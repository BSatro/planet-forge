--!strict
-- PF_PersistenceProbe — owner: Release / QA. Runs the real persistence path (ProfileStore + DataStoreGateway)
-- end to end. NEVER runs automatically; nothing requires it. Run it from the Studio command bar:
--
--   require(game.ServerStorage.PF_PersistenceProbe).run({ mode = "mock" })  -- anywhere: in-memory MockDataStore
--   require(game.ServerStorage.PF_PersistenceProbe).run({ mode = "test" })  -- ONLY in the private TEST experience
--
-- "test" mode safety (all must hold, otherwise it refuses before any request):
--   * Studio session, game.GameId listed in DataConfig.TEST_UNIVERSE_IDS
--   * game.GameId NOT in PRODUCTION_UNIVERSE_IDS and NOT the PRODUCTION_UNIVERSE_ID_PENDING universe
--   * store = DataConfig.STORE_NAMES.test (never the production name), keys "probe_<run>_" + negative fake user
--     ids (no real player can ever own them); every probe key is removed at the end
--   * Studio API access must have been enabled BY A HUMAN in that experience's Game Settings (never by code)
-- Checks: new profile, save, leave + rejoin, planet reconstruction, session conflict (two servers), shutdown
-- release, transient-failure recovery, persistent failure leaves stored data untouched.
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = ServerScriptService.PF_Server.Data
local DataConfig = require(ServerScriptService.PF_Server.Config.DataConfig)
local ProfileStore = require(Data.ProfileStore)
local MockDataStore = require(Data.MockDataStore)

local Probe = {}

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

local function copy(t: any): any
	return HttpService:JSONDecode(HttpService:JSONEncode(t))
end

-- Returns nil when "test" mode is allowed here, else the reason it is refused.
function Probe.refusal(): string?
	if not RunService:IsStudio() then
		return "not a Studio session"
	end
	local u = game.GameId
	if u == 0 then
		return "place is not published to an experience (GameId 0)"
	end
	if table.find(DataConfig.PRODUCTION_UNIVERSE_IDS, u) or u == DataConfig.PRODUCTION_UNIVERSE_ID_PENDING then
		return "universe " .. u .. " is the production (or pending production) experience"
	end
	if not table.find(DataConfig.TEST_UNIVERSE_IDS, u) then
		return "universe " .. u .. " is not listed in DataConfig.TEST_UNIVERSE_IDS"
	end
	if DataConfig.STORE_NAMES.test == DataConfig.STORE_NAMES.production then
		return "test and production store names are identical"
	end
	return nil
end

function Probe.run(opts: any?): string
	local o = opts or {}
	local mode = o.mode or "mock"
	local lines = {}
	local pass, fail = 0, 0
	local function check(name: string, ok: boolean, detail: string?)
		if ok then
			pass += 1
		else
			fail += 1
		end
		table.insert(lines, string.format("%s  %s%s", if ok then "PASS" else "FAIL", name, if detail then " — " .. detail else ""))
	end

	local raw: any -- backend without fault injection
	local peek: (string) -> any
	local remove: (string) -> ()
	if mode == "mock" then
		local mock = MockDataStore.new()
		raw = mock
		peek = function(k)
			return mock:Peek(k)
		end
		remove = function(k)
			mock:Poke(k, nil)
		end
	elseif mode == "test" then
		local why = Probe.refusal()
		if why then
			return "REFUSED (nothing was read or written): " .. why
		end
		local store = DataStoreService:GetDataStore(DataConfig.STORE_NAMES.test)
		raw = {
			kind = "datastore",
			storeName = DataConfig.STORE_NAMES.test,
			UpdateAsync = function(_self: any, key: string, transform: (any) -> any): any
				return (store:UpdateAsync(key, function(old)
					return transform(old)
				end))
			end,
		}
		peek = function(k)
			return store:GetAsync(k)
		end
		remove = function(k)
			store:RemoveAsync(k)
		end
	else
		return "unknown mode " .. tostring(mode)
	end

	-- fault injection wrapper around the backend (failure recovery checks)
	local failLeft = 0
	local backend = {
		kind = raw.kind or "mock",
		storeName = raw.storeName,
		UpdateAsync = function(_self: any, key: string, transform: (any) -> any): any
			if failLeft > 0 then
				failLeft -= 1
				error("502: injected probe failure")
			end
			return raw:UpdateAsync(key, transform)
		end,
	}
	local run = string.sub(HttpService:GenerateGUID(false), 1, 8)
	local prefix = "probe_" .. run .. "_"
	local real = mode == "test"
	local function newStore(job: string, retries: number?): any
		return ProfileStore.new({
			backend = backend,
			keyPrefix = prefix,
			jobId = job,
			config = { LOAD_LOCK_RETRIES = retries or 0, LOAD_LOCK_RETRY_DELAY = 0, RELEASE_RETRY_DELAY = 0 },
			retryOpts = { retries = 3, baseDelay = if real then 0.5 else 0, waitForBudget = real },
		})
	end
	local U1, U2, U3 = -1001, -1002, -1003
	table.insert(lines, string.format("Persistence probe — mode=%s store=%s prefix=%s universe=%d", mode, tostring(backend.storeName or "MockDataStore"), prefix, game.GameId))

	local okAll, err = pcall(function()
		-- 1) new profile
		local s1 = newStore("probe-server-1")
		local ok1, p1 = s1:Load(U1)
		check("new player gets a fresh profile", ok1 and p1.isNew == true, if ok1 then nil else tostring(p1))
		if not ok1 then
			return
		end
		-- 2) progression + save
		p1.data.currencies.Credits = 4321
		p1.data.level = math.max(p1.data.level, 3)
		p1.data.planet.dna.Water = 37
		p1.data.planet.dna.Temperature = 61
		p1.data.discoveries.FirstHarvest = os.time()
		local okS, codeS = s1:Save(p1)
		check("save progression", okS, codeS)
		local savedPlanet = copy(p1.data.planet)
		local okR, codeR = s1:Release(p1)
		check("leave: final save + release", okR, codeR)
		local rec = peek(p1.key)
		check("lock cleared after leaving", type(rec) == "table" and rec.meta ~= nil and rec.meta.session == nil)
		-- 3) rejoin on another server + planet reconstruction
		local s2 = newStore("probe-server-2")
		local ok2, p2 = s2:Load(U1)
		check("rejoin loads the saved profile", ok2 and p2.isNew == false and p2.data.currencies.Credits == 4321, if ok2 then ("credits " .. tostring(p2.data.currencies.Credits)) else tostring(p2))
		if ok2 then
			check("planet reconstructed identically (DNA, stage, branch, formations, seed)", deepEq(copy(p2.data.planet), savedPlanet))
			s2:Release(p2)
		end
		-- 4) session conflict: server A still holds the lock when server B loads (teleport / crash case)
		local sA, sB = newStore("probe-server-A"), newStore("probe-server-B")
		local okA, pA = sA:Load(U2)
		pA.data.currencies.Credits = 777
		sA:Save(pA)
		local okB, pB = sB:Load(U2)
		check("second server takes over the session from a live lock", okA and okB and pB.stoleLock == true and pB.data.currencies.Credits == 777)
		pA.data.currencies.Credits = 1
		local okOld, codeOld = sA:Save(pA)
		check("old server can no longer overwrite (LOCK_LOST)", okOld == false and codeOld == "LOCK_LOST", codeOld)
		local recB = peek(pB.key)
		check("stored data is the newer session's", type(recB) == "table" and recB.data.currencies.Credits == 777)
		-- 5) shutdown: release every held profile
		local okSh = sB:Release(pB)
		local recSh = peek(pB.key)
		check("shutdown release frees the lock and keeps the data", okSh and type(recSh) == "table" and recSh.meta.session == nil and recSh.data.currencies.Credits == 777)
		-- 6) failure recovery
		local s3 = newStore("probe-server-3")
		local ok3, p3 = s3:Load(U3)
		p3.data.currencies.Credits = 55
		failLeft = 2
		local okT, codeT = s3:Save(p3)
		check("transient failures are retried and the save succeeds", ok3 and okT and failLeft == 0, codeT)
		local before = copy(peek(p3.key))
		p3.data.currencies.Credits = 99999
		failLeft = 50
		local okP, codeP = s3:Save(p3)
		failLeft = 0
		check("persistent failure reports an error and leaves stored data untouched", okP == false and deepEq(copy(peek(p3.key)), before), codeP)
		s3:Release(p3)
	end)
	if not okAll then
		check("probe completed without a script error", false, tostring(err))
	end
	-- cleanup: only this run's probe keys
	for _, u in { U1, U2, U3 } do
		pcall(remove, prefix .. tostring(u))
	end
	table.insert(lines, string.format("RESULT: %d passed, %d failed (probe keys removed)", pass, fail))
	return table.concat(lines, "\n")
end

return Probe
