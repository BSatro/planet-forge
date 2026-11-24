--!strict
-- UIRoot — owner: Developer A. The single PLANET FORGE interface root (ScreenGui "PF_UI", ResetOnSpawn = false,
-- so nothing is rebuilt or duplicated on respawn). Provides:
--   * responsive design canvas: layouts are authored in design units (Theme.Canvas) and scaled to the screen;
--     modes "wide" | "narrow" (portrait / small width) | "short" (phone landscape)
--   * layers: Hud < Scrim < Panels < Modal < Toast < Tooltip
--   * panel manager: one panel open at a time, lazily built once, hotkeys, gamepad ButtonB/back, focus handling
--   * toasts and a reusable confirm dialog
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local Motion = require(Kit.Motion)
local Prefs = require(Kit.Prefs)
local C = require(Kit.Components)
local Signal = require(game:GetService("ReplicatedStorage").PF_Shared.Util.Signal)
local okSfx, Sfx = pcall(function()
	return require(script.Parent.Parent.Audio.Sfx)
end)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer

local UIRoot = {}
UIRoot.Resized = Signal.new() -- (canvasSize: Vector2, mode: string)
UIRoot.PanelChanged = Signal.new() -- (openId: string?)
UIRoot.HudVisibilityChanged = Signal.new() -- (visible)

local gui: ScreenGui
local canvas: Frame
local uiScale: UIScale
local layers: { [string]: Frame } = {}
local canvasSize = Vector2.new(Theme.Canvas.width, Theme.Canvas.height)
local mode = "wide"

export type PanelDef = {
	id: string,
	title: string,
	icon: string,
	hotkey: Enum.KeyCode?,
	hotkeyLabel: string?,
	gamepadKey: Enum.KeyCode?,
	build: (shell: any) -> any, -- returns { refresh?, onOpen?, onClose?, layout?(size, mode), firstSelection?() -> GuiObject? }
	available: (() -> boolean)?,
}
local defs: { [string]: PanelDef } = {}
local built: { [string]: any } = {}
local openId: string? = nil
local hudHidden: { [string]: boolean } = {}
local lastInputGamepad = false

----------------------------------------------------------------------------------------------------
-- responsive scale
local forcedTouch: boolean? = nil
local function computeScale(vp: Vector2): number
	local touchOnly = if forcedTouch ~= nil then forcedTouch else (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
	local minScale = if touchOnly then 0.9 else Theme.Canvas.minScale
	local s = math.min(vp.X / Theme.Canvas.width, vp.Y / Theme.Canvas.height)
	return math.clamp(s, minScale, Theme.Canvas.maxScale) * (Prefs.get("UiScale") or 1)
end

-- Exposed for tests: lay the canvas out as if the screen were `vp` pixels (nil = real screen).
local forcedViewport: Vector2? = nil
function UIRoot.relayout(vp: Vector2?, touch: boolean?)
	if vp ~= nil then
		forcedViewport = vp
		forcedTouch = touch
	end
	local real = gui and gui.AbsoluteSize or Vector2.new(1280, 740)
	local view = forcedViewport or real
	local s = computeScale(view)
	uiScale.Scale = s
	canvasSize = Vector2.new(math.floor(view.X / s), math.floor(view.Y / s))
	canvas.Size = UDim2.fromOffset(canvasSize.X, canvasSize.Y)
	mode = if canvasSize.X < Theme.Canvas.narrowBelow then "narrow" elseif canvasSize.Y < Theme.Canvas.shortBelow then "short" else "wide"
	UIRoot.Resized:Fire(canvasSize, mode)
	for id, p in built do
		if p.layout then
			pcall(p.layout, canvasSize, mode)
		end
	end
end
function UIRoot.clearForcedViewport()
	forcedViewport = nil
	forcedTouch = nil
	UIRoot.relayout(nil)
end

function UIRoot.size(): Vector2
	return canvasSize
end
function UIRoot.mode(): string
	return mode
end
function UIRoot.layer(name: string): Frame
	return layers[name]
end
function UIRoot.gui(): ScreenGui
	return gui
end
function UIRoot.isGamepad(): boolean
	return lastInputGamepad
end

function UIRoot.sfx(name: string, volume: number?, pitch: number?)
	if okSfx and Sfx then
		pcall(Sfx.play, name, { volume = volume, pitch = pitch })
	end
end

----------------------------------------------------------------------------------------------------
-- HUD visibility (harvesting, cinematic screens hide it)
function UIRoot.setHudHidden(reason: string, hidden: boolean)
	hudHidden[reason] = if hidden then true else nil
	local visible = next(hudHidden) == nil
	local hud = layers.Hud
	if hud and hud.Visible ~= visible then
		hud.Visible = visible
		UIRoot.HudVisibilityChanged:Fire(visible)
	end
end
function UIRoot.hudVisible(): boolean
	return next(hudHidden) == nil
end

----------------------------------------------------------------------------------------------------
-- panel shell: title bar + close + content; shared look for every panel
local function makeShell(def: PanelDef)
	local root = C.glass({ name = "Panel_" .. def.id, variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5), dims = UDim2.fromOffset(940, 600), parent = layers.Panels })
	root.Visible = false
	root.Active = true
	-- top notch accent (reference: holographic frame tab)
	C.make("Frame", { Name = "Notch", BackgroundColor3 = Col.Cyan, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -1), Size = UDim2.fromOffset(120, 3), Parent = root }, { C.corner(2) })
	local header = C.make("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), Parent = root }, { C.pad(0, Sp.l, 0, Sp.xl) })
	local icon = C.icon(def.icon, 22, Col.Cyan, header)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	local title = C.text({ name = "Title", text = string.upper(def.title), size = S.Title, font = F.Display, color = Col.Text, parent = header, dims = UDim2.new(1, -120, 0, 26) })
	title.Position = UDim2.new(0, 34, 0.5, -13)
	local sub = C.text({ name = "Subtitle", text = "", size = S.Small, color = Col.TextMute, parent = header, dims = UDim2.new(0.5, 0, 0, 20), align = Enum.TextXAlignment.Right })
	sub.AnchorPoint = Vector2.new(1, 0.5)
	sub.Position = UDim2.new(1, -52, 0.5, 0)
	local close = C.button({ icon = "close", iconOnly = true, style = "ghost", dims = UDim2.fromOffset(36, 36), parent = header, tooltip = if def.hotkeyLabel then string.format("Close  [%s]", def.hotkeyLabel) else "Close", onClick = function()
		UIRoot.close()
	end })
	close.Instance.AnchorPoint = Vector2.new(1, 0.5)
	close.Instance.Position = UDim2.new(1, 0, 0.5, 0)
	C.divider(root).Position = UDim2.fromOffset(0, 56)
	local body = C.make("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 57), Size = UDim2.new(1, 0, 1, -57), ClipsDescendants = true, Parent = root }, { C.pad(Sp.l, Sp.xl, Sp.l, Sp.xl) })
	return { Instance = root, Body = body, Title = title, Subtitle = sub, Close = close, def = def }
end

local function fitShell(shell)
	local margin = if mode == "wide" then 48 else 10
	local topReserve = if mode == "narrow" then 8 else 8
	local w = math.min(980, canvasSize.X - margin * 2)
	local h = math.min(640, canvasSize.Y - margin - topReserve)
	if mode ~= "wide" then
		w = canvasSize.X - margin * 2
		h = canvasSize.Y - margin * 2
	end
	shell.Instance.Size = UDim2.fromOffset(w, h)
	shell.size = Vector2.new(w, h)
end

----------------------------------------------------------------------------------------------------
function UIRoot.registerPanel(def: PanelDef)
	defs[def.id] = def
end

function UIRoot.isAvailable(id: string): boolean
	local d = defs[id]
	return d ~= nil and (d.available == nil or d.available())
end

local function ensureBuilt(id: string): any
	if built[id] then
		return built[id]
	end
	local def = defs[id]
	local shell = makeShell(def)
	fitShell(shell)
	local ok, impl = pcall(def.build, shell)
	if not ok then
		warn("[PF][UI] panel build failed:", id, impl)
		shell.Instance:Destroy()
		return nil
	end
	impl = impl or {}
	impl.shell = shell
	local userLayout = impl.layout
	impl.layout = function(size: Vector2, m: string)
		fitShell(shell)
		if userLayout then
			userLayout(shell.size, m)
		end
	end
	impl.layout(canvasSize, mode)
	built[id] = impl
	return impl
end

local scrim: TextButton

local function bindBack(on: boolean)
	if on then
		ContextActionService:BindActionAtPriority("PF_UI_Back", function(_, state)
			if state == Enum.UserInputState.Begin then
				if UIRoot.modalOpen() then
					UIRoot.closeModal()
				else
					UIRoot.close()
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, 4000, Enum.KeyCode.ButtonB)
	else
		ContextActionService:UnbindAction("PF_UI_Back")
	end
end

function UIRoot.open(id: string)
	if not UIRoot.isAvailable(id) then
		return
	end
	if openId == id then
		return
	end
	local impl = ensureBuilt(id)
	if not impl then
		return
	end
	if openId then
		local prev = built[openId]
		if prev then
			prev.shell.Instance.Visible = false
			if prev.onClose then
				pcall(prev.onClose)
			end
		end
	end
	openId = id
	C.hideTooltip()
	local root = impl.shell.Instance
	root.Visible = true
	root.Position = UDim2.new(0.5, 0, 0.5, 18)
	Motion.tween(root, Theme.Motion.panel, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Quint, nil, "open")
	scrim.Visible = true
	Motion.tween(scrim, Theme.Motion.panel, { BackgroundTransparency = Theme.Alpha.Scrim }, nil, nil, "scrim")
	if impl.refresh then
		pcall(impl.refresh)
	end
	if impl.onOpen then
		pcall(impl.onOpen)
	end
	bindBack(true)
	UIRoot.sfx("Whoosh", 0.12, 1.45)
	if lastInputGamepad then
		task.defer(function()
			local sel = (impl.firstSelection and impl.firstSelection()) or impl.shell.Close.Instance
			if sel and sel.Visible then
				GuiService.SelectedObject = sel
			end
		end)
	end
	UIRoot.PanelChanged:Fire(id)
end

function UIRoot.close()
	if not openId then
		return
	end
	local impl = built[openId]
	openId = nil
	C.hideTooltip()
	if impl then
		impl.shell.Instance.Visible = false
		if impl.onClose then
			pcall(impl.onClose)
		end
	end
	Motion.tween(scrim, Theme.Motion.base, { BackgroundTransparency = 1 }, nil, nil, "scrim")
	task.delay(Theme.Motion.base, function()
		if not openId then
			scrim.Visible = false
		end
	end)
	if not UIRoot.modalOpen() then
		bindBack(false)
	end
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	UIRoot.PanelChanged:Fire(nil)
end

function UIRoot.toggle(id: string)
	if openId == id then
		UIRoot.close()
	else
		UIRoot.open(id)
	end
end

function UIRoot.current(): string?
	return openId
end

-- refresh visible panels (data changed). Cheap: hidden panels refresh on open.
function UIRoot.refreshOpen()
	if openId then
		local impl = built[openId]
		if impl and impl.refresh then
			local ok, err = pcall(impl.refresh)
			if not ok then
				warn("[PF][UI] refresh failed:", openId, err)
			end
		end
	end
end

function UIRoot.getPanel(id: string): any
	return built[id]
end

----------------------------------------------------------------------------------------------------
-- toasts
local toastPool: { Frame } = {}
local toastStack: Frame
local toastSeq = 0
function UIRoot.toast(text: string, kind: string?, icon: string?)
	local color = if kind == "success" then Col.Success elseif kind == "warn" then Col.Warn elseif kind == "error" then Col.Danger elseif kind == "reward" then Col.Gold else Col.Cyan
	local f: Frame? = nil
	for _, t in toastPool do
		if not t.Visible then
			f = t
			break
		end
	end
	if not f then
		if #toastPool >= 4 then
			-- recycle the oldest
			local oldest, oldestSeq = toastPool[1], math.huge
			for _, t in toastPool do
				local s = t:GetAttribute("seq") or 0
				if s < oldestSeq then
					oldest, oldestSeq = t, s
				end
			end
			f = oldest
		else
			local nf = C.glass({ name = "Toast", variant = "card", dims = UDim2.fromOffset(300, 0), parent = toastStack })
			nf.AutomaticSize = Enum.AutomaticSize.Y
			nf.BackgroundTransparency = 0.08
			nf.BackgroundColor3 = Col.Navy
			C.pad(10, 14, 10, 14).Parent = nf
			C.make("Frame", { Name = "Accent", BackgroundColor3 = Col.Cyan, Size = UDim2.new(0, 3, 1, -12), Position = UDim2.fromOffset(-8, 6), Parent = nf }, { C.corner(2) })
			local l = C.text({ name = "Label", text = "", size = S.Small, font = F.Semi, autoY = true, parent = nf })
			l.Size = UDim2.new(1, 0, 0, 0)
			table.insert(toastPool, nf)
			f = nf
		end
	end
	local t = f :: Frame
	-- QA-2026-11-21: keep toasts clear of the right-hand hex dock (wide/narrow); phones carry the dock at the bottom
	toastStack.Position = UDim2.new(1, if mode == "short" then -Sp.l else -(Sp.m + 64 + Sp.s), 0, 96)
	toastSeq += 1
	t:SetAttribute("seq", toastSeq)
	t.LayoutOrder = -toastSeq
	local label = t:FindFirstChild("Label") :: TextLabel
	label.Text = text
	label.TextColor3 = Col.Text;
	(t:FindFirstChild("Accent") :: Frame).BackgroundColor3 = color
	local st = t:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = color
		st.Transparency = 0.5
	end
	t.Visible = true
	local my = toastSeq
	task.delay(3.4, function()
		if t:GetAttribute("seq") == my then
			t.Visible = false
		end
	end)
	local _ = icon
end

----------------------------------------------------------------------------------------------------
-- confirm dialog (one instance, reused)
local modal: Frame
local modalTitle: TextLabel
local modalBody: TextLabel
local modalOk: any
local modalCancel: any
local modalCb: (() -> ())? = nil
local modalIsOpen = false
function UIRoot.modalOpen(): boolean
	return modalIsOpen
end
function UIRoot.closeModal()
	modalIsOpen = false
	modal.Visible = false
	modalCb = nil
	if not openId then
		bindBack(false)
	end
	if lastInputGamepad and openId then
		local impl = built[openId]
		local sel = impl and impl.firstSelection and impl.firstSelection()
		if sel then
			GuiService.SelectedObject = sel
		end
	end
end
function UIRoot.confirm(p: { title: string, body: string, confirmText: string?, danger: boolean?, onConfirm: () -> () })
	modalTitle.Text = string.upper(p.title)
	modalBody.Text = p.body
	modalOk:setText(p.confirmText or "Confirm")
	modalOk:setStyle(if p.danger then "danger" else "solid")
	modalCb = p.onConfirm
	modalIsOpen = true
	modal.Visible = true
	modal.Position = UDim2.new(0.5, 0, 0.5, 12)
	Motion.tween(modal, Theme.Motion.panel, { Position = UDim2.fromScale(0.5, 0.5) }, nil, nil, "open")
	bindBack(true)
	if lastInputGamepad then
		GuiService.SelectedObject = modalCancel.Instance
	end
end

----------------------------------------------------------------------------------------------------
function UIRoot.init()
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("PF_UI")
	if old then
		old:Destroy() -- hot-reload safety in Studio; in game init runs once (ResetOnSpawn = false)
	end
	gui = C.make("ScreenGui", { Name = "PF_UI", ResetOnSpawn = false, IgnoreGuiInset = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 25 })
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	canvas = C.make("Frame", { Name = "Canvas", BackgroundTransparency = 1, Size = UDim2.fromOffset(Theme.Canvas.width, Theme.Canvas.height), Parent = gui })
	uiScale = C.make("UIScale", { Name = "Responsive", Parent = canvas })
	for _, name in { "World", "Hud", "Scrim", "Panels", "Modal", "Toast", "Tooltip" } do
		layers[name] = C.make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = canvas })
	end
	scrim = C.make("TextButton", { Name = "Scrim", Text = "", AutoButtonColor = false, Selectable = false, BackgroundColor3 = Col.Void, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = layers.Scrim })
	scrim.Activated:Connect(function()
		UIRoot.close()
	end)
	toastStack = C.make("Frame", { Name = "ToastStack", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -Sp.l, 0, 96), Size = UDim2.fromOffset(300, 400), Parent = layers.Toast }, { C.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Right) })
	C.mountTooltip(layers.Tooltip)

	-- modal
	local modalScrim = C.make("Frame", { Name = "ModalScrim", BackgroundColor3 = Col.Void, BackgroundTransparency = 0.3, Size = UDim2.fromScale(1, 1), Visible = false, Active = true, Parent = layers.Modal })
	modal = C.glass({ name = "Confirm", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5), dims = UDim2.fromOffset(440, 0), parent = layers.Modal })
	modal.AutomaticSize = Enum.AutomaticSize.Y
	modal.Visible = false
	local modalInner = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = modal }, { C.pad(Sp.xl), C.list(Enum.FillDirection.Vertical, Sp.m) })
	modalTitle = C.text({ text = "", size = S.Heading, font = F.Display, parent = modalInner, order = 1 })
	modalBody = C.text({ text = "", size = S.Body, color = Col.TextDim, autoY = true, parent = modalInner, order = 2 })
	local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 3, Parent = modalInner }, { C.list(Enum.FillDirection.Horizontal, Sp.s, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })
	modalCancel = C.button({ text = "Cancel", style = "ghost", parent = row, order = 1, onClick = function()
		UIRoot.closeModal()
	end })
	modalOk = C.button({ text = "Confirm", style = "solid", parent = row, order = 2, onClick = function()
		local cb = modalCb
		UIRoot.closeModal()
		if cb then
			cb()
		end
	end })
	modal:GetPropertyChangedSignal("Visible"):Connect(function()
		modalScrim.Visible = modal.Visible
	end)

	gui.Parent = pg
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		UIRoot.relayout(nil)
	end)
	Prefs.Changed:Connect(function(key)
		if key == "UiScale" then
			UIRoot.relayout(nil)
		end
	end)
	UIRoot.relayout(nil)

	-- input routing
	local function isGamepadInput(t: Enum.UserInputType): boolean
		return t.Name:sub(1, 7) == "Gamepad"
	end
	lastInputGamepad = isGamepadInput(UserInputService:GetLastInputType())
	UserInputService.LastInputTypeChanged:Connect(function(t)
		lastInputGamepad = isGamepadInput(t)
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if not UIRoot.hudVisible() and openId == nil then
			return -- harvesting / cinematic: hotkeys off
		end
		for id, def in defs do
			if (def.hotkey and input.KeyCode == def.hotkey) or (def.gamepadKey and input.KeyCode == def.gamepadKey) then
				if UIRoot.isAvailable(id) then
					UIRoot.toggle(id)
				end
				return
			end
		end
	end)
end

return UIRoot
