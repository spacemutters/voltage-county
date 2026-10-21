--!strict
-- The Wrap & Tint shop on the client (docs/phase-7-contracts.md "Client"; PLAN.md Phase 7).
--
--   opening     the shop's "Customize" prompt (ProximityPromptService.PromptTriggered on this client, a prompt
--               under a CustomShop location part) while the player drives one of their own cars (a car with an
--               OwnedUid attribute that is in their profile). DriveController hides every prompt while the player
--               is seated, so while their own car stands in a shop's bay (a CustomShop footprint in
--               Config/MapLayout) a "Customize" button shows as well, and E / gamepad A do the same. The server
--               (Services/CustomizationService) checks the same things on every call.
--   the panel   a side panel on the right (UI/Customize/Panel), tabs from Config/Customization.categories (Paint,
--               Finish, Wrap, Wheels, Stance, Tint, Calipers, Extras, Plate), options and prices from
--               Config/Customization (UI/Customize/CustomizeModel); Extras lists only what the car's class takes.
--   preview     every choice goes on the player's own car at once, on this client only (UI/Customize/Preview,
--               Vehicle/Appearance.apply); closing (or Reset) puts the saved look back. The saved look is the one
--               the server put on the car (Appearance.lookOf, plate text already filtered), or the profile's copy
--               of the car when the model has none.
--   buying      a running total of what differs from the car (Config/Customization.priceOf, the server's own
--               pricing); Buy asks first (total, cash, cash after) unless the change is free, then sends
--               BuyCustomization with only what changed. The server decides and puts the look on the car for
--               everyone; on success the look stays and the shop stays open for more. Custom plate text goes
--               through SetPlate (the server filters it; empty text goes back to the standard plate).
--   camera      the orbit view while the shop is open (CameraController.setMode), slid sideways so the car sits
--               in the middle of the screen the panel leaves free; the player's own view comes back after.
--   closing     the close button, gamepad B, driving out of the bay, leaving the seat, the car going away, or
--               the character resetting.
--
-- Server-authoritative: these are only requests, and every answer shows as a notice (NotifyController). While a
-- call is in flight Buy, Reset and Set plate are off; a reply that lands after the shop closed still shows its
-- notice. When the server puts a look on a car this client previewed on, Preview tells us and the car is shown as
-- one look again (onServerLook). No polling: while the player drives, one Heartbeat connection checks a few times
-- a second (Style.bayCheckHz) whether the car stands in a bay (dropped when they stop driving), and only while the
-- shop is open does a render step slide the camera.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local CameraConfig = require(ReplicatedStorage.Shared.Config.Camera)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Monetization = require(ReplicatedStorage.Shared.Config.Monetization)
local Net = require(ReplicatedStorage.Shared.Net)
local CameraController = require(script.Parent.CameraController)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local NotifyController = require(script.Parent.NotifyController)
local PhoneController = require(script.Parent.PhoneController)
local ProfileController = require(script.Parent.ProfileController)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local Primitives = require(UI.Shop.Primitives)
local ShopModel = require(UI.Shop.ShopModel)
local CustomizeModel = require(UI.Customize.CustomizeModel)
local EntryButton = require(UI.Customize.EntryButton)
local Panel = require(UI.Customize.Panel)
local Preview = require(UI.Customize.Preview)
local Style = require(UI.Customize.Style)

local GUI_NAME = "Customize"
local OPEN_ACTION = "CustomizeOpen"
local CLOSE_ACTION = "CustomizeClose"
local ORBIT_MODE: CameraConfig.Mode = "orbit"
-- Above the driving controls (Config/Controls.actionPriority), so gamepad A opens the shop instead of being sunk
-- and gamepad B closes it instead of standing the player up.
local ACTION_PRIORITY = Controls.actionPriority + 1
-- Framing runs right after CameraController (RenderPriority.Camera + 1), which writes the camera every frame and
-- never reads it back, so the sideways slide never feeds into its own maths.
local FRAMING_STEP = "CustomizeFraming"
local FRAMING_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local e = React.createElement
local copy = Style.copy
-- Slack round a bay's footprint before an open shop counts the car as gone: the server's own number, so the panel
-- closes exactly when a purchase would be refused.
local BAY_SLACK = Customization.shop.footprintSlack

type Look = CustomizeModel.Look
type Location = CustomizeModel.Location
type Busy = "buy" | "plate"

-- The open shop.
type Session = {
	car: Model,
	uid: string,
	title: string, -- the car's name
	class: string, -- its Config/Classes id (prices and which extras fit)
	bodyStyle: string, -- its Config/Vehicles bodyStyle (some extras fit only some bodies)
	bay: Location?, -- the bay it opened in; driving out of it closes the shop
	saved: Look, -- what the car wears
	pending: Look, -- what the player is trying on
	tab: CustomizeModel.TabId,
	cameraMode: CameraConfig.Mode?, -- the camera view to put back on close (nil: we didn't change it)
	watch: RBXScriptConnection, -- closes the shop when the car leaves the world
}

type View = {
	session: Session?,
	confirm: boolean, -- the Buy confirm is showing
	busy: Busy?,
	cash: number?,
	entryBay: Location?, -- the bay the player's own car stands in (the Customize button shows)
	scale: number,
	screen: Vector2, -- unscaled pixels inside the safe area
}

local CustomizationController = {}

local localPlayer = Players.LocalPlayer

local view: View = {
	session = nil,
	confirm = false,
	busy = nil,
	cash = nil,
	entryBay = nil,
	scale = 1,
	screen = Vector2.new(Controls.hud.referenceShortSide, Controls.hud.referenceShortSide),
}

local root: any = nil
local screenGui: ScreenGui? = nil
local bayCheck: RBXScriptConnection? = nil
local openBound = false
local closeBound = false
local framingBound = false
local framingShift = 0 -- studs the camera is slid right this frame (eases toward its target)

-- Defined below; the panel, the keys and the bay check call them.
local close: () -> ()
local tryOpen: (bay: Location?, quiet: boolean) -> ()
local pickTab: (tab: string) -> ()
local pick: (key: string) -> ()
local step: (key: string, direction: number) -> ()
local reset: () -> ()
local requestBuy: () -> ()
local confirmBuy: () -> ()
local cancelBuy: () -> ()
local submitPlate: (text: string) -> ()

-- Profile and cash ---------------------------------------------------------------------------------------------------

local function readCash()
	local snapshot = ProfileController.get()
	if snapshot ~= nil then
		view.cash = snapshot.cash
		return
	end
	local attribute = localPlayer:GetAttribute(Economy.cashAttribute)
	view.cash = if type(attribute) == "number" then attribute else nil
end

-- The player's own car with this uid, as their profile snapshot describes it (nil when it isn't theirs).
local function ownedEntry(uid: string): { [string]: any }?
	local snapshot = ProfileController.get()
	if snapshot == nil then
		return nil
	end
	for _, vehicle in snapshot.vehicles do
		if vehicle.uid == uid then
			return vehicle :: any
		end
	end
	return nil
end

-- The car the local player drives, when it is one of their own garage cars (not a test drive): (car, uid).
local function ownCar(): (Model?, string?)
	local car = DriveController.getCar()
	if car == nil then
		return nil, nil
	end
	local uid = car:GetAttribute(Garage.ownedUidAttribute)
	if type(uid) ~= "string" or ownedEntry(uid) == nil then
		return nil, nil
	end
	return car, uid
end

-- The player attribute MonetizationService keeps true while the Custom Plates pass is owned (a pass given in Studio
-- with DevPurchase counts too).
local PLATES_PASS_ATTRIBUTE = Monetization.attributes.passPrefix .. Customization.shop.passId

-- The exclusive looks the player has (Phase 12: the profile snapshot's `looks`), so the Wrap tab lists those
-- wraps. The server checks ownership again on every purchase (Services/CustomizationService).
local function ownedLooks(): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	local snapshot = ProfileController.get()
	if snapshot ~= nil and snapshot.looks ~= nil then
		for _, id in snapshot.looks do
			owned[id] = true
		end
	end
	return owned
end

-- Custom plate text needs the Custom Plates pass (Phase 12); until the pass is created (its id is 0), only Studio
-- allows it. The server's rule (Services/CustomizationService.customTextAllowed); the server decides either way.
local function customPlatesAllowed(): boolean
	local passId = Monetization.passes[Customization.shop.passId]
	if type(passId) == "number" and passId > 0 then
		return localPlayer:GetAttribute(PLATES_PASS_ATTRIBUTE) == true
	end
	return RunService:IsStudio()
end

-- Rendering ----------------------------------------------------------------------------------------------------------

local function confirmFor(session: Session): Primitives.Confirm?
	if not view.confirm then
		return nil
	end
	local total = CustomizeModel.totalOf(session.saved, session.pending, session.class)
	return {
		title = copy.confirmTitle,
		rows = CustomizeModel.confirmRows(total, view.cash),
		confirmLabel = copy.buy,
		busyLabel = copy.buying,
		busy = view.busy ~= nil,
		onConfirm = confirmBuy,
		onCancel = cancelBuy,
	}
end

-- The whole tree: the root frame is sized 1/scale so that, after the UIScale, it fills the screen and the panel is
-- laid out in unscaled (phone) pixels, like the driving HUD.
local function App(props: { view: View })
	local current = props.view
	local session = current.session
	local inputKind = HudController.getInputKind()
	local children: { [string]: any } = {
		Scale = e("UIScale", { Scale = current.scale }),
	}
	if session ~= nil then
		children.Panel = e(Panel.Panel, {
			view = CustomizeModel.panelView({
				title = session.title,
				tab = session.tab,
				saved = session.saved,
				pending = session.pending,
				class = session.class,
				bodyStyle = session.bodyStyle,
				cash = current.cash,
				busy = current.busy ~= nil,
				platePending = current.busy == "plate",
				plateAllowed = customPlatesAllowed(),
				looks = ownedLooks(),
			}),
			screen = current.screen,
			gamepad = inputKind == "gamepad",
			confirm = confirmFor(session),
			onTab = pickTab,
			onReset = reset,
			onBuy = requestBuy,
			onClose = close,
			onPick = pick,
			onStep = step,
			onPlate = submitPlate,
		})
	elseif current.entryBay ~= nil then
		children.Entry = e(EntryButton, {
			label = copy.customize,
			keyGlyph = Style.input.openKeyGlyphs[inputKind],
			top = HudController.noticesRect(current.screen).bottom + Style.layout.entryGap,
			onTap = function()
				tryOpen(view.entryBay, false)
			end,
		})
	end
	return e("Frame", {
		Size = UDim2.fromScale(1 / current.scale, 1 / current.scale),
		BackgroundTransparency = 1,
	}, children)
end

local function render()
	if root == nil then
		return
	end
	if view.session == nil and view.entryBay == nil then
		root:render(nil)
		return
	end
	root:render(e(App, { view = table.clone(view) }))
end

-- Keys ---------------------------------------------------------------------------------------------------------------

local function onOpenKey(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and view.session == nil and view.entryBay ~= nil then
		tryOpen(view.entryBay, false)
	end
	return Enum.ContextActionResult.Sink
end

local function bindOpenKeys(on: boolean)
	if on == openBound then
		return
	end
	openBound = on
	if on then
		ContextActionService:BindActionAtPriority(
			OPEN_ACTION,
			onOpenKey,
			false,
			ACTION_PRIORITY,
			table.unpack(Style.input.openKeys)
		)
	else
		ContextActionService:UnbindAction(OPEN_ACTION)
	end
end

local function onCloseKey(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		if view.confirm then
			cancelBuy()
		else
			close()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function bindCloseKeys(on: boolean)
	if on == closeBound then
		return
	end
	closeBound = on
	if on then
		ContextActionService:BindActionAtPriority(
			CLOSE_ACTION,
			onCloseKey,
			false,
			ACTION_PRIORITY,
			table.unpack(Style.input.closeKeys)
		)
	else
		ContextActionService:UnbindAction(CLOSE_ACTION)
	end
end

-- The Customize button -----------------------------------------------------------------------------------------------

-- Shows the Customize button (and binds its keys) while the player's own car stands in a bay and the shop is
-- closed; hides it otherwise. Re-renders only when that changes.
local function setEntryBay(bay: Location?)
	local shown = if view.session == nil then bay else nil
	bindOpenKeys(shown ~= nil)
	if shown == view.entryBay then
		return
	end
	view.entryBay = shown
	render()
end

-- One bay check: the Customize button while the shop is closed; driving out of the bay while it is open.
local function checkBay()
	local session = view.session
	if session ~= nil then
		local bay = session.bay
		local chassis = session.car.PrimaryPart
		if bay ~= nil and chassis ~= nil and not CustomizeModel.inBay(chassis.Position, bay, BAY_SLACK) then
			close()
		end
		return
	end
	local car = ownCar()
	local chassis = if car ~= nil then car.PrimaryPart else nil
	setEntryBay(if chassis ~= nil then CustomizeModel.bayAt(chassis.Position, 0) else nil)
end

local function startBayCheck()
	if bayCheck ~= nil then
		return
	end
	local interval = 1 / Style.bayCheckHz
	local elapsed = interval -- check on the first frame
	bayCheck = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			checkBay()
		end
	end)
end

local function stopBayCheck()
	local connection = bayCheck
	if connection ~= nil then
		connection:Disconnect()
		bayCheck = nil
	end
	setEntryBay(nil)
end

-- Framing ----------------------------------------------------------------------------------------------------------------

-- Slides the orbit camera sideways (after CameraController has placed it this frame) so the car sits in the middle
-- of the part of the screen the panel leaves free, easing there when the shop opens.
local function frameCar(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil or camera.CameraType ~= Enum.CameraType.Scriptable or view.session == nil then
		return
	end
	if CameraController.getMode() ~= ORBIT_MODE then
		framingShift = 0 -- the player switched to another view: leave it as CameraController placed it
		return
	end
	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return
	end
	local rect = CustomizeModel.panelLayout(view.screen)
	local covered = (rect.width + Style.layout.margin) * view.scale / viewport.X
	local distance = (camera.CFrame.Position - camera.Focus.Position).Magnitude
	local target = CustomizeModel.framingShift(covered, camera.FieldOfView, viewport.X / viewport.Y, distance)
	local alpha = 1 - math.exp(-Style.framing.stiffness * dt)
	framingShift += (target - framingShift) * alpha
	camera.CFrame *= CFrame.new(framingShift, 0, 0)
end

local function bindFraming(on: boolean)
	if on == framingBound then
		return
	end
	framingBound = on
	framingShift = 0
	if on then
		RunService:BindToRenderStep(FRAMING_STEP, FRAMING_PRIORITY, frameCar)
	else
		RunService:UnbindFromRenderStep(FRAMING_STEP)
	end
end

-- Opening and closing ------------------------------------------------------------------------------------------------

-- Opens the shop for the car the player drives. `quiet`: say nothing when it can't open (the prompt path, where
-- the server already tells the player why).
tryOpen = function(bay: Location?, quiet: boolean)
	if view.session ~= nil then
		return
	end
	local function refuse(text: string)
		if not quiet then
			NotifyController.show(text, "warning")
		end
	end
	if not ProfileController.isLoaded() then
		refuse(copy.loading)
		return
	end
	local car, uid = ownCar()
	local owned = if uid ~= nil then ownedEntry(uid) else nil
	-- The car is looked up by its model's catalog id: a player design is saved as "custom" but spawns as
	-- "custom:<designUid>", which resolves through the designs the server published (Vehicle/Catalog).
	local modelId = if car ~= nil then car:GetAttribute("VehicleId") else nil
	local info = if owned == nil
		then nil
		else (if type(modelId) == "string" then CustomizeModel.vehicleInfo(modelId) else nil)
			or CustomizeModel.vehicleInfo(owned.vehicleId)
	if car == nil or uid == nil or owned == nil or info == nil then
		refuse(copy.notYourCar)
		return
	end
	-- Opened from the prompt: the bay the car stands in decides when it has driven off.
	local chassis = car.PrimaryPart
	local openBay = bay or (if chassis ~= nil then CustomizeModel.bayAt(chassis.Position, BAY_SLACK) else nil)
	-- What the car wears: the look the server put on the model (plate text already filtered); the profile's copy
	-- of the car when the model has none yet.
	local saved = Preview.lookOf(car) or CustomizeModel.savedLook(owned, nil)

	local session: Session = {
		car = car,
		uid = uid,
		title = info.name,
		class = info.class,
		bodyStyle = info.bodyStyle,
		bay = openBay,
		saved = saved,
		pending = CustomizeModel.cloneLook(saved),
		tab = CustomizeModel.tabs[1].id,
		cameraMode = nil,
		-- The car going away (put away, despawned) closes the shop.
		watch = car.AncestryChanged:Connect(function()
			if not car:IsDescendantOf(Workspace) then
				close()
			end
		end),
	}
	view.session = session
	view.confirm = false
	view.busy = nil
	setEntryBay(nil)
	readCash()

	-- The orbit view frames the car (drag to look round it); the player's own view comes back on close.
	local mode: CameraConfig.Mode = CameraController.getMode() :: any
	if mode ~= ORBIT_MODE then
		session.cameraMode = mode
		CameraController.setMode(ORBIT_MODE)
	end
	bindFraming(true)
	PhoneController.close() -- the phone and the panel would overlap
	bindCloseKeys(true)
	render()
end

close = function()
	local session = view.session
	if session == nil then
		return
	end
	view.session = nil
	view.confirm = false
	-- A call still in flight finishes on its own; its notice still shows.
	view.busy = nil
	session.watch:Disconnect()
	-- Put the saved look back if the player was trying something else on.
	local car = session.car
	if car.Parent ~= nil and not CustomizeModel.sameLook(session.saved, session.pending) then
		Preview.apply(car, session.saved)
	end
	bindFraming(false)
	local mode = session.cameraMode
	if mode ~= nil and CameraController.getMode() == ORBIT_MODE then
		CameraController.setMode(mode :: any) -- (the analyzer widens Config/Camera's Mode to string here)
	end
	bindCloseKeys(false)
	-- Let go of a gamepad selection inside the panel.
	local selected = GuiService.SelectedObject
	local gui = screenGui
	if selected ~= nil and gui ~= nil and selected:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	render()
	-- Still in the bay: the Customize button comes back on the next bay check.
end

-- True while the Wrap & Tint panel is open.
function CustomizationController.isOpen(): boolean
	return view.session ~= nil
end

-- The server put a look on a car this client previewed on (after a purchase, a new plate, or a spawn-time plate
-- filter finishing). Show one look again: the one being tried on while the shop is open on that car (with the
-- server's word on what the car now wears), else the server's.
local function onServerLook(car: Model, look: Look?)
	local session = view.session
	if session ~= nil and session.car == car then
		if look ~= nil then
			session.saved = look
			session.pending.uid = look.uid
			session.pending.plateText = look.plateText
		end
		Preview.apply(car, session.pending)
		render()
		return
	end
	local current = look or Preview.lookOf(car)
	if current ~= nil then
		Preview.apply(car, current)
	end
end

-- Choosing -----------------------------------------------------------------------------------------------------------

-- Puts the look being tried on onto the car (this client only) and redraws.
local function preview(session: Session, look: Look)
	session.pending = look
	Preview.apply(session.car, look)
	render()
end

pickTab = function(tab: string)
	local session = view.session
	if session == nil or view.confirm then
		return
	end
	local id = CustomizeModel.tabId(tab)
	if id == nil or id == session.tab then
		return
	end
	session.tab = id
	render()
end

pick = function(key: string)
	local session = view.session
	if session == nil or view.confirm then
		return
	end
	local look = CustomizeModel.pick(session.saved, session.pending, session.tab, key, session.class, session.bodyStyle)
	if look ~= nil then
		preview(session, look)
	end
end

step = function(key: string, direction: number)
	local session = view.session
	if session == nil or view.confirm then
		return
	end
	local look = CustomizeModel.step(session.pending, key, direction)
	if look ~= nil then
		preview(session, look)
	end
end

reset = function()
	local session = view.session
	if session == nil or view.busy ~= nil or view.confirm then
		return
	end
	if not CustomizeModel.sameLook(session.saved, session.pending) then
		preview(session, CustomizeModel.cloneLook(session.saved))
	end
end

-- Calls ----------------------------------------------------------------------------------------------------------------

-- Calls a remote with Buy, Reset and Set plate off until the answer comes back, then shows the answer as a notice
-- and hands it to `finish` (`current` is false when the shop closed or reopened meanwhile).
local function call(busy: Busy, remote: string, payload: any, finish: (ok: boolean, reply: any, current: boolean) -> ())
	if view.busy ~= nil then
		return
	end
	local session = view.session
	view.busy = busy
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, remote, payload)
		local current = session ~= nil and view.session == session
		if current then
			view.busy = nil
		end
		local ok, message, kind = ShopModel.outcome(called, reply)
		NotifyController.show(message, kind)
		finish(ok, reply, current)
		render()
	end)
end

local function sendBuy()
	local session = view.session
	if session == nil then
		return
	end
	local changes = CustomizeModel.changesOf(session.saved, session.pending)
	if changes == nil then
		view.confirm = false
		render()
		return
	end
	local bought = CustomizeModel.cloneLook(session.pending)
	call("buy", "BuyCustomization", { uid = session.uid, changes = changes }, function(ok, _reply, current)
		if not current then
			return
		end
		view.confirm = false
		local now = view.session
		if ok and now ~= nil then
			-- Saved, and on the car for everyone (the server's pieces landing are handled by onServerLook).
			now.saved = bought
		end
	end)
end

requestBuy = function()
	local session = view.session
	if session == nil or view.busy ~= nil or view.confirm then
		return
	end
	local total = CustomizeModel.totalOf(session.saved, session.pending, session.class)
	if not total.hasChanges or not CustomizeModel.canAfford(total, view.cash) then
		return
	end
	if total.amount <= 0 then
		sendBuy() -- nothing to pay (a plate style): no need to ask
		return
	end
	view.confirm = true
	render()
end

confirmBuy = function()
	if view.session == nil or not view.confirm or view.busy ~= nil then
		return
	end
	sendBuy()
end

cancelBuy = function()
	if not view.confirm or view.busy ~= nil then
		return
	end
	view.confirm = false
	render()
end

-- Sends custom plate text (empty: back to the standard plate). The server checks the rules, filters the text and
-- puts the plate on; its answer shows as a notice.
submitPlate = function(text: string)
	local session = view.session
	if session == nil or view.busy ~= nil or not customPlatesAllowed() then
		return
	end
	local clean = CustomizeModel.cleanPlate(text, CustomizeModel.plateMaxLength(), true)
	call("plate", "SetPlate", { uid = session.uid, text = clean }, function()
		-- Nothing else to do: a new plate reaches the car through onServerLook.
	end)
end

-- Boot -----------------------------------------------------------------------------------------------------------------

-- The screen in unscaled pixels and the UI scale (the HUD's rule: scale up from a landscape phone, never down).
local function measureScreen(): boolean
	local gui = screenGui
	if gui == nil then
		return false
	end
	local size = gui.AbsoluteSize
	local scale = HudController.scaleFor(size)
	local screen = Vector2.new(math.floor(size.X / scale), math.floor(size.Y / scale))
	if scale == view.scale and screen == view.screen then
		return false
	end
	view.scale = scale
	view.screen = screen
	return true
end

function CustomizationController:Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false -- one GUI for the whole session
	gui.DisplayOrder = Theme.displayOrder.shop
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep the panel clear of the Roblox top bar, notches and the home indicator.
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui
	screenGui = gui

	root = ReactRoblox.createRoot(gui)
	measureScreen()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if measureScreen() then
			render()
		end
	end)

	Preview.onServerLook(onServerLook)

	readCash()
	ProfileController.onChanged:Connect(function()
		readCash()
		render()
	end)
	localPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
		readCash()
		render()
	end)
	-- The Custom Plates pass bought (or found on join) unlocks the plate text box while the shop is open.
	localPlayer:GetAttributeChangedSignal(PLATES_PASS_ATTRIBUTE):Connect(function()
		render()
	end)
	-- Switching to a gamepad selects Buy; the key chip on the Customize button follows the input too.
	HudController.onInputKindChanged:Connect(function()
		render()
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= localPlayer then
			return
		end
		local bay = CustomizeModel.bayOfPrompt(prompt)
		if bay ~= nil or CustomizeModel.isShopPrompt(prompt) then
			tryOpen(bay, true)
		end
	end)

	DriveController.onDrivingChanged:Connect(function(driving: boolean)
		if driving then
			startBayCheck()
		else
			close()
			stopBayCheck()
		end
	end)
	if DriveController.getCar() ~= nil then
		startBayCheck()
	end
	localPlayer.CharacterRemoving:Connect(function()
		close()
	end)
end

return CustomizationController
