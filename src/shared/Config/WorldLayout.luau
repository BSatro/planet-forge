--!strict
-- WorldLayout — owner: Developer A. Pure constants/helpers (PROJECT_SPEC §7, ADR-005, ADR-014).
-- No Instance access; safe to require on server, client and in Edit-mode tests.

local WorldLayout = {}

WorldLayout.STATION_CENTER = Vector3.new(0, 3000, 0) -- centre of THE FORGE plaza deck
WorldLayout.STATION_DECK_SIZE = Vector3.new(170, 6, 170) -- circular plaza: X/Z = diameter, Y = thickness
WorldLayout.DOCK_INNER_RADIUS = 84 -- docking sectors run from the plaza edge...
WorldLayout.DOCK_OUTER_RADIUS = 116 -- ...to here
WorldLayout.DOCK_PAD_RADIUS = 106 -- warp pad centre on each dock
WorldLayout.DOCK_ARRIVAL_RADIUS = 93 -- arrival point on each dock (between plaza and pad)
WorldLayout.ORBIT_RADIUS = 1100
WorldLayout.SLOT_COUNT = 8
-- ADR-014 (revised 2026-11-23, planet scale rework): 160. The largest radius that keeps the 8-slot ring on
-- ORBIT_RADIUS 1100 valid without other changes: neighbour centres are 842 studs apart, planet gravity
-- influence is 2.5 R = 400 (fields never overlap: 800 < 842) and "on a planet" (EvolutionConfig 2.6 R = 416)
-- stays inside half the spacing (421). 180 would need ORBIT_RADIUS >= 1180 or a weaker gravity reach.
-- Formation art is scaled down around the player (FormationDensity.TIER_SCALE), the character keeps its size.
WorldLayout.PLANET_RADIUS = 160
WorldLayout.ACTIVE_SLOTS = { 1, 2, 3, 4, 5, 6, 7, 8 }

function WorldLayout.getSlotAngle(slot: number): number
	return math.rad((slot - 1) * 360 / WorldLayout.SLOT_COUNT)
end

function WorldLayout.getDeckTop(): number
	return WorldLayout.STATION_CENTER.Y + WorldLayout.STATION_DECK_SIZE.Y / 2
end

function WorldLayout.isValidSlot(slot: any): boolean
	return type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= WorldLayout.SLOT_COUNT
end

function WorldLayout.isActiveSlot(slot: any): boolean
	if not WorldLayout.isValidSlot(slot) then
		return false
	end
	return table.find(WorldLayout.ACTIVE_SLOTS, slot) ~= nil
end

function WorldLayout.getSlotCenter(slot: number): Vector3
	assert(WorldLayout.isValidSlot(slot), "WorldLayout.getSlotCenter: invalid slot")
	local a = math.rad((slot - 1) * 360 / WorldLayout.SLOT_COUNT)
	return WorldLayout.STATION_CENTER + Vector3.new(math.cos(a), 0, math.sin(a)) * WorldLayout.ORBIT_RADIUS
end

-- Orthonormal CFrame whose UpVector == normal (rotation only). `twist` rotates around the normal.
function WorldLayout.frameFromUp(normal: Vector3, twist: number?): CFrame
	local up = normal.Unit
	local ref = if math.abs(up.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
	local right = ref:Cross(up).Unit
	local back = right:Cross(up).Unit
	return CFrame.fromMatrix(Vector3.zero, right, up, back) * CFrame.Angles(0, twist or 0, 0)
end

-- CFrame standing on a sphere surface: position at `height` above the surface along `normal`, up = normal.
function WorldLayout.surfaceCFrame(center: Vector3, radius: number, normal: Vector3, height: number): CFrame
	local n = normal.Unit
	return CFrame.new(center + n * (radius + height)) * WorldLayout.frameFromUp(n)
end

-- Default spawn: on the plaza, south of the reactor, facing it.
function WorldLayout.getStationSpawn(): CFrame
	local c = WorldLayout.STATION_CENTER
	local pos = Vector3.new(c.X, WorldLayout.getDeckTop() + 3.5, c.Z + 34)
	return CFrame.lookAt(pos, Vector3.new(c.X, pos.Y, c.Z))
end

-- Arrival on the station when returning from planet `slot`: on that planet's dock, facing the plaza.
function WorldLayout.getStationArrival(slot: number): CFrame
	local a = WorldLayout.getSlotAngle(slot)
	local c = WorldLayout.STATION_CENTER
	local pos = Vector3.new(c.X + math.cos(a) * WorldLayout.DOCK_ARRIVAL_RADIUS, WorldLayout.getDeckTop() + 3.5, c.Z + math.sin(a) * WorldLayout.DOCK_ARRIVAL_RADIUS)
	return CFrame.lookAt(pos, Vector3.new(c.X, pos.Y, c.Z))
end

-- Spawn point on a planet: 10 degrees off the north pole so it doesn't overlap the pole warp pad.
function WorldLayout.getPlanetSpawn(slot: number): CFrame
	local tilt = math.rad(10)
	local normal = Vector3.new(math.sin(tilt), math.cos(tilt), 0)
	return WorldLayout.surfaceCFrame(WorldLayout.getSlotCenter(slot), WorldLayout.PLANET_RADIUS, normal, 3.5)
end

-- Warp pad positions (centre of the pad's top surface).
function WorldLayout.getStationPadPosition(slot: number): Vector3
	local a = WorldLayout.getSlotAngle(slot)
	local r = WorldLayout.DOCK_PAD_RADIUS
	return Vector3.new(WorldLayout.STATION_CENTER.X + math.cos(a) * r, WorldLayout.getDeckTop(), WorldLayout.STATION_CENTER.Z + math.sin(a) * r)
end

function WorldLayout.getPlanetPadPosition(slot: number): Vector3
	return WorldLayout.getSlotCenter(slot) + Vector3.yAxis * WorldLayout.PLANET_RADIUS
end

return WorldLayout
