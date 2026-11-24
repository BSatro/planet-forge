--!strict
-- PlanetStateValidator — owner: Developer B. Normalizes the persisted planet + reaction Codex (schema v2)
-- IN PLACE. Called by ProfileSchema.reconcile on every load (after migrations) and by tests.
-- Never deletes player data: unknown-but-valid ids are kept (rollback / removed content safe); only
-- malformed values are repaired. Stage is RECOMPUTED from the authoritative rules, never trusted.
--
-- planet (v2) = {
--   dna        = { Temperature, Water, Life, CosmicEnergy }      integers 0..100
--   stage      = 0..4 (derived; stored for readers/visuals)
--   branch     = "None" | selectable branch id
--   formations = { [formationId] = { n = count, t = firstUnlockedAt } }
--   seed       = deterministic world seed (from the userId; never the temporary slot)
--   rev        = state revision (+1 per confirmed change; visual + idempotency contract)
--   cosmetics  = { Atmosphere = cosmeticId?, PlanetRing = cosmeticId? }   (equipped, must be owned)
--   stageAt    = { s1..s4 = firstReachedAt }   (milestones/rewards fire once)
--   branchLog  = { committedAt, respecs, history = { ids } }
--   legacy     = migration leftovers (audit only)
-- }
-- reactions (Codex) = { [reactionId] = { n = completions, d = discoveredAt, m = masteredAt?, f = firstResult? } }

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local PlanetConfig = require(Shared.Config.PlanetConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EvolutionRules = require(Shared.Evolution.EvolutionRules)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)

local Validator = {}

local MAX_TS = 4_102_444_800
local MAX_COUNTER = 1_000_000

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function int(v: any, lo: number, hi: number, fallback: number): number
	if not finite(v) then
		return fallback
	end
	return math.clamp(math.floor(v), lo, hi)
end

local function tsOrNil(v: any): number?
	if not finite(v) or v <= 0 then
		return nil
	end
	return math.min(math.floor(v), MAX_TS)
end

-- Deterministic world seed from the userId (stable across sessions, slots and failed saves).
function Validator.seedFor(userId: number?): number
	local u = math.abs(math.floor(tonumber(userId) or 0))
	local h = (u * 2654435761 + 97531) % 2147483629
	return math.max(1, h)
end

function Validator.reconcilePlanet(planet: any, now: number, userId: number?, ownedCosmetics: any?): any
	if type(planet) ~= "table" then
		planet = {}
	end
	-- DNA: canonical params clamped; unknown finite params kept (ignored by rules)
	local dna = if type(planet.dna) == "table" then planet.dna else {}
	for id, v in dna do
		if type(id) ~= "string" or not finite(v) then
			dna[id] = nil
		end
	end
	for _, param in PlanetConfig.DNA_ORDER do
		local v = dna[param]
		dna[param] = if finite(v) then PlanetConfig.clampDna(param, v) else PlanetConfig.DNA_PARAMS[param].default
	end
	planet.dna = dna

	-- branch
	if not PlanetConfig.isSelectableBranch(planet.branch) and planet.branch ~= PlanetConfig.DEFAULT_BRANCH then
		if planet.branch ~= nil then
			planet.legacy = if type(planet.legacy) == "table" then planet.legacy else {}
			planet.legacy.invalidBranch = tostring(planet.branch)
		end
		planet.branch = PlanetConfig.DEFAULT_BRANCH
	end

	-- formations: { n, t }; legacy numbers (v1 timestamps) become { n = 1, t = ts }
	local formations = if type(planet.formations) == "table" then planet.formations else {}
	for id, rec in formations do
		if not ItemCatalog.isValidIdString(id) then
			formations[id] = nil
			continue
		end
		if rec == true or finite(rec) then
			rec = { n = 1, t = if finite(rec) then rec else now }
		elseif type(rec) ~= "table" then
			formations[id] = nil
			continue
		end
		local def = FormationRegistry.DEFS[id]
		local n = int(rec.n, 0, if def then def.maxCount else 99, 0)
		if n <= 0 then
			formations[id] = nil
		else
			formations[id] = { n = n, t = tsOrNil(rec.t) or now }
		end
	end
	planet.formations = formations

	planet.seed = int(planet.seed, 1, 2147483646, 0)
	if planet.seed == 0 then
		planet.seed = Validator.seedFor(userId)
	end
	planet.rev = int(planet.rev, 0, 2 ^ 31, 0)
	planet.stage = int(planet.stage, 0, PlanetConfig.MAX_EVOLUTION_STAGE, 0)

	-- equipped cosmetics must exist, match the slot category and be owned
	local cos = if type(planet.cosmetics) == "table" then planet.cosmetics else {}
	local clean = {}
	for slot, cid in cos do
		local e = ItemCatalog.COSMETICS[cid]
		if type(slot) == "string" and e and e.category == slot and (ownedCosmetics == nil or ownedCosmetics[cid] ~= nil) then
			clean[slot] = cid
		end
	end
	planet.cosmetics = clean

	local stageAt = if type(planet.stageAt) == "table" then planet.stageAt else {}
	local cleanStage = {}
	for k = 1, PlanetConfig.MAX_EVOLUTION_STAGE do
		local t = tsOrNil(stageAt["s" .. k])
		if t then
			cleanStage["s" .. k] = t
		end
	end
	planet.stageAt = cleanStage

	local log = if type(planet.branchLog) == "table" then planet.branchLog else {}
	local history = {}
	if type(log.history) == "table" then
		for _, b in ipairs(log.history) do
			if PlanetConfig.getBranch(b) and #history < 20 then
				table.insert(history, b)
			end
		end
	end
	planet.branchLog = { committedAt = tsOrNil(log.committedAt), respecs = int(log.respecs, 0, MAX_COUNTER, 0), history = history }
	return planet
end

function Validator.reconcileCodex(codex: any, now: number): any
	if type(codex) ~= "table" then
		return {}
	end
	for id, rec in codex do
		if not ItemCatalog.isValidIdString(id) or type(rec) ~= "table" then
			codex[id] = nil
			continue
		end
		local n = int(rec.n, 0, MAX_COUNTER, 0)
		local d = tsOrNil(rec.d)
		if n > 0 and not d then
			d = now
		end
		if not d then
			codex[id] = nil
			continue
		end
		local f = nil
		if type(rec.f) == "table" then
			f = {
				stage = int(rec.f.stage, 0, PlanetConfig.MAX_EVOLUTION_STAGE, 0),
				branch = if PlanetConfig.getBranch(rec.f.branch) then rec.f.branch else PlanetConfig.DEFAULT_BRANCH,
				rev = int(rec.f.rev, 0, 2 ^ 31, 0),
			}
		end
		codex[id] = { n = math.max(n, 1), d = d, m = tsOrNil(rec.m), f = f }
	end
	return codex
end

-- Cross-field consistency once planet + codex are clean: recompute the authoritative stage.
function Validator.finalize(p: any)
	local planet = p.planet
	if planet.branch ~= PlanetConfig.DEFAULT_BRANCH then
		-- a branch needs a Terraforming world; corrupt data -> safely unspecialize (formations are kept)
		local probe = EvolutionRules.viewFromProfile(p)
		probe.branch = PlanetConfig.DEFAULT_BRANCH
		if EvolutionRules.computeStage(probe) < 2 then
			planet.legacy = if type(planet.legacy) == "table" then planet.legacy else {}
			planet.legacy.unsupportedBranch = planet.branch
			planet.branch = PlanetConfig.DEFAULT_BRANCH
		end
	end
	planet.stage = EvolutionRules.computeStage(EvolutionRules.viewFromProfile(p))
end

return Validator
