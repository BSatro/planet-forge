--!strict
-- Specs for WorldLayout, GravityFields and PlanetBuilder (pure / deterministic parts).
return function(ctx: any)
	local it, expect = ctx.it, ctx.expect
	local RS = game:GetService("ReplicatedStorage")
	local WorldLayout = ctx.require(RS.PF_Shared.Config.WorldLayout)
	local GravityFields = ctx.require(RS.PF_Shared.Gravity.GravityFields)
	local PlanetBuilder = ctx.require(game:GetService("ServerScriptService").PF_Server.World.PlanetBuilder)
	local fields = GravityFields.buildDefault()
	local c1 = WorldLayout.getSlotCenter(1)
	local R = WorldLayout.PLANET_RADIUS

	it("8 slots are distinct, non-overlapping and above FallenPartsDestroyHeight", function()
		for i = 1, 8 do
			local a = WorldLayout.getSlotCenter(i)
			expect(a.Y - R > -500).toBeTruthy()
			for j = i + 1, 8 do
				local b = WorldLayout.getSlotCenter(j)
				expect((a - b).Magnitude > 2 * R * GravityFields.INFLUENCE_FACTOR).toBeTruthy()
			end
		end
	end)

	it("invalid slots are rejected", function()
		expect(function() WorldLayout.getSlotCenter(0) end).toThrow()
		expect(function() WorldLayout.getSlotCenter(9) end).toThrow()
		expect(function() WorldLayout.getSlotCenter(1.5) end).toThrow()
	end)

	it("frameFromUp is orthonormal with UpVector == normal for many normals incl. poles", function()
		local normals = { Vector3.yAxis, -Vector3.yAxis, Vector3.xAxis, Vector3.new(0.3, -0.9, 0.2).Unit, Vector3.new(0, 0.9999, 0.001).Unit }
		for _, n in normals do
			local f = WorldLayout.frameFromUp(n, 1.2)
			expect(f.UpVector:Dot(n)).toBeNear(1, 1e-5)
			expect(f.RightVector:Dot(f.UpVector)).toBeNear(0, 1e-5)
			expect(f.RightVector:Cross(f.UpVector):Dot(-f.LookVector)).toBeNear(1, 1e-5) -- right-handed
		end
	end)

	it("planet field: up is the radial normal on top, side and bottom", function()
		for _, n in { Vector3.yAxis, Vector3.xAxis, -Vector3.yAxis, Vector3.new(-1, -1, 1).Unit } do
			local s = GravityFields.sample(fields, c1 + n * (R + 3))
			expect(s.kind).toBe("planet")
			expect(s.up:Dot(n)).toBeNear(1, 1e-5)
			expect(s.altitude).toBeNear(3, 1e-4)
		end
	end)

	it("station field is uniform +Y above the deck", function()
		local s = GravityFields.sample(fields, WorldLayout.getStationSpawn().Position)
		expect(s.kind).toBe("uniform")
		expect(s.up).toBe(Vector3.yAxis)
		expect(s.altitude).toBeNear(3.5, 1e-4)
	end)

	it("between station and planet is space; NaN is space", function()
		local mid = (WorldLayout.STATION_CENTER + c1) / 2
		expect(GravityFields.sample(fields, mid).kind).toBe("space")
		expect(GravityFields.sample(fields, Vector3.new(0 / 0, 0, 0)).kind).toBe("space")
		expect(GravityFields.sample(fields, c1).kind).toBe("space") -- exact centre has no direction
	end)

	it("planet spawn lies on the surface with up == normal", function()
		local cf = WorldLayout.getPlanetSpawn(1)
		local s = GravityFields.sample(fields, cf.Position)
		expect(s.altitude).toBeNear(3.5, 1e-3)
		expect(cf.UpVector:Dot(s.up)).toBeNear(1, 1e-5)
	end)

	it("PlanetBuilder is deterministic and within the part budget", function()
		local p = { slot = 1, center = c1, radius = R, seed = 42 }
		local a, ad = PlanetBuilder.build(p)
		local b, bd = PlanetBuilder.build(p)
		ad.Parent = a
		bd.Parent = b
		local pa, pb = a:GetDescendants(), b:GetDescendants()
		expect(#pa).toBe(#pb)
		local parts = 0
		for i, d in pa do
			if d:IsA("BasePart") then
				parts += 1
				expect((d.Position - (pb[i] :: BasePart).Position).Magnitude).toBeNear(0, 1e-4)
			end
		end
		expect(parts <= 340).toBeTruthy()
		local core = a:FindFirstChild("Core") :: Part
		expect(core.Shape).toBe(Enum.PartType.Ball)
		expect(core.Size.X).toBe(2 * R)
		a:Destroy()
		b:Destroy()
	end)

	it("only the core and boulders are queryable (ground probe ignores decoration)", function()
		local m, md = PlanetBuilder.build({ slot = 1, center = c1, radius = R, seed = 7 })
		md.Parent = m
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") and d.CanQuery then
				expect(d.Name == "Core" or d.Name == "Spire" or d.Name:match("^Boulder_") ~= nil).toBeTruthy()
			end
		end
		m:Destroy()
	end)
end
