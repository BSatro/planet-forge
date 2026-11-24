--!strict
-- CharacterAnimator — owner: Developer A.
-- With Humanoid.EvaluateStateMachine = false the default Animate script no longer receives state
-- changes, so it is disabled and this module plays the same Animation assets (read from the
-- character's own Animate script) based on the gravity controller's state.

export type Mode = "idle" | "walk" | "jump" | "fall"

-- Planet Physics 3.0: ground speed is 23 (walk) / 33 (sprint), far above the walk cycle's natural pace, so
-- "walk" requests switch to the avatar's own run animation above RUN_ON (hysteresis down to RUN_OFF).
-- Playback rate follows speed; capped so a short-legged avatar's cycle never turns into a blur.
local RUN_ON, RUN_OFF = 11, 9
local WALK_REF, RUN_REF = 14.5, 15 -- studs/s that play each cycle at 1x
local RUN_MAX_RATE = 2.2

local CharacterAnimator = {}

local tracks: { [string]: AnimationTrack } = {}
local current: string? = nil
local animateScript: LocalScript? = nil
local animatorRef: Animator? = nil

-- Stops tracks we don't own (e.g. an idle the default Animate script started before it was disabled).
local function stopForeignTracks()
	if not animatorRef then
		return
	end
	for _, t in animatorRef:GetPlayingAnimationTracks() do
		local owned = false
		for _, mine in tracks do
			if mine == t then
				owned = true
				break
			end
		end
		if not owned then
			t:Stop(0.1)
		end
	end
end

local SOURCES = {
	idle = { "idle", "Animation1" },
	walk = { "walk", "WalkAnim" },
	jump = { "jump", "JumpAnim" },
	fall = { "fall", "FallAnim" },
	run = { "run", "RunAnim" },
}

function CharacterAnimator.attach(character: Model)
	CharacterAnimator.detach()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local animate = character:FindFirstChild("Animate")
	if not animator or not animate then
		return
	end
	if animate:IsA("LocalScript") then
		animate.Enabled = false
		animateScript = animate
	end
	animatorRef = animator
	for _, t in animator:GetPlayingAnimationTracks() do
		t:Stop(0.1)
	end
	for mode, path in SOURCES do
		local holder = animate:FindFirstChild(path[1])
		local anim = holder and holder:FindFirstChild(path[2])
		if anim and anim:IsA("Animation") then
			local ok, track = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			if ok and track then
				track.Priority = if mode == "idle" then Enum.AnimationPriority.Idle else Enum.AnimationPriority.Movement
				track.Looped = mode ~= "jump"
				tracks[mode] = track
			end
		end
	end
end

function CharacterAnimator.update(mode: Mode, speed: number)
	local want: string = mode
	if mode == "walk" and tracks.run and (speed >= RUN_ON or (current == "run" and speed > RUN_OFF)) then
		want = "run"
	end
	CharacterAnimator._play(want, speed)
end

function CharacterAnimator._play(mode: string, speed: number)
	if mode ~= current then
		stopForeignTracks()
		if current and tracks[current] then
			tracks[current]:Stop(0.15)
		end
		current = mode
		local t = tracks[mode]
		if t then
			t:Play(0.15)
		end
	end
	if mode == "walk" and tracks.walk then
		tracks.walk:AdjustSpeed(math.clamp(speed / WALK_REF, 0.4, 1.6))
	elseif mode == "run" and tracks.run then
		tracks.run:AdjustSpeed(math.clamp(speed / RUN_REF, 0.75, RUN_MAX_RATE))
	end
end

function CharacterAnimator.detach()
	for _, t in tracks do
		t:Stop(0)
		t:Destroy()
	end
	table.clear(tracks)
	current = nil
	animateScript = nil
	animatorRef = nil
end

function CharacterAnimator.getMode(): string?
	return current
end

return CharacterAnimator
