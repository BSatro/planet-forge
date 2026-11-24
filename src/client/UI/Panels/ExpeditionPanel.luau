--!strict
-- ExpeditionPanel — owner: Developer A (presentation) / Mission Systems (Cosmic Rifts). Expedition briefing:
-- what a Cosmic Rift is, live portal status (lobby / active rifts from the station portal attributes), the way to
-- the portal (travel + world marker, or open the rift when standing at it) and the player's expedition history.
-- Available as soon as the expedition backend exists (Expedition_Start remote).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local UIData = require(script.Parent.Parent.UIData)
local RiftConfig = require(ReplicatedStorage.PF_Shared.Rift.RiftConfig)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Expedition = {}

function Expedition.available(): boolean
	local r = ReplicatedStorage:FindFirstChild("PF_Remotes")
	return r ~= nil and r:FindFirstChild("Expedition_Start") ~= nil
end

local function portal(): BasePart?
	local w = Workspace:FindFirstChild("PF_World")
	local st = w and w:FindFirstChild("Station")
	return st and st:FindFirstChild("RiftSurface", true) :: BasePart?
end

function Expedition.build(shell: any)
	local body: Frame = shell.Body
	local list = C.scroll({ parent = body, gap = Sp.m })
	local ui: any = {}
	C.caption("Cosmic rift", list, 1, Col.Magenta)
	C.text({ text = string.upper(RiftConfig.NAME), size = S.Hero, font = F.Display, parent = list, order = 2, dims = UDim2.new(1, 0, 0, 36) })
	C.text({ text = "A fractured anomaly beyond THE FORGE. Cross shattered asteroids, gather unstable energy fragments, stabilize three nodes in order and seal the rift core before it collapses. 3–5 minutes, solo or with up to 8 explorers — every run is different.", size = S.Body, color = Col.TextDim, autoY = true, parent = list, order = 3 })
	local steps = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = list }, { C.list(Enum.FillDirection.Vertical, 4) })
	for i, t in { "Enter the rift portal on THE FORGE (others can join for 8 seconds)", "Collect energy fragments along the stepping stones", "Stabilize three nodes, then seal the core in the chamber", "Escape through the portal — rewards: credits, energy, XP, catalysts, rare components" } do
		C.text({ text = string.format("%d  ·  %s", i, t), size = S.Small, font = F.Semi, autoY = true, parent = steps, order = i })
	end
	C.divider(list, 5)
	C.caption("Portal status", list, 6)
	ui.status = C.text({ text = "", size = S.Body, font = F.Bold, color = Col.Cyan, autoY = true, parent = list, order = 7 })
	ui.go = C.button({ text = "Go to the rift portal", icon = "travel", style = "solid", dims = UDim2.fromOffset(280, 40), parent = list, order = 8, onClick = function()
		Expedition._go()
	end })
	C.divider(list, 9)
	C.caption("Your expeditions", list, 10)
	ui.history = C.text({ text = "", size = S.Small, color = Col.TextDim, autoY = true, parent = list, order = 11 })

	local function nearPortal(): boolean
		local p = portal()
		local c = Players.LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		return p ~= nil and r ~= nil and (r.Position - p.Position).Magnitude <= RiftConfig.PORTAL_RADIUS
	end

	function Expedition._go()
		if nearPortal() then
			ui.go:setBusy(true)
			task.spawn(function()
				local ok, code = UIData.Profile.request("Expedition_Start", {})
				ui.go:setBusy(false)
				if ok then
					UIRoot.close()
				else
					UIRoot.toast("Rift: " .. tostring(code), "error")
				end
			end)
			return
		end
		local okW, WorldUI = pcall(require, script.Parent.Parent:FindFirstChild("WorldUI") :: ModuleScript)
		local p = portal()
		local c = Players.LocalPlayer.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local atStation = p ~= nil and r ~= nil and (r.Position - p.Position).Magnitude < 200
		UIRoot.close()
		if atStation then
			if okW and WorldUI then
				WorldUI.pointTo("riftPortal")
			end
		else
			task.spawn(function()
				UIData.travel("station")
				task.wait(1)
				if okW and WorldUI then
					WorldUI.pointTo("riftPortal")
				end
			end)
		end
	end

	local impl: any = {}
	function impl.refresh()
		local p = portal()
		local holder = p and p.Parent
		local lobby = holder and holder:GetAttribute("PFRiftLobbyCount") or 0
		local active = holder and holder:GetAttribute("PFRiftActiveRuns") or 0
		ui.status.Text = if lobby > 0 then string.format("A rift is opening now — %d explorer(s) waiting. Join them!", lobby) elseif active > 0 then string.format("%d rift(s) in progress. The portal is ready for a new run.", active) else "The portal is stable and ready."
		ui.go:setText(if nearPortal() then (if lobby > 0 then "Join the rift" else "Open the rift") else "Go to the rift portal")
		local snap = UIData.snapshot()
		local ex = snap and snap.expeditions or {}
		local recent = {}
		for i = #(ex.recent or {}), math.max(1, #(ex.recent or {}) - 4), -1 do
			local r = ex.recent[i]
			if r then
				table.insert(recent, string.format("• %s — %s", if r.expeditionId == RiftConfig.EXPEDITION_ID then RiftConfig.NAME else tostring(r.expeditionId), tostring(r.outcome)))
			end
		end
		ui.history.Text = string.format("%d expedition(s) completed%s", ex.totalCompleted or 0, if #recent > 0 then "\n" .. table.concat(recent, "\n") else "")
	end
	function impl.firstSelection(): GuiObject?
		return ui.go.Instance
	end
	return impl
end

return Expedition
