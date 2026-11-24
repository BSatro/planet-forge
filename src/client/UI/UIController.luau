--!strict
-- UIController — owner: Developer A. Boots the PLANET FORGE interface: data layer, UI root, HUD, panels,
-- evolution screen, onboarding, world interactions and settings application. Each feature initializes in
-- isolation (a failing screen never takes the rest of the UI or gameplay down).
local RunService = game:GetService("RunService")
local UI = script.Parent
local UIRoot = require(UI.UIRoot)
local UIData = require(UI.UIData)
local Hud = require(UI.Hud)

local UIController = {}
local deps: any = {}

local function safe(name: string, fn: () -> ()): boolean
	local ok, err = pcall(fn)
	if not ok then
		warn("[PF][UI] init failed:", name, err)
	end
	return ok
end

local function register(module: Instance?, def: { [string]: any })
	if not module then
		return
	end
	local ok, impl = pcall(require, module)
	if not ok then
		warn("[PF][UI] require failed:", module.Name, impl)
		return
	end
	def.build = impl.build
	if impl.available then
		def.available = impl.available
	end
	if impl.setDeps then
		impl.setDeps(deps)
	end
	UIRoot.registerPanel(def :: any)
end

function UIController.init(d: any?): boolean
	deps = d or {}
	local okCore = safe("data", UIData.init) and safe("root", UIRoot.init)
	if not okCore then
		return false
	end
	local P = UI:FindFirstChild("Panels")
	register(P and P:FindFirstChild("DnaPanel"), { id = "dna", title = "Planet DNA Lab", icon = "dna", hotkey = Enum.KeyCode.L, hotkeyLabel = "L", gamepadKey = Enum.KeyCode.DPadUp })
	register(P and P:FindFirstChild("QuestPanel"), { id = "quests", title = "Quests", icon = "objective", hotkey = Enum.KeyCode.Y, hotkeyLabel = "Y" })
	register(P and P:FindFirstChild("HarvesterPanel"), { id = "harvester", title = "Gravity Harvester", icon = "harvester", hotkey = Enum.KeyCode.H, hotkeyLabel = "H" })
	register(P and P:FindFirstChild("InventoryPanel"), { id = "inventory", title = "Inventory", icon = "inventory", hotkey = Enum.KeyCode.I, hotkeyLabel = "I", gamepadKey = Enum.KeyCode.DPadRight })
	register(P and P:FindFirstChild("CodexPanel"), { id = "codex", title = "Planet Codex", icon = "codex", hotkey = Enum.KeyCode.K, hotkeyLabel = "K", gamepadKey = Enum.KeyCode.DPadLeft })
	register(P and P:FindFirstChild("ExpeditionPanel"), { id = "expedition", title = "Expedition", icon = "expedition", hotkey = Enum.KeyCode.X, hotkeyLabel = "X" })
	register(P and P:FindFirstChild("SocialPanel"), { id = "social", title = "Planets", icon = "planet", hotkey = Enum.KeyCode.P, hotkeyLabel = "P" })
	register(P and P:FindFirstChild("EventsPanel"), { id = "events", title = "Cosmic Events", icon = "star", hotkey = Enum.KeyCode.J, hotkeyLabel = "J" })
	register(P and P:FindFirstChild("StorePanel"), { id = "store", title = "Cosmic Store", icon = "store", hotkey = Enum.KeyCode.B, hotkeyLabel = "B" })
	register(P and P:FindFirstChild("SettingsPanel"), { id = "settings", title = "Settings", icon = "settings", hotkey = Enum.KeyCode.O, hotkeyLabel = "O" })
	safe("hud", Hud.init)
	UIData.Changed:Connect(UIRoot.refreshOpen)
	for _, name in { "SettingsApplier", "EvolutionScreen", "Onboarding", "WorldUI", "RiftHud", "EventHud", "QuestNotifier", "SprintButton" } do
		local mod = UI:FindFirstChild(name)
		if mod then
			safe(name, function()
				local impl = require(mod) :: any
				impl.init(deps)
			end)
		end
	end
	-- world events (input + replaceable effects) and the planet showcase; each isolated
	local Client = UI.Parent
	local Ev = Client:FindFirstChild("Events")
	local So = Client:FindFirstChild("Social")
	for _, mod in { Ev and Ev:FindFirstChild("EventInteract"), Ev and Ev:FindFirstChild("EventFx"), So and So:FindFirstChild("Showcase") } do
		if mod then
			safe(mod.Name, function()
				local impl = require(mod) :: any
				impl.init(deps)
			end)
		end
	end
	if RunService:IsStudio() then
		-- Studio-only test hook (tests run in a separate VM and drive the live UI through this instance)
		local hook = Instance.new("BindableFunction")
		hook.Name = "PF_UITest"
		hook.Archivable = false
		hook.OnInvoke = function(cmd: string, a: any, b: any, c: any)
			if cmd == "open" then
				UIRoot.open(a)
			elseif cmd == "close" then
				UIRoot.close()
			elseif cmd == "toggle" then
				UIRoot.toggle(a)
			elseif cmd == "viewport" then
				UIRoot.relayout(Vector2.new(a, b), c)
			elseif cmd == "realViewport" then
				UIRoot.clearForcedViewport()
			elseif cmd == "toast" then
				UIRoot.toast(a, b)
			elseif cmd == "confirm" then
				UIRoot.confirm({ title = a, body = b, onConfirm = function() end })
			elseif cmd == "closeModal" then
				UIRoot.closeModal()
			elseif cmd == "pref" then
				require(UI.Kit.Prefs).set(a, b)
			elseif cmd == "call" then
				local mod = UI:FindFirstChild(a, true)
				local impl = mod and require(mod) :: any
				return impl and impl[b] and impl[b]()
			end
			return { open = UIRoot.current(), mode = UIRoot.mode(), size = UIRoot.size(), hud = UIRoot.hudVisible(), modal = UIRoot.modalOpen() }
		end
		hook.Parent = UIRoot.gui()
	end
	return true
end

return UIController
