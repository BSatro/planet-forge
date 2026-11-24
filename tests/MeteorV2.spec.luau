--!strict
-- Meteor Overhaul V2 specs (Gameplay): 12 variants, rarity odds, gating, captures, anti-spam emitter,
-- validation, latency, mobile tolerance, memory. Pure modules + the session core with fake players; no
-- live data stores, no remotes. Feel / difficulty balance is NOT proven here (that needs playtests).
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local HarvestConfig = require(RS.PF_Shared.Config.HarvestConfig)
	local EconomyConfig = require(RS.PF_Shared.Config.EconomyConfig)
	local Registry = require(RS.PF_Shared.Harvest.MeteorRegistry)
	local MeteorPath = require(RS.PF_Shared.Harvest.MeteorPath)
	local HarvestRules = require(RS.PF_Shared.Harvest.HarvestRules)
	local HarvestLayout = require(RS.PF_Shared.Harvest.HarvestLayout)
	local Rules = require(RS.PF_Shared.Evolution.EvolutionRules)
	local Core = require(SSS.PF_Server.Harvest.HarvestSessionCore)
	local Schema = require(SSS.PF_Server.Data.ProfileSchema)
	local NetConfig = require(SSS.PF_Server.Config.NetConfig)
	local RemoteGuard = require(SSS.PF_Server.Net.RemoteGuard)
	local SHOT = HarvestConfig.SHOT
	local Z = HarvestConfig.ZONE
	local Q = HarvestConfig.QUALITY_MULTIPLIER

	local function inLane(p: Vector3?): boolean
		return p ~= nil
			and math.abs(p.X) <= Z.HALF_WIDTH + Z.ENTRY_MARGIN + 0.01
			and p.Y >= Z.MIN_HEIGHT - 30 and p.Y <= Z.MAX_HEIGHT + 30
			and p.Z >= Z.MIN_DEPTH - 25 and p.Z <= Z.MAX_DEPTH + 25
	end
	local function newCore(seed: number?): any
		return Core.new({ seed = seed or 42 })
	end
	local function start(core: any, key: string, slot: number?, t: number?): any
		return core:Start(key, slot or 1, t or 0, { tutorial = false })
	end
	local function inject(core: any, key: string, spec: any): any
		local s = core:Get(key)
		s.meteors[spec.id] = spec
		s.issued[spec.id] = spec.t0 + spec.duration + 1000
		return s
	end
	-- first time >= t where the target is in flight, not phased and inside the window (perfect band if asked)
	local function windowTime(spec: any, t: number, perfect: boolean?, stacks: number?): number?
		for i = 0, 3000 do
			local tt = t + i * 0.01
			if MeteorPath.evaluate(spec, tt) and not MeteorPath.isPhased(spec, tt) then
				local q = HarvestRules.timingQuality(spec, tt, stacks or 0)
				if (perfect and q == "perfect") or (not perfect and q ~= nil) then
					return tt
				end
			end
		end
		return nil
	end
	local function badTime(spec: any, t: number): number?
		for i = 0, 3000 do
			local tt = t + i * 0.01
			if MeteorPath.evaluate(spec, tt) and not MeteorPath.isPhased(spec, tt) and HarvestRules.timingQuality(spec, tt, HarvestConfig.FOCUS.MAX_STACKS) == nil then
				return tt
			end
		end
		return nil
	end
	local function aimAt(L: any, spec: any, t: number): Vector3
		return (L.toWorld(MeteorPath.evaluate(spec, t) :: Vector3) - L.origin).Unit
	end
	-- rotate `aim` by exactly `deg` degrees (about an axis perpendicular to it)
	local function rotateOff(L: any, aim: Vector3, deg: number): Vector3
		local axis = aim:Cross(L.base.UpVector)
		if axis.Magnitude < 1e-3 then
			axis = aim:Cross(L.base.RightVector)
		end
		return CFrame.fromAxisAngle(axis.Unit, math.rad(deg)):VectorToWorldSpace(aim)
	end
	-- charge (server timestamp `hold` before t) + release at t
	local function shoot(core: any, key: string, id: number, t: number, aim: Vector3, opts: any?): any
		local o = opts or {}
		core:BeginCharge(key, t - (o.hold or 0.55))
		return core:Fire(key, { targetId = id, fireTime = t, aim = aim }, { now = t + (o.lag or 0), ping = o.ping, canAfford = o.canAfford ~= false })
	end
	local function exact(L: any, spec: any, t: number): Vector3
		return aimAt(L, spec, t)
	end
	-- fresh core + one meteor of `kind` + one charged shot inside its window
	local function oneShot(kind: string, seed: number, aimFn: any, opts: any?): (any, any, any, any, number)
		local o = opts or {}
		local core = newCore(seed)
		local s = start(core, "a", (seed % 8) + 1, 0)
		local spec = MeteorPath.generate(Random.new(seed), 20000 + seed, kind, 0, o.pattern)
		inject(core, "a", spec)
		local t = windowTime(spec, spec.t0 + 0.6, o.perfect)
		if not t then
			error("no capture window for " .. kind .. " seed " .. seed)
		end
		local r = shoot(core, "a", spec.id, t, aimFn(s.layout, spec, t), o)
		return r, core, s, spec, t
	end

	---------------------------------------------------------------- 1
	it("1 registry: 12 data-driven variants, valid config, existing resources, legacy aliases", function()
		local ok, problems = Registry.validate()
		if not ok then
			error(table.concat(problems, "; "))
		end
		local RARITY = { Ice = "common", Magma = "common", Plasma = "uncommon", Crystal = "uncommon", Bio = "uncommon", Iron = "uncommon", Magnetic = "rare", Split = "rare", Comet = "epic", Stellar = "legendary", Void = "mythic", Astral = "secret" }
		expect(#Registry.ORDER).toBe(12)
		local materials = { IceMatter = true, MagmaMatter = true, PlasmaMatter = true, CrystalFragments = true, BioEssence = true, CosmicCatalyst = true }
		for _, id in Registry.ORDER do
			local def = Registry.get(id)
			expect(def.rarity).toBe(RARITY[id])
			expect(materials[def.resource]).toBe(true)
			for _, field in { "displayName", "theme", "color", "speedMultiplier", "size", "patterns", "period", "window", "perfect", "resource", "multiplier", "sfx", "vfx", "weight", "discovery" } do
				if def[field] == nil then
					error(id .. " is missing " .. field)
				end
			end
		end
		expect(Registry.resolve("Spore")).toBe("Bio")
		expect(Registry.get("Spore")).toBe(Registry.get("Bio"))
		expect(Registry.resolve("Comet")).toBe("Comet")
		expect(Registry.resolve("Anomaly")).toBe(nil)
		expect(Registry.resolve(42)).toBe(nil)
		for _, id in Registry.ORDER do
			for seed = 1, 10 do
				local a = MeteorPath.generate(Random.new(seed), 10, id, 100)
				local b = MeteorPath.generate(Random.new(seed), 10, id, 100)
				expect(MeteorPath.isValidSpec(a)).toBe(true)
				expect(a.kind).toBe(id)
				for i = 0, 24 do
					local t = a.t0 + a.duration * i / 24
					local p = MeteorPath.evaluate(a, t)
					expect(inLane(p)).toBe(true)
					expect(((MeteorPath.evaluate(b, t) :: Vector3) - (p :: Vector3)).Magnitude < 1e-6).toBe(true)
				end
				if a.splits then
					local n = 0
					local frags = MeteorPath.generateFragments(Random.new(seed), a, function()
						n += 1
						return 100 + n
					end)
					expect(#frags).toBe(HarvestConfig.SPLIT.FRAGMENTS)
					for _, f in frags do
						expect(MeteorPath.isValidSpec(f) and f.fragment == true and f.parentId == a.id).toBe(true)
						expect(math.abs(f.t0 - (a.t0 + a.duration)) < 1e-9).toBe(true)
						expect(((MeteorPath.evaluate(f, f.t0) :: Vector3) - (MeteorPath.evaluate(a, a.t0 + a.duration) :: Vector3)).Magnitude < 1e-6).toBe(true)
						for i = 0, 10 do
							expect(inLane(MeteorPath.evaluate(f, f.t0 + f.duration * i / 10))).toBe(true)
						end
					end
				end
			end
		end
		-- a legacy in-flight spec ("Spore", from an older server) still verifies and rewards as Bio
		local legacy = MeteorPath.generate(Random.new(3), 11, "Spore", 0)
		expect(legacy.kind).toBe("Bio")
		legacy.kind = "Spore"
		expect(HarvestRules.rewardMultiplier("Spore", "good")).toBe(Registry.get("Bio").multiplier)
		local L = HarvestLayout.forSlot(1)
		local t = windowTime(legacy, 1) :: number
		expect(HarvestRules.evaluateShot(legacy, t, L.toWorld, L.origin, aimAt(L, legacy, t), 0).hit).toBe(true)
	end)

	---------------------------------------------------------------- 2
	it("2 spawn probabilities: configured weights, exact renormalization, no pity / anti-streak (200k draws)", function()
		local W = { Ice = 24, Magma = 20, Plasma = 16, Crystal = 12, Bio = 10, Iron = 7, Magnetic = 4, Split = 3, Comet = 2, Stellar = 1, Void = 0.7, Astral = 0.3 }
		local total = 0
		for id, w in W do
			expect(Registry.get(id).weight).toBe(w)
			total += w
		end
		expect(math.abs(total - 100) < 1e-9).toBe(true)
		local core = newCore(5)
		local s = start(core, "p", 1, 0) -- no planet context: everything eligible
		local weights = core:Weights(s)
		local probs = Registry.probabilities(weights)
		for id, w in W do
			expect(math.abs(probs[id] - w / 100) < 1e-9).toBe(true)
		end
		local rng = Random.new(1234)
		local N = 200000
		local counts = {}
		for _ = 1, N do
			local k = MeteorPath.pickWeighted(rng, weights, Registry.ORDER) :: string
			counts[k] = (counts[k] or 0) + 1
		end
		for id, w in W do
			local p = w / 100
			local f = (counts[id] or 0) / N
			local sigma = math.sqrt(p * (1 - p) / N)
			if math.abs(f - p) > 4.5 * sigma then
				error(string.format("%s frequency %.5f, expected %.5f", id, f, p))
			end
		end
		-- the live stream uses the same odds (no anti-streak, no pity)
		expect(HarvestConfig.SPAWN.STREAK_DAMPING).toBe(1)
		local stream, n, iceIce, iceIceN = {}, 6000, 0, 0
		for i = 1, n do
			local p1, p2 = s.recentKinds[1], s.recentKinds[2]
			local spec = core:_spawnNormal(s, i)
			stream[spec.kind] = (stream[spec.kind] or 0) + 1
			if p1 == "Ice" and p2 == "Ice" then
				iceIceN += 1
				if spec.kind == "Ice" then
					iceIce += 1
				end
			end
			s.meteors, s.issued, s.children, s.outbox, s.spawnTimes = {}, {}, {}, {}, {}
		end
		expect(math.abs((stream.Ice or 0) / n - 0.24) < 0.03).toBe(true)
		expect(iceIceN > 100).toBe(true)
		expect(math.abs(iceIce / iceIceN - 0.24) < 0.1).toBe(true)
	end)

	---------------------------------------------------------------- 3
	it("3 progression gating: gated variants never spawn, the rest renormalize, aliases mirror", function()
		local p = Schema.default(1000, 4242)
		local c0 = HarvestRules.worldContext(Rules.viewFromProfile(p))
		for _, id in { "Ice", "Magma", "Plasma", "Crystal", "Iron" } do
			expect(c0.allowed[id]).toBe(true)
		end
		for _, id in { "Bio", "Magnetic", "Split", "Comet", "Stellar", "Void", "Astral" } do
			expect(c0.allowed[id]).toBe(false)
		end
		expect(c0.allowed.Spore).toBe(false)
		local core = newCore(9)
		local s = core:Start("k", 1, 0, { tutorial = false, worldContext = c0 })
		local probs = Registry.probabilities(core:Weights(s))
		local eligible = 24 + 20 + 16 + 12 + 7
		expect(math.abs(probs.Ice - 24 / eligible) < 1e-9).toBe(true)
		expect(math.abs(probs.Iron - 7 / eligible) < 1e-9).toBe(true)
		expect(probs.Astral).toBe(nil)
		local seen = {}
		for i = 1, 400 do
			seen[core:_spawnNormal(s, i).kind] = true
			s.outbox = {}
		end
		for _, id in { "Bio", "Magnetic", "Split", "Comet", "Stellar", "Void", "Astral" } do
			expect(seen[id]).toBe(nil)
		end
		expect(seen.Iron == true and seen.Ice == true).toBe(true)
		p.planet.dna.Water = 20
		p.planet.stage = 1
		local c1 = HarvestRules.worldContext(Rules.viewFromProfile(p))
		expect(c1.allowed.Bio and c1.allowed.Spore and c1.allowed.Magnetic and c1.allowed.Split and c1.allowed.Stellar).toBe(true)
		expect(c1.allowed.Comet or c1.allowed.Void or c1.allowed.Astral).toBe(false)
		p.planet.stage = 2
		local c2 = HarvestRules.worldContext(Rules.viewFromProfile(p))
		expect(c2.allowed.Comet and c2.allowed.Void).toBe(true)
		expect(c2.allowed.Astral).toBe(false)
		p.planet.stage = 3
		expect(HarvestRules.worldContext(Rules.viewFromProfile(p)).allowed.Astral).toBe(true)
		p.planet.branch = "Living"
		core:SetWorldContext("k", HarvestRules.worldContext(Rules.viewFromProfile(p)))
		expect(core:Weights(s).Bio).toBe(10 * HarvestConfig.BRANCH_WEIGHT_MULTIPLIERS.Living.Bio)
	end)

	---------------------------------------------------------------- 4
	it("4 common captures: Ice and Magma, good and perfect, multiplier and reload", function()
		local core = newCore(1)
		local s = start(core, "a", 1, 0)
		local L = s.layout
		local t = 1
		for i, kind in { "Ice", "Magma", "Ice", "Magma" } do
			local spec = MeteorPath.generate(Random.new(i), 5000 + i, kind, t)
			inject(core, "a", spec)
			local tw = windowTime(spec, math.max(spec.t0 + 0.5, core:ReadyAt("a") + 0.6), i > 2) :: number
			local r = shoot(core, "a", spec.id, tw, aimAt(L, spec, tw))
			expect(r.outcome).toBe("capture")
			expect(i <= 2 or r.quality == "perfect").toBe(true)
			expect(math.abs(r.multiplier - Registry.get(kind).multiplier * Q[r.quality]) < 1e-9).toBe(true)
			expect(math.abs(r.readyAt - (tw + SHOT.COOLDOWN)) < 1e-9).toBe(true)
			core:Settle("a")
			t = r.readyAt + 0.1
		end
		expect(s.captures).toBe(4)
		expect(s.shots).toBe(4)
	end)

	---------------------------------------------------------------- 5
	it("5 rare captures: Magnetic mid-correction; Split parent cancels fragments; fragments pay 60%", function()
		local core = newCore(2)
		local s = start(core, "a", 1, 0)
		local L = s.layout
		local mag = MeteorPath.generate(Random.new(4), 6001, "Magnetic", 0)
		expect(mag.pattern).toBe("magnetic")
		inject(core, "a", mag)
		local W = HarvestConfig.PATTERNS.magnetic.WIDTH
		local tc = mag.t0 + mag.duration * (mag.m1 + W * 0.5)
		local straight = Vector3.new(mag.ax, mag.ay, mag.az):Lerp(Vector3.new(mag.bx, mag.by, mag.bz), (tc - mag.t0) / mag.duration)
		expect(((MeteorPath.evaluate(mag, tc) :: Vector3) - straight).Magnitude > 2).toBe(true)
		local tw = windowTime(mag, tc - 0.3) :: number
		local r = shoot(core, "a", mag.id, tw, aimAt(L, mag, tw))
		expect(r.outcome).toBe("capture")
		-- split through the live stream code path
		local c2 = newCore(3)
		local s2 = start(c2, "b", 2, 0)
		s2.worldContext = { allowed = { Split = true } }
		local parent = c2:_spawnNormal(s2, 1)
		expect(parent.kind).toBe("Split")
		local kids = s2.children[parent.id]
		expect(#kids).toBe(HarvestConfig.SPLIT.FRAGMENTS)
		expect(c2:ActiveCount(s2, parent.t0 + 0.1)).toBe(1) -- parent + unborn fragments count once
		expect(c2:ActiveCount(s2, parent.t0 + parent.duration + 0.05)).toBe(2)
		local tp = windowTime(parent, parent.t0 + 0.6) :: number
		expect(tp < parent.t0 + parent.duration).toBe(true)
		local rp = shoot(c2, "b", parent.id, tp, aimAt(s2.layout, parent, tp))
		expect(rp.outcome).toBe("capture")
		expect(#rp.cancelIds).toBe(#kids)
		expect(math.abs(rp.multiplier - Registry.get("Split").multiplier * Q[rp.quality]) < 1e-9).toBe(true)
		for _, cid in kids do
			expect(s2.meteors[cid]).toBe(nil)
			expect(s2.claimed[cid]).toBe(true)
		end
		c2:Unclaim("b", rp.spec, rp.cancelled) -- reward failed: parent and fragments come back
		for _, cid in kids do
			expect(s2.meteors[cid] ~= nil and s2.claimed[cid] == nil).toBe(true)
		end
		-- fragments after the split
		local c3 = newCore(4)
		local s3 = start(c3, "c", 3, 0)
		s3.worldContext = { allowed = { Split = true } }
		local p3 = c3:_spawnNormal(s3, 1)
		local frag = s3.meteors[s3.children[p3.id][1]]
		local tf = windowTime(frag, frag.t0 + 0.6) :: number
		local rf = shoot(c3, "c", frag.id, tf, aimAt(s3.layout, frag, tf))
		expect(rf.outcome).toBe("capture")
		expect(math.abs(rf.multiplier - Registry.get("Split").multiplier * Q[rf.quality] * HarvestConfig.SPLIT.FRAGMENT_REWARD) < 1e-9).toBe(true)
		-- the parent can no longer be claimed once it has split
		c3:Settle("c")
		local late = rf.readyAt + 0.6
		local rl = shoot(c3, "c", p3.id, late, Vector3.yAxis)
		expect(rl.reason).toBe("EXPIRED")
	end)

	---------------------------------------------------------------- 6
	it("6 very fast captures: Comet / Stellar / Void / Astral speeds in band and capturable inside the lane", function()
		for _, kind in { "Comet", "Stellar", "Void", "Astral" } do
			local def = Registry.get(kind)
			local rar = Registry.rarity(kind)
			local captured = 0
			for seed = 1, 25 do
				local core = newCore(seed)
				local s = start(core, "a", (seed % 8) + 1, 0)
				local L = s.layout
				local spec = MeteorPath.generate(Random.new(seed * 31), 7000 + seed, kind, 0)
				local m = spec.spd / HarvestConfig.SPEED.BASE
				local j = HarvestConfig.SPAWN.SPEED_JITTER
				expect(m >= rar.speedMin * (1 - j) - 1e-9 and m <= rar.speedMax * (1 + j) + 1e-9).toBe(true)
				expect(spec.tele).toBe(def.telegraph)
				inject(core, "a", spec)
				local open, first = 0, nil
				for i = 0, math.floor(spec.duration / 0.01) do
					local tt = spec.t0 + i * 0.01
					local p = MeteorPath.evaluate(spec, tt)
					if p and math.abs(p.X) <= Z.HALF_WIDTH and not MeteorPath.isPhased(spec, tt) and HarvestRules.timingQuality(spec, tt, 0) then
						open += 0.01
						first = first or tt
					end
				end
				if open < 0.6 then
					error(string.format("%s seed %d: only %.2f s of capture window inside the lane", kind, seed, open))
				end
				local tw = first :: number
				local dist = (L.toWorld(MeteorPath.evaluate(spec, tw) :: Vector3) - L.origin).Magnitude
				local allowed = HarvestRules.allowedAngleDeg(spec, dist, 0, 0)
				local r = shoot(core, "a", spec.id, tw, rotateOff(L, aimAt(L, spec, tw), allowed * 0.7))
				if r.outcome == "capture" then
					captured += 1
				end
			end
			expect(captured).toBe(25)
		end
	end)

	---------------------------------------------------------------- 7
	it("7 perfect capture: x1.5 for every variant, best reward within the economy bound", function()
		for i, kind in Registry.ORDER do
			local r = oneShot(kind, 100 + i, exact, { perfect = true })
			expect(r.outcome).toBe("capture")
			expect(r.quality).toBe("perfect")
			expect(math.abs(r.multiplier - HarvestRules.rewardMultiplier(kind, "good") * Q.perfect) < 1e-9).toBe(true)
			expect(r.multiplier <= EconomyConfig.HARVEST.MAX_MULTIPLIER + 1e-9).toBe(true)
		end
	end)

	---------------------------------------------------------------- 8
	it("8 missed capture: timing / aim / phase misses -> focus +1 and the longer miss reload", function()
		local core = newCore(8)
		local s = start(core, "a", 1, 0)
		local L = s.layout
		local spec = MeteorPath.generate(Random.new(8), 9001, "Ice", 0, "drift")
		inject(core, "a", spec)
		local tb = badTime(spec, 1) :: number
		local r = shoot(core, "a", spec.id, tb, aimAt(L, spec, tb))
		expect(r.outcome).toBe("miss")
		expect(r.reason).toBe("MISS_TIMING")
		expect(r.missStacks).toBe(1)
		expect(math.abs(r.readyAt - (tb + SHOT.MISS_COOLDOWN)) < 1e-9).toBe(true)
		expect(SHOT.MISS_COOLDOWN > SHOT.COOLDOWN).toBe(true)
		local okC, codeC = core:BeginCharge("a", tb + 3.0) -- a hit's 2.8 s would have passed; a miss's 3.2 s has not
		expect(okC).toBe(false)
		expect(codeC).toBe("COOLDOWN")
		local t2 = windowTime(spec, r.readyAt + 0.6) :: number
		local r2 = shoot(core, "a", spec.id, t2, rotateOff(L, aimAt(L, spec, t2), 25))
		expect(r2.reason).toBe("MISS_AIM")
		expect(r2.missStacks).toBe(2)
		local void = MeteorPath.generate(Random.new(2), 9002, "Void", r2.readyAt)
		inject(core, "a", void)
		local tph = nil
		for i = 0, 3000 do
			local tt = void.t0 + i * 0.01
			if tt >= r2.readyAt + 0.6 and MeteorPath.evaluate(void, tt) and MeteorPath.isPhased(void, tt) then
				tph = tt
				break
			end
		end
		expect(tph ~= nil).toBe(true)
		local r3 = shoot(core, "a", void.id, tph :: number, aimAt(L, void, tph :: number))
		expect(r3.reason).toBe("MISS_PHASED")
		expect(s.missStacks).toBe(HarvestConfig.FOCUS.MAX_STACKS)
	end)

	---------------------------------------------------------------- 9
	it("9 cooldown enforcement: 2.8 s reload, server-clock charge >= 0.5 s, one charge per release", function()
		expect(SHOT.COOLDOWN).toBe(2.8)
		expect(SHOT.MISS_COOLDOWN).toBe(3.2)
		expect(SHOT.MIN_CHARGE).toBe(0.5)
		expect(SHOT.MAX_CONCURRENT).toBe(1)
		local core = newCore(9)
		local s = start(core, "a", 1, 0)
		local L = s.layout
		local spec = MeteorPath.generate(Random.new(9), 9100, "Ice", 0, "drift")
		inject(core, "a", spec)
		local t = windowTime(spec, 1) :: number
		local r = shoot(core, "a", spec.id, t, aimAt(L, spec, t))
		expect(r.outcome).toBe("capture")
		core:Settle("a")
		local readyAt = r.readyAt
		local spec2 = MeteorPath.generate(Random.new(10), 9101, "Ice", t, "drift")
		inject(core, "a", spec2)
		local ok1, code1 = core:BeginCharge("a", readyAt - 0.1)
		expect(ok1).toBe(false)
		expect(code1).toBe("COOLDOWN")
		expect(core:Fire("a", { targetId = 9101, fireTime = readyAt - 0.2, aim = Vector3.yAxis }, { now = readyAt - 0.2, canAfford = true }).code).toBe("COOLDOWN")
		local t3 = readyAt + 0.3
		expect(core:Fire("a", { targetId = 9101, fireTime = t3, aim = Vector3.yAxis }, { now = t3, canAfford = true }).code).toBe("NOT_CHARGED")
		core:BeginCharge("a", t3 + 0.1)
		expect(core:Fire("a", { targetId = 9101, fireTime = t3 + 0.4, aim = Vector3.yAxis }, { now = t3 + 0.4, ping = 0, canAfford = true }).code).toBe("CHARGE_SHORT")
		expect(s.charge).toBe(nil) -- consumed: a second release needs a new charge
		expect(core:Fire("a", { targetId = 9101, fireTime = t3 + 0.9, aim = Vector3.yAxis }, { now = t3 + 0.9, canAfford = true }).code).toBe("NOT_CHARGED")
		local tc = t3 + 1
		core:BeginCharge("a", tc)
		local tw = windowTime(spec2, tc + SHOT.MIN_CHARGE) :: number
		local r4 = core:Fire("a", { targetId = 9101, fireTime = tw, aim = aimAt(L, spec2, tw) }, { now = tw, ping = 0, canAfford = true })
		expect(r4.outcome).toBe("capture")
		expect(s.shots).toBe(2) -- six claims, two spent shots
	end)

	---------------------------------------------------------------- 10
	it("10 rapid click spam: 20 clicks/s never fires; optimal hold-release spam never beats the reload", function()
		local core = newCore(10)
		local s = start(core, "a", 1, 0)
		-- (a) click spam: press + release every 50 ms (no hold)
		for i = 1, 600 do
			local now = i * 0.05
			if i % 4 == 0 then
				core:Tick(now)
			end
			core:BeginCharge("a", now)
			local id = next(s.meteors)
			if id then
				core:Fire("a", { targetId = id, fireTime = now, aim = Vector3.yAxis }, { now = now, canAfford = true })
			end
		end
		expect(s.shots).toBe(0)
		-- (b) a cheater who holds just long enough under the MAX latency tolerance and re-presses at 20 Hz
		local c2 = newCore(11)
		local s2 = start(c2, "b", 2, 0)
		local spent, lastSpent, tooFast = 0, -math.huge, 0
		local chargeAt: number? = nil
		for i = 1, 1200 do -- 60 s
			local now = i * 0.05
			if i % 4 == 0 then
				c2:Tick(now)
			end
			if not chargeAt and (c2:BeginCharge("b", now)) then
				chargeAt = s2.charge
			end
			if chargeAt and now - chargeAt >= SHOT.MIN_CHARGE - SHOT.CHARGE_TOLERANCE_MAX then
				local target = nil
				for _, spec in s2.meteors do
					if MeteorPath.evaluate(spec, now) and not MeteorPath.isPhased(spec, now) then
						target = spec
						break
					end
				end
				if target then
					local r = c2:Fire("b", { targetId = target.id, fireTime = now, aim = aimAt(s2.layout, target, now) }, { now = now, ping = 5, canAfford = true })
					chargeAt = nil
					if r.ok then
						spent += 1
						if now - lastSpent < SHOT.COOLDOWN - 1e-6 then
							tooFast += 1
						end
						lastSpent = now
						c2:Settle("b")
					end
				end
			end
		end
		expect(tooFast).toBe(0)
		expect(spent >= 8).toBe(true) -- not vacuous
		expect(spent <= math.floor(60 / (SHOT.COOLDOWN + SHOT.MIN_CHARGE - SHOT.CHARGE_TOLERANCE_MAX)) + 1).toBe(true)
	end)

	---------------------------------------------------------------- 11
	it("11 remote spam: token buckets, payload checks, a flood of identical claims rewards once", function()
		for _, name in { "Harvest_Fire", "Harvest_Charge", "Harvest_Enter", "Harvest_Exit" } do
			local cfg = NetConfig.RATE_LIMITS[name]
			expect(cfg ~= nil).toBe(true)
			local clock = 0
			local rl = RemoteGuard.newRateLimiter(cfg.capacity, cfg.refillPerSecond, function()
				return clock
			end)
			local allowed = 0
			for i = 1, 200 do
				clock = i * 0.005
				if rl:Allow("p") then
					allowed += 1
				end
			end
			expect(allowed <= cfg.capacity + math.ceil(cfg.refillPerSecond)).toBe(true)
		end
		expect((RemoteGuard.checkPayload({ requestId = 1, targetId = 1, fireTime = 0 / 0 }))).toBe(false)
		expect((RemoteGuard.checkPayload({ requestId = 1, aimX = math.huge }))).toBe(false)
		local core = newCore(12)
		local s = start(core, "a", 1, 0)
		local spec = MeteorPath.generate(Random.new(12), 9200, "Magma", 0)
		inject(core, "a", spec)
		local t = windowTime(spec, 1) :: number
		core:BeginCharge("a", t - 0.6)
		local rewards = 0
		for _ = 1, 50 do
			local r = core:Fire("a", { targetId = spec.id, fireTime = t, aim = aimAt(s.layout, spec, t) }, { now = t + 0.01, canAfford = true })
			if r.ok and r.outcome == "capture" then
				rewards += 1
			end
		end
		expect(rewards).toBe(1)
		expect(s.shots).toBe(1)
	end)

	---------------------------------------------------------------- 12
	it("12 respawn during reload: death ends the session; reload and focus survive the respawn", function()
		local core = newCore(13)
		local s = start(core, "a", 1, 0)
		local L = s.layout
		local spec = MeteorPath.generate(Random.new(13), 9300, "Ice", 0, "drift")
		inject(core, "a", spec)
		local tb = badTime(spec, 1) :: number
		local miss = shoot(core, "a", spec.id, tb, aimAt(L, spec, tb))
		expect(miss.outcome).toBe("miss")
		local readyAt = miss.readyAt
		core:Stop("a", tb + 0.4) -- died -> EndSession -> dormant
		expect(core:Get("a")).toBe(nil)
		local s2 = core:Start("a", 1, tb + 1, { tutorial = false })
		expect(s2.resumed).toBe(true)
		expect(s2.missStacks).toBe(1)
		expect(s2.charge).toBe(nil)
		expect(core:ReadyAt("a")).toBe(readyAt)
		local ok, code = core:BeginCharge("a", tb + 1.2)
		expect(ok).toBe(false)
		expect(code).toBe("COOLDOWN")
		core:Stop("a") -- even a dropped session keeps the reload
		core:Start("a", 1, tb + 1.5, { tutorial = false })
		expect(select(2, core:BeginCharge("a", tb + 1.6))).toBe("COOLDOWN")
		expect((core:BeginCharge("a", readyAt + 0.01))).toBe(true)
	end)

	---------------------------------------------------------------- 13
	it("13 exit and reopen: same stream resumes (no re-rolls), exit/enter spam does not out-spawn play", function()
		local core = newCore(14)
		core:Start("a", 1, 0, { tutorial = false })
		for i = 1, 50 do
			core:Tick(i * 0.2)
		end
		local s = core:Get("a")
		local ids = {}
		for id in s.meteors do
			ids[id] = true
		end
		local nextSpawn = s.nextSpawnAt
		core:Stop("a", 10)
		local s2 = core:Start("a", 1, 10.5, { tutorial = false })
		expect(s2.resumed).toBe(true)
		for id in ids do
			expect(s2.meteors[id] ~= nil).toBe(true)
		end
		expect(s2.nextSpawnAt).toBe(nextSpawn)
		local calm, spam = newCore(15), newCore(15)
		calm:Start("a", 1, 0, { tutorial = false })
		spam:Start("a", 1, 0, { tutorial = false })
		for i = 1, 600 do -- 120 s
			local now = i * 0.2
			calm:Tick(now)
			spam:Tick(now)
			if i % 3 == 0 then
				spam:Stop("a", now)
				spam:Start("a", 1, now + 0.01, { tutorial = false })
			end
		end
		local calmIssued, spamIssued = calm.nextId - 1000, spam.nextId - 1000
		expect(spamIssued <= calmIssued * 1.15 + 3).toBe(true)
		-- after the dormant TTL a fresh stream starts, the reload is still known
		local c = newCore(16)
		local sc = start(c, "a", 1, 0)
		local spec = MeteorPath.generate(Random.new(16), 9400, "Ice", 0, "drift")
		inject(c, "a", spec)
		local t = windowTime(spec, 1) :: number
		local r = shoot(c, "a", spec.id, t, aimAt(sc.layout, spec, t))
		expect(r.outcome).toBe("capture")
		c:Stop("a", t + 0.1)
		c:Tick(t + 0.1 + HarvestConfig.SPAWN.DORMANT_TTL + 0.5)
		expect(c.dormant.a).toBe(nil)
	end)

	---------------------------------------------------------------- 14
	it("14 multiple players: 8 independent emitters, streams and claims", function()
		local core = newCore(17)
		for i = 1, 8 do
			core:Start("p" .. i, i, 0, { tutorial = false })
		end
		for k = 1, 60 do
			core:Tick(k * 0.2)
		end
		local now = 12
		local s1 = core:Get("p1")
		local target = nil
		for _, spec in s1.meteors do
			if MeteorPath.evaluate(spec, now) and not MeteorPath.isPhased(spec, now) then
				target = spec
				break
			end
		end
		expect(target ~= nil).toBe(true)
		local r = shoot(core, "p1", target.id, now, aimAt(s1.layout, target, now))
		expect(r.ok).toBe(true)
		for i = 2, 8 do
			expect((core:BeginCharge("p" .. i, now + 0.01))).toBe(true)
		end
		expect(select(2, core:BeginCharge("p1", now + 0.01))).toBe("COOLDOWN")
		local foreign = next(core:Get("p3").meteors)
		expect(core:Fire("p2", { targetId = foreign, fireTime = now + 0.6, aim = Vector3.yAxis }, { now = now + 0.6, canAfford = true }).code).toBe("UNKNOWN_TARGET")
		local owner = {}
		for i = 1, 8 do
			for id in core:Get("p" .. i).meteors do
				expect(owner[id]).toBe(nil)
				owner[id] = i
			end
		end
	end)

	---------------------------------------------------------------- 15
	it("15 duplicate claims: in-flight lock, replay after reload, unclaim -> exactly one more capture", function()
		local core = newCore(18)
		local s = start(core, "a", 1, 0)
		local L = s.layout
		local spec = MeteorPath.generate(Random.new(18), 9500, "Ice", 0, "drift")
		inject(core, "a", spec)
		local t = windowTime(spec, 1) :: number
		local r = shoot(core, "a", spec.id, t, aimAt(L, spec, t))
		expect(r.outcome).toBe("capture")
		expect(select(2, core:BeginCharge("a", t + 0.3))).toBe("SHOT_IN_FLIGHT")
		expect(core:Fire("a", { targetId = spec.id, fireTime = t + 0.3, aim = aimAt(L, spec, t) }, { now = t + 0.3, canAfford = true }).code).toBe("SHOT_IN_FLIGHT")
		core:Settle("a")
		local td = r.readyAt + 0.7
		expect(shoot(core, "a", spec.id, td, aimAt(L, spec, td)).code).toBe("ALREADY_CLAIMED")
		core:Unclaim("a", r.spec, r.cancelled)
		local tw = windowTime(spec, td + 0.6) :: number
		expect(shoot(core, "a", spec.id, tw, aimAt(L, spec, tw)).outcome).toBe("capture")
		core:Settle("a")
		local tz = core:ReadyAt("a") + 0.6
		expect(shoot(core, "a", spec.id, tz, aimAt(L, spec, math.min(tz, spec.t0 + spec.duration))).code).toBe("ALREADY_CLAIMED")
	end)

	---------------------------------------------------------------- 16
	it("16 expired targets: late claim = EXPIRED miss; pruned ids become unknown; Tick frees specs", function()
		local core = newCore(19)
		local s = start(core, "a", 1, 0)
		local spec = MeteorPath.generate(Random.new(19), 9600, "Ice", 0, "drift")
		core:_issue(s, spec)
		local late = spec.t0 + spec.duration + 0.4
		local r = shoot(core, "a", spec.id, late, Vector3.yAxis)
		expect(r.outcome).toBe("miss")
		expect(r.reason).toBe("EXPIRED")
		expect(math.abs(r.readyAt - (late + SHOT.MISS_COOLDOWN)) < 1e-9).toBe(true)
		local S = HarvestConfig.SPAWN
		core:Tick(spec.t0 + spec.duration + S.EXPIRE_GRACE + 0.1)
		expect(s.meteors[spec.id]).toBe(nil)
		local after = spec.t0 + spec.duration + S.EXPIRE_GRACE + S.ISSUED_RETENTION + 1
		core:Tick(after)
		expect(s.issued[spec.id]).toBe(nil)
		expect(shoot(core, "a", spec.id, after + 0.6, Vector3.yAxis).code).toBe("UNKNOWN_TARGET")
	end)

	---------------------------------------------------------------- 17
	it("17 invalid aim: zero, reversed, beyond the cone, aimed at a different meteor", function()
		expect(oneShot("Ice", 201, function()
			return Vector3.zero
		end).reason).toBe("MISS_AIM")
		expect(oneShot("Ice", 202, function(L, spec, t)
			return -aimAt(L, spec, t)
		end).reason).toBe("MISS_AIM")
		local function edge(extra: number)
			return function(L: any, spec: any, t: number): Vector3
				local dist = (L.toWorld(MeteorPath.evaluate(spec, t) :: Vector3) - L.origin).Magnitude
				return rotateOff(L, aimAt(L, spec, t), HarvestRules.allowedAngleDeg(spec, dist, 0, 0) + extra)
			end
		end
		expect(oneShot("Magma", 203, edge(0.5)).reason).toBe("MISS_AIM")
		expect(oneShot("Magma", 203, edge(-0.3)).outcome).toBe("capture")
		-- claiming meteor A while aiming at meteor B
		local core = newCore(204)
		local s = start(core, "a", 1, 0)
		local A = MeteorPath.generate(Random.new(1), 9701, "Ice", 0, "drift")
		local B = MeteorPath.generate(Random.new(2), 9702, "Ice", 0, "drift")
		inject(core, "a", A)
		inject(core, "a", B)
		local t = nil
		for i = 0, 1000 do
			local tt = 1 + i * 0.01
			if MeteorPath.evaluate(A, tt) and MeteorPath.evaluate(B, tt) and HarvestRules.timingQuality(A, tt, 0) then
				local ang = math.deg(math.acos(math.clamp(aimAt(s.layout, A, tt):Dot(aimAt(s.layout, B, tt)), -1, 1)))
				if ang > 20 then
					t = tt
					break
				end
			end
		end
		expect(t ~= nil).toBe(true)
		expect(shoot(core, "a", A.id, t :: number, aimAt(s.layout, B, t :: number)).reason).toBe("MISS_AIM")
	end)

	---------------------------------------------------------------- 18
	it("18 high latency: bounded fireTime rewind, bounded charge tolerance, exact verification for fast meteors", function()
		-- ping 0.6 s: a claim 0.65 s old still verifies against the authored path (Astral, the fastest)
		expect(oneShot("Astral", 301, exact, { lag = 0.65, ping = 0.6 }).outcome).toBe("capture")
		expect(oneShot("Astral", 302, exact, { lag = 0.8, ping = 0.6 }).code).toBe("BAD_TIME")
		expect(oneShot("Astral", 303, exact, { lag = 0.8, ping = 5 }).code).toBe("BAD_TIME") -- never more than MAX_LATENCY
		expect(oneShot("Astral", 304, exact, { lag = -(SHOT.MAX_CLOCK_LEAD + 0.05), ping = 0.1 }).code).toBe("BAD_TIME") -- claims from the future
		-- the charge tolerance is capped: huge ping cannot shorten the hold below MIN_CHARGE - CHARGE_TOLERANCE_MAX
		expect(oneShot("Ice", 305, exact, { hold = SHOT.MIN_CHARGE - SHOT.CHARGE_TOLERANCE_MAX - 0.01, ping = 3 }).code).toBe("CHARGE_SHORT")
		expect(oneShot("Ice", 306, exact, { hold = SHOT.MIN_CHARGE - SHOT.CHARGE_TOLERANCE_MAX + 0.01, ping = 3 }).outcome).toBe("capture")
		expect(oneShot("Ice", 307, exact, { hold = SHOT.MIN_CHARGE - SHOT.CHARGE_SLACK - 0.01, ping = 0 }).code).toBe("CHARGE_SHORT")
		expect(oneShot("Ice", 308, exact, { hold = SHOT.MIN_CHARGE - SHOT.CHARGE_SLACK + 0.01, ping = 0 }).outcome).toBe("capture")
	end)

	---------------------------------------------------------------- 19
	it("19 mobile / controller tolerance: assisted lock, locked shots verify for every variant, device claims ignored", function()
		local LOCK = HarvestConfig.LOCK
		expect(LOCK.TOUCH_RADIUS_MULT > 1 and LOCK.GAMEPAD_RADIUS_MULT > 1 and LOCK.MAGNET_RATE > 0).toBe(true)
		for i, kind in Registry.ORDER do
			-- a LOCKED shot aims at the target's true position at fireTime (client contract)
			expect(oneShot(kind, 400 + i, exact).outcome).toBe("capture")
			-- an unlocked thumb aim that is 0.3 deg inside the allowed cone still verifies
			local r = oneShot(kind, 450 + i, function(L, spec, t)
				local dist = (L.toWorld(MeteorPath.evaluate(spec, t) :: Vector3) - L.origin).Magnitude
				return rotateOff(L, aimAt(L, spec, t), HarvestRules.allowedAngleDeg(spec, dist, 0, 0) - 0.3)
			end)
			expect(r.outcome).toBe("capture")
		end
		-- forged device / cone fields in a claim change nothing
		local core = newCore(499)
		local s = start(core, "a", 1, 0)
		local spec = MeteorPath.generate(Random.new(9), 9800, "Ice", 0, "drift")
		inject(core, "a", spec)
		local t = windowTime(spec, 1) :: number
		core:BeginCharge("a", t - 0.6)
		local claim: any = { targetId = spec.id, fireTime = t, aim = rotateOff(s.layout, aimAt(s.layout, spec, t), 30), device = "touch", coneDeg = 90 }
		expect(core:Fire("a", claim, { now = t, canAfford = true }).reason).toBe("MISS_AIM")
	end)

	---------------------------------------------------------------- 20
	it("20 memory cleanup + bounded load: 8 harvesters x 10 simulated minutes; leaving frees everything", function()
		local core = newCore(20)
		for i = 1, 8 do
			core:Start("p" .. i, i, 0, { tutorial = false })
		end
		local maxMeteors, maxIssued, maxActive = 0, 0, 0
		for k = 1, 3000 do -- 600 s at the server's 5 Hz tick
			local now = k * 0.2
			core:Tick(now)
			if k % 5 == 0 then
				for i = 1, 8 do
					local key = "p" .. i
					local s = core:Get(key)
					if s and now - 0.55 >= core:ReadyAt(key) then
						core:BeginCharge(key, now - 0.55)
						for id, spec in s.meteors do
							if MeteorPath.evaluate(spec, now) then
								core:Fire(key, { targetId = id, fireTime = now, aim = aimAt(s.layout, spec, now) }, { now = now, canAfford = true })
								core:Settle(key)
								break
							end
						end
					end
					if s then
						maxActive = math.max(maxActive, core:ActiveCount(s, now))
					end
				end
			end
			if k % 25 == 0 then
				local f = core:Footprint()
				maxMeteors = math.max(maxMeteors, f.meteors)
				maxIssued = math.max(maxIssued, f.issued)
			end
		end
		expect(core:SessionCount()).toBe(8)
		-- a split adds FRAGMENTS - 1 meteors after it breaks: the hard visual bound
		expect(maxActive <= HarvestConfig.SPAWN.MAX_ACTIVE + HarvestConfig.SPLIT.FRAGMENTS - 1).toBe(true)
		expect(maxMeteors <= 8 * 8).toBe(true)
		expect(maxIssued <= 8 * 60).toBe(true)
		for i = 1, 8 do
			core:Stop("p" .. i, 600)
		end
		expect(core:Footprint().dormant).toBe(8)
		core:Tick(600 + HarvestConfig.SPAWN.DORMANT_TTL + 1)
		expect(core:Footprint().dormant).toBe(0)
		core:Tick(600 + 200)
		expect(core:Footprint().ready).toBe(0)
		core:Start("x", 1, 900, { tutorial = false })
		core:Tick(901)
		core:Forget("x")
		local f = core:Footprint()
		expect(f.sessions + f.dormant + f.ready + f.meteors + f.issued).toBe(0)
	end)
end
