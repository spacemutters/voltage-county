--!strict
-- Game passes, developer products and the subscription (Phase 12, PLAN.md §11). Davis creates them in the
-- Creator Dashboard and pastes their ids here. An id of 0 means "not created yet" and must no-op safely.
-- Robux prices are never written here: the UI reads them from MarketplaceService.

export type Monetization = {
	passes: { [string]: number },
	products: { [string]: number },
	subscriptions: { [string]: string },
}

local Monetization: Monetization = {
	passes = {},
	products = {},
	subscriptions = {},
}

return Monetization
