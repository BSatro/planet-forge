--!strict
-- EvolutionClient — owner: Developer B. CLIENT-ONLY contract for evolution UIs (Developer A can build any
-- presentation on top of it). Everything is derived from the authoritative Profile_Snapshot with the SAME
-- EvolutionRules the server enforces, so previews never disagree with the server. Actions only send intent.
--
--   EvolutionClient.view()                -> EvolutionRules view | nil
--   EvolutionClient.reactions()           -> { ReactionPreview } sorted for display (see below)
--   EvolutionClient.branches()            -> { BranchPreview } (4 selectable + future ones)
--   EvolutionClient.stage()               -> { stage, name, description, next = { stage, name, goal, unmet } }
--   EvolutionClient.codex()               -> { entries = { CodexEntry }, discovered, mastered, total }
--   EvolutionClient.dna()                 -> { { id, name, value, color, description } }
--   EvolutionClient.materials()           -> { { id, name, amount, color, category, description } }
--   EvolutionClient.cosmetics()           -> { owned = { { id, name, category } }, equipped = { [category]=id } }
--   EvolutionClient.isOnOwnPlanet()       -> boolean (client-side hint of the server's location rule)
--   EvolutionClient.react(reactionId)     -> ok, code, data   (yields; sends actionId + expectedRevision)
--   EvolutionClient.commit(branchId)      -> ok, code, data   (always confirm = true: call only after the
--                                                              player confirmed in your UI)
--   EvolutionClient.setCosmetic(category, cosmeticId | "None") -> ok, code, data
--   EvolutionClient.Changed               Signal(snapshot)     authoritative state changed
--   EvolutionClient.Transformation        Signal(event)        any planet's committed milestone
--   EvolutionClient.describeError(code, data) -> player-facing text
--
-- ReactionPreview = { id, name, description, category, branch, status, available, unmet = {texts},
--   costs = {{ id, name, need, have, ok }}, dnaDelta = { [param] = n }, formations = {{ id, name, to }},
--   reward = { credits, xp, materials, cosmetic }? (first discovery only), codexState, completions, headline }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = script.Parent.Parent
local Signal = require(Shared.Util.Signal)
local PlanetConfig = require(Shared.Config.PlanetConfig)
local WorldLayout = require(Shared.Config.WorldLayout)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local EvolutionRules = require(Shared.Evolution.EvolutionRules)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local ProfileClient = require(script.Parent.ProfileClient)

local EvolutionClient = {}
EvolutionClient.Changed = Signal.new()
EvolutionClient.Transformation = Signal.new()

local started = false

local function init()
	if started then
		return
	end
	started = true
	ProfileClient.Changed:Connect(function(s)
		EvolutionClient.Changed:Fire(s)
	end)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 30)
		local ev = remotes and remotes:WaitForChild("Planet_Transformation", 30) :: RemoteEvent?
		if ev then
			ev.OnClientEvent:Connect(function(msg)
				if type(msg) == "table" and type(msg.transformation) == "table" then
					EvolutionClient.Transformation:Fire(msg)
				end
			end)
		end
	end)
end

function EvolutionClient.view(): any
	init()
	local s = ProfileClient.get()
	return s and EvolutionRules.viewFromSnapshot(s)
end

local STATUS_RANK = { AVAILABLE = 1, NEEDS_MATERIALS = 2, LOCKED = 3, NO_EFFECT = 4, MAXED = 5, DONE = 6, UNKNOWN = 7 }

function EvolutionClient.reactions(): { any }
	local view = EvolutionClient.view()
	if not view then
		return {}
	end
	local out = {}
	for i, id in ReactionRegistry.ORDER do
		local st = EvolutionRules.reactionStatus(view, id)
		local def = st.def
		local unmet = {}
		for _, u in st.unmet do
			table.insert(unmet, u.text)
		end
		local forms = {}
		for _, g in st.formationGains do
			table.insert(forms, { id = g.id, name = EvolutionRules.formationName(g.id), to = g.to })
		end
		local codex = EvolutionRules.codexStatus(view, id)
		table.insert(out, {
			id = id,
			order = i,
			name = def.name,
			description = def.description,
			headline = def.preview and def.preview.headline,
			category = def.category,
			branch = def.branch,
			branchRequired = type(def.requires.branch) == "string" and def.requires.branch or nil,
			status = st.status,
			available = st.available,
			unmet = unmet,
			costs = st.costs,
			dnaDelta = st.dnaDelta,
			formations = forms,
			reward = st.reward,
			codexState = codex.state,
			completions = st.completions,
			repeats = def.repeats,
		})
	end
	table.sort(out, function(a, b)
		local ra, rb = STATUS_RANK[a.status] or 9, STATUS_RANK[b.status] or 9
		if ra ~= rb then
			return ra < rb
		end
		return a.order < b.order
	end)
	return out
end

function EvolutionClient.branches(): { any }
	local view = EvolutionClient.view()
	local out = {}
	for _, b in PlanetConfig.BRANCH_ORDER do
		local bdef = PlanetConfig.BRANCHES[b]
		if view and bdef and bdef.selectable then
			local st = EvolutionRules.branchStatus(view, b)
			local rule = EvolutionConfig.BRANCH_RULES[b]
			local unmet = {}
			for _, u in st.unmet or {} do
				table.insert(unmet, u.text)
			end
			local unlocks = {}
			for fid in rule.unlocks or {} do
				table.insert(unlocks, EvolutionRules.formationName(fid))
			end
			local key = {}
			for _, fid in FormationRegistry.BRANCH_FORMATIONS[b] or {} do
				table.insert(key, EvolutionRules.formationName(fid))
			end
			local dormant = {}
			for _, fid in st.willGoDormant or {} do
				table.insert(dormant, EvolutionRules.formationName(fid))
			end
			table.insert(out, {
				id = b,
				name = bdef.displayName,
				focus = bdef.focus,
				color = bdef.color,
				headline = rule.headline,
				consequences = rule.consequences,
				status = st.status,
				available = st.available,
				isRespec = st.isRespec,
				unmet = unmet,
				costs = st.costs or {},
				unlocks = unlocks,
				capstone = EvolutionRules.formationName(rule.capstone),
				formations = key,
				willGoDormant = dormant,
				requires = rule.requires,
			})
		elseif bdef and bdef.future then
			table.insert(out, { id = b, name = bdef.displayName, status = "UNAVAILABLE", future = true, available = false })
		end
	end
	return out
end

function EvolutionClient.stage(): any
	local view = EvolutionClient.view()
	if not view then
		return nil
	end
	local p = EvolutionRules.stageProgress(view)
	if p.next then
		local texts = {}
		for _, u in p.next.unmet do
			table.insert(texts, u.text)
		end
		p.next.unmetTexts = texts
	end
	p.branch = view.branch
	p.branchName = (PlanetConfig.BRANCHES[view.branch] or {}).displayName
	return p
end

function EvolutionClient.codex(): any
	local view = EvolutionClient.view()
	local entries, discovered, mastered = {}, 0, 0
	if not view then
		return { entries = entries, discovered = 0, mastered = 0, total = #ReactionRegistry.ORDER }
	end
	for _, id in ReactionRegistry.ORDER do
		local def = ReactionRegistry.DEFS[id]
		local c = EvolutionRules.codexStatus(view, id)
		local rec = view.codex[id]
		if c.state ~= "UNDISCOVERED" then
			discovered += 1
		end
		if c.state == "MASTERED" then
			mastered += 1
		end
		local unmet = {}
		for _, u in c.unmet or {} do
			table.insert(unmet, u.text)
		end
		table.insert(entries, {
			id = id,
			name = def.name,
			category = def.category,
			branch = def.branch,
			state = c.state,
			discoveredAt = rec and rec.d,
			masteredAt = rec and rec.m,
			completions = c.completions or 0,
			masteryHint = c.hint,
			masteryUnmet = unmet,
			description = def.description,
		})
	end
	return { entries = entries, discovered = discovered, mastered = mastered, total = #ReactionRegistry.ORDER }
end

function EvolutionClient.dna(): { any }
	local view = EvolutionClient.view()
	local out = {}
	for _, id in PlanetConfig.DNA_ORDER do
		local def = PlanetConfig.DNA_PARAMS[id]
		table.insert(out, { id = id, name = def.displayName, short = def.short, value = view and view.dna[id] or def.default, color = def.color, description = def.description })
	end
	return out
end

function EvolutionClient.materials(): { any }
	local view = EvolutionClient.view()
	local out = {}
	for _, id in ItemCatalog.ids("materials") do
		local e = ItemCatalog.MATERIALS[id]
		table.insert(out, { id = id, name = e.displayName, amount = view and view.materials[id] or 0, color = e.iconColor, category = e.category, description = e.description })
	end
	return out
end

function EvolutionClient.cosmetics(): any
	local s = ProfileClient.get()
	local owned = {}
	for _, id in (s and s.cosmetics) or {} do
		local e = ItemCatalog.COSMETICS[id]
		if e and (e.category == "Atmosphere" or e.category == "PlanetRing") then
			table.insert(owned, { id = id, name = e.displayName, category = e.category, color = e.color })
		end
	end
	return { owned = owned, equipped = (s and s.planet and s.planet.cosmetics) or {} }
end

function EvolutionClient.isOnOwnPlanet(): boolean
	local player = Players.LocalPlayer
	local slot = player:GetAttribute("PF_Slot")
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if type(slot) ~= "number" or not root then
		return false
	end
	return (root.Position - WorldLayout.getSlotCenter(slot)).Magnitude <= WorldLayout.PLANET_RADIUS * EvolutionConfig.ACTIONS.ON_PLANET_RADIUS_FACTOR
end

local function revision(): number?
	local s = ProfileClient.get()
	return s and s.planet and s.planet.revision
end

function EvolutionClient.react(reactionId: string): (boolean, string?, any)
	init()
	return ProfileClient.request("Evolution_React", {
		actionId = HttpService:GenerateGUID(false),
		reactionId = reactionId,
		expectedRevision = revision(),
	})
end

function EvolutionClient.commit(branchId: string): (boolean, string?, any)
	init()
	return ProfileClient.request("Evolution_Commit", {
		actionId = HttpService:GenerateGUID(false),
		branchId = branchId,
		confirm = true,
		expectedRevision = revision(),
	})
end

function EvolutionClient.setCosmetic(category: string, cosmeticId: string): (boolean, string?, any)
	init()
	return ProfileClient.request("Evolution_Cosmetic", { category = category, cosmeticId = cosmeticId })
end

local ERRORS: { [string]: string } = {
	NOT_READY = "Your planet data is still loading. Nothing is lost.",
	NO_PLANET = "You don't have a planet in this server yet.",
	NOT_OWNER = "You can only change your own planet.",
	NOT_ON_PLANET = "Stand on your own planet to perform reactions.",
	BUSY = "Another reaction is still being processed.",
	STALE_REVISION = "Your planet changed a moment ago — refreshed. Try again.",
	INVALID_PAYLOAD = "That request was not valid.",
	UNKNOWN_REACTION = "Unknown reaction.",
	ALREADY_COMPLETED = "This transformation already happened on your planet.",
	MAX_COMPLETIONS = "This reaction has reached its limit on your planet.",
	INSUFFICIENT_MATERIALS = "Not enough materials.",
	REQUIREMENTS_NOT_MET = "Your planet doesn't meet the conditions yet.",
	NO_EFFECT = "It would have no effect right now — your materials were not used.",
	UNKNOWN_BRANCH = "Unknown specialization.",
	SAME_BRANCH = "Your planet already has this specialization.",
	BRANCH_UNAVAILABLE = "This specialization is not available yet.",
	NOT_CONFIRMED = "Please confirm the specialization.",
	NOT_OWNED = "You don't own that cosmetic yet.",
	RATE_LIMITED = "Slow down a little.",
	TIMEOUT = "The server didn't answer — nothing was spent. Try again.",
	INTERNAL_ERROR = "Something went wrong — your materials were refunded.",
}

function EvolutionClient.describeError(code: string?, data: any?): string
	local base = ERRORS[code or ""] or ("Request failed (" .. tostring(code) .. ")")
	if type(data) == "table" and type(data.unmet) == "table" and data.unmet[1] then
		return base .. " " .. tostring(data.unmet[1])
	end
	return base
end

function EvolutionClient.init()
	init()
end

return EvolutionClient
