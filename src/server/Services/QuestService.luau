--!strict
-- QuestService — owner: Live Gameplay. Daily + weekly quests (INTERFACES §11), server-authoritative.
--   * state lives in the profile (profile.quests, repaired by ProfileSchema via QuestRules.reconcile) and reaches
--     the owning client inside Profile_Snapshot (`quests` = QuestRules.view), so the HUD updates live
--   * progress comes ONLY from committed server events: harvest captures, reactions, sells, credits earned,
--     completed rifts, cosmic-event rewards (WorldEventService.RewardGranted: the rewarding instance counts once).
--     Clients send nothing but "claim quest N".
--   * rewards go through EconomyService with reason "Quest" (credits) + GrantXp; a failed grant undoes the claim
--   * period rollover (00:00 UTC / Monday 00:00 UTC) is checked on load, before every claim and every 30 s;
--     finished-but-unclaimed quests of an expired period are granted automatically
-- Remote: Quest_Action {requestId, action = "claim", period = "day"|"week", index = 1..3} -> Action_Result
--         (RemoteGuard default rate limit). Signals: QuestCompleted(player, kind, id), QuestClaimed(player, kind, id, auto).
-- Studio only: ServerStorage.PF_QuestHook (BindableFunction) for tests: state / progress / offset / reset.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local QuestConfig = require(Shared.Quests.QuestConfig)
local QuestRules = require(Shared.Quests.QuestRules)
local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local EconomyService = require(script.Parent.EconomyService)
local HarvestService = require(script.Parent.HarvestService)
local EvolutionService = require(script.Parent.EvolutionService)
local WorldEventService = require(script.Parent.WorldEventService)

local QuestService = {}
QuestService.QuestCompleted = Signal.new() -- (player, kind, questId)
QuestService.QuestClaimed = Signal.new() -- (player, kind, questId, auto: boolean)

local clockOffset = 0 -- Studio tests only (PF_QuestHook "offset")
local lastExpeditions: { [Player]: number } = {}

local function now(): number
	return os.time() + clockOffset
end

local function stateOf(player: Player): any
	local d = ProfileService:GetData(player)
	if not d then
		return nil, nil
	end
	if type(d.quests) ~= "table" then
		d.quests = QuestRules.reconcile(nil)
	end
	return d.quests, d
end

local function grant(player: Player, r: QuestRules.Reward, auto: boolean): (boolean, string)
	local ok, code = EconomyService:Transact(player, { currencies = { Credits = r.credits } }, "Quest", { overflow = "clamp" })
	if not ok then
		warn(string.format("[PF][Quest] %s: %s reward not granted (%s)", player.Name, r.id, tostring(code)))
		return false, code
	end
	EconomyService:GrantXp(player, r.xp, "Quest")
	QuestService.QuestClaimed:Fire(player, r.kind, r.id, auto)
	return true, "OK"
end

-- Rolls periods over (granting finished-but-unclaimed quests of expired periods). Returns the state.
local function ensure(player: Player): any
	local s, d = stateOf(player)
	if not s then
		return nil
	end
	local rolled, changed = QuestRules.ensure(s, player.UserId, now(), d.level or 1)
	for _, r in rolled do
		grant(player, r, true)
	end
	if changed or #rolled > 0 then
		ProfileService:MarkChanged(player, "quests")
	end
	return s
end

local function addProgress(player: Player, metric: string, amount: number)
	local s = ensure(player)
	if not s then
		return
	end
	local done, changed = QuestRules.progress(s, metric, amount)
	if changed then
		ProfileService:MarkChanged(player, "quests")
	end
	for _, q in done do
		QuestService.QuestCompleted:Fire(player, q.kind, q.id)
	end
end

function QuestService:Claim(player: Player, kind: any, index: any): (boolean, string, any?)
	local s = ensure(player)
	if not s then
		return false, "NOT_READY", nil
	end
	local ok, code, reward = QuestRules.claim(s, kind, index, now())
	if not ok or not reward then
		return false, code, nil
	end
	local granted, gcode = grant(player, reward, false)
	if not granted then
		QuestRules.unclaim(s, kind, index)
		return false, gcode, nil
	end
	ProfileService:MarkChanged(player, "quests")
	return true, "OK", { id = reward.id, credits = reward.credits, xp = reward.xp }
end

function QuestService:View(player: Player): any
	local s = ensure(player)
	return QuestRules.view(s, now())
end

function QuestService:Init() end

function QuestService:Start()
	ProfileService.ProfileLoaded:Connect(function(player: Player)
		local _, d = stateOf(player)
		lastExpeditions[player] = if d and d.expeditions then d.expeditions.totalCompleted or 0 else 0
		ensure(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastExpeditions[player] = nil
	end)
	for _, player in ProfileService:GetLoadedPlayers() do
		local _, d = stateOf(player)
		lastExpeditions[player] = if d and d.expeditions then d.expeditions.totalCompleted or 0 else 0
		ensure(player)
	end

	HarvestService.CaptureCompleted:Connect(function(player: Player, info: any)
		addProgress(player, "capture", 1)
		if type(info) == "table" and info.quality == "perfect" then
			addProgress(player, "perfect", 1)
		end
	end)
	EvolutionService.ReactionCompleted:Connect(function(player: Player)
		addProgress(player, "reaction", 1)
	end)
	EconomyService.TransactionCompleted:Connect(function(player: Player, reason: string, applied: any)
		if type(applied) ~= "table" then
			return
		end
		if reason == "Sell" and type(applied.materials) == "table" then
			local sold = 0
			for _, v in applied.materials do
				if type(v) == "number" and v < 0 then
					sold -= v
				end
			end
			addProgress(player, "sell", sold)
		end
		local credits = type(applied.currencies) == "table" and applied.currencies.Credits
		if type(credits) == "number" and credits > 0 and reason ~= "Quest" and reason ~= "Dev" then
			addProgress(player, "earn", credits)
		end
	end)
	-- cosmic events: the event instance that actually rewarded the player counts once (not every event running)
	WorldEventService.RewardGranted:Connect(function(player: Player, instanceId: string)
		local s = ensure(player)
		if s and QuestRules.recordEvent(s, instanceId) then
			addProgress(player, "event", 1)
		end
	end)
	-- completed rifts: InventoryService:RecordExpedition raises expeditions.totalCompleted (completed runs only)
	ProfileService.ProfileChanged:Connect(function(player: Player, section: string?)
		if section == "quests" then
			return
		end
		local d = ProfileService:GetData(player)
		local total = d and d.expeditions and d.expeditions.totalCompleted
		local last = lastExpeditions[player]
		if type(total) == "number" and last ~= nil and total > last then
			lastExpeditions[player] = total
			addProgress(player, "rift", total - last)
		end
	end)

	RemoteGuard.bind("Quest_Action", function(player: Player, payload: any)
		if payload.action == "claim" then
			return QuestService:Claim(player, payload.period, payload.index)
		end
		return false, "INVALID_PAYLOAD"
	end)

	-- midnight / Monday rollover for players who stay online
	task.spawn(function()
		while true do
			task.wait(QuestConfig.ROLLOVER_CHECK_SECONDS)
			for _, player in ProfileService:GetLoadedPlayers() do
				pcall(ensure, player)
			end
		end
	end)

	if RunService:IsStudio() then
		local hook = (ServerStorage:FindFirstChild("PF_QuestHook") :: BindableFunction?) or Instance.new("BindableFunction")
		hook.Name = "PF_QuestHook"
		hook.Archivable = false
		hook.OnInvoke = function(cmd: string, userId: number?, arg: any): any
			if cmd == "offset" then
				clockOffset = tonumber(arg) or 0
				return clockOffset
			end
			local player = userId and Players:GetPlayerByUserId(userId)
			if not player then
				return { error = "NO_PLAYER" }
			end
			if cmd == "state" then
				return QuestService:View(player)
			elseif cmd == "raw" then
				return (stateOf(player))
			elseif cmd == "progress" then
				addProgress(player, arg.metric, arg.amount)
				return QuestService:View(player)
			elseif cmd == "reset" then
				local _, d = stateOf(player)
				d.quests = QuestRules.reconcile(nil)
				return QuestService:View(player)
			end
			return { error = "UNKNOWN_COMMAND" }
		end
		hook.Parent = ServerStorage
	end
end

return QuestService
