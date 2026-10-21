--!strict
-- Social roleplay (PLAN.md Phase 13; docs/phase-13-contracts.md "Social"): tunables and words for
--
--   meets      Services/MeetService: when `meet.minCars` players' cars stand parked in one MeetSpot's footprint, the
--              meet is announced once to everyone (Net FeedUpdate) and not again at that spot until it has dropped
--              below minCars for `meet.cooldownSeconds`.
--   feed       Controllers/FeedController and UI/Phone/FeedApp: the phone's Feed of recent server events, newest
--              first, plus a toast for each new one.
--   nametags   Services/SocialSetupService keeps each player's best job title in a player attribute;
--              Controllers/NametagController draws the display name and that title over every character.
--   chat       Services/SocialSetupService and Controllers/ChatSetupController: TextChatService's own chat, bubbles
--              on. Nothing here sends or rewrites player text, so Roblox's filtering always applies.
--   emotes     UI/Phone/EmotesApp: Roblox's default emotes, on foot only.
--
-- Data plus one pure helper, bestTitle (the server publishes it; tests/Nametags.spec checks it). No Roblox services.

local Jobs = require(script.Parent.Jobs)

-- One Feed entry as FeedUpdate carries it. `at` is server time (Workspace:GetServerTimeNow()). A meet entry also
-- names its spot (a Config/MapLayout id, so the Feed can offer directions) and how many cars made it.
export type FeedEntry = {
	id: string,
	kind: string,
	text: string,
	at: number,
	meetSpotId: string?,
	cars: number?,
}

-- One emote button: `id` is the name Roblox's default emotes go by (Humanoid:PlayEmote and the Animate script).
export type Emote = { id: string, label: string }

local Social = {
	meet = {
		spotTag = "MeetSpot", -- Config/MapLayout locations with this tag are meet spots
		minCars = 4, -- parked cars of different players at one spot that make a meet
		-- After a meet at a spot drops below minCars, a new meet there is announced only once it has been below for
		-- this long; one that fills up again sooner is the same meet carrying on (no second announcement).
		cooldownSeconds = 600,
		-- Studs a car's pivot may stand outside the spot's rectangle and still count (Config/LightShows'
		-- insideFootprint handles the height band).
		footprintMargin = 2,
	},

	feed = {
		maxEntries = 20, -- the server keeps and every client shows at most this many, newest first
		toastKind = "info", -- the toast's kind (Config/Gps toast.kindColors)
		kinds = {
			meet = "meet",
		},
		-- Words, filled in where noted.
		text = {
			meetStarted = "Car meet at %s! %d cars parked up.", -- the spot's name, the cars
			empty = "Nothing yet. Car meets and other big moments on this server show up here.",
			kindLabels = { meet = "Car meet" } :: { [string]: string },
			directions = "Directions",
			justNow = "Just now",
			minutesAgo = "%d min ago",
			hoursAgo = "%d h ago",
		},
		-- Ages: under justNowSeconds says "Just now", under an hour in minutes, after that in hours.
		justNowSeconds = 60,
		secondsPerMinute = 60,
		secondsPerHour = 3600,
	},

	nametag = {
		-- The player attribute Services/SocialSetupService keeps: the title of the player's best job level
		-- (bestTitle), or nil while they have no job XP.
		titleAttribute = "JobTitle",
		showOwn = false, -- your own nametag stays hidden (like Roblox's own names)
		guiName = "Nametag", -- the BillboardGui's name, inside the character's head
		size = Vector2.new(220, 50), -- px, a fixed size at every distance so it stays readable
		studsOffset = Vector3.new(0, 2.6, 0), -- above the head
		maxDistance = 90, -- studs from the camera beyond which it hides
		nameTextSize = 18,
		titleTextSize = 14,
		padding = 6, -- px inside the panel, each side
		panelTransparency = 0.2, -- the dark panel keeps 4.5:1 for the text over a bright sky
		cornerRadius = 10,
		-- Hidden on a character sitting in a car going faster than hideAboveMph, shown again under showBelowMph (the
		-- gap keeps it from flickering around one speed).
		hideAboveMph = 15,
		showBelowMph = 10,
		-- Seated characters' car speeds are checked this often (seconds); the check runs only while someone sits
		-- in a car.
		speedCheckSeconds = 0.5,
	},

	chat = {
		bubbles = true, -- TextChatService's BubbleChatConfiguration.Enabled
		window = true, -- its chat window and input bar
	},

	emotes = {
		-- Roblox's default emotes, in the order the Emotes app lists them.
		list = {
			{ id = "wave", label = "Wave" },
			{ id = "point", label = "Point" },
			{ id = "cheer", label = "Cheer" },
			{ id = "laugh", label = "Laugh" },
			{ id = "dance", label = "Dance" },
			{ id = "dance2", label = "Dance 2" },
			{ id = "dance3", label = "Dance 3" },
		} :: { Emote },
		columns = 2, -- buttons side by side in the app
		animateScript = "Animate", -- the character's default animation script
		playEmoteBindable = "PlayEmote", -- its emote hook, used when the avatar has no such emote equipped
		text = {
			intro = "Tap an emote to play it. Walking stops it.",
			onFootOnly = "Get out of your car to use emotes.",
			failed = "That emote didn't play. Try standing still.",
		},
	},

	-- Studio only (CLAUDE.md hard rule 8): stand-in cars for Dev/SocialTests (Net DevSocial). At a MeetSpot they fill
	-- the meet; on a claimed HousePlot one stands on the house's home charger (Config/Houses chargerPad), nobody's car,
	-- below full, so the house test can check that it doesn't charge there.
	dev = {
		defaultMeetSpot = "lk_overlook",
		housePlotTag = "HousePlot", -- Config/MapLayout locations a stand-in can be parked at the home charger of
		dummyAttribute = "MeetDummyCar", -- true on a stand-in car; MeetService counts it as its own player's car
		vehicles = { "ohm_summit", "ohm_grand", "ohm_spark", "ohm_current" }, -- cycled; built by Dev/VehicleBuilder
		homeVehicle = "ohm_spark", -- the stand-in on a home charger: a battery car
		-- The home stand-in's energy level: under Config/Energy charging.startBelow, so a charger would fill it. Set
		-- once Services/EnergyService has started sampling it, which it marks with this attribute.
		homeEnergyLevel = 0.5,
		energyKindAttribute = "EnergyKind",
		takenRadius = 8, -- studs: a slot with a car's pivot this close is taken
		messages = {
			studioOnly = "Studio only.",
			noSpot = "No meet spot named %s.", -- the id
			full = "Every slot at %s is taken.", -- the spot's name
			noModel = "No built model for the stand-in car. Run Dev/VehicleBuilder.buildAll in Edit mode.",
			parked = "Parked a stand-in car at %s: %d parked there now.", -- the spot's name, the count
			noHouse = "Nobody has claimed %s, so it has no home charger.", -- the plot's address
			parkedHome = "Parked a stand-in car on the home charger at %s.", -- the plot's address
			cleared = "Cleared %d stand-in cars.", -- how many
		},
	},
}

-- The 1-based level `xp` reaches on `ladder` (level 1 for anything below the second threshold, as JobService's
-- Levels.levelOf).
local function levelOn(ladder: { Jobs.Level }, xp: number): number
	local level = 1
	for index, def in ladder do
		if xp >= def.xp then
			level = index
		else
			break
		end
	end
	return level
end

-- The nametag title for a player's job XP (PlayerData.jobs.xp: XP by job type): the title of their best job level,
-- or nil when they have no XP in any job yet. Best is the highest level; a tie goes to the job with more XP, then
-- to the job listed first in Config/Jobs.order. A level without a title shows the job's displayName.
function Social.bestTitle(xp: { [string]: number }?): string?
	if type(xp) ~= "table" then
		return nil
	end
	local bestType: string? = nil
	local bestLevel, bestXp = 0, 0
	for _, jobType in Jobs.order do
		local amount = xp[jobType]
		local ladder = Jobs.levels[jobType]
		if type(amount) ~= "number" or amount ~= amount or amount <= 0 or ladder == nil then
			continue
		end
		local level = levelOn(ladder, amount)
		if level > bestLevel or (level == bestLevel and amount > bestXp) then
			bestType, bestLevel, bestXp = jobType, level, amount
		end
	end
	if bestType == nil then
		return nil
	end
	local def = Jobs.levels[bestType][bestLevel]
	if def ~= nil and def.title ~= nil then
		return def.title
	end
	local job = Jobs.types[bestType]
	return if job then job.displayName else nil
end

return Social
