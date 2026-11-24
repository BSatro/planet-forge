--!strict
-- DevCommandService — owner: Developer B. Developer test commands, TEST ENVIRONMENTS ONLY.
--   * Disabled (and the Dev_Command remote is never created) when the data environment is "production"
--     or DevConfig.ENABLED is false.
--   * 2026-11-22 (release blockers): on LIVE servers they also need the universe to be listed in
--     DataConfig.TEST_UNIVERSE_IDS (the private test experience). An unlisted live universe — e.g. the real game
--     before production is activated — never gets developer commands. Pure decision: DevCommandService.decideEnabled.
--   * Authorized: every player in Studio; in a live TEST experience only DevConfig.DEV_USER_IDS and
--     (if ALLOW_EXPERIENCE_OWNER) the owning user.
--   * Grants still go through EconomyService (reason "Dev") and are bounded by DevConfig.MAX_GRANT.
-- Usage: remote Dev_Command { requestId, command, args = {...} }, or server-side :Run(player, cmd, args).
-- Commands: help | env | snapshot | slots | ledger | save | reset
--           grant {section,id,amount} | xp {amount} | setlevel {level} | harvest {materialId,multiplier?}
--           sell {materialId,amount} | upgrade {upgradeId} | dna {paramId,value} | branch {branchId}
--           unlock {section,id} | discover {id} | failnext {count}  (mock store only)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.PF_Shared.Config.EconomyConfig)
local DevConfig = require(script.Parent.Parent.Config.DevConfig)
local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local DataEnvironment = require(script.Parent.Parent.Data.DataEnvironment)
local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)
local PlanetDataService = require(script.Parent.PlanetDataService)
local ClientDataService = require(script.Parent.ClientDataService)
local EvolutionService = require(script.Parent.EvolutionService)

local DevCommandService = {}

local enabled = false

function DevCommandService.isEnabled(): boolean
	return enabled
end

function DevCommandService.isAuthorized(player: Player): boolean
	if not enabled then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if table.find(DevConfig.DEV_USER_IDS, player.UserId) then
		return true
	end
	return DevConfig.ALLOW_EXPERIENCE_OWNER and game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

local function arg(args: any, k: string): any
	return if type(args) == "table" then args[k] else nil
end

local COMMANDS: { [string]: (Player, any) -> (boolean, string, any?) } = {}

COMMANDS.help = function()
	local names = {}
	for k in COMMANDS do
		table.insert(names, k)
	end
	table.sort(names)
	return true, "OK", names
end

COMMANDS.env = function()
	return true, "OK", ProfileService:GetEnvironment()
end

COMMANDS.snapshot = function(player)
	return true, "OK", ClientDataService:BuildSnapshot(player)
end

COMMANDS.slots = function()
	return true, "OK", { occupancy = PlanetSlotService:GetOccupancy(), free = PlanetSlotService:GetFreeCount() }
end

COMMANDS.ledger = function(player)
	return true, "OK", EconomyService:GetLedger(player)
end

COMMANDS.save = function(player)
	local ok, code = ProfileService:SaveNow(player)
	return ok, code
end

COMMANDS.reset = function(player)
	local ok = ProfileService:_ResetData(player)
	return ok, if ok then "OK" else "NOT_ALLOWED"
end

COMMANDS.grant = function(player, args)
	local amount = arg(args, "amount")
	if not RemoteGuard.isPositiveInt(amount, DevConfig.MAX_GRANT) then
		return false, "INVALID_AMOUNT"
	end
	return EconomyService:Grant(player, arg(args, "section"), arg(args, "id"), amount, "Dev")
end

COMMANDS.xp = function(player, args)
	return EconomyService:GrantXp(player, arg(args, "amount"), "Dev")
end

COMMANDS.setlevel = function(player, args)
	local level = arg(args, "level")
	if not RemoteGuard.isInt(level, 1, EconomyConfig.LEVEL.MAX_LEVEL) then
		return false, "INVALID_AMOUNT"
	end
	local d = ProfileService:GetData(player)
	if not d then
		return false, "NOT_READY"
	end
	d.level, d.xp = level, 0
	ProfileService:MarkChanged(player, "level")
	return true, "OK"
end

COMMANDS.harvest = function(player, args)
	return EconomyService:RewardHarvest(player, arg(args, "materialId"), arg(args, "multiplier"))
end

COMMANDS.sell = function(player, args)
	return EconomyService:SellMaterial(player, arg(args, "materialId"), arg(args, "amount"))
end

COMMANDS.upgrade = function(player, args)
	return EconomyService:PurchaseUpgrade(player, arg(args, "upgradeId"))
end

COMMANDS.dna = function(player, args)
	return PlanetDataService:_DevSetDna(player, arg(args, "paramId"), arg(args, "value"))
end

COMMANDS.branch = function(player, args)
	return EvolutionService:CommitBranch(player, arg(args, "branchId"), { confirm = true, bypassLocation = arg(args, "bypassLocation") ~= false })
end

-- Evolution (test environments): a real reaction through the full transaction path. bypassLocation
-- defaults to true so tests don't need to walk to the planet; pass false to test the location rule.
COMMANDS.react = function(player, args)
	return EvolutionService:React(player, arg(args, "reactionId"), {
		actionId = arg(args, "actionId"),
		expectedRevision = arg(args, "expectedRevision"),
		slot = arg(args, "slot"),
		bypassLocation = arg(args, "bypassLocation") ~= false,
	})
end

COMMANDS.evo = function(player)
	return true, "OK", { planet = PlanetDataService:GetPlanetState(player), previews = EvolutionService:GetPreviews(player) }
end

COMMANDS.formation = function(player, args)
	return PlanetDataService:_DevSetFormation(player, arg(args, "id"), arg(args, "n"))
end

COMMANDS.cosmetic = function(player, args)
	return EvolutionService:SetCosmetic(player, arg(args, "category"), arg(args, "cosmeticId"))
end

COMMANDS.unlock = function(player, args)
	return InventoryService:Unlock(player, arg(args, "section"), arg(args, "id"))
end

COMMANDS.discover = function(player, args)
	return InventoryService:RecordDiscovery(player, arg(args, "id"))
end

COMMANDS.has = function(player, args)
	return true, "OK", InventoryService:HasUnlock(player, arg(args, "section"), arg(args, "id"))
end

COMMANDS.consume = function(player, args)
	return InventoryService:ConsumeCatalyst(player, arg(args, "id"), arg(args, "count"), "Dev")
end

COMMANDS.expedition = function(player, args)
	return InventoryService:RecordExpedition(player, { expeditionId = arg(args, "expeditionId"), outcome = arg(args, "outcome") })
end

COMMANDS.canedit = function(player, args)
	return true, "OK", PlanetDataService:CanEdit(player, arg(args, "slot"))
end

COMMANDS.planet = function(player)
	return true, "OK", PlanetDataService:GetPlanetState(player)
end

COMMANDS.failnext = function(_player, args)
	local backend = ProfileService:_GetBackend()
	if not backend or backend.kind ~= "mock" then
		return false, "MOCK_ONLY"
	end
	local n = arg(args, "count")
	if not RemoteGuard.isInt(n, 0, DevConfig.MAX_FAIL_INJECT) then
		return false, "INVALID_AMOUNT"
	end
	backend:FailNext(n)
	return true, "OK"
end

-- Server-side entry (also used by MCP/Studio tests). Returns ok, code, data.
function DevCommandService:Run(player: Player, command: any, args: any): (boolean, string, any?)
	if not DevCommandService.isAuthorized(player) then
		return false, "NOT_AUTHORIZED"
	end
	local fn = type(command) == "string" and COMMANDS[string.lower(command)]
	if not fn then
		return false, "UNKNOWN_COMMAND"
	end
	local ok, a, b, c = pcall(fn, player, args)
	if not ok then
		warn("[PF][Dev] command error: " .. tostring(a))
		return false, "INTERNAL_ERROR"
	end
	print(string.format("[PF][Dev] %s ran %s -> %s", player.Name, tostring(command), tostring(b)))
	return a, b, c
end

-- Pure (D1.spec): may developer commands exist on this server?
function DevCommandService.decideEnabled(envName: string, isStudio: boolean, universeId: number, devCfg: any?, dataCfg: any?): boolean
	local dv = devCfg or DevConfig
	local dc = dataCfg or DataConfig
	if not dv.ENABLED or envName == "production" or table.find(dc.PRODUCTION_UNIVERSE_IDS, universeId) then
		return false
	end
	if isStudio then
		return true
	end
	return table.find(dc.TEST_UNIVERSE_IDS, universeId) ~= nil and universeId ~= dc.PRODUCTION_UNIVERSE_ID_PENDING
end

function DevCommandService:Init()
	local env = DataEnvironment.resolve()
	enabled = DevCommandService.decideEnabled(env.name, RunService:IsStudio(), game.GameId)
	if not enabled and not RunService:IsStudio() and env.name ~= "production" then
		print("[PF][Dev] developer commands OFF: universe " .. game.GameId .. " is not listed in DataConfig.TEST_UNIVERSE_IDS")
	end
end

function DevCommandService:Start()
	if not enabled then
		return
	end
	RemoteGuard.bind("Dev_Command", function(player, p)
		if not DevCommandService.isAuthorized(player) then
			return false, "NOT_AUTHORIZED"
		end
		return DevCommandService:Run(player, p.command, p.args)
	end)
	print("[PF][Dev] developer commands ENABLED (environment is not production)")
	-- Studio-only server-side hook for automated tests (MCP / command bar run in a separate VM).
	-- Lives in ServerStorage: clients cannot see or invoke it.
	if RunService:IsStudio() then
		local ServerStorage = game:GetService("ServerStorage")
		local hook = ServerStorage:FindFirstChild("PF_DevHook") :: BindableFunction?
		if not hook then
			hook = Instance.new("BindableFunction")
			;(hook :: BindableFunction).Name = "PF_DevHook"
			;(hook :: BindableFunction).Archivable = false
			;(hook :: BindableFunction).Parent = ServerStorage
		end
		;(hook :: BindableFunction).OnInvoke = function(userId: number, command: string, args: any)
			local player = game:GetService("Players"):GetPlayerByUserId(userId)
			if not player then
				return false, "NO_PLAYER"
			end
			return DevCommandService:Run(player, command, args)
		end
	end
end

return DevCommandService
