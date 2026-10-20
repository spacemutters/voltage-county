--!strict
-- Shared types. Player data matches the ProfileStore template in PLAN.md §6; any change here is a schema
-- change: bump `version`, add a migration and a spec (CLAUDE.md hard rule 7).

export type OwnedVehicle = {
	uid: string, -- HttpService:GenerateGUID(false)
	vehicleId: string, -- a Config/Vehicles id, or "custom" for a player design
	designUid: string?, -- set when vehicleId == "custom"
	trim: string,
	paint: string, -- palette id
	finish: string, -- "gloss" | "matte" | "metallic"
	wrap: string?,
	wheels: string,
	rideHeight: number, -- -1..1
	tint: number, -- 0..1
	plateText: string?, -- raw; filter before showing to anyone else
	mods: { [string]: any }?, -- validated AI mod spec (Phase 11)
	serial: number?, -- limited serial number
	acquiredAt: number, -- os.time()
	favorite: boolean, -- v3: starred in the phone's Garage app (favorites sort first)
	paid: number, -- v3: whole $ the player paid (0 for the free starter); selling back pays Config/Garage share
	-- v4: charge or tank level, 0..1 (1 = full). Services/EnergyService owns it while the car is out and writes
	-- it back when the car is put away, the player leaves, and at most once a minute while driving.
	energy: number,
}

export type CustomDesign = {
	uid: string,
	spec: { [string]: any }, -- validated design spec (Phase 11); the car rebuilds from it
	createdAt: number,
	hidden: boolean, -- set by moderation; the car falls back to the plain kit look
}

export type CreditReservation = { id: string, amount: number, at: number }

-- A timed earnings boost (from a code). Active while os.time() < endsAt; EconomyService drops expired ones.
-- Added in schema version 2.
export type Boost = { id: string, factor: number, endsAt: number } -- endsAt = os.time() seconds

-- Player settings, set from the phone's Settings app (Net UpdateSettings, validated by GarageService).
export type Settings = { units: "mph" | "kph", camera: string, musicVolume: number }

-- Schema version 4 (Config/Data.schemaVersion). DataService/Migrations upgrades older saves step by step.
export type PlayerData = {
	version: number,
	cash: number,
	starterClaimed: boolean,
	vehicles: { OwnedVehicle },
	garageSlots: number,
	designs: { CustomDesign },
	customSlots: number,
	credits: { balance: number, freeDesignUsed: boolean, reserved: { CreditReservation } },
	fleet: { pods: { { uid: string, zone: string } }, lastCollectedAt: number },
	jobs: { xp: { [string]: number }, licenses: { [string]: boolean } },
	house: { upgrades: { [string]: boolean } },
	stats: { milesDriven: number, tripsCompleted: number, playtimeSec: number },
	codesRedeemed: { [string]: boolean },
	season: { id: string, xp: number, premium: boolean, claimed: { [string]: boolean } },
	streak: { lastDay: number, count: number },
	offersSeen: { [string]: boolean }, -- one-time offers like the Starter Pack
	club: { lastGrantMonth: string? }, -- Voltage Club monthly credit grant (once per billing month)
	receipts: { string }, -- last 100 processed PurchaseIds (ProcessReceipt idempotency)
	pendingGrants: { { kind: string, ref: string } },
	settings: Settings,
	firstJoinAt: number,
	boosts: { Boost }, -- v2: timed earnings boosts
}

-- What a player's client knows about their own profile: the Net ProfileSnapshot payload, sent by
-- Services/ProfileSyncService on load and after every change (docs/phase-4-contracts.md). Copies of sanitized
-- fields only; never anyone else's data.
export type SnapshotVehicle = {
	uid: string,
	vehicleId: string,
	trim: string,
	favorite: boolean,
	paid: number,
	paint: string,
	finish: string,
	wheels: string,
	acquiredAt: number,
}

export type ProfileSnapshot = {
	cash: number,
	garageSlots: number,
	customSlots: number,
	starterClaimed: boolean,
	vehicles: { SnapshotVehicle }, -- favorites first, then the newest (Config/Garage.sortVehicles)
	settings: Settings,
	credits: { balance: number },
}

-- Driving -------------------------------------------------------------------------------------------------

export type DriveMode = "comfort" | "standard" | "sport"
export type RegenLevel = "low" | "standard" | "high"

-- What the driver is asking for this frame, from InputController (keyboard, gamepad, touch or AutoDriver).
export type Controls = {
	throttle: number, -- 0..1
	brake: number, -- 0..1; held at a standstill it engages reverse (Vehicle/Powertrain)
	steer: number, -- -1 (left) .. 1 (right)
	handbrake: boolean,
}

-- What the owning client's chassis reports each frame, for the HUD, camera and AutoDriver.
export type Telemetry = {
	speed: number, -- studs/s, forward-signed (negative when reversing)
	mph: number, -- absolute
	gear: string, -- "P" | "R" | "N" | "D" or "1".."6" for fuel cars
	mode: DriveMode,
	regen: RegenLevel,
	throttle: number, -- 0..1 after drive-mode shaping
	wheelsGrounded: number, -- 0..4
	tractionActive: boolean,
	reversing: boolean,
}

-- A server service or client controller booted by Util/Loader.
export type Service = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

return {}
