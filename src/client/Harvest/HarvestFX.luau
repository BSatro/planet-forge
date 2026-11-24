--!strict
-- HarvestFX — owner: Gameplay / Technical Art (VFX). Client-only harvester effects (seen by the operator):
--   charge build-up at the muzzle, muzzle flash, gravity beam + pulse, 3D lock ring, impact families per
--   meteor kind, stasis bubble, capture tether, absorption swirl at the collector, perfect-capture
--   celebration, miss fizzle, reload / READY states on the harvester's own muzzle crystal + coil rings.
-- Performance: transient parts come from a bounded pool (MAX_IDLE idle, everything returned after its effect),
-- particle counts scale with the PFEffects preset, no effect outlives ~1.6 s, and the only per-frame
-- connections are the single pulse in flight and the stasis bubble (both one at a time by design).
-- Reduced motion: no pulsing, no flying rays / light columns, static lock ring, gentler bursts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)
local ItemCatalog = require(ReplicatedStorage.PF_Shared.Config.ItemCatalog)
local Styles = require(script.Parent.MeteorStyles)

local HarvestFX = {}
local TEX = Styles.TEXTURE
local TAU = math.pi * 2
local rgb = Color3.fromRGB

-- Cosmetic style (Harvester VFX Bundle / equipped HarvesterFX cosmetic). nil = default look.
-- Only the BEAM (charge, muzzle flash, pulse) and the CAPTURE flourish change colour; meteor-kind colours
-- (tether, stasis, impacts) are kept so the gameplay information is identical for every style.
local style: { id: string, beam: Color3, capture: Color3 }? = nil

function HarvestFX.setStyle(cosmeticId: string?)
	local e = if type(cosmeticId) == "string" then ItemCatalog.COSMETICS[cosmeticId] else nil
	style = if e and e.category == "HarvesterFX" then { id = cosmeticId :: string, beam = e.color, capture = e.color2 or e.color } else nil
end

function HarvestFX.getStyle(): string?
	return style and style.id
end

local container: Instance = Workspace

function HarvestFX.setContainer(c: Instance)
	container = c
end

---------------------------------------------------------------- bounded part pool

local MAX_IDLE = 48
local idle: { Part } = {}
local live = 0
local tweensOf: { [Part]: { Tween } } = setmetatable({}, { __mode = "k" }) :: any

local function acquire(props: { [string]: any }): Part
	local p = table.remove(idle)
	if not p then
		p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
	end
	p.Name = "FX"
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Reflectance = 0
	p.Transparency = 0
	p.Color = Color3.new(1, 1, 1)
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = container
	live += 1
	return p
end

local function release(p: Part)
	if not p or p.Parent == nil and table.find(idle, p) then
		return
	end
	local tws = tweensOf[p]
	if tws then
		for _, tw in tws do
			tw:Cancel()
		end
		tweensOf[p] = nil
	end
	p:ClearAllChildren()
	p.Parent = nil
	live = math.max(0, live - 1)
	if #idle < MAX_IDLE then
		table.insert(idle, p)
	else
		p:Destroy()
	end
end

local function releaseAfter(p: Part, t: number)
	task.delay(t, release, p)
end

local function tween(inst: Instance, t: number, goal: { [string]: any }, easing: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, easing or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), goal)
	if inst:IsA("Part") then
		local list = tweensOf[inst] or {}
		table.insert(list, tw)
		tweensOf[inst] = list
	end
	tw:Play()
	return tw
end

local function seq(a: number, b: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

local function camPos(): Vector3
	local c = Workspace.CurrentCamera
	return if c then c.CFrame.Position else Vector3.zero
end

-- a flat ring (cylinder) at pos facing the camera
local function faceRing(pos: Vector3, d: number, thick: number, color: Color3, transparency: number): Part
	local cf = CFrame.lookAt(pos, camPos()) * CFrame.Angles(0, math.pi / 2, 0)
	return acquire({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(thick, d, d), CFrame = cf, Color = color, Transparency = transparency })
end

function HarvestFX.stats(): { live: number, idle: number }
	return { live = live, idle = #idle }
end

---------------------------------------------------------------- particles

local function burst(pos: Vector3, color: any, count: number, speed: number, size: number, texture: string?, opts: any?)
	local o = opts or {}
	local n = math.max(1, math.floor(count * Styles.quality().burst + 0.5))
	local anchor = acquire({ Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(pos) })
	local e = Instance.new("ParticleEmitter")
	e.Texture = texture or TEX.sparkle
	e.Color = if typeof(color) == "ColorSequence" then color else ColorSequence.new(color)
	e.LightEmission = o.lightEmission or 1
	e.Rate = 0
	e.Lifetime = o.lifetime or NumberRange.new(0.4, 0.9)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = o.size or seq(size, 0)
	e.Transparency = o.transparency or seq(0, 1)
	e.Drag = o.drag or 3
	e.Acceleration = o.acceleration or Vector3.zero
	e.RotSpeed = o.rotSpeed or NumberRange.new(0)
	if o.inward then
		e.Shape = Enum.ParticleEmitterShape.Sphere
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
		anchor.Size = Vector3.one * (o.inwardRadius or 6)
	end
	e.Parent = anchor
	e:Emit(n)
	releaseAfter(anchor, o.hold or 1.6)
end
HarvestFX.burst = burst

-- short-lived physical shards flying out (ice / crystal / rock)
local function shards(pos: Vector3, color: Color3, material: Enum.Material, count: number, size: number, dist: number)
	local rng = Random.new()
	for _ = 1, math.max(1, math.floor(count * Styles.quality().burst + 0.5)) do
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.yAxis
		local p = acquire({ Shape = Enum.PartType.Block, Material = material, Color = color, Size = Vector3.new(size * 0.4, size, size * 0.4), CFrame = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(math.pi / 2, 0, 0) })
		tween(p, 0.45, { CFrame = CFrame.new(pos + dir * dist) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0), Transparency = 1, Size = p.Size * 0.4 })
		releaseAfter(p, 0.5)
	end
end

-- transient electric arcs from pos to random points (electric impacts)
local function zaps(pos: Vector3, c0: Color3, c1: Color3, count: number, reach: number)
	local rng = Random.new()
	local anchor = acquire({ Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(pos) })
	for _ = 1, count do
		local a0 = Instance.new("Attachment")
		a0.Parent = anchor
		local a1 = Instance.new("Attachment")
		local d = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		a1.Position = (if d.Magnitude > 1e-3 then d.Unit else Vector3.xAxis) * reach * rng:NextNumber(0.6, 1)
		a1.Parent = anchor
		local b = Instance.new("Beam")
		b.Attachment0 = a0
		b.Attachment1 = a1
		b.Color = ColorSequence.new(c0, c1)
		b.LightEmission = 1
		b.LightInfluence = 0
		b.FaceCamera = true
		b.Width0 = 0.5
		b.Width1 = 0.1
		b.Segments = 10
		b.CurveSize0 = rng:NextNumber(-1, 1) * reach * 0.6
		b.CurveSize1 = rng:NextNumber(-1, 1) * reach * 0.6
		b.Texture = TEX.sparkle
		b.TextureSpeed = 6
		b.Parent = anchor
	end
	releaseAfter(anchor, 0.2)
end

---------------------------------------------------------------- charge, muzzle, pulse

-- Charge build-up at the muzzle. getPos() is read every :set so it follows the turret.
-- handle:set(frac 0..1)  handle:release()  handle:cancel()
function HarvestFX.chargeBegin(getPos: () -> Vector3, accent: Color3): any
	local color = if style then style.beam else accent
	local calm = Styles.reducedMotion()
	local Q = Styles.quality()
	local pos = getPos()
	local orb = acquire({ Size = Vector3.one * 0.3, CFrame = CFrame.new(pos), Color = Color3.new(1, 1, 1) })
	local shell = acquire({ Size = Vector3.one * 0.8, CFrame = CFrame.new(pos), Material = Enum.Material.ForceField, Color = color, Transparency = 0.2 })
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 0.5
	light.Parent = orb
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX.sparkle
	e.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	e.LightEmission = 1
	e.Rate = (if calm then 14 else 36) * Q.emission
	e.Lifetime = NumberRange.new(0.3, 0.45)
	e.Speed = NumberRange.new(5, 8)
	e.Shape = Enum.ParticleEmitterShape.Sphere
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	e.Size = seq(0.35, 0)
	e.Transparency = seq(0.1, 0.7)
	e.Parent = shell
	local done = false
	local cued = false
	local h = {}
	function h.set(_: any, frac: number)
		if done then
			return
		end
		local f = math.clamp(frac, 0, 1)
		local eased = 1 - (1 - f) * (1 - f)
		local p = getPos()
		orb.CFrame = CFrame.new(p)
		shell.CFrame = CFrame.new(p)
		orb.Size = Vector3.one * (0.3 + 1.3 * eased)
		local wobble = if calm or f < 1 then 1 else 1 + 0.06 * math.sin(os.clock() * TAU * 1.2)
		shell.Size = Vector3.one * (0.8 + 2.4 * eased) * wobble
		shell.Size = Vector3.one * math.max(shell.Size.X, 3 * (1 - eased) + 0.8) -- particles converge from a wider sphere early on
		light.Brightness = 0.5 + 2.5 * eased
		orb.Color = Color3.new(1, 1, 1):Lerp(color, 0.25 * (1 - f))
		if f >= 1 and not cued then
			cued = true
			local ring = faceRing(p, 1.6, 0.15, color, 0.1)
			tween(ring, 0.3, { Size = Vector3.new(0.05, 6, 6), Transparency = 1 })
			releaseAfter(ring, 0.35)
		end
	end
	local function finish(fadeTime: number)
		if done then
			return
		end
		done = true
		e.Enabled = false
		tween(orb, fadeTime, { Size = Vector3.one * 0.1, Transparency = 1 })
		tween(shell, fadeTime, { Transparency = 1 })
		tween(light, fadeTime, { Brightness = 0 })
		releaseAfter(orb, fadeTime + 0.05)
		releaseAfter(shell, fadeTime + 0.05)
	end
	function h.release(_: any)
		finish(0.08)
	end
	function h.cancel(_: any)
		finish(0.2)
	end
	return h
end

-- Expanding ring + flash at the muzzle, aligned with the shot direction.
function HarvestFX.muzzleFlash(pos: Vector3, dir: Vector3, color: Color3)
	if style then
		color = style.beam
		local cf2 = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, math.pi / 2, 0)
		local ring2 = acquire({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.18, 1, 1), CFrame = cf2, Color = style.capture, Transparency = 0.2 })
		tween(ring2, 0.42, { Size = Vector3.new(0.08, 10, 10), Transparency = 1 })
		releaseAfter(ring2, 0.5)
	end
	local cf = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, math.pi / 2, 0)
	local ring = acquire({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.25, 1.6, 1.6), CFrame = cf, Color = color, Transparency = 0.05 })
	tween(ring, 0.28, { Size = Vector3.new(0.1, 7, 7), Transparency = 1 })
	local flash = acquire({ Size = Vector3.one * 2.2, CFrame = CFrame.new(pos), Color = Color3.new(1, 1, 1), Transparency = 0.1 })
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = 22
	l.Brightness = 3.5
	l.Parent = flash
	tween(flash, 0.18, { Size = Vector3.one * 0.4, Transparency = 1 })
	tween(l, 0.25, { Brightness = 0 })
	releaseAfter(ring, 0.35)
	releaseAfter(flash, 0.35)
	burst(pos, color, 10, 16, 0.5, TEX.sparks, { lifetime = NumberRange.new(0.12, 0.25), drag = 6 })
end

-- Travelling pulse with a gravity beam back to the muzzle. targetFn returns the (possibly moving)
-- destination each frame.
function HarvestFX.pulse(from: Vector3, targetFn: () -> Vector3, duration: number, color: Color3, onArrive: (Vector3) -> ())
	if style then
		color = style.beam
	end
	local calm = Styles.reducedMotion()
	local orb = acquire({ Size = Vector3.one * 1.3, CFrame = CFrame.new(from), Color = Color3.new(1, 1, 1) })
	local shell = acquire({ Size = Vector3.one * 3.0, CFrame = CFrame.new(from), Material = Enum.Material.ForceField, Color = color, Transparency = 0 })
	local root = acquire({ Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(from) })
	local a0 = Instance.new("Attachment")
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Parent = orb
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	beam.LightEmission = 0.85 -- bright but controlled: never a full-screen glare
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Width0 = 0.9
	beam.Width1 = 0.45
	beam.Texture = TEX.sparkle
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.TextureLength = 3
	beam.TextureSpeed = if calm then 1 else 5
	beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 0.35) })
	beam.Parent = root
	local t0a = Instance.new("Attachment")
	t0a.Position = Vector3.new(0, 0.55, 0)
	t0a.Parent = orb
	local t1a = Instance.new("Attachment")
	t1a.Position = Vector3.new(0, -0.55, 0)
	t1a.Parent = orb
	local trail = Instance.new("Trail")
	trail.Attachment0 = t0a
	trail.Attachment1 = t1a
	trail.Color = ColorSequence.new(color)
	trail.LightEmission = 1
	trail.Lifetime = 0.25
	trail.FaceCamera = true
	trail.WidthScale = seq(2.4, 0)
	trail.Transparency = seq(0, 1)
	trail.Parent = orb
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = 16
	l.Brightness = 2.5
	l.Parent = orb
	local t = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		t += dt
		local u = math.clamp(t / duration, 0, 1)
		local target = targetFn()
		local pos = from:Lerp(target, u)
		orb.CFrame = CFrame.new(pos)
		shell.CFrame = CFrame.new(pos)
		shell.Size = Vector3.one * 3.0 * (if calm then 1 else 1 + 0.12 * math.sin(t * 14))
		if u >= 1 then
			conn:Disconnect()
			release(shell)
			trail.Enabled = false
			tween(orb, 0.12, { Transparency = 1 })
			releaseAfter(orb, 0.15)
			tween(beam, 0.15, { Width0 = 0, Width1 = 0 })
			releaseAfter(root, 0.18)
			onArrive(target)
		end
	end)
end

---------------------------------------------------------------- lock-on

-- 3D lock ring around the locked target: snaps in from wide, four rotating ticks. handle:update(pos, size,
-- color)  handle:destroy()
function HarvestFX.lockRing(pos: Vector3, size: number, color: Color3): any
	local calm = Styles.reducedMotion()
	local ring = faceRing(pos, size * 2.6, 0.12, color, 0.2)
	local ticks = {}
	for i = 1, 4 do
		ticks[i] = acquire({ Shape = Enum.PartType.Block, Size = Vector3.new(0.25, 0.25, size * 0.35), Color = color, Transparency = 0.05 })
	end
	local born = os.clock()
	local alive = true
	local h = {}
	function h.update(_: any, p: Vector3, s: number, c: Color3)
		if not alive then
			return
		end
		local age = os.clock() - born
		local k = math.clamp(age / 0.15, 0, 1) -- snap-in
		local d = s * (2.6 - 1.1 * (1 - (1 - k) * (1 - k)))
		local look = CFrame.lookAt(p, camPos())
		ring.CFrame = look * CFrame.Angles(0, math.pi / 2, 0)
		ring.Size = Vector3.new(0.12, d, d)
		ring.Color = c
		local spin = if calm then 0 else age * TAU * 0.35
		for i, tk in ticks do
			local a = spin + (i - 1) * math.pi / 2
			local off = (look.RightVector * math.cos(a) + look.UpVector * math.sin(a)) * (d * 0.5 + s * 0.15)
			tk.CFrame = CFrame.lookAt(p + off, p + off * 2)
			tk.Size = Vector3.new(0.25, 0.25, s * 0.35)
			tk.Color = c
		end
	end
	function h.destroy(_: any)
		if not alive then
			return
		end
		alive = false
		release(ring)
		for _, tk in ticks do
			release(tk)
		end
	end
	h:update(pos, size, color)
	return h
end

---------------------------------------------------------------- impacts by meteor family

-- kind: shatter | molten | electric | spore | metal | rock | stardust | radiant | void | prism
function HarvestFX.impact(pos: Vector3, color: Color3, size: number, kind: string?, burstColors: ColorSequence?)
	local calm = Styles.reducedMotion()
	local bc: any = burstColors or color
	local wave = faceRing(pos, size, 0.25, color, 0)
	tween(wave, 0.35, { Size = Vector3.new(0.05, size * 3.2, size * 3.2), Transparency = 1 })
	releaseAfter(wave, 0.4)
	local flash = acquire({ Size = Vector3.one * size * 0.9, CFrame = CFrame.new(pos), Color = Color3.new(1, 1, 1), Transparency = 0.2 })
	tween(flash, 0.16, { Size = Vector3.one * size * 0.3, Transparency = 1 })
	releaseAfter(flash, 0.2)
	local k = kind or "spore"
	if k == "shatter" then
		burst(pos, bc, 22, 18, 0.9)
		shards(pos, color:Lerp(Color3.new(1, 1, 1), 0.4), Enum.Material.Glass, 5, size * 0.3, size * 1.8)
	elseif k == "molten" then
		burst(pos, bc, 16, 12, 1.4, TEX.fire, { lifetime = NumberRange.new(0.3, 0.6) })
		burst(pos, rgb(255, 210, 120), 20, 22, 0.3, TEX.sparks, { acceleration = Vector3.new(0, -20, 0), drag = 1 })
	elseif k == "electric" then
		burst(pos, bc, 24, 26, 0.35, TEX.sparks, { lifetime = NumberRange.new(0.12, 0.3), drag = 5 })
		if not calm then
			zaps(pos, Color3.new(1, 1, 1), color, 3, size * 1.6)
		end
	elseif k == "spore" then
		burst(pos, bc, 10, 6, size * 0.35, TEX.smoke, { lightEmission = 0.4, lifetime = NumberRange.new(0.6, 1.0), size = seq(size * 0.3, size * 0.55), transparency = seq(0.4, 1) })
		burst(pos, bc, 18, 8, 0.6, TEX.sparkle, { lifetime = NumberRange.new(0.8, 1.4), drag = 1.5 })
	elseif k == "metal" then
		burst(pos, rgb(255, 240, 200), 28, 30, 0.3, TEX.sparks, { lifetime = NumberRange.new(0.2, 0.45), acceleration = Vector3.new(0, -30, 0), drag = 1 })
		burst(pos, bc, 8, 6, size * 0.3, TEX.dust, { lightEmission = 0, size = seq(size * 0.25, size * 0.4), transparency = seq(0.4, 1) })
	elseif k == "rock" then
		burst(pos, rgb(130, 110, 95), 10, 8, size * 0.3, TEX.dust, { lightEmission = 0, size = seq(size * 0.3, size * 0.5), transparency = seq(0.35, 1) })
		burst(pos, bc, 16, 16, 0.5, TEX.sparks)
		shards(pos, rgb(86, 66, 56), Enum.Material.Basalt, 5, size * 0.3, size * 1.6)
	elseif k == "stardust" then
		burst(pos, bc, 34, 14, 0.9, TEX.sparkle, { lifetime = NumberRange.new(0.8, 1.4), drag = 2 })
		burst(pos, bc, 4, 2, size * 0.5, TEX.glow, { lifetime = NumberRange.new(0.3, 0.5) })
	elseif k == "radiant" then
		burst(pos, bc, 6, 3, size * 0.6, TEX.core, { lifetime = NumberRange.new(0.3, 0.5), size = seq(size * 0.6, size * 1.2), transparency = seq(0.2, 1) })
		burst(pos, bc, 30, 20, 0.9)
		if not calm then
			for i = 0, 5 do
				local a = i * TAU / 6
				local look = CFrame.lookAt(pos, camPos())
				local dir = look.RightVector * math.cos(a) + look.UpVector * math.sin(a)
				local ray = acquire({ Shape = Enum.PartType.Block, Size = Vector3.new(0.25, 0.25, size * 0.5), CFrame = CFrame.lookAt(pos + dir * size * 0.5, pos + dir * size * 2), Color = rgb(255, 230, 150), Transparency = 0.1 })
				tween(ray, 0.35, { CFrame = CFrame.lookAt(pos + dir * size * 2.2, pos + dir * size * 4), Size = Vector3.new(0.1, 0.1, size * 1.6), Transparency = 1 })
				releaseAfter(ray, 0.4)
			end
		end
	elseif k == "void" then
		-- implosion: matter pulled INTO the impact point + a contracting ring
		burst(pos, bc, 30, 10, 0.6, TEX.sparkle, { inward = true, inwardRadius = size * 3, lifetime = NumberRange.new(0.25, 0.4), drag = 0 })
		local ring = faceRing(pos, size * 3.4, 0.2, color, 0.1)
		tween(ring, 0.35, { Size = Vector3.new(0.05, size * 0.4, size * 0.4), Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		releaseAfter(ring, 0.4)
	elseif k == "prism" then
		burst(pos, bc, 36, 18, 0.9, TEX.sparkle, { lifetime = NumberRange.new(0.6, 1.1) })
		burst(pos, bc, 5, 3, size * 0.5, TEX.glow, { lifetime = NumberRange.new(0.3, 0.5) })
	else
		burst(pos, bc, 20, 16, 1.0)
	end
end

-- Stasis bubble while the capture is being confirmed. Returns a cleanup function.
function HarvestFX.stasis(getPos: () -> Vector3, size: number, color: Color3): () -> ()
	local calm = Styles.reducedMotion()
	local bubble = acquire({ Size = Vector3.one * size * 1.6, CFrame = CFrame.new(getPos()), Material = Enum.Material.ForceField, Color = color, Transparency = 0.1 })
	local alive = true
	local conn = RunService.RenderStepped:Connect(function()
		if alive then
			bubble.CFrame = CFrame.new(getPos())
			bubble.Size = Vector3.one * size * (if calm then 1.6 else 1.55 + 0.08 * math.sin(os.clock() * TAU * 1.2))
		end
	end)
	return function()
		if not alive then
			return
		end
		alive = false
		conn:Disconnect()
		tween(bubble, 0.2, { Transparency = 1, Size = bubble.Size * 1.3 })
		releaseAfter(bubble, 0.25)
	end
end

-- Gravity tether between two attachments (collector -> meteor). Returns the Beam (destroy when done).
function HarvestFX.tether(att0: Attachment, att1: Attachment, color: Color3): Beam
	local b = Instance.new("Beam")
	b.Attachment0 = att0
	b.Attachment1 = att1
	b.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	b.LightEmission = 1
	b.LightInfluence = 0
	b.FaceCamera = true
	b.Width0 = 0.8
	b.Width1 = 2.6
	b.Segments = 20
	b.CurveSize0 = 0
	b.CurveSize1 = 0
	b.Texture = TEX.sparkle
	b.TextureMode = Enum.TextureMode.Wrap
	b.TextureLength = 3
	b.TextureSpeed = -4
	b.Transparency = seq(0, 0.2)
	b.Parent = container
	return b
end

-- Material absorption at the collector: matter spirals in, flash, ring. flourish 1..3 (rarity).
function HarvestFX.implosion(pos: Vector3, up: Vector3, color: Color3, flourish: number?)
	local f = flourish or 1
	burst(pos, color, 26 + 10 * f, 8, 0.7, TEX.sparkle, { inward = true, inwardRadius = 9, lifetime = NumberRange.new(0.3, 0.5), drag = 0, hold = 0.8 })
	local flash = acquire({ Size = Vector3.one * 6, CFrame = CFrame.new(pos), Color = color, Transparency = 0.1 })
	tween(flash, 0.35, { Size = Vector3.one * 0.5, Transparency = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	local ring = acquire({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 2, 2),
		CFrame = CFrame.lookAt(pos, pos + up) * CFrame.Angles(0, math.pi / 2, 0),
		Color = if style then style.capture else Color3.new(1, 1, 1),
		Transparency = 0.1,
	})
	tween(ring, 0.5, { Size = Vector3.new(0.1, 16, 16), Transparency = 1 })
	if style then
		burst(pos, style.beam, 24, 30, 1.6)
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = 30
	l.Brightness = 4
	l.Parent = flash
	tween(l, 0.6, { Brightness = 0 })
	burst(pos, color, 30, 22, 1.1)
	releaseAfter(flash, 0.65)
	releaseAfter(ring, 0.65)
end

-- Perfect capture celebration at pos (the catch point). flourish 1..3 scales the show.
function HarvestFX.perfect(pos: Vector3, up: Vector3, color: Color3, flourish: number?)
	local f = flourish or 1
	local calm = Styles.reducedMotion()
	local gold = rgb(255, 215, 90)
	local rings = if calm then 1 else 1 + math.min(f, 2)
	for i = 1, rings do
		local r = faceRing(pos, 2, 0.2, if i == 2 then color else gold, 0.05)
		task.delay((i - 1) * 0.08, function()
			if r.Parent then
				tween(r, 0.55, { Size = Vector3.new(0.05, 18 + i * 6, 18 + i * 6), Transparency = 1 })
			end
		end)
		releaseAfter(r, 0.7 + (i - 1) * 0.08)
	end
	burst(pos, Styles.cs(Color3.new(1, 1, 1), gold), 28 + 12 * f, 24, 1.1, TEX.sparkle, { lifetime = NumberRange.new(0.6, 1.1), drag = 2 })
	burst(pos, gold, 3, 2, 4, TEX.core, { lifetime = NumberRange.new(0.25, 0.4), size = seq(4, 9), transparency = seq(0.3, 1) })
	if f >= 3 and not calm then
		-- legendary+: a column of light rising from the catch point
		local col = acquire({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(2, 1.2, 1.2), CFrame = CFrame.lookAt(pos, pos + up) * CFrame.Angles(0, math.pi / 2, 0) + up * 1, Color = gold, Transparency = 0.2 })
		tween(col, 0.7, { Size = Vector3.new(60, 0.3, 0.3), CFrame = CFrame.lookAt(pos, pos + up) * CFrame.Angles(0, math.pi / 2, 0) + up * 30, Transparency = 1 })
		releaseAfter(col, 0.75)
	end
end

-- Pulse that found nothing / missed: dull puff, deflected sparks.
function HarvestFX.fizzle(pos: Vector3, color: Color3)
	burst(pos, rgb(150, 160, 180), 10, 6, 1.0, TEX.smoke, { lightEmission = 0.2, transparency = seq(0.3, 1) })
	burst(pos, color, 10, 14, 0.3, TEX.sparks, { lifetime = NumberRange.new(0.15, 0.3), drag = 4 })
	local puff = acquire({ Size = Vector3.one * 2, CFrame = CFrame.new(pos), Material = Enum.Material.ForceField, Color = color, Transparency = 0.3 })
	tween(puff, 0.3, { Size = Vector3.one * 5, Transparency = 1 })
	releaseAfter(puff, 0.35)
end

---------------------------------------------------------------- reload / READY on the harvester itself

local saved: { [Instance]: any } = setmetatable({}, { __mode = "k" }) :: any
local DIM = rgb(52, 62, 84)

local function emitterParts(m: Model): any
	local s = saved[m]
	if s then
		return s
	end
	local head = m:FindFirstChild("Head")
	if not head then
		return nil
	end
	local crystal = head:FindFirstChild("MuzzleCrystal") :: BasePart?
	local coils = {}
	for i = 1, 3 do
		local c = head:FindFirstChild("CoilRing" .. i) :: BasePart?
		if c then
			table.insert(coils, { part = c, color = c.Color })
		end
	end
	local light = crystal and crystal:FindFirstChildOfClass("PointLight")
	s = { crystal = crystal, crystalColor = crystal and crystal.Color, coils = coils, light = light, lightBrightness = light and light.Brightness }
	saved[m] = s
	return s
end

-- mode: "reload" (frac = progress) | "ready" | "charging" (frac = charge) | "charged" | "firing"
-- Coils light up one by one during the reload; the muzzle crystal refills from dim to the accent colour.
function HarvestFX.emitterState(m: Model?, mode: string, frac: number, accent: Color3)
	if not m then
		return
	end
	local s = emitterParts(m)
	if not s or not s.crystal then
		return
	end
	local color = if style then style.beam else accent
	local level
	if mode == "reload" then
		level = math.clamp(frac, 0, 1)
		s.crystal.Color = DIM:Lerp(color, level * 0.8)
		for i, c in s.coils do
			local on = frac >= i / (#s.coils + 1)
			c.part.Color = if on then color else DIM
		end
	elseif mode == "firing" then
		level = 0.15
		s.crystal.Color = DIM
		for _, c in s.coils do
			c.part.Color = DIM
		end
	else
		level = if mode == "charging" then 0.6 + 0.4 * frac elseif mode == "charged" then 1 else 0.75
		s.crystal.Color = if mode == "charged" then color:Lerp(Color3.new(1, 1, 1), 0.45) else color
		for _, c in s.coils do
			c.part.Color = color
		end
	end
	if s.light then
		s.light.Brightness = 0.3 + 2.2 * level
		s.light.Color = color
	end
end

function HarvestFX.restoreEmitter(m: Model?)
	local s = m and saved[m]
	if not s then
		return
	end
	if s.crystal and s.crystalColor then
		s.crystal.Color = s.crystalColor
	end
	for _, c in s.coils do
		c.part.Color = c.color
	end
	if s.light and s.lightBrightness then
		s.light.Brightness = s.lightBrightness
	end
	saved[m :: Model] = nil
end

-- READY: a soft ring + sparkle at the muzzle when the reload completes.
function HarvestFX.readyPulse(pos: Vector3, accent: Color3)
	local color = if style then style.beam else accent
	local ring = faceRing(pos, 1.2, 0.15, color, 0.1)
	tween(ring, 0.35, { Size = Vector3.new(0.05, 5, 5), Transparency = 1 })
	releaseAfter(ring, 0.4)
	if not Styles.reducedMotion() then
		burst(pos, color, 10, 5, 0.4, TEX.sparkle, { lifetime = NumberRange.new(0.3, 0.5) })
	end
end

return HarvestFX
