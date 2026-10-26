--!strict
-- The open plots' uses (docs/city/CITY_PLAN.md §4.3, pass 4). A plot no building fits used to stay open (Config/City
-- openFallback): the run's paved lot, or bare ground. Dev/City/CityBuilder now gives each run of open plots a use of
-- its own: surface parking, a pocket plaza, a food-truck court, a sports court, a construction site, a small park or
-- dog run, an outdoor market. Each lot type is an archetype like any building (Config/CityArchetypes/<id> with weight
-- 0, so the building passes never draw it, and a module in Dev/City/Archetypes/lots); this module says which stand in
-- which district, how many parts a lot may spend, and the ceilings the whole pass keeps to.
--
--   types       the lot type ids, in a fixed order (placement walks them in this order)
--   mix         each lot type's weight per district: neighbouring lots never share a type, so the second and third
--               choices matter as much as the first
--   maxWidth    a run of open plots wider than this (or of more than maxPlots plots) is cut into several lots
--   parts       how many parts one lot may spend: base + perHundred for every 100 studs of frontage it takes (its width
--               plus the gap to its neighbours). A lot type builds its core, then its extras in order while they fit,
--               so a wide lot is richer than a narrow one and downtown (inside the phone gate's worst view) is leaner
--               than the arts district
--   budget      the most parts the pass adds per district, and night lights in all: past them a run stays open (the
--               pass measures each lot by building it, so these are exact)
--   names       invented text for the hoardings and market signs (never a real business, developer or brand)

export type Rate = { base: number, perHundred: number }

local CityLots = {
	types = {
		"construction_site",
		"food_truck_court",
		"outdoor_market",
		"pocket_park",
		"pocket_plaza",
		"sports_court",
		"surface_parking",
	},

	-- Davis, 2026-10-26: "fill the streets: cafés, parked cars, shop fronts, the empty lawn and the empty downtown lots".
	-- Downtown: parking, plazas, construction and food trucks; the arts district: mural-and-truck courts, parking and
	-- markets; the suburbs: parks and courts; the beach: plazas and parking.
	mix = {
		downtown = {
			surface_parking = 3,
			pocket_plaza = 3,
			construction_site = 1.6,
			food_truck_court = 1.2,
			pocket_park = 0.6,
			outdoor_market = 0.5,
			sports_court = 0.35,
		},
		arts = {
			food_truck_court = 3,
			surface_parking = 2,
			outdoor_market = 2,
			construction_site = 0.6,
			pocket_plaza = 0.6,
			sports_court = 0.5,
			pocket_park = 0.3,
		},
		suburbs = {
			pocket_park = 3,
			sports_court = 2.2,
			pocket_plaza = 0.7,
			surface_parking = 0.5,
			outdoor_market = 0.3,
			food_truck_court = 0.2,
		},
		beach = {
			pocket_plaza = 3,
			surface_parking = 2.4,
			food_truck_court = 0.8,
			outdoor_market = 0.6,
			pocket_park = 0.5,
			sports_court = 0.3,
		},
		quarry = {
			surface_parking = 1,
			construction_site = 1,
			food_truck_court = 0.8,
		},
	} :: { [string]: { [string]: number } },

	maxWidth = 150,
	maxPlots = 4,
	-- Salt for a lot's own random stream (its first plot's stream, salted so it never repeats the building draw).
	salt = 4099,

	-- Parts per lot (see the header). Downtown 1.5 + 5.5 per 100 studs: about 4 parts on one plot, 6 on two, 8 on three.
	-- Measured budget, 2026-10-26: the open plots were downtown 299, arts 114, suburbs 40, beach 19, quarry 3.
	parts = {
		downtown = { base = 1.5, perHundred = 5.5 },
		beach = { base = 2, perHundred = 7 },
		suburbs = { base = 2, perHundred = 7.5 },
		-- Outside the phone gate's worst view, so richer: a mural-and-trucks court on two plots gets its mural.
		arts = { base = 2, perHundred = 8 },
		quarry = { base = 2, perHundred = 7 },
	} :: { [string]: Rate },
	defaultRate = { base = 2, perHundred = 6 } :: Rate,

	-- Ceilings for the whole pass (Environment budget.buildingParts and Config/City budgets.nightLights carry these on
	-- top of the buildings' own). About 1,550 parts and 300 night lights expected. Downtown went from 900 to 700 at
	-- integration (2026-10-26): its lots all stand inside the phone gate's worst view (Environment budget.inViewParts,
	-- near (-900, 300)), which the street-life round had pushed over; a run past the budget stays an open plaza.
	budget = {
		parts = { downtown = 700, arts = 520, suburbs = 180, beach = 90, quarry = 24 } :: { [string]: number },
		lights = 340,
	},

	-- Every lot paves itself from `bottom` (under the ground) to `top`, over the run's paved lot (0.1 thick) or the bare
	-- ground of a lone plot; everything on a lot stands on `top`.
	floor = { top = 0.3, bottom = -0.4 },
	-- A lot's lamps are glass heads that glow at night (Config/Environment nightLights kind "window", their own night
	-- colour): warm like the streetlights, or a cool white for the floodlights over a court.
	lampColors = { warm = Color3.fromRGB(255, 214, 150), cool = Color3.fromRGB(236, 240, 255) },
	-- Festoons (Dev/City/LotKit festoon): a strand of lights from a lantern to a pole at most `span` studs away along x
	-- and z (a 100-stud straight strand read as a pipe across the lot, 2026-10-26), `thick` across, a dark cable by day.
	-- It hangs in two strands that `sag` studs under a straight line at the middle (a straight strand read as a
	-- volleyball net by day: the street-level roast, 2026-10-26), and casts `glow` on the tables at night.
	festoon = {
		span = Vector2.new(32, 12),
		thick = 0.25,
		cable = Color3.fromRGB(58, 56, 54),
		sag = 2.4,
		glow = { brightness = 1.6, range = 22, color = Color3.fromRGB(255, 196, 132) },
	},
	-- A palm on a lot is left out when its crown would have to shrink below this share of its species' size to stay on
	-- the site (Dev/City/LotKit palm).
	palmMin = 0.55,

	names = {
		-- Construction hoardings: "<project>  ·  COMING SOON  ·  <developer>". Projects come from Config/City
		-- signNames.towers.
		developers = {
			"KILOVOLT PARTNERS",
			"TIDEWATT DEVELOPMENT",
			"NEW CURRENT GROUP",
			"HIGH TENSION BUILDERS",
			"OHM & ARC BUILDERS",
		},
		markets = { "CURRENT MARKET", "BREAKER YARD MARKET", "AMP ALLEY MARKET", "VOLT ROW MARKET" },
		courts = { "VOLT EATS", "THE CHARGE-UP", "SPARK YARD", "LIVE WIRE EATS" },
	},
}

return CityLots
