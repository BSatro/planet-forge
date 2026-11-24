--!strict
-- VisualStyle — owner: Developer A. Single source for the PLANET FORGE palette and shared visual helpers.
-- Pure data + Instance-free helpers, safe on server and client.

local VisualStyle = {}

VisualStyle.Color = table.freeze({
	Cyan = Color3.fromRGB(70, 230, 255),
	Violet = Color3.fromRGB(165, 95, 255),
	Magenta = Color3.fromRGB(255, 85, 200),
	Reactor = Color3.fromRGB(128, 72, 255),
	Hull = Color3.fromRGB(38, 42, 56),
	HullLight = Color3.fromRGB(62, 68, 88),
	Deck = Color3.fromRGB(56, 62, 80),
	Panel = Color3.fromRGB(82, 90, 114),
	TrimDark = Color3.fromRGB(24, 26, 36),
	Glass = Color3.fromRGB(120, 210, 255),
	Text = Color3.fromRGB(230, 240, 255),
	RockBase = Color3.fromRGB(112, 110, 106),
})

-- One identification colour per planet slot (dock gate, floor guide line, planet label, hologram).
VisualStyle.SlotColors = table.freeze({
	Color3.fromRGB(70, 230, 255), -- 1 cyan
	Color3.fromRGB(170, 120, 255), -- 2 violet
	Color3.fromRGB(255, 95, 200), -- 3 magenta
	Color3.fromRGB(255, 170, 70), -- 4 amber
	Color3.fromRGB(140, 255, 130), -- 5 lime
	Color3.fromRGB(95, 165, 255), -- 6 sky
	Color3.fromRGB(255, 125, 110), -- 7 coral
	Color3.fromRGB(255, 225, 100), -- 8 gold
})

-- Future planet themes (progression). Starting planets are ALWAYS "barren".
VisualStyle.Themes = table.freeze({ "barren", "living", "frozen", "volcanic", "crystal", "astral", "void", "desert", "mechanical" })

-- Engine-bundled textures (rbxasset://) are used for FX because they always load (no asset permissions).
VisualStyle.Texture = table.freeze({
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Fire = "rbxasset://textures/particles/fire_main.dds",
})

function VisualStyle.slotColor(slot: number): Color3
	return VisualStyle.SlotColors[((slot - 1) % #VisualStyle.SlotColors) + 1]
end

return VisualStyle
