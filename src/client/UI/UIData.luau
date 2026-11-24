--!strict
-- UIData — owner: Developer A. Thin read layer over Developer B's client contracts (ProfileClient,
-- EvolutionClient) for every PLANET FORGE screen. Coalesces change notifications into ONE refresh per frame,
-- formats numbers, and wraps the few actions the UI sends (travel). No game state lives here.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.PF_Shared
local ProfileClient = require(Shared.Client.ProfileClient)
local EvolutionClient = require(Shared.Client.EvolutionClient)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local Signal = require(Shared.Util.Signal)

local player = Players.LocalPlayer
local UIData = {}
UIData.Changed = Signal.new() -- fired at most once per frame after any authoritative change
UIData.HarvestingChanged = Signal.new() -- (operating: boolean)
UIData.Evolution = EvolutionClient
UIData.Profile = ProfileClient

local pending = false
local function schedule()
	if pending then
		return
	end
	pending = true
	task.defer(function()
		pending = false
		UIData.Changed:Fire()
	end)
end

function UIData.snapshot(): any
	return ProfileClient.get()
end

function UIData.slot(): number?
	local s = player:GetAttribute("PF_Slot")
	if type(s) == "number" then
		return s
	end
	local snap = ProfileClient.get()
	return snap and snap.slot
end

function UIData.fmt(n: number?): string
	n = n or 0
	local v = n :: number
	if math.abs(v) >= 1e6 then
		return string.format("%.1fM", v / 1e6)
	elseif math.abs(v) >= 1e4 then
		return string.format("%.1fK", v / 1e3)
	end
	local s = tostring(math.floor(v + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

function UIData.materialDef(id: string): any
	return ItemCatalog.MATERIALS[id]
end
function UIData.materialColor(id: string): Color3
	local d = ItemCatalog.MATERIALS[id]
	return (d and d.iconColor) or Color3.fromRGB(150, 160, 200)
end
function UIData.catalystDef(id: string): any
	return ItemCatalog.CATALYSTS and ItemCatalog.CATALYSTS[id]
end

function UIData.onOwnPlanet(): boolean
	local ok, v = pcall(EvolutionClient.isOnOwnPlanet)
	return ok and v == true
end

-- Travel through the server's warp network (Travel_Warp, validated server-side). dest = slot number | "station"
function UIData.travel(dest: any): (boolean, string)
	local ok, code = ProfileClient.request("Travel_Warp", { destination = dest })
	return ok == true, tostring(code)
end
function UIData.travelHome(): (boolean, string)
	local slot = UIData.slot()
	if not slot then
		return false, "NO_PLANET"
	end
	return UIData.travel(slot)
end

-- Harvest mode is owned by the Cosmic Core Hunt system; its operating HUD being enabled is the public signal.
local harvesting = false
function UIData.isHarvesting(): boolean
	return harvesting
end

function UIData.availableReactions(): number
	local n = 0
	for _, r in EvolutionClient.reactions() do
		if r.available then
			n += 1
		end
	end
	return n
end

function UIData.init()
	pcall(EvolutionClient.init)
	ProfileClient.Changed:Connect(schedule)
	EvolutionClient.Changed:Connect(schedule)
	player:GetAttributeChangedSignal("PF_Slot"):Connect(schedule)
	local pg = player:WaitForChild("PlayerGui")
	local function watch(g: Instance)
		if g.Name == "PF_HarvestHUD" and g:IsA("ScreenGui") then
			local function upd()
				local on = g.Enabled
				if on ~= harvesting then
					harvesting = on
					UIData.HarvestingChanged:Fire(on)
				end
			end
			g:GetPropertyChangedSignal("Enabled"):Connect(upd)
			upd()
		end
	end
	for _, g in pg:GetChildren() do
		watch(g)
	end
	pg.ChildAdded:Connect(watch)
	task.spawn(function()
		ProfileClient.waitForSnapshot(15)
		schedule()
	end)
end

return UIData
