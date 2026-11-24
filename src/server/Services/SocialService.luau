--!strict
-- SocialService — owner: Live Gameplay. Lightweight social layer (no trading):
--   * visits: player-initiated warp to another player's planet (CharacterService:WarpTo; never forced)
--   * presence: who is visiting which planet (1 Hz), owner + visitor notifications (throttled)
--   * reactions: Stellar / Wow / Inspiring on other players' planets with abuse protection (SocialRules)
--   * showcase tokens: a showcase view held for a few seconds counts as "viewing" a planet for reactions
-- Public planet data (owner, stage, branch, formations) is already published by PlanetVisualPublisher as slot
-- attributes; nothing private is exposed, nothing is persisted (session-only counts, see INTERFACES §9).
-- Remotes: Social_Action {requestId, action = "react"|"showcase"|"visit"|"mine", slot?, kind?} -> Action_Result;
--          Social_Notify (server -> client). Replication: ReplicatedStorage.PF_Social/Slot_<n> attributes.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.PF_Shared
local EventConfig = require(Shared.Events.EventConfig)
local WorldLayout = require(Shared.Config.WorldLayout)
local Server = script.Parent.Parent
local SocialRules = require(Server.Events.SocialRules)
local RemoteGuard = require(Server.Net.RemoteGuard)
local ProfileService = require(script.Parent.ProfileService)
local PlanetSlotService = require(script.Parent.PlanetSlotService)
local CharacterService = require(script.Parent.CharacterService)
local RiftService = require(script.Parent.RiftService)
local HarvestService = require(script.Parent.HarvestService)

local S = EventConfig.SOCIAL
local SocialService = {}

local st = SocialRules.new()
local folder: Folder = nil :: any
local nodes: { [number]: Configuration } = {}
local notify: RemoteEvent = nil :: any
local joinedAt: { [Player]: number } = {}
local viewing: { [Player]: { slot: number, at: number } } = {}
local presence: { [Player]: number } = {}
local lastOwnerNotify: { [number]: number } = {}
local lastVisitorNotify: { [string]: number } = {}
local lastVisit: { [Player]: number } = {}
local sessionOverride: { [Player]: number } = {} -- Studio hook only

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function send(p: Player, kind: string, data: { [string]: any })
	data.kind = kind
	notify:FireClient(p, data)
end

local function slotAt(pos: Vector3): number?
	local reach = WorldLayout.PLANET_RADIUS + S.presenceExtra
	for slot = 1, WorldLayout.SLOT_COUNT do
		if WorldLayout.isActiveSlot(slot) and (pos - WorldLayout.getSlotCenter(slot)).Magnitude <= reach then
			return slot
		end
	end
	return nil
end

local function validSlot(slot: any): boolean
	return type(slot) == "number" and slot % 1 == 0 and WorldLayout.isActiveSlot(slot)
end

local function publish(slot: number)
	local node = nodes[slot]
	if not node then
		return
	end
	local owner = PlanetSlotService:GetOwner(slot)
	local counts = if owner then SocialRules.countsFor(st, owner.UserId) else nil
	node:SetAttribute("OwnerUserId", if owner then owner.UserId else 0)
	for _, k in S.reactionOrder do
		node:SetAttribute(k, if counts then counts[k] or 0 else 0)
	end
	node:SetAttribute("Total", if counts then counts.total or 0 else 0)
end

local function publishAll()
	for slot in nodes do
		publish(slot)
	end
end

local function inRift(p: Player): boolean
	local ok, run = pcall(RiftService.GetRun, RiftService, p)
	return ok and run ~= nil
end

local function sessionSeconds(p: Player): number
	return sessionOverride[p] or (now() - (joinedAt[p] or now()))
end

----------------------------------------------------------------------------------------------------
-- presence (who is visiting which planet)
local function presenceTick()
	local visitors: { [number]: { string } } = {}
	for _, p in Players:GetPlayers() do
		local c = p.Character
		local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local slot = r and slotAt(r.Position) or nil
		local owner = slot and PlanetSlotService:GetOwner(slot)
		local visiting = if slot and owner and owner ~= p then slot else nil
		if visiting then
			visitors[visiting] = visitors[visiting] or {}
			table.insert(visitors[visiting], p.DisplayName)
		end
		local prev = presence[p]
		if visiting ~= prev then
			presence[p] = visiting :: any
			if visiting and owner then
				local key = p.UserId .. ":" .. owner.UserId
				local t = now()
				if not lastVisitorNotify[key] or t - lastVisitorNotify[key] >= S.visitorNotifyInterval then
					lastVisitorNotify[key] = t
					send(owner, "visitor", { name = p.DisplayName, slot = visiting })
				end
				send(p, "visiting", { slot = visiting, owner = owner.DisplayName })
			end
		end
	end
	for slot, node in nodes do
		local list = visitors[slot] or {}
		node:SetAttribute("Visitors", #list)
		local names = {}
		for i = 1, math.min(3, #list) do
			names[i] = list[i]
		end
		node:SetAttribute("VisitorNames", table.concat(names, ", "))
	end
end

----------------------------------------------------------------------------------------------------
-- actions
function SocialService:React(p: Player, slot: any, kind: any): (boolean, string, any?)
	if not validSlot(slot) then
		return false, "INVALID_PAYLOAD", nil
	end
	local owner = PlanetSlotService:GetOwner(slot)
	local t = now()
	local v = viewing[p]
	local present = presence[p] == slot or (v ~= nil and v.slot == slot and t - v.at >= S.showcaseHold and t - v.at <= S.showcaseValid)
	local ok, code, info = SocialRules.react(st, { userId = p.UserId, sessionSeconds = sessionSeconds(p), accountAge = p.AccountAge }, { ownerId = owner and owner.UserId, present = present }, kind, t)
	if not ok then
		return false, code, nil
	end
	publish(slot)
	if owner then
		local last = lastOwnerNotify[owner.UserId]
		if not last or t - last >= S.ownerNotifyInterval then
			lastOwnerNotify[owner.UserId] = t
			send(owner, "reaction", { name = p.DisplayName, reaction = kind, total = info.counts.total })
		end
	end
	return true, code, { counts = info.counts, mine = kind }
end

function SocialService:Showcase(p: Player, slot: any): (boolean, string, any?)
	if not validSlot(slot) then
		return false, "INVALID_PAYLOAD", nil
	end
	local owner = PlanetSlotService:GetOwner(slot)
	if not owner then
		return false, "NO_OWNER", nil
	end
	viewing[p] = { slot = slot, at = now() }
	local mine = SocialRules.mine(st, p.UserId)[owner.UserId]
	return true, "OK", { counts = SocialRules.countsFor(st, owner.UserId), mine = mine, own = owner == p }
end

function SocialService:Visit(p: Player, slot: any): (boolean, string, any?)
	if not validSlot(slot) then
		return false, "INVALID_PAYLOAD", nil
	end
	if not PlanetSlotService:GetOwner(slot) then
		return false, "NO_OWNER", nil
	end
	if inRift(p) then
		return false, "IN_RIFT", nil
	end
	local okH, operating = pcall(HarvestService.IsOperating, HarvestService, p)
	if okH and operating then
		return false, "HARVESTING", nil
	end
	local t = now()
	if lastVisit[p] and t - lastVisit[p] < S.visitCooldown then
		return false, "COOLDOWN", nil
	end
	lastVisit[p] = t
	local code = CharacterService:WarpTo(p, slot)
	return code == "OK", code, nil
end

function SocialService:GetCounts(slot: number): any
	local owner = PlanetSlotService:GetOwner(slot)
	return owner and SocialRules.countsFor(st, owner.UserId) or nil
end

----------------------------------------------------------------------------------------------------
function SocialService:Init()
	folder = ReplicatedStorage:FindFirstChild("PF_Social") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PF_Social"
		folder.Parent = ReplicatedStorage
	end
	for slot = 1, WorldLayout.SLOT_COUNT do
		if WorldLayout.isActiveSlot(slot) then
			local node = Instance.new("Configuration")
			node.Name = "Slot_" .. slot
			node:SetAttribute("Slot", slot)
			node.Parent = folder
			nodes[slot] = node
		end
	end
	notify = RemoteGuard.getRemote("Social_Notify")
end

function SocialService:Start()
	publishAll()
	for _, p in Players:GetPlayers() do
		joinedAt[p] = now()
	end
	Players.PlayerAdded:Connect(function(p: Player)
		joinedAt[p] = now()
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		SocialRules.forgetOwner(st, p.UserId)
		joinedAt[p], viewing[p], presence[p], lastVisit[p], sessionOverride[p] = nil, nil, nil, nil, nil
		lastOwnerNotify[p.UserId] = nil
		-- visitor-notification throttles involving this player (as visitor or as owner)
		local id = tostring(p.UserId)
		for key in table.clone(lastVisitorNotify) do
			local a, b = string.match(key, "^(%d+):(%d+)$")
			if a == id or b == id then
				lastVisitorNotify[key] = nil
			end
		end
		task.defer(publishAll)
	end)
	PlanetSlotService.SlotAssigned:Connect(function(_p: Player, slot: number)
		publish(slot)
	end)
	PlanetSlotService.SlotReleased:Connect(function(_p: Player, slot: number)
		task.defer(publish, slot)
	end)
	RemoteGuard.bind("Social_Action", function(p: Player, payload: any)
		if not ProfileService:IsReady(p) then
			return false, "NOT_READY"
		end
		local a = payload.action
		if a == "react" then
			return SocialService:React(p, payload.slot, payload.kind)
		elseif a == "showcase" then
			return SocialService:Showcase(p, payload.slot)
		elseif a == "visit" then
			return SocialService:Visit(p, payload.slot)
		elseif a == "mine" then
			local out = {}
			local byOwner = SocialRules.mine(st, p.UserId)
			for slot = 1, WorldLayout.SLOT_COUNT do
				local owner = PlanetSlotService:GetOwner(slot)
				if owner and byOwner[owner.UserId] then
					out[tostring(slot)] = byOwner[owner.UserId]
				end
			end
			return true, "OK", { mine = out }
		end
		return false, "INVALID_PAYLOAD"
	end)
	task.spawn(function()
		while true do
			local ok, err = pcall(presenceTick)
			if not ok then
				warn("[PF][Social] presence tick failed: " .. tostring(err))
			end
			task.wait(1)
		end
	end)
	if RunService:IsStudio() then
		local hook = ServerStorage:FindFirstChild("PF_SocialHook") or Instance.new("BindableFunction")
		hook.Name = "PF_SocialHook"
		hook.Archivable = false;
		(hook :: BindableFunction).OnInvoke = function(cmd: string, a: any, b: any, c: any)
			local p = if typeof(a) == "Instance" and a:IsA("Player") then a else nil
			if cmd == "react" and p then
				return SocialService:React(p, b, c)
			elseif cmd == "showcase" and p then
				return SocialService:Showcase(p, b)
			elseif cmd == "visit" and p then
				return SocialService:Visit(p, b)
			elseif cmd == "session" and p then
				sessionOverride[p] = b
				return true
			elseif cmd == "viewAge" and p then
				local v = viewing[p]
				if v then
					v.at = now() - (b or 0)
				end
				return v ~= nil
			elseif cmd == "presence" then
				local out = {}
				for pl, s in presence do
					out[pl.Name] = s
				end
				return out
			elseif cmd == "rules" then
				return st
			end
			return nil
		end
		hook.Parent = ServerStorage
	end
end

return SocialService
