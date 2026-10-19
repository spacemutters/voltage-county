--!strict
-- Driving input (docs/phase-1-contracts.md "Client"). Turns keyboard, gamepad and on-screen touch input into
-- one Types.Controls for the chassis, and raises one-shot signals for drive mode, camera, regen and exit.
--
-- Bindings go through ContextActionService (Roblox's docs don't recommend the newer input-action system over
-- it), at a priority above the default character controls, and only while the player drives: DriveController
-- calls setEnabled(true) when the player takes the Driver seat and setEnabled(false) when they leave. While
-- enabled, Space, WASD, the left stick and the gamepad jump button are sunk so they drive the car instead of
-- walking or jumping the character out of the seat, and the default touch thumbstick and jump button hide.
--
-- Keyboard and touch steering are on/off, so they ramp toward full lock and back (rates in Config/Controls);
-- gamepad triggers and the stick are analog with deadzones. setOverride (Dev/AutoDriver) beats everything.
-- Exit just stands the character up (Humanoid.Sit = false); the server sees the seat empty and parks the car.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Types = require(ReplicatedStorage.Shared.Types)

-- Signals ---------------------------------------------------------------------------------------------------

-- A minimal signal shared by the driving controllers. Listeners can attach in any of the styles the contracts
-- doc allows, and all of them land in the same list:
--   signal:Connect(fn)          returns a connection with :Disconnect()
--   signal.Event:Connect(fn)    BindableEvent style
--   table.insert(signal, fn)    plain callback list
--   signal(fn)                  same as :Connect
-- Fire runs each listener in its own thread, so one failing listener never blocks the others.
export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	[number]: (...any) -> (),
	Event: Signal,
	Connect: (self: Signal, listener: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
}

local function connectListener(signal: Signal, listener: (...any) -> ()): Connection
	table.insert(signal, listener)
	local connection = { Connected = true } :: any
	function connection.Disconnect(self: Connection)
		if not self.Connected then
			return
		end
		self.Connected = false
		local index = table.find(signal, listener)
		if index then
			table.remove(signal, index)
		end
	end
	return connection :: Connection
end

local function fireSignal(signal: Signal, ...: any)
	-- Copy the listeners first: a listener may disconnect itself (or another) while we go through them.
	local listeners: { (...any) -> () } = table.move(signal :: any, 1, #signal, 1, {})
	for _, listener in listeners do
		task.spawn(listener, ...)
	end
end

local signalMetatable = {
	__call = function(signal: Signal, listener: (...any) -> ()): Connection
		return connectListener(signal, listener)
	end,
}

local function newSignal(): Signal
	local signal = setmetatable({}, signalMetatable) :: any
	signal.Event = signal
	signal.Connect = connectListener
	signal.Fire = fireSignal
	return signal :: Signal
end

-- Types -----------------------------------------------------------------------------------------------------

-- What the on-screen touch controls are holding. steer is the target (-1 left .. 1 right); it ramps like the
-- keyboard does.
export type TouchState = {
	throttle: number,
	brake: number,
	steer: number,
	handbrake: boolean,
}

export type TouchStatePartial = {
	throttle: number?,
	brake: number?,
	steer: number?,
	handbrake: boolean?,
}

-- One-shot driving actions, from keys, gamepad buttons or the touch buttons.
export type Action = "mode" | "camera" | "regen" | "exit"

-- One entry of the HUD's key hint row.
export type HintItem = { keys: string, label: string }

type DigitalControl = "throttle" | "brake" | "steerLeft" | "steerRight" | "handbrake"

local ACTION_PREFIX = "VoltageDrive_"

local InputController = {}

InputController.onCycleMode = newSignal()
InputController.onCycleCamera = newSignal()
InputController.onCycleRegen = newSignal()
InputController.onExit = newSignal()

-- Shared with the other driving controllers (DriveController.onDrivingChanged).
InputController.newSignal = newSignal

-- State -----------------------------------------------------------------------------------------------------

local enabled = false
local override: Types.Controls? = nil

-- Keys and buttons currently held, per on/off control. Two keys on one control (W and Up) both count.
local heldKeys: { [DigitalControl]: { [Enum.KeyCode]: true } } = {
	throttle = {},
	brake = {},
	steerLeft = {},
	steerRight = {},
	handbrake = {},
}

-- Analog gamepad values, deadzones already applied.
local pad = { throttle = 0, brake = 0, steer = 0 }

local function neutralTouch(): TouchState
	return { throttle = 0, brake = 0, steer = 0, handbrake = false }
end

local touch = neutralTouch()

-- The ramped steering value for keyboard and touch, and when it was last advanced (os.clock()).
local rampedSteer = 0
local lastRampAt: number? = nil

local boundActions: { string } = {}
local whileEnabled: { RBXScriptConnection } = {}

-- What setEnabled(true) changed on the character and the touch UI, so setEnabled(false) can put it back.
local restore: { humanoid: Humanoid?, jumpWasEnabled: boolean, touchControlsWereEnabled: boolean? } = {
	humanoid = nil,
	jumpWasEnabled = true,
	touchControlsWereEnabled = nil,
}

-- Pure helpers (specs cover these) --------------------------------------------------------------------------

-- Analog value with a deadzone: zero inside it, the rest rescaled to the full range, then shaped by `curve`
-- (1 = linear). Keeps the sign.
function InputController.applyDeadzone(value: number, deadzone: number, curve: number?): number
	local magnitude = math.abs(value)
	if magnitude <= deadzone then
		return 0
	end
	local scaled = math.min((magnitude - deadzone) / (1 - deadzone), 1)
	return math.sign(value) * scaled ^ (curve or 1)
end

local function approach(value: number, target: number, maxDelta: number): number
	if value < target then
		return math.min(value + maxDelta, target)
	end
	return math.max(value - maxDelta, target)
end

-- Moves `current` toward `target` over `dt` seconds: at `returnRate` while heading back toward center and at
-- `rampRate` while heading out. Counter-steering crosses center at the return rate, then ramps out the other
-- way with whatever time is left. Never overshoots the target.
function InputController.rampSteer(
	current: number,
	target: number,
	dt: number,
	rampRate: number?,
	returnRate: number?
): number
	local outRate = rampRate or Controls.steerRamp.rampRate
	local backRate = returnRate or Controls.steerRamp.returnRate
	local remaining = math.max(dt, 0)
	local value = current

	local sameSide = math.sign(target) == math.sign(value)
	local headingBack = value ~= 0 and (not sameSide or math.abs(target) < math.abs(value))
	if headingBack then
		-- The point we head back to: the target itself when it is on this side, otherwise the center.
		local towardCenter = if sameSide then target else 0
		local timeNeeded = math.abs(value - towardCenter) / backRate
		if timeNeeded >= remaining then
			return approach(value, towardCenter, backRate * remaining)
		end
		value = towardCenter
		remaining -= timeNeeded
	end
	return approach(value, target, outRate * remaining)
end

-- Combines two control sources: the stronger pedal wins, the larger steer wins, either handbrake counts.
function InputController.merge(a: Types.Controls, b: Types.Controls): Types.Controls
	return {
		throttle = math.clamp(math.max(a.throttle, b.throttle), 0, 1),
		brake = math.clamp(math.max(a.brake, b.brake), 0, 1),
		steer = math.clamp(if math.abs(b.steer) > math.abs(a.steer) then b.steer else a.steer, -1, 1),
		handbrake = a.handbrake or b.handbrake,
	}
end

local function keyLabel(key: Enum.KeyCode, kind: "keyboard" | "gamepad"): string
	if kind == "gamepad" then
		return Controls.gamepadGlyphs[key.Name] or key.Name
	end
	return key.Name
end

-- The HUD hint row for one input kind, built from the bindings so it always shows the real keys.
function InputController.getHints(kind: "keyboard" | "gamepad"): { HintItem }
	local bindings: { [string]: { Enum.KeyCode } } = if kind == "keyboard"
		then Controls.keyboard :: any
		else Controls.gamepad :: any
	local items: { HintItem } = {}
	for _, hint in Controls.hints[kind] do
		local names: { string } = {}
		for _, action in hint.actions do
			local keys = bindings[action]
			if keys and keys[1] then
				table.insert(names, keyLabel(keys[1], kind))
			end
		end
		if #names > 0 then
			table.insert(items, { keys = table.concat(names, "/"), label = hint.label })
		end
	end
	return items
end

-- Reading input ---------------------------------------------------------------------------------------------

local function isHeld(control: DigitalControl): boolean
	return next(heldKeys[control]) ~= nil
end

local function axis(control: DigitalControl): number
	return if isHeld(control) then 1 else 0
end

-- Drops held keys and gamepad values (touches are tracked by the touch UI itself).
local function clearKeysAndPad()
	for _, keys in heldKeys do
		table.clear(keys)
	end
	pad.throttle, pad.brake, pad.steer = 0, 0, 0
end

local function clearInputs()
	clearKeysAndPad()
	touch = neutralTouch()
	rampedSteer = 0
	lastRampAt = nil
end

-- The controls for this frame. DriveController calls it every PreSimulation; other callers (camera, HUD) may
-- call it too, which only advances the steering ramp by the time since the last call.
function InputController.getControls(): Types.Controls
	if override then
		return table.clone(override)
	end

	local now = os.clock()
	local dt = if lastRampAt then math.min(now - lastRampAt, Controls.steerRamp.maxStep) else 0
	lastRampAt = now
	local steerTarget = math.clamp(axis("steerRight") - axis("steerLeft") + touch.steer, -1, 1)
	rampedSteer = InputController.rampSteer(rampedSteer, steerTarget, dt)

	local onOff: Types.Controls = {
		throttle = math.max(axis("throttle"), touch.throttle),
		brake = math.max(axis("brake"), touch.brake),
		steer = rampedSteer,
		handbrake = isHeld("handbrake") or touch.handbrake,
	}
	local analog: Types.Controls = {
		throttle = pad.throttle,
		brake = pad.brake,
		steer = pad.steer,
		handbrake = false,
	}
	return InputController.merge(onOff, analog)
end

-- AutoDriver (Studio only) drives through this; while set it wins over every input. nil hands control back.
function InputController.setOverride(controls: Types.Controls?)
	override = if controls then table.clone(controls) else nil
end

-- Called by UI/TouchControls with only the fields that changed.
function InputController.setTouchState(partial: TouchStatePartial)
	if partial.throttle ~= nil then
		touch.throttle = math.clamp(partial.throttle, 0, 1)
	end
	if partial.brake ~= nil then
		touch.brake = math.clamp(partial.brake, 0, 1)
	end
	if partial.steer ~= nil then
		touch.steer = math.clamp(partial.steer, -1, 1)
	end
	if partial.handbrake ~= nil then
		touch.handbrake = partial.handbrake
	end
end

local function localHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- Runs a one-shot action (keys, gamepad buttons and the touch buttons all end up here). Ignored when the
-- player isn't driving.
function InputController.trigger(action: Action)
	if not enabled then
		return
	end
	if action == "mode" then
		InputController.onCycleMode:Fire()
	elseif action == "camera" then
		InputController.onCycleCamera:Fire()
	elseif action == "regen" then
		InputController.onCycleRegen:Fire()
	elseif action == "exit" then
		InputController.onExit:Fire()
		-- Deferred so the seat change (and the unbinding it causes) happens outside the input callback.
		task.defer(function()
			local humanoid = localHumanoid()
			if humanoid and humanoid.SeatPart then
				humanoid.Sit = false
			end
		end)
	end
end

-- Binding ---------------------------------------------------------------------------------------------------

local SINK = Enum.ContextActionResult.Sink

type ActionHandler = (actionName: string, state: Enum.UserInputState, input: InputObject) -> Enum.ContextActionResult

local function isRelease(state: Enum.UserInputState): boolean
	return state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
end

local function onOffHandler(control: DigitalControl): ActionHandler
	return function(_actionName, state, input)
		if state == Enum.UserInputState.Begin then
			heldKeys[control][input.KeyCode] = true
		elseif isRelease(state) then
			heldKeys[control][input.KeyCode] = nil
		end
		return SINK
	end
end

local function triggerHandler(control: "throttle" | "brake"): ActionHandler
	return function(_actionName, state, input)
		pad[control] = if isRelease(state)
			then 0
			else InputController.applyDeadzone(input.Position.Z, Controls.deadzones.trigger)
		return SINK
	end
end

local function onStick(_actionName: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	pad.steer = if isRelease(state)
		then 0
		else InputController.applyDeadzone(input.Position.X, Controls.deadzones.stick, Controls.stickSteerCurve)
	return SINK
end

local function pressHandler(action: Action): ActionHandler
	return function(_actionName, state, _input)
		if state == Enum.UserInputState.Begin then
			InputController.trigger(action)
		end
		return SINK
	end
end

local function sinkOnly(_actionName: string, _state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	return SINK
end

local function bind(name: string, handler: ActionHandler, ...: { Enum.KeyCode })
	local keys: { Enum.KeyCode } = {}
	for _, list in { ... } do
		table.move(list, 1, #list, #keys + 1, keys)
	end
	if #keys == 0 then
		return
	end
	local actionName = ACTION_PREFIX .. name
	ContextActionService:BindActionAtPriority(actionName, handler, false, Controls.actionPriority, table.unpack(keys))
	table.insert(boundActions, actionName)
end

local function bindAll()
	local keyboard, gamepad = Controls.keyboard, Controls.gamepad
	bind("Throttle", onOffHandler("throttle"), keyboard.throttle)
	bind("Brake", onOffHandler("brake"), keyboard.brake)
	bind("SteerLeft", onOffHandler("steerLeft"), keyboard.steerLeft)
	bind("SteerRight", onOffHandler("steerRight"), keyboard.steerRight)
	bind("Handbrake", onOffHandler("handbrake"), keyboard.handbrake, gamepad.handbrake)
	bind("PadThrottle", triggerHandler("throttle"), gamepad.throttle)
	bind("PadBrake", triggerHandler("brake"), gamepad.brake)
	bind("PadSteer", onStick, gamepad.steer)
	bind("Exit", pressHandler("exit"), keyboard.exit, gamepad.exit)
	bind("Mode", pressHandler("mode"), keyboard.mode, gamepad.mode)
	bind("Camera", pressHandler("camera"), keyboard.camera, gamepad.camera)
	bind("Regen", pressHandler("regen"), keyboard.regen, gamepad.regen)
	bind("Sink", sinkOnly, gamepad.sink)

	-- Keys held while the window loses focus (or chat opens) never report their release: drop them so the
	-- car doesn't keep accelerating on its own.
	table.insert(whileEnabled, UserInputService.WindowFocusReleased:Connect(clearKeysAndPad))
	table.insert(whileEnabled, UserInputService.TextBoxFocused:Connect(clearKeysAndPad))
	table.insert(
		whileEnabled,
		UserInputService.GamepadDisconnected:Connect(function()
			pad.throttle, pad.brake, pad.steer = 0, 0, 0
		end)
	)
end

local function unbindAll()
	for _, actionName in boundActions do
		ContextActionService:UnbindAction(actionName)
	end
	table.clear(boundActions)
	for _, connection in whileEnabled do
		connection:Disconnect()
	end
	table.clear(whileEnabled)
end

-- While driving: the character can't jump (that would stand it up out of the seat; this also hides the touch
-- jump button), and the default touch thumbstick hides behind our own controls.
local function holdCharacter()
	local humanoid = localHumanoid()
	restore.humanoid = humanoid
	if humanoid then
		restore.jumpWasEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end
	if UserInputService.TouchEnabled then
		restore.touchControlsWereEnabled = GuiService.TouchControlsEnabled
		GuiService.TouchControlsEnabled = false
	end
end

local function releaseCharacter()
	local humanoid = restore.humanoid
	if humanoid and humanoid.Parent then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, restore.jumpWasEnabled)
	end
	restore.humanoid = nil
	if restore.touchControlsWereEnabled ~= nil then
		GuiService.TouchControlsEnabled = restore.touchControlsWereEnabled
		restore.touchControlsWereEnabled = nil
	end
end

-- DriveController turns driving input on when the player takes the Driver seat and off when they leave it.
function InputController.setEnabled(on: boolean)
	if on == enabled then
		return
	end
	enabled = on
	clearInputs()
	if on then
		bindAll()
		holdCharacter()
	else
		unbindAll()
		releaseCharacter()
	end
end

function InputController.isEnabled(): boolean
	return enabled
end

return InputController
