--!strict
-- ReadabilityFX — owner: Technical Art (visual polish pass). Two small, client-only readability aids:
--   * Planet label LOD: PlanetBuilder's PlanetLabel billboards keep their full size up close and shrink with
--     camera distance (8 labels, 6 updates/s), so the sky is no longer lined with eight full-size names.
--   * Explorer fill light: one soft, shadowless PointLight on the LOCAL character so the player reads against
--     the dark night-side lighting of planets and the station (other players are lit by the scene as usual).
-- Pure presentation: no gameplay state, no replication, safe to remove.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReadabilityFX = {}

local LABEL = { near = 450, far = 1900, maxW = 200, minW = 80, ratio = 56 / 200 }
local FILL = { range = 11, brightness = 0.9, color = Color3.fromRGB(255, 240, 225) }

local player = Players.LocalPlayer
local started = false

local function labelTick()
	local cam = Workspace.CurrentCamera
	local world = Workspace:FindFirstChild("PF_World")
	local planets = world and world:FindFirstChild("Planets")
	if not cam or not planets then
		return
	end
	local camPos = cam.CFrame.Position
	for _, slot in planets:GetChildren() do
		local core = slot:FindFirstChild("Core")
		local gui = core and core:FindFirstChild("PlanetLabel")
		if gui and gui:IsA("BillboardGui") and core:IsA("BasePart") then
			local d = (core.Position - camPos).Magnitude
			local k = math.clamp((d - LABEL.near) / (LABEL.far - LABEL.near), 0, 1)
			local w = math.floor(LABEL.maxW + (LABEL.minW - LABEL.maxW) * k + 0.5)
			if gui.Size.X.Offset ~= w then
				gui.Size = UDim2.fromOffset(w, math.floor(w * LABEL.ratio + 0.5))
			end
		end
	end
end

local function attachFill(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root or root:FindFirstChild("PF_ExplorerFill") then
		return
	end
	local l = Instance.new("PointLight")
	l.Name = "PF_ExplorerFill"
	l.Range = FILL.range
	l.Brightness = FILL.brightness
	l.Color = FILL.color
	l.Shadows = false
	l.Parent = root
end

-- Visual effects "minimal" (Settings) = the low preset: no real-time global shadows on this device.
local function applyShadowPreset()
	local Lighting = game:GetService("Lighting")
	local low = player:GetAttribute("PFEffects") == "minimal"
	if low then
		Lighting.GlobalShadows = false
	elseif Lighting:GetAttribute("PFShadowsDefault") ~= nil then
		Lighting.GlobalShadows = Lighting:GetAttribute("PFShadowsDefault") == true
	end
end

function ReadabilityFX.init()
	if started then
		return
	end
	started = true
	local Lighting = game:GetService("Lighting")
	if Lighting:GetAttribute("PFShadowsDefault") == nil then
		Lighting:SetAttribute("PFShadowsDefault", Lighting.GlobalShadows)
	end
	applyShadowPreset()
	player:GetAttributeChangedSignal("PFEffects"):Connect(applyShadowPreset)
	if player.Character then
		task.spawn(attachFill, player.Character)
	end
	player.CharacterAdded:Connect(function(c)
		task.spawn(attachFill, c)
	end)
	task.spawn(function()
		while true do
			local ok, err = pcall(labelTick)
			if not ok then
				warn("[PF][ReadabilityFX] " .. tostring(err))
				task.wait(5)
			end
			task.wait(1 / 6)
		end
	end)
end

return ReadabilityFX
