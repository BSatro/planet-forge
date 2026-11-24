--!strict
-- PlanetVisualMock — owner: Developer A. DEVELOPMENT ONLY mock provider for the planet visual contract.
-- * Lives in ServerStorage.PF_DevTools: never required by Main or any production module.
-- * Refuses to run outside Studio, and only ever writes UNCLAIMED slots (never a real player's planet).
-- * Writes exactly the PlanetVisualContract attributes the production publisher writes, so the client
--   renderer is exercised through the real replication path.
-- Usage (Studio, Server datamodel while playing, e.g. via MCP execute_luau):
--   local Mock = require(game.ServerStorage.PF_DevTools.PlanetVisualMock)
--   Mock.showcase()                         -- 8 planets in different stages/branches
--   Mock.set(3, { stage = 4, branch = "Volcanic", dna = { Tectonics = 90 } })
--   Mock.resetAll()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Contract = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualContract)
local Profile = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualProfile)
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)

local Mock = {}

local function slotModel(slot: number): Model?
	local world = workspace:FindFirstChild("PF_World")
	local planets = world and world:FindFirstChild("Planets")
	return planets and planets:FindFirstChild("Slot_" .. slot) :: Model?
end

local function isRealOwned(model: Model): boolean
	local uid = model:GetAttribute(Contract.ATTR.OwnerUserId)
	if model:GetAttribute("PFMock") == true then
		return false
	end
	return type(uid) == "number" and uid > 0 and Players:GetPlayerByUserId(uid) ~= nil
end

function Mock.set(slot: number, partial: { [string]: any }): (boolean, string)
	if not RunService:IsStudio() then
		return false, "STUDIO_ONLY"
	end
	if not WorldLayout.isValidSlot(slot) then
		return false, "INVALID_SLOT"
	end
	local model = slotModel(slot)
	if not model then
		return false, "NO_MODEL"
	end
	if isRealOwned(model) then
		return false, "SLOT_OWNED_BY_REAL_PLAYER"
	end
	local raw = table.clone(partial)
	raw.ownerUserId = raw.ownerUserId or (100000 + slot) -- fake owner id -> deterministic per-owner seed
	raw.ownerName = raw.ownerName or ("MockOwner" .. slot)
	local state = Contract.normalize(slot, raw)
	state.revision = (tonumber(model:GetAttribute(Contract.ATTR.Revision)) or 0) + 1
	for name, value in Contract.toAttributes(state, (Profile.themeFor(state.branch, state.stage))) do
		model:SetAttribute(name, value)
	end
	model:SetAttribute("PFMock", true)
	return true, "OK"
end

function Mock.reset(slot: number): (boolean, string)
	local model = slotModel(slot)
	if not model or model:GetAttribute("PFMock") ~= true then
		return false, "NOT_MOCKED"
	end
	local state = Contract.defaultState(slot)
	state.revision = (tonumber(model:GetAttribute(Contract.ATTR.Revision)) or 0) + 1
	for name, value in Contract.toAttributes(state, "barren") do
		model:SetAttribute(name, value)
	end
	model:SetAttribute("PFMock", nil)
	return true, "OK"
end

function Mock.resetAll()
	for slot = 1, WorldLayout.SLOT_COUNT do
		Mock.reset(slot)
	end
end

-- 8 planets across every stage and the 4 implemented specializations (Developer B's v2 ids:
-- PlanetConfig.BRANCHES, DNA Temperature/Water/Life/CosmicEnergy 0..100, FormationRegistry ids with counts).
Mock.SHOWCASE = {
	[1] = { stage = 0, branch = "None" },
	[2] = { stage = 1, branch = "None", dna = { Temperature = 55, Water = 15, Life = 0, CosmicEnergy = 30 },
		formations = { ShallowOcean = 1, IceImpact = 1 } },
	[3] = { stage = 2, branch = "None", dna = { Temperature = 50, Water = 60, Life = 35, CosmicEnergy = 35 },
		formations = { ShallowOcean = 2, SteamPools = 1, PlasmaFissures = 1 } },
	[4] = { stage = 3, branch = "Frozen", dna = { Temperature = 12, Water = 55, Life = 10, CosmicEnergy = 45 },
		formations = { FrozenLake = 1, IceSpikes = 1, GlacierRidge = 1, CrystalIceCave = 1 } },
	[5] = { stage = 4, branch = "Volcanic", dna = { Temperature = 92, Water = 10, Life = 5, CosmicEnergy = 70 },
		formations = { ThermalCrack = 1, LavaPool = 1, BasaltSpires = 1, MagmaRiver = 1, VolcanicMountain = 1, EternalCore = 1 } },
	[6] = { stage = 4, branch = "Crystal", dna = { Temperature = 45, Water = 25, Life = 10, CosmicEnergy = 95 },
		formations = { CrystalCluster = 3, EnergyVeins = 2, CrystalGarden = 1, ResonanceArch = 1, CelestialPrism = 1 } },
	[7] = { stage = 4, branch = "Living", dna = { Temperature = 55, Water = 70, Life = 90, CosmicEnergy = 60 },
		formations = { GrassPatches = 1, FirstForest = 3, BioluminescentGrove = 1, AncientTree = 1, LivingWaterfall = 1, WorldTree = 1 } },
	[8] = { stage = 3, branch = "Living", dna = { Temperature = 30, Water = 45, Life = 55, CosmicEnergy = 40 },
		formations = { GrassPatches = 1, FirstForest = 2 } },
}

function Mock.showcase(): { [number]: string }
	local results = {}
	for slot, st in Mock.SHOWCASE do
		local _, code = Mock.set(slot, st)
		results[slot] = code
	end
	return results
end

return Mock
