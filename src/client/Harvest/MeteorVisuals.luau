--!strict
-- MeteorVisuals — owner: Gameplay / Technical Art (VFX). Client-only DECORATIVE meteor models driven by the
-- server's AUTHORITATIVE spec. Each frame the visual is placed at MeteorPath.evaluate(spec, serverNow) — the
-- exact position the server verifies against; the visual core is always centred on that point (hitbox
-- alignment). States: "pending" (announced: approach cue at the entry point), "flight", "phased" (Void: faded
-- + not targetable), "held" (stasis while the server confirms), "captured" (pulled into the collector),
-- "cancelled" (a split parent was captured: fragment fades out).
--
-- RENDERING CONTRACT (Developer A; see METEOR_RENDERING_CONTRACT.md): ReplicatedStorage.PF_Assets.Meteors.<Id>
-- overrides a look (cloned, scaled to spec.size, made non-colliding, light + trail + attachments added).
-- Every live model carries PFMeteorId / PFVariant / PFRarity / PFFragment / PFState. Never move them.
--
-- Presentation data: Harvest/MeteorStyles (variant identity, rarity presence, quality budgets, reduced
-- motion). Performance: no per-meteor connections (HarvestController calls :update for all visuals once per
-- frame), models pooled per look (POOL_MAX), particle budgets by quality preset, distance LOD, particle sizes
-- capped at 0.35 x the hitbox so effects never hide the target.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.PF_Shared
local HarvestConfig = require(Shared.Config.HarvestConfig)
local MeteorPath = require(Shared.Harvest.MeteorPath)
local MeteorRegistry = require(Shared.Harvest.MeteorRegistry)
local Styles = require(script.Parent.MeteorStyles)

local MeteorVisuals = {}
MeteorVisuals.__index = MeteorVisuals

local TEX = Styles.TEXTURE
local SPAWN_RAMP = 0.45
local EXIT_RAMP = 0.5
local CANCEL_TIME = 0.35
local POOL_MAX = 3
local LOD_FAR = 450 -- studs: beyond this, particles + trail are switched off
local MAG = HarvestConfig.PATTERNS.magnetic
local VOID = HarvestConfig.PATTERNS.void
local HALF_WIDTH = HarvestConfig.ZONE.HALF_WIDTH
local TAU = math.pi * 2
local rgb = Color3.fromRGB

local function part(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function seq(a: number, b: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

local function randomUnit(rng: Random): Vector3
	local z = rng:NextNumber(-1, 1)
	local t = rng:NextNumber(0, TAU)
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(t), z, r * math.sin(t))
end

-- kit = { rings, arcs, halves, emitters }: what a builder registers for animation / quality control
local function emit(kit: any, parent: Instance, tier: string, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.LightEmission = 1
	e.LockedToPart = false
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	table.insert(kit.emitters, { inst = e, base = e.Rate, tier = tier })
	return e
end

local function addRing(model: Model, kit: any, s: number, color: Color3, axis: Vector3, rate: number, base: CFrame, scale: number?, thickness: number?, name: string?): Part
	local d = s * (scale or 1.35)
	local r = part(model, { Name = name or ("Ring" .. (#kit.rings + 1)), Shape = Enum.PartType.Cylinder, Size = Vector3.new(thickness or 0.18, d, d), Material = Enum.Material.Neon, Color = color, Transparency = 0.15 })
	table.insert(kit.rings, { part = r, axis = axis.Unit, rate = rate, base = base })
	return r
end

-- Electric arc: a Beam between two attachments on the core, re-shaped a few times per second.
-- mode "surface": random points on a sphere of radius `radius`; mode "poles": north -> south field line.
local function addArc(core: BasePart, kit: any, c0: Color3, c1: Color3, width: number, radius: number, mode: string)
	local a0 = Instance.new("Attachment")
	a0.Name = "ArcA"
	a0.Parent = core
	local a1 = Instance.new("Attachment")
	a1.Name = "ArcB"
	a1.Parent = core
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.Color = ColorSequence.new(c0, c1)
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Width0 = width
	b.Width1 = width * 0.55
	b.FaceCamera = true
	b.Segments = 12
	b.Texture = TEX.sparkle
	b.TextureMode = Enum.TextureMode.Wrap
	b.TextureLength = 1.2
	b.TextureSpeed = 3
	b.Transparency = NumberSequence.new(0.05)
	b.Parent = core
	table.insert(kit.arcs, { beam = b, a0 = a0, a1 = a1, radius = radius, mode = mode })
end

---------------------------------------------------------------- builders (one visual identity per variant)

-- Ice (common): frosted glass sphere, ice crystals, frost sparkle + cold mist, icy two-tone trail.
local function buildIce(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s, Material = Enum.Material.Glass, Color = rgb(175, 225, 255), Transparency = 0.2, Reflectance = 0.15 })
	part(model, { Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.62, Material = Enum.Material.Neon, Color = rgb(120, 205, 255), Transparency = 0.25 })
	for i = 1, 6 do
		local dir = randomUnit(rng)
		local shard = part(model, { Name = "Frost" .. i, Size = Vector3.new(s * 0.22, s * rng:NextNumber(0.55, 0.8), s * 0.22), Material = Enum.Material.Ice, Color = rgb(225, 248, 255) })
		shard.CFrame = CFrame.lookAt(dir * s * 0.33, dir * s) * CFrame.Angles(math.pi / 2, 0, rng:NextNumber(0, 6))
	end
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(200, 240, 255)), Rate = 14, Lifetime = NumberRange.new(0.6, 1.2), Speed = NumberRange.new(1, 3), Size = seq(s * 0.12, 0), Transparency = seq(0.1, 1) })
	emit(kit, core, "secondary", { Texture = TEX.smoke, Color = ColorSequence.new(rgb(210, 240, 255)), Rate = 6, Lifetime = NumberRange.new(0.7, 1.1), Speed = NumberRange.new(0.3, 0.8), Size = seq(s * 0.2, s * 0.32), Transparency = seq(0.6, 1), LightEmission = 0.3 })
	return core
end

-- Magma (common): molten core in basalt crust, licking flames, embers, smoky ribbon.
local function buildMagma(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.82, Material = Enum.Material.Neon, Color = rgb(255, 120, 35) })
	part(model, { Name = "Heat", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 1.0, Material = Enum.Material.ForceField, Color = rgb(255, 120, 40), Transparency = 0 })
	for i = 1, 6 do
		local dir = randomUnit(rng)
		local k = rng:NextNumber(0.32, 0.42)
		local rock = part(model, { Name = "Crust" .. i, Size = Vector3.new(s * k, s * k * 0.75, s * k), Material = Enum.Material.Basalt, Color = rgb(52, 38, 34) })
		rock.CFrame = CFrame.new(dir * s * 0.34) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6))
	end
	emit(kit, core, "primary", { Texture = TEX.fire, Color = ColorSequence.new(rgb(255, 170, 70), rgb(210, 50, 20)), Rate = 26, Lifetime = NumberRange.new(0.35, 0.7), Speed = NumberRange.new(2, 4), Size = seq(s * 0.3, 0), Transparency = seq(0.2, 1), LightEmission = 0.85 })
	emit(kit, core, "secondary", { Texture = TEX.sparks, Color = ColorSequence.new(rgb(255, 210, 120)), Rate = 12, Lifetime = NumberRange.new(0.3, 0.6), Speed = NumberRange.new(3, 6), Size = seq(s * 0.07, 0), Transparency = seq(0, 1) })
	emit(kit, core, "secondary", { Texture = TEX.smoke, Color = ColorSequence.new(rgb(70, 45, 38)), Rate = 6, Lifetime = NumberRange.new(0.6, 1.0), Speed = NumberRange.new(0.3, 0.8), Size = seq(s * 0.22, s * 0.34), Transparency = seq(0.45, 1), LightEmission = 0 })
	return core
end

-- Plasma (uncommon): bright violet energy ball with orbiting rings and crackling electric arcs.
local function buildPlasma(model: Model, s: number, _rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.55, Material = Enum.Material.Neon, Color = rgb(240, 160, 255) })
	part(model, { Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * s, Material = Enum.Material.ForceField, Color = rgb(200, 90, 255), Transparency = 0.05 })
	addRing(model, kit, s, rgb(255, 120, 230), Vector3.new(1, 0.3, 0), 3.1, CFrame.Angles(0, 0, 0.4))
	addRing(model, kit, s, rgb(140, 100, 255), Vector3.new(0, 1, 0.4), -2.3, CFrame.Angles(0, 0, math.pi / 2))
	addArc(core, kit, rgb(255, 230, 255), rgb(170, 110, 255), s * 0.06, s * 0.5, "surface")
	addArc(core, kit, rgb(255, 230, 255), rgb(170, 110, 255), s * 0.05, s * 0.5, "surface")
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(240, 170, 255)), Rate = 30, Lifetime = NumberRange.new(0.4, 0.9), Speed = NumberRange.new(2, 5), Size = seq(s * 0.15, 0), Transparency = seq(0, 1) })
	emit(kit, core, "secondary", { Texture = TEX.sparks, Color = ColorSequence.new(rgb(220, 170, 255)), Rate = 10, Lifetime = NumberRange.new(0.15, 0.3), Speed = NumberRange.new(6, 10), Size = seq(s * 0.06, 0), Transparency = seq(0, 1) })
	return core
end

-- Crystal (uncommon): transparent glass formations around a glowing heart, light slivers inside the shards.
local function buildCrystal(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.46, Material = Enum.Material.Neon, Color = rgb(255, 175, 238) })
	local colors = { rgb(255, 150, 225), rgb(160, 232, 255), rgb(205, 150, 255) }
	for i = 1, 7 do
		local dir = randomUnit(rng)
		local len = s * rng:NextNumber(0.55, 0.92)
		local cf = CFrame.lookAt(dir * len * 0.4, dir * s) * CFrame.Angles(math.pi / 2, 0, rng:NextNumber(0, 6))
		-- translucent glowing formation (Glass reads near-black against empty space) with a bright spine
		local shard = part(model, { Name = "Formation" .. i, Size = Vector3.new(s * 0.24, len, s * 0.24), Material = Enum.Material.Neon, Color = colors[(i % 3) + 1], Transparency = 0.55 })
		shard.CFrame = cf
		local sliver = part(model, { Name = "Sliver" .. i, Size = Vector3.new(s * 0.07, len * 0.85, s * 0.07), Material = Enum.Material.Neon, Color = colors[(i % 3) + 1]:Lerp(Color3.new(1, 1, 1), 0.5), Transparency = 0 })
		sliver.CFrame = cf
	end
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(255, 195, 242), rgb(165, 232, 255)), Rate = 18, Lifetime = NumberRange.new(0.5, 1), Speed = NumberRange.new(1, 3), Size = seq(s * 0.14, 0), Transparency = seq(0, 1) })
	emit(kit, core, "secondary", { Texture = TEX.glow, Color = ColorSequence.new(rgb(255, 210, 245)), Rate = 4, Lifetime = NumberRange.new(0.5, 0.8), Speed = NumberRange.new(0, 0.5), Size = seq(s * 0.3, s * 0.2), Transparency = seq(0.6, 1) })
	return core
end

-- Bio (uncommon): green organic heart, spore pods, drifting spores and a soft haze.
local function buildBio(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.46, Material = Enum.Material.Neon, Color = rgb(150, 255, 150) })
	for i = 1, 9 do
		local dir = randomUnit(rng)
		local k = rng:NextNumber(0.22, 0.34)
		local pod = part(model, { Name = "Pod" .. i, Shape = Enum.PartType.Ball, Size = Vector3.one * s * k, Material = Enum.Material.SmoothPlastic, Color = rgb(90, 200, 110):Lerp(rgb(220, 255, 120), rng:NextNumber()), Transparency = 0.1 })
		pod.CFrame = CFrame.new(dir * s * 0.36)
	end
	part(model, { Name = "Haze", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 1.05, Material = Enum.Material.ForceField, Color = rgb(120, 255, 140), Transparency = 0.2 })
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(215, 255, 160), rgb(110, 230, 130)), Rate = 14, Lifetime = NumberRange.new(1.2, 2.0), Speed = NumberRange.new(0.4, 1.4), Drag = 1, Size = seq(s * 0.1, s * 0.04), Transparency = seq(0.1, 1), RotSpeed = NumberRange.new(-40, 40) })
	emit(kit, core, "secondary", { Texture = TEX.smoke, Color = ColorSequence.new(rgb(170, 255, 170)), Rate = 8, Lifetime = NumberRange.new(0.8, 1.4), Speed = NumberRange.new(0.5, 1.5), Size = seq(s * 0.22, s * 0.34), Transparency = seq(0.55, 1), LightEmission = 0.4 })
	return core
end

-- Iron (uncommon): heavy metallic asteroid, corroded plates, faint hot seams, subtle sparks.
local function buildIron(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.82, Material = Enum.Material.Metal, Color = rgb(112, 108, 106), Reflectance = 0.12 })
	for i = 1, 7 do
		local dir = randomUnit(rng)
		local k = rng:NextNumber(0.32, 0.44)
		local chunk = part(model, { Name = "Plate" .. i, Size = Vector3.new(s * k, s * k * 0.7, s * k), Material = Enum.Material.CorrodedMetal, Color = rgb(122, 86, 62):Lerp(rgb(84, 80, 78), rng:NextNumber()) })
		chunk.CFrame = CFrame.new(dir * s * 0.3) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6))
	end
	for i = 1, 3 do
		local dir = randomUnit(rng)
		local crack = part(model, { Name = "Seam" .. i, Size = Vector3.new(s * 0.07, s * 0.5, s * 0.07), Material = Enum.Material.Neon, Color = rgb(255, 130, 50), Transparency = 0.15 })
		crack.CFrame = CFrame.lookAt(dir * s * 0.37, dir * s) * CFrame.Angles(math.pi / 2, 0, rng:NextNumber(0, 6))
	end
	emit(kit, core, "primary", { Texture = TEX.sparks, Color = ColorSequence.new(rgb(255, 235, 190), rgb(255, 140, 60)), Rate = 7, Lifetime = NumberRange.new(0.2, 0.45), Speed = NumberRange.new(4, 7), Size = seq(s * 0.07, 0), Transparency = seq(0, 1) })
	return core
end

-- Magnetic (rare): metal core with red / blue poles, field lines arcing pole to pole, field shell, two rings.
local function buildMagnetic(model: Model, s: number, _rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.6, Material = Enum.Material.Metal, Color = rgb(72, 78, 96), Reflectance = 0.3 })
	local north = part(model, { Name = "PoleN", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.26, Material = Enum.Material.Neon, Color = rgb(255, 85, 85) })
	north.CFrame = CFrame.new(0, s * 0.3, 0)
	local south = part(model, { Name = "PoleS", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.26, Material = Enum.Material.Neon, Color = rgb(85, 145, 255) })
	south.CFrame = CFrame.new(0, -s * 0.3, 0)
	part(model, { Name = "Field", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 1.1, Material = Enum.Material.ForceField, Color = rgb(120, 170, 255), Transparency = 0.15 })
	addRing(model, kit, s, rgb(255, 85, 85), Vector3.new(0, 1, 0), 4.2, CFrame.Angles(0, 0, math.pi / 2), 1.3, 0.2)
	addRing(model, kit, s, rgb(85, 145, 255), Vector3.new(1, 0, 0), -3.6, CFrame.new(), 1.3, 0.2)
	for _ = 1, 3 do
		addArc(core, kit, rgb(255, 120, 120), rgb(120, 170, 255), s * 0.05, s * 0.3, "poles")
	end
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(150, 190, 255), rgb(255, 120, 120)), Rate = 22, Lifetime = NumberRange.new(0.3, 0.7), Speed = NumberRange.new(2, 5), Size = seq(s * 0.12, 0), Transparency = seq(0, 1) })
	return core
end

-- Split (rare): visibly fractured rock: three shards around a glowing seam; the shards pull apart as the
-- split approaches (telegraphs the break).
local function buildSplit(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.55, Material = Enum.Material.Neon, Color = rgb(255, 200, 110) })
	part(model, { Name = "Heat", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.9, Material = Enum.Material.ForceField, Color = rgb(255, 170, 70), Transparency = 0 })
	for i = 0, 2 do
		local ang = i * TAU / 3 + rng:NextNumber(-0.2, 0.2)
		local dir = Vector3.new(math.cos(ang), rng:NextNumber(-0.3, 0.3), math.sin(ang)).Unit
		local offset = dir * s * 0.32
		local rot = CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6))
		local shard = part(model, { Name = "Shard" .. i, Size = Vector3.new(s * 0.42, s * 0.38, s * 0.4), Material = Enum.Material.Basalt, Color = rgb(86, 66, 56) })
		shard.CFrame = CFrame.new(offset) * rot
		table.insert(kit.halves, { part = shard, offset = offset, rot = rot })
	end
	for i = 0, 2 do
		local seam = part(model, { Name = "Seam" .. i, Size = Vector3.new(s * 0.05, s * 0.7, s * 0.4), Material = Enum.Material.Neon, Color = rgb(255, 210, 120), Transparency = 0.1 })
		seam.CFrame = CFrame.Angles(0, i * TAU / 3 + math.pi / 3, 0)
	end
	emit(kit, core, "primary", { Texture = TEX.fire, Color = ColorSequence.new(rgb(255, 205, 115), rgb(220, 90, 30)), Rate = 14, Lifetime = NumberRange.new(0.3, 0.6), Speed = NumberRange.new(2, 4), Size = seq(s * 0.22, 0), Transparency = seq(0.2, 1), LightEmission = 0.8 })
	emit(kit, core, "secondary", { Texture = TEX.dust, Color = ColorSequence.new(rgb(110, 90, 80)), Rate = 5, Lifetime = NumberRange.new(0.5, 0.9), Speed = NumberRange.new(0.5, 1.5), Size = seq(s * 0.18, s * 0.3), Transparency = seq(0.5, 1), LightEmission = 0 })
	return core
end

-- Split fragment: bright molten shard with a rock flake (small + fast: must stay readable).
local function buildFragment(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.62, Material = Enum.Material.Neon, Color = rgb(255, 185, 90) })
	part(model, { Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.95, Material = Enum.Material.ForceField, Color = rgb(255, 160, 70), Transparency = 0.05 })
	local rock = part(model, { Name = "Flake", Size = Vector3.new(s * 0.5, s * 0.42, s * 0.5), Material = Enum.Material.Basalt, Color = rgb(72, 56, 48) })
	rock.CFrame = CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0) * CFrame.new(s * 0.28, 0, 0)
	emit(kit, core, "primary", { Texture = TEX.fire, Color = ColorSequence.new(rgb(255, 200, 110), rgb(220, 90, 30)), Rate = 18, Lifetime = NumberRange.new(0.25, 0.5), Speed = NumberRange.new(2, 4), Size = seq(s * 0.25, 0), Transparency = seq(0.2, 1), LightEmission = 0.8 })
	return core
end

-- Cosmic Comet (epic): white-gold nucleus, coma shell, long luminous tail (ribbon + particles left behind).
local function buildComet(model: Model, s: number, _rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.6, Material = Enum.Material.Neon, Color = rgb(255, 245, 195) })
	part(model, { Name = "Coma", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.95, Material = Enum.Material.ForceField, Color = rgb(255, 220, 120), Transparency = 0 })
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(255, 250, 215), rgb(140, 210, 255)), Rate = 55, Lifetime = NumberRange.new(0.8, 1.3), Speed = NumberRange.new(0.2, 1), Size = seq(s * 0.3, 0), Transparency = seq(0, 1) })
	emit(kit, core, "secondary", { Texture = TEX.glow, Color = ColorSequence.new(rgb(255, 235, 170)), Rate = 10, Lifetime = NumberRange.new(0.5, 0.9), Speed = NumberRange.new(0, 0.4), Size = seq(s * 0.32, s * 0.12), Transparency = seq(0.45, 1) })
	return core
end

-- Stellar (legendary): radiant white-gold star, corona, rotating rays and halo, gold radiance.
local function buildStellar(model: Model, s: number, _rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.56, Material = Enum.Material.Neon, Color = rgb(255, 248, 220) })
	part(model, { Name = "Corona", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 1.15, Material = Enum.Material.ForceField, Color = rgb(255, 200, 90), Transparency = 0 })
	for i = 0, 2 do
		local ray = part(model, { Name = "Ray" .. i, Size = Vector3.new(s * 0.09, s * 1.9, s * 0.09), Material = Enum.Material.Neon, Color = rgb(255, 236, 165), Transparency = 0.1 })
		table.insert(kit.rings, { part = ray, axis = Vector3.new(0, 0, 1), rate = 1.2, base = CFrame.Angles(0, 0, i * math.pi / 3) })
	end
	addRing(model, kit, s, rgb(255, 215, 110), Vector3.new(0, 1, 0), 0.6, CFrame.Angles(0, 0, math.pi / 2), 1.45, 0.14, "Halo")
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(255, 252, 225), rgb(255, 190, 80)), Rate = 50, Lifetime = NumberRange.new(0.5, 1), Speed = NumberRange.new(1, 3), Size = seq(s * 0.22, 0), Transparency = seq(0, 1) })
	emit(kit, core, "secondary", { Texture = TEX.glow, Color = ColorSequence.new(rgb(255, 225, 150)), Rate = 6, Lifetime = NumberRange.new(0.4, 0.7), Speed = NumberRange.new(0, 0.3), Size = seq(s * 0.34, s * 0.2), Transparency = seq(0.4, 1) })
	return core
end

-- Void (mythic): black singularity in a violet rim, matter spiralling INWARD (gravity distortion), two rings.
local function buildVoid(model: Model, s: number, _rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.7, Material = Enum.Material.Glass, Color = rgb(18, 8, 30), Reflectance = 0.6 })
	part(model, { Name = "Rim", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.82, Material = Enum.Material.Neon, Color = rgb(120, 40, 220), Transparency = 0.55 })
	part(model, { Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 1.15, Material = Enum.Material.ForceField, Color = rgb(190, 110, 255), Transparency = 0 })
	addRing(model, kit, s, rgb(200, 120, 255), Vector3.new(0.3, 1, 0), 2.6, CFrame.Angles(0, 0, math.pi / 2), 1.5, 0.32)
	addRing(model, kit, s, rgb(255, 90, 200), Vector3.new(1, 0.2, 0), -1.9, CFrame.new(), 1.25, 0.22)
	emit(kit, core, "primary", {
		Texture = TEX.sparkle,
		Color = ColorSequence.new(rgb(230, 170, 255), rgb(120, 40, 220)),
		Rate = 34,
		Lifetime = NumberRange.new(0.3, 0.5),
		Speed = NumberRange.new(3, 5),
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
		Size = seq(s * 0.12, s * 0.02),
		Transparency = seq(0.1, 0.8),
	})
	emit(kit, core, "secondary", { Texture = TEX.smoke, Color = ColorSequence.new(rgb(170, 80, 255)), Rate = 12, Lifetime = NumberRange.new(0.6, 1.1), Speed = NumberRange.new(0.5, 1.5), Size = seq(s * 0.26, s * 0.34), Transparency = seq(0.35, 1), LightEmission = 0.7 })
	return core
end

-- Astral (secret): pale-cyan heart, prism shards, colour-cycling shell + halo, multicolour stardust tail.
local function buildAstral(model: Model, s: number, rng: Random, kit: any): Part
	local core = part(model, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 0.5, Material = Enum.Material.Neon, Color = rgb(220, 255, 252) })
	part(model, { Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * s * 1.0, Material = Enum.Material.ForceField, Color = rgb(120, 255, 235), Transparency = 0.1 })
	local colors = { rgb(120, 255, 235), rgb(255, 150, 255), rgb(255, 230, 140) }
	for i = 1, 6 do
		local dir = randomUnit(rng)
		local len = s * rng:NextNumber(0.55, 0.85)
		local shard = part(model, { Name = "Prism" .. i, Size = Vector3.new(s * 0.17, len, s * 0.17), Material = Enum.Material.Glass, Color = colors[(i % 3) + 1], Transparency = 0.1, Reflectance = 0.3 })
		shard.CFrame = CFrame.lookAt(dir * len * 0.4, dir * s) * CFrame.Angles(math.pi / 2, 0, rng:NextNumber(0, 6))
	end
	addRing(model, kit, s, rgb(255, 170, 255), Vector3.new(0.2, 1, 0.3), 1.4, CFrame.Angles(0, 0, math.pi / 2), 1.4, 0.16, "Halo")
	emit(kit, core, "primary", { Texture = TEX.sparkle, Color = Styles.cs(rgb(120, 255, 235), rgb(255, 150, 255), rgb(255, 230, 140)), Rate = 60, Lifetime = NumberRange.new(0.6, 1.1), Speed = NumberRange.new(0.3, 2), Size = seq(s * 0.2, 0), Transparency = seq(0, 1) })
	emit(kit, core, "secondary", { Texture = TEX.glow, Color = ColorSequence.new(rgb(210, 255, 250)), Rate = 8, Lifetime = NumberRange.new(0.4, 0.8), Speed = NumberRange.new(0, 0.4), Size = seq(s * 0.32, s * 0.18), Transparency = seq(0.45, 1) })
	return core
end

local BUILDERS: { [string]: any } = {
	Ice = buildIce,
	Magma = buildMagma,
	Plasma = buildPlasma,
	Crystal = buildCrystal,
	Bio = buildBio,
	Iron = buildIron,
	Magnetic = buildMagnetic,
	Split = buildSplit,
	SplitFragment = buildFragment,
	Comet = buildComet,
	Stellar = buildStellar,
	Void = buildVoid,
	Astral = buildAstral,
}
MeteorVisuals.LOOKS = { "Ice", "Magma", "Plasma", "Crystal", "Bio", "Iron", "Magnetic", "Split", "SplitFragment", "Comet", "Stellar", "Void", "Astral" }

---------------------------------------------------------------- build + pool

local pools: { [string]: { any } } = {}

local function templateFor(name: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("PF_Assets")
	local folder = assets and assets:FindFirstChild("Meteors")
	local t = folder and folder:FindFirstChild(name)
	if t and t:IsA("Model") and t.PrimaryPart then
		return t
	end
	return nil
end

local function build(lookKey: string, def: any, s: number, seed: number): any
	local pool = pools[lookKey]
	if pool and #pool > 0 then
		return table.remove(pool)
	end
	local rng = Random.new(seed)
	local kit = { rings = {}, arcs = {}, halves = {}, emitters = {} }
	local model: Model
	local core: BasePart
	local unit = 1
	local template = templateFor(lookKey)
	if template then
		model = template:Clone()
		core = model.PrimaryPart :: BasePart
		local _, ext = model:GetBoundingBox()
		local biggest = math.max(ext.X, ext.Y, ext.Z, 0.01)
		model:ScaleTo(model:GetScale() * s / biggest)
		unit = model:GetScale()
		for _, d in model:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				table.insert(kit.emitters, { inst = d, base = d.Rate, tier = "primary" })
			end
		end
	else
		model = Instance.new("Model")
		core = (BUILDERS[lookKey] or buildIce)(model, s, rng, kit)
		model.PrimaryPart = core
	end
	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			table.insert(parts, d)
		end
	end
	local light = Instance.new("PointLight")
	light.Color = def.color
	light.Parent = core
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailA"
	a0.Position = Vector3.new(0, s * 0.3, 0)
	a0.Parent = core
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailB"
	a1.Position = Vector3.new(0, -s * 0.3, 0)
	a1.Parent = core
	local tether = Instance.new("Attachment")
	tether.Name = "Tether"
	tether.Parent = core
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Transparency = seq(0.2, 1)
	trail.Enabled = false
	trail.Parent = core
	return {
		lookKey = lookKey,
		model = model,
		core = core,
		rings = kit.rings,
		arcs = kit.arcs,
		halves = kit.halves,
		emitters = kit.emitters,
		parts = parts,
		light = light,
		trail = trail,
		tether = tether,
		builtSize = s,
		unit = unit,
	}
end

local function recycle(b: any)
	if not b or not b.model then
		return
	end
	local pool = pools[b.lookKey]
	if not pool then
		pool = {}
		pools[b.lookKey] = pool
	end
	if #pool >= POOL_MAX then
		b.model:Destroy()
		return
	end
	b.model.Parent = nil
	b.trail.Enabled = false
	b.trail:Clear()
	for _, e in b.emitters do
		e.inst.Rate = e.base
		e.inst.Enabled = true
		e.inst:Clear()
	end
	for _, p in b.parts do
		p.LocalTransparencyModifier = 0
	end
	local hl = b.model:FindFirstChildOfClass("Highlight")
	if hl then
		hl:Destroy()
	end
	table.insert(pool, b)
end

function MeteorVisuals.clearPool()
	for key, pool in pools do
		for _, b in pool do
			b.model:Destroy()
		end
		pools[key] = nil
	end
end

function MeteorVisuals.poolCount(): number
	local n = 0
	for _, pool in pools do
		n += #pool
	end
	return n
end

---------------------------------------------------------------- instance

function MeteorVisuals.new(spec: any, layout: any, container: Instance)
	local def = MeteorRegistry.get(spec.kind) or MeteorRegistry.get("Ice")
	local variant = MeteorRegistry.resolve(spec.kind) or "Ice"
	local rarity = MeteorRegistry.rarity(spec.kind)
	local rStyle = Styles.RARITY[def.rarity] or Styles.RARITY.common
	local vStyle = Styles.variant(variant)
	local Q = Styles.quality()
	local calm = Styles.reducedMotion()
	local lookKey = if spec.fragment then "SplitFragment" else ((def.theme and def.theme.builder) or variant)
	local b = build(lookKey, def, spec.size, spec.id)
	local model = b.model
	model.Name = "Meteor_" .. spec.id
	model:SetAttribute("PFMeteorId", spec.id)
	model:SetAttribute("PFVariant", variant)
	model:SetAttribute("PFRarity", def.rarity)
	model:SetAttribute("PFFragment", spec.fragment == true)
	model:SetAttribute("PFState", "pending")
	-- quality budget: particle rates, secondary emitters, arcs, light, trail
	local wantEmit = {}
	for _, e in b.emitters do
		e.inst.Rate = e.base * Q.emission * rStyle.emission
		local on = e.tier == "primary" or Q.secondary
		e.inst.Enabled = on
		wantEmit[e.inst] = on
	end
	for _, arc in b.arcs do
		arc.beam.Enabled = Q.arcs
		arc.beam.TextureSpeed = if calm then 0.5 else 3
	end
	local baseBrightness = math.min(((def.vfx and def.vfx.light) or 1.8) * rStyle.light, 4.5)
	b.light.Enabled = Q.lights or rarity.order >= 3
	b.light.Brightness = baseBrightness
	b.light.Range = math.min(spec.size * 2.8, 24)
	b.light.Color = def.color
	b.trail.Color = vStyle.trail
	b.trail.Lifetime = rStyle.trailLife * Q.trail
	b.trail.WidthScale = seq(rStyle.trailWidth, 0)
	if spec.tutorial or rarity.order >= 5 then
		local hl = Instance.new("Highlight")
		hl.FillTransparency = 1
		hl.OutlineColor = if spec.tutorial then Color3.new(1, 1, 1) else rarity.color
		hl.OutlineTransparency = 0.2
		hl.DepthMode = if spec.tutorial then Enum.HighlightDepthMode.AlwaysOnTop else Enum.HighlightDepthMode.Occluded
		hl.Parent = model
	end
	local rng = Random.new(spec.id + 7)
	local self = setmetatable({
		spec = spec,
		def = def,
		variant = variant,
		rarity = rarity,
		rStyle = rStyle,
		vStyle = vStyle,
		calm = calm,
		quality = Q,
		layout = layout,
		container = container,
		built = b,
		model = model,
		core = b.core,
		tether = b.tether,
		trail = b.trail,
		light = b.light,
		wantEmit = wantEmit,
		baseBrightness = baseBrightness,
		baseRange = b.light.Range,
		trailOn = false,
		rings = b.rings,
		arcs = b.arcs,
		halves = b.halves,
		arcT = math.huge,
		arcRng = rng,
		lodT = 0,
		far = false,
		state = "flight",
		unit = b.unit * spec.size / b.builtSize,
		appliedAbs = model:GetScale(),
		spinAxis = randomUnit(rng),
		spinRate = rng:NextNumber(0.6, 1.6) * (if variant == "Plasma" or variant == "Astral" then 2 else 1) * rStyle.spinMul * (if calm then 0.35 else 1),
		spin = 0,
		slipOffset = Vector3.zero,
		worldPos = nil :: Vector3?,
		lastPos = nil :: Vector3?,
		telegraphPos = nil :: Vector3?,
		fade = 0,
		phased = false,
		phaseable = spec.pa ~= nil,
		corrections = if spec.pattern == "magnetic" and spec.m1 and spec.m2 then { spec.m1, spec.m2 } else nil,
		cueWanted = not spec.tutorial and not spec.fragment and ((spec.tele or 0) > 0 or Styles.needsApproachCue(def.rarity, def.speedMultiplier)),
		expired = false,
		released = false,
		done = false,
	}, MeteorVisuals)
	self:_setScale(0.05)
	return self
end

function MeteorVisuals:_attr(name: string, value: any)
	if self.model then
		self.model:SetAttribute(name, value)
	end
end

function MeteorVisuals:_ratio(): number
	return self.appliedAbs / self.built.unit
end

function MeteorVisuals:_setScale(k: number)
	local target = self.unit * math.max(k, 0.02)
	if math.abs(target - self.appliedAbs) > 0.015 * self.unit then
		self.model:ScaleTo(target)
		self.appliedAbs = target
	end
end

function MeteorVisuals:_place(pos: Vector3, dt: number)
	self.spin += self.spinRate * dt
	local cf = CFrame.new(pos) * CFrame.fromAxisAngle(self.spinAxis, self.spin)
	self.model:PivotTo(cf)
	for _, r in self.rings do
		r.part.CFrame = CFrame.new(pos) * CFrame.fromAxisAngle(r.axis, self.spin * r.rate) * r.base
	end
	if #self.halves > 0 then
		-- Split: the shards pull apart over the last 45% of the parent's flight (telegraphs the break)
		local gap = 0
		if self.spec.splits and self.worldPos then
			local u = math.clamp((self.nowT - self.spec.t0) / self.spec.duration, 0, 1)
			local g = math.clamp((u - 0.55) / 0.45, 0, 1)
			gap = g * g * 0.55
		end
		local r = self:_ratio()
		for _, h in self.halves do
			h.part.CFrame = cf * CFrame.new(h.offset * r * (1 + gap)) * h.rot
		end
	end
	self.lastPos = pos
end

-- Electric arcs: re-shaped a few times per second (static under reduced motion).
function MeteorVisuals:_updateArcs(dt: number)
	if #self.arcs == 0 or not self.quality.arcs then
		return
	end
	self.arcT += dt
	if self.arcT < self.quality.arcInterval or (self.calm and self.arcsShaped) then
		return
	end
	self.arcT = 0
	self.arcsShaped = true
	local rng = self.arcRng
	local r = self:_ratio()
	for i, arc in self.arcs do
		local R = arc.radius * r
		if arc.mode == "poles" then
			local ang = (i / #self.arcs) * TAU + rng:NextNumber(-0.5, 0.5)
			local rot = CFrame.Angles(0, ang, 0)
			arc.a0.CFrame = CFrame.new(0, R, 0) * rot
			arc.a1.CFrame = CFrame.new(0, -R, 0) * rot
			local bulge = R * rng:NextNumber(1.6, 2.6)
			arc.beam.CurveSize0 = bulge
			arc.beam.CurveSize1 = -bulge
		else
			arc.a0.Position = randomUnit(rng) * R
			arc.a1.Position = randomUnit(rng) * R
			arc.beam.CurveSize0 = rng:NextNumber(-1.4, 1.4) * R
			arc.beam.CurveSize1 = rng:NextNumber(-1.4, 1.4) * R
		end
	end
end

function MeteorVisuals:_setFade(alpha: number)
	if math.abs(alpha - self.fade) < 0.03 and not (alpha == 0 and self.fade ~= 0) then
		return
	end
	self.fade = alpha
	for _, p in self.built.parts do
		p.LocalTransparencyModifier = alpha
	end
	for _, e in self.built.emitters do
		e.inst.Enabled = self.wantEmit[e.inst] == true and alpha < 0.5 and not self.far
	end
	for _, arc in self.arcs do
		arc.beam.Enabled = self.quality.arcs and alpha < 0.5
	end
	self.trail.Enabled = alpha < 0.5 and self.trailOn and not self.far
end

-- True (server-verifiable) world position at time t, or nil.
function MeteorVisuals:truePosition(t: number): Vector3?
	local lp = MeteorPath.evaluate(self.spec, t)
	return lp and self.layout.toWorld(lp)
end

function MeteorVisuals:isTargetable(): boolean
	return self.state == "flight" and not self.expired and not self.phased and self.worldPos ~= nil
end

function MeteorVisuals:isLockable(): boolean
	return self.state == "flight" and not self.expired and self.worldPos ~= nil
end

---------------------------------------------------------------- approach cue (fast / rare targets)

-- Lazily computes where the meteor enters, its heading, and when it crosses into the visible lane.
function MeteorVisuals:_cueData(): any
	if self.cue ~= nil then
		return self.cue
	end
	local spec = self.spec
	local entry = self:truePosition(spec.t0)
	if not entry then
		self.cue = false
		return false
	end
	local ahead = self:truePosition(math.min(spec.t0 + 0.25, spec.t0 + spec.duration)) or entry
	local dir = if (ahead - entry).Magnitude > 1e-3 then (ahead - entry).Unit else Vector3.xAxis
	local enterT = spec.t0
	for i = 0, 200 do
		local t = spec.t0 + i * 0.02
		local lp = MeteorPath.evaluate(spec, t)
		if lp and math.abs(lp.X) <= HALF_WIDTH then
			enterT = t
			break
		end
	end
	self.cue = { entry = entry, dir = dir, enterT = enterT }
	return self.cue
end

-- Entry flare (until t0) + inbound streak along the first stretch of the path (until it reaches the lane).
function MeteorVisuals:_updateCue(now: number)
	if not self.cueWanted or self.state ~= "flight" then
		self:_endCue()
		return
	end
	local cue = self:_cueData()
	if not cue or now >= cue.enterT then
		self:_endCue()
		return
	end
	local spec = self.spec
	local color = self.rarity.color
	local pulse = if self.calm then 0.5 else 0.5 + 0.5 * math.cos(now * TAU * 1.2) -- 1.2 Hz, under MAX_PULSE_HZ
	if now < spec.t0 then
		self.telegraphPos = cue.entry
		if not self.flare then
			self.flare = part(self.container, { Name = "ApproachFlare_" .. spec.id, Shape = Enum.PartType.Ball, Size = Vector3.one * spec.size, Material = Enum.Material.Neon, Color = color, Transparency = 0.4, CFrame = CFrame.new(cue.entry) })
			self:_attr("PFState", "telegraph")
		end
		local lead = math.max(spec.tele or 0, 0.3)
		local k = math.clamp(1 - (spec.t0 - now) / lead, 0, 1)
		self.flare.Transparency = 0.3 + 0.35 * pulse
		self.flare.Size = Vector3.one * spec.size * (0.5 + 1.1 * k)
	else
		self.telegraphPos = nil
		if self.flare then
			self.flare:Destroy()
			self.flare = nil
		end
	end
	if not self.streak then
		local anchor = part(self.container, { Name = "ApproachStreak_" .. spec.id, Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(cue.entry) })
		local s0 = Instance.new("Attachment")
		s0.Parent = anchor
		local s1 = Instance.new("Attachment")
		s1.Position = cue.dir * 32
		s1.Parent = anchor
		local beam = Instance.new("Beam")
		beam.Attachment0 = s0
		beam.Attachment1 = s1
		beam.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.FaceCamera = true
		beam.Width0 = math.max(1.2, spec.size * 0.35)
		beam.Width1 = 0.2
		beam.Texture = TEX.sparkle
		beam.TextureMode = Enum.TextureMode.Wrap
		beam.TextureLength = 4
		beam.TextureSpeed = if self.calm then 0.6 else 2.5
		beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0.85) })
		beam.Parent = anchor
		self.streak = anchor
	end
end

function MeteorVisuals:_endCue()
	if self.flare then
		self.flare:Destroy()
		self.flare = nil
	end
	if self.streak then
		self.streak:Destroy()
		self.streak = nil
	end
	self.telegraphPos = nil
end

---------------------------------------------------------------- per frame

function MeteorVisuals:update(now: number, dt: number)
	if self.released then
		return
	end
	self.nowT = now
	if self.state == "captured" then
		self:_captureStep(dt)
		return
	elseif self.state == "cancelled" then
		self:_cancelStep(dt)
		return
	end
	if self.expired then
		return
	end
	self:_updateCue(now)
	if self.state == "held" then
		self.spinRate = math.min(self.spinRate + dt * 6, 9)
		self:_place(self.heldPos, dt)
		return
	end
	local spec = self.spec
	if now < spec.t0 then
		self.worldPos = nil
		return
	end
	local pos = self:truePosition(now)
	if not pos then
		self.expired = true
		self.worldPos = nil
		self:_endCue()
		self.model.Parent = nil
		return
	end
	if self.model.Parent == nil then
		self.model.Parent = self.container
		self:_attr("PFState", "flight")
	end
	-- distance LOD (cheap, twice a second)
	self.lodT -= dt
	if self.lodT <= 0 then
		self.lodT = 0.5
		local cam = Workspace.CurrentCamera
		local far = cam ~= nil and (cam.CFrame.Position - pos).Magnitude > LOD_FAR
		if far ~= self.far then
			self.far = far
			local f = self.fade
			self.fade = -1
			self:_setFade(f)
		end
	end
	local brightness, range = self.baseBrightness, self.baseRange
	if self.phaseable then
		-- Void: smooth dim before a phase-out (no strobing), faded + untargetable while phased
		local phased = MeteorPath.isPhased(spec, now)
		if phased ~= self.phased then
			self.phased = phased
			self:_attr("PFState", if phased then "phased" else "flight")
		end
		local alpha = 0
		if phased then
			alpha = 0.85
		else
			local ttp = MeteorPath.timeToPhase(spec, now)
			if ttp < VOID.WARN then
				alpha = 0.55 * (1 - ttp / VOID.WARN)
			end
		end
		self:_setFade(alpha)
	end
	if self.corrections then
		-- Magnetic: the field swells once before / during each course correction (smooth, < 1 Hz)
		local u = (now - spec.t0) / spec.duration
		local warnU = MAG.WARN / spec.duration
		local w = 0
		for _, m in self.corrections do
			local a, b2 = m - warnU, m + MAG.WIDTH
			if u >= a and u <= b2 then
				w = math.max(w, math.sin(math.pi * (u - a) / (b2 - a)))
			end
		end
		brightness *= 1 + 1.4 * w
		range *= 1 + 0.6 * w
	end
	if self.variant == "Astral" then
		-- slow hue cycle (0.12 Hz): multicolour identity without flashing
		local hue = (now * 0.12) % 1
		local c = Color3.fromHSV(hue, 0.45, 1)
		self.light.Color = c
		local shell = self.model:FindFirstChild("Shell") :: BasePart?
		if shell then
			shell.Color = c
		end
		local halo = self.model:FindFirstChild("Halo") :: BasePart?
		if halo then
			halo.Color = Color3.fromHSV((hue + 0.33) % 1, 0.5, 1)
		end
	elseif self.variant == "Stellar" and not self.calm then
		brightness *= 1 + 0.12 * math.sin(now * TAU * 0.8) -- gentle radiance, 0.8 Hz
	end
	self.light.Brightness = brightness
	self.light.Range = range
	self:_updateArcs(dt)
	self.slipOffset *= math.exp(-dt * 8)
	local e = now - spec.t0
	local left = spec.duration - e
	local k
	if spec.fragment then
		k = math.clamp(math.min(0.7 + e / 0.25, left / EXIT_RAMP), 0, 1)
	elseif spec.splits then
		k = math.clamp(e / SPAWN_RAMP, 0, 1)
	else
		k = math.clamp(math.min(e / SPAWN_RAMP, left / EXIT_RAMP), 0, 1)
	end
	self:_setScale(0.05 + 0.95 * k)
	self.worldPos = pos
	self:_place(pos + self.slipOffset, dt)
	if not self.trailOn then
		self.trailOn = true
		self.trail:Clear()
		self.trail.Enabled = not self.phased and not self.far
	end
end

function MeteorVisuals:hold()
	if self.state ~= "flight" then
		return
	end
	self.state = "held"
	self.heldPos = self.core.Position
	self:_attr("PFState", "held")
end

function MeteorVisuals:release(now: number)
	if self.state ~= "held" then
		return
	end
	self.state = "flight"
	self:_attr("PFState", "flight")
	self.spinRate = math.max(self.spinRate * 0.3, 1)
	local truePos = self:truePosition(now)
	if truePos then
		self.slipOffset = self.heldPos - truePos
	end
end

-- Pull into the collector; legendary+ spiral in with a swell first (skipped under reduced motion).
function MeteorVisuals:capture(collectorPos: Vector3, up: Vector3, duration: number, onDone: () -> ())
	if self.state == "captured" or self.released then
		return
	end
	local from = self.core.Position
	self.state = "captured"
	self:_attr("PFState", "captured")
	self:_endCue()
	self:_setFade(0)
	local grand = self.rStyle.flourish >= 3 and not self.calm
	local side = (collectorPos - from):Cross(up)
	self.cap = {
		from = from,
		ctrl = from:Lerp(collectorPos, 0.45) + up * 14,
		to = collectorPos,
		t = 0,
		duration = if grand then duration * 1.35 else duration,
		onDone = onDone,
		grand = grand,
		side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis,
		up = up,
	}
end

function MeteorVisuals:_captureStep(dt: number)
	local c = self.cap
	c.t += dt
	local u = math.clamp(c.t / c.duration, 0, 1)
	local e = u * u * (3 - 2 * u)
	local iu = 1 - e
	local pos = c.from * (iu * iu) + c.ctrl * (2 * iu * e) + c.to * (e * e)
	local scale = 1 - 0.85 * u
	if c.grand then
		-- swell, then spiral into the collector
		local swirl = math.sin(math.pi * u) * self.spec.size * 1.1
		local ang = u * TAU * 2
		pos += (c.side * math.cos(ang) + c.up * math.sin(ang)) * swirl
		scale = if u < 0.2 then 1 + 0.3 * math.sin(math.pi * u / 0.2) else 1 - 0.85 * ((u - 0.2) / 0.8)
	end
	self.spinRate = 4 + 14 * u
	self:_setScale(scale)
	self:_place(pos, dt)
	if u >= 1 then
		self.done = true
		local cb = c.onDone
		self:destroy()
		cb()
	end
end

function MeteorVisuals:cancel()
	if self.released or self.state == "captured" or self.state == "cancelled" then
		return
	end
	self.state = "cancelled"
	self:_attr("PFState", "cancelled")
	self:_endCue()
	self.cancelT = 0
end

function MeteorVisuals:_cancelStep(dt: number)
	self.cancelT += dt
	local u = math.clamp(self.cancelT / CANCEL_TIME, 0, 1)
	if self.model.Parent then
		self:_setFade(u)
	end
	if u >= 1 then
		self.done = true
		self:destroy()
	end
end

-- Returns the model to the pool (idempotent).
function MeteorVisuals:destroy()
	if self.released then
		return
	end
	self.released = true
	self.expired = true
	self.worldPos = nil
	self:_endCue()
	recycle(self.built)
	self.model = nil :: any
end

return MeteorVisuals
