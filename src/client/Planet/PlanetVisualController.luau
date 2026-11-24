--!strict
-- PlanetVisualController — owner: Developer A. Renders the evolution of all 8 planets on every client.
--
-- Data flow:  Slot_n attributes (PlanetVisualContract, produced by PlanetVisualPublisher from Developer B's
--             PlanetDataService) -> Contract.fromInstance -> PlanetVisualProfile.build -> PlanetDecorator.
-- * Re-renders a slot only when its PFVisualRevision changes and the visual signature differs.
-- * LOD: "far" layers (atmosphere, water, clouds, landmark, rings, moon, aura) always shown; "near" layers
--   (geology, formations, props, particles) only while the camera is within NEAR_DISTANCE of the planet.
-- * Milestone transformation (stage went UP while this client watched): brief cinematic for anyone within
--   FX_RANGE — light pulse, surface recolour, formations emerging, atmosphere fade-in; skippable; scaled by the
--   effects level. Collision planet is never scaled.
-- * Effects level: LocalPlayer attribute "PFEffects" = "full" | "reduced" | "minimal" (touch-only devices
--   default to "reduced"). Changing it rebuilds all planets.
-- * Evolution WOW 2.0 (Technical Art): FormationRegistry formations + orbital dressing are rendered by a per-slot
--   FormationLayer (incremental: an unlock builds only the new formation, with its own emergence cinematic;
--   branch switches retire dormant ones). The decorator keeps the generic dressing and is told which sites to
--   leave free (spec.externalFormations / reservedSites / ownedLandmark / externalOrbitals).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Contract = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualContract)
local Profile = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualProfile)
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local Sfx = require(script.Parent.Parent.Audio.Sfx)
local PlanetDecorator = require(script.Parent.PlanetDecorator)
local FormationLayer = require(script.Parent.FormationLayer)
local SurfaceSkin = require(script.Parent.SurfaceSkin) -- Planet Physics 3.0: visible surface = collision sphere

local PlanetVisualController = {}

local NEAR_DISTANCE = WorldLayout.PLANET_RADIUS + 424 -- from the planet centre (2026-11-23: 520 at R = 96)
local FX_RANGE = 900
local LOD_INTERVAL = 0.25
local MAX_GROW_TWEENS = 140

local EFFECTS = {
	full = { level = "full", density = 1, particles = true, props = true, fxTime = 2.4 },
	reduced = { level = "reduced", density = 0.6, particles = true, props = true, fxTime = 1.3 },
	minimal = { level = "minimal", density = 0.4, particles = false, props = false, fxTime = 0.35 },
}

type SlotView = {
	slot: number,
	model: Model,
	signature: string,
	stage: number,
	built: any?,
	spec: any?,
	nearShown: boolean,
	original: { [BasePart]: { color: Color3, material: Enum.Material, transparency: number } },
	pending: boolean,
	layer: any?,
}

local player = Players.LocalPlayer
local views: { [number]: SlotView } = {}
local fxRoot: Folder
local effectsLevel = "full"
local skipRequested = false
local stats = { builds = 0, transforms = 0, lastBuildMs = 0 }

local function effects(): any
	local e = EFFECTS[effectsLevel] or EFFECTS.full
	if player:GetAttribute("PFReducedMotion") == true and e.fxTime > EFFECTS.minimal.fxTime then
		-- reduced motion: same content, shortest cinematic
		local copy = table.clone(e)
		copy.fxTime = EFFECTS.minimal.fxTime
		return copy
	end
	return e
end

local function reducedMotion(): boolean
	if player:GetAttribute("PFReducedMotion") == true then
		return true
	end
	local ok, v = pcall(function()
		return (game:GetService("GuiService") :: any).ReducedMotionEnabled
	end)
	return ok and v == true
end

local function signatureOf(spec: any): string
	return table.concat({ spec.themeLabel or spec.theme, spec.stage, spec.seed, spec.extraWater, spec.clouds, spec.formations, spec.props, tostring(spec.polarCaps), spec.rings, math.floor(spec.glow * 10), effectsLevel, tostring(spec.ownedLandmark) }, "|")
end

-- Local, purely visual recolour of the server planet's Core + maria basins (remembered for restore).
local function applySurface(view: SlotView, spec: any)
	local core = view.model:FindFirstChild("Core") :: BasePart?
	local maria = view.model:FindFirstChild("Maria")
	local targets: { BasePart } = {}
	if core then
		table.insert(targets, core)
	end
	if maria then
		for _, m in maria:GetChildren() do
			if m:IsA("BasePart") then
				table.insert(targets, m)
			end
		end
	end
	for _, p in targets do
		if not view.original[p] then
			view.original[p] = { color = p.Color, material = p.Material, transparency = p.Transparency }
		end
	end
	-- barren-era detail (boulders, crater rims, spires) streams in separately; tint it to the theme too
	local world = Workspace:FindFirstChild("PF_World")
	local detailRoot = world and world:FindFirstChild("PlanetDetail")
	local detail = detailRoot and detailRoot:FindFirstChild("Slot_" .. view.slot .. "_Detail")
	local rocks: { [BasePart]: boolean } = {}
	if detail then
		for _, p in detail:GetDescendants() do
			if p:IsA("BasePart") and p.Transparency < 0.9 then
				rocks[p] = true
				table.insert(targets, p)
				if not view.original[p] then
					view.original[p] = { color = p.Color, material = p.Material, transparency = p.Transparency }
				end
			end
		end
	end
	for _, p in targets do
		local o = view.original[p]
		if rocks[p] then
			if spec.stage == 0 or not spec.rock then
				p.Color, p.Material = o.color, o.material
			else
				-- keep the original light/dark variation, shifted to the theme's rock colour
				local lum = (o.color.R + o.color.G + o.color.B) / 3
				local k = math.clamp(lum / 0.42, 0.6, 1.3)
				local c = spec.rock.color
				p.Color = Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
				p.Material = spec.rock.material
			end
		elseif spec.stage == 0 then
			p.Color, p.Material, p.Transparency = o.color, o.material, o.transparency
		elseif p == core then
			p.Material = spec.surface.material
			p.Color = spec.surface.color
		else
			p.Material = spec.basins.material
			p.Color = spec.basins.color
			p.Transparency = spec.basins.transparency
		end
	end
end

local function updateLabel(view: SlotView, state: any, spec: any)
	local core = view.model:FindFirstChild("Core")
	local label = core and core:FindFirstChild("PlanetLabel")
	local owner = label and label:FindFirstChild("Owner")
	if owner and owner:IsA("TextLabel") then
		owner.Text = if state.ownerUserId > 0 then string.format("%s · %s", state.ownerName ~= "" and state.ownerName or "Owner", spec.stageName) else "Unclaimed"
	end
	-- dock sign on THE FORGE
	local world = Workspace:FindFirstChild("PF_World")
	local dock = world and world:FindFirstChild("Station") and world.Station:FindFirstChild("Docks") and world.Station.Docks:FindFirstChild("Dock_" .. view.slot)
	local beam = dock and dock:FindFirstChild("GateBeam")
	local sign = beam and beam:FindFirstChild("Sign")
	local sub = sign and sign:FindFirstChildWhichIsA("Frame") and sign:FindFirstChildWhichIsA("Frame"):FindFirstChild("Subtitle")
	if sub and sub:IsA("TextLabel") then
		sub.Text = if state.ownerUserId > 0 then (state.ownerName ~= "" and state.ownerName or "CLAIMED"):upper() else "UNCLAIMED"
	end
end

-- Visual capture for the evolution screen (before/after). A Model with clones of the Core, maria and the built
-- decoration; positioned in world space (centre = core position). Cheap: only taken for the local player's own
-- planet when its stage or theme changes.
local captures: { [number]: { before: Model? } } = {}
local function captureVisual(view: SlotView): Model?
	local core = view.model:FindFirstChild("Core") :: BasePart?
	if not core then
		return nil
	end
	local m = Instance.new("Model")
	m.Name = "PlanetCapture"
	local c = core:Clone()
	c.LocalTransparencyModifier = 0 -- the live Core is hidden locally behind its SurfaceSkin
	for _, ch in c:GetChildren() do
		if not ch:IsA("SpecialMesh") then
			ch:Destroy()
		end
	end
	c.Parent = m
	m.PrimaryPart = c
	local maria = view.model:FindFirstChild("Maria")
	if maria then
		maria:Clone().Parent = m
	end
	if view.built then
		view.built.far:Clone().Parent = m
		view.built.near:Clone().Parent = m
	end
	if view.layer then
		view.layer.far:Clone().Parent = m
		view.layer.near:Clone().Parent = m
	end
	for _, d in m:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Light") or d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	return m
end

local function destroyBuilt(view: SlotView)
	if view.built then
		view.built.near:Destroy()
		view.built.far:Destroy()
		view.built = nil
	end
	view.nearShown = false
end

local function cameraDistance(view: SlotView): number
	local core = view.model:FindFirstChild("Core") :: BasePart?
	if not core then
		return math.huge
	end
	return (Workspace.CurrentCamera.CFrame.Position - core.Position).Magnitude
end

local function setNear(view: SlotView, show: boolean)
	if not view.built or view.nearShown == show then
		return
	end
	view.nearShown = show
	view.built.near.Parent = if show then fxRoot else nil
end

----------------------------------------------------------------------------------------------------
-- transformation cinematic

local skipGui: ScreenGui? = nil

local function showBanner(text: string, canSkip: boolean, duration: number, compact: boolean?)
	if not skipGui then
		local g = Instance.new("ScreenGui")
		g.Name = "PF_EvolutionFX"
		g.ResetOnSpawn = false
		g.DisplayOrder = 40
		local frame = Instance.new("Frame")
		frame.Name = "Banner"
		frame.AnchorPoint = Vector2.new(0.5, 0)
		frame.Position = UDim2.fromScale(0.5, 0.16)
		frame.Size = UDim2.new(0.5, 0, 0, 64)
		frame.BackgroundColor3 = Color3.fromRGB(12, 14, 30)
		frame.BackgroundTransparency = 0.25
		frame.Visible = false
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 10)
		c.Parent = frame
		local sz = Instance.new("UISizeConstraint")
		sz.MaxSize = Vector2.new(620, 64)
		sz.MinSize = Vector2.new(280, 64)
		sz.Parent = frame
		local t = Instance.new("TextLabel")
		t.Name = "Text"
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, -110, 1, 0)
		t.Position = UDim2.fromOffset(14, 0)
		t.Font = Enum.Font.GothamBlack
		t.TextScaled = true
		t.TextColor3 = Color3.fromRGB(150, 230, 255)
		t.Parent = frame
		local b = Instance.new("TextButton")
		b.Name = "Skip"
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -10, 0.5, 0)
		b.Size = UDim2.fromOffset(84, 44)
		b.BackgroundColor3 = Color3.fromRGB(45, 70, 110)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 16
		b.Text = "Skip ▸"
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 8)
		bc.Parent = b
		b.Activated:Connect(function()
			PlanetVisualController.skipCinematics()
		end)
		b.Parent = frame
		frame.Parent = g
		g.Parent = player:WaitForChild("PlayerGui")
		skipGui = g
	end
	local frame = (skipGui :: ScreenGui):FindFirstChild("Banner") :: Frame
	local textLabel = frame:FindFirstChild("Text") :: TextLabel
	local skipButton = frame:FindFirstChild("Skip") :: TextButton
	textLabel.Text = text
	skipButton.Visible = canSkip
	-- compact = owner's own planet: Developer B's PF_TransformationBanner already shows the text, so only
	-- the Skip control is drawn here (top-right, clear of B's banner and of mobile thumb controls).
	textLabel.Visible = not compact
	frame.BackgroundTransparency = if compact then 1 else 0.25
	frame.AnchorPoint = if compact then Vector2.new(1, 0) else Vector2.new(0.5, 0)
	frame.Position = if compact then UDim2.new(1, -16, 0, 72) else UDim2.fromScale(0.5, 0.16)
	frame.Size = if compact then UDim2.fromOffset(100, 64) else UDim2.new(0.5, 0, 0, 64)
	local constraint = frame:FindFirstChildOfClass("UISizeConstraint")
	if constraint then
		constraint.MinSize = if compact then Vector2.new(100, 64) else Vector2.new(280, 64)
	end
	frame.Visible = true
	task.delay(duration + 1.2, function()
		frame.Visible = false
	end)
end

local function playTransformation(view: SlotView, spec: any, oldStage: number)
	stats.transforms += 1
	local fx = effects()
	local T = fx.fxTime
	local core = view.model:FindFirstChild("Core") :: BasePart?
	if not core then
		return
	end
	local built = view.built
	skipRequested = false
	local isMine = view.model:GetAttribute("PFOwnerUserId") == player.UserId
	showBanner(string.format("PLANET %02d → %s%s", view.slot, spec.stageName:upper(), if spec.stage >= 3 then " · " .. (spec.themeLabel or spec.theme):upper() else ""), true, T, isMine)
	-- audio: the owner hears it full (2D); a visitor hears it from the planet (positional)
	local soundAt: any = if isMine then nil else core
	Sfx.play("Transformation", { at = soundAt, volume = if isMine then 0.55 else 0.8 })
	local powerUpPlayed = false
	local function powerUp()
		if not powerUpPlayed then
			powerUpPlayed = true
			Sfx.play("Power_Up", { at = soundAt, volume = if isMine then 0.6 else 0.8 })
		end
	end
	if reducedMotion() then
		-- Evolution WOW 2.0: reduced motion snaps to the new look (no pulse flash, no growth, no recolour tween)
		powerUp()
		return
	end
	local tweens: { Tween } = {}
	local function tw(obj: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, delay: number?)
		local x = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay or 0), props)
		x:Play()
		table.insert(tweens, x)
		return x
	end
	-- 1) light pulse expanding from the core
	local pulse = Instance.new("Part")
	pulse.Name = "EvolutionPulse"
	pulse.Shape = Enum.PartType.Ball
	pulse.Anchored, pulse.CanCollide, pulse.CanQuery, pulse.CanTouch, pulse.CastShadow = true, false, false, false, false
	pulse.Material = Enum.Material.Neon
	pulse.Color = spec.palette.glow or Color3.fromRGB(150, 230, 255)
	pulse.Size = core.Size * 1.01
	pulse.CFrame = core.CFrame
	pulse.Transparency = 0.15
	pulse.Parent = fxRoot
	tw(pulse, T * 0.7, { Size = core.Size * 1.45, Transparency = 1 }, Enum.EasingStyle.Quad)
	-- 2) surface colour shift (tween from the barren colour)
	if fx.level ~= "minimal" then
		local target = core.Color
		core.Color = view.original[core] and view.original[core].color or target
		tw(core, T * 0.8, { Color = target }, Enum.EasingStyle.Sine)
	end
	-- 3) atmosphere fades in, formations emerge from the ground (near LOD only, capped)
	if built and fx.level ~= "minimal" then
		local atmo = built.far:FindFirstChild("Atmosphere") :: BasePart?
		if atmo then
			local tr = atmo.Transparency
			atmo.Transparency = 1
			tw(atmo, T * 0.9, { Transparency = tr }, Enum.EasingStyle.Sine)
		end
		local n = 0
		for _, p in built.grow do
			if n >= MAX_GROW_TWEENS then
				break
			end
			if p.Parent then
				n += 1
				local targetSize, targetCf = p.Size, p.CFrame
				local up = (p.Position - core.Position).Unit
				p.Size = targetSize * 0.05
				p.CFrame = targetCf - up * (targetSize.Magnitude * 0.4)
				tw(p, T * 0.45, { Size = targetSize, CFrame = targetCf }, Enum.EasingStyle.Back, math.random() * T * 0.45)
			end
		end
	end
	-- skip: finish everything immediately
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < T + 0.6 do
			if skipRequested then
				for _, x in tweens do
					x:Cancel()
				end
				break
			end
			task.wait(0.05)
		end
		powerUp() -- the stage "lands": end of the sequence, or immediately on Skip
		if skipRequested then
			-- snap to final state by re-applying the spec
			skipRequested = false
			view.signature = ""
			PlanetVisualController.refresh(view.slot, true)
		end
		pulse:Destroy()
	end)
	local _ = oldStage
end

----------------------------------------------------------------------------------------------------

-- Evolution screen API: before = look before the last stage/theme change of MY planet; after = current look.
-- Callers own (and must Destroy) the returned models.
function PlanetVisualController.getEvolutionCaptures(slot: number): (Model?, Model?)
	local view = views[slot]
	local before = captures[slot] and captures[slot].before
	local b = if before then before:Clone() else nil
	local a = if view then captureVisual(view) else nil
	return b, a
end

function PlanetVisualController.refresh(slot: number, silent: boolean?)
	local view = views[slot]
	if not view then
		return
	end
	local state = Contract.fromInstance(slot, view.model)
	local spec = Profile.build(state)
	local layer = view.layer
	if layer then
		spec.externalFormations = true
		spec.externalOrbitals = spec.stage >= 3
		spec.ownedLandmark = layer:hasLandmark(spec)
	end
	local sig = signatureOf(spec)
	updateLabel(view, state, spec)
	if sig == view.signature then
		-- same look: only formations may have changed -> incremental (new ones emerge, retired ones sink)
		if layer then
			layer:sync(spec, { silent = silent, quality = effectsLevel })
		end
		return
	end
	local oldStage = view.stage
	local firstRender = view.signature == ""
	local t0 = os.clock()
	if view.model:GetAttribute("PFOwnerUserId") == player.UserId and view.spec and (view.spec.stage ~= spec.stage or view.spec.theme ~= spec.theme) then
		local prev = captures[slot]
		if prev and prev.before then
			prev.before:Destroy()
		end
		captures[slot] = { before = captureVisual(view) }
	end
	destroyBuilt(view)
	view.spec = spec
	applySurface(view, spec)
	do -- Planet Physics 3.0: stage 0 is decorated too (barren geology only: every other count is 0 at stage 0)
		if layer then
			spec.reservedSites = layer:reservedSites(spec, effectsLevel)
			local owned = 0
			for _, n in spec.formationCounts or {} do
				owned += if type(n) == "number" then n else 0
			end
			spec.ownedFormations = owned
		end
		view.built = PlanetDecorator.build(view.model, spec, effects(), fxRoot)
	end
	view.signature = sig
	view.stage = spec.stage
	stats.builds += 1
	stats.lastBuildMs = (os.clock() - t0) * 1000
	view.model:SetAttribute("PFClientRenderedStage", spec.stage) -- local, for tests/debug
	if view.built then
		setNear(view, cameraDistance(view) < NEAR_DISTANCE)
	end
	if layer then
		layer:sync(spec, { silent = silent or firstRender, quality = effectsLevel })
	end
	if not silent and not firstRender and spec.stage > oldStage and cameraDistance(view) < FX_RANGE then
		playTransformation(view, spec, oldStage)
	end
end

-- Skip every running cinematic: the stage transformation and any formation emergence (final state at once).
function PlanetVisualController.skipCinematics()
	skipRequested = true
	for _, v in views do
		if v.layer then
			v.layer:skipAll()
		end
	end
end

local function watch(model: Model)
	local slot = model:GetAttribute("PFSlot")
	if type(slot) ~= "number" or views[slot] then
		return
	end
	local view: SlotView = { slot = slot, model = model, signature = "", stage = 0, built = nil, nearShown = false, original = setmetatable({}, { __mode = "k" }) :: any, pending = false, layer = FormationLayer.new(slot, model, fxRoot) }
	views[slot] = view
	SurfaceSkin.attach(model)
	local function schedule()
		if view.pending then
			return
		end
		view.pending = true
		task.delay(0.1, function() -- coalesce the burst of attribute writes of one publish
			view.pending = false
			PlanetVisualController.refresh(slot)
		end)
	end
	model:GetAttributeChangedSignal(Contract.ATTR.Revision):Connect(schedule)
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBuilt(view)
			SurfaceSkin.detach(model)
			if view.layer then
				view.layer:destroy()
				view.layer = nil
			end
			views[slot] = nil
		end
	end)
	PlanetVisualController.refresh(slot, true)
end

function PlanetVisualController.setEffects(level: string)
	if not EFFECTS[level] or level == effectsLevel then
		return
	end
	effectsLevel = level
	-- mirror the preset to the PFEffects attribute (other client systems read it: transformation FX,
	-- event FX, shadow preset); the attribute handler calls back here and returns early (same level)
	player:SetAttribute("PFEffects", level)
	for slot in views do
		PlanetVisualController.refresh(slot, true)
	end
end

function PlanetVisualController.getEffects(): string
	return effectsLevel
end

function PlanetVisualController.cycleEffects(): string
	local order = { "full", "reduced", "minimal" }
	local i = table.find(order, effectsLevel) or 1
	local nextLevel = order[(i % #order) + 1]
	player:SetAttribute("PFEffects", nextLevel)
	return nextLevel
end

function PlanetVisualController.getStats()
	local near, far = 0, 0
	for _, v in views do
		if v.built then
			for _, d in v.built.near:GetDescendants() do
				if d:IsA("BasePart") then
					near += 1
				end
			end
			for _, d in v.built.far:GetDescendants() do
				if d:IsA("BasePart") then
					far += 1
				end
			end
		end
	end
	local fl = { instances = 0, parts = 0, emerging = 0, cinematics = 0, built = 0, removed = 0 }
	for _, v in views do
		if v.layer then
			local ls = v.layer:getStats()
			for k in fl do
				fl[k] += ls[k] or 0
			end
		end
	end
	return { builds = stats.builds, transforms = stats.transforms, lastBuildMs = stats.lastBuildMs, nearParts = near, farParts = far, effects = effectsLevel, formations = fl }
end

function PlanetVisualController.init()
	local fx = Workspace:FindFirstChild("PF_ClientFX") or Instance.new("Folder")
	fx.Name = "PF_ClientFX"
	fx.Parent = Workspace
	local root = Instance.new("Folder")
	root.Name = "PlanetVisuals"
	root.Parent = fx
	fxRoot = root

	local attr = player:GetAttribute("PFEffects")
	if type(attr) == "string" and EFFECTS[attr] then
		effectsLevel = attr
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		effectsLevel = "reduced"
	end
	player:GetAttributeChangedSignal("PFEffects"):Connect(function()
		local v = player:GetAttribute("PFEffects")
		if type(v) == "string" then
			PlanetVisualController.setEffects(v)
		end
	end)

	task.spawn(function()
		local world = Workspace:WaitForChild("PF_World", 30)
		local planets = world and world:WaitForChild("Planets", 30)
		if not planets then
			warn("[PF] PlanetVisualController: no planets folder")
			return
		end
		-- streamed planet detail arrives (or re-arrives) after the core: tint it to the current theme
		local detailRoot = world:WaitForChild("PlanetDetail", 10)
		if detailRoot then
			detailRoot.ChildAdded:Connect(function(m)
				local slot = tonumber(string.match(m.Name, "^Slot_(%d+)_Detail$"))
				local view = slot and views[slot]
				if view and view.spec then
					task.defer(applySurface, view, view.spec)
				end
			end)
		end
		planets.ChildAdded:Connect(function(m)
			if m:IsA("Model") then
				task.defer(watch, m)
			end
		end)
		for _, m in planets:GetChildren() do
			if m:IsA("Model") then
				watch(m)
				task.wait() -- spread initial builds over frames
			end
		end
		-- LOD + slow glow pulse, at LOD_INTERVAL
		local acc = 0
		local phase = 0
		RunService.Heartbeat:Connect(function(dt)
			acc += dt
			phase += dt
			if acc < LOD_INTERVAL then
				return
			end
			acc = 0
			for _, v in views do
				local d = cameraDistance(v)
				if v.layer then
					v.layer:setDistance(d)
				end
				if v.built then
					setNear(v, d < NEAR_DISTANCE)
					-- gentle neon pulse on the planet you're near (cheap: <= 60 parts, 4 Hz)
					if v.nearShown and effectsLevel ~= "minimal" then
						local k = 0.15 + 0.12 * math.sin(phase * 2 + v.slot)
						for i, p in v.built.pulse do
							if i > 60 then
								break
							end
							if p.Name == "Glow" then
								p.Transparency = k
							end
						end
					end
				end
			end
		end)
		-- formation layers: idle animation (near), orbitals (near/mid), emergence cinematics (any range)
		RunService.Heartbeat:Connect(function(dt)
			for _, v in views do
				local layer = v.layer
				if layer and (layer.lod ~= "far" or next(layer.emerging) ~= nil) then
					layer:step(dt)
				end
			end
		end)
	end)
end

local _ = WorldLayout
return PlanetVisualController
