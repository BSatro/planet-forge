--!strict
-- Theme — owner: Developer A. Central design tokens for every PLANET FORGE interface.
-- Change a value here, never inline in a screen. Art direction: dark cosmic navy / deep violet panels,
-- electric cyan as the primary signal colour, restrained magenta for emphasis, holographic glass surfaces.
local rgb = Color3.fromRGB
local Theme = {}

Theme.Color = {
	Void = rgb(4, 6, 16),
	Navy = rgb(9, 13, 32),
	Panel = rgb(13, 18, 42),
	PanelHi = rgb(22, 29, 64),
	PanelLo = rgb(7, 10, 24),
	Violet = rgb(52, 32, 104),
	VioletDeep = rgb(24, 15, 54),
	Cyan = rgb(86, 222, 255),
	CyanDim = rgb(52, 140, 190),
	Magenta = rgb(255, 92, 206),
	MagentaDim = rgb(150, 60, 140),
	Text = rgb(234, 242, 255),
	TextDim = rgb(164, 178, 214),
	TextMute = rgb(104, 116, 156),
	Success = rgb(98, 234, 170),
	Warn = rgb(255, 198, 100),
	Danger = rgb(255, 98, 124),
	Gold = rgb(255, 216, 122),
	Shadow = rgb(0, 0, 0),
}

-- 0 = opaque, 1 = invisible (Roblox transparency)
Theme.Alpha = {
	Panel = 0.08,
	Card = 0.35,
	Field = 0.55,
	Stroke = 0.62,
	StrokeHover = 0.2,
	StrokeActive = 0,
	Scrim = 0.35,
	Disabled = 0.55,
}

local function fam(name: string, weight: Enum.FontWeight): Font
	return Font.new("rbxasset://fonts/families/" .. name .. ".json", weight)
end
Theme.Font = {
	Display = fam("Michroma", Enum.FontWeight.Regular), -- titles, numbers in headers, wide sci-fi caps
	Body = fam("TitilliumWeb", Enum.FontWeight.Regular),
	Semi = fam("TitilliumWeb", Enum.FontWeight.SemiBold),
	Bold = fam("TitilliumWeb", Enum.FontWeight.Bold),
}

-- type scale (design pixels; the UI root's UIScale maps design pixels to the screen)
Theme.Size = { Hero = 28, Title = 19, Heading = 15, Body = 15, Small = 13, Micro = 11 }
Theme.Space = { xxs = 2, xs = 4, s = 8, m = 12, l = 16, xl = 24, xxl = 32 }
Theme.Radius = { s = 6, m = 10, l = 14 }
Theme.Stroke = { thin = 1, base = 1.5, bold = 2 }
Theme.Motion = { fast = 0.12, base = 0.2, slow = 0.32, panel = 0.24, tooltipDelay = 0.35 }
-- DisplayOrder of the ScreenGuis / ZIndex bands inside PF_UI
Theme.Layer = { World = 5, Hud = 10, Panel = 20, Modal = 40, Overlay = 50, Toast = 60, Tooltip = 70 }

-- Design canvas: layouts are authored at this size, then scaled to the screen (see UIRoot).
Theme.Canvas = { width = 1280, height = 740, minScale = 0.72, maxScale = 1.35, narrowBelow = 720, shortBelow = 520 }

-- Status colours used by reaction/branch/codex states coming from EvolutionClient.
Theme.Status = {
	AVAILABLE = rgb(98, 234, 170),
	NEEDS_MATERIALS = rgb(255, 198, 100),
	LOCKED = rgb(104, 116, 156),
	DONE = rgb(86, 222, 255),
	MASTERED = rgb(255, 216, 122),
	COMMITTED = rgb(255, 92, 206),
	FUTURE = rgb(80, 88, 124),
}

return table.freeze(Theme)
