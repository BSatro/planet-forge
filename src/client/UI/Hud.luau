--!strict
-- Hud — owner: Developer A. Always-on game HUD: planet identity + evolution stage, resources, current objective
-- and the hexagon dock (DNA Lab, Harvester, Inventory, Codex, Expedition when available, Settings).
-- Reads only UIData (Developer B's ProfileClient/EvolutionClient); hides while harvesting or in cinematics.
local Players = game:GetService("Players")
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Hud = {}

local refs: any = {}
local dockButtons: { [string]: any } = {}
local dockOrder: { string } = {}
local lastCredits = -1
local objective: any = nil

local STAGE_COLORS = { [0] = Col.TextMute, Col.Cyan, Col.Success, Col.Magenta, Col.Gold }

local function planetCard(parent: Instance)
	local card = C.glass({ name = "PlanetCard", variant = "panel", dims = UDim2.fromOffset(340, 96), pos = UDim2.fromOffset(Sp.l, Sp.m), parent = parent, brackets = true })
	-- emblem: hexagon with stage number
	local emblem = C.make("Frame", { Name = "Emblem", BackgroundTransparency = 1, Size = UDim2.fromOffset(64, 64), Position = UDim2.fromOffset(14, 16), Parent = card })
	local hexBtn = C.hexButton({ icon = "planet", label = "", onClick = function() UIRoot.open("dna") end, parent = emblem, size = 64 })
	hexBtn.Instance.Size = UDim2.fromOffset(64, 64);
	(hexBtn.Instance:FindFirstChild("Caption") :: TextLabel).Visible = false
	refs.emblem = hexBtn
	local stageNum = C.text({ name = "StageNum", text = "0", size = 12, font = F.Display, color = Col.Navy, align = Enum.TextXAlignment.Center, dims = UDim2.fromOffset(22, 22), parent = emblem })
	stageNum.AnchorPoint = Vector2.new(0.5, 0.5)
	stageNum.Position = UDim2.fromOffset(52, 52)
	stageNum.BackgroundTransparency = 0
	stageNum.BackgroundColor3 = Col.Cyan
	stageNum.ZIndex = 10
	C.corner(11).Parent = stageNum
	refs.stageNum = stageNum
	local info = C.make("Frame", { Name = "Info", BackgroundTransparency = 1, Position = UDim2.fromOffset(92, 12), Size = UDim2.new(1, -104, 1, -20), Parent = card }, { C.list(Enum.FillDirection.Vertical, 3) })
	refs.planetName = C.text({ name = "Name", text = "PLANET", size = 16, font = F.Display, parent = info, order = 1, dims = UDim2.new(1, 0, 0, 22) })
	local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 2, Parent = info }, { C.list(Enum.FillDirection.Horizontal, 6, nil, Enum.VerticalAlignment.Center) })
	refs.stageName = C.text({ name = "Stage", text = "", size = S.Small, font = F.Bold, color = Col.Cyan, parent = row, order = 1, dims = UDim2.new(0, 0, 1, 0) })
	refs.stageName.AutomaticSize = Enum.AutomaticSize.X
	refs.branchChip = C.chip("Unspecialized", Col.TextMute, row, 2)
	refs.stageBar = C.bar({ color = Col.Cyan, height = 5, parent = info, order = 3 })
	refs.nextLabel = C.text({ name = "Next", text = "", size = S.Micro, font = F.Semi, color = Col.TextMute, parent = info, order = 4, dims = UDim2.new(1, 0, 0, 14) })
	C.tooltip(card, function()
		local st = UIData.Evolution.stage()
		if not st then
			return nil
		end
		local lines = { st.name .. " — " .. (st.description or "") }
		if st.next then
			table.insert(lines, "Next: " .. st.next.name .. " — " .. (st.next.goal or ""))
			for _, t in st.next.unmetTexts or {} do
				table.insert(lines, "• " .. t)
			end
		end
		return table.concat(lines, "\n")
	end)
	refs.card = card
end

local function resourcePill(parent: Instance, icon: string, color: Color3, order: number, width: number, tooltip: string)
	local pill = C.glass({ name = "Pill_" .. icon, variant = "panel", dims = UDim2.fromOffset(width, 40), parent = parent, order = order })
	C.icon(icon, 18, color, pill).Position = UDim2.fromOffset(12, 11)
	local v = C.text({ name = "Value", text = "0", size = 16, font = F.Bold, parent = pill, dims = UDim2.new(1, -44, 0, 22) })
	v.Position = UDim2.fromOffset(38, 4)
	local cap = C.caption(tooltip, pill)
	cap.Position = UDim2.fromOffset(38, 22)
	cap.Size = UDim2.new(1, -44, 0, 12)
	cap.TextSize = 9
	C.tooltip(pill, tooltip)
	return pill, v
end

local function resources(parent: Instance)
	local holder = C.make("Frame", { Name = "Resources", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -Sp.l, 0, Sp.m), Size = UDim2.fromOffset(420, 40), Parent = parent }, { C.list(Enum.FillDirection.Horizontal, Sp.s, Enum.HorizontalAlignment.Right) })
	local _, credits = resourcePill(holder, "credits", Col.Gold, 2, 132, "Credits")
	refs.credits = credits
	local energyPill, energy = resourcePill(holder, "energy", Col.Cyan, 3, 150, "Energy")
	refs.energy = energy
	refs.energyBar = C.bar({ color = Col.Cyan, height = 3, parent = energyPill })
	refs.energyBar.Instance.Position = UDim2.new(0, 10, 1, -5)
	refs.energyBar.Instance.Size = UDim2.new(1, -20, 0, 2)
	local levelPill, level = resourcePill(holder, "level", Col.Magenta, 1, 104, "Level")
	refs.level = level
	refs.xpBar = C.bar({ color = Col.Magenta, height = 3, parent = levelPill })
	refs.xpBar.Instance.Position = UDim2.new(0, 10, 1, -5)
	refs.xpBar.Instance.Size = UDim2.new(1, -20, 0, 2)
	refs.resources = holder
	-- matter strip
	local strip = C.make("Frame", { Name = "Matter", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -Sp.l, 0, Sp.m + 48), Size = UDim2.fromOffset(420, 28), Parent = parent }, { C.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right) })
	refs.matterStrip = strip
	refs.matterPool = C.pool(function()
		local p = C.make("TextButton", { Name = "Matter", Text = "", AutoButtonColor = false, Selectable = false, BackgroundColor3 = Col.Panel, BackgroundTransparency = 0.15, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 28), Parent = strip }, { C.corner(14), C.stroke(Col.Cyan, 0.8), C.pad(0, 10, 0, 8), C.list(Enum.FillDirection.Horizontal, 6, nil, Enum.VerticalAlignment.Center) })
		local ic = C.icon("matter", 14, Col.Cyan, p, 1)
		local t = C.text({ name = "Amount", text = "0", size = S.Small, font = F.Bold, parent = p, order = 2, dims = UDim2.new(0, 0, 1, 0) })
		t.AutomaticSize = Enum.AutomaticSize.X
		p.Activated:Connect(function() UIRoot.open("inventory") end)
		local item = { Instance = p, icon = ic, amount = t, tip = "" }
		C.tooltip(p, function() return item.tip end)
		return item
	end)
end

local function objectiveCard(parent: Instance)
	-- First 10 Minutes 2.0: premium objective card — icon badge, step pips, glowing progress, completion stamp and
	-- up to three optional "next discoveries" (same Hud.setObjective API, extra optional fields).
	local card = C.glass({ name = "Objective", variant = "panel", dims = UDim2.fromOffset(340, 0), pos = UDim2.fromOffset(Sp.l, Sp.m + 96 + Sp.s), parent = parent })
	card.AutomaticSize = Enum.AutomaticSize.Y
	C.pad(Sp.m, Sp.l, Sp.m, Sp.l).Parent = card
	C.list(Enum.FillDirection.Vertical, 6).Parent = card
	local objStroke = card:FindFirstChildOfClass("UIStroke")
	if objStroke then
		objStroke.Color = Color3.new(1, 1, 1)
		objStroke.Transparency = 0.25
		objStroke.Thickness = 1.5
		C.gradient(Col.Cyan, Col.Magenta, 0).Parent = objStroke
		refs.objStroke = objStroke
	end
	-- header: badge · caption · pips
	local head = C.make("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1, Parent = card })
	local badge = C.make("Frame", { Name = "Badge", BackgroundColor3 = Col.VioletDeep, Size = UDim2.fromOffset(30, 30), Parent = head }, { C.corner(15), C.stroke(Col.Cyan, 0.35, 1.5) })
	C.gradient(Color3.fromRGB(46, 62, 130), Col.VioletDeep, 90).Parent = badge
	refs.objBadge = badge
	refs.objIconName = ""
	local cap = C.caption("Objective", head, 0, Col.Cyan)
	cap.Position = UDim2.fromOffset(40, 8)
	cap.Size = UDim2.new(1, -120, 0, 14)
	refs.objCaption = cap
	local pips = C.make("Frame", { Name = "Pips", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(80, 10), Parent = head }, { C.list(Enum.FillDirection.Horizontal, 5, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })
	refs.objPips = pips
	refs.objStep = C.text({ name = "Step", text = "", size = S.Micro, font = F.Display, color = Col.TextMute, align = Enum.TextXAlignment.Right, parent = head, dims = UDim2.new(0, 60, 0, 14) })
	refs.objStep.AnchorPoint = Vector2.new(1, 0)
	refs.objStep.Position = UDim2.new(1, 0, 0, 8)
	refs.objStep.Visible = false
	refs.objTitle = C.text({ name = "Title", text = "", size = 16, font = F.Bold, autoY = true, parent = card, order = 2 })
	refs.objDetail = C.text({ name = "Detail", text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = card, order = 3 })
	refs.objDetail.RichText = true
	local prog = C.make("Frame", { Name = "Progress", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 4, Parent = card })
	refs.objBar = C.bar({ color = Col.Cyan, height = 6, parent = prog, dims = UDim2.new(1, -44, 0, 6) })
	refs.objBar.Instance.Position = UDim2.fromOffset(0, 4)
	local fill = refs.objBar.Instance:FindFirstChild("Fill")
	if fill then
		local g = fill:FindFirstChildOfClass("UIGradient")
		if g then
			g.Color = ColorSequence.new(Col.Cyan, Col.Magenta)
		end
	end
	refs.objPct = C.text({ name = "Pct", text = "", size = S.Micro, font = F.Display, color = Col.Cyan, align = Enum.TextXAlignment.Right, parent = prog, dims = UDim2.new(0, 40, 1, 0) })
	refs.objPct.AnchorPoint = Vector2.new(1, 0)
	refs.objPct.Position = UDim2.new(1, 0, 0, 0)
	refs.objProgress = prog
	refs.objAction = C.button({ text = "", style = "primary", dims = UDim2.new(0, 0, 0, 30), parent = card, order = 5, onClick = function()
		if objective and objective.action then
			objective.action()
		end
	end })
	refs.objAction.Instance.AutomaticSize = Enum.AutomaticSize.X
	-- next discoveries (optional, up to 3)
	local disc = C.make("Frame", { Name = "Discoveries", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6, Visible = false, Parent = card }, { C.list(Enum.FillDirection.Vertical, 4) })
	C.divider(disc, 0)
	C.caption("Next discoveries", disc, 1, Col.Magenta)
	refs.objDisc = disc
	refs.objDiscRows = {}
	for i = 1, 3 do
		local row = C.make("TextButton", { Name = "Row" .. i, Text = "", AutoButtonColor = false, BackgroundColor3 = Col.PanelHi, BackgroundTransparency = 0.5, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1 + i, Selectable = true, Parent = disc }, { C.corner(8), C.stroke(Col.Cyan, 0.8, 1) })
		local iconHolder = C.make("Frame", { Name = "Icon", BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(8, 8), Parent = row })
		local t = C.text({ name = "Text", text = "", size = S.Small, font = F.Semi, color = Col.Text, parent = row, dims = UDim2.new(1, -60, 0, 16) })
		t.Position = UDim2.fromOffset(32, 2)
		t.TextTruncate = Enum.TextTruncate.AtEnd
		local sub = C.text({ name = "Sub", text = "", size = S.Micro, color = Col.TextMute, parent = row, dims = UDim2.new(1, -60, 0, 13) })
		sub.Position = UDim2.fromOffset(32, 18)
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		local chev = C.icon("chevron", 12, Col.CyanDim, row)
		chev.AnchorPoint = Vector2.new(1, 0.5)
		chev.Position = UDim2.new(1, -10, 0.5, 0)
		local item: any = { Instance = row, iconHolder = iconHolder, text = t, sub = sub, action = nil, icon = "" }
		row.Activated:Connect(function()
			if item.action then
				UIRoot.sfx("Bot_Blip", 0.1, 1.8)
				item.action()
			end
		end)
		row.MouseEnter:Connect(function()
			Motion.tween(row, Theme.Motion.fast, { BackgroundTransparency = 0.25 }, nil, nil, "hover")
		end)
		row.MouseLeave:Connect(function()
			Motion.tween(row, Theme.Motion.fast, { BackgroundTransparency = 0.5 }, nil, nil, "hover")
		end)
		refs.objDiscRows[i] = item
	end
	-- completion stamp (overlay, no input)
	local stamp = C.make("Frame", { Name = "ObjectiveComplete", BackgroundColor3 = Col.Success, BackgroundTransparency = 1, Size = UDim2.fromOffset(340, 80), ZIndex = 20, Visible = false, Parent = parent }, { C.corner(Theme.Radius.l) })
	local stampRow = C.make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(260, 30), ZIndex = 21, Parent = stamp }, { C.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center) })
	local ck = C.make("Frame", { BackgroundColor3 = Col.Success, Size = UDim2.fromOffset(26, 26), ZIndex = 22, LayoutOrder = 1, Parent = stampRow }, { C.corner(13) })
	C.icon("check", 16, Col.Navy, ck).Position = UDim2.fromOffset(5, 5)
	local stampText = C.text({ text = "OBJECTIVE COMPLETE", size = S.Small, font = F.Display, color = Col.Success, parent = stampRow, order = 2, dims = UDim2.new(0, 0, 0, 20) })
	stampText.AutomaticSize = Enum.AutomaticSize.X
	stampText.ZIndex = 22
	local stampScale = C.make("UIScale", { Parent = stampRow })
	refs.objStamp, refs.objStampText, refs.objStampScale = stamp, stampText, stampScale
	refs.objective = card
end

local function dock(parent: Instance)
	local d = C.make("Frame", { Name = "Dock", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -Sp.l, 0.5, 30), Size = UDim2.fromOffset(64, 480), Parent = parent }, { C.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center) })
	refs.dock = d
	local items = {
		{ id = "dna", icon = "dna", label = "DNA Lab", key = "L" },
		{ id = "quests", icon = "objective", label = "Quests", key = "Y" }, -- daily/weekly quests (Live Gameplay)
		{ id = "harvester", icon = "harvester", label = "Harvester", key = "H" },
		{ id = "inventory", icon = "inventory", label = "Inventory", key = "I" },
		{ id = "codex", icon = "codex", label = "Codex", key = "K" },
		{ id = "expedition", icon = "expedition", label = "Expedition", key = "X" },
		{ id = "social", icon = "planet", label = "Planets", key = "P" },
		{ id = "store", icon = "store", label = "Store", key = "B" },
		{ id = "settings", icon = "settings", label = "Settings", key = "O" },
	}
	for i, it in items do
		local b = C.hexButton({ icon = it.icon, label = it.label, hotkey = it.key, size = 56, parent = d, order = i, onClick = function()
			UIRoot.toggle(it.id)
		end })
		dockButtons[it.id] = b
		table.insert(dockOrder, it.id)
	end
end

----------------------------------------------------------------------------------------------------
function Hud.layout(size: Vector2, mode: string)
	if not refs.card then
		return
	end
	local short = mode == "short"
	-- Left column stack: planet card -> resources -> matter -> objective. Top-centre stays free for the
	-- Cosmic Core Hunt banner, top-right for Roblox's player list.
	local colW = if short then 320 else 340
	local y = Sp.m
	refs.card.Size = UDim2.fromOffset(colW, 96)
	refs.card.Position = UDim2.fromOffset(Sp.l, y)
	y += 96 + Sp.s
	refs.resources.AnchorPoint = Vector2.zero
	refs.resources.Position = UDim2.fromOffset(Sp.l, y)
	refs.resources.Size = UDim2.fromOffset(colW, 40)
	local layoutR = refs.resources:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	layoutR.HorizontalAlignment = Enum.HorizontalAlignment.Left
	local pillW = math.floor((colW - 2 * Sp.s) / 3)
	for _, p in refs.resources:GetChildren() do
		if p:IsA("Frame") then
			p.Size = UDim2.fromOffset(pillW, 40)
		end
	end
	y += 40 + Sp.s
	refs.matterStrip.Visible = not short
	refs.matterStrip.AnchorPoint = Vector2.zero
	refs.matterStrip.Position = UDim2.fromOffset(Sp.l, y)
	refs.matterStrip.Size = UDim2.fromOffset(colW, 28)
	local layoutM = refs.matterStrip:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	layoutM.HorizontalAlignment = Enum.HorizontalAlignment.Left
	if not short then
		y += 28 + Sp.s
	end
	refs.objective.Position = UDim2.fromOffset(Sp.l, y)
	refs.objective.Size = UDim2.fromOffset(colW, 0)
	local dk = refs.dock :: Frame
	local layout = dk:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	local visibleCount = 0
	for _, id in dockOrder do
		if dockButtons[id].Instance.Visible then
			visibleCount += 1
		end
	end
	for _, bt in dockButtons do
		local cap = bt.Instance:FindFirstChild("Caption") :: TextLabel
		cap.Visible = not short
		bt.Instance.Size = UDim2.fromOffset(56, if short then 58 else 74)
	end
	if short then
		layout.FillDirection = Enum.FillDirection.Horizontal
		dk.AnchorPoint = Vector2.new(0.5, 1)
		dk.Position = UDim2.new(0.5, 0, 1, -Sp.s)
		dk.Size = UDim2.fromOffset(visibleCount * 62, 60)
	else
		layout.FillDirection = Enum.FillDirection.Vertical
		dk.AnchorPoint = Vector2.new(1, 0.5)
		-- QA-2026-11-21: with 8 buttons (Planets, Store) the dock outgrew a 720p canvas and the last button was
		-- clipped at the bottom edge. Keep the preferred drop below centre only as far as the screen allows, and
		-- fall back to caption-less buttons (as on phones) when even a centred dock would not fit.
		local compact = visibleCount * 76 > size.Y - 2 * Sp.m
		local perButton = if compact then 60 else 76
		local dockH = visibleCount * perButton
		local room = math.max(0, math.floor((size.Y - dockH) / 2) - Sp.m)
		dk.Position = UDim2.new(1, -Sp.m, 0.5, math.min(if mode == "narrow" then 40 else 70, room))
		dk.Size = UDim2.fromOffset(64, dockH)
		if compact then
			for _, bt in dockButtons do
				(bt.Instance:FindFirstChild("Caption") :: TextLabel).Visible = false
				bt.Instance.Size = UDim2.fromOffset(56, 58)
			end
		end
	end
end

local function setIcon(name: string)
	if refs.objIconName == name then
		return
	end
	refs.objIconName = name
	for _, ch in refs.objBadge:GetChildren() do
		if ch:IsA("Frame") then
			ch:Destroy()
		end
	end
	local ic = C.icon(name, 16, Col.Cyan, refs.objBadge)
	ic.Position = UDim2.fromOffset(7, 7)
end

local function setPips(step: number?, total: number?)
	for _, ch in refs.objPips:GetChildren() do
		if ch:IsA("Frame") then
			ch:Destroy()
		end
	end
	if not (step and total) then
		return
	end
	for i = 1, total do
		local done, cur = i < step, i == step
		C.make("Frame", { Name = "Pip" .. i, BackgroundColor3 = if done then Col.Success elseif cur then Col.Cyan else Col.PanelHi, BackgroundTransparency = if done or cur then 0 else 0.2, Size = UDim2.fromOffset(if cur then 18 else 8, 8), LayoutOrder = i, Parent = refs.objPips }, { C.corner(4) })
	end
end

local function apply(o: any)
	objective = o
	local card = refs.objective
	card.Visible = o ~= nil
	if not o then
		return
	end
	refs.objTitle.Text = o.title or ""
	refs.objDetail.Text = o.detail or ""
	refs.objDetail.Visible = (o.detail or "") ~= ""
	refs.objCaption.Text = string.upper(o.caption or (if o.step then "Objective" else "Next goal"))
	refs.objStep.Text = if o.step and o.total then string.format("%d / %d", o.step, o.total) else ""
	setIcon(o.icon or "objective")
	setPips(o.step, o.total)
	refs.objProgress.Visible = o.progress ~= nil
	if o.progress then
		refs.objBar:set(o.progress)
		refs.objPct.Text = string.format("%d%%", math.floor(math.clamp(o.progress, 0, 1) * 100 + 0.5))
	end
	refs.objAction.Instance.Visible = o.actionText ~= nil
	if o.actionText then
		refs.objAction:setText(o.actionText)
	end
	local list = o.discoveries or {}
	refs.objDisc.Visible = #list > 0
	for i, item in refs.objDiscRows do
		local d = list[i]
		item.Instance.Visible = d ~= nil
		if d then
			item.text.Text = d.text or ""
			item.sub.Text = d.sub or ""
			item.action = d.action
			if item.icon ~= (d.icon or "star") then
				item.icon = d.icon or "star"
				for _, ch in item.iconHolder:GetChildren() do
					ch:Destroy()
				end
				C.icon(item.icon, 16, d.color or Col.Cyan, item.iconHolder)
			end
		end
	end
end

local completing = false
local pendingObjective: any = nil

-- opts = { completed: boolean? } -> plays the "OBJECTIVE COMPLETE" stamp, then shows `o`
function Hud.setObjective(o: any, opts: any?)
	if not refs.objective then
		objective = o
		return
	end
	if opts and opts.completed and refs.objective.Visible then
		pendingObjective = o
		if completing then
			return
		end
		completing = true
		UIRoot.sfx("UI_ObjectiveDone")
		local stamp = refs.objStamp :: Frame
		-- cover the card exactly (design units: the HUD layer is scaled by UIRoot)
		local card = refs.objective :: Frame
		local k = if card.Size.X.Offset > 0 and card.AbsoluteSize.X > 0 then card.Size.X.Offset / card.AbsoluteSize.X else 1
		stamp.Position = card.Position
		stamp.AnchorPoint = card.AnchorPoint
		stamp.Size = UDim2.fromOffset(card.Size.X.Offset, math.max(60, card.AbsoluteSize.Y * k))
		stamp.Visible = true
		local reduced = require(Kit.Prefs).reducedMotion()
		if reduced then
			stamp.BackgroundTransparency = 0.82
			task.delay(0.9, function()
				stamp.Visible = false
				completing = false
				apply(pendingObjective)
			end)
		else
			stamp.BackgroundTransparency = 1
			refs.objStampScale.Scale = 0.6
			Motion.tween(stamp, 0.18, { BackgroundTransparency = 0.78 }, nil, nil, "stamp")
			Motion.tween(refs.objStampScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, "stampScale")
			if refs.objStroke then
				refs.objStroke.Transparency = 0
			end
			task.delay(1.05, function()
				Motion.tween(stamp, 0.25, { BackgroundTransparency = 1 }, nil, nil, "stamp")
				task.delay(0.25, function()
					stamp.Visible = false
					completing = false
					if refs.objStroke then
						refs.objStroke.Transparency = 0.25
					end
					apply(pendingObjective)
					UIRoot.sfx("UI_ObjectiveNew")
				end)
			end)
		end
		return
	end
	if completing then
		pendingObjective = o
		return
	end
	apply(o)
end

-- dock helpers used by onboarding (pulse) and panels (active state)
function Hud.dockButton(id: string): any
	return dockButtons[id]
end
function Hud.pulse(id: string?, on: boolean)
	for bid, b in dockButtons do
		b:setPulse(on and bid == id)
	end
end

function Hud.refresh()
	local snap = UIData.snapshot()
	if not snap or not refs.card then
		return
	end
	local slot = UIData.slot()
	refs.planetName.Text = if slot then string.format("PLANET %02d", slot) else "NO PLANET"
	local st = UIData.Evolution.stage()
	if st then
		refs.stageName.Text = string.upper(st.name or "")
		refs.stageNum.Text = tostring(st.stage or 0)
		local sc = STAGE_COLORS[st.stage or 0] or Col.Cyan
		refs.stageNum.BackgroundColor3 = sc
		C.setChip(refs.branchChip, st.branchName or "Unspecialized", if st.branch and st.branch ~= "None" then Col.Magenta else Col.TextMute)
		if st.next then
			local unmet = st.next.unmet or {}
			local have, need = 0, 0
			for _, u in unmet do
				if type(u) == "table" and type(u.have) == "number" and type(u.need) == "number" and u.need > 0 then
					have += math.min(u.have, u.need)
					need += u.need
				end
			end
			local frac = if #unmet == 0 then 1 elseif need > 0 then have / need else 0
			refs.stageBar:set(frac)
			refs.nextLabel.Text = "NEXT · " .. string.upper(st.next.name or "") .. (if st.next.unmetTexts and st.next.unmetTexts[1] then "  —  " .. st.next.unmetTexts[1] else "")
		else
			refs.stageBar:set(1)
			refs.nextLabel.Text = "FULLY EVOLVED"
		end
	end
	local credits = (snap.currencies and snap.currencies.Credits) or 0
	if lastCredits < 0 then
		refs.credits.Text = UIData.fmt(credits)
	elseif credits ~= lastCredits then
		Motion.count(refs.credits, lastCredits, credits, UIData.fmt)
	end
	lastCredits = credits
	local energy = (snap.currencies and snap.currencies.CosmicEnergy) or 0
	local cap = snap.energyCap or 100
	refs.energy.Text = string.format("%s / %s", UIData.fmt(energy), UIData.fmt(cap))
	refs.energyBar:set(energy / math.max(1, cap))
	refs.level.Text = "LV " .. tostring(snap.level or 1)
	refs.xpBar:set((snap.xp or 0) / math.max(1, snap.xpToNext or 1))
	-- matter strip (Developer B's display order)
	local mats = UIData.Evolution.materials()
	refs.matterPool:sync(#mats, function(item, i)
		local m = mats[i]
		item.amount.Text = UIData.fmt(m.amount)
		item.amount.TextColor3 = if m.amount > 0 then Col.Text else Col.TextMute
		local C3 = m.color or Col.Cyan
		for _, d in item.icon:GetDescendants() do
			if d:IsA("Frame") and d.BackgroundColor3 ~= Color3.new(1, 1, 1) then
				d.BackgroundColor3 = C3
			end
		end
		item.tip = string.format("%s — %s", m.name, m.description or "")
	end)
	-- dock state
	local avail = UIData.availableReactions()
	dockButtons.dna:setBadge(avail)
	if dockButtons.quests then
		local snap = UIData.snapshot()
		dockButtons.quests:setBadge(snap and snap.quests and snap.quests.claimable or 0)
		dockButtons.quests.Instance.Visible = UIRoot.isAvailable("quests")
	end
	dockButtons.expedition.Instance.Visible = UIRoot.isAvailable("expedition")
	dockButtons.social.Instance.Visible = UIRoot.isAvailable("social")
	if dockButtons.store then
		dockButtons.store.Instance.Visible = UIRoot.isAvailable("store")
	end
	Hud.layout(UIRoot.size(), UIRoot.mode())
end

function Hud.init()
	local layer = UIRoot.layer("Hud")
	planetCard(layer)
	resources(layer)
	objectiveCard(layer)
	dock(layer)
	Hud.setObjective(nil)
	UIRoot.Resized:Connect(Hud.layout)
	UIRoot.PanelChanged:Connect(function(id)
		for bid, b in dockButtons do
			b:setActive(bid == id)
		end
	end)
	UIData.Changed:Connect(Hud.refresh)
	UIData.HarvestingChanged:Connect(function(on)
		UIRoot.setHudHidden("harvesting", on)
		if on then
			UIRoot.close()
		end
	end)
	Hud.layout(UIRoot.size(), UIRoot.mode())
	Hud.refresh()
end

return Hud
