--!strict
-- The phone's Jobs app. Jobs arrive in Phase 6 (PLAN.md); until then this is a finished "arriving soon" screen.

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)

local function JobsApp(_props: {})
	local copy = PhoneConfig.jobs
	return Kit.ComingSoon({ glyph = "jobs", title = copy.title, body = copy.body, pill = copy.pill })
end

return JobsApp
