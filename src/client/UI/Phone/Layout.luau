--!strict
-- Where the phone button and the phone sheet go on a given screen, and where the HUD's speed panel and the
-- touch driving controls already are. Pure math in UI-scale-1 pixels (the screen size divided by the UI scale):
-- no instances and no services, so tests/Phone.spec checks it on fixture screens in Edit mode.
--
--   phone button   on foot: bottom centre. While driving: just left of the speed panel when that is clear of
--                  the touch controls, else just above the panel, else above every control at the bottom.
--   phone sheet    on foot: a sheet rising from the bottom centre over a dimmed screen (tap outside closes).
--                  Driving on touch: no dimming, and the sheet never covers the pedals or the steering zones:
--                  it fills the column between them (landscape), or the band above them (portrait), and only
--                  when neither fits does it fall back to the dimmed sheet (one tap closes it). Driving with a
--                  keyboard or gamepad: above the speed panel, without dimming.
--
-- The touch control rectangles mirror UI/TouchControls and the speed panel mirrors UI/Hud (both read the same
-- Config/Controls numbers through here).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

-- A screen rectangle in UI-scale-1 pixels, from the top-left corner.
export type Rect = { left: number, top: number, right: number, bottom: number }

-- What the layout depends on.
export type Context = {
	driving: boolean, -- the player sits in a Driver seat
	touch: boolean, -- the on-screen driving controls show (touch input while driving)
	hints: boolean, -- the key hint row shows under the speed panel (keyboard or gamepad while driving)
}

export type Placement = "modal" | "column" | "band" | "aboveHud"

export type Sheet = {
	rect: Rect,
	scrim: boolean, -- dim the screen behind the sheet; a tap on the dimming closes the phone
	placement: Placement,
}

export type TouchZones = { steering: Rect, pedals: Rect, buttons: Rect }

local Layout = {}

-- Rect helpers -----------------------------------------------------------------------------------------------

function Layout.rect(left: number, top: number, width: number, height: number): Rect
	return { left = left, top = top, right = left + width, bottom = top + height }
end

function Layout.width(rect: Rect): number
	return rect.right - rect.left
end

function Layout.height(rect: Rect): number
	return rect.bottom - rect.top
end

-- True when the two rectangles share some area (touching edges don't count).
function Layout.overlaps(a: Rect, b: Rect): boolean
	return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom
end

-- True when `inner` lies wholly inside `outer`.
function Layout.contains(outer: Rect, inner: Rect): boolean
	return inner.left >= outer.left
		and inner.right <= outer.right
		and inner.top >= outer.top
		and inner.bottom <= outer.bottom
end

function Layout.screen(size: Vector2): Rect
	return { left = 0, top = 0, right = size.X, bottom = size.Y }
end

-- The screen size the UI is laid out in: the ScreenGui's absolute size divided by the UI scale.
function Layout.layoutSize(absoluteSize: Vector2, scale: number): Vector2
	if scale <= 0 then
		return absoluteSize
	end
	return absoluteSize / scale
end

-- The HUD speed panel ------------------------------------------------------------------------------------------

-- The speed panel's size: Config/Controls' cluster plus the energy row along its bottom.
function Layout.clusterSize(): Vector2
	local hud = Controls.hud
	return Vector2.new(hud.clusterSize.X, hud.clusterSize.Y + PhoneConfig.hud.energy.rowHeight)
end

-- How far the speed panel's bottom edge sits above the screen's bottom edge (above the hint row when it shows).
function Layout.clusterBottom(hints: boolean): number
	local hud = Controls.hud
	return if hints then hud.margin + hud.hintHeight + hud.gap else hud.margin
end

function Layout.cluster(screen: Vector2, hints: boolean): Rect
	local size = Layout.clusterSize()
	local bottom = screen.Y - Layout.clusterBottom(hints)
	return Layout.rect((screen.X - size.X) / 2, bottom - size.Y, size.X, size.Y)
end

-- The touch driving controls (UI/TouchControls) -----------------------------------------------------------------

function Layout.touchZones(screen: Vector2): TouchZones
	local touch = Controls.touch
	local margin, gap = touch.margin, touch.gap
	local width, height = screen.X, screen.Y
	-- The pedal block plus the Horn / Lights row one gap above it (UI/TouchControls), so everything that keeps clear
	-- of the pedals keeps clear of that row too.
	local pedalHeight = math.max(touch.gasSize.Y, touch.brakeSize.Y + gap + touch.handbrakeSize.Y)
		+ gap
		+ touch.signalSize.Y
	local pedalWidth = touch.gasSize.X + gap + math.max(touch.brakeSize.X, touch.handbrakeSize.X)
	local buttonsWidth = 3 * touch.buttonSize.X + 2 * gap
	return {
		steering = Layout.rect(
			margin,
			height - margin - touch.steerSize.Y,
			2 * touch.steerSize.X + gap,
			touch.steerSize.Y
		),
		pedals = Layout.rect(width - margin - pedalWidth, height - margin - pedalHeight, pedalWidth, pedalHeight),
		buttons = Layout.rect(width - margin - buttonsWidth, margin, buttonsWidth, touch.buttonSize.Y),
	}
end

-- What the phone button must stay clear of while the player drives.
local function blockers(screen: Vector2, context: Context): { Rect }
	local list = { Layout.cluster(screen, context.hints) }
	if context.touch then
		local zones = Layout.touchZones(screen)
		table.insert(list, zones.steering)
		table.insert(list, zones.pedals)
		table.insert(list, zones.buttons)
	end
	return list
end

local function clearOf(rect: Rect, screen: Vector2, others: { Rect }): boolean
	if not Layout.contains(Layout.screen(screen), rect) then
		return false
	end
	for _, other in others do
		if Layout.overlaps(rect, other) then
			return false
		end
	end
	return true
end

-- The phone button ---------------------------------------------------------------------------------------------

function Layout.phoneButton(screen: Vector2, context: Context): Rect
	local size = PhoneConfig.button.size
	local hud = Controls.hud
	local centreLeft = (screen.X - size.X) / 2

	if not context.driving then
		return Layout.rect(centreLeft, screen.Y - hud.margin - size.Y, size.X, size.Y)
	end

	local cluster = Layout.cluster(screen, context.hints)
	local others = blockers(screen, context)
	-- 1. Beside the speed panel, on its left, sharing its bottom edge.
	local beside = Layout.rect(cluster.left - hud.gap - size.X, cluster.bottom - size.Y, size.X, size.Y)
	if clearOf(beside, screen, others) then
		return beside
	end
	-- 2. Centred just above the speed panel.
	local above = Layout.rect(centreLeft, cluster.top - hud.gap - size.Y, size.X, size.Y)
	if clearOf(above, screen, others) then
		return above
	end
	-- 3. Centred above every control along the bottom of the screen (tall, narrow screens).
	local lowest = cluster.top
	if context.touch then
		local zones = Layout.touchZones(screen)
		lowest = math.min(lowest, zones.steering.top, zones.pedals.top)
	end
	return Layout.rect(centreLeft, lowest - hud.gap - size.Y, size.X, size.Y)
end

-- The phone sheet ----------------------------------------------------------------------------------------------

-- The biggest phone-shaped sheet that fits `region`: at most Theme's sheet width and PhoneConfig's height (and a
-- share of the screen height), centred across the region and standing on its bottom edge. nil when the region is
-- smaller than the sheet's minimum size.
local function fit(region: Rect, screen: Vector2, scrim: boolean, placement: Placement): Sheet?
	local config = PhoneConfig.sheet
	local maxHeight = math.min(config.maxHeight, screen.Y * Theme.size.sheetMaxHeightScale)
	local width = math.min(Theme.size.sheetMaxWidth, Layout.width(region))
	local height = math.min(maxHeight, Layout.height(region))
	if width < config.minWidth or height < config.minHeight then
		return nil
	end
	local left = region.left + (Layout.width(region) - width) / 2
	return { rect = Layout.rect(left, region.bottom - height, width, height), scrim = scrim, placement = placement }
end

function Layout.sheet(screen: Vector2, context: Context): Sheet
	local config = PhoneConfig.sheet
	local margin = config.margin
	local full: Rect = { left = margin, top = margin, right = screen.X - margin, bottom = screen.Y - margin }

	-- A screen too small for even the minimum sheet gets everything inside the margins, dimmed.
	local function modal(scrim: boolean): Sheet
		return fit(full, screen, scrim, "modal") or { rect = full, scrim = true, placement = "modal" }
	end

	if not context.driving then
		return modal(true)
	end

	if context.touch then
		local zones = Layout.touchZones(screen)
		local gap = config.controlsGap
		local top = zones.buttons.bottom + gap
		-- Between the steering zones and the pedals (landscape phones and tablets).
		local column: Rect = {
			left = zones.steering.right + gap,
			top = top,
			right = zones.pedals.left - gap,
			bottom = screen.Y - margin,
		}
		local inColumn = fit(column, screen, false, "column")
		if inColumn then
			return inColumn
		end
		-- Above every control at the bottom (portrait).
		local band: Rect = {
			left = margin,
			top = top,
			right = screen.X - margin,
			bottom = math.min(zones.steering.top, zones.pedals.top) - gap,
		}
		local inBand = fit(band, screen, false, "band")
		if inBand then
			return inBand
		end
		-- Nothing fits beside the controls: cover them, dimmed, so one tap anywhere closes the phone.
		return modal(true)
	end

	-- Keyboard or gamepad: nothing on screen takes taps, so no dimming; keep the speed panel in view if it fits.
	local cluster = Layout.cluster(screen, context.hints)
	local aboveHud: Rect =
		{ left = margin, top = margin, right = screen.X - margin, bottom = cluster.top - Controls.hud.gap }
	return fit(aboveHud, screen, false, "aboveHud") or modal(false)
end

-- How many app icons fit across a sheet of this width.
function Layout.gridColumns(sheetWidth: number): number
	local grid = PhoneConfig.grid
	local inner = sheetWidth - 2 * PhoneConfig.sheet.padding
	local columns = math.floor((inner + grid.columnGap) / (grid.iconSize + grid.columnGap))
	return math.clamp(columns, grid.minColumns, grid.maxColumns)
end

-- UDim2 helpers for placing a Rect in a frame that fills the (UI-scale-1) screen.
function Layout.position(rect: Rect): UDim2
	return UDim2.fromOffset(rect.left, rect.top)
end

function Layout.size(rect: Rect): UDim2
	return UDim2.fromOffset(Layout.width(rect), Layout.height(rect))
end

return Layout
