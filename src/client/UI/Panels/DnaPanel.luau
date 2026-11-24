--!strict
-- DnaPanel — owner: Developer A. PLANET DNA LAB: DNA parameters, available matter, discoverable reactions
-- (costs, conditions, DNA preview, formations, first-discovery rewards) and evolution progress + branch
-- specialization. Replaces Developer B's PlanetLabUI presentation (its header allows it); every number and
-- every action goes through EvolutionClient, so previews match the server's rules exactly.
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local EC = UIData.Evolution
-- Solar Storm marker (Live Gameplay): which reactions currently refund part of their matter
local okEv, EventClient = pcall(function()
	return require(script.Parent.Parent.Parent:WaitForChild("Events"):WaitForChild("EventClient")) :: any
end)
local SURGE_HEX = Color3.fromRGB(255, 138, 61):ToHex()
local function surging(id: string): boolean
	return okEv and EventClient and EventClient.isBoosted(id) == true
end

local DnaPanel = {}

local STATUS_TEXT = { AVAILABLE = "Ready", NEEDS_MATERIALS = "Needs matter", LOCKED = "Locked", DONE = "Completed", MASTERED = "Mastered", COMMITTED = "Active", FUTURE = "Coming later" }
local function statusColor(s: string?): Color3
	return Theme.Status[s or "LOCKED"] or Col.TextMute
end
local DNA_SHORT = { Temperature = "Temp", Water = "Water", Life = "Life", CosmicEnergy = "Energy" }

function DnaPanel.build(shell: any)
	local body: Frame = shell.Body
	local state = { tab = "reactions", filter = "all", selected = nil :: string?, branch = nil :: string?, busy = false, compactDetail = false }
	local ui: any = {}

	------------------------------------------------------------------ left column: DNA, matter, stage
	local left = C.make("Frame", { Name = "Left", BackgroundTransparency = 1, Size = UDim2.new(0, 250, 1, 0), Parent = body })
	local leftScroll = C.scroll({ name = "LeftScroll", parent = left, gap = Sp.m })
	C.caption("Planet DNA", leftScroll, 1)
	ui.dnaRows = {}
	for i, id in { "Temperature", "Water", "Life", "CosmicEnergy" } do
		local row = C.make("Frame", { Name = "Dna_" .. id, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1 + i, Parent = leftScroll })
		local name = C.text({ text = id, size = S.Small, font = F.Semi, color = Col.TextDim, parent = row, dims = UDim2.new(0.6, 0, 0, 18) })
		local val = C.text({ text = "0", size = S.Small, font = F.Bold, align = Enum.TextXAlignment.Right, parent = row, dims = UDim2.new(0.4, 0, 0, 18) })
		val.Position = UDim2.fromScale(0.6, 0)
		val.RichText = true
		local bar = C.bar({ height = 6, parent = row })
		bar.Instance.Position = UDim2.fromOffset(0, 22)
		ui.dnaRows[id] = { name = name, val = val, bar = bar, row = row }
		C.tooltip(row, function()
			for _, d in EC.dna() do
				if d.id == id then
					return d.description
				end
			end
			return nil
		end)
	end
	C.divider(leftScroll, 10)
	C.caption("Available matter", leftScroll, 11)
	local matterList = C.make("Frame", { Name = "Matter", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 12, Parent = leftScroll }, { C.list(Enum.FillDirection.Vertical, 4) })
	ui.matterPool = C.pool(function()
		local r = C.make("Frame", { Name = "M", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = matterList })
		local ic = C.icon("matter", 12, Col.Cyan, r)
		ic.Position = UDim2.fromOffset(0, 4)
		local n = C.text({ text = "", size = S.Small, color = Col.TextDim, parent = r, dims = UDim2.new(1, -80, 1, 0) })
		n.Position = UDim2.fromOffset(20, 0)
		local a = C.text({ text = "", size = S.Small, font = F.Bold, align = Enum.TextXAlignment.Right, parent = r, dims = UDim2.new(0, 60, 1, 0) })
		a.AnchorPoint = Vector2.new(1, 0)
		a.Position = UDim2.fromScale(1, 0)
		return { Instance = r, icon = ic, name = n, amount = a }
	end)
	C.divider(leftScroll, 20)
	C.caption("Evolution", leftScroll, 21)
	ui.stageName = C.text({ text = "", size = S.Heading, font = F.Display, color = Col.Cyan, parent = leftScroll, order = 22 })
	ui.branchChip = C.chip("Unspecialized", Col.TextMute, leftScroll, 23)
	ui.nextTitle = C.text({ text = "", size = S.Small, font = F.Semi, color = Col.Text, autoY = true, parent = leftScroll, order = 24 })
	local checklist = C.make("Frame", { Name = "Checklist", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 25, Parent = leftScroll }, { C.list(Enum.FillDirection.Vertical, 3) })
	ui.checkPool = C.pool(function()
		local r = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = checklist })
		local dot = C.make("Frame", { BackgroundColor3 = Col.Warn, Size = UDim2.fromOffset(5, 5), Position = UDim2.fromOffset(2, 7), Parent = r }, { C.corner(3) })
		local t = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = r })
		t.Size = UDim2.new(1, -14, 0, 0)
		t.Position = UDim2.fromOffset(14, 0)
		return { Instance = r, dot = dot, text = t }
	end)

	------------------------------------------------------------------ right area: compact DNA strip, tabs, content
	local right = C.make("Frame", { Name = "Right", BackgroundTransparency = 1, Position = UDim2.fromOffset(266, 0), Size = UDim2.new(1, -266, 1, 0), Parent = body })
	local strip = C.make("Frame", { Name = "DnaStrip", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Visible = false, Parent = right }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
	ui.stripBars = {}
	for i, id in { "Temperature", "Water", "Life", "CosmicEnergy" } do
		local cell = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0.25, -6, 1, 0), LayoutOrder = i, Parent = strip })
		local l = C.text({ text = DNA_SHORT[id], size = S.Micro, font = F.Bold, color = Col.TextDim, parent = cell, dims = UDim2.new(1, 0, 0, 16) })
		l.RichText = true
		local b = C.bar({ height = 5, parent = cell })
		b.Instance.Position = UDim2.fromOffset(0, 22)
		ui.stripBars[id] = { label = l, bar = b }
	end
	ui.strip = strip
	local tabs = C.tabs({ items = { { id = "reactions", label = "Reactions", icon = "flask" }, { id = "specialize", label = "Specialize", icon = "star" } }, parent = right, onSelect = function(id)
		state.tab = id
		state.compactDetail = false
		DnaPanel._refresh()
	end })
	ui.tabs = tabs
	local content = C.make("Frame", { Name = "Content", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 1, -46), Parent = right })
	ui.content = content

	-- reactions: list + detail
	local listCol = C.make("Frame", { Name = "ListCol", BackgroundTransparency = 1, Size = UDim2.new(0, 300, 1, 0), Parent = content })
	local filters = C.make("Frame", { Name = "Filters", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), Parent = listCol }, { C.list(Enum.FillDirection.Horizontal, 6) })
	ui.filterButtons = {}
	for i, f in { { "all", "All" }, { "ready", "Ready" }, { "new", "Undiscovered" } } do
		ui.filterButtons[f[1]] = C.button({ text = f[2], style = "ghost", dims = UDim2.new(0, 0, 0, 26), parent = filters, order = i, size = S.Micro, onClick = function()
			state.filter = f[1]
			DnaPanel._refresh()
		end })
		ui.filterButtons[f[1]].Instance.AutomaticSize = Enum.AutomaticSize.X
	end
	local list = C.scroll({ name = "Reactions", parent = listCol, gap = 6 })
	list.Position = UDim2.fromOffset(0, 36)
	list.Size = UDim2.new(1, 0, 1, -36)
	ui.list = list
	ui.empty = C.text({ text = "", size = S.Small, color = Col.TextMute, wrap = true, parent = listCol, dims = UDim2.new(1, 0, 0, 60) })
	ui.empty.Position = UDim2.fromOffset(0, 44)
	ui.rowPool = C.pool(function()
		local b = C.make("TextButton", { Name = "Reaction", Text = "", AutoButtonColor = false, BackgroundColor3 = Col.PanelHi, BackgroundTransparency = 0.55, Size = UDim2.new(1, 0, 0, 56), SelectionImageObject = C.selectionImage, Parent = list }, { C.corner(Theme.Radius.m) })
		local st = C.stroke(Col.Cyan, 0.85)
		st.Parent = b
		local stripe = C.make("Frame", { Name = "Stripe", BackgroundColor3 = Col.Cyan, Size = UDim2.new(0, 3, 1, -16), Position = UDim2.fromOffset(6, 8), Parent = b }, { C.corner(2) })
		local name = C.text({ text = "", size = S.Body, font = F.Bold, parent = b, dims = UDim2.new(1, -130, 0, 20) })
		name.Position = UDim2.fromOffset(18, 8)
		local sub = C.text({ text = "", size = S.Micro, font = F.Semi, color = Col.TextMute, parent = b, dims = UDim2.new(1, -30, 0, 16) })
		sub.Position = UDim2.fromOffset(18, 30)
		sub.RichText = true
		local chip = C.chip("Ready", Col.Success, b)
		chip.AnchorPoint = Vector2.new(1, 0)
		chip.Position = UDim2.new(1, -10, 0, 9)
		local item: any = { Instance = b, stroke = st, stripe = stripe, name = name, sub = sub, chip = chip, id = "" }
		b.MouseEnter:Connect(function() if state.selected ~= item.id then st.Transparency = 0.5 end end)
		b.MouseLeave:Connect(function() if state.selected ~= item.id then st.Transparency = 0.85 end end)
		b.Activated:Connect(function()
			state.selected = item.id
			state.compactDetail = true
			DnaPanel._refresh()
		end)
		return item
	end)

	local detail = C.glass({ name = "Detail", variant = "card", parent = content })
	detail.Position = UDim2.fromOffset(312, 0)
	detail.Size = UDim2.new(1, -312, 1, 0)
	ui.detail = detail
	local back = C.button({ text = "Back", icon = "back", style = "ghost", dims = UDim2.new(0, 0, 0, 28), parent = detail, size = S.Micro, onClick = function()
		state.compactDetail = false
		DnaPanel._refresh()
	end })
	back.Instance.AutomaticSize = Enum.AutomaticSize.X
	back.Instance.Position = UDim2.fromOffset(12, 10)
	back.Instance.ZIndex = 5
	ui.back = back
	local dScroll = C.scroll({ name = "DetailScroll", parent = detail, gap = Sp.s, padding = Sp.l })
	dScroll.Size = UDim2.new(1, 0, 1, -64)
	ui.dScroll = dScroll
	ui.dTitle = C.text({ text = "", size = S.Title, font = F.Display, autoY = true, parent = dScroll, order = 1 })
	ui.dHeadline = C.text({ text = "", size = S.Body, font = F.Semi, color = Col.Cyan, autoY = true, parent = dScroll, order = 2 })
	ui.dDesc = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = dScroll, order = 3 })
	local function section(title: string, order: number)
		local holder = C.make("Frame", { Name = "Sec_" .. title, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = dScroll }, { C.list(Enum.FillDirection.Vertical, 4) })
		C.caption(title, holder, 0)
		local rows = C.make("Frame", { Name = "Rows", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = holder }, { C.list(Enum.FillDirection.Vertical, 4) })
		return holder, rows
	end
	ui.secCost, ui.costRows = section("Required matter", 10)
	ui.costPool = C.pool(function()
		local r = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), Parent = ui.costRows })
		local ic = C.icon("matter", 13, Col.Cyan, r)
		ic.Position = UDim2.fromOffset(0, 4)
		local n = C.text({ text = "", size = S.Small, parent = r, dims = UDim2.new(1, -120, 1, 0) })
		n.Position = UDim2.fromOffset(22, 0)
		local a = C.text({ text = "", size = S.Small, font = F.Bold, align = Enum.TextXAlignment.Right, parent = r, dims = UDim2.new(0, 100, 1, 0) })
		a.AnchorPoint = Vector2.new(1, 0)
		a.Position = UDim2.fromScale(1, 0)
		a.RichText = true
		return { Instance = r, icon = ic, name = n, amount = a }
	end)
	ui.secDna, ui.dnaChips = section("Effect on DNA", 11)
	local chipsRow = ui.dnaChips
	chipsRow:FindFirstChildOfClass("UIListLayout").FillDirection = Enum.FillDirection.Horizontal
	chipsRow:FindFirstChildOfClass("UIListLayout").Wraps = true
	ui.dnaChipPool = C.pool(function()
		return C.chip("", Col.Cyan, chipsRow)
	end)
	ui.secForm, ui.formRows = section("New formations", 12)
	ui.formPool = C.pool(function()
		local r = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = ui.formRows })
		C.icon("formation", 13, Col.Success, r).Position = UDim2.fromOffset(0, 3)
		local t = C.text({ text = "", size = S.Small, font = F.Semi, color = Col.Success, parent = r, dims = UDim2.new(1, -22, 1, 0) })
		t.Position = UDim2.fromOffset(22, 0)
		return { Instance = r, text = t }
	end)
	ui.secReward, ui.rewardRows = section("First discovery reward", 13)
	ui.rewardText = C.text({ text = "", size = S.Small, font = F.Bold, color = Col.Gold, autoY = true, parent = ui.rewardRows })
	ui.secReq, ui.reqRows = section("Requirements", 14)
	ui.reqPool = C.pool(function()
		local r = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = ui.reqRows })
		C.icon("lock", 12, Col.Warn, r).Position = UDim2.fromOffset(0, 3)
		local t = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = r })
		t.Size = UDim2.new(1, -22, 0, 0)
		t.Position = UDim2.fromOffset(22, 0)
		return { Instance = r, text = t }
	end)
	ui.secExtra, ui.extraRows = section("Consequences", 15)
	ui.extraText = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = ui.extraRows })

	local actionBar = C.make("Frame", { Name = "ActionBar", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 64), Parent = detail }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l) })
	C.divider(actionBar).Position = UDim2.fromOffset(0, -Sp.m)
	ui.reason = C.text({ text = "", size = S.Small, color = Col.TextMute, wrap = true, parent = actionBar, dims = UDim2.new(1, -190, 1, 0) })
	ui.action = C.button({ text = "React", icon = "flask", style = "solid", dims = UDim2.fromOffset(176, 40), parent = actionBar, onClick = function()
		DnaPanel._act()
	end })
	ui.action.Instance.AnchorPoint = Vector2.new(1, 0.5)
	ui.action.Instance.Position = UDim2.new(1, 0, 0.5, 0)

	-- specialize: branch grid (shares the detail card)
	local branchCol = C.make("Frame", { Name = "BranchCol", BackgroundTransparency = 1, Size = UDim2.new(0, 300, 1, 0), Visible = false, Parent = content })
	local bList = C.scroll({ name = "Branches", parent = branchCol, gap = 6 })
	ui.branchCol = branchCol
	ui.listCol = listCol
	ui.branchPool = C.pool(function()
		local b = C.make("TextButton", { Name = "Branch", Text = "", AutoButtonColor = false, BackgroundColor3 = Col.PanelHi, BackgroundTransparency = 0.55, Size = UDim2.new(1, 0, 0, 62), SelectionImageObject = C.selectionImage, Parent = bList }, { C.corner(Theme.Radius.m) })
		local st = C.stroke(Col.Cyan, 0.85)
		st.Parent = b
		local sw = C.make("Frame", { Name = "Swatch", BackgroundColor3 = Col.Cyan, Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(12, 16), Rotation = 45, Parent = b }, { C.corner(6) })
		local name = C.text({ text = "", size = S.Body, font = F.Bold, parent = b, dims = UDim2.new(1, -150, 0, 20) })
		name.Position = UDim2.fromOffset(56, 10)
		local focus = C.text({ text = "", size = S.Micro, font = F.Semi, color = Col.TextMute, parent = b, dims = UDim2.new(1, -66, 0, 16) })
		focus.Position = UDim2.fromOffset(56, 34)
		local chip = C.chip("", Col.TextMute, b)
		chip.AnchorPoint = Vector2.new(1, 0)
		chip.Position = UDim2.new(1, -10, 0, 10)
		local item: any = { Instance = b, stroke = st, swatch = sw, name = name, focus = focus, chip = chip, id = "" }
		b.Activated:Connect(function()
			state.branch = item.id
			state.compactDetail = true
			DnaPanel._refresh()
		end)
		return item
	end)

	------------------------------------------------------------------ data -> view
	local function currentReaction(rs: { any }): any
		for _, r in rs do
			if r.id == state.selected then
				return r
			end
		end
		return nil
	end
	local function currentBranch(bs: { any }): any
		for _, b in bs do
			if b.id == state.branch then
				return b
			end
		end
		return nil
	end

	local function paintDna(preview: { [string]: number }?)
		for _, d in EC.dna() do
			local row = ui.dnaRows[d.id]
			local sb = ui.stripBars[d.id]
			local delta = preview and preview[d.id] or 0
			local after = math.clamp(d.value + delta, 0, 100)
			local valueText = if delta ~= 0 then string.format("%d <font color=\"#%s\">→ %d</font>", d.value, (if delta > 0 then Col.Success else Col.Danger):ToHex(), after) else tostring(d.value)
			if row then
				row.name.Text = d.name
				row.val.Text = valueText
				row.bar:setColor(d.color or Col.Cyan)
				row.bar:set(d.value / 100, if delta ~= 0 then after / 100 else nil)
			end
			if sb then
				sb.label.Text = string.upper(DNA_SHORT[d.id] or d.name) .. "  " .. valueText
				sb.bar:setColor(d.color or Col.Cyan)
				sb.bar:set(d.value / 100, if delta ~= 0 then after / 100 else nil)
			end
		end
	end

	local function fillCosts(costs: { any })
		ui.secCost.Visible = #costs > 0
		ui.costPool:sync(#costs, function(item, i)
			local c = costs[i]
			item.name.Text = c.name
			item.amount.Text = string.format("<font color=\"#%s\">%s</font> / %s", (if c.ok then Col.Success else Col.Danger):ToHex(), UIData.fmt(c.have), UIData.fmt(c.need))
			local color = UIData.materialColor(c.id)
			for _, d in item.icon:GetDescendants() do
				if d:IsA("Frame") and d.BackgroundColor3 ~= Color3.new(1, 1, 1) then
					d.BackgroundColor3 = color
				end
			end
		end)
	end

	local function fillReq(texts: { string })
		ui.secReq.Visible = #texts > 0
		ui.reqPool:sync(#texts, function(item, i)
			item.text.Text = texts[i]
		end)
	end

	local function showReaction(r: any)
		ui.dTitle.Text = string.upper(r.name)
		ui.dHeadline.Text = r.headline or ""
		ui.dHeadline.Visible = (r.headline or "") ~= ""
		ui.dDesc.Text = (r.description or "") .. (if surging(r.id) then "\nSOLAR SURGE: half of this reaction's matter cost is returned when it completes during the storm." else "")
		fillCosts(r.costs or {})
		local chips = {}
		for _, id in { "Temperature", "Water", "Life", "CosmicEnergy" } do
			local v = r.dnaDelta and r.dnaDelta[id] or 0
			if v ~= 0 then
				table.insert(chips, { text = string.format("%s %s%d", DNA_SHORT[id], if v > 0 then "+" else "−", math.abs(v)), color = if v > 0 then Col.Success else Col.Danger })
			end
		end
		ui.secDna.Visible = #chips > 0
		ui.dnaChipPool:sync(#chips, function(chip, i)
			C.setChip(chip, chips[i].text, chips[i].color)
		end)
		local forms = r.formations or {}
		ui.secForm.Visible = #forms > 0
		ui.formPool:sync(#forms, function(item, i)
			item.text.Text = string.format("%s%s", forms[i].name, if (forms[i].to or 1) > 1 then string.format("  ×%d", forms[i].to) else "")
		end)
		local rw = r.reward
		ui.secReward.Visible = rw ~= nil
		if rw then
			local parts = {}
			if rw.credits then
				table.insert(parts, UIData.fmt(rw.credits) .. " credits")
			end
			if rw.xp then
				table.insert(parts, rw.xp .. " XP")
			end
			if type(rw.materials) == "table" then
				for id, n in rw.materials do
					local d = UIData.materialDef(id)
					table.insert(parts, string.format("%d %s", n, d and d.displayName or id))
				end
			end
			if rw.cosmetic then
				table.insert(parts, "cosmetic: " .. tostring(rw.cosmetic))
			end
			ui.rewardText.Text = table.concat(parts, "  ·  ")
		end
		fillReq(r.unmet or {})
		ui.secExtra.Visible = false
		-- action
		local onPlanet = UIData.onOwnPlanet()
		ui.action.Instance.Visible = true
		if r.available and not onPlanet then
			ui.action:setText("Travel home")
			ui.action:setStyle("primary")
			ui.action:setEnabled(true)
			ui.reason.Text = "Reactions happen on your own planet."
			state.actionKind = "travel"
		elseif r.available then
			ui.action:setText("React")
			ui.action:setStyle("solid")
			ui.action:setEnabled(not state.busy)
			ui.reason.Text = if r.completions and r.completions > 0 then string.format("Completed %d×", r.completions) else "Ready — all requirements met."
			state.actionKind = "react"
		else
			ui.action:setText(STATUS_TEXT[r.status] or "Locked")
			ui.action:setStyle("ghost")
			ui.action:setEnabled(false)
			ui.reason.Text = if r.status == "DONE" then "Already completed." elseif (r.unmet and r.unmet[1]) then r.unmet[1] else "Not available yet."
			state.actionKind = nil
		end
		paintDna(r.dnaDelta)
	end

	local function showBranch(b: any)
		ui.dTitle.Text = string.upper(b.name)
		ui.dHeadline.Text = b.headline or ""
		ui.dHeadline.Visible = (b.headline or "") ~= ""
		ui.dDesc.Text = string.format("Focus: %s%s", b.focus or "—", if b.capstone then "\nCapstone landmark: " .. b.capstone else "")
		fillCosts(b.costs or {})
		ui.secDna.Visible = false
		local forms = {}
		for _, f in b.formations or {} do
			table.insert(forms, { name = f })
		end
		ui.secForm.Visible = #forms > 0
		ui.formPool:sync(#forms, function(item, i)
			item.text.Text = forms[i].name
		end)
		ui.secReward.Visible = false
		fillReq(b.unmet or {})
		ui.secExtra.Visible = (b.consequences or "") ~= ""
		ui.extraText.Text = b.consequences or ""
		paintDna(nil)
		if b.status == "COMMITTED" then
			ui.action:setText("Active branch")
			ui.action:setStyle("ghost")
			ui.action:setEnabled(false)
			ui.reason.Text = "Your planet is specialized in this branch."
			state.actionKind = nil
		elseif b.available then
			ui.action:setText(if b.isRespec then "Re-specialize" else "Specialize")
			ui.action:setStyle("danger")
			ui.action:setEnabled(not state.busy)
			ui.reason.Text = "Permanent choice for your planet's identity (can be changed later at a cost)."
			state.actionKind = "commit"
		else
			ui.action:setText(STATUS_TEXT[b.status] or "Locked")
			ui.action:setStyle("ghost")
			ui.action:setEnabled(false)
			ui.reason.Text = if b.status == "FUTURE" then "This branch arrives in a future update." elseif (b.unmet and b.unmet[1]) then b.unmet[1] else "Not available yet."
			state.actionKind = nil
		end
	end

	function DnaPanel._refresh()
		local compact = UIRoot.mode() ~= "wide"
		local st = EC.stage()
		if st then
			ui.stageName.Text = string.upper(st.name or "")
			C.setChip(ui.branchChip, st.branchName or "Unspecialized", if st.branch and st.branch ~= "None" then Col.Magenta else Col.TextMute)
			local items = {}
			if st.next then
				ui.nextTitle.Text = "Next: " .. (st.next.name or "") .. " — " .. (st.next.goal or "")
				items = st.next.unmetTexts or {}
			else
				ui.nextTitle.Text = "Your planet is fully evolved."
			end
			ui.checkPool:sync(#items, function(item, i)
				item.text.Text = items[i]
			end)
			shell.Subtitle.Text = string.format("STAGE %d · %s", st.stage or 0, string.upper(st.name or ""))
		end
		local mats = EC.materials()
		ui.matterPool:sync(#mats, function(item, i)
			local mm = mats[i]
			item.name.Text = mm.name
			item.amount.Text = UIData.fmt(mm.amount)
			item.amount.TextColor3 = if mm.amount > 0 then Col.Text else Col.TextMute
			for _, d in item.icon:GetDescendants() do
				if d:IsA("Frame") and d.BackgroundColor3 ~= Color3.new(1, 1, 1) then
					d.BackgroundColor3 = mm.color or Col.Cyan
				end
			end
		end)
		ui.tabs:select(state.tab)
		local isReactions = state.tab == "reactions"
		ui.listCol.Visible = isReactions and (not compact or not state.compactDetail)
		ui.branchCol.Visible = (not isReactions) and (not compact or not state.compactDetail)
		ui.back.Instance.Visible = compact
		if isReactions then
			for id, b in ui.filterButtons do
				b:setSelected(id == state.filter)
				b:setStyle(if id == state.filter then "primary" else "ghost")
			end
			local all = EC.reactions()
			local rs = {}
			for _, r in all do
				if state.filter == "all" or (state.filter == "ready" and r.available) or (state.filter == "new" and r.codexState == "UNDISCOVERED" and r.status ~= "LOCKED") then
					table.insert(rs, r)
				end
			end
			-- ready first, then needs matter, then the rest (Developer B's order inside each group)
			local rank = { AVAILABLE = 1, NEEDS_MATERIALS = 2, LOCKED = 3, DONE = 4, MASTERED = 4 }
			table.sort(rs, function(a, b)
				local ra, rb = rank[a.status] or 3, rank[b.status] or 3
				if ra ~= rb then
					return ra < rb
				end
				return (a.order or 0) < (b.order or 0)
			end)
			ui.empty.Visible = #rs == 0
			ui.empty.Text = if state.filter == "ready" then "No reaction is ready yet. Harvest more matter or change your planet's DNA." else "Nothing here yet."
			ui.rowPool:sync(#rs, function(item, i)
				local r = rs[i]
				item.id = r.id
				item.name.Text = if r.codexState == "UNDISCOVERED" and r.status == "LOCKED" then "Unknown reaction" else r.name
				local costBits = {}
				for _, c in r.costs or {} do
					table.insert(costBits, string.format("<font color=\"#%s\">%d %s</font>", (if c.ok then Col.TextDim else Col.Danger):ToHex(), c.need, c.name))
				end
				item.sub.Text = (if surging(r.id) then string.format("<font color=\"#%s\">SOLAR SURGE</font>  ·  ", SURGE_HEX) else "") .. (if #costBits > 0 then table.concat(costBits, "  ·  ") else string.upper(r.category or ""))
				local sc = statusColor(r.status)
				C.setChip(item.chip, STATUS_TEXT[r.status] or r.status, sc)
				item.stripe.BackgroundColor3 = sc
				local sel = r.id == state.selected
				item.stroke.Transparency = if sel then 0.1 else 0.85
				item.Instance.BackgroundTransparency = if sel then 0.3 else 0.55
			end)
			if not state.selected or not currentReaction(all) then
				state.selected = rs[1] and rs[1].id or nil
			end
			local r = currentReaction(all)
			ui.detail.Visible = r ~= nil and (not compact or state.compactDetail)
			if r then
				showReaction(r)
			else
				paintDna(nil)
			end
		else
			local bs = EC.branches()
			ui.branchPool:sync(#bs, function(item, i)
				local b = bs[i]
				item.id = b.id
				item.name.Text = b.name
				item.focus.Text = b.focus or ""
				item.swatch.BackgroundColor3 = b.color or Col.Cyan
				item.swatch.BackgroundTransparency = if b.status == "FUTURE" then 0.7 else 0
				C.setChip(item.chip, STATUS_TEXT[b.status] or b.status or "", statusColor(b.status))
				local sel = b.id == state.branch
				item.stroke.Transparency = if sel then 0.1 else 0.85
			end)
			if not state.branch or not currentBranch(bs) then
				state.branch = bs[1] and bs[1].id or nil
			end
			local b = currentBranch(bs)
			ui.detail.Visible = b ~= nil and (not compact or state.compactDetail)
			if b then
				showBranch(b)
			end
		end
	end

	function DnaPanel._act()
		if state.busy then
			return
		end
		if state.actionKind == "travel" then
			ui.action:setBusy(true)
			task.spawn(function()
				local ok, code = UIData.travelHome()
				ui.action:setBusy(false)
				if ok then
					UIRoot.close()
				else
					UIRoot.toast("Travel failed: " .. code, "error")
				end
			end)
		elseif state.actionKind == "react" and state.selected then
			local id = state.selected
			state.busy = true
			ui.action:setBusy(true)
			task.spawn(function()
				local ok, code, data = EC.react(id)
				state.busy = false
				ui.action:setBusy(false)
				if ok then
					local name = (data and data.name) or id
					local bits = {}
					if data and data.reward then
						if data.reward.credits then table.insert(bits, "+" .. UIData.fmt(data.reward.credits) .. " credits") end
						if data.reward.xp then table.insert(bits, "+" .. data.reward.xp .. " XP") end
					end
					UIRoot.toast(string.format("%s%s", string.upper(name), if #bits > 0 then "  ·  " .. table.concat(bits, "  ") else ""), if data and data.firstDiscovery then "reward" else "success")
					UIRoot.sfx("Power_Up", 0.35, 1.25)
				else
					UIRoot.toast(EC.describeError(code, data), "error")
				end
				DnaPanel._refresh()
			end)
		elseif state.actionKind == "commit" and state.branch then
			local bs = EC.branches()
			local b = currentBranch(bs)
			if not b then
				return
			end
			UIRoot.confirm({
				title = "Specialize: " .. b.name,
				body = (b.consequences or "") .. "\n\nThis shapes your planet's identity.",
				confirmText = if b.isRespec then "Re-specialize" else "Specialize",
				danger = true,
				onConfirm = function()
					state.busy = true
					ui.action:setBusy(true)
					task.spawn(function()
						local ok, code, data = EC.commit(b.id)
						state.busy = false
						ui.action:setBusy(false)
						if ok then
							UIRoot.toast(string.upper(b.name) .. " — specialization committed", "reward")
						else
							UIRoot.toast(EC.describeError(code, data), "error")
						end
						DnaPanel._refresh()
					end)
				end,
			})
		end
	end

	local impl: any = {}
	function impl.refresh()
		DnaPanel._refresh()
	end
	function impl.layout(size: Vector2, mode: string)
		local compact = mode ~= "wide"
		left.Visible = not compact
		strip.Visible = compact
		right.Position = UDim2.fromOffset(if compact then 0 else 266, 0)
		right.Size = UDim2.new(1, if compact then 0 else -266, 1, 0)
		local top = if compact then 46 else 0
		tabs.Instance.Position = UDim2.fromOffset(0, top)
		content.Position = UDim2.fromOffset(0, top + 46)
		content.Size = UDim2.new(1, 0, 1, -(top + 46))
		if compact then
			listCol.Size = UDim2.fromScale(1, 1)
			branchCol.Size = UDim2.fromScale(1, 1)
			detail.Position = UDim2.new()
			detail.Size = UDim2.fromScale(1, 1)
			dScroll.Position = UDim2.fromOffset(0, 40)
			dScroll.Size = UDim2.new(1, 0, 1, -104)
		else
			local listW = math.clamp(math.floor((size.X - 266 - 48) * 0.48), 260, 320)
			listCol.Size = UDim2.new(0, listW, 1, 0)
			branchCol.Size = UDim2.new(0, listW, 1, 0)
			detail.Position = UDim2.fromOffset(listW + 12, 0)
			detail.Size = UDim2.new(1, -(listW + 12), 1, 0)
			dScroll.Position = UDim2.new()
			dScroll.Size = UDim2.new(1, 0, 1, -64)
		end
		DnaPanel._refresh()
	end
	function impl.firstSelection(): GuiObject?
		local first = ui.rowPool.items[1]
		return if first and first.Instance.Visible then first.Instance else ui.tabs.buttons.reactions.Instance
	end
	function impl.onOpen()
		state.compactDetail = false
	end
	-- external entry (onboarding): open with a reaction pre-selected
	function DnaPanel.focusReaction(id: string?)
		state.tab = "reactions"
		state.filter = "all"
		state.selected = id
		state.compactDetail = id ~= nil
	end
	return impl
end

return DnaPanel
