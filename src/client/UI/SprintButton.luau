--!strict
-- SprintButton — owner: Planet Physics 3.0. Touch-only SPRINT toggle placed beside the jump button.
-- Tap to sprint, tap again (or stop moving) to walk. Hidden on keyboard/gamepad, while the HUD is hidden
-- (harvesting, cinematics) and while touch controls are disabled. Drives SprintInput only; no physics here.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local UIRoot = require(script.Parent.UIRoot)
local Theme = require(script.Parent.Kit.Theme)
local SprintInput = require(script.Parent.Parent.Controllers.SprintInput)

local Col = Theme.Color
local SprintButton = {}

local btn: TextButton? = nil
local stroke: UIStroke? = nil
local label: TextLabel? = nil
local lastTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local forced = false

local function jumpButton(): GuiObject?
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local tg = pg and pg:FindFirstChild("TouchGui")
	local j = tg and tg:FindFirstChild("JumpButton", true)
	if j and j:IsA("GuiObject") and j.AbsoluteSize.X > 0 then
		return j
	end
	return nil
end

local function place()
	local b = btn
	if not b then
		return
	end
	local gui = UIRoot.gui()
	local vp = gui.AbsoluteSize
	local js: number, jc: Vector2
	local j = jumpButton()
	if j then
		js = math.min(j.AbsoluteSize.X, j.AbsoluteSize.Y)
		jc = j.AbsolutePosition + j.AbsoluteSize / 2 - gui.AbsolutePosition
	elseif math.min(vp.X, vp.Y) <= 500 then
		js, jc = 70, Vector2.new(vp.X - 60, vp.Y - 55) -- default small-screen jump button
	else
		js, jc = 120, Vector2.new(vp.X - 110, vp.Y - 150) -- default large-screen jump button
	end
	local size = math.floor(js * 0.72)
	b.Size = UDim2.fromOffset(size, size)
	b.Position = UDim2.fromOffset(jc.X - js * 0.5 - size * 0.5 - 12, jc.Y + js * 0.18)
	if label then
		label.TextSize = math.max(10, math.floor(size * 0.2))
	end
end

local function paint(on: boolean)
	local b, st, l = btn, stroke, label
	if not b or not st or not l then
		return
	end
	b.BackgroundColor3 = if on then Col.Cyan else Col.Navy
	b.BackgroundTransparency = if on then 0.25 else 0.35
	st.Color = if on then Col.Text else Col.Cyan
	st.Transparency = if on then 0 else 0.35
	st.Thickness = if on then 3 else 2
	l.TextColor3 = if on then Col.Void else Col.Text
end

local function refresh()
	local b = btn
	if not b then
		return
	end
	local touch = forced or (UserInputService.TouchEnabled and lastTouch)
	local ok, touchControls = pcall(function()
		return GuiService.TouchControlsEnabled
	end)
	b.Visible = touch and UIRoot.hudVisible() and (not ok or touchControls ~= false) and Players.LocalPlayer.Character ~= nil
	if b.Visible then
		place()
	end
end

function SprintButton.init(_deps: any?)
	if btn then
		return
	end
	local gui = UIRoot.gui()
	local b = Instance.new("TextButton")
	b.Name = "PF_SprintButton"
	b.Text = ""
	b.AutoButtonColor = false
	b.ZIndex = 6
	b.Visible = false
	b.Active = true
	b.Selectable = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = b
	local st = Instance.new("UIStroke")
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = b
	local l = Instance.new("TextLabel")
	l.Name = "Label"
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Text = "SPRINT"
	l.FontFace = Theme.Font.Display
	l.TextSize = 14
	l.ZIndex = 7
	l.Parent = b
	b.Parent = gui
	btn, stroke, label = b, st, l
	paint(SprintInput.isToggled())
	b.Activated:Connect(function()
		SprintInput.setToggled(not SprintInput.isToggled())
	end)
	SprintInput.ToggleChanged:Connect(paint)
	UIRoot.HudVisibilityChanged:Connect(refresh)
	UserInputService.LastInputTypeChanged:Connect(function(t)
		if t == Enum.UserInputType.Touch then
			lastTouch = true
		elseif t == Enum.UserInputType.Keyboard or t == Enum.UserInputType.MouseButton1 or t.Name:find("Gamepad") then
			lastTouch = false
		end
		refresh()
	end)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TouchControlsEnabled"):Connect(refresh)
	end)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(refresh)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		task.delay(1, refresh) -- the jump button is rebuilt with the character
	end)
	Players.LocalPlayer.CharacterRemoving:Connect(function()
		SprintInput.setToggled(false)
		task.defer(refresh)
	end)
	refresh()
end

-- Studio test hooks (PF_UITest "call"): show the touch button on a desktop session for layout checks.
function SprintButton.testShow()
	if RunService:IsStudio() then
		forced = true
		refresh()
	end
end
function SprintButton.testHide()
	forced = false
	refresh()
end
function SprintButton.testState()
	local b = btn
	return { visible = b and b.Visible, toggled = SprintInput.isToggled(), active = SprintInput.isActive(), pos = b and tostring(b.AbsolutePosition), size = b and tostring(b.AbsoluteSize) }
end

return SprintButton
