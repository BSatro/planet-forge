--!strict
-- ProfileService — owner: Developer B. Server-owned player profiles.
-- Per-player lifecycle:
--   join  -> PlanetSlotService:Assign (kick if 8/8) -> ProfileStore:Load (session-locked, migrated,
--            reconciled) -> ProfileLoaded(player, slot, isNew)
--   play  -> services mutate the live data through THEIR APIs and call :MarkChanged
--            autosave sweep every AUTOSAVE_INTERVAL (staggered, refreshes the session lock)
--   leave -> slot released immediately (another player may take it); ProfileReleasing fires; final save +
--            unlock in the background with retries. A rejoin to the same server waits for that release.
--   close -> BindToClose releases every profile in parallel within SHUTDOWN_TIMEOUT.
--
-- Public API (server only):
--   :GetData(player) -> live profile table | nil   (READ for owners; mutate only via owning services)
--   :IsReady(player) / :WaitForData(player, timeout?)
--   :MarkChanged(player, section)                  -> pushes a client snapshot (coalesced)
--   :SaveNow(player) -> ok, code                   (cooldown-limited)
--   :GetLoadedPlayers() -> { Player }
--   :GetEnvironment() -> { name, persistent, storeName }
--   .ProfileLoaded(player, slot, isNew) .ProfileReleasing(player) .ProfileChanged(player, section)
--   .SaveFailed(player?, userId, code)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.PF_Shared.Util.Signal)
local EconomyConfig = require(ReplicatedStorage.PF_Shared.Config.EconomyConfig)
local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local DataEnvironment = require(script.Parent.Parent.Data.DataEnvironment)
local ProfileStore = require(script.Parent.Parent.Data.ProfileStore)
local Schema = require(script.Parent.Parent.Data.ProfileSchema)
local PlanetSlotService = require(script.Parent.PlanetSlotService)

local ProfileService = {}
ProfileService.ProfileLoaded = Signal.new()
ProfileService.ProfileReleasing = Signal.new()
ProfileService.ProfileChanged = Signal.new()
ProfileService.SaveFailed = Signal.new()

local env: any = nil
local store: any = nil
local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}
local releasing: { [number]: number } = {} -- userId -> in-flight release count
local lastManualSave: { [Player]: number } = {}
local shuttingDown = false

local function kickMessage(code: string): string
	return DataConfig.KICK_MESSAGES[code] or DataConfig.KICK_MESSAGES.LOAD_FAILED
end

local function accountPlayTime(profile: any)
	local t = os.clock()
	local mark = profile._playMark or t
	local whole = math.floor(t - mark)
	if whole > 0 then
		profile.data.playSeconds = math.min(profile.data.playSeconds + whole, EconomyConfig.BALANCE_CAPS.counter)
		profile._playMark = mark + whole
	else
		profile._playMark = mark
	end
end

local function releaseProfile(userId: number, profile: any, attempts: number?): boolean
	releasing[userId] = (releasing[userId] or 0) + 1
	accountPlayTime(profile)
	local ok, code = store:Release(profile, attempts)
	local left = (releasing[userId] or 1) - 1
	releasing[userId] = if left > 0 then left else nil
	if ok then
		print(string.format("[PF][Profile] released %s (saves=%d)", profile.key, profile.saveCount))
	else
		warn(string.format("[PF][Profile] release FAILED for %s: %s", profile.key, code))
		ProfileService.SaveFailed:Fire(nil, userId, code)
	end
	return ok
end

local function saveProfile(player: Player, profile: any): (boolean, string)
	accountPlayTime(profile)
	local ok, code = store:Save(profile)
	if not ok then
		if code == "LOCK_LOST" then
			if profiles[player] == profile then
				profiles[player] = nil
			end
			player:Kick(kickMessage("LOCK_LOST"))
		elseif code ~= "RELEASED" then
			ProfileService.SaveFailed:Fire(player, player.UserId, code)
		end
	end
	return ok, code
end

local function onPlayerAdded(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	if shuttingDown then
		player:Kick(kickMessage("SHUTTING_DOWN"))
		return
	end
	loading[player] = true
	local slot = PlanetSlotService:Assign(player)
	if not slot then
		loading[player] = nil
		warn("[PF][Profile] no free planet slot for " .. player.Name)
		player:Kick(kickMessage("SERVER_FULL"))
		return
	end
	-- same user rejoining this server before their previous session finished saving
	local waited = 0
	while releasing[player.UserId] and waited < DataConfig.REJOIN_RELEASE_WAIT do
		waited += task.wait(0.25)
	end
	-- Load with a RESTRICTED fallback: a transient failure never writes defaults over a real save. The
	-- player stays in a safe read-only state (PF_ProfileState = "restricted"; every service answers
	-- NOT_READY) while we retry, and is only kicked after LOAD_RETRY_ATTEMPTS more failures.
	player:SetAttribute("PF_ProfileState", "loading")
	local ok, result = store:Load(player.UserId)
	local attempt = 0
	while not ok and DataConfig.RETRYABLE_LOAD_CODES[result] and attempt < DataConfig.LOAD_RETRY_ATTEMPTS
		and player.Parent == Players and not shuttingDown do
		attempt += 1
		player:SetAttribute("PF_ProfileState", "restricted")
		warn(string.format("[PF][Profile] load failed for %s (%s); restricted mode, retry %d/%d in %ds", player.Name, tostring(result), attempt, DataConfig.LOAD_RETRY_ATTEMPTS, DataConfig.LOAD_RETRY_INTERVAL))
		task.wait(DataConfig.LOAD_RETRY_INTERVAL)
		if player.Parent ~= Players or shuttingDown then
			break
		end
		ok, result = store:Load(player.UserId)
	end
	loading[player] = nil
	if player.Parent ~= Players or shuttingDown then
		if ok then
			task.spawn(releaseProfile, player.UserId, result)
		end
		if player.Parent == Players then
			player:Kick(kickMessage("SHUTTING_DOWN"))
		end
		return
	end
	if not ok then
		warn(string.format("[PF][Profile] load failed for %s (%d): %s", player.Name, player.UserId, tostring(result)))
		player:SetAttribute("PF_ProfileState", "failed")
		PlanetSlotService:Release(player)
		if DataConfig.KICK_ON_LOAD_FAILURE then
			player:Kick(kickMessage(result))
		end
		return
	end
	local profile = result
	profile.data.lastLoginAt = os.time()
	profile.data.loginCount += 1
	profile._playMark = os.clock()
	profiles[player] = profile
	player:SetAttribute("PF_Level", profile.data.level)
	player:SetAttribute("PF_ProfileReady", true)
	player:SetAttribute("PF_ProfileState", "ready")
	print(string.format("[PF][Profile] loaded %s -> slot %d (%s, env=%s)", profile.key, slot, if profile.isNew then "new" else "returning", env.name))
	ProfileService.ProfileLoaded:Fire(player, slot, profile.isNew)
	ProfileService:MarkChanged(player, "all")
end

local function onPlayerRemoving(player: Player)
	PlanetSlotService:Release(player)
	lastManualSave[player] = nil
	local profile = profiles[player]
	if not profile then
		return
	end
	ProfileService.ProfileReleasing:Fire(player) -- listeners run synchronously while data is still readable
	profiles[player] = nil
	task.spawn(releaseProfile, player.UserId, profile)
end

local function autosaveLoop()
	while not shuttingDown do
		task.wait(DataConfig.AUTOSAVE_INTERVAL)
		local list = {}
		for p, prof in profiles do
			table.insert(list, { p, prof })
		end
		local gap = if #list > 0 then math.min(DataConfig.AUTOSAVE_INTERVAL / (#list + 1), DataConfig.AUTOSAVE_MAX_GAP) else 0
		for _, e in list do
			if shuttingDown then
				break
			end
			if profiles[e[1]] == e[2] then
				task.spawn(saveProfile, e[1], e[2])
			end
			task.wait(gap)
		end
	end
end

local function onClose()
	shuttingDown = true
	local pending = 0
	local released = 0
	for player, profile in profiles do
		profiles[player] = nil
		pending += 1
		task.spawn(function()
			if releaseProfile(player.UserId, profile, DataConfig.SHUTDOWN_RELEASE_ATTEMPTS) then
				released += 1
			end
			pending -= 1
		end)
	end
	local deadline = os.clock() + DataConfig.SHUTDOWN_TIMEOUT
	while (pending > 0 or next(releasing) ~= nil or next(loading) ~= nil) and os.clock() < deadline do
		task.wait(0.1)
	end
	print(string.format("[PF][Profile] shutdown: released %d profile(s), %d still pending", released, pending))
end

function ProfileService:Init()
	env = DataEnvironment.resolve()
	store = ProfileStore.new({ backend = env.backend, keyPrefix = env.keyPrefix })
	print(string.format("[PF][Profile] data environment=%s persistent=%s store=%s keyPrefix=%s universe=%d place=%d studio=%s", env.name, tostring(env.persistent), tostring(env.storeName), tostring(env.keyPrefix), game.GameId, game.PlaceId, tostring(env.isStudio)))
end

function ProfileService:Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	game:BindToClose(onClose)
	-- deferred so every other service has connected its ProfileLoaded listeners first
	task.defer(function()
		for _, p in Players:GetPlayers() do
			task.spawn(onPlayerAdded, p)
		end
	end)
	task.spawn(autosaveLoop)
end

function ProfileService:GetData(player: Player): any
	local p = profiles[player]
	return p and p.data
end

function ProfileService:IsReady(player: Player): boolean
	return profiles[player] ~= nil
end

function ProfileService:WaitForData(player: Player, timeout: number?): any
	local deadline = os.clock() + (timeout or 30)
	while not profiles[player] and player.Parent == Players and os.clock() < deadline do
		task.wait(0.1)
	end
	return self:GetData(player)
end

function ProfileService:GetLoadedPlayers(): { Player }
	local out = {}
	for p in profiles do
		table.insert(out, p)
	end
	return out
end

function ProfileService:MarkChanged(player: Player, section: string)
	local p = profiles[player]
	if not p then
		return
	end
	if player:GetAttribute("PF_Level") ~= p.data.level then
		player:SetAttribute("PF_Level", p.data.level)
	end
	self.ProfileChanged:Fire(player, section)
end

-- force = true: purchase fulfilment (a receipt may only be acknowledged once its grant is saved), no cooldown.
function ProfileService:SaveNow(player: Player, force: boolean?): (boolean, string)
	local p = profiles[player]
	if not p then
		return false, "NOT_READY"
	end
	local t = os.clock()
	if not force and (lastManualSave[player] or -math.huge) + DataConfig.MANUAL_SAVE_COOLDOWN > t then
		return false, "COOLDOWN"
	end
	lastManualSave[player] = t
	return saveProfile(player, p)
end

function ProfileService:GetEnvironment(): { name: string, persistent: boolean, storeName: string }
	return { name = env.name, persistent = env.persistent, storeName = env.storeName }
end

-- Dev/test only (DevCommandService): replace the data with a fresh default, keeping the session lock.
function ProfileService:_ResetData(player: Player): boolean
	local p = profiles[player]
	if not p or env.name == "production" then
		return false
	end
	p.data = Schema.default(os.time(), player.UserId)
	self:MarkChanged(player, "all")
	return true
end

-- Dev/test only: underlying backend (MockDataStore in Studio).
function ProfileService:_GetBackend(): any
	return if env.name ~= "production" then env.backend else nil
end

return ProfileService
