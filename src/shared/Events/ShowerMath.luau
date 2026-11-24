--!strict
-- ShowerMath — owner: Live Gameplay. Pure, deterministic meteor motion for the Meteor Shower, shared by the server
-- (spawning + capture validation) and the client (drawing). A meteor is a point on a circle:
--   position(t) = c + (u cos a + v sin a) * r,   a = a0 + w (t - t0),   alive for t0 <= t <= t0 + life
-- Zone 0 is THE FORGE (horizontal rings above the plaza), zones 1..8 are planet slots (great circles in low orbit).
local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)
local EventConfig = require(script.Parent.EventConfig)

local ShowerMath = {}

export type Meteor = {
	id: string,
	zone: number,
	c: Vector3,
	r: number,
	u: Vector3,
	v: Vector3,
	a0: number,
	w: number,
	t0: number,
	life: number,
	rare: boolean,
}

ShowerMath.DECK_OFFSET = 3.3 -- plaza deck top above STATION_CENTER

function ShowerMath.position(m: Meteor, t: number): Vector3
	local a = m.a0 + m.w * (t - m.t0)
	return m.c + (m.u * math.cos(a) + m.v * math.sin(a)) * m.r
end

function ShowerMath.velocity(m: Meteor, t: number): Vector3
	local a = m.a0 + m.w * (t - m.t0)
	return (m.v * math.cos(a) - m.u * math.sin(a)) * (m.r * m.w)
end

function ShowerMath.alive(m: Meteor, t: number): boolean
	return t >= m.t0 - 0.5 and t <= m.t0 + m.life
end

-- centre + surface radius of a zone
function ShowerMath.zoneCenter(zone: number): (Vector3, number)
	if zone == 0 then
		return WorldLayout.STATION_CENTER, 85
	end
	return WorldLayout.getSlotCenter(zone), WorldLayout.PLANET_RADIUS
end

-- Which zone (if any) a world position belongs to (for presence and spawn bias).
function ShowerMath.zoneAt(pos: Vector3): number?
	local st = WorldLayout.STATION_CENTER
	local flat = Vector3.new(pos.X - st.X, 0, pos.Z - st.Z)
	if flat.Magnitude <= 120 and math.abs(pos.Y - st.Y) <= 80 then
		return 0
	end
	local reach = WorldLayout.PLANET_RADIUS + EventConfig.SHOWER.planet.presenceRadius
	for slot = 1, WorldLayout.SLOT_COUNT do
		if WorldLayout.isActiveSlot(slot) and (pos - WorldLayout.getSlotCenter(slot)).Magnitude <= reach then
			return slot
		end
	end
	return nil
end

local function range(rng: Random, t: { number }): number
	return t[1] + (t[2] - t[1]) * rng:NextNumber()
end

local function perpendicular(n: Vector3, rng: Random): Vector3
	for _ = 1, 4 do
		local r = rng:NextUnitVector()
		local d = r - n * r:Dot(n)
		if d.Magnitude > 0.2 then
			return d.Unit
		end
	end
	local alt = if math.abs(n.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	return n:Cross(alt).Unit
end

-- Plans one meteor path. `near` (optional) = a player position the meteor should pass close to (keeps showers
-- fun on empty servers: meteors come to the players instead of the whole sphere).
function ShowerMath.plan(id: string, zone: number, t0: number, rng: Random, near: Vector3?, rare: boolean): Meteor
	local S = EventConfig.SHOWER
	local life = range(rng, S.life)
	if zone == 0 then
		local st = WorldLayout.STATION_CENTER
		local h = range(rng, S.station.height)
		local c = Vector3.new(st.X, st.Y + ShowerMath.DECK_OFFSET + h, st.Z)
		local w = range(rng, S.station.speed) * (if rng:NextNumber() < 0.5 then -1 else 1)
		local r = range(rng, S.station.radius)
		local a0 = rng:NextNumber() * math.pi * 2
		if near then
			local flat = Vector3.new(near.X - st.X, 0, near.Z - st.Z)
			if flat.Magnitude > 1 then
				r = math.clamp(flat.Magnitude + (rng:NextNumber() - 0.5) * 16, S.station.radius[1], S.station.radius[2])
				local ang = math.atan2(flat.Z, flat.X)
				a0 = ang - w * life * S.planet.nearLead + (rng:NextNumber() - 0.5) * 0.4
			end
		end
		return { id = id, zone = 0, c = c, r = r, u = Vector3.xAxis, v = Vector3.zAxis, a0 = a0, w = w, t0 = t0, life = life, rare = rare }
	end
	local center, radius = ShowerMath.zoneCenter(zone)
	local r = radius + range(rng, S.planet.altitude)
	local w = range(rng, S.planet.speed) * (if rng:NextNumber() < 0.5 then -1 else 1)
	local n: Vector3
	if near and (near - center).Magnitude > 1 then
		n = (near - center).Unit
		-- tilt so the meteor passes beside the player, not straight through them
		local side = perpendicular(n, rng)
		n = (n + side * ((rng:NextNumber() - 0.5) * 2 * S.planet.nearJitter)).Unit
	else
		n = rng:NextUnitVector()
	end
	local d = perpendicular(n, rng)
	local a0 = if near then -w * life * S.planet.nearLead else rng:NextNumber() * math.pi * 2
	return { id = id, zone = zone, c = center, r = r, u = n, v = d, a0 = a0, w = w, t0 = t0, life = life, rare = rare }
end

-- Network form (plain table of numbers/vectors; Vector3 replicates natively).
function ShowerMath.encode(m: Meteor): any
	return { id = m.id, z = m.zone, c = m.c, r = m.r, u = m.u, v = m.v, a = m.a0, w = m.w, t = m.t0, l = m.life, x = m.rare }
end

function ShowerMath.decode(e: any): Meteor?
	if type(e) ~= "table" or type(e.id) ~= "string" or typeof(e.c) ~= "Vector3" or typeof(e.u) ~= "Vector3" or typeof(e.v) ~= "Vector3" then
		return nil
	end
	return { id = e.id, zone = e.z, c = e.c, r = e.r, u = e.u, v = e.v, a0 = e.a, w = e.w, t0 = e.t, life = e.l, rare = e.x == true }
end

return ShowerMath
