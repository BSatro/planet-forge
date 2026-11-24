--!strict
-- EventClient — owner: Live Gameplay (client). Read-only view of COSMIC WORLD EVENTS for every client system
-- (HUD, panels, effects, capture input). Sources: ReplicatedStorage.PF_WorldEvents attributes (phases, timers,
-- event state — available to late joiners immediately), Event_Notify (feedback), Event_Action (capture / sync).
-- No authority lives here: the server decides phases, meteors, captures and every reward.
--
--   EventClient.list() -> { EventView }            EventClient.get(eventId) -> EventView?
--   EventClient.meteors() -> { [id]: Meteor }      EventClient.mine() -> { capturesLeft?, surgesLeft?, points?, carrying? }
--   EventClient.isBoosted(reactionId) -> boolean   EventClient.capture(id) -> ok, code, data   (yields)
--   Signals: Changed(eventId?), PhaseChanged(eventId, phase, prev), Notified(msg), MeteorsAdded({Meteor}),
--            MeteorsRemoved({id}, byUserId?, pos?)
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PF_Shared")
local Signal = require(Shared.Util.Signal)
local EventConfig = require(Shared.Events.EventConfig)
local ShowerMath = require(Shared.Events.ShowerMath)
local ProfileClient = require(Shared.Client.ProfileClient)

local player = Players.LocalPlayer
local EventClient = {}
EventClient.Changed = Signal.new()
EventClient.PhaseChanged = Signal.new()
EventClient.Notified = Signal.new()
EventClient.MeteorsAdded = Signal.new()
EventClient.MeteorsRemoved = Signal.new()

export type EventView = {
	eventId: string,
	instanceId: string,
	name: string,
	def: any,
	phase: string,
	phaseEndsAt: number,
	activeAt: number,
	endsAt: number,
	outcome: string,
	attrs: { [string]: any },
}

local folder: Folder? = nil
local phases: { [string]: string } = {}
local meteors: { [string]: ShowerMath.Meteor } = {}
local mine: { [string]: any } = {}
local started = false

function EventClient.serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function view(node: Instance): EventView?
	local id = node:GetAttribute("EventId")
	if type(id) ~= "string" then
		return nil
	end
	return {
		eventId = id,
		instanceId = node:GetAttribute("InstanceId") or "",
		name = node:GetAttribute("Name") or id,
		def = EventConfig.get(id),
		phase = node:GetAttribute("Phase") or "incoming",
		phaseEndsAt = node:GetAttribute("PhaseEndsAt") or 0,
		activeAt = node:GetAttribute("ActiveAt") or 0,
		endsAt = node:GetAttribute("EndsAt") or 0,
		outcome = node:GetAttribute("Outcome") or "",
		attrs = node:GetAttributes(),
	}
end

function EventClient.get(eventId: string): EventView?
	local node = folder and folder:FindFirstChild(eventId)
	return node and view(node) or nil
end

function EventClient.list(): { EventView }
	local out = {}
	for _, id in EventConfig.ORDER do
		local v = EventClient.get(id)
		if v then
			table.insert(out, v)
		end
	end
	return out
end

function EventClient.isActive(eventId: string): boolean
	local v = EventClient.get(eventId)
	return v ~= nil and v.phase == "active"
end

function EventClient.isBoosted(reactionId: string): boolean
	local v = EventClient.get("SolarStorm")
	if not v or v.phase ~= "active" then
		return false
	end
	local list = v.attrs.Boosted
	return type(list) == "string" and table.find(string.split(list, ","), reactionId) ~= nil
end

function EventClient.meteors(): { [string]: ShowerMath.Meteor }
	return meteors
end

function EventClient.mine(): { [string]: any }
	return mine
end

function EventClient.testMode(): boolean
	return folder ~= nil and folder:GetAttribute("TestMode") == true
end

local function clearMeteors()
	local ids = {}
	for id in meteors do
		table.insert(ids, id)
	end
	table.clear(meteors)
	if #ids > 0 then
		EventClient.MeteorsRemoved:Fire(ids, nil, nil)
	end
end

local function addMeteors(list: { any })
	local added = {}
	local t = EventClient.serverNow()
	for _, e in list do
		local m = ShowerMath.decode(e)
		if m and not meteors[m.id] and t <= m.t0 + m.life then
			meteors[m.id] = m
			table.insert(added, m)
		end
	end
	if #added > 0 then
		EventClient.MeteorsAdded:Fire(added)
	end
end

-- Expire meteors locally (their life is deterministic; the server does not broadcast expiry).
function EventClient.expire()
	local t = EventClient.serverNow()
	local ids = {}
	for id, m in meteors do
		if t > m.t0 + m.life then
			meteors[id] = nil
			table.insert(ids, id)
		end
	end
	if #ids > 0 then
		EventClient.MeteorsRemoved:Fire(ids, nil, nil)
	end
end

function EventClient.request(action: string, payload: { [string]: any }?): (boolean, string, any)
	local p = payload or {}
	p.action = action
	local ok, code, data = ProfileClient.request("Event_Action", p)
	return ok == true, tostring(code), data
end

function EventClient.capture(id: string): (boolean, string, any)
	local ok, code, data = EventClient.request("capture", { id = id })
	if ok and type(data) == "table" then
		mine.capturesLeft = data.left
		if meteors[id] then
			meteors[id] = nil
			EventClient.MeteorsRemoved:Fire({ id }, player.UserId, data.pos)
		end
	elseif code == "TAKEN" or code == "EXPIRED" or code == "NOT_FOUND" then
		if meteors[id] then
			meteors[id] = nil
			EventClient.MeteorsRemoved:Fire({ id }, nil, nil)
		end
	elseif code == "CAP_REACHED" then
		mine.capturesLeft = 0
	end
	return ok, code, data
end

function EventClient.sync()
	task.spawn(function()
		local ok, _, data = EventClient.request("sync")
		if ok and type(data) == "table" then
			for k, v in data.mine or {} do
				mine[k] = v
			end
			if data.meteors then
				addMeteors(data.meteors)
			end
			EventClient.Changed:Fire(nil)
		end
	end)
end

local function watchNode(node: Instance)
	local id = node:GetAttribute("EventId")
	if type(id) ~= "string" then
		return
	end
	local function onChange()
		local ph = node:GetAttribute("Phase")
		local prev = phases[id]
		if ph ~= prev then
			phases[id] = ph
			if id == "MeteorShower" and ph ~= "active" then
				clearMeteors()
			end
			if ph == "active" and prev ~= nil then
				-- a new phase: reset the personal counters of this event
				if id == "MeteorShower" then
					mine.capturesLeft = node:GetAttribute("CapturePerPlayer")
				elseif id == "SolarStorm" then
					mine.surgesLeft = node:GetAttribute("MaxSurges")
				elseif id == "CosmicConvergence" then
					mine.points = 0
				end
			end
			EventClient.PhaseChanged:Fire(id, ph, prev)
		end
		EventClient.Changed:Fire(id)
	end
	node.AttributeChanged:Connect(onChange)
	onChange()
end

local function onNotify(msg: any)
	if type(msg) ~= "table" then
		return
	end
	local k = msg.kind
	if k == "meteors" and type(msg.add) == "table" then
		addMeteors(msg.add)
		return -- high frequency: not forwarded to Notified
	elseif k == "gone" and type(msg.ids) == "table" then
		local ids = {}
		for _, id in msg.ids do
			if meteors[id] then
				meteors[id] = nil
				table.insert(ids, id)
			end
		end
		if #ids > 0 then
			EventClient.MeteorsRemoved:Fire(ids, msg.by, msg.pos)
		end
		return
	elseif k == "surge" then
		mine.surgesLeft = msg.left
	elseif k == "surgeCap" then
		mine.surgesLeft = 0
	elseif k == "task" and type(msg.total) == "number" then
		mine.points = msg.total
	end
	EventClient.Notified:Fire(msg)
end

function EventClient.init()
	if started then
		return
	end
	started = true
	local f = ReplicatedStorage:WaitForChild("PF_WorldEvents", 30) :: Folder?
	local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 30)
	local n = remotes and remotes:WaitForChild("Event_Notify", 30) :: RemoteEvent?
	if not f or not n then
		warn("[PF][Events] world events unavailable on this server")
		return
	end
	folder = f
	n.OnClientEvent:Connect(onNotify)
	for _, node in f:GetChildren() do
		watchNode(node)
	end
	f.ChildAdded:Connect(function(node)
		-- attributes are set before parenting on the server, but wait one frame to be safe
		task.defer(watchNode, node)
	end)
	f.ChildRemoved:Connect(function(node)
		local id = node.Name
		local prev = phases[id]
		phases[id] = nil
		if id == "MeteorShower" then
			clearMeteors()
		end
		EventClient.PhaseChanged:Fire(id, nil, prev)
		EventClient.Changed:Fire(id)
	end)
	f:GetAttributeChangedSignal("TestMode"):Connect(function()
		EventClient.Changed:Fire(nil)
	end)
	player:GetAttributeChangedSignal("PFConvCarrying"):Connect(function()
		mine.carrying = player:GetAttribute("PFConvCarrying") == true
		EventClient.Changed:Fire("CosmicConvergence")
	end)
	task.spawn(function()
		ProfileClient.waitForSnapshot(20)
		EventClient.sync()
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			EventClient.expire()
		end
	end)
end

return EventClient
