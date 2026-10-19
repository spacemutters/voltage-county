--!strict
-- On-screen driving controls for touch devices (PLAN.md Phase 1). HudController shows them only while the
-- player drives on a touch screen.
--
--   left side     two steering hold zones (left and right)
--   right side    brake and gas pedals (press and hold), the handbrake above the brake
--   top right     drive mode, camera and exit buttons
--
-- Held controls write InputController.setTouchState; the buttons call InputController.trigger. Every control
-- tracks its own touches, so steering and gas work at the same time (multi-touch), and a finger that slides
-- off a pedal still releases it when it lifts. Sizes come from Config/Controls (all at least 44 px).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local InputController = require(script.Parent.Parent.Controllers.InputController)

local e = React.createElement

type Placement = {
	anchor: Vector2,
	position: UDim2,
	size: Vector2,
}

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

-- A ">" (direction 1) or "<" (direction -1) drawn from two rounded bars, so it needs no image asset.
local function Chevron(props: { direction: number, color: Color3 })
	local touch = Controls.touch
	local size = touch.chevronSize
	local thickness = touch.chevronThickness
	-- Each bar runs from an open end to the tip: half the glyph wide and half of it tall. The extra half
	-- thickness makes the two bars overlap at the tip so the joint looks solid.
	local length = size * math.sqrt(0.5) + thickness / 2
	local quarter = size / 4
	-- A vertical bar turned -45 degrees reads "\", +45 reads "/"; ">" is "\" over "/".
	local tilt = 45 * props.direction

	local function bar(offsetY: number, rotation: number)
		return e("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, offsetY),
			Size = UDim2.fromOffset(thickness, length),
			Rotation = rotation,
			BackgroundColor3 = props.color,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		})
	end

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
	}, {
		Upper = bar(-quarter, -tilt),
		Lower = bar(quarter, tilt),
	})
end

-- A control that is "held" while at least one finger (or the mouse, for Studio testing) is pressing it.
-- onHeldChanged fires only when that changes, including a final false when the control unmounts mid-press.
local function HoldButton(props: Placement & {
	label: string?,
	chevron: number?,
	onHeldChanged: (held: boolean) -> (),
})
	local theme = Controls.theme
	local held, setHeld = React.useState(false)
	local heldRef = React.useRef(false)
	-- Every input currently pressing this control, with the connection that waits for it to end.
	local presses = React.useRef({} :: { [InputObject]: RBXScriptConnection })
	local onHeldChanged = React.useRef(props.onHeldChanged)
	onHeldChanged.current = props.onHeldChanged

	local refresh = React.useCallback(function()
		local nowHeld = next(presses.current :: any) ~= nil
		if nowHeld ~= heldRef.current then
			heldRef.current = nowHeld
			setHeld(nowHeld)
			onHeldChanged.current(nowHeld)
		end
	end, {})

	local onInputBegan = React.useCallback(function(_button: GuiObject, input: InputObject)
		local current = presses.current :: { [InputObject]: RBXScriptConnection }
		if not isPress(input) or current[input] then
			return
		end
		-- Watch the input itself rather than this button, so lifting a finger that slid off still counts.
		current[input] = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
			local state = input.UserInputState
			if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				local connection = current[input]
				if connection then
					connection:Disconnect()
					current[input] = nil
				end
				refresh()
			end
		end)
		refresh()
	end, {})

	React.useEffect(function()
		return function()
			local current = presses.current :: { [InputObject]: RBXScriptConnection }
			for _, connection in current do
				connection:Disconnect()
			end
			table.clear(current)
			if heldRef.current then
				heldRef.current = false
				onHeldChanged.current(false)
			end
		end
	end, {})

	local foreground = if held then theme.onAccent else theme.text
	return e("TextButton", {
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = UDim2.fromOffset(props.size.X, props.size.Y),
		BackgroundColor3 = if held then theme.accent else theme.panel,
		BackgroundTransparency = if held then 0 else theme.panelTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Selectable = false,
		FontFace = theme.fonts.bold,
		Text = props.label or "",
		TextColor3 = foreground,
		TextSize = Controls.touch.labelTextSize,
		[React.Event.InputBegan] = onInputBegan,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Controls.touch.cornerRadius) }),
		Chevron = if props.chevron then e(Chevron, { direction = props.chevron, color = foreground }) else nil,
	})
end

-- A tap button for one-shot actions (mode, camera, exit).
local function TapButton(props: Placement & { label: string, onTap: () -> () })
	local theme = Controls.theme
	return e("TextButton", {
		AnchorPoint = props.anchor,
		Position = props.position,
		Size = UDim2.fromOffset(props.size.X, props.size.Y),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
		Selectable = false,
		FontFace = theme.fonts.medium,
		Text = props.label,
		TextColor3 = theme.text,
		TextSize = Controls.touch.labelTextSize,
		[React.Event.Activated] = function()
			props.onTap()
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Controls.touch.cornerRadius) }),
	})
end

local function TouchControls(_props: {})
	local touch = Controls.touch
	local margin, gap = touch.margin, touch.gap
	local labels = touch.labels

	-- Which steering zones are held; steering is right minus left, so holding both steers straight.
	local steering = React.useRef({ left = false, right = false })
	local function steerHeld(side: "left" | "right", held: boolean)
		local current = steering.current :: { left: boolean, right: boolean }
		current[side] = held
		InputController.setTouchState({
			steer = (if current.right then 1 else 0) - (if current.left then 1 else 0),
		})
	end

	-- Leaving the driver seat unmounts the controls: make sure nothing stays pressed.
	React.useEffect(function()
		return function()
			InputController.setTouchState({ throttle = 0, brake = 0, steer = 0, handbrake = false })
		end
	end, {})

	local pedalColumn = margin + touch.gasSize.X + gap -- right edge offset of the brake / handbrake column
	local buttonStep = touch.buttonSize.X + gap

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		SteerLeft = e(HoldButton, {
			anchor = Vector2.new(0, 1),
			position = UDim2.new(0, margin, 1, -margin),
			size = touch.steerSize,
			chevron = -1,
			onHeldChanged = function(held: boolean)
				steerHeld("left", held)
			end,
		}),
		SteerRight = e(HoldButton, {
			anchor = Vector2.new(0, 1),
			position = UDim2.new(0, margin + touch.steerSize.X + gap, 1, -margin),
			size = touch.steerSize,
			chevron = 1,
			onHeldChanged = function(held: boolean)
				steerHeld("right", held)
			end,
		}),
		Gas = e(HoldButton, {
			anchor = Vector2.new(1, 1),
			position = UDim2.new(1, -margin, 1, -margin),
			size = touch.gasSize,
			label = labels.gas,
			onHeldChanged = function(held: boolean)
				InputController.setTouchState({ throttle = if held then 1 else 0 })
			end,
		}),
		Brake = e(HoldButton, {
			anchor = Vector2.new(1, 1),
			position = UDim2.new(1, -pedalColumn, 1, -margin),
			size = touch.brakeSize,
			label = labels.brake,
			onHeldChanged = function(held: boolean)
				InputController.setTouchState({ brake = if held then 1 else 0 })
			end,
		}),
		Handbrake = e(HoldButton, {
			anchor = Vector2.new(1, 1),
			position = UDim2.new(1, -pedalColumn, 1, -(margin + touch.brakeSize.Y + gap)),
			size = touch.handbrakeSize,
			label = labels.handbrake,
			onHeldChanged = function(held: boolean)
				InputController.setTouchState({ handbrake = held })
			end,
		}),
		Exit = e(TapButton, {
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -margin, 0, margin),
			size = touch.buttonSize,
			label = labels.exit,
			onTap = function()
				InputController.trigger("exit")
			end,
		}),
		Camera = e(TapButton, {
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -(margin + buttonStep), 0, margin),
			size = touch.buttonSize,
			label = labels.camera,
			onTap = function()
				InputController.trigger("camera")
			end,
		}),
		Mode = e(TapButton, {
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, -(margin + 2 * buttonStep), 0, margin),
			size = touch.buttonSize,
			label = labels.mode,
			onTap = function()
				InputController.trigger("mode")
			end,
		}),
	})
end

return TouchControls
