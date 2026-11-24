--!strict
-- DataStoreGateway — owner: Developer B. The ONLY code that issues data store requests.
--   * UpdateAsync only (atomic read-modify-write; no GetAsync->SetAsync races).
--   * Waits for request budget before real requests (bounded), so bursts don't throttle the server.
--   * Bounded exponential back-off retries. Non-retryable errors (bad key, value too large, API access
--     denied) fail fast instead of burning budget.
-- The transform passed in must NOT yield and may run more than once.

local DataStoreService = game:GetService("DataStoreService")

local DataConfig = require(script.Parent.Parent.Config.DataConfig)

local Gateway = {}

-- Roblox data store error codes that will not succeed on retry.
local NON_RETRYABLE = {
	[101] = true, -- key name empty
	[102] = true, -- key name too long
	[103] = true, -- value not allowed
	[104] = true, -- cannot store value
	[105] = true, -- serialized value too large
	[106] = true, -- invalid MaxValue/MinValue
	[403] = true, -- Studio API access disabled / forbidden
} :: { [number]: boolean }

export type RetryOpts = { retries: number?, baseDelay: number?, maxDelay: number?, waitForBudget: boolean? }

function Gateway.errorCode(err: any): number?
	local s = tostring(err)
	local code = string.match(s, "^(%d%d%d):") or string.match(s, "HTTP (%d%d%d)")
	return if code then tonumber(code) else nil
end

function Gateway.isRetryable(err: any): boolean
	local code = Gateway.errorCode(err)
	return code == nil or not NON_RETRYABLE[code]
end

local function waitForBudget(backend: any)
	if backend.kind ~= "datastore" then
		return
	end
	local deadline = os.clock() + DataConfig.BUDGET_WAIT_MAX
	while os.clock() < deadline do
		local ok, budget = pcall(function()
			return math.min(
				DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync),
				DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync)
			)
		end)
		if not ok or budget >= 1 then
			return
		end
		task.wait(DataConfig.BUDGET_POLL_INTERVAL)
	end
end

-- Returns ok, committedValue, lastError
function Gateway.update(backend: any, key: string, transform: (any) -> any, opts: RetryOpts?): (boolean, any, string?)
	local o: RetryOpts = opts or {}
	local attempts = (o.retries or DataConfig.REQUEST_RETRIES) + 1
	local baseDelay = o.baseDelay or DataConfig.RETRY_BASE_DELAY
	local maxDelay = o.maxDelay or DataConfig.RETRY_MAX_DELAY
	local lastErr: string? = nil
	for attempt = 1, attempts do
		if o.waitForBudget ~= false then
			waitForBudget(backend)
		end
		local ok, result = pcall(backend.UpdateAsync, backend, key, transform)
		if ok then
			return true, result, nil
		end
		lastErr = tostring(result)
		local retryable = Gateway.isRetryable(result)
		warn(string.format("[PF][Data] UpdateAsync %s failed (attempt %d/%d, %s): %s", key, attempt, attempts, if not retryable then "not retryable" elseif attempt < attempts then "retrying" else "giving up", lastErr :: string))
		if not retryable then
			break
		end
		if attempt < attempts then
			task.wait(math.min(baseDelay * 2 ^ (attempt - 1), maxDelay))
		end
	end
	return false, nil, lastErr
end

return Gateway
