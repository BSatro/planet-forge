--!strict
-- AmbientMeteors — owner: Technical Art (VFX). CLIENT-ONLY decorative space rocks drifting far away.
-- They are NEVER gameplay targets and are built to not look like one: dull grey / desaturated rock, no Neon
-- core, no light, no rarity colour, no Highlight, no HUD marker, CanQuery off, a faint dust wake only, and
-- they stay 900+ studs away. While the player operates a harvester they are kept out of a cone around the
-- view direction (the capture lane). Gameplay meteors live in Workspace.PF_HarvestClient; these live in
-- Workspace.PF_AmbientMeteors and carry the attribute PFDecorative = true.
-- Budget: PFEffects full 8 / reduced 4 / minimal 0, halved under reduced motion; pooled; one RenderStepped.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Styles = require(script.Parent.Parent:WaitForChild("Harvest"):WaitForChild("MeteorStyles"))

local AmbientMeteors = {}

local MIN_DIST, MAX_DIST = 900, 1500
local LANE_CONE_DEG = 50
local SPAWN_EVERY = 1.6
local COLORS = { Color3.fromRGB(92, 94, 104), Color3.fromRGB(110, 102, 96), Color3.fromRGB(78, 82, 92), Color3.fromRGB(100, 100, 108) }

local folder: Folder? = nil
local active: { any } = {}
local pool: { any } = {}
local rng = Random.new()
local spawnT = 0
local started = false

local function harvesting(): boolean
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local gui = pg and pg:FindFirstChild("PF_HarvestHUD") :: ScreenGui?
	return gui ~= nil and gui.Enabled
end

function AmbientMeteors.target(): number
	local n = Styles.quality().ambient
	if Styles.reducedMotion() then
		n = math.floor(n / 2)
	end
	return n
end

local function newRock(): any
	local p = Instance.new("Part")
	p.Name = "AmbientRock"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Slate
	p:SetAttribute("PFDecorative", true)
	local a0 = Instance.new("Attachment")
	a0.Parent = p
	local a1 = Instance.new("Attachment")
	a1.Parent = p
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(Color3.fromRGB(140, 140, 150))
	trail.LightEmission = 0
	trail.Lifetime = 1.6
	trail.FaceCamera = true
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1) })
	trail.Parent = p
	return { part = p, a0 = a0, a1 = a1, trail = trail }
end

local function viewOk(cam: Camera, pos: Vector3): boolean
	if not harvesting() then
		return true
	end
	local to = pos - cam.CFrame.Position
	local cosA = to.Unit:Dot(cam.CFrame.LookVector)
	return cosA < math.cos(math.rad(LANE_CONE_DEG))
end

local function spawnOne(cam: Camera)
	local origin = cam.CFrame.Position
	for _ = 1, 6 do
		local az = rng:NextNumber(0, math.pi * 2)
		local el = math.rad(rng:NextNumber(-20, 40))
		local dir = Vector3.new(math.cos(az) * math.cos(el), math.sin(el), math.sin(az) * math.cos(el))
		local pos = origin + dir * rng:NextNumber(MIN_DIST, MAX_DIST)
		if viewOk(cam, pos) then
			local r = table.remove(pool) or newRock()
			local size = rng:NextNumber(8, 20)
			r.part.Size = Vector3.new(size, size * rng:NextNumber(0.6, 0.9), size * rng:NextNumber(0.7, 1))
			r.part.Color = COLORS[rng:NextInteger(1, #COLORS)]
			r.part.Transparency = 0
			r.a0.Position = Vector3.new(0, size * 0.3, 0)
			r.a1.Position = Vector3.new(0, -size * 0.3, 0)
			local tangent = dir:Cross(Vector3.yAxis)
			tangent = if tangent.Magnitude > 1e-3 then tangent.Unit else Vector3.xAxis
			local speed = rng:NextNumber(15, 35) * (if Styles.reducedMotion() then 0.5 else 1)
			r.vel = (tangent * (if rng:NextNumber() < 0.5 then -1 else 1) + Vector3.new(0, rng:NextNumber(-0.25, 0.1), 0)).Unit * speed
			r.spinAxis = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)).Unit
			r.spinRate = rng:NextNumber(0.05, 0.25)
			r.spin = 0
			r.pos = pos
			r.life = rng:NextNumber(30, 45)
			r.part.CFrame = CFrame.new(pos)
			r.trail:Clear()
			r.part.Parent = folder
			table.insert(active, r)
			return
		end
	end
end

local function retire(i: number)
	local r = table.remove(active, i)
	r.part.Parent = nil
	if #pool < 10 then
		table.insert(pool, r)
	else
		r.part:Destroy()
	end
end

local function step(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam or not folder then
		return
	end
	local target = AmbientMeteors.target()
	local origin = cam.CFrame.Position
	for i = #active, 1, -1 do
		local r = active[i]
		r.life -= dt
		r.pos += r.vel * dt
		r.spin += r.spinRate * dt
		local dist = (r.pos - origin).Magnitude
		if r.life <= 0 or dist > MAX_DIST * 1.4 or dist < MIN_DIST * 0.6 or #active > target or not viewOk(cam, r.pos) then
			retire(i)
		else
			r.part.CFrame = CFrame.new(r.pos) * CFrame.fromAxisAngle(r.spinAxis, r.spin)
		end
	end
	spawnT -= dt
	if #active < target and spawnT <= 0 then
		spawnT = SPAWN_EVERY
		spawnOne(cam)
	end
end

function AmbientMeteors.count(): number
	return #active
end

function AmbientMeteors.init()
	if started then
		return
	end
	started = true
	local f = Instance.new("Folder")
	f.Name = "PF_AmbientMeteors"
	f.Parent = Workspace
	folder = f
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[PF] ambient meteors:", err)
		end
	end)
end

return AmbientMeteors
