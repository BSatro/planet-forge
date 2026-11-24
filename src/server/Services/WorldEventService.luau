--!strict
-- WorldEventService — owner: Live Gameplay. COSMIC WORLD EVENTS, server-authoritative:
--   scheduler (EventScheduler: cooldowns, concurrency cap, channel compatibility) -> per event: incoming (announced)
--   -> active -> ending (wrap-up) -> cleanup. Three events:
--     MeteorShower       bounded meteors in occupied orbital zones; first valid capture wins; matter granted instantly
--     SolarStorm         energy reactions completed during the storm refund part of their matter (capped per player)
--     CosmicConvergence  co-op reactor stabilization at THE FORGE (conduits + flux cells); fair contribution rewards,
--                        kept for participants who left and granted when they rejoin this server
-- Rules: no forced teleports, nothing touches player planets, every reward goes through EconomyService exactly once
-- (granted keys), clients only send intent (capture a meteor id / sync), presentation is client-side.
-- Replication: ReplicatedStorage.PF_WorldEvents/<EventId> (Configuration attributes, late joiners get them for free),
--   Event_Notify (server -> client feedback), Event_Action (client -> server: capture / sync).
-- Studio only: ServerStorage.PF_EventHook (BindableFunction test hook) and the Event_Dev remote (developer panel).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.PF_Shared
local EventConfig = require(Shared.Events.EventConfig)
local ShowerMath = require(Shared.Events.ShowerMath)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local WorldLayout = require(Shared.Config.WorldLayout)
local Signal = require(Shared.Util.Signal)
local Server = script.Parent.Parent
local EventScheduler = require(Server.Events.EventScheduler)
local ShowerRules = require(Server.Events.ShowerRules)
local StormRules = require(Server.Events.StormRules)
local ConvergenceRules = require(Server.Events.ConvergenceRules)
local ConvergenceRig = require(Server.Events.ConvergenceRig)
local RemoteGuard = require(Server.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local EconomyService = require(script.Parent.EconomyService)
local EvolutionService = require(script.Parent.EvolutionService)
local RiftService = require(script.Parent.RiftService)

local WorldEventService = {}
WorldEventService.EventAnnounced = Signal.new() -- (eventId, instanceId)
WorldEventService.EventActivated = Signal.new() -- (eventId, instanceId)
WorldEventService.EventEnded = Signal.new() -- (eventId, instanceId, outcome)
-- (player, instanceId, rewardKey) after an event reward was granted (quests: "took part in this event")
WorldEventService.RewardGranted = Signal.new()

type Inst = {
	id: string,
	eventId: string,
	def: any,
	phase: string,
	phaseEndsAt: number,
	activeAt: number,
	endsAt: number,
	duration: number,
	outcome: string?,
	node: Configuration,
	data: any,
	errors: number,
}

local PREFIX = { MeteorShower = "MS", SolarStorm = "SS", CosmicConvergence = "CC" }
local CV = EventConfig.CONVERGENCE
local REASON = if EconomyConfig.REASONS[EventConfig.REWARD_REASON] then EventConfig.REWARD_REASON else EventConfig.REWARD_REASON_FALLBACK

local rng = Random.new()
local sched: EventScheduler.State = nil :: any
local instances: { [string]: Inst } = {}
local folder: Folder = nil :: any
local eventsWorld: Folder = nil :: any
local notify: RemoteEvent = nil :: any
local granted: { [string]: boolean } = {}
local keyIndex: { [string]: { string } } = {} -- instance id -> its granted keys (pruned after the rejoin window)
local endedAt: { [string]: number } = {} -- instance id -> cleanup time
local pending: { [number]: { any } } = {}
local absent: { [Player]: boolean } = {} -- Studio test hook only: treat a present player as disconnected
local testMode = false
local counter = 0
local accumulator = 0
local lastPendingSweep = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function scale(): number
	return if testMode then EventConfig.SCHEDULER.testScale else 1
end

local function root(p: Player): BasePart?
	local c = p.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return nil
	end
	return c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function inRift(p: Player): boolean
	local ok, run = pcall(RiftService.GetRun, RiftService, p)
	return ok and run ~= nil
end

local function ready(p: Player): boolean
	return p.Parent ~= nil and not absent[p] and ProfileService:IsReady(p)
end

local function send(p: Player, kind: string, data: { [string]: any }?)
	local d = data or {}
	d.kind = kind
	notify:FireClient(p, d)
end

local function broadcast(kind: string, data: { [string]: any }?)
	local d = data or {}
	d.kind = kind
	notify:FireAllClients(d)
end

local function itemName(section: string, id: string): string
	local cat = if section == "catalysts" then ItemCatalog.CATALYSTS else ItemCatalog.MATERIALS
	local d = cat and cat[id]
	return (d and d.displayName) or id
end

local function setAttrs(inst: Inst, t: { [string]: any })
	for k, v in t do
		inst.node:SetAttribute(k, v)
	end
end

-- players that count for event scaling: loaded, not in a rift
local function eligiblePlayers(): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		if ready(p) and not inRift(p) then
			table.insert(out, p)
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- rewards (exactly once per key)

local function grant(p: Player, key: string, reward: any): (boolean, any)
	if granted[key] then
		return false, nil
	end
	granted[key] = true
	local iid = string.match(key, "^[^:]+") or key
	keyIndex[iid] = keyIndex[iid] or {}
	table.insert(keyIndex[iid], key)
	local out: any = { credits = 0, energy = 0, xp = 0, items = {} }
	local cur: any = {}
	if (reward.credits or 0) > 0 then
		cur.Credits = math.floor(reward.credits)
	end
	local energy = math.floor(reward.energy or 0)
	if energy > 0 then
		local cap = EconomyService:GetEnergyCap(p) or 0
		local have = EconomyService:GetBalance(p, "currencies", "CosmicEnergy") or 0
		energy = math.max(0, math.min(energy, cap - have))
		if energy > 0 then
			cur.CosmicEnergy = energy
		end
	end
	local tx: any = {}
	if next(cur) then
		tx.currencies = cur
	end
	if reward.materials and next(reward.materials) then
		tx.materials = table.clone(reward.materials)
	end
	if reward.catalysts and next(reward.catalysts) then
		tx.catalysts = table.clone(reward.catalysts)
	end
	local applied: any = tx
	if next(tx) then
		local ok, code, a = EconomyService:Transact(p, tx, REASON, { overflow = "clamp" })
		if ok then
			applied = a or tx
		else
			warn("[PF][Events] combined grant failed (" .. tostring(code) .. "), granting lines individually")
			for section, map in tx do
				for id, n in map do
					EconomyService:Grant(p, section, id, n, REASON)
				end
			end
		end
	end
	if (reward.xp or 0) > 0 then
		EconomyService:GrantXp(p, math.floor(reward.xp), REASON)
	end
	local ac = applied.currencies or {}
	out.credits = ac.Credits or 0
	out.energy = ac.CosmicEnergy or 0
	out.xp = math.floor(reward.xp or 0)
	for id, n in applied.materials or {} do
		if n > 0 then
			table.insert(out.items, { id = id, name = itemName("materials", id), amount = n, kind = if id == CV.rewards.componentId then "component" else "material" })
		end
	end
	for id, n in applied.catalysts or {} do
		if n > 0 then
			table.insert(out.items, { id = id, name = itemName("catalysts", id), amount = n, kind = "catalyst" })
		end
	end
	WorldEventService.RewardGranted:Fire(p, iid, key)
	return true, out
end

local function addTotals(totals: any, applied: any)
	totals.credits += applied.credits or 0
	totals.energy += applied.energy or 0
	totals.xp += applied.xp or 0
	for _, it in applied.items or {} do
		totals.items[it.id] = totals.items[it.id] or { id = it.id, name = it.name, amount = 0, kind = it.kind }
		totals.items[it.id].amount += it.amount
	end
end

local function newTotals(): any
	return { credits = 0, energy = 0, xp = 0, items = {}, count = 0 }
end

local function totalsOut(t: any): any
	local items = {}
	for _, it in t.items do
		table.insert(items, it)
	end
	return { credits = t.credits, energy = t.energy, xp = t.xp, items = items }
end

local function deliverPending(p: Player)
	local list = pending[p.UserId]
	if not list or not ready(p) then
		return
	end
	pending[p.UserId] = nil
	for _, e in list do
		if now() <= e.expiresAt then
			local ok, applied = grant(p, e.key, e.reward)
			if ok then
				if e.prior then -- already paid part of it when they left: show the full total
					local tt = newTotals()
					addTotals(tt, e.prior)
					addTotals(tt, applied)
					applied = totalsOut(tt)
				end
				e.summary.rewards = applied
				e.summary.late = true
				send(p, "summary", { summary = e.summary })
				print(string.format("[PF][Events] %s received pending %s rewards (%d credits)", p.Name, e.summary.name, applied.credits))
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Meteor Shower

local function showerZones(): { any }
	local byZone: { [number]: { Vector3 } } = {}
	for _, p in Players:GetPlayers() do
		local r = root(p)
		if r and ready(p) and not inRift(p) then
			local z = ShowerMath.zoneAt(r.Position)
			if z then
				byZone[z] = byZone[z] or {}
				table.insert(byZone[z], r.Position)
			end
		end
	end
	local zones = {}
	for z, list in byZone do
		table.insert(zones, { zone = z, near = list })
	end
	return zones
end

local function showerTick(inst: Inst, t: number)
	local d = inst.data
	ShowerRules.expire(d.shower, t)
	if t >= d.nextPass then
		d.nextPass = t + EventConfig.SHOWER.spawnInterval
		local made = ShowerRules.spawnPass(d.shower, t, showerZones())
		if #made > 0 then
			local enc = {}
			for _, m in made do
				table.insert(enc, ShowerMath.encode(m))
			end
			broadcast("meteors", { instanceId = inst.id, add = enc })
		end
		setAttrs(inst, { Alive = d.shower.alive, Captured = d.shower.captured })
	end
end

local function capture(p: Player, id: any): (boolean, string, any?)
	local inst = instances.MeteorShower
	if not inst or inst.phase ~= "active" then
		return false, "NOT_ACTIVE"
	end
	if inRift(p) then
		return false, "IN_RIFT"
	end
	local r = root(p)
	local t = now()
	local ok, code, reward, m = ShowerRules.capture(inst.data.shower, p.UserId, id, t, r and r.Position)
	if not ok or not m then
		return false, code
	end
	local pos = ShowerMath.position(m, t)
	broadcast("gone", { ids = { m.id }, by = p.UserId, pos = pos })
	local okG, applied = grant(p, inst.id .. ":" .. m.id, reward)
	if okG then
		local totals = inst.data.totals[p.UserId] or newTotals()
		inst.data.totals[p.UserId] = totals
		totals.count += 1
		addTotals(totals, applied)
	end
	setAttrs(inst, { Alive = inst.data.shower.alive, Captured = inst.data.shower.captured })
	return true, "OK", { id = m.id, gains = applied, rare = reward.rare, left = ShowerRules.capturesLeft(inst.data.shower, p.UserId), pos = pos }
end

----------------------------------------------------------------------------------------------------
-- Solar Storm

local function onReaction(player: Player, data: any)
	local inst = instances.SolarStorm
	if not inst or inst.phase ~= "active" or type(data) ~= "table" or not ready(player) then
		return
	end
	local def = ReactionRegistry.DEFS[data.reactionId]
	if not def then
		return
	end
	local ok, code, bonus = StormRules.apply(inst.data.storm, player.UserId, def)
	if not ok then
		if code == "CAP_REACHED" then
			send(player, "surgeCap", { name = def.name })
		end
		return
	end
	local okG, applied = grant(player, string.format("%s:%d:%s", inst.id, player.UserId, tostring(data.revision or data.completions or os.clock())), { credits = bonus.credits, materials = bonus.materials })
	if okG then
		local totals = inst.data.totals[player.UserId] or newTotals()
		inst.data.totals[player.UserId] = totals
		totals.count += 1
		addTotals(totals, applied)
		send(player, "surge", { reactionId = def.id, name = def.name, gains = applied, left = bonus.left })
	end
end

----------------------------------------------------------------------------------------------------
-- Cosmic Convergence

local function publishConvergence(inst: Inst)
	local run = inst.data.run
	local top = ConvergenceRules.top(run, 5)
	local parts = {}
	for _, e in top do
		local clean = string.gsub(e.name :: string, "[:;]", "")
		table.insert(parts, string.format("%s:%d", clean, e.points))
	end
	local unstable = 0
	for _, c in inst.data.rig.conduits do
		if c.state == "unstable" then
			unstable += 1
		end
	end
	setAttrs(inst, {
		Progress = run.progress,
		Target = run.target,
		Stage = run.stage,
		Participants = #run.order,
		Top = table.concat(parts, ";"),
		Unstable = unstable,
		Cells = #inst.data.rig.cells,
	})
end

local finish: (Inst, string) -> ()

local function applyRunEvents(inst: Inst)
	local run = inst.data.run
	for _, ev in ConvergenceRules.drain(run) do
		if ev.kind == "stage" then
			ConvergenceRig.setStage(inst.data.rig, ev.stage)
			broadcast("stage", { eventId = inst.eventId, stage = ev.stage })
		elseif ev.kind == "sync" then
			local a, b = Players:GetPlayerByUserId(ev.a), Players:GetPlayerByUserId(ev.b)
			if a and b then
				send(a, "sync", { with = b.DisplayName, points = CV.points.sync })
				send(b, "sync", { with = a.DisplayName, points = CV.points.sync })
			end
		elseif ev.kind == "completed" then
			finish(inst, "completed")
			return
		end
	end
	inst.data.dirty = true
end

local function myPoints(inst: Inst, p: Player): number
	local e = inst.data.run.contributions[p.UserId]
	return e and e.points or 0
end

local function dropCarry(inst: Inst, p: Player, why: string?)
	local d = inst.data
	local c = d.carriers[p]
	if not c then
		return
	end
	d.carriers[p] = nil
	if c.orb then
		c.orb:Destroy()
	end
	if p.Parent then
		p:SetAttribute("PFConvCarrying", nil)
		if why then
			send(p, "hint", { text = why })
		end
	end
	d.nextCellAt = math.min(d.nextCellAt, now() + CV.flux.respawn)
end

local function near(p: Player, pos: Vector3, dist: number): boolean
	local r = root(p)
	return r ~= nil and (r.Position - pos).Magnitude <= dist
end

local function onConduit(inst: Inst, i: number, p: Player)
	if inst.phase ~= "active" or not ready(p) or inRift(p) then
		return
	end
	local d = inst.data
	local c = d.rig.conduits[i]
	if not c or not near(p, c.pos + Vector3.new(0, 3, 0), CV.promptDistance + 6) then
		return
	end
	local t = now()
	if c.state == "unstable" then
		c.stabilizedBy = p.UserId
		c.stabilizedAt = t
		c.stableUntil = t + CV.conduitCooldown
		c.unstableAt = nil
		ConvergenceRig.setConduit(d.rig, i, "stable")
		local ok, _, pts = ConvergenceRules.contribute(d.run, p.UserId, p.DisplayName, "calibrate", t)
		if ok then
			send(p, "task", { task = "calibrate", points = pts, total = myPoints(inst, p) })
		end
	elseif c.stabilizedBy ~= p.UserId and t - c.stabilizedAt <= CV.assistWindow then
		local ok, _, pts = ConvergenceRules.contribute(d.run, p.UserId, p.DisplayName, "assist", t)
		if ok then
			send(p, "task", { task = "assist", points = pts, total = myPoints(inst, p) })
		end
	else
		send(p, "hint", { text = "That conduit is already stable — look for a flickering one." })
	end
	applyRunEvents(inst)
end

local function onPickup(inst: Inst, cell: any, p: Player)
	if inst.phase ~= "active" or not ready(p) or inRift(p) or cell.taken then
		return
	end
	local d = inst.data
	if d.carriers[p] then
		send(p, "hint", { text = "You are already carrying a flux cell." })
		return
	end
	if not near(p, cell.pos, CV.flux.pickupDistance + 6) then
		return
	end
	ConvergenceRig.removeCell(d.rig, cell)
	local t = now()
	d.carriers[p] = { deadline = t + CV.flux.carryTime, orb = ConvergenceRig.attachCarry(d.rig, p.Character), spot = cell.spot }
	d.lastSpot = cell.spot
	p:SetAttribute("PFConvCarrying", true)
	d.nextCellAt = t + CV.flux.respawn
	send(p, "task", { task = "pickup", deadline = t + CV.flux.carryTime })
	d.dirty = true
end

local function onInject(inst: Inst, p: Player)
	if inst.phase ~= "active" or not ready(p) then
		return
	end
	local d = inst.data
	if not d.carriers[p] then
		send(p, "hint", { text = "Collect a flux cell from the plaza rim first." })
		return
	end
	if not near(p, d.rig.intake.Position, CV.flux.intakeDistance + 6) then
		return
	end
	dropCarry(inst, p, nil)
	local ok, _, pts = ConvergenceRules.contribute(d.run, p.UserId, p.DisplayName, "deliver", now())
	if ok then
		send(p, "task", { task = "deliver", points = pts, total = myPoints(inst, p) })
	end
	applyRunEvents(inst)
end

local function atStationCount(): number
	local n = 0
	local c = WorldLayout.STATION_CENTER
	for _, p in Players:GetPlayers() do
		local r = root(p)
		if r and ready(p) and (r.Position - c).Magnitude <= CV.stationRadius then
			n += 1
		end
	end
	return n
end

local function spawnCellIfNeeded(inst: Inst, t: number)
	local d = inst.data
	local rig = d.rig
	local carried = 0
	for _ in d.carriers do
		carried += 1
	end
	local want = math.clamp(1 + math.floor((math.max(1, atStationCount()) - 1) / CV.flux.perPlayers), 1, CV.flux.maxActive)
	if #rig.cells + carried >= want or t < d.nextCellAt or #rig.spots == 0 then
		return
	end
	local used = {}
	for _, cell in rig.cells do
		used[cell.spot] = true
	end
	local free = {}
	for i in rig.spots do
		if not used[i] and i ~= d.lastSpot then
			table.insert(free, i)
		end
	end
	if #free == 0 then
		return
	end
	local spot = free[rng:NextInteger(1, #free)]
	local cell = ConvergenceRig.spawnCell(rig, spot)
	cell.prompt.Triggered:Connect(function(p: Player)
		onPickup(inst, cell, p)
	end)
	d.nextCellAt = t + 1
	d.dirty = true
end

local function convergenceTick(inst: Inst, t: number)
	local d = inst.data
	local rig = d.rig
	-- players leaving the server (or entering rifts) lower the target; joiners never raise it
	local n = #eligiblePlayers()
	if n < d.minEligible then
		d.minEligible = n
		ConvergenceRules.updatePlayers(d.run, n)
		applyRunEvents(inst)
		if inst.phase ~= "active" then
			return
		end
	end
	-- conduits: keep 1 + floor(players at the station / 2) unstable
	local want = math.clamp(1 + math.floor(atStationCount() / 2), 1, #rig.conduits)
	local unstable, scheduled = 0, 0
	for _, c in rig.conduits do
		if c.state == "unstable" then
			unstable += 1
		elseif c.unstableAt then
			scheduled += 1
		end
	end
	for _, c in rig.conduits do
		if unstable + scheduled >= want then
			break
		end
		if c.state == "stable" and not c.unstableAt and t >= c.stableUntil then
			c.unstableAt = t + CV.unstableDelay[1] + (CV.unstableDelay[2] - CV.unstableDelay[1]) * rng:NextNumber()
			scheduled += 1
		end
	end
	for i, c in rig.conduits do
		if c.unstableAt and t >= c.unstableAt then
			c.unstableAt = nil
			ConvergenceRig.setConduit(rig, i, "unstable")
			d.dirty = true
		end
	end
	-- carried cells expire / are dropped on death, rift entry or leaving
	for p, c in d.carriers do
		if not p.Parent or not root(p) or inRift(p) or absent[p] then
			dropCarry(inst, p, if p.Parent then "Your flux cell was lost." else nil)
		elseif t > c.deadline then
			dropCarry(inst, p, "Your flux cell destabilized — collect a new one.")
		end
	end
	spawnCellIfNeeded(inst, t)
	if d.dirty and t - d.lastPublish >= 0.5 then
		d.dirty = false
		d.lastPublish = t
		publishConvergence(inst)
	end
end

-- What is still owed after a participant was already paid on leaving (never negative, never twice).
local function remainder(reward: any, prior: any): any
	local r = table.clone(reward)
	r.credits = math.max(0, (reward.credits or 0) - (prior.credits or 0))
	r.energy = math.max(0, (reward.energy or 0) - (prior.energy or 0))
	r.xp = math.max(0, (reward.xp or 0) - (prior.xp or 0))
	local mats, cats = table.clone(reward.materials or {}), table.clone(reward.catalysts or {})
	for _, it in prior.items or {} do
		local t = if it.kind == "catalyst" then cats else mats
		if t[it.id] then
			t[it.id] = math.max(0, t[it.id] - it.amount)
			if t[it.id] == 0 then
				t[it.id] = nil
			end
		end
	end
	r.materials, r.catalysts = mats, cats
	return r
end

local function sumApplied(a: any, b: any): any
	local t = newTotals()
	addTotals(t, a)
	addTotals(t, b)
	return totalsOut(t)
end

-- A Cosmic Convergence participant is LEAVING (profile releasing / server shutting down): pay what their
-- contribution has earned so far (the same rule as a timed-out event at this moment) while their profile can
-- still be written, so leaving never forfeits a fair reward. If they return to this server before the end they
-- only receive the difference (finalizeConvergence), so nothing is ever paid twice.
local function settleLeaver(p: Player)
	local inst = instances.CosmicConvergence
	if not inst or inst.phase ~= "active" or not inst.data.run or not inst.data.paid then
		return
	end
	local run = inst.data.run
	if not run.contributions[p.UserId] or inst.data.paid[p.UserId] then
		return
	end
	local eligible, reward = ConvergenceRules.rewardsFor(run, p.UserId)
	if not eligible then
		return
	end
	local ok, applied = grant(p, inst.id .. ":" .. p.UserId .. ":left", reward)
	if ok then
		inst.data.paid[p.UserId] = applied
		print(string.format("[PF][Events] %s left during %s: settled %d credits, %d xp (share %.2f, x%.2f)", p.Name, inst.id, applied.credits, applied.xp, reward.share, reward.mult))
	end
end

local function finalizeConvergence(inst: Inst, outcome: string)
	local d = inst.data
	local run = d.run
	ConvergenceRules.close(run, now())
	for p in table.clone(d.carriers) do
		dropCarry(inst, p, nil)
	end
	ConvergenceRig.setAllStable(d.rig)
	ConvergenceRig.setStage(d.rig, run.stage, if outcome == "completed" then "completed" else "failed")
	publishConvergence(inst)
	for _, uid in run.order do
		local e = run.contributions[uid]
		local eligible, reward = ConvergenceRules.rewardsFor(run, uid)
		local summary: any = {
			eventId = inst.eventId,
			instanceId = inst.id,
			name = inst.def.name,
			outcome = outcome,
			progress = run.progress,
			target = run.target,
			points = e.points,
			tasks = e.tasks,
			share = if eligible then reward.share else 0,
			eligible = eligible,
			reason = if eligible then nil else reward,
			rewards = { credits = 0, energy = 0, xp = 0, items = {} },
		}
		local p = Players:GetPlayerByUserId(uid)
		if eligible then
			local key = inst.id .. ":" .. uid
			local prior = d.paid and d.paid[uid]
			local owed = if prior then remainder(reward, prior) else reward
			if prior then
				summary.settledOnLeave = true
				summary.rewards = prior
			end
			if p and ready(p) then
				local ok, applied = grant(p, key, owed)
				if ok then
					summary.rewards = if prior then sumApplied(prior, applied) else applied
					print(string.format("[PF][Events] %s convergence reward: %d credits, %d energy, %d xp (share %.2f)%s", p.Name, applied.credits, applied.energy, applied.xp, reward.share, if prior then " (top-up after leaving)" else ""))
				end
				send(p, "summary", { summary = summary })
			elseif not granted[key] then
				pending[uid] = pending[uid] or {}
				table.insert(pending[uid], { key = key, reward = owed, prior = prior, summary = summary, expiresAt = now() + CV.pendingTtl })
				print(string.format("[PF][Events] convergence reward for absent participant %d kept for %ds%s", uid, CV.pendingTtl, if prior then " (remainder after the leave settlement)" else ""))
			end
		elseif p and p.Parent then
			send(p, "summary", { summary = summary })
		end
	end
end

local function sendTotalsSummaries(inst: Inst, label: string)
	for uid, totals in inst.data.totals do
		local p = Players:GetPlayerByUserId(uid)
		if p and p.Parent and totals.count > 0 then
			send(p, "summary", { summary = { eventId = inst.eventId, instanceId = inst.id, name = inst.def.name, outcome = "completed", count = totals.count, countLabel = label, eligible = true, alreadyGranted = true, rewards = totalsOut(totals) } })
		end
	end
end

----------------------------------------------------------------------------------------------------
-- lifecycle

local function activate(inst: Inst)
	local t = now()
	inst.phase = "active"
	inst.activeAt = t
	inst.endsAt = t + inst.duration
	inst.phaseEndsAt = inst.endsAt
	inst.data.totals = {}
	if inst.eventId == "MeteorShower" then
		inst.data.shower = ShowerRules.new(inst.id, rng:NextInteger(1, 2 ^ 30))
		inst.data.nextPass = t
		setAttrs(inst, { Alive = 0, Captured = 0, CapturePerPlayer = EventConfig.SHOWER.perPlayerCap })
	elseif inst.eventId == "SolarStorm" then
		inst.data.storm = StormRules.new()
		setAttrs(inst, { Boosted = table.concat(StormRules.boostedIds(ReactionRegistry), ","), RefundPct = math.floor(EventConfig.STORM.refundShare * 100), MaxSurges = EventConfig.STORM.maxSurges })
	elseif inst.eventId == "CosmicConvergence" then
		local n = #eligiblePlayers()
		inst.data.run = ConvergenceRules.new(inst.id, n, t)
		inst.data.paid = {} -- uid -> applied settlement of participants who left mid-event
		inst.data.minEligible = math.max(1, n)
		inst.data.carriers = {}
		inst.data.nextCellAt = t + 1
		inst.data.lastPublish = 0
		inst.data.dirty = true
		local rig = ConvergenceRig.build(eventsWorld)
		inst.data.rig = rig
		for i, c in rig.conduits do
			c.prompt.Triggered:Connect(function(p: Player)
				onConduit(inst, i, p)
			end)
		end
		rig.intakePrompt.Triggered:Connect(function(p: Player)
			onInject(inst, p)
		end)
		publishConvergence(inst)
	end
	setAttrs(inst, { Phase = "active", PhaseEndsAt = inst.phaseEndsAt, ActiveAt = inst.activeAt, EndsAt = inst.endsAt })
	broadcast("started", { eventId = inst.eventId, instanceId = inst.id })
	print(string.format("[PF][Events] %s %s active for %ds", inst.eventId, inst.id, math.floor(inst.duration)))
	WorldEventService.EventActivated:Fire(inst.eventId, inst.id)
end

finish = function(inst: Inst, outcome: string)
	if inst.phase == "ending" then
		return
	end
	local wasActive = inst.phase == "active"
	inst.phase = "ending"
	inst.outcome = outcome
	inst.phaseEndsAt = now() + EventConfig.SCHEDULER.ending
	if wasActive then
		local ok, err = pcall(function()
			if inst.eventId == "MeteorShower" then
				ShowerRules.close(inst.data.shower)
				sendTotalsSummaries(inst, "meteors captured")
			elseif inst.eventId == "SolarStorm" then
				sendTotalsSummaries(inst, "solar surges")
			elseif inst.eventId == "CosmicConvergence" then
				finalizeConvergence(inst, outcome)
			end
		end)
		if not ok then
			warn("[PF][Events] finalize failed for " .. inst.id .. ": " .. tostring(err))
		end
	end
	setAttrs(inst, { Phase = "ending", PhaseEndsAt = inst.phaseEndsAt, Outcome = outcome })
	broadcast("ended", { eventId = inst.eventId, instanceId = inst.id, outcome = outcome })
	print(string.format("[PF][Events] %s %s ended (%s)", inst.eventId, inst.id, outcome))
	WorldEventService.EventEnded:Fire(inst.eventId, inst.id, outcome)
end

local function cleanup(inst: Inst)
	if inst.data.rig then
		ConvergenceRig.destroy(inst.data.rig)
		inst.data.rig = nil
	end
	if inst.data.carriers then
		for p, c in inst.data.carriers do
			if c.orb then
				c.orb:Destroy()
			end
			if p.Parent then
				p:SetAttribute("PFConvCarrying", nil)
			end
		end
		table.clear(inst.data.carriers)
	end
	if inst.data.shower then
		ShowerRules.close(inst.data.shower)
	end
	inst.node:Destroy()
	if instances[inst.eventId] == inst then
		instances[inst.eventId] = nil
	end
	endedAt[inst.id] = now()
	EventScheduler.markEnded(sched, inst.eventId, now())
end

function WorldEventService:StartEvent(eventId: string, opts: any?): (boolean, string, string?)
	local o = opts or {}
	local okStart, code = EventScheduler.canStart(sched, eventId, now(), o.force == true)
	if not okStart then
		return false, code, nil
	end
	counter += 1
	local def = EventConfig.get(eventId)
	local id = string.format("%s%d", PREFIX[eventId] or "EV", counter)
	local t = now()
	local incoming = if o.skipIncoming then 0 else EventConfig.SCHEDULER.incoming * scale()
	local duration = if type(o.duration) == "number" then o.duration else def.duration * scale()
	local node = Instance.new("Configuration")
	node.Name = eventId
	local inst: Inst = { id = id, eventId = eventId, def = def, phase = "incoming", phaseEndsAt = t + incoming, activeAt = t + incoming, endsAt = t + incoming + duration, duration = duration, outcome = nil, node = node, data = {}, errors = 0 }
	node:SetAttribute("EventId", eventId)
	node:SetAttribute("InstanceId", id)
	node:SetAttribute("Name", def.name)
	node:SetAttribute("Phase", "incoming")
	node:SetAttribute("PhaseEndsAt", inst.phaseEndsAt)
	node:SetAttribute("ActiveAt", inst.activeAt)
	node:SetAttribute("EndsAt", inst.endsAt)
	node:SetAttribute("Outcome", "")
	node.Parent = folder
	instances[eventId] = inst
	EventScheduler.markStarted(sched, eventId)
	broadcast("incoming", { eventId = eventId, instanceId = id, activeAt = inst.activeAt })
	print(string.format("[PF][Events] %s %s announced (active in %ds)", eventId, id, math.floor(incoming)))
	WorldEventService.EventAnnounced:Fire(eventId, id)
	if incoming <= 0 then
		activate(inst)
	end
	return true, "OK", id
end

function WorldEventService:EndEvent(eventId: string, outcome: string?): (boolean, string)
	local inst = instances[eventId]
	if not inst then
		return false, "NOT_ACTIVE"
	end
	if inst.phase == "incoming" then
		finish(inst, "cancelled")
	else
		finish(inst, outcome or (if eventId == "CosmicConvergence" then "timeout" else "completed"))
	end
	return true, "OK"
end

function WorldEventService:IsActive(eventId: string): boolean
	local inst = instances[eventId]
	return inst ~= nil and inst.phase == "active"
end

function WorldEventService:GetActive(): { any }
	local out = {}
	for id, inst in instances do
		table.insert(out, { eventId = id, instanceId = inst.id, phase = inst.phase, endsAt = inst.endsAt, phaseEndsAt = inst.phaseEndsAt })
	end
	return out
end

function WorldEventService:SetTestMode(on: boolean)
	testMode = on
	EventScheduler.setScale(sched, scale(), now())
	folder:SetAttribute("TestMode", on)
end

local function tick()
	local t = now()
	for _, inst in table.clone(instances) do
		local ok, err = pcall(function()
			if inst.phase == "incoming" then
				if t >= inst.phaseEndsAt then
					activate(inst)
				end
			elseif inst.phase == "active" then
				if inst.eventId == "MeteorShower" then
					showerTick(inst, t)
				elseif inst.eventId == "CosmicConvergence" then
					convergenceTick(inst, t)
				end
				if inst.phase == "active" and t >= inst.endsAt then
					finish(inst, if inst.eventId == "CosmicConvergence" then "timeout" else "completed")
				end
			elseif inst.phase == "ending" and t >= inst.phaseEndsAt then
				cleanup(inst)
			end
		end)
		if not ok then
			inst.errors += 1
			warn(string.format("[PF][Events] %s tick error #%d: %s", inst.id, inst.errors, tostring(err)))
			if inst.errors >= 5 then
				-- never leave a broken event (and its objects) behind
				pcall(finish, inst, "failed")
				pcall(cleanup, inst)
				instances[inst.eventId] = nil
			end
		end
	end
	local pick = EventScheduler.decide(sched, t, #eligiblePlayers(), rng)
	if pick then
		WorldEventService:StartEvent(pick)
	end
	if t - lastPendingSweep > 30 then
		lastPendingSweep = t
		for uid, list in pending do
			for i = #list, 1, -1 do
				if t > list[i].expiresAt then
					table.remove(list, i)
				end
			end
			if #list == 0 then
				pending[uid] = nil
			end
		end
		-- forget the granted keys of long-finished events (no pending reward can reference them any more)
		for iid, at in endedAt do
			if t - at > CV.pendingTtl + 60 then
				for _, key in keyIndex[iid] or {} do
					granted[key] = nil
				end
				keyIndex[iid] = nil
				endedAt[iid] = nil
			end
		end
	end
end

-- What a (re)connecting client needs beyond the replicated attributes.
local function syncFor(p: Player): any
	local t = now()
	local out: any = { serverNow = t, testMode = testMode, mine = {} }
	local sh = instances.MeteorShower
	if sh and sh.phase == "active" and sh.data.shower then
		out.meteors = ShowerRules.list(sh.data.shower, t)
		out.mine.capturesLeft = ShowerRules.capturesLeft(sh.data.shower, p.UserId)
	end
	local ss = instances.SolarStorm
	if ss and ss.phase == "active" and ss.data.storm then
		out.mine.surgesLeft = StormRules.surgesLeft(ss.data.storm, p.UserId)
	end
	local cc = instances.CosmicConvergence
	if cc and cc.phase == "active" and cc.data.run then
		out.mine.points = myPoints(cc, p)
		out.mine.carrying = cc.data.carriers[p] ~= nil
	end
	return out
end

----------------------------------------------------------------------------------------------------
function WorldEventService:Init()
	folder = ReplicatedStorage:FindFirstChild("PF_WorldEvents") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PF_WorldEvents"
		folder.Parent = ReplicatedStorage
	end
	folder:SetAttribute("TestMode", false)
	folder:SetAttribute("Version", EventConfig.VERSION)
	eventsWorld = Instance.new("Folder")
	eventsWorld.Name = "PF_Events"
	eventsWorld.Parent = Workspace
	notify = RemoteGuard.getRemote("Event_Notify")
	sched = EventScheduler.new(now(), rng, 1)
end

function WorldEventService:Start()
	EvolutionService.ReactionCompleted:Connect(onReaction)
	ProfileService.ProfileLoaded:Connect(function(p: Player)
		task.defer(deliverPending, p)
	end)
	-- last chance to write the leaving player's profile (also runs for everyone on server shutdown)
	ProfileService.ProfileReleasing:Connect(function(p: Player)
		local ok, err = pcall(settleLeaver, p)
		if not ok then
			warn("[PF][Events] leave settlement failed: " .. tostring(err))
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		local cc = instances.CosmicConvergence
		if cc and cc.data.carriers then
			dropCarry(cc, p, nil)
		end
		absent[p] = nil
	end)
	RemoteGuard.bind("Event_Action", function(p: Player, payload: any)
		if not ready(p) then
			return false, "NOT_READY"
		end
		local action = payload.action
		if action == "capture" then
			return capture(p, payload.id)
		elseif action == "sync" then
			return true, "OK", syncFor(p)
		end
		return false, "INVALID_PAYLOAD"
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		local step = 1 / EventConfig.SCHEDULER.tickRate
		if accumulator >= step then
			accumulator = 0
			tick()
		end
	end)

	if RunService:IsStudio() then
		-- developer test panel (client F3) — bound ONLY in Studio
		RemoteGuard.bind("Event_Dev", function(_p: Player, payload: any)
			local a = payload.action
			if a == "start" and type(payload.eventId) == "string" then
				return WorldEventService:StartEvent(payload.eventId, { force = true, skipIncoming = payload.skipIncoming == true })
			elseif a == "stop" and type(payload.eventId) == "string" then
				return WorldEventService:EndEvent(payload.eventId, nil)
			elseif a == "testMode" then
				WorldEventService:SetTestMode(payload.value == true)
				return true, "OK"
			elseif a == "scheduler" then
				sched.enabled = payload.value == true
				return true, "OK"
			end
			return false, "INVALID_PAYLOAD"
		end)
		local hook = ServerStorage:FindFirstChild("PF_EventHook") or Instance.new("BindableFunction")
		hook.Name = "PF_EventHook"
		hook.Archivable = false;
		(hook :: BindableFunction).OnInvoke = function(cmd: string, a: any, b: any, c: any)
			local p = if typeof(a) == "Instance" and a:IsA("Player") then a else nil
			if cmd == "start" then
				return WorldEventService:StartEvent(a, b or { force = true })
			elseif cmd == "stop" then
				return WorldEventService:EndEvent(a, b)
			elseif cmd == "testMode" then
				WorldEventService:SetTestMode(a == true)
				return true
			elseif cmd == "scheduler" then
				sched.enabled = a == true
				return true
			elseif cmd == "next" then
				sched.nextAt = now() + (a or 0)
				return true
			elseif cmd == "status" then
				local pend = 0
				for _, l in pending do
					pend += #l
				end
				return { active = WorldEventService:GetActive(), nextIn = sched.nextAt - now(), testMode = testMode, scheduler = sched.enabled, pending = pend, now = now() }
			elseif cmd == "state" then
				local inst = instances[a]
				if not inst then
					return nil
				end
				local d = inst.data
				local s: any = { id = inst.id, phase = inst.phase, endsAt = inst.endsAt, outcome = inst.outcome }
				if d.shower then
					s.alive, s.total, s.captured = d.shower.alive, d.shower.total, d.shower.captured
					s.captures = table.clone(d.shower.captures)
					s.meteors = {}
					for id, m in d.shower.meteors do
						s.meteors[id] = { pos = ShowerMath.position(m, now()), zone = m.zone, rare = m.rare }
					end
				end
				if d.storm then
					s.surges = table.clone(d.storm.surges)
				end
				if d.run then
					s.progress, s.target, s.stage, s.completed = d.run.progress, d.run.target, d.run.stage, d.run.completed
					s.contributions = {}
					for uid, e in d.run.contributions do
						s.contributions[uid] = table.clone(e)
					end
					if d.rig then
						s.conduits = {}
						for i, cd in d.rig.conduits do
							s.conduits[i] = { state = cd.state, pos = cd.pos }
						end
						s.cells = {}
						for _, cell in d.rig.cells do
							table.insert(s.cells, cell.pos)
						end
						s.intake = d.rig.intake.Position
						s.parts = #d.rig.folder:GetDescendants()
					end
					s.carriers = 0
					for _ in d.carriers do
						s.carriers += 1
					end
				end
				return s
			elseif cmd == "capture" and p then
				return capture(p, b)
			elseif cmd == "conduit" and p then
				local inst = instances.CosmicConvergence
				if inst then
					onConduit(inst, b, p)
				end
				return true
			elseif cmd == "pickup" and p then
				local inst = instances.CosmicConvergence
				local cell = inst and inst.data.rig and inst.data.rig.cells[b or 1]
				if cell then
					onPickup(inst :: Inst, cell, p)
				end
				return cell ~= nil
			elseif cmd == "inject" and p then
				local inst = instances.CosmicConvergence
				if inst then
					onInject(inst, p)
				end
				return true
			elseif cmd == "absent" and p then
				absent[p] = b == true or nil
				return true
			elseif cmd == "leave" and p then
				-- simulate a real departure: the leave settlement (ProfileReleasing) + absence from the server
				settleLeaver(p)
				absent[p] = true
				return true
			elseif cmd == "keys" then
				local n, idx = 0, 0
				for _ in granted do
					n += 1
				end
				for _ in keyIndex do
					idx += 1
				end
				return { granted = n, instances = idx }
			elseif cmd == "rejoin" and p then
				absent[p] = nil
				deliverPending(p)
				return true
			elseif cmd == "reaction" and p then
				-- simulate Developer B's ReactionCompleted for a reaction id (storm bonus path only; no DNA change)
				onReaction(p, { reactionId = b, revision = c or math.random(1, 1e9) })
				return true
			elseif cmd == "granted" then
				local n = 0
				for _ in granted do
					n += 1
				end
				return n
			end
			return nil
		end
		hook.Parent = ServerStorage
	end
end

return WorldEventService
