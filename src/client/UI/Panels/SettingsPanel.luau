--!strict
-- SettingsPanel — owner: Developer A. Effects volume, visual effects quality, camera mode / sensitivity /
-- invert, reduced motion and interface scale. Applies instantly (SettingsApplier); kept for the session.
-- Music volume (ambient space music, PF_Music) is separate from effects volume.
local Kit = script.Parent.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Prefs = require(Kit.Prefs)
local UIRoot = require(script.Parent.Parent.UIRoot)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local Settings = {}
local deps: any = {}
function Settings.setDeps(d: any)
	deps = d or {}
end

function Settings.build(shell: any)
	local body: Frame = shell.Body
	shell.Subtitle.Text = "APPLIED INSTANTLY · KEPT FOR THIS SESSION"
	local list = C.scroll({ parent = body, gap = Sp.s })
	local order = 0
	local first: GuiObject? = nil
	local segs: { any } = {}
	local function nextOrder(): number
		order += 1
		return order
	end
	local function section(title: string)
		local h = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = nextOrder(), Parent = list })
		local cap = C.caption(title, h, 0, Col.Cyan)
		cap.Position = UDim2.fromOffset(0, 12)
	end
	local function row(icon: string, title: string, desc: string): Frame
		local f = C.glass({ name = title, variant = "card", dims = UDim2.new(1, 0, 0, 64), parent = list, order = nextOrder() })
		C.icon(icon, 20, Col.Cyan, f).Position = UDim2.fromOffset(16, 22)
		local t = C.text({ text = title, size = S.Body, font = F.Bold, parent = f, dims = UDim2.new(0.5, -40, 0, 20) })
		t.Position = UDim2.fromOffset(50, 12)
		local d = C.text({ text = desc, size = S.Small, color = Col.TextMute, parent = f, dims = UDim2.new(0.5, -40, 0, 18) })
		d.Position = UDim2.fromOffset(50, 34)
		local holder = C.make("Frame", { Name = "Control", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0), Size = UDim2.new(0.5, 0, 1, -16), Parent = f }, { C.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })
		return holder
	end
	local function segmented(holder: Frame, options: { { string } }, get: () -> string, set: (string) -> ())
		local buttons = {}
		local function paint()
			local cur = get()
			for id, b in buttons do
				b:setStyle(if id == cur then "primary" else "ghost")
				b:setSelected(id == cur)
			end
		end
		for i, o in options do
			local b = C.button({ text = o[2], style = "ghost", dims = UDim2.new(0, 0, 0, 32), size = S.Micro, parent = holder, order = i, onClick = function()
				set(o[1])
				paint()
			end })
			b.Instance.AutomaticSize = Enum.AutomaticSize.X
			buttons[o[1]] = b
			first = first or b.Instance
		end
		paint()
		table.insert(segs, paint)
	end
	local function slider(holder: Frame, key: string, fmt: (number) -> string)
		local range = Prefs.RANGES[key]
		local s = C.slider({ min = range[1], max = range[2], step = range[3], value = Prefs.get(key), width = 180, format = fmt, parent = holder, onChange = function(v)
			Prefs.set(key, v)
		end })
		first = first or s.Instance
		return s
	end
	local function toggle(holder: Frame, key: string)
		local t = C.toggle({ value = Prefs.get(key) == true, parent = holder, onChange = function(v)
			Prefs.set(key, v)
		end })
		first = first or t.Instance
		return t
	end
	local pct = function(v: number): string
		return string.format("%d%%", math.round(v * 100))
	end

	section("Audio")
	slider(row("sound", "Effects volume", "Transformations, warps and interface cues"), "EffectsVolume", pct)
	slider(row("sound", "Music volume", "Ambient space music"), "MusicVolume", pct)
	section("Graphics")
	segmented(row("eye", "Visual effects", "Planet detail, particles and evolution effects"), { { "full", "Full" }, { "reduced", "Reduced" }, { "minimal", "Minimal" } }, function()
		return if deps.visuals and deps.visuals.getEffects then deps.visuals.getEffects() else "full"
	end, function(v)
		if deps.visuals and deps.visuals.setEffects then
			deps.visuals.setEffects(v)
		end
	end)
	section("Camera")
	segmented(row("camera", "Camera mode", "Follow your character or orbit the planet"), { { "follow", "Follow" }, { "orbit", "Orbit" } }, function()
		return if deps.camera and deps.camera.getMode then deps.camera.getMode() else "follow"
	end, function(v)
		if deps.camera and deps.camera.setMode then
			deps.camera.setMode(v)
		end
	end)
	slider(row("motion", "Look sensitivity", "Mouse, touch and controller look speed"), "CameraSensitivity", function(v) return string.format("%.1f×", v) end)
	toggle(row("camera", "Invert vertical look", "Up moves the view down"), "InvertY")
	section("Guidance")
	toggle(row("info", "ForgeBot hints", "Short tips from your guide robot"), "ForgeBot")
	do
		local holder = row("back", "Replay tutorial", "Watch the welcome and the guide tips again")
		local b = C.button({ text = "Replay", style = "ghost", dims = UDim2.new(0, 0, 0, 32), size = S.Micro, parent = holder, onClick = function()
			local mod = script.Parent.Parent:FindFirstChild("Onboarding")
			local ok, Onb = pcall(require, mod :: ModuleScript)
			if ok and Onb and Onb.replay then
				Onb.replay()
			end
		end })
		b.Instance.AutomaticSize = Enum.AutomaticSize.X
		first = first or b.Instance
	end
	section("Accessibility")
	toggle(row("motion", "Reduced motion", "Shorter, calmer animations and camera effects"), "ReducedMotion")
	slider(row("scale", "Interface scale", "Size of the whole interface"), "UiScale", pct)

	local impl: any = {}
	function impl.refresh()
		for _, p in segs do
			p()
		end
	end
	function impl.firstSelection(): GuiObject?
		return first
	end
	return impl
end

return Settings
