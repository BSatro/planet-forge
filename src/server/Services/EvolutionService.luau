--!strict
-- EvolutionService — owner: Developer B. Server authority for Planet DNA reactions, development stages,
-- branch specialization (commit / re-specialization), the reaction Codex (discovery + mastery) and planet
-- cosmetics. Rules come from EvolutionRules; state changes from ReactionEngine; every cost and reward goes
-- through EconomyService; cosmetics through InventoryService. The client only ever sends INTENT.
--
-- One action = one uninterrupted server step (no yields between validation and commit):
--   validate (profile, ownership, location, busy, expectedRevision, idempotent actionId, rules)
--   -> EconomyService:Transact(costs + first-discovery rewards)      atomic balances
--   -> ReactionEngine.apply*                                         DNA / formations / Codex / revision
--      (if this throws: compensating refund, INTERNAL_ERROR, nothing lost)
--   -> XP, stage milestones, mastery rewards (each granted once)
--   -> PlanetDataService:NotifyChanged -> snapshot + PlanetVisualAdapter (public state + transformation)
-- No DataStore write per action (autosave + a cooldown-limited milestone save on stage/branch changes).
--
-- Remotes (RemoteGuard; replies on Action_Result):
--   Evolution_React    { requestId, actionId, reactionId, expectedRevision?, slot? }   -> REACTED | <error>
--   Evolution_Commit   { requestId, actionId, branchId, confirm = true, expectedRevision? } -> COMMITTED | <error>
--   Evolution_Cosmetic { requestId, category, cosmeticId ("None" to clear) }          -> OK | <error>
-- Error codes: NOT_READY NO_PLANET NOT_OWNER NOT_ON_PLANET BUSY STALE_REVISION INVALID_PAYLOAD
--   UNKNOWN_REACTION ALREADY_COMPLETED MAX_COMPLETIONS REQUIREMENTS_NOT_MET INSUFFICIENT_MATERIALS NO_EFFECT
--   UNKNOWN_BRANCH SAME_BRANCH BRANCH_UNAVAILABLE NOT_CONFIRMED NOT_OWNED INTERNAL_ERROR
--
-- Server API: :React(player, reactionId, opts) / :CommitBranch(player, branchId, opts) /
--   :SetCosmetic(player, category, cosmeticId) -> ok, code, data
--   .ReactionCompleted(player, result) .StageChanged(player, from, to) .BranchChanged(player, from, to)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)
local Server = script.Parent.Parent
local RemoteGuard = require(Server.Net.RemoteGuard)
local ReactionEngine = require(Server.Evolution.ReactionEngine)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)
local PlanetDataService = require(script.Parent.PlanetDataService)

local EvolutionService = {}
EvolutionService.ReactionCompleted = Signal.new()
EvolutionService.StageChanged = Signal.new()
EvolutionService.BranchChanged = Signal.new()

local ACT = EvolutionConfig.ACTIONS
local busy: { [Player]: boolean } = {}
local actionCache: { [Player]: { order: { string }, map: { [string]: any } } } = {}
local lastLog: { [string]: number } = {}

local function log(player: Player, msg: string)
	print(string.format("[PF][Evo] %s (%d): %s", player.Name, player.UserId, msg))
end

local function suspicious(player: Player, code: string, detail: string)
	local k = player.UserId .. code
	local t = os.clock()
	if (lastLog[k] or -math.huge) + 10 < t then
		lastLog[k] = t
		warn(string.format("[PF][Evo] rejected %s from %s (%d): %s", code, player.Name, player.UserId, detail))
	end
end

-- Idempotency keys are namespaced per action kind (a reaction's actionId never answers a branch commit).
local function cacheKey(kind: string, actionId: any): string?
	return if type(actionId) == "string" then kind .. "|" .. actionId else nil
end

local function cached(player: Player, actionId: any): any
	if type(actionId) ~= "string" then
		return nil
	end
	local c = actionCache[player]
	return c and c.map[actionId]
end

local function remember(player: Player, actionId: any, entry: any)
	if type(actionId) ~= "string" then
		return
	end
	local c = actionCache[player]
	if not c then
		c = { order = {}, map = {} }
		actionCache[player] = c
	end
	if c.map[actionId] == nil then
		table.insert(c.order, actionId)
	end
	c.map[actionId] = entry
	while #c.order > ACT.ACTION_CACHE_SIZE do
		c.map[table.remove(c.order, 1) :: string] = nil
	end
end

-- Common gate for every action. Returns ok, code, data, profileData
local function gate(player: Player, opts: any): (boolean, string, any, any)
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", nil, nil
	end
	local slot = PlanetSlotService:GetSlot(player)
	if not slot then
		return false, "NO_PLANET", nil, nil
	end
	if opts.slot ~= nil and opts.slot ~= slot then
		return false, "NOT_OWNER", nil, nil -- cross-planet requests are always refused
	end
	if ACT.REQUIRE_ON_PLANET and not opts.bypassLocation then
		local onPlanet = PlanetDataService:IsOnOwnPlanet(player)
		if not onPlanet then
			return false, "NOT_ON_PLANET", nil, nil
		end
	end
	if busy[player] then
		return false, "BUSY", nil, nil
	end
	if opts.expectedRevision ~= nil and opts.expectedRevision ~= d.planet.rev then
		return false, "STALE_REVISION", { revision = d.planet.rev }, nil
	end
	return true, "OK", nil, d
end

-- Milestones are marked in the profile BEFORE their rewards are granted (they can never be granted twice),
-- so each reward is granted in isolation: one failing grant cannot swallow the others.
local function grantProgressRewards(player: Player, prog: any): { any }
	local granted = {}
	for _, r in prog.rewards do
		local rw = r.reward
		local reason = if r.source == "stage" then "StageUp" else "Mastery"
		local ok, err = pcall(function()
			local tx: any = {}
			if rw.credits and rw.credits > 0 then
				tx.currencies = { Credits = rw.credits }
			end
			if rw.materials then
				tx.materials = table.clone(rw.materials)
			end
			if next(tx) then
				EconomyService:Transact(player, tx, reason, { overflow = "clamp" })
			end
			if rw.xp and rw.xp > 0 then
				EconomyService:GrantXp(player, rw.xp, reason)
			end
			if rw.cosmetic then
				InventoryService:Unlock(player, "cosmetics", rw.cosmetic)
			end
		end)
		if not ok then
			warn("[PF][Evo] progress reward grant failed: " .. tostring(err))
		end
		table.insert(granted, { source = r.source, stage = r.stage, reaction = r.reaction, credits = rw.credits, xp = rw.xp, materials = rw.materials, cosmetic = rw.cosmetic })
	end
	return granted
end

-- Compensation for a failed apply: give back exactly what the transaction APPLIED (a reward clamped at
-- the stack cap was never received, so it must not be taken back either).
local function refundApplied(player: Player, applied: any)
	if type(applied) ~= "table" or ReactionEngine.txIsEmpty(applied) then
		return
	end
	local ok, code = EconomyService:Transact(player, ReactionEngine.invertTx(applied), "Evolution", { overflow = "clamp" })
	if not ok then
		warn("[PF][Evo] refund failed: " .. tostring(code))
	end
end

-- First-discovery reward as actually received (a material reward can be clamped at the stack cap).
local function receivedReward(plan: any, applied: any): any
	local r = plan.reward
	if not r then
		return nil
	end
	local out: any = { credits = r.credits, xp = r.xp, cosmetic = r.cosmetic }
	if r.materials then
		out.materials = {}
		for mid, nominal in r.materials do
			local cost = (plan.def.cost.materials or {})[mid] or 0
			local got = math.max(0, (((applied or {}).materials or {})[mid] or 0) + cost)
			if got > 0 then
				out.materials[mid] = got
			end
			if got < nominal then
				out.capped = out.capped or {}
				out.capped[mid] = nominal - got
			end
		end
	end
	return out
end

-- Runs `fn` holding the player's action lock; the lock is ALWAYS released, an unexpected error becomes
-- INTERNAL_ERROR instead of locking the player out for the rest of the session.
local function withLock(player: Player, label: string, fn: () -> (boolean, string, any)): (boolean, string, any)
	busy[player] = true
	local ok, a, b, c = pcall(fn)
	busy[player] = nil
	if not ok then
		warn(string.format("[PF][Evo] %s failed for %s: %s", label, player.Name, tostring(a)))
		return false, "INTERNAL_ERROR", nil
	end
	return a, b, c
end

local function merge(into: any, from: any)
	for k, v in from do
		into[k] = v
	end
end

local function afterCommit(player: Player, d: any, prog: any, kind: string, extra: any): any
	local granted = grantProgressRewards(player, prog)
	local planet = d.planet
	local gains = {}
	for _, g in extra.gains or {} do
		table.insert(gains, g.id)
	end
	local stageChanged = prog.stageAfter ~= prog.stageBefore
	local transformation = nil
	if kind == "branch" or stageChanged or #gains > 0 or extra.firstDiscovery then
		transformation = {
			id = string.format("%d:%d", player.UserId, planet.rev),
			kind = kind,
			reactionId = extra.reactionId,
			effect = extra.effect,
			formations = gains,
			stageFrom = prog.stageBefore,
			stageTo = prog.stageAfter,
			newStages = prog.newStages,
			branch = planet.branch,
			branchFrom = extra.branchFrom,
			revision = planet.rev,
		}
	end
	PlanetDataService:NotifyChanged(player, { revision = planet.rev, kind = kind, transformation = transformation })
	if stageChanged then
		EvolutionService.StageChanged:Fire(player, prog.stageBefore, prog.stageAfter)
	end
	if (stageChanged or kind == "branch") and ACT.MILESTONE_SAVE then
		task.spawn(function()
			ProfileService:SaveNow(player) -- cooldown-limited; autosave covers the rest
		end)
	end
	return {
		revision = planet.rev,
		stage = planet.stage,
		stageFrom = prog.stageBefore,
		newStages = prog.newStages,
		branch = planet.branch,
		dna = table.clone(planet.dna),
		masteries = prog.masteries,
		progressRewards = granted,
		transformation = transformation,
	}
end

local function unmetTexts(st: any): { string }
	local out = {}
	if st and st.unmet then
		for _, u in st.unmet do
			table.insert(out, u.text)
		end
	end
	return out
end

-- opts: { actionId?, expectedRevision?, slot?, bypassLocation? (server/dev only) }
function EvolutionService:React(player: Player, reactionId: any, opts: any?): (boolean, string, any)
	local o = opts or {}
	local key = cacheKey("react", o.actionId)
	local prior = cached(player, key)
	if prior then
		return prior.ok, prior.code, prior.data -- replay: same answer, nothing executed again
	end
	local okGate, gateCode, gateData, d = gate(player, o)
	if not okGate then
		return false, gateCode, gateData
	end
	return withLock(player, "React", function()
		local okPlan, code, plan = ReactionEngine.planReaction(d, reactionId)
		if not okPlan then
			if code == "UNKNOWN_REACTION" then
				suspicious(player, code, tostring(reactionId))
			end
			local data = { reactionId = reactionId, unmet = unmetTexts(plan), revision = d.planet.rev }
			remember(player, key, { ok = false, code = code, data = data })
			return false, code, data
		end
		local okTx, txCode, applied = EconomyService:Transact(player, plan.tx, "Evolution", { overflow = "clamp" })
		if not okTx then
			return false, if txCode == "INSUFFICIENT_FUNDS" then "INSUFFICIENT_MATERIALS" else txCode, { reactionId = reactionId, revision = d.planet.rev }
		end
		local now = os.time()
		local okApply, applyErr = pcall(ReactionEngine.applyReaction, d, plan, now)
		if not okApply then
			refundApplied(player, applied) -- planet untouched; balances restored exactly
			warn("[PF][Evo] applyReaction failed, refunded: " .. tostring(applyErr))
			return false, "INTERNAL_ERROR", nil
		end
		-- COMMITTED. Remember the answer FIRST: whatever happens below, a retry of this actionId replays it.
		local gainsOut = {}
		for _, g in plan.gains do
			table.insert(gainsOut, { id = g.id, from = g.from, to = g.to })
		end
		local data: any = {
			reactionId = reactionId,
			name = plan.def.name,
			firstDiscovery = plan.firstDiscovery,
			dnaDelta = plan.dnaDelta,
			formations = gainsOut,
			reward = receivedReward(plan, applied),
			completions = d.reactions[reactionId].n,
			revision = d.planet.rev,
			stage = d.planet.stage,
			branch = d.planet.branch,
			dna = table.clone(d.planet.dna),
		}
		remember(player, key, { ok = true, code = "REACTED", data = data })
		local okPost, postErr = pcall(function()
			if plan.xp > 0 then
				EconomyService:GrantXp(player, plan.xp, "Evolution")
			end
			if plan.cosmetic then
				InventoryService:Unlock(player, "cosmetics", plan.cosmetic)
			end
			local prog = ReactionEngine.evaluateProgress(d, now)
			merge(data, afterCommit(player, d, prog, "reaction", {
				gains = plan.gains,
				firstDiscovery = plan.firstDiscovery,
				reactionId = reactionId,
				effect = plan.def.effect,
			}))
		end)
		if not okPost then
			-- the reaction itself is committed; stage/mastery are re-evaluated on the next action
			warn("[PF][Evo] post-commit step failed (reaction kept): " .. tostring(postErr))
			pcall(PlanetDataService.NotifyChanged, PlanetDataService, player, { revision = d.planet.rev, kind = "reaction" })
		end
		if plan.firstDiscovery or #gainsOut > 0 or (data.newStages and #data.newStages > 0) then
			log(player, string.format("%s %s rev=%d stage=%d%s", reactionId, plan.def.name, data.revision, data.stage, if plan.firstDiscovery then " (discovered)" else ""))
		end
		self.ReactionCompleted:Fire(player, data)
		return true, "REACTED", data
	end)
end

-- opts: { actionId?, expectedRevision?, confirm = true (required), bypassLocation? }
function EvolutionService:CommitBranch(player: Player, branchId: any, opts: any?): (boolean, string, any)
	local o = opts or {}
	local key = cacheKey("commit", o.actionId)
	local prior = cached(player, key)
	if prior then
		return prior.ok, prior.code, prior.data
	end
	local okGate, gateCode, gateData, d = gate(player, o)
	if not okGate then
		return false, gateCode, gateData
	end
	return withLock(player, "CommitBranch", function()
		local okPlan, code, plan = ReactionEngine.planBranch(d, branchId, o.confirm)
		if not okPlan then
			if code == "UNKNOWN_BRANCH" then
				suspicious(player, code, tostring(branchId))
			end
			local data = { branchId = branchId, unmet = unmetTexts(plan), revision = d.planet.rev }
			if code ~= "NOT_CONFIRMED" then
				remember(player, key, { ok = false, code = code, data = data })
			end
			return false, code, data
		end
		local okTx, txCode, applied = EconomyService:Transact(player, plan.tx, "Evolution", { overflow = "clamp" })
		if not okTx then
			return false, if txCode == "INSUFFICIENT_FUNDS" then "INSUFFICIENT_MATERIALS" else txCode, { branchId = branchId }
		end
		local now = os.time()
		local okApply, applyErr = pcall(ReactionEngine.applyBranch, d, plan, now)
		if not okApply then
			refundApplied(player, applied)
			warn("[PF][Evo] applyBranch failed, refunded: " .. tostring(applyErr))
			return false, "INTERNAL_ERROR", nil
		end
		local data: any = {
			branchId = branchId,
			isRespec = plan.isRespec,
			branchFrom = plan.from,
			dormant = plan.willGoDormant,
			revision = d.planet.rev,
			stage = d.planet.stage,
			branch = d.planet.branch,
		}
		remember(player, key, { ok = true, code = "COMMITTED", data = data })
		local okPost, postErr = pcall(function()
			local prog = ReactionEngine.evaluateProgress(d, now)
			merge(data, afterCommit(player, d, prog, "branch", { gains = plan.gains, effect = plan.effect, branchFrom = plan.from }))
		end)
		if not okPost then
			warn("[PF][Evo] post-commit step failed (branch kept): " .. tostring(postErr))
			pcall(PlanetDataService.NotifyChanged, PlanetDataService, player, { revision = d.planet.rev, kind = "branch" })
		end
		log(player, string.format("branch %s -> %s (respec=%s) rev=%d stage=%d", plan.from, branchId, tostring(plan.isRespec), data.revision, data.stage))
		self.BranchChanged:Fire(player, plan.from, branchId)
		return true, "COMMITTED", data
	end)
end

function EvolutionService:SetCosmetic(player: Player, category: any, cosmeticId: any): (boolean, string, any)
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY", nil
	end
	if type(category) ~= "string" or not ItemCatalog.EQUIPPABLE_CATEGORIES[category] then
		return false, "INVALID_PAYLOAD", nil
	end
	local current = d.planet.cosmetics[category]
	if (cosmeticId == "None" and current == nil) or cosmeticId == current then
		return true, "OK", { revision = d.planet.rev, cosmetics = table.clone(d.planet.cosmetics) } -- no change
	end
	if cosmeticId == "None" then
		d.planet.cosmetics[category] = nil
	else
		local e = ItemCatalog.COSMETICS[cosmeticId]
		if not e or e.category ~= category then
			return false, "INVALID_PAYLOAD", nil
		end
		if d.cosmetics[cosmeticId] == nil then
			return false, "NOT_OWNED", nil
		end
		d.planet.cosmetics[category] = cosmeticId
	end
	d.planet.rev += 1
	PlanetDataService:NotifyChanged(player, { revision = d.planet.rev, kind = "cosmetic" })
	return true, "OK", { revision = d.planet.rev, cosmetics = table.clone(d.planet.cosmetics) }
end

---------------------------------------------------------------- lifecycle

local function validActionId(v: any): boolean
	return type(v) == "string" and #v >= 4 and #v <= ACT.ACTION_ID_MAX_LENGTH and string.match(v, "^[%w%-_:]+$") ~= nil
end

local function optionalInt(v: any): (boolean, number?)
	if v == nil then
		return true, nil
	end
	if RemoteGuard.isInt(v, 0, 2 ^ 31) then
		return true, v
	end
	return false, nil
end

function EvolutionService:Init()
	ProfileService.ProfileReleasing:Connect(function(player: Player)
		busy[player] = nil
		actionCache[player] = nil
	end)
	Players.PlayerRemoving:Connect(function(player)
		busy[player] = nil
		actionCache[player] = nil
	end)
end

function EvolutionService:Start()
	RemoteGuard.bind("Evolution_React", function(player, p)
		if not validActionId(p.actionId) or not RemoteGuard.isId(p.reactionId) then
			return false, "INVALID_PAYLOAD"
		end
		local okRev, rev = optionalInt(p.expectedRevision)
		local okSlot, slot = optionalInt(p.slot)
		if not okRev or not okSlot then
			return false, "INVALID_PAYLOAD"
		end
		return EvolutionService:React(player, p.reactionId, { actionId = p.actionId, expectedRevision = rev, slot = slot })
	end)
	RemoteGuard.bind("Evolution_Commit", function(player, p)
		if not validActionId(p.actionId) or not RemoteGuard.isId(p.branchId) or type(p.confirm) ~= "boolean" then
			return false, "INVALID_PAYLOAD"
		end
		local okRev, rev = optionalInt(p.expectedRevision)
		if not okRev then
			return false, "INVALID_PAYLOAD"
		end
		return EvolutionService:CommitBranch(player, p.branchId, { actionId = p.actionId, expectedRevision = rev, confirm = p.confirm })
	end)
	RemoteGuard.bind("Evolution_Cosmetic", function(player, p)
		if not RemoteGuard.isId(p.category) or not RemoteGuard.isId(p.cosmeticId) then
			return false, "INVALID_PAYLOAD"
		end
		return EvolutionService:SetCosmetic(player, p.category, p.cosmeticId)
	end)
end

-- Test/diagnostic: sanitized reaction previews for a player (clients compute the same via EvolutionRules).
function EvolutionService:GetPreviews(player: Player): any
	local view = PlanetDataService:GetView(player)
	if not view then
		return nil
	end
	local EvolutionRules = require(Shared.Evolution.EvolutionRules)
	local out = {}
	for _, id in ReactionRegistry.ORDER do
		local st = EvolutionRules.reactionStatus(view, id)
		table.insert(out, { id = id, status = st.status, unmet = unmetTexts(st) })
	end
	return TableUtil.deepCopy(out)
end

return EvolutionService
