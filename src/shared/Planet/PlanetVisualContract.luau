--!strict
-- PlanetVisualContract — owner: Developer A (proposed to Developer B, INTERFACES.md §7, contract v1.3).
-- The PUBLIC, replicated view of one planet that every client renders. Transport = attributes on
-- Workspace.PF_World.Planets.Slot_n (Persistent model, replicates to all clients incl. late joiners).
-- Producers: PlanetVisualPublisher (production adapter over PlanetDataService) or PF_DevTools.PlanetVisualMock
-- (Studio only). Consumer: client PlanetVisualController. Pure module, no side effects.
--
-- The fields mirror PlanetDataService:GetPlanetState() exactly (dna / branch / stage / formations) plus
-- ownership and a revision counter, so the real DNA service plugs in without renderer changes.
--
-- 2026-11-23 (planet scale rework): the attribute shape is UNCHANGED. PFFormations still carries purchase counts
-- ("FirstForest:1"), never rendered element counts. How many trees / seas / cracks a purchase shows is derived on
-- the client from the published PFDna_* values with the shared, pure PF_Shared.Planet.FormationDensity (the ONLY
-- copy of that formula). PlanetVisualProfile.build exposes the DNA as spec.dna for it. Same attributes -> same
-- visuals on every client (deterministic, no per-client randomness).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlanetConfig = require(ReplicatedStorage.PF_Shared.Config.PlanetConfig)

local Contract = {}

Contract.VERSION = 1

Contract.ATTR = table.freeze({
	OwnerUserId = "PFOwnerUserId", -- number, 0 = unclaimed (already written by WorldService at build)
	OwnerName = "PFOwnerName", -- string
	ClaimState = "PFClaimState", -- "unclaimed" | "claimed"
	Branch = "PFBranch", -- PlanetConfig branch id ("Primordial" | "Cryogenic" | "Volcanic" | "Stellar" | future)
	Stage = "PFStage", -- integer 0..PlanetConfig.MAX_EVOLUTION_STAGE
	Formations = "PFFormations", -- "Id:count,Id:count" (FormationRegistry ids); a bare "Id" means count 1
	LastEffect = "PFLastEffect", -- optional effect id of the change ("ocean", "volcanic", ...)
	Theme = "PFTheme", -- derived visual theme (informational, written by the producer)
	Revision = "PFVisualRevision", -- integer, +1 on every publish; consumers re-render on change
	DnaPrefix = "PFDna_", -- PFDna_<ParamId> = number for each PlanetConfig.DNA_PARAMS entry
})

export type State = {
	slot: number,
	ownerUserId: number,
	ownerName: string,
	branch: string,
	stage: number,
	dna: { [string]: number },
	formations: { [string]: number }, -- formation id -> instance count
	lastEffect: string,
	revision: number,
}

local function finite(v: any): boolean
	return type(v) == "number" and v == v and math.abs(v) < math.huge
end

-- Default (barren / unclaimed) state for a slot.
function Contract.defaultState(slot: number): State
	local dna = {}
	for id, def in PlanetConfig.DNA_PARAMS do
		dna[id] = def.default
	end
	return {
		slot = slot,
		ownerUserId = 0,
		ownerName = "",
		branch = PlanetConfig.DEFAULT_BRANCH,
		stage = 0,
		dna = dna,
		formations = {},
		lastEffect = "",
		revision = 0,
	}
end

-- Validate + clamp anything (attributes or a PlanetDataService state) into a safe State.
function Contract.normalize(slot: number, raw: { [string]: any }): State
	local s = Contract.defaultState(slot)
	if finite(raw.ownerUserId) then
		s.ownerUserId = math.max(0, math.floor(raw.ownerUserId))
	end
	if type(raw.ownerName) == "string" then
		s.ownerName = raw.ownerName:sub(1, 40)
	end
	if type(raw.branch) == "string" and #raw.branch <= 32 then
		s.branch = raw.branch
	end
	if finite(raw.stage) then
		s.stage = math.clamp(math.floor(raw.stage), 0, PlanetConfig.MAX_EVOLUTION_STAGE)
	end
	if type(raw.dna) == "table" then
		for id in PlanetConfig.DNA_PARAMS do
			local v = PlanetConfig.clampDna(id, raw.dna[id])
			if v then
				s.dna[id] = v
			end
		end
	end
	-- formations: accepts { "Id", ... } (count 1 each), { Id = count } or B's profile form { Id = { n = count } }
	if type(raw.formations) == "table" then
		local n = 0
		for k, v in raw.formations do
			n += 1
			if n > 64 then
				break
			end
			local id, count = nil, nil
			if type(k) == "number" and type(v) == "string" then
				id, count = v, 1
			elseif type(k) == "string" and finite(v) then
				id, count = k, v
			elseif type(k) == "string" and type(v) == "table" and finite(v.n) then
				id, count = k, v.n
			end
			if id and #id <= 40 and count then
				s.formations[id] = math.clamp(math.floor(count), 0, 99)
			end
		end
	end
	if type(raw.lastEffect) == "string" then
		s.lastEffect = raw.lastEffect:sub(1, 24)
	end
	if finite(raw.revision) then
		s.revision = math.max(0, math.floor(raw.revision))
	end
	return s
end

-- State -> attribute map (producer side). Theme is passed in so producers don't need the visual profile.
function Contract.toAttributes(state: State, theme: string?): { [string]: any }
	local A = Contract.ATTR
	local out: { [string]: any } = {
		[A.OwnerUserId] = state.ownerUserId,
		[A.OwnerName] = state.ownerName,
		[A.ClaimState] = if state.ownerUserId > 0 then "claimed" else "unclaimed",
		[A.Branch] = state.branch,
		[A.Stage] = state.stage,
		[A.Formations] = (function()
			local parts = {}
			for id, c in state.formations do
				table.insert(parts, id .. ":" .. c)
			end
			table.sort(parts)
			return table.concat(parts, ",")
		end)(),
		[A.LastEffect] = state.lastEffect,
		[A.Revision] = state.revision,
	}
	if theme then
		out[A.Theme] = theme
	end
	for id, v in state.dna do
		out[A.DnaPrefix .. id] = v
	end
	return out
end

-- Attributes of a slot model -> State (consumer side).
function Contract.fromInstance(slot: number, inst: Instance): State
	local A = Contract.ATTR
	local dna = {}
	for id in PlanetConfig.DNA_PARAMS do
		dna[id] = inst:GetAttribute(A.DnaPrefix .. id)
	end
	local formations = {}
	local f = inst:GetAttribute(A.Formations)
	if type(f) == "string" and f ~= "" then
		for _, item in string.split(f, ",") do
			local id, c = item:match("^([%w_]+):(%d+)$")
			if id then
				formations[id] = tonumber(c)
			elseif item:match("^[%w_]+$") then
				formations[item] = 1
			end
		end
	end
	return Contract.normalize(slot, {
		ownerUserId = inst:GetAttribute(A.OwnerUserId),
		ownerName = inst:GetAttribute(A.OwnerName),
		branch = inst:GetAttribute(A.Branch),
		stage = inst:GetAttribute(A.Stage),
		dna = dna,
		formations = formations,
		lastEffect = inst:GetAttribute(A.LastEffect),
		revision = inst:GetAttribute(A.Revision),
	})
end

return Contract
