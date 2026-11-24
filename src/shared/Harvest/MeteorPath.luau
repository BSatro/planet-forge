--!strict
-- MeteorPath — owner: Gameplay (Cosmic Core Hunt). Deterministic target trajectories.
-- The SERVER generates a spec (plain numbers/strings/booleans, remote-safe) and sends it to the owning client.
-- Both sides evaluate the same spec at the same server time, so the client can animate smoothly and
-- predict hits while the server verifies claims against its own copy. No per-meteor timers: a spec is a pure
-- function of time (performance: one evaluation per meteor per frame on the client, per claim on the server).
--
-- Spec: { id, kind, pattern, t0, duration, ax, ay, az, bx, by, bz, k1, k2, k3,
--         period, phase, w0, w1, p0, p1, size, tutorial,
--         spd?     actual lane speed (studs/s)            tele?    telegraph seconds before t0 (warning only)
--         splits?  fragments issued at the end (split)    parentId?, fragment?   (split fragments)
--         cx..dz?  extra path points (slingshot)          m1?, m2? magnetic correction times (flight fractions)
--         pe?, pa?, pb?, po?  void phase-out: every pe-th resonance cycle while the ring phase is in
--                 [pa, pb], starting po seconds after t0 }
-- Positions are in harvester local space (x right, y up, z forward).

local HarvestConfig = require(script.Parent.Parent.Config.HarvestConfig)
local MeteorRegistry = require(script.Parent.MeteorRegistry)

export type Spec = { [string]: any }

local MeteorPath = {}

local TAU = math.pi * 2

local function pickWeighted(rng: Random, weights: { [string]: number }, order: { string }): string?
	local total = 0
	for _, k in order do
		total += math.max(0, weights[k] or 0)
	end
	if total <= 0 then
		return nil
	end
	local r = rng:NextNumber() * total
	for _, k in order do
		local w = math.max(0, weights[k] or 0)
		if w > 0 then
			if r < w then
				return k
			end
			r -= w
		end
	end
	for i = #order, 1, -1 do
		if (weights[order[i]] or 0) > 0 then
			return order[i]
		end
	end
	return nil
end
MeteorPath.pickWeighted = pickWeighted

local function smooth01(x: number): number
	local c = math.clamp(x, 0, 1)
	return c * c * (3 - 2 * c)
end

local function bounds()
	local Z = HarvestConfig.ZONE
	return Z.HALF_WIDTH + Z.ENTRY_MARGIN, Z.MIN_HEIGHT + Z.INNER_MARGIN, Z.MAX_HEIGHT - Z.INNER_MARGIN, Z.MIN_DEPTH + Z.INNER_MARGIN, Z.MAX_DEPTH - Z.INNER_MARGIN
end

local function setPoint(spec: Spec, prefix: string, p: Vector3)
	spec[prefix .. "x"] = p.X
	spec[prefix .. "y"] = p.Y
	spec[prefix .. "z"] = p.Z
end

-- Generate a normal spawn of `kind` (any id or alias; the spec carries the canonical id).
-- t0 = when the meteor would be announced; variants with a telegraph enter `telegraph` seconds later.
function MeteorPath.generate(rng: Random, id: number, kind: string, t0: number, patternOverride: string?): Spec
	local def = MeteorRegistry.get(kind)
	assert(def, "MeteorPath.generate: unknown kind " .. tostring(kind))
	local canonical = MeteorRegistry.resolve(kind) :: string
	local Z = HarvestConfig.ZONE
	local S = HarvestConfig.SPAWN
	local pattern = patternOverride or pickWeighted(rng, def.patterns, HarvestConfig.PATTERN_ORDER) or "drift"
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local xEdge, yLo, yHi, zLo, zHi = bounds()
	local yMid = (Z.MIN_HEIGHT + Z.MAX_HEIGHT) / 2
	local a = Vector3.new(side * xEdge, rng:NextNumber(yLo, yHi), rng:NextNumber(zLo, zHi))
	local b = Vector3.new(-side * xEdge, rng:NextNumber(yLo, yHi), rng:NextNumber(zLo, zHi))
	local tele = def.telegraph or 0
	local spec: Spec = {
		id = id,
		kind = canonical,
		pattern = pattern,
		t0 = t0 + tele,
		duration = 1,
		k1 = 0,
		k2 = 0,
		k3 = 0,
		period = def.period,
		phase = rng:NextNumber(),
		w0 = def.window[1],
		w1 = def.window[2],
		p0 = def.perfect[1],
		p1 = def.perfect[2],
		size = def.size * (1 + rng:NextNumber(-S.SIZE_JITTER, S.SIZE_JITTER)),
		tutorial = false,
		tele = tele,
	}
	local P = HarvestConfig.PATTERNS[pattern] or {}
	local extra = 0 -- extra path length beyond a -> b (slingshot)
	if pattern == "arc" then
		local mid = (a.Y + b.Y) / 2
		local dir = if mid < yMid then 1 else -1
		spec.k1 = dir * rng:NextNumber(P.LIFT_MIN, P.LIFT_MAX)
		spec.k2 = rng:NextNumber(-P.BEND, P.BEND)
	elseif pattern == "weave" then
		spec.k1 = rng:NextNumber(P.AMP_MIN, P.AMP_MAX)
		spec.k2 = rng:NextNumber(P.CYCLES_MIN, P.CYCLES_MAX)
		spec.k3 = rng:NextNumber(0, TAU)
	elseif pattern == "spiral" then
		spec.k1 = rng:NextNumber(P.RADIUS_MIN, P.RADIUS_MAX)
		spec.k2 = rng:NextNumber(P.TURNS_MIN, P.TURNS_MAX) * (if rng:NextNumber() < 0.5 then -1 else 1)
		spec.k3 = rng:NextNumber(0, TAU)
	elseif pattern == "flyby" then
		local drop = rng:NextNumber(P.DROP_MIN, P.DROP_MAX)
		local down = rng:NextNumber() < 0.5
		local yA = if down then yHi - rng:NextNumber(0, 4) else yLo + rng:NextNumber(0, 4)
		local yB = math.clamp(if down then yA - drop else yA + drop, yLo, yHi)
		local near = rng:NextNumber() < 0.5
		a = Vector3.new(side * xEdge, yA, if near then zLo + rng:NextNumber(0, 6) else zHi - rng:NextNumber(0, 6))
		b = Vector3.new(-side * xEdge, yB, if near then zHi - rng:NextNumber(0, 6) else zLo + rng:NextNumber(0, 6))
	elseif pattern == "magnetic" then
		local amp = rng:NextNumber(P.AMP_MIN, P.AMP_MAX)
		local m1 = rng:NextNumber(P.FIRST[1], P.FIRST[2])
		local m2 = rng:NextNumber(P.SECOND[1], P.SECOND[2])
		-- each correction pulls towards the middle of the lane, so the path stays inside it
		local y1 = a.Y + (b.Y - a.Y) * (m1 + P.WIDTH)
		local s1 = if y1 > yMid then -1 else 1
		local y2 = a.Y + (b.Y - a.Y) * (m2 + P.WIDTH) + s1 * amp
		local s2 = if y2 > yMid then -1 else 1
		spec.k1, spec.k2, spec.k3, spec.m1, spec.m2 = amp, s1, s2, m1, m2
	elseif pattern == "stellar" then
		local mid = (a.Y + b.Y) / 2
		spec.k1 = P.BRAKE
		spec.k2 = (if mid < yMid then 1 else -1) * rng:NextNumber(P.LIFT_MIN, P.LIFT_MAX)
	elseif pattern == "void" then
		spec.k1 = rng:NextNumber(P.AMP_MIN, P.AMP_MAX)
		spec.k2 = rng:NextNumber(P.CYCLES_MIN, P.CYCLES_MAX)
		spec.k3 = rng:NextNumber()
		spec.pe = P.PHASE_STRIDE
		spec.pa = P.PHASE_FROM
		spec.pb = P.PHASE_TO
		spec.po = P.PHASE_START + rng:NextNumber(0, 0.3)
	elseif pattern == "slingshot" then
		local dy = rng:NextNumber(P.TURN_DY_MIN, P.TURN_DY_MAX)
		local c = Vector3.new(b.X, math.clamp(if b.Y > yMid then b.Y - dy else b.Y + dy, yLo, yHi), rng:NextNumber(zLo, zHi))
		local d = Vector3.new(a.X, rng:NextNumber(yLo, yHi), rng:NextNumber(zLo, zHi))
		setPoint(spec, "c", c)
		setPoint(spec, "d", d)
		extra = (c - b).Magnitude + (d - c).Magnitude
	end
	if def.special == "split" then
		-- the parent only flies part of the lane; its fragments (generateFragments) continue from there
		local SP = HarvestConfig.SPLIT
		b = a:Lerp(b, rng:NextNumber(SP.FRACTION_MIN, SP.FRACTION_MAX))
		spec.splits = SP.FRAGMENTS
	end
	local speed = HarvestConfig.SPEED.BASE * def.speedMultiplier * (1 + rng:NextNumber(-S.SPEED_JITTER, S.SPEED_JITTER))
	setPoint(spec, "a", a)
	setPoint(spec, "b", b)
	spec.spd = speed
	spec.duration = ((b - a).Magnitude + extra) / speed
	return spec
end

-- Fragments of a split parent: start where (and when) the parent ends, fan out towards the far edge.
function MeteorPath.generateFragments(rng: Random, parent: Spec, newId: () -> number): { Spec }
	local SP = HarvestConfig.SPLIT
	local xEdge, yLo, yHi, zLo, zHi = bounds()
	local from = Vector3.new(parent.bx, parent.by, parent.bz)
	local dirX = if parent.bx < parent.ax then -1 else 1
	local speed = (parent.spd or HarvestConfig.SPEED.BASE) * SP.FRAGMENT_SPEED
	local out = {}
	for i = 1, (parent.splits or SP.FRAGMENTS) do
		local sgn = if i % 2 == 1 then 1 else -1
		local spread = SP.SPREAD_Y * (1 + math.floor((i - 1) / 2) * 0.5)
		local to = Vector3.new(dirX * xEdge, math.clamp(from.Y + sgn * spread, yLo, yHi), math.clamp(from.Z - sgn * SP.SPREAD_Z, zLo, zHi))
		local f: Spec = {
			id = newId(),
			kind = parent.kind,
			pattern = "drift",
			t0 = parent.t0 + parent.duration,
			duration = (to - from).Magnitude / speed,
			k1 = 0,
			k2 = 0,
			k3 = 0,
			period = parent.period,
			phase = rng:NextNumber(),
			w0 = parent.w0,
			w1 = parent.w1,
			p0 = parent.p0,
			p1 = parent.p1,
			size = parent.size * SP.FRAGMENT_SIZE,
			tutorial = false,
			tele = 0,
			spd = speed,
			fragment = true,
			parentId = parent.id,
		}
		setPoint(f, "a", from)
		setPoint(f, "b", to)
		table.insert(out, f)
	end
	return out
end

-- The first-capture tutorial target: slow pendulum across the lane, wide window, long life.
function MeteorPath.generateTutorial(rng: Random, id: number, t0: number): Spec
	local T = HarvestConfig.TUTORIAL
	local P = HarvestConfig.PATTERNS.pingpong
	local amp = HarvestConfig.ZONE.HALF_WIDTH * P.AMPLITUDE_FRAC
	return {
		id = id,
		kind = T.TYPE,
		pattern = "pingpong",
		t0 = t0,
		duration = T.DURATION,
		ax = 0,
		ay = T.HEIGHT,
		az = T.DEPTH,
		bx = 0,
		by = T.HEIGHT,
		bz = T.DEPTH,
		k1 = amp,
		k2 = P.PERIOD,
		k3 = -math.pi / 2, -- starts at the left edge, swings right
		period = T.PERIOD,
		phase = rng:NextNumber(),
		w0 = T.WINDOW[1],
		w1 = T.WINDOW[2],
		p0 = T.PERFECT[1],
		p1 = T.PERFECT[2],
		size = T.SIZE,
		tutorial = true,
		tele = 0,
	}
end

-- Progress 0..1, or nil outside the lifetime.
function MeteorPath.progress(spec: Spec, t: number): number?
	local e = t - spec.t0
	if e < -1e-6 or e > spec.duration + 1e-6 or spec.duration <= 0 then
		return nil
	end
	return math.clamp(e / spec.duration, 0, 1)
end

local function phaseParams(spec: Spec): (number?, number, number)
	local pa, pb = spec.pa, spec.pb
	if type(pa) ~= "number" or type(pb) ~= "number" or pb <= pa then
		return nil, 0, 1
	end
	return pa, pb, math.max(1, math.floor(spec.pe or 1))
end

-- Void: phased out (invisible and NOT capturable) at time t? Deterministic from the spec, in step with the
-- resonance ring (cycle = (t - t0) / period + phase, the same phase HarvestRules uses).
function MeteorPath.isPhased(spec: Spec, t: number): boolean
	local pa, pb, stride = phaseParams(spec)
	if not pa then
		return false
	end
	local e = t - spec.t0
	if e < (spec.po or 0) then
		return false
	end
	local cyc = e / spec.period + spec.phase
	local k = math.floor(cyc)
	if k % stride ~= 0 then
		return false
	end
	local ph = cyc - k
	return ph >= pa and ph <= pb
end

-- Seconds until the next phase-out starts (0 while phased; math.huge when the spec never phases).
function MeteorPath.timeToPhase(spec: Spec, t: number): number
	local pa, _, stride = phaseParams(spec)
	if not pa then
		return math.huge
	end
	if MeteorPath.isPhased(spec, t) then
		return 0
	end
	local cyc = (t - spec.t0) / spec.period + spec.phase
	local k = math.floor(cyc)
	for i = 0, stride + 2 do
		local kk = k + i
		if kk % stride == 0 then
			local startT = spec.t0 + (kk + pa - spec.phase) * spec.period
			if startT >= t and startT >= spec.t0 + (spec.po or 0) then
				return startT - t
			end
		end
	end
	return math.huge
end

-- Local position at server time t, or nil if not in flight.
function MeteorPath.evaluate(spec: Spec, t: number): Vector3?
	local u = MeteorPath.progress(spec, t)
	if not u then
		return nil
	end
	local a = Vector3.new(spec.ax, spec.ay, spec.az)
	local b = Vector3.new(spec.bx, spec.by, spec.bz)
	local p = spec.pattern
	if p == "drift" or p == "flyby" then
		return a:Lerp(b, u)
	elseif p == "arc" then
		local c = (a + b) / 2 + Vector3.new(0, spec.k1, spec.k2)
		local iu = 1 - u
		return a * (iu * iu) + c * (2 * iu * u) + b * (u * u)
	elseif p == "weave" then
		local ang = TAU * spec.k2 * u + spec.k3
		return a:Lerp(b, u) + Vector3.new(0, spec.k1 * math.sin(ang), spec.k1 * 0.45 * math.cos(ang))
	elseif p == "spiral" then
		local ang = TAU * spec.k2 * u + spec.k3
		return a:Lerp(b, u) + Vector3.new(0, spec.k1 * math.cos(ang), spec.k1 * math.sin(ang))
	elseif p == "pingpong" then
		local e = t - spec.t0
		local ang = TAU * e / spec.k2 + spec.k3
		local bob = HarvestConfig.PATTERNS.pingpong.BOB
		return Vector3.new(spec.k1 * math.sin(ang), spec.ay + bob * math.sin(ang * 1.7), spec.az + bob * math.cos(ang * 0.8))
	elseif p == "magnetic" then
		local W = HarvestConfig.PATTERNS.magnetic.WIDTH
		local o = spec.k1 * (spec.k2 * smooth01((u - (spec.m1 or 0.3)) / W) + spec.k3 * smooth01((u - (spec.m2 or 0.6)) / W))
		return a:Lerp(b, u) + Vector3.new(0, o, o * 0.3)
	elseif p == "stellar" then
		local w = u + spec.k1 * math.sin(TAU * u) / TAU -- fast in, slow through the middle, fast out
		local c = (a + b) / 2 + Vector3.new(0, spec.k2, 0)
		local iw = 1 - w
		return a * (iw * iw) + c * (2 * iw * w) + b * (w * w)
	elseif p == "void" then
		local x = u * spec.k2 + spec.k3
		local tri = 4 * math.abs(x - math.floor(x + 0.5)) - 1 -- zigzag in [-1, 1]
		return a:Lerp(b, u) + Vector3.new(0, spec.k1 * tri, 0)
	elseif p == "slingshot" then
		local c = Vector3.new(spec.cx, spec.cy, spec.cz)
		local d = Vector3.new(spec.dx, spec.dy, spec.dz)
		local l1, l2, l3 = (b - a).Magnitude, (c - b).Magnitude, (d - c).Magnitude
		local s = u * (l1 + l2 + l3)
		if s <= l1 then
			return a:Lerp(b, if l1 > 0 then s / l1 else 1)
		end
		s -= l1
		if s <= l2 then
			return b:Lerp(c, if l2 > 0 then s / l2 else 1)
		end
		s -= l2
		return c:Lerp(d, if l3 > 0 then math.min(1, s / l3) else 1)
	end
	return a:Lerp(b, u)
end

local REQUIRED = { "id", "t0", "duration", "ax", "ay", "az", "bx", "by", "bz", "k1", "k2", "k3", "period", "phase", "w0", "w1", "p0", "p1", "size" }
local OPTIONAL = { "spd", "tele", "splits", "parentId", "cx", "cy", "cz", "dx", "dy", "dz", "m1", "m2", "pe", "pa", "pb", "po" }

local function finite(v: any): boolean
	return type(v) == "number" and v == v and math.abs(v) ~= math.huge
end

function MeteorPath.isValidSpec(spec: any): boolean
	if type(spec) ~= "table" then
		return false
	end
	for _, k in REQUIRED do
		if not finite(spec[k]) then
			return false
		end
	end
	for _, k in OPTIONAL do
		if spec[k] ~= nil and not finite(spec[k]) then
			return false
		end
	end
	if type(spec.kind) ~= "string" or type(spec.pattern) ~= "string" or spec.period <= 0 then
		return false
	end
	if spec.pattern == "slingshot" and not (spec.cx and spec.cy and spec.cz and spec.dx and spec.dy and spec.dz) then
		return false
	end
	if spec.pattern == "magnetic" and not (spec.m1 and spec.m2) then
		return false
	end
	return true
end

return MeteorPath
