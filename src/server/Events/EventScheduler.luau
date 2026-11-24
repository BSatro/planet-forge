--!strict
-- EventScheduler — owner: Live Gameplay. Pure scheduling rules for COSMIC WORLD EVENTS (no Instances, no clock:
-- callers pass `now` and an RNG). Decides WHEN the next event may start and WHICH one, honouring per-event
-- cooldowns, the concurrency cap and channel compatibility (EventConfig.compatible).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)

local EventScheduler = {}

export type State = {
	nextAt: number,
	lastEnded: { [string]: number },
	active: { [string]: boolean },
	scale: number,
	enabled: boolean,
	starts: number,
}

local function range(rng: Random, t: { number }): number
	return t[1] + (t[2] - t[1]) * rng:NextNumber()
end

function EventScheduler.new(now: number, rng: Random, scale: number?): State
	local s = scale or 1
	return {
		nextAt = now + range(rng, EventConfig.SCHEDULER.firstDelay) * s,
		lastEnded = {},
		active = {},
		scale = s,
		enabled = EventConfig.SCHEDULER.enabled,
		starts = 0,
	}
end

-- Changing the time scale (developer test mode) rescales the remaining wait.
function EventScheduler.setScale(st: State, scale: number, now: number)
	local remaining = math.max(0, st.nextAt - now)
	st.nextAt = now + remaining * (scale / st.scale)
	st.scale = scale
end

function EventScheduler.activeCount(st: State): number
	local n = 0
	for _ in st.active do
		n += 1
	end
	return n
end

-- Why `id` can or cannot start now. ignoreCooldown is for developer commands only.
function EventScheduler.canStart(st: State, id: string, now: number, ignoreCooldown: boolean?): (boolean, string)
	local def = EventConfig.get(id)
	if not def then
		return false, "UNKNOWN_EVENT"
	end
	if st.active[id] then
		return false, "ALREADY_ACTIVE"
	end
	if EventScheduler.activeCount(st) >= EventConfig.SCHEDULER.maxConcurrent then
		return false, "MAX_CONCURRENT"
	end
	for other in st.active do
		if not EventConfig.compatible(id, other) then
			return false, "INCOMPATIBLE"
		end
	end
	local ended = st.lastEnded[id]
	if not ignoreCooldown and ended and now - ended < def.cooldown * st.scale then
		return false, "COOLDOWN"
	end
	return true, "OK"
end

function EventScheduler.candidates(st: State, now: number): { string }
	local out = {}
	for _, id in EventConfig.ORDER do
		if EventScheduler.canStart(st, id, now) then
			table.insert(out, id)
		end
	end
	return out
end

-- Returns the event id to start now, or nil. Advances nextAt either way once it was due.
function EventScheduler.decide(st: State, now: number, playerCount: number, rng: Random): string?
	if not st.enabled or now < st.nextAt then
		return nil
	end
	local S = EventConfig.SCHEDULER
	if playerCount < S.minPlayers or EventScheduler.activeCount(st) >= S.maxConcurrent then
		st.nextAt = now + S.retry * st.scale
		return nil
	end
	local c = EventScheduler.candidates(st, now)
	if #c == 0 then
		st.nextAt = now + S.retry * st.scale
		return nil
	end
	local total = 0
	for _, id in c do
		total += EventConfig.get(id).weight
	end
	local roll = rng:NextNumber() * total
	local pick = c[#c]
	for _, id in c do
		roll -= EventConfig.get(id).weight
		if roll <= 0 then
			pick = id
			break
		end
	end
	st.nextAt = now + range(rng, S.gap) * st.scale
	return pick
end

function EventScheduler.markStarted(st: State, id: string)
	st.active[id] = true
	st.starts += 1
end

function EventScheduler.markEnded(st: State, id: string, now: number)
	st.active[id] = nil
	st.lastEnded[id] = now
end

return EventScheduler
