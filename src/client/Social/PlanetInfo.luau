--!strict
-- PlanetInfo — owner: Live Gameplay (client). Read-only public view of every claimed planet for the social UI:
-- owner, stage, branch, DNA and discovered formations come from the PUBLIC slot attributes published by
-- PlanetVisualPublisher (nothing private); reactions and visitors from ReplicatedStorage.PF_Social. Actions
-- (react / visit / showcase token) go through Social_Action and are validated by SocialService.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.PF_Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local EvolutionConfig = require(Shared.Config.EvolutionConfig)
local PlanetConfig = require(Shared.Config.PlanetConfig)
local FormationRegistry = require(Shared.Evolution.FormationRegistry)
local EventConfig = require(Shared.Events.EventConfig)
local ProfileClient = require(Shared.Client.ProfileClient)

local player = Players.LocalPlayer
local PlanetInfo = {}
local mine: { [number]: string } = {}

local REASONS: { [string]: string } = {
	OWN_PLANET = "You can't react to your own planet.",
	TOO_SOON = "Explore a little first — reactions unlock after 30 seconds on this server.",
	ACCOUNT_TOO_NEW = "Reactions need an account older than one day.",
	NOT_VIEWING = "Visit the planet or keep the showcase open for a few seconds first.",
	ALREADY = "You already gave this reaction.",
	COOLDOWN = "You can change your reaction in a few seconds.",
	NO_OWNER = "Nobody owns that planet right now.",
	IN_RIFT = "Finish your rift first.",
	HARVESTING = "Leave the harvester first.",
	RATE_LIMITED = "Slow down a little.",
}

function PlanetInfo.reasonText(code: string?): string
	return REASONS[code or ""] or tostring(code)
end

local function slotModel(slot: number): Instance?
	local w = Workspace:FindFirstChild("PF_World")
	local p = w and w:FindFirstChild("Planets")
	return p and p:FindFirstChild("Slot_" .. slot)
end

local function socialNode(slot: number): Instance?
	local f = ReplicatedStorage:FindFirstChild("PF_Social")
	return f and f:FindFirstChild("Slot_" .. slot)
end

local function parseFormations(s: any): { any }
	local out = {}
	if type(s) ~= "string" then
		return out
	end
	for item in string.gmatch(s, "[^,]+") do
		local id, n = string.match(item, "^%s*([%w_]+):(%d+)%s*$")
		if not id then
			id = string.match(item, "^%s*([%w_]+)%s*$")
			n = "1"
		end
		local def = id and FormationRegistry.DEFS[id]
		if id and tonumber(n) and (tonumber(n) :: number) > 0 then
			table.insert(out, { id = id, name = def and def.displayName or id, count = tonumber(n), color = def and def.color or Color3.fromRGB(160, 170, 200), landmark = def and def.landmark == true, tier = def and def.tier or 0 })
		end
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then
			return a.tier > b.tier
		end
		return a.name < b.name
	end)
	return out
end

function PlanetInfo.get(slot: number): any
	local m = slotModel(slot)
	if not m then
		return nil
	end
	local owner = m:GetAttribute("PFOwnerUserId") or 0
	if owner == 0 then
		return nil
	end
	local stage = m:GetAttribute("PFStage") or 0
	local branch = m:GetAttribute("PFBranch") or "None"
	local bdef = PlanetConfig.BRANCHES[branch]
	local sdef = EvolutionConfig.STAGES[stage]
	local node = socialNode(slot)
	local forms = parseFormations(m:GetAttribute("PFFormations"))
	local total = 0
	for _, f in forms do
		total += f.count
	end
	local reactions: any = { total = node and node:GetAttribute("Total") or 0 }
	for _, k in EventConfig.SOCIAL.reactionOrder do
		reactions[k] = node and node:GetAttribute(k) or 0
	end
	return {
		slot = slot,
		ownerUserId = owner,
		ownerName = m:GetAttribute("PFOwnerName") or "Explorer",
		own = owner == player.UserId,
		stage = stage,
		stageName = sdef and sdef.name or ("Stage " .. stage),
		branch = branch,
		-- "None" exists in PlanetConfig.BRANCHES without a colour/name: always fall back
		branchName = if bdef and type(bdef.displayName) == "string" and branch ~= "None" then bdef.displayName else "Unspecialized",
		branchColor = if bdef and typeof(bdef.color) == "Color3" and branch ~= "None" then bdef.color else Color3.fromRGB(150, 160, 190),
		theme = m:GetAttribute("PFTheme") or "barren",
		formations = forms,
		formationCount = total,
		dna = { Temperature = m:GetAttribute("PFDna_Temperature") or 0, Water = m:GetAttribute("PFDna_Water") or 0, Life = m:GetAttribute("PFDna_Life") or 0, CosmicEnergy = m:GetAttribute("PFDna_CosmicEnergy") or 0 },
		reactions = reactions,
		visitors = node and node:GetAttribute("Visitors") or 0,
		visitorNames = node and node:GetAttribute("VisitorNames") or "",
		center = WorldLayout.getSlotCenter(slot),
		radius = m:GetAttribute("PFRadius") or WorldLayout.PLANET_RADIUS,
		mine = mine[slot],
	}
end

-- Claimed planets, the local player's first, then by slot.
function PlanetInfo.list(): { any }
	local out = {}
	for slot = 1, WorldLayout.SLOT_COUNT do
		if WorldLayout.isActiveSlot(slot) then
			local info = PlanetInfo.get(slot)
			if info then
				table.insert(out, info)
			end
		end
	end
	table.sort(out, function(a, b)
		if a.own ~= b.own then
			return a.own
		end
		return a.slot < b.slot
	end)
	return out
end

-- Which planet the local character is on (or nil).
function PlanetInfo.currentSlot(): number?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not r then
		return nil
	end
	for slot = 1, WorldLayout.SLOT_COUNT do
		if WorldLayout.isActiveSlot(slot) and (r.Position - WorldLayout.getSlotCenter(slot)).Magnitude <= WorldLayout.PLANET_RADIUS + EventConfig.SOCIAL.presenceExtra then
			return slot
		end
	end
	return nil
end

local function request(action: string, payload: { [string]: any }): (boolean, string, any)
	payload.action = action
	local ok, code, data = ProfileClient.request("Social_Action", payload)
	return ok == true, tostring(code), data
end

function PlanetInfo.react(slot: number, kind: string): (boolean, string, any)
	local ok, code, data = request("react", { slot = slot, kind = kind })
	if ok then
		mine[slot] = kind
	end
	return ok, code, data
end

function PlanetInfo.visit(slot: number): (boolean, string)
	local ok, code = request("visit", { slot = slot })
	return ok, code
end

function PlanetInfo.showcaseToken(slot: number): (boolean, string, any)
	local ok, code, data = request("showcase", { slot = slot })
	if ok and type(data) == "table" then
		mine[slot] = data.mine
	end
	return ok, code, data
end

function PlanetInfo.refreshMine()
	local ok, _, data = request("mine", {})
	if ok and type(data) == "table" and type(data.mine) == "table" then
		table.clear(mine)
		for k, v in data.mine do
			local s = tonumber(k)
			if s then
				mine[s] = v
			end
		end
	end
end

return PlanetInfo
