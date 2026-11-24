--!strict
-- FormationArt — owner: Technical Art (Evolution WOW 2.0). Art for EVERY FormationRegistry archetype plus the
-- deterministic SITE PLAN that decides where each formation instance lives on its planet.
--
-- Site plan: every registry formation instance (id, i) gets ONE fixed site, computed from the planet seed in
-- registry ORDER, whether or not the planet owns it. Unlocking / losing a formation therefore never moves any
-- other formation, rejoining reproduces the exact layout, and two planets of the same branch differ (seed).
-- Sites respect the renderer's exclusion zones (return pad, spawn, Gravity Harvester + walking corridor) and
-- each formation's polar zones; footprints never overlap.
--
-- Builders: Art.build(planet, def, index, site) -> Instance record
--   { model: Model (WorldPivot = site frame), far: boolean (landmark: kept at range), height: number,
--     anims = { ... } (sway / spin / bob / aurora / glow, stepped by FormationLayer only when near),
--     emitters = { ParticleEmitter }, lights = { PointLight }, burst = Color3 }
-- Every object stands on the true sphere, aligned to the local surface normal with a small deterministic
-- tilt, and is embedded into the crust (no floating bases on the curved horizon). All parts: Anchored,
-- CanCollide / CanQuery / CanTouch false, CastShadow false (never blocks movement, clicks or the ground probe).
-- Templates (ReplicatedStorage.PF_Assets.Models: trees, crystals, volcano) are cloned where they exist.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.PF_Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local Profile = require(Shared.Planet.PlanetVisualProfile)
local Density = require(Shared.Planet.FormationDensity)
local okHL, HarvestLayout = pcall(function()
	return require(Shared.Harvest.HarvestLayout)
end)

local Art = {}
local TAU = math.pi * 2
local rgb = Color3.fromRGB
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) -> up

local TEX = {
	sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
	sparks = "rbxasset://textures/particles/fire_sparks_main.dds",
	glow = "rbxasset://textures/particles/forcefield_glow_main.dds",
	core = "rbxasset://textures/particles/explosion01_core_main.dds",
}
Art.TEX = TEX

---------------------------------------------------------------- deterministic hashing (pure bit32, platform-exact)

local function mix(h: number, byte: number): number
	h = bit32.bxor(h, byte)
	return (bit32.lshift(h, 24) + h * 403) % 4294967296 -- h * 16777619 mod 2^32 without float overflow
end

function Art.hash(...: any): number
	local h = 2166136261
	for _, v in { ... } do
		local s = tostring(v)
		for i = 1, #s do
			h = mix(h, string.byte(s, i))
		end
		h = mix(h, 0x9e)
	end
	return h % 2147483647
end

---------------------------------------------------------------- site plan

local function angleBetween(a: Vector3, b: Vector3): number
	return math.acos(math.clamp(a:Dot(b), -1, 1))
end

-- Exclusion zones (same rules as PlanetDecorator.buildBlocked): return pad, spawn, harvester + corridor.
-- 2026-11-23: the zones protect fixed-size things (pad, spawn, harvester, a walking corridor), so they are
-- kept in STUDS (the old degree values measured on the 96-stud prototype planet) and converted with R.
local REF_R = 96
function Art.blockedFor(slot: number, center: Vector3, spawnPos: Vector3?, R: number?): { { dir: Vector3, ang: number } }
	local radius = R or WorldLayout.PLANET_RADIUS
	local blocked = {}
	local function block(d: Vector3, refDeg: number)
		table.insert(blocked, { dir = d.Unit, ang = math.rad(refDeg) * REF_R / radius })
	end
	block(Vector3.yAxis, math.max(14, (Profile.VISUAL.POLAR_EXCLUSION_DEG or 0) * 0.6))
	local sp = spawnPos or WorldLayout.getPlanetSpawn(slot).Position
	local spawnDir = (sp - center).Unit
	block(spawnDir, 7)
	if okHL then
		local okBase, base = pcall(HarvestLayout.getBaseCFrame, slot)
		if okBase then
			local hDir = (base.Position - center).Unit
			block(hDir, 16)
			for i = 1, 5 do
				block(spawnDir:Lerp(hDir, i / 6), 4)
			end
		end
	end
	return blocked
end

-- planet = { seed, slot, center, R, blocked }. Returns { ["Id#i"] = { dir, ang, twist } } for ALL formations.
-- Candidates are generated in a station-relative frame (rotated by the slot's azimuth) so the same owner gets
-- the same layout relative to the station whatever slot they occupy.
function Art.sitePlan(planet: any): { [string]: any }
	local plan = {}
	local placed = {}
	local c = planet.center
	local az = math.atan2(c.Z, c.X)
	local toWorld = CFrame.Angles(0, -az, 0)
	for _, id in FormationRegistry.ORDER do
		local def = FormationRegistry.DEFS[id]
		-- scaled footprint; density formations reserve their DNA-growth sites up front (FormationDensity)
		local ang = Density.footprintStuds(def) / planet.R
		for i = 1, Density.siteCount(def) do
			local rng = Random.new(Art.hash(planet.seed, id, i))
			local best, bestScore = nil, -math.huge
			for attempt = 1, 90 do
				local zones = def.zones or { { 30, 165 } }
				local z = zones[rng:NextInteger(1, #zones)]
				local polar = math.rad(rng:NextNumber(z[1], z[2]))
				local a = rng:NextNumber(0, TAU)
				local d = toWorld:VectorToWorldSpace(Vector3.new(math.sin(polar) * math.cos(a), math.cos(polar), math.sin(polar) * math.sin(a)))
				local clear = math.huge
				for _, b in planet.blocked do
					clear = math.min(clear, angleBetween(d, b.dir) - (b.ang + ang))
				end
				for _, p in placed do
					clear = math.min(clear, angleBetween(d, p.dir) - (p.ang + ang) * 0.92)
				end
				if clear >= 0 then
					best = d
					break
				elseif clear > bestScore then
					best, bestScore = d, clear -- deterministic fallback: the least-overlapping candidate
				end
				local _ = attempt
			end
			local site = { dir = best :: Vector3, ang = ang, twist = rng:NextNumber(0, TAU) }
			plan[id .. "#" .. i] = site
			table.insert(placed, site)
		end
	end
	return plan
end

---------------------------------------------------------------- builder helpers

local function quality(level: string?): any
	if level == "minimal" then
		return { emitters = 0, lights = false, detail = 0.6 }
	elseif level == "reduced" then
		return { emitters = 1, lights = true, detail = 0.8 }
	end
	return { emitters = 2, lights = true, detail = 1 }
end
Art.quality = quality

-- Builders work at the authored size on a VIRTUAL sphere of radius R / scale that touches the real planet at the
-- site; Art.build then scales the model by `scale` about the site pivot, which maps that virtual sphere exactly
-- onto the real one (scaled props still hug the curvature, nothing floats or sinks).
local function newB(planet: any, def: any, site: any, index: number, pal: any, scale: number?): any
	local s = scale or 1
	local model = Instance.new("Model")
	model.Name = def.id .. "_" .. index
	local frame = WorldLayout.frameFromUp(site.dir, site.twist)
	local surf = planet.center + site.dir * planet.R
	local siteCf = CFrame.new(surf) * frame
	model.WorldPivot = siteCf
	local Rv = planet.R / s
	return {
		model = model,
		center = surf - site.dir * Rv,
		R = Rv,
		scale = s,
		elements = 0,
		level = 0,
		elRng = Random.new(Art.hash(planet.seed, def.id, index, "el")),
		dir = site.dir,
		frame = frame,
		siteCf = siteCf,
		rng = Random.new(Art.hash(planet.seed, def.id, index, "art")),
		pal = pal,
		def = def,
		q = quality(planet.quality),
		anims = {},
		emitters = {},
		lights = {},
	}
end

local function P(b: any, props: { [string]: any }): BasePart
	local p = Instance.new(props.ClassName or "Part") :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	if p:IsA("Part") then
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
	end
	for k, v in props do
		if k ~= "ClassName" then
			(p :: any)[k] = v
		end
	end
	p.Parent = b.model
	return p
end

-- Ground frame at tangent offset (x, z) from the site, h studs above the true sphere, aligned to THAT spot's
-- normal (so wide formations hug the curvature). tilt = max organic tilt in degrees (deterministic).
local function at(b: any, x: number, z: number, h: number, twist: number?, tilt: number?): CFrame
	local d2 = (b.dir * b.R + b.frame.RightVector * x + b.frame.LookVector * z).Unit
	local rot = CFrame.fromRotationBetweenVectors(b.dir, d2) * b.frame * CFrame.Angles(0, twist or 0, 0)
	local cf = CFrame.new(b.center + d2 * (b.R + h)) * rot
	if tilt and tilt > 0 then
		cf *= CFrame.Angles(math.rad(b.rng:NextNumber(-tilt, tilt)), 0, math.rad(b.rng:NextNumber(-tilt, tilt)))
	end
	return cf
end

-- sagitta: how far a flat base of radius r lifts off the sphere at its rim -> sink by this much
local function sag(b: any, r: number): number
	return r * r / (2 * b.R)
end

local function disc(b: any, x: number, z: number, dia: number, lift: number, props: { [string]: any }): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(props.Thick or 0.3, dia, dia)
	props.Thick = nil
	props.CFrame = at(b, x, z, lift - sag(b, dia / 2)) * UPRIGHT
	return P(b, props)
end

local function cyl(b: any, base: CFrame, len: number, dia: number, props: { [string]: any }): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(len, dia, dia)
	props.CFrame = base * CFrame.new(0, len / 2, 0) * UPRIGHT
	return P(b, props)
end

local function ball(b: any, cf: CFrame, dia: number, props: { [string]: any }): BasePart
	props.Shape = Enum.PartType.Ball
	props.Size = Vector3.one * dia
	props.CFrame = cf
	return P(b, props)
end

local function emit(b: any, parent: Instance, props: { [string]: any }): ParticleEmitter?
	if #b.emitters >= b.q.emitters then
		return nil
	end
	local e = Instance.new("ParticleEmitter")
	e.LightEmission = 1
	e.LockedToPart = false
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	table.insert(b.emitters, e)
	return e
end

local function light(b: any, parent: Instance, color: Color3, range: number, brightness: number, always: boolean?)
	if not b.q.lights and not always then
		return
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
	table.insert(b.lights, l)
end

local function seq(a: number, z: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, z) })
end
local function seq3(a: number, m: number, z: number): NumberSequence
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(0.5, m), NumberSequenceKeypoint.new(1, z) })
end

local function beam(parent: Instance, a0: Attachment, a1: Attachment, props: { [string]: any }): Beam
	local bm = Instance.new("Beam")
	bm.Attachment0 = a0
	bm.Attachment1 = a1
	bm.LightInfluence = 0
	for k, v in props do
		(bm :: any)[k] = v
	end
	bm.Parent = parent
	return bm
end

local function attach(parent: BasePart, worldPos: Vector3, axisCf: CFrame?): Attachment
	local a = Instance.new("Attachment")
	-- parent FIRST: World* setters are relative to the parent part (an unparented attachment would store the
	-- world position as a local offset and the beam would render far away from the formation)
	a.Parent = parent
	if axisCf then
		a.WorldCFrame = CFrame.new(worldPos) * axisCf.Rotation
	else
		a.WorldPosition = worldPos
	end
	return a
end

-- invisible anchor part (for attachments / emitters / lights)
local function anchor(b: any, cf: CFrame, name: string?): BasePart
	-- satellites (extra DNA-spread copies) carry no particles / lights: one shared anchor, not one per effect
	if b.satellite and b.sharedAnchor then
		return b.sharedAnchor
	end
	local p = P(b, { Name = name or "Anchor", Size = Vector3.one * 0.2, CFrame = cf, Transparency = 1 })
	if b.satellite then
		b.sharedAnchor = p
	end
	return p
end

-- template clone (pivot at bottom centre), scaled to `height`; tint(part) optional
local AssetModels: Instance? = nil
do
	local assets = ReplicatedStorage:FindFirstChild("PF_Assets")
	AssetModels = assets and assets:FindFirstChild("Models")
end
local function asset(b: any, name: string, cf: CFrame, height: number, tint: ((BasePart) -> ())?): Model?
	local tpl = AssetModels and AssetModels:FindFirstChild(name)
	if not tpl or not tpl:IsA("Model") then
		return nil
	end
	local m = tpl:Clone()
	local h0 = tonumber(tpl:GetAttribute("PFHeight")) or 10
	m:ScaleTo(math.max(0.01, tpl:GetScale() * height / h0))
	m:PivotTo(cf)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = true, false, false, false, false
			if tint then
				tint(d)
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy() -- template FX are re-authored per formation; joints are dead weight once everything is anchored
		end
	end
	m.Parent = b.model
	return m
end

local function partsOf(inst: Instance): { BasePart }
	local list = {}
	if inst:IsA("BasePart") then
		table.insert(list, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

-- animation records (FormationLayer steps them only while the planet is near and motion is allowed)
local function sway(b: any, parts: { BasePart }, pivot: CFrame, amp: number, freq: number)
	table.insert(b.anims, { kind = "sway", parts = parts, pivot = pivot, amp = amp, freq = freq, phase = b.rng:NextNumber(0, TAU) })
end
local function spin(b: any, parts: { BasePart }, pivot: CFrame, speed: number, bob: number?, bobFreq: number?)
	table.insert(b.anims, { kind = "spin", parts = parts, pivot = pivot, speed = speed, bob = bob or 0, bobFreq = bobFreq or 0.25, phase = b.rng:NextNumber(0, TAU) })
end
local function glowPulse(b: any, parts: { BasePart }, lo: number, hi: number, freq: number)
	table.insert(b.anims, { kind = "glow", parts = parts, lo = lo, hi = hi, freq = math.min(freq, 1), phase = b.rng:NextNumber(0, TAU) })
end

local function shade(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

-- a faceted crystal: hexagonal-ish body (block, rotated 45 deg twin) + pointed tip (two wedges) + neon core
local function crystal(b: any, base: CFrame, h: number, w: number, color: Color3, glow: Color3, mat: Enum.Material?): { BasePart }
	-- body = translucent glowing facets (Neon reads luminous against space; Glass renders near-black there),
	-- or the given opaque material (ice); pointed two-wedge tip; bright inner core
	local out = {}
	local m = mat or Enum.Material.Neon
	local t = if m == Enum.Material.Neon then 0.42 else 0.05
	local bodyH = h * 0.72
	table.insert(out, P(b, { Name = "Facet", Size = Vector3.new(w, bodyH, w * 0.86), CFrame = base * CFrame.new(0, bodyH / 2, 0), Material = m, Color = color, Transparency = t }))
	table.insert(out, P(b, { Name = "Facet", Size = Vector3.new(w * 0.86, bodyH * 0.96, w), CFrame = base * CFrame.new(0, bodyH * 0.48, 0) * CFrame.Angles(0, math.rad(45), 0), Material = m, Color = shade(color, 0.85), Transparency = t + 0.05 }))
	local tipH = h - bodyH
	table.insert(out, P(b, { ClassName = "WedgePart", Name = "Tip", Size = Vector3.new(w, tipH, w * 0.43), CFrame = base * CFrame.new(0, bodyH + tipH / 2, w * 0.215), Material = m, Color = color, Transparency = t }))
	table.insert(out, P(b, { ClassName = "WedgePart", Name = "Tip", Size = Vector3.new(w, tipH, w * 0.43), CFrame = base * CFrame.new(0, bodyH + tipH / 2, -w * 0.215) * CFrame.Angles(0, math.pi, 0), Material = m, Color = shade(color, 0.9), Transparency = t }))
	table.insert(out, P(b, { Name = "Glow", Size = Vector3.new(w * 0.28, h * 0.8, w * 0.28), CFrame = base * CFrame.new(0, h * 0.42, 0), Material = Enum.Material.Neon, Color = glow, Transparency = 0.15 }))
	return out
end

---------------------------------------------------------------- builders: GENERIC

local B: { [string]: (b: any) -> () } = {}

B.impact = function(b) -- Ice Impact Site: frosted crater, shattered rim, frost glitter
	local blue = rgb(190, 228, 250)
	disc(b, 0, 0, 20, 0.02, { Name = "Frost", Material = Enum.Material.Snow, Color = rgb(232, 244, 252) })
	disc(b, 0, 0, 12, 0.1, { Name = "Bowl", Material = Enum.Material.Ice, Color = blue, Transparency = 0.15 })
	disc(b, 0, 0, 6, 0.16, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(150, 225, 255), Transparency = 0.45 })
	-- lean (scaled) art: 8 shards / 3 ice crystals instead of 12 / 4 (a shattered rim reads the same at scale)
	local rims = if b.lean then 8 else 12
	for k = 1, rims do
		local a = k / rims * TAU + b.rng:NextNumber(-0.15, 0.15)
		local r = 6.5 + b.rng:NextNumber(-0.6, 0.8)
		local cf = at(b, math.cos(a) * r, math.sin(a) * r, 0.2, -a, 8) * CFrame.Angles(math.rad(-25), 0, 0)
		P(b, { Name = "RimShard", Size = Vector3.new(b.rng:NextNumber(1.6, 2.6), b.rng:NextNumber(1.2, 2.4), b.rng:NextNumber(1.2, 1.8)), CFrame = cf, Material = Enum.Material.Ice, Color = shade(blue, b.rng:NextNumber(0.95, 1.08)) })
	end
	for k = 1, (if b.lean then 3 else 4) do
		local a = k / 4 * TAU + 0.4
		asset(b, "CrystalIce", at(b, math.cos(a) * 3, math.sin(a) * 3, -0.4, a, 12), b.rng:NextNumber(2.5, 4.5))
	end
	emit(b, anchor(b, at(b, 0, 0, 1)), { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(220, 245, 255)), Rate = 4, Lifetime = NumberRange.new(1, 2), Speed = NumberRange.new(0.3, 1), Size = seq(0.35, 0), SpreadAngle = Vector2.new(60, 60) })
end

B.ocean = function(b) -- Shallow Ocean: deep centre, turquoise shelf, foam ring, shimmer
	local w = b.pal.water or rgb(40, 116, 178)
	-- overlapping offset basins (shelf -> water -> deep) give an organic coastline, never a bullseye
	local lobes = if b.satellite then 3 else 7 -- extra DNA-grown seas are simpler (cost per instance)
	for k = 1, lobes do
		local a = k / lobes * TAU + b.rng:NextNumber(-0.4, 0.4)
		local r = if k == 1 then 0 else b.rng:NextNumber(6, 10)
		local x, z = math.cos(a) * r, math.sin(a) * r
		local d = b.rng:NextNumber(11, 17)
		disc(b, x, z, d + 4, 0.04, { Name = "Shelf", Material = Enum.Material.Glass, Color = rgb(70, 190, 210), Transparency = 0.3, Thick = 0.2 })
		disc(b, x * 0.9, z * 0.9, d, 0.08 + k * 0.003, { Name = "Water", Material = Enum.Material.Glass, Color = shade(w, b.rng:NextNumber(0.75, 0.9)), Transparency = 0.12, Thick = 0.2 })
		if k <= (if b.satellite then 1 else 3) then
			disc(b, x * 0.8 + 1, z * 0.8, d * 0.45, 0.12 + k * 0.003, { Name = "Deep", Material = Enum.Material.Glass, Color = shade(w, 0.55), Transparency = 0.1, Thick = 0.15 })
		end
	end
	emit(b, anchor(b, at(b, 0, 0, 0.6)), { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(200, 245, 255)), Rate = 3, Lifetime = NumberRange.new(0.8, 1.6), Speed = NumberRange.new(0, 0.3), Size = seq(0.5, 0), Shape = Enum.ParticleEmitterShape.Cylinder, ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume })
end

B.steam = function(b) -- Steam Pools: travertine terraces, turquoise pools, rising steam
	for k = 1, (if b.satellite then 2 else 3) do
		local a = k / 3 * TAU + 0.3
		local x, z = math.cos(a) * 4, math.sin(a) * 4
		disc(b, x, z, 8.5, 0.25 + k * 0.15, { Name = "Terrace", Material = Enum.Material.Limestone, Color = rgb(232, 222, 200), Thick = 0.6 })
		disc(b, x, z, 6.2, 0.45 + k * 0.15, { Name = "Pool", Material = Enum.Material.Glass, Color = rgb(90, 220, 210), Transparency = 0.15 })
		local glow = if b.satellite then nil else disc(b, x, z, 3, 0.5 + k * 0.15, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(150, 245, 235), Transparency = 0.55 })
		if glow and k <= 2 then
			emit(b, glow, { Texture = TEX.smoke, Color = ColorSequence.new(rgb(235, 245, 245)), LightEmission = 0, Rate = 2.5, Lifetime = NumberRange.new(2.5, 4), Speed = NumberRange.new(2, 3.5), Size = seq(1.4, 5), Transparency = seq(0.5, 1), SpreadAngle = Vector2.new(12, 12), EmissionDirection = Enum.NormalId.Right })
		end
	end
end

B.fissures = function(b) -- Plasma Fissures: branching neon veins recessed between dark basalt lips
	local col = b.def.color
	-- lean (scaled) art: half the segments at twice the length (same shape, half the parts)
	local steps, k = if b.lean then 3 else 6, if b.lean then 2 else 1
	for branch = 1, (if b.satellite then 2 else 3) do
		local a = branch / 3 * TAU + b.rng:NextNumber(-0.4, 0.4)
		local x, z, h = 0, 0, a
		for s = 1, steps do
			local len = b.rng:NextNumber(1.8, 2.6) * k
			local nx, nz = x + math.cos(h) * len, z + math.sin(h) * len
			local mx, mz = (x + nx) / 2, (z + nz) / 2
			local cf = at(b, mx, mz, 0.03, -h + math.pi / 2)
			local w = 0.75 - s * 0.05
			P(b, { Name = "Glow", Size = Vector3.new(w, 0.2, len + 0.3), CFrame = cf, Material = Enum.Material.Neon, Color = col })
			if s < steps then -- round node at the bend: one continuous vein instead of dashes
				P(b, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, w * 1.05, w * 1.05), CFrame = at(b, nx, nz, 0.03) * CFrame.Angles(0, 0, math.pi / 2), Material = Enum.Material.Neon, Color = col })
			end
			if b.lean then -- one dark bed under the vein instead of two angled lips: half the parts, same read at scale
				P(b, { Name = "Lip", Size = Vector3.new(2.1, 0.22, len + 0.9), CFrame = cf * CFrame.new(0, -0.1, 0), Material = Enum.Material.Basalt, Color = rgb(40, 34, 44) })
			else
				for side = -1, 1, 2 do
					P(b, { Name = "Lip", Size = Vector3.new(0.9, 0.22, len + 0.5), CFrame = cf * CFrame.new(side * 0.6, 0.02, 0) * CFrame.Angles(0, 0, math.rad(side * 28)), Material = Enum.Material.Basalt, Color = rgb(40, 34, 44) })
				end
			end
			x, z = nx, nz
			h += b.rng:NextNumber(-0.6, 0.6)
		end
	end
	light(b, anchor(b, at(b, 0, 0, 1.2)), col, 14, 1.4)
end

B.celestialFlora = function(b) -- Celestial Flora: tall starlit stalks with glowing bulbs, star-flowers, pollen
	local glow = rgb(215, 190, 255)
	local swayParts = {}
	-- lean (scaled) art: 6 stalks and 3 star-flowers of 3 petals (tiny petals vanish at scale anyway)
	local stalks = if b.lean then 6 else 7
	local flowers, petals = if b.lean then 3 else 4, if b.lean then 3 else 5
	for k = 1, stalks do
		local a = k / stalks * TAU + b.rng:NextNumber(-0.3, 0.3)
		local r = if k == 1 then 0 else b.rng:NextNumber(2.5, 5.5)
		local base = at(b, math.cos(a) * r, math.sin(a) * r, -0.3, a, 10)
		local h = b.rng:NextNumber(6, 11) * (if k == 1 then 1.3 else 1)
		local stalk = cyl(b, base, h, 0.45, { Name = "Stalk", Material = Enum.Material.SmoothPlastic, Color = rgb(70, 60, 110) })
		local bulb = ball(b, base * CFrame.new(0, h, 0), b.rng:NextNumber(1.4, 2.2), { Name = "Glow", Material = Enum.Material.Neon, Color = if k % 2 == 0 then glow else rgb(255, 245, 255), Transparency = 0.1 })
		table.insert(swayParts, stalk)
		table.insert(swayParts, bulb)
	end
	for k = 1, flowers do
		local a = k / flowers * TAU + 0.7
		local base = at(b, math.cos(a) * 3.5, math.sin(a) * 3.5, 0.6, a, 8)
		for petal = 1, petals do
			P(b, { Name = "Petal", Size = Vector3.new(0.3, 0.15, 1.6), CFrame = base * CFrame.Angles(0, petal / petals * TAU, 0) * CFrame.new(0, 0, 0.8) * CFrame.Angles(math.rad(-20), 0, 0), Material = Enum.Material.Neon, Color = if petal % 2 == 0 then rgb(255, 200, 250) else rgb(190, 170, 255), Transparency = 0.15 })
		end
		ball(b, base * CFrame.new(0, 0.2, 0), 0.6, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(255, 240, 180) })
	end
	sway(b, swayParts, b.siteCf, math.rad(3), 0.35)
	local fx = anchor(b, at(b, 0, 0, 5)) -- one anchor carries both the pollen and the light
	emit(b, fx, { Texture = TEX.sparkle, Color = ColorSequence.new(glow), Rate = 5, Lifetime = NumberRange.new(2, 3.5), Speed = NumberRange.new(0.5, 1.2), Size = seq3(0, 0.35, 0), SpreadAngle = Vector2.new(180, 180) })
	light(b, fx, glow, 18, 1.2)
end

---------------------------------------------------------------- builders: LIVING

local function canopyTree(b: any, base: CFrame, h: number, trunkCol: Color3, leaf: Color3, glow: Color3?, branches: number): { BasePart }
	-- flared, gently S-curved trunk; branches fan out from the upper trunk; a canopy cluster (3 lit balls + a
	-- glowing underside) sits on every branch tip, plus a crown: a wide umbrella silhouette readable from orbit
	local parts = {}
	local cf = base
	local seg = h * 0.55 / 4
	for s2 = 1, 4 do
		local d = h * 0.16 * (1.3 - s2 * 0.2)
		local bend = CFrame.Angles(math.rad(b.rng:NextNumber(-6, 6)), 0, math.rad(b.rng:NextNumber(-6, 6)))
		table.insert(parts, cyl(b, cf, seg + d * 0.4, d, { Name = "Trunk", Material = Enum.Material.Wood, Color = shade(trunkCol, 0.95 + s2 * 0.03) }))
		cf = cf * CFrame.new(0, seg, 0) * bend
	end
	local top = cf
	local light2 = shade(leaf, 1.25)
	local function cluster(at2: CFrame, r: number)
		for k = 1, 3 do
			local a2 = k / 3 * TAU + b.rng:NextNumber(-0.4, 0.4)
			table.insert(parts, ball(b, at2 * CFrame.new(math.cos(a2) * r * 0.45, b.rng:NextNumber(-0.2, 0.35) * r, math.sin(a2) * r * 0.45), r * b.rng:NextNumber(0.95, 1.25), { Name = "Leaves", Material = Enum.Material.LeafyGrass, Color = if k == 1 then light2 else shade(leaf, b.rng:NextNumber(0.9, 1.1)) }))
		end
		if glow then
			for k = 1, 3 do -- bioluminescent fruit hanging under the cluster
				local a2 = k / 3 * TAU + 0.5
				table.insert(parts, ball(b, at2 * CFrame.new(math.cos(a2) * r * 0.6, -r * 0.75, math.sin(a2) * r * 0.6), r * 0.22, { Name = "Glow", Material = Enum.Material.Neon, Color = glow }))
			end
		end
	end
	for k = 1, branches do
		local a2 = k / branches * TAU + b.rng:NextNumber(-0.25, 0.25)
		local startY = -seg * b.rng:NextNumber(0.2, 1.2)
		local out = CFrame.new(0, startY, 0) * CFrame.Angles(0, a2, 0) * CFrame.Angles(0, 0, -math.rad(b.rng:NextNumber(42, 62)))
		local len = h * b.rng:NextNumber(0.3, 0.4)
		local bcf = top * out
		table.insert(parts, cyl(b, bcf, len, h * 0.05, { Name = "Branch", Material = Enum.Material.Wood, Color = trunkCol }))
		cluster(bcf * CFrame.new(0, len, 0), h * 0.12)
	end
	cluster(top * CFrame.new(0, h * 0.12, 0), h * 0.15)
	if glow then
		for k = 1, 8 do
			local a2 = k / 8 * TAU
			table.insert(parts, ball(b, top * CFrame.new(math.cos(a2) * h * 0.3, -h * 0.04 + b.rng:NextNumber(-1, 1), math.sin(a2) * h * 0.3), h * 0.035, { Name = "Glow", Material = Enum.Material.Neon, Color = glow }))
		end
	end
	return parts
end

B.grass = function(b) -- Small Grass Patches: soft moss carpet, tufts, tiny flowers
	-- (2026-11-23: a patch is now one of up to 5 DNA-driven meadows, so each is lighter: 4 moss discs, 6 tufts)
	local moss = if b.satellite then 3 else 4
	for k = 1, moss do
		local a = k / moss * TAU
		local r = if k == 1 then 0 else b.rng:NextNumber(3, 6)
		disc(b, math.cos(a) * r, math.sin(a) * r, b.rng:NextNumber(6, 10), 0.06 + k * 0.004, { Name = "Moss", Material = Enum.Material.Grass, Color = shade(rgb(96, 168, 78), b.rng:NextNumber(0.85, 1.15)), Thick = 0.2 })
	end
	-- tall grass tufts (3 fanned blades each) and a few round shrubs give the meadow volume at planet scale
	local blades = {}
	for k = 1, math.floor((if b.satellite then 4 else 6) * b.q.detail) do
		local x, z = b.rng:NextNumber(-6.5, 6.5), b.rng:NextNumber(-6.5, 6.5)
		local base = at(b, x, z, 0, b.rng:NextNumber(0, TAU))
		local col = shade(rgb(120, 200, 86), b.rng:NextNumber(0.88, 1.15))
		for j = -1, 1 do
			local h = b.rng:NextNumber(2, 3.4)
			table.insert(blades, P(b, { ClassName = "WedgePart", Name = "Tuft", Size = Vector3.new(0.25, h, 1.1), CFrame = base * CFrame.Angles(0, j * 0.9, 0) * CFrame.Angles(math.rad(j * 14), 0, 0) * CFrame.new(0, h / 2, 0), Material = Enum.Material.Grass, Color = col }))
		end
		local _ = k
	end
	sway(b, blades, at(b, 0, 0, 0), 0.06, 0.35)
	for _ = 1, (if b.satellite then 2 else 3) do
		local sz = b.rng:NextNumber(1.8, 2.8)
		ball(b, at(b, b.rng:NextNumber(-5.5, 5.5), b.rng:NextNumber(-5.5, 5.5), sz * 0.3), sz, { Name = "Shrub", Material = Enum.Material.Grass, Color = shade(rgb(70, 140, 64), b.rng:NextNumber(0.85, 1.1)) })
	end
	for _ = 1, (if b.satellite then 2 else 3) do
		ball(b, at(b, b.rng:NextNumber(-5, 5), b.rng:NextNumber(-5, 5), 0.35), 0.5, { Name = "Glow", Material = Enum.Material.Neon, Color = if b.rng:NextNumber() < 0.5 then rgb(255, 230, 120) else rgb(255, 160, 220) })
	end
end

-- deterministic, STABLE element positions: element k always lands on the same spot whatever the total count
-- (golden-angle spiral + per-element jitter from its own rng stream), so DNA growth only ADDS elements
local GOLDEN = math.pi * (3 - math.sqrt(5))
local function elementSpot(b: any, k: number, spacing: number): (number, number)
	local rng = Random.new(Art.hash(b.def.id, k, b.elSeed))
	if k == 1 then
		return rng:NextNumber(-0.4, 0.4), rng:NextNumber(-0.4, 0.4)
	end
	local r = spacing * math.sqrt(k - 1) * rng:NextNumber(0.85, 1.15)
	local a = (k - 1) * GOLDEN + rng:NextNumber(-0.25, 0.25)
	return math.cos(a) * r, math.sin(a) * r
end

B.forest = function(b) -- First Forest: a grove whose tree count follows Life DNA (FormationDensity)
	local count = if b.elements > 0 then b.elements else math.max(4, math.floor(6 * b.q.detail))
	local names = Density.variants("trees", b.level)
	local spread = 3.4 * math.sqrt(count)
	disc(b, 0, 0, 6 + spread * 2, 0.05, { Name = "Floor", Material = Enum.Material.Grass, Color = rgb(70, 130, 62), Thick = 0.2 })
	local leaves = {}
	for k = 1, count do
		local x, z = elementSpot(b, k, 3.4)
		local er = Random.new(Art.hash(b.def.id, k, b.elSeed, "t"))
		local name = names[er:NextInteger(1, #names)]
		local m = asset(b, name, at(b, x, z, -0.5, er:NextNumber(0, TAU), 6), er:NextNumber(7, 11))
		if m then
			for _, p in partsOf(m) do
				if string.sub(p.Name, 1, 6) == "Leaves" then
					p.Color = shade(p.Color, er:NextNumber(0.88, 1.12))
					table.insert(leaves, p)
				end
			end
		end
	end
	for _ = 1, math.min(3, 1 + math.floor(count / 3)) do
		ball(b, at(b, b.rng:NextNumber(-spread, spread), b.rng:NextNumber(-spread, spread), 0.4), b.rng:NextNumber(1.6, 2.6), { Name = "Shrub", Material = Enum.Material.LeafyGrass, Color = rgb(64, 128, 58) })
	end
	sway(b, leaves, b.siteCf, math.rad(1.6), 0.3)
end

B.ancientTree = function(b) -- Ancient Tree: buttress roots, bent colossal trunk, layered canopy, glow fruit
	local root = at(b, 0, 0, -0.8)
	disc(b, 0, 0, 16, 0.05, { Name = "Moss", Material = Enum.Material.Grass, Color = rgb(70, 140, 62), Thick = 0.25 })
	for k = 1, 6 do
		local a = k / 6 * TAU + b.rng:NextNumber(-0.2, 0.2)
		P(b, { ClassName = "WedgePart", Name = "Root", Size = Vector3.new(1.2, 3.2, 4.2), CFrame = root * CFrame.Angles(0, -a, 0) * CFrame.new(0, 1.3, 2.6) * CFrame.Angles(0, math.pi, 0), Material = Enum.Material.Wood, Color = rgb(92, 66, 46) })
	end
	local parts = canopyTree(b, root, 24, rgb(98, 70, 48), rgb(86, 176, 78), rgb(150, 255, 190), 5)
	for k = 1, 4 do
		local a = k / 4 * TAU + 0.5
		local vineTop = root * CFrame.new(math.cos(a) * 4.5, 15, math.sin(a) * 4.5)
		local an = anchor(b, vineTop)
		local a0 = attach(an, vineTop.Position)
		local a1 = attach(an, (vineTop * CFrame.new(0, -6, 0)).Position)
		beam(an, a0, a1, { Width0 = 0.35, Width1 = 0.15, Color = ColorSequence.new(rgb(90, 170, 80)), Transparency = seq(0.1, 0.4), FaceCamera = true, LightEmission = 0.1 })
	end
	sway(b, parts, root * CFrame.new(0, 2, 0), math.rad(1.2), 0.22)
	light(b, anchor(b, root * CFrame.new(0, 16, 0)), rgb(150, 255, 190), 20, 0.9)
end

B.glowGrove = function(b) -- Bioluminescent Grove: bulb plants, giant glowing mushrooms, spore motes
	local cyan, pink = rgb(70, 255, 220), rgb(255, 110, 220)
	disc(b, 0, 0, 16, 0.05, { Name = "Moss", Material = Enum.Material.Grass, Color = rgb(40, 90, 70), Thick = 0.2 })
	local glows = {}
	for k = 1, 4 do
		local a = k / 4 * TAU + b.rng:NextNumber(-0.3, 0.3)
		local base = at(b, math.cos(a) * 4, math.sin(a) * 4, -0.2, a, 10)
		local h = b.rng:NextNumber(3, 5.5)
		cyl(b, base, h, 0.9, { Name = "Stalk", Material = Enum.Material.SmoothPlastic, Color = rgb(225, 230, 215) })
		-- glowing translucent dome cap (squashed sphere mesh) over a bright core, with a gill ring that shows
		-- from the side: reads as bioluminescent from orbit and up close
		local capCol = if k % 2 == 0 then cyan else pink
		local capCf = base * CFrame.new(0, h + 0.2, 0)
		local cap = P(b, { Name = "Glow", Size = Vector3.new(h * 1.15, h * 0.55, h * 1.15), CFrame = capCf, Material = Enum.Material.Neon, Color = capCol:Lerp(rgb(60, 30, 120), 0.35), Transparency = 0.3 })
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = cap
		local core = P(b, { Name = "CapCore", Size = Vector3.new(h * 0.6, h * 0.3, h * 0.6), CFrame = capCf * CFrame.new(0, 0.1, 0), Material = Enum.Material.Neon, Color = capCol:Lerp(Color3.new(1, 1, 1), 0.45) })
		local coreMesh = Instance.new("SpecialMesh")
		coreMesh.MeshType = Enum.MeshType.Sphere
		coreMesh.Parent = core
		table.insert(glows, cap)
		P(b, { Name = "Gills", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.25, h * 1.0, h * 1.0), CFrame = base * CFrame.new(0, h - 0.05, 0) * UPRIGHT, Material = Enum.Material.Neon, Color = capCol })
	end
	for k = 1, 7 do
		local base = at(b, b.rng:NextNumber(-6, 6), b.rng:NextNumber(-6, 6), -0.2, 0, 14)
		local h = b.rng:NextNumber(1.5, 3)
		cyl(b, base, h, 0.25, { Name = "Stem", Material = Enum.Material.SmoothPlastic, Color = rgb(40, 90, 80) })
		table.insert(glows, ball(b, base * CFrame.new(0, h, 0), b.rng:NextNumber(0.8, 1.3), { Name = "Glow", Material = Enum.Material.Neon, Color = if k % 3 == 0 then pink else cyan }))
		local _ = k
	end
	glowPulse(b, glows, 0, 0.35, 0.4)
	emit(b, anchor(b, at(b, 0, 0, 3)), { Texture = TEX.sparkle, Color = ColorSequence.new(cyan, pink), Rate = 6, Lifetime = NumberRange.new(2, 4), Speed = NumberRange.new(0.4, 1), Size = seq3(0, 0.3, 0), SpreadAngle = Vector2.new(180, 180) })
	light(b, anchor(b, at(b, 0, 0, 4)), cyan, 18, 1.1)
end

B.waterfall = function(b) -- Living Waterfall: mossy cliff, animated falling water ribbons, mist, plunge pool, stream
	local rock, moss = rgb(104, 110, 100), rgb(80, 150, 70)
	local cliffBase = at(b, 4, 0, -1.5)
	local blocks = { { 0, 6, 0, 9, 14, 8 }, { -1.5, 13.5, 0.5, 8, 5, 7 }, { 2.5, 4, 4, 7, 10, 6 }, { 2, 5, -4.5, 7, 12, 6 }, { -2, 2.5, 4.5, 6, 6, 4 }, { 3.5, 17, 0, 6, 6, 9 }, { 2, 21, -1, 5, 3, 7 }, { 1, 9, 5.5, 4, 8, 3 } }
	for _, bl in blocks do
		P(b, { Name = "Cliff", Size = Vector3.new(bl[4], bl[5], bl[6]), CFrame = cliffBase * CFrame.new(bl[1], bl[2], bl[3]) * CFrame.Angles(math.rad(b.rng:NextNumber(-6, 6)), math.rad(b.rng:NextNumber(-10, 10)), math.rad(b.rng:NextNumber(-6, 6))), Material = Enum.Material.Slate, Color = shade(rock, b.rng:NextNumber(0.9, 1.08)) })
	end
	P(b, { Name = "MossTop", Size = Vector3.new(8.5, 0.8, 6.5), CFrame = cliffBase * CFrame.new(-1.3, 16.2, 0.4), Material = Enum.Material.Grass, Color = moss })
	disc(b, -4, 0, 11, 0.12, { Name = "Pool", Material = Enum.Material.Glass, Color = rgb(60, 150, 200), Transparency = 0.15 })
	local top = (cliffBase * CFrame.new(-5.2, 16.2, 0)).Position
	local bottom = at(b, -4, 0, 0.3).Position
	local an = anchor(b, CFrame.new(top))
	local a0 = attach(an, top)
	local a1 = attach(an, bottom)
	beam(an, a0, a1, { Width0 = 5, Width1 = 6.5, Color = ColorSequence.new(rgb(235, 250, 255), rgb(120, 205, 245)), Transparency = seq(0.05, 0.3), Texture = TEX.smoke, TextureMode = Enum.TextureMode.Wrap, TextureLength = 4, TextureSpeed = -1.6, LightEmission = 0.55, FaceCamera = true, CurveSize0 = -2.2, Segments = 12 })
	beam(an, a0, a1, { Width0 = 3, Width1 = 4, Color = ColorSequence.new(rgb(255, 255, 255)), Transparency = seq(0.25, 0.6), Texture = TEX.sparkle, TextureMode = Enum.TextureMode.Wrap, TextureLength = 2, TextureSpeed = -2.6, LightEmission = 0.8, FaceCamera = true, CurveSize0 = -2.2, Segments = 12 })
	P(b, { Name = "Glow", Size = Vector3.new(0.4, 14, 4.6), CFrame = cliffBase * CFrame.new(-4.75, 8.5, 0), Material = Enum.Material.Neon, Color = rgb(170, 225, 255), Transparency = 0.55 })
	emit(b, anchor(b, at(b, -4, 0, 0.6)), { Texture = TEX.smoke, Color = ColorSequence.new(rgb(235, 248, 255)), LightEmission = 0.1, Rate = 4, Lifetime = NumberRange.new(1.5, 2.5), Speed = NumberRange.new(1, 2), Size = seq(1.5, 4), Transparency = seq(0.55, 1), SpreadAngle = Vector2.new(70, 70) })
	for s = 1, 5 do
		local x = -4 - 5 - s * 2.2
		disc(b, x, b.rng:NextNumber(-0.6, 0.6), 3.2 - s * 0.25, 0.1, { Name = "Stream", Material = Enum.Material.Glass, Color = rgb(70, 160, 210), Transparency = 0.2 })
	end
	for _ = 1, 5 do
		ball(b, at(b, b.rng:NextNumber(-9, 1), b.rng:NextNumber(-6, 6), 0.3), b.rng:NextNumber(1.6, 2.8), { Name = "Fern", Material = Enum.Material.LeafyGrass, Color = rgb(70, 150, 66) })
	end
end

B.worldTree = function(b) -- Giant World Tree: colossal glowing tree, surface roots, two-tier canopy, rising spores
	local root = at(b, 0, 0, -1.2)
	disc(b, 0, 0, 26, 0.05, { Name = "Moss", Material = Enum.Material.Grass, Color = rgb(70, 145, 64), Thick = 0.3 })
	for k = 1, 8 do
		local a = k / 8 * TAU + b.rng:NextNumber(-0.15, 0.15)
		for s = 1, 3 do
			local r0 = 2.5 + (s - 1) * 3.2
			local x, z = math.cos(a) * (r0 + 1.6), math.sin(a) * (r0 + 1.6)
			P(b, { Name = "Root", Size = Vector3.new(1.6 - s * 0.35, 1.4 - s * 0.3, 3.6), CFrame = at(b, x, z, 0.25 - s * 0.12, -a + math.pi / 2), Material = Enum.Material.Wood, Color = rgb(96, 70, 50) })
		end
	end
	local parts = canopyTree(b, root, 44, rgb(112, 82, 58), rgb(110, 210, 110), rgb(160, 255, 200), 7)
	local heart = P(b, { Name = "Glow", Size = Vector3.new(0.9, 14, 0.9), CFrame = root * CFrame.new(0, 9, 0), Material = Enum.Material.Neon, Color = rgb(170, 255, 200), Transparency = 0.35 })
	table.insert(parts, heart)
	sway(b, parts, root * CFrame.new(0, 3, 0), math.rad(0.9), 0.18)
	glowPulse(b, { heart }, 0.25, 0.55, 0.3)
	emit(b, anchor(b, root * CFrame.new(0, 26, 0)), { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(200, 255, 170), rgb(140, 255, 220)), Rate = 8, Lifetime = NumberRange.new(3, 5), Speed = NumberRange.new(1, 2.5), Size = seq3(0, 0.45, 0), SpreadAngle = Vector2.new(70, 70), Acceleration = Vector3.zero })
	light(b, anchor(b, root * CFrame.new(0, 24, 0)), rgb(170, 255, 200), 34, 1.4, true)
end
---------------------------------------------------------------- builders: FROZEN

-- vertical light curtain (aurora): beam between two attachments whose up axis is the local normal
local function curtain(b: any, an: BasePart, p0: Vector3, p1: Vector3, up: Vector3, width: number, colors: ColorSequence, curve: number): Beam
	local flow = (p1 - p0).Unit
	local rot = CFrame.fromMatrix(Vector3.zero, flow, up)
	local a0 = attach(an, p0, rot)
	local a1 = attach(an, p1, rot)
	return beam(an, a0, a1, { Width0 = width, Width1 = width, Color = colors, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.25, 0.45), NumberSequenceKeypoint.new(0.75, 0.45), NumberSequenceKeypoint.new(1, 1) }), LightEmission = 1, FaceCamera = false, Segments = 24, CurveSize0 = curve, CurveSize1 = -curve })
end
Art.curtain = curtain

local AURORA = ColorSequence.new({ ColorSequenceKeypoint.new(0, rgb(90, 255, 180)), ColorSequenceKeypoint.new(0.45, rgb(80, 210, 255)), ColorSequenceKeypoint.new(1, rgb(190, 120, 255)) })

B.frozenLake = function(b) -- Frozen Lake: clear ice sheet with glowing depths, cracks, snow banks, frozen boulders
	disc(b, 0, 0, 26, 0.03, { Name = "Snow", Material = Enum.Material.Snow, Color = rgb(214, 228, 242), Transparency = 0.35, Thick = 0.25 })
	disc(b, 0, 0, 20, 0.09, { Name = "Depth", Material = Enum.Material.Neon, Color = rgb(70, 170, 235), Transparency = 0.6, Thick = 0.15 })
	disc(b, 0, 0, 21, 0.16, { Name = "Ice", Material = Enum.Material.Ice, Color = rgb(175, 222, 248), Transparency = 0.3, Thick = 0.15 })
	for k = 1, (if b.satellite then 3 else 6) do
		local a = b.rng:NextNumber(0, TAU)
		local r = b.rng:NextNumber(1, 6)
		P(b, { Name = "Glow", Size = Vector3.new(0.12, 0.08, b.rng:NextNumber(3, 7)), CFrame = at(b, math.cos(a) * r, math.sin(a) * r, 0.24 - sag(b, r), b.rng:NextNumber(0, TAU)), Material = Enum.Material.Neon, Color = rgb(225, 248, 255), Transparency = 0.25 })
		local _ = k
	end
	local nBoulders = if b.satellite then 2 else 4
	for k = 1, nBoulders do
		local a = k / nBoulders * TAU + 0.6
		ball(b, at(b, math.cos(a) * 11.5, math.sin(a) * 11.5, 0.4 - sag(b, 11.5)), b.rng:NextNumber(2.2, 3.6), { Name = "Boulder", Material = Enum.Material.Glacier, Color = rgb(205, 228, 245) })
	end
end

B.iceSpikes = function(b) -- Ice Spikes: a field of translucent spires whose count follows Water DNA
	local count = if b.elements > 0 then b.elements else 7
	disc(b, 0, 0, 8 + 4 * math.sqrt(count), 0.04, { Name = "Snow", Material = Enum.Material.Snow, Color = rgb(214, 228, 242), Transparency = 0.35, Thick = 0.25 })
	for k = 1, count do
		local x, z = elementSpot(b, k, 2.4)
		local er = Random.new(Art.hash(b.def.id, k, b.elSeed, "s"))
		local lean = CFrame.Angles(math.rad(if k == 1 then 0 else -12), 0, 0)
		asset(b, "CrystalIce", at(b, x, z, -0.5, math.atan2(z, x) + math.pi / 2, 6) * lean, er:NextNumber(5, 12) * (if k == 1 then 1.3 else 1))
	end
	light(b, anchor(b, at(b, 0, 0, 5)), rgb(150, 220, 255), 16, 0.9)
end

B.glacier = function(b) -- Glacier Ridge: long ridge of fractured blue ice, snow caps, glowing crevasse
	local heading = b.rng:NextNumber(0, TAU)
	local hx, hz = math.cos(heading), math.sin(heading)
	for k = -4, 4 do
		local t = k * 3.4
		local x, z = hx * t + b.rng:NextNumber(-0.8, 0.8), hz * t + b.rng:NextNumber(-0.8, 0.8)
		local h = 7.5 - math.abs(k) * 0.9 + b.rng:NextNumber(-0.8, 0.8)
		local base = at(b, x, z, -0.8, -heading, 7)
		P(b, { Name = "Glacier", Size = Vector3.new(b.rng:NextNumber(3.6, 4.6), h, b.rng:NextNumber(4.5, 6.5)), CFrame = base * CFrame.new(0, h / 2, 0), Material = Enum.Material.Glacier, Color = shade(rgb(205, 230, 248), b.rng:NextNumber(0.92, 1.05)) })
		P(b, { Name = "SnowCap", Size = Vector3.new(4, 0.6, 5.5), CFrame = base * CFrame.new(0, h + 0.2, 0) * CFrame.Angles(math.rad(b.rng:NextNumber(-8, 8)), 0, 0), Material = Enum.Material.Snow, Color = rgb(244, 249, 255) })
	end
	for k = -3, 3 do
		local t = k * 3.4 + 1.7
		P(b, { Name = "Glow", Size = Vector3.new(0.35, 2.6, 3.2), CFrame = at(b, hx * t + hz * 2.6, hz * t - hx * 2.6, 0.6, -heading), Material = Enum.Material.Neon, Color = rgb(110, 205, 255), Transparency = 0.25 })
	end
	light(b, anchor(b, at(b, 0, 0, 6)), rgb(130, 210, 255), 22, 0.8)
end

B.iceCave = function(b) -- Crystal Ice Cave: arched mouth of ice blocks, glowing heart, icicles
	local base = at(b, 0, 0, -0.5)
	disc(b, 0, 0, 16, 0.04, { Name = "Snow", Material = Enum.Material.Snow, Color = rgb(214, 228, 242), Transparency = 0.35, Thick = 0.25 })
	for k = 0, 8 do
		local a = k / 8 * math.pi
		P(b, { Name = "Arch", Size = Vector3.new(2.6, 2.4, 5), CFrame = base * CFrame.new(math.cos(a) * 6, math.sin(a) * 6 + 0.4, 0) * CFrame.Angles(0, 0, a - math.pi / 2), Material = Enum.Material.Ice, Color = shade(rgb(190, 228, 250), b.rng:NextNumber(0.93, 1.06)), Transparency = 0.12 })
	end
	P(b, { Name = "Back", Size = Vector3.new(11, 7, 1.2), CFrame = base * CFrame.new(0, 3.2, -2.6), Material = Enum.Material.Glacier, Color = rgb(150, 200, 235) })
	local heart = P(b, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 7.5, 7.5), CFrame = base * CFrame.new(0, 3.4, -1.9) * CFrame.Angles(0, math.pi / 2, 0), Material = Enum.Material.Neon, Color = rgb(90, 200, 255), Transparency = 0.25 })
	for k = 1, 6 do
		P(b, { ClassName = "WedgePart", Name = "Icicle", Size = Vector3.new(0.5, b.rng:NextNumber(1.2, 2.4), 0.5), CFrame = base * CFrame.new(-4 + k * 1.15, 5.6, 1.6) * CFrame.Angles(math.pi, 0, 0), Material = Enum.Material.Ice, Color = rgb(220, 242, 255) })
	end
	glowPulse(b, { heart }, 0.15, 0.4, 0.35)
	light(b, heart, rgb(90, 200, 255), 18, 1.4)
end

B.aurora = function(b) -- Aurora Field: layered undulating light curtains over a frozen plain
	disc(b, 0, 0, 24, 0.04, { Name = "Snow", Material = Enum.Material.Snow, Color = rgb(214, 228, 242), Transparency = 0.35, Thick = 0.25 })
	for k = 1, 5 do
		asset(b, "CrystalIce", at(b, b.rng:NextNumber(-8, 8), b.rng:NextNumber(-8, 8), -0.5, b.rng:NextNumber(0, TAU), 10), b.rng:NextNumber(3, 6))
		local _ = k
	end
	local an = anchor(b, at(b, 0, 0, 20), "AuroraAnchor")
	local up = b.dir
	local beams = {}
	for k = 1, 4 do
		local z = (k - 2.5) * 5
		local p0 = at(b, -18, z, 14 + k * 3).Position
		local p1 = at(b, 18, z + 4, 14 + k * 3).Position
		local bm = curtain(b, an, p0, p1, up, 9 + k, AURORA, 7)
		table.insert(beams, bm)
	end
	table.insert(b.anims, { kind = "aurora", beams = beams, amp = 6, base = 7, freq = 0.12, phase = b.rng:NextNumber(0, TAU) })
	light(b, an, rgb(110, 255, 190), 30, 0.7)
end

B.frozenCrown = function(b) -- Frozen Crown: ring of levitating ice monoliths turning around a refracting light shaft
	local base = at(b, 0, 0, -0.6)
	disc(b, 0, 0, 30, 0.04, { Name = "Snow", Material = Enum.Material.Snow, Color = rgb(214, 228, 242), Transparency = 0.35, Thick = 0.3 })
	disc(b, 0, 0, 12, 0.14, { Name = "Dais", Material = Enum.Material.Glacier, Color = rgb(200, 228, 248), Thick = 1 })
	for k = 1, 6 do
		local a = k / 6 * TAU
		asset(b, "CrystalIce", at(b, math.cos(a) * 4.5, math.sin(a) * 4.5, -0.3, -a, 10) * CFrame.Angles(math.rad(-14), 0, 0), b.rng:NextNumber(5, 8))
	end
	local ring = {}
	for k = 1, 8 do
		local a = k / 8 * TAU
		local h = b.rng:NextNumber(14, 20)
		local cf = base * CFrame.new(math.cos(a) * 13, 5 + h / 2 + b.rng:NextNumber(-1, 1.5), math.sin(a) * 13) * CFrame.Angles(0, -a, math.rad(b.rng:NextNumber(-6, 6)))
		table.insert(ring, P(b, { Name = "Monolith", Size = Vector3.new(2.4, h, 3.4), CFrame = cf, Material = Enum.Material.Ice, Color = rgb(185, 225, 252), Transparency = 0.08 }))
		for side = 0, 1 do -- tapered point
			table.insert(ring, P(b, { ClassName = "WedgePart", Name = "Tip", Size = Vector3.new(2.4, 4.5, 1.7), CFrame = cf * CFrame.new(0, h / 2 + 2.25, if side == 0 then 0.85 else -0.85) * CFrame.Angles(0, side * math.pi, 0), Material = Enum.Material.Ice, Color = rgb(205, 236, 255), Transparency = 0.08 }))
		end
		table.insert(ring, P(b, { Name = "Glow", Size = Vector3.new(0.5, h * 0.85, 0.5), CFrame = cf * CFrame.new(1.25, 0, 0), Material = Enum.Material.Neon, Color = rgb(150, 230, 255), Transparency = 0.2 }))
	end
	spin(b, ring, base, 0.12, 0.6, 0.2)
	local shaft = P(b, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(44, 2.6, 2.6), CFrame = base * CFrame.new(0, 22, 0) * UPRIGHT, Material = Enum.Material.Neon, Color = rgb(200, 245, 255), Transparency = 0.55 })
	glowPulse(b, { shaft }, 0.45, 0.7, 0.25)
	emit(b, anchor(b, base * CFrame.new(0, 3, 0)), { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(220, 245, 255)), Rate = 6, Lifetime = NumberRange.new(2, 3), Speed = NumberRange.new(2, 5), Size = seq3(0, 0.5, 0), SpreadAngle = Vector2.new(15, 15), EmissionDirection = Enum.NormalId.Top })
	light(b, anchor(b, base * CFrame.new(0, 14, 0)), rgb(170, 230, 255), 36, 1.5, true)
end

---------------------------------------------------------------- builders: VOLCANIC

local function magmaVeins(b: any, branches: number, steps0: number, width: number, color: Color3, lipColor: Color3)
	-- lean (scaled) art: half the segments at twice the length (same crack, half the parts)
	local steps = if b.lean then math.ceil(steps0 / 2) else steps0
	local k = steps0 / steps
	local nb = if b.satellite then math.max(2, branches - 1) else branches
	for br = 1, nb do
		local x, z, h = 0, 0, br / nb * TAU + b.rng:NextNumber(-0.4, 0.4)
		for s = 1, steps do
			local len = b.rng:NextNumber(1.9, 2.8) * k
			local nx, nz = x + math.cos(h) * len, z + math.sin(h) * len
			local cf = at(b, (x + nx) / 2, (z + nz) / 2, 0.02, -h + math.pi / 2)
			local w = width * (1.1 - s / steps * 0.6)
			P(b, { Name = "Glow", Size = Vector3.new(w, 0.26, len + 0.35), CFrame = cf, Material = Enum.Material.Neon, Color = color })
			if b.lean then -- one basalt bed under the molten strip instead of two lips (half the parts, same read at scale)
				P(b, { Name = "Lip", Size = Vector3.new(w * 1.7 + 0.6, 0.26, len + 0.9), CFrame = cf * CFrame.new(0, -0.1, 0), Material = Enum.Material.Basalt, Color = lipColor })
			else
				for side = -1, 1, 2 do
					-- low lips (top below the molten strip) so the crack reads as one continuous glowing line
					P(b, { Name = "Lip", Size = Vector3.new(w * 0.7 + 0.3, 0.26, len + 0.9), CFrame = cf * CFrame.new(side * (w * 0.5 + 0.3), -0.04, 0) * CFrame.Angles(0, 0, math.rad(side * 12)), Material = Enum.Material.Basalt, Color = lipColor })
				end
			end
			-- round molten joint closes the gap on the outside of each bend (no "ladder" look)
			if s < steps then
				P(b, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.22, w * 1.05, w * 1.05), CFrame = at(b, nx, nz, 0.02) * CFrame.Angles(0, 0, math.pi / 2), Material = Enum.Material.Neon, Color = color })
			end
			x, z = nx, nz
			h += b.rng:NextNumber(-0.55, 0.55)
		end
	end
end

B.thermalCrack = function(b) -- Thermal Crack: widening magma fissures between basalt lips, embers
	magmaVeins(b, 4, 6, 1.1, rgb(255, 120, 35), rgb(40, 32, 32))
	emit(b, anchor(b, at(b, 0, 0, 0.5)), { Texture = TEX.sparks, Color = ColorSequence.new(rgb(255, 200, 110), rgb(255, 90, 30)), Rate = 6, Lifetime = NumberRange.new(1, 2), Speed = NumberRange.new(2, 5), Size = seq(0.3, 0), SpreadAngle = Vector2.new(30, 30), EmissionDirection = Enum.NormalId.Top })
	light(b, anchor(b, at(b, 0, 0, 1.5)), rgb(255, 120, 40), 16, 1.4)
end

B.lavaPool = function(b) -- Lava Pool: basalt caldera rim, molten surface with drifting crust, bubbling
	-- extra DNA-grown pools: 8 wider rim blocks instead of 12 (same closed caldera, fewer parts)
	local rims = if b.satellite then 8 else 12
	local rimW = if b.satellite then 4.1 else 2.8
	for k = 1, rims do
		local a = k / rims * TAU
		P(b, { Name = "Rim", Size = Vector3.new(rimW, b.rng:NextNumber(1.6, 2.8), 2.2), CFrame = at(b, math.cos(a) * 6.6, math.sin(a) * 6.6, 0.4 - sag(b, 6.6), -a, 6) * CFrame.Angles(math.rad(18), 0, 0), Material = Enum.Material.Basalt, Color = shade(rgb(52, 42, 42), b.rng:NextNumber(0.85, 1.1)) })
	end
	local lava = disc(b, 0, 0, 12, 0.12, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(255, 105, 25) })
	for _ = 1, (if b.satellite then 2 else 4) do
		disc(b, b.rng:NextNumber(-3, 3), b.rng:NextNumber(-3, 3), b.rng:NextNumber(1.6, 3), 0.2, { Name = "Crust", Material = Enum.Material.CrackedLava, Color = rgb(70, 40, 30), Thick = 0.12 })
	end
	glowPulse(b, { lava }, 0, 0.2, 0.5)
	emit(b, lava, { Texture = TEX.fire, Color = ColorSequence.new(rgb(255, 200, 90), rgb(255, 80, 20)), Rate = 5, Lifetime = NumberRange.new(0.5, 1), Speed = NumberRange.new(1, 3), Size = seq(1.2, 0), SpreadAngle = Vector2.new(20, 20), EmissionDirection = Enum.NormalId.Right })
	light(b, lava, rgb(255, 110, 30), 20, 2)
end

B.basalt = function(b) -- Basalt Spires: tight cluster of columnar basalt, glowing seams, ash
	local cells = { { 0, 0 } }
	for ring = 1, 2 do
		for k = 0, ring * 6 - 1 do
			local a = k / (ring * 6) * TAU
			table.insert(cells, { math.cos(a) * ring * 1.9, math.sin(a) * ring * 1.9 })
		end
	end
	for i, c in cells do
		local dist = math.sqrt(c[1] ^ 2 + c[2] ^ 2)
		local h = 12 - dist * 1.6 + b.rng:NextNumber(-1.5, 1.5)
		local base = at(b, c[1], c[2], -0.8, b.rng:NextNumber(0, TAU), 4)
		cyl(b, base, h, 1.9, { Name = "Column", Material = Enum.Material.Basalt, Color = shade(rgb(52, 46, 48), b.rng:NextNumber(0.85, 1.12)) })
		P(b, { Name = "ColumnTop", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 1.95, 1.95), CFrame = base * CFrame.new(0, h, 0) * CFrame.Angles(math.rad(b.rng:NextNumber(-8, 8)), 0, 0) * UPRIGHT, Material = Enum.Material.Slate, Color = rgb(70, 64, 66) })
		if i % 4 == 0 then
			P(b, { Name = "Glow", Size = Vector3.new(0.2, h * 0.6, 0.35), CFrame = base * CFrame.new(0.95, h * 0.4, 0), Material = Enum.Material.Neon, Color = rgb(255, 110, 30) })
		end
	end
	emit(b, anchor(b, at(b, 0, 0, 12)), { Texture = TEX.smoke, Color = ColorSequence.new(rgb(80, 72, 72)), LightEmission = 0, Rate = 1.5, Lifetime = NumberRange.new(3, 5), Speed = NumberRange.new(1.5, 3), Size = seq(2, 6), Transparency = seq(0.6, 1), EmissionDirection = Enum.NormalId.Top })
end

B.magmaRiver = function(b) -- Magma River: wide flowing ribbon of lava with scrolling surface, basalt banks
	local heading = b.rng:NextNumber(0, TAU)
	local an = anchor(b, at(b, 0, 0, 0.3), "FlowAnchor")
	local x, z, h = -math.cos(heading) * 16, -math.sin(heading) * 16, heading
	local prev = nil
	for s = 1, 12 do
		local len = 2.8
		local nx, nz = x + math.cos(h) * len, z + math.sin(h) * len
		local cf = at(b, (x + nx) / 2, (z + nz) / 2, 0.02, -h + math.pi / 2)
		local w = 2.6 + math.sin(s * 0.7) * 0.5
		P(b, { Name = "Glow", Size = Vector3.new(w, 0.2, len + 0.5), CFrame = cf, Material = Enum.Material.Neon, Color = rgb(255, 105, 25) })
		for side = -1, 1, 2 do
			P(b, { Name = "Bank", Size = Vector3.new(1.2, 0.7, len + 0.4), CFrame = cf * CFrame.new(side * (w * 0.5 + 0.5), 0.2, 0) * CFrame.Angles(0, 0, math.rad(side * 16)), Material = Enum.Material.Basalt, Color = rgb(44, 36, 36) })
		end
		local here = at(b, x, z, 0.25)
		if prev and s % 2 == 0 then
			local flowRot = CFrame.fromMatrix(Vector3.zero, (here.Position - prev.Position).Unit, b.dir)
			beam(an, attach(an, prev.Position, flowRot), attach(an, here.Position, flowRot), { Width0 = w * 0.8, Width1 = w * 0.8, Color = ColorSequence.new(rgb(255, 230, 120), rgb(255, 150, 40)), Transparency = NumberSequence.new(0.35), Texture = TEX.fire, TextureMode = Enum.TextureMode.Wrap, TextureLength = 3, TextureSpeed = 0.8, LightEmission = 0.8, FaceCamera = false, Segments = 2 })
			prev = here
		elseif not prev then
			prev = here
		end
		x, z = nx, nz
		h += b.rng:NextNumber(-0.3, 0.3)
	end
	emit(b, an, { Texture = TEX.sparks, Color = ColorSequence.new(rgb(255, 200, 110)), Rate = 5, Lifetime = NumberRange.new(1, 2), Speed = NumberRange.new(2, 4), Size = seq(0.3, 0), SpreadAngle = Vector2.new(40, 40), EmissionDirection = Enum.NormalId.Top })
	light(b, an, rgb(255, 120, 40), 24, 1.6)
end

B.volcano = function(b) -- Volcanic Mountain: towering cone, lava streaks down the flanks, smoke + embers
	local base = at(b, 0, 0, -sag(b, 13) - 0.5)
	local h = 26
	local m = asset(b, "Volcano", base, h, function(p)
		p.Color = rgb(74, 58, 54)
	end)
	if not m then
		cyl(b, base, h, 26, { Name = "Cone", Material = Enum.Material.Basalt, Color = rgb(74, 58, 54) })
	end
	local caldera = P(b, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 6, 6), CFrame = base * CFrame.new(0, h * 0.92, 0) * UPRIGHT, Material = Enum.Material.Neon, Color = rgb(255, 120, 35) })
	for k = 1, 4 do
		local a = k / 4 * TAU + b.rng:NextNumber(-0.3, 0.3)
		local top = Vector3.new(math.cos(a) * 3, h * 0.88, math.sin(a) * 3)
		local bot = Vector3.new(math.cos(a) * 12, 1.2, math.sin(a) * 12)
		local mid = (top + bot) / 2
		P(b, { Name = "Glow", Size = Vector3.new(0.7, 0.3, (bot - top).Magnitude), CFrame = base * CFrame.lookAt(mid, bot) * CFrame.new(0, 0.35, 0), Material = Enum.Material.Neon, Color = rgb(255, 100, 25) })
	end
	glowPulse(b, { caldera }, 0, 0.25, 0.4)
	emit(b, caldera, { Texture = TEX.smoke, Color = ColorSequence.new(rgb(90, 80, 80)), LightEmission = 0, Rate = 2, Lifetime = NumberRange.new(4, 6), Speed = NumberRange.new(3, 5), Size = seq(3, 10), Transparency = seq(0.5, 1), SpreadAngle = Vector2.new(15, 15), EmissionDirection = Enum.NormalId.Right })
	emit(b, caldera, { Texture = TEX.sparks, Color = ColorSequence.new(rgb(255, 210, 120), rgb(255, 90, 30)), Rate = 8, Lifetime = NumberRange.new(1, 2), Speed = NumberRange.new(6, 10), Size = seq(0.4, 0), SpreadAngle = Vector2.new(25, 25), EmissionDirection = Enum.NormalId.Right })
	light(b, caldera, rgb(255, 120, 40), 30, 2, true)
end

B.eternalCore = function(b) -- Eternal Core: exposed caldera, levitating molten core, orbiting tectonic plates, plasma arcs, eruptions
	local base = at(b, 0, 0, -0.4)
	for k = 1, 14 do
		local a = k / 14 * TAU
		P(b, { Name = "Caldera", Size = Vector3.new(3.2, b.rng:NextNumber(2.5, 4.5), 2.6), CFrame = at(b, math.cos(a) * 10, math.sin(a) * 10, 0.6 - sag(b, 10), -a, 6) * CFrame.Angles(math.rad(22), 0, 0), Material = Enum.Material.Basalt, Color = shade(rgb(48, 40, 40), b.rng:NextNumber(0.85, 1.1)) })
	end
	local floor = disc(b, 0, 0, 18, 0.12, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(255, 100, 25) })
	local coreCf = base * CFrame.new(0, 17, 0)
	local core = ball(b, coreCf, 8, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(255, 150, 40) })
	local heart = ball(b, coreCf, 5, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(255, 240, 200), Transparency = 0.2 })
	local shell = ball(b, coreCf, 10, { Name = "Shell", Material = Enum.Material.ForceField, Color = rgb(255, 120, 40) })
	local bobParts = { core, heart, shell }
	local plates = {}
	for k = 1, 6 do
		local a = k / 6 * TAU
		table.insert(plates, P(b, { Name = "Plate", Size = Vector3.new(5, 1.2, 3.4), CFrame = coreCf * CFrame.Angles(0, a, 0) * CFrame.new(8.5, b.rng:NextNumber(-2, 2), 0) * CFrame.Angles(math.rad(b.rng:NextNumber(-25, 25)), 0, math.rad(b.rng:NextNumber(-20, 20))), Material = Enum.Material.Basalt, Color = rgb(56, 46, 46) }))
		table.insert(plates, P(b, { Name = "Glow", Size = Vector3.new(4.6, 0.15, 3), CFrame = plates[#plates].CFrame * CFrame.new(0, -0.62, 0), Material = Enum.Material.Neon, Color = rgb(255, 110, 30) }))
	end
	spin(b, plates, coreCf, 0.35, 0.8, 0.22)
	table.insert(b.anims, { kind = "bob", parts = bobParts, pivot = coreCf, amp = 0.9, freq = 0.22, phase = 0 })
	local an = anchor(b, coreCf, "ArcAnchor")
	for k = 1, 3 do
		local a = k / 3 * TAU + 0.5
		local rim = at(b, math.cos(a) * 9.5, math.sin(a) * 9.5, 2.5).Position
		beam(an, attach(an, coreCf.Position), attach(an, rim), { Width0 = 0.8, Width1 = 0.3, Color = ColorSequence.new(rgb(255, 240, 200), rgb(255, 120, 40)), Transparency = seq(0.1, 0.4), Texture = TEX.sparkle, TextureMode = Enum.TextureMode.Wrap, TextureLength = 2, TextureSpeed = 4, LightEmission = 1, FaceCamera = true, CurveSize0 = 4, CurveSize1 = -3, Segments = 10 })
	end
	local plume = emit(b, floor, { Texture = TEX.fire, Color = ColorSequence.new(rgb(255, 220, 120), rgb(255, 70, 20)), Rate = 0, Lifetime = NumberRange.new(1.2, 2), Speed = NumberRange.new(14, 22), Size = seq(2.4, 0), SpreadAngle = Vector2.new(14, 14), EmissionDirection = Enum.NormalId.Right })
	if plume then
		table.insert(b.anims, { kind = "erupt", emitter = plume, every = 7, count = 26, t = b.rng:NextNumber(0, 7) })
	end
	glowPulse(b, { core }, 0, 0.2, 0.35)
	light(b, an, rgb(255, 140, 40), 40, 2.4, true)
end

---------------------------------------------------------------- builders: CRYSTAL

local function crystalTint(b: any): ((BasePart) -> ())
	return function(p: BasePart)
		if p:IsA("UnionOperation") then
			p.UsePartColor = true
		end
		p.Color = b.pal.accent or rgb(175, 110, 255)
		p.Material = Enum.Material.Neon
		p.Transparency = 0.3
	end
end

B.crystalCluster = function(b) -- Crystal Cluster: crystals bursting from the crust; count + colours follow CosmicEnergy
	local cols = { rgb(200, 130, 255), rgb(150, 215, 255), rgb(255, 150, 230) }
	local count = if b.elements > 0 then b.elements else math.max(4, math.floor(7 * b.q.detail))
	local names = Density.variants("crystals", b.level)
	for k = 1, count do
		local x, z = elementSpot(b, k, 1.7)
		local er = Random.new(Art.hash(b.def.id, k, b.elSeed, "c"))
		local lean = CFrame.Angles(math.rad(if k == 1 then 0 else -er:NextNumber(10, 25)), 0, 0)
		local base = at(b, x, z, -0.4, math.atan2(z, x) + math.pi / 2, 5) * lean
		if k == 1 then
			-- the centrepiece stays a faceted glowing crystal; the rest are cheap 1-2 part template variants
			local c = cols[1]
			crystal(b, base, er:NextNumber(4.2, 6.5), er:NextNumber(1.1, 1.5), c, shade(c, 1.2))
		else
			local name = names[er:NextInteger(1, #names)]
			local m = asset(b, name, base, er:NextNumber(3, 5.5), if name == "CrystalBase" then crystalTint(b) else nil)
			if not m then
				local c = cols[(k % 3) + 1]
				crystal(b, base, er:NextNumber(3, 6), er:NextNumber(0.9, 1.4), c, shade(c, 1.2))
			end
		end
	end
	light(b, anchor(b, at(b, 0, 0, 3)), rgb(200, 140, 255), 12, 0.9)
end

B.energyVeins = function(b) -- Energy Veins: luminous mineral veins threading the rock, crystal nodes at junctions
	local steps = if b.lean then 4 else 7
	local k = 7 / steps
	local nb = if b.satellite then 2 else 3
	for br = 1, nb do
		local x, z, h = 0, 0, br / nb * TAU + b.rng:NextNumber(-0.4, 0.4)
		for s = 1, steps do
			local len = b.rng:NextNumber(1.6, 2.4) * k
			local nx, nz = x + math.cos(h) * len, z + math.sin(h) * len
			-- glowing vein on a dark mineral bed (contrast), round node at each bend: reads as one continuous vein
			local cf = at(b, (x + nx) / 2, (z + nz) / 2, 0.04, -h + math.pi / 2)
			P(b, { Name = "Glow", Size = Vector3.new(0.75, 0.2, len + 0.3), CFrame = cf, Material = Enum.Material.Neon, Color = rgb(120, 225, 255) })
			P(b, { Name = "Seam", Size = Vector3.new(1.8, 0.16, len + 0.8), CFrame = cf * CFrame.new(0, -0.06, 0), Material = Enum.Material.Slate, Color = rgb(34, 30, 60) })
			if s < steps then
				P(b, { Name = "Glow", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 0.85, 0.85), CFrame = at(b, nx, nz, 0.04) * CFrame.Angles(0, 0, math.pi / 2), Material = Enum.Material.Neon, Color = rgb(150, 235, 255) })
			end
			if s % 3 == 0 then
				crystal(b, at(b, nx, nz, -0.3, h, 12), b.rng:NextNumber(1.2, 2.2), 0.6, rgb(150, 230, 255), rgb(200, 250, 255))
			end
			x, z = nx, nz
			h += b.rng:NextNumber(-0.7, 0.7)
		end
	end
	ball(b, at(b, 0, 0, 0.2), 1.6, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(170, 240, 255) })
end

B.crystalGarden = function(b) -- Crystal Garden: ring of multicolour crystal clusters around a towering centrepiece
	disc(b, 0, 0, 22, 0.05, { Name = "Glow", Material = Enum.Material.Neon, Color = rgb(120, 70, 190), Transparency = 0.75, Thick = 0.15 })
	local cols = { rgb(255, 140, 220), rgb(140, 220, 255), rgb(190, 140, 255), rgb(255, 200, 120) }
	crystal(b, at(b, 0, 0, -0.5, 0, 3), 9, 2.2, rgb(220, 160, 255), rgb(255, 220, 255))
	for k = 1, 6 do
		local a = k / 6 * TAU
		local cx, cz = math.cos(a) * 6.5, math.sin(a) * 6.5
		for j = 1, 3 do
			local c = cols[((k + j) % 4) + 1]
			local lean = CFrame.Angles(math.rad(-b.rng:NextNumber(8, 22)), 0, 0)
			crystal(b, at(b, cx + b.rng:NextNumber(-1.2, 1.2), cz + b.rng:NextNumber(-1.2, 1.2), -0.4, b.rng:NextNumber(0, TAU), 4) * lean, b.rng:NextNumber(2.5, 5), b.rng:NextNumber(0.8, 1.2), c, shade(c, 1.2))
		end
	end
	emit(b, anchor(b, at(b, 0, 0, 3)), { Texture = TEX.sparkle, Color = ColorSequence.new(rgb(255, 180, 255), rgb(150, 230, 255)), Rate = 6, Lifetime = NumberRange.new(1.5, 3), Speed = NumberRange.new(0.3, 1), Size = seq3(0, 0.4, 0), SpreadAngle = Vector2.new(180, 180) })
	light(b, anchor(b, at(b, 0, 0, 6)), rgb(220, 150, 255), 22, 1.1)
end

B.resonanceArch = function(b) -- Resonance Arch: crystal arch with a glowing spine and turning resonance rings
	local base = at(b, 0, 0, -0.5)
	for k = 0, 10 do
		local a = k / 10 * math.pi
		local cf = base * CFrame.new(math.cos(a) * 7, math.sin(a) * 9 + 0.5, 0) * CFrame.Angles(0, 0, a - math.pi / 2)
		P(b, { Name = "Arch", Size = Vector3.new(2.4, 2.6, 2.6), CFrame = cf, Material = Enum.Material.Glass, Color = rgb(175, 120, 255), Transparency = 0.2 })
		P(b, { Name = "Glow", Size = Vector3.new(0.6, 2.7, 0.6), CFrame = cf, Material = Enum.Material.Neon, Color = rgb(120, 230, 255) })
	end
	local ringCf = base * CFrame.new(0, 7, 0)
	local rings = {}
	for k = 1, 2 do
		local d = 8 - k * 2.2
		for s = 1, 16 do
			local a = s / 16 * TAU
			table.insert(rings, P(b, { Name = "Glow", Size = Vector3.new(0.35, 0.35, d * math.pi / 16 * 1.1), CFrame = ringCf * CFrame.Angles(0, 0, if k == 1 then 0 else math.pi / 2) * CFrame.Angles(a, 0, 0) * CFrame.new(0, d / 2, 0), Material = Enum.Material.Neon, Color = if k == 1 then rgb(120, 230, 255) else rgb(255, 150, 230), Transparency = 0.15 }))
		end
	end
	spin(b, rings, ringCf, 0.5)
	light(b, anchor(b, ringCf), rgb(150, 230, 255), 22, 1.4)
end

B.crystalSpire = function(b) -- Giant Crystal Spire: a single crystal taller than a mountain, orbiting shards
	local base = at(b, 0, 0, -1.2, 0, 4)
	crystal(b, base, 34, 6, rgb(210, 150, 255), rgb(255, 225, 255))
	for k = 1, 4 do
		local a = k / 4 * TAU + 0.4
		crystal(b, at(b, math.cos(a) * 4.2, math.sin(a) * 4.2, -0.5, a, 6) * CFrame.Angles(math.rad(-18), 0, 0), b.rng:NextNumber(6, 11), 2, rgb(170, 140, 255), rgb(230, 210, 255))
	end
	local shards = {}
	for k = 1, 6 do
		local a = k / 6 * TAU
		local cf = base * CFrame.new(math.cos(a) * 9, 14 + (k % 3) * 4, math.sin(a) * 9) * CFrame.Angles(b.rng:NextNumber(0, 6), b.rng:NextNumber(0, 6), 0)
		for _, p in crystal(b, cf, 3, 0.9, rgb(160, 230, 255), rgb(230, 250, 255)) do
			table.insert(shards, p)
		end
	end
	spin(b, shards, base, 0.25, 0.8, 0.3)
	light(b, anchor(b, base * CFrame.new(0, 20, 0)), rgb(220, 160, 255), 36, 1.6, true)
end

B.celestialPrism = function(b) -- Celestial Prism: levitating faceted prism, turning prismatic rings, light beams to the sky
	local base = at(b, 0, 0, -0.5)
	for k = 1, 5 do
		local a = k / 5 * TAU
		crystal(b, at(b, math.cos(a) * 3, math.sin(a) * 3, -0.4, a, 6) * CFrame.Angles(math.rad(-15), 0, 0), b.rng:NextNumber(3, 6), 1.3, rgb(255, 200, 255), rgb(255, 235, 255))
	end
	local prismCf = base * CFrame.new(0, 19, 0)
	local prism = {}
	for k = 0, 1 do
		table.insert(prism, P(b, { Name = "Prism", Size = Vector3.one * 8.5, CFrame = prismCf * CFrame.Angles(math.rad(45), math.rad(45 * k), math.rad(35)), Material = Enum.Material.Neon, Color = if k == 0 then rgb(255, 200, 250) else rgb(190, 225, 255), Transparency = 0.45 }))
	end
	table.insert(prism, P(b, { Name = "Glow", Size = Vector3.one * 4, CFrame = prismCf * CFrame.Angles(math.rad(45), 0, math.rad(35)), Material = Enum.Material.Neon, Color = rgb(255, 255, 255) }))
	ball(b, prismCf, 15, { Name = "Halo", Material = Enum.Material.ForceField, Color = rgb(255, 200, 255) })
	spin(b, prism, prismCf, 0.4, 1.2, 0.18)
	local rings = {}
	local cols = { rgb(255, 120, 200), rgb(120, 220, 255), rgb(255, 230, 120) }
	for k = 1, 3 do
		local d = 12 + k * 2.5
		local tilt = CFrame.Angles(math.rad(k * 35), math.rad(k * 50), 0)
		for s = 1, 20 do
			local a = s / 20 * TAU
			table.insert(rings, P(b, { Name = "Glow", Size = Vector3.new(0.3, 0.3, d * math.pi / 20 * 1.1), CFrame = prismCf * tilt * CFrame.Angles(a, 0, 0) * CFrame.new(0, d / 2, 0), Material = Enum.Material.Neon, Color = cols[k], Transparency = 0.25 }))
		end
	end
	spin(b, rings, prismCf, -0.18)
	local an = anchor(b, prismCf, "BeamAnchor")
	for k = 1, 3 do
		local a = k / 3 * TAU
		local sky = (prismCf * CFrame.new(math.cos(a) * 6, 40, math.sin(a) * 6)).Position
		beam(an, attach(an, prismCf.Position), attach(an, sky), { Width0 = 1.6, Width1 = 0.2, Color = ColorSequence.new(cols[k], Color3.new(1, 1, 1)), Transparency = seq(0.2, 1), LightEmission = 1, FaceCamera = true, Segments = 4 })
	end
	light(b, an, rgb(255, 210, 255), 40, 1.8, true)
end

---------------------------------------------------------------- orbital dressing (stage >= 3) + rim glow

-- Returns { model, anims } or nil. Deterministic from seed; one tilted belt per branch, moonlet at stage 4.
function Art.orbitals(planet: any, branch: string?, stage: number): any
	if stage < 3 then
		return nil
	end
	local theme = string.lower(branch or "")
	local pal = Profile.PALETTES[theme] or Profile.PALETTES.primordial
	local model = Instance.new("Model")
	model.Name = "Orbitals"
	local rng = Random.new(Art.hash(planet.seed, "orbit", theme))
	local tilt = CFrame.Angles(rng:NextNumber(-0.45, 0.45), rng:NextNumber(0, TAU), rng:NextNumber(-0.45, 0.45))
	local pivot = CFrame.new(planet.center) * tilt
	model.WorldPivot = pivot
	local b = { model = model, rng = rng, anims = {}, emitters = {}, lights = {}, q = quality(planet.quality) }
	local R = planet.R
	-- orbital dressing scales with the planet (authored at FormationDensity.REFERENCE_RADIUS): piece size, belt
	-- thickness and piece count grow with R so the belt keeps the same read from orbit at any planet scale
	local ks = R / (Density.REFERENCE_RADIUS or 96)
	local belt = {}
	local count = math.floor(22 * b.q.detail * ks)
	for k = 1, count do
		local a = k / count * TAU + rng:NextNumber(-0.1, 0.1)
		local r = R * rng:NextNumber(1.5, 1.72)
		local cf = pivot * CFrame.new(math.cos(a) * r, rng:NextNumber(-2.5, 2.5) * ks, math.sin(a) * r) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0)
		local p
		if theme == "living" then
			p = P(b, { Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * rng:NextNumber(0.9, 1.8), CFrame = cf, Material = Enum.Material.Neon, Color = if k % 3 == 0 then rgb(255, 230, 140) else rgb(190, 255, 160), Transparency = 0.15 })
		elseif theme == "frozen" then
			p = P(b, { Name = "IceShard", Size = Vector3.new(rng:NextNumber(1, 2), rng:NextNumber(2.5, 5), rng:NextNumber(1, 2)), CFrame = cf, Material = Enum.Material.Ice, Color = rgb(200, 232, 252), Transparency = 0.1 })
		elseif theme == "volcanic" then
			p = P(b, { Name = "Rock", Size = Vector3.new(rng:NextNumber(2, 4.5), rng:NextNumber(1.6, 3.5), rng:NextNumber(2, 4)), CFrame = cf, Material = Enum.Material.Basalt, Color = if k % 3 == 0 then rgb(255, 110, 30) else rgb(92, 70, 64) })
			if k % 3 == 0 then
				p.Material = Enum.Material.Neon
			end
		elseif theme == "crystal" then
			p = P(b, { Name = "Shard", Size = Vector3.new(0.9, rng:NextNumber(2.5, 4.5), 0.9), CFrame = cf, Material = if k % 2 == 0 then Enum.Material.Neon else Enum.Material.Glass, Color = if k % 3 == 0 then rgb(255, 150, 230) else rgb(170, 220, 255), Transparency = if k % 2 == 0 then 0.2 else 0.15 })
		else
			p = P(b, { Name = "Rock", Size = Vector3.one * rng:NextNumber(1.5, 3), CFrame = cf, Material = Enum.Material.Slate, Color = rgb(110, 104, 100) })
		end
		p.Size *= ks
		table.insert(belt, p)
	end
	table.insert(b.anims, { kind = "spin", parts = belt, pivot = pivot, speed = 0.05 * (if rng:NextNumber() < 0.5 then -1 else 1), bob = 0, bobFreq = 0, phase = 0, orbital = true })
	if stage >= 4 then
		local moonPivot = CFrame.new(planet.center) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3))
		local mat = if theme == "frozen" then Enum.Material.Glacier elseif theme == "volcanic" then Enum.Material.CrackedLava elseif theme == "crystal" then Enum.Material.Glass else Enum.Material.Slate
		local moon = P(b, { Name = "Moonlet", Shape = Enum.PartType.Ball, Size = Vector3.one * R * 0.22, CFrame = moonPivot * CFrame.new(R * 2.25, 0, 0), Material = mat, Color = shade(pal.surface, 0.85) })
		table.insert(b.anims, { kind = "spin", parts = { moon }, pivot = moonPivot, speed = 0.07, bob = 0, bobFreq = 0, phase = 0, orbital = true })
		if theme == "frozen" then
			-- polar aurora crown: curtains ringing the north pole
			local an = P(b, { Name = "AuroraAnchor", Size = Vector3.one * 0.2, Transparency = 1, CFrame = CFrame.new(planet.center) })
			local beams = {}
			for k = 1, 6 do
				local a0, a1 = k / 6 * TAU, (k + 0.9) / 6 * TAU
				local p0 = planet.center + Vector3.new(math.cos(a0) * R * 0.5, R * 1.12, math.sin(a0) * R * 0.5)
				local p1 = planet.center + Vector3.new(math.cos(a1) * R * 0.5, R * 1.12, math.sin(a1) * R * 0.5)
				local up = ((p0 + p1) / 2 - planet.center).Unit
				table.insert(beams, curtain(b, an, p0, p1, up, 16 * ks, AURORA, 10 * ks))
			end
			table.insert(b.anims, { kind = "aurora", beams = beams, amp = 8 * ks, base = 10 * ks, freq = 0.08, phase = 0, orbital = true })
		end
	end
	-- branch-tinted rim (fake fresnel): a second ForceField shell reads as a halo from across the system
	local rimCol = (pal.atmosphere or pal.glow or rgb(150, 200, 255)):Lerp(Color3.new(1, 1, 1), 0.3)
	P(b, { Name = "Rim", Shape = Enum.PartType.Ball, Size = Vector3.one * 2 * R * 1.07, CFrame = CFrame.new(planet.center), Material = Enum.Material.ForceField, Color = rimCol, Transparency = 0.25 })
	return { model = model, anims = b.anims }
end

---------------------------------------------------------------- build entry

Art.BUILDERS = B

-- planet = { seed, slot, center, R, theme, quality }. opts = { elements?, level? } from FormationDensity.layout.
-- Returns the instance record or nil (unknown archetype). The model is built at authored size on the virtual
-- sphere and then scaled by FormationDensity.scaleFor(def) about the site pivot (record.scale).
function Art.build(planet: any, def: any, index: number, site: any, opts: any?): any
	local fn = B[def.archetype]
	if not fn then
		return nil
	end
	local o = opts or {}
	local theme = if def.branch then string.lower(def.branch) else (planet.theme or "primordial")
	local pal = Profile.PALETTES[theme] or Profile.PALETTES.primordial
	local scale = Density.scaleFor(def)
	local b = newB(planet, def, site, index, pal, scale)
	b.elements = o.elements or 0
	b.level = o.level or 0
	b.elSeed = Art.hash(planet.seed, index)
	b.lean = scale < 1
	-- extra copies of a DNA-spread formation (2nd lake, 3rd crack...): same look, no particles / lights of their own
	b.satellite = index > 1 and Density.SPEC[def.id] ~= nil and Density.SPEC[def.id].mode == "spread"
	if b.satellite then
		b.q = table.clone(b.q)
		b.q.emitters = 0
		b.q.lights = false
	end
	fn(b)
	local siteCf = b.siteCf
	if scale ~= 1 then
		b.model:ScaleTo(scale)
		-- animation pivots / amplitudes were recorded at authored size: map them through the same scaling
		local function scaled(cf: CFrame): CFrame
			local rel = siteCf:ToObjectSpace(cf)
			return siteCf * CFrame.new(rel.Position * scale) * rel.Rotation
		end
		for _, a in b.anims do
			if typeof(a.pivot) == "CFrame" then
				a.pivot = scaled(a.pivot)
			end
			if a.kind == "spin" and a.bob then
				a.bob *= scale
			elseif a.kind == "bob" and a.amp then
				a.amp *= scale
			elseif a.kind == "aurora" then
				a.amp = (a.amp or 0) * scale
				a.base = (a.base or 0) * scale
			end
		end
	end
	b.model:SetAttribute("PFFormation", def.id)
	b.model:SetAttribute("PFIndex", index)
	b.model:SetAttribute("PFElements", b.elements)
	return {
		model = b.model,
		far = def.landmark == true,
		height = (def.height or 6) * scale,
		scale = scale,
		elements = b.elements,
		anims = b.anims,
		emitters = b.emitters,
		lights = b.lights,
		burst = def.color,
		siteCf = siteCf,
	}
end

return Art
