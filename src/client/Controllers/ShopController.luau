--!strict
-- The dealership and used-lot shop sheets (docs/phase-4-contracts.md "Shops"; PLAN.md Phase 4).
--
--   opening     ProximityPromptService.PromptTriggered on this client: a "View" prompt on a display car opens
--               the dealership sheet for its VehicleId, or the used-lot sheet for its Slot (ShopModel.targetOf
--               reads the prompt and the car it sits in). One sheet at a time; nothing opens while the player
--               sits in a car.
--   closing     the close button, a tap on the dim area, gamepad B, walking away (the prompt is hidden or
--               removed), getting into a car, the character resetting, or a pod ride's cutscene starting.
--   dealership  trims, stats and price from Config (UI/Shop/DealershipSheet). Buy and Upgrade ask first (a
--               confirm with the price and the cash left after), then call BuyVehicle / UpgradeVehicle; Test
--               drive calls StartTestDrive. On the robotaxi brand's cars (Phase 9) a Buy pods card closes the
--               sheet and fires onFleetRequested, and PhoneController opens the phone's Fleet app.
--   used lot    GetUsedLot when the sheet opens (today's stock), Buy with a confirm (BuyUsed), and the free
--               starter (ClaimStarter) until the player has claimed it (UI/Shop/UsedLotSheet).
--
-- Server-authoritative: these are only requests. The server decides every purchase and its answer is shown as
-- a notice (NotifyController). While a call is in flight every button is off; a call still running when the
-- sheet closes still shows its notice. The player's cars, cash, garage slots and units come from
-- ProfileController's snapshot (cash falls back to the Cash attribute). Owns the "Shop" ScreenGui
-- (Theme.displayOrder.shop), scaled like the HUD. No polling: prompt, profile and attribute events only.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Dealership = require(ReplicatedStorage.Shared.Config.Dealership)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Net = require(ReplicatedStorage.Shared.Net)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)

local UI = script.Parent.Parent.UI
local PhoneConfig = require(UI.Phone.PhoneConfig)
local Theme = require(UI.Theme)
local DealershipSheet = require(UI.Shop.DealershipSheet)
local Primitives = require(UI.Shop.Primitives)
local ShopModel = require(UI.Shop.ShopModel)
local ShopSheet = require(UI.Shop.ShopSheet)
local Style = require(UI.Shop.Style)
local UsedLotSheet = require(UI.Shop.UsedLotSheet)

local GUI_NAME = "Shop"
local CLOSE_ACTION = "ShopClose"
local PROFILE_MODULE = "ProfileController" -- written alongside this one (phone helper); looked up in Start
local PROFILE_REMOTE = "ProfileSnapshot"
local CUTSCENE_ATTRIBUTE = PhoneConfig.cutsceneAttribute

local e = React.createElement
local copy = Style.copy

-- The open sheet. Dealership sheets use vehicleId and trim (the selected trim); used-lot sheets use slot and
-- today's stock (with the starter claim as GetUsedLot reported it).
type Open = {
	kind: "dealership" | "usedLot",
	vehicleId: string,
	trim: string,
	slot: number,
	lotState: UsedLotSheet.LotState,
	lot: { ShopModel.LotEntry }?,
	lotStarterClaimed: boolean?,
	lotDate: string?, -- the lot day GetUsedLot answered for; BuyUsed sends it back
}

type ConfirmAction = "buy" | "upgrade" | "buyUsed"

-- A confirm dialog waiting for the player.
type Pending = {
	action: ConfirmAction,
	title: string,
	rows: { Primitives.ConfirmRow },
	confirmLabel: string,
	busyLabel: string,
	uid: string?, -- the owned car an upgrade applies to
}

type View = {
	open: Open?,
	confirm: Pending?,
	busy: Primitives.Busy?,
	snapshot: ShopModel.Snapshot?,
	cash: number?,
	units: ShopModel.Units,
	scale: number,
	screen: Vector2, -- unscaled pixels inside the safe area
	testDriveSeconds: number?,
}

local ShopController = {}

-- Fires () when a sheet opens. PhoneController closes the phone on it, so the two never stack and fight over
-- gamepad B (the phone can't be required here: it requires this module).
ShopController.onOpened = InputController.newSignal()

-- Fires () when the player taps Buy pods on a dealership sheet, after the sheet has closed. PhoneController opens
-- the Fleet app on it.
ShopController.onFleetRequested = InputController.newSignal()

local localPlayer = Players.LocalPlayer

local view: View = {
	open = nil,
	confirm = nil,
	busy = nil,
	snapshot = nil,
	cash = nil,
	units = "mph",
	scale = 1,
	screen = Vector2.new(Controls.hud.referenceShortSide, Controls.hud.referenceShortSide),
	testDriveSeconds = nil,
}

local root: any = nil
local screenGui: ScreenGui? = nil
-- Bumped whenever a sheet opens or closes: a reply that arrives later only shows its notice.
local session = 0
local currentPrompt: ProximityPrompt? = nil
local promptWatch: RBXScriptConnection? = nil
local closeBound = false
-- Set when BuyUsed answered "the price changed": the next lot load shows the confirm again.
local reconfirmAfterLoad = false

-- Where the profile snapshot comes from: ProfileController.get when it loaded, otherwise our own copy of the
-- last ProfileSnapshot event.
local profileGet: (() -> any)? = nil
local lastSnapshot: any = nil

-- Callbacks the sheets call, defined below (they change the view and re-render).
local close: () -> ()
local pickTrim: (trimId: string) -> ()
local requestBuy: () -> ()
local requestUpgrade: () -> ()
local requestBuyUsed: () -> ()
local testDrive: () -> ()
local openFleet: () -> ()
local claimStarter: () -> ()
local loadLot: () -> ()
local confirmPending: () -> ()
local cancelPending: () -> ()

-- Rendering ----------------------------------------------------------------------------------------------------

local function contentFor(current: View, open: Open): Primitives.Content
	if open.kind == "dealership" then
		return DealershipSheet.content({
			vehicleId = open.vehicleId,
			trimId = open.trim,
			snapshot = current.snapshot,
			cash = current.cash,
			units = current.units,
			busy = current.busy,
			testDriveSeconds = current.testDriveSeconds,
			onPickTrim = pickTrim,
			onBuy = requestBuy,
			onUpgrade = requestUpgrade,
			onTestDrive = testDrive,
			onOpenFleet = openFleet,
		})
	end
	-- The snapshot knows best whether the free starter was claimed; until it arrives, GetUsedLot's answer.
	local snapshot = current.snapshot
	local starterClaimed = if snapshot ~= nil and type(snapshot.starterClaimed) == "boolean"
		then snapshot.starterClaimed
		else open.lotStarterClaimed
	return UsedLotSheet.content({
		slot = open.slot,
		state = open.lotState,
		entry = ShopModel.lotEntry(open.lot, open.slot),
		starterClaimed = starterClaimed,
		snapshot = snapshot,
		cash = current.cash,
		units = current.units,
		busy = current.busy,
		onBuy = requestBuyUsed,
		onClaim = claimStarter,
		onRetry = loadLot,
	})
end

-- The whole tree: the root frame is sized 1/scale so that, after the UIScale, it fills the screen and the sheet
-- is laid out in unscaled (phone) pixels, like the driving HUD. The sheet is keyed by session so each newly
-- opened sheet mounts fresh and slides in.
local function App(props: { view: View, session: number })
	local current = props.view
	local open = current.open
	if open == nil then
		return nil
	end
	local pending = current.confirm
	local confirm: Primitives.Confirm? = if pending
		then {
			title = pending.title,
			rows = pending.rows,
			confirmLabel = pending.confirmLabel,
			busyLabel = pending.busyLabel,
			busy = current.busy ~= nil,
			onConfirm = confirmPending,
			onCancel = cancelPending,
		}
		else nil
	return e("Frame", {
		Size = UDim2.fromScale(1 / current.scale, 1 / current.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = current.scale }),
		[`Sheet{props.session}`] = e(ShopSheet.Sheet, {
			content = contentFor(current, open),
			layout = ShopModel.layoutFor(current.screen),
			screen = current.screen,
			confirm = confirm,
			gamepad = HudController.getInputKind() == "gamepad",
			onClose = close,
		}),
	})
end

local function render()
	if root == nil then
		return
	end
	if view.open == nil then
		root:render(nil)
		return
	end
	root:render(e(App, { view = table.clone(view), session = session }))
end

-- Profile and cash ---------------------------------------------------------------------------------------------

-- Copies the latest snapshot, cash and speed units into the view.
local function readProfile()
	local snapshot: any = lastSnapshot
	local get = profileGet
	if get ~= nil then
		local ok, result = pcall(get)
		snapshot = if ok then result else nil
	end
	view.snapshot = if type(snapshot) == "table" then snapshot else nil

	local cash: number? = nil
	if type(snapshot) == "table" and type(snapshot.cash) == "number" then
		cash = snapshot.cash
	else
		local attribute = localPlayer:GetAttribute(Economy.cashAttribute)
		cash = if type(attribute) == "number" then attribute else nil
	end
	view.cash = cash

	local settings = if type(snapshot) == "table" then snapshot.settings else nil
	view.units = if type(settings) == "table" and settings.units == "kph" then "kph" else "mph"
end

local function onProfileChanged()
	readProfile()
	if view.open ~= nil then
		render()
	end
end

-- Connects `listener` to a signal of any common kind (RBXScriptSignal, BindableEvent, or a table with a
-- Connect method, like InputController.newSignal). Returns false when it isn't one.
local function connectSignal(signal: any, listener: () -> ()): boolean
	local target: any = nil
	if typeof(signal) == "Instance" and signal:IsA("BindableEvent") then
		target = signal.Event
	elseif typeof(signal) == "RBXScriptSignal" or (type(signal) == "table" and type(signal.Connect) == "function") then
		target = signal
	end
	if target == nil then
		return false
	end
	target:Connect(listener)
	return true
end

-- Uses ProfileController (get + onChanged) when it is there; otherwise listens for ProfileSnapshot itself, so
-- the shops still know the player's cars without it.
local function watchProfile()
	local module = script.Parent:FindFirstChild(PROFILE_MODULE)
	if module ~= nil then
		local loaded, controller = pcall(require :: any, module)
		if loaded and type(controller) == "table" and type(controller.get) == "function" then
			local ok, connected = pcall(connectSignal, controller.onChanged, onProfileChanged)
			if ok and connected then
				profileGet = controller.get
				return
			end
		end
	end
	warn(`[ShopController] {PROFILE_MODULE} isn't usable; listening for {PROFILE_REMOTE} directly`)
	Net.onClientEvent(PROFILE_REMOTE, function(payload: any)
		if type(payload) == "table" then
			lastSnapshot = payload
			onProfileChanged()
		end
	end)
end

-- Opening and closing ------------------------------------------------------------------------------------------

local function unwatchPrompt()
	local watch = promptWatch
	if watch ~= nil then
		watch:Disconnect()
		promptWatch = nil
	end
	currentPrompt = nil
end

-- Closes the sheet if its prompt leaves the world (the display car was removed or restocked).
local function watchPrompt(prompt: ProximityPrompt)
	unwatchPrompt()
	currentPrompt = prompt
	promptWatch = prompt.AncestryChanged:Connect(function()
		if not prompt:IsDescendantOf(Workspace) then
			close()
		end
	end)
end

local function onCloseKey(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if view.confirm ~= nil then
		cancelPending()
	else
		close()
	end
	return Enum.ContextActionResult.Sink
end

local function bindCloseKey()
	if closeBound then
		return
	end
	closeBound = true
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		onCloseKey,
		false,
		Controls.actionPriority,
		table.unpack(Style.input.closeKeys)
	)
end

local function unbindCloseKey()
	if closeBound then
		closeBound = false
		ContextActionService:UnbindAction(CLOSE_ACTION)
	end
end

-- True while the local character sits in any seat (driver or passenger): shops don't open from a car.
local function isSeated(): boolean
	if DriveController.getCar() ~= nil then
		return true
	end
	local character = localPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil and humanoid.SeatPart ~= nil
end

local function openSheet(target: ShopModel.Target, prompt: ProximityPrompt)
	local open: Open
	if target.kind == "dealership" then
		local trim = ShopModel.initialTrim(target.vehicleId, target.trim)
		if trim == nil then
			return
		end
		open = {
			kind = "dealership",
			vehicleId = target.vehicleId,
			trim = trim,
			slot = 0,
			lotState = "ready",
			lot = nil,
			lotStarterClaimed = nil,
			lotDate = nil,
		}
	else
		open = {
			kind = "usedLot",
			vehicleId = "",
			trim = "",
			slot = target.slot,
			lotState = "loading",
			lot = nil,
			lotStarterClaimed = nil,
			lotDate = nil,
		}
	end

	session += 1
	view.open = open
	view.confirm = nil
	view.busy = nil
	reconfirmAfterLoad = false
	readProfile()
	watchPrompt(prompt)
	bindCloseKey()
	render()
	ShopController.onOpened:Fire()
	if open.kind == "usedLot" then
		loadLot()
	end
end

close = function()
	if view.open == nil then
		return
	end
	session += 1
	view.open = nil
	view.confirm = nil
	view.busy = nil
	reconfirmAfterLoad = false
	unwatchPrompt()
	unbindCloseKey()
	-- Let go of a gamepad selection inside the sheet (ShopSheet selects its buttons).
	local selected = GuiService.SelectedObject
	local gui = screenGui
	if selected ~= nil and gui ~= nil and selected:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	render()
end

-- True while a shop sheet is open (PhoneController doesn't open over one).
function ShopController.isOpen(): boolean
	return view.open ~= nil
end

-- Calls --------------------------------------------------------------------------------------------------------

-- Calls a shop remote with every button off until the answer comes back, then hands the result to `finish`
-- (`current` is false when the sheet was closed or replaced meanwhile).
local function call(
	busy: Primitives.Busy,
	remote: string,
	payload: any,
	finish: (called: boolean, reply: any, current: boolean) -> ()
)
	if view.busy ~= nil then
		return
	end
	local mine = session
	view.busy = busy
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, remote, payload)
		local current = mine == session
		if current then
			view.busy = nil
		end
		finish(called, reply, current)
		render()
	end)
end

-- A purchase-like call: the answer becomes a notice; on success the sheet closes (the server spawns the car).
local function transact(busy: Primitives.Busy, remote: string, payload: any)
	call(busy, remote, payload, function(called: boolean, reply: any, current: boolean)
		local ok, message, kind = ShopModel.outcome(called, reply)
		NotifyController.show(message, kind)
		if current then
			view.confirm = nil
			if ok then
				close()
			end
		end
	end)
end

loadLot = function()
	local open = view.open
	if open == nil or open.kind ~= "usedLot" or view.busy ~= nil then
		return
	end
	open.lotState = "loading"
	open.lot = nil
	call("loadLot", "GetUsedLot", nil, function(called: boolean, reply: any, current: boolean)
		local now = view.open
		if not current or now == nil or now.kind ~= "usedLot" then
			return
		end
		local entries: { ShopModel.LotEntry }? = nil
		local message: string? = nil
		if called then
			entries, message = ShopModel.normalizeLot(reply)
			now.lotStarterClaimed = ShopModel.lotStarterClaimed(reply)
			now.lotDate = if type(reply) == "table" and type(reply.date) == "string" then reply.date else nil
		end
		local again = reconfirmAfterLoad
		reconfirmAfterLoad = false
		if entries ~= nil then
			now.lot = entries
			now.lotState = "ready"
			if again then
				requestBuyUsed() -- the price changed: show the confirm again with the new one
			end
		else
			now.lotState = "failed"
			if message ~= nil then
				NotifyController.show(message, "error")
			end
		end
	end)
end

-- The price, cash and cash-after rows of a confirm dialog (cash rows only when the cash is known).
local function cashRows(priceLabel: string, price: number, cash: number?): { Primitives.ConfirmRow }
	local rows: { Primitives.ConfirmRow } = {
		{ label = priceLabel, value = ShopModel.cash(price) },
	}
	if cash ~= nil then
		local after = cash - price
		table.insert(rows, { label = copy.yourCash, value = ShopModel.cash(cash), tone = "dim" })
		table.insert(rows, {
			label = copy.after,
			value = ShopModel.cash(after),
			tone = if after < 0 then "warning" else "normal",
		})
	end
	return rows
end

pickTrim = function(trimId: string)
	local open = view.open
	if open == nil or open.kind ~= "dealership" or view.busy ~= nil or view.confirm ~= nil then
		return
	end
	if Catalog.getTrim(open.vehicleId, trimId) == nil or trimId == open.trim then
		return
	end
	open.trim = trimId
	render()
end

requestBuy = function()
	local open = view.open
	if open == nil or open.kind ~= "dealership" or view.busy ~= nil then
		return
	end
	local trim = Catalog.getTrim(open.vehicleId, open.trim)
	local offer = ShopModel.offer(open.vehicleId, open.trim, view.snapshot, view.cash)
	local price = offer.price
	if trim == nil or offer.kind ~= "buy" or price == nil or offer.garageFull or offer.shortBy ~= nil then
		return
	end
	view.confirm = {
		action = "buy",
		title = string.format(copy.confirmBuy, trim.displayName),
		rows = cashRows(copy.price, price, view.cash),
		confirmLabel = copy.buy,
		busyLabel = copy.buying,
		uid = nil,
	}
	render()
end

requestUpgrade = function()
	local open = view.open
	if open == nil or open.kind ~= "dealership" or view.busy ~= nil then
		return
	end
	local trim = Catalog.getTrim(open.vehicleId, open.trim)
	local offer = ShopModel.offer(open.vehicleId, open.trim, view.snapshot, view.cash)
	local price = offer.price
	if trim == nil or offer.kind ~= "upgrade" or price == nil or offer.upgradeUid == nil or offer.shortBy ~= nil then
		return
	end
	view.confirm = {
		action = "upgrade",
		title = string.format(copy.confirmUpgrade, trim.displayName),
		rows = cashRows(copy.upgradePrice, price, view.cash),
		confirmLabel = copy.upgrade,
		busyLabel = copy.upgrading,
		uid = offer.upgradeUid,
	}
	render()
end

requestBuyUsed = function()
	local open = view.open
	if open == nil or open.kind ~= "usedLot" or view.busy ~= nil then
		return
	end
	local entry = ShopModel.lotEntry(open.lot, open.slot)
	local vehicle = if entry then Catalog.getVehicle(entry.vehicleId) else nil
	if entry == nil or vehicle == nil then
		return
	end
	view.confirm = {
		action = "buyUsed",
		title = string.format(copy.confirmUsed, vehicle.displayName),
		rows = cashRows(copy.todaysPrice, entry.price, view.cash),
		confirmLabel = copy.buy,
		busyLabel = copy.buying,
		uid = nil,
	}
	render()
end

confirmPending = function()
	local pending = view.confirm
	local open = view.open
	if pending == nil or open == nil or view.busy ~= nil then
		return
	end
	if pending.action == "buy" then
		transact("buy", "BuyVehicle", { vehicleId = open.vehicleId, trim = open.trim })
	elseif pending.action == "upgrade" then
		local uid = pending.uid
		if uid ~= nil then
			transact("upgrade", "UpgradeVehicle", { uid = uid, trim = open.trim })
		end
	elseif pending.action == "buyUsed" then
		-- Sends the day and the price the confirm showed; the server never charges more than that.
		local entry = ShopModel.lotEntry(open.lot, open.slot)
		if entry == nil then
			return
		end
		local payload = { slot = open.slot, date = open.lotDate or "", maxPrice = math.max(math.floor(entry.price), 0) }
		call("buyUsed", "BuyUsed", payload, function(called: boolean, reply: any, current: boolean)
			local ok, message, kind = ShopModel.outcome(called, reply)
			local repriced = not ok and type(reply) == "table" and reply.priceChanged == true
			NotifyController.show(message, if repriced then "warning" else kind)
			if not current then
				return
			end
			view.confirm = nil
			if ok then
				close()
			elseif repriced then
				-- Fetch today's lot again, then ask again at the new price.
				reconfirmAfterLoad = true
				loadLot()
			end
		end)
	end
end

cancelPending = function()
	if view.confirm == nil or view.busy ~= nil then
		return
	end
	view.confirm = nil
	render()
end

testDrive = function()
	local open = view.open
	if open == nil or open.kind ~= "dealership" then
		return
	end
	transact("testDrive", "StartTestDrive", { vehicleId = open.vehicleId, trim = open.trim })
end

claimStarter = function()
	if view.open == nil then
		return
	end
	transact("claim", "ClaimStarter", nil)
end

-- Buy pods: pods are bought in the phone's Fleet app, so the sheet makes way for it.
openFleet = function()
	if view.open == nil or view.busy ~= nil then
		return
	end
	close()
	ShopController.onFleetRequested:Fire()
end

-- Boot ---------------------------------------------------------------------------------------------------------

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

function ShopController:Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false -- one GUI for the whole session
	gui.DisplayOrder = Theme.displayOrder.shop
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep the sheet clear of the Roblox top bar, notches and the home indicator.
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui
	screenGui = gui

	root = ReactRoblox.createRoot(gui)
	measureScreen()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if measureScreen() and view.open ~= nil then
			render()
		end
	end)

	view.testDriveSeconds = Dealership.testDrive.seconds
	watchProfile()
	readProfile()
	localPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(onProfileChanged)
	-- Switching to a gamepad selects the sheet's main button.
	HudController.onInputKindChanged:Connect(function()
		if view.open ~= nil then
			render()
		end
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= localPlayer then
			return
		end
		local target = ShopModel.targetOf(prompt)
		if target == nil or isSeated() then
			return
		end
		openSheet(target, prompt)
	end)

	-- Walking away hides the prompt; so does sitting down (DriveController switches prompts off while seated).
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		if prompt == currentPrompt then
			close()
		end
	end)

	DriveController.onDrivingChanged:Connect(function(driving: boolean)
		if driving then
			close()
		end
	end)
	localPlayer.CharacterRemoving:Connect(function()
		close()
	end)
	-- A pod ride's cutscene (Phase 9, Controllers/HailController) clears the screen.
	localPlayer:GetAttributeChangedSignal(CUTSCENE_ATTRIBUTE):Connect(function()
		if localPlayer:GetAttribute(CUTSCENE_ATTRIBUTE) == true then
			close()
		end
	end)
end

return ShopController
