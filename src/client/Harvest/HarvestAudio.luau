--!strict
-- HarvestAudio — owner: Gameplay / Technical Art (sound). Client-only harvest sounds.
-- Sources: engine-bundled rbxasset:// sounds (always available, no permissions) shaped with pitch, EQ and a
-- light reverb, plus one vetted library loop already used by the game (Pro Sound Effects "Metallic Glow Hum",
-- rbxassetid://9125674114) for the charge tone. No other uploaded audio is required.
-- Comfort rules: moderate volumes, harsh highs cut by EQ, at most MAX_VOICES one-shots at a time, the charge
-- loop fades in/out instead of starting hard.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local HarvestAudio = {}

type Def = { id: string, volume: number, pitch: number, eqHigh: number?, verb: boolean? }

local DEFS: { [string]: Def } = {
	-- session / UI
	enter = { id = "rbxasset://sounds/button.wav", volume = 0.45, pitch = 0.7 },
	exit = { id = "rbxasset://sounds/button.wav", volume = 0.35, pitch = 0.55 },
	hover = { id = "rbxasset://sounds/switch.wav", volume = 0.15, pitch = 1.8 },
	lock = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.4, pitch = 1.35, verb = true },
	window = { id = "rbxasset://sounds/clickfast.wav", volume = 0.12, pitch = 2.2 },
	denied = { id = "rbxasset://sounds/Kerplunk.wav", volume = 0.3, pitch = 0.6 },
	-- pulse emitter
	charge = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.18, pitch = 0.55, verb = true },
	charged = { id = "rbxasset://sounds/clickfast.wav", volume = 0.28, pitch = 1.7 },
	fire = { id = "rbxasset://sounds/Launching rocket.wav", volume = 0.38, pitch = 2.3, eqHigh = -9 },
	fireBass = { id = "rbxasset://sounds/bass.wav", volume = 0.45, pitch = 1.6 },
	reload = { id = "rbxasset://sounds/unsheath.wav", volume = 0.16, pitch = 0.7, eqHigh = -8 },
	ready = { id = "rbxasset://sounds/switch.wav", volume = 0.22, pitch = 1.25 },
	readyChime = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.12, pitch = 2.2, verb = true },
	-- hits / captures
	impact = { id = "rbxasset://sounds/collide.wav", volume = 0.42, pitch = 0.75, eqHigh = -6 },
	iceHit = { id = "rbxasset://sounds/glassbreak.wav", volume = 0.26, pitch = 1.4, eqHigh = -6 },
	absorb = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.5, pitch = 0.9, verb = true },
	perfect = { id = "rbxasset://sounds/victory.wav", volume = 0.32, pitch = 1.25, verb = true },
	first = { id = "rbxasset://sounds/victory.wav", volume = 0.45, pitch = 1.0, verb = true },
	rare = { id = "rbxasset://sounds/victory.wav", volume = 0.36, pitch = 0.85, verb = true },
	miss = { id = "rbxasset://sounds/swordlunge.wav", volume = 0.2, pitch = 0.8, eqHigh = -10 },
	missThud = { id = "rbxasset://sounds/snap.wav", volume = 0.3, pitch = 0.55 },
	telegraph = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.36, pitch = 0.45, verb = true },
	split = { id = "rbxasset://sounds/collide.wav", volume = 0.42, pitch = 1.35, eqHigh = -6 },
	-- impact families (layered on top of "impact")
	zap = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.24, pitch = 2.0 },
	zapSnap = { id = "rbxasset://sounds/snap.wav", volume = 0.2, pitch = 1.6 },
	splat = { id = "rbxasset://sounds/paintball.wav", volume = 0.3, pitch = 0.8 },
	clang = { id = "rbxasset://sounds/hit.wav", volume = 0.32, pitch = 0.8, eqHigh = -4 },
	shimmer = { id = "rbxasset://sounds/glassbreak.wav", volume = 0.14, pitch = 2.0, eqHigh = -8 },
	radiant = { id = "rbxasset://sounds/victory.wav", volume = 0.18, pitch = 1.6, verb = true },
	sub = { id = "rbxasset://sounds/bass.wav", volume = 0.45, pitch = 0.5, verb = true },
	sizzle = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.12, pitch = 1.5, eqHigh = -6 },
}

-- Impact family -> extra layers { name, pitchMul }
local FAMILY: { [string]: { { any } } } = {
	shatter = { { "iceHit", 1.0 }, { "shimmer", 1.0 } },
	molten = { { "sizzle", 1.0 } },
	electric = { { "zap", 1.0 }, { "zapSnap", 1.0 } },
	spore = { { "splat", 1.0 } },
	metal = { { "clang", 1.0 } },
	rock = { { "impact", 0.9 } },
	stardust = { { "shimmer", 0.9 }, { "zap", 0.7 } },
	radiant = { { "radiant", 1.0 } },
	void = { { "sub", 1.0 } },
	prism = { { "shimmer", 1.1 }, { "radiant", 1.2 } },
}

local CHARGE_LOOP = "rbxassetid://9125674114" -- Pro Sound Effects "Metallic Glow ... Hum 2" (verified in this game)
local MAX_VOICES = 10

local group: SoundGroup? = nil
local templates: { [string]: Sound } = {}
local voices = 0
local loop: Sound? = nil
local loopTween: Tween? = nil

local function ensure()
	if group then
		return
	end
	local g = Instance.new("SoundGroup")
	g.Name = "PF_HarvestSFX"
	g.Volume = 1
	g.Parent = SoundService
	group = g
	for name, d in DEFS do
		local s = Instance.new("Sound")
		s.Name = name
		s.SoundId = d.id
		s.Volume = d.volume
		s.PlaybackSpeed = d.pitch
		s.SoundGroup = g
		if d.eqHigh then
			local eq = Instance.new("EqualizerSoundEffect")
			eq.HighGain = d.eqHigh
			eq.MidGain = 0
			eq.LowGain = 0
			eq.Parent = s
		end
		if d.verb then
			local rv = Instance.new("ReverbSoundEffect")
			rv.DecayTime = 0.9
			rv.WetLevel = -12
			rv.DryLevel = 0
			rv.Parent = s
		end
		s.Parent = g
		templates[name] = s
	end
end

-- pitchMul lets callers vary pitch (e.g. by meteor type) without new assets.
function HarvestAudio.play(name: string, pitchMul: number?, volumeMul: number?)
	ensure()
	local t = templates[name]
	if not t or voices >= MAX_VOICES then
		return
	end
	voices += 1
	local s = t:Clone()
	s.PlaybackSpeed = t.PlaybackSpeed * (pitchMul or 1)
	s.Volume = t.Volume * (volumeMul or 1)
	s.Parent = group
	s:Play()
	local released = false
	local function free()
		if not released then
			released = true
			voices = math.max(0, voices - 1)
			s:Destroy()
		end
	end
	s.Ended:Once(free)
	task.delay(6, free)
end

-- Category impact: a base thump + the family's own layers.
function HarvestAudio.impact(family: string?, pitchMul: number?)
	local p = pitchMul or 1
	if family ~= "rock" and family ~= "metal" then
		HarvestAudio.play("impact", p, 0.7)
	end
	for _, layer in FAMILY[family or ""] or {} do
		HarvestAudio.play(layer[1], (layer[2] :: number) * p)
	end
end

-- Charge tone: fades in on start, pitch + level rise with the charge (setChargeLevel), fades out on stop.
function HarvestAudio.chargeLoop(on: boolean)
	ensure()
	if on then
		if not loop then
			local s = Instance.new("Sound")
			s.Name = "ChargeLoop"
			s.SoundId = CHARGE_LOOP
			s.Looped = true
			s.Volume = 0
			s.PlaybackSpeed = 0.85
			s.SoundGroup = group
			local eq = Instance.new("EqualizerSoundEffect")
			eq.HighGain = -6
			eq.Parent = s
			s.Parent = group
			loop = s
		end
		local s = loop :: Sound
		if loopTween then
			loopTween:Cancel()
		end
		s.TimePosition = 0
		if not s.IsPlaying then
			s:Play()
		end
		loopTween = TweenService:Create(s, TweenInfo.new(0.12), { Volume = 0.16 })
		;(loopTween :: Tween):Play()
	elseif loop then
		local s = loop
		if loopTween then
			loopTween:Cancel()
		end
		loopTween = TweenService:Create(s, TweenInfo.new(0.15), { Volume = 0 })
		;(loopTween :: Tween):Play()
		task.delay(0.16, function()
			if s.Volume <= 0.01 then
				s:Stop()
			end
		end)
	end
end

function HarvestAudio.setChargeLevel(frac: number)
	local s = loop
	if s and s.IsPlaying then
		local f = math.clamp(frac, 0, 1)
		s.PlaybackSpeed = 0.85 + 0.65 * f
		if not loopTween or loopTween.PlaybackState ~= Enum.PlaybackState.Playing then
			s.Volume = 0.16 + 0.12 * f
		end
	end
end

function HarvestAudio.stats(): { voices: number, looping: boolean }
	return { voices = voices, looping = loop ~= nil and loop.IsPlaying }
end

return HarvestAudio
