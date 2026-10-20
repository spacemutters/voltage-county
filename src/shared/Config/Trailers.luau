--!strict
-- Trailers and towed cars (PLAN.md Phase 8, docs/phase-8-contracts.md "Trailers and towed cars"): the trailer
-- models Dev/TrailerBuilder builds, the physics Vehicle/Trailer runs for a coupled trailer or towed car, the
-- ball-socket hitch Services/HitchService puts on a coupling, the couple and decouple rules, and the jackknife
-- angle Dev/FreightTests judges a run by. Pure data: no Roblox services.
--
-- Units are studs, seconds, studs/s and studs/s²; angles are degrees, like BallSocketConstraint's own
-- properties. Physics is mass-independent like Config/Driving: every force on a trailer is its own assembly
-- mass times an acceleration from here, so a trailer's mass only changes how hard it tugs on its tractor.
--
-- Who carries a trailer's weight. In a real rig the tractor carries the trailer's nose on its fifth wheel or
-- tow hitch. Our tractors' springs are sized to their own weight (Vehicle/Chassis), so that load would squash
-- them onto their bump stops. Instead the trailer holds up its own nose: Vehicle/Trailer pushes up at the hitch
-- with exactly the weight resting there (hitchSupport = 1), the hitch only pulls, pushes and steers, and the
-- tractor drives the same coupled or not. Rolling resistance still counts the trailer's whole weight.
--
-- Hitch geometry. Both attachments of a coupling keep their chassis orientation when the rig is in line: the
-- Hauler's Kingpin and a trailer's Kingpin face forward; a TowHitch and a car's TowPoint both face back. So
-- with LimitsEnabled the cone (upperAngle) bounds the angle between the two attachments' primary axes (their
-- X, sideways): the articulation, plus any roll between the two. The twist limits bound the rotation about that
-- sideways axis: the pitch between tractor and trailer over crests and dips.

-- What Vehicle/Trailer needs to run a trailer or a towed car. Trailer specs and the towed-car spec both have
-- these fields.
export type Physics = {
	hitchAttachment: string, -- the attachment on the Chassis that couples: "Kingpin" or "TowPoint"
	groundWheels: { string }, -- wheels that touch the ground: raycast suspension, tires and brakes
	liftedWheels: { string }, -- wheels held off the ground (a towed car's front): posed hanging, no physics
	-- Share of the weight resting on the hitch that the trailer holds up itself (see the header). 1 = all of it.
	hitchSupport: number,
	suspensionFrequency: number, -- natural frequency of each ground wheel, Hz
	dampingRatio: number, -- of critical damping, averaged over bump and rebound (Config/Driving's scales)
	antiRollRatio: number, -- anti-roll bar stiffness as a share of the wheel spring, per axle
	-- Compression (studs) where the bump stop starts; nil = Config/Driving.suspension.bumpStopFraction of the
	-- ride height (what cars use).
	bumpTravel: number?,
	grip: number, -- tire friction coefficient, relative to gravity
	lateralGripRate: number, -- how fast the tires kill sideways sliding below the grip limit, 1/s
	brakeDecel: number, -- full-brake deceleration of the trailer itself, studs/s²
	-- Anti-jackknife: the yaw rate relative to the tractor decays at this rate, 1/s. Applied as a pair of
	-- equal and opposite angular impulses on trailer and tractor, so it only ever slows the hitch's swing.
	yawDampingRate: number,
}

-- BallSocketConstraint settings for a coupling (the property names, in lowerCamelCase). HitchService applies
-- them; Vehicle/Trailer.configureHitch does it in one call.
export type HitchSettings = {
	limitsEnabled: boolean,
	upperAngle: number, -- degrees: the most articulation (plus roll) the hitch allows
	twistLimitsEnabled: boolean,
	twistLowerAngle: number, -- degrees: pitch between tractor and trailer, nose down
	twistUpperAngle: number, -- degrees: nose up
	restitution: number, -- bounce off the limits, 0..1
	maxFrictionTorque: number, -- 0 = the hitch swings freely (yaw damping is Vehicle/Trailer's job)
}

export type TrailerStyle = "box" | "flatbed" | "tanker"

export type Axle = {
	id: string, -- wheel names are this plus L or R ("A1" -> A1L, A1R)
	fromBack: number, -- studs from the back end of the body
}

export type TrailerSpec = {
	id: string,
	displayName: string,
	style: TrailerStyle, -- which greybox body Dev/TrailerBuilder builds
	-- Mass as a share of the reference tractor's (referenceTractor below). Dev/TrailerBuilder sets the Chassis
	-- density from it. It sets how much the trailer slows the tractor down, nothing else (see the header).
	massRatio: number,
	length: number, -- body, front to back
	width: number,
	height: number, -- top of the body (or load) above the ground
	chassisHeight: number, -- the physics box: from the deck (kingpinHeight) up this far
	wheelRadius: number,
	wheelWidth: number,
	track: number, -- center to center of the left and right wheels
	axles: { Axle }, -- front axle first

	-- Physics (the Physics type)
	hitchAttachment: string,
	groundWheels: { string },
	liftedWheels: { string },
	hitchSupport: number,
	suspensionFrequency: number,
	dampingRatio: number,
	antiRollRatio: number,
	bumpTravel: number?,
	grip: number,
	lateralGripRate: number,
	brakeDecel: number,
	yawDampingRate: number,
}

export type TowedSpec = {
	-- A towed car's TowPoint (added to every catalog model by Dev/VehicleBuilder): this far ahead of the
	-- Chassis' front face, so the tow truck's and the car's chassis boxes stay clear of each other while the
	-- hitch swings (a wheel-lift tow holds the car about this far behind the truck)...
	towPointAhead: number,
	-- ...and this high above the ground at rest. Every TowHitch is higher (about 1.4 to 1.8 studs), so coupling
	-- lifts the car's front wheels off the road by the difference.
	towPointHeight: number,
	hitch: HitchSettings, -- for a TowHitch-TowPoint coupling

	-- Physics (the Physics type): the rear wheels roll, the front ones hang in the lift.
	hitchAttachment: string,
	groundWheels: { string },
	liftedWheels: { string },
	hitchSupport: number,
	suspensionFrequency: number,
	dampingRatio: number,
	antiRollRatio: number,
	bumpTravel: number?,
	grip: number,
	lateralGripRate: number,
	brakeDecel: number,
	yawDampingRate: number,
}

-- Shared by the three trailers: the axles, tires and suspension of a tandem-axle semi trailer.
local TANDEM: { Axle } = {
	{ id = "A1", fromBack = 9.5 },
	{ id = "A2", fromBack = 5.5 },
}
local TANDEM_WHEELS = { "A1L", "A1R", "A2L", "A2R" }
local TRAILER_WHEEL_RADIUS = 1.7
local TRAILER_WHEEL_WIDTH = 1.5 -- reads as a dual-tire set
local TRAILER_TRACK = 6.4
local TRAILER_FREQUENCY = 2.0 -- Hz, about the Hauler's own (Config/Driving at its handling)
local TRAILER_DAMPING = 0.6
-- Twice a car's: the ball-socket hitch gives no roll support, so the tandem's springs alone hold the tall box
-- up (about 1.5 degrees of lean in a hard 60 mph curve instead of about 4).
local TRAILER_ANTI_ROLL = 1.0
local TRAILER_BUMP_TRAVEL = 1.0
local TRAILER_GRIP = 0.6
local TRAILER_LATERAL_RATE = 18 -- the Hauler's own rate (Config/Driving at its handling)
-- A little more than the Hauler's own 35 studs/s²: under braking the trailer pulls back on the hitch, and a
-- rig that stays stretched cannot jackknife. The floor: Vehicle/Trailer brakes at brakeRatio x the tractor's own
-- brake when that is more.
local TRAILER_BRAKE_DECEL = 38
local TRAILER_YAW_DAMPING = 2

local function trailer(spec: {
	id: string,
	displayName: string,
	style: TrailerStyle,
	massRatio: number,
	length: number,
	height: number,
	chassisHeight: number,
}): TrailerSpec
	return {
		id = spec.id,
		displayName = spec.displayName,
		style = spec.style,
		massRatio = spec.massRatio,
		length = spec.length,
		width = 8.5, -- the Hauler's width
		height = spec.height,
		chassisHeight = spec.chassisHeight,
		wheelRadius = TRAILER_WHEEL_RADIUS,
		wheelWidth = TRAILER_WHEEL_WIDTH,
		track = TRAILER_TRACK,
		axles = TANDEM,

		hitchAttachment = "Kingpin",
		groundWheels = TANDEM_WHEELS,
		liftedWheels = {},
		hitchSupport = 1,
		suspensionFrequency = TRAILER_FREQUENCY,
		dampingRatio = TRAILER_DAMPING,
		antiRollRatio = TRAILER_ANTI_ROLL,
		bumpTravel = TRAILER_BUMP_TRAVEL,
		grip = TRAILER_GRIP,
		lateralGripRate = TRAILER_LATERAL_RATE,
		brakeDecel = TRAILER_BRAKE_DECEL,
		yawDampingRate = TRAILER_YAW_DAMPING,
	}
end

local Trailers = {
	-- Contract names (docs/phase-8-contracts.md).
	modelsFolder = "TrailerModels", -- ServerStorage.TrailerModels
	tag = "Trailer", -- CollectionService tag on every trailer model (and so on every clone)
	-- CollectionService tag on every towed car a job puts out (Services/JobService/Towing): such a car is not a
	-- player's car (no Config/Spawning.vehicleTag), so Controllers/TrailerController poses its wheels for everyone.
	towedTag = "TowedCar",
	idAttribute = "TrailerId", -- on every trailer model: its key in `trailers` below
	towedAttribute = "Towed", -- a catalog car with this attribute = true is a towed car
	towingAttribute = "TowingModel", -- on a coupled tractor: the coupled model's name
	towingValue = "Towing", -- ObjectValue under a coupled tractor pointing at the coupled model
	landingGearFolder = "LandingGear", -- trailer legs, each on a Motor6D named landingGearMotor
	landingGearMotor = "Lift",

	-- The tractor trailers are built for: their kingpin height, width and mass ratio are relative to it.
	referenceTractor = { vehicleId = "ohm_hauler", trimId = "standard" },
	-- Height of the Hauler's fifth-wheel plate top above the ground at rest, where its Kingpin attachment sits
	-- (Dev/VehicleBuilder: arch top 4.06 + plate lift 0.45 + plate 0.35). Trailers stand with their kingpin and
	-- deck at this height, so a coupled rig rides level. tests/Trailer.spec checks it against the built Hauler.
	kingpinHeight = 4.86,
	-- How far behind a trailer's front edge its kingpin sits.
	kingpinSetback = 3.2,
	-- A trailer's physics box starts this far behind its kingpin. The Hauler's chassis box reaches 5.6 studs
	-- behind its kingpin, and its farthest rear corner is ~7.8 studs from it (5.6 behind, 4.25 to the side, 3.3
	-- below), so within the hitch's limits the two boxes never touch; the trailer's front overhang is visual only.
	chassisGap = 8,
	landingGear = {
		behindKingpin = 9, -- the legs stand this far behind the kingpin
		retract = 1.5, -- studs the legs crank up while the trailer is coupled (unanchored)
	},

	-- Coupling rules (Services/HitchService).
	coupleDistance = 5, -- studs between the tractor's Kingpin / TowHitch and the target's Kingpin / TowPoint
	coupleMaxSpeed = 2, -- studs/s: the tractor must be about this still to couple...
	decoupleMaxSpeed = 2, -- ...and to uncouple
	-- A TowDrop or TrailerSpawn point (a single spot rather than a footprint part) counts as "inside a depot or
	-- yard" within this many studs.
	decoupleRadius = 25,
	-- Degrees: the tractor and the target must be lined up within this (Vehicle/Trailer.articulation) to couple,
	-- well inside both hitches' upperAngle, so the joint never starts outside its own limits.
	coupleMaxAngle = 30,

	-- The semi's kingpin hitch.
	hitch = {
		limitsEnabled = true,
		upperAngle = 80, -- a little past jackknifeAngle: the hitch only stops a swing a test already failed
		twistLimitsEnabled = true,
		twistLowerAngle = -20,
		twistUpperAngle = 20,
		restitution = 0,
		maxFrictionTorque = 0,
	} :: HitchSettings,

	-- Dev/FreightTests counts a jackknife when the articulation (Vehicle/Trailer.articulation: the angle between
	-- tractor and trailer headings in the tractor's ground plane) goes past this many degrees.
	jackknifeAngle = 75,

	-- Under braking a trailer or towed car brakes at least this many times its tractor's own full-brake
	-- deceleration (Vehicle/Tuning brakeDecel, mods included), so it always pulls back on the hitch and never
	-- pushes: a rig that stays stretched cannot jackknife. Each spec's brakeDecel is the floor.
	brakeRatio = 1.1,
	-- Off the throttle, the trailer brakes like its tractor's own lift-off (regen at the driver's level and drive
	-- mode, or engine braking; Config/Driving.powertrain, faded in and out the same way) plus this many studs/s²,
	-- about the tractor's air drag that the trailer lacks, so a coasting rig stays stretched.
	coastMargin = 1,

	trailers = {
		-- A 53-foot-style dry van: one tall box with swing doors, side skirts and a stripe.
		box_trailer = trailer({
			id = "box_trailer",
			displayName = "Box Trailer",
			style = "box",
			massRatio = 0.55,
			length = 40,
			height = 13,
			chassisHeight = 7.9, -- the whole van box above the deck
		}),
		-- An open deck with a headboard and a strapped load of crates.
		flatbed_trailer = trailer({
			id = "flatbed_trailer",
			displayName = "Flatbed Trailer",
			style = "flatbed",
			massRatio = 0.45,
			length = 38,
			height = 8.3,
			chassisHeight = 3.2, -- the deck and its load
		}),
		-- A round steel tank with a top walkway.
		tanker_trailer = trailer({
			id = "tanker_trailer",
			displayName = "Tanker Trailer",
			style = "tanker",
			massRatio = 0.7,
			length = 34,
			height = 12.4,
			chassisHeight = 7.2, -- the tank's bounding box above the deck
		}),
	} :: { [string]: TrailerSpec },

	-- A towed car: any catalog car with Towed = true, its front lifted on a pickup's or tow truck's TowHitch.
	towed = {
		towPointAhead = 2.5,
		towPointHeight = 0.3,
		hitch = {
			limitsEnabled = true,
			upperAngle = 65,
			twistLimitsEnabled = true,
			twistLowerAngle = -30, -- the lifted car sits nose-up by a few degrees before any dip
			twistUpperAngle = 30,
			restitution = 0,
			maxFrictionTorque = 0,
		},

		hitchAttachment = "TowPoint",
		groundWheels = { "RL", "RR" },
		liftedWheels = { "FL", "FR" },
		hitchSupport = 1,
		suspensionFrequency = 2.2,
		dampingRatio = 0.6,
		antiRollRatio = 0.5,
		bumpTravel = nil, -- the car's own: a share of its ride height
		grip = 0.7,
		lateralGripRate = 20,
		-- The tow rig brakes the car's rear wheels with the truck, harder than any tow truck brakes itself (at most
		-- 40), so it never pushes; brakeRatio keeps that for any truck that brakes harder.
		brakeDecel = 42,
		yawDampingRate = 2,
	} :: TowedSpec,
}

return Trailers
