--!strict
-- RiftLayout — owner: Mission Systems. PURE, deterministic layout generator for THE FRACTURED NEBULA.
-- generate(seed, players) -> Layout (local coordinates, arena origin = 0,0,0). Varies per seed:
-- node sites + activation order, stepping-stone paths, hazard placement, fragment spots, secondary objectives,
-- hidden prism islet, resonance pads, decoration. Same seed -> same layout (server builds it, tests verify it).
local RiftConfig = require(script.Parent.RiftConfig)

local RiftLayout = {}

export type Stone = { pos: Vector3, size: Vector3, yaw: number, hazard: string, segment: number, index: number, sweepSpeed: number? }
export type Layout = {
	seed: number,
	players: number,
	entry: Vector3,
	chamber: Vector3,
	nodes: { { id: number, site: number, pos: Vector3 } },
	stones: { Stone },
	fragments: { { id: number, pos: Vector3 } },
	secondaries: { string },
	prism: Vector3?,
	prismStones: { Stone },
	relayPads: { Vector3 },
	rocks: { { pos: Vector3, size: Vector3, rot: Vector3 } },
	crystals: { { pos: Vector3, height: number } },
}

local SITE_RADIUS = 150
local STEP = 15

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function RiftLayout.generate(seed: number, players: number): Layout
	local rng = Random.new(seed)
	players = math.clamp(players, 1, RiftConfig.MAX_PLAYERS)
	local entry = Vector3.new(0, 0, -175)
	local chamber = Vector3.new(0, 6, 35)

	-- node sites on a ring around the chamber; pick 3, random activation order
	local sites = {}
	local base = rng:NextNumber(0, math.pi * 2)
	for i = 0, 5 do
		local a = base + i * math.pi / 3 + rng:NextNumber(-0.12, 0.12)
		table.insert(sites, { site = i + 1, pos = chamber + Vector3.new(math.cos(a) * SITE_RADIUS, rng:NextNumber(-8, 10), math.sin(a) * SITE_RADIUS) })
	end
	for i = #sites, 2, -1 do
		local j = rng:NextInteger(1, i)
		sites[i], sites[j] = sites[j], sites[i]
	end
	local nodes = {}
	for i = 1, 3 do
		table.insert(nodes, { id = i, site = sites[i].site, pos = sites[i].pos })
	end

	-- secondaries
	local soloPool, coopPool = {}, {}
	for _, id in RiftConfig.SECONDARY_ORDER do
		local d = RiftConfig.SECONDARIES[id]
		if d.coop then
			table.insert(coopPool, id)
		else
			table.insert(soloPool, id)
		end
	end
	local function take(pool: { string }): string
		return table.remove(pool, rng:NextInteger(1, #pool))
	end
	local secondaries = {}
	if players >= 2 then
		table.insert(secondaries, take(coopPool))
		table.insert(secondaries, take(soloPool))
		table.insert(secondaries, take(soloPool))
	else
		table.insert(secondaries, take(soloPool))
		table.insert(secondaries, take(soloPool))
	end
	local has = {}
	for _, s in secondaries do
		has[s] = true
	end

	-- stepping-stone paths: entry -> N1 -> N2 -> N3 -> chamber (island edges, not centres)
	local stones: { Stone } = {}
	local points = { { pos = entry, r = 22 }, { pos = nodes[1].pos, r = 15 }, { pos = nodes[2].pos, r = 15 }, { pos = nodes[3].pos, r = 15 }, { pos = chamber, r = 26 } }
	local lastHazard = true
	for seg = 1, 4 do
		local a, b = points[seg], points[seg + 1]
		local dir = flat(b.pos - a.pos)
		local dist = dir.Magnitude
		local unit = dir.Unit
		local side = Vector3.new(-unit.Z, 0, unit.X)
		local from = a.pos + unit * a.r
		local to = b.pos - unit * b.r
		local span = (flat(to - from)).Magnitude
		local n = math.max(1, math.floor(span / STEP))
		for i = 1, n - 1 do
			local t = i / n
			local p = from:Lerp(to, t) + side * rng:NextNumber(-4, 4) + Vector3.new(0, rng:NextNumber(-1.2, 1.2), 0)
			local w = rng:NextNumber(11, 15)
			local hazard = "none"
			if i > 1 and i < n - 1 and not lastHazard then
				local roll = rng:NextNumber()
				if roll < RiftConfig.HAZARDS.crumbleChance then
					hazard = "crumble"
				elseif roll < RiftConfig.HAZARDS.crumbleChance + RiftConfig.HAZARDS.sweeperChance then
					hazard = "sweeper"
				end
			end
			lastHazard = hazard ~= "none"
			table.insert(stones, { pos = p, size = Vector3.new(w, 2.4, rng:NextNumber(11, 15)), yaw = rng:NextNumber(0, math.pi * 2), hazard = hazard, segment = seg, index = i, sweepSpeed = if hazard == "sweeper" then rng:NextNumber(RiftConfig.HAZARDS.sweeperSpeed[1], RiftConfig.HAZARDS.sweeperSpeed[2]) * (if rng:NextNumber() < 0.5 then -1 else 1) else nil })
		end
		local _ = dist
	end

	-- fragments: prefer safe stones, then crumble stones, then island rims; never on sweeper stones
	local total = RiftConfig.fragmentCount(players)
	local candidates = {}
	for _, s in stones do
		if s.hazard == "none" then
			table.insert(candidates, s.pos + Vector3.new(0, 4.2, 0))
		end
	end
	for _, s in stones do
		if s.hazard == "crumble" then
			table.insert(candidates, s.pos + Vector3.new(0, 4.2, 0))
		end
	end
	for i = #candidates, 2, -1 do
		local j = rng:NextInteger(1, i)
		candidates[i], candidates[j] = candidates[j], candidates[i]
	end
	local k = 0
	while #candidates < total do
		k += 1
		local nd = nodes[(k % 3) + 1]
		local a = rng:NextNumber(0, math.pi * 2)
		table.insert(candidates, nd.pos + Vector3.new(math.cos(a) * 10, 4.2, math.sin(a) * 10))
	end
	local fragments = {}
	for i = 1, total do
		table.insert(fragments, { id = i, pos = candidates[i] })
	end

	-- hidden prism: side islet off a mid-path stone (only when the objective is rolled)
	local prism, prismStones = nil, {}
	if has.prism then
		local midStones = {}
		for _, s in stones do
			if s.segment >= 2 and s.segment <= 3 and s.hazard == "none" then
				table.insert(midStones, s)
			end
		end
		local anchor = midStones[rng:NextInteger(1, math.max(1, #midStones))] or stones[1]
		local outward = flat(anchor.pos - chamber).Unit
		for i = 1, 2 do
			table.insert(prismStones, { pos = anchor.pos + outward * (STEP * i) + Vector3.new(0, i * 1.5, 0), size = Vector3.new(9, 2.4, 9), yaw = rng:NextNumber(0, 6.28), hazard = "none", segment = 9, index = i })
		end
		prism = anchor.pos + outward * (STEP * 3) + Vector3.new(0, 4.5 + 3, 0)
		table.insert(prismStones, { pos = anchor.pos + outward * (STEP * 3) + Vector3.new(0, 4.5, 0), size = Vector3.new(10, 2.4, 10), yaw = 0, hazard = "none", segment = 9, index = 3 })
	end

	-- resonance pads: on two different node islands (co-op task)
	local relayPads = {}
	if has.relay then
		for _, ni in { 1, 3 } do
			local nd = nodes[ni]
			local away = flat(nd.pos - chamber).Unit
			table.insert(relayPads, nd.pos + away * 9 + Vector3.new(0, 1.4, 0))
		end
	end

	-- decoration: shattered asteroid shell + energy crystals (non-colliding)
	local rocks = {}
	for _ = 1, 46 do
		local a = rng:NextNumber(0, math.pi * 2)
		local rr = rng:NextNumber(230, 360)
		local s = rng:NextNumber(8, 34)
		table.insert(rocks, { pos = Vector3.new(math.cos(a) * rr, rng:NextNumber(-90, 110), math.sin(a) * rr), size = Vector3.new(s, s * rng:NextNumber(0.5, 0.9), s * rng:NextNumber(0.6, 1)), rot = Vector3.new(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)) })
	end
	local crystals = {}
	for _ = 1, 14 do
		local a = rng:NextNumber(0, math.pi * 2)
		local rr = rng:NextNumber(60, 210)
		table.insert(crystals, { pos = Vector3.new(math.cos(a) * rr, rng:NextNumber(-60, -20), math.sin(a) * rr), height = rng:NextNumber(14, 34) })
	end

	return {
		seed = seed,
		players = players,
		entry = entry,
		chamber = chamber,
		nodes = nodes,
		stones = stones,
		fragments = fragments,
		secondaries = secondaries,
		prism = prism,
		prismStones = prismStones,
		relayPads = relayPads,
		rocks = rocks,
		crystals = crystals,
	}
end

return RiftLayout
