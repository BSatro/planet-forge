--!strict
-- EventHud — owner: Live Gameplay (client presentation on Developer A's UI kit). Informative, non-intrusive:
--   * event chips (top centre): icon, name, timer, one-line effect, time bar; click -> Cosmic Events panel
--   * a first-seen intro card per event type (what is happening, what to do, time left) — also for players who
--     join mid-event; never shown inside a rift (deferred until the player is back)
--   * Cosmic Convergence card (reactor stability, stage, my contribution, top contributors, carried-cell timer),
--     shown near THE FORGE or once the player has contributed
--   * feedback toasts (captures, solar surges, tasks, sync, hints, visitors, reactions) + the reward summary card
--   * Studio-only developer strip (F3): start / end events, test mode, scheduler (Event_Dev exists only in Studio)
-- Chips and the convergence card live on the Hud layer, so they hide with the HUD (rifts, harvesting, cinematics).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)
local Shared = ReplicatedStorage.PF_Shared
local EventConfig = require(Shared.Events.EventConfig)
local WorldLayout = require(Shared.Config.WorldLayout)
local Events = script.Parent.Parent:WaitForChild("Events")
local EventClient = require(Events:WaitForChild("EventClient"))
local EventInteract = require(Events:WaitForChild("EventInteract"))

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local EventHud = {}
local ui: any = {}
local introShown: { [string]: boolean } = {}
local introQueue: { string } = {}
local summaryToken = 0
local introToken = 0
local lastHint = 0

local function fmtTime(sec: number): string
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function inRift(): boolean
	return player:GetAttribute("PFInRiftLocal") == true
end

local function nearStation(): boolean
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return r ~= nil and (r.Position - WorldLayout.STATION_CENTER).Magnitude <= 260
end

local function outcomeText(v: any): string
	if v.eventId == "CosmicConvergence" then
		return if v.outcome == "completed" then "Reactor stabilized — rewards sent!" elseif v.outcome == "cancelled" then "Cancelled" else "The reactor settled on its own"
	end
	return if v.outcome == "cancelled" then "Cancelled" else "Event over"
end

local function progressPct(v: any): number
	local p, t = v.attrs.Progress or 0, v.attrs.Target or 1
	return math.clamp(math.floor(p / math.max(1, t) * 100), 0, 100)
end

local function chipInfo(v: any): (string, number)
	local t = EventClient.serverNow()
	if v.phase == "incoming" then
		return "Starting in " .. fmtTime(v.activeAt - t), 1
	elseif v.phase == "active" then
		local left = v.endsAt - t
		local frac = left / math.max(1, v.endsAt - v.activeAt)
		local line = v.def.effect
		if v.eventId == "CosmicConvergence" then
			line = string.format("Reactor %d%% · help at THE FORGE", progressPct(v))
		elseif v.eventId == "MeteorShower" then
			local left2 = EventClient.mine().capturesLeft
			line = if left2 == 0 then "Capture limit reached — enjoy the show" else "Capture glowing meteors for bonus matter"
		elseif v.eventId == "SolarStorm" then
			local s = EventClient.mine().surgesLeft
			line = string.format("Energy reactions refund %d%% matter%s", v.attrs.RefundPct or 50, if type(s) == "number" then string.format(" · %d left", s) else "")
		end
		return fmtTime(left) .. "  ·  " .. line, frac
	end
	return outcomeText(v), 0
end

----------------------------------------------------------------------------------------------------
local function rewardLine(r: any): string
	local bits = {}
	if r then
		if (r.credits or 0) > 0 then
			table.insert(bits, string.format("+%s credits", UIData.fmt(r.credits)))
		end
		if (r.energy or 0) > 0 then
			table.insert(bits, string.format("+%s energy", UIData.fmt(r.energy)))
		end
		if (r.xp or 0) > 0 then
			table.insert(bits, string.format("+%s XP", UIData.fmt(r.xp)))
		end
		for _, it in r.items or {} do
			table.insert(bits, string.format("+%d %s", it.amount, it.name))
		end
	end
	return table.concat(bits, "  ·  ")
end

local function showSummary(s: any)
	if type(s) ~= "table" then
		return
	end
	summaryToken += 1
	local token = summaryToken
	local def = EventConfig.get(s.eventId)
	local color = def and def.color or Col.Cyan
	ui.sumCaption.Text = if s.late then "COSMIC EVENT · REWARD WHILE YOU WERE AWAY" else "COSMIC EVENT · RESULTS"
	ui.sumCaption.TextColor3 = color
	local title = string.upper(s.name or "Event")
	if s.eventId == "CosmicConvergence" then
		title ..= if s.outcome == "completed" then " — STABILIZED" else " — PARTIAL"
	end
	ui.sumTitle.Text = title
	local lines = {}
	if s.eventId == "CosmicConvergence" then
		table.insert(lines, string.format("Reactor %d / %d · your contribution %d pts (%d tasks)", s.progress or 0, s.target or 0, s.points or 0, s.tasks or 0))
		if s.eligible then
			table.insert(lines, string.format("Reward share %.0f%% of a fair share%s", (s.share or 0) * 100, if (s.share or 0) >= EventConfig.CONVERGENCE.maxShare then " (maximum)" else ""))
		else
			table.insert(lines, if s.reason == "TOO_LITTLE" then "Finish at least one task to earn a reward next time." elseif s.reason == "NOT_STABILIZED" then "The reactor needed more help — no reward this time." else "No reward this time.")
		end
	elseif s.count then
		table.insert(lines, string.format("%d %s — already added to your inventory", s.count, s.countLabel or ""))
	end
	ui.sumBody.Text = table.concat(lines, "\n")
	local rl = rewardLine(s.rewards)
	ui.sumRewards.Text = if rl ~= "" then rl else "—"
	ui.summary.Visible = true
	UIRoot.sfx("Power_Up", 0.4)
	task.delay(14, function()
		if summaryToken == token then
			ui.summary.Visible = false
		end
	end)
end

local function showIntro(eventId: string)
	local v = EventClient.get(eventId)
	if not v or not v.def then
		return
	end
	introToken += 1
	local token = introToken
	local def = v.def
	ui.introCaption.Text = if v.phase == "incoming" then "COSMIC EVENT INCOMING" else "COSMIC EVENT IN PROGRESS"
	ui.introCaption.TextColor3 = def.color
	ui.introTitle.Text = string.upper(def.name)
	ui.introTag.Text = def.tagline
	ui.introEffect.Text = def.effect
	ui.introEffect.TextColor3 = def.color
	ui.introHow.Text = "• " .. table.concat(def.howTo, "\n• ")
	ui.introEventId = eventId
	ui.intro.Visible = true
	UIRoot.sfx("Whoosh", 0.35)
	task.delay(11, function()
		if introToken == token then
			ui.intro.Visible = false
		end
	end)
end

local function onNotify(msg: any)
	local k = msg.kind
	local def = msg.eventId and EventConfig.get(msg.eventId)
	if k == "incoming" then
		if introShown[msg.eventId] and def then
			UIRoot.toast(string.format("%s incoming — %s", def.name, def.effect), "info", def.icon)
		end
	elseif k == "ended" and def then
		if msg.eventId ~= "CosmicConvergence" then
			UIRoot.toast(def.name .. " has ended.", "info", def.icon)
		end
	elseif k == "surge" then
		UIRoot.toast(string.format("SOLAR SURGE · %s returned %s (%d left)", msg.name or "reaction", rewardLine(msg.gains), msg.left or 0), "reward", "energy")
		UIRoot.sfx("Power_Up", 0.35, 1.2)
	elseif k == "surgeCap" then
		UIRoot.toast("Solar Surge limit reached for this storm.", "warn", "energy")
	elseif k == "task" then
		if msg.task == "calibrate" then
			UIRoot.toast(string.format("Conduit stabilized · +%d stability (you: %d)", msg.points or 0, msg.total or 0), "success", "team")
		elseif msg.task == "assist" then
			UIRoot.toast(string.format("Assist · +%d stability", msg.points or 0), "success", "team")
		elseif msg.task == "deliver" then
			UIRoot.toast(string.format("Flux cell injected · +%d stability (you: %d)", msg.points or 0, msg.total or 0), "success", "energy")
		elseif msg.task == "pickup" then
			UIRoot.toast("Flux cell collected — carry it to the reactor intake.", "info", "energy")
		end
		UIRoot.sfx("Whoosh", 0.3, 1.3)
	elseif k == "sync" then
		UIRoot.toast(string.format("Synchronized with %s! +%d each", msg.with or "an explorer", msg.points or 0), "reward", "team")
	elseif k == "stage" then
		UIRoot.toast(string.format("Reactor stage %d / 3 reached", msg.stage or 0), "success", "team")
	elseif k == "hint" then
		if os.clock() - lastHint > 2 then
			lastHint = os.clock()
			UIRoot.toast(tostring(msg.text), "info")
		end
	elseif k == "summary" then
		showSummary(msg.summary)
	end
end

local function onSocial(msg: any)
	if type(msg) ~= "table" then
		return
	end
	if msg.kind == "visitor" then
		UIRoot.toast(string.format("%s is visiting your planet.", tostring(msg.name)), "info", "planet")
	elseif msg.kind == "reaction" then
		local r = EventConfig.SOCIAL.reactions[msg.reaction]
		UIRoot.toast(string.format("%s reacted “%s” to your planet (%d total)", tostring(msg.name), r and r.label or tostring(msg.reaction), msg.total or 0), "reward", "star")
	elseif msg.kind == "visiting" then
		UIRoot.toast(string.format("Visiting PLANET %02d — %s's world. Press P to inspect or react.", msg.slot or 0, tostring(msg.owner)), "info", "planet")
	end
end

local function onCaptured(ok: boolean, code: string, data: any, m: any)
	if ok and data then
		UIRoot.toast(string.format("%sMeteor captured · %s", if data.rare then "RARE · " else "", rewardLine(data.gains)), if data.rare then "reward" else "success", "matter")
		UIRoot.sfx("Whoosh", 0.4, if data.rare then 0.8 else 1.4)
	elseif code == "CAP_REACHED" then
		UIRoot.toast("You captured the maximum for this shower — more next time!", "warn", "matter")
	elseif code == "OUT_OF_RANGE" then
		UIRoot.toast("Too far — get closer to the meteor.", "info", "matter")
	elseif code == "TAKEN" then
		UIRoot.toast("Another explorer captured that meteor first.", "info", "matter")
	end
end

----------------------------------------------------------------------------------------------------
local function build()
	local hud = UIRoot.layer("Hud")
	-- chips
	ui.chips = C.make("Frame", { Name = "EventChips", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 78), Size = UDim2.fromOffset(640, 50), Visible = false, Parent = hud }, { C.list(Enum.FillDirection.Horizontal, Sp.s, Enum.HorizontalAlignment.Center) })
	ui.chipPool = C.pool(function()
		local b = C.make("TextButton", { Name = "EventChip", Text = "", AutoButtonColor = false, BackgroundColor3 = Col.Panel, BackgroundTransparency = 0.1, Size = UDim2.fromOffset(300, 50), SelectionImageObject = C.selectionImage, Parent = ui.chips }, { C.corner(12) })
		local st = C.stroke(Col.Cyan, 0.35)
		st.Parent = b
		local disc = C.make("Frame", { Name = "Disc", BackgroundColor3 = Col.Navy, Size = UDim2.fromOffset(34, 34), Position = UDim2.fromOffset(8, 8), Parent = b }, { C.corner(17) })
		local discStroke = C.stroke(Col.Cyan, 0.4)
		discStroke.Parent = disc
		local title = C.text({ text = "", size = 13, font = F.Display, parent = b, dims = UDim2.new(1, -60, 0, 16) })
		title.Position = UDim2.fromOffset(50, 7)
		local sub = C.text({ text = "", size = 12, font = F.Semi, color = Col.TextDim, parent = b, dims = UDim2.new(1, -58, 0, 16) })
		sub.Position = UDim2.fromOffset(50, 25)
		local track = C.make("Frame", { Name = "Track", BackgroundColor3 = Col.PanelHi, BorderSizePixel = 0, Position = UDim2.new(0, 50, 1, -6), Size = UDim2.new(1, -62, 0, 2), Parent = b })
		local fill = C.make("Frame", { Name = "Fill", BackgroundColor3 = Col.Cyan, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = track })
		local item: any = { Instance = b, stroke = st, disc = disc, discStroke = discStroke, title = title, sub = sub, fill = fill, icon = nil, iconName = "", eventId = "" }
		b.Activated:Connect(function()
			UIRoot.open("events")
		end)
		C.tooltip(b, function()
			local d = EventConfig.get(item.eventId)
			return d and (d.tagline .. "\n" .. d.effect) or nil
		end)
		return item
	end)

	-- convergence card
	-- bottom centre: close to the action, clear of the Cosmic Core Hunt banner, chips and intro card
	local conv = C.glass({ name = "ConvergenceCard", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 1), pos = UDim2.new(0.5, 0, 1, -16), dims = UDim2.fromOffset(380, 0), parent = hud })
	conv.AutomaticSize = Enum.AutomaticSize.Y
	conv.Visible = false
	local ci = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = conv }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 5) })
	local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 1, Parent = ci })
	local cap = C.caption("Reactor stability", head, 0, EventConfig.FX.palette.convergence)
	cap.Size = UDim2.new(1, -110, 0, 14)
	ui.convStage = C.text({ text = "", size = S.Micro, font = F.Display, color = Col.TextDim, align = Enum.TextXAlignment.Right, parent = head, dims = UDim2.new(0, 110, 0, 14) })
	ui.convStage.AnchorPoint = Vector2.new(1, 0)
	ui.convStage.Position = UDim2.fromScale(1, 0)
	ui.convBar = C.bar({ color = EventConfig.FX.palette.convergence, height = 7, parent = ci, order = 2 })
	ui.convMine = C.text({ text = "", size = S.Small, font = F.Bold, parent = ci, order = 3, autoY = true })
	ui.convMine.RichText = true
	ui.convTop = C.text({ text = "", size = S.Small, color = Col.TextDim, parent = ci, order = 4, autoY = true })
	ui.convTop.RichText = true
	ui.convCarry = C.text({ text = "", size = S.Small, font = F.Bold, color = EventConfig.FX.palette.unstable, parent = ci, order = 5, autoY = true })
	ui.convHint = C.text({ text = "Hold E on flickering conduits · carry flux cells from the plaza rim into the reactor", size = S.Micro, color = Col.TextMute, parent = ci, order = 6, autoY = true })
	ui.conv = conv

	-- intro card (Toast layer: readable even if the player opened a panel)
	local intro = C.glass({ name = "EventIntro", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0), pos = UDim2.new(0.5, 0, 0, 138), dims = UDim2.fromOffset(440, 0), parent = UIRoot.layer("Toast") })
	intro.AutomaticSize = Enum.AutomaticSize.Y
	intro.Visible = false
	local ii = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = intro }, { C.pad(Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
	ui.introCaption = C.caption("Cosmic event", ii, 1, Col.Cyan)
	ui.introTitle = C.text({ text = "", size = 22, font = F.Display, parent = ii, order = 2, dims = UDim2.new(1, 0, 0, 28) })
	ui.introTag = C.text({ text = "", size = S.Body, color = Col.TextDim, parent = ii, order = 3, autoY = true })
	ui.introEffect = C.text({ text = "", size = S.Body, font = F.Bold, parent = ii, order = 4, autoY = true })
	ui.introHow = C.text({ text = "", size = S.Small, color = Col.TextDim, parent = ii, order = 5, autoY = true })
	local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 6, Parent = ii }, { C.list(Enum.FillDirection.Horizontal, Sp.s) })
	C.button({ text = "Details", icon = "info", style = "primary", dims = UDim2.fromOffset(120, 30), parent = row, order = 1, onClick = function()
		intro.Visible = false
		UIRoot.open("events")
	end })
	C.button({ text = "Got it", style = "ghost", dims = UDim2.fromOffset(100, 30), parent = row, order = 2, onClick = function()
		intro.Visible = false
	end })
	ui.intro = intro

	-- reward summary (Toast layer, non-modal)
	local sum = C.glass({ name = "EventSummary", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0), pos = UDim2.new(0.5, 0, 0.26, 0), dims = UDim2.fromOffset(440, 0), parent = UIRoot.layer("Toast") })
	sum.AutomaticSize = Enum.AutomaticSize.Y
	sum.Visible = false
	local si = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = sum }, { C.pad(Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
	ui.sumCaption = C.caption("Cosmic event", si, 1, Col.Cyan)
	ui.sumTitle = C.text({ text = "", size = 20, font = F.Display, parent = si, order = 2, autoY = true })
	ui.sumBody = C.text({ text = "", size = S.Small, color = Col.TextDim, parent = si, order = 3, autoY = true })
	ui.sumRewards = C.text({ text = "", size = S.Body, font = F.Bold, color = Col.Gold, parent = si, order = 4, autoY = true })
	C.button({ text = "Close", style = "ghost", dims = UDim2.fromOffset(100, 30), parent = si, order = 5, onClick = function()
		sum.Visible = false
	end })
	ui.summary = sum
end

local function fillChip(item: any, v: any)
	local def = v.def
	item.eventId = v.eventId
	local color = def and def.color or Col.Cyan
	if item.iconName ~= (def and def.icon or "info") then
		if item.icon then
			item.icon:Destroy()
		end
		item.iconName = def and def.icon or "info"
		item.icon = C.icon(item.iconName, 18, color, item.disc)
		item.icon.AnchorPoint = Vector2.new(0.5, 0.5)
		item.icon.Position = UDim2.fromScale(0.5, 0.5)
	end
	item.stroke.Color = color
	item.discStroke.Color = color
	item.fill.BackgroundColor3 = color
	local prefix = if v.phase == "incoming" then "INCOMING · " elseif v.phase == "ending" then "ENDED · " else ""
	item.title.Text = prefix .. string.upper(v.name)
	local sub, frac = chipInfo(v)
	item.sub.Text = sub
	item.fill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	item.Instance.BackgroundTransparency = if v.phase == "ending" then 0.35 else 0.1
end

-- QA-2026-11-21: the chip row sat at the exact screen centre and covered the planet card on phones (and on
-- tablets with two concurrent events). Keep it clear of the left HUD column and of the right-hand dock; stack the
-- chips beside the column when a row does not fit, or in the bottom-left corner on very narrow canvases.
-- Returns how far the bottom-centre convergence card must lift to stay clear of the chips.
local CHIP_W, CHIP_H, CHIP_Y = 300, 50, 78
local function placeChips(n: number): number
	if n <= 0 then
		return 0
	end
	local size, mode = UIRoot.size(), UIRoot.mode()
	local layout = ui.chips:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	local colRight = Sp.l + (if mode == "short" then 320 else 340) + Sp.s -- matches Hud.layout's column width
	-- the hex dock is a right-hand column except on phones (short), where it runs along the bottom edge
	local rightLimit = size.X - (if mode == "short" then Sp.l else Sp.m + 64 + Sp.s)
	local rowW = n * CHIP_W + (n - 1) * Sp.s
	local stackH = n * CHIP_H + (n - 1) * Sp.s
	if colRight + rowW <= rightLimit then
		layout.FillDirection = Enum.FillDirection.Horizontal
		ui.chips.Size = UDim2.fromOffset(rowW, CHIP_H)
		ui.chips.AnchorPoint = Vector2.new(0.5, 0)
		ui.chips.Position = UDim2.fromOffset(math.max(size.X / 2, colRight + rowW / 2), CHIP_Y)
		return 0
	end
	layout.FillDirection = Enum.FillDirection.Vertical
	ui.chips.Size = UDim2.fromOffset(CHIP_W, stackH)
	if colRight + CHIP_W <= rightLimit then
		ui.chips.AnchorPoint = Vector2.zero
		ui.chips.Position = UDim2.fromOffset(colRight, CHIP_Y)
		return 0
	end
	ui.chips.AnchorPoint = Vector2.new(0, 1)
	ui.chips.Position = UDim2.new(0, Sp.l, 1, -Sp.l)
	return stackH + Sp.s
end

local function refresh()
	local list = EventClient.list()
	ui.chips.Visible = #list > 0
	ui.chipPool:sync(#list, function(item, i)
		fillChip(item, list[i])
	end)
	local lift = placeChips(#list)
	-- convergence card
	local cv = EventClient.get("CosmicConvergence")
	local mine = EventClient.mine()
	local show = cv ~= nil and cv.phase == "active" and (nearStation() or (mine.points or 0) > 0)
	ui.conv.Visible = show
	-- phones (short canvas) carry the hex dock along the bottom edge: sit above it
	ui.conv.Position = UDim2.new(0.5, 0, 1, (if UIRoot.mode() == "short" then -84 else -16) - lift)
	if show and cv then
		local pct = progressPct(cv)
		ui.convBar:set(pct / 100)
		ui.convStage.Text = string.format("STAGE %d / 3 · %d%%", cv.attrs.Stage or 0, pct)
		ui.convMine.Text = string.format("Your contribution: <font color=\"#%s\">%d pts</font>  ·  %d explorer(s) helping", EventConfig.FX.palette.convergence:ToHex(), mine.points or 0, cv.attrs.Participants or 0)
		local top = {}
		for _, pair in string.split(cv.attrs.Top or "", ";") do
			local name, pts = string.match(pair, "^(.*):(%d+)$")
			if name and #top < 3 then
				table.insert(top, string.format("%s <font color=\"#%s\">%s</font>", name, Col.Cyan:ToHex(), pts))
			end
		end
		ui.convTop.Text = if #top > 0 then "Top: " .. table.concat(top, "  ·  ") else "Be the first to stabilize a conduit!"
		local carrying = mine.carrying == true
		ui.convCarry.Visible = carrying
		if carrying then
			ui.convCarry.Text = "Carrying a flux cell — inject it at the reactor (centre of the plaza)"
		end
	end
	-- intro cards: first time each event type is seen this session (deferred inside rifts)
	if not inRift() and not ui.intro.Visible then
		for _, v in list do
			if not introShown[v.eventId] and v.phase ~= "ending" then
				introShown[v.eventId] = true
				showIntro(v.eventId)
				break
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Studio developer strip (F3)
local function devStrip()
	if not RunService:IsStudio() then
		return
	end
	local strip = C.glass({ name = "EventDevStrip", variant = "panel", anchor = Vector2.new(0, 1), pos = UDim2.new(0, Sp.l, 1, -Sp.l), dims = UDim2.fromOffset(620, 46), parent = UIRoot.layer("Overlay") })
	strip.Visible = false
	local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = strip }, { C.pad(7, 10, 7, 10), C.list(Enum.FillDirection.Horizontal, 6, nil, Enum.VerticalAlignment.Center) })
	C.caption("Events dev", row, 0, Col.Magenta).Size = UDim2.fromOffset(78, 14)
	local function dev(payload: { [string]: any })
		task.spawn(function()
			local ok, code = UIData.Profile.request("Event_Dev", payload)
			UIRoot.toast(string.format("Event_Dev %s → %s", tostring(payload.action), tostring(code)), if ok then "success" else "error")
		end)
	end
	for i, id in EventConfig.ORDER do
		local def = EventConfig.get(id)
		C.button({ text = def.name, style = "primary", dims = UDim2.fromOffset(0, 30), size = S.Micro, parent = row, order = i, onClick = function()
			if EventClient.get(id) then
				dev({ action = "stop", eventId = id })
			else
				dev({ action = "start", eventId = id, skipIncoming = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) })
			end
		end })
	end
	C.button({ text = "Test mode", style = "ghost", dims = UDim2.fromOffset(0, 30), size = S.Micro, parent = row, order = 10, onClick = function()
		dev({ action = "testMode", value = not EventClient.testMode() })
	end })
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.F3 then
			strip.Visible = not strip.Visible
		end
	end)
end

function EventHud.init(_deps: any?)
	EventClient.init()
	build()
	devStrip()
	EventClient.Notified:Connect(onNotify)
	EventInteract.Captured:Connect(onCaptured)
	-- phase changes re-render the open panel (e.g. SOLAR SURGE tags in the DNA Lab); timers refresh themselves
	EventClient.PhaseChanged:Connect(function()
		UIRoot.refreshOpen()
	end)
	local remotes = ReplicatedStorage:FindFirstChild("PF_Remotes")
	local sn = remotes and remotes:WaitForChild("Social_Notify", 10) :: RemoteEvent?
	if sn then
		sn.OnClientEvent:Connect(onSocial)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			local ok, err = pcall(refresh)
			if not ok then
				warn("[PF][EventHud] refresh failed: " .. tostring(err))
			end
		end
	end)
	local _ = Motion
end

return EventHud
