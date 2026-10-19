--!strict
-- Default feature switches. From Phase 12 a DataStore key overrides these live (read every 60 s), giving a
-- kill switch per feature, the AI Car Designer included.

local FeatureFlags: { [string]: boolean } = {}

return FeatureFlags
