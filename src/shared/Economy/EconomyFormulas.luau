--!strict
-- EconomyFormulas — owner: Developer B. Pure, deterministic formulas. Every constant comes from
-- EconomyConfig. Safe on server and client (UI previews); the server is the only authority.

local EconomyConfig = require(script.Parent.Parent.Config.EconomyConfig)

local LEVEL = EconomyConfig.LEVEL
local ENERGY = EconomyConfig.ENERGY
local HARVEST = EconomyConfig.HARVEST
local UPGRADES = EconomyConfig.UPGRADES

local Formulas = {}

-- XP required to advance from `level` to level+1 (0 at max level).
function Formulas.xpToNext(level: number): number
	if level >= LEVEL.MAX_LEVEL then
		return 0
	end
	return math.floor(LEVEL.XP_BASE * math.max(level, 1) ^ LEVEL.XP_EXPONENT + 0.5)
end

function Formulas.levelUpReward(newLevel: number): number
	return LEVEL.REWARD_CREDITS_BASE + LEVEL.REWARD_CREDITS_PER_LEVEL * newLevel
end

-- Adds XP and resolves level-ups. Returns newLevel, newXp, { levels reached }.
function Formulas.applyXp(level: number, xp: number, amount: number): (number, number, { number })
	local gained = {}
	xp += amount
	while level < LEVEL.MAX_LEVEL do
		local need = Formulas.xpToNext(level)
		if xp < need then
			break
		end
		xp -= need
		level += 1
		table.insert(gained, level)
	end
	if level >= LEVEL.MAX_LEVEL then
		xp = 0
	end
	return level, xp, gained
end

function Formulas.upgradeEffect(upgradeId: string, level: number): number
	local def = UPGRADES[upgradeId]
	if not def then
		return 0
	end
	return (def.effectPerLevel or 0) * math.clamp(level, 0, def.maxLevel)
end

function Formulas.energyCap(playerLevel: number, capacityUpgradeLevel: number): number
	return math.min(
		EconomyConfig.BALANCE_CAPS.currencies.CosmicEnergy,
		ENERGY.BASE_CAP + ENERGY.CAP_PER_PLAYER_LEVEL * (playerLevel - 1) + Formulas.upgradeEffect("EnergyCapacity", capacityUpgradeLevel)
	)
end

-- Regenerates energy over `elapsed` seconds. Returns newValue, secondsConsumed (so callers carry the
-- fractional remainder forward instead of losing it). Never reduces a value that is above the cap.
function Formulas.regenEnergy(current: number, cap: number, elapsed: number): (number, number)
	local rate = ENERGY.REGEN_PER_MINUTE / 60
	if current >= cap then
		return current, math.max(elapsed, 0)
	end
	if elapsed <= 0 or rate <= 0 then
		return current, 0
	end
	local gain = math.floor(elapsed * rate)
	if current + gain >= cap then
		return cap, elapsed
	end
	return current + gain, gain / rate
end

function Formulas.harvestYield(materialId: string, playerLevel: number, yieldUpgradeLevel: number, multiplier: number?): number
	local base = HARVEST.BASE_YIELD[materialId]
	if not base then
		return 0
	end
	local m = math.clamp(multiplier or 1, 0, HARVEST.MAX_MULTIPLIER)
	local v = base
		* (1 + Formulas.upgradeEffect("HarvestYield", yieldUpgradeLevel))
		* (1 + HARVEST.LEVEL_YIELD_BONUS * (playerLevel - 1))
		* m
	return math.max(0, math.floor(v + 0.5))
end

function Formulas.harvestEnergyCost(efficiencyLevel: number): number
	local mult = math.max(HARVEST.MIN_COST_MULTIPLIER, 1 - Formulas.upgradeEffect("HarvestEfficiency", efficiencyLevel))
	return math.max(HARVEST.MIN_ENERGY_COST, math.floor(HARVEST.ENERGY_COST * mult + 0.5))
end

-- Cost to go from currentLevel to currentLevel+1, as a transaction-shaped table of POSITIVE amounts.
-- nil when the upgrade is unknown or maxed.
function Formulas.upgradeCost(upgradeId: string, currentLevel: number): { currencies: { [string]: number }, materials: { [string]: number } }?
	local def = UPGRADES[upgradeId]
	if not def or currentLevel >= def.maxLevel then
		return nil
	end
	local mats = {}
	for id, mc in (def.materialCosts or {}) :: { [string]: any } do
		mats[id] = mc.base + mc.perLevel * currentLevel
	end
	return {
		currencies = { Credits = math.floor(def.baseCost * def.costGrowth ^ currentLevel + 0.5) },
		materials = mats,
	}
end

function Formulas.sellValue(materialId: string, amount: number): number?
	local price = EconomyConfig.SELL_PRICES[materialId]
	if not price then
		return nil
	end
	return price * amount
end

return Formulas
