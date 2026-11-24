--!strict
-- MeteorStyles — owner: Technical Art (VFX). CLIENT-ONLY presentation data for the 12 meteor variants and
-- their rarity tiers: trails, particles, impact family, approach cue, capture flourish and audio. Gameplay data
-- (speed, hitbox, timing windows, rewards) lives in HarvestConfig and is never read from here, so nothing in
-- this file can change what the server verifies.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local Styles = {}

-- Engine-bundled particle textures (verified to load in this place: ContentProvider status Success, and a
-- missing-file control returns Failure). No uploaded assets are required.
Styles.TEXTURE = {
	sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
	sparks = "rbxasset://textures/particles/fire_sparks_main.dds",
	core = "rbxasset://textures/particles/explosion01_core_main.dds",
	implosion = "rbxasset://textures/particles/explosion01_implosion_main.dds",
	shockwave = "rbxasset://textures/particles/explosion01_shockwave_main.dds",
	dust = "rbxasset://textures/particles/explosion01_smoke_main.dds",
	glow = "rbxasset://textures/particles/forcefield_glow_main.dds",
	vortex = "rbxasset://textures/particles/forcefield_vortex_main.dds",
}

local function cs(...: Color3): ColorSequence
	local list = { ... }
	if #list == 1 then
		return ColorSequence.new(list[1])
	end
	local kps = {}
	for i, c in list do
		table.insert(kps, ColorSequenceKeypoint.new((i - 1) / (#list - 1), c))
	end
	return ColorSequence.new(kps)
end
Styles.cs = cs
local rgb = Color3.fromRGB

-- Rarity presentation: how much presence a tier gets on top of its variant identity.
--   trailLife / trailWidth: ribbon behind the meteor; emission: particle rate multiplier; light: point light
--   multiplier; approach: show the approach cue (entry flare + inbound streak) before it reaches the lane;
--   flourish: capture celebration level (1 simple, 2 accented, 3 full show); spinMul: spin speed
Styles.RARITY = {
	common = { trailLife = 0.5, trailWidth = 0.8, emission = 1.0, light = 1.0, approach = false, flourish = 1, spinMul = 1.0 },
	uncommon = { trailLife = 0.65, trailWidth = 0.95, emission = 1.1, light = 1.1, approach = false, flourish = 1, spinMul = 1.1 },
	rare = { trailLife = 0.8, trailWidth = 1.1, emission = 1.2, light = 1.25, approach = true, flourish = 2, spinMul = 1.2 },
	epic = { trailLife = 1.35, trailWidth = 1.25, emission = 1.3, light = 1.4, approach = true, flourish = 2, spinMul = 1.2 },
	legendary = { trailLife = 1.0, trailWidth = 1.35, emission = 1.4, light = 1.6, approach = true, flourish = 3, spinMul = 0.9 },
	mythic = { trailLife = 0.9, trailWidth = 1.3, emission = 1.35, light = 1.4, approach = true, flourish = 3, spinMul = 0.8 },
	secret = { trailLife = 1.2, trailWidth = 1.4, emission = 1.45, light = 1.7, approach = true, flourish = 3, spinMul = 1.0 },
}

-- Variant identity. trail = ribbon colours (head -> tail); impact = impact family used by HarvestFX and
-- HarvestAudio; burst = impact particle colours.
Styles.VARIANT = {
	Ice = { trail = cs(rgb(235, 252, 255), rgb(120, 210, 255)), impact = "shatter", burst = cs(rgb(220, 250, 255), rgb(130, 210, 255)) },
	Magma = { trail = cs(rgb(255, 210, 110), rgb(255, 90, 30), rgb(90, 35, 20)), impact = "molten", burst = cs(rgb(255, 220, 120), rgb(255, 80, 20)) },
	Plasma = { trail = cs(rgb(255, 190, 255), rgb(170, 90, 255)), impact = "electric", burst = cs(rgb(255, 210, 255), rgb(170, 100, 255)) },
	Crystal = { trail = cs(rgb(255, 200, 245), rgb(160, 230, 255)), impact = "shatter", burst = cs(rgb(255, 180, 240), rgb(160, 230, 255)) },
	Bio = { trail = cs(rgb(210, 255, 160), rgb(90, 220, 120)), impact = "spore", burst = cs(rgb(200, 255, 150), rgb(80, 200, 110)) },
	Iron = { trail = cs(rgb(210, 200, 190), rgb(255, 140, 60), rgb(90, 80, 75)), impact = "metal", burst = cs(rgb(255, 240, 200), rgb(255, 140, 50)) },
	Magnetic = { trail = cs(rgb(255, 90, 90), rgb(200, 150, 255), rgb(90, 150, 255)), impact = "electric", burst = cs(rgb(255, 120, 120), rgb(110, 160, 255)) },
	Split = { trail = cs(rgb(255, 215, 140), rgb(255, 130, 50), rgb(80, 60, 50)), impact = "rock", burst = cs(rgb(255, 210, 130), rgb(160, 110, 80)) },
	Comet = { trail = cs(rgb(255, 255, 235), rgb(255, 215, 120), rgb(120, 200, 255)), impact = "stardust", burst = cs(rgb(255, 250, 210), rgb(255, 200, 90)) },
	Stellar = { trail = cs(rgb(255, 255, 240), rgb(255, 205, 90), rgb(255, 140, 40)), impact = "radiant", burst = cs(rgb(255, 255, 230), rgb(255, 190, 70)) },
	Void = { trail = cs(rgb(200, 130, 255), rgb(110, 30, 200), rgb(20, 8, 40)), impact = "void", burst = cs(rgb(210, 150, 255), rgb(90, 20, 170)) },
	Astral = {
		trail = cs(rgb(120, 255, 235), rgb(150, 170, 255), rgb(255, 150, 255), rgb(255, 230, 140)),
		impact = "prism",
		burst = cs(rgb(120, 255, 235), rgb(255, 150, 255), rgb(255, 230, 140)),
	},
}

function Styles.variant(id: string): any
	return Styles.VARIANT[id] or Styles.VARIANT.Ice
end

-- A target is "fast" (gets an approach cue) at rare rarity or faster than 1.5x the common lane speed.
function Styles.needsApproachCue(rarityId: string, speedMultiplier: number?): boolean
	local r = Styles.RARITY[rarityId]
	return (r ~= nil and r.approach) or (speedMultiplier or 1) >= 1.5
end

-- Quality budgets by the player's Visual effects preset (LocalPlayer attribute PFEffects, mirrored by
-- PlanetVisualController). emission = particle rate multiplier; secondary = second / third emitters;
-- arcs = animated electric arcs; trail = ribbon lifetime multiplier; lights = point lights on commons;
-- ambient = decorative space rocks; burst = impact particle count multiplier.
Styles.QUALITY = {
	full = { emission = 1.0, secondary = true, arcs = true, arcInterval = 0.09, trail = 1.0, lights = true, ambient = 8, burst = 1.0 },
	reduced = { emission = 0.55, secondary = false, arcs = true, arcInterval = 0.16, trail = 0.8, lights = true, ambient = 4, burst = 0.6 },
	minimal = { emission = 0.25, secondary = false, arcs = false, arcInterval = 1, trail = 0.6, lights = false, ambient = 0, burst = 0.35 },
}

function Styles.qualityLevel(): string
	local q = Players.LocalPlayer and Players.LocalPlayer:GetAttribute("PFEffects")
	return if q == "reduced" or q == "minimal" then q else "full"
end

function Styles.quality(): any
	return Styles.QUALITY[Styles.qualityLevel()]
end

-- Reduced motion: the in-game setting (PFReducedMotion, set by SettingsApplier) or the OS / Roblox setting.
function Styles.reducedMotion(): boolean
	local p = Players.LocalPlayer
	if p and p:GetAttribute("PFReducedMotion") == true then
		return true
	end
	local ok, v = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return ok and v == true
end

-- Photosensitivity guard: every pulsing effect in the harvest VFX uses at most this frequency (Hz), well
-- under the 3 flashes/second guideline; reduced motion removes pulsing entirely.
Styles.MAX_PULSE_HZ = 1.5

return Styles
