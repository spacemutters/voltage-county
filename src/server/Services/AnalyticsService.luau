--!strict
-- Game analytics (PLAN.md Phase 12 "Analytics"; docs/phase-12-contracts.md "Ads, analytics, admin"), sent to
-- Roblox's own AnalyticsService (this module is the game's; Roblox's is `RobloxAnalytics` below). Checked on the
-- Roblox docs on 2026-10-20: LogOnboardingFunnelStepEvent(player, step, stepName, customFields?),
-- LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName, customFields?),
-- LogEconomyEvent(player, flowType, currencyType, amount, endingBalance, transactionType, itemSku, customFields?),
-- LogProgressionCompleteEvent(player, pathName, level, levelName, customFields?) and
-- LogCustomEvent(player, eventName, value, customFields?). Events count only from the server of a published game
-- (never Studio or a client); custom fields are up to three strings keyed by
-- Enum.AnalyticsCustomFieldKeys.CustomField01..03.Name; a one-time (onboarding) funnel counts each step once per
-- player, and a later step marks the skipped ones done.
--
-- What is logged and where it comes from. Nothing here needs another service to call it: it watches the save
-- (DataService.onChanged, comparing each update with the last), the cars (CollectionService tag Config/Spawning
-- .vehicleTag) and MonetizationService's grant and pass hooks.
--   onboarding  1 Joined (a save with no car yet), 2 Claimed a car (the first car lands in the garage), 3 First drive
--               (the owner takes their own car's Driver seat, before their first job), 4 First job (job XP first
--               rises), 5 First purchase (any Robux purchase; the item rides along as a custom field, so the item of
--               the purchase Roblox counts is the first-purchase item).
--   designer    funnel "Designer", one funnel session per request (its credit reservation id): 2 Submitted (a
--               reservation appears), 3 Result (it settles; field Outcome: "built" when a design lands in the same
--               update, "refunded" when its credits come back (a refusal, moderation or an error), "spent" otherwise:
--               a mod, or a design discarded), 4 Drove it (the owner first drives a design built this session).
--               Step 1 Opened needs a client signal: designerStep(player, "open", sessionId) is ready for it.
--   revenue     custom events Purchase (every Robux product or pass; fields Item and Kind), CreditPack (the pack
--               mix), SeasonPass (uptake), ClubMonth (field Month: "first" or "renewal", from the save's
--               club.lastGrantMonth) and RewardedAd (AdsService). Payer conversion, Robux per daily player and revenue
--               are Roblox's own monetization dashboards (they need nothing from the game).
--   economy     cash is logged by EconomyService. Design Credits here (currency "DesignCredits"): a source when the
--               balance rises (IAP when a receipt lands in the same update, TimedReward with the club's monthly
--               grant, Gameplay otherwise: streaks, season, events, ads), a sink when a reservation is spent.
--   jobs        a JobCompleted custom event per job (field Job) and a progression event ("Job <type>", Complete)
--               for every level reached.
--   abilities   AbilityUsed (field Ability) when AbilityService sets a car's Ability attribute.
--   light shows LightShowJoined when LightShowService sets a car's LightShowId attribute.
-- In Studio nothing goes to Roblox (it would be dropped); every event is still kept in a short list, recent(), for
-- the admin tools and playtests.
--
-- The comparisons are pure (factsFrom, diff, fields, onboardingStep) so tests/Ads.spec checks them in Edit mode.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RobloxAnalytics: any = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local Abilities = require(ReplicatedStorage.Shared.Config.Abilities)
local Ads = require(ReplicatedStorage.Shared.Config.Ads)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Levels = require(script.Parent.JobService.Levels)

-- DataService is required in Init rather than here: it loads ProfileStore, which talks to DataStores straight away,
-- and the spec requires this module in Edit mode.
type DataServiceModule = typeof(require(script.Parent.DataService))

-- What the comparison keeps of one save.
export type Facts = {
	hasCar: boolean, -- the starter is claimed or a car is owned
	jobXp: { [string]: number },
	totalXp: number,
	lastReceipt: string?, -- the newest PurchaseId in receipts
	balance: number, -- Design Credits
	freeUsed: boolean,
	reserved: { [string]: number }, -- credit reservations by id
	designs: { [string]: boolean }, -- design uids
	clubMonth: string?,
}

-- One thing the comparison found. `kind` says which fields are set:
--   "claimCar", "firstJob"                       (nothing else)
--   "submit"   session, free                     a design or mod request started
--   "result"   session, outcome, designUid?      it settled
--   "source" / "sink"  amount, balance, transaction, sku   Design Credits in or out
--   "job"      jobType, before, after            job XP rose
--   "club"     month, first                      the club's monthly credits landed
export type Event = {
	kind: string,
	session: string?,
	free: boolean?,
	outcome: string?,
	designUid: string?,
	amount: number?,
	balance: number?,
	transaction: string?,
	sku: string?,
	jobType: string?,
	before: number?,
	after: number?,
	month: string?,
	first: boolean?,
}

-- An event kept for recent(): when, whose, what.
export type Record = { at: number, userId: number, name: string, detail: string }

local LOG = "[AnalyticsService]"
local FREE_PREFIX = "free:" -- CreditsService.Ledger.FREE_PREFIX: the free first car's reservation ids
local OWNER_ATTRIBUTE = "OwnerUserId" -- VehicleService stamps every spawned car with its owner
local DESIGN_ATTRIBUTE = "DesignUid" -- ...and a player design with its design uid
local SEATS_FOLDER, DRIVER_SEAT = "Seats", "Driver" -- the vehicle model contract (PLAN.md §6)
local RECENT_KEPT = 60 -- events kept for recent()
local CREDITS_CURRENCY = "DesignCredits"

-- The onboarding funnel's steps, in order (the index is the step number).
local ONBOARDING: { { id: string, name: string } } = {
	{ id = "join", name = "Joined" },
	{ id = "claimCar", name = "Claimed a car" },
	{ id = "firstDrive", name = "First drive" },
	{ id = "firstJob", name = "First job" },
	{ id = "firstPurchase", name = "First purchase" },
}

-- The designer funnel (recurring: one session per request).
local DESIGNER_FUNNEL = "Designer"
local DESIGNER: { { id: string, name: string } } = {
	{ id = "open", name = "Opened the studio" },
	{ id = "submit", name = "Submitted" },
	{ id = "result", name = "Result" },
	{ id = "drive", name = "Drove it" },
}

-- Custom event names (Roblox allows up to 100 per game).
local EVENTS = {
	purchase = "Purchase",
	creditPack = "CreditPack",
	seasonPass = "SeasonPass",
	clubMonth = "ClubMonth",
	rewardedAd = "RewardedAd",
	jobCompleted = "JobCompleted",
	abilityUsed = "AbilityUsed",
	lightShow = "LightShowJoined",
}

local AnalyticsService = {}
AnalyticsService.ONBOARDING = ONBOARDING
AnalyticsService.DESIGNER = DESIGNER
AnalyticsService.EVENTS = EVENTS

local DataService: DataServiceModule? = nil
local monetization: any = nil

local factsOf: { [Player]: Facts } = {}
local onboarded: { [Player]: { [string]: boolean } } = {} -- onboarding steps logged this session
local sessions: { [string]: Player } = {} -- designer sessions seen starting on this server, by reservation id
local built: { [string]: { session: string, player: Player } } = {} -- designs built on this server, not yet driven
local passKnown: { [Player]: { [string]: boolean } } = {} -- pass ownership as first heard this session
local recentList: { Record } = {}
local sendWarned = false

type Sender = (method: string, ...any) -> ()

-- The call that reaches Roblox: `method` on RobloxAnalytics with the arguments.
local function robloxSender(method: string, ...: any)
	local args = table.pack(...)
	local ok, err = pcall(function()
		RobloxAnalytics[method](RobloxAnalytics, table.unpack(args, 1, args.n))
	end)
	if not ok and not sendWarned then
		sendWarned = true
		warn(`{LOG} couldn't log an event (later failures are not reported): {err}`)
	end
end

local customSender: Sender? = nil -- specs (setSender)

-- Pure helpers ----------------------------------------------------------------------------------------------

local function whole(value: any): number
	return if type(value) == "number"
			and value == value
			and value > 0
			and value ~= math.huge
		then math.floor(value)
		else 0
end

-- The custom fields dictionary for up to three string values (Roblox ignores any other keys).
function AnalyticsService.fields(values: { string }): { [string]: string }
	local keys = {
		Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
		Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
		Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
	}
	local result: { [string]: string } = {}
	for i, value in values do
		local key = keys[i]
		if key ~= nil then
			result[key] = value
		end
	end
	return result
end

-- The step number and name of an onboarding step id, or nil.
function AnalyticsService.onboardingStep(id: string): (number?, string?)
	for index, step in ONBOARDING do
		if step.id == id then
			return index, step.name
		end
	end
	return nil, nil
end

local function designerStep(id: string): (number?, string?)
	for index, step in DESIGNER do
		if step.id == id then
			return index, step.name
		end
	end
	return nil, nil
end

-- What the comparison needs from a save (copies; a damaged field reads as empty).
function AnalyticsService.factsFrom(data: any): Facts
	local facts: Facts = {
		hasCar = false,
		jobXp = {},
		totalXp = 0,
		lastReceipt = nil,
		balance = 0,
		freeUsed = false,
		reserved = {},
		designs = {},
		clubMonth = nil,
	}
	if type(data) ~= "table" then
		return facts
	end
	facts.hasCar = data.starterClaimed == true or (type(data.vehicles) == "table" and #data.vehicles > 0)
	local jobs = data.jobs
	if type(jobs) == "table" and type(jobs.xp) == "table" then
		for jobType, xp in jobs.xp do
			if type(jobType) == "string" then
				local amount = whole(xp)
				facts.jobXp[jobType] = amount
				facts.totalXp += amount
			end
		end
	end
	local receipts = data.receipts
	if type(receipts) == "table" and #receipts > 0 then
		local newest = receipts[#receipts]
		facts.lastReceipt = if type(newest) == "string" then newest else nil
	end
	local credits = data.credits
	if type(credits) == "table" then
		facts.balance = whole(credits.balance)
		facts.freeUsed = credits.freeDesignUsed == true
		if type(credits.reserved) == "table" then
			for _, entry in credits.reserved do
				if type(entry) == "table" and type(entry.id) == "string" then
					facts.reserved[entry.id] = whole(entry.amount)
				end
			end
		end
	end
	if type(data.designs) == "table" then
		for _, design in data.designs do
			if type(design) == "table" and type(design.uid) == "string" then
				facts.designs[design.uid] = true
			end
		end
	end
	local club = data.club
	if type(club) == "table" and type(club.lastGrantMonth) == "string" then
		facts.clubMonth = club.lastGrantMonth
	end
	return facts
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- What changed from one save update to the next, in a fixed order (see Event).
function AnalyticsService.diff(before: Facts, after: Facts): { Event }
	local events: { Event } = {}
	if not before.hasCar and after.hasCar then
		table.insert(events, { kind = "claimCar" })
	end
	if before.totalXp <= 0 and after.totalXp > 0 then
		table.insert(events, { kind = "firstJob" })
	end
	for _, jobType in sortedKeys(after.jobXp) do
		local was, now = before.jobXp[jobType] or 0, after.jobXp[jobType]
		if now > was then
			table.insert(events, { kind = "job", jobType = jobType, before = was, after = now })
		end
	end

	-- Credit reservations: new ones are requests; gone ones settled (refunded when the balance came back for them).
	local newDesign: string? = nil
	for _, uid in sortedKeys(after.designs) do
		if not before.designs[uid] then
			newDesign = uid
			break
		end
	end
	local added = 0
	for _, id in sortedKeys(after.reserved) do
		if before.reserved[id] == nil then
			added += after.reserved[id]
			table.insert(
				events,
				{ kind = "submit", session = id, free = string.sub(id, 1, #FREE_PREFIX) == FREE_PREFIX }
			)
		end
	end
	-- Balance the new reservations don't explain: refunds first, anything left is new credits.
	local restored = after.balance - before.balance + added
	local spent = 0
	for _, id in sortedKeys(before.reserved) do
		if after.reserved[id] ~= nil then
			continue
		end
		local amount = before.reserved[id]
		local refunded: boolean
		if string.sub(id, 1, #FREE_PREFIX) == FREE_PREFIX then
			refunded = before.freeUsed and not after.freeUsed
		else
			refunded = amount > 0 and restored >= amount
			if refunded then
				restored -= amount
			end
		end
		local outcome = if refunded then "refunded" elseif newDesign ~= nil then "built" else "spent"
		table.insert(events, {
			kind = "result",
			session = id,
			outcome = outcome,
			designUid = if outcome == "built" then newDesign else nil,
		})
		if not refunded then
			spent += amount
		end
	end
	if spent > 0 then
		table.insert(events, {
			kind = "sink",
			amount = spent,
			balance = after.balance,
			transaction = Enum.AnalyticsEconomyTransactionType.Shop.Name,
			sku = "designer",
		})
	end
	local clubChanged = after.clubMonth ~= nil and after.clubMonth ~= before.clubMonth
	if restored > 0 then
		local transaction: string, sku: string
		if after.lastReceipt ~= nil and after.lastReceipt ~= before.lastReceipt then
			transaction, sku = Enum.AnalyticsEconomyTransactionType.IAP.Name, "purchase"
		elseif clubChanged then
			transaction, sku = Enum.AnalyticsEconomyTransactionType.TimedReward.Name, "club"
		else
			transaction, sku = Enum.AnalyticsEconomyTransactionType.Gameplay.Name, "reward"
		end
		table.insert(
			events,
			{ kind = "source", amount = restored, balance = after.balance, transaction = transaction, sku = sku }
		)
	elseif restored < 0 then
		-- Taken without a reservation (only the Studio balance setter does this).
		table.insert(events, {
			kind = "sink",
			amount = -restored,
			balance = after.balance,
			transaction = Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
			sku = "adjust",
		})
	end
	if clubChanged then
		table.insert(events, { kind = "club", month = after.clubMonth, first = before.clubMonth == nil })
	end
	return events
end

-- Sending ------------------------------------------------------------------------------------------------------

local function remember(player: Player, name: string, detail: string)
	table.insert(recentList, { at = os.time(), userId = player.UserId, name = name, detail = detail })
	while #recentList > RECENT_KEPT do
		table.remove(recentList, 1)
	end
end

-- Logs `method` for `player` (kept in recent(); sent to Roblox outside Studio, or to a spec's sender).
local function send(player: Player, name: string, detail: string, method: string, ...: any)
	remember(player, name, detail)
	local spec = customSender
	if spec ~= nil then
		spec(method, player, ...)
	elseif not RunService:IsStudio() then
		robloxSender(method, player, ...)
	end
end

-- The latest events, oldest first (copies), for the admin tools and playtests.
function AnalyticsService.recent(): { Record }
	local list: { Record } = {}
	for _, record in recentList do
		table.insert(list, table.clone(record))
	end
	return list
end

-- Specs: route events to `fn(method, player, ...)` instead of Roblox, Studio included (nil puts Roblox back), and
-- forget what was logged this session.
function AnalyticsService.setSender(fn: Sender?)
	customSender = fn
	table.clear(onboarded)
	table.clear(recentList)
end

-- Public events (other services may call these; the watchers below already cover everything listed in the header)

-- One onboarding step, at most once per player per session (Roblox counts it once per player anyway).
function AnalyticsService.onboarding(player: Player, id: string, fields: { string }?)
	local step, name = AnalyticsService.onboardingStep(id)
	if step == nil or name == nil then
		return
	end
	local done = onboarded[player]
	if done == nil then
		done = {}
		onboarded[player] = done
	end
	if done[id] then
		return
	end
	done[id] = true
	send(player, "Onboarding", name, "LogOnboardingFunnelStepEvent", step, name, AnalyticsService.fields(fields or {}))
end

-- One step of the designer funnel for request `session` (open, submit, result, drive).
function AnalyticsService.designerStep(player: Player, id: string, session: string, fields: { string }?)
	local step, name = designerStep(id)
	if step == nil or name == nil then
		return
	end
	send(
		player,
		DESIGNER_FUNNEL,
		`{name} {session}`,
		"LogFunnelStepEvent",
		DESIGNER_FUNNEL,
		session,
		step,
		name,
		AnalyticsService.fields(fields or {})
	)
end

local function custom(player: Player, name: string, value: number, values: { string })
	send(player, name, table.concat(values, ", "), "LogCustomEvent", name, value, AnalyticsService.fields(values))
end

-- A Robux purchase: a developer product (`kind` from Config/Monetization.productInfo, or "cosmetic") or a pass.
function AnalyticsService.purchase(player: Player, key: string, kind: string)
	local values = { `Item - {key}`, `Kind - {kind}` }
	custom(player, EVENTS.purchase, 1, values)
	if kind == "credits" then
		custom(player, EVENTS.creditPack, 1, { `Pack - {key}` })
	elseif key == "seasonPass" then
		custom(player, EVENTS.seasonPass, 1, {})
	end
	AnalyticsService.onboarding(player, "firstPurchase", values)
end

-- A rewarded video ad played (AdsService); `result` is the Enum.ShowAdResult name.
function AnalyticsService.rewardedAd(player: Player, result: string)
	custom(player, EVENTS.rewardedAd, 1, { `Result - {result}` })
end

function AnalyticsService.abilityUsed(player: Player, ability: string)
	custom(player, EVENTS.abilityUsed, 1, { `Ability - {ability}` })
end

function AnalyticsService.lightShowJoined(player: Player)
	custom(player, EVENTS.lightShow, 1, {})
end

-- Job XP rose from `before` to `after` for `jobType`: one job done, plus a progression event per level reached.
function AnalyticsService.jobProgress(player: Player, jobType: string, before: number, after: number)
	custom(player, EVENTS.jobCompleted, 1, { `Job - {jobType}` })
	for _, level in Levels.levelsGained(Levels.ladder(jobType), before, after) do
		send(
			player,
			"Progression",
			`{jobType} level {level}`,
			"LogProgressionCompleteEvent",
			`Job {jobType}`,
			level,
			`Level {level}`
		)
	end
end

-- Applies one comparison's events.
local function dispatch(player: Player, events: { Event })
	for _, event in events do
		local kind = event.kind
		if kind == "claimCar" then
			AnalyticsService.onboarding(player, "claimCar")
		elseif kind == "firstJob" then
			AnalyticsService.onboarding(player, "firstJob")
		elseif kind == "job" then
			AnalyticsService.jobProgress(player, event.jobType or "", event.before or 0, event.after or 0)
		elseif kind == "submit" then
			local session = event.session or ""
			sessions[session] = player
			AnalyticsService.designerStep(
				player,
				"submit",
				session,
				{ if event.free then "Kind - free" else "Kind - paid" }
			)
		elseif kind == "result" then
			local session = event.session or ""
			-- Only requests seen starting here (a reservation a crashed server left is refunded on join, not a result).
			if sessions[session] == player then
				sessions[session] = nil
				local designUid = event.designUid
				if designUid ~= nil then
					built[designUid] = { session = session, player = player }
				end
				AnalyticsService.designerStep(player, "result", session, { `Outcome - {event.outcome or "spent"}` })
			end
		elseif kind == "source" or kind == "sink" then
			local amount, balance = event.amount or 0, event.balance or 0
			local flow = if kind == "source"
				then Enum.AnalyticsEconomyFlowType.Source
				else Enum.AnalyticsEconomyFlowType.Sink
			send(
				player,
				"Credits",
				`{kind} {amount} ({event.sku})`,
				"LogEconomyEvent",
				flow,
				CREDITS_CURRENCY,
				amount,
				balance,
				event.transaction or Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
				event.sku or "other"
			)
		elseif kind == "club" then
			custom(player, EVENTS.clubMonth, 1, { if event.first then "Month - first" else "Month - renewal" })
		end
	end
end

-- Watchers -----------------------------------------------------------------------------------------------------

local function onSaveChanged(player: Player, data: any)
	local facts = AnalyticsService.factsFrom(data)
	local before = factsOf[player]
	factsOf[player] = facts
	if before == nil then
		-- The save just loaded: nothing to compare yet. A player with no car yet is at the start of the funnel.
		if not facts.hasCar then
			AnalyticsService.onboarding(player, "join")
		end
		return
	end
	dispatch(player, AnalyticsService.diff(before, facts))
end

local function ownerOf(model: Instance): Player?
	local userId = model:GetAttribute(OWNER_ATTRIBUTE)
	return if type(userId) == "number" then Players:GetPlayerByUserId(userId) else nil
end

-- The owner sat in their own car's Driver seat.
local function onDriverSeated(model: Instance, seat: Seat)
	local occupant = seat.Occupant
	local character = if occupant ~= nil then occupant.Parent else nil
	if character == nil or model:GetAttribute(Garage.testDriveAttribute) == true then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if player == nil or player ~= ownerOf(model) then
		return
	end
	local facts = factsOf[player]
	if facts ~= nil and facts.totalXp <= 0 then
		AnalyticsService.onboarding(player, "firstDrive")
	end
	local designUid = model:GetAttribute(DESIGN_ATTRIBUTE)
	local entry = if type(designUid) == "string" then built[designUid] else nil
	if entry ~= nil and entry.player == player then
		built[designUid :: string] = nil
		AnalyticsService.designerStep(player, "drive", entry.session)
	end
end

local function watchCar(model: Instance)
	local seats = model:FindFirstChild(SEATS_FOLDER)
	local driver = if seats ~= nil then seats:FindFirstChild(DRIVER_SEAT) else nil
	if driver ~= nil and driver:IsA("Seat") then
		local seat = driver :: Seat
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			onDriverSeated(model, seat)
		end)
	end
	model:GetAttributeChangedSignal(Abilities.attributes.ability):Connect(function()
		local ability = model:GetAttribute(Abilities.attributes.ability)
		local owner = ownerOf(model)
		if type(ability) == "string" and owner ~= nil then
			AnalyticsService.abilityUsed(owner, ability)
		end
	end)
	model:GetAttributeChangedSignal(LightShows.attributes.showId):Connect(function()
		local owner = ownerOf(model)
		if model:GetAttribute(LightShows.attributes.showId) ~= nil and owner ~= nil then
			AnalyticsService.lightShowJoined(owner)
		end
	end)
end

-- Revenue hooks: every product receipt granted, and passes bought this session (a pass first heard as owned was
-- bought before, so only a change from not owned to owned counts).
local function hookMonetization()
	local service = monetization
	if service == nil then
		warn(`{LOG} MonetizationService isn't there: purchases aren't logged`)
		return
	end
	if type(service.onGranted) == "function" then
		service.onGranted(function(player: Player, key: string, _purchaseId: string)
			if key == Ads.rewardedVideo.productKey then
				return -- an ad's reward, not a purchase (AdsService logs RewardedAd)
			end
			local info = Monetization.productInfo[key]
			AnalyticsService.purchase(player, key, if info ~= nil then info.kind else "cosmetic")
		end)
	end
	if type(service.onPassChanged) == "function" then
		for key in Monetization.passes do
			service.onPassChanged(key, function(player: Player, owned: boolean)
				local seen = passKnown[player]
				if seen == nil then
					seen = {}
					passKnown[player] = seen
				end
				local before = seen[key]
				seen[key] = owned
				if before == false and owned then
					AnalyticsService.purchase(player, key, "pass")
				end
			end)
		end
	end
end

-- Boot ---------------------------------------------------------------------------------------------------------

function AnalyticsService:Init()
	DataService = require(script.Parent.DataService)
	local module = script.Parent:FindFirstChild("MonetizationService")
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, result = pcall(require :: any, module)
		if ok and type(result) == "table" then
			monetization = result
		end
	end
end

function AnalyticsService:Start()
	local dataService = DataService
	if dataService ~= nil then
		dataService.onChanged(onSaveChanged)
	end
	for _, model in CollectionService:GetTagged(Spawning.vehicleTag) do
		watchCar(model)
	end
	CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(watchCar)
	hookMonetization()
	Players.PlayerRemoving:Connect(function(player: Player)
		factsOf[player] = nil
		onboarded[player] = nil
		passKnown[player] = nil
		for session, owner in table.clone(sessions) do
			if owner == player then
				sessions[session] = nil
			end
		end
		for designUid, entry in table.clone(built) do
			if entry.player == player then
				built[designUid] = nil
			end
		end
	end)
end

return AnalyticsService
