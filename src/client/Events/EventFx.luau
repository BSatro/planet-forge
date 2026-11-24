--!strict
-- EventFx — owner: Live Gameplay (registry + lifecycle) / Developer A (production effects).
-- Presentation of world events is LOCAL and replaceable. Each event id has one handler; the defaults live in
-- Events/Fx/<EventId>Fx. Developer A swaps in production art with:
--     EventFx.register("SolarStorm", MyStormFx)      -- stops the current handler, starts the new one if running
-- Handler (all optional):  start(ctx) | phase(ctx, phase) | update(ctx, dt) | notify(ctx, msg) | stop(ctx)
--                          meteorAdded(ctx, meteor) | meteorRemoved(ctx, id, capturedByUserId?, pos?)
-- ctx: eventId, instanceId, view() -> EventView?, quality "full"|"reduced"|"minimal", budget (EventConfig.FX),
--      palette, folder (local Workspace folder), data (scratch), track(inst) -> inst, connect(signal, fn),
--      tween(obj, t, props, style?, dir?), setLighting({prop = value}), original(prop), onCleanup(fn), inRift(),
--      reducedMotion() -> boolean.
-- Guarantees: everything tracked is destroyed, every connection/tween cancelled and every Lighting property set
-- through ctx.setLighting restored when the event ends, the handler is replaced, or the handler errors.
-- Gameplay never depends on these handlers (capture input + markers live in EventInteract).
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)
local EventClient = require(script.Parent.EventClient)

local player = Players.LocalPlayer
local EventFx = {}

local handlers: { [string]: any } = {}
local running: { [string]: any } = {}
local deps: any = {}
local root: Folder? = nil
local initialised = false

local function prefsReduced(): boolean
	return player:GetAttribute("PFReducedMotion") == true
end

function EventFx.quality(): string
	local q = "full"
	local v = deps.visuals
	if v and v.getEffects then
		local ok, e = pcall(v.getEffects)
		if ok and type(e) == "string" and (EventConfig.FX.budgets :: any)[e] then
			q = e
		end
	end
	if q == "full" and prefsReduced() then
		q = "reduced"
	end
	return q
end

local function warnFx(eventId: string, what: string, err: any)
	warn(string.format("[PF][EventFx] %s.%s failed: %s", eventId, what, tostring(err)))
end

local function call(ctx: any, name: string, ...: any): boolean
	local h = handlers[ctx.eventId]
	local fn = h and h[name]
	if type(fn) ~= "function" then
		return true
	end
	local ok, err = pcall(fn, ctx, ...)
	if not ok then
		warnFx(ctx.eventId, name, err)
	end
	return ok
end

local function makeCtx(eventId: string, v: any): any
	local q = EventFx.quality()
	local f = Instance.new("Folder")
	f.Name = eventId
	f.Parent = root
	local ctx: any = {
		eventId = eventId,
		instanceId = v.instanceId,
		quality = q,
		budget = (EventConfig.FX.budgets :: any)[q],
		palette = EventConfig.FX.palette,
		folder = f,
		data = {},
		_tracked = {} :: { Instance },
		_conns = {} :: { any },
		_tweens = {} :: { Tween },
		_lighting = {} :: { [string]: any },
		_cleanup = {} :: { () -> () },
	}
	function ctx.view()
		return EventClient.get(eventId)
	end
	function ctx.track(inst: Instance): Instance
		table.insert(ctx._tracked, inst)
		return inst
	end
	function ctx.connect(signal: any, fn: (...any) -> ())
		table.insert(ctx._conns, signal:Connect(fn))
	end
	function ctx.tween(obj: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
		local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Sine, dir or Enum.EasingDirection.Out), props)
		table.insert(ctx._tweens, tw)
		tw:Play()
		return tw
	end
	function ctx.setLighting(props: { [string]: any })
		for k, val in props do
			if ctx._lighting[k] == nil then
				ctx._lighting[k] = (Lighting :: any)[k]
			end
			(Lighting :: any)[k] = val
		end
	end
	-- value a Lighting property had before this handler first changed it (nil if never changed)
	function ctx.original(k: string): any
		return ctx._lighting[k]
	end
	function ctx.onCleanup(fn: () -> ())
		table.insert(ctx._cleanup, fn)
	end
	function ctx.inRift(): boolean
		return player:GetAttribute("PFInRiftLocal") == true
	end
	ctx.reducedMotion = prefsReduced
	return ctx
end

local function cleanupCtx(ctx: any)
	for _, fn in ctx._cleanup do
		pcall(fn)
	end
	for _, tw in ctx._tweens do
		pcall(function()
			tw:Cancel()
		end)
	end
	for _, c in ctx._conns do
		pcall(function()
			c:Disconnect()
		end)
	end
	for k, val in ctx._lighting do
		pcall(function()
			(Lighting :: any)[k] = val
		end)
	end
	for _, inst in ctx._tracked do
		pcall(inst.Destroy, inst)
	end
	pcall(ctx.folder.Destroy, ctx.folder)
	table.clear(ctx._tracked)
	table.clear(ctx._conns)
	table.clear(ctx._tweens)
	table.clear(ctx._lighting)
end

local function stopFx(eventId: string)
	local ctx = running[eventId]
	if not ctx then
		return
	end
	running[eventId] = nil
	call(ctx, "stop")
	cleanupCtx(ctx)
end

local function startFx(eventId: string)
	if running[eventId] or not handlers[eventId] then
		return
	end
	local v = EventClient.get(eventId)
	if not v then
		return
	end
	local ctx = makeCtx(eventId, v)
	running[eventId] = ctx
	if not call(ctx, "start") then
		running[eventId] = nil
		cleanupCtx(ctx)
		return
	end
	call(ctx, "phase", v.phase)
end

function EventFx.register(eventId: string, handler: any)
	local wasRunning = running[eventId] ~= nil
	stopFx(eventId)
	handlers[eventId] = handler
	if initialised and (wasRunning or EventClient.get(eventId) ~= nil) then
		startFx(eventId)
	end
end

function EventFx.running(eventId: string): any
	return running[eventId]
end

-- Stats for tests / the developer strip: tracked instances + descendants of the local effect folders.
function EventFx.stats(): any
	local out = { running = {}, instances = 0 }
	for id in running do
		table.insert(out.running, id)
	end
	if root then
		out.instances = #root:GetDescendants()
	end
	return out
end

function EventFx.init(d: any?)
	if initialised then
		return
	end
	initialised = true
	deps = d or {}
	local f = Instance.new("Folder")
	f.Name = "PF_ClientEvents"
	f.Parent = Workspace
	root = f
	-- default handlers (Developer A may register replacements at any time)
	local fxFolder = script.Parent:FindFirstChild("Fx")
	for _, id in EventConfig.ORDER do
		if not handlers[id] then
			local mod = fxFolder and fxFolder:FindFirstChild(id .. "Fx")
			if mod and mod:IsA("ModuleScript") then
				local ok, h = pcall(require, mod)
				if ok then
					handlers[id] = h
				else
					warnFx(id, "require", h)
				end
			end
		end
	end
	EventClient.PhaseChanged:Connect(function(eventId: string, phase: string?)
		if phase == nil then
			stopFx(eventId)
		elseif not running[eventId] then
			startFx(eventId)
		else
			call(running[eventId], "phase", phase)
		end
	end)
	EventClient.Notified:Connect(function(msg: any)
		for _, ctx in running do
			call(ctx, "notify", msg)
		end
	end)
	EventClient.MeteorsAdded:Connect(function(list: any)
		local ctx = running.MeteorShower
		if ctx then
			for _, m in list do
				call(ctx, "meteorAdded", m)
			end
		end
	end)
	EventClient.MeteorsRemoved:Connect(function(ids: any, by: number?, pos: Vector3?)
		local ctx = running.MeteorShower
		if ctx then
			for _, id in ids do
				call(ctx, "meteorRemoved", id, by, pos)
			end
		end
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		for _, ctx in running do
			local h = handlers[ctx.eventId]
			if h and h.update then
				local ok, err = pcall(h.update, ctx, dt)
				if not ok then
					ctx._errors = (ctx._errors or 0) + 1
					if ctx._errors <= 3 then
						warnFx(ctx.eventId, "update", err)
					end
					if ctx._errors >= 30 then
						-- a broken handler is switched off instead of spamming every frame
						stopFx(ctx.eventId)
					end
				end
			end
		end
	end)
	for _, v in EventClient.list() do
		startFx(v.eventId)
	end
end

return EventFx
