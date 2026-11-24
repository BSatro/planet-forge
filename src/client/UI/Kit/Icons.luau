--!strict
-- Icons — owner: Developer A. Procedural vector icon set (Frames + UIStroke), so iconography is crisp at
-- any scale, recolourable, and needs no uploaded images. Icons.new(name, sizePx, color) -> Frame.
-- All glyphs are drawn in a unit box (0..1) with one stroke weight for a consistent family look.
local Icons = {}

type Ctx = { root: Frame, color: Color3, px: number, w: number }

local function bar(c: Ctx, x: number, y: number, w: number, h: number, rot: number?, color: Color3?, round: boolean?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.new(w, if w == 0 then c.w else 0, h, if h == 0 then c.w else 0)
	f.Rotation = rot or 0
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color or c.color
	if round ~= false then
		local k = Instance.new("UICorner")
		k.CornerRadius = UDim.new(1, 0)
		k.Parent = f
	end
	f.Parent = c.root
	return f
end

local function ring(c: Ctx, x: number, y: number, d: number, filled: boolean?, aspect: number?, rot: number?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(d, d / (aspect or 1))
	f.Rotation = rot or 0
	f.BorderSizePixel = 0
	f.BackgroundColor3 = c.color
	f.BackgroundTransparency = if filled then 0 else 1
	local k = Instance.new("UICorner")
	k.CornerRadius = UDim.new(1, 0)
	k.Parent = f
	if not filled then
		local s = Instance.new("UIStroke")
		s.Thickness = c.w
		s.Color = c.color
		s.Parent = f
	end
	f.Parent = c.root
	return f
end

local function box(c: Ctx, x: number, y: number, w: number, h: number, filled: boolean?, rot: number?, radius: number?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(w, h)
	f.Rotation = rot or 0
	f.BorderSizePixel = 0
	f.BackgroundColor3 = c.color
	f.BackgroundTransparency = if filled then 0 else 1
	if radius then
		local k = Instance.new("UICorner")
		k.CornerRadius = UDim.new(radius, 0)
		k.Parent = f
	end
	if not filled then
		local s = Instance.new("UIStroke")
		s.Thickness = c.w
		s.Color = c.color
		s.Parent = f
	end
	f.Parent = c.root
	return f
end

local G: { [string]: (Ctx) -> () } = {}
G.dna = function(c)
	for i = 0, 6 do
		local t = i / 6
		local y = 0.12 + t * 0.76
		local s = math.sin(t * math.pi * 2)
		ring(c, 0.5 + s * 0.24, y, 0.13, true)
		ring(c, 0.5 - s * 0.24, y, 0.13, true).BackgroundTransparency = 0.35
		if i % 2 == 1 then
			bar(c, 0.5, y, math.abs(s) * 0.44 + 0.02, 0).BackgroundTransparency = 0.45
		end
	end
end
G.harvester = function(c)
	ring(c, 0.5, 0.5, 0.62)
	ring(c, 0.5, 0.5, 0.14, true)
	bar(c, 0.5, 0.1, 0, 0.18)
	bar(c, 0.5, 0.9, 0, 0.18)
	bar(c, 0.1, 0.5, 0.18, 0)
	bar(c, 0.9, 0.5, 0.18, 0)
end
G.expedition = function(c)
	ring(c, 0.5, 0.5, 0.8)
	box(c, 0.5, 0.5, 0.2, 0.2, true, 45)
	bar(c, 0.5, 0.33, 0.12, 0.34, 0, nil, false).Rotation = 0
	box(c, 0.5, 0.36, 0.13, 0.13, true, 45)
end
G.codex = function(c)
	box(c, 0.3, 0.5, 0.34, 0.68, false, -6, 0.12)
	box(c, 0.7, 0.5, 0.34, 0.68, false, 6, 0.12)
	bar(c, 0.5, 0.52, 0, 0.62)
end
G.inventory = function(c)
	box(c, 0.3, 0.3, 0.3, 0.3, false, 0, 0.2)
	box(c, 0.7, 0.3, 0.3, 0.3, false, 0, 0.2)
	box(c, 0.3, 0.7, 0.3, 0.3, false, 0, 0.2)
	box(c, 0.7, 0.7, 0.3, 0.3, true, 0, 0.2)
end
G.settings = function(c)
	for i = 0, 7 do
		local a = i * math.pi / 4
		box(c, 0.5 + math.cos(a) * 0.34, 0.5 + math.sin(a) * 0.34, 0.16, 0.16, true, math.deg(a), 0.25)
	end
	ring(c, 0.5, 0.5, 0.56)
	ring(c, 0.5, 0.5, 0.2)
end
G.credits = function(c)
	ring(c, 0.5, 0.5, 0.84, true)
	local inner = ring(c, 0.5, 0.5, 0.56)
	inner:FindFirstChildOfClass("UIStroke").Color = Color3.new(0, 0, 0)
	inner:FindFirstChildOfClass("UIStroke").Transparency = 0.55
	bar(c, 0.5, 0.5, 0, 0.32, 0, Color3.new(0, 0, 0)).BackgroundTransparency = 0.55
end
G.energy = function(c)
	bar(c, 0.56, 0.3, 0, 0.44, 24, nil, false)
	bar(c, 0.44, 0.7, 0, 0.44, 24, nil, false)
	bar(c, 0.5, 0.5, 0.36, 0, -10, nil, false)
end
G.close = function(c)
	bar(c, 0.5, 0.5, 0.78, 0, 45)
	bar(c, 0.5, 0.5, 0.78, 0, -45)
end
G.planet = function(c)
	ring(c, 0.5, 0.5, 0.56, true)
	ring(c, 0.5, 0.52, 0.98, false, 3.2, -18)
end
G.objective = function(c)
	box(c, 0.5, 0.5, 0.58, 0.58, false, 45)
	ring(c, 0.5, 0.5, 0.16, true)
end
G.check = function(c)
	bar(c, 0.38, 0.62, 0.32, 0, 45)
	bar(c, 0.6, 0.5, 0.56, 0, -50)
end
G.lock = function(c)
	ring(c, 0.5, 0.38, 0.4)
	box(c, 0.5, 0.64, 0.6, 0.4, true, 0, 0.18)
end
G.star = function(c)
	box(c, 0.5, 0.5, 0.48, 0.48, true, 0, 0.1)
	box(c, 0.5, 0.5, 0.48, 0.48, true, 45, 0.1)
end
G.chevron = function(c)
	bar(c, 0.48, 0.35, 0.36, 0, 45)
	bar(c, 0.48, 0.65, 0.36, 0, -45)
end
G.back = function(c)
	bar(c, 0.52, 0.35, 0.36, 0, -45)
	bar(c, 0.52, 0.65, 0.36, 0, 45)
end
G.flask = function(c)
	bar(c, 0.5, 0.24, 0, 0.36)
	ring(c, 0.5, 0.64, 0.58)
	ring(c, 0.5, 0.7, 0.22, true).BackgroundTransparency = 0.25
end
G.formation = function(c)
	bar(c, 0.34, 0.52, 0.56, 0, -58)
	bar(c, 0.66, 0.52, 0.56, 0, 58)
	bar(c, 0.5, 0.78, 0.78, 0)
end
G.flag = function(c)
	bar(c, 0.28, 0.5, 0, 0.8)
	box(c, 0.56, 0.32, 0.5, 0.32, true, 0, 0.12)
end
G.info = function(c)
	ring(c, 0.5, 0.5, 0.84)
	bar(c, 0.5, 0.58, 0, 0.3)
	ring(c, 0.5, 0.32, 0.1, true)
end
G.warning = function(c)
	box(c, 0.5, 0.5, 0.6, 0.6, false, 45, 0.1)
	bar(c, 0.5, 0.45, 0, 0.24)
	ring(c, 0.5, 0.66, 0.08, true)
end
G.plus = function(c)
	bar(c, 0.5, 0.5, 0.66, 0)
	bar(c, 0.5, 0.5, 0, 0.66)
end
G.minus = function(c)
	bar(c, 0.5, 0.5, 0.66, 0)
end
G.sort = function(c)
	bar(c, 0.5, 0.28, 0.72, 0)
	bar(c, 0.42, 0.5, 0.56, 0)
	bar(c, 0.34, 0.72, 0.4, 0)
end
G.travel = function(c)
	bar(c, 0.44, 0.5, 0.64, 0)
	bar(c, 0.66, 0.36, 0.3, 0, 45)
	bar(c, 0.66, 0.64, 0.3, 0, -45)
end
G.matter = function(c)
	box(c, 0.5, 0.5, 0.56, 0.56, true, 45, 0.12)
	box(c, 0.5, 0.42, 0.18, 0.18, true, 45, 0.2).BackgroundColor3 = Color3.new(1, 1, 1)
end
G.catalyst = function(c)
	ring(c, 0.5, 0.5, 0.42, true)
	ring(c, 0.5, 0.5, 0.86)
	ring(c, 0.5, 0.5, 0.86, false, 2.6, 60)
end
G.level = function(c)
	box(c, 0.5, 0.52, 0.62, 0.62, false, 45, 0.1)
	bar(c, 0.5, 0.44, 0.22, 0, -45)
	bar(c, 0.5, 0.44, 0.22, 0, 45)
end
G.sound = function(c)
	box(c, 0.28, 0.5, 0.2, 0.32, true, 0, 0.2)
	bar(c, 0.44, 0.5, 0.3, 0, 90, nil, false).Size = UDim2.new(0, c.w * 2.2, 0.56, 0)
	ring(c, 0.56, 0.5, 0.52, false, 0.5)
	ring(c, 0.6, 0.5, 0.84, false, 0.5)
end
G.eye = function(c)
	ring(c, 0.5, 0.5, 0.86, false, 1.8)
	ring(c, 0.5, 0.5, 0.26, true)
end
G.camera = function(c)
	box(c, 0.44, 0.54, 0.6, 0.44, false, 0, 0.15)
	box(c, 0.84, 0.54, 0.16, 0.3, true, 0, 0.2)
end
G.motion = function(c)
	bar(c, 0.56, 0.3, 0.6, 0)
	bar(c, 0.46, 0.5, 0.6, 0)
	bar(c, 0.6, 0.7, 0.5, 0)
end
G.scale = function(c)
	box(c, 0.4, 0.6, 0.44, 0.44, false, 0, 0.12)
	box(c, 0.62, 0.38, 0.56, 0.56, false, 0, 0.12).BackgroundTransparency = 1
end
G.rocket = G.expedition
G.timer = function(c)
	ring(c, 0.5, 0.54, 0.76)
	bar(c, 0.5, 0.42, 0, 0.26)
	bar(c, 0.59, 0.56, 0.2, 0, 35)
	bar(c, 0.5, 0.1, 0.24, 0)
end
G.team = function(c)
	ring(c, 0.34, 0.36, 0.26, true)
	ring(c, 0.66, 0.36, 0.26, true)
	box(c, 0.34, 0.74, 0.38, 0.3, true, 0, 0.4)
	box(c, 0.66, 0.74, 0.38, 0.3, true, 0, 0.4)
end

G.store = function(c)
	box(c, 0.5, 0.62, 0.66, 0.5, false, 0, 0.12)
	ring(c, 0.5, 0.34, 0.34)
	bar(c, 0.5, 0.6, 0.22, 0)
end

function Icons.has(name: string): boolean
	return G[name] ~= nil
end

function Icons.new(name: string, sizePx: number, color: Color3): Frame
	local root = Instance.new("Frame")
	root.Name = "Icon_" .. name
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(sizePx, sizePx)
	root.ClipsDescendants = false
	local c: Ctx = { root = root, color = color, px = sizePx, w = math.max(1.4, sizePx * 0.085) }
	local g = G[name] or G.info
	g(c)
	return root
end

-- Recolour an icon built by Icons.new (keeps intentional black/white accents)
function Icons.recolor(icon: Instance, color: Color3)
	for _, d in icon:GetDescendants() do
		if d:IsA("Frame") then
			local c = d.BackgroundColor3
			if not (c == Color3.new(0, 0, 0) or c == Color3.new(1, 1, 1)) then
				d.BackgroundColor3 = color
			end
		elseif d:IsA("UIStroke") and d.Color ~= Color3.new(0, 0, 0) then
			d.Color = color
		end
	end
end

return Icons
