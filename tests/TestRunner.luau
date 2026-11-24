--!strict
-- TestRunner (Joint, B maintains). Minimal describe/it/expect runner for pure modules.
-- Run from Edit mode via MCP:  return require(game.ServerStorage.PF_Tests.TestRunner).run()
-- Every *.spec module and every module it requires through `ctx.require` is CLONED before require,
-- so edits made in Studio are always picked up (no stale require cache).

local TestRunner = {}

local loadCache: { [ModuleScript]: any } = {}
-- Loads a ModuleScript from its current Source, recursively replacing `require` so every nested
-- dependency is also loaded fresh (the plugin-context require cache otherwise returns stale modules).
local function freshRequire(m: ModuleScript): any
	if loadCache[m] ~= nil then
		return loadCache[m]
	end
	local fn, err = loadstring(m.Source, "=" .. m:GetFullName())
	if not fn then
		error(err, 0)
	end
	setfenv(fn, setmetatable({ script = m, require = freshRequire }, { __index = getfenv() }) :: any)
	local res = fn()
	loadCache[m] = res
	return res
end

local function expect(actual: any)
	local e = {}
	function e.toBe(expected: any)
		if actual ~= expected then
			error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
		end
	end
	function e.toBeNear(expected: number, eps: number?)
		if math.abs(actual - expected) > (eps or 1e-6) then
			error(string.format("expected ~%s, got %s", tostring(expected), tostring(actual)), 2)
		end
	end
	function e.toBeTruthy()
		if not actual then
			error("expected truthy, got " .. tostring(actual), 2)
		end
	end
	function e.toThrow()
		if pcall(actual) then
			error("expected function to throw", 2)
		end
	end
	return e
end

function TestRunner.run(filter: string?): string
	table.clear(loadCache)
	local passed, failed = 0, 0
	local lines = {}
	for _, spec in script.Parent:GetChildren() do
		if spec:IsA("ModuleScript") and spec.Name:match("%.spec$") and (not filter or spec.Name:find(filter, 1, true)) then
			local ok, specFn = pcall(freshRequire, spec)
			if not ok then
				failed += 1
				table.insert(lines, "FAIL " .. spec.Name .. " (load): " .. tostring(specFn))
				continue
			end
			local ctx = { require = freshRequire, expect = expect }
			local cases: { { name: string, fn: () -> () } } = {}
			function ctx.it(name: string, fn: () -> ())
				table.insert(cases, { name = name, fn = fn })
			end
			specFn(ctx)
			for _, c in cases do
				local okCase, err = pcall(c.fn)
				if okCase then
					passed += 1
				else
					failed += 1
					table.insert(lines, string.format("FAIL %s > %s: %s", spec.Name, c.name, tostring(err)))
				end
			end
		end
	end
	table.insert(lines, 1, string.format("TESTS passed=%d failed=%d", passed, failed))
	return table.concat(lines, "\n")
end

return TestRunner
