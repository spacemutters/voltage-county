--!strict
-- Design Credits and how the AI Car Designer pays for requests (PLAN.md Phase 11 acceptance "Credits spec";
-- docs/phase-11-contracts.md "Server"):
--   * the free new car works exactly once per player (and comes back when its request fails)
--   * reservations are spent on success and refunded on a refusal, a moderation failure, an error, a timeout or an
--     unusable reply, each exactly once
--   * the re-roll is free once per paid design; after that a re-roll is a new paid design
--   * nothing can drive the balance below zero (or past the cap), and damaged saves are repaired
-- It drives the real rules: CreditsService.Ledger on a credits table and DesignerService's request pipelines with
-- fake text filters and a fake backend (no Roblox services, no network), settled the way the service settles them
-- (DesignerService.settles). Also checks how backend answers are read, the Studio fake backend and the class rules.
-- Pure: runs in Edit mode (ServerStorage.Tests).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BrandNames = require(ReplicatedStorage.Shared.Util.BrandNames)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Services = ServerScriptService.Server.Services
local CreditsService = require(Services.CreditsService)
local DesignerService = require(Services.DesignerService)
local Validate = require(Services.DesignerService.Validate)

local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

local Ledger = CreditsService.Ledger
local PRICES = Designer.prices
local KEEP: string = kit.mod.keep
local NOW = 1_700_000_000

type Credits = CreditsService.Credits
type Reply = DesignerService.Reply
type Deps = DesignerService.Deps

local function credits(balance: number, freeDesignUsed: boolean?): Credits
	return { balance = balance, freeDesignUsed = freeDesignUsed == true, reserved = {} }
end

-- Stats in the middle of a class band (what SpecBuilder.stats gives is checked in DesignerValidate.spec).
local function middleStats(classId: string): { [string]: any }
	local class = Classes[classId]
	local function middle(range: Classes.Range): number
		return (range.min + range.max) / 2
	end
	return {
		topSpeedMph = middle(class.topSpeedMph),
		zeroToSixtySec = middle(class.zeroToSixtySec),
		handling = middle(class.handling),
		energyMinutes = middle(class.energyMinutes),
		seats = math.ceil(class.seats.min),
		drive = "RWD",
	}
end

-- A valid design spec as the backend would send it.
local function backendDesign(classId: string?): { [string]: any }
	local id = classId or "sedan"
	local class = kit.classes[id]
	return {
		refusal = nil,
		name = "Dune Hopper",
		tagline = "A cheerful little runabout",
		class = id,
		energy = class.energy[1],
		personality = "balanced",
		meshPrompt = "rounded compact car with short overhangs",
		body = {
			template = class.templates[1],
			length = 0.5,
			height = 0.5,
			roofline = 0.5,
			noseSlope = 0.5,
			flare = 0.5,
		},
		parts = {
			frontBumper = kit.parts.frontBumper[1],
			rearBumper = kit.parts.rearBumper[1],
			spoiler = kit.parts.spoiler[1],
			lights = kit.parts.lights[1],
			wheels = kit.parts.wheels[1],
		},
		paint = { primary = "#336699", secondary = "#EEEEEE", finish = kit.finishes[1], stripe = kit.stripes[1] },
		stance = { rideHeight = 0, wheelSize = 0.5 },
	}
end

-- A valid catalog mod as the backend would send it.
local function backendMod(): { [string]: any }
	local function same(): { [string]: any }
		return { change = false, value = 0 }
	end
	return {
		refusal = nil,
		summary = "Desert tan with trail wheels",
		body = {
			template = KEEP,
			length = same(),
			height = same(),
			roofline = same(),
			noseSlope = same(),
			flare = same(),
		},
		parts = { frontBumper = KEEP, rearBumper = KEEP, spoiler = KEEP, lights = KEEP, wheels = "trail" },
		paint = { primary = "#C2A27A", secondary = KEEP, finish = KEEP, stripe = KEEP },
		stance = { rideHeight = { change = true, value = 0.5 }, wheelSize = same() },
		extras = { "roof_rack" },
		accessoryPrompt = "none",
	}
end

-- Fake deps: a filter that changes nothing (or `filter`), a fixed hash, a backend that always gives `reply`, and
-- stats in the middle of the class band. `calls` records every backend call.
local function fakeDeps(
	reply: Reply,
	options: {
		filter: ((string) -> string?)?,
		stats: ((any, any) -> any)?,
		canDesign: boolean?,
		hash: string?,
	}?
): (Deps, { { path: string, body: { [string]: any } } })
	local calls: { { path: string, body: { [string]: any } } } = {}
	local opts = options or {}
	local deps: Deps = {
		kit = kit,
		filter = opts.filter or function(text: string): string?
			return text
		end,
		userHash = function(): string?
			return opts.hash or "a1b2c3"
		end,
		call = function(path: string, body: { [string]: any }): Reply
			table.insert(calls, { path = path, body = body })
			return reply
		end,
		stats = opts.stats or function(spec: any, _kit: any): any
			return middleStats(spec.class)
		end,
		canDesign = function(_classId: string): boolean
			return opts.canDesign ~= false
		end,
		pickClass = function(): string
			return "economy"
		end,
		log = function(_message: string) end,
	}
	return deps, calls
end

-- One new-car request the way DesignerService runs it: reserve `cost`, run the pipeline, then hold-and-build
-- (spend) or refund. Returns the outcome and whether the reservation could be made.
local function designRequest(
	wallet: Credits,
	cost: number,
	deps: Deps,
	input: DesignerService.DesignInput,
	id: string
): (DesignerService.DesignOutcome?, boolean)
	if not Ledger.reserve(wallet, cost, id, NOW) then
		return nil, false
	end
	local outcome = DesignerService.designPipeline(deps, input)
	if DesignerService.settles(outcome.status) == "hold" then
		Ledger.spend(wallet, id) -- built (or discarded): the design came back, so it is paid for
	else
		Ledger.refund(wallet, id)
	end
	return outcome, true
end

local function modRequest(wallet: Credits, deps: Deps, kind: "kit" | "catalog", id: string): DesignerService.ModOutcome
	assert(Ledger.reserve(wallet, PRICES.mod, id, NOW), "the mod reservation failed")
	local outcome = DesignerService.modPipeline(deps, {
		prompt = "lift it, chunky tires, desert tan",
		kind = kind,
		classId = "pickup",
		current = { kind = kind, classId = "pickup" },
	})
	if DesignerService.settles(outcome.status) == "hold" then
		Ledger.spend(wallet, id)
	else
		Ledger.refund(wallet, id)
	end
	return outcome
end

local DESIGN_INPUT: DesignerService.DesignInput =
	{ prompt = "a cheerful little runabout for the beach", classId = "sedan" }

local function catalogVehicleOfClass(classId: string): string?
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil and vehicle.class == classId then
			return vehicleId
		end
	end
	return nil
end

return function(t: Harness.Api)
	t.describe("Credits ledger", function()
		t.it("gives every player the free new car exactly once", function()
			local wallet = credits(0)
			t.expect(Ledger.freeAvailable(wallet)).toBe(true)
			t.expect(Ledger.reserve(wallet, 0, Ledger.freeId("first"), NOW)).toBe(true)
			t.expect(Ledger.freeAvailable(wallet)).toBe(false)
			-- While the free car is held by a request, a second free request is refused.
			t.expect(Ledger.reserve(wallet, 0, Ledger.freeId("second"), NOW)).toBe(false)
			t.expect(Ledger.spend(wallet, Ledger.freeId("first"))).toBe(true)
			t.expect(wallet.freeDesignUsed).toBe(true)
			t.expect(Ledger.reserve(wallet, 0, Ledger.freeId("third"), NOW)).toBe(false)
			t.expect(wallet.balance).toBe(0)
			t.expect(#wallet.reserved).toBe(0)
		end)

		t.it("gives the free car back when its request fails", function()
			local wallet = credits(0)
			t.expect(Ledger.reserve(wallet, 0, Ledger.freeId("first"), NOW)).toBe(true)
			t.expect(Ledger.refund(wallet, Ledger.freeId("first"))).toBe(true)
			t.expect(Ledger.freeAvailable(wallet)).toBe(true)
			t.expect(Ledger.reserve(wallet, 0, Ledger.freeId("again"), NOW)).toBe(true)
		end)

		-- Prices are data (Config/Designer.prices): an event may make mods cost 0. That must never use up (or need)
		-- the free new car.
		t.it("treats a price of 0 as holding nothing, never as the free car", function()
			local wallet = credits(3)
			t.expect(Ledger.reserve(wallet, 0, "mod", NOW)).toBe(true)
			t.expect(wallet.freeDesignUsed).toBe(false)
			t.expect(wallet.balance).toBe(3)
			t.expect(Ledger.refund(wallet, "mod")).toBe(true)
			t.expect(wallet.balance).toBe(3)
			t.expect(Ledger.freeAvailable(wallet)).toBe(true)
			-- With the free car already used, a 0 price still goes through.
			local used = credits(0, true)
			t.expect(Ledger.reserve(used, 0, "mod", NOW)).toBe(true)
			t.expect(Ledger.spend(used, "mod")).toBe(true)
			t.expect(used.balance).toBe(0)
			-- The free car is only ever a reservation of 0.
			t.expect(Ledger.reserve(credits(5), 2, Ledger.freeId("x"), NOW)).toBe(false)
			t.expect(Ledger.isFreeId(Ledger.freeId("x"))).toBe(true)
			t.expect(Ledger.isFreeId("x")).toBe(false)
		end)

		t.it("takes credits at reserve, keeps them on spend and returns them on refund", function()
			local wallet = credits(5)
			t.expect(Ledger.reserve(wallet, 2, "a", NOW)).toBe(true)
			t.expect(wallet.balance).toBe(3)
			t.expect(wallet.reserved).toEqual({ { id = "a", amount = 2, at = NOW } })
			t.expect(Ledger.spend(wallet, "a")).toBe(true)
			t.expect(wallet.balance).toBe(3)
			t.expect(Ledger.reserve(wallet, 2, "b", NOW)).toBe(true)
			t.expect(Ledger.refund(wallet, "b")).toBe(true)
			t.expect(wallet.balance).toBe(3)
			t.expect(#wallet.reserved).toBe(0)
		end)

		t.it("settles each reservation once", function()
			local wallet = credits(4)
			Ledger.reserve(wallet, 2, "a", NOW)
			t.expect(Ledger.spend(wallet, "a")).toBe(true)
			t.expect(Ledger.spend(wallet, "a")).toBe(false)
			t.expect(Ledger.refund(wallet, "a")).toBe(false) -- a refund after the spend gives nothing back
			t.expect(wallet.balance).toBe(2)
			Ledger.reserve(wallet, 1, "b", NOW)
			t.expect(Ledger.refund(wallet, "b")).toBe(true)
			t.expect(Ledger.refund(wallet, "b")).toBe(false)
			t.expect(wallet.balance).toBe(2)
			t.expect(Ledger.spend(wallet, "never")).toBe(false)
			t.expect(Ledger.refund(wallet, "never")).toBe(false)
			t.expect(Ledger.reserve(wallet, 1, "c", NOW)).toBe(true)
			t.expect(Ledger.reserve(wallet, 1, "c", NOW)).toBe(false) -- the same id twice
			t.expect(wallet.balance).toBe(1)
		end)

		t.it("never lets the balance go below zero", function()
			local wallet = credits(1)
			t.expect(Ledger.reserve(wallet, 2, "a", NOW)).toBe(false)
			t.expect(wallet.balance).toBe(1)
			t.expect(Ledger.reserve(wallet, 1, "b", NOW)).toBe(true)
			t.expect(wallet.balance).toBe(0)
			t.expect(Ledger.reserve(wallet, 1, "c", NOW)).toBe(false)
			for _, amount in { -1, 1.5, 0 / 0, math.huge } do
				t.expect(Ledger.reserve(wallet, amount, `odd{amount}`, NOW)).toBe(false)
			end
			t.expect(wallet.balance).toBe(0)
			t.expect(#wallet.reserved).toBe(1)
		end)

		t.it("grants whole credits only, up to the cap", function()
			local wallet = credits(0)
			t.expect(Ledger.grant(wallet, 5)).toBe(5)
			for _, amount in { 0, -5, 1.5, 0 / 0 } do
				t.expect(Ledger.grant(wallet, amount)).toBe(0)
			end
			t.expect(wallet.balance).toBe(5)
			t.expect(Ledger.grant(wallet, Designer.maxCredits * 2)).toBe(Designer.maxCredits - 5)
			t.expect(wallet.balance).toBe(Designer.maxCredits)
			-- A refund never pushes past the cap either.
			local full = credits(Designer.maxCredits)
			Ledger.reserve(full, 2, "a", NOW)
			full.balance = Designer.maxCredits
			Ledger.refund(full, "a")
			t.expect(full.balance).toBe(Designer.maxCredits)
		end)

		t.it("refunds what an earlier session left reserved, except this server's own", function()
			local wallet = credits(10)
			Ledger.reserve(wallet, 0, Ledger.freeId("free"), NOW)
			Ledger.reserve(wallet, 2, "old", NOW)
			Ledger.reserve(wallet, 1, "mine", NOW)
			t.expect(wallet.balance).toBe(7)
			t.expect(Ledger.clearStale(wallet, { mine = true })).toBe(2)
			t.expect(wallet.balance).toBe(9)
			t.expect(wallet.freeDesignUsed).toBe(false)
			t.expect(wallet.reserved).toEqual({ { id = "mine", amount = 1, at = NOW } })
			t.expect(Ledger.clearStale(wallet)).toBe(1)
			t.expect(wallet.balance).toBe(10)
		end)

		t.it("repairs damaged saves without ever making credits", function()
			t.expect(Ledger.sanitize({ balance = -5 }).balance).toBe(0)
			t.expect(Ledger.sanitize({ balance = 2.7 }).balance).toBe(2)
			t.expect(Ledger.sanitize({ balance = 0 / 0 }).balance).toBe(0)
			t.expect(Ledger.sanitize({ balance = math.huge }).balance).toBe(Designer.maxCredits)
			t.expect(Ledger.sanitize("junk")).toEqual({ balance = 0, freeDesignUsed = false, reserved = {} })
			local repaired = Ledger.sanitize({
				balance = 3,
				freeDesignUsed = "yes",
				reserved = {
					"junk",
					{ id = "ok", amount = 1, at = NOW },
					{ id = 4, amount = 1, at = NOW },
					{
						id = "neg",
						amount = -2,
						at = NOW,
					},
				},
			})
			t.expect(repaired.freeDesignUsed).toBe(false)
			t.expect(repaired.reserved).toEqual({ { id = "ok", amount = 1, at = NOW } })
		end)
	end)

	t.describe("Paying for a new car", function()
		t.it("spends the reservation when a design comes back", function()
			local wallet = credits(5)
			local deps, calls = fakeDeps({ status = "ok", spec = backendDesign() })
			local outcome = designRequest(wallet, PRICES.newCar, deps, DESIGN_INPUT, "r")
			t.expect(outcome and outcome.status).toBe("ok")
			t.expect(wallet.balance).toBe(5 - PRICES.newCar)
			t.expect(#wallet.reserved).toBe(0)
			t.expect(#calls).toBe(1)
		end)

		t.it("uses the free car on success, exactly once", function()
			local wallet = credits(0)
			local deps = fakeDeps({ status = "ok", spec = backendDesign() })
			local outcome = designRequest(wallet, 0, deps, DESIGN_INPUT, Ledger.freeId("free"))
			t.expect(outcome and outcome.status).toBe("ok")
			t.expect(wallet.freeDesignUsed).toBe(true)
			local _, reserved = designRequest(wallet, 0, deps, DESIGN_INPUT, Ledger.freeId("free2"))
			t.expect(reserved).toBe(false)
		end)

		local failures: { { label: string, reply: Reply, status: DesignerService.Status } } = {
			{
				label = "a refusal",
				reply = { status = "refused", refusal = "Let's keep it friendly. Try another idea!" },
				status = "refused",
			},
			{ label = "the backend's limits", reply = { status = "limited" }, status = "limited" },
			{ label = "an error", reply = { status = "error" }, status = "error" },
			{ label = "a timeout", reply = { status = "timeout" }, status = "timeout" },
			{ label = "no backend yet", reply = { status = "closed" }, status = "closed" },
			{
				label = "a refusal inside the spec",
				reply = { status = "ok", spec = { refusal = "Not that one, sorry!" } },
				status = "refused",
			},
			{
				label = "a forged spec (a class nobody may design)",
				reply = {
					status = "ok",
					spec = (function()
						local spec = backendDesign()
						spec.class = "hypercar"
						return spec
					end)(),
				},
				status = "invalid",
			},
			{ label = "a spec that isn't one", reply = { status = "ok", spec = "fast car" }, status = "invalid" },
		}
		for _, case in failures do
			t.it(`refunds on {case.label}, the free car included`, function()
				local wallet = credits(5)
				local outcome = designRequest(wallet, PRICES.newCar, fakeDeps(case.reply), DESIGN_INPUT, "r")
				t.expect(outcome and outcome.status).toBe(case.status)
				t.expect(wallet.balance).toBe(5)
				t.expect(#wallet.reserved).toBe(0)
				t.expect(type(outcome and outcome.message) == "string" and outcome.message ~= "").toBe(true)

				local fresh = credits(0)
				designRequest(fresh, 0, fakeDeps(case.reply), DESIGN_INPUT, Ledger.freeId("free"))
				t.expect(Ledger.freeAvailable(fresh)).toBe(true)
			end)
		end

		t.it("refunds when the text filter can't be reached, before anything is sent", function()
			local wallet = credits(5)
			local deps, calls = fakeDeps({ status = "ok", spec = backendDesign() }, {
				filter = function(_text: string): string?
					return nil
				end,
			})
			local outcome = designRequest(wallet, PRICES.newCar, deps, DESIGN_INPUT, "r")
			t.expect(outcome and outcome.status).toBe("moderated")
			t.expect(wallet.balance).toBe(5)
			t.expect(#calls).toBe(0)
		end)

		t.it("refunds when too little of the prompt survives the filter, before anything is sent", function()
			local wallet = credits(5)
			local deps, calls = fakeDeps({ status = "ok", spec = backendDesign() }, {
				filter = function(text: string): string?
					return string.rep("#", #text - 3) .. "car"
				end,
			})
			local outcome = designRequest(wallet, PRICES.newCar, deps, DESIGN_INPUT, "r")
			t.expect(outcome and outcome.status).toBe("filtered")
			t.expect(wallet.balance).toBe(5)
			t.expect(#calls).toBe(0)
		end)

		t.it("refunds when the built stats would leave the class band", function()
			local wallet = credits(5)
			local deps = fakeDeps({ status = "ok", spec = backendDesign() }, {
				stats = function(spec: any, _kit: any): any
					local stats = middleStats(spec.class)
					stats.topSpeedMph = 999
					return stats
				end,
			})
			local outcome = designRequest(wallet, PRICES.newCar, deps, DESIGN_INPUT, "r")
			t.expect(outcome and outcome.status).toBe("invalid")
			t.expect(wallet.balance).toBe(5)
		end)

		t.it("refunds when the stats can't be built at all", function()
			local wallet = credits(5)
			local deps = fakeDeps({ status = "ok", spec = backendDesign() }, {
				stats = function(_spec: any, _kit: any): any
					error("no stats")
				end,
			})
			local outcome = designRequest(wallet, PRICES.newCar, deps, DESIGN_INPUT, "r")
			t.expect(outcome and outcome.status).toBe("invalid")
			t.expect(wallet.balance).toBe(5)
		end)

		t.it("shows the designer's refusal (filtered) and says nothing was charged", function()
			local refusal = "Let's keep it friendly. Try another idea!"
			local outcome = designRequest(
				credits(5),
				PRICES.newCar,
				fakeDeps({ status = "refused", refusal = refusal }),
				DESIGN_INPUT,
				"r"
			)
			t.expect(outcome and outcome.message).toBe(refusal .. Designer.messages.refusedSuffix)
			-- Words the filter changes are never shown: the plain message stands in.
			local censored = designRequest(
				credits(5),
				PRICES.newCar,
				fakeDeps({ status = "refused", refusal = refusal }, {
					filter = function(text: string): string?
						return if text == refusal then "####" else text
					end,
				}),
				DESIGN_INPUT,
				"r"
			)
			t.expect(censored and censored.message).toBe(Designer.messages.refused)
		end)
	end)

	t.describe("Re-rolls", function()
		t.it("come free once with a paid design, then cost a new design", function()
			t.expect(DesignerService.rerollsFor(false)).toBe(PRICES.rerollsPaid)
			t.expect(PRICES.rerollsPaid).toBe(1)
			t.expect(DesignerService.rerollsFor(true)).toBe(PRICES.rerollsFree)
			t.expect(DesignerService.rerollCost(1)).toBe(0)
			t.expect(DesignerService.rerollCost(0)).toBe(PRICES.newCar)

			-- A paid design and its free re-roll cost the price of one design.
			local wallet = credits(10)
			local deps, calls = fakeDeps({ status = "ok", spec = backendDesign() })
			t.expect(Ledger.reserve(wallet, PRICES.newCar, "design", NOW)).toBe(true)
			local rerollsLeft = DesignerService.rerollsFor(false)
			local first = DesignerService.designPipeline(deps, DESIGN_INPUT)
			t.expect(first.status).toBe("ok")
			t.expect(DesignerService.rerollCost(rerollsLeft)).toBe(0)
			rerollsLeft -= 1
			local again = DesignerService.designPipeline(
				deps,
				{ prompt = first.prompt or "", classId = "sedan", filtered = true, reroll = true }
			)
			t.expect(again.status).toBe("ok")
			Ledger.spend(wallet, "design")
			t.expect(wallet.balance).toBe(10 - PRICES.newCar)
			-- The re-roll sends the already-filtered prompt and says it's a re-roll.
			t.expect(calls[2].body.prompt).toBe(first.prompt)
			t.expect(calls[2].body.reroll).toBe(true)
			-- The next re-roll is a new paid design.
			t.expect(DesignerService.rerollCost(rerollsLeft)).toBe(PRICES.newCar)
		end)
	end)

	t.describe("What leaves Roblox", function()
		t.it("is only the filtered prompt, the class, the player hash and the kit version", function()
			local deps, calls = fakeDeps({ status = "ok", spec = backendDesign() }, {
				filter = function(text: string): string?
					return (string.gsub(text, "beach", "#####"))
				end,
				hash = "f00d",
			})
			DesignerService.designPipeline(deps, DESIGN_INPUT)
			local body = calls[1].body
			local keys = {}
			for key in body do
				table.insert(keys, key)
			end
			table.sort(keys)
			t.expect(keys).toEqual({ "classId", "kitVersion", "prompt", "userHash" })
			t.expect(body.prompt).toBe("a cheerful little runabout for the #####")
			t.expect(body.userHash).toBe("f00d")
			t.expect(body.kitVersion).toBe(kit.kitVersion)
			t.expect(calls[1].path).toBe(Designer.paths.design)
		end)

		t.it("leaves the class out for surprise me", function()
			local deps, calls = fakeDeps({ status = "ok", spec = backendDesign() })
			DesignerService.designPipeline(deps, { prompt = DESIGN_INPUT.prompt })
			t.expect(calls[1].body.classId).toBe(nil)
		end)
	end)

	t.describe("Design results", function()
		t.it("keep the class the player asked for", function()
			local deps = fakeDeps({ status = "ok", spec = backendDesign("suv") })
			local outcome = DesignerService.designPipeline(deps, DESIGN_INPUT)
			t.expect(outcome.status).toBe("ok")
			local spec = outcome.spec :: any
			t.expect(spec.class).toBe("sedan")
			t.expect(table.find(kit.classes.sedan.templates, spec.body.template) ~= nil).toBe(true)
		end)

		t.it("move a surprise into a class the player may design", function()
			local deps = fakeDeps({ status = "ok", spec = backendDesign("sports") }, { canDesign = false })
			local outcome = DesignerService.designPipeline(deps, { prompt = DESIGN_INPUT.prompt })
			t.expect(outcome.status).toBe("ok")
			t.expect((outcome.spec :: any).class).toBe("economy")
		end)

		-- The backend checks brand names too, but it isn't trusted (CLAUDE.md hard rule 11).
		t.it("replace a name, tagline or mesh prompt that names a real brand", function()
			local brand = BrandNames.phrases()[2]
			local spec = backendDesign()
			spec.name = `{string.upper(brand)} Junior`
			spec.tagline = `faster than a {brand}`
			spec.meshPrompt = `a coupe with a {brand}-style hood`
			local outcome = DesignerService.designPipeline(fakeDeps({ status = "ok", spec = spec }), DESIGN_INPUT)
			t.expect(outcome.status).toBe("ok")
			local built = outcome.spec :: any
			t.expect(built.name).toBe(string.format(Designer.messages.fallbackName, Classes.sedan.displayName))
			t.expect(built.tagline).toBe("")
			t.expect(built.meshPrompt).toBe("") -- no generated look from a prompt that names a brand
		end)

		t.it("never show a refusal that names a real brand", function()
			local refusal = `We can't make a {BrandNames.phrases()[3]}, sorry!`
			local outcome =
				DesignerService.designPipeline(fakeDeps({ status = "refused", refusal = refusal }), DESIGN_INPUT)
			t.expect(outcome.status).toBe("refused")
			t.expect(outcome.message).toBe(Designer.messages.refused)
		end)

		t.it("replace a name or tagline the filter changes", function()
			local deps = fakeDeps({ status = "ok", spec = backendDesign() }, {
				filter = function(text: string): string?
					return if text == "Dune Hopper" or text == "A cheerful little runabout" then "####" else text
				end,
			})
			local outcome = DesignerService.designPipeline(deps, DESIGN_INPUT)
			t.expect(outcome.status).toBe("ok")
			local spec = outcome.spec :: any
			t.expect(spec.name).toBe(string.format(Designer.messages.fallbackName, Classes.sedan.displayName))
			t.expect(spec.tagline).toBe("")
		end)
	end)

	t.describe("Paying for a mod", function()
		t.it("spends one credit on success", function()
			local wallet = credits(3)
			local outcome = modRequest(wallet, fakeDeps({ status = "ok", spec = backendMod() }), "catalog", "m")
			t.expect(outcome.status).toBe("ok")
			t.expect(wallet.balance).toBe(3 - PRICES.mod)
			t.expect(outcome.mod ~= nil).toBe(true)
		end)

		t.it("refunds a mod that changes nothing", function()
			local wallet = credits(3)
			local empty = Validate.keepMod(kit) :: any
			empty.summary = "Nothing to do"
			local outcome = modRequest(wallet, fakeDeps({ status = "ok", spec = empty }), "kit", "m")
			t.expect(outcome.status).toBe("empty")
			t.expect(wallet.balance).toBe(3)
		end)

		-- What the backend really sends when nothing the game builds was asked for: every field kept, an empty
		-- extras list ("mount nothing new") and an accessory or a template the game never builds.
		t.it("refunds a backend-shaped mod with nothing the game can build", function()
			for _, kind in { "kit", "catalog" } do
				local wallet = credits(3)
				local mod = backendMod()
				mod.parts.wheels = KEEP
				mod.paint.primary = KEEP
				mod.stance.rideHeight = { change = false, value = 0 }
				mod.extras = {}
				mod.accessoryPrompt = "a surfboard on the roof"
				mod.body.template = "pickup"
				local outcome = modRequest(wallet, fakeDeps({ status = "ok", spec = mod }), kind :: any, "m")
				t.expect({ kind = kind, status = outcome.status }).toEqual({ kind = kind, status = "empty" })
				t.expect(wallet.balance).toBe(3)
			end
		end)

		t.it("replaces a summary that names a real brand", function()
			local mod = backendMod()
			mod.summary = `Paint like a {BrandNames.phrases()[4]}`
			local outcome = modRequest(credits(3), fakeDeps({ status = "ok", spec = mod }), "catalog", "m")
			t.expect(outcome.status).toBe("ok")
			t.expect((outcome.mod :: any).summary).toBe(Designer.messages.fallbackSummary)
		end)

		local failures: { { label: string, reply: Reply, status: DesignerService.Status } } = {
			{ label = "a refusal", reply = { status = "refused", refusal = "Not that one!" }, status = "refused" },
			{ label = "an error", reply = { status = "error" }, status = "error" },
			{ label = "a timeout", reply = { status = "timeout" }, status = "timeout" },
			{
				label = "a forged mod (an unknown part)",
				reply = {
					status = "ok",
					spec = (function()
						local mod = backendMod()
						mod.parts.wheels = "spinners"
						return mod
					end)(),
				},
				status = "invalid",
			},
		}
		for _, case in failures do
			t.it(`refunds on {case.label}`, function()
				local wallet = credits(3)
				local outcome = modRequest(wallet, fakeDeps(case.reply), "catalog", "m")
				t.expect(outcome.status).toBe(case.status)
				t.expect(wallet.balance).toBe(3)
				t.expect(#wallet.reserved).toBe(0)
			end)
		end

		t.it("replaces a summary the filter changes", function()
			local deps = fakeDeps({ status = "ok", spec = backendMod() }, {
				filter = function(text: string): string?
					return if text == "Desert tan with trail wheels" then "Desert ### with trail wheels" else text
				end,
			})
			local outcome = modRequest(credits(3), deps, "catalog", "m")
			t.expect(outcome.status).toBe("ok")
			t.expect((outcome.mod :: any).summary).toBe(Designer.messages.fallbackSummary)
		end)
	end)

	t.describe("Backend answers", function()
		t.it("are read by the backend contract", function()
			local function respond(code: number, body: any): Reply
				return DesignerService.interpretResponse({
					StatusCode = code,
					Body = if type(body) == "string" then body else game:GetService("HttpService"):JSONEncode(body),
				})
			end
			local ok = respond(200, { ok = true, spec = { name = "x" }, cached = true })
			t.expect(ok.status).toBe("ok")
			t.expect(ok.cached).toBe(true)
			t.expect(ok.spec).toEqual({ name = "x" })
			t.expect(respond(200, { ok = false, refusal = "No thanks" })).toEqual({
				status = "refused",
				refusal = "No thanks",
			})
			t.expect(respond(429, { ok = false, refusal = "Busy today" })).toEqual({
				status = "limited",
				refusal = "Busy today",
			})
			t.expect(respond(429, "not json").status).toBe("limited")
			t.expect(respond(401, { ok = false }).status).toBe("error")
			t.expect(respond(500, { ok = true, spec = {} }).status).toBe("error")
			t.expect(respond(200, "not json").status).toBe("error")
			t.expect(respond(200, { ok = true }).status).toBe("error")
			t.expect(DesignerService.interpretResponse(nil).status).toBe("error")
		end)

		t.it("every status has a message, and only ok holds the credits", function()
			for _, status in
				{
					"ok",
					"refused",
					"limited",
					"error",
					"timeout",
					"closed",
					"moderated",
					"filtered",
					"invalid",
					"empty",
				}
			do
				local message = DesignerService.messageFor(status :: any)
				t.expect(type(message) == "string" and message ~= "").toBe(true)
				t.expect(DesignerService.settles(status :: any)).toBe(if status == "ok" then "hold" else "refund")
			end
		end)
	end)

	t.describe("The Studio fake backend", function()
		t.it("answers a valid design for every designable class", function()
			local problems: { string } = {}
			for classId in kit.classes do
				local reply = DesignerService.fakeReply(Designer.paths.design, { prompt = "x", classId = classId }, kit)
				local spec, reasons = Validate.design(reply.spec, kit)
				if reply.status ~= "ok" or spec == nil then
					table.insert(problems, `{classId}: {table.concat(reasons, "; ")}`)
				elseif spec.class ~= classId then
					table.insert(problems, `{classId}: came back as {spec.class}`)
				end
			end
			t.expect(problems).toEqual({})
		end)

		t.it("answers a valid mod that changes something, on either kind of car", function()
			for _, kind in { "kit", "catalog" } do
				local reply = DesignerService.fakeReply(Designer.paths.mod, { prompt = "x" }, kit)
				local mod = Validate.mod(reply.spec, kit, kind :: any)
				t.expect(mod ~= nil).toBe(true)
				t.expect(mod ~= nil and Validate.isEmptyMod(mod, kit)).toBe(false)
			end
		end)

		t.it("answers an empty mod, the backend's way, for the empty test prompt", function()
			local reply =
				DesignerService.fakeReply(Designer.paths.mod, { prompt = Designer.devFake.triggers.empty }, kit)
			for _, kind in { "kit", "catalog" } do
				local mod = Validate.mod(reply.spec, kit, kind :: any)
				t.expect(mod ~= nil and Validate.isEmptyMod(mod, kit)).toBe(true)
			end
		end)

		t.it("fails on purpose for the test prompts", function()
			local triggers = Designer.devFake.triggers
			t.expect(DesignerService.fakeReply(Designer.paths.design, { prompt = triggers.refuse }, kit).status)
				.toBe("refused")
			t.expect(DesignerService.fakeReply(Designer.paths.design, { prompt = triggers.error }, kit).status)
				.toBe("error")
			t.expect(DesignerService.fakeReply(Designer.paths.mod, { prompt = triggers.timeout }, kit).status)
				.toBe("timeout")
		end)
	end)

	t.describe("Class rules", function()
		t.it("let anyone design the kit's classes up to tier 3", function()
			for classId in kit.classes do
				local ok = DesignerService.canDesign({ vehicles = {} }, classId, kit)
				t.expect({ classId = classId, ok = ok }).toEqual({
					classId = classId,
					ok = kit.classes[classId].requiresOwnedClass == nil,
				})
			end
		end)

		t.it("need an owned exotic for an exotic", function()
			local ok, code = DesignerService.canDesign({ vehicles = {} }, "exotic", kit)
			t.expect(ok).toBe(false)
			t.expect(code).toBe("classLocked")
			local exotic = catalogVehicleOfClass("exotic")
			t.expect(exotic ~= nil).toBe(true)
			t.expect((DesignerService.canDesign({ vehicles = { { vehicleId = exotic } } }, "exotic", kit))).toBe(true)
		end)

		t.it("never allow hypercar, heavy, service or unknown classes", function()
			for _, classId in { "hypercar", "heavy", "service", "spaceship", 7 } do
				local ok, code = DesignerService.canDesign({ vehicles = {} }, classId, kit)
				t.expect(ok).toBe(false)
				t.expect(code).toBe("unknownClass")
			end
		end)
	end)
end
