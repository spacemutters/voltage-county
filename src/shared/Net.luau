--!strict
-- The one network module (CLAUDE.md hard rule 2). Every RemoteEvent and RemoteFunction is declared in REMOTES
-- below with a direction, a payload validator and a per-player rate limit. No system creates remotes of its
-- own. Clients send intents ("buy X"), never outcomes ("add $500"); the server validates and decides.
--
-- Declaring a remote:
--   RequestSpawn = {
--   	kind = "event", -- "event" (RemoteEvent) or "function" (RemoteFunction, always client -> server)
--   	direction = "toServer", -- "toServer" (client sends, server validates) or "toClient" (server sends)
--   	validate = Check.shape({ vehicleUid = Check.string(64) }), -- checks every client -> server payload
--   	burst = 3, -- requests allowed at once
--   	perSecond = 0.5, -- requests regained per second
--   },
-- Each remote carries one payload value (or nothing). Server -> client payloads are trusted and not validated;
-- a client firing a "toClient" remote is rejected and reported.
--
-- Server: Net.setupServer(), Net.onServerEvent, Net.onServerInvoke, Net.fireClient, Net.fireAllClients,
--         Net.onReject (AntiExploitService listens here to log offenders).
-- Client: Net.setupClient(), Net.fireServer, Net.invokeServer, Net.onClientEvent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Check = require(script.Parent.Util.Check)
local RateLimiter = require(script.Parent.Util.RateLimiter)

export type Direction = "toServer" | "toClient"

export type Spec = {
	kind: "event" | "function",
	direction: Direction,
	validate: Check.Validator,
	burst: number,
	perSecond: number,
}

export type RejectReason = "rate" | "payload" | "arity" | "direction"
export type RejectListener = (player: Player, remote: string, reason: RejectReason) -> ()

local ID_LENGTH = 40
local UID_LENGTH = 64 -- HttpService:GenerateGUID(false) is 36 characters
local MAX_LOT_SLOTS = 64
local MAX_DEV_CASH = 100000000
local MAX_PRICE = 100000000 -- the dearest car in the catalog is far below this
local DATE_LENGTH = 10 -- "YYYY-MM-DD"
local MAX_EXTRAS = 8 -- kit extras on one car
local PLATE_LENGTH = 16 -- generous: the server trims and enforces Config/Customization's own limit

local REMOTES: { [string]: Spec } = {
	-- Studio only: spawn a car next to the player for testing (VehicleService refuses it outside Studio).
	DevSpawnVehicle = {
		kind = "event",
		direction = "toServer",
		validate = Check.shape({ vehicleId = Check.string(ID_LENGTH), trim = Check.string(ID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	-- Server tells the driver their car was moved back (anti-exploit reset or unstuck); payload { reason }.
	VehicleReset = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Redeem a code (Phase 3). Payload: the code as typed. Returns { ok: boolean, message: string }.
	RedeemCode = {
		kind = "function",
		direction = "toServer",
		validate = Check.string(32),
		burst = 3,
		perSecond = 0.2,
	},
	-- Server tells one player something short and friendly (a toast); payload { text: string, kind: string? }.
	Notify = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},

	-- Phase 4: dealership, used lot, garage, settings. Functions return { ok: boolean, message: string, ... }.
	BuyVehicle = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ vehicleId = Check.string(ID_LENGTH), trim = Check.string(ID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	UpgradeVehicle = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH), trim = Check.string(ID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	StartTestDrive = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ vehicleId = Check.string(ID_LENGTH), trim = Check.string(ID_LENGTH) }),
		burst = 2,
		perSecond = 0.2,
	},
	ClaimStarter = {
		kind = "function",
		direction = "toServer",
		validate = Check.none(),
		burst = 2,
		perSecond = 0.2,
	},
	GetUsedLot = {
		kind = "function",
		direction = "toServer",
		validate = Check.none(),
		burst = 4,
		perSecond = 1,
	},
	BuyUsed = {
		kind = "function",
		direction = "toServer",
		-- date and maxPrice are the lot day and the price the player's confirm showed: the server refuses (and
		-- says the new price) when the day has changed or the price has risen past it.
		validate = Check.shape({
			slot = Check.integer(1, MAX_LOT_SLOTS),
			date = Check.string(DATE_LENGTH),
			maxPrice = Check.integer(0, MAX_PRICE),
		}),
		burst = 3,
		perSecond = 0.5,
	},
	SpawnOwned = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	DespawnOwned = {
		kind = "function",
		direction = "toServer",
		validate = Check.none(),
		burst = 3,
		perSecond = 0.5,
	},
	SellVehicle = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	SetFavorite = {
		kind = "event",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH), favorite = Check.boolean() }),
		burst = 6,
		perSecond = 2,
	},
	UpdateSettings = {
		kind = "event",
		direction = "toServer",
		validate = Check.shape({
			units = Check.optional(Check.oneOf({ "mph", "kph" })),
			camera = Check.optional(Check.oneOf({ "chase", "orbit", "hood" })),
			musicVolume = Check.optional(Check.number(0, 1)),
		}),
		burst = 6,
		perSecond = 2,
	},
	-- Server sends a player their own profile snapshot (docs/phase-4-contracts.md, ProfileSyncService).
	ProfileSnapshot = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Phase 5: the server tells a driver their car is out of energy; payload { level, stationId? } (the nearest
	-- compatible station's MapLayout location id, for the GPS).
	EnergyAlert = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Phase 6: jobs. The client asks; the server checks positions and decides (docs/phase-6-contracts.md).
	JobAction = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({
			action = Check.oneOf({ "accept", "arrive", "cancel", "refresh" }),
			offerId = Check.optional(Check.string(ID_LENGTH)),
			jobId = Check.optional(Check.string(UID_LENGTH)),
		}),
		burst = 4,
		perSecond = 1,
	},
	-- Server sends a player their active job and current offers.
	JobUpdate = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Phase 7: the Wrap & Tint shop. `changes` holds only what the player changed; the server validates every
	-- value against Config/Customization and prices it. Returns { ok, message, cost }.
	BuyCustomization = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({
			uid = Check.string(UID_LENGTH),
			changes = Check.shape({
				paint = Check.optional(Check.string(ID_LENGTH)),
				customColor = Check.optional(Check.shape({
					h = Check.number(0, 1),
					s = Check.number(0, 1),
					v = Check.number(0, 1),
				})),
				finish = Check.optional(Check.string(ID_LENGTH)),
				wrap = Check.optional(Check.string(ID_LENGTH)),
				wheels = Check.optional(Check.string(ID_LENGTH)),
				rideHeight = Check.optional(Check.number(-1, 1)),
				tint = Check.optional(Check.number(0, 1)),
				caliper = Check.optional(Check.string(ID_LENGTH)),
				extras = Check.optional(Check.array(Check.string(ID_LENGTH), MAX_EXTRAS)),
				plateFormat = Check.optional(Check.string(ID_LENGTH)),
			}),
		}),
		burst = 3,
		perSecond = 0.5,
	},
	-- Custom plate text (filtered by TextService on the server before anyone sees it).
	SetPlate = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH), text = Check.string(PLATE_LENGTH) }),
		burst = 2,
		perSecond = 0.2,
	},
	-- Light shows at a MeetSpot.
	JoinLightShow = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ meetSpotId = Check.string(ID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	LeaveLightShow = {
		kind = "function",
		direction = "toServer",
		validate = Check.none(),
		burst = 3,
		perSecond = 0.5,
	},
	-- Server tells nearby players a show starts: { showId, routineId, startAt, cars }.
	LightShowStart = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	LightShowEnd = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Phase 8: couple or uncouple a trailer / towed car (HitchService picks the nearest valid target).
	TrailerAction = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ action = Check.oneOf({ "couple", "decouple" }) }),
		burst = 3,
		perSecond = 0.5,
	},
	-- Buy a job license (Phase 8: freight).
	BuyLicense = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ license = Check.oneOf({ "freight" }) }),
		burst = 2,
		perSecond = 0.2,
	},
	-- Phase 9: the robotaxi fleet (docs/phase-9-contracts.md). Functions return { ok, message, ... }; the server
	-- prices pods and counts slots. `zone` is a MapLayout zone id.
	BuyPod = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ zone = Check.string(ID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	AssignPod = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH), zone = Check.string(ID_LENGTH) }),
		burst = 4,
		perSecond = 1,
	},
	-- Pays out the fleet's uncollected earnings; returns { ok, message, amount }.
	CollectFleet = {
		kind = "function",
		direction = "toServer",
		validate = Check.none(),
		burst = 2,
		perSecond = 0.5,
	},
	SellPod = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ uid = Check.string(UID_LENGTH) }),
		burst = 3,
		perSecond = 0.5,
	},
	-- Ride a pod to a GPS destination (a MapLayout destination id); the server charges the fare and moves you.
	HailPod = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ destinationId = Check.string(ID_LENGTH) }),
		burst = 2,
		perSecond = 0.2,
	},
	-- Server sends every client the ambient pods' routes (all of them on join, one pod's new route after that).
	TrafficRoutes = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Server tells a rider to play their pod ride: { from, to, seconds, route }.
	HailRide = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- Phase 10: thrusters (docs/phase-10-contracts.md). The server checks ownership, trim, cooldown and zone; the
	-- owner's client applies the push. Returns { ok, message, startsAt?, endsAt?, readyAt? }.
	UseAbility = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ ability = Check.oneOf({ "boostHop", "flight" }) }),
		burst = 3,
		perSecond = 1,
	},
	-- Server tells a driver about their drag-strip run: { state, time?, best?, rank?, message? }.
	DragStripUpdate = {
		kind = "event",
		direction = "toClient",
		validate = Check.none(),
		burst = 0,
		perSecond = 0,
	},
	-- This week's drag-strip board: { week, entries = { { name, time } }, best?, rank? }.
	GetDragLeaderboard = {
		kind = "function",
		direction = "toServer",
		validate = Check.none(),
		burst = 3,
		perSecond = 0.5,
	},
	-- Studio only: clear the caller's car's ability cooldowns (AbilityService refuses it outside Studio), for the
	-- 50-run hop and flight tests.
	DevAbility = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ action = Check.oneOf({ "resetCooldowns" }) }),
		burst = 5,
		perSecond = 2,
	},
	-- Studio only: pretend the caller was away for `hours` (FleetService refuses it outside Studio), for the
	-- offline-earnings check in the fleet tests.
	DevFleet = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ action = Check.oneOf({ "simulateOffline" }), hours = Check.number(0, 24) }),
		burst = 3,
		perSecond = 1,
	},
	-- Studio only: dev shortcuts for the automated job tests (JobService refuses it outside Studio).
	DevJob = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ action = Check.oneOf({ "teleportToStop", "grantLicenseXp" }) }),
		burst = 3,
		perSecond = 1,
	},
	-- Studio only: set the caller's current car's energy (0..1) for the energy tests (EnergyService refuses it
	-- outside Studio).
	DevSetEnergy = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ level = Check.number(0, 1) }),
		burst = 3,
		perSecond = 1,
	},
	-- Studio only: set the caller's cash to exactly `amount` for the shop tests (DealershipService refuses it
	-- outside Studio).
	DevSetCash = {
		kind = "function",
		direction = "toServer",
		validate = Check.shape({ amount = Check.integer(0, MAX_DEV_CASH) }),
		burst = 3,
		perSecond = 1,
	},
}

local FOLDER_NAME = "Remotes"

local Net = {}
Net.check = Check

local remotes: { [string]: Instance } = {}
local limiters: { [string]: RateLimiter.RateLimiter } = {}
local rejectListeners: { RejectListener } = {}

local function specFor(name: string, kind: "event" | "function", direction: Direction): Spec
	local spec = REMOTES[name]
	assert(spec ~= nil, `Net: no remote named "{name}" is declared in Net.luau`)
	assert(spec.kind == kind, `Net: remote "{name}" is a {spec.kind}, not a {kind}`)
	assert(spec.direction == direction, `Net: remote "{name}" goes {spec.direction}, not {direction}`)
	return spec
end

local function remoteFor(name: string): Instance
	local remote = remotes[name]
	assert(remote ~= nil, `Net: remote "{name}" is not set up yet (call Net.setupServer / Net.setupClient first)`)
	return remote
end

local function reject(player: Player, name: string, reason: RejectReason)
	for _, listener in rejectListeners do
		task.spawn(listener, player, name, reason)
	end
end

-- Rate limit first (cheap), then the payload shape. Returns the payload only when it is admitted.
local function admit(player: Player, name: string, spec: Spec, ...: any): (boolean, any)
	if select("#", ...) > 1 then
		reject(player, name, "arity")
		return false, nil
	end
	if not limiters[name].take(player) then
		reject(player, name, "rate")
		return false, nil
	end
	local payload = ...
	if not spec.validate(payload) then
		reject(player, name, "payload")
		return false, nil
	end
	return true, payload
end

-- Server ---------------------------------------------------------------------------------------------------

function Net.setupServer()
	assert(RunService:IsServer(), "Net.setupServer runs on the server")
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for name, spec in REMOTES do
		local remote: Instance = if spec.kind == "event"
			then Instance.new("RemoteEvent")
			else Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
		remotes[name] = remote
		limiters[name] = RateLimiter.new(spec.burst, spec.perSecond)
		-- A client firing a server -> client remote is never legitimate.
		if spec.direction == "toClient" and remote:IsA("RemoteEvent") then
			remote.OnServerEvent:Connect(function(player: Player)
				reject(player, name, "direction")
			end)
		end
	end
	folder.Parent = ReplicatedStorage
	Players.PlayerRemoving:Connect(function(player)
		for _, limiter in limiters do
			limiter.forget(player)
		end
	end)
end

function Net.onReject(listener: RejectListener)
	table.insert(rejectListeners, listener)
end

function Net.onServerEvent(name: string, handler: (player: Player, payload: any) -> ()): RBXScriptConnection
	local spec = specFor(name, "event", "toServer")
	local remote = remoteFor(name) :: RemoteEvent
	return remote.OnServerEvent:Connect(function(player: Player, ...: any)
		local ok, payload = admit(player, name, spec, ...)
		if ok then
			handler(player, payload)
		end
	end)
end

-- A rejected call returns nil to the client.
function Net.onServerInvoke(name: string, handler: (player: Player, payload: any) -> any)
	local spec = specFor(name, "function", "toServer")
	local remote = remoteFor(name) :: RemoteFunction
	remote.OnServerInvoke = function(player: Player, ...: any): any
		local ok, payload = admit(player, name, spec, ...)
		if not ok then
			return nil
		end
		return handler(player, payload)
	end
end

function Net.fireClient(name: string, player: Player, payload: any?)
	specFor(name, "event", "toClient")
	local remote = remoteFor(name) :: RemoteEvent
	remote:FireClient(player, payload)
end

function Net.fireAllClients(name: string, payload: any?)
	specFor(name, "event", "toClient")
	local remote = remoteFor(name) :: RemoteEvent
	remote:FireAllClients(payload)
end

-- Client ---------------------------------------------------------------------------------------------------

function Net.setupClient()
	assert(RunService:IsClient(), "Net.setupClient runs on the client")
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	for name in REMOTES do
		remotes[name] = folder:WaitForChild(name)
	end
end

function Net.fireServer(name: string, payload: any?)
	specFor(name, "event", "toServer")
	local remote = remoteFor(name) :: RemoteEvent
	remote:FireServer(payload)
end

function Net.invokeServer(name: string, payload: any?): any
	specFor(name, "function", "toServer")
	local remote = remoteFor(name) :: RemoteFunction
	return remote:InvokeServer(payload)
end

function Net.onClientEvent(name: string, handler: (payload: any) -> ()): RBXScriptConnection
	specFor(name, "event", "toClient")
	local remote = remoteFor(name) :: RemoteEvent
	return remote.OnClientEvent:Connect(handler)
end

-- For specs and SECURITY.md: the declared remotes, read-only.
function Net.declared(): { [string]: Spec }
	return table.clone(REMOTES)
end

return Net
