--!strict
-- Planet scale rework (2026-11-23): radius invariants, FormationDensity (DNA-driven counts), scaled site plan and
-- deterministic, add-only growth of the renderer's clusters. Pure + Edit-mode Instances (never parented).
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SP = game:GetService("StarterPlayer")
	local Shared = RS.PF_Shared
	local WorldLayout = ctx.require(Shared.Config.WorldLayout)
	local GravityFields = ctx.require(Shared.Gravity.GravityFields)
	local EvolutionConfig = ctx.require(Shared.Config.EvolutionConfig)
	local Registry = ctx.require(Shared.Evolution.FormationRegistry)
	local Density = ctx.require(Shared.Planet.FormationDensity)
	local Art = ctx.require(SP.StarterPlayerScripts.PF_Client.Planet.FormationArt)
	local R = WorldLayout.PLANET_RADIUS

	it("RADIUS: 8 planets on the ring keep gravity, 'on planet' and LOD ranges apart", function()
		expect(R).toBe(160)
		local spacing = (WorldLayout.getSlotCenter(1) - WorldLayout.getSlotCenter(2)).Magnitude
		expect(2 * R * GravityFields.INFLUENCE_FACTOR < spacing).toBe(true) -- gravity fields never overlap
		expect(R * EvolutionConfig.ACTIONS.ON_PLANET_RADIUS_FACTOR < spacing / 2).toBe(true)
		local toStation = (WorldLayout.getSlotCenter(1) - WorldLayout.STATION_CENTER).Magnitude
		expect(toStation - R * GravityFields.INFLUENCE_FACTOR > WorldLayout.DOCK_OUTER_RADIUS + 200).toBe(true)
	end)

	it("SCALE: tiers keep their hierarchy; nothing is taller than a quarter of the radius", function()
		local last = 0
		for tier = 1, 6 do
			local s = Density.TIER_SCALE[tier]
			expect(s >= last and s < 1).toBe(true)
			last = s
		end
		for id, def in Registry.DEFS do
			local h = (def.height or 6) * Density.scaleFor(def)
			if h > R * 0.25 then
				error(id .. " is " .. h .. " studs tall on a " .. R .. "-stud planet")
			end
		end
		-- capstones still read as the biggest things on the world
		expect(Registry.DEFS.WorldTree.height * Density.scaleFor(Registry.DEFS.WorldTree) > Registry.DEFS.FirstForest.height * Density.scaleFor(Registry.DEFS.FirstForest) * 3).toBe(true)
	end)

	it("DENSITY: purchase seeds a small cluster; DNA grows it monotonically, bounded, never down", function()
		local forest = Registry.DEFS.FirstForest
		-- buying vegetation right after unlocking (Life ~27) gives a handful of trees, not a forest
		local e0 = Density.elements(forest, 1, { Life = 27 })
		expect(e0 >= 2 and e0 <= 3).toBe(true)
		expect((Density.elements(forest, 1, { Life = 60 })) > e0).toBe(true)
		for id, s in Density.SPEC do
			local def = Registry.DEFS[id]
			expect(def ~= nil).toBe(true)
			expect(s.lo >= 1 and s.hi >= s.lo and s.maxSites >= 1).toBe(true)
			for owned = 1, def.maxCount do
				local prev = -1
				local prevLayout = nil
				for v = 0, 100 do
					local dna = { [s.dna] = v }
					local e = Density.elements(def, owned, dna)
					expect(e >= prev).toBe(true) -- monotonic in DNA
					expect(e <= Density.maxElements(def)).toBe(true) -- bounded
					expect(e >= math.min(owned * s.lo, Density.maxElements(def))).toBe(true)
					local layout = Density.layout(def, owned, dna)
					local sum = 0
					for i, c in layout do
						sum += c.elements
						if prevLayout and prevLayout[i] then
							expect(c.elements >= prevLayout[i].elements).toBe(true) -- a cluster never loses elements
						end
					end
					expect(sum).toBe(e)
					expect(#layout <= s.maxSites).toBe(true)
					prev, prevLayout = e, layout
				end
			end
			-- more purchases never show less
			expect((Density.elements(def, def.maxCount, { [s.dna] = 50 })) >= (Density.elements(def, 1, { [s.dna] = 50 }))).toBe(true)
		end
		-- unique / landmark formations keep maxCount as the hard cap
		expect(#Density.layout(Registry.DEFS.WorldTree, 5, { Life = 100 })).toBe(1)
		expect(#Density.layout(Registry.DEFS.CelestialFlora, 1, {})).toBe(1)
		-- worst case per planet stays bounded (budget): every density formation maxed
		local total = 0
		for id in Density.SPEC do
			total += Density.maxElements(Registry.DEFS[id])
		end
		expect(total <= 90).toBe(true)
	end)

	it("VARIETY: higher DNA unlocks more variants (never fewer)", function()
		local a, b, c = #Density.variants("trees", 0), #Density.variants("trees", 0.5), #Density.variants("trees", 1)
		expect(a <= b and b <= c and c == 3).toBe(true)
		expect(#Density.variants("crystals", 1)).toBe(4)
	end)

	local function planetFor(slot: number, seed: number): any
		local center = WorldLayout.getSlotCenter(slot)
		local p = { seed = seed, slot = slot, center = center, R = R, theme = "living", quality = "full" }
		p.blocked = Art.blockedFor(slot, center, nil, R)
		return p
	end

	it("SITES: deterministic, footprints never overlap, pad / spawn / harvester corridor stay clear (8 slots)", function()
		for slot = 1, 8 do
			local p = planetFor(slot, 1000 + slot * 7)
			local a, b = Art.sitePlan(p), Art.sitePlan(p)
			local list = {}
			for key, site in a do
				expect(b[key].dir:Dot(site.dir) > 0.999999).toBe(true)
				table.insert(list, site)
			end
			local overlaps, blockedHits = 0, 0
			for i = 1, #list do
				for j = i + 1, #list do
					local ang = math.acos(math.clamp(list[i].dir:Dot(list[j].dir), -1, 1))
					if ang < (list[i].ang + list[j].ang) * 0.9 then
						overlaps += 1
					end
				end
				for _, bz in p.blocked do
					local ang = math.acos(math.clamp(list[i].dir:Dot(bz.dir), -1, 1))
					if ang < bz.ang + list[i].ang * 0.9 then
						blockedHits += 1
					end
				end
			end
			expect(overlaps).toBe(0)
			expect(blockedHits).toBe(0)
			-- every density formation has all of its growth sites reserved up front
			for id, s in Density.SPEC do
				for i = 1, s.maxSites do
					expect(a[id .. "#" .. i] ~= nil).toBe(true)
				end
			end
		end
	end)

	it("RENDER: same state -> same model; DNA growth only ADDS trees; scaled art hugs the real sphere", function()
		local p = planetFor(3, 424242)
		local plan = Art.sitePlan(p)
		local def = Registry.DEFS.FirstForest
		local function build(elements: number, level: number): any
			return Art.build(p, def, 1, plan["FirstForest#1"], { elements = elements, level = level })
		end
		local function trees(rec: any): { CFrame }
			local out = {}
			for _, m in rec.model:GetChildren() do
				if m:IsA("Model") then
					table.insert(out, m:GetPivot())
				end
			end
			return out
		end
		local a, b = build(3, 0.1), build(3, 0.1)
		local ta, tb = trees(a), trees(b)
		expect(#ta).toBe(3)
		for i = 1, #ta do
			expect((ta[i].Position - tb[i].Position).Magnitude < 1e-3).toBe(true)
		end
		local c = build(6, 0.1)
		local tc = trees(c)
		expect(#tc).toBe(6)
		for i = 1, 3 do
			expect((ta[i].Position - tc[i].Position).Magnitude < 1e-3).toBe(true) -- the first trees did not move
		end
		-- every tree base sits on the real planet surface (within 1 stud), i.e. nothing floats after scaling
		for _, cf in tc do
			local h = (cf.Position - p.center).Magnitude - R
			expect(h > -1.5 and h < 1).toBe(true)
		end
		expect(math.abs(c.scale - Density.scaleFor(def)) < 1e-9).toBe(true)
		for _, rec in { a, b, c } do
			rec.model:Destroy()
		end
	end)

	it("COST: every DNA-grown formation builds at every site; extra spread copies are lean (no particles / lights)", function()
		local p = planetFor(5, 777)
		local plan = Art.sitePlan(p)
		for id, s in Density.SPEC do
			local def = Registry.DEFS[id]
			local first
			for i = 1, s.maxSites do
				local site = plan[id .. "#" .. i]
				local ok, rec = pcall(Art.build, p, def, i, site, { elements = (s.perCluster or 1), level = 1 })
				expect(ok).toBe(true) -- a builder that errors at a satellite site would silently drop features
				if ok and rec then
					local parts = 0
					for _, d in rec.model:GetDescendants() do
						if d:IsA("BasePart") then
							parts += 1
						end
					end
					if i == 1 then
						first = parts
					elseif s.mode == "spread" then
						expect(#rec.emitters).toBe(0)
						expect(#rec.lights).toBe(0)
						expect(parts <= first).toBe(true)
					end
					rec.model:Destroy()
				end
			end
		end
	end)
end
