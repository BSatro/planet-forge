--!strict
-- TransactionCore — owner: Developer B. Pure, atomic balance changes on a profile table.
--   tx = { currencies = { Credits = 50 }, materials = { IceMatter = -10 }, catalysts = { FrostSeed = 1 } }
-- ALL deltas are validated before ANY is applied: a transaction applies completely or not at all.
-- overflow: "clamp" (default; grants stop at the cap) | "reject" (CAP_EXCEEDED, e.g. for sells).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemCatalog = require(ReplicatedStorage.PF_Shared.Config.ItemCatalog)
local EconomyConfig = require(ReplicatedStorage.PF_Shared.Config.EconomyConfig)

local TransactionCore = {}

TransactionCore.SECTIONS = { currencies = true, materials = true, catalysts = true } :: { [string]: boolean }

function TransactionCore.isSafeInt(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v % 1 == 0
end

-- Returns ok, code, applied ({ [section]: { [id]: actualDelta } })
function TransactionCore.apply(profile: any, tx: any, capFn: (string, string) -> number, overflow: string?): (boolean, string, any)
	if type(tx) ~= "table" then
		return false, "INVALID_TRANSACTION", nil
	end
	local plan = {}
	for section, deltas in tx do
		if type(section) ~= "string" or not TransactionCore.SECTIONS[section] or type(deltas) ~= "table" then
			return false, "INVALID_TRANSACTION", nil
		end
		local balances = profile[section]
		if type(balances) ~= "table" then
			return false, "CORRUPT_PROFILE", nil
		end
		for id, delta in deltas do
			if not ItemCatalog.get(section, id) then
				return false, "UNKNOWN_ITEM", nil
			end
			if not TransactionCore.isSafeInt(delta) or math.abs(delta) > EconomyConfig.MAX_TRANSACTION_AMOUNT then
				return false, "INVALID_AMOUNT", nil
			end
			if delta ~= 0 then
				local cur = balances[id] or 0
				local new = cur + delta
				if new < 0 then
					return false, "INSUFFICIENT_FUNDS", nil
				end
				local cap = capFn(section, id)
				if delta > 0 and new > cap then
					if overflow == "reject" then
						return false, "CAP_EXCEEDED", nil
					end
					new = math.max(cur, cap)
				end
				table.insert(plan, { section = section, id = id, old = cur, new = new })
			end
		end
	end
	if #plan == 0 then
		return false, "EMPTY_TRANSACTION", nil
	end
	local applied = {}
	for _, step in plan do
		profile[step.section][step.id] = step.new
		applied[step.section] = applied[step.section] or {}
		applied[step.section][step.id] = step.new - step.old
	end
	return true, "OK", applied
end

-- Negates a positive cost table (from EconomyFormulas.upgradeCost) into spend deltas.
function TransactionCore.negate(cost: any): any
	local out = {}
	for section, deltas in cost do
		local s = {}
		local any = false
		for id, v in deltas do
			if v ~= 0 then
				s[id] = -v
				any = true
			end
		end
		if any then
			out[section] = s
		end
	end
	return out
end

return TransactionCore
