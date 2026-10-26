--!strict
-- The bay as terrain water (docs/city/SCENERY.md §3): Dev/WaterBuilder writes it into Workspace.Terrain from
-- Util/WaterShape, Services/WaterRescueService pulls cars out of it, Dev/MapCheck checks nothing of the road or the
-- gameplay spots stands in it.
--   terrain   the switch: on, the bay is terrain water and Dev/MapBuilder leaves out the old part water, the lake bed
--             and its banks (it keeps the stone coping on the walled shores); off, the old part water comes back
--   look      the terrain's water (Terrain.WaterColor and the rest; one look for all terrain water)
--   seabed    the sand and stone under the water: where the seabed meets the ground at a lake's edge, and the water
--             depth by distance from each kind of shore (a beach shore, a walled shore). The seabed never goes below
--             the lake's bedY (Config/MapLayout), which the bridge's piers stand on
--   build     how Dev/WaterBuilder writes the voxels
--   dry       how far over the water a road or a gameplay spot must stand (Dev/MapCheck, tests/Water.spec)
--   rescue    when a driven car counts as in the water, and how long it may stay there before the server puts it
--             back on the nearest road
-- Coordinates: X east, north is -Z, Y up; terrain voxels are 4 studs a side.

local rgb = Color3.fromRGB

-- One kind of shore. `profile` is the water depth (studs below the water line) at each distance (studs) from the
-- shore, in order, as Vector2(distance, depth): between the edge, where the seabed meets the ground at seabed.rimY,
-- and the first point the seabed slopes straight, and past the last it stays at the last depth. Depths only grow.
export type Shore = {
	profile: { Vector2 },
	material: Enum.Material, -- the seabed's terrain material
	-- A walled shore's bank is stone this many studs out from the edge (nil: all `material`).
	stone: Enum.Material?,
	stoneReach: number?,
}

export type Rescue = {
	interval: number, -- seconds between checks of the driven cars (one Heartbeat with an accumulator)
	touch: number, -- a car is in the water when its chassis centre is less than this far above the water line
	depth: number, -- ...where the water is at least this deep (studs, surface to seabed)
	seconds: number, -- ...for this long: then it goes back to the nearest road
	flippedDot: number, -- a car whose up vector's Y is below this is on its roof or its side
	flippedSeconds: number, -- such a car in any water goes back after this long
	-- A car stuck in any water (the shallows' shelf, nosed into a seawall): moving slower than stuckSpeed studs/s across
	-- the ground (AntiExploitService.groundSpeed) for stuckSeconds, it goes back too.
	stuckSpeed: number,
	stuckSeconds: number,
	reason: string, -- Net VehicleReset's reason
	message: string, -- Net Notify's text for the driver
	kind: string, -- Net Notify's kind
}

local Water = {
	terrain = true,

	-- The look of docs/city/SCENERY.md §3 (turquoise over the pale sand of the shallows, deep teal-blue offshore), tuned
	-- in Studio 2026-10-26 at top graphics quality (SCENERY.md §3): at reflectance 1 the bay read milky sky-blue
	-- from the beach; at 0.4 or less a neon pool-cyan from the air. These keep the sand clear under the shallows, a
	-- turquoise band off the beach and a deep cerulean bay from the air.
	-- The street-level roast (2026-10-26, point 3) saw milky grey-white shallows from the beach and no waves: the colour
	-- is greener (a real bay's green-turquoise), less of the pale sky is mirrored, and the waves are twice as big. Seen in
	-- Studio the same day from the beach and from the air (a teal-blue bay, not a pool).
	look = {
		color = rgb(12, 120, 128), -- Terrain.WaterColor
		transparency = 0.68, -- Terrain.WaterTransparency: 0 opaque .. 1 clear
		reflectance = 0.42, -- Terrain.WaterReflectance: 0 none .. 1 full
		waveSize = 0.3, -- Terrain.WaterWaveSize: studs, 0..1
		waveSpeed = 12, -- Terrain.WaterWaveSpeed: cycles a minute, 0..100
	},

	-- Keys across the bay (the roast, point 3: a rectangle of open water with no shape in it): low sand islands with a
	-- grassy crown and a pale shoal round them under the water, written into the terrain after the water
	-- (Dev/WaterBuilder islands). Each is a chain of balls along its axis (`at` its middle in plan x, z; `length`
	-- studs; `yaw` degrees from x), so it reads long and soft-edged. Kept clear of the causeway (x -60..60), every road,
	-- the bay's centre and its shores. sand/grass: a ball's radius and how far its top stands over the water line; the
	-- grass ball is smaller, so a ring of beach shows round it. `step`: studs between the balls of a chain.
	islands = {
		list = {
			{ at = Vector2.new(470, 2330), length = 240, yaw = 18 },
			{ at = Vector2.new(-500, 2390), length = 170, yaw = -14 },
			{ at = Vector2.new(660, 2070), length = 90, yaw = 40 },
		},
		-- Seen from the causeway 2026-10-26: a 40-stud grass ball 4.5 over the water read as a hill; these are flat keys.
		sand = { radius = 160, rise = 2.2 },
		grass = { radius = 90, rise = 3 },
		step = 30,
		sandMaterial = Enum.Material.Sand,
		grassMaterial = Enum.Material.Grass,
	},

	seabed = {
		-- At a lake's edge the seabed meets the ground a little under its top (y = 0), so the ground's own surface hides
		-- the seam and the two never draw over each other.
		rimY = -0.3,
		-- The seabed runs on this far under the ground past a lake's edge, at rimY and dry, so no gap shows at the seam.
		lip = 8,
		-- Solid seabed below the deepest point (the bottom voxel layer).
		under = 4,
		shores = {
			-- A beach: the water line about 8 studs out, then a long shelf of shallows (a stud or three deep for 90
			-- studs: the pale sand shows through, turquoise), then deeper offshore.
			beach = {
				profile = {
					Vector2.new(8, 0),
					Vector2.new(40, 1.4),
					Vector2.new(90, 3.4),
					Vector2.new(150, 7),
					Vector2.new(240, 14),
					Vector2.new(340, 22),
				},
				material = Enum.Material.Sand,
			},
			-- A seawall: deep water at its foot (a stone bank down to 10 studs within 14), then the bay's floor.
			wall = {
				profile = {
					Vector2.new(3, 2),
					Vector2.new(14, 10),
					Vector2.new(60, 14),
					Vector2.new(180, 19),
					Vector2.new(300, 22),
				},
				material = Enum.Material.Sand,
				stone = Enum.Material.Limestone,
				stoneReach = 16,
			},
		} :: { [string]: Shore },
		-- Terrain:SetMaterialColor for the seabed's materials: a pale sand (it is what turns clear water turquoise) and
		-- the coping's stone.
		colors = {
			[Enum.Material.Sand] = rgb(226, 212, 172),
			[Enum.Material.Limestone] = rgb(204, 188, 152),
			[Enum.Material.Grass] = rgb(88, 122, 62), -- the islands' crowns (the engine's own grass reads straw-yellow)
		} :: { [Enum.Material]: Color3 },
	},

	build = {
		stripColumns = 16, -- voxel columns along X per write; the build yields between writes
		minOccupancy = 1 / 256, -- less solid than this in a voxel counts as none
		-- Studs: the engine draws (and collides) a solid voxel's surface half a voxel above its occupancy level (seen in
		-- Studio 2026-10-26: a seabed written at -9 stood at -7, the lip written at -0.3 stood 1.7 over the ground),
		-- while water draws at its level. So the seabed is written this much lower than Util/WaterShape's, and stands
		-- where WaterShape says.
		solidLift = 2,
	},

	dry = {
		-- Studs: a road or spot over the water stands at least this far above the water line, so nothing at ground
		-- level (2 studs over it) may reach over the water; the bridge's deck clears it by 22.
		clearance = 8,
		roadStep = 8, -- studs between the points checked along each road
	},

	rescue = {
		interval = 0.5,
		touch = 1,
		depth = 4,
		seconds = 3,
		flippedDot = 0.2,
		flippedSeconds = 1.5,
		-- Long enough that a driver who stops in the shallows for a look isn't moved straight away.
		stuckSpeed = 2,
		stuckSeconds = 8,
		reason = "water",
		message = "Your car was pulled out of the water.",
		kind = "info",
	} :: Rescue,
}

return Water
