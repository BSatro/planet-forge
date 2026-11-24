--!strict
-- SprintInput — owner: Planet Physics 3.0. Sprint intent for the local character. No stamina, by design.
--   Keyboard: hold Left Shift.
--   Gamepad:  click L3 (left stick) to toggle; it switches off when the stick is released.
--   Touch:    the SPRINT toggle beside the jump button (UI.SprintButton); also switches off when you stop.
-- Purely local: it only chooses the target speed GravityController steers the client-owned character towards.
-- No remote, no new server trust (the character's physics already belong to its client).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Signal = require(game:GetService("ReplicatedStorage").PF_Shared.Util.Signal)

local SprintInput = {}
SprintInput.Changed = Signal.new() -- (sprinting: boolean) effective state (needs movement)
SprintInput.ToggleChanged = Signal.new() -- (on: boolean) touch / gamepad toggle state

local AUTO_OFF_IDLE = 0.35 -- s without movement input before a toggle switches itself off

local shiftHeld = false
local toggled = false
local active = false
local idleSince: number? = nil

local function setToggled(on: boolean)
	if toggled ~= on then
		toggled = on
		SprintInput.ToggleChanged:Fire(on)
	end
end

function SprintInput.setToggled(on: boolean)
	setToggled(on)
end

function SprintInput.isToggled(): boolean
	return toggled
end

function SprintInput.isActive(): boolean
	return active
end

-- Called by GravityController once per physics step. Returns whether the character should sprint now.
function SprintInput.update(moving: boolean): boolean
	local t = os.clock()
	if moving then
		idleSince = nil
	else
		idleSince = idleSince or t
		if toggled and t - (idleSince :: number) > AUTO_OFF_IDLE then
			setToggled(false)
		end
	end
	local forced = false
	if RunService:IsStudio() then
		local char = Players.LocalPlayer.Character
		forced = char ~= nil and char:GetAttribute("PFTestSprint") == true
	end
	local now = moving and (shiftHeld or toggled or forced)
	if now ~= active then
		active = now
		SprintInput.Changed:Fire(now)
	end
	return now
end

UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		if not processed and not UserInputService:GetFocusedTextBox() then
			shiftHeld = true
		end
	elseif input.KeyCode == Enum.KeyCode.ButtonL3 and not processed then
		setToggled(not toggled)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		shiftHeld = false
	end
end)
-- never leave a stuck sprint after alt-tab or when typing starts
UserInputService.WindowFocusReleased:Connect(function()
	shiftHeld = false
end)
UserInputService.TextBoxFocused:Connect(function()
	shiftHeld = false
end)

return SprintInput
