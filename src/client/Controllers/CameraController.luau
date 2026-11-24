--!strict
-- CameraController — owner: Developer A. Scriptable third-person camera for arbitrary gravity.
--
-- The camera keeps a reference rotation `ref` whose UpVector follows the character's gravity up.
-- Each frame `ref` is rotated by the *minimal* rotation from its current up to the new up (parallel
-- transport), smoothed exponentially. Yaw/pitch are relative to `ref`, so walking over the poles or
-- under the planet never flips the camera.
-- Input: mouse (right-drag), wheel zoom, touch drag + pinch, gamepad right stick.
-- Modes: "follow" (default) and "orbit" (planet overview; toggle with O / ButtonY / debug panel).
-- Showcase (v1.7): setShowcase(center, radius) runs a cinematic orbit around any world point (Planet Showcase);
-- clearShowcase() returns to follow. The character is untouched.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local CameraController = {}

local CONFIG = {
	MinDistance = 6,
	MaxDistance = 40,
	DefaultDistance = 16,
	MinPitch = math.rad(-75),
	MaxPitch = math.rad(35),
	MouseSensitivity = 0.0045,
	TouchSensitivity = 0.008,
	GamepadSpeed = 2.6, -- rad/s at full deflection
	InvertY = false, -- player setting (Settings panel)
	SensitivityScale = 1, -- player setting, multiplies mouse/touch/gamepad look
	UpFollowRate = 9, -- 1/s, how fast the camera up catches up with gravity up
	FocusHeight = 1.8,
	OrbitDistanceFactor = 3.4, -- x planet radius
	OrbitAutoSpin = 0.08, -- rad/s
	-- Planet Physics 3.0 game feel (follow mode only; both off with reduced motion)
	SprintFovAdd = 4, -- degrees added while sprinting, eased in/out
	LandDipMax = 0.45, -- studs the camera dips on the hardest landing
	LandDipTime = 0.28,
}
CameraController.CONFIG = CONFIG

local gravity: any = nil
local camera: Camera = Workspace.CurrentCamera
local ref = CFrame.identity
local yaw, pitch = 0, math.rad(-20)
local distance = CONFIG.DefaultDistance
local mode: "follow" | "orbit" = "follow"
local orbitYaw, orbitPitch = 0, math.rad(-25)
local gamepadLook = Vector2.zero
local lastInputAt = 0
local touches: { [InputObject]: boolean } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local initialised = false
local showcase: { center: Vector3, radius: number, t0: number, yaw: number, pitch: number, zoom: number, baseFov: number }? = nil
-- game feel state: the sprint FOV is applied as an eased delta on top of whatever FOV the camera has; if any other
-- system writes the FOV (warp FX, harvester), the offset is dropped instead of fought
local fovOffset, fovTarget = 0, 0
local fovLastWritten: number? = nil
local dipAmp, dipT = 0, math.huge

local function reducedMotion(): boolean
	local p = game:GetService("Players").LocalPlayer
	if p and p:GetAttribute("PFReducedMotion") == true then
		return true
	end
	local ok, v = pcall(function()
		return (game:GetService("GuiService") :: any).ReducedMotionEnabled
	end)
	return ok and v == true
end

local function rotateRefTowards(up: Vector3, alpha: number)
	local cur = ref.UpVector
	local dot = math.clamp(cur:Dot(up), -1, 1)
	local angle = math.acos(dot)
	if angle < 1e-5 then
		return
	end
	local axis = cur:Cross(up)
	if axis.Magnitude < 1e-6 then
		axis = ref.RightVector -- exactly opposite: any perpendicular axis works
	end
	ref = CFrame.fromAxisAngle(axis.Unit, angle * alpha) * ref
	-- re-orthonormalise to avoid drift
	ref = CFrame.fromMatrix(Vector3.zero, ref.RightVector, ref.UpVector):Orthonormalize()
end

local function rotate(dx: number, dy: number)
	lastInputAt = os.clock()
	dx *= CONFIG.SensitivityScale
	dy *= CONFIG.SensitivityScale * (if CONFIG.InvertY then -1 else 1)
	local sc = showcase
	if sc then
		sc.yaw -= dx
		sc.pitch = math.clamp(sc.pitch - dy, -0.9, 0.6)
		return
	end
	if mode == "orbit" then
		orbitYaw -= dx
		orbitPitch = math.clamp(orbitPitch - dy, math.rad(-85), math.rad(85))
	else
		yaw -= dx
		pitch = math.clamp(pitch - dy, CONFIG.MinPitch, CONFIG.MaxPitch)
	end
end

-- Yaw-only frame used for movement input (independent of camera mode/pitch).
function CameraController.getMoveBasis(): CFrame
	return ref * CFrame.Angles(0, yaw, 0)
end

function CameraController.getMode(): string
	return mode
end

function CameraController.setMode(m: "follow" | "orbit")
	if m == "orbit" and mode ~= "orbit" then
		orbitYaw, orbitPitch = yaw, math.rad(-25)
	end
	mode = m
end

-- Instantly re-frames the camera behind the character in its CURRENT gravity frame. Used after a
-- teleport (called while the warp overlay is still opaque) so the camera never swings or flips.
function CameraController.snapBehind()
	local root = gravity and gravity.getRoot()
	if not root then
		return
	end
	local up = root.CFrame.UpVector
	ref = CFrame.identity
	rotateRefTowards(up, 1)
	local localLook = ref:VectorToObjectSpace(root.CFrame.LookVector)
	yaw = math.atan2(-localLook.X, -localLook.Z)
	pitch = math.rad(-20)
	mode = "follow"
	initialised = true
end

function CameraController.toggleOrbit()
	CameraController.setMode(if mode == "orbit" then "follow" else "orbit")
end

-- Cinematic orbit around `center` (e.g. a planet centre) at a distance scaled by `radius`.
-- `up` (optional, First 10 Minutes 2.0): orbit in the plane of a surface normal, so a point on the side or the
-- underside of a planet (a new formation) is framed from above its own horizon, never through the planet.
function CameraController.setShowcase(center: Vector3, radius: number, up: Vector3?)
	local cam = Workspace.CurrentCamera
	local startYaw = 0
	local basis: CFrame? = nil
	if up and up.Magnitude > 0.5 then
		local u = up.Unit
		local ref = if math.abs(u.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
		local right = ref:Cross(u).Unit
		basis = CFrame.fromMatrix(Vector3.zero, right, u)
	end
	if cam then
		local d = cam.CFrame.Position - center
		if basis then
			d = (basis :: CFrame):VectorToObjectSpace(d)
		end
		startYaw = math.atan2(d.X, d.Z)
	end
	local prevFov = if showcase then showcase.baseFov elseif cam then cam.FieldOfView - fovOffset else 70
	fovOffset, fovLastWritten = 0, nil -- the showcase owns the FOV now (restored to prevFov, without the sprint delta)
	showcase = { center = center, radius = math.max(10, radius), t0 = os.clock(), yaw = startYaw, pitch = 0, zoom = 1, baseFov = prevFov, basis = basis }
	lastInputAt = 0
end

function CameraController.clearShowcase()
	local sc = showcase
	if not sc then
		return
	end
	showcase = nil
	local cam = Workspace.CurrentCamera
	if cam then
		cam.FieldOfView = sc.baseFov
	end
	CameraController.snapBehind()
end

function CameraController.isShowcase(): boolean
	return showcase ~= nil
end

local function update(dt: number)
	local sc = showcase
	if sc then
		camera = Workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable
		if gamepadLook.Magnitude > 0.15 then
			rotate(gamepadLook.X * CONFIG.GamepadSpeed * dt, -gamepadLook.Y * CONFIG.GamepadSpeed * dt)
		end
		local t = os.clock() - sc.t0
		if os.clock() - lastInputAt > 2.5 then
			sc.yaw += 0.12 * dt
		end
		local pitch = math.rad(-16) + math.sin(t * 0.35) * math.rad(8) + sc.pitch
		local dist = sc.radius * (2.7 + math.sin(t * 0.22) * 0.3) * sc.zoom
		local rot = (sc.basis or CFrame.identity) * CFrame.Angles(0, sc.yaw, 0) * CFrame.Angles(pitch, 0, 0)
		local pos = sc.center + rot:VectorToWorldSpace(Vector3.new(0, 0, dist))
		camera.CFrame = CFrame.lookAt(pos, sc.center, if sc.basis then sc.basis.UpVector else Vector3.yAxis)
		camera.Focus = CFrame.new(sc.center)
		camera.FieldOfView += (52 - camera.FieldOfView) * math.min(1, dt * 3)
		return
	end
	local root = gravity.getRoot()
	if not root then
		return
	end
	camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local up = gravity.getUp()
	if not initialised then
		ref = CFrame.identity
		rotateRefTowards(up, 1)
		initialised = true
	else
		rotateRefTowards(up, 1 - math.exp(-CONFIG.UpFollowRate * dt))
	end
	if gamepadLook.Magnitude > 0.15 then
		rotate(gamepadLook.X * CONFIG.GamepadSpeed * dt, -gamepadLook.Y * CONFIG.GamepadSpeed * dt)
	end

	local camUp = ref.UpVector
	if mode == "orbit" then
		local dbg = gravity.getDebug()
		local center: Vector3 = root.Position
		local radius = 30
		for _, f in gravity.getFields() do
			if f.id == dbg.field and f.kind == "planet" then
				center, radius = f.center, f.radius
			end
		end
		if os.clock() - lastInputAt > 2 then
			orbitYaw += CONFIG.OrbitAutoSpin * dt
		end
		local rot = ref * CFrame.Angles(0, orbitYaw, 0) * CFrame.Angles(orbitPitch, 0, 0)
		local pos = center + rot:VectorToWorldSpace(Vector3.new(0, 0, radius * CONFIG.OrbitDistanceFactor))
		camera.CFrame = CFrame.lookAt(pos, center, rot.UpVector)
		return
	end

	local focus = root.Position + camUp * CONFIG.FocusHeight
	local rot = ref * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local offset = rot:VectorToWorldSpace(Vector3.new(0, 0, distance))
	local char = gravity.getCharacter()
	rayParams.FilterDescendantsInstances = if char then { char } else {}
	local hit = Workspace:Raycast(focus, offset, rayParams)
	local camPos = if hit then hit.Position - offset.Unit * 0.6 else focus + offset
	-- landing dip (Planet Physics 3.0): a short sine dip along -up, view direction unchanged
	if dipT < CONFIG.LandDipTime then
		dipT += dt
		local k = math.clamp(dipT / CONFIG.LandDipTime, 0, 1)
		local d = math.sin(k * math.pi) * dipAmp
		camPos -= camUp * d
		focus -= camUp * d * 0.6
	end
	camera.CFrame = CFrame.lookAt(camPos, focus, rot.UpVector)
	camera.Focus = CFrame.new(focus)
	-- sprint FOV delta
	if fovLastWritten and math.abs(camera.FieldOfView - fovLastWritten) > 0.01 then
		fovOffset = 0 -- someone else changed the FOV: their value is the new base
	end
	local want = if reducedMotion() then 0 else fovTarget
	local nextOff = fovOffset + (want - fovOffset) * math.min(1, dt * 6)
	if math.abs(want - nextOff) < 0.01 then
		nextOff = want
	end
	if nextOff ~= fovOffset then
		camera.FieldOfView += nextOff - fovOffset
		fovOffset = nextOff
	end
	fovLastWritten = camera.FieldOfView
end

-- Planet Physics 3.0 game feel hooks (driven by Controllers.MotionFX)
function CameraController.setSprintFeel(on: boolean)
	fovTarget = if on then CONFIG.SprintFovAdd else 0
end

function CameraController.landingDip(intensity: number)
	if reducedMotion() or mode ~= "follow" or showcase then
		return
	end
	dipAmp = CONFIG.LandDipMax * math.clamp(intensity, 0, 1)
	dipT = 0
end

function CameraController.getFeel()
	return { fovOffset = fovOffset, fovTarget = fovTarget, dipActive = dipT < CONFIG.LandDipTime }
end

function CameraController.init(gravityController: any)
	gravity = gravityController
	UserInputService.InputBegan:Connect(function(input, gpe)
		if input.UserInputType == Enum.UserInputType.Touch and not gpe then
			touches[input] = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		touches[input] = nil
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end)
	UserInputService.InputChanged:Connect(function(input, gpe)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseMovement then
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
				rotate(input.Delta.X * CONFIG.MouseSensitivity, input.Delta.Y * CONFIG.MouseSensitivity)
			end
		elseif t == Enum.UserInputType.MouseWheel and not gpe then
			local sc = showcase
			if sc then
				sc.zoom = math.clamp(sc.zoom - input.Position.Z * 0.08, 0.7, 1.6)
			else
				distance = math.clamp(distance - input.Position.Z * 2, CONFIG.MinDistance, CONFIG.MaxDistance)
			end
		elseif t == Enum.UserInputType.Touch and touches[input] then
			local n = 0
			for _ in touches do
				n += 1
			end
			if n == 1 then
				rotate(input.Delta.X * CONFIG.TouchSensitivity, input.Delta.Y * CONFIG.TouchSensitivity)
			end
		elseif t == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick2 then
			gamepadLook = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)
	UserInputService.TouchPinch:Connect(function(_, scale, _, state, gpe)
		if gpe or state ~= Enum.UserInputState.Change then
			return
		end
		local s = math.clamp(scale, 0.5, 2)
		distance = math.clamp(distance / (1 + (s - 1) * 0.08), CONFIG.MinDistance, CONFIG.MaxDistance)
	end)
	ContextActionService:BindAction("PF_ToggleOrbit", function(_, state)
		if state == Enum.UserInputState.Begin then
			CameraController.toggleOrbit()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.O, Enum.KeyCode.ButtonY)
	RunService:BindToRenderStep("PF_Camera", Enum.RenderPriority.Camera.Value + 1, update)
end

return CameraController
