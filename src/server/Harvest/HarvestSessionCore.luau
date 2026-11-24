--!strict
-- HarvestSessionCore — owner: Gameplay (Cosmic Core Hunt). Instance-free, clock-injected session logic so
-- the whole verification path is unit-testable with fake players:
--   * one session per key (player), bound to the key's own harvester slot
--   * server-authored meteor stream: 12 data-driven variants (MeteorRegistry). Kinds the owner's planet does
--     not attract are removed and the remaining weights renormalized; bounded active count and spawns/minute
--   * pulse emitter (anti-spam): a server-timestamped charge (BeginCharge, SHOT.MIN_CHARGE), one pulse in
--     flight, reload after every spent shot (SHOT.COOLDOWN, SHOT.MISS_COOLDOWN after a miss). The reload is
--     stored per key OUTSIDE the session, so exit / death / respawn / re-entry never resets it
--   * shot verification: fireTime window (ping-aware), ownership (ids issued to THIS session), duplicate
--     claims, per-minute capture cap, phase + aim + timing via HarvestRules (rarity tolerances)
--   * exit -> dormant: re-entering within SPAWN.DORMANT_TTL resumes the SAME stream (no re-rolls for rares)
--   * split meteors: fragments are issued with their parent; capturing the parent first cancels them
--   * focus stacks (miss recovery) and capture bookkeeping
-- It never grants rewards; HarvestService does that through EconomyService, then calls :Settle (or :Unclaim
-- when the reward failed).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local HarvestConfig = require(Shared.Config.HarvestConfig)
local MeteorPath = require(Shared.Harvest.MeteorPath)
local HarvestRules = require(Shared.Harvest.HarvestRules)
local HarvestLayout = require(Shared.Harvest.HarvestLayout)
local MeteorRegistry = require(Shared.Harvest.MeteorRegistry)

export type Claim = { targetId: number, fireTime: number, aim: Vector3 }
export type FireContext = { now: number, ping: number?, canAfford: boolean, bonusDeg: number? }

local Core = {}
Core.__index = Core

-- opts: { seed?: number, layoutFor?: (slot) -> Layout, eventId?: string }
function Core.new(opts: any?)
	local o = opts or {}
	return setmetatable({
		sessions = {} :: { [any]: any },
		dormant = {} :: { [any]: any }, -- key -> { s = session, at = stoppedAt }
		ready = {} :: { [any]: number }, -- key -> server time the emitter is ready again (outlives sessions)
		rng = Random.new(o.seed or os.clock() * 1e6),
		layoutFor = o.layoutFor or HarvestLayout.forSlot,
		nextId = 1000 + math.floor((o.seed or 0) % 1000),
		eventId = o.eventId,
	}, Core)
end

local function eventDef(self: any): any
	local id = self.eventId or HarvestConfig.ACTIVE_EVENT
	return id and HarvestConfig.EVENTS[id]
end

local function typeEnabled(self: any, kind: string): boolean
	local def = HarvestConfig.TARGET_TYPES[kind]
	if not def then
		return false
	end
	if def.enabled then
		return true
	end
	local ev = eventDef(self)
	if ev and ev.enableTypes then
		for _, k in ev.enableTypes do
			if MeteorRegistry.resolve(k) == kind then
				return true
			end
		end
	end
	return false
end

function Core:_newId(): number
	self.nextId += 1
	return self.nextId
end

local function retainUntil(spec: any): number
	local S = HarvestConfig.SPAWN
	return spec.t0 + spec.duration + S.EXPIRE_GRACE + S.ISSUED_RETENTION
end

function Core:_issue(s: any, spec: any)
	s.meteors[spec.id] = spec
	s.issued[spec.id] = retainUntil(spec)
	s.issuedCount += 1
	table.insert(s.outbox, spec)
end

-- Spawn weights for a session: enabled variants, filtered by the planet context (progression gates) and
-- multiplied by event and planet-branch multipliers. Picking renormalizes over whatever remains.
function Core:Weights(s: any): { [string]: number }
	local weights = {}
	local ev = eventDef(self)
	local evMult = ev and MeteorRegistry.normalizeMap(ev.weightMultipliers)
	local ctx = s.worldContext
	local ctxMult = ctx and MeteorRegistry.normalizeMap(ctx.weightMultipliers)
	for _, kind in MeteorRegistry.ORDER do
		if typeEnabled(self, kind) and (ctx == nil or ctx.allowed == nil or ctx.allowed[kind]) then
			local w = HarvestConfig.TARGET_TYPES[kind].weight
			if evMult and evMult[kind] then
				w *= evMult[kind]
			end
			if ctxMult and ctxMult[kind] then
				w *= ctxMult[kind]
			end
			weights[kind] = w
		end
	end
	return weights
end

-- ctx = { allowed = { [kind]: true }?, weightMultipliers = { [kind]: number }? } (from the owner's planet)
function Core:SetWorldContext(key: any, ctx: any)
	local s = self.sessions[key]
	if s then
		s.worldContext = ctx
	end
end

function Core:_spawnNormal(s: any, now: number): any
	local weights = self:Weights(s)
	local damp = HarvestConfig.SPAWN.STREAK_DAMPING
	if damp < 1 then
		local k1, k2 = s.recentKinds[1], s.recentKinds[2]
		if k1 and k1 == k2 and weights[k1] then
			weights[k1] *= damp
		end
	end
	local kind = MeteorPath.pickWeighted(s.rng, weights, MeteorRegistry.ORDER) or "Ice"
	table.insert(s.recentKinds, 1, kind)
	s.recentKinds[3] = nil
	local spec = MeteorPath.generate(s.rng, self:_newId(), kind, now + HarvestConfig.SPAWN.LEAD)
	self:_issue(s, spec)
	if spec.splits and spec.splits > 0 then
		local ids = {}
		for _, frag in MeteorPath.generateFragments(s.rng, spec, function()
			return self:_newId()
		end) do
			self:_issue(s, frag)
			table.insert(ids, frag.id)
		end
		s.children[spec.id] = ids
	end
	table.insert(s.spawnTimes, now)
	return spec
end

function Core:_spawnTutorial(s: any, now: number): any
	local spec = MeteorPath.generateTutorial(s.rng, self:_newId(), now + HarvestConfig.SPAWN.LEAD)
	s.tutorialId = spec.id
	self:_issue(s, spec)
	return spec
end

local function newSession(self: any, key: any, slot: number, now: number, opts: any?): any
	return {
		key = key,
		slot = slot,
		layout = self.layoutFor(slot),
		startedAt = now,
		lastActivityAt = now,
		nextSpawnAt = now + HarvestConfig.SPAWN.FIRST_DELAY,
		lastSpawnAt = -math.huge,
		meteors = {} :: { [number]: any },
		issued = {} :: { [number]: number }, -- id -> retain until (server time)
		issuedCount = 0,
		claimed = {} :: { [number]: boolean },
		children = {} :: { [number]: { number } }, -- split parent id -> fragment ids
		captureTimes = {} :: { number },
		spawnTimes = {} :: { number },
		missStacks = 0,
		captures = 0,
		shots = 0,
		charge = nil :: number?, -- server time the current charge started
		inFlightAt = nil :: number?, -- server time of a capture whose reward has not settled yet
		tutorial = (opts and opts.tutorial == true and HarvestConfig.TUTORIAL.ENABLED) or false,
		tutorialId = nil :: number?,
		outbox = {} :: { any },
		recentKinds = {} :: { string },
		worldContext = opts and opts.worldContext or nil,
		rng = Random.new(self.rng:NextInteger(1, 2 ^ 30)),
		resumed = false,
	}
end

-- Starts (or returns the existing) session. A dormant session of the same key (exited less than
-- SPAWN.DORMANT_TTL ago) is resumed with its stream, focus and caps. opts: { tutorial, worldContext }
function Core:Start(key: any, slot: number, now: number, opts: any?): any
	local existing = self.sessions[key]
	if existing then
		return existing
	end
	local d = self.dormant[key]
	self.dormant[key] = nil
	if d and now - d.at <= HarvestConfig.SPAWN.DORMANT_TTL then
		local s = d.s
		s.slot = slot
		s.layout = self.layoutFor(slot)
		s.startedAt = now
		s.lastActivityAt = now
		s.issuedCount = 0
		s.charge = nil
		s.inFlightAt = nil
		s.outbox = {}
		s.resumed = true
		if opts and opts.worldContext then
			s.worldContext = opts.worldContext
		end
		self.sessions[key] = s
		local wantTutorial = (opts and opts.tutorial == true and HarvestConfig.TUTORIAL.ENABLED) or false
		if s.tutorial and not wantTutorial then
			self:CompleteTutorial(key, now)
		end
		return s
	end
	local s = newSession(self, key, slot, now, opts)
	self.sessions[key] = s
	if s.tutorial then
		self:_spawnTutorial(s, now)
	end
	return s
end

function Core:Get(key: any): any
	return self.sessions[key]
end

-- Ends the active session. With `now`, it is kept dormant (resumable); without, it is simply dropped.
-- The emitter reload (ready time) is kept either way.
function Core:Stop(key: any, now: number?): boolean
	local s = self.sessions[key]
	if not s then
		return false
	end
	self.sessions[key] = nil
	s.charge = nil
	s.inFlightAt = nil
	if now then
		self.dormant[key] = { s = s, at = now }
	end
	return true
end

-- The key is gone for good (player left the server): drop everything held for it.
function Core:Forget(key: any)
	self.sessions[key] = nil
	self.dormant[key] = nil
	self.ready[key] = nil
end

function Core:ReadyAt(key: any): number
	return self.ready[key] or -math.huge
end

function Core:ActiveCount(s: any, now: number): number
	local n = 0
	for _, spec in s.meteors do
		-- a split parent and its (not yet started) fragments count once
		if now <= spec.t0 + spec.duration and not (spec.parentId and now < spec.t0) then
			n += 1
		end
	end
	return n
end

-- Drains newly issued specs for a session (to send to the client).
function Core:TakeOutbox(key: any): { any }
	local s = self.sessions[key]
	if not s or #s.outbox == 0 then
		return {}
	end
	local out = s.outbox
	s.outbox = {}
	return out
end

function Core:_prune(s: any, now: number)
	local S = HarvestConfig.SPAWN
	for id, spec in s.meteors do
		if now > spec.t0 + spec.duration + S.EXPIRE_GRACE then
			s.meteors[id] = nil
			s.children[id] = nil
			if id == s.tutorialId then
				s.tutorialId = nil
			end
		end
	end
	for id, untilT in s.issued do
		if type(untilT) ~= "number" then
			-- legacy marker (`true`): retain like a fresh issue so it is still pruned eventually
			local spec = s.meteors[id]
			s.issued[id] = if spec then retainUntil(spec) else now + S.ISSUED_RETENTION
		elseif now > untilT then
			s.issued[id] = nil
			s.claimed[id] = nil
		end
	end
	while #s.spawnTimes > 0 and now - s.spawnTimes[1] > 60 do
		table.remove(s.spawnTimes, 1)
	end
	while #s.captureTimes > 0 and now - s.captureTimes[1] > 60 do
		table.remove(s.captureTimes, 1)
	end
end

-- Advances every session. Returns { [key]: endReason } for sessions that ended (idle / max length); they
-- become dormant. Also expires dormant records and stale reload entries.
function Core:Tick(now: number): { [any]: string }
	local ended = {}
	local S = HarvestConfig.SPAWN
	local ev = eventDef(self)
	local intervalMult = if ev then ev.spawnIntervalMultiplier or 1 else 1
	for key, s in self.sessions do
		if now - s.lastActivityAt > HarvestConfig.OPERATE.IDLE_TIMEOUT then
			ended[key] = "idle"
			continue
		end
		if now - s.startedAt > HarvestConfig.OPERATE.MAX_SESSION_SECONDS or s.issuedCount >= HarvestConfig.LIMITS.MAX_ISSUED_PER_SESSION then
			ended[key] = "limit"
			continue
		end
		self:_prune(s, now)
		if s.tutorial then
			if not s.tutorialId then
				self:_spawnTutorial(s, now) -- tutorial target never runs out
			end
			continue
		end
		local active = self:ActiveCount(s, now)
		if
			active < S.MAX_ACTIVE
			and now - s.lastSpawnAt >= S.MIN_GAP
			and (now >= s.nextSpawnAt or active < S.MIN_ACTIVE)
			and #s.spawnTimes < S.MAX_SPAWNS_PER_MINUTE
		then
			self:_spawnNormal(s, now)
			s.lastSpawnAt = now
			s.nextSpawnAt = now + s.rng:NextNumber(S.INTERVAL_MIN, S.INTERVAL_MAX) * intervalMult
		end
	end
	for key in ended do
		self:Stop(key, now)
	end
	for key, d in self.dormant do
		if now - d.at > S.DORMANT_TTL then
			self.dormant[key] = nil
		end
	end
	for key, t in self.ready do
		if t < now - 60 and not self.sessions[key] and not self.dormant[key] then
			self.ready[key] = nil
		end
	end
	return ended
end

-- Charge start (server timestamp). Refused while reloading or while a pulse is in flight.
-- Returns ok, code, readyAt.
function Core:BeginCharge(key: any, now: number): (boolean, string, number)
	local s = self.sessions[key]
	local readyAt = self:ReadyAt(key)
	if not s then
		return false, "NOT_OPERATING", readyAt
	end
	local SHOT = HarvestConfig.SHOT
	if s.inFlightAt and now - s.inFlightAt < SHOT.IN_FLIGHT_TIMEOUT then
		return false, "SHOT_IN_FLIGHT", readyAt
	end
	if now < readyAt - SHOT.COOLDOWN_TOLERANCE then
		return false, "COOLDOWN", readyAt
	end
	s.lastActivityAt = now
	if s.charge == nil or s.charge < readyAt - SHOT.COOLDOWN_TOLERANCE then
		s.charge = now -- an already valid charge is kept (a repeated begin can never shorten the hold)
	end
	return true, "OK", readyAt
end

-- Verifies a capture claim. Result:
--   { ok = false, code, readyAt }                                     rejected
--   { ok = true, outcome = "miss", reason, missStacks, readyAt, cooldown }   verified miss (focus +1)
--   { ok = true, outcome = "capture", spec, quality, multiplier, missStacksBefore, readyAt, cooldown,
--     cancelIds, cancelled }
-- Order: session -> in flight -> fireTime window -> reload -> charge (consumed) -> target issued -> not
-- claimed -> capture cap; from there the shot is SPENT (reload starts at fireTime) and evaluated.
function Core:Fire(key: any, claim: Claim, ctx: FireContext): any
	local s = self.sessions[key]
	if not s then
		return { ok = false, code = "NOT_OPERATING", readyAt = self:ReadyAt(key) }
	end
	local SHOT = HarvestConfig.SHOT
	local now = ctx.now
	local readyAt = self:ReadyAt(key)
	if s.inFlightAt and now - s.inFlightAt < SHOT.IN_FLIGHT_TIMEOUT then
		return { ok = false, code = "SHOT_IN_FLIGHT", readyAt = readyAt }
	end
	local maxLate = math.min(SHOT.MAX_LATENCY, (ctx.ping or 0) * SHOT.LATENCY_PING_FACTOR + SHOT.LATENCY_SLACK)
	if claim.fireTime > now + SHOT.MAX_CLOCK_LEAD or claim.fireTime < now - maxLate or claim.fireTime < s.startedAt then
		return { ok = false, code = "BAD_TIME", readyAt = readyAt }
	end
	if claim.fireTime < readyAt - SHOT.COOLDOWN_TOLERANCE then
		return { ok = false, code = "COOLDOWN", readyAt = readyAt }
	end
	local chargeAt = s.charge
	s.charge = nil -- one charge, one release: consumed by any claim that got this far
	if chargeAt == nil then
		return { ok = false, code = "NOT_CHARGED", readyAt = readyAt }
	end
	local tolerance = math.min(SHOT.CHARGE_TOLERANCE_MAX, (ctx.ping or 0) + SHOT.CHARGE_SLACK)
	if claim.fireTime - chargeAt < SHOT.MIN_CHARGE - tolerance then
		return { ok = false, code = "CHARGE_SHORT", readyAt = readyAt }
	end
	local id = claim.targetId
	if not s.issued[id] then
		return { ok = false, code = "UNKNOWN_TARGET", readyAt = readyAt }
	end
	if s.claimed[id] then
		return { ok = false, code = "ALREADY_CLAIMED", readyAt = readyAt }
	end
	local times = s.captureTimes
	while #times > 0 and now - times[1] > 60 do
		table.remove(times, 1)
	end
	if #times >= HarvestConfig.LIMITS.MAX_CAPTURES_PER_MINUTE then
		return { ok = false, code = "CAPTURE_LIMIT", readyAt = readyAt }
	end
	-- the shot is spent from here on
	s.lastActivityAt = now
	s.shots += 1
	local spec = s.meteors[id]
	local result = if spec
		then HarvestRules.evaluateShot(spec, claim.fireTime, s.layout.toWorld, s.layout.origin, claim.aim, s.missStacks, ctx.bonusDeg)
		else { hit = false, reason = "EXPIRED" }
	if not result.hit then
		s.missStacks = math.min(s.missStacks + 1, HarvestConfig.FOCUS.MAX_STACKS)
		readyAt = claim.fireTime + SHOT.MISS_COOLDOWN
		self.ready[key] = readyAt
		return {
			ok = true,
			outcome = "miss",
			reason = result.reason,
			missStacks = s.missStacks,
			phase = result.phase,
			angleDeg = result.angleDeg,
			readyAt = readyAt,
			cooldown = SHOT.MISS_COOLDOWN,
		}
	end
	readyAt = claim.fireTime + SHOT.COOLDOWN
	self.ready[key] = readyAt
	if not ctx.canAfford then
		return { ok = false, code = "NOT_ENOUGH_ENERGY", readyAt = readyAt }
	end
	local before = s.missStacks
	s.claimed[id] = true
	s.meteors[id] = nil
	local cancelIds, cancelled = {}, {}
	for _, cid in s.children[id] or {} do
		local child = s.meteors[cid]
		if child then
			s.meteors[cid] = nil
			s.claimed[cid] = true
			table.insert(cancelIds, cid)
			table.insert(cancelled, child)
		end
	end
	s.missStacks = 0
	s.captures += 1
	table.insert(times, now)
	s.inFlightAt = now
	return {
		ok = true,
		outcome = "capture",
		spec = spec,
		quality = result.quality,
		multiplier = HarvestRules.rewardMultiplier(spec.kind, result.quality :: string, self.eventId or HarvestConfig.ACTIVE_EVENT, spec.fragment == true),
		missStacksBefore = before,
		readyAt = readyAt,
		cooldown = SHOT.COOLDOWN,
		cancelIds = cancelIds,
		cancelled = cancelled,
	}
end

-- The capture's reward was granted: release the in-flight lock.
function Core:Settle(key: any)
	local s = self.sessions[key]
	if s then
		s.inFlightAt = nil
	end
end

-- Reward could not be granted: give the target (and any cancelled fragments) back while still in flight.
function Core:Unclaim(key: any, spec: any, cancelled: { any }?)
	local s = self.sessions[key]
	if not s or not spec then
		return
	end
	s.claimed[spec.id] = nil
	s.meteors[spec.id] = spec
	for _, child in cancelled or {} do
		s.claimed[child.id] = nil
		s.meteors[child.id] = child
	end
	s.captures = math.max(0, s.captures - 1)
	table.remove(s.captureTimes)
	s.inFlightAt = nil
end

-- Tutorial finished: drop the tutorial target, start the normal stream right away.
function Core:CompleteTutorial(key: any, now: number)
	local s = self.sessions[key]
	if not s or not s.tutorial then
		return
	end
	s.tutorial = false
	if s.tutorialId then
		s.meteors[s.tutorialId] = nil
		s.tutorialId = nil
	end
	s.nextSpawnAt = now
	s.lastSpawnAt = -math.huge
end

function Core:SessionCount(): number
	local n = 0
	for _ in self.sessions do
		n += 1
	end
	return n
end

-- Memory accounting (tests / Studio hook).
function Core:Footprint(): { sessions: number, dormant: number, ready: number, meteors: number, issued: number }
	local f = { sessions = 0, dormant = 0, ready = 0, meteors = 0, issued = 0 }
	local function count(s: any)
		for _ in s.meteors do
			f.meteors += 1
		end
		for _ in s.issued do
			f.issued += 1
		end
	end
	for _, s in self.sessions do
		f.sessions += 1
		count(s)
	end
	for _, d in self.dormant do
		f.dormant += 1
		count(d.s)
	end
	for _ in self.ready do
		f.ready += 1
	end
	return f
end

return Core
