--!strict
-- Cosmic World Events + Social specs (pure rules; no Instances, no clock). Multiplayer cases use up to 8
-- virtual players; the service-level paths (leave settlement, cleanup, remotes) are covered by the playtest hooks.
-- Every loop here is bounded (an unbounded test loop freezes Studio's command runner).
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local Shared = RS.PF_Shared
	local Ev = SSS.PF_Server.Events
	local EventConfig = ctx.require(Shared.Events.EventConfig)
	local ShowerMath = ctx.require(Shared.Events.ShowerMath)
	local WorldLayout = ctx.require(Shared.Config.WorldLayout)
	local Registry = ctx.require(Shared.Evolution.ReactionRegistry)
	local ItemCatalog = ctx.require(Shared.Config.ItemCatalog)
	local EconomyConfig = ctx.require(Shared.Config.EconomyConfig)
	local Scheduler = ctx.require(Ev.EventScheduler)
	local ShowerRules = ctx.require(Ev.ShowerRules)
	local StormRules = ctx.require(Ev.StormRules)
	local Conv = ctx.require(Ev.ConvergenceRules)
	local SocialRules = ctx.require(Ev.SocialRules)
	local S, CV = EventConfig.SHOWER, EventConfig.CONVERGENCE

	---------------------------------------------------------------- config
	it("CFG: every event is fully configured; reward reason + items exist; budgets are ordered", function()
		for _, id in EventConfig.ORDER do
			local d = EventConfig.get(id)
			expect(d ~= nil and d.duration > 0 and d.cooldown > 0 and #d.channels > 0 and #d.howTo > 0).toBe(true)
		end
		expect(EconomyConfig.REASONS[EventConfig.REWARD_REASON]).toBe(true)
		for id in S.materials do
			expect(ItemCatalog.MATERIALS[id] ~= nil).toBe(true)
		end
		for _, id in CV.rewards.catalysts do
			expect(ItemCatalog.CATALYSTS[id] ~= nil).toBe(true)
		end
		expect(ItemCatalog.MATERIALS[CV.rewards.componentId] ~= nil).toBe(true)
		local B = EventConfig.FX.budgets
		expect(B.full.meteors >= B.reduced.meteors and B.reduced.meteors >= B.minimal.meteors).toBe(true)
		expect(B.minimal.lights == 0 and B.minimal.emitters == 0 and B.minimal.stormRate == 0).toBe(true)
		expect(B.full.meteors <= S.maxTotal).toBe(true)
	end)

	---------------------------------------------------------------- scheduler
	it("SCHED: compatibility matrix and concurrency cap", function()
		expect(EventConfig.compatible("MeteorShower", "SolarStorm")).toBe(true)
		expect(EventConfig.compatible("SolarStorm", "CosmicConvergence")).toBe(true)
		expect(EventConfig.compatible("MeteorShower", "CosmicConvergence")).toBe(false)
		expect(EventConfig.compatible("SolarStorm", "SolarStorm")).toBe(false)
		local rng = Random.new(1)
		local st = Scheduler.new(0, rng, 1)
		Scheduler.markStarted(st, "MeteorShower")
		local _, c1 = Scheduler.canStart(st, "CosmicConvergence", 0)
		expect(c1).toBe("INCOMPATIBLE")
		local _, c2 = Scheduler.canStart(st, "MeteorShower", 0, true)
		expect(c2).toBe("ALREADY_ACTIVE")
		expect((Scheduler.canStart(st, "SolarStorm", 0))).toBe(true)
		Scheduler.markStarted(st, "SolarStorm")
		local _, c3 = Scheduler.canStart(st, "CosmicConvergence", 0, true)
		expect(c3 == "MAX_CONCURRENT" or c3 == "INCOMPATIBLE").toBe(true)
		local _, c4 = Scheduler.canStart(st, "Nope", 0)
		expect(c4).toBe("UNKNOWN_EVENT")
	end)

	it("SCHED: cooldowns, developer override, test-mode scaling, empty servers", function()
		local rng = Random.new(2)
		local st = Scheduler.new(0, rng, 1)
		Scheduler.markStarted(st, "SolarStorm")
		Scheduler.markEnded(st, "SolarStorm", 100)
		local cd = EventConfig.get("SolarStorm").cooldown
		local _, c = Scheduler.canStart(st, "SolarStorm", 100 + cd - 1)
		expect(c).toBe("COOLDOWN")
		expect((Scheduler.canStart(st, "SolarStorm", 100 + cd - 1, true))).toBe(true) -- dev force
		expect((Scheduler.canStart(st, "SolarStorm", 100 + cd + 1))).toBe(true)
		local test = Scheduler.new(0, rng, EventConfig.SCHEDULER.testScale)
		Scheduler.markStarted(test, "SolarStorm")
		Scheduler.markEnded(test, "SolarStorm", 0)
		expect((Scheduler.canStart(test, "SolarStorm", cd * EventConfig.SCHEDULER.testScale + 1))).toBe(true)
		local e = Scheduler.new(0, rng, 1)
		e.nextAt = 0
		expect(Scheduler.decide(e, 1, 0, rng)).toBe(nil) -- nobody online: nothing starts
		expect(e.nextAt > 1).toBe(true) -- ...and the decision is retried later
	end)

	it("SCHED: 20,000 random server-seconds never run incompatible/too many/cooling-down events", function()
		local rng = Random.new(7)
		local st = Scheduler.new(0, rng, 1)
		local running: { [string]: number } = {}
		local lastEnd: { [string]: number } = {}
		local starts = 0
		for t = 0, 20000, 2 do
			for id, endAt in running do
				if t >= endAt then
					running[id] = nil
					Scheduler.markEnded(st, id, t)
					lastEnd[id] = t
				end
			end
			local pick = Scheduler.decide(st, t, rng:NextInteger(0, 8), rng)
			if pick then
				expect(running[pick]).toBe(nil)
				for other in running do
					expect(EventConfig.compatible(pick, other)).toBe(true)
				end
				if lastEnd[pick] then
					expect(t - lastEnd[pick] >= EventConfig.get(pick).cooldown).toBe(true)
				end
				Scheduler.markStarted(st, pick)
				running[pick] = t + EventConfig.SCHEDULER.incoming + EventConfig.get(pick).duration + EventConfig.SCHEDULER.ending
				starts += 1
				local n = 0
				for _ in running do
					n += 1
				end
				expect(n <= EventConfig.SCHEDULER.maxConcurrent).toBe(true)
			end
		end
		expect(starts > 20).toBe(true)
	end)

	---------------------------------------------------------------- meteor shower
	local function allZones(players: number): { any }
		local zones = { { zone = 0, near = {} } }
		for slot = 1, WorldLayout.SLOT_COUNT do
			if WorldLayout.isActiveSlot(slot) and #zones <= players then
				table.insert(zones, { zone = slot, near = { WorldLayout.getSlotCenter(slot) + Vector3.new(0, WorldLayout.PLANET_RADIUS + 3, 0) } })
			end
		end
		return zones
	end

	it("SHOWER: spawning stays bounded with 8 players for a whole shower", function()
		local st = ShowerRules.new("T1", 99)
		local zones = allZones(8)
		local peak = 0
		for t = 0, EventConfig.get("MeteorShower").duration, S.spawnInterval do
			ShowerRules.expire(st, t)
			local made = ShowerRules.spawnPass(st, t, zones)
			expect(#made <= S.perPass).toBe(true)
			expect(st.alive <= S.maxTotal).toBe(true)
			for _, n in st.perZone do
				expect(n <= S.maxPerZone).toBe(true)
			end
			local count = 0
			for _ in st.meteors do
				count += 1
			end
			expect(count).toBe(st.alive)
			peak = math.max(peak, st.alive)
		end
		expect(peak > 0).toBe(true)
		ShowerRules.close(st)
		expect(st.alive).toBe(0)
		expect(next(st.meteors)).toBe(nil)
		expect(#ShowerRules.spawnPass(st, 999, zones)).toBe(0) -- nothing after close
	end)

	it("SHOWER: one player still gets meteors near them (low population)", function()
		local st = ShowerRules.new("T2", 5)
		local me = WorldLayout.getSlotCenter(1) + Vector3.new(0, WorldLayout.PLANET_RADIUS + 3, 0)
		local inRange = 0
		for t = 0, 60 do
			ShowerRules.expire(st, t)
			ShowerRules.spawnPass(st, t, { { zone = 1, near = { me } } })
			for _, m in st.meteors do
				if (ShowerMath.position(m, t) - me).Magnitude <= S.captureRange then
					inRange += 1
					break
				end
			end
		end
		expect(inRange >= 30).toBe(true)
	end)

	it("SHOWER: first valid capture wins; range, lag window, cap, expiry, ended", function()
		local st = ShowerRules.new("T3", 11)
		local me = WorldLayout.getSlotCenter(1) + Vector3.new(0, WorldLayout.PLANET_RADIUS + 3, 0)
		local m = ShowerRules.spawnPass(st, 0, { { zone = 1, near = { me } } })[1]
		local at = ShowerMath.position(m, 1)
		local ok1, c1, reward = ShowerRules.capture(st, 1, m.id, 1, at)
		local ok2, c2 = ShowerRules.capture(st, 2, m.id, 1, at) -- simultaneous second claim
		expect(ok1).toBe(true)
		expect(c1).toBe("OK")
		expect(ok2).toBe(false)
		expect(c2).toBe("TAKEN")
		local mat, amt = next(reward.materials)
		expect(S.materials[mat] ~= nil).toBe(true)
		expect(amt >= S.amount[1] and amt <= (if reward.rare then S.rareAmount[2] else S.amount[2])).toBe(true)
		local m2 = ShowerRules.spawnPass(st, 2, { { zone = 1, near = { me } } })[1]
		local _, c3 = ShowerRules.capture(st, 1, m2.id, 3, ShowerMath.position(m2, 3) + Vector3.new(0, 500, 0))
		expect(c3).toBe("OUT_OF_RANGE")
		expect((ShowerRules.capture(st, 1, m2.id, 3, ShowerMath.position(m2, 3 - S.lagWindow)))).toBe(true)
		local m3 = ShowerRules.spawnPass(st, 4, { { zone = 1, near = { me } } })[1]
		local _, c4 = ShowerRules.capture(st, 1, m3.id, 5, nil)
		expect(c4).toBe("NO_CHARACTER")
		local _, c5 = ShowerRules.capture(st, 1, { m3.id } :: any, 5, me)
		expect(c5).toBe("INVALID_PAYLOAD")
		local _, c6 = ShowerRules.capture(st, 1, m3.id, m3.t0 + m3.life + 1, me)
		expect(c6).toBe("EXPIRED")
		st.captures[9] = S.perPlayerCap
		local m4 = ShowerRules.spawnPass(st, 6, { { zone = 1, near = { me } } })[1]
		local _, c7 = ShowerRules.capture(st, 9, m4.id, 6, ShowerMath.position(m4, 6))
		expect(c7).toBe("CAP_REACHED")
		expect(ShowerRules.capturesLeft(st, 9)).toBe(0)
		ShowerRules.close(st)
		local _, c8 = ShowerRules.capture(st, 1, m4.id, 6, me)
		expect(c8).toBe("ENDED")
	end)

	it("SHOWER: client and server agree on every meteor path (encode/decode)", function()
		local st = ShowerRules.new("T4", 3)
		local made = ShowerRules.spawnPass(st, 10, allZones(8))
		expect(#made > 0).toBe(true)
		for _, m in made do
			local d = ShowerMath.decode(ShowerMath.encode(m)) :: any
			for _, t in { 10, 13.7, 20 } do
				expect((ShowerMath.position(d, t) - ShowerMath.position(m, t)).Magnitude < 1e-3).toBe(true)
			end
		end
		expect(ShowerMath.decode({ id = 5 })).toBe(nil)
	end)

	---------------------------------------------------------------- solar storm
	it("STORM: energy reactions only; refund = 50% floored, catalysts never; capped per player", function()
		local boosted = StormRules.boostedIds(Registry)
		expect(table.find(boosted, "R03") ~= nil).toBe(true)
		expect(table.find(boosted, "R06") ~= nil).toBe(true)
		expect(table.find(boosted, "R30") ~= nil).toBe(true)
		expect(table.find(boosted, "R01")).toBe(nil)
		expect(table.find(boosted, "R09")).toBe(nil)
		local refund = StormRules.refundFor(Registry.DEFS.R15) -- Magma 15 + Catalyst 1
		expect(refund.MagmaMatter).toBe(7)
		expect(refund.CosmicCatalyst).toBe(nil)
		local st = StormRules.new()
		for uid = 1, 8 do
			for i = 1, EventConfig.STORM.maxSurges do
				local ok, _, bonus = StormRules.apply(st, uid, Registry.DEFS.R03)
				expect(ok).toBe(true)
				expect(bonus.left).toBe(EventConfig.STORM.maxSurges - i)
			end
			local ok2, code2 = StormRules.apply(st, uid, Registry.DEFS.R03)
			expect(ok2).toBe(false)
			expect(code2).toBe("CAP_REACHED")
		end
		local ok3, code3 = StormRules.apply(st, 99, Registry.DEFS.R01)
		expect(ok3).toBe(false)
		expect(code3).toBe("NOT_BOOSTED")
		expect(st.total).toBe(8 * EventConfig.STORM.maxSurges)
	end)

	---------------------------------------------------------------- convergence
	it("CONV: target scales with players, never rises mid-event, small servers stay small", function()
		expect(Conv.targetFor(1)).toBe(CV.targetBase)
		expect(Conv.targetFor(0)).toBe(CV.targetBase)
		expect(Conv.targetFor(8)).toBe(CV.targetBase + CV.targetPerExtra * 7)
		expect(Conv.targetFor(30)).toBe(Conv.targetFor(CV.maxCounted))
		local run = Conv.new("C1", 6, 0)
		local t6 = run.target
		Conv.updatePlayers(run, 8)
		expect(run.target).toBe(t6)
		Conv.updatePlayers(run, 2)
		expect(run.target).toBe(Conv.targetFor(2))
	end)

	it("CONV: contributions, sync bonus, completion, nothing after close", function()
		local run = Conv.new("C2", 2, 0)
		expect((Conv.contribute(run, 1, "A", "calibrate", 0))).toBe(true)
		local _, _, pts = Conv.contribute(run, 2, "B", "calibrate", 1)
		expect(pts).toBe(CV.points.calibrate + CV.points.sync)
		local _, _, pts2 = Conv.contribute(run, 2, "B", "calibrate", 2)
		expect(pts2).toBe(CV.points.calibrate)
		local _, code = Conv.contribute(run, 1, "A", "hack", 3)
		expect(code).toBe("INVALID")
		local guard = 0
		while not run.completed and guard < 500 do
			guard += 1
			Conv.contribute(run, 1, "A", "deliver", 5)
		end
		expect(run.completed).toBe(true)
		local completed, stages = false, 0
		for _, e in Conv.drain(run) do
			if e.kind == "completed" then
				completed = true
			elseif e.kind == "stage" then
				stages += 1
			end
		end
		expect(completed).toBe(true)
		expect(stages).toBe(#CV.stages)
		local _, code2 = Conv.contribute(run, 1, "A", "deliver", 6)
		expect(code2).toBe("ENDED")
	end)

	it("CONV: fair rewards: proportional shares, capped, deterministic, thresholds", function()
		local run = Conv.new("C3", 4, 0)
		Conv.contribute(run, 5, "P5", "assist", 1) -- 4 points: below the minimum (before the reactor completes)
		local pts = { 10, 40, 90, 400 }
		for uid, p in pts do
			for k = 1, p / 10 do
				Conv.contribute(run, uid, "P" .. uid, "calibrate", uid * 1000 + k * 10) -- spaced: no sync bonus
			end
		end
		run.completed = true
		local prev = -1
		for uid = 1, 4 do
			local ok, r = Conv.rewardsFor(run, uid)
			expect(ok).toBe(true)
			expect(r.share <= CV.maxShare).toBe(true)
			expect(r.credits >= prev).toBe(true)
			prev = r.credits
			local _, again = Conv.rewardsFor(run, uid)
			expect(again.credits).toBe(r.credits)
			expect(next(again.catalysts)).toBe(next(r.catalysts))
		end
		local _, top = Conv.rewardsFor(run, 4)
		expect(top.share).toBe(CV.maxShare)
		local okLow, why = Conv.rewardsFor(run, 5)
		expect(okLow).toBe(false)
		expect(why).toBe("TOO_LITTLE")
		local okNone, why2 = Conv.rewardsFor(run, 77)
		expect(okNone).toBe(false)
		expect(why2).toBe("NOT_PARTICIPANT")
		local low = Conv.new("C4", 1, 0)
		Conv.contribute(low, 1, "A", "calibrate", 0)
		local okT, whyT = Conv.rewardsFor(low, 1)
		expect(okT).toBe(false)
		expect(whyT).toBe("NOT_STABILIZED")
		for k = 1, 4 do
			Conv.contribute(low, 1, "A", "calibrate", 100 + k)
		end
		local okP, part = Conv.rewardsFor(low, 1)
		expect(okP).toBe(true)
		expect(part.mult < 1).toBe(true)
		expect(next(part.catalysts)).toBe(nil)
	end)

	it("CONV: a leaver's settlement never exceeds what finishing would pay (top-up never negative)", function()
		for seed = 1, 30 do
			local rng = Random.new(seed)
			local players = rng:NextInteger(2, 8) -- someone must stay to finish the reactor
			local run = Conv.new("C5-" .. seed, players, 0)
			local leaver = rng:NextInteger(1, players)
			local settled = nil
			local t = 0
			while not run.completed and t < 5000 do
				t += 1
				local uid = rng:NextInteger(1, players)
				if not (settled and uid == leaver) then
					Conv.contribute(run, uid, "P" .. uid, if rng:NextNumber() < 0.5 then "calibrate" else "deliver", t)
				end
				if not settled and run.progress >= run.target * 0.6 then
					local ok, r = Conv.rewardsFor(run, leaver)
					settled = if ok then r else { credits = 0, xp = 0, energy = 0 }
				end
			end
			expect(run.completed).toBe(true)
			if settled then
				local ok, final = Conv.rewardsFor(run, leaver)
				if ok then
					expect(final.credits >= settled.credits).toBe(true)
					expect(final.xp >= settled.xp).toBe(true)
				end
			end
		end
	end)

	-- time model of the reactor (mirrors WorldEventService: unstable conduits, flux cells, cooldowns, walking)
	local function simulate(n: number, seed: number): (boolean, number)
		local rng = Random.new(seed)
		local run = Conv.new("SIM", n, 0)
		local dur = EventConfig.get("CosmicConvergence").duration
		local conduits = {}
		for i = 1, CV.conduits do
			conduits[i] = { state = "stable", stableUntil = 0 }
		end
		local cells, nextCell = 0, 1
		local busyUntil, carrying, doing = {}, {}, {}
		for p = 1, n do
			busyUntil[p] = 0
		end
		local t = 0
		while t < dur and not run.completed do
			t += 0.25
			local want = math.clamp(1 + math.floor(n / 2), 1, CV.conduits)
			local unstable, scheduled = 0, 0
			for _, c in conduits do
				if c.state == "unstable" then
					unstable += 1
				elseif c.unstableAt then
					scheduled += 1
				end
			end
			for _, c in conduits do
				if unstable + scheduled >= want then
					break
				end
				if c.state == "stable" and not c.unstableAt and t >= c.stableUntil then
					c.unstableAt = t + CV.unstableDelay[1] + (CV.unstableDelay[2] - CV.unstableDelay[1]) * rng:NextNumber()
					scheduled += 1
				end
			end
			for _, c in conduits do
				if c.unstableAt and t >= c.unstableAt then
					c.unstableAt = nil
					c.state = "unstable"
				end
			end
			local wantCells = math.clamp(1 + math.floor((n - 1) / CV.flux.perPlayers), 1, CV.flux.maxActive)
			local carried = 0
			for _ in carrying do
				carried += 1
			end
			if cells + carried < wantCells and t >= nextCell then
				cells += 1
				nextCell = t + 1
			end
			for p = 1, n do
				if t >= busyUntil[p] then
					if doing[p] then -- finished walking + holding at a conduit
						Conv.contribute(run, p, "P" .. p, "calibrate", t)
						doing[p].state, doing[p].stableUntil, doing[p].claimed = "stable", t + CV.conduitCooldown, nil
						doing[p] = nil
					elseif carrying[p] then
						carrying[p] = nil
						Conv.contribute(run, p, "P" .. p, "deliver", t)
						nextCell = math.min(nextCell, t + CV.flux.respawn)
					end
					local target = nil
					for _, c in conduits do
						if c.state == "unstable" and not c.claimed then
							target = c
							break
						end
					end
					if target then
						target.claimed = p
						doing[p] = target
						busyUntil[p] = t + 3.5 + CV.holdTime -- walk to the conduit (~3.5 s) + hold
					elseif cells > 0 then
						cells -= 1
						carrying[p] = true
						busyUntil[p] = t + 8 -- walk to the plaza rim, then back to the intake
					end
				end
			end
			Conv.drain(run)
		end
		return run.completed, t
	end

	it("CONV: 1..8 players at walking speed stabilize the reactor in time (small servers too)", function()
		local dur = EventConfig.get("CosmicConvergence").duration
		for n = 1, 8 do
			local worst = 0
			for seed = 1, 4 do
				local done, t = simulate(n, n * 100 + seed)
				if not done then
					error(string.format("%d player(s) did not finish in %ds (seed %d)", n, dur, seed))
				end
				worst = math.max(worst, t)
			end
			if worst > dur * 0.8 then
				error(string.format("%d player(s) need %ds of %ds: too tight", n, math.floor(worst), dur))
			end
		end
	end)

	---------------------------------------------------------------- social
	it("SOCIAL: abuse protection — own planet, new/brief accounts, not viewing, one per planet", function()
		local st = SocialRules.new()
		local good = { userId = 2, sessionSeconds = 999, accountAge = 30 }
		local ctxOk = { ownerId = 1, present = true }
		local _, c1 = SocialRules.react(st, { userId = 1, sessionSeconds = 999, accountAge = 30 }, ctxOk, "Stellar", 0)
		expect(c1).toBe("OWN_PLANET")
		local _, c2 = SocialRules.react(st, { userId = 3, sessionSeconds = 5, accountAge = 30 }, ctxOk, "Stellar", 0)
		expect(c2).toBe("TOO_SOON")
		local _, c3 = SocialRules.react(st, { userId = 4, sessionSeconds = 999, accountAge = 0 }, ctxOk, "Stellar", 0)
		expect(c3).toBe("ACCOUNT_TOO_NEW")
		local _, c4 = SocialRules.react(st, good, { ownerId = 1, present = false }, "Stellar", 0)
		expect(c4).toBe("NOT_VIEWING")
		local _, c5 = SocialRules.react(st, good, ctxOk, "Spam", 0)
		expect(c5).toBe("INVALID_KIND")
		local _, c6 = SocialRules.react(st, good, { ownerId = nil, present = true }, "Stellar", 0)
		expect(c6).toBe("NO_OWNER")
		expect((SocialRules.react(st, good, ctxOk, "Stellar", 0))).toBe(true)
		local _, c7 = SocialRules.react(st, good, ctxOk, "Stellar", 1)
		expect(c7).toBe("ALREADY")
		local _, c8 = SocialRules.react(st, good, ctxOk, "Wow", 1)
		expect(c8).toBe("COOLDOWN")
		local ok9, c9, info = SocialRules.react(st, good, ctxOk, "Wow", 1 + EventConfig.SOCIAL.changeCooldown)
		expect(ok9).toBe(true)
		expect(c9).toBe("CHANGED")
		expect(info.counts.total).toBe(1)
		expect(info.counts.Stellar).toBe(0)
		expect(info.counts.Wow).toBe(1)
	end)

	it("SOCIAL: 8 visitors, spam and leaving owners", function()
		local st = SocialRules.new()
		for uid = 2, 9 do
			for _ = 1, 20 do
				SocialRules.react(st, { userId = uid, sessionSeconds = 999, accountAge = 30 }, { ownerId = 1, present = true }, "Inspiring", 0)
			end
		end
		local c = SocialRules.countsFor(st, 1)
		expect(c.total).toBe(8)
		expect(c.Inspiring).toBe(8)
		expect(SocialRules.mine(st, 5)[1]).toBe("Inspiring")
		SocialRules.forgetOwner(st, 1)
		expect(SocialRules.countsFor(st, 1).total).toBe(0)
		expect(SocialRules.mine(st, 5)[1]).toBe(nil)
	end)
end
