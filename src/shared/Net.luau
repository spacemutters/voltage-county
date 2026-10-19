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
