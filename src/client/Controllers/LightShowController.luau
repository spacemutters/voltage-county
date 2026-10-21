--!strict
-- Runs light shows on this client (PLAN.md Phase 7; docs/phase-7-contracts.md "Light shows").
--
-- Services/LightShowService sends LightShowStart { showId, routineId, startAt, endsAt, meetSpotId, cars } to
-- everyone near a meet spot. Every client then runs the routine itself against workspace:GetServerTimeNow(),
-- which Roblox keeps in step across clients, so all of them light every car in the show together with no
-- per-frame network traffic:
--   * The routine (Config/LightShows) is compiled to seconds and expanded per car (wave cues are delayed by the
--     car's slot) into one list sorted by time. One RenderStepped connection, alive only while a show runs,
--     walks that list with a cursor and fires every cue whose time has come this frame. Cue times always come
--     from the shared startAt, never from accumulated waits, so nothing drifts.
--   * Lamps (the model contract's Lights folder: each part holds a Light named "Light"), the doors (Doors
--     folder, Hinge motors, OpenAngle attribute) and, on cars with a light-bar extra, an underglow light made on
--     this client. Pulses fade and doors swing from the cue's own time, drawn in the same frame walk.
--   * The track (Config/Audio) plays from the right offset at the meet spot when its assetId is not 0, and is
--     re-seeked if it drifts. Placeholder tracks (assetId 0) play nothing; the show runs silently.
--   * Every lamp, door and light it touched goes back the way it was when the show ends (LightShowEnd, or the
--     music's end if that message never comes), when a car drives off (Config client.leaveDistance), or when the
--     server takes a car out (its LightShowId attribute changes).
--
-- The roster is rebuilt from the payload plus every car tagged "Vehicle" whose LightShowId attribute names the
-- show, and again whenever such a car streams in, so a car that arrives late still joins (caught up to the
-- current moment without fades).
--
-- The "Light show" button: while the player drives and their car is nearly still inside a MeetSpot's footprint,
-- a button under the notices band asks the server to start or join the show there (JoinLightShow); while
-- their own car is in a show it turns into "Leave show" (LeaveLightShow), and anyone just watching a show gets
-- "Hide show" (also LeaveLightShow; the server then keeps that meet spot's shows off their screen for a while). Mobile-first: one 48 px button, UI
-- scaled up (never down) like the HUD. The button hides while a pod ride's cutscene plays (the LocalPlayer
-- attribute Config/Hail cutscene.attribute, like the HUD).
--
-- Studio only: a BindableFunction "Probe" under this module returns the timing of the first cues each car ran
-- (Dev/LightShowTests.sync reads it from its own copy of the modules).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)
local Hail = require(ReplicatedStorage.Shared.Config.Hail)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local NotifyController = require(script.Parent.NotifyController)
local ProfileController = require(script.Parent.ProfileController)

local UI = script.Parent.Parent.UI
local Primitives = require(UI.Shop.Primitives)
local Theme = require(UI.Theme)

local LOG = "[LightShowController]"
local GUI_NAME = "LightShow"
local PROBE_NAME = "Probe"
local GLOW_NAME = "LightShowGlow"
local MEET_SPOT_TAG = "MeetSpot"
local OWNER_ATTRIBUTE = "OwnerUserId" -- set on every player's car by VehicleService
local PROBES_KEPT = 4 -- Studio: shows whose timing the probe remembers

local look = LightShows.look
local attributes = LightShows.attributes
local messages = LightShows.messages

local e = React.createElement

-- Something on a car the show lights: a lamp part, or the underglow.
type Lamp = {
	steady: boolean, -- lit between pulses
	pulseAt: number?, -- show time of the running pulse
	pulseLength: number,
	written: number, -- the level last written (-1: never)
	write: (level: number) -> (),
	restore: () -> (),
}

type Door = {
	motor: Motor6D,
	part: BasePart, -- the door (an art model's door and the parts on it show only while open)
	original: CFrame, -- the hinge's Transform before the show
	angle: number, -- radians, fully open
	from: number, -- 0 shut .. 1 open
	to: number,
	swingAt: number?, -- show time of the running swing
	swingLength: number,
	amount: number, -- how open it is now
}

type Car = {
	model: Model,
	slot: number,
	anchor: Vector3, -- where it stood when it joined this client's show
	gone: boolean,
	lamps: { [string]: Lamp }, -- by Lights part name (made on first use)
	glow: Lamp?,
	doors: { Door }?, -- nil until the first door cue
	fires: number, -- cues run on it (Studio probe)
	connection: RBXScriptConnection?, -- watches its LightShowId attribute
}

type ProbeFire = {
	car: string, -- the car's full name
	slot: number,
	cue: number, -- index in the routine
	scheduled: number, -- seconds after startAt the cue was due
	fired: number, -- seconds after startAt (server clock) it ran on this client
	wall: number, -- os.clock() when it ran
}

type Probe = { showId: string, routineId: string, startAt: number, ended: boolean, fires: { ProbeFire } }

type Show = {
	id: string,
	routineId: string,
	meetSpotId: string,
	startAt: number,
	endsAt: number,
	cues: { LightShows.Cue },
	cars: { Car }, -- indices are the event car numbers
	byModel: { [Model]: Car },
	events: { LightShows.Event },
	cursor: number,
	animLamps: { [Lamp]: boolean },
	animDoors: { [Door]: boolean },
	sound: Sound?,
	soundAnchor: Attachment?,
	soundPlaying: boolean,
	resyncTimer: number,
	leaveTimer: number,
	render: RBXScriptConnection?,
	streamed: RBXScriptConnection?,
	probe: Probe?,
}

type ButtonMode = "hidden" | "join" | "leave" | "hide"

local LightShowController = {}

local active: Show? = nil
local probes: { Probe } = {} -- Studio only, oldest first

local meetSpots: { MapLayout.Location } = {}
local nearSpot: string? = nil -- the meet spot the driven car stands still in, if any
local buttonMode: ButtonMode = "hidden"
local buttonBusy = false
local scale = 1
local screenGui: ScreenGui? = nil
local root: any = nil
local promptConnection: RBXScriptConnection? = nil

local stillSpeed = Units.mphToStuds(LightShows.client.stillMph)

-- Lamps and doors ---------------------------------------------------------------------------------------------

local function quantize(level: number): number
	return math.round(level / look.levelStep) * look.levelStep
end

-- A lamp part from the Lights folder. restore() leaves it unlit in its own material (not however it happened to
-- look when the show first touched it, which may have been a held brake pedal); restoreCar then has the drive
-- code re-apply whatever it has lit right now (DriveController.refreshLamps).
local function partLamp(part: BasePart): Lamp
	local found = part:FindFirstChild(look.lightName)
	local light: Light? = if found ~= nil and found:IsA("Light") then found else nil
	local originalBrightness = if light then light.Brightness else 0
	DriveController.rememberLampMaterial(part)
	local originalMaterial = DriveController.lampOffMaterial(part) or part.Material
	local showBrightness = math.max(originalBrightness, look.minBrightness)

	local function write(level: number)
		if light ~= nil then
			light.Enabled = level > 0
			light.Brightness = showBrightness * level
		end
		local glowing = level > look.glowThreshold
		part.Material = if glowing then look.onMaterial else originalMaterial
		-- An art model's lamp is a glow overlay: it shows only while it glows (Vehicle/Appearance).
		local transparency = Appearance.lampOverlayTransparency(part, if glowing then level else 0)
		if transparency ~= nil then
			part.Transparency = transparency
		end
	end

	local function restore()
		if light ~= nil then
			light.Enabled = false
			light.Brightness = originalBrightness
		end
		part.Material = originalMaterial
		local transparency = Appearance.lampOverlayTransparency(part, 0)
		if transparency ~= nil then
			part.Transparency = transparency
		end
	end

	return { steady = false, pulseAt = nil, pulseLength = 0, written = -1, write = write, restore = restore }
end

-- The underglow: a light under the chassis, made on this client only and removed on restore.
local function glowLamp(model: Model): Lamp?
	local chassis = model.PrimaryPart
	if chassis == nil then
		return nil
	end
	local glow = LightShows.underglow
	local attachment = Instance.new("Attachment")
	attachment.Name = GLOW_NAME
	attachment.Position = Vector3.new(0, -chassis.Size.Y / 2 - glow.drop, 0)
	local light = Instance.new("PointLight")
	light.Color = glow.color
	light.Range = glow.range
	light.Brightness = 0
	light.Enabled = false
	light.Shadows = false
	light.Parent = attachment
	attachment.Parent = chassis

	local function write(level: number)
		light.Enabled = level > 0
		light.Brightness = glow.brightness * level
	end

	local function restore()
		attachment:Destroy()
	end

	return { steady = false, pulseAt = nil, pulseLength = 0, written = -1, write = write, restore = restore }
end

-- Draws a lamp at show time `elapsed`. Returns true while a pulse is still fading.
local function renderLamp(lamp: Lamp, elapsed: number): boolean
	local level = if lamp.steady then 1 else 0
	local pulsing = false
	local pulseAt = lamp.pulseAt
	if pulseAt ~= nil then
		local since = elapsed - pulseAt
		if since < lamp.pulseLength then
			level = math.max(level, LightShows.pulseLevel(since, lamp.pulseLength))
			pulsing = true
		else
			lamp.pulseAt = nil
		end
	end
	level = quantize(level)
	if level ~= lamp.written then
		lamp.written = level
		lamp.write(level)
	end
	return pulsing
end

-- Art models (Dev/ArtPass): the body mesh draws the closed door, so the door part and the parts on it carry
-- look.doorShowAttribute and show (at that transparency) only while the door stands open.
local function showDoor(door: Door, open: boolean)
	local parts: { Instance } = door.part:GetDescendants()
	table.insert(parts, door.part)
	for _, part in parts do
		local shown = part:GetAttribute(look.doorShowAttribute)
		if part:IsA("BasePart") and type(shown) == "number" then
			part.Transparency = if open then shown else 1
		end
	end
end

local function writeDoor(door: Door)
	door.motor.Transform = door.original * CFrame.Angles(0, 0, door.angle * door.amount)
	showDoor(door, door.amount > look.doorShowAmount)
end

-- Draws a door at show time `elapsed`. Returns true while it is still swinging.
local function renderDoor(door: Door, elapsed: number): boolean
	local swingAt = door.swingAt
	if swingAt == nil then
		return false
	end
	local since = elapsed - swingAt
	door.amount = LightShows.doorAmount(door.from, door.to, since, door.swingLength)
	writeDoor(door)
	if since >= door.swingLength then
		door.swingAt = nil
		return false
	end
	return true
end

-- The car's lamp in Lights/<name>, made on first use; nil while that part hasn't streamed in (tried again on the
-- next cue).
local function lampOf(car: Car, name: string): Lamp?
	local existing = car.lamps[name]
	if existing ~= nil then
		return existing
	end
	local folder = car.model:FindFirstChild(look.lightsFolder)
	local part = if folder then folder:FindFirstChild(name) else nil
	if part == nil or not part:IsA("BasePart") then
		return nil
	end
	local lamp = partLamp(part)
	car.lamps[name] = lamp
	return lamp
end

local function glowOf(car: Car): Lamp?
	if car.model:GetAttribute(attributes.underglow) ~= true then
		return nil
	end
	if car.glow == nil then
		car.glow = glowLamp(car.model)
	end
	return car.glow
end

-- The car's hinged doors (Doors folder: parts with a Hinge Motor6D and an OpenAngle attribute), found once.
local function doorsOf(car: Car): { Door }
	local existing = car.doors
	if existing ~= nil then
		return existing
	end
	local doors: { Door } = {}
	local folder = car.model:FindFirstChild(look.doorsFolder)
	if folder ~= nil then
		for _, part in folder:GetChildren() do
			local motor = part:FindFirstChild(look.hingeName)
			local angle = part:GetAttribute(look.openAngleAttribute)
			if part:IsA("BasePart") and motor ~= nil and motor:IsA("Motor6D") and type(angle) == "number" then
				table.insert(doors, {
					motor = motor,
					part = part,
					original = motor.Transform,
					angle = math.rad(angle),
					from = 0,
					to = 0,
					swingAt = nil,
					swingLength = 0,
					amount = 0,
				})
			end
		end
	end
	car.doors = doors
	return doors
end

-- Runs one cue on one car. `at` is when it was due and `elapsed` the show time now; `instant` skips fades and
-- swings (a cue found long after its time). Returns true when the car has what the cue moves.
local function applyCue(
	show: Show,
	car: Car,
	compiled: LightShows.Cue,
	at: number,
	elapsed: number,
	instant: boolean
): boolean
	if compiled.target == "doors" then
		local doors = doorsOf(car)
		local target = if compiled.action == "open" then 1 else 0
		for _, door in doors do
			door.from = door.amount
			door.to = target
			door.swingLength = compiled.duration
			if instant then
				door.swingAt = nil
				door.amount = target
				writeDoor(door)
				show.animDoors[door] = nil
			else
				door.swingAt = at
				if renderDoor(door, elapsed) then
					show.animDoors[door] = true
				end
			end
		end
		return #doors > 0
	end

	local lamps: { Lamp } = {}
	if compiled.target == "underglow" then
		local glow = glowOf(car)
		if glow ~= nil then
			table.insert(lamps, glow)
		end
	else
		local names = LightShows.lampGroups[compiled.target]
		if names ~= nil then
			for _, name in names do
				local lamp = lampOf(car, name)
				if lamp ~= nil then
					table.insert(lamps, lamp)
				end
			end
		end
	end
	for _, lamp in lamps do
		if compiled.action == "on" then
			lamp.steady = true
		elseif compiled.action == "off" then
			lamp.steady = false
		elseif compiled.action == "pulse" and not instant then
			lamp.pulseAt = at
			lamp.pulseLength = compiled.duration
		end
		if renderLamp(lamp, elapsed) then
			show.animLamps[lamp] = true
		else
			show.animLamps[lamp] = nil
		end
	end
	return #lamps > 0
end

-- Puts everything the show changed on a car back.
local function restoreCar(show: Show, car: Car)
	for _, lamp in car.lamps do
		show.animLamps[lamp] = nil
		lamp.restore()
	end
	table.clear(car.lamps)
	DriveController.refreshLamps(car.model) -- a brake still held (or let go) mid-show shows as it is now
	local glow = car.glow
	if glow ~= nil then
		show.animLamps[glow] = nil
		glow.restore()
		car.glow = nil
	end
	local doors = car.doors
	if doors ~= nil then
		for _, door in doors do
			show.animDoors[door] = nil
			door.motor.Transform = door.original
			showDoor(door, false)
		end
	end
	car.doors = nil
	local connection = car.connection
	if connection ~= nil then
		connection:Disconnect()
		car.connection = nil
	end
end

local function dropCar(show: Show, car: Car)
	if car.gone then
		return
	end
	car.gone = true
	restoreCar(show, car)
end

-- Audio -------------------------------------------------------------------------------------------------------

local function startAudio(show: Show)
	local routine = LightShows.getRoutine(show.routineId)
	local track = if routine then LightShows.trackOf(routine) else nil
	if track == nil or track.assetId == 0 then
		return -- a placeholder track: the show runs silently
	end
	local spot: MapLayout.Location? = nil
	for _, location in meetSpots do
		if location.id == show.meetSpotId then
			spot = location
		end
	end
	if spot == nil then
		return
	end
	local client = LightShows.client
	local anchor = Instance.new("Attachment")
	anchor.Name = GUI_NAME
	anchor.Position = spot.position + Vector3.yAxis * spot.size.Y -- Terrain sits at the origin: world space
	local sound = Instance.new("Sound")
	sound.SoundId = `rbxassetid://{track.assetId}`
	sound.Volume = track.volume * ProfileController.settings().musicVolume
	sound.RollOffMinDistance = client.rollOffMin
	sound.RollOffMaxDistance = client.rollOffMax
	sound.Looped = false
	sound.Parent = anchor
	anchor.Parent = Workspace.Terrain
	show.sound = sound
	show.soundAnchor = anchor
end

-- Starts the music at the show's clock once beat 0 has come, and re-seeks it when it drifts.
local function stepAudio(show: Show, elapsed: number, dt: number)
	local sound = show.sound
	if sound == nil or elapsed < 0 then
		return
	end
	if sound.IsLoaded and sound.TimeLength > 0 and elapsed >= sound.TimeLength then
		return -- the music has run out
	end
	if not show.soundPlaying then
		show.soundPlaying = true
		sound.TimePosition = elapsed
		sound:Play()
		return
	end
	show.resyncTimer += dt
	if show.resyncTimer >= LightShows.client.audioResyncInterval then
		show.resyncTimer = 0
		if sound.IsLoaded and math.abs(sound.TimePosition - elapsed) > LightShows.client.audioResyncTolerance then
			sound.TimePosition = elapsed
		end
	end
end

local function stopAudio(show: Show)
	local anchor = show.soundAnchor
	if anchor ~= nil then
		anchor:Destroy() -- takes the Sound with it
	end
	show.sound = nil
	show.soundAnchor = nil
end

-- The button ----------------------------------------------------------------------------------------------------

local function ownCarInShow(): boolean
	local show = active
	if show == nil then
		return false
	end
	local userId = Players.LocalPlayer.UserId
	for _, car in show.cars do
		if not car.gone and car.model:GetAttribute(OWNER_ATTRIBUTE) == userId then
			return true
		end
	end
	return false
end

local function render()
	if root == nil or screenGui == nil then
		return
	end
	if buttonMode == "hidden" then
		root:render(nil)
		return
	end
	local screen = (screenGui :: ScreenGui).AbsoluteSize / scale
	local top = HudController.noticesRect(screen).bottom + LightShows.button.gap
	local joining = buttonMode == "join"
	root:render(e("Frame", {
		Size = UDim2.fromScale(1 / scale, 1 / scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = scale }),
		Button = e(Primitives.Button, {
			label = if joining
				then messages.buttonJoin
				elseif buttonMode == "hide" then messages.buttonHide
				else messages.buttonLeave,
			style = if joining then "primary" else "secondary",
			disabled = buttonBusy,
			size = UDim2.fromOffset(LightShows.button.width, Theme.size.buttonHeight),
			position = UDim2.new(0.5, 0, 0, top),
			anchor = Vector2.new(0.5, 0),
			onTap = function()
				LightShowController.tap()
			end,
		}),
	}))
end

local function updateButton()
	-- Watchers get "Hide show" so nobody is stuck with a show they didn't ask for.
	local mode: ButtonMode = if ownCarInShow()
		then "leave"
		elseif nearSpot ~= nil then "join"
		elseif active ~= nil then "hide"
		else "hidden"
	if mode ~= buttonMode then
		buttonMode = mode
		render()
	end
end

-- The meet spot whose footprint the driven car stands still in, or nil.
local function stillAtMeetSpot(): string?
	local car = DriveController.getCar()
	local chassis = if car then car.PrimaryPart else nil
	if car == nil or chassis == nil then
		return nil
	end
	local velocity = chassis.AssemblyLinearVelocity
	if Vector3.new(velocity.X, 0, velocity.Z).Magnitude > stillSpeed then
		return nil
	end
	local pivot = car:GetPivot().Position
	for _, location in meetSpots do
		local frame = LightShows.footprintFrame(location.position, location.yaw)
		if LightShows.insideFootprint(frame, location.size, pivot, 0) then
			return location.id
		end
	end
	return nil
end

-- While driving, looks for a meet spot every Config client.promptCheckInterval (Heartbeat, connected only while
-- driving).
local function onDrivingChanged(driving: boolean)
	if promptConnection ~= nil then
		promptConnection:Disconnect()
		promptConnection = nil
	end
	nearSpot = nil
	if driving then
		local elapsed = 0
		promptConnection = RunService.Heartbeat:Connect(function(dt: number)
			elapsed += dt
			if elapsed >= LightShows.client.promptCheckInterval then
				elapsed = 0
				nearSpot = stillAtMeetSpot()
				updateButton()
			end
		end)
	end
	updateButton()
end

-- Shows ---------------------------------------------------------------------------------------------------------

local function recordFire(show: Show, car: Car, event: LightShows.Event, elapsed: number)
	local probe = show.probe
	if probe == nil or car.fires >= LightShows.dev.probeFiresPerCar then
		return
	end
	car.fires += 1
	table.insert(probe.fires, {
		car = car.model:GetFullName(),
		slot = car.slot,
		cue = event.cue.index,
		scheduled = event.at,
		fired = elapsed,
		wall = os.clock(),
	})
end

local finish: (show: Show, reason: string) -> ()

-- Runs every event that has come due by show time `elapsed`, from the cursor on.
local function runDue(show: Show, elapsed: number)
	local nextCursor = LightShows.advance(show.events, show.cursor, elapsed)
	for index = show.cursor, nextCursor - 1 do
		local event = show.events[index]
		local car = show.cars[event.car]
		if car ~= nil and not car.gone then
			local instant = elapsed - event.at > LightShows.client.lateCatchUp
			if applyCue(show, car, event.cue, event.at, elapsed, instant) then
				recordFire(show, car, event, elapsed)
			end
		end
	end
	show.cursor = nextCursor
end

-- One frame: run every cue that has come due, draw fading lamps and swinging doors, keep the music in step, and
-- every so often drop cars that drove off.
local function step(dt: number)
	local show = active
	if show == nil then
		return
	end
	local now = Workspace:GetServerTimeNow()
	local elapsed = now - show.startAt
	if now >= show.endsAt + LightShows.show.endPadding then
		finish(show, "finished") -- the server's LightShowEnd should have come by now
		return
	end

	runDue(show, elapsed)

	for lamp in show.animLamps do
		if not renderLamp(lamp, elapsed) then
			show.animLamps[lamp] = nil
		end
	end
	for door in show.animDoors do
		if not renderDoor(door, elapsed) then
			show.animDoors[door] = nil
		end
	end

	stepAudio(show, elapsed, dt)

	show.leaveTimer += dt
	if show.leaveTimer >= LightShows.client.leaveCheckInterval then
		show.leaveTimer = 0
		local changed = false
		for _, car in show.cars do
			if not car.gone then
				local model = car.model
				local moved = model.Parent == nil
					or (model:GetPivot().Position - car.anchor).Magnitude > LightShows.client.leaveDistance
				if moved then
					dropCar(show, car)
					changed = true
				end
			end
		end
		if changed then
			updateButton()
		end
	end
end

-- Rebuilds the event list after the roster changed. Cars new to this client are caught up to the current moment
-- (every cue already due applied without fades), so a car that streams in mid-show matches the others.
local function reschedule(show: Show, newcomers: { Car })
	local elapsed = Workspace:GetServerTimeNow() - show.startAt
	-- First finish what the cars already in the show were due since the last frame, so the new list's cursor
	-- (which counts everything up to now as done) skips nothing for them.
	runDue(show, elapsed)
	for _, car in newcomers do
		for _, compiled in show.cues do
			local at = LightShows.cueTime(compiled, car.slot)
			if at <= elapsed then
				applyCue(show, car, compiled, at, elapsed, elapsed - at > LightShows.client.lateCatchUp)
			end
		end
	end
	local slots: { number } = {}
	for index, car in show.cars do
		slots[index] = car.slot
	end
	show.events = LightShows.schedule(show.cues, slots)
	show.cursor = LightShows.cursorAt(show.events, elapsed)
end

local function slotOf(model: Model, fallback: number): number
	local slot = model:GetAttribute(attributes.slot)
	return if type(slot) == "number" and slot >= 1 then slot else fallback
end

-- Brings the show's cars up to date: the payload's cars plus every car whose LightShowId names this show; cars
-- the server took out (their attribute changed) are restored.
local function syncRoster(show: Show, listed: { any }?)
	local wanted: { Model } = {}
	local function consider(candidate: any)
		if typeof(candidate) ~= "Instance" or not candidate:IsA("Model") or table.find(wanted, candidate) then
			return
		end
		local showId = candidate:GetAttribute(attributes.showId)
		if showId == show.id or (showId == nil and listed ~= nil and table.find(listed, candidate) ~= nil) then
			table.insert(wanted, candidate)
		end
	end
	if listed ~= nil then
		for _, candidate in listed do
			consider(candidate)
		end
	end
	for _, candidate in CollectionService:GetTagged(Spawning.vehicleTag) do
		consider(candidate)
	end

	local newcomers: { Car } = {}
	local slotsChanged = false
	for _, car in show.cars do
		if not car.gone then
			if not table.find(wanted, car.model) then
				dropCar(show, car)
			else
				local slot = slotOf(car.model, car.slot)
				if slot ~= car.slot then
					car.slot = slot
					slotsChanged = true
				end
			end
		end
	end
	for _, model in wanted do
		local existing = show.byModel[model]
		if existing == nil or existing.gone then
			local car: Car = {
				model = model,
				slot = slotOf(model, #show.cars + 1),
				anchor = model:GetPivot().Position,
				gone = false,
				lamps = {},
				glow = nil,
				doors = nil,
				fires = if existing then existing.fires else 0,
				connection = nil,
			}
			car.connection = model:GetAttributeChangedSignal(attributes.showId):Connect(function()
				if model:GetAttribute(attributes.showId) ~= show.id and active == show then
					dropCar(show, car)
					updateButton()
				end
			end)
			table.insert(show.cars, car)
			show.byModel[model] = car
			table.insert(newcomers, car)
		end
	end
	if #newcomers > 0 or slotsChanged then
		reschedule(show, newcomers)
	end
	updateButton()
end

finish = function(show: Show, _reason: string)
	if active ~= show then
		return
	end
	active = nil
	local renderConnection = show.render
	if renderConnection ~= nil then
		renderConnection:Disconnect()
	end
	local streamed = show.streamed
	if streamed ~= nil then
		streamed:Disconnect()
	end
	for _, car in show.cars do
		dropCar(show, car)
	end
	stopAudio(show)
	local probe = show.probe
	if probe ~= nil then
		probe.ended = true
	end
	updateButton()
end

local function begin(payload: any, routine: LightShows.Routine): Show
	local show: Show = {
		id = payload.showId,
		routineId = routine.id,
		meetSpotId = if type(payload.meetSpotId) == "string" then payload.meetSpotId else "",
		startAt = payload.startAt,
		endsAt = if type(payload.endsAt) == "number"
			then payload.endsAt
			else payload.startAt + LightShows.length(routine),
		cues = LightShows.compile(routine),
		cars = {},
		byModel = {},
		events = {},
		cursor = 1,
		animLamps = {},
		animDoors = {},
		sound = nil,
		soundAnchor = nil,
		soundPlaying = false,
		resyncTimer = 0,
		leaveTimer = 0,
		render = nil,
		streamed = nil,
		probe = nil,
	}
	if RunService:IsStudio() then
		local probe: Probe =
			{ showId = show.id, routineId = show.routineId, startAt = show.startAt, ended = false, fires = {} }
		show.probe = probe
		table.insert(probes, probe)
		while #probes > PROBES_KEPT do
			table.remove(probes, 1)
		end
	end
	active = show
	startAudio(show)
	show.render = RunService.RenderStepped:Connect(step)
	-- Cars that stream in while the show runs join it.
	show.streamed = CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(function(instance: Instance)
		if active == show and instance:GetAttribute(attributes.showId) == show.id then
			syncRoster(show, nil)
		end
	end)

	local secondsToGo = math.ceil(show.startAt - Workspace:GetServerTimeNow())
	if secondsToGo > 0 then
		local name = show.meetSpotId
		for _, location in meetSpots do
			if location.id == show.meetSpotId then
				name = location.displayName
			end
		end
		NotifyController.show(string.format(messages.started, name, secondsToGo), "info")
	end
	return show
end

local function onStart(payload: any)
	if
		type(payload) ~= "table"
		or type(payload.showId) ~= "string"
		or type(payload.routineId) ~= "string"
		or type(payload.startAt) ~= "number"
	then
		return
	end
	local routine = LightShows.getRoutine(payload.routineId)
	if routine == nil then
		warn(`{LOG} unknown routine "{payload.routineId}"`)
		return
	end
	local current = active
	if current ~= nil and current.id ~= payload.showId then
		finish(current, "replaced")
	end
	local show = active
	if show == nil then
		local endsAt = if type(payload.endsAt) == "number"
			then payload.endsAt
			else payload.startAt + LightShows.length(routine)
		if Workspace:GetServerTimeNow() >= endsAt then
			return -- already over
		end
		show = begin(payload, routine)
	end
	syncRoster(show :: Show, if type(payload.cars) == "table" then payload.cars else {})
end

local function onEnd(payload: any)
	local show = active
	if show ~= nil and type(payload) == "table" and payload.showId == show.id then
		finish(show, if type(payload.reason) == "string" then payload.reason else "ended")
	end
end

-- Public --------------------------------------------------------------------------------------------------------

-- The button's action: join the show at the meet spot the car stands in, or leave the one it is in.
function LightShowController.tap()
	if buttonBusy or buttonMode == "hidden" then
		return
	end
	local leaving = buttonMode == "leave" or buttonMode == "hide"
	local spot = nearSpot
	if not leaving and spot == nil then
		return
	end
	buttonBusy = true
	render()
	task.spawn(function()
		local ok, reply = pcall(function(): any
			if leaving then
				return Net.invokeServer("LeaveLightShow")
			end
			return Net.invokeServer("JoinLightShow", { meetSpotId = spot })
		end)
		buttonBusy = false
		-- Success is plain to see (the show's own "starts in" notice, or the lamps going back); a refusal says why.
		if ok and type(reply) == "table" and type(reply.message) == "string" and not reply.ok then
			NotifyController.show(reply.message, "warning")
		end
		updateButton()
		render()
	end)
end

-- The show running on this client: its id, routine and start (server time), or nil.
function LightShowController.getActive(): { showId: string, routineId: string, startAt: number }?
	local show = active
	if show == nil then
		return nil
	end
	return { showId = show.id, routineId = show.routineId, startAt = show.startAt }
end

-- Boot ----------------------------------------------------------------------------------------------------------

function LightShowController:Start()
	for _, location in MapLayout.locations do
		if location.tag == MEET_SPOT_TAG then
			table.insert(meetSpots, location)
		end
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Theme.displayOrder.hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui
	screenGui = gui
	-- The button hides while a pod ride's cutscene plays (Controllers/HailController), like the HUD.
	local cutsceneAttribute = Hail.cutscene.attribute
	local function onCutsceneChanged()
		gui.Enabled = Players.LocalPlayer:GetAttribute(cutsceneAttribute) ~= true
	end
	Players.LocalPlayer:GetAttributeChangedSignal(cutsceneAttribute):Connect(onCutsceneChanged)
	onCutsceneChanged()
	root = ReactRoblox.createRoot(gui)
	scale = HudController.scaleFor(gui.AbsoluteSize)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		scale = HudController.scaleFor(gui.AbsoluteSize)
		render()
	end)

	Net.onClientEvent("LightShowStart", onStart)
	Net.onClientEvent("LightShowEnd", onEnd)
	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	if DriveController.getCar() ~= nil then
		onDrivingChanged(true)
	end

	-- Studio: the timing probe Dev/LightShowTests reads (from its own copy of these modules).
	if RunService:IsStudio() then
		local probe = Instance.new("BindableFunction")
		probe.Name = PROBE_NAME
		probe.OnInvoke = function(showId: any): any
			for index = #probes, 1, -1 do
				local entry = probes[index]
				if showId == nil or entry.showId == showId then
					return entry
				end
			end
			return nil
		end
		probe.Parent = script
	end
end

return LightShowController
