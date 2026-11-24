--!strict
-- StorePanel — owner: Monetization (presentation on Developer A's UI kit). The Cosmic Store.
-- Honest by design: every item lists exactly what it contains; prices are the ones Roblox returns for the
-- configured IDs (never hard-coded); unconfigured items say "Not on sale yet"; no rarity labels, timers,
-- countdowns or "limited" wording; nothing in here is needed to progress. Purchases open Roblox's own
-- confirmation window; cancelling never charges. Opened only by the player (dock / B / the shop on THE FORGE).
-- Tabs: Passes · Celebration · Appearance (equip owned cosmetics, preview others) · Presets.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local MonetizationConfig = require(ReplicatedStorage.PF_Shared.Config.MonetizationConfig)
local ItemCatalog = require(ReplicatedStorage.PF_Shared.Config.ItemCatalog)
local Client = script.Parent.Parent.Parent
local StoreClient = require(Client:WaitForChild("Store"):WaitForChild("StoreClient"))
local CosmeticsFX = require(Client.Store:WaitForChild("CosmeticsFX"))

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local StorePanel = {}

local CATEGORY_LABEL = { Atmosphere = "Atmosphere", PlanetRing = "Planet ring", HarvesterFX = "Harvester effects" }
local NONE_LABEL = { Atmosphere = "None", PlanetRing = "None", HarvesterFX = "Default" }

function StorePanel.available(): boolean
	local r = ReplicatedStorage:FindFirstChild("PF_Remotes")
	return r ~= nil and r:FindFirstChild("Store_Action") ~= nil
end

local function cosmeticsOf(category: string): { string }
	local out = {}
	for id, e in ItemCatalog.COSMETICS do
		if e.category == category then
			table.insert(out, id)
		end
	end
	table.sort(out, function(a, b)
		local ea, eb = ItemCatalog.COSMETICS[a], ItemCatalog.COSMETICS[b]
		if (ea.premium == true) ~= (eb.premium == true) then
			return not ea.premium
		end
		return ea.displayName < eb.displayName
	end)
	return out
end

local function priceText(entry: any): string
	if not entry then
		return "Checking price…"
	end
	if entry.owned then
		return "Owned"
	end
	if entry.available and type(entry.price) == "number" then
		return string.format("R$ %d", entry.price)
	end
	return StoreClient.reasonText(entry.reason)
end

local function preview(category: string, id: string)
	local slot = player:GetAttribute("PF_Slot")
	if category == "HarvesterFX" then
		local ok, FX = pcall(function()
			return require(Client:WaitForChild("Harvest"):WaitForChild("HarvestFX")) :: any
		end)
		local char = player.Character
		local rootPart = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if ok and rootPart then
			local before = FX.getStyle()
			FX.setStyle(id)
			local cf = rootPart.CFrame
			local pos = cf.Position + cf.LookVector * 7 + cf.UpVector * 3
			FX.muzzleFlash(pos, cf.LookVector, Color3.new(1, 1, 1))
			FX.implosion(pos + cf.LookVector * 4, cf.UpVector, Color3.fromRGB(150, 220, 255))
			FX.setStyle(before)
			UIRoot.toast("Preview: " .. ItemCatalog.COSMETICS[id].displayName .. " (only you can see previews)", "info", "eye")
		end
		return
	end
	if type(slot) ~= "number" then
		UIRoot.toast("Claim your planet to preview planet cosmetics.", "info", "eye")
		return
	end
	CosmeticsFX.preview(slot, { [category] = id }, 12)
	UIRoot.close()
	local okS, Showcase = pcall(function()
		return require(Client:WaitForChild("Social"):WaitForChild("Showcase")) :: any
	end)
	if okS and Showcase.open then
		Showcase.open(slot)
	end
	UIRoot.toast("Preview: " .. ItemCatalog.COSMETICS[id].displayName .. " on your planet for 12 s (only you can see it).", "info", "eye")
end

function StorePanel.build(shell: any)
	local body: Frame = shell.Body
	local impl: any = {}
	local state = { tab = "passes", busy = false }

	local top = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = body })
	local pages: { [string]: ScrollingFrame } = {}
	local tabs = C.tabs({ items = { { id = "passes", label = "Passes", icon = "star" }, { id = "celebration", label = "Celebration", icon = "rocket" }, { id = "appearance", label = "Appearance", icon = "planet" }, { id = "presets", label = "Presets", icon = "scale" } }, parent = top, order = 1, onSelect = function(id)
		state.tab = id
		for k, pg in pages do
			pg.Visible = k == id
		end
		impl.refresh()
	end })
	local holder = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -48), Position = UDim2.fromOffset(0, 48), Parent = body })
	for _, id in { "passes", "celebration", "appearance", "presets" } do
		local pg = C.scroll({ parent = holder, gap = Sp.s, dims = UDim2.fromScale(1, 1) })
		pg.Visible = id == "passes"
		pages[id] = pg
	end
	local INTRO = "Cosmetics and celebrations only. Every planet branch, discovery, harvest and expedition is free for everyone. Prices come from Roblox, and buying opens Roblox's own confirmation window — cancelling never charges you."
	local intro = C.text({ text = INTRO, size = S.Small, color = Col.TextDim, autoY = true, parent = pages.passes, order = 0 })
	intro.RichText = true

	-- PASSES ------------------------------------------------------------------------------------------
	local passCards: { [string]: any } = {}
	for i, pass in MonetizationConfig.sortedPasses() do
		local card = C.glass({ name = "Pass_" .. pass.key, variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = pages.passes, order = i })
		card.AutomaticSize = Enum.AutomaticSize.Y
		local inner = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
		local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1, Parent = inner })
		local sw = C.make("Frame", { BackgroundColor3 = pass.color, Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(0, 2), Parent = head }, { C.corner(15) })
		C.icon(pass.icon, 18, Color3.new(0.05, 0.06, 0.1), sw).Position = UDim2.fromOffset(6, 6)
		local title = C.text({ text = pass.name, size = 16, font = F.Display, parent = head, dims = UDim2.new(1, -170, 0, 20) })
		title.Position = UDim2.fromOffset(42, 0)
		local tag = C.text({ text = pass.tagline, size = S.Micro, font = F.Semi, color = Col.TextDim, parent = head, dims = UDim2.new(1, -170, 0, 14) })
		tag.Position = UDim2.fromOffset(42, 20)
		local price = C.text({ text = "Checking price…", size = S.Small, font = F.Bold, color = Col.Gold, align = Enum.TextXAlignment.Right, parent = head, dims = UDim2.new(0, 160, 0, 20) })
		price.AnchorPoint = Vector2.new(1, 0)
		price.Position = UDim2.new(1, 0, 0, 6)
		C.text({ text = pass.description, size = S.Small, color = Col.TextDim, autoY = true, parent = inner, order = 2 })
		if pass.grants.cosmetics then
			C.caption("Includes — tap to preview", inner, 3)
			local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = inner })
			local l = C.list(Enum.FillDirection.Horizontal, 6)
			l.Wraps = true
			l.Parent = row
			for k, id in pass.grants.cosmetics do
				local e = ItemCatalog.COSMETICS[id]
				C.button({ text = e.displayName, icon = "eye", style = "ghost", size = S.Micro, dims = UDim2.fromOffset(170, 28), parent = row, order = k, onClick = function()
					preview(e.category, id)
				end })
			end
		else
			C.caption("Includes", inner, 3)
			C.text({ text = string.format("+%d preset slots (%d in total)", pass.grants.presetSlots, MonetizationConfig.FREE.presetSlots + pass.grants.presetSlots), size = S.Small, parent = inner, order = 4, autoY = true })
		end
		local actions = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 5, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
		local buy = C.button({ text = "Buy", icon = "plus", style = "primary", dims = UDim2.fromOffset(150, 32), parent = actions, order = 1, onClick = function()
			impl.buyPass(pass.key)
		end })
		passCards[pass.key] = { price = price, buy = buy }
	end
	C.text({ text = "Game Passes are one-time purchases tied to your Roblox account. Contents are fixed and listed above — nothing is random.", size = S.Micro, color = Col.TextMute, autoY = true, parent = pages.passes, order = 99 })

	-- CELEBRATION -------------------------------------------------------------------------------------
	local prodCards: { [string]: any } = {}
	for i, prod in MonetizationConfig.sortedProducts() do
		local card = C.glass({ name = "Product_" .. prod.key, variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = pages.celebration, order = i })
		card.AutomaticSize = Enum.AutomaticSize.Y
		local inner = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
		local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1, Parent = inner })
		local sw = C.make("Frame", { BackgroundColor3 = prod.color, Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(0, 2), Parent = head }, { C.corner(15) })
		C.icon(prod.icon, 18, Color3.new(0.05, 0.06, 0.1), sw).Position = UDim2.fromOffset(6, 6)
		local title = C.text({ text = prod.name, size = 16, font = F.Display, parent = head, dims = UDim2.new(1, -170, 0, 20) })
		title.Position = UDim2.fromOffset(42, 0)
		local tag = C.text({ text = prod.tagline, size = S.Micro, font = F.Semi, color = Col.TextDim, parent = head, dims = UDim2.new(1, -170, 0, 14) })
		tag.Position = UDim2.fromOffset(42, 20)
		local price = C.text({ text = "Checking price…", size = S.Small, font = F.Bold, color = Col.Gold, align = Enum.TextXAlignment.Right, parent = head, dims = UDim2.new(0, 160, 0, 20) })
		price.AnchorPoint = Vector2.new(1, 0)
		price.Position = UDim2.new(1, 0, 0, 6)
		C.text({ text = prod.description, size = S.Small, color = Col.TextDim, autoY = true, parent = inner, order = 2 })
		local have = C.text({ text = "", size = S.Small, font = F.Semi, parent = inner, order = 3, autoY = true })
		local actions = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 4, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
		local buy = C.button({ text = "Buy", icon = "plus", style = "primary", dims = UDim2.fromOffset(150, 32), parent = actions, order = 1, onClick = function()
			impl.buyProduct(prod.key)
		end })
		local launch = C.button({ text = "Launch", icon = "rocket", style = "solid", dims = UDim2.fromOffset(150, 32), parent = actions, order = 2, onClick = function()
			impl.launch()
		end })
		prodCards[prod.key] = { price = price, buy = buy, launch = launch, have = have }
	end

	-- APPEARANCE --------------------------------------------------------------------------------------
	local rows: { [string]: { [string]: any } } = {}
	local order = 0
	for _, cat in MonetizationConfig.COSMETIC_CATEGORIES do
		order += 1
		C.caption(CATEGORY_LABEL[cat], pages.appearance, order, Col.Cyan)
		order += 1
		local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = pages.appearance })
		local l = C.list(Enum.FillDirection.Horizontal, 6)
		l.Wraps = true
		l.Parent = row
		rows[cat] = {}
		rows[cat]["None"] = C.button({ text = NONE_LABEL[cat], style = "ghost", size = S.Micro, dims = UDim2.fromOffset(150, 30), parent = row, order = 0, onClick = function()
			impl.equip(cat, nil)
		end })
		for k, id in cosmeticsOf(cat) do
			local e = ItemCatalog.COSMETICS[id]
			rows[cat][id] = C.button({ text = e.displayName, style = "ghost", size = S.Micro, dims = UDim2.fromOffset(170, 30), parent = row, order = k, onClick = function()
				if StoreClient.owns(id) then
					impl.equip(cat, id)
				else
					preview(cat, id)
				end
			end })
		end
	end
	order += 1
	C.text({ text = "Owned items equip in one tap. Items you don't own show a preview instead (only you can see previews). Earned atmospheres and rings come from planet evolution and are free.", size = S.Micro, color = Col.TextMute, autoY = true, parent = pages.appearance, order = order })

	-- PRESETS -----------------------------------------------------------------------------------------
	local presetRows = {}
	for i = 1, MonetizationConfig.FREE.presetSlots + (MonetizationConfig.PASSES.DesignPresets.grants.presetSlots :: number) do
		local card = C.glass({ name = "Preset_" .. i, variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = pages.presets, order = i })
		card.AutomaticSize = Enum.AutomaticSize.Y
		local inner = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.s, Sp.l, Sp.s, Sp.l), C.list(Enum.FillDirection.Vertical, 4) })
		local label = C.text({ text = "Preset " .. i, size = S.Small, font = F.Bold, parent = inner, order = 1, autoY = true })
		local summary = C.text({ text = "", size = S.Micro, color = Col.TextDim, parent = inner, order = 2, autoY = true })
		local actions = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 3, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
		local save = C.button({ text = "Save current look", style = "ghost", size = S.Micro, dims = UDim2.fromOffset(170, 28), parent = actions, order = 1, onClick = function()
			impl.savePreset(i)
		end })
		local apply = C.button({ text = "Apply", style = "solid", size = S.Micro, dims = UDim2.fromOffset(110, 28), parent = actions, order = 2, onClick = function()
			impl.applyPreset(i)
		end })
		presetRows[i] = { label = label, summary = summary, save = save, apply = apply }
	end

	-- actions -----------------------------------------------------------------------------------------
	local function run(fn: () -> (boolean, string), okText: string?)
		if state.busy then
			return
		end
		state.busy = true
		task.spawn(function()
			local ok, code = fn()
			state.busy = false
			if ok and okText then
				UIRoot.toast(okText, "success", "check")
			elseif not ok then
				UIRoot.toast(StoreClient.reasonText(code), "info", "info")
			end
			impl.refresh()
		end)
	end
	function impl.buyPass(key: string)
		run(function()
			return StoreClient.buyPass(key)
		end, nil)
	end
	function impl.buyProduct(key: string)
		run(function()
			return StoreClient.buyProduct(key)
		end, nil)
	end
	function impl.launch()
		run(function()
			return StoreClient.launch()
		end, "Cosmic Fireworks launched around your planet!")
	end
	function impl.equip(cat: string, id: string?)
		run(function()
			return StoreClient.equip(cat, id)
		end, nil)
	end
	function impl.savePreset(i: number)
		run(function()
			return StoreClient.savePreset(i)
		end, "Preset " .. i .. " saved.")
	end
	function impl.applyPreset(i: number)
		run(function()
			local ok, code, data = StoreClient.applyPreset(i)
			if ok and data and data.missing and #data.missing > 0 then
				UIRoot.toast("Applied. Some saved items are not owned and were skipped.", "info", "info")
			end
			return ok, code
		end, "Preset " .. i .. " applied.")
	end

	local function nameOf(id: string?): string
		local e = id and ItemCatalog.COSMETICS[id]
		return if e then e.displayName else "—"
	end

	function impl.refresh()
		local cat = StoreClient.catalog()
		local mine = StoreClient.mine()
		local byPass, byProd = {}, {}
		for _, e in (cat and cat.passes) or {} do
			byPass[e.key] = e
		end
		for _, e in (cat and cat.products) or {} do
			byProd[e.key] = e
		end
		-- QA I6 (2026-11-22): say plainly when nothing can be bought yet (no product ids configured), instead of a
		-- page of disabled Buy buttons; previews and the free design preset keep working
		if cat then
			local anyForSale = false
			for _, e in byPass do
				anyForSale = anyForSale or e.available == true
			end
			for _, e in byProd do
				anyForSale = anyForSale or e.available == true
			end
			intro.Text = if anyForSale
				then INTRO
				else "<b>Nothing is on sale yet.</b> Passes and products open later. Appearance previews and your free design preset already work. " .. INTRO
		end
		for key, card in passCards do
			local entry = byPass[key]
			local owned = StoreClient.ownsPass(key) or (entry ~= nil and entry.owned)
			card.price.Text = if owned then "Owned" else priceText(entry)
			card.price.TextColor3 = if owned then Col.Cyan else Col.Gold
			card.buy:setText(if owned then "Owned" elseif entry and entry.available and entry.price then string.format("Buy  R$ %d", entry.price) else "Buy")
			card.buy:setEnabled(not owned and entry ~= nil and entry.available == true and not state.busy, if owned then "You own this pass" elseif entry then StoreClient.reasonText(entry.reason) else "Checking availability")
		end
		for key, card in prodCards do
			local entry = byProd[key]
			card.price.Text = priceText(entry)
			card.have.Text = string.format("Ready to launch: %d", mine.fireworks or 0)
			card.buy:setText(if entry and entry.available and entry.price then string.format("Buy  R$ %d", entry.price) else "Buy")
			card.buy:setEnabled(entry ~= nil and entry.available == true and not state.busy, if entry then StoreClient.reasonText(entry.reason) else "Checking availability")
			card.launch:setEnabled((mine.fireworks or 0) > 0 and not state.busy, "You have no Cosmic Fireworks to launch")
		end
		for catName, buttons in rows do
			local eq = StoreClient.equipped(catName)
			for id, b in buttons do
				local isNone = id == "None"
				local owned = isNone or StoreClient.owns(id)
				local equipped = (isNone and eq == nil) or eq == id
				b:setStyle(if equipped then "solid" else "ghost")
				local e = ItemCatalog.COSMETICS[id]
				if not isNone then
					local pass = MonetizationConfig.passForCosmetic(id)
					b:setText((if owned then "" else "Preview · ") .. e.displayName)
					local _ = pass
				end
				b:setEnabled(not state.busy, "")
			end
		end
		local slots = mine.presetSlots or 1
		for i, r in presetRows do
			local unlocked = i <= slots
			local pr = (mine.presets or {})[i] or (mine.presets or {})[tostring(i)]
			r.label.Text = "Preset " .. i .. (if unlocked then "" else "  ·  Extra Planet Design Presets pass")
			r.summary.Text = if not unlocked then "Locked — preset slots never affect progression." elseif pr then string.format("Atmosphere: %s · Ring: %s · Harvester: %s", nameOf(pr.Atmosphere), nameOf(pr.PlanetRing), nameOf(pr.HarvesterFX)) else "Empty — save your current look here."
			r.save:setEnabled(unlocked and not state.busy, "Needs the Extra Planet Design Presets pass")
			r.apply:setEnabled(unlocked and pr ~= nil and not state.busy, if unlocked then "Save a look into this slot first" else "Needs the Extra Planet Design Presets pass")
		end
	end

	function impl.onOpen()
		impl.refresh()
		task.spawn(function()
			StoreClient.request("refresh")
			StoreClient.refreshCatalog()
			impl.refresh()
		end)
	end
	function impl.onClose() end
	function impl.firstSelection(): GuiObject?
		local first = passCards[MonetizationConfig.sortedPasses()[1].key]
		return first and first.buy.Instance
	end
	StoreClient.Changed:Connect(function()
		if UIRoot.current() == "store" then
			impl.refresh()
		end
	end)
	tabs:select("passes")
	return impl
end

return StorePanel
