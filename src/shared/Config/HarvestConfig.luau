--!strict
-- HarvestConfig — owner: Gameplay (Cosmic Core Hunt). Every Cosmic Core Hunt number lives here.
-- Shared: the client uses it for visuals/prediction, the server for verification. The server never
-- trusts a client copy.
--
-- Coordinates: "harvester local" space = x right, y up (planet surface normal), z forward (away from the
-- planet's north pole). See Harvest/HarvestLayout.

local HarvestConfig = {}

-- Where the harvester sits on every planet. It always FACES OUTWARD (away from the station) so the lane is
-- open space. Position: POLE_ANGLE_DEG from the north pole, on the station side of the pole, rotated by the
-- first AZIMUTH_OFFSETS_DEG entry that keeps it MIN_SPAWN_SEPARATION_DEG (azimuth) away from the planet
-- spawn (WorldLayout.getPlanetSpawn tilts towards world +X, SPAWN_AZIMUTH_DEG).
HarvestConfig.PLACEMENT = {
	POLE_ANGLE_DEG = 13,
	SPAWN_AZIMUTH_DEG = 0,
	MIN_SPAWN_SEPARATION_DEG = 70,
	AZIMUTH_OFFSETS_DEG = { 0, 30, -30, 60, -60, 90, -90, 120, -120 },
}

-- Points on the device (harvester local space).
HarvestConfig.DEVICE = {
	MUZZLE = Vector3.new(0, 6.9, 8.4),
	COLLECTOR = Vector3.new(0, 7.6, -7.2),
	CONSOLE = Vector3.new(0, 0, -8.5),
	OPERATOR = Vector3.new(0, 0, -10.6),
	HEAD_PIVOT = Vector3.new(0, 6.9, 0),
	CAMERA = Vector3.new(0, 14.5, -19),
	CAMERA_FOCUS = Vector3.new(0, 52, 85),
	CAMERA_FOV = 72,
	CAMERA_AIM_FOLLOW = 0.16, -- camera look-at leans this fraction towards the aim point
	BEACON_HEIGHT = 220,
}

-- Bounded, predictable collection lane in front of / above the harvester.
HarvestConfig.ZONE = {
	HALF_WIDTH = 60, -- visible lane: x in [-60, 60]
	ENTRY_MARGIN = 22, -- meteors enter/leave this far beyond the lane edge
	MIN_HEIGHT = 36,
	MAX_HEIGHT = 90,
	MIN_DEPTH = 60,
	MAX_DEPTH = 112,
	INNER_MARGIN = 8, -- start/end points keep this far inside the height/depth bounds
}

HarvestConfig.OPERATE = {
	PROMPT_DISTANCE = 10,
	ENTER_RADIUS = 16, -- server: character root must be this close to the console to start
	SESSION_RADIUS = 24, -- server: session ends if the character is farther than this
	POLL_INTERVAL = 0.5,
	IDLE_TIMEOUT = 180, -- seconds without a shot -> session closes (no idle meteor farming)
	MAX_SESSION_SECONDS = 3600,
}

HarvestConfig.SHOT = {
	-- Pulse emitter (anti-spam, server-authoritative; METEOR OVERHAUL V2). A shot is: hold FIRE to charge
	-- (the server timestamps the charge start), release after MIN_CHARGE, one pulse in flight, then reload.
	COOLDOWN = 2.8, -- reload after a spent shot that hit (also after an unaffordable hit)
	MISS_COOLDOWN = 3.2, -- reload after a verified miss
	MIN_CHARGE = 0.5, -- server charge start -> fireTime must be at least this (minus latency tolerance)
	CHARGE_TOLERANCE_MAX = 0.2, -- one-way latency allowance on the charge (bounded; never more)
	CHARGE_SLACK = 0.05,
	MAX_CONCURRENT = 1, -- pulses in flight per player
	IN_FLIGHT_TIMEOUT = 2, -- a capture whose reward never settled releases the in-flight lock after this
	COOLDOWN_TOLERANCE = 0.08, -- clock tolerance on reload / charge checks
	MAX_RANGE = 220,
	AIM_CONE_DEG = 4, -- max angle between aim and target centre (plus the target's own angular radius)
	HITBOX_PAD = 2, -- studs added to the target radius for the angular hitbox
	MAX_CLOCK_LEAD = 0.1, -- a claimed fireTime may be at most this far in the server's future...
	MAX_LATENCY = 0.75, -- ...and at most this far in the past
	LATENCY_PING_FACTOR = 0.75, -- allowed lateness = min(MAX_LATENCY, ping * factor + slack)
	LATENCY_SLACK = 0.25,
	PULSE_SPEED = 240, -- studs/s (visual travel only; verification happens at fire time)
	MIN_PULSE_TIME = 0.16,
}

-- Recovery after a miss: each consecutive miss widens the aim cone and the timing window.
HarvestConfig.FOCUS = {
	MAX_STACKS = 2,
	CONE_BONUS_DEG = 2.5, -- per stack
	WINDOW_BONUS = 0.07, -- per stack, in resonance phase units (window opens earlier)
}

-- Client aiming / lock-on (screen fractions are of the viewport height).
HarvestConfig.LOCK = {
	TIME = 0.32,
	TUTORIAL_TIME = 0.18,
	RADIUS_FRAC = 0.055,
	TOUCH_RADIUS_MULT = 1.6,
	GAMEPAD_RADIUS_MULT = 1.35,
	BREAK_FACTOR = 2.2, -- a lock survives until the reticle is this many lock radii away
	SELECT_FRAC = 0.13, -- hover highlight radius
	MAGNET_RATE = 7, -- 1/s reticle pull towards a locked target (gamepad / touch only)
	GAMEPAD_SPEED_FRAC = 0.95, -- reticle speed at full stick (viewport heights per second)
	KEYBOARD_SPEED_FRAC = 0.65,
	GAMEPAD_DEADZONE = 0.15,
}

-- Resonance ring: shrinks from RING_MAX to RING_MIN (x target marker size) once per period.
-- Firing while the ring is inside the window band captures; the perfect band gives a bonus.
HarvestConfig.RESONANCE = { RING_MAX = 2.6, RING_MIN = 0.55 }

HarvestConfig.QUALITY_MULTIPLIER = { perfect = 1.5, good = 1.0 } :: { [string]: number }

---------------------------------------------------------------- METEOR OVERHAUL V2: variants + rarity
-- Lane speed of a COMMON meteor (studs/s). A variant flies at BASE x speedMultiplier (x 1 +/- SPAWN.SPEED_JITTER).
-- Patterns may vary the instantaneous speed (Stellar brakes mid-lane) but the crossing average is the multiplier.
HarvestConfig.SPEED = { BASE = 15 }

-- Rarity tiers. speedMin/speedMax bound each variant's speedMultiplier (checked by MeteorRegistry.validate).
-- aimBonusDeg / hitboxPad widen the aim cone / angular hitbox so faster meteors stay capturable. The same
-- numbers run on the client (prediction) and the server (verification).
HarvestConfig.RARITIES = {
	common = { order = 1, label = "COMMON", color = Color3.fromRGB(205, 215, 230), speedMin = 1.0, speedMax = 1.0, aimBonusDeg = 0, hitboxPad = 0 },
	uncommon = { order = 2, label = "UNCOMMON", color = Color3.fromRGB(110, 235, 140), speedMin = 1.2, speedMax = 1.4, aimBonusDeg = 0.5, hitboxPad = 0.5 },
	rare = { order = 3, label = "RARE", color = Color3.fromRGB(90, 170, 255), speedMin = 1.5, speedMax = 1.8, aimBonusDeg = 1.0, hitboxPad = 1.0 },
	epic = { order = 4, label = "EPIC", color = Color3.fromRGB(195, 115, 255), speedMin = 1.9, speedMax = 2.1, aimBonusDeg = 1.5, hitboxPad = 1.5 },
	legendary = { order = 5, label = "LEGENDARY", color = Color3.fromRGB(255, 190, 70), speedMin = 2.2, speedMax = 2.2, aimBonusDeg = 2.0, hitboxPad = 2.0 },
	mythic = { order = 6, label = "MYTHIC", color = Color3.fromRGB(255, 85, 130), speedMin = 2.3, speedMax = 2.3, aimBonusDeg = 2.5, hitboxPad = 2.5 },
	secret = { order = 7, label = "SECRET", color = Color3.fromRGB(120, 255, 235), speedMin = 2.4, speedMax = 2.4, aimBonusDeg = 3.0, hitboxPad = 3.0 },
} :: { [string]: any }
HarvestConfig.RARITY_ORDER = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "secret" }

-- Meteor variant registry (data only; read through Harvest/MeteorRegistry, which resolves ALIASES).
--   rarity, displayName, category, color (marker / trail / light), theme { builder, accent } (visual theme;
--   Developer A may override any variant with ReplicatedStorage.PF_Assets.Meteors.<id>, see the contract)
--   speedMultiplier (x SPEED.BASE), size (hitbox diameter, studs), patterns { pattern = weight }
--   period / window / perfect: resonance timing (window and perfect are phase fractions of the period)
--   rewardCategory "material": `resource` (an EXISTING ItemCatalog material) x `multiplier`, granted only by
--     EconomyService:RewardHarvest (perfect x QUALITY_MULTIPLIER, bounded by HARVEST.MAX_MULTIPLIER)
--   sfx { impact, pitch } (HarvestAudio ids)   vfx { light, trail }
--   unlock: EvolutionRules condition on the OWNER's planet (progression eligibility; nil = always)
--   weight: spawn weight (eligible weights are renormalized)   discovery: first-capture discovery id
--   telegraph: seconds of warning before the meteor enters   special: optional behaviour id
HarvestConfig.TARGET_TYPES = {
	Ice = {
		enabled = true, rarity = "common", category = "meteor", displayName = "Ice Meteor",
		color = Color3.fromRGB(150, 225, 255), theme = { builder = "Ice", accent = Color3.fromRGB(220, 245, 255) },
		speedMultiplier = 1.0, size = 7, patterns = { drift = 70, arc = 30 },
		period = 1.7, window = { 0.55, 0.9 }, perfect = { 0.69, 0.79 },
		rewardCategory = "material", resource = "IceMatter", multiplier = 1.0,
		sfx = { impact = "iceHit", pitch = 1.0 }, vfx = { light = 1.8, trail = 0.7 },
		tags = { "water", "cooling" }, discovery = "FrozenCore", weight = 24,
	},
	Magma = {
		enabled = true, rarity = "common", category = "meteor", displayName = "Magma Meteor",
		color = Color3.fromRGB(255, 120, 40), theme = { builder = "Magma", accent = Color3.fromRGB(255, 190, 90) },
		speedMultiplier = 1.0, size = 6.5, patterns = { arc = 55, drift = 20, weave = 25 },
		period = 1.5, window = { 0.56, 0.89 }, perfect = { 0.69, 0.78 },
		rewardCategory = "material", resource = "MagmaMatter", multiplier = 1.2,
		sfx = { impact = "impact", pitch = 0.85 }, vfx = { light = 1.8, trail = 0.7 },
		tags = { "thermal" }, discovery = "MoltenHeart", weight = 20,
	},
	Plasma = {
		enabled = true, rarity = "uncommon", category = "meteor", displayName = "Plasma Meteor",
		color = Color3.fromRGB(210, 110, 255), theme = { builder = "Plasma", accent = Color3.fromRGB(255, 120, 230) },
		speedMultiplier = 1.4, size = 5.5, patterns = { weave = 55, spiral = 45 },
		period = 1.15, window = { 0.58, 0.88 }, perfect = { 0.7, 0.78 },
		rewardCategory = "material", resource = "PlasmaMatter", multiplier = 1.6,
		sfx = { impact = "impact", pitch = 1.2 }, vfx = { light = 2.6, trail = 0.7 },
		tags = { "energy" }, discovery = "PlasmaBloom", weight = 16,
	},
	Crystal = {
		enabled = true, rarity = "uncommon", category = "meteor", displayName = "Crystal Meteor",
		color = Color3.fromRGB(255, 150, 230), theme = { builder = "Crystal", accent = Color3.fromRGB(150, 230, 255) },
		speedMultiplier = 1.25, size = 5.5, patterns = { drift = 40, arc = 40, weave = 20 },
		period = 1.35, window = { 0.57, 0.88 }, perfect = { 0.69, 0.78 },
		rewardCategory = "material", resource = "CrystalFragments", multiplier = 1.15,
		sfx = { impact = "iceHit", pitch = 1.3 }, vfx = { light = 1.8, trail = 0.7 },
		tags = { "mineral" }, discovery = "PrismaticShard", weight = 12,
	},
	-- Legacy id "Spore" (Spore Cloud) resolves here through ALIASES.
	Bio = {
		enabled = true, rarity = "uncommon", category = "spore", displayName = "Bio Spore Cloud",
		color = Color3.fromRGB(120, 255, 140), theme = { builder = "Bio", accent = Color3.fromRGB(220, 255, 120) },
		speedMultiplier = 1.2, size = 6.5, patterns = { drift = 55, weave = 45 },
		period = 1.5, window = { 0.55, 0.9 }, perfect = { 0.68, 0.79 },
		-- x1.8 (was 1.1 at weight 26): keeps the Living branch on its pre-V2 pacing at the new weight 10
		rewardCategory = "material", resource = "BioEssence", multiplier = 1.8,
		sfx = { impact = "impact", pitch = 1.4 }, vfx = { light = 1.6, trail = 0.8 },
		tags = { "organic" }, discovery = "LivingSpores", weight = 10,
		unlock = { dna = { Water = { min = 20 } } },
		unlockHint = "Bio spore clouds are drawn to planets with Water 20+.",
	},
	Iron = {
		enabled = true, rarity = "uncommon", category = "meteor", displayName = "Iron Meteor",
		color = Color3.fromRGB(200, 170, 140), theme = { builder = "Iron", accent = Color3.fromRGB(255, 140, 60) },
		speedMultiplier = 1.3, size = 7.5, patterns = { drift = 60, arc = 40 },
		period = 1.4, window = { 0.58, 0.87 }, perfect = { 0.7, 0.77 },
		rewardCategory = "material", resource = "CrystalFragments", multiplier = 1.2,
		sfx = { impact = "impact", pitch = 0.6 }, vfx = { light = 1.4, trail = 0.6 },
		tags = { "mineral", "metal" }, discovery = "IronHeart", weight = 7,
	},
	Magnetic = {
		enabled = true, rarity = "rare", category = "meteor", displayName = "Magnetic Meteor", special = "magnetic",
		color = Color3.fromRGB(120, 170, 255), theme = { builder = "Magnetic", accent = Color3.fromRGB(255, 90, 90) },
		speedMultiplier = 1.6, size = 6, patterns = { magnetic = 100 },
		period = 1.2, window = { 0.58, 0.88 }, perfect = { 0.7, 0.78 },
		rewardCategory = "material", resource = "PlasmaMatter", multiplier = 2.2,
		sfx = { impact = "impact", pitch = 1.1 }, vfx = { light = 2.2, trail = 0.8 },
		tags = { "energy", "magnetic" }, discovery = "MagneticCore", weight = 4,
		unlock = { stage = { min = 1 } },
		unlockHint = "Magnetic meteors are drawn to Stage 1+ worlds.",
	},
	Split = {
		enabled = true, rarity = "rare", category = "meteor", displayName = "Split Meteor", special = "split",
		color = Color3.fromRGB(255, 170, 80), theme = { builder = "Split", accent = Color3.fromRGB(255, 220, 140) },
		speedMultiplier = 1.5, size = 7, patterns = { drift = 100 },
		period = 1.3, window = { 0.57, 0.88 }, perfect = { 0.69, 0.78 },
		rewardCategory = "material", resource = "MagmaMatter", multiplier = 2.0, -- each fragment: x SPLIT.FRAGMENT_REWARD
		sfx = { impact = "impact", pitch = 0.75 }, vfx = { light = 2.0, trail = 0.7 },
		tags = { "thermal", "split" }, discovery = "TwinShard", weight = 3,
		unlock = { stage = { min = 1 } },
		unlockHint = "Split meteors are drawn to Stage 1+ worlds.",
	},
	Comet = {
		enabled = true, rarity = "epic", category = "comet", displayName = "Cosmic Comet", special = "flyby",
		color = Color3.fromRGB(255, 235, 150), theme = { builder = "Comet", accent = Color3.fromRGB(255, 200, 90) },
		speedMultiplier = 2.0, size = 6, patterns = { flyby = 100 },
		period = 1.0, window = { 0.58, 0.9 }, perfect = { 0.7, 0.79 },
		rewardCategory = "material", resource = "CosmicCatalyst", multiplier = 1.0,
		sfx = { impact = "impact", pitch = 1.3 }, vfx = { light = 2.4, trail = 1.1 },
		tags = { "rare" }, discovery = "CometHeart", weight = 2, telegraph = 0.8,
		unlock = { stage = { min = 2 } },
		unlockHint = "Cosmic comets visit Terraforming worlds (Stage 2+).",
		behavior = "capture", -- future: "redirect" (pulse deflects it into a planet orbit)
	},
	Stellar = {
		enabled = true, rarity = "legendary", category = "meteor", displayName = "Stellar Meteor", special = "stellar",
		color = Color3.fromRGB(255, 225, 140), theme = { builder = "Stellar", accent = Color3.fromRGB(255, 255, 230) },
		speedMultiplier = 2.2, size = 7, patterns = { stellar = 100 },
		period = 1.1, window = { 0.56, 0.9 }, perfect = { 0.69, 0.79 },
		rewardCategory = "material", resource = "PlasmaMatter", multiplier = 3.0,
		sfx = { impact = "impact", pitch = 1.5 }, vfx = { light = 3.2, trail = 1.0 },
		tags = { "energy", "rare" }, discovery = "StellarCore", weight = 1, telegraph = 1.4,
		unlock = { stage = { min = 1 } },
		unlockHint = "Stellar meteors are drawn to Stage 1+ worlds.",
	},
	Void = {
		enabled = true, rarity = "mythic", category = "meteor", displayName = "Void Meteor", special = "void",
		color = Color3.fromRGB(170, 90, 255), theme = { builder = "Void", accent = Color3.fromRGB(40, 10, 70) },
		speedMultiplier = 2.3, size = 6.5, patterns = { void = 100 },
		period = 1.0, window = { 0.56, 0.9 }, perfect = { 0.69, 0.79 },
		rewardCategory = "material", resource = "CosmicCatalyst", multiplier = 2.0,
		sfx = { impact = "impact", pitch = 0.5 }, vfx = { light = 2.0, trail = 0.9 },
		tags = { "rare", "void" }, discovery = "VoidEcho", weight = 0.7, telegraph = 1.0,
		unlock = { stage = { min = 2 } },
		unlockHint = "Void meteors visit Stage 2+ worlds.",
	},
	Astral = {
		enabled = true, rarity = "secret", category = "meteor", displayName = "Astral Meteor", special = "slingshot",
		color = Color3.fromRGB(150, 255, 240), theme = { builder = "Astral", accent = Color3.fromRGB(255, 160, 255) },
		speedMultiplier = 2.4, size = 6, patterns = { slingshot = 100 },
		period = 0.9, window = { 0.55, 0.92 }, perfect = { 0.68, 0.8 },
		rewardCategory = "material", resource = "CosmicCatalyst", multiplier = 3.0,
		sfx = { impact = "impact", pitch = 1.8 }, vfx = { light = 2.8, trail = 1.2 },
		tags = { "rare", "astral" }, discovery = "AstralSpark", weight = 0.3, telegraph = 1.0,
		unlock = { stage = { min = 3 } },
		unlockHint = "Astral meteors visit Stage 3+ worlds.",
	},
} :: { [string]: any }

-- Spawn / display order (weights are applied in this order). Legacy ids resolve through ALIASES.
HarvestConfig.TYPE_ORDER = { "Ice", "Magma", "Plasma", "Crystal", "Bio", "Iron", "Magnetic", "Split", "Comet", "Stellar", "Void", "Astral" }
HarvestConfig.ALIASES = { Spore = "Bio" } :: { [string]: string }

-- A specialized planet attracts more of its own matter (spawn weight multipliers by planet branch).
HarvestConfig.BRANCH_WEIGHT_MULTIPLIERS = {
	Living = { Bio = 1.5, Ice = 1.2 },
	Frozen = { Ice = 1.6 },
	Volcanic = { Magma = 1.6 },
	Crystal = { Crystal = 1.5, Plasma = 1.2 },
} :: { [string]: { [string]: number } }

HarvestConfig.PATTERNS = {
	drift = {},
	arc = { LIFT_MIN = 12, LIFT_MAX = 24, BEND = 16 },
	weave = { AMP_MIN = 6, AMP_MAX = 11, CYCLES_MIN = 1.5, CYCLES_MAX = 2.5 },
	spiral = { RADIUS_MIN = 6, RADIUS_MAX = 10, TURNS_MIN = 1.5, TURNS_MAX = 2.5 },
	pingpong = { PERIOD = 14, AMPLITUDE_FRAC = 0.55, BOB = 3 },
	-- Comet: straight diagonal flyby (high -> low or low -> high) with a depth change
	flyby = { DROP_MIN = 22, DROP_MAX = 34 },
	-- Magnetic: two smooth, server-scheduled course corrections (fractions of the flight); the client
	-- telegraphs each one WARN seconds ahead
	magnetic = { AMP_MIN = 8, AMP_MAX = 13, FIRST = { 0.26, 0.34 }, SECOND = { 0.56, 0.64 }, WIDTH = 0.1, WARN = 0.35 },
	-- Stellar: fast entry, brakes through the middle of the lane (speed factor 1 + BRAKE cos 2pi u), gentle lift
	stellar = { BRAKE = 0.35, LIFT_MIN = 6, LIFT_MAX = 14 },
	-- Void: zigzag + deterministic phase-outs locked to its own resonance rhythm: on every PHASE_STRIDE-th
	-- cycle it is phased out (invisible, NOT capturable) while the ring phase is in [PHASE_FROM, PHASE_TO],
	-- i.e. right after the ring restarts. PHASE_TO stays below the earliest window start (max focus), so a
	-- phase-out never hides the capture window: it vanishes as the ring starts closing and reappears before
	-- the green band. WARN = client shimmer before each phase-out.
	void = { AMP_MIN = 5, AMP_MAX = 9, CYCLES_MIN = 2, CYCLES_MAX = 3, PHASE_STRIDE = 1, PHASE_FROM = 0.06, PHASE_TO = 0.36, PHASE_START = 0.5, WARN = 0.25 },
	-- Astral: crosses the lane, turns at the far edge (outside the lane) and crosses back
	slingshot = { TURN_DY_MIN = 14, TURN_DY_MAX = 24 },
} :: { [string]: any }
HarvestConfig.PATTERN_ORDER = { "drift", "arc", "weave", "spiral", "pingpong", "flyby", "magnetic", "stellar", "void", "slingshot" }

-- Split meteor: flies FRACTION of the lane, then breaks into FRAGMENTS smaller, faster pieces. Fragments are
-- issued together with the parent (server-authored); capturing the parent first cancels them.
HarvestConfig.SPLIT = {
	FRACTION_MIN = 0.42,
	FRACTION_MAX = 0.52,
	FRAGMENTS = 2,
	FRAGMENT_SPEED = 1.15,
	FRAGMENT_SIZE = 0.62,
	FRAGMENT_REWARD = 0.6, -- reward multiplier of each fragment relative to the parent
	SPREAD_Y = 16,
	SPREAD_Z = 10,
}

HarvestConfig.SPAWN = {
	FIRST_DELAY = 0.5, -- first meteor after starting a session
	LEAD = 0.3, -- meteors are announced this long before t0 (they start outside the lane anyway)
	MIN_ACTIVE = 2, -- never fewer than this many meteors in flight (a split parent + its fragments count once)
	MAX_ACTIVE = 3,
	INTERVAL_MIN = 2.2,
	INTERVAL_MAX = 3.4,
	MIN_GAP = 0.9, -- minimum seconds between two spawns
	SPEED_JITTER = 0.05, -- +/- fraction (applied on top of the rarity speed multiplier)
	SIZE_JITTER = 0.12,
	STREAK_DAMPING = 1.0, -- 1 = off: spawn odds are exactly the renormalized weights (no pity, no anti-streak)
	MAX_SPAWNS_PER_MINUTE = 30, -- hard bound per player (the normal stream is ~20/min); survives re-entry
	DORMANT_TTL = 90, -- an exited session's stream / focus resume if re-entered within this (no re-rolls)
	EXPIRE_GRACE = 1.0, -- server keeps expired specs this long (late claims resolve as misses)
	ISSUED_RETENTION = 30, -- issued / claimed ids are forgotten this long after their target expired
	TICK_INTERVAL = 0.2,
}

HarvestConfig.LIMITS = {
	MAX_CAPTURES_PER_MINUTE = 15,
	MAX_ISSUED_PER_SESSION = 2000, -- hard stop for runaway sessions
}

-- First-capture tutorial: one slow Ice meteor swinging across the lane with a wide window.
HarvestConfig.TUTORIAL = {
	ENABLED = true,
	TYPE = "Ice",
	PATTERN = "pingpong",
	DURATION = 90,
	PERIOD = 2.0,
	WINDOW = { 0.45, 0.95 },
	PERFECT = { 0.66, 0.8 },
	SIZE = 8,
	HEIGHT = 58,
	DEPTH = 82,
}

-- Seasonal / live phenomena. Set ACTIVE_EVENT to an id to apply its modifiers.
HarvestConfig.EVENTS = {
	MeteorShower = { spawnIntervalMultiplier = 0.65, weightMultipliers = { Plasma = 2 }, rewardMultiplier = 1.0 },
	CometSeason = { spawnIntervalMultiplier = 1.0, weightMultipliers = {}, enableTypes = { "Comet" }, rewardMultiplier = 1.0 },
} :: { [string]: any }
HarvestConfig.ACTIVE_EVENT = nil :: string?

-- Expansion hooks (read by HarvestSessionCore; upgrade ids that don't exist yet resolve to level 0).
HarvestConfig.UPGRADE_HOOKS = {
	LockAssist = { upgradeId = "HarvesterLockAssist", coneBonusDegPerLevel = 0.4 },
}
HarvestConfig.COOP = { ENABLED = false, WINDOW = 0.6, MAX_PARTICIPANTS = 4 }

return HarvestConfig
