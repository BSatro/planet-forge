--!strict
-- ClientDataService — owner: Developer B. Sanitized, read-only profile snapshots for the OWNING client.
-- Remotes:
--   Profile_Snapshot        server -> client   full snapshot (coalesced; at most one per SNAPSHOT_THROTTLE)
--   Profile_RequestSnapshot client -> server   { requestId }  -> re-sends Profile_Snapshot
-- Snapshots are built from a WHITELIST: session/lock metadata, ledgers, retired ids and other players'
-- data are never sent. Clients read them through PF_Shared.Client.ProfileClient (deep-frozen).
--
-- Snapshot (v1): { v, schemaVersion, environment, slot, level, xp, xpToNext, maxLevel,
--   currencies, energyCap, materials, catalysts, upgrades = { [id] = { level, maxLevel, nextCost? } },
--   planet = { dna, branch, stage, formations = {ids} }, discoveries/codex/cosmetics = {ids},
--   expeditions = { totalCompleted, recent }, stats, lastSaveAt }

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.PF_Shared
local TableUtil = require(Shared.Util.TableUtil)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local PlanetConfig = require(Shared.Config.PlanetConfig)
local Formulas = require(Shared.Economy.EconomyFormulas)
local ReactionRegistry = require(Shared.Evolution.ReactionRegistry)
local NetConfig = require(script.Parent.Parent.Config.NetConfig)
local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local EconomyService = require(script.Parent.EconomyService)
local MonetizationData = require(script.Parent.Parent.Monetization.MonetizationData)
local QuestRules = require(Shared.Quests.QuestRules)

local ClientDataService = {}

local snapshotRemote: RemoteEvent
local pending: { [Player]: boolean } = {}

-- purchases as the client may see them (no receipt ledger)
local function monetizationView(mon: any): any
	if type(mon) ~= "table" then
		return { passes = {}, fireworks = 0, presets = {}, presetSlots = 1 }
	end
	local passes = {}
	for key in mon.passes do
		table.insert(passes, key)
	end
	table.sort(passes)
	return { passes = passes, fireworks = mon.fireworks, presets = TableUtil.deepCopy(mon.presets), presetSlots = MonetizationData.presetSlots(mon) }
end

local function copyKnown(map: any, section: string): { [string]: number }
	local out = {}
	for _, id in ItemCatalog.ids(section) do
		out[id] = map[id] or 0
	end
	return out
end

local function knownSet(map: any, section: string): { string }
	local out = {}
	for _, id in ItemCatalog.ids(section) do
		if map[id] ~= nil then
			table.insert(out, id)
		end
	end
	return out
end

-- Known formations only: { [id] = count }
local function formationCounts(map: any): { [string]: number }
	local out = {}
	for _, id in ItemCatalog.ids("formations") do
		local rec = map[id]
		if type(rec) == "table" and rec.n and rec.n > 0 then
			out[id] = rec.n
		end
	end
	return out
end

-- Reaction Codex for the UI: { [reactionId] = { n = completions, d = discoveredAt, m = masteredAt? } }
local function reactionCodex(map: any): any
	local out = {}
	for _, id in ReactionRegistry.ORDER do
		local rec = map[id]
		if rec and rec.d then
			out[id] = { n = rec.n, d = rec.d, m = rec.m }
		end
	end
	return out
end

function ClientDataService:BuildSnapshot(player: Player): any
	local d = ProfileService:GetData(player)
	if not d then
		return nil
	end
	local upgrades = {}
	for id, def in EconomyConfig.UPGRADES do
		local lvl = d.upgrades[id] or 0
		upgrades[id] = { level = lvl, maxLevel = def.maxLevel, minPlayerLevel = def.minPlayerLevel or 1, nextCost = Formulas.upgradeCost(id, lvl) }
	end
	local dna = {}
	for id in PlanetConfig.DNA_PARAMS do
		dna[id] = d.planet.dna[id]
	end
	local history = d.expeditions.history
	local recent = {}
	for i = math.max(1, #history - NetConfig.SNAPSHOT_RECENT_EXPEDITIONS + 1), #history do
		table.insert(recent, TableUtil.deepCopy(history[i]))
	end
	return {
		v = NetConfig.SNAPSHOT_VERSION,
		schemaVersion = d.schemaVersion,
		environment = ProfileService:GetEnvironment().name,
		slot = PlanetSlotService:GetSlot(player),
		level = d.level,
		xp = d.xp,
		xpToNext = Formulas.xpToNext(d.level),
		maxLevel = EconomyConfig.LEVEL.MAX_LEVEL,
		currencies = copyKnown(d.currencies, "currencies"),
		energyCap = EconomyService:GetEnergyCap(player),
		materials = copyKnown(d.materials, "materials"),
		catalysts = copyKnown(d.catalysts, "catalysts"),
		upgrades = upgrades,
		planet = {
			dna = dna,
			branch = d.planet.branch,
			stage = d.planet.stage,
			formations = knownSet(d.planet.formations, "formations"),
			formationCounts = formationCounts(d.planet.formations),
			seed = d.planet.seed,
			revision = d.planet.rev,
			cosmetics = table.clone(d.planet.cosmetics),
			stageAt = table.clone(d.planet.stageAt),
			respecs = d.planet.branchLog.respecs,
		},
		reactions = reactionCodex(d.reactions),
		discoveries = knownSet(d.discoveries, "discoveries"),
		codex = knownSet(d.codex, "codex"),
		cosmetics = knownSet(d.cosmetics, "cosmetics"),
		monetization = monetizationView(d.monetization),
		expeditions = { totalCompleted = d.expeditions.totalCompleted, recent = recent },
		stats = table.clone(d.stats),
		quests = QuestRules.view(d.quests, os.time()), -- daily/weekly quests view (INTERFACES §11), never the raw state
		lastSaveAt = d.lastSaveAt,
		loginCount = d.loginCount, -- read-only (First 10 Minutes 2.0: the welcome intro plays in the first session only)
	}
end

function ClientDataService:PushNow(player: Player)
	local snap = self:BuildSnapshot(player)
	if snap and player.Parent then
		snapshotRemote:FireClient(player, snap)
	end
end

function ClientDataService:SchedulePush(player: Player)
	if pending[player] then
		return
	end
	pending[player] = true
	task.delay(NetConfig.SNAPSHOT_THROTTLE, function()
		pending[player] = nil
		ClientDataService:PushNow(player)
	end)
end

function ClientDataService:Init()
	snapshotRemote = RemoteGuard.getRemote("Profile_Snapshot")
	ProfileService.ProfileChanged:Connect(function(player: Player)
		ClientDataService:SchedulePush(player)
	end)
end

function ClientDataService:Start()
	RemoteGuard.bind("Profile_RequestSnapshot", function(player)
		if not ProfileService:IsReady(player) then
			return false, "NOT_READY"
		end
		ClientDataService:SchedulePush(player)
		return true, "OK"
	end)
end

return ClientDataService
