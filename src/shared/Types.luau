--!strict
-- Shared types. Player data matches the ProfileStore template in PLAN.md §6; any change here is a schema
-- change: bump `version`, add a migration and a spec (CLAUDE.md hard rule 7).

export type OwnedVehicle = {
	uid: string, -- HttpService:GenerateGUID(false)
	vehicleId: string, -- a Config/Vehicles id, or "custom" for a player design
	designUid: string?, -- set when vehicleId == "custom"
	trim: string,
	paint: string, -- palette id (Config/Customization.paints), or a constrained custom color (Phase 7)
	finish: string, -- "gloss" | "matte" | "metallic"
	wrap: string?, -- Config/Customization.wraps id; nil or "none" = no wrap
	wheels: string,
	rideHeight: number, -- -1..1
	tint: number, -- 0..1
	-- v5 (Phase 7, the Wrap & Tint shop; ids from Config/Customization):
	caliper: string, -- brake caliper color
	extras: { string }, -- kit extras on the car's Mount_* attachments (spoiler, roof rack...), each id once
	plateFormat: string, -- plate style; standard formats are free
	-- Custom plate text exactly as the player typed it (Custom Plates pass). Raw: Services/CustomizationService
	-- filters it with TextService when it is set and again whenever the car spawns, and only the filtered text
	-- is ever put on a plate or sent to anyone. nil = the plate format's own text.
	plateText: string?,
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

-- One robotaxi pod (Phase 9): its uid (HttpService:GenerateGUID(false)) and the Config/Fleet zone it works in.
export type FleetPod = { uid: string, zone: string }

-- The robotaxi fleet (Phase 9; Services/FleetService owns it). Times are os.time() seconds.
export type FleetData = {
	pods: { FleetPod },
	lastCollectedAt: number, -- the player's last Collect (the collect cooldown)
	uncollected: number, -- v6: $ earned and not yet collected (not rounded; collecting pays the whole dollars)
	lastOnlineAt: number, -- v6: earnings are counted up to here; saved on the fleet timer and on leaving
}

-- Schema version 6 (Config/Data.schemaVersion). DataService/Migrations upgrades older saves step by step.
export type PlayerData = {
	version: number,
	cash: number,
	starterClaimed: boolean,
	vehicles: { OwnedVehicle },
	garageSlots: number,
	designs: { CustomDesign },
	customSlots: number,
	credits: { balance: number, freeDesignUsed: boolean, reserved: { CreditReservation } },
	fleet: FleetData,
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
	-- Phase 11 (Services/ProfileSyncService), each only when it applies:
	designUid: string?, -- a player design (vehicleId "custom")
	modded: boolean?, -- the car has an AI mod
	modHidden: boolean?, -- a moderator hid it (no mods or summary are sent)
	mods: { [string]: any }?, -- the mod spec, re-validated, without its accessory prompt
	modSummary: string?, -- filtered when the mod was made, and again on every join
}

-- One of the player's designs in the snapshot (Phase 11, Services/ProfileSyncService). A design a moderator hid
-- sends its plain look and plain name, no tagline.
export type SnapshotDesign = {
	uid: string,
	name: string,
	tagline: string,
	classId: string,
	hidden: boolean,
	createdAt: number,
	spec: { [string]: any }?, -- the design without its generation prompt; nil when it no longer validates
}

-- A zone a pod can work in, as the Fleet app shows it (Config/Fleet).
export type SnapshotFleetZone = {
	id: string, -- a MapLayout zone id
	name: string, -- its display name
	demand: number, -- 1 = average
	perHour: number, -- expected $ per pod per hour online there (before the hourly variation and boosts)
}

-- The robotaxi fleet part of the snapshot (Phase 9, docs/phase-9-contracts.md).
export type SnapshotFleet = {
	pods: { FleetPod },
	uncollected: number, -- whole dollars ready to collect
	slots: number, -- pods allowed now (Config/Fleet default slots + the Fleet Manager pass bonus)
	podPrice: number, -- what BuyPod costs now
	sellBack: number, -- what SellPod pays for one pod
	zones: { SnapshotFleetZone },
	offlineRate: number, -- share of the online rate pods earn while the player is away
	offlineCapHours: number, -- away time past this earns nothing
}

export type ProfileSnapshot = {
	cash: number,
	garageSlots: number,
	customSlots: number,
	starterClaimed: boolean,
	vehicles: { SnapshotVehicle }, -- favorites first, then the newest (Config/Garage.sortVehicles)
	settings: Settings,
	-- Phase 11: freeDesignUsed is true while the one free new car is used or held by a request.
	credits: { balance: number, freeDesignUsed: boolean? },
	-- Phase 9: ProfileSyncService always sends it; optional so a client copy built before it (ProfileController's
	-- checked copy, specs) still type-checks.
	fleet: SnapshotFleet?,
	-- Phase 11: ProfileSyncService always sends it (optional for the same reason as `fleet`).
	designs: { SnapshotDesign }?,
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
