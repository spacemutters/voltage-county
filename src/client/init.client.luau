--!strict
-- Client entry point: waits for the remotes, then boots every controller in Controllers/.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Shared")
local Loader = require(ReplicatedStorage.Shared.Util.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

Net.setupClient()
Loader.boot(script:FindFirstChild("Controllers"), "Client", "controllers")
