--!strict
-- MonetizationConfig — owner: Monetization. THE single product definition table (Game Passes + Developer
-- Products). Read by the server (entitlements, receipts, prompts) and the client (store presentation).
--
-- IDs: create the items on Creator Hub (Experience > Monetization > Passes / Developer Products), then paste the
-- numeric IDs below. While an ID is nil the item is shown as "not on sale yet" and can never be prompted.
-- Prices are NEVER hard-coded for display: the store shows the price Roblox returns for the ID
-- (MarketplaceService:GetProductInfo). `suggestedPriceRobux` is only a balancing note for whoever creates the item.
--
-- Fairness rules (enforced by tests): grants are cosmetic / presentation / celebration only. Nothing here may grant
-- currencies, materials, XP, energy, upgrades, discoveries, branches, stages or expedition access. No paid
-- randomized items: every grant is fixed and listed before purchase.
local MonetizationConfig = {}

MonetizationConfig.VERSION = 1

-- grant keys that are allowed at all (anything else fails validation)
MonetizationConfig.ALLOWED_GRANTS = table.freeze({ cosmetics = true, presetSlots = true, fireworks = true })

-- equippable presentation categories (ItemCatalog.COSMETICS[*].category)
MonetizationConfig.COSMETIC_CATEGORIES = table.freeze({ "Atmosphere", "PlanetRing", "HarvesterFX" })

MonetizationConfig.PASSES = {
	CosmicAtmospheres = {
		key = "CosmicAtmospheres",
		gamePassId = nil :: number?,
		name = "Cosmic Atmosphere Pack",
		tagline = "Four premium atmosphere palettes with aurora sky effects.",
		description = "Adds the Nebula Veil, Solaris Corona, Abyssal Tide and Aurora Mantle atmospheres. Each wraps your planet in its own colour palette with a drifting aurora sky effect that visitors can see. Cosmetic only.",
		icon = "planet",
		color = Color3.fromRGB(160, 120, 255),
		previewCategory = "Atmosphere",
		grants = { cosmetics = { "Atmosphere_Nebula", "Atmosphere_Solaris", "Atmosphere_Abyss", "Atmosphere_Aurora" } },
		suggestedPriceRobux = 199,
		order = 1,
	},
	PremiumRings = {
		key = "PremiumRings",
		gamePassId = nil :: number?,
		name = "Premium Planet Rings",
		tagline = "Three orbiting ring designs for your planet.",
		description = "Adds the Golden Halo, Saturnine Bands and Prism Ring designs, shown around your planet to everyone. Cosmetic only.",
		icon = "formation",
		color = Color3.fromRGB(255, 205, 110),
		previewCategory = "PlanetRing",
		grants = { cosmetics = { "Ring_Halo", "Ring_Saturnine", "Ring_Prism" } },
		suggestedPriceRobux = 149,
		order = 2,
	},
	HarvesterVFX = {
		key = "HarvesterVFX",
		gamePassId = nil :: number?,
		name = "Harvester VFX Bundle",
		tagline = "Three alternative beam and capture effects.",
		description = "Adds the Solar Flare, Void Lance and Aurora Stream styles for your Gravity Harvester's beam, muzzle flash and capture burst. Meteor colours, aim, timing and rewards are unchanged. Cosmetic only.",
		icon = "harvester",
		color = Color3.fromRGB(110, 230, 255),
		previewCategory = "HarvesterFX",
		grants = { cosmetics = { "HarvesterFX_Solar", "HarvesterFX_Void", "HarvesterFX_Aurora" } },
		suggestedPriceRobux = 149,
		order = 3,
	},
	DesignPresets = {
		key = "DesignPresets",
		gamePassId = nil :: number?,
		name = "Extra Planet Design Presets",
		tagline = "Four more saved appearance presets.",
		description = "Adds 4 extra preset slots (5 in total) that remember an atmosphere, ring and harvester style so you can switch looks in one click. Presets only use cosmetics you own and give no progression.",
		icon = "scale",
		color = Color3.fromRGB(120, 255, 190),
		grants = { presetSlots = 4 },
		suggestedPriceRobux = 99,
		order = 4,
	},
}

MonetizationConfig.PRODUCTS = {
	CosmicFireworks = {
		key = "CosmicFireworks",
		productId = nil :: number?,
		name = "Cosmic Fireworks",
		tagline = "A one-time celebration around your planet.",
		description = "One decorative fireworks show (about 10 seconds) bursting around your planet for everyone nearby to see. Purely visual: no rewards, no progression. If you can't launch it right away it is kept until you do.",
		icon = "star",
		color = Color3.fromRGB(255, 120, 200),
		grants = { fireworks = 1 },
		suggestedPriceRobux = 25,
		order = 1,
	},
}

MonetizationConfig.FREE = { presetSlots = 1 }

MonetizationConfig.LIMITS = {
	fireworksStack = 999, -- paid celebrations are never lost; this only guards against corrupt data
	fireworksCooldown = 20, -- seconds between launches by the same player
	fireworksSeconds = 10,
	receiptHistory = 500, -- processed PurchaseIds remembered per player (idempotency)
	ownershipRetries = 3,
	productInfoTtl = 600,
	presetSlotsMax = 10,
}

----------------------------------------------------------------------------------------------------
function MonetizationConfig.pass(key: any): any
	return if type(key) == "string" then (MonetizationConfig.PASSES :: any)[key] else nil
end

function MonetizationConfig.product(key: any): any
	return if type(key) == "string" then (MonetizationConfig.PRODUCTS :: any)[key] else nil
end

function MonetizationConfig.passById(id: any): any
	if type(id) ~= "number" then
		return nil
	end
	for _, p in MonetizationConfig.PASSES do
		if p.gamePassId == id then
			return p
		end
	end
	return nil
end

function MonetizationConfig.productById(id: any): any
	if type(id) ~= "number" then
		return nil
	end
	for _, p in MonetizationConfig.PRODUCTS do
		if p.productId == id then
			return p
		end
	end
	return nil
end

-- The pass that grants a cosmetic (nil for free/earned cosmetics).
function MonetizationConfig.passForCosmetic(cosmeticId: string): any
	for _, p in MonetizationConfig.PASSES do
		local list = p.grants.cosmetics
		if list and table.find(list, cosmeticId) then
			return p
		end
	end
	return nil
end

function MonetizationConfig.sortedPasses(): { any }
	local out = {}
	for _, p in MonetizationConfig.PASSES do
		table.insert(out, p)
	end
	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	return out
end

function MonetizationConfig.sortedProducts(): { any }
	local out = {}
	for _, p in MonetizationConfig.PRODUCTS do
		table.insert(out, p)
	end
	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	return out
end

return MonetizationConfig
