--!strict
-- HarvestHUD — owner: Gameplay (Cosmic Core Hunt). All Cosmic Core Hunt screen UI.
--   PF_HarvestHUD (while operating): reticle (+ charge ring and pulse-emitter status beside it), target
--     markers (rarity, lock brackets, resonance ring, capture band, INBOUND / PHASED states), off-screen arrows,
--     harvester panel (energy, materials, captures, focus), notice line (new reaction / rare inbound), feedback
--     text, reward popups, tutorial panel, control hints, EXIT button, touch FIRE (hold / release) / NEXT.
--   PF_HarvestHint (while walking): onboarding banner + toasts.
-- Positions are viewport pixels (IgnoreGuiInset), matching Camera:WorldToViewportPoint.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)
local Styles = require(script.Parent.MeteorStyles)

local HUD = {}
HUD.__index = HUD

local C = VisualStyle.Color
local GREEN = Color3.fromRGB(90, 255, 150)
local GOLD = Color3.fromRGB(255, 215, 90)
local RED = Color3.fromRGB(255, 90, 90)
local WHITE = Color3.new(1, 1, 1)
local MAX_MARKERS = 6

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(className)
	for k, v in props do
		(i :: any)[k] = v
	end
	if parent then
		i.Parent = parent
	end
	return i
end

local function frame(parent: Instance, props: { [string]: any }): Frame
	props.BorderSizePixel = 0
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	return new("Frame", props, parent)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.Font = props.Font or Enum.Font.GothamBold
	props.TextColor3 = props.TextColor3 or C.Text
	props.BorderSizePixel = 0
	return new("TextLabel", props, parent)
end

local function circle(parent: Instance, props: { [string]: any }, strokeColor: Color3, thickness: number): (Frame, UIStroke)
	local f = frame(parent, props)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, f)
	local s = new("UIStroke", { Color = strokeColor, Thickness = thickness, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	return f, s
end

local function panelStyle(f: Frame)
	f.BackgroundColor3 = Color3.fromRGB(12, 16, 28)
	f.BackgroundTransparency = 0.25
	new("UICorner", { CornerRadius = UDim.new(0, 10) }, f)
	new("UIStroke", { Color = C.Cyan, Thickness = 1.2, Transparency = 0.55 }, f)
end

local function button(parent: Instance, props: { [string]: any }, text: string, color: Color3, round: boolean): TextButton
	props.BackgroundColor3 = Color3.fromRGB(14, 20, 34)
	props.BackgroundTransparency = 0.15
	props.AutoButtonColor = true
	props.Text = text
	props.Font = Enum.Font.GothamBlack
	props.TextColor3 = color
	props.TextScaled = true
	props.BorderSizePixel = 0
	local b = new("TextButton", props, parent)
	new("UICorner", { CornerRadius = if round then UDim.new(0.5, 0) else UDim.new(0, 10) }, b)
	new("UIStroke", { Color = color, Thickness = 2.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	new("UIPadding", { PaddingTop = UDim.new(0.22, 0), PaddingBottom = UDim.new(0.22, 0), PaddingLeft = UDim.new(0.12, 0), PaddingRight = UDim.new(0.12, 0) }, b)
	return b
end

local function buildMarker(parent: Instance, index: number): any
	local root = frame(parent, { Name = "Marker" .. index, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(60, 60), Visible = false, ZIndex = 2 })
	-- four corner brackets
	local brackets = {}
	for _, c in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local h = frame(root, { AnchorPoint = Vector2.new(c[1], c[2]), Position = UDim2.fromScale(c[1], c[2]), Size = UDim2.new(0.32, 0, 0, 3), BackgroundTransparency = 0, BackgroundColor3 = WHITE, ZIndex = 3 })
		local v = frame(root, { AnchorPoint = Vector2.new(c[1], c[2]), Position = UDim2.fromScale(c[1], c[2]), Size = UDim2.new(0, 3, 0.32, 0), BackgroundTransparency = 0, BackgroundColor3 = WHITE, ZIndex = 3 })
		table.insert(brackets, h)
		table.insert(brackets, v)
	end
	local band, bandStroke = circle(root, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 2 }, GREEN, 6)
	bandStroke.Transparency = 0.55
	bandStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	local perfect, perfectStroke = circle(root, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 2 }, GOLD, 2)
	perfectStroke.Transparency = 0.3
	local ring, ringStroke = circle(root, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(2, 2), ZIndex = 4 }, WHITE, 2.5)
	local name = label(root, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -8), Size = UDim2.fromOffset(200, 18), TextSize = 15, Text = "", TextStrokeTransparency = 0.4, ZIndex = 5 })
	local rarity = label(root, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -27), Size = UDim2.fromOffset(200, 14), TextSize = 12, Font = Enum.Font.GothamBlack, Text = "", TextStrokeTransparency = 0.4, ZIndex = 5 })
	local state = label(root, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 8), Size = UDim2.fromOffset(200, 18), TextSize = 15, Font = Enum.Font.GothamBlack, Text = "", TextStrokeTransparency = 0.4, ZIndex = 5 })
	local barBack = frame(root, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 4), Size = UDim2.new(0.9, 0, 0, 3), BackgroundTransparency = 0.5, BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 5 })
	local bar = frame(barBack, { Size = UDim2.fromScale(0, 1), BackgroundTransparency = 0, BackgroundColor3 = C.Cyan, ZIndex = 6 })
	return { root = root, brackets = brackets, band = band, bandStroke = bandStroke, perfect = perfect, perfectStroke = perfectStroke, ring = ring, ringStroke = ringStroke, name = name, rarity = rarity, state = state, barBack = barBack, bar = bar }
end

function HUD.new(playerGui: Instance)
	local self = setmetatable({}, HUD)
	self.onFire = function() end
	self.onFirePress = function() end
	self.onFireRelease = function() end
	self.onCycle = function() end
	self.onExit = function() end

	local gui = new("ScreenGui", { Name = "PF_HarvestHUD", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 20, Enabled = false })
	self.gui = gui

	-- world-anchored layer (no UIScale: viewport pixels)
	local world = frame(gui, { Name = "World", Size = UDim2.fromScale(1, 1) })
	self.markers = {}
	for i = 1, MAX_MARKERS do
		table.insert(self.markers, buildMarker(world, i))
	end
	self.arrows = {}
	for i = 1, MAX_MARKERS do
		table.insert(self.arrows, label(world, { Name = "Arrow" .. i, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(34, 34), Text = "▲", TextSize = 30, Font = Enum.Font.GothamBlack, Visible = false, TextStrokeTransparency = 0.3, ZIndex = 6 }))
	end
	local ret = frame(world, { Name = "Reticle", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(46, 46), ZIndex = 8 })
	local retRing, retStroke = circle(ret, { Size = UDim2.fromScale(1, 1), ZIndex = 8 }, WHITE, 2)
	local dot = frame(ret, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(6, 6), BackgroundTransparency = 0, BackgroundColor3 = WHITE, ZIndex = 9 })
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, dot)
	local ticks = {}
	for _, d in { { 0.5, -0.25, 2, 10 }, { 0.5, 1.25, 2, 10 }, { -0.25, 0.5, 10, 2 }, { 1.25, 0.5, 10, 2 } } do
		table.insert(ticks, frame(ret, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(d[1], d[2]), Size = UDim2.fromOffset(d[3], d[4]), BackgroundTransparency = 0, BackgroundColor3 = WHITE, ZIndex = 9 }))
	end
	-- charge ring grows inside the reticle; emitter status + reload / charge bar sit to its RIGHT so they never
	-- cover the target marker's own labels (rarity / name above it, lock state below it)
	local charge, chargeStroke = circle(ret, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.25, 0.25), Visible = false, ZIndex = 8 }, GOLD, 3)
	local status = label(ret, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(1, 14, 0.5, -4), Size = UDim2.fromOffset(230, 16), TextSize = 13, Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "", TextStrokeTransparency = 0.35, ZIndex = 9 })
	local cdBack = frame(ret, { AnchorPoint = Vector2.new(0, 0), Position = UDim2.new(1, 14, 0.5, 6), Size = UDim2.fromOffset(92, 4), BackgroundTransparency = 0.5, BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 9 })
	local cd = frame(cdBack, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0, BackgroundColor3 = C.Cyan, ZIndex = 10 })
	self.reticle = { root = ret, ring = retRing, stroke = retStroke, dot = dot, ticks = ticks, cdBack = cdBack, cd = cd, charge = charge, chargeStroke = chargeStroke, status = status }

	-- overlay layer (scaled)
	local overlay = frame(gui, { Name = "Overlay", Size = UDim2.fromScale(1, 1), ZIndex = 20 }) -- resized to 1/scale in setViewport
	self.scale = new("UIScale", { Scale = 1 }, overlay)
	self.overlay = overlay

	local panel = frame(overlay, { Name = "Panel", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 74), Size = UDim2.fromOffset(300, 150), BackgroundTransparency = 0.25 })
	panelStyle(panel)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 8) }, panel)
	label(panel, { Size = UDim2.new(1, 0, 0, 22), Text = "GRAVITY HARVESTER", Font = Enum.Font.GothamBlack, TextSize = 18, TextColor3 = C.Cyan, TextXAlignment = Enum.TextXAlignment.Left })
	self.energyText = label(panel, { Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, 16), Text = "HARVEST ENERGY", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left })
	local eBack = frame(panel, { Position = UDim2.fromOffset(0, 47), Size = UDim2.new(1, 0, 0, 8), BackgroundTransparency = 0.4, BackgroundColor3 = Color3.fromRGB(30, 36, 54) })
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, eBack)
	self.energyBar = frame(eBack, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0, BackgroundColor3 = C.Violet })
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, self.energyBar)
	self.matText = label(panel, { Position = UDim2.fromOffset(0, 62), Size = UDim2.new(1, 0, 0, 38), RichText = true, TextWrapped = true, Text = "", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })
	self.sessionText = label(panel, { Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 0, 18), Text = "Captures this session: 0", TextSize = 13, Font = Enum.Font.GothamMedium, TextXAlignment = Enum.TextXAlignment.Left })
	self.focusText = label(panel, { Position = UDim2.fromOffset(0, 124), Size = UDim2.new(1, 0, 0, 18), Text = "", TextSize = 13, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Left })

	self.noticeLabel = label(overlay, { Name = "Notice", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 232), Size = UDim2.fromOffset(300, 22), TextSize = 15, Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Right, Text = "", TextStrokeTransparency = 0.35, TextTransparency = 1, ZIndex = 21 })

	self.feedback = label(overlay, { Name = "Feedback", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.3), Size = UDim2.fromOffset(700, 56), Font = Enum.Font.GothamBlack, TextSize = 44, Text = "", TextStrokeTransparency = 0.3, TextTransparency = 1 })
	self.feedbackSub = label(overlay, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.3, 40), Size = UDim2.fromOffset(700, 26), Font = Enum.Font.GothamBold, TextSize = 20, Text = "", TextStrokeTransparency = 0.4, TextTransparency = 1 })

	local tut = frame(overlay, { Name = "Tutorial", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18), Size = UDim2.fromOffset(600, 74), BackgroundTransparency = 0.2, Visible = false })
	panelStyle(tut)
	self.tutStep = label(tut, { Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 16), TextSize = 13, TextColor3 = GOLD, Text = "" })
	self.tutText = label(tut, { Position = UDim2.fromOffset(12, 24), Size = UDim2.new(1, -24, 0, 44), TextSize = 20, TextWrapped = true, RichText = true, Text = "" })
	self.tutorial = tut

	self.hints = label(overlay, { Name = "Hints", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14), Size = UDim2.fromOffset(820, 22), TextSize = 15, Font = Enum.Font.GothamMedium, TextStrokeTransparency = 0.5, Text = "" })

	local exit = button(overlay, { Name = "Exit", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 18), Size = UDim2.fromOffset(130, 44) }, "EXIT  [Q]", C.Text, false)
	exit.Activated:Connect(function()
		self.onExit()
	end)
	self.exitButton = exit

	local touch = frame(overlay, { Name = "Touch", Size = UDim2.fromScale(1, 1), Visible = false })
	local fire = button(touch, { Name = "Fire", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -34, 1, -56), Size = UDim2.fromOffset(132, 132) }, "FIRE", C.Cyan, true)
	-- hold to charge, release to fire (the release is caught globally, so sliding off the button still fires)
	fire.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) and input.UserInputState == Enum.UserInputState.Begin and not self._fireInput then
			self._fireInput = input
			self.onFirePress()
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == self._fireInput then
			self._fireInput = nil
			self.onFireRelease()
		end
	end)
	local nxt = button(touch, { Name = "Next", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -184, 1, -80), Size = UDim2.fromOffset(86, 86) }, "NEXT", C.Violet, true)
	nxt.Activated:Connect(function()
		self.onCycle()
	end)
	self.touch = touch
	self.fireButton = fire

	self.popups = frame(overlay, { Name = "Popups", Size = UDim2.fromScale(1, 1) })

	-- perfect-capture screen-edge glow (world layer: unscaled, covers the whole viewport)
	local glow = frame(gui, { Name = "PerfectGlow", Size = UDim2.fromScale(1, 1), ZIndex = 30 })
	self.glowStroke = new("UIStroke", { Color = GOLD, Thickness = 16, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, glow)

	-- walking-mode hint gui
	local hint = new("ScreenGui", { Name = "PF_HarvestHint", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 15, Enabled = true })
	local hintRoot = frame(hint, { Name = "Root", Size = UDim2.fromScale(1, 1) })
	self.hintRoot = hintRoot
	self.hintScale = new("UIScale", { Scale = 1 }, hintRoot)
	local banner = frame(hintRoot, { Name = "Banner", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 58), Size = UDim2.fromOffset(620, 72), BackgroundTransparency = 0.2, Visible = false })
	panelStyle(banner)
	self.bannerTitle = label(banner, { Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 18), TextSize = 15, Font = Enum.Font.GothamBlack, TextColor3 = C.Cyan, Text = "COSMIC CORE HUNT" })
	self.bannerText = label(banner, { Position = UDim2.fromOffset(14, 26), Size = UDim2.new(1, -28, 0, 40), TextSize = 16, Font = Enum.Font.GothamMedium, TextWrapped = true, Text = "" })
	self.banner = banner
	self.toast = label(hintRoot, { Name = "Toast", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -120), Size = UDim2.fromOffset(600, 30), TextSize = 20, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.3, TextTransparency = 1, Text = "" })
	self.hintGui = hint

	-- the top-centre strip belongs to the Cosmic World Events chips (EventHud) while an event is shown:
	-- the onboarding banner then sits just below them instead of underneath
	task.spawn(function()
		local events = game:GetService("ReplicatedStorage"):WaitForChild("PF_WorldEvents", 30)
		if not events then
			return
		end
		local function place()
			local busy = #events:GetChildren() > 0
			banner.Position = UDim2.new(0.5, 0, 0, if busy then 136 else 58)
		end
		events.ChildAdded:Connect(place)
		events.ChildRemoved:Connect(function()
			task.defer(place)
		end)
		place()
	end)

	gui.Parent = playerGui
	hint.Parent = playerGui
	return self
end

-- UIScale scales a frame from its top-left, so the scaled roots are sized 1/s to keep filling the screen.
function HUD:setViewport(vp: Vector2)
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.6, 1.25)
	if s ~= self._lastScale then
		self._lastScale = s
		self.scale.Scale = s
		self.hintScale.Scale = s
		self.overlay.Size = UDim2.fromScale(1 / s, 1 / s)
		self.hintRoot.Size = UDim2.fromScale(1 / s, 1 / s)
	end
end

function HUD:setActive(on: boolean)
	self.gui.Enabled = on
	self.hintGui.Enabled = not on
end

function HUD:setReticle(pos: Vector2, color: Color3, cooldownFrac: number, visible: boolean)
	local r = self.reticle
	local now = os.clock()
	local calm = Styles.reducedMotion()
	local p = pos
	local size = 46
	local missAge = now - (self._missT or -10)
	if missAge < 0.35 then
		color = RED:Lerp(color, missAge / 0.35)
		if not calm then
			p = pos + Vector2.new(math.sin(missAge * 60) * 6 * (1 - missAge / 0.35), 0)
		end
	end
	local popAge = now - (self._popT or -10)
	if popAge < 0.22 and not calm then
		size = 46 * (1 + 0.35 * (1 - popAge / 0.22) ^ 2)
	end
	r.root.Visible = visible
	r.root.Position = UDim2.fromOffset(p.X, p.Y)
	r.root.Size = UDim2.fromOffset(size, size)
	r.stroke.Color = color
	r.dot.BackgroundColor3 = color
	for _, t in r.ticks do
		t.BackgroundColor3 = color
	end
	local _ = cooldownFrac -- the reload / charge bar is driven by :setEmitter (Meteor V2)
end

-- READY transition: the reticle pops once.
function HUD:readyPop()
	self._popT = os.clock()
end

-- Miss: the reticle shakes (not under reduced motion) and flashes red for a moment.
function HUD:missPulse()
	self._missT = os.clock()
end

-- Perfect capture: a soft gold glow around the screen edge (one fade, never a strobe).
function HUD:perfectGlow(color: Color3?)
	local st = self.glowStroke
	st.Color = color or GOLD
	st.Transparency = if Styles.reducedMotion() then 0.6 else 0.25
	st.Thickness = 16
	TweenService:Create(st, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { Transparency = 1, Thickness = 28 }):Play()
end

-- items: { id, pos: Vector2, size: number (px), onScreen, color, name, lockProgress, locked, hovered,
--          ringScale, bandScale, bandWidth, perfectScale, inWindow, perfect, tutorial, edge: Vector2?, edgeAngle }
function HUD:updateMarkers(items: { any })
	for i, m in self.markers do
		local it = items[i]
		local arrow = self.arrows[i]
		if not it then
			m.root.Visible = false
			arrow.Visible = false
			continue
		end
		if not it.onScreen then
			m.root.Visible = false
			arrow.Visible = it.edge ~= nil
			if it.edge then
				arrow.Position = UDim2.fromOffset(it.edge.X, it.edge.Y)
				arrow.Rotation = it.edgeAngle
				arrow.TextColor3 = it.color
			end
			continue
		end
		arrow.Visible = false
		m.root.Visible = true
		m.root.Position = UDim2.fromOffset(it.pos.X, it.pos.Y)
		-- lock acquired: the brackets snap in from wide (skipped under reduced motion)
		if it.locked and m.lockedId ~= it.id then
			m.lockedId = it.id
			m.lockPopT = os.clock()
		elseif not it.locked and m.lockedId == it.id then
			m.lockedId = nil
		end
		local popAge = os.clock() - (m.lockPopT or -10)
		local scale = if it.locked and popAge < 0.18 and not Styles.reducedMotion() then 1 + 0.6 * (1 - popAge / 0.18) ^ 2 else 1
		m.root.Size = UDim2.fromOffset(it.size * scale, it.size * scale)
		local bracketColor = if it.locked then (if it.inWindow then GREEN else C.Cyan) elseif it.hovered then WHITE else it.color
		for _, b in m.brackets do
			b.BackgroundColor3 = bracketColor
			b.BackgroundTransparency = if it.locked or it.hovered then 0 else 0.45
		end
		local showTiming = (it.locked or it.hovered or it.tutorial) and not it.telegraph and not it.phased
		m.ring.Visible = showTiming
		m.band.Visible = showTiming
		m.perfect.Visible = showTiming
		if showTiming then
			m.ring.Size = UDim2.fromScale(it.ringScale, it.ringScale)
			m.ringStroke.Color = if it.perfect then GOLD elseif it.inWindow then GREEN else WHITE
			m.ringStroke.Thickness = if it.inWindow then 4 else 2.5
			-- annulus [bandInner, bandOuter]: frame at the inner edge, stroke grows outwards
			m.band.Size = UDim2.fromScale(it.bandInner, it.bandInner)
			m.bandStroke.Thickness = math.max(2, (it.bandOuter - it.bandInner) * it.size / 2)
			m.bandStroke.Transparency = if it.inWindow then 0.25 else 0.6
			m.perfect.Size = UDim2.fromScale(it.perfectScale, it.perfectScale)
		end
		m.name.Text = it.name
		m.name.TextColor3 = it.color
		m.rarity.Text = it.rarityText or ""
		m.rarity.TextColor3 = it.rarityColor or it.color
		m.barBack.Visible = it.hovered and not it.locked and it.lockProgress > 0
		m.bar.Size = UDim2.fromScale(it.lockProgress, 1)
		if it.stateText then
			m.state.Text = it.stateText
			m.state.TextColor3 = it.stateColor or WHITE
		elseif it.locked then
			local em = it.emitter or "charged"
			if em == "charged" then
				m.state.Text = if it.perfect then "PERFECT — RELEASE!" elseif it.inWindow then "RELEASE NOW" else "LOCKED · WAIT FOR GREEN"
				m.state.TextColor3 = if it.perfect then GOLD elseif it.inWindow then GREEN else C.Cyan
			else
				m.state.Text = if em == "charging" then "LOCKED · CHARGING" elseif em == "ready" then "LOCKED · HOLD TO CHARGE" else "LOCKED"
				m.state.TextColor3 = C.Cyan
			end
		elseif it.hovered then
			m.state.Text = if it.lockProgress > 0 then "LOCKING…" else ""
			m.state.TextColor3 = WHITE
		else
			m.state.Text = ""
		end
	end
end

-- Pulse emitter state. e = { mode = "reload" | "ready" | "charging" | "charged" | "firing", frac (0..1:
-- reload progress or charge), remaining (s, reload) }
local DIM = Color3.fromRGB(170, 185, 205)
function HUD:setEmitter(e: any)
	local r = self.reticle
	local mode = e.mode
	local frac = math.clamp(e.frac or 0, 0, 1)
	r.cdBack.Visible = mode ~= "ready"
	r.cd.Size = UDim2.fromScale(frac, 1)
	r.cd.BackgroundColor3 = if mode == "charged" then GREEN elseif mode == "charging" then GOLD else C.Cyan
	local cs = if mode == "charging" or mode == "charged" then frac else 0
	r.charge.Visible = cs > 0
	r.charge.Size = UDim2.fromScale(0.25 + 0.75 * cs, 0.25 + 0.75 * cs)
	r.chargeStroke.Color = if mode == "charged" then GREEN else GOLD
	r.chargeStroke.Thickness = if mode == "charged" then 4 else 3
	local text, color
	if mode == "reload" then
		text, color = string.format("RELOADING  %.1fs", e.remaining or 0), DIM
	elseif mode == "firing" then
		text, color = "PULSE IN FLIGHT", C.Cyan
	elseif mode == "charging" then
		text, color = "CHARGING…", GOLD
	elseif mode == "charged" then
		text, color = "CHARGED · RELEASE ON GREEN", GREEN
	else
		text, color = e.readyText or "READY · HOLD TO CHARGE", WHITE
	end
	r.status.Text = text
	r.status.TextColor3 = color
	local fb = self.fireButton
	fb.Text = if mode == "reload" then string.format("%.1f", e.remaining or 0) elseif mode == "firing" then "…" elseif mode == "charging" then "HOLD" elseif mode == "charged" then "RELEASE" else "FIRE"
	local stroke = fb:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if mode == "charged" then GREEN elseif mode == "charging" then GOLD elseif mode == "ready" then C.Cyan else Color3.fromRGB(90, 100, 120)
	end
	fb.TextColor3 = if mode == "charged" then GREEN elseif mode == "charging" then GOLD elseif mode == "ready" then C.Cyan else DIM
end

-- Extra horizontal gap (px) between the reticle and its status line, so the status never sits on the
-- hovered / locked target's resonance ring.
function HUD:setStatusClearance(px: number)
	local x = 14 + math.floor(px)
	if x ~= self._statusX then
		self._statusX = x
		self.reticle.status.Position = UDim2.new(1, x, 0.5, -4)
		self.reticle.cdBack.Position = UDim2.new(1, x, 0.5, 6)
	end
end

-- One short line under the panel (newest wins): new reaction available, rare meteor inbound...
function HUD:notice(text: string, color: Color3?, seconds: number?)
	local n = self.noticeLabel
	n.Text = text
	n.TextColor3 = color or C.Text
	n.TextTransparency = 0
	n.TextStrokeTransparency = 0.35
	local token = {}
	self._noticeToken = token
	task.delay(seconds or 3.5, function()
		if self._noticeToken == token then
			TweenService:Create(n, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

function HUD:setEnergy(cur: number, cap: number, cost: number)
	self.energyText.Text = string.format("HARVEST ENERGY  %d / %d   (−%d per capture)", cur, cap, cost)
	self.energyBar.Size = UDim2.fromScale(math.clamp(cur / math.max(cap, 1), 0, 1), 1)
	self.energyBar.BackgroundColor3 = if cur < cost then RED else C.Violet
end

-- m = { [materialId] = amount } (all six planet materials)
function HUD:setMaterials(m: { [string]: number })
	self.matText.Text = string.format(
		'<font color="#96E1FF">● ICE %d</font>  <font color="#FF7828">● MAGMA %d</font>  <font color="#D26EFF">● PLASMA %d</font>\n<font color="#FF96E6">● CRYSTAL %d</font>  <font color="#78FF8C">● BIO %d</font>  <font color="#FFE678">● CATALYST %d</font>',
		m.IceMatter or 0,
		m.MagmaMatter or 0,
		m.PlasmaMatter or 0,
		m.CrystalFragments or 0,
		m.BioEssence or 0,
		m.CosmicCatalyst or 0
	)
end

function HUD:setSession(captures: number, focusStacks: number)
	self.sessionText.Text = "Captures this session: " .. captures
	self.focusText.Text = if focusStacks > 0 then string.rep("◆", focusStacks) .. "  FOCUS: wider lock + earlier window" else ""
end

function HUD:flash(text: string, color: Color3, sub: string?)
	local f, s = self.feedback, self.feedbackSub
	f.Text = text
	f.TextColor3 = color
	s.Text = sub or ""
	s.TextColor3 = C.Text
	f.TextTransparency = 0
	s.TextTransparency = 0
	f.Size = UDim2.fromOffset(760, 64)
	TweenService:Create(f, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(700, 56) }):Play()
	local token = {}
	self._flashToken = token
	task.delay(1.1, function()
		if self._flashToken == token then
			TweenService:Create(f, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
			TweenService:Create(s, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		end
	end)
end

function HUD:popup(text: string, color: Color3, pos: Vector2?)
	local s = self.scale.Scale
	local p = (pos or Vector2.new(self.gui.AbsoluteSize.X / 2, self.gui.AbsoluteSize.Y * 0.42)) / s
	local l = label(self.popups, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(p.X, p.Y), Size = UDim2.fromOffset(360, 30), TextSize = 26, Font = Enum.Font.GothamBlack, Text = text, TextColor3 = color, TextStrokeTransparency = 0.3 })
	TweenService:Create(l, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(p.X, p.Y - 90), TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(1.5, function()
		l:Destroy()
	end)
end

function HUD:setTutorial(text: string?, step: string?)
	self.tutorial.Visible = text ~= nil
	if text then
		self.tutText.Text = text
		self.tutStep.Text = step or ""
	end
end

function HUD:setHints(device: string)
	if device == "gamepad" then
		self.hints.Text = "Sticks: aim   •   Hold on a target: lock   •   Hold RT / A: charge, release: fire   •   RB: next   •   B: exit"
		self.exitButton.Text = "EXIT  [B]"
	elseif device == "touch" then
		self.hints.Text = "Drag to aim   •   Hold on a target to lock   •   Hold FIRE to charge, release on green"
		self.exitButton.Text = "EXIT"
	else
		self.hints.Text = "Mouse / arrows: aim   •   Hold on a target: lock   •   Hold Click / Space: charge, release: fire   •   R: next   •   Q: exit"
		self.exitButton.Text = "EXIT  [Q]"
	end
	self.touch.Visible = device == "touch"
end

function HUD:setFireReady(ready: boolean)
	self.fireButton.BackgroundTransparency = if ready then 0.15 else 0.55
end

function HUD:setBanner(text: string?)
	self.banner.Visible = text ~= nil
	if text then
		self.bannerText.Text = text
	end
end

function HUD:showToast(text: string, color: Color3?)
	local t = self.toast
	t.Text = text
	t.TextColor3 = color or C.Text
	t.TextTransparency = 0
	t.TextStrokeTransparency = 0.3
	local token = {}
	self._toastToken = token
	task.delay(2.5, function()
		if self._toastToken == token then
			TweenService:Create(t, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

HUD.COLORS = { GREEN = GREEN, GOLD = GOLD, RED = RED, WHITE = WHITE, CYAN = C.Cyan, VIOLET = C.Violet }

return HUD
