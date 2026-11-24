--!strict
-- EvolutionConfig — owner: Developer B. Tunable evolution balance: stages, branch commitment,
-- re-specialization, action limits, visual tuning and the assumptions used by the progression simulator.
-- Reactions live in Evolution.ReactionRegistry, formations in Evolution.FormationRegistry, DNA in
-- PlanetConfig. All values are PROTOTYPE values to be validated with real players.

local EvolutionConfig = {}

local K = "CosmicCatalyst"

-- STAGES ----------------------------------------------------------------------------------------------
-- Stage = overall development (0..4). Branch = specialization. They are separate pieces of state.
-- A stage is reached when ITS requirements and every lower stage's requirements hold (evaluated by the
-- server after each confirmed action; never from a raw resource amount). Stage 3 is entered by
-- deliberately committing a branch. Rewards are granted the FIRST time a stage is reached only.
EvolutionConfig.STAGES = {
	[0] = {
		name = "Barren World",
		description = "A gray rocky sphere scarred by craters.",
		goal = "Harvest matter and try your first reactions.",
	},
	[1] = {
		name = "Primordial World",
		description = "Early geological changes and the first formations.",
		goal = "Experiment with elements: discover 5 reactions, including an ocean or an eruption.",
		requires = { discoveredCount = 2 },
		reward = { credits = 100, xp = 60 },
		effect = "stage",
	},
	[2] = {
		name = "Terraforming World",
		description = "A visible atmosphere, water, minerals and early specialized formations.",
		goal = "Shape the DNA toward a specialization, then commit to a branch.",
		requires = { discoveredCount = 5, discoveredAny = { ids = { "R02", "R04" }, min = 1 } },
		reward = { credits = 200, xp = 120, materials = { [K] = 1 } },
		effect = "stage",
	},
	[3] = {
		name = "Specialized World",
		description = "A clear Living, Frozen, Volcanic or Crystal identity.",
		goal = "Create your branch landmark (capstone) and discover 11 reactions.",
		requires = { branchSet = true },
		reward = { credits = 300, xp = 200 },
		effect = "branch",
	},
	[4] = {
		name = "Advanced World",
		description = "A spectacular mature world with massive landmarks and orbital effects.",
		goal = "Master reactions and customize your world.",
		requires = { branchSet = true, capstone = true, discoveredCount = 11 },
		reward = { credits = 600, xp = 400 },
		cosmeticByBranch = { Living = "Atmosphere_Verdant", Frozen = "Atmosphere_Glacial", Volcanic = "Atmosphere_Ember", Crystal = "Atmosphere_Prismatic" },
		effect = "stage",
	},
} :: { [number]: any }

-- BRANCHES ----------------------------------------------------------------------------------------------
-- Committing is a deliberate, confirmed action (Evolution_Commit with confirm = true). Never automatic.
EvolutionConfig.BRANCH_RULES = {
	Living = {
		requires = { stage = { min = 2 }, discovered = { "R09" }, dna = { Water = { min = 45 }, Life = { min = 25 }, Temperature = { min = 20, max = 65 } } },
		cost = { materials = { BioEssence = 10, IceMatter = 10, [K] = 1 } },
		unlocks = { AncientTree = 1 },
		capstone = "WorldTree",
		effect = "living",
		headline = "Forests, rivers and glowing groves",
		consequences = "Grows the Ancient Tree and unlocks Living reactions (Sacred Springs, World Tree). Landmarks of other branches go dormant (kept, not shown) until you switch back.",
	},
	Frozen = {
		requires = { stage = { min = 2 }, discovered = { "R08" }, dna = { Temperature = { max = 25 }, Water = { min = 35 } } },
		cost = { materials = { IceMatter = 20, CrystalFragments = 5, [K] = 1 } },
		unlocks = { GlacierRidge = 1 },
		capstone = "FrozenCrown",
		effect = "frozen",
		headline = "Snow, glaciers, blue ice and auroras",
		consequences = "Raises a Glacier Ridge and unlocks Frozen reactions (Frozen Caverns, Polar Aurora, Frozen Crown). Landmarks of other branches go dormant until you switch back.",
	},
	Volcanic = {
		requires = { stage = { min = 2 }, discovered = { "R04" }, dna = { Temperature = { min = 75 } } },
		cost = { materials = { MagmaMatter = 20, PlasmaMatter = 5, [K] = 1 } },
		unlocks = { BasaltSpires = 1 },
		capstone = "EternalCore",
		effect = "volcanic",
		headline = "Basalt, magma rivers and volcanoes",
		consequences = "Raises Basalt Spires and unlocks Volcanic reactions (Magma Rivers, Eternal Core). Landmarks of other branches go dormant until you switch back.",
	},
	Crystal = {
		requires = { stage = { min = 2 }, discovered = { "R05", "R06" }, dna = { CosmicEnergy = { min = 40 } } },
		cost = { materials = { CrystalFragments = 15, PlasmaMatter = 10, [K] = 1 } },
		unlocks = { CrystalGarden = 1 },
		capstone = "CelestialPrism",
		effect = "crystal",
		headline = "Violet, cyan and pink crystals and energy",
		consequences = "Grows a Crystal Garden and unlocks Crystal reactions (Crystal Ascension, Celestial Prism). Landmarks of other branches go dormant until you switch back.",
	},
} :: { [string]: any }

-- Re-specialization (switching branch at stage 3+): pay the target branch's commit cost + this fee and
-- meet its DNA/discovery requirements. Codex, cosmetics, materials and all formations are kept; the old
-- branch's landmarks go dormant; stage is re-evaluated (4 -> 3 unless the new branch's capstone is
-- already owned, e.g. switching back). No refunds, no resource duplication.
EvolutionConfig.RESPEC = { credits = 250, minStage = 3 }

-- ACTIONS -------------------------------------------------------------------------------------------------
EvolutionConfig.ACTIONS = {
	REQUIRE_ON_PLANET = true, -- reactions/commits only while standing in your own planet's gravity field
	ON_PLANET_RADIUS_FACTOR = 2.6, -- x planet radius from the planet centre
	ACTION_ID_MAX_LENGTH = 40,
	ACTION_CACHE_SIZE = 32, -- remembered actionIds per player (replay -> same result, no re-execution)
	MILESTONE_SAVE = true, -- request an early (cooldown-limited) profile save after stage/branch changes
}

-- VISUALS (consumed by the renderer through the public state) ------------------------------------------
EvolutionConfig.VISUAL = {
	POLAR_EXCLUSION_DEG = 24, -- no formations near the north pole: warp pad, spawn, harvester (any slot)
	PATCHES_BY_STAGE = { [0] = 0, [1] = 6, [2] = 12, [3] = 18, [4] = 24 },
	PATCH_FOOTPRINT = 7,
	ATMOSPHERE_FROM_STAGE = 2,
	RING_FROM_STAGE = 4,
}

-- PROGRESSION SIMULATOR ASSUMPTIONS (NOT live data; tune after playtests) -----------------------------
EvolutionConfig.SIM = {
	CAPTURES_PER_MINUTE = 6, -- active harvesting, average skill, energy permitting
	PERFECT_SHARE = 0.25,
	DECISION_SECONDS = 6, -- time spent per reaction in the UI
	MAX_MINUTES = 180,
}

return EvolutionConfig
