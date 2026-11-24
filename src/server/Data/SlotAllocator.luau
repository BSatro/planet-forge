--!strict
-- SlotAllocator — owner: Developer B. Pure bookkeeping for a server's temporary planet slots.
-- Invariants: an owner holds at most one slot; a slot has at most one owner. Never persisted.

local SlotAllocator = {}
SlotAllocator.__index = SlotAllocator

-- order: preference list of slot numbers, each exactly once (e.g. built slots first).
function SlotAllocator.new(order: { number })
	local seen = {}
	for _, s in order do
		assert(type(s) == "number" and not seen[s], "SlotAllocator: invalid or duplicate slot in order")
		seen[s] = true
	end
	return setmetatable({
		_order = table.clone(order),
		_ownerOf = {} :: { [number]: any },
		_slotOf = {} :: { [any]: number },
	}, SlotAllocator)
end

-- Returns the owner's slot (existing one if already assigned) or nil when full.
function SlotAllocator:Assign(owner: any): number?
	assert(owner ~= nil, "SlotAllocator:Assign owner is nil")
	local existing = self._slotOf[owner]
	if existing then
		return existing
	end
	for _, s in self._order do
		if self._ownerOf[s] == nil then
			self._ownerOf[s] = owner
			self._slotOf[owner] = s
			return s
		end
	end
	return nil
end

function SlotAllocator:Release(owner: any): number?
	local s = self._slotOf[owner]
	if s == nil then
		return nil
	end
	self._slotOf[owner] = nil
	self._ownerOf[s] = nil
	return s
end

function SlotAllocator:GetSlot(owner: any): number?
	return self._slotOf[owner]
end

function SlotAllocator:GetOwner(slot: number): any
	return self._ownerOf[slot]
end

function SlotAllocator:Count(): number
	local n = 0
	for _ in self._ownerOf do
		n += 1
	end
	return n
end

function SlotAllocator:Capacity(): number
	return #self._order
end

function SlotAllocator:Snapshot(): { [number]: any }
	return table.clone(self._ownerOf)
end

return SlotAllocator
