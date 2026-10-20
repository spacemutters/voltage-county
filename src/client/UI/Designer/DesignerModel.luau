--!strict
-- The AI Car Designer's screen logic, with no UI and no network (docs/phase-11-contracts.md "Client"), so
-- tests/DesignerUi.spec can check it in Edit mode:
--
--   charCount(), clampPrompt(), counterText()  the prompt box: characters (not bytes), cut at the kit's limit
--   cleanPrompt(), promptProblem()             what is sent, and why Design is refused before it is sent
--   prices(), creditsText(), costOf()          what a new car or a mod costs this player (the free first car),
--   costLabel(), costSentence(), canAfford()   in plain words, whether their balance covers it, and whether a
--   rerollFree()                               design still has its free re-roll
--   disclosureNeeded(), unlocked()             the AI notice gate and the phone app's unlock
--   classOptions()                             the class picker: designable kit classes by tier, exotic only
--                                              for owners of an exotic, then "Surprise me"
--   disclosureText(), reportReasons()          Config/Designer's words when it has them, else DesignerStyle's
--   readResult(), designCard(), statRows()     a DesignResult payload, the result card's name, tagline, spec
--   modTitle()                                 line and stat bars, and the mod result's title
--   carName(), isCustom(), modKind(),          how the Garage and the mod sheet name a car, which builder rules
--   reportable()                               apply to it, and whether it gets a Report entry
--
-- Config/Designer (the designer's server settings) is read defensively through config(): a missing module or field
-- falls back to DesignerStyle. The server decides every charge and every outcome; these only keep the
-- buttons honest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Types = require(ReplicatedStorage.Shared.Types)
local ProfileController = require(script.Parent.Parent.Parent.Controllers.ProfileController)
local ShopModel = require(script.Parent.Parent.Shop.ShopModel)
local ShopStyle = require(script.Parent.Parent.Shop.Style)
local DesignerStyle = require(script.Parent.DesignerStyle)

local KPH_PER_MPH = 1.609344 -- a unit conversion, not a tunable
local HANDLING_SCALE = 10 -- handling (0..1) is shown out of 10, like the dealership
local SURPRISE_ID = "surprise" -- the class picker's "Surprise me" chip (sends no classId)

local copy = DesignerStyle.copy

export type Kind = "design" | "mod"
export type ModKind = "kit" | "catalog"

-- Credits for a new car and a mod, and the free re-rolls that come with a paid design and with the free one.
export type Prices = { newCar: number, mod: number, rerollsPaid: number, rerollsFree: number }

-- The player's designer data: credits, the free car, designs and mods (ProfileController.normalizeDesigner).
export type DesignerData = ProfileController.Designer

-- A car as the Garage lists it (the profile snapshot's copy of an owned car).
export type Car = Types.SnapshotVehicle

export type Option = { id: string, label: string }

-- A DesignResult (or a reply carrying a design) after checking.
export type Result = {
	requestId: string,
	ok: boolean,
	message: string,
	spec: { [string]: any }?, -- the validated design or mod spec (the server's; checked again for display)
	preview: any, -- what the server sent to show (a Model, or { before, after }), if anything
	rerollFree: boolean?, -- the server says whether the next re-roll is free
	stats: { [string]: any }?, -- the design's stats as the server worked them out (SpecBuilder.stats)
	uid: string?, -- the owned car the result belongs to (mods; a built design)
}

-- The result card's words.
export type Card = {
	name: string,
	tagline: string?,
	specLine: string, -- "Sports · Electric"
	classId: string?,
}

local DesignerModel = {}

DesignerModel.surpriseId = SURPRISE_ID

-- The design kit (Config/DesignKit.json, kitVersion 1): limits, classes, templates, parts.
DesignerModel.kit = require(ReplicatedStorage.Shared.Config.DesignKit) :: any

-- Config/Designer ----------------------------------------------------------------------------------------------

local cachedConfig: any = nil
local configLoaded = false

-- Config/Designer when it is there (a table), else nil. Required once.
function DesignerModel.config(): any
	if configLoaded then
		return cachedConfig
	end
	configLoaded = true
	local module = ReplicatedStorage.Shared.Config:FindFirstChild("Designer")
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, result = pcall(require :: any, module)
		if ok and type(result) == "table" then
			cachedConfig = result
		end
	end
	return cachedConfig
end

local function positiveWhole(value: any): number?
	if type(value) == "number" and value == value and value >= 0 and value ~= math.huge then
		return math.floor(value)
	end
	return nil
end

-- The first field of `config` along any of `paths` ({ "prices", "newCar" } means config.prices.newCar).
local function lookup(config: any, paths: { { string } }): any
	if type(config) ~= "table" then
		return nil
	end
	for _, path in paths do
		local node: any = config
		for _, key in path do
			node = if type(node) == "table" then node[key] else nil
		end
		if node ~= nil then
			return node
		end
	end
	return nil
end

-- What a new car and a mod cost (Config/Designer's prices, else DesignerStyle.fallbackPrices). `config` defaults
-- to config(); specs pass a fixture.
function DesignerModel.prices(config: any?): Prices
	local source = if config ~= nil then config else DesignerModel.config()
	local fallback = DesignerStyle.fallbackPrices
	local newCar = positiveWhole(lookup(source, {
		{ "prices", "newCar" },
		{ "prices", "design" },
		{ "newCarCredits" },
		{ "designCost" },
	}))
	local mod = positiveWhole(lookup(source, { { "prices", "mod" }, { "modCredits" }, { "modCost" } }))
	local rerollsPaid = positiveWhole(lookup(source, { { "prices", "rerollsPaid" } }))
	local rerollsFree = positiveWhole(lookup(source, { { "prices", "rerollsFree" } }))
	return {
		newCar = newCar or fallback.newCar,
		mod = mod or fallback.mod,
		rerollsPaid = rerollsPaid or fallback.rerollsPaid,
		rerollsFree = rerollsFree or fallback.rerollsFree,
	}
end

-- The AI notice's body: Config/Designer's text when it has one, else DesignerStyle's.
function DesignerModel.disclosureText(config: any?): string
	local source = if config ~= nil then config else DesignerModel.config()
	local text = lookup(source, {
		{ "disclosure" },
		{ "disclosureText" },
		{ "aiDisclosure" },
		{ "messages", "disclosure" },
	})
	return if type(text) == "string" and text ~= "" then text else copy.disclosureBody
end

-- The report reasons ({ id, label }, in order): Config/Designer's (a list of { id, label }, a list of ids, or a map
-- id -> label sorted by id), else DesignerStyle's. Ids longer than the Net limit are left out.
function DesignerModel.reportReasons(config: any?): { Option }
	local source = if config ~= nil then config else DesignerModel.config()
	local raw = lookup(source, { { "reportReasons" }, { "report", "reasons" }, { "moderation", "reasons" } })
	local reasons: { Option } = {}
	local limit = DesignerStyle.reportReasonMaxLength
	local function add(id: any, label: any)
		if type(id) == "string" and id ~= "" and #id <= limit then
			table.insert(reasons, { id = id, label = if type(label) == "string" and label ~= "" then label else id })
		end
	end
	if type(raw) == "table" then
		if #raw > 0 then
			for _, entry in raw do
				if type(entry) == "table" then
					add(entry.id, entry.label or entry.text)
				else
					add(entry, entry)
				end
			end
		else
			local ids: { string } = {}
			for id in raw do
				if type(id) == "string" then
					table.insert(ids, id)
				end
			end
			table.sort(ids)
			for _, id in ids do
				add(id, raw[id])
			end
		end
	end
	if #reasons == 0 then
		for _, reason in copy.reportReasons do
			table.insert(reasons, { id = reason.id, label = reason.label })
		end
	end
	return reasons
end

-- The prompt --------------------------------------------------------------------------------------------------

-- Characters in `text` (UTF-8 code points; bytes when the text isn't valid UTF-8).
function DesignerModel.charCount(text: string): number
	return utf8.len(text) or #text
end

-- The most characters a prompt may have for a new car or a mod (Config/DesignKit limits).
function DesignerModel.promptLimit(kind: Kind): number
	local limits = DesignerModel.kit.limits
	return if kind == "mod" then limits.modPromptChars else limits.promptChars
end

-- `text` as the box may hold it: control characters (newlines, tabs) become spaces, and anything past `limit`
-- characters is cut on a character boundary.
function DesignerModel.clampPrompt(text: string, limit: number): string
	local clean = string.gsub(text, "%c", " ")
	local count = utf8.len(clean)
	if count == nil then
		return string.sub(clean, 1, limit) -- not valid UTF-8: the server would refuse it anyway
	end
	if count <= limit then
		return clean
	end
	local cut = utf8.offset(clean, limit + 1)
	return if cut ~= nil then string.sub(clean, 1, cut - 1) else clean
end

-- "12/200": characters used and the limit.
function DesignerModel.counterText(text: string, limit: number): string
	return string.format(copy.counter, DesignerModel.charCount(text), limit)
end

-- What is sent: trimmed, with runs of spaces made one.
function DesignerModel.cleanPrompt(text: string): string
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	return (string.gsub(trimmed, "%s+", " "))
end

-- Why the prompt can't be sent yet (empty, or shorter than the kit's minimum), or nil when it can.
function DesignerModel.promptProblem(text: string, kind: Kind): string?
	local clean = DesignerModel.cleanPrompt(text)
	if clean == "" then
		return if kind == "mod" then copy.emptyModPrompt else copy.emptyPrompt
	end
	local letters = string.gsub(clean, "%s", "")
	if DesignerModel.charCount(letters) < DesignerModel.kit.limits.minFilteredChars then
		return copy.shortPrompt
	end
	return nil
end

-- Cost ---------------------------------------------------------------------------------------------------------

-- "1 credit", "2 credits".
function DesignerModel.creditsText(amount: number): string
	return if amount == 1 then copy.oneCredit else string.format(copy.credits, amount)
end

-- Credits this request takes from the player: a new car is free while the free first car is unused.
function DesignerModel.costOf(kind: Kind, credits: DesignerData?, prices: Prices): number
	if kind == "mod" then
		return prices.mod
	end
	if credits ~= nil and not credits.freeDesignUsed then
		return 0
	end
	return prices.newCar
end

-- True while a design still has a free re-roll: `used` of the ones that come with it (a paid design comes with
-- prices.rerollsPaid, the free first car with prices.rerollsFree). After that a re-roll is a new paid design.
-- The server's DesignResult says (rerollFree); this is only for when it doesn't.
function DesignerModel.rerollFree(paid: boolean, used: number, prices: Prices): boolean
	return used < (if paid then prices.rerollsPaid else prices.rerollsFree)
end

-- "Free" or "2 credits", for the price block.
function DesignerModel.costLabel(kind: Kind, credits: DesignerData?, prices: Prices): string
	local cost = DesignerModel.costOf(kind, credits, prices)
	return if cost == 0 then copy.free else DesignerModel.creditsText(cost)
end

-- "Your first car is free." or "This uses 2 credits."
function DesignerModel.costSentence(kind: Kind, credits: DesignerData?, prices: Prices): string
	local cost = DesignerModel.costOf(kind, credits, prices)
	if cost == 0 then
		return copy.firstFree
	end
	return if cost == 1 then copy.usesOne else string.format(copy.uses, cost)
end

-- How many more credits the player needs (0 when they can pay, or don't need to). Unknown credits (the profile
-- hasn't arrived) need nothing: the server checks anyway.
function DesignerModel.shortBy(kind: Kind, credits: DesignerData?, prices: Prices): number
	if credits == nil then
		return 0
	end
	return math.max(DesignerModel.costOf(kind, credits, prices) - credits.balance, 0)
end

function DesignerModel.canAfford(kind: Kind, credits: DesignerData?, prices: Prices): boolean
	return DesignerModel.shortBy(kind, credits, prices) == 0
end

-- The price block's status line: the free car, the balance, or how many more credits are needed (with its tone).
function DesignerModel.balanceLine(kind: Kind, credits: DesignerData?, prices: Prices): (string, "dim" | "warning")
	if credits == nil then
		return copy.checking, "dim"
	end
	local short = DesignerModel.shortBy(kind, credits, prices)
	if short > 0 then
		return string.format(copy.needMore, DesignerModel.creditsText(short)), "warning"
	end
	if DesignerModel.costOf(kind, credits, prices) == 0 then
		return copy.firstFree, "dim"
	end
	return string.format(copy.balance, DesignerModel.creditsText(credits.balance)), "dim"
end

-- Gates --------------------------------------------------------------------------------------------------------

-- True when the player has used the designer before (a design, a mod, or the free car used): they were shown the
-- AI notice then, and the phone's Designer app stays unlocked.
function DesignerModel.hasUsed(designer: DesignerData?): boolean
	if designer == nil then
		return false
	end
	return designer.freeDesignUsed or designer.designCount > 0 or next(designer.mods) ~= nil
end

-- True when the AI notice must be shown (and acknowledged) before the next request: never acknowledged this
-- session (or by the server's attribute), and no sign in the profile of an earlier request.
function DesignerModel.disclosureNeeded(acknowledged: boolean, designer: DesignerData?): boolean
	return not acknowledged and not DesignerModel.hasUsed(designer)
end

-- True when the phone's Designer app shows: the player visited the studio (the attribute) or used the designer.
function DesignerModel.unlocked(visited: boolean, designer: DesignerData?): boolean
	return visited or DesignerModel.hasUsed(designer)
end

-- Classes ------------------------------------------------------------------------------------------------------

-- The classes of the catalog cars the player owns (for the kit's requiresOwnedClass rule).
function DesignerModel.ownedClasses(cars: { Car }?): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	local list: { Car } = cars or {}
	for _, car in list do
		local entry = if car.vehicleId ~= Garage.customVehicleId then Catalog.getVehicle(car.vehicleId) else nil
		if entry ~= nil then
			owned[entry.class] = true
		end
	end
	return owned
end

-- The class picker's choices: every kit class that Config/Classes marks designable, cheapest tier first (then by
-- name), leaving out classes that need an owned class the player doesn't have; "Surprise me" last.
function DesignerModel.classOptions(owned: { [string]: boolean }): { Option }
	local ids: { string } = {}
	for id, rule in DesignerModel.kit.classes :: { [string]: any } do
		local class = Classes[id]
		local needs = rule.requiresOwnedClass
		if class ~= nil and class.designable and (type(needs) ~= "string" or owned[needs] == true) then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a: string, b: string): boolean
		local classA, classB = Classes[a], Classes[b]
		if classA.tier ~= classB.tier then
			return classA.tier < classB.tier
		end
		return classA.displayName < classB.displayName
	end)
	local options: { Option } = {}
	for _, id in ids do
		table.insert(options, { id = id, label = Classes[id].displayName })
	end
	table.insert(options, { id = SURPRISE_ID, label = copy.surprise })
	return options
end

-- The classId DesignCar sends for a picked chip (nil: "Surprise me").
function DesignerModel.classIdFor(choice: string?): string?
	if choice == nil or choice == SURPRISE_ID then
		return nil
	end
	return choice
end

-- Results ------------------------------------------------------------------------------------------------------

-- `value` as a display string: a string cut to `limit` characters, else nil.
local function shortText(value: any, limit: number): string?
	if type(value) ~= "string" then
		return nil
	end
	local clean = DesignerModel.cleanPrompt(value)
	if clean == "" then
		return nil
	end
	return DesignerModel.clampPrompt(clean, limit)
end

-- A checked DesignResult payload (or a DesignCar / ModCar reply that carries a design), or nil when it isn't one.
function DesignerModel.readResult(payload: any): Result?
	if type(payload) ~= "table" or type(payload.requestId) ~= "string" or payload.requestId == "" then
		return nil
	end
	local ok = payload.ok == true
	local spec = if type(payload.design) == "table" then payload.design else nil
	if ok and spec == nil then
		ok = false -- a success with nothing to show is treated as a failure (the server refunds on its side)
	end
	return {
		requestId = payload.requestId,
		ok = ok,
		message = if type(payload.message) == "string" then payload.message else "",
		spec = spec,
		preview = payload.preview,
		rerollFree = if type(payload.rerollFree) == "boolean" then payload.rerollFree else nil,
		stats = if type(payload.stats) == "table" then payload.stats else nil,
		uid = if type(payload.uid) == "string" then payload.uid else nil,
	}
end

-- The result card's words from a design spec: its name and tagline (filtered by the server, cut to the kit's
-- lengths here), and "Class · Electric".
function DesignerModel.designCard(spec: { [string]: any }): Card
	local limits = DesignerModel.kit.limits
	local classId = if type(spec.class) == "string" then spec.class else nil
	local class = if classId ~= nil then Classes[classId] else nil
	local parts: { string } = {}
	if class ~= nil then
		table.insert(parts, class.displayName)
	end
	local energy = if type(spec.energy) == "string" then copy.energy[spec.energy] else nil
	if energy ~= nil then
		table.insert(parts, energy)
	end
	return {
		name = shortText(spec.name, limits.name) or copy.yourDesign,
		tagline = shortText(spec.tagline, limits.tagline),
		specLine = table.concat(parts, copy.separator),
		classId = if class ~= nil then classId else nil,
	}
end

-- The mod result's title: the mod's summary (filtered by the server), or a plain "Your mod is on".
function DesignerModel.modTitle(spec: { [string]: any }?): string
	local summary = if spec ~= nil then shortText(spec.summary, DesignerModel.kit.limits.summary) else nil
	return summary or copy.modDoneTitle
end

-- The stat bars for a design's stats (SpecBuilder.stats: topSpeedMph, zeroToSixtySec, handling, energyMinutes,
-- seats), in the player's speed units, scaled like the dealership's bars (the whole catalog's range).
function DesignerModel.statRows(stats: { [string]: any }?, units: string?): { ShopModel.StatRow }
	if type(stats) ~= "table" then
		return {}
	end
	local ranges = ShopModel.ranges()
	local labels, formats = ShopStyle.copy.stats, ShopStyle.copy.units
	local rows: { ShopModel.StatRow } = {}
	local function number(value: any): number?
		return if type(value) == "number" and value == value then value else nil
	end
	local top = number(stats.topSpeedMph)
	if top ~= nil then
		table.insert(rows, {
			id = "topSpeed",
			label = labels.topSpeed,
			value = if units == "kph"
				then string.format(formats.kph, math.round(top * KPH_PER_MPH))
				else string.format(formats.mph, math.round(top)),
			fraction = ShopModel.fraction(top, ranges.topSpeedMph),
		})
	end
	local sprint = number(stats.zeroToSixtySec)
	if sprint ~= nil then
		table.insert(rows, {
			id = "zeroToSixty",
			label = labels.zeroToSixty,
			value = string.format(formats.seconds, sprint),
			fraction = ShopModel.fraction(sprint, ranges.zeroToSixtySec, true),
		})
	end
	local energy = number(stats.energyMinutes)
	if energy ~= nil then
		table.insert(rows, {
			id = "range",
			label = labels.range,
			value = string.format(formats.minutes, math.round(energy)),
			fraction = ShopModel.fraction(energy, ranges.energyMinutes),
		})
	end
	local handling = number(stats.handling)
	if handling ~= nil then
		table.insert(rows, {
			id = "handling",
			label = labels.handling,
			value = string.format(formats.handling, handling * HANDLING_SCALE),
			fraction = ShopModel.fraction(handling, ranges.handling),
		})
	end
	local seats = number(stats.seats)
	if seats ~= nil then
		table.insert(rows, {
			id = "seats",
			label = labels.seats,
			value = string.format(formats.seats, seats),
			fraction = ShopModel.fraction(seats, ranges.seats),
		})
	end
	return rows
end

-- Cars ---------------------------------------------------------------------------------------------------------

function DesignerModel.isCustom(car: Car): boolean
	return car.vehicleId == Garage.customVehicleId
end

-- Which ModBuilder rules apply: designed (kit) cars can change parts and proportions; catalog cars paint, wheels,
-- stance and extras only.
function DesignerModel.modKind(car: Car): ModKind
	return if DesignerModel.isCustom(car) then "kit" else "catalog"
end

-- The design behind a custom car, if the snapshot has it.
function DesignerModel.designOf(car: Car, designer: DesignerData?): ProfileController.DesignInfo?
	if designer == nil or not DesignerModel.isCustom(car) then
		return nil
	end
	local designUid = designer.vehicleDesigns[car.uid]
	return if designUid ~= nil then designer.designs[designUid] else nil
end

-- How a car is named to the player: a design by its (filtered) name, "Your design" when there is none to show,
-- a catalog car by its catalog name.
function DesignerModel.carName(car: Car, designer: DesignerData?): string
	if DesignerModel.isCustom(car) then
		local design = DesignerModel.designOf(car, designer)
		return if design ~= nil and design.name ~= nil then design.name else copy.yourDesign
	end
	local entry = Catalog.getVehicle(car.vehicleId)
	return if entry ~= nil then entry.displayName else copy.yourCar
end

-- True when a car gets a Report entry: a player design, or any car carrying an AI mod.
function DesignerModel.reportable(car: Car, designer: DesignerData?): boolean
	if DesignerModel.isCustom(car) then
		return true
	end
	return designer ~= nil and designer.mods[car.uid] ~= nil
end

return DesignerModel
