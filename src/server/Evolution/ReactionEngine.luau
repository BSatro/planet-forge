--!strict
-- ReactionEngine — owner: Developer B. Pure transaction planner/applier over a profile table.
-- No Instances, no yields, no services -> fully unit-testable. EvolutionService wires it to the live
-- profile, EconomyService and the visual adapter.
--
-- Transaction shape (used by EvolutionService, in ONE uninterrupted server step):
--   1. plan = planReaction(profile, id)       validation only (EvolutionRules), nothing changes
--   2. EconomyService:Transact(plan.tx)       atomic: material/credit costs + first-discovery material
--                                             and credit rewards in a single TransactionCore apply
--   3. applyReaction(profile, plan, now)      DNA, formations, Codex, revision (cannot fail on valid plan)
--   4. evaluateProgress(profile, now)         stage milestones + mastery (rewards returned, granted by caller)
-- The client never supplies resulting values; everything is computed here from server state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local PlanetConfig = require(Shared.Config.PlanetConfig)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local EvolutionRules = require(Shared.Evolution.EvolutionRules)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)

local Engine = {}

local STATUS_CODE = {
	UNKNOWN = "UNKNOWN_REACTION",
	DONE = "ALREADY_COMPLETED",
	MAXED = "MAX_COMPLETIONS",
	LOCKED = "REQUIREMENTS_NOT_MET",
	NEEDS_MATERIALS = "INSUFFICIENT_MATERIALS",
	NO_EFFECT = "NO_EFFECT",
	CURRENT = "SAME_BRANCH",
	UNAVAILABLE = "BRANCH_UNAVAILABLE",
}

local function addTx(tx: any, section: string, id: string, delta: number)
	if delta == 0 then
		return
	end
	tx[section] = tx[section] or {}
	tx[section][id] = (tx[section][id] or 0) + delta
end

local function costTx(cost: any, tx: any)
	if cost and cost.materials then
		for mid, n in cost.materials do
			addTx(tx, "materials", mid, -n)
		end
	end
	if cost and cost.credits and cost.credits > 0 then
		addTx(tx, "currencies", "Credits", -cost.credits)
	end
end

local function rewardTx(reward: any, tx: any)
	if not reward then
		return
	end
	if reward.credits and reward.credits > 0 then
		addTx(tx, "currencies", "Credits", reward.credits)
	end
	if reward.materials then
		for mid, n in reward.materials do
			addTx(tx, "materials", mid, n)
		end
	end
end

-- Returns ok, code, planOrStatus
function Engine.planReaction(p: any, reactionId: any): (boolean, string, any)
	if not ReactionRegistry.get(reactionId) then
		return false, "UNKNOWN_REACTION", nil
	end
	local view = EvolutionRules.viewFromProfile(p)
	local st = EvolutionRules.reactionStatus(view, reactionId)
	if not st.available then
		return false, STATUS_CODE[st.status] or "REQUIREMENTS_NOT_MET", st
	end
	local def = st.def
	local tx = {}
	costTx(def.cost, tx)
	local reward = if st.firstDiscovery then def.discoveryReward else nil
	rewardTx(reward, tx)
	return true, "OK", {
		kind = "reaction",
		id = reactionId,
		def = def,
		tx = tx,
		firstDiscovery = st.firstDiscovery,
		reward = reward,
		xp = if reward then reward.xp or 0 else 0,
		cosmetic = reward and reward.cosmetic,
		dnaAfter = st.dnaAfter,
		dnaDelta = st.dnaDelta,
		gains = st.formationGains,
	}
end

-- Applies the planet/Codex half of a reaction (call only after plan.tx was applied). Returns summary.
function Engine.applyReaction(p: any, plan: any, now: number): any
	local planet = p.planet
	for _, param in PlanetConfig.DNA_ORDER do
		planet.dna[param] = plan.dnaAfter[param]
	end
	for _, g in plan.gains do
		local rec = planet.formations[g.id]
		if rec then
			rec.n = g.to
		else
			planet.formations[g.id] = { n = g.to, t = now }
		end
	end
	planet.rev += 1
	local rec = p.reactions[plan.id]
	if not rec then
		rec = { n = 0 }
		p.reactions[plan.id] = rec
	end
	rec.n += 1
	if not rec.d then
		rec.d = now
		rec.f = { stage = planet.stage, branch = planet.branch, rev = planet.rev }
	end
	return { rev = planet.rev }
end

-- Branch commit / re-specialization plan. Requires confirm == true (never automatic).
function Engine.planBranch(p: any, branchId: any, confirm: any): (boolean, string, any)
	if type(branchId) ~= "string" or not PlanetConfig.getBranch(branchId) then
		return false, "UNKNOWN_BRANCH", nil
	end
	local view = EvolutionRules.viewFromProfile(p)
	local st = EvolutionRules.branchStatus(view, branchId)
	if not st.available then
		return false, STATUS_CODE[st.status] or "REQUIREMENTS_NOT_MET", st
	end
	if confirm ~= true then
		return false, "NOT_CONFIRMED", st
	end
	local tx = {}
	costTx(st.cost, tx)
	local gains = EvolutionRules.formationGains(view, st.rule.unlocks)
	return true, "OK", {
		kind = "branch",
		id = branchId,
		tx = tx,
		isRespec = st.isRespec,
		from = view.branch,
		gains = gains,
		willGoDormant = st.willGoDormant,
		effect = st.rule.effect,
	}
end

function Engine.applyBranch(p: any, plan: any, now: number): any
	local planet = p.planet
	planet.branch = plan.id
	for _, g in plan.gains do
		local rec = planet.formations[g.id]
		if rec then
			rec.n = g.to
		else
			planet.formations[g.id] = { n = g.to, t = now }
		end
	end
	local log = planet.branchLog
	log.committedAt = now
	if plan.isRespec then
		log.respecs += 1
	end
	table.insert(log.history, plan.id)
	while #log.history > 20 do
		table.remove(log.history, 1)
	end
	planet.rev += 1
	return { rev = planet.rev }
end

-- Recompute stage, record first-time milestones and newly earned masteries (marks them; returns rewards
-- for the caller to grant). Idempotent: a milestone or mastery is only ever returned once.
function Engine.evaluateProgress(p: any, now: number): any
	local planet = p.planet
	local before = planet.stage
	local view = EvolutionRules.viewFromProfile(p)
	local after = EvolutionRules.computeStage(view)
	planet.stage = after
	view.stage = after
	local out = { stageBefore = before, stageAfter = after, newStages = {}, masteries = {}, rewards = {} }
	for k = 1, after do
		local key = "s" .. k
		if not planet.stageAt[key] then
			planet.stageAt[key] = now
			table.insert(out.newStages, k)
			local def = EvolutionConfig.STAGES[k]
			if def.reward then
				table.insert(out.rewards, { source = "stage", stage = k, reward = def.reward })
			end
			local cos = def.cosmeticByBranch and def.cosmeticByBranch[planet.branch]
			if cos then
				table.insert(out.rewards, { source = "stage", stage = k, reward = { cosmetic = cos } })
			end
		end
	end
	for _, id in ReactionRegistry.ORDER do
		local rec = p.reactions[id]
		local def = ReactionRegistry.DEFS[id]
		if rec and rec.d and not rec.m and def.mastery then
			if EvolutionRules.checkConditions(view, def.mastery.requires, id) then
				rec.m = now
				table.insert(out.masteries, id)
				table.insert(out.rewards, { source = "mastery", reaction = id, reward = def.mastery.reward })
			end
		end
	end
	return out
end

-- Inverse of a transaction (compensation if a later step throws unexpectedly).
function Engine.invertTx(tx: any): any
	local inv = {}
	for section, deltas in tx do
		for id, v in deltas do
			addTx(inv, section, id, -v)
		end
	end
	return inv
end

function Engine.txIsEmpty(tx: any): boolean
	for _, deltas in tx do
		for _, v in deltas do
			if v ~= 0 then
				return false
			end
		end
	end
	return true
end

return Engine
