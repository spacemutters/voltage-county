--!strict
-- Phase 1 generation spike (PLAN.md Phase 1, "Generation spike"): timeboxed research, not production code.
-- Asks GenerationService for 3 original test cars (PredefinedSchema "Car5": a "body" and four named wheels) and
-- 2 accessories ("Body1": a single MeshPart), with generic prompts only (CLAUDE.md hard rule 4). For each it
-- records latency, success or the error text, part names, triangle counts when readable, bounding size, and the
-- wheel centers relative to the body. Models are kept under ServerStorage.GenerationSpike; the report is
-- returned, printed, and saved there as JSON (StringValue "ReportJson") so any script context can read it.
--
-- Studio only, and never runs by itself. In a playtest, MCP execute_luau in the Server datamodel:
--   require(game.ServerScriptService.Server.Dev.GenerationSpike).run()
-- run({ display = true }) also lines copies up in Workspace.GenerationSpikeDisplay to look at.
--
-- API as checked on 2026-10-19 against create.roblox.com/docs/parts/model-generation and the GenerationService
-- reference: GenerateModelAsync(inputs, schema, options?) yields and returns (model, metadata); inputs take
-- TextPrompt (and Image); schema takes PredefinedSchema ("Car5", "Body1") or SchemaDefinition.Groups. Car5 part
-- names are guaranteed. Not confirmed there (so not relied on): input names for size or a triangle limit, what
-- metadata holds, quotas or cost, and whether it must run on the server. Only TextPrompt is passed.

local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

type Vec3 = { number } -- {x, y, z}, rounded for reading

export type PartReport = {
	name: string,
	className: string,
	size: Vec3, -- studs
	triangles: number?, -- nil when the mesh could not be read
	triangleSource: string, -- how the count was read, or why it couldn't be
	meshId: string?, -- an asset URI means the mesh is saved; empty means it lives only in this session
	appearance: { string }, -- class names of children (SurfaceAppearance and the like)
}

export type Entry = {
	label: string,
	kind: string, -- "car" or "accessory"
	schema: string,
	prompt: string,
	ok: boolean,
	error: string?,
	latencySec: number,
	storedAs: string?, -- name under ServerStorage.GenerationSpike
	boundingSize: Vec3?,
	partNames: { string },
	parts: { PartReport },
	totalTriangles: number?, -- nil unless every part's count was readable
	missingParts: { string }, -- Car5 parts the schema promises but the model lacks
	wheels: { [string]: Vec3 }?, -- FL/FR/RL/RR wheel centers in the body's own space
	wheelbase: number?, -- front axle center to rear axle center, studs
	track: number?, -- left to right wheel center, averaged over both axles
	wheelDiameter: number?, -- average of each wheel's largest dimension
	frontDirection: Vec3?, -- unit vector rear axle -> front axle, in body space (which way the car faces)
	metadata: string?, -- the second return value, described as text
}

export type Report = {
	startedAt: string,
	totalSec: number,
	succeeded: number,
	failed: number,
	entries: { Entry },
	notes: { string },
}

type Job = { label: string, kind: string, schema: string, prompt: string }

-- Generic, original prompts only: no brands, no real models, no logos or text.
local JOBS: { Job } = {
	{
		label = "car1_hatchback",
		kind = "car",
		schema = "Car5",
		prompt = "compact electric hatchback, smooth rounded panels, short hood, no logos or text",
	},
	{
		label = "car2_pickup",
		kind = "car",
		schema = "Car5",
		prompt = "mid-size pickup truck with an open cargo bed, flat angular panels, no logos or text",
	},
	{
		label = "car3_coupe",
		kind = "car",
		schema = "Car5",
		prompt = "low two-door sports coupe, wide stance, sleek wedge shape, no logos or text",
	},
	{
		label = "acc1_roof_box",
		kind = "accessory",
		schema = "Body1",
		prompt = "roof cargo box for a car, smooth aerodynamic shell, matte black, no logos or text",
	},
	{
		label = "acc2_rear_wing",
		kind = "accessory",
		schema = "Body1",
		prompt = "rear wing spoiler for a car, flat blade on two supports, no logos or text",
	},
}

-- Car5 part names (guaranteed by the schema) and the short keys the report uses for the wheels.
local BODY_NAME = "body"
local WHEEL_NAMES: { [string]: string } = {
	FL = "front left wheel",
	FR = "front right wheel",
	RL = "rear left wheel",
	RR = "rear right wheel",
}
local WHEEL_ORDER = { "FL", "FR", "RL", "RR" }

local FOLDER_NAME = "GenerationSpike"
local REPORT_VALUE_NAME = "ReportJson"
local DISPLAY_FOLDER_NAME = "GenerationSpikeDisplay"
local DISPLAY_ORIGIN = Vector3.new(0, 0, 80) -- where display copies start (clear of the spawn at the origin)
local DISPLAY_GAP = 6 -- studs between display copies
local DECIMALS = 100 -- report numbers are rounded to 1/DECIMALS
local MAX_METADATA_CHARS = 600

local NOTES = {
	"Inputs: only TextPrompt (and Image) are documented; size and triangle-limit field names are not, so none were passed.",
	"Metadata: its contents are undocumented; recorded as returned (see each entry's metadata).",
	"Triangles: MeshPart has no triangle-count property; counted through EditableMesh where Studio allows, else nil.",
	"Cost and quotas: not reported by the API; check the Creator Dashboard after the run.",
	"Persistence: a mesh with an empty meshId exists only in this session; saving it would need another route.",
}

local GenerationSpike = {}

local function round(value: number): number
	return math.round(value * DECIMALS) / DECIMALS
end

local function vec(v: Vector3): Vec3
	return { round(v.X), round(v.Y), round(v.Z) }
end

-- Any value as short readable text: tables shallowly as key=value pairs.
local function describe(value: any): string?
	if value == nil then
		return nil
	end
	local text: string
	if type(value) == "table" then
		local pairsText = {}
		for key, item in value do
			table.insert(pairsText, `{tostring(key)}={tostring(item)}`)
		end
		text = "{" .. table.concat(pairsText, ", ") .. "}"
	else
		text = tostring(value)
	end
	return string.sub(text, 1, MAX_METADATA_CHARS)
end

-- A descendant by exact name, then case-insensitively.
local function findNamed(root: Instance, name: string): Instance?
	local exact = root:FindFirstChild(name, true)
	if exact then
		return exact
	end
	local lower = string.lower(name)
	for _, descendant in root:GetDescendants() do
		if string.lower(descendant.Name) == lower then
			return descendant
		end
	end
	return nil
end

-- Center frame and size of a part, or of a model's bounding box.
local function boundsOf(instance: Instance): (CFrame?, Vector3?)
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	elseif instance:IsA("Model") then
		local cframe, size = instance:GetBoundingBox()
		return cframe, size
	end
	return nil, nil
end

-- Triangle count of a MeshPart, and how it was read (or why not).
local function countTriangles(part: MeshPart): (number?, string)
	-- A freshly generated mesh may still be an in-memory EditableMesh behind MeshContent.
	local okDirect, direct = pcall(function(): number?
		local content = (part :: any).MeshContent
		local object = if content then content.Object else nil
		if object ~= nil and typeof(object) == "Instance" and object:IsA("EditableMesh") then
			return #(object :: any):GetFaces()
		end
		return nil
	end)
	if okDirect and direct ~= nil then
		return direct, "MeshContent.Object"
	end
	-- Otherwise load an editable copy just to count its faces (EditableMesh faces are triangles).
	local okCopy, copied = pcall(function(): number
		local mesh = (AssetService :: any):CreateEditableMeshAsync((part :: any).MeshContent)
		local faces = #mesh:GetFaces()
		mesh:Destroy()
		return faces
	end)
	if okCopy then
		return copied, "CreateEditableMeshAsync"
	end
	return nil, `unreadable: {copied}`
end

local function reportPart(part: BasePart): PartReport
	local triangles: number?, source: string = nil, "not a MeshPart"
	local meshId: string? = nil
	if part:IsA("MeshPart") then
		triangles, source = countTriangles(part)
		meshId = part.MeshId
	end
	local appearance = {}
	for _, child in part:GetChildren() do
		table.insert(appearance, child.ClassName)
	end
	return {
		name = part.Name,
		className = part.ClassName,
		size = vec(part.Size),
		triangles = triangles,
		triangleSource = source,
		meshId = meshId,
		appearance = appearance,
	}
end

-- Wheel centers in the body's space, and the wheelbase, track, diameter and facing they imply.
local function measureWheels(model: Instance, entry: Entry)
	local body = findNamed(model, BODY_NAME)
	if body == nil then
		table.insert(entry.missingParts, BODY_NAME)
	end
	local centers: { [string]: Vector3 } = {}
	local diameters: { number } = {}
	for _, key in WHEEL_ORDER do
		local wheel = findNamed(model, WHEEL_NAMES[key])
		local cframe: CFrame?, size: Vector3? = nil, nil
		if wheel then
			cframe, size = boundsOf(wheel)
		end
		if cframe and size then
			centers[key] = cframe.Position
			table.insert(diameters, math.max(size.X, size.Y, size.Z))
		else
			table.insert(entry.missingParts, WHEEL_NAMES[key])
		end
	end
	local bodyFrame = if body then boundsOf(body) else nil
	if bodyFrame == nil then
		return
	end

	local wheels: { [string]: Vec3 } = {}
	local localCenters: { [string]: Vector3 } = {}
	for key, center in centers do
		localCenters[key] = bodyFrame:PointToObjectSpace(center)
		wheels[key] = vec(localCenters[key])
	end
	entry.wheels = wheels

	local fl, fr, rl, rr = localCenters.FL, localCenters.FR, localCenters.RL, localCenters.RR
	if fl and fr and rl and rr then
		local front, rear = (fl + fr) / 2, (rl + rr) / 2
		entry.wheelbase = round((front - rear).Magnitude)
		entry.track = round(((fl - fr).Magnitude + (rl - rr).Magnitude) / 2)
		if (front - rear).Magnitude > 0 then
			entry.frontDirection = vec((front - rear).Unit)
		end
	end
	if #diameters > 0 then
		local sum = 0
		for _, diameter in diameters do
			sum += diameter
		end
		entry.wheelDiameter = round(sum / #diameters)
	end
end

local function generate(job: Job, folder: Folder): Entry
	local entry: Entry = {
		label = job.label,
		kind = job.kind,
		schema = job.schema,
		prompt = job.prompt,
		ok = false,
		latencySec = 0,
		partNames = {},
		parts = {},
		missingParts = {},
	}

	local started = os.clock()
	local ok, model, metadata = pcall(function()
		local service: any = game:GetService("GenerationService")
		return service:GenerateModelAsync({ TextPrompt = job.prompt }, { PredefinedSchema = job.schema })
	end)
	entry.latencySec = round(os.clock() - started)
	if not ok then
		entry.error = tostring(model)
		return entry
	end
	entry.metadata = describe(metadata)
	if typeof(model) ~= "Instance" then
		entry.error = `no model returned (got {typeof(model)})`
		return entry
	end
	entry.ok = true

	local instance = model :: Instance
	if instance:IsA("Model") then
		entry.boundingSize = vec(instance:GetExtentsSize())
	end
	local total = 0
	local allCounted = true
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Kept still: these are for measuring and looking at, not driving.
			descendant.Anchored = true
			local part = reportPart(descendant)
			table.insert(entry.parts, part)
			table.insert(entry.partNames, part.name)
			if part.triangles then
				total += part.triangles
			else
				allCounted = false
			end
		end
	end
	if allCounted and #entry.parts > 0 then
		entry.totalTriangles = total
	end
	if job.schema == "Car5" then
		measureWheels(instance, entry)
	end

	instance.Name = job.label
	instance.Parent = folder
	entry.storedAs = job.label
	return entry
end

-- Lines copies of the stored models up in Workspace, on the ground, to look at and screenshot.
local function display(folder: Folder)
	local old = Workspace:FindFirstChild(DISPLAY_FOLDER_NAME)
	if old then
		old:Destroy()
	end
	local shown = Instance.new("Folder")
	shown.Name = DISPLAY_FOLDER_NAME
	local x = DISPLAY_ORIGIN.X
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			local copy = child:Clone()
			local _, size = copy:GetBoundingBox()
			x += size.X / 2
			copy:PivotTo(CFrame.new(x, DISPLAY_ORIGIN.Y + size.Y / 2, DISPLAY_ORIGIN.Z))
			x += size.X / 2 + DISPLAY_GAP
			copy.Parent = shown
		end
	end
	shown.Parent = Workspace
end

-- Generates everything in JOBS, one after another, and returns the report. Yields for as long as generation
-- takes. Options: display = true to also put copies in Workspace.
function GenerationSpike.run(opts: { display: boolean? }?): Report?
	if not RunService:IsStudio() or not RunService:IsServer() then
		warn("[GenerationSpike] runs only on the server in a Studio playtest")
		return nil
	end

	local folder = ServerStorage:FindFirstChild(FOLDER_NAME)
	if folder then
		folder:Destroy()
	end
	local results = Instance.new("Folder")
	results.Name = FOLDER_NAME
	results:SetAttribute("Status", "running")
	results.Parent = ServerStorage

	local report: Report = {
		startedAt = DateTime.now():ToIsoDate(),
		totalSec = 0,
		succeeded = 0,
		failed = 0,
		entries = {},
		notes = NOTES,
	}
	local started = os.clock()
	for _, job in JOBS do
		print(`[GenerationSpike] generating {job.label} ({job.schema})...`)
		local entry = generate(job, results)
		table.insert(report.entries, entry)
		if entry.ok then
			report.succeeded += 1
			local triangles = if entry.totalTriangles then tostring(entry.totalTriangles) else "?"
			print(`[GenerationSpike]   ok in {entry.latencySec} s, {#entry.parts} parts, {triangles} triangles`)
		else
			report.failed += 1
			warn(`[GenerationSpike]   failed after {entry.latencySec} s: {entry.error}`)
		end
	end
	report.totalSec = round(os.clock() - started)

	local json = Instance.new("StringValue")
	json.Name = REPORT_VALUE_NAME
	json.Value = HttpService:JSONEncode(report)
	json.Parent = results
	results:SetAttribute("Status", "done")

	if opts and opts.display then
		display(results)
	end
	print(`[GenerationSpike] done: {report.succeeded} ok, {report.failed} failed, {report.totalSec} s`)
	return report
end

return GenerationSpike
