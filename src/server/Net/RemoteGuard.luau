--!strict
-- RemoteGuard — owner: Developer B (Net layer; INTERFACES.md request + Action_Result convention).
-- Every client->server remote of the backend services is bound through RemoteGuard.bind:
--   per-player token-bucket rate limit -> payload shape check -> requestId check -> handler in pcall
--   -> Action_Result { requestId, ok, code, data? }   (data is an optional, additive field)
-- Clients only ever send INTENT (ids, amounts they want to spend); servers compute every reward.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetConfig = require(script.Parent.Parent.Config.NetConfig)
local ItemCatalog = require(ReplicatedStorage.PF_Shared.Config.ItemCatalog)

local RemoteGuard = {}

---------------------------------------------------------------- pure validators

function RemoteGuard.isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function RemoteGuard.isInt(v: any, min: number, max: number): boolean
	return RemoteGuard.isFiniteNumber(v) and v % 1 == 0 and v >= min and v <= max
end

function RemoteGuard.isPositiveInt(v: any, max: number): boolean
	return RemoteGuard.isInt(v, 1, max)
end

function RemoteGuard.isRequestId(v: any): boolean
	return RemoteGuard.isInt(v, 1, NetConfig.MAX_REQUEST_ID)
end

RemoteGuard.isId = ItemCatalog.isValidIdString

-- Structural check of an untrusted payload. Returns ok, reason.
function RemoteGuard.checkPayload(payload: any, limits: any?): (boolean, string?)
	local L = limits or NetConfig.PAYLOAD
	if type(payload) ~= "table" then
		return false, "NOT_TABLE"
	end
	local count = 0
	local function walk(t: any, depth: number): (boolean, string?)
		if depth > L.MAX_DEPTH then
			return false, "TOO_DEEP"
		end
		for k, v in t do
			count += 1
			if count > L.MAX_KEYS then
				return false, "TOO_MANY_KEYS"
			end
			if type(k) ~= "string" or #k > L.MAX_KEY_LENGTH then
				return false, "BAD_KEY"
			end
			local tv = typeof(v)
			if tv == "string" then
				if #v > L.MAX_STRING_LENGTH then
					return false, "STRING_TOO_LONG"
				end
			elseif tv == "number" then
				if not RemoteGuard.isFiniteNumber(v) then
					return false, "BAD_NUMBER"
				end
			elseif tv == "table" then
				local ok, why = walk(v, depth + 1)
				if not ok then
					return false, why
				end
			elseif tv ~= "boolean" then
				return false, "BAD_TYPE"
			end
		end
		return true, nil
	end
	return walk(payload, 1)
end

---------------------------------------------------------------- rate limiter

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RemoteGuard.newRateLimiter(capacity: number, refillPerSecond: number, clock: (() -> number)?)
	return setmetatable({ capacity = capacity, refill = refillPerSecond, clock = clock or os.clock, _buckets = {} :: { [any]: any } }, RateLimiter)
end

function RateLimiter:Allow(key: any): boolean
	local t = self.clock()
	local b = self._buckets[key]
	if not b then
		b = { tokens = self.capacity, at = t }
		self._buckets[key] = b
	end
	b.tokens = math.min(self.capacity, b.tokens + (t - b.at) * self.refill)
	b.at = t
	if b.tokens >= 1 then
		b.tokens -= 1
		return true
	end
	return false
end

function RateLimiter:Remove(key: any)
	self._buckets[key] = nil
end

---------------------------------------------------------------- remotes

local limiters: { any } = {}
local lastViolationLog: { [string]: number } = {}
local cleanupConnected = false

local function remoteFolder(): Folder
	local f = ReplicatedStorage:FindFirstChild("PF_Remotes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "PF_Remotes"
		f.Parent = ReplicatedStorage
	end
	return f :: Folder
end

function RemoteGuard.getRemote(name: string): RemoteEvent
	local folder = remoteFolder()
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

function RemoteGuard.reply(player: Player, requestId: any, ok: boolean, code: string, data: any?)
	if RemoteGuard.isRequestId(requestId) then
		RemoteGuard.getRemote("Action_Result"):FireClient(player, { requestId = requestId, ok = ok, code = code, data = data })
	end
end

local function logViolation(player: Player, remoteName: string, reason: string)
	local k = tostring(player.UserId) .. ":" .. remoteName
	local t = os.clock()
	if (lastViolationLog[k] or -math.huge) + NetConfig.VIOLATION_LOG_INTERVAL <= t then
		lastViolationLog[k] = t
		warn(string.format("[PF][Net] rejected %s from %s (%d): %s", remoteName, player.Name, player.UserId, reason))
	end
end

export type Handler = (Player, { [string]: any }) -> (boolean, string?, any?)

function RemoteGuard.bind(name: string, handler: Handler): RemoteEvent
	local remote = RemoteGuard.getRemote(name)
	RemoteGuard.getRemote("Action_Result")
	local rl = NetConfig.RATE_LIMITS[name] or NetConfig.RATE_LIMITS.default
	local limiter = RemoteGuard.newRateLimiter(rl.capacity, rl.refillPerSecond)
	table.insert(limiters, limiter)
	if not cleanupConnected then
		cleanupConnected = true
		Players.PlayerRemoving:Connect(function(p)
			for _, l in limiters do
				l:Remove(p)
			end
		end)
	end
	remote.OnServerEvent:Connect(function(player: Player, payload: any)
		local requestId = if type(payload) == "table" then rawget(payload, "requestId") else nil
		if not limiter:Allow(player) then
			logViolation(player, name, "RATE_LIMITED")
			RemoteGuard.reply(player, requestId, false, "RATE_LIMITED")
			return
		end
		local okShape, why = RemoteGuard.checkPayload(payload)
		if not okShape then
			logViolation(player, name, why or "INVALID")
			RemoteGuard.reply(player, requestId, false, "INVALID_PAYLOAD")
			return
		end
		if not RemoteGuard.isRequestId(requestId) then
			logViolation(player, name, "BAD_REQUEST_ID")
			return
		end
		local okCall, success, code, data = pcall(handler, player, payload)
		if not okCall then
			warn("[PF][Net] handler error in " .. name .. ": " .. tostring(success))
			RemoteGuard.reply(player, requestId, false, "INTERNAL_ERROR")
			return
		end
		local finalCode = if type(code) == "string" then code elseif success then "OK" else "FAILED"
		RemoteGuard.reply(player, requestId, success == true, finalCode, data)
	end)
	return remote
end

return RemoteGuard
