--!strict
-- HarvestController — owner: Gameplay (Cosmic Core Hunt). Client side of the harvesting loop.
--   walk up to YOUR harvester -> ProximityPrompt (E / ButtonX / tap) -> Harvest_Enter
--   operating: character frozen locally, harvester camera (render step after CameraController),
--   reticle aim (mouse / arrows / gamepad sticks / touch drag), hover -> hold to LOCK -> HOLD fire to charge
--   the pulse emitter (Harvest_Charge: the SERVER timestamps the start) -> RELEASE inside the resonance window.
--   One pulse in flight, then the emitter reloads (SHOT.COOLDOWN, MISS_COOLDOWN after a miss); the server is
--   authoritative and replies with readyAt. Shots are predicted locally with HarvestRules for instant
--   feedback; the server's Harvest_Fire reply decides the outcome (capture animation + reward popups, or miss
--   + focus recovery). Meteor variants / rarity come from Harvest/MeteorRegistry.
-- Touches nothing owned by other systems except: local Anchored on the own root while operating, the
-- camera while operating, GuiService.TouchControlsEnabled / MouseIconEnabled (restored on exit).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.PF_Shared
local HarvestConfig = require(Shared.Config.HarvestConfig)
local ItemCatalog = require(Shared.Config.ItemCatalog)
local VisualStyle = require(Shared.Config.VisualStyle)
local HarvestLayout = require(Shared.Harvest.HarvestLayout)
local MeteorPath = require(Shared.Harvest.MeteorPath)
local HarvestRules = require(Shared.Harvest.HarvestRules)
local MeteorRegistry = require(Shared.Harvest.MeteorRegistry)
local Styles = require(script.Parent.MeteorStyles)
local Formulas = require(Shared.Economy.EconomyFormulas)
local ProfileClient = require(Shared.Client.ProfileClient)
local EvolutionClient = require(Shared.Client.EvolutionClient)
local Audio = require(script.Parent.HarvestAudio)
local MeteorVisuals = require(script.Parent.MeteorVisuals)
local FX = require(script.Parent.HarvestFX)
local HUD = require(script.Parent.HarvestHUD)

local HarvestController = {}
-- (First 10 Minutes 2.0) guide hook: ("enter", {tutorial}) | ("exit") | ("capture", info) | ("miss", {tutorial})
-- fired from server-confirmed results only; consumers are presentation (ForgeBot), never gameplay.
HarvestController.Events = require(game:GetService("ReplicatedStorage").PF_Shared.Util.Signal).new()

local player = Players.LocalPlayer
local LOCK = HarvestConfig.LOCK
local SHOT = HarvestConfig.SHOT
local RES = HarvestConfig.RESONANCE
local DEVICE = HarvestConfig.DEVICE
local COLORS = HUD.COLORS

local gravity: any = nil
local hud: any = nil
local container: Folder
local harvestFolder: Folder? = nil

local active = false
local entering = false
local session: any = nil
local visuals: { [number]: any } = {}
local pending: { [number]: any } = {}
local reticle = Vector2.new(400, 300)
local device = "keyboard"
local mouseAim = true
local stickL, stickR = Vector2.zero, Vector2.zero
local keys = { up = false, down = false, left = false, right = false }
local touchInput: InputObject? = nil
local mouseAnchor: Vector2? = nil -- mouse position when Tab/RB took over the reticle
local MOUSE_RECLAIM_PX = 14 -- the mouse takes the reticle back after moving this far
local hoverId: number? = nil
local lockId: number? = nil
local lockProgress = 0
-- pulse emitter: client mirror of the server's state (the server decides; readyAt is SERVER time)
local emitter: any = { readyAt = -math.huge, lastCooldown = HarvestConfig.SHOT.COOLDOWN, chargeAt = nil, chargeToken = nil, held = false, inFlight = false, chargedCue = false, wasReady = true }
local animating: { [any]: boolean } = {} -- captured / cancelled visuals finishing their animation
local lastAvailable: number? = nil
local mouseHeld = false
local chargeFx: any = nil -- charge build-up at the muzzle (HarvestFX.chargeBegin)
local lockFx: any = nil -- 3D lock ring (HarvestFX.lockRing)
local lockFxId: number? = nil
local camStart: CFrame? = nil
local camBlend = 0
local shake = 0
local fovKick = 0
local saved: { [string]: any } = {}
local headYaw, headPitch = 0, 0.45
local windowWas: { [number]: boolean } = {}
local tutorial = { step = 0, misses = 0, outroUntil = 0 }
local ownerBillboard: BillboardGui? = nil

local KEYMAP = {
	[Enum.KeyCode.Up] = "up",
	[Enum.KeyCode.W] = "up",
	[Enum.KeyCode.Down] = "down",
	[Enum.KeyCode.S] = "down",
	[Enum.KeyCode.Left] = "left",
	[Enum.KeyCode.A] = "left",
	[Enum.KeyCode.Right] = "right",
	[Enum.KeyCode.D] = "right",
}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function cam(): Camera
	return Workspace.CurrentCamera
end

local function myHarvester(): Model?
	local slot = session and session.slot or player:GetAttribute("PF_Slot")
	return harvestFolder and slot and harvestFolder:FindFirstChild("Harvester_" .. tostring(slot)) :: Model?
end

local function accent(): Color3
	return VisualStyle.slotColor(session and session.slot or 1)
end

local function materialName(id: string): string
	local e = ItemCatalog.get("materials", id)
	return if e then e.displayName else id
end

local function snapshotEnergy(): (number, number, number)
	local s = ProfileClient.get()
	if not s then
		return 0, 100, Formulas.harvestEnergyCost(0)
	end
	local eff = s.upgrades and s.upgrades.HarvestEfficiency
	return s.currencies.CosmicEnergy or 0, s.energyCap or 100, Formulas.harvestEnergyCost(if eff then eff.level else 0)
end

local function tutorialDone(): boolean
	local s = ProfileClient.get()
	return s ~= nil and table.find(s.discoveries or {}, "FirstHarvest") ~= nil
end

local function availableReactions(): number
	local ok, list = pcall(EvolutionClient.reactions)
	if not ok or type(list) ~= "table" then
		return 0
	end
	local n = 0
	for _, r in list do
		if r.available then
			n += 1
		end
	end
	return n
end

local function refreshPanel()
	if not hud or not session then
		return
	end
	-- a capture that makes a new reaction affordable is called out (the DNA LAB itself is Developer A's)
	local avail = availableReactions()
	if lastAvailable ~= nil and avail > lastAvailable then
		hud:notice("NEW REACTION AVAILABLE · open the DNA LAB", COLORS.GREEN, 5)
	end
	lastAvailable = avail
	local cur, cap, cost = snapshotEnergy()
	hud:setEnergy(cur, cap, cost)
	local s = ProfileClient.get()
	local m = s and s.materials or {}
	hud:setMaterials(m)
	hud:setSession(session.captures, session.missStacks)
	hud:setFireReady(cur >= cost)
end

local function setDevice(d: string)
	if d ~= device then
		device = d
		if hud then
			hud:setHints(d)
		end
	end
end

local function deviceFromInputType(t: Enum.UserInputType): string?
	if t == Enum.UserInputType.Touch then
		return "touch"
	elseif string.sub(t.Name, 1, 7) == "Gamepad" then
		return "gamepad"
	elseif t == Enum.UserInputType.Keyboard or t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseWheel then
		return "keyboard"
	end
	return nil
end

local function touchPos(input: InputObject): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(input.Position.X, input.Position.Y) + inset
end

local function fireKeyText(): string
	return if device == "gamepad" then "hold RT or A" elseif device == "touch" then "hold FIRE" else "hold Click or Space"
end

---------------------------------------------------------------- tutorial

local function setTutorialStep(n: number)
	if not hud then
		return
	end
	tutorial.step = n
	local title = "FIRST CAPTURE  •  STEP " .. n .. " / 3"
	if n == 1 then
		local how = if device == "gamepad" then "Use a <b>stick</b> to aim" elseif device == "touch" then "<b>Drag</b> your finger" else "Move your <b>mouse</b>"
		hud:setTutorial(how .. " onto the glowing <b>ICE METEOR</b>.", title)
	elseif n == 2 then
		hud:setTutorial("Keep your aim on it to <b>LOCK ON</b>.", title)
	elseif n == 3 then
		local lead = if tutorial.misses > 0 then "Almost! " else ""
		hud:setTutorial(lead .. "Charge (" .. fireKeyText() .. '), then <b>RELEASE</b> when the shrinking ring is inside the <font color="#5AFF96"><b>GREEN</b></font> band.', title)
	else
		hud:setTutorial(nil)
	end
end

local function updateTutorial()
	if not session or not session.tutorial then
		return
	end
	local n = if lockId then 3 elseif hoverId then 2 else 1
	if n ~= tutorial.step then
		setTutorialStep(n)
	end
end

local function finishTutorial()
	if not session then
		return
	end
	session.tutorial = false
	tutorial.step = 0
	hud:setTutorial("<b>CAPTURE COMPLETE!</b>  Ice Matter was added to your inventory.", "TUTORIAL COMPLETE")
	task.delay(3.5, function()
		if active and session and not session.tutorial then
			hud:setTutorial('More meteors incoming: <b>rarer</b> meteors fly faster and are worth more — watch the <font color="#5AAAFF"><b>rarity</b></font> tag.', "COSMIC CORE HUNT")
			task.delay(4.5, function()
				if active and session and not session.tutorial and tutorial.step == 0 then
					hud:setTutorial(nil)
				end
			end)
		end
	end)
end

---------------------------------------------------------------- meteors

local function addMeteor(spec: any)
	if not session or not MeteorPath.isValidSpec(spec) or visuals[spec.id] then
		return
	end
	local ok, v = pcall(MeteorVisuals.new, spec, session.layout, container)
	if ok then
		visuals[spec.id] = v
		if v.rarity.order >= 4 and not spec.fragment and not spec.tutorial then
			hud:notice(string.format("%s INBOUND · %s", string.upper(v.def.displayName), v.rarity.label), v.rarity.color)
			Audio.play("telegraph")
		end
	else
		warn("[PF] meteor visual failed:", v)
		container:SetAttribute("PFLastError", tostring(v))
	end
end

local function clearMeteors()
	for id, v in visuals do
		v:destroy()
		visuals[id] = nil
	end
	for v in animating do
		v:destroy()
		animating[v] = nil
	end
	for id, p in pending do
		if p.stasis then
			p.stasis()
		end
		pending[id] = nil
	end
	windowWas = {}
end

---------------------------------------------------------------- aim + lock

local function lockRadius(vp: Vector2): number
	local mult = if device == "touch" then LOCK.TOUCH_RADIUS_MULT elseif device == "gamepad" then LOCK.GAMEPAD_RADIUS_MULT else 1
	return LOCK.RADIUS_FRAC * vp.Y * mult
end

local function updateReticle(dt: number, vp: Vector2)
	if device == "touch" then
		if touchInput then
			reticle = touchPos(touchInput)
		end
	elseif device == "keyboard" and mouseAim then
		reticle = UserInputService:GetMouseLocation()
	else
		local s = if stickL.Magnitude >= stickR.Magnitude then stickL else stickR
		local v = Vector2.zero
		if s.Magnitude > LOCK.GAMEPAD_DEADZONE then
			local mag = math.clamp((s.Magnitude - LOCK.GAMEPAD_DEADZONE) / (1 - LOCK.GAMEPAD_DEADZONE), 0, 1)
			local d = s.Unit * (0.25 * mag + 0.75 * mag * mag) * LOCK.GAMEPAD_SPEED_FRAC * vp.Y
			v = Vector2.new(d.X, -d.Y)
		end
		local k = Vector2.new((if keys.right then 1 else 0) - (if keys.left then 1 else 0), (if keys.down then 1 else 0) - (if keys.up then 1 else 0))
		if k.Magnitude > 0 then
			v += k.Unit * LOCK.KEYBOARD_SPEED_FRAC * vp.Y
		end
		reticle += v * dt
	end
	reticle = Vector2.new(math.clamp(reticle.X, 0, vp.X), math.clamp(reticle.Y, 0, vp.Y))
end

local function aimInputIdle(): boolean
	if device == "touch" then
		return touchInput == nil
	end
	if device == "keyboard" then
		return not mouseAim and not (keys.up or keys.down or keys.left or keys.right)
	end
	return math.max(stickL.Magnitude, stickR.Magnitude) <= LOCK.GAMEPAD_DEADZONE
end

local function scan(dt: number, vp: Vector2): { [number]: any }
	local c = cam()
	local fovK = (vp.Y * 0.5) / math.tan(math.rad(c.FieldOfView) / 2)
	local lockR = lockRadius(vp)
	local selectR = LOCK.SELECT_FRAC * vp.Y
	local infos = {}
	local best, bestD = nil, math.huge
	for id, v in visuals do
		local isPending = pending[id] ~= nil
		local pos = if isPending and v.state == "held" then v.heldPos else v.worldPos
		if pos and (v:isLockable() or isPending) then
			local p3, onScreen = c:WorldToViewportPoint(pos)
			local sp = Vector2.new(p3.X, p3.Y)
			local depth = p3.Z
			local pr = if depth > 0 then (v.spec.size * 0.5) / depth * fovK else 0
			local info = { id = id, v = v, sp = sp, depth = depth, onScreen = onScreen and depth > 0, pr = pr, pending = isPending }
			infos[id] = info
			if info.onScreen and not isPending and v:isTargetable() then
				local d = math.max(0, (sp - reticle).Magnitude - pr)
				if d < selectR and d < bestD then
					best, bestD = id, d
				end
			end
		end
	end
	if best ~= hoverId then
		hoverId = best
		if not lockId then
			lockProgress = 0
		end
		if best then
			Audio.play("hover")
		end
	end
	if lockId and not pending[lockId] then -- a shot in flight never breaks the lock (retry after a miss)
		local info = infos[lockId]
		if not info or not info.onScreen or math.max(0, (info.sp - reticle).Magnitude - info.pr) > lockR * LOCK.BREAK_FACTOR then
			lockId = nil
			lockProgress = 0
		end
	end
	if not lockId and hoverId and bestD <= lockR then
		local lt = if session.tutorial then LOCK.TUTORIAL_TIME else LOCK.TIME
		lockProgress = math.min(1, lockProgress + dt / lt)
		if lockProgress >= 1 then
			lockId = hoverId
			Audio.play("lock")
		end
	elseif not lockId then
		lockProgress = math.max(0, lockProgress - dt * 2.5)
	end
	-- aim assist: a locked target gently pulls the reticle when the player isn't steering (not for mouse)
	if lockId and infos[lockId] and aimInputIdle() and not (device == "keyboard" and mouseAim) then
		reticle = reticle:Lerp(infos[lockId].sp, 1 - math.exp(-LOCK.MAGNET_RATE * dt))
	end
	return infos
end

local function aimDirection(): (Vector3, Vector3)
	local L = session.layout
	local locked = lockId and visuals[lockId]
	if locked and locked.worldPos then
		return (locked.worldPos - L.origin).Unit, locked.worldPos
	end
	local ray = cam():ViewportPointToRay(reticle.X, reticle.Y)
	local depth = (L.cameraFocus - ray.Origin).Magnitude
	local hovered = hoverId and visuals[hoverId]
	if hovered and hovered.worldPos then
		depth = math.max(10, (hovered.worldPos - ray.Origin):Dot(ray.Direction))
	end
	local p = ray.Origin + ray.Direction * depth
	return (p - L.origin).Unit, p
end

local function headFor(slot: number): CFrame
	return HarvestLayout.localCFrame(HarvestLayout.forSlot(slot), DEVICE.HEAD_PIVOT)
end

local function updateHead(dt: number, aim: Vector3)
	local m = myHarvester()
	local head = m and m:FindFirstChild("Head") :: Model?
	if not head then
		return
	end
	local L = session.layout
	local o = L.base:VectorToObjectSpace(aim)
	local yaw = math.atan2(-o.X, -o.Z)
	local pitch = math.atan2(o.Y, math.sqrt(o.X * o.X + o.Z * o.Z))
	local k = 1 - math.exp(-16 * dt)
	headYaw += (yaw - headYaw) * k
	headPitch += (pitch - headPitch) * k
	head:PivotTo(headFor(session.slot) * CFrame.Angles(0, headYaw, 0) * CFrame.Angles(headPitch, 0, 0))
end

local function muzzlePosition(): Vector3
	local m = myHarvester()
	local crystal = m and m:FindFirstChild("MuzzleCrystal", true)
	local att = crystal and crystal:FindFirstChild("Muzzle") :: Attachment?
	return if att then att.WorldPosition else session.layout.origin
end

---------------------------------------------------------------- HUD markers

local function ringScaleAt(phase: number): number
	return RES.RING_MAX + (RES.RING_MIN - RES.RING_MAX) * phase
end

-- screen-edge arrow for an off-screen point
local function edgeOf(sp: Vector2, depth: number, vp: Vector2): (Vector2?, number?)
	local center = vp / 2
	local d = sp - center
	if depth < 0 then
		d = -d
	end
	if d.Magnitude <= 1 then
		return nil, nil
	end
	local dir = d.Unit
	local margin = 40
	local tx = if math.abs(dir.X) > 1e-4 then (center.X - margin) / math.abs(dir.X) else math.huge
	local ty = if math.abs(dir.Y) > 1e-4 then (center.Y - margin) / math.abs(dir.Y) else math.huge
	return center + dir * math.min(tx, ty), math.deg(math.atan2(dir.X, -dir.Y))
end

local function drawMarkers(infos: { [number]: any }, vp: Vector2, now: number, emitterState: string)
	local items = {}
	local ids = {}
	for id in infos do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		if a == b then
			return false
		elseif a == lockId then
			return true
		elseif b == lockId then
			return false
		end
		return a < b
	end)
	local stacks = session.missStacks
	for _, id in ids do
		local info = infos[id]
		local v = info.v
		local spec = v.spec
		local phase = HarvestRules.phase(spec, now)
		local ws = HarvestRules.windowStart(spec, stacks)
		local inWindow = phase >= ws and phase <= spec.w1
		local perfect = phase >= spec.p0 and phase <= spec.p1
		local size = math.max(46, info.pr * 2.5)
		local s0, s1 = ringScaleAt(ws), ringScaleAt(spec.w1)
		local item = {
			id = id,
			pos = info.sp,
			size = size,
			onScreen = info.onScreen,
			color = v.def.color,
			name = string.upper(v.def.displayName) .. (if spec.fragment then " SHARD" else ""),
			rarityText = if v.rarity.order >= 3 or id == hoverId or id == lockId then v.rarity.label else nil,
			rarityColor = v.rarity.color,
			phased = v.phased,
			emitter = emitterState, -- "RELEASE NOW" only when a charged pulse is actually ready
			stateText = if v.phased then "PHASED — WAIT" else nil,
			stateColor = v.rarity.color,
			lockProgress = if id == hoverId then lockProgress else 0,
			locked = id == lockId,
			hovered = id == hoverId,
			ringScale = ringScaleAt(phase),
			bandInner = math.min(s0, s1),
			bandOuter = math.max(s0, s1),
			perfectScale = ringScaleAt((spec.p0 + spec.p1) / 2),
			inWindow = inWindow,
			perfect = perfect,
			tutorial = spec.tutorial,
		}
		if not info.onScreen then
			item.edge, item.edgeAngle = edgeOf(info.sp, info.depth, vp)
		end
		if id == lockId then
			if inWindow and not windowWas[id] then
				Audio.play("window")
			end
			windowWas[id] = inWindow
		end
		table.insert(items, item)
	end
	-- telegraphed arrivals (Comet / Stellar / Void / Astral): warning marker where they will enter
	local c = cam()
	for _, v in visuals do
		if v.telegraphPos and #items < 6 then
			local p3, on = c:WorldToViewportPoint(v.telegraphPos)
			local item: any = {
				id = v.spec.id,
				pos = Vector2.new(p3.X, p3.Y),
				size = 54,
				onScreen = on and p3.Z > 0,
				color = v.rarity.color,
				name = string.upper(v.def.displayName),
				rarityText = v.rarity.label,
				rarityColor = v.rarity.color,
				telegraph = true,
				stateText = "INBOUND",
				stateColor = v.rarity.color,
				lockProgress = 0,
				ringScale = 1,
				bandInner = 1,
				bandOuter = 1,
				perfectScale = 1,
			}
			if not item.onScreen then
				item.edge, item.edgeAngle = edgeOf(item.pos, p3.Z, vp)
			end
			table.insert(items, item)
		end
	end
	hud:updateMarkers(items)
	-- keep the emitter status clear of the hovered / locked target's resonance ring
	local focusInfo = (lockId and infos[lockId]) or (hoverId and infos[hoverId])
	hud:setStatusClearance(if focusInfo then math.max(0, math.max(46, focusInfo.pr * 2.5) * RES.RING_MAX / 2 - 23) else 0)
	local locked = lockId and infos[lockId]
	local color = COLORS.WHITE
	if locked then
		local spec = locked.v.spec
		local ph = HarvestRules.phase(spec, now)
		color = if ph >= HarvestRules.windowStart(spec, stacks) and ph <= spec.w1 then COLORS.GREEN else COLORS.CYAN
	elseif hoverId then
		color = COLORS.CYAN
	end
	hud:setReticle(reticle, color, 1, true)
end

---------------------------------------------------------------- shots

local resolve: (any) -> ()

local function onCapture(entry: any, data: any)
	local v = entry.v
	local L = session.layout
	if lockId == v.spec.id then
		lockId = nil
		lockProgress = 0
	end
	visuals[v.spec.id] = nil
	animating[v] = true
	-- a split parent caught before it broke: its (server-cancelled) fragments fade out
	for _, cid in data.cancelIds or {} do
		local cv = visuals[cid]
		if cv then
			visuals[cid] = nil
			windowWas[cid] = nil
			if lockId == cid then
				lockId = nil
			end
			cv:cancel()
			animating[cv] = true
		end
	end
	session.captures = data.captures or (session.captures + 1)
	session.missStacks = 0
	local m = myHarvester()
	local core = m and m:FindFirstChild("Collector") and m.Collector:FindFirstChild("Core")
	local att = core and core:FindFirstChild("CollectorAttachment") :: Attachment?
	local beam = if att then FX.tether(att, v.tether, v.def.color) else nil
	Audio.play("absorb", 0.8)
	local perfect = data.quality == "perfect"
	local rarity = v.rarity
	local title = if perfect then "PERFECT CAPTURE!" else "CAPTURED!"
	if rarity.order >= 3 then
		title = rarity.label .. "  " .. title
	end
	if rarity.order >= 4 then
		Audio.play("rare")
	end
	hud:flash(
		title,
		if perfect then COLORS.GOLD elseif rarity.order >= 3 then rarity.color else COLORS.GREEN,
		string.format("+%d %s   •   +%d XP%s", data.amount or 0, materialName(data.materialId), data.xp or 0, if perfect then "   •   x1.5 resonance bonus" else "")
	)
	if perfect then
		Audio.play("perfect")
		FX.perfect(v.core.Position, L.base.UpVector, rarity.color, v.rStyle.flourish)
		hud:perfectGlow(if rarity.order >= 4 then rarity.color else nil)
	elseif rarity.order >= 5 then
		FX.perfect(v.core.Position, L.base.UpVector, rarity.color, 2) -- legendary+ always get a show
	end
	-- reward popup where the meteor was caught (the collector itself sits below the view)
	local vp = cam().ViewportSize
	local at = cam():WorldToViewportPoint(v.core.Position)
	local popupPos = Vector2.new(math.clamp(at.X, 120, vp.X - 120), math.clamp(at.Y, 100, vp.Y * 0.75))
	v:capture(L.collector, L.base.UpVector, 0.85, function()
		if beam then
			beam:Destroy()
		end
		FX.implosion(L.collector, L.base.LookVector, v.def.color, v.rStyle.flourish)
		Audio.play("absorb", 1.4)
		if hud then
			hud:popup(string.format("+%d %s", data.amount or 0, materialName(data.materialId)), v.def.color, Vector2.new(popupPos.X, popupPos.Y))
		end
	end)
	for i, d in data.discoveries or {} do
		local e = ItemCatalog.get("discoveries", d)
		task.delay(0.9 + i * 0.6, function()
			if hud then
				hud:popup("DISCOVERY: " .. (if e then e.displayName else d), COLORS.GOLD)
			end
		end)
	end
	if table.find(data.discoveries or {}, "FirstHarvest") then
		Audio.play("first")
	end
	if data.tutorialComplete or (session.tutorial and v.spec.tutorial) then
		finishTutorial()
	end
	refreshPanel()
	-- guide (ForgeBot): server-confirmed capture only
	HarvestController.Events:Fire("capture", { quality = data.quality, perfect = perfect, first = table.find(data.discoveries or {}, "FirstHarvest") ~= nil, tutorial = data.tutorialComplete == true, materialId = data.materialId, amount = data.amount, rarity = rarity.order })
end

local REJECT_TEXT: { [string]: { string } } = {
	NOT_ENOUGH_ENERGY = { "OUT OF ENERGY", "Harvest Energy regenerates over time; level-ups refill it." },
	CAPTURE_LIMIT = { "COLLECTOR SATURATED", "Too many captures this minute — give it a few seconds." },
	COOLDOWN = { "RELOADING", "The pulse emitter is still reloading." },
	NOT_CHARGED = { "CHARGE FIRST", "Hold fire to charge the pulse, release on the green band." },
	CHARGE_SHORT = { "CHARGE TOO SHORT", "Hold until the charge ring fills, then release." },
	SHOT_IN_FLIGHT = { "PULSE IN FLIGHT", "One pulse at a time." },
	INTERNAL_ERROR = { "SIGNAL LOST", "Harvester hiccup — the meteor is still in play." },
	TIMEOUT = { "SIGNAL LOST", "Connection hiccup — the meteor is still in play." },
	BAD_TIME = { "SIGNAL LOST", "Connection hiccup — the meteor is still in play." },
	RATE_LIMITED = { "RECHARGING", "Slow down a little." },
}

resolve = function(entry: any)
	if pending[entry.id] ~= entry then
		return
	end
	pending[entry.id] = nil
	if entry.stasis then
		entry.stasis()
		entry.stasis = nil
	end
	local v = entry.v
	if not active or not session then
		return
	end
	local r = entry.reply or { ok = false, code = "TIMEOUT" }
	if r.ok and r.code == "CAPTURE" then
		onCapture(entry, r.data or {})
		return
	end
	v:release(serverNow())
	if r.ok and r.code == "MISS" then
		local data = r.data or {}
		session.missStacks = data.missStacks or session.missStacks
		local reason = data.reason
		local title, sub = "MISSED", ""
		if reason == "MISS_TIMING" then
			local ph = HarvestRules.phase(v.spec, entry.fireTime)
			title = if ph < HarvestRules.windowStart(v.spec, entry.stacks) then "TOO EARLY" else "TOO LATE"
			sub = "Fire while the shrinking ring is inside the green band."
		elseif reason == "MISS_AIM" then
			title = "OFF TARGET"
			sub = "Hold your aim on a meteor to lock on — locked pulses home in."
		elseif reason == "MISS_PHASED" then
			title = "PHASED OUT"
			sub = "Void meteors blink out between capture windows — release while it is visible."
		else
			title = "TARGET LOST"
			sub = "It left the harvesting lane."
		end
		if session.missStacks > 0 then
			sub ..= "   •   FOCUS +1: your next shot is easier"
		end
		Audio.play("miss")
		Audio.play("missThud")
		hud:missPulse()
		hud:flash(title, COLORS.RED, sub)
		if session.tutorial then
			tutorial.misses += 1
			setTutorialStep(tutorial.step)
		end
		refreshPanel()
		HarvestController.Events:Fire("miss", { tutorial = session.tutorial == true, misses = tutorial.misses })
		return
	end
	if r.code == "ALREADY_CLAIMED" then
		return
	end
	local t = REJECT_TEXT[r.code] or { "PULSE REJECTED", tostring(r.code) }
	Audio.play("denied")
	hud:flash(t[1], COLORS.RED, t[2])
end

local function chargeNeeded(): number
	-- the server measures the charge from when IT received the start: high-latency clients hold a bit longer
	local okPing, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local p = if okPing and type(ping) == "number" then ping else 0
	return SHOT.MIN_CHARGE + math.clamp(p - SHOT.CHARGE_TOLERANCE_MAX + 0.05, 0, 0.35)
end

-- "reload" | "firing" | "charging" | "charged" | "ready", fraction, seconds remaining
local function emitterMode(nowS: number): (string, number, number)
	if emitter.inFlight then
		return "firing", 1, 0
	end
	if nowS < emitter.readyAt then
		local remaining = emitter.readyAt - nowS
		return "reload", 1 - math.clamp(remaining / math.max(emitter.lastCooldown, 0.1), 0, 1), remaining
	end
	if emitter.chargeAt then
		local f = math.clamp((os.clock() - emitter.chargeAt) / chargeNeeded(), 0, 1)
		return if f >= 1 then "charged" else "charging", f, 0
	end
	return "ready", 0, 0
end

local function cancelCharge()
	emitter.chargeAt = nil
	emitter.chargeToken = nil
	emitter.chargedCue = false
	if chargeFx then
		chargeFx:cancel()
		chargeFx = nil
	end
	Audio.chargeLoop(false)
end

-- Start charging (a press, or still holding when the reload completes). The server timestamps the start.
local function beginCharge(fromPress: boolean)
	if not active or not session or emitter.chargeAt or emitter.inFlight then
		return
	end
	if serverNow() < emitter.readyAt - SHOT.COOLDOWN_TOLERANCE then
		if fromPress then
			Audio.play("denied", 1.4, 0.5) -- still reloading: the HUD shows how long
		end
		return
	end
	local cur, _, cost = snapshotEnergy()
	if cur < cost then
		if fromPress then
			Audio.play("denied")
			hud:flash("OUT OF ENERGY", COLORS.RED, "Harvest Energy regenerates over time; level-ups refill it.")
		end
		return
	end
	emitter.chargeAt = os.clock()
	emitter.chargedCue = false
	local token = {}
	emitter.chargeToken = token
	Audio.play("charge")
	if chargeFx then
		chargeFx:cancel()
	end
	chargeFx = FX.chargeBegin(muzzlePosition, accent())
	Audio.chargeLoop(true)
	task.spawn(function()
		local ok, code, data = ProfileClient.request("Harvest_Charge", {})
		if emitter.chargeToken ~= token or ok then
			return
		end
		if type(data) == "table" and type(data.readyAt) == "number" then
			emitter.readyAt = data.readyAt -- the server's reload wins
		end
		if code ~= "TIMEOUT" then
			cancelCharge()
		end
	end)
end

local function fire()
	if not active or not session or emitter.inFlight then
		return
	end
	local fireTime = serverNow()
	local L = session.layout
	local targetId = lockId or hoverId
	local v = targetId and visuals[targetId]
	if v and v.phased then
		-- keep the charge: release again once it is visible (nothing was sent, the server charge stands)
		Audio.play("denied", 1.2, 0.6)
		hud:flash("PHASED OUT", COLORS.WHITE, "Void meteors blink out — release when it is visible again.")
		return
	end
	if not targetId or not v or pending[targetId] or not v:isTargetable() then
		Audio.play("denied", 1.2, 0.6)
		hud:flash("NO TARGET", COLORS.WHITE, "Aim at a meteor — the brackets show what you will hit. Your charge is kept.")
		return
	end
	if chargeFx then
		chargeFx:release() -- the build-up bursts into the muzzle flash
		chargeFx = nil
	end
	cancelCharge()
	local tid = targetId :: number
	-- a LOCKED pulse homes in: aim at the target's true position at the release time (what the server checks)
	local aim
	if lockId == tid then
		local tp = v:truePosition(fireTime)
		aim = if tp then (tp - L.origin).Unit else aimDirection()
	else
		aim = aimDirection()
	end
	local muzzle = muzzlePosition()
	local color = accent()
	local predicted = HarvestRules.evaluateShot(v.spec, fireTime, L.toWorld, L.origin, aim, session.missStacks)
	emitter.inFlight = true
	emitter.lastCooldown = if predicted.hit then SHOT.COOLDOWN else SHOT.MISS_COOLDOWN
	emitter.readyAt = fireTime + emitter.lastCooldown -- prediction; the reply carries the server's readyAt
	FX.muzzleFlash(muzzle, aim, color)
	Audio.play("fire")
	Audio.play("fireBass")
	if not Styles.reducedMotion() then
		shake = 0.35
		fovKick = 3
	end
	local entry: any = { id = tid, v = v, predicted = predicted, fireTime = fireTime, stacks = session.missStacks, arrived = false, reply = nil }
	pending[tid] = entry
	local targetPos = predicted.position or v.worldPos or (muzzle + aim * 100)
	local dist = (targetPos - muzzle).Magnitude
	local travel = math.max(SHOT.MIN_PULSE_TIME, dist / SHOT.PULSE_SPEED)
	local homing = predicted.hit or lockId == tid
	local missDest = muzzle + aim * dist
	FX.pulse(muzzle, function()
		if homing and v.model and v.model.Parent then
			return v.core.Position
		end
		return missDest
	end, travel, color, function(p)
		entry.arrived = true
		if homing and v.model and v.model.Parent then
			-- hit feedback by meteor family (shatter / molten / electric / spore / metal / rock / ...)
			FX.impact(p, v.def.color, v.spec.size, v.vStyle.impact, v.vStyle.burst)
			local sfx = v.def.sfx
			Audio.impact(v.vStyle.impact, sfx and sfx.pitch or 1)
			v:hold()
			entry.stasis = FX.stasis(function()
				return if v.core.Parent then v.core.Position else p
			end, v.spec.size, v.def.color)
		else
			FX.fizzle(p, color)
		end
		if entry.reply then
			resolve(entry)
		end
	end)
	task.spawn(function()
		local ok, code, data = ProfileClient.request("Harvest_Fire", {
			targetId = tid,
			fireTime = fireTime,
			aimX = aim.X,
			aimY = aim.Y,
			aimZ = aim.Z,
		})
		emitter.inFlight = false
		if type(data) == "table" and type(data.readyAt) == "number" then
			emitter.readyAt = data.readyAt
			if type(data.cooldown) == "number" then
				emitter.lastCooldown = data.cooldown
			end
		end
		entry.reply = { ok = ok, code = code, data = data }
		if entry.arrived then
			resolve(entry)
		end
	end)
	task.delay(3, function()
		if pending[tid] == entry then
			emitter.inFlight = false
			entry.reply = entry.reply or { ok = false, code = "TIMEOUT" }
			resolve(entry)
		end
	end)
end

-- input: press = start charging (or keep holding through the reload), release = fire when charged
local function pressFire()
	if not active then
		return
	end
	emitter.held = true
	beginCharge(true)
end

local function releaseFire()
	local wasHeld = emitter.held
	emitter.held = false
	if not active or not wasHeld or not emitter.chargeAt then
		return
	end
	if os.clock() - emitter.chargeAt < chargeNeeded() then
		cancelCharge()
		hud:flash("HOLD TO CHARGE", COLORS.WHITE, "Keep holding until the ring fills, then release on the green band.")
		return
	end
	fire()
end

local function cycleTarget()
	if not active then
		return
	end
	local c = cam()
	local list = {}
	for id, v in visuals do
		if v:isTargetable() and not pending[id] then
			local p3, on = c:WorldToViewportPoint(v.worldPos)
			if on and p3.Z > 0 then
				table.insert(list, { id = id, x = p3.X, sp = Vector2.new(p3.X, p3.Y) })
			end
		end
	end
	if #list == 0 then
		return
	end
	table.sort(list, function(a, b)
		return a.x < b.x
	end)
	local current = lockId or hoverId
	local idx = 1
	for i, e in list do
		if e.id == current then
			idx = (i % #list) + 1
		end
	end
	mouseAim = false
	mouseAnchor = UserInputService:GetMouseLocation()
	lockId = nil
	lockProgress = 0
	reticle = list[idx].sp
	Audio.play("hover", 1.2)
end

---------------------------------------------------------------- mode

local stopMode: (string) -> ()

local function cameraStep(dt: number)
	local c = cam()
	local L = session.layout
	local vp = c.ViewportSize
	local n = Vector2.new((reticle.X / math.max(vp.X, 1) - 0.5) * 2, (reticle.Y / math.max(vp.Y, 1) - 0.5) * 2)
	local focus = L.cameraFocus + L.base.RightVector * (n.X * 16) - L.base.UpVector * (n.Y * 9)
	shake *= math.exp(-dt * 10)
	local jitter = if shake > 0.01 then Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * shake else Vector3.zero
	local desired = CFrame.lookAt(L.camera + jitter, focus, L.base.UpVector)
	camBlend = math.min(1, camBlend + dt / 0.6)
	local k = camBlend * camBlend * (3 - 2 * camBlend)
	c.CameraType = Enum.CameraType.Scriptable
	c.CFrame = if camStart and k < 1 then camStart:Lerp(desired, k) else desired
	fovKick *= math.exp(-dt * 8)
	c.FieldOfView = DEVICE.CAMERA_FOV + fovKick
	c.Focus = CFrame.new(focus)
end

-- 3D lock ring follows the locked target; green only when a charged pulse would land in the window.
local function updateLockFx(now: number, mode: string)
	local v = lockId and visuals[lockId]
	local pos = v and (if v.state == "held" then v.heldPos else v.worldPos)
	if not v or not pos then
		if lockFx then
			lockFx:destroy()
			lockFx = nil
			lockFxId = nil
		end
		return
	end
	local ph = HarvestRules.phase(v.spec, now)
	local inWindow = ph >= HarvestRules.windowStart(v.spec, session.missStacks) and ph <= v.spec.w1
	local color = if mode == "charged" and inWindow then COLORS.GREEN elseif v.phased then v.rarity.color else COLORS.CYAN
	if lockFxId ~= lockId or not lockFx then
		if lockFx then
			lockFx:destroy()
		end
		lockFx = FX.lockRing(pos, v.spec.size, color)
		lockFxId = lockId
	else
		lockFx:update(pos, v.spec.size, color)
	end
end

local function frame(dt: number)
	if not active or not session then
		return
	end
	cameraStep(dt)
	local now = serverNow()
	local vp = cam().ViewportSize
	hud:setViewport(vp)
	for id, v in visuals do
		v:update(now, dt)
		if v.expired and not pending[id] then
			if v.spec.splits and v.lastPos then
				-- the split parent breaks apart; its fragments (issued with it) take over
				FX.impact(v.lastPos, v.def.color, v.spec.size * 1.4, "rock", v.vStyle.burst)
				Audio.play("split")
			end
			v:destroy()
			visuals[id] = nil
			windowWas[id] = nil
			if lockId == id then
				lockId = nil
			end
		end
	end
	for v in animating do
		v:update(now, dt)
		if v.released then
			animating[v] = nil
		end
	end
	updateReticle(dt, vp)
	local infos = scan(dt, vp)
	local aim = aimDirection()
	updateHead(dt, aim)
	-- pulse emitter: holding through the reload starts the charge the moment it is ready
	if emitter.held and not emitter.chargeAt and not emitter.inFlight and now >= emitter.readyAt then
		beginCharge(false)
	end
	local mode, frac, remaining = emitterMode(now)
	drawMarkers(infos, vp, now, mode)
	if mode == "charged" and not emitter.chargedCue then
		emitter.chargedCue = true
		Audio.play("charged")
	end
	local readyNow = mode ~= "reload" and mode ~= "firing"
	if readyNow and not emitter.wasReady then
		-- smooth READY transition: chime, muzzle ring, reticle pop
		Audio.play("ready")
		Audio.play("readyChime")
		FX.readyPulse(muzzlePosition(), accent())
		hud:readyPop()
	end
	emitter.wasReady = readyNow
	-- harvester VFX: charge build-up + tone, reload / READY on the turret, 3D lock ring
	if chargeFx then
		local cf = if mode == "charging" or mode == "charged" then frac else 0
		chargeFx:set(cf)
		Audio.setChargeLevel(cf)
	end
	FX.emitterState(myHarvester(), mode, frac, accent())
	if mode == "reload" and emitter.lastMode == "firing" then
		Audio.play("reload")
	end
	emitter.lastMode = mode
	updateLockFx(now, mode)
	hud:setEmitter({ mode = mode, frac = frac, remaining = remaining })
	updateTutorial()
	if RunService:IsStudio() then
		local n = 0
		for _ in visuals do
			n += 1
		end
		container:SetAttribute("PFVisuals", n)
		container:SetAttribute("PFLock", lockId or 0)
		container:SetAttribute("PFHover", hoverId or 0)
		container:SetAttribute("PFMissStacks", session.missStacks)
		container:SetAttribute("PFCaptures", session.captures)
		container:SetAttribute("PFEmitter", mode)
		container:SetAttribute("PFReadyIn", math.max(0, emitter.readyAt - now))
		container:SetAttribute("PFPool", MeteorVisuals.poolCount())
	end
end

local function bindActions()
	ContextActionService:BindActionAtPriority("PF_HarvestFire", function(_, state)
		if state == Enum.UserInputState.Begin then
			pressFire()
		elseif state == Enum.UserInputState.End then
			releaseFire()
		elseif state == Enum.UserInputState.Cancel then
			emitter.held = false
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.Return, Enum.KeyCode.ButtonR2, Enum.KeyCode.ButtonA)
	ContextActionService:BindActionAtPriority("PF_HarvestCycle", function(_, state)
		if state == Enum.UserInputState.Begin then
			cycleTarget()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.R, Enum.KeyCode.Tab, Enum.KeyCode.ButtonR1, Enum.KeyCode.ButtonL1) -- Tab is usually taken by the Roblox player list: R is the keyboard key
	ContextActionService:BindActionAtPriority("PF_HarvestExit", function(_, state)
		if state == Enum.UserInputState.Begin then
			HarvestController.exit()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Q, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
end

local function unbindActions()
	for _, n in { "PF_HarvestFire", "PF_HarvestCycle", "PF_HarvestExit" } do
		ContextActionService:UnbindAction(n)
	end
end

-- Own planet's name label (WorldService, Developer A) floats right in the lane: hidden LOCALLY while
-- operating and restored on exit. Never modified on the server.
local function setPlanetLabelVisible(slot: number, visible: boolean)
	local world = Workspace:FindFirstChild("PF_World")
	local planet = world and world:FindFirstChild("Planets") and world.Planets:FindFirstChild("Slot_" .. slot)
	local label = planet and planet:FindFirstChild("PlanetLabel", true) :: BillboardGui?
	if label then
		if not visible then
			saved.planetLabel = label
			saved.planetLabelEnabled = label.Enabled
			label.Enabled = false
		elseif saved.planetLabel == label then
			label.Enabled = if saved.planetLabelEnabled == nil then true else saved.planetLabelEnabled
			saved.planetLabel = nil
		end
	end
end

-- Own beacon + floating label are hidden locally while operating (they'd sit in the middle of the view).
local function setBeaconVisible(m: Model?, visible: boolean)
	local static = m and m:FindFirstChild("Static")
	local b = static and static:FindFirstChild("Beacon") :: BasePart?
	if b then
		b.LocalTransparencyModifier = if visible then 0 else 1
	end
	local anchor = static and static:FindFirstChild("LabelAnchor")
	local label = anchor and anchor:FindFirstChild("HarvesterLabel") :: BillboardGui?
	if label then
		label.Enabled = visible
	end
end

local refreshPrompts: () -> ()

local function startMode(msg: any)
	if active then
		-- re-sync (server re-sent the session): add anything we don't have yet
		for _, spec in msg.meteors or {} do
			addMeteor(spec)
		end
		return
	end
	local slot = msg.slot
	if type(slot) ~= "number" then
		return
	end
	active = true
	session = {
		slot = slot,
		layout = HarvestLayout.forSlot(slot),
		tutorial = msg.tutorial == true,
		missStacks = msg.missStacks or 0,
		captures = msg.captures or 0,
	}
	tutorial = { step = 0, misses = 0, outroUntil = 0 }
	HarvestController.Events:Fire("enter", { tutorial = session.tutorial })
	if type(msg.readyAt) == "number" then
		emitter.readyAt = msg.readyAt -- the reload survives exit / death / re-entry (server-authoritative)
	end
	emitter.inFlight = false
	emitter.held = false
	mouseHeld = false
	cancelCharge()
	emitter.wasReady = serverNow() >= emitter.readyAt
	lastAvailable = availableReactions()
	local root = gravity and gravity.getRoot()
	if root then
		saved.root = root
		saved.anchored = root.Anchored
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = true
	end
	local c = cam()
	saved.fov = c.FieldOfView
	saved.mouseIcon = UserInputService.MouseIconEnabled
	camStart = c.CFrame
	camBlend = 0
	UserInputService.MouseIconEnabled = false
	pcall(function()
		saved.touchControls = GuiService.TouchControlsEnabled
		GuiService.TouchControlsEnabled = false
	end)
	local vp = c.ViewportSize
	reticle = vp / 2
	lockId, hoverId, lockProgress = nil, nil, 0
	headYaw, headPitch = 0, 0.45
	local m = myHarvester()
	setBeaconVisible(m, false)
	setPlanetLabelVisible(slot, false)
	if ownerBillboard then
		ownerBillboard.Enabled = false
	end
	refreshPrompts()
	hud:setHints(device)
	hud:setActive(true)
	refreshPanel()
	bindActions()
	RunService:BindToRenderStep("PF_HarvestFrame", Enum.RenderPriority.Camera.Value + 2, frame)
	for _, spec in msg.meteors or {} do
		addMeteor(spec)
	end
	if session.tutorial then
		setTutorialStep(1)
	else
		hud:setTutorial(nil)
		if msg.resumed then
			hud:notice("HARVESTER RESUMED · same meteor stream", COLORS.CYAN)
		end
	end
	Audio.play("enter")
end

local EXIT_TEXT: { [string]: string } = {
	idle = "Harvester powered down (idle).",
	too_far = "You walked away from the harvester.",
	died = "Harvester session ended.",
	limit = "Harvester session limit reached — operate it again any time.",
}

stopMode = function(reason: string)
	HarvestController.Events:Fire("exit", {})
	if not active then
		return
	end
	active = false
	RunService:UnbindFromRenderStep("PF_HarvestFrame")
	unbindActions()
	clearMeteors()
	MeteorVisuals.clearPool()
	emitter.held = false
	emitter.inFlight = false
	mouseHeld = false
	cancelCharge()
	if lockFx then
		lockFx:destroy()
		lockFx = nil
		lockFxId = nil
	end
	FX.restoreEmitter(myHarvester())
	emitter.lastMode = nil
	if saved.root and saved.root.Parent then
		saved.root.Anchored = saved.anchored or false
	end
	saved.root = nil
	-- the operator spot faces AWAY from the turret: turn the explorer towards their harvester first, then put
	-- the camera behind them, so the device is framed in view instead of wrapped around the camera
	pcall(function()
		local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local m = myHarvester()
		local head = m and m:FindFirstChild("Head", true)
		if r and head then
			local hp = if head:IsA("Model") then head:GetPivot().Position else (head :: BasePart).Position
			local up = r.CFrame.UpVector
			local to = hp - r.Position
			local flat = to - up * to:Dot(up)
			if flat.Magnitude > 0.5 then
				r.CFrame = CFrame.lookAt(r.Position, r.Position + flat.Unit, up)
			end
		end
		local controllers = script.Parent.Parent:FindFirstChild("Controllers")
		local cc = controllers and controllers:FindFirstChild("CameraController")
		if cc then
			(require(cc) :: any).snapBehind()
		end
	end)
	local c = cam()
	c.FieldOfView = saved.fov or 70
	UserInputService.MouseIconEnabled = if saved.mouseIcon == nil then true else saved.mouseIcon
	pcall(function()
		GuiService.TouchControlsEnabled = if saved.touchControls == nil then true else saved.touchControls
	end)
	setBeaconVisible(myHarvester(), true)
	if session then
		setPlanetLabelVisible(session.slot, true)
	end
	if ownerBillboard then
		ownerBillboard.Enabled = true
	end
	hud:setTutorial(nil)
	hud:setActive(false)
	session = nil
	lockId, hoverId = nil, nil
	touchInput = nil
	refreshPrompts()
	Audio.play("exit")
	if EXIT_TEXT[reason] then
		hud:showToast(EXIT_TEXT[reason])
	end
end

function HarvestController.exit()
	if not active then
		return
	end
	stopMode("exit")
	task.spawn(ProfileClient.request, "Harvest_Exit", {})
end

local ENTER_TEXT: { [string]: string } = {
	TOO_FAR = "Step closer to the harvester console.",
	NOT_READY = "Your profile is still loading — try again in a moment.",
	NO_HARVESTER = "This harvester isn't assigned to you.",
	DEAD = "You can't operate the harvester right now.",
	RATE_LIMITED = "One moment…",
	TIMEOUT = "The harvester didn't respond — try again.",
}

function HarvestController.enter()
	if active or entering then
		return
	end
	entering = true
	task.spawn(function()
		local ok, code = ProfileClient.request("Harvest_Enter", {})
		entering = false
		if not ok and hud then
			Audio.play("denied")
			hud:showToast(ENTER_TEXT[code or ""] or ("Harvester unavailable (" .. tostring(code) .. ")"), COLORS.RED)
		end
	end)
end

---------------------------------------------------------------- world (prompts, idle animation, onboarding)

refreshPrompts = function()
	if not harvestFolder then
		return
	end
	for _, m in harvestFolder:GetChildren() do
		local prompt = m:FindFirstChild("PF_HarvestPrompt", true) :: ProximityPrompt?
		if prompt then
			prompt.Enabled = (not active) and m:GetAttribute("PFOwnerUserId") == player.UserId
		end
	end
end

local hooked: { [Instance]: boolean } = {}

local function hookHarvester(m: Instance)
	if hooked[m] or not m:IsA("Model") then
		return
	end
	hooked[m] = true
	m:GetAttributeChangedSignal("PFOwnerUserId"):Connect(refreshPrompts)
	local prompt = m:WaitForChild("Static", 10) and m:FindFirstChild("PF_HarvestPrompt", true) :: ProximityPrompt?
	if prompt then
		prompt.Triggered:Connect(function(who)
			if who == player then
				HarvestController.enter()
			end
		end)
	end
	refreshPrompts()
end

local function updateOwnerBillboard()
	local m = myHarvester()
	local anchor = m and m:FindFirstChild("Static") and m.Static:FindFirstChild("LabelAnchor")
	if not anchor then
		if ownerBillboard then
			ownerBillboard:Destroy()
			ownerBillboard = nil
		end
		return
	end
	if ownerBillboard and ownerBillboard.Parent and ownerBillboard.Adornee == anchor then
		return
	end
	if ownerBillboard then
		ownerBillboard:Destroy()
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "PF_MyHarvester"
	bb.ResetOnSpawn = false -- QA-2026-11-21: the marker was destroyed by the PlayerGui reset on respawn and never rebuilt
	bb.Adornee = anchor :: BasePart
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2500
	bb.Size = UDim2.fromOffset(170, 44)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 14, 0)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.2
	t.Text = "YOUR HARVESTER\n▼"
	t.Parent = bb
	bb.Parent = player:WaitForChild("PlayerGui")
	ownerBillboard = bb
end

local function setBeaconOnly(m: Model?, visible: boolean)
	local static = m and m:FindFirstChild("Static")
	local b = static and static:FindFirstChild("Beacon") :: BasePart?
	if b then
		b.LocalTransparencyModifier = if visible then 0 else 1
	end
end

local function onboardingTick()
	if active or not hud then
		return
	end
	hud:setViewport(cam().ViewportSize)
	updateOwnerBillboard()
	-- Guidance lives in ONE place: Developer A's objective card (Onboarding) + the harvester's own prompt.
	-- (This module used to show a second, competing banner at the top of the screen.)
	hud:setBanner(nil)
	if ProfileClient.get() then
		-- the sky beacon + YOUR HARVESTER marker only guide players who have never harvested; afterwards
		-- they are visual noise (the harvester itself stays visible and promptable)
		local guiding = not tutorialDone()
		setBeaconOnly(myHarvester(), guiding)
		if ownerBillboard then
			ownerBillboard.Enabled = guiding
		end
	end
end

local idleClock = 0
local function idleAnimate(dt: number)
	idleClock += dt
	if not harvestFolder then
		return
	end
	local camPos = cam().CFrame.Position
	for _, m in harvestFolder:GetChildren() do
		local slot = m:GetAttribute("PFSlot")
		if type(slot) ~= "number" then
			continue
		end
		local L = HarvestLayout.forSlot(slot)
		if (L.base.Position - camPos).Magnitude > 600 then
			continue
		end
		local ring = m:FindFirstChild("Collector") and m.Collector:FindFirstChild("Ring") :: Model?
		if ring then
			local speed = if active and session and session.slot == slot then 2.2 else 0.6
			ring:PivotTo(HarvestLayout.localCFrame(L, DEVICE.COLLECTOR) * CFrame.Angles(0, 0, idleClock * speed))
		end
		if not (active and session and session.slot == slot) then
			local head = m:FindFirstChild("Head") :: Model?
			if head then
				local yaw = 0.45 * math.sin(idleClock * 0.25 + slot)
				local pitch = 0.5 + 0.12 * math.sin(idleClock * 0.4 + slot * 2)
				head:PivotTo(headFor(slot) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0))
			end
		end
	end
end

---------------------------------------------------------------- init

function HarvestController.init(opts: { gravity: any })
	gravity = opts.gravity
	container = Instance.new("Folder")
	container.Name = "PF_HarvestClient"
	container.Parent = Workspace
	FX.setContainer(container)
	-- equipped Harvester VFX style (cosmetic only)
	local function syncStyle(snap: any)
		local cos = snap and snap.planet and snap.planet.cosmetics
		FX.setStyle(cos and cos.HarvesterFX)
	end
	syncStyle(ProfileClient.get())
	ProfileClient.Changed:Connect(syncStyle)
	hud = HUD.new(player:WaitForChild("PlayerGui"))
	hud.onFire = function()
		pressFire()
		releaseFire()
	end
	hud.onFirePress = pressFire
	hud.onFireRelease = releaseFire
	hud.onCycle = cycleTarget
	hud.onExit = HarvestController.exit
	setDevice(deviceFromInputType(UserInputService:GetLastInputType()) or (if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "touch" else "keyboard"))
	hud:setHints(device)

	UserInputService.LastInputTypeChanged:Connect(function(t)
		local d = deviceFromInputType(t)
		if d then
			setDevice(d)
			if active and session and session.tutorial then
				setTutorialStep(tutorial.step)
			end
		end
	end)
	UserInputService.InputBegan:Connect(function(input, gpe)
		if not active then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 and not gpe then
			mouseHeld = true
			pressFire()
		elseif t == Enum.UserInputType.Touch and not gpe then
			touchInput = input
			reticle = touchPos(input)
		elseif t == Enum.UserInputType.Keyboard then
			local k = KEYMAP[input.KeyCode]
			if k then
				keys[k] = true
				mouseAim = false
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and mouseHeld then
			mouseHeld = false
			releaseFire()
		end
		local k = KEYMAP[input.KeyCode]
		if k then
			keys[k] = false
		end
		if input == touchInput then
			touchInput = nil
		end
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			stickL = Vector2.zero
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stickR = Vector2.zero
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseMovement then
			if not mouseAim and mouseAnchor and (UserInputService:GetMouseLocation() - mouseAnchor).Magnitude < MOUSE_RECLAIM_PX then
				return -- tiny jitter: keep the Tab-selected target
			end
			mouseAim = true
			mouseAnchor = nil
		elseif t == Enum.UserInputType.Touch and input == touchInput then
			reticle = touchPos(input)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
			stickL = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stickR = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)

	player.CharacterRemoving:Connect(function()
		stopMode("died")
	end)
	player:GetAttributeChangedSignal("PF_Slot"):Connect(function()
		if active then
			stopMode("slot")
		end
		refreshPrompts()
	end)

	RunService.RenderStepped:Connect(idleAnimate)

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("PF_Remotes", 30)
		local ev = remotes and remotes:WaitForChild("Harvest_Event", 30) :: RemoteEvent?
		if not ev then
			warn("[PF] Harvest_Event remote missing; Cosmic Core Hunt disabled")
			return
		end
		ev.OnClientEvent:Connect(function(msg)
			if type(msg) ~= "table" then
				return
			end
			if msg.type == "session" then
				if msg.active then
					startMode(msg)
				else
					stopMode(msg.reason or "server")
				end
			elseif msg.type == "spawn" and active then
				for _, spec in msg.meteors or {} do
					addMeteor(spec)
				end
			end
		end)
		ProfileClient.Changed:Connect(function()
			if active then
				refreshPanel()
			end
		end)
	end)

	task.spawn(function()
		local f = Workspace:WaitForChild("PF_Harvest", 60) :: Folder?
		if not f then
			warn("[PF] PF_Harvest folder missing")
			return
		end
		harvestFolder = f
		for _, m in f:GetChildren() do
			task.spawn(hookHarvester, m)
		end
		f.ChildAdded:Connect(function(m)
			task.spawn(hookHarvester, m)
		end)
	end)

	task.spawn(function()
		while true do
			local ok, err = pcall(onboardingTick)
			if not ok then
				warn("[PF] harvest onboarding:", err)
			end
			task.wait(0.5)
		end
	end)
end

function HarvestController.isActive(): boolean
	return active
end

return HarvestController
