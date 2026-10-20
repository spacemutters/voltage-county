--!strict
-- Economy simulator (PLAN.md §4 deliverable; docs/phase-3-contracts.md "EconSim"). Plays three player profiles
-- (casual, mid, grinder), each with and without VIP, minute by minute through the money side of the game, and
-- reports how many hours of play each one takes to reach each §4 milestone, next to the §4 targets:
--   new Ohm Spark ≈ 0.5 h · crossover or pickup ≈ 1–2 h · semi ≈ 4–5 h · Arc ≈ 15–20 h · Arc Boost ≈ 40–50 h.
--
-- Each simulated minute the player does the best-paying thing they can (rates are Config/Economy.activities, the
-- §4 mid-skill $/min targets):
--   free driving       any car (a casual player also free-drives part of the time)
--   rideshare          a sedan; rideshare XL an suv (the free used Spark counts, so rideshare is open from the start)
--   delivery           any car, +Economy.activities.deliveryVehicleBonus in an Economy.deliveryBonusClasses class
--   towing             a pickup
--   freight            a heavy truck plus the freight license (Economy.freightLicensePrice)
-- VIP adds Economy.vipJobPayBonus to job pay (not to free driving). Each profile scales every rate by its skill
-- (`payFactor`). Driving costs a little charging (a small sink, see SETTINGS). As soon as the player can afford
-- the next milestone of Config/Economy.milestones they buy it, in order: new Spark -> pickup (the "crossover or
-- pickup" step; SETTINGS.choices) -> semi, with the freight license its jobs need -> Arc -> Arc Boost (an upgrade
-- of the Arc). Prices come from Vehicle/Catalog; starting cash, rates and targets from Config/Economy.
--
-- Deterministic and pure apart from printing: simulate() and runAll() only compute; run() also prints a table.
-- Run in Edit mode or a playtest via MCP execute_luau, Server or Edit datamodel:
--   require(game.ServerScriptService.Server.Dev.EconSim).run()
-- Paste its output into docs/PROGRESS.md whenever economy numbers change (PLAN.md §4). tests/EconSim.spec checks
-- that it runs, every profile reaches every milestone, better players are never slower, and VIP is never slower.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Catalog = require(Shared.Vehicle.Catalog)
local Economy = require(Shared.Config.Economy)

export type ProfileId = "casual" | "mid" | "grinder"
export type ActivityId = "freeDrive" | "rideshare" | "rideshareXL" | "delivery" | "towing" | "freight"

export type Profile = {
	id: ProfileId,
	label: string,
	payFactor: number, -- every $/min rate is multiplied by this (skill: route choice, fewer mistakes, less idling)
	freeDriveShare: number, -- 0..1: the share of minutes spent free driving instead of the best job
}

export type Purchase = { vehicleId: string, trim: string }

-- One milestone of Config/Economy.milestones, as the simulated player buys it.
export type Milestone = {
	id: string,
	label: string,
	buy: Purchase, -- which of the milestone's vehicles the player buys
	licenses: { string }, -- licenses bought with it (the jobs the vehicle opens need them)
	target: { min: number, max: number }, -- hours, PLAN.md §4 (Economy.milestones minHours / maxHours)
}

export type MilestoneResult = {
	id: string,
	label: string,
	hours: number?, -- hours of play when bought (nil: not reached within maxHours)
	cost: number,
	targetMin: number,
	targetMax: number,
}

export type Run = {
	profile: ProfileId,
	label: string,
	vip: boolean,
	milestones: { MilestoneResult },
	minutes: number, -- minutes simulated
	cash: number, -- cash left at the end
	earned: number, -- gross earned
	charging: number, -- spent on charging
	minutesBy: { [string]: number }, -- minutes spent on each activity
}

export type Report = { runs: { Run }, lines: { string } }

export type Options = {
	maxHours: number?, -- stop a run after this many hours of play (default SETTINGS.maxHours)
}

-- A dev tool, so its assumptions live here rather than in Shared/Config (like Dev/RouteTests' SETTINGS).
local SETTINGS = {
	maxHours = 200, -- give up on a run after this many hours of play
	-- The free car every new player claims at the used lot (PLAN.md Phase 4), owned from minute 0.
	starter = { vehicleId = "ohm_spark", trim = "used" } :: Purchase,
	-- Which vehicle to buy for a milestone that offers several (default: the first listed). For "crossover or
	-- pickup" the sim buys the pickup: it opens towing ($1,600/min), the road to the semi in §4, where the
	-- crossover only adds rideshare XL ($1,250/min).
	choices = {
		crossoverOrPickup = { vehicleId = "ohm_mesa", trim = "standard" },
	} :: { [string]: Purchase },
	-- Charging: $ for a full charge, by vehicle class (default for any other class). A car's catalog
	-- energyMinutes is how long a charge lasts, so the cost per minute of driving is this / energyMinutes:
	-- about $5 a minute in a car, $12 in the semi, under 2% of what the driving earns. Placeholders until Phase 5
	-- puts charging prices in Config.
	chargeCostPerCharge = { default = 120, heavy = 480 } :: { [string]: number },
}

local PROFILES: { Profile } = {
	{ id = "casual", label = "casual", payFactor = 0.75, freeDriveShare = 0.25 },
	{ id = "mid", label = "mid", payFactor = 1, freeDriveShare = 0 },
	{ id = "grinder", label = "grinder", payFactor = 1.15, freeDriveShare = 0 },
}

type ActivityRule = {
	id: ActivityId,
	job: boolean, -- VIP's job bonus applies
	classes: { string }?, -- vehicle classes that can do it (nil: any car)
	bonusClasses: { string }?, -- classes that earn Economy.activities.deliveryVehicleBonus on top
	license: string?, -- also needs this license
}

local ACTIVITIES: { ActivityRule } = {
	{ id = "freeDrive", job = false },
	{ id = "rideshare", job = true, classes = { "sedan" } },
	{ id = "rideshareXL", job = true, classes = { "suv" } },
	{ id = "delivery", job = true, bonusClasses = Economy.deliveryBonusClasses },
	{ id = "towing", job = true, classes = { "pickup" } },
	{ id = "freight", job = true, classes = { "heavy" }, license = "freight" },
}

-- The licenses the jobs a vehicle class opens need (bought together with the vehicle).
local function licensesFor(class: string): { string }
	local licenses: { string } = {}
	for _, rule in ACTIVITIES do
		local classes = rule.classes
		if rule.license ~= nil and classes ~= nil and table.find(classes, class) ~= nil then
			table.insert(licenses, rule.license)
		end
	end
	return licenses
end

-- Config/Economy.milestones (PLAN.md §4), in the order a player buys them, as purchases.
local MILESTONES: { Milestone } = {}
for _, milestone in Economy.milestones do
	local choice = SETTINGS.choices[milestone.id]
	local buy: Purchase = milestone.vehicles[1]
	if choice ~= nil then
		for _, option in milestone.vehicles do
			if option.vehicleId == choice.vehicleId and option.trim == choice.trim then
				buy = option
			end
		end
	end
	local vehicle = Catalog.getVehicle(buy.vehicleId)
	assert(vehicle ~= nil, `EconSim: milestone "{milestone.id}" names unknown vehicle "{buy.vehicleId}"`)
	table.insert(MILESTONES, {
		id = milestone.id,
		label = milestone.label,
		buy = { vehicleId = buy.vehicleId, trim = buy.trim },
		licenses = licensesFor(vehicle.class),
		target = { min = milestone.minHours, max = milestone.maxHours },
	})
end

local MINUTES_PER_HOUR = 60

type Owned = { vehicleId: string, trim: string, class: string, energyMinutes: number }
type Player = {
	cash: number,
	cars: { Owned },
	licenses: { [string]: boolean },
}

local EconSim = {}
EconSim.SETTINGS = SETTINGS
EconSim.PROFILES = PROFILES
EconSim.MILESTONES = MILESTONES

local function rateOf(activity: ActivityId): number
	local rates: { [string]: number } = Economy.activities :: any
	local rate = rates[activity]
	assert(type(rate) == "number", `EconSim: Config/Economy.activities.{activity} is missing`)
	return rate
end

local function licensePrice(license: string): number
	if license == "freight" then
		return Economy.freightLicensePrice
	end
	error(`EconSim: no price for the "{license}" license`)
end

local function ownedFrom(purchase: Purchase): Owned
	local vehicle = Catalog.getVehicle(purchase.vehicleId)
	local trim = Catalog.getTrim(purchase.vehicleId, purchase.trim)
	assert(vehicle ~= nil and trim ~= nil, `EconSim: {purchase.vehicleId}/{purchase.trim} is not in the catalog`)
	return {
		vehicleId = purchase.vehicleId,
		trim = purchase.trim,
		class = vehicle.class,
		energyMinutes = trim.energyMinutes or MINUTES_PER_HOUR,
	}
end

-- What a milestone costs a player: the car (an upgrade trim costs only its own price when the player owns the
-- trim it upgrades) plus the licenses that come with it, if they don't hold them yet.
function EconSim.costOf(
	milestone: Milestone,
	ownedTrims: { [string]: boolean }?,
	licenses: { [string]: boolean }?
): number
	local buy = milestone.buy
	local trim = Catalog.getTrim(buy.vehicleId, buy.trim)
	assert(trim ~= nil, `EconSim: {buy.vehicleId}/{buy.trim} is not in the catalog`)
	local price: number?
	if trim.upgradeFrom ~= nil and ownedTrims ~= nil and ownedTrims[`{buy.vehicleId}/{trim.upgradeFrom}`] then
		price = trim.price
	else
		price = Catalog.totalPrice(buy.vehicleId, buy.trim)
	end
	assert(price ~= nil, `EconSim: {buy.vehicleId}/{buy.trim} is not sold for cash`)
	for _, license in milestone.licenses do
		if not (licenses ~= nil and licenses[license]) then
			price += licensePrice(license)
		end
	end
	return price
end

local function canDo(rule: ActivityRule, car: Owned, player: Player): boolean
	if rule.license ~= nil and not player.licenses[rule.license] then
		return false
	end
	local classes = rule.classes
	return classes == nil or table.find(classes, car.class) ~= nil
end

-- $ per minute for doing `rule` in `car`, for this profile and VIP state.
local function payFor(rule: ActivityRule, car: Owned, profile: Profile, vip: boolean): number
	local rate = rateOf(rule.id)
	local bonusClasses = rule.bonusClasses
	if bonusClasses ~= nil and table.find(bonusClasses, car.class) ~= nil then
		rate *= 1 + Economy.activities.deliveryVehicleBonus
	end
	if rule.job and vip then
		rate *= 1 + Economy.vipJobPayBonus
	end
	return rate * profile.payFactor
end

local function chargingPerMinute(car: Owned): number
	local perCharge = SETTINGS.chargeCostPerCharge[car.class] or SETTINGS.chargeCostPerCharge.default
	return perCharge / math.max(car.energyMinutes, 1)
end

-- The best-paying thing the player can do this minute (net of charging), and in which car. With `freeOnly`,
-- the best car for free driving.
local function bestMinute(
	player: Player,
	profile: Profile,
	vip: boolean,
	freeOnly: boolean
): (ActivityId, number, number)
	local bestActivity: ActivityId = "freeDrive"
	local bestPay, bestCost, bestNet = 0, 0, -math.huge
	for _, rule in ACTIVITIES do
		if freeOnly and rule.id ~= "freeDrive" then
			continue
		end
		for _, car in player.cars do
			if canDo(rule, car, player) then
				local pay = payFor(rule, car, profile, vip)
				local cost = chargingPerMinute(car)
				if pay - cost > bestNet then
					bestActivity, bestPay, bestCost, bestNet = rule.id, pay, cost, pay - cost
				end
			end
		end
	end
	return bestActivity, bestPay, bestCost
end

local function profileById(id: ProfileId): Profile
	for _, profile in PROFILES do
		if profile.id == id then
			return profile
		end
	end
	error(`EconSim: unknown profile "{id}"`)
end

-- One profile, with or without VIP, minute by minute until every milestone is bought or maxHours pass.
function EconSim.simulate(profileId: ProfileId, vip: boolean, opts: Options?): Run
	local profile = profileById(profileId)
	local maxMinutes =
		math.floor((if opts and opts.maxHours then opts.maxHours else SETTINGS.maxHours) * MINUTES_PER_HOUR)
	local player: Player = { cash = Economy.startingCash, cars = { ownedFrom(SETTINGS.starter) }, licenses = {} }
	local ownedTrims: { [string]: boolean } = { [`{SETTINGS.starter.vehicleId}/{SETTINGS.starter.trim}`] = true }

	local results: { MilestoneResult } = {}
	for _, milestone in MILESTONES do
		table.insert(results, {
			id = milestone.id,
			label = milestone.label,
			hours = nil,
			cost = EconSim.costOf(milestone, nil, nil),
			targetMin = milestone.target.min,
			targetMax = milestone.target.max,
		})
	end

	local run: Run = {
		profile = profile.id,
		label = profile.label .. (if vip then "+VIP" else ""),
		vip = vip,
		milestones = results,
		minutes = 0,
		cash = player.cash,
		earned = 0,
		charging = 0,
		minutesBy = {},
	}

	local nextIndex = 1
	local freeDriveCredit = 0
	for minute = 1, maxMinutes do
		-- A casual player free-drives a steady share of their minutes (deterministic: every 1/share-th minute).
		freeDriveCredit += profile.freeDriveShare
		local freeOnly = freeDriveCredit >= 1
		if freeOnly then
			freeDriveCredit -= 1
		end
		local activity, pay, charging = bestMinute(player, profile, vip, freeOnly)
		player.cash += pay - charging
		run.earned += pay
		run.charging += charging
		run.minutesBy[activity] = (run.minutesBy[activity] or 0) + 1
		run.minutes = minute

		-- Buy every milestone the player can now afford, in order.
		while nextIndex <= #MILESTONES do
			local milestone = MILESTONES[nextIndex]
			local cost = EconSim.costOf(milestone, ownedTrims, player.licenses)
			if player.cash < cost then
				break
			end
			player.cash -= cost
			local bought = ownedFrom(milestone.buy)
			local boughtTrim = Catalog.getTrim(milestone.buy.vehicleId, milestone.buy.trim)
			local from = if boughtTrim then boughtTrim.upgradeFrom else nil
			if from ~= nil then
				-- An upgrade replaces the trim it upgrades.
				for index, car in player.cars do
					if car.vehicleId == milestone.buy.vehicleId and car.trim == from then
						table.remove(player.cars, index)
						break
					end
				end
			end
			table.insert(player.cars, bought)
			ownedTrims[`{milestone.buy.vehicleId}/{milestone.buy.trim}`] = true
			for _, license in milestone.licenses do
				player.licenses[license] = true
			end
			results[nextIndex].hours = minute / MINUTES_PER_HOUR
			results[nextIndex].cost = cost
			nextIndex += 1
		end
		if nextIndex > #MILESTONES then
			break
		end
	end
	run.cash = player.cash
	return run
end

-- Every profile, without and with VIP, in PROFILES order.
function EconSim.runAll(opts: Options?): { Run }
	local runs: { Run } = {}
	for _, profile in PROFILES do
		table.insert(runs, EconSim.simulate(profile.id, false, opts))
		table.insert(runs, EconSim.simulate(profile.id, true, opts))
	end
	return runs
end

local function hoursText(hours: number?): string
	return if hours == nil then "never" else string.format("%.2f", hours)
end

local function targetText(min: number, max: number): string
	if min == max then
		return string.format("~%g", min)
	end
	return string.format("%g-%g", min, max)
end

local function pad(text: string, width: number): string
	return text .. string.rep(" ", math.max(width - #text, 0))
end

-- Where `hours` sits against a target: "on target", "fast" (sooner) or "slow" (later). A single-value target
-- (≈ 0.5 h) counts as on target within 25%.
function EconSim.verdict(hours: number?, min: number, max: number): string
	local ON_TARGET_SLACK = 0.25
	if hours == nil then
		return "never"
	end
	local low, high = min, max
	if min == max then
		low, high = min * (1 - ON_TARGET_SLACK), max * (1 + ON_TARGET_SLACK)
	end
	if hours < low then
		return "fast"
	elseif hours > high then
		return "slow"
	end
	return "on target"
end

-- The table of hours per milestone (rows) and run (columns), with the §4 target.
function EconSim.format(runs: { Run }): { string }
	local LABEL_WIDTH, COLUMN_WIDTH = 22, 13
	local lines: { string } = { "[EconSim] hours of play to each milestone (PLAN.md §4 target in hours)" }
	local header = pad("milestone", LABEL_WIDTH) .. pad("target", COLUMN_WIDTH)
	for _, run in runs do
		header ..= pad(run.label, COLUMN_WIDTH)
	end
	table.insert(lines, header)
	for index, milestone in MILESTONES do
		local row = pad(milestone.label, LABEL_WIDTH)
			.. pad(targetText(milestone.target.min, milestone.target.max), COLUMN_WIDTH)
		for _, run in runs do
			row ..= pad(hoursText(run.milestones[index].hours), COLUMN_WIDTH)
		end
		table.insert(lines, row)
	end
	return lines
end

-- The mid profile (no VIP) next to the §4 targets, one line per milestone.
function EconSim.midComparison(runs: { Run }): { string }
	local lines: { string } = {}
	for _, run in runs do
		if run.profile == "mid" and not run.vip then
			for _, result in run.milestones do
				table.insert(
					lines,
					string.format(
						"[EconSim] mid: %s at %s h, target %s h -> %s",
						result.label,
						hoursText(result.hours),
						targetText(result.targetMin, result.targetMax),
						EconSim.verdict(result.hours, result.targetMin, result.targetMax)
					)
				)
			end
		end
	end
	return lines
end

-- Simulates every profile, prints the table and the mid comparison, and returns both.
function EconSim.run(opts: Options?): Report
	if not RunService:IsStudio() then
		warn("[EconSim] runs only in Studio")
		return { runs = {}, lines = {} }
	end
	local runs = EconSim.runAll(opts)
	local lines = EconSim.format(runs)
	for _, line in EconSim.midComparison(runs) do
		table.insert(lines, line)
	end
	for _, line in lines do
		print(line)
	end
	return { runs = runs, lines = lines }
end

return EconSim
