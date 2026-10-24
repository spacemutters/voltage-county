--!strict
-- The Wrap & Tint shop catalog (PLAN.md Phase 7; docs/phase-7-contracts.md "Wrap & Tint shop").
--
-- Everything a player can change about how an owned car looks, what each option costs in in-game $, and the
-- pure helpers the server (Services/CustomizationService), the shop UI (UI/Customize) and Vehicle/Appearance all
-- share so they always agree:
--   priceOf(changes, currentLook, vehicleClass)   what a set of changes costs (only what differs is charged)
--   check(changes, vehicleClass)                  whether every value in a change set is allowed
--   paintColor(paintId), customPaintId(hsv)       palette and custom paint ids to colors
--   normalizePlateText / isPlateTextAllowed       custom plate rules (the text is still filtered by the server)
--   standardPlateText(formatId, seed)             the free standard plate for a car
--   wornFinish, effectsOf, shopCanMake            exclusive looks: what they wear, and what the shop can't sell
--   pearlMix(now, seconds), underglowBrightness   a pearl's drift and the underglow light, for every client alike
--
-- Fair monetization (CLAUDE.md hard rule 6): prices are a money sink (PLAN.md §4), in-game $ only. Nothing here
-- is random or sold for Robux; exclusive looks (exclusiveWraps) come with Store items, the Voltage Club and the Season
-- Pass (Phase 12) and are free to put on. Each one has something the shop can't make (shopCanMake, effectsOf): a
-- chrome, brushed-metal or pearl finish, a pearl that drifts between two colors, colored glass or underglow. Every
-- option is original: no real brands, wheel makers or paint names.
--
-- Pure: no Roblox services (Color3, Vector3 and Enum are plain data types), so specs run it in Edit mode.

local Classes = require(script.Parent.Classes)
local Environment = require(script.Parent.Environment)

----------------------------------------------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------------------------------------------

-- A color as hue, saturation and value, each 0..1 (what the shop's custom color picker sends).
export type HSV = { h: number, s: number, v: number }

-- `factory`: the car's own brand color as it was built (Vehicle/Appearance puts back the color each Paint part had
-- before the first look); `color` is then only the shop swatch.
export type Paint = { id: string, displayName: string, color: Color3, factory: boolean? }

export type Finish = {
	id: string,
	displayName: string,
	material: Enum.Material, -- applied to every Paint-tagged part
	reflectance: number,
	price: number,
}

-- One stripe of a wrap. Bands are thin vinyl parts laid on the body's painted panels (Vehicle/Appearance):
--   "top"  runs along the car on upward faces (roof, deck, hood slopes). `center` is the stripe's x as a share of
--          the body's half-width (-1 left edge .. 0 middle .. 1 right edge) and `width` a share of the body width.
--   "side" runs along both flanks at a height: `center` is a share of the body height (0 bottom .. 1 top) and
--          `width` a share of the body height.
export type BandFace = "top" | "side"
export type Band = {
	face: BandFace,
	center: number,
	width: number,
	color: Color3,
	-- "top" only: a roof band. Set, it decorates only the roof: parts standing on the top of the windows (a glass
	-- roof takes it as a film). A car without glass falls back to faces at least this share of the body height up.
	minHeight: number?,
}

export type Wrap = {
	id: string,
	displayName: string,
	price: number, -- 0: free to put on (exclusive wraps: the player already has the look)
	bands: { Band },
	trimColor: Color3?, -- recolors every Trim-tagged part (bumpers, mirrors, cladding); nil keeps the car's own
	exclusive: boolean?, -- an exclusive look (exclusiveWraps): only for players who have it, never sold for cash
	-- The body color. An exclusive look paints every body in it (paint-matched extras too), with its bands on top
	-- where the body takes them. A body that takes no bands (final art: one curved painted mesh,
	-- Vehicle/Appearance.takesWraps) wears any other wrap with an artColor as a full-body color wrap. nil: the wrap
	-- can't go on such a body (wrapFitsMesh), unless it has no bands.
	artColor: Color3?,
	-- Exclusive looks only: what the shop can't make (effectsOf; tests/Customization.spec checks none of it is sold).
	finish: string?, -- an exclusiveFinishes id, worn in place of the car's own finish while the look is on
	shift: Color3?, -- a pearl: the body drifts from artColor to this color and back (Customization.pearl)
	glass: Color3?, -- the windows take this color (the car's tint level still darkens it)
	underglow: Color3?, -- a glow under the car (Customization.underglow)
	blurb: string?, -- what the look is, in a few plain words (the Wrap tab's note and the store: lookBlurb)
}

-- A wheel style: the rim parts Vehicle/Appearance builds on each tire. Diameters and lengths are shares of the
-- tire diameter, so a style fits every car's wheel size.
export type Wheel = {
	id: string,
	displayName: string,
	price: number,
	rim: number, -- rim lip diameter
	brake: number, -- brake disc (caliper color) diameter, showing between the spokes
	spokes: number, -- spoke count (0 = a solid face); even counts are built as bars through the center
	spokeLength: number, -- tip-to-tip length of two opposite spokes
	spokeWidth: number, -- spoke width
	cap: number, -- center cap diameter (a large cap covers the brake disc: an aero face)
	rimColor: Color3,
	spokeColor: Color3,
	capColor: Color3,
	material: Enum.Material,
}

export type Caliper = { id: string, displayName: string, color: Color3, price: number }

-- A kit extra's parts, in the space of its mount attachment and as shares of the extra's size for the car's
-- class. Mount space: +Y is up; -Z is the attachment's look direction (forward for Mount_Roof, Mount_Hood and
-- Mount_Spoiler; straight out of the surface for the bumper and side mounts). Blocks and wedges are axis-aligned
-- in mount space (a wedge is tall at +Z with its slope facing -Z and up); cylinders run along X.
export type ExtraColor = "paint" | "trim" | "dark" | "metal" | "lamp"
export type ExtraPiece = {
	name: string,
	shape: "block" | "wedge" | "cylinder",
	center: Vector3, -- share of the size, from the attachment
	size: Vector3, -- share of the size
	color: ExtraColor,
	light: boolean?, -- holds a disabled PointLight named Light (light shows switch it on)
	-- A foot: Vehicle/Appearance stretches it down from its top to the body under it (roofs slope), so the extra
	-- never floats. Feet reach at most extraFootReach studs.
	foot: boolean?,
}

export type Extra = {
	id: string,
	displayName: string,
	mount: string, -- Mount_* attachment on the Chassis (vehicle model contract)
	-- Extras sharing a group exclude each other (one spoiler, one roof carrier, one front piece).
	group: string?,
	classes: { string }, -- Config/Classes ids that may take it
	sizeByClass: { [string]: Vector3 }, -- studs; one entry per allowed class
	price: number,
	pieces: { ExtraPiece },
	-- Only cars of these body styles (Config/Vehicles bodyStyle) may take it; nil = any body in its classes.
	bodyStyles: { string }?,
}

-- A plate style. Standard plates are free: their text comes from `pattern` ("@" a letter, "#" a digit, anything
-- else as written), seeded by the car's uid so a car keeps its number.
export type PlateFormat = {
	id: string,
	displayName: string,
	pattern: string,
	caption: string, -- small line above the number
	background: Color3,
	text: Color3,
}

export type TintLevel = {
	value: number, -- OwnedVehicle.tint
	displayName: string,
	transparency: number, -- Glass-tagged parts
	darken: number, -- 0..1: how far the glass color moves toward black
}

-- How a car looks: the look fields of Types.OwnedVehicle (an OwnedVehicle can be passed as a Look). `plateText`
-- here is always text the server has already filtered (Vehicle/Appearance shows it as given); nil means the
-- plate format's standard text and "" a blank plate (a failed filter call).
export type Look = {
	uid: string, -- seeds the standard plate number
	paint: string,
	finish: string,
	wrap: string?,
	wheels: string,
	rideHeight: number,
	tint: number,
	caliper: string,
	extras: { string },
	plateFormat: string,
	plateText: string?,
}

-- What a shop purchase asks for (Net BuyCustomization `changes`): only the fields the player touched.
-- `customColor` replaces the palette paint with a constrained custom color.
export type Changes = {
	paint: string?,
	customColor: HSV?,
	finish: string?,
	wrap: string?,
	wheels: string?,
	rideHeight: number?,
	tint: number?,
	caliper: string?,
	extras: { string }?,
	plateFormat: string?,
}

-- One charged line of a purchase (the shop shows them; the server charges their sum).
export type PriceLine = { category: string, id: string, price: number }

----------------------------------------------------------------------------------------------------------------
-- Helpers for the tables below
----------------------------------------------------------------------------------------------------------------

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Kit extras come in three sizes; each class takes one of them.
local SIZE_GROUP: { [string]: "small" | "medium" | "large" } = {
	economy = "small",
	sedan = "small",
	sports = "small",
	muscle = "small",
	exotic = "small",
	hypercar = "small",
	luxury = "medium",
	suv = "medium",
	minivan = "medium",
	offroad = "medium",
	pickup = "medium",
	van = "large",
	service = "large",
	heavy = "large",
}

-- sizeByClass for an extra: each allowed class gets the size of its group.
local function sized(classes: { string }, small: Vector3, medium: Vector3, large: Vector3): { [string]: Vector3 }
	local byClass: { [string]: Vector3 } = {}
	for _, class in classes do
		local group = SIZE_GROUP[class]
		byClass[class] = if group == "small" then small elseif group == "medium" then medium else large
	end
	return byClass
end

local function piece(
	name: string,
	shape: "block" | "wedge" | "cylinder",
	center: Vector3,
	size: Vector3,
	color: ExtraColor,
	light: boolean?
): ExtraPiece
	return { name = name, shape = shape, center = center, size = size, color = color, light = light }
end

-- A foot block (see ExtraPiece.foot): `center` and `size` give its top; Appearance reaches it down to the body.
local function foot(name: string, center: Vector3, size: Vector3, color: ExtraColor): ExtraPiece
	return { name = name, shape = "block", center = center, size = size, color = color, foot = true }
end

local V = Vector3.new

-- Common colors.
local VINYL_WHITE = rgb(240, 240, 236)
local VINYL_BLACK = rgb(26, 26, 30)

-- Extras sized to a roof (rack, cargo pod, light bar share one footprint so they line up).
local ROOF_SMALL, ROOF_MEDIUM, ROOF_LARGE = V(3.4, 0.4, 3.0), V(3.8, 0.45, 3.4), V(4.6, 0.5, 4.0)
local POD_SMALL, POD_MEDIUM, POD_LARGE = V(2.6, 0.9, 3.0), V(3.0, 1.0, 3.4), V(3.6, 1.2, 4.0)

-- The lip sits on a trunk lid or ducktail: SUV bodies in its classes (luxury SUVs) end in a raked rear window.
local LIP_BODIES = { "sedan", "coupe", "hatch", "wagon", "muscle", "exotic", "hypercar" }
local SPOILER_CLASSES = { "economy", "sedan", "sports", "muscle", "exotic", "hypercar" }
local LIP_CLASSES = { "economy", "sedan", "sports", "muscle", "luxury", "exotic", "hypercar" }
local RACK_CLASSES = { "economy", "sedan", "minivan", "van", "suv", "pickup", "offroad", "service" }
local POD_CLASSES = { "economy", "sedan", "minivan", "van", "suv", "offroad", "luxury" }
local WORK_CLASSES = { "suv", "pickup", "offroad", "van", "service", "heavy" }
local SPLITTER_CLASSES = { "economy", "sedan", "sports", "muscle", "exotic", "hypercar" }
local DIFFUSER_CLASSES = { "sedan", "sports", "muscle", "luxury", "exotic", "hypercar" }

----------------------------------------------------------------------------------------------------------------
-- The catalog
----------------------------------------------------------------------------------------------------------------

local Customization = {
	-- Shop tabs, in order (UI/Customize). Ids are the Changes fields each tab edits.
	categories = {
		{ id = "paint", displayName = "Paint" },
		{ id = "finish", displayName = "Finish" },
		{ id = "wrap", displayName = "Wrap" },
		{ id = "wheels", displayName = "Wheels" },
		{ id = "rideHeight", displayName = "Stance" },
		{ id = "tint", displayName = "Tint" },
		{ id = "caliper", displayName = "Calipers" },
		{ id = "extras", displayName = "Extras" },
		{ id = "plateFormat", displayName = "Plate" },
	},

	-- How a car looks before anyone customizes it. paint/finish/wheels/rideHeight/tint match Config/Garage.defaults
	-- (what every OwnedVehicle already stores); caliper, extras and plateFormat are the schema v5 defaults.
	defaults = {
		paint = "factory", -- the brand's own color (schema 5 moved every pre-shop "white" here)
		finish = "gloss",
		wrap = "none",
		wheels = "stock",
		rideHeight = 0,
		tint = 0,
		caliper = "stock",
		extras = {} :: { string },
		plateFormat = "county",
	},

	-- Prices scale with the car's class tier (Config/Classes): dressing up a hypercar costs more than a hatchback.
	-- Results are rounded to the nearest `priceRounding` dollars.
	priceScaleByTier = { [1] = 1, [2] = 1.2, [3] = 1.5, [4] = 2, [5] = 3 } :: { [number]: number },
	priceRounding = 50,

	-- Any palette paint costs the same.
	paintPrice = 1500,
	-- Curated palette, in shop order. "factory" (the default) keeps each brand's own color; its swatch color is a
	-- neutral silver.
	paints = {
		{ id = "factory", displayName = "Factory", color = rgb(198, 202, 207), factory = true },
		{ id = "white", displayName = "Studio White", color = rgb(236, 236, 232) },
		{ id = "pearl_white", displayName = "Pearl White", color = rgb(246, 243, 234) },
		{ id = "silver", displayName = "Silver Mist", color = rgb(190, 194, 200) },
		{ id = "slate", displayName = "Slate Grey", color = rgb(112, 118, 126) },
		{ id = "graphite", displayName = "Graphite", color = rgb(58, 60, 66) },
		{ id = "midnight", displayName = "Midnight Black", color = rgb(22, 22, 26) },
		{ id = "cherry_red", displayName = "Cherry Red", color = rgb(170, 22, 30) },
		{ id = "sunset_orange", displayName = "Sunset Orange", color = rgb(226, 104, 36) },
		{ id = "canyon_copper", displayName = "Canyon Copper", color = rgb(160, 84, 48) },
		{ id = "prairie_gold", displayName = "Prairie Gold", color = rgb(214, 168, 52) },
		{ id = "lime_zest", displayName = "Lime Zest", color = rgb(142, 184, 58) },
		{ id = "sage", displayName = "Sage Green", color = rgb(132, 150, 120) },
		{ id = "forest", displayName = "Forest Green", color = rgb(34, 82, 52) },
		{ id = "lagoon_teal", displayName = "Lagoon Teal", color = rgb(28, 128, 132) },
		{ id = "sky_blue", displayName = "Sky Blue", color = rgb(110, 164, 216) },
		{ id = "cobalt", displayName = "Cobalt Blue", color = rgb(30, 76, 168) },
		{ id = "deep_navy", displayName = "Deep Navy", color = rgb(22, 34, 66) },
		{ id = "dusk_violet", displayName = "Dusk Violet", color = rgb(92, 60, 140) },
		{ id = "plum", displayName = "Plum", color = rgb(96, 34, 64) },
		{ id = "rose_quartz", displayName = "Rose Quartz", color = rgb(214, 150, 160) },
		{ id = "desert_sand", displayName = "Desert Sand", color = rgb(204, 180, 140) },
		{ id = "bronze", displayName = "Bronze", color = rgb(130, 98, 56) },
	} :: { Paint },

	-- A custom color the player picks. Limits keep it off pure neon (saturation cap) and off near-black panels
	-- you can't read (value floor). Hue, saturation and value are stored rounded to these steps, so the saved id
	-- is short and the server and the preview agree exactly.
	customColor = {
		price = 3000,
		minSaturation = 0,
		maxSaturation = 0.85,
		minValue = 0.15,
		maxValue = 0.95,
		hueSteps = 360, -- whole degrees
		percentSteps = 100, -- saturation and value in whole percent
		idPrefix = "custom:", -- stored paint id: "custom:<hue>,<saturation>,<value>", e.g. "custom:210,65,80"
	},

	finishes = {
		{
			id = "gloss",
			displayName = "Gloss",
			material = Enum.Material.SmoothPlastic,
			reflectance = 0.08,
			price = 1000,
		},
		{ id = "matte", displayName = "Matte", material = Enum.Material.Plastic, reflectance = 0, price = 2500 },
		{ id = "metallic", displayName = "Metallic", material = Enum.Material.Metal, reflectance = 0.25, price = 3500 },
	} :: { Finish },

	-- Finishes only exclusive looks wear (exclusiveWraps `finish`). Never sold: they aren't in `finishes`, so check
	-- refuses them, and the AI Car Designer's finishes are shop finishes (tests/Customization.spec). Each differs
	-- from every shop finish in its material or by at least finishGap in reflectance; chrome and brushed metal shine
	-- more than any shop finish.
	exclusiveFinishes = {
		{
			id = "mirror_chrome",
			displayName = "Mirror Chrome",
			material = Enum.Material.SmoothPlastic,
			reflectance = 0.55,
			price = 0,
		},
		{
			id = "brushed_metal",
			displayName = "Brushed Metal",
			material = Enum.Material.Metal,
			reflectance = 0.45,
			price = 0,
		},
		{
			id = "pearl_coat",
			displayName = "Pearl Coat",
			material = Enum.Material.SmoothPlastic,
			reflectance = 0.18,
			price = 0,
		},
	} :: { Finish },
	finishGap = 0.08,

	-- Original vinyl designs. "none" (no wrap) has a small removal fee like any other change.
	wraps = {
		{ id = "none", displayName = "No Wrap", price = 500, bands = {} },
		{
			id = "twin_stripes",
			displayName = "Twin Stripes",
			price = 2500,
			bands = {
				{ face = "top", center = -0.2, width = 0.1, color = VINYL_WHITE },
				{ face = "top", center = 0.2, width = 0.1, color = VINYL_WHITE },
			},
		},
		{
			id = "center_stripe",
			displayName = "Center Stripe",
			price = 2000,
			bands = { { face = "top", center = 0, width = 0.2, color = VINYL_BLACK } },
		},
		{
			id = "side_dash",
			displayName = "Side Dash",
			price = 1800,
			bands = { { face = "side", center = 0.45, width = 0.07, color = VINYL_WHITE } },
		},
		{
			id = "lower_split",
			displayName = "Lower Split",
			price = 3500,
			bands = { { face = "side", center = 0.14, width = 0.28, color = rgb(36, 38, 42) } },
			trimColor = rgb(36, 38, 42),
		},
		{
			id = "blackout_roof",
			displayName = "Blackout Roof",
			price = 2000,
			bands = { { face = "top", center = 0, width = 1, color = VINYL_BLACK, minHeight = 0.8 } },
		},
		{
			id = "rally",
			displayName = "Rally",
			price = 4500,
			bands = {
				{ face = "top", center = 0, width = 0.16, color = rgb(232, 112, 32) },
				{ face = "side", center = 0.32, width = 0.06, color = rgb(232, 112, 32) },
			},
			trimColor = VINYL_WHITE,
		},
		{
			id = "tricolor",
			displayName = "Tricolor Line",
			price = 3500,
			bands = {
				{ face = "side", center = 0.3, width = 0.045, color = rgb(28, 140, 150) },
				{ face = "side", center = 0.37, width = 0.045, color = VINYL_WHITE },
				{ face = "side", center = 0.44, width = 0.045, color = rgb(232, 96, 82) },
			},
		},
		{
			id = "pinstripe",
			displayName = "Pinstripe",
			price = 3000,
			bands = {
				{ face = "side", center = 0.55, width = 0.02, color = rgb(204, 164, 72) },
				{ face = "side", center = 0.6, width = 0.02, color = rgb(204, 164, 72) },
				{ face = "top", center = -0.1, width = 0.025, color = rgb(204, 164, 72) },
				{ face = "top", center = 0.1, width = 0.025, color = rgb(204, 164, 72) },
			},
		},
	} :: { Wrap },

	-- Exclusive wraps (Phase 12): looks a player gets, never buys here. The Wrap tab lists one only for a player who
	-- has it: saved in PlayerData.cosmetics (the Starter Pack, a limited cosmetic, a Season Pass reward) or, for the
	-- club's, while they are a Voltage Club member (Services/MonetizationService.ownsCosmetic; the profile
	-- snapshot's `looks`), and Services/CustomizationService refuses it to anyone else. Putting one on is free. Ids are
	-- the look ids Config/Monetization, Config/Limiteds and Config/Season grant (lookExists; tests/Monetization.spec
	-- fails when something grants a look that isn't here).
	--
	-- Every one paints the whole body in its artColor on every catalog car, art or greybox, and on player designs,
	-- and adds what no paint, finish or shop wrap can (effectsOf), each a different mix:
	--   Starter Spark    pearl coat that drifts amber to coral
	--   Voltage Club     brushed graphite metal, teal underglow
	--   Launch Week      red mirror chrome, warm white underglow (the serial-numbered limited)
	--   Lift Off         pearl coat that drifts violet to blue, lilac glass
	--   Arc Streak       brushed electric-blue metal, ice-blue glass and underglow
	--   Season One Gold  gold mirror chrome that drifts to champagne, warm gold underglow (the season's last tier)
	-- Chrome alone isn't enough for a top reward: reflections may not render on a phone's low graphics, and shop
	-- metallic in a custom gold comes close, so the higher Season looks add a drift or underglow, which show at any
	-- quality.
	-- Bodies that take bands (greybox, designs) wear its stripes on top, in colors that read on its own body color.
	exclusiveWraps = {
		{
			id = "starter_wrap", -- the Starter Pack (Config/Monetization grants.starterPack)
			displayName = "Starter Spark",
			price = 0,
			exclusive = true,
			bands = {
				{ face = "side", center = 0.38, width = 0.05, color = VINYL_WHITE },
				{ face = "side", center = 0.46, width = 0.02, color = VINYL_BLACK },
			},
			artColor = rgb(255, 190, 60),
			finish = "pearl_coat",
			shift = rgb(255, 104, 84),
			blurb = "Amber pearl that slowly shifts to coral",
		},
		{
			id = "club_wrap", -- Voltage Club members, while subscribed (Config/Monetization club.cosmetics)
			displayName = "Voltage Club",
			price = 0,
			exclusive = true,
			bands = {
				{ face = "top", center = -0.14, width = 0.06, color = rgb(40, 200, 190) },
				{ face = "top", center = 0.14, width = 0.06, color = rgb(40, 200, 190) },
				{ face = "side", center = 0.2, width = 0.03, color = rgb(40, 200, 190) },
			},
			trimColor = rgb(20, 22, 26),
			artColor = rgb(52, 56, 62),
			finish = "brushed_metal",
			underglow = rgb(40, 220, 205),
			blurb = "Brushed graphite metal with teal underglow",
		},
		{
			id = "launch_week_wrap", -- the serial-numbered launch-week limited (Config/Limiteds launch_wrap)
			displayName = "Launch Week",
			price = 0,
			exclusive = true,
			bands = {
				{ face = "top", center = 0, width = 0.16, color = VINYL_WHITE },
				{ face = "top", center = -0.22, width = 0.02, color = VINYL_BLACK },
				{ face = "top", center = 0.22, width = 0.02, color = VINYL_BLACK },
			},
			artColor = rgb(232, 72, 48),
			finish = "mirror_chrome",
			underglow = rgb(255, 236, 210),
			blurb = "Red mirror chrome with warm white underglow",
		},
		{
			id = "season1_wrap", -- Season 1 premium track (Config/Season)
			displayName = "Lift Off",
			price = 0,
			exclusive = true,
			bands = {
				{ face = "side", center = 0.25, width = 0.05, color = VINYL_WHITE },
				{ face = "side", center = 0.33, width = 0.035, color = rgb(222, 210, 255) },
				{ face = "side", center = 0.4, width = 0.02, color = rgb(196, 170, 255) },
			},
			artColor = rgb(120, 80, 220),
			finish = "pearl_coat",
			shift = rgb(60, 120, 255),
			glass = rgb(176, 150, 255),
			blurb = "Violet pearl that shifts to blue, with lilac glass",
		},
		{
			id = "season1_arc_wrap", -- Season 1 premium track (Config/Season)
			displayName = "Arc Streak",
			price = 0,
			exclusive = true,
			bands = {
				{ face = "top", center = -0.35, width = 0.08, color = VINYL_WHITE },
				{ face = "side", center = 0.5, width = 0.03, color = VINYL_WHITE },
			},
			trimColor = VINYL_WHITE,
			artColor = rgb(40, 110, 230),
			finish = "brushed_metal",
			glass = rgb(150, 210, 255),
			underglow = rgb(150, 210, 255),
			blurb = "Brushed electric-blue metal, ice-blue glass and underglow",
		},
		{
			id = "season1_finale_wrap", -- Season 1 premium track, the last tier (Config/Season)
			displayName = "Season One Gold",
			price = 0,
			exclusive = true,
			bands = {
				{ face = "top", center = 0, width = 1, color = VINYL_BLACK, minHeight = 0.8 },
				{ face = "side", center = 0.5, width = 0.02, color = VINYL_BLACK },
			},
			artColor = rgb(204, 164, 72),
			finish = "mirror_chrome",
			shift = rgb(240, 222, 176), -- champagne
			underglow = rgb(255, 196, 92),
			blurb = "Gold chrome that shifts to champagne, with gold underglow",
		},
	} :: { Wrap },

	-- Pearl looks (`shift`): Vehicle/Appearance tags every painted part (the body and paint-colored extra pieces)
	-- with `tag` and its two colors (these attributes), and Controllers/LookEffectsController drifts them on each
	-- client with Customization.pearlMix on the server clock: every client and every part agree, nothing is random.
	-- It writes `updateHz` times a second, to at most `maxParts` parts at once.
	pearl = {
		tag = "PearlShift",
		fromAttribute = "PearlFrom",
		toAttribute = "PearlTo",
		seconds = 12, -- one round trip, own color to shift color and back
		updateHz = 12,
		maxParts = 400,
	},

	-- Underglow (`underglow`): Vehicle/Appearance lays a thin Neon strip under each sill, between the front and rear
	-- tires, and hangs a PointLight under the middle of the car (tagged lightTag). The light is brighter at night:
	-- Lighting.ClockTime from nightFrom to nightUntil hours (underglowBrightness); Controllers/LookEffectsController
	-- switches it when the clock crosses dusk or dawn. Strips count toward wrapMaxParts.
	underglow = {
		stripWidth = 0.16, -- studs across
		stripThickness = 0.06, -- studs tall
		inset = 0.82, -- the strips' centers as a share of the body's half-width
		drop = 0.02, -- studs between the body's lowest point and the strips' tops
		tireGap = 0.25, -- studs kept clear of the tires, front and back
		minLength = 1, -- studs: a shorter strip (a tiny wheelbase) isn't built; the light still is
		material = Enum.Material.Neon,
		lightName = "UnderglowLight", -- the Attachment on the Chassis holding the PointLight
		lightTag = "UnderglowLight", -- CollectionService tag on the PointLight
		lightDrop = 0.35, -- studs below the body's lowest point
		range = 12, -- studs
		dayBrightness = 1.5,
		nightBrightness = 5,
		-- Lighting.ClockTime hours: the streetlights' dusk and dawn (Config/Environment dayNight), so the underglow
		-- and the streetlights can't drift apart.
		nightFrom = Environment.dayNight.duskClock,
		nightUntil = Environment.dayNight.dawnClock,
	},

	-- Wrap vinyl parts: this thick, standing this far proud of the panel, never shorter than this along the car
	-- (shorter leftovers between other parts are dropped), and at most this many per car.
	wrapThickness = 0.02,
	wrapProud = 0.005,
	wrapMinSegment = 0.3,
	wrapMaxParts = 48,
	wrapMaterial = Enum.Material.SmoothPlastic,
	-- A panel's outer face counts as a flank when it is at least this share of the body's half-width out.
	wrapSideShare = 0.8,
	-- Vinyl narrower than this (after clipping to a panel) is dropped.
	wrapMinWidth = 0.02,
	-- A part this close above (or outside) a panel face counts as covering it, so no vinyl goes under it.
	wrapCoverProbe = 0.05,
	-- A sloped panel (hood, nose, ducktail) takes top stripes when its slope faces at least this much upward
	-- (the up component of its unit normal).
	wrapSlopeMinUp = 0.3,
	-- Roof bands: a part counts as standing on the window line when its bottom is within this many studs of it.
	wrapRoofSlack = 0.1,

	-- Original wheel styles. "stock" is the default every existing car already has.
	wheels = {
		{
			id = "stock",
			displayName = "Factory",
			price = 1000,
			rim = 0.62,
			brake = 0.4,
			spokes = 2,
			spokeLength = 0.56,
			spokeWidth = 0.09,
			cap = 0.14,
			rimColor = rgb(150, 154, 160),
			spokeColor = rgb(64, 66, 72),
			capColor = rgb(64, 66, 72),
			material = Enum.Material.SmoothPlastic,
		},
		{
			id = "five_star",
			displayName = "Five Star",
			price = 2500,
			rim = 0.66,
			brake = 0.46,
			spokes = 5,
			spokeLength = 0.62,
			spokeWidth = 0.08,
			cap = 0.14,
			rimColor = rgb(196, 200, 206),
			spokeColor = rgb(196, 200, 206),
			capColor = rgb(48, 50, 56),
			material = Enum.Material.SmoothPlastic,
		},
		{
			id = "mesh",
			displayName = "Mesh Ten",
			price = 3500,
			rim = 0.66,
			brake = 0.5,
			spokes = 10,
			spokeLength = 0.62,
			spokeWidth = 0.035,
			cap = 0.12,
			rimColor = rgb(182, 150, 92),
			spokeColor = rgb(182, 150, 92),
			capColor = rgb(182, 150, 92),
			material = Enum.Material.SmoothPlastic,
		},
		{
			id = "turbine",
			displayName = "Turbine",
			price = 3000,
			rim = 0.64,
			brake = 0.42,
			spokes = 7,
			spokeLength = 0.6,
			spokeWidth = 0.06,
			cap = 0.2,
			rimColor = rgb(70, 72, 78),
			spokeColor = rgb(176, 180, 186),
			capColor = rgb(70, 72, 78),
			material = Enum.Material.SmoothPlastic,
		},
		{
			id = "deep_dish",
			displayName = "Deep Dish",
			price = 4000,
			rim = 0.7,
			brake = 0.36,
			spokes = 4,
			spokeLength = 0.44,
			spokeWidth = 0.07,
			cap = 0.12,
			rimColor = rgb(210, 214, 220),
			spokeColor = rgb(210, 214, 220),
			capColor = rgb(40, 42, 46),
			material = Enum.Material.Metal,
		},
		{
			id = "steel",
			displayName = "Steelie",
			price = 1500,
			rim = 0.6,
			brake = 0.42,
			spokes = 0,
			spokeLength = 0,
			spokeWidth = 0,
			cap = 0.3,
			rimColor = rgb(34, 34, 38),
			spokeColor = rgb(34, 34, 38),
			capColor = rgb(140, 142, 146),
			material = Enum.Material.SmoothPlastic,
		},
		{
			id = "aero",
			displayName = "Aero Disc",
			price = 2500,
			rim = 0.64,
			brake = 0.4,
			spokes = 0,
			spokeLength = 0,
			spokeWidth = 0,
			cap = 0.58,
			rimColor = rgb(64, 66, 72),
			spokeColor = rgb(64, 66, 72),
			capColor = rgb(228, 230, 232),
			material = Enum.Material.SmoothPlastic,
		},
		{
			id = "trail",
			displayName = "Trail Six",
			price = 3000,
			rim = 0.58,
			brake = 0.38,
			spokes = 6,
			spokeLength = 0.54,
			spokeWidth = 0.12,
			cap = 0.16,
			rimColor = rgb(40, 40, 44),
			spokeColor = rgb(40, 40, 44),
			capColor = rgb(150, 152, 156),
			material = Enum.Material.Plastic,
		},
	} :: { Wheel },

	-- Rim parts stand this far proud of each tire face, in layers from the tire out (studs). The brake disc sits
	-- under the spokes and the cap over everything, so an aero cap hides the disc.
	wheelLayers = { rim = 0.02, brake = 0.035, spokes = 0.05, cap = 0.065 },
	-- Art models' stock wheels are textured meshes (Vehicle/Appearance.artWheelName) with no brake disc to color, so a
	-- caliper other than the stock one shows as a disc on the hub: this share of the tire diameter, standing this far
	-- proud of the tire faces.
	artWheelCaliper = { diameter = 0.24, proud = 0.03 },

	-- Ride height: OwnedVehicle.rideHeight is -1 (lowest) .. 1 (highest) in `step`s. At -1 the body sits `lower`
	-- studs down, at 1 `raise` studs up (by class). Only the visual body moves: the chassis, the wheels' hub
	-- attachments and the suspension never change, so handling and the server's checks are the same at any stance.
	rideHeight = {
		price = 1200,
		step = 0.25,
		min = -1,
		max = 1,
		-- Lowering stops short where the lowest body part would come nearer the ground than this (studs, at rest):
		-- the body doesn't collide, so braking pitch would push a lower chin through the road
		-- (Vehicle/Appearance.bodyOffset).
		minClearance = 0.25,
		default = { lower = 0.2, raise = 0.2 },
		byClass = {
			economy = { lower = 0.2, raise = 0.25 },
			sedan = { lower = 0.25, raise = 0.25 },
			minivan = { lower = 0.15, raise = 0.25 },
			van = { lower = 0.15, raise = 0.3 },
			suv = { lower = 0.2, raise = 0.45 },
			pickup = { lower = 0.2, raise = 0.55 },
			offroad = { lower = 0.2, raise = 0.6 },
			service = { lower = 0.1, raise = 0.3 },
			sports = { lower = 0.3, raise = 0.2 },
			muscle = { lower = 0.3, raise = 0.25 },
			luxury = { lower = 0.25, raise = 0.2 },
			heavy = { lower = 0.1, raise = 0.2 },
			exotic = { lower = 0.25, raise = 0.15 },
			hypercar = { lower = 0.2, raise = 0.1 },
		} :: { [string]: { lower: number, raise: number } },
	},

	-- Window tint: OwnedVehicle.tint must be one of these values. Level 0 is the factory glass.
	tint = {
		price = 800,
		levels = {
			{ value = 0, displayName = "Factory", transparency = 0.35, darken = 0 },
			{ value = 0.25, displayName = "Light", transparency = 0.26, darken = 0.25 },
			{ value = 0.5, displayName = "Medium", transparency = 0.18, darken = 0.45 },
			{ value = 0.75, displayName = "Dark", transparency = 0.1, darken = 0.65 },
			{ value = 1, displayName = "Limo", transparency = 0.05, darken = 0.8 },
		} :: { TintLevel },
	},

	calipers = {
		{ id = "stock", displayName = "Factory Grey", color = rgb(58, 60, 64), price = 500 },
		{ id = "red", displayName = "Race Red", color = rgb(196, 40, 36), price = 900 },
		{ id = "yellow", displayName = "Signal Yellow", color = rgb(232, 190, 40), price = 900 },
		{ id = "blue", displayName = "Electric Blue", color = rgb(40, 96, 200), price = 900 },
		{ id = "green", displayName = "Track Green", color = rgb(46, 150, 80), price = 900 },
		{ id = "orange", displayName = "Ember Orange", color = rgb(232, 120, 32), price = 900 },
		{ id = "silver", displayName = "Silver", color = rgb(196, 200, 206), price = 900 },
		{ id = "black", displayName = "Black", color = rgb(24, 24, 26), price = 900 },
	} :: { Caliper },

	-- Kit extras on the model contract's Mount_* attachments. At most `maxExtras` on one car (Net allows 8).
	maxExtras = 6,
	-- Colors for extra pieces that aren't body-colored ("paint") or trim-colored ("trim").
	extraColors = {
		trim = rgb(40, 42, 46), -- when the wrap sets no trim color
		dark = rgb(30, 31, 34),
		metal = rgb(176, 180, 186),
		lamp = rgb(246, 244, 232),
	},
	-- Feet (ExtraPiece.foot) reach at most this many studs below their top to find the body; none found, they
	-- keep their own size.
	extraFootReach = 1,
	-- The PointLight a "light" piece holds (off until a light show or the player switches it on).
	extraLight = { color = rgb(255, 248, 232), brightness = 3, range = 24 },
	extras = {
		{
			id = "lip_spoiler",
			displayName = "Ducktail Lip",
			mount = "Mount_Spoiler",
			group = "spoiler",
			classes = LIP_CLASSES,
			sizeByClass = sized(LIP_CLASSES, V(4.8, 0.3, 0.7), V(5.2, 0.32, 0.75), V(5.6, 0.35, 0.8)),
			bodyStyles = LIP_BODIES,
			price = 1500,
			pieces = { piece("Lip", "wedge", V(0, 0.5, 0), V(1, 1, 1), "paint") },
		},
		{
			id = "wing_spoiler",
			displayName = "Track Wing",
			mount = "Mount_Spoiler",
			group = "spoiler",
			classes = SPOILER_CLASSES,
			sizeByClass = sized(SPOILER_CLASSES, V(4.6, 0.9, 0.9), V(5.0, 1.0, 1.0), V(5.4, 1.1, 1.1)),
			price = 3500,
			pieces = {
				piece("StandL", "block", V(-0.34, 0.37, 0.1), V(0.04, 0.74, 0.35), "dark"),
				piece("StandR", "block", V(0.34, 0.37, 0.1), V(0.04, 0.74, 0.35), "dark"),
				piece("Blade", "block", V(0, 0.8, 0.15), V(1, 0.12, 0.7), "paint"),
				piece("EndplateL", "block", V(-0.51, 0.78, 0.15), V(0.02, 0.44, 0.76), "trim"),
				piece("EndplateR", "block", V(0.51, 0.78, 0.15), V(0.02, 0.44, 0.76), "trim"),
			},
		},
		{
			id = "roof_rack",
			displayName = "Roof Rack",
			mount = "Mount_Roof",
			group = "roofCargo",
			classes = RACK_CLASSES,
			sizeByClass = sized(RACK_CLASSES, ROOF_SMALL, ROOF_MEDIUM, ROOF_LARGE),
			price = 2000,
			pieces = {
				piece("RailL", "block", V(-0.45, 0.3, 0.05), V(0.04, 0.6, 0.8), "dark"),
				piece("RailR", "block", V(0.45, 0.3, 0.05), V(0.04, 0.6, 0.8), "dark"),
				piece("BarFront", "block", V(0, 0.75, -0.25), V(0.96, 0.3, 0.05), "dark"),
				piece("BarMid", "block", V(0, 0.75, 0.05), V(0.96, 0.3, 0.05), "dark"),
				piece("BarRear", "block", V(0, 0.75, 0.35), V(0.96, 0.3, 0.05), "dark"),
				-- Feet under the rail ends, reaching down to the roof (it may slope away under the rails).
				foot("FootFL", V(-0.45, 0.05, -0.3), V(0.06, 0.1, 0.06), "dark"),
				foot("FootFR", V(0.45, 0.05, -0.3), V(0.06, 0.1, 0.06), "dark"),
				foot("FootRL", V(-0.45, 0.05, 0.4), V(0.06, 0.1, 0.06), "dark"),
				foot("FootRR", V(0.45, 0.05, 0.4), V(0.06, 0.1, 0.06), "dark"),
			},
		},
		{
			id = "roof_box",
			displayName = "Cargo Pod",
			mount = "Mount_Roof",
			group = "roofCargo",
			classes = POD_CLASSES,
			sizeByClass = sized(POD_CLASSES, POD_SMALL, POD_MEDIUM, POD_LARGE),
			price = 2500,
			pieces = {
				piece("FootL", "block", V(-0.35, 0.05, 0.05), V(0.08, 0.1, 0.8), "dark"),
				piece("FootR", "block", V(0.35, 0.05, 0.05), V(0.08, 0.1, 0.8), "dark"),
				piece("Shell", "block", V(0, 0.5, 0.05), V(1, 0.8, 0.8), "dark"),
				piece("Nose", "wedge", V(0, 0.5, -0.375), V(1, 0.8, 0.05), "dark"),
			},
		},
		{
			id = "light_bar",
			displayName = "Light Bar",
			mount = "Mount_Roof",
			classes = WORK_CLASSES,
			sizeByClass = sized(WORK_CLASSES, ROOF_SMALL, ROOF_MEDIUM, ROOF_LARGE),
			price = 3000,
			pieces = {
				piece("Housing", "block", V(0, 0.45, -0.45), V(0.95, 0.9, 0.08), "dark"),
				piece("Glow", "block", V(0, 0.45, -0.495), V(0.9, 0.6, 0.012), "lamp", true),
				-- Stands from the housing's foot down to the roof.
				foot("StandL", V(-0.4, 0.05, -0.45), V(0.05, 0.1, 0.05), "dark"),
				foot("StandR", V(0.4, 0.05, -0.45), V(0.05, 0.1, 0.05), "dark"),
			},
		},
		{
			id = "bull_bar",
			displayName = "Bull Bar",
			mount = "Mount_FrontBumper",
			group = "front",
			classes = WORK_CLASSES,
			sizeByClass = sized(WORK_CLASSES, V(4.0, 1.4, 0.6), V(4.4, 1.6, 0.6), V(5.2, 1.9, 0.7)),
			price = 2500,
			pieces = {
				piece("UprightL", "block", V(-0.3, 0.5, -0.5), V(0.05, 1, 0.2), "metal"),
				piece("UprightR", "block", V(0.3, 0.5, -0.5), V(0.05, 1, 0.2), "metal"),
				piece("TopBar", "block", V(0, 0.96, -0.5), V(0.65, 0.08, 0.2), "metal"),
				piece("MidBar", "block", V(0, 0.55, -0.5), V(0.6, 0.06, 0.16), "metal"),
				piece("LowBar", "block", V(0, 0.08, -0.5), V(1, 0.1, 0.25), "metal"),
				-- Brackets from the bumper face (the mount) out to the uprights.
				piece("BracketL", "block", V(-0.3, 0.3, -0.22), V(0.05, 0.08, 0.45), "metal"),
				piece("BracketR", "block", V(0.3, 0.3, -0.22), V(0.05, 0.08, 0.45), "metal"),
			},
		},
		{
			id = "front_splitter",
			displayName = "Front Splitter",
			mount = "Mount_FrontBumper",
			group = "front",
			classes = SPLITTER_CLASSES,
			sizeByClass = sized(SPLITTER_CLASSES, V(5.0, 0.12, 0.7), V(5.4, 0.12, 0.75), V(5.8, 0.14, 0.8)),
			price = 2000,
			pieces = { piece("Blade", "block", V(0, -0.5, -0.2), V(1, 1, 0.8), "dark") },
		},
		{
			id = "rear_diffuser",
			displayName = "Rear Diffuser",
			mount = "Mount_RearBumper",
			classes = DIFFUSER_CLASSES,
			sizeByClass = sized(DIFFUSER_CLASSES, V(4.2, 0.5, 0.5), V(4.6, 0.55, 0.55), V(5.0, 0.6, 0.6)),
			price = 2500,
			pieces = {
				piece("Base", "block", V(0, -0.6, -0.3), V(1, 0.2, 0.6), "dark"),
				piece("Fin1", "block", V(-0.3, -0.3, -0.3), V(0.03, 0.5, 0.6), "dark"),
				piece("Fin2", "block", V(-0.1, -0.3, -0.3), V(0.03, 0.5, 0.6), "dark"),
				piece("Fin3", "block", V(0.1, -0.3, -0.3), V(0.03, 0.5, 0.6), "dark"),
				piece("Fin4", "block", V(0.3, -0.3, -0.3), V(0.03, 0.5, 0.6), "dark"),
			},
		},
	} :: { Extra },

	-- Standard plate styles: always free. Captions are made-up places in the county.
	plateFormats = {
		{
			id = "county",
			displayName = "County",
			pattern = "@@@ ####",
			caption = "VOLTAGE COUNTY",
			background = rgb(236, 238, 240),
			text = rgb(28, 52, 110),
		},
		{
			id = "classic",
			displayName = "Classic",
			pattern = "###-@@@",
			caption = "CEDAR BEND",
			background = rgb(232, 196, 64),
			text = rgb(24, 24, 24),
		},
		{
			id = "metro",
			displayName = "Metro",
			pattern = "@@ ## @@",
			caption = "METRO",
			background = rgb(24, 26, 30),
			text = rgb(236, 236, 236),
		},
		{
			id = "heritage",
			displayName = "Heritage",
			pattern = "@-#####",
			caption = "HERITAGE",
			background = rgb(34, 74, 58),
			text = rgb(238, 232, 210),
		},
	} :: { PlateFormat },

	-- Plates: custom text rules and how plates are drawn.
	plate = {
		maxLength = 8,
		minLength = 1,
		allowedPattern = "^[A-Z0-9 %-]+$", -- after normalizePlateText: capitals, digits, single spaces, dashes
		allowedDescription = "Letters, numbers, spaces and dashes, up to 8.",
		-- Standard plates draw letters without vowels (so they can't spell words) and redraw any number that
		-- contains one of these.
		standardLetters = "BCDFGHJLMNPRSTVWXZ",
		standardDigits = "0123456789",
		standardAvoid = { "WTF", "STD", "FML", "SHT", "DMN", "666", "69", "88", "420", "1488" },
		standardMaxDraws = 32,
		-- The plate part Vehicle/Appearance builds on PlateFront and PlateRear (studs) and its SurfaceGui.
		size = Vector3.new(1.3, 0.5, 0.04),
		pixelsPerStud = 100,
		captionShare = 0.24, -- share of the plate height the caption line takes
		font = Enum.Font.BuilderSansBold, -- the game's own type (UI/Theme)
		captionFont = Enum.Font.BuilderSans,
	},

	-- CollectionService tag on everything Vehicle/Appearance builds (wrap vinyl, rim parts, extras, plates), so
	-- applying a look again removes the old ones first.
	lookTag = "LookPart",

	-- The Wrap & Tint shop building and the server's replies (Services/CustomizationService). The client reads
	-- footprintSlack too (Controllers/CustomizationController), so the panel closes exactly when a purchase would
	-- be refused.
	shop = {
		tag = "CustomShop", -- MapLayout location tag (MapBuilder builds the bay and its garage door)
		displayNameAttribute = "DisplayName", -- set on every location part by MapBuilder
		-- The car's pivot (the ground point under its chassis) may be this many studs outside the bay's footprint and
		-- still count as in the shop: the server's view of a client-driven car lags and wobbles a little.
		footprintSlack = 2,
		prompt = {
			name = "CustomizePrompt",
			actionText = "Customize",
			objectText = "Wrap & Tint",
			holdSeconds = 0.3,
			-- The prompt sits at the bay's centre; it reaches a driver anywhere on the bay plus this many studs.
			reachMargin = 8,
		},
		passId = "customPlates", -- MonetizationService.hasPass id for custom plate text (Phase 12)
		economyReason = "customize", -- EconomyService reason for the money sink (Config/Economy analytics)
		messages = {
			notLoaded = "Your garage is still loading. Try again in a moment.",
			noCar = "Drive one of your cars into the shop first.",
			testDrive = "Test-drive cars can't be customized. Buy it first!",
			notOwned = "Only cars from your garage can be customized.",
			notDriving = "Sit in the driver's seat to customize your car.",
			notInShop = "Park inside the shop's bay to customize your car.",
			wrongCar = "That's not the car you're sitting in.",
			cantAfford = "You need %s for that.", -- the price
			bought = "Your car's new look is on! (%s)", -- the price
			boughtFree = "Your car's new look is on!",
			saveFailed = "Couldn't save that. Try again in a moment.",
			plateNeedsPass = "Custom plate text needs the Custom Plates pass.",
			plateFilterFailed = "Couldn't check that text right now. Try again in a moment.",
			plateNotAllowed = "That plate text isn't allowed. Try something else.",
			plateSet = "Your new plate is on!",
			plateCleared = "Back to your standard plate.",
			plateUnchanged = "That's already on your plate.",
		},
	},

	-- Refusals the server shows the player. Plain words.
	messages = {
		unknownPaint = "That paint isn't in the shop.",
		customColorLimit = "That color is too bright or too dark. Pick a softer shade.",
		paintAndCustom = "Pick a palette paint or a custom color, not both.",
		unknownFinish = "That finish isn't in the shop.",
		unknownWrap = "That wrap isn't in the shop.",
		lockedWrap = "That's an exclusive wrap you don't have.",
		wrapDoesntFit = "Stripes don't fit this car's body. Pick a paint color instead.",
		unknownWheels = "Those wheels aren't in the shop.",
		badRideHeight = "That ride height isn't available.",
		badTint = "That tint level isn't available.",
		unknownCaliper = "That caliper color isn't in the shop.",
		unknownExtra = "That extra isn't in the shop.",
		extraNotForClass = "That extra doesn't fit this car.",
		extraTwice = "That extra is already on the list.",
		extraClash = "Those two extras use the same spot. Pick one.",
		tooManyExtras = "That's too many extras for one car.",
		unknownPlate = "That plate style isn't available.",
		nothingChanged = "Nothing to buy yet. Change something first.",
	},
}

----------------------------------------------------------------------------------------------------------------
-- Lookups
----------------------------------------------------------------------------------------------------------------

local function indexById<T>(list: { T }): { [string]: T }
	local byId: { [string]: T } = {}
	for _, entry in list do
		byId[(entry :: any).id] = entry
	end
	return byId
end

local paintsById = indexById(Customization.paints)
local finishesById = indexById(Customization.finishes)
local exclusiveFinishesById = indexById(Customization.exclusiveFinishes)
local wrapsById = indexById(Customization.wraps)
local exclusiveWrapsById = indexById(Customization.exclusiveWraps)
for id, wrap in exclusiveWrapsById do
	wrapsById[id] = wrap -- every wrap renders and validates by id; the shop list and the server gate exclusives
end
local wheelsById = indexById(Customization.wheels)
local calipersById = indexById(Customization.calipers)
local extrasById = indexById(Customization.extras)
local platesById = indexById(Customization.plateFormats)

-- Floating-point slack when comparing ride heights and tints (they arrive as decimals over the network).
local EPSILON = 1e-4

function Customization.getPaint(id: string?): Paint?
	return if id then paintsById[id] else nil
end

function Customization.getFinish(id: string?): Finish?
	return if id then finishesById[id] else nil
end

-- nil and "none" both mean the "none" wrap. Exclusive wraps are found too.
function Customization.getWrap(id: string?): Wrap?
	return wrapsById[id or "none"]
end

-- True for an exclusive look's id (exclusiveWraps): one a player must have before they can use it.
function Customization.isExclusive(id: string?): boolean
	return id ~= nil and exclusiveWrapsById[id] ~= nil
end

-- True when the shop has the exclusive look `lookId` (Config/Monetization, Config/Limiteds and Config/Season grant
-- look ids). Plate frames aren't built yet, so a plate frame id is false: whatever grants one isn't sold yet.
function Customization.lookExists(lookId: string): boolean
	return Customization.isExclusive(lookId)
end

-- Whether a wrap can go on a body that takes no vinyl bands (final art, Vehicle/Appearance.takesWraps): it has no
-- bands, or a full-body color for such a body (artColor).
function Customization.wrapFitsMesh(wrap: Wrap): boolean
	return #wrap.bands == 0 or wrap.artColor ~= nil
end

-- The finish a car wears with this wrap on: the wrap's own (an exclusive look's chrome, brushed metal or pearl coat)
-- when it has one, else `finishId`'s shop finish, else nil. Only for drawing a car: the shop sells, checks and prices
-- `finishes` alone (getFinish), so an exclusive finish can never be bought.
function Customization.wornFinish(wrap: Wrap?, finishId: string?): Finish?
	local ownId = if wrap ~= nil then wrap.finish else nil
	local own = if ownId ~= nil then exclusiveFinishesById[ownId] else nil
	return own or Customization.getFinish(finishId)
end

-- Whether a wrap paints the whole body in its artColor on every car (every exclusive look), not only on a body that
-- takes no bands.
function Customization.paintsWholeBody(wrap: Wrap?): boolean
	return wrap ~= nil and wrap.exclusive == true and wrap.artColor ~= nil
end

-- True when a finish looks like a shop finish: the same material and a reflectance less than finishGap away.
local function likeShopFinish(finish: Finish): boolean
	for _, shop in Customization.finishes do
		if
			shop.material == finish.material
			and math.abs(shop.reflectance - finish.reflectance) < Customization.finishGap - EPSILON
		then
			return true
		end
	end
	return false
end

-- What a wrap adds that the shop can't sell, in a fixed order: its exclusive finish's id, then "pearl" (a color
-- drift), "glass" (colored windows) and "underglow". Empty for every shop wrap.
function Customization.effectsOf(wrap: Wrap): { string }
	local effects: { string } = {}
	local finishId = wrap.finish
	local finish = if finishId ~= nil then exclusiveFinishesById[finishId] else nil
	if finish ~= nil and not likeShopFinish(finish) then
		table.insert(effects, finish.id)
	end
	if wrap.shift ~= nil then
		table.insert(effects, "pearl")
	end
	if wrap.glass ~= nil then
		table.insert(effects, "glass")
	end
	if wrap.underglow ~= nil then
		table.insert(effects, "underglow")
	end
	return effects
end

-- Whether the shop could make this wrap's whole look from what it sells (a shop wrap's bands, a palette or custom
-- paint, a shop finish). False for every exclusive look (tests/Customization.spec): each has a finish no shop finish
-- comes near, a pearl drift, colored glass or underglow, and nothing the shop or the AI Car Designer sells adds any.
function Customization.shopCanMake(wrap: Wrap): boolean
	return #Customization.effectsOf(wrap) == 0 -- a finish id that isn't an exclusive finish is never worn (wornFinish)
end

-- An exclusive look's few plain words ("Amber pearl that slowly shifts to coral"), or nil for an id that isn't one.
function Customization.lookBlurb(lookId: string): string?
	local wrap = exclusiveWrapsById[lookId]
	return if wrap ~= nil then wrap.blurb else nil
end

-- How far a pearl has drifted at server time `now` (seconds): 0 at its own color, 1 at its shift color, eased, one
-- round trip every `seconds`. The same everywhere at the same time, and never random.
function Customization.pearlMix(now: number, seconds: number): number
	if type(now) ~= "number" or now ~= now or not (seconds > 0) or now == math.huge or now == -math.huge then
		return 0
	end
	local phase = (now % seconds) / seconds
	local rise = 1 - math.abs(2 * phase - 1) -- 0 .. 1 .. 0 over the round trip
	return rise * rise * (3 - 2 * rise)
end

-- Whether Lighting.ClockTime `clockTime` (hours) is night for underglow.
function Customization.isNight(clockTime: number): boolean
	local glow = Customization.underglow
	return clockTime >= glow.nightFrom or clockTime < glow.nightUntil
end

-- The underglow light's brightness at Lighting.ClockTime `clockTime`.
function Customization.underglowBrightness(clockTime: number): number
	local glow = Customization.underglow
	return if Customization.isNight(clockTime) then glow.nightBrightness else glow.dayBrightness
end

-- The wraps the Wrap tab lists for a player: every shop wrap, then the exclusive wraps they have (`owned`, by look
-- id) and the one already on the car (`onCar`), so a look they no longer have (the club lapsed) still shows as
-- current. `paintOnly` (a car whose body is one painted mesh, Vehicle/Appearance.takesWraps) leaves out every wrap
-- that can't go on it (wrapFitsMesh): bands are laid on flat panels, so only wraps without bands and those with a
-- full-body color for final art (every exclusive look) are left.
function Customization.wrapsFor(owned: { [string]: boolean }?, onCar: string?, paintOnly: boolean?): { Wrap }
	local list: { Wrap } = {}
	for _, wrap in Customization.wraps do
		table.insert(list, wrap)
	end
	for _, wrap in Customization.exclusiveWraps do
		if (owned ~= nil and owned[wrap.id] == true) or wrap.id == onCar then
			table.insert(list, wrap)
		end
	end
	if paintOnly == true then
		local fits: { Wrap } = {}
		for _, wrap in list do
			if Customization.wrapFitsMesh(wrap) then
				table.insert(fits, wrap)
			end
		end
		return fits
	end
	return list
end

function Customization.getWheel(id: string?): Wheel?
	return if id then wheelsById[id] else nil
end

function Customization.getCaliper(id: string?): Caliper?
	return if id then calipersById[id] else nil
end

function Customization.getExtra(id: string?): Extra?
	return if id then extrasById[id] else nil
end

function Customization.getPlateFormat(id: string?): PlateFormat?
	return if id then platesById[id] else nil
end

----------------------------------------------------------------------------------------------------------------
-- Paint
----------------------------------------------------------------------------------------------------------------

local function quantize(value: number, steps: number): number
	return math.floor(math.clamp(value, 0, 1) * steps + 0.5)
end

-- Whether a custom color is inside the shop's limits (hue is free; saturation and value are capped).
function Customization.customColorAllowed(hsv: HSV): boolean
	local limits = Customization.customColor
	local function unit(value: any): boolean
		return type(value) == "number" and value == value and value >= 0 and value <= 1
	end
	if type(hsv) ~= "table" or not (unit(hsv.h) and unit(hsv.s) and unit(hsv.v)) then
		return false
	end
	return hsv.s >= limits.minSaturation - EPSILON
		and hsv.s <= limits.maxSaturation + EPSILON
		and hsv.v >= limits.minValue - EPSILON
		and hsv.v <= limits.maxValue + EPSILON
end

-- The stored paint id for a custom color: clamped into the limits and rounded to whole degrees and percent.
function Customization.customPaintId(hsv: HSV): string
	local limits = Customization.customColor
	local s = math.clamp(hsv.s, limits.minSaturation, limits.maxSaturation)
	local v = math.clamp(hsv.v, limits.minValue, limits.maxValue)
	local hue = quantize(hsv.h, limits.hueSteps) % limits.hueSteps -- 360 degrees is 0
	return `{limits.idPrefix}{hue},{quantize(s, limits.percentSteps)},{quantize(v, limits.percentSteps)}`
end

-- The custom color a "custom:" paint id stands for, or nil when the id isn't a valid custom color.
function Customization.parseCustomPaint(id: string): HSV?
	local limits = Customization.customColor
	local prefix = limits.idPrefix
	if string.sub(id, 1, #prefix) ~= prefix then
		return nil
	end
	local h, s, v = string.match(string.sub(id, #prefix + 1), "^(%d+),(%d+),(%d+)$")
	if h == nil or s == nil or v == nil then
		return nil
	end
	local hue, saturation, value = tonumber(h), tonumber(s), tonumber(v)
	if hue == nil or saturation == nil or value == nil or hue >= limits.hueSteps then
		return nil
	end
	local hsv = { h = hue / limits.hueSteps, s = saturation / limits.percentSteps, v = value / limits.percentSteps }
	-- Only ids customPaintId can make are valid (no leading zeros, inside the limits).
	if not Customization.customColorAllowed(hsv) or Customization.customPaintId(hsv) ~= id then
		return nil
	end
	return hsv
end

-- Whether a paint id is a palette color or a valid custom color.
function Customization.isPaint(id: string): boolean
	return paintsById[id] ~= nil or Customization.parseCustomPaint(id) ~= nil
end

-- Whether a paint id is the factory color (the car keeps its brand's own paint).
function Customization.isFactoryPaint(id: string?): boolean
	local paint = if id then paintsById[id] else nil
	return paint ~= nil and paint.factory == true
end

-- The color a paint id stands for (palette or custom), or nil for an unknown id. For the factory paint this is
-- only its swatch color: the car shows its own brand color (Vehicle/Appearance).
function Customization.paintColor(id: string?): Color3?
	if id == nil then
		return nil
	end
	local paint = paintsById[id]
	if paint then
		return paint.color
	end
	local hsv = Customization.parseCustomPaint(id)
	return if hsv then Color3.fromHSV(hsv.h, hsv.s, hsv.v) else nil
end

----------------------------------------------------------------------------------------------------------------
-- Ride height and tint
----------------------------------------------------------------------------------------------------------------

-- Whether a ride height is in range and on a step.
function Customization.isRideHeight(value: number): boolean
	local r = Customization.rideHeight
	if type(value) ~= "number" or value ~= value or value < r.min - EPSILON or value > r.max + EPSILON then
		return false
	end
	local steps = value / r.step
	return math.abs(steps - math.floor(steps + 0.5)) <= EPSILON
end

-- Body offset in studs (negative = lower) for a ride height on a car of this class. Values are clamped to -1..1.
function Customization.rideOffset(value: number, vehicleClass: string?): number
	local r = Customization.rideHeight
	local range = (if vehicleClass then r.byClass[vehicleClass] else nil) or r.default
	local clamped = math.clamp(if value == value then value else 0, r.min, r.max)
	return if clamped < 0 then clamped * range.lower else clamped * range.raise
end

-- The tint level for a value: the exact level, or nil when the value isn't one of the steps.
function Customization.getTintLevel(value: number): TintLevel?
	for _, level in Customization.tint.levels do
		if math.abs(level.value - value) <= EPSILON then
			return level
		end
	end
	return nil
end

-- The tint level nearest a value (for showing any stored value, even an off-step one).
function Customization.nearestTintLevel(value: number): TintLevel
	local levels = Customization.tint.levels
	local best = levels[1]
	for _, level in levels do
		if math.abs(level.value - value) < math.abs(best.value - value) then
			best = level
		end
	end
	return best
end

----------------------------------------------------------------------------------------------------------------
-- Extras
----------------------------------------------------------------------------------------------------------------

-- An extra's size on a car of this class (studs), or nil when the car can't take it: its class isn't listed, or
-- the extra names the body styles it fits (Config/Vehicles bodyStyle) and `bodyStyle` isn't one of them. Callers
-- that know the car pass its body style; nil checks the class alone.
function Customization.extraSize(extra: Extra, vehicleClass: string, bodyStyle: string?): Vector3?
	local styles = extra.bodyStyles
	if styles ~= nil and bodyStyle ~= nil and table.find(styles, bodyStyle) == nil then
		return nil
	end
	return extra.sizeByClass[vehicleClass]
end

-- Whether an extra may go on a car of this class (and body style, when given).
function Customization.extraAllowed(extraId: string, vehicleClass: string, bodyStyle: string?): boolean
	local extra = extrasById[extraId]
	return extra ~= nil and Customization.extraSize(extra, vehicleClass, bodyStyle) ~= nil
end

-- The extras a car of this class (and body style, when given) may take, in shop order.
function Customization.extrasFor(vehicleClass: string, bodyStyle: string?): { Extra }
	local list = {}
	for _, extra in Customization.extras do
		if Customization.extraSize(extra, vehicleClass, bodyStyle) ~= nil then
			table.insert(list, extra)
		end
	end
	return list
end

-- Checks a full extras list for a car: known ids, allowed on the class, each once, one per group, not too many.
-- Returns nil when it's fine, else the message to show.
function Customization.checkExtras(list: { string }, vehicleClass: string, bodyStyle: string?): string?
	local messages = Customization.messages
	if #list > Customization.maxExtras then
		return messages.tooManyExtras
	end
	local seen: { [string]: boolean } = {}
	local groups: { [string]: boolean } = {}
	for _, id in list do
		local extra = extrasById[id]
		if extra == nil then
			return messages.unknownExtra
		end
		if Customization.extraSize(extra, vehicleClass, bodyStyle) == nil then
			return messages.extraNotForClass
		end
		if seen[id] then
			return messages.extraTwice
		end
		seen[id] = true
		local group = extra.group
		if group then
			if groups[group] then
				return messages.extraClash
			end
			groups[group] = true
		end
	end
	return nil
end

----------------------------------------------------------------------------------------------------------------
-- Plates
----------------------------------------------------------------------------------------------------------------

-- Custom plate text as it is stored and checked: capitals, no leading or trailing spaces, single spaces.
function Customization.normalizePlateText(text: string): string
	local upper = string.upper(text)
	local trimmed = string.match(upper, "^%s*(.-)%s*$") or ""
	return (string.gsub(trimmed, "%s+", " "))
end

-- Whether custom plate text follows the rules (check the normalized text). The server still filters it with
-- TextService before anyone else sees it.
function Customization.isPlateTextAllowed(text: string): boolean
	local rules = Customization.plate
	return #text >= rules.minLength and #text <= rules.maxLength and string.match(text, rules.allowedPattern) ~= nil
end

-- 32-bit FNV-1a hash of a string (a stable seed for standard plate numbers).
local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619
local TWO_16 = 65536
local TWO_32 = 4294967296
local function hash(text: string): number
	local h = FNV_OFFSET
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		-- h * prime mod 2^32, multiplied in 16-bit halves so every product stays exact in a double.
		local low, high = h % TWO_16, (h - h % TWO_16) / TWO_16
		h = (low * FNV_PRIME + ((high * FNV_PRIME) % TWO_16) * TWO_16) % TWO_32
	end
	return h
end

-- A linear congruential step (Numerical Recipes constants); products stay below 2^53, so this is exact.
local LCG_MULTIPLIER = 1664525
local LCG_INCREMENT = 1013904223
local LCG_MODULUS = TWO_32
local function nextState(state: number): number
	return (state * LCG_MULTIPLIER + LCG_INCREMENT) % LCG_MODULUS
end

local function hasAvoided(text: string): boolean
	for _, bad in Customization.plate.standardAvoid do
		if string.find(text, bad, 1, true) then
			return true
		end
	end
	return false
end

-- The free standard plate text for a car: the format's pattern filled in from `seed` (the car's uid), the same
-- every time. Unknown formats use the default format.
function Customization.standardPlateText(formatId: string?, seed: string): string
	local format = platesById[formatId or ""] or platesById[Customization.defaults.plateFormat]
	local rules = Customization.plate
	local letters, digits = rules.standardLetters, rules.standardDigits
	local state = hash(`{format.id}:{seed}`)
	local text = ""
	for _ = 1, rules.standardMaxDraws do
		local chars = table.create(#format.pattern)
		for i = 1, #format.pattern do
			local slot = string.sub(format.pattern, i, i)
			if slot == "@" or slot == "#" then
				state = nextState(state)
				local pool = if slot == "@" then letters else digits
				-- The high bits of an LCG are the well-mixed ones.
				local pick = math.floor(state / LCG_MODULUS * #pool) + 1
				table.insert(chars, string.sub(pool, pick, pick))
			else
				table.insert(chars, slot)
			end
		end
		text = table.concat(chars)
		if not hasAvoided(text) then
			break
		end
	end
	return text
end

----------------------------------------------------------------------------------------------------------------
-- Prices and checks
----------------------------------------------------------------------------------------------------------------

-- A base price scaled for the class's tier and rounded to whole dollars (Config/Classes; unknown class: 1x).
function Customization.scaledPrice(base: number, vehicleClass: string?): number
	local class = if vehicleClass then Classes[vehicleClass] else nil
	local scale = if class then Customization.priceScaleByTier[class.tier] or 1 else 1
	local rounding = Customization.priceRounding
	return math.max(rounding, math.floor(base * scale / rounding + 0.5) * rounding)
end

local function sameNumber(a: number?, b: number?): boolean
	return a ~= nil and b ~= nil and math.abs(a - b) <= EPSILON
end

-- Whether two look numbers (ride height, tint) count as the same: the tolerance check, pricing and the server's
-- "did anything change" all use this one rule.
function Customization.sameNumber(a: number?, b: number?): boolean
	return sameNumber(a, b)
end

-- A ride height or tint on its exact step when it is within the tolerance of one (what gets saved), else the value
-- as given (check refuses it).
local function canonicalRideHeight(value: number): number
	if Customization.isRideHeight(value) then
		local step = Customization.rideHeight.step
		return math.round(value / step) * step
	end
	return value
end

local function canonicalTint(value: number): number
	local level = Customization.getTintLevel(value)
	return if level then level.value else value
end

-- The paint id a change set ends with (a custom color wins over a palette id), or nil when paint isn't touched.
function Customization.paintAfter(changes: Changes): string?
	local custom = changes.customColor
	if custom then
		return Customization.customPaintId(custom)
	end
	return changes.paint
end

-- What `changes` cost on a car that currently looks like `current`, for a car of `vehicleClass`. Only fields
-- that differ from the current look are charged; plate formats are free; removing extras is free. Unknown ids
-- cost nothing here, so call `check` first. Returns the total (whole $) and the charged lines in shop order.
function Customization.priceOf(changes: Changes, current: Look, vehicleClass: string?): (number, { PriceLine })
	local lines: { PriceLine } = {}
	local function charge(category: string, id: string, base: number)
		table.insert(lines, { category = category, id = id, price = Customization.scaledPrice(base, vehicleClass) })
	end

	local paint = Customization.paintAfter(changes)
	if paint ~= nil and paint ~= current.paint then
		if changes.customColor then
			charge("paint", paint, Customization.customColor.price)
		elseif paintsById[paint] then
			charge("paint", paint, Customization.paintPrice)
		end
	end

	local finish = finishesById[changes.finish or ""]
	if finish and finish.id ~= current.finish then
		charge("finish", finish.id, finish.price)
	end

	if changes.wrap ~= nil then
		local wrap = wrapsById[changes.wrap]
		local currentWrap = current.wrap or "none"
		-- An exclusive wrap (price 0) goes on free: the player already has the look.
		if wrap and wrap.id ~= currentWrap and wrap.price > 0 then
			charge("wrap", wrap.id, wrap.price)
		end
	end

	local wheel = wheelsById[changes.wheels or ""]
	if wheel and wheel.id ~= current.wheels then
		charge("wheels", wheel.id, wheel.price)
	end

	if changes.rideHeight ~= nil and not sameNumber(changes.rideHeight, current.rideHeight) then
		charge("rideHeight", tostring(changes.rideHeight), Customization.rideHeight.price)
	end

	if changes.tint ~= nil and not sameNumber(changes.tint, current.tint) then
		charge("tint", tostring(changes.tint), Customization.tint.price)
	end

	local caliper = calipersById[changes.caliper or ""]
	if caliper and caliper.id ~= (current.caliper or Customization.defaults.caliper) then
		charge("caliper", caliper.id, caliper.price)
	end

	if changes.extras ~= nil then
		local had: { [string]: boolean } = {}
		local currentExtras: { string } = current.extras or {}
		for _, id in currentExtras do
			had[id] = true
		end
		local counted: { [string]: boolean } = {}
		for _, id in changes.extras do
			local extra = extrasById[id]
			if extra and not had[id] and not counted[id] then
				counted[id] = true
				charge("extras", id, extra.price)
			end
		end
	end

	-- Plate formats are free (standard plates); nothing to charge.

	local total = 0
	for _, line in lines do
		total += line.price
	end
	return total, lines
end

-- Checks every value in a change set against the catalog for a car of this class. Returns (true, nil) when all
-- are allowed, else (false, message to show). It does not price anything or compare with the current look.
function Customization.check(changes: Changes, vehicleClass: string, bodyStyle: string?): (boolean, string?)
	local messages = Customization.messages
	if changes.paint ~= nil and changes.customColor ~= nil then
		return false, messages.paintAndCustom
	end
	if changes.paint ~= nil and paintsById[changes.paint] == nil then
		return false, messages.unknownPaint
	end
	if changes.customColor ~= nil and not Customization.customColorAllowed(changes.customColor) then
		return false, messages.customColorLimit
	end
	if changes.finish ~= nil and finishesById[changes.finish] == nil then
		return false, messages.unknownFinish
	end
	if changes.wrap ~= nil and wrapsById[changes.wrap] == nil then
		return false, messages.unknownWrap
	end
	if changes.wheels ~= nil and wheelsById[changes.wheels] == nil then
		return false, messages.unknownWheels
	end
	if changes.rideHeight ~= nil and not Customization.isRideHeight(changes.rideHeight) then
		return false, messages.badRideHeight
	end
	if changes.tint ~= nil and Customization.getTintLevel(changes.tint) == nil then
		return false, messages.badTint
	end
	if changes.caliper ~= nil and calipersById[changes.caliper] == nil then
		return false, messages.unknownCaliper
	end
	if changes.extras ~= nil then
		local problem = Customization.checkExtras(changes.extras, vehicleClass, bodyStyle)
		if problem then
			return false, problem
		end
	end
	if changes.plateFormat ~= nil and platesById[changes.plateFormat] == nil then
		return false, messages.unknownPlate
	end
	return true, nil
end

-- The look a car ends up with after `changes` (validated or not: unknown values are copied as given). The
-- server saves these fields; the shop previews them. Never changes `current`.
function Customization.applyChanges(current: Look, changes: Changes): Look
	local paint = Customization.paintAfter(changes)
	return {
		uid = current.uid,
		paint = paint or current.paint,
		finish = changes.finish or current.finish,
		wrap = if changes.wrap ~= nil then changes.wrap else current.wrap,
		wheels = changes.wheels or current.wheels,
		-- Snapped to their exact steps, so a value a hair off a step never reaches a save.
		rideHeight = if changes.rideHeight ~= nil then canonicalRideHeight(changes.rideHeight) else current.rideHeight,
		tint = if changes.tint ~= nil then canonicalTint(changes.tint) else current.tint,
		caliper = changes.caliper or current.caliper,
		extras = table.clone(changes.extras or current.extras or {}),
		plateFormat = changes.plateFormat or current.plateFormat,
		plateText = current.plateText,
	}
end

return Customization
