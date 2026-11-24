--!strict
-- PlanetDataService — owner: Developer B. Authoritative planet-state READ API (the "PlanetDNAService" role).
-- All mutations go through EvolutionService (reactions, branch commits, cosmetics) which calls
-- :NotifyChanged afterwards. Raw setters are Studio/test-only and refused in production.
--
-- Public server API:
--   :GetView(player)              -> EvolutionRules view over the LIVE profile (read only!) | nil
--   :GetPlanetState(player)       -> sanitized deep copy (see :GetPublicState + owned formations, stageAt)
--   :GetPublicState(player)       -> public snapshot consumed by Developer A's PlanetVisualPublisher
--        (PlanetVisualContract.normalize):
--        { v, ownerUserId, ownerName, slot, stage, stageName, branch, theme, dna, seed, rev, revision,
--          formations = { [id] = count } (all owned known formations; the renderer applies dormancy via
--          FormationRegistry.isActive), dormant = { ids }, lastEffect, cosmetics = { Atmosphere?, PlanetRing? } }
--   :GetPlanetStateBySlot(slot)   -> public snapshot of the slot's current owner | nil
--   :CanEdit(player, slot)        -> owner of that slot with a loaded profile
--   :IsOnOwnPlanet(player)        -> boolean, distance (character within the planet's gravity field)
--   .PlanetReady(player, slot, publicState)   once per session when the profile is loaded onto its slot
--   .PlanetChanged(player, slot, info)        after every committed change
--                                             info = { revision, kind = "reaction"|"branch"|"cosmetic"|"dev",
--                                                      transformation? }
--   :NotifyChanged(player, info)  EvolutionService only
--   :_DevSetDna(player, param, value) / :_DevSetFormation(player, id, n)   Studio/test only

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.PF_Shared
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)
local PlanetConfig = require(Shared.Config.PlanetConfig)
local WorldLayout = require(Shared.Config.WorldLayout)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local EvolutionRules = require(Shared.Evolution.EvolutionRules)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local DataEnvironment = require(script.Parent.Parent.Data.DataEnvironment)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)

local PlanetDataService = {}
PlanetDataService.PlanetReady = Signal.new()
PlanetDataService.PlanetChanged = Signal.new()

PlanetDataService.PUBLIC_STATE_VERSION = 1

local lastEffect: { [Player]: string } = {} -- effect id of the last committed transformation (session only)

function PlanetDataService:Init()
	ProfileService.ProfileReleasing:Connect(function(player: Player)
		lastEffect[player] = nil
	end)
	ProfileService.ProfileLoaded:Connect(function(player: Player, slot: number)
		local state = PlanetDataService:GetPublicState(player)
		if state then
			PlanetDataService.PlanetReady:Fire(player, slot, state)
		end
	end)
end

function PlanetDataService:Start() end

function PlanetDataService:GetView(player: Player): any
	local d = ProfileService:GetData(player)
	return d and EvolutionRules.viewFromProfile(d)
end

function PlanetDataService:GetPublicState(player: Player): any
	local d = ProfileService:GetData(player)
	if not d then
		return nil
	end
	local p = d.planet
	local view = EvolutionRules.viewFromProfile(d)
	local formations, dormant = {}, {}
	for _, fid in FormationRegistry.ORDER do
		local rec = p.formations[fid]
		if rec and rec.n > 0 then
			formations[fid] = rec.n
			if not FormationRegistry.isActive(fid, p.branch) then
				table.insert(dormant, fid)
			end
		end
	end
	local branchDef = PlanetConfig.getBranch(p.branch)
	return {
		v = PlanetDataService.PUBLIC_STATE_VERSION,
		ownerUserId = player.UserId,
		ownerName = player.DisplayName,
		slot = PlanetSlotService:GetSlot(player),
		stage = p.stage,
		stageName = EvolutionRules.stageName(p.stage),
		branch = p.branch,
		theme = if branchDef then branchDef.theme else "barren",
		dna = table.clone(p.dna),
		seed = p.seed,
		rev = p.rev,
		revision = p.rev,
		formations = formations,
		dormant = dormant,
		lastEffect = lastEffect[player] or "",
		cosmetics = table.clone(p.cosmetics),
		discovered = EvolutionRules.discoveredCount(view),
	}
end

function PlanetDataService:GetPlanetState(player: Player): any
	local d = ProfileService:GetData(player)
	local pub = self:GetPublicState(player)
	if not d or not pub then
		return nil
	end
	local owned = {}
	for fid, rec in d.planet.formations do
		owned[fid] = rec.n
	end
	pub.ownedFormations = owned
	pub.stageAt = TableUtil.deepCopy(d.planet.stageAt)
	pub.respecs = d.planet.branchLog.respecs
	return pub
end

function PlanetDataService:GetPlanetStateBySlot(slot: number): any
	local owner = PlanetSlotService:GetOwner(slot)
	return owner and self:GetPublicState(owner)
end

function PlanetDataService:CanEdit(player: Player, slot: any): boolean
	return ProfileService:IsReady(player) and PlanetSlotService:IsOwner(player, slot)
end

function PlanetDataService:IsOnOwnPlanet(player: Player): (boolean, number?)
	local slot = PlanetSlotService:GetSlot(player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not slot or not root then
		return false, nil
	end
	local dist = (root.Position - WorldLayout.getSlotCenter(slot)).Magnitude
	return dist <= WorldLayout.PLANET_RADIUS * EvolutionConfig.ACTIONS.ON_PLANET_RADIUS_FACTOR, dist
end

function PlanetDataService:NotifyChanged(player: Player, info: any)
	if info and info.transformation and type(info.transformation.effect) == "string" then
		lastEffect[player] = info.transformation.effect
	end
	ProfileService:MarkChanged(player, "planet")
	self.PlanetChanged:Fire(player, PlanetSlotService:GetSlot(player), info)
end

local function devAllowed(): boolean
	return DataEnvironment.resolve().name ~= "production" and RunService:IsStudio()
end

-- Studio/test only: force a DNA value (bypasses reactions). Refused outside Studio test environments.
function PlanetDataService:_DevSetDna(player: Player, param: string, value: number): (boolean, string)
	local d = ProfileService:GetData(player)
	if not devAllowed() then
		return false, "NOT_ALLOWED"
	end
	if not d then
		return false, "NOT_READY"
	end
	local v = PlanetConfig.clampDna(param, value)
	if v == nil then
		return false, "INVALID_VALUE"
	end
	d.planet.dna[param] = v
	d.planet.rev += 1
	self:NotifyChanged(player, { revision = d.planet.rev, kind = "dev" })
	return true, "OK"
end

function PlanetDataService:_DevSetFormation(player: Player, fid: string, n: number): (boolean, string)
	local d = ProfileService:GetData(player)
	local def = FormationRegistry.get(fid)
	if not devAllowed() then
		return false, "NOT_ALLOWED"
	end
	if not d or not def or type(n) ~= "number" then
		return false, "INVALID"
	end
	n = math.clamp(math.floor(n), 0, def.maxCount)
	if n == 0 then
		d.planet.formations[fid] = nil
	else
		d.planet.formations[fid] = { n = n, t = os.time() }
	end
	d.planet.rev += 1
	self:NotifyChanged(player, { revision = d.planet.rev, kind = "dev" })
	return true, "OK"
end

return PlanetDataService
