--!strict
-- EventConfig — owner: Live Gameplay. Tuning for COSMIC WORLD EVENTS (scheduler, Meteor Shower, Solar Storm,
-- Cosmic Convergence), lightweight social features and the client effect budgets. Shared by the server rules
-- (authority) and the client presentation (read-only). Every number that changes how an event plays lives here.
-- Times are seconds; positions come from WorldLayout.
local EventConfig = {}

EventConfig.VERSION = 1

-- Economy reason for every event reward. "Event" is used as soon as Developer B whitelists it in
-- EconomyConfig.REASONS; until then the already-whitelisted "Quest" reason is used (events are live quests).
EventConfig.REWARD_REASON = "Event"
EventConfig.REWARD_REASON_FALLBACK = "Quest"

----------------------------------------------------------------------------------------------------
-- Scheduler (server-authoritative)
EventConfig.SCHEDULER = {
	enabled = true,
	firstDelay = { 120, 210 }, -- after server start, before the first event is announced
	gap = { 210, 420 }, -- between event STARTS (uniform random in range); compatible events may overlap
	retry = 30, -- nothing could start (cooldowns / incompatible / nobody online): try again after
	maxConcurrent = 2,
	minPlayers = 1,
	incoming = 20, -- announcement phase ("Meteor Shower in 0:20") before an event becomes active
	ending = 6, -- wrap-up phase (effects fade, summaries) before objects are cleaned up
	testScale = 0.2, -- developer test mode multiplies every duration, cooldown and gap by this
	tickRate = 4, -- server event ticks per second
}

EventConfig.ORDER = { "MeteorShower", "SolarStorm", "CosmicConvergence" }

-- channels: two events may run together only if their channel sets do not intersect
--   activity = asks for the player's attention / input, sky = fills orbital space, lighting = owns the
--   environment light grade, station = uses THE FORGE plaza.
EventConfig.EVENTS = {
	MeteorShower = {
		id = "MeteorShower",
		name = "Meteor Shower",
		icon = "matter",
		color = Color3.fromRGB(255, 196, 92),
		tagline = "A wave of meteors streaks through planetary orbits.",
		effect = "Capture glowing meteors near you for bonus matter.",
		howTo = {
			"Look for glowing meteors around any planet or THE FORGE",
			"Click or tap one within range, or press F / R1 to capture the highlighted one",
			"Golden meteors are rare and carry more matter plus credits",
		},
		duration = 150,
		cooldown = 540,
		weight = 3,
		channels = { "activity", "sky" },
	},
	SolarStorm = {
		id = "SolarStorm",
		name = "Solar Storm",
		icon = "energy",
		color = Color3.fromRGB(255, 138, 61),
		tagline = "Charged solar winds wash over the system.",
		effect = "Energy reactions return half of their matter cost.",
		howTo = {
			"Open the DNA Lab on your own planet",
			"Reactions marked SOLAR SURGE return 50% of their matter when they complete",
			"The surge works a limited number of times per storm",
		},
		duration = 180,
		cooldown = 660,
		weight = 2,
		channels = { "lighting" },
	},
	CosmicConvergence = {
		id = "CosmicConvergence",
		name = "Cosmic Convergence",
		icon = "team",
		color = Color3.fromRGB(120, 230, 255),
		tagline = "THE FORGE reactor is destabilizing — every explorer can help.",
		effect = "Stabilize the station reactor together for shared rewards.",
		howTo = {
			"Travel to THE FORGE station",
			"Hold the prompt on flickering stabilizer conduits around the reactor",
			"Carry flux cells from the plaza rim into the reactor intake",
			"Everyone who helped is rewarded by contribution, even after leaving the station",
		},
		duration = 240,
		cooldown = 780,
		weight = 2,
		channels = { "activity", "station" },
	},
}

----------------------------------------------------------------------------------------------------
-- Meteor Shower
EventConfig.SHOWER = {
	spawnInterval = 1.0, -- seconds between spawn passes
	perPass = 3, -- at most this many meteors created per pass (all zones together)
	maxPerZone = 7, -- alive at once in one orbital zone
	maxTotal = 40, -- alive at once on the server
	life = { 16, 26 },
	-- zone 0 = THE FORGE: horizontal rings around the reactor, above the plaza deck
	station = { radius = { 34, 76 }, height = { 9, 34 }, speed = { 0.09, 0.2 } },
	-- zones 1..8 = planets with at least one player within presenceRadius of the planet surface
	planet = { altitude = { 10, 34 }, speed = { 0.05, 0.1 }, presenceRadius = 160, nearChance = 0.75, nearJitter = 0.28, nearLead = 0.35 },
	captureRange = 80, -- studs from the character root to the meteor
	rangeTolerance = 12,
	lagWindow = 0.4, -- a capture is also accepted against the meteor position this many seconds earlier
	perPlayerCap = 28, -- captures per player per shower
	xpPerCapture = 2,
	rareChance = 0.07,
	materials = { IceMatter = 3, MagmaMatter = 3, CrystalFragments = 2, PlasmaMatter = 2, BioEssence = 2 },
	amount = { 1, 3 },
	rareAmount = { 4, 6 },
	rareCredits = 20,
}

----------------------------------------------------------------------------------------------------
-- Solar Storm
EventConfig.STORM = {
	categories = { cosmic = true, thermal = true }, -- ReactionRegistry categories that count as energy reactions
	reactions = { R18 = true, R20 = true, R30 = true }, -- plus these tuning reactions (Heat Surge, Energy Grounding, Stellar Charge)
	refundShare = 0.5, -- share of each material cost returned when a boosted reaction completes (floored; 1-unit costs return nothing)
	noRefund = { CosmicCatalyst = true }, -- rare components are never refunded
	creditBonus = 10,
	maxSurges = 8, -- boosted completions per player per storm
}

----------------------------------------------------------------------------------------------------
-- Cosmic Convergence (THE FORGE reactor)
EventConfig.CONVERGENCE = {
	targetBase = 140, -- stability needed with one eligible player
	targetPerExtra = 70, -- + per additional eligible player at activation (not in a rift), counted up to maxCounted
	maxCounted = 8,
	conduits = 4,
	conduitRadius = 28, -- around the reactor
	holdTime = 1.6,
	promptDistance = 10,
	conduitCooldown = 5, -- a stabilized conduit stays stable at least this long
	unstableDelay = { 1.2, 3.0 },
	points = { calibrate = 10, deliver = 18, assist = 4, sync = 4 },
	syncWindow = 3, -- two calibrations by different explorers within this window: both get the sync bonus
	assistWindow = 1.5, -- finishing a hold on a conduit someone else just stabilized still earns assist points
	flux = { maxActive = 3, perPlayers = 3, radius = 70, carryTime = 30, respawn = 4, pickupDistance = 9, intakeDistance = 16, holdTime = 0.3, injectTime = 0.6 },
	minContribution = 10, -- one finished task makes a participant eligible
	maxShare = 1.5, -- reward share is capped (no reason to farm past 1.5x a fair share)
	stages = { 0.34, 0.67, 1.0 },
	partialFloor = 0.3, -- a timed-out convergence pays participants only above this progress
	rewards = {
		-- reward = (base + share * perShare) * outcomeMultiplier; share = contribution / fair share (target / eligible)
		credits = { base = 50, share = 150 },
		energy = { base = 10, share = 40 },
		xp = { base = 30, share = 80 },
		catalystChance = 0.6,
		catalystMinShare = 0.5,
		catalysts = { "EmberCore", "FrostSeed", "IonSpark" },
		componentId = "CosmicCatalyst", -- material
		componentMinShare = 1.0,
		partialScale = 0.5,
	},
	pendingTtl = 1200, -- rewards of participants who left the server are kept this long for a rejoin
	stationRadius = 130, -- "at the station" for conduit scheduling
}

----------------------------------------------------------------------------------------------------
-- Social
EventConfig.SOCIAL = {
	reactions = {
		Stellar = { id = "Stellar", label = "Stellar", icon = "star" },
		Wow = { id = "Wow", label = "Wow", icon = "eye" },
		Inspiring = { id = "Inspiring", label = "Inspiring", icon = "flag" },
	},
	reactionOrder = { "Stellar", "Wow", "Inspiring" },
	minSessionSeconds = 30, -- in this server before reactions count (anti join-and-spam)
	minAccountAgeDays = 1,
	changeCooldown = 20, -- seconds before the same visitor may change their reaction on a planet
	showcaseHold = 3, -- a showcase view must be open this long before it counts as "seen"
	showcaseValid = 180,
	presenceExtra = 60, -- "on a planet" = within PLANET_RADIUS + this of its centre
	ownerNotifyInterval = 12,
	visitorNotifyInterval = 300,
	visitCooldown = 4,
}

----------------------------------------------------------------------------------------------------
-- Client presentation budgets (Developer A: see INTERFACES §9 / EVENTS_VFX_GUIDE)
EventConfig.FX = {
	renderDistance = 900, -- meteors farther than this from the camera are not drawn
	budgets = {
		full = { meteors = 26, trails = true, lights = 6, emitters = 6, stormRate = 40 },
		reduced = { meteors = 16, trails = true, lights = 2, emitters = 3, stormRate = 16 },
		minimal = { meteors = 10, trails = false, lights = 0, emitters = 0, stormRate = 0 },
	},
	palette = {
		meteor = Color3.fromRGB(255, 196, 92),
		rare = Color3.fromRGB(255, 236, 150),
		stormOrange = Color3.fromRGB(255, 138, 61),
		stormViolet = Color3.fromRGB(155, 92, 255),
		convergence = Color3.fromRGB(120, 230, 255),
		unstable = Color3.fromRGB(255, 120, 70),
	},
}

function EventConfig.get(eventId: string): any
	return (EventConfig.EVENTS :: any)[eventId]
end

-- Two events can overlap only if they share no channel.
function EventConfig.compatible(a: string, b: string): boolean
	local da, db = EventConfig.get(a), EventConfig.get(b)
	if not da or not db or a == b then
		return false
	end
	for _, ca in da.channels do
		if table.find(db.channels, ca) then
			return false
		end
	end
	return true
end

return EventConfig
