--!strict
-- Car brands (PLAN.md §2, §3.1). Every vehicle references a brand id. The default build is unlicensed: every
-- brand is fictional and original (working names; trademark-search before launch). A signed license becomes a
-- new entry with licensed = true and its credits text; no system code changes.

export type Brand = {
	id: string,
	displayName: string,
	logoAssetIds: { number },
	segment: string,
	personality: string,
	licensed: boolean,
	credits: string?, -- trademark notice shown in credits when licensed
}

local Brands: { [string]: Brand } = {
	ohm = {
		id = "ohm",
		displayName = "Ohm Motors",
		logoAssetIds = {},
		segment = "Electric hero brand",
		personality = "Futuristic; every model is a job",
		licensed = false,
	},
	halden = {
		id = "halden",
		displayName = "Halden",
		logoAssetIds = {},
		segment = "Everyday hatchbacks, sedans and minivans",
		personality = "Cheap, reliable starters",
		licensed = false,
	},
	ironwood = {
		id = "ironwood",
		displayName = "Ironwood",
		logoAssetIds = {},
		segment = "Trucks and off-road",
		personality = "Big, rugged, built to tow",
		licensed = false,
	},
	aldermoor = {
		id = "aldermoor",
		displayName = "Aldermoor",
		logoAssetIds = {},
		segment = "Luxury sedans and SUVs",
		personality = "Quiet, plush, expensive",
		licensed = false,
	},
	kaze = {
		id = "kaze",
		displayName = "Kaze",
		logoAssetIds = {},
		segment = "Tuner and sports cars",
		personality = "Light, nimble, mod-friendly",
		licensed = false,
	},
	brannock = {
		id = "brannock",
		displayName = "Brannock",
		logoAssetIds = {},
		segment = "Muscle cars and classics",
		personality = "Loud, torquey, retro",
		licensed = false,
	},
	montevale = {
		id = "montevale",
		displayName = "Montevale",
		logoAssetIds = {},
		segment = "Exotics and supercars",
		personality = "Fast, rare, flashy",
		licensed = false,
	},
	northline = {
		id = "northline",
		displayName = "Northline",
		logoAssetIds = {},
		segment = "Vans, tow trucks and municipal fleet",
		personality = "Work vehicles for jobs and roleplay roles",
		licensed = false,
	},
}

return Brands
