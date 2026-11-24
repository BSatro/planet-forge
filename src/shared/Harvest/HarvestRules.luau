--!strict
-- HarvestRules — owner: Gameplay (Cosmic Core Hunt). The single definition of "did this shot capture".
-- Server: authoritative verification. Client: instant prediction (same inputs -> same answer).
--
-- A shot captures when, at fireTime:
--   1. the target is in flight (MeteorPath.evaluate ~= nil) and not phased out (Void),
--   2. it is within SHOT.MAX_RANGE of the turret origin,
--   3. the aim direction is within (AIM_CONE + focus bonus + upgrade bonus + RARITY aim bonus) of the target,
--      or inside its angular hitbox (radius + HITBOX_PAD + RARITY hitbox pad),
--   4. the resonance phase is inside the capture window (focus stacks open the window earlier);
--      inside the perfect band it is a "perfect" capture.
-- Positions come only from the server-authored spec at the (bounded) fireTime: no client positions, no
-- client-supplied history.

local HarvestConfig = require(script.Parent.Parent.Config.HarvestConfig)
local MeteorPath = require(script.Parent.MeteorPath)
local MeteorRegistry = require(script.Parent.MeteorRegistry)

export type ShotResult = {
	hit: boolean,
	reason: string, -- "CAPTURE" | "EXPIRED" | "MISS_PHASED" | "OUT_OF_RANGE" | "MISS_AIM" | "MISS_TIMING"
	quality: string?, -- "perfect" | "good"
	position: Vector3?, -- world position of the target at fireTime
	angleDeg: number?,
	allowedDeg: number?,
	phase: number?,
}

local HarvestRules = {}

function HarvestRules.phase(spec: any, t: number): number
	return ((t - spec.t0) / spec.period + spec.phase) % 1
end

-- Window start after focus bonus (never earlier than 0.05).
function HarvestRules.windowStart(spec: any, focusStacks: number?): number
	local stacks = math.clamp(focusStacks or 0, 0, HarvestConfig.FOCUS.MAX_STACKS)
	return math.max(0.05, spec.w0 - stacks * HarvestConfig.FOCUS.WINDOW_BONUS)
end

function HarvestRules.timingQuality(spec: any, t: number, focusStacks: number?): string?
	local p = HarvestRules.phase(spec, t)
	if p >= spec.p0 and p <= spec.p1 then
		return "perfect"
	end
	if p >= HarvestRules.windowStart(spec, focusStacks) and p <= spec.w1 then
		return "good"
	end
	return nil
end

function HarvestRules.allowedAngleDeg(spec: any, distance: number, focusStacks: number?, bonusDeg: number?): number
	local stacks = math.clamp(focusStacks or 0, 0, HarvestConfig.FOCUS.MAX_STACKS)
	local rarity = MeteorRegistry.rarity(spec.kind)
	local cone = HarvestConfig.SHOT.AIM_CONE_DEG + stacks * HarvestConfig.FOCUS.CONE_BONUS_DEG + (bonusDeg or 0) + rarity.aimBonusDeg
	local hitbox = math.deg(math.atan((spec.size * 0.5 + HarvestConfig.SHOT.HITBOX_PAD + rarity.hitboxPad) / math.max(distance, 1)))
	return math.max(cone, hitbox)
end

-- toWorld: harvester local -> world; origin: world turret origin; aim: world direction (any length > 0).
function HarvestRules.evaluateShot(spec: any, fireTime: number, toWorld: (Vector3) -> Vector3, origin: Vector3, aim: Vector3, focusStacks: number?, bonusDeg: number?): ShotResult
	local lp = MeteorPath.evaluate(spec, fireTime)
	if not lp then
		return { hit = false, reason = "EXPIRED" }
	end
	local wp = toWorld(lp)
	if MeteorPath.isPhased(spec, fireTime) then
		return { hit = false, reason = "MISS_PHASED", position = wp, phase = HarvestRules.phase(spec, fireTime) }
	end
	local to = wp - origin
	local dist = to.Magnitude
	if dist > HarvestConfig.SHOT.MAX_RANGE or dist < 1e-3 then
		return { hit = false, reason = "OUT_OF_RANGE", position = wp }
	end
	if aim.Magnitude < 1e-6 then
		return { hit = false, reason = "MISS_AIM", position = wp }
	end
	local cosA = math.clamp(aim.Unit:Dot(to / dist), -1, 1)
	local angle = math.deg(math.acos(cosA))
	local allowed = HarvestRules.allowedAngleDeg(spec, dist, focusStacks, bonusDeg)
	local phase = HarvestRules.phase(spec, fireTime)
	if angle > allowed then
		return { hit = false, reason = "MISS_AIM", position = wp, angleDeg = angle, allowedDeg = allowed, phase = phase }
	end
	local quality = HarvestRules.timingQuality(spec, fireTime, focusStacks)
	if not quality then
		return { hit = false, reason = "MISS_TIMING", position = wp, angleDeg = angle, allowedDeg = allowed, phase = phase }
	end
	return { hit = true, reason = "CAPTURE", quality = quality, position = wp, angleDeg = angle, allowedDeg = allowed, phase = phase }
end

-- Harvest context from the owner's planet (EvolutionRules view): which variants the planet attracts
-- (TARGET_TYPES[id].unlock = progression eligibility) and branch spawn-weight multipliers. Keys are canonical
-- variant ids; legacy aliases (e.g. Spore) mirror their variant so older callers keep working.
function HarvestRules.worldContext(view: any): any
	local EvolutionRules = require(script.Parent.Parent.Evolution.EvolutionRules)
	local allowed = {}
	for _, id in MeteorRegistry.ORDER do
		local def = HarvestConfig.TARGET_TYPES[id]
		if def and def.enabled then
			allowed[id] = def.unlock == nil or (view ~= nil and EvolutionRules.checkConditions(view, def.unlock)) or false
		end
	end
	for alias, target in HarvestConfig.ALIASES do
		if allowed[target] ~= nil then
			allowed[alias] = allowed[target]
		end
	end
	return {
		allowed = allowed,
		weightMultipliers = if view then MeteorRegistry.normalizeMap(HarvestConfig.BRANCH_WEIGHT_MULTIPLIERS[view.branch]) else nil,
	}
end

-- Reward multiplier passed to EconomyService:RewardHarvest (bounded there by HARVEST.MAX_MULTIPLIER).
function HarvestRules.rewardMultiplier(kind: string, quality: string, eventId: string?, fragment: boolean?): number
	local def = MeteorRegistry.get(kind)
	local q = HarvestConfig.QUALITY_MULTIPLIER[quality] or 1
	local ev = eventId and HarvestConfig.EVENTS[eventId]
	local frag = if fragment then HarvestConfig.SPLIT.FRAGMENT_REWARD else 1
	return (if def then def.multiplier else 1) * q * (if ev then ev.rewardMultiplier or 1 else 1) * frag
end

return HarvestRules
