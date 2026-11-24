--!strict
-- Migrations — owner: Developer B. Ordered, one-way profile schema upgrades.
--   STEPS[n] converts a vN profile into v(N+1). Steps must be pure, must not yield, and must tolerate
--   partially-shaped data (ProfileSchema.reconcile runs afterwards and fills/clamps everything).
-- Rules:
--   * Never edit a shipped step. Append STEPS[CURRENT] and bump ProfileSchema.CURRENT_VERSION.
--   * Additive changes (new ids/params/branches) need no step — reconcile covers them.
--   * A save NEWER than this server's version is refused (FUTURE_SCHEMA) instead of being downgraded, so
--     an old server during a rolling update can never overwrite data written by a newer one.
--
-- Example of a future step (v1 -> v2 renaming a material id):
--   STEPS[1] = function(p)
--       local m = p.materials or {}
--       m.NewIceId = (m.NewIceId or 0) + (m.IceMatter or 0); m.IceMatter = nil
--       return p
--   end

local Migrations = {}

local function finite(v: any, fallback: number): number
	return if type(v) == "number" and v == v and math.abs(v) ~= math.huge then v else fallback
end

Migrations.STEPS = {
	-- v0 = unversioned pre-release saves. Structure is compatible; reconcile fills the gaps.
	[0] = function(p: any): any
		return p
	end,
	-- v1 -> v2: Planet DNA & Evolution Engine.
	--   DNA {Temperature -100..100, Hydrosphere, Atmosphere, Tectonics, Luminosity} -> {Temperature, Water,
	--   Life, CosmicEnergy} 0..100. v1 had no way to earn DNA, so defaults map to the new barren defaults
	--   and only values ABOVE the old defaults carry over. Old branch ids (Primordial/Cryogenic/Volcanic/
	--   Stellar) were never earnable -> "None" (stage is recomputed from the Codex). Formation timestamps
	--   become { n = 1, t = ts }. Everything replaced is kept under planet.legacy for audit.
	[1] = function(p: any): any
		local planet = if type(p.planet) == "table" then p.planet else {}
		local old = if type(planet.dna) == "table" then planet.dna else {}
		planet.legacy = { v = 1, dna = old, branch = planet.branch, stage = planet.stage }
		planet.dna = {
			Temperature = math.clamp(math.floor(40 + finite(old.Temperature, 0) * 0.3 + 0.5), 0, 100),
			Water = math.clamp(math.floor(finite(old.Hydrosphere, 20) - 20 + 0.5), 0, 100),
			Life = 0,
			CosmicEnergy = math.clamp(math.floor(finite(old.Luminosity, 50) - 50 + 0.5), 0, 100),
		}
		planet.branch = "None"
		planet.stage = 0
		local formations = {}
		if type(planet.formations) == "table" then
			for id, v in planet.formations do
				if type(id) == "string" then
					formations[id] = { n = 1, t = if type(v) == "number" then v else nil }
				end
			end
		end
		planet.formations = formations
		p.planet = planet
		if type(p.reactions) ~= "table" then
			p.reactions = {}
		end
		return p
	end,
} :: { [number]: (any) -> any }

-- Returns ok, profileOrErrorCode
function Migrations.run(profile: any, targetVersion: number, steps: { [number]: (any) -> any }?): (boolean, any)
	local list = steps or Migrations.STEPS
	if type(profile) ~= "table" then
		return false, "CORRUPT_PROFILE"
	end
	local v = profile.schemaVersion
	if v == nil then
		v = 0
	end
	if type(v) ~= "number" or v ~= v or v % 1 ~= 0 or v < 0 then
		return false, "CORRUPT_VERSION"
	end
	if v > targetVersion then
		return false, "FUTURE_SCHEMA"
	end
	while v < targetVersion do
		local step = list[v]
		if not step then
			return false, "MISSING_MIGRATION_" .. v
		end
		local ok, res = pcall(step, profile)
		if not ok or type(res) ~= "table" then
			warn("[PF][Data] migration from v" .. v .. " failed: " .. tostring(res))
			return false, "MIGRATION_FAILED"
		end
		profile = res
		v += 1
		profile.schemaVersion = v
	end
	return true, profile
end

return Migrations
