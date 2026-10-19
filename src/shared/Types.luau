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
}

export type CustomDesign = {
	uid: string,
	spec: { [string]: any }, -- validated design spec (Phase 11); the car rebuilds from it
	createdAt: number,
	hidden: boolean, -- set by moderation; the car falls back to the plain kit look
}

export type CreditReservation = { id: string, amount: number, at: number }

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
	settings: { units: "mph" | "kph", camera: string, musicVolume: number },
	firstJoinAt: number,
}

-- A server service or client controller booted by Util/Loader.
export type Service = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

return {}
