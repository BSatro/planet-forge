--!strict
-- SolarStormFx — DEFAULT (prototype) presentation of the Solar Storm. Developer A: replace with
-- EventFx.register("SolarStorm", handler). Local only: an orange/violet grade (own ColorCorrectionEffect +
-- Lighting.ColorShift_Top/Bottom and OutdoorAmbient through ctx.setLighting, restored automatically), solar-wind
-- streak particles around the camera (budgeted) and soft flares (skipped with reduced motion). Suspended while
-- the local player is inside a Cosmic Rift.
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Fx = {}
local TINT = Color3.fromRGB(255, 222, 204)
local AMBIENT = Color3.fromRGB(150, 104, 150)
local PROPS = { "ColorShift_Top", "ColorShift_Bottom", "OutdoorAmbient" }

local function stormLighting(ctx: any): { [string]: any }
	return { ColorShift_Top = ctx.palette.stormOrange, ColorShift_Bottom = ctx.palette.stormViolet, OutdoorAmbient = AMBIENT }
end

local function originals(ctx: any): { [string]: any }
	local out = {}
	for _, k in PROPS do
		local v = ctx.original(k)
		if v ~= nil then
			out[k] = v
		end
	end
	return out
end

local function enable(ctx: any)
	if ctx.data.on then
		return
	end
	ctx.data.on = true
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "PF_SolarStormGrade"
	cc.TintColor = Color3.new(1, 1, 1)
	cc.Parent = Lighting
	ctx.track(cc)
	ctx.data.cc = cc
	-- record originals (setting the current values), then fade towards the storm palette
	local now: { [string]: any } = {}
	for _, k in PROPS do
		now[k] = (Lighting :: any)[k]
	end
	ctx.setLighting(now)
	ctx.tween(cc, 3, { TintColor = TINT, Saturation = 0.12, Contrast = 0.05 })
	ctx.tween(Lighting, 3, stormLighting(ctx))
	if ctx.budget.stormRate > 0 then
		local anchor = Instance.new("Part")
		anchor.Name = "SolarWind"
		anchor.Size = Vector3.new(140, 70, 2)
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Parent = ctx.folder
		local pe = Instance.new("ParticleEmitter")
		pe.Shape = Enum.ParticleEmitterShape.Box
		pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		pe.EmissionDirection = Enum.NormalId.Front
		pe.Rate = ctx.budget.stormRate
		pe.Lifetime = NumberRange.new(1.2, 2)
		pe.Speed = NumberRange.new(55, 80)
		pe.SpreadAngle = Vector2.new(6, 6)
		pe.Orientation = Enum.ParticleOrientation.VelocityParallel
		pe.Squash = NumberSequence.new(-2.5)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, 0.35), NumberSequenceKeypoint.new(1, 0) })
		pe.Color = ColorSequence.new(ctx.palette.stormOrange, ctx.palette.stormViolet)
		pe.LightEmission = 1
		pe.Transparency = NumberSequence.new(0.2, 1)
		pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		pe.Parent = anchor
		ctx.data.anchor = anchor
		ctx.data.pe = pe
	end
	ctx.data.nextFlare = os.clock() + 5
	ctx.data.wasRift = false
end

local function fade(ctx: any)
	if not ctx.data.on or ctx.data.fading then
		return
	end
	ctx.data.fading = true
	if ctx.data.cc then
		ctx.tween(ctx.data.cc, 4, { TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0, Brightness = 0 })
	end
	ctx.tween(Lighting, 4, originals(ctx))
	if ctx.data.pe then
		ctx.data.pe.Enabled = false
	end
end

function Fx.start(ctx: any)
	ctx.data.on = false
end

function Fx.phase(ctx: any, phase: string)
	if phase == "active" then
		enable(ctx)
	elseif phase == "ending" then
		fade(ctx)
	end
end

function Fx.update(ctx: any, _dt: number)
	if not ctx.data.on or ctx.data.fading then
		return
	end
	local rift = ctx.inRift()
	if rift ~= ctx.data.wasRift then
		ctx.data.wasRift = rift
		local target = if rift then originals(ctx) else stormLighting(ctx)
		for k, v in target do
			(Lighting :: any)[k] = v
		end
		if ctx.data.cc then
			ctx.data.cc.Enabled = not rift
		end
	end
	local cam = Workspace.CurrentCamera
	if ctx.data.anchor and cam then
		-- the wind blows from the camera's front-left: streaks cross the view diagonally
		local cf = cam.CFrame
		local from = cf.Position + cf.LookVector * 40 - cf.RightVector * 70 + cf.UpVector * 10
		ctx.data.anchor.CFrame = CFrame.lookAt(from, from + cf.RightVector + cf.LookVector * 0.3 - cf.UpVector * 0.15)
		ctx.data.pe.Enabled = not rift
	end
	if ctx.data.cc and not rift and not ctx.reducedMotion() and os.clock() >= ctx.data.nextFlare then
		ctx.data.nextFlare = os.clock() + 6 + math.random() * 5
		ctx.data.cc.Brightness = 0.14
		ctx.tween(ctx.data.cc, 1.6, { Brightness = 0 })
	end
end

function Fx.stop(_ctx: any)
	-- EventFx restores Lighting and destroys tracked instances
end

return Fx
