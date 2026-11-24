--!strict
-- MonetizationService — owner: Monetization. The ONLY place that talks to MarketplaceService.
--   * Game Passes: ownership verified on join (UserOwnsGamePassAsync, retried) and on purchase
--     (PromptGamePassPurchaseFinished). Granting is idempotent and persisted (profile.monetization.passes +
--     unlocked cosmetics), so a returning owner keeps everything even if the ownership API is down.
--     A negative answer never auto-revokes a stored entitlement (it is logged for review instead).
--   * Developer Products: ONE MarketplaceService.ProcessReceipt handler. Fulfilment is idempotent by
--     PurchaseId (ledger in the profile) and is acknowledged (PurchaseGranted) only after the grant is saved;
--     if the save fails the grant is rolled back and Roblox retries later (NotProcessedYet). A server crash
--     before the save therefore loses nothing and grants nothing twice.
--   * Prompts only on an explicit player request from the store, never while harvesting or inside a rift.
--   * Prices come from GetProductInfo (official); unconfigured / unavailable items are never prompted.
-- Remotes: Store_Action {requestId, action, key?, index?} -> Action_Result;  Store_Notify (server -> client);
--          Store_Celebration (server -> all clients, decorative fireworks).
-- Studio only: ServerStorage.PF_StoreHook (fake marketplace + receipts for tests).
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local Server = script.Parent.Parent
local MonetizationData = require(Server.Monetization.MonetizationData)
local RemoteGuard = require(Server.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local EvolutionService = require(script.Parent.EvolutionService)
local HarvestService = require(script.Parent.HarvestService)
local RiftService = require(script.Parent.RiftService)

local MonetizationService = {}
MonetizationService.EntitlementGranted = Signal.new() -- (player, passKey)
MonetizationService.ProductGranted = Signal.new() -- (player, productKey, purchaseId)
-- analytics hook (TelemetryService): (player, step "opened"|"prompted"|"completed", kind "pass"|"product"?, key?)
MonetizationService.StoreFunnel = Signal.new()

local L = MonetizationConfig.LIMITS
local Decision = Enum.ProductPurchaseDecision

-- Marketplace adapter (swapped for a fake in Studio tests) ----------------------------------------------
local realMarket = {
	owns = function(userId: number, passId: number): boolean
		return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end,
	info = function(id: number, kind: string): any
		return MarketplaceService:GetProductInfo(id, if kind == "pass" then Enum.InfoType.GamePass else Enum.InfoType.Product)
	end,
	promptPass = function(player: Player, passId: number)
		MarketplaceService:PromptGamePassPurchase(player, passId)
	end,
	promptProduct = function(player: Player, productId: number)
		MarketplaceService:PromptProductPurchase(player, productId)
	end,
}
local market: any = realMarket

local notify: RemoteEvent = nil :: any
local resolvePlayer = function(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end
local celebrate: RemoteEvent = nil :: any
local infoCache: { [string]: { at: number, info: any } } = {}
local receiptLock: { [number]: boolean } = {}
local lastLaunch: { [Player]: number } = {}
local launchCount = 0

local function send(p: Player, kind: string, data: { [string]: any }?)
	if p.Parent then
		local d = data or {}
		d.kind = kind
		notify:FireClient(p, d)
	end
end

local function retry<T>(attempts: number, fn: () -> T): (boolean, T?)
	local lastErr: any = nil
	for i = 1, attempts do
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		if i < attempts then
			task.wait(0.5 * i)
		end
	end
	warn("[PF][Store] marketplace call failed: " .. tostring(lastErr))
	return false, nil
end

local function gameplayBusy(p: Player): string?
	local okH, operating = pcall(HarvestService.IsOperating, HarvestService, p)
	if okH and operating then
		return "BUSY_HARVESTING"
	end
	local okR, run = pcall(RiftService.GetRun, RiftService, p)
	if okR and run ~= nil then
		return "BUSY_EXPEDITION"
	end
	return nil
end

-- Official product information (price, for sale), cached. Returns info or nil, reason.
local function productInfo(kind: string, id: number?): (any, string?)
	if type(id) ~= "number" then
		return nil, "NOT_CONFIGURED"
	end
	local key = kind .. ":" .. id
	local c = infoCache[key]
	if c and os.clock() - c.at < L.productInfoTtl then
		return c.info, nil
	end
	local ok, info = retry(2, function()
		return market.info(id, kind)
	end)
	if not ok or type(info) ~= "table" then
		return nil, "INFO_UNAVAILABLE"
	end
	local clean = {
		price = if type(info.PriceInRobux) == "number" then info.PriceInRobux else nil,
		forSale = if kind == "pass" then info.IsForSale == true else (info.IsForSale ~= false),
		name = info.Name,
	}
	if clean.price == nil then
		clean.forSale = false
	end
	infoCache[key] = { at = os.clock(), info = clean }
	return clean, nil
end

----------------------------------------------------------------------------------------------------
-- Game Pass entitlements

local function grantPass(p: Player, pass: any, source: string): boolean
	local d = ProfileService:GetData(p)
	if not d then
		return false
	end
	local changed = MonetizationData.grantPass(d, pass, os.time())
	if changed then
		ProfileService:MarkChanged(p, "monetization")
		ProfileService:SaveNow(p, true)
		print(string.format("[PF][Store] %s: %s entitlement granted (%s)", p.Name, pass.key, source))
		send(p, "passGranted", { key = pass.key })
		MonetizationService.EntitlementGranted:Fire(p, pass.key)
		if source == "purchase" then
			MonetizationService.StoreFunnel:Fire(p, "completed", "pass", pass.key)
		end
	end
	return changed
end

-- Verifies every configured pass for a player. Positive -> grant; negative never revokes a stored entitlement.
function MonetizationService:RefreshPasses(p: Player)
	local d = ProfileService:GetData(p)
	if not d then
		return
	end
	for _, pass in MonetizationConfig.sortedPasses() do
		if type(pass.gamePassId) == "number" then
			local ok, owned = retry(L.ownershipRetries, function()
				return market.owns(p.UserId, pass.gamePassId)
			end)
			if ok and owned then
				grantPass(p, pass, "verified")
			elseif ok and not owned and MonetizationData.ownsPass(d.monetization, pass.key) then
				warn(string.format("[PF][Store] ownership mismatch for %s / %s: stored entitlement kept for review", p.Name, pass.key))
			end
		end
	end
end

local function onPassFinished(p: Player, passId: number, purchased: boolean)
	local pass = MonetizationConfig.passById(passId)
	if not pass then
		return
	end
	if purchased then
		grantPass(p, pass, "purchase")
	else
		send(p, "cancelled", { key = pass.key, what = "pass" })
	end
end

----------------------------------------------------------------------------------------------------
-- Developer Products (the single receipt handler)

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local product = MonetizationConfig.productById(receipt.ProductId)
	if not product then
		-- unknown / not yet configured: keep it pending so a config fix can still fulfil it later
		warn("[PF][Store] receipt for an unconfigured product " .. tostring(receipt.ProductId) .. " left unprocessed")
		return Decision.NotProcessedYet
	end
	local p = resolvePlayer(receipt.PlayerId)
	if not p then
		return Decision.NotProcessedYet -- Roblox retries when the player is next in a server
	end
	local d = ProfileService:WaitForData(p, 15)
	if not d or not p.Parent then
		return Decision.NotProcessedYet
	end
	local uid = p.UserId
	local waited = 0
	while receiptLock[uid] and waited < 15 do -- one fulfilment per player at a time
		waited += task.wait(0.1)
	end
	if receiptLock[uid] then
		return Decision.NotProcessedYet
	end
	receiptLock[uid] = true
	local ok, decision = pcall(function(): Enum.ProductPurchaseDecision
		d = ProfileService:GetData(p)
		if not d then
			return Decision.NotProcessedYet
		end
		if MonetizationData.hasReceipt(d.monetization, receipt.PurchaseId) then
			return Decision.PurchaseGranted -- duplicate delivery: already fulfilled and saved
		end
		local okA, code, undo = MonetizationData.applyReceipt(d, product, tostring(receipt.PurchaseId), receipt.CurrencySpent, os.time())
		if not okA or not undo then
			warn("[PF][Store] receipt rejected: " .. tostring(code))
			return Decision.NotProcessedYet
		end
		-- a receipt may only be acknowledged once its grant is durably saved: a failed OR throwing save undoes the
		-- grant, so a later retry (same server or another) applies and saves it again (never lost, never twice)
		local okCall, saved, saveCode = pcall(ProfileService.SaveNow, ProfileService, p, true)
		if not okCall or not saved then
			undo()
			saveCode = if okCall then saveCode else "SAVE_ERROR"
			warn("[PF][Store] receipt " .. tostring(receipt.PurchaseId) .. " not acknowledged (save " .. tostring(saveCode) .. ")")
			return Decision.NotProcessedYet
		end
		ProfileService:MarkChanged(p, "monetization")
		print(string.format("[PF][Store] %s: %s fulfilled (receipt %s)", p.Name, product.key, tostring(receipt.PurchaseId)))
		send(p, "productGranted", { key = product.key, fireworks = d.monetization.fireworks })
		MonetizationService.ProductGranted:Fire(p, product.key, receipt.PurchaseId)
		MonetizationService.StoreFunnel:Fire(p, "completed", "product", product.key)
		if product.grants.fireworks then
			task.defer(function()
				MonetizationService:LaunchFireworks(p, true)
			end)
		end
		return Decision.PurchaseGranted
	end)
	receiptLock[uid] = nil
	if not ok then
		warn("[PF][Store] receipt handler error: " .. tostring(decision))
		return Decision.NotProcessedYet
	end
	return decision
end
MonetizationService._processReceipt = processReceipt

-- test seams (unit tests / Studio hook)
MonetizationService._passFinished = function(p: Player, passId: number, purchased: boolean)
	onPassFinished(p, passId, purchased)
end

function MonetizationService._setPlayerResolver(fn: any?)
	resolvePlayer = fn or function(userId: number): Player?
		return Players:GetPlayerByUserId(userId)
	end
end

-- swap the marketplace adapter; nil restores the real one
function MonetizationService._setMarket(m: any?)
	market = m or realMarket
	table.clear(infoCache)
end

----------------------------------------------------------------------------------------------------
-- Player actions

function MonetizationService:Catalog(p: Player): any
	local d = ProfileService:GetData(p)
	local mon = d and d.monetization
	local out = { passes = {}, products = {}, presetSlots = if mon then MonetizationData.presetSlots(mon) else MonetizationConfig.FREE.presetSlots, fireworks = if mon then mon.fireworks else 0 }
	for _, pass in MonetizationConfig.sortedPasses() do
		local info, why = productInfo("pass", pass.gamePassId)
		table.insert(out.passes, {
			key = pass.key,
			owned = mon ~= nil and MonetizationData.ownsPass(mon, pass.key),
			available = info ~= nil and info.forSale,
			price = info and info.price,
			reason = if info == nil then why elseif not info.forSale then "NOT_FOR_SALE" else nil,
		})
	end
	for _, prod in MonetizationConfig.sortedProducts() do
		local info, why = productInfo("product", prod.productId)
		table.insert(out.products, {
			key = prod.key,
			available = info ~= nil and info.forSale,
			price = info and info.price,
			reason = if info == nil then why elseif not info.forSale then "NOT_FOR_SALE" else nil,
		})
	end
	return out
end

function MonetizationService:PromptPass(p: Player, key: any): (boolean, string)
	local pass = MonetizationConfig.pass(key)
	if not pass then
		return false, "UNKNOWN_ITEM"
	end
	local d = ProfileService:GetData(p)
	if not d then
		return false, "NOT_READY"
	end
	if MonetizationData.ownsPass(d.monetization, pass.key) then
		return false, "ALREADY_OWNED"
	end
	local info, why = productInfo("pass", pass.gamePassId)
	if not info then
		return false, why or "UNAVAILABLE"
	end
	if not info.forSale then
		return false, "NOT_FOR_SALE"
	end
	local busy = gameplayBusy(p)
	if busy then
		return false, busy
	end
	local ok = pcall(market.promptPass, p, pass.gamePassId)
	if ok then
		MonetizationService.StoreFunnel:Fire(p, "prompted", "pass", pass.key)
	end
	return ok, if ok then "PROMPTED" else "PROMPT_FAILED"
end

function MonetizationService:PromptProduct(p: Player, key: any): (boolean, string)
	local prod = MonetizationConfig.product(key)
	if not prod then
		return false, "UNKNOWN_ITEM"
	end
	if not ProfileService:GetData(p) then
		return false, "NOT_READY"
	end
	local info, why = productInfo("product", prod.productId)
	if not info then
		return false, why or "UNAVAILABLE"
	end
	if not info.forSale then
		return false, "NOT_FOR_SALE"
	end
	local busy = gameplayBusy(p)
	if busy then
		return false, busy
	end
	local ok = pcall(market.promptProduct, p, prod.productId)
	if ok then
		MonetizationService.StoreFunnel:Fire(p, "prompted", "product", prod.key)
	end
	return ok, if ok then "PROMPTED" else "PROMPT_FAILED"
end

-- auto = true: right after a purchase (silently keeps the celebration for later if it can't run now)
function MonetizationService:LaunchFireworks(p: Player, auto: boolean?): (boolean, string, any?)
	local d = ProfileService:GetData(p)
	if not d then
		return false, "NOT_READY"
	end
	local mon = d.monetization
	if mon.fireworks <= 0 then
		return false, "NONE_LEFT"
	end
	local slot = PlanetSlotService:GetSlot(p)
	if not slot then
		return false, "NO_PLANET"
	end
	local t = os.clock()
	if lastLaunch[p] and t - lastLaunch[p] < L.fireworksCooldown then
		return false, "COOLDOWN"
	end
	local okR, run = pcall(RiftService.GetRun, RiftService, p)
	if okR and run ~= nil then
		return false, "BUSY_EXPEDITION"
	end
	lastLaunch[p] = t
	mon.fireworks -= 1
	launchCount += 1
	ProfileService:MarkChanged(p, "monetization")
	celebrate:FireAllClients({ slot = slot, ownerUserId = p.UserId, ownerName = p.DisplayName, seed = launchCount, duration = L.fireworksSeconds })
	print(string.format("[PF][Store] %s launched Cosmic Fireworks at slot %d (%d left)%s", p.Name, slot, mon.fireworks, if auto then " [auto]" else ""))
	return true, "LAUNCHED", { left = mon.fireworks }
end

function MonetizationService:SavePreset(p: Player, index: any): (boolean, string, any?)
	local d = ProfileService:GetData(p)
	if not d then
		return false, "NOT_READY"
	end
	local ok, code = MonetizationData.savePreset(d, index)
	if ok then
		ProfileService:MarkChanged(p, "monetization")
	end
	return ok, code
end

function MonetizationService:ApplyPreset(p: Player, index: any): (boolean, string, any?)
	local d = ProfileService:GetData(p)
	if not d then
		return false, "NOT_READY"
	end
	local ok, code, res = MonetizationData.presetEquip(d, index)
	if not ok then
		return false, code
	end
	for _, cat in MonetizationConfig.COSMETIC_CATEGORIES do
		EvolutionService:SetCosmetic(p, cat, res.equip[cat] or "None")
	end
	return true, code, { missing = res.missing }
end

----------------------------------------------------------------------------------------------------
function MonetizationService:Init()
	notify = RemoteGuard.getRemote("Store_Notify")
	celebrate = RemoteGuard.getRemote("Store_Celebration")
	local errs = MonetizationData.validateConfig()
	for _, e in errs do
		warn("[PF][Store] config error: " .. e)
	end
end

function MonetizationService:Start()
	-- the single developer-product receipt handler
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(p: Player, passId: number, purchased: boolean)
		onPassFinished(p, passId, purchased)
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
		local p = Players:GetPlayerByUserId(userId)
		local prod = MonetizationConfig.productById(productId)
		if p and prod and not purchased then
			send(p, "cancelled", { key = prod.key, what = "product" }) -- informational only; receipts decide
		end
	end)
	ProfileService.ProfileLoaded:Connect(function(p: Player)
		task.spawn(function()
			MonetizationService:RefreshPasses(p)
		end)
	end)
	for _, p in Players:GetPlayers() do
		if ProfileService:IsReady(p) then
			task.spawn(MonetizationService.RefreshPasses, MonetizationService, p)
		end
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		lastLaunch[p] = nil
	end)
	RemoteGuard.bind("Store_Action", function(p: Player, payload: any)
		if not ProfileService:IsReady(p) then
			return false, "NOT_READY"
		end
		local a = payload.action
		if a == "catalog" then
			MonetizationService.StoreFunnel:Fire(p, "opened", nil, nil)
			return true, "OK", MonetizationService:Catalog(p)
		elseif a == "buyPass" then
			return MonetizationService:PromptPass(p, payload.key)
		elseif a == "buyProduct" then
			return MonetizationService:PromptProduct(p, payload.key)
		elseif a == "launch" then
			return MonetizationService:LaunchFireworks(p, false)
		elseif a == "savePreset" then
			return MonetizationService:SavePreset(p, payload.index)
		elseif a == "applyPreset" then
			return MonetizationService:ApplyPreset(p, payload.index)
		elseif a == "refresh" then
			task.spawn(MonetizationService.RefreshPasses, MonetizationService, p)
			return true, "OK"
		end
		return false, "INVALID_PAYLOAD"
	end)

	if RunService:IsStudio() then
		-- Studio-only test hook: a fake marketplace (no real products are touched) and direct receipt calls
		local hook = ServerStorage:FindFirstChild("PF_StoreHook") or Instance.new("BindableFunction")
		hook.Name = "PF_StoreHook"
		hook.Archivable = false
		;(hook :: BindableFunction).OnInvoke = function(cmd: string, a: any, b: any, c: any)
			if cmd == "fakeMarket" then
				-- a = { ids = { passKey = id, productKey = id }, owned = { [passId] = true }, prices = { [id] = robux }, failInfo = bool }
				local cfg = a or {}
				for key, id in cfg.ids or {} do
					local pass = MonetizationConfig.pass(key)
					local prod = MonetizationConfig.product(key)
					if pass then
						pass.gamePassId = id
					elseif prod then
						prod.productId = id
					end
				end
				table.clear(infoCache)
				local prompts = {}
				market = {
					owns = function(userId: number, passId: number)
						if cfg.ownsError then
							error("fake ownership outage")
						end
						local owned = cfg.owned or {}
						return owned[passId] == true or owned[tostring(passId)] == true
					end,
					info = function(id: number, kind: string)
						if cfg.failInfo then
							error("fake info outage")
						end
						local prices = cfg.prices or {}
						local price = prices[id] or prices[tostring(id)]
						return { PriceInRobux = price, IsForSale = price ~= nil, Name = kind .. id }
					end,
					promptPass = function(p: Player, id: number)
						table.insert(prompts, { kind = "pass", id = id, user = p.UserId })
					end,
					promptProduct = function(p: Player, id: number)
						table.insert(prompts, { kind = "product", id = id, user = p.UserId })
					end,
					prompts = prompts,
				}
				return true
			elseif cmd == "realMarket" then
				market = realMarket
				table.clear(infoCache)
				return true
			elseif cmd == "prompts" then
				return market.prompts or {}
			elseif cmd == "passFinished" then
				onPassFinished(a, b, c == true)
				return true
			elseif cmd == "receipt" then
				local decision = processReceipt(a)
				return decision.Name
			elseif cmd == "refresh" then
				MonetizationService:RefreshPasses(a)
				return true
			elseif cmd == "catalog" then
				return MonetizationService:Catalog(a)
			elseif cmd == "promptPass" then
				return MonetizationService:PromptPass(a, b)
			elseif cmd == "promptProduct" then
				return MonetizationService:PromptProduct(a, b)
			elseif cmd == "launch" then
				lastLaunch[a] = nil
				return MonetizationService:LaunchFireworks(a, false)
			elseif cmd == "state" then
				local d = ProfileService:GetData(a)
				return d and d.monetization
			end
			return nil
		end
		hook.Parent = ServerStorage
	end
end

return MonetizationService
