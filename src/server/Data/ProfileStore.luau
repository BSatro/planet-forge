--!strict
-- ProfileStore — owner: Developer B. Session-locked profile persistence on top of DataStoreGateway.
-- One key per user. Stored record:
--   { data = <profile>, meta = { session = { id, jobId, placeId, lockedAt }?, lastSaveAt, saveCount } }
-- Conflict protection:
--   * Load acquires the session lock inside UpdateAsync. A foreign *fresh* lock -> wait and retry (lets a
--     teleporting player's previous server finish its final save). After LOAD_LOCK_RETRIES the lock is
--     taken over. A lock not refreshed for SESSION_LOCK_STALE_AFTER (crashed server) is taken at once.
--   * Every save is an UpdateAsync that writes ONLY while the stored session id is still ours. Once another
--     server has taken over, saves are refused (LOCK_LOST): an old session can never overwrite newer data.
--   * Saves of one profile are serialized and work on a deep copy taken at save time.
-- Instances are injectable (backend, clock, config) so the whole flow is unit-tested with MockDataStore.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gateway = require(script.Parent.DataStoreGateway)
local Schema = require(script.Parent.ProfileSchema)
local Migrations = require(script.Parent.Migrations)
local TableUtil = require(ReplicatedStorage.PF_Shared.Util.TableUtil)
local DataConfig = require(script.Parent.Parent.Config.DataConfig)

export type Profile = {
	userId: number,
	key: string,
	sessionId: string,
	data: any,
	isNew: boolean,
	stoleLock: boolean,
	loadedAt: number,
	lastSavedAt: number,
	saveCount: number,
	released: boolean,
	lockLost: boolean,
	_saving: boolean,
}

local ProfileStore = {}
ProfileStore.__index = ProfileStore

-- opts: { backend, keyPrefix?, clock?, config? (overrides DataConfig fields), retryOpts?, jobId?, placeId? }
function ProfileStore.new(opts: any)
	local self = setmetatable({}, ProfileStore)
	self.backend = assert(opts.backend, "ProfileStore.new: backend required")
	self.keyPrefix = opts.keyPrefix or ""
	self.clock = opts.clock or os.time
	self.config = setmetatable(opts.config or {}, { __index = DataConfig })
	self.retryOpts = opts.retryOpts
	self.jobId = opts.jobId or (if game.JobId ~= "" then game.JobId else "studio")
	self.placeId = opts.placeId or game.PlaceId
	return self
end

function ProfileStore:KeyFor(userId: number): string
	return self.keyPrefix .. tostring(userId)
end

local function normalize(old: any): any
	if type(old) ~= "table" then
		return nil
	end
	if type(old.meta) == "table" then
		return { data = old.data, meta = old.meta }
	end
	-- raw value without an envelope (pre-envelope/legacy): the whole value is the profile
	return { data = old, meta = { saveCount = 0 } }
end

local function sessionOf(record: any): any
	local s = record and record.meta and record.meta.session
	return if type(s) == "table" then s else nil
end

-- Returns ok, Profile | errorCode ("DATASTORE_ERROR" | "LOCKED" | "FUTURE_SCHEMA" | "CORRUPT_*" | "MIGRATION_FAILED")
function ProfileStore:Load(userId: number): (boolean, any)
	local cfg = self.config
	local key = self:KeyFor(userId)
	local sessionId = HttpService:GenerateGUID(false)
	local maxAttempts = cfg.LOAD_LOCK_RETRIES + 1
	for attempt = 1, maxAttempts do
		local outcome: any = nil
		local okReq = Gateway.update(self.backend, key, function(old)
			outcome = nil
			local now = self.clock()
			-- Only a MISSING record is a new player. A value that exists but is not a usable profile (not a table,
			-- or an envelope whose data is gone) is refused untouched: never overwritten with defaults.
			if old ~= nil and (type(old) ~= "table" or (type(old.meta) == "table" and type(old.data) ~= "table")) then
				outcome = { kind = "error", code = "CORRUPT_RECORD" }
				return nil
			end
			local record = normalize(old)
			local stole = false
			local session = sessionOf(record)
			if session and session.id ~= sessionId then
				local lockedAt = tonumber(session.lockedAt) or 0
				local stale = now - lockedAt >= cfg.SESSION_LOCK_STALE_AFTER
				if not stale and attempt < maxAttempts then
					outcome = { kind = "locked" }
					return nil -- cancel write
				end
				stole = true
			end
			local isNew = old == nil
			local data
			if isNew then
				data = Schema.default(now, userId)
			else
				local okMig, res = Migrations.run(TableUtil.deepCopy(record.data), Schema.CURRENT_VERSION)
				if not okMig then
					outcome = { kind = "error", code = res }
					return nil
				end
				data = Schema.reconcile(res, now, userId)
			end
			local newRecord = { data = data, meta = if record then record.meta else { saveCount = 0 } }
			newRecord.meta.session = { id = sessionId, jobId = self.jobId, placeId = self.placeId, lockedAt = now }
			outcome = { kind = "loaded", data = data, isNew = isNew, stole = stole, saveCount = tonumber(newRecord.meta.saveCount) or 0 }
			return newRecord
		end, self.retryOpts)
		if not okReq or outcome == nil then
			return false, "DATASTORE_ERROR"
		end
		if outcome.kind == "loaded" then
			if outcome.stole then
				warn("[PF][Data] took over session lock for " .. key)
			end
			local profile: Profile = {
				userId = userId,
				key = key,
				sessionId = sessionId,
				data = outcome.data,
				isNew = outcome.isNew,
				stoleLock = outcome.stole,
				loadedAt = self.clock(),
				lastSavedAt = 0,
				saveCount = outcome.saveCount,
				released = false,
				lockLost = false,
				_saving = false,
			}
			return true, profile
		elseif outcome.kind == "error" then
			return false, outcome.code
		end
		if attempt < maxAttempts then
			task.wait(cfg.LOAD_LOCK_RETRY_DELAY)
		end
	end
	return false, "LOCKED"
end

-- Writes the profile if we still own the session. release=true also clears the lock.
-- Returns ok, code ("OK" | "LOCK_LOST" | "RELEASED" | "DATASTORE_ERROR" | "TOO_LARGE")
function ProfileStore:Save(profile: Profile, release: boolean?): (boolean, string)
	while profile._saving do
		task.wait()
	end
	if profile.lockLost then
		return false, "LOCK_LOST"
	end
	if profile.released then
		return false, "RELEASED"
	end
	profile._saving = true
	local now = self.clock()
	local snapshot = TableUtil.deepCopy(profile.data)
	snapshot.lastSaveAt = now
	local okEnc, encoded = pcall(HttpService.JSONEncode, HttpService, snapshot)
	if not okEnc or #encoded > self.config.MAX_RECORD_BYTES then
		profile._saving = false
		warn("[PF][Data] refusing to save " .. profile.key .. ": " .. (if okEnc then "record too large" else tostring(encoded)))
		return false, "TOO_LARGE"
	end
	local outcome: string? = nil
	local okReq = Gateway.update(self.backend, profile.key, function(old)
		outcome = nil
		local record = normalize(old)
		local session = sessionOf(record)
		if not session or session.id ~= profile.sessionId then
			outcome = "LOCK_LOST"
			return nil
		end
		local meta = record.meta
		meta.lastSaveAt = now
		meta.saveCount = (tonumber(meta.saveCount) or 0) + 1
		if release then
			meta.session = nil
		else
			session.lockedAt = now
		end
		outcome = "OK"
		return { data = snapshot, meta = meta }
	end, self.retryOpts)
	profile._saving = false
	if not okReq or outcome == nil then
		return false, "DATASTORE_ERROR"
	end
	if outcome == "LOCK_LOST" then
		profile.lockLost = true
		warn("[PF][Data] session lock lost for " .. profile.key .. " — save refused")
		return false, "LOCK_LOST"
	end
	profile.data.lastSaveAt = now
	profile.lastSavedAt = now
	profile.saveCount += 1
	if release then
		profile.released = true
	end
	return true, "OK"
end

-- Final save + unlock, retried. attempts defaults to config.RELEASE_ATTEMPTS.
function ProfileStore:Release(profile: Profile, attempts: number?): (boolean, string)
	local n = attempts or self.config.RELEASE_ATTEMPTS
	local code = "DATASTORE_ERROR"
	for attempt = 1, n do
		local ok, c = self:Save(profile, true)
		if ok then
			return true, "OK"
		end
		code = c
		if c == "LOCK_LOST" or c == "RELEASED" or c == "TOO_LARGE" then
			return false, c
		end
		if attempt < n then
			task.wait(self.config.RELEASE_RETRY_DELAY)
		end
	end
	return false, code
end

return ProfileStore
