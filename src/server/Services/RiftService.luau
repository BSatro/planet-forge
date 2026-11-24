--!strict
-- RiftService — owner: Mission Systems. COSMIC RIFTS: replayable co-op expedition "The Fractured Nebula".
--   Station portal (ProximityPrompt / Expedition_Start) -> forming lobby (LOBBY_SECONDS, anyone may join, any member
--   may launch now) -> procedurally generated arena in a free slot -> collect fragments, stabilize 3 nodes IN ORDER,
--   seal the core, escape -> per-explorer rewards granted ONCE at escape through EconomyService (reason "Expedition").
-- Authority: every objective is observed server-side (positions sampled at SECURITY.sampleHz, server Touched for
-- pickups). Clients only send intent (start, launch, leave, restart, home, claim-summary). Speed/teleport checks snap
-- offenders back and remove repeat offenders; non-members found inside an arena are sent to the station.
-- Remotes: Expedition_Start {requestId}, Expedition_Action {requestId, action}, Expedition_Claim {requestId, runId}
--          -> Action_Result; server->client Expedition_State (public run state), Expedition_Event (feedback).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.PF_Shared
local RiftConfig = require(Shared.Rift.RiftConfig)
local RiftLayout = require(Shared.Rift.RiftLayout)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local RiftRules = require(script.Parent.Parent.Rift.RiftRules)
local RiftBuilder = require(script.Parent.Parent.Rift.RiftBuilder)
local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local CharacterService = require(script.Parent.CharacterService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)

local RiftService = {}

type RT = { run: any, slot: number, origin: Vector3, h: any, players: { [Player]: boolean }, lastPos: { [Player]: Vector3 }, lastValid: { [Player]: CFrame }, grace: { [Player]: number }, violations: { [Player]: number }, knockCd: { [Player]: number }, outside: { [Player]: number }, lastBroadcast: number, crumbling: { [BasePart]: boolean }, teardownAt: number? }

local runtimes: { [string]: RT } = {}
local slotTaken: { [number]: string } = {}
local playerRun: { [Player]: string } = {}
local forming: { members: { Player }, endsAt: number }? = nil
local lastResult: { [number]: { runId: string, summary: any, endedAt: number } } = {}
local granted: { [string]: boolean } = {}
local leftAt: { [Player]: number } = {} -- grace for the intruder sweep while a departing warp is in flight
local remotes: any = {}
local portalPart: BasePart? = nil
local runCounter = 0
local rng = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function root(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function event(p: Player, kind: string, data: { [string]: any }?)
	local e = data or {}
	e.kind = kind
	remotes.Event:FireClient(p, e)
end

local function playersOf(rt: RT): { Player }
	local out = {}
	for p in rt.players do
		table.insert(out, p)
	end
	return out
end

local function setPortalAttrs()
	local holder = portalPart and portalPart.Parent
	if not holder then
		return
	end
	holder:SetAttribute("PFRiftLobbyCount", if forming then #forming.members else 0)
	holder:SetAttribute("PFRiftLobbyEndsAt", if forming then forming.endsAt else 0)
	local active = 0
	for _ in runtimes do
		active += 1
	end
	holder:SetAttribute("PFRiftActiveRuns", active)
end

local function sendLobby()
	if not forming then
		return
	end
	local names = {}
	for _, p in forming.members do
		table.insert(names, p.DisplayName)
	end
	for _, p in forming.members do
		remotes.State:FireClient(p, { phase = "forming", endsAt = forming.endsAt, members = names, max = RiftConfig.MAX_PLAYERS })
	end
	setPortalAttrs()
end

----------------------------------------------------------------------------------------------------
-- teleports (server-initiated moves get a grace window for the speed check)
local function legitPlace(rt: RT, p: Player, cf: CFrame)
	rt.grace[p] = now() + 1.5
	rt.lastValid[p] = cf
	rt.lastPos[p] = cf.Position
	CharacterService:PlaceAt(p, cf)
end

local function checkpointCf(rt: RT, p: Player): CFrame
	local cf = rt.h.checkpoints[rt.run.checkpoint] or rt.h.checkpoints[0]
	local i = 0
	for q in rt.players do
		i += 1
		if q == p then
			break
		end
	end
	return cf * CFrame.new((i % 4 - 1.5) * 3, 0, math.floor(i / 4) * 3)
end


local function stationArrival(): CFrame
	local pp = portalPart
	if not pp then
		return CFrame.new(0, 3010, 0)
	end
	-- in front of the portal, facing away from it, on the deck
	local look = (Vector3.new(0, pp.Position.Y, 0) - pp.Position)
	look = Vector3.new(look.X, 0, look.Z).Unit
	local pos = pp.Position + look * 18 - Vector3.new(0, 9, 0)
	return CFrame.lookAt(pos, pos + look)
end

----------------------------------------------------------------------------------------------------
-- rewards (server-authoritative, exactly once per run+player)
local function itemName(section: string, id: string): string
	local cat = if section == "catalysts" then ItemCatalog.CATALYSTS else ItemCatalog.MATERIALS
	local d = cat and cat[id]
	return (d and d.displayName) or id
end

local function grantRewards(p: Player, rt: RT): any
	local run = rt.run
	local key = run.id .. ":" .. p.UserId
	local eligible, reward = RiftRules.rewardsFor(run, p.UserId)
	local summary: any = {
		runId = run.id,
		outcome = if run.phase == "escape" then "completed" else run.outcome,
		elapsed = math.floor(((run.endedAt or now()) - run.startedAt) + 0.5),
		nodesDone = run.nodesDone,
		collected = run.collectedCount,
		total = run.total,
		players = run.players,
		secondaries = {},
		eligible = eligible,
		reason = if eligible then nil else reward,
		rewards = { credits = 0, energy = 0, xp = 0, items = {} },
		lines = {},
	}
	for _, id in run.layout.secondaries do
		local d = RiftConfig.SECONDARIES[id]
		table.insert(summary.secondaries, { name = d.name, text = d.text, state = run.sec[id] })
	end
	if eligible and not granted[key] then
		granted[key] = true
		local energy = reward.energy
		local cap = EconomyService:GetEnergyCap(p) or 0
		local cur = EconomyService:GetBalance(p, "currencies", "CosmicEnergy") or 0
		energy = math.max(0, math.min(energy, cap - cur))
		local tx: any = { currencies = { Credits = reward.credits } }
		if energy > 0 then
			tx.currencies.CosmicEnergy = energy
		end
		if next(reward.materials) then
			tx.materials = reward.materials
		end
		if next(reward.catalysts) then
			tx.catalysts = reward.catalysts
		end
		local ok, code = EconomyService:Transact(p, tx, "Expedition")
		if not ok then
			-- fall back to individual grants so one capped line never voids the whole reward
			warn("[PF][Rift] combined grant failed (" .. tostring(code) .. "), granting lines individually")
			EconomyService:Grant(p, "currencies", "Credits", reward.credits, "Expedition")
			if energy > 0 then
				EconomyService:Grant(p, "currencies", "CosmicEnergy", energy, "Expedition")
			end
			for id, n in reward.materials do
				EconomyService:Grant(p, "materials", id, n, "Expedition")
			end
			for id, n in reward.catalysts do
				EconomyService:Grant(p, "catalysts", id, n, "Expedition")
			end
		end
		if reward.xp > 0 then
			EconomyService:GrantXp(p, reward.xp, "Expedition")
		end
		if summary.outcome == "completed" then
			local t = os.time()
			InventoryService:RecordExpedition(p, { expeditionId = RiftConfig.EXPEDITION_ID, outcome = "completed", startedAt = t - summary.elapsed, endedAt = t })
		end
		summary.rewards = { credits = reward.credits, energy = energy, xp = reward.xp, items = {} }
		for id, n in reward.catalysts do
			table.insert(summary.rewards.items, { name = itemName("catalysts", id), amount = n, kind = "catalyst" })
		end
		for id, n in reward.materials do
			table.insert(summary.rewards.items, { name = itemName("materials", id), amount = n, kind = if id == RiftConfig.REWARDS.componentId then "component" else "material" })
		end
		summary.lines = reward.lines
		print(string.format("[PF][Rift] %s rewarded run %s: %d credits, %d energy, %d xp", p.Name, run.id, reward.credits, energy, reward.xp))
	end
	lastResult[p.UserId] = { runId = run.id, summary = summary, endedAt = now() }
	event(p, "summary", { summary = summary })
	return summary
end

----------------------------------------------------------------------------------------------------
-- membership
local function detach(p: Player, rt: RT, reason: string, teleport: boolean)
	rt.players[p] = nil
	leftAt[p] = now()
	rt.lastPos[p], rt.lastValid[p], rt.grace[p], rt.violations[p], rt.outside[p] = nil, nil, nil, nil, nil
	if playerRun[p] == rt.run.id then
		playerRun[p] = nil
	end
	if teleport and p.Parent == Players then
		CharacterService:WarpToCFrame(p, stationArrival(), "rift_exit")
	end
	event(p, "detached", { reason = reason })
end

local function leaveRun(p: Player, reason: string, teleport: boolean)
	if forming then
		local i = table.find(forming.members, p)
		if i then
			table.remove(forming.members, i)
			playerRun[p] = nil
			event(p, "detached", { reason = reason })
			if #forming.members == 0 then
				forming = nil
			end
			sendLobby()
			setPortalAttrs()
			return
		end
	end
	local id = playerRun[p]
	local rt = id and runtimes[id]
	if rt then
		RiftRules.removeMember(rt.run, p.UserId, now())
		detach(p, rt, reason, teleport)
	end
end

----------------------------------------------------------------------------------------------------
-- launch / teardown
local function teardown(rt: RT)
	for p in rt.players do
		detach(p, rt, "ended", true)
	end
	runtimes[rt.run.id] = nil
	task.delay(4, function()
		if rt.h and rt.h.folder then
			rt.h.folder:Destroy()
		end
		slotTaken[rt.slot] = nil
		setPortalAttrs()
	end)
end

local function hookTouches(rt: RT)
	local function playerFrom(hit: BasePart): Player?
		local model = hit:FindFirstAncestorOfClass("Model")
		return model and Players:GetPlayerFromCharacter(model)
	end
	for id, frag in rt.h.fragments do
		frag.Touched:Connect(function(hit)
			local p = playerFrom(hit)
			local r = p and root(p :: Player)
			if not p or not r or not rt.players[p] or not frag.Parent then
				return
			end
			if (r.Position - frag.Position).Magnitude > RiftConfig.FRAGMENTS.pickupRadius then
				return
			end
			local ok = RiftRules.collect(rt.run, p.UserId, id)
			if ok then
				frag:Destroy()
			end
		end)
	end
	for _, c in rt.h.crumble do
		c.part.Touched:Connect(function(hit)
			local p = playerFrom(hit)
			if not p or not rt.players[p] or rt.crumbling[c.part] then
				return
			end
			rt.crumbling[c.part] = true
			if c.glow then
				c.glow.Transparency = 0
			end
			task.delay(RiftConfig.HAZARDS.crumbleDelay, function()
				c.part.Transparency = 0.85
				c.part.CanCollide = false
				task.delay(RiftConfig.HAZARDS.crumbleRespawn, function()
					if c.part.Parent then
						c.part.Transparency = 0
						c.part.CanCollide = true
						if c.glow then
							c.glow.Transparency = 0.6
						end
						rt.crumbling[c.part] = nil
					end
				end)
			end)
		end)
	end
	for _, sw in rt.h.sweepers do
		sw.part.Touched:Connect(function(hit)
			if not sw.active then
				return
			end
			local p = playerFrom(hit)
			local r = p and root(p :: Player)
			if not p or not r or not rt.players[p] then
				return
			end
			local t = now()
			if (rt.knockCd[p] or 0) > t then
				return
			end
			rt.knockCd[p] = t + RiftConfig.HAZARDS.knockback
			rt.knockCd[p] = t + RiftConfig.HAZARDS.knockbackCooldown
			local away = (r.Position - sw.center) * Vector3.new(1, 0, 1)
			if away.Magnitude < 0.1 then
				away = Vector3.new(1, 0, 0)
			end
			rt.grace[p] = t + 1.2 -- knockback is a legitimate fast move
			event(p, "knockback", { dir = away.Unit, power = RiftConfig.HAZARDS.knockback })
		end)
	end
	if rt.h.prism then
		rt.h.prism.Touched:Connect(function(hit)
			local p = playerFrom(hit)
			if p and rt.players[p] and RiftRules.prism(rt.run, p.UserId) then
				rt.h.prism:Destroy()
				rt.h.prism = nil
			end
		end)
	end
end

local function launch()
	local f = forming
	if not f then
		return
	end
	forming = nil
	local members = {}
	for _, p in f.members do
		if p.Parent == Players and root(p) then
			table.insert(members, p)
		else
			playerRun[p] = nil
		end
	end
	if #members == 0 then
		setPortalAttrs()
		return
	end
	local slot = nil
	for s = 1, RiftConfig.MAX_RUNS do
		if not slotTaken[s] then
			slot = s
			break
		end
	end
	if not slot then
		for _, p in members do
			playerRun[p] = nil
			event(p, "error", { text = "All rifts are busy. Try again in a moment." })
		end
		setPortalAttrs()
		return
	end
	runCounter += 1
	local runId = string.format("R%d-%d", runCounter, os.time() % 100000)
	slotTaken[slot] = runId
	local seed = rng:NextInteger(1, 2 ^ 30)
	local layout = RiftLayout.generate(seed, #members)
	local origin = RiftConfig.arenaOrigin(slot)
	local container = Workspace:FindFirstChild("PF_Rifts") or Instance.new("Folder")
	container.Name = "PF_Rifts"
	container.Parent = Workspace
	local h = RiftBuilder.build(layout, origin, container, "Rift_" .. slot)
	local list = {}
	for _, p in members do
		table.insert(list, { userId = p.UserId, name = p.DisplayName })
	end
	local run = RiftRules.new(runId, seed, layout, list, now() + 0.5)
	local rt: RT = { run = run, slot = slot, origin = origin, h = h, players = {}, lastPos = {}, lastValid = {}, grace = {}, violations = {}, knockCd = {}, outside = {}, lastBroadcast = 0, crumbling = {} }
	runtimes[runId] = rt
	hookTouches(rt)
	for _, p in members do
		rt.players[p] = true
		playerRun[p] = runId
		rt.grace[p] = now() + 3
	end
	for _, p in members do
		local cf = checkpointCf(rt, p)
		rt.lastValid[p] = cf
		rt.lastPos[p] = cf.Position
		task.spawn(function()
			-- stream the arena to this client BEFORE the move, so the floor exists when they arrive
			pcall(function()
				p:RequestStreamAroundAsync(cf.Position, 6)
			end)
			rt.grace[p] = now() + 3
			CharacterService:WarpToCFrame(p, cf, "rift", function()
				rt.grace[p] = now() + 1.5
			end)
		end)
	end
	print(string.format("[PF][Rift] run %s launched in slot %d seed %d with %d explorer(s), %d stones, %d fragments, secondaries: %s", runId, slot, seed, #members, #layout.stones, #layout.fragments, table.concat(layout.secondaries, ",")))
	setPortalAttrs()
end

----------------------------------------------------------------------------------------------------
-- public entry points
function RiftService:Request(p: Player, opts: any?): (boolean, string)
	opts = opts or {}
	if not ProfileService:IsReady(p) then
		return false, "NOT_READY"
	end
	if playerRun[p] then
		if forming and table.find(forming.members, p) then
			return true, "ALREADY_IN_LOBBY"
		end
		return false, "ALREADY_ACTIVE"
	end
	local r = root(p)
	if not r then
		return false, "NOT_READY"
	end
	if not opts.skipPortal then
		if not portalPart or (r.Position - portalPart.Position).Magnitude > RiftConfig.PORTAL_RADIUS then
			return false, "OUT_OF_RANGE"
		end
	end
	local active = 0
	for _ in slotTaken do
		active += 1
	end
	if forming then
		if #forming.members >= RiftConfig.MAX_PLAYERS then
			return false, "LOBBY_FULL"
		end
		table.insert(forming.members, p)
	else
		if active >= RiftConfig.MAX_RUNS then
			return false, "BUSY"
		end
		forming = { members = { p }, endsAt = now() + RiftConfig.LOBBY_SECONDS }
	end
	playerRun[p] = "forming"
	sendLobby()
	return true, "OK"
end

function RiftService:GetRun(p: Player): any
	local id = playerRun[p]
	return id and runtimes[id] and runtimes[id].run
end

----------------------------------------------------------------------------------------------------
-- per-tick processing
local function zoneMembers(rt: RT, center: Vector3, radius: number, vertical: number): { number }
	local out = {}
	for p in rt.players do
		local r = root(p)
		if r then
			local d = r.Position - center
			if Vector3.new(d.X, 0, d.Z).Magnitude <= radius and d.Y > -2 and d.Y < vertical then
				table.insert(out, p.UserId)
			end
		end
	end
	return out
end

local function applyEvents(rt: RT)
	local run = rt.run
	for _, e in RiftRules.drainEvents(run) do
		local k = e.kind
		if k == "node_done" then
			local n = rt.h.nodes[e.node]
			if n then
				n.crystal.Color = RiftBuilder.COLORS.cyan
				n.ring.Color = RiftBuilder.COLORS.cyan
				n.light.Color = RiftBuilder.COLORS.cyan
				n.light.Brightness = 3
				local py = rt.h.pylons[e.node]
				if py then
					py.part.Color = RiftBuilder.COLORS.cyan
					local beam = Instance.new("Beam")
					beam.Attachment0 = n.att
					beam.Attachment1 = py.att
					beam.Color = ColorSequence.new(RiftBuilder.COLORS.cyan, RiftBuilder.COLORS.violet)
					beam.Width0, beam.Width1 = 1.2, 0.6
					beam.LightEmission = 1
					beam.FaceCamera = true
					beam.Transparency = NumberSequence.new(0.2)
					beam.Parent = n.crystal
				end
			end
		elseif k == "final_open" then
			for _, sw in rt.h.sweepers do
				if sw.final then
					sw.active = true
					sw.part.Transparency = 0
					sw.part.CanTouch = true
				end
			end
			rt.h.chamber.core.Color = RiftBuilder.COLORS.violet
		elseif k == "core_sealed" then
			for _, sw in rt.h.sweepers do
				if sw.final then
					sw.active = false
					sw.part.Transparency = 1
					sw.part.CanTouch = false
				end
			end
			rt.h.chamber.core.Color = RiftBuilder.COLORS.cyan
			for _, d in rt.h.exit:GetDescendants() do
				if d:IsA("BasePart") then
					d.Transparency = d:GetAttribute("t0") or 0
				elseif d:IsA("ParticleEmitter") or d:IsA("Light") then
					(d :: any).Enabled = true
				end
			end
		elseif k == "escaped" then
			local p = Players:GetPlayerByUserId(e.userId)
			if p and rt.players[p] then
				grantRewards(p, rt)
				detach(p, rt, "escaped", true)
			end
		elseif k == "ended" then
			-- failure / abandon: partial rewards for whoever is still inside, then everyone goes home
			for p in rt.players do
				grantRewards(p, rt)
			end
			rt.teardownAt = now()
		end
		-- feedback to every member
		for p in rt.players do
			event(p, k, e)
		end
	end
end

local function processRun(rt: RT, dt: number, t: number)
	local run = rt.run
	local S = RiftConfig.SECURITY
	local inArena = {}
	for p in rt.players do
		local r = root(p)
		if not r then
			continue
		end
		local pos = r.Position
		local rel = pos - rt.origin
		local horiz = Vector3.new(rel.X, 0, rel.Z).Magnitude
		local inside = math.abs(rel.Y) < RiftConfig.FIELD_HALF.Y and horiz < RiftConfig.FIELD_HALF.X
		-- left the arena without the server moving them (e.g. a warp request): they abandon the run
		if not inside and (rt.grace[p] or 0) < t then
			rt.outside[p] = (rt.outside[p] or 0) + dt
			if rt.outside[p] > 3 then
				RiftRules.removeMember(run, p.UserId, t)
				detach(p, rt, "left_arena", false)
			end
			continue
		end
		rt.outside[p] = 0
		if inside then
			inArena[p.UserId] = true
		end
		-- void / bounds: back to the team checkpoint
		if rel.Y < -RiftConfig.KILL_DEPTH or horiz > RiftConfig.BOUNDS_RADIUS then
			RiftRules.fall(run, p.UserId)
			legitPlace(rt, p, checkpointCf(rt, p))
			continue
		end
		-- speed / teleport check
		local last = rt.lastPos[p]
		if last and (rt.grace[p] or 0) < t then
			local d = pos - last
			local hSpeed = Vector3.new(d.X, 0, d.Z).Magnitude
			local up = d.Y
			if hSpeed > S.maxSpeed * dt + S.tolerance or up > S.maxSpeed * dt + S.tolerance then
				rt.violations[p] = (rt.violations[p] or 0) + 1
				warn(string.format("[PF][Rift] movement violation %s (%.0f studs in %.2fs) #%d", p.Name, d.Magnitude, dt, rt.violations[p]))
				if rt.violations[p] >= S.maxViolations then
					RiftRules.removeMember(run, p.UserId, t)
					detach(p, rt, "removed_movement", true)
					continue
				end
				legitPlace(rt, p, rt.lastValid[p] or checkpointCf(rt, p))
				continue
			end
		end
		rt.lastPos[p] = pos
		if r.AssemblyLinearVelocity.Y > -5 and math.abs(r.AssemblyLinearVelocity.Y) < 30 then
			rt.lastValid[p] = r.CFrame
		end
		-- escape portal
		if run.phase == "escape" then
			local exitCenter = rt.h.chamber.center + Vector3.new(0, 4, 0)
			local d = pos - exitCenter
			if Vector3.new(d.X, 0, d.Z).Magnitude <= RiftConfig.EXIT.radius + 3 and d.Y < 16 then
				RiftRules.escape(run, p.UserId, t)
			end
		end
		-- hidden prism proximity (backup for missed touches)
		if rt.h.prism and (pos - rt.h.prism.Position).Magnitude < 5 and RiftRules.prism(run, p.UserId) then
			rt.h.prism:Destroy()
			rt.h.prism = nil
		end
	end
	local zones: any = { inArena = inArena }
	if run.phase == "active" then
		local n = rt.h.nodes[run.nodeIndex]
		if n then
			zones.node = zoneMembers(rt, n.center, RiftConfig.NODE.radius, 12)
		end
	elseif run.phase == "final" then
		zones.chamber = zoneMembers(rt, rt.h.chamber.center, RiftConfig.FINAL.radius, 14)
	end
	if rt.h.relayPads[1] and rt.h.relayPads[2] then
		zones.padA = #zoneMembers(rt, rt.h.relayPads[1].center, RiftConfig.RELAY.radius, 8) > 0
		zones.padB = #zoneMembers(rt, rt.h.relayPads[2].center, RiftConfig.RELAY.radius, 8) > 0
	end
	RiftRules.tick(run, dt, t, zones)
	-- current node highlight
	for i, n in rt.h.nodes do
		if i == run.nodeIndex and run.phase == "active" then
			n.crystal.Color = RiftBuilder.COLORS.magenta
			n.ring.Color = RiftBuilder.COLORS.magenta
		end
	end
	applyEvents(rt)
	if t - rt.lastBroadcast >= 0.5 or run.phase == "ended" then
		rt.lastBroadcast = t
		local st = RiftRules.publicState(run, t, rt.origin)
		for p in rt.players do
			remotes.State:FireClient(p, st)
		end
	end
	if rt.teardownAt or (run.phase ~= "ended" and next(rt.players) == nil) then
		if run.phase ~= "ended" then
			RiftRules.finish(run, t, "abandoned")
		end
		teardown(rt)
	end
end

-- intruders: a character inside an arena it is not a member of goes back to the station
local function sweepIntruders()
	for _, p in Players:GetPlayers() do
		local r = root(p)
		if not r or (leftAt[p] and now() - leftAt[p] < 3) then
			continue
		end
		for slot, runId in slotTaken do
			local o = RiftConfig.arenaOrigin(slot)
			local rel = r.Position - o
			if math.abs(rel.Y) < RiftConfig.FIELD_HALF.Y and Vector3.new(rel.X, 0, rel.Z).Magnitude < RiftConfig.FIELD_HALF.X then
				local rt = runtimes[runId]
				if not rt or not rt.players[p] then
					warn("[PF][Rift] intruder in arena slot " .. slot .. ": " .. p.Name)
					CharacterService:PlaceAt(p, stationArrival())
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
function RiftService:Init()
	remotes.State = RemoteGuard.getRemote("Expedition_State")
	remotes.Event = RemoteGuard.getRemote("Expedition_Event")
end

function RiftService:Start()
	-- station portal
	task.spawn(function()
		local world = Workspace:WaitForChild("PF_World", 30)
		local station = world and world:WaitForChild("Station", 30)
		local portalModel = station and station:FindFirstChild("RiftPortal", true)
		local surface = portalModel and portalModel:FindFirstChild("RiftSurface") :: BasePart?
		if not surface then
			warn("[PF][Rift] station RiftPortal not found; expeditions unavailable")
			return
		end
		portalPart = surface
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "PF_RiftPrompt"
		prompt.ActionText = "Enter the Rift"
		prompt.ObjectText = RiftConfig.NAME
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 16
		prompt.RequiresLineOfSight = false
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.Parent = surface
		prompt.Triggered:Connect(function(p)
			local ok, code = RiftService:Request(p)
			if not ok and code ~= "ALREADY_IN_LOBBY" then
				event(p, "error", { text = code })
			end
		end)
		setPortalAttrs()
	end)

	RemoteGuard.bind("Expedition_Start", function(p, payload)
		return RiftService:Request(p)
	end)
	RemoteGuard.bind("Expedition_Action", function(p, payload)
		local action = payload.action
		if action == "launch" then
			if forming and table.find(forming.members, p) then
				forming.endsAt = math.min(forming.endsAt, now())
				return true, "OK"
			end
			return false, "NOT_IN_LOBBY"
		elseif action == "leave" then
			if not playerRun[p] then
				return false, "NOT_IN_RUN"
			end
			leaveRun(p, "left", true)
			return true, "OK"
		elseif action == "restart" then
			local last = lastResult[p.UserId]
			if not last or now() - last.endedAt > RiftConfig.RESTART_WINDOW then
				return false, "NO_RECENT_RUN"
			end
			return RiftService:Request(p, { skipPortal = true })
		elseif action == "home" then
			if playerRun[p] then
				return false, "IN_RUN"
			end
			local slot = PlanetSlotService:GetSlot(p)
			if not slot then
				return false, "NO_PLANET"
			end
			local code = CharacterService:WarpTo(p, slot)
			return code == "OK", code
		end
		return false, "INVALID_PAYLOAD"
	end)
	RemoteGuard.bind("Expedition_Claim", function(p, payload)
		-- Rewards are granted server-side at escape (exactly once). Claim returns the stored summary; repeating it
		-- never grants anything again.
		local last = lastResult[p.UserId]
		if not last or (payload.runId ~= nil and payload.runId ~= last.runId) then
			return false, "NOT_FOUND"
		end
		return true, "OK", { summary = last.summary, alreadyGranted = true }
	end)

	CharacterService.SpawnOverride = function(p: Player): CFrame?
		local id = playerRun[p]
		local rt = id and runtimes[id]
		if rt and rt.players[p] and rt.run.phase ~= "ended" then
			rt.grace[p] = now() + 2
			local cf = checkpointCf(rt, p)
			rt.lastValid[p] = cf
			rt.lastPos[p] = cf.Position
			return cf
		end
		return nil
	end

	Players.PlayerRemoving:Connect(function(p)
		leaveRun(p, "disconnect", false)
		lastResult[p.UserId] = nil
		leftAt[p] = nil
	end)
	local function watchDeaths(p: Player)
		p.CharacterAdded:Connect(function(char)
			local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
			if hum then
				hum.Died:Connect(function()
					local id = playerRun[p]
					local rt = id and runtimes[id]
					if rt and rt.players[p] then
						RiftRules.fall(rt.run, p.UserId)
					end
				end)
			end
		end)
	end
	for _, p in Players:GetPlayers() do
		watchDeaths(p)
	end
	Players.PlayerAdded:Connect(watchDeaths)

	-- main loops
	local acc, spinAcc, intruderAcc = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt)
		local t = now()
		-- lobby
		if forming then
			for i = #forming.members, 1, -1 do
				local p = forming.members[i]
				local r = root(p)
				if p.Parent ~= Players or not r or (portalPart and (r.Position - portalPart.Position).Magnitude > RiftConfig.PORTAL_RADIUS * 3) then
					leaveRun(p, "walked_away", false)
					if not forming then
						break
					end
				end
			end
			if forming and t >= forming.endsAt then
				launch()
			end
		end
		spinAcc += dt
		if spinAcc >= 1 / 20 then
			local sdt = spinAcc
			spinAcc = 0
			for _, rt in runtimes do
				for _, sw in rt.h.sweepers do
					if sw.active then
						sw.angle += sw.speed * sdt
						sw.part.CFrame = CFrame.new(sw.center) * CFrame.Angles(0, sw.angle, 0)
					end
				end
				for _, sp in rt.h.spinners do
					local rate = sp:GetAttribute("spin") or 0
					if rate ~= 0 and sp.PrimaryPart == nil then
						local pivot = sp:GetPivot()
						sp:PivotTo(pivot * CFrame.Angles(0, 0, rate * sdt))
					end
				end
			end
		end
		acc += dt
		if acc >= 1 / RiftConfig.SECURITY.sampleHz then
			local sdt = acc
			acc = 0
			for _, rt in runtimes do
				local ok, err = pcall(processRun, rt, sdt, t)
				if not ok then
					warn("[PF][Rift] run error:", err)
				end
			end
		end
		intruderAcc += dt
		if intruderAcc >= 1 then
			intruderAcc = 0
			sweepIntruders()
		end
	end)

	-- Studio-only test hook (server tests run in a separate VM)
	if RunService:IsStudio() then
		local hook = ServerStorage:FindFirstChild("PF_RiftHook") or Instance.new("BindableFunction")
		hook.Name = "PF_RiftHook"
		hook.Archivable = false;
		(hook :: BindableFunction).OnInvoke = function(cmd: string, a: any, b: any)
			local p = if typeof(a) == "Instance" then a :: Player else nil
			if cmd == "start" and p then
				return RiftService:Request(p, { skipPortal = true })
			elseif cmd == "launch" then
				if forming then
					forming.endsAt = now()
				end
				return true
			elseif cmd == "tp" and p then
				local rt = runtimes[playerRun[p] or ""]
				if rt then
					legitPlace(rt, p, CFrame.new(b))
					return true
				end
				return false
			elseif cmd == "run" and p then
				local rt = runtimes[playerRun[p] or ""]
				if not rt then
					return nil
				end
				local nodes = {}
				for i, n in rt.h.nodes do
					nodes[i] = n.center
				end
				local frags = {}
				for id, f in rt.h.fragments do
					if f.Parent then
						frags[id] = f.Position
					end
				end
				return { state = RiftRules.publicState(rt.run, now(), rt.origin), nodes = nodes, chamber = rt.h.chamber.center, fragments = frags, prism = rt.h.prism and rt.h.prism.Position, pads = { rt.h.relayPads[1] and rt.h.relayPads[1].center, rt.h.relayPads[2] and rt.h.relayPads[2].center }, slot = rt.slot, origin = rt.origin, parts = #rt.h.folder:GetDescendants(), violations = rt.violations[p] or 0 }
			elseif cmd == "timeLimit" and p then
				local rt = runtimes[playerRun[p] or ""]
				if rt then
					rt.run.endsAt = now() + (b or 2)
				end
				return true
			elseif cmd == "last" and p then
				return lastResult[p.UserId]
			elseif cmd == "status" then
				local n = 0
				for _ in runtimes do
					n += 1
				end
				return { runs = n, forming = forming and #forming.members or 0 }
			end
			return nil
		end
		hook.Parent = ServerStorage
	end
end

return RiftService
