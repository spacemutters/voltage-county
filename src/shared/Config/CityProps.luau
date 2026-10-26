--!strict
-- The city's shared props (Dev/City/Props): café sets, food trucks, market stalls, fountains, sculptures, the tower
-- crane... Each is one MeshPart template in ServerStorage.CityAssets.Props.<Name>, made in Studio (Studio-owned, like
-- the palm meshes). A plan places a prop as one templated spec standing for its box (Dev/MapTypes TemplateSpec); the
-- build clones the template, scales it (keeping its proportions) to the box's height, stands its bottom centre on the
-- box's floor (`seat`) and turns it as the box is turned plus `turn` degrees, so every copy is one part drawing as one
-- instanced mesh (Dev/City/Scenery Palms.instantiate). While a template is missing the build puts up a few plain parts
-- in its place (`standIn`, drawn in the box's own measure: x and z from -0.5 to 0.5, y from 0 to 1), marked so
-- Dev/MapCheck fails until the template is back.
--
-- A template's front is taken to face its -Z (its LookVector); a set whose fronts face another way gets a `turn`.
-- `size` is the box a prop is usually given (width along x, height, depth along z), in studs, in the template's own
-- proportions as near as they are known (the clone keeps its own, scaled to the height); callers may give another.
-- `collider` is the share of the box an invisible collision box takes where a car or a player could hit it.

local rgb = Color3.fromRGB

export type Piece = {
	shape: "block" | "cylinder" | "ball", -- a cylinder stands up (its axis along y)
	from: Vector3,
	to: Vector3,
	color: Color3,
	material: Enum.Material,
}

export type Prop = {
	size: Vector3,
	turn: number, -- degrees, about the template's up axis
	collider: Vector3?, -- share of the box (x, y, z) the collision box takes, when the caller asks for one
	-- Never wider or deeper than its box: the build scales the clone down to fit it, keeping its proportions (Dev/City
	-- /Scenery Palms.fit). For a prop whose mesh could otherwise reach into a neighbour (the crane's jib). The others
	-- keep their box's height and may reach a little past its sides (decor: they never collide).
	contain: boolean?,
	standIn: { Piece },
}

local P = Enum.Material
local WHITE = rgb(244, 242, 236)
local METAL = rgb(70, 72, 76)
local STONE = rgb(226, 220, 206)
local WATER = rgb(80, 200, 214)

local function piece(
	shape: "block" | "cylinder" | "ball",
	from: Vector3,
	to: Vector3,
	color: Color3,
	material: Enum.Material
): Piece
	return { shape = shape, from = from, to = to, color = color, material = material }
end

local v = Vector3.new

-- A round café table under an umbrella of `canopy`'s colour.
local function cafe(canopy: Color3): Prop
	return {
		size = v(8, 8.5, 8),
		turn = 0,
		standIn = {
			piece("cylinder", v(-0.14, 0.32, -0.14), v(0.14, 0.36, 0.14), WHITE, P.SmoothPlastic),
			piece("cylinder", v(-0.02, 0, -0.02), v(0.02, 0.86, 0.02), WHITE, P.Metal),
			piece("cylinder", v(-0.5, 0.82, -0.5), v(0.5, 0.88, 0.5), canopy, P.Fabric),
		},
	}
end

local function truck(body: Color3, trim: Color3): Prop
	return {
		size = v(8.5, 11, 22),
		turn = 0,
		collider = v(0.9, 0.8, 0.95),
		standIn = {
			piece("block", v(-0.5, 0.12, -0.18), v(0.5, 0.92, 0.5), body, P.SmoothPlastic),
			piece("block", v(-0.48, 0.12, -0.5), v(0.48, 0.66, -0.18), trim, P.SmoothPlastic),
			-- The windows stand a hair proud of the body's sides (no z-fighting) and inside the box's checks.
			piece("block", v(-0.505, 0.45, -0.05), v(0.505, 0.7, 0.38), rgb(36, 40, 46), P.Glass),
		},
	}
end

local CityProps = {
	root = { "CityAssets", "Props" },
	-- Parts a stand-in may have at most (Dev/MapCheck counts a missing template as a failure, whatever its size).
	standInMax = 4,

	props = {
		CafeSetPink = cafe(rgb(255, 160, 172)),
		CafeSetMint = cafe(rgb(140, 224, 196)),
		CafeSetWhite = cafe(WHITE),
		BistroPair = {
			size = v(5, 3.6, 3),
			turn = 0,
			standIn = {
				piece("cylinder", v(-0.12, 0, -0.2), v(0.12, 0.8, 0.2), METAL, P.Metal),
				piece("block", v(-0.5, 0, -0.3), v(-0.25, 0.55, 0.3), METAL, P.Metal),
				piece("block", v(0.25, 0, -0.3), v(0.5, 0.55, 0.3), METAL, P.Metal),
			},
		},
		FoodTruckA = truck(WHITE, rgb(120, 206, 214)),
		FoodTruckB = truck(rgb(255, 210, 130), rgb(255, 160, 172)),
		MarketStall = {
			size = v(10, 9, 7),
			turn = 0,
			standIn = {
				piece("block", v(-0.5, 0, -0.5), v(0.5, 0.38, -0.1), rgb(150, 110, 76), P.WoodPlanks),
				piece("block", v(-0.5, 0, 0.42), v(-0.42, 0.9, 0.5), rgb(150, 110, 76), P.Wood),
				piece("block", v(0.42, 0, 0.42), v(0.5, 0.9, 0.5), rgb(150, 110, 76), P.Wood),
				piece("block", v(-0.5, 0.88, -0.5), v(0.5, 1, 0.5), rgb(236, 120, 96), P.Fabric),
			},
		},
		BikeRack = {
			size = v(7, 3, 2),
			turn = 0,
			standIn = { piece("block", v(-0.5, 0, -0.1), v(0.5, 1, 0.1), METAL, P.Metal) },
		},
		NewsBoxes = {
			size = v(5, 4, 2),
			turn = 0,
			standIn = {
				piece("block", v(-0.5, 0, -0.5), v(-0.04, 1, 0.5), rgb(40, 96, 170), P.SmoothPlastic),
				piece("block", v(0.04, 0, -0.5), v(0.5, 0.86, 0.5), rgb(196, 44, 40), P.SmoothPlastic),
			},
		},
		Fountain = {
			size = v(16, 8, 16),
			turn = 0,
			collider = v(0.95, 0.2, 0.95),
			standIn = {
				piece("cylinder", v(-0.5, 0, -0.5), v(0.5, 0.16, 0.5), STONE, P.Marble),
				piece("cylinder", v(-0.44, 0.04, -0.44), v(0.44, 0.17, 0.44), WATER, P.Glass),
				piece("cylinder", v(-0.07, 0, -0.07), v(0.07, 0.72, 0.07), STONE, P.Marble),
				piece("cylinder", v(-0.24, 0.66, -0.24), v(0.24, 0.74, 0.24), STONE, P.Marble),
			},
		},
		SculptureA = {
			size = v(7, 14, 7),
			turn = 0,
			collider = v(0.6, 0.25, 0.6),
			standIn = {
				piece("block", v(-0.3, 0, -0.3), v(0.3, 0.2, 0.3), STONE, P.Marble),
				piece("ball", v(-0.5, 0.2, -0.5), v(0.5, 1, 0.5), rgb(236, 110, 96), P.SmoothPlastic),
			},
		},
		SculptureB = {
			size = v(8, 12, 8),
			turn = 0,
			collider = v(0.6, 0.25, 0.6),
			standIn = {
				piece("block", v(-0.3, 0, -0.3), v(0.3, 0.18, 0.3), STONE, P.Marble),
				piece("block", v(-0.12, 0.18, -0.4), v(0.12, 1, 0.4), rgb(40, 96, 170), P.Metal),
				piece("block", v(-0.4, 0.4, -0.12), v(0.4, 0.62, 0.12), rgb(255, 210, 130), P.Metal),
			},
		},
		PlaygroundSet = {
			size = v(24, 12, 18),
			turn = 0,
			collider = v(0.8, 0.45, 0.8),
			standIn = {
				piece("block", v(-0.3, 0.3, -0.25), v(0.2, 0.36, 0.25), rgb(255, 210, 130), P.SmoothPlastic),
				piece("block", v(-0.32, 0.8, -0.27), v(0.22, 0.9, 0.27), rgb(40, 96, 170), P.SmoothPlastic),
				piece("block", v(0.2, 0, -0.1), v(0.5, 0.34, 0.1), rgb(236, 110, 96), P.SmoothPlastic),
				piece("block", v(-0.31, 0, -0.26), v(0.21, 0.3, 0.26), METAL, P.Metal),
			},
		},
		BasketballHoop = {
			size = v(4, 13, 6),
			turn = 0,
			standIn = {
				piece("cylinder", v(-0.1, 0, 0.3), v(0.1, 0.8, 0.5), METAL, P.Metal),
				piece("block", v(-0.5, 0.62, -0.05), v(0.5, 0.95, 0.05), WHITE, P.SmoothPlastic),
				piece("cylinder", v(-0.22, 0.75, -0.5), v(0.22, 0.77, -0.06), rgb(236, 110, 40), P.Metal),
			},
		},
		TowerCrane = {
			size = v(60, 100, 12),
			turn = 0,
			-- Its jib is about as long as the crane is tall: scaled by height alone it reached past narrow sites into
			-- their neighbours (review 2026-10-26).
			contain = true,
			standIn = {
				piece("block", v(-0.05, 0, -0.3), v(0.05, 0.94, 0.3), rgb(236, 190, 40), P.Metal),
				piece("block", v(-0.5, 0.9, -0.15), v(0.5, 0.96, 0.15), rgb(236, 190, 40), P.Metal),
				piece("block", v(-0.36, 0.84, -0.3), v(-0.22, 0.9, 0.3), rgb(150, 150, 150), P.Concrete),
				piece("block", v(-0.04, 0.96, -0.1), v(0.04, 1, 0.1), rgb(236, 190, 40), P.Metal),
			},
		},
		Bandshell = {
			size = v(30, 18, 20),
			turn = 0,
			collider = v(0.95, 0.12, 0.9),
			standIn = {
				piece("block", v(-0.5, 0, -0.5), v(0.5, 0.12, 0.5), STONE, P.Concrete),
				piece("cylinder", v(-0.45, 0.12, -0.2), v(0.45, 1, 0.5), WHITE, P.SmoothPlastic),
			},
		},
		ParkBench = {
			size = v(6, 3, 2.5),
			turn = 0,
			standIn = {
				piece("block", v(-0.5, 0.42, -0.5), v(0.5, 0.56, 0.3), rgb(150, 110, 76), P.WoodPlanks),
				piece("block", v(-0.5, 0.56, 0.3), v(0.5, 1, 0.5), rgb(150, 110, 76), P.WoodPlanks),
			},
		},
	} :: { [string]: Prop },
}

return CityProps
