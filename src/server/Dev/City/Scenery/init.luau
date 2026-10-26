--!strict
-- The beach city's scenery (docs/city/SCENERY.md; Config/CityScenery): palms, the beach, the bay, the causeway and the
-- street furniture. Pure, like the rest of the plan: Dev/MapBuilder hands it a Host (the roads as built, the
-- placement grid's checks, a way to add parts) and builds the specs it adds. Edit-mode only (CLAUDE.md hard rule 9).
--
--   Scenery.plan(host)            plans the streetscape, most important first, within Config/CityScenery budget
--                                 streetscapeParts: the palms beside the causeway, the beach, the downtown square, the
--                                 avenues' palms, bus shelters, crossings, then the streets' palms. Returns the parts
--                                 each group added
--   Scenery.instantiate(spec, f)  what the build puts in a templated spec's place (a palm's mesh, or its stand-in)
--   Scenery.Palms / Lamps / Causeway / Water   the pieces MapBuilder's own passes ask for (trees, streetlights, the
--                                 bridge, the lake)
--
-- Modules: Palms (the two-part palms and their templates), Beach, LifeguardStand (C08), Causeway (C09), Water, Lamps,
-- Streets (street palms, shelters, crossings), Square (Town Square), Piece (kit models filed as scenery), Types.
-- Dev/City/Scenery/Preview builds samples to photograph (it requires MapBuilder, so nothing here requires it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BayfrontPark = require(script.BayfrontPark)
local Beach = require(script.Beach)
local Causeway = require(script.Causeway)
local CityScenery = require(ReplicatedStorage.Shared.Config.CityScenery)
local Lamps = require(script.Lamps)
local Palms = require(script.Palms)
local Parking = require(script.Parent.Street.Parking)
local Piece = require(script.Piece)
local Square = require(script.Square)
local Streets = require(script.Streets)
local Types = require(script.Types)
local Water = require(script.Water)

export type Host = Types.Host
export type Street = Types.Street
export type Rect = Types.Rect
export type Report = { [string]: number }

local Scenery = {}

Scenery.Palms = Palms
Scenery.Lamps = Lamps
Scenery.Causeway = Causeway
Scenery.Water = Water
Scenery.Piece = Piece
Scenery.Parking = Parking -- the parked cars (Dev/City/Street/Parking): MapBuilder plans them after the scenery
Scenery.BayfrontPark = BayfrontPark -- the lawn between downtown and the beach: planned right after Scenery.plan

-- Plans every piece of street scenery into `host`. Returns the parts each group added (and `total`).
function Scenery.plan(host: Host): Report
	local ledger: Types.Ledger = { used = 0, limit = CityScenery.budget.streetscapeParts }
	local state: Streets.State = { palms = 0 }
	local report: Report = {}
	report.causewayPalms = Streets.palms(host, ledger, state, function(rule)
		return rule.kind == "bridge"
	end)
	report.beach = Beach.plan(host, ledger)
	report.square = Square.plan(host, ledger)
	report.avenuePalms = Streets.palms(host, ledger, state, function(rule)
		return rule.kind == "arterial"
	end)
	report.shelters = Streets.shelters(host, ledger)
	report.crosswalks = Streets.crosswalks(host, ledger)
	report.streetPalms = Streets.palms(host, ledger, state, function(rule)
		return rule.kind ~= "arterial" and rule.kind ~= "bridge"
	end)
	report.total = ledger.used
	return report
end

-- What the build puts in place of a spec with a template: a clone of its template, or the parts-only stand-in made
-- with `makePart` (Dev/MapBuilder createPart). A parked car's goes through Parking (its colour falls back to the
-- paints that are there, and its nose is found from the template's shape); the rest through Palms.
function Scenery.instantiate(spec: Types.PartSpec, makePart: (Types.PartSpec) -> BasePart): Instance
	if Parking.owns(spec) then
		return Parking.instantiate(spec, makePart)
	end
	return Palms.instantiate(spec, makePart)
end

return Scenery
