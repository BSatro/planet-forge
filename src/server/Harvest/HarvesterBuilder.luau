--!strict
-- HarvesterBuilder — owner: Gameplay (Cosmic Core Hunt). Builds one Gravity Harvester for a planet slot.
--   Harvester_n (Model, Persistent streaming, attributes PFSlot / PFOwnerUserId / PFOwnerName)
--     Static/       foundation, trim, pylons, collector mast, console, beacon
--     Head (Model)  turret head; WorldPivot = HEAD_PIVOT. Clients rotate it locally (aim / idle sway).
--     Collector/    core + shell + ring (clients pulse/spin it locally)
--     Console.Pillar has the ProximityPrompt "PF_HarvestPrompt" (clients enable it for the owner only)
-- Only the foundation and console pillar collide. Everything is anchored, CanTouch = false.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local VisualStyle = require(Shared.Config.VisualStyle)
local HarvestConfig = require(Shared.Config.HarvestConfig)
local HarvestLayout = require(Shared.Harvest.HarvestLayout)

local HarvesterBuilder = {}

local C = VisualStyle.Color
local CYL_UP = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) -> up
local CYL_FWD = CFrame.Angles(0, math.pi / 2, 0) -- cylinder axis (X) -> forward (-Z object)

local function part(parent: Instance, name: string, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.Metal
	p.Color = C.Hull
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

-- Long block between two local points (long axis = Z).
local function strut(parent: Instance, name: string, L: any, a: Vector3, b: Vector3, w: number, h: number, props: { [string]: any }): Part
	local wa, wb = L.toWorld(a), L.toWorld(b)
	local p = part(parent, name, props)
	p.Size = Vector3.new(w, h, (wb - wa).Magnitude)
	p.CFrame = CFrame.lookAt((wa + wb) / 2, wb, L.base.UpVector)
	return p
end

local function light(parent: Instance, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
end

function HarvesterBuilder.build(slot: number): Model
	local L = HarvestLayout.forSlot(slot)
	local D = HarvestConfig.DEVICE
	local accent = VisualStyle.slotColor(slot)
	local function at(x: number, y: number, z: number): CFrame
		return HarvestLayout.localCFrame(L, Vector3.new(x, y, z))
	end

	local model = Instance.new("Model")
	model.Name = "Harvester_" .. slot
	model:SetAttribute("PFSlot", slot)
	model:SetAttribute("PFOwnerUserId", 0)
	model:SetAttribute("PFOwnerName", "")
	model:SetAttribute("PFKind", "GravityHarvester")

	local static = Instance.new("Folder")
	static.Name = "Static"
	static.Parent = model

	-- foundation ---------------------------------------------------------------------------------
	local foundation = part(static, "Foundation", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.6, 16, 16),
		CFrame = at(0, 0, 0) * CYL_UP,
		CanCollide = true,
		CanQuery = true,
		CastShadow = true,
		Color = C.Hull,
	})
	model.PrimaryPart = foundation
	part(static, "Trim", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.35, 16.7, 16.7),
		CFrame = at(0, 0.35, 0) * CYL_UP,
		Material = Enum.Material.Metal, -- coloured metal band (was a 17-stud neon disc: glare)
		Color = accent:Lerp(Color3.new(0, 0, 0), 0.35),
	})
	part(static, "Deck", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 11.5, 11.5),
		CFrame = at(0, 0.86, 0) * CYL_UP,
		Material = Enum.Material.DiamondPlate,
		Color = C.HullLight,
	})
	part(static, "DeckGlow", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.14, 12.3, 12.3),
		CFrame = at(0, 0.84, 0) * CYL_UP,
		Material = Enum.Material.Neon,
		Color = accent,
		Transparency = 0.72, -- a soft rim light under the deck, not a glowing floor
	})

	-- pylons (front, back-left, back-right), leaning in towards the turret ---------------------------
	for i, deg in { 90, 215, 325 } do
		local a = math.rad(deg)
		local dx, dz = math.cos(a), math.sin(a)
		local bottom = Vector3.new(dx * 6, 0.6, dz * 6)
		local top = Vector3.new(dx * 2.6, 5.4, dz * 2.6)
		strut(static, "Pylon" .. i, L, bottom, top, 1.3, 1.0, { Color = C.HullLight, CastShadow = true })
		local outward = Vector3.new(dx, 0, dz) * 0.55
		strut(static, "PylonGlow" .. i, L, bottom + outward + Vector3.new(0, 0.4, 0), top + outward, 0.3, 0.25, {
			Material = Enum.Material.Neon,
			Color = accent,
		})
	end

	-- turret hub (static ring the head sits on) ------------------------------------------------------
	part(static, "Hub", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.4, 5.6, 5.6),
		CFrame = at(0, 5.4, 0) * CYL_UP,
		Color = C.HullLight,
		CastShadow = true,
	})
	part(static, "HubRing", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.35, 6.2, 6.2),
		CFrame = at(0, 5.4, 0) * CYL_UP,
		Material = Enum.Material.Neon,
		Color = accent,
	})

	-- rotating head ----------------------------------------------------------------------------------
	local head = Instance.new("Model")
	head.Name = "Head"
	local pivot = at(D.HEAD_PIVOT.X, D.HEAD_PIVOT.Y, D.HEAD_PIVOT.Z)
	local function h(x: number, y: number, z: number): CFrame
		return pivot * CFrame.new(x, y, -z) -- head-local, z forward
	end
	local housing = part(head, "Housing", { Size = Vector3.new(3.2, 2.4, 4.4), CFrame = h(0, 0, -0.6), Color = C.Hull, CastShadow = true })
	part(head, "HousingTop", { Size = Vector3.new(2.5, 0.5, 3.4), CFrame = h(0, 1.35, -0.5), Color = C.HullLight })
	part(head, "Vent", { Size = Vector3.new(1.4, 0.15, 2.2), CFrame = h(0, 1.62, -0.6), Material = Enum.Material.Neon, Color = accent })
	for _, sx in { -1, 1 } do
		part(head, "Fin", { Size = Vector3.new(0.3, 1.8, 4.0), CFrame = h(sx * 1.75, 0, -0.4), Color = C.Panel })
		part(head, "FinGlow", { Size = Vector3.new(0.12, 0.35, 3.2), CFrame = h(sx * 1.92, 0.25, -0.4), Material = Enum.Material.Neon, Color = accent })
	end
	part(head, "Barrel", { Shape = Enum.PartType.Cylinder, Size = Vector3.new(7.2, 1.4, 1.4), CFrame = h(0, 0, 4.4) * CYL_FWD, Color = C.HullLight, CastShadow = true })
	for i, z in { 2.4, 4.2, 6.0 } do
		part(head, "CoilRing" .. i, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.35, 2.3 - i * 0.12, 2.3 - i * 0.12),
			CFrame = h(0, 0, z) * CYL_FWD,
			Material = Enum.Material.Neon,
			Color = accent,
		})
	end
	part(head, "Emitter", { Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.9, 2.2, 2.2), CFrame = h(0, 0, 7.6) * CYL_FWD, Color = C.Hull })
	local crystal = part(head, "MuzzleCrystal", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 1.3,
		CFrame = h(0, 0, 8.2),
		Material = Enum.Material.Neon,
		Color = C.Cyan,
	})
	light(crystal, C.Cyan, 10, 1.6)
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.CFrame = crystal.CFrame:ToObjectSpace(h(0, 0, 8.8))
	muzzle.Parent = crystal
	head.PrimaryPart = housing
	head.WorldPivot = pivot
	head.Parent = model

	-- collector -------------------------------------------------------------------------------------
	local collector = Instance.new("Folder")
	collector.Name = "Collector"
	collector.Parent = model
	local cpos = D.COLLECTOR
	strut(static, "Mast", L, Vector3.new(0, 5.2, -1.8), cpos + Vector3.new(0, -0.6, 0.9), 0.8, 0.8, { Color = C.HullLight })
	local core = part(collector, "Core", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 2,
		CFrame = at(cpos.X, cpos.Y, cpos.Z),
		Material = Enum.Material.Neon,
		Color = accent,
	})
	light(core, accent, 14, 2)
	local ca = Instance.new("Attachment")
	ca.Name = "CollectorAttachment"
	ca.Parent = core
	part(collector, "Shell", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 3.3,
		CFrame = at(cpos.X, cpos.Y, cpos.Z),
		Material = Enum.Material.ForceField,
		Color = accent,
		Transparency = 0.1,
	})
	local ring = Instance.new("Model")
	ring.Name = "Ring"
	local ringCenter = at(cpos.X, cpos.Y, cpos.Z)
	local SEG = 14
	for i = 1, SEG do
		local a = (i / SEG) * math.pi * 2
		local off = Vector3.new(math.cos(a), math.sin(a), 0) * 3.1 -- ring in the right/up plane, facing forward
		local seg = part(ring, "Seg" .. i, {
			Size = Vector3.new(0.4, 0.4, 1.35),
			Material = if i % 2 == 0 then Enum.Material.Neon else Enum.Material.Metal,
			Color = if i % 2 == 0 then accent else C.Panel,
		})
		seg.CFrame = ringCenter * CFrame.new(off) * CFrame.Angles(0, 0, a + math.pi / 2) * CFrame.Angles(0, math.pi / 2, 0)
	end
	ring.WorldPivot = ringCenter
	ring.Parent = collector

	-- console + prompt -------------------------------------------------------------------------------
	local con = D.CONSOLE
	local pillar = part(static, "ConsolePillar", {
		Size = Vector3.new(1.5, 3.8, 1.1),
		CFrame = at(con.X, 1.3, con.Z),
		Color = C.HullLight,
		CanCollide = true,
		CanQuery = true,
		CastShadow = true,
	})
	local panel = part(static, "ConsoleScreen", {
		Size = Vector3.new(3.0, 0.22, 1.9),
		CFrame = at(con.X, 3.25, con.Z - 0.25) * CFrame.Angles(math.rad(32), 0, 0),
		Material = Enum.Material.Glass,
		Color = C.Glass,
		Transparency = 0.05,
	})
	local sg = Instance.new("SurfaceGui")
	sg.Name = "Screen"
	sg.Face = Enum.NormalId.Top
	sg.LightInfluence = 0
	sg.Brightness = 2
	sg.PixelsPerStud = 60
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.5)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = accent
	title.Text = "GRAVITY HARVESTER"
	title.Parent = sg
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromScale(0, 0.5)
	status.Size = UDim2.fromScale(1, 0.4)
	status.Font = Enum.Font.GothamMedium
	status.TextScaled = true
	status.TextColor3 = C.Text
	status.Text = string.format("PLANET %02d  •  STANDBY", slot)
	status.Parent = sg
	sg.Parent = panel
	part(static, "OperatorPad", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.12, 3.6, 3.6),
		CFrame = at(D.OPERATOR.X, 0.86, D.OPERATOR.Z) * CYL_UP,
		Material = Enum.Material.Neon,
		Color = accent,
		Transparency = 0.35,
	})
	local promptAtt = Instance.new("Attachment")
	promptAtt.Name = "PromptAttachment"
	promptAtt.Position = Vector3.new(0, 2.2, 0)
	promptAtt.Parent = pillar
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PF_HarvestPrompt"
	prompt.ActionText = "Operate"
	prompt.ObjectText = "Gravity Harvester"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = HarvestConfig.OPERATE.PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false -- clients enable it locally for the owner
	prompt.Parent = promptAtt

	-- beacon + label ----------------------------------------------------------------------------------
	local bh = D.BEACON_HEIGHT
	local beacon = part(static, "Beacon", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(bh, 1.4, 1.4),
		CFrame = at(cpos.X, cpos.Y + 2 + bh / 2, cpos.Z) * CYL_UP,
		Material = Enum.Material.Neon,
		Color = accent,
		Transparency = 0.78, -- guidance beam: readable from orbit without cutting the sky in half
	})
	beacon:SetAttribute("PFBeacon", true)
	local labelAnchor = part(static, "LabelAnchor", {
		Size = Vector3.one * 0.2,
		CFrame = at(0, 22, 0),
		Transparency = 1,
	})
	local bb = Instance.new("BillboardGui")
	bb.Name = "HarvesterLabel"
	bb.Size = UDim2.fromOffset(220, 52)
	bb.LightInfluence = 0
	bb.MaxDistance = 260
	bb.AlwaysOnTop = false
	local t1 = Instance.new("TextLabel")
	t1.Name = "Title"
	t1.BackgroundTransparency = 1
	t1.Size = UDim2.fromScale(1, 0.55)
	t1.Font = Enum.Font.GothamBlack
	t1.TextScaled = true
	t1.TextColor3 = accent
	t1.TextStrokeTransparency = 0.4
	t1.Text = "GRAVITY HARVESTER"
	t1.Parent = bb
	local t2 = Instance.new("TextLabel")
	t2.Name = "Owner"
	t2.BackgroundTransparency = 1
	t2.Position = UDim2.fromScale(0, 0.55)
	t2.Size = UDim2.fromScale(1, 0.45)
	t2.Font = Enum.Font.GothamMedium
	t2.TextScaled = true
	t2.TextColor3 = C.Text
	t2.TextStrokeTransparency = 0.5
	t2.Text = "Unclaimed"
	t2.Parent = bb
	bb.Parent = labelAnchor

	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	return model
end

return HarvesterBuilder
