--!strict
-- CodexPanel — owner: Developer A. Planet Codex: discovered reactions (+ mastery), formations (owned / max,
-- undiscovered ones hinted by branch), evolution milestones with dates and rewards, and progression stats.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local Shared = ReplicatedStorage.PF_Shared
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local PlanetConfig = require(Shared.Config.PlanetConfig)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Codex = {}

local function branchColor(id: string?): Color3
	local b = id and PlanetConfig.getBranch(id)
	return (b and b.color) or Col.Cyan
end

function Codex.build(shell: any)
	local body: Frame = shell.Body
	local state = { tab = "reactions" }
	local ui: any = {}
	ui.tabs = C.tabs({ items = { { id = "reactions", label = "Reactions", icon = "flask" }, { id = "formations", label = "Formations", icon = "formation" }, { id = "milestones", label = "Milestones", icon = "flag" }, { id = "progress", label = "Progress", icon = "level" } }, parent = body, onSelect = function(id)
		state.tab = id
		Codex._refresh()
	end })
	ui.summary = C.text({ text = "", size = S.Small, font = F.Semi, color = Col.TextDim, parent = body, dims = UDim2.new(1, 0, 0, 20) })
	ui.summary.Position = UDim2.fromOffset(0, 46)
	ui.summary.RichText = true
	local area = C.make("Frame", { Name = "Area", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 74), Size = UDim2.new(1, 0, 1, -74), Parent = body })

	-- generic card grid used by reactions + formations
	local grid = C.make("ScrollingFrame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, ScrollBarImageColor3 = Col.Cyan, Selectable = false, Parent = area }, {
		C.make("UIGridLayout", { CellSize = UDim2.fromOffset(210, 92), CellPadding = UDim2.fromOffset(Sp.s, Sp.s), SortOrder = Enum.SortOrder.LayoutOrder }),
		C.pad(2, 6, 2, 2),
	})
	ui.grid = grid
	ui.cardPool = C.pool(function()
		local f = C.make("TextButton", { Name = "Card", Text = "", AutoButtonColor = false, BackgroundColor3 = Col.PanelHi, BackgroundTransparency = 0.55, SelectionImageObject = C.selectionImage, Parent = grid }, { C.corner(Theme.Radius.m) })
		local st = C.stroke(Col.Cyan, 0.85)
		st.Parent = f
		local ic = C.icon("flask", 18, Col.Cyan, f)
		ic.Position = UDim2.fromOffset(12, 12)
		local title = C.text({ text = "", size = S.Small, font = F.Bold, parent = f, dims = UDim2.new(1, -44, 0, 18) })
		title.Position = UDim2.fromOffset(38, 11)
		local sub = C.text({ text = "", size = S.Micro, color = Col.TextDim, wrap = true, parent = f, dims = UDim2.new(1, -24, 0, 30) })
		sub.Position = UDim2.fromOffset(12, 36)
		sub.TextYAlignment = Enum.TextYAlignment.Top
		local foot = C.text({ text = "", size = S.Micro, font = F.Display, color = Col.TextMute, parent = f, dims = UDim2.new(1, -24, 0, 14) })
		foot.Position = UDim2.new(0, 12, 1, -20)
		foot.RichText = true
		local item: any = { Instance = f, stroke = st, icon = ic, title = title, sub = sub, foot = foot, tip = "" }
		C.tooltip(f, function() return item.tip end)
		return item
	end)

	-- list used by milestones + progress
	local list = C.scroll({ name = "List", parent = area, gap = Sp.s })
	ui.list = list
	ui.rowPool = C.pool(function()
		local f = C.glass({ name = "Row", variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = list })
		f.AutomaticSize = Enum.AutomaticSize.Y
		C.pad(Sp.m, Sp.l, Sp.m, Sp.l).Parent = f
		local ic = C.icon("flag", 20, Col.Cyan, f)
		ic.Position = UDim2.fromOffset(0, 2)
		local holder = C.make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(34, 0), Size = UDim2.new(1, -150, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = f }, { C.list(Enum.FillDirection.Vertical, 2) })
		local title = C.text({ text = "", size = S.Body, font = F.Bold, autoY = true, parent = holder, order = 1 })
		local sub = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = holder, order = 2 })
		sub.RichText = true
		local chip = C.chip("", Col.TextMute, f)
		chip.AnchorPoint = Vector2.new(1, 0)
		chip.Position = UDim2.new(1, 0, 0, 0)
		return { Instance = f, icon = ic, title = title, sub = sub, chip = chip }
	end)

	local function recolor(icon: Instance, color: Color3)
		for _, d in icon:GetDescendants() do
			if d:IsA("Frame") and d.BackgroundColor3 ~= Color3.new(1, 1, 1) and d.BackgroundColor3 ~= Color3.new(0, 0, 0) then
				d.BackgroundColor3 = color
			elseif d:IsA("UIStroke") then
				d.Color = color
			end
		end
	end

	function Codex._refresh()
		ui.tabs:select(state.tab)
		local snap = UIData.snapshot()
		local isGrid = state.tab == "reactions" or state.tab == "formations"
		grid.Visible = isGrid
		list.Visible = not isGrid
		if state.tab == "reactions" then
			local cx = UIData.Evolution.codex()
			local entries = cx.entries or {}
			ui.summary.Text = string.format("Discovered <b>%d</b> / %d   ·   Mastered <b>%d</b>", cx.discovered or 0, cx.total or #entries, cx.mastered or 0)
			ui.cardPool:sync(#entries, function(item, i)
				local e = entries[i]
				local known = e.state ~= "UNDISCOVERED"
				local color = if e.state == "MASTERED" then Col.Gold elseif known then Col.Cyan else Col.TextMute
				item.title.Text = if known then e.name else "Undiscovered"
				item.title.TextColor3 = if known then Col.Text else Col.TextMute
				item.sub.Text = if known then (e.description or "") else string.format("A %s reaction waiting to be found.", tostring(e.category or "cosmic"))
				item.foot.Text = if e.state == "MASTERED" then "MASTERED" elseif known then string.format("COMPLETED %d×", e.completions or 0) else string.upper(tostring(e.category or ""))
				item.foot.TextColor3 = color
				item.stroke.Color = color
				item.stroke.Transparency = if known then 0.6 else 0.88
				recolor(item.icon, color)
				local mastery = e.masteryUnmet or {}
				item.tip = if known and #mastery > 0 then "Mastery: " .. table.concat(mastery, " · ") elseif known then e.description or "" else "Discover it through experimentation in the DNA Lab."
			end)
		elseif state.tab == "formations" then
			local owned = (snap and snap.planet and snap.planet.formations) or {}
			local counts = (snap and snap.planet and snap.planet.formationCounts) or {}
			local ids = FormationRegistry.ORDER or {}
			local have = 0
			for _, id in ids do
				local n = counts[id] or (if type(owned[id]) == "table" then owned[id].n elseif table.find(owned :: any, id) then 1 else 0)
				if (n or 0) > 0 then
					have += 1
				end
			end
			ui.summary.Text = string.format("Formations on your planet: <b>%d</b> / %d types", have, #ids)
			ui.cardPool:sync(#ids, function(item, i)
				local id = ids[i]
				local def = FormationRegistry.DEFS[id] or {}
				local n = counts[id] or (if type(owned[id]) == "table" then owned[id].n elseif table.find(owned :: any, id) then 1 else 0) or 0
				local color = if n > 0 then branchColor(def.branch) else Col.TextMute
				item.title.Text = if n > 0 then (def.displayName or id) else "Unknown formation"
				item.title.TextColor3 = if n > 0 then Col.Text else Col.TextMute
				item.sub.Text = string.format("%s · Tier %d%s", def.branch or "Any branch", def.tier or 1, if def.landmark then " · Landmark" else "")
				item.foot.Text = string.format("%d / %d", n, def.maxCount or 1)
				item.foot.TextColor3 = color
				item.stroke.Color = color
				item.stroke.Transparency = if n > 0 then 0.55 else 0.88
				recolor(item.icon, color)
				item.tip = if n > 0 then (def.displayName or id) else "Unlocked by reactions" .. (if def.branch then " of the " .. def.branch .. " branch." else ".")
			end)
		elseif state.tab == "milestones" then
			local stage = snap and snap.planet and snap.planet.stage or 0
			local stageAt = snap and snap.planet and snap.planet.stageAt or {}
			local rows = {}
			for n = 0, 4 do
				local def = EvolutionConfig.STAGES[n]
				if def then
					local reached = stage >= n
					local at = stageAt[n] or stageAt[tostring(n)]
					local rw = def.reward
					local rwText = ""
					if rw then
						local bits = {}
						if rw.credits then table.insert(bits, UIData.fmt(rw.credits) .. " credits") end
						if rw.xp then table.insert(bits, rw.xp .. " XP") end
						if type(rw.materials) == "table" then
							for id, q in rw.materials do
								local md = UIData.materialDef(id)
								table.insert(bits, string.format("%d %s", q, md and md.displayName or id))
							end
						end
						rwText = if #bits > 0 then string.format("\n<font color=\"#%s\">Reward: %s</font>", Col.Gold:ToHex(), table.concat(bits, " · ")) else ""
					end
					table.insert(rows, { title = string.format("Stage %d · %s", n, def.name), sub = (def.description or "") .. (if not reached and def.goal then "\nGoal: " .. def.goal else "") .. rwText, chip = if reached then (if type(at) == "number" and at > 0 then "Reached " .. os.date("%d %b", at) else "Reached") else (if n == stage + 1 then "Next" else "Locked"), color = if reached then Col.Success elseif n == stage + 1 then Col.Cyan else Col.TextMute, icon = "flag" })
				end
			end
			ui.summary.Text = string.format("Evolution stage <b>%d</b> / 4", stage)
			ui.rowPool:sync(#rows, function(item, i)
				local rr = rows[i]
				item.title.Text = rr.title
				item.sub.Text = rr.sub
				C.setChip(item.chip, rr.chip, rr.color)
				recolor(item.icon, rr.color)
			end)
		else
			local st = snap and snap.stats or {}
			local ex = snap and snap.expeditions or {}
			local cx = UIData.Evolution.codex()
			local rows = {
				{ title = string.format("Level %d", snap and snap.level or 1), sub = string.format("%s / %s XP to the next level", UIData.fmt(snap and snap.xp or 0), UIData.fmt(snap and snap.xpToNext or 0)), chip = string.format("Max %d", snap and snap.maxLevel or 50), color = Col.Magenta, icon = "level" },
				{ title = "Harvesting", sub = string.format("%s captures · %s matter harvested", UIData.fmt(st.harvests or 0), UIData.fmt(st.materialsHarvested or 0)), chip = "Harvester", color = Col.Cyan, icon = "harvester" },
				{ title = "Economy", sub = string.format("%s credits earned · %s spent · %s matter sold · %d upgrades", UIData.fmt(st.creditsEarned or 0), UIData.fmt(st.creditsSpent or 0), UIData.fmt(st.materialsSold or 0), st.upgradesBought or 0), chip = "Credits", color = Col.Gold, icon = "credits" },
				{ title = "Discoveries", sub = string.format("%d of %d reactions discovered · %d mastered", cx.discovered or 0, cx.total or 0, cx.mastered or 0), chip = "Codex", color = Col.Success, icon = "flask" },
				{ title = "Expeditions", sub = string.format("%d completed", ex.totalCompleted or 0), chip = "History", color = Col.TextDim, icon = "expedition" },
			}
			ui.summary.Text = "Your journey so far"
			ui.rowPool:sync(#rows, function(item, i)
				local rr = rows[i]
				item.title.Text = rr.title
				item.sub.Text = rr.sub
				C.setChip(item.chip, rr.chip, rr.color)
				recolor(item.icon, rr.color)
			end)
		end
	end

	local impl: any = {}
	function impl.refresh()
		Codex._refresh()
	end
	function impl.layout(size: Vector2, mode: string)
		local w = size.X - 48
		local cols = math.max(1, math.floor((w + Sp.s) / (210 + Sp.s)))
		local cellW = math.floor((w - (cols - 1) * Sp.s - 8) / cols)
		local gridLayout = grid:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout
		gridLayout.CellSize = UDim2.fromOffset(cellW, 92)
		Codex._refresh()
	end
	function impl.firstSelection(): GuiObject?
		return ui.tabs.buttons[state.tab].Instance
	end
	return impl
end

return Codex
