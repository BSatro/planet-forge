--!strict
-- FormationDensity — owner: Technical Art (planet scale rework, 2026-11-23). THE ONLY place that turns a planet's
-- DNA + owned formations into what the renderer builds. Pure (no Instances, no randomness, no clock), shared:
-- the client renderer (FormationLayer / FormationArt) and the specs require it; the server never duplicates it
-- (it publishes DNA + formation counts, which are already in the PlanetVisualContract attributes).
--
--   scaleFor(def)              art scale of a formation (built at authored size, then Model:ScaleTo(scale))
--   siteCount(def)             how many deterministic sites the site plan reserves for the formation
--   footprintStuds(def)        reserved surface radius after scaling
--   layout(def, owned, dna)    { { elements = e, level = 0..1 } } one entry per site actually used
--
-- Unique / landmark formations: one site per owned unit, capped by FormationRegistry.maxCount (unchanged).
-- DENSITY formations (SPEC below): the purchase is only the seed of a small cluster; the DNA parameter that
-- feeds it grows the element count along a bounded sqrt curve (early DNA points show the most, late points add
-- density without exploding counts). Two modes:
--   "cluster"  elements grow inside clusters (trees in a grove, crystals in a cluster); a cluster fills up to
--              perCluster before the next one starts, so a cluster never LOSES elements while DNA rises
--   "spread"   every element is its own small site (more lakes, lava pools, cracks, veins across the world)
-- level (0..1) = growth on the curve: renderers use it for variety (tree / crystal variants) never for counts.

local FormationDensity = {}

-- Art scale by tier (formations were authored for the 96-stud prototype planet; see ADR-014 rev. 2026-11-23).
-- Tier 1-2 small features, 3-4 notable, 5 major, 6 capstone landmarks (big, but a feature of the world).
FormationDensity.TIER_SCALE = { [1] = 0.6, [2] = 0.6, [3] = 0.66, [4] = 0.66, [5] = 0.74, [6] = 0.82 }
-- Generic theme dressing of PlanetDecorator (trees, mushrooms, spires, ice, crystals, volcanoes, vents, flowers)
FormationDensity.GENERIC_PROP_SCALE = 0.62
-- Prototype radius the art and the exclusion zones were authored on (stud sizes are kept, angles derive from R)
FormationDensity.REFERENCE_RADIUS = 96

export type DensitySpec = {
	mode: string, -- "cluster" | "spread"
	dna: string, -- Life | Water | Temperature | CosmicEnergy
	from: number, -- DNA value where growth starts (about the value the unlock reaction leaves)
	lo: number, -- elements per purchase at `from` and below
	hi: number, -- elements per purchase at DNA 100
	perCluster: number?, -- cluster mode: elements per site
	maxSites: number, -- sites reserved in the plan (hard cap; elements <= maxSites * perCluster)
}

-- `from` values follow ReactionRegistry: the unlocking reaction's DNA requirement + its own DNA effect.
local SPEC: { [string]: DensitySpec } = {
	-- Life -> vegetation
	FirstForest = { mode = "cluster", dna = "Life", from = 25, lo = 2, hi = 8, perCluster = 6, maxSites = 4 },
	GrassPatches = { mode = "spread", dna = "Life", from = 15, lo = 1, hi = 5, maxSites = 5 },
	-- Water -> oceans / ice
	-- ShallowOcean / PlasmaFissures are branch-less, so they repeat on EVERY planet: capped one site lower than
	-- first drafted (5 -> 4, 3 -> 2) after the per-instance cuts, to hold the 8-planet worst case inside budget
	ShallowOcean = { mode = "spread", dna = "Water", from = 25, lo = 1, hi = 3, maxSites = 4 },
	FrozenLake = { mode = "spread", dna = "Water", from = 35, lo = 1, hi = 3, maxSites = 3 },
	IceSpikes = { mode = "cluster", dna = "Water", from = 30, lo = 3, hi = 9, perCluster = 5, maxSites = 2 },
	-- Temperature -> volcanic features
	ThermalCrack = { mode = "spread", dna = "Temperature", from = 20, lo = 1, hi = 4, maxSites = 4 },
	LavaPool = { mode = "spread", dna = "Temperature", from = 60, lo = 1, hi = 3, maxSites = 3 },
	SteamPools = { mode = "spread", dna = "Temperature", from = 55, lo = 1, hi = 2, maxSites = 2 },
	-- CosmicEnergy -> crystals / energy structures
	CrystalCluster = { mode = "cluster", dna = "CosmicEnergy", from = 10, lo = 2, hi = 6, perCluster = 5, maxSites = 4 },
	EnergyVeins = { mode = "spread", dna = "CosmicEnergy", from = 15, lo = 1, hi = 2, maxSites = 5 },
	PlasmaFissures = { mode = "spread", dna = "CosmicEnergy", from = 25, lo = 1, hi = 2, maxSites = 2 },
}
FormationDensity.SPEC = SPEC

function FormationDensity.isDensity(id: string): boolean
	return SPEC[id] ~= nil
end

function FormationDensity.scaleFor(def: any): number
	return FormationDensity.TIER_SCALE[def.tier or 1] or 0.66
end

function FormationDensity.footprintStuds(def: any): number
	return (def.footprint or 6) * FormationDensity.scaleFor(def)
end

function FormationDensity.siteCount(def: any): number
	local s = SPEC[def.id]
	return if s then s.maxSites else (def.maxCount or 1)
end

-- growth 0..1 of a DNA value for a spec: bounded, monotonic, concave (sqrt)
function FormationDensity.growth(s: DensitySpec, value: number?): number
	local v = if type(value) == "number" and value == value then value else 0
	local span = math.max(1, 100 - s.from)
	return math.sqrt(math.clamp((v - s.from) / span, 0, 1))
end

-- Total elements for `owned` purchases (owned is clamped to FormationRegistry.maxCount).
function FormationDensity.elements(def: any, owned: number, dna: { [string]: number }?): (number, number)
	local s = SPEC[def.id]
	local n = math.clamp(math.floor(owned or 0), 0, def.maxCount or 1)
	if not s or n <= 0 then
		return n, 0
	end
	local g = FormationDensity.growth(s, dna and dna[s.dna])
	local perPurchase = s.lo + (s.hi - s.lo) * g
	local cap = s.maxSites * (if s.mode == "cluster" then (s.perCluster or 1) else 1)
	local e = math.clamp(math.floor(n * perPurchase + 0.5), math.min(n * s.lo, cap), cap)
	return e, g
end

-- One entry per site actually used: { elements, level }. Cluster mode fills site 1 before site 2 (never shrinks).
function FormationDensity.layout(def: any, owned: number, dna: { [string]: number }?): { { elements: number, level: number } }
	local s = SPEC[def.id]
	local out = {}
	if not s then
		for _ = 1, math.clamp(math.floor(owned or 0), 0, def.maxCount or 1) do
			table.insert(out, { elements = 0, level = 0 })
		end
		return out
	end
	local e, g = FormationDensity.elements(def, owned, dna)
	if s.mode == "spread" then
		for _ = 1, e do
			table.insert(out, { elements = 1, level = g })
		end
		return out
	end
	local per = s.perCluster or 1
	local left = e
	while left > 0 and #out < s.maxSites do
		local k = math.min(per, left)
		table.insert(out, { elements = k, level = g })
		left -= k
	end
	return out
end

-- Variety by growth level (deterministic choice is made by the renderer's seeded rng from this list).
FormationDensity.VARIANTS = {
	trees = { { 0, { "TreeDefault" } }, { 0.35, { "TreeDefault", "TreeVariant" } }, { 0.65, { "TreeDefault", "TreeVariant", "TreePine" } } },
	crystals = { { 0, { "CrystalBase" } }, { 0.3, { "CrystalBase", "CrystalRed" } }, { 0.6, { "CrystalBase", "CrystalRed", "CrystalGreen", "CrystalIce" } } },
}
function FormationDensity.variants(kind: string, level: number): { string }
	local pick = { "" }
	for _, row in FormationDensity.VARIANTS[kind] or {} do
		if level >= row[1] then
			pick = row[2]
		end
	end
	return pick
end

-- Upper bound of elements a planet can show for a formation (budget checks / specs).
function FormationDensity.maxElements(def: any): number
	local s = SPEC[def.id]
	if not s then
		return def.maxCount or 1
	end
	return s.maxSites * (if s.mode == "cluster" then (s.perCluster or 1) else 1)
end

return FormationDensity
