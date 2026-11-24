--!strict
-- DataEnvironment — owner: Developer B. Decides WHERE profiles are persisted. Safety rules:
--   * Studio                       -> in-memory mock store (default). The real TEST store is used only if
--                                     DataConfig.STUDIO_BACKEND == "test" AND this universe is listed in
--                                     TEST_UNIVERSE_IDS (and not in PRODUCTION) AND a human enabled Studio
--                                     API access in Game Settings. Code never enables that permission.
--   * Live, PRODUCTION universe    -> production store + production keys.
--   * Live, any other universe     -> TEST store name + test key prefix, never production names.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local MockDataStore = require(script.Parent.MockDataStore)

export type Environment = {
	name: string, -- "studio" | "test" | "production"
	persistent: boolean,
	isStudio: boolean,
	universeId: number,
	storeName: string,
	keyPrefix: string,
	backend: any,
}

local DataEnvironment = {}

local cached: Environment? = nil

local function realBackend(storeName: string): any
	local store = DataStoreService:GetDataStore(storeName)
	return {
		kind = "datastore",
		storeName = storeName,
		UpdateAsync = function(_self: any, key: string, transform: (any) -> any): any
			return (store:UpdateAsync(key, function(old)
				return transform(old)
			end))
		end,
	}
end

local function make(name: string, persistent: boolean, backend: any, isStudio: boolean, universeId: number): Environment
	return {
		name = name,
		persistent = persistent,
		isStudio = isStudio,
		universeId = universeId,
		storeName = backend.storeName,
		keyPrefix = DataConfig.KEY_PREFIXES[name],
		backend = backend,
	}
end

-- Pure decision (unit-tested). Returns "studio" | "test" | "production".
function DataEnvironment.decide(isStudio: boolean, universeId: number, cfg: any?): string
	local c = cfg or DataConfig
	local isProd = table.find(c.PRODUCTION_UNIVERSE_IDS, universeId) ~= nil
	if isStudio then
		local isTest = table.find(c.TEST_UNIVERSE_IDS, universeId) ~= nil
		if c.STUDIO_BACKEND == "test" and isTest and not isProd then
			return "test"
		end
		return "studio"
	end
	return if isProd then "production" else "test"
end

function DataEnvironment.resolve(): Environment
	if cached then
		return cached
	end
	local isStudio = RunService:IsStudio()
	local universeId = game.GameId
	local name = DataEnvironment.decide(isStudio, universeId)
	local env: Environment
	if name == "studio" then
		env = make("studio", false, MockDataStore.shared(), true, universeId)
	else
		env = make(name, true, realBackend(DataConfig.STORE_NAMES[name]), isStudio, universeId)
		if name == "test" and not isStudio then
			warn("[PF][Data] universe " .. universeId .. " is not listed as production -> using the TEST data store.")
		end
	end
	cached = env
	return env
end

return DataEnvironment
