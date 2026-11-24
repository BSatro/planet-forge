--!strict
-- SocialPanel — owner: Live Gameplay (presentation on Developer A's UI kit). "Planets": every claimed planet on
-- this server with owner, evolution stage, branch, discovered formations (read-only), DNA, visitors and reactions.
-- Actions: Visit (player-initiated warp), Showcase (cinematic orbit camera), React (Stellar / Wow / Inspiring).
-- Also lists live co-op activity (world events, a forming rift lobby). No trading by design.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)
local Client = script.Parent.Parent.Parent
local PlanetInfo = require(Client:WaitForChild("Social"):WaitForChild("PlanetInfo"))
local Showcase = require(Client.Social:WaitForChild("Showcase"))
local EventClient = require(Client:WaitForChild("Events"):WaitForChild("EventClient"))

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local SocialPanel = {}

function SocialPanel.available(): boolean
	local r = ReplicatedStorage:FindFirstChild("PF_Remotes")
	return r ~= nil and r:FindFirstChild("Social_Action") ~= nil
end

local DNA_ORDER = { "Temperature", "Water", "Life", "CosmicEnergy" }
local DNA_LABEL = { Temperature = "Temp", Water = "Water", Life = "Life", CosmicEnergy = "Energy" }

function SocialPanel.build(shell: any)
	local body: Frame = shell.Body
	local list = C.scroll({ parent = body, gap = Sp.s })
	local state: any = { selected = nil, busy = false }
	C.caption("Live activity", list, 1, Col.Magenta)
	local activity = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = list, order = 2 })
	activity.RichText = true
	C.caption("Planets on this server", list, 3, Col.Cyan)
	local empty = C.text({ text = "", size = S.Small, color = Col.TextMute, autoY = true, parent = list, order = 4 })
	local holder = C.make("Frame", { Name = "Planets", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = list }, { C.list(Enum.FillDirection.Vertical, Sp.s) })
	C.text({ text = "Formations and evolution shown here are public and read-only. Reactions are visible to everyone on this server and reset when the server closes. Trading is not available.", size = S.Micro, color = Col.TextMute, autoY = true, parent = list, order = 6 })

	local impl: any = {}
	local pool = C.pool(function()
		local card = C.glass({ name = "PlanetCard", variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = holder })
		card.AutomaticSize = Enum.AutomaticSize.Y
		local st = card:FindFirstChildOfClass("UIStroke") or C.stroke(Col.Cyan, 0.8)
		st.Parent = card
		local inner = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
		local headBtn = C.make("TextButton", { Name = "Head", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 1, SelectionImageObject = C.selectionImage, Parent = inner })
		local swatch = C.make("Frame", { Name = "Swatch", BackgroundColor3 = Col.Cyan, Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(0, 5), Parent = headBtn }, { C.corner(15) })
		local title = C.text({ text = "", size = 15, font = F.Display, parent = headBtn, dims = UDim2.new(1, -150, 0, 20) })
		title.Position = UDim2.fromOffset(42, 2)
		local sub = C.text({ text = "", size = S.Micro, font = F.Semi, color = Col.TextDim, parent = headBtn, dims = UDim2.new(1, -150, 0, 16) })
		sub.Position = UDim2.fromOffset(42, 22)
		local stars = C.text({ text = "", size = S.Small, font = F.Bold, color = Col.Gold, align = Enum.TextXAlignment.Right, parent = headBtn, dims = UDim2.new(0, 140, 0, 20) })
		stars.AnchorPoint = Vector2.new(1, 0)
		stars.Position = UDim2.new(1, 0, 0, 10)
		-- detail (expanded)
		local detail = C.make("Frame", { Name = "Detail", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Visible = false, Parent = inner }, { C.list(Enum.FillDirection.Vertical, 6) })
		local dna = C.text({ text = "", size = S.Micro, font = F.Semi, color = Col.TextDim, parent = detail, order = 1, autoY = true })
		C.caption("Discovered formations", detail, 2)
		local forms = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = detail })
		local fl = C.list(Enum.FillDirection.Horizontal, 6)
		fl.Wraps = true
		fl.Parent = forms
		local formPool = C.pool(function()
			return C.chip("", Col.Cyan, forms)
		end)
		local noForms = C.text({ text = "No formations discovered yet.", size = S.Small, color = Col.TextMute, parent = detail, order = 4, autoY = true })
		local reactRow = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 5, Parent = detail }, { C.list(Enum.FillDirection.Horizontal, 6) })
		local react: { [string]: any } = {}
		local item: any = { Instance = card, stroke = st, swatch = swatch, title = title, sub = sub, stars = stars, detail = detail, dna = dna, formPool = formPool, noForms = noForms, react = react, slot = 0 }
		for i, k in EventConfig.SOCIAL.reactionOrder do
			local r = EventConfig.SOCIAL.reactions[k]
			react[k] = C.button({ text = r.label, icon = r.icon, style = "ghost", dims = UDim2.fromOffset(112, 30), size = S.Micro, parent = reactRow, order = i, onClick = function()
				impl.react(item.slot, k)
			end })
		end
		item.reactNote = C.text({ text = "", size = S.Micro, color = Col.TextMute, parent = detail, order = 6, autoY = true })
		local actions = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 7, Parent = detail }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
		item.visit = C.button({ text = "Visit", icon = "travel", style = "solid", dims = UDim2.fromOffset(130, 32), parent = actions, order = 1, onClick = function()
			impl.visit(item.slot)
		end })
		item.showcase = C.button({ text = "Showcase", icon = "camera", style = "primary", dims = UDim2.fromOffset(150, 32), parent = actions, order = 2, onClick = function()
			Showcase.open(item.slot)
		end })
		headBtn.Activated:Connect(function()
			state.selected = if state.selected == item.slot then nil else item.slot
			impl.refresh()
		end)
		return item
	end)

	function impl.react(slot: number, kind: string)
		if state.busy then
			return
		end
		state.busy = true
		task.spawn(function()
			local ok, code = PlanetInfo.react(slot, kind)
			state.busy = false
			if ok then
				UIRoot.toast("Reaction sent: " .. EventConfig.SOCIAL.reactions[kind].label, "success", "star")
			else
				UIRoot.toast(PlanetInfo.reasonText(code), "info", "star")
			end
			impl.refresh()
		end)
	end

	function impl.visit(slot: number)
		UIRoot.close()
		task.spawn(function()
			local info = PlanetInfo.get(slot)
			local ok, code
			if info and info.own then
				ok, code = UIData.travelHome()
			else
				ok, code = PlanetInfo.visit(slot)
			end
			if not ok then
				UIRoot.toast("Travel: " .. PlanetInfo.reasonText(code), "info", "travel")
			end
		end)
	end

	function impl.refresh()
		-- live co-op activity
		local lines = {}
		for _, v in EventClient.list() do
			if v.phase ~= "ending" then
				local extra = if v.eventId == "CosmicConvergence" and v.phase == "active" then string.format(" — %d explorer(s) helping at THE FORGE", v.attrs.Participants or 0) else ""
				table.insert(lines, string.format("<font color=\"#%s\">%s</font> %s%s", v.def.color:ToHex(), string.upper(v.name), if v.phase == "incoming" then "incoming" else "active", extra))
			end
		end
		local w = Workspace:FindFirstChild("PF_World")
		local portal = w and w:FindFirstChild("RiftSurface", true)
		local holderP = portal and portal.Parent
		local lobby = holderP and holderP:GetAttribute("PFRiftLobbyCount") or 0
		local runs = holderP and holderP:GetAttribute("PFRiftActiveRuns") or 0
		if lobby > 0 then
			table.insert(lines, string.format("<font color=\"#%s\">COSMIC RIFT</font> lobby open — %d explorer(s) waiting at the portal (Expedition panel, X)", Col.Magenta:ToHex(), lobby))
		elseif runs > 0 then
			table.insert(lines, string.format("<font color=\"#%s\">COSMIC RIFT</font> %d run(s) in progress", Col.Magenta:ToHex(), runs))
		end
		activity.Text = if #lines > 0 then table.concat(lines, "\n") else "Quiet right now. World events appear every few minutes."
		-- planets
		local infos = PlanetInfo.list()
		local others = 0
		for _, info in infos do
			if not info.own then
				others += 1
			end
		end
		empty.Visible = others == 0
		empty.Text = "No other explorer has claimed a planet on this server yet. Your own world is listed — when friends join, visit and react to their planets here."
		local here = PlanetInfo.currentSlot()
		pool:sync(#infos, function(item, i)
			local info = infos[i]
			item.slot = info.slot
			item.swatch.BackgroundColor3 = info.branchColor
			item.title.Text = string.format("PLANET %02d · %s%s", info.slot, string.upper(info.ownerName), if info.own then "  (YOU)" else "")
			item.sub.Text = string.format("Stage %d %s · %s · %d formation(s)%s%s", info.stage, info.stageName, info.branchName, info.formationCount, if info.visitors > 0 then string.format(" · %d visiting", info.visitors) else "", if here == info.slot then " · you are here" else "")
			item.stars.Text = string.format("%d reaction(s)", info.reactions.total or 0)
			local open = state.selected == info.slot
			item.detail.Visible = open
			item.stroke.Transparency = if open then 0.2 else 0.8
			if open then
				local bits = {}
				for _, k in DNA_ORDER do
					table.insert(bits, string.format("%s %d", DNA_LABEL[k], math.floor(info.dna[k] or 0)))
				end
				item.dna.Text = "DNA  ·  " .. table.concat(bits, "  ·  ") .. (if info.visitorNames ~= "" then "\nVisiting now: " .. info.visitorNames else "")
				item.formPool:sync(#info.formations, function(chip, j)
					local f = info.formations[j]
					C.setChip(chip, if f.count > 1 then string.format("%s ×%d", f.name, f.count) else f.name, f.color)
				end)
				item.noForms.Visible = #info.formations == 0
				for k, b in item.react do
					b:setText(string.format("%s %d", EventConfig.SOCIAL.reactions[k].label, info.reactions[k] or 0))
					b:setStyle(if info.mine == k then "solid" else "ghost")
					b:setEnabled(not info.own and here == info.slot, if info.own then "Your own planet" else "Visit the planet or open its showcase to react")
				end
				item.reactNote.Text = if info.own then "Visitors can react to your planet." elseif here == info.slot then "One reaction per planet per server session (changeable)." else "Visit this planet (or react from its Showcase) to leave a reaction."
				item.visit:setText(if info.own then "Go home" else "Visit")
				item.visit.Instance.Visible = here ~= info.slot
			end
		end)
	end

	local conn: RBXScriptConnection? = nil
	function impl.onOpen()
		task.spawn(function()
			PlanetInfo.refreshMine()
			impl.refresh()
		end)
		impl.refresh()
		local acc = 0
		conn = RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc >= 1 then
				acc = 0
				impl.refresh()
			end
		end)
	end
	function impl.onClose()
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end
	function impl.firstSelection(): GuiObject?
		local first = pool.items[1]
		return first and first.Instance:FindFirstChild("Head", true) :: GuiObject?
	end
	local _ = player
	return impl
end

return SocialPanel
