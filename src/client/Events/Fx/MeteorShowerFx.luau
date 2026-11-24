--!strict
-- MeteorShowerFx — DEFAULT (prototype) presentation of the Meteor Shower. Developer A: replace with
-- EventFx.register("MeteorShower", handler) or drop a Model at ReplicatedStorage.PF_Assets.Events.Meteor (PrimaryPart
-- required, PivotTo is used). Draws only the nearest meteors within FX.renderDistance and the quality budget;
-- positions come from ShowerMath (the same path the server validates captures against).
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)
local ShowerMath = require(ReplicatedStorage.PF_Shared.Events.ShowerMath)
local EventClient = require(script.Parent.Parent.EventClient)

local Fx = {}
local ROCK = Color3.fromRGB(58, 46, 44)

local function template(): Model?
	local a = ReplicatedStorage:FindFirstChild("PF_Assets")
	local ev = a and a:FindFirstChild("Events")
	local t = ev and ev:FindFirstChild("Meteor")
	return if t and t:IsA("Model") and t.PrimaryPart then t else nil
end

local function ball(size: number, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one * size
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

local function build(ctx: any, m: ShowerMath.Meteor): (Model, { BasePart }?)
	local tpl = template()
	if tpl then
		local model = tpl:Clone()
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
			end
		end
		model.Parent = ctx.folder
		return model, nil
	end
	local color = if m.rare then ctx.palette.rare else ctx.palette.meteor
	local size = if m.rare then 3.4 else 2.4
	local model = Instance.new("Model")
	model.Name = if m.rare then "RareMeteor" else "Meteor"
	local rock = ball(size, ROCK, Enum.Material.Slate, 0)
	rock.Name = "Rock"
	rock.Parent = model
	local glow = ball(size * 1.5, color, Enum.Material.Neon, 0.5)
	glow.Name = "Glow"
	glow.Parent = model
	if ctx.budget.trails then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, size * 0.35, 0)
		a0.Parent = glow
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -size * 0.35, 0)
		a1.Parent = glow
		local tr = Instance.new("Trail")
		tr.Attachment0 = a0
		tr.Attachment1 = a1
		tr.Lifetime = if m.rare then 1.3 else 0.8
		tr.LightEmission = 1
		tr.FaceCamera = true
		tr.Color = ColorSequence.new(color, Color3.fromRGB(255, 110, 60))
		tr.Transparency = NumberSequence.new(0.15, 1)
		tr.WidthScale = NumberSequence.new(1, 0)
		tr.Parent = glow
	end
	if m.rare and ctx.data.lights < ctx.budget.lights then
		ctx.data.lights += 1
		local l = Instance.new("PointLight")
		l.Range = 16
		l.Brightness = 2
		l.Color = color
		l.Parent = glow
		model:SetAttribute("PFHasLight", true)
	end
	model.PrimaryPart = glow
	model.Parent = ctx.folder
	return model, { rock, glow }
end

local function dispose(ctx: any, e: any)
	if e.model then
		if e.model:GetAttribute("PFHasLight") then
			ctx.data.lights -= 1
		end
		e.model:Destroy()
		e.model, e.parts = nil, nil
	end
end

local function burst(ctx: any, pos: Vector3, color: Color3, big: boolean)
	local p = ball(2, color, Enum.Material.Neon, 0.1)
	p.CFrame = CFrame.new(pos)
	p.Parent = ctx.folder
	ctx.tween(p, 0.45, { Size = Vector3.one * (if big then 16 else 10), Transparency = 1 })
	task.delay(0.5, function()
		p:Destroy()
	end)
end

-- far-away shooting stars (decoration only, never collectible)
local function streak(ctx: any, cam: Camera)
	local cf = cam.CFrame
	local dir = (cf.LookVector + cf.UpVector * (0.35 + math.random() * 0.4) + cf.RightVector * (math.random() - 0.5) * 1.6).Unit
	local start = cf.Position + dir * (320 + math.random() * 160)
	local travel = (cf.RightVector * (if math.random() < 0.5 then -1 else 1) - cf.UpVector * 0.4).Unit * 260
	local p = Instance.new("Part")
	p.Size = Vector3.new(0.6, 0.6, 14)
	p.Material = Enum.Material.Neon
	p.Color = ctx.palette.meteor
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = CFrame.lookAt(start, start + travel)
	p.Parent = ctx.folder
	ctx.tween(p, 1.1, { CFrame = CFrame.lookAt(start + travel, start + travel * 2), Transparency = 1 }, Enum.EasingStyle.Linear)
	task.delay(1.15, function()
		p:Destroy()
	end)
end

function Fx.start(ctx: any)
	ctx.data.entries = {}
	ctx.data.lights = 0
	ctx.data.nextStreak = 0
	for _, m in EventClient.meteors() do
		Fx.meteorAdded(ctx, m)
	end
end

function Fx.meteorAdded(ctx: any, m: ShowerMath.Meteor)
	ctx.data.entries[m.id] = { m = m, model = nil, parts = nil, spin = math.random() * 6 }
end

function Fx.meteorRemoved(ctx: any, id: string, by: number?, pos: Vector3?)
	local e = ctx.data.entries[id]
	ctx.data.entries[id] = nil
	if not e then
		return
	end
	local at = if e.model and e.model.PrimaryPart then e.model.PrimaryPart.Position else pos
	if by and at and ctx.quality ~= "minimal" then
		burst(ctx, at, if e.m.rare then ctx.palette.rare else ctx.palette.meteor, e.m.rare)
	end
	dispose(ctx, e)
end

function Fx.update(ctx: any, dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local t = EventClient.serverNow()
	local camPos = cam.CFrame.Position
	local list = {}
	for _, e in ctx.data.entries do
		local pos = ShowerMath.position(e.m, t)
		local d = (pos - camPos).Magnitude
		if d <= EventConfig.FX.renderDistance and t >= e.m.t0 and not ctx.inRift() then
			table.insert(list, { e = e, d = d, pos = pos })
		else
			dispose(ctx, e)
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local parts, cfs = {}, {}
	for i, it in list do
		local e = it.e
		if i <= ctx.budget.meteors then
			if not e.model then
				e.model, e.parts = build(ctx, e.m)
			end
			local vel = ShowerMath.velocity(e.m, t)
			local look = if vel.Magnitude > 0.01 then CFrame.lookAt(it.pos, it.pos + vel) else CFrame.new(it.pos)
			e.spin += dt * 1.6
			if e.parts then
				table.insert(parts, e.parts[1])
				table.insert(cfs, look * CFrame.Angles(e.spin, e.spin * 0.7, 0))
				table.insert(parts, e.parts[2])
				table.insert(cfs, look)
			else
				e.model:PivotTo(look)
			end
		else
			dispose(ctx, e)
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	local v = ctx.view()
	if v and v.phase == "active" and ctx.quality ~= "minimal" and not ctx.inRift() and os.clock() >= ctx.data.nextStreak then
		ctx.data.nextStreak = os.clock() + (if ctx.quality == "full" then 1.6 else 4) * (0.6 + math.random() * 0.8)
		streak(ctx, cam)
	end
end

function Fx.stop(ctx: any)
	for _, e in ctx.data.entries or {} do
		dispose(ctx, e)
	end
	table.clear(ctx.data.entries or {})
end

return Fx
