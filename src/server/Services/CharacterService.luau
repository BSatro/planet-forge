--!strict
-- CharacterService — owner: Developer A. Server-authoritative character lifecycle:
--   * owns spawning (Players.CharacterAutoLoads = false), places characters at their spawn target
--   * respawn after death (any cause) exactly once per character
--   * recovery: characters in deep space (no gravity field) for RECOVER_AFTER seconds, NaN positions,
--     or below the safety floor are moved back to their spawn target
--   * warp pads (distance polled, no Touched dependency)
--   * remotes Travel_Warp and Character_Recover (INTERFACES.md v1.1). PROTOTYPE net layer:
--     validation + per-player cooldown inline here; replaced by Net/RemoteGuard in M0.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local GravityFields = require(ReplicatedStorage.PF_Shared.Gravity.GravityFields)

local CharacterService = {}

local RECOVER_AFTER = 2.5 -- seconds in space before forced recovery
local POLL_INTERVAL = 0.25
local SAFETY_FLOOR_Y = WorldLayout.STATION_CENTER.Y - 1500
local PAD_RADIUS = 4.5
local PAD_HEIGHT = 7
local WARP_COOLDOWN = 2
local REQUEST_COOLDOWN = 1
local WARP_OUT_TIME = 0.35 -- client fades out during this window, then the character is moved once

type SpawnTarget = "station" | number

type PlayerState = {
	spawnTarget: SpawnTarget,
	spaceSince: number?,
	lastWarpAt: number,
	lastRequestAt: number,
	warping: boolean,
	respawnScheduledFor: Model?,
	connections: { RBXScriptConnection },
}

local fields = GravityFields.buildDefault()
local states: { [Player]: PlayerState } = {}
local remotes: { [string]: RemoteEvent } = {}
local pads: { { position: Vector3, up: Vector3, target: SpawnTarget, fromSlot: number? } } = {}

local function now(): number
	return os.clock()
end

local function getRemoteFolder(): Folder
	local f = ReplicatedStorage:FindFirstChild("PF_Remotes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "PF_Remotes"
		f.Parent = ReplicatedStorage
	end
	return f :: Folder
end

local function remote(name: string): RemoteEvent
	local folder = getRemoteFolder()
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	remotes[name] = r :: RemoteEvent
	return r :: RemoteEvent
end

local function reply(player: Player, requestId: any, ok: boolean, code: string)
	if typeof(requestId) == "number" then
		remotes.Action_Result:FireClient(player, { requestId = requestId, ok = ok, code = code })
	end
end

local function isValidRequestId(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and v >= 1 and v <= 2 ^ 31
end

-- Fx_Play is an UnreliableRemoteEvent (cosmetic, may drop).
local function fireFx(payload: { [string]: any })
	local fx: any = remotes.Fx_Play
	if fx then
		fx:FireAllClients(payload)
	end
end

-- fromSlot: when returning from a planet, arrive on that planet's dock instead of the plaza spawn.
local function targetCFrame(target: SpawnTarget, fromSlot: number?): CFrame
	if target == "station" then
		if fromSlot and WorldLayout.isValidSlot(fromSlot) then
			return WorldLayout.getStationArrival(fromSlot)
		end
		return WorldLayout.getStationSpawn()
	end
	return WorldLayout.getPlanetSpawn(target :: number)
end

local function getRoot(player: Player): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Single CFrame move (not per-frame) + velocity reset. Server writes replicate to the owning client.
function CharacterService:PlaceCharacter(player: Player, target: SpawnTarget, fromSlot: number?): boolean
	local char = player.Character
	local root = getRoot(player)
	if not char or not root then
		return false
	end
	char:PivotTo(targetCFrame(target, fromSlot))
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	local st = states[player]
	if st then
		st.spaceSince = nil
	end
	return true
end

-- Mission hook (Cosmic Rifts): when set and returning a CFrame, (re)spawns and recoveries go there instead of
-- the player's spawn target (e.g. the team's rift checkpoint).
CharacterService.SpawnOverride = nil :: ((Player) -> CFrame?)?

function CharacterService:PlaceAt(player: Player, cf: CFrame): boolean
	local char = player.Character
	local root = getRoot(player)
	if not char or not root then
		return false
	end
	char:PivotTo(cf)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	local st = states[player]
	if st then
		st.spaceSince = nil
	end
	return true
end

-- Same presentation as WarpTo, to an arbitrary CFrame (streams the destination in first).
-- `label` is shown by TravelFX ("rift", "rift_exit"). onArrive(ok) runs after the move.
function CharacterService:WarpToCFrame(player: Player, cf: CFrame, label: string, onArrive: ((boolean) -> ())?): string
	local st = states[player]
	local char = player.Character
	local root = getRoot(player)
	if not st or not char or not root then
		return "NOT_READY"
	end
	if st.warping then
		return "ALREADY_ACTIVE"
	end
	st.warping = true
	st.lastWarpAt = now()
	remotes.Travel_Transition:FireClient(player, { phase = "out", destination = label, duration = WARP_OUT_TIME })
	fireFx({ fxId = "warp_depart", position = root.Position })
	task.spawn(function()
		pcall(function()
			player:RequestStreamAroundAsync(cf.Position, 4)
		end)
	end)
	task.delay(WARP_OUT_TIME, function()
		local s = states[player]
		if s then
			s.warping = false
			s.lastWarpAt = now()
		end
		local ok = s ~= nil and player.Character == char and char.Parent ~= nil and self:PlaceAt(player, cf)
		if ok then
			fireFx({ fxId = "warp_arrive", position = cf.Position })
		end
		remotes.Travel_Transition:FireClient(player, { phase = "in", destination = label })
		if onArrive then
			task.spawn(onArrive, ok)
		end
	end)
	return "OK"
end

-- Teleport network: fade-out on the client, ONE CFrame move, arrival FX for everyone nearby.
-- Returns immediately; the move happens WARP_OUT_TIME later if the character is still valid.
function CharacterService:WarpTo(player: Player, destination: SpawnTarget, fromSlot: number?): string
	if destination ~= "station" and not WorldLayout.isActiveSlot(destination) then
		return "NOT_FOUND"
	end
	local st = states[player]
	local char = player.Character
	local root = getRoot(player)
	if not st or not char or not root then
		return "NOT_READY"
	end
	if st.warping then
		return "ALREADY_ACTIVE"
	end
	st.warping = true
	st.lastWarpAt = now()
	st.spawnTarget = destination
	remotes.Travel_Transition:FireClient(player, { phase = "out", destination = destination, duration = WARP_OUT_TIME })
	fireFx({ fxId = "warp_depart", position = root.Position })
	task.delay(WARP_OUT_TIME, function()
		local s = states[player]
		if s then
			s.warping = false
			s.lastWarpAt = now()
		end
		if not s or player.Character ~= char or not char.Parent then
			return
		end
		if self:PlaceCharacter(player, destination, fromSlot) then
			local r = getRoot(player)
			if r then
				fireFx({ fxId = "warp_arrive", position = r.Position })
			end
		end
		remotes.Travel_Transition:FireClient(player, { phase = "in", destination = destination })
	end)
	return "OK"
end

local function scheduleRespawn(player: Player, char: Model)
	local st = states[player]
	if not st or st.respawnScheduledFor == char then
		return
	end
	st.respawnScheduledFor = char
	task.delay(Players.RespawnTime, function()
		if player.Parent == Players and player.Character == char then
			player:LoadCharacter()
		end
	end)
end

local function respawnNow(player: Player)
	local st = states[player]
	if st then
		st.respawnScheduledFor = player.Character
	end
	player:LoadCharacter()
end

local function onCharacterAdded(player: Player, char: Model)
	local humanoid = char:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root or player.Character ~= char then
		return
	end
	local st = states[player]
	if not st then
		return
	end
	local override = CharacterService.SpawnOverride and CharacterService.SpawnOverride(player)
	if override then
		CharacterService:PlaceAt(player, override)
	else
		CharacterService:PlaceCharacter(player, st.spawnTarget)
	end
	humanoid.Died:Connect(function()
		scheduleRespawn(player, char)
	end)
	humanoid.HealthChanged:Connect(function(h)
		if h <= 0 then
			scheduleRespawn(player, char)
		end
	end)
end

local function onPlayerAdded(player: Player)
	if states[player] then
		return
	end
	local st: PlayerState = {
		spawnTarget = "station",
		spaceSince = nil,
		lastWarpAt = 0,
		lastRequestAt = 0,
		warping = false,
		respawnScheduledFor = nil,
		connections = {},
	}
	states[player] = st
	table.insert(st.connections, player.CharacterAdded:Connect(function(char)
		onCharacterAdded(player, char)
	end))
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	else
		player:LoadCharacter()
	end
end

local function onPlayerRemoving(player: Player)
	local st = states[player]
	if st then
		for _, c in st.connections do
			c:Disconnect()
		end
	end
	states[player] = nil
end

local function poll()
	local t = now()
	for player, st in states do
		local root = getRoot(player)
		if not root then
			continue
		end
		local pos = root.Position
		if not GravityFields.isFinite(pos) or pos.Y < SAFETY_FLOOR_Y then
			local override = CharacterService.SpawnOverride and CharacterService.SpawnOverride(player)
			if override then
				CharacterService:PlaceAt(player, override)
			else
				CharacterService:PlaceCharacter(player, st.spawnTarget)
			end
			continue
		end
		local sample = GravityFields.sample(fields, pos)
		if sample.kind == "space" then
			st.spaceSince = st.spaceSince or t
			if t - (st.spaceSince :: number) >= RECOVER_AFTER then
				local override = CharacterService.SpawnOverride and CharacterService.SpawnOverride(player)
				if override then
					CharacterService:PlaceAt(player, override)
				else
					CharacterService:PlaceCharacter(player, st.spawnTarget)
				end
			end
			continue
		end
		st.spaceSince = nil
		if not st.warping and t - st.lastWarpAt >= WARP_COOLDOWN then
			for _, pad in pads do
				local d = pos - pad.position
				local along = d:Dot(pad.up)
				if along >= -1 and along <= PAD_HEIGHT and (d - pad.up * along).Magnitude <= PAD_RADIUS then
					CharacterService:WarpTo(player, pad.target, pad.fromSlot)
					break
				end
			end
		end
	end
end

function CharacterService:Init()
	Players.CharacterAutoLoads = false
	remote("Action_Result")
	remote("Travel_Warp")
	remote("Character_Recover")
	remote("Travel_Transition")
	do
		local folder = getRemoteFolder()
		local fx = folder:FindFirstChild("Fx_Play")
		if not fx then
			fx = Instance.new("UnreliableRemoteEvent")
			fx.Name = "Fx_Play"
			fx.Parent = folder
		end
		remotes.Fx_Play = fx :: any
	end
	for _, slot in WorldLayout.ACTIVE_SLOTS do
		table.insert(pads, { position = WorldLayout.getStationPadPosition(slot), up = Vector3.yAxis, target = slot })
		table.insert(pads, { position = WorldLayout.getPlanetPadPosition(slot), up = Vector3.yAxis, target = "station", fromSlot = slot })
	end
end

function CharacterService:Start()
	remotes.Travel_Warp.OnServerEvent:Connect(function(player, payload)
		local st = states[player]
		if not st or typeof(payload) ~= "table" or not isValidRequestId(payload.requestId) then
			return
		end
		if now() - st.lastRequestAt < REQUEST_COOLDOWN then
			reply(player, payload.requestId, false, "RATE_LIMITED")
			return
		end
		st.lastRequestAt = now()
		local dest = payload.destination
		if dest == "home" then
			-- QA-2026-11-21: "home" used to mean slot 1 for everyone (prototype). Resolve the player's own slot;
			-- lazy require: PlanetSlotService boots after this service.
			local okS, PlanetSlotService = pcall(require, script.Parent.PlanetSlotService)
			local own = okS and (PlanetSlotService :: any):GetSlot(player) or nil
			if not own then
				reply(player, payload.requestId, false, "NO_PLANET")
				return
			end
			dest = own
		end
		if dest ~= "station" and not WorldLayout.isActiveSlot(dest) then
			reply(player, payload.requestId, false, "INVALID_PAYLOAD")
			return
		end
		local code = CharacterService:WarpTo(player, dest)
		reply(player, payload.requestId, code == "OK", code)
	end)

	remotes.Character_Recover.OnServerEvent:Connect(function(player, payload)
		local st = states[player]
		if not st or typeof(payload) ~= "table" or not isValidRequestId(payload.requestId) then
			return
		end
		if now() - st.lastRequestAt < REQUEST_COOLDOWN then
			reply(player, payload.requestId, false, "RATE_LIMITED")
			return
		end
		st.lastRequestAt = now()
		if payload.mode == "respawn" then
			respawnNow(player)
			reply(player, payload.requestId, true, "OK")
		elseif payload.mode == "recover" then
			local ok = CharacterService:PlaceCharacter(player, st.spawnTarget)
			reply(player, payload.requestId, ok, if ok then "OK" else "NOT_READY")
		else
			reply(player, payload.requestId, false, "INVALID_PAYLOAD")
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= POLL_INTERVAL then
			acc = 0
			poll()
		end
	end)
end

function CharacterService:GetSpawnTarget(player: Player): SpawnTarget?
	local st = states[player]
	return st and st.spawnTarget
end

return CharacterService
