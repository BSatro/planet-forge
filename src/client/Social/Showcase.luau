--!strict
-- Showcase — owner: Live Gameplay (client). PLANET SHOWCASE: cinematic orbit camera around any claimed planet
-- (CameraController.setShowcase) with a letterboxed overlay: planet, owner, stage, branch, discovered formations
-- (read-only), reactions and a Visit button. The character is never moved; movement input is paused while the
-- showcase is open. Close: button, Backspace or gamepad B. Drag / right stick to orbit, wheel to zoom.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = UI:WaitForChild("Kit")
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(UI.UIRoot)
local UIData = require(UI.UIData)
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)
local PlanetInfo = require(script.Parent.PlanetInfo)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local Showcase = {}
local deps: any = {}
local ui: any = {}
local current: number? = nil
local openedAt = 0
local conn: RBXScriptConnection? = nil

local SINK_KEYS = {
	Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left,
	Enum.KeyCode.Right, Enum.KeyCode.Space, Enum.KeyCode.Thumbstick1, Enum.KeyCode.ButtonA,
}

local function build()
	local layer = UIRoot.layer("Overlay")
	local root = C.make("Frame", { Name = "PlanetShowcase", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = layer })
	local top = C.make("Frame", { Name = "BarTop", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.05, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.1, 0), Parent = root })
	local bottom = C.make("Frame", { Name = "BarBottom", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.05, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0.1, 0), Parent = root })
	C.gradient(Color3.new(1, 1, 1), Color3.new(1, 1, 1), 90, 0, 1).Parent = top
	C.gradient(Color3.new(1, 1, 1), Color3.new(1, 1, 1), 90, 1, 0).Parent = bottom
	C.text({ text = "PLANET SHOWCASE", size = S.Micro, font = F.Display, color = Col.TextMute, align = Enum.TextXAlignment.Center, parent = top, dims = UDim2.new(1, 0, 0, 16) }).Position = UDim2.new(0, 0, 0.5, -8)

	local card = C.glass({ name = "Info", variant = "panel", brackets = true, anchor = Vector2.new(0, 1), pos = UDim2.new(0, Sp.xl, 0.9, -Sp.m), dims = UDim2.fromOffset(420, 0), parent = root })
	card.AutomaticSize = Enum.AutomaticSize.Y
	local inner = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
	ui.caption = C.caption("Planet", inner, 1, Col.Cyan)
	ui.title = C.text({ text = "", size = 24, font = F.Display, parent = inner, order = 2, dims = UDim2.new(1, 0, 0, 30) })
	ui.owner = C.text({ text = "", size = S.Body, font = F.Bold, color = Col.TextDim, parent = inner, order = 3, autoY = true })
	local chips = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 4, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, 6) })
	ui.stageChip = C.chip("", Col.Cyan, chips, 1)
	ui.branchChip = C.chip("", Col.Magenta, chips, 2)
	C.caption("Discovered formations", inner, 5)
	local forms = C.make("Frame", { Name = "Formations", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6, Parent = inner })
	local fl = C.list(Enum.FillDirection.Horizontal, 6)
	fl.Wraps = true
	fl.Parent = forms
	ui.formPool = C.pool(function()
		return C.chip("", Col.Cyan, forms)
	end)
	ui.noForms = C.text({ text = "No formations yet — a fresh world.", size = S.Small, color = Col.TextMute, parent = inner, order = 7, autoY = true })
	C.divider(inner, 8)
	local reactRow = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 9, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, 6) })
	ui.react = {}
	for i, k in EventConfig.SOCIAL.reactionOrder do
		local r = EventConfig.SOCIAL.reactions[k]
		ui.react[k] = C.button({ text = r.label, icon = r.icon, style = "ghost", dims = UDim2.fromOffset(122, 32), size = S.Micro, parent = reactRow, order = i, onClick = function()
			Showcase._react(k)
		end })
	end
	ui.reactNote = C.text({ text = "", size = S.Micro, color = Col.TextMute, parent = inner, order = 10, autoY = true })
	local actions = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 11, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
	ui.visit = C.button({ text = "Visit this planet", icon = "travel", style = "solid", dims = UDim2.fromOffset(190, 34), parent = actions, order = 1, onClick = function()
		Showcase._visit()
	end })
	C.button({ text = "Close", icon = "close", style = "ghost", dims = UDim2.fromOffset(120, 34), parent = actions, order = 2, onClick = function()
		Showcase.close()
	end })
	C.text({ text = "Drag to orbit · wheel to zoom · Backspace / B to close", size = S.Micro, color = Col.TextMute, align = Enum.TextXAlignment.Center, parent = bottom, dims = UDim2.new(1, 0, 0, 16) }).Position = UDim2.new(0, 0, 0.5, -8)
	ui.root = root
end

local function refresh()
	local slot = current
	if not slot then
		return
	end
	local info = PlanetInfo.get(slot)
	if not info then
		Showcase.close()
		UIRoot.toast("That planet is no longer claimed.", "info", "planet")
		return
	end
	ui.caption.Text = if info.own then "YOUR PLANET" else "EXPLORER PLANET"
	ui.title.Text = string.format("PLANET %02d", info.slot)
	ui.owner.Text = string.format("%s's world%s", info.ownerName, if info.visitors > 0 then string.format("  ·  %d visitor(s) now", info.visitors) else "")
	C.setChip(ui.stageChip, string.format("Stage %d · %s", info.stage, info.stageName), Col.Cyan)
	C.setChip(ui.branchChip, info.branchName, info.branchColor)
	ui.formPool:sync(math.min(#info.formations, 12), function(chip, i)
		local f = info.formations[i]
		C.setChip(chip, if f.count > 1 then string.format("%s ×%d", f.name, f.count) else f.name, f.color)
	end)
	ui.noForms.Visible = #info.formations == 0
	local held = os.clock() - openedAt
	local wait = EventConfig.SOCIAL.showcaseHold - held
	for k, b in ui.react do
		local r = EventConfig.SOCIAL.reactions[k]
		b:setText(string.format("%s %d", r.label, info.reactions[k] or 0))
		b:setStyle(if info.mine == k then "solid" else "ghost")
		b:setEnabled(not info.own and wait <= 0, if info.own then "Your own planet" else nil)
	end
	ui.reactNote.Text = if info.own then "Other explorers can react to your planet from here or when visiting." elseif wait > 0 then string.format("Take a look… reactions unlock in %d s", math.ceil(wait)) else "One reaction per planet per server session — you can change it."
	ui.visit.Instance.Visible = not info.own and PlanetInfo.currentSlot() ~= info.slot
end

function Showcase._react(kind: string)
	local slot = current
	if not slot then
		return
	end
	task.spawn(function()
		local ok, code = PlanetInfo.react(slot, kind)
		if ok then
			UIRoot.toast("Reaction sent: " .. EventConfig.SOCIAL.reactions[kind].label, "success", "star")
			UIRoot.sfx("Power_Up", 0.3, 1.4)
		else
			UIRoot.toast(PlanetInfo.reasonText(code), "info", "star")
		end
		refresh()
	end)
end

function Showcase._visit()
	local slot = current
	if not slot then
		return
	end
	Showcase.close()
	task.spawn(function()
		local ok, code = PlanetInfo.visit(slot)
		if not ok then
			UIRoot.toast("Visit: " .. PlanetInfo.reasonText(code), "info", "travel")
		end
	end)
end

function Showcase.isOpen(): boolean
	return current ~= nil
end

function Showcase.open(slot: number)
	local cam = deps.camera
	if not cam or not cam.setShowcase then
		return
	end
	if UIData.isHarvesting() or player:GetAttribute("PFInRiftLocal") == true then
		UIRoot.toast("The showcase is unavailable right now.", "info", "camera")
		return
	end
	local info = PlanetInfo.get(slot)
	if not info then
		UIRoot.toast("Nobody owns that planet right now.", "info", "planet")
		return
	end
	if current then
		Showcase.close()
	end
	current = slot
	openedAt = os.clock()
	UIRoot.close()
	UIRoot.setHudHidden("showcase", true)
	cam.setShowcase(info.center, info.radius)
	ContextActionService:BindActionAtPriority("PF_ShowcaseSink", function()
		return Enum.ContextActionResult.Sink
	end, false, 3000, table.unpack(SINK_KEYS))
	ContextActionService:BindActionAtPriority("PF_ShowcaseExit", function(_, state)
		if state == Enum.UserInputState.Begin then
			Showcase.close()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3001, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
	ui.root.Visible = true
	UIRoot.sfx("Whoosh", 0.35, 0.8)
	task.spawn(function()
		PlanetInfo.showcaseToken(slot) -- the server notes the view (reactions from the showcase need a few seconds)
		refresh()
	end)
	refresh()
	local acc = 0
	conn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.5 then
			acc = 0
			refresh()
		end
	end)
end

function Showcase.close()
	if not current then
		return
	end
	current = nil
	if conn then
		conn:Disconnect()
		conn = nil
	end
	ContextActionService:UnbindAction("PF_ShowcaseSink")
	ContextActionService:UnbindAction("PF_ShowcaseExit")
	if deps.camera and deps.camera.clearShowcase then
		deps.camera.clearShowcase()
	end
	UIRoot.setHudHidden("showcase", false)
	ui.root.Visible = false
end

function Showcase.init(d: any?)
	deps = d or {}
	build()
	player:GetAttributeChangedSignal("PFInRiftLocal"):Connect(function()
		if player:GetAttribute("PFInRiftLocal") == true then
			Showcase.close()
		end
	end)
	player.CharacterRemoving:Connect(function()
		Showcase.close()
	end)
end

return Showcase
