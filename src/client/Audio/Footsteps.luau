--!strict
-- Footsteps — owner: Planet Physics 3.0. Surface-aware footsteps and landing sounds for every character.
--   * Synced to the animation: a step plays when an animated foot plants (its height relative to the root
--     reaches a low point), so the cadence follows walk / sprint speed and whatever cycle is playing.
--   * Surface = what the character stands on, from the gravity controller's own -up ground probe (local player)
--     or a short ray along the character's own -up (other players), so it works on every side of a planet.
--     Material -> category (CATEGORY_BY_MATERIAL); a part or its parent can force one with the attribute
--     PFFootstep = "rock" | "regolith" | "ice" | "snow" | "basalt" | "crystal" | "grass" | "metal".
--     Anything inside the station's gravity field counts as station metal.
--   * Only grounded, moving, unanchored characters step. Pooled sounds (no Instance per step), at most POOL
--     voices per character, oldest voice is stolen, MIN_STEP_GAP between steps -> no stacking.
--   * Audio: licensed clips from the Pro Sound Effects library on the Creator Store ("Courtesy of Pro Sound
--     Effects"), sliced with PlaybackRegion and shaped per surface with pitch + EQ. Everything plays through
--     SoundService.PF_SFX.PF_Footsteps, so the player's Effects volume applies.
--   * Other players: nearest MAX_REMOTE within REMOTE_RANGE studs only, ground checked at 5 Hz.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.PF_Shared.Util.Signal)
local GravityFields = require(ReplicatedStorage.PF_Shared.Gravity.GravityFields)

local Footsteps = {}
Footsteps.Step = Signal.new() -- (character: Model, category: string, position: Vector3, up: Vector3, intensity: number)
Footsteps.Landed = Signal.new() -- (character: Model, category: string, position: Vector3, up: Vector3, intensity: number)

local POOL = 3
local MIN_STEP_GAP = 0.09
local MIN_MOVE_SPEED = 2.5
local REMOTE_RANGE = 80
local MAX_REMOTE = 6
local LAND_MIN_SPEED = 12

local M = Enum.Material
local CATEGORY_BY_MATERIAL: { [Enum.Material]: string } = {
	[M.Rock] = "rock", [M.Slate] = "rock", [M.Granite] = "rock", [M.Pebble] = "rock", [M.Cobblestone] = "rock",
	[M.Concrete] = "rock", [M.Asphalt] = "rock", [M.Brick] = "rock", [M.Pavement] = "rock", [M.Limestone] = "rock",
	[M.Marble] = "rock", [M.Plastic] = "rock", [M.SmoothPlastic] = "rock", [M.Wood] = "rock", [M.WoodPlanks] = "rock",
	[M.Sand] = "regolith", [M.Sandstone] = "regolith", [M.Ground] = "regolith", [M.Mud] = "regolith", [M.Salt] = "regolith",
	[M.Basalt] = "basalt", [M.CrackedLava] = "basalt",
	[M.Ice] = "ice", [M.Glacier] = "ice",
	[M.Snow] = "snow",
	[M.Glass] = "crystal", [M.Neon] = "crystal", [M.ForceField] = "crystal",
	[M.Grass] = "grass", [M.LeafyGrass] = "grass",
	[M.Metal] = "metal", [M.DiamondPlate] = "metal", [M.CorrodedMetal] = "metal", [M.Foil] = "metal",
}
Footsteps.CATEGORIES = { "rock", "regolith", "ice", "snow", "basalt", "crystal", "grass", "metal" }

-- Licensed source clips (Creator Store, creator "ProSoundEffects"). `gain` evens out the recordings' loudness.
type Clip = { id: number, from: number, to: number, gain: number }
local CLIPS: { [string]: Clip } = {
	-- gains measured in Studio with an AudioAnalyzer (RMS of each slice) so every step take lands at ~0.06 RMS and
	-- every landing take at ~0.12 RMS before STEP_VOLUME / LAND_VOLUME
	dirtA = { id = 9114109953, from = 0.00, to = 0.26, gain = 0.72 }, -- Dirt Impacts 4
	dirtB = { id = 9114110819, from = 0.03, to = 0.30, gain = 1.03 }, -- Dirt Impacts 17
	fallD = { id = 9113469779, from = 0.34, to = 0.60, gain = 7.50 }, -- Body Fall Dirt 3, first hit
	fallE = { id = 9113469779, from = 0.88, to = 1.14, gain = 4.60 }, -- Body Fall Dirt 3, second hit
	snow1 = { id = 9119316609, from = 0.10, to = 0.40, gain = 1.60 }, -- Snow Impact Big Hits Semi-Deep 3 (13 hits)
	snow2 = { id = 9119316609, from = 1.44, to = 1.74, gain = 2.10 },
	snow3 = { id = 9119316609, from = 3.23, to = 3.53, gain = 2.10 },
	snow4 = { id = 9119316609, from = 3.98, to = 4.28, gain = 2.00 },
	snow5 = { id = 9119316609, from = 4.71, to = 5.01, gain = 3.75 },
	snow6 = { id = 9119316609, from = 7.03, to = 7.33, gain = 0.63 },
	metal1 = { id = 9125818616, from = 0.02, to = 0.30, gain = 0.47 }, -- Robot Footsteps Walking Slowly Metal Surface 1
	metal2 = { id = 9125818616, from = 0.02, to = 0.40, gain = 0.48 },
	metal3 = { id = 9125818616, from = 0.02, to = 0.50, gain = 0.46 },
	landDirt = { id = 9113469779, from = 0.34, to = 1.20, gain = 2.50 }, -- Body Fall Dirt 3
	landSnowA = { id = 9113479898, from = 0.10, to = 0.90, gain = 0.32 }, -- Body Falls In Snow 2
	landSnowB = { id = 9125965296, from = 0.86, to = 1.60, gain = 0.70 }, -- Snow Impact ... Stomping Jumping 7
}

-- per-surface voice: clips to rotate through, pitch range, loudness, EQ (low, mid, high dB), optional short echo
type Voice = { clips: { string }, pitch: { number }, volume: number, eq: { number }, echo: boolean? }
local VOICES: { [string]: Voice } = {
	rock = { clips = { "dirtA", "dirtB", "fallD", "fallE" }, pitch = { 1.04, 1.20 }, volume = 1.0, eq = { 0, 0, 2 } },
	regolith = { clips = { "dirtA", "dirtB", "fallD", "fallE" }, pitch = { 0.86, 0.98 }, volume = 0.9, eq = { 2, -2, -10 } },
	basalt = { clips = { "dirtB", "fallD", "fallE", "dirtA" }, pitch = { 1.28, 1.45 }, volume = 1.0, eq = { -4, 1, 4 } },
	ice = { clips = { "dirtA", "dirtB", "fallD", "fallE" }, pitch = { 1.70, 1.95 }, volume = 1.0, eq = { -12, 0, 6 } },
	snow = { clips = { "snow1", "snow2", "snow3", "snow4", "snow5", "snow6" }, pitch = { 0.95, 1.10 }, volume = 0.9, eq = { 0, 0, -2 } },
	crystal = { clips = { "dirtA", "dirtB", "fallD", "fallE" }, pitch = { 1.90, 2.20 }, volume = 1.0, eq = { -14, 0, 8 }, echo = true },
	grass = { clips = { "dirtA", "dirtB", "fallD", "fallE" }, pitch = { 0.78, 0.90 }, volume = 0.75, eq = { 0, -3, -12 } },
	metal = { clips = { "metal1", "metal2", "metal3" }, pitch = { 0.92, 1.12 }, volume = 0.9, eq = { -6, 0, 2 } },
}
local LANDING_CLIPS: { [string]: { string } } = {
	snow = { "landSnowA", "landSnowB" },
	metal = { "metal3" },
}
local STEP_VOLUME = 0.3 -- one step ~0.018 RMS: about half a UI cue (UI_ObjectiveDone ~0.039 RMS)
local LAND_VOLUME = 0.35 -- a hard landing ~0.04 RMS, a light one about half

local rng = Random.new()
local gravity: any = nil
local fields: any = nil
local group: SoundGroup? = nil

type CharState = {
	char: Model,
	root: BasePart,
	humanoid: Humanoid?,
	feet: { BasePart },
	h1: { number }, -- foot height one sample ago
	h2: { number }, -- two samples ago
	lo: number,
	hi: number,
	lastStep: number,
	lastFoot: { number },
	sounds: { Sound },
	nextVoice: number,
	lastClip: string?,
	grounded: boolean,
	groundCat: string,
	groundAt: number,
	isLocal: boolean,
	steps: number,
}
local states: { [Model]: CharState } = {}
local stats = { steps = 0, landings = 0, byCategory = {} :: { [string]: number }, maxConcurrent = 0, stolen = 0 }

local function footGroup(): SoundGroup
	if group and group.Parent then
		return group
	end
	local sfx = SoundService:FindFirstChild("PF_SFX")
	if not sfx then
		local g = Instance.new("SoundGroup")
		g.Name = "PF_SFX"
		g.Volume = 0.8
		g.Parent = SoundService
		sfx = g
	end
	local g = (sfx :: Instance):FindFirstChild("PF_Footsteps") :: SoundGroup?
	if not g then
		local ng = Instance.new("SoundGroup")
		ng.Name = "PF_Footsteps"
		ng.Volume = 1
		ng.Parent = sfx
		g = ng
	end
	group = g
	return g :: SoundGroup
end

local function categoryOf(part: Instance?, material: Enum.Material, pos: Vector3): string
	if part then
		local forced = part:GetAttribute("PFFootstep") or (part.Parent and part.Parent:GetAttribute("PFFootstep"))
		if type(forced) == "string" and VOICES[forced] then
			return forced
		end
	end
	if fields then
		local ok, s = pcall(GravityFields.sample, fields, pos)
		if ok and s and s.id == "station" then -- the station's uniform field
			return "metal"
		end
	end
	return CATEGORY_BY_MATERIAL[material] or "rock"
end

local function buildPool(st: CharState)
	local holder = Instance.new("Attachment")
	holder.Name = "PF_FootstepEmitter"
	holder.Position = Vector3.new(0, -(st.root.Size.Y * 0.5 + 1), 0)
	holder.Parent = st.root
	for i = 1, POOL do
		local s = Instance.new("Sound")
		s.Name = "Step" .. i
		s.SoundGroup = footGroup()
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = if st.isLocal then 22 else 10
		s.RollOffMaxDistance = REMOTE_RANGE + 10
		s.PlaybackRegionsEnabled = true
		s.Volume = 0
		local eq = Instance.new("EqualizerSoundEffect")
		eq.Name = "EQ"
		eq.Parent = s
		local echo = Instance.new("EchoSoundEffect")
		echo.Name = "Echo"
		echo.Delay = 0.06
		echo.Feedback = 0.25
		echo.DryLevel = 0
		echo.WetLevel = -12
		echo.Enabled = false
		echo.Parent = s
		s.Parent = holder
		table.insert(st.sounds, s)
	end
end

local function track(char: Model, isLocal: boolean): CharState?
	local existing = states[char]
	if existing then
		return existing
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local feet: { BasePart } = {}
	for _, n in { "LeftFoot", "RightFoot", "Left Leg", "Right Leg" } do
		local f = char:FindFirstChild(n)
		if f and f:IsA("BasePart") and #feet < 2 then
			table.insert(feet, f)
		end
	end
	local st: CharState = {
		char = char, root = root, humanoid = char:FindFirstChildOfClass("Humanoid"), feet = feet,
		h1 = { 0, 0 }, h2 = { 0, 0 }, lo = -2, hi = -1.5, lastStep = 0, lastFoot = { 0, 0 },
		sounds = {}, nextVoice = 1, lastClip = nil, grounded = false, groundCat = "rock", groundAt = 0,
		isLocal = isLocal, steps = 0,
	}
	buildPool(st)
	states[char] = st
	char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			states[char] = nil
		end
	end)
	return st
end

local function pickClip(st: CharState, list: { string }): string
	if #list == 1 then
		return list[1]
	end
	local name = list[rng:NextInteger(1, #list)]
	if name == st.lastClip then
		name = list[(table.find(list, name) :: number) % #list + 1]
	end
	st.lastClip = name
	return name
end

local function play(st: CharState, category: string, clipName: string, volume: number, pitchMul: number)
	local voice = VOICES[category] or VOICES.rock
	local clip = CLIPS[clipName]
	if not clip then
		return
	end
	-- choose a free voice; otherwise steal the next one in rotation (never more than POOL at once)
	local s: Sound? = nil
	local busy = 0
	for _, cand in st.sounds do
		if cand.IsPlaying then
			busy += 1
		elseif not s then
			s = cand
		end
	end
	if not s then
		s = st.sounds[st.nextVoice]
		st.nextVoice = st.nextVoice % #st.sounds + 1
		stats.stolen += 1
		;(s :: Sound):Stop()
	end
	stats.maxConcurrent = math.max(stats.maxConcurrent, busy + 1)
	local snd = s :: Sound
	local id = "rbxassetid://" .. clip.id
	if snd.SoundId ~= id then
		snd.SoundId = id
	end
	snd.PlaybackRegion = NumberRange.new(clip.from, clip.to)
	snd.PlaybackSpeed = rng:NextNumber(voice.pitch[1], voice.pitch[2]) * pitchMul
	snd.Volume = math.clamp(volume * voice.volume * clip.gain, 0, 10)
	local eq = snd:FindFirstChild("EQ") :: EqualizerSoundEffect?
	if eq then
		eq.LowGain, eq.MidGain, eq.HighGain = voice.eq[1], voice.eq[2], voice.eq[3]
	end
	local echo = snd:FindFirstChild("Echo") :: EchoSoundEffect?
	if echo then
		echo.Enabled = voice.echo == true
	end
	snd.TimePosition = clip.from
	snd:Play()
end

local footRay = RaycastParams.new()
footRay.FilterType = Enum.RaycastFilterType.Exclude

local function step(st: CharState, footIndex: number, speed: number)
	local t = os.clock()
	if t - st.lastStep < MIN_STEP_GAP then
		return
	end
	st.lastStep = t
	st.lastFoot[footIndex] = t
	-- surface under the planting foot itself (one short ray along -up per step), else what the root stands on
	local cat = st.groundCat
	local plant = st.feet[footIndex]
	if plant then
		local up = st.root.CFrame.UpVector
		footRay.FilterDescendantsInstances = { st.char }
		local hit = Workspace:Raycast(plant.Position + up * 1.2, -up * 2.6, footRay)
		if hit then
			cat = categoryOf(hit.Instance, hit.Material, hit.Position)
		end
	end
	local voice = VOICES[cat] or VOICES.rock
	local intensity = math.clamp(speed / 33, 0.45, 1)
	play(st, cat, pickClip(st, voice.clips), STEP_VOLUME * (0.65 + 0.35 * intensity), 1)
	st.steps += 1
	stats.steps += 1
	stats.byCategory[cat] = (stats.byCategory[cat] or 0) + 1
	local foot = st.feet[footIndex]
	Footsteps.Step:Fire(st.char, cat, if foot then foot.Position else st.root.Position, st.root.CFrame.UpVector, intensity)
	if st.isLocal and RunService:IsStudio() then
		st.char:SetAttribute("PFStepCount", st.steps)
		st.char:SetAttribute("PFStepSurface", cat)
	end
end

-- foot plant detector: a local minimum of the foot's height (along up, relative to the root) in the lower
-- part of its recent range. lo / hi relax slowly so the range adapts to any rig and animation.
local function detect(st: CharState, up: Vector3, speed: number, dt: number)
	local rootPos = st.root.Position
	local relax = math.min(1, dt * 0.8)
	for i, foot in st.feet do
		local h = (foot.Position - rootPos):Dot(up)
		st.lo = math.min(st.lo + (h - st.lo) * relax * 0.1, h)
		st.hi = math.max(st.hi + (h - st.hi) * relax * 0.1, h)
		local a, b = st.h2[i], st.h1[i]
		if b <= a and b < h and b < st.lo + (st.hi - st.lo) * 0.3 and os.clock() - st.lastFoot[i] > 0.15 then
			step(st, i, speed)
		end
		st.h2[i], st.h1[i] = b, h
	end
end

local function timerCadence(st: CharState, speed: number)
	-- rigs without feet: alternate on a stride timer matched to speed
	local period = math.clamp(4.6 / math.max(speed, 1), 0.14, 0.55)
	if os.clock() - st.lastStep >= period then
		step(st, 1, speed)
	end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local remoteAcc = 0
local remoteList: { Model } = {}

local function updateLocal(dt: number)
	local char = gravity.getCharacter()
	if not char then
		return
	end
	local st = track(char, true)
	if not st or st.root.Anchored then
		return
	end
	local motion = gravity.getMotion()
	local ground = gravity.getGround()
	if not motion.grounded or not ground then
		return
	end
	st.groundCat = categoryOf(ground.instance, ground.material, ground.position)
	if motion.speed < MIN_MOVE_SPEED then
		return
	end
	if #st.feet == 2 then
		detect(st, gravity.getUp(), motion.speed, dt)
	else
		timerCadence(st, motion.speed)
	end
end

local function updateRemote(dt: number)
	remoteAcc += dt
	local me = Players.LocalPlayer.Character
	local cam = Workspace.CurrentCamera
	if remoteAcc >= 0.5 and cam then
		remoteAcc = 0
		local list = {}
		local camPos = cam.CFrame.Position
		for _, p in Players:GetPlayers() do
			local ch = p.Character
			local r = ch and ch:FindFirstChild("HumanoidRootPart")
			if ch and ch ~= me and r and r:IsA("BasePart") then
				local d = (r.Position - camPos).Magnitude
				if d <= REMOTE_RANGE then
					table.insert(list, { ch = ch, d = d })
				end
			end
		end
		table.sort(list, function(a, b)
			return a.d < b.d
		end)
		table.clear(remoteList)
		for i = 1, math.min(#list, MAX_REMOTE) do
			table.insert(remoteList, list[i].ch)
		end
	end
	local t = os.clock()
	for _, ch in remoteList do
		local st = track(ch, false)
		if st and st.root.Parent and not st.root.Anchored then
			local up = st.root.CFrame.UpVector -- the owner's gravity controller keeps it on the field up
			if t - st.groundAt > 0.2 then
				st.groundAt = t
				rayParams.FilterDescendantsInstances = { ch }
				local hip = (if st.humanoid then st.humanoid.HipHeight else 2) + st.root.Size.Y * 0.5
				local hit = Workspace:Raycast(st.root.Position, -up * (hip + 1.2), rayParams)
				st.grounded = hit ~= nil
				if hit then
					st.groundCat = categoryOf(hit.Instance, hit.Material, hit.Position)
				end
			end
			local v = st.root.AssemblyLinearVelocity
			local speed = (v - up * v:Dot(up)).Magnitude
			if st.grounded and speed >= MIN_MOVE_SPEED then
				if #st.feet == 2 then
					detect(st, up, speed, dt)
				else
					timerCadence(st, speed)
				end
			end
		end
	end
end

local function onLanded(impact: number, ground: any)
	local char = gravity.getCharacter()
	if not char or impact < LAND_MIN_SPEED then
		return
	end
	local st = track(char, true)
	if not st then
		return
	end
	local cat = categoryOf(ground and ground.instance, ground and ground.material or Enum.Material.Rock, ground and ground.position or st.root.Position)
	local intensity = math.clamp((impact - LAND_MIN_SPEED) / 60, 0, 1)
	local list = LANDING_CLIPS[cat] or { "landDirt" }
	local pitch = if cat == "ice" or cat == "crystal" then 1.25 elseif cat == "metal" then 0.75 else 1
	play(st, cat, pickClip(st, list), LAND_VOLUME * (0.45 + 0.55 * intensity), pitch / (VOICES[cat] or VOICES.rock).pitch[1])
	st.lastStep = os.clock() -- no footstep right on top of the landing
	stats.landings += 1
	Footsteps.Landed:Fire(char, cat, if ground then ground.position else st.root.Position, gravity.getUp(), intensity)
	if RunService:IsStudio() then
		char:SetAttribute("PFLandCount", stats.landings)
		char:SetAttribute("PFLandSurface", cat)
	end
end

function Footsteps.init(gravityController: any)
	if gravity then
		return
	end
	gravity = gravityController
	fields = gravity.getFields and gravity.getFields() or nil
	footGroup()
	task.spawn(function()
		local preload = {}
		local seen = {}
		for _, c in CLIPS do
			if not seen[c.id] then
				seen[c.id] = true
				local s = Instance.new("Sound")
				s.SoundId = "rbxassetid://" .. c.id
				table.insert(preload, s)
			end
		end
		pcall(function()
			ContentProvider:PreloadAsync(preload)
		end)
	end)
	gravity.Landed:Connect(onLanded)
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(updateLocal, dt)
		if not ok then
			warn("[PF] Footsteps (local):", err)
		end
		local ok2, err2 = pcall(updateRemote, dt)
		if not ok2 then
			warn("[PF] Footsteps (remote):", err2)
		end
	end)
end

-- read-only diagnostics (tests, debug panel)
function Footsteps.stats()
	return stats
end
Footsteps.CLIPS = CLIPS
Footsteps.VOICES = VOICES
Footsteps.categoryOf = categoryOf

return Footsteps
