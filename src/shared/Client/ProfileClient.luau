--!strict
-- ProfileClient — owner: Developer B. CLIENT-ONLY read-only view of the local player's profile + helpers
-- for backend actions. Require it from LocalScripts (UI etc.); it initializes lazily.
--
--   local ProfileClient = require(ReplicatedStorage.PF_Shared.Client.ProfileClient)
--   ProfileClient.get()                 -> deep-frozen snapshot | nil (see ClientDataService for the shape)
--   ProfileClient.Changed:Connect(fn)   -- fn(snapshot)
--   ProfileClient.waitForSnapshot(timeout?) -> snapshot | nil
--   ProfileClient.refresh()
--   ProfileClient.sellMaterial(materialId, amount) -> ok, code, data   (yields until Action_Result)
--   ProfileClient.purchaseUpgrade(upgradeId)      -> ok, code, data
-- Request ids start at 1e9 so they never collide with other client controllers' ids on Action_Result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Util.Signal)
local TableUtil = require(script.Parent.Parent.Util.TableUtil)

local ProfileClient = {}
ProfileClient.Changed = Signal.new()

local REQUEST_TIMEOUT = 10
local REMOTE_WAIT = 30

local snapshot: any = nil
local started = false
local nextRequestId = 1_000_000_000
local waiting: { [number]: thread } = {}
local remotes: Folder? = nil

local function init()
	if started then
		return
	end
	assert(RunService:IsClient(), "ProfileClient is client-only")
	started = true
	remotes = ReplicatedStorage:WaitForChild("PF_Remotes", REMOTE_WAIT) :: Folder?
	if not remotes then
		warn("[PF][ProfileClient] PF_Remotes not found")
		return
	end
	local snap = remotes:WaitForChild("Profile_Snapshot", REMOTE_WAIT) :: RemoteEvent?
	local result = remotes:WaitForChild("Action_Result", REMOTE_WAIT) :: RemoteEvent?
	if snap then
		snap.OnClientEvent:Connect(function(s: any)
			if type(s) == "table" then
				snapshot = TableUtil.deepFreeze(s)
				ProfileClient.Changed:Fire(snapshot)
			end
		end)
	end
	if result then
		result.OnClientEvent:Connect(function(r: any)
			if type(r) == "table" and type(r.requestId) == "number" then
				local th = waiting[r.requestId]
				if th then
					waiting[r.requestId] = nil
					task.spawn(th, r.ok == true, r.code, r.data)
				end
			end
		end)
	end
	ProfileClient.refresh()
end

local function send(remoteName: string, payload: { [string]: any }): (boolean, string?, any)
	init()
	local r = remotes and remotes:FindFirstChild(remoteName) :: RemoteEvent?
	if not r then
		return false, "NO_REMOTE", nil
	end
	nextRequestId += 1
	local id = nextRequestId
	payload.requestId = id
	waiting[id] = coroutine.running()
	local timeoutThread = task.delay(REQUEST_TIMEOUT, function()
		local th = waiting[id]
		if th then
			waiting[id] = nil
			task.spawn(th, false, "TIMEOUT", nil)
		end
	end)
	r:FireServer(payload)
	local ok, code, data = coroutine.yield()
	task.cancel(timeoutThread)
	return ok, code, data
end

function ProfileClient.get(): any
	init()
	return snapshot
end

function ProfileClient.waitForSnapshot(timeout: number?): any
	init()
	local deadline = os.clock() + (timeout or 30)
	while snapshot == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return snapshot
end

function ProfileClient.refresh()
	init()
	local r = remotes and remotes:FindFirstChild("Profile_RequestSnapshot") :: RemoteEvent?
	if r then
		nextRequestId += 1
		r:FireServer({ requestId = nextRequestId })
	end
end

function ProfileClient.sellMaterial(materialId: string, amount: number)
	return send("Economy_SellMaterial", { materialId = materialId, amount = amount })
end

function ProfileClient.purchaseUpgrade(upgradeId: string)
	return send("Economy_PurchaseUpgrade", { upgradeId = upgradeId })
end

-- Generic sender for other backend remotes (same request/Action_Result convention).
function ProfileClient.request(remoteName: string, payload: { [string]: any })
	return send(remoteName, payload)
end

return ProfileClient
