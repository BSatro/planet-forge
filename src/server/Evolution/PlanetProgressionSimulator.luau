--!strict
-- PlanetProgressionSimulator — owner: Developer B. Offline balance + reachability tooling (tests only).
-- Uses the REAL rules (EvolutionRules, ReactionEngine, ProfileSchema, EconomyFormulas, HarvestConfig), not a
-- copy, and a deterministic EXPECTED-VALUE harvest income model from EvolutionConfig.SIM (no randomness).
-- These are design estimates for playtesting, not live player data.
--
--   validateRegistry()               static checks: ids, ranges, prerequisites, cycles, unreachable content
--   run(targetBranch, opts?)         goal-directed greedy player -> timings + stuck detection
--   runFrom(profile, target, opts?)  same from an arbitrary (e.g. fuzzed) state -> softlock check
--   fuzz(seed, actions)              random legal actions from a fresh profile (returns the profile)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local PlanetConfig = require(Shared.Config.PlanetConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local HarvestConfig = require(Shared.Config.HarvestConfig)
local Formulas = require(Shared.Economy.EconomyFormulas)
local HarvestRules = require(Shared.Harvest.HarvestRules)
local EvolutionRules = require(Shared.Evolution.EvolutionRules)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local ReactionEngine = require(script.Parent.ReactionEngine)
local Schema = require(script.Parent.Parent.Data.ProfileSchema)

local Sim = {}

---------------------------------------------------------------- static validation

function Sim.validateRegistry(): { string }
	local errs = {}
	local function err(s: string)
		table.insert(errs, s)
	end
	local produced: { [string]: string } = {}
	local function checkCond(where: string, cond: any)
		if type(cond) ~= "table" then
			return
		end
		for param, r in cond.dna or {} do
			if not PlanetConfig.DNA_PARAMS[param] then
				err(where .. ": unknown DNA param " .. param)
			elseif (r.min and (r.min < 0 or r.min > 100)) or (r.max and (r.max < 0 or r.max > 100)) or (r.min and r.max and r.min > r.max) then
				err(where .. ": impossible DNA range for " .. param)
			end
		end
		for _, id in cond.discovered or {} do
			if not ReactionRegistry.DEFS[id] then
				err(where .. ": unknown prerequisite " .. id)
			end
		end
		if cond.discoveredAny then
			for _, id in cond.discoveredAny.ids do
				if not ReactionRegistry.DEFS[id] then
					err(where .. ": unknown prerequisite " .. id)
				end
			end
		end
		for fid in cond.formations or {} do
			if not FormationRegistry.DEFS[fid] then
				err(where .. ": unknown formation " .. fid)
			end
		end
		if cond.branch then
			for _, b in (if type(cond.branch) == "table" then cond.branch else { cond.branch }) do
				if not PlanetConfig.isSelectableBranch(b) then
					err(where .. ": branch not selectable " .. tostring(b))
				end
			end
		end
	end
	for _, id in ReactionRegistry.ORDER do
		local d = ReactionRegistry.DEFS[id]
		local w = "reaction " .. id
		if type(d.name) ~= "string" or type(d.description) ~= "string" then
			err(w .. ": missing name/description")
		end
		local anyCost = false
		for mid, n in (d.cost and d.cost.materials) or {} do
			anyCost = true
			if not ItemCatalog.MATERIALS[mid] then
				err(w .. ": unknown material " .. mid)
			end
			if type(n) ~= "number" or n <= 0 or n % 1 ~= 0 then
				err(w .. ": bad amount for " .. mid)
			end
		end
		if not anyCost then
			err(w .. ": reactions must cost something")
		end
		for param in (d.effects and d.effects.dna) or {} do
			if not PlanetConfig.DNA_PARAMS[param] then
				err(w .. ": effect on unknown DNA param " .. param)
			end
		end
		for fid in (d.effects and d.effects.formations) or {} do
			if not FormationRegistry.DEFS[fid] then
				err(w .. ": unknown formation " .. fid)
			end
			produced[fid] = produced[fid] or id
		end
		local rep = d.repeats
		if type(rep) ~= "table" or not (rep.mode == "once" or rep.mode == "unlimited" or (rep.mode == "limited" and type(rep.max) == "number" and rep.max >= 1)) then
			err(w .. ": bad repeats")
		end
		checkCond(w .. " requires", d.requires)
		if d.mastery then
			checkCond(w .. " mastery", d.mastery.requires)
		end
		if d.discoveryReward and d.discoveryReward.cosmetic and not ItemCatalog.COSMETICS[d.discoveryReward.cosmetic] then
			err(w .. ": unknown cosmetic reward")
		end
	end
	-- prerequisite cycles (discovered-graph DFS)
	local state: { [string]: number } = {}
	local function visit(id: string, path: string)
		if state[id] == 1 then
			err("prerequisite cycle: " .. path .. " -> " .. id)
			return
		end
		if state[id] == 2 then
			return
		end
		state[id] = 1
		local d = ReactionRegistry.DEFS[id]
		for _, pre in (d.requires and d.requires.discovered) or {} do
			if ReactionRegistry.DEFS[pre] then
				visit(pre, path .. " -> " .. id)
			end
		end
		state[id] = 2
	end
	for _, id in ReactionRegistry.ORDER do
		visit(id, "")
	end
	for b, rule in EvolutionConfig.BRANCH_RULES do
		checkCond("branch " .. b, rule.requires)
		for fid in rule.unlocks or {} do
			if not FormationRegistry.DEFS[fid] then
				err("branch " .. b .. ": unknown unlock " .. fid)
			end
			produced[fid] = produced[fid] or ("branch:" .. b)
		end
		local cap = FormationRegistry.DEFS[rule.capstone]
		if not cap or cap.branch ~= b then
			err("branch " .. b .. ": capstone must be a formation of the branch")
		end
	end
	for _, fid in FormationRegistry.ORDER do
		if not produced[fid] then
			err("formation " .. fid .. " is never produced (unreachable)")
		end
	end
	for k = 1, PlanetConfig.MAX_EVOLUTION_STAGE do
		if not EvolutionConfig.STAGES[k] or not EvolutionConfig.STAGES[k].requires then
			err("stage " .. k .. " has no requirements")
		end
	end
	-- DNA reversibility (softlock guard): if any reaction can push a parameter AWAY from a threshold that
	-- some requirement needs, an UNLIMITED reaction must be able to push it back.
	local needsMin, needsMax, lowers, raises, unlimitedUp, unlimitedDown = {}, {}, {}, {}, {}, {}
	local function scanNeeds(cond: any)
		for param, r in (type(cond) == "table" and cond.dna) or {} do
			if r.min then
				needsMin[param] = true
			end
			if r.max then
				needsMax[param] = true
			end
		end
	end
	for _, id in ReactionRegistry.ORDER do
		local d = ReactionRegistry.DEFS[id]
		scanNeeds(d.requires)
		for param, delta in (d.effects and d.effects.dna) or {} do
			local unlimited = d.repeats and d.repeats.mode == "unlimited"
			if delta < 0 then
				lowers[param] = id
				if unlimited then
					unlimitedDown[param] = true
				end
			elseif delta > 0 then
				raises[param] = id
				if unlimited then
					unlimitedUp[param] = true
				end
			end
		end
	end
	for _, rule in EvolutionConfig.BRANCH_RULES do
		scanNeeds(rule.requires)
	end
	for _, param in PlanetConfig.DNA_ORDER do
		if needsMin[param] and lowers[param] and not unlimitedUp[param] then
			err("softlock: " .. lowers[param] .. " lowers " .. param .. " but no unlimited reaction raises it")
		end
		if needsMax[param] and raises[param] and not unlimitedDown[param] then
			err("softlock: " .. raises[param] .. " raises " .. param .. " but no unlimited reaction lowers it")
		end
	end
	return errs
end

---------------------------------------------------------------- simulated player

local function applyTx(p: any, tx: any)
	for section, deltas in tx do
		for id, v in deltas do
			p[section][id] = math.max(0, (p[section][id] or 0) + v)
		end
	end
end

local function grantXp(p: any, xp: number, sim: any)
	if xp <= 0 then
		return
	end
	local lvl, rest, gained = Formulas.applyXp(p.level, p.xp, xp)
	p.level, p.xp = lvl, rest
	for _, L in gained do
		p.currencies.Credits += Formulas.levelUpReward(L)
		sim.energy = Formulas.energyCap(p.level, 0) -- level-up refills harvest energy
	end
end

local function grantRewards(p: any, prog: any, sim: any)
	for _, r in prog.rewards do
		local rw = r.reward
		if rw.credits then
			p.currencies.Credits += rw.credits
		end
		if rw.materials then
			applyTx(p, { materials = rw.materials })
		end
		grantXp(p, rw.xp or 0, sim)
	end
end

local function floorMaterials(p: any): any
	local view = EvolutionRules.viewFromProfile(p)
	local m = {}
	for id, v in p.materials do
		m[id] = math.floor(v + 1e-9)
	end
	view.materials = m
	return view
end

-- one harvesting tick of `dt` seconds (expected values)
local function harvest(p: any, sim: any, dt: number)
	local S = EvolutionConfig.SIM
	local cost = Formulas.harvestEnergyCost(0)
	local cap = Formulas.energyCap(p.level, 0)
	sim.energy = math.min(cap, sim.energy + EconomyConfig.ENERGY.REGEN_PER_MINUTE * dt / 60)
	local captures = math.min(S.CAPTURES_PER_MINUTE * dt / 60 * (sim.rateScale or 1), sim.energy / cost)
	if captures <= 0 then
		return
	end
	sim.energy -= captures * cost
	sim.captures += captures
	local ctx = HarvestRules.worldContext(EvolutionRules.viewFromProfile(p))
	local weights, total = {}, 0
	for kind, def in HarvestConfig.TARGET_TYPES do
		if def.enabled and ctx.allowed[kind] then
			local w = def.weight * (ctx.weightMultipliers and ctx.weightMultipliers[kind] or 1)
			weights[kind] = w
			total += w
		end
	end
	local quality = S.PERFECT_SHARE * HarvestConfig.QUALITY_MULTIPLIER.perfect + (1 - S.PERFECT_SHARE) * HarvestConfig.QUALITY_MULTIPLIER.good
	for kind, w in weights do
		local def = HarvestConfig.TARGET_TYPES[kind]
		local base = EconomyConfig.HARVEST.BASE_YIELD[def.resource] or 0
		local yieldEach = base * (1 + EconomyConfig.HARVEST.LEVEL_YIELD_BONUS * (p.level - 1)) * def.multiplier * quality
		p.materials[def.resource] = (p.materials[def.resource] or 0) + captures * (w / total) * yieldEach
	end
	grantXp(p, captures * EconomyConfig.HARVEST.XP_PER_HARVEST, sim)
end

-- can an UNLIMITED reaction move `param` in direction `dir` (+1 up / -1 down)?
local tunableCache: { [string]: boolean } = {}
local function tunable(param: string, dir: number): boolean
	local k = param .. dir
	if tunableCache[k] == nil then
		local found = false
		for _, id in ReactionRegistry.ORDER do
			local d = ReactionRegistry.DEFS[id]
			local delta = d.effects.dna and d.effects.dna[param] or 0
			if d.repeats and d.repeats.mode == "unlimited" and delta * dir > 0 then
				found = true
			end
		end
		tunableCache[k] = found
	end
	return tunableCache[k]
end

-- DNA goal ranges the player is working toward (weighted)
local function goals(p: any, view: any, target: string): { any }
	local out = {}
	local function addCond(cond: any, weight: number)
		if not cond then
			return
		end
		for param, r in cond.dna or {} do
			table.insert(out, { param = param, min = r.min, max = r.max, w = weight })
		end
	end
	local rule = EvolutionConfig.BRANCH_RULES[target]
	if view.branch ~= target then -- unspecialized OR re-specializing: the target's commit rules are the goal
		if view.stage >= 2 then
			addCond(rule.requires, 3)
		else
			-- the next stage's gating discoveries are real goals (e.g. an ocean or an eruption for Stage 2)
			local nxt = EvolutionConfig.STAGES[view.stage + 1]
			local any = nxt and nxt.requires and nxt.requires.discoveredAny
			if any then
				for _, id in any.ids do
					if not EvolutionRules.isDiscovered(view, id) then
						addCond(ReactionRegistry.DEFS[id].requires, 3)
						break
					end
				end
			end
		end
	else
		-- capstone chain: requirements of undiscovered reactions of the branch
		for _, id in ReactionRegistry.ORDER do
			local d = ReactionRegistry.DEFS[id]
			if d.requires.branch == target and not EvolutionRules.isDiscovered(view, id) then
				addCond(d.requires, 3)
			end
		end
	end
	-- exploration: undiscovered major reactions. Optional (weight 1, reward-only) until the landmark
	-- exists and Stage 4 still needs discoveries -> then a real goal (weight 3) for any branch-free one.
	local rule4 = EvolutionConfig.STAGES[4].requires
	local cap = rule and rule.capstone
	local needMore = view.branch == target and cap ~= nil and (view.formations[cap] or 0) > 0
		and EvolutionRules.discoveredCount(view) < (rule4.discoveredCount or 0)
	for _, id in ReactionRegistry.ORDER do
		local d = ReactionRegistry.DEFS[id]
		if d.major and not EvolutionRules.isDiscovered(view, id) and d.requires.branch == nil then
			if needMore then
				addCond(d.requires, 3)
				break -- one target at a time keeps DNA goals consistent
			elseif d.branch == nil or d.branch == target then
				addCond(d.requires, 1)
			end
		end
	end
	-- indirect goals: a real goal on a parameter that no UNLIMITED reaction can move in the needed direction
	-- (e.g. Life) is met by doing the reactions that change it -> the DNA requirements of the closest such
	-- reaction become real goals too (otherwise the greedy player waits forever).
	local extra = {}
	for _, g in out do
		if g.w >= 3 then
			local v = view.dna[g.param]
			local dir = if g.min and v < g.min then 1 elseif g.max and v > g.max then -1 else 0
			if dir ~= 0 and not tunable(g.param, dir) then
				local bestCond, bestGap = nil, math.huge
				for _, id in ReactionRegistry.ORDER do
					local d = ReactionRegistry.DEFS[id]
					local delta = d.effects.dna and d.effects.dna[g.param] or 0
					if delta * dir > 0 then
						local st = EvolutionRules.reactionStatus(view, id)
						if st.status == "LOCKED" then
							local onlyDna, gap = true, 0
							for _, u in st.unmet do
								if (u.code == "DNA_MIN" or u.code == "DNA_MAX") and u.id == g.param then
									onlyDna = false -- needs the very value we're trying to raise: circular
								elseif u.code == "DNA_MIN" or u.code == "DNA_MAX" then
									gap += math.abs((u.need or 0) - (u.have or 0))
								elseif u.code ~= "MATERIAL" then
									onlyDna = false
								end
							end
							if onlyDna and gap < bestGap then
								bestCond, bestGap = d.requires, gap
							end
						end
					end
				end
				if bestCond then
					table.insert(extra, bestCond)
				end
			end
		end
	end
	for _, c in extra do
		addCond(c, 3)
	end
	return out
end

local function gapOf(g: any, v: number): number
	if g.min and v < g.min then
		return g.min - v
	end
	if g.max and v > g.max then
		return v - g.max
	end
	return 0
end

local function scoreReaction(view: any, st: any, gl: { any }, target: string, p: any): number
	local def = st.def
	local score = 0
	if st.firstDiscovery then
		score += if def.major then (if def.branch == nil or def.branch == target then 150 else 60) else 25
	end
	for _, g in gl do
		if not def.major and g.w < 3 then
			continue -- tuning reactions only steer toward real goals (prevents heat/cool ping-pong)
		end
		local before = gapOf(g, view.dna[g.param])
		local after = gapOf(g, st.dnaAfter[g.param])
		local improvement = before - after
		if g.w >= 3 then
			score += improvement * 2 * g.w -- branch/capstone goals: signed (moving away is penalized)
		else
			score += math.max(0, improvement) * 2 * g.w -- optional exploration: only rewards progress
		end
	end
	for _, gain in st.formationGains do
		-- formation counts needed by pending requirements (e.g. 2 crystal clusters, 3 forests)
		for _, id in ReactionRegistry.ORDER do
			local d = ReactionRegistry.DEFS[id]
			local need = d.requires.formations and d.requires.formations[gain.id]
			if need and gain.from < need and not EvolutionRules.isDiscovered(view, id) then
				score += 80
			end
		end
	end
	return score
end

-- Returns a report table.
function Sim.runFrom(p: any, target: string, opts: any?): any
	local o = opts or {}
	local S = EvolutionConfig.SIM
	local sim = { energy = o.energy or Formulas.energyCap(p.level, 0), captures = 0, rateScale = o.rateScale }
	local t = 0
	local maxT = (o.maxMinutes or S.MAX_MINUTES) * 60
	local report: any = { target = target, events = {}, actions = 0, reactions = 0, tuning = 0 }
	local function mark(key: string)
		if report[key] == nil then
			report[key] = t / 60
		end
	end
	local tick = 10
	local guard = 0
	while t < maxT do
		guard += 1
		if guard > 200000 then
			break
		end
		local view = floorMaterials(p)
		if view.stage >= 4 and view.branch == target then
			mark("stage4At")
			break
		end
		-- 1) commit the target branch as soon as it is affordable/eligible
		local acted = false
		if view.branch ~= target then
			local bs = EvolutionRules.branchStatus(view, target)
			if bs.available and (view.branch == PlanetConfig.DEFAULT_BRANCH or o.allowRespec) then
				local ok, _, plan = ReactionEngine.planBranch(p, target, true)
				if ok then
					-- planReaction validates against floored materials via the view; mirror that here
					applyTx(p, plan.tx)
					ReactionEngine.applyBranch(p, plan, t)
					local prog = ReactionEngine.evaluateProgress(p, t)
					grantRewards(p, prog, sim)
					for _, k in prog.newStages do
						mark("stage" .. k .. "At")
					end
					mark("branchAt")
					table.insert(report.events, string.format("%.1f commit %s", t / 60, target))
					report.actions += 1
					t += S.DECISION_SECONDS
					acted = true
				end
			end
		end
		-- 2) best available reaction
		if not acted then
			local gl = goals(p, view, target)
			local best, bestScore = nil, 0
			for _, id in ReactionRegistry.ORDER do
				local st = EvolutionRules.reactionStatus(view, id)
				if st.available then
					local sc = scoreReaction(view, st, gl, target, p)
					if sc > bestScore then
						best, bestScore = id, sc
					end
				end
			end
			if best then
				-- the real engine reads floored balances: give it the floored view's materials
				local saved = p.materials
				p.materials = view.materials
				local ok, code, plan = ReactionEngine.planReaction(p, best)
				p.materials = saved
				if ok then
					applyTx(p, plan.tx)
					ReactionEngine.applyReaction(p, plan, t)
					grantXp(p, plan.xp, sim)
					local prog = ReactionEngine.evaluateProgress(p, t)
					grantRewards(p, prog, sim)
					report.actions += 1
					if ReactionRegistry.DEFS[best].major then
						report.reactions += 1
					else
						report.tuning += 1
					end
					mark("firstReactionAt")
					if plan.firstDiscovery and #plan.gains > 0 then
						mark("firstTransformationAt")
					end
					for _, k in prog.newStages do
						mark("stage" .. k .. "At")
					end
					table.insert(report.events, string.format("%.1f %s %s", t / 60, best, ReactionRegistry.DEFS[best].name))
					t += S.DECISION_SECONDS
					acted = true
				else
					table.insert(report.events, "engine rejected " .. best .. ": " .. code)
				end
			end
		end
		if not acted then
			harvest(p, sim, tick)
			t += tick
		end
	end
	report.minutes = t / 60
	report.stuck = report.stage4At == nil
	report.captures = sim.captures
	report.level = p.level
	report.discovered = EvolutionRules.discoveredCount(EvolutionRules.viewFromProfile(p))
	report.finalDna = table.clone(p.planet.dna)
	report.finalStage = p.planet.stage
	report.branch = p.planet.branch
	report.profile = p -- for debugging a stuck run
	return report
end

function Sim.newProfile(userId: number?): any
	return Schema.default(0, userId or 1)
end

function Sim.run(target: string, opts: any?): any
	return Sim.runFrom(Sim.newProfile(), target, opts)
end

-- Random legal actions (reactions and branch commits) from a fresh profile with generous materials.
function Sim.fuzz(seed: number, steps: number): any
	local rng = Random.new(seed)
	local p = Sim.newProfile(seed)
	for id in ItemCatalog.MATERIALS do
		p.materials[id] = math.min(400, Schema.capFor("materials", id))
	end
	local sim = { energy = 100, captures = 0 }
	for step = 1, steps do
		local view = EvolutionRules.viewFromProfile(p)
		local options = {}
		for _, id in ReactionRegistry.ORDER do
			if EvolutionRules.reactionStatus(view, id).available then
				table.insert(options, { kind = "r", id = id })
			end
		end
		for b in EvolutionConfig.BRANCH_RULES do
			if EvolutionRules.branchStatus(view, b).available then
				table.insert(options, { kind = "b", id = b })
			end
		end
		if #options == 0 then
			break
		end
		local pick = options[rng:NextInteger(1, #options)]
		if pick.kind == "r" then
			local ok, _, plan = ReactionEngine.planReaction(p, pick.id)
			if ok then
				applyTx(p, plan.tx)
				ReactionEngine.applyReaction(p, plan, step)
			end
		else
			local ok, _, plan = ReactionEngine.planBranch(p, pick.id, true)
			if ok then
				applyTx(p, plan.tx)
				ReactionEngine.applyBranch(p, plan, step)
			end
		end
		grantRewards(p, ReactionEngine.evaluateProgress(p, step), sim)
	end
	return p
end

return Sim
