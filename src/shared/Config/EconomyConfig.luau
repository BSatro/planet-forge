--!strict
-- EconomyConfig — owner: Developer B. EVERY economy number lives here (prototype values — tune freely).
-- Growth is deliberately bounded: all upgrades have a max level, the XP curve is polynomial (not
-- exponential), balances have hard caps, and single transactions have a hard size limit.
-- Readable by clients (UI shows costs); the server never trusts client copies.

local EconomyConfig = {}

-- New-player starting kit (applied only when a profile is created).
EconomyConfig.STARTING_BALANCES = {
	currencies = { Credits = 250, CosmicEnergy = 100 },
	materials = { IceMatter = 10, MagmaMatter = 10, PlasmaMatter = 10, CrystalFragments = 4 },
	catalysts = { FrostSeed = 1, EmberCore = 1, IonSpark = 1 },
}

-- Hard storage caps. CosmicEnergy also has a dynamic *live* cap (see ENERGY); this is the absolute ceiling.
EconomyConfig.BALANCE_CAPS = {
	currencies = { Credits = 1_000_000_000, CosmicEnergy = 10_000 },
	currencyDefault = 1_000_000_000,
	material = 10_000_000,
	catalystDefault = 99,
	counter = 2_000_000_000, -- stats / play time / login counters
}

-- Any single delta larger than this (absolute) is rejected outright.
EconomyConfig.MAX_TRANSACTION_AMOUNT = 10_000_000

-- Transactions kept in the per-session debug ledger (memory only, not persisted).
EconomyConfig.LEDGER_SIZE = 50

EconomyConfig.LEVEL = {
	MAX_LEVEL = 50,
	-- XP needed to go from level L to L+1 = round(XP_BASE * L ^ XP_EXPONENT)
	--   L1: 100, L5: ~1030, L10: ~2820, L25: ~10650, L49: ~28200 (total to 50 ~= 590k)
	XP_BASE = 100,
	XP_EXPONENT = 1.45,
	MAX_XP_GRANT = 100_000, -- per call
	-- Credits granted when reaching level L = BASE + PER_LEVEL * L
	REWARD_CREDITS_BASE = 50,
	REWARD_CREDITS_PER_LEVEL = 25,
	REFILL_ENERGY_ON_LEVEL_UP = true,
}

EconomyConfig.ENERGY = {
	BASE_CAP = 100,
	CAP_PER_PLAYER_LEVEL = 5,
	REGEN_PER_MINUTE = 6, -- 1 energy every 10 s, online and offline (offline is bounded by the cap)
	TICK_INTERVAL = 10, -- seconds between server regen ticks for online players
}

EconomyConfig.HARVEST = {
	BASE_YIELD = { IceMatter = 3, MagmaMatter = 3, PlasmaMatter = 2, CrystalFragments = 2, BioEssence = 2, CosmicCatalyst = 1 },
	XP_PER_HARVEST = 12,
	ENERGY_COST = 4,
	MIN_ENERGY_COST = 1,
	MIN_COST_MULTIPLIER = 0.4, -- HarvestEfficiency can never reduce cost below 40%
	LEVEL_YIELD_BONUS = 0.02, -- +2% yield per player level above 1 (linear)
	MAX_MULTIPLIER = 5, -- node-quality/event multiplier the harvesting system may pass (server side)
}

-- Credits per unit when selling.
EconomyConfig.SELL_PRICES = { IceMatter = 4, MagmaMatter = 5, PlasmaMatter = 8, CrystalFragments = 7, BioEssence = 7 } -- CosmicCatalyst: not sellable
EconomyConfig.MAX_SELL_PER_REQUEST = 10_000

-- First-time discovery reward.
EconomyConfig.DISCOVERY_REWARD = { credits = 60, xp = 30 }

-- Upgrades: credit cost to go from level L to L+1 = round(baseCost * costGrowth ^ L), capped by maxLevel.
-- materialCosts[id] = base + perLevel * L (linear).
EconomyConfig.UPGRADES = {
	HarvestYield = {
		displayName = "Harvest Yield",
		maxLevel = 20,
		minPlayerLevel = 1,
		baseCost = 150,
		costGrowth = 1.28, -- L19 -> 20 costs ~16.3k; whole track ~74k credits
		effectPerLevel = 0.15, -- +15% yield per level (linear)
		materialCosts = { IceMatter = { base = 5, perLevel = 3 } },
	},
	EnergyCapacity = {
		displayName = "Energy Capacity",
		maxLevel = 15,
		minPlayerLevel = 2,
		baseCost = 200,
		costGrowth = 1.30,
		effectPerLevel = 10, -- +10 max energy per level
		materialCosts = { PlasmaMatter = { base = 4, perLevel = 2 } },
	},
	HarvestEfficiency = {
		displayName = "Harvest Efficiency",
		maxLevel = 10,
		minPlayerLevel = 3,
		baseCost = 300,
		costGrowth = 1.35,
		effectPerLevel = 0.06, -- -6% energy cost per level (floored by MIN_COST_MULTIPLIER)
		materialCosts = { MagmaMatter = { base = 6, perLevel = 3 } },
	},
} :: { [string]: any }

-- Whitelisted transaction reasons (audit trail; unknown reasons are rejected).
EconomyConfig.REASONS = {
	Harvest = true,
	Sell = true,
	Upgrade = true,
	LevelUp = true,
	Discovery = true,
	Catalyst = true,
	Quest = true,
	Expedition = true,
	Dna = true,
	Evolution = true, -- reaction costs + first-discovery material rewards (one atomic transaction)
	Mastery = true,
	StageUp = true,
	Event = true, -- Cosmic World Events rewards (meteor captures, solar surges, convergence shares)
	Dev = true,
} :: { [string]: boolean }

return EconomyConfig
