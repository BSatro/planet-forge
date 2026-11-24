--!strict
-- ShowerRules — owner: Live Gameplay. Pure Meteor Shower rules: bounded spawning per orbital zone, expiry, capture
-- validation (first come, range against the deterministic path, per-player cap) and reward rolls.
-- The runtime passes positions and time; this module never touches Instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)
local ShowerMath = require(ReplicatedStorage.PF_Shared.Events.ShowerMath)

local ShowerRules = {}

export type Zone = { zone: number, near: { Vector3 } }

function ShowerRules.new(instanceId: string, seed: number): any
	return {
		id = instanceId,
		rng = Random.new(seed),
		meteors = {} :: { [string]: ShowerMath.Meteor },
		alive = 0,
		perZone = {} :: { [number]: number },
		gone = {} :: { [string]: string },
		captures = {} :: { [number]: number },
		total = 0,
		captured = 0,
		n = 0,
		closed = false,
	}
end

local function drop(st: any, m: ShowerMath.Meteor, why: string)
	st.meteors[m.id] = nil
	st.alive -= 1
	st.perZone[m.zone] = math.max(0, (st.perZone[m.zone] or 1) - 1)
	st.gone[m.id] = why
end

function ShowerRules.expire(st: any, now: number): { string }
	local out = {}
	for _, m in st.meteors do
		if now > m.t0 + m.life then
			drop(st, m, "expired")
			table.insert(out, m.id)
		end
	end
	return out
end

-- One spawn pass: at most one new meteor per zone, at most SHOWER.perPass in total, never above the per-zone
-- and server caps. Zones with the fewest meteors are served first.
function ShowerRules.spawnPass(st: any, now: number, zones: { Zone }): { ShowerMath.Meteor }
	local S = EventConfig.SHOWER
	local made = {}
	if st.closed or #zones == 0 then
		return made
	end
	local order = table.clone(zones)
	for i = #order, 2, -1 do
		local j = st.rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	table.sort(order, function(a, b)
		return (st.perZone[a.zone] or 0) < (st.perZone[b.zone] or 0)
	end)
	for _, z in order do
		if #made >= S.perPass or st.alive >= S.maxTotal then
			break
		end
		if (st.perZone[z.zone] or 0) < S.maxPerZone then
			st.n += 1
			local id = string.format("%s-%d", st.id, st.n)
			local near: Vector3? = nil
			if #z.near > 0 and st.rng:NextNumber() < S.planet.nearChance then
				near = z.near[st.rng:NextInteger(1, #z.near)]
			end
			local m = ShowerMath.plan(id, z.zone, now, st.rng, near, st.rng:NextNumber() < S.rareChance)
			st.meteors[id] = m
			st.alive += 1
			st.perZone[z.zone] = (st.perZone[z.zone] or 0) + 1
			st.total += 1
			table.insert(made, m)
		end
	end
	return made
end

local MATERIAL_ORDER: { string } = {}
for id in EventConfig.SHOWER.materials do
	table.insert(MATERIAL_ORDER, id)
end
table.sort(MATERIAL_ORDER)

function ShowerRules.rollReward(st: any, m: ShowerMath.Meteor): any
	local S = EventConfig.SHOWER
	local total = 0
	for _, id in MATERIAL_ORDER do
		total += S.materials[id]
	end
	local roll = st.rng:NextNumber() * total
	local pick = MATERIAL_ORDER[#MATERIAL_ORDER]
	for _, id in MATERIAL_ORDER do
		roll -= S.materials[id]
		if roll <= 0 then
			pick = id
			break
		end
	end
	local amt = if m.rare then st.rng:NextInteger(S.rareAmount[1], S.rareAmount[2]) else st.rng:NextInteger(S.amount[1], S.amount[2])
	return { materials = { [pick] = amt }, credits = if m.rare then S.rareCredits else 0, xp = S.xpPerCapture, rare = m.rare }
end

-- First valid capture wins. rootPos = the capturer's character root (server-sampled).
function ShowerRules.capture(st: any, userId: number, id: any, now: number, rootPos: Vector3?): (boolean, string, any?, ShowerMath.Meteor?)
	local S = EventConfig.SHOWER
	if st.closed then
		return false, "ENDED", nil, nil
	end
	if type(id) ~= "string" then
		return false, "INVALID_PAYLOAD", nil, nil
	end
	local m = st.meteors[id]
	if not m then
		local g = st.gone[id]
		return false, if g == "captured" then "TAKEN" elseif g == "expired" then "EXPIRED" else "NOT_FOUND", nil, nil
	end
	if now > m.t0 + m.life then
		drop(st, m, "expired")
		return false, "EXPIRED", nil, nil
	end
	if (st.captures[userId] or 0) >= S.perPlayerCap then
		return false, "CAP_REACHED", nil, nil
	end
	if not rootPos then
		return false, "NO_CHARACTER", nil, nil
	end
	local limit = S.captureRange + S.rangeTolerance
	local d1 = (ShowerMath.position(m, now) - rootPos).Magnitude
	local d2 = (ShowerMath.position(m, now - S.lagWindow) - rootPos).Magnitude
	if math.min(d1, d2) > limit then
		return false, "OUT_OF_RANGE", nil, nil
	end
	drop(st, m, "captured")
	st.captures[userId] = (st.captures[userId] or 0) + 1
	st.captured += 1
	return true, "OK", ShowerRules.rollReward(st, m), m
end

function ShowerRules.capturesLeft(st: any, userId: number): number
	return math.max(0, EventConfig.SHOWER.perPlayerCap - (st.captures[userId] or 0))
end

-- Alive meteors in network form (late joiners / resync). Bounded by SHOWER.maxTotal.
function ShowerRules.list(st: any, now: number): { any }
	local out = {}
	for _, m in st.meteors do
		if now <= m.t0 + m.life then
			table.insert(out, ShowerMath.encode(m))
		end
	end
	return out
end

function ShowerRules.close(st: any)
	st.closed = true
	table.clear(st.meteors)
	st.alive = 0
	table.clear(st.perZone)
end

return ShowerRules
