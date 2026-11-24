--!strict
-- InventoryPanel — owner: Developer A. Materials by category, catalysts, quantities, sorting, readable item
-- details (description, cap, which reactions use it) and selling through Developer B's Economy_SellMaterial.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local ItemCatalog = require(ReplicatedStorage.PF_Shared.Config.ItemCatalog)
local EconomyFormulas = require(ReplicatedStorage.PF_Shared.Economy.EconomyFormulas)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Inventory = {}

local SORTS = { "amount", "name", "category" }
local SORT_LABEL = { amount = "Amount", name = "Name", category = "Category" }

local function tintIcon(icon: Instance, color: Color3)
	for _, d in icon:GetDescendants() do
		if d:IsA("Frame") and d.BackgroundColor3 ~= Color3.new(1, 1, 1) then
			d.BackgroundColor3 = color
		end
	end
end

function Inventory.build(shell: any)
	local body: Frame = shell.Body
	local state = { cat = "all", sort = "amount", selected = nil :: string?, sellAmount = 1, busy = false, compactDetail = false }
	local ui: any = {}

	-- categories from the catalog (materials) + catalysts
	local cats = { { id = "all", label = "All" } }
	local seen = {}
	local ordered = {}
	for id, d in ItemCatalog.MATERIALS do
		table.insert(ordered, { id = id, d = d })
	end
	table.sort(ordered, function(a, b) return (a.d.order or 0) < (b.d.order or 0) end)
	for _, it in ordered do
		local c = it.d.category or "Other"
		if not seen[c] then
			seen[c] = true
			table.insert(cats, { id = c, label = c })
		end
	end
	table.insert(cats, { id = "Catalyst", label = "Catalysts" })

	local top = C.make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), Parent = body })
	ui.tabs = C.tabs({ items = cats, parent = top, dims = UDim2.new(1, -140, 1, 0), onSelect = function(id)
		state.cat = id
		Inventory._refresh()
	end })
	ui.sort = C.button({ text = "Sort: Amount", icon = "sort", style = "ghost", dims = UDim2.fromOffset(132, 32), parent = top, size = S.Micro, onClick = function()
		local i = table.find(SORTS, state.sort) or 1
		state.sort = SORTS[i % #SORTS + 1]
		Inventory._refresh()
	end, tooltip = "Change sorting" })
	ui.sort.Instance.AnchorPoint = Vector2.new(1, 0.5)
	ui.sort.Instance.Position = UDim2.new(1, 0, 0.5, 0)

	local gridHolder = C.make("Frame", { Name = "GridHolder", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, -312, 1, -48), Parent = body })
	local grid = C.make("ScrollingFrame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, ScrollBarImageColor3 = Col.Cyan, Selectable = false, Parent = gridHolder }, {
		C.make("UIGridLayout", { CellSize = UDim2.fromOffset(136, 112), CellPadding = UDim2.fromOffset(Sp.s, Sp.s), SortOrder = Enum.SortOrder.LayoutOrder }),
		C.pad(2, 6, 2, 2),
	})
	ui.empty = C.text({ text = "No items in this category yet.", size = S.Small, color = Col.TextMute, parent = gridHolder, dims = UDim2.new(1, 0, 0, 30) })
	ui.cardPool = C.pool(function()
		local b = C.make("TextButton", { Name = "Item", Text = "", AutoButtonColor = false, BackgroundColor3 = Col.PanelHi, BackgroundTransparency = 0.5, SelectionImageObject = C.selectionImage, Parent = grid }, { C.corner(Theme.Radius.m) })
		local st = C.stroke(Col.Cyan, 0.85)
		st.Parent = b
		local ic = C.icon("matter", 26, Col.Cyan, b)
		ic.Position = UDim2.fromOffset(12, 12)
		local amt = C.text({ text = "0", size = 20, font = F.Bold, align = Enum.TextXAlignment.Right, parent = b, dims = UDim2.new(1, -56, 0, 26) })
		amt.Position = UDim2.fromOffset(44, 12)
		local name = C.text({ text = "", size = S.Small, font = F.Semi, wrap = true, parent = b, dims = UDim2.new(1, -24, 0, 36) })
		name.Position = UDim2.fromOffset(12, 46)
		name.TextYAlignment = Enum.TextYAlignment.Top
		local cat = C.text({ text = "", size = S.Micro, font = F.Display, color = Col.TextMute, parent = b, dims = UDim2.new(1, -24, 0, 14) })
		cat.Position = UDim2.new(0, 12, 1, -22)
		local item: any = { Instance = b, stroke = st, icon = ic, amount = amt, name = name, cat = cat, id = "" }
		b.MouseEnter:Connect(function() if state.selected ~= item.id then st.Transparency = 0.5 end end)
		b.MouseLeave:Connect(function() if state.selected ~= item.id then st.Transparency = 0.85 end end)
		b.Activated:Connect(function()
			state.selected = item.id
			state.sellAmount = 1
			state.compactDetail = true
			Inventory._refresh()
		end)
		return item
	end)

	-- details
	local detail = C.glass({ name = "Detail", variant = "card", parent = body })
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.new(1, 0, 0, 48)
	detail.Size = UDim2.new(0, 300, 1, -48)
	ui.detail = detail
	local back = C.button({ text = "Back", icon = "back", style = "ghost", dims = UDim2.new(0, 0, 0, 28), parent = detail, size = S.Micro, onClick = function()
		state.compactDetail = false
		Inventory._refresh()
	end })
	back.Instance.AutomaticSize = Enum.AutomaticSize.X
	back.Instance.Position = UDim2.fromOffset(12, 10)
	ui.back = back
	local ds = C.scroll({ name = "DetailScroll", parent = detail, gap = Sp.s, padding = Sp.l })
	ds.Size = UDim2.new(1, 0, 1, -120)
	ui.ds = ds
	local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = 1, Parent = ds })
	ui.bigIcon = C.icon("matter", 40, Col.Cyan, head)
	ui.dName = C.text({ text = "", size = S.Heading, font = F.Display, wrap = true, parent = head, dims = UDim2.new(1, -56, 0, 40) })
	ui.dName.Position = UDim2.fromOffset(54, 4)
	ui.dChip = C.chip("", Col.Cyan, ds, 2)
	ui.dDesc = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = ds, order = 3 })
	C.divider(ds, 4)
	ui.dQty = C.text({ text = "", size = S.Body, font = F.Bold, autoY = true, parent = ds, order = 5 })
	ui.dQty.RichText = true
	ui.dPrice = C.text({ text = "", size = S.Small, color = Col.Gold, autoY = true, parent = ds, order = 6 })
	ui.dUses = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = ds, order = 7 })
	ui.dUses.RichText = true

	local sell = C.make("Frame", { Name = "Sell", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 112), Parent = detail }, { C.pad(Sp.s, Sp.l, Sp.m, Sp.l) })
	ui.sell = sell
	local stepper = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), Parent = sell }, { C.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })
	local function step(delta: number?, absolute: number?)
		return function()
			local snap = UIData.snapshot()
			local have = snap and snap.materials and state.selected and snap.materials[state.selected] or 0
			if absolute then
				state.sellAmount = absolute
			else
				state.sellAmount += delta or 0
			end
			state.sellAmount = math.clamp(state.sellAmount, 1, math.max(1, have))
			Inventory._refresh()
		end
	end
	C.button({ icon = "minus", iconOnly = true, style = "ghost", dims = UDim2.fromOffset(32, 32), parent = stepper, order = 1, onClick = step(-1), tooltip = "Sell one less" })
	ui.sellQty = C.text({ text = "1", size = S.Body, font = F.Bold, align = Enum.TextXAlignment.Center, parent = stepper, order = 2, dims = UDim2.fromOffset(56, 32) })
	C.button({ icon = "plus", iconOnly = true, style = "ghost", dims = UDim2.fromOffset(32, 32), parent = stepper, order = 3, onClick = step(1), tooltip = "Sell one more" })
	C.button({ text = "+10", style = "ghost", dims = UDim2.fromOffset(44, 32), parent = stepper, order = 4, size = S.Micro, onClick = step(10) })
	C.button({ text = "All", style = "ghost", dims = UDim2.fromOffset(44, 32), parent = stepper, order = 5, size = S.Micro, onClick = function()
		local snap = UIData.snapshot()
		step(nil, snap and snap.materials and state.selected and snap.materials[state.selected] or 1)()
	end })
	ui.sellBtn = C.button({ text = "Sell", icon = "credits", style = "solid", dims = UDim2.new(1, 0, 0, 40), parent = sell, onClick = function()
		Inventory._sell()
	end })
	ui.sellBtn.Instance.Position = UDim2.fromOffset(0, 46)

	local function entries(): { any }
		local snap = UIData.snapshot()
		local out = {}
		if not snap then
			return out
		end
		if state.cat ~= "Catalyst" then
			for id, d in ItemCatalog.MATERIALS do
				if state.cat == "all" or d.category == state.cat then
					table.insert(out, { id = id, kind = "material", name = d.displayName or id, amount = snap.materials and snap.materials[id] or 0, category = d.category or "", color = d.iconColor or Col.Cyan, order = d.order or 0, def = d })
				end
			end
		end
		if state.cat == "all" or state.cat == "Catalyst" then
			for id, d in ItemCatalog.CATALYSTS or {} do
				table.insert(out, { id = id, kind = "catalyst", name = d.displayName or id, amount = snap.catalysts and snap.catalysts[id] or 0, category = "Catalyst", color = Col.Magenta, order = 100 + (d.order or 0), def = d })
			end
		end
		table.sort(out, function(a, b)
			if state.sort == "name" then
				return a.name < b.name
			elseif state.sort == "category" then
				if a.category ~= b.category then
					return a.category < b.category
				end
				return a.order < b.order
			end
			if a.amount ~= b.amount then
				return a.amount > b.amount
			end
			return a.order < b.order
		end)
		return out
	end

	function Inventory._refresh()
		local compact = UIRoot.mode() ~= "wide"
		local list = entries()
		ui.tabs:select(state.cat)
		ui.sort:setText("Sort: " .. SORT_LABEL[state.sort])
		ui.empty.Visible = #list == 0
		ui.cardPool:sync(#list, function(item, i)
			local e = list[i]
			item.id = e.id
			item.name.Text = e.name
			item.amount.Text = UIData.fmt(e.amount)
			item.amount.TextColor3 = if e.amount > 0 then Col.Text else Col.TextMute
			item.cat.Text = string.upper(e.category)
			tintIcon(item.icon, e.color)
			local sel = e.id == state.selected
			item.stroke.Transparency = if sel then 0.1 else 0.85
			item.Instance.BackgroundTransparency = if sel then 0.3 else 0.5
		end)
		local sel = nil
		for _, e in list do
			if e.id == state.selected then
				sel = e
			end
		end
		if not sel then
			sel = list[1]
			state.selected = sel and sel.id
		end
		gridHolder.Visible = not compact or not state.compactDetail
		detail.Visible = sel ~= nil and (not compact or state.compactDetail)
		ui.back.Instance.Visible = compact
		ds.Position = UDim2.fromOffset(0, if compact then 40 else 0)
		if not sel then
			return
		end
		tintIcon(ui.bigIcon, sel.color)
		ui.dName.Text = sel.name
		C.setChip(ui.dChip, sel.category, sel.color)
		local cap = sel.def.maxAmount or sel.def.maxStack
		ui.dQty.Text = string.format("Owned  <font color=\"#%s\">%s</font>%s", Col.Cyan:ToHex(), UIData.fmt(sel.amount), if cap then string.format("  <font color=\"#%s\">/ %s</font>", Col.TextMute:ToHex(), UIData.fmt(cap)) else "")
		local uses = {}
		for _, r in UIData.Evolution.reactions() do
			for _, c in r.costs or {} do
				if c.id == sel.id then
					table.insert(uses, r.name)
					break
				end
			end
		end
		if sel.kind == "catalyst" then
			ui.dDesc.Text = sel.def.description or string.format("A rare %s catalyst. Catalysts come from rare drops and enable special reactions.", tostring(sel.def.element or "cosmic"):lower())
		else
			ui.dDesc.Text = sel.def.description or ""
		end
		ui.dUses.Text = if #uses > 0 then string.format("<b>Used in:</b> %s", table.concat(uses, ", ")) else ""
		ui.dUses.Visible = #uses > 0
		local unit = if sel.kind == "material" then EconomyFormulas.sellValue(sel.id, 1) else nil
		ui.sell.Visible = unit ~= nil and unit > 0
		ui.dPrice.Visible = unit ~= nil
		ds.Size = UDim2.new(1, 0, 1, if ui.sell.Visible then -112 - (if compact then 40 else 0) else -(if compact then 40 else 0))
		if unit then
			ui.dPrice.Text = string.format("Sells for %s credits each", UIData.fmt(unit))
			state.sellAmount = math.clamp(state.sellAmount, 1, math.max(1, sel.amount))
			ui.sellQty.Text = tostring(state.sellAmount)
			local total = EconomyFormulas.sellValue(sel.id, state.sellAmount) or 0
			ui.sellBtn:setText(string.format("Sell %d for %s", state.sellAmount, UIData.fmt(total)))
			ui.sellBtn:setEnabled(sel.amount > 0 and not state.busy)
		end
	end

	function Inventory._sell()
		local id = state.selected
		if not id or state.busy then
			return
		end
		local amount = state.sellAmount
		state.busy = true
		ui.sellBtn:setBusy(true)
		task.spawn(function()
			local ok, code, data = UIData.Profile.sellMaterial(id, amount)
			state.busy = false
			ui.sellBtn:setBusy(false)
			if ok then
				local d = ItemCatalog.MATERIALS[id]
				local credits = data and (data.credits or data.gained or data.value)
				UIRoot.toast(string.format("Sold %d %s%s", amount, d and d.displayName or id, if credits then "  ·  +" .. UIData.fmt(credits) .. " credits" else ""), "success")
				state.sellAmount = 1
			else
				UIRoot.toast("Sale failed: " .. tostring(code), "error")
			end
			Inventory._refresh()
		end)
	end

	local impl: any = {}
	function impl.refresh()
		local snap = UIData.snapshot()
		shell.Subtitle.Text = if snap then string.format("%s CREDITS", UIData.fmt(snap.currencies and snap.currencies.Credits or 0)) else ""
		Inventory._refresh()
	end
	function impl.layout(size: Vector2, mode: string)
		local compact = mode ~= "wide"
		gridHolder.Size = UDim2.new(1, if compact then 0 else -312, 1, -48)
		if compact then
			detail.Position = UDim2.fromOffset(0, 0)
			detail.AnchorPoint = Vector2.zero
			detail.Size = UDim2.fromScale(1, 1)
			detail.ZIndex = 5
		else
			detail.AnchorPoint = Vector2.new(1, 0)
			detail.Position = UDim2.new(1, 0, 0, 48)
			detail.Size = UDim2.new(0, 300, 1, -48)
		end
		local cols = math.max(2, math.floor(((if compact then size.X - 48 else size.X - 48 - 312) + Sp.s) / (136 + Sp.s)))
		local cellW = math.floor(((if compact then size.X - 48 else size.X - 48 - 312) - (cols - 1) * Sp.s - 8) / cols)
		local gridLayout = grid:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout
		gridLayout.CellSize = UDim2.fromOffset(math.max(110, cellW), 112)
		Inventory._refresh()
	end
	function impl.onOpen()
		state.compactDetail = false
	end
	function impl.firstSelection(): GuiObject?
		local first = ui.cardPool.items[1]
		return first and first.Instance
	end
	return impl
end

return Inventory
