--!strict
-- CosmeticsFX — owner: Monetization (client presentation). Renders equipped planet cosmetics for EVERY planet
-- (earned and premium): atmospheres (palette shell + haze + an aurora sky effect for premium palettes) and
-- orbiting rings (default band / halo / bands / prism). Source of truth: slot attributes PFCosAtmosphere and
-- PFCosRing (PlanetVisualAdapter). Also plays Cosmic Fireworks (Store_Celebration) and local store previews.
-- Performance: built only within BUILD_RANGE of the camera (hysteresis), static parts (no per-frame movement),
-- particle budget by the player's Visual effects preset (PFEffects: full / reduced / minimal), nothing
-- collides, casts shadows or is queryable. Everything is local and destroyed when out of range.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("PF_Shared")
local ItemCatalog = require(Shared.Config.ItemCatalog)
local WorldLayout = require(Shared.Config.WorldLayout)

local CosmeticsFX = {}

local BUILD_RANGE, DROP_RANGE = 2400, 2700
local TILT = math.rad(18)
local BUDGET = {
	full = { segments = 40, aurora = 12, burstEvery = 0.3, sparks = 70, perTick = 2 },
	reduced = { segments = 32, aurora = 5, burstEvery = 0.6, sparks = 35, perTick = 1 },
	minimal = { segments = 24, aurora = 0, burstEvery = 1.2, sparks = 0, perTick = 1 },
}

local player = Players.LocalPlayer
local root: Folder = nil :: any
local views: { [number]: any } = {}
local previews: { [number]: { [string]: string } } = {}
local started = false

local function quality(): string
	local q = player:GetAttribute("PFEffects")
	return if type(q) == "string" and BUDGET[q] then q else "full"
end

local function reducedMotion(): boolean
	return player:GetAttribute("PFReducedMotion") == true
end

local function part(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function slotModel(slot: number): Instance?
	local w = Workspace:FindFirstChild("PF_World")
	local planets = w and w:FindFirstChild("Planets")
	return planets and planets:FindFirstChild("Slot_" .. slot)
end

local function wanted(slot: number): (string?, string?)
	local pv = previews[slot]
	local m = slotModel(slot)
	local atmo = m and m:GetAttribute("PFCosAtmosphere")
	local ring = m and m:GetAttribute("PFCosRing")
	if pv then
		if pv.Atmosphere then
			atmo = pv.Atmosphere
		end
		if pv.PlanetRing then
			ring = pv.PlanetRing
		end
	end
	return (if type(atmo) == "string" and atmo ~= "" then atmo else nil), (if type(ring) == "string" and ring ~= "" then ring else nil)
end

local function buildAtmosphere(folder: Folder, center: Vector3, R: number, id: string, q: string)
	local e = ItemCatalog.COSMETICS[id]
	if not e then
		return
	end
	local c1 = e.color or Color3.new(1, 1, 1)
	local c2 = e.color2 or c1
	part(folder, { Name = "AtmoShell", Shape = Enum.PartType.Ball, Size = Vector3.one * R * 2.26, CFrame = CFrame.new(center), Material = Enum.Material.ForceField, Color = c1, Transparency = 0.4 })
	if q ~= "minimal" then
		part(folder, { Name = "AtmoHaze", Shape = Enum.PartType.Ball, Size = Vector3.one * R * 2.1, CFrame = CFrame.new(center), Material = Enum.Material.Neon, Color = c2, Transparency = 0.93 })
	end
	local rate = BUDGET[q].aurora
	if e.sky and rate > 0 then
		local holder = part(folder, { Name = "AuroraSky", Shape = Enum.PartType.Ball, Size = Vector3.one * R * 2.5, CFrame = CFrame.new(center), Transparency = 1 })
		local pe = Instance.new("ParticleEmitter")
		pe.Shape = Enum.ParticleEmitterShape.Sphere
		pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		pe.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
		pe.Rate = rate
		pe.Lifetime = NumberRange.new(4, 7)
		pe.Speed = NumberRange.new(1, 3)
		pe.Drag = 0.4
		pe.Rotation = NumberRange.new(0, 360)
		pe.RotSpeed = NumberRange.new(-12, 12)
		pe.LightEmission = 0.7
		pe.Color = ColorSequence.new(c1, c2)
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, R * 0.16), NumberSequenceKeypoint.new(1, R * 0.24) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.35, 0.72), NumberSequenceKeypoint.new(1, 1) })
		pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
		pe.Parent = holder
	end
end

-- one band of `n` flat segments at radius r (studs), width w, in the tilted ring plane
local function band(folder: Folder, center: Vector3, r: number, w: number, n: number, colorFn: (number) -> Color3, material: Enum.Material, transparency: number)
	local plane = CFrame.new(center) * CFrame.Angles(TILT, 0, TILT * 0.6)
	local seg = 2 * math.pi * r / n * 1.04
	for i = 1, n do
		local a = (i - 0.5) / n * 2 * math.pi
		local cf = plane * CFrame.Angles(0, a, 0) * CFrame.new(r, 0, 0)
		part(folder, { Name = "RingSeg", Size = Vector3.new(w, 0.25, seg), CFrame = cf, Color = colorFn(i / n), Material = material, Transparency = transparency })
	end
end

local function buildRing(folder: Folder, center: Vector3, R: number, id: string, q: string)
	local e = ItemCatalog.COSMETICS[id]
	if not e then
		return
	end
	local n = BUDGET[q].segments
	local c1 = e.color or Color3.new(1, 1, 1)
	local c2 = e.color2 or c1
	local style = e.style
	if style == "halo" then
		band(folder, center, R * 1.78, 1.4, n, function()
			return c1
		end, Enum.Material.Neon, 0.2)
		band(folder, center, R * 1.98, 0.9, n, function()
			return c1
		end, Enum.Material.Neon, 0.35)
	elseif style == "bands" then
		band(folder, center, R * 1.72, 11, n, function()
			return c1
		end, Enum.Material.SmoothPlastic, 0.22)
		band(folder, center, R * 1.96, 7, n, function()
			return c2
		end, Enum.Material.SmoothPlastic, 0.3)
		band(folder, center, R * 2.16, 3, n, function()
			return c1
		end, Enum.Material.Glass, 0.45)
	elseif style == "prism" then
		band(folder, center, R * 1.9, 5, n, function(u)
			return Color3.fromHSV(u, 0.55, 1)
		end, Enum.Material.Neon, 0.3)
	else
		band(folder, center, R * 1.85, 6, n, function()
			return c1
		end, Enum.Material.Glass, 0.3)
	end
end

local function rebuild(slot: number, center: Vector3)
	local v = views[slot]
	if v and v.folder then
		v.folder:Destroy()
	end
	local atmo, ring = wanted(slot)
	local q = quality()
	views[slot] = { key = (atmo or "") .. "|" .. (ring or "") .. "|" .. q, folder = nil }
	if not atmo and not ring then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "Slot_" .. slot
	f.Parent = root
	views[slot].folder = f
	local R = WorldLayout.PLANET_RADIUS
	if atmo then
		buildAtmosphere(f, center, R, atmo, q)
	end
	if ring then
		buildRing(f, center, R, ring, q)
	end
end

local function tick()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	for slot = 1, WorldLayout.SLOT_COUNT do
		if WorldLayout.isActiveSlot(slot) then
			local center = WorldLayout.getSlotCenter(slot)
			local d = (center - camPos).Magnitude
			local v = views[slot]
			local atmo, ring = wanted(slot)
			local key = (atmo or "") .. "|" .. (ring or "") .. "|" .. quality()
			if d <= BUILD_RANGE then
				if not v or v.key ~= key then
					rebuild(slot, center)
				end
			elseif d > DROP_RANGE and v then
				if v.folder then
					v.folder:Destroy()
				end
				views[slot] = nil
			end
		end
	end
end

-- Local-only preview on a slot (store). cosmetics = { Atmosphere?, PlanetRing? }; seconds = auto-revert.
function CosmeticsFX.preview(slot: number, cosmetics: { [string]: string }, seconds: number?)
	previews[slot] = cosmetics
	local token = {}
	;(previews[slot] :: any).__token = token
	tick()
	task.delay(seconds or 12, function()
		local pv = previews[slot]
		if pv and (pv :: any).__token == token then
			previews[slot] = nil
			tick()
		end
	end)
end

function CosmeticsFX.endPreview(slot: number?)
	if slot then
		previews[slot] = nil
	else
		table.clear(previews)
	end
	tick()
end

function CosmeticsFX.isPreviewing(slot: number): boolean
	return previews[slot] ~= nil
end

-- Cosmic Fireworks: decorative bursts around a planet for `duration` seconds.
function CosmeticsFX.fireworks(slot: number, duration: number, seed: number?)
	local center = WorldLayout.getSlotCenter(slot)
	local cam = Workspace.CurrentCamera
	if not cam or (center - cam.CFrame.Position).Magnitude > 3200 then
		return
	end
	local q = quality()
	local b = BUDGET[q]
	local calm = reducedMotion()
	local R = WorldLayout.PLANET_RADIUS
	local rng = Random.new(seed or os.clock() * 1000)
	local f = Instance.new("Folder")
	f.Name = "Fireworks_" .. slot
	f.Parent = root
	local palette = { Color3.fromRGB(255, 120, 200), Color3.fromRGB(120, 230, 255), Color3.fromRGB(255, 215, 110), Color3.fromRGB(150, 255, 170), Color3.fromRGB(190, 140, 255) }
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < duration and f.Parent do
			for _ = 1, b.perTick do
				local dir = rng:NextUnitVector()
				local pos = center + dir * R * rng:NextNumber(1.45, 1.95)
				local col = palette[rng:NextInteger(1, #palette)]
				-- rising streak from the surface to the burst point
				if not calm then
					local from = center + dir * R * 1.02
					local streak = part(f, { Size = Vector3.new(0.8, 0.8, 9), CFrame = CFrame.lookAt(from, pos), Material = Enum.Material.Neon, Color = col, Transparency = 0.1 })
					TweenService:Create(streak, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = CFrame.lookAt(pos, pos + (pos - from)), Transparency = 0.6 }):Play()
					Debris:AddItem(streak, 0.4)
				end
				task.delay(if calm then 0 else 0.35, function()
					if not f.Parent then
						return
					end
					local ball = part(f, { Shape = Enum.PartType.Ball, Size = Vector3.one * 4, CFrame = CFrame.new(pos), Material = Enum.Material.Neon, Color = col, Transparency = if calm then 0.5 else 0.05 })
					TweenService:Create(ball, TweenInfo.new(if calm then 1.4 else 0.7, Enum.EasingStyle.Quad), { Size = Vector3.one * (if calm then 24 else 46), Transparency = 1 }):Play()
					Debris:AddItem(ball, 2.2)
					if b.sparks > 0 then
						local pe = Instance.new("ParticleEmitter")
						pe.Rate = 0
						pe.Speed = NumberRange.new(35, 70)
						pe.SpreadAngle = Vector2.new(180, 180)
						pe.Lifetime = NumberRange.new(1, 2)
						pe.Drag = 1.2
						pe.Acceleration = -dir * 6 -- sparks drift back towards the planet
						pe.LightEmission = 1
						pe.Color = ColorSequence.new(col, Color3.new(1, 1, 1))
						pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3.2), NumberSequenceKeypoint.new(1, 0) })
						pe.Transparency = NumberSequence.new(0, 1)
						pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
						pe.Parent = ball
						pe:Emit(b.sparks)
					end
				end)
			end
			task.wait(b.burstEvery * (if calm then 1.5 else 1))
		end
		task.wait(2)
		f:Destroy()
	end)
end

function CosmeticsFX.stats(): any
	local n, built = 0, 0
	for _, v in views do
		if v.folder then
			built += 1
			n += #v.folder:GetDescendants()
		end
	end
	return { planets = built, instances = n, total = root and #root:GetDescendants() or 0 }
end

function CosmeticsFX.init()
	if started then
		return
	end
	started = true
	root = Instance.new("Folder")
	root.Name = "PF_PlanetCosmetics"
	root.Parent = Workspace
	task.spawn(function()
		while true do
			local ok, err = pcall(tick)
			if not ok then
				warn("[PF][CosmeticsFX] " .. tostring(err))
				task.wait(5)
			end
			task.wait(0.5)
		end
	end)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 30)
		local ev = remotes and remotes:WaitForChild("Store_Celebration", 30) :: RemoteEvent?
		if ev then
			ev.OnClientEvent:Connect(function(msg)
				if type(msg) == "table" and type(msg.slot) == "number" and WorldLayout.isActiveSlot(msg.slot) then
					CosmeticsFX.fireworks(msg.slot, math.clamp(tonumber(msg.duration) or 10, 1, 15), msg.seed)
				end
			end)
		end
	end)
end

return CosmeticsFX
