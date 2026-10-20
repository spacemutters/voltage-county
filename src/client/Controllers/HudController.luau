--!strict
-- Owns the one HUD ScreenGui (docs/phase-1-contracts.md "Client") and renders it with react-lua: the HUD
-- (UI/Hud: the player's cash at all times with the active job under it while one runs (Phase 6: JobController
-- calls setActiveJob), the speed panel with its energy row while they drive, and the charging card while
-- their car charges or fuels, and the hitch row under the job slot while they drive a car with a hitch (Phase 8:
-- HitchInputController calls setHitch, and listens to onHitch for the row's Couple / Uncouple button)), on touch
-- screens the touch controls (UI/TouchControls) while the player drives, and the dev spawn menu (UI/DevSpawnMenu)
-- in Studio. Since Phase 4 codes live in the phone (PhoneController), which draws its own button beside the
-- speed panel.
--
-- Phase 9: the fleet chip ("$1,240 ready") once the robotaxi fleet's uncollected earnings in the profile snapshot
-- reach PhoneConfig.hud.fleetChip.threshold. It sits right of the cash, or under the cash column when that spot
-- would touch a driving control (fleetChipPlacement), and tapping it fires onFleetChipTapped (PhoneController
-- opens the Fleet app). While the LocalPlayer attribute PhoneConfig.cutsceneAttribute is true (a pod ride,
-- Controllers/HailController) the whole HUD hides and the touch controls unmount (letting go of anything held);
-- both come back when it clears.
--
-- Phase 10: the ability chip in the hitch row's place while driving a car with a thruster ability
-- (AbilityController calls setAbility), the ability key's entry in the hint row only then (hintsFor), and on touch
-- the Boost / Fly button in UI/TouchControls, whose press fires onAbility (AbilityController asks the server).
--
-- Telemetry is read from DriveController about 10 times a second (Heartbeat plus an accumulator, connected
-- only while driving), and the tree re-renders only when a shown value changes. Speed shows in the player's
-- units (mph or km/h) from ProfileController. Cash comes from the player's `Cash` attribute, which the server
-- sets (Config/Economy cashAttribute). The energy row and the charging card come from EnergyController
-- (setEnergy), which watches the driven car's energy attributes. The UI is laid out at a landscape phone's
-- size and scaled up on bigger screens by one UIScale; it never scales down, so touch targets keep their 44 px
-- minimum.
--
-- Other controllers read which controls the player is using from here (getInputKind, onInputKindChanged), so
-- the HUD, the touch controls and the phone always agree.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Economy = require(ReplicatedStorage.Shared.Config.Economy)
local Gps = require(ReplicatedStorage.Shared.Config.Gps)
local LightShows = require(ReplicatedStorage.Shared.Config.LightShows)
local Types = require(ReplicatedStorage.Shared.Types)
local Units = require(ReplicatedStorage.Shared.Util.Units)
local DriveController = require(script.Parent.DriveController)
local InputController = require(script.Parent.InputController)
local ProfileController = require(script.Parent.ProfileController)

local UI = script.Parent.Parent.UI
local DevSpawnMenu = require(UI.DevSpawnMenu)
local Hud = require(UI.Hud)
local Layout = require(UI.Phone.Layout)
local PhoneConfig = require(UI.Phone.PhoneConfig)
local Theme = require(UI.Theme)
local TouchControls = require(UI.TouchControls)

local GUI_NAME = "DrivingHud"

-- The hitch row (UI/Hud's HitchRow, px at UI scale 1): as wide as the job slot and a button tall, one
-- Economy.hud.gap under the job slot's place in the cash column. Mirrors UI/Hud's HITCH sizes.
local HITCH_ROW = {
	size = Vector2.new(PhoneConfig.hud.jobSlot.size.X, Theme.size.buttonHeight),
	gap = Economy.hud.gap,
}

-- The Studio spawn menu (which places itself in the top-left corner) is pushed down below the cash readout,
-- the active-job slot, the hitch row and the fleet chip's lower place.
local DEV_MENU_TOP = Controls.touch.margin
	+ Economy.hud.rowHeight
	+ Economy.hud.gap
	+ PhoneConfig.hud.jobSlot.size.Y
	+ HITCH_ROW.gap
	+ HITCH_ROW.size.Y
	+ Economy.hud.gap
	+ Economy.hud.rowHeight
	+ Economy.hud.gap

-- The charging card (PhoneConfig.hud.chargingCard, px at UI scale 1) and where it may go. It sits above the
-- speed panel when there's room, and never over the touch controls, the phone button, the cash and job slot,
-- the GPS route chip or the notices.
local CHARGING_CARD = {
	size = PhoneConfig.hud.chargingCard.size,
	gap = Controls.hud.gap, -- from the speed panel and the phone button
	noticeLines = PhoneConfig.hud.chargingCard.noticeLines,
	noticeLineHeight = PhoneConfig.hud.chargingCard.noticeLineHeight,
}

export type InputKind = "keyboard" | "gamepad" | "touch"
export type ActiveJob = Hud.ActiveJob
export type Energy = Hud.Energy
export type Charging = Hud.Charging
export type Hitch = Hud.Hitch
export type HitchAction = Hud.HitchAction
export type FleetChipPlacement = Hud.FleetChipPlacement
export type AbilityChip = Hud.AbilityChip

-- Everything the tree shows. render() hands a copy to the App component.
type View = {
	driving: boolean,
	speed: number, -- rounded, in the player's units
	units: string, -- "mph" | "kph"
	gear: string,
	mode: Types.DriveMode,
	regen: Types.RegenLevel,
	energy: Energy?,
	charging: Charging?,
	inputKind: InputKind,
	hints: { InputController.HintItem }?,
	scale: number,
	screen: Vector2, -- the screen in UI-scale-1 pixels (where the charging card can go)
	showDevMenu: boolean,
	cash: number?, -- nil until the player's data has loaded
	job: ActiveJob?,
	hitch: Hitch?, -- nil: no hitch row
	ability: AbilityChip?, -- nil: no ability chip, no Boost / Fly button, no ability hint
	fleetReady: number?, -- the fleet's uncollected $ while the chip shows (nil: no chip)
	cutscene: boolean, -- a pod ride's cutscene is playing: the HUD is hidden
}

local e = React.createElement

local HudController = {}

-- Fires (kind: InputKind) when the player switches between keyboard, gamepad and touch.
HudController.onInputKindChanged = InputController.newSignal()

-- Fires (action: HitchAction) when the player taps the hitch row's Couple or Uncouple button
-- (HitchInputController sends it to the server).
HudController.onHitch = InputController.newSignal()

-- Fires () when the player presses the touch Boost / Fly button (AbilityController asks the server).
HudController.onAbility = InputController.newSignal()

-- Fires () when the player taps the fleet chip (PhoneController opens the Fleet app; it can't be required here,
-- since it requires this module).
HudController.onFleetChipTapped = InputController.newSignal()

local view: View = {
	driving = false,
	speed = 0,
	units = ProfileController.defaultSettings().units,
	gear = "P",
	mode = Controls.defaultMode,
	regen = Controls.defaultRegen,
	energy = nil,
	charging = nil,
	inputKind = "keyboard",
	hints = nil,
	scale = 1,
	screen = Vector2.new(Controls.hud.referenceShortSide, Controls.hud.referenceShortSide),
	showDevMenu = false,
	cash = nil,
	job = nil,
	hitch = nil,
	ability = nil,
	fleetReady = nil,
	cutscene = false,
}

local root: any = nil
local screenGui: ScreenGui? = nil
local ticker: RBXScriptConnection? = nil
local lastMph = 0 -- the latest telemetry speed, so a units switch redraws at once

-- Declared with the pure helpers below; App places the charging card and labels the hitch button with them.
local chargingCardRect: (screen: Vector2, context: Layout.Context, hitch: boolean?) -> Layout.Rect
local hitchKeyFor: (kind: InputKind) -> string?
local abilityKeyFor: (kind: InputKind) -> string?
local fleetChipPlacement: (screen: Vector2, context: Layout.Context) -> FleetChipPlacement?

-- The hitch row's button was tapped: HitchInputController takes it from here.
local function onHitchTapped(action: HitchAction)
	HudController.onHitch:Fire(action)
end

-- The touch Boost / Fly button was pressed: AbilityController takes it from here.
local function onAbilityPressed()
	HudController.onAbility:Fire()
end

-- The fleet chip was tapped: PhoneController opens the Fleet app.
local function onFleetChipTapped()
	HudController.onFleetChipTapped:Fire()
end

-- The whole tree. The root frame is sized 1/scale so that, after the UIScale, it exactly fills the screen
-- and every child can be laid out in unscaled (phone) pixels.
local function App(props: View)
	local showHints = props.hints ~= nil and #props.hints > 0
	local touch = props.inputKind == "touch"
	local charging = if props.driving then props.charging else nil
	local hitch = if props.driving then props.hitch else nil
	local ability = if props.driving then props.ability else nil
	local showTouchControls = props.driving and touch and not props.cutscene
	-- The ability chip takes the hitch row's place, so the charging card keeps clear of it the same way.
	local chargingRect = if charging
		then chargingCardRect(props.screen, {
			driving = true,
			touch = touch,
			hints = showHints,
		}, hitch ~= nil or ability ~= nil)
		else nil
	local fleetReady = props.fleetReady
	local fleetPlacement = if fleetReady ~= nil
		then fleetChipPlacement(props.screen, {
			driving = props.driving,
			touch = props.driving and touch,
			hints = props.driving and showHints,
		})
		else nil
	return e("Frame", {
		Size = UDim2.fromScale(1 / props.scale, 1 / props.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = props.scale }),
		Hud = e(Hud, {
			driving = props.driving,
			speed = props.speed,
			unitLabel = PhoneConfig.hud.unitLabels[props.units] or props.units,
			gear = props.gear,
			mode = props.mode,
			regen = props.regen,
			energy = props.energy,
			charging = charging,
			chargingRect = chargingRect,
			hints = props.hints,
			cash = props.cash,
			job = props.job,
			hitch = hitch,
			hitchKey = hitchKeyFor(props.inputKind),
			onHitch = onHitchTapped,
			ability = ability,
			abilityKey = abilityKeyFor(props.inputKind),
			fleetReady = if fleetPlacement ~= nil then fleetReady else nil,
			fleetPlacement = fleetPlacement,
			onFleetChip = onFleetChipTapped,
		}),
		-- Unmounted (not just hidden) during a cutscene, so a held pedal or steering zone lets go.
		TouchControls = if showTouchControls
			then e(TouchControls, { ability = ability, onAbility = onAbilityPressed })
			else nil,
		DevSpawnMenu = if props.showDevMenu
			then e("Frame", {
				Position = UDim2.fromOffset(0, DEV_MENU_TOP),
				Size = UDim2.new(1, 0, 1, -DEV_MENU_TOP),
				BackgroundTransparency = 1,
			}, {
				Menu = e(DevSpawnMenu, {}),
			})
			else nil,
	})
end

local function render()
	if root then
		root:render(e(App, table.clone(view)))
	end
end

-- Pure helpers (tests/Phone.spec and tests/DriveClient.spec) -------------------------------------------------

-- UI scale for a screen: the short side against the phone the UI was laid out for, never below 1.
function HudController.scaleFor(screenSize: Vector2): number
	local shortSide = math.min(screenSize.X, screenSize.Y)
	if shortSide <= 0 then
		return 1
	end
	local scale = math.clamp(shortSide / Controls.hud.referenceShortSide, 1, Controls.hud.maxScale)
	return math.round(scale * 100) / 100 -- tiny window resizes don't re-render the tree
end

-- The speed the HUD shows for a telemetry speed in mph, in the player's units ("mph" or "kph"), rounded.
function HudController.speedFor(mph: number, units: string): number
	local absolute = math.abs(mph)
	if units == "kph" then
		return math.round(Units.studsToKph(Units.mphToStuds(absolute)))
	end
	return math.round(absolute)
end

-- The HUD hint row for keyboard or gamepad: the driving keys, then the phone key. With `withAbility` false the
-- ability key's entry is left out (the player isn't driving a car with a thruster ability).
function HudController.hintsFor(kind: "keyboard" | "gamepad", withAbility: boolean?): { InputController.HintItem }
	local hints = InputController.getHints(kind)
	if withAbility == false then
		-- getHints writes the ability entry as its first key's cap and its label: drop exactly that one.
		local abilityKey = HudController.abilityKeyFor(kind)
		for _, hint in Controls.hints[kind] do
			if table.find(hint.actions, "ability") == nil then
				continue
			end
			for index = #hints, 1, -1 do
				if hints[index].keys == abilityKey and hints[index].label == hint.label then
					table.remove(hints, index)
				end
			end
		end
	end
	table.insert(hints, { keys = PhoneConfig.keyGlyphs[kind], label = PhoneConfig.hud.phoneHint })
	return hints
end

-- The notices band at the top centre (UI/Toast), tall enough for a notice CHARGING_CARD.noticeLines lines tall.
function HudController.noticesRect(screen: Vector2): Layout.Rect
	local toast = Gps.toast
	local noticeWidth = toast.maxTextWidth + 2 * toast.padding.X + toast.dotSize + toast.gap
	local noticeHeight = 2 * toast.padding.Y
		+ CHARGING_CARD.noticeLines * toast.textSize * CHARGING_CARD.noticeLineHeight
	return Layout.rect((screen.X - noticeWidth) / 2, toast.margin, noticeWidth, noticeHeight)
end

-- The GPS route chip, top right (UI/GpsPanel).
function HudController.gpsChipRect(screen: Vector2): Layout.Rect
	local panel = Gps.panel
	return Layout.rect(screen.X - panel.margin - panel.chipWidth, panel.top, panel.chipWidth, panel.buttonSize.Y)
end

-- The active-job slot (UI/Hud's Wallet: under the cash readout, at the touch margin).
function HudController.jobSlotRect(_screen: Vector2): Layout.Rect
	local hud = Economy.hud
	local slot = PhoneConfig.hud.jobSlot.size
	local margin = Controls.touch.margin
	return Layout.rect(margin, margin + hud.rowHeight + hud.gap, slot.X, slot.Y)
end

-- What the active-job slot must stay clear of on `screen` (UI-scale-1 pixels): the notices band, the GPS route
-- chip, the speed panel and the phone button, and on touch the steering zones, pedals and touch buttons
-- (tests/JobClient.spec checks it on landscape phones, tablets and desktops).
function HudController.jobSlotBlockers(screen: Vector2, context: Layout.Context): { Layout.Rect }
	local list: { Layout.Rect } = {
		HudController.noticesRect(screen),
		HudController.gpsChipRect(screen),
		Layout.phoneButton(screen, context),
	}
	if context.driving then
		table.insert(list, Layout.cluster(screen, context.hints))
	end
	if context.touch then
		local zones = Layout.touchZones(screen)
		table.insert(list, zones.steering)
		table.insert(list, zones.pedals)
		table.insert(list, zones.buttons)
	end
	return list
end

-- The hitch row (UI/Hud's HitchRow) at its lowest: one gap under the job slot's place, which it takes when a job
-- is running (with no job it rises into the slot's place, which is clear of the same things). The rect is the
-- row itself; its key cap pokes out PhoneConfig.button.badgeInset above the top-right corner (never past the right
-- edge: on a small keyboard window the speed panel starts a few pixels right of this column).
function HudController.hitchRect(screen: Vector2): Layout.Rect
	local slot = HudController.jobSlotRect(screen)
	return Layout.rect(slot.left, slot.bottom + HITCH_ROW.gap, HITCH_ROW.size.X, HITCH_ROW.size.Y)
end

-- What the hitch row must stay clear of while driving on `screen` (UI-scale-1 pixels): everything the job slot
-- keeps clear of (the notices band, the GPS route chip, the phone button, the speed panel, and on touch the
-- steering zones, pedals and touch buttons), the job slot itself, and the light-show button under the notices
-- (Controllers/LightShowController, Config/LightShows button).
function HudController.hitchBlockers(screen: Vector2, context: Layout.Context): { Layout.Rect }
	local list = HudController.jobSlotBlockers(screen, context)
	table.insert(list, HudController.jobSlotRect(screen))
	local lightShowWidth = LightShows.button.width
	table.insert(
		list,
		Layout.rect(
			(screen.X - lightShowWidth) / 2,
			HudController.noticesRect(screen).bottom + LightShows.button.gap,
			lightShowWidth,
			Theme.size.buttonHeight
		)
	)
	return list
end

-- The key cap the hitch button wears for keyboard and gamepad players: the first hitch key in Config/Controls
-- ("T"), or its gamepad glyph ("RB"). nil on touch, where the button is the control.
function HudController.hitchKeyFor(kind: InputKind): string?
	if kind == "touch" then
		return nil
	end
	local keys: { Enum.KeyCode } = if kind == "gamepad" then Controls.gamepad.hitch else Controls.keyboard.hitch
	local key = keys[1]
	if key == nil then
		return nil
	end
	return if kind == "gamepad" then Controls.gamepadGlyphs[key.Name] or key.Name else key.Name
end
hitchKeyFor = HudController.hitchKeyFor

-- The key cap the ability chip wears for keyboard and gamepad players: the first ability key in Config/Controls
-- ("Q"), or its gamepad glyph ("L3"). nil on touch, where the Boost / Fly button is the control.
function HudController.abilityKeyFor(kind: InputKind): string?
	if kind == "touch" then
		return nil
	end
	local keys: { Enum.KeyCode } = if kind == "gamepad" then Controls.gamepad.ability else Controls.keyboard.ability
	local key = keys[1]
	if key == nil then
		return nil
	end
	return if kind == "gamepad" then Controls.gamepadGlyphs[key.Name] or key.Name else key.Name
end
abilityKeyFor = HudController.abilityKeyFor

-- What the charging card must stay clear of while driving on `screen` (UI-scale-1 pixels): the speed panel, the
-- phone button, the cash readout with its job slot, the GPS route chip (top right), the notices band (top
-- centre), the hitch row while it shows (`hitch`) and, on touch, the steering zones, pedals and touch buttons.
function HudController.chargingCardBlockers(screen: Vector2, context: Layout.Context, hitch: boolean?): { Layout.Rect }
	local hud = Economy.hud
	local jobSlot = PhoneConfig.hud.jobSlot.size
	local margin = Controls.touch.margin
	local list: { Layout.Rect } = {
		Layout.cluster(screen, context.hints),
		Layout.phoneButton(screen, context),
		Layout.rect(margin, margin, math.max(hud.cashMaxWidth, jobSlot.X), hud.rowHeight + hud.gap + jobSlot.Y),
		HudController.gpsChipRect(screen),
		HudController.noticesRect(screen),
	}
	if hitch then
		table.insert(list, HudController.hitchRect(screen))
	end
	if context.touch then
		local zones = Layout.touchZones(screen)
		table.insert(list, zones.steering)
		table.insert(list, zones.pedals)
		table.insert(list, zones.buttons)
	end
	return list
end

-- Where the charging card goes while driving on `screen` (UI-scale-1 pixels). The first spot that is on screen
-- and clear of everything in chargingCardBlockers: centred just above the speed panel; centred above the speed
-- panel and the phone button (when the phone button sits above the panel); then left, then right of the phone
-- button. If none is clear (a very small screen), just above the speed panel. `hitch`: the hitch row shows.
function HudController.chargingCardRect(screen: Vector2, context: Layout.Context, hitch: boolean?): Layout.Rect
	local size = CHARGING_CARD.size
	local gap = CHARGING_CARD.gap
	local cluster = Layout.cluster(screen, context.hints)
	local phone = Layout.phoneButton(screen, context)
	local centreLeft = (cluster.left + cluster.right - size.X) / 2

	local candidates: { Layout.Rect } = {
		Layout.rect(centreLeft, cluster.top - gap - size.Y, size.X, size.Y),
		Layout.rect(centreLeft, math.min(cluster.top, phone.top) - gap - size.Y, size.X, size.Y),
		Layout.rect(phone.left - gap - size.X, phone.bottom - size.Y, size.X, size.Y),
		Layout.rect(phone.right + gap, phone.bottom - size.Y, size.X, size.Y),
	}
	local blockers = HudController.chargingCardBlockers(screen, context, hitch)
	local whole = Layout.screen(screen)
	for _, candidate in candidates do
		local clear = Layout.contains(whole, candidate)
		for _, blocker in blockers do
			if not clear then
				break
			end
			clear = not Layout.overlaps(candidate, blocker)
		end
		if clear then
			return candidate
		end
	end
	return candidates[1]
end
chargingCardRect = HudController.chargingCardRect

-- The fleet chip (Phase 9) ---------------------------------------------------------------------------------------

-- The uncollected $ the fleet chip shows for this fleet (ProfileController.fleet()), or nil when it shouldn't
-- show: no fleet yet, or less than PhoneConfig.hud.fleetChip.threshold waiting.
function HudController.fleetChipAmount(fleet: ProfileController.Fleet?): number?
	if fleet == nil or fleet.uncollected <= 0 or fleet.uncollected < PhoneConfig.hud.fleetChip.threshold then
		return nil
	end
	return fleet.uncollected
end

-- The fleet chip right of the cash readout, as wide as it can get (with the cash readout at its widest too), so
-- a spot found clear stays clear whatever the amounts.
function HudController.fleetChipBesideRect(_screen: Vector2): Layout.Rect
	local hud = Economy.hud
	local margin = Controls.touch.margin
	return Layout.rect(margin + hud.cashMaxWidth + hud.gap, margin, PhoneConfig.hud.fleetChip.maxWidth, hud.rowHeight)
end

-- The fleet chip under the cash column at its lowest: one gap under the hitch row's place (with no job or hitch
-- row showing it rises into theirs, which is clear of the same things).
function HudController.fleetChipBelowRect(screen: Vector2): Layout.Rect
	local hitch = HudController.hitchRect(screen)
	local hud = Economy.hud
	return Layout.rect(hitch.left, hitch.bottom + hud.gap, PhoneConfig.hud.fleetChip.maxWidth, hud.rowHeight)
end

-- What the fleet chip must stay clear of on `screen` (UI-scale-1 pixels): the GPS route chip and the phone
-- button, the speed panel while driving, and on touch the steering zones, pedals and touch buttons. (The notices
-- band is left out: notices come and go above it.)
function HudController.fleetChipBlockers(screen: Vector2, context: Layout.Context): { Layout.Rect }
	local list: { Layout.Rect } = {
		HudController.gpsChipRect(screen),
		Layout.phoneButton(screen, context),
	}
	if context.driving then
		table.insert(list, Layout.cluster(screen, context.hints))
	end
	if context.touch then
		local zones = Layout.touchZones(screen)
		table.insert(list, zones.steering)
		table.insert(list, zones.pedals)
		table.insert(list, zones.buttons)
	end
	return list
end

-- Where the fleet chip goes on `screen`: "beside" the cash when that spot is on screen and clear of everything in
-- fleetChipBlockers (landscape phones, tablets, desktops, and portrait on foot), else "below" the cash column
-- (portrait phones driving on touch, where the touch buttons take the top right), else nil: no room, so no chip
-- rather than one over a driving control.
function HudController.fleetChipPlacement(screen: Vector2, context: Layout.Context): FleetChipPlacement?
	local whole = Layout.screen(screen)
	local blockers = HudController.fleetChipBlockers(screen, context)
	local candidates: { { placement: FleetChipPlacement, rect: Layout.Rect } } = {
		{ placement = "beside", rect = HudController.fleetChipBesideRect(screen) },
		{ placement = "below", rect = HudController.fleetChipBelowRect(screen) },
	}
	for _, candidate in candidates do
		local clear = Layout.contains(whole, candidate.rect)
		for _, blocker in blockers do
			if not clear then
				break
			end
			clear = not Layout.overlaps(candidate.rect, blocker)
		end
		if clear then
			return candidate.placement
		end
	end
	return nil
end
fleetChipPlacement = HudController.fleetChipPlacement

-- Input kind -------------------------------------------------------------------------------------------------

-- Which controls the player is using, from the last input type (nil: an input that says nothing about it).
local function kindFor(inputType: Enum.UserInputType): InputKind?
	if inputType == Enum.UserInputType.Touch then
		return if UserInputService.TouchEnabled then "touch" else nil
	elseif string.sub(inputType.Name, 1, #"Gamepad") == "Gamepad" then
		return "gamepad"
	elseif
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseWheel
	then
		return "keyboard"
	end
	return nil
end

-- Before any input arrives, guess from the device.
local function deviceKind(): InputKind
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "gamepad"
	end
	return "keyboard"
end

local function setInputKind(kind: InputKind)
	view.inputKind = kind
	view.hints = if kind == "touch" then nil else HudController.hintsFor(kind, view.ability ~= nil)
end

-- The controls the player is using right now ("keyboard", "gamepad" or "touch").
function HudController.getInputKind(): InputKind
	return view.inputKind
end

-- Active job (Phase 6) -------------------------------------------------------------------------------------------

-- Shows a job in the slot under the cash, or empties it (nil). JobController calls it when the job, its stop,
-- or the distance or time left as shown changes; an unchanged job doesn't redraw.
function HudController.setActiveJob(job: ActiveJob?)
	local current = view.job
	if
		current ~= nil
		and job ~= nil
		and current.title == job.title
		and current.detail == job.detail
		and current.status == job.status
		and current.pay == job.pay
		and current.alert == job.alert
	then
		return
	end
	if current == nil and job == nil then
		return
	end
	view.job = if job then table.clone(job) else nil
	render()
end

-- Hitch (Phase 8) ------------------------------------------------------------------------------------------------

-- Shows the driven car's hitch in the row under the job slot (what is coupled, or near enough to couple, and the
-- Uncouple or Couple button), or hides the row (nil). HitchInputController calls it whenever that changes; an
-- unchanged hitch doesn't redraw.
function HudController.setHitch(hitch: Hitch?)
	local current = view.hitch
	if current == nil and hitch == nil then
		return
	end
	if
		current ~= nil
		and hitch ~= nil
		and current.state == hitch.state
		and current.kind == hitch.kind
		and current.name == hitch.name
		and current.busy == hitch.busy
	then
		return
	end
	view.hitch = if hitch then table.clone(hitch) else nil
	render()
end

-- Ability (Phase 10) ----------------------------------------------------------------------------------------------

-- Shows the ability chip (and on touch the Boost / Fly button) for the car being driven, or hides them (nil).
-- AbilityController calls it whenever what they show changes; an unchanged chip doesn't redraw.
function HudController.setAbility(ability: AbilityChip?)
	local current = view.ability
	if current == nil and ability == nil then
		return
	end
	if
		current ~= nil
		and ability ~= nil
		and current.label == ability.label
		and current.status == ability.status
		and current.state == ability.state
		and current.fill == ability.fill
		and current.seconds == ability.seconds
		and current.busy == ability.busy
	then
		return
	end
	local toggled = (current == nil) ~= (ability == nil)
	view.ability = if ability then table.clone(ability) else nil
	if toggled then
		setInputKind(view.inputKind) -- the hint row gains or loses the ability key
	end
	render()
end

-- Energy (Phase 5) -----------------------------------------------------------------------------------------------

local function sameFields(a: { [string]: any }?, b: { [string]: any }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- Shows the driven car's energy in the speed panel's energy row, and the charging card while it charges or
-- fuels (nil: none). For EnergyController, which works both out from the car's attributes; redraws only when
-- something shown changed.
function HudController.setEnergy(energy: Energy?, charging: Charging?)
	if sameFields(view.energy :: any, energy :: any) and sameFields(view.charging :: any, charging :: any) then
		return
	end
	view.energy = if energy then table.clone(energy) else nil
	view.charging = if charging then table.clone(charging) else nil
	render()
end

-- Driving ----------------------------------------------------------------------------------------------------

-- Copies the telemetry into the view; re-renders only if something shown changed.
local function refreshTelemetry()
	local telemetry = DriveController.getTelemetry()
	if telemetry == nil then
		return
	end
	lastMph = telemetry.mph
	local speed = HudController.speedFor(telemetry.mph, view.units)
	if
		speed == view.speed
		and telemetry.gear == view.gear
		and telemetry.mode == view.mode
		and telemetry.regen == view.regen
	then
		return
	end
	view.speed = speed
	view.gear = telemetry.gear
	view.mode = telemetry.mode
	view.regen = telemetry.regen
	render()
end

local function startTicker()
	if ticker then
		return
	end
	local interval = 1 / Controls.hud.refreshHz
	local elapsed = interval -- refresh on the first frame
	ticker = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= interval then
			elapsed = 0
			refreshTelemetry()
		end
	end)
end

local function stopTicker()
	if ticker then
		ticker:Disconnect()
		ticker = nil
	end
end

-- The energy row and charging card follow EnergyController (setEnergy), which watches the same signal.
local function onDrivingChanged(driving: boolean)
	view.driving = driving
	if driving then
		view.mode = DriveController.getMode()
		view.regen = DriveController.getRegen()
		startTicker()
	else
		stopTicker()
	end
	render()
end

-- Cash and units ---------------------------------------------------------------------------------------------

local function readCash()
	local value = Players.LocalPlayer:GetAttribute(Economy.cashAttribute)
	view.cash = if type(value) == "number" then value else nil
end

local function onProfileChanged()
	local changed = false
	local units = ProfileController.settings().units
	if units ~= view.units then
		view.units = units
		view.speed = HudController.speedFor(lastMph, units)
		changed = true
	end
	local fleetReady = HudController.fleetChipAmount(ProfileController.fleet())
	if fleetReady ~= view.fleetReady then
		view.fleetReady = fleetReady
		changed = true
	end
	if changed then
		render()
	end
end

-- Cutscene (Phase 9) -----------------------------------------------------------------------------------------------

-- Hides the whole HUD while a pod ride's cutscene plays, and brings it back after.
local function onCutsceneChanged()
	local cutscene = Players.LocalPlayer:GetAttribute(PhoneConfig.cutsceneAttribute) == true
	if cutscene == view.cutscene then
		return
	end
	view.cutscene = cutscene
	local gui = screenGui
	if gui then
		gui.Enabled = not cutscene
	end
	render()
end

function HudController:Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	-- One GUI for the whole session: what it shows follows DriveController, not the character.
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = Theme.displayOrder.hud
	-- Keep every control clear of the Roblox top bar, notches and the home indicator.
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui
	screenGui = gui

	root = ReactRoblox.createRoot(gui)
	view.showDevMenu = RunService:IsStudio()
	view.scale = HudController.scaleFor(gui.AbsoluteSize)
	view.screen = Layout.layoutSize(gui.AbsoluteSize, view.scale)
	setInputKind(kindFor(UserInputService:GetLastInputType()) or deviceKind())
	-- Controllers that started before this one (the phone) hear the first guess too.
	HudController.onInputKindChanged:Fire(view.inputKind)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local scale = HudController.scaleFor(gui.AbsoluteSize)
		local screen = Layout.layoutSize(gui.AbsoluteSize, scale)
		local moved = screen ~= view.screen
		view.screen = screen
		-- The charging card's and the fleet chip's spots depend on the screen size; everything else only on the
		-- scale.
		if scale ~= view.scale or (moved and (view.charging ~= nil or view.fleetReady ~= nil)) then
			view.scale = scale
			render()
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
		local kind = kindFor(inputType)
		if kind and kind ~= view.inputKind then
			setInputKind(kind :: InputKind)
			render()
			HudController.onInputKindChanged:Fire(kind)
		end
	end)

	-- The server sets Cash once the player's data loads and whenever it changes.
	readCash()
	Players.LocalPlayer:GetAttributeChangedSignal(Economy.cashAttribute):Connect(function()
		readCash()
		render()
	end)

	ProfileController.onChanged:Connect(onProfileChanged)
	onProfileChanged()

	Players.LocalPlayer:GetAttributeChangedSignal(PhoneConfig.cutsceneAttribute):Connect(onCutsceneChanged)
	onCutsceneChanged()

	DriveController.onDrivingChanged:Connect(onDrivingChanged)
	if DriveController.getCar() then
		onDrivingChanged(true)
	else
		render()
	end
end

return HudController
