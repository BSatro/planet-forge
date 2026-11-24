--!strict
-- ItemCatalog — owner: Developer B. Registry of every PERSISTED id: currencies, materials, catalysts and
-- unlockables. Profiles store maps keyed by these ids, so adding a material/catalyst/unlock is just a new
-- entry here: old saves lack the key and are reconciled to 0 / locked (no migration needed).
-- RULES: never rename or reuse a shipped id. To remove one, set `retired = true` (saves keep the value,
-- the id just stops being transactable/visible).

local FormationRegistry = require(script.Parent.Parent.Evolution.FormationRegistry)

local ItemCatalog = {}

ItemCatalog.MAX_ID_LENGTH = 48

-- NOTE: currency id "CosmicEnergy" is the harvester's spendable energy. It is DISPLAYED as
-- "Harvest Energy" so it is never confused with the Planet DNA parameter "Cosmic Energy".
ItemCatalog.CURRENCIES = {
	Credits = { displayName = "Credits", order = 1 },
	CosmicEnergy = { displayName = "Harvest Energy", order = 2 },
}

-- Materials: the single source of truth for resource metadata. Reaction compatibility is derived from
-- Evolution.ReactionRegistry at runtime (ReactionRegistry.reactionsUsing(materialId)).
--   category, description, iconColor (UI placeholder until Developer A provides icons), icon (asset id or
--   nil), maxAmount (storage cap), relevance (base progression relevance, UI hint 1..3)
ItemCatalog.MATERIALS = {
	IceMatter = {
		displayName = "Ice Matter",
		element = "Ice",
		order = 1,
		category = "Elemental",
		description = "Frozen cosmic matter. Raises Water and cools the planet.",
		iconColor = Color3.fromRGB(150, 225, 255),
		maxAmount = 100000,
		relevance = 3,
	},
	MagmaMatter = {
		displayName = "Magma Matter",
		element = "Magma",
		order = 2,
		category = "Elemental",
		description = "Molten rock. Raises Temperature and geological activity.",
		iconColor = Color3.fromRGB(255, 120, 40),
		maxAmount = 100000,
		relevance = 3,
	},
	PlasmaMatter = {
		displayName = "Plasma Matter",
		element = "Plasma",
		order = 3,
		category = "Elemental",
		description = "Charged stellar plasma. Raises Cosmic Energy.",
		iconColor = Color3.fromRGB(210, 110, 255),
		maxAmount = 100000,
		relevance = 3,
	},
	CrystalFragments = {
		displayName = "Crystal Fragments",
		element = "Crystal",
		order = 4,
		category = "Mineral",
		description = "Prismatic shards for mineral formations and advanced reactions.",
		iconColor = Color3.fromRGB(255, 150, 230),
		maxAmount = 100000,
		relevance = 2,
	},
	BioEssence = {
		displayName = "Bio Essence",
		element = "Life",
		order = 5,
		category = "Organic",
		description = "Living spores drifting through space. Fuels biological growth.",
		iconColor = Color3.fromRGB(120, 255, 140),
		maxAmount = 100000,
		relevance = 2,
	},
	CosmicCatalyst = {
		displayName = "Cosmic Catalyst",
		element = "Cosmic",
		order = 6,
		category = "Special",
		description = "A rare reagent for special reactions, specializations and landmarks.",
		iconColor = Color3.fromRGB(255, 230, 120),
		maxAmount = 99,
		relevance = 1,
	},
}

ItemCatalog.CATALYSTS = {
	FrostSeed = { displayName = "Frost Seed", element = "Ice", maxStack = 99, order = 1 },
	EmberCore = { displayName = "Ember Core", element = "Magma", maxStack = 99, order = 2 },
	IonSpark = { displayName = "Ion Spark", element = "Plasma", maxStack = 99, order = 3 },
}

-- Formations come from Evolution.FormationRegistry (single source). The v1 placeholder ids are retired:
-- old saves keep them (data is never deleted) but they are not rendered or granted.
ItemCatalog.FORMATIONS = {
	CrystalSpires = { displayName = "Crystal Spires", retired = true },
	GlacierShelf = { displayName = "Glacier Shelf", retired = true },
	LavaRivers = { displayName = "Lava Rivers", retired = true },
	BasaltColumns = { displayName = "Basalt Columns", retired = true },
	AuroraVeil = { displayName = "Aurora Veil", retired = true },
	StormRings = { displayName = "Storm Rings", retired = true },
} :: { [string]: any }
for id, def in FormationRegistry.DEFS do
	ItemCatalog.FORMATIONS[id] = { displayName = def.displayName, branch = def.branch, maxStack = def.maxCount }
end

ItemCatalog.COSMETICS = {
	Halo_Azure = { displayName = "Azure Halo", category = "PlanetHalo" },
	Halo_Ember = { displayName = "Ember Halo", category = "PlanetHalo" },
	Trail_Stardust = { displayName = "Stardust Trail", category = "Trail" },
	-- Planet appearance (equippable through Evolution_Cosmetic; granted by stage/mastery milestones)
	Atmosphere_Verdant = { displayName = "Verdant Atmosphere", category = "Atmosphere", color = Color3.fromRGB(120, 255, 150) },
	Atmosphere_Glacial = { displayName = "Glacial Atmosphere", category = "Atmosphere", color = Color3.fromRGB(170, 230, 255) },
	Atmosphere_Ember = { displayName = "Ember Atmosphere", category = "Atmosphere", color = Color3.fromRGB(255, 130, 60) },
	Atmosphere_Prismatic = { displayName = "Prismatic Atmosphere", category = "Atmosphere", color = Color3.fromRGB(220, 140, 255) },
	Ring_Celestial = { displayName = "Celestial Ring", category = "PlanetRing", color = Color3.fromRGB(255, 230, 160) },
	Ring_Primordial = { displayName = "Primordial Ring", category = "PlanetRing", color = Color3.fromRGB(180, 200, 220) },
	-- Premium presentation cosmetics (Game Passes, see MonetizationConfig). Fixed contents, never random.
	Atmosphere_Nebula = { displayName = "Nebula Veil", category = "Atmosphere", color = Color3.fromRGB(170, 110, 255), color2 = Color3.fromRGB(255, 120, 210), sky = true, premium = true },
	Atmosphere_Solaris = { displayName = "Solaris Corona", category = "Atmosphere", color = Color3.fromRGB(255, 196, 96), color2 = Color3.fromRGB(255, 110, 60), sky = true, premium = true },
	Atmosphere_Abyss = { displayName = "Abyssal Tide", category = "Atmosphere", color = Color3.fromRGB(70, 130, 255), color2 = Color3.fromRGB(40, 220, 255), sky = true, premium = true },
	Atmosphere_Aurora = { displayName = "Aurora Mantle", category = "Atmosphere", color = Color3.fromRGB(90, 255, 190), color2 = Color3.fromRGB(150, 140, 255), sky = true, premium = true },
	Ring_Halo = { displayName = "Golden Halo", category = "PlanetRing", color = Color3.fromRGB(255, 214, 120), style = "halo", premium = true },
	Ring_Saturnine = { displayName = "Saturnine Bands", category = "PlanetRing", color = Color3.fromRGB(232, 204, 160), color2 = Color3.fromRGB(150, 118, 92), style = "bands", premium = true },
	Ring_Prism = { displayName = "Prism Ring", category = "PlanetRing", color = Color3.fromRGB(255, 255, 255), style = "prism", premium = true },
	HarvesterFX_Solar = { displayName = "Solar Flare Beam", category = "HarvesterFX", color = Color3.fromRGB(255, 190, 80), color2 = Color3.fromRGB(255, 110, 40), premium = true },
	HarvesterFX_Void = { displayName = "Void Lance", category = "HarvesterFX", color = Color3.fromRGB(175, 95, 255), color2 = Color3.fromRGB(70, 25, 140), premium = true },
	HarvesterFX_Aurora = { displayName = "Aurora Stream", category = "HarvesterFX", color = Color3.fromRGB(90, 255, 190), color2 = Color3.fromRGB(120, 170, 255), premium = true },
}

-- Categories a player can equip on their planet / harvester (Evolution_Cosmetic, presets, store).
ItemCatalog.EQUIPPABLE_CATEGORIES = table.freeze({ Atmosphere = true, PlanetRing = true, HarvesterFX = true })

ItemCatalog.DISCOVERIES = {
	FirstHarvest = { displayName = "First Harvest", unlocksCodex = "Codex_Harvesting" },
	FrozenCore = { displayName = "Frozen Core", unlocksCodex = "Codex_IceMatter" },
	MoltenHeart = { displayName = "Molten Heart", unlocksCodex = "Codex_MagmaMatter" },
	PlasmaBloom = { displayName = "Plasma Bloom", unlocksCodex = "Codex_PlasmaMatter" },
	PrismaticShard = { displayName = "Prismatic Shard", unlocksCodex = "Codex_CrystalFragments" },
	LivingSpores = { displayName = "Living Spores", unlocksCodex = "Codex_BioEssence" },
	CometHeart = { displayName = "Comet Heart", unlocksCodex = "Codex_CosmicCatalyst" },
	-- Meteor Overhaul V2: first capture of each new meteor variant (HarvestConfig.TARGET_TYPES[*].discovery)
	IronHeart = { displayName = "Iron Heart" },
	MagneticCore = { displayName = "Magnetic Core" },
	TwinShard = { displayName = "Twin Shard" },
	StellarCore = { displayName = "Stellar Core" },
	VoidEcho = { displayName = "Void Echo" },
	AstralSpark = { displayName = "Astral Spark" },
}

ItemCatalog.CODEX = {
	Codex_Harvesting = { displayName = "Harvesting" },
	Codex_IceMatter = { displayName = "Ice Matter" },
	Codex_MagmaMatter = { displayName = "Magma Matter" },
	Codex_PlasmaMatter = { displayName = "Plasma Matter" },
	Codex_CrystalFragments = { displayName = "Crystal Fragments" },
	Codex_BioEssence = { displayName = "Bio Essence" },
	Codex_CosmicCatalyst = { displayName = "Cosmic Catalyst" },
	Codex_Evolution = { displayName = "Planetary Evolution" },
}

-- section name (as used in profiles / transactions) -> registry
ItemCatalog.SECTIONS = {
	currencies = ItemCatalog.CURRENCIES,
	materials = ItemCatalog.MATERIALS,
	catalysts = ItemCatalog.CATALYSTS,
	formations = ItemCatalog.FORMATIONS,
	cosmetics = ItemCatalog.COSMETICS,
	discoveries = ItemCatalog.DISCOVERIES,
	codex = ItemCatalog.CODEX,
} :: { [string]: { [string]: any } }

function ItemCatalog.isValidIdString(id: any): boolean
	return type(id) == "string" and #id >= 1 and #id <= ItemCatalog.MAX_ID_LENGTH and string.match(id, "^%a[%w_]*$") ~= nil
end

-- Active (non-retired) entry or nil. Safe for any untrusted input.
function ItemCatalog.get(section: any, id: any): any
	if type(section) ~= "string" or not ItemCatalog.isValidIdString(id) then
		return nil
	end
	local reg = ItemCatalog.SECTIONS[section]
	local entry = reg and reg[id]
	if entry == nil or entry.retired then
		return nil
	end
	return entry
end

-- Active ids of a section, sorted by `order` then id.
function ItemCatalog.ids(section: string): { string }
	local reg = ItemCatalog.SECTIONS[section] or {}
	local ids = {}
	for id, entry in reg do
		if not entry.retired then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		local oa, ob = reg[a].order or 1e9, reg[b].order or 1e9
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)
	return ids
end

return ItemCatalog
