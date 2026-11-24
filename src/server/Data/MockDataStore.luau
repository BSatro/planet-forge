--!strict
-- MockDataStore — owner: Developer B. In-memory stand-in for a DataStore (Studio default + tests).
-- Values round-trip through JSON so unserializable data fails here just like in a real store.
-- Nothing is persisted beyond the current server session.
-- Test hooks: :FailNext(n, message), :SetLatency(seconds), :Peek(key), :Poke(key, value), .requestCount

local HttpService = game:GetService("HttpService")

local MockDataStore = {}
MockDataStore.__index = MockDataStore

local VALUE_LIMIT = 4_000_000

function MockDataStore.new()
	return setmetatable({
		kind = "mock",
		storeName = "mock",
		requestCount = 0,
		_data = {} :: { [string]: string },
		_failCount = 0,
		_failMessage = "",
		_latency = 0,
	}, MockDataStore)
end

local shared: any = nil
function MockDataStore.shared()
	if not shared then
		shared = MockDataStore.new()
		shared.storeName = "mock(shared)"
	end
	return shared
end

function MockDataStore:FailNext(n: number, message: string?)
	self._failCount = math.max(0, math.floor(n))
	self._failMessage = message or "503: Mock DataStore failure (injected)"
end

function MockDataStore:SetLatency(seconds: number)
	self._latency = math.max(0, seconds)
end

function MockDataStore:Peek(key: string): any
	local raw = self._data[key]
	return if raw ~= nil then HttpService:JSONDecode(raw) else nil
end

function MockDataStore:Poke(key: string, value: any)
	self._data[key] = if value == nil then nil else HttpService:JSONEncode(value)
end

function MockDataStore:UpdateAsync(key: string, transform: (any) -> any): any
	self.requestCount += 1
	if self._latency > 0 then
		task.wait(self._latency)
	end
	if self._failCount > 0 then
		self._failCount -= 1
		error(self._failMessage, 0)
	end
	local old = self:Peek(key)
	local new = transform(old)
	if new == nil then
		return old
	end
	local encoded = HttpService:JSONEncode(new)
	if #encoded > VALUE_LIMIT then
		error("105: Mock serialized value too large", 0)
	end
	self._data[key] = encoded
	return HttpService:JSONDecode(encoded)
end

return MockDataStore
