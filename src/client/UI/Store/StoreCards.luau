--!strict
-- The Store app's pieces (docs/phase-12-contracts.md "Store UI"), built from the phone's kit (UI/Phone/Kit) in the
-- one look from UI/Theme. UI/Phone/StoreApp lays them out:
--
--   EventBanner   the events and limited drops on now ("On now" / "Limited drop", what they do, "Ends in 3h 12m")
--                 and the next one coming ("Starts in 1d 4h"), from EventUpdate. Its countdowns redraw when the shown
--                 time changes (StoreModel.tickAfter), only while it's on screen. A drop on sale now has its Buy button
--                 (in-game cash, Net BuyLimited).
--   CreditsPage   your Design Credits, the Starter Pack while the server says its offer is up, the free daily ad
--                 credit while it's offered and Roblox says an ad can play, the credit packs with their prices, and
--                 what credits buy (Config/Designer's prices).
--   PassesPage    the Voltage Club card, then every pass with its perks.
--   MorePage      the daily reward, the Season Pass (tier, XP, countdown, the next reward to claim on each track),
--                 "Invite your crew" (when Roblox says this player can send invites), private servers with the Roblox
--                 Plus prompt, cash packs, the extra custom-car space and limited looks.
--   StatusPage    loading, or "The store didn't load" with Try again.
--
-- Every price is the number the server's GetStore sent (StoreModel.priceText). An item the server didn't put on sale
-- shows a "Coming soon" pill and no button, so nothing can be bought until it exists; one this player can't buy now
-- shows the server's note instead of a button. One request at a time: while one is with the server every buy button is
-- off and that one says "Opening...". Presentation only: the taps call UI/Store/StoreState, which StoreController
-- answers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Season = require(ReplicatedStorage.Shared.Config.Season)

local Kit = require(script.Parent.Parent.Phone.Kit)
local Theme = require(script.Parent.Parent.Theme)
local DesignerModel = require(script.Parent.Parent.Designer.DesignerModel)
local StoreModel = require(script.Parent.StoreModel)
local StoreState = require(script.Parent.StoreState)
local StoreStyle = require(script.Parent.StoreStyle)

local e = React.createElement
local colors = Theme.colors
local copy = StoreStyle.copy
local card = StoreStyle.card

local StoreCards = {}

-- The clock ------------------------------------------------------------------------------------------------------

-- `now` (server UTC seconds) for a component that shows countdowns, read fresh on every render. It redraws the
-- component when the text it shows next changes: `soonestOf(now)` says how many seconds until the nearest countdown
-- it shows ends (nil: none). Each render sets one timer and drops the last one.
local function useClock(soonestOf: (now: number) -> number?): number
	local _, setTick = React.useState(0)
	local now = StoreState.now()
	local soonest = soonestOf(now)
	React.useEffect(function(): (() -> ())?
		if soonest == nil then
			return nil
		end
		local live = true
		task.delay(StoreModel.tickAfter(soonest), function()
			if live then
				setTick(function(count: number): number
					return count + 1
				end)
			end
		end)
		return function()
			live = false
		end
	end)
	return now
end

-- Small pieces ---------------------------------------------------------------------------------------------------

local function bulleted(line: string): string
	return `{copy.bullet} {line}`
end

local function dimLine(line: string, order: number)
	return Kit.Text({ text = line, order = order, size = Theme.text.small, color = colors.textDim })
end

-- The buy button, the server's note for an item this player can't buy now, or the pill an item shows instead
-- ("Coming soon", "Owned").
local function BuyControl(props: {
	state: StoreModel.ItemState,
	label: string?,
	note: string?,
	style: Kit.ButtonStyle,
	disabled: boolean,
	order: number,
	onTap: () -> (),
})
	local label = props.label
	if props.state == "buy" and label ~= nil then
		return e(Kit.Button, {
			label = label,
			style = props.style,
			disabled = props.disabled,
			order = props.order,
			size = UDim2.new(1, 0, 0, card.buttonHeight),
			onTap = props.onTap,
		})
	elseif props.state == "blocked" then
		return Kit.Text({
			text = props.note or copy.unavailable,
			order = props.order,
			font = Theme.fonts.medium,
			color = colors.warning,
		})
	end
	local pill = StoreModel.pillText(props.state) or copy.comingSoon
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, card.pillHeight),
		BackgroundTransparency = 1,
	}, {
		Pill = Kit.Pill({
			text = pill,
			color = if props.state == "owned" then colors.success else colors.textDim,
		}),
	})
end

export type ItemCardProps = {
	order: number,
	eyebrow: string?, -- small accent line above the title ("One-time offer")
	title: string,
	detail: string?, -- an accent line under the title ("+3 bonus")
	lines: { string }?, -- dim lines (perks, what it gives)
	state: StoreModel.ItemState,
	label: string?, -- the buy button's words (StoreModel.buttonLabel)
	note: string?, -- why a blocked item can't be bought (StoreModel.noteText)
	primary: boolean?, -- the page's one accent button
	disabled: boolean,
	onBuy: () -> (),
}

-- One thing for sale: its name, what it gives, and the buy button (full width, a big target) or its pill.
function StoreCards.ItemCard(props: ItemCardProps)
	local children: { [string]: any } = {}
	local order = 0
	local function add(key: string, element: any)
		order += 1
		children[key] = element
	end
	local eyebrow = props.eyebrow
	if eyebrow ~= nil then
		add(
			"Eyebrow",
			Kit.Text({
				text = eyebrow,
				order = order + 1,
				size = Theme.text.small,
				font = Theme.fonts.bold,
				color = colors.accent,
			})
		)
	end
	add(
		"Title",
		Kit.Text({ text = props.title, order = order + 1, size = Theme.text.heading, font = Theme.fonts.bold })
	)
	local detail = props.detail
	if detail ~= nil then
		add("Detail", Kit.Text({ text = detail, order = order + 1, font = Theme.fonts.medium, color = colors.success }))
	end
	for index, line in props.lines or {} do
		add(`Line{index}`, dimLine(bulleted(line), order + 1))
	end
	add(
		"Buy",
		e(BuyControl, {
			state = props.state,
			label = props.label,
			note = props.note,
			style = if props.primary then "primary" else "secondary",
			disabled = props.disabled,
			order = order + 1,
			onTap = props.onBuy,
		})
	)
	return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, children)
end

-- Events ---------------------------------------------------------------------------------------------------------

local function eventBlock(event: StoreModel.Event, live: boolean, now: number, order: number, busy: string?)
	local children: { [string]: any } = {
		Tag = Kit.Text({
			text = StoreModel.eventTag(event, live),
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.bold,
			color = colors.accent,
		}),
		Title = Kit.Text({ text = event.title, order = 2, size = Theme.text.heading, font = Theme.fonts.bold }),
	}
	for index, line in StoreModel.eventLines(event) do
		children[`Line{index}`] = Kit.Text({ text = line, order = 2 + index, font = Theme.fonts.medium })
	end
	children.Countdown = Kit.Text({
		text = StoreModel.eventCountdown(event, now),
		order = 100,
		size = Theme.text.small,
		color = colors.textDim,
	})
	-- A limited drop on sale now: buy one here (Net BuyLimited; the server checks the supply, cash and garage).
	local cashPrice = event.cashPrice
	if cashPrice ~= nil and StoreModel.canBuyDrop(event, now) then
		local key = `drop:{event.id}`
		children.Buy = e(Kit.Button, {
			label = if busy == key then copy.dropBuying else string.format(copy.dropBuy, Economy.formatCash(cashPrice)),
			style = "primary",
			disabled = busy ~= nil,
			order = 101,
			size = UDim2.new(1, 0, 0, card.buttonHeight),
			onTap = function()
				StoreState.buyDrop(event.id)
			end,
		})
	end
	return Kit.Stack({ order = order, gap = StoreStyle.banner.gap }, children)
end

-- The events on now and the next one coming; nothing when there are none. `busy`: the request with the server.
function StoreCards.EventBanner(props: { events: { StoreModel.Event }, order: number, busy: string? })
	local now = useClock(function(at: number): number?
		return StoreModel.soonest(props.events, at)
	end)
	local live, upcoming = StoreModel.liveEvents(props.events, now)
	if #live == 0 and #upcoming == 0 then
		return nil
	end
	local blocks: { [string]: any } = {}
	for index, event in live do
		blocks[`Live_{event.id}`] = eventBlock(event, true, now, index, props.busy)
	end
	local nextEvent = upcoming[1]
	if nextEvent ~= nil then
		blocks[`Next_{nextEvent.id}`] = eventBlock(nextEvent, false, now, #live + 1, props.busy)
	end
	local banner = StoreStyle.banner
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = colors.panelRaised,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Theme.radius.card) }),
		Stripe = e("Frame", {
			Size = UDim2.new(0, banner.stripeWidth, 1, 0),
			BackgroundColor3 = colors.accent,
			BorderSizePixel = 0,
		}, {
			Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		}),
		Body = Kit.Stack({ gap = Theme.spacing.md, padding = banner.padding }, blocks),
	})
end

-- Loading and failure --------------------------------------------------------------------------------------------

function StoreCards.StatusPage(props: { loading: boolean, order: number })
	if props.loading then
		return Kit.Text({ text = copy.loading, order = props.order, color = colors.textDim })
	end
	return Kit.Stack({ order = props.order, gap = Theme.spacing.sm }, {
		Text = Kit.Text({ text = copy.failed, order = 1, color = colors.textDim }),
		Retry = e(Kit.Button, {
			label = copy.retry,
			style = "primary",
			order = 2,
			onTap = function()
				StoreState.refresh(true)
			end,
		}),
	})
end

-- Pages ----------------------------------------------------------------------------------------------------------

local function productCard(
	product: StoreModel.Product,
	busy: string?,
	order: number,
	extra: { eyebrow: string?, primary: boolean?, lines: { string }? }?
)
	local key = `product:{product.key}`
	local more = extra or {}
	return e(StoreCards.ItemCard, {
		order = order,
		eyebrow = more.eyebrow,
		title = StoreModel.packTitle(product),
		detail = StoreModel.packDetail(product),
		lines = more.lines,
		state = StoreModel.itemState(product),
		label = StoreModel.buttonLabel(product, busy == key),
		note = StoreModel.noteText(product),
		primary = more.primary,
		disabled = busy ~= nil,
		onBuy = function()
			StoreState.buyProduct(product.key)
		end,
	})
end

-- The one-time offers that are up for this player (StoreModel.offerCards: a moment happened, not bought yet).
local function offerCards(state: StoreState.State, order: number): { [string]: any }
	local cards: { [string]: any } = {}
	for index, entry in StoreModel.offerCards(state.store) do
		cards[`Offer_{entry.offer.id}`] = productCard(entry.product, state.busy, order + index, {
			eyebrow = copy.offerEyebrow,
			primary = true,
			lines = StoreModel.grantLines(entry.product.grants),
		})
	end
	return cards
end

export type CreditsPageProps = {
	state: StoreState.State,
	balance: number?, -- nil until the profile loads
	freeCar: boolean, -- the free first car is unused
}

function StoreCards.CreditsPage(props: CreditsPageProps)
	local state = props.state
	local children: { [string]: any } = {}

	local balance: { [string]: any } = {
		Label = Kit.Text({
			text = copy.balance,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Value = Kit.Text({
			text = if props.balance ~= nil then StoreModel.creditsText(props.balance) else "-",
			order = 2,
			size = Theme.text.price,
			font = Theme.fonts.bold,
		}),
	}
	if props.freeCar then
		balance.Free = Kit.Text({ text = copy.freeCar, order = 3, font = Theme.fonts.medium, color = colors.success })
	end
	children.Balance = Kit.Card({ order = 1, gap = Theme.spacing.xs, padding = card.padding }, balance)

	for key, offer in offerCards(state, 10) do
		children[key] = offer
	end

	-- The free daily credit for a rewarded ad: only while the server offers it and Roblox says an ad can play.
	if state.adReady then
		children.Ad = Kit.Card({ order = 20, gap = card.gap, padding = card.padding }, {
			Title = Kit.Text({ text = copy.adTitle, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
			Body = dimLine(copy.adBody, 2),
			Watch = e(Kit.Button, {
				label = if state.busy == "ad" then copy.adWatching else copy.adButton,
				disabled = state.busy ~= nil,
				order = 3,
				size = UDim2.new(1, 0, 0, card.buttonHeight),
				onTap = StoreState.watchAd,
			}),
		})
	end

	local packs = StoreModel.productsOf(state.store, { "credits" })
	if #packs > 0 then
		children.PacksTitle = Kit.SectionTitle({ text = copy.packsTitle, order = 30 })
		for index, product in packs do
			children[`Pack_{product.key}`] = productCard(product, state.busy, 30 + index)
		end
	end

	local uses: { [string]: any } = {
		Title = Kit.Text({ text = copy.usesTitle, order = 1, font = Theme.fonts.bold }),
	}
	for index, line in StoreModel.creditUses(DesignerModel.prices()) do
		uses[`Use{index}`] = dimLine(bulleted(line), 1 + index)
	end
	children.Uses = Kit.Card({ order = 80, gap = card.lineGap, padding = card.padding }, uses)
	children.Note = dimLine(copy.packNote, 81)
	return Kit.Stack({ order = 3, gap = Theme.spacing.md }, children)
end

local function ClubCard(props: { club: StoreModel.Club, busy: string?, order: number })
	local club = props.club
	local children: { [string]: any } = {
		Title = Kit.Text({
			text = club.name or copy.clubTitle,
			order = 1,
			size = Theme.text.heading,
			font = Theme.fonts.bold,
		}),
		Body = dimLine(copy.clubBody, 2),
	}
	for index, perk in StoreModel.clubLines(club) do
		children[`Perk{index}`] = dimLine(bulleted(perk), 2 + index)
	end
	if club.member then
		children.Member =
			Kit.Text({ text = copy.clubMember, order = 20, font = Theme.fonts.medium, color = colors.success })
	else
		children.Join = e(BuyControl, {
			state = StoreModel.itemState(club),
			label = StoreModel.clubButton(club, props.busy == "club"),
			note = copy.storeClosed, -- the club is on sale but can't be joined only while the store is closed
			style = "primary",
			disabled = props.busy ~= nil,
			order = 20,
			onTap = StoreState.joinClub,
		})
	end
	return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, children)
end

function StoreCards.PassesPage(props: { state: StoreState.State })
	local state = props.state
	local store = state.store
	local children: { [string]: any } = {}
	if store == nil then
		return Kit.Stack({ order = 3 }, children)
	end
	children.Club = e(ClubCard, { club = store.club, busy = state.busy, order = 1 })
	if #store.passes > 0 then
		children.Title = Kit.SectionTitle({ text = copy.passesTitle, order = 2 })
		children.Body = dimLine(copy.passesBody, 3)
		for index, pass in store.passes do
			local key = `pass:{pass.key}`
			children[`Pass_{pass.key}`] = e(StoreCards.ItemCard, {
				order = 3 + index,
				title = pass.name,
				lines = pass.perks,
				state = StoreModel.itemState(pass),
				label = StoreModel.buttonLabel(pass, state.busy == key),
				note = StoreModel.noteText(pass),
				disabled = state.busy ~= nil,
				onBuy = function()
					StoreState.buyPass(pass.key)
				end,
			})
		end
	end
	return Kit.Stack({ order = 3, gap = Theme.spacing.md }, children)
end

local function StreakCard(props: { streak: StoreModel.Streak?, busy: string?, order: number })
	local now = useClock(function(at: number): number?
		return StoreModel.streakStatus(props.streak, at).nextIn
	end)
	local status = StoreModel.streakStatus(props.streak, now)
	local children: { [string]: any } = {
		Title = Kit.Text({ text = copy.streakTitle, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = dimLine(copy.streakBody, 2),
	}
	if status.known and status.day > 0 then
		children.Day = Kit.Text({
			text = string.format(copy.streakDay, status.day),
			order = 3,
			font = Theme.fonts.medium,
			color = colors.success,
		})
	end
	local nextIn = status.nextIn
	if status.claimable then
		children.Claim = e(Kit.Button, {
			label = if props.busy == "streak" then copy.streakClaiming else copy.streakClaim,
			style = "primary",
			disabled = props.busy ~= nil,
			order = 4,
			onTap = StoreState.claimStreak,
		})
	elseif nextIn ~= nil then
		children.Next = Kit.Text({
			text = string.format(copy.streakNext, StoreModel.countdownText(nextIn)),
			order = 4,
			font = Theme.fonts.medium,
		})
	end
	return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, children)
end

-- One claim button on the Season Pass card.
local function claimButton(claim: StoreModel.SeasonClaim, format: string, busy: string?, order: number)
	local key = `season:{claim.track}`
	return e(Kit.Button, {
		label = if busy == key then copy.seasonClaiming else string.format(format, claim.tier, claim.text),
		style = if claim.track == "free" then "primary" else "secondary",
		disabled = busy ~= nil,
		order = order,
		size = UDim2.new(1, 0, 0, card.buttonHeight),
		onTap = function()
			StoreState.claimSeason(claim.tier, claim.track)
		end,
	})
end

-- The Season Pass (Config/Season): the tier and XP, the countdown, and a button for the next reward on each track.
local function SeasonCard(props: { input: StoreModel.SeasonInput, busy: string?, order: number })
	local nowAt = useClock(function(at: number): number?
		local view = StoreModel.seasonView(Season, props.input, at)
		return view.startsIn or view.endsIn
	end)
	local view = StoreModel.seasonView(Season, props.input, nowAt)
	if not view.show then
		return nil
	end
	local children: { [string]: any } = {
		Title = Kit.Text({ text = view.name, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = dimLine(copy.seasonBody, 2),
	}
	local startsIn, endsIn = view.startsIn, view.endsIn
	if startsIn ~= nil then
		children.When = Kit.Text({
			text = string.format(copy.startsIn, StoreModel.countdownText(startsIn)),
			order = 3,
			font = Theme.fonts.medium,
		})
		return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, children)
	end
	children.Tier = Kit.Text({
		text = string.format(copy.seasonTier, view.tier, view.tiers),
		order = 3,
		font = Theme.fonts.medium,
		color = colors.success,
	})
	local nextXp = view.nextXp
	children.Xp = dimLine(
		if nextXp ~= nil
			then string.format(copy.seasonXp, StoreModel.groupDigits(view.xp), StoreModel.groupDigits(nextXp))
			else string.format(copy.seasonTop, StoreModel.groupDigits(view.xp)),
		4
	)
	children.When = dimLine(
		if endsIn ~= nil then string.format(copy.endsIn, StoreModel.countdownText(endsIn)) else copy.seasonOver,
		5
	)
	local free, premium, locked = view.free, view.premiumClaim, view.premiumLocked
	if free ~= nil then
		children.Free = claimButton(free, copy.seasonClaim, props.busy, 6)
	end
	if premium ~= nil then
		children.Premium = claimButton(premium, copy.seasonPremiumClaim, props.busy, 7)
	elseif locked ~= nil then
		children.Locked = dimLine(string.format(copy.seasonLocked, locked.tier, locked.text), 7)
	end
	if free == nil and premium == nil then
		children.Nothing = dimLine(copy.seasonNothing, 8)
	end
	return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, children)
end

local function InviteCard(props: { order: number })
	return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, {
		Title = Kit.Text({ text = copy.inviteTitle, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = dimLine(copy.inviteBody, 2),
		Invite = e(Kit.Button, { label = copy.invite, order = 3, onTap = StoreState.invite }),
	})
end

local function PrivateServersCard(props: { member: boolean?, canPrompt: boolean, order: number })
	local children: { [string]: any } = {
		Title = Kit.Text({ text = copy.privateTitle, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
		Body = dimLine(copy.privateBody, 2),
	}
	if props.member == true then
		children.Member =
			Kit.Text({ text = copy.plusMember, order = 3, font = Theme.fonts.medium, color = colors.success })
	elseif props.canPrompt then
		children.Prompt = Kit.Text({ text = copy.plusPrompt, order = 3, font = Theme.fonts.medium })
		children.Plus = e(Kit.Button, { label = copy.plusButton, order = 4, onTap = StoreState.getPlus })
	end
	return Kit.Card({ order = props.order, gap = card.gap, padding = card.padding }, children)
end

function StoreCards.MorePage(props: { state: StoreState.State })
	local state = props.state
	local children: { [string]: any } = {
		Streak = e(StreakCard, { streak = state.streak, busy = state.busy, order = 1 }),
		Season = e(SeasonCard, { input = state.season, busy = state.busy, order = 2 }),
	}
	if state.invite == "yes" then
		children.Invite = e(InviteCard, { order = 3 })
	end
	children.Private = e(PrivateServersCard, {
		member = state.plusMember,
		canPrompt = state.plusAvailable,
		order = 4,
	})

	local sections: { { kinds: { StoreModel.Kind }, title: string, body: string?, withLines: boolean } } = {
		{ kinds = { "cash" }, title = copy.cashTitle, body = copy.cashBody, withLines = false },
		{ kinds = { "slot" }, title = copy.slotTitle, body = nil, withLines = true },
		{ kinds = { "cosmetic" }, title = copy.cosmeticsTitle, body = copy.cosmeticsBody, withLines = true },
	}
	local order = 10
	for sectionIndex, section in sections do
		local products = StoreModel.productsOf(state.store, section.kinds)
		if #products > 0 then
			order += 1
			children[`Title{sectionIndex}`] = Kit.SectionTitle({ text = section.title, order = order })
			local body = section.body
			if body ~= nil then
				order += 1
				children[`Body{sectionIndex}`] = dimLine(body, order)
			end
			for _, product in products do
				order += 1
				children[`Product_{product.key}`] = productCard(product, state.busy, order, {
					lines = if section.withLines then StoreModel.grantLines(product.grants) else nil,
				})
			end
		end
	end
	return Kit.Stack({ order = 3, gap = Theme.spacing.md }, children)
end

return StoreCards
