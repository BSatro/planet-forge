--!strict
-- SettingsApplier — owner: Developer A. Applies Prefs to the systems that own the behaviour: sound groups
-- (PF_SFX, Cosmic Core Hunt's group), CameraController.CONFIG (sensitivity / invert). Reduced motion is read
-- directly by Motion, TravelFX and PlanetVisualController through the PFReducedMotion player attribute.
local SoundService = game:GetService("SoundService")
local Prefs = require(script.Parent.Kit.Prefs)

local Applier = {}
local deps: any = {}

local function applyVolume()
	local v = Prefs.get("EffectsVolume")
	local g = SoundService:FindFirstChild("PF_SFX")
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = "PF_SFX"
		g.Parent = SoundService
	end
	(g :: SoundGroup).Volume = v
	for _, d in SoundService:GetDescendants() do
		if d:IsA("SoundGroup") and d.Name == "PF_HarvestSFX" then
			d.Volume = v
		end
	end
	local music = SoundService:FindFirstChild("PF_Music")
	if not music then
		music = Instance.new("SoundGroup")
		music.Name = "PF_Music"
		music.Parent = SoundService
	end
	(music :: SoundGroup).Volume = Prefs.get("MusicVolume") or 0.5
end

local function applyCamera()
	local cam = deps.camera
	if cam and cam.CONFIG then
		cam.CONFIG.SensitivityScale = Prefs.get("CameraSensitivity")
		cam.CONFIG.InvertY = Prefs.get("InvertY") == true
	end
end

function Applier.init(d: any)
	deps = d or {}
	applyVolume()
	applyCamera()
	Prefs.Changed:Connect(function(key)
		if key == "EffectsVolume" or key == "MusicVolume" then
			applyVolume()
		elseif key == "CameraSensitivity" or key == "InvertY" then
			applyCamera()
		end
	end)
	SoundService.DescendantAdded:Connect(function(x)
		if x:IsA("SoundGroup") and x.Name == "PF_HarvestSFX" then
			applyVolume()
		end
	end)
end

return Applier
