--!strict
-- DataConfig — owner: Developer B. Persistence settings. SERVER ONLY.
--
-- ENVIRONMENT SAFETY (see Data/DataEnvironment):
--   * Data stores are per-experience (universe). Production data must live in the live experience; test
--     data in a SEPARATE test experience. List each universe id below.
--   * A universe NOT in PRODUCTION_UNIVERSE_IDS never touches the production store name/keys.
--   * Studio defaults to the in-memory mock store. Nothing here enables Studio API access — that is a
--     manual Game Settings toggle a human must make, and only for the TEST experience.

local DataConfig = {}

-- Universe (GameId) of the LIVE experience: an ARRAY of numbers, checked with table.find(list, game.GameId).
-- PRODUCTION IS PREPARED BUT NOT ACTIVE (owner decision, 2026-11-22): activate only after the owner confirmed the
-- universe AND the private-test DataStore pass (TASKS Q-7.8) succeeded. Until then every live server of every
-- universe (this one included) uses the TEST store name + test key prefix, and nothing can reach production keys.
-- To activate: set PRODUCTION_UNIVERSE_IDS = { PRODUCTION_UNIVERSE_ID_PENDING }, run D1.spec, save, publish.
-- Studio sessions stay on the in-memory mock either way (DataEnvironment.decide never returns "production" in Studio).
DataConfig.PRODUCTION_UNIVERSE_IDS = {} :: { number }
-- 10778085398 = PLANET FORGE: COSMIC EVOLUTION (root place 79132282456701, owner user 8319150623, visibility PRIVATE),
-- verified 2026-11-22 in Studio (game.GameId / game.PlaceId) and through Open Cloud (universe + place read).
DataConfig.PRODUCTION_UNIVERSE_ID_PENDING = 10778085398
-- The separate PRIVATE TEST experience(s). Listing a universe here (1) lets Studio use the real *test* store when
-- STUDIO_BACKEND = "test" and (2) is the ONLY way developer commands work on live servers (DevCommandService).
-- Never list the production universe: it is refused for both.
DataConfig.TEST_UNIVERSE_IDS = {} :: { number }

-- "mock" (default, in-memory, nothing persisted) | "test" (real test store; needs the checks above)
DataConfig.STUDIO_BACKEND = "mock"

DataConfig.STORE_NAMES = {
	production = "PF_Profiles_v1",
	test = "PF_TEST_Profiles_v1",
	studio = "PF_MOCK_Profiles",
}
DataConfig.KEY_PREFIXES = {
	production = "u_",
	test = "test_u_",
	studio = "mock_u_",
}

-- Saving cadence
DataConfig.AUTOSAVE_INTERVAL = 120 -- seconds between autosave sweeps
DataConfig.AUTOSAVE_MAX_GAP = 10 -- max seconds between two profiles within a sweep (staggering)
DataConfig.MANUAL_SAVE_COOLDOWN = 30 -- min seconds between explicit SaveNow calls per player

-- Session locking
DataConfig.SESSION_LOCK_STALE_AFTER = 600 -- a lock not refreshed for this long belongs to a dead server
DataConfig.LOAD_LOCK_RETRIES = 5 -- times to wait for a foreign fresh lock before taking it over
DataConfig.LOAD_LOCK_RETRY_DELAY = 6 -- seconds between those attempts (~30 s total, covers teleports)
DataConfig.REJOIN_RELEASE_WAIT = 20 -- max seconds a rejoin waits for this server's own pending release

-- Request retries (per request, inside DataStoreGateway)
DataConfig.REQUEST_RETRIES = 4 -- extra attempts after the first
DataConfig.RETRY_BASE_DELAY = 1 -- seconds, doubled each attempt
DataConfig.RETRY_MAX_DELAY = 8
DataConfig.BUDGET_WAIT_MAX = 10 -- max seconds to wait for request budget before trying anyway
DataConfig.BUDGET_POLL_INTERVAL = 0.5

-- Release (final save) retries on leave, on top of request retries
DataConfig.RELEASE_ATTEMPTS = 3
DataConfig.RELEASE_RETRY_DELAY = 3

-- Shutdown
DataConfig.SHUTDOWN_TIMEOUT = 25 -- BindToClose budget is 30 s
DataConfig.SHUTDOWN_RELEASE_ATTEMPTS = 1

-- Values
DataConfig.MAX_TIMESTAMP = 4_102_444_800 -- 2100-01-01; larger timestamps are treated as corrupt
DataConfig.MAX_RECORD_BYTES = 3_500_000 -- refuse to save above this (limit is 4 MB)
DataConfig.EXPEDITION_HISTORY_MAX = 50

-- Load failure handling
-- Transient failures put the player in a RESTRICTED state (no writes possible, nothing overwritten) and
-- retry; only after the retries fail is the player kicked (rejoin is safe: the saved data is untouched).
DataConfig.RETRYABLE_LOAD_CODES = { DATASTORE_ERROR = true, LOCKED = true } :: { [string]: boolean }
DataConfig.LOAD_RETRY_ATTEMPTS = 3
DataConfig.LOAD_RETRY_INTERVAL = 15 -- seconds
DataConfig.KICK_ON_LOAD_FAILURE = true
DataConfig.KICK_MESSAGES = {
	SERVER_FULL = "This server is full (8 planets). Please join another server.",
	LOAD_FAILED = "We couldn't load your planet data. Nothing was lost — please rejoin in a moment.",
	DATASTORE_ERROR = "Roblox data services are not responding. Nothing was lost — please rejoin in a moment.",
	LOCKED = "Your planet is still open on another server. Please rejoin in a moment.",
	FUTURE_SCHEMA = "This server is out of date. Please rejoin to get a newer server.",
	LOCK_LOST = "Your planet was opened on another server, so this session was closed to protect your data.",
	SHUTTING_DOWN = "This server is shutting down. Please rejoin.",
	CORRUPT_RECORD = "We couldn't read your saved planet safely, so it was left untouched. Please contact support.",
} :: { [string]: string }

return DataConfig
