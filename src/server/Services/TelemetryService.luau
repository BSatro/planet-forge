--!strict
-- TelemetryService — owner: Release / Live Ops. Server-only product analytics through Roblox AnalyticsService.
-- Privacy: no names, chat, free text or device data are sent — only fixed ids, small counts and enum-like labels,
-- attached to the player the way AnalyticsService always does. Every event is logged AFTER the server committed
-- the state change it describes (never on a client request alone). Roblox's built-in dashboards already cover
-- DAU, retention, session length, revenue and pass/product sales, so none of those are re-logged here.
--
-- Events (INTERFACES §10):
--   Onboarding funnel (one-time, mirrors the in-game guide): 1 Joined · 2 ReachedOwnPlanet · 3 FirstMeteorCapture ·
--     4 FirstReaction · 5 TutorialComplete (second discovery or first stage-up). Skipped steps are auto-completed by
--     Roblox (e.g. a reaction before any capture, as the guide itself allows).
--   Custom "Milestone" (CustomField01): FirstMeteorCapture | FirstEvolution | FirstExpedition | SecondSession
--   Custom "ReactionDiscovered": CustomField01 = reaction id, CustomField02 = "Total - N" (discovery counts)
--   Recurring funnel "Store" (one session per store visit): 1 StoreOpened · 2 PurchasePrompted · 3 PurchaseCompleted
--     (CustomField01 = "Item - <key>"); fed by MonetizationService.StoreFunnel
--   Economy: Credits sources / sinks by economy reason (Dev grants excluded), ending balance after the change
--   Custom "QuestClaimed" (daily/weekly quests, QuestService.QuestClaimed): CustomField01 = "Daily - <questId>" |
--     "Weekly - <questId>", CustomField02 = "Manual" | "Auto" (granted at period rollover); value = 1
-- Studio: AnalyticsService records nothing from Studio, but the calls are still made (pcall) and mirrored into a
-- bounded in-memory log that ServerStorage.PF_TelemetryHook (Studio only) returns, so tests can verify them.
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Analytics = game:GetService("AnalyticsService")

local Formulas = require(ReplicatedStorage.PF_Shared.Economy.EconomyFormulas)
local ProfileService = require(script.Parent.ProfileService)
local EconomyService = require(script.Parent.EconomyService)
local EvolutionService = require(script.Parent.EvolutionService)
local HarvestService = require(script.Parent.HarvestService)
local PlanetDataService = require(script.Parent.PlanetDataService)
local MonetizationService = require(script.Parent.MonetizationService)
local QuestService = require(script.Parent.QuestService)

local TelemetryService = {}

local CF = Enum.AnalyticsCustomFieldKeys
local isStudio = RunService:IsStudio()
local STEPS = { "Joined", "ReachedOwnPlanet", "FirstMeteorCapture", "FirstReaction", "TutorialComplete" }
local SOURCE_TYPE: { [string]: string } = {
	Harvest = "Gameplay", Expedition = "Gameplay", Event = "Gameplay", Quest = "TimedReward", Discovery = "Gameplay",
	Mastery = "Gameplay", StageUp = "Gameplay", LevelUp = "Gameplay", Evolution = "Gameplay", Sell = "Shop",
}
local SINK_TYPE: { [string]: string } = { Upgrade = "Shop", Evolution = "Gameplay" }

type PState = { steps: { [number]: boolean }, expeditions: number, store: string?, storeStep: number }
local states: { [Player]: PState } = {}
local debugLog: { any } = {}
local sent = 0
local failed = 0

local function mirror(kind: string, player: Player, a: any?, b: any?, c: any?)
	if not isStudio then
		return
	end
	table.insert(debugLog, { kind = kind, userId = player.UserId, a = a, b = b, c = c, t = os.clock() })
	while #debugLog > 300 do
		table.remove(debugLog, 1)
	end
end

local function fields(f1: string?, f2: string?): { [string]: string }?
	local t: { [string]: string } = {}
	if f1 then
		t[CF.CustomField01.Name] = f1
	end
	if f2 then
		t[CF.CustomField02.Name] = f2
	end
	return if next(t) then t else nil
end

local function call(fn: any, ...: any)
	local ok, err = pcall(fn, Analytics, ...)
	if ok then
		sent += 1
	else
		failed += 1
		if failed <= 5 then
			warn("[PF][Telemetry] AnalyticsService call failed: " .. tostring(err))
		end
	end
end

local function onboarding(p: Player, step: number)
	local s = states[p]
	if not s or s.steps[step] then
		return
	end
	for k = 1, step do
		if not s.steps[k] then
			s.steps[k] = true
			call(Analytics.LogOnboardingFunnelStepEvent, p, k, STEPS[k])
			mirror("onboarding", p, k, STEPS[k])
		end
	end
end

local function custom(p: Player, name: string, value: number, f1: string?, f2: string?)
	call(Analytics.LogCustomEvent, p, name, value, fields(f1, f2))
	mirror("custom", p, name, f1, f2)
end

local function discovered(d: any): number
	local n = 0
	for _, rec in (d and d.reactions) or {} do
		if type(rec) == "table" and rec.d ~= nil then
			n += 1
		end
	end
	return n
end

local function credits(p: Player): number
	return EconomyService:GetBalance(p, "currencies", "Credits") or 0
end

local function economy(p: Player, flow: Enum.AnalyticsEconomyFlowType, amount: number, reason: string, ttype: string)
	if amount <= 0 then
		return
	end
	call(Analytics.LogEconomyEvent, p, flow, "Credits", amount, credits(p), ttype, nil, fields("Reason - " .. reason))
	mirror("economy", p, flow.Name, amount, reason)
end

local function storeStep(p: Player, step: number, name: string, key: string?)
	local s = states[p]
	if not s then
		return
	end
	if step == 1 or not s.store then
		-- random per-visit id: AnalyticsService already knows the player, so the id carries no user identity
		s.store = HttpService:GenerateGUID(false)
		s.storeStep = 0
	end
	if step <= s.storeStep and step ~= 3 then
		return -- the same step twice in one visit is not a new funnel event
	end
	s.storeStep = math.max(s.storeStep, step)
	call(Analytics.LogFunnelStepEvent, p, "Store", s.store, step, name, fields(if key then "Item - " .. key else nil))
	mirror("store", p, step, name, key)
end

----------------------------------------------------------------------------------------------------
local function onLoaded(p: Player, _slot: number, isNew: boolean)
	local d = ProfileService:GetData(p)
	if not d then
		return
	end
	local s: PState = { steps = {}, expeditions = (d.expeditions and d.expeditions.totalCompleted) or 0, store = nil, storeStep = 0 }
	states[p] = s
	-- returning players: steps their saved progress already proves are not logged again
	local harvests = (d.stats and d.stats.harvests) or 0
	local disc = discovered(d)
	local stage = (d.planet and d.planet.stage) or 0
	if not isNew then
		s.steps[1] = true
	end
	if harvests > 0 or disc > 0 then
		s.steps[1], s.steps[2] = true, true
	end
	if harvests > 0 then
		s.steps[3] = true
	end
	if disc > 0 then
		s.steps[3], s.steps[4] = true, true
	end
	if disc >= 2 or stage >= 1 then
		s.steps[5] = true
	end
	if isNew then
		onboarding(p, 1)
	end
	if (d.loginCount or 0) == 2 then
		custom(p, "Milestone", 1, "SecondSession")
	end
end

function TelemetryService:Init() end

function TelemetryService:Start()
	ProfileService.ProfileLoaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(p: Player)
		states[p] = nil
	end)
	QuestService.QuestClaimed:Connect(function(p: Player, kind: string, id: string, auto: boolean)
		custom(p, "QuestClaimed", 1, (if kind == "day" then "Daily - " else "Weekly - ") .. id, if auto then "Auto" else "Manual")
	end)
	HarvestService.CaptureCompleted:Connect(function(p: Player, info: any)
		if type(info) == "table" and type(info.discoveries) == "table" and table.find(info.discoveries, "FirstHarvest") then
			-- FirstHarvest is granted exactly once per profile (HarvestService), so this milestone fires once
			custom(p, "Milestone", 1, "FirstMeteorCapture")
			onboarding(p, 3)
		end
	end)
	EvolutionService.ReactionCompleted:Connect(function(p: Player, data: any)
		if type(data) ~= "table" or not data.firstDiscovery then
			return
		end
		local n = discovered(ProfileService:GetData(p))
		custom(p, "ReactionDiscovered", 1, tostring(data.reactionId), "Total - " .. n)
		onboarding(p, 4)
		if n >= 2 then
			onboarding(p, 5)
		end
	end)
	EvolutionService.StageChanged:Connect(function(p: Player, from: number, to: number)
		if from == 0 and to >= 1 then
			custom(p, "Milestone", 1, "FirstEvolution")
			onboarding(p, 5)
		end
	end)
	ProfileService.ProfileChanged:Connect(function(p: Player)
		local s = states[p]
		local d = ProfileService:GetData(p)
		if not s or not d or not d.expeditions then
			return
		end
		local n = d.expeditions.totalCompleted or 0
		if n > s.expeditions then
			if s.expeditions == 0 then
				custom(p, "Milestone", 1, "FirstExpedition")
			end
			s.expeditions = n
		end
	end)
	EconomyService.TransactionCompleted:Connect(function(p: Player, reason: string, applied: any)
		local c = type(applied) == "table" and applied.currencies and applied.currencies.Credits
		if type(c) ~= "number" or c == 0 or reason == "Dev" then
			return
		end
		if c > 0 then
			economy(p, Enum.AnalyticsEconomyFlowType.Source, c, reason, SOURCE_TYPE[reason] or "Gameplay")
		else
			economy(p, Enum.AnalyticsEconomyFlowType.Sink, -c, reason, SINK_TYPE[reason] or "Gameplay")
		end
	end)
	EconomyService.LevelUp:Connect(function(p: Player, level: number)
		local ok, reward = pcall(Formulas.levelUpReward, level)
		if ok and type(reward) == "number" then
			economy(p, Enum.AnalyticsEconomyFlowType.Source, reward, "LevelUp", "Gameplay")
		end
	end)
	MonetizationService.StoreFunnel:Connect(function(p: Player, step: string, _kind: string?, key: string?)
		if step == "opened" then
			storeStep(p, 1, "StoreOpened", nil)
		elseif step == "prompted" then
			storeStep(p, 2, "PurchasePrompted", key)
		elseif step == "completed" then
			storeStep(p, 3, "PurchaseCompleted", key)
		end
	end)
	-- onboarding step 2: first arrival on the player's own planet (cheap 1 Hz check, only until it happened)
	task.spawn(function()
		while true do
			task.wait(1)
			for p, s in states do
				if not s.steps[2] and p.Parent then
					local ok, onPlanet = pcall(PlanetDataService.IsOnOwnPlanet, PlanetDataService, p)
					if ok and onPlanet then
						onboarding(p, 2)
					end
				end
			end
		end
	end)
	for _, p in Players:GetPlayers() do
		if ProfileService:IsReady(p) and not states[p] then
			local d = ProfileService:GetData(p)
			onLoaded(p, 0, d ~= nil and (d.loginCount or 0) <= 1)
		end
	end
	if isStudio then
		local hook = ServerStorage:FindFirstChild("PF_TelemetryHook") or Instance.new("BindableFunction")
		hook.Name = "PF_TelemetryHook"
		hook.Archivable = false;
		(hook :: BindableFunction).OnInvoke = function(cmd: string)
			if cmd == "log" then
				return table.clone(debugLog)
			elseif cmd == "clear" then
				table.clear(debugLog)
				return true
			elseif cmd == "stats" then
				return { sent = sent, failed = failed }
			end
			return nil
		end
		hook.Parent = ServerStorage
	end
end

return TelemetryService
