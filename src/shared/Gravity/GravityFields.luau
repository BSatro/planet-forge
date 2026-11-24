--!strict
-- GravityFields — owner: Developer A. Pure gravity-field model shared by the client controller
-- (forces) and the server (recovery checks). No Instance access.
--
-- Field kinds:
--   "planet"  : radial gravity towards `center` inside `influence` radius.
--   "uniform" : constant direction inside an axis-aligned box (station deck).
--   "space"   : no field (returned when nothing contains the point).
-- Highest priority wins; ties go to the field with the smallest altitude.

local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)

export type FieldKind = "planet" | "uniform" | "space"

export type Field = {
	id: string,
	kind: FieldKind,
	priority: number,
	strength: number, -- studs/s^2
	center: Vector3,
	radius: number?, -- planet surface radius
	influence: number?, -- planet field radius
	halfSize: Vector3?, -- uniform box half extents
	up: Vector3?, -- uniform "up" (gravity is -up)
	surfaceHeight: number?, -- uniform: world Y of the walkable surface (altitude reference)
	slot: number?,
}

export type Sample = {
	id: string,
	kind: FieldKind,
	up: Vector3,
	strength: number,
	altitude: number, -- distance above the field's reference surface (planet: above the sphere)
	center: Vector3?,
	radius: number?,
	slot: number?,
}

local GravityFields = {}

GravityFields.STATION_G = 196.2
GravityFields.PLANET_G = 160
GravityFields.INFLUENCE_FACTOR = 2.5

local SPACE: Sample = table.freeze({
	id = "space",
	kind = "space" :: FieldKind,
	up = Vector3.yAxis,
	strength = 0,
	altitude = math.huge,
})
GravityFields.SPACE = SPACE

function GravityFields.isFinite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < math.huge and math.abs(v.Y) < math.huge and math.abs(v.Z) < math.huge
end

function GravityFields.planetField(slot: number, center: Vector3, radius: number): Field
	return {
		id = "planet_" .. slot,
		kind = "planet",
		priority = 5,
		strength = GravityFields.PLANET_G,
		center = center,
		radius = radius,
		influence = radius * GravityFields.INFLUENCE_FACTOR,
		slot = slot,
	}
end

function GravityFields.stationField(): Field
	local deck = WorldLayout.STATION_DECK_SIZE
	local top = WorldLayout.STATION_CENTER.Y + deck.Y / 2
	return {
		id = "station",
		kind = "uniform",
		priority = 10,
		strength = GravityFields.STATION_G,
		-- box spans 20 studs below the deck to 80 above it and covers the docks (+14 studs margin)
		center = Vector3.new(WorldLayout.STATION_CENTER.X, top + 30, WorldLayout.STATION_CENTER.Z),
		halfSize = Vector3.new(WorldLayout.DOCK_OUTER_RADIUS + 14, 50, WorldLayout.DOCK_OUTER_RADIUS + 14),
		up = Vector3.yAxis,
		surfaceHeight = top,
	}
end

-- Cosmic Rift arenas: one flat gravity box per arena slot (RiftConfig), so the client controller and the
-- server recovery watchdog both treat the rift as walkable space, never as "lost in space".
function GravityFields.riftFields(): { Field }
	local ok, RiftConfig = pcall(function()
		return require(script.Parent.Parent.Rift.RiftConfig) :: any
	end)
	local list: { Field } = {}
	if not ok then
		return list
	end
	for slot = 1, RiftConfig.MAX_RUNS do
		local o = RiftConfig.arenaOrigin(slot)
		table.insert(list, {
			id = "rift_" .. slot,
			kind = "uniform",
			priority = 10,
			strength = GravityFields.STATION_G,
			center = o,
			halfSize = RiftConfig.FIELD_HALF,
			up = Vector3.yAxis,
			surfaceHeight = o.Y,
		} :: Field)
	end
	return list
end

-- Default field list for the current WorldLayout (station + active slots + rift arenas).
function GravityFields.buildDefault(): { Field }
	local list: { Field } = { GravityFields.stationField() }
	for _, f in GravityFields.riftFields() do
		table.insert(list, f)
	end
	for _, slot in WorldLayout.ACTIVE_SLOTS do
		table.insert(list, GravityFields.planetField(slot, WorldLayout.getSlotCenter(slot), WorldLayout.PLANET_RADIUS))
	end
	return list
end

function GravityFields.sample(fields: { Field }, position: Vector3): Sample
	if not GravityFields.isFinite(position) then
		return SPACE
	end
	local best: Sample? = nil
	local bestPriority = -math.huge
	for _, f in fields do
		local candidate: Sample? = nil
		if f.kind == "planet" then
			local offset = position - f.center
			local dist = offset.Magnitude
			if dist > 1e-3 and dist <= (f.influence :: number) then
				candidate = {
					id = f.id,
					kind = "planet",
					up = offset / dist,
					strength = f.strength,
					altitude = dist - (f.radius :: number),
					center = f.center,
					radius = f.radius,
					slot = f.slot,
				}
			end
		elseif f.kind == "uniform" then
			local d = position - f.center
			local h = f.halfSize :: Vector3
			if math.abs(d.X) <= h.X and math.abs(d.Y) <= h.Y and math.abs(d.Z) <= h.Z then
				local up = (f.up :: Vector3).Unit
				candidate = {
					id = f.id,
					kind = "uniform",
					up = up,
					strength = f.strength,
					altitude = position.Y - (f.surfaceHeight or f.center.Y),
				}
			end
		end
		if candidate then
			if f.priority > bestPriority or (f.priority == bestPriority and best and candidate.altitude < best.altitude) then
				best = candidate
				bestPriority = f.priority
			end
		end
	end
	return best or SPACE
end

return GravityFields
