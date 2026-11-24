--!strict
-- WorldService — owner: Developer A. Builds the runtime world skeleton at boot:
--   Workspace.PF_World/
--     Station                 THE FORGE (Persistent)
--     Planets/Slot_1..8       planet core + pad + spawn + label + ownership attributes (Persistent)
--     PlanetDetail/Slot_n_Detail  craters/boulders/formations (Atomic, streamed)
-- Built synchronously in Init (~3k parts, measured boot cost is reported in CHANGELOG).
-- Idempotent: existing pieces are reused, not duplicated.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local PlanetBuilder = require(script.Parent.Parent.World.PlanetBuilder)
local StationBuilder = require(script.Parent.Parent.World.StationBuilder)

local WorldService = {}

local SEED_BASE = 7919
local world: Folder
local slotModels: { [number]: Model } = {}
local ready = false

local function folder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = name
	nf.Parent = parent
	return nf
end

function WorldService:Init()
	world = (Workspace:FindFirstChild("PF_World") :: Folder?) or Instance.new("Folder")
	world.Name = "PF_World"
	world.Parent = Workspace
	local planets = folder(world, "Planets")
	local detail = folder(world, "PlanetDetail")
	if not world:FindFirstChild("Station") then
		StationBuilder.build().Parent = world
	end
	for _, slot in WorldLayout.ACTIVE_SLOTS do
		local existing = planets:FindFirstChild("Slot_" .. slot) :: Model?
		if existing then
			slotModels[slot] = existing
		else
			local core, det = PlanetBuilder.build({
				slot = slot,
				center = WorldLayout.getSlotCenter(slot),
				radius = WorldLayout.PLANET_RADIUS,
				seed = SEED_BASE + slot * 101,
			})
			core.Parent = planets
			det.Parent = detail
			slotModels[slot] = core
		end
	end
	ready = true
end

function WorldService:Start() end

function WorldService:IsReady(): boolean
	return ready
end

function WorldService:GetSlotModel(slot: number): Model?
	return slotModels[slot]
end

function WorldService:GetSpawnPoint(slot: number): BasePart?
	local m = slotModels[slot]
	return m and m:FindFirstChild("SpawnPoint") :: BasePart?
end

return WorldService
