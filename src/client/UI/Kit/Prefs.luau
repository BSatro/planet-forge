--!strict
-- Prefs — owner: Developer A. Player interface/feel preferences (Settings panel). Session-scoped:
-- there is no server settings store yet (INTERFACES §7.9 asks Developer B for Settings_Update). Values are
-- mirrored to LocalPlayer attributes ("PF<Key>") so other client systems can read them without requiring UI code.
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local Signal = require(game:GetService("ReplicatedStorage").PF_Shared.Util.Signal)

local Prefs = {}
Prefs.Changed = Signal.new() -- (key, value)

local okRM, systemReduced = pcall(function()
	return (GuiService :: any).ReducedMotionEnabled
end)

local values: { [string]: any } = {
	EffectsVolume = 0.8, -- 0..1, PF_SFX and the harvest sound group
	MusicVolume = 0.5, -- 0..1, PF_Music (ambient space music)
	ReducedMotion = okRM and systemReduced == true,
	UiScale = 1, -- 0.8..1.3, multiplies the responsive scale
	CameraSensitivity = 1, -- 0.4..2
	InvertY = false,
	ForgeBot = true, -- First 10 Minutes 2.0: ForgeBot hints (Settings -> Guidance)
}

Prefs.RANGES = table.freeze({
	EffectsVolume = { 0, 1, 0.05 },
	MusicVolume = { 0, 1, 0.05 },
	UiScale = { 0.8, 1.3, 0.05 },
	CameraSensitivity = { 0.4, 2, 0.1 },
})

function Prefs.get(key: string): any
	return values[key]
end

function Prefs.set(key: string, value: any)
	local range = Prefs.RANGES[key]
	if range and type(value) == "number" then
		value = math.clamp(math.round(value / range[3]) * range[3], range[1], range[2])
	end
	if values[key] == value then
		return
	end
	values[key] = value
	local p = Players.LocalPlayer
	if p and (type(value) == "number" or type(value) == "boolean" or type(value) == "string") then
		p:SetAttribute("PF" .. key, value)
	end
	Prefs.Changed:Fire(key, value)
end

function Prefs.reducedMotion(): boolean
	return values.ReducedMotion == true
end

-- publish initial values once
task.defer(function()
	local p = Players.LocalPlayer
	if p then
		for k, v in values do
			p:SetAttribute("PF" .. k, v)
		end
	end
end)

return Prefs
