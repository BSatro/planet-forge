--!strict
-- StationFX — owner: Developer A. Client-side animation of THE FORGE.
-- Every Model under Workspace.PF_World.Station with attribute PFSpin (rad/s) and optional PFSpinAxis
-- (Vector3) rotates about its bounding-box centre. Moves are LOCAL (server never animates).
-- Uses one workspace:BulkMoveTo per frame for all spinning parts (~180), and only animates while the
-- camera is within ANIMATE_RANGE of the station (planets far away pay nothing).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)

local StationFX = {}

local ANIMATE_RANGE = 450

type Spinner = { pivot: CFrame, axis: Vector3, speed: number, parts: { BasePart }, offsets: { CFrame }, angle: number }

local spinners: { Spinner } = {}
local conn: RBXScriptConnection? = nil

local function collect(station: Instance)
	table.clear(spinners)
	for _, m in station:GetDescendants() do
		if m:IsA("Model") and typeof(m:GetAttribute("PFSpin")) == "number" then
			local axisAttr = m:GetAttribute("PFSpinAxis")
			local axis = if typeof(axisAttr) == "Vector3" and axisAttr.Magnitude > 0 then axisAttr.Unit else Vector3.yAxis
			local cf, _ = m:GetBoundingBox()
			local pivot = CFrame.new(cf.Position)
			local parts: { BasePart } = {}
			local offsets: { CFrame } = {}
			for _, p in m:GetDescendants() do
				if p:IsA("BasePart") then
					table.insert(parts, p)
					table.insert(offsets, pivot:ToObjectSpace(p.CFrame))
				end
			end
			if #parts > 0 then
				table.insert(spinners, { pivot = pivot, axis = axis, speed = m:GetAttribute("PFSpin") :: number, parts = parts, offsets = offsets, angle = 0 })
			end
		end
	end
end

function StationFX.init()
	task.spawn(function()
		local world = Workspace:WaitForChild("PF_World", 30)
		local station = world and world:WaitForChild("Station", 30)
		if not station then
			warn("[PF] StationFX: station not found")
			return
		end
		task.wait(0.5) -- let the persistent model finish arriving
		collect(station)
		local partsBuf: { BasePart } = {}
		local cfBuf: { CFrame } = {}
		conn = RunService.RenderStepped:Connect(function(dt)
			local cam = Workspace.CurrentCamera
			if (cam.CFrame.Position - WorldLayout.STATION_CENTER).Magnitude > ANIMATE_RANGE then
				return
			end
			table.clear(partsBuf)
			table.clear(cfBuf)
			for _, s in spinners do
				s.angle = (s.angle + s.speed * dt) % (math.pi * 2)
				local rot = s.pivot * CFrame.fromAxisAngle(s.axis, s.angle)
				for i, p in s.parts do
					table.insert(partsBuf, p)
					table.insert(cfBuf, rot * s.offsets[i])
				end
			end
			if #partsBuf > 0 then
				Workspace:BulkMoveTo(partsBuf, cfBuf, Enum.BulkMoveMode.FireCFrameChanged)
			end
		end)
	end)
end

function StationFX.getSpinnerCount(): (number, number)
	local n = 0
	for _, s in spinners do
		n += #s.parts
	end
	return #spinners, n
end

return StationFX
