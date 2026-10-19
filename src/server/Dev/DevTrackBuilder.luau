--!strict
-- Builds Workspace.DevTrack, the Phase 1 test track: a long straight with lane paint, start and finish
-- gantries and distance boards; a skidpad (an asphalt ring with a painted circle); and a bumps lane with
-- rounded speed humps. Every number comes from Config/DevTrack, which also holds the waypoints AutoDriver uses.
--
-- Edit-mode tool only (CLAUDE.md hard rule 9). Run it from the Studio command bar or MCP execute_luau
-- (Edit datamodel):
--   require(game.ServerScriptService.Server.Dev.DevTrackBuilder).build()
--
-- The build happens in two steps. plan() is pure: it lists every part (name, size, CFrame, look) without
-- touching the place, so specs can check the layout. build() replaces Workspace.DevTrack with the planned
-- parts, yielding between chunks so Studio stays responsive. Rebuilding gives the same instances every time.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DevTrack = require(ReplicatedStorage.Shared.Config.DevTrack)

local TRACK_NAME = "DevTrack"

export type PartSpec = {
	section: string, -- folder inside Workspace.DevTrack
	name: string,
	shape: "block" | "cylinder", -- cylinders run along their local X axis
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	solid: boolean, -- driving surfaces, humps, posts and walls collide; paint and markers do not
	label: string?, -- text on the face that looks toward approaching cars (+Z)
}

local DevTrackBuilder = {}

local Y = DevTrack.surfaceY
local THICKNESS = DevTrack.surfaceThickness
local COLORS = DevTrack.colors

-- A cylinder whose axis points up instead of along X.
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
-- Left and right edges, in build order.
local SIDES = { { sign = -1, suffix = "L" }, { sign = 1, suffix = "R" } }

local function block(section: string, name: string, center: Vector3, size: Vector3, color: Color3): PartSpec
	return {
		section = section,
		name = name,
		shape = "block",
		size = size,
		cframe = CFrame.new(center),
		color = color,
		material = Enum.Material.SmoothPlastic,
		solid = true,
	}
end

-- A flat asphalt slab whose top is the driving surface.
local function surface(section: string, name: string, centerX: number, width: number, z0: number, z1: number): PartSpec
	local spec = block(
		section,
		name,
		Vector3.new(centerX, Y - THICKNESS / 2, (z0 + z1) / 2),
		Vector3.new(width, THICKNESS, math.abs(z1 - z0)),
		COLORS.asphalt
	)
	spec.material = Enum.Material.Asphalt
	return spec
end

-- A strip of paint running north-south, `layer` paint steps above the surface. Not solid, so wheel raycasts
-- and collisions only ever see the asphalt underneath.
local function paint(section: string, name: string, x: number, width: number, z0: number, z1: number, layer: number)
	local top = Y + layer * DevTrack.paintRaise
	local spec = block(
		section,
		name,
		Vector3.new(x, top - DevTrack.paintThickness / 2, (z0 + z1) / 2),
		Vector3.new(width, DevTrack.paintThickness, math.abs(z1 - z0)),
		COLORS.paint
	)
	spec.solid = false
	return spec
end

-- A post with a sign board on top; the board's text faces approaching cars.
local function sign(add: (PartSpec) -> (), section: string, name: string, x: number, z: number, text: string)
	local s = DevTrack.signs
	local postSize = Vector3.new(s.postSize, s.postHeight, s.postSize)
	add(block(section, `{name}Post`, Vector3.new(x, Y + s.postHeight / 2, z), postSize, COLORS.post))
	local board = block(
		section,
		`{name}Board`,
		Vector3.new(x, Y + s.postHeight + s.boardHeight / 2, z),
		Vector3.new(s.boardWidth, s.boardHeight, s.boardThickness),
		COLORS.board
	)
	board.label = text
	add(board)
end

-- The long straight: asphalt, edge lines, dashed lane dividers, checkered start and finish lines under
-- gantries, distance boards every `boardEvery` studs, and a wall at the end of the run-off.
local function planStraight(add: (PartSpec) -> ())
	local s = DevTrack.straight
	local section = "Straight"
	local halfWidth = s.width / 2
	local farZ = s.nearZ - s.length
	local startZ = DevTrack.straightStart.Z
	local finishZ = DevTrack.straightEnd.Z

	local segments = math.ceil(s.length / s.segmentLength)
	for i = 1, segments do
		local z0 = s.nearZ - (i - 1) * s.segmentLength
		local z1 = math.max(s.nearZ - i * s.segmentLength, farZ)
		add(surface(section, `Surface{i}`, s.centerX, s.width, z0, z1))
		for _, side in SIDES do
			local x = s.centerX + side.sign * (halfWidth - s.edgeInset)
			add(paint(section, `Edge{side.suffix}{i}`, x, s.lineWidth, z0, z1, 1))
		end
	end

	for lane = 1, s.lanes - 1 do
		local x = s.centerX - halfWidth + lane * s.laneWidth
		local distance = s.dashGap / 2
		local dash = 0
		while distance + s.dashLength <= s.length do
			dash += 1
			local z0 = s.nearZ - distance
			add(paint(section, `Lane{lane}Dash{dash}`, x, s.lineWidth, z0, z0 - s.dashLength, 1))
			distance += s.dashLength + s.dashGap
		end
	end

	-- Checkered lines sit one paint step above the dashes they cross.
	local function checkerLine(name: string, z: number)
		local columns = math.floor(s.width / s.checkerSize)
		local left = s.centerX - columns * s.checkerSize / 2
		local square = 0
		for row = 0, 1 do
			for column = 0, columns - 1 do
				if (row + column) % 2 == 0 then
					square += 1
					local x = left + (column + 0.5) * s.checkerSize
					local z0 = z - row * s.checkerSize
					add(paint(section, `{name}Square{square}`, x, s.checkerSize, z0, z0 - s.checkerSize, 2))
				end
			end
		end
	end

	local function gantryAt(name: string, z: number, text: string)
		local g = DevTrack.gantry
		local postX = halfWidth + s.boardOffset
		for _, side in SIDES do
			add(
				block(
					section,
					`{name}Post{side.suffix}`,
					Vector3.new(s.centerX + side.sign * postX, Y + g.height / 2, z),
					Vector3.new(g.postSize, g.height, g.postSize),
					COLORS.post
				)
			)
		end
		add(
			block(
				section,
				`{name}Beam`,
				Vector3.new(s.centerX, Y + g.height - g.beamHeight / 2, z),
				Vector3.new(2 * postX + g.postSize, g.beamHeight, g.postSize),
				COLORS.post
			)
		)
		-- The board hangs on the beam's south face, toward cars coming up the straight.
		local board = block(
			section,
			`{name}Board`,
			Vector3.new(s.centerX, Y + g.height - g.boardHeight / 2, z + (g.postSize + g.boardThickness) / 2),
			Vector3.new(g.boardWidth, g.boardHeight, g.boardThickness),
			COLORS.board
		)
		board.label = text
		add(board)
	end

	checkerLine("StartLine", startZ)
	checkerLine("FinishLine", finishZ)
	gantryAt("StartGantry", startZ, "START")
	gantryAt("FinishGantry", finishZ, "FINISH")

	local boardX = s.centerX + halfWidth + s.boardOffset
	local distance = s.boardEvery
	while distance < s.finishFromStart do
		sign(add, section, `Distance{distance}`, boardX, startZ - distance, tostring(distance))
		distance += s.boardEvery
	end

	add(
		block(
			section,
			"EndBarrier",
			Vector3.new(s.centerX, Y + s.barrierHeight / 2, farZ - s.barrierThickness / 2),
			Vector3.new(s.width + 2 * s.boardOffset, s.barrierHeight, s.barrierThickness),
			COLORS.barrier
		)
	)
end

-- The skidpad: stacked discs, each a paint step above the last. Outer asphalt, a slightly smaller white disc
-- and a slightly smaller asphalt disc leave a thin painted circle at lineRadius; a grass infield fills the
-- middle. Orange markers on the infield show where the loop waypoints are.
local function planSkidpad(add: (PartSpec) -> ())
	local k = DevTrack.skidpad
	local section = "Skidpad"

	local function disc(name: string, radius: number, layer: number, color: Color3, material: Enum.Material)
		local top = Y + layer * DevTrack.paintRaise
		add({
			section = section,
			name = name,
			shape = "cylinder",
			size = Vector3.new(THICKNESS, 2 * radius, 2 * radius),
			cframe = CFrame.new(k.centerX, top - THICKNESS / 2, k.centerZ) * UPRIGHT,
			color = color,
			material = material,
			solid = true,
		})
	end

	disc("Asphalt", k.outerRadius, 0, COLORS.asphalt, Enum.Material.Asphalt)
	disc("Line", k.lineRadius + k.lineWidth / 2, 1, COLORS.paint, Enum.Material.SmoothPlastic)
	disc("InnerAsphalt", k.lineRadius - k.lineWidth / 2, 2, COLORS.asphalt, Enum.Material.Asphalt)
	disc("Infield", k.innerRadius, 3, COLORS.infield, Enum.Material.Grass)

	local infieldTop = Y + 3 * DevTrack.paintRaise
	local markerRadius = k.innerRadius - k.markerInset
	for i = 1, k.loopPoints do
		local point = DevTrack.skidpadLoop[i]
		local direction = (point - DevTrack.skidpadCenter).Unit
		local at = DevTrack.skidpadCenter + direction * markerRadius
		add({
			section = section,
			name = `Marker{i}`,
			shape = "cylinder",
			size = Vector3.new(k.markerHeight, k.markerDiameter, k.markerDiameter),
			cframe = CFrame.new(at.X, infieldTop + k.markerHeight / 2, at.Z) * UPRIGHT,
			color = COLORS.marker,
			material = Enum.Material.SmoothPlastic,
			solid = false,
		})
	end
end

-- The bumps lane: asphalt with edge lines, rounded humps across it, and a sign at the near end.
local function planBumps(add: (PartSpec) -> ())
	local b = DevTrack.bumps
	local section = "Bumps"
	local halfWidth = b.width / 2
	local farZ = b.nearZ - b.length
	local edgeInset = DevTrack.straight.edgeInset
	local lineWidth = DevTrack.straight.lineWidth

	local segments = math.ceil(b.length / b.segmentLength)
	for i = 1, segments do
		local z0 = b.nearZ - (i - 1) * b.segmentLength
		local z1 = math.max(b.nearZ - i * b.segmentLength, farZ)
		add(surface(section, `Surface{i}`, b.centerX, b.width, z0, z1))
		for _, side in SIDES do
			local x = b.centerX + side.sign * (halfWidth - edgeInset)
			add(paint(section, `Edge{side.suffix}{i}`, x, lineWidth, z0, z1, 1))
		end
	end

	-- A hump is the top of a long cylinder lying across the lane, sunk so only an arc `height` tall and
	-- `chord` long shows above the asphalt. Radius of that circle: (chord^2 / 4 + height^2) / (2 * height).
	local radius = (b.chord * b.chord / 4 + b.height * b.height) / (2 * b.height)
	for i, distance in b.at do
		add({
			section = section,
			name = `Hump{i}`,
			shape = "cylinder",
			size = Vector3.new(b.width, 2 * radius, 2 * radius),
			cframe = CFrame.new(b.centerX, Y + b.height - radius, b.nearZ - distance),
			color = COLORS.bump,
			material = Enum.Material.SmoothPlastic,
			solid = true,
		})
	end

	local signX = b.centerX - halfWidth - DevTrack.straight.boardOffset
	sign(add, section, "Sign", signX, b.nearZ - DevTrack.signs.boardWidth, `SPEED BUMPS {b.signMph} MPH`)
end

-- Every part of the track, in build order. Pure: creates no instances.
function DevTrackBuilder.plan(): { PartSpec }
	local specs: { PartSpec } = {}
	local function add(spec: PartSpec)
		table.insert(specs, spec)
	end
	planStraight(add)
	planSkidpad(add)
	planBumps(add)
	return specs
end

local function addLabel(part: BasePart, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = Enum.NormalId.Back -- +Z: toward cars driving north up the track
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = DevTrack.signs.pixelsPerStud
	gui.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = COLORS.text
	label.Font = Enum.Font.GothamBold
	label.Parent = gui

	gui.Parent = part
end

local function createPart(spec: PartSpec): Part
	local part = Instance.new("Part")
	part.Name = spec.name
	part.Shape = if spec.shape == "cylinder" then Enum.PartType.Cylinder else Enum.PartType.Block
	part.Size = spec.size
	part.CFrame = spec.cframe
	part.Color = spec.color
	part.Material = spec.material
	part.Anchored = true
	part.CanCollide = spec.solid
	part.CanQuery = spec.solid
	part.CanTouch = false
	part.CastShadow = spec.solid
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if spec.label then
		addLabel(part, spec.label)
	end
	return part
end

local building = false

-- Replaces Workspace.DevTrack with a fresh build. Returns the number of parts built.
function DevTrackBuilder.build(): number
	if not RunService:IsStudio() then
		error("DevTrackBuilder is a Studio-only tool", 2)
	end
	if RunService:IsRunning() then
		error("DevTrackBuilder runs in Edit mode only; stop the playtest first", 2)
	end
	if building then
		error("DevTrackBuilder is already building", 2)
	end
	building = true

	local ok, result = pcall(function(): number
		local specs = DevTrackBuilder.plan()

		local old = Workspace:FindFirstChild(TRACK_NAME)
		if old then
			old:Destroy()
		end

		local track = Instance.new("Model")
		track.Name = TRACK_NAME
		-- Always streamed in, so a car at full speed never outruns the track on a client.
		track.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		track:SetAttribute("BuiltBy", "DevTrackBuilder")
		track.Parent = Workspace

		local sections: { [string]: Folder } = {}
		for i, spec in specs do
			local folder = sections[spec.section]
			if folder == nil then
				local newFolder = Instance.new("Folder")
				newFolder.Name = spec.section
				newFolder.Parent = track
				sections[spec.section] = newFolder
				folder = newFolder
			end
			createPart(spec).Parent = folder
			if i % DevTrack.partsPerChunk == 0 then
				task.wait()
			end
		end
		return #specs
	end)

	building = false
	if not ok then
		error(result, 0)
	end
	print(`[DevTrackBuilder] built {TRACK_NAME} with {result} parts`)
	return result
end

return DevTrackBuilder
