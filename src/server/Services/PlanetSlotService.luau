--!strict
-- PlanetSlotService — owner: Developer B. Session-only Player <-> planet slot mapping (1..SLOT_COUNT).
-- Slot number and position are TEMPORARY; the planet's persistent state lives in the profile and is applied
-- to whichever slot the player gets (listen to PlanetDataService.PlanetReady). Built slots (ACTIVE_SLOTS)
-- are handed out first. Driven by ProfileService (assign on join, release on leave).
--
-- Public API:
--   :GetSlot(player) -> number?          :GetOwner(slot) -> Player?
--   :IsOwner(player, slot) -> boolean    (ownership guard for any client-facing planet action)
--   :GetOccupancy() -> { [slot]: userId }   :GetFreeCount() / :Capacity()
--   .SlotAssigned(player, slot)  .SlotReleased(player, slot)
--   Player attribute "PF_Slot" (replicated, read-only for clients).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldLayout = require(ReplicatedStorage.PF_Shared.Config.WorldLayout)
local Signal = require(ReplicatedStorage.PF_Shared.Util.Signal)
local SlotAllocator = require(script.Parent.Parent.Data.SlotAllocator)

local PlanetSlotService = {}
PlanetSlotService.SlotAssigned = Signal.new()
PlanetSlotService.SlotReleased = Signal.new()

local allocator: any = nil

function PlanetSlotService.buildOrder(): { number }
	local order = {}
	for _, s in WorldLayout.ACTIVE_SLOTS do
		table.insert(order, s)
	end
	for s = 1, WorldLayout.SLOT_COUNT do
		if not table.find(order, s) then
			table.insert(order, s)
		end
	end
	return order
end

function PlanetSlotService:Init()
	allocator = SlotAllocator.new(PlanetSlotService.buildOrder())
end

function PlanetSlotService:Start() end

-- Internal (ProfileService). Returns the slot or nil when all slots are taken.
function PlanetSlotService:Assign(player: Player): number?
	local had = allocator:GetSlot(player)
	local slot = allocator:Assign(player)
	if slot and not had then
		player:SetAttribute("PF_Slot", slot)
		self.SlotAssigned:Fire(player, slot)
	end
	return slot
end

-- Internal (ProfileService).
function PlanetSlotService:Release(player: Player): number?
	local slot = allocator:Release(player)
	if slot then
		player:SetAttribute("PF_Slot", nil)
		self.SlotReleased:Fire(player, slot)
	end
	return slot
end

function PlanetSlotService:GetSlot(player: Player): number?
	return allocator and allocator:GetSlot(player)
end

function PlanetSlotService:GetOwner(slot: number): Player?
	return allocator and allocator:GetOwner(slot)
end

function PlanetSlotService:IsOwner(player: Player, slot: any): boolean
	return WorldLayout.isValidSlot(slot) and allocator ~= nil and allocator:GetOwner(slot) == player
end

function PlanetSlotService:GetOccupancy(): { [number]: number }
	local out = {}
	for slot, p in allocator:Snapshot() do
		out[slot] = p.UserId
	end
	return out
end

function PlanetSlotService:Capacity(): number
	return allocator:Capacity()
end

function PlanetSlotService:GetFreeCount(): number
	return allocator:Capacity() - allocator:Count()
end

return PlanetSlotService
