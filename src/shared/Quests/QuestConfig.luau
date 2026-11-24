--!strict
-- QuestConfig — owner: Live Gameplay. Daily and weekly quests (INTERFACES §11). All tuning lives here.
-- Design rules:
--   * a reason to come back every day, never a punishment for missing one: a quest finished but not claimed when
--     its period ends is granted automatically; nothing is lost except the chance to do more
--   * every daily quest is completable SOLO in one normal session (no events, no other players needed)
--   * the same player gets the same quests for the same period on every server (seeded by user id + period), so
--     rejoining or server-hopping cannot re-roll them
--   * rewards are credits + XP only (no premium currency, no gameplay power); sized well under one rift run per
--     daily quest so quests add to the loop instead of replacing it
-- Periods are UTC: a day starts at 00:00 UTC, a week on Monday 00:00 UTC.

local QuestConfig = {}

QuestConfig.VERSION = 1
QuestConfig.COUNT = { day = 3, week = 3 }
QuestConfig.DAY_SECONDS = 86400
QuestConfig.WEEK_SECONDS = 7 * 86400
QuestConfig.WEEK_START_DAY_OFFSET = 4 -- 1970-01-01 was a Thursday; day 4 (1970-01-05) was a Monday
QuestConfig.EVENT_MEMORY = 8 -- event instances remembered per player (a cosmic event counts once)
QuestConfig.ROLLOVER_CHECK_SECONDS = 30

-- metric ids are fed by QuestService:
--   capture  harvester captures (HarvestService.CaptureCompleted)
--   perfect  perfect-timing harvester captures
--   reaction completed DNA Lab reactions (EvolutionService.ReactionCompleted)
--   sell     matter units sold (EconomyService, reason "Sell")
--   earn     credits earned from gameplay (every positive Credits change except Quest / Dev rewards)
--   rift     completed Cosmic Rift runs (profile expeditions.totalCompleted)
--   event    cosmic events the player took part in (any "Event" reward during that event instance)
QuestConfig.METRICS = { capture = true, perfect = true, reaction = true, sell = true, earn = true, rift = true, event = true }

export type QuestDef = {
	id: string,
	period: string, -- "day" | "week"
	metric: string,
	target: number,
	credits: number,
	xp: number,
	title: string,
	detail: string,
	minLevel: number?,
}

local Q: { [string]: QuestDef } = {}
local function def(d: QuestDef)
	Q[d.id] = d
end

-- daily (3 of these per day)
def({ id = "D_Capture", period = "day", metric = "capture", target = 6, credits = 80, xp = 30, title = "Meteor hunter", detail = "Capture 6 meteors with your harvester" })
def({ id = "D_Perfect", period = "day", metric = "perfect", target = 3, credits = 90, xp = 35, title = "Perfect timing", detail = "Land 3 perfect captures with your harvester" })
def({ id = "D_React", period = "day", metric = "reaction", target = 2, credits = 80, xp = 30, title = "Lab work", detail = "Complete 2 reactions in the DNA Lab" })
def({ id = "D_Sell", period = "day", metric = "sell", target = 10, credits = 60, xp = 20, title = "Matter trader", detail = "Sell 10 matter" })
def({ id = "D_Earn", period = "day", metric = "earn", target = 250, credits = 70, xp = 25, title = "Steady income", detail = "Earn 250 credits" })
def({ id = "D_Rift", period = "day", metric = "rift", target = 1, credits = 120, xp = 45, title = "Rift runner", detail = "Complete a Cosmic Rift", minLevel = 3 })

-- weekly (3 of these per week)
def({ id = "W_Capture", period = "week", metric = "capture", target = 40, credits = 400, xp = 150, title = "Core hunter", detail = "Capture 40 meteors with your harvester" })
def({ id = "W_Perfect", period = "week", metric = "perfect", target = 15, credits = 450, xp = 160, title = "Sharpshooter", detail = "Land 15 perfect captures" })
def({ id = "W_React", period = "week", metric = "reaction", target = 10, credits = 400, xp = 150, title = "Planet architect", detail = "Complete 10 reactions in the DNA Lab" })
def({ id = "W_Earn", period = "week", metric = "earn", target = 2000, credits = 350, xp = 140, title = "Cosmic economy", detail = "Earn 2,000 credits" })
def({ id = "W_Rift", period = "week", metric = "rift", target = 3, credits = 500, xp = 180, title = "Rift veteran", detail = "Complete 3 Cosmic Rifts", minLevel = 3 })
def({ id = "W_Event", period = "week", metric = "event", target = 2, credits = 400, xp = 150, title = "Cosmic witness", detail = "Take part in 2 cosmic events (meteor showers, solar storms, convergences)" })

QuestConfig.QUESTS = Q
-- fixed order = deterministic selection input (never iterate the map for selection)
QuestConfig.ORDER = {
	day = { "D_Capture", "D_Perfect", "D_React", "D_Sell", "D_Earn", "D_Rift" },
	week = { "W_Capture", "W_Perfect", "W_React", "W_Earn", "W_Rift", "W_Event" },
}
-- at most one quest per metric in a period's selection (no "capture 6" next to "capture 3 perfect" twice over)
QuestConfig.ONE_PER_METRIC = true

function QuestConfig.get(id: string): QuestDef?
	return Q[id]
end

return QuestConfig
