--!strict
-- WorldUI — owner: Developer A. Interface elements that live in the 3D world:
--   * waypoint marker (pointTo("harvester" | "stationPad"), clear()) with live distance
--   * planet hover card (desktop): planet, owner avatar + name, stage, branch — from the public slot attributes
--   * planet labels restyled + owner avatar (labels are Developer A's PlanetBuilder billboards)
--   * custom interaction prompts for every ProximityPrompt (keyboard / controller / touch, hold progress)
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)
local Shared = ReplicatedStorage.PF_Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local okHL, HarvestLayout = pcall(function()
	return require(Shared.Harvest.HarvestLayout)
end)
local okPVP, Profile = pcall(function()
	return require(Shared.Planet.PlanetVisualProfile)
end)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local WorldUI = {}

----------------------------------------------------------------------------------------------------
-- avatars (cached; mock/test owner ids simply have no image)
local avatarCache: { [number]: string } = {}
local function avatar(userId: number, cb: (string) -> ())
	if userId <= 0 then
		return
	end
	if avatarCache[userId] then
		cb(avatarCache[userId])
		return
	end
	task.spawn(function()
		local ok, img = pcall(Players.GetUserThumbnailAsync, Players, userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		if ok and img then
			avatarCache[userId] = img
			cb(img)
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- waypoint
local wp: any = {}
local function targetPosition(kind: string): Vector3?
	local slot = UIData.slot()
	if not slot then
		return nil
	end
	if kind == "harvester" and okHL and HarvestLayout and HarvestLayout.getBaseCFrame then
		local ok, cf = pcall(HarvestLayout.getBaseCFrame, slot)
		if ok and cf then
			return cf.Position + cf.UpVector * 6
		end
	elseif kind == "riftPortal" then
		local w = Workspace:FindFirstChild("PF_World")
		local st = w and w:FindFirstChild("Station")
		local surf = st and st:FindFirstChild("RiftSurface", true) :: BasePart?
		return surf and surf.Position + Vector3.new(0, 4, 0)
	elseif kind == "stationPad" and WorldLayout.getStationPadPosition then
		return WorldLayout.getStationPadPosition(slot) + Vector3.new(0, 5, 0)
	end
	return nil
end

function WorldUI.clear()
	wp.kind = nil
	if wp.gui then
		wp.gui.Enabled = false
	end
	if wp.edge then
		wp.edge.Enabled = false
	end
end

-- First 10 Minutes 2.0: off-screen direction indicator for the waypoint (one ScreenGui, built once)
local function buildEdge()
	local g = C.make("ScreenGui", { Name = "PF_WaypointEdge", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 12, Enabled = false, Parent = player:WaitForChild("PlayerGui") })
	local badge = C.make("Frame", { Name = "Badge", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(46, 46), BackgroundColor3 = Col.Navy, BackgroundTransparency = 0.15, Parent = g }, { C.corner(23), C.stroke(Col.Magenta, 0.15, 2) })
	C.gradient(Color3.fromRGB(46, 62, 130), Col.VioletDeep, 90).Parent = badge
	local arrowHolder = C.make("Frame", { Name = "Arrow", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), Parent = badge })
	local ic = C.icon("chevron", 22, Col.Cyan, arrowHolder)
	ic.Position = UDim2.fromOffset(0, 0)
	local dist = C.text({ text = "", size = 12, font = F.Bold, color = Col.Text, align = Enum.TextXAlignment.Center, parent = g, dims = UDim2.fromOffset(120, 16) })
	dist.AnchorPoint = Vector2.new(0.5, 0)
	dist.TextStrokeTransparency = 0.35
	wp.edge, wp.edgeBadge, wp.edgeArrow, wp.edgeDist = g, badge, arrowHolder, dist
end

local function updateEdge(target: Vector3, title: string, meters: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if not wp.edge then
		buildEdge()
	end
	local vp = cam.ViewportSize
	local p, onScreen = cam:WorldToViewportPoint(target)
	-- safe rectangle: clear of the left HUD column edge, the right-hand dock and the bottom controls
	local left, right, top, bottom = 70, vp.X - 140, 80, vp.Y - 110
	if onScreen and p.Z > 0 and p.X > left and p.X < right and p.Y > top and p.Y < bottom then
		wp.edge.Enabled = false
		return
	end
	local c = Vector2.new((left + right) / 2, (top + bottom) / 2)
	local d = Vector2.new(p.X, p.Y) - c
	if p.Z < 0 then
		d = -d -- behind the camera: point the other way
	end
	if d.Magnitude < 1 then
		d = Vector2.new(0, 1)
	end
	local half = Vector2.new((right - left) / 2, (bottom - top) / 2)
	local k = math.min(math.abs(half.X / d.X), math.abs(half.Y / d.Y))
	local pos = c + d * k
	wp.edge.Enabled = true
	wp.edgeBadge.Position = UDim2.fromOffset(pos.X, pos.Y)
	wp.edgeArrow.Rotation = math.deg(math.atan2(d.Y, d.X))
	wp.edgeDist.Text = string.format("%s · %dm", title, meters)
	wp.edgeDist.Position = UDim2.fromOffset(pos.X, pos.Y + 26)
end

-- generic marker (missions): stays until cleared or replaced
function WorldUI.pointAt(pos: Vector3, title: string)
	WorldUI.pointTo("custom", pos, title)
end

function WorldUI.pointTo(kind: string, customPos: Vector3?, customTitle: string?)
	local pos = if kind == "custom" then customPos else targetPosition(kind);
	(wp :: any).title = customTitle;
	(wp :: any).sticky = kind == "custom"
	if not pos then
		WorldUI.clear()
		return
	end
	if not wp.gui then
		local att = Instance.new("Attachment")
		att.Name = "PF_Waypoint"
		att.Parent = Workspace.Terrain
		local g = C.make("BillboardGui", { Name = "PF_Waypoint", AlwaysOnTop = true, LightInfluence = 0, Size = UDim2.fromOffset(150, 74), Adornee = att, ResetOnSpawn = false, ClipsDescendants = false, Parent = player:WaitForChild("PlayerGui") })
		local holder = C.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = g })
		local dia = C.make("Frame", { Name = "Diamond", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(26, 26), Rotation = 45, BackgroundColor3 = Col.Magenta, BackgroundTransparency = 0.15, Parent = holder }, { C.corner(5), C.stroke(Col.Text, 0.2, 2) })
		local _ = dia
		local label = C.text({ text = "", size = 14, font = F.Bold, color = Col.Text, align = Enum.TextXAlignment.Center, parent = holder, dims = UDim2.new(1, 0, 0, 18) })
		label.Position = UDim2.fromOffset(0, 40)
		label.TextStrokeTransparency = 0.4
		wp.gui, wp.att, wp.label = g, att, label
		-- gentle bob (off under reduced motion)
		local t = 0
		wp.conn = RunService.RenderStepped:Connect(function(dt)
			if not (wp.gui and wp.gui.Enabled and wp.att) then
				return
			end
			t += dt
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and wp.label then
				local d = (root.Position - wp.att.WorldPosition).Magnitude
				local title = wp.title or (if wp.kind == "harvester" then "HARVESTER" elseif wp.kind == "riftPortal" then "RIFT PORTAL" else "YOUR DOCK PAD")
				wp.label.Text = string.format("%s · %dm", title, math.floor(d / 3.57))
				if d < 14 and not wp.sticky then
					WorldUI.clear()
				else
					updateEdge(wp.att.WorldPosition, title, math.floor(d / 3.57))
				end
			end
			if not player:GetAttribute("PFReducedMotion") then
				(wp.gui :: BillboardGui).StudsOffsetWorldSpace = Vector3.new(0, math.sin(t * 2.4) * 0.6, 0)
			end
		end)
	end
	(wp.att :: Attachment).WorldPosition = pos
	wp.kind = kind;
	(wp.gui :: BillboardGui).Enabled = true
end

----------------------------------------------------------------------------------------------------
-- planet hover card (desktop pointer)
local hover: any = {}
local function buildHover()
	local card = C.glass({ name = "PlanetHover", variant = "panel", dims = UDim2.fromOffset(250, 0), parent = UIRoot.layer("World") })
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.Visible = false
	C.pad(Sp.m, Sp.l, Sp.m, Sp.l).Parent = card
	local av = C.make("ImageLabel", { Name = "Avatar", BackgroundColor3 = Col.PanelHi, Size = UDim2.fromOffset(40, 40), Image = "", Parent = card }, { C.corner(20), C.stroke(Col.Cyan, 0.4) })
	local info = C.make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(52, 0), Size = UDim2.new(1, -52, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card }, { C.list(Enum.FillDirection.Vertical, 2) })
	hover.title = C.text({ text = "", size = S.Small, font = F.Display, parent = info, order = 1 })
	hover.owner = C.text({ text = "", size = S.Body, font = F.Bold, color = Col.Cyan, parent = info, order = 2 })
	hover.stage = C.text({ text = "", size = S.Small, color = Col.TextDim, parent = info, order = 3 })
	hover.card, hover.avatar = card, av
end

local function planetCores(): { BasePart }
	local out = {}
	local w = Workspace:FindFirstChild("PF_World")
	local planets = w and w:FindFirstChild("Planets")
	if planets then
		for _, s in planets:GetChildren() do
			local core = s:FindFirstChild("Core")
			if core and core:IsA("BasePart") then
				table.insert(out, core)
			end
		end
	end
	return out
end

local hoverParams = RaycastParams.new()
hoverParams.FilterType = Enum.RaycastFilterType.Include
local lastHoverSlot: Model? = nil
local function updateHover()
	if not hover.card then
		return
	end
	local canHover = UserInputService.MouseEnabled and UIRoot.current() == nil and UIRoot.hudVisible() and not UIData.isHarvesting()
	if not canHover then
		hover.card.Visible = false
		lastHoverSlot = nil
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	local cam = Workspace.CurrentCamera
	local ray = cam:ViewportPointToRay(mouse.X, mouse.Y)
	hoverParams.FilterDescendantsInstances = planetCores()
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 3000, hoverParams)
	local slotModel = hit and hit.Instance.Parent :: Model?
	if not slotModel or not slotModel:IsA("Model") then
		hover.card.Visible = false
		lastHoverSlot = nil
		return
	end
	-- skip the planet you stand on (the ground under the cursor is not a "hover")
	local slotNum = tonumber(string.match(slotModel.Name, "%d+"))
	if slotNum and slotNum == UIData.slot() and UIData.onOwnPlanet() then
		hover.card.Visible = false
		return
	end
	if slotModel ~= lastHoverSlot then
		lastHoverSlot = slotModel
		local owner = slotModel:GetAttribute("PFOwnerUserId") or 0
		local name = slotModel:GetAttribute("PFOwnerName") or ""
		local stage = slotModel:GetAttribute("PFStage") or 0
		local branch = slotModel:GetAttribute("PFBranch") or "None"
		hover.title.Text = string.format("PLANET %02d", slotNum or 0)
		hover.owner.Text = if owner > 0 then (if owner == player.UserId then "Your planet" else (if name ~= "" then name else "Claimed")) else "Unclaimed"
		local stageName = if okPVP and Profile.STAGE_NAMES then Profile.STAGE_NAMES[stage] else tostring(stage)
		hover.stage.Text = string.format("Stage %d · %s%s", stage, stageName or "", if branch ~= "None" then " · " .. branch else "")
		hover.avatar.Image = ""
		hover.avatar.Visible = owner > 0
		avatar(owner, function(img)
			if lastHoverSlot == slotModel then
				hover.avatar.Image = img
			end
		end)
	end
	local scale = UIRoot.gui().Canvas:FindFirstChildOfClass("UIScale")
	local s = if scale then scale.Scale else 1
	local inset = GuiService:GetGuiInset()
	local origin = UIRoot.gui().Canvas.AbsolutePosition
	local p = (mouse - inset - origin) / s
	hover.card.Position = UDim2.fromOffset(p.X + 18, p.Y + 18)
	hover.card.Visible = true
end

----------------------------------------------------------------------------------------------------
-- planet labels: premium fonts + owner avatar (labels created by PlanetBuilder, text set by PlanetVisualController)
local function styleLabel(slotModel: Model)
	local core = slotModel:FindFirstChild("Core")
	local label = core and core:FindFirstChild("PlanetLabel")
	if not label or not label:IsA("BillboardGui") then
		return
	end
	local title = label:FindFirstChild("Title") :: TextLabel?
	local owner = label:FindFirstChild("Owner") :: TextLabel?
	if title then
		title.FontFace = F.Display
	end
	if owner then
		owner.FontFace = F.Semi
	end
	local img = label:FindFirstChild("PF_Avatar") :: ImageLabel?
	if not img then
		img = C.make("ImageLabel", { Name = "PF_Avatar", BackgroundColor3 = Col.Navy, BackgroundTransparency = 0.2, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -2), Size = UDim2.fromOffset(34, 34), Image = "", Visible = false, Parent = label }, { C.corner(17), C.stroke(Col.Cyan, 0.3, 2) })
	end
	local function upd()
		local id = slotModel:GetAttribute("PFOwnerUserId") or 0
		local im = img :: ImageLabel
		im.Visible = false
		avatar(id, function(url)
			if (slotModel:GetAttribute("PFOwnerUserId") or 0) == id then
				im.Image = url
				im.Visible = true
			end
		end)
	end
	slotModel:GetAttributeChangedSignal("PFOwnerUserId"):Connect(upd)
	upd()
end

----------------------------------------------------------------------------------------------------
-- custom proximity prompts
local promptGuis: { [ProximityPrompt]: any } = {}
local function keyText(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		local map = { ButtonX = "X", ButtonY = "Y", ButtonA = "A", ButtonB = "B", ButtonR1 = "RB", ButtonL1 = "LB" }
		return map[prompt.GamepadKeyCode.Name] or prompt.GamepadKeyCode.Name
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		return "TAP"
	end
	return prompt.KeyboardKeyCode.Name
end

local function onPromptShown(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		return
	end
	local entry = promptGuis[prompt]
	if not entry then
		local g = C.make("BillboardGui", { Name = "PF_Prompt", AlwaysOnTop = true, LightInfluence = 0, Size = UDim2.fromOffset(250, 64), StudsOffset = Vector3.new(0, 0.5, 0), ResetOnSpawn = false, Active = true, Parent = player:WaitForChild("PlayerGui") })
		local card = C.glass({ name = "Card", variant = "panel", dims = UDim2.fromScale(1, 1), parent = g })
		local key = C.make("TextButton", { Name = "Key", Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(48, 48), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = Col.Cyan, BackgroundTransparency = 0.05, Parent = card }, { C.corner(10) })
		local keyLabel = C.text({ text = "E", size = 18, font = F.Display, color = Col.Navy, align = Enum.TextXAlignment.Center, dims = UDim2.fromScale(1, 1), parent = key })
		local ring = C.make("Frame", { Name = "Hold", BackgroundColor3 = Col.Magenta, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(0, 0, 0, 4), Parent = key }, { C.corner(2) })
		local action = C.text({ text = "", size = 17, font = F.Bold, parent = card, dims = UDim2.new(1, -72, 0, 24) })
		action.Position = UDim2.fromOffset(66, 8)
		local object = C.text({ text = "", size = 13, font = F.Semi, color = Col.TextDim, parent = card, dims = UDim2.new(1, -72, 0, 18) })
		object.Position = UDim2.fromOffset(66, 34)
		-- touch: the key button triggers the prompt
		key.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				prompt:InputHoldBegin()
			end
		end)
		key.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				prompt:InputHoldEnd()
			end
		end)
		entry = { gui = g, key = keyLabel, ring = ring, action = action, object = object, conns = {} }
		table.insert(entry.conns, prompt.PromptButtonHoldBegan:Connect(function()
			if prompt.HoldDuration > 0 then
				ring.Size = UDim2.new(0, 0, 0, 4)
				Motion.tween(ring, prompt.HoldDuration, { Size = UDim2.new(1, 0, 0, 4) }, Enum.EasingStyle.Linear, nil, "hold")
			end
		end))
		table.insert(entry.conns, prompt.PromptButtonHoldEnded:Connect(function()
			Motion.tween(ring, 0.1, { Size = UDim2.new(0, 0, 0, 4) }, nil, nil, "hold")
		end))
		table.insert(entry.conns, prompt.Destroying:Connect(function()
			g:Destroy()
			promptGuis[prompt] = nil
		end))
		promptGuis[prompt] = entry
	end
	entry.gui.Adornee = prompt.Parent :: any
	entry.key.Text = keyText(prompt, inputType)
	entry.key.TextSize = if #entry.key.Text > 2 then 12 else 18
	entry.action.Text = prompt.ActionText
	entry.object.Text = prompt.ObjectText
	entry.gui.Enabled = true
end

local function onPromptHidden(prompt: ProximityPrompt)
	local entry = promptGuis[prompt]
	if entry then
		entry.gui.Enabled = false
	end
end

local function adoptPrompt(p: Instance)
	if p:IsA("ProximityPrompt") then
		p.Style = Enum.ProximityPromptStyle.Custom -- client-side presentation only; behaviour unchanged
	end
end

----------------------------------------------------------------------------------------------------
function WorldUI.init()
	buildHover()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.08 then
			acc = 0
			updateHover()
		end
	end)
	task.spawn(function()
		local w = Workspace:WaitForChild("PF_World", 30)
		local planets = w and w:WaitForChild("Planets", 30)
		if planets then
			for _, s in planets:GetChildren() do
				if s:IsA("Model") then
					styleLabel(s)
				end
			end
			planets.ChildAdded:Connect(function(s)
				if s:IsA("Model") then
					task.wait(0.5)
					styleLabel(s)
				end
			end)
		end
	end)
	ProximityPromptService.PromptShown:Connect(onPromptShown)
	ProximityPromptService.PromptHidden:Connect(onPromptHidden)
	for _, d in Workspace:GetDescendants() do
		adoptPrompt(d)
	end
	Workspace.DescendantAdded:Connect(adoptPrompt)
	UIRoot.PanelChanged:Connect(function()
		if hover.card then
			hover.card.Visible = false
		end
	end)
	player.CharacterAdded:Connect(function()
		WorldUI.clear()
	end)
end

return WorldUI
