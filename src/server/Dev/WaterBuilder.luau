--!strict
-- WaterBuilder: the bay as terrain water (docs/city/SCENERY.md §3; Config/Water; Util/WaterShape).
--
-- Edit-mode tool only (CLAUDE.md hard rule 9). Run it from MCP execute_luau (Edit datamodel) or the command bar:
--   require(game.ServerScriptService.Server.Dev.WaterBuilder).build()
-- It owns Workspace.Terrain and nothing else of the map (Dev/MapBuilder owns Workspace.Map.Generated): build() clears
-- the terrain, sets the terrain's water look (Config/Water look) and its seabed colours, then writes every water area
-- of Util/WaterShape into it, a strip of voxel columns at a time (yielding between strips so Studio stays
-- responsive): the seabed in sand (stone on a seawall's bank) sloping from the ground at each edge down offshore, and
-- water over it up to the lake's water line. Nothing else: no road, pier, causeway or building is terrain, and the
-- water stays inside the lakes, below every road (Dev/MapCheck and tests/Water.spec check). Building twice writes the
-- same terrain.
--
-- While Config/Water.terrain is on, Dev/MapBuilder leaves out the old part water, the lake bed and its banks, so run
-- this once after the place's first MapBuilder build with it on (the terrain saves with the place; MapBuilder never
-- touches it).
--
-- Voxels: written with Terrain:WriteVoxelChannels (a voxel holds sand and water together, so the water meets the
-- sloping sand cleanly). Where that call fails (an older place), with Terrain:WriteVoxels instead: a voxel is then
-- either seabed or water.
--
-- Pure helpers (tests/Water.spec): region(area), voxels(area, from, to), fallback(channels), dryProblems(...).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage.Shared.Config
local Graph = require(ReplicatedStorage.Shared.Road.Graph)
local MapLayout = require(Config.MapLayout)
local Water = require(Config.Water)
local WaterShape = require(ReplicatedStorage.Shared.Util.WaterShape)

type Area = WaterShape.Area

-- The three voxel channels of a region, each indexed [x][y][z] from 1 (Terrain:WriteVoxelChannels).
export type Channels = {
	SolidMaterial: { { { Enum.Material } } },
	SolidOccupancy: { { { number } } },
	LiquidOccupancy: { { { number } } },
}

export type Report = {
	areas: number,
	strips: number,
	method: string, -- "channels" (WriteVoxelChannels) or "voxels" (WriteVoxels), "" when nothing was written
	cells: number, -- Terrain:CountCells() after the build
	wet: { [string]: boolean }, -- each area's centre reads back as water
}

-- A road or gameplay spot (Dev/MapCheck, tests/Water.spec): it must not stand in the water.
export type Spot = { name: string, position: Vector3, reach: number } -- reach: studs across the ground from position

local VOXEL = 4

local WaterBuilder = {}

local function down(value: number): number
	return math.floor(value / VOXEL) * VOXEL
end

local function up(value: number): number
	return math.ceil(value / VOXEL) * VOXEL
end

-- The voxel-aligned box (studs) the build writes for `area`: its water and its lip, from under the deepest seabed to
-- above the water line and the edge.
function WaterBuilder.region(area: Area): (Vector3, Vector3)
	local lip = Water.seabed.lip
	local low = math.min(area.bedY, Water.seabed.rimY, area.waterY) - Water.seabed.under - Water.build.solidLift
	local high = math.max(area.waterY, Water.seabed.rimY)
	return Vector3.new(down(area.min.X - lip), down(low), down(area.min.Y - lip)),
		Vector3.new(up(area.max.X + lip), up(high), up(area.max.Y + lip))
end

-- The voxels of `area` in the voxel-aligned box `from`..`to` (studs): each column's seabed (Util/WaterShape column at
-- the column's centre) as solid occupancy by how much of each voxel lies under it, and, inside the area's edges, its
-- water as liquid occupancy by how much of each voxel lies under the water line (none in a voxel the seabed fills,
-- none on the lip).
function WaterBuilder.voxels(area: Area, from: Vector3, to: Vector3): Channels
	local function count(span: number): number
		return math.floor(span / VOXEL + 0.5)
	end
	local nx, ny, nz = count(to.X - from.X), count(to.Y - from.Y), count(to.Z - from.Z)
	local minOccupancy = Water.build.minOccupancy
	-- The engine draws a solid surface half a voxel above its occupancy level (Config/Water build.solidLift): write the
	-- seabed that much lower so it stands where WaterShape says.
	local lift = Water.build.solidLift
	local materials: { { { Enum.Material } } } = table.create(nx)
	local solids: { { { number } } } = table.create(nx)
	local liquids: { { { number } } } = table.create(nx)
	for i = 1, nx do
		local cx = from.X + VOXEL * (i - 0.5)
		local columnsM: { { Enum.Material } } = table.create(ny)
		local columnsS: { { number } } = table.create(ny)
		local columnsL: { { number } } = table.create(ny)
		for j = 1, ny do
			columnsM[j] = table.create(nz, Enum.Material.Air)
			columnsS[j] = table.create(nz, 0)
			columnsL[j] = table.create(nz, 0)
		end
		for k = 1, nz do
			local cz = from.Z + VOXEL * (k - 0.5)
			local column = WaterShape.column(area, cx, cz)
			if column == nil then
				continue
			end
			for j = 1, ny do
				local y0 = from.Y + VOXEL * (j - 1)
				local solid = math.clamp((column.seabed - lift - y0) / VOXEL, 0, 1)
				if solid < minOccupancy then
					solid = 0
				end
				-- Water to the water line in every column inside the area, even where the sand stands higher: the sand
				-- hides it there, and the water's edge follows the sand's slope instead of a voxel's edge.
				local liquid = 0
				if column.inside and solid < 1 then
					-- Water fills at most what the seabed leaves of the voxel (the engine's rule; overfilled voxels draw as
					-- dark deep water at low graphics quality, seen in Studio 2026-10-26).
					liquid = math.min(math.clamp((area.waterY - y0) / VOXEL, 0, 1), 1 - solid)
					if liquid < minOccupancy then
						liquid = 0
					end
				end
				columnsS[j][k] = solid
				columnsL[j][k] = liquid
				if solid > 0 then
					columnsM[j][k] = column.material
				end
			end
		end
		materials[i] = columnsM
		solids[i] = columnsS
		liquids[i] = columnsL
	end
	return { SolidMaterial = materials, SolidOccupancy = solids, LiquidOccupancy = liquids }
end

-- The same voxels for Terrain:WriteVoxels, where a voxel holds one material: seabed where there is any, else water.
function WaterBuilder.fallback(channels: Channels): ({ { { Enum.Material } } }, { { { number } } })
	local materials: { { { Enum.Material } } } = {}
	local occupancy: { { { number } } } = {}
	for i, plane in channels.SolidMaterial do
		local outM: { { Enum.Material } } = {}
		local outO: { { number } } = {}
		for j, row in plane do
			local rowM: { Enum.Material } = table.create(#row)
			local rowO: { number } = table.create(#row)
			for k, material in row do
				local solid = channels.SolidOccupancy[i][j][k]
				local liquid = channels.LiquidOccupancy[i][j][k]
				if solid > 0 then
					rowM[k], rowO[k] = material, solid
				elseif liquid > 0 then
					rowM[k], rowO[k] = Enum.Material.Water, liquid
				else
					rowM[k], rowO[k] = Enum.Material.Air, 0
				end
			end
			outM[j] = rowM
			outO[j] = rowO
		end
		materials[i] = outM
		occupancy[i] = outO
	end
	return materials, occupancy
end

---------------------------------------------------------------------------------------------------------------
-- Dry ground for the game (pure): no road or gameplay spot stands in the water
---------------------------------------------------------------------------------------------------------------

-- Every gameplay spot of `layout` (default Config/MapLayout): its locations (house plots among them), display pads,
-- player spawns, jump ramps, billboards, landmarks and features, each with how far it reaches across the ground.
function WaterBuilder.spots(layout: any?): { Spot }
	local data: any = layout or MapLayout
	local out: { Spot } = {}
	local function reach(size: Vector3): number
		return math.sqrt(size.X * size.X + size.Z * size.Z) / 2
	end
	for _, location in data.locations or {} do
		table.insert(
			out,
			{ name = `location {location.id}`, position = location.position, reach = reach(location.size) }
		)
	end
	local dealership = data.dealership
	if dealership then
		for _, section in dealership.sections do
			for index, pad in section.pads do
				local name = `dealership pad {section.brandId} {index}`
				table.insert(out, { name = name, position = pad.Position, reach = reach(dealership.padSize) })
			end
		end
	end
	local usedLot = data.usedLot
	if usedLot then
		for index, pad in usedLot.pads do
			table.insert(
				out,
				{ name = `used lot pad {index}`, position = pad.Position, reach = reach(usedLot.padSize) }
			)
		end
	end
	for index, spawn in data.playerSpawns or {} do
		table.insert(out, { name = `player spawn {index}`, position = spawn.Position, reach = 3 })
	end
	for _, ramp in data.jumpRamps or {} do
		table.insert(out, { name = `jump ramp {ramp.id}`, position = ramp.position, reach = reach(ramp.size) })
	end
	for _, board in data.billboards or {} do
		table.insert(out, { name = `billboard {board.id}`, position = board.position, reach = reach(board.size) })
	end
	for _, landmark in data.landmarks or {} do
		local name = `landmark {landmark.id}`
		table.insert(out, { name = name, position = landmark.position, reach = reach(landmark.size) })
	end
	for _, feature in data.features or {} do
		-- A bridge's arches stand beside its deck over the water by design: their deck point counts, not their span.
		local span = if feature.kind == "bridge_arch" then 0 else reach(feature.size)
		table.insert(out, { name = `feature {feature.id}`, position = feature.position, reach = span })
	end
	return out
end

-- Studs across the ground from (x, z) to the rectangle min..max (0 inside).
local function rectGap(x: number, z: number, min: Vector2, max: Vector2): number
	local dx = math.max(min.X - x, 0, x - max.X)
	local dz = math.max(min.Y - z, 0, z - max.Y)
	return math.sqrt(dx * dx + dz * dz)
end

-- Problems with the game's dry ground: every road (sampled every Config/Water dry.roadStep studs along its centre line,
-- out to its edges) and every spot that reaches over an area's water must stand dry.clearance above its water line.
-- Defaults: the county's areas, road graph and spots. Each problem names the road or spot and the area.
function WaterBuilder.dryProblems(areas: { Area }?, graph: Graph.Api?, spots: { Spot }?): { string }
	local list = areas or WaterShape.areas()
	local roads = graph or Graph
	local problems: { string } = {}
	local clearance = Water.dry.clearance
	local step = Water.dry.roadStep
	local function check(name: string, position: Vector3, reach: number)
		for _, area in list do
			if rectGap(position.X, position.Z, area.min, area.max) > reach then
				continue
			end
			if position.Y < area.waterY + clearance then
				table.insert(
					problems,
					string.format(
						"%s at (%.0f, %.1f, %.0f) is in %s's water (its line is at %.1f)",
						name,
						position.X,
						position.Y,
						position.Z,
						area.id,
						area.waterY
					)
				)
			end
		end
	end
	for index, edge in roads.edges() do
		local length = roads.edgeLength(index)
		local count = math.max(1, math.ceil(length / step))
		local half = roads.edgeWidth(index) / 2
		for s = 0, count do
			check(`road {edge.from}-{edge.to}`, roads.pointOnEdge(index, s / count), half)
		end
	end
	for _, node in roads.nodes() do
		check(`road node {node.id}`, node.position, 0)
	end
	for _, spot in spots or WaterBuilder.spots() do
		check(spot.name, spot.position, spot.reach)
	end
	return problems
end

---------------------------------------------------------------------------------------------------------------
-- Reading the terrain back (Edit mode or runtime): is there water in the voxel at a point?
---------------------------------------------------------------------------------------------------------------

function WaterBuilder.wetAt(position: Vector3): boolean
	local terrain = Workspace.Terrain
	local corner = Vector3.new(down(position.X), down(position.Y), down(position.Z))
	local region = Region3.new(corner, corner + Vector3.one * VOXEL)
	local ok, liquid = pcall(function(): number
		local read = (terrain :: any):ReadVoxelChannels(region, VOXEL, { "LiquidOccupancy" })
		return read.LiquidOccupancy[1][1][1]
	end)
	if ok and type(liquid) == "number" then
		return liquid > 0
	end
	local materials = terrain:ReadVoxels(region, VOXEL)
	return materials[1][1][1] == Enum.Material.Water
end

---------------------------------------------------------------------------------------------------------------
-- The build
---------------------------------------------------------------------------------------------------------------

local function applyLook(terrain: Terrain)
	local look = Water.look
	terrain.WaterColor = look.color
	terrain.WaterTransparency = look.transparency
	terrain.WaterReflectance = look.reflectance
	terrain.WaterWaveSize = look.waveSize
	terrain.WaterWaveSpeed = look.waveSpeed
	for material, color in Water.seabed.colors do
		terrain:SetMaterialColor(material, color)
	end
end

-- The balls each island of Config/Water islands in `area` is written as: { centre, radius, material }, an island's sand
-- before its grass, in plan order. Pure (tests/Water.spec).
function WaterBuilder.islandBalls(area: Area): { { centre: Vector3, radius: number, material: Enum.Material } }
	local I = Water.islands
	local waterY = area.waterY
	local out: { { centre: Vector3, radius: number, material: Enum.Material } } = {}
	for _, island in I.list do
		local at = island.at
		if at.X < area.min.X or at.X > area.max.X or at.Y < area.min.Y or at.Y > area.max.Y then
			continue
		end
		local yaw = math.rad(island.yaw)
		local axis = Vector2.new(math.cos(yaw), math.sin(yaw))
		local n = math.max(1, math.floor(island.length / I.step + 0.5))
		for _, layer in { { I.sand, I.sandMaterial }, { I.grass, I.grassMaterial } } do
			local ball, material = layer[1], layer[2]
			for k = 1, n do
				local along = (k - (n + 1) / 2) * I.step
				local p = island.at + axis * along
				local y = waterY + ball.rise - ball.radius
				table.insert(out, { centre = Vector3.new(p.X, y, p.Y), radius = ball.radius, material = material })
			end
		end
	end
	return out
end

-- Writes the area's islands into the terrain (after its water: each ball replaces the water and seabed inside it), then
-- clears what the balls put below the seabed's bottom layer (nothing shows there; it only adds cells).
local function writeIslands(terrain: Terrain, area: Area)
	local balls = WaterBuilder.islandBalls(area)
	for _, ball in balls do
		terrain:FillBall(ball.centre, ball.radius, ball.material)
		task.wait()
	end
	local floor = down(math.min(area.bedY, Water.seabed.rimY) - Water.seabed.under - Water.build.solidLift)
	for _, ball in balls do
		local bottom = down(ball.centre.Y - ball.radius) - VOXEL
		if bottom < floor then
			local size = Vector3.new(2 * ball.radius + 2 * VOXEL, floor - bottom, 2 * ball.radius + 2 * VOXEL)
			local at = Vector3.new(ball.centre.X, (floor + bottom) / 2, ball.centre.Z)
			terrain:FillBlock(CFrame.new(at), size, Enum.Material.Air)
		end
	end
end

local running = false

-- Clears Workspace.Terrain and writes every water area into it, then the islands. Returns what it wrote.
function WaterBuilder.build(): Report
	if not RunService:IsStudio() then
		error("WaterBuilder is a Studio-only tool", 2)
	end
	if RunService:IsRunning() then
		error("WaterBuilder runs in Edit mode only; stop the playtest first", 2)
	end
	if running then
		error("WaterBuilder is already running", 2)
	end
	running = true
	local report: Report = { areas = 0, strips = 0, method = "", cells = 0, wet = {} }
	local ok, err = pcall(function()
		local terrain = Workspace.Terrain
		terrain:Clear()
		applyLook(terrain)
		local width = Water.build.stripColumns * VOXEL
		for _, area in WaterShape.areas() do
			report.areas += 1
			local low, high = WaterBuilder.region(area)
			local x = low.X
			while x < high.X do
				local x1 = math.min(x + width, high.X)
				local from, to = Vector3.new(x, low.Y, low.Z), Vector3.new(x1, high.Y, high.Z)
				local channels = WaterBuilder.voxels(area, from, to)
				local region = Region3.new(from, to)
				if report.method ~= "voxels" then
					local wrote, why = pcall(function()
						(terrain :: any):WriteVoxelChannels(region, VOXEL, channels)
					end)
					if wrote then
						report.method = "channels"
					elseif report.method == "channels" then
						error(why) -- worked before: a real failure
					else
						warn(`[WaterBuilder] WriteVoxelChannels failed ({tostring(why)}); writing whole voxels instead`)
						report.method = "voxels"
					end
				end
				if report.method == "voxels" then
					local materials, occupancy = WaterBuilder.fallback(channels)
					terrain:WriteVoxels(region, VOXEL, materials, occupancy)
				end
				report.strips += 1
				x = x1
				task.wait()
			end
			writeIslands(terrain, area)
			local centre = Vector3.new((area.min.X + area.max.X) / 2, area.waterY - 1, (area.min.Y + area.max.Y) / 2)
			report.wet[area.id] = WaterBuilder.wetAt(centre)
		end
		report.cells = terrain:CountCells()
	end)
	running = false
	if not ok then
		error(`[WaterBuilder] build failed: {tostring(err)}`, 2)
	end
	local wet: { string } = {}
	for id, yes in report.wet do
		table.insert(wet, `{id} {if yes then "wet" else "DRY"}`)
	end
	table.sort(wet)
	print(
		`[WaterBuilder] {report.areas} areas, {report.strips} strips ({report.method}), {report.cells} cells; `
			.. `centres: {table.concat(wet, ", ")}`
	)
	return report
end

return WaterBuilder
