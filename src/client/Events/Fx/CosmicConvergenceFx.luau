--!strict
-- CosmicConvergenceFx — DEFAULT (prototype) presentation of the Cosmic Convergence. Developer A: replace with
-- EventFx.register("CosmicConvergence", handler). The server rig (Workspace.PF_Events.PF_Convergence) carries the
-- authoritative state as attributes (conduit PFState, folder PFStage); this handler only adds local polish:
-- flickering unstable conduits, reactor sparks scaled by stage, stage pulses and the completion shockwave.
local Workspace = game:GetService("Workspace")

local Fx = {}

local function rig(): Instance?
	local ev = Workspace:FindFirstChild("PF_Events")
	return ev and ev:FindFirstChild("PF_Convergence")
end

local function column(m: Instance): BasePart?
	local c = m:FindFirstChild("Column")
	if c and c:IsA("BasePart") then
		return c
	end
	local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
	return if pp and pp.Parent and pp.Parent:IsA("BasePart") then pp.Parent else nil
end

local function ring(ctx: any, center: Vector3, color: Color3, size: number, t: number)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.4, 6, 6)
	p.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.2
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = ctx.folder
	ctx.tween(p, t, { Size = Vector3.new(0.2, size, size), Transparency = 1 })
	task.delay(t + 0.05, function()
		p:Destroy()
	end)
end

function Fx.start(ctx: any)
	ctx.data.t = 0
	ctx.data.touched = {} :: { [BasePart]: boolean }
end

function Fx.update(ctx: any, dt: number)
	local r = rig()
	if not r then
		return
	end
	ctx.data.t += dt
	local reduced = ctx.reducedMotion() or ctx.quality == "minimal"
	for _, m in r:GetChildren() do
		local idx = m:GetAttribute("PFConduit")
		if type(idx) == "number" then
			local col = column(m)
			if col then
				if m:GetAttribute("PFState") == "unstable" and not reduced then
					ctx.data.touched[col] = true
					col.Transparency = 0.1 + 0.5 * (0.5 + 0.5 * math.sin(ctx.data.t * 16 + idx * 1.7))
				elseif ctx.data.touched[col] then
					ctx.data.touched[col] = nil
					col.Transparency = 0
				end
			end
		end
	end
	local glow = r:FindFirstChild("ReactorGlow") :: BasePart?
	if glow and not ctx.data.pe and ctx.budget.emitters > 0 then
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "PF_ReactorSparks"
		pe.Shape = Enum.ParticleEmitterShape.Sphere
		pe.Lifetime = NumberRange.new(0.8, 1.4)
		pe.Speed = NumberRange.new(6, 14)
		pe.Size = NumberSequence.new(0.6, 0)
		pe.LightEmission = 1
		pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		pe.Rate = 6
		pe.Parent = glow
		ctx.track(pe)
		ctx.data.pe = pe
	end
	if ctx.data.pe and glow then
		local stage = r:GetAttribute("PFStage") or 0
		ctx.data.pe.Color = ColorSequence.new(glow.Color)
		ctx.data.pe.Rate = if reduced then 4 else 6 + stage * 8
	end
end

function Fx.notify(ctx: any, msg: any)
	local r = rig()
	local glow = r and r:FindFirstChild("ReactorGlow") :: BasePart?
	if not glow or ctx.quality == "minimal" then
		return
	end
	local deck = glow.Position - Vector3.new(0, 27, 0)
	if msg.kind == "stage" and msg.eventId == ctx.eventId then
		ring(ctx, deck, glow.Color, 70, 0.9)
	elseif msg.kind == "ended" and msg.eventId == ctx.eventId and msg.outcome == "completed" then
		ring(ctx, deck, ctx.palette.convergence, 170, 1.6)
		ring(ctx, glow.Position, Color3.new(1, 1, 1), 60, 0.8)
	end
end

function Fx.stop(ctx: any)
	for col in ctx.data.touched or {} do
		if col.Parent then
			col.Transparency = 0
		end
	end
end

return Fx
