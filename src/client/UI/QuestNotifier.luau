--!strict
-- QuestNotifier — owner: Live Gameplay. Small, non-intrusive quest feedback from the Profile_Snapshot `quests` view:
--   * a toast when a quest becomes complete ("claim it in Quests (Y)")
--   * one toast per session at join if rewards are waiting
-- The dock badge (Hud) shows the number of claimable quests.
local Kit = script.Parent.Kit
local _Theme = require(Kit.Theme)
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)

local QuestNotifier = {}
local known: { [string]: boolean }? = nil -- "day:D_Capture" -> complete, from the previous snapshot

local function scan(q: any): { [string]: { title: string, complete: boolean } }
	local out = {}
	for _, kind in { "day", "week" } do
		local v = q[kind]
		for _, e in (v and v.list) or {} do
			out[kind .. ":" .. e.id] = { title = e.title, complete = e.complete and not e.claimed }
		end
	end
	return out
end

local function onChanged()
	local snap = UIData.snapshot()
	local q = snap and snap.quests
	if not q or not q.day then
		return
	end
	local now = scan(q)
	if known == nil then
		known = {}
		if (q.claimable or 0) > 0 then
			UIRoot.toast(string.format("%d quest reward%s waiting — open Quests (Y)", q.claimable, if q.claimable == 1 then " is" else "s are"), "reward")
		end
	else
		for key, e in now do
			if e.complete and not (known :: any)[key] then
				UIRoot.toast("Quest complete: " .. e.title .. " — claim it in Quests (Y)", "success")
			end
		end
	end
	local k = {}
	for key, e in now do
		k[key] = e.complete
	end
	known = k
end

function QuestNotifier.init(_deps: any?)
	UIData.Changed:Connect(function()
		local ok, err = pcall(onChanged)
		if not ok then
			warn("[PF][Quests] notifier: " .. tostring(err))
		end
	end)
	task.defer(onChanged)
end

return QuestNotifier
