--!strict
-- MeteorRegistry — owner: Gameplay (Cosmic Core Hunt). Read API over the data-driven meteor variant registry
-- (HarvestConfig.TARGET_TYPES, 12 variants) and its rarity tiers (HarvestConfig.RARITIES).
-- Every kind lookup goes through resolve(), so legacy ids (HarvestConfig.ALIASES: "Spore" -> "Bio") keep working
-- for in-flight specs, older callers and saved data. Shared: client (visuals / HUD / prediction) and server.

local HarvestConfig = require(script.Parent.Parent.Config.HarvestConfig)

local Registry = {}

Registry.ORDER = HarvestConfig.TYPE_ORDER :: { string }
Registry.RARITY_ORDER = HarvestConfig.RARITY_ORDER :: { string }

-- Canonical variant id for an id or alias, or nil.
function Registry.resolve(kind: any): string?
	if type(kind) ~= "string" then
		return nil
	end
	if HarvestConfig.TARGET_TYPES[kind] then
		return kind
	end
	local alias = HarvestConfig.ALIASES[kind]
	if alias and HarvestConfig.TARGET_TYPES[alias] then
		return alias
	end
	return nil
end

function Registry.get(kind: any): any
	local id = Registry.resolve(kind)
	return if id then HarvestConfig.TARGET_TYPES[id] else nil
end

-- Rarity definition of a variant (unknown kinds count as common).
function Registry.rarity(kind: any): any
	local def = Registry.get(kind)
	return HarvestConfig.RARITIES[def and def.rarity or "common"] or HarvestConfig.RARITIES.common
end

function Registry.rarityOrder(kind: any): number
	return Registry.rarity(kind).order
end

-- Nominal lane speed in studs/s (before SPAWN.SPEED_JITTER).
function Registry.speed(kind: any): number
	local def = Registry.get(kind)
	return HarvestConfig.SPEED.BASE * (if def then def.speedMultiplier else 1)
end

-- Legacy ids that resolve to `id`.
function Registry.aliasesOf(id: string): { string }
	local out = {}
	for alias, target in HarvestConfig.ALIASES do
		if target == id then
			table.insert(out, alias)
		end
	end
	table.sort(out)
	return out
end

-- Re-keys a { [kind or alias] = value } map to canonical ids (a canonical key wins over its alias).
function Registry.normalizeMap(map: { [string]: any }?): { [string]: any }?
	if map == nil then
		return nil
	end
	local out = {}
	for k, v in map do
		local id = Registry.resolve(k)
		if id and (out[id] == nil or k == id) then
			out[id] = v
		end
	end
	return out
end

-- Renormalized spawn probabilities for a weight table (ids in ORDER). Sums to 1 when any weight > 0.
function Registry.probabilities(weights: { [string]: number }): { [string]: number }
	local total = 0
	for _, id in Registry.ORDER do
		total += math.max(0, weights[id] or 0)
	end
	local out = {}
	if total <= 0 then
		return out
	end
	for _, id in Registry.ORDER do
		local w = math.max(0, weights[id] or 0)
		if w > 0 then
			out[id] = w / total
		end
	end
	return out
end

-- Config validation (tests + boot). Returns ok, { problems }.
function Registry.validate(): (boolean, { string })
	local problems = {}
	local function bad(msg: string)
		table.insert(problems, msg)
	end
	local Config = script.Parent.Parent.Config
	local ItemCatalog = require(Config.ItemCatalog) :: any
	local EconomyConfig = require(Config.EconomyConfig) :: any
	local maxQuality = 1
	for _, q in HarvestConfig.QUALITY_MULTIPLIER do
		maxQuality = math.max(maxQuality, q)
	end
	local seen = {}
	for _, id in Registry.ORDER do
		local def = HarvestConfig.TARGET_TYPES[id]
		if not def then
			bad(id .. ": in TYPE_ORDER but not defined")
			continue
		end
		seen[id] = true
		local rar = HarvestConfig.RARITIES[def.rarity]
		if not rar then
			bad(id .. ": unknown rarity " .. tostring(def.rarity))
		elseif type(def.speedMultiplier) ~= "number" or def.speedMultiplier < rar.speedMin - 1e-9 or def.speedMultiplier > rar.speedMax + 1e-9 then
			bad(id .. ": speedMultiplier outside the " .. def.rarity .. " band")
		end
		if type(def.weight) ~= "number" or def.weight <= 0 then
			bad(id .. ": weight must be > 0")
		end
		if not ItemCatalog.get("materials", def.resource) then
			bad(id .. ": reward resource is not an existing material: " .. tostring(def.resource))
		end
		if def.rewardCategory ~= "material" then
			bad(id .. ": rewardCategory must be 'material'")
		end
		if type(def.multiplier) ~= "number" or def.multiplier <= 0 or def.multiplier * maxQuality > EconomyConfig.HARVEST.MAX_MULTIPLIER + 1e-9 then
			bad(id .. ": reward multiplier out of bounds")
		end
		if def.discovery and not ItemCatalog.get("discoveries", def.discovery) then
			bad(id .. ": unknown discovery " .. tostring(def.discovery))
		end
		local w, p = def.window, def.perfect
		if not (type(def.period) == "number" and def.period > 0 and w and p and w[1] >= 0 and w[2] <= 1 and w[1] < w[2] and p[1] >= w[1] and p[2] <= w[2] and p[1] < p[2]) then
			bad(id .. ": bad timing window")
		end
		if type(def.size) ~= "number" or def.size <= 0 then
			bad(id .. ": bad size")
		end
		local nPatterns = 0
		for pattern, pw in def.patterns or {} do
			nPatterns += 1
			if not HarvestConfig.PATTERNS[pattern] or not table.find(HarvestConfig.PATTERN_ORDER, pattern) or pw <= 0 then
				bad(id .. ": unknown pattern " .. tostring(pattern))
			end
		end
		if nPatterns == 0 then
			bad(id .. ": no patterns")
		end
		if def.telegraph ~= nil and (type(def.telegraph) ~= "number" or def.telegraph < 0 or def.telegraph > 3) then
			bad(id .. ": bad telegraph")
		end
		if def.patterns and def.patterns.void and w then
			local V = HarvestConfig.PATTERNS.void
			local earliest = w[1] - HarvestConfig.FOCUS.MAX_STACKS * HarvestConfig.FOCUS.WINDOW_BONUS
			if not (V.PHASE_FROM >= 0 and V.PHASE_TO < earliest - 0.02) then
				bad(id .. ": void phase-out overlaps the capture window")
			end
		end
	end
	for id in HarvestConfig.TARGET_TYPES do
		if not seen[id] then
			bad(id .. ": defined but missing from TYPE_ORDER")
		end
	end
	for alias, target in HarvestConfig.ALIASES do
		if HarvestConfig.TARGET_TYPES[alias] then
			bad("alias " .. alias .. " shadows a real variant")
		end
		if not HarvestConfig.TARGET_TYPES[target] then
			bad("alias " .. alias .. " -> unknown " .. tostring(target))
		end
	end
	return #problems == 0, problems
end

return Registry
