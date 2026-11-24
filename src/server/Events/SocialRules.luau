--!strict
-- SocialRules — owner: Live Gameplay. Pure planet-reaction rules with abuse protection: valid kinds only, no
-- reactions to your own planet, a minimum time in the server and account age, the reacting player must actually
-- be viewing the planet (standing on it, or a showcase view held for a few seconds), ONE reaction per visitor per
-- planet per server session (changeable after a cooldown, never stacked). Session memory only: nothing persisted.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventConfig = require(ReplicatedStorage.PF_Shared.Events.EventConfig)

local SocialRules = {}

function SocialRules.new(): any
	return { given = {} :: { [number]: { [number]: any } }, counts = {} :: { [number]: any } }
end

local function zero(): any
	local c: any = { total = 0 }
	for _, k in EventConfig.SOCIAL.reactionOrder do
		c[k] = 0
	end
	return c
end

-- liker = { userId, sessionSeconds, accountAge }, ctx = { ownerId: number?, present: boolean }
function SocialRules.react(st: any, liker: any, ctx: any, kind: any, now: number): (boolean, string, any?)
	local S = EventConfig.SOCIAL
	if type(kind) ~= "string" or not S.reactions[kind] then
		return false, "INVALID_KIND", nil
	end
	local owner = ctx.ownerId
	if type(owner) ~= "number" or owner == 0 then
		return false, "NO_OWNER", nil
	end
	if owner == liker.userId then
		return false, "OWN_PLANET", nil
	end
	if (liker.sessionSeconds or 0) < S.minSessionSeconds then
		return false, "TOO_SOON", nil
	end
	if (liker.accountAge or 0) < S.minAccountAgeDays then
		return false, "ACCOUNT_TOO_NEW", nil
	end
	if not ctx.present then
		return false, "NOT_VIEWING", nil
	end
	local g = st.given[liker.userId]
	if not g then
		g = {}
		st.given[liker.userId] = g
	end
	local prev = g[owner]
	if prev then
		if prev.kind == kind then
			return false, "ALREADY", nil
		end
		if now - prev.at < S.changeCooldown then
			return false, "COOLDOWN", nil
		end
	end
	local c = st.counts[owner]
	if not c then
		c = zero()
		st.counts[owner] = c
	end
	if prev then
		c[prev.kind] = math.max(0, (c[prev.kind] or 0) - 1)
	else
		c.total += 1
	end
	c[kind] = (c[kind] or 0) + 1
	g[owner] = { kind = kind, at = now }
	return true, if prev then "CHANGED" else "OK", { counts = table.clone(c), previous = prev and prev.kind }
end

function SocialRules.countsFor(st: any, ownerId: number): any
	return table.clone(st.counts[ownerId] or zero())
end

function SocialRules.mine(st: any, likerId: number): { [number]: string }
	local out = {}
	for owner, g in st.given[likerId] or {} do
		out[owner] = g.kind
	end
	return out
end

-- The owner left the server: their planet's session counts go with them.
function SocialRules.forgetOwner(st: any, ownerId: number)
	st.counts[ownerId] = nil
	for _, g in st.given do
		g[ownerId] = nil
	end
end

return SocialRules
