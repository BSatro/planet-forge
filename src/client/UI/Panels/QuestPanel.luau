--!strict
-- QuestPanel — owner: Live Gameplay (on Developer A's UI kit). Daily + weekly quests (INTERFACES §11):
-- three daily and three weekly cards (title, what to do, progress bar, reward, Claim), reset timers and the
-- daily streak. Reads only the Profile_Snapshot `quests` view; the only request is Quest_Action "claim".
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local QuestConfig = require(ReplicatedStorage.PF_Shared.Quests.QuestConfig)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Quests = {}

function Quests.available(): boolean
	local r = ReplicatedStorage:FindFirstChild("PF_Remotes")
	return r ~= nil and r:FindFirstChild("Quest_Action") ~= nil
end

local function fmtLeft(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d, h, m = sec // 86400, (sec % 86400) // 3600, (sec % 3600) // 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm %02ds", m, sec % 60)
end

function Quests.build(shell: any)
	local body: Frame = shell.Body
	local list = C.scroll({ parent = body, gap = Sp.m })
	local ui: any = { cards = { day = {}, week = {} } }
	local busy = false

	ui.streak = C.text({ text = "", size = S.Body, font = F.Bold, autoY = true, parent = list, order = 2 })
	ui.streak.RichText = true
	C.text({ text = "New quests every day at 00:00 UTC and every Monday. Finished quests you forget to claim are paid out automatically when they reset — nothing is lost.", size = S.Small, color = Col.TextDim, autoY = true, parent = list, order = 3 })

	local function claim(kind: string, index: number)
		if busy then
			return
		end
		busy = true
		local card = ui.cards[kind][index]
		if card then
			card.claim:setBusy(true)
		end
		task.spawn(function()
			local ok, code, data = UIData.Profile.request("Quest_Action", { action = "claim", period = kind, index = index })
			busy = false
			if card then
				card.claim:setBusy(false)
			end
			if ok and type(data) == "table" then
				UIRoot.toast(string.format("Quest reward: +%s credits · +%d XP", UIData.fmt(data.credits), data.xp or 0), "reward")
				UIRoot.sfx("reward")
			else
				UIRoot.toast("Quest: " .. tostring(code), "error")
			end
			UIRoot.refreshOpen()
		end)
	end

	local order = 10
	for _, kind in { "day", "week" } do
		C.divider(list, order)
		local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = order + 1, Parent = list })
		local cap = C.caption(if kind == "day" then "Daily quests" else "Weekly quests", head, 0, if kind == "day" then Col.Cyan else Col.Magenta)
		cap.Size = UDim2.new(1, -160, 0, 16)
		local timer = C.text({ text = "", size = S.Micro, font = F.Display, color = Col.TextDim, align = Enum.TextXAlignment.Right, parent = head, dims = UDim2.new(0, 160, 0, 16) })
		timer.AnchorPoint = Vector2.new(1, 0)
		timer.Position = UDim2.fromScale(1, 0)
		ui[kind .. "Timer"] = timer
		for i = 1, QuestConfig.COUNT[kind] do
			local card = C.glass({ name = "QuestCard", variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = list, order = order + 1 + i })
			card.AutomaticSize = Enum.AutomaticSize.Y
			local inner = C.make("Frame", { Name = "Inner", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 5) })
			local title = C.text({ text = "", size = S.Body, font = F.Bold, autoY = true, parent = inner, order = 1 })
			local detail = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = inner, order = 2 })
			local bar = C.bar({ color = if kind == "day" then Col.Cyan else Col.Magenta, height = 6, parent = inner, order = 3 })
			local row = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 4, Parent = inner })
			local info = C.text({ text = "", size = S.Small, font = F.Semi, parent = row, dims = UDim2.new(1, -150, 1, 0) })
			info.RichText = true
			local k, idx = kind, i
			local btn = C.button({ text = "Claim", icon = "check", style = "solid", dims = UDim2.fromOffset(140, 30), parent = row, onClick = function()
				claim(k, idx)
			end })
			btn.Instance.AnchorPoint = Vector2.new(1, 0.5)
			btn.Instance.Position = UDim2.fromScale(1, 0.5)
			ui.cards[kind][i] = { card = card, title = title, detail = detail, bar = bar, info = info, claim = btn }
		end
		order += 10
	end
	ui.empty = C.text({ text = "Quests are loading…", size = S.Small, color = Col.TextDim, autoY = true, parent = list, order = 4 })

	local impl: any = {}
	local function fill()
		local snap = UIData.snapshot()
		local q = snap and snap.quests
		ui.empty.Visible = q == nil or q.day == nil
		if not q then
			return
		end
		ui.streak.Text = if (q.streak or 0) > 0
			then string.format("Daily streak: <font color=\"#%s\">%d day%s</font>  ·  %d quests completed", Col.Gold:ToHex(), q.streak, if q.streak == 1 then "" else "s", q.claimed or 0)
			else string.format("Claim a daily quest to start a streak  ·  %d quests completed", q.claimed or 0)
		local nowT = workspace:GetServerTimeNow()
		for _, kind in { "day", "week" } do
			local v = q[kind]
			ui[kind .. "Timer"].Text = if v and v.endsAt > 0 then "RESETS IN " .. string.upper(fmtLeft(v.endsAt - nowT)) else ""
			for i, card in ui.cards[kind] do
				local e = v and v.list[i]
				card.card.Visible = e ~= nil
				if e then
					card.title.Text = e.title
					card.detail.Text = e.detail
					card.bar:set(e.progress / math.max(1, e.target))
					card.info.Text = string.format("%s / %s   <font color=\"#%s\">+%s credits · +%d XP</font>", UIData.fmt(e.progress), UIData.fmt(e.target), Col.Gold:ToHex(), UIData.fmt(e.credits), e.xp)
					if e.claimed then
						card.claim:setText("Claimed")
						card.claim:setEnabled(false, "Already claimed")
					elseif e.complete then
						card.claim:setText("Claim")
						card.claim:setEnabled(not busy, "")
					else
						card.claim:setText("In progress")
						card.claim:setEnabled(false, "Finish the quest first")
					end
				end
			end
		end
	end
	impl.refresh = fill
	local open = false
	function impl.onOpen()
		open = true
		task.spawn(function()
			while open do
				pcall(fill) -- timers tick once per second while the panel is open
				task.wait(1)
			end
		end)
	end
	function impl.onClose()
		open = false
	end
	function impl.firstSelection(): GuiObject?
		for _, kind in { "day", "week" } do
			for _, card in ui.cards[kind] do
				if card.card.Visible and card.claim.Instance.Active then
					return card.claim.Instance
				end
			end
		end
		return ui.cards.day[1] and ui.cards.day[1].claim.Instance
	end
	return impl
end

return Quests
