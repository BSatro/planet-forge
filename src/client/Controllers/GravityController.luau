--!strict
-- GravityController — owner: Developer A. Local-character controller for spherical + uniform gravity.
--
-- Design (ADR-004 prototype):
--   * Humanoid.EvaluateStateMachine = false -> the Humanoid applies no locomotion forces.
--   * ONE VectorForce (world space, at centre of mass) carries everything:
--       cancel Workspace.Gravity  +  field gravity  +  hover spring (when grounded)  +  move acceleration
--   * ONE AlignOrientation (OneAttachment) keeps the root's UpVector on the field "up" and faces the
--     move direction. Smooth: never sets CFrame per frame.
--   * Jump = single ApplyImpulse along "up".
--   * Ground = raycast along -up from the root (respects CanQuery), so it works on any side of a sphere.
-- Input: the 2026 PlayerModule lives in StarterPlayer.PlayerModule and is driven by the Input Action
-- System. We read its CharacterContext.MoveAction (Direction2D) and JumpAction (Bool) via
-- InputAction:GetState(), which covers keyboard, gamepad and the touch thumbstick/jump button.
-- Fallbacks: legacy PlayerScripts.PlayerModule:GetControls():GetMoveVector(), then Humanoid.Jump.
-- Nothing here blocks: input sources are resolved lazily and re-resolved if they disappear.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GravityFields = require(ReplicatedStorage.PF_Shared.Gravity.GravityFields)
local CharacterAnimator = require(script.Parent.CharacterAnimator)
local SprintInput = require(script.Parent.SprintInput)
local Signal = require(ReplicatedStorage.PF_Shared.Util.Signal)

local GravityController = {}

local CONFIG = {
	WalkSpeed = 23, -- Planet Physics 3.0 (was 16): planets are R160, walking needed to feel quicker
	SprintSpeed = 33, -- Left Shift / L3 / touch SPRINT (SprintInput); no stamina
	GroundAccelGain = 14, -- 1/s: how fast tangential velocity converges on the wish velocity
	MaxGroundAccel = 240,
	AirAccelGain = 3,
	MaxAirAccel = 55,
	JumpVelocity = 52,
	JumpCooldown = 0.3,
	JumpGrace = 0.2, -- seconds after a jump during which the ground spring is off
	JumpBuffer = 0.15, -- seconds a press is remembered (catches sub-frame taps and early presses)
	SpringK = 450,
	SpringDamping = 42,
	MaxStepUpError = 1.0, -- studs of spring error considered per frame (smooth step-up onto boulders)
	MaxSpringAccel = 160, -- clamp so a sudden ground change never launches the character
	MaxUpSpeedGrounded = 12, -- cap on upward speed produced by the spring while grounded
	ProbeExtra = 2.5,
	GroundTolerance = 0.8,
	MinGroundDot = 0.55, -- surfaces steeper than ~56 degrees are not ground
	OrientResponsiveness = 30,
	StuckAirborneSeconds = 8,
	ClipDepth = -1.5, -- root below the planet surface by this much -> recover
	RecoverCooldown = 3,
	-- Landing brake (Planet Physics 3.0). The hover spring alone (clamped to MaxSpringAccel, engaged only within
	-- GroundTolerance) could not stop a fall: a 52 studs/s landing drove the root box into the planet and the legs
	-- ~1.5 studs under the surface. While falling, the ground probe looks ahead by fallSpeed * LandLookAhead and,
	-- once stopping at hip height needs at least LandBrakeTrigger, the force decelerates the root so it comes to
	-- rest exactly at hip height (constant-deceleration profile, never reversing within one physics step).
	LandLookAhead = 0.2, -- seconds of fall the probe looks ahead
	MaxLandProbe = 40, -- studs, cap on the extra probe length
	LandBrakeTrigger = 900, -- studs/s^2 of required deceleration at which braking starts (late = firm landing)
	MaxLandAccel = 1600, -- studs/s^2 cap on braking deceleration
	-- Step assist (Planet Physics 3.0). Only the root box collides and its bottom sits HipHeight (~1.3) above
	-- the ground, so any rock taller than that stopped the player dead (20 of 58 rocks on a planet). While moving,
	-- a probe just ahead finds low obstacle tops (<= StepMaxHeight) and the hover spring rises a moment early.
	-- Taller boulders and spires stay solid obstacles.
	StepMaxHeight = 2.2,
	StepMinHeight = 0.35,
	StepProbeAhead = 0.35, -- studs beyond the root's front face
	StepLookAheadTime = 0.08, -- s of travel added to the probe distance
	MaxStepAccel = 900,
	MaxStepRiseSpeed = 16,
	-- Wall anticipation: a too-steep surface just ahead (rock side, spire) is not pushed into and the approach
	-- speed is shed before contact; otherwise a 33 studs/s root box rams a tilted rock face and pops upward.
	WallProbeAhead = 0.2, -- studs beyond the root's front face
	WallLookAheadTime = 0.06, -- s of travel added (kept below the step probe so low steps are seen first)
	MaxWallBrake = 720,
}
GravityController.CONFIG = CONFIG
-- Planet Physics 3.0 hooks for footsteps / landing feel (read-only consumers; nothing here changes physics):
GravityController.Landed = Signal.new() -- (impactSpeed: number, ground: GroundInfo) after a real airborne phase
GravityController.SprintChanged = SprintInput.Changed -- (sprinting: boolean)

export type GroundInfo = { instance: Instance?, material: Enum.Material, position: Vector3, normal: Vector3 }

export type DebugState = {
	state: string,
	field: string,
	kind: string,
	grounded: boolean,
	altitude: number,
	speed: number,
	upDot: number,
	up: Vector3,
	strength: number,
	brake: number,
	step: number,
}

local player = Players.LocalPlayer
local fields = GravityFields.buildDefault()
local controls: any = nil -- legacy ControlModule (pre-2026 PlayerModule), if present
local moveAction: InputAction? = nil
local jumpAction: InputAction? = nil
local nextInputResolve = 0
local jumpPressedConn: RBXScriptConnection? = nil
local jumpBufferedAt = -math.huge -- jump buffering: a press shortly before landing still jumps
local basisProvider: (() -> CFrame)? = nil
local recoverFn: ((mode: string) -> ())? = nil

local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local attachment: Attachment? = nil
local force: VectorForce? = nil
local align: AlignOrientation? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local conns: { RBXScriptConnection } = {}

local facing = Vector3.new(0, 0, -1)
local currentUp = Vector3.yAxis
local lastJumpAt = -math.huge
local airborneSince: number? = nil
local airPeakFall = 0 -- fastest fall speed of the current airborne phase (landing intensity)
local ground: GroundInfo = { instance = nil, material = Enum.Material.Plastic, position = Vector3.zero, normal = Vector3.yAxis }
local groundedNow = false
local sprintingNow = false
local tanSpeedNow = 0
local lastRecoverAt = -math.huge
local debugAcc = 0
local dbg: DebugState = {
	state = "Disabled",
	field = "-",
	kind = "-",
	grounded = false,
	altitude = 0,
	speed = 0,
	upDot = 1,
	up = Vector3.yAxis,
	strength = 0,
	brake = 0,
	step = 0,
}

local function tangent(v: Vector3, up: Vector3): Vector3
	return v - up * v:Dot(up)
end

local function resolveInput()
	local t = os.clock()
	if t < nextInputResolve then
		return
	end
	nextInputResolve = t + 1
	if not (moveAction and moveAction.Parent) then
		moveAction, jumpAction = nil, nil
		local pm = game:GetService("StarterPlayer"):FindFirstChild("PlayerModule")
		local ctx = pm and pm:FindFirstChild("InputContexts")
		ctx = ctx and ctx:FindFirstChild("CharacterContext")
		if ctx then
			local m, j = ctx:FindFirstChild("MoveAction"), ctx:FindFirstChild("JumpAction")
			if m and m:IsA("InputAction") then
				moveAction = m
			end
			if j and j:IsA("InputAction") then
				jumpAction = j
				if jumpPressedConn then
					jumpPressedConn:Disconnect()
				end
				local okSig, conn = pcall(function()
					return (j :: any).Pressed:Connect(function()
						jumpBufferedAt = os.clock()
					end)
				end)
				jumpPressedConn = if okSig then conn else nil
			end
		end
	end
	if not moveAction and not controls then
		local ps = player:FindFirstChild("PlayerScripts")
		local legacy = ps and ps:FindFirstChild("PlayerModule")
		if legacy and legacy:IsA("ModuleScript") then
			local ok, pm = pcall(require, legacy)
			if ok and type(pm) == "table" and (pm :: any).GetControls then
				controls = (pm :: any):GetControls()
			end
		end
	end
end

-- Camera-relative move vector in ControlModule convention: X = right, Z = -forward, |v| <= 1.
local function readMoveVector(): Vector3
	if RunService:IsStudio() and character then
		local override = character:GetAttribute("PFTestMove")
		if typeof(override) == "Vector3" then
			return override
		end
	end
	resolveInput()
	if moveAction then
		local ok, v = pcall(moveAction.GetState, moveAction)
		if ok and typeof(v) == "Vector2" then
			return Vector3.new(v.X, 0, -v.Y)
		end
	end
	if controls then
		local ok, v = pcall(controls.GetMoveVector, controls)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	return Vector3.zero
end

local function consumeJump(): boolean
	local wants = false
	if os.clock() - jumpBufferedAt <= CONFIG.JumpBuffer then
		wants = true
	end
	if jumpAction then
		local ok, v = pcall(jumpAction.GetState, jumpAction)
		if ok and v == true then
			wants = true
		end
	end
	if humanoid and humanoid.Jump then
		wants = true
		humanoid.Jump = false
	end
	if RunService:IsStudio() and character and character:GetAttribute("PFTestJump") == true then
		character:SetAttribute("PFTestJump", false)
		wants = true
	end
	return wants
end

local function requestRecover(mode: string)
	local t = os.clock()
	if t - lastRecoverAt < CONFIG.RecoverCooldown then
		return
	end
	lastRecoverAt = t
	if recoverFn then
		recoverFn(mode)
	end
end

local function cleanupInstances()
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
	if force then
		force:Destroy()
	end
	if align then
		align:Destroy()
	end
	if attachment then
		attachment:Destroy()
	end
	force, align, attachment = nil, nil, nil
end

function GravityController.detach()
	cleanupInstances()
	CharacterAnimator.detach()
	character, humanoid, root = nil, nil, nil
	groundedNow, sprintingNow, tanSpeedNow = false, false, 0
	dbg.state = "Disabled"
end

local function onDied()
	local h = humanoid
	GravityController.detach()
	if h and h.Parent then
		h.EvaluateStateMachine = true
		h:ChangeState(Enum.HumanoidStateType.Dead)
	end
end

function GravityController.attach(char: Model)
	GravityController.detach()
	local h = char:WaitForChild("Humanoid", 10) :: Humanoid?
	local r = char:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not h or not r or player.Character ~= char then
		warn("[PF] GravityController: character incomplete, not attaching")
		return
	end
	character, humanoid, root = char, h, r
	h.EvaluateStateMachine = false
	-- Limbs never collide: the hover spring keeps the root at hip height, only the root collides
	-- (walls/boulders). Prevents feet friction and tripping on curvature.
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") and d ~= r then
			d.CanCollide = false
		end
	end

	local att = Instance.new("Attachment")
	att.Name = "PF_GravityAttachment"
	att.Parent = r
	local vf = Instance.new("VectorForce")
	vf.Name = "PF_GravityForce"
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.zero
	vf.Parent = r
	local ao = Instance.new("AlignOrientation")
	ao.Name = "PF_GravityAlign"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = false
	ao.MaxTorque = 1e7
	ao.Responsiveness = CONFIG.OrientResponsiveness
	ao.CFrame = r.CFrame.Rotation
	ao.Parent = r
	attachment, force, align = att, vf, ao

	rayParams.FilterDescendantsInstances = { char }
	facing = r.CFrame.LookVector
	currentUp = r.CFrame.UpVector
	airborneSince = nil

	table.insert(conns, h.HealthChanged:Connect(function(hp)
		if hp <= 0 then
			onDied()
		end
	end))
	table.insert(conns, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil and character == char then
			GravityController.detach()
		end
	end))
	-- Limbs added later (accessories/layered clothing load async) also must not collide.
	table.insert(conns, char.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") and d ~= r then
			d.CanCollide = false
		end
	end))
	CharacterAnimator.attach(char)
	dbg.state = "Attached"
end

local function writeDebug(dt: number)
	debugAcc += dt
	if debugAcc < 0.1 or not character then
		return
	end
	debugAcc = 0
	character:SetAttribute("PFState", dbg.state)
	character:SetAttribute("PFField", dbg.field)
	character:SetAttribute("PFGrounded", dbg.grounded)
	character:SetAttribute("PFAltitude", math.round(dbg.altitude * 100) / 100)
	character:SetAttribute("PFUpDot", math.round(dbg.upDot * 1000) / 1000)
	character:SetAttribute("PFSpeed", math.round(dbg.speed * 100) / 100)
	character:SetAttribute("PFSprint", sprintingNow)
end

local function step(dt: number)
	local r, h, vf, ao = root, humanoid, force, align
	if not r or not h or not vf or not ao or not r.Parent then
		return
	end
	local t = os.clock()
	local pos = r.Position
	local mass = r.AssemblyMass
	local v = r.AssemblyLinearVelocity
	local cancel = Vector3.yAxis * (Workspace.Gravity * mass)
	local sample = GravityFields.sample(fields, pos)
	dbg.field, dbg.kind, dbg.strength = sample.id, sample.kind, sample.strength
	dbg.altitude = if sample.altitude == math.huge then -1 else sample.altitude
	dbg.speed = v.Magnitude

	if sample.kind == "space" then
		-- No field: drift with current momentum. The server recovers the character after a few seconds.
		vf.Force = cancel
		groundedNow, tanSpeedNow = false, 0
		dbg.state, dbg.grounded = "Space", false
		dbg.upDot = r.CFrame.UpVector:Dot(currentUp)
		CharacterAnimator.update("fall", 0)
		writeDebug(dt)
		return
	end

	local up = sample.up
	currentUp = up
	dbg.up = up

	-- Clipped inside a planet (e.g. a bad teleport): recover.
	if sample.kind == "planet" and sample.altitude < CONFIG.ClipDepth then
		requestRecover("recover")
	end

	-- Ground probe along -up (looks further ahead while falling, for the landing brake).
	local hipTarget = h.HipHeight + r.Size.Y * 0.5
	local vUp = v:Dot(up)
	local fallSpeed = math.max(0, -vUp)
	local probeLen = hipTarget + CONFIG.ProbeExtra + math.min(fallSpeed * CONFIG.LandLookAhead, CONFIG.MaxLandProbe)
	local hit = Workspace:Raycast(pos, -up * probeLen, rayParams)
	local floorHit = hit and hit.Normal:Dot(up) >= CONFIG.MinGroundDot
	local grounded = false
	local groundDist = 0
	if floorHit and (t - lastJumpAt) > CONFIG.JumpGrace then
		groundDist = (hit :: RaycastResult).Distance
		grounded = groundDist <= hipTarget + CONFIG.GroundTolerance
	end

	local accel = -up * sample.strength
	local support = 0 -- upward acceleration added on top of the field gravity term
	if grounded then
		local err = math.clamp(hipTarget - groundDist, -CONFIG.MaxStepUpError, CONFIG.MaxStepUpError)
		local springA = math.clamp(CONFIG.SpringK * err - CONFIG.SpringDamping * vUp, -CONFIG.MaxSpringAccel, CONFIG.MaxSpringAccel)
		if vUp > CONFIG.MaxUpSpeedGrounded and springA > 0 then
			springA = 0
		end
		support = sample.strength + springA
	end
	if floorHit and fallSpeed > 1 then
		local simDt = math.clamp(dt, 1 / 240, 1 / 15)
		local d = (hit :: RaycastResult).Distance - hipTarget -- distance left until the root rests at hip height
		-- decide one step early so low frame rates still have room to stop
		local needNext = fallSpeed * fallSpeed / (2 * math.max(d - fallSpeed * simDt, 0.05))
		if needNext >= CONFIG.LandBrakeTrigger then
			local brake = fallSpeed * fallSpeed / (2 * math.max(d, 0.05))
			brake = math.min(brake, CONFIG.MaxLandAccel, fallSpeed / simDt) -- never reverse within one step
			support = math.max(support, sample.strength + brake)
			dbg.brake = brake
		end
	end
	accel += up * support

	-- Movement in the camera's yaw frame, projected onto the local tangent plane.
	local basis = if basisProvider then basisProvider() else Workspace.CurrentCamera.CFrame
	local fwd = tangent(basis.LookVector, up)
	if fwd.Magnitude < 0.05 then
		fwd = tangent(basis.UpVector, up)
	end
	fwd = if fwd.Magnitude > 1e-4 then fwd.Unit else tangent(facing, up).Unit
	local right = fwd:Cross(up)
	local mv = readMoveVector()
	local wish = right * mv.X - fwd * mv.Z
	if RunService:IsStudio() and character then
		-- Test hook: world-space walk direction (projected onto the tangent plane every frame).
		local worldDir = character:GetAttribute("PFTestMoveWorld")
		if typeof(worldDir) == "Vector3" and worldDir.Magnitude > 0 then
			local w = tangent(worldDir, up)
			wish = if w.Magnitude > 1e-3 then w.Unit else Vector3.zero
		end
		-- Test hook: walk a great circle around `axis` (used to test full loops through both poles).
		local axis = character:GetAttribute("PFTestGreatCircleAxis")
		if typeof(axis) == "Vector3" and axis.Magnitude > 0 then
			local w = axis.Unit:Cross(up)
			wish = if w.Magnitude > 1e-3 then w.Unit else Vector3.zero
		end
	end
	if wish.Magnitude > 1 then
		wish = wish.Unit
	end
	local vTan = v - up * vUp
	-- Step assist: obstacle top just ahead in the move direction, measured from the current ground level.
	local stepping = false
	if grounded and wish.Magnitude > 0.1 then
		local dir = wish.Unit
		local half = math.max(r.Size.X, r.Size.Z) * 0.5
		local ahead = half + CONFIG.StepProbeAhead + math.max(0, vTan:Dot(dir)) * CONFIG.StepLookAheadTime
		local top = CONFIG.StepMaxHeight + 0.15
		local base = pos - up * groundDist + up * top
		local stepHit = Workspace:Raycast(base + dir * ahead, -up * (top + 0.5), rayParams)
		if stepHit and stepHit.Normal:Dot(up) >= CONFIG.MinGroundDot then
			local h = top - stepHit.Distance
			-- the obstacle must stay low a little further on too (a tilted rock whose near edge is low but whose
			-- top keeps rising is a wall, not a step)
			-- (cast from higher up: a ray that starts inside a rock does not see that rock)
			local farHit = Workspace:Raycast(base + up * 3 + dir * (ahead + 1), -up * (top + 3.5), rayParams)
			local farH = if farHit then top + 3 - farHit.Distance else top
			if h >= CONFIG.StepMinHeight and h <= CONFIG.StepMaxHeight and farH <= CONFIG.StepMaxHeight then
				local err = hipTarget - (groundDist - h)
				local stepA = math.clamp(CONFIG.SpringK * err - CONFIG.SpringDamping * vUp, 0, CONFIG.MaxStepAccel)
				if vUp > CONFIG.MaxStepRiseSpeed then
					stepA = 0
				end
				accel += up * math.max(0, (sample.strength + stepA) - support)
				dbg.step = h
				stepping = true
			end
		end
	end
	-- Wall anticipation (see CONFIG). Probes at the root's bottom edge and centre along the actual travel.
	if grounded and not stepping and wish.Magnitude > 0.1 then
		local speed = vTan.Magnitude
		local travel = if speed > 1 then vTan / speed else wish.Unit
		local half = math.max(r.Size.X, r.Size.Z) * 0.5
		local reach = half + CONFIG.WallProbeAhead + speed * CONFIG.WallLookAheadTime
		for _, hOff in { -(r.Size.Y * 0.5 - 0.15), 0 } do
			local wallHit = Workspace:Raycast(pos + up * hOff, travel * reach, rayParams)
			if wallHit and wallHit.Normal:Dot(up) < CONFIG.MinGroundDot then
				local n = tangent(wallHit.Normal, up)
				if n.Magnitude > 0.1 then
					n = n.Unit -- horizontal wall normal, pointing away from the wall
					local into = wish:Dot(n)
					if into < 0 then
						wish -= n * into -- slide along instead of pushing in
					end
					local vInto = -vTan:Dot(n)
					if vInto > 0.5 then
						local dist = math.max(wallHit.Distance - half, 0.05)
						accel += n * math.min(vInto * vInto / (2 * dist), CONFIG.MaxWallBrake)
					end
					break
				end
			end
		end
	end
	local gain = if grounded then CONFIG.GroundAccelGain else CONFIG.AirAccelGain
	local maxA = if grounded then CONFIG.MaxGroundAccel else CONFIG.MaxAirAccel
	local sprint = SprintInput.update(wish.Magnitude > 0.1)
	local moveA = (wish * (if sprint then CONFIG.SprintSpeed else CONFIG.WalkSpeed) - vTan) * gain
	if not grounded and wish.Magnitude < 0.05 then
		moveA = Vector3.zero -- keep air momentum when there is no input
	end
	if moveA.Magnitude > maxA then
		moveA = moveA.Unit * maxA
	end
	accel += moveA

	vf.Force = cancel + accel * mass

	-- Jump: one impulse along up, only from the ground.
	if consumeJump() and grounded and (t - lastJumpAt) > CONFIG.JumpCooldown then
		r:ApplyImpulse(up * (CONFIG.JumpVelocity - vUp) * mass)
		lastJumpAt = t
		jumpBufferedAt = -math.huge
		grounded = false
	end

	-- Orientation: up = field up, face movement (or keep facing, parallel-transported).
	if wish.Magnitude > 0.1 then
		facing = wish.Unit
	else
		local f = tangent(facing, up)
		facing = if f.Magnitude > 1e-3 then f.Unit else fwd
	end
	ao.CFrame = CFrame.fromMatrix(Vector3.zero, facing:Cross(up), up, -facing)

	-- Bookkeeping, stuck detection, animation, debug.
	if grounded and floorHit then
		local gh = hit :: RaycastResult
		ground.instance, ground.material, ground.position, ground.normal = gh.Instance, gh.Material, gh.Position, gh.Normal
	end
	if grounded then
		if airborneSince and (t - airborneSince > 0.12 or airPeakFall > 10) then
			GravityController.Landed:Fire(airPeakFall, table.clone(ground))
		end
		airPeakFall = 0
		airborneSince = nil
	else
		airPeakFall = math.max(airPeakFall, fallSpeed)
		airborneSince = airborneSince or t
		if t - (airborneSince :: number) > CONFIG.StuckAirborneSeconds then
			requestRecover("recover")
			airborneSince = t
		end
	end
	dbg.grounded = grounded
	dbg.state = if grounded then "Grounded" else "Airborne"
	dbg.upDot = r.CFrame.UpVector:Dot(up)
	local tanSpeed = vTan.Magnitude
	groundedNow, sprintingNow, tanSpeedNow = grounded, sprint, tanSpeed
	if grounded then
		CharacterAnimator.update(if tanSpeed > 0.8 then "walk" else "idle", tanSpeed)
	else
		CharacterAnimator.update(if vUp > 1 then "jump" else "fall", tanSpeed)
	end
	writeDebug(dt)
end

function GravityController.init(opts: { recover: (mode: string) -> (), basis: (() -> CFrame)? })
	recoverFn = opts.recover
	basisProvider = opts.basis
	resolveInput()
	if not moveAction and not controls then
		warn("[PF] no movement input source found yet; will keep retrying once per second")
	end
	player.CharacterAdded:Connect(GravityController.attach)
	if player.Character then
		task.spawn(GravityController.attach, player.Character)
	end
	RunService.PreSimulation:Connect(step)
end

-- After a server teleport: adopt the root's new orientation as the facing/up target, so the
-- AlignOrientation doesn't rotate the character back towards its pre-teleport facing.
function GravityController.resetFacing()
	local r = root
	if r then
		facing = r.CFrame.LookVector
		currentUp = r.CFrame.UpVector
		local ao = align
		if ao then
			ao.CFrame = r.CFrame.Rotation
		end
	end
end

function GravityController.setBasisProvider(fn: () -> CFrame)
	basisProvider = fn
end

function GravityController.getUp(): Vector3
	return currentUp
end

function GravityController.getRoot(): BasePart?
	return root
end

function GravityController.getCharacter(): Model?
	return character
end

-- Planet Physics 3.0: what the local character stands on (from the same -up ground probe the physics uses).
function GravityController.getGround(): GroundInfo?
	return if groundedNow then ground else nil
end

function GravityController.getMotion(): { grounded: boolean, sprinting: boolean, speed: number }
	return { grounded = groundedNow, sprinting = sprintingNow, speed = tanSpeedNow }
end

function GravityController.getDebug(): DebugState
	return dbg
end

function GravityController.getFields()
	return fields
end

return GravityController
