--!strict
-- Planet DNA & Evolution Engine specs (Developer B). Pure modules + simulator; no live data stores.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local Shared = RS.PF_Shared
	local PlanetConfig = ctx.require(Shared.Config.PlanetConfig)
	local EvolutionConfig = ctx.require(Shared.Config.EvolutionConfig)
	local ItemCatalog = ctx.require(Shared.Config.ItemCatalog)
	local Registry = ctx.require(Shared.Evolution.ReactionRegistry)
	local Formations = ctx.require(Shared.Evolution.FormationRegistry)
	local Rules = ctx.require(Shared.Evolution.EvolutionRules)
	local Engine = ctx.require(SSS.PF_Server.Evolution.ReactionEngine)
	local Validator = ctx.require(SSS.PF_Server.Evolution.PlanetStateValidator)
	local Sim = ctx.require(SSS.PF_Server.Evolution.PlanetProgressionSimulator)
	local Schema = ctx.require(SSS.PF_Server.Data.ProfileSchema)
	local Migrations = ctx.require(SSS.PF_Server.Data.Migrations)
	local TransactionCore = ctx.require(SSS.PF_Server.Data.TransactionCore)
	local ProfileStore = ctx.require(SSS.PF_Server.Data.ProfileStore)
	local MockDataStore = ctx.require(SSS.PF_Server.Data.MockDataStore)
	local HttpService = game:GetService("HttpService")

	local function capFn(section: string, id: string): number
		return Schema.capFor(section, id)
	end
	local function fresh(): any
		return Schema.default(1000, 4242)
	end
	local function rich(p: any)
		for id in ItemCatalog.MATERIALS do
			p.materials[id] = math.min(500, Schema.capFor("materials", id))
		end
		p.currencies.Credits = 100000
	end
	-- full server transaction path minus the services: costs+rewards atomically, then the planet half
	local function execute(p: any, id: string, now: number?): (boolean, string, any)
		local ok, code, plan = Engine.planReaction(p, id)
		if not ok then
			return false, code, plan
		end
		local okTx, txCode = TransactionCore.apply(p, plan.tx, capFn, "clamp")
		if not okTx then
			return false, txCode, nil
		end
		Engine.applyReaction(p, plan, now or 2000)
		local prog = Engine.evaluateProgress(p, now or 2000)
		return true, "OK", { plan = plan, prog = prog }
	end
	local function commit(p: any, b: string, confirm: boolean?): (boolean, string, any)
		local ok, code, plan = Engine.planBranch(p, b, if confirm == nil then true else confirm)
		if not ok then
			return false, code, plan
		end
		local okTx, txCode = TransactionCore.apply(p, plan.tx, capFn, "clamp")
		if not okTx then
			return false, txCode, nil
		end
		Engine.applyBranch(p, plan, 3000)
		return true, "OK", Engine.evaluateProgress(p, 3000)
	end
	local function must(p: any, id: string): any
		local ok, code, res = execute(p, id)
		if not ok then
			local u = {}
			for _, x in (res and res.unmet) or {} do
				table.insert(u, x.text)
			end
			error(string.format("%s rejected: %s %s (dna %s)", id, code, table.concat(u, "; "), HttpService:JSONEncode(p.planet.dna)), 2)
		end
		return res
	end
	local function deepEq(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in a do
			if not deepEq(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end
	local function snapshotOf(p: any): string
		return HttpService:JSONEncode({ p.materials, p.planet, p.reactions, p.currencies })
	end
	-- makes every requirement of `def` true (discoveries, branch, DNA, formations) without discovering `def`
	local function prepareFor(p: any, id: string)
		local def = Registry.DEFS[id]
		local req = def.requires
		for _, other in Registry.ORDER do
			if other ~= id and Registry.DEFS[other].major then
				p.reactions[other] = { n = 1, d = 1 }
			end
		end
		if type(req.branch) == "string" then
			p.planet.branch = req.branch
		elseif req.stage and (req.stage.min or 0) >= 3 then
			p.planet.branch = if def.branch and PlanetConfig.isSelectableBranch(def.branch) then def.branch else "Living"
		end
		for fid, n in req.formations or {} do
			p.planet.formations[fid] = { n = n, t = 1 }
		end
		for param, r in req.dna or {} do
			local v = p.planet.dna[param]
			if r.min and v < r.min then
				v = r.min
			end
			if r.max and v > r.max then
				v = r.max
			end
			p.planet.dna[param] = v
		end
		-- also make sure the DNA effect isn't fully clamped away and formation room exists
		p.planet.stage = Rules.computeStage(Rules.viewFromProfile(p))
	end

	---------------------------------------------------------------- A. DNA
	it("A: new planet is barren with the configured starting DNA", function()
		local p = fresh()
		expect(p.planet.dna.Temperature).toBe(40)
		expect(p.planet.dna.Water).toBe(0)
		expect(p.planet.dna.Life).toBe(0)
		expect(p.planet.dna.CosmicEnergy).toBe(0)
		expect(p.planet.stage).toBe(0)
		expect(p.planet.branch).toBe("None")
		expect(next(p.planet.formations)).toBe(nil)
		expect(p.planet.seed).toBe(Validator.seedFor(4242))
		expect(p.planet.rev).toBe(0)
	end)

	it("A: DNA is clamped and malformed values are rejected", function()
		expect(PlanetConfig.clampDna("Water", 250)).toBe(100)
		expect(PlanetConfig.clampDna("Water", -5)).toBe(0)
		expect(PlanetConfig.clampDna("Water", 0 / 0)).toBe(nil)
		expect(PlanetConfig.clampDna("Water", math.huge)).toBe(nil)
		expect(PlanetConfig.clampDna("Water", "50")).toBe(nil)
		expect(PlanetConfig.clampDna("Gravity", 5)).toBe(nil)
		local after = Rules.dnaAfter({ Temperature = 98, Water = 3, Life = 0, CosmicEnergy = 0 }, { Temperature = 12, Water = -8 })
		expect(after.Temperature).toBe(100)
		expect(after.Water).toBe(0)
		local p = Validator.reconcilePlanet({ dna = { Temperature = 1e9, Water = 0 / 0, Life = "x", CosmicEnergy = -9, Weird = math.huge } }, 1, 7)
		expect(p.dna.Temperature).toBe(100)
		expect(p.dna.Water).toBe(0)
		expect(p.dna.Life).toBe(0)
		expect(p.dna.CosmicEnergy).toBe(0)
		expect(p.dna.Weird).toBe(nil)
	end)

	---------------------------------------------------------------- B. reactions
	it("B: registry is valid, has 16 core reactions and no impossible/unreachable content", function()
		local errs = Sim.validateRegistry()
		expect(#errs).toBe(0)
		for i = 1, 16 do
			expect(Registry.DEFS[string.format("R%02d", i)] ~= nil).toBe(true)
		end
		expect(#Registry.ORDER >= 16).toBe(true)
	end)

	it("B: static softlock guard rejects a one-way DNA parameter", function()
		local saved = Registry.DEFS.R30.repeats
		Registry.DEFS.R30.repeats = { mode = "once" }
		local ok, errs = pcall(Sim.validateRegistry)
		Registry.DEFS.R30.repeats = saved
		expect(ok).toBe(true)
		local found = false
		for _, e in errs do
			if string.find(e, "softlock", 1, true) and string.find(e, "CosmicEnergy", 1, true) then
				found = true
			end
		end
		expect(found).toBe(true)
		expect(#Sim.validateRegistry()).toBe(0)
	end)

	it("B: EVERY reaction executes with exact costs, DNA changes, formations and Codex entry", function()
		for _, id in Registry.ORDER do
			local p = fresh()
			rich(p)
			prepareFor(p, id)
			local def = Registry.DEFS[id]
			local before = table.clone(p.materials)
			local dnaBefore = table.clone(p.planet.dna)
			local credits = p.currencies.Credits
			local ok, code, res = execute(p, id)
			if not ok then
				error(id .. " failed: " .. code .. " " .. HttpService:JSONEncode(res and res.unmet or {}))
			end
			for mid, n in def.cost.materials do
				local reward = def.discoveryReward and def.discoveryReward.materials and def.discoveryReward.materials[mid] or 0
				expect(p.materials[mid]).toBe(before[mid] - n + reward)
			end
			for _, param in PlanetConfig.DNA_ORDER do
				local expected = PlanetConfig.clampDna(param, dnaBefore[param] + ((def.effects.dna or {})[param] or 0))
				expect(p.planet.dna[param]).toBe(expected)
			end
			for fid, add in def.effects.formations or {} do
				expect(p.planet.formations[fid] ~= nil and p.planet.formations[fid].n >= math.min(add, Formations.DEFS[fid].maxCount)).toBe(true)
			end
			expect(p.reactions[id].n).toBe(1)
			expect(p.reactions[id].d ~= nil).toBe(true)
			expect(p.currencies.Credits).toBe(credits + (def.discoveryReward and def.discoveryReward.credits or 0))
			expect(p.planet.rev).toBe(1)
		end
	end)

	it("B: rejections never change state (materials, conditions, unknown, exclusive, limit, no-effect)", function()
		local p = fresh()
		p.materials.IceMatter = 2
		local s = snapshotOf(p)
		local ok, code = execute(p, "R01")
		expect(ok).toBe(false)
		expect(code).toBe("INSUFFICIENT_MATERIALS")
		expect(snapshotOf(p)).toBe(s)
		local _, code2 = execute(p, "R04") -- needs R03 + Temperature 55
		expect(code2).toBe("REQUIREMENTS_NOT_MET")
		local _, code3 = execute(p, "R99")
		expect(code3).toBe("UNKNOWN_REACTION")
		local _, code3b = execute(p, 42 :: any)
		expect(code3b).toBe("UNKNOWN_REACTION")
		expect(snapshotOf(p)).toBe(s)
		rich(p)
		expect((execute(p, "R01"))).toBe(true)
		local s2 = snapshotOf(p)
		local _, code4 = execute(p, "R01")
		expect(code4).toBe("ALREADY_COMPLETED")
		expect(snapshotOf(p)).toBe(s2)
		for _ = 1, 3 do
			execute(p, "R05")
		end
		local _, code5 = execute(p, "R05")
		expect(code5).toBe("MAX_COMPLETIONS")
		expect(p.planet.formations.CrystalCluster.n).toBe(3)
		-- tuning at the clamp limit would only burn materials -> refused
		must(p, "R03")
		must(p, "R18")
		p.planet.dna.Temperature = 100
		local s3 = snapshotOf(p)
		local _, code6 = execute(p, "R18")
		expect(code6).toBe("NO_EFFECT")
		expect(snapshotOf(p)).toBe(s3)
	end)

	---------------------------------------------------------------- C. evolution
	it("C: stages 0->4 are reached by rules, not by resources; milestones fire once", function()
		local p = fresh()
		rich(p)
		p.materials.IceMatter = 5000 -- a pile of one resource never advances a stage
		expect(Engine.evaluateProgress(p, 1).stageAfter).toBe(0)
		execute(p, "R01")
		local ok, _, r = execute(p, "R03")
		expect(ok).toBe(true)
		expect(r.prog.stageAfter).toBe(1)
		expect(#r.prog.newStages).toBe(1)
		must(p, "R02")
		must(p, "R05")
		local r2 = must(p, "R06")
		expect(r2.prog.stageAfter).toBe(2)
		-- stage 3 only through a confirmed commit
		for _ = 1, 4 do
			must(p, "R18")
		end
		must(p, "R04")
		expect(p.planet.stage).toBe(2)
		local okNo, codeNo = commit(p, "Volcanic", false)
		expect(okNo).toBe(false)
		expect(codeNo).toBe("NOT_CONFIRMED")
		local okC, _, prog = commit(p, "Volcanic")
		expect(okC).toBe(true)
		expect(prog.stageAfter).toBe(3)
		expect(p.planet.formations.BasaltSpires.n).toBe(1)
		-- capstone chain
		p.materials.CosmicCatalyst = 20
		for _, id in { "R15", "R26", "R27", "R13", "R07" } do
			must(p, id)
		end
		local view = Rules.viewFromProfile(p)
		expect(Rules.discoveredCount(view) >= 11).toBe(true)
		expect(p.planet.stage).toBe(4)
		expect(p.planet.stageAt.s4 ~= nil).toBe(true)
		-- re-evaluating never re-grants milestones
		local again = Engine.evaluateProgress(p, 99)
		expect(#again.newStages).toBe(0)
		expect(#again.rewards).toBe(0)
	end)

	it("C: re-specialization is fair: fee + target cost, Codex kept, landmarks dormant, switch back restores", function()
		local p = fresh()
		rich(p)
		p.materials.CosmicCatalyst = 30
		for _, id in { "R01", "R03", "R02", "R05", "R06", "R18", "R18", "R18", "R04", "R15", "R13", "R07" } do
			must(p, id)
		end
		expect((commit(p, "Volcanic"))).toBe(true)
		must(p, "R26")
		must(p, "R18")
		must(p, "R27")
		expect(p.planet.stage).toBe(4)
		local codexBefore = HttpService:JSONEncode(p.reactions)
		local credits = p.currencies.Credits
		local plasma, crystal = p.materials.PlasmaMatter, p.materials.CrystalFragments
		must(p, "R06")
		must(p, "R06")
		plasma = p.materials.PlasmaMatter
		local ok, code, prog = commit(p, "Crystal")
		expect(ok).toBe(true)
		expect(p.currencies.Credits).toBe(credits - (EvolutionConfig.BRANCH_RULES.Crystal.cost.credits or 0) - EvolutionConfig.RESPEC.credits)
		expect(p.materials.PlasmaMatter).toBe(plasma - EvolutionConfig.BRANCH_RULES.Crystal.cost.materials.PlasmaMatter)
		expect(p.materials.CrystalFragments).toBe(crystal - EvolutionConfig.BRANCH_RULES.Crystal.cost.materials.CrystalFragments)
		expect(prog.stageAfter).toBe(3) -- Crystal capstone not owned yet
		expect(p.planet.branchLog.respecs).toBe(1)
		local view = Rules.viewFromProfile(p)
		expect(Formations.isActive("EternalCore", view.branch)).toBe(false)
		expect(Formations.isActive("VolcanicMountain", view.branch)).toBe(true) -- secondary stays
		expect(p.planet.formations.EternalCore.n).toBe(1) -- kept, just dormant
		for id, rec in HttpService:JSONDecode(codexBefore) do
			expect(p.reactions[id] ~= nil and p.reactions[id].d == rec.d).toBe(true)
		end
		local okBack, _, progBack = commit(p, "Volcanic")
		expect(okBack).toBe(true)
		expect(progBack.stageAfter).toBe(4) -- capstone already owned: restored, no new milestone reward
		expect(#progBack.newStages).toBe(0)
		local _, codeSame = commit(p, "Volcanic")
		expect(codeSame).toBe("SAME_BRANCH")
		local _, codeFuture = commit(p, "Astral")
		expect(codeFuture).toBe("BRANCH_UNAVAILABLE")
		local _, codeUnknown = commit(p, "Hacker")
		expect(codeUnknown).toBe("UNKNOWN_BRANCH")
		local _ = code
	end)

	it("C: all four branches reach Advanced World in the simulator (timing bands)", function()
		for _, b in { "Living", "Frozen", "Volcanic", "Crystal" } do
			local r = Sim.run(b)
			if r.stuck then
				error(b .. " stuck: " .. table.concat(r.events, " | ", math.max(1, #r.events - 6)))
			end
			expect(r.firstTransformationAt <= 3).toBe(true)
			expect(r.stage2At <= 10).toBe(true)
			expect(r.branchAt >= 8 and r.branchAt <= 25).toBe(true)
			expect(r.stage4At >= 15).toBe(true) -- not trivially fast
		end
	end)

	it("C: no permanent softlock: from random legal histories every branch is still reachable", function()
		for seed = 1, 60 do -- includes the histories that exposed the R20 one-way Cosmic Energy softlock
			local p = Sim.fuzz(seed * 7919, 15 + seed % 35)
			local target = ({ "Living", "Frozen", "Volcanic", "Crystal" })[(seed % 4) + 1]
			local r = Sim.runFrom(p, target, { allowRespec = true, maxMinutes = 300 })
			if r.stuck then
				error(string.format("seed %d -> %s stuck (branch %s stage %d) %s", seed, target, r.branch, r.finalStage, table.concat(r.events, " | ", math.max(1, #r.events - 5))))
			end
		end
	end)

	---------------------------------------------------------------- D. persistence
	it("D: v1 profile migrates to v2 safely (legacy kept, stage recomputed, formations converted)", function()
		local v1 = { schemaVersion = 1, level = 5, currencies = { Credits = 900 }, materials = { IceMatter = 12 },
			planet = { dna = { Temperature = 20, Hydrosphere = 45, Atmosphere = 10, Tectonics = 30, Luminosity = 70 }, branch = "Volcanic", stage = 5, formations = { CrystalSpires = 1234 } } }
		local ok, migrated = Migrations.run(v1, Schema.CURRENT_VERSION)
		expect(ok).toBe(true)
		local p = Schema.reconcile(migrated, 5000, 77)
		expect(p.schemaVersion).toBe(2)
		expect(p.planet.dna.Temperature).toBe(46)
		expect(p.planet.dna.Water).toBe(25)
		expect(p.planet.dna.CosmicEnergy).toBe(20)
		expect(p.planet.branch).toBe("None")
		expect(p.planet.stage).toBe(0)
		expect(p.planet.formations.CrystalSpires.n).toBe(1) -- retired id kept, not rendered
		expect(p.planet.legacy.branch).toBe("Volcanic")
		expect(p.materials.IceMatter).toBe(12)
		expect(p.currencies.Credits).toBe(900)
		expect(type(p.reactions)).toBe("table")
	end)

	it("D: missing / malformed optional fields are repaired without losing valid data", function()
		local p = Schema.reconcile({ schemaVersion = 2, planet = { dna = { Water = 33 }, formations = { ShallowOcean = { n = 99 }, Bad = "x", ["$$"] = 1 }, cosmetics = { Atmosphere = "Atmosphere_Ember" } },
			reactions = { R01 = { n = 2, d = 10 }, R02 = { n = 1 }, R03 = "junk" }, cosmetics = {} }, 50, 9)
		expect(p.planet.dna.Water).toBe(33)
		expect(p.planet.formations.ShallowOcean.n).toBe(Formations.DEFS.ShallowOcean.maxCount)
		expect(p.planet.formations.Bad).toBe(nil)
		expect(p.planet.cosmetics.Atmosphere).toBe(nil) -- not owned -> unequipped
		expect(p.reactions.R01.n).toBe(2)
		expect(p.reactions.R02.d).toBe(50) -- completed but no timestamp -> repaired
		expect(p.reactions.R03).toBe(nil)
	end)

	it("D: evolution state round-trips through the session-locked store (returning player)", function()
		local mock = MockDataStore.new()
		local clk = { t = 1000 }
		local function store()
			return ProfileStore.new({ backend = mock, keyPrefix = "evo_", clock = function() return clk.t end, config = { LOAD_LOCK_RETRIES = 1, LOAD_LOCK_RETRY_DELAY = 0, RELEASE_RETRY_DELAY = 0 }, retryOpts = { retries = 1, baseDelay = 0, waitForBudget = false }, jobId = "T" })
		end
		local s = store()
		local _, prof = s:Load(555)
		rich(prof.data)
		for _, id in { "R01", "R03", "R02", "R05", "R06" } do
			execute(prof.data, id)
		end
		local planetBefore = HttpService:JSONEncode(prof.data.planet)
		local codexBefore = HttpService:JSONEncode(prof.data.reactions)
		expect((s:Release(prof))).toBe(true)
		clk.t = 2000
		local ok, again = store():Load(555)
		expect(ok).toBe(true)
		expect(again.isNew).toBe(false)
		expect(again.data.planet.stage).toBe(2)
		expect(deepEq(again.data.reactions, HttpService:JSONDecode(codexBefore))).toBe(true)
		expect(again.data.planet.seed).toBe(Validator.seedFor(555))
		expect(again.data.planet.rev).toBe(HttpService:JSONDecode(planetBefore).rev)
		expect(deepEq(again.data.planet.formations, HttpService:JSONDecode(planetBefore).formations)).toBe(true)
		expect(deepEq(again.data.planet.dna, HttpService:JSONDecode(planetBefore).dna)).toBe(true)
	end)

	---------------------------------------------------------------- E/F. duplication + isolation
	it("E: discovery rewards are granted once; repeated completions don't re-grant", function()
		local p = fresh()
		rich(p)
		execute(p, "R01")
		execute(p, "R02")
		local catalyst = p.materials.CosmicCatalyst
		local credits = p.currencies.Credits
		local ok, _, r = execute(p, "R02") -- limited 2: second completion
		expect(ok).toBe(true)
		expect(r.plan.firstDiscovery).toBe(false)
		expect(p.materials.CosmicCatalyst).toBe(catalyst)
		expect(p.currencies.Credits).toBe(credits)
		expect(p.reactions.R02.n).toBe(2)
	end)

	it("F: two players' planets are fully independent", function()
		local a, b = Schema.default(1, 1), Schema.default(1, 2)
		rich(a)
		rich(b)
		expect(a.planet.seed ~= b.planet.seed).toBe(true)
		local bBefore = snapshotOf(b)
		for _, id in { "R01", "R03", "R05", "R06", "R02" } do
			execute(a, id)
		end
		expect(snapshotOf(b)).toBe(bBefore)
		expect(a.planet.stage).toBe(2)
		expect(b.planet.stage).toBe(0)
	end)

	---------------------------------------------------------------- G. visual contract
	it("G: public formation map is accepted by Developer A's PlanetVisualContract; ids are registry ids", function()
		local Contract = ctx.require(Shared.Planet.PlanetVisualContract)
		local p = fresh()
		rich(p)
		for _, id in { "R01", "R03", "R05", "R05", "R06" } do
			execute(p, id)
		end
		local map = {}
		for fid, rec in p.planet.formations do
			map[fid] = rec.n
		end
		local state = Contract.normalize(1, { ownerUserId = 42, ownerName = "x", branch = p.planet.branch, stage = p.planet.stage, dna = p.planet.dna, formations = map, revision = p.planet.rev })
		expect(state.formations.CrystalCluster).toBe(2)
		expect(state.formations.IceImpact).toBe(1)
		expect(state.stage).toBe(p.planet.stage)
		expect(state.dna.Temperature).toBe(p.planet.dna.Temperature)
		for fid in map do
			expect(Formations.DEFS[fid] ~= nil).toBe(true)
		end
	end)

	---------------------------------------------------------------- harvest integration
	it("G: harvest target types follow the planet (Spore needs Water 20, Comet needs Stage 2, branch weights)", function()
		local HarvestRules = ctx.require(Shared.Harvest.HarvestRules)
		local HarvestConfig = ctx.require(Shared.Config.HarvestConfig)
		local Core = ctx.require(SSS.PF_Server.Harvest.HarvestSessionCore)
		local p = fresh()
		local c0 = HarvestRules.worldContext(Rules.viewFromProfile(p))
		expect(c0.allowed.Ice).toBe(true)
		expect(c0.allowed.Crystal).toBe(true)
		expect(c0.allowed.Spore).toBe(false)
		expect(c0.allowed.Comet).toBe(false)
		p.planet.dna.Water = 20
		expect(HarvestRules.worldContext(Rules.viewFromProfile(p)).allowed.Spore).toBe(true)
		p.planet.stage = 2
		local c2 = HarvestRules.worldContext(Rules.viewFromProfile(p))
		expect(c2.allowed.Comet).toBe(true)
		-- the live session core only spawns allowed kinds
		local core = Core.new({ seed = 7 })
		local sess = core:Start("k", 1, 0, { worldContext = c0 })
		local w0 = core:Weights(sess)
		expect(w0.Spore).toBe(nil)
		expect(w0.Comet).toBe(nil)
		expect((w0.Crystal or 0) > 0).toBe(true)
		local kinds = {}
		for n = 1, 300 do
			local met = core:_spawnNormal(sess, n)
			if met then
				kinds[met.kind] = true
			end
		end
		expect(kinds.Spore).toBe(nil)
		expect(kinds.Comet).toBe(nil)
		expect(kinds.Ice == true and kinds.Crystal == true).toBe(true) -- not vacuous: allowed kinds did spawn
		-- planet changes mid-session -> new kinds appear without restarting
		p.planet.branch = "Volcanic"
		core:SetWorldContext("k", HarvestRules.worldContext(Rules.viewFromProfile(p)))
		local w2 = core:Weights(sess)
		expect((w2.Comet or 0) > 0).toBe(true)
		expect((w2.Bio or 0) > 0).toBe(true) -- Meteor V2: the Spore Cloud is the Bio variant (alias "Spore")
		local mult = HarvestConfig.BRANCH_WEIGHT_MULTIPLIERS.Volcanic
		if mult and mult.Magma then
			expect(w2.Magma).toBe(HarvestConfig.TARGET_TYPES.Magma.weight * mult.Magma)
		end
	end)

	---------------------------------------------------------------- H. performance
	it("H: previews for all reactions + stage + 4 branches stay cheap", function()
		local p = fresh()
		rich(p)
		local view = Rules.viewFromProfile(p)
		local t0 = os.clock()
		for _ = 1, 100 do
			for _, id in Registry.ORDER do
				Rules.reactionStatus(view, id)
			end
			Rules.computeStage(view)
			for b in EvolutionConfig.BRANCH_RULES do
				Rules.branchStatus(view, b)
			end
		end
		local perRefreshMs = (os.clock() - t0) * 1000 / 100
		expect(perRefreshMs < 8).toBe(true)
	end)
end
