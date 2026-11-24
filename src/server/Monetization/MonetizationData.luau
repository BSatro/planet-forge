--!strict
-- MonetizationData — owner: Monetization. Pure rules for the persisted purchase state (no Instances, no
-- services; unit-tested). profile.monetization =
--   { passes   = { [passKey] = { at = firstGrantedAt, v = lastVerifiedAt? } }   cached Game Pass entitlements
--     receipts = { [PurchaseId] = { t = processedAt, k = productKey, r = robuxSpent } }   idempotency ledger
--     order    = { PurchaseId }   oldest first (bounded by LIMITS.receiptHistory)
--     fireworks = n             Cosmic Fireworks bought and not launched yet (never lost)
--     presets  = { { Atmosphere?, PlanetRing?, HarvesterFX? } }   saved appearance presets }
-- Cosmetics granted by a pass are unlocked into profile.cosmetics (persistent entitlement, survives an API
-- outage); equipping still checks ownership like every other cosmetic.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.PF_Shared
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)

local L = MonetizationConfig.LIMITS
local Data = {}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function validKey(k: any, maxLen: number): boolean
	return type(k) == "string" and #k > 0 and #k <= maxLen
end

-- Normalizes a stored block in place (or creates it). Never drops a valid receipt or entitlement.
function Data.reconcile(mon: any, now: number): any
	if type(mon) ~= "table" then
		mon = {}
	end
	local passes = {}
	for k, rec in (if type(mon.passes) == "table" then mon.passes else {}) do
		if validKey(k, 64) then
			local at = if type(rec) == "table" and finite(rec.at) then rec.at else now
			passes[k] = { at = at, v = if type(rec) == "table" and finite(rec.v) then rec.v else nil }
		end
	end
	mon.passes = passes
	local receipts = {}
	for id, rec in (if type(mon.receipts) == "table" then mon.receipts else {}) do
		if validKey(id, 128) and type(rec) == "table" then
			receipts[id] = { t = if finite(rec.t) then rec.t else now, k = if type(rec.k) == "string" then rec.k else "?", r = if finite(rec.r) then rec.r else 0 }
		end
	end
	local order = {}
	for _, id in (if type(mon.order) == "table" then mon.order else {}) do
		if receipts[id] and not table.find(order, id) then
			table.insert(order, id)
		end
	end
	for id in receipts do -- ids missing from the order list go first (oldest unknown)
		if not table.find(order, id) then
			table.insert(order, 1, id)
		end
	end
	while #order > L.receiptHistory do
		receipts[table.remove(order, 1) :: string] = nil
	end
	mon.receipts, mon.order = receipts, order
	mon.fireworks = if finite(mon.fireworks) then math.clamp(math.floor(mon.fireworks), 0, L.fireworksStack) else 0
	local presets = {}
	for i, pr in (if type(mon.presets) == "table" then mon.presets else {}) do
		if type(i) == "number" and i >= 1 and i <= L.presetSlotsMax and type(pr) == "table" then
			local clean = {}
			for _, cat in MonetizationConfig.COSMETIC_CATEGORIES do
				local id = pr[cat]
				local e = type(id) == "string" and ItemCatalog.COSMETICS[id]
				if e and e.category == cat then
					clean[cat] = id
				end
			end
			presets[i] = clean
		end
	end
	mon.presets = presets
	return mon
end

function Data.ownsPass(mon: any, key: string): boolean
	return mon.passes[key] ~= nil
end

function Data.presetSlots(mon: any): number
	local n = MonetizationConfig.FREE.presetSlots
	for key in mon.passes do
		local p = MonetizationConfig.pass(key)
		if p and p.grants.presetSlots then
			n += p.grants.presetSlots
		end
	end
	return math.min(n, L.presetSlotsMax)
end

-- Game Pass entitlement: idempotent. Returns changed (true the first time / when cosmetics were missing).
function Data.grantPass(profile: any, pass: any, now: number): boolean
	local mon = profile.monetization
	local changed = mon.passes[pass.key] == nil
	if changed then
		mon.passes[pass.key] = { at = now, v = now }
	else
		mon.passes[pass.key].v = now
	end
	for _, id in pass.grants.cosmetics or {} do
		if ItemCatalog.COSMETICS[id] and profile.cosmetics[id] == nil then
			profile.cosmetics[id] = now
			changed = true
		end
	end
	return changed
end

function Data.hasReceipt(mon: any, purchaseId: string): boolean
	return mon.receipts[purchaseId] ~= nil
end

-- Developer Product fulfilment. Applies the grant AND records the PurchaseId in one step and returns an undo
-- function (used when the save that must follow fails: nothing half-granted remains in memory).
function Data.applyReceipt(profile: any, product: any, purchaseId: string, robux: number?, now: number): (boolean, string, (() -> ())?)
	local mon = profile.monetization
	if not validKey(purchaseId, 128) then
		return false, "BAD_RECEIPT", nil
	end
	if mon.receipts[purchaseId] then
		return true, "ALREADY_GRANTED", nil
	end
	local g = product.grants
	local before = mon.fireworks
	if g.fireworks then
		mon.fireworks = math.min(L.fireworksStack, mon.fireworks + g.fireworks)
	end
	mon.receipts[purchaseId] = { t = now, k = product.key, r = if finite(robux) then robux :: number else 0 }
	table.insert(mon.order, purchaseId)
	local evicted: { any } = {}
	while #mon.order > L.receiptHistory do
		local old = table.remove(mon.order, 1) :: string
		table.insert(evicted, { id = old, rec = mon.receipts[old] })
		mon.receipts[old] = nil
	end
	local function undo()
		mon.fireworks = before
		mon.receipts[purchaseId] = nil
		local i = table.find(mon.order, purchaseId)
		if i then
			table.remove(mon.order, i)
		end
		for k = #evicted, 1, -1 do
			table.insert(mon.order, 1, evicted[k].id)
			mon.receipts[evicted[k].id] = evicted[k].rec
		end
	end
	return true, "GRANTED", undo
end

-- Presets -------------------------------------------------------------------------------------------
function Data.savePreset(profile: any, index: any): (boolean, string)
	local mon = profile.monetization
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
		return false, "INVALID_PAYLOAD"
	end
	if index > Data.presetSlots(mon) then
		return false, "LOCKED"
	end
	local cur = profile.planet.cosmetics or {}
	local pr = {}
	for _, cat in MonetizationConfig.COSMETIC_CATEGORIES do
		pr[cat] = cur[cat]
	end
	mon.presets[index] = pr
	return true, "SAVED"
end

-- Returns the equip map a preset resolves to: only cosmetics the player owns (others are left unequipped).
function Data.presetEquip(profile: any, index: any): (boolean, string, any)
	local mon = profile.monetization
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
		return false, "INVALID_PAYLOAD", nil
	end
	if index > Data.presetSlots(mon) then
		return false, "LOCKED", nil
	end
	local pr = mon.presets[index]
	if not pr then
		return false, "EMPTY", nil
	end
	local out, missing = {}, {}
	for _, cat in MonetizationConfig.COSMETIC_CATEGORIES do
		local id = pr[cat]
		if id and profile.cosmetics[id] ~= nil then
			out[cat] = id
		elseif id then
			table.insert(missing, id)
		end
	end
	return true, if #missing > 0 then "PARTIAL" else "OK", { equip = out, missing = missing }
end

-- Static validation of the product table (tests + server start). Returns { error strings }.
function Data.validateConfig(): { string }
	local errs = {}
	local function check(def: any, where: string)
		for k, v in def.grants do
			if not MonetizationConfig.ALLOWED_GRANTS[k] then
				table.insert(errs, where .. ": grant '" .. tostring(k) .. "' is not allowed (no progression for money)")
			end
			if k == "cosmetics" then
				for _, id in v do
					local e = ItemCatalog.COSMETICS[id]
					if not e then
						table.insert(errs, where .. ": unknown cosmetic " .. tostring(id))
					elseif not table.find(MonetizationConfig.COSMETIC_CATEGORIES, e.category) then
						table.insert(errs, where .. ": " .. id .. " is not an equippable presentation cosmetic")
					end
				end
			end
		end
		if type(def.name) ~= "string" or type(def.description) ~= "string" or #def.description < 20 then
			table.insert(errs, where .. ": needs a name and an accurate description")
		end
	end
	for key, p in MonetizationConfig.PASSES do
		if p.key ~= key then
			table.insert(errs, "pass " .. key .. ": key mismatch")
		end
		if p.gamePassId ~= nil and (type(p.gamePassId) ~= "number" or p.gamePassId <= 0) then
			table.insert(errs, "pass " .. key .. ": gamePassId must be a positive number or nil")
		end
		check(p, "pass " .. key)
	end
	for key, p in MonetizationConfig.PRODUCTS do
		if p.key ~= key then
			table.insert(errs, "product " .. key .. ": key mismatch")
		end
		if p.productId ~= nil and (type(p.productId) ~= "number" or p.productId <= 0) then
			table.insert(errs, "product " .. key .. ": productId must be a positive number or nil")
		end
		check(p, "product " .. key)
	end
	return errs
end

return Data
