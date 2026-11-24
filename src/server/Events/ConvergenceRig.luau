--!strict
-- ConvergenceRig — owner: Live Gameplay (prototype art; Developer A may replace the models, see INTERFACES §9).
-- Builds the temporary Cosmic Convergence props on THE FORGE plaza, all inside ONE folder so cleanup is a single
-- Destroy: 4 stabilizer conduits around the reactor (hold prompts, beams to the core), flux-cell spawn spots on the
-- plaza rim, the reactor intake prompt and a stage glow around the reactor core. Station parts are never modified.
-- Asset overrides: ReplicatedStorage.PF_Assets.Events.Conduit / .FluxCell (Models with a PrimaryPart; parts with
-- attribute PFStateColor=true are recoloured by state).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)

local CV = EventConfig.CONVERGENCE
local PAL = EventConfig.FX.palette
local ConvergenceRig = {}

local STABLE = PAL.convergence
local UNSTABLE = PAL.unstable
local METAL = Color3.fromRGB(38, 44, 62)
local STAGE_COLORS = { [0] = Color3.fromRGB(255, 120, 70), Color3.fromRGB(255, 190, 90), Color3.fromRGB(170, 230, 160), Color3.fromRGB(120, 230, 255) }

local function part(props: { [string]: any }): BasePart
	local p = Instance.new(props.ClassName or "Part") :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		if k ~= "ClassName" then
			(p :: any)[k] = v
		end
	end
	return p
end

local function template(name: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("PF_Assets")
	local ev = assets and assets:FindFirstChild("Events")
	local t = ev and ev:FindFirstChild(name)
	if t and t:IsA("Model") and t.PrimaryPart then
		return t
	end
	return nil
end

local function recolor(model: Instance, color: Color3)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("PFStateColor") then
			d.Color = color
		elseif d:IsA("PointLight") then
			d.Color = color
		end
	end
end

local function prompt(parent: Instance, action: string, object: string, hold: number, dist: number, enabled: boolean): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = hold
	pp.MaxActivationDistance = dist
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.Enabled = enabled
	pp.Parent = parent
	return pp
end

local function buildConduit(folder: Instance, i: number, pos: Vector3, coreAtt: Attachment): any
	local tpl = template("Conduit")
	local model: Model
	local main: BasePart
	if tpl then
		model = tpl:Clone()
		model:PivotTo(CFrame.new(pos))
		main = model.PrimaryPart :: BasePart
	else
		model = Instance.new("Model")
		local base = part({ Name = "Base", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.2, 5, 5), CFrame = CFrame.new(pos + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90)), Material = Enum.Material.Metal, Color = METAL, CanCollide = true, Parent = model })
		local column = part({ Name = "Column", Size = Vector3.new(1.3, 5.6, 1.3), CFrame = CFrame.new(pos + Vector3.new(0, 4, 0)), Material = Enum.Material.Neon, Color = STABLE, Parent = model })
		column:SetAttribute("PFStateColor", true)
		local ring = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.35, 3.6, 3.6), CFrame = CFrame.new(pos + Vector3.new(0, 3.2, 0)) * CFrame.Angles(0, 0, math.rad(90)), Material = Enum.Material.Neon, Color = STABLE, Transparency = 0.25, Parent = model })
		ring:SetAttribute("PFStateColor", true)
		local cap = part({ Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.new(2.2, 2.2, 2.2), CFrame = CFrame.new(pos + Vector3.new(0, 7.4, 0)), Material = Enum.Material.Glass, Color = STABLE, Transparency = 0.15, Parent = model })
		cap:SetAttribute("PFStateColor", true)
		local light = Instance.new("PointLight")
		light.Range = 12
		light.Brightness = 1.6
		light.Color = STABLE
		light.Parent = cap
		model.PrimaryPart = base
		main = column
		local _ = base
	end
	model.Name = "Conduit_" .. i
	local top = Instance.new("Attachment")
	top.Name = "BeamFrom"
	top.WorldPosition = pos + Vector3.new(0, 7.4, 0)
	top.Parent = main
	local beam = Instance.new("Beam")
	beam.Name = "CoreBeam"
	beam.Attachment0 = top
	beam.Attachment1 = coreAtt
	beam.Color = ColorSequence.new(STABLE)
	beam.LightEmission = 1
	beam.Width0 = 0.5
	beam.Width1 = 1.2
	beam.FaceCamera = true
	beam.Transparency = NumberSequence.new(0.35)
	beam.Segments = 6
	beam.Enabled = true
	beam.Parent = main
	local pp = prompt(main, "Stabilize", "Stabilizer Conduit", CV.holdTime, CV.promptDistance, false)
	pp.Name = "PF_ConduitPrompt"
	model:SetAttribute("PFConduit", i)
	model:SetAttribute("PFState", "stable")
	model.Parent = folder
	return { model = model, main = main, prompt = pp, beam = beam, pos = pos, state = "stable", stableUntil = 0, stabilizedAt = -math.huge, stabilizedBy = 0, unstableAt = nil :: number? }
end

-- Free spots for flux cells on the plaza rim (overlap-checked against existing station geometry).
local function findSpots(center: Vector3, deckY: number, exclude: { Instance }): { Vector3 }
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local out = {}
	for k = 0, 23 do
		local a = math.rad(k * 15 + 7.5)
		local pos = Vector3.new(center.X + math.cos(a) * CV.flux.radius, deckY, center.Z + math.sin(a) * CV.flux.radius)
		local hits = Workspace:GetPartBoundsInBox(CFrame.new(pos + Vector3.new(0, 3.5, 0)), Vector3.new(7, 6, 7), params)
		local blocked = false
		for _, h in hits do
			if h.CanCollide or h.Transparency < 0.9 then
				blocked = true
				break
			end
		end
		if not blocked then
			table.insert(out, pos)
		end
	end
	-- keep a spread-out subset (every other free spot, at most 8)
	local spread = {}
	for i = 1, #out, 2 do
		if #spread < 8 then
			table.insert(spread, out[i])
		end
	end
	if #spread == 0 then
		for k = 0, 3 do
			local a = math.rad(k * 90 + 45)
			table.insert(spread, Vector3.new(center.X + math.cos(a) * 40, deckY, center.Z + math.sin(a) * 40))
		end
	end
	return spread
end

function ConvergenceRig.build(parent: Instance): any
	local center = WorldLayout.STATION_CENTER
	local deckY = WorldLayout.getDeckTop()
	local folder = Instance.new("Folder")
	folder.Name = "PF_Convergence"
	-- reactor glow + core attachment
	local world = Workspace:FindFirstChild("PF_World")
	local station = world and world:FindFirstChild("Station")
	local reactor = station and station:FindFirstChild("Reactor")
	local core = reactor and reactor:FindFirstChild("Core") :: BasePart?
	local corePos = if core then core.Position else center + Vector3.new(0, 31, 0)
	local glow = part({ Name = "ReactorGlow", Shape = Enum.PartType.Ball, Size = Vector3.new(25, 25, 25), CFrame = CFrame.new(corePos), Material = Enum.Material.ForceField, Color = STAGE_COLORS[0], Transparency = 0.2, Parent = folder })
	local glowLight = Instance.new("PointLight")
	glowLight.Range = 46
	glowLight.Brightness = 2
	glowLight.Color = STAGE_COLORS[0]
	glowLight.Parent = glow
	local coreAtt = Instance.new("Attachment")
	coreAtt.Name = "CoreAttachment"
	coreAtt.Parent = glow
	-- conduits
	local conduits = {}
	for i = 1, CV.conduits do
		local a = math.rad(45 + (i - 1) * (360 / CV.conduits))
		local pos = Vector3.new(center.X + math.cos(a) * CV.conduitRadius, deckY, center.Z + math.sin(a) * CV.conduitRadius)
		conduits[i] = buildConduit(folder, i, pos, coreAtt)
	end
	-- intake (centre prompt, reachable from anywhere around the reactor pedestal)
	local intake = part({ Name = "Intake", Size = Vector3.new(2, 2, 2), CFrame = CFrame.new(center.X, deckY + 5, center.Z), Transparency = 1, Parent = folder })
	local intakePrompt = prompt(intake, "Inject flux cell", "Reactor Intake", CV.flux.injectTime, CV.flux.intakeDistance, true)
	intakePrompt.Name = "PF_IntakePrompt"
	intakePrompt:SetAttribute("PFCarrierOnly", true) -- clients hide it unless their player carries a cell
	local exclude: { Instance } = { folder }
	if station then
		local plaza = station:FindFirstChild("Plaza")
		if plaza then
			for _, c in plaza:GetChildren() do
				if c.Name ~= "Railing" then
					table.insert(exclude, c)
				end
			end
		end
	end
	local spots = findSpots(center, deckY, exclude)
	folder.Parent = parent
	return { folder = folder, conduits = conduits, spots = spots, cells = {} :: { any }, intake = intake, intakePrompt = intakePrompt, glow = glow, glowLight = glowLight, deckY = deckY, center = center }
end

function ConvergenceRig.setConduit(rig: any, i: number, state: string)
	local c = rig.conduits[i]
	if not c then
		return
	end
	c.state = state
	local color = if state == "unstable" then UNSTABLE else STABLE
	recolor(c.model, color)
	c.beam.Enabled = state == "stable"
	c.prompt.Enabled = state == "unstable"
	c.model:SetAttribute("PFState", state)
end

function ConvergenceRig.spawnCell(rig: any, spotIndex: number): any
	local pos = rig.spots[spotIndex]
	local tpl = template("FluxCell")
	local model: Model
	local main: BasePart
	if tpl then
		model = tpl:Clone()
		model:PivotTo(CFrame.new(pos + Vector3.new(0, 3, 0)))
		main = model.PrimaryPart :: BasePart
	else
		model = Instance.new("Model")
		local pad = part({ Name = "Pad", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 4.4, 4.4), CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)), Material = Enum.Material.Neon, Color = STABLE, Transparency = 0.4, Parent = model })
		main = part({ Name = "Cell", Shape = Enum.PartType.Ball, Size = Vector3.new(2.4, 2.4, 2.4), CFrame = CFrame.new(pos + Vector3.new(0, 3, 0)), Material = Enum.Material.Neon, Color = STABLE, Parent = model })
		local light = Instance.new("PointLight")
		light.Range = 10
		light.Brightness = 1.4
		light.Color = STABLE
		light.Parent = main
		model.PrimaryPart = pad
	end
	model.Name = "FluxCell"
	model:SetAttribute("PFFluxCell", spotIndex)
	local pp = prompt(main, "Collect", "Flux Cell", CV.flux.holdTime, CV.flux.pickupDistance, true)
	pp.Name = "PF_FluxPrompt"
	model.Parent = rig.folder
	local cell = { model = model, main = main, prompt = pp, spot = spotIndex, pos = pos + Vector3.new(0, 3, 0), taken = false }
	table.insert(rig.cells, cell)
	return cell
end

function ConvergenceRig.removeCell(rig: any, cell: any)
	cell.taken = true
	local i = table.find(rig.cells, cell)
	if i then
		table.remove(rig.cells, i)
	end
	if cell.model then
		cell.model:Destroy()
	end
end

-- Visible carried cell welded to the character (replicates to everyone). Returns the part (destroy to drop).
function ConvergenceRig.attachCarry(rig: any, character: Model?): BasePart?
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local orb = Instance.new("Part")
	orb.Name = "PF_CarriedFluxCell"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(1.7, 1.7, 1.7)
	orb.Material = Enum.Material.Neon
	orb.Color = STABLE
	orb.CanCollide = false
	orb.CanTouch = false
	orb.CanQuery = false
	orb.Massless = true
	orb.CastShadow = false
	orb.CFrame = root.CFrame * CFrame.new(0, 1.2, 1.6)
	local light = Instance.new("PointLight")
	light.Range = 8
	light.Color = STABLE
	light.Parent = orb
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = orb
	weld.Parent = orb
	orb.Parent = character
	return orb
end

function ConvergenceRig.setStage(rig: any, stage: number, final: string?)
	local color = STAGE_COLORS[math.clamp(stage, 0, 3)]
	if final == "failed" then
		color = Color3.fromRGB(120, 110, 130)
	end
	rig.glow.Color = color
	rig.glowLight.Color = color
	rig.glowLight.Brightness = 2 + stage * 0.8
	rig.glow.Transparency = if final == "completed" then 0 else 0.2
	rig.folder:SetAttribute("PFStage", stage)
end

function ConvergenceRig.setAllStable(rig: any)
	for i in rig.conduits do
		ConvergenceRig.setConduit(rig, i, "stable")
	end
	for _, cell in table.clone(rig.cells) do
		ConvergenceRig.removeCell(rig, cell)
	end
	rig.intakePrompt.Enabled = false
end

function ConvergenceRig.destroy(rig: any)
	if rig.folder then
		rig.folder:Destroy()
	end
	table.clear(rig.cells)
end

return ConvergenceRig
