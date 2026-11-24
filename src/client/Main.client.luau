--!strict
-- PF client boot (Joint). Prototype wiring for the gravity/camera spike.
-- Remote requests use a minimal requestId helper here; replaced by ClientState:Request in M0/M1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Controllers = script.Parent:WaitForChild("Controllers")
local UI = script.Parent:WaitForChild("UI")
local GravityController = require(Controllers:WaitForChild("GravityController"))
local CameraController = require(Controllers:WaitForChild("CameraController"))
local GravityDebugPanel = require(UI:WaitForChild("GravityDebugPanel"))
local Environment = script.Parent:WaitForChild("Environment")
local SpaceBackdrop = require(Environment:WaitForChild("SpaceBackdrop"))
local StationFX = require(Environment:WaitForChild("StationFX"))
local TravelFX = require(Environment:WaitForChild("TravelFX"))
local SkyActivator = require(Environment:WaitForChild("SkyActivator"))
local PlanetVisualController = require(script.Parent:WaitForChild("Planet"):WaitForChild("PlanetVisualController"))

local remotesFolder = ReplicatedStorage:WaitForChild("PF_Remotes", 15)
assert(remotesFolder, "[PF] PF_Remotes missing (server boot failed?)")
local R = {
	Action_Result = remotesFolder:WaitForChild("Action_Result") :: RemoteEvent,
	Travel_Warp = remotesFolder:WaitForChild("Travel_Warp") :: RemoteEvent,
	Character_Recover = remotesFolder:WaitForChild("Character_Recover") :: RemoteEvent,
}

local nextRequestId = 0
local pending: { [number]: string } = {}
local panel: any = nil

local function request(name: string, payload: { [string]: any })
	nextRequestId = (nextRequestId % 2 ^ 30) + 1
	payload.requestId = nextRequestId
	pending[nextRequestId] = name
	;(R :: any)[name]:FireServer(payload)
end

R.Action_Result.OnClientEvent:Connect(function(res)
	if typeof(res) ~= "table" then
		return
	end
	local name = pending[res.requestId] or "?"
	pending[res.requestId] = nil
	if panel then
		panel.setMessage(string.format("%s → %s", name, tostring(res.code)))
	end
end)

GravityController.init({
	recover = function(mode: string)
		request("Character_Recover", { mode = mode })
	end,
	basis = CameraController.getMoveBasis,
})
CameraController.init(GravityController)
TravelFX.onArrive = function()
	GravityController.resetFacing()
	CameraController.snapBehind()
end
-- Same re-framing after every (re)spawn, once the server has placed the character.
game:GetService("Players").LocalPlayer.CharacterAdded:Connect(function()
	task.wait(0.4)
	GravityController.resetFacing()
	CameraController.snapBehind()
end)

-- Environment (client-only visuals). Each is isolated so a visual failure never blocks movement.
for name, fn in { SpaceBackdrop = SpaceBackdrop.build, StationFX = StationFX.init, TravelFX = TravelFX.init, SkyActivator = SkyActivator.init, PlanetVisuals = PlanetVisualController.init, ReadabilityFX = function()
	require(Environment:WaitForChild("ReadabilityFX")).init()
end, AmbientAudio = function()
	require(Environment:WaitForChild("AmbientAudio")).init()
end, AmbientMeteors = function()
	require(Environment:WaitForChild("AmbientMeteors")).init()
end, Store = function()
	require(script.Parent:WaitForChild("Store"):WaitForChild("StoreEntry")).init()
end, Footsteps = function()
	require(script.Parent:WaitForChild("Audio"):WaitForChild("Footsteps")).init(GravityController)
end, MotionFX = function()
	require(script.Parent:WaitForChild("Controllers"):WaitForChild("MotionFX")).init({
		gravity = GravityController,
		camera = CameraController,
		footsteps = require(script.Parent:WaitForChild("Audio"):WaitForChild("Footsteps")),
	})
end } do
	task.spawn(function()
		local ok, err = pcall(fn)
		if not ok then
			warn("[PF] environment init failed:", name, err)
		end
	end)
end

-- Cosmic Core Hunt (Gameplay). Isolated: a failure here never blocks movement/camera.
task.spawn(function()
	local ok, err = pcall(function()
		local HarvestController = require(script.Parent:WaitForChild("Harvest"):WaitForChild("HarvestController"))
		HarvestController.init({ gravity = GravityController })
	end)
	if not ok then
		warn("[PF] harvest init failed:", err)
	end
end)

-- Planet DNA & Evolution feedback (Developer B) + the PLANET FORGE interface (Developer A).
-- The interface replaces Developer B's PlanetLabUI presentation (allowed by its header); if the interface
-- fails to boot, PlanetLabUI is started instead so the evolution gameplay is never without a UI.
task.spawn(function()
	local ok, err = pcall(function()
		local Evo = script.Parent:WaitForChild("Evolution")
		require(Evo:WaitForChild("TransformationFX")).init()
		local UIController = require(UI:WaitForChild("UIController"))
		local booted = UIController.init({ camera = CameraController, visuals = PlanetVisualController, gravity = GravityController })
		if not booted then
			warn("[PF] interface boot failed; falling back to PlanetLabUI")
			require(Evo:WaitForChild("PlanetLabUI")).init()
		end
	end)
	if not ok then
		warn("[PF] evolution UI init failed:", err)
	end
end)

panel = GravityDebugPanel.init(GravityController, {
	recover = function()
		request("Character_Recover", { mode = "recover" })
	end,
	respawn = function()
		request("Character_Recover", { mode = "respawn" })
	end,
	toggleOrbit = CameraController.toggleOrbit,
	warp = function(dest)
		request("Travel_Warp", { destination = dest })
	end,
	getCameraMode = CameraController.getMode,
	cycleEffects = PlanetVisualController.cycleEffects,
	getEffects = PlanetVisualController.getEffects,
})

-- The gravity test panel is a developer tool: Studio only, hidden by default, toggled with F2.
task.spawn(function()
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")
	local dbg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("PF_GravityDebug", 5) :: ScreenGui?
	if dbg then
		dbg.Enabled = false
		if RunService:IsStudio() then
			UserInputService.InputBegan:Connect(function(input, processed)
				if not processed and input.KeyCode == Enum.KeyCode.F2 then
					dbg.Enabled = not dbg.Enabled
				end
			end)
		end
	end
end)

-- Route the Roblox menu "Reset Character" through the server-authoritative respawn.
local resetEvent = Instance.new("BindableEvent")
resetEvent.Event:Connect(function()
	request("Character_Recover", { mode = "respawn" })
end)
task.spawn(function()
	for _ = 1, 20 do
		if pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", resetEvent) then
			return
		end
		task.wait(0.5)
	end
	warn("[PF] could not set ResetButtonCallback")
end)

print("[PF] client booted")
