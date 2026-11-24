--!strict
-- Monetization specs: the REAL MonetizationService + MonetizationData over stubs and a real session-locked
-- ProfileStore on MockDataStore. A fake marketplace adapter stands in for MarketplaceService (no real
-- products are created or touched). Every loop is bounded.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local Shared = RS.PF_Shared
	local Server = SSS.PF_Server
	local Signal = ctx.require(Shared.Util.Signal)
	local MonetizationConfig = ctx.require(Shared.Config.MonetizationConfig)
	local Data = ctx.require(Server.Monetization.MonetizationData)
	local Schema = ctx.require(Server.Data.ProfileSchema)
	local ProfileStore = ctx.require(Server.Data.ProfileStore)
	local MockDataStore = ctx.require(Server.Data.MockDataStore)
	local Sim = ctx.require(Server.Evolution.PlanetProgressionSimulator)
	local Decision = Enum.ProductPurchaseDecision

	local PASS_IDS = { CosmicAtmospheres = 9001, PremiumRings = 9002, HarvesterVFX = 9003, DesignPresets = 9004 }
	local FIREWORKS_ID = 7001

	local function world(opts: any?): any
		local o = opts or {}
		local W: any = { mock = o.mock or MockDataStore.new(), clk = o.clk or { t = 10000 }, sessions = {}, sent = {}, celebrations = {}, prompts = {}, harvesting = {}, rifts = {}, failSave = false, saveError = false, saveDelay = 0 }
		W.store = ProfileStore.new({ backend = W.mock, keyPrefix = "mon_", clock = function() return W.clk.t end, config = { LOAD_LOCK_RETRIES = 1, LOAD_LOCK_RETRY_DELAY = 0, RELEASE_RETRY_DELAY = 0 }, retryOpts = { retries = 1, baseDelay = 0, waitForBudget = false }, jobId = o.job or "J1" })
		local PS: any = { ProfileLoaded = Signal.new(), ProfileReleasing = Signal.new() }
		function PS:GetData(p)
			local s = W.sessions[p]
			return s and s.data
		end
		function PS:WaitForData(p)
			return PS:GetData(p)
		end
		function PS:IsReady(p)
			return W.sessions[p] ~= nil
		end
		function PS:MarkChanged() end
		function PS:SaveNow(p, _force)
			if W.saveDelay > 0 then
				task.wait(W.saveDelay)
			end
			if W.saveError then
				error("simulated crash during save")
			end
			if W.failSave then
				return false, "DATASTORE_ERROR"
			end
			local s = W.sessions[p]
			if not s then
				return false, "NOT_READY"
			end
			return W.store:Save(s)
		end
		local Slots: any = {}
		function Slots:GetSlot(p)
			return if W.sessions[p] then 1 else nil
		end
		local Evo: any = {}
		function Evo:SetCosmetic(p, cat, id)
			local d = PS:GetData(p)
			if id == "None" then
				d.planet.cosmetics[cat] = nil
			elseif d.cosmetics[id] ~= nil then
				d.planet.cosmetics[cat] = id
			else
				return false, "NOT_OWNED"
			end
			return true, "OK"
		end
		local Harv: any = {}
		function Harv:IsOperating(p)
			return W.harvesting[p] == true
		end
		local Rift: any = {}
		function Rift:GetRun(p)
			return W.rifts[p]
		end
		local RG = table.clone(ctx.require(Server.Net.RemoteGuard))
		RG.bind = function() end
		RG.getRemote = function(name: string)
			return {
				FireClient = function(_, p, msg)
					table.insert(W.sent, { p = p, msg = msg, remote = name })
				end,
				FireAllClients = function(_, msg)
					table.insert(W.celebrations, msg)
				end,
			}
		end
		local S = Server.Services
		local stubs: any = { [S.ProfileService] = PS, [S.PlanetSlotService] = Slots, [S.EvolutionService] = Evo, [S.HarvestService] = Harv, [S.RiftService] = Rift, [Server.Net.RemoteGuard] = RG }
		local function req(m: any): any
			return if stubs[m] ~= nil then stubs[m] else ctx.require(m)
		end
		local mod = S.MonetizationService
		local fn = assert(loadstring(mod.Source, "=" .. mod:GetFullName()))
		setfenv(fn, setmetatable({ script = mod, require = req }, { __index = getfenv() }) :: any)
		W.svc = fn()
		W.svc:Init()
		W.market = { owned = {}, prices = {}, ownsError = false, infoError = false }
		W.svc._setPlayerResolver(function(uid: number)
			for p in W.sessions do
				if p.UserId == uid then
					return p
				end
			end
			return nil
		end)
		W.svc._setMarket({
			owns = function(_uid: number, id: number)
				if W.market.ownsError then
					error("ownership outage")
				end
				return W.market.owned[id] == true
			end,
			info = function(id: number, kind: string)
				if W.market.infoError then
					error("info outage")
				end
				local price = W.market.prices[id]
				return { PriceInRobux = price, IsForSale = price ~= nil, Name = kind .. id }
			end,
			promptPass = function(p, id)
				table.insert(W.prompts, { kind = "pass", id = id, p = p })
			end,
			promptProduct = function(p, id)
				table.insert(W.prompts, { kind = "product", id = id, p = p })
			end,
		})
		function W.join(userId: number): any
			local p = { UserId = userId, Name = "P" .. userId, DisplayName = "P" .. userId, Parent = true }
			local ok, prof = W.store:Load(userId)
			assert(ok, "load failed: " .. tostring(prof))
			W.sessions[p] = prof
			return p
		end
		function W.leave(p: any)
			W.store:Release(W.sessions[p])
			W.sessions[p] = nil
		end
		function W.data(p: any): any
			return W.sessions[p].data
		end
		function W.notices(p: any, kind: string): number
			local n = 0
			for _, s in W.sent do
				if s.p == p and s.msg.kind == kind then
					n += 1
				end
			end
			return n
		end
		return W
	end

	local function withIds(fn: () -> ())
		local saved = {}
		for k, id in PASS_IDS do
			saved[k] = MonetizationConfig.PASSES[k].gamePassId
			MonetizationConfig.PASSES[k].gamePassId = id
		end
		local savedP = MonetizationConfig.PRODUCTS.CosmicFireworks.productId
		MonetizationConfig.PRODUCTS.CosmicFireworks.productId = FIREWORKS_ID
		local ok, err = pcall(fn)
		for k, id in saved do
			MonetizationConfig.PASSES[k].gamePassId = id
		end
		MonetizationConfig.PRODUCTS.CosmicFireworks.productId = savedP
		if not ok then
			error(err, 0)
		end
	end

	local function receipt(userId: number, purchaseId: string, productId: number?): any
		return { PlayerId = userId, PurchaseId = purchaseId, ProductId = productId or FIREWORKS_ID, CurrencySpent = 25, CurrencyType = Enum.CurrencyType.Robux, PlaceIdWherePurchased = 1 }
	end

	---------------------------------------------------------------- configuration / fairness
	it("CONFIG: valid, fixed contents, cosmetic-only grants, nothing random, ids optional", function()
		expect(#Data.validateConfig()).toBe(0)
		for _, group in { MonetizationConfig.PASSES, MonetizationConfig.PRODUCTS } do
			for _, p in group do
				for k in p.grants do
					expect(MonetizationConfig.ALLOWED_GRANTS[k]).toBe(true)
				end
			end
		end
		local pass = MonetizationConfig.PASSES.PremiumRings
		pass.grants.currencies = { Credits = 1000 }
		local errs = Data.validateConfig()
		pass.grants.currencies = nil
		expect(#errs > 0).toBe(true) -- a progression grant is rejected
		expect(#Data.validateConfig()).toBe(0)
	end)

	it("FREE PLAYERS: no gameplay system checks purchases; every branch reaches Stage 4 with nothing bought", function()
		for _, name in { "EvolutionService", "HarvestService", "RiftService", "WorldEventService", "EconomyService", "SocialService", "InventoryService" } do
			local s = (Server.Services :: any)[name].Source
			expect(s:find("onetization", 1, true)).toBe(nil)
			expect(s:find("GamePass", 1, true)).toBe(nil)
		end
		expect(Server.Evolution.ReactionEngine.Source:find("onetization", 1, true)).toBe(nil)
		local p = Schema.default(1, 1)
		expect(next(p.monetization.passes)).toBe(nil)
		for _, b in { "Living", "Frozen", "Volcanic", "Crystal" } do
			expect(Sim.run(b).stuck).toBe(false)
		end
	end)

	---------------------------------------------------------------- product information / prompts
	it("CATALOG: missing configuration, official prices, not for sale, info outage", function()
		local W = world()
		local A = W.join(101)
		for _, e in W.svc:Catalog(A).passes do
			expect(e.available).toBe(false)
			expect(e.price).toBe(nil)
			expect(e.reason).toBe("NOT_CONFIGURED")
		end
		local ok, code = W.svc:PromptPass(A, "PremiumRings")
		expect(ok).toBe(false)
		expect(code).toBe("NOT_CONFIGURED")
		expect(#W.prompts).toBe(0)
		withIds(function()
			W.market.prices = { [9001] = 199, [9002] = 149, [7001] = 25 }
			W.svc._setMarket(nil)
			local W2 = world()
			W2.market.prices = W.market.prices
			local B = W2.join(111)
			local c = W2.svc:Catalog(B)
			local byKey = {}
			for _, e in c.passes do
				byKey[e.key] = e
			end
			expect(byKey.CosmicAtmospheres.price).toBe(199)
			expect(byKey.CosmicAtmospheres.available).toBe(true)
			expect(byKey.HarvesterVFX.available).toBe(false)
			expect(byKey.HarvesterVFX.reason).toBe("NOT_FOR_SALE")
			expect(c.products[1].price).toBe(25)
			local okP, codeP = W2.svc:PromptPass(B, "CosmicAtmospheres")
			expect(okP).toBe(true)
			expect(codeP).toBe("PROMPTED")
			expect(W2.prompts[#W2.prompts].id).toBe(9001)
			local _, codeNS = W2.svc:PromptPass(B, "HarvesterVFX")
			expect(codeNS).toBe("NOT_FOR_SALE")
			local _, codeU = W2.svc:PromptPass(B, "LootBox")
			expect(codeU).toBe("UNKNOWN_ITEM")
			local W3 = world()
			W3.market.infoError = true
			local C3 = W3.join(112)
			local c3 = W3.svc:Catalog(C3)
			expect(c3.passes[1].reason).toBe("INFO_UNAVAILABLE")
			expect(c3.passes[1].price).toBe(nil) -- never a guessed price
			local _, codeO = W3.svc:PromptPass(C3, "CosmicAtmospheres")
			expect(codeO).toBe("INFO_UNAVAILABLE")
			expect(#W3.prompts).toBe(0)
		end)
	end)

	it("PROMPTS: never during harvesting or an expedition, never for owned passes", function()
		withIds(function()
			local W = world()
			W.market.prices = { [9001] = 199, [7001] = 25 }
			local A = W.join(102)
			W.harvesting[A] = true
			local _, c1 = W.svc:PromptPass(A, "CosmicAtmospheres")
			expect(c1).toBe("BUSY_HARVESTING")
			W.harvesting[A] = nil
			W.rifts[A] = { id = "run" }
			local _, c2 = W.svc:PromptProduct(A, "CosmicFireworks")
			expect(c2).toBe("BUSY_EXPEDITION")
			W.rifts[A] = nil
			expect(#W.prompts).toBe(0)
			W.market.owned[9001] = true
			W.svc:RefreshPasses(A)
			local _, c3 = W.svc:PromptPass(A, "CosmicAtmospheres")
			expect(c3).toBe("ALREADY_OWNED")
			expect(#W.prompts).toBe(0)
		end)
	end)

	---------------------------------------------------------------- game passes
	it("PASSES: purchase grants once; cancellation grants nothing; returning owner keeps everything", function()
		withIds(function()
			local mock = MockDataStore.new()
			local clk = { t = 10000 }
			local W = world({ mock = mock, clk = clk })
			local A = W.join(103)
			W.svc._passFinished(A, 9002, false) -- cancelled
			expect(W.data(A).monetization.passes.PremiumRings).toBe(nil)
			expect(W.data(A).cosmetics.Ring_Halo).toBe(nil)
			expect(W.notices(A, "cancelled")).toBe(1)
			W.svc._passFinished(A, 9002, true) -- purchased
			W.svc._passFinished(A, 9002, true) -- duplicate event
			W.market.owned[9002] = true
			W.svc:RefreshPasses(A) -- and a verification on top
			expect(W.notices(A, "passGranted")).toBe(1)
			for _, id in MonetizationConfig.PASSES.PremiumRings.grants.cosmetics do
				expect(W.data(A).cosmetics[id] ~= nil).toBe(true)
			end
			W.data(A).planet.cosmetics.PlanetRing = "Ring_Halo"
			W.leave(A)
			-- returning owner on another server while the ownership API is DOWN: nothing is lost
			clk.t += 600
			local W2 = world({ mock = mock, clk = clk, job = "J2" })
			W2.market.ownsError = true
			local A2 = W2.join(103)
			W2.svc:RefreshPasses(A2)
			expect(W2.data(A2).monetization.passes.PremiumRings ~= nil).toBe(true)
			expect(W2.data(A2).planet.cosmetics.PlanetRing).toBe("Ring_Halo")
			-- and a definite "not owned" answer never silently revokes a stored entitlement
			W2.market.ownsError = false
			W2.svc:RefreshPasses(A2)
			expect(W2.data(A2).monetization.passes.PremiumRings ~= nil).toBe(true)
		end)
	end)

	---------------------------------------------------------------- developer product receipts
	it("RECEIPTS: granted once; duplicates, absent players, unknown products and unloaded profiles", function()
		withIds(function()
			local W = world()
			local A = W.join(104)
			W.rifts[A] = { id = "away" } -- keep the fireworks token (auto-launch waits) so counts are exact
			expect(W.svc._processReceipt(receipt(104, "P-1"))).toBe(Decision.PurchaseGranted)
			expect(W.data(A).monetization.fireworks).toBe(1)
			expect(W.svc._processReceipt(receipt(104, "P-1"))).toBe(Decision.PurchaseGranted) -- duplicate
			expect(W.data(A).monetization.fireworks).toBe(1)
			expect(W.svc._processReceipt(receipt(104, "P-2"))).toBe(Decision.PurchaseGranted)
			expect(W.data(A).monetization.fireworks).toBe(2)
			expect(W.svc._processReceipt(receipt(999, "P-3"))).toBe(Decision.NotProcessedYet) -- player not here
			expect(W.svc._processReceipt(receipt(104, "P-4", 123456))).toBe(Decision.NotProcessedYet) -- unknown product
			expect(W.data(A).monetization.fireworks).toBe(2)
			expect(W.data(A).monetization.receipts["P-4"]).toBe(nil)

		end)
	end)

	it("RECEIPTS: a failed save rolls the grant back and is retried later (exactly once)", function()
		withIds(function()
			local W = world()
			local A = W.join(105)
			W.rifts[A] = { id = "away" }
			W.failSave = true
			expect(W.svc._processReceipt(receipt(105, "F-1"))).toBe(Decision.NotProcessedYet)
			expect(W.data(A).monetization.fireworks).toBe(0) -- nothing half-granted
			expect(W.data(A).monetization.receipts["F-1"]).toBe(nil)
			W.failSave = false
			expect(W.svc._processReceipt(receipt(105, "F-1"))).toBe(Decision.PurchaseGranted) -- Roblox retry
			expect(W.data(A).monetization.fireworks).toBe(1)
			-- an exception inside the save is not a grant either
			W.saveError = true
			expect(W.svc._processReceipt(receipt(105, "F-2"))).toBe(Decision.NotProcessedYet)
			expect(W.data(A).monetization.receipts["F-2"]).toBe(nil) -- not remembered as granted while unsaved
			expect(W.data(A).monetization.fireworks).toBe(1)
			W.saveError = false
			expect(W.svc._processReceipt(receipt(105, "F-2"))).toBe(Decision.PurchaseGranted)
			expect(W.data(A).monetization.fireworks).toBe(2) -- F-2 granted exactly once in the end
		end)
	end)

	it("RECEIPTS: server crash during fulfilment -> the next server grants it exactly once", function()
		withIds(function()
			local mock = MockDataStore.new()
			local clk = { t = 20000 }
			local W = world({ mock = mock, clk = clk })
			local A = W.join(106)
			W.rifts[A] = { id = "away" }
			expect(W.svc._processReceipt(receipt(106, "C-0"))).toBe(Decision.PurchaseGranted) -- saved earlier purchase
			-- the crash: the grant is applied in memory but the process dies before the save completes
			W.saveError = true
			expect(W.svc._processReceipt(receipt(106, "C-1"))).toBe(Decision.NotProcessedYet)
			W.sessions[A] = nil -- server gone, no release, memory lost
			clk.t += 3600 -- the dead session's lock goes stale
			local W2 = world({ mock = mock, clk = clk, job = "J2" })
			local A2 = W2.join(106)
			W2.rifts[A2] = { id = "away" }
			expect(W2.data(A2).monetization.fireworks).toBe(1) -- only C-0 survived
			expect(W2.svc._processReceipt(receipt(106, "C-1"))).toBe(Decision.PurchaseGranted) -- Roblox re-delivers
			expect(W2.svc._processReceipt(receipt(106, "C-1"))).toBe(Decision.PurchaseGranted)
			expect(W2.data(A2).monetization.fireworks).toBe(2)
		end)
	end)

	it("RECEIPTS: simultaneous deliveries for one player are serialized (no lost or doubled grants)", function()
		withIds(function()
			local W = world()
			local A = W.join(107)
			W.rifts[A] = { id = "away" }
			W.saveDelay = 0.05 -- saves yield, so the deliveries overlap
			local results = {}
			for i, id in { "S-1", "S-2", "S-1", "S-3" } do
				task.spawn(function()
					results[i] = W.svc._processReceipt(receipt(107, id))
				end)
			end
			local waited = 0
			while #results < 4 and waited < 5 do
				waited += task.wait(0.05)
			end
			for i = 1, 4 do
				expect(results[i]).toBe(Decision.PurchaseGranted)
			end
			expect(W.data(A).monetization.fireworks).toBe(3)
			expect(#W.data(A).monetization.order).toBe(3)
		end)
	end)

	---------------------------------------------------------------- fireworks + presets + persistence
	it("FIREWORKS: auto-launch after purchase, explicit launch, none left, cooldown, kept during expeditions", function()
		withIds(function()
			local W = world()
			local A = W.join(108)
			expect(W.svc._processReceipt(receipt(108, "W-1"))).toBe(Decision.PurchaseGranted)
			task.wait() -- deferred auto-launch
			expect(#W.celebrations).toBe(1)
			expect(W.celebrations[1].slot).toBe(1)
			expect(W.data(A).monetization.fireworks).toBe(0)
			local _, c1 = W.svc:LaunchFireworks(A)
			expect(c1).toBe("NONE_LEFT")
			W.rifts[A] = { id = "run" }
			expect(W.svc._processReceipt(receipt(108, "W-2"))).toBe(Decision.PurchaseGranted)
			task.wait()
			expect(W.data(A).monetization.fireworks).toBe(1) -- kept, not wasted while away
			W.rifts[A] = nil
			local _, c2 = W.svc:LaunchFireworks(A)
			expect(c2).toBe("COOLDOWN")
		end)
	end)

	it("PRESETS: 1 free slot, pass adds 4, apply equips only owned cosmetics", function()
		withIds(function()
			local W = world()
			local A = W.join(109)
			local d = W.data(A)
			d.cosmetics.Atmosphere_Verdant = 1
			d.planet.cosmetics.Atmosphere = "Atmosphere_Verdant"
			expect((W.svc:SavePreset(A, 1))).toBe(true)
			local _, c2 = W.svc:SavePreset(A, 2)
			expect(c2).toBe("LOCKED")
			W.svc._passFinished(A, 9004, true)
			expect(Data.presetSlots(d.monetization)).toBe(5)
			d.monetization.presets[2] = { Atmosphere = "Atmosphere_Nebula", PlanetRing = nil, HarvesterFX = nil } -- not owned
			local ok, code, res = W.svc:ApplyPreset(A, 2)
			expect(ok).toBe(true)
			expect(code).toBe("PARTIAL")
			expect(res.missing[1]).toBe("Atmosphere_Nebula")
			expect(d.planet.cosmetics.Atmosphere).toBe(nil) -- never equips something not owned
			expect((W.svc:ApplyPreset(A, 1))).toBe(true)
			expect(d.planet.cosmetics.Atmosphere).toBe("Atmosphere_Verdant")
			local _, c3 = W.svc:ApplyPreset(A, 3)
			expect(c3).toBe("EMPTY")
		end)
	end)

	it("PERSISTENCE: premium cosmetics stay owned + equipped across sessions; corrupt data is repaired", function()
		local p = Schema.default(1, 77)
		p.cosmetics.Ring_Prism = 5
		p.planet.cosmetics.PlanetRing = "Ring_Prism"
		p.planet.cosmetics.HarvesterFX = "HarvesterFX_Void" -- NOT owned -> dropped on load
		p.monetization.passes.PremiumRings = { at = 5 }
		local q = Schema.reconcile(game:GetService("HttpService"):JSONDecode(game:GetService("HttpService"):JSONEncode(p)), 9, 77)
		expect(q.planet.cosmetics.PlanetRing).toBe("Ring_Prism")
		expect(q.planet.cosmetics.HarvesterFX).toBe(nil)
		expect(q.monetization.passes.PremiumRings.at).toBe(5)
		local bad = Data.reconcile({ passes = { [""] = 1, Ok = "x" }, receipts = { R1 = { t = 1 }, R2 = "junk" }, order = { "R9", "R1" }, fireworks = -5, presets = { [1] = { Atmosphere = "Nope", PlanetRing = "Ring_Halo" }, [99] = {} } }, 100)
		expect(bad.passes[""]).toBe(nil)
		expect(bad.passes.Ok.at).toBe(100)
		expect(bad.receipts.R1 ~= nil).toBe(true)
		expect(bad.receipts.R2).toBe(nil)
		expect(#bad.order).toBe(1)
		expect(bad.fireworks).toBe(0)
		expect(bad.presets[1].Atmosphere).toBe(nil)
		expect(bad.presets[1].PlanetRing).toBe("Ring_Halo")
		expect(bad.presets[99]).toBe(nil)
	end)
end
