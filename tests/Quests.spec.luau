--!strict
-- Daily / weekly quest specs (pure QuestRules + QuestConfig + ProfileSchema integration). No clock, no Instances.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local QuestConfig = ctx.require(RS.PF_Shared.Quests.QuestConfig)
	local QuestRules = ctx.require(RS.PF_Shared.Quests.QuestRules)
	local EconomyConfig = ctx.require(RS.PF_Shared.Config.EconomyConfig)
	local Schema = ctx.require(SSS.PF_Server.Data.ProfileSchema)
	local DAY = 86400
	-- 2026-11-23 00:00:00 UTC is a Monday
	local MONDAY = 1795392000

	it("CFG: every quest is valid, reasons exist, rewards are modest and each pool can fill a period", function()
		expect(EconomyConfig.REASONS.Quest).toBe(true)
		for _, kind in { "day", "week" } do
			local metrics = {}
			for _, id in QuestConfig.ORDER[kind] do
				local d = QuestConfig.QUESTS[id]
				expect(d ~= nil).toBe(true)
				expect(d.period).toBe(kind)
				expect(QuestConfig.METRICS[d.metric]).toBe(true)
				expect(d.target >= 1 and d.credits > 0 and d.xp > 0).toBe(true)
				expect(d.credits <= (if kind == "day" then 150 else 600)).toBe(true)
				if (d.minLevel or 1) <= 1 then
					metrics[d.metric] = true
				end
			end
			local n = 0
			for _ in metrics do
				n += 1
			end
			-- a level-1 player can always be offered a full set of distinct metrics
			expect(n >= QuestConfig.COUNT[kind]).toBe(true)
		end
		-- daily quests never depend on events or other players
		for _, id in QuestConfig.ORDER.day do
			expect(QuestConfig.QUESTS[id].metric ~= "event").toBe(true)
		end
	end)

	it("PERIODS: UTC days, weeks start on Monday 00:00 UTC, ends are exact", function()
		local w = QuestRules.periodIndex("week", MONDAY)
		expect(QuestRules.periodIndex("week", MONDAY - 1)).toBe(w - 1)
		expect(QuestRules.periodIndex("week", MONDAY + 7 * DAY - 1)).toBe(w)
		expect(QuestRules.periodEnds("week", w)).toBe(MONDAY + 7 * DAY)
		local d = QuestRules.periodIndex("day", MONDAY + 5)
		expect(QuestRules.periodEnds("day", d)).toBe(MONDAY + DAY)
		expect(QuestRules.periodIndex("day", MONDAY - 1)).toBe(d - 1)
	end)

	it("PICK: deterministic per player+period, distinct metrics, level-gated, varies across days/players", function()
		local a = QuestRules.pick(8319150623, "day", 20000, 10)
		local b = QuestRules.pick(8319150623, "day", 20000, 10)
		expect(table.concat(a, ",")).toBe(table.concat(b, ","))
		expect(#a).toBe(QuestConfig.COUNT.day)
		local sets = {}
		for day = 20000, 20029 do
			local ids = QuestRules.pick(8319150623, "day", day, 10)
			local metrics = {}
			for _, id in ids do
				local m = QuestConfig.QUESTS[id].metric
				expect(metrics[m] == nil).toBe(true)
				metrics[m] = true
			end
			sets[table.concat(ids, ",")] = true
			-- level 1: no rift quests
			for _, id in QuestRules.pick(42 + day, "day", day, 1) do
				expect((QuestConfig.QUESTS[id].minLevel or 1) <= 1).toBe(true)
			end
		end
		local distinct = 0
		for _ in sets do
			distinct += 1
		end
		expect(distinct >= 5).toBe(true)
		expect(table.concat(QuestRules.pick(1, "week", 3000, 10), ",") ~= table.concat(QuestRules.pick(2, "week", 3000, 10), ",") or table.concat(QuestRules.pick(1, "week", 3001, 10), ",") ~= table.concat(QuestRules.pick(2, "week", 3001, 10), ",")).toBe(true)
	end)

	it("PROGRESS + CLAIM: caps at target, only open quests, codes, single grant, unclaim on a failed grant", function()
		local s = QuestRules.reconcile(nil)
		local rolled, changed = QuestRules.ensure(s, 7, MONDAY + 100, 10)
		expect(#rolled).toBe(0)
		expect(changed).toBe(true)
		-- force a known daily set
		s.day.q = { { id = "D_Capture", n = 0, c = 0 }, { id = "D_Sell", n = 0, c = 0 }, { id = "D_Earn", n = 0, c = 0 } }
		local ok, code = QuestRules.claim(s, "day", 1, MONDAY + 200)
		expect(code).toBe("NOT_COMPLETE")
		local done = QuestRules.progress(s, "capture", 4)
		expect(#done).toBe(0)
		done = QuestRules.progress(s, "capture", 10)
		expect(#done).toBe(1)
		expect(s.day.q[1].n).toBe(6) -- capped at target
		local _, again = QuestRules.progress(s, "capture", 1)
		expect(again).toBe(false) -- completed quests stop counting
		local ok2, code2, reward = QuestRules.claim(s, "day", 1, MONDAY + 300)
		expect(ok2).toBe(true)
		expect(code2).toBe("OK")
		expect(reward and reward.credits).toBe(QuestConfig.QUESTS.D_Capture.credits)
		expect(select(2, QuestRules.claim(s, "day", 1, MONDAY + 301))).toBe("ALREADY_CLAIMED")
		expect(select(2, QuestRules.claim(s, "day", 9, MONDAY + 301))).toBe("UNKNOWN_QUEST")
		expect(select(2, QuestRules.claim(s, "month", 1, MONDAY))).toBe("INVALID_PAYLOAD")
		expect(select(2, QuestRules.claim(s, "day", 1.5, MONDAY))).toBe("INVALID_PAYLOAD")
		expect(s.claimed).toBe(1)
		QuestRules.unclaim(s, "day", 1)
		expect(s.claimed).toBe(0)
		expect(s.day.q[1].c).toBe(0)
		expect((QuestRules.claim(s, "day", 1, MONDAY + 302))).toBe(true)
		-- junk progress is ignored
		expect(select(2, QuestRules.progress(s, "capture", -5))).toBe(false)
		expect(select(2, QuestRules.progress(s, "teleport", 5))).toBe(false)
		expect(select(2, QuestRules.progress(s, "sell", 0 / 0))).toBe(false)
		local _ = ok
	end)

	it("ROLLOVER: finished-but-unclaimed quests are paid once at reset; open ones expire; streak counts days", function()
		local s = QuestRules.reconcile(nil)
		QuestRules.ensure(s, 7, MONDAY + 10, 10)
		s.day.q = { { id = "D_Capture", n = 6, c = 0 }, { id = "D_Sell", n = 3, c = 0 }, { id = "D_Earn", n = 250, c = MONDAY + 50 } }
		local rolled = QuestRules.ensure(s, 7, MONDAY + DAY + 10, 10)
		expect(#rolled).toBe(1)
		expect(rolled[1].id).toBe("D_Capture")
		expect(s.day.p).toBe(QuestRules.periodIndex("day", MONDAY + DAY))
		expect(#s.day.q).toBe(QuestConfig.COUNT.day)
		for _, e in s.day.q do
			expect(e.n).toBe(0)
		end
		local again = QuestRules.ensure(s, 7, MONDAY + DAY + 20, 10)
		expect(#again).toBe(0) -- never paid twice
		-- streak: day 0 (auto-paid) then day 1 claimed -> 2; skipping a day restarts at 1
		s.day.q[1].n = QuestConfig.QUESTS[s.day.q[1].id].target
		QuestRules.claim(s, "day", 1, MONDAY + DAY + 30)
		expect(s.streak.n).toBe(2)
		QuestRules.ensure(s, 7, MONDAY + 3 * DAY + 5, 10)
		s.day.q[1].n = QuestConfig.QUESTS[s.day.q[1].id].target
		QuestRules.claim(s, "day", 1, MONDAY + 3 * DAY + 6)
		expect(s.streak.n).toBe(1)
		expect(QuestRules.view(s, MONDAY + 3 * DAY + 7).streak).toBe(1)
		expect(QuestRules.view(s, MONDAY + 6 * DAY).streak).toBe(0) -- a broken streak shows 0
		-- a lagging server clock (server hop at midnight) never rolls a period back or re-issues claimed quests
		local dayP, claimedBefore = s.day.p, s.day.q[1].c
		local back, ch = QuestRules.ensure(s, 7, MONDAY + 3 * DAY - 30, 10)
		expect(#back).toBe(0)
		expect(ch).toBe(false)
		expect(s.day.p).toBe(dayP)
		expect(s.day.q[1].c).toBe(claimedBefore)
		-- weekly rolls only on Monday
		local wp = s.week.p
		QuestRules.ensure(s, 7, MONDAY + 6 * DAY + 86399, 10)
		expect(s.week.p).toBe(wp)
		QuestRules.ensure(s, 7, MONDAY + 7 * DAY, 10)
		expect(s.week.p).toBe(wp + 1)
	end)

	it("EVENTS: one cosmic event counts once; memory is bounded", function()
		local s = QuestRules.reconcile(nil)
		expect(QuestRules.recordEvent(s, "MS1")).toBe(true)
		expect(QuestRules.recordEvent(s, "MS1")).toBe(false)
		for i = 2, 30 do
			QuestRules.recordEvent(s, "EV" .. i)
		end
		expect(#s.ev).toBe(QuestConfig.EVENT_MEMORY)
		expect(QuestRules.recordEvent(s, "")).toBe(false)
	end)

	it("PERSISTENCE: new and old profiles get a valid quests section; corrupt data is repaired, not invented", function()
		local p = Schema.default(MONDAY, 99)
		expect(type(p.quests)).toBe("table")
		expect(p.quests.claimed).toBe(0)
		local old = Schema.default(MONDAY, 99)
		old.quests = nil -- a v2 save from before quests existed
		local fixed = Schema.reconcile(old, MONDAY, 99)
		expect(type(fixed.quests)).toBe("table")
		local junk = QuestRules.reconcile({ day = { p = "x", q = 5 }, week = { p = 3000, q = { { id = "W_Capture", n = 1e12, c = -4 }, { id = 7 }, "bad" } }, ev = { 1, "ok" }, streak = "no", claimed = -3 })
		expect(junk.day).toBe(nil)
		expect(#junk.week.q).toBe(1)
		expect(junk.week.q[1].n).toBe(QuestConfig.QUESTS.W_Capture.target)
		expect(junk.week.q[1].c).toBe(0)
		expect(#junk.ev).toBe(1)
		expect(junk.streak.n).toBe(0)
		expect(junk.claimed).toBe(0)
		-- an unknown (retired) quest id is kept in storage but never shown or claimable
		local s = QuestRules.reconcile({ day = { p = 1, q = { { id = "D_Retired", n = 5, c = 0 } } } })
		expect(#s.day.q).toBe(1)
		expect(#QuestRules.view(s, 2 * DAY - 10).day.list).toBe(0)
		expect(select(2, QuestRules.claim(s, "day", 1, 2 * DAY - 10))).toBe("UNKNOWN_QUEST")
		expect(QuestRules.claimable(s)).toBe(0)
	end)
end
