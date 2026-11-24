--!strict
-- Onboarding — owner: Developer A; First 10 Minutes 2.0 extensions (UX). The ONE onboarding system.
-- Seamless first-session guidance with NO mandatory text screens:
--   1 reach your planet  2 capture your first meteor  3 trigger a reaction  4 see the planet transform
-- Each step is derived from real, server-persisted state (location, stats.harvests, discoveries, formations), so
-- returning players skip what they've done and a rejoin / respawn / device switch resumes at the right step.
-- Guidance = objective card (Hud) + world marker (WorldUI) + pulsing dock button + ForgeBot lines.
-- First 10 Minutes 2.0:
--   * welcome intro (first session only: loginCount 1, nothing harvested or discovered): short skippable orbit
--     of the player's own planet + one title line; reduced motion = title only, no camera move
--   * ForgeBot (UI.ForgeBot) speaks on real events only: arriving home, entering the harvester, a server-
--     confirmed capture / miss, a confirmed reaction, a stage-up. Never on a timer; each line once per session.
--   * step 3 knows whether the first reaction is affordable (else: "collect N more X" with progress)
--   * first own reaction: short framed camera reveal of the new formation (skippable, never under reduced motion)
--   * after onboarding: next stage goal + up to three "next discoveries" from real availability (no promises:
--     locked recipes are never shown as available)
--   * Replay tutorial (Settings): plays the intro and the guide lines again; progress is never reset
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local UIRoot = require(script.Parent.UIRoot)
local UIData = require(script.Parent.UIData)
local Hud = require(script.Parent.Hud)
local ForgeBot = require(script.Parent.ForgeBot)
local Kit = script.Parent.Kit
local Theme = require(Kit.Theme)
local C = require(Kit.Components)
local Motion = require(Kit.Motion)
local Prefs = require(Kit.Prefs)
local Shared = ReplicatedStorage.PF_Shared
local WorldLayout = require(Shared.Config.WorldLayout)

local Col, Sp, S, F = Theme.Color, Theme.Space, Theme.Size, Theme.Font
local player = Players.LocalPlayer
local Onboarding = {}
local deps: any = {}
local visitedOwnPlanet = false
local transformSeenAt: number? = nil
local finished = false
local lastStep = -1
local lastOnPlanet = false
local introDone = false
local introPlaying = false
local revealActive = false
local availSeen: { [string]: boolean }? = nil
local lastAvailSay = 0
local intro: any = {}

local function WorldUI(): any
	local m = script.Parent:FindFirstChild("WorldUI")
	local ok, mod = pcall(require, m :: ModuleScript)
	return if ok then mod else nil
end

local function discoveries(snap: any): number
	local n = 0
	for _ in (snap and snap.reactions) or {} do
		n += 1
	end
	if n == 0 then
		local cx = UIData.Evolution.codex()
		n = cx.discovered or 0
	end
	return n
end

local function formationCount(snap: any): number
	local n = 0
	for _ in (snap and snap.planet and snap.planet.formations) or {} do
		n += 1
	end
	return n
end

local function openLab(reactionId: string?)
	local P = script.Parent:FindFirstChild("Panels")
	local ok, Dna = pcall(require, P and P:FindFirstChild("DnaPanel") :: ModuleScript)
	if ok and Dna and Dna.focusReaction then
		Dna.focusReaction(reactionId)
	end
	UIRoot.open("dna")
end

local function showHarvester()
	if UIData.onOwnPlanet() then
		local w = WorldUI()
		if w then
			w.pointTo("harvester")
		end
	else
		task.spawn(UIData.travelHome)
	end
end

-- the first reaction the player can do now, else the closest one they can save up for (never a locked one)
local function reactionGoal(): any
	local best, bestFrac = nil, -1
	for _, r in UIData.Evolution.reactions() do
		if r.available then
			return { reaction = r, ready = true }
		end
		if r.status == "NEEDS_MATERIALS" then
			local have, need = 0, 0
			local short: any = nil
			for _, c in r.costs or {} do
				have += math.min(c.have, c.need)
				need += c.need
				if not c.ok and not short then
					short = c
				end
			end
			local frac = if need > 0 then have / need else 0
			if frac > bestFrac then
				best, bestFrac = { reaction = r, ready = false, short = short, frac = frac }, frac
			end
		end
	end
	return best
end

-- up to three optional next steps, from real availability only
local function nextDiscoveries(): { any }
	local out = {}
	local n = 0
	for _, r in UIData.Evolution.reactions() do
		if r.available and n < 2 then
			n += 1
			table.insert(out, { icon = "flask", color = Col.Success, text = "Trigger " .. r.name, sub = r.headline or "Ready in the DNA Lab", action = function()
				openLab(r.id)
			end })
		end
	end
	local goal = reactionGoal()
	if goal and not goal.ready and goal.short and #out < 3 then
		local c = goal.short
		table.insert(out, { icon = "matter", color = Col.Cyan, text = string.format("Collect %s for %s", c.name, goal.reaction.name), sub = string.format("%d / %d · capture meteors at your harvester", c.have, c.need), action = showHarvester })
	end
	if #out < 3 then
		for _, b in UIData.Evolution.branches() do
			if b.available then
				table.insert(out, { icon = "planet", color = Col.Magenta, text = "Choose a specialization: " .. (b.name or b.id), sub = b.headline or "Shape what your world becomes", action = function()
					openLab(nil)
				end })
				break
			end
		end
	end
	if #out < 3 and UIRoot.isAvailable("expedition") then
		table.insert(out, { icon = "expedition", color = Col.Gold, text = "Launch an expedition", sub = "Send a probe for rare matter", action = function()
			UIRoot.open("expedition")
		end })
	end
	while #out > 3 do
		table.remove(out)
	end
	return out
end

local function stageObjective()
	local st = UIData.Evolution.stage()
	if not st then
		return nil
	end
	if not st.next then
		return { icon = "star", title = "Your world is fully evolved", detail = "Master reactions in the Codex and show your planet to visitors.", actionText = "Open Codex", action = function() UIRoot.open("codex") end, discoveries = nextDiscoveries() }
	end
	local unmet = st.next.unmet or {}
	local have, need = 0, 0
	for _, u in unmet do
		if type(u) == "table" and type(u.have) == "number" and type(u.need) == "number" and u.need > 0 then
			have += math.min(u.have, u.need)
			need += u.need
		end
	end
	local texts = st.next.unmetTexts or {}
	return {
		icon = "planet",
		title = "Evolve into " .. (st.next.name or "the next stage"),
		detail = if texts[1] then texts[1] .. (if #texts > 1 then string.format("  (+%d more)", #texts - 1) else "") else (st.next.goal or ""),
		progress = if need > 0 then have / need else nil,
		actionText = "Open DNA Lab",
		action = function() UIRoot.open("dna") end,
		discoveries = nextDiscoveries(),
	}
end

----------------------------------------------------------------------------------------------------
-- welcome intro (first session only, or Replay)
local function introInput(input: InputObject, processed: boolean)
	if not introPlaying and not revealActive then
		return
	end
	local k = input.KeyCode
	if k == Enum.KeyCode.ButtonB or k == Enum.KeyCode.ButtonA or k == Enum.KeyCode.Space or k == Enum.KeyCode.Return then
		introPlaying = false
		revealActive = false
	elseif revealActive and not processed and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
		revealActive = false
	end
end

local function buildIntro()
	if intro.root then
		return
	end
	local layer = UIRoot.layer("Toast")
	local root = C.make("Frame", { Name = "WelcomeIntro", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Active = false, Parent = layer })
	local top = C.make("Frame", { Name = "BarTop", BackgroundColor3 = Col.Void, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.09, 0), Position = UDim2.fromScale(0, -0.09), Parent = root })
	local bottom = C.make("Frame", { Name = "BarBottom", BackgroundColor3 = Col.Void, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Size = UDim2.new(1, 0, 0.09, 0), Position = UDim2.fromScale(0, 1.09), Parent = root })
	local holder = C.make("Frame", { Name = "Title", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.84, 0), Size = UDim2.fromOffset(720, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = root }, { C.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center) })
	intro.kicker = C.text({ text = "", size = S.Small, font = F.Display, color = Col.Cyan, align = Enum.TextXAlignment.Center, parent = holder, order = 1, dims = UDim2.new(1, 0, 0, 18) })
	intro.title = C.text({ text = "WELCOME TO PLANET FORGE", size = 30, font = F.Display, color = Col.Text, align = Enum.TextXAlignment.Center, parent = holder, order = 2, dims = UDim2.new(1, 0, 0, 40) })
	intro.title.TextScaled = true
	C.make("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 16, Parent = intro.title })
	intro.title.TextStrokeTransparency = 0.6
	intro.sub = C.text({ text = "This world is yours. Let's bring it to life.", size = 22, font = F.Semi, color = Col.TextDim, align = Enum.TextXAlignment.Center, parent = holder, order = 3, dims = UDim2.new(1, 0, 0, 30) })
	intro.sub.TextStrokeTransparency = 0.7
	local skip = C.button({ text = "Skip", icon = "chevron", style = "ghost", dims = UDim2.fromOffset(110, 34), parent = root, onClick = function()
		introPlaying = false
	end })
	skip.Instance.AnchorPoint = Vector2.new(1, 1)
	skip.Instance.Position = UDim2.new(1, -Sp.l, 1, -Sp.l)
	skip.Instance.ZIndex = 5
	intro.root, intro.top, intro.bottom, intro.holder, intro.skip = root, top, bottom, holder, skip
	intro.scale = C.make("UIScale", { Parent = holder })
end

local function finishIntro()
	introPlaying = false
	if deps.camera and deps.camera.isShowcase and deps.camera.isShowcase() then
		deps.camera.clearShowcase()
	end
	if intro.root then
		if Prefs.reducedMotion() then
			intro.root.Visible = false
		else
			Motion.tween(intro.top, 0.3, { Position = UDim2.fromScale(0, -0.09) }, nil, nil, "intro")
			Motion.tween(intro.bottom, 0.3, { Position = UDim2.fromScale(0, 1.09) }, nil, nil, "intro")
			Motion.tween(intro.title, 0.25, { TextTransparency = 1 }, nil, nil, "introT")
			Motion.tween(intro.sub, 0.25, { TextTransparency = 1 }, nil, nil, "introS")
			task.delay(0.32, function()
				intro.root.Visible = false
			end)
		end
	end
	UIRoot.setHudHidden("intro", false)
end

local update: () -> ()

local function playIntro(replay: boolean?)
	if introPlaying or revealActive then
		return
	end
	local slot = UIData.slot()
	if not slot then
		return
	end
	introDone = true
	introPlaying = true
	buildIntro()
	local reduced = Prefs.reducedMotion()
	intro.kicker.Text = string.format("PLANET %02d · YOUR WORLD", slot)
	intro.title.TextTransparency, intro.sub.TextTransparency = 0, 0
	intro.root.Visible = true
	UIRoot.setHudHidden("intro", true)
	if reduced then
		intro.top.Position = UDim2.fromScale(0, 0)
		intro.bottom.Position = UDim2.fromScale(0, 1)
	else
		Motion.tween(intro.top, 0.45, { Position = UDim2.fromScale(0, 0) }, nil, nil, "intro")
		Motion.tween(intro.bottom, 0.45, { Position = UDim2.fromScale(0, 1) }, nil, nil, "intro")
		intro.scale.Scale = 0.92
		Motion.tween(intro.scale, 0.6, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, "introScale")
		if deps.camera and deps.camera.setShowcase then
			deps.camera.setShowcase(WorldLayout.getSlotCenter(slot), WorldLayout.PLANET_RADIUS)
		end
		UIRoot.sfx("Whoosh", 0.35, 0.8)
	end
	task.spawn(function()
		local t0 = os.clock()
		local length = if reduced then 3 else 5.5
		while introPlaying and os.clock() - t0 < length do
			task.wait(0.05)
		end
		finishIntro()
		task.wait(0.3)
		if replay and finished then
			ForgeBot.say("Quick tour: capture meteors at your Gravity Harvester to collect cosmic matter.", { id = "tour1", mood = "point", priority = 2 })
			ForgeBot.say("Spend matter in the DNA Lab — every reaction reshapes your planet.", { id = "tour2", mood = "happy", priority = 2 })
			ForgeBot.say("Every world can evolve differently: Living, Frozen, Volcanic or Crystal. Yours is up to you!", { id = "tour3", mood = "celebrate", priority = 2 })
		else
			ForgeBot.say("That's your planet! Let's bring it to life.", { id = "intro_planet", mood = "happy", priority = 2 })
		end
		update()
	end)
end

----------------------------------------------------------------------------------------------------
-- first own reaction: short framed reveal of the new formation (skippable; never under reduced motion)
local function formationPoint(slot: number, fid: string?): (Vector3, Vector3)
	local center = WorldLayout.getSlotCenter(slot)
	local R = WorldLayout.PLANET_RADIUS
	local dir: Vector3? = nil
	local fx = Workspace:FindFirstChild("PF_ClientFX")
	local pv = fx and fx:FindFirstChild("PlanetVisuals")
	local folder = pv and pv:FindFirstChild("Formations_" .. slot)
	if folder and fid then
		for _, d in folder:GetDescendants() do
			if d:IsA("Model") and d:GetAttribute("PFFormation") == fid then
				dir = (d:GetPivot().Position - center).Unit
				break
			end
		end
	end
	if not dir then
		local cam = Workspace.CurrentCamera
		dir = if cam then (cam.CFrame.Position - center).Unit else Vector3.yAxis
	end
	local up = dir :: Vector3
	return center + up * (R + 3), up
end

local function reveal(t: any)
	local slot = UIData.slot()
	if not slot or revealActive or introPlaying then
		return
	end
	UIRoot.sfx("Discovery_Reveal")
	ForgeBot.say("Look at your planet! You created that!", { id = "first_reaction", mood = "celebrate", priority = 3 })
	if Prefs.reducedMotion() or not (deps.camera and deps.camera.setShowcase) or not UIData.onOwnPlanet() then
		return
	end
	revealActive = true
	task.delay(0.2, function()
		if not revealActive then
			return
		end
		local fid = t and t.formations and t.formations[1]
		-- the formation layer builds the new model when the published revision lands: wait for it briefly
		local point, up = formationPoint(slot, fid)
		local fx = Workspace:FindFirstChild("PF_ClientFX")
		local waited = 0
		while waited < 1.2 do
			local pv = fx and fx:FindFirstChild("PlanetVisuals")
			local folder = pv and pv:FindFirstChild("Formations_" .. slot)
			local found = false
			if folder and fid then
				for _, d in folder:GetDescendants() do
					if d:IsA("Model") and d:GetAttribute("PFFormation") == fid then
						found = true
						break
					end
				end
			end
			if found then
				point, up = formationPoint(slot, fid)
				break
			end
			task.wait(0.1)
			waited += 0.1
		end
		if not revealActive then
			return
		end
		deps.camera.setShowcase(point, 15, up)
		UIRoot.setHudHidden("reveal", true)
		local t0 = os.clock()
		while revealActive and os.clock() - t0 < 3.6 do
			task.wait(0.05)
		end
		revealActive = false
		if deps.camera.isShowcase and deps.camera.isShowcase() then
			deps.camera.clearShowcase()
		end
		UIRoot.setHudHidden("reveal", false)
	end)
end

----------------------------------------------------------------------------------------------------
local function stepLine(step: number, onPlanet: boolean, goal: any)
	if step == 1 then
		ForgeBot.say("Your planet is waiting! Tap Travel now, or step on your dock pad here on the Forge.", { id = "s1", group = "step", mood = "point", actionText = "Travel now", action = function()
			task.spawn(UIData.travelHome)
		end })
	elseif step == 2 then
		if onPlanet then
			ForgeBot.say("Welcome home! Your Gravity Harvester pulls cosmic matter from passing meteors — follow the marker.", { id = "s2", group = "step", mood = "point", actionText = "Show me", action = showHarvester })
		else
			ForgeBot.say("Head back to your planet — your Gravity Harvester is there.", { id = "s2_away", group = "step", mood = "point", actionText = "Travel home", action = function()
				task.spawn(UIData.travelHome)
			end })
		end
	elseif step == 3 and goal then
		if goal.ready then
			ForgeBot.say(string.format("Now let's transform your world! Trigger %s in the DNA Lab.", goal.reaction.name), { id = "s3_ready", group = "step", mood = "happy", priority = 2, actionText = "Open DNA Lab", action = function()
				openLab(goal.reaction.id)
			end })
		elseif goal.short then
			ForgeBot.say(string.format("Almost there: %s needs %d %s (you have %d). Capture another meteor!", goal.reaction.name, goal.short.need, goal.short.name, goal.short.have), { id = "s3_need", group = "step", mood = "point" })
		end
	end
end

update = function()
	local snap = UIData.snapshot()
	if not snap then
		return
	end
	local slot = UIData.slot()
	local onPlanet = UIData.onOwnPlanet()
	if onPlanet then
		visitedOwnPlanet = true
	end
	local harvests = (snap.stats and snap.stats.harvests) or 0
	local disc = discoveries(snap)
	local forms = formationCount(snap)
	local stage = (snap.planet and snap.planet.stage) or 0
	-- first session only (loginCount is server-counted; nil on an older server -> no intro). Decided once, when
	-- both the slot and the profile counters are known (a slow profile load never skips it).
	if not introDone and slot and type(snap.loginCount) == "number" then
		introDone = true
		if not finished and harvests == 0 and disc == 0 and snap.loginCount <= 1 then
			playIntro(false)
		end
	end
	if introPlaying then
		return
	end
	local done1 = visitedOwnPlanet or harvests > 0 or disc > 0
	local done2 = harvests > 0 or disc > 0
	local done3 = disc > 0
	local done4 = finished or stage >= 1 or disc >= 2 or (forms > 0 and transformSeenAt ~= nil and os.clock() - transformSeenAt > 5)
	local w = WorldUI()
	local step, o = 0, nil
	local goal = nil
	if not done1 then
		step = 1
		o = { icon = "travel", title = string.format("Reach your planet%s", if slot then string.format(" — PLANET %02d", slot) else ""), detail = "Step on its dock pad on THE FORGE, or travel there directly.", actionText = "Travel now", action = function()
			task.spawn(UIData.travelHome)
		end }
		if w and slot then
			w.pointTo("stationPad")
		end
	elseif not done2 then
		step = 2
		o = { icon = "harvester", title = "Capture your first meteor", detail = if onPlanet then "Walk to your Gravity Harvester and operate it. Lock on, charge, and release on the <b>green</b> band." else "Return to your planet to use your Gravity Harvester.", actionText = if onPlanet then "Show the way" else "Travel home", action = showHarvester }
		if w then
			w.pointTo(if onPlanet then "harvester" else "stationPad")
		end
	elseif not done3 then
		step = 3
		goal = reactionGoal()
		if goal and not goal.ready and goal.short then
			local c = goal.short
			o = { icon = "matter", title = "Collect matter for your first reaction", detail = string.format("<b>%s</b> needs %s %d — you have %d. Capture more meteors at your harvester.", goal.reaction.name, c.name, c.need, c.have), progress = goal.frac, actionText = if onPlanet then "Show the way" else "Travel home", action = showHarvester }
		else
			local r = goal and goal.reaction
			local costText = ""
			if r then
				local parts = {}
				for _, c in r.costs or {} do
					table.insert(parts, string.format("%s %d", c.name, c.need))
				end
				costText = if #parts > 0 then "  ·  Cost: " .. table.concat(parts, ", ") else ""
			end
			o = { icon = "dna", title = if r then "Trigger your first reaction: " .. r.name else "Trigger your first reaction", detail = (if r and r.headline then r.headline else "Open the DNA Lab and use your matter to transform the planet.") .. costText, actionText = "Open DNA Lab", action = function()
				openLab(r and r.id)
			end }
		end
		if w then
			w.clear()
		end
	elseif not done4 then
		step = 4
		o = { icon = "formation", title = "Watch your planet transform", detail = "Look around — your first formation has appeared. Every reaction reshapes your world.", progress = if transformSeenAt then math.clamp((os.clock() - transformSeenAt) / 5, 0, 1) else 0 }
		if w then
			w.clear()
		end
		if not transformSeenAt and forms > 0 then
			transformSeenAt = os.clock()
		end
		task.delay(1, update)
	else
		local justFinished = not finished and lastStep > 0
		if not finished then
			ForgeBot.dropGroup("step")
		end
		if justFinished then
			UIRoot.toast("Training complete — keep evolving your world!", "reward")
			ForgeBot.say("Every world can evolve differently. Try new reactions — your choices shape your planet!", { id = "finale", mood = "celebrate", priority = 2 })
		end
		finished = true
		o = stageObjective()
		if w and lastStep > 0 then
			w.clear()
		end
		-- a reaction became available during play: a soft cue + one line (rate-limited)
		local now = {}
		for _, r in UIData.Evolution.reactions() do
			if r.available then
				now[r.id] = true
				if availSeen and not availSeen[r.id] and os.clock() - lastAvailSay > 60 then
					lastAvailSay = os.clock()
					UIRoot.sfx("Discovery_Reveal", 0.18, 1.3)
					ForgeBot.say(string.format("New reaction ready: %s! Find it in the DNA Lab.", r.name), { id = "avail_" .. r.id, mood = "happy", actionText = "Open DNA Lab", action = function()
						openLab(r.id)
					end })
				end
			end
		end
		availSeen = now
	end
	if step > 0 then
		o.step = step
		o.total = 4
	end
	-- step lines: once per session, when the step is entered (or the player arrives home during step 2)
	if step ~= lastStep or (step == 2 and onPlanet and not lastOnPlanet) then
		stepLine(step, onPlanet, goal)
	end
	lastOnPlanet = onPlanet
	Hud.pulse(if step == 3 and goal and goal.ready then "dna" else nil, step == 3)
	local advanced = lastStep > 0 and (step > lastStep or (step == 0 and lastStep > 0))
	Hud.setObjective(o, { completed = advanced })
	lastStep = step
end

----------------------------------------------------------------------------------------------------
local function hookHarvest()
	local H = script.Parent.Parent:FindFirstChild("Harvest")
	local m = H and H:FindFirstChild("HarvestController")
	local ok, HC = pcall(require, m :: ModuleScript)
	if not ok or not HC or not HC.Events then
		return
	end
	HC.Events:Connect(function(kind: string, info: any)
		info = info or {}
		if kind == "enter" and info.tutorial then
			ForgeBot.say("See that glowing meteor with the target ring? Let's capture it! Grey rocks far away are just scenery.", { id = "h_enter", mood = "point", priority = 2 })
		elseif kind == "miss" and info.tutorial and (info.misses or 0) == 1 then
			ForgeBot.say("So close! Hold to charge, then release when the ring sits inside the green band.", { id = "h_miss", mood = "point", priority = 2 })
		elseif kind == "capture" then
			if info.first then
				ForgeBot.say("Great shot! You collected cosmic matter!", { id = "h_first", mood = "celebrate", priority = 3 })
			elseif info.perfect then
				ForgeBot.say("PERFECT capture! Timing it on the bright band gives a ×1.5 bonus.", { id = "h_perfect", mood = "celebrate", priority = 2 })
			end
		end
	end)
end

function Onboarding.init(d: any?)
	deps = d or {}
	ForgeBot.init()
	UIData.Changed:Connect(update)
	UIData.Evolution.Transformation:Connect(function(ev: any)
		if type(ev) ~= "table" or ev.ownerUserId ~= player.UserId then
			return
		end
		local t = ev.transformation or ev
		local snap = UIData.snapshot()
		local disc = discoveries(snap)
		if not transformSeenAt and not finished then
			transformSeenAt = os.clock()
			task.delay(5.2, update)
			if t.formations and #t.formations > 0 and disc <= 1 then
				reveal(t) -- the very first reaction
			end
		end
		if (t.stageTo or 0) > (t.stageFrom or 0) then
			local st = UIData.Evolution.stage()
			ForgeBot.say(string.format("Stage up! Your world is now %s.", (st and st.name) or "evolving"), { id = "stage_" .. tostring(t.stageTo), mood = "celebrate", priority = 2 })
		end
	end)
	hookHarvest()
	UserInputService.InputBegan:Connect(introInput)
	-- WorldUI clears its marker on every respawn: restore the current step's guidance afterwards
	player.CharacterAdded:Connect(function()
		task.delay(1, update)
	end)
	-- location changes (warps / walking) are not data changes: poll lightly
	task.spawn(function()
		local last = nil
		while true do
			task.wait(1)
			local now = UIData.onOwnPlanet()
			if now ~= last then
				last = now
				update()
			end
		end
	end)
	-- returning player: one relevant hint, a few seconds in (never during onboarding steps)
	task.delay(6, function()
		local snap = UIData.snapshot()
		if finished and snap and type(snap.loginCount) == "number" and snap.loginCount > 1 then
			local list = nextDiscoveries()
			local first = list[1]
			ForgeBot.say(if first then "Welcome back! Next up: " .. first.text .. "." else "Welcome back! Your world is waiting.", { id = "welcome_back", mood = "happy", actionText = if first then "Let's go" else nil, action = first and first.action })
		end
	end)
	update()
end

function Onboarding.isFinished(): boolean
	return finished
end

-- Settings -> Guidance -> Replay tutorial: intro + guide lines again; never resets progress
function Onboarding.replay()
	ForgeBot.resetMemory()
	if not ForgeBot.isEnabled() then
		ForgeBot.setEnabled(true)
	end
	lastStep = -1
	UIRoot.close()
	playIntro(true)
end

return Onboarding
