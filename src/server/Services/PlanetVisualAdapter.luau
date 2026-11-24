--!strict
-- PlanetVisualAdapter — owner: Developer B. Bridges authoritative evolution events to clients.
--
-- Planet APPEARANCE is published by Developer A's PlanetVisualPublisher (attributes of
-- Workspace.PF_World.Planets.Slot_n per PlanetVisualContract) from PlanetDataService:GetPlanetState(), and
-- rendered by A's PlanetVisualController / PlanetDecorator (FormationRegistry archetypes, deterministic
-- placement, LOD, stage-up cinematic). This adapter writes none of A's contract attributes (single producer,
-- no races). It only owns two separate presentation attributes on the same slot model:
--   PFCosAtmosphere, PFCosRing = equipped planet cosmetic ids ("" = none), rendered client-side by
--   PF_Client.Store.CosmeticsFX (premium + earned atmospheres and rings).
--
-- It adds the one thing the attribute contract cannot express: discrete, once-only transformation events.
--   RemoteEvent PF_Remotes.Planet_Transformation (server -> all clients, reliable)
--     { slot, ownerUserId, revision, transformation = { id, kind = "reaction"|"branch", reactionId?, effect,
--       formations = { ids }, stageFrom, stageTo, newStages, branch, branchFrom? } }
--   * fired once per committed milestone (first discovery, new formation instance, stage change, branch
--     commit); never replayed on reconnect (late joiners rebuild from attributes only)
--   * purely cosmetic: grants nothing; clients choose full / cheap / no effect by distance + motion setting
--   * consumers: PF_Client.Evolution.TransformationFX (Developer B, overlay FX + owner feedback);
--     Developer A may also listen to theme a cinematic per `effect`.

local RemoteGuard = require(script.Parent.Parent.Net.RemoteGuard)
local PlanetDataService = require(script.Parent.PlanetDataService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local WorldService = require(script.Parent.WorldService)

local PlanetVisualAdapter = {}

local transformationRemote: RemoteEvent
local sent = 0

local function publishCosmetics(slot: number?, cosmetics: any)
	if type(slot) ~= "number" then
		return
	end
	local ok, model = pcall(WorldService.GetSlotModel, WorldService, slot)
	if not ok or not model then
		return
	end
	local c = cosmetics or {}
	model:SetAttribute("PFCosAtmosphere", if type(c.Atmosphere) == "string" then c.Atmosphere else "")
	model:SetAttribute("PFCosRing", if type(c.PlanetRing) == "string" then c.PlanetRing else "")
end

function PlanetVisualAdapter:Init()
	transformationRemote = RemoteGuard.getRemote("Planet_Transformation")
	PlanetDataService.PlanetReady:Connect(function(_player: Player, slot: number, state: any)
		publishCosmetics(slot, state and state.cosmetics)
	end)
	PlanetDataService.PlanetChanged:Connect(function(player: Player, slot: number?)
		local state = PlanetDataService:GetPublicState(player)
		publishCosmetics(slot, state and state.cosmetics)
	end)
	PlanetSlotService.SlotReleased:Connect(function(_player: Player, slot: number)
		publishCosmetics(slot, nil)
	end)
	PlanetDataService.PlanetChanged:Connect(function(player: Player, slot: number?, info: any)
		if slot and info and info.transformation then
			sent += 1
			transformationRemote:FireAllClients({
				slot = slot,
				ownerUserId = player.UserId,
				revision = info.revision,
				transformation = info.transformation,
			})
		end
	end)
end

function PlanetVisualAdapter:Start() end

-- diagnostics (tests / performance checks)
function PlanetVisualAdapter:GetSentCount(): number
	return sent
end

return PlanetVisualAdapter
