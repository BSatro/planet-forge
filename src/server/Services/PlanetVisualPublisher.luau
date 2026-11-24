--!strict
-- PlanetVisualPublisher — owner: Developer A. PRODUCTION adapter: Developer B's planet state -> public
-- visual contract (PlanetVisualContract attributes on Workspace.PF_World.Planets.Slot_n).
--
-- Reads ONLY B's public API (never modifies B's modules or data):
--   PlanetDataService.PlanetReady(player, slot, state), PlanetDataService.PlanetChanged(player, slot, field),
--   PlanetDataService:GetPlanetState(player), PlanetSlotService.SlotReleased(player, slot)
-- When B's Planet DNA service changes stage/branch/dna through PlanetDataService, this republishes and every
-- client re-renders. If B later publishes the same attributes itself, delete this module and its Main entry.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Contract = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualContract)
local Profile = require(ReplicatedStorage.PF_Shared.Planet.PlanetVisualProfile)
local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local WorldService = require(script.Parent.WorldService)
local PlanetDataService = require(script.Parent.PlanetDataService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)

local PlanetVisualPublisher = {}

local revisions: { [number]: number } = {}

local function write(slot: number, state: Contract.State)
	local model = WorldService:GetSlotModel(slot)
	if not model then
		return
	end
	revisions[slot] = (revisions[slot] or 0) + 1
	state.revision = revisions[slot]
	local theme = Profile.themeFor(state.branch, state.stage)
	for name, value in Contract.toAttributes(state, theme) do
		model:SetAttribute(name, value)
	end
end

function PlanetVisualPublisher:PublishDefault(slot: number)
	write(slot, Contract.defaultState(slot))
end

function PlanetVisualPublisher:PublishPlayer(player: Player)
	local raw = PlanetDataService:GetPlanetState(player)
	if not raw or not WorldLayout.isValidSlot(raw.slot) then
		return
	end
	raw.ownerName = player.DisplayName
	write(raw.slot, Contract.normalize(raw.slot, raw))
end

function PlanetVisualPublisher:Init()
	PlanetDataService.PlanetReady:Connect(function(player: Player)
		PlanetVisualPublisher:PublishPlayer(player)
	end)
	PlanetDataService.PlanetChanged:Connect(function(player: Player)
		PlanetVisualPublisher:PublishPlayer(player)
	end)
	PlanetSlotService.SlotReleased:Connect(function(_player: Player, slot: number)
		PlanetVisualPublisher:PublishDefault(slot)
	end)
end

function PlanetVisualPublisher:Start()
	for _, slot in WorldLayout.ACTIVE_SLOTS do
		if not PlanetSlotService:GetOwner(slot) then
			PlanetVisualPublisher:PublishDefault(slot)
		end
	end
	-- players whose profile finished loading before this Start ran
	for _, p in Players:GetPlayers() do
		if PlanetSlotService:GetSlot(p) then
			PlanetVisualPublisher:PublishPlayer(p)
		end
	end
end

return PlanetVisualPublisher
