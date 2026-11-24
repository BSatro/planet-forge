--!strict
-- ProfileStore specs (Developer B): session locking, conflicts, retries, failures — against MockDataStore only.
-- Never touches a real data store.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local Data = game:GetService("ServerScriptService").PF_Server.Data
	local ProfileStore = ctx.require(Data.ProfileStore)
	local MockDataStore = ctx.require(Data.MockDataStore)
	local Schema = require(Data.ProfileSchema)

	local FAST = { LOAD_LOCK_RETRIES = 2, LOAD_LOCK_RETRY_DELAY = 0, RELEASE_RETRY_DELAY = 0, SESSION_LOCK_STALE_AFTER = 600 }
	local RETRY = { retries = 2, baseDelay = 0, maxDelay = 0, waitForBudget = false }

	local function server(mock: any, clockRef: { t: number }, job: string)
		return ProfileStore.new({
			backend = mock,
			keyPrefix = "spec_",
			clock = function()
				return clockRef.t
			end,
			config = table.clone(FAST),
			retryOpts = RETRY,
			jobId = job,
			placeId = 1,
		})
	end

	it("new player: default profile, lock written", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local s = server(mock, clk, "A")
		local ok, prof = s:Load(42)
		expect(ok).toBe(true)
		expect(prof.isNew).toBe(true)
		expect(prof.data.currencies.Credits > 0).toBe(true)
		local rec = mock:Peek("spec_42")
		expect(rec.meta.session.id).toBe(prof.sessionId)
		expect(rec.meta.session.jobId).toBe("A")
	end)

	it("returning player: progress persists across release + reload", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local s = server(mock, clk, "A")
		local _, prof = s:Load(7)
		prof.data.currencies.Credits = 1234
		prof.data.planet.dna.Temperature = 77
		prof.data.planet.formations.ThermalCrack = { n = 1, t = 1000 }
		prof.data.reactions.R03 = { n = 1, d = 1000 }
		prof.data.planet.rev = 5
		expect((s:Release(prof))).toBe(true)
		expect(mock:Peek("spec_7").meta.session).toBe(nil)
		clk.t = 2000
		local ok, again = server(mock, clk, "B"):Load(7)
		expect(ok).toBe(true)
		expect(again.isNew).toBe(false)
		expect(again.data.currencies.Credits).toBe(1234)
		expect(again.data.planet.dna.Temperature).toBe(77)
		expect(again.data.planet.formations.ThermalCrack.n).toBe(1)
		expect(again.data.reactions.R03.d).toBe(1000)
		expect(again.data.planet.rev).toBe(5)
		expect(again.data.planet.seed).toBe(prof.data.planet.seed) -- deterministic world seed
		expect(again.data.lastSaveAt).toBe(1000)
	end)

	it("conflict: second server waits, then takes over; old session can no longer save", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local a, b = server(mock, clk, "A"), server(mock, clk, "B")
		local _, pa = a:Load(9)
		pa.data.currencies.Credits = 500
		expect((a:Save(pa))).toBe(true)
		local before = mock.requestCount
		local ok, pb = b:Load(9)
		expect(ok).toBe(true)
		expect(pb.stoleLock).toBe(true)
		expect(mock.requestCount - before).toBe(FAST.LOAD_LOCK_RETRIES + 1) -- waited, then took over
		expect(pb.data.currencies.Credits).toBe(500)
		pa.data.currencies.Credits = 999_999 -- stale server keeps playing
		local okA, codeA = a:Save(pa)
		expect(okA).toBe(false)
		expect(codeA).toBe("LOCK_LOST")
		local okRel, codeRel = a:Release(pa)
		expect(okRel).toBe(false)
		expect(codeRel).toBe("LOCK_LOST")
		expect(mock:Peek("spec_9").data.currencies.Credits).toBe(500)
		expect(mock:Peek("spec_9").meta.session.id).toBe(pb.sessionId)
	end)

	it("stale lock from a crashed server is taken over immediately", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local _ = server(mock, clk, "A"):Load(11) -- never released (crash)
		clk.t = 1000 + FAST.SESSION_LOCK_STALE_AFTER + 1
		local before = mock.requestCount
		local ok, pb = server(mock, clk, "B"):Load(11)
		expect(ok).toBe(true)
		expect(pb.stoleLock).toBe(true)
		expect(mock.requestCount - before).toBe(1)
	end)

	it("same-session double release is harmless", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local s = server(mock, clk, "A")
		local _, p = s:Load(12)
		expect((s:Release(p))).toBe(true)
		local ok, code = s:Release(p)
		expect(ok).toBe(false)
		expect(code).toBe("RELEASED")
	end)

	it("failed requests: transient failures are retried, persistent failures reported", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local s = server(mock, clk, "A")
		mock:FailNext(2) -- RETRY allows 3 attempts
		local ok, p = s:Load(13)
		expect(ok).toBe(true)
		mock:FailNext(100)
		local okSave, code = s:Save(p)
		expect(okSave).toBe(false)
		expect(code).toBe("DATASTORE_ERROR")
		expect(p.lockLost).toBe(false) -- data stays in memory for the next attempt
		mock:FailNext(0)
		expect((s:Save(p))).toBe(true)
		mock:FailNext(100)
		local okLoad, codeLoad = server(mock, clk, "B"):Load(14)
		expect(okLoad).toBe(false)
		expect(codeLoad).toBe("DATASTORE_ERROR")
		mock:FailNext(0)
	end)

	it("non-retryable errors fail fast", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		mock:FailNext(5, "104: Cannot store value")
		local before = mock.requestCount
		local ok = server(mock, clk, "A"):Load(15)
		expect(ok).toBe(false)
		expect(mock.requestCount - before).toBe(1)
	end)

	it("future schema version is refused and left untouched", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		mock:Poke("spec_16", { data = { schemaVersion = Schema.CURRENT_VERSION + 1, level = 30 }, meta = { saveCount = 3 } })
		local ok, code = server(mock, clk, "A"):Load(16)
		expect(ok).toBe(false)
		expect(code).toBe("FUTURE_SCHEMA")
		expect(mock:Peek("spec_16").data.level).toBe(30)
		expect(mock:Peek("spec_16").meta.session).toBe(nil)
	end)

	it("legacy raw (no envelope) and corrupted values load safely", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		mock:Poke("spec_17", { level = 6, currencies = { Credits = 1e300 }, materials = { IceMatter = -5 } })
		local ok, p = server(mock, clk, "A"):Load(17)
		expect(ok).toBe(true)
		expect(p.isNew).toBe(false)
		expect(p.data.level).toBe(6)
		expect(p.data.currencies.Credits).toBe(Schema.capFor("currencies", "Credits"))
		expect(p.data.materials.IceMatter).toBe(0)
	end)

	it("concurrent saves of one profile are serialized", function()
		local mock, clk = MockDataStore.new(), { t = 1000 }
		local s = server(mock, clk, "A")
		local _, p = s:Load(18)
		mock:SetLatency(0.05)
		local done = 0
		for i = 1, 3 do
			task.spawn(function()
				p.data.currencies.Credits = 100 * i
				s:Save(p)
				done += 1
			end)
		end
		local t0 = os.clock()
		while done < 3 and os.clock() - t0 < 5 do
			task.wait()
		end
		mock:SetLatency(0)
		expect(done).toBe(3)
		expect(p.saveCount).toBe(3)
		expect(mock:Peek("spec_18").meta.saveCount).toBe(3)
	end)
end
