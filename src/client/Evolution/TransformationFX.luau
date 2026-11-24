--!strict
-- TransformationFX — owner: Developer B. Client overlay for reaction-level milestones (Planet_Transformation).
-- Developer A's PlanetVisualController already renders the planet itself (formations appear from the
-- published state) and plays the STAGE-UP cinematic; this adds short, themed feedback for every committed
-- milestone (first ocean, eruption, frozen crust, crystal resonance, first life, branch commits...).
--   * full effect within FULL_RANGE of the planet, a cheap flash up to CHEAP_RANGE, nothing beyond
--   * reduced motion (GuiService.ReducedMotionEnabled or PFEffects = "minimal"): single soft flash, no growth
--   * each transformation id plays at most once (never on reconnect: events are not replayed)
--   * a newer effect on the same planet cancels the running one; all parts self-destruct
--   * purely visual: grants nothing, never blocks input
--   * Evolution WOW 2.0: the owner gets a non-blocking "NEW FORMATION UNLOCKED: X" toast with a Skip control
--     (skips the formation-emergence cinematics rendered by Planet/FormationLayer); reduced motion = no slide

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.PF_Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local VisualStyle = require(Shared.Config.VisualStyle)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local PlanetConfig = require(Shared.Config.PlanetConfig)
local EvolutionClient = require(Shared.Client.EvolutionClient)

local TransformationFX = {}

local FULL_RANGE = 900
local CHEAP_RANGE = 2600

local EFFECT_COLORS: { [string]: Color3 } = {
	impact = Color3.fromRGB(200, 240, 255),
	ocean = Color3.fromRGB(60, 160, 255),
	volcanic = Color3.fromRGB(255, 110, 30),
	frozen = Color3.fromRGB(170, 235, 255),
	crystal = Color3.fromRGB(200, 120, 255),
	cosmic = Color3.fromRGB(255, 110, 230),
	living = Color3.fromRGB(110, 255, 130),
	steam = Color3.fromRGB(150, 240, 230),
	stage = Color3.fromRGB(255, 220, 120),
}

local player = Players.LocalPlayer
local seen: { [string]: boolean } = {}
local running: { [number]: { Instance } } = {}
local folder: Folder
local bannerGui: ScreenGui
local bannerTitle: TextLabel
local bannerSub: TextLabel
local played = 0
local toast: Frame
local toastLabel: TextLabel
local toastStroke: UIStroke
local toastToken: any = nil

local function reducedMotion(): boolean
	local ok, v = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return (ok and v == true) or player:GetAttribute("PFEffects") == "minimal" or player:GetAttribute("PFReducedMotion") == true
end

local function cleanup(slot: number)
	for _, i in running[slot] or {} do
		if i.Parent then
			i:Destroy()
		end
	end
	running[slot] = nil
end

local function track(slot: number, i: Instance)
	running[slot] = running[slot] or {}
	table.insert(running[slot], i)
end

local function ball(slot: number, pos: Vector3, size: number, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Material = material
	p.Color = color
	p.Size = Vector3.one * size
	p.CFrame = CFrame.new(pos)
	p.Transparency = transparency
	p.Parent = folder
	track(slot, p)
	return p
end

local bannerToken: any = nil
local function showBanner(title: string, sub: string, color: Color3)
	bannerTitle.Text = title
	bannerTitle.TextColor3 = color
	bannerSub.Text = sub
	bannerTitle.TextTransparency, bannerSub.TextTransparency = 0, 0
	bannerGui.Enabled = true
	local tok = {}
	bannerToken = tok -- (Instances can't hold custom fields; keep the token in a local)
	task.delay(3.2, function()
		if bannerToken ~= tok then
			return
		end
		TweenService:Create(bannerTitle, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		TweenService:Create(bannerSub, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		task.delay(0.7, function()
			if bannerToken == tok then
				bannerGui.Enabled = false
			end
		end)
	end)
end

local function describe(t: any): (string, string, { string })
	if t.kind == "branch" then
		local b = PlanetConfig.BRANCHES[t.branch]
		return string.upper((b and b.displayName) or t.branch), if t.branchFrom and t.branchFrom ~= "None" then "Re-specialized" else "Specialization committed", {}
	end
	local def = t.reactionId and ReactionRegistry.get(t.reactionId)
	local title = string.upper(def and def.name or "TRANSFORMATION")
	local subs = {}
	for _, fid in t.formations or {} do
		local f = FormationRegistry.get(fid)
		table.insert(subs, (f and f.displayName or fid))
	end
	local sub = if def and def.preview and def.preview.headline then def.preview.headline elseif #subs > 0 then ("New: " .. table.concat(subs, ", ")) else ""
	return title, sub, subs
end

-- Non-blocking toast under the banner (only the small Skip button takes input).
local function showToast(names: { string }, color: Color3)
	if #names == 0 or not toast then
		return
	end
	toastLabel.Text = "NEW FORMATION UNLOCKED:  " .. string.upper(table.concat(names, ", "))
	toastStroke.Color = color
	toast.Visible = true
	local tok = {}
	toastToken = tok
	if reducedMotion() then
		toast.Position = UDim2.new(0.5, 0, 0.24, 84)
		toast.BackgroundTransparency = 0.2
	else
		toast.Position = UDim2.new(0.5, 0, 0.24, 64)
		toast.BackgroundTransparency = 1
		TweenService:Create(toast, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 0.24, 84), BackgroundTransparency = 0.2 }):Play()
	end
	task.delay(4.5, function()
		if toastToken == tok then
			toast.Visible = false
		end
	end)
end

local function skipCinematics()
	local ok, ctl = pcall(function()
		return require(script.Parent.Parent.Planet.PlanetVisualController) :: any
	end)
	if ok and ctl and ctl.skipCinematics then
		ctl.skipCinematics()
	end
	if toast then
		toast.Visible = false
	end
end

function TransformationFX.play(msg: any)
	local t = msg.transformation
	if type(t) ~= "table" or type(msg.slot) ~= "number" or not WorldLayout.isValidSlot(msg.slot) then
		return
	end
	local key = tostring(t.id)
	if seen[key] then
		return
	end
	seen[key] = true
	local slot = msg.slot
	local center = WorldLayout.getSlotCenter(slot)
	local R = WorldLayout.PLANET_RADIUS
	local dist = (Workspace.CurrentCamera.CFrame.Position - center).Magnitude
	local color = EFFECT_COLORS[t.effect or ""] or EFFECT_COLORS.stage
	local mine = msg.ownerUserId == player.UserId
	if mine then
		local title, sub, formations = describe(t)
		showBanner(title, sub, color)
		showToast(formations, color)
	end
	if dist > CHEAP_RANGE then
		return
	end
	cleanup(slot)
	played += 1
	local strictReduced = player:GetAttribute("PFReducedMotion") == true or (pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end) and (GuiService :: any).ReducedMotionEnabled == true)
	if strictReduced then
		-- reduced motion (OS or in-game setting): no flash at all; the banner/toast still inform
		return
	end
	if dist > FULL_RANGE or reducedMotion() then
		-- cheap: one soft glow around the planet
		local glow = ball(slot, center, R * 2.1, color, Enum.Material.Neon, 0.75)
		TweenService:Create(glow, TweenInfo.new(0.8), { Transparency = 1 }):Play()
		task.delay(0.9, function()
			cleanup(slot)
		end)
		return
	end
	-- full: energy shell sweeping outward + sparkle bursts at the surface + light flash.
	-- First 10 Minutes 2.0: when the camera is INSIDE the shell (standing on / near the planet) the neon shell would
	-- fill the whole screen (a full-screen flash): keep the sparkle bursts + light, skip the shell and flash balls.
	local inside = dist < R * 1.6
	local shell = if inside then nil else ball(slot, center, R * 2.02, color, Enum.Material.ForceField, 0)
	if shell then
		TweenService:Create(shell, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * R * 2.7, Transparency = 1 }):Play()
	end
	local flash = ball(slot, center, R * 2.05, color, Enum.Material.Neon, if inside then 1 else 0.55)
	TweenService:Create(flash, TweenInfo.new(0.9), { Transparency = 1 }):Play()
	local rng = Random.new(#key * 7919 + slot)
	for _ = 1, 7 do
		local z = rng:NextNumber(-1, 1)
		local a = rng:NextNumber(0, math.pi * 2)
		local r = math.sqrt(1 - z * z)
		local n = Vector3.new(r * math.cos(a), z, r * math.sin(a))
		local anchor = ball(slot, center + n * (R + 2), 0.2, color, Enum.Material.Neon, 1)
		local e = Instance.new("ParticleEmitter")
		e.Texture = VisualStyle.Texture.Sparkle
		e.Color = ColorSequence.new(color)
		e.LightEmission = 1
		e.Rate = 0
		e.Lifetime = NumberRange.new(0.6, 1.3)
		e.Speed = NumberRange.new(6, 16)
		e.SpreadAngle = Vector2.new(60, 60)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		e.Parent = anchor
		e:Emit(22)
	end
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 60
	light.Brightness = 3
	light.Parent = flash
	TweenService:Create(light, TweenInfo.new(1.2), { Brightness = 0 }):Play()
	task.delay(2.2, function()
		cleanup(slot)
	end)
end

function TransformationFX.getStats(): any
	local live = 0
	for _, list in running do
		live += #list
	end
	return { played = played, liveInstances = live }
end

function TransformationFX.init()
	folder = Instance.new("Folder")
	folder.Name = "PF_TransformationFX"
	folder.Parent = Workspace
	bannerGui = Instance.new("ScreenGui")
	bannerGui.Name = "PF_TransformationBanner"
	bannerGui.ResetOnSpawn = false
	bannerGui.IgnoreGuiInset = true
	bannerGui.DisplayOrder = 20 -- below the Planet Lab window (25) so it never covers an open menu
	bannerGui.Enabled = false
	bannerTitle = Instance.new("TextLabel")
	bannerTitle.BackgroundTransparency = 1
	bannerTitle.AnchorPoint = Vector2.new(0.5, 0)
	bannerTitle.Position = UDim2.new(0.5, 0, 0.24, 0)
	bannerTitle.Size = UDim2.new(0.8, 0, 0, 44)
	bannerTitle.Font = Enum.Font.GothamBlack
	bannerTitle.TextScaled = true
	bannerTitle.TextStrokeTransparency = 0.3
	bannerTitle.Parent = bannerGui
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = 40
	c.Parent = bannerTitle
	bannerSub = Instance.new("TextLabel")
	bannerSub.BackgroundTransparency = 1
	bannerSub.AnchorPoint = Vector2.new(0.5, 0)
	bannerSub.Position = UDim2.new(0.5, 0, 0.24, 48)
	bannerSub.Size = UDim2.new(0.8, 0, 0, 24)
	bannerSub.Font = Enum.Font.GothamBold
	bannerSub.TextSize = 18
	bannerSub.TextColor3 = Color3.new(1, 1, 1)
	bannerSub.TextStrokeTransparency = 0.4
	bannerSub.Parent = bannerGui
	-- formation toast: pill with a Skip control
	toast = Instance.new("Frame")
	toast.Name = "FormationToast"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0.24, 84)
	toast.Size = UDim2.fromOffset(0, 36)
	toast.AutomaticSize = Enum.AutomaticSize.X
	toast.BackgroundColor3 = Color3.fromRGB(12, 14, 30)
	toast.BackgroundTransparency = 0.2
	toast.Visible = false
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 18)
	tc.Parent = toast
	toastStroke = Instance.new("UIStroke")
	toastStroke.Thickness = 1.5
	toastStroke.Transparency = 0.2
	toastStroke.Parent = toast
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 16), UDim.new(0, 6)
	pad.Parent = toast
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 12)
	list.Parent = toast
	toastLabel = Instance.new("TextLabel")
	toastLabel.Name = "Text"
	toastLabel.BackgroundTransparency = 1
	toastLabel.Size = UDim2.fromOffset(0, 36)
	toastLabel.AutomaticSize = Enum.AutomaticSize.X
	toastLabel.Font = Enum.Font.GothamBold
	toastLabel.TextSize = 16
	toastLabel.TextColor3 = Color3.fromRGB(235, 245, 255)
	toastLabel.Parent = toast
	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Size = UDim2.fromOffset(64, 26)
	skip.BackgroundColor3 = Color3.fromRGB(45, 70, 110)
	skip.TextColor3 = Color3.new(1, 1, 1)
	skip.Font = Enum.Font.GothamBold
	skip.TextSize = 14
	skip.Text = "SKIP"
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 13)
	sc.Parent = skip
	skip.Activated:Connect(skipCinematics)
	skip.Parent = toast
	toast.Parent = bannerGui
	bannerGui.Parent = player:WaitForChild("PlayerGui")
	EvolutionClient.init()
	EvolutionClient.Transformation:Connect(TransformationFX.play)
end

return TransformationFX
