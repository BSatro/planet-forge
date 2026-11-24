--!strict
-- ProfileSchema — owner: Developer B. Shape of the persisted player profile (schema v1).
--
--   schemaVersion          number   (Migrations upgrade older saves)
--   createdAt/lastSaveAt/lastLoginAt  unix seconds;  loginCount, playSeconds
--   level, xp
--   currencies  { [currencyId]: int }      Credits, CosmicEnergy (+ energyUpdatedAt for regen)
--   materials   { [materialId]: int }      IceMatter, MagmaMatter, PlasmaMatter, ...
--   catalysts   { [catalystId]: int }
--   upgrades    { [upgradeId]: level }
--   planet      { dna = { [paramId]: number }, branch = branchId, stage = int,
--                 formations = { [formationId]: unlockedAt } }
--   discoveries / codex / cosmetics   { [id]: unlockedAt }
--   expeditions { history = { record }, active = { [id]: record }, totalCompleted = int }  (future system)
--   stats       { [statId]: int }
--
-- default(now)       -> a brand-new profile (starting kit from EconomyConfig).
-- reconcile(p, now)  -> repairs a (migrated) profile IN PLACE: fills missing sections/keys, drops invalid
--                       values, clamps numbers. Unknown-but-valid ids/keys are KEPT, so removing a catalog
--                       entry or rolling back a release never destroys player data.
-- Additive changes (new material, branch, unlock, DNA param, stat) need NO migration. Renames or
-- restructures need a Migrations step + CURRENT_VERSION bump.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local MonetizationData = require(script.Parent.Parent.Monetization.MonetizationData)
local PlanetStateValidator = require(script.Parent.Parent.Evolution.PlanetStateValidator)
-- quests (Live Gameplay, 2026-11-22): additive section, repaired by the pure QuestRules (no migration needed)
local QuestRules = require(Shared.Quests.QuestRules)

local Schema = {}

-- v2 (Planet DNA & Evolution Engine): planet = { dna{T,W,L,C}, stage, branch, formations{id={n,t}}, seed,
-- rev, cosmetics, stageAt, branchLog }, + reactions (Codex). See Evolution/PlanetStateValidator.
Schema.CURRENT_VERSION = 2

Schema.STAT_IDS = { "creditsEarned", "creditsSpent", "materialsHarvested", "materialsSold", "harvests", "upgradesBought" }

local CAPS = EconomyConfig.BALANCE_CAPS
local COUNTER_MAX = CAPS.counter

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function int(v: any, min: number, max: number, fallback: number): number
	if not isFinite(v) then
		return fallback
	end
	return math.clamp(math.floor(v), min, max)
end

local function ts(v: any, fallback: number): number
	return int(v, 0, DataConfig.MAX_TIMESTAMP, fallback)
end

local function ensureTable(parent: any, key: string): any
	local t = parent[key]
	if type(t) ~= "table" then
		t = {}
		parent[key] = t
	end
	return t
end

-- Storage cap for a balance (live CosmicEnergy cap is applied by EconomyService).
function Schema.capFor(section: string, id: string): number
	if section == "currencies" then
		return CAPS.currencies[id] or CAPS.currencyDefault
	elseif section == "materials" then
		local e = ItemCatalog.MATERIALS[id]
		return if e and e.maxAmount then e.maxAmount else CAPS.material
	elseif section == "catalysts" then
		local e = ItemCatalog.CATALYSTS[id]
		return if e and e.maxStack then e.maxStack else CAPS.catalystDefault
	end
	return 0
end

local function reconcileBalances(map: any, section: string)
	for id, v in map do
		if not ItemCatalog.isValidIdString(id) then
			map[id] = nil
		else
			map[id] = int(v, 0, Schema.capFor(section, id), 0)
		end
	end
	for id in ItemCatalog.SECTIONS[section] do
		if map[id] == nil then
			map[id] = 0
		end
	end
end

local function reconcileSet(set: any, now: number)
	for id, v in set do
		if not ItemCatalog.isValidIdString(id) or v == false then
			set[id] = nil
		elseif v == true then
			set[id] = now
		else
			set[id] = ts(v, now)
		end
	end
end

local function reconcileCounters(map: any)
	for id, v in map do
		if type(id) ~= "string" or not isFinite(v) then
			map[id] = nil
		else
			map[id] = int(v, 0, COUNTER_MAX, 0)
		end
	end
end

-- userId: used only to derive a deterministic world seed when the save has none.
function Schema.reconcile(p: any, now: number, userId: number?): any
	if type(p) ~= "table" then
		p = {}
	end
	p.schemaVersion = Schema.CURRENT_VERSION
	p.createdAt = ts(p.createdAt, now)
	p.lastSaveAt = ts(p.lastSaveAt, 0)
	p.lastLoginAt = ts(p.lastLoginAt, now)
	p.loginCount = int(p.loginCount, 0, COUNTER_MAX, 0)
	p.playSeconds = int(p.playSeconds, 0, COUNTER_MAX, 0)

	p.level = int(p.level, 1, EconomyConfig.LEVEL.MAX_LEVEL, 1)
	p.xp = int(p.xp, 0, COUNTER_MAX, 0)

	reconcileBalances(ensureTable(p, "currencies"), "currencies")
	p.energyUpdatedAt = ts(p.energyUpdatedAt, now)
	reconcileBalances(ensureTable(p, "materials"), "materials")
	reconcileBalances(ensureTable(p, "catalysts"), "catalysts")

	local upgrades = ensureTable(p, "upgrades")
	for id, v in upgrades do
		if not ItemCatalog.isValidIdString(id) then
			upgrades[id] = nil
		else
			local def = EconomyConfig.UPGRADES[id]
			upgrades[id] = int(v, 0, if def then def.maxLevel else COUNTER_MAX, 0)
		end
	end

	reconcileSet(ensureTable(p, "discoveries"), now)
	reconcileSet(ensureTable(p, "codex"), now)
	reconcileSet(ensureTable(p, "cosmetics"), now)

	-- Planet DNA, evolution state and reaction Codex (schema v2)
	p.planet = PlanetStateValidator.reconcilePlanet(p.planet, now, userId, p.cosmetics)
	p.reactions = PlanetStateValidator.reconcileCodex(p.reactions, now)
	p.monetization = MonetizationData.reconcile(p.monetization, now)
	p.quests = QuestRules.reconcile(p.quests) -- daily/weekly quests (INTERFACES §11)

	local exp = ensureTable(p, "expeditions")
	local history = ensureTable(exp, "history")
	local cleaned = {}
	for _, rec in ipairs(history) do
		if type(rec) == "table" then
			table.insert(cleaned, rec)
		end
	end
	while #cleaned > DataConfig.EXPEDITION_HISTORY_MAX do
		table.remove(cleaned, 1)
	end
	exp.history = cleaned
	local active = ensureTable(exp, "active")
	for id, rec in active do
		if not ItemCatalog.isValidIdString(id) or type(rec) ~= "table" then
			active[id] = nil
		end
	end
	exp.totalCompleted = int(exp.totalCompleted, 0, COUNTER_MAX, 0)

	local stats = ensureTable(p, "stats")
	reconcileCounters(stats)
	for _, id in Schema.STAT_IDS do
		if stats[id] == nil then
			stats[id] = 0
		end
	end
	PlanetStateValidator.finalize(p) -- authoritative stage from the rules
	return p
end

function Schema.default(now: number, userId: number?): any
	local S = EconomyConfig.STARTING_BALANCES
	local p = {
		schemaVersion = Schema.CURRENT_VERSION,
		createdAt = now,
		lastSaveAt = 0,
		lastLoginAt = now,
		loginCount = 0,
		playSeconds = 0,
		level = 1,
		xp = 0,
		currencies = table.clone(S.currencies),
		energyUpdatedAt = now,
		materials = table.clone(S.materials),
		catalysts = table.clone(S.catalysts),
		upgrades = {},
		planet = {}, -- barren world: PlanetStateValidator fills DNA defaults, seed, rev 0, stage 0
		reactions = {},
		discoveries = {},
		codex = {},
		cosmetics = {},
		expeditions = { history = {}, active = {}, totalCompleted = 0 },
		stats = {},
	}
	return Schema.reconcile(p, now, userId)
end

return Schema
