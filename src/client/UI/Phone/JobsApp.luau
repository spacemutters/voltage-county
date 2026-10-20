--!strict
-- The phone's Jobs app (docs/phase-6-contracts.md "Client"; PLAN.md Phase 6). It reads Controllers/
-- JobController (the server's last JobUpdate plus the car the player is in) and asks it for everything; the
-- server decides every outcome.
--
--   the job      while one runs, at the top: its title and pay estimate, "Stop 2 of 4" with a bar, what to do
--                at that stop, and the distance and time left (amber, then red, as time runs short). Show route
--                points the GPS at the stop again; Cancel job asks first (no pay, and a short wait before the
--                next job of that type, Config/Jobs cooldownSec).
--   job types    every type in Config/Jobs order, each with the player's level, XP toward the next level and
--                what that level unlocks (JobUpdate `progress`, Config/Jobs levels), then:
--                  with no job running, the offers for the car (title, where, pay estimate, distance and stops,
--                  an XL tag, Accept), or why there are none: the server's reason (no car, a test drive, a
--                  cooldown), or for a car whose class can't do the type, which classes can (Config/Jobs classes,
--                  Config/Classes names).
--   refresh      "Find new offers" asks the server again. Opening the app, and changing cars while it's open,
--                ask on their own (quietly; JobController limits how often).
--   towing and   (Phase 8, docs/phase-8-contracts.md "Client UI") the same sections, each with a line on how the job
--   freight      works (back up, tap Couple, haul it to the yard or the next depot). A job that needs a license
--                (Config/Jobs JobDef.license: freight) shows the license card under its header: owned, or its price,
--                the XP gate (a level in delivery or towing, Config/Jobs freightLicense) with the player's best XP
--                toward it, and Buy license, which asks first ("Buy the freight license?") and then sends Net
--                BuyLicense through Controllers/HitchInputController. Whether the player holds it: what that
--                controller knows (bought this session, or the profile snapshot once it carries licenses), or what
--                the server's JobUpdate implies (offers of that type, or it being open to them).
--
-- While a request is with the server every button is disabled and the one that was tapped says what it's doing,
-- so nothing can be tapped twice. PhoneController draws this with no props; its state comes from JobController
-- (and, for the license, HitchInputController and ProfileController).

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Jobs = require(ReplicatedStorage.Shared.Config.Jobs)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local Controllers = script.Parent.Parent.Parent.Controllers
local GpsController = require(Controllers.GpsController)
local HitchInputController = require(Controllers.HitchInputController)
local JobController = require(Controllers.JobController)
local ProfileController = require(Controllers.ProfileController)

local e = React.createElement
local colors = Theme.colors

type View = JobController.View
type Offer = JobController.Offer
type Level = JobController.Level
type JobType = JobController.JobType

local SECONDS_PER_MINUTE = 60

-- Sizes (px at UI scale 1) that Theme and PhoneConfig don't already give.
local LAYOUT = {
	barHeight = 6, -- the stop and XP bars
	payWidth = 92, -- room kept on a card's title row for the pay ("$12,345" at Theme.text.price)
	payHeight = 28, -- the pay's line, at Theme.text.price
	headerHeight = 26, -- a job type's name and level row
	metaHeight = 22, -- an offer's distance and stops row (the XL tag's height)
	nameGap = 2, -- between a title and the line under it
}

-- What players read. %s and %d are filled in as noted.
local TEXT = {
	loading = "Looking for jobs...",
	-- The job in progress.
	onJob = "On the job",
	stopOf = "Stop %d of %d",
	showRoute = "Show route",
	cancel = "Cancel job",
	cancelling = "Cancelling...",
	oneAtATime = "Finish or cancel this job to take another.",
	confirmTitle = "Cancel this job?",
	confirmBody = "You won't be paid for it, and you'll wait %s before your next %s job.", -- wait, job name
	keep = "Keep going",
	confirmCancel = "Cancel job",
	seconds = "%d seconds",
	oneMinute = "1 minute",
	minutes = "%d minutes",
	-- Levels.
	level = "Level %d",
	toNext = "%s / %s XP to level %d", -- XP, next level's XP, next level
	topLevel = "Top level · %s XP", -- XP
	xpOnly = "%s XP",
	paysMore = "Pays x%s", -- the level's pay multiplier, "1.05"
	multiplier = "%.2f", -- then trailing zeros are dropped: "1.05", "1.1", "1"
	separator = " · ", -- between the level and its pay multiplier
	unlocks = "Level %d unlocks %s", -- level, unlock names (Config/Jobs unlockNames)
	listJoin = ", ",
	-- Offers.
	accept = "Accept",
	accepting = "Accepting...",
	refresh = "Find new offers",
	refreshing = "Looking...",
	noOffers = "No offers right now. Check again in a moment.",
	noCar = "Get in one of your cars to see jobs for it.",
	cantDo = "Your %s can't do %s jobs.", -- car name, job name
	worksWith = "Cars that can: %s.", -- class names
	bonus = "Your %s earns extra on these.", -- car name
	oneStop = "1 stop",
	stops = "%d stops",
	meta = "%s · %s", -- distance, stops
	xl = "XL",
	-- How a job type works, under its name (Phase 8 types; others have none).
	about = {
		towing = "Back your pickup or tow truck up to a broken-down car, tap Couple, and tow it to the County Tow Yard.",
		freight = "Back your semi up to the trailer at a depot, tap Couple, and haul it to the next depot. Long hauls "
			.. "round the County Loop pay the most.",
	} :: { [string]: string },
	-- A job license (Config/Jobs licenses).
	licenseName = "Freight license", -- when Config/Jobs has no display name for it
	licenseAbout = "Freight jobs need it. Buy it once and it's yours for good.",
	licenseOwned = "It's yours: freight jobs show up whenever you drive a semi.",
	owned = "Owned",
	gateLevel = "Reach level %d in %s (%s XP).", -- level, job names, XP
	gateXp = "Earn %s XP in %s.", -- XP, job names
	gateBest = "Your best: %s XP.", -- XP
	gateMet = "You've earned the XP for it.",
	cashShort = "You need %s more.", -- cash
	buyLicense = "Buy license",
	buying = "Buying...",
	confirmBuyTitle = "Buy the %s?", -- license name, lower case
	confirmBuyBody = "It costs %s and it's yours for good.", -- price
	notNow = "Not now",
	confirmBuy = "Buy for %s", -- price
	namesOr = " or ", -- between job names: "Delivery or Towing"
}

-- The license a job needs when Config/Jobs names none (docs/phase-8-contracts.md: freight needs `freight`), and
-- the job types whose XP counts toward it when Config/Jobs lists none (delivery or towing).
local DEFAULT_LICENSE = { job = "freight", id = "freight", jobTypes = { "delivery", "towing" } }

-- Small helpers -------------------------------------------------------------------------------------------------

-- "12,345": whole numbers with a thousands separator (Economy.formatCash without the symbol).
local function grouped(value: number): string
	local cash = Economy.formatCash(value)
	local symbol = Economy.display.symbol
	local at = string.find(cash, symbol, 1, true)
	if at == nil then
		return cash
	end
	return string.sub(cash, 1, at - 1) .. string.sub(cash, at + #symbol)
end

-- "20 seconds", "1 minute", "2 minutes".
local function waitText(seconds: number): string
	if seconds < SECONDS_PER_MINUTE then
		return string.format(TEXT.seconds, math.ceil(seconds))
	end
	local minutes = math.ceil(seconds / SECONDS_PER_MINUTE)
	return if minutes == 1 then TEXT.oneMinute else string.format(TEXT.minutes, minutes)
end

-- "1.05": a multiplier with as few decimals as it needs.
local function multiplierText(value: number): string
	local text = string.format(TEXT.multiplier, value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text
end

-- A bar of `fill` (0..1) on the track color.
local function Bar(props: { order: number, fill: number, color: Color3? })
	local fill = math.clamp(props.fill, 0, 1)
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, LAYOUT.barHeight),
		BackgroundColor3 = colors.track,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Fill = if fill > 0
			then e("Frame", {
				Size = UDim2.fromScale(fill, 1),
				BackgroundColor3 = props.color or colors.accent,
				BorderSizePixel = 0,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			})
			else nil,
	})
end

-- A title (left, cut short when long) with the pay on its right in the accent, never cut short.
local function TitleRow(props: { order: number, title: string, subtitle: string?, pay: number? })
	local pay = props.pay
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		Names = Kit.Stack({ gap = LAYOUT.nameGap }, {
			Title = Kit.Text({ text = props.title, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
			Subtitle = if props.subtitle and props.subtitle ~= ""
				then Kit.Text({ text = props.subtitle, order = 2, color = colors.textDim })
				else nil,
			Room = e("UIPadding", {
				PaddingRight = UDim.new(0, if pay then LAYOUT.payWidth + Theme.spacing.sm else 0),
			}),
		}),
		Pay = if pay
			then e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromOffset(LAYOUT.payWidth, LAYOUT.payHeight),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.bold,
				Text = Economy.formatCash(pay),
				TextColor3 = colors.accent,
				TextSize = Theme.text.price,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			else nil,
	})
end

-- A one-line row of text with an optional tag (the XL pill) after it.
local function MetaRow(props: { order: number, text: string, tag: string? })
	return e("Frame", {
		LayoutOrder = props.order,
		Size = UDim2.new(1, 0, 0, LAYOUT.metaHeight),
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Theme.spacing.sm),
		}),
		Text = e("TextLabel", {
			LayoutOrder = 1,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			FontFace = Theme.fonts.medium,
			Text = props.text,
			TextColor3 = colors.textDim,
			TextSize = Theme.text.small,
		}),
		Tag = if props.tag then Kit.Pill({ text = props.tag, order = 2 }) else nil,
	})
end

-- The text color for how much time is left.
local function alertColor(alert: JobController.TimeAlert): Color3
	if alert == "critical" then
		return colors.danger
	elseif alert == "low" then
		return colors.warning
	end
	return colors.textDim
end

-- The job in progress ----------------------------------------------------------------------------------------------

local function ActiveJob(props: { view: View, order: number, onAskCancel: () -> () })
	local view = props.view
	local job = view.job :: JobController.Job
	local stop = job.stops[job.stopIndex]
	local busy = view.busy
	local cancelling = busy ~= nil and busy.action == "cancel"
	local hud = JobController.hudFor(job, view.secondsLeft, view.distanceText, view.near)
	local stopCount = #job.stops
	return Kit.Card({ order = props.order, gap = Theme.spacing.sm }, {
		Eyebrow = Kit.Text({
			text = TEXT.onJob,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Title = e(TitleRow, { order = 2, title = job.title, pay = job.estPay }),
		-- "Stop 2 of 4", with the XL tag on an XL fare, and a bar of the stops done.
		Step = MetaRow({
			order = 3,
			text = string.format(TEXT.stopOf, job.stopIndex, stopCount),
			tag = if job.xl then TEXT.xl else nil,
		}),
		Progress = e(Bar, { order = 4, fill = (job.stopIndex - 1) / math.max(stopCount, 1) }),
		Stop = if stop
			then Kit.Text({
				text = JobController.stopText(stop),
				order = 6,
				size = Theme.text.body,
				font = Theme.fonts.bold,
			})
			else nil,
		Status = if hud.status
			then Kit.Text({
				text = hud.status,
				order = 7,
				font = Theme.fonts.medium,
				color = if view.near then colors.accent else alertColor(hud.alert or "normal"),
			})
			else nil,
		Buttons = Kit.ButtonRow({
			order = 8,
			count = 2,
			buttons = {
				Route = e(Kit.Button, {
					label = TEXT.showRoute,
					disabled = busy ~= nil,
					order = 1,
					size = UDim2.fromScale(1, 1),
					onTap = JobController.routeToStop,
				}),
				Cancel = e(Kit.Button, {
					label = if cancelling then TEXT.cancelling else TEXT.cancel,
					style = "dangerText",
					disabled = busy ~= nil,
					order = 2,
					size = UDim2.fromScale(1, 1),
					onTap = props.onAskCancel,
				}),
			},
		}),
	})
end

-- A question over the app, like the garage's sell confirm: a title, a line about it, the safe choice on the left
-- and the action on the right. Tapping outside is the same as the safe choice. While `busy` both wait.
local function ConfirmSheet(props: {
	title: string,
	body: string?,
	keepLabel: string,
	confirmLabel: string,
	confirmStyle: Kit.ButtonStyle,
	busy: boolean,
	onKeep: () -> (),
	onConfirm: () -> (),
})
	local busy = props.busy
	local fade = Kit.useAppear(false)
	local keepRef = React.useRef(nil :: GuiObject?)
	local scrimTransparency = colors.scrimTransparency
	local sheet = PhoneConfig.sheet

	-- A gamepad (the only input that has a selected object) moves to the safe choice.
	React.useEffect(function()
		if GuiService.SelectedObject ~= nil and keepRef.current then
			GuiService.SelectedObject = keepRef.current
		end
	end, {})

	local body = props.body
	return e("Frame", {
		ZIndex = 5,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Scrim = e("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = colors.scrim,
			BackgroundTransparency = fade:map(function(value: number): number
				return scrimTransparency + (1 - scrimTransparency) * value
			end),
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			[React.Event.Activated] = function()
				if not busy then
					props.onKeep()
				end
			end,
		}),
		Sheet = e("Frame", {
			ZIndex = 2,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = fade:map(function(value: number): UDim2
				return UDim2.new(0.5, 0, 1, -sheet.padding + value * sheet.slideOffset)
			end),
			Size = UDim2.new(1, -2 * sheet.padding, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Active = true,
		}, {
			Card = Kit.Card({ gap = Theme.spacing.md, padding = Theme.spacing.lg }, {
				Title = Kit.Text({
					text = props.title,
					order = 1,
					size = Theme.text.heading,
					font = Theme.fonts.bold,
				}),
				Body = if body then Kit.Text({ text = body, order = 2, color = colors.textDim }) else nil,
				Buttons = Kit.ButtonRow({
					order = 3,
					count = 2,
					buttons = {
						Keep = e(Kit.Button, {
							label = props.keepLabel,
							disabled = busy,
							order = 1,
							size = UDim2.fromScale(1, 1),
							buttonRef = keepRef,
							onTap = props.onKeep,
						}),
						Confirm = e(Kit.Button, {
							label = props.confirmLabel,
							style = props.confirmStyle,
							disabled = busy,
							order = 2,
							size = UDim2.fromScale(1, 1),
							onTap = props.onConfirm,
						}),
					},
				}),
			}),
		}),
	})
end

-- "Cancel this job?": no pay, and a wait before the next job of its type. Keep going is the safe choice.
local function CancelConfirm(props: { view: View, onKeep: () -> (), onCancel: () -> () })
	local view = props.view
	local job = view.job :: JobController.Job
	local info = JobController.jobType(job.type)
	local busy = view.busy
	local cancelling = busy ~= nil and busy.action == "cancel"
	return e(ConfirmSheet, {
		title = TEXT.confirmTitle,
		body = if info
			then string.format(TEXT.confirmBody, waitText(info.cooldownSec), string.lower(info.name))
			else nil,
		keepLabel = TEXT.keep,
		confirmLabel = if cancelling then TEXT.cancelling else TEXT.confirmCancel,
		confirmStyle = "danger",
		busy = busy ~= nil,
		onKeep = props.onKeep,
		onConfirm = props.onCancel,
	})
end

-- Job types ------------------------------------------------------------------------------------------------------

-- "Level 3 unlocks One more job offer": what a level adds (Config/Jobs levels and unlockNames), or nil when it
-- adds nothing but pay.
local function nextUnlocks(jobType: string, level: number): any
	local ladders = (Jobs.levels :: any) :: { [string]: { Jobs.Level } }
	local ladder = ladders[jobType]
	local rung = if ladder then ladder[level] else nil
	if rung == nil or #rung.unlocks == 0 then
		return nil
	end
	local names: { string } = {}
	for _, id in rung.unlocks do
		table.insert(names, Jobs.unlockNames[id] or id)
	end
	return Kit.Text({
		text = string.format(TEXT.unlocks, level, table.concat(names, TEXT.listJoin)),
		order = 4,
		size = Theme.text.small,
		color = colors.textDim,
	})
end

-- A job type's name with the player's level on the right, the bar toward the next level, the XP, and what the
-- next level unlocks.
local function TypeHeader(props: { info: JobType, level: Level?, order: number })
	local level = props.level
	local levelNumber = if level then level.level else nil
	local xpLine: string? = nil
	if level ~= nil then
		local nextXp = level.nextXp
		if levelNumber == nil then
			xpLine = string.format(TEXT.xpOnly, grouped(level.xp))
		elseif nextXp ~= nil then
			xpLine = string.format(TEXT.toNext, grouped(level.xp), grouped(nextXp), levelNumber + 1)
		else
			xpLine = string.format(TEXT.topLevel, grouped(level.xp))
		end
	end
	-- "Level 2 · Pays x1.05" (the multiplier only once it's more than x1).
	local multiplier = if level then level.multiplier else nil
	local right: string? = nil
	if levelNumber ~= nil then
		local levelText = string.format(TEXT.level, levelNumber)
		right = if multiplier ~= nil and multiplier > 1
			then levelText .. TEXT.separator .. string.format(TEXT.paysMore, multiplierText(multiplier))
			else levelText
	end
	return Kit.Stack({ order = props.order, gap = Theme.spacing.xs }, {
		Top = e("Frame", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, LAYOUT.headerHeight),
			BackgroundTransparency = 1,
		}, {
			Name = e("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.bold,
				Text = props.info.name,
				TextColor3 = colors.text,
				TextSize = Theme.text.heading,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Level = if right
				then e("TextLabel", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromScale(0, 1),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundTransparency = 1,
					FontFace = Theme.fonts.bold,
					Text = right,
					TextColor3 = colors.accent,
					TextSize = Theme.text.small,
					TextXAlignment = Enum.TextXAlignment.Right,
				})
				else nil,
		}),
		Bar = if level and levelNumber ~= nil then e(Bar, { order = 2, fill = level.progress }) else nil,
		Xp = if xpLine
			then Kit.Text({ text = xpLine, order = 3, size = Theme.text.small, color = colors.textDim })
			else nil,
		Unlocks = if levelNumber ~= nil
				and level
				and level.nextXp ~= nil
			then nextUnlocks(props.info.id, levelNumber + 1)
			else nil,
	})
end

-- One offer: its title and where it starts, the pay estimate, distance and stops, and Accept.
local function OfferCard(props: { offer: Offer, view: View, order: number })
	local offer = props.offer
	local busy = props.view.busy
	local accepting = busy ~= nil and busy.action == "accept" and busy.offerId == offer.id
	local stops = if offer.stops == 1 then TEXT.oneStop else string.format(TEXT.stops, offer.stops)
	local distance = GpsController.distanceText(offer.distance, props.view.units)
	return Kit.Card({ order = props.order }, {
		Title = e(TitleRow, { order = 1, title = offer.title, subtitle = offer.subtitle, pay = offer.pay }),
		Meta = MetaRow({
			order = 2,
			text = string.format(TEXT.meta, distance, stops),
			tag = if offer.xl then TEXT.xl else nil,
		}),
		Accept = e(Kit.Button, {
			label = if accepting then TEXT.accepting else TEXT.accept,
			style = "primary",
			disabled = busy ~= nil,
			order = 3,
			onTap = function()
				task.spawn(JobController.accept, offer.id)
			end,
		}),
	})
end

-- A note card: why a job type has no offers.
local function Note(props: { order: number, lines: { string } })
	local children: { [string]: any } = {}
	for index, line in props.lines do
		children[`Line{index}`] = Kit.Text({
			text = line,
			order = index,
			color = if index == 1 then colors.text else colors.textDim,
		})
	end
	return Kit.Card({ order = props.order, gap = Theme.spacing.xs }, children)
end

-- The reason every job type shares, when they all have no offers for the same reason (no car, a test drive):
-- said once at the top instead of under each type.
local function sharedReason(view: View, types: { JobType }): string?
	local shared: string? = nil
	for _, info in types do
		local availability = view.availability[info.id]
		if availability == nil or availability.ok or availability.reason == nil then
			return nil
		end
		if shared ~= nil and shared ~= availability.reason then
			return nil
		end
		shared = availability.reason
	end
	return shared
end

-- What shows under a job type with no job running: its offers, or why there are none.
local function typeBody(info: JobType, view: View, shared: string?, order: number): { [string]: any }
	local children: { [string]: any } = {}
	local car = view.car
	local availability = view.availability[info.id]
	local classes = string.format(TEXT.worksWith, JobController.classNames(info.classes))

	-- The car's class can't do this type: say which classes can (the client knows the car and Config/Jobs).
	if car ~= nil and not JobController.canDo(info, car.classId) then
		children[`Note_{info.id}`] = Note({
			order = order,
			lines = { string.format(TEXT.cantDo, car.name, string.lower(info.name)), classes },
		})
		return children
	end
	-- The server says there are none, and why (a cooldown, no car, a test drive). A reason every type shares is
	-- already at the top, so only the classes show here.
	if availability ~= nil and not availability.ok then
		local reason = availability.reason
		local lines = if reason ~= nil and reason ~= shared then { reason } else { classes }
		children[`Note_{info.id}`] = Note({ order = order, lines = lines })
		return children
	end
	if car == nil and availability == nil then
		children[`Note_{info.id}`] = Note({ order = order, lines = { classes } })
		return children
	end

	if JobController.earnsBonus(info, car) and car ~= nil then
		children[`Bonus_{info.id}`] = Kit.Text({
			text = string.format(TEXT.bonus, car.name),
			order = order,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.accent,
		})
	end
	local count = 0
	for _, offer in view.offers do
		if offer.type == info.id then
			count += 1
			children[`Offer_{offer.id}`] = e(OfferCard, { offer = offer, view = view, order = order + count })
		end
	end
	if count == 0 then
		children[`Note_{info.id}`] = Note({
			order = order + 1,
			lines = { if view.loaded then TEXT.noOffers else TEXT.loading },
		})
	end
	return children
end

-- Licenses (Phase 8) ----------------------------------------------------------------------------------------------

-- A job license as the app shows it (Config/Jobs licenses / freightLicense, read loosely so a missing field never
-- breaks the phone).
type License = {
	id: string, -- PlayerData.jobs.licenses key, and Net BuyLicense's `license`
	name: string, -- "Freight license"
	xpRequired: number?, -- XP in any one of jobTypes; nil: no gate known
	level: number?, -- the job level that XP is
	jobTypes: { string },
	price: number,
}

-- What the app knows about the player and a license right now.
type LicenseState = {
	known: boolean, -- HitchInputController knows they hold it (bought this session, or in their profile)
	busy: boolean, -- a BuyLicense is with the server
	cash: number?, -- the player's cash (ProfileController), nil until it loads
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

-- The license job type `jobType` needs, or nil: Config/Jobs JobDef.license with its Config/Jobs licenses entry
-- (DEFAULT_LICENSE when Config/Jobs has none yet).
local function licenseFor(jobType: string): License?
	local jobs = Jobs :: any
	local def = if type(jobs.types) == "table" then jobs.types[jobType] else nil
	local id: string? = if type(def) == "table" and type(def.license) == "string" then def.license else nil
	if id == nil and jobType == DEFAULT_LICENSE.job then
		id = DEFAULT_LICENSE.id
	end
	if id == nil then
		return nil
	end
	local rule = if type(jobs.licenses) == "table" then jobs.licenses[id] else nil
	if type(rule) ~= "table" and id == DEFAULT_LICENSE.id then
		rule = jobs.freightLicense
	end
	if type(rule) ~= "table" then
		rule = {}
	end
	local jobTypes: { string } = {}
	if type(rule.jobTypes) == "table" then
		for _, value in rule.jobTypes do
			if type(value) == "string" then
				table.insert(jobTypes, value)
			end
		end
	end
	if #jobTypes == 0 then
		jobTypes = table.clone(DEFAULT_LICENSE.jobTypes)
	end
	return {
		id = id,
		name = if type(rule.displayName) == "string" then rule.displayName else TEXT.licenseName,
		xpRequired = if finite(rule.xpRequired) then rule.xpRequired else nil,
		level = if finite(rule.level) then rule.level else nil,
		jobTypes = jobTypes,
		price = if finite(rule.price) then rule.price else Economy.freightLicensePrice,
	}
end

-- Whether the player holds license `licenseId`, which `jobType` needs: what the server's JobUpdate says
-- (`licenses`, sent with every update) or a purchase that just worked; before the server has said,
-- HitchInputController's knowledge (bought this session, or in the profile) or what JobUpdate implies (offers of
-- that type, the type open to them, or such a job running: the server only offers and starts them with it).
local function holdsLicense(view: View, state: LicenseState, jobType: string, licenseId: string): boolean
	local held = view.licenses[licenseId]
	if held ~= nil then
		return held or state.known
	end
	if state.known then
		return true
	end
	local availability = view.availability[jobType]
	if availability ~= nil and availability.ok then
		return true
	end
	for _, offer in view.offers do
		if offer.type == jobType then
			return true
		end
	end
	local job = view.job
	return job ~= nil and job.type == jobType
end

-- The player's most XP in any job type that counts toward the license, or nil before their levels arrive.
local function bestXp(view: View, license: License): number?
	local best: number? = nil
	for _, jobType in license.jobTypes do
		local level = view.levels[jobType]
		if level ~= nil then
			best = math.max(best or 0, level.xp)
		end
	end
	return best
end

-- "Delivery or Towing": the job types' names (Config/Jobs), in order.
local function jobNames(jobTypes: { string }): string
	local names: { string } = {}
	for _, id in jobTypes do
		local info = JobController.jobType(id)
		table.insert(names, if info then info.name else id)
	end
	return table.concat(names, TEXT.namesOr)
end

-- The license card under a job type's name: owned, or its price, what it takes (the XP gate, with the player's
-- best XP toward it and a bar), and Buy license (waiting while the XP or the cash is short, as far as the client
-- knows; the server checks both again).
local function LicenseCard(props: {
	view: View,
	license: License,
	state: LicenseState,
	owned: boolean,
	order: number,
	onAskBuy: () -> (),
})
	local license = props.license
	local state = props.state
	if props.owned then
		return Kit.Card({ order = props.order, gap = Theme.spacing.sm }, {
			Title = e(TitleRow, { order = 1, title = license.name, subtitle = TEXT.licenseOwned }),
			Owned = Kit.Pill({ text = TEXT.owned, order = 2, color = colors.success }),
		})
	end

	local required = license.xpRequired
	local best = bestXp(props.view, license)
	-- Short of the XP, as far as the client knows (before the levels arrive the server decides alone).
	local xpShort = required ~= nil and best ~= nil and best < required
	local gateLine: string? = nil
	if required ~= nil then
		local names = jobNames(license.jobTypes)
		gateLine = if license.level ~= nil
			then string.format(TEXT.gateLevel, license.level, names, grouped(required))
			else string.format(TEXT.gateXp, grouped(required), names)
	end
	local cash = state.cash
	local short = if cash ~= nil then license.price - cash else 0
	local busy = state.busy
	return Kit.Card({ order = props.order, gap = Theme.spacing.sm }, {
		Title = e(TitleRow, { order = 1, title = license.name, subtitle = TEXT.licenseAbout, pay = license.price }),
		Gate = if gateLine
			then Kit.Text({ text = gateLine, order = 2, size = Theme.text.small, color = colors.textDim })
			else nil,
		Progress = if required ~= nil
				and best ~= nil
				and xpShort
			then e(Bar, { order = 3, fill = best / math.max(required, 1) })
			else nil,
		Best = if required ~= nil and best ~= nil
			then Kit.Text({
				text = if xpShort then string.format(TEXT.gateBest, grouped(best)) else TEXT.gateMet,
				order = 4,
				size = Theme.text.small,
				font = Theme.fonts.medium,
				color = if xpShort then colors.textDim else colors.success,
			})
			else nil,
		Short = if not xpShort and short > 0
			then Kit.Text({
				text = string.format(TEXT.cashShort, Economy.formatCash(short)),
				order = 5,
				size = Theme.text.small,
				font = Theme.fonts.medium,
				color = colors.warning,
			})
			else nil,
		Buy = e(Kit.Button, {
			label = if busy then TEXT.buying else TEXT.buyLicense,
			style = "primary",
			disabled = busy or xpShort or short > 0,
			order = 6,
			onTap = props.onAskBuy,
		}),
	})
end

-- "Buy the freight license?": the price, then Buy for $25,000. Not now is the safe choice.
local function LicenseConfirm(props: { license: License, busy: boolean, onKeep: () -> (), onBuy: () -> () })
	local license = props.license
	local price = Economy.formatCash(license.price)
	return e(ConfirmSheet, {
		title = string.format(TEXT.confirmBuyTitle, string.lower(license.name)),
		body = string.format(TEXT.confirmBuyBody, price),
		keepLabel = TEXT.notNow,
		confirmLabel = if props.busy then TEXT.buying else string.format(TEXT.confirmBuy, price),
		confirmStyle = "primary",
		busy = props.busy,
		onKeep = props.onKeep,
		onConfirm = props.onBuy,
	})
end

-- What the app knows about `id` and the player's cash, redrawn whenever HitchInputController says it may have
-- changed (a purchase, or a new profile snapshot).
local function useLicense(id: string?): LicenseState
	local function read(): LicenseState
		local profile = ProfileController.get()
		return {
			known = id ~= nil and HitchInputController.licenseKnown(id),
			busy = HitchInputController.licenseBusy() ~= nil,
			cash = if profile then profile.cash else nil,
		}
	end
	local state, setState = React.useState(read)
	React.useEffect(function()
		local live = true
		local connection = HitchInputController.onLicenseChanged:Connect(function()
			if live then
				setState(read())
			end
		end)
		setState(read())
		return function()
			live = false
			connection:Disconnect()
		end
	end, { id } :: { any })
	return state
end

-- The app ----------------------------------------------------------------------------------------------------------

-- The latest JobController view, redrawn whenever it changes.
local function useJobs(): View
	local state, setState = React.useState(JobController.get)
	React.useEffect(function()
		local live = true
		local connection = JobController.onChanged:Connect(function(view: View)
			if live then
				setState(view)
			end
		end)
		setState(JobController.get())
		return function()
			live = false
			connection:Disconnect()
		end
	end, {})
	return state
end

-- Offers rows are numbered in steps of this per job type, so every type's rows stay together and in order.
local ORDER_STEP = 1000

local function JobsApp(_props: {})
	local view = useJobs()
	local types = JobController.jobTypes()
	-- The license some job type needs (Config/Jobs: today only freight's), and what the app knows about it.
	local licensed: { [string]: License } = {}
	local licenseId: string? = nil
	for _, info in types do
		local license = licenseFor(info.id)
		if license ~= nil then
			licensed[info.id] = license
			licenseId = licenseId or license.id
		end
	end
	local licenseState = useLicense(licenseId)
	local confirming, setConfirming = React.useState(false)
	local buying, setBuying = React.useState(nil :: License?) -- the license whose buy confirm is showing
	local live = React.useRef(true)
	React.useEffect(function()
		live.current = true
		return function()
			live.current = false
		end
	end, {})

	-- Fresh offers when the app opens, when the car changes, and when a job ends (quietly, and not too often).
	local car = view.car
	local carKey = if car then `{car.vehicleId}/{car.seats}` else ""
	local running = view.job ~= nil
	React.useEffect(function()
		if not running then
			task.spawn(JobController.refresh, true)
		end
	end, { carKey, running } :: { any })

	-- A confirm belongs to the job it was asked about: a job ending (or a new one starting) puts it away.
	local job = view.job
	local jobId = if job then job.id else nil
	React.useEffect(function()
		setConfirming(false)
	end, { jobId } :: { any })

	-- A job starting puts the buy confirm away (the license cards hide while a job runs).
	React.useEffect(function()
		if jobId ~= nil then
			setBuying(nil)
		end
	end, { jobId } :: { any })

	local showConfirm = confirming and job ~= nil
	local shared = if job == nil then sharedReason(view, types) else nil
	local anyOpen = false -- some job type has offers for the player (the server says so)
	for _, availability in view.availability do
		anyOpen = anyOpen or availability.ok
	end
	local children: { [string]: any } = {}
	local busy = view.busy

	if job ~= nil then
		children.Active = ActiveJob({
			view = view,
			order = 1,
			onAskCancel = function()
				setConfirming(true)
			end,
		})
		children.OneAtATime = Kit.Text({
			text = TEXT.oneAtATime,
			order = 2,
			size = Theme.text.small,
			color = colors.textDim,
		})
	elseif not view.loaded then
		children.Loading = Kit.Text({ text = TEXT.loading, order = 1, color = colors.textDim })
	elseif shared ~= nil or (car == nil and not anyOpen) then
		children.Shared = Note({ order = 1, lines = { shared or TEXT.noCar } })
	end

	for index, info in types do
		local base = index * ORDER_STEP
		children[`Header_{info.id}`] = TypeHeader({ info = info, level = view.levels[info.id], order = base })
		if job == nil and view.loaded then
			local order = base + 1
			-- How the job works (towing, freight).
			local about = TEXT.about[info.id]
			if about ~= nil then
				children[`About_{info.id}`] = Kit.Text({
					text = about,
					order = order,
					size = Theme.text.small,
					color = colors.textDim,
				})
				order += 1
			end
			-- The license it needs: owned, or how to get it.
			local license = licensed[info.id]
			if license ~= nil then
				children[`License_{info.id}`] = LicenseCard({
					view = view,
					license = license,
					state = licenseState,
					owned = holdsLicense(view, licenseState, info.id, license.id),
					order = order,
					onAskBuy = function()
						setBuying(license)
					end,
				})
				order += 1
			end
			for key, child in typeBody(info, view, shared, order) do
				children[key] = child
			end
		end
	end

	if job == nil and view.loaded then
		local refreshing = busy ~= nil and busy.action == "refresh"
		children.Refresh = e(Kit.Button, {
			label = if refreshing then TEXT.refreshing else TEXT.refresh,
			disabled = busy ~= nil,
			order = (#types + 1) * ORDER_STEP,
			onTap = function()
				task.spawn(JobController.refresh)
			end,
		})
	end

	local buyingLicense = if job == nil and view.loaded then buying else nil
	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Page = Kit.Page({}, children),
		Buy = if buyingLicense ~= nil
			then e(LicenseConfirm, {
				license = buyingLicense,
				busy = licenseState.busy,
				onKeep = function()
					setBuying(nil)
				end,
				onBuy = function()
					local id = (buyingLicense :: License).id
					task.spawn(function()
						HitchInputController.buyLicense(id)
						if live.current then
							setBuying(nil)
						end
					end)
				end,
			})
			else nil,
		Confirm = if showConfirm
			then e(CancelConfirm, {
				view = view,
				onKeep = function()
					setConfirming(false)
				end,
				onCancel = function()
					task.spawn(function()
						JobController.cancel()
						if live.current then
							setConfirming(false)
						end
					end)
				end,
			})
			else nil,
	})
end

return JobsApp
