--!strict
-- Scenery pieces drawn with the city's building kit (Dev/City/Kit): a lifeguard stand, a bus shelter, a bench, the
-- fountain. A piece gets a Kit model at its own frame (x across it, y up from the ground, z back from its front, which
-- faces the frame's LookVector), is drawn with the Kit's primitives, and then finish() files its parts as scenery:
-- role "scenery" (or the role asked for), in the 500-stud Streetscape tile it stands in, with its night lights in the
-- matching StreetscapeLights tile so the static tiles stay ready for SLIM (docs/city/TECH.md §6), every container
-- registered with the host.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Kit = require(script.Parent.Parent.Kit)
local CityTypes = require(script.Parent.Parent.Types)
local Types = require(script.Parent.Types)

type PartSpec = Types.PartSpec
type Host = Types.Host
type Role = Types.Role

local TILE = 500
local NIGHT_TAG = Environment.nightLights.tag

local Piece = {}

Piece.TILE = TILE
Piece.ROOT = "Streetscape"
Piece.LIGHTS = "StreetscapeLights"

-- The tile key ("3_-1") a plan point stands in.
function Piece.key(x: number, z: number): string
	return `{math.floor(x / TILE)}_{math.floor(z / TILE)}`
end

-- The Streetscape tile (or its lights tile) a plan point stands in, registered with the host.
function Piece.tile(host: Host, x: number, z: number, lights: boolean?): string
	local root = if lights then Piece.LIGHTS else Piece.ROOT
	host.container(root, "Folder")
	local path = `{root}/Tile{Piece.key(x, z)}`
	host.container(path, "Model", Enum.ModelStreamingMode.Atomic, if lights then "Disabled" else "SLIM")
	return path
end

-- A Kit model for a piece named `id` standing at `frame` (its front faces frame.LookVector, so local -Z is out the
-- front). Never mirrored: a piece draws the handedness it means.
function Piece.model(id: string, frame: CFrame, seed: number): CityTypes.Model
	-- A stand-in site: the kit reads only its frame, mirror, id, folder and seed. (Cast, so a field the city's sites
	-- gain later doesn't have to be invented here.)
	local site: CityTypes.Site = (
		{
			id = id,
			archetype = "scenery",
			district = "scenery",
			zone = "",
			frame = frame,
			width = 0,
			depth = 0,
			height = 0,
			maxHeight = math.huge,
			seed = seed,
			variant = { palette = 1, crown = 1, rhythm = 1, mirror = false },
			folder = Piece.ROOT,
			lightsFolder = Piece.LIGHTS,
			plots = {},
			block = 0,
			band = "L",
			face = "road",
			claim = 0,
			corner = { left = false, right = false },
			landmark = false,
			skyline = false,
		} :: any
	) :: CityTypes.Site
	return Kit.model(site)
end

-- Files every part of `m` as scenery in the tile its frame stands in (night lights in the lights tile) and adds it to
-- the host. Returns how many parts it added.
function Piece.finish(host: Host, m: CityTypes.Model, role: Role?): number
	local at = m.frame.Position
	local folder = Piece.tile(host, at.X, at.Z)
	local lights: string? = nil
	for _, spec in m.specs do
		spec.role = role or "scenery"
		if spec.tag == NIGHT_TAG then
			lights = lights or Piece.tile(host, at.X, at.Z, true)
			spec.folder = lights :: string
		else
			spec.folder = folder
		end
		host.add(spec)
	end
	return #m.specs
end

-- Files loose specs (made without a Kit model) the same way, in the tile of `x, z`.
function Piece.file(host: Host, specs: { PartSpec }, x: number, z: number, role: Role?): number
	local folder = Piece.tile(host, x, z)
	for _, spec in specs do
		spec.role = role or spec.role
		if spec.tag == NIGHT_TAG then
			spec.folder = Piece.tile(host, x, z, true)
		else
			spec.folder = folder
		end
		host.add(spec)
	end
	return #specs
end

-- Spends `count` parts from `ledger` when they fit (true), else leaves it as it is (false).
function Piece.take(ledger: Types.Ledger, count: number): boolean
	if ledger.used + count > ledger.limit then
		return false
	end
	ledger.used += count
	return true
end

-- A plan rectangle round a point: `half` across both ways (a square), turned to `u`.
function Piece.square(c: Vector2, half: number, u: Vector2?): Types.Rect
	return { c = c, u = u or Vector2.xAxis, ha = half, hc = half }
end

-- The plan rectangle a frame's local box min..max covers.
function Piece.rect(frame: CFrame, min: Vector3, max: Vector3): Types.Rect
	local mid = frame * ((min + max) / 2)
	local look = Vector2.new(frame.LookVector.X, frame.LookVector.Z)
	local u = if look.Magnitude > 1e-6 then look.Unit else Vector2.yAxis
	return {
		c = Vector2.new(mid.X, mid.Z),
		u = u,
		ha = math.abs(max.Z - min.Z) / 2,
		hc = math.abs(max.X - min.X) / 2,
	}
end

return Piece
