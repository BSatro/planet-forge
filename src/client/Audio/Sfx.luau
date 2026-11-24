--!strict
-- Sfx — owner: Developer A. Plays the one-shot sound effects stored in ReplicatedStorage.PF_Assets.Sounds.
--   Sfx.play(name, { volume?, pitch?, at? })
--     2D (UI / own-planet moments) by default; with `at` (Vector3 or BasePart) it plays positionally.
--   Templates: Transformation (stage-up cinematic), Power_Up (stage reached), Whoosh (warp transitions).
--   All sounds go through the "PF_SFX" SoundGroup so a future settings slider can scale them.
--   Missing template -> silently does nothing (the game never depends on audio).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Sfx = {}

local MIN_GAP = 0.12 -- s; identical sound requested twice in a frame burst plays once
local lastPlayed: { [string]: number } = {}

local function group(): SoundGroup
	local g = SoundService:FindFirstChild("PF_SFX")
	if g and g:IsA("SoundGroup") then
		return g
	end
	local ng = Instance.new("SoundGroup")
	ng.Name = "PF_SFX"
	ng.Volume = 1
	ng.Parent = SoundService
	return ng
end

local function template(name: string): Sound?
	local assets = ReplicatedStorage:FindFirstChild("PF_Assets")
	local folder = assets and assets:FindFirstChild("Sounds")
	local s = folder and folder:FindFirstChild(name)
	return if s and s:IsA("Sound") then s else nil
end

function Sfx.play(name: string, opts: { volume: number?, pitch: number?, at: any? }?): Sound?
	local tpl = template(name)
	if not tpl then
		return nil
	end
	local now = os.clock()
	if lastPlayed[name] and now - lastPlayed[name] < MIN_GAP then
		return nil
	end
	lastPlayed[name] = now
	local o = opts or {}
	local s = tpl:Clone()
	s.Looped = false
	s.SoundGroup = group()
	if o.volume then
		s.Volume = o.volume
	end
	if o.pitch then
		s.PlaybackSpeed = o.pitch
	end
	local holder: Instance = SoundService
	if typeof(o.at) == "Instance" and o.at:IsA("BasePart") then
		holder = o.at
	elseif typeof(o.at) == "Vector3" then
		local a = Instance.new("Attachment")
		a.WorldPosition = o.at
		a.Parent = Workspace.Terrain
		holder = a
		Debris:AddItem(a, 8)
	end
	if holder ~= SoundService then
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 40
		s.RollOffMaxDistance = 900
	end
	s.Parent = holder
	s:Play()
	Debris:AddItem(s, math.max(s.TimeLength, 3) + 1)
	return s
end

return Sfx
