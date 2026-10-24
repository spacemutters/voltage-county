--!strict
-- Vehicle classes, tiers and stat bands (PLAN.md §3.3). Every vehicle trim must sit inside its class band,
-- player designs and AI mods included, so no car can break the economy. The Ohm lineup (§3.2) anchors the
-- bands. Job eligibility comes from class (Phase 6).
--
-- price is the in-game $ a trim costs in total (an upgrade trim counts its base trim plus the upgrade).
-- handling is 0..1: how sharply a car turns and how much grip it has (Vehicle/Tuning maps it to physics).
--
-- The price ladder (docs/roast-2026-10-24.md point 5; tests/Catalog.spec): only tiers 4 and 5 reach under 3 s to 60,
-- and their bands sit wholly ahead of every lower class (slower to 60 at their best, less grip at their most), so
-- designs and AI mods keep the order too. The exotic band starts at 2.1 s: a fuel exotic designed any quicker would
-- out-launch the Arc (a fuel car needs a harder peak for the same 0-60; tests/Tuning.spec "Arc tuning").

export type Range = { min: number, max: number }

export type Class = {
	id: string,
	displayName: string,
	tier: number, -- 1..5
	price: Range,
	topSpeedMph: Range,
	zeroToSixtySec: Range,
	energyMinutes: Range, -- minutes of driving on a full charge or tank
	handling: Range,
	seats: Range,
	designable: boolean, -- the AI Car Designer may make this class (Phase 11; exotic also needs an owned exotic)
}

local function range(min: number, max: number): Range
	return { min = min, max = max }
end

local Classes: { [string]: Class } = {
	economy = {
		id = "economy",
		displayName = "Economy",
		tier = 1,
		price = range(0, 40000),
		topSpeedMph = range(85, 125),
		zeroToSixtySec = range(5, 11),
		energyMinutes = range(20, 45),
		handling = range(0.3, 0.6),
		seats = range(2, 5),
		designable = true,
	},
	sedan = {
		id = "sedan",
		displayName = "Sedan",
		tier = 1,
		price = range(0, 75000),
		topSpeedMph = range(95, 160),
		zeroToSixtySec = range(3.4, 8),
		energyMinutes = range(20, 45),
		handling = range(0.4, 0.75),
		seats = range(4, 5),
		designable = true,
	},
	minivan = {
		id = "minivan",
		displayName = "Minivan",
		tier = 1,
		price = range(25000, 70000),
		topSpeedMph = range(95, 125),
		zeroToSixtySec = range(5, 9),
		energyMinutes = range(25, 45),
		handling = range(0.3, 0.55),
		seats = range(6, 8),
		designable = true,
	},
	van = {
		id = "van",
		displayName = "Van",
		tier = 1,
		price = range(25000, 80000),
		topSpeedMph = range(80, 110),
		zeroToSixtySec = range(6, 12),
		energyMinutes = range(25, 50),
		handling = range(0.25, 0.5),
		seats = range(2, 3),
		designable = true,
	},
	suv = {
		id = "suv",
		displayName = "SUV",
		tier = 2,
		price = range(40000, 110000),
		topSpeedMph = range(100, 155),
		zeroToSixtySec = range(3.2, 8),
		energyMinutes = range(25, 45),
		handling = range(0.4, 0.65),
		seats = range(5, 7),
		designable = true,
	},
	pickup = {
		id = "pickup",
		displayName = "Pickup",
		tier = 2,
		price = range(45000, 150000),
		topSpeedMph = range(95, 135),
		zeroToSixtySec = range(3.2, 8),
		energyMinutes = range(22, 40),
		handling = range(0.35, 0.6),
		seats = range(2, 5),
		designable = true,
	},
	offroad = {
		id = "offroad",
		displayName = "Off-road",
		tier = 2,
		price = range(40000, 140000),
		topSpeedMph = range(85, 125),
		zeroToSixtySec = range(3.5, 9),
		energyMinutes = range(20, 40),
		handling = range(0.3, 0.55),
		seats = range(2, 5),
		designable = true,
	},
	service = {
		id = "service",
		displayName = "Service",
		tier = 2,
		price = range(30000, 160000),
		topSpeedMph = range(40, 110),
		zeroToSixtySec = range(5, 14),
		energyMinutes = range(20, 60),
		handling = range(0.25, 0.5),
		seats = range(1, 5),
		designable = false,
	},
	sports = {
		id = "sports",
		displayName = "Sports",
		tier = 3,
		price = range(60000, 250000),
		topSpeedMph = range(140, 190),
		zeroToSixtySec = range(3, 5),
		energyMinutes = range(18, 35),
		handling = range(0.65, 0.86),
		seats = range(2, 4),
		designable = true,
	},
	muscle = {
		id = "muscle",
		displayName = "Muscle",
		tier = 3,
		price = range(50000, 220000),
		topSpeedMph = range(135, 185),
		zeroToSixtySec = range(3, 5.5),
		energyMinutes = range(15, 35),
		handling = range(0.45, 0.7),
		seats = range(2, 5),
		designable = true,
	},
	luxury = {
		id = "luxury",
		displayName = "Luxury",
		tier = 3,
		price = range(120000, 400000),
		topSpeedMph = range(135, 175),
		zeroToSixtySec = range(3, 6),
		energyMinutes = range(25, 45),
		handling = range(0.5, 0.75),
		seats = range(4, 7),
		designable = true,
	},
	heavy = {
		id = "heavy",
		displayName = "Heavy",
		tier = 3,
		price = range(180000, 400000),
		topSpeedMph = range(60, 80),
		zeroToSixtySec = range(10, 16),
		energyMinutes = range(35, 60),
		handling = range(0.15, 0.35),
		seats = range(1, 2),
		designable = false,
	},
	exotic = {
		id = "exotic",
		displayName = "Exotic",
		tier = 4,
		price = range(300000, 1200000),
		topSpeedMph = range(180, 215),
		zeroToSixtySec = range(2.1, 2.8),
		energyMinutes = range(18, 30),
		handling = range(0.87, 0.95),
		seats = range(1, 2),
		designable = true,
	},
	hypercar = {
		id = "hypercar",
		displayName = "Hypercar",
		tier = 5,
		price = range(1500000, 8000000),
		topSpeedMph = range(210, 240),
		zeroToSixtySec = range(1, 2.2),
		energyMinutes = range(15, 30),
		handling = range(0.9, 1),
		seats = range(1, 2),
		designable = false,
	},
}

return Classes
