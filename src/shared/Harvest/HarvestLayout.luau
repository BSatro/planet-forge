--!strict
-- HarvestLayout — owner: Gameplay (Cosmic Core Hunt). Pure placement math, shared by server (build +
-- verification) and client (visuals + prediction). No Instance access.
--
-- Harvester local space: x = right, y = up (surface normal), z = forward (away from the north pole).
-- base CFrame: Position on the planet surface, UpVector = normal, LookVector = forward.

local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)
local HarvestConfig = require(script.Parent.Parent.Config.HarvestConfig)

export type Layout = {
	slot: number,
	base: CFrame,
	origin: Vector3, -- verification origin for aim (turret head pivot)
	collector: Vector3,
	console: Vector3,
	operator: Vector3,
	camera: Vector3,
	cameraFocus: Vector3,
	toWorld: (Vector3) -> Vector3,
	toLocal: (Vector3) -> Vector3,
}

local HarvestLayout = {}

local function azimuthDelta(a: number, b: number): number
	local d = (a - b) % 360
	return math.min(d, 360 - d)
end

-- Azimuth (degrees, atan2(z, x)) of the harvester position around the north pole for a slot.
function HarvestLayout.getAzimuthDeg(slot: number): number
	local P = HarvestConfig.PLACEMENT
	local center = WorldLayout.getSlotCenter(slot)
	local st = WorldLayout.STATION_CENTER
	local stationSide = math.deg(math.atan2(st.Z - center.Z, st.X - center.X))
	for _, off in P.AZIMUTH_OFFSETS_DEG do
		local az = stationSide + off
		if azimuthDelta(az, P.SPAWN_AZIMUTH_DEG) >= P.MIN_SPAWN_SEPARATION_DEG then
			return az
		end
	end
	return P.SPAWN_AZIMUTH_DEG + 180
end

function HarvestLayout.getBaseCFrame(slot: number): CFrame
	local center = WorldLayout.getSlotCenter(slot)
	local tilt = math.rad(HarvestConfig.PLACEMENT.POLE_ANGLE_DEG)
	local az = math.rad(HarvestLayout.getAzimuthDeg(slot))
	local n = Vector3.new(math.sin(tilt) * math.cos(az), math.cos(tilt), math.sin(tilt) * math.sin(az))
	local pos = center + n * WorldLayout.PLANET_RADIUS
	-- forward = outward (away from the station), projected onto the tangent plane
	local st = WorldLayout.STATION_CENTER
	local outward = Vector3.new(center.X - st.X, 0, center.Z - st.Z)
	outward = if outward.Magnitude > 1e-4 then outward.Unit else Vector3.xAxis
	local fwd = (outward - n * outward:Dot(n)).Unit
	local right = fwd:Cross(n).Unit
	return CFrame.fromMatrix(pos, right, n, -fwd)
end

-- local (x right, y up, z forward) -> object space (Roblox: -Z is forward)
function HarvestLayout.localToObject(v: Vector3): Vector3
	return Vector3.new(v.X, v.Y, -v.Z)
end

local cache: { [number]: Layout } = {}

function HarvestLayout.forSlot(slot: number): Layout
	local cached = cache[slot]
	if cached then
		return cached
	end
	assert(WorldLayout.isValidSlot(slot), "HarvestLayout.forSlot: invalid slot")
	local base = HarvestLayout.getBaseCFrame(slot)
	local D = HarvestConfig.DEVICE
	local function toWorld(v: Vector3): Vector3
		return base:PointToWorldSpace(Vector3.new(v.X, v.Y, -v.Z))
	end
	local function toLocal(w: Vector3): Vector3
		local o = base:PointToObjectSpace(w)
		return Vector3.new(o.X, o.Y, -o.Z)
	end
	local layout: Layout = {
		slot = slot,
		base = base,
		origin = toWorld(D.HEAD_PIVOT),
		collector = toWorld(D.COLLECTOR),
		console = toWorld(D.CONSOLE),
		operator = toWorld(D.OPERATOR),
		camera = toWorld(D.CAMERA),
		cameraFocus = toWorld(D.CAMERA_FOCUS),
		toWorld = toWorld,
		toLocal = toLocal,
	}
	cache[slot] = layout
	return layout
end

-- CFrame at a local position with the base orientation (for building parts).
function HarvestLayout.localCFrame(layout: Layout, v: Vector3): CFrame
	return layout.base * CFrame.new(v.X, v.Y, -v.Z)
end

return HarvestLayout
