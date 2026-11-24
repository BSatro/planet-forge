--!strict
-- ConvergenceRules — owner: Live Gameplay. Pure Cosmic Convergence rules: stability target scaled to the number of
-- eligible players (small servers can finish), contributions per task (calibrate / deliver / assist + the co-op
-- sync bonus), stages, completion and fair per-participant rewards (share of a fair contribution, capped).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)

local CV = EventConfig.CONVERGENCE
local ConvergenceRules = {}

function ConvergenceRules.targetFor(players: number): number
	local n = math.clamp(math.floor(players), 1, CV.maxCounted)
	return CV.targetBase + CV.targetPerExtra * (n - 1)
end

function ConvergenceRules.new(id: string, players: number, now: number): any
	return {
		id = id,
		target = ConvergenceRules.targetFor(players),
		progress = 0,
		stage = 0,
		contributions = {} :: { [number]: any },
		order = {} :: { number },
		completed = false,
		closed = false,
		startedAt = now,
		lastCal = nil :: any,
		events = {} :: { any },
	}
end

local function push(run: any, ev: any)
	table.insert(run.events, ev)
end

local function evaluate(run: any)
	local frac = run.progress / math.max(1, run.target)
	local stage = 0
	for i, th in CV.stages do
		if frac >= th then
			stage = i
		end
	end
	if stage > run.stage then
		run.stage = stage
		push(run, { kind = "stage", stage = stage })
	end
	if not run.completed and run.progress >= run.target then
		run.completed = true
		push(run, { kind = "completed" })
	end
end

-- Players leaving lowers the target (never raises it mid-event: newcomers just make it faster).
function ConvergenceRules.updatePlayers(run: any, players: number)
	local t = ConvergenceRules.targetFor(players)
	if t < run.target and not run.completed and not run.closed then
		run.target = t
		evaluate(run)
	end
end

local function entry(run: any, userId: number, name: string): any
	local e = run.contributions[userId]
	if not e then
		e = { userId = userId, name = name, points = 0, tasks = 0, calibrations = 0, deliveries = 0, assists = 0, syncs = 0 }
		run.contributions[userId] = e
		table.insert(run.order, userId)
	end
	return e
end

local function addPoints(run: any, e: any, pts: number)
	e.points += pts
	run.progress += pts
	evaluate(run)
end

-- kind: "calibrate" | "deliver" | "assist". Returns ok, code, points credited to this player (incl. sync bonus).
function ConvergenceRules.contribute(run: any, userId: number, name: string, kind: string, now: number): (boolean, string, number)
	if run.completed or run.closed then
		return false, "ENDED", 0
	end
	if kind ~= "calibrate" and kind ~= "deliver" and kind ~= "assist" then
		return false, "INVALID", 0
	end
	local pts = CV.points[kind]
	local e = entry(run, userId, name)
	e.tasks += 1
	if kind == "calibrate" then
		e.calibrations += 1
	elseif kind == "deliver" then
		e.deliveries += 1
	else
		e.assists += 1
	end
	addPoints(run, e, pts)
	local total = pts
	if kind == "calibrate" then
		local last = run.lastCal
		local synced = false
		if last and last.userId ~= userId and now - last.at <= CV.syncWindow and not last.synced then
			local other = run.contributions[last.userId]
			if other then
				other.syncs += 1
				e.syncs += 1
				addPoints(run, other, CV.points.sync)
				addPoints(run, e, CV.points.sync)
				total += CV.points.sync
				synced = true
				push(run, { kind = "sync", a = last.userId, b = userId })
			end
		end
		run.lastCal = { userId = userId, at = now, synced = synced }
	end
	return true, "OK", total
end

function ConvergenceRules.close(run: any, now: number)
	run.closed = true
	run.closedAt = now
end

function ConvergenceRules.eligibleCount(run: any): number
	local n = 0
	for _, e in run.contributions do
		if e.points >= CV.minContribution then
			n += 1
		end
	end
	return n
end

-- contribution / fair share, where fair share = target / eligible participants. Capped at CV.maxShare.
function ConvergenceRules.share(run: any, userId: number): number
	local e = run.contributions[userId]
	if not e then
		return 0
	end
	local fair = run.target / math.max(1, ConvergenceRules.eligibleCount(run))
	return math.clamp(e.points / math.max(1, fair), 0, CV.maxShare)
end

local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

-- Deterministic per run + player (repeated evaluation always yields the same reward).
function ConvergenceRules.rewardsFor(run: any, userId: number): (boolean, any)
	local e = run.contributions[userId]
	if not e then
		return false, "NOT_PARTICIPANT"
	end
	if e.points < CV.minContribution then
		return false, "TOO_LITTLE"
	end
	local frac = math.min(1, run.progress / math.max(1, run.target))
	local mult: number
	if run.completed then
		mult = 1
	elseif frac >= CV.partialFloor then
		mult = CV.rewards.partialScale * frac
	else
		return false, "NOT_STABILIZED"
	end
	local R = CV.rewards
	local share = ConvergenceRules.share(run, userId)
	local rng = Random.new(hash(run.id .. ":" .. tostring(userId)))
	local reward: any = {
		credits = math.floor((R.credits.base + R.credits.share * share) * mult + 0.5),
		energy = math.floor((R.energy.base + R.energy.share * share) * mult + 0.5),
		xp = math.floor((R.xp.base + R.xp.share * share) * mult + 0.5),
		materials = {},
		catalysts = {},
		share = share,
		mult = mult,
		points = e.points,
		completed = run.completed,
	}
	local roll = rng:NextNumber()
	local which = rng:NextInteger(1, #R.catalysts)
	if run.completed and share >= R.catalystMinShare and roll < R.catalystChance then
		reward.catalysts[R.catalysts[which]] = 1
	end
	if run.completed and share >= R.componentMinShare then
		reward.materials[R.componentId] = 1
	end
	return true, reward
end

function ConvergenceRules.top(run: any, n: number): { any }
	local list = {}
	for _, e in run.contributions do
		table.insert(list, e)
	end
	table.sort(list, function(a, b)
		if a.points ~= b.points then
			return a.points > b.points
		end
		return a.userId < b.userId
	end)
	local out = {}
	for i = 1, math.min(n, #list) do
		table.insert(out, { userId = list[i].userId, name = list[i].name, points = list[i].points })
	end
	return out
end

function ConvergenceRules.drain(run: any): { any }
	local ev = run.events
	run.events = {}
	return ev
end

return ConvergenceRules
