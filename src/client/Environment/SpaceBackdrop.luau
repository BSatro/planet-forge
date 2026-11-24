--!strict
-- SpaceBackdrop — owner: Developer A. CLIENT-ONLY deep-space enhancement layer (never replicated).
--
-- BASE LAYER (not this module): Lighting uses Roblox's native night sky (ClockTime 20.5, Sky.StarCount
-- 5000, CelestialBodiesShown) which the engine renders on every device and quality level.
-- THIS MODULE adds, using engine-bundled textures only (rbxasset://, no asset permissions needed):
--   * ~70 translucent Neon glow balls in a camera-locked shell (1400 studs) (nebulae along a galactic band), 3 galaxies
--     (translucent discs + core), a soft glow at the key light (moon at night).
--   * Geometry lit by the key light: ringed, banded gas giant + 2 moons, a dark silhouette world,
--     a 70-rock asteroid belt. ~300 Parts total, CastShadow off, no collision/query/touch.
--   * Cosmic dust: one ParticleEmitter volume following the camera (~120 particles alive).
--   * Shooting stars: ONE reused trail object, one streak every 7-16 s.
--   * Parallax damping: the whole layer follows the camera at FOLLOW = 0.35.
-- History (ADR-019): a SurfaceGui sky-cube was tried first; the play client did not render far
-- SurfaceGuis, decals with bundled textures were not reliably visible either, so the layer is pure geometry. On low graphics quality the client may still cull
-- some far geometry; the native starry sky always remains.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)

local SpaceBackdrop = {}

local CENTER = WorldLayout.STATION_CENTER
local H = 2040 -- sky cube half-size
local BAND_NORMAL = Vector3.new(0.32, 0.86, 0.4).Unit -- galactic plane normal
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

local SMOKE = VisualStyle.Texture.Smoke
local SPARKLE = VisualStyle.Texture.Sparkle

local root: Folder? = nil
local dustPart: Part? = nil

-- Parallax damping: the whole backdrop (tiles + far geometry) follows the camera by FOLLOW of its
-- offset from the station, so the cube's flat faces read less. 0.35 keeps every planet inside the
-- cube from any reachable camera position (checked in World.spec numbers, see CHANGELOG).
local FOLLOW = 0.35
local followParts: { BasePart } = {}
local shellParts: { BasePart } = {} -- camera-locked (follow = 1)
local shellBase: { CFrame } = {}
local shellBuf: { CFrame } = {}
local followBase: { CFrame } = {}
local followBuf: { CFrame } = {}
local lastFollow = Vector3.new(math.huge, 0, 0)
local conns: { RBXScriptConnection } = {}

local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

local function bandFactor(dir: Vector3): number
	return math.clamp(1 - math.abs(dir.Unit:Dot(BAND_NORMAL)) * 1.6, 0, 1)
end

-- low contrast on purpose: per-tile gradients must not read as patches
local DEEP = Color3.fromRGB(5, 6, 18)
local INDIGO = Color3.fromRGB(10, 9, 28)
local PURPLE = Color3.fromRGB(15, 9, 32)

-- Seam-free: every tile uses the same base colour (tiles meeting at an edge must match exactly).
-- Colour variation comes only from nebula clouds, which never touch tile edges.
local function skyColor(_dir: Vector3): Color3
	return DEEP
end
local _ = { INDIGO, PURPLE, lerpColor }

local function newPart(parent: Instance, props: { [string]: any }): BasePart
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

local function randomOnBand(rng: Random): Vector3
	-- a direction close to the galactic plane (perpendicular to BAND_NORMAL)
	local a = rng:NextNumber(0, math.pi * 2)
	local e1 = BAND_NORMAL:Cross(Vector3.xAxis).Unit
	local e2 = BAND_NORMAL:Cross(e1).Unit
	local dir = e1 * math.cos(a) + e2 * math.sin(a) + BAND_NORMAL * rng:NextNumber(-0.25, 0.25)
	return dir.Unit
end

-- Sky shell radius. The play client stops drawing geometry somewhere between 1500 and ~2000 studs
-- (measured, ADR-019), so the shell is camera-locked at 1400 studs and always inside that range.
local NEBULA_DIST = 1400
local K = NEBULA_DIST / 2300 -- sizes were authored for 2300 studs

-- Nebulae are GEOMETRY (translucent Neon balls that bloom softly). Far SurfaceGuis and Decals were not
-- rendered reliably by the play client; far Parts are (ADR-019).
local function glowBall(parent: Instance, pos: Vector3, size: number, color: Color3, transparency: number)
	return newPart(parent, {
		Name = "Glow",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * size,
		CFrame = CFrame.new(pos),
		Material = Enum.Material.Neon,
		Color = color,
		Transparency = transparency,
	})
end

local function buildNebulae(parent: Folder, rng: Random)
	local m = Instance.new("Model")
	m.Name = "Nebulae"
	local palette = { VisualStyle.Color.Magenta, Color3.fromRGB(130, 80, 255), Color3.fromRGB(70, 110, 255), Color3.fromRGB(190, 70, 230) }
	for _ = 1, 12 do
		local dir = randomOnBand(rng)
		local core = CENTER + dir * (NEBULA_DIST + rng:NextNumber(-60, 60))
		local col = palette[rng:NextInteger(1, #palette)]
		local tangent = dir:Cross(BAND_NORMAL).Unit
		for k = 1, 5 do
			local off = (tangent * rng:NextNumber(-260, 260) + BAND_NORMAL * rng:NextNumber(-90, 90)) * K
			glowBall(m, core + off, rng:NextNumber(160, 420) * K * (if k == 1 then 1.5 else 1), col, rng:NextNumber(0.9, 0.95))
		end
	end
	-- galaxies: thin translucent discs + bright core
	for _, g in {
		{ dir = Vector3.new(0.7, 0.45, -0.55), tint = Color3.fromRGB(220, 180, 255), size = 180 * K, tilt = 0.5 },
		{ dir = Vector3.new(-0.5, 0.2, 0.84), tint = Color3.fromRGB(170, 200, 255), size = 140 * K, tilt = -0.7 },
		{ dir = Vector3.new(-0.2, -0.75, -0.62), tint = Color3.fromRGB(255, 190, 230), size = 160 * K, tilt = 1.1 },
	} do
		local pos = CENTER + g.dir.Unit * NEBULA_DIST
		local face = CFrame.lookAt(pos, CENTER) * CFrame.Angles(0, 0, g.tilt) * CFrame.Angles(1.2, 0, 0)
		newPart(m, { Name = "Galaxy", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1, g.size, g.size), CFrame = face * CFrame.Angles(0, math.pi / 2, 0), Material = Enum.Material.Neon, Color = g.tint, Transparency = 0.72 })
		newPart(m, { Name = "GalaxyHalo", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1, g.size * 1.7, g.size * 1.7), CFrame = face * CFrame.Angles(0, math.pi / 2, 0), Material = Enum.Material.Neon, Color = g.tint, Transparency = 0.9 })
		glowBall(m, pos, g.size * 0.16, Color3.new(1, 1, 1), 0.1)
	end
	-- soft glow around the key light (moon at night, sun by day)
	local okDir, keyDir = pcall(function()
		local sdir = Lighting:GetSunDirection()
		return if sdir.Y < 0 then Lighting:GetMoonDirection() else sdir
	end)
	if okDir and typeof(keyDir) == "Vector3" then
		glowBall(m, CENTER + keyDir * NEBULA_DIST, 380 * K, Color3.fromRGB(200, 205, 255), 0.94)
	end
	m.Parent = parent
end

local function buildGasGiant(parent: Folder)
	local m = Instance.new("Model")
	m.Name = "GasGiant"
	local G = CENTER + Vector3.new(-1150, 1000, -1250)
	local R = 380
	local tilt = CFrame.Angles(0.38, 0.4, -0.22)
	newPart(m, { Name = "Body", Shape = Enum.PartType.Ball, Size = Vector3.one * 2 * R, CFrame = CFrame.new(G), Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(116, 78, 158) })
	local bandColors = { Color3.fromRGB(150, 98, 182), Color3.fromRGB(88, 58, 138), Color3.fromRGB(196, 132, 172), Color3.fromRGB(72, 50, 120), Color3.fromRGB(170, 110, 190), Color3.fromRGB(110, 70, 160), Color3.fromRGB(205, 150, 190), Color3.fromRGB(96, 64, 150) }
	-- thin slabs, only between +-0.6R, radius = chord at slab centre -> ledges of a few studs, no "lid"
	for i, k in { -0.58, -0.4, -0.24, -0.08, 0.06, 0.2, 0.36, 0.52 } do
		local hgt = k * R
		local r = math.sqrt(R * R - hgt * hgt) + 0.3
		newPart(m, { Name = "Band", Shape = Enum.PartType.Cylinder, Size = Vector3.new(R * (0.035 + (i % 3) * 0.012), r * 2, r * 2), CFrame = CFrame.new(G) * tilt * CFrame.new(0, hgt, 0) * UPRIGHT, Material = Enum.Material.SmoothPlastic, Color = bandColors[i] })
	end
	newPart(m, { Name = "Haze", Shape = Enum.PartType.Ball, Size = Vector3.one * 2 * R * 1.05, CFrame = CFrame.new(G), Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(170, 130, 255), Transparency = 0.88 })
	for _, rd in { { r = 520, w = 70, c = Color3.fromRGB(205, 175, 225), t = 0.3 }, { r = 625, w = 95, c = Color3.fromRGB(150, 130, 205), t = 0.5 } } do
		local segs = 56
		for i = 1, segs do
			local a = (i / segs) * math.pi * 2
			newPart(m, {
				Name = "Ring",
				Size = Vector3.new(rd.w, 1.5, 2 * math.pi * rd.r / segs * 1.05),
				CFrame = CFrame.new(G) * tilt * CFrame.Angles(0, a, 0) * CFrame.new(rd.r, 0, 0),
				Material = Enum.Material.SmoothPlastic,
				Color = rd.c,
				Transparency = rd.t,
			})
		end
	end
	newPart(m, { Name = "Moon1", Shape = Enum.PartType.Ball, Size = Vector3.one * 84, CFrame = CFrame.new(G + Vector3.new(560, -220, 320)), Material = Enum.Material.Slate, Color = Color3.fromRGB(70, 66, 78) })
	newPart(m, { Name = "Moon2", Shape = Enum.PartType.Ball, Size = Vector3.one * 52, CFrame = CFrame.new(G + Vector3.new(-430, 250, 520)), Material = Enum.Material.Slate, Color = Color3.fromRGB(92, 84, 96) })
	m.Parent = parent
	return G, R
end

local function buildSilhouette(parent: Folder)
	newPart(parent, { Name = "DistantWorld", Shape = Enum.PartType.Ball, Size = Vector3.one * 400, CFrame = CFrame.new(CENTER + Vector3.new(1480, -640, 1430)), Material = Enum.Material.Slate, Color = Color3.fromRGB(36, 36, 58) })
end

local function buildAsteroids(parent: Folder, rng: Random, giant: Vector3, giantR: number)
	local m = Instance.new("Model")
	m.Name = "AsteroidBelt"
	local avoid = { { p = giant, r = giantR + 300 }, { p = CENTER + Vector3.new(1480, -640, 1430), r = 320 } }
	local placed = 0
	local tries = 0
	while placed < 70 and tries < 400 do
		tries += 1
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(1550, 1880)
		local pos = CENTER + Vector3.new(math.cos(a) * r, rng:NextNumber(-160, 160) + math.sin(a * 2) * 90, math.sin(a) * r)
		local ok = math.abs(pos.X - CENTER.X) < H - 60 and math.abs(pos.Z - CENTER.Z) < H - 60
		for _, av in avoid do
			if (pos - av.p).Magnitude < av.r then
				ok = false
			end
		end
		if ok then
			placed += 1
			local s = if rng:NextNumber() < 0.15 then rng:NextNumber(26, 44) else rng:NextNumber(6, 20)
			newPart(m, {
				Name = "Asteroid",
				Size = Vector3.new(s * rng:NextNumber(0.8, 1.4), s * rng:NextNumber(0.6, 1), s * rng:NextNumber(0.8, 1.3)),
				CFrame = CFrame.new(pos) * CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)),
				Material = Enum.Material.Basalt,
				Color = Color3.fromRGB(rng:NextInteger(62, 84), rng:NextInteger(58, 74), rng:NextInteger(64, 80)),
			})
		end
	end
	m.Parent = parent
end

local function buildDust(parent: Folder)
	local p = newPart(parent, { Name = "DustVolume", Size = Vector3.new(160, 90, 160), Transparency = 1 }) :: Part
	local e = Instance.new("ParticleEmitter")
	e.Texture = SPARKLE
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.Rate = 10
	e.Lifetime = NumberRange.new(9, 14)
	e.Speed = NumberRange.new(0.3, 1.2)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, 0.32), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new(0.35)
	e.Color = ColorSequence.new(Color3.fromRGB(190, 170, 255), Color3.fromRGB(140, 230, 255))
	e.LightEmission = 1
	e.LockedToPart = false
	e.Parent = p
	dustPart = p
end

local function startShootingStars(parent: Folder, rng: Random)
	local star = newPart(parent, { Name = "ShootingStar", Size = Vector3.one, Transparency = 1 }) :: Part
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 2.5, 0)
	a0.Parent = star
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -2.5, 0)
	a1.Parent = star
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.55
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(Color3.new(1, 1, 1), VisualStyle.Color.Cyan)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
	trail.Enabled = false
	trail.Parent = star
	task.spawn(function()
		while star.Parent do
			task.wait(rng:NextNumber(7, 16))
			if not star.Parent then
				break
			end
			local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0.1, 1), rng:NextNumber(-1, 1)).Unit
			local from = CENTER + dir * 1850
			local tangent = dir:Cross(Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))).Unit
			local to = from + tangent * rng:NextNumber(500, 900) - dir * 120
			trail.Enabled = false
			star.CFrame = CFrame.lookAt(from, to)
			task.wait()
			trail.Enabled = true
			local tw = TweenService:Create(star, TweenInfo.new(rng:NextNumber(0.9, 1.4), Enum.EasingStyle.Linear), { CFrame = CFrame.lookAt(to, to + (to - from)) })
			tw:Play()
			tw.Completed:Wait()
			trail.Enabled = false
		end
	end)
end

function SpaceBackdrop.build()
	if root then
		return
	end
	local fx = Workspace:FindFirstChild("PF_ClientFX") or Instance.new("Folder")
	fx.Name = "PF_ClientFX"
	fx.Parent = Workspace
	local r = Instance.new("Folder")
	r.Name = "Backdrop"
	root = r
	local rng = Random.new(424242)
	-- When the Sky carries the baked PLANET FORGE skybox (nebulae, galaxies, gas giant painted in), the
	-- client skips those geometry layers entirely. Set Lighting.PF_Sky:SetAttribute("PFBakedBackdrop", true).
	local sky = Lighting:FindFirstChild("PF_Sky")
	local baked = sky ~= nil and sky:GetAttribute("PFBakedBackdrop") == true
	-- (Planet Physics 3.0) ...and only when the baked faces can be shown at the current lighting (see SkyActivator)
	if baked then
		local okSA, SA = pcall(function()
			return require(script.Parent:WaitForChild("SkyActivator"))
		end)
		baked = okSA and SA.bakedUsable()
	end
	local g, gr = CENTER + Vector3.new(-1150, 1000, -1250), 380
	if not baked then
		buildNebulae(r, rng)
		g, gr = buildGasGiant(r)
		buildSilhouette(r)
	end
	buildAsteroids(r, rng, g, gr)
	buildDust(r)
	-- Shell = camera-locked layer, always within the client's render distance (ADR-019).
	-- The gas giant system and the silhouette world are pulled in to 70% of their authored distance.
	local SHELL_SCALE = 0.7
	for _, name in { "GasGiant", "DistantWorld" } do
		local obj = r:FindFirstChild(name)
		if obj then
			local parts = if obj:IsA("BasePart") then { obj } else obj:GetDescendants()
			for _, p in parts do
				if p:IsA("BasePart") then
					local rel = p.CFrame - CENTER
					p.Size = p.Size * SHELL_SCALE
					p.CFrame = rel.Rotation + CENTER + rel.Position * SHELL_SCALE
				end
			end
		end
	end
	local shellRoots = { r:FindFirstChild("Nebulae"), r:FindFirstChild("GasGiant"), r:FindFirstChild("DistantWorld") }
	local function inShell(x: Instance): boolean
		for _, root in shellRoots do
			if root and (x == root or x:IsDescendantOf(root)) then
				return true
			end
		end
		return false
	end
	for _, x in r:GetDescendants() do
		if x:IsA("BasePart") and x ~= dustPart and x.Name ~= "ShootingStar" then
			if inShell(x) then
				table.insert(shellParts, x)
				table.insert(shellBase, x.CFrame)
			else
				table.insert(followParts, x)
				table.insert(followBase, x.CFrame)
			end
		end
	end
	r.Parent = fx
	startShootingStars(r, rng)
	table.insert(conns, RunService.RenderStepped:Connect(function()
		local camPos = Workspace.CurrentCamera.CFrame.Position
		local d = dustPart
		if d then
			d.CFrame = CFrame.new(camPos)
		end
		local offset = (camPos - CENTER) * FOLLOW
		if (offset - lastFollow).Magnitude > 2 then
			lastFollow = offset
			for i, base in followBase do
				followBuf[i] = base + offset
			end
			Workspace:BulkMoveTo(followParts, followBuf, Enum.BulkMoveMode.FireCFrameChanged)
			local full = camPos - CENTER
			for i, base in shellBase do
				shellBuf[i] = base + full
			end
			Workspace:BulkMoveTo(shellParts, shellBuf, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end))
end

function SpaceBackdrop.destroy()
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
	if root then
		root:Destroy()
		root = nil
	end
	dustPart = nil
	table.clear(followParts)
	table.clear(followBase)
	table.clear(followBuf)
	table.clear(shellParts)
	table.clear(shellBase)
	table.clear(shellBuf)
	lastFollow = Vector3.new(math.huge, 0, 0)
end

function SpaceBackdrop.getRoot(): Folder?
	return root
end

return SpaceBackdrop
