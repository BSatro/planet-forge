--!strict
-- SkyActivator — owner: Developer A. Optional switch to the baked PLANET FORGE skybox.
-- The DEFAULT sky is local and needs no uploads: Lighting.PF_Sky's native night sky (StarCount 5000) plus the
-- client backdrop. Lighting.PF_Sky may store six uploaded face images as attributes PFPending_Ft/Bk/Lf/Rt/Up/Dn;
-- the client applies them (locally) only if ALL six load, so a pending-moderation or broken image never produces a
-- black or grey sky.
-- 2026-11-22 (QA): ONE attempt per session, no retry loop (the images failed for days and the old 40 x 90 s loop
-- kept retrying). To use new images: upload them, put the ids in the attributes; nothing else to change.

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")

local SkyActivator = {}

local FACES = { "Ft", "Bk", "Lf", "Rt", "Up", "Dn" }

local active = false

-- Planet Physics 3.0 (P4): the engine darkens a custom skybox with the time of day. At the game's night lighting
-- (Lighting.ClockTime 20.5, moon key light) the baked faces rendered pure black, and because baked mode also turns
-- the native stars off (StarCount 0) and makes SpaceBackdrop skip its nebula / gas-giant geometry, players saw an
-- empty black sky. The baked faces are therefore used only while the sun is up; at night the Space Overhaul's
-- native star field + backdrop geometry (the documented default) is the sky.
local DAY_FROM, DAY_TO = 6.5, 17.5
function SkyActivator.bakedUsable(): boolean
	local t = Lighting.ClockTime
	return t >= DAY_FROM and t <= DAY_TO
end

local function pendingIds(sky: Sky): { [string]: string }?
	local ids = {}
	for _, f in FACES do
		local v = sky:GetAttribute("PFPending_" .. f)
		if typeof(v) ~= "string" or v == "" then
			return nil
		end
		ids[f] = v
	end
	return ids
end

-- 2026-11-22 (QA): preload through a probe Sky INSTANCE. PreloadAsync on bare content-id strings reported Failure
-- for every asset (even known-good meshes/sounds), so the approved sky images were never applied. A Sky instance
-- tells the engine what the ids are (sky textures) and returns one status per face.
local function allLoad(ids: { [string]: string }): boolean
	local probe = Instance.new("Sky")
	for _, f in FACES do
		(probe :: any)["Skybox" .. f] = ids[f]
	end
	local good, seen = 0, 0
	local success = pcall(function()
		ContentProvider:PreloadAsync({ probe }, function(_, s)
			seen += 1
			if s == Enum.AssetFetchStatus.Success then
				good += 1
			end
		end)
	end)
	probe:Destroy()
	return success and seen >= #FACES and good == seen
end

function SkyActivator.isActive(): boolean
	return active
end

function SkyActivator.init()
	task.spawn(function()
		local sky = Lighting:WaitForChild("PF_Sky", 20) :: Sky?
		if not sky then
			return
		end
		local ids = pendingIds(sky)
		if not ids then
			return -- nothing configured: the native night sky is the sky
		end
		if not SkyActivator.bakedUsable() then
			print(string.format("[PF] baked skybox skipped: ClockTime %.1f is night (the engine draws custom skyboxes black); native stars + backdrop", Lighting.ClockTime))
			return
		end
		if allLoad(ids) and sky.Parent then
			for _, f in FACES do
				(sky :: any)["Skybox" .. f] = ids[f]
			end
			sky.StarCount = 0 -- stars are baked into the images
			active = true
			print("[PF] baked skybox active")
		end
		-- failure is silent: the native night sky is the intended fallback and nothing retries
	end)
end

return SkyActivator
