--!strict
-- RiftHud — owner: Mission Systems (client presentation on Developer A's UI kit). Cosmic Rifts on the client:
--   lobby card (countdown, explorers, Launch now / Leave), mission HUD (objective, channel progress, node pips,
--   fragment pool, timer, secondary objectives, team contributions, Leave), world marker to the current goal,
--   event feedback (toasts + sounds), local nebula colour grade, knockback impulse, reward summary
--   (Run again / Return to my planet). Everything shown comes from the server (Expedition_State / _Event).
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)
local RiftConfig = require(ReplicatedStorage.PF_Shared.Rift.RiftConfig)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local RiftHud = {}
local ui: any = {}
local state: any = nil
local inRun = false
local lastSummary: any = nil
local busy = false

local function WorldUI(): any
	local ok, m = pcall(require, script.Parent:FindFirstChild("WorldUI") :: ModuleScript)
	return if ok then m else nil
end

local function fmtTime(sec: number): string
	sec = math.max(0, math.floor(sec))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function request(remote: string, payload: { [string]: any }): (boolean, string, any)
	local ok, code, data = UIData.Profile.request(remote, payload)
	return ok == true, tostring(code), data
end

----------------------------------------------------------------------------------------------------
-- local nebula grade
local function setGrade(on: boolean)
	local cc = Lighting:FindFirstChild("PF_RiftGrade") :: ColorCorrectionEffect?
	if not cc then
		local n = Instance.new("ColorCorrectionEffect")
		n.Name = "PF_RiftGrade"
		n.TintColor = Color3.fromRGB(214, 196, 255)
		n.Saturation = 0.18
		n.Contrast = 0.08
		n.Enabled = false
		n.Parent = Lighting
		cc = n
	end
	(cc :: ColorCorrectionEffect).Enabled = on
end

----------------------------------------------------------------------------------------------------
local function build()
	local hudLayer = UIRoot.layer("Hud").Parent :: Frame -- Canvas
	-- mission card (own layer frame so hiding the regular HUD does not hide it)
	local layer = C.make("Frame", { Name = "RiftLayer", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = hudLayer })
	layer.ZIndex = 2
	ui.layer = layer
	local card = C.glass({ name = "Mission", variant = "panel", brackets = true, dims = UDim2.fromOffset(340, 0), pos = UDim2.fromOffset(Sp.l, Sp.m), parent = layer })
	card.AutomaticSize = Enum.AutomaticSize.Y
	local inner = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 6) })
	local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 1, Parent = inner })
	local cap = C.caption("Cosmic Rift", head, 0, Col.Magenta)
	cap.Size = UDim2.new(1, -70, 0, 14)
	ui.timer = C.text({ text = "0:00", size = S.Small, font = F.Display, color = Col.Text, align = Enum.TextXAlignment.Right, parent = head, dims = UDim2.new(0, 70, 0, 16) })
	ui.timer.AnchorPoint = Vector2.new(1, 0)
	ui.timer.Position = UDim2.fromScale(1, 0)
	C.text({ text = string.upper(RiftConfig.NAME), size = 15, font = F.Display, parent = inner, order = 2 })
	ui.objective = C.text({ text = "", size = S.Body, font = F.Bold, color = Col.Cyan, autoY = true, parent = inner, order = 3 })
	ui.detail = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = inner, order = 4 })
	ui.progress = C.bar({ color = Col.Magenta, height = 6, parent = inner, order = 5 })
	-- node pips + fragments
	local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 6, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, 6, nil, Enum.VerticalAlignment.Center) })
	ui.pips = {}
	for i = 1, 3 do
		local pip = C.make("Frame", { Name = "Node" .. i, BackgroundColor3 = Col.PanelHi, Size = UDim2.fromOffset(18, 18), Rotation = 45, LayoutOrder = i, Parent = row }, { C.corner(4), C.stroke(Col.Cyan, 0.5) })
		ui.pips[i] = pip
	end
	local coreLabel = C.text({ text = "NODES", size = S.Micro, font = F.Display, color = Col.TextMute, parent = row, order = 4, dims = UDim2.fromOffset(60, 18) })
	coreLabel.Position = UDim2.fromOffset(0, 0)
	C.icon("matter", 14, Col.Cyan, row, 5)
	ui.frags = C.text({ text = "", size = S.Small, font = F.Bold, parent = row, order = 6, dims = UDim2.new(0, 120, 1, 0) })
	ui.frags.RichText = true
	C.divider(inner, 7)
	C.caption("Bonus objectives", inner, 8)
	local secList = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 9, Parent = inner }, { C.list(Enum.FillDirection.Vertical, 3) })
	ui.secPool = C.pool(function()
		local r = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = secList })
		local dot = C.make("Frame", { BackgroundColor3 = Col.TextMute, Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(1, 5), Rotation = 45, Parent = r }, { C.corner(2) })
		local t = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = r })
		t.Size = UDim2.new(1, -18, 0, 0)
		t.Position = UDim2.fromOffset(18, 0)
		t.RichText = true
		return { Instance = r, dot = dot, text = t }
	end)
	ui.teamCap = C.caption("Team", inner, 10)
	local team = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 11, Parent = inner }, { C.list(Enum.FillDirection.Vertical, 2) })
	ui.team = team
	ui.teamPool = C.pool(function()
		local r = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), Parent = team })
		local n = C.text({ text = "", size = S.Small, font = F.Semi, parent = r, dims = UDim2.new(1, -60, 1, 0) })
		local v = C.text({ text = "", size = S.Small, font = F.Bold, color = Col.Cyan, align = Enum.TextXAlignment.Right, parent = r, dims = UDim2.new(0, 60, 1, 0) })
		v.AnchorPoint = Vector2.new(1, 0)
		v.Position = UDim2.fromScale(1, 0)
		return { Instance = r, name = n, value = v }
	end)
	ui.leave = C.button({ text = "Leave rift", icon = "back", style = "ghost", dims = UDim2.new(0, 0, 0, 28), size = S.Micro, parent = inner, order = 12, onClick = function()
		UIRoot.confirm({ title = "Leave the rift?", body = "You return to THE FORGE and forfeit this run's rewards. Your team can continue without you.", confirmText = "Leave", danger = true, onConfirm = function()
			task.spawn(request, "Expedition_Action", { action = "leave" })
		end })
	end })
	ui.leave.Instance.AutomaticSize = Enum.AutomaticSize.X
	-- channel ring (centre-bottom)
	local ch = C.glass({ name = "Channel", variant = "panel", anchor = Vector2.new(0.5, 1), pos = UDim2.new(0.5, 0, 1, -110), dims = UDim2.fromOffset(360, 64), parent = layer })
	ch.Visible = false
	ui.chTitle = C.text({ text = "", size = S.Small, font = F.Display, color = Col.Magenta, align = Enum.TextXAlignment.Center, parent = ch, dims = UDim2.new(1, 0, 0, 20) })
	ui.chTitle.Position = UDim2.fromOffset(0, 10)
	ui.chBar = C.bar({ color = Col.Magenta, height = 8, parent = ch })
	ui.chBar.Instance.Position = UDim2.new(0, 20, 0, 40)
	ui.chBar.Instance.Size = UDim2.new(1, -40, 0, 8)
	ui.channel = ch

	-- lobby card (top centre, below the Roblox top bar)
	local lobby = C.glass({ name = "RiftLobby", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0), pos = UDim2.new(0.5, 0, 0, 140), dims = UDim2.fromOffset(420, 0), parent = UIRoot.layer("Toast") })
	lobby.AutomaticSize = Enum.AutomaticSize.Y
	lobby.Visible = false
	local li = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = lobby }, { C.pad(Sp.l), C.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center) })
	C.caption("Cosmic rift opening", li, 1, Col.Magenta).TextXAlignment = Enum.TextXAlignment.Center
	ui.lobbyTitle = C.text({ text = "", size = 22, font = F.Display, align = Enum.TextXAlignment.Center, parent = li, order = 2, dims = UDim2.new(1, 0, 0, 30) })
	ui.lobbyMembers = C.text({ text = "", size = S.Small, color = Col.TextDim, align = Enum.TextXAlignment.Center, autoY = true, parent = li, order = 3 })
	local br = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 4, Parent = li }, { C.list(Enum.FillDirection.Horizontal, Sp.s, Enum.HorizontalAlignment.Center) })
	ui.lobbyLeave = C.button({ text = "Leave", style = "ghost", parent = br, order = 1, onClick = function()
		task.spawn(request, "Expedition_Action", { action = "leave" })
	end })
	ui.lobbyLaunch = C.button({ text = "Launch now", icon = "travel", style = "solid", parent = br, order = 2, onClick = function()
		task.spawn(request, "Expedition_Action", { action = "launch" })
	end })
	ui.lobby = lobby

	-- summary modal
	local sumRoot = C.make("Frame", { Name = "RiftSummary", BackgroundColor3 = Col.Void, BackgroundTransparency = 0.3, Size = UDim2.fromScale(1, 1), Visible = false, Active = true, Parent = UIRoot.layer("Modal") })
	local sc = C.glass({ name = "Card", variant = "panel", brackets = true, anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5), dims = UDim2.fromOffset(520, 0), parent = sumRoot })
	sc.AutomaticSize = Enum.AutomaticSize.Y
	local si = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = sc }, { C.pad(Sp.xl), C.list(Enum.FillDirection.Vertical, Sp.s, Enum.HorizontalAlignment.Center) })
	ui.sKicker = C.text({ text = "", size = S.Small, font = F.Display, color = Col.Magenta, align = Enum.TextXAlignment.Center, parent = si, order = 1 })
	ui.sTitle = C.text({ text = "", size = 24, font = F.Display, align = Enum.TextXAlignment.Center, parent = si, order = 2, dims = UDim2.new(1, 0, 0, 32) })
	ui.sStats = C.text({ text = "", size = S.Small, color = Col.TextDim, align = Enum.TextXAlignment.Center, autoY = true, parent = si, order = 3 })
	ui.sStats.RichText = true
	C.divider(si, 4)
	ui.sSec = C.text({ text = "", size = S.Small, align = Enum.TextXAlignment.Center, autoY = true, parent = si, order = 5 })
	ui.sSec.RichText = true
	C.caption("Rewards", si, 6).TextXAlignment = Enum.TextXAlignment.Center
	ui.sRewards = C.text({ text = "", size = S.Heading, font = F.Bold, color = Col.Gold, align = Enum.TextXAlignment.Center, autoY = true, parent = si, order = 7 })
	ui.sLines = C.text({ text = "", size = S.Small, color = Col.TextDim, align = Enum.TextXAlignment.Center, autoY = true, parent = si, order = 8 })
	local sb = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 9, Parent = si }, { C.list(Enum.FillDirection.Horizontal, Sp.s, Enum.HorizontalAlignment.Center) })
	ui.sClose = C.button({ text = "Close", style = "ghost", parent = sb, order = 1, onClick = function()
		sumRoot.Visible = false
		UIRoot.setHudHidden("riftSummary", false)
	end })
	ui.sHome = C.button({ text = "My planet", icon = "planet", style = "primary", parent = sb, order = 2, onClick = function()
		sumRoot.Visible = false
		UIRoot.setHudHidden("riftSummary", false)
		task.spawn(request, "Expedition_Action", { action = "home" })
	end })
	ui.sAgain = C.button({ text = "Run again", icon = "expedition", style = "solid", parent = sb, order = 3, onClick = function()
		if busy then
			return
		end
		busy = true
		task.spawn(function()
			local ok, code = request("Expedition_Action", { action = "restart" })
			busy = false
			if ok then
				sumRoot.Visible = false
				UIRoot.setHudHidden("riftSummary", false)
			else
				UIRoot.toast("Could not restart: " .. code, "error")
			end
		end)
	end })
	ui.summary = sumRoot
end

----------------------------------------------------------------------------------------------------
local function objectiveFor(st: any): (string, string, number?)
	if st.phase == "active" then
		if st.pool < st.cost then
			return string.format("Collect energy fragments  %d / %d", st.pool, st.cost), string.format("Node %d needs %d fragments. Follow the stepping stones — mind crumbling rock and sweeping beams.", st.nodeIndex, st.cost), st.pool / math.max(1, st.cost)
		end
		return string.format("Stabilize node %d of 3", st.nodeIndex), "Stand inside the glowing node ring. More explorers inside = faster.", st.nodeProgress
	elseif st.phase == "final" then
		return "Seal the rift core", "Hold the stabilization chamber. Jump over the sweeping beams!", st.finalProgress
	elseif st.phase == "escape" then
		return string.format("Escape the rift  %ds", math.ceil(st.escapeLeft or 0)), "The rift is sealed — enter the portal in the chamber.", nil
	end
	return "", "", nil
end

local function render()
	local st = state
	if not st or not ui.layer then
		return
	end
	if st.phase == "forming" then
		ui.lobby.Visible = true
		local left = math.max(0, math.ceil((st.endsAt or 0) - Workspace:GetServerTimeNow()))
		ui.lobbyTitle.Text = string.format("LAUNCH IN %ds", left)
		ui.lobbyMembers.Text = string.format("%s\n%d / %d explorers · others can still step in", table.concat(st.members or {}, " · "), #(st.members or {}), st.max or 8)
		return
	end
	ui.lobby.Visible = false
	if st.phase == "ended" then
		return
	end
	local title, detail, prog = objectiveFor(st)
	ui.objective.Text = title
	ui.detail.Text = detail
	ui.progress.Instance.Visible = prog ~= nil
	if prog then
		ui.progress:set(prog)
	end
	ui.timer.Text = fmtTime(st.timeLeft or 0)
	ui.timer.TextColor3 = if (st.timeLeft or 0) < 60 then Col.Danger else Col.Text
	for i, pip in ui.pips do
		pip.BackgroundColor3 = if i <= st.nodesDone then Col.Cyan elseif i == st.nodeIndex and st.phase == "active" then Col.Magenta else Col.PanelHi
	end
	ui.frags.Text = string.format("%d <font color=\"#%s\">pool</font>  ·  %d/%d", st.pool, Col.TextMute:ToHex(), st.collected, st.total)
	ui.secPool:sync(#st.secondaries, function(item, i)
		local s = st.secondaries[i]
		local color = if s.state == "done" then Col.Success elseif s.state == "failed" then Col.Danger else Col.TextMute
		item.dot.BackgroundColor3 = color
		item.text.Text = string.format("<b>%s</b> — %s", s.name, s.text)
		item.text.TextColor3 = if s.state == "pending" then Col.TextDim else color
	end)
	local multi = (st.players or 1) > 1
	ui.teamCap.Visible = multi
	ui.team.Visible = multi
	if multi then
		ui.teamPool:sync(#st.team, function(item, i)
			local m = st.team[i]
			item.name.Text = m.name .. (if m.escaped then "  ✓" else "")
			item.value.Text = string.format("%d ◆", m.fragments)
		end)
	end
	-- channel ring
	local channeling = (st.phase == "active" and st.pool >= st.cost and st.nodeProgress > 0.01) or (st.phase == "final" and st.finalProgress > 0.01)
	ui.channel.Visible = channeling
	if channeling then
		ui.chTitle.Text = if st.phase == "final" then string.format("SEALING THE CORE · %d%%", math.floor(st.finalProgress * 100)) else string.format("STABILIZING NODE %d · %d%%", st.nodeIndex, math.floor(st.nodeProgress * 100))
		ui.chBar:set(if st.phase == "final" then st.finalProgress else st.nodeProgress)
	end
	-- world marker
	local w = WorldUI()
	if w then
		if st.phase == "active" and st.pool >= st.cost and st.nodes[st.nodeIndex] then
			w.pointAt(st.nodes[st.nodeIndex].pos + Vector3.new(0, 18, 0), "NODE " .. st.nodeIndex)
		elseif st.phase == "active" and st.nodes[st.nodeIndex] then
			w.pointAt(st.nodes[st.nodeIndex].pos + Vector3.new(0, 18, 0), "NODE " .. st.nodeIndex .. " (need fragments)")
		elseif st.phase == "final" then
			w.pointAt(st.chamber + Vector3.new(0, 24, 0), "STABILIZATION CHAMBER")
		elseif st.phase == "escape" then
			w.pointAt(st.chamber + Vector3.new(0, 18, 0), "EXIT PORTAL")
		end
	end
end

local function enterRun(on: boolean)
	if inRun == on then
		return
	end
	inRun = on
	player:SetAttribute("PFInRiftLocal", on) -- local flag for world-event effects (suspended inside a rift)
	ui.layer.Visible = on
	UIRoot.setHudHidden("rift", on)
	setGrade(on)
	-- the Cosmic Core Hunt walking hint is about planets; hide it locally while inside the rift
	local hint = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("PF_HarvestHint") :: ScreenGui?
	if hint then
		if on then
			hint:SetAttribute("PFRiftWasEnabled", hint.Enabled)
			hint.Enabled = false
		elseif hint:GetAttribute("PFRiftWasEnabled") ~= nil then
			hint.Enabled = hint:GetAttribute("PFRiftWasEnabled") == true
			hint:SetAttribute("PFRiftWasEnabled", nil)
		end
	end
	if on then
		UIRoot.close()
		ui.summary.Visible = false
		UIRoot.setHudHidden("riftSummary", false)
	else
		local w = WorldUI()
		if w then
			w.clear()
		end
		ui.channel.Visible = false
	end
end

local function showSummary(sum: any)
	lastSummary = sum
	local completed = sum.outcome == "completed"
	ui.sKicker.Text = if completed then "EXPEDITION COMPLETE" elseif sum.outcome == "failed" then "THE RIFT COLLAPSED" else "EXPEDITION ENDED"
	ui.sTitle.Text = if completed then "RIFT STABILIZED" else string.upper(RiftConfig.NAME)
	ui.sStats.Text = string.format("Time <b>%s</b>   ·   Nodes <b>%d/3</b>   ·   Fragments <b>%d/%d</b>   ·   Explorers <b>%d</b>", fmtTime(sum.elapsed or 0), sum.nodesDone or 0, sum.collected or 0, sum.total or 0, sum.players or 1)
	local secs = {}
	for _, s in sum.secondaries or {} do
		local color = if s.state == "done" then Col.Success else Col.Danger
		table.insert(secs, string.format("<font color=\"#%s\">%s %s</font>", color:ToHex(), if s.state == "done" then "✓" else "✗", s.name))
	end
	ui.sSec.Text = table.concat(secs, "     ")
	local rw = sum.rewards or {}
	local bits = {}
	if sum.eligible then
		if (rw.credits or 0) > 0 then table.insert(bits, "+" .. UIData.fmt(rw.credits) .. " credits") end
		if (rw.energy or 0) > 0 then table.insert(bits, "+" .. rw.energy .. " energy") end
		if (rw.xp or 0) > 0 then table.insert(bits, "+" .. rw.xp .. " XP") end
		for _, it in rw.items or {} do
			table.insert(bits, string.format("+%d %s", it.amount, it.name))
		end
	end
	ui.sRewards.Text = if #bits > 0 then table.concat(bits, "   ·   ") else (if sum.reason == "NOT_ENOUGH_PARTICIPATION" then "No reward — you joined too briefly to contribute." else "No reward this time.")
	ui.sLines.Text = table.concat(sum.lines or {}, "  ·  ")
	ui.summary.Visible = true
	UIRoot.setHudHidden("riftSummary", true)
	if UIRoot.isGamepad() then
		GuiService.SelectedObject = ui.sAgain.Instance
	end
	if completed then
		UIRoot.sfx("Power_Up", 0.6, 1)
	end
end

local FEEDBACK: { [string]: (any) -> () } = {
	fragment = function(e)
		if e.userId == player.UserId then
			UIRoot.sfx("Whoosh", 0.12, 1.8)
		end
	end,
	node_done = function(e)
		UIRoot.toast(string.format("NODE %d STABILIZED — checkpoint saved", e.node), "success")
		UIRoot.sfx("Power_Up", 0.45, 1.15)
	end,
	final_open = function()
		UIRoot.toast("All nodes online — the stabilization chamber is open!", "reward")
	end,
	core_sealed = function()
		UIRoot.toast("RIFT CORE SEALED — escape through the portal!", "reward")
		UIRoot.sfx("Transformation", 0.6, 1)
	end,
	fall = function(e)
		if e.userId == player.UserId then
			UIRoot.toast("Lost in the void — returned to the last checkpoint", "warn")
		end
	end,
	need_fragments = function(e)
		UIRoot.toast(string.format("This node needs %d more fragment(s)", e.need), "warn")
	end,
	secondary_done = function(e)
		local d = RiftConfig.SECONDARIES[e.id]
		UIRoot.toast("BONUS COMPLETE: " .. (d and d.name or e.id), "reward")
	end,
	secondary_failed = function(e)
		local d = RiftConfig.SECONDARIES[e.id]
		UIRoot.toast("Bonus failed: " .. (d and d.name or e.id), "error")
	end,
	knockback = function(e)
		local c = player.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and typeof(e.dir) == "Vector3" then
			r.AssemblyLinearVelocity = e.dir * (e.power or 60) + Vector3.new(0, 38, 0)
		end
	end,
	summary = function(e)
		task.delay(0.6, function()
			showSummary(e.summary)
		end)
	end,
	detached = function(e)
		enterRun(false)
		ui.lobby.Visible = false
		state = nil
		if e.reason == "removed_movement" then
			UIRoot.toast("Removed from the rift: invalid movement detected", "error")
		elseif e.reason == "left_arena" then
			UIRoot.toast("You left the rift", "warn")
		end
	end,
	error = function(e)
		local map = { OUT_OF_RANGE = "Step closer to the rift portal.", BUSY = "All rifts are busy — try again shortly.", LOBBY_FULL = "This rift is full.", ALREADY_ACTIVE = "You are already on an expedition.", NOT_READY = "Still loading your profile..." }
		UIRoot.toast(map[e.text] or e.text or "Rift unavailable", "error")
	end,
	left = function(e)
		if e.userId ~= player.UserId then
			UIRoot.toast("An explorer left the rift", "info")
		end
	end,
}

function RiftHud.init()
	build()
	local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 20)
	if not remotes then
		return
	end
	local stateRemote = remotes:WaitForChild("Expedition_State", 20) :: RemoteEvent?
	local eventRemote = remotes:WaitForChild("Expedition_Event", 20) :: RemoteEvent?
	if not stateRemote or not eventRemote then
		return
	end
	stateRemote.OnClientEvent:Connect(function(st: any)
		if typeof(st) ~= "table" then
			return
		end
		state = st
		if st.phase == "forming" then
			enterRun(false)
		elseif st.phase ~= "ended" then
			enterRun(true)
		end
		render()
	end)
	eventRemote.OnClientEvent:Connect(function(e: any)
		if typeof(e) ~= "table" then
			return
		end
		local fn = FEEDBACK[e.kind]
		if fn then
			fn(e)
		end
	end)
	-- local countdown smoothing between server updates
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 or not state then
			return
		end
		acc = 0
		if state.phase == "forming" then
			render()
		elseif inRun and state.timeLeft then
			state.timeLeft = math.max(0, state.timeLeft - 0.25)
			if state.escapeLeft then
				state.escapeLeft = math.max(0, state.escapeLeft - 0.25)
			end
			ui.timer.Text = fmtTime(state.timeLeft)
		end
	end)
	player.CharacterAdded:Connect(function()
		if inRun then
			setGrade(true)
		end
	end)
end

function RiftHud.lastSummary(): any
	return lastSummary
end

return RiftHud
