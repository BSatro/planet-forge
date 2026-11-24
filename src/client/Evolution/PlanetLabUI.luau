--!strict
-- PlanetLabUI — owner: Developer B (gameplay UI; Developer A may restyle or replace it — all data and
-- actions come from PF_Shared.Client.EvolutionClient). Opens with L / gamepad DPadUp / the PLANET LAB button.
--   Left:  Planet DNA bars, next-stage requirements, materials
--   Tabs:  REACTIONS (previews: costs, conditions, DNA changes, formations, first-discovery reward)
--          EVOLUTION (4 branches: requirements, costs, unlocks, consequences, confirm dialog; future branches)
--          CODEX     (undiscovered / discovered / mastered, mastery goals, planet cosmetics)
-- Every action is a request; only the server's answer changes what is shown. Buttons lock while a request
-- is in flight (double-click safe on top of the server's actionId + revision protection).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.PF_Shared
local EvolutionClient = require(Shared.Client.EvolutionClient)
local PlanetConfig = require(Shared.Config.PlanetConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local Audio = require(script.Parent.Parent.Harvest.HarvestAudio)

local PlanetLabUI = {}

local player = Players.LocalPlayer

local COL = {
	bg = Color3.fromRGB(10, 14, 26),
	panel = Color3.fromRGB(18, 24, 42),
	card = Color3.fromRGB(24, 32, 54),
	cardHi = Color3.fromRGB(30, 44, 72),
	text = Color3.fromRGB(230, 240, 255),
	dim = Color3.fromRGB(150, 165, 195),
	cyan = Color3.fromRGB(70, 230, 255),
	green = Color3.fromRGB(90, 255, 150),
	red = Color3.fromRGB(255, 110, 110),
	gold = Color3.fromRGB(255, 215, 90),
	violet = Color3.fromRGB(170, 120, 255),
}

local STATUS = {
	AVAILABLE = { "READY", COL.green },
	NEEDS_MATERIALS = { "NEED MATERIALS", COL.gold },
	LOCKED = { "LOCKED", COL.dim },
	NO_EFFECT = { "NO EFFECT", COL.dim },
	DONE = { "COMPLETED", COL.cyan },
	MAXED = { "MAXED", COL.cyan },
	CURRENT = { "CURRENT", COL.cyan },
	UNAVAILABLE = { "COMING SOON", COL.dim },
}

local gui: ScreenGui
local window: Frame
local scale: UIScale
local content: ScrollingFrame
local toastLabel: TextLabel
local banner: TextLabel
local header: TextLabel
local leftDna: Frame
local leftStage: Frame
local leftMats: Frame
local modal: Frame
local tabButtons: { [string]: TextButton } = {}
local tab = "REACTIONS"
local busy = false
local open = false

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(className)
	for k, v in props do
		(i :: any)[k] = v
	end
	if parent then
		i.Parent = parent
	end
	return i
end

local function corner(parent: Instance, r: number)
	new("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end

local function stroke(parent: Instance, color: Color3, t: number?, th: number?)
	new("UIStroke", { Color = color, Transparency = t or 0.5, Thickness = th or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, parent)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextColor3 = props.TextColor3 or COL.text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextSize = props.TextSize or 14
	return new("TextLabel", props, parent)
end

local function button(parent: Instance, props: { [string]: any }, color: Color3): TextButton
	props.BackgroundColor3 = props.BackgroundColor3 or COL.cardHi
	props.Font = props.Font or Enum.Font.GothamBold
	props.TextColor3 = props.TextColor3 or color
	props.TextSize = props.TextSize or 15
	props.AutoButtonColor = true
	local b = new("TextButton", props, parent)
	corner(b, 8)
	stroke(b, color, 0.2, 1.5)
	return b
end

local function signed(n: number): string
	return if n > 0 then "+" .. n else tostring(n)
end

local function hex(c: Color3): string
	return string.format("#%02X%02X%02X", math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255))
end

local function dnaLine(delta: any): string
	local parts = {}
	for _, id in PlanetConfig.DNA_ORDER do
		local v = delta and delta[id] or 0
		if v ~= 0 then
			local def = PlanetConfig.DNA_PARAMS[id]
			table.insert(parts, string.format('<font color="%s">%s %s</font>', hex(def.color), def.displayName, signed(v)))
		end
	end
	return table.concat(parts, "   ")
end

local function costLine(costs: any): string
	local parts = {}
	for _, c in costs or {} do
		table.insert(parts, string.format('<font color="%s">%s %d/%d</font>', hex(if c.ok then COL.text else COL.red), c.name, c.have, c.need))
	end
	return table.concat(parts, "  ·  ")
end

local function rewardLine(r: any): string
	if not r then
		return ""
	end
	local parts = {}
	if r.credits then
		table.insert(parts, "+" .. r.credits .. " Credits")
	end
	if r.xp then
		table.insert(parts, "+" .. r.xp .. " XP")
	end
	for mid, n in r.materials or {} do
		local e = ItemCatalog.MATERIALS[mid]
		table.insert(parts, "+" .. n .. " " .. (if e then e.displayName else mid))
	end
	if r.cosmetic then
		local e = ItemCatalog.COSMETICS[r.cosmetic]
		table.insert(parts, "Cosmetic: " .. (if e then e.displayName else r.cosmetic))
	end
	return table.concat(parts, "  ")
end

local toastToken = {}
local function toast(text: string, color: Color3)
	toastLabel.Text = text
	toastLabel.TextColor3 = color
	toastLabel.TextTransparency = 0
	toastLabel.BackgroundTransparency = 0.15
	toastLabel.Visible = true
	local tok = {}
	toastToken = tok
	task.delay(4.5, function()
		if toastToken ~= tok then
			return
		end
		TweenService:Create(toastLabel, TweenInfo.new(0.6), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		task.delay(0.7, function()
			if toastToken == tok then
				toastLabel.Visible = false
			end
		end)
	end)
end

---------------------------------------------------------------- left column

local function refreshLeft()
	for _, c in leftDna:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	for i, d in EvolutionClient.dna() do
		local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = i }, leftDna)
		label(row, { Size = UDim2.new(1, -40, 0, 18), Text = d.name, Font = Enum.Font.GothamBold, TextColor3 = d.color })
		label(row, { Position = UDim2.new(1, -40, 0, 0), Size = UDim2.new(0, 40, 0, 18), Text = tostring(d.value), TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBold })
		local back = new("Frame", { Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 10), BackgroundColor3 = COL.card, BorderSizePixel = 0 }, row)
		corner(back, 5)
		local fill = new("Frame", { Size = UDim2.fromScale(math.clamp(d.value / 100, 0, 1), 1), BackgroundColor3 = d.color, BorderSizePixel = 0 }, back)
		corner(fill, 5)
	end
	for _, c in leftStage:GetChildren() do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	local st = EvolutionClient.stage()
	if st then
		label(leftStage, { Size = UDim2.new(1, 0, 0, 18), Text = string.format("STAGE %d · %s", st.stage, string.upper(st.name)), Font = Enum.Font.GothamBlack, TextColor3 = COL.cyan, LayoutOrder = 1 })
		if st.next then
			label(leftStage, { Size = UDim2.new(1, 0, 0, 16), Text = "Next: " .. st.next.name, TextColor3 = COL.dim, TextSize = 13, LayoutOrder = 2 })
			for i, t in st.next.unmetTexts do
				if i > 4 then
					break
				end
				label(leftStage, { Size = UDim2.new(1, 0, 0, 30), Text = "• " .. t, TextWrapped = true, TextSize = 12, TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = 2 + i })
			end
		else
			label(leftStage, { Size = UDim2.new(1, 0, 0, 16), Text = "Maximum stage reached", TextColor3 = COL.gold, TextSize = 13, LayoutOrder = 2 })
		end
	end
	for _, c in leftMats:GetChildren() do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	for i, m in EvolutionClient.materials() do
		label(leftMats, { Text = string.format('<font color="%s">●</font> %s  <b>%d</b>', hex(m.color), m.name, m.amount), RichText = true, TextSize = 13, LayoutOrder = i })
	end
	local s = EvolutionClient.view()
	local slot = player:GetAttribute("PF_Slot")
	if st then
		header.Text = string.format("PLANET LAB  ·  PLANET %02d  ·  %s", tonumber(slot) or 0, string.upper(st.branchName or "Unspecialized"))
	end
	local ps = player:GetAttribute("PF_ProfileState")
	if ps == "restricted" or ps == "loading" or not s then
		banner.Text = "Your planet data is loading or temporarily unavailable — progress is paused, nothing is lost."
		banner.Visible = true
	elseif not EvolutionClient.isOnOwnPlanet() then
		banner.Text = "You can browse here, but reactions only work while you stand on your own planet."
		banner.Visible = true
	else
		banner.Visible = false
	end
end

---------------------------------------------------------------- tabs

local refreshContent: () -> ()

local function act(kind: string, id: string, display: string)
	if busy then
		return
	end
	busy = true
	refreshContent()
	task.spawn(function()
		local ok, code, data
		if kind == "react" then
			ok, code, data = EvolutionClient.react(id)
		elseif kind == "commit" then
			ok, code, data = EvolutionClient.commit(id)
		else
			local cat, cid = string.match(id, "^(.-)|(.+)$")
			ok, code, data = EvolutionClient.setCosmetic(cat :: string, cid :: string)
		end
		busy = false
		if ok then
			local text
			if kind == "react" then
				local parts = { (if data.firstDiscovery then "DISCOVERED: " else "") .. string.upper(display) }
				for _, f in data.formations or {} do
					table.insert(parts, "New: " .. (ItemCatalog.FORMATIONS[f.id] and ItemCatalog.FORMATIONS[f.id].displayName or f.id))
				end
				if data.reward then
					table.insert(parts, rewardLine(data.reward))
				end
				if data.newStages and #data.newStages > 0 then
					table.insert(parts, "STAGE " .. data.stage .. " REACHED")
				end
				for _, m in data.masteries or {} do
					table.insert(parts, "Mastered " .. m)
				end
				text = table.concat(parts, "   •   ")
				Audio.play(if data.firstDiscovery then "perfect" else "lock")
			elseif kind == "commit" then
				text = "SPECIALIZED: " .. string.upper(display) .. "   •   Stage " .. tostring(data.stage)
				Audio.play("first")
			else
				text = "Appearance updated."
				Audio.play("lock")
			end
			toast(text, COL.green)
			-- let the player watch the planet change
			if kind ~= "cosmetic" and data and (data.transformation ~= nil) then
				PlanetLabUI.setOpen(false)
				toast(text .. "   (press L to reopen the Lab)", COL.green)
			end
		else
			Audio.play("denied")
			toast(EvolutionClient.describeError(code, data), COL.red)
		end
		refreshContent()
	end)
end

local function clearContent()
	for _, c in content:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function card(order: number, height: number, accent: Color3?): Frame
	local f = new("Frame", { Size = UDim2.new(1, -8, 0, height), BackgroundColor3 = COL.card, BorderSizePixel = 0, LayoutOrder = order }, content)
	corner(f, 10)
	if accent then
		new("Frame", { Size = UDim2.new(0, 4, 1, -16), Position = UDim2.fromOffset(6, 8), BackgroundColor3 = accent, BorderSizePixel = 0 }, f)
	end
	return f
end

local function pill(parent: Instance, text: string, color: Color3)
	local p = label(parent, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(130, 20), Text = text, TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBlack, TextSize = 12, TextColor3 = color })
	return p
end

local function branchColor(b: string?): Color3
	local def = b and PlanetConfig.BRANCHES[b]
	return (def and def.color) or COL.cyan
end

local function buildReactions()
	for i, r in EvolutionClient.reactions() do
		local c = card(i, 118, branchColor(r.branch))
		label(c, { Position = UDim2.fromOffset(18, 8), Size = UDim2.new(1, -170, 0, 22), Text = r.name .. (if r.completions > 0 and r.repeats and r.repeats.mode ~= "once" then string.format("  (x%d)", r.completions) else ""), Font = Enum.Font.GothamBlack, TextSize = 17 })
		local s = STATUS[r.status] or { r.status, COL.dim }
		pill(c, s[1], s[2])
		label(c, { Position = UDim2.fromOffset(18, 30), Size = UDim2.new(1, -150, 0, 30), Text = r.description, TextWrapped = true, TextSize = 12, TextColor3 = COL.dim, TextYAlignment = Enum.TextYAlignment.Top })
		label(c, { Position = UDim2.fromOffset(18, 62), Size = UDim2.new(1, -150, 0, 16), Text = "Cost: " .. costLine(r.costs), RichText = true, TextSize = 12 })
		local eff = dnaLine(r.dnaDelta)
		for _, f in r.formations do
			eff ..= '   <font color="#FFFFFF">→ ' .. f.name .. "</font>"
		end
		label(c, { Position = UDim2.fromOffset(18, 79), Size = UDim2.new(1, -150, 0, 16), Text = "Effect: " .. (if eff == "" then "—" else eff), RichText = true, TextSize = 12 })
		local last = ""
		if #r.unmet > 0 and r.status ~= "DONE" and r.status ~= "MAXED" then
			last = '<font color="#FF8A8A">' .. table.concat(r.unmet, "  ·  ", 1, math.min(2, #r.unmet)) .. "</font>"
		elseif r.reward then
			last = '<font color="#FFD75A">First discovery: ' .. rewardLine(r.reward) .. "</font>"
		end
		label(c, { Position = UDim2.fromOffset(18, 96), Size = UDim2.new(1, -150, 0, 16), Text = last, RichText = true, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })
		if r.status ~= "DONE" and r.status ~= "MAXED" then
			local b = button(c, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -12), Size = UDim2.fromOffset(120, 40), Text = if busy then "…" else "REACT" }, if r.available then COL.green else COL.dim)
			b.Active = r.available and not busy
			b.AutoButtonColor = r.available and not busy
			b.Activated:Connect(function()
				if r.available and not busy then
					act("react", r.id, r.name)
				elseif not r.available then
					Audio.play("denied")
					toast(r.unmet[1] or "Not available right now.", COL.gold)
				end
			end)
		end
	end
end

local function confirmBranch(b: any)
	for _, c in modal:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local box = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(560, 300), BackgroundColor3 = COL.panel, BorderSizePixel = 0 }, modal)
	corner(box, 14)
	stroke(box, branchColor(b.id), 0, 2)
	label(box, { Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -40, 0, 28), Text = (if b.isRespec then "SWITCH TO " else "SPECIALIZE: ") .. string.upper(b.name), Font = Enum.Font.GothamBlack, TextSize = 22, TextColor3 = branchColor(b.id) })
	local body = b.consequences .. "\n\nCost: " .. costLine(b.costs) .. "\nUnlocks: " .. table.concat(b.unlocks, ", ") .. " · Landmark goal: " .. b.capstone
	if b.isRespec and #b.willGoDormant > 0 then
		body ..= "\nGoes dormant (kept): " .. table.concat(b.willGoDormant, ", ")
	end
	body ..= "\nYour Codex, cosmetics and materials are kept. You can switch again later."
	label(box, { Position = UDim2.fromOffset(20, 52), Size = UDim2.new(1, -40, 0, 180), Text = body, RichText = true, TextWrapped = true, TextSize = 14, TextYAlignment = Enum.TextYAlignment.Top })
	local yes = button(box, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -16), Size = UDim2.fromOffset(170, 44), Text = "CONFIRM" }, COL.green)
	local no = button(box, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -204, 1, -16), Size = UDim2.fromOffset(130, 44), Text = "CANCEL" }, COL.dim)
	modal.Visible = true
	yes.Activated:Connect(function()
		modal.Visible = false
		act("commit", b.id, b.name)
	end)
	no.Activated:Connect(function()
		modal.Visible = false
	end)
end

local function buildEvolution()
	local order = 0
	for _, b in EvolutionClient.branches() do
		order += 1
		if b.future then
			local c = card(100 + order, 40, COL.dim)
			label(c, { Position = UDim2.fromOffset(18, 10), Size = UDim2.new(1, -40, 0, 20), Text = b.name .. "  —  coming in a future update", TextColor3 = COL.dim, TextSize = 14 })
			continue
		end
		local c = card(order, 176, b.color)
		label(c, { Position = UDim2.fromOffset(18, 8), Size = UDim2.new(1, -170, 0, 24), Text = string.upper(b.name), Font = Enum.Font.GothamBlack, TextSize = 19, TextColor3 = b.color })
		local s = STATUS[b.status] or { b.status, COL.dim }
		pill(c, if b.status == "AVAILABLE" and b.isRespec then "CAN SWITCH" else s[1], s[2])
		label(c, { Position = UDim2.fromOffset(18, 32), Size = UDim2.new(1, -150, 0, 16), Text = (b.headline or "") .. "  ·  Focus: " .. (b.focus or ""), TextSize = 12, TextColor3 = COL.dim })
		label(c, { Position = UDim2.fromOffset(18, 52), Size = UDim2.new(1, -150, 0, 16), Text = "Formations: " .. table.concat(b.formations or {}, ", "), TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })
		label(c, { Position = UDim2.fromOffset(18, 70), Size = UDim2.new(1, -150, 0, 16), Text = "Cost: " .. costLine(b.costs), RichText = true, TextSize = 12 })
		local req = if #b.unmet > 0 then '<font color="#FF8A8A">Needs: ' .. table.concat(b.unmet, "  ·  ") .. "</font>" else '<font color="#5AFF96">All requirements met</font>'
		label(c, { Position = UDim2.fromOffset(18, 88), Size = UDim2.new(1, -150, 0, 34), Text = req, RichText = true, TextWrapped = true, TextSize = 12, TextYAlignment = Enum.TextYAlignment.Top })
		label(c, { Position = UDim2.fromOffset(18, 124), Size = UDim2.new(1, -150, 0, 44), Text = b.consequences or "", TextWrapped = true, TextSize = 11, TextColor3 = COL.dim, TextYAlignment = Enum.TextYAlignment.Top })
		if b.status ~= "CURRENT" then
			local btn = button(c, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -12, 1, -12), Size = UDim2.fromOffset(120, 44), Text = if busy then "…" elseif b.isRespec then "SWITCH" else "COMMIT" }, if b.available then COL.green else COL.dim)
			btn.Activated:Connect(function()
				if b.available and not busy then
					confirmBranch(b)
				elseif not b.available then
					Audio.play("denied")
					toast(b.unmet[1] or "Not available right now.", COL.gold)
				end
			end)
		end
	end
end

local STATE_STYLE = { UNDISCOVERED = { "?", COL.dim }, DISCOVERED = { "◆", COL.cyan }, MASTERED = { "★", COL.gold } }

local function buildCodex()
	local cx = EvolutionClient.codex()
	local head = card(0, 40, COL.gold)
	label(head, { Position = UDim2.fromOffset(18, 10), Size = UDim2.new(1, -30, 0, 20), Text = string.format("PLANET CODEX  ·  Discovered %d/%d  ·  Mastered %d", cx.discovered, cx.total, cx.mastered), Font = Enum.Font.GothamBlack, TextSize = 15, TextColor3 = COL.gold })
	for i, e in cx.entries do
		local st = STATE_STYLE[e.state] or { "?", COL.dim }
		local c = card(i, 58, st[2])
		local title = if e.state == "UNDISCOVERED" then ("???  (" .. e.category .. " reaction)") else e.name
		label(c, { Position = UDim2.fromOffset(18, 6), Size = UDim2.new(1, -150, 0, 20), Text = st[1] .. "  " .. title, Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = if e.state == "UNDISCOVERED" then COL.dim else COL.text })
		pill(c, e.state, st[2])
		local detail
		if e.state == "UNDISCOVERED" then
			detail = "Experiment with materials and conditions to discover it."
		elseif e.state == "MASTERED" then
			detail = string.format("Mastered  ·  completed %d time(s)", e.completions)
		else
			detail = "Mastery: " .. (e.masteryHint or "—") .. (if #e.masteryUnmet > 0 then "  (" .. e.masteryUnmet[1] .. ")" else "  (ready)")
		end
		label(c, { Position = UDim2.fromOffset(18, 30), Size = UDim2.new(1, -30, 0, 18), Text = detail, TextSize = 12, TextColor3 = COL.dim, TextTruncate = Enum.TextTruncate.AtEnd })
	end
	local cos = EvolutionClient.cosmetics()
	local cc = card(1000, 50 + 46 * math.max(1, #cos.owned), COL.violet)
	label(cc, { Position = UDim2.fromOffset(18, 8), Size = UDim2.new(1, -30, 0, 20), Text = "PLANET APPEARANCE", Font = Enum.Font.GothamBlack, TextSize = 15, TextColor3 = COL.violet })
	if #cos.owned == 0 then
		label(cc, { Position = UDim2.fromOffset(18, 34), Size = UDim2.new(1, -30, 0, 18), Text = "Earn atmospheres and rings from stage milestones and rare discoveries.", TextSize = 12, TextColor3 = COL.dim })
	end
	for i, o in cos.owned do
		local y = 34 + (i - 1) * 46
		local equipped = cos.equipped[o.category] == o.id
		label(cc, { Position = UDim2.fromOffset(18, y + 8), Size = UDim2.new(1, -170, 0, 20), Text = o.name .. "  (" .. o.category .. ")", TextSize = 14 })
		local b = button(cc, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, y), Size = UDim2.fromOffset(120, 38), Text = if equipped then "UNEQUIP" else "EQUIP" }, if equipped then COL.dim else COL.violet)
		b.Activated:Connect(function()
			act("cosmetic", o.category .. "|" .. (if equipped then "None" else o.id), o.name)
		end)
	end
end

refreshContent = function()
	if not open then
		return
	end
	clearContent()
	for name, b in tabButtons do
		b.BackgroundColor3 = if name == tab then COL.cardHi else COL.card
	end
	if tab == "REACTIONS" then
		buildReactions()
	elseif tab == "EVOLUTION" then
		buildEvolution()
	else
		buildCodex()
	end
	refreshLeft()
end

---------------------------------------------------------------- shell

local function fit()
	local vp = Workspace.CurrentCamera.ViewportSize
	scale.Scale = math.clamp(math.min((vp.X - 24) / 1000, (vp.Y - 24) / 620), 0.45, 1.15)
end

function PlanetLabUI.setOpen(v: boolean)
	open = v
	window.Visible = v
	if v then
		fit()
		refreshContent()
		Audio.play("enter")
	else
		modal.Visible = false
	end
end

function PlanetLabUI.toggle()
	PlanetLabUI.setOpen(not open)
end

function PlanetLabUI.isOpen(): boolean
	return open
end

function PlanetLabUI.init()
	EvolutionClient.init()
	gui = new("ScreenGui", { Name = "PF_PlanetLab", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 25, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
	local toggle = button(gui, { Name = "Toggle", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.66, 0), Size = UDim2.fromOffset(170, 46), Text = "PLANET LAB  [L]", BackgroundColor3 = COL.panel, TextSize = 15 }, COL.cyan)
	toggle.Activated:Connect(PlanetLabUI.toggle)

	-- bottom-centre with its own backing: never collides with the harvest HUD's top hint panel
	toastLabel = label(gui, { Name = "Toast", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -28), Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, Text = "", TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, TextSize = 17, TextStrokeTransparency = 0.6, Visible = false, ZIndex = 60 })
	toastLabel.BackgroundColor3 = COL.bg
	corner(toastLabel, 10)
	stroke(toastLabel, COL.cyan, 0.5, 1)
	new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, toastLabel)
	new("UISizeConstraint", { MaxSize = Vector2.new(1100, 36) }, toastLabel)

	window = new("Frame", { Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.fromOffset(1000, 620), BackgroundColor3 = COL.bg, BackgroundTransparency = 0, Visible = false }, gui)
	corner(window, 14)
	stroke(window, COL.cyan, 0.4, 1.5)
	scale = new("UIScale", {}, window)
	header = label(window, { Position = UDim2.fromOffset(20, 12), Size = UDim2.new(1, -90, 0, 28), Text = "PLANET LAB", Font = Enum.Font.GothamBlack, TextSize = 22, TextColor3 = COL.cyan })
	local close = button(window, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 10), Size = UDim2.fromOffset(44, 36), Text = "X" }, COL.text)
	close.Activated:Connect(function()
		PlanetLabUI.setOpen(false)
	end)
	banner = label(window, { Position = UDim2.fromOffset(20, 44), Size = UDim2.new(1, -40, 0, 20), Text = "", TextColor3 = COL.gold, TextSize = 13, Visible = false })

	local left = new("Frame", { Position = UDim2.fromOffset(16, 70), Size = UDim2.new(0, 290, 1, -86), BackgroundColor3 = COL.panel, BorderSizePixel = 0 }, window)
	corner(left, 10)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10) }, left)
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, left)
	label(left, { Size = UDim2.new(1, 0, 0, 18), Text = "PLANET DNA", Font = Enum.Font.GothamBlack, TextColor3 = COL.dim, TextSize = 13, LayoutOrder = 1 })
	leftDna = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 172), LayoutOrder = 2 }, left)
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, leftDna)
	leftStage = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 160), LayoutOrder = 3 }, left)
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, leftStage)
	label(left, { Size = UDim2.new(1, 0, 0, 18), Text = "MATERIALS", Font = Enum.Font.GothamBlack, TextColor3 = COL.dim, TextSize = 13, LayoutOrder = 4 })
	leftMats = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 80), LayoutOrder = 5 }, left)
	new("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 0, 18), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, leftMats)

	local right = new("Frame", { Position = UDim2.fromOffset(318, 70), Size = UDim2.new(1, -334, 1, -86), BackgroundTransparency = 1 }, window)
	local tabs = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1 }, right)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, tabs)
	for _, name in { "REACTIONS", "EVOLUTION", "CODEX" } do
		local b = button(tabs, { Size = UDim2.fromOffset(150, 38), Text = name, BackgroundColor3 = COL.card }, COL.cyan)
		tabButtons[name] = b
		b.Activated:Connect(function()
			tab = name
			refreshContent()
		end)
	end
	content = new("ScrollingFrame", { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 1, -48), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y }, right)
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, content)

	modal = new("Frame", { Name = "Modal", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Visible = false, ZIndex = 50 }, window)

	gui.Parent = player:WaitForChild("PlayerGui")
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	ContextActionService:BindAction("PF_PlanetLab", function(_, state)
		if state == Enum.UserInputState.Begin then
			PlanetLabUI.toggle()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.L, Enum.KeyCode.DPadUp)
	EvolutionClient.Changed:Connect(function()
		if open and not busy then
			refreshContent()
		end
	end)
	player:GetAttributeChangedSignal("PF_ProfileState"):Connect(function()
		if open then
			refreshLeft()
		end
	end)
end

return PlanetLabUI
