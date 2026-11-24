--!strict
-- RiftBuilder — owner: Mission Systems (prototype art; production art by Developer A).
-- Builds THE FRACTURED NEBULA from a RiftLayout at an arena origin. Only stepping stones, islands and the
-- chamber floor collide; everything decorative is non-colliding and non-queryable.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RiftConfig = require(ReplicatedStorage.PF_Shared.Rift.RiftConfig)

local RiftBuilder = {}

local COL = {
	rock = Color3.fromRGB(72, 60, 104),
	rockHi = Color3.fromRGB(98, 82, 140),
	rockLo = Color3.fromRGB(46, 38, 72),
	cyan = Color3.fromRGB(86, 222, 255),
	violet = Color3.fromRGB(150, 90, 255),
	magenta = Color3.fromRGB(255, 92, 206),
	amber = Color3.fromRGB(255, 176, 84),
	dim = Color3.fromRGB(70, 56, 120),
}
RiftBuilder.COLORS = COL

local function part(parent: Instance, props: { [string]: any }): BasePart
	local p = Instance.new(props.Shape and "Part" or (props.Class or "Part"))
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = false
	for k, v in props do
		if k ~= "Class" then
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function solid(p: BasePart): BasePart
	p.CanCollide = true
	p.CanQuery = true
	p.CastShadow = true
	return p
end

local UP = CFrame.Angles(0, 0, math.pi / 2) -- cylinders: axis X -> Y

local function disc(parent: Instance, cf: CFrame, dia: number, h: number, props: { [string]: any }): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(h, dia, dia)
	props.CFrame = cf * UP
	return part(parent, props)
end

local function emitter(parent: BasePart, color: Color3, rate: number, size: number, life: number, speed: number?): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(color)
	e.LightEmission = 1
	e.Rate = rate
	e.Lifetime = NumberRange.new(life * 0.6, life)
	e.Speed = NumberRange.new((speed or 2) * 0.5, speed or 2)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, size), NumberSequenceKeypoint.new(1, 0) })
	e.SpreadAngle = Vector2.new(180, 180)
	e.Parent = parent
	return e
end

local function portal(parent: Instance, cf: CFrame, color: Color3, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	local segs = 20
	local ringParts = {}
	for i = 1, segs do
		local a = i / segs * math.pi * 2
		local seg = part(m, { Name = "Ring", Size = Vector3.new(1.4, 2.6, 1), CFrame = cf * CFrame.Angles(0, 0, a) * CFrame.new(0, 7, 0), Material = Enum.Material.Neon, Color = if i % 2 == 0 then color else COL.violet })
		table.insert(ringParts, seg)
	end
	local surf = part(m, { Name = "Surface", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 13, 13), CFrame = cf * CFrame.Angles(0, math.pi / 2, 0), Material = Enum.Material.Neon, Color = color, Transparency = 0.55 })
	local e = emitter(surf, color, 18, 1.4, 1.6, 3)
	e.Shape = Enum.ParticleEmitterShape.Disc
	e.EmissionDirection = Enum.NormalId.Front
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 26
	light.Brightness = 2
	light.Parent = surf
	m.Parent = parent
	m:SetAttribute("spin", 0.6)
	return m
end

local function asteroidStone(parent: Instance, origin: Vector3, s: any, index: number): BasePart
	local cf = CFrame.new(origin + s.pos) * CFrame.Angles(0, s.yaw, 0)
	local top = solid(part(parent, { Name = "Stone_" .. index, Size = s.size, CFrame = cf, Material = Enum.Material.Slate, Color = COL.rock:Lerp(COL.rockHi, (index % 5) / 6) }))
	-- shattered underside (decor)
	for k = 1, 2 do
		local w = s.size.X * (0.7 - k * 0.18)
		part(parent, { Name = "Shard", Size = Vector3.new(w, s.size.Y * 1.6, w * 0.8), CFrame = cf * CFrame.new((k - 1.5) * 1.5, -s.size.Y * (0.9 + k * 0.5), 0) * CFrame.Angles(0.35 * k, 0.6 * k, 0.25), Material = Enum.Material.Slate, Color = COL.rockLo })
	end
	if s.hazard == "crumble" then
		top.Material = Enum.Material.CrackedLava
		top.Color = Color3.fromRGB(110, 80, 120)
		top.CanTouch = true
		local edge = part(parent, { Name = "CrumbleGlow", Size = Vector3.new(s.size.X + 0.2, 0.25, s.size.Z + 0.2), CFrame = cf * CFrame.new(0, s.size.Y / 2 + 0.05, 0), Material = Enum.Material.Neon, Color = COL.amber, Transparency = 0.6 })
		top:SetAttribute("glow", edge:GetFullName())
		edge.Name = "CrumbleGlow_" .. index
	end
	return top
end

-- returns handles used by RiftService (all world-space)
function RiftBuilder.build(layout: any, origin: Vector3, parent: Instance, name: string): any
	local root = Instance.new("Folder")
	root.Name = name
	local geo = Instance.new("Folder")
	geo.Name = "Geometry"
	geo.Parent = root
	local deco = Instance.new("Folder")
	deco.Name = "Decor"
	deco.Parent = root
	local h: any = { folder = root, stones = {}, crumble = {}, sweepers = {}, fragments = {}, nodes = {}, spinners = {}, relayPads = {}, checkpoints = {} }

	-- entry platform + arrival portal
	local entryCf = CFrame.new(origin + layout.entry)
	solid(disc(geo, entryCf, 44, 4, { Name = "EntryPlatform", Material = Enum.Material.Slate, Color = COL.rockHi }))
	disc(geo, entryCf * CFrame.new(0, 2.05, 0), 45, 0.3, { Name = "EntryRing", Material = Enum.Material.Neon, Color = COL.cyan, Transparency = 0.2 })
	local entryPortal = portal(deco, entryCf * CFrame.new(0, 10, -17), COL.cyan, "ArrivalPortal")
	table.insert(h.spinners, entryPortal)
	h.checkpoints[0] = entryCf * CFrame.new(0, 5, 4)

	-- stones
	for i, s in layout.stones do
		local top = asteroidStone(geo, origin, s, i)
		h.stones[i] = top
		if s.hazard == "crumble" then
			table.insert(h.crumble, { part = top, glow = geo:FindFirstChild("CrumbleGlow_" .. i), size = s.size })
		elseif s.hazard == "sweeper" then
			local beamLen = math.max(s.size.X, s.size.Z) * 0.95
			local center = origin + s.pos + Vector3.new(0, s.size.Y / 2 + 1.5, 0)
			local beam = part(geo, { Name = "Sweeper_" .. i, Size = Vector3.new(beamLen, 0.7, 0.7), CFrame = CFrame.new(center), Material = Enum.Material.Neon, Color = COL.magenta, CanTouch = true })
			part(geo, { Name = "SweeperHub_" .. i, Shape = Enum.PartType.Ball, Size = Vector3.one * 1.6, CFrame = CFrame.new(center), Material = Enum.Material.Neon, Color = COL.violet })
			table.insert(h.sweepers, { part = beam, center = center, speed = s.sweepSpeed or 2, angle = (i * 0.7) % 6.28, active = true })
		end
	end
	for i, s in layout.prismStones or {} do
		asteroidStone(geo, origin, s, 1000 + i)
	end

	-- node islands
	for i, n in layout.nodes do
		local cf = CFrame.new(origin + n.pos)
		local island = solid(disc(geo, cf, 32, 5, { Name = "NodeIsland_" .. i, Material = Enum.Material.Slate, Color = COL.rock }))
		part(geo, { Name = "NodeUnder_" .. i, Size = Vector3.new(20, 14, 18), CFrame = cf * CFrame.new(0, -9, 0) * CFrame.Angles(0.3, 0.8, 0.2), Material = Enum.Material.Slate, Color = COL.rockLo })
		local ring = disc(geo, cf * CFrame.new(0, 2.6, 0), RiftConfig.NODE.radius * 2, 0.25, { Name = "NodeRing_" .. i, Material = Enum.Material.Neon, Color = COL.dim, Transparency = 0.3 })
		local core = part(geo, { Name = "NodeCrystal_" .. i, Size = Vector3.new(3, 12, 3), CFrame = cf * CFrame.new(0, 8.5, 0) * CFrame.Angles(0, math.rad(45), 0), Material = Enum.Material.Neon, Color = COL.dim })
		local cap = part(geo, { Name = "NodeCap_" .. i, Size = Vector3.new(4.2, 4.2, 4.2), CFrame = cf * CFrame.new(0, 16, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45)), Material = Enum.Material.Glass, Color = COL.violet, Transparency = 0.3 })
		local light = Instance.new("PointLight")
		light.Color = COL.violet
		light.Range = 22
		light.Brightness = 1
		light.Parent = core
		local att0 = Instance.new("Attachment")
		att0.Position = Vector3.new(0, 6, 0)
		att0.Parent = core
		h.nodes[i] = { island = island, ring = ring, crystal = core, cap = cap, light = light, att = att0, center = origin + n.pos }
		h.checkpoints[i] = cf * CFrame.new(0, 6, -6)
		local _ = island
	end

	-- stabilization chamber
	local chCf = CFrame.new(origin + layout.chamber)
	solid(disc(geo, chCf, 54, 5, { Name = "ChamberFloor", Material = Enum.Material.Slate, Color = COL.rockHi }))
	disc(geo, chCf * CFrame.new(0, 2.6, 0), RiftConfig.FINAL.radius * 2, 0.25, { Name = "ChamberRing", Material = Enum.Material.Neon, Color = COL.violet, Transparency = 0.25 })
	disc(geo, chCf * CFrame.new(0, 2.6, 0), 12, 0.3, { Name = "ChamberInner", Material = Enum.Material.Neon, Color = COL.cyan, Transparency = 0.4 })
	part(geo, { Name = "ChamberUnder", Size = Vector3.new(34, 24, 30), CFrame = chCf * CFrame.new(0, -15, 0) * CFrame.Angles(0.2, 0.5, 0.15), Material = Enum.Material.Slate, Color = COL.rockLo })
	local coreBall = part(geo, { Name = "RiftCore", Shape = Enum.PartType.Ball, Size = Vector3.one * 9, CFrame = chCf * CFrame.new(0, 17, 0), Material = Enum.Material.Neon, Color = COL.magenta, Transparency = 0.15 })
	emitter(coreBall, COL.magenta, 20, 2, 2, 6)
	local coreLight = Instance.new("PointLight")
	coreLight.Color = COL.magenta
	coreLight.Range = 40
	coreLight.Brightness = 2
	coreLight.Parent = coreBall
	local coreAtt = Instance.new("Attachment")
	coreAtt.Parent = coreBall
	-- orbiting arcs (spun by RiftService)
	local arcs = Instance.new("Model")
	arcs.Name = "CoreArcs"
	for k = 1, 3 do
		for s = 1, 10 do
			local a = s / 14 * math.pi * 2
			part(arcs, { Name = "Arc", Size = Vector3.new(0.8, 0.8, 3.4), CFrame = chCf * CFrame.new(0, 17, 0) * CFrame.Angles(k * 1.05, 0, 0) * CFrame.Angles(0, a, 0) * CFrame.new(10, 0, 0), Material = Enum.Material.Neon, Color = if k == 2 then COL.cyan else COL.violet })
		end
	end
	arcs.Parent = deco
	arcs:SetAttribute("spin", 0.35)
	table.insert(h.spinners, arcs)
	-- three pylons (one per node) that light up as nodes stabilize
	h.pylons = {}
	for k = 1, 3 do
		local a = k / 3 * math.pi * 2
		local pcf = chCf * CFrame.new(math.cos(a) * 22, 9, math.sin(a) * 22)
		local py = part(geo, { Name = "Pylon_" .. k, Size = Vector3.new(2.4, 14, 2.4), CFrame = pcf, Material = Enum.Material.Neon, Color = COL.dim })
		local att = Instance.new("Attachment")
		att.Position = Vector3.new(0, 7, 0)
		att.Parent = py
		h.pylons[k] = { part = py, att = att }
	end
	-- final-phase sweepers (inactive until the core channel starts)
	for k = 1, 2 do
		local center = origin + layout.chamber + Vector3.new(0, 4.1, 0)
		local beam = part(geo, { Name = "ChamberSweeper_" .. k, Size = Vector3.new(RiftConfig.FINAL.radius * 2 - 6, 0.7, 0.7), CFrame = CFrame.new(center), Material = Enum.Material.Neon, Color = COL.magenta, Transparency = 1 })
		table.insert(h.sweepers, { part = beam, center = center, speed = if k == 1 then 1.1 else -0.8, angle = k * 1.6, active = false, final = true })
	end
	h.chamber = { core = coreBall, coreAtt = coreAtt, center = origin + layout.chamber, cf = chCf }
	h.checkpoints[4] = chCf * CFrame.new(0, 6, -16)
	-- exit portal (hidden until escape)
	local exit = portal(deco, chCf * CFrame.new(0, 10, 0), COL.cyan, "ExitPortal")
	for _, p in exit:GetDescendants() do
		if p:IsA("BasePart") then
			p:SetAttribute("t0", p.Transparency)
			p.Transparency = 1
		elseif p:IsA("ParticleEmitter") or p:IsA("Light") then
			(p :: any).Enabled = false
		end
	end
	h.exit = exit
	table.insert(h.spinners, exit)

	-- fragments
	for _, f in layout.fragments do
		local p = part(geo, { Name = "Fragment_" .. f.id, Size = Vector3.new(1.6, 2.4, 1.6), CFrame = CFrame.new(origin + f.pos) * CFrame.Angles(0, math.rad(45), math.rad(12)), Material = Enum.Material.Neon, Color = COL.cyan, CanTouch = true })
		p:SetAttribute("fragmentId", f.id)
		emitter(p, COL.cyan, 3, 0.6, 1.2, 1)
		h.fragments[f.id] = p
	end
	-- hidden prism
	if layout.prism then
		local p = part(geo, { Name = "NebulaPrism", Class = "WedgePart", Size = Vector3.new(2.4, 3.4, 2.4), CFrame = CFrame.new(origin + layout.prism) * CFrame.Angles(0, 0.7, 0), Material = Enum.Material.Neon, Color = COL.amber, CanTouch = true })
		emitter(p, COL.amber, 8, 0.9, 1.5, 2)
		h.prism = p
	end
	-- resonance pads
	for k, pos in layout.relayPads or {} do
		local pad = disc(geo, CFrame.new(origin + pos), RiftConfig.RELAY.radius * 2, 0.4, { Name = "RelayPad_" .. k, Material = Enum.Material.Neon, Color = COL.amber, Transparency = 0.35 })
		h.relayPads[k] = { part = pad, center = origin + pos }
	end

	-- decoration: shattered asteroid shell, energy crystals, nebula mist
	for i, rk in layout.rocks do
		part(deco, { Name = "Asteroid", Size = rk.size, CFrame = CFrame.new(origin + rk.pos) * CFrame.Angles(rk.rot.X, rk.rot.Y, rk.rot.Z), Material = if i % 3 == 0 then Enum.Material.Basalt else Enum.Material.Slate, Color = COL.rockLo:Lerp(COL.rock, (i % 4) / 4) })
	end
	for i, c in layout.crystals do
		local cf = CFrame.new(origin + c.pos) * CFrame.Angles(0.2 * ((i % 3) - 1), i, 0.15)
		part(deco, { Name = "EnergySpire", Size = Vector3.new(3, c.height, 3), CFrame = cf * CFrame.Angles(0, math.rad(45), 0), Material = Enum.Material.Neon, Color = if i % 2 == 0 then COL.violet else COL.cyan, Transparency = 0.15 })
		part(deco, { Name = "SpireBase", Size = Vector3.new(9, 6, 8), CFrame = cf * CFrame.new(0, -c.height / 2, 0) * CFrame.Angles(0.4, 0.3, 0.2), Material = Enum.Material.Slate, Color = COL.rockLo })
	end
	for k = 1, 5 do
		local a = k / 5 * math.pi * 2
		local anchor = part(deco, { Name = "Mist", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(origin + Vector3.new(math.cos(a) * 170, -40 + k * 12, math.sin(a) * 170)) })
		local e = Instance.new("ParticleEmitter")
		e.Texture = "rbxasset://textures/particles/smoke_main.dds"
		e.Color = ColorSequence.new(if k % 2 == 0 then Color3.fromRGB(120, 70, 220) else Color3.fromRGB(60, 90, 220))
		e.LightEmission = 0.6
		e.Rate = 0.8
		e.Lifetime = NumberRange.new(14, 20)
		e.Speed = NumberRange.new(1, 3)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 40), NumberSequenceKeypoint.new(1, 90) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.86), NumberSequenceKeypoint.new(1, 1) })
		e.SpreadAngle = Vector2.new(180, 180)
		e.RotSpeed = NumberRange.new(-10, 10)
		e.Parent = anchor
	end
	root.Parent = parent
	return h
end

return RiftBuilder
