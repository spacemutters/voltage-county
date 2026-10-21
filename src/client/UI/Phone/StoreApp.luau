--!strict
-- The phone's Store app (docs/phase-12-contracts.md "Store UI"; PLAN.md Phase 12 and §11). It shows, top to bottom:
--
--   events      the event banner and its countdowns, from EventUpdate, with Buy on a limited drop that's on sale
--               (UI/Store/StoreCards.EventBanner)
--   pages       Credits / Passes / More (Kit.Segmented; the page is kept in UI/Store/StoreState)
--   Credits     your Design Credits, the Starter Pack while it's offered, the free daily ad credit when one can
--               play, the credit packs with the prices the server's GetStore sent, and what credits buy
--   Passes      the Voltage Club and every pass with its perks
--   More        the daily reward, the Season Pass, "Invite your crew", private servers with the Roblox Plus prompt,
--               cash packs, the extra custom-car space and limited looks
--
-- UI/Phone/Phone mounts it for the "store" app. It reads the store's state itself (UI/Store/StoreState, which
-- re-renders it when it changes) and the balance from the profile (ProfileController); the phone re-renders it with
-- every new snapshot. Opening it asks StoreController for a fresh GetStore when the last one is old
-- (StoreStyle.refreshAfterSeconds). Presentation only: every purchase is a request the server decides, and
-- Roblox's own prompt shows the price before anything is charged.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local StoreCards = require(script.Parent.Parent.Store.StoreCards)
local StoreState = require(script.Parent.Parent.Store.StoreState)
local StoreStyle = require(script.Parent.Parent.Store.StoreStyle)
local ProfileController = require(script.Parent.Parent.Parent.Controllers.ProfileController)

local e = React.createElement

local function StoreApp(_props: {})
	local state = StoreState.useState()

	-- Opening the app: a fresh store when the last answer is old (never on a timer).
	React.useEffect(function()
		StoreState.refresh(false)
	end, {})

	local designer = ProfileController.designer()
	local children: { [string]: any } = {
		Events = e(StoreCards.EventBanner, { events = state.events, order = 1, busy = state.busy }),
		Pages = e(Kit.Segmented, {
			options = StoreStyle.pages,
			selected = state.page,
			order = 2,
			onSelect = function(id: string)
				StoreState.setPage(id :: StoreState.Page)
			end,
		}),
	}

	local store = state.store
	if store ~= nil and not store.open then
		-- Switched off for a moment (a live flag): every card shows the same note in place of its button.
		children.Closed = Kit.Text({
			text = StoreStyle.copy.storeClosed,
			order = 0, -- above everything
			font = Theme.fonts.medium,
			color = Theme.colors.warning,
		})
	end
	if store == nil then
		children.Status = e(StoreCards.StatusPage, { loading = state.loading or not state.failed, order = 3 })
	elseif state.page == "passes" then
		children.Page = e(StoreCards.PassesPage, { state = state })
	elseif state.page == "more" then
		children.Page = e(StoreCards.MorePage, { state = state })
	else
		children.Page = e(StoreCards.CreditsPage, {
			state = state,
			balance = if designer ~= nil then designer.balance else nil,
			freeCar = designer ~= nil and not designer.freeDesignUsed,
		})
	end

	return Kit.Page({ gap = Theme.spacing.md }, children)
end

return StoreApp
