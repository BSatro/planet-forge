--!strict
-- Specs for the 8-planet world layout, THE FORGE and planet metadata.
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")
	local WorldLayout = ctx.require(RS.PF_Shared.Config.WorldLayout)
	local GravityFields = ctx.require(RS.PF_Shared.Gravity.GravityFields)
	local StationBuilder = ctx.require(SSS.PF_Server.World.StationBuilder)
	local PlanetBuilder = ctx.require(SSS.PF_Server.World.PlanetBuilder)
	local fields = GravityFields.buildDefault()
	local R = WorldLayout.PLANET_RADIUS

	it("exactly 8 active slots, evenly spaced on a circle", function()
		expect(#WorldLayout.ACTIVE_SLOTS).toBe(8)
		for s = 1, 8 do
			local c = WorldLayout.getSlotCenter(s)
			expect((c - WorldLayout.STATION_CENTER).Magnitude).toBeNear(WorldLayout.ORBIT_RADIUS, 1e-3)
			local n = WorldLayout.getSlotCenter(s % 8 + 1)
			expect((c - n).Magnitude).toBeNear(2 * WorldLayout.ORBIT_RADIUS * math.sin(math.pi / 8), 1e-2)
		end
	end)

	it("planet gravity fields never overlap each other or the station field", function()
		local station = GravityFields.stationField()
		for s = 1, 8 do
			local c = WorldLayout.getSlotCenter(s)
			local infl = R * GravityFields.INFLUENCE_FACTOR
			-- nearest point of the station box to the planet centre
			local d = c - station.center
			local h = station.halfSize :: Vector3
			local q = Vector3.new(math.clamp(d.X, -h.X, h.X), math.clamp(d.Y, -h.Y, h.Y), math.clamp(d.Z, -h.Z, h.Z))
			expect((d - q).Magnitude > infl).toBeTruthy()
		end
	end)

	it("every spawn / arrival / pad is inside the right gravity field at stand height", function()
		local s0 = GravityFields.sample(fields, WorldLayout.getStationSpawn().Position)
		expect(s0.id).toBe("station")
		expect(s0.altitude).toBeNear(3.5, 1e-3)
		for s = 1, 8 do
			local arr = GravityFields.sample(fields, WorldLayout.getStationArrival(s).Position)
			expect(arr.id).toBe("station")
			expect(arr.altitude).toBeNear(3.5, 1e-3)
			local pad = GravityFields.sample(fields, WorldLayout.getStationPadPosition(s) + Vector3.new(0, 3, 0))
			expect(pad.id).toBe("station")
			local ps = GravityFields.sample(fields, WorldLayout.getPlanetSpawn(s).Position)
			expect(ps.id).toBe("planet_" .. s)
			expect(ps.altitude).toBeNear(3.5, 1e-3)
			-- arrival is not on the pad (no immediate re-warp)
			expect((WorldLayout.getStationArrival(s).Position - WorldLayout.getStationPadPosition(s)).Magnitude > 8).toBeTruthy()
		end
	end)

	it("THE FORGE has 8 docks with warp pads at the slot angles, and all required districts", function()
		local st = StationBuilder.build()
		local docks = st:FindFirstChild("Docks") :: Model
		expect(#docks:GetChildren()).toBe(8)
		for s = 1, 8 do
			local d = docks:FindFirstChild("Dock_" .. s) :: Model
			expect(d ~= nil).toBeTruthy()
			local pad = d:FindFirstChild("WarpPad") :: BasePart
			expect(pad:GetAttribute("PFWarpTarget")).toBe(s)
			local flat = pad.Position - WorldLayout.getStationPadPosition(s)
			expect(Vector3.new(flat.X, 0, flat.Z).Magnitude).toBeNear(0, 1e-3)
		end
		local districts = st:FindFirstChild("Districts") :: Model
		for _, name in { "PlanetLab", "MeteorTerminal", "RiftPortal", "CosmeticShop", "PlanetHologram" } do
			expect(districts:FindFirstChild(name) ~= nil).toBeTruthy()
		end
		expect((st:FindFirstChild("Reactor") :: Model):FindFirstChild("Core") ~= nil).toBeTruthy()
		local parts, lights = 0, 0
		for _, x in st:GetDescendants() do
			if x:IsA("BasePart") then
				parts += 1
				expect(x.CanTouch).toBe(false)
			elseif x:IsA("PointLight") then
				lights += 1
				expect(x.Shadows).toBe(false)
			end
		end
		expect(parts <= 800).toBeTruthy()
		expect(lights <= 10).toBeTruthy()
		expect(st.ModelStreamingMode).toBe(Enum.ModelStreamingMode.Persistent)
		st:Destroy()
	end)

	it("every planet starts barren and unclaimed, with a spawn point and LOD split", function()
		for s = 1, 8 do
			local core, detail = PlanetBuilder.build({ slot = s, center = WorldLayout.getSlotCenter(s), radius = R, seed = 7919 + s * 101 })
			expect(core:GetAttribute("PFTheme")).toBe("barren")
			expect(core:GetAttribute("PFOwnerUserId")).toBe(0)
			expect(core:GetAttribute("PFClaimState")).toBe("unclaimed")
			expect(core:GetAttribute("PFSlot")).toBe(s)
			local sp = core:FindFirstChild("SpawnPoint") :: BasePart
			expect(sp ~= nil and sp:GetAttribute("PFSpawnFor") == s).toBeTruthy()
			expect(core.ModelStreamingMode).toBe(Enum.ModelStreamingMode.Persistent)
			expect(detail.ModelStreamingMode).toBe(Enum.ModelStreamingMode.Atomic)
			-- no biome content: only rock-family materials, neon only on the pad
			for _, x in core:GetDescendants() do
				if x:IsA("BasePart") and x.Material == Enum.Material.Neon then
					expect(x.Name == "WarpPad" or x.Name == "WarpPadRing").toBeTruthy()
				end
			end
			for _, x in detail:GetDescendants() do
				if x:IsA("BasePart") then
					local m = x.Material
					expect(m == Enum.Material.Rock or m == Enum.Material.Slate or m == Enum.Material.Basalt).toBeTruthy()
				end
			end
			core:Destroy()
			detail:Destroy()
		end
	end)
end
