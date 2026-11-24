--!strict
-- HarvestService — owner: Gameplay (Cosmic Core Hunt). Server authority for the harvesting loop.
--   * builds one Gravity Harvester per planet slot (Workspace.PF_Harvest/Harvester_n)
--   * sessions: only the slot OWNER can operate, only while standing at the console, one at a time
--   * server-authored meteor stream per session (Harvest_Event "spawn"); clients animate it locally
--   * every capture claim is verified (HarvestSessionCore + HarvestRules) and rewarded ONLY through
--     EconomyService:RewardHarvest (energy cost, yield formula, XP) and InventoryService discoveries
--
-- Remotes (PF_Remotes; replies on Action_Result via RemoteGuard):
--   Harvest_Enter  {requestId}                     -> OK | NOT_READY | NO_HARVESTER | TOO_FAR | DEAD
--   Harvest_Exit   {requestId}                     -> OK
--   Harvest_Charge {requestId}                     -> OK {readyAt} | COOLDOWN {readyAt} | SHOT_IN_FLIGHT |
--                                                     NOT_OPERATING | TOO_FAR   (server timestamps the charge)
--   Harvest_Fire   {requestId, targetId, fireTime, aimX, aimY, aimZ}
--        -> CAPTURE {result, targetId, kind, displayName, rarity, fragment, quality, materialId, amount, xp,
--                    energySpent, discoveries, cancelIds, readyAt, cooldown, ...}
--        -> MISS {result, targetId, reason, missStacks, readyAt, cooldown}
--        -> rejected {targetId, readyAt}: NOT_OPERATING | BAD_TIME | COOLDOWN | NOT_CHARGED | CHARGE_SHORT |
--                     SHOT_IN_FLIGHT | UNKNOWN_TARGET | ALREADY_CLAIMED | CAPTURE_LIMIT | NOT_ENOUGH_ENERGY |
--                     TOO_FAR | INVALID_PAYLOAD
--        readyAt is SERVER time (Workspace:GetServerTimeNow) when the pulse emitter can charge again.
--   Harvest_Event (server -> owner client)
--        {type="session", active, slot?, tutorial?, meteors?, missStacks?, captures?, readyAt?, resumed?, reason?}
--        {type="spawn", meteors = {spec...}}
--
-- Public server API (quests / co-op / analytics later):
--   :IsOperating(player) -> boolean   :GetHarvester(slot) -> Model?   :EndSession(player, reason)
--   .CaptureCompleted(player, info)   .SessionChanged(player, active, reason)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local WorldLayout = require(Shared.Config.WorldLayout)
local HarvestConfig = require(Shared.Config.HarvestConfig)
local HarvestLayout = require(Shared.Harvest.HarvestLayout)
local Formulas = require(Shared.Economy.EconomyFormulas)
local Server = script.Parent.Parent
local RemoteGuard = require(Server.Net.RemoteGuard)
local HarvesterBuilder = require(Server.Harvest.HarvesterBuilder)
local HarvestSessionCore = require(Server.Harvest.HarvestSessionCore)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)
local PlanetDataService = require(script.Parent.PlanetDataService)
local HarvestRules = require(Shared.Harvest.HarvestRules)
local MeteorRegistry = require(Shared.Harvest.MeteorRegistry)

local HarvestService = {}
HarvestService.CaptureCompleted = Signal.new()
HarvestService.SessionChanged = Signal.new()

local core: any = nil
local harvesters: { [number]: Model } = {}
local eventRemote: RemoteEvent

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function send(player: Player, msg: any)
	if player.Parent == Players then
		eventRemote:FireClient(player, msg)
	end
end

local function setConsoleStatus(slot: number, text: string)
	local m = harvesters[slot]
	local screen = m and m:FindFirstChild("Static") and m.Static:FindFirstChild("ConsoleScreen")
	local label = screen and screen:FindFirstChild("Screen") and screen.Screen:FindFirstChild("Status")
	if label then
		(label :: TextLabel).Text = string.format("PLANET %02d  •  %s", slot, text)
	end
end

local function setOwner(slot: number, player: Player?)
	local m = harvesters[slot]
	if not m then
		return
	end
	m:SetAttribute("PFOwnerUserId", if player then player.UserId else 0)
	m:SetAttribute("PFOwnerName", if player then player.DisplayName else "")
	local anchor = m.Static:FindFirstChild("LabelAnchor")
	local owner = anchor and anchor:FindFirstChild("HarvesterLabel") and anchor.HarvesterLabel:FindFirstChild("Owner")
	if owner then
		(owner :: TextLabel).Text = if player then ("Operator: " .. player.DisplayName) else "Unclaimed"
	end
	setConsoleStatus(slot, "STANDBY")
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function consoleDistance(player: Player, slot: number): number?
	local root = rootOf(player)
	if not root then
		return nil
	end
	return (root.Position - HarvestLayout.forSlot(slot).console).Magnitude
end

local function meteorList(s: any): { any }
	local list = {}
	for _, spec in s.meteors do
		table.insert(list, spec)
	end
	return list
end

local function upgradeBonusDeg(data: any): number
	local bonus = 0
	for _, hook in HarvestConfig.UPGRADE_HOOKS do
		local lvl = data.upgrades[hook.upgradeId] or 0
		bonus += lvl * (hook.coneBonusDegPerLevel or 0)
	end
	return bonus
end

-- readyAt for the wire (-math.huge = never fired -> nil)
local function finiteReadyAt(t: number): number?
	return if t > -math.huge then t else nil
end

function HarvestService:EndSession(player: Player, reason: string)
	local s = core:Get(player)
	if not s then
		return
	end
	core:Stop(player, serverNow()) -- dormant: re-entering resumes the same stream; the reload is kept
	setConsoleStatus(s.slot, "STANDBY")
	send(player, { type = "session", active = false, reason = reason })
	HarvestService.SessionChanged:Fire(player, false, reason)
end

function HarvestService:IsOperating(player: Player): boolean
	return core ~= nil and core:Get(player) ~= nil
end

function HarvestService:GetHarvester(slot: number): Model?
	return harvesters[slot]
end

---------------------------------------------------------------- handlers (also used by the Studio test hook)

local handlers = {}

function handlers.enter(player: Player, _p: any): (boolean, string, any?)
	if not ProfileService:IsReady(player) then
		return false, "NOT_READY"
	end
	local slot = PlanetSlotService:GetSlot(player)
	if not slot or not harvesters[slot] then
		return false, "NO_HARVESTER"
	end
	local dist = consoleDistance(player, slot)
	if not dist then
		return false, "DEAD"
	end
	if dist > HarvestConfig.OPERATE.ENTER_RADIUS then
		return false, "TOO_FAR"
	end
	local data = ProfileService:GetData(player)
	local tutorial = data.discoveries.FirstHarvest == nil
	local s = core:Start(player, slot, serverNow(), { tutorial = tutorial, worldContext = HarvestRules.worldContext(PlanetDataService:GetView(player)) })
	core:TakeOutbox(player) -- everything is in the session snapshot below
	send(player, {
		type = "session",
		active = true,
		slot = slot,
		tutorial = s.tutorial,
		meteors = meteorList(s),
		missStacks = s.missStacks,
		captures = s.captures,
		readyAt = finiteReadyAt(core:ReadyAt(player)),
		resumed = s.resumed,
	})
	setConsoleStatus(slot, "OPERATING")
	HarvestService.SessionChanged:Fire(player, true, "enter")
	return true, "OK", { slot = slot, tutorial = s.tutorial }
end

function handlers.exit(player: Player, _p: any): (boolean, string, any?)
	HarvestService:EndSession(player, "exit")
	return true, "OK"
end

-- Charge start: the server records ITS time, so the minimum charge cannot be faked by the client.
function handlers.charge(player: Player, _p: any): (boolean, string, any?)
	local s = core:Get(player)
	if not s then
		return false, "NOT_OPERATING"
	end
	local dist = consoleDistance(player, s.slot)
	if not dist or dist > HarvestConfig.OPERATE.SESSION_RADIUS then
		HarvestService:EndSession(player, if dist then "too_far" else "died")
		return false, "TOO_FAR"
	end
	local ok, code, readyAt = core:BeginCharge(player, serverNow())
	return ok, code, { readyAt = finiteReadyAt(readyAt) }
end

function handlers.fire(player: Player, p: any): (boolean, string, any?)
	local id, fireTime = p.targetId, p.fireTime
	if not RemoteGuard.isInt(id, 1, 2 ^ 31) or not RemoteGuard.isFiniteNumber(fireTime) then
		return false, "INVALID_PAYLOAD"
	end
	local ax, ay, az = p.aimX, p.aimY, p.aimZ
	if not (RemoteGuard.isFiniteNumber(ax) and RemoteGuard.isFiniteNumber(ay) and RemoteGuard.isFiniteNumber(az)) then
		return false, "INVALID_PAYLOAD"
	end
	local aim = Vector3.new(ax, ay, az)
	if aim.Magnitude < 0.5 or aim.Magnitude > 1.5 then
		return false, "INVALID_PAYLOAD"
	end
	local s = core:Get(player)
	if not s then
		return false, "NOT_OPERATING"
	end
	local dist = consoleDistance(player, s.slot)
	if not dist or dist > HarvestConfig.OPERATE.SESSION_RADIUS then
		HarvestService:EndSession(player, if dist then "too_far" else "died")
		return false, "TOO_FAR"
	end
	local data = ProfileService:GetData(player)
	if not data then
		return false, "NOT_READY"
	end
	local cost = Formulas.harvestEnergyCost(data.upgrades.HarvestEfficiency or 0)
	local energy = EconomyService:GetBalance(player, "currencies", "CosmicEnergy") or 0
	local res = core:Fire(player, { targetId = id, fireTime = fireTime, aim = aim.Unit }, {
		now = serverNow(),
		ping = player:GetNetworkPing(),
		canAfford = energy >= cost,
		bonusDeg = upgradeBonusDeg(data),
	})
	if not res.ok then
		return false, res.code, { targetId = id, readyAt = finiteReadyAt(res.readyAt or core:ReadyAt(player)) }
	end
	if res.outcome == "miss" then
		return true, "MISS", { result = "miss", targetId = id, reason = res.reason, missStacks = res.missStacks, readyAt = res.readyAt, cooldown = res.cooldown }
	end
	local spec = res.spec
	local def = MeteorRegistry.get(spec.kind)
	-- rewards only through the existing economy API; a throw or failure gives the target back
	local okCall, ok, code, reward = pcall(EconomyService.RewardHarvest, EconomyService, player, def.resource, res.multiplier)
	if not okCall or not ok then
		core:Unclaim(player, spec, res.cancelled)
		if not okCall then
			warn("[PF][Harvest] reward error: " .. tostring(ok))
		end
		return false, if okCall then code else "INTERNAL_ERROR", { targetId = id, readyAt = res.readyAt }
	end
	core:Settle(player)
	local discoveries = {}
	for _, discoveryId in { "FirstHarvest", def.discovery } do
		if discoveryId then
			local _, _, isNew = InventoryService:RecordDiscovery(player, discoveryId)
			if isNew then
				table.insert(discoveries, discoveryId)
			end
		end
	end
	local tutorialComplete = s.tutorial
	if s.tutorial then
		core:CompleteTutorial(player, serverNow())
	end
	local info = {
		result = "capture",
		targetId = id,
		kind = spec.kind,
		displayName = def.displayName,
		rarity = def.rarity,
		fragment = spec.fragment == true,
		cancelIds = res.cancelIds,
		readyAt = res.readyAt,
		cooldown = res.cooldown,
		quality = res.quality,
		multiplier = res.multiplier,
		materialId = def.resource,
		amount = reward.amount,
		xp = reward.xp,
		energySpent = reward.energySpent,
		discoveries = discoveries,
		tutorialComplete = tutorialComplete,
		captures = s.captures,
	}
	HarvestService.CaptureCompleted:Fire(player, info)
	return true, "CAPTURE", info
end

---------------------------------------------------------------- lifecycle

function HarvestService:Init()
	core = HarvestSessionCore.new({ seed = math.floor(os.clock() * 1000) % 100000 })
	local folder = (Workspace:FindFirstChild("PF_Harvest") :: Folder?) or Instance.new("Folder")
	folder.Name = "PF_Harvest"
	for _, slot in WorldLayout.ACTIVE_SLOTS do
		local existing = folder:FindFirstChild("Harvester_" .. slot) :: Model?
		local m = existing or HarvesterBuilder.build(slot)
		m.Parent = folder
		harvesters[slot] = m
	end
	folder.Parent = Workspace
	eventRemote = RemoteGuard.getRemote("Harvest_Event")
	PlanetSlotService.SlotAssigned:Connect(function(player: Player, slot: number)
		setOwner(slot, player)
	end)
	PlanetSlotService.SlotReleased:Connect(function(player: Player, slot: number)
		core:Forget(player)
		setOwner(slot, nil)
	end)
	ProfileService.ProfileReleasing:Connect(function(player: Player)
		core:Forget(player) -- disconnect mid-session: nothing pending, rewards are granted synchronously
	end)
	-- the owner's planet decides which matter it attracts (Spore clouds need Water, comets need Stage 2...)
	PlanetDataService.PlanetChanged:Connect(function(player: Player)
		if core:Get(player) then
			core:SetWorldContext(player, HarvestRules.worldContext(PlanetDataService:GetView(player)))
		end
	end)
end

function HarvestService:Start()
	RemoteGuard.bind("Harvest_Enter", handlers.enter)
	RemoteGuard.bind("Harvest_Exit", handlers.exit)
	RemoteGuard.bind("Harvest_Charge", handlers.charge)
	RemoteGuard.bind("Harvest_Fire", handlers.fire)
	for _, p in Players:GetPlayers() do
		local slot = PlanetSlotService:GetSlot(p)
		if slot then
			setOwner(slot, p)
		end
	end
	Players.PlayerRemoving:Connect(function(p)
		core:Forget(p)
	end)

	local tickAcc, pollAcc = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		tickAcc += dt
		pollAcc += dt
		if tickAcc >= HarvestConfig.SPAWN.TICK_INTERVAL then
			tickAcc = 0
			local ended = core:Tick(serverNow())
			for player, reason in ended do
				send(player, { type = "session", active = false, reason = reason })
				HarvestService.SessionChanged:Fire(player, false, reason)
			end
			for player in core.sessions do
				local specs = core:TakeOutbox(player)
				if #specs > 0 then
					send(player, { type = "spawn", meteors = specs })
				end
			end
		end
		if pollAcc >= HarvestConfig.OPERATE.POLL_INTERVAL then
			pollAcc = 0
			for player, s in core.sessions do
				if player.Parent ~= Players then
					core:Forget(player)
					continue
				end
				local dist = consoleDistance(player, s.slot)
				if not dist then
					HarvestService:EndSession(player, "died")
				elseif dist > HarvestConfig.OPERATE.SESSION_RADIUS then
					HarvestService:EndSession(player, "too_far")
				end
			end
		end
	end)

	-- Studio-only server test hook (MCP / command bar run in a separate VM). Not reachable by clients.
	if RunService:IsStudio() then
		local ServerStorage = game:GetService("ServerStorage")
		local hook = (ServerStorage:FindFirstChild("PF_HarvestTestHook") :: BindableFunction?) or Instance.new("BindableFunction")
		hook.Name = "PF_HarvestTestHook"
		hook.Archivable = false
		hook.OnInvoke = function(command: string, userId: number, arg: any): any
			local player = Players:GetPlayerByUserId(userId)
			if not player then
				return { error = "NO_PLAYER" }
			end
			if command == "state" then
				local s = core:Get(player)
				local slot = PlanetSlotService:GetSlot(player)
				return {
					operating = s ~= nil,
					slot = slot,
					sessions = core:SessionCount(),
					meteors = if s then meteorList(s) else {},
					missStacks = s and s.missStacks,
					captures = s and s.captures,
					tutorial = s and s.tutorial,
					consoleDistance = slot and consoleDistance(player, slot),
					serverNow = serverNow(),
					readyAt = finiteReadyAt(core:ReadyAt(player)),
					charge = s and s.charge,
					inFlight = s ~= nil and s.inFlightAt ~= nil,
					dormant = core.dormant[player] ~= nil,
					resumed = s and s.resumed,
					footprint = core:Footprint(),
				}
			elseif command == "teleport" then
				local slot = PlanetSlotService:GetSlot(player)
				local char = player.Character
				if not slot or not char then
					return { error = "NO_SLOT_OR_CHAR" }
				end
				local L = HarvestLayout.forSlot(slot)
				local offset = if type(arg) == "number" then arg else 0
				local pos = L.toWorld(HarvestConfig.DEVICE.OPERATOR + Vector3.new(0, 4, -offset))
				char:PivotTo(CFrame.lookAt(pos, pos + L.base.LookVector, L.base.UpVector))
				return { ok = true }
			elseif command == "call" then
				local fn = handlers[arg.handler]
				return table.pack(fn(player, arg.payload or {}))
			elseif command == "end" then
				HarvestService:EndSession(player, arg or "test")
				return { ok = true }
			end
			return { error = "UNKNOWN_COMMAND" }
		end
		hook.Parent = ServerStorage
	end
end

return HarvestService
