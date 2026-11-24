--!strict
-- EventInteract — owner: Live Gameplay. Client GAMEPLAY input for world events, independent of the replaceable
-- effects (EventFx) so production art can never break interaction:
--   Meteor Shower: the best capturable meteor in range (server range) gets a reticle; F / ButtonR1 captures it, a
--     click or tap captures the meteor under the pointer (screen-space pick). The server validates everything.
--   Cosmic Convergence: the reactor intake prompt is shown only while the local player carries a flux cell;
--     unstable conduits and flux cells get small world markers while the player is at THE FORGE.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.PF_Shared
local EventConfig = require(Shared.Events.EventConfig)
local ShowerMath = require(Shared.Events.ShowerMath)
local WorldLayout = require(Shared.Config.WorldLayout)
local Signal = require(Shared.Util.Signal)
local EventClient = require(script.Parent.EventClient)

local player = Players.LocalPlayer
local EventInteract = {}
EventInteract.Captured = Signal.new() -- (ok, code, data, meteor)

local PICK_PX = 56
local ORANGE = EventConfig.FX.palette.unstable
local CYAN = EventConfig.FX.palette.convergence
local GOLD = EventConfig.FX.palette.rare

local target: ShowerMath.Meteor? = nil
local inFlight: { [string]: boolean } = {}
local anchor: Part = nil :: any
local reticle: BillboardGui = nil :: any
local reticleLabel: TextLabel = nil :: any
local reticleRing: Frame = nil :: any
local bound = false
local markers: { [Instance]: BillboardGui } = {}
local lastScan = 0

local function rootPos(): Vector3?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return r and r.Position
end

local function inRift(): boolean
	return player:GetAttribute("PFInRiftLocal") == true
end

local function bestTarget(t: number): ShowerMath.Meteor?
	local r = rootPos()
	local cam = Workspace.CurrentCamera
	if not r or not cam then
		return nil
	end
	local center = cam.ViewportSize / 2
	local best, bestScore = nil, math.huge
	for _, m in EventClient.meteors() do
		if not inFlight[m.id] and t >= m.t0 then
			local p = ShowerMath.position(m, t)
			local d = (p - r).Magnitude
			if d <= EventConfig.SHOWER.captureRange then
				local sp, onScreen = cam:WorldToViewportPoint(p)
				if onScreen then
					local score = (Vector2.new(sp.X, sp.Y) - center).Magnitude + d * 1.5 - (if m.rare then 80 else 0)
					if score < bestScore then
						best, bestScore = m, score
					end
				end
			end
		end
	end
	return best
end

local function pickAt(screen: Vector2): ShowerMath.Meteor?
	local r = rootPos()
	local cam = Workspace.CurrentCamera
	if not r or not cam then
		return nil
	end
	local t = EventClient.serverNow()
	local inset = game:GetService("GuiService"):GetGuiInset()
	local best, bestPx = nil, PICK_PX
	for _, m in EventClient.meteors() do
		if not inFlight[m.id] and t >= m.t0 then
			local p = ShowerMath.position(m, t)
			if (p - r).Magnitude <= EventConfig.SHOWER.captureRange + 4 then
				local sp, onScreen = cam:WorldToScreenPoint(p)
				if onScreen then
					local px = (Vector2.new(sp.X, sp.Y - inset.Y) - screen).Magnitude
					local px2 = (Vector2.new(sp.X, sp.Y) - screen).Magnitude
					local d = math.min(px, px2)
					if d < bestPx then
						best, bestPx = m, d
					end
				end
			end
		end
	end
	return best
end

function EventInteract.capture(m: ShowerMath.Meteor?)
	if not m or inFlight[m.id] then
		return
	end
	local meteor = m :: ShowerMath.Meteor
	inFlight[meteor.id] = true
	task.spawn(function()
		local ok, code, data = EventClient.capture(meteor.id)
		inFlight[meteor.id] = nil
		EventInteract.Captured:Fire(ok, code, data, meteor)
	end)
end

function EventInteract.target(): ShowerMath.Meteor?
	return target
end

local function setBound(on: boolean)
	if on == bound then
		return
	end
	bound = on
	if on then
		ContextActionService:BindAction("PF_CaptureMeteor", function(_, state)
			if state == Enum.UserInputState.Begin and target then
				EventInteract.capture(target)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.KeyCode.F, Enum.KeyCode.ButtonR1)
	else
		ContextActionService:UnbindAction("PF_CaptureMeteor")
	end
end

local function buildReticle()
	local f = Instance.new("Folder")
	f.Name = "PF_EventInteract"
	f.Parent = Workspace
	anchor = Instance.new("Part")
	anchor.Name = "ReticleAnchor"
	anchor.Size = Vector3.one * 0.2
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Parent = f
	reticle = Instance.new("BillboardGui")
	reticle.Name = "PF_MeteorReticle"
	reticle.ResetOnSpawn = false -- QA-2026-11-21: survived respawns, otherwise destroyed with PlayerGui reset
	reticle.AlwaysOnTop = true
	reticle.Size = UDim2.fromOffset(120, 96)
	reticle.LightInfluence = 0
	reticle.Enabled = false
	reticle.Adornee = anchor
	reticleRing = Instance.new("Frame")
	reticleRing.AnchorPoint = Vector2.new(0.5, 0.5)
	reticleRing.Position = UDim2.fromScale(0.5, 0.36)
	reticleRing.Size = UDim2.fromOffset(44, 44)
	reticleRing.BackgroundTransparency = 1
	reticleRing.Parent = reticle
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = reticleRing
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Thickness = 2
	stroke.Color = EventConfig.FX.palette.meteor
	stroke.Parent = reticleRing
	reticleLabel = Instance.new("TextLabel")
	reticleLabel.AnchorPoint = Vector2.new(0.5, 0)
	reticleLabel.Position = UDim2.new(0.5, 0, 0.36, 28)
	reticleLabel.Size = UDim2.fromOffset(120, 18)
	reticleLabel.BackgroundColor3 = Color3.fromRGB(9, 13, 32)
	reticleLabel.BackgroundTransparency = 0.25
	reticleLabel.TextColor3 = Color3.fromRGB(255, 236, 190)
	reticleLabel.TextSize = 12
	reticleLabel.FontFace = Font.new("rbxasset://fonts/families/TitilliumWeb.json", Enum.FontWeight.Bold)
	reticleLabel.Text = "F · CAPTURE"
	reticleLabel.Parent = reticle
	local lc = Instance.new("UICorner")
	lc.CornerRadius = UDim.new(0, 6)
	lc.Parent = reticleLabel
	reticle.Parent = player:WaitForChild("PlayerGui")
end

-- world markers on the convergence rig ----------------------------------------------------------
local function marker(adornee: BasePart, text: string, color: Color3): BillboardGui
	local b = Instance.new("BillboardGui")
	b.Name = "PF_EventMarker"
	b.ResetOnSpawn = false
	b.AlwaysOnTop = true
	b.Size = UDim2.fromOffset(150, 26)
	b.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	b.MaxDistance = 260
	b.LightInfluence = 0
	b.Adornee = adornee
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundColor3 = Color3.fromRGB(9, 13, 32)
	l.BackgroundTransparency = 0.2
	l.TextColor3 = color
	l.TextSize = 13
	l.FontFace = Font.new("rbxasset://fonts/families/TitilliumWeb.json", Enum.FontWeight.Bold)
	l.Text = text
	l.Parent = b
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = l
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = 0.3
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = l
	b.Parent = player:WaitForChild("PlayerGui")
	return b
end

local function clearMarkers()
	for _, b in markers do
		b:Destroy()
	end
	table.clear(markers)
end

local function scanConvergence()
	local ev = Workspace:FindFirstChild("PF_Events")
	local rig = ev and ev:FindFirstChild("PF_Convergence")
	local active = EventClient.isActive("CosmicConvergence")
	local r = rootPos()
	local atStation = r ~= nil and (r - WorldLayout.STATION_CENTER).Magnitude <= 220 and not inRift()
	if not rig or not active then
		clearMarkers()
		return
	end
	local carrying = player:GetAttribute("PFConvCarrying") == true
	local intake = rig:FindFirstChild("Intake")
	local ip = intake and intake:FindFirstChild("PF_IntakePrompt") :: ProximityPrompt?
	if ip and ip.Enabled ~= carrying then
		ip.Enabled = carrying -- local only: the prompt is meaningful for carriers
	end
	local want: { [Instance]: { part: BasePart, text: string, color: Color3 } } = {}
	if atStation then
		for _, m in rig:GetChildren() do
			if m:GetAttribute("PFConduit") and m:GetAttribute("PFState") == "unstable" then
				local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
				local part = pp and pp.Parent
				if part and part:IsA("BasePart") then
					want[m] = { part = part, text = "UNSTABLE · HOLD E", color = ORANGE }
				end
			elseif m:GetAttribute("PFFluxCell") and not carrying then
				local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
				local part = pp and pp.Parent
				if part and part:IsA("BasePart") then
					want[m] = { part = part, text = "FLUX CELL", color = CYAN }
				end
			end
		end
		if carrying and intake and intake:IsA("BasePart") then
			want[intake] = { part = intake, text = "INJECT · REACTOR", color = CYAN }
		end
	end
	for inst, b in markers do
		if not want[inst] or not inst.Parent or not b.Parent then
			b:Destroy()
			markers[inst] = nil
		end
	end
	for inst, w in want do
		if not markers[inst] then
			markers[inst] = marker(w.part, w.text, w.color)
		end
	end
end

function EventInteract.init()
	buildReticle()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not bound then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			local m = pickAt(Vector2.new(input.Position.X, input.Position.Y))
			if m then
				EventInteract.capture(m)
			end
		end
	end)
	RunService.RenderStepped:Connect(function()
		local active = EventClient.isActive("MeteorShower") and not inRift()
		setBound(active)
		if active then
			local t = EventClient.serverNow()
			target = bestTarget(t)
			if target then
				anchor.CFrame = CFrame.new(ShowerMath.position(target, t))
				local left = EventClient.mine().capturesLeft
				local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
				reticleLabel.Text = if left == 0 then "LIMIT REACHED" elseif touch then "TAP · CAPTURE" elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then "R1 · CAPTURE" else "F · CAPTURE"
				local stroke = reticleRing:FindFirstChild("Stroke") :: UIStroke?
				if stroke then
					stroke.Color = if target.rare then GOLD else EventConfig.FX.palette.meteor
				end
				reticleRing.Rotation = (os.clock() * 90) % 360
			end
			reticle.Enabled = target ~= nil
		else
			target = nil
			reticle.Enabled = false
		end
		local now = os.clock()
		if now - lastScan >= 0.25 then
			lastScan = now
			local ok, err = pcall(scanConvergence)
			if not ok then
				warn("[PF][Events] convergence markers: " .. tostring(err))
			end
		end
	end)
end

return EventInteract
