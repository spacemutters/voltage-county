--!strict
-- Car brands (PLAN.md §2, §3.1). Every vehicle references a brand id. The default build is unlicensed: every
-- brand is fictional. A signed license becomes a new entry with licensed = true; no system code changes.
-- Filled in Phase 1.

export type Brand = {
	id: string,
	displayName: string,
	logoAssetIds: { number },
	segment: string,
	licensed: boolean,
	credits: string?, -- trademark notice shown in credits when licensed
}

local Brands: { [string]: Brand } = {}

return Brands
