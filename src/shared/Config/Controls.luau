--!strict
-- Driving controls and the driving HUD (PLAN.md Phase 1, docs/phase-1-contracts.md "Client").
-- Read by Controllers/InputController (bindings, deadzones, steering ramp), DriveController (drive-mode and
-- regen cycles, lamps), VehicleVisualsController (other players' cars), HudController and the UI components
-- (layout, touch sizes, theme, copy), and the controllers that bind their own keys only while they apply
-- (HitchInputController's hitch, AbilityController's ability).
--
-- GUI sizes are in pixels at UI scale 1, which is a landscape phone (`hud.referenceShortSide`). HudController
-- only ever scales the UI up from there, never down, so every touch target stays at least `touch.minTarget`.

local Types = require(script.Parent.Parent.Types)

-- Each driving action is bound to a list of keys; the first key is the one the HUD hint row shows.
export type KeyboardBindings = {
	throttle: { Enum.KeyCode },
	brake: { Enum.KeyCode }, -- held at a standstill it reverses (Vehicle/Powertrain)
	steerLeft: { Enum.KeyCode },
	steerRight: { Enum.KeyCode },
	handbrake: { Enum.KeyCode },
	exit: { Enum.KeyCode },
	mode: { Enum.KeyCode },
	camera: { Enum.KeyCode },
	regen: { Enum.KeyCode },
	hitch: { Enum.KeyCode }, -- couple / uncouple a trailer or towed car (Controllers/HitchInputController)
	ability: { Enum.KeyCode }, -- the Arc's boost-hop or flight (Controllers/AbilityController)
}

export type GamepadBindings = {
	throttle: { Enum.KeyCode }, -- analog trigger: InputObject.Position.Z runs 0..1
	brake: { Enum.KeyCode }, -- analog trigger
	steer: { Enum.KeyCode }, -- thumbstick: InputObject.Position.X runs -1..1
	handbrake: { Enum.KeyCode },
	exit: { Enum.KeyCode },
	mode: { Enum.KeyCode },
	camera: { Enum.KeyCode },
	regen: { Enum.KeyCode },
	hitch: { Enum.KeyCode }, -- couple / uncouple (Controllers/HitchInputController)
	ability: { Enum.KeyCode }, -- boost-hop or flight (Controllers/AbilityController)
	-- Swallowed while driving and otherwise ignored: the default gamepad jump would stand the driver up.
	sink: { Enum.KeyCode },
}

-- One entry in the HUD's key hint row: the first key of each listed action, then the label.
export type Hint = { actions: { string }, label: string }

local FONT_FAMILY = "rbxasset://fonts/families/BuilderSans.json"

local Controls = {
	-- ContextActionService priority for every driving binding. The default character controls bind at
	-- Medium, so High wins: while driving, Space, WASD and the left stick drive the car instead of jumping
	-- or walking the character.
	actionPriority = Enum.ContextActionPriority.High.Value,

	keyboard = {
		throttle = { Enum.KeyCode.W, Enum.KeyCode.Up },
		brake = { Enum.KeyCode.S, Enum.KeyCode.Down },
		steerLeft = { Enum.KeyCode.A, Enum.KeyCode.Left },
		steerRight = { Enum.KeyCode.D, Enum.KeyCode.Right },
		handbrake = { Enum.KeyCode.Space },
		exit = { Enum.KeyCode.F },
		mode = { Enum.KeyCode.M },
		camera = { Enum.KeyCode.C },
		regen = { Enum.KeyCode.R },
		-- Phase 8: bound by HitchInputController (not InputController) and only while driving a car with a hitch
		-- (a Kingpin or TowHitch attachment), so T stays free on foot.
		hitch = { Enum.KeyCode.T },
		-- Phase 10: bound by AbilityController (not InputController) and only while driving a car whose trim has a
		-- thruster ability (Config/Abilities.byTrim), so Q stays free on foot.
		ability = { Enum.KeyCode.Q },
	} :: KeyboardBindings,

	gamepad = {
		throttle = { Enum.KeyCode.ButtonR2 },
		brake = { Enum.KeyCode.ButtonL2 },
		steer = { Enum.KeyCode.Thumbstick1 },
		handbrake = { Enum.KeyCode.ButtonX },
		exit = { Enum.KeyCode.ButtonB },
		mode = { Enum.KeyCode.ButtonY },
		camera = { Enum.KeyCode.ButtonR3 },
		regen = { Enum.KeyCode.DPadUp },
		-- Phase 8, bound like the keyboard's T. ButtonR1 was free: the triggers, X, Y, B, R3, D-pad up and A drive,
		-- and the phone has ButtonL1 (UI/Phone/PhoneConfig keys).
		hitch = { Enum.KeyCode.ButtonR1 },
		-- Phase 10, bound like the keyboard's Q. Clicking the left stick (L3) was free and stays under the thumb that
		-- steers: the triggers, X, Y, B, R3, D-pad up, A and RB drive, LB opens the phone, and A also opens the
		-- Customize shop in a bay (UI/Customize/Style).
		ability = { Enum.KeyCode.ButtonL3 },
		sink = { Enum.KeyCode.ButtonA },
	} :: GamepadBindings,

	-- How gamepad keys are written in the hint row (anything missing shows its KeyCode name).
	gamepadGlyphs = {
		ButtonR2 = "RT",
		ButtonL2 = "LT",
		Thumbstick1 = "Left stick",
		ButtonX = "X",
		ButtonY = "Y",
		ButtonB = "B",
		ButtonR3 = "R3",
		DPadUp = "D-pad up",
		ButtonR1 = "RB",
		ButtonL3 = "L3",
	} :: { [string]: string },

	-- Analog input below these magnitudes reads as zero; the rest is rescaled to the full 0..1 range.
	deadzones = {
		stick = 0.15,
		trigger = 0.06,
	},
	-- Stick steering response curve: output = input ^ curve after the deadzone. Above 1 gives finer control
	-- near the center without reducing full lock.
	stickSteerCurve = 1.4,

	-- Keyboard and touch steering are on/off, so the steer value ramps toward full lock and back.
	steerRamp = {
		rampRate = 3.5, -- steer units per second moving away from center (full lock in about 0.29 s)
		returnRate = 6, -- steer units per second moving back toward center (snappier than steering in)
		maxStep = 0.1, -- longest time step one ramp update may take, in seconds (after a hitch or a pause)
	},

	-- Drive mode and regen level cycles (M / ButtonY and R / D-pad up). The first entry follows the last.
	modeCycle = { "comfort", "standard", "sport" } :: { Types.DriveMode },
	regenCycle = { "low", "standard", "high" } :: { Types.RegenLevel },
	defaultMode = "standard" :: Types.DriveMode,
	defaultRegen = "standard" :: Types.RegenLevel,

	-- With streaming on, the Driver seat can reach this client a moment before the rest of the car. Driving
	-- starts once the car's Chassis and four wheels have arrived, waiting at most this many seconds.
	carReadyTimeout = 5,

	-- The local car's own brake and reverse lamps (Lights/Brake and Lights/Reverse in the model contract).
	lamps = {
		pedalThreshold = 0.1, -- pedal travel (0..1) that counts as braking
		onMaterial = Enum.Material.Neon, -- a lit lamp part glows; the part's own material returns when off
	},

	-- Other players' cars, animated on this client by VehicleVisualsController.
	otherCars = {
		maxDistance = 400, -- studs from the camera; cars farther away are not animated
		retryDelay = 2, -- seconds before retrying a car whose wheels could not be set up (still streaming in)
		parkedSettleTime = 0.5, -- seconds a parked (anchored) car's wheels keep updating before they rest
		brakeLight = {
			-- Replicated speed is the only signal we have, so brake lamps follow the car's deceleration:
			-- lit above `onDecel` and unlit below `offDecel` (studs/s^2), with a short hold so they don't
			-- flicker. Coasting and light regen slow a car by well under `offDecel`.
			onDecel = 14,
			offDecel = 7,
			filterTime = 0.12, -- seconds; low-pass filter on the measured deceleration (network jitter)
			confirmTime = 0.08, -- seconds the deceleration must stay above onDecel before the lamp lights
			minOnTime = 0.3, -- seconds a lit lamp stays lit at least
			minSpeed = 3, -- studs/s; slower cars never light up (a parked car settling)
		},
	},

	-- The driving HUD (UI/Hud), drawn by HudController.
	hud = {
		refreshHz = 10, -- telemetry reads per second while driving
		-- The UI is laid out for this screen short side (a landscape phone) and scales up with bigger screens,
		-- to at most maxScale; it never scales down.
		referenceShortSide = 390,
		maxScale = 1.25,
		margin = 16, -- from the safe-area edge
		gap = 8,
		clusterSize = Vector2.new(220, 80), -- the speed / gear / mode panel, bottom center
		clusterPadding = 12,
		gearSize = 38,
		gearTextSize = 22,
		gearCornerRadius = 10,
		speedWidth = 92,
		speedTextSize = 44,
		unitTextSize = 13,
		sideLabelWidth = 72, -- drive mode and regen labels, right side of the panel
		modeTextSize = 14,
		smallTextSize = 12,
		hintHeight = 28,
		hintTextSize = 13,
		hintSpacing = "    ", -- between hint entries
		cornerRadius = 14,
		unitLabel = "mph",
		modeLabels = {
			comfort = "Comfort",
			standard = "Standard",
			sport = "Sport",
		} :: { [Types.DriveMode]: string },
		regenLabels = {
			low = "Regen low",
			standard = "Regen normal",
			high = "Regen high",
		} :: { [Types.RegenLevel]: string },
		-- Phase 10: the ability chip (UI/Hud), in the hitch row's place under the cash column while driving a car
		-- with a thruster ability: a ring that fills as the ability recharges, what a press does now and whether
		-- it is ready, with its key cap on keyboard and gamepad. Controllers/AbilityController works out what it
		-- shows. As tall as a button (Theme.size.buttonHeight).
		abilityChip = {
			width = 136,
			padding = 7, -- inside the chip, left of the ring
			ringSize = 34,
			ringThickness = 4,
			ringSteps = 72, -- the ring fills in this many steps (5 degrees), so it redraws only when it visibly moves
			gap = 8, -- between the ring and the words
			chevronSize = 12, -- the up arrow inside a ready ring
			chevronThickness = 3,
			secondsTextSize = 13, -- the seconds left inside a recharging ring
			-- What a press does now, and what the chip says while it runs.
			labels = {
				boostHop = "Boost",
				flight = "Fly",
			} :: { [string]: string },
			activeLabels = {
				boostHop = "Boosting",
				flight = "Flying",
			} :: { [string]: string },
			ready = "Ready",
			recharging = "Recharging",
			landing = "Landing",
			secondsFormat = "%d s", -- the seconds left on the touch Boost / Fly button while it recharges
		},
	},

	-- On-screen controls for touch devices (UI/TouchControls). Every size here is a touch target.
	touch = {
		minTarget = 44, -- smallest allowed touch target in either direction, px (a spec checks the sizes below)
		margin = 20, -- from the safe-area edge
		gap = 10,
		steerSize = Vector2.new(96, 96), -- each steering hold zone, bottom left
		gasSize = Vector2.new(88, 140), -- bottom right
		brakeSize = Vector2.new(88, 108), -- left of the gas pedal
		handbrakeSize = Vector2.new(88, 52), -- above the brake pedal
		buttonSize = Vector2.new(68, 48), -- mode, camera and exit, top right
		-- Phase 10: in a car with a thruster ability the gas pedal shortens to abilityGasSize and the Boost / Fly
		-- button sits above it, so the right-hand column stays exactly as tall as the brake and handbrake beside it
		-- and the pedal block UI/Phone/Layout keeps clear of doesn't change (tests/Thrusters.spec checks it).
		abilitySize = Vector2.new(88, 52),
		abilityGasSize = Vector2.new(88, 108),
		abilityStatusTextSize = 12, -- "Ready" / "12 s" under the button's label
		cornerRadius = 16,
		chevronSize = 26, -- steering arrow drawn on each hold zone
		chevronThickness = 5,
		labelTextSize = 15,
		labels = {
			gas = "Gas",
			brake = "Brake",
			handbrake = "Handbrake",
			mode = "Mode",
			camera = "Camera",
			exit = "Exit",
		},
	},

	-- Studio-only spawn list (UI/DevSpawnMenu).
	devMenu = {
		width = 220,
		rowHeight = 44,
		sectionHeight = 28,
		maxListHeight = 300,
		textSize = 14,
		sectionTextSize = 12,
		rowPadding = 12, -- text inset inside a row
		rowCornerRadius = 10,
		listInset = 6, -- space around the rows inside the list
		scrollBarThickness = 4,
		pickedFlashSeconds = 1.5, -- how long a picked row stays highlighted
		title = "Spawn a car",
		showLabel = "Show",
		hideLabel = "Hide",
	},

	-- One look for every driving UI: dark translucent panels, white text, one accent. Text colors keep at
	-- least 4.5:1 contrast on a panel even over a white sky.
	theme = {
		panel = Color3.fromRGB(16, 18, 24),
		panelRaised = Color3.fromRGB(38, 42, 52),
		panelTransparency = 0.2,
		text = Color3.fromRGB(255, 255, 255),
		textDim = Color3.fromRGB(186, 192, 204),
		accent = Color3.fromRGB(92, 196, 255),
		onAccent = Color3.fromRGB(8, 14, 22), -- text on an accent fill
		fonts = {
			regular = Font.new(FONT_FAMILY, Enum.FontWeight.Regular),
			medium = Font.new(FONT_FAMILY, Enum.FontWeight.Medium),
			bold = Font.new(FONT_FAMILY, Enum.FontWeight.Bold),
		},
	},

	-- The HUD's key hint row on keyboard and gamepad (none on touch: the buttons label themselves). The ability
	-- entry shows only while driving a car with a thruster ability (HudController.hintsFor).
	hints = {
		keyboard = {
			{ actions = { "throttle", "brake" }, label = "Drive" },
			{ actions = { "steerLeft", "steerRight" }, label = "Steer" },
			{ actions = { "handbrake" }, label = "Handbrake" },
			{ actions = { "ability" }, label = "Boost" },
			{ actions = { "mode" }, label = "Mode" },
			{ actions = { "regen" }, label = "Regen" },
			{ actions = { "camera" }, label = "Camera" },
			{ actions = { "exit" }, label = "Exit" },
		} :: { Hint },
		gamepad = {
			{ actions = { "throttle", "brake" }, label = "Drive" },
			{ actions = { "steer" }, label = "Steer" },
			{ actions = { "handbrake" }, label = "Handbrake" },
			{ actions = { "ability" }, label = "Boost" },
			{ actions = { "mode" }, label = "Mode" },
			{ actions = { "regen" }, label = "Regen" },
			{ actions = { "camera" }, label = "Camera" },
			{ actions = { "exit" }, label = "Exit" },
		} :: { Hint },
	},
}

return Controls
