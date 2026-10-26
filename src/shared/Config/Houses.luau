--!strict
-- Houses (PLAN.md Phase 13; docs/phase-13-contracts.md "Houses"): the claimable HousePlots in Riverside, the house
-- built on a claimed plot (its garage door and home charger), the upgrades players buy for it, and what players
-- read.
--
-- The city rebuild (docs/city, 2026-10-25) gives the houses four hand-modelled styles, each after its own real
-- inspiration (named in docs/city/ARCHETYPES.md only, never here), picked per plot (Houses.styleOf):
--   tile_tower_villa     light stucco under low barrel-tile gable roofs, a square stair tower with a tile cap
--                        and twin arched lookout windows, a three-arch loggia with a tile-coped terrace on top, a
--                        walled entry court (ARCHETYPES R01)
--   tropical_modern      two crisp white boxes, the upper one sliding out over the entry and the garage under a
--                        razor-thin roof, floor-to-ceiling glass, a wood slat screen, a stone blade wall and a pool
--                        (ARCHETYPES R06)
--   butterfly_modern     a 1950s seaside modern house: a butterfly roof (a V against the sky) with glazed gable
--                        triangles, a grid screen before the entry, louvred windows, a pastel wall with aluminium
--                        fins, a stone end wall and a V of steel posts
--   coral_rock_cottage   rough tan stone walls under steep coral-red gable roofs, a front gable with an arched
--                        triple window, a porch on white columns (ARCHETYPES R02)
-- Every style shares the garage (Houses.structure): its 16 x 20 bay, the 9-stud door that swings up under the
-- roof, the home charger on its floor and the driveway. Each style dresses the garage in its own roof and trim.
--
-- Read by Services/HouseService (builds the plot signs and the houses under Workspace.<folderName>, outside
-- Workspace.Map.Generated; claims, releases, upgrades, the garage door), Services/EnergyService (the home
-- charger's tag and attributes), Controllers/HouseController and UI/Phone/HomeApp (the Home app), Dev/SocialTests
-- and tests/Houses.spec. The charger math (chargerKW, chargerCostPerFull) and the upgrade checks (cleanUpgrades,
-- buyRefusal) are pure functions here, so the server's decision and the Home app's numbers always agree; the
-- server's decision is the truth.
--
-- Geometry: every offset is the centre of a part in a plot's own frame (Houses.plotFrame: the HousePlot location's
-- centre on the ground, turned to its yaw), in studs: X across the plot, Y up from the ground, Z front to back,
-- with -Z toward the road the plot faces (Config/MapLayout: pads face their road). A HousePlot is 50 x 40 studs
-- (X -25..25, Z -20..20), and every part of every style stays inside it. The house stands at the back on the -X
-- side (X -25..5), the one-car garage at the back on the +X side (X 4.5..23.5) with the home charger painted on its
-- floor, the driveway runs from the garage door to the road, and the sign and mailbox stand at the front by the
-- road. Cars in the catalog are at most 18 long, 7 wide and 6.2 tall (the semi excepted), so the garage's 16 x 20
-- bay and 9-stud door take any of them. Nothing a style adds reaches into the bay or the door's swing
-- (Houses.garageClear).
--
-- Sharpness (docs/city/TECH.md): every facade has two depths (glass and doors stand proud of a rim, trims, sills,
-- piers, eyebrows and roof edges stand 0.3 to 3 proud and throw shadow lines); no two faces are coplanar (laid-on
-- parts stand at least 0.02 proud, a half-disc arch top sits 0.02 behind the rectangle under it); roofs are real
-- sheets of tile with eaves and rakes over stucco gable fills; glass is opaque Glass; small parts cast no shadow.

local Energy = require(script.Parent.Energy)

export type UpgradeId = "fastCharger" | "solarRoof" | "porchLights" | "garden" | "mailbox"

-- One upgrade: bought once with in-game cash, saved in PlayerData.house.upgrades[id] = true, and applied to
-- whichever plot the player claims (and at once to the one they hold). `chargerKW` raises the home charger's
-- power; `costScale` multiplies what home charging costs.
export type Upgrade = {
	id: UpgradeId,
	name: string,
	description: string,
	price: number,
	chargerKW: number?,
	costScale: number?,
}

-- A colour and material (and the glass's shine, or a rail's see-through).
export type Look = { color: Color3, material: Enum.Material, reflectance: number?, transparency: number? }

-- A house's colours: paint slot name -> look. Every style names its own slots (wall, trim, roof, glass...); the
-- shared garage uses "wall", "trim", "paving" and the door "garage", so every palette has those.
export type Palette = { [string]: Look }

export type Shape = "block" | "wedge" | "cylinder" | "ball"

-- One part of the house: its centre in the plot's frame and its size (X across, Y up, Z front to back), before
-- any turn.
--   paint   the palette slot it is painted in; `color` / `material` / `reflectance` override it
--   solid   CanCollide and CanQuery (walls, roofs, floors, columns); false for trims, glass on walls, markings and
--           everything cars and rays pass through
--   shape   "wedge" (a WedgePart: its slope rises from its front edge to its back edge), "cylinder" (its axis is
--           its X), "ball"; nil is a block
--   rotation  a turn applied first (corner wedges are built from axis vectors), then:
--   tilt    degrees about X (roof sheets sloping front to back, solar panels)
--   turn    degrees about Y (a wedge facing another way, a cylinder along Z)
--   roll    degrees about Z (roof sheets sloping across, a cylinder standing up)
--   shadow  casts a shadow; nil: yes, unless it is thin both ways across (under 1 stud on two axes) or see-through
--   glow    a PointLight (Houses.porchLight) inside it
--   night   a night light: a Config/Environment nightLights kind. Services/HouseService tags the part
--           nightLights.tag with that kind and its day colour, and Services/DayNightService lights it from dusk to
--           dawn (with any PointLight in it) like the county's windows and streetlights
export type Piece = {
	name: string,
	offset: Vector3,
	size: Vector3,
	paint: string?,
	color: Color3?,
	material: Enum.Material?,
	reflectance: number?,
	transparency: number?,
	solid: boolean,
	shape: Shape?,
	rotation: CFrame?,
	tilt: number?,
	turn: number?,
	roll: number?,
	shadow: boolean?,
	glow: boolean?,
	night: string?,
}

-- One house style: its own parts (besides Houses.structure, the door, the charger bay and the sensor), what each
-- upgrade adds to it (porch lights, garden, solar panels: they sit where that style's door, beds and roof are; the
-- mailbox is shared, Houses.extras), and its palettes (one picked per plot).
export type Variant = {
	id: string,
	pieces: { Piece },
	extras: { [string]: { Piece } },
	palettes: { Palette },
}

-- A box in a plot's frame (Houses.garageClear).
export type Zone = { offset: Vector3, size: Vector3 }

export type Light = { range: number, brightness: number, color: Color3 }

-- Why an upgrade can't be bought (nil: it can).
export type BuyRefusal = "unknown" | "owned" | "cash"

local rgb = Color3.fromRGB
local v3 = Vector3.new

local PERCENT = 100 -- home prices stay whole dollars per percent (multiples of this per full charge)
local LIFT = 0.02 -- a roof sheet stands this far off the gable fill under it, so no two faces are coplanar
local PANEL_LIFT = 0.15 -- solar panels stand this far off the roof
local PANEL_THICK = 0.2
-- An arch drawn as an opening with its two top corners filled: legs of this share of the radius make the fill's
-- slope touch the round arch it stands for (2 - sqrt 2).
local CHAMFER = 2 - math.sqrt(2)
local DOWN = v3(0, -1, 0)
local EAST = v3(1, 0, 0)
local WEST = v3(-1, 0, 0)

local ACCENT = rgb(92, 196, 255) -- the charger's light and bay (Config/Controls theme accent)
local WARM_LIGHT = rgb(255, 214, 150)
local TRIM = rgb(70, 74, 80)

-- Shared looks.
local function look(color: Color3, material: Enum.Material, reflectance: number?, transparency: number?): Look
	return { color = color, material = material, reflectance = reflectance, transparency = transparency }
end

local LEAF = look(rgb(62, 120, 64), Enum.Material.LeafyGrass)
local HEDGE = look(rgb(70, 128, 70), Enum.Material.Grass)
local SOIL = look(rgb(76, 58, 44), Enum.Material.Ground)
local POT = look(rgb(178, 96, 68), Enum.Material.CeramicTiles)
local LAMP = look(WARM_LIGHT, Enum.Material.Neon)
local LAMP_IRON = look(rgb(36, 36, 38), Enum.Material.Metal)
local PANEL = look(rgb(34, 52, 90), Enum.Material.Glass, 0.2)
local PANEL_RAIL = look(rgb(176, 182, 190), Enum.Material.Metal)
local RAIL_GLASS = look(rgb(207, 232, 236), Enum.Material.Glass, 0.1, 0.55)
local WINDOW_GLASS = look(rgb(40, 70, 86), Enum.Material.Glass, 0.15)

---------------------------------------------------------------------------------------------------------------------
-- Modelling helpers (pure: each returns pieces in the plot's frame)
---------------------------------------------------------------------------------------------------------------------

type Paint = string | Look
type Side = "back" | "front" | "left" | "right"
type Axis = "x" | "y" | "z"

-- A wall face: which way it looks (front -Z toward the road, back +Z, left -X, right +X) and where its plane is.
-- Along a front or back face `u` is X; along a left or right face it is Z. `out` is measured outward from the plane.
type Face = { normal: Side, plane: number }

local function painted(piece: Piece, paint: Paint): Piece
	if type(paint) == "string" then
		piece.paint = paint
	else
		piece.color = paint.color
		piece.material = paint.material
		piece.reflectance = paint.reflectance
		piece.transparency = paint.transparency
	end
	return piece
end

local function lit(piece: Piece, kind: string): Piece
	piece.night = kind
	return piece
end

-- A porch lamp: a warm night light with a PointLight (Houses.porchLight) in it.
local function lamp(piece: Piece): Piece
	piece.night = "streetlight"
	piece.glow = true
	return piece
end

local function shadowed(piece: Piece, casts: boolean): Piece
	piece.shadow = casts
	return piece
end

-- A block between two corners.
local function box(name: string, a: Vector3, b: Vector3, paint: Paint, solid: boolean?): Piece
	local lo, hi = a:Min(b), a:Max(b)
	return painted({ name = name, offset = (lo + hi) / 2, size = hi - lo, solid = solid == true }, paint)
end

-- A cylinder centred at `centre` along an axis.
local function cylinder(
	name: string,
	centre: Vector3,
	axis: Axis,
	length: number,
	diameter: number,
	paint: Paint,
	solid: boolean?
): Piece
	return painted({
		name = name,
		offset = centre,
		size = v3(length, diameter, diameter),
		solid = solid == true,
		shape = "cylinder",
		roll = if axis == "y" then 90 else nil,
		turn = if axis == "z" then 90 else nil,
	}, paint)
end

-- A cylinder from `a` to `b` in any direction (posts, struts).
local function strut(name: string, a: Vector3, b: Vector3, diameter: number, paint: Paint, solid: boolean?): Piece
	local d = b - a
	return painted({
		name = name,
		offset = (a + b) / 2,
		size = v3(d.Magnitude, diameter, diameter),
		solid = solid == true,
		shape = "cylinder",
		-- lookAt sends -Z along d; a quarter turn about Y first sends the cylinder's X axis there.
		rotation = CFrame.lookAt(Vector3.zero, d) * CFrame.Angles(0, math.rad(90), 0),
	}, paint)
end

local function ball(name: string, centre: Vector3, diameter: number, paint: Paint, solid: boolean?): Piece
	return painted({
		name = name,
		offset = centre,
		size = v3(diameter, diameter, diameter),
		solid = solid == true,
		shape = "ball",
	}, paint)
end

local RISE_TURN: { [Side]: number } = { back = 0, front = 180, right = 90, left = -90 }

-- A wedge filling the box between two corners, its slope rising toward `rise` (its high edge on that side).
local function wedge(name: string, a: Vector3, b: Vector3, rise: Side, paint: Paint, solid: boolean?): Piece
	local lo, hi = a:Min(b), a:Max(b)
	local s = hi - lo
	local across = rise == "left" or rise == "right"
	return painted({
		name = name,
		offset = (lo + hi) / 2,
		size = if across then v3(s.Z, s.Y, s.X) else s,
		solid = solid == true,
		shape = "wedge",
		turn = RISE_TURN[rise],
	}, paint)
end

-- A right-angled corner fill (a wedge seen end-on): its right angle at `at` (the middle of its depth), one leg
-- `lenA` long along `dirA`, the other `lenB` along `dirB` (unit axis vectors), `depth` thick across both. Arches:
-- one in each top corner of an opening turns it into an arch with chamfered haunches.
local function corner(
	name: string,
	at: Vector3,
	dirA: Vector3,
	lenA: number,
	dirB: Vector3,
	lenB: number,
	depth: number,
	paint: Paint,
	solid: boolean?
): Piece
	-- A WedgePart's right angle is its bottom back edge: its Y leg runs up the back face, its Z leg forward along
	-- the bottom. So its Y goes along dirA and its -Z along dirB.
	local backward = -dirB
	return painted({
		name = name,
		offset = at + dirA * (lenA / 2) + dirB * (lenB / 2),
		size = v3(depth, lenA, lenB),
		solid = solid == true,
		shape = "wedge",
		rotation = CFrame.fromMatrix(Vector3.zero, dirA:Cross(backward), dirA, backward),
	}, paint)
end

-- A roof plane: where its top surface starts (above the low edge's middle), the way up it, its outward normal,
-- the way along it (the ridge's direction), and the sheet's turn (tilt for a slope front to back, roll across).
type Slope = { origin: Vector3, up: Vector3, normal: Vector3, along: Vector3, tilt: number?, roll: number? }

-- A sheet of roof `thick` thick whose bottom surface runs from the line through `low` to the line through `high`
-- (both lines along the ridge, `length` long, centred on those points). `low` and `high` differ in height and in
-- X or Z only.
local function sheet(
	name: string,
	low: Vector3,
	high: Vector3,
	length: number,
	thick: number,
	paint: Paint,
	solid: boolean?
): (Piece, Slope)
	local d = high - low
	local acrossX = math.abs(d.X) > math.abs(d.Z)
	local run = if acrossX then math.abs(d.X) else math.abs(d.Z)
	local angle = math.atan2(d.Y, run)
	local c, s = math.cos(angle), math.sin(angle)
	local normal: Vector3, along: Vector3, size: Vector3 = Vector3.yAxis, Vector3.xAxis, Vector3.one
	local tilt: number?, roll: number? = nil, nil
	if acrossX then
		local sign = if d.X > 0 then 1 else -1
		normal = v3(-sign * s, c, 0)
		along = v3(0, 0, 1)
		size = v3(d.Magnitude, thick, length)
		roll = sign * math.deg(angle)
	else
		local sign = if d.Z > 0 then 1 else -1
		normal = v3(0, c, -sign * s)
		along = v3(1, 0, 0)
		size = v3(length, thick, d.Magnitude)
		tilt = -sign * math.deg(angle)
	end
	local piece = painted({
		name = name,
		offset = (low + high) / 2 + normal * (thick / 2 + LIFT),
		size = size,
		solid = solid ~= false,
		tilt = tilt,
		roll = roll,
	}, paint)
	local slope: Slope = {
		origin = low + normal * (thick + LIFT),
		up = d.Unit,
		normal = normal,
		along = along,
		tilt = tilt,
		roll = roll,
	}
	return piece, slope
end

-- A flat panel lying on a roof plane: `at` studs up the slope from its low edge, `side` studs along the ridge from
-- the sheet's middle; `width` along the ridge, `depth` up the slope.
local function onSlope(name: string, slope: Slope, at: number, side: number, width: number, depth: number): Piece
	return painted({
		name = name,
		offset = slope.origin + slope.up * at + slope.along * side + slope.normal * (PANEL_THICK / 2 + PANEL_LIFT),
		size = if slope.roll ~= nil then v3(depth, PANEL_THICK, width) else v3(width, PANEL_THICK, depth),
		solid = false,
		tilt = slope.tilt,
		roll = slope.roll,
	}, PANEL)
end

type Gable = { pieces: { Piece }, a: Slope, b: Slope, ridgeY: number }

-- A gable roof over walls that stop at `top`: two stucco fills (the gable ends are their triangles), two sheets of
-- tile `thick` thick with eaves past the two eave walls and a rake past both gable ends, and a barrel ridge.
-- axis "x": the ridge runs along X from lo to hi, the eave walls are at z = wallA (front) and wallB (back).
-- axis "z": the ridge runs along Z from lo to hi, the eave walls are at x = wallA (left) and wallB (right).
local function gable(
	prefix: string,
	axis: "x" | "z",
	lo: number,
	hi: number,
	wallA: number,
	wallB: number,
	top: number,
	rise: number,
	eaveA: number,
	eaveB: number,
	rake: number,
	thick: number,
	fill: Paint,
	roof: Paint
): Gable
	local mid = (wallA + wallB) / 2
	local slope = rise / ((wallB - wallA) / 2)
	local centre = (lo + hi) / 2
	local length = hi - lo + 2 * rake
	local function at(across: number, y: number): Vector3
		return if axis == "x" then v3(centre, y, across) else v3(across, y, centre)
	end
	local pieces: { Piece } = {}
	if axis == "x" then
		table.insert(pieces, wedge(prefix .. "FillA", v3(lo, top, wallA), v3(hi, top + rise, mid), "back", fill, true))
		table.insert(pieces, wedge(prefix .. "FillB", v3(lo, top, mid), v3(hi, top + rise, wallB), "front", fill, true))
	else
		table.insert(pieces, wedge(prefix .. "FillA", v3(wallA, top, lo), v3(mid, top + rise, hi), "right", fill, true))
		table.insert(pieces, wedge(prefix .. "FillB", v3(mid, top, lo), v3(wallB, top + rise, hi), "left", fill, true))
	end
	local ridge = at(mid, top + rise)
	local sheetA, slopeA = sheet(prefix .. "RoofA", at(wallA - eaveA, top - eaveA * slope), ridge, length, thick, roof)
	local sheetB, slopeB = sheet(prefix .. "RoofB", at(wallB + eaveB, top - eaveB * slope), ridge, length, thick, roof)
	table.insert(pieces, sheetA)
	table.insert(pieces, sheetB)
	-- Where the two sheets' top surfaces meet over the ridge line.
	local ridgeY = top + rise + (thick + LIFT) / math.cos(math.atan(slope))
	local cap = thick + 0.5
	table.insert(pieces, cylinder(prefix .. "Ridge", at(mid, ridgeY - cap * 0.25), axis, length, cap, roof))
	return { pieces = pieces, a = slopeA, b = slopeB, ridgeY = ridgeY }
end

-- A box on a wall face: `u0..u1` along it, `y0..y1` up it, `out0..out1` outward from its plane.
local function faceBox(
	name: string,
	f: Face,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	out0: number,
	out1: number,
	paint: Paint,
	solid: boolean?
): Piece
	local p = f.plane
	if f.normal == "front" then
		return box(name, v3(u0, y0, p - out1), v3(u1, y1, p - out0), paint, solid)
	elseif f.normal == "back" then
		return box(name, v3(u0, y0, p + out0), v3(u1, y1, p + out1), paint, solid)
	elseif f.normal == "left" then
		return box(name, v3(p - out1, y0, u0), v3(p - out0, y1, u1), paint, solid)
	end
	return box(name, v3(p + out0, y0, u0), v3(p + out1, y1, u1), paint, solid)
end

-- A disc on a wall face (its axis through the wall), centred at `u`, `y`, from `out0` to `out1` outward.
local function faceDisc(
	name: string,
	f: Face,
	u: number,
	y: number,
	out0: number,
	out1: number,
	diameter: number,
	paint: Paint
): Piece
	local p, middle, length = f.plane, (out0 + out1) / 2, out1 - out0
	if f.normal == "front" then
		return cylinder(name, v3(u, y, p - middle), "z", length, diameter, paint)
	elseif f.normal == "back" then
		return cylinder(name, v3(u, y, p + middle), "z", length, diameter, paint)
	elseif f.normal == "left" then
		return cylinder(name, v3(p - middle, y, u), "x", length, diameter, paint)
	end
	return cylinder(name, v3(p + middle, y, u), "x", length, diameter, paint)
end

-- A window: glass (lit at night) standing 0.25 proud in front of a rim `rim` wider on every side.
local function window(
	prefix: string,
	f: Face,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	rim: number,
	rimPaint: Paint
): { Piece }
	return {
		faceBox(prefix .. "Rim", f, u0 - rim, u1 + rim, y0 - rim, y1 + rim, -0.1, 0.15, rimPaint),
		lit(faceBox(prefix .. "Glass", f, u0, u1, y0, y1, -0.1, 0.25, "glass"), "window"),
	}
end

-- An arched window: an upright rectangle from `sill` to `spring` under a half-disc, glass in front of a rim. Each
-- half-disc sits 0.02 behind its rectangle, so their faces never share a plane.
local function archWindow(
	prefix: string,
	f: Face,
	u: number,
	sill: number,
	spring: number,
	width: number,
	rim: number,
	rimPaint: Paint
): { Piece }
	local half = width / 2
	return {
		faceBox(prefix .. "Rim", f, u - half - rim, u + half + rim, sill - rim, spring, -0.1, 0.15, rimPaint),
		faceDisc(prefix .. "RimArch", f, u, spring, -0.1, 0.13, width + 2 * rim, rimPaint),
		lit(faceBox(prefix .. "Glass", f, u - half, u + half, sill, spring, -0.1, 0.25, "glass"), "window"),
		lit(faceDisc(prefix .. "Arch", f, u, spring, -0.1, 0.23, width, "glass"), "window"),
	}
end

-- Shutters either side of a window (its glass from u0 to u1, y0 to y1, its rim `rim` wide).
local function shutters(
	prefix: string,
	f: Face,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	rim: number,
	width: number
): { Piece }
	return {
		faceBox(prefix .. "ShutterA", f, u0 - rim - 0.1 - width, u0 - rim - 0.1, y0, y1, -0.1, 0.3, "shutter"),
		faceBox(prefix .. "ShutterB", f, u1 + rim + 0.1, u1 + rim + 0.1 + width, y0, y1, -0.1, 0.3, "shutter"),
	}
end

local function append(list: { Piece }, more: { Piece })
	for _, piece in more do
		table.insert(list, piece)
	end
end

-- A palette from a base and the slots one colour set changes.
local function palette(base: Palette, changes: Palette): Palette
	local merged = table.clone(base)
	for slot, value in changes do
		merged[slot] = value
	end
	return merged
end

---------------------------------------------------------------------------------------------------------------------
-- The shared garage (every style). Its walls, header and roof slab are painted in the style's colours.
---------------------------------------------------------------------------------------------------------------------

-- The garage's front face (its walls and header stop at z = -3).
local GARAGE_FRONT: Face = { normal = "front", plane = -3 }
-- The garage's right side (its outer wall's face).
local GARAGE_SIDE: Face = { normal = "right", plane = 23 }

-- One slab under the driveway and the garage bay, from the road edge to the back wall: concrete whatever the
-- palette's paving colour (cars drive on it).
local floorSlab = box("Floor", v3(6, 0, -20), v3(22, 0.35, 19), "paving", true)
floorSlab.material = Enum.Material.Concrete

local structure: { Piece } = {
	box("GarageWallInner", v3(5, 0, -3), v3(6, 11, 19), "wall", true),
	box("GarageWallOuter", v3(22, 0, -3), v3(23, 11, 19), "wall", true),
	box("GarageWallBack", v3(6, 0, 18), v3(22, 11, 19), "wall", true),
	box("GarageRoof", v3(4.5, 11, -4), v3(23.5, 12, 20), "trim", true),
	box("GarageHeader", v3(6, 9, -3), v3(22, 11, -2), "wall", true),
	floorSlab,
	box("Charger", v3(13, 2, 17.2), v3(15, 5, 18), look(rgb(40, 44, 52), Enum.Material.SmoothPlastic), true),
	box("ChargerLight", v3(13.4, 4.25, 17.1), v3(14.6, 4.55, 17.2), look(ACCENT, Enum.Material.Neon)),
}

---------------------------------------------------------------------------------------------------------------------
-- Style 1: tile_tower_villa
---------------------------------------------------------------------------------------------------------------------

local function towerVilla(): Variant
	local p: { Piece } = {}

	-- The main block: two storeys, 20 x 15, its front behind the loggia.
	table.insert(p, box("Body", v3(-24, -0.5, 4), v3(-4.2, 21, 19), "wall", true))
	table.insert(p, box("BodyPlinth", v3(-24.3, 0, 3.9), v3(-23.9, 1.2, 19), "stone"))
	local main = gable("Main", "x", -24, -4.2, 4, 19, 21, 3.8, 1.5, 0.5, 0.9, 0.8, "wall", "roof")
	append(p, main.pieces)
	table.insert(p, box("MainCornice", v3(-24.3, 20, 3.55), v3(-4.2, 20.7, 4), "stone"))
	-- Upstairs, two arched glass doors onto the loggia's terrace.
	local front: Face = { normal = "front", plane = 4 }
	for _, door in { { "UpperDoorL", -18 }, { "UpperDoorR", -10 } } :: { { any } } do
		local name, x = door[1] :: string, door[2] :: number
		append(p, archWindow(name, front, x, 12.8, 17.9, 3.2, 0.4, "stone"))
		table.insert(p, faceBox(name .. "Bar", front, x - 0.12, x + 0.12, 12.8, 19.4, 0.2, 0.32, "iron"))
	end
	-- The side the street sees past the court wall: two shuttered windows with sills.
	local left: Face = { normal = "left", plane = -24 }
	for _, row in { { "SideLow", 3.2 }, { "SideHigh", 13.2 } } :: { { any } } do
		local name, y = row[1] :: string, row[2] :: number
		append(p, window(name, left, 9.5, 12.5, y, y + 5, 0.35, "stone"))
		append(p, shutters(name, left, 9.5, 12.5, y, y + 5, 0.35, 1.5))
		table.insert(p, faceBox(name .. "Sill", left, 8.8, 13.2, y - 0.75, y - 0.35, -0.1, 0.5, "stone"))
	end
	-- The chimney through the back slope.
	table.insert(p, box("Chimney", v3(-21, 19, 13.5), v3(-18.6, 28, 15.9), "wall", true))
	table.insert(p, box("ChimneyCap", v3(-21.3, 28, 13.2), v3(-18.3, 28.5, 16.2), "stone"))
	table.insert(p, box("ChimneyHood", v3(-20.5, 28.5, 13.9), v3(-19.1, 29.3, 15.5), "wall"))

	-- The tower: 29 tall by the garage, the entrance in its foot, a lookout under a steep tile cap.
	table.insert(p, box("Tower", v3(-4.4, -0.5, -2.6), v3(4.7, 29, 6.2), "wall", true))
	local cap = gable("Tower", "x", -4.4, 4.7, -2.6, 6.2, 29, 3.8, 0.8, 0.8, 0.8, 0.7, "wall", "roof")
	append(p, cap.pieces)
	table.insert(p, ball("TowerFinial", v3(0.15, cap.ridgeY + 0.6, 1.8), 0.9, "stone"))
	table.insert(p, box("TowerCornice", v3(-4.9, 27.4, -3.1), v3(5.2, 28.2, 6.7), "stone"))
	table.insert(p, box("TowerString", v3(-4.7, 11.4, -2.95), v3(5, 12, -2.6), "stone"))
	local tower: Face = { normal = "front", plane = -2.6 }
	-- The entrance: an arched wooden door between stone pilasters under a lintel, on a stone step.
	table.insert(p, faceBox("FrontDoor", tower, -1.55, 1.85, 0.5, 6, -0.1, 0.2, "door", true))
	table.insert(p, faceDisc("FrontDoorArch", tower, 0.15, 6, -0.1, 0.18, 3.4, "door"))
	table.insert(p, faceBox("PortalLeft", tower, -2.75, -2.05, 0, 8.6, -0.1, 0.5, "stone"))
	table.insert(p, faceBox("PortalRight", tower, 2.35, 3.05, 0, 8.6, -0.1, 0.5, "stone"))
	table.insert(p, faceBox("PortalLintel", tower, -3, 3.3, 8.6, 9.5, -0.1, 0.65, "stone"))
	table.insert(p, box("DoorStep", v3(-2.6, 0, -4.2), v3(2.9, 0.5, -2.6), "stone", true))
	-- Halfway up, an arched window on a sill.
	append(p, archWindow("TowerWindow", tower, 0.15, 13.4, 16.6, 2.6, 0.35, "stone"))
	-- Its stone ledge carries a wrought-iron balcony: a rail on two end posts and three balusters.
	table.insert(p, faceBox("TowerBalcony", tower, -1.95, 2.25, 12.65, 13.05, -0.1, 1.1, "stone"))
	table.insert(p, faceBox("TowerBalconyRail", tower, -1.95, 2.25, 14.55, 14.75, 0.9, 1.1, "iron"))
	for index, x in { -1.85, -0.55, 0.15, 0.85, 2.15 } do
		local post = faceBox(`TowerBalconyBar{index}`, tower, x - 0.07, x + 0.07, 13.05, 14.55, 0.94, 1.06, "iron")
		table.insert(p, post)
	end
	-- The lookout: twin arches either side of a slim column, in one stone frame.
	table.insert(p, faceBox("LookoutRim", tower, -2.5, 2.8, 20.6, 25.6, -0.1, 0.15, "stone"))
	for _, arch in { { "LookoutLeft", -1.05 }, { "LookoutRight", 1.35 } } :: { { any } } do
		local name, x = arch[1] :: string, arch[2] :: number
		table.insert(p, lit(faceBox(name .. "Glass", tower, x - 0.9, x + 0.9, 21, 23.9, -0.1, 0.25, "glass"), "window"))
		table.insert(p, lit(faceDisc(name .. "Arch", tower, x, 23.9, -0.1, 0.23, 1.8, "glass"), "window"))
	end
	table.insert(p, cylinder("LookoutColumn", v3(0.15, 22.45, -2.95), "y", 2.9, 0.45, "stone"))
	table.insert(p, faceBox("LookoutSill", tower, -2.7, 3, 20.2, 20.6, -0.1, 0.55, "stone"))
	local towerSide: Face = { normal = "right", plane = 4.7 }
	table.insert(p, lit(faceBox("LookoutSideGlass", towerSide, 0.6, 2.6, 21.4, 24, -0.1, 0.25, "glass"), "window"))
	table.insert(p, lit(faceDisc("LookoutSideArch", towerSide, 1.6, 24, -0.1, 0.23, 2, "glass"), "window"))
	-- Behind the tower, a one-storey wing up to the garage.
	table.insert(p, box("Wing", v3(-4.2, -0.5, 6), v3(4.95, 12, 19), "wall", true))
	table.insert(p, box("WingCap", v3(-4.2, 12, 6.2), v3(4.95, 12.4, 19.3), "stone"))

	-- The loggia: three arches on piers in front of the main block, its roof a terrace with a tile-coped wall.
	table.insert(p, box("LoggiaFloor", v3(-22.75, 0, -2.5), v3(-4.4, 0.5, 4), "floor", true))
	table.insert(p, box("LoggiaRoof", v3(-23.1, 11, -2.9), v3(-4.4, 12.4, 4.2), "stone", true))
	local spring, radius = 6.6, 2.165
	local crown = spring + radius
	local leg = CHAMFER * radius
	for index, pier in { { -22.8, -21 }, { -16.67, -14.87 }, { -10.53, -8.73 } } do
		table.insert(p, box(`Pier{index}`, v3(pier[1], -0.5, -2.6), v3(pier[2], 11, -1.2), "wall", true))
		table.insert(p, box(`Pier{index}Cap`, v3(pier[1] - 0.2, 6.2, -2.8), v3(pier[2] + 0.2, 6.6, -1), "stone"))
	end
	-- The wall over the arches stands 0.05 behind the piers' faces (no shared plane; the piers read as pilasters).
	table.insert(p, box("Arcade", v3(-22.75, crown, -2.55), v3(-4.4, 11, -1.2), "wall", true))
	for index, opening in { { -21, -16.67 }, { -14.87, -10.53 }, { -8.73, -4.4 } } do
		local xa, xb = opening[1], opening[2]
		table.insert(p, corner(`Arch{index}A`, v3(xa, crown, -1.9), DOWN, leg, EAST, leg, 1.4, "wall"))
		table.insert(p, corner(`Arch{index}B`, v3(xb, crown, -1.9), DOWN, leg, WEST, leg, 1.4, "wall"))
		local x = (xa + xb) / 2
		table.insert(p, box(`Key{index}`, v3(x - 0.45, crown - 0.15, -2.75), v3(x + 0.45, crown + 1, -2.6), "stone"))
	end
	table.insert(p, box("TerraceWall", v3(-23.1, 12.4, -2.9), v3(-4.4, 14.6, -2.3), "wall", true))
	table.insert(p, box("TerraceWallSide", v3(-23.1, 12.4, -2.3), v3(-22.5, 14.6, 4), "wall", true))
	table.insert(p, box("TerraceCoping", v3(-23.3, 14.6, -3.05), v3(-4.4, 15, -2.15), "roof"))
	table.insert(p, box("TerraceCopingSide", v3(-23.3, 14.6, -2.15), v3(-22.35, 15, 4), "roof"))
	-- Inside the loggia: two windows and a glass door, lit at night through the arches.
	append(p, window("LoggiaWindowL", front, -20.1, -17.6, 2.6, 8, 0.35, "stone"))
	append(p, window("LoggiaWindowR", front, -13.95, -11.45, 2.6, 8, 0.35, "stone"))
	append(p, window("LoggiaDoor", front, -7.9, -5.3, 0.5, 8.2, 0.35, "stone"))

	-- The entry court: a low stucco wall with tile coping, a pier and an urn where it opens to the lawn.
	table.insert(p, box("CourtWallSide", v3(-24.4, -0.5, -9), v3(-23.7, 3.4, 4), "wall", true))
	table.insert(p, box("CourtWallFront", v3(-24.4, -0.5, -9.7), v3(-15.2, 3.4, -9), "wall", true))
	table.insert(p, box("CourtCopingSide", v3(-24.6, 3.4, -8.8), v3(-23.5, 3.8, 4), "roof"))
	table.insert(p, box("CourtCopingFront", v3(-24.6, 3.4, -9.9), v3(-15.2, 3.8, -8.8), "roof"))
	table.insert(p, box("CourtPier", v3(-15.6, -0.5, -10), v3(-14.2, 4.6, -8.6), "wall", true))
	table.insert(p, box("CourtPierCap", v3(-15.8, 4.6, -10.2), v3(-14, 4.95, -8.4), "stone"))
	table.insert(p, ball("CourtUrn", v3(-14.9, 5.45, -9.3), 1.1, "stone"))
	table.insert(p, shadowed(box("Path", v3(-1.5, 0, -20), v3(1.8, 0.12, -4.2), "stone"), false))

	-- The garage in the same language: a low tile gable, stone pilasters and a lintel round the door, a vent.
	local garage = gable("Garage", "x", 4.7, 23, -4, 19.6, 12, 3.4, 1, 0, 0.6, 0.7, "wall", "roof")
	append(p, garage.pieces)
	table.insert(p, faceBox("GaragePierL", GARAGE_FRONT, 4.7, 6, 0, 9.2, -0.1, 0.45, "stone"))
	table.insert(p, faceBox("GaragePierR", GARAGE_FRONT, 22, 23.4, 0, 9.2, -0.1, 0.45, "stone"))
	table.insert(p, faceBox("GarageLintel", GARAGE_FRONT, 4.7, 23.4, 9.2, 10.4, -0.1, 0.5, "stone"))
	table.insert(p, faceDisc("GarageVent", GARAGE_SIDE, 7.8, 13.3, -0.1, 0.15, 1.5, "stone"))

	local extras: { [string]: { Piece } } = {
		-- Iron lanterns either side of the tower door.
		porchLights = {
			lamp(box("PorchLightLeft", v3(-3.9, 5.6, -3.4), v3(-3.2, 6.8, -2.75), LAMP)),
			lamp(box("PorchLightRight", v3(3.5, 5.6, -3.4), v3(4.2, 6.8, -2.75), LAMP)),
			box("PorchLampLeftCap", v3(-4, 6.8, -3.5), v3(-3.1, 7.1, -2.6), LAMP_IRON),
			box("PorchLampRightCap", v3(3.4, 6.8, -3.5), v3(4.3, 7.1, -2.6), LAMP_IRON),
		},
		-- Hedges and bougainvillea inside the court walls, and potted plants by the door.
		garden = {
			box("HedgeLeft", v3(-23.6, 0, -8.8), v3(-22.2, 2.6, -2.8), HEDGE, true),
			box("FlowersLeft", v3(-23.5, 2.6, -8.6), v3(-22.3, 3, -3), look(rgb(214, 60, 140), Enum.Material.Grass)),
			box("HedgeRight", v3(-22.2, 0, -8.9), v3(-15.8, 2, -7.5), HEDGE, true),
			box("FlowersRight", v3(-22, 2, -8.8), v3(-16, 2.4, -7.6), look(rgb(232, 96, 168), Enum.Material.Grass)),
			cylinder("PotLeft", v3(-3.55, 0.7, -3.75), "y", 1.4, 1, POT, true),
			ball("PotPlantLeft", v3(-3.55, 2, -3.75), 1.4, LEAF),
			cylinder("PotRight", v3(3.85, 0.7, -3.75), "y", 1.4, 1, POT, true),
			ball("PotPlantRight", v3(3.85, 2, -3.75), 1.4, LEAF),
		},
		-- Two panels on the main roof's street slope.
		solarRoof = {
			onSlope("SolarPanelLeft", main.a, 5.6, -4.6, 7.6, 5),
			onSlope("SolarPanelRight", main.a, 5.6, 4, 7.6, 5),
		},
	}

	local base: Palette = {
		wall = look(rgb(246, 240, 228), Enum.Material.Plaster),
		trim = look(rgb(224, 210, 184), Enum.Material.Limestone),
		stone = look(rgb(224, 210, 184), Enum.Material.Limestone),
		roof = look(rgb(184, 86, 56), Enum.Material.ClayRoofTiles),
		shutter = look(rgb(62, 107, 84), Enum.Material.SmoothPlastic),
		door = look(rgb(88, 56, 36), Enum.Material.Wood),
		iron = look(rgb(40, 40, 42), Enum.Material.Metal),
		floor = look(rgb(178, 96, 68), Enum.Material.CeramicTiles),
		paving = look(rgb(206, 190, 166), Enum.Material.Concrete),
		garage = look(rgb(96, 64, 42), Enum.Material.Wood),
		glass = WINDOW_GLASS,
	}
	return {
		id = "tile_tower_villa",
		pieces = p,
		extras = extras,
		palettes = {
			base,
			palette(base, {
				wall = look(rgb(240, 222, 186), Enum.Material.Plaster),
				roof = look(rgb(196, 104, 62), Enum.Material.ClayRoofTiles),
				shutter = look(rgb(52, 84, 112), Enum.Material.SmoothPlastic),
			}),
			palette(base, {
				wall = look(rgb(242, 198, 184), Enum.Material.Plaster),
				stone = look(rgb(236, 226, 206), Enum.Material.Limestone),
				trim = look(rgb(236, 226, 206), Enum.Material.Limestone),
				roof = look(rgb(176, 80, 52), Enum.Material.ClayRoofTiles),
			}),
			palette(base, {
				wall = look(rgb(230, 192, 130), Enum.Material.Plaster),
				roof = look(rgb(170, 78, 50), Enum.Material.ClayRoofTiles),
				shutter = look(rgb(96, 64, 44), Enum.Material.Wood),
				garage = look(rgb(70, 46, 32), Enum.Material.Wood),
			}),
		},
	}
end

---------------------------------------------------------------------------------------------------------------------
-- Style 2: tropical_modern
---------------------------------------------------------------------------------------------------------------------

local function tropicalModern(): Variant
	local p: { Piece } = {}

	-- The ground floor: a white box glazed floor to ceiling in the shade of the overhang, its entry wall on the left
	-- with a tall wood pivot door.
	table.insert(p, box("Body", v3(-21.6, -0.5, 6), v3(4.95, 11.4, 19), "wall", true))
	table.insert(p, lit(box("GroundGlass", v3(-15.4, 0.3, 5.75), v3(4.6, 11.2, 6.1), "glass"), "window"))
	for index, x in { -10.4, -5.4, -0.4 } do
		table.insert(p, box(`GroundMullion{index}`, v3(x - 0.15, 0.3, 5.6), v3(x + 0.15, 11.2, 5.8), "frame"))
	end
	table.insert(p, box("FrontDoor", v3(-20.3, 0.3, 5.75), v3(-16.9, 10.2, 6.1), "wood", true))
	table.insert(p, box("DoorPull", v3(-17.55, 3.5, 5.55), v3(-17.35, 7.5, 5.8), "frame"))
	table.insert(p, box("EntryTerrace", v3(-23.4, 0, -1.4), v3(4.9, 0.3, 6), "stone", true))
	-- A stone blade wall the upper box seems to rest on.
	table.insert(p, box("StoneBlade", v3(-24.2, -0.5, -1.6), v3(-23.2, 11.4, 13), "stone", true))

	-- The upper box: 34 wide, sliding 7 out over the glass and half across the garage, its glass set 2.6 back in a
	-- white frame under a thin roof slab that overhangs it all round.
	table.insert(p, box("UpperFloor", v3(-24.2, 11.4, -1.4), v3(10.2, 12.4, 15.5), "wall", true))
	table.insert(p, box("Upper", v3(-23.8, 12.4, 1.4), v3(9.8, 21.2, 15), "wall", true))
	table.insert(p, box("Roof", v3(-24.9, 21.2, -2.8), v3(11.8, 22, 16.6), "trim", true))
	table.insert(p, box("FinLeft", v3(-24.2, 12.4, -1.4), v3(-23.4, 21.2, 1.4), "wall", true))
	table.insert(p, box("FinRight", v3(9.4, 12.4, -1.4), v3(10.2, 21.2, 1.4), "wall", true))
	table.insert(p, lit(box("UpperGlass", v3(-23.4, 12.4, 1.2), v3(9.4, 21.2, 1.5), "glass"), "window"))
	for index, x in { -17.6, -11.8, -6, -0.2 } do
		table.insert(p, box(`UpperMullion{index}`, v3(x - 0.15, 12.4, 1.05), v3(x + 0.15, 21.2, 1.25), "frame"))
	end
	table.insert(p, box("GlassRail", v3(-23.4, 12.4, -1.3), v3(2.3, 15.6, -1.1), RAIL_GLASS))
	-- The wood screen: seven slats before the right end of the glass, their shadows striping it.
	for index = 1, 7 do
		local x = 2.5 + (index - 1) * 6.4 / 6
		table.insert(p, shadowed(box(`Slat{index}`, v3(x, 12.4, -0.9), v3(x + 0.5, 21.2, -0.3), "wood"), true))
	end
	table.insert(p, lit(box("SideWindow", v3(-23.95, 13, 5), v3(-23.7, 20.6, 6.4), "glass"), "window"))

	-- The pool in the front lawn: water inside a stone coping, two loungers beside it.
	table.insert(p, box("PoolCopingFront", v3(-16, 0, -12.4), v3(4.5, 0.7, -10.8), "stone", true))
	table.insert(p, box("PoolCopingBack", v3(-16, 0, -3.2), v3(4.5, 0.7, -1.4), "stone", true))
	table.insert(p, box("PoolCopingLeft", v3(-16, 0, -10.8), v3(-14.4, 0.7, -3.2), "stone", true))
	table.insert(p, box("PoolCopingRight", v3(2.9, 0, -10.8), v3(4.5, 0.7, -3.2), "stone", true))
	table.insert(p, shadowed(box("PoolWater", v3(-14.4, 0, -10.8), v3(2.9, 0.5, -3.2), "water"), false))
	for index, x in { -22.8, -19.8 } do
		table.insert(p, box(`Lounger{index}`, v3(x, 0, -10), v3(x + 2, 0.9, -5.4), "trim", true))
		table.insert(p, wedge(`Lounger{index}Back`, v3(x, 0.9, -6.6), v3(x + 2, 2.4, -5.4), "back", "trim", true))
	end

	-- The garage: its thin white roof a terrace behind a glass rail, with a long planter.
	table.insert(p, box("GarageRail", v3(10.4, 12, -3.8), v3(23.2, 15.2, -3.6), RAIL_GLASS))
	table.insert(p, box("GaragePlanter", v3(12, 12, -3.4), v3(22, 13.4, -2), "trim", true))
	table.insert(p, box("GaragePlanting", v3(12.2, 13.4, -3.2), v3(21.8, 14.4, -2.2), LEAF))

	local extras: { [string]: { Piece } } = {
		-- Slim wall lights either side of the pivot door.
		porchLights = {
			lamp(box("PorchLightLeft", v3(-21.25, 7, 5.55), v3(-20.75, 8.6, 5.9), LAMP)),
			lamp(box("PorchLightRight", v3(-16.4, 7, 5.55), v3(-15.9, 8.6, 5.9), LAMP)),
		},
		-- Clipped hedges with bird-of-paradise orange along the lawn and the pool.
		garden = {
			box("HedgeLeft", v3(-23, 0, -12.6), v3(-17, 1.6, -11), HEDGE, true),
			box(
				"FlowersLeft",
				v3(-22.8, 1.6, -12.4),
				v3(-17.2, 2, -11.2),
				look(rgb(240, 110, 60), Enum.Material.Grass)
			),
			box("HedgeRight", v3(-16, 0, -14.2), v3(4.5, 1.8, -12.6), HEDGE, true),
			box("FlowersRight", v3(-15.8, 1.8, -14), v3(4.3, 2.2, -12.8), look(rgb(250, 170, 60), Enum.Material.Grass)),
		},
		-- Two panels on the flat roof, tipped toward the street on low rails.
		solarRoof = {
			painted({
				name = "SolarPanelLeft",
				offset = v3(-16.5, 23.1, 7.5),
				size = v3(10, PANEL_THICK, 9),
				solid = false,
				tilt = -10,
			}, PANEL),
			painted({
				name = "SolarPanelRight",
				offset = v3(-4.5, 23.1, 7.5),
				size = v3(10, PANEL_THICK, 9),
				solid = false,
				tilt = -10,
			}, PANEL),
			box("SolarRailFront", v3(-21.6, 22, 3.2), v3(0.6, 22.25, 3.7), PANEL_RAIL),
			box("SolarRailBack", v3(-21.6, 22, 11.4), v3(0.6, 23.7, 11.9), PANEL_RAIL),
		},
	}

	local base: Palette = {
		wall = look(rgb(247, 247, 245), Enum.Material.SmoothPlastic),
		trim = look(rgb(250, 250, 248), Enum.Material.SmoothPlastic),
		frame = look(rgb(52, 56, 62), Enum.Material.Metal),
		wood = look(rgb(139, 90, 60), Enum.Material.WoodPlanks),
		stone = look(rgb(231, 225, 212), Enum.Material.Limestone),
		water = look(rgb(59, 186, 216), Enum.Material.Glass, 0.25),
		paving = look(rgb(226, 222, 214), Enum.Material.Concrete),
		garage = look(rgb(200, 205, 210), Enum.Material.Metal),
		glass = look(rgb(64, 104, 118), Enum.Material.Glass, 0.2),
	}
	return {
		id = "tropical_modern",
		pieces = p,
		extras = extras,
		palettes = {
			base,
			palette(base, {
				wood = look(rgb(170, 118, 74), Enum.Material.WoodPlanks),
				stone = look(rgb(222, 210, 190), Enum.Material.Limestone),
				glass = look(rgb(52, 86, 112), Enum.Material.Glass, 0.2),
			}),
			palette(base, {
				wood = look(rgb(96, 64, 44), Enum.Material.WoodPlanks),
				stone = look(rgb(92, 94, 98), Enum.Material.Basalt),
				glass = look(rgb(44, 58, 68), Enum.Material.Glass, 0.2),
				garage = look(rgb(70, 74, 80), Enum.Material.Metal),
			}),
		},
	}
end

---------------------------------------------------------------------------------------------------------------------
-- Style 3: butterfly_modern
---------------------------------------------------------------------------------------------------------------------

local function butterflyModern(): Variant
	local p: { Piece } = {}
	-- The walls stop at wallTop; the roof's two halves rise `rise` from the valley to both ends of the house.
	local valley, rise, wallTop = -9.55, 4.5, 11
	local slope = rise / 14.45
	-- The roof's underside over x (posts stop just under it).
	local function under(x: number): number
		return wallTop + slope * math.abs(x - valley) + LIFT
	end

	table.insert(p, box("Body", v3(-24, -0.5, 1), v3(4.9, wallTop, 19), "wall", true))
	-- The butterfly: two fills (each end's triangle) under two thin white sheets meeting in the valley, eaves 3 deep
	-- over the street side.
	table.insert(p, wedge("WingFillLeft", v3(-24, wallTop, 1), v3(valley, wallTop + rise, 19), "left", "wall", true))
	table.insert(p, wedge("WingFillRight", v3(valley, wallTop, 1), v3(4.9, wallTop + rise, 19), "right", "wall", true))
	local low = v3(valley, wallTop, 8.9)
	local roofLeft, slopeLeft = sheet("RoofLeft", low, v3(-24.8, wallTop + rise + 0.8 * slope, 8.9), 21.8, 0.7, "trim")
	local roofRight = sheet("RoofRight", low, v3(5.4, wallTop + rise + 0.5 * slope, 8.9), 21.8, 0.7, "trim")
	table.insert(p, roofLeft)
	table.insert(p, roofRight)
	-- Glass in the V's two street triangles, a band of fill kept above it (lit at night like two wings).
	table.insert(
		p,
		lit(
			wedge("ClerestoryLeft", v3(-22.4, wallTop, 0.85), v3(-10.6, wallTop + slope * 11.8, 1.05), "left", "glass"),
			"window"
		)
	)
	table.insert(
		p,
		lit(
			wedge("ClerestoryRight", v3(-8.5, wallTop, 0.85), v3(3.6, wallTop + slope * 12.1, 1.05), "right", "glass"),
			"window"
		)
	)
	-- The stone end wall, proud of the front, up under the roof.
	table.insert(p, box("StoneEnd", v3(-24.4, -0.5, 0.4), v3(-22.8, 15, 19.2), "stone", true))

	local front: Face = { normal = "front", plane = 1 }
	-- Louvred windows over a built-in stone planter.
	append(p, window("Jalousie", front, -22.2, -15.4, 3.2, 9.4, 0.4, "trim"))
	for index = 1, 6 do
		local y = 3.2 + index * 6.2 / 7
		table.insert(p, faceBox(`Louvre{index}`, front, -22.2, -15.4, y - 0.07, y + 0.07, 0.25, 0.45, "alu"))
	end
	table.insert(p, box("Planter", v3(-23, -0.5, -0.6), v3(-14.6, 2.2, 0.9), "stone", true))
	table.insert(p, box("PlanterSoil", v3(-22.7, 2.2, -0.3), v3(-14.9, 2.3, 0.6), SOIL))
	-- The entry: a coloured door and a glass side light under a white head.
	table.insert(p, faceBox("FrontDoor", front, -11.2, -7.9, 0.3, 8.4, -0.1, 0.2, "door", true))
	table.insert(p, lit(faceBox("DoorLight", front, -7.6, -6.6, 0.3, 8.4, -0.1, 0.2, "glass"), "window"))
	table.insert(p, faceBox("DoorHead", front, -11.6, -6.4, 8.4, 8.9, -0.1, 0.35, "trim"))
	-- The pastel wall: a picture window behind three aluminium fins.
	table.insert(p, box("AccentWall", v3(-6.4, -0.5, 0.6), v3(4.9, wallTop, 1), "accent", true))
	local accent: Face = { normal = "front", plane = 0.6 }
	table.insert(p, lit(faceBox("PictureWindow", accent, -5.2, 3.4, 2.2, 9.2, -0.1, 0.15, "glass"), "window"))
	table.insert(p, faceBox("PictureSill", accent, -5.6, 3.8, 1.8, 2.2, -0.1, 0.5, "trim"))
	for index, x in { -3.05, -0.9, 1.25 } do
		table.insert(p, shadowed(faceBox(`Fin{index}`, accent, x - 0.15, x + 0.15, 1.8, 9.8, 0.15, 1.6, "alu"), true))
	end
	-- The grid screen before the entry: posts, a top and a base, bars and rails whose shadows grid the terrazzo.
	table.insert(p, box("ScreenPostL", v3(-15, -0.5, -3.6), v3(-14.6, 8.8, -3), "trim", true))
	table.insert(p, box("ScreenPostR", v3(-7.8, -0.5, -3.6), v3(-7.4, 8.8, -3), "trim", true))
	table.insert(p, box("ScreenTop", v3(-14.6, 8.4, -3.6), v3(-7.8, 8.8, -3), "trim"))
	table.insert(p, box("ScreenBase", v3(-14.6, 0, -3.6), v3(-7.8, 0.4, -3), "trim", true))
	for index, x in { -12.9, -11.2, -9.5 } do
		local bar = box(`ScreenBar{index}`, v3(x - 0.15, 0.4, -3.55), v3(x + 0.15, 8.4, -3.05), "trim")
		table.insert(p, shadowed(bar, true))
	end
	for index, y in { 2.4, 4.4, 6.4 } do
		local rail = box(`ScreenRail{index}`, v3(-14.6, y - 0.15, -3.5), v3(-7.8, y + 0.15, -3.1), "trim")
		table.insert(p, shadowed(rail, true))
	end
	table.insert(p, box("Terrazzo", v3(-15.4, 0, -4.4), v3(-6, 0.25, 1), "terrazzo", true))
	-- A V of steel posts under the left wing's eave.
	local foot = v3(-18.8, 0.2, -1.6)
	table.insert(p, strut("PostLeft", foot, v3(-22.2, under(-22.2) - 0.12, -1.6), 0.4, "iron", true))
	table.insert(p, strut("PostRight", foot, v3(-15.4, under(-15.4) - 0.12, -1.6), 0.4, "iron", true))

	-- The garage: a deep pastel fascia round its flat roof.
	table.insert(p, box("GarageFascia", v3(4.5, 10.9, -4.4), v3(23.9, 12.8, -4), "accent"))
	table.insert(p, box("GarageFasciaSide", v3(23.5, 10.9, -4), v3(23.9, 12.8, 20), "accent"))

	local extras: { [string]: { Piece } } = {
		-- Globe lamps on short arms either side of the entry.
		porchLights = {
			lamp(ball("PorchLightLeft", v3(-12, 7.4, 0.25), 0.9, LAMP)),
			lamp(ball("PorchLightRight", v3(-5.8, 7.4, -0.15), 0.9, LAMP)),
			box("PorchLampLeftArm", v3(-12.06, 7.34, 0.6), v3(-11.94, 7.46, 1), LAMP_IRON),
			box("PorchLampRightArm", v3(-5.86, 7.34, 0.2), v3(-5.74, 7.46, 0.6), LAMP_IRON),
		},
		-- Planting in the stone planter and along the pastel wall.
		garden = {
			box("HedgeLeft", v3(-22.7, 2.2, -0.3), v3(-14.9, 3.4, 0.6), HEDGE),
			box("FlowersLeft", v3(-22.4, 3.4, -0.1), v3(-15.2, 3.8, 0.4), look(rgb(250, 140, 40), Enum.Material.Grass)),
			box("HedgeRight", v3(-6, 0, -2.6), v3(4.4, 1.4, -1.2), HEDGE, true),
			box("FlowersRight", v3(-5.8, 1.4, -2.4), v3(4.2, 1.8, -1.4), look(rgb(240, 90, 120), Enum.Material.Grass)),
		},
		-- Two panels on the left wing.
		solarRoof = {
			onSlope("SolarPanelLeft", slopeLeft, 7, -4, 7.5, 8),
			onSlope("SolarPanelRight", slopeLeft, 7, 5, 7.5, 8),
		},
	}

	local base: Palette = {
		wall = look(rgb(246, 244, 238), Enum.Material.SmoothPlastic),
		trim = look(rgb(250, 250, 248), Enum.Material.SmoothPlastic),
		accent = look(rgb(120, 200, 232), Enum.Material.SmoothPlastic),
		door = look(rgb(240, 138, 60), Enum.Material.SmoothPlastic),
		stone = look(rgb(214, 198, 166), Enum.Material.Limestone),
		alu = look(rgb(196, 202, 208), Enum.Material.Metal),
		iron = look(rgb(46, 48, 52), Enum.Material.Metal),
		terrazzo = look(rgb(236, 226, 214), Enum.Material.Marble),
		paving = look(rgb(222, 216, 206), Enum.Material.Concrete),
		garage = look(rgb(120, 200, 232), Enum.Material.SmoothPlastic),
		glass = WINDOW_GLASS,
	}
	local function pastel(color: Color3, door: Color3): Palette
		return palette(base, {
			accent = look(color, Enum.Material.SmoothPlastic),
			garage = look(color, Enum.Material.SmoothPlastic),
			door = look(door, Enum.Material.SmoothPlastic),
		})
	end
	return {
		id = "butterfly_modern",
		pieces = p,
		extras = extras,
		palettes = {
			base,
			pastel(rgb(255, 160, 172), rgb(60, 150, 160)),
			pastel(rgb(255, 210, 130), rgb(60, 110, 170)),
			pastel(rgb(140, 224, 196), rgb(240, 110, 90)),
		},
	}
end

---------------------------------------------------------------------------------------------------------------------
-- Style 4: coral_rock_cottage
---------------------------------------------------------------------------------------------------------------------

local function coralCottage(): Variant
	local p: { Piece } = {}

	-- The cottage: one and a half storeys of rough tan stone, a steep main gable and a gabled wing toward the street
	-- whose ridge runs into the main roof's slope.
	table.insert(p, box("Body", v3(-24, -0.5, 4), v3(4.9, 12, 19), "wall", true))
	-- (The wing's side stands 0.05 proud of the main block's, so the two never share a plane.)
	table.insert(p, box("FrontWing", v3(-24.05, -0.5, -2), v3(-11.5, 12, 10), "wall", true))
	local main = gable("Main", "x", -24, 4.9, 4, 19, 12, 6.5, 0.6, 0.3, 0.9, 0.8, "wall", "roof")
	append(p, main.pieces)
	local wing = gable("Wing", "z", -2, 10.5, -24.05, -11.5, 12, 6.2, 0.4, 0.4, 0.8, 0.6, "wall", "roof")
	append(p, wing.pieces)

	-- The wing's gable end: an arched triple window on a sill under a keystone, a round vent high in the gable.
	local wingFront: Face = { normal = "front", plane = -2 }
	table.insert(p, faceBox("TripleRim", wingFront, -21.6, -13.9, 2.6, 8, -0.1, 0.15, "trim"))
	table.insert(p, faceDisc("TripleRimArch", wingFront, -17.75, 7.6, -0.1, 0.13, 3.2, "trim"))
	table.insert(p, lit(faceBox("TripleGlass", wingFront, -18.95, -16.55, 3, 7.6, -0.1, 0.25, "glass"), "window"))
	table.insert(p, lit(faceDisc("TripleArch", wingFront, -17.75, 7.6, -0.1, 0.23, 2.4, "glass"), "window"))
	table.insert(p, lit(faceBox("TripleLeft", wingFront, -21.2, -19.6, 3, 7.6, -0.1, 0.25, "glass"), "window"))
	table.insert(p, lit(faceBox("TripleRight", wingFront, -15.9, -14.3, 3, 7.6, -0.1, 0.25, "glass"), "window"))
	table.insert(p, faceBox("TripleSill", wingFront, -21.9, -13.6, 2.2, 2.6, -0.1, 0.55, "trim"))
	table.insert(p, faceBox("TripleKey", wingFront, -18.2, -17.3, 8.6, 9.6, -0.1, 0.35, "trim"))
	table.insert(p, faceDisc("GableVent", wingFront, -17.75, 14.4, -0.1, 0.2, 1.8, "trim"))

	-- The porch: a tile floor up a step, four white columns on bases under caps and a beam, a tile lean-to roof
	-- tucked under the main eave.
	table.insert(p, box("PorchFloor", v3(-11.5, 0, -3.2), v3(4.6, 1, 4), "floor", true))
	table.insert(p, box("PorchStep", v3(-5.45, 0, -4), v3(-1.45, 0.5, -3.2), "floor", true))
	for index, x in { -10.6, -5.83, -1.07, 3.7 } do
		table.insert(p, cylinder(`Column{index}`, v3(x, 4.7, -2.35), "y", 6.6, 1, "trim", true))
		table.insert(p, box(`Column{index}Base`, v3(x - 0.7, 1, -3.05), v3(x + 0.7, 1.4, -1.65), "trim"))
		table.insert(p, box(`Column{index}Cap`, v3(x - 0.75, 8, -3.1), v3(x + 0.75, 8.5, -1.6), "trim"))
	end
	table.insert(p, box("PorchBeam", v3(-11.5, 8.5, -3), v3(4.6, 9.5, -1.7), "trim"))
	local porchRoof = sheet("PorchRoof", v3(-3.4, 9.2, -3.6), v3(-3.4, 10.7, 4), 16.2, 0.6, "roof")
	table.insert(p, porchRoof)
	-- Under the porch: the front door in a white surround with a lit transom, a window either side.
	local porch: Face = { normal = "front", plane = 4 }
	table.insert(p, faceBox("DoorSurround", porch, -5.6, -1.3, 1, 9.6, -0.1, 0.12, "trim"))
	table.insert(p, faceBox("FrontDoor", porch, -5.2, -1.7, 1, 8, -0.1, 0.22, "door", true))
	table.insert(p, lit(faceBox("Transom", porch, -5.2, -1.7, 8.2, 9.3, -0.1, 0.2, "glass"), "window"))
	append(p, window("PorchWindowL", porch, -9.4, -7, 3, 8, 0.35, "trim"))
	append(p, window("PorchWindowR", porch, 0.1, 2.5, 3, 8, 0.35, "trim"))
	-- The side the street sees: a window in the wing and one in the main block. A stone chimney through the back.
	local side: Face = { normal = "left", plane = -24 }
	append(p, window("WingSideWindow", { normal = "left", plane = -24.05 }, 1.5, 4.5, 3.5, 8, 0.35, "trim"))
	append(p, window("SideWindow", side, 12.5, 15.5, 3.5, 8, 0.35, "trim"))
	table.insert(p, box("Chimney", v3(-21, 15, 14), v3(-18.6, 22.5, 16.4), "wall", true))
	table.insert(p, box("ChimneyCap", v3(-21.3, 22.5, 13.7), v3(-18.3, 23, 16.7), "trim"))

	-- The garage: stone under a tile gable, a white surround round the door, a vent in the gable.
	local garage = gable("Garage", "x", 4.9, 23, -4, 19.6, 12, 3.8, 0.8, 0, 0.6, 0.7, "wall", "roof")
	append(p, garage.pieces)
	table.insert(p, faceBox("GaragePierL", GARAGE_FRONT, 4.6, 6, 0, 9.4, -0.1, 0.45, "trim"))
	table.insert(p, faceBox("GaragePierR", GARAGE_FRONT, 22, 23.4, 0, 9.4, -0.1, 0.45, "trim"))
	table.insert(p, faceBox("GarageLintel", GARAGE_FRONT, 4.6, 23.4, 9.4, 10.4, -0.1, 0.5, "trim"))
	table.insert(p, faceDisc("GarageVent", GARAGE_SIDE, 7.8, 13.4, -0.1, 0.15, 1.5, "trim"))

	local extras: { [string]: { Piece } } = {
		-- Lanterns either side of the door, under the porch roof.
		porchLights = {
			lamp(box("PorchLightLeft", v3(-6.45, 5.8, 3.3), v3(-5.85, 7, 3.9), LAMP)),
			lamp(box("PorchLightRight", v3(-1.05, 5.8, 3.3), v3(-0.45, 7, 3.9), LAMP)),
			box("PorchLampLeftCap", v3(-6.55, 7, 3.2), v3(-5.75, 7.25, 4), LAMP_IRON),
			box("PorchLampRightCap", v3(-1.15, 7, 3.2), v3(-0.35, 7.25, 4), LAMP_IRON),
		},
		-- Hedges and flower beds under the triple window and along the porch either side of the step.
		garden = {
			box("HedgeLeft", v3(-23.5, 0, -4), v3(-12, 2, -2.6), HEDGE, true),
			box("FlowersLeft", v3(-23.3, 2, -3.8), v3(-12.2, 2.4, -2.8), look(rgb(236, 120, 160), Enum.Material.Grass)),
			box("HedgeRight", v3(-11.3, 0, -4.8), v3(-6, 1.6, -3.3), HEDGE, true),
			box("FlowersRight", v3(-11.1, 1.6, -4.6), v3(-6.2, 2, -3.5), look(rgb(250, 210, 90), Enum.Material.Grass)),
			box("HedgeCentre", v3(-0.9, 0, -4.8), v3(4.4, 1.6, -3.3), HEDGE, true),
			box("FlowersCentre", v3(-0.7, 1.6, -4.6), v3(4.2, 2, -3.5), look(rgb(250, 210, 90), Enum.Material.Grass)),
		},
		-- Two panels on the main roof's street slope, right of the wing.
		solarRoof = {
			onSlope("SolarPanelLeft", main.a, 5, 3.55, 5.6, 5),
			onSlope("SolarPanelRight", main.a, 5, 10.15, 5.6, 5),
		},
	}

	local base: Palette = {
		wall = look(rgb(205, 187, 149), Enum.Material.Limestone),
		trim = look(rgb(250, 250, 246), Enum.Material.SmoothPlastic),
		roof = look(rgb(201, 121, 78), Enum.Material.ClayRoofTiles),
		door = look(rgb(52, 96, 76), Enum.Material.Wood),
		floor = look(rgb(176, 92, 70), Enum.Material.CeramicTiles),
		paving = look(rgb(200, 192, 178), Enum.Material.Concrete),
		garage = look(rgb(244, 242, 234), Enum.Material.Wood),
		glass = WINDOW_GLASS,
	}
	return {
		id = "coral_rock_cottage",
		pieces = p,
		extras = extras,
		palettes = {
			base,
			palette(base, {
				wall = look(rgb(214, 194, 152), Enum.Material.Sandstone),
				roof = look(rgb(186, 92, 60), Enum.Material.ClayRoofTiles),
				door = look(rgb(48, 80, 118), Enum.Material.Wood),
			}),
			palette(base, {
				wall = look(rgb(188, 178, 156), Enum.Material.Limestone),
				roof = look(rgb(172, 104, 74), Enum.Material.ClayRoofTiles),
				door = look(rgb(120, 50, 40), Enum.Material.Wood),
			}),
		},
	}
end

local Houses = {
	-- The CollectionService tag MapBuilder puts on every plot (Config/MapLayout HousePlot locations).
	plotTag = "HousePlot",
	-- Workspace.<folderName> holds every plot's sign and every claimed house (built at run time by HouseService).
	folderName = "Houses",
	-- EconomyService reasons: buying an upgrade, and giving the price back if it couldn't be saved.
	economyReason = "house",
	refundReason = "refund",

	-- Net ClaimHouse is refused unless the player's character stands within this many studs of the plot's sign (the
	-- prompt's reach plus a margin for lag). The prompt itself is checked by Roblox.
	claimReach = 24,

	-- The "Claim house" prompt on every free plot's sign.
	prompt = {
		name = "ClaimHousePrompt",
		actionText = "Claim house",
		holdSeconds = 0.5,
		maxDistance = 12,
	},

	-- The home charger: a painted bay on the garage floor, tagged for Services/EnergyService. HouseService sets its
	-- attributes: the owner's UserId, the plot id, its power (chargerKW) and its price per full charge
	-- (chargerCostPerFull). EnergyService charges only the owner's own car there.
	charger = {
		tag = "HomeCharger",
		ownerAttribute = "OwnerUserId",
		plotAttribute = "PlotId",
		kWAttribute = "kW",
		costAttribute = "CostPerFull",
	},

	-- Attributes on each plot's model (Workspace.Houses.<plotId>), for the client and tests: its address, and the
	-- owner's UserId while it is claimed (absent while it is free). The house model (<plotId>.House) carries its
	-- style's id.
	plotAttributes = {
		address = "Address",
		owner = "OwnerUserId",
		style = "Style",
	},

	-- The garage door. Closed, it fills the door opening; open, it lies flat under the garage roof. It opens when
	-- the owner's car touches the sensor over the driveway and the bay (the car's Chassis part, vehicle model
	-- contract), or when the owner drives off in a car that stood in the sensor while it was shut. It closes once no
	-- car is in its way: none moving in the sensor (checked every closeCheckSeconds while one is) and none standing
	-- in the doorway (the doorwaySize box round the shut door, deep enough for the door's swing at car height).
	-- Painted in the palette's "garage" slot, with `panels` drawn on its road face: a sectional door's joints.
	door = {
		name = "GarageDoor",
		offset = Vector3.new(14, 4.5, -2.5),
		size = Vector3.new(16, 9, 0.6),
		openOffset = Vector3.new(14, 10.4, 2.3),
		openTilt = 90,
		paint = "garage",
		-- A Texture: our slab-line overlay (a white band along the bottom of each tile, docs/city/TECH.md §8),
		-- tinted `shade` times the door's colour, one tile per panel.
		panels = {
			texture = "rbxassetid://127561142232255",
			studsU = 16,
			studsV = 2.25,
			shade = 0.55,
		},
		openSeconds = 1,
		closeSeconds = 1.4,
		closeCheckSeconds = 4,
		sensorName = "DoorSensor",
		sensorOffset = Vector3.new(14, 4, -2),
		sensorSize = Vector3.new(16, 8, 36),
		-- Centred on `offset` (the shut door): the opening's width and height, and 2 studs either side of the door
		-- plane. Swinging up under the roof the door reaches about 1.5 studs inside the bay at car height.
		doorwaySize = Vector3.new(16, 9, 4),
		-- The car part that opens it (vehicle model contract) and the car attribute naming its owner.
		chassisName = "Chassis",
		carOwnerAttribute = "OwnerUserId",
	},

	-- What a style may never put a part in: the bay behind the door up to the roof slab, and what the door sweeps
	-- in front of its plane as it swings up (its bottom edge comes about 1 stud out at mid-swing, below 9 studs,
	-- and rises past the header's depth near the end). Lintels and surrounds round the door stay in front of
	-- z = -2.9 above 9 studs. tests/Houses.spec checks every style against these, and the door's swing inside them.
	garageClear = {
		{ offset = Vector3.new(14, 5.65, 7.4), size = Vector3.new(15.9, 10.5, 19.2) },
		{ offset = Vector3.new(14, 4.7, -3.25), size = Vector3.new(15.9, 8.6, 0.7) },
		{ offset = Vector3.new(14, 5.65, -2.55), size = Vector3.new(15.9, 10.5, 0.7) },
	} :: { Zone },

	-- A claim is refused while a car's chassis or another player stands where a solid part of the house would
	-- appear, so nobody is trapped inside a wall: every solid piece (of Houses.structure and the plot's style) that
	-- reaches from below `maxBottom` to above `minTop`, and the shut garage door. Floor slabs, steps and pool
	-- copings (lower than minTop) and roofs (higher than maxBottom) are left out: a car on or under them isn't
	-- trapped.
	lotClear = {
		minTop = 1.2,
		maxBottom = 8,
		door = true,
	},

	-- The home charger's bay on the garage floor (inside the door, clear of it when it closes).
	chargerPad = {
		name = "HomeCharger",
		offset = Vector3.new(14, 0.4, 7),
		size = Vector3.new(12, 0.1, 18),
		color = ACCENT,
		transparency = 0.45,
	},

	-- The sign by the road on every plot: a post and a board facing the road, with the owner's display name (Roblox
	-- display names need no filtering) or "Free house", and the address. The board's text is drawn on a SurfaceGui
	-- on its road side.
	sign = {
		postOffset = Vector3.new(-20, 4, -17),
		postSize = Vector3.new(0.6, 8, 0.6),
		boardOffset = Vector3.new(-20, 6.5, -17.4),
		boardSize = Vector3.new(10, 4, 0.3),
		postColor = TRIM,
		boardColor = Color3.fromRGB(38, 42, 52),
		freeColor = Color3.fromRGB(110, 214, 150), -- the title while the plot is free
		ownedColor = ACCENT, -- the owner's name
		textColor = Color3.fromRGB(255, 255, 255),
		dimColor = Color3.fromRGB(186, 192, 204),
		pixelsPerStud = 50,
		padding = 0.06, -- of the board's width, each side
		-- Rows of the board, as fractions of its height: { top, height }.
		topRow = { 0.08, 0.2 },
		titleRow = { 0.3, 0.38 },
		addressRow = { 0.7, 0.22 },
	},

	-- The garage every house shares (Dev/SocialTests checks a claimed house has every one of these, by name).
	structure = structure,

	-- The styles, in the order Houses.styleOf deals them out.
	variants = { towerVilla(), tropicalModern(), butterflyModern(), coralCottage() } :: { Variant },

	-- Parts in one claimed house at most (structure, style, door, charger bay, sensor and every extra), so 26
	-- claimed houses stay a small share of what a phone streams in (Config/Perf). tests/Houses.spec holds each style
	-- to it.
	partBudget = 150,
	-- Nothing of a house rises above this (studs over the plot's ground).
	maxHeight = 40,

	-- Extras every style shares, rebuilt whenever the upgrades change: the plain mailbox every house has (until the
	-- painted one replaces it), and the painted mailbox. The other upgrades' parts are in each style's extras.
	plainMailbox = {
		box("MailboxPost", v3(-13.2, 0, -18.7), v3(-12.8, 3.5, -18.3), look(TRIM, Enum.Material.Metal)),
		box("Mailbox", v3(-13.6, 3.4, -19.5), v3(-12.4, 4.4, -17.5), look(rgb(150, 154, 160), Enum.Material.Metal)),
	} :: { Piece },
	-- The upgrade whose extras replace the plain mailbox.
	plainMailboxReplacedBy = "mailbox",
	extras = {
		mailbox = {
			box(
				"MailboxPost",
				v3(-13.2, 0, -18.7),
				v3(-12.8, 3.5, -18.3),
				look(rgb(245, 245, 245), Enum.Material.SmoothPlastic)
			),
			box(
				"Mailbox",
				v3(-13.6, 3.4, -19.5),
				v3(-12.4, 4.4, -17.5),
				look(rgb(200, 52, 52), Enum.Material.SmoothPlastic)
			),
			box(
				"MailboxFlag",
				v3(-12.35, 4.15, -18.35),
				v3(-12.25, 5.05, -17.85),
				look(rgb(245, 245, 245), Enum.Material.SmoothPlastic)
			),
		},
	} :: { [string]: { Piece } },
	-- The porch lights' glow (a PointLight in each lamp).
	porchLight = { range = 16, brightness = 1.2, color = WARM_LIGHT } :: Light,

	-- The upgrades, in the order the Home app lists them. Prices are in-game cash (no Robux; CLAUDE.md hard rule 6).
	upgrades = {
		{
			id = "fastCharger",
			name = "Faster home charger",
			description = "Your garage charger tops your car up faster.",
			price = 15000,
			chargerKW = 300,
		},
		{
			id = "solarRoof",
			name = "Solar roof",
			description = "Panels on the roof halve what charging at home costs.",
			price = 20000,
			costScale = 0.5,
		},
		{
			id = "porchLights",
			name = "Porch lights",
			description = "Warm lamps either side of the front door.",
			price = 3000,
		},
		{
			id = "garden",
			name = "Front garden",
			description = "Hedges and flower beds along the front of the house.",
			price = 5000,
		},
		{
			id = "mailbox",
			name = "Painted mailbox",
			description = "A bright red mailbox by the road, flag up.",
			price = 1500,
		},
	} :: { Upgrade },

	-- With no house, the Home app's directions lead here (a HousePlot with gps = true in Config/MapLayout).
	directionsPlot = "rv_cedar_ct_3",

	-- What players read. Plain words; %s is filled in where noted.
	text = {
		signFreeTitle = "Free house",
		signFreeTop = "Claim me",
		signOwnedTop = "Home of",
		claimed = "Welcome home! %s is yours while you're in this server.", -- the address
		alreadyYours = "This is already your house.",
		hasHouse = "You already live at %s. Leave it in the Home app first.", -- the address
		taken = "Someone already lives here. Find a free house nearby.",
		blocked = "A car or a player is where the house would go. Try again once the lot is clear.",
		noPlot = "That house isn't on the map.",
		tooFar = "Walk up to the house's sign to claim it.",
		notReady = "You need to be standing by the sign to claim a house.",
		loading = "Your save is still loading. Try again in a moment.",
		left = "You moved out of %s. Your upgrades come with you to your next house.", -- the address
		noHouse = "You don't have a house right now.",
		unknownUpgrade = "That upgrade isn't for sale.",
		owned = "You already have this upgrade.",
		cash = "You need %s more for this upgrade.", -- the shortfall
		bought = "%s added to your house.", -- the upgrade's name
		boughtLater = "%s bought. It comes with the next house you claim.", -- the upgrade's name
		failed = "That didn't work. Please try again.",
	},

	-- The phone's Home app (UI/Phone/HomeApp).
	app = {
		loading = "Loading your home...",
		yourHouse = "Your house",
		chargerLine = "Home charging: %s kW, %s per %%", -- kW, the price of a percent
		setGps = "Set GPS home",
		gpsName = "Home",
		leave = "Move out",
		leaving = "Moving out...",
		confirmTitle = "Move out of %s?", -- the address
		confirmBody = "The house goes back on the market. Your upgrades stay yours for the next one.",
		stay = "Stay",
		confirmLeave = "Move out",
		noHouseTitle = "No house yet",
		noHouseBody = "Walk up to the sign of a free house in Riverside and claim it. It's yours while you're in "
			.. "this server, and your upgrades come with you to every house you claim.",
		directions = "Directions to Riverside homes",
		upgrades = "Upgrades",
		owned = "Owned",
		buy = "Buy for %s", -- the price
		buying = "Buying...",
		cashNeeded = "You need %s more.", -- the shortfall
	},
}

-- Pure helpers -------------------------------------------------------------------------------------------------

-- The upgrade with this id, or nil.
function Houses.upgrade(id: string): Upgrade?
	for _, upgrade in Houses.upgrades do
		if upgrade.id == id then
			return upgrade
		end
	end
	return nil
end

-- The upgrades a save says the player owns, as a clean set: only known ids marked true. Anything else in a damaged
-- save (unknown ids, non-true values, a non-table) is ignored, never an error.
function Houses.cleanUpgrades(saved: any): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	if type(saved) ~= "table" then
		return owned
	end
	for _, upgrade in Houses.upgrades do
		if saved[upgrade.id] == true then
			owned[upgrade.id] = true
		end
	end
	return owned
end

-- The owned upgrades' ids, in Houses.upgrades order (for HouseUpdate and the Home app).
function Houses.ownedList(owned: { [string]: boolean }): { string }
	local list: { string } = {}
	for _, upgrade in Houses.upgrades do
		if owned[upgrade.id] == true then
			table.insert(list, upgrade.id)
		end
	end
	return list
end

-- Why `id` can't be bought by a player who owns `owned` and has `cash` (nil: it can): an unknown upgrade, one
-- already owned, or not enough cash.
function Houses.buyRefusal(owned: { [string]: boolean }, id: string, cash: number): BuyRefusal?
	local upgrade = Houses.upgrade(id)
	if upgrade == nil then
		return "unknown"
	elseif owned[id] == true then
		return "owned"
	elseif not (cash >= upgrade.price) then
		return "cash"
	end
	return nil
end

-- The home charger's power (kW) with these upgrades: Config/Energy home.kW, or the highest chargerKW an owned
-- upgrade gives.
function Houses.chargerKW(owned: { [string]: boolean }): number
	local kW = Energy.home.kW
	for _, upgrade in Houses.upgrades do
		local boosted = upgrade.chargerKW
		if owned[upgrade.id] == true and boosted ~= nil and boosted > kW then
			kW = boosted
		end
	end
	return kW
end

-- What a full charge at home costs with these upgrades: Config/Energy home.costPerFull times every owned
-- upgrade's costScale, rounded to whole dollars per percent (never below 0).
function Houses.chargerCostPerFull(owned: { [string]: boolean }): number
	local cost = Energy.home.costPerFull
	for _, upgrade in Houses.upgrades do
		local scale = upgrade.costScale
		if owned[upgrade.id] == true and scale ~= nil then
			cost *= scale
		end
	end
	return math.max(math.floor(cost / PERCENT + 0.5) * PERCENT, 0)
end

-- A plot's frame: its HousePlot location's centre on the ground (Config/MapLayout position), turned to its yaw.
-- Every offset above is in this frame.
function Houses.plotFrame(position: Vector3, yaw: number): CFrame
	return CFrame.new(position) * CFrame.Angles(0, math.rad(yaw), 0)
end

-- Where a plot's sign board stands in the world (the claim reach is measured from here).
function Houses.signPosition(position: Vector3, yaw: number): Vector3
	return (Houses.plotFrame(position, yaw) * CFrame.new(Houses.sign.boardOffset)).Position
end

-- Where a piece stands on a plot whose frame is `frame` (CFrame.identity: in the plot's own frame).
function Houses.pieceFrame(piece: Piece, frame: CFrame): CFrame
	local turned = CFrame.Angles(math.rad(piece.tilt or 0), math.rad(piece.turn or 0), math.rad(piece.roll or 0))
	return frame * CFrame.new(piece.offset) * (piece.rotation or CFrame.identity) * turned
end

-- How far a piece reaches from its centre along each of the plot's axes (half its turned box's extent).
function Houses.reach(piece: Piece): Vector3
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = Houses.pieceFrame(piece, CFrame.identity)
		:GetComponents()
	local half = piece.size / 2
	return v3(
		math.abs(r00) * half.X + math.abs(r01) * half.Y + math.abs(r02) * half.Z,
		math.abs(r10) * half.X + math.abs(r11) * half.Y + math.abs(r12) * half.Z,
		math.abs(r20) * half.X + math.abs(r21) * half.Y + math.abs(r22) * half.Z
	)
end

-- Whether a piece casts a shadow (Piece.shadow, else: not when see-through or thin both ways across).
function Houses.castsShadow(piece: Piece): boolean
	if piece.shadow ~= nil then
		return piece.shadow
	end
	if (piece.transparency or 0) > 0 then
		return false
	end
	local thin = 0
	for _, extent in { piece.size.X, piece.size.Y, piece.size.Z } do
		if extent < 1 then
			thin += 1
		end
	end
	return thin < 2
end

-- A piece's look on a house painted in `colors`: its paint slot's look, with its own colour, material, shine and
-- see-through over it. nil when it names a slot the palette lacks and has no colour of its own.
function Houses.lookOf(piece: Piece, colors: Palette): Look?
	local slot = if piece.paint ~= nil then colors[piece.paint] else nil
	local color = piece.color or (if slot ~= nil then slot.color else nil)
	local material = piece.material or (if slot ~= nil then slot.material else nil)
	if color == nil or material == nil then
		return nil
	end
	return {
		color = color,
		material = material,
		reflectance = piece.reflectance or (if slot ~= nil then slot.reflectance else nil),
		transparency = piece.transparency or (if slot ~= nil then slot.transparency else nil),
	}
end

-- The style and palette of the plot at `index` among the HousePlots (MapLayout order): the styles in turn, so
-- neighbours on a street or round a court differ, and each style's palettes in turn across its copies. Always the
-- same for a plot.
function Houses.styleOf(index: number): (number, number)
	local count = #Houses.variants
	local variant = (index - 1) % count + 1
	local palettes = #Houses.variants[variant].palettes
	return variant, math.floor((index - 1) / count) % palettes + 1
end

return Houses
