--!strict
-- HarvesterPanel — owner: Developer A. Gravity Harvester hub: harvest energy + regeneration, the harvester's
-- location (travel there / show the way) and upgrades bought through Developer B's Economy_PurchaseUpgrade.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local EconomyConfig = require(ReplicatedStorage.PF_Shared.Config.EconomyConfig)
local EconomyFormulas = require(ReplicatedStorage.PF_Shared.Economy.EconomyFormulas)
local ItemCatalog = require(ReplicatedStorage.PF_Shared.Config.ItemCatalog)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Harvester = {}
local ORDER = { "HarvestYield", "HarvestEfficiency", "EnergyCapacity" }

local function effectText(id: string, level: number): string
	local def = EconomyConfig.UPGRADES[id]
	local per = def and def.effectPerLevel or 0
	if id == "HarvestYield" then
		return string.format("+%d%% matter per capture", math.round(per * level * 100))
	elseif id == "HarvestEfficiency" then
		return string.format("−%d%% energy per shot", math.round(per * level * 100))
	elseif id == "EnergyCapacity" then
		return string.format("+%d max energy", math.round(per * level))
	end
	return tostring(EconomyFormulas.upgradeEffect(id, level))
end

function Harvester.build(shell: any)
	local body: Frame = shell.Body
	local ui: any = { busy = {} }
	local left = C.glass({ name = "Energy", variant = "card", parent = body, dims = UDim2.new(0, 300, 1, 0) })
	local ls = C.scroll({ parent = left, gap = Sp.s, padding = Sp.l })
	C.caption("Harvest energy", ls, 1)
	ui.energy = C.text({ text = "", size = S.Hero, font = F.Display, parent = ls, order = 2, dims = UDim2.new(1, 0, 0, 36) })
	ui.energyBar = C.bar({ color = Col.Cyan, height = 8, parent = ls, order = 3 })
	ui.regen = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = ls, order = 4 })
	C.divider(ls, 5)
	C.caption("Location", ls, 6)
	ui.where = C.text({ text = "", size = S.Body, font = F.Semi, autoY = true, parent = ls, order = 7 })
	ui.go = C.button({ text = "Travel to my planet", icon = "travel", style = "primary", dims = UDim2.new(1, 0, 0, 38), parent = ls, order = 8, onClick = function()
		Harvester._go()
	end })
	ui.hint = C.text({ text = "At the harvester, press the prompt to operate it, then aim and lock onto passing meteors.", size = S.Small, color = Col.TextMute, autoY = true, parent = ls, order = 9 })
	C.divider(ls, 10)
	C.caption("Session totals", ls, 11)
	ui.stats = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = ls, order = 12 })

	local right = C.make("Frame", { Name = "Upgrades", BackgroundTransparency = 1, Position = UDim2.fromOffset(316, 0), Size = UDim2.new(1, -316, 1, 0), Parent = body })
	C.caption("Upgrades", right).Size = UDim2.new(1, 0, 0, 16)
	local list = C.scroll({ parent = right, gap = Sp.s })
	list.Position = UDim2.fromOffset(0, 24)
	list.Size = UDim2.new(1, 0, 1, -24)
	ui.list, ui.left, ui.right = list, left, right
	ui.cards = {}
	for i, id in ORDER do
		local def = EconomyConfig.UPGRADES[id]
		local card = C.glass({ name = id, variant = "card", dims = UDim2.new(1, 0, 0, 116), parent = list, order = i })
		C.pad(Sp.m, Sp.l, Sp.m, Sp.l).Parent = card
		local title = C.text({ text = string.upper(def.displayName or id), size = S.Heading, font = F.Display, parent = card, dims = UDim2.new(1, -170, 0, 20) })
		local lvl = C.text({ text = "", size = S.Small, font = F.Bold, color = Col.Cyan, align = Enum.TextXAlignment.Right, parent = card, dims = UDim2.new(0, 150, 0, 20) })
		lvl.AnchorPoint = Vector2.new(1, 0)
		lvl.Position = UDim2.fromScale(1, 0)
		local bar = C.bar({ color = Col.Cyan, height = 4, parent = card })
		bar.Instance.Position = UDim2.fromOffset(0, 28)
		local eff = C.text({ text = "", size = S.Small, color = Col.TextDim, parent = card, dims = UDim2.new(1, -170, 0, 18) })
		eff.Position = UDim2.fromOffset(0, 40)
		eff.RichText = true
		local cost = C.text({ text = "", size = S.Small, parent = card, dims = UDim2.new(1, -170, 0, 36), wrap = true })
		cost.Position = UDim2.fromOffset(0, 60)
		cost.RichText = true
		local buy = C.button({ text = "Upgrade", icon = "plus", style = "solid", dims = UDim2.fromOffset(150, 38), parent = card, onClick = function()
			Harvester._buy(id)
		end })
		buy.Instance.AnchorPoint = Vector2.new(1, 1)
		buy.Instance.Position = UDim2.fromScale(1, 1)
		ui.cards[id] = { title = title, lvl = lvl, bar = bar, eff = eff, cost = cost, buy = buy }
	end

	function Harvester._refresh()
		local snap = UIData.snapshot()
		if not snap then
			return
		end
		local energy = snap.currencies and snap.currencies.CosmicEnergy or 0
		local cap = snap.energyCap or 100
		ui.energy.Text = string.format("%s / %s", UIData.fmt(energy), UIData.fmt(cap))
		ui.energyBar:set(energy / math.max(1, cap))
		local effLevel = snap.upgrades and snap.upgrades.HarvestEfficiency and snap.upgrades.HarvestEfficiency.level or 0
		local shot = EconomyFormulas.harvestEnergyCost(effLevel)
		ui.regen.Text = string.format("Regenerates %d per minute. Each shot uses %d energy.", EconomyConfig.ENERGY.REGEN_PER_MINUTE or 0, shot)
		local slot = UIData.slot()
		local onPlanet = UIData.onOwnPlanet()
		ui.where.Text = if not slot then "No planet assigned yet." elseif onPlanet then string.format("You are on PLANET %02d with your harvester.", slot) else string.format("Your harvester stands on PLANET %02d.", slot)
		ui.go:setText(if onPlanet then "Show me the way" else "Travel to my planet")
		ui.go:setEnabled(slot ~= nil)
		local st = snap.stats or {}
		ui.stats.Text = string.format("%s captures · %s matter harvested", UIData.fmt(st.harvests or 0), UIData.fmt(st.materialsHarvested or 0))
		for _, id in ORDER do
			local def = EconomyConfig.UPGRADES[id]
			local u = snap.upgrades and snap.upgrades[id] or { level = 0, maxLevel = def.maxLevel }
			local card = ui.cards[id]
			local level, maxL = u.level or 0, u.maxLevel or def.maxLevel or 1
			card.lvl.Text = string.format("LEVEL %d / %d", level, maxL)
			card.bar:set(level / math.max(1, maxL))
			local maxed = level >= maxL
			card.eff.Text = if maxed then effectText(id, level) .. "  ·  maxed" else string.format("%s  <font color=\"#%s\">→ %s</font>", if level > 0 then effectText(id, level) else "No bonus yet", Col.Success:ToHex(), effectText(id, level + 1))
			local lockedByLevel = (def.minPlayerLevel or 1) > (snap.level or 1)
			local affordable = true
			local bits = {}
			local nc = u.nextCost or (not maxed and EconomyFormulas.upgradeCost(id, level)) or nil
			if nc then
				for cur, n in nc.currencies or {} do
					local have = snap.currencies and snap.currencies[cur] or 0
					local ok = have >= n
					affordable = affordable and ok
					local d = ItemCatalog.CURRENCIES and ItemCatalog.CURRENCIES[cur]
					table.insert(bits, string.format("<font color=\"#%s\">%s %s</font>", (if ok then Col.Text else Col.Danger):ToHex(), UIData.fmt(n), d and d.displayName or cur))
				end
				for mat, n in nc.materials or {} do
					local have = snap.materials and snap.materials[mat] or 0
					local ok = have >= n
					affordable = affordable and ok
					local d = ItemCatalog.MATERIALS[mat]
					table.insert(bits, string.format("<font color=\"#%s\">%s %s</font>", (if ok then Col.Text else Col.Danger):ToHex(), UIData.fmt(n), d and d.displayName or mat))
				end
			end
			card.cost.Text = if maxed then "Fully upgraded." elseif lockedByLevel then string.format("<font color=\"#%s\">Requires level %d</font>", Col.Warn:ToHex(), def.minPlayerLevel) else "Cost: " .. table.concat(bits, "  ·  ")
			card.buy:setText(if maxed then "Maxed" else "Upgrade")
			card.buy:setEnabled(not maxed and not lockedByLevel and affordable and not ui.busy[id])
		end
	end

	function Harvester._buy(id: string)
		if ui.busy[id] then
			return
		end
		ui.busy[id] = true
		ui.cards[id].buy:setBusy(true)
		task.spawn(function()
			local ok, code = UIData.Profile.purchaseUpgrade(id)
			ui.busy[id] = nil
			ui.cards[id].buy:setBusy(false)
			local def = EconomyConfig.UPGRADES[id]
			if ok then
				UIRoot.toast(string.upper(def.displayName or id) .. " upgraded", "success")
				UIRoot.sfx("Power_Up", 0.3, 1.4)
			else
				UIRoot.toast("Upgrade failed: " .. tostring(code), "error")
			end
			Harvester._refresh()
		end)
	end

	function Harvester._go()
		if UIData.onOwnPlanet() then
			local okW, WorldUI = pcall(require, script.Parent.Parent:FindFirstChild("WorldUI") :: ModuleScript)
			if okW and WorldUI and WorldUI.pointTo then
				WorldUI.pointTo("harvester")
				UIRoot.close()
				UIRoot.toast("Follow the marker to your Gravity Harvester", "info")
			end
			return
		end
		ui.go:setBusy(true)
		task.spawn(function()
			local ok, code = UIData.travelHome()
			ui.go:setBusy(false)
			if ok then
				UIRoot.close()
			else
				UIRoot.toast("Travel failed: " .. code, "error")
			end
		end)
	end

	local impl: any = {}
	function impl.refresh()
		Harvester._refresh()
	end
	function impl.layout(size: Vector2, mode: string)
		if mode == "wide" then
			left.Size = UDim2.new(0, 300, 1, 0)
			right.Position = UDim2.fromOffset(316, 0)
			right.Size = UDim2.new(1, -316, 1, 0)
		else
			left.Size = UDim2.new(1, 0, 0.42, 0)
			right.Position = UDim2.new(0, 0, 0.42, Sp.s)
			right.Size = UDim2.new(1, 0, 0.58, -Sp.s)
		end
	end
	function impl.firstSelection(): GuiObject?
		return ui.go.Instance
	end
	return impl
end

return Harvester
