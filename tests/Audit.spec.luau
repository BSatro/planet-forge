--!strict
-- Adversarial audit specs: realistic reachability (every reaction + mastery from real play), branch
-- switching between every pair, load/save drift, and planet reconstruction after a rejoin on another slot
-- through Developer A's (read-only) visual contract.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local Shared = RS.PF_Shared
	local Server = SSS.PF_Server
	local HttpService = game:GetService("HttpService")
	local ItemCatalog = ctx.require(Shared.Config.ItemCatalog)
	local Registry = ctx.require(Shared.Evolution.ReactionRegistry)
	local Rules = ctx.require(Shared.Evolution.EvolutionRules)
	local Signal = ctx.require(Shared.Util.Signal)
	local Engine = ctx.require(Server.Evolution.ReactionEngine)
	local Sim = ctx.require(Server.Evolution.PlanetProgressionSimulator)
	local Schema = ctx.require(Server.Data.ProfileSchema)
	local TransactionCore = ctx.require(Server.Data.TransactionCore)
	local ProfileStore = ctx.require(Server.Data.ProfileStore)
	local MockDataStore = ctx.require(Server.Data.MockDataStore)
	local BRANCHES = { "Living", "Frozen", "Volcanic", "Crystal" }

	local function capFn(section: string, id: string): number
		return Schema.capFor(section, id)
	end
	local function rich(p: any)
		for id in ItemCatalog.MATERIALS do
			p.materials[id] = Schema.capFor("materials", id)
		end
		p.currencies.Credits = 1e6
	end
	local clock = 5000
	local function execute(p: any, id: string): boolean
		local ok, _, plan = Engine.planReaction(p, id)
		if not ok then
			return false
		end
		local okTx = TransactionCore.apply(p, plan.tx, capFn, "clamp")
		if not okTx then
			return false
		end
		clock += 1
		Engine.applyReaction(p, plan, clock)
		Engine.evaluateProgress(p, clock)
		return true
	end
	local function commit(p: any, b: string): boolean
		local ok, _, plan = Engine.planBranch(p, b, true)
		if not ok then
			return false
		end
		if not TransactionCore.apply(p, plan.tx, capFn, "clamp") then
			return false
		end
		clock += 1
		Engine.applyBranch(p, plan, clock)
		Engine.evaluateProgress(p, clock)
		return true
	end
	local function deepCopy(t: any): any
		if type(t) ~= "table" then
			return t
		end
		local o = {}
		for k, v in t do
			o[k] = deepCopy(v)
		end
		return o
	end
	local function deepEq(a: any, b: any, path: string?): (boolean, string?)
		path = path or ""
		if type(a) ~= type(b) then
			return false, path .. " type " .. type(a) .. "~=" .. type(b)
		end
		if type(a) ~= "table" then
			return a == b, path .. " " .. tostring(a) .. "~=" .. tostring(b)
		end
		for k, v in a do
			local ok, w = deepEq(v, b[k], (path :: string) .. "." .. tostring(k))
			if not ok then
				return false, w
			end
		end
		for k in b do
			if a[k] == nil then
				return false, (path :: string) .. "." .. tostring(k) .. " missing"
			end
		end
		return true, nil
	end

	-- distance of a view to a condition table (DNA gaps, formations, prerequisites, own completions)
	local function dist(view: any, cond: any, selfId: string): number
		local d = 0
		for param, r in cond.dna or {} do
			local v = view.dna[param]
			if r.min and v < r.min then
				d += r.min - v
			end
			if r.max and v > r.max then
				d += v - r.max
			end
		end
		for fid, need in cond.formations or {} do
			local have = view.formations[fid] or 0
			if have < need then
				d += (need - have) * 20
			end
		end
		for _, rid in cond.discovered or {} do
			if not Rules.isDiscovered(view, rid) then
				d += 40
			end
		end
		if cond.completions then
			local have = Rules.completions(view, selfId)
			if have < cond.completions then
				d += (cond.completions - have) * 15
			end
		end
		return d
	end
	-- the view after doing reaction `st` (no mutation)
	local function viewAfter(view: any, st: any): any
		local v = table.clone(view)
		v.dna = st.dnaAfter
		v.formations = table.clone(view.formations)
		for _, g in st.formationGains do
			v.formations[g.id] = g.to
		end
		v.codex = table.clone(view.codex)
		local rec = v.codex[st.id]
		v.codex[st.id] = { n = (rec and rec.n or 0) + 1, d = 1 }
		return v
	end
	-- greedy "player": works on every reachable discovery and mastery of branch `b`
	local function completionist(p: any, b: string): (number, { string })
		local function eligible(id: string): boolean
			local br = Registry.DEFS[id].requires.branch
			return br == nil or br == b
		end
		local targets = {}
		for _, id in Registry.ORDER do
			if eligible(id) then
				table.insert(targets, { kind = "d", id = id })
			end
		end
		for _, id in Registry.ORDER do
			if eligible(id) and Registry.DEFS[id].mastery then
				table.insert(targets, { kind = "m", id = id })
			end
		end
		local function done(t: any): boolean
			local rec = p.reactions[t.id]
			return if t.kind == "d" then (rec ~= nil and rec.d ~= nil) else (rec ~= nil and rec.m ~= nil)
		end
		local steps = 0
		for _pass = 1, 6 do
			local progressed = false
			for _, t in targets do
				for _ = 1, 60 do
					if done(t) then
						break
					end
					rich(p)
					local view = Rules.viewFromProfile(p)
					if t.kind == "d" and Rules.reactionStatus(view, t.id).available then
						if execute(p, t.id) then
							steps += 1
							progressed = true
						end
						continue
					end
					local def = Registry.DEFS[t.id]
					local cond = if t.kind == "d" then def.requires else (def.mastery and def.mastery.requires or {})
					if t.kind == "m" and not Rules.isDiscovered(view, t.id) then
						break
					end
					local d0 = dist(view, cond, t.id)
					local best, bestD = nil, d0
					for _, id in Registry.ORDER do
						local st = Rules.reactionStatus(view, id)
						if st.available then
							local d1 = dist(viewAfter(view, st), cond, t.id)
							if d1 < bestD then
								best, bestD = id, d1
							end
						end
					end
					if not best then
						break
					end
					if execute(p, best) then
						steps += 1
						progressed = true
					else
						break
					end
				end
			end
			if not progressed then
				break
			end
		end
		local missing = {}
		for _, t in targets do
			if not done(t) then
				table.insert(missing, t.kind .. ":" .. t.id)
			end
		end
		return steps, missing
	end

	it("AUDIT: every reaction AND every mastery is reachable through real play on some branch", function()
		local discovered, mastered = {}, {}
		local report = {}
		for _, b in BRANCHES do
			local r = Sim.run(b)
			expect(r.stuck).toBe(false)
			local p = r.profile
			local _, missing = completionist(p, b)
			for id, rec in p.reactions do
				if rec.d then
					discovered[id] = true
				end
				if rec.m then
					mastered[id] = true
				end
			end
			table.insert(report, b .. " missing: " .. table.concat(missing, ","))
		end
		local lostD, lostM = {}, {}
		for _, id in Registry.ORDER do
			if not discovered[id] then
				table.insert(lostD, id)
			end
			if Registry.DEFS[id].mastery and not mastered[id] then
				table.insert(lostM, id)
			end
		end
		if #lostD > 0 or #lostM > 0 then
			error("unreachable discoveries: " .. table.concat(lostD, ",") .. " | masteries: " .. table.concat(lostM, ",") .. "\n" .. table.concat(report, "\n"))
		end
	end)

	it("AUDIT: every branch can switch to every other branch and back (no dead ends, no re-paid milestones)", function()
		for _, from in BRANCHES do
			for _, to in BRANCHES do
				if from ~= to then
					local p = Sim.run(from).profile
					expect(p.planet.stage).toBe(4)
					local s4 = p.planet.stageAt.s4
					local r = Sim.runFrom(p, to, { allowRespec = true, maxMinutes = 400 })
					if r.stuck then
						error(from .. " -> " .. to .. " stuck at stage " .. r.finalStage .. " branch " .. r.branch)
					end
					expect(p.planet.stageAt.s4).toBe(s4) -- the Stage-4 milestone was not paid a second time
					-- switching back (meeting that branch's DNA rules again) restores Stage 4 at once: capstone kept
					local back = Sim.runFrom(p, from, { allowRespec = true, maxMinutes = 400 })
					if back.stuck then
						error(to .. " -> back to " .. from .. " stuck at stage " .. back.finalStage)
					end
					expect(p.planet.stage).toBe(4)
					expect(p.planet.stageAt.s4).toBe(s4)
					expect(p.planet.branchLog.respecs).toBe(2)
				end
			end
		end
	end)

	it("AUDIT: saving and loading never changes a live planet (no drift), also through JSON", function()
		for seed = 1, 12 do
			local p = Sim.fuzz(seed * 977, 20 + seed)
			local live = deepCopy(p)
			local loaded = Schema.reconcile(HttpService:JSONDecode(HttpService:JSONEncode(deepCopy(p))), 99999, seed * 977)
			local ok1, w1 = deepEq(loaded.planet, live.planet, "planet")
			local ok2, w2 = deepEq(loaded.reactions, live.reactions, "reactions")
			if not ok1 or not ok2 then
				error("seed " .. seed .. " drift: " .. tostring(w1 or w2))
			end
			-- and a second load is a fixed point
			local again = Schema.reconcile(deepCopy(loaded), 123456, seed * 977)
			expect((deepEq(again.planet, loaded.planet))).toBe(true)
		end
	end)

	it("AUDIT: a rejoining player's planet is reconstructed identically on a different slot", function()
		-- real PlanetDataService over stubbed profile/slot services
		local W: any = { data = {}, slots = {} }
		local PS: any = { ProfileReleasing = Signal.new(), ProfileLoaded = Signal.new() }
		function PS:GetData(pl)
			return W.data[pl]
		end
		function PS:MarkChanged() end
		local Slots: any = {}
		function Slots:GetSlot(pl)
			return W.slots[pl]
		end
		function Slots:GetOwner(slot)
			for pl, s in W.slots do
				if s == slot then
					return pl
				end
			end
			return nil
		end
		local S = Server.Services
		local stubs: any = { [S.ProfileService] = PS, [S.PlanetSlotService] = Slots }
		local function req(m: any): any
			return if stubs[m] ~= nil then stubs[m] else ctx.require(m)
		end
		local mod = S.PlanetDataService
		local fn = assert(loadstring(mod.Source, "=" .. mod:GetFullName()))
		setfenv(fn, setmetatable({ script = mod, require = req }, { __index = getfenv() }) :: any)
		local PDS = fn()
		local Contract = ctx.require(Shared.Planet.PlanetVisualContract)
		local VisualProfile = ctx.require(Shared.Planet.PlanetVisualProfile)

		-- a played planet with history: Volcanic stage 4, then switched to Crystal (dormant landmarks)
		local mock = MockDataStore.new()
		local clk = { t = 10000 }
		local function store()
			return ProfileStore.new({ backend = mock, keyPrefix = "rj_", clock = function() return clk.t end, config = { LOAD_LOCK_RETRIES = 1, LOAD_LOCK_RETRY_DELAY = 0, RELEASE_RETRY_DELAY = 0 }, retryOpts = { retries = 1, baseDelay = 0, waitForBudget = false }, jobId = "J" })
		end
		local userId = 424242
		local s1 = store()
		local _, prof = s1:Load(userId)
		local played = Sim.run("Volcanic").profile
		Sim.runFrom(played, "Crystal", { allowRespec = true, maxMinutes = 400 })
		rich(played)
		commit(played, "Volcanic") -- back to Volcanic: Crystal landmarks dormant now
		prof.data.planet = deepCopy(played.planet)
		prof.data.reactions = deepCopy(played.reactions)
		prof.data.planet.seed = played.planet.seed
		local player = { UserId = userId, DisplayName = "Rejoiner", Name = "Rejoiner" }
		W.data[player], W.slots[player] = prof.data, 1
		local before = PDS:GetPlanetState(player)
		expect(#before.dormant > 0).toBe(true)
		expect((s1:Release(prof))).toBe(true)

		clk.t += 600 -- rejoin later, another server, another slot
		local okLoad, prof2 = store():Load(userId)
		expect(okLoad).toBe(true)
		W.data[player], W.slots[player] = prof2.data, 5
		local after = PDS:GetPlanetState(player)
		for _, k in { "stage", "branch", "theme", "seed", "rev", "discovered", "respecs" } do
			if before[k] ~= after[k] then
				error("field " .. k .. ": " .. tostring(before[k]) .. " -> " .. tostring(after[k]))
			end
		end
		for _, k in { "dna", "formations", "dormant", "cosmetics", "ownedFormations", "stageAt" } do
			local ok, w = deepEq(before[k], after[k], k)
			if not ok then
				error("field " .. tostring(w))
			end
		end
		expect(after.slot).toBe(5)
		-- Developer A's pipeline (read only): same spec apart from the slot
		local specA = VisualProfile.build(Contract.normalize(1, before))
		local specB = VisualProfile.build(Contract.normalize(5, after))
		expect(specA.seed).toBe(specB.seed)
		expect(specA.theme).toBe(specB.theme)
		expect(specA.stage).toBe(specB.stage)
		expect(specA.landmark).toBe(specB.landmark)
		expect((deepEq(specA.formationCounts, specB.formationCounts))).toBe(true)
	end)
end
