--!strict
-- The phone (docs/phase-4-contracts.md "Client UI"; PLAN.md Phase 4). Owns the Phone ScreenGui and renders
-- UI/Phone/Phone with react-lua: the phone button and the phone sheet with its apps, GPS, Garage, Jobs, Fleet,
-- Wallet, Codes and Settings.
--
--   opening      the phone button (UI/Phone/Layout places it: bottom centre on foot, beside the speed panel while
--                driving, never over the touch pedals or steering), the P key, or LB on a gamepad. The same
--                again, Close, or a tap on the dimmed screen closes it; on a gamepad B goes back a screen.
--   GPS          the destination list from GpsController.destinations(); picking one routes there
--                (GpsController.setDestination) and closes the phone. The active route with End route. Tapping
--                the on-screen route chip opens this app.
--   Garage       cars from the profile snapshot (ProfileController). Spawn -> Net SpawnOwned, Put away ->
--                DespawnOwned, Sell (after a confirm) -> SellVehicle, the star -> SetFavorite. One request at a
--                time; every reply shows as a notice (NotifyController).
--   Codes        Net RedeemCode, as the HUD did in Phase 3.
--   Settings     units, starting camera and music volume -> Net UpdateSettings. The camera setting is applied to
--                CameraController whenever it changes.
--
-- Clients send intents only: the server decides every outcome and sends a new ProfileSnapshot. Settings and
-- favorites show at once (ProfileController patches) and are sent after a short pause, so a burst of taps sends
-- one request. No polling: everything here runs on events, signals and task.delay.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local CameraConfig = require(ReplicatedStorage.Shared.Config.Camera)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Types = require(ReplicatedStorage.Shared.Types)
local CameraController = require(script.Parent.CameraController)
local DriveController = require(script.Parent.DriveController)
local GpsController = require(script.Parent.GpsController)
local HudController = require(script.Parent.HudController)
local NotifyController = require(script.Parent.NotifyController)
local ProfileController = require(script.Parent.ProfileController)
local ShopController = require(script.Parent.ShopController)

local UI = script.Parent.Parent.UI
local PhoneUI = UI.Phone
local CodesApp = require(PhoneUI.CodesApp)
local FleetApp = require(PhoneUI.FleetApp)
local GarageApp = require(PhoneUI.GarageApp)
local GpsApp = require(PhoneUI.GpsApp)
local JobsApp = require(PhoneUI.JobsApp)
local Layout = require(PhoneUI.Layout)
local Phone = require(PhoneUI.Phone)
local PhoneConfig = require(PhoneUI.PhoneConfig)
local SettingsApp = require(PhoneUI.SettingsApp)
local WalletApp = require(PhoneUI.WalletApp)
local Theme = require(UI.Theme)

local GUI_NAME = "Phone"
local OWNER_ATTRIBUTE = "OwnerUserId" -- set by VehicleService on every spawned car
-- Above the driving bindings (Config/Controls), so the phone keys and gamepad B win while the phone is open.
local ACTION_PRIORITY = Controls.actionPriority + 1

local e = React.createElement

type InputKind = HudController.InputKind
type AppId = PhoneConfig.AppId

-- Everything the phone shows.
type View = {
	scale: number,
	screen: Vector2, -- the ScreenGui's size in UI-scale-1 pixels
	open: boolean, -- the sheet is showing (or sliding out)
	leaving: boolean, -- the sheet is sliding out
	app: AppId?, -- nil: the home screen
	driving: boolean,
	inputKind: InputKind,
	profile: Types.ProfileSnapshot?,
	gps: GpsController.Status?,
	outUid: string?, -- the garage car that's out, as far as this client knows
	busy: GarageApp.Busy?, -- a garage request is with the server
	confirmUid: string?, -- the car whose sell confirm is showing
	redeeming: boolean, -- a code is with the server
	codesClear: number, -- bumped when a code worked, to empty the box
}

local PhoneController = {}

local view: View = {
	scale = 1,
	screen = Vector2.new(0, 0),
	open = false,
	leaving = false,
	app = nil,
	driving = false,
	inputKind = "keyboard",
	profile = nil,
	gps = nil,
	outUid = nil,
	busy = nil,
	confirmUid = nil,
	redeeming = false,
	codesClear = 0,
}

local root: any = nil
local sections: { GpsApp.Section } = {}
local closeSerial = 0 -- bumped on every open and close, so a stale close timer does nothing
local backBound = false

-- Garage cars of this player currently in the world, and the car the last successful Spawn brought out.
local tracked: { [Model]: RBXScriptConnection } = {}
local rememberedOut: string? = nil

-- Settings and favorites waiting to be sent (the latest value of each), and the send timer's serial.
local unsentSettings: { [string]: any } = {}
local unsentFavorites: { [string]: boolean } = {}
local sendSerial = 0
local nextFavoriteBatch = 0 -- os.clock() when the SetFavorite rate limit has room for another batch
local appliedCamera: string? = nil

-- Forward declarations (the callbacks below reference each other).
local render: () -> ()

-- Opening and closing -------------------------------------------------------------------------------------------

local function onBackAction(
	_actionName: string,
	state: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		PhoneController.back()
	end
	return Enum.ContextActionResult.Sink
end

local function bindBack(on: boolean)
	if on == backBound then
		return
	end
	backBound = on
	local action = PhoneConfig.actions.back
	if on then
		ContextActionService:BindActionAtPriority(
			action,
			onBackAction,
			false,
			ACTION_PRIORITY,
			table.unpack(PhoneConfig.keys.back)
		)
	else
		ContextActionService:UnbindAction(action)
	end
end

-- Opens the phone on an app (nil: the home screen). Opening while it's open switches to that app. Does nothing
-- while a shop sheet is open: the two would stack and fight over gamepad B.
function PhoneController.open(app: AppId?)
	if ShopController.isOpen() then
		return
	end
	closeSerial += 1
	view.open = true
	view.leaving = false
	view.app = app
	view.confirmUid = nil
	bindBack(true)
	render()
end

-- Slides the sheet away, then unmounts it.
function PhoneController.close()
	if not view.open or view.leaving then
		return
	end
	closeSerial += 1
	local serial = closeSerial
	view.leaving = true
	view.confirmUid = nil
	bindBack(false)
	render()
	task.delay(Theme.motion.sheetSeconds, function()
		if serial == closeSerial then
			view.open = false
			view.leaving = false
			view.app = nil
			render()
		end
	end)
end

function PhoneController.toggle()
	if view.open and not view.leaving then
		PhoneController.close()
	else
		PhoneController.open(nil)
	end
end

-- One step back: the sell confirm, then the home screen, then closed.
function PhoneController.back()
	if view.confirmUid ~= nil and view.busy == nil then
		view.confirmUid = nil
		render()
	elseif view.app ~= nil then
		view.app = nil
		render()
	else
		PhoneController.close()
	end
end

function PhoneController.isOpen(): boolean
	return view.open and not view.leaving
end

local function onToggleAction(
	_actionName: string,
	state: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if UserInputService:GetFocusedTextBox() ~= nil then
		return Enum.ContextActionResult.Pass -- typing a P in the chat or the code box
	end
	if state == Enum.UserInputState.Begin then
		PhoneController.toggle()
	end
	return Enum.ContextActionResult.Sink
end

-- Replies --------------------------------------------------------------------------------------------------------

-- Shows a server reply ({ ok, message }) as a notice. Returns true when the request worked.
local function showReply(called: boolean, reply: any): boolean
	if not called then
		NotifyController.show(PhoneConfig.labels.failed, "error")
		return false
	elseif type(reply) == "table" and type(reply.message) == "string" then
		local worked = reply.ok == true
		NotifyController.show(reply.message, if worked then "success" else "error")
		return worked
	end
	-- No answer: Net turned the request away (too many in a row).
	NotifyController.show(PhoneConfig.labels.tryLater, "warning")
	return false
end

-- Garage -------------------------------------------------------------------------------------------------------

local function currentOut(): string?
	for model in tracked do
		local uid = model:GetAttribute(Garage.ownedUidAttribute)
		if type(uid) == "string" then
			return uid
		end
	end
	return rememberedOut
end

local function updateOut()
	local out = currentOut()
	if out ~= view.outUid then
		view.outUid = out
		render()
	end
end

local function track(instance: Instance)
	if not instance:IsA("Model") or tracked[instance] then
		return
	end
	if instance:GetAttribute(OWNER_ATTRIBUTE) ~= Players.LocalPlayer.UserId then
		return
	end
	-- GarageService marks which owned car it is just after VehicleService spawns it.
	tracked[instance] = instance:GetAttributeChangedSignal(Garage.ownedUidAttribute):Connect(updateOut)
	updateOut()
end

local function untrack(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local connection = tracked[instance]
	if not connection then
		return
	end
	connection:Disconnect()
	tracked[instance] = nil
	if instance:GetAttribute(Garage.ownedUidAttribute) == rememberedOut then
		rememberedOut = nil -- put away, sold, despawned after sitting parked, or streamed out of range
	end
	updateOut()
end

-- Sends one garage request (one at a time) and shows the reply. `after` runs once the answer is in, told
-- whether the request worked.
local function garageRequest(remote: string, payload: any, busy: GarageApp.Busy, after: (worked: boolean) -> ())
	if view.busy ~= nil then
		return
	end
	view.busy = busy
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, remote, payload)
		view.busy = nil
		after(showReply(called, reply))
		render()
	end)
end

local function spawnCar(uid: string)
	garageRequest("SpawnOwned", { uid = uid }, { uid = uid, action = "spawn" }, function(worked: boolean)
		if worked then
			rememberedOut = uid
			updateOut()
			PhoneController.close() -- the player is in their car: get the phone out of the way
		end
	end)
end

local function putAway()
	garageRequest("DespawnOwned", nil, { uid = nil, action = "despawn" }, function(worked: boolean)
		if worked then
			rememberedOut = nil
			updateOut()
		end
	end)
end

local function askSell(uid: string)
	if view.busy == nil then
		view.confirmUid = uid
		render()
	end
end

local function cancelSell()
	if view.busy == nil then
		view.confirmUid = nil
		render()
	end
end

local function confirmSell(uid: string)
	garageRequest("SellVehicle", { uid = uid }, { uid = uid, action = "sell" }, function(worked: boolean)
		-- The confirm closes once the answer is in, worked or not; the notice says which.
		if view.confirmUid == uid then
			view.confirmUid = nil
		end
		if worked and rememberedOut == uid then
			rememberedOut = nil
			updateOut()
		end
	end)
end

-- Sends the waiting favorites, at most the SetFavorite remote's burst less one at a time (Net would turn the rest
-- away). Whatever is left goes once the rate limit has room for another batch; a new tap's timer also sends it.
local function flushFavorites()
	local spec = Net.declared().SetFavorite
	local batch = math.max(spec.burst - 1, 1)
	local serial = sendSerial
	local wait = nextFavoriteBatch - os.clock()
	if wait > 0 then
		-- The last batch hasn't been paid back yet.
		task.delay(wait, function()
			if serial == sendSerial then
				flushFavorites()
			end
		end)
		return
	end
	local sent = 0
	for uid, favorite in unsentFavorites do
		if sent >= batch then
			break
		end
		unsentFavorites[uid] = nil
		ProfileController.patchFavorite(uid, favorite) -- holds the star until the server's answer
		Net.fireServer("SetFavorite", { uid = uid, favorite = favorite })
		sent += 1
	end
	nextFavoriteBatch = os.clock() + sent / spec.perSecond
	if next(unsentFavorites) ~= nil then
		flushFavorites() -- waits for the rate limit to have room again
	end
end

-- Sends the settings and favorites waiting to go, after a short pause with no new taps.
local function scheduleSend()
	sendSerial += 1
	local serial = sendSerial
	task.delay(PhoneConfig.sendDelaySeconds, function()
		if serial ~= sendSerial then
			return -- another tap came in: its timer sends everything
		end
		if next(unsentSettings) ~= nil then
			Net.fireServer("UpdateSettings", unsentSettings)
			unsentSettings = {}
		end
		flushFavorites()
	end)
end

local function setFavorite(uid: string, favorite: boolean)
	ProfileController.patchFavorite(uid, favorite)
	unsentFavorites[uid] = favorite
	scheduleSend()
end

local function directions(locationId: string)
	if GpsController.hasLocation(locationId) then
		GpsController.setDestination(locationId)
		PhoneController.close()
	end
end

-- GPS ----------------------------------------------------------------------------------------------------------

local function pickDestination(id: string)
	GpsController.setDestination(id)
	PhoneController.close() -- show the road and the route line
end

local function clearRoute()
	GpsController.setDestination(nil)
end

-- Codes --------------------------------------------------------------------------------------------------------

-- Sends the typed code to the server (which decides everything) and shows its answer as a notice. Empties the
-- box when the code worked and leaves it when it didn't, so a typo can be fixed.
local function redeem(text: string)
	if view.redeeming then
		return
	end
	local messages = Economy.codes.messages
	local code = string.match(text, "^%s*(.-)%s*$") or ""
	if code == "" then
		NotifyController.show(messages.empty, "warning")
		return
	elseif #code > Economy.codes.maxLength then
		NotifyController.show(messages.unknown, "error") -- no code is that long; the server would refuse to read it
		return
	end
	view.redeeming = true
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, "RedeemCode", code)
		view.redeeming = false
		if not called then
			NotifyController.show(messages.failed, "error")
		elseif type(reply) == "table" and type(reply.message) == "string" then
			local worked = reply.ok == true
			if worked then
				view.codesClear += 1
			end
			NotifyController.show(reply.message, if worked then "success" else "error")
		else
			NotifyController.show(messages.tryLater, "warning")
		end
		render()
	end)
end

-- Settings -----------------------------------------------------------------------------------------------------

local function setSetting(field: string, value: any)
	ProfileController.patchSettings({ [field] = value })
	unsentSettings[field] = value
	scheduleSend()
end

-- Puts the camera in the player's starting view whenever that setting changes, once their profile loads, and
-- (with `force`) at the start of every drive, so a view cycled on the last drive doesn't carry over. Cycling
-- the camera during a drive is left alone.
local function applyCamera(force: boolean?)
	if not ProfileController.isLoaded() then
		return
	end
	local camera = ProfileController.settings().camera
	if camera == appliedCamera and not force then
		return
	end
	appliedCamera = camera
	if table.find(CameraConfig.modes, camera :: any) then
		CameraController.setMode(camera :: any)
	end
end

-- Rendering ----------------------------------------------------------------------------------------------------

local function appTitle(app: AppId?): string
	if app ~= nil then
		for _, entry in PhoneConfig.apps do
			if entry.id == app then
				return entry.label
			end
		end
	end
	return PhoneConfig.labels.home
end

-- The open app's screen.
local function appBody(app: AppId?): any
	if app == "gps" then
		return e(GpsApp, { sections = sections, status = view.gps, onPick = pickDestination, onClear = clearRoute })
	elseif app == "garage" then
		return e(GarageApp, {
			profile = view.profile,
			outUid = view.outUid,
			busy = view.busy,
			confirmUid = view.confirmUid,
			onSpawn = spawnCar,
			onPutAway = putAway,
			onFavorite = setFavorite,
			onAskSell = askSell,
			onCancelSell = cancelSell,
			onConfirmSell = confirmSell,
			onDirections = directions,
		})
	elseif app == "jobs" then
		return e(JobsApp, {})
	elseif app == "fleet" then
		return e(FleetApp, {})
	elseif app == "wallet" then
		return e(WalletApp, { profile = view.profile })
	elseif app == "codes" then
		return e(CodesApp, {
			redeeming = view.redeeming,
			clearToken = view.codesClear,
			autoFocus = view.inputKind == "keyboard",
			onRedeem = redeem,
		})
	elseif app == "settings" then
		return e(SettingsApp, {
			settings = ProfileController.settings(),
			onUnits = function(units: string)
				setSetting("units", units)
			end,
			onCamera = function(camera: string)
				setSetting("camera", camera)
			end,
			onMusicVolume = function(volume: number)
				setSetting("musicVolume", volume)
			end,
		})
	end
	return nil
end

render = function()
	if root == nil then
		return
	end
	local touch = view.inputKind == "touch"
	local context: Layout.Context = {
		driving = view.driving,
		touch = view.driving and touch,
		hints = view.driving and not touch,
	}
	local screen = view.screen
	root:render(e("Frame", {
		Size = UDim2.fromScale(1 / view.scale, 1 / view.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = view.scale }),
		Phone = e(Phone, {
			screen = screen,
			button = Layout.phoneButton(screen, context),
			sheet = Layout.sheet(screen, context),
			inputKind = view.inputKind,
			open = view.open,
			leaving = view.leaving,
			app = view.app,
			title = appTitle(view.app),
			body = if view.open then appBody(view.app) else nil,
			routeActive = view.gps ~= nil,
			onToggle = PhoneController.toggle,
			onClose = PhoneController.close,
			onBack = PhoneController.back,
			onOpenApp = function(id: AppId)
				PhoneController.open(id)
			end,
		}),
	}))
end

-- Boot ---------------------------------------------------------------------------------------------------------

function PhoneController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.ResetOnSpawn = false -- one phone for the whole session
	screenGui.DisplayOrder = Theme.displayOrder.phone
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- The same safe area as the HUD, so the phone button lines up with the speed panel.
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.Parent = playerGui

	root = ReactRoblox.createRoot(screenGui)
	sections = GpsController.destinations()

	local function measure()
		view.scale = HudController.scaleFor(screenGui.AbsoluteSize)
		view.screen = Layout.layoutSize(screenGui.AbsoluteSize, view.scale)
	end
	measure()
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		measure()
		render()
	end)

	-- The keys that open and close the phone, from anywhere.
	local keys: { Enum.KeyCode } = table.clone(PhoneConfig.keys.keyboard)
	table.move(PhoneConfig.keys.gamepad, 1, #PhoneConfig.keys.gamepad, #keys + 1, keys)
	ContextActionService:BindActionAtPriority(
		PhoneConfig.actions.toggle,
		onToggleAction,
		false,
		ACTION_PRIORITY,
		table.unpack(keys)
	)

	-- What the layout follows: driving or not, and which controls the player uses.
	view.inputKind = HudController.getInputKind()
	HudController.onInputKindChanged:Connect(function(kind: InputKind)
		if kind ~= view.inputKind then
			view.inputKind = kind
			render()
		end
	end)
	view.driving = DriveController.getCar() ~= nil
	DriveController.onDrivingChanged:Connect(function(driving: boolean)
		view.driving = driving
		if driving then
			applyCamera(true) -- every drive starts in the saved view
		end
		render()
	end)

	-- The profile: garage, wallet, settings.
	ProfileController.onChanged:Connect(function(snapshot: Types.ProfileSnapshot)
		view.profile = snapshot
		if view.confirmUid ~= nil then
			local stillOwned = false
			for _, vehicle in snapshot.vehicles do
				stillOwned = stillOwned or vehicle.uid == view.confirmUid
			end
			if not stillOwned then
				view.confirmUid = nil
			end
		end
		applyCamera()
		render()
	end)
	view.profile = ProfileController.get()
	applyCamera()

	-- The GPS: the active route for the app and the icon's dot; the route chip opens the app.
	view.gps = GpsController.getStatus()
	GpsController.onStatusChanged:Connect(function(status: GpsController.Status?)
		view.gps = status
		render()
	end)
	GpsController.onChipTapped:Connect(function()
		PhoneController.open("gps")
	end)
	-- A shop sheet opening puts the phone away.
	ShopController.onOpened:Connect(function()
		PhoneController.close()
	end)

	-- Which garage car is out: this player's spawned cars that carry an owned-car uid.
	CollectionService:GetInstanceAddedSignal(Spawning.vehicleTag):Connect(track)
	CollectionService:GetInstanceRemovedSignal(Spawning.vehicleTag):Connect(untrack)
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		track(instance)
	end

	render()
end

return PhoneController
