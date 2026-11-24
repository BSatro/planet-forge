--!strict
-- InventoryService — owner: Developer B. Catalysts (stackable; changed through EconomyService transactions),
-- unlock sets (formations, cosmetics), discoveries, codex entries and expedition records.
--
-- Public server API:
--   :GetCatalystCount(player, id) -> int?
--   :AddCatalyst(player, id, count, reason) / :ConsumeCatalyst(player, id, count, reason) -> ok, code
--   :HasUnlock(player, section, id) -> boolean       section: formations|cosmetics|discoveries|codex
--   :Unlock(player, section, id) -> ok, code, isNew
--   :UnlockFormation / :UnlockCosmetic / :UnlockCodexEntry(player, id) -> ok, code, isNew
--   :RecordDiscovery(player, id) -> ok, code, isNew   (first time: reward + linked codex entry)
--   :RecordExpedition(player, { expeditionId, outcome, startedAt?, endedAt? }) -> ok, code
--   .ItemUnlocked(player, section, id)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local EconomyService = require(script.Parent.EconomyService)

local InventoryService = {}
InventoryService.ItemUnlocked = Signal.new()

-- Formations are NOT unlockable here any more: they are planet state ({ n, t } records) granted only by
-- the evolution engine (EvolutionService). HasUnlock("formations") still answers ownership.
local UNLOCK_SECTIONS = { cosmetics = true, discoveries = true, codex = true } :: { [string]: boolean }

local function unlockMap(d: any, section: string): any
	return d[section]
end

function InventoryService:Init() end
function InventoryService:Start() end

function InventoryService:GetCatalystCount(player: Player, id: string): number?
	return EconomyService:GetBalance(player, "catalysts", id)
end

function InventoryService:AddCatalyst(player: Player, id: string, count: number, reason: string): (boolean, string)
	if not RemoteGuard.isPositiveInt(count, EconomyConfig.MAX_TRANSACTION_AMOUNT) then
		return false, "INVALID_AMOUNT"
	end
	local ok, code = EconomyService:Transact(player, { catalysts = { [id] = count } }, reason, { overflow = "reject" })
	return ok, if code == "CAP_EXCEEDED" then "STACK_FULL" else code
end

function InventoryService:ConsumeCatalyst(player: Player, id: string, count: number, reason: string): (boolean, string)
	if not RemoteGuard.isPositiveInt(count, EconomyConfig.MAX_TRANSACTION_AMOUNT) then
		return false, "INVALID_AMOUNT"
	end
	local ok, code = EconomyService:Transact(player, { catalysts = { [id] = -count } }, reason)
	return ok, if code == "INSUFFICIENT_FUNDS" then "NOT_ENOUGH_CATALYSTS" else code
end

function InventoryService:HasUnlock(player: Player, section: string, id: string): boolean
	local d = ProfileService:GetData(player)
	if not d or not ItemCatalog.isValidIdString(id) then
		return false
	end
	if section == "formations" then
		local rec = d.planet.formations[id]
		return rec ~= nil and rec.n > 0
	end
	if not UNLOCK_SECTIONS[section] then
		return false
	end
	return unlockMap(d, section)[id] ~= nil
end

function InventoryService:Unlock(player: Player, section: string, id: string): (boolean, string, boolean)
	if not UNLOCK_SECTIONS[section] then
		return false, "INVALID_SECTION", false
	end
	if not ItemCatalog.get(section, id) then
		return false, "UNKNOWN_ITEM", false
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", false
	end
	local map = unlockMap(d, section)
	if map[id] ~= nil then
		return true, "ALREADY_UNLOCKED", false
	end
	map[id] = os.time()
	ProfileService:MarkChanged(player, section)
	self.ItemUnlocked:Fire(player, section, id)
	return true, "OK", true
end

-- Deprecated: formations come from reactions/branches (EvolutionService). Kept for API compatibility.
function InventoryService:UnlockFormation(_player: Player, _id: string): (boolean, string, boolean)
	return false, "USE_EVOLUTION_SERVICE", false
end

function InventoryService:UnlockCosmetic(player: Player, id: string)
	return self:Unlock(player, "cosmetics", id)
end

function InventoryService:UnlockCodexEntry(player: Player, id: string)
	return self:Unlock(player, "codex", id)
end

function InventoryService:RecordDiscovery(player: Player, id: string): (boolean, string, boolean)
	local ok, code, isNew = self:Unlock(player, "discoveries", id)
	if ok and isNew then
		local R = EconomyConfig.DISCOVERY_REWARD
		if R.credits > 0 then
			EconomyService:Grant(player, "currencies", "Credits", R.credits, "Discovery")
		end
		if R.xp > 0 then
			EconomyService:GrantXp(player, R.xp, "Discovery")
		end
		local entry = ItemCatalog.get("discoveries", id)
		if entry and entry.unlocksCodex then
			self:Unlock(player, "codex", entry.unlocksCodex)
		end
	end
	return ok, code, isNew
end

-- Future expedition system: bounded history of finished expeditions.
function InventoryService:RecordExpedition(player: Player, record: any): (boolean, string)
	if type(record) ~= "table" or not ItemCatalog.isValidIdString(record.expeditionId) or not ItemCatalog.isValidIdString(record.outcome) then
		return false, "INVALID_RECORD"
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY"
	end
	local now = os.time()
	local function ts(v: any): number
		return if RemoteGuard.isInt(v, 0, DataConfig.MAX_TIMESTAMP) then v else now
	end
	local history = d.expeditions.history
	table.insert(history, {
		expeditionId = record.expeditionId,
		outcome = record.outcome,
		startedAt = ts(record.startedAt),
		endedAt = ts(record.endedAt),
	})
	while #history > DataConfig.EXPEDITION_HISTORY_MAX do
		table.remove(history, 1)
	end
	d.expeditions.totalCompleted = math.min(d.expeditions.totalCompleted + 1, EconomyConfig.BALANCE_CAPS.counter)
	ProfileService:MarkChanged(player, "expeditions")
	return true, "OK"
end

return InventoryService
