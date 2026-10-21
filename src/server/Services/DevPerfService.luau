--!strict
-- The server half of the Studio perf drive (PLAN.md Phase 14 "Budgets"; docs/phase-14-contracts.md "Performance"):
-- samples the server's frame times while Dev/PerfTests drives.
--
-- Net DevPerf { action = "start" | "stop" } (Studio only, CLAUDE.md hard rule 8):
--   start  begins recording every RunService.Heartbeat delta (the server's frame time, in ms), dropping any run
--          already going. Returns { ok, message }.
--   stop   ends it and returns { ok, message, samples, seconds, meanMs, p95Ms, maxMs, capped, instances, parts,
--          budget }: the frame times summarized by Config/Perf.summarize, how long it ran, whether it hit the cap
--          below, everything in Workspace on the server now (instances) and how many of those are BaseParts, and the
--          budget they are judged against (Config/Perf frame.server). Dev/PerfTests does the judging.
-- One run per server, whoever calls. A run stops recording by itself after Config/Perf dev.maxSampleSeconds (stop
-- still returns what it has, with capped = true) and ends when the player who started it leaves, so a test that
-- dies never leaves it running. The handler is always connected, so the remote never queues; outside Studio it
-- answers { ok = false } and does nothing else.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Perf = require(Shared.Config.Perf)

local LOG = "[DevPerfService]"
local MS_PER_SECOND = 1000

local dev = Perf.dev
local messages = dev.messages

export type Reply = {
	ok: boolean,
	message: string,
	samples: number?,
	seconds: number?,
	meanMs: number?,
	p95Ms: number?,
	maxMs: number?,
	capped: boolean?,
	instances: number?,
	parts: number?,
	budget: Perf.FrameBudget?,
}

type Run = {
	owner: number, -- UserId of the player who started it
	samples: { number },
	limit: number, -- samples kept at most
	started: number, -- os.clock()
	ended: number?, -- os.clock() when it stopped recording (the cap)
	capped: boolean,
	connection: RBXScriptConnection?,
}

local DevPerfService = {}

local current: Run? = nil

local function halt(run: Run)
	local connection = run.connection
	run.connection = nil
	if connection ~= nil then
		connection:Disconnect()
	end
	if run.ended == nil then
		run.ended = os.clock()
	end
end

-- Everything in Workspace, and how many of those are BaseParts.
local function workspaceCounts(): (number, number)
	local instances, parts = 0, 0
	for _, descendant in Workspace:GetDescendants() do
		instances += 1
		if descendant:IsA("BasePart") then
			parts += 1
		end
	end
	return instances, parts
end

local function start(player: Player): Reply
	local previous = current
	if previous ~= nil then
		halt(previous)
	end
	local limit = math.ceil(dev.maxSampleSeconds * Perf.frame.server.fps)
	local run: Run = {
		owner = player.UserId,
		samples = table.create(limit),
		limit = limit,
		started = os.clock(),
		ended = nil,
		capped = false,
		connection = nil,
	}
	run.connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		if #run.samples >= run.limit then
			run.capped = true
			halt(run)
			return
		end
		table.insert(run.samples, deltaTime * MS_PER_SECOND)
	end)
	current = run
	print(`{LOG} {player.Name} started sampling the server's frame times`)
	return { ok = true, message = messages.started }
end

local function stop(): Reply
	local run = current
	if run == nil then
		return { ok = false, message = messages.notRunning }
	end
	current = nil
	halt(run)
	local summary = Perf.summarize(run.samples)
	local seconds = (run.ended or os.clock()) - run.started
	local instances, parts = workspaceCounts()
	return {
		ok = true,
		message = string.format(messages.stopped, summary.samples, seconds),
		samples = summary.samples,
		seconds = seconds,
		meanMs = summary.meanMs,
		p95Ms = summary.p95Ms,
		maxMs = summary.maxMs,
		capped = run.capped,
		instances = instances,
		parts = parts,
		budget = Perf.frame.server,
	}
end

local function onDevPerf(player: Player, payload: any): Reply
	if not RunService:IsStudio() then
		warn(`{LOG} {player.Name} ({player.UserId}) called DevPerf outside Studio`)
		return { ok = false, message = messages.studioOnly } -- dev tools stay dev (CLAUDE.md hard rule 8)
	end
	if payload.action == "start" then
		return start(player)
	end
	return stop()
end

-- Boot --------------------------------------------------------------------------------------------------------------

function DevPerfService:Start()
	-- Always listen, so the remote never queues up; the handler itself refuses outside Studio.
	Net.onServerInvoke("DevPerf", onDevPerf)
	Players.PlayerRemoving:Connect(function(player: Player)
		local run = current
		if run ~= nil and run.owner == player.UserId then
			current = nil
			halt(run)
		end
	end)
end

return DevPerfService
