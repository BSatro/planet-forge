--!strict
-- TableUtil — owner: Developer B. Pure table helpers, safe on server and client.

local TableUtil = {}

function TableUtil.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[TableUtil.deepCopy(k)] = TableUtil.deepCopy(v)
	end
	return (out :: any) :: T
end

function TableUtil.deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, v in value :: any do
			TableUtil.deepFreeze(v)
		end
		table.freeze(value :: any)
	end
	return value
end

function TableUtil.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

function TableUtil.sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return keys
end

return TableUtil
