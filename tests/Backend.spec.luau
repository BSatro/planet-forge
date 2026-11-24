--!strict
-- Backend specs (Developer B): schema/migrations, slots, transactions, formulas, RemoteGuard, environment.
-- Pure modules only; the session-lock flow is in ProfileStore.spec.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local Data = SSS.PF_Server.Data
	local Schema = ctx.require(Data.ProfileSchema)
	local Migrations = ctx.require(Data.Migrations)
	local SlotAllocator = ctx.require(Data.SlotAllocator)
	local TransactionCore = ctx.require(Data.TransactionCore)
	local DataEnvironment = ctx.require(Data.DataEnvironment)
	local RemoteGuard = ctx.require(SSS.PF_Server.Net.RemoteGuard)
	local Formulas = ctx.require(RS.PF_Shared.Economy.EconomyFormulas)
	local EconomyConfig = require(RS.PF_Shared.Config.EconomyConfig)
	local PlanetConfig = require(RS.PF_Shared.Config.PlanetConfig)
	local ItemCatalog = require(RS.PF_Shared.Config.ItemCatalog)
	local HttpService = game:GetService("HttpService")
	local NOW = 1_700_000_000

	---------------------------------------------------------------- schema
	it("default profile: starting kit, all sections, JSON-serializable", function()
		local p = Schema.default(NOW)
		expect(p.schemaVersion).toBe(Schema.CURRENT_VERSION)
		expect(p.level).toBe(1)
		expect(p.currencies.Credits).toBe(EconomyConfig.STARTING_BALANCES.currencies.Credits)
		expect(p.currencies.CosmicEnergy).toBe(EconomyConfig.STARTING_BALANCES.currencies.CosmicEnergy)
		for id in ItemCatalog.MATERIALS do
			expect(type(p.materials[id])).toBe("number")
		end
		for id, def in PlanetConfig.DNA_PARAMS do
			expect(p.planet.dna[id]).toBe(def.default)
		end
		expect(p.planet.branch).toBe(PlanetConfig.DEFAULT_BRANCH)
		expect(type(p.expeditions.history)).toBe("table")
		expect(type(p.cosmetics)).toBe("table")
		local back = HttpService:JSONDecode(HttpService:JSONEncode(p))
		expect(back.currencies.Credits).toBe(p.currencies.Credits)
	end)

	it("reconcile: old save missing new material/param gets 0/default, unknown ids are kept", function()
		local old = { schemaVersion = 2, level = 4, currencies = { Credits = 500 }, materials = { IceMatter = 7, LegacyDust = 3 }, planet = { dna = { Temperature = 40, FutureParam = 9 }, branch = "FutureBranch" } }
		local p = Schema.reconcile(old, NOW)
		expect(p.level).toBe(4)
		expect(p.materials.IceMatter).toBe(7)
		expect(p.materials.MagmaMatter).toBe(0)
		expect(p.materials.LegacyDust).toBe(3)
		expect(p.planet.dna.Temperature).toBe(40)
		expect(p.planet.dna.Water).toBe(PlanetConfig.DNA_PARAMS.Water.default)
		expect(p.materials.CrystalFragments).toBe(0)
		expect(p.planet.dna.FutureParam).toBe(9)
		-- an unknown branch is never trusted: unspecialized, the raw value is kept for audit
		expect(p.planet.branch).toBe(PlanetConfig.DEFAULT_BRANCH)
		expect(p.planet.legacy.invalidBranch).toBe("FutureBranch")
		expect(p.currencies.CosmicEnergy).toBe(0)
	end)

	it("reconcile: NaN / inf / negative / huge / wrong types are repaired", function()
		local nan = 0 / 0
		local p = Schema.reconcile({
			level = 1e300, -- finite but huge -> clamped
			xp = nan,
			loginCount = math.huge, -- non-finite -> corrupt -> fallback
			currencies = { Credits = 1e300, CosmicEnergy = -50 },
			materials = { IceMatter = "lots", MagmaMatter = 12.9, ["bad key!"] = 5 },
			catalysts = { FrostSeed = 1e9 },
			planet = { dna = { Temperature = 1e9, Water = nan, Life = -40 }, stage = 99, branch = 42, rev = "x", seed = 0 / 0 },
			upgrades = { HarvestYield = 999 },
			discoveries = { FirstHarvest = true, ["$$"] = true },
			stats = "oops",
		}, NOW)
		expect(p.level).toBe(EconomyConfig.LEVEL.MAX_LEVEL)
		expect(p.xp).toBe(0)
		expect(p.loginCount).toBe(0)
		expect(p.currencies.Credits).toBe(EconomyConfig.BALANCE_CAPS.currencies.Credits)
		expect(p.currencies.CosmicEnergy).toBe(0)
		expect(p.materials.IceMatter).toBe(0)
		expect(p.materials.MagmaMatter).toBe(12)
		expect(p.materials["bad key!"]).toBe(nil)
		expect(p.catalysts.FrostSeed).toBe(ItemCatalog.CATALYSTS.FrostSeed.maxStack)
		expect(p.planet.dna.Temperature).toBe(PlanetConfig.DNA_PARAMS.Temperature.max)
		expect(p.planet.dna.Water).toBe(PlanetConfig.DNA_PARAMS.Water.default)
		expect(p.planet.dna.Life).toBe(0)
		expect(p.planet.stage).toBe(0) -- recomputed from the Codex, never trusted
		expect(p.planet.rev).toBe(0)
		expect(p.planet.seed > 0).toBe(true)
		expect(p.planet.branch).toBe(PlanetConfig.DEFAULT_BRANCH)
		expect(p.upgrades.HarvestYield).toBe(EconomyConfig.UPGRADES.HarvestYield.maxLevel)
		expect(p.discoveries.FirstHarvest).toBe(NOW)
		expect(p.discoveries["$$"]).toBe(nil)
		expect(p.stats.harvests).toBe(0)
	end)

	it("migrations: unversioned save upgrades to current", function()
		local ok, p = Migrations.run({ level = 3 }, Schema.CURRENT_VERSION)
		expect(ok).toBe(true)
		expect(p.schemaVersion).toBe(Schema.CURRENT_VERSION)
		expect(p.level).toBe(3)
	end)

	it("migrations: chained custom steps, future version refused, missing step and bad data reported", function()
		local steps = {
			[1] = function(p)
				p.materials = p.materials or {}
				p.materials.NewIce = (p.materials.OldIce or 0)
				p.materials.OldIce = nil
				return p
			end,
			[2] = function(p)
				p.renamed = true
				return p
			end,
		}
		local ok, p = Migrations.run({ schemaVersion = 1, materials = { OldIce = 5 } }, 3, steps)
		expect(ok).toBe(true)
		expect(p.schemaVersion).toBe(3)
		expect(p.materials.NewIce).toBe(5)
		expect(p.renamed).toBe(true)
		local ok2, code2 = Migrations.run({ schemaVersion = 99 }, Schema.CURRENT_VERSION)
		expect(ok2).toBe(false)
		expect(code2).toBe("FUTURE_SCHEMA")
		local ok3, code3 = Migrations.run({ schemaVersion = 0 }, 2, {})
		expect(ok3).toBe(false)
		expect(code3).toBe("MISSING_MIGRATION_0")
		local ok4, code4 = Migrations.run({ schemaVersion = "x" }, 1)
		expect(ok4).toBe(false)
		expect(code4).toBe("CORRUPT_VERSION")
		local ok5, code5 = Migrations.run({ schemaVersion = 1 }, 2, { [1] = function()
			error("boom")
		end })
		expect(ok5).toBe(false)
		expect(code5).toBe("MIGRATION_FAILED")
	end)

	---------------------------------------------------------------- slots
	it("slots: 8 unique slots, 9th refused, duplicates return the same slot", function()
		local a = SlotAllocator.new({ 1, 2, 3, 4, 5, 6, 7, 8 })
		local seen = {}
		for i = 1, 8 do
			local s = a:Assign("p" .. i)
			expect(s ~= nil).toBe(true)
			expect(seen[s]).toBe(nil)
			seen[s] = true
		end
		expect(a:Count()).toBe(8)
		expect(a:Assign("p9")).toBe(nil)
		expect(a:Assign("p3")).toBe(a:GetSlot("p3"))
		expect(a:Count()).toBe(8)
	end)

	it("slots: leaving frees the slot for the next joiner; unknown release is a no-op", function()
		local a = SlotAllocator.new({ 1, 2, 3, 4, 5, 6, 7, 8 })
		for i = 1, 8 do
			a:Assign("p" .. i)
		end
		local freed = a:Release("p5")
		expect(freed).toBe(5)
		expect(a:GetOwner(5)).toBe(nil)
		expect(a:Release("p5")).toBe(nil)
		expect(a:Release("ghost")).toBe(nil)
		expect(a:Assign("p9")).toBe(5)
		expect(a:GetOwner(5)).toBe("p9")
		expect(a:GetSlot("p5")).toBe(nil)
	end)

	it("slots: preference order is respected and duplicate order entries are rejected", function()
		local a = SlotAllocator.new({ 3, 1, 2 })
		expect(a:Assign("x")).toBe(3)
		expect(a:Assign("y")).toBe(1)
		expect(function()
			SlotAllocator.new({ 1, 1 })
		end).toThrow()
	end)

	---------------------------------------------------------------- transactions
	local function capFn(section: string, id: string): number
		return Schema.capFor(section, id)
	end

	it("transactions: atomic — one failing delta applies nothing", function()
		local p = Schema.default(NOW)
		local credits, ice = p.currencies.Credits, p.materials.IceMatter
		local ok, code = TransactionCore.apply(p, { currencies = { Credits = 100 }, materials = { IceMatter = -(ice + 1) } }, capFn)
		expect(ok).toBe(false)
		expect(code).toBe("INSUFFICIENT_FUNDS")
		expect(p.currencies.Credits).toBe(credits)
		expect(p.materials.IceMatter).toBe(ice)
		local ok2, _, applied = TransactionCore.apply(p, { currencies = { Credits = 100 }, materials = { IceMatter = -ice } }, capFn)
		expect(ok2).toBe(true)
		expect(p.currencies.Credits).toBe(credits + 100)
		expect(p.materials.IceMatter).toBe(0)
		expect(applied.materials.IceMatter).toBe(-ice)
	end)

	it("transactions: malformed / huge / unknown inputs are rejected", function()
		local p = Schema.default(NOW)
		local function code(tx: any): string
			local _, c = TransactionCore.apply(p, tx, capFn)
			return c
		end
		expect(code(nil)).toBe("INVALID_TRANSACTION")
		expect(code({ wallet = { Credits = 1 } })).toBe("INVALID_TRANSACTION")
		expect(code({ currencies = { Gold = 1 } })).toBe("UNKNOWN_ITEM")
		expect(code({ currencies = { Credits = 0 / 0 } })).toBe("INVALID_AMOUNT")
		expect(code({ currencies = { Credits = math.huge } })).toBe("INVALID_AMOUNT")
		expect(code({ currencies = { Credits = 1.5 } })).toBe("INVALID_AMOUNT")
		expect(code({ currencies = { Credits = 1e15 } })).toBe("INVALID_AMOUNT")
		expect(code({ currencies = { Credits = "100" } })).toBe("INVALID_AMOUNT")
		expect(code({ currencies = { Credits = 0 } })).toBe("EMPTY_TRANSACTION")
		expect(p.currencies.Credits).toBe(EconomyConfig.STARTING_BALANCES.currencies.Credits)
	end)

	it("transactions: caps clamp by default and reject when asked", function()
		local p = Schema.default(NOW)
		local cap = Schema.capFor("catalysts", "FrostSeed")
		local ok, _, applied = TransactionCore.apply(p, { catalysts = { FrostSeed = cap + 50 } }, capFn)
		expect(ok).toBe(true)
		expect(p.catalysts.FrostSeed).toBe(cap)
		expect(applied.catalysts.FrostSeed).toBe(cap - 1)
		local ok2, code2 = TransactionCore.apply(p, { catalysts = { FrostSeed = 1 } }, capFn, "reject")
		expect(ok2).toBe(false)
		expect(code2).toBe("CAP_EXCEEDED")
	end)

	---------------------------------------------------------------- formulas
	it("formulas: xp curve monotonic, bounded, max level absorbs xp", function()
		local prev = 0
		for l = 1, EconomyConfig.LEVEL.MAX_LEVEL - 1 do
			local n = Formulas.xpToNext(l)
			expect(n > prev).toBe(true)
			expect(n < 100_000).toBe(true)
			prev = n
		end
		expect(Formulas.xpToNext(EconomyConfig.LEVEL.MAX_LEVEL)).toBe(0)
		local lvl, xp, gained = Formulas.applyXp(1, 0, Formulas.xpToNext(1) + Formulas.xpToNext(2) + 5)
		expect(lvl).toBe(3)
		expect(xp).toBe(5)
		expect(#gained).toBe(2)
		local lvl2, xp2 = Formulas.applyXp(1, 0, 1e9)
		expect(lvl2).toBe(EconomyConfig.LEVEL.MAX_LEVEL)
		expect(xp2).toBe(0)
	end)

	it("formulas: upgrade costs finite and nil at max; early progression reachable", function()
		for id, def in EconomyConfig.UPGRADES do
			local total = 0
			for l = 0, def.maxLevel - 1 do
				local c = Formulas.upgradeCost(id, l)
				expect(c ~= nil).toBe(true)
				total += c.currencies.Credits
			end
			expect(Formulas.upgradeCost(id, def.maxLevel)).toBe(nil)
			expect(total < 500_000).toBe(true)
		end
		-- a new player can afford the first yield upgrade from the starting kit
		local first = Formulas.upgradeCost("HarvestYield", 0)
		expect(first.currencies.Credits <= EconomyConfig.STARTING_BALANCES.currencies.Credits).toBe(true)
		expect(Formulas.upgradeCost("Nope", 0)).toBe(nil)
	end)

	it("formulas: harvest yield/energy/regen bounded", function()
		expect(Formulas.harvestYield("IceMatter", 1, 0, 1)).toBe(EconomyConfig.HARVEST.BASE_YIELD.IceMatter)
		expect(Formulas.harvestYield("Nope", 1, 0, 1)).toBe(0)
		local maxY = Formulas.harvestYield("PlasmaMatter", 50, 999, 1e9)
		expect(maxY < 1000).toBe(true)
		expect(Formulas.harvestEnergyCost(999) >= EconomyConfig.HARVEST.MIN_ENERGY_COST).toBe(true)
		local v, used = Formulas.regenEnergy(0, 100, 25) -- 6/min -> 2 energy, 20 s used
		expect(v).toBe(2)
		expect(used).toBeNear(20)
		local v2 = Formulas.regenEnergy(90, 100, 1e7)
		expect(v2).toBe(100)
		local v3 = Formulas.regenEnergy(150, 100, 60)
		expect(v3).toBe(150)
		expect(Formulas.energyCap(50, 15) <= EconomyConfig.BALANCE_CAPS.currencies.CosmicEnergy).toBe(true)
	end)

	---------------------------------------------------------------- net
	it("RemoteGuard.checkPayload rejects malformed client input", function()
		local function why(p: any): string?
			local ok, reason = RemoteGuard.checkPayload(p)
			return if ok then "OK" else reason
		end
		expect(why({ requestId = 1, materialId = "IceMatter", amount = 5 })).toBe("OK")
		expect(why("str")).toBe("NOT_TABLE")
		expect(why(nil)).toBe("NOT_TABLE")
		expect(why({ amount = 0 / 0 })).toBe("BAD_NUMBER")
		expect(why({ amount = math.huge })).toBe("BAD_NUMBER")
		expect(why({ [1] = "array" })).toBe("BAD_KEY")
		expect(why({ s = string.rep("x", 1000) })).toBe("STRING_TOO_LONG")
		expect(why({ a = { b = { c = 1 } } })).toBe("TOO_DEEP")
		expect(why({ v = Vector3.zero })).toBe("BAD_TYPE")
		local big = {}
		for i = 1, 100 do
			big["k" .. i] = i
		end
		expect(why(big)).toBe("TOO_MANY_KEYS")
		expect(RemoteGuard.isRequestId(1.5)).toBe(false)
		expect(RemoteGuard.isRequestId(-1)).toBe(false)
		expect(RemoteGuard.isRequestId(2 ^ 40)).toBe(false)
		expect(RemoteGuard.isPositiveInt(1e300, 10)).toBe(false)
		expect(RemoteGuard.isId("Ice Matter; drop")).toBe(false)
	end)

	it("RemoteGuard rate limiter: burst, block, refill, per key", function()
		local t = 0
		local rl = RemoteGuard.newRateLimiter(3, 1, function()
			return t
		end)
		expect(rl:Allow("a")).toBe(true)
		expect(rl:Allow("a")).toBe(true)
		expect(rl:Allow("a")).toBe(true)
		expect(rl:Allow("a")).toBe(false)
		expect(rl:Allow("b")).toBe(true)
		t = 1.01
		expect(rl:Allow("a")).toBe(true)
		expect(rl:Allow("a")).toBe(false)
		t = 100
		for _ = 1, 3 do
			expect(rl:Allow("a")).toBe(true)
		end
		expect(rl:Allow("a")).toBe(false)
	end)

	---------------------------------------------------------------- environment
	it("environment: Studio never writes real stores unless explicitly configured; live non-prod uses TEST", function()
		local cfg = { PRODUCTION_UNIVERSE_IDS = { 111 }, TEST_UNIVERSE_IDS = { 222 }, STUDIO_BACKEND = "mock" }
		expect(DataEnvironment.decide(true, 111, cfg)).toBe("studio")
		expect(DataEnvironment.decide(true, 222, cfg)).toBe("studio")
		cfg.STUDIO_BACKEND = "test"
		expect(DataEnvironment.decide(true, 222, cfg)).toBe("test")
		expect(DataEnvironment.decide(true, 111, cfg)).toBe("studio") -- production universe never from Studio
		expect(DataEnvironment.decide(true, 333, cfg)).toBe("studio")
		expect(DataEnvironment.decide(false, 111, cfg)).toBe("production")
		expect(DataEnvironment.decide(false, 222, cfg)).toBe("test")
		expect(DataEnvironment.decide(false, 333, cfg)).toBe("test")
	end)
end
