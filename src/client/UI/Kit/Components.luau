--!strict
-- Components — owner: Developer A. Reusable PLANET FORGE UI building blocks. Every screen is composed from
-- these, styled only through Theme tokens. Interactive components are Selectable (gamepad), share one focus
-- highlight, expose small imperative APIs (setEnabled/setText/set...) and never recreate themselves on refresh.
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Theme = require(script.Parent.Theme)
local Motion = require(script.Parent.Motion)
local Icons = require(script.Parent.Icons)

local Col, A, F, S, Sp, R = Theme.Color, Theme.Alpha, Theme.Font, Theme.Size, Theme.Space, Theme.Radius
local C = {}

----------------------------------------------------------------------------------------------------
-- primitives
function C.make(class: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(class)
	if inst:IsA("GuiObject") then
		(inst :: any).BorderSizePixel = 0
	end
	local parent = nil
	for k, v in props or {} do
		if k == "Parent" then
			parent = v
		else
			(inst :: any)[k] = v
		end
	end
	for _, ch in children or {} do
		ch.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function C.corner(r: number?): UICorner
	return C.make("UICorner", { CornerRadius = UDim.new(0, r or R.m) })
end
function C.stroke(color: Color3?, transparency: number?, thickness: number?): UIStroke
	return C.make("UIStroke", { Color = color or Col.Cyan, Transparency = transparency or A.Stroke, Thickness = thickness or Theme.Stroke.thin, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
function C.pad(t: number, r: number?, b: number?, l: number?): UIPadding
	return C.make("UIPadding", { PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r or t), PaddingBottom = UDim.new(0, b or t), PaddingLeft = UDim.new(0, l or r or t) })
end
function C.list(dir: Enum.FillDirection?, gap: number?, hAlign: Enum.HorizontalAlignment?, vAlign: Enum.VerticalAlignment?): UIListLayout
	return C.make("UIListLayout", { FillDirection = dir or Enum.FillDirection.Vertical, Padding = UDim.new(0, gap or Sp.s), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left, VerticalAlignment = vAlign or Enum.VerticalAlignment.Top })
end
function C.gradient(c0: Color3, c1: Color3, rot: number?, t0: number?, t1: number?): UIGradient
	return C.make("UIGradient", { Color = ColorSequence.new(c0, c1), Rotation = rot or 90, Transparency = NumberSequence.new(t0 or 0, t1 or 0) })
end

export type TextProps = { text: string?, size: number?, font: Font?, color: Color3?, align: Enum.TextXAlignment?, valign: Enum.TextYAlignment?, wrap: boolean?, autoY: boolean?, name: string?, parent: Instance?, dims: UDim2?, order: number?, rich: boolean?, transparency: number? }
function C.text(p: TextProps): TextLabel
	local autoY = p.autoY == true
	local l = C.make("TextLabel", {
		Name = p.name or "Text",
		BackgroundTransparency = 1,
		Text = p.text or "",
		FontFace = p.font or F.Body,
		TextSize = p.size or S.Body,
		TextColor3 = p.color or Col.Text,
		TextTransparency = p.transparency or 0,
		TextXAlignment = p.align or Enum.TextXAlignment.Left,
		TextYAlignment = p.valign or Enum.TextYAlignment.Center,
		TextWrapped = p.wrap == true or autoY,
		RichText = p.rich == true,
		TextTruncate = if (p.wrap or autoY) then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
		Size = p.dims or (if autoY then UDim2.new(1, 0, 0, 0) else UDim2.new(1, 0, 0, (p.size or S.Body) + 6)),
		AutomaticSize = if autoY then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		LayoutOrder = p.order or 0,
		Parent = p.parent,
	})
	return l
end

-- small caps label used above values ("CREDITS", "OBJECTIVE")
function C.caption(text: string, parent: Instance?, order: number?, color: Color3?): TextLabel
	return C.text({ text = string.upper(text), size = S.Micro, font = F.Display, color = color or Col.TextMute, parent = parent, order = order, dims = UDim2.new(1, 0, 0, 14) })
end

function C.icon(name: string, px: number, color: Color3?, parent: Instance?, order: number?): Frame
	local i = Icons.new(name, px, color or Col.Cyan)
	i.LayoutOrder = order or 0
	i.Parent = parent
	return i
end

----------------------------------------------------------------------------------------------------
-- holographic surfaces
function C.brackets(frame: GuiObject, color: Color3?, len: number?, thick: number?)
	local L, T = len or 12, thick or 2
	local holder = C.make("Frame", { Name = "Brackets", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = frame.ZIndex + 1, Parent = frame })
	local c = color or Col.Cyan
	for _, corner in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local x, y = corner[1], corner[2]
		C.make("Frame", { BackgroundColor3 = c, AnchorPoint = Vector2.new(x, y), Position = UDim2.new(x, if x == 0 then -1 else 1, y, if y == 0 then -1 else 1), Size = UDim2.fromOffset(L, T), Parent = holder })
		C.make("Frame", { BackgroundColor3 = c, AnchorPoint = Vector2.new(x, y), Position = UDim2.new(x, if x == 0 then -1 else 1, y, if y == 0 then -1 else 1), Size = UDim2.fromOffset(T, L), Parent = holder })
	end
	return holder
end

-- Glass panel: navy->violet body, faint top sheen, thin cyan rim. variant: "panel" | "card" | "field"
function C.glass(props: { name: string?, dims: UDim2?, pos: UDim2?, anchor: Vector2?, parent: Instance?, variant: string?, brackets: boolean?, radius: number?, order: number?, clip: boolean? }): Frame
	local v = props.variant or "panel"
	local f = C.make("Frame", {
		Name = props.name or "Glass",
		Size = props.dims or UDim2.fromScale(1, 1),
		Position = props.pos or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		BackgroundColor3 = if v == "field" then Col.PanelLo elseif v == "card" then Col.PanelHi else Col.Panel,
		BackgroundTransparency = if v == "field" then A.Field elseif v == "card" then A.Card else A.Panel,
		LayoutOrder = props.order or 0,
		ClipsDescendants = props.clip == true,
		Parent = props.parent,
	}, { C.corner(props.radius or (if v == "panel" then R.l else R.m)) })
	if v == "panel" then
		C.gradient(Color3.fromRGB(255, 255, 255), Col.VioletDeep, 90, 0, 0).Parent = f
		f.BackgroundColor3 = Col.Panel
		local g = f:FindFirstChildOfClass("UIGradient") :: UIGradient
		g.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 40, 86)), ColorSequenceKeypoint.new(0.25, Col.Panel), ColorSequenceKeypoint.new(1, Col.VioletDeep) })
		C.stroke(Col.Cyan, 0.55, Theme.Stroke.thin).Parent = f
	elseif v == "card" then
		C.stroke(Col.Cyan, 0.8, Theme.Stroke.thin).Parent = f
	end
	if props.brackets then
		C.brackets(f, Col.Cyan, 14, 2)
	end
	return f
end

function C.divider(parent: Instance?, order: number?, vertical: boolean?): Frame
	local d = C.make("Frame", { Name = "Divider", BackgroundColor3 = Col.Cyan, BackgroundTransparency = 0.82, Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1), LayoutOrder = order or 0, Parent = parent })
	C.gradient(Col.Cyan, Col.Cyan, if vertical then 90 else 0).Parent = d
	local g = d:FindFirstChildOfClass("UIGradient") :: UIGradient
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) })
	return d
end

function C.chip(text: string, color: Color3, parent: Instance?, order: number?): Frame
	local f = C.make("Frame", { Name = "Chip", BackgroundColor3 = color, BackgroundTransparency = 0.82, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 20), LayoutOrder = order or 0, Parent = parent }, { C.corner(10), C.stroke(color, 0.5), C.pad(0, 8, 0, 8) })
	C.text({ name = "Label", text = string.upper(text), size = S.Micro, font = F.Bold, color = color, dims = UDim2.new(0, 0, 1, 0), parent = f }).AutomaticSize = Enum.AutomaticSize.X
	return f
end

function C.setChip(chip: Frame, text: string, color: Color3)
	chip.BackgroundColor3 = color
	local s = chip:FindFirstChildOfClass("UIStroke")
	if s then
		s.Color = color
	end
	local l = chip:FindFirstChild("Label") :: TextLabel
	l.Text = string.upper(text)
	l.TextColor3 = color
end

----------------------------------------------------------------------------------------------------
-- focus highlight shared by every Selectable (gamepad / keyboard navigation)
local selectionImage = C.make("Frame", { Name = "PF_Selection", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, { C.corner(R.m), C.stroke(Col.Cyan, 0, 2) })
C.selectionImage = selectionImage

-- tooltip (one shared instance, mounted by UIRoot)
local tooltip: Frame? = nil
local tooltipLabel: TextLabel? = nil
local tipToken = 0
function C.mountTooltip(layer: Instance)
	tooltip = C.make("Frame", { Name = "Tooltip", Visible = false, AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = Col.Navy, BackgroundTransparency = 0.05, ZIndex = 200, Parent = layer }, { C.corner(R.s), C.stroke(Col.Cyan, 0.4), C.pad(6, 10, 6, 10), C.make("UISizeConstraint", { MaxSize = Vector2.new(280, 400) }) })
	tooltipLabel = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = tooltip })
	local tl = tooltipLabel :: TextLabel
	tl.AutomaticSize = Enum.AutomaticSize.XY
	tl.Size = UDim2.new()
	tl.ZIndex = 201
end
local function placeTooltip(target: GuiObject?)
	local t = tooltip
	if not t then
		return
	end
	local layer = t.Parent :: GuiObject
	local origin = layer.AbsolutePosition
	local scale = layer.AbsoluteSize.X / math.max(1, layer.Size.X.Offset > 0 and layer.Size.X.Offset or layer.AbsoluteSize.X)
	local pos: Vector2
	if target then
		pos = target.AbsolutePosition + Vector2.new(0, target.AbsoluteSize.Y + 6)
	else
		pos = UserInputService:GetMouseLocation() - Vector2.new(0, GuiService:GetGuiInset().Y) + Vector2.new(14, 18)
	end
	local local_ = (pos - origin) / math.max(scale, 0.01)
	local maxX = layer.AbsoluteSize.X / math.max(scale, 0.01) - t.AbsoluteSize.X / math.max(scale, 0.01) - 8
	local maxY = layer.AbsoluteSize.Y / math.max(scale, 0.01) - t.AbsoluteSize.Y / math.max(scale, 0.01) - 8
	t.Position = UDim2.fromOffset(math.clamp(local_.X, 8, math.max(8, maxX)), math.clamp(local_.Y, 8, math.max(8, maxY)))
end
function C.tooltip(gui: GuiObject, text: string | () -> string?)
	local function show(target: GuiObject?)
		tipToken += 1
		local my = tipToken
		task.delay(Theme.Motion.tooltipDelay, function()
			if my ~= tipToken or not tooltip or not tooltipLabel then
				return
			end
			local s = if type(text) == "function" then text() else text
			if not s or s == "" then
				return
			end
			(tooltipLabel :: TextLabel).Text = s;
			(tooltip :: Frame).Visible = true
			placeTooltip(target)
		end)
	end
	local function hide()
		tipToken += 1
		if tooltip then
			tooltip.Visible = false
		end
	end
	gui.MouseEnter:Connect(function()
		show(nil)
	end)
	gui.MouseMoved:Connect(function()
		if tooltip and tooltip.Visible then
			placeTooltip(nil)
		end
	end)
	gui.MouseLeave:Connect(hide)
	gui.SelectionGained:Connect(function()
		show(gui)
	end)
	gui.SelectionLost:Connect(hide)
	gui.AncestryChanged:Connect(hide)
	gui:GetPropertyChangedSignal("Visible"):Connect(hide)
end
function C.hideTooltip()
	tipToken += 1
	if tooltip then
		tooltip.Visible = false
	end
end

----------------------------------------------------------------------------------------------------
-- buttons
export type Button = {
	Instance: TextButton,
	Label: TextLabel?,
	setEnabled: (self: Button, on: boolean, reason: string?) -> (),
	setText: (self: Button, text: string) -> (),
	setBusy: (self: Button, busy: boolean) -> (),
	setSelected: (self: Button, on: boolean) -> (),
	setStyle: (self: Button, style: string) -> (),
	enabled: boolean,
	busy: boolean,
}

local STYLES = {
	primary = { bg = Col.Cyan, bgT = 0.84, bgHover = 0.7, stroke = Col.Cyan, strokeT = 0.35, text = Col.Cyan },
	solid = { bg = Col.Cyan, bgT = 0.05, bgHover = 0, stroke = Col.Cyan, strokeT = 0, text = Col.Navy },
	ghost = { bg = Col.PanelHi, bgT = 0.5, bgHover = 0.25, stroke = Col.Cyan, strokeT = 0.78, text = Col.TextDim },
	danger = { bg = Col.Magenta, bgT = 0.84, bgHover = 0.7, stroke = Col.Magenta, strokeT = 0.35, text = Col.Magenta },
	tab = { bg = Col.PanelHi, bgT = 1, bgHover = 0.7, stroke = Col.Cyan, strokeT = 1, text = Col.TextMute },
}

function C.button(p: { text: string?, icon: string?, style: string?, dims: UDim2?, onClick: (() -> ())?, tooltip: (string | () -> string?)?, parent: Instance?, order: number?, size: number?, name: string?, iconOnly: boolean? }): Button
	local style = STYLES[p.style or "primary"]
	local h = if p.dims then p.dims.Y.Offset else 36
	local b = C.make("TextButton", {
		Name = p.name or ("Btn_" .. (p.text or p.icon or "x")),
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = style.bg,
		BackgroundTransparency = style.bgT,
		Size = p.dims or UDim2.fromOffset(0, 36),
		AutomaticSize = if p.dims then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		SelectionImageObject = selectionImage,
		Selectable = true,
		LayoutOrder = p.order or 0,
		Parent = p.parent,
	}, { C.corner(R.m), C.make("UIScale", { Name = "Press" }) })
	local stroke = C.stroke(style.stroke, style.strokeT, Theme.Stroke.thin)
	stroke.Parent = b
	local inner = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), AutomaticSize = if p.dims then Enum.AutomaticSize.None else Enum.AutomaticSize.X, Parent = b }, {
		C.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
		C.pad(0, if p.iconOnly then 0 else 14, 0, if p.iconOnly then 0 else 14),
	})
	local icon: Frame? = nil
	if p.icon then
		icon = C.icon(p.icon, math.floor(h * 0.46), style.text, inner, 1)
	end
	local label: TextLabel? = nil
	if p.text and not p.iconOnly then
		label = C.text({ name = "Label", text = string.upper(p.text), size = p.size or S.Small, font = F.Bold, color = style.text, align = Enum.TextXAlignment.Center, dims = UDim2.new(0, 0, 1, 0), parent = inner, order = 2 })
		local lab = label :: TextLabel
		lab.AutomaticSize = Enum.AutomaticSize.X
		lab.TextTruncate = Enum.TextTruncate.None
	end
	local obj: any = { Instance = b, Label = label, enabled = true, busy = false, _style = style, _hover = false, _selected = false, _text = p.text }
	local function paint()
		local st = obj._style
		local hot = (obj._hover or obj._selected) and obj.enabled and not obj.busy
		local textColor = if not obj.enabled then Col.TextMute elseif obj._selected and p.style == "tab" then Col.Cyan elseif hot and st == STYLES.ghost then Col.Text else st.text
		Motion.tween(b, Theme.Motion.fast, { BackgroundTransparency = if not obj.enabled then math.max(0.86, st.bgT) elseif hot or (obj._selected and p.style == "tab") then st.bgHover else st.bgT }, nil, nil, "bg")
		Motion.tween(stroke, Theme.Motion.fast, { Transparency = if not obj.enabled then 0.88 elseif hot then math.min(st.strokeT, A.StrokeHover) else st.strokeT }, nil, nil, "stroke")
		if label then
			label.TextColor3 = textColor
		end
		if icon then
			Icons.recolor(icon, textColor)
		end
	end
	obj._paint = paint
	b.MouseEnter:Connect(function()
		obj._hover = true
		paint()
	end)
	b.MouseLeave:Connect(function()
		obj._hover = false
		(b:FindFirstChild("Press") :: UIScale).Scale = 1
		paint()
	end)
	b.SelectionGained:Connect(function()
		obj._hover = true
		paint()
	end)
	b.SelectionLost:Connect(function()
		obj._hover = false
		paint()
	end)
	b.MouseButton1Down:Connect(function()
		if obj.enabled and not obj.busy then
			Motion.tween(b:FindFirstChild("Press") :: UIScale, 0.06, { Scale = 0.97 }, nil, nil, "press")
		end
	end)
	b.MouseButton1Up:Connect(function()
		Motion.tween(b:FindFirstChild("Press") :: UIScale, 0.12, { Scale = 1 }, nil, nil, "press")
	end)
	b.Activated:Connect(function()
		if obj.enabled and not obj.busy and p.onClick then
			C.hideTooltip()
			p.onClick()
		end
	end)
	if p.tooltip then
		C.tooltip(b, p.tooltip)
	end
	function obj:setEnabled(on: boolean, reason: string?)
		obj.enabled = on
		obj._reason = reason
		paint()
	end
	function obj:setText(t: string)
		obj._text = t
		if label and not obj.busy then
			label.Text = string.upper(t)
		end
	end
	function obj:setBusy(busy: boolean)
		obj.busy = busy
		if label then
			label.Text = if busy then "···" else string.upper(obj._text or "")
		end
		paint()
	end
	function obj:setSelected(on: boolean)
		obj._selected = on
		paint()
	end
	function obj:setStyle(name: string)
		obj._style = STYLES[name] or STYLES.primary
		b.BackgroundColor3 = obj._style.bg
		stroke.Color = obj._style.stroke
		paint()
	end
	paint()
	return obj :: Button
end

----------------------------------------------------------------------------------------------------
-- hexagon dock button (CanvasGroup so three overlapping rectangles render as one translucent hexagon)
export type HexButton = { Instance: TextButton, setBadge: (self: HexButton, n: number?) -> (), setPulse: (self: HexButton, on: boolean) -> (), setActive: (self: HexButton, on: boolean) -> () }
local function hexShape(parent: Instance, d: number, color: Color3, z: number, name: string)
	local holder = C.make("Frame", { Name = name, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(d, d), ZIndex = z, Parent = parent })
	local Rr = d / 2
	for _, rot in { 0, 60, 120 } do
		C.make("Frame", { BackgroundColor3 = color, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.ceil(Rr * math.sqrt(3)), math.ceil(Rr)), Rotation = rot + 30, ZIndex = z, Parent = holder })
	end
	return holder
end
function C.hexButton(p: { icon: string, label: string, hotkey: string?, onClick: () -> (), parent: Instance?, order: number?, size: number? }): HexButton
	local d = p.size or 64
	local b = C.make("TextButton", { Name = "Hex_" .. p.label, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(d, d + 16), SelectionImageObject = selectionImage, LayoutOrder = p.order or 0, Parent = p.parent }, { C.make("UIScale", { Name = "Press" }) })
	local group = C.make("CanvasGroup", { Name = "Hex", BackgroundTransparency = 1, Size = UDim2.fromOffset(d, d), GroupTransparency = 0.18, Parent = b })
	hexShape(group, d, Col.Cyan, 1, "Rim")
	local fill = hexShape(group, d - 4, Col.Panel, 2, "Fill")
	local glow = hexShape(group, d - 4, Col.Cyan, 3, "Glow")
	for _, f in glow:GetChildren() do
		(f :: Frame).BackgroundTransparency = 0.9
	end
	local _ = fill
	local icon = C.icon(p.icon, math.floor(d * 0.4), Col.Cyan, b, 0)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromOffset(d / 2, d / 2)
	icon.ZIndex = 5
	for _, x in icon:GetDescendants() do
		if x:IsA("GuiObject") then
			x.ZIndex = 5
		end
	end
	local cap = C.text({ name = "Caption", text = string.upper(p.label), size = S.Micro, font = F.Bold, color = Col.TextDim, align = Enum.TextXAlignment.Center, dims = UDim2.new(1, 16, 0, 14), parent = b })
	cap.Position = UDim2.new(0, -8, 0, d + 2)
	local badge = C.make("Frame", { Name = "Badge", Visible = false, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(d * 0.82, d * 0.2), Size = UDim2.fromOffset(20, 20), BackgroundColor3 = Col.Magenta, ZIndex = 8, Parent = b }, { C.corner(10), C.stroke(Col.Navy, 0, 2) })
	local badgeText = C.text({ text = "", size = S.Micro, font = F.Bold, color = Col.Text, align = Enum.TextXAlignment.Center, dims = UDim2.fromScale(1, 1), parent = badge })
	badgeText.ZIndex = 9
	if p.hotkey then
		C.tooltip(b, string.format("%s  [%s]", p.label, p.hotkey))
	else
		C.tooltip(b, p.label)
	end
	local obj: any = { Instance = b, _hover = false, _active = false, _pulse = nil :: thread? }
	local function paint()
		local hot = obj._hover or obj._active
		Motion.tween(group, Theme.Motion.fast, { GroupTransparency = if hot then 0 else 0.18 }, nil, nil, "grp")
		for _, f in glow:GetChildren() do
			Motion.tween(f, Theme.Motion.fast, { BackgroundTransparency = if obj._active then 0.72 elseif obj._hover then 0.8 else 0.9 }, nil, nil, "glow")
		end
		cap.TextColor3 = if hot then Col.Text else Col.TextDim
	end
	b.MouseEnter:Connect(function() obj._hover = true paint() end)
	b.MouseLeave:Connect(function() obj._hover = false paint() end)
	b.SelectionGained:Connect(function() obj._hover = true paint() end)
	b.SelectionLost:Connect(function() obj._hover = false paint() end)
	b.MouseButton1Down:Connect(function() Motion.tween(b:FindFirstChild("Press") :: UIScale, 0.06, { Scale = 0.94 }, nil, nil, "press") end)
	b.MouseButton1Up:Connect(function() Motion.tween(b:FindFirstChild("Press") :: UIScale, 0.14, { Scale = 1 }, nil, nil, "press") end)
	b.Activated:Connect(function()
		C.hideTooltip()
		p.onClick()
	end)
	function obj:setBadge(n: number?)
		badge.Visible = n ~= nil and n > 0
		badgeText.Text = if n and n > 9 then "9+" else tostring(n or "")
	end
	function obj:setActive(on: boolean)
		obj._active = on
		paint()
	end
	function obj:setPulse(on: boolean)
		if obj._pulse then
			task.cancel(obj._pulse)
			obj._pulse = nil
		end
		local rim = group:FindFirstChild("Rim") :: Frame
		for _, f in rim:GetChildren() do
			(f :: Frame).BackgroundColor3 = if on then Col.Magenta else Col.Cyan
		end
		if on then
			obj._pulse = task.spawn(function()
				local scale = b:FindFirstChild("Press") :: UIScale
				while true do
					Motion.tween(scale, 0.5, { Scale = 1.07 }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, "pulse")
					task.wait(0.55)
					Motion.tween(scale, 0.5, { Scale = 1 }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, "pulse")
					task.wait(0.9)
				end
			end)
		else
			(b:FindFirstChild("Press") :: UIScale).Scale = 1
		end
	end
	paint()
	return obj :: HexButton
end

----------------------------------------------------------------------------------------------------
-- value bar with optional preview (ghost segment shows a pending change)
export type Bar = { Instance: Frame, set: (self: Bar, v: number, preview: number?) -> (), setColor: (self: Bar, c: Color3) -> () }
function C.bar(p: { color: Color3?, height: number?, parent: Instance?, order: number?, dims: UDim2? }): Bar
	local h = p.height or 6
	local track = C.make("Frame", { Name = "Bar", BackgroundColor3 = Col.PanelLo, BackgroundTransparency = 0.2, Size = p.dims or UDim2.new(1, 0, 0, h), LayoutOrder = p.order or 0, ClipsDescendants = true, Parent = p.parent }, { C.corner(h), C.stroke(Col.Cyan, 0.86) })
	local ghost = C.make("Frame", { Name = "Ghost", BackgroundColor3 = Col.Text, BackgroundTransparency = 0.6, Size = UDim2.fromScale(0, 1), Parent = track }, { C.corner(h) })
	local fill = C.make("Frame", { Name = "Fill", BackgroundColor3 = p.color or Col.Cyan, Size = UDim2.fromScale(0, 1), Parent = track }, { C.corner(h) })
	C.gradient(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190), 0).Parent = fill
	local obj: any = { Instance = track }
	function obj:set(v: number, preview: number?)
		v = math.clamp(v, 0, 1)
		Motion.tween(fill, Theme.Motion.slow, { Size = UDim2.fromScale(v, 1) }, nil, nil, "fill")
		if preview and math.abs(preview - v) > 0.001 then
			preview = math.clamp(preview, 0, 1)
			local lo, hi = math.min(v, preview), math.max(v, preview)
			ghost.Visible = true
			ghost.BackgroundColor3 = if preview > v then Col.Success else Col.Danger
			ghost.BackgroundTransparency = 0.25
			ghost.Position = UDim2.fromScale(lo, 0)
			ghost.Size = UDim2.fromScale(hi - lo, 1)
			fill.ZIndex = if preview > v then 2 else 1
			ghost.ZIndex = if preview > v then 1 else 2
		else
			ghost.Visible = false
		end
	end
	function obj:setColor(c: Color3)
		fill.BackgroundColor3 = c
	end
	return obj :: Bar
end

----------------------------------------------------------------------------------------------------
-- tabs
export type Tabs = { Instance: Frame, select: (self: Tabs, id: string) -> (), selected: string, buttons: { [string]: Button } }
function C.tabs(p: { items: { { id: string, label: string, icon: string? } }, onSelect: (string) -> (), parent: Instance?, order: number?, dims: UDim2? }): Tabs
	local holder = C.make("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = p.dims or UDim2.new(1, 0, 0, 38), LayoutOrder = p.order or 0, Parent = p.parent })
	local row = C.make("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = holder }, { C.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })
	C.make("Frame", { Name = "Baseline", BackgroundColor3 = Col.Cyan, BackgroundTransparency = 0.85, Size = UDim2.new(1, 0, 0, 1), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Parent = holder })
	local underline = C.make("Frame", { Name = "Underline", BackgroundColor3 = Col.Cyan, Size = UDim2.fromOffset(40, 2), AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), ZIndex = 3, Parent = holder })
	local obj: any = { Instance = holder, selected = "", buttons = {} }
	local function moveUnderline()
		local btn = obj.buttons[obj.selected]
		if btn and holder.AbsoluteSize.X > 0 then
			local bi = btn.Instance
			local scale = holder.AbsoluteSize.X / math.max(1, holder.AbsoluteSize.X)
			local _ = scale
			-- convert absolute pixels to the holder's local (pre-UIScale) units
			local root = holder:FindFirstAncestorWhichIsA("LayerCollector")
			local uiScale = 1
			local cur: Instance? = holder
			while cur and cur ~= root do
				local sc = cur:FindFirstChildOfClass("UIScale")
				if sc and sc.Name ~= "Press" then
					uiScale *= sc.Scale
				end
				cur = cur.Parent
			end
			Motion.tween(underline, Theme.Motion.base, { Position = UDim2.new(0, (bi.AbsolutePosition.X - holder.AbsolutePosition.X) / uiScale, 1, 0), Size = UDim2.fromOffset(bi.AbsoluteSize.X / uiScale, 2) }, nil, nil, "ul")
		end
	end
	for i, it in p.items do
		obj.buttons[it.id] = C.button({ text = it.label, icon = it.icon, style = "tab", parent = row, order = i, onClick = function()
			obj:select(it.id)
			p.onSelect(it.id)
		end })
	end
	function obj:select(id: string)
		obj.selected = id
		for bid, b in obj.buttons do
			b:setSelected(bid == id)
		end
		task.defer(moveUnderline)
	end
	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() task.defer(moveUnderline) end)
	holder:GetPropertyChangedSignal("AbsolutePosition"):Connect(function() task.defer(moveUnderline) end)
	return obj :: Tabs
end

----------------------------------------------------------------------------------------------------
-- toggle + slider (both fully operable with mouse, touch, keyboard and gamepad)
export type Toggle = { Instance: TextButton, set: (self: Toggle, on: boolean) -> (), value: boolean }
function C.toggle(p: { value: boolean, onChange: (boolean) -> (), parent: Instance?, order: number? }): Toggle
	local b = C.make("TextButton", { Name = "Toggle", Text = "", AutoButtonColor = false, BackgroundColor3 = Col.PanelLo, BackgroundTransparency = 0.2, Size = UDim2.fromOffset(52, 28), SelectionImageObject = selectionImage, LayoutOrder = p.order or 0, Parent = p.parent }, { C.corner(14) })
	local st = C.stroke(Col.Cyan, 0.6)
	st.Parent = b
	local knob = C.make("Frame", { Name = "Knob", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(20, 20), BackgroundColor3 = Col.TextMute, Parent = b }, { C.corner(10) })
	local obj: any = { Instance = b, value = p.value }
	function obj:set(on: boolean)
		obj.value = on
		Motion.tween(knob, Theme.Motion.base, { Position = if on then UDim2.new(1, -24, 0.5, 0) else UDim2.new(0, 4, 0.5, 0), BackgroundColor3 = if on then Col.Navy else Col.TextMute }, nil, nil, "knob")
		Motion.tween(b, Theme.Motion.base, { BackgroundColor3 = if on then Col.Cyan else Col.PanelLo, BackgroundTransparency = if on then 0.05 else 0.2 }, nil, nil, "bg")
	end
	b.Activated:Connect(function()
		obj:set(not obj.value)
		p.onChange(obj.value)
	end)
	b.MouseEnter:Connect(function() st.Transparency = 0.2 end)
	b.MouseLeave:Connect(function() st.Transparency = 0.6 end)
	obj:set(p.value)
	return obj :: Toggle
end

export type Slider = { Instance: TextButton, set: (self: Slider, v: number) -> (), value: number }
function C.slider(p: { min: number, max: number, step: number, value: number, format: (number) -> string, onChange: (number) -> (), parent: Instance?, order: number?, width: number? }): Slider
	local w = p.width or 220
	local b = C.make("TextButton", { Name = "Slider", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(w + 64, 32), SelectionImageObject = selectionImage, LayoutOrder = p.order or 0, Parent = p.parent })
	local track = C.make("Frame", { Name = "Track", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(w, 6), BackgroundColor3 = Col.PanelLo, Parent = b }, { C.corner(3), C.stroke(Col.Cyan, 0.8) })
	local fill = C.make("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = Col.Cyan, Parent = track }, { C.corner(3) })
	local knob = C.make("Frame", { Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = Col.Text, Parent = track }, { C.corner(9), C.stroke(Col.Cyan, 0, 2) })
	local valueLabel = C.text({ text = "", size = S.Small, font = F.Bold, color = Col.Text, align = Enum.TextXAlignment.Right, dims = UDim2.fromOffset(56, 32), parent = b })
	valueLabel.Position = UDim2.fromOffset(w + 8, 0)
	local obj: any = { Instance = b, value = p.value }
	local function render()
		local t = (obj.value - p.min) / (p.max - p.min)
		fill.Size = UDim2.fromScale(t, 1)
		knob.Position = UDim2.fromScale(t, 0.5)
		valueLabel.Text = p.format(obj.value)
	end
	function obj:set(v: number)
		obj.value = math.clamp(math.round(v / p.step) * p.step, p.min, p.max)
		render()
	end
	local function commit(v: number)
		local before = obj.value
		obj:set(v)
		if obj.value ~= before then
			p.onChange(obj.value)
		end
	end
	local dragging = false
	local function fromX(x: number)
		local t = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		commit(p.min + t * (p.max - p.min))
	end
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			fromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			fromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	-- gamepad / keyboard: left/right adjust while focused (focus stays on the slider horizontally)
	b.NextSelectionLeft = b
	b.NextSelectionRight = b
	UserInputService.InputBegan:Connect(function(input)
		if GuiService.SelectedObject ~= b then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.DPadLeft or k == Enum.KeyCode.Left then
			commit(obj.value - p.step)
		elseif k == Enum.KeyCode.DPadRight or k == Enum.KeyCode.Right then
			commit(obj.value + p.step)
		end
	end)
	b.SelectionGained:Connect(function() knob:FindFirstChildOfClass("UIStroke").Color = Col.Magenta end)
	b.SelectionLost:Connect(function() knob:FindFirstChildOfClass("UIStroke").Color = Col.Cyan end)
	obj:set(p.value)
	return obj :: Slider
end

----------------------------------------------------------------------------------------------------
-- scrolling list + row pool (refreshes reuse instances; nothing is recreated per data change)
function C.scroll(p: { name: string?, dims: UDim2?, pos: UDim2?, parent: Instance?, gap: number?, order: number?, padding: number?, horizontal: boolean? }): ScrollingFrame
	local s = C.make("ScrollingFrame", {
		Name = p.name or "Scroll",
		BackgroundTransparency = 1,
		Size = p.dims or UDim2.fromScale(1, 1),
		Position = p.pos or UDim2.new(),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = if p.horizontal then Enum.AutomaticSize.X else Enum.AutomaticSize.Y,
		ScrollingDirection = if p.horizontal then Enum.ScrollingDirection.X else Enum.ScrollingDirection.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Col.Cyan,
		ScrollBarImageTransparency = 0.4,
		LayoutOrder = p.order or 0,
		Selectable = false,
		Parent = p.parent,
	}, { C.list(if p.horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical, p.gap or Sp.s), C.pad(p.padding or 2, (p.padding or 2) + 4, p.padding or 2, p.padding or 2) })
	return s
end

export type Pool = { items: { any }, sync: (self: Pool, n: number, fill: (item: any, index: number) -> ()) -> () }
function C.pool(create: (index: number) -> any): Pool
	local obj: any = { items = {} }
	function obj:sync(n: number, fill: (any, number) -> ())
		for i = 1, n do
			local it = obj.items[i]
			if not it then
				it = create(i)
				obj.items[i] = it
			end
			local inst = if typeof(it) == "Instance" then it else it.Instance
			inst.Visible = true
			inst.LayoutOrder = i
			fill(it, i)
		end
		for i = n + 1, #obj.items do
			local it = obj.items[i]
			local inst = if typeof(it) == "Instance" then it else it.Instance
			inst.Visible = false
		end
	end
	return obj :: Pool
end

return C
