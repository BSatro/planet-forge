--!strict
-- MotionFX — owner: Planet Physics 3.0 (game feel). Purely cosmetic and local; no physics, no remotes.
--   * foot dust: a few surface-tinted dust / snow particles where a foot plants (none on metal, grass, crystal)
--   * landing: a bigger dust puff, plus a short camera dip on hard landings (the landing sound is Footsteps')
--   * sprint: the camera eases its field of view out a little while sprinting (CameraController.setSprintFeel)
-- Reduced motion (Settings or OS): the camera effects are off; dust stays (it does not move the view).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VisualStyle = require(ReplicatedStorage.PF_Shared.Config.VisualStyle)

local MotionFX = {}

local DUST: { [string]: Color3 } = {
	rock = Color3.fromRGB(150, 142, 134),
	regolith = Color3.fromRGB(168, 152, 128),
	basalt = Color3.fromRGB(96, 88, 86),
	snow = Color3.fromRGB(240, 246, 255),
	ice = Color3.fromRGB(214, 234, 255),
}
local DUST_RANGE = 70 -- studs from the camera
local HARD_LANDING = 0.2 -- landing intensity (0..1) above which the camera dips

local emitter: ParticleEmitter? = nil
local holder: Attachment? = nil
local stats = { stepPuffs = 0, landPuffs = 0, dips = 0 }

local function ensureEmitter(): (Attachment, ParticleEmitter)
	if holder and holder.Parent and emitter then
		return holder, emitter
	end
	local a = Instance.new("Attachment")
	a.Name = "PF_FootDust"
	a.Parent = Workspace.Terrain
	local e = Instance.new("ParticleEmitter")
	e.Name = "Dust"
	e.Texture = VisualStyle.Texture.Smoke
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.45, 0.9)
	e.Speed = NumberRange.new(1.2, 3.2)
	e.SpreadAngle = Vector2.new(75, 75)
	e.EmissionDirection = Enum.NormalId.Top
	e.Drag = 4
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1.3) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	e.LightInfluence = 1
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-40, 40)
	e.Parent = a
	holder, emitter = a, e
	return a, e
end

local function puff(pos: Vector3, up: Vector3, color: Color3, count: number, sizeMul: number)
	local cam = Workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - pos).Magnitude > DUST_RANGE then
		return
	end
	local a, e = ensureEmitter()
	local ref = if math.abs(up.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
	local right = ref:Cross(up).Unit
	a.WorldCFrame = CFrame.fromMatrix(pos + up * 0.15, right, up)
	e.Color = ColorSequence.new(color)
	e.Acceleration = up * 1.5
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25 * sizeMul), NumberSequenceKeypoint.new(1, 1.3 * sizeMul) })
	e:Emit(count)
end

function MotionFX.init(deps: { gravity: any, camera: any, footsteps: any })
	local gravity, camera, footsteps = deps.gravity, deps.camera, deps.footsteps
	if gravity and gravity.SprintChanged and camera and camera.setSprintFeel then
		gravity.SprintChanged:Connect(function(on: boolean)
			camera.setSprintFeel(on)
		end)
	end
	if footsteps then
		footsteps.Step:Connect(function(_char: Model, category: string, pos: Vector3, up: Vector3, intensity: number)
			local col = DUST[category]
			if col then
				stats.stepPuffs += 1
				puff(pos, up, col, if intensity > 0.85 then 3 else 2, 0.8 + 0.3 * intensity)
			end
		end)
		footsteps.Landed:Connect(function(char: Model, category: string, pos: Vector3, up: Vector3, intensity: number)
			local col = DUST[category]
			if col then
				stats.landPuffs += 1
				puff(pos, up, col, math.floor(8 + 14 * intensity), 1 + 0.6 * intensity)
			end
			if char == Players.LocalPlayer.Character and intensity >= HARD_LANDING and camera and camera.landingDip then
				stats.dips += 1
				camera.landingDip(intensity)
			end
		end)
	end
end

function MotionFX.stats()
	return stats
end

return MotionFX
