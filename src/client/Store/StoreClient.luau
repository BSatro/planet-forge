--!strict
-- StoreClient — owner: Monetization (client). Read model + intent requests for the Cosmic Store. No authority:
-- the server verifies ownership, prompts Roblox purchases, processes receipts and equips cosmetics.
--   StoreClient.catalog() -> { passes = {{key, owned, available, price?, reason?}}, products = {...}, presetSlots, fireworks }?
--   StoreClient.refreshCatalog() (yields)   StoreClient.mine() -> { passes = {keys}, fireworks, presets, presetSlots }
--   StoreClient.owns(cosmeticId) / equipped(category)   buyPass(key) / buyProduct(key) / launch() / equip(cat, id)
--   savePreset(i) / applyPreset(i)   reasonText(code)   Signals: Changed(), Notified(msg)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PF_Shared")
local Signal = require(Shared.Util.Signal)
local ProfileClient = require(Shared.Client.ProfileClient)
local EvolutionClient = require(Shared.Client.EvolutionClient)

local StoreClient = {}
StoreClient.Changed = Signal.new()
StoreClient.Notified = Signal.new()

local catalogData: any = nil
local started = false

function StoreClient.request(action: string, payload: { [string]: any }?): (boolean, string, any)
	local p = payload or {}
	p.action = action
	local ok, code, data = ProfileClient.request("Store_Action", p)
	return ok == true, tostring(code), data
end

function StoreClient.refreshCatalog(): any
	local ok, _, data = StoreClient.request("catalog")
	if ok and type(data) == "table" then
		catalogData = data
		StoreClient.Changed:Fire()
	end
	return catalogData
end

function StoreClient.catalog(): any
	return catalogData
end

function StoreClient.mine(): any
	local s = ProfileClient.get()
	local m = s and s.monetization
	return m or { passes = {}, fireworks = 0, presets = {}, presetSlots = 1 }
end

function StoreClient.ownsPass(key: string): boolean
	return table.find(StoreClient.mine().passes, key) ~= nil
end

function StoreClient.owns(cosmeticId: string): boolean
	local s = ProfileClient.get()
	return s ~= nil and table.find(s.cosmetics or {}, cosmeticId) ~= nil
end

function StoreClient.equipped(category: string): string?
	local s = ProfileClient.get()
	local c = s and s.planet and s.planet.cosmetics
	return c and c[category]
end

function StoreClient.buyPass(key: string): (boolean, string)
	local ok, code = StoreClient.request("buyPass", { key = key })
	return ok, code
end

function StoreClient.buyProduct(key: string): (boolean, string)
	local ok, code = StoreClient.request("buyProduct", { key = key })
	return ok, code
end

function StoreClient.launch(): (boolean, string)
	local ok, code = StoreClient.request("launch")
	return ok, code
end

function StoreClient.equip(category: string, cosmeticId: string?): (boolean, string)
	local ok, code = EvolutionClient.setCosmetic(category, cosmeticId or "None")
	return ok == true, tostring(code)
end

function StoreClient.savePreset(i: number): (boolean, string)
	local ok, code = StoreClient.request("savePreset", { index = i })
	return ok, code
end

function StoreClient.applyPreset(i: number): (boolean, string, any)
	return StoreClient.request("applyPreset", { index = i })
end

local REASONS: { [string]: string } = {
	NOT_CONFIGURED = "Not on sale yet.",
	INFO_UNAVAILABLE = "The store can't reach Roblox right now — try again in a moment.",
	NOT_FOR_SALE = "Not on sale right now.",
	ALREADY_OWNED = "You already own this.",
	BUSY_HARVESTING = "Finish harvesting first — purchases never interrupt gameplay.",
	BUSY_EXPEDITION = "Not available during an expedition.",
	PROMPT_FAILED = "Roblox couldn't open the purchase window. Nothing was charged.",
	NONE_LEFT = "You have no Cosmic Fireworks to launch.",
	COOLDOWN = "Your last fireworks show is still lighting up the sky.",
	NO_PLANET = "You need a planet to celebrate around.",
	LOCKED = "That preset slot needs the Extra Planet Design Presets pass.",
	EMPTY = "That preset slot is empty — save your current look into it first.",
	NOT_OWNED = "You don't own that cosmetic.",
	RATE_LIMITED = "One moment…",
	NOT_READY = "Your profile is still loading.",
	TIMEOUT = "The server didn't answer — nothing was charged. Try again.",
}

function StoreClient.reasonText(code: string?): string
	return REASONS[code or ""] or ("Not available (" .. tostring(code) .. ")")
end

function StoreClient.init()
	if started then
		return
	end
	started = true
	ProfileClient.Changed:Connect(function()
		StoreClient.Changed:Fire()
	end)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 30)
		local n = remotes and remotes:WaitForChild("Store_Notify", 30) :: RemoteEvent?
		if n then
			n.OnClientEvent:Connect(function(msg)
				if type(msg) ~= "table" then
					return
				end
				if msg.kind == "passGranted" or msg.kind == "productGranted" then
					task.spawn(StoreClient.refreshCatalog)
				end
				StoreClient.Notified:Fire(msg)
			end)
		end
	end)
end

return StoreClient
