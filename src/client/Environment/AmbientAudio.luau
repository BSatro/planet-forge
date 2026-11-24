--!strict
-- AmbientAudio — owner: Technical Art (polish pass). Client-only atmosphere:
--   * ambient space music: one quiet looping track in SoundGroup PF_Music (Settings > Music volume)
--   * THE FORGE reactor hum: a 3D looping hum at the station reactor in PF_SFX (Settings > Effects volume),
--     audible only near the station (roll-off), so planets stay calm.
-- Sources: Roblox Creator Store audio from verified libraries (licensed for use in experiences):
--   music  "Slow Breathing Aurora (Space Ambient)"  rbxassetid://140041908508788  (DistroKid official)
--   hum    "Metallic Glow Constant Deep Ticking Bassy Hum 2"  rbxassetid://9125674114  (Pro Sound Effects)
-- If an asset fails to load the game simply stays quiet; nothing else depends on this module.
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local AmbientAudio = {}

AmbientAudio.MUSIC_ID = "rbxassetid://140041908508788"
AmbientAudio.HUM_ID = "rbxassetid://9125674114"
local MUSIC_VOLUME = 0.45 -- before the player's Music volume
local HUM_VOLUME = 0.5 -- before the player's Effects volume

local started = false

local function group(name: string, default: number): SoundGroup
	local g = SoundService:FindFirstChild(name)
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = name
		;(g :: SoundGroup).Volume = default
		g.Parent = SoundService
	end
	return g :: SoundGroup
end

local function startMusic()
	local s = Instance.new("Sound")
	s.Name = "PF_AmbientMusic"
	s.SoundId = AmbientAudio.MUSIC_ID
	s.Looped = true
	s.Volume = 0
	s.SoundGroup = group("PF_Music", 0.5)
	s.Parent = SoundService
	s:Play()
	-- slow fade-in: atmosphere, never a jump-scare at spawn
	task.spawn(function()
		for i = 1, 40 do
			s.Volume = MUSIC_VOLUME * i / 40
			task.wait(0.15)
		end
	end)
end

local function startHum()
	local world = Workspace:WaitForChild("PF_World", 60)
	local station = world and world:WaitForChild("Station", 60)
	local reactor = station and station:WaitForChild("Reactor", 30)
	local anchorPart: BasePart? = nil
	if reactor then
		anchorPart = if reactor:IsA("Model") and reactor.PrimaryPart then reactor.PrimaryPart else reactor:FindFirstChildWhichIsA("BasePart", true)
	end
	if not anchorPart then
		return
	end
	local s = Instance.new("Sound")
	s.Name = "PF_ReactorHum"
	s.SoundId = AmbientAudio.HUM_ID
	s.Looped = true
	s.Volume = HUM_VOLUME
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 25
	s.RollOffMaxDistance = 170
	s.SoundGroup = group("PF_SFX", 0.8)
	s.Parent = anchorPart
	s:Play()
end

function AmbientAudio.init()
	if started then
		return
	end
	started = true
	task.spawn(startMusic)
	task.spawn(function()
		local ok, err = pcall(startHum)
		if not ok then
			warn("[PF][AmbientAudio] reactor hum unavailable: " .. tostring(err))
		end
	end)
end

return AmbientAudio
