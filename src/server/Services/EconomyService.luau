--!strict
-- EconomyService — owner: Developer B. The ONLY code that changes balances, XP, levels and upgrades.
-- Every change is an atomic TransactionCore transaction tagged with a whitelisted reason
-- (EconomyConfig.REASONS). Clients can never name a reward: remotes carry intent only.
--
-- Public server API (harvesting / DNA / quests / UI backends):
--   :GetBalance(player, section, id) -> int?        :GetBalances(player) -> copy
--   :CanAfford(player, cost) -> boolean             (cost = positive transaction-shaped table)
--   :Transact(player, tx, reason, opts?) -> ok, code, applied     opts.overflow = "clamp"|"reject"
--   :Grant(player, section, id, amount, reason) / :Spend(...) -> ok, code, applied
--   :GrantXp(player, amount, reason) -> ok, code, levelsReached
--   :RewardHarvest(player, materialId, multiplier?) -> ok, code, { materialId, amount, xp, energySpent }
--       call AFTER the harvesting system validated the action (node ownership/proximity/cooldown)
--   :SellMaterial(player, materialId, amount) -> ok, code, { credits }
--   :PurchaseUpgrade(player, upgradeId) -> ok, code, { upgradeId, level }
--   :GetUpgradeLevel / :GetUpgradeCost(player, upgradeId) / :GetEnergyCap(player)
--   :GetLedger(player) -> recent transactions (session memory, debugging)
--   .TransactionCompleted(player, reason, applied)  .LevelUp(player, newLevel)
-- Client remotes (via RemoteGuard): Economy_SellMaterial {materialId, amount},
--   Economy_PurchaseUpgrade {upgradeId}.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Formulas = require(Shared.Economy.EconomyFormulas)
local Schema = require(script.Parent.Parent.Data.ProfileSchema)
local TransactionCore = require(script.Parent.Parent.Data.TransactionCore)
local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)

local EconomyService = {}
EconomyService.TransactionCompleted = Signal.new()
EconomyService.LevelUp = Signal.new()

local ledgers: { [Player]: { any } } = {}
local COUNTER_MAX = EconomyConfig.BALANCE_CAPS.counter

local function energyCapFor(d: any): number
	return Formulas.energyCap(d.level, d.upgrades.EnergyCapacity or 0)
end

local function capFnFor(d: any): (string, string) -> number
	return function(section: string, id: string): number
		if section == "currencies" and id == "CosmicEnergy" then
			return energyCapFor(d)
		end
		return Schema.capFor(section, id)
	end
end

local function isReason(r: any): boolean
	return type(r) == "string" and EconomyConfig.REASONS[r] == true
end

local function bumpStat(d: any, id: string, by: number)
	d.stats[id] = math.clamp((d.stats[id] or 0) + by, 0, COUNTER_MAX)
end

local function pushLedger(player: Player, reason: string, applied: any)
	local l = ledgers[player]
	if not l then
		l = {}
		ledgers[player] = l
	end
	table.insert(l, { t = os.time(), reason = reason, applied = applied })
	while #l > EconomyConfig.LEDGER_SIZE do
		table.remove(l, 1)
	end
end

-- Brings energy regen up to date. Returns true if the value changed.
local function tickEnergy(d: any, now: number): boolean
	local cap = energyCapFor(d)
	local cur = d.currencies.CosmicEnergy or 0
	local new, consumed = Formulas.regenEnergy(cur, cap, now - d.energyUpdatedAt)
	d.currencies.CosmicEnergy = new
	if new >= cap then
		d.energyUpdatedAt = now
	else
		d.energyUpdatedAt += math.floor(consumed)
	end
	return new ~= cur
end

---------------------------------------------------------------- reads

function EconomyService:GetBalance(player: Player, section: string, id: string): number?
	local d = ProfileService:GetData(player)
	local map = d and d[section]
	if type(map) ~= "table" or not TransactionCore.SECTIONS[section] then
		return nil
	end
	return map[id] or 0
end

function EconomyService:GetBalances(player: Player): any
	local d = ProfileService:GetData(player)
	if not d then
		return nil
	end
	return { currencies = table.clone(d.currencies), materials = table.clone(d.materials), catalysts = table.clone(d.catalysts) }
end

function EconomyService:GetEnergyCap(player: Player): number?
	local d = ProfileService:GetData(player)
	return d and energyCapFor(d)
end

function EconomyService:GetUpgradeLevel(player: Player, upgradeId: string): number?
	local d = ProfileService:GetData(player)
	return d and (d.upgrades[upgradeId] or 0)
end

function EconomyService:GetUpgradeCost(player: Player, upgradeId: string): any
	local lvl = self:GetUpgradeLevel(player, upgradeId)
	return lvl and Formulas.upgradeCost(upgradeId, lvl)
end

function EconomyService:CanAfford(player: Player, cost: any): boolean
	local d = ProfileService:GetData(player)
	if not d or type(cost) ~= "table" then
		return false
	end
	for section, amounts in cost do
		local map = d[section]
		if not TransactionCore.SECTIONS[section] or type(map) ~= "table" or type(amounts) ~= "table" then
			return false
		end
		for id, amount in amounts do
			if not TransactionCore.isSafeInt(amount) or (map[id] or 0) < amount then
				return false
			end
		end
	end
	return true
end

function EconomyService:GetLedger(player: Player): { any }
	return TableUtil.deepCopy(ledgers[player] or {})
end

---------------------------------------------------------------- writes

function EconomyService:Transact(player: Player, tx: any, reason: string, opts: any?): (boolean, string, any)
	if not isReason(reason) then
		return false, "INVALID_REASON", nil
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", nil
	end
	tickEnergy(d, os.time())
	local ok, code, applied = TransactionCore.apply(d, tx, capFnFor(d), opts and opts.overflow)
	if not ok then
		return false, code, nil
	end
	local credits = applied.currencies and applied.currencies.Credits
	if credits then
		if credits > 0 then
			bumpStat(d, "creditsEarned", credits)
		else
			bumpStat(d, "creditsSpent", -credits)
		end
	end
	pushLedger(player, reason, applied)
	ProfileService:MarkChanged(player, "economy")
	self.TransactionCompleted:Fire(player, reason, applied)
	return true, "OK", applied
end

function EconomyService:Grant(player: Player, section: string, id: string, amount: number, reason: string): (boolean, string, any)
	if not RemoteGuard.isPositiveInt(amount, EconomyConfig.MAX_TRANSACTION_AMOUNT) then
		return false, "INVALID_AMOUNT", nil
	end
	return self:Transact(player, { [section] = { [id] = amount } }, reason)
end

function EconomyService:Spend(player: Player, section: string, id: string, amount: number, reason: string): (boolean, string, any)
	if not RemoteGuard.isPositiveInt(amount, EconomyConfig.MAX_TRANSACTION_AMOUNT) then
		return false, "INVALID_AMOUNT", nil
	end
	return self:Transact(player, { [section] = { [id] = -amount } }, reason)
end

function EconomyService:GrantXp(player: Player, amount: number, reason: string): (boolean, string, { number }?)
	if not isReason(reason) then
		return false, "INVALID_REASON", nil
	end
	if not RemoteGuard.isPositiveInt(amount, EconomyConfig.LEVEL.MAX_XP_GRANT) then
		return false, "INVALID_AMOUNT", nil
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", nil
	end
	local newLevel, newXp, reached = Formulas.applyXp(d.level, d.xp, amount)
	d.level, d.xp = newLevel, newXp
	for _, lvl in reached do
		local reward = Formulas.levelUpReward(lvl)
		local tx: any = { currencies = { Credits = reward } }
		if EconomyConfig.LEVEL.REFILL_ENERGY_ON_LEVEL_UP then
			local missing = energyCapFor(d) - (d.currencies.CosmicEnergy or 0)
			if missing > 0 then
				tx.currencies.CosmicEnergy = missing
			end
		end
		local ok, _, applied = TransactionCore.apply(d, tx, capFnFor(d), "clamp")
		if ok then
			if applied.currencies and applied.currencies.Credits then
				bumpStat(d, "creditsEarned", applied.currencies.Credits)
			end
			pushLedger(player, "LevelUp", applied)
		end
		self.LevelUp:Fire(player, lvl)
	end
	ProfileService:MarkChanged(player, "level")
	return true, "OK", reached
end

function EconomyService:RewardHarvest(player: Player, materialId: string, multiplier: number?): (boolean, string, any)
	if not ItemCatalog.get("materials", materialId) then
		return false, "UNKNOWN_ITEM", nil
	end
	local m = if multiplier == nil then 1 else multiplier
	if not RemoteGuard.isFiniteNumber(m) or m < 0 or m > EconomyConfig.HARVEST.MAX_MULTIPLIER then
		return false, "INVALID_AMOUNT", nil
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", nil
	end
	local amount = Formulas.harvestYield(materialId, d.level, d.upgrades.HarvestYield or 0, m)
	if amount <= 0 then
		return false, "NOTHING_HARVESTED", nil
	end
	local cost = Formulas.harvestEnergyCost(d.upgrades.HarvestEfficiency or 0)
	local ok, code, applied = self:Transact(player, {
		currencies = { CosmicEnergy = -cost },
		materials = { [materialId] = amount },
	}, "Harvest")
	if not ok then
		return false, if code == "INSUFFICIENT_FUNDS" then "NOT_ENOUGH_ENERGY" else code, nil
	end
	local got = applied.materials and applied.materials[materialId] or 0
	bumpStat(d, "harvests", 1)
	bumpStat(d, "materialsHarvested", got)
	local xp = EconomyConfig.HARVEST.XP_PER_HARVEST
	self:GrantXp(player, xp, "Harvest")
	return true, "OK", { materialId = materialId, amount = got, xp = xp, energySpent = cost }
end

function EconomyService:SellMaterial(player: Player, materialId: string, amount: number): (boolean, string, any)
	if not ItemCatalog.get("materials", materialId) then
		return false, "UNKNOWN_ITEM", nil
	end
	if not RemoteGuard.isPositiveInt(amount, EconomyConfig.MAX_SELL_PER_REQUEST) then
		return false, "INVALID_AMOUNT", nil
	end
	local value = Formulas.sellValue(materialId, amount)
	if not value then
		return false, "NOT_SELLABLE", nil
	end
	local ok, code = self:Transact(player, {
		materials = { [materialId] = -amount },
		currencies = { Credits = value },
	}, "Sell", { overflow = "reject" })
	if not ok then
		return false, code, nil
	end
	local d = ProfileService:GetData(player)
	bumpStat(d, "materialsSold", amount)
	return true, "OK", { credits = value }
end

function EconomyService:PurchaseUpgrade(player: Player, upgradeId: string): (boolean, string, any)
	local def = type(upgradeId) == "string" and EconomyConfig.UPGRADES[upgradeId]
	if not def then
		return false, "UNKNOWN_UPGRADE", nil
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", nil
	end
	if d.level < (def.minPlayerLevel or 1) then
		return false, "LEVEL_TOO_LOW", nil
	end
	local current = d.upgrades[upgradeId] or 0
	local cost = Formulas.upgradeCost(upgradeId, current)
	if not cost then
		return false, "MAX_LEVEL", nil
	end
	local ok, code = self:Transact(player, TransactionCore.negate(cost), "Upgrade")
	if not ok then
		return false, code, nil
	end
	d.upgrades[upgradeId] = current + 1 -- same thread, no yield since the transaction: atomic
	bumpStat(d, "upgradesBought", 1)
	ProfileService:MarkChanged(player, "upgrades")
	return true, "OK", { upgradeId = upgradeId, level = current + 1 }
end

---------------------------------------------------------------- lifecycle

function EconomyService:Init()
	ProfileService.ProfileLoaded:Connect(function(player: Player)
		local d = ProfileService:GetData(player)
		if d and tickEnergy(d, os.time()) then -- offline regen
			ProfileService:MarkChanged(player, "economy")
		end
	end)
	ProfileService.ProfileReleasing:Connect(function(player: Player)
		ledgers[player] = nil
	end)
end

function EconomyService:Start()
	RemoteGuard.bind("Economy_SellMaterial", function(player, p)
		if not RemoteGuard.isId(p.materialId) then
			return false, "INVALID_PAYLOAD"
		end
		if not RemoteGuard.isPositiveInt(p.amount, EconomyConfig.MAX_SELL_PER_REQUEST) then
			return false, "INVALID_AMOUNT"
		end
		return EconomyService:SellMaterial(player, p.materialId, p.amount)
	end)
	RemoteGuard.bind("Economy_PurchaseUpgrade", function(player, p)
		if not RemoteGuard.isId(p.upgradeId) then
			return false, "INVALID_PAYLOAD"
		end
		return EconomyService:PurchaseUpgrade(player, p.upgradeId)
	end)
	task.spawn(function()
		while true do
			task.wait(EconomyConfig.ENERGY.TICK_INTERVAL)
			local now = os.time()
			for _, player in ProfileService:GetLoadedPlayers() do
				local d = ProfileService:GetData(player)
				if d and tickEnergy(d, now) then
					ProfileService:MarkChanged(player, "economy")
				end
			end
		end
	end)
end

return EconomyService
