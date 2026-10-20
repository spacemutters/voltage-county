--!strict
-- Phase 8 on the client (docs/phase-8-contracts.md "Client UI"; PLAN.md Phase 8): coupling a trailer to a semi or
-- a broken-down car to a pickup or tow truck, and buying the freight license. The server decides everything
-- (Services/HitchService); this controller asks it and shows what it says.
--
--   hitch      while the player drives a car with a hitch (a Kingpin or TowHitch attachment on its Chassis, the
--              vehicle model contract), it works out what the HUD's hitch row shows (HudController.setHitch):
--                coupled   the server has set the attribute TowingModel (the coupled model's name) on the car, and
--                          an ObjectValue Towing under it: "Hauling Box trailer" / "Towing <car>", with Uncouple.
--                near      nothing coupled, the car nearly still, and a valid target close enough and lined up:
--                          a trailer's Kingpin within Config/Trailers.coupleDistance of the semi's Kingpin, or a
--                          broken-down car's (Towed = true) TowPoint within it of the TowHitch, measured in 3D like
--                          the server, and the two within Config/Trailers.coupleMaxAngle of each other
--                          (Vehicle/Trailer.articulation). "Nearby <name>", with Couple. A light check a few times
--                          a second (a spatial query around each hitch point wide enough to reach the target's
--                          Chassis, which starts chassisGap or towPointAhead behind its hitch point; connected only
--                          while driving such a car with nothing coupled). The server decides for real.
--              Coupling and uncoupling are watched through the car's attribute and child signals, not polled.
--   requests   T on keyboard and RB on gamepad (Config/Controls hitch, bound only while driving a car with a hitch)
--              and the row's button (HudController.onHitch) send Net TrailerAction: "decouple" while coupled, else
--              "couple" (the server picks the nearest valid target and says when there is none, so the key works
--              even when the light check sees nothing). One request at a time; the reply shows as a notice
--              (NotifyController), and the button waits meanwhile.
--   license    buyLicense(id) sends Net BuyLicense (the phone's Jobs app asks the player first) and shows the
--              reply. licenseKnown(id) is what this client knows the player holds: a purchase that worked this
--              session, or the profile snapshot once it carries the licenses. The Jobs app adds what the server's
--              JobUpdate implies (freight offers on the list).
--
-- The pure helpers (prettyName, displayName, readReply, flatDistance, readCoupleDistance) are exposed for specs.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Trailer = require(ReplicatedStorage.Shared.Vehicle.Trailer)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)
local ProfileController = require(script.Parent.ProfileController)

local PhoneConfig = require(script.Parent.Parent.UI.Phone.PhoneConfig)

local REMOTE_TRAILER = "TrailerAction"
local REMOTE_LICENSE = "BuyLicense"
local ACTION_NAME = "VoltageHitch" -- ContextActionService

-- Names from the vehicle model contract (PLAN.md §6) and docs/phase-8-contracts.md. Config/Jobs `hitch` and
-- `props` carry the same names for the server; they win when present.
local jobsConfig = Jobs :: any
local hitchNames = if type(jobsConfig.hitch) == "table" then jobsConfig.hitch else {}
local propNames = if type(jobsConfig.props) == "table" then jobsConfig.props else {}
local CHASSIS = "Chassis"
local KINGPIN = "Kingpin" -- a semi's fifth wheel, and a trailer's kingpin
local TOW_HITCH = "TowHitch" -- a pickup's or tow truck's hitch
local TOW_POINT = "TowPoint" -- the front of a car that can be towed
-- On the tractor while coupled: the coupled model's name, and an ObjectValue holding the coupled model.
local TOWING_ATTRIBUTE: string = hitchNames.towingAttribute or "TowingModel"
local TOWING_VALUE: string = hitchNames.towingValue or "Towing"
local TOWED_ATTRIBUTE: string = propNames.towedAttribute or "Towed" -- on a broken-down car waiting for a tow
-- On a job's trailer or broken-down car: the UserId of the player whose job it is (only they can hitch it).
local PROP_OWNER_ATTRIBUTE: string = propNames.ownerAttribute or "JobOwnerUserId"
local VEHICLE_ATTRIBUTE = "VehicleId" -- on every catalog car (trailers have none)
local TRAILERS_MODULE = "Trailers" -- Config/Trailers (the trailer-physics helper's)
local TOWING_JOB = "towing" -- Config/Jobs type whose classes can tow cars

-- How the client side of hitching behaves. The server's rules are in Config/Trailers and Services/HitchService.
local TUNING = {
	checkHz = 4, -- the near check runs this often while driving a car with a hitch and nothing coupled
	-- Couple shows only at this speed or slower (a car rolling past a parked trailer shouldn't flash it). The
	-- server's own limit (the semi nearly still) is stricter and says so when it refuses.
	showBelowMph = 8,
	-- Studs. Used only if Config/Trailers has no coupleDistance (with a warning), so touch players still get a
	-- Couple button; the server always measures with its own.
	fallbackCoupleDistance = 6,
	-- Studs added to the search radius past the target's Chassis offset behind its hitch point (Config/Trailers
	-- chassisGap for a trailer, towed.towPointAhead for a car), so its Chassis box is always found.
	searchMargin = 2,
	-- Degrees. Used only if Config/Trailers has no coupleMaxAngle.
	fallbackCoupleMaxAngle = 30,
}

-- What players read. The server's replies come first; these fill in when a reply has no words.
local TEXT = {
	coupled = "Coupled.",
	decoupled = "Uncoupled.",
	licenseBought = "License bought.",
}

export type Action = HudController.HitchAction
export type Kind = "trailer" | "car"
export type Hitch = HudController.Hitch

-- Something on the hitch, or close enough to couple.
export type Target = { kind: Kind, model: Model?, name: string }

local HitchInputController = {}
HitchInputController.tuning = TUNING
HitchInputController.text = TEXT

-- Fires (hitch: Hitch?) whenever get() would return something new.
HitchInputController.onChanged = InputController.newSignal()
-- Fires () when licenseKnown or licenseBusy may have changed.
HitchInputController.onLicenseChanged = InputController.newSignal()

local car: Model? = nil -- the car being driven, while it has a hitch
local kingpin: Attachment? = nil -- its hitch points
local towHitch: Attachment? = nil
local canTowCars = false -- its class can tow cars (Config/Jobs towing classes)
local carConnections: { RBXScriptConnection } = {}
local valueConnection: RBXScriptConnection? = nil -- the Towing ObjectValue's Changed
local ticker: RBXScriptConnection? = nil
local near: Target? = nil
local busy: Action? = nil
local bound = false
local shown: Hitch? = nil -- what the HUD row was last told

local buying: string? = nil -- the license a BuyLicense request is waiting on
local bought: { [string]: boolean } = {} -- licenses bought this session (the server said yes)

local coupleDistance: number? = nil -- read from Config/Trailers on first use

-- Pure helpers ---------------------------------------------------------------------------------------------------

-- "box_trailer" -> "Box trailer": a model name made readable (underscores and dashes become spaces, the first
-- letter upper case).
function HitchInputController.prettyName(name: string): string
	local words = string.gsub(name, "[_%-]+", " ")
	words = string.gsub(words, "^%s+", "")
	words = string.gsub(words, "%s+$", "")
	if words == "" then
		return name
	end
	return string.upper(string.sub(words, 1, 1)) .. string.sub(words, 2)
end

-- A trailer's display name from Config/Trailers when it has one (a `displayName` on the trailer's spec), else nil.
-- The table is read loosely: Config/Trailers is another helper's, and only coupleDistance is in the contract.
local function trailerConfigName(config: any, name: string): string?
	if type(config) ~= "table" then
		return nil
	end
	for _, key in { "trailers", "specs", "models" } do
		local list = config[key]
		local spec = if type(list) == "table" then list[name] else nil
		if type(spec) == "table" and type(spec.displayName) == "string" then
			return spec.displayName
		end
	end
	local spec = config[name]
	if type(spec) == "table" and type(spec.displayName) == "string" then
		return spec.displayName
	end
	return nil
end

-- The name the HUD shows for a model on (or near) the hitch, from its model name and VehicleId (when known): a
-- catalog car's display name (its model is named <vehicleId>_<trim>, so the longest prefix that is a vehicle id
-- also works), else the trailer's name from `trailers` (Config/Trailers, when it has one), else the model name
-- made readable.
function HitchInputController.displayName(name: string, vehicleId: string?, trailers: any?): string
	if vehicleId ~= nil then
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle ~= nil then
			return vehicle.displayName
		end
	end
	local parts = string.split(name, "_")
	for count = #parts, 1, -1 do
		local vehicle = Catalog.getVehicle(table.concat(parts, "_", 1, count))
		if vehicle ~= nil then
			return vehicle.displayName
		end
	end
	return trailerConfigName(trailers, name) or HitchInputController.prettyName(name)
end

-- True when a model name is a catalog car's (<vehicleId>_<trim>, or a vehicle id).
local function isCatalogName(name: string): boolean
	local parts = string.split(name, "_")
	for count = #parts, 1, -1 do
		if Catalog.getVehicle(table.concat(parts, "_", 1, count)) ~= nil then
			return true
		end
	end
	return false
end

-- A TrailerAction or BuyLicense reply read the same way either shape comes: the house style { ok, message }, or
-- the two values HitchService's couple / decouple return (ok, message). ok is nil when there was no answer (Net
-- turned the request away: too many in a row); message is nil when the reply has no words.
function HitchInputController.readReply(reply: any, extra: any): (boolean?, string?)
	if type(reply) == "table" then
		local message = reply.message
		return reply.ok == true, if type(message) == "string" and message ~= "" then message else nil
	elseif type(reply) == "boolean" then
		return reply, if type(extra) == "string" and extra ~= "" then extra else nil
	end
	return nil, nil
end

-- Horizontal studs between two points: hitch points mate at slightly different heights, and the server is the
-- one that measures exactly.
function HitchInputController.flatDistance(a: Vector3, b: Vector3): number
	local delta = b - a
	return Vector3.new(delta.X, 0, delta.Z).Magnitude
end

-- The couple distance from a Config/Trailers table: `coupleDistance` (the contract's name), or the same under a
-- `hitch` or `couple` group. nil when it has none.
function HitchInputController.readCoupleDistance(config: any): number?
	if type(config) ~= "table" then
		return nil
	end
	local candidates = { config.coupleDistance }
	if type(config.hitch) == "table" then
		table.insert(candidates, config.hitch.coupleDistance)
	end
	if type(config.couple) == "table" then
		table.insert(candidates, config.couple.distance)
	end
	for _, value in candidates do
		if type(value) == "number" and value == value and value > 0 and value ~= math.huge then
			return value
		end
	end
	return nil
end

-- Config ---------------------------------------------------------------------------------------------------------

local trailersLoaded: any = nil -- Config/Trailers once found

-- Config/Trailers, or nil while it can't be read (it is another helper's file, found by name so a missing or
-- broken one never stops the hitch key from working).
local function trailersConfig(): any
	if trailersLoaded ~= nil then
		return trailersLoaded
	end
	local folder = ReplicatedStorage.Shared:FindFirstChild("Config")
	local module = if folder then folder:FindFirstChild(TRAILERS_MODULE) else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, config = pcall(require, module)
	if ok and type(config) == "table" then
		trailersLoaded = config
	end
	return trailersLoaded
end

local function getCoupleDistance(): number
	local cached = coupleDistance
	if cached ~= nil then
		return cached
	end
	local distance = HitchInputController.readCoupleDistance(trailersConfig())
	if distance == nil then
		warn("[HitchInputController] Config/Trailers has no coupleDistance; using the client fallback")
		distance = TUNING.fallbackCoupleDistance
	end
	coupleDistance = distance
	return distance
end

-- A positive number from Config/Trailers at `path` (keys), else `fallback`.
local function trailersNumber(path: { string }, fallback: number): number
	local value: any = trailersConfig()
	for _, key in path do
		if type(value) ~= "table" then
			return fallback
		end
		value = value[key]
	end
	return if type(value) == "number" and value == value and value >= 0 and value ~= math.huge then value else fallback
end

-- How far round a hitch point to look for a target's Chassis: the couple distance plus the farthest a target's
-- Chassis starts behind its hitch point (a trailer's chassisGap, a towed car's towPointAhead) and a margin.
local function searchRadius(distance: number): number
	local behind = math.max(trailersNumber({ "chassisGap" }, 0), trailersNumber({ "towed", "towPointAhead" }, 0))
	return distance + behind + TUNING.searchMargin
end

-- True when a car of this VehicleId's class can tow cars (Config/Jobs towing classes). With no towing job in
-- Config/Jobs, any car with a TowHitch can (the server decides either way).
local function classCanTowCars(vehicleId: any): boolean
	local def = ((Jobs.types :: any) :: { [string]: any })[TOWING_JOB]
	if type(def) ~= "table" or type(def.classes) ~= "table" then
		return true
	end
	local vehicle = if type(vehicleId) == "string" then Catalog.getVehicle(vehicleId) else nil
	return vehicle ~= nil and table.find(def.classes, vehicle.class) ~= nil
end

-- The coupled model ----------------------------------------------------------------------------------------------

local function towingValue(model: Model): ObjectValue?
	local value = model:FindFirstChild(TOWING_VALUE)
	return if value ~= nil and value:IsA("ObjectValue") then value else nil
end

-- What the driven car has on its hitch (from the server's TowingModel attribute and Towing value), or nil.
local function coupledTarget(): Target?
	local current = car
	if current == nil then
		return nil
	end
	local name = current:GetAttribute(TOWING_ATTRIBUTE)
	local value = towingValue(current)
	local coupled = if value then value.Value else nil
	local model: Model? = if coupled ~= nil and coupled:IsA("Model") then coupled :: Model else nil
	if (type(name) ~= "string" or name == "") and model == nil then
		return nil
	end
	local modelName = if type(name) == "string" and name ~= "" then name else (model :: Model).Name
	local vehicleId = if model then model:GetAttribute(VEHICLE_ATTRIBUTE) else nil
	-- A towed car is a catalog car; a trailer isn't. Without the model (still streaming in), its name tells.
	local isCar = if model ~= nil
		then model:GetAttribute(TOWED_ATTRIBUTE) == true or vehicleId ~= nil
		else isCatalogName(modelName)
	return {
		kind = if isCar then "car" else "trailer",
		model = model,
		name = HitchInputController.displayName(
			modelName,
			if type(vehicleId) == "string" then vehicleId else nil,
			if isCar then nil else trailersConfig()
		),
	}
end

-- Every model some car is towing now (their Towing values), so the near check never offers one already coupled.
local function towedModels(): { [Instance]: boolean }
	local set: { [Instance]: boolean } = {}
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if instance:IsA("Model") then
			local value = towingValue(instance)
			if value ~= nil and value.Value ~= nil then
				set[value.Value] = true
			end
		end
	end
	return set
end

-- The near check ---------------------------------------------------------------------------------------------------

-- The hitch point on `chassis` (a trailer's Kingpin, or a towed car's TowPoint) that mates with a hitch of `kind`
-- on the driven car, or nil when this model isn't that kind of target.
local function targetPoint(model: Model, chassis: BasePart, kind: Kind): Attachment?
	-- Another player's job trailer or broken-down car is theirs to hitch.
	local owner = model:GetAttribute(PROP_OWNER_ATTRIBUTE)
	if type(owner) == "number" and owner ~= Players.LocalPlayer.UserId then
		return nil
	end
	local pointName: string
	if kind == "trailer" then
		-- A trailer is no catalog car (another semi also carries a Kingpin) and no broken-down car.
		if model:GetAttribute(VEHICLE_ATTRIBUTE) ~= nil or model:GetAttribute(TOWED_ATTRIBUTE) == true then
			return nil
		end
		pointName = KINGPIN
	else
		if model:GetAttribute(TOWED_ATTRIBUTE) ~= true then
			return nil
		end
		pointName = TOW_POINT
	end
	local point = chassis:FindFirstChild(pointName)
	return if point ~= nil and point:IsA("Attachment") then point else nil
end

-- The nearest valid target within the couple distance of the driven car's hitch points, or nil. Only while the
-- car is nearly still (DriveController telemetry).
local function findTarget(): Target?
	local current = car
	if current == nil then
		return nil
	end
	local telemetry = DriveController.getTelemetry()
	if telemetry ~= nil and telemetry.mph > TUNING.showBelowMph then
		return nil
	end
	local distance = getCoupleDistance()
	local radius = searchRadius(distance)
	local maxAngle = math.rad(trailersNumber({ "coupleMaxAngle" }, TUNING.fallbackCoupleMaxAngle))
	local carChassis = current.PrimaryPart or current:FindFirstChild(CHASSIS)
	if carChassis == nil or not carChassis:IsA("BasePart") then
		return nil
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { current }
	local character = Players.LocalPlayer.Character
	if character ~= nil then
		table.insert(exclude, character)
	end
	params.FilterDescendantsInstances = exclude

	local hitches: { { kind: Kind, attachment: Attachment? } } = {
		{ kind = "trailer", attachment = kingpin },
		{ kind = "car", attachment = if canTowCars then towHitch else nil },
	}
	local best: Target? = nil
	local bestDistance = distance
	local towed: { [Instance]: boolean }? = nil
	for _, hitch in hitches do
		local attachment = hitch.attachment
		if attachment == nil or attachment.Parent == nil then
			continue
		end
		local origin = attachment.WorldPosition
		local seen: { [Instance]: boolean } = {}
		for _, part in Workspace:GetPartBoundsInRadius(origin, radius, params) do
			local parent = part.Parent
			if part.Name ~= CHASSIS or parent == nil or not parent:IsA("Model") or seen[parent] then
				continue
			end
			seen[parent] = true
			local model = parent :: Model
			local point = targetPoint(model, part, hitch.kind)
			if point == nil then
				continue
			end
			-- Measured in 3D like the server; and lined up, or the server refuses it.
			local gap = (point.WorldPosition - origin).Magnitude
			if gap > bestDistance then
				continue
			end
			if Trailer.articulation(carChassis.CFrame, part.CFrame) > maxAngle then
				continue
			end
			towed = towed or towedModels()
			if (towed :: { [Instance]: boolean })[model] then
				continue
			end
			local vehicleId = model:GetAttribute(VEHICLE_ATTRIBUTE)
			bestDistance = gap
			best = {
				kind = hitch.kind,
				model = model,
				name = HitchInputController.displayName(
					model.Name,
					if type(vehicleId) == "string" then vehicleId else nil,
					if hitch.kind == "trailer" then trailersConfig() else nil
				),
			}
		end
	end
	return best
end

-- State ------------------------------------------------------------------------------------------------------------

-- What the HUD row shows now: what is coupled, else what is near enough to couple, else nothing.
local function currentHitch(): Hitch?
	if car == nil then
		return nil
	end
	local target = coupledTarget()
	local state: "coupled" | "near" = "coupled"
	if target == nil then
		target = near
		state = "near"
	end
	if target == nil then
		return nil
	end
	return { state = state, kind = target.kind, name = target.name, busy = busy ~= nil }
end

local function sameHitch(a: Hitch?, b: Hitch?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.state == b.state and a.kind == b.kind and a.name == b.name and a.busy == b.busy
end

-- Tells the HUD (and listeners) when what shows changed.
local function publish()
	local hitch = currentHitch()
	if sameHitch(hitch, shown) then
		return
	end
	shown = hitch
	HudController.setHitch(hitch)
	HitchInputController.onChanged:Fire(if hitch then table.clone(hitch) else nil)
end

-- What the HUD's hitch row shows now (nil: nothing). A copy.
function HitchInputController.get(): Hitch?
	local hitch = currentHitch()
	return if hitch then table.clone(hitch) else nil
end

local function stopTicker()
	if ticker ~= nil then
		ticker:Disconnect()
		ticker = nil
	end
	near = nil
end

-- One look for something to couple; redraws only when the answer changed.
local function check()
	local found = findTarget()
	local before = near
	near = found
	local changed = if found == nil or before == nil
		then found ~= before
		else found.model ~= before.model or found.name ~= before.name
	if changed then
		publish()
	end
end

-- The near check runs only while driving a car with a hitch that has nothing coupled.
local function updateTicker()
	if car == nil or coupledTarget() ~= nil then
		stopTicker()
		return
	end
	if ticker ~= nil then
		return
	end
	local interval = 1 / TUNING.checkHz
	local elapsed = interval -- look on the first frame
	ticker = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			check()
		end
	end)
end

-- The coupling changed (the server set or cleared TowingModel or Towing).
local function onCouplingChanged()
	updateTicker()
	publish()
end

local function watchValue(value: Instance?)
	if valueConnection ~= nil then
		valueConnection:Disconnect()
		valueConnection = nil
	end
	if value ~= nil and value:IsA("ObjectValue") then
		valueConnection = value.Changed:Connect(onCouplingChanged)
	end
end

-- Requests ---------------------------------------------------------------------------------------------------------

-- Shows a reply as a notice and says whether the request worked. `okText` stands in for a success with no words.
local function showReply(called: boolean, reply: any, extra: any, okText: string): boolean
	if not called then
		NotifyController.show(PhoneConfig.labels.failed, "error")
		return false
	end
	local ok, message = HitchInputController.readReply(reply, extra)
	if ok == nil then
		NotifyController.show(PhoneConfig.labels.tryLater, "warning")
		return false
	end
	NotifyController.show(
		message or (if ok then okText else PhoneConfig.labels.failed),
		if ok then "success" else "warning"
	)
	return ok
end

-- Asks the server to couple or uncouple: `action`, or by default "decouple" while something is coupled and
-- "couple" otherwise (the server picks the nearest valid target). Yields until it answers; returns whether it
-- worked, or nil when nothing was sent (not driving a car with a hitch, or another request is waiting).
function HitchInputController.request(action: Action?): boolean?
	if busy ~= nil or car == nil then
		return nil
	end
	local chosen: Action = action or (if coupledTarget() ~= nil then "decouple" else "couple")
	busy = chosen
	publish()
	local called, reply, extra = pcall(Net.invokeServer, REMOTE_TRAILER, { action = chosen })
	busy = nil
	local worked = showReply(called, reply, extra, if chosen == "couple" then TEXT.coupled else TEXT.decoupled)
	publish()
	return worked
end

-- T / RB: one request per press. Typing in the chat or a text box never couples.
local function onHitchInput(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if UserInputService:GetFocusedTextBox() ~= nil then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		task.spawn(HitchInputController.request)
	end
	return Enum.ContextActionResult.Sink
end

local function bindKeys()
	if bound then
		return
	end
	local keys: { Enum.KeyCode } = table.clone(Controls.keyboard.hitch)
	table.move(Controls.gamepad.hitch, 1, #Controls.gamepad.hitch, #keys + 1, keys)
	if #keys == 0 then
		return
	end
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		onHitchInput,
		false,
		Controls.actionPriority,
		table.unpack(keys)
	)
	bound = true
end

local function unbindKeys()
	if bound then
		ContextActionService:UnbindAction(ACTION_NAME)
		bound = false
	end
end

-- The driven car -------------------------------------------------------------------------------------------------

local function stopWatching()
	for _, connection in carConnections do
		connection:Disconnect()
	end
	table.clear(carConnections)
	watchValue(nil)
	stopTicker()
	unbindKeys()
	car, kingpin, towHitch, canTowCars = nil, nil, nil, false
end

local function attachmentOn(chassis: Instance, name: string): Attachment?
	local found = chassis:FindFirstChild(name)
	return if found ~= nil and found:IsA("Attachment") then found else nil
end

-- Starts watching a car the player now drives, if it has a hitch.
local function startWatching(model: Model)
	local chassis = model.PrimaryPart or model:FindFirstChild(CHASSIS)
	if chassis == nil then
		return
	end
	local foundKingpin = attachmentOn(chassis, KINGPIN)
	local foundHitch = attachmentOn(chassis, TOW_HITCH)
	if foundKingpin == nil and foundHitch == nil then
		return -- no hitch: no key, no row
	end
	car, kingpin, towHitch = model, foundKingpin, foundHitch
	canTowCars = foundHitch ~= nil and classCanTowCars(model:GetAttribute(VEHICLE_ATTRIBUTE))

	table.insert(carConnections, model:GetAttributeChangedSignal(TOWING_ATTRIBUTE):Connect(onCouplingChanged))
	table.insert(
		carConnections,
		model.ChildAdded:Connect(function(child: Instance)
			if child.Name == TOWING_VALUE then
				watchValue(child)
				onCouplingChanged()
			end
		end)
	)
	table.insert(
		carConnections,
		model.ChildRemoved:Connect(function(child: Instance)
			if child.Name == TOWING_VALUE then
				watchValue(towingValue(model))
				onCouplingChanged()
			end
		end)
	)
	watchValue(towingValue(model))
	bindKeys()
	updateTicker()
end

local function onDrivingChanged(driving: boolean, model: Model?)
	stopWatching()
	if driving then
		local current = model or DriveController.getCar()
		if current ~= nil then
			startWatching(current)
		end
	end
	publish()
end

-- Licenses ---------------------------------------------------------------------------------------------------------

-- The licenses a profile snapshot carries (`licenses`, or `jobs.licenses` like PlayerData), or nil when it has none.
local function profileLicenses(): { [string]: any }?
	local profile = ProfileController.get() :: any
	if type(profile) ~= "table" then
		return nil
	end
	if type(profile.licenses) == "table" then
		return profile.licenses
	end
	if type(profile.jobs) == "table" and type(profile.jobs.licenses) == "table" then
		return profile.jobs.licenses
	end
	return nil
end

-- True when this client knows the player holds license `id`: bought this session, or in their profile snapshot.
-- false means "not known", not "doesn't hold it" (the Jobs app also reads what JobUpdate implies).
function HitchInputController.licenseKnown(id: string): boolean
	if bought[id] then
		return true
	end
	local licenses = profileLicenses()
	return licenses ~= nil and licenses[id] == true
end

-- The license a BuyLicense request is waiting on, or nil.
function HitchInputController.licenseBusy(): string?
	return buying
end

-- Buys license `id` (Net BuyLicense; the server checks the XP gate and takes the price). The reply shows as a
-- notice. Yields; returns whether it worked, or nil when another purchase was already waiting.
function HitchInputController.buyLicense(id: string): boolean?
	if buying ~= nil then
		return nil
	end
	buying = id
	HitchInputController.onLicenseChanged:Fire()
	local called, reply, extra = pcall(Net.invokeServer, REMOTE_LICENSE, { license = id })
	buying = nil
	local worked = showReply(called, reply, extra, TEXT.licenseBought)
	if worked then
		bought[id] = true -- buying is idempotent: "you already have it" is a yes too
	end
	HitchInputController.onLicenseChanged:Fire()
	return worked
end

-- Boot ---------------------------------------------------------------------------------------------------------------

function HitchInputController:Start()
	HudController.onHitch:Connect(function(action: Action)
		task.spawn(HitchInputController.request, action)
	end)
	ProfileController.onChanged:Connect(function()
		HitchInputController.onLicenseChanged:Fire()
	end)
	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	local current = DriveController.getCar()
	if current ~= nil then
		onDrivingChanged(true, current)
	end
end

return HitchInputController
