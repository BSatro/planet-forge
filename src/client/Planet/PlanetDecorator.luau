--!strict
-- PlanetDecorator — owner: Developer A. Builds the CLIENT-LOCAL visual layers of one planet from a
-- PlanetVisualProfile.Spec. Nothing here touches collision or the server planet (except a local recolour of
-- the Core and maria parts, which is purely visual). All parts: Anchored, CanCollide/CanQuery/CanTouch false,
-- so the gravity controller's ground probe and player movement are unaffected.
--
-- Placement rules:
--   * every object sits on the true sphere: position = centre + n * (R + h), orientation = frameFromUp(n)
--   * tall objects are sunk by the footprint sagitta so no edge floats over the curvature
--   * deterministic Random(seed) from the OWNER -> same planet in every server
--   * exclusion zones: north-pole pad, spawn point, Gravity Harvester (HarvestLayout) and the corridor
--     between spawn and harvester stay clear; objects never overlap (angular footprint test)
-- Output: { near = Folder (detail, LOD-gated), far = Folder (always), grow = {parts for emergence FX},
--           pulse = {neon parts for the controller's slow pulse}, emitters = {ParticleEmitter} }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)

local okHL, HarvestLayout = pcall(function()
	return require(ReplicatedStorage.PF_Shared.Harvest.HarvestLayout)
end)

local Profile = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualProfile)
local Density = require(ReplicatedStorage.PF_Shared.Planet.FormationDensity)
local okFR, FormationRegistry = pcall(function()
	return require(ReplicatedStorage.PF_Shared.Evolution.FormationRegistry)
end)
if not okFR then
	FormationRegistry = nil
end

local PlanetDecorator = {}

export type Effects = { level: string, density: number, particles: boolean, props: boolean }
export type Built = { near: Folder, far: Folder, grow: { BasePart }, pulse: { BasePart }, emitters: { ParticleEmitter } }

local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

----------------------------------------------------------------------------------------------------
-- primitives

local function part(parent: Instance, props: { [string]: any }): BasePart
	local p = Instance.new(props.ClassName or "Part") :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		if k ~= "ClassName" then
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function shade(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local function randomUnit(rng: Random): Vector3
	local z = rng:NextNumber(-1, 1)
	local t = rng:NextNumber(0, math.pi * 2)
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(t), z, r * math.sin(t))
end

----------------------------------------------------------------------------------------------------
-- placement context

type Ctx = {
	center: Vector3,
	R: number,
	rng: Random,
	spec: any,
	pal: { [string]: any },
	placed: { { dir: Vector3, ang: number } },
	blocked: { { dir: Vector3, ang: number } },
	grow: { BasePart },
	pulse: { BasePart },
	emitters: { ParticleEmitter },
	effects: Effects,
}

local function angleBetween(a: Vector3, b: Vector3): number
	return math.acos(math.clamp(a:Dot(b), -1, 1))
end

local function isFree(ctx: Ctx, dir: Vector3, ang: number, checkPlaced: boolean): boolean
	for _, b in ctx.blocked do
		if angleBetween(dir, b.dir) < b.ang + ang then
			return false
		end
	end
	if checkPlaced then
		for _, p in ctx.placed do
			if angleBetween(dir, p.dir) < (p.ang + ang) * 0.9 then
				return false
			end
		end
	end
	return true
end

-- footprint radius in studs -> angular radius on the sphere
local function angOf(ctx: Ctx, footprint: number): number
	return footprint / ctx.R
end

local function place(ctx: Ctx, footprint: number, near: Vector3?, spread: number?): Vector3?
	local ang = angOf(ctx, footprint)
	for _ = 1, 40 do
		local d: Vector3
		if near then
			local f = WorldLayout.frameFromUp(near, ctx.rng:NextNumber(0, 6.283))
			local s = (spread or 20) / ctx.R
			d = (near + (f.RightVector * ctx.rng:NextNumber(-1, 1) + f.LookVector * ctx.rng:NextNumber(-1, 1)) * s).Unit
		else
			d = randomUnit(ctx.rng)
		end
		if isFree(ctx, d, ang, true) then
			table.insert(ctx.placed, { dir = d, ang = ang })
			return d
		end
	end
	return nil
end

-- CFrame standing on the sphere at dir; `h` = height of the object's centre above the surface.
local function onSurface(ctx: Ctx, dir: Vector3, h: number, twist: number?): CFrame
	return CFrame.new(ctx.center + dir * (ctx.R + h)) * WorldLayout.frameFromUp(dir, twist or 0)
end

local function sag(ctx: Ctx, footprint: number): number
	return footprint * footprint / (2 * ctx.R)
end

local function discAt(ctx: Ctx, parent: Instance, dir: Vector3, dia: number, lift: number, props: { [string]: any }): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(0.25, dia, dia)
	props.CFrame = onSurface(ctx, dir, lift) * UPRIGHT
	return part(parent, props)
end

-- chain of thin neon segments along a great-circle arc on the surface (fissures, veins, lava rivers)
local function arcLine(ctx: Ctx, parent: Instance, start: Vector3, heading: Vector3, steps: number, stepLen: number, width: number, color: Color3, wobble: number)
	local dir = start
	local head = (heading - dir * heading:Dot(dir)).Unit
	for _ = 1, steps do
		local nextDir = (dir * ctx.R + head * stepLen).Unit
		local a = ctx.center + dir * (ctx.R + 0.08)
		local b = ctx.center + nextDir * (ctx.R + 0.08)
		local mid = (a + b) / 2
		local up = ((a + b) / 2 - ctx.center).Unit
		local p = part(parent, {
			Name = "Glow",
			Size = Vector3.new(width, 0.18, (b - a).Magnitude + width * 0.5),
			CFrame = CFrame.lookAt(mid, b, up),
			Material = Enum.Material.Neon,
			Color = color,
		})
		table.insert(ctx.pulse, p)
		-- wander a little
		local side = head:Cross(nextDir).Unit
		head = (head + side * ctx.rng:NextNumber(-wobble, wobble)).Unit
		head = (head - nextDir * head:Dot(nextDir)).Unit
		dir = nextDir
	end
end

-- Per-planet particle budget (mobile/low settings get fewer); over-budget emitters stay unparented.
local EMITTER_BUDGET = { full = 10, reduced = 6, minimal = 0 }
local function emitterAllowed(ctx: Ctx): boolean
	local level = ctx.effects and (ctx.effects.level or ctx.effects.name) or "full"
	return #ctx.emitters < (EMITTER_BUDGET[level] or 10)
end

local function sparkleEmitter(ctx: Ctx, parent: BasePart, color: Color3, rate: number, speed: number, size: number, life: number): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = VisualStyle.Texture.Sparkle
	e.Color = ColorSequence.new(color)
	e.LightEmission = 1
	e.Rate = rate
	e.Lifetime = NumberRange.new(life * 0.7, life)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, size), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new(0.25)
	e.SpreadAngle = Vector2.new(25, 25)
	if emitterAllowed(ctx) then
		e.Parent = parent
		table.insert(ctx.emitters, e)
	end
	return e
end

local function smokeEmitter(ctx: Ctx, parent: BasePart, color: Color3, rate: number)
	local e = Instance.new("ParticleEmitter")
	e.Texture = VisualStyle.Texture.Smoke
	e.Color = ColorSequence.new(color)
	e.Rate = rate
	e.Lifetime = NumberRange.new(3, 5)
	e.Speed = NumberRange.new(2, 4)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 6) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	e.SpreadAngle = Vector2.new(10, 10)
	if emitterAllowed(ctx) then
		e.Parent = parent
		table.insert(ctx.emitters, e)
	end
end

----------------------------------------------------------------------------------------------------
-- small formation builders (each returns nothing; adds parts to `parent`, registers growth parts)

local function grow(ctx: Ctx, p: BasePart)
	table.insert(ctx.grow, p)
end

local function spire(ctx: Ctx, parent: Instance, dir: Vector3, color: Color3, hMin: number, hMax: number)
	local h = ctx.rng:NextNumber(hMin, hMax)
	local w = ctx.rng:NextNumber(1.6, 3)
	grow(ctx, part(parent, {
		Name = "Spire", Size = Vector3.new(w, h, w * ctx.rng:NextNumber(0.8, 1.2)),
		CFrame = onSurface(ctx, dir, h * 0.45, ctx.rng:NextNumber(0, 6.28)) * CFrame.Angles(ctx.rng:NextNumber(-0.25, 0.25), 0, ctx.rng:NextNumber(-0.25, 0.25)),
		Material = Enum.Material.Basalt, Color = shade(color, ctx.rng:NextNumber(0.8, 1.05)),
	}))
end

local function vent(ctx: Ctx, parent: Instance, dir: Vector3, glow: Color3, withSmoke: boolean)
	local base = onSurface(ctx, dir, 0)
	grow(ctx, part(parent, { Name = "Vent", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 6, 6), CFrame = base * CFrame.new(0, 0.6, 0) * UPRIGHT, Material = Enum.Material.Basalt, Color = Color3.fromRGB(58, 50, 50) }))
	grow(ctx, part(parent, { Name = "Vent", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 3.6, 3.6), CFrame = base * CFrame.new(0, 1.9, 0) * UPRIGHT, Material = Enum.Material.Basalt, Color = Color3.fromRGB(70, 60, 58) }))
	local mouth = part(parent, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 2.2, 2.2), CFrame = base * CFrame.new(0, 2.72, 0) * UPRIGHT, Material = Enum.Material.Neon, Color = glow })
	table.insert(ctx.pulse, mouth)
	if withSmoke and ctx.effects.particles then
		smokeEmitter(ctx, mouth, Color3.fromRGB(200, 195, 190), 1.5)
	end
end

----------------------------------------------------------------------------------------------------
-- Mesh assets (ReplicatedStorage.PF_Assets.Models, pivots at the bottom centre, non-colliding). A clone is
-- scaled to `height`, seated with PivotTo(surface frame), every part registered for the emergence FX, and
-- any ParticleEmitter it carries is kept only inside the per-planet emitter budget (rate capped).
local AssetModels: Instance? = nil
do
	local assets = ReplicatedStorage:FindFirstChild("PF_Assets")
	AssetModels = assets and assets:FindFirstChild("Models")
end

local function assetTemplate(name: string): Model?
	local t = AssetModels and AssetModels:FindFirstChild(name)
	return if t and t:IsA("Model") then t else nil
end

local function placeAsset(ctx: Ctx, parent: Instance, name: string, cf: CFrame, height: number, tint: ((BasePart) -> ())?): Model?
	local tpl = assetTemplate(name)
	if not tpl then
		return nil
	end
	local m = tpl:Clone()
	local h0 = tonumber(tpl:GetAttribute("PFHeight")) or 10
	m:ScaleTo(math.max(0.01, tpl:GetScale() * height / h0)) -- ScaleTo is absolute; some templates ship pre-scaled
	m:PivotTo(cf)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch = true, false, false, false
			if tint then
				tint(d)
			end
			grow(ctx, d)
		elseif d:IsA("ParticleEmitter") then
			if ctx.effects.particles and emitterAllowed(ctx) then
				d.Rate = math.min(d.Rate, 10)
				table.insert(ctx.emitters, d)
			else
				d:Destroy()
			end
		end
	end
	m.Parent = parent
	return m
end

local function isLeaves(p: BasePart): boolean
	return string.sub(p.Name, 1, 6) == "Leaves"
end

local TREE_VARIANTS = { "TreeDefault", "TreeDefault", "TreeVariant" } -- default 2:1 against the 3-part variant

local function tree(ctx: Ctx, parent: Instance, dir: Vector3, glowing: boolean)
	local twist = ctx.rng:NextNumber(0, 6.28)
	-- conifers on frozen worlds and in the cold polar bands of planets with ice caps
	local cold = ctx.spec.theme == "frozen" or (ctx.spec.polarCaps == true and math.abs(dir.Y) > 0.62)
	local name = if cold then "TreePine" else TREE_VARIANTS[ctx.rng:NextInteger(1, #TREE_VARIANTS)]
	local h = ctx.rng:NextNumber(8, 12) * (if cold then 1.15 else 1)
	local leafShade = ctx.rng:NextNumber(0.88, 1.12)
	placeAsset(ctx, parent, name, onSurface(ctx, dir, -0.4, twist), h, function(p)
		if not isLeaves(p) then
			return
		end
		if glowing then
			p.Name = "Glow" -- picked up by the controller's slow pulse
			p.Material = Enum.Material.Neon
			p.Color = ctx.pal.glow
			p.Transparency = 0.35
			table.insert(ctx.pulse, p)
		elseif cold then
			p.Color = p.Color:Lerp(Color3.fromRGB(226, 240, 250), 0.55) -- frosted needles
		else
			p.Color = shade(p.Color, leafShade)
		end
	end)
end
local function mushroom(ctx: Ctx, parent: Instance, dir: Vector3)
	local h = ctx.rng:NextNumber(2, 4)
	local base = onSurface(ctx, dir, 0)
	grow(ctx, part(parent, { Name = "Stalk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(h, 0.7, 0.7), CFrame = base * CFrame.new(0, h / 2, 0) * UPRIGHT, Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(235, 230, 220) }))
	local cap = part(parent, { Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * ctx.rng:NextNumber(2.2, 3.2), CFrame = base * CFrame.new(0, h, 0), Material = Enum.Material.Neon, Color = if ctx.rng:NextNumber() < 0.5 then ctx.pal.glow else ctx.pal.accent })
	grow(ctx, cap)
	table.insert(ctx.pulse, cap)
end

local function flowers(ctx: Ctx, parent: Instance, dir: Vector3)
	local f = WorldLayout.frameFromUp(dir, 0)
	for _ = 1, 3 do
		local d = (dir * ctx.R + (f.RightVector * ctx.rng:NextNumber(-1.5, 1.5) + f.LookVector * ctx.rng:NextNumber(-1.5, 1.5))).Unit
		local pick = ctx.rng:NextNumber()
		grow(ctx, part(parent, { Name = "Flower", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.9, CFrame = onSurface(ctx, d, 0.8), Material = Enum.Material.Neon, Color = if pick < 0.4 then ctx.pal.accent elseif pick < 0.75 then ctx.pal.secondary else Color3.new(1, 1, 1) }))
	end
end

local function iceCluster(ctx: Ctx, parent: Instance, dir: Vector3, scale: number)
	local f = WorldLayout.frameFromUp(dir, ctx.rng:NextNumber(0, 6.28))
	for k = 1, ctx.rng:NextInteger(3, 5) do
		local off = (f.RightVector * ctx.rng:NextNumber(-1.8, 1.8) + f.LookVector * ctx.rng:NextNumber(-1.8, 1.8)) * scale
		local d = (dir * ctx.R + off).Unit
		local h = ctx.rng:NextNumber(4, 9) * scale * (if k == 1 then 1.3 else 1)
		local outward = (d - dir) * 8
		local cf = onSurface(ctx, d, -0.3, ctx.rng:NextNumber(0, 6.28))
			* CFrame.Angles(outward.Z * 0.5 + ctx.rng:NextNumber(-0.2, 0.2), 0, -outward.X * 0.5 + ctx.rng:NextNumber(-0.2, 0.2))
		placeAsset(ctx, parent, "CrystalIce", cf, h, nil)
	end
end
local function glacier(ctx: Ctx, parent: Instance, dir: Vector3)
	local w, d = ctx.rng:NextNumber(8, 14), ctx.rng:NextNumber(5, 9)
	local h = ctx.rng:NextNumber(1.6, 3)
	grow(ctx, part(parent, { Name = "Glacier", Size = Vector3.new(w, h, d), CFrame = onSurface(ctx, dir, h * 0.5 - sag(ctx, w / 2), ctx.rng:NextNumber(0, 6.28)), Material = Enum.Material.Glacier, Color = Color3.fromRGB(220, 238, 250) }))
end

local function volcano(ctx: Ctx, parent: Instance, dir: Vector3, scale: number, rivers: number)
	local tpl = assetTemplate("Volcano")
	local width = 20 * scale
	local ratio = if tpl then (tonumber(tpl:GetAttribute("PFHeight")) or 52.7) / (tonumber(tpl:GetAttribute("PFWidth")) or 70) else 0.75
	local h = width * ratio
	local base = onSurface(ctx, dir, -sag(ctx, width * 0.5), ctx.rng:NextNumber(0, 6.28))
	local m = placeAsset(ctx, parent, "Volcano", base, h, function(p)
		p.Name = "Volcano"
	end)
	if not m then
		return
	end
	local caldera = part(parent, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, width * 0.2, width * 0.2), CFrame = base * CFrame.new(0, h * 0.9, 0) * UPRIGHT, Material = Enum.Material.Neon, Color = ctx.pal.glow })
	grow(ctx, caldera)
	table.insert(ctx.pulse, caldera)
	if ctx.effects.particles then
		sparkleEmitter(ctx, caldera, ctx.pal.particle or ctx.pal.glow, 4 * scale, 8, 0.5, 2)
		smokeEmitter(ctx, caldera, Color3.fromRGB(70, 62, 62), 1.5 * scale)
	end
	local f = WorldLayout.frameFromUp(dir, ctx.rng:NextNumber(0, 6.28))
	for r = 1, rivers do
		local a = (r / rivers) * math.pi * 2 + ctx.rng:NextNumber(-0.3, 0.3)
		local heading = f.RightVector * math.cos(a) + f.LookVector * math.sin(a)
		local start = (dir * ctx.R + heading * width * 0.45).Unit
		arcLine(ctx, parent, start, heading, math.floor(4 + 3 * scale), 3, 0.9 * scale, ctx.pal.glow, 0.35)
	end
end
-- Crystal theme: the effect-carrying base crystal (every 3rd an ice-blue accent); frozen: ice crystals;
-- volcanic: red ember crystals; everything else (primordial/living): green crystals.
local function crystalTemplate(ctx: Ctx, k: number): string
	local P = Profile.PALETTES
	local label = ctx.spec.themeLabel
	if label == "void" then
		return "CrystalBase"
	elseif label == "astral" or label == "mechanical" then
		return "CrystalIce"
	end
	if ctx.pal == P.crystal then
		return if k % 3 == 0 then "CrystalIce" else "CrystalBase"
	elseif ctx.pal == P.frozen then
		return "CrystalIce"
	elseif ctx.pal == P.volcanic then
		return "CrystalRed"
	end
	return "CrystalGreen"
end

local function crystalCluster(ctx: Ctx, parent: Instance, dir: Vector3, scale: number)
	local f = WorldLayout.frameFromUp(dir, ctx.rng:NextNumber(0, 6.28))
	for k = 1, ctx.rng:NextInteger(3, 6) do
		local off = (f.RightVector * ctx.rng:NextNumber(-1.5, 1.5) + f.LookVector * ctx.rng:NextNumber(-1.5, 1.5)) * scale
		local d = (dir * ctx.R + off).Unit
		local h = ctx.rng:NextNumber(3, 8) * scale * (if k == 1 then 1.5 else 1)
		local tilt = (d - dir) * 10
		local cf = onSurface(ctx, d, -0.3, ctx.rng:NextNumber(0, 6.28))
			* CFrame.Angles(tilt.Z * 0.5 + ctx.rng:NextNumber(-0.25, 0.25), 0, -tilt.X * 0.5 + ctx.rng:NextNumber(-0.25, 0.25))
		local tplName = crystalTemplate(ctx, k)
		placeAsset(ctx, parent, tplName, cf, h, if tplName == "CrystalBase" then function(p: BasePart)
			-- the supplied base crystal is dark magenta glass: tint it to the planet's accent and let it glow softly
			if p:IsA("UnionOperation") then
				p.UsePartColor = true
			end
			p.Color = ctx.pal.accent
			p.Material = Enum.Material.Neon
			p.Transparency = 0.3
		end else nil)
	end
end
local function cloud(ctx: Ctx, parent: Instance, dir: Vector3)
	local alt = ctx.rng:NextNumber(9, 13)
	local f = WorldLayout.frameFromUp(dir, ctx.rng:NextNumber(0, 6.28))
	for k = 1, 4 do
		local off = f.RightVector * (k - 2.5) * 3.2 + f.LookVector * ctx.rng:NextNumber(-1.5, 1.5)
		local d = (dir * (ctx.R + alt) + off).Unit
		part(parent, { Name = "Cloud", Shape = Enum.PartType.Ball, Size = Vector3.one * ctx.rng:NextNumber(3.5, 6.5) * (if k == 2 or k == 3 then 1.25 else 1), CFrame = CFrame.new(ctx.center + d * (ctx.R + alt)), Material = Enum.Material.Neon, Color = shade(ctx.pal.cloud, 0.82), Transparency = 0.45, CastShadow = false })
	end
end

----------------------------------------------------------------------------------------------------
-- landmarks (one per planet at stage >= 4; live in the FAR folder so they read from space)

local function landmarkDir(ctx: Ctx): Vector3
	-- best of 40 candidates: maximise distance to blocked zones, prefer the equator band (good silhouette)
	local best, bestScore = Vector3.xAxis, -math.huge
	for _ = 1, 40 do
		local d = randomUnit(ctx.rng)
		local minA = math.huge
		for _, b in ctx.blocked do
			minA = math.min(minA, angleBetween(d, b.dir) - b.ang)
		end
		local score = minA - math.abs(d.Y) * 0.6
		if score > bestScore then
			best, bestScore = d, score
		end
	end
	table.insert(ctx.placed, { dir = best, ang = angOf(ctx, 22) })
	return best
end

local function worldTree(ctx: Ctx, parent: Instance, dir: Vector3, scale: number, withCliff: boolean)
	local base = onSurface(ctx, dir, -sag(ctx, 4 * scale), ctx.rng:NextNumber(0, 6.28))
	local H = 34 * scale
	local tpl = assetTemplate("TreeVariant")
	local w = H * ((tpl and tonumber(tpl:GetAttribute("PFWidth")) or 15.2) / (tpl and tonumber(tpl:GetAttribute("PFHeight")) or 24.2))
	placeAsset(ctx, parent, "TreeVariant", base, H, function(p)
		if p.Name == "Trunk" then
			p.Name = "WorldTree"
		elseif isLeaves(p) then
			p.Color = shade(p.Color, 1.12)
		end
	end)
	-- bioluminescent fruit in the canopy
	for k = 1, 10 do
		local g = part(parent, { Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.3 * scale, CFrame = base * CFrame.new(ctx.rng:NextNumber(-0.42, 0.42) * w, ctx.rng:NextNumber(0.55, 0.95) * H, ctx.rng:NextNumber(-0.42, 0.42) * w), Material = Enum.Material.Neon, Color = if k % 2 == 0 then ctx.pal.glow else (ctx.pal.secondary or ctx.pal.glow) })
		table.insert(ctx.pulse, g)
	end
	if withCliff then
		local cliff = part(parent, { Name = "Cliff", Size = Vector3.new(9, 14, 6), CFrame = base * CFrame.new(w * 0.5 + 8, 6.5, 0), Material = Enum.Material.Slate, Color = Color3.fromRGB(96, 104, 96) })
		grow(ctx, cliff)
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(-4.6, 6.8, 0)
		a0.Parent = cliff
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(-6.8, -7, 0)
		a1.Parent = cliff
		local bm = Instance.new("Beam")
		bm.Attachment0, bm.Attachment1 = a0, a1
		bm.Width0, bm.Width1 = 3.5, 5
		bm.Color = ColorSequence.new(Color3.fromRGB(200, 240, 255), ctx.pal.water or Color3.fromRGB(40, 116, 178))
		bm.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 0.45) })
		bm.LightEmission = 0.4
		bm.FaceCamera = true
		bm.CurveSize0 = -2
		bm.Parent = cliff
		discAt(ctx, parent, (dir * ctx.R + (base.RightVector * (w * 0.5 + 2))).Unit, 9, 0.12, { Name = "Pool", Material = Enum.Material.Glass, Color = ctx.pal.water or Color3.fromRGB(40, 116, 178), Transparency = 0.1 })
	end
end
local function waterfall(ctx: Ctx, parent: Instance, dir: Vector3)
	local base = onSurface(ctx, dir, 0, ctx.rng:NextNumber(0, 6.28))
	local cliff = part(parent, { Name = "Cliff", Size = Vector3.new(10, 15, 7), CFrame = base * CFrame.new(0, 6.8, 0), Material = Enum.Material.Slate, Color = Color3.fromRGB(96, 104, 96) })
	grow(ctx, cliff)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(-5.1, 7.2, 0)
	a0.Parent = cliff
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(-7.4, -7.4, 0)
	a1.Parent = cliff
	local bm = Instance.new("Beam")
	bm.Attachment0, bm.Attachment1 = a0, a1
	bm.Width0, bm.Width1 = 4, 5.5
	bm.Color = ColorSequence.new(Color3.fromRGB(205, 242, 255), ctx.pal.water or Color3.fromRGB(40, 116, 178))
	bm.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 0.45) })
	bm.LightEmission = 0.4
	bm.FaceCamera = true
	bm.CurveSize0 = -2
	bm.Parent = cliff
	discAt(ctx, parent, (dir * ctx.R - base.RightVector * 8).Unit, 10, 0.12, { Name = "Pool", Material = Enum.Material.Glass, Color = ctx.pal.water or Color3.fromRGB(40, 116, 178), Transparency = 0.1 })
	for k = 1, 4 do
		local d = (dir * ctx.R + base.LookVector * (k - 2.5) * 4 + base.RightVector * 3).Unit
		local s2 = ctx.rng:NextNumber(2.5, 4)
		grow(ctx, part(parent, { Name = "Moss", Shape = Enum.PartType.Ball, Size = Vector3.one * s2, CFrame = onSurface(ctx, d, s2 * 0.3), Material = Enum.Material.Grass, Color = Color3.fromRGB(80, 150, 76) }))
	end
end

local function glacierSpire(ctx: Ctx, parent: Instance, dir: Vector3, scale: number)
	iceCluster(ctx, parent, dir, 3.2 * scale)
	local spireCf = onSurface(ctx, dir, 16 * scale, ctx.rng:NextNumber(0, 6.28))
	grow(ctx, part(parent, { Name = "GlacierSpire", Size = Vector3.new(5, 34, 5) * scale, CFrame = spireCf * CFrame.Angles(0, math.rad(45), 0), Material = Enum.Material.Ice, Color = Color3.fromRGB(170, 215, 255), Transparency = 0.15 }))
	local core = part(parent, { Name = "Glow", Size = Vector3.new(1.4, 30, 1.4) * scale, CFrame = spireCf, Material = Enum.Material.Neon, Color = ctx.pal.glow })
	table.insert(ctx.pulse, core)
	grow(ctx, core)
end

local function prismHeart(ctx: Ctx, parent: Instance, dir: Vector3, scale: number, withRing: boolean)
	crystalCluster(ctx, parent, dir, 3.6 * scale)
	if withRing then
		local ringCf = onSurface(ctx, dir, 14 * scale)
		for k = 1, 20 do
			local ang = (k / 20) * math.pi * 2
			local seg = part(parent, { Name = "Glow", Size = Vector3.new(0.5, 0.5, 2.6) * scale, CFrame = ringCf * CFrame.Angles(0, ang, 0) * CFrame.new(9 * scale, 0, 0), Material = Enum.Material.Neon, Color = ctx.pal.glow, Transparency = 0.2 })
			table.insert(ctx.pulse, seg)
		end
	end
end

local function arch(ctx: Ctx, parent: Instance, dir: Vector3, colorA: Color3, colorB: Color3, mat: Enum.Material)
	local base = onSurface(ctx, dir, 0, ctx.rng:NextNumber(0, 6.28))
	for _, x in { -5, 5 } do
		grow(ctx, part(parent, { Name = "ArchPillar", Size = Vector3.new(2, 12, 2), CFrame = base * CFrame.new(x, 5.6, 0) * CFrame.Angles(0, math.rad(45), 0), Material = mat, Color = colorA, Transparency = if mat == Enum.Material.Glass then 0.2 else 0 }))
	end
	grow(ctx, part(parent, { Name = "ArchTop", Size = Vector3.new(13, 1.8, 1.8), CFrame = base * CFrame.new(0, 12, 0), Material = mat, Color = colorA, Transparency = if mat == Enum.Material.Glass then 0.2 else 0 }))
	local g = part(parent, { Name = "Glow", Size = Vector3.new(8, 8, 0.3), CFrame = base * CFrame.new(0, 6.5, 0), Material = Enum.Material.Neon, Color = colorB, Transparency = 0.55 })
	table.insert(ctx.pulse, g)
end

local function landmarkDirOrNil(ctx: Ctx): Vector3
	return landmarkDir(ctx)
end

local function buildLandmark(ctx: Ctx, parent: Instance, theme: string)
	local dir = landmarkDirOrNil(ctx)
	if theme == "living" then
		worldTree(ctx, parent, dir, 1, true)
	elseif theme == "frozen" then
		glacierSpire(ctx, parent, dir, 1)
	elseif theme == "volcanic" then
		volcano(ctx, parent, dir, 2.3, 5)
	else
		prismHeart(ctx, parent, dir, 1, true)
	end
end

----------------------------------------------------------------------------------------------------
-- Developer B's FormationRegistry archetypes -> art (each instance at a deterministic, zone-valid spot)

local ARCHETYPES: { [string]: (ctx: Ctx, parent: Instance, dir: Vector3) -> () } = {
	-- living
	grass = function(ctx, parent, dir)
		for k = 1, 5 do
			local d = if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit
			discAt(ctx, parent, d, ctx.rng:NextNumber(8, 12), 0.035, { Name = "Patch", Material = Enum.Material.Grass, Color = shade(Color3.fromRGB(96, 160, 80), ctx.rng:NextNumber(0.9, 1.1)) })
		end
	end,
	forest = function(ctx, parent, dir)
		for k = 1, 5 do
			local d = if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit
			tree(ctx, parent, d, false)
		end
	end,
	glowGrove = function(ctx, parent, dir)
		for k = 1, 6 do
			local d = if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit
			if k % 2 == 0 then mushroom(ctx, parent, d) else tree(ctx, parent, d, true) end
		end
	end,
	ancientTree = function(ctx, parent, dir) worldTree(ctx, parent, dir, 0.6, false) end,
	worldTree = function(ctx, parent, dir) worldTree(ctx, parent, dir, 1.2, false) end,
	waterfall = function(ctx, parent, dir) waterfall(ctx, parent, dir) end,
	-- frozen
	frozenLake = function(ctx, parent, dir)
		for k = 1, 5 do
			local d = if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit
			discAt(ctx, parent, d, ctx.rng:NextNumber(12, 18), 0.04, { Name = "Ice", Material = Enum.Material.Ice, Color = Color3.fromRGB(170, 215, 245), Transparency = 0.1 })
		end
	end,
	iceSpikes = function(ctx, parent, dir)
		for k = 1, 3 do
			iceCluster(ctx, parent, if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 4).Unit, 1)
		end
	end,
	glacier = function(ctx, parent, dir)
		for k = 1, 3 do
			glacier(ctx, parent, if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 7).Unit)
		end
	end,
	iceCave = function(ctx, parent, dir) arch(ctx, parent, dir, Color3.fromRGB(190, 225, 250), Color3.fromRGB(90, 200, 255), Enum.Material.Ice) end,
	aurora = function(ctx, parent, dir)
		local base = onSurface(ctx, dir, 26)
		local anchor = part(parent, { Name = "AuroraAnchor", Size = Vector3.one, CFrame = base, Transparency = 1 })
		for k = 1, 2 do
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(-16, 0, (k - 1.5) * 8)
			a0.Parent = anchor
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(16, 0, (k - 1.5) * 8)
			a1.Parent = anchor
			local bm = Instance.new("Beam")
			bm.Attachment0, bm.Attachment1 = a0, a1
			bm.Width0, bm.Width1 = 12, 12
			bm.CurveSize0, bm.CurveSize1 = 14, -14
			bm.Segments = 16
			bm.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 255, 180)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 200, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 120, 255)) })
			bm.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.5), NumberSequenceKeypoint.new(0.7, 0.5), NumberSequenceKeypoint.new(1, 1) })
			bm.LightEmission = 1
			bm.Parent = anchor
		end
	end,
	frozenCrown = function(ctx, parent, dir) glacierSpire(ctx, parent, dir, 1.1) end,
	-- volcanic
	thermalCrack = function(ctx, parent, dir)
		for _ = 1, 3 do
			arcLine(ctx, parent, dir, randomUnit(ctx.rng), 6, 2.4, 1.1, Color3.fromRGB(255, 110, 30), 0.5)
		end
	end,
	lavaPool = function(ctx, parent, dir)
		local g = discAt(ctx, parent, dir, 12, 0.08, { Name = "Glow", Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 100, 25) })
		table.insert(ctx.pulse, g)
		for _ = 1, 5 do
			spire(ctx, parent, (dir * ctx.R + randomUnit(ctx.rng) * 5.5).Unit, Color3.fromRGB(56, 46, 46), 1.5, 3.5)
		end
	end,
	basalt = function(ctx, parent, dir)
		for k = 1, 7 do
			spire(ctx, parent, if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit, Color3.fromRGB(52, 44, 46), 6, 12)
		end
	end,
	magmaRiver = function(ctx, parent, dir) arcLine(ctx, parent, dir, randomUnit(ctx.rng), 12, 2.8, 2.4, Color3.fromRGB(255, 100, 25), 0.3) end,
	volcano = function(ctx, parent, dir) volcano(ctx, parent, dir, 1.6, 3) end,
	eternalCore = function(ctx, parent, dir)
		volcano(ctx, parent, dir, 2.2, 5)
		local core = part(parent, { Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * 7, CFrame = onSurface(ctx, dir, 24), Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 160, 60), Transparency = 0.1 })
		table.insert(ctx.pulse, core)
	end,
	-- crystal
	crystalCluster = function(ctx, parent, dir) crystalCluster(ctx, parent, dir, 1.2) end,
	energyVeins = function(ctx, parent, dir)
		for _ = 1, 3 do
			arcLine(ctx, parent, dir, randomUnit(ctx.rng), 7, 2.4, 0.35, Color3.fromRGB(175, 110, 255), 0.6)
		end
	end,
	crystalGarden = function(ctx, parent, dir)
		for k = 1, 5 do
			crystalCluster(ctx, parent, if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit, 0.6)
		end
	end,
	resonanceArch = function(ctx, parent, dir) arch(ctx, parent, dir, Color3.fromRGB(175, 110, 255), Color3.fromRGB(90, 230, 255), Enum.Material.Glass) end,
	crystalSpire = function(ctx, parent, dir) crystalCluster(ctx, parent, dir, 3) end,
	celestialPrism = function(ctx, parent, dir) prismHeart(ctx, parent, dir, 1.1, true) end,
	-- generic
	impact = function(ctx, parent, dir)
		discAt(ctx, parent, dir, 14, 0.05, { Name = "Impact", Material = Enum.Material.Ice, Color = Color3.fromRGB(180, 215, 240), Transparency = 0.1 })
		local f = WorldLayout.frameFromUp(dir, 0)
		for k = 1, 10 do
			local ang = k / 10 * math.pi * 2
			local d = (dir * ctx.R + (f.RightVector * math.cos(ang) + f.LookVector * math.sin(ang)) * 6.5).Unit
			grow(ctx, part(parent, { Name = "Rim", Size = Vector3.new(2.4, 1.2, 1.4), CFrame = onSurface(ctx, d, 0.3, ang), Material = Enum.Material.Ice, Color = Color3.fromRGB(205, 230, 250) }))
		end
	end,
	ocean = function(ctx, parent, dir)
		for k = 1, 8 do
			local d = if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 9).Unit
			discAt(ctx, parent, d, ctx.rng:NextNumber(16, 24), 0.05 + k * 0.002, { Name = "Water", Material = Enum.Material.Glass, Color = Color3.fromRGB(44, 110, 170), Transparency = 0.12 })
		end
	end,
	steam = function(ctx, parent, dir)
		for k = 1, 2 do
			vent(ctx, parent, if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 4).Unit, Color3.fromRGB(150, 220, 255), true)
		end
	end,
	fissures = function(ctx, parent, dir)
		for _ = 1, 3 do
			arcLine(ctx, parent, dir, randomUnit(ctx.rng), 6, 2.6, 0.45, Color3.fromRGB(190, 120, 255), 0.5)
		end
	end,
	celestialFlora = function(ctx, parent, dir)
		for k = 1, 6 do
			local d = if k == 1 then dir else (dir * ctx.R + randomUnit(ctx.rng) * 5).Unit
			if k % 2 == 0 then mushroom(ctx, parent, d) else flowers(ctx, parent, d) end
		end
	end,
}
PlanetDecorator.ARCHETYPES = ARCHETYPES

local function placeInZones(ctx: Ctx, zones: { { number } }, footprint: number, rng: Random): Vector3?
	local ang = angOf(ctx, footprint)
	for _ = 1, 60 do
		local z = zones[rng:NextInteger(1, #zones)]
		local polar = math.rad(rng:NextNumber(z[1], z[2]))
		local az = rng:NextNumber(0, math.pi * 2)
		local d = Vector3.new(math.sin(polar) * math.cos(az), math.cos(polar), math.sin(polar) * math.sin(az))
		if isFree(ctx, d, ang, true) then
			table.insert(ctx.placed, { dir = d, ang = ang })
			return d
		end
	end
	return nil
end

local function hashId(id: string): number
	local h = 5381
	for i = 1, #id do
		h = (h * 33 + string.byte(id, i)) % 2147483647
	end
	return h
end

-- Returns: hasLandmark, instances rendered, skipped (no space / unknown archetype)
local function buildRegistryFormations(ctx: Ctx, near: Instance, far: Instance): (boolean, number, number)
	local counts = ctx.spec.formationCounts or {}
	if not FormationRegistry or next(counts) == nil then
		return false, 0, 0
	end
	local ids = {}
	for id in counts do
		table.insert(ids, id)
	end
	table.sort(ids)
	local hasLandmark, rendered, skipped = false, 0, 0
	local savedRng, savedPal = ctx.rng, ctx.pal
	for _, id in ids do
		local okDef, def = pcall(FormationRegistry.get, id)
		local builder = okDef and def and ARCHETYPES[def.archetype]
		local active = okDef and def and (not def.dormantOutsideBranch or def.branch == nil or def.branch == ctx.spec.branch)
		if def and builder and active then
			local theme = if def.branch then string.lower(def.branch) else ctx.spec.theme
			ctx.pal = Profile.PALETTES[theme] or savedPal
			for i = 1, math.min(counts[id], def.maxCount or 1) do
				local rng = Random.new((ctx.spec.seed + hashId(id) * 31 + i * 7919) % 2147483647)
				local d = placeInZones(ctx, def.zones or { { 30, 165 } }, def.footprint or 6, rng)
				if d then
					ctx.rng = rng
					builder(ctx, if def.landmark then far else near, d)
					rendered += 1
					hasLandmark = hasLandmark or def.landmark == true
				else
					skipped += 1
				end
			end
		elseif counts[id] > 0 and not (def and not active) then
			skipped += 1
		end
	end
	ctx.rng, ctx.pal = savedRng, savedPal
	return hasLandmark, rendered, skipped
end

----------------------------------------------------------------------------------------------------

local function buildRings(ctx: Ctx, parent: Instance, count: number)
	local tilt = CFrame.Angles(ctx.rng:NextNumber(-0.5, 0.5), ctx.rng:NextNumber(0, 6.28), ctx.rng:NextNumber(-0.5, 0.5))
	local defs = {
		{ r0 = 1.58, r1 = 1.59, color = ctx.pal.glow, t = 0.35, mat = Enum.Material.Neon },
		{ r0 = 1.66, r1 = 1.665, color = ctx.pal.accent, t = 0.5, mat = Enum.Material.Neon },
	}
	for i = 1, #defs do
		local d = defs[i]
		local r = (d.r0 + d.r1) / 2 * ctx.R
		local w = (d.r1 - d.r0) * ctx.R
		-- 2026-11-22 (perf): rings were 2 x 48 semi-transparent segments on EVERY ringed planet's far LOD (the largest
		-- per-planet cost). 32 keeps the band smooth (sagitta < 0.8 studs at r = 1.6R); reduced/minimal effects use 24.
		local segs = if ctx.effects.level == "full" then 32 else 24
		for k = 1, segs do
			local a = (k / segs) * math.pi * 2
			part(parent, { Name = "Ring", Size = Vector3.new(w, 0.25, 2 * math.pi * r / segs * 1.04), CFrame = CFrame.new(ctx.center) * tilt * CFrame.Angles(0, a, 0) * CFrame.new(r, 0, 0), Material = d.mat, Color = d.color, Transparency = d.t, CastShadow = false })
		end
	end
end

local function buildBlocked(ctx: Ctx, slotModel: Model, slot: number)
	-- 2026-11-23: zones protect fixed-size things, so they keep their STUD size (authored on R = 96)
	local function block(d: Vector3, refDeg: number)
		table.insert(ctx.blocked, { dir = d.Unit, ang = math.rad(refDeg) * Density.REFERENCE_RADIUS / ctx.R })
	end
	block(Vector3.yAxis, math.max(14, (Profile.VISUAL.POLAR_EXCLUSION_DEG or 0) * 0.6)) -- return pad + approach (B: POLAR_EXCLUSION_DEG)
	local sp = slotModel:FindFirstChild("SpawnPoint")
	local spawnDir = if sp and sp:IsA("BasePart") then (sp.Position - ctx.center).Unit else (WorldLayout.getPlanetSpawn(slot).Position - ctx.center).Unit
	block(spawnDir, 7)
	if okHL then
		local okBase, base = pcall(HarvestLayout.getBaseCFrame, slot)
		if okBase then
			local hDir = (base.Position - ctx.center).Unit
			block(hDir, 16) -- Gravity Harvester + meteor approach
			for i = 1, 5 do -- walking corridor spawn -> harvester
				block(spawnDir:Lerp(hDir, i / 6), 4)
			end
		end
	end
end

-- Build one prop at `dir` scaled by `s` about its surface point: the builder works on a virtual sphere of radius
-- R / s touching the planet there, then Model:ScaleTo(s) maps it onto the real surface (no floating bases).
local function scaledProp(ctx: Ctx, parent: Instance, dir: Vector3, s: number, build: (Instance) -> ())
	local m = Instance.new("Model")
	m.Name = "Prop"
	local surf = ctx.center + dir * ctx.R
	m.WorldPivot = CFrame.new(surf) * WorldLayout.frameFromUp(dir)
	local c0, r0 = ctx.center, ctx.R
	ctx.R = r0 / s
	ctx.center = surf - dir * ctx.R
	local ok, err = pcall(build, m)
	ctx.center, ctx.R = c0, r0
	if not ok then
		warn("[PF] decorator prop failed: " .. tostring(err))
	end
	if #m:GetChildren() == 0 then
		m:Destroy()
		return
	end
	m:ScaleTo(s)
	-- the wrapper only exists to scale about the surface point: hand its parts to the layer and drop it
	-- (one Model fewer per prop; nothing looks props up by model)
	for _, c in m:GetChildren() do
		c.Parent = parent
	end
	m:Destroy()
end

----------------------------------------------------------------------------------------------------
-- Planet Physics 3.0 (P3): barren geology. A stage-0 barren world had no client dressing at all (bare Core plus
-- the server's boulders). Craters (pale raised rim, dark floor, rim blocks, ejecta), dark regolith patches,
-- matte impact scars and loose stones; rock tones only, no glow, no life, so the world stays barren.
-- Discs are thick slabs whose top sits just above the sphere: a flat disc on a curved surface then shows a
-- slight raised edge (reads as a rim) instead of a floating edge.

local function slab(ctx: Ctx, parent: Instance, dir: Vector3, dia: number, top: number, thick: number, props: { [string]: any }): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(thick, dia, dia)
	props.CFrame = onSurface(ctx, dir, top - thick * 0.5) * UPRIGHT
	return part(parent, props)
end

local function stone(ctx: Ctx, parent: Instance, dir: Vector3, size: number, color: Color3, name: string?)
	local r = ctx.rng
	part(parent, {
		Name = name or "Stone",
		Size = Vector3.new(size * r:NextNumber(1.1, 1.6), size * r:NextNumber(0.45, 0.8), size),
		CFrame = onSurface(ctx, dir, size * 0.18, r:NextNumber(0, 6.28)) * CFrame.Angles(r:NextNumber(-0.35, 0.35), 0, r:NextNumber(-0.35, 0.35)),
		Material = Enum.Material.Slate,
		Color = shade(color, r:NextNumber(0.8, 1.08)),
	})
end

local function offsetDir(ctx: Ctx, dir: Vector3, frame: CFrame, angle: number, dist: number): Vector3
	return (dir * ctx.R + (frame.RightVector * math.cos(angle) + frame.LookVector * math.sin(angle)) * dist).Unit
end

local function crater(ctx: Ctx, parent: Instance, dir: Vector3, dia: number, base: Color3, big: boolean)
	local r = ctx.rng
	slab(ctx, parent, dir, dia * 1.22, 0.05, 0.6, { Name = "CraterRim", Material = Enum.Material.Slate, Color = shade(base, 1.16) })
	slab(ctx, parent, dir, dia, 0.09, 0.6, { Name = "CraterFloor", Material = Enum.Material.Sand, Color = shade(base, 0.6) })
	local f = WorldLayout.frameFromUp(dir, r:NextNumber(0, 6.28))
	if big then
		stone(ctx, parent, dir, 2.2, shade(base, 0.85), "CraterPeak")
	end
	local rimN = if big then 10 else 6
	for j = 1, rimN do
		local a = (j / rimN) * math.pi * 2 + r:NextNumber(-0.22, 0.22)
		stone(ctx, parent, offsetDir(ctx, dir, f, a, dia * 0.6), r:NextNumber(0.9, 1.7) * (if big then 1.35 else 1), base, "RimRock")
	end
	for _ = 1, (if big then 7 else 4) do
		local a = r:NextNumber(0, 6.28)
		stone(ctx, parent, offsetDir(ctx, dir, f, a, dia * r:NextNumber(0.75, 1.3)), r:NextNumber(0.35, 0.8), base, "Ejecta")
	end
end

local function scar(ctx: Ctx, parent: Instance, start: Vector3, heading: Vector3, steps: number, color: Color3)
	local dir = start
	local head = (heading - dir * heading:Dot(dir)).Unit
	for k = 1, steps do
		local stepLen = ctx.rng:NextNumber(2.2, 3.2)
		local nextDir = (dir * ctx.R + head * stepLen).Unit
		local a = ctx.center + dir * (ctx.R + 0.04)
		local b = ctx.center + nextDir * (ctx.R + 0.04)
		local width = 1.3 * (1 - (k - 1) / steps) + 0.35 -- groove narrows towards its end
		part(parent, {
			Name = "Scar",
			Size = Vector3.new(width, 0.14, (b - a).Magnitude + width * 0.4),
			CFrame = CFrame.lookAt((a + b) / 2, b, ((a + b) / 2 - ctx.center).Unit),
			Material = Enum.Material.Slate,
			Color = color,
		})
		local side = head:Cross(nextDir).Unit
		head = (head + side * ctx.rng:NextNumber(-0.12, 0.12)).Unit
		head = (head - nextDir * head:Dot(nextDir)).Unit
		dir = nextDir
	end
	-- the impactor's debris at the end of the groove
	local f = WorldLayout.frameFromUp(dir, 0)
	for _ = 1, 3 do
		stone(ctx, parent, offsetDir(ctx, dir, f, ctx.rng:NextNumber(0, 6.28), ctx.rng:NextNumber(0.5, 2)), ctx.rng:NextNumber(0.5, 1.1), color, "Debris")
	end
end

local function barrenGeology(ctx: Ctx, parent: Instance, theme: string, base: Color3, cnt: (number) -> number)
	local r = ctx.rng
	local barren = theme == "barren"
	for k = 1, cnt(if barren then 9 else 5) do
		local big = k <= 2
		local dia = if big then r:NextNumber(14, 16) else r:NextNumber(7, 11)
		local d = place(ctx, dia * 0.75)
		if d then
			crater(ctx, parent, d, dia, base, big)
		end
	end
	for _ = 1, cnt(if barren then 8 else 4) do
		local d = place(ctx, 5)
		if d then
			slab(ctx, parent, d, r:NextNumber(8, 14), 0.04, 0.5, { Name = "Regolith", Material = Enum.Material.Sand, Color = shade(base, r:NextNumber(0.68, 0.82)) })
		end
	end
	for _ = 1, cnt(if barren then 5 else 2) do
		local d = place(ctx, 3)
		if d then
			scar(ctx, parent, d, randomUnit(r), r:NextInteger(4, 7), shade(base, 0.55))
		end
	end
	for _ = 1, cnt(if barren then 14 else 6) do
		local d = place(ctx, 2.5)
		if d then
			local f = WorldLayout.frameFromUp(d, r:NextNumber(0, 6.28))
			for _ = 1, r:NextInteger(3, 5) do
				stone(ctx, parent, offsetDir(ctx, d, f, r:NextNumber(0, 6.28), r:NextNumber(0, 2.6)), r:NextNumber(0.4, 1.0), base)
			end
		end
	end
end

function PlanetDecorator.build(slotModel: Model, spec: any, effects: Effects, fxRoot: Instance): Built
	local core = slotModel:FindFirstChild("Core") :: BasePart
	local R = (slotModel:GetAttribute("PFRadius") :: number?) or core.Size.X / 2
	local near = Instance.new("Folder")
	near.Name = "Near_" .. spec.slot
	local far = Instance.new("Folder")
	far.Name = "Far_" .. spec.slot
	local ctx: Ctx = {
		center = core.Position, R = R, rng = Random.new(spec.seed), spec = spec, pal = spec.palette,
		placed = {}, blocked = {}, grow = {}, pulse = {}, emitters = {}, effects = effects,
	}
	buildBlocked(ctx, slotModel, spec.slot)
	local dens = effects.density
	local function cnt(x: number): number
		return math.floor(x * dens + 0.5)
	end
	local theme = spec.theme
	local pal = spec.palette

	-- Developer B's formations (persisted, unlocked by reactions) take precedence over generic dressing
	local regLandmark, regCount, regSkipped
	if spec.externalFormations then
		-- Evolution WOW 2.0: FormationLayer renders the registry formations incrementally (no rebuild on unlock).
		-- Reserve every site it uses or will grow into, so generic dressing never overlaps a formation.
		for _, site in spec.reservedSites or {} do
			table.insert(ctx.placed, site)
		end
		regLandmark, regCount, regSkipped = spec.ownedLandmark == true, spec.ownedFormations or 0, 0
	else
		regLandmark, regCount, regSkipped = buildRegistryFormations(ctx, near, far)
	end
	near:SetAttribute("PFRegistryFormations", regCount)
	near:SetAttribute("PFRegistrySkipped", regSkipped)
	if regCount >= 3 then
		dens *= 0.6 -- avoid clutter when the player's own formations are present
	end

	-- FAR: atmosphere, polar caps, water bodies, clouds, landmark, rings, moon, aura
	if spec.atmosphere then
		-- ForceField renders as a fresnel rim (bright limb, clear centre) and ignores the night lighting,
		-- so it reads as an atmosphere instead of a dark veil over the surface.
		local thick = math.clamp((0.94 - spec.atmosphere.transparency) / 0.06, 0, 1) -- 0 thin .. 1 dense
		part(far, { Name = "Atmosphere", Shape = Enum.PartType.Ball, Size = Vector3.one * 2 * R * (1.035 + 0.02 * thick), CFrame = CFrame.new(ctx.center), Material = Enum.Material.ForceField, Color = spec.atmosphere.color, Transparency = 0.35 - 0.25 * thick })
	end
	-- planet-scale features (caps, clouds, seas) grow with the radius so they read from orbit; surface props shrink
	local kR = R / Density.REFERENCE_RADIUS
	local PS = Density.GENERIC_PROP_SCALE
	if spec.polarCaps then
		for _, pole in { Vector3.yAxis, -Vector3.yAxis } do
			for k = 1, 7 do
				local f = WorldLayout.frameFromUp(pole, k)
				local d = if k == 1 then pole else (pole * R + (f.RightVector * math.cos(k) + f.LookVector * math.sin(k)) * 11 * kR).Unit
				discAt(ctx, far, d, 13 * math.sqrt(kR), 0.03, { Name = "PolarCap", Material = Enum.Material.Snow, Color = Color3.fromRGB(240, 246, 255) })
			end
		end
	end
	if spec.extraWater > 0 then
		local maria = slotModel:FindFirstChild("Maria")
		local anchors = {}
		if maria then
			for _, m in maria:GetChildren() do
				if m:IsA("BasePart") then
					table.insert(anchors, (m.Position - ctx.center).Unit)
				end
			end
		end
		-- (Evolution WOW 2.0) with FormationLayer active, extra water also avoids the reserved formation sites
		-- (a few deterministic retries, so the water budget is still spent)
		local avoid = spec.externalFormations == true
		for i = 1, spec.extraWater do
			for attempt = 1, if avoid then 8 else 1 do
				local anchor = if #anchors > 0 and attempt <= 2 then anchors[((i + attempt - 1) % #anchors) + 1] else randomUnit(ctx.rng)
				local f = WorldLayout.frameFromUp(anchor, ctx.rng:NextNumber(0, 6.28))
				local d = (anchor * R + (f.RightVector * ctx.rng:NextNumber(-1, 1) + f.LookVector * ctx.rng:NextNumber(-1, 1)) * 12).Unit
				if isFree(ctx, d, angOf(ctx, 6), avoid) then
					discAt(ctx, far, d, ctx.rng:NextNumber(10, 14), 0.04 + i * 0.002, { Name = "Water", Material = spec.basins.material, Color = spec.basins.color, Transparency = spec.basins.transparency })
					break
				end
			end
		end
	end
	for _ = 1, cnt(spec.clouds) do
		local d = place(ctx, 0.01)
		if d then
			scaledProp(ctx, far, d, kR, function(m)
				cloud(ctx, m, d)
			end)
		end
	end
	if spec.landmark and not regLandmark then
		buildLandmark(ctx, far, theme)
	end
	if spec.rings > 0 then
		buildRings(ctx, far, spec.rings)
	end
	if spec.moon and not spec.externalOrbitals then
		part(far, { Name = "Moonlet", Shape = Enum.PartType.Ball, Size = Vector3.one * R * 0.24, CFrame = CFrame.new(ctx.center + Vector3.new(R * 2.3, R * 0.6, 0)), Material = Enum.Material.Slate, Color = shade(pal.surface, 0.9) })
	end
	if spec.aura then
		part(far, { Name = "Aura", Shape = Enum.PartType.Ball, Size = Vector3.one * 2 * R * 1.16, CFrame = CFrame.new(ctx.center), Material = Enum.Material.ForceField, Color = pal.glow, Transparency = 0.2 })
	end

	-- NEAR: geology, biome, formations, props, particles (surface props at GENERIC_PROP_SCALE, 2026-11-23)
	for _ = 1, cnt(spec.vents) do
		local d = place(ctx, 4 * PS)
		if d then
			scaledProp(ctx, near, d, PS, function(m)
				vent(ctx, m, d, pal.glow or Color3.fromRGB(255, 120, 50), true)
			end)
		end
	end
	for _ = 1, cnt(spec.fissures) do
		local d = place(ctx, 3)
		if d then
			arcLine(ctx, near, d, randomUnit(ctx.rng), 6, 2.6, 0.5, pal.glow, 0.5)
		end
	end
	for _ = 1, cnt(spec.veins) do
		local d = place(ctx, 3)
		if d then
			arcLine(ctx, near, d, randomUnit(ctx.rng), 8, 2.4, 0.35, if theme == "crystal" then pal.accent else pal.accent, 0.6)
		end
	end
	for _ = 1, cnt(spec.spires) do
		local d = place(ctx, 2 * PS)
		if d then
			scaledProp(ctx, near, d, PS, function(m)
				spire(ctx, m, d, if theme == "frozen" then Color3.fromRGB(150, 170, 190) else Color3.fromRGB(80, 70, 68), 3, 8)
			end)
		end
	end
	for _ = 1, cnt(spec.patches) do
		local d = place(ctx, 4)
		if d then
			local col = if theme == "primordial" then pal.accent elseif theme == "frozen" then Color3.fromRGB(235, 245, 255) elseif theme == "volcanic" then Color3.fromRGB(30, 26, 28) elseif theme == "crystal" then shade(pal.accent, 0.6) else shade(pal.surface, 1.15)
			discAt(ctx, near, d, ctx.rng:NextNumber(6, 10), 0.03, { Name = "Patch", Material = if theme == "frozen" then Enum.Material.Snow else Enum.Material.Grass, Color = col })
		end
	end
	for i = 1, cnt(spec.formations) do
		if theme == "living" then
			local d = place(ctx, 3 * PS)
			if d then
				scaledProp(ctx, near, d, PS, function(m)
					if i % 4 == 0 then
						mushroom(ctx, m, d)
					else
						tree(ctx, m, d, spec.stage >= 4 and i % 3 == 0)
					end
				end)
			end
		elseif theme == "frozen" then
			local d = place(ctx, 5 * PS)
			if d then
				scaledProp(ctx, near, d, PS, function(m)
					if i % 3 == 0 then
						glacier(ctx, m, d)
					else
						iceCluster(ctx, m, d, 1 + (if spec.stage >= 4 then 0.4 else 0))
					end
				end)
			end
		elseif theme == "volcanic" then
			if i % 4 == 0 then
				local d = place(ctx, 10 * PS)
				if d then
					scaledProp(ctx, near, d, PS, function(m)
						volcano(ctx, m, d, 0.7, 2)
					end)
				end
			else
				local d = place(ctx, 2 * PS)
				if d then
					scaledProp(ctx, near, d, PS, function(m)
						spire(ctx, m, d, Color3.fromRGB(60, 50, 50), 4, 10)
					end)
				end
			end
		elseif theme == "crystal" then
			local d = place(ctx, 4 * PS)
			if d then
				scaledProp(ctx, near, d, PS, function(m)
					crystalCluster(ctx, m, d, 1 + (if spec.stage >= 4 then 0.35 else 0))
				end)
			end
		end
	end
	if effects.props then
		for _ = 1, cnt(spec.props) do
			local d = place(ctx, 1.6 * PS)
			if d then
				scaledProp(ctx, near, d, PS, function(m)
					if theme == "living" then
						flowers(ctx, m, d)
					elseif theme == "frozen" then
						iceCluster(ctx, m, d, 0.4)
					elseif theme == "volcanic" then
						local g = part(m, { Name = "Glow", Size = Vector3.new(1.2, 0.8, 1.2), CFrame = onSurface(ctx, d, 0.3, ctx.rng:NextNumber(0, 6.28)), Material = Enum.Material.Neon, Color = pal.accent })
						table.insert(ctx.pulse, g)
					else
						crystalCluster(ctx, m, d, 0.35)
					end
				end)
			end
		end
	end
	if (theme == "barren" or theme == "primordial") and effects.props ~= false then
		barrenGeology(ctx, near, theme, pal.surface or core.Color, cnt)
	end
	if spec.particles and effects.particles then
		local shell = part(near, { Name = "ParticleShell", Shape = Enum.PartType.Ball, Size = Vector3.one * (2 * R + 2), CFrame = CFrame.new(ctx.center), Transparency = 1 })
		local e = sparkleEmitter(ctx, shell, spec.particles.color, spec.particles.rate * dens * 2, 2, 0.5, 6)
		e.Shape = Enum.ParticleEmitterShape.Sphere
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	end
	if theme == "frozen" and spec.stage >= 4 and not spec.externalOrbitals then
		-- aurora: curved translucent beams above the north polar region
		local anchor = part(far, { Name = "AuroraAnchor", Size = Vector3.one, CFrame = CFrame.new(ctx.center), Transparency = 1 })
		for k = 1, 3 do
			local a = k * 2.1
			local p0 = Vector3.new(math.cos(a) * R * 0.55, R * 1.18, math.sin(a) * R * 0.55)
			local p1 = Vector3.new(math.cos(a + 1.6) * R * 0.55, R * 1.18, math.sin(a + 1.6) * R * 0.55)
			local a0 = Instance.new("Attachment")
			a0.Position = p0
			a0.Parent = anchor
			local a1 = Instance.new("Attachment")
			a1.Position = p1
			a1.Parent = anchor
			local b = Instance.new("Beam")
			b.Attachment0, b.Attachment1 = a0, a1
			b.Width0, b.Width1 = 14, 14
			b.CurveSize0, b.CurveSize1 = 30, -30
			b.Segments = 20
			b.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 255, 180)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 200, 255)), ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 120, 255)) })
			b.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.55), NumberSequenceKeypoint.new(0.7, 0.55), NumberSequenceKeypoint.new(1, 1) })
			b.LightEmission = 1
			b.Parent = anchor
		end
	end

	far.Parent = fxRoot
	return { near = near, far = far, grow = ctx.grow, pulse = ctx.pulse, emitters = ctx.emitters }
end

return PlanetDecorator
