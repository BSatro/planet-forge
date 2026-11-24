--!strict
-- RiftConfig — owner: Mission Systems (Cosmic Rifts). All tuning for THE FRACTURED NEBULA expedition.
-- Shared (client reads names/texts/timers for the HUD; server enforces everything).
local RiftConfig = {}

RiftConfig.EXPEDITION_ID = "FracturedNebula"
RiftConfig.NAME = "The Fractured Nebula"

-- Arena instances: one slot per concurrent run, far from the station/planets, each with its own flat gravity box.
RiftConfig.ARENA_ORIGIN = Vector3.new(5000, 3000, 5000)
RiftConfig.ARENA_SPACING = 1400 -- along +X
RiftConfig.MAX_RUNS = 8
RiftConfig.MAX_PLAYERS = 8
RiftConfig.FIELD_HALF = Vector3.new(340, 220, 340)
RiftConfig.KILL_DEPTH = 70 -- below the arena origin = fell into the void
RiftConfig.BOUNDS_RADIUS = 330

function RiftConfig.arenaOrigin(slot: number): Vector3
	return RiftConfig.ARENA_ORIGIN + Vector3.new((slot - 1) * RiftConfig.ARENA_SPACING, 0, 0)
end

-- Flow / timing (seconds)
RiftConfig.LOBBY_SECONDS = 8 -- forming countdown at the station portal (others may join)
RiftConfig.TIME_LIMIT = 480 -- rift collapses (failure) after 8:00
RiftConfig.SWIFT_TIME = 240
RiftConfig.ESCAPE_SECONDS = 25 -- after the core is sealed, auto-escape for anyone left
RiftConfig.RESTART_WINDOW = 180 -- "run again" allowed this long after a run ended
RiftConfig.PORTAL_RADIUS = 34 -- max distance from the station portal to start / join
RiftConfig.MIN_ACTIVE_SECONDS = 45 -- participation: time spent in the arena to earn rewards

-- Objectives
RiftConfig.NODE = { radius = 12, channel = 4, coopBonus = 0.5, maxSpeedup = 2.5, decay = 0.6 }
RiftConfig.FINAL = { radius = 21, channel = 8 }
RiftConfig.RELAY = { radius = 5.5, hold = 3 }
RiftConfig.EXIT = { radius = 7 }
RiftConfig.FRAGMENTS = { base = 12, perExtraPlayer = 3, max = 30, pickupRadius = 8 }
function RiftConfig.nodeCost(players: number): number
	return 3 + math.floor((math.max(1, players) - 1) / 2)
end
function RiftConfig.fragmentCount(players: number): number
	return math.min(RiftConfig.FRAGMENTS.max, RiftConfig.FRAGMENTS.base + RiftConfig.FRAGMENTS.perExtraPlayer * (math.max(1, players) - 1))
end

-- Hazards (layout picks per stone; never two hazards in a row, first/last stones safe)
RiftConfig.HAZARDS = {
	crumbleChance = 0.22,
	sweeperChance = 0.14,
	crumbleDelay = 0.7,
	crumbleRespawn = 4,
	sweeperSpeed = { 1.5, 2.5 }, -- rad/s
	knockback = 65,
	knockbackCooldown = 1.2,
}

-- Anti-exploit (server samples every member's root)
RiftConfig.SECURITY = { sampleHz = 10, maxSpeed = 80, maxFallSpeed = 260, tolerance = 16, maxViolations = 6 }

-- Secondary objectives: 2 per solo run, 3 per co-op run (at least one co-op task when 2+ explorers).
RiftConfig.SECONDARIES = {
	flawless = { name = "Flawless Flight", text = "No explorer falls into the void", solo = true },
	swift = { name = "Swift Stabilizer", text = "Seal the core within 4:00", solo = true },
	collector = { name = "Fragment Hoarder", text = "Collect every energy fragment", solo = true },
	prism = { name = "Hidden Prism", text = "Find the hidden Nebula Prism", solo = true },
	sync = { name = "Synchronized Pulse", text = "Stabilize a node with 2+ explorers inside", coop = true },
	relay = { name = "Resonance Relay", text = "Hold both resonance pads at the same time", coop = true },
}
RiftConfig.SECONDARY_ORDER = { "flawless", "swift", "collector", "prism", "sync", "relay" }

-- Rewards (server rolls with a per-run+player seed; granted through EconomyService, reason "Expedition")
RiftConfig.REWARDS = {
	credits = { base = 140, perSecondary = 30, perFragment = 4, max = 340 },
	energy = { base = 35, perSecondary = 10 }, -- Harvest Energy, clipped to the player's cap
	xp = { base = 80, perSecondary = 20 },
	coopBonusPerExtra = 0.08,
	coopBonusMax = 0.24,
	catalystChance = { base = 0.45, perSecondary = 0.15, max = 0.95 },
	catalysts = { "EmberCore", "FrostSeed", "IonSpark" },
	componentId = "CosmicCatalyst", -- "rift component": rare, guaranteed when the Hidden Prism is found
	componentChance = 0.12,
	cacheChance = 0.5, -- bonus matter cache
	cacheMaterials = { "IceMatter", "MagmaMatter", "PlasmaMatter", "CrystalFragments", "BioEssence" },
	cacheAmount = { 3, 7 },
	failCreditsPerNode = 20,
}

return table.freeze(RiftConfig)
