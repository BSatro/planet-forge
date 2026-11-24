--!strict
-- PlanetConfig — owner: Developer B. CANONICAL Planet DNA definition (profile schema v2) and branch ids.
--   * DNA: four normalized 0..100 parameters. One representation everywhere: { [paramId]: integer }.
--     Adding a parameter = add an entry + DNA_ORDER; old saves reconcile to `default` (no migration).
--   * Branches: persisted ids. Never rename a shipped id (set `retired = true`). Future branches are
--     declared with enabled = false so data/visual contracts already know their ids and themes.
--   * `theme` values match Developer A's VisualStyle.Themes and are written to the planet model's
--     PFTheme attribute by PlanetVisualAdapter.
-- Values here are prototype balance values (see EvolutionConfig for stages/branch rules).

local PlanetConfig = {}

PlanetConfig.DNA_ORDER = { "Temperature", "Water", "Life", "CosmicEnergy" }

PlanetConfig.DNA_PARAMS = {
	Temperature = {
		displayName = "Temperature",
		short = "TEMP",
		min = 0,
		max = 100,
		default = 40,
		step = 1,
		color = Color3.fromRGB(255, 140, 60),
		description = "Thermal conditions: volcanism, lava activity, instability and ice melting.",
	},
	Water = {
		displayName = "Water",
		short = "WATER",
		min = 0,
		max = 100,
		default = 0,
		step = 1,
		color = Color3.fromRGB(70, 170, 255),
		description = "Oceans, rivers, lakes and ice; needed for biological reactions.",
	},
	Life = {
		displayName = "Life",
		short = "LIFE",
		min = 0,
		max = 100,
		default = 0,
		step = 1,
		color = Color3.fromRGB(110, 230, 120),
		description = "Vegetation, ecosystems and living formations.",
	},
	CosmicEnergy = {
		displayName = "Cosmic Energy",
		short = "COSMIC",
		min = 0,
		max = 100,
		default = 0,
		step = 1,
		color = Color3.fromRGB(200, 120, 255),
		description = "Exotic minerals, crystals, cosmic reactions and energy structures.",
	},
} :: { [string]: { displayName: string, short: string, min: number, max: number, default: number, step: number, color: Color3, description: string } }

PlanetConfig.DEFAULT_BRANCH = "None"

-- Branch registry. `selectable` = can be committed in this build.
PlanetConfig.BRANCH_ORDER = { "Living", "Frozen", "Volcanic", "Crystal", "Astral", "Void", "Desert", "Mechanical" }
PlanetConfig.BRANCHES = {
	None = { displayName = "Unspecialized", theme = "barren", selectable = false },
	Living = { displayName = "Living World", theme = "living", selectable = true, focus = "Water and Life", color = Color3.fromRGB(110, 230, 120) },
	Frozen = { displayName = "Frozen World", theme = "frozen", selectable = true, focus = "Low Temperature and Water", color = Color3.fromRGB(150, 220, 255) },
	Volcanic = { displayName = "Volcanic World", theme = "volcanic", selectable = true, focus = "High Temperature", color = Color3.fromRGB(255, 110, 40) },
	Crystal = { displayName = "Crystal World", theme = "crystal", selectable = true, focus = "Cosmic Energy and crystal reactions", color = Color3.fromRGB(200, 120, 255) },
	-- FUTURE (ids/themes reserved; not selectable yet)
	Astral = { displayName = "Astral World", theme = "astral", selectable = false, future = true },
	Void = { displayName = "Void World", theme = "void", selectable = false, future = true },
	Desert = { displayName = "Desert World", theme = "desert", selectable = false, future = true },
	Mechanical = { displayName = "Mechanical World", theme = "mechanical", selectable = false, future = true },
} :: { [string]: any }

PlanetConfig.MAX_EVOLUTION_STAGE = 4

function PlanetConfig.defaultDna(): { [string]: number }
	local t = {}
	for id, def in PlanetConfig.DNA_PARAMS do
		t[id] = def.default
	end
	return t
end

-- Clamp + quantize a DNA value. Returns nil for unknown params or non-finite input.
function PlanetConfig.clampDna(paramId: any, value: any): number?
	local def = type(paramId) == "string" and PlanetConfig.DNA_PARAMS[paramId]
	if not def or type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	local q = math.floor(value / def.step + 0.5) * def.step
	return math.clamp(q, def.min, def.max)
end

-- Known (non-retired) branch entry, including "None" and future ones.
function PlanetConfig.getBranch(branchId: any): any
	local b = type(branchId) == "string" and PlanetConfig.BRANCHES[branchId]
	if not b or b.retired then
		return nil
	end
	return b
end

-- A branch that can be committed in this build.
function PlanetConfig.isSelectableBranch(branchId: any): boolean
	local b = PlanetConfig.getBranch(branchId)
	return b ~= nil and b.selectable == true
end

return PlanetConfig
