--!strict
-- Motion — owner: Developer A. The only place UI tweens are created. Honours reduced motion (instant
-- property changes), cancels the previous tween on the same object+channel so rapid toggling never stacks.
local TweenService = game:GetService("TweenService")
local Theme = require(script.Parent.Theme)
local Prefs = require(script.Parent.Prefs)

local Motion = {}
local running: { [Instance]: { [string]: Tween } } = setmetatable({}, { __mode = "k" }) :: any

function Motion.tween(obj: Instance, t: number?, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?, channel: string?): Tween?
	local ch = channel or "default"
	local perObj = running[obj]
	if perObj and perObj[ch] then
		perObj[ch]:Cancel()
		perObj[ch] = nil
	end
	if Prefs.reducedMotion() or (t or Theme.Motion.base) <= 0 then
		for k, v in props do
			(obj :: any)[k] = v
		end
		return nil
	end
	local tw = TweenService:Create(obj, TweenInfo.new(t or Theme.Motion.base, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	running[obj] = running[obj] or {}
	running[obj][ch] = tw
	tw.Completed:Once(function()
		local p = running[obj]
		if p and p[ch] == tw then
			p[ch] = nil
		end
	end)
	tw:Play()
	return tw
end

-- Counter that animates between integers (resource readouts). Snaps under reduced motion.
function Motion.count(label: TextLabel, from: number, to: number, fmt: (number) -> string)
	if Prefs.reducedMotion() or from == to then
		label.Text = fmt(to)
		return
	end
	local nv = Instance.new("NumberValue")
	nv.Value = from
	nv.Changed:Connect(function(v)
		label.Text = fmt(math.round(v))
	end)
	local tw = TweenService:Create(nv, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Value = to })
	tw.Completed:Once(function()
		label.Text = fmt(to)
		nv:Destroy()
	end)
	tw:Play()
end

return Motion
