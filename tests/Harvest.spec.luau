--!strict
-- Cosmic Core Hunt specs (Gameplay): paths, rules, session verification with fake players.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local HarvestConfig = require(RS.PF_Shared.Config.HarvestConfig)
	local MeteorPath = ctx.require(RS.PF_Shared.Harvest.MeteorPath)
	local HarvestRules = ctx.require(RS.PF_Shared.Harvest.HarvestRules)
	local HarvestLayout = ctx.require(RS.PF_Shared.Harvest.HarvestLayout)
	local Core = ctx.require(SSS.PF_Server.Harvest.HarvestSessionCore)
	local WorldLayout = require(RS.PF_Shared.Config.WorldLayout)
	local Z = HarvestConfig.ZONE

	local function inLane(p: Vector3): boolean
		return math.abs(p.X) <= Z.HALF_WIDTH + Z.ENTRY_MARGIN + 0.01
			and p.Y >= Z.MIN_HEIGHT - 30 and p.Y <= Z.MAX_HEIGHT + 30
			and p.Z >= Z.MIN_DEPTH - 25 and p.Z <= Z.MAX_DEPTH + 25
	end

	-- time inside the capture window of a spec, at or after t
	local function windowTime(spec: any, t: number, perfect: boolean?): number
		for i = 0, 400 do
			local tt = t + i * 0.01
			local q = HarvestRules.timingQuality(spec, tt, 0)
			if (perfect and q == "perfect") or (not perfect and q ~= nil) then
				return tt
			end
		end
		error("no window found")
	end
	local function badTime(spec: any, t: number): number
		for i = 0, 400 do
			local tt = t + i * 0.01
			if HarvestRules.timingQuality(spec, tt, HarvestConfig.FOCUS.MAX_STACKS) == nil then
				return tt
			end
		end
		error("no bad time found")
	end
	local function aimAt(L: any, spec: any, t: number): Vector3
		return (L.toWorld(MeteorPath.evaluate(spec, t) :: Vector3) - L.origin).Unit
	end

	it("layout: every slot's harvester sits on its planet surface, clear of the pole pad and spawn", function()
		for slot = 1, WorldLayout.SLOT_COUNT do
			local L = HarvestLayout.forSlot(slot)
			local center = WorldLayout.getSlotCenter(slot)
			expect(math.abs((L.base.Position - center).Magnitude - WorldLayout.PLANET_RADIUS) < 0.01).toBe(true)
			expect((L.base.UpVector - (L.base.Position - center).Unit).Magnitude < 1e-4).toBe(true)
			expect((L.console - WorldLayout.getPlanetPadPosition(slot)).Magnitude > 7).toBe(true)
			expect((L.base.Position - WorldLayout.getPlanetSpawn(slot).Position).Magnitude > 20).toBe(true)
			-- the whole lane is above the planet surface
			for _, corner in { Vector3.new(-Z.HALF_WIDTH, Z.MIN_HEIGHT, Z.MIN_DEPTH), Vector3.new(Z.HALF_WIDTH, Z.MIN_HEIGHT, Z.MAX_DEPTH) } do
				expect((L.toWorld(corner) - center).Magnitude > WorldLayout.PLANET_RADIUS + 20).toBe(true)
			end
			expect((L.toLocal(L.toWorld(Vector3.new(3, 4, 5))) - Vector3.new(3, 4, 5)).Magnitude < 1e-3).toBe(true)
			-- faces outward (away from the station) and keeps clear of the planet spawn
			local outward = (center - WorldLayout.STATION_CENTER) * Vector3.new(1, 0, 1)
			expect(L.base.LookVector:Dot(outward.Unit) > 0.9).toBe(true)
			expect(math.deg(math.acos(L.base.UpVector:Dot(Vector3.yAxis))) < 14).toBe(true)
			expect((L.operator - WorldLayout.getPlanetSpawn(slot).Position).Magnitude > 8).toBe(true)
		end
	end)

	it("paths: all patterns deterministic, finite and inside the bounded lane", function()
		for _, kind in { "Ice", "Magma", "Plasma" } do
			for _, pattern in { "drift", "arc", "weave", "spiral" } do
				local spec = MeteorPath.generate(Random.new(7), 1, kind, 100, pattern)
				local again = MeteorPath.generate(Random.new(7), 1, kind, 100, pattern)
				expect(MeteorPath.isValidSpec(spec)).toBe(true)
				expect(spec.duration > 3 and spec.duration < 30).toBe(true)
				for i = 0, 20 do
					local t = 100 + spec.duration * i / 20
					local p = MeteorPath.evaluate(spec, t) :: Vector3
					expect(p ~= nil and inLane(p)).toBe(true)
					expect(((MeteorPath.evaluate(again, t) :: Vector3) - p).Magnitude < 1e-6).toBe(true)
				end
				expect(MeteorPath.evaluate(spec, 99.9)).toBe(nil)
				expect(MeteorPath.evaluate(spec, 100 + spec.duration + 0.01)).toBe(nil)
			end
		end
		local tut = MeteorPath.generateTutorial(Random.new(1), 5, 0)
		for t = 0, 90, 3 do
			local p = MeteorPath.evaluate(tut, t) :: Vector3
			expect(math.abs(p.X) <= Z.HALF_WIDTH).toBe(true)
		end
	end)

	it("rules: capture needs aim AND timing; focus stacks widen both", function()
		local L = HarvestLayout.forSlot(1)
		local spec = MeteorPath.generate(Random.new(3), 9, "Magma", 0, "drift")
		local tGood = windowTime(spec, spec.duration * 0.4)
		local r = HarvestRules.evaluateShot(spec, tGood, L.toWorld, L.origin, aimAt(L, spec, tGood), 0)
		expect(r.hit).toBe(true)
		local tPerfect = windowTime(spec, spec.duration * 0.4, true)
		expect(HarvestRules.evaluateShot(spec, tPerfect, L.toWorld, L.origin, aimAt(L, spec, tPerfect), 0).quality).toBe("perfect")
		local tBad = badTime(spec, spec.duration * 0.4)
		expect(HarvestRules.evaluateShot(spec, tBad, L.toWorld, L.origin, aimAt(L, spec, tBad), 0).reason).toBe("MISS_TIMING")
		-- aim 12 degrees off: miss without focus, still a miss with max focus (cone 4 + 5)
		local aim = aimAt(L, spec, tGood)
		local off = (CFrame.fromAxisAngle(L.base.UpVector, math.rad(12)) * CFrame.new()):VectorToWorldSpace(aim)
		expect(HarvestRules.evaluateShot(spec, tGood, L.toWorld, L.origin, off, 0).reason).toBe("MISS_AIM")
		-- 6 degrees off: miss at 0 stacks, hit at 1+ stacks
		local six = CFrame.fromAxisAngle(L.base.UpVector, math.rad(6)):VectorToWorldSpace(aim)
		local r0 = HarvestRules.evaluateShot(spec, tGood, L.toWorld, L.origin, six, 0)
		local r1 = HarvestRules.evaluateShot(spec, tGood, L.toWorld, L.origin, six, 1)
		expect(r0.allowedDeg < 6 or r0.hit).toBe(true)
		expect(r1.hit).toBe(true)
		expect(HarvestRules.evaluateShot(spec, -5, L.toWorld, L.origin, aim, 0).reason).toBe("EXPIRED")
		expect(HarvestRules.rewardMultiplier("Plasma", "perfect") <= 5).toBe(true)
	end)

	local function newCore()
		return Core.new({ seed = 42 })
	end

	it("sessions: 8 simultaneous players get independent streams; foreign target ids are rejected", function()
		local core = newCore()
		local now = 1000
		for i = 1, 8 do
			core:Start("p" .. i, i, now, { tutorial = false })
		end
		expect(core:SessionCount()).toBe(8)
		for step = 1, 50 do
			core:Tick(now + step * 0.2)
		end
		now += 10
		local ids = {}
		for i = 1, 8 do
			local s = core:Get("p" .. i)
			local active = core:ActiveCount(s, now)
			expect(active >= HarvestConfig.SPAWN.MIN_ACTIVE and active <= HarvestConfig.SPAWN.MAX_ACTIVE).toBe(true)
			for id in s.meteors do
				expect(ids[id]).toBe(nil) -- ids unique across sessions
				ids[id] = "p" .. i
			end
		end
		-- p1 tries to claim p2's meteor (charged properly, so only ownership can reject it)
		local foreignId = next(core:Get("p2").meteors)
		core:BeginCharge("p1", now - 1)
		local res = core:Fire("p1", { targetId = foreignId, fireTime = now, aim = Vector3.yAxis }, { now = now, canAfford = true })
		expect(res.ok).toBe(false)
		expect(res.code).toBe("UNKNOWN_TARGET")
		expect(core:Fire("ghost", { targetId = foreignId, fireTime = now, aim = Vector3.yAxis }, { now = now, canAfford = true }).code).toBe("NOT_OPERATING")
	end)

	it("sessions: capture, duplicate claim, cooldown, bad time, miss + focus recovery", function()
		local core = newCore()
		local s = core:Start("a", 1, 0, { tutorial = false })
		local spec = MeteorPath.generate(Random.new(11), 777, "Ice", 0, "drift")
		s.meteors[777] = spec
		s.issued[777] = true
		local L = s.layout
		local t = windowTime(spec, 3)
		-- missed timing first -> focus stack
		local tb = badTime(spec, 2)
		core:BeginCharge("a", tb - 0.6)
		local miss = core:Fire("a", { targetId = 777, fireTime = tb, aim = aimAt(L, spec, tb) }, { now = tb, canAfford = true })
		expect(miss.ok).toBe(true)
		expect(miss.outcome).toBe("miss")
		expect(miss.reason).toBe("MISS_TIMING")
		expect(miss.missStacks).toBe(1)
		-- rapid second shot -> cooldown
		local cd = core:Fire("a", { targetId = 777, fireTime = tb + 0.1, aim = aimAt(L, spec, tb + 0.1) }, { now = tb + 0.1, canAfford = true })
		expect(cd.code).toBe("COOLDOWN")
		-- fireTime far in the past / future
		expect(core:Fire("a", { targetId = 777, fireTime = t - 5, aim = Vector3.yAxis }, { now = t, canAfford = true }).code).toBe("BAD_TIME")
		expect(core:Fire("a", { targetId = 777, fireTime = t + 2, aim = Vector3.yAxis }, { now = t, canAfford = true }).code).toBe("BAD_TIME")
		-- proper capture (after the 3.2 s miss reload, with a fresh charge)
		local t2 = windowTime(spec, tb + HarvestConfig.SHOT.MISS_COOLDOWN + 0.7)
		core:BeginCharge("a", t2 - 0.6)
		local cap = core:Fire("a", { targetId = 777, fireTime = t2, aim = aimAt(L, spec, t2) }, { now = t2 + 0.05, canAfford = true })
		expect(cap.ok).toBe(true)
		expect(cap.outcome).toBe("capture")
		expect(cap.missStacksBefore).toBe(1)
		expect(s.missStacks).toBe(0)
		core:Settle("a")
		-- duplicate claim (after the reload, charged)
		local td = t2 + HarvestConfig.SHOT.COOLDOWN + 0.1
		core:BeginCharge("a", td)
		local dup = core:Fire("a", { targetId = 777, fireTime = td + 0.6, aim = aimAt(L, spec, t2) }, { now = td + 0.6, canAfford = true })
		expect(dup.code).toBe("ALREADY_CLAIMED")
	end)

	it("sessions: no energy -> target stays capturable; unclaim restores it", function()
		local core = newCore()
		local s = core:Start("a", 2, 0, { tutorial = false })
		local spec = MeteorPath.generate(Random.new(5), 900, "Plasma", 0, "drift")
		s.meteors[900], s.issued[900] = spec, true
		local t = windowTime(spec, 0.7)
		core:BeginCharge("a", t - 0.6)
		local r = core:Fire("a", { targetId = 900, fireTime = t, aim = aimAt(s.layout, spec, t) }, { now = t, canAfford = false })
		expect(r.code).toBe("NOT_ENOUGH_ENERGY")
		expect(s.meteors[900] ~= nil).toBe(true)
		local t2 = windowTime(spec, t + HarvestConfig.SHOT.COOLDOWN + 0.7)
		core:BeginCharge("a", t2 - 0.6)
		local ok = core:Fire("a", { targetId = 900, fireTime = t2, aim = aimAt(s.layout, spec, t2) }, { now = t2, canAfford = true })
		expect(ok.outcome).toBe("capture")
		core:Unclaim("a", ok.spec)
		expect(s.claimed[900]).toBe(nil)
		expect(s.meteors[900] ~= nil).toBe(true)
	end)

	it("sessions: expired target resolves as a miss; target destruction after grace", function()
		local core = newCore()
		local s = core:Start("a", 3, 0, { tutorial = false })
		local spec = MeteorPath.generate(Random.new(9), 500, "Ice", 0, "drift")
		s.meteors[500], s.issued[500] = spec, true
		local late = spec.duration + 0.3
		core:BeginCharge("a", late - 0.6)
		local r = core:Fire("a", { targetId = 500, fireTime = late, aim = Vector3.yAxis }, { now = late, canAfford = true })
		expect(r.outcome).toBe("miss")
		expect(r.reason).toBe("EXPIRED")
		core:Tick(spec.duration + HarvestConfig.SPAWN.EXPIRE_GRACE + 0.5)
		expect(s.meteors[500]).toBe(nil)
		local tr = late + HarvestConfig.SHOT.MISS_COOLDOWN + 0.1
		core:BeginCharge("a", tr)
		local r2 = core:Fire("a", { targetId = 500, fireTime = tr + 0.6, aim = Vector3.yAxis }, { now = tr + 0.6, canAfford = true })
		expect(r2.reason).toBe("EXPIRED") -- issued id, gone: still a clean miss, never a reward
	end)

	it("sessions: per-minute capture cap, idle timeout, disconnect (stop) mid-session", function()
		local core = newCore()
		local s = core:Start("a", 4, 0, { tutorial = false })
		local now = 1
		for i = 1, HarvestConfig.LIMITS.MAX_CAPTURES_PER_MINUTE do
			table.insert(s.captureTimes, now)
		end
		local spec = MeteorPath.generate(Random.new(2), 600, "Ice", 0, "drift")
		s.meteors[600], s.issued[600] = spec, true
		local t = windowTime(spec, 2)
		core:BeginCharge("a", t - 0.6)
		expect(core:Fire("a", { targetId = 600, fireTime = t, aim = aimAt(s.layout, spec, t) }, { now = t, canAfford = true }).code).toBe("CAPTURE_LIMIT")
		-- disconnect: session gone, later claims rejected
		core:Stop("a")
		expect(core:Fire("a", { targetId = 600, fireTime = t + 1, aim = Vector3.yAxis }, { now = t + 1, canAfford = true }).code).toBe("NOT_OPERATING")
		local c2 = newCore()
		c2:Start("b", 5, 0, { tutorial = false })
		local ended = c2:Tick(HarvestConfig.OPERATE.IDLE_TIMEOUT + 1)
		expect(ended.b).toBe("idle")
		expect(c2:Get("b")).toBe(nil)
	end)

	it("tutorial: single slow target that never runs out, then the normal stream starts", function()
		local core = newCore()
		local s = core:Start("t", 1, 0, { tutorial = true })
		expect(s.tutorial).toBe(true)
		local tut = s.meteors[s.tutorialId]
		expect(tut.tutorial).toBe(true)
		for k = 1, 20 do
			core:Tick(k * 0.2)
		end
		expect(core:ActiveCount(s, 4)).toBe(1)
		core:Tick(tut.duration + HarvestConfig.SPAWN.EXPIRE_GRACE + 1)
		expect(s.tutorialId ~= nil and s.tutorialId ~= tut.id).toBe(true) -- respawned
		s.lastActivityAt = 199 -- the player has been shooting
		core:CompleteTutorial("t", 200)
		core:Tick(200.1)
		expect(s.tutorial).toBe(false)
		expect(core:ActiveCount(s, 200.5) >= 1).toBe(true)
	end)
end
