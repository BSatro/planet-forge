--!strict
-- PF server boot (Joint). Init all (no yields, no cross-calls) -> Start all. One failing service
-- is reported and does not block the others.

local Services = script.Parent.Services

-- Backend services (Developer B) connect cross-service signal listeners in Init (no calls, no yields);
-- ProfileService defers handling of already-present players until every Start has run.
local ORDER = {
	"WorldService",
	"CharacterService",
	"PlanetSlotService",
	"ProfileService",
	"EconomyService",
	"InventoryService",
	"PlanetDataService",
	"EvolutionService", -- Developer B: Planet DNA reactions, stages, branches, Codex
	"PlanetVisualAdapter", -- Developer B: once-only transformation events (no attribute writes)
	"PlanetVisualPublisher", -- Developer A: public visual state of every planet (reads PlanetDataService)
	"ClientDataService",
	"DevCommandService",
	"HarvestService", -- Gameplay: Cosmic Core Hunt
	"RiftService", -- Mission Systems: Cosmic Rifts expeditions (uses CharacterService, EconomyService, InventoryService)
	"WorldEventService", -- Live Gameplay: Cosmic World Events (Meteor Shower, Solar Storm, Cosmic Convergence)
	"SocialService", -- Live Gameplay: planet visits, presence, reactions, showcase tokens
	"MonetizationService", -- Monetization: game passes, the single ProcessReceipt handler, store actions
	"QuestService", -- Live Gameplay: daily + weekly quests (progress from server events, rewards via EconomyService)
	"TelemetryService", -- Release / Live Ops: AnalyticsService funnels and milestones (server-only, no PII)
}

local loaded: { [string]: any } = {}
for _, name in ORDER do
	local ok, mod = pcall(require, Services:WaitForChild(name))
	if ok then
		loaded[name] = mod
	else
		warn("[PF] require failed:", name, mod)
	end
end
for _, name in ORDER do
	local s = loaded[name]
	if s and s.Init then
		local ok, err = pcall(s.Init, s)
		if not ok then
			warn("[PF] Init failed:", name, err)
			loaded[name] = nil
		end
	end
end
for _, name in ORDER do
	local s = loaded[name]
	if s and s.Start then
		task.spawn(function()
			local ok, err = pcall(s.Start, s)
			if not ok then
				warn("[PF] Start failed:", name, err)
			end
		end)
	end
end
print("[PF] server booted")
