--!strict
-- Signal — owner: Developer B. Minimal signal. Each handler runs in its own task.spawn thread, so a
-- throwing or yielding handler never breaks the emitter or other handlers. Non-yielding handlers run
-- to completion before :Fire returns.

local Signal = {}
Signal.__index = Signal

export type Connection = { Connected: boolean, Disconnect: (any) -> () }

function Signal.new()
	return setmetatable({ _handlers = {} :: { any } }, Signal)
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local handlers = self._handlers
	local entry: any = { fn = fn, Connected = true }
	function entry.Disconnect()
		entry.Connected = false
		local i = table.find(handlers, entry)
		if i then
			table.remove(handlers, i)
		end
	end
	table.insert(handlers, entry)
	return entry
end

function Signal:Fire(...: any)
	for _, entry in table.clone(self._handlers) do
		if entry.Connected then
			task.spawn(entry.fn, ...)
		end
	end
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local conn: Connection
	conn = self:Connect(function(...)
		conn.Disconnect(conn)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

return Signal
