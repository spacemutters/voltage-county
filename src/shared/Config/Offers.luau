--!strict
-- One-time offers such as the Starter Pack (Phase 12): when they show, and the product they sell.
-- Once bought, an offer never shows again (PlayerData.offersSeen).

export type Offer = {
	id: string,
	productKey: string, -- key into Config/Monetization.products
	showAfter: { string }, -- moments that trigger it, e.g. "firstDesign", "firstJobPayout"
}

local Offers: { [string]: Offer } = {}

return Offers
