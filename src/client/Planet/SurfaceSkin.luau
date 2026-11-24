--!strict
-- SurfaceSkin — owner: Planet Physics 3.0. Makes the VISIBLE planet surface match the COLLISION surface.
-- Root cause it fixes: Roblox draws a Ball part as a coarse faceted mesh (about 20 segments around) while its
-- collision is a perfect sphere. At planet scale (R = 160) the flat facets sit up to ~2 studs INSIDE the true
-- sphere, so characters standing correctly on the collision surface looked like they hovered, and every formation /
-- rock placed on the true sphere floated a little over the facet middles.
-- The skin is a client-side, high-resolution sphere drawn exactly at the collision radius. Source, in order:
--   1) ReplicatedStorage.PF_Assets.Meshes.PlanetSkinSphere: a MeshPart template (Creator Store mesh, 9800 tris,
--      ~0.08 stud chord error at R = 160). Works everywhere, no special permission.
--   2) fallback: a generated EditableMesh (needs Experience Settings > Security > "Allow Mesh / Image APIs").
-- The server Core keeps collision and queries (physics, ground raycasts, camera) and is only hidden locally
-- (LocalTransparencyModifier), and only after the skin's mesh has loaded. Material, colour, transparency,
-- reflectance, size and position are mirrored from the Core, so PlanetVisualController's recolours and its stage-up
-- colour tween keep working. The generated fallback also swaps distant planets to a low-resolution skin.
local AssetService = game:GetService("AssetService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SurfaceSkin = {}

local HI = { lon = 128, lat = 64 } -- 16k triangles, max chord error R*(1-cos(pi/128)) = 0.05 studs at R = 160
local LO = { lon = 48, lat = 24 } -- far LOD
local LOD_DISTANCE = 900
local MIRROR = { "Color", "Material", "MaterialVariant", "Transparency", "Reflectance", "CastShadow" }

local meshes: { [string]: any } = {}
local skins: { [Model]: any } = {}
local folder: Folder? = nil
local available: boolean? = nil

-- unit sphere (diameter 1) with smooth normals and equirectangular UVs (u wraps once around, v pole to pole)
local function buildSphere(spec: { lon: number, lat: number }): any
	local em = AssetService:CreateEditableMesh()
	local verts: { [number]: { number } } = {}
	local normals: { [number]: { number } } = {}
	for j = 0, spec.lat do
		local theta = j / spec.lat * math.pi -- 0 (north) .. pi (south)
		local y = math.cos(theta)
		local r = math.sin(theta)
		verts[j] = {}
		normals[j] = {}
		for i = 0, spec.lon - 1 do
			local phi = i / spec.lon * 2 * math.pi
			local n = Vector3.new(r * math.cos(phi), y, r * math.sin(phi))
			if (j == 0 or j == spec.lat) and i > 0 then
				verts[j][i] = verts[j][0] -- one vertex per pole
				normals[j][i] = normals[j][0]
			else
				verts[j][i] = em:AddVertex(n * 0.5)
				normals[j][i] = em:AddNormal(n)
			end
		end
	end
	local uvs: { [number]: { number } } = {}
	for j = 0, spec.lat do
		uvs[j] = {}
		for i = 0, spec.lon do
			uvs[j][i] = em:AddUV(Vector2.new(i / spec.lon, j / spec.lat))
		end
	end
	for j = 0, spec.lat - 1 do
		for i = 0, spec.lon - 1 do
			local i2 = (i + 1) % spec.lon
			local a, b = verts[j][i], verts[j][i2]
			local c, d = verts[j + 1][i], verts[j + 1][i2]
			local na, nb, nc, nd = normals[j][i], normals[j][i2], normals[j + 1][i], normals[j + 1][i2]
			local ua, ub, uc, ud = uvs[j][i], uvs[j][i + 1], uvs[j + 1][i], uvs[j + 1][i + 1]
			-- front faces point outward (Roblox culls the other side; verified visually)
			if j > 0 then
				local f = em:AddTriangle(a, c, b)
				em:SetFaceNormals(f, { na, nc, nb })
				em:SetFaceUVs(f, { ua, uc, ub })
			end
			if j < spec.lat - 1 then
				local f = em:AddTriangle(b, c, d)
				em:SetFaceNormals(f, { nb, nc, nd })
				em:SetFaceUVs(f, { ub, uc, ud })
			end
		end
	end
	return em
end

local function mesh(kind: string): any
	if not meshes[kind] then
		meshes[kind] = buildSphere(if kind == "hi" then HI else LO)
	end
	return meshes[kind]
end

local function template(): MeshPart?
	local assets = ReplicatedStorage:FindFirstChild("PF_Assets")
	local meshes = assets and assets:FindFirstChild("Meshes")
	local t = meshes and meshes:FindFirstChild("PlanetSkinSphere")
	return if t and t:IsA("MeshPart") then t else nil
end

local function newPart(kind: string): MeshPart?
	local tpl = template()
	if tpl then
		if kind ~= "hi" then
			return nil -- one mesh asset, no separate far LOD needed
		end
		local p = tpl:Clone()
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Name = "PlanetSkin_" .. kind
		return p
	end
	local ok, part = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh(kind)))
	end)
	if not ok or not part then
		warn("[PF] SurfaceSkin: mesh unavailable (" .. tostring(part) .. ") - keeping the default planet rendering")
		return nil
	end
	local p = part :: MeshPart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Name = "PlanetSkin_" .. kind
	return p
end

local function sync(s: any)
	local core: BasePart = s.core
	for _, part in { s.hi, s.lo } do
		if part then
			for _, prop in MIRROR do
				local ok, v = pcall(function()
					return (core :: any)[prop]
				end)
				if ok then
					pcall(function()
						(part :: any)[prop] = v
					end)
				end
			end
			part.Size = core.Size
			part.CFrame = core.CFrame
		end
	end
end

-- both skins stay parented for their whole life (re-parenting a part whose mesh comes from an EditableMesh
-- left it unrendered in testing); the inactive one is hidden locally instead
local function setLod(s: any, far: boolean)
	if s.far == far or not s.lo then
		return
	end
	s.far = far
	s.hi.LocalTransparencyModifier = if far then 1 else 0
	s.lo.LocalTransparencyModifier = if far then 0 else 1
end

function SurfaceSkin.attach(model: Model)
	if skins[model] or available == false then
		return
	end
	local core = model:FindFirstChild("Core")
	if not core or not core:IsA("Part") or core.Shape ~= Enum.PartType.Ball then
		return
	end
	if not folder then
		local root = Workspace:FindFirstChild("PF_ClientFX") or Instance.new("Folder")
		root.Name = "PF_ClientFX"
		root.Parent = Workspace
		local f = Instance.new("Folder")
		f.Name = "PlanetSkins"
		f.Parent = root
		folder = f
	end
	local hi = newPart("hi")
	if not hi then
		available = false
		return
	end
	available = true
	local lo = newPart("lo")
	local s: any = { core = core, hi = hi, lo = lo, far = nil, conns = {}, ready = false }
	skins[model] = s
	hi.Name = "Skin_" .. model.Name
	if lo then
		lo.Name = "SkinFar_" .. model.Name
	end
	sync(s)
	hi.Parent = folder
	if lo then
		lo.Parent = folder
	end
	setLod(s, false)
	-- hide the coarse Ball only once the skin's mesh is really there (never a frame without a planet)
	task.spawn(function()
		local okLoad = pcall(function()
			ContentProvider:PreloadAsync({ hi })
		end)
		if skins[model] ~= s then
			return
		end
		local meshId = (hi :: any).MeshId
		local status = if type(meshId) == "string" and meshId ~= "" then ContentProvider:GetAssetFetchStatus(meshId) else Enum.AssetFetchStatus.Success
		if okLoad and status == Enum.AssetFetchStatus.Success then
			s.ready = true
			core.LocalTransparencyModifier = 1 -- the coarse Ball stays for physics/raycasts, the skin is drawn instead
		else
			warn("[PF] SurfaceSkin: skin mesh failed to load - keeping the default planet rendering")
			SurfaceSkin.detach(model)
		end
	end)
	for _, prop in { "Color", "Material", "MaterialVariant", "Transparency", "Reflectance", "Size", "CFrame", "CastShadow" } do
		table.insert(s.conns, core:GetPropertyChangedSignal(prop):Connect(function()
			sync(s)
		end))
	end
	table.insert(s.conns, core:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
		if s.ready and core.LocalTransparencyModifier ~= 1 then
			core.LocalTransparencyModifier = 1
		end
	end))
	table.insert(s.conns, core.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			SurfaceSkin.detach(model)
		end
	end))
end

function SurfaceSkin.detach(model: Model)
	local s = skins[model]
	if not s then
		return
	end
	skins[model] = nil
	for _, c in s.conns do
		c:Disconnect()
	end
	if s.hi then
		s.hi:Destroy()
	end
	if s.lo then
		s.lo:Destroy()
	end
	if s.core and s.core.Parent then
		s.core.LocalTransparencyModifier = 0
	end
end

function SurfaceSkin.stats(): any
	local n = 0
	for _ in skins do
		n += 1
	end
	return { planets = n, available = available, source = if template() then "template" else "editablemesh" }
end

-- distance LOD (cheap: 2 Hz)
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.5 then
		return
	end
	acc = 0
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local p = cam.CFrame.Position
	for _, s in skins do
		local d = (s.core.Position - p).Magnitude - s.core.Size.X / 2
		setLod(s, d > LOD_DISTANCE)
	end
end)

return SurfaceSkin
