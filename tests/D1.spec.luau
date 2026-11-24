--!strict
-- D1 (release blocker): production DataStore configuration, environment selection, dev-command security and
-- "a failed load never overwrites saved data". Pure decisions + MockDataStore only: NO real DataStore is touched.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local SSS = game:GetService("ServerScriptService")
	local Server = SSS.PF_Server
	local DataConfig = ctx.require(Server.Config.DataConfig)
	local DataEnvironment = ctx.require(Server.Data.DataEnvironment)
	local ProfileStore = ctx.require(Server.Data.ProfileStore)
	local MockDataStore = ctx.require(Server.Data.MockDataStore)
	local Schema = ctx.require(Server.Data.ProfileSchema)
	local HttpService = game:GetService("HttpService")

	local PROD_UNIVERSE = 10778085398
	local PROD_PLACE = 79132282456701

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

	-- 2026-11-22: production is PREPARED but NOT ACTIVE until the owner confirms the universe and the private-test
	-- DataStore pass succeeded (owner decision). PROD_CFG = the configuration that activation will produce.
	local PROD_CFG = table.clone(DataConfig)
	PROD_CFG.PRODUCTION_UNIVERSE_IDS = { DataConfig.PRODUCTION_UNIVERSE_ID_PENDING }

	it("CONFIG: the verified universe is the pending production universe (not active yet); arrays; no overlap", function()
		expect(game.GameId).toBe(PROD_UNIVERSE) -- the place open in Studio IS the reported experience
		expect(game.PlaceId).toBe(PROD_PLACE)
		expect(type(DataConfig.PRODUCTION_UNIVERSE_IDS)).toBe("table")
		expect(#DataConfig.PRODUCTION_UNIVERSE_IDS).toBe(0) -- not active: live servers use the TEST store
		expect(DataConfig.PRODUCTION_UNIVERSE_ID_PENDING).toBe(PROD_UNIVERSE)
		expect(table.find(DataConfig.TEST_UNIVERSE_IDS, PROD_UNIVERSE)).toBe(nil)
		for _, list in { DataConfig.PRODUCTION_UNIVERSE_IDS, DataConfig.TEST_UNIVERSE_IDS } do
			for k, v in list do
				expect(type(k)).toBe("number") -- array, not a dictionary
				expect(type(v) == "number" and v % 1 == 0 and v > 0).toBe(true)
			end
		end
		for _, id in DataConfig.TEST_UNIVERSE_IDS do
			expect(table.find(DataConfig.PRODUCTION_UNIVERSE_IDS, id)).toBe(nil)
		end
		expect(DataConfig.STUDIO_BACKEND).toBe("mock")
		expect(DataConfig.STORE_NAMES.production ~= DataConfig.STORE_NAMES.test).toBe(true)
		expect(DataConfig.KEY_PREFIXES.production ~= DataConfig.KEY_PREFIXES.test).toBe(true)
	end)

	it("ENVIRONMENT: live production universe -> production store; Studio NEVER production; others -> test", function()
		-- today (inactive): even the real universe's live servers stay on the TEST store
		expect(DataEnvironment.decide(false, PROD_UNIVERSE)).toBe("test")
		-- after activation:
		expect(DataEnvironment.decide(false, PROD_UNIVERSE, PROD_CFG)).toBe("production")
		expect(DataConfig.STORE_NAMES[DataEnvironment.decide(false, PROD_UNIVERSE, PROD_CFG)]).toBe("PF_Profiles_v1")
		expect(DataConfig.KEY_PREFIXES[DataEnvironment.decide(false, PROD_UNIVERSE, PROD_CFG)]).toBe("u_")
		-- Studio sessions of the production experience stay on the in-memory mock ...
		expect(DataEnvironment.decide(true, PROD_UNIVERSE, PROD_CFG)).toBe("studio")
		-- ... even if someone switches Studio to the real test store and lists the production id as "test"
		local cfg = table.clone(PROD_CFG)
		cfg.STUDIO_BACKEND = "test"
		cfg.TEST_UNIVERSE_IDS = { PROD_UNIVERSE }
		expect(DataEnvironment.decide(true, PROD_UNIVERSE, cfg)).toBe("studio")
		-- a separate private test experience: live -> TEST store; Studio -> mock unless explicitly opted in
		local testUniverse = 123456789
		expect(DataEnvironment.decide(false, testUniverse)).toBe("test")
		expect(DataConfig.STORE_NAMES.test).toBe("PF_TEST_Profiles_v1")
		expect(DataEnvironment.decide(true, testUniverse)).toBe("studio")
		cfg.TEST_UNIVERSE_IDS = { testUniverse }
		expect(DataEnvironment.decide(true, testUniverse, cfg)).toBe("test")
		-- exhaustive: Studio can never resolve to production for any universe or config
		for _, u in { 0, 1, PROD_UNIVERSE, testUniverse } do
			for _, backend in { "mock", "test" } do
				local c2 = table.clone(PROD_CFG)
				c2.STUDIO_BACKEND = backend
				c2.TEST_UNIVERSE_IDS = { u }
				expect(DataEnvironment.decide(true, u, c2) ~= "production").toBe(true)
			end
		end
	end)

	it("DEV COMMANDS: disabled on production servers for everyone (owner included); no remote, no hook", function()
		local bound = {}
		local RG = table.clone(ctx.require(Server.Net.RemoteGuard))
		RG.bind = function(name: string)
			table.insert(bound, name)
		end
		local fakeEnv = table.clone(DataEnvironment)
		fakeEnv.resolve = function()
			return { name = "production", persistent = true, isStudio = false, storeName = "PF_Profiles_v1", keyPrefix = "u_" }
		end
		local S = Server.Services
		local stubs: any = { [Server.Data.DataEnvironment] = fakeEnv, [Server.Net.RemoteGuard] = RG }
		for _, n in { "ProfileService", "PlanetSlotService", "EconomyService", "InventoryService", "PlanetDataService", "ClientDataService", "EvolutionService" } do
			stubs[(S :: any)[n]] = {}
		end
		local function req(m: any): any
			return if stubs[m] ~= nil then stubs[m] else ctx.require(m)
		end
		local mod = S.DevCommandService
		local fn = assert(loadstring(mod.Source, "=" .. mod:GetFullName()))
		setfenv(fn, setmetatable({ script = mod, require = req }, { __index = getfenv() }) :: any)
		local Dev = fn()
		Dev:Init()
		Dev:Start()
		expect(Dev.isEnabled()).toBe(false)
		expect(#bound).toBe(0) -- the Dev_Command remote is never created
		local owner = { UserId = game.CreatorId, Name = "Owner" }
		expect(Dev.isAuthorized(owner)).toBe(false)
		local ok, code = Dev:Run(owner, "grant", { section = "currencies", id = "Credits", amount = 1 })
		expect(ok).toBe(false)
		expect(code).toBe("NOT_AUTHORIZED")
	end)

	it("DEV COMMANDS (live allowlist): only Studio or a listed private TEST universe; never the real game", function()
		local Dev = ctx.require(Server.Services.DevCommandService)
		local dv = { ENABLED = true }
		local function dc(prod: { number }, test: { number }): any
			return { PRODUCTION_UNIVERSE_IDS = prod, TEST_UNIVERSE_IDS = test, PRODUCTION_UNIVERSE_ID_PENDING = PROD_UNIVERSE }
		end
		local testU = 123456789
		expect(Dev.decideEnabled("studio", true, PROD_UNIVERSE, dv, dc({}, {}))).toBe(true) -- Studio playtests
		expect(Dev.decideEnabled("test", false, PROD_UNIVERSE, dv, dc({}, {}))).toBe(false) -- real game, prod inactive
		expect(Dev.decideEnabled("test", false, PROD_UNIVERSE, dv, dc({}, { PROD_UNIVERSE }))).toBe(false) -- mis-listed
		expect(Dev.decideEnabled("production", false, PROD_UNIVERSE, dv, dc({ PROD_UNIVERSE }, {}))).toBe(false)
		expect(Dev.decideEnabled("test", false, 5555, dv, dc({}, {}))).toBe(false) -- any unlisted live universe
		expect(Dev.decideEnabled("test", false, testU, dv, dc({}, { testU }))).toBe(true) -- the private test experience
		expect(Dev.decideEnabled("test", false, testU, { ENABLED = false }, dc({}, { testU }))).toBe(false)
		expect(Dev.decideEnabled("studio", true, PROD_UNIVERSE, dv, dc({ PROD_UNIVERSE }, {}))).toBe(false) -- activated prod
		-- the shipped configuration: the real game's live servers get NO developer commands
		expect(Dev.decideEnabled("test", false, PROD_UNIVERSE)).toBe(false)
	end)

	it("HOOKS: every test hook / developer remote is behind a Studio-only or non-production guard", function()
		local unguarded = {}
		for _, root in { game:GetService("ServerScriptService"), game:GetService("StarterPlayer") } do
			for _, d in root:GetDescendants() do
				if d:IsA("LuaSourceContainer") then
					local lines = {}
					for line in (d.Source .. "\n"):gmatch("([^\n]*)\n") do
						table.insert(lines, line)
					end
					for i, l in lines do
						local creates = l:find('Instance.new%("BindableFunction"%)') or l:find('bind%("Event_Dev"') or l:find('bind%("Dev_Command"')
						if creates then
							local ok = false
							for k = i, math.max(1, i - 60), -1 do
								local g = lines[k]
								if g:find("IsStudio%(%)") or g:find("if isStudio then") or g:find("if not enabled then") then
									ok = true
									break
								end
							end
							if not ok then
								table.insert(unguarded, d:GetFullName() .. ":" .. i)
							end
						end
					end
				end
			end
		end
		if #unguarded > 0 then
			error("unguarded hooks: " .. table.concat(unguarded, ", "))
		end
		-- the raw planet setters refuse outside Studio / in production
		local pds = Server.Services.PlanetDataService.Source
		expect(pds:find('DataEnvironment.resolve().name ~= "production" and RunService:IsStudio()', 1, true) ~= nil).toBe(true)
	end)

	local function store(mock: any, opts: any?): any
		local o = opts or {}
		return ProfileStore.new({ backend = mock, keyPrefix = o.prefix or "u_", clock = o.clock or function() return 10000 end, config = { LOAD_LOCK_RETRIES = o.retries or 0, LOAD_LOCK_RETRY_DELAY = 0, RELEASE_RETRY_DELAY = 0 }, retryOpts = { retries = 0, baseDelay = 0, waitForBudget = false }, jobId = o.job or "J1" })
	end

	it("FAILED LOAD: read errors, damaged records and newer schemas are refused WITHOUT any write", function()
		local mock = MockDataStore.new()
		local s = store(mock)
		-- a real returning player's save
		local _, prof = s:Load(501)
		prof.data.currencies.Credits = 4321
		expect((s:Release(prof))).toBe(true)
		local before = mock:Peek("u_501")
		-- 1) the DataStore read fails: nothing is written, nothing is lost
		mock:FailNext(1)
		local ok1, c1 = s:Load(501)
		expect(ok1).toBe(false)
		expect(c1).toBe("DATASTORE_ERROR")
		expect(deepEq(mock:Peek("u_501"), before)).toBe(true)
		-- 2) damaged values are never treated as "new player" (no defaults written over them)
		for i, bad in { "corrupt", 42, { meta = { saveCount = 9 } }, { meta = { saveCount = 9 }, data = "x" } } do
			local key = "u_" .. (600 + i)
			mock:Poke(key, bad)
			local okB, codeB = s:Load(600 + i)
			expect(okB).toBe(false)
			expect(codeB).toBe("CORRUPT_RECORD")
			expect(deepEq(mock:Peek(key), bad)).toBe(true)
		end
		-- 3) a save written by a NEWER game version is refused, not downgraded
		local future = table.clone(before)
		future.data = table.clone(before.data)
		future.data.schemaVersion = Schema.CURRENT_VERSION + 1
		future.meta = { saveCount = 3 }
		mock:Poke("u_700", future)
		local stored = mock:Peek("u_700")
		local okF, codeF = s:Load(700)
		expect(okF).toBe(false)
		expect(codeF ~= "CORRUPT_RECORD").toBe(true) -- refused as a newer schema, not as damage
		expect(deepEq(mock:Peek("u_700"), stored)).toBe(true)
		-- 4) the only "new player" is a missing key; the existing save still loads intact
		local okN, pn = s:Load(800)
		expect(okN).toBe(true)
		expect(pn.isNew).toBe(true)
		local okR, pr = s:Load(501)
		expect(okR).toBe(true)
		expect(pr.isNew).toBe(false)
		expect(pr.data.currencies.Credits).toBe(4321)
	end)

	it("SESSION LOCK with production keys: a second server cannot overwrite a live session's data", function()
		local mock = MockDataStore.new()
		local clk = { t = 50000 }
		local a = store(mock, { job = "A", clock = function() return clk.t end })
		local b = store(mock, { job = "B", clock = function() return clk.t end })
		local okA, pa = a:Load(901)
		expect(okA).toBe(true)
		expect(pa.key).toBe("u_901")
		pa.data.currencies.Credits = 777
		expect((a:Save(pa))).toBe(true)
		-- server B (retries 0) sees a fresh foreign lock on its last attempt -> takes over (teleport case)
		local okB, pb = b:Load(901)
		expect(okB).toBe(true)
		expect(pb.stoleLock).toBe(true)
		expect(pb.data.currencies.Credits).toBe(777) -- B continues from A's saved data
		-- A's stale session can no longer write
		pa.data.currencies.Credits = 1
		local okSave, code = a:Save(pa)
		expect(okSave).toBe(false)
		expect(code).toBe("LOCK_LOST")
		expect(mock:Peek("u_901").data.currencies.Credits).toBe(777)
	end)
end
