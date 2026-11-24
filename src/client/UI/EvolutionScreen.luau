--!strict
-- EvolutionScreen — owner: Developer A. Reward moment for the local player's planet:
--   * stage-up / branch commit -> full screen: before/after planet previews (ViewportFrames, lit independently
--     of the night scene), stage name, newly unlocked formations, stage rewards, Continue
--   * reaction that adds formations -> compact discovery card (no interruption)
-- Driven by EvolutionClient.Transformation (Developer B's once-only event) and shown after the in-world
-- cinematic (PlanetVisualController) has played.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local Prefs = require(Kit.Prefs)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)
local Shared = ReplicatedStorage.PF_Shared
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local Screen = {}
local deps: any = {}
local ui: any = {}
local spinConn: RBXScriptConnection? = nil
local queue: { any } = {}
local showing = false

local function formationName(id: string): string
	local d = FormationRegistry.DEFS and FormationRegistry.DEFS[id]
	return (d and d.displayName) or id
end

local function viewport(parent: Instance, caption: string, order: number): (ViewportFrame, TextLabel)
	local holder = C.glass({ name = "View_" .. caption, variant = "field", dims = UDim2.fromOffset(300, 240), parent = parent, order = order })
	local vp = C.make("ViewportFrame", { Name = "Viewport", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Ambient = Color3.fromRGB(150, 150, 170), LightColor = Color3.fromRGB(255, 248, 235), LightDirection = Vector3.new(-1, -0.6, -0.4), Parent = holder }, { C.corner(Theme.Radius.m) })
	local cap = C.caption(caption, holder, 0, Col.TextDim)
	cap.Position = UDim2.fromOffset(12, 10)
	cap.Size = UDim2.new(1, -24, 0, 14)
	cap.ZIndex = 3
	return vp, cap
end

local function mount(vp: ViewportFrame, model: Model?): Camera?
	vp:ClearAllChildren()
	if not model then
		return nil
	end
	model.Parent = vp
	local core = model.PrimaryPart
	local center = if core then core.Position else model:GetPivot().Position
	local radius = if core then core.Size.X / 2 else 96
	local cam = Instance.new("Camera")
	cam.FieldOfView = 34
	cam.CFrame = CFrame.lookAt(center + Vector3.new(0.55, 0.45, 1).Unit * radius * 4.2, center)
	cam.Parent = vp
	vp.CurrentCamera = cam
	vp:SetAttribute("cx", center.X)
	vp:SetAttribute("cy", center.Y)
	vp:SetAttribute("cz", center.Z)
	vp:SetAttribute("r", radius)
	return cam
end

local function close()
	if not showing then
		return
	end
	showing = false
	if spinConn then
		spinConn:Disconnect()
		spinConn = nil
	end
	ContextActionService:UnbindAction("PF_EvoContinue")
	Motion.tween(ui.root, Theme.Motion.base, { BackgroundTransparency = 1 }, nil, nil, "fade")
	ui.card.Visible = false
	task.delay(Theme.Motion.base, function()
		if not showing then
			ui.root.Visible = false
			ui.before:ClearAllChildren()
			ui.after:ClearAllChildren()
			UIRoot.setHudHidden("evolution", false)
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(ui.root) then
				GuiService.SelectedObject = nil
			end
			local nxt = table.remove(queue, 1)
			if nxt then
				task.delay(0.3, function()
					Screen.show(nxt)
				end)
			end
		end
	end)
end

function Screen.show(t: any)
	if showing then
		table.insert(queue, t)
		return
	end
	showing = true
	UIRoot.close()
	UIRoot.setHudHidden("evolution", true)
	local stageTo = t.stageTo or 0
	local stageDef = EvolutionConfig.STAGES[stageTo]
	local isBranch = t.kind == "branch"
	local st = UIData.Evolution.stage()
	ui.kicker.Text = if isBranch then "SPECIALIZATION COMMITTED" else "EVOLUTION COMPLETE"
	ui.title.Text = string.upper(if isBranch and st then (st.branchName or "") .. " WORLD" else (stageDef and stageDef.name or ("Stage " .. stageTo)))
	ui.desc.Text = (stageDef and stageDef.description) or ""
	-- formations unlocked by this milestone
	local forms = {}
	for _, id in t.formations or {} do
		table.insert(forms, formationName(id))
	end
	ui.formHolder.Visible = #forms > 0
	ui.formPool:sync(#forms, function(chip, i)
		C.setChip(chip, forms[i], Col.Success)
	end)
	-- rewards for every newly reached stage
	local bits = {}
	for _, n in t.newStages or (if (t.stageTo or 0) > (t.stageFrom or 0) then { t.stageTo } else {}) do
		local d = EvolutionConfig.STAGES[n]
		local rw = d and d.reward
		if rw then
			if rw.credits then table.insert(bits, "+" .. UIData.fmt(rw.credits) .. " credits") end
			if rw.xp then table.insert(bits, "+" .. rw.xp .. " XP") end
			if type(rw.materials) == "table" then
				for id, q in rw.materials do
					local md = UIData.materialDef(id)
					table.insert(bits, string.format("+%d %s", q, md and md.displayName or id))
				end
			end
		end
	end
	ui.rewardHolder.Visible = #bits > 0
	ui.rewards.Text = table.concat(bits, "   ·   ")
	-- previews
	local before, after = nil, nil
	if deps.visuals and deps.visuals.getEvolutionCaptures and t.slot then
		before, after = deps.visuals.getEvolutionCaptures(t.slot)
	end
	mount(ui.before, before)
	local cam = mount(ui.after, after)
	ui.beforeHolder.Visible = before ~= nil
	ui.arrow.Visible = before ~= nil
	ui.root.Visible = true
	ui.root.BackgroundTransparency = 1
	Motion.tween(ui.root, Theme.Motion.slow, { BackgroundTransparency = 0.25 }, nil, nil, "fade")
	ui.card.Visible = true
	ui.card.Position = UDim2.new(0.5, 0, 0.5, 24)
	Motion.tween(ui.card, Theme.Motion.slow, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back, nil, "pop")
	if cam and not Prefs.reducedMotion() then
		local a = 0
		local vp = ui.after
		spinConn = RunService.RenderStepped:Connect(function(dt)
			a += dt * 0.25
			local c = Vector3.new(vp:GetAttribute("cx"), vp:GetAttribute("cy"), vp:GetAttribute("cz"))
			local rr = vp:GetAttribute("r") * 4.2
			cam.CFrame = CFrame.lookAt(c + Vector3.new(math.sin(a) * 0.9, 0.45, math.cos(a)).Unit * rr, c)
		end)
	end
	ContextActionService:BindActionAtPriority("PF_EvoContinue", function(_, state)
		if state == Enum.UserInputState.Begin then
			close()
		end
		return Enum.ContextActionResult.Sink
	end, false, 4100, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonA)
	if UIRoot.isGamepad() then
		GuiService.SelectedObject = ui.continue.Instance
	end
end

-- compact card for formation-only milestones
local cardToken = 0
function Screen.discovery(t: any)
	local forms = {}
	for _, id in t.formations or {} do
		table.insert(forms, formationName(id))
	end
	if #forms == 0 then
		return
	end
	cardToken += 1
	local my = cardToken
	ui.discTitle.Text = if #forms == 1 then "NEW FORMATION" else string.format("%d NEW FORMATIONS", #forms)
	ui.discBody.Text = table.concat(forms, " · ")
	local d = ui.disc
	d.Visible = true
	d.Position = UDim2.new(0.5, 0, 1, 40)
	Motion.tween(d, Theme.Motion.slow, { Position = UDim2.new(0.5, 0, 1, -Sp.xl) }, Enum.EasingStyle.Back, nil, "slide")
	task.delay(4.5, function()
		if my == cardToken then
			Motion.tween(d, Theme.Motion.base, { Position = UDim2.new(0.5, 0, 1, 80) }, nil, nil, "slide")
			task.delay(Theme.Motion.base, function()
				if my == cardToken then
					d.Visible = false
				end
			end)
		end
	end)
end

local function layout(size: Vector2, mode: string)
	if not ui.card then
		return
	end
	local narrow = mode == "narrow"
	local short = mode == "short"
	ui.card.Size = UDim2.fromOffset(math.min(820, size.X - 24), 0)
	local vpW = if narrow then math.min(300, size.X - 72) else (if short then 220 else 300)
	local vpH = if short then 150 else (if narrow then 180 else 240)
	for _, h in { ui.beforeHolder, ui.afterHolder } do
		h.Size = UDim2.fromOffset(vpW, vpH)
	end
	local row = ui.views:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	row.FillDirection = if narrow then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal
	ui.arrow.Rotation = if narrow then 90 else 0
end

function Screen.init(d: any)
	deps = d or {}
	local layer = UIRoot.layer("Modal")
	local root = C.make("Frame", { Name = "Evolution", BackgroundColor3 = Col.Void, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Active = true, Parent = layer })
	ui.root = root
	local card = C.glass({ name = "Card", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5), dims = UDim2.fromOffset(820, 0), parent = root })
	card.AutomaticSize = Enum.AutomaticSize.Y
	ui.card = card
	-- content lives in an inner frame so the card's corner brackets never take part in the list layout
	local inner = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.xl), C.list(Enum.FillDirection.Vertical, Sp.m, Enum.HorizontalAlignment.Center) })
	card = inner
	ui.kicker = C.text({ text = "", size = S.Small, font = F.Display, color = Col.Magenta, align = Enum.TextXAlignment.Center, parent = card, order = 1 })
	ui.title = C.text({ text = "", size = 30, font = F.Display, align = Enum.TextXAlignment.Center, parent = card, order = 2, dims = UDim2.new(1, 0, 0, 40) })
	ui.title.TextScaled = true
	C.make("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 16, Parent = ui.title })
	ui.desc = C.text({ text = "", size = S.Body, color = Col.TextDim, align = Enum.TextXAlignment.Center, autoY = true, parent = card, order = 3 })
	local views = C.make("Frame", { Name = "Views", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = card }, { C.list(Enum.FillDirection.Horizontal, Sp.l, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center) })
	ui.views = views
	ui.before, _ = viewport(views, "Before", 1)
	ui.beforeHolder = ui.before.Parent
	ui.arrow = C.icon("chevron", 28, Col.Cyan, views, 2)
	ui.after, _ = viewport(views, "After", 3)
	ui.afterHolder = ui.after.Parent
	local afterStroke = ui.afterHolder:FindFirstChildOfClass("UIStroke") or C.stroke(Col.Cyan, 0.2, 2)
	afterStroke.Parent = ui.afterHolder
	afterStroke.Transparency = 0.2
	ui.formHolder = C.make("Frame", { Name = "Forms", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = card }, { C.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center) })
	C.caption("New formations", ui.formHolder, 0).TextXAlignment = Enum.TextXAlignment.Center
	local chips = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = ui.formHolder }, { C.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center) })
	chips:FindFirstChildOfClass("UIListLayout").Wraps = true
	ui.formPool = C.pool(function()
		return C.chip("", Col.Success, chips)
	end)
	ui.rewardHolder = C.make("Frame", { Name = "Rewards", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6, Parent = card }, { C.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center) })
	C.caption("Rewards", ui.rewardHolder, 0).TextXAlignment = Enum.TextXAlignment.Center
	ui.rewards = C.text({ text = "", size = S.Heading, font = F.Bold, color = Col.Gold, align = Enum.TextXAlignment.Center, autoY = true, parent = ui.rewardHolder, order = 1 })
	ui.continue = C.button({ text = "Continue", style = "solid", dims = UDim2.fromOffset(220, 44), parent = card, order = 7, onClick = close })

	-- discovery card (bottom centre, Toast layer so it never blocks input)
	local disc = C.glass({ name = "Discovery", variant = "panel", anchor = Vector2.new(0.5, 1), dims = UDim2.fromOffset(380, 0), parent = UIRoot.layer("Toast") })
	disc.AutomaticSize = Enum.AutomaticSize.Y
	disc.Visible = false
	C.pad(Sp.m, Sp.l, Sp.m, Sp.l).Parent = disc
	C.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center).Parent = disc
	ui.discTitle = C.text({ text = "", size = S.Small, font = F.Display, color = Col.Success, align = Enum.TextXAlignment.Center, parent = disc, order = 1 })
	ui.discBody = C.text({ text = "", size = S.Body, font = F.Bold, align = Enum.TextXAlignment.Center, autoY = true, parent = disc, order = 2 })
	ui.disc = disc
	local discStroke = disc:FindFirstChildOfClass("UIStroke")
	if discStroke then
		discStroke.Color = Col.Success
	end

	UIRoot.Resized:Connect(layout)
	layout(UIRoot.size(), UIRoot.mode())

	UIData.Evolution.Transformation:Connect(function(ev: any)
		if type(ev) ~= "table" or ev.ownerUserId ~= player.UserId then
			return
		end
		local t = ev.transformation or ev
		local payload = table.clone(t)
		payload.slot = ev.slot
		local stageUp = (t.stageTo or 0) > (t.stageFrom or 0)
		if stageUp or t.kind == "branch" then
			-- let the in-world cinematic (PlanetVisualController) play first
			local wait = if Prefs.reducedMotion() then 0.8 else 3.2
			task.delay(wait, function()
				Screen.show(payload)
			end)
		elseif t.formations and #t.formations > 0 then
			task.delay(0.6, function()
				Screen.discovery(payload)
			end)
		end
	end)
end

Screen.close = close
Screen.isShowing = function(): boolean
	return showing
end

return Screen
