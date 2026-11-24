--!strict
-- ForgeBot — owner: UX (First 10 Minutes 2.0). The small, friendly guide robot of PLANET FORGE.
--   * Presentation only: it never decides progress. Onboarding (the single step source) and real, server-confirmed
--     events (harvest results, transformations) tell it what to say.
--   * Lives in the interface (portrait + speech bubble, bottom-left), never in the 3D world: it cannot block the
--     camera, the harvester lane or clicks (only its small close / action buttons take input).
--   * Short lines, each said at most once per session (id), auto-hide after a reading time, max 3 queued.
--   * Hidden while a modal screen is open; optional (Settings -> Guidance -> ForgeBot hints, Prefs "ForgeBot").
--   * Reduced motion: no bob / hop / typewriter; the robot is still.
-- API: say(text, opts?) · dismiss() · resetMemory() · setEnabled(on) · isEnabled() · isShowing()
--      opts = { id?, mood? = "idle"|"happy"|"point"|"celebrate", duration?, priority?, actionText?, action? }
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local Prefs = require(Kit.Prefs)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local ForgeBot = {}

type Msg = { text: string, id: string?, mood: string, duration: number, priority: number, actionText: string?, action: (() -> ())?, group: string? }

local ui: any = {}
local seen: { [string]: boolean } = {}
local queue: { Msg } = {}
local current: Msg? = nil
local token = 0
local mood = "idle"
local moodAt = 0
local talkingUntil = 0

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function reduced(): boolean
	return Prefs.reducedMotion()
end

----------------------------------------------------------------------------------------------------
-- the robot (built once, rendered in a ViewportFrame; procedural, no uploaded assets)
local WHITE, NAVY, VIOLET, CYAN = rgb(236, 241, 252), rgb(14, 20, 48), rgb(124, 86, 216), rgb(86, 232, 255)

local function part(parent: Instance, props: { [string]: any }): BasePart
	local cls = props.ClassName or "Part"
	local p = Instance.new(cls) :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		if k ~= "ClassName" and k ~= "Mesh" then
			(p :: any)[k] = v
		end
	end
	if props.Mesh then
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.Sphere
		m.Scale = props.Mesh
		m.Parent = p
	end
	p.Parent = parent
	return p
end

local function buildRobot(world: WorldModel): any
	local r: any = { parts = {} }
	local root = Instance.new("Model")
	root.Name = "ForgeBot"
	-- body + thruster
	r.body = part(root, { Name = "Body", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.15, CFrame = CFrame.new(0, -1.42, 0), Color = WHITE })
	r.chest = part(root, { Name = "Chest", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.24, CFrame = CFrame.new(0, -1.36, -0.53), Color = CYAN, Material = Enum.Material.Neon })
	r.armL = part(root, { Name = "ArmL", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.4, CFrame = CFrame.new(-0.66, -1.42, -0.05), Color = VIOLET })
	r.armR = part(root, { Name = "ArmR", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.4, CFrame = CFrame.new(0.66, -1.42, -0.05), Color = VIOLET })
	r.jet = part(root, { Name = "Jet", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.08, 0.56, 0.56), CFrame = CFrame.new(0, -2.05, 0) * CFrame.Angles(0, 0, math.pi / 2), Color = CYAN, Material = Enum.Material.Neon, Transparency = 0.35 })
	-- head group
	local head = Instance.new("Model")
	head.Name = "Head"
	head.Parent = root
	r.head = head
	part(head, { Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * 2.3, CFrame = CFrame.new(0, 0, 0), Color = WHITE })
	part(head, { Name = "Visor", Size = Vector3.one * 2.3, CFrame = CFrame.new(0, -0.02, -0.72), Color = NAVY, Mesh = Vector3.new(0.82, 0.62, 0.56), Reflectance = 0.08 })
	r.eyeL = part(head, { Name = "EyeL", Size = Vector3.new(0.36, 0.46, 0.2), CFrame = CFrame.new(-0.38, 0.1, -1.33), Color = CYAN, Material = Enum.Material.Neon, Mesh = Vector3.new(1, 1, 1) })
	r.eyeR = part(head, { Name = "EyeR", Size = Vector3.new(0.36, 0.46, 0.2), CFrame = CFrame.new(0.38, 0.1, -1.33), Color = CYAN, Material = Enum.Material.Neon, Mesh = Vector3.new(1, 1, 1) })
	r.smile = {
		part(head, { Name = "Smile", Size = Vector3.new(0.34, 0.07, 0.06), CFrame = CFrame.new(0, -0.34, -1.3), Color = CYAN, Material = Enum.Material.Neon }),
		part(head, { Name = "SmileL", Size = Vector3.new(0.16, 0.07, 0.06), CFrame = CFrame.new(-0.22, -0.29, -1.29) * CFrame.Angles(0, 0, math.rad(-28)), Color = CYAN, Material = Enum.Material.Neon }),
		part(head, { Name = "SmileR", Size = Vector3.new(0.16, 0.07, 0.06), CFrame = CFrame.new(0.22, -0.29, -1.29) * CFrame.Angles(0, 0, math.rad(28)), Color = CYAN, Material = Enum.Material.Neon }),
	}
	for side = -1, 1, 2 do
		part(head, { Name = "Ear", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.34, 0.78, 0.78), CFrame = CFrame.new(side * 1.12, 0, 0), Color = VIOLET })
		part(head, { Name = "EarGlow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.36, 0.42, 0.42), CFrame = CFrame.new(side * 1.13, 0, 0), Color = CYAN, Material = Enum.Material.Neon })
	end
	part(head, { Name = "Antenna", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.55, 0.07, 0.07), CFrame = CFrame.new(0, 1.32, 0) * CFrame.Angles(0, 0, math.pi / 2), Color = rgb(200, 206, 226) })
	r.tip = part(head, { Name = "Tip", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.2, CFrame = CFrame.new(0, 1.62, 0), Color = CYAN, Material = Enum.Material.Neon })
	root.Parent = world
	r.root = root
	r.headBase = head:GetPivot()
	head.WorldPivot = CFrame.new(0, -0.9, 0) -- tilt around the neck
	r.headBase = head:GetPivot()
	r.bodyParts = { r.body, r.chest, r.armL, r.armR, r.jet }
	r.bodyBase = {}
	for i, p in r.bodyParts do
		r.bodyBase[i] = p.CFrame
	end
	r.eyeSize = r.eyeL.Size
	return r
end

----------------------------------------------------------------------------------------------------
local function layout()
	if not ui.root then
		return
	end
	local size = UIRoot.size()
	local mode = UIRoot.mode()
	local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local width = math.min(420, size.X - 2 * Sp.l)
	if mode ~= "wide" and not UIData.isHarvesting() then
		-- phones (short / narrow): the left column already fills the height -> top-right corner, under the
		-- Roblox top bar (free there: resources live in the left column in these modes)
		width = math.min(380, math.floor(size.X * 0.46))
		ui.root.AnchorPoint = Vector2.new(1, 0)
		ui.root.Position = UDim2.fromOffset(size.X - Sp.m, 52)
	else
		-- bottom-left, clear of the mobile thumbstick (tablets) and of the harvest hints
		local bottomGap = if touch and not UIData.isHarvesting() then 190 else Sp.l
		ui.root.AnchorPoint = Vector2.new(0, 1)
		ui.root.Position = UDim2.fromOffset(Sp.l, size.Y - bottomGap)
	end
	ui.root.Size = UDim2.fromOffset(width, 0)
end

local function build()
	local layer = UIRoot.layer("Toast")
	local root = C.make("Frame", { Name = "ForgeBot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Active = false, Parent = layer })
	ui.root = root
	-- portrait
	local port = C.make("Frame", { Name = "Portrait", BackgroundColor3 = Col.Navy, BackgroundTransparency = 0.1, Size = UDim2.fromOffset(84, 84), Position = UDim2.fromOffset(0, 0), Parent = root }, { C.corner(42), C.stroke(Col.Cyan, 0.25, 2) })
	C.gradient(rgb(40, 56, 120), Col.VioletDeep, 90).Parent = port
	ui.portrait = port
	local vpf = C.make("ViewportFrame", { Name = "View", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Ambient = rgb(150, 160, 196), LightColor = Color3.new(1, 1, 1), LightDirection = Vector3.new(-0.45, -1, 0.55), Parent = port }, { C.corner(42) })
	local world = Instance.new("WorldModel")
	world.Parent = vpf
	local cam = Instance.new("Camera")
	cam.FieldOfView = 34
	cam.CFrame = CFrame.lookAt(Vector3.new(1.1, 0.2, -6.1), Vector3.new(0, -0.45, 0))
	cam.Parent = vpf
	vpf.CurrentCamera = cam
	ui.robot = buildRobot(world)
	-- speech bubble
	local bubble = C.glass({ name = "Bubble", variant = "panel", dims = UDim2.new(1, -96, 0, 0), pos = UDim2.fromOffset(96, 0), parent = root })
	bubble.AutomaticSize = Enum.AutomaticSize.Y
	C.pad(Sp.s + 2, Sp.l + 18, Sp.m, Sp.l).Parent = bubble
	C.list(Enum.FillDirection.Vertical, 4).Parent = bubble
	local st = bubble:FindFirstChildOfClass("UIStroke")
	if st then
		st.Transparency = 0.3
	end
	-- little tail toward the portrait (outside the bubble's list layout)
	C.make("Frame", { Name = "Tail", BackgroundColor3 = Col.Panel, BackgroundTransparency = 0.08, Size = UDim2.fromOffset(12, 12), Position = UDim2.fromOffset(90, 34), Rotation = 45, Parent = root })
	ui.name = C.caption("FORGEBOT", bubble, 1, Col.Cyan)
	ui.text = C.text({ name = "Line", text = "", size = S.Body, font = F.Semi, color = Col.Text, autoY = true, parent = bubble, order = 2 })
	ui.action = C.button({ text = "", style = "primary", dims = UDim2.new(0, 0, 0, 28), size = S.Micro, parent = bubble, order = 3, onClick = function()
		local m = current
		if m and m.action then
			m.action()
		end
		ForgeBot.dismiss()
	end })
	ui.action.Instance.AutomaticSize = Enum.AutomaticSize.X
	ui.action.Instance.Visible = false
	local close = C.make("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 6), Size = UDim2.fromOffset(22, 22), ZIndex = 5, Parent = root })
	C.icon("close", 12, Col.TextMute, close).Position = UDim2.fromOffset(5, 5)
	close.Activated:Connect(function()
		ForgeBot.dismiss()
	end)
	ui.bubble = bubble
	ui.scale = C.make("UIScale", { Scale = 1, Parent = root })
	layout()
	UIRoot.Resized:Connect(layout)
	UIData.HarvestingChanged:Connect(function()
		layout()
	end)
end

----------------------------------------------------------------------------------------------------
-- animation (only while visible)
local t = 0
local nextBlink = 3
local function animate(dt: number)
	local r = ui.robot
	if not (ui.root and ui.root.Visible and r) then
		return
	end
	t += dt
	if reduced() then
		return
	end
	local m = mood
	local since = os.clock() - moodAt
	-- body bob + hop on celebrate
	local hop = if m == "celebrate" and since < 1.2 then math.abs(math.sin(since * 7)) * 0.35 * (1 - since / 1.2) else 0
	local bob = math.sin(t * 2.2) * 0.07 + hop
	for i, base in r.bodyBase do
		r.bodyParts[i].CFrame = base + Vector3.new(0, bob, 0)
	end
	-- head: idle sway, happy tilt, point lean, celebrate wiggle
	local yaw = math.sin(t * 0.7) * 0.12
	local roll = if m == "happy" then 0.16 elseif m == "point" then -0.1 else math.sin(t * 0.9) * 0.04
	local pitch = if m == "point" then -0.12 else 0
	if m == "celebrate" and since < 1.2 then
		roll = math.sin(since * 14) * 0.2
	end
	r.head:PivotTo(r.headBase * CFrame.new(0, bob, 0) * CFrame.Angles(pitch, yaw, roll))
	-- blink
	if t >= nextBlink then
		local k = (t - nextBlink) / 0.14
		local sy = if k < 1 then math.max(0.12, math.abs(1 - 2 * k)) else 1
		r.eyeL.Size = Vector3.new(r.eyeSize.X, r.eyeSize.Y * sy, r.eyeSize.Z)
		r.eyeR.Size = r.eyeL.Size
		if k >= 1 then
			nextBlink = t + 2.5 + (t * 7.3 % 2.5)
		end
	end
	-- talking: smile pulses while the line is typed
	local talk = os.clock() < talkingUntil
	local sc = if talk then 1 + 0.6 * math.abs(math.sin(t * 16)) else 1
	r.smile[1].Size = Vector3.new(0.34, 0.07 * sc, 0.06)
	r.tip.Transparency = if talk then 0.1 * math.abs(math.sin(t * 9)) else 0
end

----------------------------------------------------------------------------------------------------
local function readingTime(text: string): number
	return math.clamp(2.6 + #text * 0.045, 4, 9)
end

local showNext: () -> ()

local function present(m: Msg)
	current = m
	token += 1
	local my = token
	mood, moodAt = m.mood, os.clock()
	ui.text.Text = m.text
	ui.action.Instance.Visible = m.actionText ~= nil
	if m.actionText then
		ui.action:setText(m.actionText)
	end
	local root = ui.root :: Frame
	root.Visible = true
	if reduced() then
		ui.text.MaxVisibleGraphemes = -1
		ui.scale.Scale = 1
	else
		ui.scale.Scale = 0.85
		Motion.tween(ui.scale, 0.28, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, "forgebot")
		-- typewriter (fast; never gates progress)
		local n = utf8.len(m.text) or #m.text
		local dur = math.clamp(n * 0.018, 0.25, 1.1)
		talkingUntil = os.clock() + dur
		task.spawn(function()
			local t0 = os.clock()
			while token == my and os.clock() - t0 < dur do
				ui.text.MaxVisibleGraphemes = math.floor(n * (os.clock() - t0) / dur)
				task.wait()
			end
			if token == my then
				ui.text.MaxVisibleGraphemes = -1
			end
		end)
	end
	UIRoot.sfx("Bot_Blip")
	task.delay(m.duration, function()
		if token == my then
			ForgeBot.dismiss(true)
		end
	end)
end

showNext = function()
	if current or #queue == 0 or not ForgeBot.isEnabled() then
		return
	end
	if UIRoot.modalOpen() then
		return -- resumes when the modal closes
	end
	present(table.remove(queue, 1) :: Msg)
end

function ForgeBot.say(text: string, opts: any?): boolean
	local o = opts or {}
	if not ui.root or not ForgeBot.isEnabled() or type(text) ~= "string" or text == "" then
		return false
	end
	if o.id then
		if seen[o.id] then
			return false
		end
		seen[o.id] = true
	end
	local m: Msg = { text = text, id = o.id, mood = o.mood or "idle", duration = o.duration or readingTime(text), priority = o.priority or 1, actionText = o.actionText, action = o.action, group = o.group }
	if m.group then
		ForgeBot.dropGroup(m.group) -- a newer hint of the same kind supersedes queued ones (never stale advice)
	end
	if current and m.priority > (current :: Msg).priority then
		-- a more important line (a real achievement) replaces a hint
		table.insert(queue, 1, current :: Msg)
		current = nil
		present(m)
	else
		table.insert(queue, m)
		while #queue > 3 do
			table.remove(queue, 1)
		end
		showNext()
	end
	return true
end

function ForgeBot.dismiss(auto: boolean?)
	token += 1
	current = nil
	if ui.root and ui.root.Visible then
		if reduced() then
			ui.root.Visible = false
		else
			Motion.tween(ui.scale, 0.16, { Scale = 0.85 }, nil, nil, "forgebot")
			local my = token
			task.delay(0.16, function()
				if token == my and not current then
					ui.root.Visible = false
				end
			end)
		end
	end
	if auto then
		task.delay(0.5, showNext)
	else
		table.clear(queue) -- the player closed it: drop the pending hints too
	end
end

-- remove queued (not yet shown) lines of a group, e.g. "step" hints once the step is done
function ForgeBot.dropGroup(group: string)
	for i = #queue, 1, -1 do
		if queue[i].group == group then
			table.remove(queue, i)
		end
	end
end

function ForgeBot.resetMemory()
	table.clear(seen)
end

function ForgeBot.hasSaid(id: string): boolean
	return seen[id] == true
end

function ForgeBot.isEnabled(): boolean
	return Prefs.get("ForgeBot") ~= false
end

function ForgeBot.setEnabled(on: boolean)
	Prefs.set("ForgeBot", on)
end

function ForgeBot.isShowing(): boolean
	return current ~= nil
end

function ForgeBot.init()
	if ui.root then
		return
	end
	build()
	RunService.RenderStepped:Connect(animate)
	Prefs.Changed:Connect(function(key, value)
		if key == "ForgeBot" and value == false then
			ForgeBot.dismiss()
		end
	end)
	-- hide behind modal screens (evolution reveal, confirms), resume afterwards
	task.spawn(function()
		while true do
			task.wait(0.25)
			local modal = UIRoot.modalOpen()
			if modal and ui.root.Visible then
				ui.root.Visible = false
			elseif not modal and current and not ui.root.Visible then
				ui.root.Visible = true
			elseif not modal and not current then
				showNext()
			end
		end
	end)
	local _ = player
end

return ForgeBot
