--!strict
-- The AI Car Designer's client screens (docs/phase-11-contracts.md "Client"): the prompt box's character counter
-- and limit (UI/Designer/DesignerModel), what a request costs in plain words ("Free" for the first car, "This uses
-- 2 credits"), the AI notice gate before the first request, the phone app's unlock, the class picker (exotic only
-- for owners, "Surprise me" last), Config/Designer's prices, notice and report reasons read defensively, the
-- profile's designer part (ProfileController.normalizeDesigner), DesignResult checks and the result card's words,
-- touch targets and contrast (UI/Designer/DesignerStyle), and the preview camera's fit. Pure logic on fixtures:
-- runs in Edit mode and never touches module state or the network.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Types = require(ReplicatedStorage.Shared.Types)

local Client = StarterPlayer.StarterPlayerScripts.Client
local ProfileController = require(Client.Controllers.ProfileController)
local Theme = require(Client.UI.Theme)
local DesignerModel = require(Client.UI.Designer.DesignerModel)
local DesignerStyle = require(Client.UI.Designer.DesignerStyle)
local Preview = require(Client.UI.Designer.Preview)
local ShopStyle = require(Client.UI.Shop.Style)
local StudioSheet = require(Client.UI.Designer.StudioSheet)

local MIN_TARGET = 44
local MIN_CONTRAST = 4.5

local PRICES: DesignerModel.Prices = { newCar = 2, mod = 1, rerollsPaid = 1, rerollsFree = 0 }

local copy = DesignerStyle.copy

-- The designer part of a snapshot with this balance and free-car state (and anything else in `extra`).
local function designer(balance: number, freeUsed: boolean, extra: { [string]: any }?): ProfileController.Designer
	local payload: { [string]: any } = { cash = 0, credits = { balance = balance, freeDesignUsed = freeUsed } }
	local more: { [string]: any } = extra or {}
	for key, value in more do
		payload[key] = value
	end
	return ProfileController.normalizeDesigner(payload)
end

local function car(uid: string, vehicleId: string, trim: string): Types.SnapshotVehicle
	return {
		uid = uid,
		vehicleId = vehicleId,
		trim = trim,
		favorite = false,
		paid = 0,
		paint = "white",
		finish = "gloss",
		wheels = "stock",
		acquiredAt = 0,
	}
end

local function spec(): { [string]: any }
	return {
		refusal = nil,
		name = "Mint Trekker",
		tagline = "Small, tough and always up for a muddy road",
		class = "offroad",
		energy = "battery",
		personality = "torquey",
		meshPrompt = "a compact boxy off-roader",
		body = { template = "offroad", length = 0.5, height = 0.5, roofline = 0.5, noseSlope = 0.3, flare = 0.6 },
		parts = { frontBumper = "rugged", rearBumper = "rugged", spoiler = "none", lights = "round", wheels = "trail" },
		paint = { primary = "#7FD8BE", secondary = "#202020", finish = "matte", stripe = "none" },
		stance = { rideHeight = 0.4, wheelSize = 0.7 },
	}
end

-- WCAG relative luminance and contrast ratio.
local function luminance(color: Color3): number
	local function channel(value: number): number
		return if value <= 0.03928 then value / 12.92 else ((value + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * channel(color.R) + 0.7152 * channel(color.G) + 0.0722 * channel(color.B)
end

local function contrast(a: Color3, b: Color3): number
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

return function(t: Harness.Api)
	t.describe("Designer prompt box", function()
		t.it("counts characters, not bytes", function()
			t.expect(DesignerModel.charCount("mint green")).toBe(10)
			t.expect(DesignerModel.charCount("café")).toBe(4) -- é is two bytes
			t.expect(DesignerModel.counterText("mint green", 200)).toBe("10/200")
		end)

		t.it("uses the kit's 200-character limits", function()
			t.expect(DesignerModel.promptLimit("design")).toBe(DesignerModel.kit.limits.promptChars)
			t.expect(DesignerModel.promptLimit("mod")).toBe(DesignerModel.kit.limits.modPromptChars)
			t.expect(DesignerModel.promptLimit("design")).toBe(200)
		end)

		t.it("cuts long text at the limit on a character boundary", function()
			local long = string.rep("é", 250)
			local cut = DesignerModel.clampPrompt(long, 200)
			t.expect(DesignerModel.charCount(cut)).toBe(200)
			t.expect(utf8.len(cut) ~= nil).toBe(true)
			t.expect(DesignerModel.clampPrompt("short", 200)).toBe("short")
		end)

		t.it("turns newlines and tabs into spaces", function()
			t.expect(DesignerModel.clampPrompt("red\nfast\tcar", 200)).toBe("red fast car")
		end)

		t.it("sends trimmed text with single spaces", function()
			t.expect(DesignerModel.cleanPrompt("   a   tough    truck  ")).toBe("a tough truck")
		end)

		t.it("refuses an empty or too-short prompt before sending", function()
			t.expect(DesignerModel.promptProblem("   ", "design")).toBe(copy.emptyPrompt)
			t.expect(DesignerModel.promptProblem("", "mod")).toBe(copy.emptyModPrompt)
			t.expect(DesignerModel.promptProblem("red", "design")).toBe(copy.shortPrompt)
			t.expect(DesignerModel.promptProblem("a tough little off-roader", "design")).toBe(nil)
		end)
	end)

	t.describe("Designer cost", function()
		t.it("makes the first new car free", function()
			local fresh = designer(0, false)
			t.expect(DesignerModel.costOf("design", fresh, PRICES)).toBe(0)
			t.expect(DesignerModel.costLabel("design", fresh, PRICES)).toBe(copy.free)
			t.expect(DesignerModel.costSentence("design", fresh, PRICES)).toBe(copy.firstFree)
			t.expect(DesignerModel.canAfford("design", fresh, PRICES)).toBe(true)
		end)

		t.it("charges the new-car price once the free car is used", function()
			local used = designer(5, true)
			t.expect(DesignerModel.costOf("design", used, PRICES)).toBe(2)
			t.expect(DesignerModel.costLabel("design", used, PRICES)).toBe("2 credits")
			t.expect(DesignerModel.costSentence("design", used, PRICES)).toBe("This uses 2 credits.")
		end)

		t.it("says one credit for a mod, even with the free car unused", function()
			local fresh = designer(0, false)
			t.expect(DesignerModel.costOf("mod", fresh, PRICES)).toBe(1)
			t.expect(DesignerModel.costLabel("mod", fresh, PRICES)).toBe("1 credit")
			t.expect(DesignerModel.costSentence("mod", fresh, PRICES)).toBe("This uses 1 credit.")
			t.expect(DesignerModel.canAfford("mod", fresh, PRICES)).toBe(false)
		end)

		t.it("knows how many more credits are needed", function()
			local poor = designer(1, true)
			t.expect(DesignerModel.shortBy("design", poor, PRICES)).toBe(1)
			t.expect(DesignerModel.canAfford("design", poor, PRICES)).toBe(false)
			local line, tone = DesignerModel.balanceLine("design", poor, PRICES)
			t.expect(line).toBe("You need 1 credit more.")
			t.expect(tone).toBe("warning")
			local rich = designer(7, true)
			local richLine, richTone = DesignerModel.balanceLine("design", rich, PRICES)
			t.expect(richLine).toBe("You have 7 credits.")
			t.expect(richTone).toBe("dim")
		end)

		t.it("waits for the profile before saying anything about credits", function()
			local line = DesignerModel.balanceLine("design", nil, PRICES)
			t.expect(line).toBe(copy.checking)
			t.expect(DesignerModel.canAfford("design", nil, PRICES)).toBe(true) -- the server checks anyway
		end)

		t.it("reads Config/Designer's prices, falling back to the plan's", function()
			local read = DesignerModel.prices({ prices = { newCar = 3, mod = 2, rerollsPaid = 2, rerollsFree = 1 } })
			t.expect(read).toEqual({ newCar = 3, mod = 2, rerollsPaid = 2, rerollsFree = 1 })
			local other = DesignerModel.prices({ newCarCredits = 4, modCredits = 1 })
			t.expect(other.newCar).toBe(4)
			t.expect(other.mod).toBe(1)
			t.expect(DesignerModel.prices({})).toEqual(DesignerStyle.fallbackPrices)
			local broken = DesignerModel.prices({ prices = { newCar = -1, mod = "x" } })
			t.expect(broken).toEqual(DesignerStyle.fallbackPrices)
		end)

		t.it("gives a paid design one free re-roll and the free car none", function()
			t.expect(DesignerModel.rerollFree(true, 0, PRICES)).toBe(true)
			t.expect(DesignerModel.rerollFree(true, 1, PRICES)).toBe(false)
			t.expect(DesignerModel.rerollFree(false, 0, PRICES)).toBe(false)
		end)
	end)

	t.describe("Designer gates", function()
		t.it("shows the AI notice before the first request", function()
			t.expect(DesignerModel.disclosureNeeded(false, designer(0, false))).toBe(true)
			t.expect(DesignerModel.disclosureNeeded(false, nil)).toBe(true)
		end)

		t.it("doesn't show it again once acknowledged or after any request", function()
			t.expect(DesignerModel.disclosureNeeded(true, designer(0, false))).toBe(false)
			t.expect(DesignerModel.disclosureNeeded(false, designer(0, true))).toBe(false)
			local withMod = designer(0, false, {
				vehicles = { { uid = "car1", vehicleId = "ohm_spark", trim = "standard", modded = true } },
			})
			t.expect(DesignerModel.disclosureNeeded(false, withMod)).toBe(false)
		end)

		t.it("unlocks the phone app after a studio visit or any use", function()
			t.expect(DesignerModel.unlocked(false, designer(0, false))).toBe(false)
			t.expect(DesignerModel.unlocked(true, designer(0, false))).toBe(true)
			t.expect(DesignerModel.unlocked(false, designer(0, true))).toBe(true)
		end)

		t.it("uses Config/Designer's notice text when it has one", function()
			t.expect(DesignerModel.disclosureText({ disclosure = "An AI makes these." })).toBe("An AI makes these.")
			t.expect(DesignerModel.disclosureText({})).toBe(copy.disclosureBody)
			t.expect(string.find(copy.disclosureLead, "AI", 1, true) ~= nil).toBe(true)
		end)
	end)

	t.describe("Designer class picker", function()
		t.it("lists designable kit classes by tier and ends with Surprise me", function()
			local options = DesignerModel.classOptions({})
			t.expect(options[#options].id).toBe(DesignerModel.surpriseId)
			t.expect(options[#options].label).toBe(copy.surprise)
			local lastTier = 0
			for index = 1, #options - 1 do
				local class = Classes[options[index].id]
				t.expect(class ~= nil and class.designable).toBe(true)
				t.expect(class.tier >= lastTier).toBe(true)
				lastTier = class.tier
				t.expect(options[index].id ~= "hypercar").toBe(true)
			end
		end)

		t.it("offers exotic only to owners of an exotic", function()
			local function has(options: { DesignerModel.Option }, id: string): boolean
				for _, option in options do
					if option.id == id then
						return true
					end
				end
				return false
			end
			t.expect(has(DesignerModel.classOptions({}), "exotic")).toBe(false)
			local owned = DesignerModel.ownedClasses({ car("a", "montevale_valtero", "standard") })
			t.expect(owned.exotic).toBe(true)
			t.expect(has(DesignerModel.classOptions(owned), "exotic")).toBe(true)
		end)

		t.it("sends no class for Surprise me", function()
			t.expect(DesignerModel.classIdFor(DesignerModel.surpriseId)).toBe(nil)
			t.expect(DesignerModel.classIdFor(nil)).toBe(nil)
			t.expect(DesignerModel.classIdFor("sports")).toBe("sports")
		end)
	end)

	t.describe("Designer profile part", function()
		t.it("reads credits, designs and mods from a snapshot", function()
			local part = ProfileController.normalizeDesigner({
				credits = { balance = 3.7, freeDesignUsed = true },
				designs = {
					{ uid = "d1", spec = spec(), createdAt = 10 },
					{ uid = "d2", spec = spec(), hidden = true },
					{ uid = "d3", name = "Custom Sports", hidden = true }, -- the server's plain name, no spec
					{ spec = spec() }, -- no uid: left out
				} :: { any },
				vehicles = {
					{ uid = "car1", vehicleId = "custom", trim = "design", designUid = "d1" },
					{ uid = "car2", vehicleId = "ohm_spark", trim = "standard", mods = { summary = "Lifted" } },
				} :: { any },
			})
			t.expect(part.balance).toBe(3)
			t.expect(part.freeDesignUsed).toBe(true)
			t.expect(part.designCount).toBe(3)
			t.expect(part.designs.d1.name).toBe("Mint Trekker")
			t.expect(part.designs.d1.tagline).toBe(spec().tagline)
			t.expect(part.designs.d2.name).toBe(nil) -- hidden, and the server sent no plain name: none shown
			t.expect(part.designs.d2.tagline).toBe(nil)
			t.expect(part.designs.d3.name).toBe("Custom Sports")
			t.expect(part.designs.d3.spec).toBe(nil)
			t.expect(part.vehicleDesigns.car1).toBe("d1")
			t.expect(part.mods.car2.summary).toBe("Lifted")
		end)

		t.it("gives safe defaults for a snapshot without designer fields", function()
			local part = ProfileController.normalizeDesigner({ cash = 100 })
			t.expect(part.balance).toBe(0)
			t.expect(part.freeDesignUsed).toBe(false)
			t.expect(part.designCount).toBe(0)
			t.expect(next(part.mods) == nil).toBe(true)
			t.expect(ProfileController.normalizeDesigner(nil).balance).toBe(0)
		end)

		t.it("accepts the map shapes too", function()
			local part = ProfileController.normalizeDesigner({
				freeDesignUsed = true,
				designs = { d9 = { spec = spec() } },
				mods = { car5 = { summary = "Desert tan" } },
			})
			t.expect(part.freeDesignUsed).toBe(true)
			t.expect(part.designs.d9.uid).toBe("d9")
			t.expect(part.mods.car5.summary).toBe("Desert tan")
		end)

		t.it("names cars and decides who gets Report", function()
			local part = ProfileController.normalizeDesigner({
				designs = { { uid = "d1", spec = spec() } },
				vehicles = {
					{ uid = "car1", vehicleId = "custom", trim = "design", designUid = "d1" },
					{ uid = "car2", vehicleId = "ohm_spark", trim = "standard", modded = true },
				} :: { any },
			})
			local custom = car("car1", "custom", "design")
			local modded = car("car2", "ohm_spark", "standard")
			local plain = car("car3", "ohm_spark", "standard")
			t.expect(DesignerModel.carName(custom, part)).toBe("Mint Trekker")
			t.expect(DesignerModel.carName(car("car4", "custom", "design"), part)).toBe(copy.yourDesign)
			t.expect(DesignerModel.modKind(custom)).toBe("kit")
			t.expect(DesignerModel.modKind(plain)).toBe("catalog")
			t.expect(DesignerModel.reportable(custom, part)).toBe(true)
			t.expect(DesignerModel.reportable(modded, part)).toBe(true)
			t.expect(DesignerModel.reportable(plain, part)).toBe(false)
		end)
	end)

	t.describe("Designer results", function()
		t.it("checks a DesignResult", function()
			local ok = DesignerModel.readResult({ requestId = "r1", ok = true, message = "Done", design = spec() })
			assert(ok, "result")
			t.expect(ok.ok).toBe(true)
			t.expect(ok.spec ~= nil).toBe(true)
			t.expect(DesignerModel.readResult({ ok = true, design = spec() })).toBe(nil) -- no requestId
			t.expect(DesignerModel.readResult("nope")).toBe(nil)
			local empty = DesignerModel.readResult({ requestId = "r2", ok = true })
			assert(empty, "result")
			t.expect(empty.ok).toBe(false) -- a success with nothing to show is a failure
			local refused =
				DesignerModel.readResult({ requestId = "r3", ok = false, message = "Let's keep it friendly." })
			assert(refused, "result")
			t.expect(refused.message).toBe("Let's keep it friendly.")
			t.expect(refused.rerollFree).toBe(nil)
		end)

		t.it("words the result card from the spec, cut to the kit's lengths", function()
			local card = DesignerModel.designCard(spec())
			t.expect(card.name).toBe("Mint Trekker")
			t.expect(card.specLine).toBe(Classes.offroad.displayName .. copy.separator .. copy.energy.battery)
			local long = spec()
			long.name = string.rep("x", 40)
			long.tagline = 12
			local cut = DesignerModel.designCard(long)
			t.expect(DesignerModel.charCount(cut.name)).toBe(DesignerModel.kit.limits.name)
			t.expect(cut.tagline).toBe(nil)
			t.expect(DesignerModel.designCard({}).name).toBe(copy.yourDesign)
		end)

		t.it("titles a mod by its summary", function()
			t.expect(DesignerModel.modTitle({ summary = "Lifted, desert tan" })).toBe("Lifted, desert tan")
			t.expect(DesignerModel.modTitle(nil)).toBe(copy.modDoneTitle)
		end)

		t.it("turns stats into the dealership's bars in the player's units", function()
			local stats = { topSpeedMph = 100, zeroToSixtySec = 6, handling = 0.5, energyMinutes = 40, seats = 4 }
			local rows = DesignerModel.statRows(stats, "kph")
			t.expect(#rows).toBe(5)
			t.expect(rows[1].value).toBe("161 km/h")
			for _, row in rows do
				t.expect(row.fraction >= 0 and row.fraction <= 1).toBe(true)
			end
			t.expect(#DesignerModel.statRows(nil, "mph")).toBe(0)
		end)

		t.it("reads report reasons from Config/Designer in any shape", function()
			local listed = DesignerModel.reportReasons({ reportReasons = { { id = "rude", label = "Rude" } } })
			t.expect(listed).toEqual({ { id = "rude", label = "Rude" } })
			local mapped = DesignerModel.reportReasons({ report = { reasons = { b = "Bee", a = "Ay" } } })
			t.expect(mapped[1].id).toBe("a")
			t.expect(mapped[2].label).toBe("Bee")
			t.expect(#DesignerModel.reportReasons({})).toBe(#copy.reportReasons)
			local tooLong = DesignerModel.reportReasons({ reportReasons = { string.rep("x", 60) } })
			t.expect(#tooLong).toBe(#copy.reportReasons) -- nothing usable: the defaults
		end)
	end)

	t.describe("Designer screens", function()
		t.it("keeps every touch target at least 44 px", function()
			local layout = DesignerStyle.layout
			t.expect(layout.reasonRowHeight >= MIN_TARGET).toBe(true)
			t.expect(layout.inlineButtonHeight >= MIN_TARGET).toBe(true)
			t.expect(Theme.size.buttonHeight >= MIN_TARGET).toBe(true)
			local box = 2 * layout.promptPadding + layout.promptLines * layout.promptLineHeight
			t.expect(box >= MIN_TARGET).toBe(true)
		end)

		t.it("keeps its text colors readable on the panels", function()
			local colors = Theme.colors
			for _, background in { colors.panel, colors.panelRaised } do
				t.expect(contrast(colors.text, background) >= MIN_CONTRAST).toBe(true)
				t.expect(contrast(colors.textDim, background) >= MIN_CONTRAST).toBe(true)
				t.expect(contrast(colors.warning, background) >= MIN_CONTRAST).toBe(true)
				t.expect(contrast(colors.success, background) >= MIN_CONTRAST).toBe(true)
			end
			t.expect(contrast(colors.onAccent, colors.accent) >= MIN_CONTRAST).toBe(true)
		end)

		t.it("says up front that an AI designs the cars", function()
			t.expect(string.find(copy.finePrint, "AI", 1, true) ~= nil).toBe(true)
			t.expect(string.find(copy.modFinePrint, "AI", 1, true) ~= nil).toBe(true)
			t.expect(string.find(DesignerStyle.app.body, "AI", 1, true) ~= nil).toBe(true)
		end)

		t.it("fits text columns inside the sheet", function()
			local narrow = StudioSheet.widthsFor({ mode = "sheet", width = 375, maxHeight = 600, asideWidth = 0 })
			t.expect(narrow.main).toBe(375 - 2 * ShopStyle.layout.pad)
			local wide = StudioSheet.widthsFor({ mode = "wide", width = 760, maxHeight = 350, asideWidth = 300 })
			t.expect(wide.main + wide.aside < 760).toBe(true)
			t.expect(StudioSheet.textHeight("one line", 15, 300) >= 15).toBe(true)
		end)

		t.it("stands the preview camera far enough back to fit the car", function()
			local size = Vector3.new(6, 4.6, 14) -- a sedan
			local fov = DesignerStyle.layout.previewFov
			local near = Preview.distanceFor(size, 2, fov, 0.3)
			local tall = Preview.distanceFor(size, 0.5, fov, 0.3)
			local across = math.sqrt(size.X ^ 2 + size.Z ^ 2) / 2
			t.expect(near > across).toBe(true)
			t.expect(tall > near).toBe(true) -- a narrow box needs the camera further back
		end)
	end)
end
