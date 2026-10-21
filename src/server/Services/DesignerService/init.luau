--!strict
-- The AI Car Designer and AI mods on the server (PLAN.md Phase 11; docs/phase-11-contracts.md "Server"). Read by
-- the server boot (Util/Loader) and the specs (tests/Credits.spec runs the request pipelines with fakes).
--
-- Remotes (declared in Net, which has already checked each payload's shape and rate-limited it). Functions answer
-- { ok, message, code?, requestId?, ... } at once; the slow part answers later as a DesignResult event.
--   DesignCar { prompt, classId? }   a new car (classId nil = "surprise me"). Answers { ok, message, requestId,
--                                    cost, free } or a refusal with `code` ("loading", "off", "busy", "pending",
--                                    "empty", "tooLong", "badText", "unknownClass", "classLocked", "slots",
--                                    "closed", "credits"; out of credits also sets outOfCredits = true).
--   ModCar { uid, prompt }           an AI mod on a car the player owns. Same answers (no class, no slots).
--   DesignResult (to the client)     { requestId, ok, message, kind = "design" | "mod", code?, ... }:
--                                    designs add design (the spec without its generation prompt), stats
--                                    (SpecBuilder.stats), designUid, rerollFree, rerollsLeft, free, cost and
--                                    preview = { spec, stats } for the client to build with Vehicle/SpecBuilder;
--                                    mods add uid (the car), design (the car's mods after this one, its summary on
--                                    top) and preview = { before, after } (mod specs; before is nil for a first mod).
--   DesignChoice { requestId, choice }   for the design waiting: "build" saves it (answers { ok, message, uid,
--                                    designUid }: uid is the new car, for SpawnOwned), "reroll" asks again (free
--                                    while rerollsLeft > 0, else a new paid design; answers { ok, message,
--                                    requestId } and a DesignResult follows), "discard" lets it go.
--   ReportDesign { uid, reason }     reports a custom or modded car: a car out in the world (its OwnedUid or
--                                    DesignUid), one of the player's own cars, or their design still waiting (its
--                                    requestId). Logged; once per car per player, Config/Designer.report limits.
--   HideDesign { designUid }         admins only (Config/Admins; anyone in Studio when studioCountsAsAdmin): hides
--                                    a design (its car falls back to the plain kit look) or a car's mod (stock
--                                    look), on every server (DataStore Config/Designer.hiddenStore, checked on join).
--                                    The same path is exported as DesignerService.hide (AdminService uses it).
--
-- A request, step by step (PLAN.md Phase 11 "DesignerService"):
--   1. checks: data loaded, the feature flag, one request at a time, the prompt (characters, not bytes), the class
--      tier rules (exotic needs an owned exotic; only kit classes), a free custom slot, the backend reachable.
--   2. reserves the price (CreditsService: the free first car, else Config/Designer.prices), then filters the
--      prompt with TextService (broadcast context) and refuses it when fewer than kit.limits.minFilteredChars
--      characters survive.
--   3. sends the backend only the filtered text, the class (or, for a mod, the car's class and current spec or
--      look), the salted player hash (Util/Sha256 of a salt kept in a DataStore and the UserId) and the kit
--      version, with the shared secret in the x-api-key header (HttpService:GetSecret). Waits at most
--      Config/Designer.requestTimeoutSeconds, sending again once if the request never reached the backend.
--   4. re-validates the reply against the kit (Validate; the backend isn't trusted either) and forces the class
--      the player asked for (or a surprise class they may design). A mod loses the extras the car can't carry
--      (Config/Customization classes and body styles; the backend is told which fit, as current.extrasThatFit) or
--      has no room for (the part budget: VehicleService.extrasAfterMods builds the car to see) before anything is
--      paid, so a mod left with nothing to change is refunded as empty.
--   5. checks the name, tagline, mod summary, refusal and mesh prompt for real brand names (Util/BrandNames; the
--      backend checks too, but it isn't trusted) and filters the shown text with TextService; text that names a
--      brand or that the filter changes is replaced by a plain one ("Custom <class>", no tagline, "Mod applied",
--      the plain refusal, no generated look), so nothing filtered is ever shown. Saved text is checked the same
--      way again on every join, before the designs are published.
--   6. stats come only from SpecBuilder.stats (class band x personality) and must sit inside the class band.
--   7. new cars wait for the player's choice; build saves the spec to `designs` and adds an OwnedVehicle
--      { vehicleId = "custom", designUid, trim "design" } in the same update that spends the reservation. Mods
--      save the car's merged mod spec to its `mods` in the same update that spends theirs, and the car, if out,
--      comes back wearing it.
--   Credits: spent when a result comes back (whether it is then built or discarded), refunded on a refusal, a
--   moderation failure, an error, a timeout or an unusable reply. A player who leaves with a design waiting gets
--   it built for them; anything still in flight is refunded (and CreditsService refunds whatever a crashed server
--   left reserved, on the next join).
--
-- The generated look: after a new design comes back, Vehicle/GeneratedAdapter asks GenerationService for a body in
-- the background (Config/Designer.generation). If it arrives within the time budget and the design is built, the
-- car wears it for the rest of this server session (VehicleService.setGeneratedLook), and a parked car out in the
-- world swaps to it; the saved car always rebuilds from its kit spec. Any failure just keeps the kit look.
--
-- The dev backend: in Studio with Config/Designer.devFakeBackend on, requests never leave the place: a local fake
-- answers with a valid fixed spec per class (prompts starting "test:refuse", "test:error" or "test:timeout" fail
-- that way, for the refund paths). Live servers always call the real backend; with no backendUrl or no secret,
-- every request answers "The design studio is opening soon" and nothing is charged.
--
-- The request pipelines (designPipeline, modPipeline) take their outside world as Deps (the filter, the hash,
-- the backend, the stats), so tests/Credits.spec can drive success, refusal, error and timeout without Roblox
-- services. No polling: everything runs on remote calls, task threads and one timer per backend call.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Admins = require(Shared.Config.Admins)
local BrandNames = require(Shared.Util.BrandNames)
local Catalog = require(Shared.Vehicle.Catalog)
local Classes = require(Shared.Config.Classes)
local DesignKit = require(Shared.Config.DesignKit)
local Designer = require(Shared.Config.Designer)
local FeatureFlags = require(Shared.Config.FeatureFlags)
local Garage = require(Shared.Config.Garage)
local GeneratedAdapter = require(Shared.Vehicle.GeneratedAdapter)
local Net = require(Shared.Net)
local Sha256 = require(Shared.Util.Sha256)
local Spawning = require(Shared.Config.Spawning)
local SpecBuilder = require(Shared.Vehicle.SpecBuilder)
local Types = require(Shared.Types)
local CreditsService = require(script.Parent.CreditsService)
local Template = require(script.Parent.DataService.Template)
local Validate = require(script.Validate)

-- Required in Init rather than here: DataService loads ProfileStore, which talks to DataStores straight away, and
-- tests/Credits.spec requires this module in Edit mode for its pipelines.
type DataServiceModule = typeof(require(script.Parent.DataService))
type VehicleServiceModule = typeof(require(script.Parent.VehicleService))
type GarageServiceModule = typeof(require(script.Parent.GarageService))

-- How a request ended. "ok" holds the reservation; everything else refunds it.
export type Status =
	"ok" -- a usable result
	| "refused" -- the designer said no (a friendly refusal)
	| "limited" -- the backend's limits, spend cap or off switch
	| "error" -- the backend failed, or nothing usable came back from it
	| "timeout" -- no answer in Config/Designer.requestTimeoutSeconds
	| "closed" -- no backend set up yet (no backendUrl or no secret)
	| "moderated" -- the text filter couldn't be reached
	| "filtered" -- too little of the prompt survived the text filter
	| "invalid" -- the reply failed validation, or its stats left the class band
	| "empty" -- a mod that changes nothing

-- What the backend (or the dev fake) answered.
export type Reply = { status: Status, spec: any?, refusal: string?, cached: boolean? }

-- The outside world of a request pipeline.
export type Deps = {
	kit: any,
	filter: (text: string) -> string?, -- TextService (broadcast) version of the text; nil when the filter failed
	userHash: () -> string?, -- the salted player hash; nil when the salt can't be had
	call: (path: string, body: { [string]: any }) -> Reply,
	stats: (spec: Validate.Spec, kit: any) -> any, -- SpecBuilder.stats
	canDesign: (classId: string) -> boolean, -- the player may design this class
	pickClass: () -> string, -- a surprise class the player may design
	log: (message: string) -> (),
}

export type DesignInput = {
	prompt: string, -- as typed (cleaned), or already filtered when `filtered` is true (a re-roll)
	classId: string?, -- nil = surprise me
	filtered: boolean?,
	reroll: boolean?,
}

export type DesignOutcome = {
	status: Status,
	message: string,
	prompt: string?, -- the filtered prompt, once it has been filtered (kept for re-rolls)
	spec: Validate.Spec?,
	stats: any?,
}

export type ModInput = {
	prompt: string,
	kind: Validate.Kind,
	classId: string,
	bodyStyle: string?, -- the car's Config/Vehicles body style (nil: extras are checked by class alone)
	current: { [string]: any }, -- the car's current spec or look, for the backend
}

export type ModOutcome = { status: Status, message: string, mod: Validate.ModSpec? }

-- What the function remotes answer (extra fields per remote; see the header).
export type Answer = { [string]: any }

-- A new design between DesignCar and the player's choice.
type Pending = {
	requestId: string,
	reservationId: string, -- what this design is paid with
	nextReservation: string?, -- a paid re-roll's reservation while it runs
	free: boolean,
	cost: number,
	classId: string?,
	prompt: string,
	filtered: boolean,
	busy: boolean, -- a backend call is running
	rerollsLeft: number, -- free re-rolls left
	spec: Validate.Spec?,
	stats: any?,
	designUid: string?, -- the latest result's design uid
}

-- A mod between ModCar and its result.
type ModJob = { requestId: string, reservationId: string, uid: string }

-- A design's generated look while GenerationService works on it.
type Generation = { owner: Player, look: Model?, built: boolean, dropped: boolean }

type ReportEntry = {
	at: number,
	reporter: number,
	owner: number?,
	designUid: string?,
	vehicleUid: string?,
	reason: string,
}

type ModPlan = {
	kind: Validate.Kind,
	classId: string,
	bodyStyle: string, -- Config/Vehicles body style (a design's: its template's)
	current: { [string]: any },
	previous: Validate.ModSpec?, -- the car's mods before this one (nil: none, or hidden)
}

local LOG = "[DesignerService]"
local CONTENT_TYPE = "application/json"
local FREE = 0 -- what the free new car costs
local MIN_SALT_LENGTH = 16 -- a stored salt shorter than this is replaced (a GUID is 36 characters)

local messages = Designer.messages

local DesignerService = {}
DesignerService.Validate = Validate

local DataService: DataServiceModule? = nil
local VehicleService: VehicleServiceModule? = nil
local GarageService: GarageServiceModule? = nil
local flagService: any = nil -- Phase 12's FeatureFlagService, when it exists

local designs: { [Player]: Pending } = {}
local modJobs: { [Player]: ModJob } = {}
local generations: { [string]: Generation } = {} -- by design uid
local reportedBy: { [Player]: { [string]: boolean } } = {}
local reportCounts: { [Player]: number } = {}
local recentReports: { ReportEntry } = {}
local random = Random.new()

local salt: string? = nil
local saltLoading = false
local saltWaiters: { thread } = {}
local secret: any = nil -- the backend key as a Roblox Secret (never a readable string)

-- Pure helpers ----------------------------------------------------------------------------------------------

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value :: any do
		copy[key] = deepCopy(item)
	end
	return copy :: any
end

-- "ok" keeps the credits reserved (they are spent when the player builds or discards); everything else refunds.
function DesignerService.settles(status: Status): "hold" | "refund"
	return if status == "ok" then "hold" else "refund"
end

-- The free re-rolls a new design comes with (Config/Designer.prices: the free first car's, or a paid one's).
function DesignerService.rerollsFor(free: boolean): number
	return if free then Designer.prices.rerollsFree else Designer.prices.rerollsPaid
end

-- What re-rolling costs with `rerollsLeft` free re-rolls left: nothing while one is left, else a new paid design.
function DesignerService.rerollCost(rerollsLeft: number): number
	return if rerollsLeft > 0 then FREE else Designer.prices.newCar
end

-- What the player reads for a request that ended with `status`. `refusal` is the designer's own friendly words
-- (already filtered), shown with "You weren't charged." after them.
function DesignerService.messageFor(status: Status, refusal: string?): string
	if (status == "refused" or status == "limited") and refusal ~= nil and refusal ~= "" then
		return refusal .. messages.refusedSuffix
	end
	local byStatus: { [string]: string } = {
		ok = messages.ready,
		refused = messages.refused,
		limited = messages.limited,
		error = messages.error,
		timeout = messages.timeout,
		closed = messages.closed,
		moderated = messages.filterFailed,
		filtered = messages.promptFiltered,
		invalid = messages.invalid,
		empty = messages.modNothing,
	}
	return byStatus[status] or messages.error
end

local function decode(body: any): any
	if type(body) ~= "string" then
		return nil
	end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, body)
	return if ok then value else nil
end

local function refusalOf(value: any): string?
	if type(value) == "table" and type(value.refusal) == "string" and string.match(value.refusal, "%S") then
		return value.refusal
	end
	return nil
end

-- A RequestAsync response ({ StatusCode, Body, ... }) as a Reply (the backend contract,
-- docs/phase-11-contracts.md "Backend"): 200 { ok = true, spec, cached } is a result, 200 or 429
-- { ok = false, refusal } a refusal (429: limits, the spend cap or the off switch), anything else an error.
function DesignerService.interpretResponse(response: any): Reply
	if type(response) ~= "table" then
		return { status = "error" }
	end
	local code = response.StatusCode
	local body = decode(response.Body)
	if code == 200 and type(body) == "table" then
		if body.ok == true and type(body.spec) == "table" then
			return { status = "ok", spec = body.spec, cached = body.cached == true }
		elseif body.ok == false then
			return { status = "refused", refusal = refusalOf(body) }
		end
		return { status = "error" }
	elseif code == 429 then
		return { status = "limited", refusal = refusalOf(body) }
	end
	return { status = "error" }
end

-- True when the player may design `classId`: a class in the kit that Config/Classes marks designable, and, for a
-- class with requiresOwnedClass (exotic), only while they own a catalog car of that class. Returns why not.
function DesignerService.canDesign(data: any, classId: any, kit: any): (boolean, string?)
	local classKit = if type(classId) == "string" then kit.classes[classId] else nil
	local class = if type(classId) == "string" then Classes[classId] else nil
	if type(classKit) ~= "table" or class == nil or not class.designable then
		return false, "unknownClass"
	end
	local required = classKit.requiresOwnedClass
	if type(required) ~= "string" then
		return true, nil
	end
	if type(data) == "table" and type(data.vehicles) == "table" then
		for _, vehicle in data.vehicles do
			local entry = if type(vehicle) == "table" and type(vehicle.vehicleId) == "string"
				then Catalog.getVehicle(vehicle.vehicleId)
				else nil
			if entry ~= nil and entry.class == required then
				return true, nil
			end
		end
	end
	return false, "classLocked"
end

-- A "surprise me" class the player may design, picked at random from kit.surpriseClasses.
function DesignerService.surpriseClass(data: any, kit: any, rng: Random): string
	local options: { string } = {}
	for _, classId in kit.surpriseClasses do
		if DesignerService.canDesign(data, classId, kit) then
			table.insert(options, classId)
		end
	end
	if #options == 0 then
		return kit.surpriseClasses[1]
	end
	return options[rng:NextInteger(1, #options)]
end

local function fallbackName(classId: string): string
	local class = Classes[classId]
	return string.format(messages.fallbackName, if class ~= nil then class.displayName else messages.genericClass)
end

-- The dev fake backend: a valid fixed spec per class (the asked class, else the first surprise class), or a
-- fixed catalog-safe mod. Prompts starting with a Config/Designer.devFake trigger fail that way instead. Pure.
function DesignerService.fakeReply(path: string, body: any, kit: any): Reply
	local fake = Designer.devFake
	local prompt = if type(body) == "table" and type(body.prompt) == "string" then string.lower(body.prompt) else ""
	local function startsWith(prefix: string): boolean
		return string.sub(prompt, 1, #prefix) == prefix
	end
	if startsWith(fake.triggers.refuse) then
		return { status = "refused", refusal = fake.refusal }
	elseif startsWith(fake.triggers.error) then
		return { status = "error" }
	elseif startsWith(fake.triggers.timeout) then
		return { status = "timeout" }
	end

	local keep = kit.mod.keep
	if path == Designer.paths.mod then
		local mod = fake.mod
		local function same(): { [string]: any }
			return { change = false, value = 0 }
		end
		if startsWith(fake.triggers.empty) then
			return {
				status = "ok",
				cached = false,
				spec = {
					refusal = nil,
					summary = mod.summary,
					body = {
						template = keep,
						length = same(),
						height = same(),
						roofline = same(),
						noseSlope = same(),
						flare = same(),
					},
					parts = { frontBumper = keep, rearBumper = keep, spoiler = keep, lights = keep, wheels = keep },
					paint = { primary = keep, secondary = keep, finish = keep, stripe = keep },
					stance = { rideHeight = same(), wheelSize = same() },
					extras = {},
					accessoryPrompt = "a small surfboard on the roof",
				},
			}
		end
		return {
			status = "ok",
			cached = false,
			spec = {
				refusal = nil,
				summary = mod.summary,
				body = {
					template = keep,
					length = same(),
					height = same(),
					roofline = same(),
					noseSlope = same(),
					flare = same(),
				},
				parts = { frontBumper = keep, rearBumper = keep, spoiler = keep, lights = keep, wheels = mod.wheels },
				paint = { primary = mod.primary, secondary = keep, finish = keep, stripe = keep },
				stance = { rideHeight = { change = true, value = mod.rideHeight }, wheelSize = same() },
				extras = table.clone(mod.extras),
				accessoryPrompt = "none",
			},
		}
	end

	local classId = if type(body) == "table"
			and type(body.classId) == "string"
			and kit.classes[body.classId]
		then body.classId
		else kit.surpriseClasses[1]
	local classKit = kit.classes[classId]
	local class = Classes[classId]
	local template = classKit.templates[1]
	local paint = fake.paint
	local reroll = type(body) == "table" and body.reroll == true
	return {
		status = "ok",
		cached = false,
		spec = {
			refusal = nil,
			name = string.format(fake.name, if class ~= nil then class.displayName else classId),
			tagline = fake.tagline,
			class = classId,
			energy = classKit.energy[1],
			personality = fake.personality,
			meshPrompt = string.format(fake.meshPrompt, template),
			body = { template = template, length = 0.5, height = 0.5, roofline = 0.5, noseSlope = 0.5, flare = 0.5 },
			parts = {
				frontBumper = kit.parts.frontBumper[1],
				rearBumper = kit.parts.rearBumper[1],
				spoiler = kit.parts.spoiler[1],
				lights = kit.parts.lights[1],
				wheels = kit.parts.wheels[2] or kit.parts.wheels[1],
			},
			paint = {
				-- A re-roll swaps the colors, so it visibly changes something.
				primary = if reroll then paint.secondary else paint.primary,
				secondary = if reroll then paint.primary else paint.secondary,
				finish = paint.finish,
				stripe = paint.stripe,
			},
			stance = { rideHeight = 0, wheelSize = 0.5 },
		},
	}
end

-- Pipelines --------------------------------------------------------------------------------------------------

local function designOutcome(status: Status, refusal: string?, prompt: string?): DesignOutcome
	return { status = status, message = DesignerService.messageFor(status, refusal), prompt = prompt }
end

-- The designer's refusal words as the player may see them: filtered, or the plain message when they name a real
-- brand (Util/BrandNames) or the filter changed them or couldn't be reached.
local function shownRefusal(deps: Deps, refusal: string?): string?
	if refusal == nil or utf8.len(refusal) == nil then
		return nil
	end
	local cut = utf8.offset(refusal, deps.kit.limits.refusal + 1)
	local text = if cut ~= nil then string.sub(refusal, 1, cut - 1) else refusal
	if BrandNames.has(text) then
		deps.log("the backend's refusal named a real brand")
		return nil
	end
	local filtered = deps.filter(text)
	return if filtered == text then text else nil
end

-- Filters a prompt (step 2). Returns the filtered text, or the outcome status that ends the request.
local function filterPrompt(deps: Deps, prompt: string): (string?, Status?)
	local filtered = deps.filter(prompt)
	if filtered == nil then
		return nil, "moderated"
	end
	if Validate.visibleChars(filtered) < deps.kit.limits.minFilteredChars then
		return nil, "filtered"
	end
	return filtered, nil
end

-- Steps 2 to 6 for a new car (the caller has done step 1 and reserved the credits; it settles them by
-- DesignerService.settles(outcome.status)).
function DesignerService.designPipeline(deps: Deps, input: DesignInput): DesignOutcome
	local kit = deps.kit
	local prompt = input.prompt
	if not input.filtered then
		local filtered, stop = filterPrompt(deps, prompt)
		if filtered == nil then
			return designOutcome(stop or "moderated", nil, nil)
		end
		prompt = filtered
	end
	local hash = deps.userHash()
	if hash == nil then
		deps.log("no player hash (the salt couldn't be loaded)")
		return designOutcome("error", nil, prompt)
	end
	local body: { [string]: any } = { kitVersion = kit.kitVersion, userHash = hash, prompt = prompt }
	if input.classId ~= nil then
		body.classId = input.classId
	end
	if input.reroll then
		body.reroll = true
	end
	local reply = deps.call(Designer.paths.design, body)
	if reply.status ~= "ok" then
		return designOutcome(reply.status, shownRefusal(deps, reply.refusal), prompt)
	end

	local checked, reasons = Validate.design(reply.spec, kit)
	if checked == nil then
		if reasons[1] == "refusal" then
			return designOutcome("refused", shownRefusal(deps, refusalOf(reply.spec)), prompt)
		end
		deps.log(`the backend's design failed validation: {table.concat(reasons, "; ")}`)
		return designOutcome("invalid", nil, prompt)
	end
	local spec: Validate.Spec? = checked
	if input.classId ~= nil and checked.class ~= input.classId then
		spec = Validate.forClass(checked, input.classId, kit)
	elseif not deps.canDesign(checked.class) then
		spec = Validate.forClass(checked, deps.pickClass(), kit)
	end
	if spec == nil then
		return designOutcome("invalid", nil, prompt)
	end

	-- Real brand names (CLAUDE.md hard rules 4 and 11): the backend checks too, but it isn't trusted. A named brand
	-- becomes the plain name, no tagline, or no generated look (the mesh prompt goes to a generation tool).
	if BrandNames.has(spec.name) then
		deps.log("the backend's design name named a real brand")
		spec.name = fallbackName(spec.class)
	end
	if BrandNames.has(spec.tagline) then
		deps.log("the backend's tagline named a real brand")
		spec.tagline = ""
	end
	if BrandNames.has(spec.meshPrompt) then
		deps.log("the backend's mesh prompt named a real brand")
		spec.meshPrompt = ""
	end

	local name = deps.filter(spec.name)
	local tagline = if spec.tagline == "" then "" else deps.filter(spec.tagline)
	if name == nil or tagline == nil then
		return designOutcome("moderated", nil, prompt)
	end
	if name ~= spec.name then
		spec.name = fallbackName(spec.class)
	end
	if tagline ~= spec.tagline then
		spec.tagline = ""
	end

	local ok, stats = pcall(deps.stats, spec, kit)
	if not ok or not Validate.statsInBand(stats, spec.class) then
		deps.log(`stats out of the {spec.class} band ({if ok then "built" else tostring(stats)})`)
		return designOutcome("invalid", nil, prompt)
	end
	return { status = "ok", message = messages.ready, prompt = prompt, spec = spec, stats = stats }
end

local function modOutcome(status: Status, refusal: string?): ModOutcome
	return { status = status, message = DesignerService.messageFor(status, refusal) }
end

-- Steps 2 to 5 for an AI mod (the caller has done step 1, reserved the credits and saves the result).
function DesignerService.modPipeline(deps: Deps, input: ModInput): ModOutcome
	local kit = deps.kit
	local prompt, stop = filterPrompt(deps, input.prompt)
	if prompt == nil then
		return modOutcome(stop or "moderated")
	end
	local hash = deps.userHash()
	if hash == nil then
		deps.log("no player hash (the salt couldn't be loaded)")
		return modOutcome("error")
	end
	local reply = deps.call(Designer.paths.mod, {
		kitVersion = kit.kitVersion,
		userHash = hash,
		prompt = prompt,
		kind = input.kind,
		classId = input.classId,
		current = input.current,
	})
	if reply.status ~= "ok" then
		return modOutcome(reply.status, shownRefusal(deps, reply.refusal))
	end
	local checked, reasons = Validate.mod(reply.spec, kit, input.kind)
	if checked == nil then
		if reasons[1] == "refusal" then
			return modOutcome("refused", shownRefusal(deps, refusalOf(reply.spec)))
		end
		deps.log(`the backend's mod failed validation: {table.concat(reasons, "; ")}`)
		return modOutcome("invalid")
	end
	-- Extras the car can't carry (Config/Customization classes and body styles) are left off before anything is
	-- charged: ModBuilder would skip them, so a mod that asked only for those changes nothing.
	local mod, dropped = Validate.fitExtras(checked, kit, input.classId, input.bodyStyle)
	if #dropped > 0 then
		deps.log(`left off extras a {input.classId} can't carry: {table.concat(dropped, ", ")}`)
	end
	if Validate.isEmptyMod(mod, kit) then
		return modOutcome("empty")
	end
	if BrandNames.has(mod.summary) then
		deps.log("the backend's mod summary named a real brand")
		mod.summary = messages.fallbackSummary
	end
	local summary = if mod.summary == "" then "" else deps.filter(mod.summary)
	if summary == nil then
		return modOutcome("moderated")
	end
	if summary ~= mod.summary or summary == "" then
		mod.summary = messages.fallbackSummary
	end
	return { status = "ok", message = string.format(messages.modReady, mod.summary), mod = mod }
end

-- The live world ---------------------------------------------------------------------------------------------

local function answer(ok: boolean, message: string, extra: { [string]: any }?): Answer
	local result: Answer = if extra ~= nil then table.clone(extra) else {}
	result.ok = ok
	result.message = message
	return result
end

local function refuse(code: string, message: string): Answer
	return answer(false, message, { code = code })
end

local function featureOn(): boolean
	if flagService ~= nil and type(flagService.isOn) == "function" then
		local ok, on = pcall(flagService.isOn, Designer.featureFlag)
		if ok and type(on) == "boolean" then
			return on
		end
	end
	local value = FeatureFlags.defaults[Designer.featureFlag]
	if type(value) == "boolean" then
		return value
	end
	return Designer.enabledByDefault
end

local function devFake(): boolean
	return Designer.devFakeBackend and RunService:IsStudio()
end

-- The backend key from the Secrets store (cached once found; a missing secret is asked for again next time).
local function backendKey(): any
	if secret ~= nil then
		return secret
	end
	local ok, result = pcall(function(): any
		return HttpService:GetSecret(Designer.secretName)
	end)
	if ok and result ~= nil then
		secret = result
		return result
	end
	return nil
end

-- True when requests can reach a backend: the dev fake in Studio, or a backendUrl and the secret.
function DesignerService.backendReady(): boolean
	if devFake() then
		return true
	end
	return Designer.backendUrl ~= "" and backendKey() ~= nil
end

-- POSTs `body` to the backend (or answers from the dev fake). Yields at most Config/Designer.requestTimeoutSeconds.
local function callBackend(path: string, body: { [string]: any }): Reply
	if devFake() then
		task.wait(Designer.devFake.delaySeconds)
		return DesignerService.fakeReply(path, body, DesignKit)
	end
	local key = backendKey()
	if Designer.backendUrl == "" or key == nil then
		return { status = "closed" }
	end
	local encoded, json = pcall(HttpService.JSONEncode, HttpService, body)
	if not encoded then
		warn(`{LOG} couldn't encode a request: {json}`)
		return { status = "error" }
	end

	local thread = coroutine.running()
	local settled = false
	local timer: thread? = nil
	local deadline = os.clock() + Designer.requestTimeoutSeconds
	local function settle(reply: Reply)
		if settled then
			return
		end
		settled = true
		local pendingTimer = timer
		timer = nil
		if pendingTimer ~= nil then
			task.cancel(pendingTimer)
		end
		task.defer(thread, reply)
	end
	task.spawn(function()
		for attempt = 0, Designer.networkRetries do
			local ok, response = pcall(function(): any
				return HttpService:RequestAsync({
					Url = Designer.backendUrl .. path,
					Method = "POST",
					Headers = { ["Content-Type"] = CONTENT_TYPE, [Designer.apiKeyHeader] = key } :: any,
					Body = json,
				})
			end)
			if settled then
				return
			end
			if ok then
				local reply = DesignerService.interpretResponse(response)
				if reply.status == "error" then
					warn(`{LOG} backend answered {tostring((response :: any).StatusCode)} on {path}`)
				end
				settle(reply)
				return
			end
			warn(`{LOG} couldn't reach the backend (try {attempt + 1}): {response}`)
			if os.clock() >= deadline then
				break
			end
		end
		settle({ status = "error" })
	end)
	if not settled then
		timer = task.delay(Designer.requestTimeoutSeconds, function()
			timer = nil
			settle({ status = "timeout" })
		end)
	end
	return coroutine.yield()
end

-- The salt for player hashes: made once (a GUID) and kept in a DataStore, never in the repo and never sent to a
-- client. Concurrent callers wait for the one load. In Studio without DataStore access a session salt stands in.
local function loadSalt(): string?
	if salt ~= nil then
		return salt
	end
	if saltLoading then
		table.insert(saltWaiters, coroutine.running())
		return coroutine.yield()
	end
	saltLoading = true
	local ok, result = pcall(function(): string?
		local store = DataStoreService:GetDataStore(Designer.salt.store)
		local stored = store:GetAsync(Designer.salt.key)
		if type(stored) == "string" and #stored >= MIN_SALT_LENGTH then
			return stored
		end
		local value = store:UpdateAsync(Designer.salt.key, function(old: any): any
			if type(old) == "string" and #old >= MIN_SALT_LENGTH then
				return old
			end
			return HttpService:GenerateGUID(false)
		end)
		return if type(value) == "string" then value else nil
	end)
	if ok and result ~= nil then
		salt = result
	elseif RunService:IsStudio() then
		warn(`{LOG} no DataStore salt in Studio ({if ok then "empty" else result}); using one for this session`)
		salt = HttpService:GenerateGUID(false)
	else
		warn(`{LOG} couldn't load the player-hash salt: {if ok then "empty" else result}`)
	end
	saltLoading = false
	local waiting = saltWaiters
	saltWaiters = {}
	for _, waiter in waiting do
		task.spawn(waiter, salt)
	end
	return salt
end

-- TextService's broadcast-safe version of text `player` is responsible for, or nil when the filter fails.
local function filterAs(player: Player, text: string): string?
	if text == "" then
		return ""
	end
	local ok, result = pcall(function(): string
		local filtered = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		warn(`{LOG} text filter failed for {player.Name}: {result}`)
		return nil
	end
	return result
end

local function depsFor(player: Player): Deps
	return {
		kit = DesignKit,
		filter = function(text: string): string?
			return filterAs(player, text)
		end,
		userHash = function(): string?
			local value = loadSalt()
			return if value ~= nil then Sha256.hex(value .. tostring(player.UserId)) else nil
		end,
		call = callBackend,
		stats = SpecBuilder.stats,
		canDesign = function(classId: string): boolean
			local dataService = DataService
			local data = if dataService ~= nil then dataService.get(player) else nil
			return (DesignerService.canDesign(data, classId, DesignKit))
		end,
		pickClass = function(): string
			local dataService = DataService
			local data = if dataService ~= nil then dataService.get(player) else nil
			return DesignerService.surpriseClass(data, DesignKit, random)
		end,
		log = function(message: string)
			warn(`{LOG} {player.Name}: {message}`)
		end,
	}
end

local function dataOf(player: Player): Types.PlayerData?
	local dataService = DataService
	return if dataService ~= nil then dataService.get(player) else nil
end

local function promptRefusal(why: string?, limit: number): Answer
	if why == "empty" then
		return refuse("empty", messages.empty)
	elseif why == "tooLong" then
		return refuse("tooLong", string.format(messages.tooLong, limit))
	end
	return refuse("badText", messages.badText)
end

local function outOfCredits(cost: number): Answer
	return answer(false, string.format(messages.outOfCredits, cost), {
		code = "credits",
		outOfCredits = true,
		reason = "credits",
		cost = cost,
	})
end

-- The car out in the world that is this player's owned car `uid`, if it's out and nobody is driving it.
local function parkedCar(player: Player, uid: string): boolean
	local vehicleService = VehicleService
	local car = if vehicleService ~= nil then vehicleService.getCar(player) else nil
	if car == nil or car:GetAttribute(Garage.ownedUidAttribute) ~= uid then
		return false
	end
	local seats = car:FindFirstChild("Seats")
	local driver = if seats ~= nil then seats:FindFirstChild("Driver") else nil
	return driver == nil or not driver:IsA("Seat") or driver.Occupant == nil
end

-- Generated looks -------------------------------------------------------------------------------------------

-- The owned car uids that are this design.
local function carsOfDesign(data: Types.PlayerData, designUid: string): { string }
	local uids: { string } = {}
	for _, vehicle in data.vehicles do
		if type(vehicle) == "table" and vehicle.designUid == designUid then
			table.insert(uids, vehicle.uid)
		end
	end
	return uids
end

-- Hands a finished look to VehicleService for the rest of the session; a parked car out in the world swaps to it.
local function deliverLook(designUid: string, record: Generation)
	local vehicleService, garageService = VehicleService, GarageService
	local look = record.look
	if generations[designUid] == record then
		generations[designUid] = nil
	end
	if vehicleService == nil or look == nil then
		return
	end
	vehicleService.setGeneratedLook(designUid, look)
	local owner = record.owner
	local data = dataOf(owner)
	if data == nil or garageService == nil then
		return
	end
	for _, uid in carsOfDesign(data, designUid) do
		if parkedCar(owner, uid) then
			garageService.refreshOwned(owner, uid)
		end
	end
end

-- Lets go of a design that won't be built (re-rolled away, discarded, its owner gone): stops waiting for its
-- generated look and drops what VehicleService built for it.
local function dropDesign(designUid: string?)
	if designUid == nil then
		return
	end
	local record = generations[designUid]
	generations[designUid] = nil
	if record ~= nil then
		record.dropped = true
		if record.look ~= nil then
			record.look:Destroy()
			record.look = nil
		end
	end
	local vehicleService = VehicleService
	if vehicleService ~= nil then
		vehicleService.forgetDesign(designUid)
	end
end

-- Starts the generated look for the latest result of a pending design, in the background.
local function startGeneration(player: Player, pending: Pending)
	local spec, designUid = pending.spec, pending.designUid
	local vehicleService = VehicleService
	if not Designer.generation.enabled or spec == nil or designUid == nil or vehicleService == nil then
		return
	end
	if string.match(spec.meshPrompt, "%S") == nil then
		return
	end
	local record: Generation = { owner = player, look = nil, built = false, dropped = false }
	generations[designUid] = record
	task.spawn(function()
		local kitModel = vehicleService.designBuild({ uid = designUid, spec = spec :: any, hidden = false })
		local look: Model?, why: string? = nil, "the kit build failed"
		if kitModel ~= nil then
			look, why = GeneratedAdapter.build(spec.meshPrompt, kitModel)
		end
		if record.dropped or generations[designUid] ~= record then
			if look ~= nil then
				look:Destroy()
			end
			return
		end
		if look == nil then
			generations[designUid] = nil
			print(`{LOG} {player.Name}: design {designUid} keeps its kit look ({why})`)
			return
		end
		record.look = look
		if record.built then
			deliverLook(designUid, record)
		end
	end)
end

-- New cars -------------------------------------------------------------------------------------------------

-- Saves a pending design into `data` (inside a DataService.update): the design and its OwnedVehicle, paid by
-- spending its reservation. Returns nil when saved, else the refusal code ("slots" or "gone"). Never yields.
local function saveDesign(data: Types.PlayerData, pending: Pending, uid: string, now: number): string?
	local garageService = GarageService
	local spec, designUid = pending.spec, pending.designUid
	if garageService == nil or spec == nil or designUid == nil then
		return "gone"
	end
	if not garageService.customRoomIn(data) then
		return "slots"
	end
	if not CreditsService.spendIn(data, pending.reservationId) then
		return "gone" -- the reservation is no longer there: never hand out an unpaid car
	end
	local design: Types.CustomDesign =
		{ uid = designUid, spec = deepCopy(spec) :: any, createdAt = now, hidden = false }
	table.insert(data.designs, design)
	local vehicle = Template.ownedVehicle(uid, Garage.customVehicleId, Designer.designTrim, FREE, now)
	vehicle.designUid = designUid
	-- The Wrap & Tint look starts as the design's own: its wheel style and finish (the paint stays "factory", the
	-- color it was built in).
	vehicle.wheels = spec.parts.wheels
	vehicle.finish = spec.paint.finish
	table.insert(data.vehicles, vehicle)
	return nil
end

local function sendDesign(player: Player, pending: Pending, message: string)
	local spec = pending.spec
	if spec == nil then
		return
	end
	local shown = Validate.clientSpec(spec)
	Net.fireClient("DesignResult", player, {
		requestId = pending.requestId,
		ok = true,
		message = message,
		kind = "design",
		design = shown,
		stats = pending.stats,
		designUid = pending.designUid,
		rerollFree = pending.rerollsLeft > 0,
		rerollsLeft = pending.rerollsLeft,
		free = pending.free,
		cost = pending.cost,
		preview = { spec = shown, stats = pending.stats },
	})
end

local function sendFailure(
	player: Player,
	requestId: string,
	kind: string,
	outcome: { status: Status, message: string }
)
	Net.fireClient("DesignResult", player, {
		requestId = requestId,
		ok = false,
		message = outcome.message,
		kind = kind,
		code = outcome.status,
	})
end

-- Runs the design pipeline for a pending design (its first request or a re-roll) and settles what it can.
local function runDesign(player: Player, pending: Pending, reroll: boolean)
	local input: DesignInput = {
		prompt = pending.prompt,
		classId = pending.classId,
		filtered = pending.filtered,
		reroll = reroll,
	}
	local ran, result = xpcall(DesignerService.designPipeline, debug.traceback, depsFor(player), input)
	local outcome: DesignOutcome = if ran then result else designOutcome("error", nil, nil)
	if not ran then
		warn(`{LOG} {player.Name}: the design pipeline failed: {result}`)
	end
	if designs[player] ~= pending then
		return -- the player left (and was settled) while this ran
	end
	pending.busy = false
	if outcome.prompt ~= nil then
		pending.prompt = outcome.prompt
		pending.filtered = true
	end
	local nextReservation = pending.nextReservation
	pending.nextReservation = nil

	if DesignerService.settles(outcome.status) == "hold" and outcome.spec ~= nil then
		if nextReservation ~= nil then
			-- A paid re-roll worked: the last result's credits are spent, the new reservation pays for this one.
			CreditsService.spend(player, pending.reservationId)
			pending.reservationId = nextReservation
			pending.free = false
			pending.cost = Designer.prices.newCar
			pending.rerollsLeft = DesignerService.rerollsFor(false)
		end
		dropDesign(pending.designUid)
		pending.spec = outcome.spec
		pending.stats = outcome.stats
		pending.designUid = HttpService:GenerateGUID(false)
		startGeneration(player, pending)
		sendDesign(player, pending, outcome.message)
		return
	end

	if reroll and pending.spec ~= nil then
		-- The re-roll failed: the last result stays, and so does what it was paid with.
		if nextReservation ~= nil then
			CreditsService.refund(player, nextReservation)
		else
			pending.rerollsLeft += 1
		end
		sendDesign(player, pending, messages.rerollFailed)
		return
	end
	designs[player] = nil
	CreditsService.refund(player, pending.reservationId)
	sendFailure(player, pending.requestId, "design", outcome)
end

local function onDesignCar(player: Player, payload: any): Answer
	local data = dataOf(player)
	local garageService = GarageService
	if data == nil or garageService == nil then
		return refuse("loading", messages.loading)
	end
	if not featureOn() then
		return refuse("off", messages.off)
	end
	local current = designs[player]
	if current ~= nil then
		return if current.busy then refuse("busy", messages.busy) else refuse("pending", messages.pendingChoice)
	end
	local limit = DesignKit.limits.promptChars
	local prompt, why = Validate.prompt(payload.prompt, limit)
	if prompt == nil then
		return promptRefusal(why, limit)
	end
	local classId: string? = payload.classId
	if classId ~= nil then
		local allowed, code = DesignerService.canDesign(data, classId, DesignKit)
		if not allowed then
			return refuse(
				code or "unknownClass",
				if code == "classLocked" then messages.classLocked else messages.unknownClass
			)
		end
	end
	if not garageService.customRoomIn(data) then
		return refuse("slots", messages.slotsFull)
	end
	if not DesignerService.backendReady() then
		return refuse("closed", messages.closed)
	end
	local free = CreditsService.freeAvailable(player)
	local cost = if free then FREE else Designer.prices.newCar
	local reservationId = if free
		then CreditsService.reserveFree(player, "design")
		else CreditsService.reserve(player, cost, "design")
	if reservationId == nil then
		-- The free car was available a moment ago, so only a save that couldn't be written stops it.
		return if free then refuse("loading", messages.loading) else outOfCredits(cost)
	end
	local pending: Pending = {
		requestId = HttpService:GenerateGUID(false),
		reservationId = reservationId,
		nextReservation = nil,
		free = free,
		cost = cost,
		classId = classId,
		prompt = prompt,
		filtered = false,
		busy = true,
		rerollsLeft = DesignerService.rerollsFor(free),
		spec = nil,
		stats = nil,
		designUid = nil,
	}
	designs[player] = pending
	task.spawn(runDesign, player, pending, false)
	return answer(true, messages.working, { requestId = pending.requestId, cost = cost, free = free })
end

local function build(player: Player, pending: Pending): Answer
	local dataService = DataService
	local spec, designUid = pending.spec, pending.designUid
	if dataService == nil or spec == nil or designUid == nil then
		return refuse("loading", messages.loading)
	end
	local uid = HttpService:GenerateGUID(false)
	local refusal: string? = nil
	local updated = dataService.update(player, function(data: Types.PlayerData)
		refusal = saveDesign(data, pending, uid, os.time())
	end)
	if not updated then
		return refuse("loading", messages.loading)
	end
	if refusal == "slots" then
		return refuse("slots", messages.slotsFull) -- still waiting: scrap a car, then build
	elseif refusal ~= nil then
		designs[player] = nil
		dropDesign(designUid)
		return refuse("pending", messages.noPending)
	end
	designs[player] = nil
	local vehicleService = VehicleService
	if vehicleService ~= nil then
		vehicleService.publishDesign({ uid = designUid, spec = spec :: any, hidden = false })
	end
	local record = generations[designUid]
	if record ~= nil then
		record.built = true
		if record.look ~= nil then
			deliverLook(designUid, record)
		end
	end
	print(`{LOG} {player.Name} built design {designUid}`)
	return answer(true, string.format(messages.built, spec.name), { uid = uid, designUid = designUid })
end

local function onDesignChoice(player: Player, payload: any): Answer
	local pending = designs[player]
	if pending == nil or pending.requestId ~= payload.requestId or pending.spec == nil then
		return refuse("pending", messages.noPending)
	end
	if pending.busy then
		return refuse("busy", messages.busy)
	end
	local choice: string = payload.choice
	if choice == "build" then
		return build(player, pending)
	elseif choice == "reroll" then
		if not DesignerService.backendReady() then
			return refuse("closed", messages.closed)
		end
		local cost = DesignerService.rerollCost(pending.rerollsLeft)
		if pending.rerollsLeft > 0 then
			pending.rerollsLeft -= 1
		else
			-- No free re-roll left: a re-roll is a new paid design, paid only if it works.
			local nextReservation = CreditsService.reserve(player, cost, "design")
			if nextReservation == nil then
				return outOfCredits(cost)
			end
			pending.nextReservation = nextReservation
		end
		pending.busy = true
		task.spawn(runDesign, player, pending, true)
		return answer(true, messages.rerolling, { requestId = pending.requestId })
	end
	-- Discard: the design came back, so what it cost stays spent.
	local dataService = DataService
	if dataService ~= nil then
		dataService.update(player, function(data: Types.PlayerData)
			CreditsService.spendIn(data, pending.reservationId)
		end)
	end
	designs[player] = nil
	dropDesign(pending.designUid)
	return answer(true, messages.discarded)
end

-- Mods -----------------------------------------------------------------------------------------------------

-- A car's saved mods as a validated mod spec, or nil (none, hidden by a moderator, or no longer valid).
local function savedMods(vehicle: Types.OwnedVehicle, kind: Validate.Kind): Validate.ModSpec?
	local mods = vehicle.mods
	if type(mods) ~= "table" or mods.hidden == true then
		return nil
	end
	return (Validate.mod(mods, DesignKit, kind))
end

-- A mod spec as the client and the backend see it (no generated-accessory prompt).
local function shownMod(mod: Validate.ModSpec?): { [string]: any }?
	if mod == nil then
		return nil
	end
	local copy: { [string]: any } = deepCopy(mod) :: any
	copy.accessoryPrompt = nil
	return copy
end

-- What a mod on this car may change and what the backend is told about it, or nil and why it can't be modded.
function DesignerService.modPlan(data: Types.PlayerData, vehicle: Types.OwnedVehicle, kit: any): (ModPlan?, string?)
	if vehicle.vehicleId == Garage.customVehicleId then
		local design: Types.CustomDesign? = nil
		for _, entry in data.designs do
			if type(entry) == "table" and entry.uid == vehicle.designUid then
				design = entry
			end
		end
		if design == nil or design.hidden == true then
			return nil, "cantMod" -- a hidden design stays plain
		end
		local spec = Validate.design(design.spec, kit)
		if spec == nil then
			return nil, "cantMod"
		end
		local previous = savedMods(vehicle, "kit")
		local template = kit.templates[spec.body.template]
		local bodyStyle: string = if template ~= nil then template.style else spec.body.template
		return {
			kind = "kit",
			classId = spec.class,
			bodyStyle = bodyStyle,
			previous = previous,
			current = {
				kind = "kit",
				classId = spec.class,
				spec = Validate.clientSpec(Validate.withMods(spec, previous, kit)),
				extras = if previous ~= nil then deepCopy(previous.extras) else kit.mod.keep,
				extrasThatFit = Validate.extrasThatFit(kit, spec.class, bodyStyle),
			},
		},
			nil
	end
	local entry = Catalog.getVehicle(vehicle.vehicleId)
	if entry == nil or not entry.playerDrivable then
		return nil, "cantMod"
	end
	local previous = savedMods(vehicle, "catalog")
	return {
		kind = "catalog",
		classId = entry.class,
		bodyStyle = entry.bodyStyle,
		previous = previous,
		current = {
			kind = "catalog",
			classId = entry.class,
			bodyStyle = entry.bodyStyle,
			look = {
				paint = vehicle.paint,
				finish = vehicle.finish,
				wheels = vehicle.wheels,
				rideHeight = vehicle.rideHeight,
			},
			mods = shownMod(previous),
			extrasThatFit = Validate.extrasThatFit(kit, entry.class, entry.bodyStyle),
		},
	},
		nil
end

-- Saves a mod into the car's entry (inside a DataService.update): the car's mods merged with the new one, paid by
-- spending its reservation, and the Wrap & Tint fields the mod takes over reset so the two never fight (new wheels
-- become the car's wheel style, new paint clears a shop paint back to "factory" so the mod's color shows, a new
-- finish becomes the car's finish, a new ride height resets the shop's). Returns the merged mods, or nil and why.
local function saveMod(
	data: Types.PlayerData,
	job: ModJob,
	mod: Validate.ModSpec,
	kind: Validate.Kind
): (Validate.ModSpec?, string?)
	local garageService = GarageService
	local vehicle = if garageService ~= nil then garageService.findVehicle(data, job.uid) else nil
	if vehicle == nil then
		return nil, "gone"
	end
	local previous = if type(vehicle.mods) == "table" and vehicle.mods.hidden ~= true then vehicle.mods else nil
	local merged = Validate.mergeMods(previous, mod, DesignKit)
	if not CreditsService.spendIn(data, job.reservationId) then
		return nil, "gone"
	end
	local saved: { [string]: any } = deepCopy(merged) :: any
	saved.hidden = false
	saved.kind = kind
	vehicle.mods = saved
	local keep = DesignKit.mod.keep
	if mod.parts.wheels ~= keep then
		vehicle.wheels = mod.parts.wheels
	end
	if mod.paint.primary ~= keep or mod.paint.secondary ~= keep then
		vehicle.paint = Garage.defaults.paint
	end
	if mod.paint.finish ~= keep then
		vehicle.finish = mod.paint.finish
	end
	if mod.stance.rideHeight.change then
		vehicle.rideHeight = Garage.defaults.rideHeight
	end
	return merged, nil
end

-- The mod with only the extras that really go on the car: VehicleService builds a copy of it out of the world with
-- its mods and this one merged, wearing the wheels its look will have (ModBuilder leaves off extras with no room
-- left in the part budget). The mod as it was when the car can't be built here, so a build problem never costs the
-- player their mod. Never changes `mod`.
local function buildableExtras(player: Player, job: ModJob, mod: Validate.ModSpec): Validate.ModSpec
	local extras = mod.extras
	local data = dataOf(player)
	local vehicleService, garageService = VehicleService, GarageService
	if type(extras) ~= "table" or data == nil or vehicleService == nil or garageService == nil then
		return mod
	end
	local vehicle = garageService.findVehicle(data, job.uid)
	local options = if vehicle ~= nil then garageService.spawnOptions(data, vehicle) else nil
	if vehicle == nil or options == nil then
		return mod
	end
	local previous = if type(vehicle.mods) == "table" and vehicle.mods.hidden ~= true then vehicle.mods else nil
	options.mods = Validate.mergeMods(previous, mod, DesignKit) :: any
	if mod.parts.wheels ~= DesignKit.mod.keep then
		options.wheels = mod.parts.wheels -- saveMod makes the mod's wheels the car's own
	end
	local ok, built = pcall(vehicleService.extrasAfterMods, vehicle.vehicleId, vehicle.trim, options)
	if not ok or built == nil then
		if not ok then
			warn(`{LOG} {player.Name}: couldn't check the mod's extras on car {job.uid}: {built}`)
		end
		return mod
	end
	local kept: { string } = {}
	for _, id in extras do
		if table.find(built, id) ~= nil then
			table.insert(kept, id)
		end
	end
	if #kept == #extras then
		return mod
	end
	warn(`{LOG} {player.Name}: car {job.uid} has no room for some extras (part budget); kept {#kept} of {#extras}`)
	local fitted = table.clone(mod)
	fitted.extras = if #kept > 0 then kept else DesignKit.mod.keep
	return fitted
end

local function runMod(player: Player, job: ModJob, prompt: string, plan: ModPlan)
	local input: ModInput = {
		prompt = prompt,
		kind = plan.kind,
		classId = plan.classId,
		bodyStyle = plan.bodyStyle,
		current = plan.current,
	}
	local ran, result = xpcall(DesignerService.modPipeline, debug.traceback, depsFor(player), input)
	local outcome: ModOutcome = if ran then result else modOutcome("error")
	if not ran then
		warn(`{LOG} {player.Name}: the mod pipeline failed: {result}`)
	end
	if modJobs[player] ~= job then
		return -- the player left (and was refunded) while this ran
	end
	modJobs[player] = nil
	local made = outcome.mod
	if DesignerService.settles(outcome.status) ~= "hold" or made == nil then
		CreditsService.refund(player, job.reservationId)
		sendFailure(player, job.requestId, "mod", outcome)
		return
	end
	-- Extras the part budget leaves off are never paid for either; a mod left with nothing is refunded.
	local mod = buildableExtras(player, job, made)
	if Validate.isEmptyMod(mod, DesignKit) then
		CreditsService.refund(player, job.reservationId)
		sendFailure(player, job.requestId, "mod", modOutcome("empty"))
		return
	end

	local merged: Validate.ModSpec? = nil
	local dataService = DataService
	local updated = dataService ~= nil
		and dataService.update(player, function(data: Types.PlayerData)
			merged = saveMod(data, job, mod, plan.kind)
		end)
	if not updated or merged == nil then
		CreditsService.refund(player, job.reservationId)
		sendFailure(player, job.requestId, "mod", modOutcome("error"))
		return
	end
	local garageService = GarageService
	if garageService ~= nil then
		garageService.refreshOwned(player, job.uid)
	end
	local after = shownMod(merged)
	Net.fireClient("DesignResult", player, {
		requestId = job.requestId,
		ok = true,
		message = outcome.message,
		kind = "mod",
		uid = job.uid,
		modKind = plan.kind,
		design = after,
		preview = { before = shownMod(plan.previous), after = after },
	})
end

local function onModCar(player: Player, payload: any): Answer
	local data = dataOf(player)
	local garageService = GarageService
	if data == nil or garageService == nil then
		return refuse("loading", messages.loading)
	end
	if not featureOn() then
		return refuse("off", messages.off)
	end
	if modJobs[player] ~= nil then
		return refuse("busy", messages.busy)
	end
	local vehicle = garageService.findVehicle(data, payload.uid)
	if vehicle == nil then
		return refuse("notYours", messages.notYours)
	end
	local plan = DesignerService.modPlan(data, vehicle, DesignKit)
	if plan == nil then
		return refuse("cantMod", messages.cantMod)
	end
	local limit = DesignKit.limits.modPromptChars
	local prompt, why = Validate.prompt(payload.prompt, limit)
	if prompt == nil then
		return promptRefusal(why, limit)
	end
	if not DesignerService.backendReady() then
		return refuse("closed", messages.closed)
	end
	local cost = Designer.prices.mod
	local reservationId = CreditsService.reserve(player, cost, "mod")
	if reservationId == nil then
		return outOfCredits(cost)
	end
	local job: ModJob =
		{ requestId = HttpService:GenerateGUID(false), reservationId = reservationId, uid = vehicle.uid }
	modJobs[player] = job
	task.spawn(runMod, player, job, prompt, plan)
	return answer(true, messages.modWorking, { requestId = job.requestId, cost = cost })
end

-- Moderation -----------------------------------------------------------------------------------------------

local function isAdmin(player: Player): boolean
	if Designer.studioCountsAsAdmin and RunService:IsStudio() then
		return true
	end
	return table.find(Admins.userIds, player.UserId) ~= nil
end

local function validReason(reason: string): boolean
	for _, entry in Designer.report.reasons do
		if entry.id == reason then
			return true
		end
	end
	return false
end

-- What a ReportDesign uid points at: the reporter's own waiting design (its requestId), one of their own custom
-- or modded cars, or a custom or modded car out in the world (its OwnedUid or DesignUid). nil when it's none of
-- these (or the car is neither custom nor modded).
local function reportTarget(player: Player, uid: string): ReportEntry?
	local pending = designs[player]
	if pending ~= nil and pending.requestId == uid then
		return { at = 0, reporter = 0, owner = player.UserId, designUid = pending.designUid, reason = "" }
	end
	local function judged(owner: Player?, ownerId: number, vehicleUid: string?, designUid: string?): ReportEntry?
		local data = if owner ~= nil then dataOf(owner) else nil
		local garageService = GarageService
		local vehicle = if data ~= nil
				and vehicleUid ~= nil
				and garageService ~= nil
			then garageService.findVehicle(data, vehicleUid)
			else nil
		local modded = vehicle ~= nil and type(vehicle.mods) == "table"
		local design = designUid or (if vehicle ~= nil then vehicle.designUid else nil)
		if design == nil and not modded then
			return nil
		end
		return { at = 0, reporter = 0, owner = ownerId, designUid = design, vehicleUid = vehicleUid, reason = "" }
	end
	local own = dataOf(player)
	local garageService = GarageService
	if own ~= nil and garageService ~= nil then
		if garageService.findVehicle(own, uid) ~= nil then
			return judged(player, player.UserId, uid, nil)
		end
		if garageService.findDesign(own, uid) ~= nil then
			return { at = 0, reporter = 0, owner = player.UserId, designUid = uid, reason = "" }
		end
	end
	local folder = Workspace:FindFirstChild(Spawning.vehiclesFolder)
	if folder == nil then
		return nil
	end
	for _, car in folder:GetChildren() do
		local ownedUid = car:GetAttribute(Garage.ownedUidAttribute)
		local designUid = car:GetAttribute("DesignUid")
		if car:IsA("Model") and (ownedUid == uid or designUid == uid) then
			local ownerId = car:GetAttribute("OwnerUserId")
			if type(ownerId) ~= "number" then
				return nil
			end
			return judged(
				Players:GetPlayerByUserId(ownerId),
				ownerId,
				if type(ownedUid) == "string" then ownedUid else nil,
				if type(designUid) == "string" then designUid else nil
			)
		end
	end
	return nil
end

local function onReport(player: Player, payload: any): Answer
	local reason: string = payload.reason
	if not validReason(reason) then
		return refuse("reason", messages.reportReason)
	end
	local target = reportTarget(player, payload.uid)
	if target == nil then
		return refuse("notFound", messages.reportNotFound)
	end
	local key = target.designUid or target.vehicleUid or payload.uid
	local mine = reportedBy[player]
	if mine == nil then
		mine = {}
		reportedBy[player] = mine
	end
	if mine[key] then
		return refuse("already", messages.reportAlready)
	end
	local count = reportCounts[player] or 0
	if count >= Designer.report.maxPerSession then
		return refuse("limit", messages.reportLimit)
	end
	mine[key] = true
	reportCounts[player] = count + 1
	target.at = os.time()
	target.reporter = player.UserId
	target.reason = reason
	table.insert(recentReports, target)
	while #recentReports > Designer.report.recentKept do
		table.remove(recentReports, 1)
	end
	warn(
		`{LOG} report: user {player.UserId} reported design {tostring(target.designUid)} / car `
			.. `{tostring(target.vehicleUid)} of user {tostring(target.owner)} ({reason})`
	)
	return answer(true, messages.reported)
end

-- The latest reports, newest last (for the Phase 12 admin tools). Copies.
function DesignerService.recentReports(): { ReportEntry }
	return deepCopy(recentReports)
end

-- Marks `uid` (a design, or a car's mod) hidden in one owner's loaded data, re-publishes a hidden design's plain
-- catalog entry, drops its generated look, and brings any of their cars that are out back with the plain look.
-- Returns true when something of theirs was hidden.
local function applyHidden(owner: Player, uid: string): boolean
	local dataService, vehicleService, garageService = DataService, VehicleService, GarageService
	if dataService == nil or vehicleService == nil or garageService == nil then
		return false
	end
	local refresh: { string } = {}
	local hiddenDesign: Types.CustomDesign? = nil
	dataService.update(owner, function(data: Types.PlayerData)
		local design = garageService.findDesign(data, uid)
		if design ~= nil and design.hidden ~= true then
			design.hidden = true
			hiddenDesign = design
			for _, carUid in carsOfDesign(data, uid) do
				table.insert(refresh, carUid)
			end
		end
		local vehicle = garageService.findVehicle(data, uid)
		if vehicle ~= nil and type(vehicle.mods) == "table" and vehicle.mods.hidden ~= true then
			vehicle.mods.hidden = true
			table.insert(refresh, vehicle.uid)
		end
	end)
	local design = hiddenDesign
	if design ~= nil then
		vehicleService.setGeneratedLook(uid, nil)
		vehicleService.publishDesign({ uid = design.uid, spec = design.spec, hidden = true })
	end
	for _, carUid in refresh do
		garageService.refreshOwned(owner, carUid)
	end
	return design ~= nil or #refresh > 0
end

-- Hides design or mod `uid` everywhere for admin `player`: saved in Designer.hiddenStore (every server, every
-- join) and applied at once to its owner if they're in this server. The HideDesign remote and AdminService's
-- hideDesign action both end here. Yields (DataStore).
function DesignerService.hide(player: Player, uid: string): Answer
	if not isAdmin(player) then
		warn(`{LOG} {player.Name} ({player.UserId}) tried HideDesign without being an admin`)
		return refuse("notAdmin", messages.notAdmin)
	end
	if type(uid) ~= "string" or uid == "" then
		return refuse("failed", messages.hideFailed)
	end
	local saved = pcall(function()
		DataStoreService:GetDataStore(Designer.hiddenStore):SetAsync(uid, true)
	end)
	local here = false
	for _, owner in Players:GetPlayers() do
		if applyHidden(owner, uid) then
			here = true
		end
	end
	warn(`{LOG} admin {player.UserId} hid {uid} (saved: {saved}, on this server: {here})`)
	if here then
		return answer(true, messages.hidden)
	elseif saved then
		return answer(true, messages.hiddenLater)
	end
	return refuse("failed", messages.hideFailed)
end

local function onHide(player: Player, payload: any): Answer
	return DesignerService.hide(player, payload.designUid)
end

-- True when saved AI text no longer passes: it names a real brand (Util/BrandNames, which may have grown) or
-- today's text filter changes it. A filter that can't be reached counts as passing: the text passed when it was
-- made, and a filter outage must not rename every car. Yields (TextService).
local function failsRecheck(player: Player, text: any): boolean
	if type(text) ~= "string" or text == "" then
		return false
	end
	if BrandNames.has(text) then
		return true
	end
	local filtered = filterAs(player, text)
	return filtered ~= nil and filtered ~= text
end

-- Join: saved AI text (designs' names and taglines, mods' summaries) is checked again before anyone sees it again
-- (CLAUDE.md hard rule 5, the way custom plates are filtered again on every spawn): the published catalog entry
-- reaches every client. Text that no longer passes is replaced by its plain stand-in ("Custom <class>", no tagline,
-- "Mod applied") and saved that way. Hidden designs and mods already show plain text. Yields (TextService).
local function recheckSavedText(player: Player)
	local data = dataOf(player)
	local dataService = DataService
	if data == nil or dataService == nil then
		return
	end
	local names: { [string]: string } = {} -- design uid -> its plain name
	local taglines: { [string]: boolean } = {} -- design uids whose tagline goes
	local summaries: { [string]: boolean } = {} -- car uids whose mod summary goes
	for _, design in data.designs do
		local spec = if type(design) == "table" and design.hidden ~= true then design.spec else nil
		if type(spec) ~= "table" or type(design.uid) ~= "string" then
			continue
		end
		local plain = fallbackName(if type(spec.class) == "string" then spec.class else "")
		if spec.name ~= plain and failsRecheck(player, spec.name) then
			names[design.uid] = plain
		end
		if failsRecheck(player, spec.tagline) then
			taglines[design.uid] = true
		end
	end
	for _, vehicle in data.vehicles do
		local mods = if type(vehicle) == "table" then vehicle.mods else nil
		if
			type(mods) == "table"
			and mods.hidden ~= true
			and type(vehicle.uid) == "string"
			and mods.summary ~= messages.fallbackSummary
			and failsRecheck(player, mods.summary)
		then
			summaries[vehicle.uid] = true
		end
	end
	if next(names) == nil and next(taglines) == nil and next(summaries) == nil then
		return
	end
	if player.Parent ~= Players then
		return
	end
	dataService.update(player, function(fresh: Types.PlayerData)
		for _, design in fresh.designs do
			local spec = if type(design) == "table" then design.spec else nil
			if type(spec) ~= "table" then
				continue
			end
			local name = names[design.uid]
			if name ~= nil then
				spec.name = name
			end
			if taglines[design.uid] then
				spec.tagline = ""
			end
		end
		for _, vehicle in fresh.vehicles do
			local mods = if type(vehicle) == "table" then vehicle.mods else nil
			if type(mods) == "table" and summaries[vehicle.uid] then
				mods.summary = messages.fallbackSummary
			end
		end
	end)
	print(`{LOG} {player.Name}: replaced saved designer text that no longer passes the filter or brand check`)
end

-- Join: hides whatever a moderator hid while the player was away, checks their saved designer text again, then
-- publishes their designs' catalog entries (so the phone and other players' clients can look them up). Yields
-- (DataStore reads, TextService).
local function onLoaded(player: Player)
	local data = dataOf(player)
	if data == nil then
		return
	end
	local uids: { string } = {}
	for _, design in data.designs do
		if type(design) == "table" and type(design.uid) == "string" and design.hidden ~= true then
			table.insert(uids, design.uid)
		end
	end
	for _, vehicle in data.vehicles do
		local mods = if type(vehicle) == "table" then vehicle.mods else nil
		if type(mods) == "table" and mods.hidden ~= true and type(vehicle.uid) == "string" then
			table.insert(uids, vehicle.uid)
		end
	end
	if #uids > 0 then
		local ok, store = pcall(DataStoreService.GetDataStore, DataStoreService, Designer.hiddenStore)
		for _, uid in uids do
			local found, hidden = false, nil
			if ok then
				found, hidden = pcall(function(): any
					return (store :: DataStore):GetAsync(uid)
				end)
			end
			if found and hidden == true and player.Parent == Players then
				applyHidden(player, uid)
			end
		end
	end
	recheckSavedText(player)
	local fresh = dataOf(player)
	local vehicleService = VehicleService
	if fresh == nil or vehicleService == nil then
		return
	end
	for _, design in fresh.designs do
		if type(design) == "table" and type(design.uid) == "string" and type(design.spec) == "table" then
			vehicleService.publishDesign({ uid = design.uid, spec = design.spec, hidden = design.hidden == true })
		end
	end
end

-- Leaving (DataService.beforeRelease, so the save still takes writes; never yields): a design waiting for a
-- choice is built for the player (or refunded when it can't be), anything still in flight is refunded, and what
-- this server built for their designs is dropped.
local function onRelease(player: Player)
	local pending = designs[player]
	local job = modJobs[player]
	designs[player] = nil
	modJobs[player] = nil
	local dataService = DataService
	if dataService == nil then
		return
	end
	if pending ~= nil or job ~= nil then
		dataService.update(player, function(data: Types.PlayerData)
			if pending ~= nil then
				if pending.nextReservation ~= nil then
					CreditsService.refundIn(data, pending.nextReservation)
				end
				-- A result already shown (even with a re-roll still running) is theirs: build it.
				local refusal = if pending.spec ~= nil
					then saveDesign(data, pending, HttpService:GenerateGUID(false), os.time())
					else "gone"
				if refusal ~= nil then
					CreditsService.refundIn(data, pending.reservationId)
				end
			end
			if job ~= nil then
				CreditsService.refundIn(data, job.reservationId)
			end
		end)
		if pending ~= nil then
			dropDesign(pending.designUid)
		end
	end
	for designUid, record in table.clone(generations) do
		if record.owner == player then
			dropDesign(designUid)
		end
	end
	local data = dataService.get(player)
	local vehicleService = VehicleService
	if data ~= nil and vehicleService ~= nil then
		for _, design in data.designs do
			if type(design) == "table" and type(design.uid) == "string" then
				vehicleService.forgetDesign(design.uid)
			end
		end
	end
end

-- Boot ------------------------------------------------------------------------------------------------------

function DesignerService:Init()
	DataService = require(script.Parent.DataService)
	VehicleService = require(script.Parent.VehicleService)
	GarageService = require(script.Parent.GarageService)
	local flags = script.Parent:FindFirstChild("FeatureFlagService")
	if flags ~= nil and flags:IsA("ModuleScript") then
		local ok, module = pcall(require :: any, flags)
		if ok and type(module) == "table" then
			flagService = module
		end
	end
end

function DesignerService:Start()
	Net.onServerInvoke("DesignCar", onDesignCar)
	Net.onServerInvoke("ModCar", onModCar)
	Net.onServerInvoke("DesignChoice", onDesignChoice)
	Net.onServerInvoke("ReportDesign", onReport)
	Net.onServerInvoke("HideDesign", onHide)
	local dataService = DataService
	if dataService ~= nil then
		dataService.onLoaded(function(player: Player, _data: Types.PlayerData)
			onLoaded(player)
		end)
		dataService.beforeRelease(onRelease)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		reportedBy[player] = nil
		reportCounts[player] = nil
	end)
end

return DesignerService
