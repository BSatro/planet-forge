--!strict
-- StoreEntry — owner: Monetization (client boot). Starts StoreClient + CosmeticsFX, shows purchase results as
-- toasts and adds the "Open Cosmic Store" prompt at THE FORGE's cosmetic shop. The store is only ever opened by
-- the player (prompt, dock button, B) — never automatically.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MonetizationConfig = require(ReplicatedStorage:WaitForChild("PF_Shared").Config.MonetizationConfig)
local StoreClient = require(script.Parent.StoreClient)
local CosmeticsFX = require(script.Parent.CosmeticsFX)

local StoreEntry = {}
local started = false
local player = Players.LocalPlayer

local function uiRoot(): any
	local ui = script.Parent.Parent:FindFirstChild("UI")
	local m = ui and ui:FindFirstChild("UIRoot")
	if not m then
		return nil
	end
	local ok, r = pcall(require, m)
	return if ok then r else nil
end

local function toast(text: string, kind: string, icon: string)
	local r = uiRoot()
	if r and r.toast then
		r.toast(text, kind, icon)
	end
end

local function itemName(key: string): string
	local p = MonetizationConfig.pass(key) or MonetizationConfig.product(key)
	return if p then p.name else key
end

local function shopPrompt()
	local world = Workspace:WaitForChild("PF_World", 60)
	local station = world and world:WaitForChild("Station", 60)
	local districts = station and station:WaitForChild("Districts", 30)
	local shop = districts and districts:WaitForChild("CosmeticShop", 30)
	if not shop then
		return
	end
	local anchorPart = (shop :: any).PrimaryPart or shop:FindFirstChildWhichIsA("BasePart", true)
	if not anchorPart then
		return
	end
	local att = Instance.new("Attachment")
	att.Name = "PF_StorePromptAtt"
	att.WorldPosition = (shop :: Model):GetPivot().Position + Vector3.new(0, 4, 0)
	att.Parent = anchorPart
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "PF_StorePrompt"
	pp.ActionText = "Open Cosmic Store"
	pp.ObjectText = "Cosmetics"
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.HoldDuration = 0
	pp.MaxActivationDistance = 14
	pp.RequiresLineOfSight = false
	pp.Parent = att
	pp.Triggered:Connect(function()
		local r = uiRoot()
		if r and r.open then
			r.open("store")
		end
	end)
end

function StoreEntry.init()
	if started then
		return
	end
	started = true
	StoreClient.init()
	CosmeticsFX.init()
	StoreClient.Notified:Connect(function(msg: any)
		if msg.kind == "passGranted" then
			toast(itemName(msg.key) .. " unlocked — thank you! Equip it under Cosmic Store › Appearance.", "success", "star")
		elseif msg.kind == "productGranted" then
			toast(itemName(msg.key) .. " added. Launching around your planet when possible.", "success", "star")
		elseif msg.kind == "cancelled" then
			toast("Purchase cancelled — nothing was charged.", "info", "info")
		end
	end)
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 30)
		local ev = remotes and remotes:WaitForChild("Store_Celebration", 30) :: RemoteEvent?
		if ev then
			ev.OnClientEvent:Connect(function(msg)
				if type(msg) == "table" and msg.ownerUserId == player.UserId then
					toast("Cosmic Fireworks are lighting up your planet!", "success", "star")
				end
			end)
		end
	end)
	task.spawn(shopPrompt)
end

return StoreEntry
