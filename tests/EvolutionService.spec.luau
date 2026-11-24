--!strict
-- EvolutionService (server authority) specs: the REAL EvolutionService wired to in-memory stubs of
-- ProfileService / PlanetSlotService / EconomyService (real TransactionCore) / InventoryService /
-- PlanetDataService. Covers locking, idempotency, refunds, ownership and multiplayer isolation.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local Shared = RS.PF_Shared
	local Server = SSS.PF_Server
	local Signal = ctx.require(Shared.Util.Signal)
	local ItemCatalog = ctx.require(Shared.Config.ItemCatalog)
	local Rules = ctx.require(Shared.Evolution.EvolutionRules)
	local Schema = ctx.require(Server.Data.ProfileSchema)
	local TransactionCore = ctx.require(Server.Data.TransactionCore)
	local RealEngine = ctx.require(Server.Evolution.ReactionEngine)
	local HttpService = game:GetService("HttpService")

	local function capFn(section: string, id: string): number
		return Schema.capFor(section, id)
	end

	-- builds a world with the real EvolutionService over stubs; opts.engine overrides ReactionEngine
	local function world(opts: any?): any
		local o = opts or {}
		local W: any = { profiles = {}, slots = {}, onPlanet = {}, notified = {}, saves = 0, handlers = {} }
		local PS: any = { ProfileReleasing = Signal.new() }
		function PS:GetData(p)
			return W.profiles[p]
		end
		function PS:MarkChanged() end
		function PS:SaveNow()
			W.saves += 1
		end
		local Slots: any = {}
		function Slots:GetSlot(p)
			return W.slots[p]
		end
		local Eco: any = {}
		function Eco:Transact(p, tx, _reason, eopts)
			local d = W.profiles[p]
			if not d then
				return false, "NOT_READY", nil
			end
			return TransactionCore.apply(d, tx, capFn, eopts and eopts.overflow)
		end
		function Eco:GrantXp(p, xp)
			if W.xpThrows then
				error("injected GrantXp failure")
			end
			local d = W.profiles[p]
			d.xp = (d.xp or 0) + xp
			return true
		end
		local Inv: any = {}
		function Inv:Unlock(p, section, id)
			W.profiles[p][section][id] = 1
			return true
		end
		local PDS: any = {}
		function PDS:IsOnOwnPlanet(p)
			return W.onPlanet[p] == true
		end
		function PDS:NotifyChanged(p, info)
			table.insert(W.notified, { p = p, info = info })
		end
		function PDS:GetView(p)
			return W.profiles[p] and Rules.viewFromProfile(W.profiles[p])
		end
		local RG = table.clone(ctx.require(Server.Net.RemoteGuard))
		RG.bind = function(name: string, fn: any)
			W.handlers[name] = fn
		end
		local S = Server.Services
		local stubs: any = {
			[S.ProfileService] = PS,
			[S.PlanetSlotService] = Slots,
			[S.EconomyService] = Eco,
			[S.InventoryService] = Inv,
			[S.PlanetDataService] = PDS,
			[Server.Net.RemoteGuard] = RG,
			[Server.Evolution.ReactionEngine] = o.engine or RealEngine,
		}
		local function req(m: any): any
			if stubs[m] ~= nil then
				return stubs[m]
			end
			return ctx.require(m)
		end
		local mod = S.EvolutionService
		local fn = assert(loadstring(mod.Source, "=" .. mod:GetFullName()))
		setfenv(fn, setmetatable({ script = mod, require = req }, { __index = getfenv() }) :: any)
		W.svc = fn()
		W.svc:Start() -- binds the remote handlers into W.handlers (no Instances created)
		function W.add(userId: number, slot: number): any
			local p = { UserId = userId, Name = "P" .. userId }
			W.profiles[p] = Schema.default(1000, userId)
			W.slots[p] = slot
			W.onPlanet[p] = true
			return p
		end
		return W
	end
	local function snap(d: any): string
		return HttpService:JSONEncode({ d.materials, d.currencies, d.planet, d.reactions, d.cosmetics })
	end
	local n = 0
	local function aid(): string
		n += 1
		return "act-" .. n
	end

	it("SVC: an internal error never leaves the player locked (BUSY forever)", function()
		local W = world()
		local A = W.add(101, 1)
		W.xpThrows = true
		local okCall, res1 = pcall(function()
			return table.pack(W.svc:React(A, "R01", { actionId = aid() }))
		end)
		W.xpThrows = false
		local ok2, code2 = W.svc:React(A, "R03", { actionId = aid() })
		expect(code2).toBe("REACTED")
		expect(ok2).toBe(true)
		local _ = okCall and res1
	end)

	it("SVC: a committed reaction is idempotent even if a post-commit step fails", function()
		local W = world()
		local A = W.add(102, 1)
		local d = W.profiles[A]
		d.materials.IceMatter = 60
		local okFirst = W.svc:React(A, "R01", { actionId = aid() })
		expect(okFirst).toBe(true)
		W.xpThrows = true
		local id = aid()
		local ice = d.materials.IceMatter
		pcall(function()
			return W.svc:React(A, "R17", { actionId = id }) -- unlimited tuning: a re-run would charge twice
		end)
		W.xpThrows = false
		local after = d.materials.IceMatter
		expect(after).toBe(ice - 4)
		local okReplay, codeReplay = W.svc:React(A, "R17", { actionId = id })
		expect(okReplay).toBe(true)
		expect(codeReplay).toBe("REACTED")
		expect(d.materials.IceMatter).toBe(after) -- replay did not charge again
		expect(d.reactions.R17.n).toBe(1)
	end)

	it("SVC: a failed apply refunds exactly what was applied (no loss at the material cap)", function()
		local failing = table.clone(RealEngine)
		failing.applyReaction = function()
			error("injected apply failure")
		end
		local W = world({ engine = failing })
		local A = W.add(103, 1)
		local d = W.profiles[A]
		d.materials.MagmaMatter = 50
		d.materials.CosmicCatalyst = Schema.capFor("materials", "CosmicCatalyst") -- R04 rewards +1 Catalyst
		d.reactions.R03 = { n = 1, d = 1 }
		d.planet.dna.Temperature = 60
		local before = snap(d)
		local ok, code = W.svc:React(A, "R04", { actionId = aid() })
		expect(ok).toBe(false)
		expect(code).toBe("INTERNAL_ERROR")
		expect(snap(d)).toBe(before)
		local ok2, code2 = W.svc:React(A, "R03", { actionId = aid() }) -- not locked afterwards
		expect(code2 ~= "BUSY").toBe(true)
		local _ = ok2
	end)

	it("SVC: replaying an actionId returns the cached answer and never runs twice", function()
		local W = world()
		local A = W.add(104, 1)
		local d = W.profiles[A]
		W.svc:React(A, "R01", { actionId = aid() })
		local id = aid()
		local ok1, c1, r1 = W.svc:React(A, "R17", { actionId = id })
		local s = snap(d)
		local ok2, c2, r2 = W.svc:React(A, "R17", { actionId = id })
		expect(ok1 and ok2).toBe(true)
		expect(c1).toBe(c2)
		expect(r1.revision).toBe(r2.revision)
		expect(snap(d)).toBe(s)
		-- an actionId used by a reaction is not reinterpreted as a branch commit (separate namespaces)
		local okB, cB = W.svc:CommitBranch(A, "Volcanic", { actionId = id, confirm = true })
		expect(cB ~= "REACTED").toBe(true)
		local _ = okB
	end)

	it("SVC: ownership, location, stale revision and busy gates (no state change on rejection)", function()
		local W = world()
		local A = W.add(105, 1)
		local B = W.add(106, 2)
		local dA, dB = W.profiles[A], W.profiles[B]
		local sA, sB = snap(dA), snap(dB)
		local _, c1 = W.svc:React(A, "R01", { actionId = aid(), slot = 2 })
		expect(c1).toBe("NOT_OWNER")
		W.onPlanet[A] = false
		local _, c2 = W.svc:React(A, "R01", { actionId = aid() })
		expect(c2).toBe("NOT_ON_PLANET")
		W.onPlanet[A] = true
		local _, c3 = W.svc:React(A, "R01", { actionId = aid(), expectedRevision = 7 })
		expect(c3).toBe("STALE_REVISION")
		local _, c4 = W.svc:CommitBranch(A, "None", { actionId = aid(), confirm = true })
		expect(c4).toBe("BRANCH_UNAVAILABLE") -- you can never "un-specialize" into None
		expect(snap(dA)).toBe(sA)
		expect(snap(dB)).toBe(sB)
		local unknown = { UserId = 999, Name = "ghost" }
		local _, c5 = W.svc:React(unknown, "R01", { actionId = aid() })
		expect(c5).toBe("NOT_READY")
	end)

	it("SVC: two players act independently (state, revisions, locks, caches)", function()
		local W = world()
		local A = W.add(107, 1)
		local B = W.add(108, 2)
		local shared = "same-action-id"
		local okA = W.svc:React(A, "R01", { actionId = shared })
		local okB, codeB = W.svc:React(B, "R03", { actionId = shared }) -- same id, other player: not a replay
		expect(okA).toBe(true)
		expect(okB).toBe(true)
		expect(codeB).toBe("REACTED")
		expect(W.profiles[A].reactions.R03).toBe(nil)
		expect(W.profiles[B].reactions.R01).toBe(nil)
		expect(W.profiles[A].planet.rev).toBe(1)
		expect(W.profiles[B].planet.rev).toBe(1)
		for _, e in W.notified do
			expect(e.info.transformation == nil or string.find(e.info.transformation.id, tostring(e.p.UserId) .. ":", 1, true) == 1).toBe(true)
		end
	end)

	it("SVC: remote payload validation rejects malformed input before any work", function()
		local W = world()
		local A = W.add(109, 1)
		local d = W.profiles[A]
		local s = snap(d)
		local React = W.handlers.Evolution_React
		local Commit = W.handlers.Evolution_Commit
		local Cos = W.handlers.Evolution_Cosmetic
		local bad = {
			{ React, { reactionId = "R01" } },
			{ React, { actionId = "x", reactionId = "R01" } },
			{ React, { actionId = string.rep("a", 41), reactionId = "R01" } },
			{ React, { actionId = "act-ok-1", reactionId = 5 } },
			{ React, { actionId = "act-ok-2", reactionId = "R01", expectedRevision = 0 / 0 } },
			{ React, { actionId = "act-ok-3", reactionId = "R01", expectedRevision = -1 } },
			{ React, { actionId = "act-ok-4", reactionId = "R01", slot = 1.5 } },
			{ React, { actionId = "bad id!", reactionId = "R01" } },
			{ Commit, { actionId = "act-ok-5", branchId = "Volcanic" } },
			{ Commit, { actionId = "act-ok-6", branchId = "Volcanic", confirm = "yes" } },
			{ Cos, { category = "Atmosphere" } },
		}
		for i, case in bad do
			local ok, code = case[1](A, case[2])
			if ok or code ~= "INVALID_PAYLOAD" then
				error("case " .. i .. " -> " .. tostring(code))
			end
		end
		expect(snap(d)).toBe(s)
		-- client-supplied results are ignored
		local ok, code = React(A, { actionId = "act-ok-7", reactionId = "R01", dna = { Water = 100 }, reward = 1e6 })
		expect(ok).toBe(true)
		expect(code).toBe("REACTED")
		expect(d.planet.dna.Water).toBe(10)
	end)

	it("SVC: cosmetics: only owned + matching category; a no-op does not bump the revision", function()
		local W = world()
		local A = W.add(110, 1)
		local d = W.profiles[A]
		local _, c1 = W.svc:SetCosmetic(A, "Atmosphere", "Atmosphere_Ember")
		expect(c1).toBe("NOT_OWNED")
		local _, c2 = W.svc:SetCosmetic(A, "PlanetRing", "Atmosphere_Ember")
		expect(c2).toBe("INVALID_PAYLOAD")
		local _, c3 = W.svc:SetCosmetic(A, "Hat", "None")
		expect(c3).toBe("INVALID_PAYLOAD")
		local rev = d.planet.rev
		local ok4 = W.svc:SetCosmetic(A, "Atmosphere", "None") -- nothing equipped
		expect(ok4).toBe(true)
		expect(d.planet.rev).toBe(rev)
		d.cosmetics.Atmosphere_Ember = 1
		expect((W.svc:SetCosmetic(A, "Atmosphere", "Atmosphere_Ember"))).toBe(true)
		expect(d.planet.cosmetics.Atmosphere).toBe("Atmosphere_Ember")
		expect(d.planet.rev).toBe(rev + 1)
		expect((W.svc:SetCosmetic(A, "Atmosphere", "Atmosphere_Ember"))).toBe(true)
		expect(d.planet.rev).toBe(rev + 1) -- same item again: no change
	end)

	it("SVC: transformations: once per milestone; repeat tuning sends none", function()
		local W = world()
		local A = W.add(111, 1)
		W.profiles[A].materials.IceMatter = 60
		W.svc:React(A, "R01", { actionId = aid() })
		W.svc:React(A, "R17", { actionId = aid() }) -- first discovery -> one transformation
		local before = 0
		for _, e in W.notified do
			if e.info.transformation then
				before += 1
			end
		end
		W.svc:React(A, "R17", { actionId = aid() })
		W.svc:React(A, "R17", { actionId = aid() })
		local after = 0
		for _, e in W.notified do
			if e.info.transformation then
				after += 1
			end
		end
		expect(before).toBe(2)
		expect(after).toBe(2)
		expect(#W.notified).toBe(4) -- the planet still notifies (snapshot/visual DNA update)
	end)
end
