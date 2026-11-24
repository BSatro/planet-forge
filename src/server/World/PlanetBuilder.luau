--!strict
-- PlanetBuilder — owner: Developer A.
-- Builds one BARREN starting planet for a slot, split into two streaming LODs:
--   Slot_n         (ModelStreamingMode Persistent, always loaded, ~20 parts)
--                  Core sphere (Ball = exact spherical collision), large dark "maria" patches readable from
--                  space, north-pole return pad, SpawnPoint, floating name label, ownership metadata.
--   Slot_n_Detail  (ModelStreamingMode Atomic, streams in when a player is near, ~300 parts)
--                  craters with rims, boulders, rock formations.
-- Deterministic from `seed`. NEVER adds biome content: themes (living/frozen/volcanic/crystal/astral/
-- void/desert/mechanical) are applied later by the renderer from PublicPlanetState.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)

local PlanetBuilder = {}

-- 2026-11-23 (R 96 -> 160): human-scale detail keeps its stud sizes; boulders (1 part each) grow with the area,
-- craters stay at 18 (13 parts each) to keep the per-slot budget
PlanetBuilder.CRATERS = 18
PlanetBuilder.BOULDERS = 34
PlanetBuilder.FORMATIONS = 6
PlanetBuilder.MARIA = 6
PlanetBuilder.POLE_CLEAR_DOT = 0.94 -- keep detail away from the north-pole pad / spawn

export type Params = { slot: number, center: Vector3, radius: number, seed: number }

local function randomUnit(rng: Random): Vector3
	local z = rng:NextNumber(-1, 1)
	local t = rng:NextNumber(0, math.pi * 2)
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(t), z, r * math.sin(t))
end

local function shade(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local function newPart(name: string, parent: Instance, solid: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = solid
	p.CanQuery = solid
	p.CanTouch = false
	p.CastShadow = solid
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function pickDirection(rng: Random, used: { Vector3 }, minDot: number): Vector3
	local n = randomUnit(rng)
	for _ = 1, 30 do
		local ok = n.Y < PlanetBuilder.POLE_CLEAR_DOT
		if ok then
			for _, u in used do
				if n:Dot(u) > minDot then
					ok = false
					break
				end
			end
		end
		if ok then
			break
		end
		n = randomUnit(rng)
	end
	return n
end

-- flat disc lying on the sphere at direction n (Cylinder X axis -> normal)
local function surfaceDisc(parent: Instance, name: string, center: Vector3, radius: number, n: Vector3, diameter: number, lift: number, twist: number): Part
	local d = newPart(name, parent, false)
	d.Shape = Enum.PartType.Cylinder
	d.Size = Vector3.new(0.3, diameter, diameter)
	d.CFrame = CFrame.new(center + n * (radius + lift)) * WorldLayout.frameFromUp(n, twist) * CFrame.Angles(0, 0, math.pi / 2)
	return d
end

local function buildCrater(rng: Random, folder: Instance, center: Vector3, radius: number, base: Color3, n: Vector3, index: number)
	local size = if rng:NextNumber() < 0.25 then rng:NextNumber(14, 18) else rng:NextNumber(6, 13)
	local frame = WorldLayout.frameFromUp(n, rng:NextNumber(0, math.pi * 2))
	local crater = Instance.new("Model")
	crater.Name = "Crater_" .. index
	local floor = surfaceDisc(crater, "Floor", center, radius, n, size, 0.02, 0)
	floor.Material = Enum.Material.Slate
	floor.Color = shade(base, 0.62)
	local inner = surfaceDisc(crater, "Inner", center, radius, n, size * 0.55, 0.06, 0)
	inner.Material = Enum.Material.Slate
	inner.Color = shade(base, 0.46)
	local rocks = math.clamp(math.floor(size * 0.7), 8, 16)
	for k = 1, rocks do
		local a = (k / rocks) * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local ringR = size * 0.5 * rng:NextNumber(0.88, 1.12) -- irregular rim
		local tangentOffset = (frame.RightVector * math.cos(a) + frame.LookVector * math.sin(a)) * ringR
		local dir = (n * radius + tangentOffset).Unit
		local rock = newPart("Rim", crater, false)
		rock.Material = Enum.Material.Rock
		rock.Color = shade(base, rng:NextNumber(0.92, 1.12))
		local w = size * rng:NextNumber(0.16, 0.34)
		local h = size * rng:NextNumber(0.04, 0.09)
		rock.Size = Vector3.new(w, h, size * rng:NextNumber(0.1, 0.17))
		rock.CFrame = CFrame.new(center + dir * (radius + h * 0.2)) * WorldLayout.frameFromUp(dir, a + rng:NextNumber(-0.5, 0.5))
			* CFrame.Angles(rng:NextNumber(-0.35, 0.35), 0, rng:NextNumber(-0.3, 0.3))
	end
	crater.Parent = folder
end

local function buildFormation(rng: Random, folder: Instance, center: Vector3, radius: number, base: Color3, n: Vector3, index: number)
	local m = Instance.new("Model")
	m.Name = "Formation_" .. index
	local frame = WorldLayout.frameFromUp(n, rng:NextNumber(0, math.pi * 2))
	for k = 1, rng:NextInteger(3, 5) do
		local off = frame.RightVector * rng:NextNumber(-4, 4) + frame.LookVector * rng:NextNumber(-4, 4)
		local dir = (n * radius + off).Unit
		local h = rng:NextNumber(3, 8)
		local b = newPart("Spire", m, true)
		b.Material = Enum.Material.Basalt
		b.Color = shade(base, rng:NextNumber(0.72, 0.9))
		b.Size = Vector3.new(rng:NextNumber(2, 4), h, rng:NextNumber(2, 4))
		b.CFrame = CFrame.new(center + dir * (radius + h * 0.4)) * WorldLayout.frameFromUp(dir, rng:NextNumber(0, 6.28))
			* CFrame.Angles(rng:NextNumber(-0.35, 0.35), 0, rng:NextNumber(-0.35, 0.35))
	end
	m.Parent = folder
end

local function buildLabel(core: BasePart, slot: number, radius: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "PlanetLabel"
	gui.Size = UDim2.fromOffset(200, 56) -- client ReadabilityFX shrinks far labels (distance LOD)
	gui.StudsOffsetWorldSpace = Vector3.new(0, radius + 26, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 2200
	gui.AlwaysOnTop = false
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.6)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = VisualStyle.slotColor(slot)
	title.TextStrokeTransparency = 0.4
	title.Text = string.format("PLANET %02d", slot)
	title.Parent = gui
	local owner = Instance.new("TextLabel")
	owner.Name = "Owner"
	owner.BackgroundTransparency = 1
	owner.Position = UDim2.fromScale(0, 0.6)
	owner.Size = UDim2.fromScale(1, 0.4)
	owner.Font = Enum.Font.GothamMedium
	owner.TextScaled = true
	owner.TextColor3 = VisualStyle.Color.Text
	owner.TextStrokeTransparency = 0.5
	owner.Text = "Unclaimed"
	owner.Parent = gui
	gui.Parent = core
end

-- Returns (persistentModel, detailModel).
function PlanetBuilder.build(params: Params): (Model, Model)
	assert(WorldLayout.isValidSlot(params.slot), "PlanetBuilder.build: invalid slot")
	assert(params.radius > 10 and params.radius <= 1000, "PlanetBuilder.build: radius out of range")
	local rng = Random.new(params.seed)
	local center, radius, slot = params.center, params.radius, params.slot
	-- barren grey stone, with a very small per-planet warm/cool shift
	local base = Color3.fromHSV(rng:NextNumber(0.05, 0.62), rng:NextNumber(0.03, 0.07), rng:NextNumber(0.41, 0.46))

	local model = Instance.new("Model")
	model.Name = "Slot_" .. slot
	model:SetAttribute("PFSlot", slot)
	model:SetAttribute("PFRadius", radius)
	model:SetAttribute("PFSeed", params.seed)
	model:SetAttribute("PFOwnerUserId", 0) -- 0 = unclaimed. Written by PlanetService (Developer B, M2).
	model:SetAttribute("PFOwnerName", "")
	model:SetAttribute("PFClaimState", "unclaimed")
	model:SetAttribute("PFTheme", "barren")
	model:SetAttribute("PFStage", 0)

	local core = newPart("Core", model, true)
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.one * (radius * 2)
	core.CFrame = CFrame.new(center)
	core.Material = Enum.Material.Rock
	core.Color = base
	model.PrimaryPart = core

	-- far-visible geology: large darker basins (visible from the station, no detail streaming needed)
	local maria = Instance.new("Folder")
	maria.Name = "Maria"
	maria.Parent = model
	-- Each basin is a cluster of small discs (<= 14 studs) so flat edges never lift visibly off the
	-- curved surface (sagitta of a 14-stud disc on R=96 is ~0.26 studs).
	local used: { Vector3 } = {}
	for i = 1, PlanetBuilder.MARIA do
		local n = pickDirection(rng, used, 0.75)
		table.insert(used, n)
		local tone = shade(base, rng:NextNumber(0.66, 0.76))
		local frame = WorldLayout.frameFromUp(n, rng:NextNumber(0, 6.28))
		local spread = rng:NextNumber(7, 12) * radius / 96 -- basins read from orbit at any radius
		for k = 1, 7 do
			local off = if k == 1 then Vector3.zero else (frame.RightVector * rng:NextNumber(-1, 1) + frame.LookVector * rng:NextNumber(-1, 1)) * spread
			local dir = (n * radius + off).Unit
			local d = surfaceDisc(maria, "Basin_" .. i, center, radius, dir, rng:NextNumber(9, 14), 0.01 + k * 0.004, 0)
			d.Material = Enum.Material.Slate
			d.Color = tone:Lerp(base, rng:NextNumber(0, 0.2))
		end
	end

	-- north-pole return pad
	local padPos = center + Vector3.yAxis * radius
	local pad = newPart("WarpPad", model, false)
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(0.4, 9, 9)
	pad.CFrame = CFrame.new(padPos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	pad.Material = Enum.Material.Neon
	pad.Color = VisualStyle.slotColor(slot)
	pad:SetAttribute("PFWarpTarget", "station")
	local padRing = newPart("WarpPadRing", model, false)
	padRing.Shape = Enum.PartType.Cylinder
	padRing.Size = Vector3.new(0.2, 10.6, 10.6)
	padRing.CFrame = CFrame.new(padPos + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	padRing.Material = Enum.Material.Neon
	padRing.Color = VisualStyle.Color.Text
	padRing.Transparency = 0.3
	local e = Instance.new("ParticleEmitter")
	e.Texture = VisualStyle.Texture.Sparkle
	e.Color = ColorSequence.new(VisualStyle.slotColor(slot))
	e.LightEmission = 1
	e.Rate = 4
	e.Lifetime = NumberRange.new(1.2, 2)
	e.Speed = NumberRange.new(3, 6)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.Parent = pad

	-- designated spawn point (invisible marker; CharacterService/PlanetService read it)
	local spawnCf = WorldLayout.getPlanetSpawn(slot)
	local sp = newPart("SpawnPoint", model, false)
	sp.Size = Vector3.new(4, 0.2, 4)
	sp.CFrame = spawnCf * CFrame.new(0, -3.4, 0)
	sp.Transparency = 1
	sp:SetAttribute("PFSpawnFor", slot)

	buildLabel(core, slot, radius)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	-- streamed detail
	local detail = Instance.new("Model")
	detail.Name = "Slot_" .. slot .. "_Detail"
	detail:SetAttribute("PFSlot", slot)
	local usedDetail: { Vector3 } = {}
	for i = 1, PlanetBuilder.CRATERS do
		local n = pickDirection(rng, usedDetail, 0.94)
		table.insert(usedDetail, n)
		buildCrater(rng, detail, center, radius, base, n, i)
	end
	for i = 1, PlanetBuilder.FORMATIONS do
		local n = pickDirection(rng, usedDetail, 0.97)
		table.insert(usedDetail, n)
		buildFormation(rng, detail, center, radius, base, n, i)
	end
	for i = 1, PlanetBuilder.BOULDERS do
		local n = pickDirection(rng, usedDetail, 0.985)
		local s = rng:NextNumber(1.6, 4.2)
		local b = newPart("Boulder_" .. i, detail, true)
		b.Material = Enum.Material.Basalt
		b.Color = shade(base, rng:NextNumber(0.7, 0.9))
		b.Size = Vector3.new(s * rng:NextNumber(1, 1.5), s * rng:NextNumber(0.6, 1), s * rng:NextNumber(1, 1.4))
		b.CFrame = CFrame.new(center + n * (radius + b.Size.Y * 0.3)) * WorldLayout.frameFromUp(n, rng:NextNumber(0, 6.28))
			* CFrame.Angles(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3))
	end
	detail.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return model, detail
end

return PlanetBuilder
