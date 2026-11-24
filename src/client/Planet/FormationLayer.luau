--!strict
-- FormationLayer — owner: Technical Art (Evolution WOW 2.0). One per planet slot (created by
-- PlanetVisualController). Renders the planet's FormationRegistry formations INCREMENTALLY with FormationArt:
--   * sync(spec, opts): diff the wanted instance set (owned, active for the branch, count <= maxCount) against
--     what is built; build ONLY new instances, remove ONLY retired ones (branch switch -> dormant formations
--     sink away). Never rebuilds the whole planet; re-running sync with the same data does nothing (dedupe).
--   * deterministic: sites come from FormationArt.sitePlan(seed) and never move (rejoin = same layout).
--   * cinematic per new formation (owner or visitor within FX_RANGE):
--       anticipation 0-0.8 s (energy converging + ground glow + rising hum), climax 0.8-1.4 s (shockwave ring,
--       light pulse, themed burst), emergence 1.4-2.8 s (rises from the crust, Back easing) -> idle animation.
--     Skip (skipAll) snaps everything to the final state at once. Reduced motion / minimal effects: no
--     anticipation, no shockwave or pulses, the formation simply appears with one soft fade.
--   * LOD by camera distance from the planet centre: NEAR (< R + 424, i.e. 584 at R = 160; was 520 at R = 96):
--     all formations, idle animation, particles, lights.
--     MID (< 1700): formations + landmarks, no particles / lights / animation, orbitals turn slowly.
--     FAR: landmarks + orbitals + rim only (silhouettes read from across the system).
--   * orbital dressing + rim glow from stage 3 (FormationArt.orbitals).
--   * Maid: every Instance / Tween / connection it creates is tracked and released on destroy().

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage.PF_Shared
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local Density = require(Shared.Planet.FormationDensity)
local WorldLayout = require(Shared.Config.WorldLayout)
local Art = require(script.Parent.FormationArt)
local okSfx, Sfx = pcall(function()
	return require(script.Parent.Parent.Audio.Sfx)
end)

local FormationLayer = {}
FormationLayer.__index = FormationLayer

-- NEAR is measured from the planet centre: 424 studs above the surface (2026-11-23: was 520 for R = 96)
local NEAR_ABOVE_SURFACE = 424
local MID = 1700
local FX_RANGE = 900
local T_ANTICIPATE, T_CLIMAX, T_EMERGE = 0.8, 0.6, 1.4
local TAU = math.pi * 2

local player = Players.LocalPlayer

local function reducedMotion(): boolean
	if player and player:GetAttribute("PFReducedMotion") == true then
		return true
	end
	local ok, v = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return ok and v == true
end

-- slot geometry (centre, radius, spawn position) of a slot model
local function geometry(model: Model): (Vector3, number, Vector3?)
	local core = model:FindFirstChild("Core") :: BasePart?
	local R = (model:GetAttribute("PFRadius") :: number?) or (core and core.Size.X / 2) or WorldLayout.PLANET_RADIUS
	local sp = model:FindFirstChild("SpawnPoint")
	return if core then core.Position else Vector3.zero, R, if sp and sp:IsA("BasePart") then sp.Position else nil
end

function FormationLayer.new(slot: number, model: Model, root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Formations_" .. slot
	folder.Parent = root
	local self = setmetatable({
		slot = slot,
		model = model,
		root = root,
		folder = folder,
		far = Instance.new("Folder"), -- landmarks + orbitals (always parented)
		near = Instance.new("Folder"), -- other formations (parented within MID)
		planet = nil :: any,
		plan = nil :: any,
		seed = nil :: number?,
		instances = {} :: { [string]: any },
		orbitals = nil :: any,
		orbitalKey = "",
		lod = "far",
		dist = math.huge,
		quality = "full",
		emerging = {} :: { [any]: boolean },
		maid = {} :: { any },
		t = 0,
		stats = { built = 0, removed = 0, cinematics = 0, syncs = 0 },
	}, FormationLayer)
	self.far.Name = "Far"
	self.far.Parent = folder
	self.near.Name = "Near"
	return self
end

function FormationLayer:_track(x: any)
	table.insert(self.maid, x)
	return x
end

-- planet context for FormationArt (re-planned only when the seed / quality / theme changes)
function FormationLayer:_planet(spec: any, quality: string)
	local center, R, spawnPos = geometry(self.model)
	local theme = spec.theme or "primordial"
	if self.planet and self.seed == spec.seed and self.planet.center == center then
		self.planet.theme = theme
		self.planet.quality = quality
		return self.planet
	end
	self.seed = spec.seed
	self.planet = { seed = spec.seed, slot = self.slot, center = center, R = R, theme = theme, quality = quality }
	self.planet.blocked = Art.blockedFor(self.slot, center, spawnPos, R)
	self.plan = Art.sitePlan(self.planet)
	return self.planet
end

-- renderer variety groups (a crossing into a new variant set rebuilds that cluster)
local VARIANT_KIND = { FirstForest = "trees", CrystalCluster = "crystals" }

-- wanted instance keys "Id#i" -> { def, index, elements, level, sig }, for owned formations active on this
-- branch. Sites + element counts come ONLY from the shared FormationDensity.layout(def, owned, DNA).
local function wanted(spec: any): { [string]: any }
	local out = {}
	for id, n in spec.formationCounts or {} do
		local def = FormationRegistry.get(id)
		if def and type(n) == "number" and n > 0 and FormationRegistry.isActive(id, spec.branch) then
			for i, e in Density.layout(def, n, spec.dna) do
				local kind = VARIANT_KIND[id]
				local tier = if kind then #Density.variants(kind, e.level) else 0
				out[id .. "#" .. i] = { def = def, index = i, elements = e.elements, level = e.level, sig = e.elements .. "/" .. tier }
			end
		end
	end
	return out
end

-- Sites reserved for the decorator's generic dressing: owned + this branch's + generic formations
-- (so generic props never sit where a formation is or will grow).
function FormationLayer:reservedSites(spec: any, quality: string?): { { dir: Vector3, ang: number } }
	self:_planet(spec, quality or self.quality)
	local out = {}
	for key, site in self.plan do
		local id = string.match(key, "^(.-)#")
		local def = FormationRegistry.get(id)
		if def and (def.branch == nil or def.branch == spec.branch or (spec.formationCounts or {})[id]) then
			table.insert(out, { dir = site.dir, ang = site.ang })
		end
	end
	return out
end

function FormationLayer:hasLandmark(spec: any): boolean
	for key, w in wanted(spec) do
		local _ = key
		if w.def.landmark then
			return true
		end
	end
	return false
end

function FormationLayer:_parentFor(inst: any): Instance
	return if inst.far then self.far else self.near
end

-- enable / disable particles + lights + animation of one instance for the current LOD
function FormationLayer:_applyLod(inst: any)
	local near = self.lod == "near"
	for _, e in inst.emitters do
		e.Enabled = near
	end
	for _, l in inst.lights do
		l.Enabled = near
	end
end

function FormationLayer:_remove(key: string, animate: boolean)
	local inst = self.instances[key]
	if not inst then
		return
	end
	self.instances[key] = nil
	self.emerging[inst] = nil
	self.stats.removed += 1
	local model = inst.model
	if animate and not reducedMotion() and self.lod == "near" then
		-- sink back into the crust, then free
		local start, dur = os.clock(), 0.7
		inst.sinking = { start = start, dur = dur, from = inst.siteCf }
		self.emerging[inst] = true
		task.delay(dur + 0.05, function()
			self.emerging[inst] = nil
			model:Destroy()
		end)
	else
		model:Destroy()
	end
end

-- Emergence / skip state: inst.emerge = { start, anticipate, climax, height, fx = {Instance}, phase }
function FormationLayer:_startCinematic(inst: any)
	local calm = reducedMotion() or self.quality == "minimal"
	self.stats.cinematics += 1
	local model = inst.model
	local siteCf = inst.siteCf
	if calm then
		-- no motion, no pulses: final pose at once; minimal quality (not reduced motion) adds one soft fade
		model:ScaleTo(inst.scale or 1)
		model:PivotTo(siteCf)
		self:_captureAnimBases(inst) -- idle animation starts from the final pose
		if reducedMotion() then
			return
		end
		local glow = Instance.new("Part")
		glow.Anchored, glow.CanCollide, glow.CanQuery, glow.CanTouch, glow.CastShadow = true, false, false, false, false
		glow.Shape = Enum.PartType.Ball
		glow.Material = Enum.Material.Neon
		glow.Color = inst.burst or Color3.new(1, 1, 1)
		glow.Size = Vector3.one * math.max(6, inst.height * 0.8)
		glow.CFrame = siteCf * CFrame.new(0, inst.height * 0.3, 0)
		glow.Transparency = 0.6
		glow.Parent = self.folder
		local tw = TweenService:Create(glow, TweenInfo.new(0.8), { Transparency = 1 })
		tw:Play()
		task.delay(0.85, function()
			glow:Destroy()
		end)
		return
	end
	local h = math.max(inst.height, 4)
	model:ScaleTo(0.25 * (inst.scale or 1))
	model:PivotTo(siteCf * CFrame.new(0, -h * 0.7, 0))
	local fxParts = {}
	local function fxPart(props: { [string]: any }): Part
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
		for k, v in props do
			(p :: any)[k] = v
		end
		p.Parent = self.folder
		table.insert(fxParts, p)
		return p
	end
	local color = inst.burst or Color3.new(1, 1, 1)
	local footprint = math.max(6, (if inst.def then Density.footprintStuds(inst.def) else 8) * 1.6)
	-- anticipation: converging energy + ground glow
	local converge = fxPart({ Name = "Converge", Shape = Enum.PartType.Ball, Size = Vector3.one * footprint * 2, CFrame = siteCf * CFrame.new(0, 2, 0), Transparency = 1 })
	local e = Instance.new("ParticleEmitter")
	e.Texture = Art.TEX.sparkle
	e.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	e.LightEmission = 1
	e.Rate = 70
	e.Lifetime = NumberRange.new(0.5, 0.75)
	e.Speed = NumberRange.new(footprint * 1.2, footprint * 1.6)
	e.Shape = Enum.ParticleEmitterShape.Sphere
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.6, 1.3), NumberSequenceKeypoint.new(1, 0) })
	e.Parent = converge
	local groundGlow = fxPart({ Name = "GroundGlow", Shape = Enum.PartType.Cylinder, Material = Enum.Material.ForceField, Color = color, Size = Vector3.new(0.4, footprint, footprint), CFrame = siteCf * CFrame.new(0, 0.35, 0) * CFrame.Angles(0, 0, math.pi / 2), Transparency = 1 })
	-- converging motes: a ring of energy that spirals into the site and rises (anticipation)
	local motes = {}
	for k = 1, 10 do
		local m = fxPart({ Name = "Mote", Shape = Enum.PartType.Ball, Material = Enum.Material.Neon, Color = if k % 2 == 0 then color else Color3.new(1, 1, 1), Size = Vector3.one * (0.7 + (k % 3) * 0.25), CFrame = siteCf, Transparency = 0.1 })
		table.insert(motes, { part = m, a0 = k / 10 * math.pi * 2, h0 = 0.8 + (k % 4) * 0.6 })
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = footprint * 2.5
	l.Brightness = 0
	l.Shadows = false
	l.Parent = groundGlow
	TweenService:Create(groundGlow, TweenInfo.new(T_ANTICIPATE, Enum.EasingStyle.Sine), { Transparency = 0 }):Play()
	TweenService:Create(l, TweenInfo.new(T_ANTICIPATE, Enum.EasingStyle.Sine), { Brightness = 2.5 }):Play()
	local mine = self.model:GetAttribute("PFOwnerUserId") == (player and player.UserId)
	if okSfx then
		pcall(Sfx.play, "Whoosh", { at = if mine then nil else groundGlow, volume = 0.45, pitch = 0.7 })
	end
	inst.emerge = { start = os.clock(), fx = fxParts, emitter = e, groundGlow = groundGlow, light = l, height = h, phase = "anticipate", footprint = footprint, color = color, mine = mine, motes = motes }
	self.emerging[inst] = true
end

-- advance one cinematic; returns true when finished
function FormationLayer:_stepCinematic(inst: any): boolean
	local em = inst.emerge
	local model = inst.model
	if inst.sinking then
		local s = inst.sinking
		local u = math.clamp((os.clock() - s.start) / s.dur, 0, 1)
		if model.Parent then
			model:ScaleTo(math.max(0.05, 1 - 0.8 * u) * (inst.scale or 1))
			model:PivotTo(s.from * CFrame.new(0, -inst.height * 0.8 * u, 0))
		end
		return u >= 1
	end
	if not em then
		return true
	end
	local t = os.clock() - em.start
	if em.phase == "anticipate" and em.motes then
		local u = math.clamp(t / T_ANTICIPATE, 0, 1)
		local r = em.footprint * 1.3 * (1 - u) ^ 1.6 + 0.3
		for _, mo in em.motes do
			local a = mo.a0 + u * 5
			mo.part.CFrame = inst.siteCf * CFrame.new(math.cos(a) * r, mo.h0 + u * em.height * 0.35, math.sin(a) * r)
		end
	end
	if em.phase == "anticipate" and t >= T_ANTICIPATE then
		em.phase = "climax"
		em.emitter.Enabled = false
		for _, mo in em.motes or {} do
			mo.part.Transparency = 1
		end
		-- climax: shockwave ring along the surface, light pulse, themed burst
		local ring = Instance.new("Part")
		ring.Name = "Shockwave"
		ring.Anchored, ring.CanCollide, ring.CanQuery, ring.CanTouch, ring.CastShadow = true, false, false, false, false
		-- expanding energy dome centred on the site: its lower half is hidden by the crust, so it reads as a
		-- bright ring racing outward along the surface plus a fresnel bubble above it
		ring.Shape = Enum.PartType.Ball
		ring.Material = Enum.Material.ForceField
		ring.Color = em.color:Lerp(Color3.new(1, 1, 1), 0.35)
		ring.Size = Vector3.one * em.footprint
		ring.CFrame = inst.siteCf
		ring.Transparency = 0
		ring.Parent = self.folder
		table.insert(em.fx, ring)
		TweenService:Create(ring, TweenInfo.new(T_CLIMAX, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = Vector3.one * em.footprint * 4, Transparency = 1 }):Play()
		TweenService:Create(em.light, TweenInfo.new(0.15), { Brightness = 6 }):Play()
		task.delay(0.15, function()
			if em.light.Parent then
				TweenService:Create(em.light, TweenInfo.new(T_CLIMAX + T_EMERGE), { Brightness = 0 }):Play()
			end
		end)
		TweenService:Create(em.groundGlow, TweenInfo.new(T_CLIMAX + T_EMERGE), { Transparency = 1 }):Play()
		local burst = Instance.new("ParticleEmitter")
		burst.Texture = Art.TEX.sparkle
		burst.Color = ColorSequence.new(em.color, Color3.new(1, 1, 1))
		burst.LightEmission = 1
		burst.Rate = 0
		burst.Lifetime = NumberRange.new(0.6, 1.2)
		burst.Speed = NumberRange.new(10, 22)
		burst.SpreadAngle = Vector2.new(70, 70)
		burst.EmissionDirection = Enum.NormalId.Right
		burst.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
		burst.Drag = 2
		burst.Parent = em.groundGlow
		burst:Emit(40)
		if okSfx then
			pcall(Sfx.play, "Power_Up", { at = if em.mine then nil else em.groundGlow, volume = if em.mine then 0.5 else 0.7 })
		end
	end
	if em.phase == "climax" and t >= T_ANTICIPATE + T_CLIMAX * 0.5 then
		em.phase = "emerge"
	end
	if em.phase == "emerge" then
		local u = math.clamp((t - T_ANTICIPATE - T_CLIMAX * 0.5) / T_EMERGE, 0, 1)
		local k = TweenService:GetValue(u, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		if model.Parent then
			model:ScaleTo(math.max(0.05, 0.25 + 0.75 * k) * (inst.scale or 1))
			model:PivotTo(inst.siteCf * CFrame.new(0, -em.height * 0.7 * (1 - math.min(k, 1)), 0))
		end
		if u >= 1 then
			self:_finishCinematic(inst)
			return true
		end
	end
	return false
end

function FormationLayer:_finishCinematic(inst: any)
	local em = inst.emerge
	inst.emerge = nil
	if inst.model.Parent then
		inst.model:ScaleTo(inst.scale or 1)
		inst.model:PivotTo(inst.siteCf)
	end
	if em then
		for _, p in em.fx do
			task.delay(0.6, function()
				p:Destroy()
			end)
		end
	end
	self:_captureAnimBases(inst)
end

-- animation bases are captured at the FINAL pose (after emergence)
function FormationLayer:_captureAnimBases(inst: any)
	for _, a in inst.anims do
		if a.parts then
			a.base = {}
			for i, p in a.parts do
				a.base[i] = p.CFrame
			end
		end
	end
end

-- Skip: finish every running cinematic now (final state, no lingering FX)
function FormationLayer:skipAll()
	for inst in self.emerging do
		if inst.sinking then
			inst.model:Destroy()
		elseif inst.emerge then
			local em = inst.emerge
			self:_finishCinematic(inst)
			for _, p in em.fx do
				p:Destroy()
			end
		end
	end
	table.clear(self.emerging)
end

-- Build / retire instances so the planet shows exactly the wanted set. opts = { silent, quality }
function FormationLayer:sync(spec: any, opts: any?)
	local o = opts or {}
	local quality = o.quality or self.quality
	self.stats.syncs += 1
	local rebuildAll = quality ~= self.quality
	self.quality = quality
	local planet = self:_planet(spec, quality)
	-- owned formations are server facts: they show from stage 0 (the first reaction creates the first formation
	-- before any stage-up; First 10 Minutes 2.0). Generic decorator dressing and orbitals stay stage-gated.
	local want = wanted(spec)
	-- retire: no longer wanted, or the generic palette changed with the theme, or quality changed
	local regrow: { [string]: boolean } = {}
	for key, inst in self.instances do
		local w = want[key]
		local staleTheme = w and w.def.branch == nil and inst.theme ~= planet.theme
		-- DNA moved the cluster's element count / variety tier: swap it in place (no cinematic, no sinking)
		local resized = w ~= nil and inst.sig ~= w.sig
		if not w or staleTheme or rebuildAll or resized then
			self:_remove(key, not o.silent and not staleTheme and not rebuildAll and not resized)
			if resized then
				regrow[key] = true
			end
		end
	end
	-- build: wanted but missing (sorted for deterministic build order)
	local keys = {}
	for key in want do
		if not self.instances[key] then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local camPos = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position or Vector3.zero
	local closeEnough = (camPos - planet.center).Magnitude < FX_RANGE
	for _, key in keys do
		local w = want[key]
		local site = self.plan[key]
		if site then
			local ok, inst = pcall(Art.build, planet, w.def, w.index, site, { elements = w.elements, level = w.level })
			if ok and inst then
				inst.key = key
				inst.def = w.def
				inst.sig = w.sig
				inst.theme = planet.theme
				self.instances[key] = inst
				self.stats.built += 1
				inst.model.Parent = self:_parentFor(inst)
				self:_applyLod(inst)
				if not o.silent and closeEnough and not regrow[key] then
					self:_startCinematic(inst)
				else
					self:_captureAnimBases(inst)
				end
			elseif not ok then
				warn("[PF] FormationArt failed for " .. key .. ": " .. tostring(inst))
			end
		end
	end
	-- orbitals + rim (stage >= 3), rebuilt only when branch / stage / quality changes
	local orbKey = string.format("%s|%d|%s|%d", tostring(spec.theme), spec.stage, quality, planet.seed)
	if orbKey ~= self.orbitalKey then
		self.orbitalKey = orbKey
		if self.orbitals then
			self.orbitals.model:Destroy()
			self.orbitals = nil
		end
		local okO, orb = pcall(Art.orbitals, planet, spec.theme, spec.stage)
		if okO and orb then
			orb.model.Parent = self.far
			orb.rim = orb.model:FindFirstChild("Rim")
			self.orbitals = orb
			for _, a in orb.anims do
				if a.parts then
					a.base = {}
					for i, p in a.parts do
						a.base[i] = p.CFrame
					end
				end
			end
		end
	end
	self:setDistance(self.dist)
end

function FormationLayer:setDistance(d: number)
	self.dist = d
	local rim = self.orbitals and self.orbitals.rim
	if rim then
		local want = if self.planet and d < self.planet.R * 1.6 then 1 else 0.25
		if rim.Transparency ~= want then
			rim.Transparency = want
		end
	end
	local nearD = (if self.planet then self.planet.R else WorldLayout.PLANET_RADIUS) + NEAR_ABOVE_SURFACE
	local lod = if d < nearD then "near" elseif d < MID then "mid" else "far"
	local nearParent = if lod == "far" then nil else self.folder
	if self.near.Parent ~= nearParent then
		self.near.Parent = nearParent
	end
	if lod ~= self.lod then
		self.lod = lod
		for _, inst in self.instances do
			self:_applyLod(inst)
		end
	end
end

local function bulk(parts: { BasePart }, cfs: { CFrame })
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function stepAnim(a: any, t: number, dt: number, calm: boolean)
	if a.parts and not a.base then
		return -- not captured yet (still emerging)
	end
	if a.kind == "sway" and not calm then
		local ang = a.amp * math.sin(t * a.freq * TAU + a.phase)
		local rot = a.pivot * CFrame.Angles(ang, 0, ang * 0.6) * a.pivot:Inverse()
		local cfs = table.create(#a.parts)
		for i, base in a.base do
			cfs[i] = rot * base
		end
		bulk(a.parts, cfs)
	elseif a.kind == "spin" then
		a.angle = (a.angle or 0) + a.speed * dt * (if calm then 0.3 else 1)
		local bob = if calm then 0 else a.bob * math.sin(t * a.bobFreq * TAU + a.phase)
		local rot = a.pivot * CFrame.new(0, bob, 0) * CFrame.Angles(0, a.angle, 0) * a.pivot:Inverse()
		local cfs = table.create(#a.parts)
		for i, base in a.base do
			cfs[i] = rot * base
		end
		bulk(a.parts, cfs)
	elseif a.kind == "bob" and not calm then
		local off = a.pivot.UpVector * a.amp * math.sin(t * a.freq * TAU + a.phase)
		local cfs = table.create(#a.parts)
		for i, base in a.base do
			cfs[i] = base + off
		end
		bulk(a.parts, cfs)
	elseif a.kind == "glow" and not calm then
		local k = 0.5 + 0.5 * math.sin(t * a.freq * TAU + a.phase)
		local tr = a.lo + (a.hi - a.lo) * k
		for _, p in a.parts do
			p.Transparency = tr
		end
	elseif a.kind == "aurora" then
		local c = a.base + (if calm then 0 else a.amp * math.sin(t * a.freq * TAU + a.phase))
		for i, bm in a.beams do
			bm.CurveSize0 = c + i * 0.7
			bm.CurveSize1 = -c + i * 0.5
		end
	elseif a.kind == "erupt" and not calm then
		a.t += dt
		if a.t >= a.every then
			a.t = 0
			a.emitter:Emit(a.count)
		end
	end
end

-- Per frame (called by the controller for planets in range). dt = frame delta.
function FormationLayer:step(dt: number)
	self.t += dt
	-- cinematics always advance (even at range they must finish)
	for inst in self.emerging do
		if self:_stepCinematic(inst) then
			self.emerging[inst] = nil
		end
	end
	local calm = reducedMotion()
	if self.lod == "near" then
		for _, inst in self.instances do
			if not inst.emerge and not inst.sinking then
				for _, a in inst.anims do
					stepAnim(a, self.t, dt, calm)
				end
			end
		end
	end
	if self.orbitals and self.lod ~= "far" then
		for _, a in self.orbitals.anims do
			stepAnim(a, self.t, dt, calm)
		end
	end
end

function FormationLayer:getStats(): any
	local n, parts = 0, 0
	for _, inst in self.instances do
		n += 1
		for _, d in inst.model:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
			end
		end
	end
	local emerging = 0
	for _ in self.emerging do
		emerging += 1
	end
	return { instances = n, parts = parts, emerging = emerging, lod = self.lod, built = self.stats.built, removed = self.stats.removed, cinematics = self.stats.cinematics, syncs = self.stats.syncs }
end

function FormationLayer:destroy()
	self:skipAll()
	for key in self.instances do
		local inst = self.instances[key]
		inst.model:Destroy()
	end
	table.clear(self.instances)
	if self.orbitals then
		self.orbitals.model:Destroy()
		self.orbitals = nil
	end
	for _, x in self.maid do
		if typeof(x) == "RBXScriptConnection" then
			x:Disconnect()
		elseif typeof(x) == "Instance" then
			x:Destroy()
		elseif typeof(x) == "Tween" then
			x:Cancel()
		end
	end
	table.clear(self.maid)
	self.near:Destroy()
	self.far:Destroy()
	self.folder:Destroy()
end

return FormationLayer
