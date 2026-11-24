--!strict
-- StormRules — owner: Live Gameplay. Pure Solar Storm rules: which reactions are "energy reactions", the matter
-- refund for a boosted completion and the per-player surge cap. Reaction defs come from Developer B's
-- ReactionRegistry (read-only); nothing here changes reaction rules, costs or DNA.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)

local StormRules = {}

function StormRules.isBoosted(def: any): boolean
	if type(def) ~= "table" then
		return false
	end
	local S = EventConfig.STORM
	return S.reactions[def.id] == true or S.categories[def.category] == true
end

-- Boosted reaction ids in registry order (published to clients so the DNA Lab can mark them).
function StormRules.boostedIds(registry: any): { string }
	local out = {}
	for _, id in registry.ORDER do
		if StormRules.isBoosted(registry.DEFS[id]) then
			table.insert(out, id)
		end
	end
	return out
end

function StormRules.refundFor(def: any): { [string]: number }
	local S = EventConfig.STORM
	local out = {}
	local mats = def and def.cost and def.cost.materials
	if type(mats) ~= "table" then
		return out
	end
	for id, n in mats do
		if type(n) == "number" and n > 0 and not S.noRefund[id] then
			local r = math.floor(n * S.refundShare)
			if r > 0 then
				out[id] = r
			end
		end
	end
	return out
end

function StormRules.new(): any
	return { surges = {} :: { [number]: number }, total = 0 }
end

-- A boosted reaction completed during the storm. Returns the bonus to grant (once per completion).
function StormRules.apply(st: any, userId: number, def: any): (boolean, string, any?)
	local S = EventConfig.STORM
	if not StormRules.isBoosted(def) then
		return false, "NOT_BOOSTED", nil
	end
	local used = st.surges[userId] or 0
	if used >= S.maxSurges then
		return false, "CAP_REACHED", nil
	end
	st.surges[userId] = used + 1
	st.total += 1
	return true, "OK", { materials = StormRules.refundFor(def), credits = S.creditBonus, left = S.maxSurges - used - 1 }
end

function StormRules.surgesLeft(st: any, userId: number): number
	return math.max(0, EventConfig.STORM.maxSurges - (st.surges[userId] or 0))
end

return StormRules
