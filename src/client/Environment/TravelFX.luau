--!strict
-- TravelFX — owner: Developer A. Client presentation of the teleport network.
--   Travel_Transition {phase="out", destination, duration}: cyan flash-to-white + FOV push + destination text
--   Travel_Transition {phase="in"}: fade back in, FOV settles. Failsafe: auto fade-in after 2.5 s.
--   Fx_Play {fxId="warp_depart"|"warp_arrive", position}: expanding ring + sparkle burst + light flash,
--   pooled (max 4 live), only when the camera is within FX_RANGE.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)
local Sfx = require(script.Parent.Parent.Audio.Sfx)

local TravelFX = {}

-- Set by Main: called on arrival while the overlay is still opaque (camera snap + facing reset).
TravelFX.onArrive = nil :: (() -> ())?

local FX_RANGE = 600
local POOL_SIZE = 4
local BASE_FOV = 70

local overlay: Frame? = nil
local caption: TextLabel? = nil
local fadeToken = 0
local pool: { { part: Part, emitter: ParticleEmitter, light: PointLight, busy: boolean } } = {}

local function destinationText(dest: any): string
	if dest == "station" then
		return "WARPING · THE FORGE"
	elseif dest == "rift" then
		return "ENTERING · THE FRACTURED NEBULA"
	elseif dest == "rift_exit" then
		return "RETURNING · THE FORGE"
	elseif typeof(dest) == "number" then
		return string.format("WARPING · PLANET %02d", dest)
	end
	return "WARPING"
end

local function tween(obj: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function fadeIn()
	local o, c = overlay, caption
	if not o or not c then
		return
	end
	tween(o, 0.45, { BackgroundTransparency = 1 })
	tween(c, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 })
	tween(Workspace.CurrentCamera, 0.6, { FieldOfView = BASE_FOV }, Enum.EasingStyle.Sine)
end

local function onTransition(msg: any)
	if typeof(msg) ~= "table" then
		return
	end
	local o, c = overlay, caption
	if not o or not c then
		return
	end
	fadeToken += 1
	local token = fadeToken
	if msg.phase == "out" then
		local d = math.clamp(tonumber(msg.duration) or 0.35, 0.1, 1)
		c.Text = destinationText(msg.destination)
		Sfx.play("Whoosh")
		tween(o, d * 0.9, { BackgroundTransparency = 0 })
		tween(c, d * 0.6, { TextTransparency = 0, TextStrokeTransparency = 0.6 })
		if not Players.LocalPlayer:GetAttribute("PFReducedMotion") then
			tween(Workspace.CurrentCamera, d, { FieldOfView = 92 }, Enum.EasingStyle.Quad)
		end
		task.delay(2.5, function()
			if fadeToken == token then
				fadeIn() -- failsafe if the "in" message never arrives
			end
		end)
	elseif msg.phase == "in" then
		task.wait(0.08) -- let the new root CFrame replicate before re-framing
		if fadeToken == token then
			local cb = TravelFX.onArrive
			if cb then
				local ok, err = pcall(cb)
				if not ok then
					warn("[PF] TravelFX.onArrive failed:", err)
				end
			end
			task.wait(0.05) -- one rendered frame with the new framing behind the overlay
			Sfx.play("Whoosh", { volume = 0.3, pitch = 0.8 })
			fadeIn()
		end
	end
end

local function buildOverlay()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PF_TravelFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Color3.fromRGB(150, 235, 255), Color3.fromRGB(205, 170, 255))
	g.Rotation = 90
	g.Parent = f
	f.Parent = gui
	local t = Instance.new("TextLabel")
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.Position = UDim2.fromScale(0.5, 0.5)
	t.Size = UDim2.fromScale(0.8, 0.08)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(20, 24, 50)
	t.TextTransparency = 1
	t.TextStrokeTransparency = 1
	t.Text = ""
	t.Parent = gui
	local ar = Instance.new("UISizeConstraint")
	ar.MaxSize = Vector2.new(900, 64)
	ar.Parent = t
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	overlay, caption = f, t
end

local function buildPool()
	local fx = Workspace:FindFirstChild("PF_ClientFX") or Instance.new("Folder")
	fx.Name = "PF_ClientFX"
	fx.Parent = Workspace
	for _ = 1, POOL_SIZE do
		local p = Instance.new("Part")
		p.Name = "WarpRing"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = VisualStyle.Color.Cyan
		p.Transparency = 1
		p.Size = Vector3.new(0.2, 1, 1)
		local e = Instance.new("ParticleEmitter")
		e.Texture = VisualStyle.Texture.Sparkle
		e.Rate = 0
		e.LightEmission = 1
		e.Lifetime = NumberRange.new(0.5, 0.9)
		e.Speed = NumberRange.new(10, 22)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
		e.Color = ColorSequence.new(VisualStyle.Color.Cyan, VisualStyle.Color.Violet)
		e.Parent = p
		local l = Instance.new("PointLight")
		l.Color = VisualStyle.Color.Cyan
		l.Range = 24
		l.Brightness = 0
		l.Shadows = false
		l.Parent = p
		p.Parent = fx
		table.insert(pool, { part = p, emitter = e, light = l, busy = false })
	end
end

local function onFx(msg: any)
	if typeof(msg) ~= "table" or typeof(msg.position) ~= "Vector3" then
		return
	end
	if msg.fxId ~= "warp_depart" and msg.fxId ~= "warp_arrive" then
		return
	end
	if (Workspace.CurrentCamera.CFrame.Position - msg.position).Magnitude > FX_RANGE then
		return
	end
	local slot = nil
	for _, s in pool do
		if not s.busy then
			slot = s
			break
		end
	end
	if not slot then
		return -- pool exhausted: skip rather than allocate
	end
	slot.busy = true
	local p = slot.part
	-- orient the ring flat under the character: use the gravity "up" approximated from the nearest body
	local up = Vector3.yAxis
	local planets = Workspace:FindFirstChild("PF_World") and Workspace.PF_World:FindFirstChild("Planets")
	if planets then
		for _, m in planets:GetChildren() do
			local core = m:FindFirstChild("Core")
			if core and core:IsA("BasePart") and (msg.position - core.Position).Magnitude < core.Size.X then
				up = (msg.position - core.Position).Unit
			end
		end
	end
	local base = CFrame.lookAt(msg.position - up * 2.6, msg.position - up * 2.6 + up) * CFrame.Angles(0, math.pi / 2, 0)
	p.CFrame = base
	p.Size = Vector3.new(0.2, 2, 2)
	p.Transparency = 0.1
	p.Color = if msg.fxId == "warp_arrive" then VisualStyle.Color.Cyan else VisualStyle.Color.Violet
	slot.light.Brightness = 3
	slot.emitter:Emit(if msg.fxId == "warp_arrive" then 26 else 16)
	tween(p, 0.6, { Size = Vector3.new(0.2, 16, 16), Transparency = 1 })
	local tw = tween(slot.light, 0.6, { Brightness = 0 })
	tw.Completed:Once(function()
		slot.busy = false
	end)
end

function TravelFX.init()
	buildOverlay()
	buildPool()
	local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 15)
	if not remotes then
		warn("[PF] TravelFX: PF_Remotes missing")
		return
	end
	local tr = remotes:WaitForChild("Travel_Transition", 10) :: RemoteEvent?
	local fx = remotes:WaitForChild("Fx_Play", 10) :: UnreliableRemoteEvent?
	if tr then
		tr.OnClientEvent:Connect(function(msg)
			task.spawn(onTransition, msg)
		end)
	end
	if fx then
		fx.OnClientEvent:Connect(onFx)
	end
end

return TravelFX
