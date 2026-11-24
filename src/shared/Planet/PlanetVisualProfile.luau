--!strict
-- PlanetVisualProfile — owner: Developer A. PURE mapping  PlanetVisualContract.State -> VisualSpec.
-- No Instances, no randomness except the deterministic seed derived from the OWNER (so a planet looks the
-- same in every server, whatever temporary slot it gets). Unit-tested.
--
-- Stages (PlanetConfig.MAX_EVOLUTION_STAGE = 5):
--   0 BARREN        grey craters, subtle dust
--   1 PRIMORDIAL    thin atmosphere, geological activity (vents, glowing fissures, spires), warmer tint
--   2 TERRAFORMING  basins fill with water, clouds, thicker atmosphere, first biome patches
--   3 SPECIALIZED   surface transforms to the branch theme, theme formations
--   4 ADVANCED      landmark, dense formations, theme lighting/particles, orbital ring
--   5 ASCENDED      everything of 4 + second ring, moonlet, aura (extra milestone; B's max stage is 5)
-- Branch -> theme (stage >= 3): PlanetConfig.BRANCHES[branch].theme (B's v2: Living/Frozen/Volcanic/Crystal;
-- None and future themes without art -> "primordial" look). Old v1 ids stay mapped via BRANCH_THEME.
-- DNA v2: Temperature (0..100), Water, Life, CosmicEnergy. v1 names are still read as fallbacks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.PF_Shared
local PlanetConfig = require(Shared.Config.PlanetConfig)
-- Developer B's visual tuning (EvolutionConfig.VISUAL), optional so this module never breaks if it moves.
local okEC, EvolutionConfig = pcall(function()
	return require(Shared.Config.EvolutionConfig)
end)
local VIS = (okEC and type(EvolutionConfig) == "table" and EvolutionConfig.VISUAL) or {}

local PlanetVisualProfile = {}
PlanetVisualProfile.VISUAL = VIS

PlanetVisualProfile.STAGE_NAMES = table.freeze({ [0] = "Barren", "Primordial", "Terraforming", "Specialized", "Advanced", "Ascended" })

PlanetVisualProfile.BRANCH_THEME = table.freeze({
	Primordial = "living",
	Cryogenic = "frozen",
	Volcanic = "volcanic",
	Stellar = "crystal",
	-- forward-compatible aliases (not yet branches in PlanetConfig)
	Living = "living",
	Verdant = "living",
	Crystal = "crystal",
	Crystalline = "crystal",
	Frozen = "frozen",
})

-- FUTURE BRANCHES — ART STUBS (no authored art yet). Each renders with an existing builder set (`base`) and
-- its own placeholder palette so the planets are distinguishable in tests. Replace an entry with a real
-- theme (palette + builders + assets) when the branch gets art; the contract does not change.
PlanetVisualProfile.ART_STUBS = table.freeze({
	astral = {
		base = "crystal",
		palette = {
			surface = Color3.fromRGB(150, 140, 200), surfaceMat = Enum.Material.Slate, basin = Color3.fromRGB(220, 200, 255), basinMat = Enum.Material.Glass,
			water = Color3.fromRGB(200, 220, 255), atmosphere = Color3.fromRGB(255, 225, 160), glow = Color3.fromRGB(255, 215, 120), accent = Color3.fromRGB(255, 240, 190),
			secondary = Color3.fromRGB(160, 200, 255), cloud = Color3.fromRGB(255, 245, 225), particle = Color3.fromRGB(255, 230, 160), rock = Color3.fromRGB(170, 160, 210),
		},
	},
	void = {
		base = "crystal",
		palette = {
			surface = Color3.fromRGB(58, 48, 78), surfaceMat = Enum.Material.Slate, basin = Color3.fromRGB(30, 10, 50), basinMat = Enum.Material.Glass,
			water = Color3.fromRGB(40, 20, 60), atmosphere = Color3.fromRGB(120, 60, 200), glow = Color3.fromRGB(190, 90, 255), accent = Color3.fromRGB(120, 60, 200),
			secondary = Color3.fromRGB(255, 80, 180), cloud = Color3.fromRGB(90, 70, 120), particle = Color3.fromRGB(200, 120, 255), rock = Color3.fromRGB(80, 66, 110),
		},
	},
	desert = {
		base = "primordial",
		palette = {
			surface = Color3.fromRGB(214, 180, 120), surfaceMat = Enum.Material.Sand, basin = Color3.fromRGB(190, 150, 95), basinMat = Enum.Material.Sandstone,
			water = Color3.fromRGB(70, 150, 170), atmosphere = Color3.fromRGB(255, 210, 150), glow = Color3.fromRGB(255, 170, 80), accent = Color3.fromRGB(150, 170, 80),
			secondary = Color3.fromRGB(230, 120, 70), cloud = Color3.fromRGB(240, 225, 200), particle = Color3.fromRGB(240, 200, 140), rock = Color3.fromRGB(170, 130, 90),
		},
	},
	mechanical = {
		base = "crystal",
		palette = {
			surface = Color3.fromRGB(120, 124, 132), surfaceMat = Enum.Material.DiamondPlate, basin = Color3.fromRGB(70, 80, 90), basinMat = Enum.Material.Metal,
			water = Color3.fromRGB(60, 140, 200), atmosphere = Color3.fromRGB(170, 200, 220), glow = Color3.fromRGB(80, 220, 255), accent = Color3.fromRGB(255, 170, 60),
			secondary = Color3.fromRGB(160, 170, 180), cloud = Color3.fromRGB(200, 205, 210), particle = Color3.fromRGB(120, 230, 255), rock = Color3.fromRGB(95, 100, 110),
		},
	},
})

-- Returns the stub key ("astral", ...) for a planet whose branch has no art yet, else nil.
function PlanetVisualProfile.artStubFor(branch: string, stage: number): string?
	if stage < 3 then
		return nil
	end
	local b = PlanetConfig.getBranch(branch)
	local t = b and b.theme
	return if t and PlanetVisualProfile.ART_STUBS[t] then t else nil
end

PlanetVisualProfile.IMPLEMENTED_THEMES = table.freeze({ "barren", "primordial", "living", "frozen", "volcanic", "crystal" })
PlanetVisualProfile.FUTURE_THEMES = table.freeze({ "astral", "void", "desert", "mechanical" })

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Per-theme art direction. Materials are built-in Roblox materials (no external assets).
local PALETTES = {
	barren = { surface = rgb(112, 110, 106), surfaceMat = Enum.Material.Rock, basin = rgb(80, 78, 76), basinMat = Enum.Material.Slate },
	primordial = {
		surface = rgb(124, 104, 90), surfaceMat = Enum.Material.Rock, rock = rgb(96, 82, 74), basin = rgb(86, 66, 58), basinMat = Enum.Material.Slate,
		water = rgb(52, 104, 158), atmosphere = rgb(150, 180, 230), glow = rgb(255, 120, 50), accent = rgb(96, 150, 92), cloud = rgb(235, 238, 245),
	},
	living = {
		surface = rgb(124, 196, 98), surfaceMat = Enum.Material.Grass, basin = rgb(74, 136, 70), rock = rgb(112, 120, 100), basinMat = Enum.Material.Grass,
		water = rgb(40, 116, 178), atmosphere = rgb(120, 195, 255), glow = rgb(90, 255, 220), accent = rgb(255, 140, 220),
		secondary = rgb(255, 220, 90), cloud = rgb(245, 248, 255), particle = rgb(210, 255, 140),
	},
	frozen = {
		surface = rgb(196, 220, 238), surfaceMat = Enum.Material.Glacier, rock = rgb(150, 175, 200), basin = rgb(150, 198, 236), basinMat = Enum.Material.Ice,
		water = rgb(150, 205, 245), atmosphere = rgb(175, 225, 255), glow = rgb(90, 200, 255), accent = rgb(60, 140, 255),
		secondary = rgb(130, 255, 200), cloud = rgb(240, 248, 255), particle = rgb(240, 248, 255),
	},
	volcanic = {
		surface = rgb(104, 78, 70), surfaceMat = Enum.Material.Rock, rock = rgb(48, 40, 42), basin = rgb(255, 92, 24), basinMat = Enum.Material.Neon,
		water = rgb(255, 92, 24), atmosphere = rgb(255, 120, 70), glow = rgb(255, 110, 30), accent = rgb(255, 190, 60),
		secondary = rgb(70, 60, 62), cloud = rgb(90, 80, 84), particle = rgb(255, 150, 60),
	},
	crystal = {
		surface = rgb(132, 116, 186), surfaceMat = Enum.Material.Slate, rock = rgb(150, 120, 210), basin = rgb(170, 110, 255), basinMat = Enum.Material.Glass,
		water = rgb(120, 220, 255), atmosphere = rgb(190, 145, 255), glow = rgb(90, 230, 255), accent = rgb(175, 110, 255),
		secondary = rgb(255, 120, 220), cloud = rgb(230, 215, 255), particle = rgb(160, 235, 255),
	},
}
PlanetVisualProfile.PALETTES = PALETTES

export type Spec = {
	slot: number,
	stage: number,
	stageName: string,
	theme: string,
	branchKnown: boolean,
	seed: number,
	surface: { color: Color3, material: Enum.Material },
	basins: { color: Color3, material: Enum.Material, transparency: number, water: boolean },
	extraWater: number,
	atmosphere: { color: Color3, transparency: number, scale: number }?,
	clouds: number,
	polarCaps: boolean,
	vents: number,
	fissures: number,
	spires: number,
	patches: number,
	formations: number,
	props: number,
	veins: number,
	landmark: boolean,
	rings: number,
	moon: boolean,
	aura: boolean,
	particles: { color: Color3, rate: number }?,
	glow: number, -- 0..1 neon intensity factor from CosmicEnergy (v1: Luminosity)
	lifeDensity: number?,
	themeLabel: string,
	artStub: boolean,
	branch: string,
	formationCounts: { [string]: number },
	-- raw DNA (0..100) for density-driven formations (FormationDensity.layout), 2026-11-23
	dna: { Life: number, Water: number, Temperature: number, CosmicEnergy: number },
	palette: { [string]: any },
}

-- Deterministic 31-bit seed from the persistent owner (fallback: slot).
function PlanetVisualProfile.seedFor(ownerUserId: number, slot: number): number
	local base = if ownerUserId > 0 then ownerUserId else slot * 7919
	local h = 2166136261
	local str = tostring(base)
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * 16777619) % 4294967296
	end
	return h % 2147483647
end

function PlanetVisualProfile.themeFor(branch: string, stage: number): (string, boolean)
	if stage <= 0 then
		return "barren", true
	end
	if stage <= 2 then
		return "primordial", true
	end
	local b = PlanetConfig.getBranch(branch)
	local t = (b and b.theme) or PlanetVisualProfile.BRANCH_THEME[branch]
	if t and PALETTES[t] and t ~= "barren" then
		return t, true
	end
	local stub = t and PlanetVisualProfile.ART_STUBS[t]
	if stub then
		return stub.base, true
	end
	-- None (unspecialized) or a future theme without art yet -> keep the terraformed look
	return "primordial", b ~= nil
end

function PlanetVisualProfile.build(state: any): Spec
	local stage = state.stage :: number
	local dna = state.dna :: { [string]: number }
	local theme, known = PlanetVisualProfile.themeFor(state.branch, stage)
	local stubKey = PlanetVisualProfile.artStubFor(state.branch, stage)
	local pal = if stubKey then PlanetVisualProfile.ART_STUBS[stubKey].palette else PALETTES[theme]
	local tDef = PlanetConfig.DNA_PARAMS.Temperature
	local tMin, tMax = (tDef and tDef.min) or 0, (tDef and tDef.max) or 100
	local t01 = math.clamp(((dna.Temperature or (tMin + tMax) / 2) - tMin) / math.max(1, tMax - tMin), 0, 1)
	local hydro = math.clamp((dna.Water or dna.Hydrosphere or 20) / 100, 0, 1)
	local life = math.clamp((dna.Life or 0) / 100, 0, 1)
	local energy = math.clamp((dna.CosmicEnergy or dna.Luminosity or 40) / 100, 0, 1)
	local atmo = if dna.Atmosphere then dna.Atmosphere / 100 else math.clamp(0.15 + 0.35 * hydro + 0.5 * life, 0, 1)
	local temp = t01 * 2 - 1 -- -1 cold .. +1 hot (cold < -0.5 -> polar caps)
	local tect = 0.7 + 0.6 * (if dna.Tectonics then dna.Tectonics / 100 else 0.3 + 0.7 * t01)
	local lum = energy
	local atmoFrom = VIS.ATMOSPHERE_FROM_STAGE or 1
	local ringFrom = VIS.RING_FROM_STAGE or 4
	local patchesByStage = VIS.PATCHES_BY_STAGE or {}
	local function n(x: number): number
		return math.max(0, math.floor(x * tect + 0.5))
	end

	local spec: Spec = {
		slot = state.slot,
		stage = stage,
		stageName = PlanetVisualProfile.STAGE_NAMES[stage],
		theme = theme,
		branchKnown = known,
		seed = PlanetVisualProfile.seedFor(state.ownerUserId, state.slot),
		surface = { color = pal.surface, material = pal.surfaceMat },
		basins = { color = pal.basin, material = pal.basinMat, transparency = 0, water = false },
		extraWater = 0,
		atmosphere = nil,
		clouds = 0,
		polarCaps = false,
		vents = 0,
		fissures = 0,
		spires = 0,
		patches = 0,
		formations = 0,
		props = 0,
		veins = 0,
		landmark = false,
		rings = 0,
		moon = false,
		aura = false,
		particles = nil,
		glow = 0.35 + 0.65 * lum,
		palette = pal,
		themeLabel = stubKey or theme, -- what players see (banner); `theme` = builder set
		artStub = stubKey ~= nil,
		rock = { color = pal.rock or pal.surface, material = if theme == "crystal" then Enum.Material.Glass elseif theme == "frozen" then Enum.Material.Ice else Enum.Material.Rock },
		branch = state.branch,
		formationCounts = state.formations or {},
		dna = {
			Life = dna.Life or 0,
			Water = dna.Water or dna.Hydrosphere or 0,
			Temperature = dna.Temperature or 50,
			CosmicEnergy = dna.CosmicEnergy or dna.Luminosity or 0,
		},
		lifeDensity = 0,
	}
	if stage == 0 then
		return spec
	end

	-- 1 PRIMORDIAL
	if stage >= atmoFrom then
		spec.atmosphere = { color = pal.atmosphere, transparency = 0.94 - 0.03 * atmo, scale = 1.07 + 0.03 * atmo }
	end
	spec.patches = patchesByStage[1] or 0
	spec.vents = n(5)
	spec.fissures = n(4)
	spec.spires = n(8)
	if stage == 1 then
		return spec
	end

	-- 2 TERRAFORMING
	spec.basins = { color = pal.water, material = Enum.Material.Glass, transparency = 0.15, water = true }
	spec.extraWater = math.floor(4 + 10 * hydro)
	spec.atmosphere = { color = pal.atmosphere, transparency = 0.9 - 0.05 * atmo, scale = 1.09 + 0.04 * atmo }
	spec.clouds = math.floor(6 + 10 * atmo)
	spec.patches = patchesByStage[2] or n(12)
	spec.polarCaps = temp < -0.5
	spec.lifeDensity = life
	if stage == 2 then
		return spec
	end

	-- 3 SPECIALIZED (theme takes over the surface)
	spec.basins = { color = pal.water, material = if theme == "volcanic" then Enum.Material.Neon elseif theme == "frozen" then Enum.Material.Ice else Enum.Material.Glass, transparency = if theme == "crystal" then 0.25 else 0.1, water = true }
	spec.vents = if theme == "volcanic" then n(6) else 0
	spec.fissures = if theme == "volcanic" or theme == "crystal" then n(6) else 0
	spec.spires = n(4)
	spec.patches = patchesByStage[3] or n(8)
	spec.formations = n(math.floor(14 + 12 * (if theme == "living" then life else 0.6)))
	spec.props = n(18)
	spec.veins = if theme == "crystal" or theme == "volcanic" then n(6) else 0
	spec.polarCaps = theme == "frozen" or (theme == "living" and temp < -0.5)
	spec.clouds = if theme == "volcanic" then 4 else spec.clouds
	if stage == 3 then
		return spec
	end

	-- 4 ADVANCED
	spec.surface = {
		color = pal.surface,
		material = pal.surfaceMat, -- (CrackedLava read pitch black under the night key light)
	}
	spec.formations = n(math.floor(24 + 14 * (if theme == "living" then life else 0.7)))
	spec.props = n(26)
	spec.patches = patchesByStage[4] or spec.patches
	spec.veins = if theme == "crystal" or theme == "volcanic" then n(10) else 0
	spec.landmark = true
	spec.rings = if stage >= ringFrom then 1 else 0
	spec.particles = { color = pal.particle, rate = 6 }
	spec.atmosphere = { color = pal.atmosphere, transparency = 0.86 - 0.05 * atmo, scale = 1.1 + 0.04 * atmo }
	if stage == 4 then
		return spec
	end

	-- 5 ASCENDED
	spec.formations = n(40)
	spec.rings = 2
	spec.moon = true
	spec.aura = true
	spec.particles = { color = pal.particle, rate = 8 }
	return spec
end

-- Rough upper bound of near-LOD parts for a spec (budget checks / tests).
function PlanetVisualProfile.estimateParts(spec: Spec): number
	return spec.extraWater + spec.clouds * 4 + spec.vents * 3 + spec.fissures * 6 + spec.spires * 2 + spec.patches
		+ spec.formations * 4 + spec.props * 2 + spec.veins * 6 + (if spec.landmark then 40 else 0) + spec.rings * 48
		+ (if spec.moon then 2 else 0) + (if spec.aura then 1 else 0) + (if spec.atmosphere then 1 else 0) + (if spec.polarCaps then 14 else 0)
end

return PlanetVisualProfile
