--!strict
-- One-time offers such as the Starter Pack (PLAN.md Phase 12 and §11; docs/phase-12-contracts.md "Monetization
-- core"): the product each one sells and the moments that bring it up. Read by Services/MonetizationService (the
-- GetStore `offers` list, and refusing a second purchase) and the store UI (when to show the offer sheet).
--
-- An offer is shown once any of its `showAfter` moments has happened and until it is bought. Buying it sets
-- PlayerData.offersSeen[id], and from then on it is never shown or sold again. The moments are read from the save
-- (MonetizationService.momentHappened), so they need no extra saved fields:
--   firstDesign      the player's free new car is used (or they have a design)
--   firstJobPayout   the player has earned job XP (a job paid out)

export type Moment = "firstDesign" | "firstJobPayout"

export type Offer = {
	id: string, -- the PlayerData.offersSeen key
	productKey: string, -- key into Config/Monetization.products
	showAfter: { Moment },
}

local Offers: { [string]: Offer } = {
	starterPack = {
		id = "starterPack",
		productKey = "starterPack",
		showAfter = { "firstDesign", "firstJobPayout" },
	},
}

return Offers
