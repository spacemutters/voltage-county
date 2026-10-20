--!strict
-- Owns the one HUD ScreenGui (docs/phase-1-contracts.md "Client") and renders it with react-lua: the HUD
-- (UI/Hud: the player's cash and the Codes entry at all times, the driving panel while they drive), on touch
-- screens the touch controls (UI/TouchControls) while the player drives, and the dev spawn menu
-- (UI/DevSpawnMenu) in Studio.
--
-- Telemetry is read from DriveController about 10 times a second (Heartbeat plus an accumulator, connected
-- only while driving), and the tree re-renders only when a shown value changes. Cash comes from the player's
-- `Cash` attribute, which the server sets (Config/Economy cashAttribute); the tree re-renders when it changes.
-- Codes are sent to the server with Net "RedeemCode" and the answer is shown as a notice (NotifyController).
-- The UI is laid out at a landscape phone's size and scaled up on bigger screens by one UIScale; it never
-- scales down, so touch targets keep their 44 px minimum.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local DriveController = require(script.Parent.DriveController)
local InputController = require(script.Parent.InputController)

local UI = script.Parent.Parent.UI
local DevSpawnMenu = require(UI.DevSpawnMenu)
local Hud = require(UI.Hud)
local TouchControls = require(UI.TouchControls)

local GUI_NAME = "DrivingHud"
local REDEEM_REMOTE = "RedeemCode"
local NOTIFY_MODULE = "NotifyController"

-- The Studio spawn menu (which places itself in the top-left corner) is pushed down below the cash readout
-- and the Codes button.
local DEV_MENU_TOP = Controls.touch.margin + 2 * Economy.hud.rowHeight + Economy.hud.gap

type InputKind = "keyboard" | "gamepad" | "touch"

-- Everything the tree shows. render() hands a copy to the App component.
type View = {
	driving: boolean,
	mph: number,
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	inputKind: InputKind,
	hints: { InputController.HintItem }?,
	scale: number,
	showDevMenu: boolean,
	cash: number?, -- nil until the player's data has loaded
	codesOpen: boolean,
	redeeming: boolean, -- a RedeemCode request is waiting for the server
}

type ShowNotice = (text: string, kind: string?) -> ()

local e = React.createElement

local HudController = {}

local view: View = {
	driving = false,
	mph = 0,
	gear = "P",
	mode = Controls.defaultMode,
	regen = Controls.defaultRegen,
	inputKind = "keyboard",
	hints = nil,
	scale = 1,
	showDevMenu = false,
	cash = nil,
	codesOpen = false,
	redeeming = false,
}

local root: any = nil
local ticker: RBXScriptConnection? = nil

-- NotifyController requires this module, so it is looked up in Start (once both have loaded) instead of at
-- the top, which would be a require cycle. Until then notices go nowhere.
local showNotice: ShowNotice = function(_text: string, _kind: string?) end

-- Code entry callbacks for the HUD, defined below (they re-render the tree).
local toggleCodes: () -> ()
local closeCodes: () -> ()
local redeemCode: (text: string) -> ()

-- The whole tree. The root frame is sized 1/scale so that, after the UIScale, it exactly fills the screen
-- and every child can be laid out in unscaled (phone) pixels.
local function App(props: View)
	return e("Frame", {
		Size = UDim2.fromScale(1 / props.scale, 1 / props.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = props.scale }),
		Hud = e(Hud, {
			driving = props.driving,
			mph = props.mph,
			gear = props.gear,
			mode = props.mode,
			regen = props.regen,
			hints = props.hints,
			cash = props.cash,
			codesOpen = props.codesOpen,
			redeeming = props.redeeming,
			onToggleCodes = toggleCodes,
			onCloseCodes = closeCodes,
			onRedeem = redeemCode,
		}),
		TouchControls = if props.driving and props.inputKind == "touch" then e(TouchControls, {}) else nil,
		DevSpawnMenu = if props.showDevMenu
			then e("Frame", {
				Position = UDim2.fromOffset(0, DEV_MENU_TOP),
				Size = UDim2.new(1, 0, 1, -DEV_MENU_TOP),
				BackgroundTransparency = 1,
			}, {
				Menu = e(DevSpawnMenu, {}),
			})
			else nil,
	})
end

local function render()
	if root then
		root:render(e(App, table.clone(view)))
	end
end

-- Cash and codes ---------------------------------------------------------------------------------------------

local function readCash()
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	view.cash = if type(value) == "number" then value else nil
end

toggleCodes = function()
	view.codesOpen = not view.codesOpen
	render()
end

closeCodes = function()
	view.codesOpen = false
	render()
end

-- Sends the typed code to the server (which decides everything) and shows its answer as a notice. Closes the
-- sheet when the code worked; leaves it open (with the text) when it didn't, so a typo can be fixed.
redeemCode = function(text: string)
	if view.redeeming then
		return
	end
	local messages = Economy.codes.messages
	local code = string.match(text, "^%s*(.-)%s*$") or ""
	if code == "" then
		showNotice(messages.empty, "warning")
		return
	elseif #code > Economy.codes.maxLength then
		showNotice(messages.unknown, "error") -- no code is that long; the server would refuse to read it
		return
	end

	view.redeeming = true
	render()
	task.spawn(function()
		local ok, reply = pcall(Net.invokeServer, REDEEM_REMOTE, code)
		view.redeeming = false
		if not ok then
			showNotice(messages.failed, "error")
		elseif type(reply) == "table" and type(reply.message) == "string" then
			local redeemed = reply.ok == true
			if redeemed then
				view.codesOpen = false
			end
			showNotice(reply.message, if redeemed then "success" else "error")
		else
			-- No answer: Net turned the request away (too many tries in a row).
			showNotice(messages.tryLater, "warning")
		end
		render()
	end)
end

-- UI scale for a screen: the short side against the phone the UI was laid out for, never below 1.
function HudController.scaleFor(screenSize: Vector2): number
	local shortSide = math.min(screenSize.X, screenSize.Y)
	if shortSide <= 0 then
		return 1
	end
	local scale = math.clamp(shortSide / Controls.hud.referenceShortSide, 1, Controls.hud.maxScale)
	return math.round(scale * 100) / 100 -- tiny window resizes don't re-render the tree
end

-- Which controls the player is using, from the last input type (nil: an input that says nothing about it).
local function kindFor(inputType: Enum.UserInputType): InputKind?
	if inputType == Enum.UserInputType.Touch then
		return if UserInputService.TouchEnabled then "touch" else nil
	elseif string.sub(inputType.Name, 1, #"Gamepad") == "Gamepad" then
		return "gamepad"
	elseif
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseWheel
	then
		return "keyboard"
	end
	return nil
end

-- Before any input arrives, guess from the device.
local function deviceKind(): InputKind
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "gamepad"
	end
	return "keyboard"
end

local function setInputKind(kind: InputKind)
	view.inputKind = kind
	view.hints = if kind == "touch" then nil else InputController.getHints(kind)
end

-- Copies the telemetry into the view; re-renders only if something shown changed.
local function refreshTelemetry()
	local telemetry = DriveController.getTelemetry()
	if telemetry == nil then
		return
	end
	local mph = math.round(telemetry.mph)
	if
		mph == view.mph
		and telemetry.gear == view.gear
		and telemetry.mode == view.mode
		and telemetry.regen == view.regen
	then
		return
	end
	view.mph = mph
	view.gear = telemetry.gear
	view.mode = telemetry.mode
	view.regen = telemetry.regen
	render()
end

local function startTicker()
	if ticker then
		return
	end
	local interval = 1 / Controls.hud.refreshHz
	local elapsed = interval -- refresh on the first frame
	ticker = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			refreshTelemetry()
		end
	end)
end

local function stopTicker()
	if ticker then
		ticker:Disconnect()
		ticker = nil
	end
end

local function onDrivingChanged(driving: boolean)
	view.driving = driving
	if driving then
		view.mode = DriveController.getMode()
		view.regen = DriveController.getRegen()
		startTicker()
	else
		stopTicker()
	end
	render()
end

function HudController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	-- One GUI for the whole session: what it shows follows DriveController, not the character.
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep every control clear of the Roblox top bar, notches and the home indicator.
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.Parent = playerGui

	root = ReactRoblox.createRoot(screenGui)
	view.showDevMenu = RunService:IsStudio()
	view.scale = HudController.scaleFor(screenGui.AbsoluteSize)
	setInputKind(kindFor(UserInputService:GetLastInputType()) or deviceKind())

	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local scale = HudController.scaleFor(screenGui.AbsoluteSize)
		if scale ~= view.scale then
			view.scale = scale
			render()
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
		local kind = kindFor(inputType)
		if kind and kind ~= view.inputKind then
			setInputKind(kind)
			render()
		end
	end)

	-- Every controller has loaded by now, so this is not a require cycle (see showNotice above). If notices are
	-- broken, the rest of the HUD still works.
	local notifyModule = script.Parent:FindFirstChild(NOTIFY_MODULE)
	local loaded, NotifyController = pcall(require :: any, notifyModule)
	if loaded and type(NotifyController) == "table" and type(NotifyController.show) == "function" then
		showNotice = NotifyController.show
	else
		warn(`[HudController] Code answers can't be shown: {NOTIFY_MODULE} didn't load`)
	end

	-- The server sets Cash once the player's data loads and whenever it changes.
	readCash()
	Players.LocalPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
		readCash()
		render()
	end)

	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	if DriveController.getCar() then
		onDrivingChanged(true)
	else
		render()
	end
end

return HudController
