--!strict
-- EventsPanel — owner: Live Gameplay (presentation on Developer A's UI kit). "Cosmic Events": what each world
-- event is, whether it is active / incoming, time left, what to do, the player's own counters (captures left,
-- surges left, contribution) and, for the Cosmic Convergence, a player-initiated trip to THE FORGE (never forced).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local Shared = ReplicatedStorage.PF_Shared
local EventConfig = require(Shared.Events.EventConfig)
local WorldLayout = require(Shared.Config.WorldLayout)
local Events = script.Parent.Parent.Parent:WaitForChild("Events")
local EventClient = require(Events:WaitForChild("EventClient"))

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local EventsPanel = {}

function EventsPanel.available(): boolean
	return ReplicatedStorage:FindFirstChild("PF_WorldEvents") ~= nil
end

local function fmtTime(sec: number): string
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function atStation(): boolean
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return r ~= nil and (r.Position - WorldLayout.STATION_CENTER).Magnitude <= 260
end

function EventsPanel.build(shell: any)
	local body: Frame = shell.Body
	local list = C.scroll({ parent = body, gap = Sp.m })
	C.caption("Cosmic events", list, 1, Col.Magenta)
	C.text({ text = "Events appear every few minutes with a 20-second heads-up. They are optional bonuses: rewards you earn are yours even if you leave early, and nobody is ever teleported.", size = S.Small, color = Col.TextDim, autoY = true, parent = list, order = 2 })
	local cards: { [string]: any } = {}
	for i, id in EventConfig.ORDER do
		local def = EventConfig.get(id)
		local card = C.glass({ name = "Event_" .. id, variant = "card", dims = UDim2.new(1, 0, 0, 0), parent = list, order = 10 + i })
		card.AutomaticSize = Enum.AutomaticSize.Y
		local inner = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.pad(Sp.m, Sp.l, Sp.m, Sp.l), C.list(Enum.FillDirection.Vertical, 5) })
		local head = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 1, Parent = inner }, { C.list(Enum.FillDirection.Horizontal, 8, nil, Enum.VerticalAlignment.Center) })
		C.icon(def.icon, 20, def.color, head, 1)
		C.text({ text = string.upper(def.name), size = 16, font = F.Display, parent = head, order = 2, dims = UDim2.new(0, 260, 1, 0) })
		local chip = C.chip("Not active", Col.TextMute, head, 3)
		C.text({ text = def.tagline .. " " .. def.effect, size = S.Small, color = Col.TextDim, autoY = true, parent = inner, order = 2 })
		local how = C.text({ text = "• " .. table.concat(def.howTo, "\n• "), size = S.Small, autoY = true, parent = inner, order = 3 })
		local status = C.text({ text = "", size = S.Small, font = F.Bold, color = def.color, autoY = true, parent = inner, order = 4 })
		status.RichText = true
		local bar = C.bar({ color = def.color, height = 5, parent = inner, order = 5 })
		local action: any = nil
		if id == "CosmicConvergence" then
			action = C.button({ text = "Travel to THE FORGE", icon = "travel", style = "solid", dims = UDim2.fromOffset(240, 34), parent = inner, order = 6, onClick = function()
				UIRoot.close()
				task.spawn(UIData.travel, "station")
			end })
		end
		cards[id] = { card = card, chip = chip, status = status, bar = bar, how = how, action = action }
	end
	C.divider(list, 50)
	C.text({ text = "Cooperative: the Cosmic Convergence and Cosmic Rifts are better together — open the Planets panel (P) to see who is online and visit their worlds.", size = S.Micro, color = Col.TextMute, autoY = true, parent = list, order = 51 })

	local impl: any = {}
	function impl.refresh()
		local t = EventClient.serverNow()
		local mine = EventClient.mine()
		for id, c in cards do
			local v = EventClient.get(id)
			local def = EventConfig.get(id)
			if not v then
				C.setChip(c.chip, "Not active", Col.TextMute)
				c.status.Text = ""
				c.status.Visible = false
				c.bar.Instance.Visible = false
				if c.action then
					c.action.Instance.Visible = false
				end
			else
				c.status.Visible = true
				c.bar.Instance.Visible = v.phase == "active"
				if v.phase == "incoming" then
					C.setChip(c.chip, "Incoming", Col.Warn)
					c.status.Text = "Starts in " .. fmtTime(v.activeAt - t)
				elseif v.phase == "active" then
					C.setChip(c.chip, "Active", Col.Success)
					local left = v.endsAt - t
					c.bar:set(left / math.max(1, v.endsAt - v.activeAt))
					local extra = ""
					if id == "MeteorShower" then
						extra = string.format(" · %s captures left for you · %d captured on this server", tostring(mine.capturesLeft or v.attrs.CapturePerPlayer or "?"), v.attrs.Captured or 0)
					elseif id == "SolarStorm" then
						extra = string.format(" · %s surges left for you · refund %d%%", tostring(mine.surgesLeft or v.attrs.MaxSurges or "?"), v.attrs.RefundPct or 50)
					elseif id == "CosmicConvergence" then
						local pct = math.floor((v.attrs.Progress or 0) / math.max(1, v.attrs.Target or 1) * 100)
						extra = string.format(" · reactor %d%% (stage %d/3) · your contribution %d pts · %d helping", pct, v.attrs.Stage or 0, mine.points or 0, v.attrs.Participants or 0)
					end
					c.status.Text = fmtTime(left) .. " left" .. extra
				else
					C.setChip(c.chip, "Ending", Col.TextMute)
					c.status.Text = if v.outcome == "completed" and id == "CosmicConvergence" then "Reactor stabilized!" else "Wrapping up…"
				end
				if c.action then
					c.action.Instance.Visible = v.phase ~= "ending" and not atStation()
				end
			end
			local _ = def
		end
	end
	local conn: RBXScriptConnection? = nil
	function impl.onOpen()
		impl.refresh()
		local acc = 0
		conn = RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc >= 0.5 then
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
	-- QA I3 (2026-11-22): gamepad focus starts on the panel's only action instead of the Close button
	function impl.firstSelection(): GuiObject?
		local c = cards.CosmicConvergence
		local b = c and c.action
		return if b and b.Instance.Visible then b.Instance else nil
	end
	return impl
end

return EventsPanel
