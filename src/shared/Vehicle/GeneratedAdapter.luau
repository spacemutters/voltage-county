--!strict
-- The session-only generated look of a new AI design (PLAN.md Phase 11 "GeneratedAdapter"; docs/phase-11-contracts.md
-- "Decisions already taken" and "Server"). Used on the server by Services/DesignerService, which hands the result
-- to Services/VehicleService for the rest of that server session.
--
--   GeneratedAdapter.build(meshPrompt, kitModel) -> (Model?, why?)   yields up to
--       Config/Designer.generation.timeoutSeconds: asks GenerationService for a body and fits it onto a copy of
--       the design's kit build. nil (and why) on any error, a moderation refusal, a missing part, a body over the
--       triangle budget or the time running out: the caller then keeps the kit build. Never errors.
--   GeneratedAdapter.generate(prompt, timeoutSeconds) -> (Model?, why?)   the raw GenerationService call
--   GeneratedAdapter.accept(generated, kitModel, countMesh?) -> (Model?, why?)
--       the triangle budget, then fit: what build does with a generated model. A look with a why was taken
--       without a triangle count (Config/Perf meshes.rejectUncounted off); the why says which mesh.
--   GeneratedAdapter.fit(generated, kitModel) -> (Model?, why?)            the mapping onto the model contract
--   GeneratedAdapter.triangles(generated, countMesh?) -> (number?, why?)   the triangles the look would keep
--   GeneratedAdapter.withinBudget(generated, countMesh?) -> (boolean, why?)
--   GeneratedAdapter.meshTriangles(part) -> number?                        one MeshPart's triangles (nil: unreadable)
--   GeneratedAdapter.editableTriangles(editableMesh) -> number?            an EditableMesh's triangles
--   countMesh (default meshTriangles) counts one MeshPart; tests/GeneratedAdapter.spec passes its own.
--
-- The triangle budget (Config/Perf meshes; PLAN.md Phase 14 "Budgets"): the meshes the look keeps (every MeshPart
-- but the four generated wheels) may have at most Config/Perf meshes.maxTriangles triangles together, at the
-- mesh's full detail. They are counted through the EditableMesh behind a freshly generated MeshPart
-- (MeshContent.Object), or an editable copy loaded just to count (AssetService:CreateEditableMeshAsync); a face
-- with n corners is n - 2 triangles. Plain parts count as none (a block or cylinder is a few dozen). A look over
-- the budget is refused before it is fitted, and so is one with a mesh that can't be read while
-- Config/Perf meshes.rejectUncounted is on (while it's off, that look is taken and accept/build still say why).
--
-- How the generated body is mapped (the Phase 1 spike: Car5 results have a "body" and four named wheels with
-- usable centres, and come out about 2 studs long):
--   * The physics never come from the mesh. The result is a copy of the kit build (Vehicle/SpecBuilder) with its
--     Chassis, hub attachments (so wheelbase, track and ride height), Seats, Wheels, Lights, plate, camera and
--     Mount_* attachments untouched, so it drives exactly like the saved car and passes the same checks.
--   * The generated wheels' centres place the body: the mesh is scaled so its axles are as far apart as the kit
--     hubs (kept within Config/Designer.generation min/maxLengthShare of the scale that matches the kit length),
--     turned so its front faces the chassis front (-Z) with +Y up, and moved so the centre of its four wheel
--     centres sits on the centre of the four kit hubs.
--   * The kit body parts are removed and every generated part except the wheels goes into Body (massless,
--     non-colliding, untouchable, invisible to raycasts, welded to the Chassis). The generated wheels are dropped:
--     the kit wheels stay, so wheel styles, steering and spin keep working. Kit light parts are made invisible
--     (their Light instances still shine) so they don't float off the new shape.
--   * The model gets the attribute Config/Designer.generation.lookAttribute = true. Generated meshes have no asset
--     id, so the look exists only in this server session; the saved car always rebuilds from its kit spec.
--
-- Prompts are the spec's meshPrompt (shape, era and style only, already checked for brand names by the backend
-- and again by Services/DesignerService) plus Config/Designer.generation.promptSuffix. API names as checked on the Roblox docs (GenerationService reference,
-- 2026-10-20) and in src/server/Dev/GenerationSpike.luau: GenerateModelAsync(inputs, schema) with
-- { TextPrompt = ... } and { PredefinedSchema = "Car5" }, called inside pcall.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local Designer = require(script.Parent.Parent.Config.Designer)
local Perf = require(script.Parent.Parent.Config.Perf)

export type MeshCounter = (part: MeshPart) -> number?

local GeneratedAdapter = {}

local CONFIG = Designer.generation
local MESHES = Perf.meshes
local BODY_FOLDER = "Body"
local LIGHTS_FOLDER = "Lights"
-- Car5's guaranteed wheel part names, by the contract's wheel ids, and the contract's hub attachments.
local WHEEL_PARTS: { [string]: string } = {
	FL = "front left wheel",
	FR = "front right wheel",
	RL = "rear left wheel",
	RR = "rear right wheel",
}
local WHEEL_ORDER = { "FL", "FR", "RL", "RR" }
local HUB_PREFIX = "Wheel"
local MIN_SPAN = 1e-3 -- studs: wheel centres closer than this give no usable direction or scale

-- A descendant by exact name, then case-insensitively.
local function findNamed(root: Instance, name: string): Instance?
	local exact = root:FindFirstChild(name, true)
	if exact ~= nil then
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

-- The centre of a part, or of a model's bounding box.
local function centreOf(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		local cframe = instance:GetBoundingBox()
		return cframe.Position
	end
	return nil
end

-- The four generated wheel instances and their centres, or nil when one is missing.
local function generatedWheels(model: Model): ({ [string]: Instance }?, { [string]: Vector3 }?)
	local instances: { [string]: Instance } = {}
	local centres: { [string]: Vector3 } = {}
	for _, key in WHEEL_ORDER do
		local wheel = findNamed(model, WHEEL_PARTS[key])
		local centre = if wheel ~= nil then centreOf(wheel) else nil
		if wheel == nil or centre == nil then
			return nil, nil
		end
		instances[key] = wheel
		centres[key] = centre
	end
	return instances, centres
end

-- Where the wheels put the car: the centre of the four wheels, the forward direction across the ground (rear axle
-- to front axle) and the distance between the axles. nil when the wheels give no direction.
local function axlesOf(centres: { [string]: Vector3 }): (Vector3?, Vector3?, number?)
	local front = (centres.FL + centres.FR) / 2
	local rear = (centres.RL + centres.RR) / 2
	local along = front - rear
	local flat = Vector3.new(along.X, 0, along.Z)
	if flat.Magnitude < MIN_SPAN then
		return nil, nil, nil
	end
	local centre = (centres.FL + centres.FR + centres.RL + centres.RR) / 4
	return centre, flat.Unit, flat.Magnitude
end

-- How long a model is along `direction` (its bounding box projected onto that direction).
local function lengthAlong(model: Model, direction: Vector3): number
	local cframe, size = model:GetBoundingBox()
	return math.abs(size.X * cframe.RightVector:Dot(direction))
		+ math.abs(size.Y * cframe.UpVector:Dot(direction))
		+ math.abs(size.Z * cframe.LookVector:Dot(direction))
end

local function isWheelPart(part: Instance, wheels: { [string]: Instance }): boolean
	for _, wheel in wheels do
		if part == wheel or part:IsDescendantOf(wheel) then
			return true
		end
	end
	return false
end

-- The triangles in an EditableMesh: n - 2 for each face with n corners (generated and imported meshes are all
-- triangles; a face made with AddFace may not be). Falls back to one triangle a face when the corners can't be
-- read; nil when nothing can.
function GeneratedAdapter.editableTriangles(editableMesh: any): number?
	local ok, total = pcall(function(): number
		local count = 0
		for _, face in editableMesh:GetFaces() do
			count += math.max(#editableMesh:GetFaceVertices(face) - 2, 0)
		end
		return count
	end)
	if ok then
		return total
	end
	local okFaces, faces = pcall(function(): number
		return #editableMesh:GetFaces()
	end)
	return if okFaces then faces else nil
end

-- One MeshPart's triangles at full detail: the EditableMesh behind a freshly generated part (MeshContent.Object),
-- else an editable copy of its saved mesh loaded just to count (yields; destroyed after). nil for a part with no
-- readable mesh behind it.
function GeneratedAdapter.meshTriangles(part: MeshPart): number?
	local okObject, object = pcall(function(): any
		local content = (part :: any).MeshContent
		return if content ~= nil then content.Object else nil
	end)
	if okObject and object ~= nil and typeof(object) == "Instance" and object:IsA("EditableMesh") then
		return GeneratedAdapter.editableTriangles(object)
	end
	if part.MeshId == "" then
		return nil
	end
	local okCopy, copy = pcall(function(): any
		return (AssetService :: any):CreateEditableMeshAsync((part :: any).MeshContent)
	end)
	if not okCopy or copy == nil then
		return nil
	end
	local count = GeneratedAdapter.editableTriangles(copy)
	pcall(function()
		copy:Destroy()
	end)
	return count
end

-- The triangles of every mesh the look keeps from `generated` (all its MeshParts but the four generated wheels,
-- when they can be found). nil and why when one of them can't be counted.
function GeneratedAdapter.triangles(generated: Model, countMesh: MeshCounter?): (number?, string?)
	local counter: MeshCounter = countMesh or GeneratedAdapter.meshTriangles
	local wheels = generatedWheels(generated)
	local total = 0
	for _, descendant in generated:GetDescendants() do
		if not descendant:IsA("MeshPart") or (wheels ~= nil and isWheelPart(descendant, wheels)) then
			continue
		end
		local count = counter(descendant :: MeshPart)
		if count == nil then
			return nil, `couldn't count the triangles in "{descendant.Name}"`
		end
		total += count
	end
	return total, nil
end

-- Whether the generated body is inside the triangle budget (see the header), and why not.
function GeneratedAdapter.withinBudget(generated: Model, countMesh: MeshCounter?): (boolean, string?)
	local total, why = GeneratedAdapter.triangles(generated, countMesh)
	if total == nil then
		return not MESHES.rejectUncounted, why
	end
	if total > MESHES.maxTriangles then
		return false, `the generated body has {total} triangles; the budget is {MESHES.maxTriangles}`
	end
	return true, nil
end

-- Asks GenerationService for a Car5 model. Yields until it answers or `timeoutSeconds` pass, whichever is first;
-- a model that arrives after the time is up is destroyed. Returns the model, or nil and why.
function GeneratedAdapter.generate(prompt: string, timeoutSeconds: number): (Model?, string?)
	if not RunService:IsServer() then
		return nil, "generation runs on the server"
	end
	if prompt == "" then
		return nil, "no prompt"
	end
	local thread = coroutine.running()
	local settled = false
	local timer: thread? = nil
	task.spawn(function()
		local ok, result = pcall(function(): any
			local service: any = game:GetService("GenerationService")
			return service:GenerateModelAsync({ TextPrompt = prompt }, { PredefinedSchema = CONFIG.schema })
		end)
		if settled then
			if ok and typeof(result) == "Instance" then
				result:Destroy() -- too late: nobody is waiting for it any more
			end
			return
		end
		settled = true
		if timer ~= nil then
			task.cancel(timer)
		end
		if not ok then
			task.defer(thread, nil, tostring(result))
		elseif typeof(result) == "Instance" and result:IsA("Model") then
			task.defer(thread, result, nil)
		else
			if typeof(result) == "Instance" then
				result:Destroy()
			end
			task.defer(thread, nil, `no model returned ({typeof(result)})`)
		end
	end)
	if not settled then
		timer = task.delay(timeoutSeconds, function()
			if not settled then
				settled = true
				task.defer(thread, nil, "timed out")
			end
		end)
	end
	return coroutine.yield()
end

-- Fits a generated Car5 model onto a copy of `kitModel` (see the header). `generated` is left changed (scaled and
-- moved, its body parts taken) and should be destroyed by the caller. Returns the new model, or nil and why.
function GeneratedAdapter.fit(generated: Model, kitModel: Model): (Model?, string?)
	local kitChassis = kitModel.PrimaryPart
	if kitChassis == nil then
		return nil, "the kit build has no Chassis"
	end
	local hubs: { [string]: Vector3 } = {}
	for _, key in WHEEL_ORDER do
		local hub = kitChassis:FindFirstChild(HUB_PREFIX .. key)
		if hub == nil or not hub:IsA("Attachment") then
			return nil, `the kit build has no {HUB_PREFIX}{key} hub`
		end
		hubs[key] = hub.Position
	end
	local hubCentre, _, hubWheelbase = axlesOf(hubs)
	if hubCentre == nil or hubWheelbase == nil then
		return nil, "the kit hubs give no wheelbase"
	end

	local wheels, centres = generatedWheels(generated)
	if wheels == nil or centres == nil then
		return nil, "the generated model is missing a wheel"
	end
	local _, forward, wheelbase = axlesOf(centres)
	if forward == nil or wheelbase == nil then
		return nil, "the generated wheels give no direction"
	end

	-- Scale: axles to the kit hubs, within a band around the scale that matches the kit's length.
	local axleScale = hubWheelbase / wheelbase
	local lengthScale = kitChassis.Size.Z / math.max(lengthAlong(generated, forward), MIN_SPAN)
	local scale = math.clamp(axleScale, lengthScale * CONFIG.minLengthShare, lengthScale * CONFIG.maxLengthShare)
	generated:ScaleTo(generated:GetScale() * scale)

	local _, scaledCentres = generatedWheels(generated)
	if scaledCentres == nil then
		return nil, "the generated wheels moved out of reach"
	end
	local centre, scaledForward = axlesOf(scaledCentres)
	if centre == nil or scaledForward == nil then
		return nil, "the scaled wheels give no direction"
	end

	-- Turn and move it: its wheel centre onto the hub centre, its front to the chassis front (-Z), +Y up.
	local look = kitModel:Clone()
	local chassis = look.PrimaryPart :: BasePart
	local right = scaledForward:Cross(Vector3.yAxis)
	local generatedFrame = CFrame.fromMatrix(centre, right, Vector3.yAxis, -scaledForward)
	local target = chassis.CFrame * CFrame.new(hubCentre)
	generated:PivotTo(target * generatedFrame:ToObjectSpace(generated:GetPivot()))

	local body = look:FindFirstChild(BODY_FOLDER)
	if body == nil then
		look:Destroy()
		return nil, "the kit build has no Body folder"
	end
	body:ClearAllChildren()
	local lights = look:FindFirstChild(LIGHTS_FOLDER)
	if lights ~= nil then
		for _, descendant in lights:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Transparency = 1
			end
		end
	end

	local moved = 0
	for _, descendant in generated:GetDescendants() do
		if not descendant:IsA("BasePart") or isWheelPart(descendant, wheels) then
			continue
		end
		descendant.Anchored = false
		descendant.CanCollide = false
		descendant.CanTouch = false
		descendant.CanQuery = false
		descendant.Massless = true
		descendant.Parent = body
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = chassis
		weld.Part1 = descendant
		weld.Parent = descendant
		moved += 1
	end
	if moved == 0 then
		look:Destroy()
		return nil, "the generated model has no body parts"
	end
	look:SetAttribute(CONFIG.lookAttribute, true)
	return look, nil
end

-- What build does with a generated model: refuses it when it is over the triangle budget (or can't be counted, see
-- the header), else fits it onto a copy of `kitModel`. Never errors; `generated` is left for the caller to destroy.
function GeneratedAdapter.accept(generated: Model, kitModel: Model, countMesh: MeshCounter?): (Model?, string?)
	local okCount, within, budgetWhy = pcall(GeneratedAdapter.withinBudget, generated, countMesh)
	if not okCount then
		return nil, tostring(within)
	end
	if not within then
		return nil, budgetWhy
	end
	local ok, look, fitWhy = pcall(GeneratedAdapter.fit, generated, kitModel)
	if not ok then
		return nil, tostring(look)
	end
	-- fit gives a why only without a look; a look taken uncounted keeps the budget's why, so the server log shows it.
	return look, fitWhy or budgetWhy
end

-- Generates a body from `meshPrompt` and fits it onto a copy of `kitModel`. Never errors: nil and why on any
-- failure (including generation switched off in Config/Designer, and a body over the triangle budget).
function GeneratedAdapter.build(meshPrompt: string, kitModel: Model): (Model?, string?)
	if not CONFIG.enabled then
		return nil, "generation is switched off"
	end
	if type(meshPrompt) ~= "string" or string.match(meshPrompt, "%S") == nil then
		return nil, "the design has no shape prompt"
	end
	local generated, why = GeneratedAdapter.generate(meshPrompt .. CONFIG.promptSuffix, CONFIG.timeoutSeconds)
	if generated == nil then
		return nil, why
	end
	local look, acceptWhy = GeneratedAdapter.accept(generated, kitModel)
	generated:Destroy()
	return look, acceptWhy
end

return GeneratedAdapter
