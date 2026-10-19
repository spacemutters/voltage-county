--!strict
-- Server entry point: creates the remotes, then boots every service in Services/.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Util.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

Net.setupServer()
Loader.boot(script:FindFirstChild("Services"), "Server", "services")
