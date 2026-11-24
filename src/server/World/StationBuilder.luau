--!strict
-- StationBuilder — owner: Developer A. Builds THE FORGE, the central hub, from primitives only
-- (no toolbox assets). Deterministic; ~550 parts; ModelStreamingMode Persistent so the hub is always
-- visible. Animated pieces (reactor rings, hologram planets, lab globe, meteor sample) are tagged with
-- the attribute PFSpin = <rad/s> and spun on the CLIENT (StationFX), never on the server.
--
-- Layout (angles measured like WorldLayout slots: 0 deg = +X, counter-clockwise towards +Z):
--   centre      : fusion reactor
--   r 20..64    : 8 floor guide lines (one per dock, slot colour)
--   r ~56       : districts at 22.5 (Planet Lab), 112.5 (Meteor Terminal), 157.5 (Hologram),
--                 202.5 (Rift Portal), 292.5 (Cosmetic Shop); directory pylons at 67.5/247.5/337.5
--   r 80..116   : 8 docking sectors at the slot angles, warp pad at r = 106
--   below deck  : stepped hull with neon bands and fins (silhouette)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)

local C = VisualStyle.Color
local StationBuilder = {}

local CENTER = WorldLayout.STATION_CENTER
local TOP = WorldLayout.getDeckTop()
local PLAZA_R = WorldLayout.STATION_DECK_SIZE.X / 2
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- turns a Cylinder's X axis to world Y

----------------------------------------------------------------------------------------------------
-- primitives

local function part(parent: Instance, props: { [string]: any }): BasePart
	local cls = props.ClassName or "Part"
	local p = Instance.new(cls) :: BasePart
	p.Anchored = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.Metal
	for k, v in props do
		if k ~= "ClassName" then
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- decorative: no collision, not hit by the ground probe, no shadows
local function deco(parent: Instance, props: { [string]: any }): BasePart
	props.CanCollide = false
	props.CanQuery = false
	if props.CastShadow == nil then
		props.CastShadow = false
	end
	return part(parent, props)
end

local function neon(parent: Instance, props: { [string]: any }): BasePart
	props.Material = Enum.Material.Neon
	return deco(parent, props)
end

-- vertical disc (Cylinder) centred at `pos`
local function disc(parent: Instance, pos: Vector3, diameter: number, thickness: number, props: { [string]: any }, solid: boolean?): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(thickness, diameter, diameter)
	props.CFrame = CFrame.new(pos) * UPRIGHT
	if solid then
		return part(parent, props)
	end
	return deco(parent, props)
end

local function model(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- ring of tangent blocks around `cf`'s Y axis (cf defines centre + ring plane = local XZ)
local function ring(parent: Instance, cf: CFrame, radius: number, count: number, segSize: Vector3, props: { [string]: any }, solid: boolean?)
	for i = 1, count do
		local a = (i / count) * math.pi * 2
		local p = table.clone(props)
		p.Size = Vector3.new(segSize.X, segSize.Y, 2 * math.pi * radius / count * 1.04)
		p.CFrame = cf * CFrame.Angles(0, a, 0) * CFrame.new(radius, 0, 0)
		if solid then
			part(parent, p)
		else
			deco(parent, p)
		end
	end
end

local function polar(r: number, angleDeg: number, y: number): Vector3
	local a = math.rad(angleDeg)
	return Vector3.new(CENTER.X + math.cos(a) * r, y, CENTER.Z + math.sin(a) * r)
end

-- CFrame at polar position whose LookVector points at the reactor (front faces the plaza centre)
local function facingCenter(r: number, angleDeg: number, y: number): CFrame
	local pos = polar(r, angleDeg, y)
	return CFrame.lookAt(pos, Vector3.new(CENTER.X, y, CENTER.Z))
end

local function sign(p: BasePart, face: Enum.NormalId, title: string, subtitle: string?, accent: Color3, ppsOverride: number?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = face
	gui.LightInfluence = 0
	gui.Brightness = 1.6
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppsOverride or 32
	gui.MaxDistance = 320
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(10, 12, 24)
	bg.BackgroundTransparency = 0.15
	bg.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = accent
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = bg
	local t = Instance.new("TextLabel")
	t.Name = "Title"
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(0.92, if subtitle then 0.58 else 0.8)
	t.Position = UDim2.fromScale(0.04, if subtitle then 0.06 else 0.1)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = accent
	t.Text = title
	t.Parent = bg
	if subtitle then
		local s = Instance.new("TextLabel")
		s.Name = "Subtitle"
		s.BackgroundTransparency = 1
		s.Size = UDim2.fromScale(0.92, 0.3)
		s.Position = UDim2.fromScale(0.04, 0.64)
		s.Font = Enum.Font.GothamMedium
		s.TextScaled = true
		s.TextColor3 = C.Text
		s.Text = subtitle
		s.Parent = bg
	end
	gui.Parent = p
end

local function light(parent: BasePart, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
end

local function sparkles(parent: BasePart, color: Color3, rate: number, speed: number, size: number)
	local e = Instance.new("ParticleEmitter")
	e.Texture = VisualStyle.Texture.Sparkle
	e.Color = ColorSequence.new(color)
	e.LightEmission = 1
	e.Rate = rate
	e.Lifetime = NumberRange.new(1.2, 2.2)
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.SpreadAngle = Vector2.new(12, 12)
	e.Parent = parent
	return e
end

----------------------------------------------------------------------------------------------------
-- sections

local function buildPlaza(root: Model)
	local m = model(root, "Plaza")
	local deck = disc(m, CENTER, PLAZA_R * 2, WorldLayout.STATION_DECK_SIZE.Y, { Name = "Deck", Color = C.Deck, Material = Enum.Material.Metal }, true)
	deck.CanQuery = true
	-- glowing edge band around the deck rim
	disc(m, CENTER + Vector3.new(0, 1.2, 0), PLAZA_R * 2 + 1.2, 1.2, { Name = "RimBand", Color = C.Violet, Material = Enum.Material.Neon })
	-- inner inlay with a 1-stud cyan ring (neon disc underneath a slightly smaller inlay disc)
	disc(m, Vector3.new(CENTER.X, TOP + 0.08, CENTER.Z), 132, 0.16, { Name = "InlayRing", Color = C.Cyan, Material = Enum.Material.Neon })
	disc(m, Vector3.new(CENTER.X, TOP + 0.12, CENTER.Z), 130, 0.2, { Name = "Inlay", Color = Color3.fromRGB(46, 52, 72), Material = Enum.Material.SmoothPlastic })
	disc(m, Vector3.new(CENTER.X, TOP + 0.2, CENTER.Z), 36, 0.16, { Name = "ReactorRing", Color = C.Violet, Material = Enum.Material.Neon })
	disc(m, Vector3.new(CENTER.X, TOP + 0.24, CENTER.Z), 34, 0.2, { Name = "ReactorInlay", Color = C.HullLight, Material = Enum.Material.Metal })

	-- floor guide lines: reactor -> each dock, in that slot's colour
	for slot = 1, WorldLayout.SLOT_COUNT do
		local a = (slot - 1) * 360 / WorldLayout.SLOT_COUNT
		local mid = polar(52, a, TOP + 0.3)
		neon(m, {
			Name = "Guide_" .. slot,
			Size = Vector3.new(0.12, 0.6, 64),
			CFrame = CFrame.lookAt(mid, polar(100, a, TOP + 0.3)),
			Color = VisualStyle.slotColor(slot),
			Transparency = 0.15,
		})
	end

	-- perimeter railing (glass + neon cap), open where docks attach
	local rail = model(m, "Railing")
	local segs = 72
	for i = 1, segs do
		local aDeg = (i - 0.5) * 360 / segs
		local nearDock = false
		for slot = 1, WorldLayout.SLOT_COUNT do
			local d = math.abs(((aDeg - (slot - 1) * 45) + 180) % 360 - 180)
			if d < 7 then
				nearDock = true
			end
		end
		if not nearDock then
			local len = 2 * math.pi * (PLAZA_R - 0.8) / segs * 1.02
			local cf = CFrame.lookAt(polar(PLAZA_R - 0.8, aDeg, TOP + 1.4), Vector3.new(CENTER.X, TOP + 1.4, CENTER.Z))
			part(rail, { Name = "Glass", Size = Vector3.new(len, 2.8, 0.4), CFrame = cf, Material = Enum.Material.Glass, Color = C.Glass, Transparency = 0.55, CastShadow = false, CanQuery = false })
			neon(rail, { Name = "Cap", Size = Vector3.new(len, 0.25, 0.5), CFrame = cf * CFrame.new(0, 1.5, 0), Color = C.Cyan })
		end
	end

	-- spawn pad (the SpawnLocation is required by LoadCharacter; CharacterService places precisely)
	local spawnCf = WorldLayout.getStationSpawn()
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PF_StationSpawn"
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.CanTouch = false
	spawn.Size = Vector3.new(7, 0.3, 7)
	spawn.CFrame = CFrame.new(spawnCf.Position.X, TOP + 0.3, spawnCf.Position.Z)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = C.HullLight
	spawn.Transparency = 1 -- only the neon ring marks the spawn
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = m
	disc(m, Vector3.new(spawnCf.Position.X, TOP + 0.28, spawnCf.Position.Z), 9, 0.12, { Name = "SpawnRing", Color = C.Cyan, Material = Enum.Material.Glass, Transparency = 0.3 })
end

local function buildReactor(root: Model)
	local m = model(root, "Reactor")
	local base = disc(m, Vector3.new(CENTER.X, TOP + 2, CENTER.Z), 26, 4, { Name = "Pedestal", Color = C.Hull }, true)
	base.CanQuery = true
	disc(m, Vector3.new(CENTER.X, TOP + 2.4, CENTER.Z), 26.8, 0.6, { Name = "PedestalBand", Color = C.Violet, Material = Enum.Material.Neon })
	disc(m, Vector3.new(CENTER.X, TOP + 6, CENTER.Z), 18, 4, { Name = "Tier", Color = C.HullLight }, true)
	part(m, { Name = "Column", Shape = Enum.PartType.Cylinder, Size = Vector3.new(40, 7, 7), CFrame = CFrame.new(CENTER.X, TOP + 28, CENTER.Z) * UPRIGHT, Material = Enum.Material.Glass, Color = C.Violet, Transparency = 0.45, CastShadow = false })
	local corePos = Vector3.new(CENTER.X, TOP + 28, CENTER.Z)
	local core = neon(m, { Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * 16, CFrame = CFrame.new(corePos), Color = C.Reactor })
	light(core, C.Reactor, 60, 3)
	deco(m, { Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * 22, CFrame = CFrame.new(corePos), Material = Enum.Material.ForceField, Color = Color3.fromRGB(205, 150, 255) })

	-- containment rings (client spins them via PFSpin)
	local ringDefs = {
		{ r = 14.5, tilt = CFrame.Angles(math.rad(18), 0, 0), color = C.Cyan, spin = 0.6 },
		{ r = 17, tilt = CFrame.Angles(0, 0, math.rad(-24)), color = C.Violet, spin = -0.45 },
		{ r = 19.5, tilt = CFrame.Angles(math.rad(-10), 0, math.rad(12)), color = C.Magenta, spin = 0.3 },
	}
	for i, d in ringDefs do
		local rm = model(m, "Ring" .. i)
		ring(rm, CFrame.new(corePos) * d.tilt, d.r, 26, Vector3.new(1.1, 0.7, 0), { Material = Enum.Material.Neon, Color = d.color })
		rm:SetAttribute("PFSpin", d.spin)
		rm:SetAttribute("PFSpinAxis", (CFrame.new() * d.tilt).UpVector)
	end

	-- cage pylons + top cap + spire
	for k = 0, 3 do
		local a = 45 + k * 90
		local p = part(m, { Name = "Pylon", Size = Vector3.new(1.6, 42, 1.6), CFrame = CFrame.new(polar(10.5, a, TOP + 29)), Color = C.HullLight })
		neon(m, { Name = "PylonStrip", Size = Vector3.new(0.3, 38, 0.3), CFrame = p.CFrame * CFrame.new(0, 0, 0) * CFrame.new((CENTER - p.Position).Unit * 0.9), Color = C.Cyan })
		-- energy beam from pylon to core
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, -4, 0)
		a0.Parent = p
		local a1 = Instance.new("Attachment")
		a1.Parent = core
		local b = Instance.new("Beam")
		b.Attachment0, b.Attachment1 = a0, a1
		b.Color = ColorSequence.new(C.Violet, C.Magenta)
		b.LightEmission = 1
		b.Width0, b.Width1 = 0.4, 1.4
		b.Transparency = NumberSequence.new(0.35)
		b.FaceCamera = true
		b.Parent = p
	end
	disc(m, Vector3.new(CENTER.X, TOP + 51, CENTER.Z), 26, 2.4, { Name = "Cap", Color = C.Hull }, true)
	disc(m, Vector3.new(CENTER.X, TOP + 51, CENTER.Z), 26.8, 0.5, { Name = "CapBand", Color = C.Cyan, Material = Enum.Material.Neon })
	part(m, { Name = "Spire", Shape = Enum.PartType.Cylinder, Size = Vector3.new(26, 1.4, 1.4), CFrame = CFrame.new(CENTER.X, TOP + 65, CENTER.Z) * UPRIGHT, Color = C.HullLight })
	neon(m, { Name = "SpireTip", Shape = Enum.PartType.Ball, Size = Vector3.one * 3, CFrame = CFrame.new(CENTER.X, TOP + 78.5, CENTER.Z), Color = C.Cyan })
end

local function buildHull(root: Model)
	local m = model(root, "Hull")
	local tiers = {
		{ d = 150, h = 8, y = -7, band = C.Cyan },
		{ d = 118, h = 12, y = -17, band = C.Violet },
		{ d = 80, h = 16, y = -31, band = C.Cyan },
		{ d = 44, h = 22, y = -50, band = C.Violet },
	}
	for i, t in tiers do
		local p = disc(m, CENTER + Vector3.new(0, t.y, 0), t.d, t.h, { Name = "Tier" .. i, Color = if i % 2 == 1 then C.Hull else C.HullLight }, true)
		p.CanQuery = false
		disc(m, CENTER + Vector3.new(0, t.y, 0), t.d + 1, 1, { Name = "Band" .. i, Color = t.band, Material = Enum.Material.Neon })
	end
	local tip = neon(m, { Name = "Exhaust", Shape = Enum.PartType.Ball, Size = Vector3.one * 20, CFrame = CFrame.new(CENTER + Vector3.new(0, -62, 0)), Color = C.Reactor })
	light(tip, C.Reactor, 50, 2)
	-- fins between the docks
	for k = 0, 7 do
		local a = 22.5 + k * 45
		local pos = polar(62, a, CENTER.Y - 20)
		local cf = CFrame.lookAt(pos, Vector3.new(CENTER.X, pos.Y, CENTER.Z))
		part(m, { ClassName = "WedgePart", Name = "Fin", Size = Vector3.new(2, 28, 44), CFrame = cf * CFrame.Angles(0, math.pi, 0) * CFrame.Angles(math.pi, 0, 0), Color = C.HullLight, CanQuery = false })
		neon(m, { Name = "FinLight", Size = Vector3.new(0.4, 0.4, 30), CFrame = cf * CFrame.new(0, -12, 0) * CFrame.Angles(math.rad(-18), 0, 0), Color = C.Violet })
	end
end

local function buildDock(root: Instance, slot: number)
	local m = model(root, "Dock_" .. slot)
	m:SetAttribute("PFSlot", slot)
	local color = VisualStyle.slotColor(slot)
	local a = math.deg(WorldLayout.getSlotAngle(slot))
	local base = CFrame.lookAt(Vector3.new(CENTER.X, TOP, CENTER.Z), polar(10, a, TOP)) -- LookVector = outward
	local function at(r: number, x: number, y: number): CFrame
		return base * CFrame.new(x, y, -r)
	end
	local bridge = part(m, { Name = "Bridge", Size = Vector3.new(16, 6, 38), CFrame = at(97, 0, -3), Color = C.Deck })
	bridge.CanQuery = true
	for _, x in { -7.7, 7.7 } do
		neon(m, { Name = "EdgeLight", Size = Vector3.new(0.4, 0.3, 36), CFrame = at(98, x, 0.15), Color = color })
		part(m, { Name = "Rail", Size = Vector3.new(0.4, 2.8, 30), CFrame = at(99, x * 1.06, 1.4), Material = Enum.Material.Glass, Color = C.Glass, Transparency = 0.55, CastShadow = false, CanQuery = false })
		neon(m, { Name = "RailCap", Size = Vector3.new(0.5, 0.25, 30), CFrame = at(99, x * 1.06, 2.9), Color = C.Cyan })
		part(m, { Name = "GatePillar", Size = Vector3.new(2, 16, 2), CFrame = at(113, x * 0.92, 8), Color = C.HullLight, CanQuery = false })
		neon(m, { Name = "GatePillarLight", Size = Vector3.new(0.4, 14, 0.4), CFrame = at(113, x * 0.92 - math.sign(x) * 1.1, 8), Color = color })
	end
	local beam = part(m, { Name = "GateBeam", Size = Vector3.new(17, 3.2, 2.2), CFrame = at(113, 0, 17.4), Color = C.Hull, CanQuery = false })
	sign(beam, Enum.NormalId.Back, string.format("PLANET %02d", slot), "UNCLAIMED", color, 24)
	neon(m, { Name = "GateBeamLight", Size = Vector3.new(15, 0.3, 0.3), CFrame = at(112, 0, 15.6), Color = color })
	local padPos = WorldLayout.getStationPadPosition(slot)
	local pad = disc(m, padPos + Vector3.new(0, 0.12, 0), 10, 0.2, { Name = "WarpPad", Color = color, Material = Enum.Material.Neon, Transparency = 0.3 })
	pad:SetAttribute("PFWarpTarget", slot)
	disc(m, padPos + Vector3.new(0, 0.08, 0), 11.5, 0.12, { Name = "WarpPadRing", Color = C.Text, Material = Enum.Material.Neon, Transparency = 0.3 })
	sparkles(pad :: BasePart, color, 5, 6, 0.8)
end

local function districtFloor(m: Model, cf: CFrame, diameter: number, accent: Color3)
	local f = disc(m, cf.Position + Vector3.new(0, 0.3 - (cf.Position.Y - TOP), 0), diameter, 0.6, { Name = "Floor", Color = C.Panel, Material = Enum.Material.SmoothPlastic }, true)
	f.CanQuery = true
	disc(m, Vector3.new(cf.Position.X, TOP + 0.25, cf.Position.Z), diameter + 0.8, 0.4, { Name = "FloorRing", Color = accent, Material = Enum.Material.Neon })
end

local function signPost(m: Model, cf: CFrame, title: string, subtitle: string, accent: Color3)
	local board = part(m, { Name = "SignBoard", Size = Vector3.new(13, 3.2, 0.5), CFrame = cf, Color = C.Hull, CanQuery = false })
	sign(board, Enum.NormalId.Front, title, subtitle, accent)
	for _, x in { -5.5, 5.5 } do
		part(m, { Name = "SignLeg", Size = Vector3.new(0.5, cf.Position.Y - TOP, 0.5), CFrame = cf * CFrame.new(x, -(cf.Position.Y - TOP) / 2 - 1.6, 0.4), Color = C.HullLight, CanQuery = false })
	end
end

local function buildPlanetLab(root: Instance)
	local m = model(root, "PlanetLab")
	local cf = facingCenter(58, 22.5, TOP)
	districtFloor(m, cf, 26, C.Cyan)
	part(m, { Name = "Dome", Shape = Enum.PartType.Ball, Size = Vector3.one * 22, CFrame = cf, Material = Enum.Material.Glass, Color = C.Glass, Transparency = 0.6, CastShadow = false })
	for k = 0, 5 do
		local ribCf = cf * CFrame.Angles(0, k * math.pi / 6, 0)
		ring(m, ribCf * CFrame.Angles(0, 0, math.pi / 2), 11.1, 14, Vector3.new(0.35, 0.35, 0), { Material = Enum.Material.Neon, Color = C.Cyan, Transparency = 0.2 })
	end
	disc(m, cf.Position + Vector3.new(0, 1.8, 0), 5, 3, { Name = "Pedestal", Color = C.Hull }, true)
	local globe = model(m, "Globe")
	part(globe, { Name = "Planet", Shape = Enum.PartType.Ball, Size = Vector3.one * 6, CFrame = cf + Vector3.new(0, 7, 0), Material = Enum.Material.Rock, Color = C.RockBase, CanQuery = false })
	ring(globe, (cf + Vector3.new(0, 7, 0)) * CFrame.Angles(math.rad(20), 0, 0), 4.6, 18, Vector3.new(0.25, 0.25, 0), { Material = Enum.Material.Neon, Color = C.Cyan })
	globe:SetAttribute("PFSpin", 0.35)
	globe:SetAttribute("PFSpinAxis", Vector3.yAxis)
	light(m:FindFirstChild("Pedestal") :: BasePart, C.Cyan, 26, 1.6)
	signPost(m, cf * CFrame.new(0, 4.6, -14), "DNA LAB", "Evolve your planet · open the DNA LAB from your HUD", C.Cyan)
end

local function buildMeteorTerminal(root: Instance)
	local m = model(root, "MeteorTerminal")
	local cf = facingCenter(58, 112.5, TOP)
	districtFloor(m, cf, 24, Color3.fromRGB(255, 160, 70))
	-- containment frame
	local frameCf = cf * CFrame.new(0, 0, 3)
	for _, o in { Vector3.new(-4, 0, -4), Vector3.new(4, 0, -4), Vector3.new(-4, 0, 4), Vector3.new(4, 0, 4) } do
		part(m, { Name = "FramePost", Size = Vector3.new(0.9, 12, 0.9), CFrame = frameCf * CFrame.new(o + Vector3.new(0, 6.6, 0)), Color = C.HullLight })
		neon(m, { Name = "FrameLight", Size = Vector3.new(0.25, 10, 0.25), CFrame = frameCf * CFrame.new(o * 0.9 + Vector3.new(0, 6.6, 0)), Color = Color3.fromRGB(255, 160, 70) })
	end
	part(m, { Name = "FrameTop", Size = Vector3.new(9.8, 0.8, 9.8), CFrame = frameCf * CFrame.new(0, 12.6, 0), Color = C.Hull, CanQuery = false })
	local sample = model(m, "MeteorSample")
	local mc = frameCf * CFrame.new(0, 6.5, 0)
	for i, s in { Vector3.new(4, 3.4, 3.6), Vector3.new(3, 3, 3.2), Vector3.new(2.6, 2.4, 2.8), Vector3.new(2.2, 2, 2.4) } do
		local off = CFrame.Angles(i * 0.9, i * 1.7, i * 0.6) * CFrame.new(i * 0.25, 0, -i * 0.2)
		part(sample, { Name = "Rock", Size = s, CFrame = mc * off, Material = Enum.Material.Basalt, Color = Color3.fromRGB(58, 52, 50), CanCollide = false, CanQuery = false })
	end
	neon(sample, { Name = "Vein", Size = Vector3.new(0.25, 3.6, 0.25), CFrame = mc * CFrame.Angles(0.4, 0, 0.7), Color = Color3.fromRGB(255, 150, 60) })
	neon(sample, { Name = "Vein", Size = Vector3.new(0.25, 3, 0.25), CFrame = mc * CFrame.Angles(-0.6, 0.8, 0.2) * CFrame.new(0.6, 0, 0), Color = C.Cyan })
	sample:SetAttribute("PFSpin", 0.25)
	sample:SetAttribute("PFSpinAxis", Vector3.new(0.2, 1, 0.1).Unit)
	-- consoles
	for _, x in { -6.5, 6.5 } do
		local desk = part(m, { Name = "Console", Size = Vector3.new(4.5, 3.2, 2.4), CFrame = cf * CFrame.new(x, 1.9, -6.5) * CFrame.Angles(0, math.rad(x > 0 and 20 or -20), 0), Color = C.HullLight })
		neon(m, { Name = "Screen", Size = Vector3.new(3.8, 0.12, 1.8), CFrame = desk.CFrame * CFrame.new(0, 1.65, 0) * CFrame.Angles(math.rad(-20), 0, 0), Color = C.Cyan, Transparency = 0.2 })
	end
	light(m:FindFirstChild("FrameTop") :: BasePart, Color3.fromRGB(255, 170, 90), 24, 1.6)
	signPost(m, cf * CFrame.new(0, 4.6, -12.5), "METEOR RESEARCH", "Sample analysis terminal", Color3.fromRGB(255, 170, 80))
end

local function buildHologram(root: Instance)
	local m = model(root, "PlanetHologram")
	local cf = facingCenter(56, 157.5, TOP)
	disc(m, cf.Position + Vector3.new(0, 0.9, 0), 13, 1.8, { Name = "Projector", Color = C.Hull }, true)
	disc(m, cf.Position + Vector3.new(0, 1.85, 0), 9, 0.15, { Name = "Emitter", Color = C.Cyan, Material = Enum.Material.Neon })
	local holoCenter = cf.Position + Vector3.new(0, 10, 0)
	local star = neon(m, { Name = "HoloStar", Shape = Enum.PartType.Ball, Size = Vector3.one * 2.6, CFrame = CFrame.new(holoCenter), Color = C.Reactor })
	light(star, C.Cyan, 22, 1.4)
	-- projection cone (beam)
	local a0 = Instance.new("Attachment")
	a0.Parent = m:FindFirstChild("Emitter") :: BasePart
	local a1 = Instance.new("Attachment")
	a1.Parent = star
	local b = Instance.new("Beam")
	b.Attachment0, b.Attachment1 = a0, a1
	b.Width0, b.Width1 = 8, 16
	b.Color = ColorSequence.new(C.Cyan)
	b.LightEmission = 1
	b.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.75), NumberSequenceKeypoint.new(1, 0.97) })
	b.FaceCamera = true
	b.Parent = star
	local orbit = model(m, "HoloPlanets")
	ring(orbit, CFrame.new(holoCenter), 6, 28, Vector3.new(0.12, 0.12, 0), { Material = Enum.Material.Neon, Color = C.Cyan, Transparency = 0.5 })
	for slot = 1, WorldLayout.SLOT_COUNT do
		local ang = WorldLayout.getSlotAngle(slot)
		local p = deco(orbit, { Name = "Holo_" .. slot, Shape = Enum.PartType.Ball, Size = Vector3.one * 1.6, CFrame = CFrame.new(holoCenter + Vector3.new(math.cos(ang) * 6, 0, math.sin(ang) * 6)), Material = Enum.Material.ForceField, Color = VisualStyle.slotColor(slot) })
		p:SetAttribute("PFSlot", slot)
	end
	orbit:SetAttribute("PFSpin", 0.12)
	orbit:SetAttribute("PFSpinAxis", Vector3.yAxis)
	signPost(m, cf * CFrame.new(0, 4.6, -10), "PLANET NETWORK", "Live map of the 8 worlds", C.Cyan)
end

local function buildRiftPortal(root: Instance)
	local m = model(root, "RiftPortal")
	local cf = facingCenter(58, 202.5, TOP)
	disc(m, cf.Position + Vector3.new(0, 0.5, 0), 24, 1, { Name = "Step1", Color = C.Panel, Material = Enum.Material.SmoothPlastic }, true).CanQuery = true
	disc(m, cf.Position + Vector3.new(0, 1.5, 0), 17, 1, { Name = "Step2", Color = C.Hull }, true).CanQuery = true
	disc(m, cf.Position + Vector3.new(0, 1.06, 0), 24.8, 0.3, { Name = "StepRing", Color = C.Magenta, Material = Enum.Material.Neon })
	local ringCf = (cf + Vector3.new(0, 12.5, 0)) * CFrame.Angles(math.pi / 2, 0, 0) -- ring plane faces the plaza
	ring(m, ringCf, 9, 30, Vector3.new(1.6, 1.6, 0), { Material = Enum.Material.Neon, Color = C.Violet })
	ring(m, ringCf, 10.6, 30, Vector3.new(1.4, 2.4, 0), { Color = C.Hull }, true)
	-- animated energy membrane (ForceField shimmer) instead of a flat neon disc
	local surface = deco(m, { Name = "RiftSurface", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 17, 17), CFrame = (cf + Vector3.new(0, 12.5, 0)) * CFrame.Angles(0, math.pi / 2, 0), Color = C.Magenta, Material = Enum.Material.ForceField, Transparency = 0 })
	local e = sparkles(surface, C.Magenta, 14, 2, 1.4)
	e.Shape = Enum.ParticleEmitterShape.Disc
	e.RotSpeed = NumberRange.new(-90, 90)
	light(surface, C.Magenta, 30, 2)
	for _, x in { -11.5, 11.5 } do
		part(m, { Name = "Support", Size = Vector3.new(2, 14, 3), CFrame = cf * CFrame.new(x, 7.8, 0), Color = C.HullLight })
	end
	signPost(m, cf * CFrame.new(0, 4.6, -13.5), "COSMIC RIFT", "The Fractured Nebula · 1–8 explorers", C.Magenta)
end

local function buildShop(root: Instance)
	local m = model(root, "CosmeticShop")
	local cf = facingCenter(58, 292.5, TOP)
	districtFloor(m, cf, 24, C.Violet)
	for k = -2, 2 do
		local wcf = cf * CFrame.Angles(0, math.rad(k * 26), 0) * CFrame.new(0, 4.6, 10.5)
		part(m, { Name = "BackWall", Size = Vector3.new(5, 8.6, 0.6), CFrame = wcf, Material = Enum.Material.Glass, Color = Color3.fromRGB(150, 110, 255), Transparency = 0.35, CastShadow = false })
	end
	for _, k in { -2, 0, 2 } do
		part(m, { Name = "CanopyPost", Size = Vector3.new(0.7, 9, 0.7), CFrame = cf * CFrame.Angles(0, math.rad(k * 26), 0) * CFrame.new(0, 4.8, 10.9), Color = C.HullLight, CanQuery = false })
	end
	disc(m, cf.Position + Vector3.new(0, 9.5, 0), 25, 0.8, { Name = "Canopy", Color = C.Hull }, true).CanQuery = false
	disc(m, cf.Position + Vector3.new(0, 9.5, 0), 25.8, 0.3, { Name = "CanopyRim", Color = C.Violet, Material = Enum.Material.Neon })
	for i, x in { -6, 0, 6 } do
		local pc = cf * CFrame.new(x, 0, 3)
		disc(m, pc.Position + Vector3.new(0, 1.5, 0), 3, 3, { Name = "Display", Color = C.HullLight }, true)
		disc(m, pc.Position + Vector3.new(0, 3.05, 0), 3.2, 0.12, { Name = "DisplayGlow", Color = C.Violet, Material = Enum.Material.Neon })
		local item = model(m, "Showcase" .. i)
		deco(item, { Name = "Placeholder", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.8, CFrame = pc + Vector3.new(0, 4.8, 0), Material = Enum.Material.ForceField, Color = VisualStyle.slotColor(i * 2) })
		ring(item, (pc + Vector3.new(0, 4.8, 0)) * CFrame.Angles(0.4, 0, 0), 1.6, 12, Vector3.new(0.12, 0.12, 0), { Material = Enum.Material.Neon, Color = C.Violet })
		item:SetAttribute("PFSpin", 0.8)
		item:SetAttribute("PFSpinAxis", Vector3.yAxis)
	end
	light(m:FindFirstChild("Canopy") :: BasePart, C.Violet, 24, 1.4)
	signPost(m, cf * CFrame.new(0, 4.6, -12.5), "COSMETICS", "Store opening soon", C.Violet)
end

local function buildDirectory(root: Instance)
	local m = model(root, "Directory")
	for _, a in { 67.5, 247.5, 337.5 } do
		local cf = facingCenter(46, a, TOP + 5.2)
		local board = part(m, { Name = "Pylon", Size = Vector3.new(4.6, 10, 0.8), CFrame = cf, Color = C.Hull, CanQuery = false })
		sign(board, Enum.NormalId.Front, "THE FORGE", "Docks 1-8 · follow the coloured floor lines", C.Cyan, 28)
		sign(board, Enum.NormalId.Back, "THE FORGE", "Docks 1-8 · follow the coloured floor lines", C.Cyan, 28)
		neon(m, { Name = "PylonEdge", Size = Vector3.new(4.8, 0.25, 1), CFrame = cf * CFrame.new(0, 5.1, 0), Color = C.Violet })
	end
end

----------------------------------------------------------------------------------------------------

function StationBuilder.build(): Model
	local root = Instance.new("Model")
	root.Name = "Station"
	root:SetAttribute("PFName", "THE FORGE")
	buildPlaza(root)
	buildReactor(root)
	buildHull(root)
	local docks = model(root, "Docks")
	for slot = 1, WorldLayout.SLOT_COUNT do
		buildDock(docks, slot)
	end
	local districts = model(root, "Districts")
	buildPlanetLab(districts)
	buildMeteorTerminal(districts)
	buildHologram(districts)
	buildRiftPortal(districts)
	buildShop(districts)
	buildDirectory(districts)
	root.PrimaryPart = (root:FindFirstChild("Plaza") :: Model):FindFirstChild("Deck") :: BasePart
	root.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	return root
end

return StationBuilder
