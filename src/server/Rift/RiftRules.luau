--!strict
-- RiftRules — owner: Mission Systems. PURE server rules for one Cosmic Rift run (no Instances, no services):
-- objective order (fragments -> node 1 -> 2 -> 3 -> core -> escape), co-op scaling, secondaries, timeout,
-- participation and reward rolls. RiftService feeds it validated observations; tests drive it with mock members.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RiftConfig = require(ReplicatedStorage.PF_Shared.Rift.RiftConfig)

local Rules = {}

export type Member = { userId: number, name: string, fragments: number, falls: number, activeTime: number, present: boolean, escaped: boolean, joinedAt: number }

local function event(run: any, kind: string, data: { [string]: any }?)
	local e = data or {}
	e.kind = kind
	table.insert(run.events, e)
end

function Rules.new(runId: string, seed: number, layout: any, members: { { userId: number, name: string } }, now: number): any
	local run: any = {
		id = runId,
		seed = seed,
		layout = layout,
		phase = "active",
		outcome = nil,
		startedAt = now,
		endsAt = now + RiftConfig.TIME_LIMIT,
		endedAt = nil,
		players = #members,
		cost = RiftConfig.nodeCost(#members),
		total = #layout.fragments,
		members = {},
		pool = 0,
		collected = {},
		collectedCount = 0,
		nodeIndex = 1,
		nodesDone = 0,
		nodeProgress = 0,
		finalProgress = 0,
		escapeAt = nil,
		falls = 0,
		prismFound = false,
		relayHeld = 0,
		syncSeen = false,
		checkpoint = 0,
		sec = {},
		events = {},
		lastNeedEvent = 0,
	}
	for _, m in members do
		run.members[m.userId] = { userId = m.userId, name = m.name, fragments = 0, falls = 0, activeTime = 0, present = true, escaped = false, joinedAt = now }
	end
	for _, id in layout.secondaries do
		run.sec[id] = "pending"
	end
	return run
end

function Rules.isMember(run: any, uid: number): boolean
	local m = run.members[uid]
	return m ~= nil and m.present
end

function Rules.presentCount(run: any): number
	local n = 0
	for _, m in run.members do
		if m.present then
			n += 1
		end
	end
	return n
end

-- fragment pickup (server already verified touch/distance)
function Rules.collect(run: any, uid: number, fragId: number): (boolean, string)
	if run.phase == "ended" then
		return false, "ENDED"
	end
	if not Rules.isMember(run, uid) then
		return false, "NOT_MEMBER"
	end
	if run.collected[fragId] then
		return false, "TAKEN"
	end
	if fragId < 1 or fragId > run.total then
		return false, "INVALID"
	end
	run.collected[fragId] = uid
	run.collectedCount += 1
	run.pool += 1
	run.members[uid].fragments += 1
	event(run, "fragment", { userId = uid, pool = run.pool, collected = run.collectedCount })
	return true, "OK"
end

function Rules.fall(run: any, uid: number)
	local m = run.members[uid]
	if not m or run.phase == "ended" then
		return
	end
	m.falls += 1
	run.falls += 1
	if run.sec.flawless == "pending" then
		run.sec.flawless = "failed"
		event(run, "secondary_failed", { id = "flawless" })
	end
	event(run, "fall", { userId = uid })
end

function Rules.prism(run: any, uid: number): boolean
	if run.prismFound or run.sec.prism == nil or not Rules.isMember(run, uid) then
		return false
	end
	run.prismFound = true
	run.sec.prism = "done"
	event(run, "secondary_done", { id = "prism", userId = uid })
	return true
end

local finalizeSecondaries: (any) -> ()

-- zones = { node = {uid...}, chamber = {uid...}, padA = bool, padB = bool, inArena = { [uid] = true } }
function Rules.tick(run: any, dt: number, now: number, zones: any)
	if run.phase == "ended" then
		return
	end
	for uid in zones.inArena or {} do
		local m = run.members[uid]
		if m and m.present then
			m.activeTime += dt
		end
	end
	-- co-op relay
	if run.sec.relay == "pending" then
		if zones.padA and zones.padB then
			run.relayHeld += dt
			if run.relayHeld >= RiftConfig.RELAY.hold then
				run.sec.relay = "done"
				event(run, "secondary_done", { id = "relay" })
			end
		else
			run.relayHeld = math.max(0, run.relayHeld - dt * 2)
		end
	end
	if run.phase == "active" then
		local inside = zones.node or {}
		if #inside > 0 then
			if run.pool >= run.cost then
				local speed = math.min(RiftConfig.NODE.maxSpeedup, 1 + RiftConfig.NODE.coopBonus * (#inside - 1))
				run.nodeProgress += dt / RiftConfig.NODE.channel * speed
				if #inside >= 2 then
					run.syncSeen = true
				end
				if run.nodeProgress >= 1 then
					run.pool -= run.cost
					run.nodesDone += 1
					run.checkpoint = run.nodeIndex
					event(run, "node_done", { node = run.nodeIndex })
					if run.sec.sync == "pending" and run.syncSeen then
						run.sec.sync = "done"
						event(run, "secondary_done", { id = "sync" })
					end
					run.syncSeen = false
					run.nodeIndex += 1
					run.nodeProgress = 0
					if run.nodesDone >= 3 then
						run.phase = "final"
						event(run, "final_open", {})
					end
				end
			elseif now - run.lastNeedEvent > 3 then
				run.lastNeedEvent = now
				event(run, "need_fragments", { need = run.cost - run.pool })
			end
		else
			run.nodeProgress = math.max(0, run.nodeProgress - dt / RiftConfig.NODE.channel * RiftConfig.NODE.decay)
			run.syncSeen = false
		end
	elseif run.phase == "final" then
		local inside = zones.chamber or {}
		if #inside > 0 then
			local speed = math.min(RiftConfig.NODE.maxSpeedup, 1 + RiftConfig.NODE.coopBonus * (#inside - 1))
			run.finalProgress += dt / RiftConfig.FINAL.channel * speed
			if run.finalProgress >= 1 then
				run.finalProgress = 1
				run.phase = "escape"
				run.checkpoint = 4
				run.escapeAt = now + RiftConfig.ESCAPE_SECONDS
				if run.sec.swift == "pending" then
					run.sec.swift = if now - run.startedAt <= RiftConfig.SWIFT_TIME then "done" else "failed"
				end
				-- secondaries are final once the core is sealed: rewards can be granted at each explorer's escape
				finalizeSecondaries(run)
				event(run, "core_sealed", {})
			end
		else
			run.finalProgress = math.max(0, run.finalProgress - dt / RiftConfig.FINAL.channel * RiftConfig.NODE.decay)
		end
	elseif run.phase == "escape" then
		if run.escapeAt and now >= run.escapeAt then
			for uid, m in run.members do
				if m.present and not m.escaped then
					Rules.escape(run, uid, now)
				end
			end
		end
	end
	if (run.phase == "active" or run.phase == "final") and now >= run.endsAt then
		Rules.finish(run, now, "failed")
	end
end

function finalizeSecondaries(run: any)
	if run.sec.flawless == "pending" then
		run.sec.flawless = if run.falls == 0 then "done" else "failed"
	end
	if run.sec.collector == "pending" then
		run.sec.collector = if run.collectedCount >= run.total then "done" else "failed"
	end
	for id, st in run.sec do
		if st == "pending" then
			run.sec[id] = "failed"
		end
	end
end

function Rules.escape(run: any, uid: number, now: number): boolean
	local m = run.members[uid]
	if run.phase ~= "escape" or not m or not m.present or m.escaped then
		return false
	end
	m.escaped = true
	event(run, "escaped", { userId = uid })
	local all = true
	for _, mm in run.members do
		if mm.present and not mm.escaped then
			all = false
		end
	end
	if all then
		Rules.finish(run, now, "completed")
	end
	return true
end

function Rules.finish(run: any, now: number, outcome: string)
	if run.phase == "ended" then
		return
	end
	if outcome == "completed" then
		finalizeSecondaries(run)
	else
		for id, st in run.sec do
			if st == "pending" then
				run.sec[id] = "failed"
			end
		end
	end
	run.phase = "ended"
	run.outcome = outcome
	run.endedAt = now
	event(run, "ended", { outcome = outcome })
end

function Rules.removeMember(run: any, uid: number, now: number)
	local m = run.members[uid]
	if not m then
		return
	end
	m.present = false
	event(run, "left", { userId = uid })
	if run.phase == "escape" then
		-- the remaining explorers may already all be out
		local all, any = true, false
		for _, mm in run.members do
			if mm.present then
				any = true
				if not mm.escaped then
					all = false
				end
			end
		end
		if any and all then
			Rules.finish(run, now, "completed")
		end
	end
	if Rules.presentCount(run) == 0 and run.phase ~= "ended" then
		Rules.finish(run, now, "abandoned")
	end
end

function Rules.secondariesDone(run: any): number
	local n = 0
	for _, st in run.sec do
		if st == "done" then
			n += 1
		end
	end
	return n
end

local function hash(a: number, b: number): number
	local h = (a % 2147483647) * 31 + b
	h = (h * 1103515245 + 12345) % 2147483647
	return h
end

-- Server-authoritative reward roll for one member. Returns (eligible, reward) where reward =
-- { credits, energy, xp, catalysts = {[id]=n}, materials = {[id]=n}, lines = { text } }
function Rules.rewardsFor(run: any, uid: number): (boolean, any)
	local m = run.members[uid]
	if not m then
		return false, "NOT_MEMBER"
	end
	if run.phase ~= "ended" and run.phase ~= "escape" then
		return false, "NOT_ENDED"
	end
	local R = RiftConfig.REWARDS
	if run.phase == "ended" and run.outcome ~= "completed" then
		local credits = R.failCreditsPerNode * run.nodesDone
		if credits <= 0 or m.activeTime < RiftConfig.MIN_ACTIVE_SECONDS then
			return false, "NO_REWARD"
		end
		return true, { credits = credits, energy = 0, xp = 0, catalysts = {}, materials = {}, lines = { string.format("Partial stabilization: %d node(s)", run.nodesDone) } }
	end
	if not m.escaped then
		return false, "NOT_ESCAPED"
	end
	if m.activeTime < RiftConfig.MIN_ACTIVE_SECONDS then
		return false, "NOT_ENOUGH_PARTICIPATION"
	end
	local rng = Random.new(hash(run.seed, uid))
	local sec = Rules.secondariesDone(run)
	local coop = 1 + math.min(R.coopBonusMax, R.coopBonusPerExtra * (run.players - 1))
	local credits = math.floor(math.min(R.credits.max, R.credits.base + R.credits.perSecondary * sec + R.credits.perFragment * m.fragments) * coop + 0.5)
	local reward = { credits = credits, energy = R.energy.base + R.energy.perSecondary * sec, xp = math.floor((R.xp.base + R.xp.perSecondary * sec) * coop + 0.5), catalysts = {}, materials = {}, lines = {} }
	if coop > 1 then
		table.insert(reward.lines, string.format("Co-op bonus +%d%%", math.round((coop - 1) * 100)))
	end
	local chance = math.min(R.catalystChance.max, R.catalystChance.base + R.catalystChance.perSecondary * sec)
	if rng:NextNumber() < chance then
		local id = R.catalysts[rng:NextInteger(1, #R.catalysts)]
		reward.catalysts[id] = 1
	end
	if run.prismFound or rng:NextNumber() < R.componentChance then
		reward.materials[R.componentId] = (reward.materials[R.componentId] or 0) + 1
		table.insert(reward.lines, if run.prismFound then "Nebula Prism recovered: rift component" else "Rare rift component found")
	end
	if rng:NextNumber() < R.cacheChance then
		local id = R.cacheMaterials[rng:NextInteger(1, #R.cacheMaterials)]
		reward.materials[id] = (reward.materials[id] or 0) + rng:NextInteger(R.cacheAmount[1], R.cacheAmount[2])
		table.insert(reward.lines, "Matter cache recovered")
	end
	return true, reward
end

function Rules.publicState(run: any, now: number, origin: Vector3): any
	local team = {}
	for uid, m in run.members do
		if m.present then
			table.insert(team, { userId = uid, name = m.name, fragments = m.fragments, escaped = m.escaped })
		end
	end
	table.sort(team, function(a, b) return a.fragments > b.fragments end)
	local secs = {}
	for _, id in run.layout.secondaries do
		local d = RiftConfig.SECONDARIES[id]
		table.insert(secs, { id = id, name = d.name, text = d.text, state = run.sec[id] })
	end
	local nodes = {}
	for i, n in run.layout.nodes do
		table.insert(nodes, { id = i, pos = origin + n.pos, done = i <= run.nodesDone, current = i == run.nodeIndex and run.phase == "active" })
	end
	return {
		runId = run.id,
		phase = run.phase,
		outcome = run.outcome,
		elapsed = (run.endedAt or now) - run.startedAt,
		timeLeft = math.max(0, run.endsAt - now),
		escapeLeft = if run.escapeAt then math.max(0, run.escapeAt - now) else nil,
		nodeIndex = run.nodeIndex,
		nodesDone = run.nodesDone,
		nodeProgress = run.nodeProgress,
		finalProgress = run.finalProgress,
		pool = run.pool,
		cost = run.cost,
		collected = run.collectedCount,
		total = run.total,
		players = run.players,
		team = team,
		secondaries = secs,
		nodes = nodes,
		chamber = origin + run.layout.chamber,
		checkpoint = run.checkpoint,
	}
end

function Rules.drainEvents(run: any): { any }
	local e = run.events
	run.events = {}
	return e
end

return Rules
