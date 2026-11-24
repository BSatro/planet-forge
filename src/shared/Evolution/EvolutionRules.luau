--!strict
-- EvolutionRules — owner: Developer B. THE single definition of evolution eligibility. Pure functions over a
-- read-only "view"; no Instances, no yields, no mutation. The server uses it to authorize actions
-- (ReactionEngine), the client uses the very same code for previews (so the UI never disagrees with the
-- server about what is possible).
--
-- View shape (build with viewFromProfile on the server or viewFromSnapshot on the client):
--   { dna = { [param]: n }, stage = n, branch = id, formations = { [id]: count },
--     codex = { [reactionId]: { n = completions, d = discoveredAt?, m = masteredAt? } },
--     materials = { [id]: n }, credits = n, level = n }

local Shared = script.Parent.Parent
local PlanetConfig = require(Shared.Config.PlanetConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local ReactionRegistry = require(script.Parent.ReactionRegistry)
local FormationRegistry = require(script.Parent.FormationRegistry)

export type Unmet = { code: string, text: string, have: number?, need: number?, id: string? }

local Rules = {}

---------------------------------------------------------------- views

function Rules.viewFromProfile(p: any): any
	local formations = {}
	for id, rec in p.planet.formations do
		if type(rec) == "table" and type(rec.n) == "number" then
			formations[id] = rec.n
		end
	end
	return {
		dna = p.planet.dna,
		stage = p.planet.stage,
		branch = p.planet.branch,
		formations = formations,
		codex = p.reactions,
		materials = p.materials,
		credits = p.currencies.Credits or 0,
		level = p.level or 1,
	}
end

-- Client snapshot (ClientDataService v2) -> view.
function Rules.viewFromSnapshot(s: any): any
	local planet = s.planet or {}
	return {
		dna = planet.dna or PlanetConfig.defaultDna(),
		stage = planet.stage or 0,
		branch = planet.branch or PlanetConfig.DEFAULT_BRANCH,
		formations = planet.formationCounts or {},
		codex = s.reactions or {},
		materials = s.materials or {},
		credits = (s.currencies and s.currencies.Credits) or 0,
		level = s.level or 1,
	}
end

---------------------------------------------------------------- small queries

function Rules.isDiscovered(view: any, id: string): boolean
	local r = view.codex[id]
	return type(r) == "table" and r.d ~= nil
end

function Rules.completions(view: any, id: string): number
	local r = view.codex[id]
	return if type(r) == "table" and type(r.n) == "number" then r.n else 0
end

function Rules.isMastered(view: any, id: string): boolean
	local r = view.codex[id]
	return type(r) == "table" and r.m ~= nil
end

-- Discovered MAJOR reactions (tuning reactions don't count toward stages).
function Rules.discoveredCount(view: any): number
	local n = 0
	for _, id in ReactionRegistry.ORDER do
		if ReactionRegistry.DEFS[id].major and Rules.isDiscovered(view, id) then
			n += 1
		end
	end
	return n
end

function Rules.formationCount(view: any, id: string): number
	return view.formations[id] or 0
end

local function reactionName(id: string): string
	local d = ReactionRegistry.DEFS[id]
	return if d then d.name else id
end

local function formationName(id: string): string
	local d = FormationRegistry.DEFS[id]
	return if d then d.displayName else id
end

local function materialName(id: string): string
	local e = ItemCatalog.MATERIALS[id]
	return if e then e.displayName else id
end
Rules.materialName = materialName
Rules.formationName = formationName
Rules.reactionName = reactionName

local function stageName(n: number): string
	local s = EvolutionConfig.STAGES[n]
	return if s then s.name else ("Stage " .. n)
end
Rules.stageName = stageName

---------------------------------------------------------------- conditions

-- Returns ok, { Unmet }. `selfId` = reaction whose completions are checked by `completions`.
function Rules.checkConditions(view: any, cond: any, selfId: string?): (boolean, { Unmet })
	local unmet: { Unmet } = {}
	if type(cond) ~= "table" then
		return true, unmet
	end
	if cond.dna then
		for _, param in PlanetConfig.DNA_ORDER do
			local r = cond.dna[param]
			if r then
				local v = view.dna[param] or 0
				local name = PlanetConfig.DNA_PARAMS[param].displayName
				if r.min and v < r.min then
					table.insert(unmet, { code = "DNA_MIN", id = param, have = v, need = r.min, text = string.format("%s %d or more (now %d)", name, r.min, v) })
				end
				if r.max and v > r.max then
					table.insert(unmet, { code = "DNA_MAX", id = param, have = v, need = r.max, text = string.format("%s %d or less (now %d)", name, r.max, v) })
				end
			end
		end
	end
	if cond.stage then
		if cond.stage.min and view.stage < cond.stage.min then
			table.insert(unmet, { code = "STAGE_MIN", have = view.stage, need = cond.stage.min, text = string.format("Reach Stage %d: %s", cond.stage.min, stageName(cond.stage.min)) })
		end
		if cond.stage.max and view.stage > cond.stage.max then
			table.insert(unmet, { code = "STAGE_MAX", have = view.stage, need = cond.stage.max, text = string.format("Only up to Stage %d", cond.stage.max) })
		end
	end
	if cond.branch then
		local allowed = if type(cond.branch) == "table" then cond.branch else { cond.branch }
		if not table.find(allowed, view.branch) then
			local names = {}
			for _, b in allowed do
				local def = PlanetConfig.BRANCHES[b]
				table.insert(names, if def then def.displayName else b)
			end
			table.insert(unmet, { code = "BRANCH", id = allowed[1], text = "Requires the " .. table.concat(names, " or ") .. " specialization" })
		end
	end
	if cond.branchSet and (view.branch == nil or view.branch == PlanetConfig.DEFAULT_BRANCH) then
		table.insert(unmet, { code = "BRANCH_SET", text = "Commit to a specialization" })
	end
	if cond.capstone then
		local rule = EvolutionConfig.BRANCH_RULES[view.branch]
		local cap = rule and rule.capstone
		if not cap or Rules.formationCount(view, cap) < 1 then
			table.insert(unmet, { code = "CAPSTONE", id = cap, text = if cap then ("Create your landmark: " .. formationName(cap)) else "Create your branch landmark" })
		end
	end
	if cond.discovered then
		for _, rid in cond.discovered do
			if not Rules.isDiscovered(view, rid) then
				table.insert(unmet, { code = "DISCOVERED", id = rid, text = "Discover " .. reactionName(rid) .. " first" })
			end
		end
	end
	if cond.discoveredAny then
		local n = 0
		local names = {}
		for _, rid in cond.discoveredAny.ids do
			if Rules.isDiscovered(view, rid) then
				n += 1
			end
			table.insert(names, reactionName(rid))
		end
		local need = cond.discoveredAny.min or 1
		if n < need then
			table.insert(unmet, { code = "DISCOVERED_ANY", have = n, need = need, text = "Discover " .. (if need == 1 then "one of: " else need .. " of: ") .. table.concat(names, ", ") })
		end
	end
	if cond.discoveredCount then
		local n = Rules.discoveredCount(view)
		if n < cond.discoveredCount then
			table.insert(unmet, { code = "DISCOVERED_COUNT", have = n, need = cond.discoveredCount, text = string.format("Discover %d reactions (%d/%d)", cond.discoveredCount, n, cond.discoveredCount) })
		end
	end
	if cond.formations then
		for fid, need in cond.formations do
			local have = Rules.formationCount(view, fid)
			if have < need then
				table.insert(unmet, { code = "FORMATION", id = fid, have = have, need = need, text = string.format("Own %s x%d (%d/%d)", formationName(fid), need, have, need) })
			end
		end
	end
	if cond.completions and selfId then
		local have = Rules.completions(view, selfId)
		if have < cond.completions then
			table.insert(unmet, { code = "COMPLETIONS", have = have, need = cond.completions, text = string.format("Complete it %d times (%d/%d)", cond.completions, have, cond.completions) })
		end
	end
	if cond.level and (view.level or 1) < cond.level then
		table.insert(unmet, { code = "LEVEL", have = view.level, need = cond.level, text = "Reach player level " .. cond.level })
	end
	return #unmet == 0, unmet
end

---------------------------------------------------------------- effects

-- DNA after applying deltas (clamped). Returns after, actualDelta.
function Rules.dnaAfter(dna: any, deltas: any): ({ [string]: number }, { [string]: number })
	local after, actual = {}, {}
	for _, param in PlanetConfig.DNA_ORDER do
		local v = dna[param] or PlanetConfig.DNA_PARAMS[param].default
		local d = deltas and deltas[param] or 0
		local nv = PlanetConfig.clampDna(param, v + d) :: number
		after[param] = nv
		actual[param] = nv - v
	end
	return after, actual
end

-- Formation gains: { { id, from, to } } (respects maxCount).
function Rules.formationGains(view: any, add: any): { any }
	local out = {}
	if type(add) ~= "table" then
		return out
	end
	local ids = {}
	for fid in add do
		table.insert(ids, fid)
	end
	table.sort(ids)
	for _, fid in ids do
		local def = FormationRegistry.DEFS[fid]
		if def then
			local from = Rules.formationCount(view, fid)
			local to = math.min(def.maxCount, from + add[fid])
			if to > from then
				table.insert(out, { id = fid, from = from, to = to })
			end
		end
	end
	return out
end

local function costLines(view: any, cost: any, unmet: { Unmet }): { any }
	local lines = {}
	if cost and cost.materials then
		local ids = {}
		for mid in cost.materials do
			table.insert(ids, mid)
		end
		table.sort(ids, function(a, b)
			local ea, eb = ItemCatalog.MATERIALS[a], ItemCatalog.MATERIALS[b]
			return (ea and ea.order or 99) < (eb and eb.order or 99)
		end)
		for _, mid in ids do
			local need = cost.materials[mid]
			local have = view.materials[mid] or 0
			table.insert(lines, { kind = "material", id = mid, name = materialName(mid), need = need, have = have, ok = have >= need })
			if have < need then
				table.insert(unmet, { code = "MATERIAL", id = mid, have = have, need = need, text = string.format("%s %d (have %d)", materialName(mid), need, have) })
			end
		end
	end
	if cost and cost.credits and cost.credits > 0 then
		local have = view.credits or 0
		table.insert(lines, { kind = "credits", id = "Credits", name = "Credits", need = cost.credits, have = have, ok = have >= cost.credits })
		if have < cost.credits then
			table.insert(unmet, { code = "CREDITS", id = "Credits", have = have, need = cost.credits, text = string.format("Credits %d (have %d)", cost.credits, have) })
		end
	end
	return lines
end

---------------------------------------------------------------- reactions

-- status: "AVAILABLE" | "LOCKED" | "NEEDS_MATERIALS" | "DONE" | "MAXED" | "NO_EFFECT" | "UNKNOWN"
function Rules.reactionStatus(view: any, id: string): any
	local def = ReactionRegistry.get(id)
	if not def then
		return { id = id, status = "UNKNOWN", available = false, unmet = {} }
	end
	local count = Rules.completions(view, id)
	local discovered = Rules.isDiscovered(view, id)
	local unmet: { Unmet } = {}
	local st: any = {
		id = id,
		def = def,
		discovered = discovered,
		mastered = Rules.isMastered(view, id),
		completions = count,
		firstDiscovery = not discovered,
		reward = if discovered then nil else def.discoveryReward,
	}
	local rep = def.repeats or { mode = "once" }
	local done = (rep.mode == "once" and count >= 1)
	local maxed = (rep.mode == "limited" and count >= (rep.max or 1))
	local condOk, condUnmet = Rules.checkConditions(view, def.requires)
	for _, u in condUnmet do
		table.insert(unmet, u)
	end
	st.costs = costLines(view, def.cost, unmet)
	local after, delta = Rules.dnaAfter(view.dna, def.effects and def.effects.dna)
	st.dnaBefore = view.dna
	st.dnaAfter = after
	st.dnaDelta = delta
	st.formationGains = Rules.formationGains(view, def.effects and def.effects.formations)
	local anyDna = false
	for _, v in delta do
		if v ~= 0 then
			anyDna = true
		end
	end
	if done then
		st.status = "DONE"
	elseif maxed then
		st.status = "MAXED"
	elseif not condOk then
		st.status = "LOCKED"
	elseif #unmet > 0 then
		st.status = "NEEDS_MATERIALS"
	elseif discovered and not anyDna and #st.formationGains == 0 then
		st.status = "NO_EFFECT" -- would only burn resources
	else
		st.status = "AVAILABLE"
	end
	st.available = st.status == "AVAILABLE"
	st.unmet = unmet
	return st
end

---------------------------------------------------------------- stages

function Rules.computeStage(view: any): number
	local s = 0
	for k = 1, PlanetConfig.MAX_EVOLUTION_STAGE do
		local def = EvolutionConfig.STAGES[k]
		if def and Rules.checkConditions(view, def.requires) then
			s = k
		else
			break
		end
	end
	return s
end

-- { stage, name, next = { stage, name, goal, unmet } | nil }
function Rules.stageProgress(view: any): any
	local s = Rules.computeStage(view)
	local out: any = { stage = s, name = stageName(s), description = EvolutionConfig.STAGES[s].description }
	local nxt = EvolutionConfig.STAGES[s + 1]
	if nxt then
		local _, unmet = Rules.checkConditions(view, nxt.requires)
		out.next = { stage = s + 1, name = nxt.name, goal = EvolutionConfig.STAGES[s].goal, unmet = unmet }
	end
	return out
end

---------------------------------------------------------------- branches

-- status: "AVAILABLE" | "LOCKED" | "NEEDS_MATERIALS" | "CURRENT" | "UNAVAILABLE"
function Rules.branchStatus(view: any, branchId: string): any
	local bdef = PlanetConfig.getBranch(branchId)
	local rule = EvolutionConfig.BRANCH_RULES[branchId]
	if not bdef or not rule or not PlanetConfig.isSelectableBranch(branchId) then
		return { id = branchId, status = "UNAVAILABLE", available = false, unmet = {}, future = bdef and bdef.future or false }
	end
	local st: any = {
		id = branchId,
		displayName = bdef.displayName,
		rule = rule,
		unlocks = rule.unlocks,
		capstone = rule.capstone,
		isRespec = view.branch ~= PlanetConfig.DEFAULT_BRANCH and view.branch ~= branchId,
	}
	if view.branch == branchId then
		st.status = "CURRENT"
		st.available = false
		st.unmet = {}
		st.costs = {}
		return st
	end
	local unmet: { Unmet } = {}
	local condOk, condUnmet = Rules.checkConditions(view, rule.requires)
	for _, u in condUnmet do
		table.insert(unmet, u)
	end
	if st.isRespec and view.stage < EvolutionConfig.RESPEC.minStage then
		condOk = false
		table.insert(unmet, { code = "STAGE_MIN", text = "Switching requires a Specialized World" })
	end
	local cost = { materials = rule.cost.materials, credits = (rule.cost.credits or 0) + (if st.isRespec then EvolutionConfig.RESPEC.credits else 0) }
	st.cost = cost
	st.costs = costLines(view, cost, unmet)
	-- landmarks of the current branch that would go dormant
	local dormant = {}
	if st.isRespec then
		for fid, n in view.formations do
			local f = FormationRegistry.DEFS[fid]
			if n > 0 and f and f.dormantOutsideBranch and f.branch == view.branch then
				table.insert(dormant, fid)
			end
		end
		table.sort(dormant)
	end
	st.willGoDormant = dormant
	st.status = if not condOk then "LOCKED" elseif #unmet > 0 then "NEEDS_MATERIALS" else "AVAILABLE"
	st.available = st.status == "AVAILABLE"
	st.unmet = unmet
	return st
end

---------------------------------------------------------------- codex / mastery

-- { state = "UNDISCOVERED"|"DISCOVERED"|"MASTERED", ready, unmet, hint }
function Rules.codexStatus(view: any, id: string): any
	local def = ReactionRegistry.get(id)
	if not def then
		return { state = "UNKNOWN" }
	end
	if not Rules.isDiscovered(view, id) then
		return { state = "UNDISCOVERED", completions = 0 }
	end
	if Rules.isMastered(view, id) then
		return { state = "MASTERED", completions = Rules.completions(view, id) }
	end
	local m = def.mastery
	local ok, unmet = Rules.checkConditions(view, m and m.requires, id)
	return { state = "DISCOVERED", ready = m ~= nil and ok, unmet = unmet, hint = m and m.hint, completions = Rules.completions(view, id) }
end

-- Formations that are rendered for the planet: { { id, n } } (owned, known, not dormant).
function Rules.activeFormations(view: any): { any }
	local out = {}
	for _, fid in FormationRegistry.ORDER do
		local n = Rules.formationCount(view, fid)
		if n > 0 and FormationRegistry.isActive(fid, view.branch) then
			table.insert(out, { id = fid, n = n })
		end
	end
	return out
end

return Rules
