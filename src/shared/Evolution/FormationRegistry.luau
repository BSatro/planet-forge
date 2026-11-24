--!strict
-- FormationRegistry — owner: Developer B (ids + placement data). Every visual formation a planet can own.
-- Formation ids are PERSISTED (profile.planet.formations[id] = { n = count, t = unlockedAt }); never rename
-- a shipped id. Pure data: no requires, safe everywhere (server, client, tests, ItemCatalog).
--
-- Fields
--   displayName, description
--   branch        nil (generic) | "Living" | "Frozen" | "Volcanic" | "Crystal"
--   tier          1..6 (6 = branch capstone landmark)
--   archetype     renderer builder id (Developer A's renderer maps these to art; the placeholder renderer
--                 in PF_Client.Planet.FormationArt implements every archetype with simple parts)
--   maxCount      instances a planet can grow (each instance has its own deterministic position)
--   footprint     surface radius in studs reserved per instance (no two instances overlap)
--   height        approximate height in studs (UI preview / camera framing)
--   zones         allowed polar-angle bands in degrees from the planet's north pole (0 = pole, 180 = south)
--   dormantOutsideBranch  true -> not rendered while the planet's branch differs (kept in data; returns
--                 when the player switches back). Secondary (false) formations always render.
--   landmark      major silhouette kept even in far LOD
--   effect        transformation effect id used when it appears

local FormationRegistry = {}

export type Formation = {
	id: string,
	displayName: string,
	description: string,
	branch: string?,
	tier: number,
	archetype: string,
	maxCount: number,
	footprint: number,
	height: number,
	zones: { { number } },
	dormantOutsideBranch: boolean,
	landmark: boolean,
	effect: string,
	color: Color3,
}

local EQ = { { 60, 120 } }
local MID = { { 40, 140 } }
local WIDE = { { 30, 165 } }
local COLD = { { 26, 62 }, { 128, 176 } }
local SOUTH = { { 140, 176 } }

local DEFS: { [string]: any } = {
	-- GENERIC (any branch) ----------------------------------------------------------------------------
	IceImpact = { displayName = "Ice Impact Site", description = "The first frozen crater where cosmic ice struck the surface.", tier = 1, archetype = "impact", maxCount = 1, footprint = 8, height = 3, zones = MID, effect = "impact", color = Color3.fromRGB(190, 235, 255) },
	ShallowOcean = { displayName = "Shallow Ocean", description = "A shallow basin of primordial water.", tier = 1, archetype = "ocean", maxCount = 2, footprint = 17, height = 1, zones = { { 80, 150 } }, effect = "ocean", color = Color3.fromRGB(60, 150, 255) },
	SteamPools = { displayName = "Steam Pools", description = "Geothermal pools venting warm steam.", tier = 2, archetype = "steam", maxCount = 1, footprint = 9, height = 6, zones = EQ, effect = "steam", color = Color3.fromRGB(120, 220, 210) },
	PlasmaFissures = { displayName = "Plasma Fissures", description = "Bright energy veins glowing beneath the crust.", tier = 2, archetype = "fissures", maxCount = 1, footprint = 11, height = 1, zones = WIDE, effect = "cosmic", color = Color3.fromRGB(255, 120, 230) },
	CelestialFlora = { displayName = "Celestial Flora", description = "Rare starlit plants that drink cosmic light.", tier = 5, archetype = "celestialFlora", maxCount = 1, footprint = 9, height = 12, zones = MID, effect = "cosmic", color = Color3.fromRGB(200, 170, 255), landmark = true },

	-- LIVING --------------------------------------------------------------------------------------------
	GrassPatches = { displayName = "Small Grass Patches", description = "The first green life on bare rock.", branch = "Living", tier = 1, archetype = "grass", maxCount = 1, footprint = 10, height = 1, zones = MID, effect = "living", color = Color3.fromRGB(110, 210, 90) },
	FirstForest = { displayName = "First Forest", description = "Young trees spreading across the lowlands.", branch = "Living", tier = 2, archetype = "forest", maxCount = 3, footprint = 11, height = 9, zones = MID, effect = "living", color = Color3.fromRGB(70, 170, 80) },
	AncientTree = { displayName = "Ancient Tree", description = "A colossal elder tree, heart of a Living World.", branch = "Living", tier = 3, archetype = "ancientTree", maxCount = 1, footprint = 9, height = 22, zones = { { 50, 130 } }, dormantOutsideBranch = true, effect = "living", color = Color3.fromRGB(90, 200, 100), landmark = true },
	BioluminescentGrove = { displayName = "Bioluminescent Grove", description = "Glowing alien plants fed by cosmic energy.", branch = "Living", tier = 4, archetype = "glowGrove", maxCount = 1, footprint = 9, height = 7, zones = MID, effect = "living", color = Color3.fromRGB(60, 255, 210) },
	LivingWaterfall = { displayName = "Living Waterfall", description = "Sacred springs cascading over mossy cliffs.", branch = "Living", tier = 5, archetype = "waterfall", maxCount = 1, footprint = 10, height = 14, zones = { { 60, 130 } }, dormantOutsideBranch = true, effect = "living", color = Color3.fromRGB(110, 200, 255), landmark = true },
	WorldTree = { displayName = "Giant World Tree", description = "The crown of a Living World, visible from orbit.", branch = "Living", tier = 6, archetype = "worldTree", maxCount = 1, footprint = 15, height = 40, zones = { { 70, 110 } }, dormantOutsideBranch = true, effect = "living", color = Color3.fromRGB(150, 255, 140), landmark = true },

	-- FROZEN --------------------------------------------------------------------------------------------
	FrozenLake = { displayName = "Frozen Lake", description = "A lake sealed under clear blue ice.", branch = "Frozen", tier = 1, archetype = "frozenLake", maxCount = 1, footprint = 10, height = 1, zones = COLD, effect = "frozen", color = Color3.fromRGB(180, 230, 255) },
	IceSpikes = { displayName = "Ice Spikes", description = "Glowing crystalline ice towers.", branch = "Frozen", tier = 2, archetype = "iceSpikes", maxCount = 1, footprint = 8, height = 12, zones = COLD, effect = "frozen", color = Color3.fromRGB(170, 240, 255) },
	GlacierRidge = { displayName = "Glacier Ridge", description = "A long ridge of ancient glacier ice.", branch = "Frozen", tier = 3, archetype = "glacier", maxCount = 1, footprint = 14, height = 8, zones = SOUTH, dormantOutsideBranch = true, effect = "frozen", color = Color3.fromRGB(225, 245, 255), landmark = true },
	CrystalIceCave = { displayName = "Crystal Ice Cave", description = "A glowing cavern carved through blue ice.", branch = "Frozen", tier = 4, archetype = "iceCave", maxCount = 1, footprint = 9, height = 9, zones = { { 120, 170 } }, dormantOutsideBranch = true, effect = "frozen", color = Color3.fromRGB(90, 200, 255) },
	AuroraField = { displayName = "Aurora Field", description = "Curtains of light dancing over the ice.", branch = "Frozen", tier = 5, archetype = "aurora", maxCount = 1, footprint = 14, height = 26, zones = SOUTH, dormantOutsideBranch = true, effect = "frozen", color = Color3.fromRGB(110, 255, 190), landmark = true },
	FrozenCrown = { displayName = "Frozen Crown", description = "A crown of colossal ice spires at the south pole.", branch = "Frozen", tier = 6, archetype = "frozenCrown", maxCount = 1, footprint = 15, height = 34, zones = { { 168, 180 } }, dormantOutsideBranch = true, effect = "frozen", color = Color3.fromRGB(200, 245, 255), landmark = true },

	-- VOLCANIC ------------------------------------------------------------------------------------------
	ThermalCrack = { displayName = "Thermal Crack", description = "Glowing fractures leaking the planet's heat.", branch = "Volcanic", tier = 1, archetype = "thermalCrack", maxCount = 1, footprint = 10, height = 1, zones = EQ, effect = "volcanic", color = Color3.fromRGB(255, 120, 30) },
	LavaPool = { displayName = "Lava Pool", description = "A volcanic vent filled with bubbling lava.", branch = "Volcanic", tier = 2, archetype = "lavaPool", maxCount = 1, footprint = 8, height = 4, zones = EQ, effect = "volcanic", color = Color3.fromRGB(255, 90, 20) },
	BasaltSpires = { displayName = "Basalt Spires", description = "Black hexagonal columns of cooled lava.", branch = "Volcanic", tier = 3, archetype = "basalt", maxCount = 1, footprint = 9, height = 12, zones = { { 60, 130 } }, dormantOutsideBranch = true, effect = "volcanic", color = Color3.fromRGB(60, 50, 50), landmark = true },
	MagmaRiver = { displayName = "Magma River", description = "A river of molten rock carving the surface.", branch = "Volcanic", tier = 4, archetype = "magmaRiver", maxCount = 1, footprint = 16, height = 1, zones = { { 70, 120 } }, dormantOutsideBranch = true, effect = "volcanic", color = Color3.fromRGB(255, 110, 20) },
	VolcanicMountain = { displayName = "Volcanic Mountain", description = "A towering volcano breathing embers.", branch = "Volcanic", tier = 5, archetype = "volcano", maxCount = 1, footprint = 15, height = 26, zones = { { 75, 120 } }, effect = "volcanic", color = Color3.fromRGB(80, 60, 55), landmark = true },
	EternalCore = { displayName = "Eternal Core", description = "A captive star of magma hovering above the crust.", branch = "Volcanic", tier = 6, archetype = "eternalCore", maxCount = 1, footprint = 14, height = 30, zones = { { 95, 135 } }, dormantOutsideBranch = true, effect = "volcanic", color = Color3.fromRGB(255, 150, 40), landmark = true },

	-- CRYSTAL -------------------------------------------------------------------------------------------
	CrystalCluster = { displayName = "Crystal Cluster", description = "Small glowing mineral formations.", branch = "Crystal", tier = 1, archetype = "crystalCluster", maxCount = 3, footprint = 6, height = 6, zones = WIDE, effect = "crystal", color = Color3.fromRGB(200, 120, 255) },
	EnergyVeins = { displayName = "Energy Veins", description = "Luminous plasma veins across the rock.", branch = "Crystal", tier = 2, archetype = "energyVeins", maxCount = 3, footprint = 9, height = 1, zones = WIDE, effect = "cosmic", color = Color3.fromRGB(120, 220, 255) },
	CrystalGarden = { displayName = "Crystal Garden", description = "A field of multicoloured crystals.", branch = "Crystal", tier = 3, archetype = "crystalGarden", maxCount = 1, footprint = 11, height = 8, zones = MID, dormantOutsideBranch = true, effect = "crystal", color = Color3.fromRGB(255, 140, 220), landmark = true },
	ResonanceArch = { displayName = "Resonance Arch", description = "A humming arch of resonating crystal.", branch = "Crystal", tier = 4, archetype = "resonanceArch", maxCount = 1, footprint = 10, height = 16, zones = { { 50, 130 } }, effect = "crystal", color = Color3.fromRGB(150, 230, 255), landmark = true },
	GiantCrystalSpire = { displayName = "Giant Crystal Spire", description = "A single crystal taller than a mountain.", branch = "Crystal", tier = 5, archetype = "crystalSpire", maxCount = 1, footprint = 10, height = 34, zones = { { 60, 120 } }, dormantOutsideBranch = true, effect = "crystal", color = Color3.fromRGB(210, 140, 255), landmark = true },
	CelestialPrism = { displayName = "Celestial Prism", description = "A floating prism that splits starlight.", branch = "Crystal", tier = 6, archetype = "celestialPrism", maxCount = 1, footprint = 13, height = 30, zones = { { 100, 140 } }, dormantOutsideBranch = true, effect = "crystal", color = Color3.fromRGB(255, 200, 255), landmark = true },
}

-- Deterministic order: landmarks reserve their space first, then by tier, then id.
local ORDER = {}
for id, def in DEFS do
	def.id = id
	def.dormantOutsideBranch = def.dormantOutsideBranch == true
	def.landmark = def.landmark == true
	table.insert(ORDER, id)
end
table.sort(ORDER, function(a, b)
	local da, db = DEFS[a], DEFS[b]
	if da.landmark ~= db.landmark then
		return da.landmark
	end
	if da.footprint ~= db.footprint then
		return da.footprint > db.footprint
	end
	return a < b
end)

FormationRegistry.DEFS = DEFS
FormationRegistry.ORDER = ORDER

-- Branch landing pages (UI / previews)
FormationRegistry.BRANCH_FORMATIONS = {
	Living = { "GrassPatches", "FirstForest", "AncientTree", "BioluminescentGrove", "LivingWaterfall", "WorldTree" },
	Frozen = { "FrozenLake", "IceSpikes", "GlacierRidge", "CrystalIceCave", "AuroraField", "FrozenCrown" },
	Volcanic = { "ThermalCrack", "LavaPool", "BasaltSpires", "MagmaRiver", "VolcanicMountain", "EternalCore" },
	Crystal = { "CrystalCluster", "EnergyVeins", "CrystalGarden", "ResonanceArch", "GiantCrystalSpire", "CelestialPrism" },
}

function FormationRegistry.get(id: any): Formation?
	return if type(id) == "string" then DEFS[id] else nil
end

-- Is the formation rendered for a planet on `branch`? (owned formations only)
function FormationRegistry.isActive(id: string, branch: string?): boolean
	local def = DEFS[id]
	if not def then
		return false
	end
	if def.dormantOutsideBranch and def.branch ~= branch then
		return false
	end
	return true
end

return FormationRegistry
