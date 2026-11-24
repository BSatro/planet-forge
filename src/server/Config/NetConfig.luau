--!strict
-- NetConfig — owner: Developer B. Limits for client->server remotes handled through Net/RemoteGuard.

local NetConfig = {}

NetConfig.MAX_REQUEST_ID = 2 ^ 31

NetConfig.PAYLOAD = {
	MAX_KEYS = 16, -- total keys across the whole payload
	MAX_DEPTH = 2, -- payload table + one nested table
	MAX_KEY_LENGTH = 32,
	MAX_STRING_LENGTH = 64,
}

-- Token buckets per player per remote: `capacity` burst, refilled at `refillPerSecond`.
NetConfig.RATE_LIMITS = {
	default = { capacity = 5, refillPerSecond = 2 },
	Profile_RequestSnapshot = { capacity = 3, refillPerSecond = 0.5 },
	Economy_SellMaterial = { capacity = 6, refillPerSecond = 3 },
	Economy_PurchaseUpgrade = { capacity = 4, refillPerSecond = 2 },
	Dev_Command = { capacity = 10, refillPerSecond = 5 },
	-- Cosmic Core Hunt (server also enforces the charge, the reload (2.8 s / 3.2 s after a miss), one pulse in
	-- flight and the per-minute capture cap; a legit player fires at most once per ~3.3 s)
	Harvest_Enter = { capacity = 3, refillPerSecond = 0.5 },
	Harvest_Exit = { capacity = 3, refillPerSecond = 0.5 },
	Harvest_Charge = { capacity = 4, refillPerSecond = 1.5 },
	Harvest_Fire = { capacity = 3, refillPerSecond = 1 },
	-- Planet DNA & Evolution (server also enforces busy lock, actionId replay cache, expectedRevision)
	Evolution_React = { capacity = 4, refillPerSecond = 2 },
	Evolution_Commit = { capacity = 2, refillPerSecond = 0.2 },
	Evolution_Cosmetic = { capacity = 3, refillPerSecond = 1 },
	-- Cosmic World Events (server also enforces range, first-capture-wins and the per-player shower cap)
	Event_Action = { capacity = 6, refillPerSecond = 3 },
	Event_Dev = { capacity = 10, refillPerSecond = 5 }, -- bound only in Studio
	-- Social (server also enforces one reaction per visitor per planet, viewing checks and a visit cooldown)
	Social_Action = { capacity = 4, refillPerSecond = 1 },
	-- Store (server also refuses prompts while harvesting / in a rift and never prompts unconfigured items)
	Store_Action = { capacity = 6, refillPerSecond = 1 },
} :: { [string]: { capacity: number, refillPerSecond: number } }

-- Seconds between warnings logged for the same player+remote (log spam protection).
NetConfig.VIOLATION_LOG_INTERVAL = 10

-- Snapshot pushes are coalesced: at most one per player per this many seconds.
NetConfig.SNAPSHOT_THROTTLE = 0.25
NetConfig.SNAPSHOT_VERSION = 1
NetConfig.SNAPSHOT_RECENT_EXPEDITIONS = 10

return NetConfig
