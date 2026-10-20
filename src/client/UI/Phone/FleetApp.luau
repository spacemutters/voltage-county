--!strict
-- The phone's Fleet app. The robotaxi fleet arrives in Phase 9 (PLAN.md); until then this is a finished
-- "arriving soon" screen.

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)

local function FleetApp(_props: {})
	local copy = PhoneConfig.fleet
	return Kit.ComingSoon({ glyph = "fleet", title = copy.title, body = copy.body, pill = copy.pill })
end

return FleetApp
