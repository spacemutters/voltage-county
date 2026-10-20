--!strict
-- Owns the one HUD ScreenGui (docs/phase-1-contracts.md "Client") and renders it with react-lua: the HUD
-- (UI/Hud: the player's cash and active job at all times, the speed panel with its energy row while they
-- drive), on touch screens the touch controls (UI/TouchControls) while the player drives, and the dev spawn
-- menu (UI/DevSpawnMenu) in Studio. Since Phase 4 codes live in the phone (PhoneController), which draws its
-- own button beside the speed panel.
--
-- Telemetry is read from DriveController about 10 times a second (Heartbeat plus an accumulator, connected
-- only while driving), and the tree re-renders only when a shown value changes. Speed shows in the player's
-- units (mph or km/h) from ProfileController. Cash comes from the player's `Cash` attribute, which the server
-- sets (Config/Economy cashAttribute). The UI is laid out at a landscape phone's size and scaled up on bigger
-- screens by one UIScale; it never scales down, so touch targets keep their 44 px minimum.
--
-- Other controllers read which controls the player is using from here (getInputKind, onInputKindChanged), so
-- the HUD, the touch controls and the phone always agree.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local DriveController = require(script.Parent.DriveController)
local InputController = require(script.Parent.InputController)
local ProfileController = require(script.Parent.ProfileController)

local UI = script.Parent.Parent.UI
local DevSpawnMenu = require(UI.DevSpawnMenu)
local Hud = require(UI.Hud)
local PhoneConfig = require(UI.Phone.PhoneConfig)
local Theme = require(UI.Theme)
local TouchControls = require(UI.TouchControls)

local GUI_NAME = "DrivingHud"

-- The Studio spawn menu (which places itself in the top-left corner) is pushed down below the cash readout
-- and the active-job slot.
local DEV_MENU_TOP = Controls.touch.margin
	+ Economy.hud.rowHeight
	+ Economy.hud.gap
	+ PhoneConfig.hud.jobSlot.size.Y
	+ Economy.hud.gap

export type InputKind = "keyboard" | "gamepad" | "touch"
export type ActiveJob = Hud.ActiveJob

-- Everything the tree shows. render() hands a copy to the App component.
type View = {
	driving: boolean,
	speed: number, -- rounded, in the player's units
	units: string, -- "mph" | "kph"
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	energy: Hud.Energy?,
	inputKind: InputKind,
	hints: { InputController.HintItem }?,
	scale: number,
	showDevMenu: boolean,
	cash: number?, -- nil until the player's data has loaded
	job: ActiveJob?,
}

local e = React.createElement

local HudController = {}

-- Fires (kind: InputKind) when the player switches between keyboard, gamepad and touch.
HudController.onInputKindChanged = InputController.newSignal()

local view: View = {
	driving = false,
	speed = 0,
	units = ProfileController.defaultSettings().units,
	gear = "P",
	mode = Controls.defaultMode,
	regen = Controls.defaultRegen,
	energy = nil,
	inputKind = "keyboard",
	hints = nil,
	scale = 1,
	showDevMenu = false,
	cash = nil,
	job = nil,
}

local root: any = nil
local ticker: RBXScriptConnection? = nil
local lastMph = 0 -- the latest telemetry speed, so a units switch redraws at once

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
			speed = props.speed,
			unitLabel = PhoneConfig.hud.unitLabels[props.units] or props.units,
			gear = props.gear,
			mode = props.mode,
			regen = props.regen,
			energy = props.energy,
			hints = props.hints,
			cash = props.cash,
			job = props.job,
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

-- Pure helpers (tests/Phone.spec and tests/DriveClient.spec) -------------------------------------------------

-- UI scale for a screen: the short side against the phone the UI was laid out for, never below 1.
function HudController.scaleFor(screenSize: Vector2): number
	local shortSide = math.min(screenSize.X, screenSize.Y)
	if shortSide <= 0 then
		return 1
	end
	local scale = math.clamp(shortSide / Controls.hud.referenceShortSide, 1, Controls.hud.maxScale)
	return math.round(scale * 100) / 100 -- tiny window resizes don't re-render the tree
end

-- The speed the HUD shows for a telemetry speed in mph, in the player's units ("mph" or "kph"), rounded.
function HudController.speedFor(mph: number, units: string): number
	local absolute = math.abs(mph)
	if units == "kph" then
		return math.round(Units.studsToKph(Units.mphToStuds(absolute)))
	end
	return math.round(absolute)
end

-- The HUD hint row for keyboard or gamepad: the driving keys, then the phone key.
function HudController.hintsFor(kind: "keyboard" | "gamepad"): { InputController.HintItem }
	local hints = InputController.getHints(kind)
	table.insert(hints, { keys = PhoneConfig.keyGlyphs[kind], label = PhoneConfig.hud.phoneHint })
	return hints
end

-- Input kind -------------------------------------------------------------------------------------------------

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
	view.hints = if kind == "touch" then nil else HudController.hintsFor(kind)
end

-- The controls the player is using right now ("keyboard", "gamepad" or "touch").
function HudController.getInputKind(): InputKind
	return view.inputKind
end

-- Active job (Phase 6) -------------------------------------------------------------------------------------------

-- Shows a job in the slot under the cash, or empties it (nil). For Phase 6's job controller.
function HudController.setActiveJob(job: ActiveJob?)
	view.job = if job then table.clone(job) else nil
	render()
end

-- Driving ----------------------------------------------------------------------------------------------------

-- The car's energy kind from the catalog. The level stays nil until Phase 5 tracks energy.
local function energyOf(car: Model?): Hud.Energy?
	local vehicleId = if car then car:GetAttribute("VehicleId") else nil
	local vehicle = if type(vehicleId) == "string" then Catalog.getVehicle(vehicleId) else nil
	if vehicle == nil then
		return nil
	end
	return { kind = vehicle.energy, level = nil }
end

-- Copies the telemetry into the view; re-renders only if something shown changed.
local function refreshTelemetry()
	local telemetry = DriveController.getTelemetry()
	if telemetry == nil then
		return
	end
	lastMph = telemetry.mph
	local speed = HudController.speedFor(telemetry.mph, view.units)
	if
		speed == view.speed
		and telemetry.gear == view.gear
		and telemetry.mode == view.mode
		and telemetry.regen == view.regen
	then
		return
	end
	view.speed = speed
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

local function onDrivingChanged(driving: boolean, car: Model?)
	view.driving = driving
	if driving then
		view.mode = DriveController.getMode()
		view.regen = DriveController.getRegen()
		view.energy = energyOf(car or DriveController.getCar())
		startTicker()
	else
		view.energy = nil
		stopTicker()
	end
	render()
end

-- Cash and units ---------------------------------------------------------------------------------------------

local function readCash()
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	view.cash = if type(value) == "number" then value else nil
end

local function onProfileChanged()
	local units = ProfileController.settings().units
	if units ~= view.units then
		view.units = units
		view.speed = HudController.speedFor(lastMph, units)
		render()
	end
end

function HudController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	-- One GUI for the whole session: what it shows follows DriveController, not the character.
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.displayOrder.hud
	-- Keep every control clear of the Roblox top bar, notches and the home indicator.
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.Parent = playerGui

	root = ReactRoblox.createRoot(screenGui)
	view.showDevMenu = RunService:IsStudio()
	view.scale = HudController.scaleFor(screenGui.AbsoluteSize)
	setInputKind(kindFor(UserInputService:GetLastInputType()) or deviceKind())
	-- Controllers that started before this one (the phone) hear the first guess too.
	HudController.onInputKindChanged:Fire(view.inputKind)

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
			setInputKind(kind :: InputKind)
			render()
			HudController.onInputKindChanged:Fire(kind)
		end
	end)

	-- The server sets Cash once the player's data loads and whenever it changes.
	readCash()
	Players.LocalPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
		readCash()
		render()
	end)

	ProfileController.onChanged:Connect(onProfileChanged)
	onProfileChanged()

	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	if DriveController.getCar() then
		onDrivingChanged(true, DriveController.getCar())
	else
		render()
	end
end

return HudController
