--!strict
-- QuestRules — owner: Live Gameplay. PURE daily/weekly quest rules (no Instances, no clock: callers pass `now`).
-- Shared so the client can format timers; only the server mutates state (QuestService). Unit-tested: Quests.spec.
--
-- Persisted state (profile.quests, compact):
--   { v = 1,
--     day  = { p = dayIndex,  q = { { id, n = progress, c = claimedAt (0 = not claimed) }, ... } },
--     week = { p = weekIndex, q = { ... } },
--     ev = { instanceId, ... }        -- recent cosmic-event instances already counted (bounded)
--     streak = { d = dayIndex, n = consecutive days with a claimed daily quest },
--     claimed = total quests claimed }
-- Unknown quest ids are KEPT in storage (a rolled-back config never destroys data) but are never shown or paid.

local QuestConfig = require(script.Parent.QuestConfig)

local QuestRules = {}
local C = QuestConfig
local KINDS = { "day", "week" }
QuestRules.KINDS = KINDS

local function isFinite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function int(v: any, min: number, max: number, fallback: number): number
	if not isFinite(v) then
		return fallback
	end
	return math.clamp(math.floor(v), min, max)
end

function QuestRules.periodIndex(kind: string, now: number): number
	local day = math.floor(now / C.DAY_SECONDS)
	if kind == "day" then
		return day
	end
	return math.floor((day - C.WEEK_START_DAY_OFFSET) / 7)
end

-- unix time at which period `idx` of `kind` ends (= the next one starts)
function QuestRules.periodEnds(kind: string, idx: number): number
	if kind == "day" then
		return (idx + 1) * C.DAY_SECONDS
	end
	return ((idx + 1) * 7 + C.WEEK_START_DAY_OFFSET) * C.DAY_SECONDS
end

local function seedFor(userId: number, kind: string, idx: number): number
	local u = math.abs(math.floor(userId)) % 2147483647
	return (u * 31 + idx * 7919 + (if kind == "day" then 104729 else 209459)) % 4503599627370496
end

-- The quest ids offered to `userId` for period `idx` (deterministic: same inputs -> same quests everywhere).
function QuestRules.pick(userId: number, kind: string, idx: number, level: number): { string }
	local eligible = {}
	for _, id in C.ORDER[kind] or {} do
		local d = C.QUESTS[id]
		if d and (d.minLevel or 1) <= level then
			table.insert(eligible, id)
		end
	end
	local rng = Random.new(seedFor(userId, kind, idx))
	for i = #eligible, 2, -1 do
		local j = rng:NextInteger(1, i)
		eligible[i], eligible[j] = eligible[j], eligible[i]
	end
	local out, metrics = {}, {}
	for _, id in eligible do
		if #out >= (C.COUNT[kind] or 0) then
			break
		end
		local m = C.QUESTS[id].metric
		if not (C.ONE_PER_METRIC and metrics[m]) then
			metrics[m] = true
			table.insert(out, id)
		end
	end
	return out
end

function QuestRules.new(): any
	return { v = C.VERSION, ev = {}, streak = { d = -1, n = 0 }, claimed = 0 }
end

-- Repairs a stored state IN PLACE (or builds a fresh one). Never invents progress.
function QuestRules.reconcile(raw: any): any
	local s = if type(raw) == "table" then raw else QuestRules.new()
	s.v = C.VERSION
	for _, kind in KINDS do
		local slot = s[kind]
		if type(slot) ~= "table" or not isFinite(slot.p) or type(slot.q) ~= "table" then
			s[kind] = nil
		else
			slot.p = math.floor(slot.p)
			local q = {}
			for _, e in ipairs(slot.q) do
				if type(e) == "table" and type(e.id) == "string" and #e.id <= 40 then
					local d = C.QUESTS[e.id]
					table.insert(q, { id = e.id, n = int(e.n, 0, if d then d.target else 1e9, 0), c = int(e.c, 0, 4102444800, 0) })
				end
			end
			slot.q = q
		end
	end
	local ev = {}
	if type(s.ev) == "table" then
		for _, id in ipairs(s.ev) do
			if type(id) == "string" and #id <= 40 and #ev < C.EVENT_MEMORY then
				table.insert(ev, id)
			end
		end
	end
	s.ev = ev
	local st = if type(s.streak) == "table" then s.streak else {}
	s.streak = { d = int(st.d, -1, 1e7, -1), n = int(st.n, 0, 1e6, 0) }
	s.claimed = int(s.claimed, 0, 1e9, 0)
	return s
end

local function bumpStreak(s: any, dayIdx: number)
	local st = s.streak
	if dayIdx == st.d then
		return
	elseif dayIdx == st.d + 1 then
		st.n += 1
		st.d = dayIdx
	elseif dayIdx > st.d then
		st.n = 1
		st.d = dayIdx
	end -- an older day than the streak's last day never changes it
end

export type Reward = { kind: string, id: string, credits: number, xp: number }

-- Brings both periods up to date (never backwards). Quests that were finished but never claimed in an expired period are marked
-- claimed and returned so the caller grants them (nothing finished is ever lost).
-- Returns (autoRewards, changed).
function QuestRules.ensure(s: any, userId: number, now: number, level: number): ({ Reward }, boolean)
	local rolled: { Reward } = {}
	local changed = false
	for _, kind in KINDS do
		local idx = QuestRules.periodIndex(kind, now)
		local slot = s[kind]
		-- forward only: a server whose clock lags (a server hop right at midnight) must never roll a period BACK,
		-- which would re-issue yesterday's quests with fresh progress (re-claimable) and drop today's progress
		if not slot or idx > slot.p then
			if slot then
				for _, e in slot.q do
					local d = C.QUESTS[e.id]
					if d and e.c == 0 and e.n >= d.target then
						e.c = now
						s.claimed += 1
						if kind == "day" then
							bumpStreak(s, slot.p)
						end
						table.insert(rolled, { kind = kind, id = e.id, credits = d.credits, xp = d.xp })
					end
				end
			end
			local q = {}
			for _, id in QuestRules.pick(userId, kind, idx, level) do
				table.insert(q, { id = id, n = 0, c = 0 })
			end
			s[kind] = { p = idx, q = q }
			changed = true
		end
	end
	return rolled, changed
end

-- Adds progress to every open quest of `metric` in both periods. Returns ({ {kind, id} newly completed }, changed).
function QuestRules.progress(s: any, metric: string, amount: number): ({ { kind: string, id: string } }, boolean)
	local done = {}
	local changed = false
	if not C.METRICS[metric] or not isFinite(amount) or amount <= 0 then
		return done, false
	end
	for _, kind in KINDS do
		local slot = s[kind]
		if slot then
			for _, e in slot.q do
				local d = C.QUESTS[e.id]
				if d and d.metric == metric and e.c == 0 and e.n < d.target then
					e.n = math.min(d.target, e.n + math.floor(amount))
					changed = true
					if e.n >= d.target then
						table.insert(done, { kind = kind, id = e.id })
					end
				end
			end
		end
	end
	return done, changed
end

-- Claims quest `index` of period `kind`. Returns ok, code, reward?. Codes: OK, INVALID_PAYLOAD, UNKNOWN_QUEST,
-- NOT_COMPLETE, ALREADY_CLAIMED. The caller grants the reward and calls unclaim() if the grant fails.
function QuestRules.claim(s: any, kind: any, index: any, now: number): (boolean, string, Reward?)
	if (kind ~= "day" and kind ~= "week") or type(index) ~= "number" or index ~= math.floor(index) then
		return false, "INVALID_PAYLOAD", nil
	end
	local slot = s[kind]
	local e = slot and slot.q[index]
	local d = e and C.QUESTS[e.id]
	if not e or not d then
		return false, "UNKNOWN_QUEST", nil
	end
	if e.c ~= 0 then
		return false, "ALREADY_CLAIMED", nil
	end
	if e.n < d.target then
		return false, "NOT_COMPLETE", nil
	end
	e.c = now
	s.claimed += 1
	if kind == "day" then
		bumpStreak(s, slot.p)
	end
	return true, "OK", { kind = kind, id = e.id, credits = d.credits, xp = d.xp }
end

-- Undo a claim whose grant failed (streak changes are kept: they carry no reward).
function QuestRules.unclaim(s: any, kind: string, index: number)
	local slot = s[kind]
	local e = slot and slot.q[index]
	if e and e.c ~= 0 then
		e.c = 0
		s.claimed = math.max(0, s.claimed - 1)
	end
end

-- Remembers a cosmic-event instance; true the first time (so one event counts once).
function QuestRules.recordEvent(s: any, instanceId: string): boolean
	if type(instanceId) ~= "string" or instanceId == "" or table.find(s.ev, instanceId) then
		return false
	end
	table.insert(s.ev, instanceId)
	while #s.ev > C.EVENT_MEMORY do
		table.remove(s.ev, 1)
	end
	return true
end

function QuestRules.claimable(s: any): number
	local n = 0
	if type(s) ~= "table" then
		return 0
	end
	for _, kind in KINDS do
		local slot = s[kind]
		if slot then
			for _, e in slot.q do
				local d = C.QUESTS[e.id]
				if d and e.c == 0 and e.n >= d.target then
					n += 1
				end
			end
		end
	end
	return n
end

-- Client view (the Profile_Snapshot carries this, never the raw state).
function QuestRules.view(s: any, now: number): any
	local out: any = { claimable = QuestRules.claimable(s), streak = 0, claimed = 0 }
	if type(s) ~= "table" then
		return out
	end
	local today = QuestRules.periodIndex("day", now)
	out.streak = if s.streak and s.streak.d >= today - 1 then s.streak.n else 0
	out.claimed = s.claimed or 0
	for _, kind in KINDS do
		local slot = s[kind]
		local list = {}
		if slot then
			for i, e in slot.q do
				local d = C.QUESTS[e.id]
				if d then
					table.insert(list, {
						index = i,
						id = e.id,
						title = d.title,
						detail = d.detail,
						target = d.target,
						progress = math.min(e.n, d.target),
						complete = e.n >= d.target,
						claimed = e.c ~= 0,
						credits = d.credits,
						xp = d.xp,
					})
				end
			end
		end
		out[kind] = { endsAt = if slot then QuestRules.periodEnds(kind, slot.p) else 0, list = list }
	end
	return out
end

return QuestRules
