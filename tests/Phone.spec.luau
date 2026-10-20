--!strict
-- The phone and the Phase 4 HUD (docs/phase-4-contracts.md "Client UI"): where the phone button and sheet go on
-- phone, tablet and desktop screens (UI/Phone/Layout: never over the touch pedals or steering while driving,
-- always on screen), touch targets and keys (UI/Phone/PhoneConfig), the profile cache's payload checks and
-- optimistic patches (ProfileController), speed in the player's units (HudController) and GPS distances in
-- kilometres (GpsController). Pure logic on fixtures: runs in Edit mode and never touches module state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Data = require(ReplicatedStorage.Shared.Config.Data)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Types = require(ReplicatedStorage.Shared.Types)
local World = require(ReplicatedStorage.Shared.Config.World)

local Client = StarterPlayer.StarterPlayerScripts.Client
local GpsController = require(Client.Controllers.GpsController)
local HudController = require(Client.Controllers.HudController)
local ProfileController = require(Client.Controllers.ProfileController)
local Layout = require(Client.UI.Phone.Layout)
local PhoneConfig = require(Client.UI.Phone.PhoneConfig)
local Theme = require(Client.UI.Theme)

local MIN_TARGET = 44

type Screen = { name: string, size: Vector2 }

-- Screens in UI-scale-1 pixels (HudController.scaleFor never shrinks below 1, and scales bigger screens up to
-- Controls.hud.maxScale, so a 1024 x 768 tablet lays out at 819 x 614).
local SCREENS: { Screen } = {
	{ name = "landscape phone 844x390", size = Vector2.new(844, 390) },
	{ name = "small landscape phone 667x375", size = Vector2.new(667, 375) },
	{ name = "portrait phone 375x667", size = Vector2.new(375, 667) },
	{ name = "tablet 819x614", size = Vector2.new(819, 614) },
	{ name = "desktop 1536x864", size = Vector2.new(1536, 864) },
}

local ON_FOOT: Layout.Context = { driving = false, touch = false, hints = false }
local DRIVING_TOUCH: Layout.Context = { driving = true, touch = true, hints = false }
local DRIVING_KEYS: Layout.Context = { driving = true, touch = false, hints = true }

local function within(t: Harness.Api, label: string, screen: Vector2, rect: Layout.Rect)
	local inside = Layout.contains(Layout.screen(screen), rect)
	t.expect(`{label} on screen: {inside}`).toBe(`{label} on screen: true`)
end

local function clear(t: Harness.Api, label: string, a: Layout.Rect, b: Layout.Rect)
	local overlap = Layout.overlaps(a, b)
	t.expect(`{label} overlaps: {overlap}`).toBe(`{label} overlaps: false`)
end

local function vehicle(uid: string, favorite: boolean, acquiredAt: number): { [string]: any }
	return {
		uid = uid,
		vehicleId = "ohm_spark",
		trim = "standard",
		favorite = favorite,
		paid = 35000,
		paint = "white",
		finish = "gloss",
		wheels = "stock",
		acquiredAt = acquiredAt,
	}
end

local function payload(): { [string]: any }
	return {
		cash = 1200,
		garageSlots = 6,
		customSlots = 3,
		starterClaimed = true,
		vehicles = { vehicle("old", false, 100), vehicle("new", false, 200), vehicle("fav", true, 50) },
		settings = { units = "kph", camera = "hood", musicVolume = 0.3 },
		credits = { balance = 2 },
	}
end

local function uids(snapshot: Types.ProfileSnapshot): { string }
	local list = {}
	for _, car in snapshot.vehicles do
		table.insert(list, car.uid)
	end
	return list
end

return function(t: Harness.Api)
	t.describe("Phone layout", function()
		t.it("keeps the phone button a full touch target", function()
			local size = PhoneConfig.button.size
			t.expect(math.min(size.X, size.Y) >= MIN_TARGET).toBe(true)
		end)

		t.it("puts the phone button at the bottom centre on foot", function()
			for _, screen in SCREENS do
				local button = Layout.phoneButton(screen.size, ON_FOOT)
				within(t, screen.name, screen.size, button)
				local centre = (button.left + button.right) / 2
				t.expect(centre).toBeNear(screen.size.X / 2, 1e-6)
				t.expect(button.bottom).toBeNear(screen.size.Y - Controls.hud.margin, 1e-6)
			end
		end)

		t.it("keeps the phone button off the pedals, steering, touch buttons and speed panel while driving", function()
			for _, screen in SCREENS do
				local button = Layout.phoneButton(screen.size, DRIVING_TOUCH)
				local zones = Layout.touchZones(screen.size)
				within(t, screen.name, screen.size, button)
				clear(t, `{screen.name} button/steering`, button, zones.steering)
				clear(t, `{screen.name} button/pedals`, button, zones.pedals)
				clear(t, `{screen.name} button/touch buttons`, button, zones.buttons)
				clear(t, `{screen.name} button/speed panel`, button, Layout.cluster(screen.size, false))
			end
		end)

		t.it("keeps the phone button off the speed panel with a keyboard or gamepad", function()
			for _, screen in SCREENS do
				local button = Layout.phoneButton(screen.size, DRIVING_KEYS)
				within(t, screen.name, screen.size, button)
				clear(t, `{screen.name} button/speed panel`, button, Layout.cluster(screen.size, true))
			end
		end)

		t.it("sits beside the speed panel on a wide phone", function()
			local screen = Vector2.new(844, 390)
			local button = Layout.phoneButton(screen, DRIVING_TOUCH)
			local cluster = Layout.cluster(screen, false)
			t.expect(button.right).toBeNear(cluster.left - Controls.hud.gap, 1e-6)
			t.expect(button.bottom).toBeNear(cluster.bottom, 1e-6)
		end)

		t.it("opens a dimmed sheet on foot, phone-sized and on screen", function()
			for _, screen in SCREENS do
				local sheet = Layout.sheet(screen.size, ON_FOOT)
				t.expect(sheet.scrim).toBe(true)
				within(t, screen.name, screen.size, sheet.rect)
				t.expect(Layout.width(sheet.rect) <= Theme.size.sheetMaxWidth).toBe(true)
				t.expect(Layout.width(sheet.rect) >= PhoneConfig.sheet.minWidth).toBe(true)
				t.expect(Layout.height(sheet.rect) >= PhoneConfig.sheet.minHeight).toBe(true)
			end
		end)

		t.it("never covers the touch pedals or steering while driving", function()
			for _, screen in SCREENS do
				local sheet = Layout.sheet(screen.size, DRIVING_TOUCH)
				local zones = Layout.touchZones(screen.size)
				within(t, screen.name, screen.size, sheet.rect)
				t.expect(`{screen.name} dimmed: {sheet.scrim}`).toBe(`{screen.name} dimmed: false`)
				clear(t, `{screen.name} sheet/steering`, sheet.rect, zones.steering)
				clear(t, `{screen.name} sheet/pedals`, sheet.rect, zones.pedals)
				clear(t, `{screen.name} sheet/touch buttons`, sheet.rect, zones.buttons)
				t.expect(Layout.width(sheet.rect) >= PhoneConfig.sheet.minWidth).toBe(true)
				t.expect(Layout.height(sheet.rect) >= PhoneConfig.sheet.minHeight).toBe(true)
			end
		end)

		t.it("fits between the controls in landscape and above them in portrait", function()
			t.expect(Layout.sheet(Vector2.new(844, 390), DRIVING_TOUCH).placement).toBe("column")
			t.expect(Layout.sheet(Vector2.new(375, 667), DRIVING_TOUCH).placement).toBe("band")
		end)

		t.it("falls back to a dimmed sheet (one tap closes it) when nothing fits beside the controls", function()
			local tiny = Vector2.new(480, 320)
			local sheet = Layout.sheet(tiny, DRIVING_TOUCH)
			t.expect(sheet.placement).toBe("modal")
			t.expect(sheet.scrim).toBe(true)
			within(t, "tiny screen", tiny, sheet.rect)
		end)

		t.it("keeps the speed panel in view with a keyboard on a desktop", function()
			local screen = Vector2.new(1536, 864)
			local sheet = Layout.sheet(screen, DRIVING_KEYS)
			t.expect(sheet.placement).toBe("aboveHud")
			t.expect(sheet.scrim).toBe(false)
			clear(t, "desktop sheet/speed panel", sheet.rect, Layout.cluster(screen, true))
		end)

		t.it("mirrors the touch controls' layout", function()
			local touch = Controls.touch
			local screen = Vector2.new(844, 390)
			local zones = Layout.touchZones(screen)
			t.expect(zones.steering.left).toBe(touch.margin)
			t.expect(zones.steering.right).toBe(touch.margin + 2 * touch.steerSize.X + touch.gap)
			t.expect(zones.pedals.right).toBe(screen.X - touch.margin)
			local pedalColumn = math.max(touch.gasSize.Y, touch.brakeSize.Y + touch.gap + touch.handbrakeSize.Y)
			t.expect(zones.pedals.top).toBe(screen.Y - touch.margin - pedalColumn)
			t.expect(zones.pedals.left)
				.toBe(screen.X - (touch.margin + touch.gasSize.X + touch.gap + touch.brakeSize.X))
			t.expect(zones.buttons.bottom).toBe(touch.margin + touch.buttonSize.Y)
		end)

		t.it("fits two to four app icons across every sheet", function()
			local grid = PhoneConfig.grid
			for _, screen in SCREENS do
				for _, context in { ON_FOOT, DRIVING_TOUCH, DRIVING_KEYS } do
					local width = Layout.width(Layout.sheet(screen.size, context).rect)
					local columns = Layout.gridColumns(width)
					t.expect(columns >= grid.minColumns and columns <= grid.maxColumns).toBe(true)
					local needed = columns * grid.iconSize
						+ (columns - 1) * grid.columnGap
						+ 2 * PhoneConfig.sheet.padding
					t.expect(`{screen.name} icons fit: {needed <= width}`).toBe(`{screen.name} icons fit: true`)
				end
			end
		end)
	end)

	t.describe("PhoneConfig", function()
		t.it("keeps every touch target at least 44 px", function()
			t.expect(Theme.size.touchTarget >= MIN_TARGET).toBe(true)
			t.expect(Theme.size.buttonHeight >= MIN_TARGET).toBe(true)
			t.expect(PhoneConfig.list.rowHeight >= MIN_TARGET).toBe(true)
			t.expect(PhoneConfig.garage.starSize >= MIN_TARGET).toBe(true)
			t.expect(PhoneConfig.slider.stepButtonWidth >= MIN_TARGET).toBe(true)
			t.expect(PhoneConfig.grid.iconSize >= MIN_TARGET).toBe(true)
			t.expect(PhoneConfig.sheet.headerHeight >= MIN_TARGET).toBe(true) -- Back and Close fit in it
		end)

		t.it("opens with keys the driving controls don't use", function()
			local used: { [Enum.KeyCode]: boolean } = {}
			for _, keys in Controls.keyboard :: { [string]: { Enum.KeyCode } } do
				for _, key in keys do
					used[key] = true
				end
			end
			for _, keys in Controls.gamepad :: { [string]: { Enum.KeyCode } } do
				for _, key in keys do
					used[key] = true
				end
			end
			for _, key in PhoneConfig.keys.keyboard do
				t.expect(`{key.Name} free: {used[key] == nil}`).toBe(`{key.Name} free: true`)
			end
			for _, key in PhoneConfig.keys.gamepad do
				t.expect(`{key.Name} free: {used[key] == nil}`).toBe(`{key.Name} free: true`)
			end
		end)

		t.it("lists the seven apps once each", function()
			local seen: { [string]: boolean } = {}
			for _, app in PhoneConfig.apps do
				t.expect(seen[app.id]).toBe(nil)
				seen[app.id] = true
			end
			for _, id in { "gps", "garage", "jobs", "fleet", "wallet", "codes", "settings" } do
				t.expect(seen[id]).toBe(true)
			end
		end)

		t.it("offers directions only to places on the map", function()
			local ids: { [string]: boolean } = {}
			for _, location in MapLayout.locations do
				ids[location.id] = true
			end
			t.expect(ids[PhoneConfig.garage.usedLotLocation]).toBe(true)
			t.expect(ids[PhoneConfig.garage.dealershipLocation]).toBe(true)
		end)

		t.it("labels both speed units", function()
			t.expect(PhoneConfig.hud.unitLabels.mph ~= nil).toBe(true)
			t.expect(PhoneConfig.hud.unitLabels.kph ~= nil).toBe(true)
			t.expect(PhoneConfig.sendDelaySeconds < PhoneConfig.confirmHoldSeconds).toBe(true)
		end)
	end)

	t.describe("ProfileController", function()
		t.it("keeps a good snapshot, with the cars in garage order", function()
			local snapshot = ProfileController.normalize(payload())
			assert(snapshot, "normalized")
			t.expect(snapshot.cash).toBe(1200)
			t.expect(snapshot.garageSlots).toBe(6)
			t.expect(snapshot.credits.balance).toBe(2)
			t.expect(snapshot.settings).toEqual({ units = "kph", camera = "hood", musicVolume = 0.3 })
			t.expect(uids(snapshot)).toEqual({ "fav", "new", "old" })
		end)

		t.it("refuses something that isn't a snapshot", function()
			t.expect(ProfileController.normalize(nil)).toBe(nil)
			t.expect(ProfileController.normalize("cash")).toBe(nil)
			t.expect(ProfileController.normalize({ cash = "lots" })).toBe(nil)
			t.expect(ProfileController.normalize({ cash = 0 / 0 })).toBe(nil)
		end)

		t.it("drops broken cars and fixes broken fields", function()
			local bad = payload()
			bad.vehicles = { { uid = 5 }, "car", vehicle("ok", false, 1) } :: { any }
			bad.vehicles[3].paid = -50
			bad.settings = { units = "furlongs", camera = "drone", musicVolume = 7 }
			bad.credits = nil
			bad.garageSlots = "six"
			local snapshot = ProfileController.normalize(bad)
			assert(snapshot, "normalized")
			t.expect(uids(snapshot)).toEqual({ "ok" })
			t.expect(snapshot.vehicles[1].paid).toBe(0)
			local defaults = Data.defaults.settings
			t.expect(snapshot.settings.units).toBe(defaults.units)
			t.expect(snapshot.settings.camera).toBe(defaults.camera)
			t.expect(snapshot.settings.musicVolume).toBe(1)
			t.expect(snapshot.credits.balance).toBe(0)
			t.expect(snapshot.garageSlots).toBe(0)
		end)

		t.it("shows a favorite star and a settings change before the server confirms them", function()
			local snapshot = ProfileController.normalize(payload())
			assert(snapshot, "normalized")
			local patches: ProfileController.Patches = {
				settings = { units = { value = "mph", untilTime = 10 } },
				favorites = { old = { value = true, untilTime = 10 } },
			}
			local merged = ProfileController.merge(snapshot, patches)
			t.expect(merged.settings.units).toBe("mph")
			t.expect(uids(merged)).toEqual({ "old", "fav", "new" }) -- both favorites first, the newer one first
			-- The snapshot itself is left alone.
			t.expect(snapshot.settings.units).toBe("kph")
			t.expect(uids(snapshot)).toEqual({ "fav", "new", "old" })
		end)

		t.it("ignores a patch with a value the server would refuse", function()
			local snapshot = ProfileController.normalize(payload())
			assert(snapshot, "normalized")
			local merged = ProfileController.merge(snapshot, {
				settings = { camera = { value = "drone", untilTime = 10 } },
				favorites = {},
			})
			t.expect(merged.settings.camera).toBe("hood")
		end)

		t.it("drops patches once the server agrees, once their wait is over, or when the car is gone", function()
			local snapshot = ProfileController.normalize(payload())
			assert(snapshot, "normalized")
			local patches: ProfileController.Patches = {
				settings = {
					units = { value = "kph", untilTime = 10 }, -- the snapshot already says kph
					camera = { value = "orbit", untilTime = 10 }, -- still waiting
					musicVolume = { value = 0.9, untilTime = 4 }, -- waited too long
				},
				favorites = {
					fav = { value = true, untilTime = 10 }, -- confirmed
					new = { value = true, untilTime = 10 }, -- still waiting
					sold = { value = true, untilTime = 10 }, -- no longer owned
				},
			}
			ProfileController.prune(snapshot, patches, 5)
			t.expect(patches.settings.units).toBe(nil)
			t.expect(patches.settings.camera ~= nil).toBe(true)
			t.expect(patches.settings.musicVolume).toBe(nil)
			t.expect(patches.favorites.fav).toBe(nil)
			t.expect(patches.favorites.new ~= nil).toBe(true)
			t.expect(patches.favorites.sold).toBe(nil)
		end)
	end)

	t.describe("HUD speed and GPS distance units", function()
		t.it("shows mph rounded, never negative", function()
			t.expect(HudController.speedFor(59.6, "mph")).toBe(60)
			t.expect(HudController.speedFor(-12.2, "mph")).toBe(12)
		end)

		t.it("shows km/h for players who picked it", function()
			t.expect(HudController.speedFor(60, "kph")).toBe(97)
			t.expect(HudController.speedFor(100, "kph")).toBe(161)
			t.expect(HudController.speedFor(0, "kph")).toBe(0)
		end)

		t.it("ends the key hint row with the phone key", function()
			local keyboard = HudController.hintsFor("keyboard")
			t.expect(keyboard[#keyboard])
				.toEqual({ keys = PhoneConfig.keyGlyphs.keyboard, label = PhoneConfig.hud.phoneHint })
			local gamepad = HudController.hintsFor("gamepad")
			t.expect(gamepad[#gamepad])
				.toEqual({ keys = PhoneConfig.keyGlyphs.gamepad, label = PhoneConfig.hud.phoneHint })
			t.expect(#keyboard).toBe(#Controls.hints.keyboard + 1)
		end)

		t.it("gives GPS distances in kilometres for km/h players, miles otherwise", function()
			local studsPerKilometer = 1000 / World.metersPerStud
			local studsPerMile = 1609.344 / World.metersPerStud
			t.expect(GpsController.distanceText(studsPerKilometer * 2.34, "kph")).toBe("2.3 km")
			t.expect(GpsController.distanceText(studsPerMile * 1.26, "mph")).toBe("1.3 mi")
			t.expect(GpsController.distanceText(studsPerMile * 1.26)).toBe("1.3 mi")
			t.expect(GpsController.distanceText(1, "kph"))
				.toBe(string.format(PhoneConfig.distance.kilometersFormat, PhoneConfig.distance.minKilometers))
		end)
	end)
end
