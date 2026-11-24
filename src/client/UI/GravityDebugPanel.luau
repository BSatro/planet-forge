--!strict
-- GravityDebugPanel — owner: Developer A. Small test HUD: gravity state + test buttons.
-- Device-responsive: UIScale from viewport size, 40px+ touch targets, collapsible. Refreshes at 10 Hz.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local GravityDebugPanel = {}

export type Actions = {
	recover: () -> (),
	respawn: () -> (),
	toggleOrbit: () -> (),
	warp: (destination: string | number) -> (),
	getCameraMode: () -> string,
	cycleEffects: (() -> string)?,
	getEffects: (() -> string)?,
}

local function label(parent: Instance, name: string, order: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.LayoutOrder = order
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 18)
	l.Font = Enum.Font.GothamMedium
	l.TextSize = 14
	l.TextColor3 = Color3.fromRGB(220, 232, 255)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = name
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, order: number, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Name = text
	b.LayoutOrder = order
	b.Size = UDim2.new(0.5, -4, 0, 40)
	b.BackgroundColor3 = Color3.fromRGB(45, 70, 110)
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = b
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

function GravityDebugPanel.init(gravity: any, actions: Actions)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "PF_GravityDebug"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local scale = Instance.new("UIScale")
	scale.Parent = gui
	local function rescale()
		local vp = Workspace.CurrentCamera.ViewportSize
		scale.Scale = math.clamp(math.min(vp.X / 1280, vp.Y / 720) * 1.1, 0.8, 1.25)
	end
	rescale()
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Position = UDim2.new(0, 12, 0, 12)
	panel.Size = UDim2.new(0, 270, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = Color3.fromRGB(12, 16, 28)
	panel.BackgroundTransparency = 0.25
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local pad = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(pad :: any)[side] = UDim.new(0, 10)
	end
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = panel

	local title = label(panel, "PLANET FORGE · Gravity test", 0)
	title.Font = Enum.Font.GothamBlack
	title.TextColor3 = Color3.fromRGB(140, 200, 255)

	local info = Instance.new("Frame")
	info.Name = "Info"
	info.LayoutOrder = 1
	info.BackgroundTransparency = 1
	info.Size = UDim2.new(1, 0, 0, 0)
	info.AutomaticSize = Enum.AutomaticSize.Y
	info.Parent = panel
	local infoList = list:Clone()
	infoList.Padding = UDim.new(0, 0)
	infoList.Parent = info
	local lField = label(info, "Field", 1)
	local lState = label(info, "State", 2)
	local lAlt = label(info, "Altitude", 3)
	local lSpeed = label(info, "Speed", 4)
	local lAlign = label(info, "Upright", 5)
	local lCam = label(info, "Camera", 6)
	local lMsg = label(info, "Last action: -", 7)
	lMsg.TextColor3 = Color3.fromRGB(170, 180, 200)

	local grid = Instance.new("Frame")
	grid.Name = "Buttons"
	grid.LayoutOrder = 2
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.Parent = panel
	local g = Instance.new("UIGridLayout")
	g.CellSize = UDim2.new(0.5, -4, 0, 40)
	g.CellPadding = UDim2.new(0, 8, 0, 6)
	g.SortOrder = Enum.SortOrder.LayoutOrder
	g.Parent = grid
	button(grid, "Recover", 1, actions.recover)
	button(grid, "Respawn", 2, actions.respawn)
	button(grid, "Orbit view", 3, actions.toggleOrbit)
	button(grid, "→ Station", 4, function()
		actions.warp("station")
	end)
	local nextSlot = 0
	button(grid, "→ Next planet", 5, function()
		nextSlot = (nextSlot % 8) + 1
		actions.warp(nextSlot)
	end)
	local fxButton: TextButton? = nil
	if actions.cycleEffects then
		fxButton = button(grid, "Effects: " .. (if actions.getEffects then actions.getEffects() else "full"), 6, function()
			local lvl = (actions.cycleEffects :: () -> string)()
			if fxButton then
				fxButton.Text = "Effects: " .. lvl
			end
		end)
	end
	local hide = button(grid, "Hide", 7, function() end)

	local show = Instance.new("TextButton")
	show.Name = "Show"
	show.Visible = false
	show.Position = UDim2.new(0, 12, 0, 12)
	show.Size = UDim2.new(0, 90, 0, 40)
	show.BackgroundColor3 = Color3.fromRGB(45, 70, 110)
	show.TextColor3 = Color3.new(1, 1, 1)
	show.Font = Enum.Font.GothamBold
	show.TextSize = 14
	show.Text = "Gravity ▸"
	show.Parent = gui
	hide.Activated:Connect(function()
		panel.Visible, show.Visible = false, true
	end)
	show.Activated:Connect(function()
		panel.Visible, show.Visible = true, false
	end)

	gui.Parent = playerGui

	task.spawn(function()
		while gui.Parent do
			if panel.Visible then
				local d = gravity.getDebug()
				lField.Text = string.format("Field: %s (%s, g=%d)", d.field, d.kind, d.strength)
				lState.Text = "State: " .. d.state
				lAlt.Text = string.format("Altitude: %.2f", d.altitude)
				lSpeed.Text = string.format("Speed: %.1f", d.speed)
				lAlign.Text = string.format("Upright (up·normal): %.3f", d.upDot)
				lCam.Text = "Camera: " .. actions.getCameraMode()
			end
			task.wait(0.1)
		end
	end)

	return {
		setMessage = function(text: string)
			lMsg.Text = "Last action: " .. text
		end,
	}
end

return GravityDebugPanel
