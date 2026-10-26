--!strict
-- Houses (docs/phase-13-contracts.md "Houses"): claiming and releasing plots (one plot per player per server, one
-- player per plot), the upgrade list and its checks, the home charger's rate and price (between the county's public
-- stalls, and only for the owner's own car at their own plot), the garage door's rules and layout, and the house
-- styles (Config/Houses variants): each stays on its plot and out of the garage's bay and the door's swing, keeps
-- its part names apart, paints every part from every one of its palettes, stays inside the part budget, lights its
-- windows and porch lights at night, and puts the upgrades where that style's door, beds and roof are. Pure logic:
-- runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Energy = require(ReplicatedStorage.Shared.Vehicle.Energy)
local EnergyConfig = require(ReplicatedStorage.Shared.Config.Energy)
local Environment = require(ReplicatedStorage.Shared.Config.Environment)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Houses = require(ReplicatedStorage.Shared.Config.Houses)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local HouseService = require(ServerScriptService.Server.Services.HouseService)
local Rules = require(ServerScriptService.Server.Services.EnergyService.Rules)

local ALICE = 101
local BOB = 202
local CAROL = 303
local PLOT_A = "rv_cedar_ct_1"
local PLOT_B = "rv_cedar_ct_2"
local HALF = 0.5 -- a battery level below the charging taper
local PERCENT = 100
local MIN_UPGRADES = 3
local MAX_UPGRADES = 5
local MIN_STYLES = 3 -- "a few" house styles
local EPSILON = 0.01 -- studs a part may touch past an edge (rounding)
local BURIED = 0.6 -- walls and columns may sink this far into the ground
local STYLE_UPGRADES = { "porchLights", "garden", "solarRoof" } -- every style places these itself

-- Every HousePlot location, in MapLayout order.
local function plots(): { MapLayout.Location }
	local list: { MapLayout.Location } = {}
	for _, location in MapLayout.locations do
		if location.tag == Houses.plotTag then
			table.insert(list, location)
		end
	end
	return list
end

local function plotIds(): { string }
	local ids: { string } = {}
	for _, location in plots() do
		table.insert(ids, location.id)
	end
	return ids
end

-- The slowest and fastest public charging stalls' kW (MapLayout ChargerStall attributes).
local function stallRange(): (number, number)
	local slowest, fastest = math.huge, -math.huge
	for _, location in MapLayout.locations do
		local attributes: { [string]: any } = location.attributes or {}
		if location.tag == "ChargerStall" and type(attributes.kW) == "number" then
			slowest = math.min(slowest, attributes.kW)
			fastest = math.max(fastest, attributes.kW)
		end
	end
	return slowest, fastest
end

-- A battery car from the catalog that charges at stalls: its id and default trim id.
local function batteryCar(): (string, string)
	for _, id in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(id)
		local trim = Catalog.defaultTrim(id)
		if
			vehicle ~= nil
			and vehicle.energy == "battery"
			and trim ~= nil
			and trim.energyMinutes ~= nil
			and Energy.isCompatible(id, "ChargerStall")
		then
			return id, trim.id
		end
	end
	error("no battery car in the catalog")
end

local function everyUpgrade(): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	for _, upgrade in Houses.upgrades do
		owned[upgrade.id] = true
	end
	return owned
end

local function pieceNamed(name: string): Houses.Piece
	for _, piece in Houses.structure do
		if piece.name == name then
			return piece
		end
	end
	error(`no structure piece {name}`)
end

local function variantPiece(variant: Houses.Variant, name: string): Houses.Piece
	for _, piece in variant.pieces do
		if piece.name == name then
			return piece
		end
	end
	error(`{variant.id} has no piece {name}`)
end

-- The parts an upgrade adds to a house in this style (its own, else the shared ones).
local function extrasOf(variant: Houses.Variant, id: string): { Houses.Piece }
	return variant.extras[id] or Houses.extras[id] or {}
end

-- Every piece a house in this style can show at once: the garage, the style, the plain mailbox and every upgrade's
-- parts but the painted mailbox (it takes the plain one's place, names and all).
local function everyPiece(variant: Houses.Variant): { Houses.Piece }
	local list: { Houses.Piece } = table.clone(Houses.structure)
	table.move(variant.pieces, 1, #variant.pieces, #list + 1, list)
	table.move(Houses.plainMailbox, 1, #Houses.plainMailbox, #list + 1, list)
	for _, upgrade in Houses.upgrades do
		if upgrade.id ~= Houses.plainMailboxReplacedBy then
			local extra = extrasOf(variant, upgrade.id)
			table.move(extra, 1, #extra, #list + 1, list)
		end
	end
	return list
end

-- The parts HouseService builds besides the pieces: the door, the charger bay and the door's sensor.
local FIXED_PARTS = { Houses.door.name, Houses.chargerPad.name, Houses.door.sensorName }

local function describe(v: Vector3): string
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

return function(t: Harness.Api)
	t.describe("Houses", function()
		t.describe("plots", function()
			t.it("has HousePlots in Riverside, each with its own id and address", function()
				local ids = plotIds()
				t.expect(#ids > 0).toBe(true)
				local seenIds: { [string]: boolean } = {}
				local seenAddresses: { [string]: boolean } = {}
				for _, location in plots() do
					t.expect(location.zone).toBe("riverside")
					t.expect(seenIds[location.id]).toBe(nil)
					t.expect(seenAddresses[location.displayName]).toBe(nil)
					seenIds[location.id] = true
					seenAddresses[location.displayName] = true
				end
				t.expect(seenIds[PLOT_A]).toBe(true)
				t.expect(seenIds[PLOT_B]).toBe(true)
			end)

			t.it("leads the Home app's directions to a HousePlot the GPS lists", function()
				local found = false
				for _, location in MapLayout.locations do
					if location.id == Houses.directionsPlot then
						found = location.tag == Houses.plotTag and location.gps == true
					end
				end
				t.expect(found).toBe(true)
			end)
		end)

		t.describe("styles", function()
			t.it(`has at least {MIN_STYLES} styles, each with its own id and at least one palette`, function()
				t.expect(#Houses.variants >= MIN_STYLES).toBe(true)
				local seen: { [string]: boolean } = {}
				for _, variant in Houses.variants do
					t.expect(seen[variant.id]).toBe(nil)
					seen[variant.id] = true
					t.expect(#variant.palettes > 0).toBe(true)
					t.expect(#variant.pieces > 0).toBe(true)
				end
			end)

			t.it("deals every plot a style and palette, the same every time, neighbours never alike", function()
				local count = #plots()
				local used: { [number]: boolean } = {}
				local last: number? = nil
				for index = 1, count do
					local variant, colors = Houses.styleOf(index)
					local again, sameColors = Houses.styleOf(index)
					t.expect(`{index}: {again},{sameColors}`).toBe(`{index}: {variant},{colors}`)
					t.expect(variant >= 1 and variant <= #Houses.variants).toBe(true)
					t.expect(colors >= 1 and colors <= #Houses.variants[variant].palettes).toBe(true)
					t.expect(`{index}: {variant ~= last}`).toBe(`{index}: true`)
					used[variant] = true
					last = variant
				end
				if count >= #Houses.variants then
					for variant = 1, #Houses.variants do
						t.expect(`{Houses.variants[variant].id} used: {used[variant] == true}`)
							.toBe(`{Houses.variants[variant].id} used: true`)
					end
				end
			end)

			t.it("keeps every part on the plot and under the height limit", function()
				local footprint = plots()[1].size
				local hx, hz = footprint.X / 2 + EPSILON, footprint.Z / 2 + EPSILON
				for _, variant in Houses.variants do
					local list = everyPiece(variant)
					table.move(Houses.extras.mailbox, 1, #Houses.extras.mailbox, #list + 1, list)
					for _, piece in list do
						local reach = Houses.reach(piece)
						local lo, hi = piece.offset - reach, piece.offset + reach
						local fits = lo.X >= -hx
							and hi.X <= hx
							and lo.Z >= -hz
							and hi.Z <= hz
							and lo.Y >= -BURIED - EPSILON
							and hi.Y <= Houses.maxHeight
						t.expect(`{variant.id}.{piece.name} {describe(lo)}..{describe(hi)} fits: {fits}`)
							.toBe(`{variant.id}.{piece.name} {describe(lo)}..{describe(hi)} fits: true`)
					end
				end
			end)

			t.it("keeps out of the garage's bay and the door's swing", function()
				for _, variant in Houses.variants do
					local list: { Houses.Piece } = table.clone(variant.pieces)
					for _, extra in variant.extras do
						table.move(extra, 1, #extra, #list + 1, list)
					end
					for _, piece in list do
						local frame = Houses.pieceFrame(piece, CFrame.identity)
						for index, zone in Houses.garageClear do
							local hits = HouseService.overlapsBox(CFrame.new(zone.offset), zone.size, frame, piece.size)
							t.expect(`{variant.id}.{piece.name} in garage zone {index}: {hits}`)
								.toBe(`{variant.id}.{piece.name} in garage zone {index}: false`)
						end
					end
				end
			end)

			t.it("names every part of a house once", function()
				for _, variant in Houses.variants do
					local seen: { [string]: boolean } = {}
					for _, name in FIXED_PARTS do
						seen[name] = true
					end
					for _, piece in everyPiece(variant) do
						t.expect(`{variant.id}.{piece.name} twice: {seen[piece.name] == true}`)
							.toBe(`{variant.id}.{piece.name} twice: false`)
						seen[piece.name] = true
					end
					-- The painted mailbox reuses the plain one's names (it replaces it), and nothing else's.
					for _, piece in Houses.extras.mailbox do
						local plain = false
						for _, other in Houses.plainMailbox do
							plain = plain or other.name == piece.name
						end
						local clash = seen[piece.name] == true and not plain
						t.expect(`{variant.id}.{piece.name} clashes: {clash}`)
							.toBe(`{variant.id}.{piece.name} clashes: false`)
					end
				end
			end)

			t.it("paints every part from every palette of its style", function()
				local doorPiece: Houses.Piece = {
					name = Houses.door.name,
					offset = Houses.door.offset,
					size = Houses.door.size,
					paint = Houses.door.paint,
					solid = true,
				}
				for _, variant in Houses.variants do
					local list = everyPiece(variant)
					table.insert(list, doorPiece)
					for index, colors in variant.palettes do
						for _, piece in list do
							local painted = Houses.lookOf(piece, colors) ~= nil
							t.expect(`{variant.id} palette {index} paints {piece.name}: {painted}`)
								.toBe(`{variant.id} palette {index} paints {piece.name}: true`)
						end
					end
				end
			end)

			t.it("stays inside the part budget with every upgrade on", function()
				for _, variant in Houses.variants do
					local count = #everyPiece(variant) + #FIXED_PARTS
					-- The painted mailbox in place of the plain one, if it has more parts.
					count += math.max(#Houses.extras.mailbox - #Houses.plainMailbox, 0)
					t.expect(`{variant.id}: {count} parts, within {Houses.partBudget}: {count <= Houses.partBudget}`)
						.toBe(`{variant.id}: {count} parts, within {Houses.partBudget}: true`)
				end
			end)

			t.it("places the porch lights, the garden and the solar panels for each style", function()
				for _, variant in Houses.variants do
					for _, id in STYLE_UPGRADES do
						local extra = variant.extras[id]
						t.expect(`{variant.id}.{id}: {extra ~= nil and #extra > 0}`).toBe(`{variant.id}.{id}: true`)
					end
					local names: { [string]: boolean } = {}
					for _, piece in extrasOf(variant, "porchLights") do
						names[piece.name] = piece.glow == true
					end
					t.expect(`{variant.id} lamps glow: {names.PorchLightLeft},{names.PorchLightRight}`)
						.toBe(`{variant.id} lamps glow: true,true`)
					local panels = 0
					for _, piece in extrasOf(variant, "solarRoof") do
						if string.find(piece.name, "SolarPanel", 1, true) == 1 then
							panels += 1
						end
					end
					t.expect(`{variant.id} solar panels: {panels >= 2}`).toBe(`{variant.id} solar panels: true`)
				end
			end)

			t.it("lights the windows and porch lights at night, as kinds Services/DayNightService knows", function()
				for _, variant in Houses.variants do
					local windows = 0
					local lit: { [string]: string } = {}
					for _, piece in everyPiece(variant) do
						local night = piece.night
						if night ~= nil then
							t.expect(`{variant.id}.{piece.name}: {Environment.nightLights.kinds[night] ~= nil}`)
								.toBe(`{variant.id}.{piece.name}: true`)
							lit[piece.name] = night
							if night == "window" then
								windows += 1
							end
						end
					end
					t.expect(`{variant.id} lit windows: {windows >= 2}`).toBe(`{variant.id} lit windows: true`)
					t.expect(`{variant.id}: {lit.PorchLightLeft},{lit.PorchLightRight}`)
						.toBe(`{variant.id}: streetlight,streetlight`)
					-- Solar panels are glass too, but stay dark.
					t.expect(`{variant.id}: {lit.SolarPanelLeft}`).toBe(`{variant.id}: nil`)
				end
			end)

			t.it("keeps glass opaque and only rails see-through", function()
				for _, variant in Houses.variants do
					for _, piece in everyPiece(variant) do
						local look = Houses.lookOf(piece, variant.palettes[1])
						local clear = if look ~= nil then look.transparency or 0 else 0
						local ok = clear == 0 or string.find(piece.name, "Rail", 1, true) ~= nil
						t.expect(`{variant.id}.{piece.name} transparency {clear}: {ok}`)
							.toBe(`{variant.id}.{piece.name} transparency {clear}: true`)
					end
				end
			end)

			t.it("casts no shadow from slivers and see-through parts, and keeps shadows on masses", function()
				local sliver: Houses.Piece =
					{ name = "Sliver", offset = Vector3.zero, size = Vector3.new(0.3, 8, 0.3), solid = false }
				local slab: Houses.Piece =
					{ name = "Slab", offset = Vector3.zero, size = Vector3.new(20, 0.6, 3), solid = false }
				local rail: Houses.Piece = {
					name = "Rail",
					offset = Vector3.zero,
					size = Vector3.new(20, 3, 0.2),
					solid = false,
					transparency = 0.55,
				}
				t.expect(Houses.castsShadow(sliver)).toBe(false)
				t.expect(Houses.castsShadow(slab)).toBe(true)
				t.expect(Houses.castsShadow(rail)).toBe(false)
				sliver.shadow = true
				t.expect(Houses.castsShadow(sliver)).toBe(true)
			end)
		end)

		t.describe("claims", function()
			t.it("lets a player claim a free plot", function()
				local claims = HouseService.newClaims()
				t.expect(HouseService.claimRefusal(claims, ALICE, PLOT_A, true)).toBe(nil)
				t.expect(HouseService.claim(claims, ALICE, PLOT_A)).toBe(true)
				t.expect(HouseService.ownerOf(claims, PLOT_A)).toBe(ALICE)
				t.expect(HouseService.plotOf(claims, ALICE)).toBe(PLOT_A)
			end)

			t.it("refuses a plot that isn't on the map", function()
				local claims = HouseService.newClaims()
				t.expect(HouseService.claimRefusal(claims, ALICE, "nowhere", false)).toBe("noPlot")
			end)

			t.it("says the plot is already yours", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, ALICE, PLOT_A)
				t.expect(HouseService.claimRefusal(claims, ALICE, PLOT_A, true)).toBe("yours")
			end)

			t.it("refuses someone else's plot", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, ALICE, PLOT_A)
				t.expect(HouseService.claimRefusal(claims, BOB, PLOT_A, true)).toBe("taken")
				t.expect(HouseService.claimRefusal(claims, CAROL, PLOT_A, true)).toBe("taken")
				t.expect(HouseService.claim(claims, BOB, PLOT_A)).toBe(false)
				t.expect(HouseService.ownerOf(claims, PLOT_A)).toBe(ALICE)
				t.expect(HouseService.plotOf(claims, BOB)).toBe(nil)
			end)

			t.it("allows one plot per player: every other plot is refused while they hold one", function()
				local claims = HouseService.newClaims()
				local ids = plotIds()
				t.expect(HouseService.claim(claims, ALICE, ids[1])).toBe(true)
				for index = 2, #ids do
					t.expect(HouseService.claimRefusal(claims, ALICE, ids[index], true)).toBe("hasHouse")
					t.expect(HouseService.claim(claims, ALICE, ids[index])).toBe(false)
					t.expect(HouseService.ownerOf(claims, ids[index])).toBe(nil)
				end
				t.expect(HouseService.plotOf(claims, ALICE)).toBe(ids[1])
			end)

			t.it("checks the player before the plot: a player with a house is told so even at a taken plot", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, ALICE, PLOT_A)
				HouseService.claim(claims, BOB, PLOT_B)
				t.expect(HouseService.claimRefusal(claims, ALICE, PLOT_B, true)).toBe("hasHouse")
			end)

			t.it("frees the plot when the player leaves, so someone else can claim it", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, ALICE, PLOT_A)
				t.expect(HouseService.release(claims, ALICE)).toBe(PLOT_A)
				t.expect(HouseService.ownerOf(claims, PLOT_A)).toBe(nil)
				t.expect(HouseService.plotOf(claims, ALICE)).toBe(nil)
				t.expect(HouseService.claimRefusal(claims, BOB, PLOT_A, true)).toBe(nil)
				t.expect(HouseService.claim(claims, BOB, PLOT_A)).toBe(true)
				t.expect(HouseService.ownerOf(claims, PLOT_A)).toBe(BOB)
			end)

			t.it("lets a player claim again after leaving", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, ALICE, PLOT_A)
				HouseService.release(claims, ALICE)
				t.expect(HouseService.claimRefusal(claims, ALICE, PLOT_B, true)).toBe(nil)
				t.expect(HouseService.claim(claims, ALICE, PLOT_B)).toBe(true)
				t.expect(HouseService.ownerOf(claims, PLOT_A)).toBe(nil)
			end)

			t.it("refuses a claim while a car or a player stands where a wall would appear, in every style", function()
				local frame = Houses.plotFrame(Vector3.new(100, 5, -40), 90)
				local car = Vector3.new(7, 4, 16)
				local door = Houses.door
				local pad = Houses.chargerPad
				for _, variant in Houses.variants do
					local boxes = HouseService.lotBoxes(frame, variant)
					local expected = if Houses.lotClear.door then 1 else 0
					for _, pieces in { Houses.structure, variant.pieces } do
						for _, piece in pieces do
							if HouseService.mustBeClear(piece) then
								expected += 1
							end
						end
					end
					t.expect(`{variant.id}: {#boxes}`).toBe(`{variant.id}: {expected}`)
					local body = variantPiece(variant, "Body")
					local inBody = { frame = frame * CFrame.new(body.offset.X, car.Y / 2, body.offset.Z), size = car }
					local person =
						{ frame = frame * CFrame.new(body.offset.X, 3, body.offset.Z), size = Vector3.new(2, 2, 1) }
					local inDoorway =
						{ frame = frame * CFrame.new(door.offset.X, car.Y / 2, door.offset.Z), size = car }
					t.expect(`{variant.id} car in the house: {HouseService.lotBlocked(boxes, { inBody })}`)
						.toBe(`{variant.id} car in the house: true`)
					t.expect(`{variant.id} player in the house: {HouseService.lotBlocked(boxes, { person })}`)
						.toBe(`{variant.id} player in the house: true`)
					t.expect(`{variant.id} car in the doorway: {HouseService.lotBlocked(boxes, { inDoorway })}`)
						.toBe(`{variant.id} car in the doorway: true`)
					-- A car on the driveway or on the charger bay isn't in a wall's way.
					local onDriveway = { frame = frame * CFrame.new(door.offset.X, car.Y / 2, -12), size = car }
					local onPad = { frame = frame * CFrame.new(pad.offset.X, car.Y / 2, pad.offset.Z), size = car }
					t.expect(`{variant.id} driveway and bay: {HouseService.lotBlocked(boxes, { onDriveway, onPad })}`)
						.toBe(`{variant.id} driveway and bay: false`)
					t.expect(HouseService.lotBlocked(boxes, {})).toBe(false)
				end
			end)

			t.it("checks walls and masses but not floor slabs or roofs", function()
				local function piece(y0: number, y1: number, solid: boolean): Houses.Piece
					return {
						name = "Test",
						offset = Vector3.new(0, (y0 + y1) / 2, 0),
						size = Vector3.new(4, y1 - y0, 4),
						solid = solid,
					}
				end
				t.expect(HouseService.mustBeClear(piece(-0.5, 11, true))).toBe(true) -- a wall
				t.expect(HouseService.mustBeClear(piece(0, 0.35, true))).toBe(false) -- a slab
				t.expect(HouseService.mustBeClear(piece(11, 12, true))).toBe(false) -- a roof
				t.expect(HouseService.mustBeClear(piece(-0.5, 11, false))).toBe(false) -- trim
			end)

			t.it("releasing with no plot changes nothing", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, BOB, PLOT_B)
				t.expect(HouseService.release(claims, ALICE)).toBe(nil)
				t.expect(HouseService.ownerOf(claims, PLOT_B)).toBe(BOB)
			end)
		end)

		t.describe("upgrades", function()
			t.it(
				`lists {MIN_UPGRADES} to {MAX_UPGRADES} upgrades with their own ids, words and whole prices`,
				function()
					local count = #Houses.upgrades
					t.expect(count >= MIN_UPGRADES and count <= MAX_UPGRADES).toBe(true)
					local seen: { [string]: boolean } = {}
					for _, upgrade in Houses.upgrades do
						t.expect(seen[upgrade.id]).toBe(nil)
						seen[upgrade.id] = true
						t.expect(#upgrade.name > 0 and #upgrade.description > 0).toBe(true)
						t.expect(upgrade.price > 0 and upgrade.price == math.floor(upgrade.price)).toBe(true)
						t.expect(Houses.upgrade(upgrade.id)).toBe(upgrade)
					end
				end
			)

			t.it("reads only known upgrades marked true from a save", function()
				t.expect(Houses.cleanUpgrades(nil)).toEqual({})
				t.expect(Houses.cleanUpgrades("junk")).toEqual({})
				t.expect(Houses.cleanUpgrades({ porchLights = true, garden = false, rocket = true, mailbox = 1 }))
					.toEqual({ porchLights = true })
			end)

			t.it("lists owned upgrades in the catalog's order", function()
				t.expect(Houses.ownedList({ mailbox = true, fastCharger = true })).toEqual({ "fastCharger", "mailbox" })
				t.expect(Houses.ownedList({})).toEqual({})
			end)

			t.it("refuses an unknown upgrade, one already owned, and one the player can't afford", function()
				local upgrade = Houses.upgrades[1]
				t.expect(Houses.buyRefusal({}, "rocket", math.huge)).toBe("unknown")
				t.expect(Houses.buyRefusal({ [upgrade.id] = true }, upgrade.id, math.huge)).toBe("owned")
				t.expect(Houses.buyRefusal({}, upgrade.id, upgrade.price - 1)).toBe("cash")
				t.expect(Houses.buyRefusal({}, upgrade.id, 0 / 0)).toBe("cash")
				t.expect(Houses.buyRefusal({}, upgrade.id, upgrade.price)).toBe(nil)
			end)
		end)

		t.describe("home charging", function()
			t.it(
				"is faster than the slowest public stall and slower than the fastest, with or without upgrades",
				function()
					local slowest, fastest = stallRange()
					for _, owned in { {}, everyUpgrade() } :: { { [string]: boolean } } do
						local kW = Houses.chargerKW(owned)
						t.expect(kW > slowest and kW < fastest).toBe(true)
					end
					t.expect(Houses.chargerKW({})).toBe(EnergyConfig.home.kW)
					t.expect(Houses.chargerKW(everyUpgrade()) > Houses.chargerKW({})).toBe(true)
				end
			)

			t.it("charges a battery car between the slowest and fastest stalls' speeds", function()
				local slowest, fastest = stallRange()
				local id, trim = batteryCar()
				local function rate(kW: number): number
					return Energy.chargeRatePerSecond("ChargerStall", { kW = kW }, id, trim, HALF)
				end
				local home = rate(Rules.homeKW(Houses.chargerKW({}), EnergyConfig.home.kW))
				t.expect(home > rate(slowest)).toBe(true)
				t.expect(home < rate(fastest)).toBe(true)
			end)

			t.it("costs less than a public stall, in whole dollars per percent", function()
				for _, owned in { {}, { solarRoof = true }, everyUpgrade() } :: { { [string]: boolean } } do
					local cost = Houses.chargerCostPerFull(owned)
					t.expect(cost >= 0 and cost < Energy.costPerFraction("ChargerStall")).toBe(true)
					t.expect(cost % PERCENT).toBe(0)
				end
				t.expect(Houses.chargerCostPerFull({})).toBe(EnergyConfig.home.costPerFull)
				t.expect(Houses.chargerCostPerFull({ solarRoof = true }) < Houses.chargerCostPerFull({})).toBe(true)
			end)

			t.it("charges only the owner's own car", function()
				t.expect(Rules.homeChargeAllowed(ALICE, ALICE, false)).toBe(true)
				t.expect(Rules.homeChargeAllowed(ALICE, BOB, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(ALICE, nil, false)).toBe(false) -- a stand-in the server spawned
				t.expect(Rules.homeChargeAllowed(nil, nil, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(nil, ALICE, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(0, 0, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(ALICE, tostring(ALICE), false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(ALICE, ALICE, true)).toBe(false) -- a test drive
				t.expect(Rules.homeChargeAllowed(0 / 0, 0 / 0, false)).toBe(false)
			end)

			t.it("works with Studio's negative playtest UserIds", function()
				t.expect(Rules.homeChargeAllowed(-1, -1, false)).toBe(true)
				t.expect(Rules.homeChargeAllowed(-1, -2, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(-1, nil, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(-1, -1, true)).toBe(false)
			end)

			t.it("gives the home rate only at the owner's own plot", function()
				local claims = HouseService.newClaims()
				HouseService.claim(claims, ALICE, PLOT_A)
				HouseService.claim(claims, BOB, PLOT_B)
				-- Each plot's charger carries its owner (HouseService puts it on the pad).
				local chargerOwnerA = HouseService.ownerOf(claims, PLOT_A)
				local chargerOwnerB = HouseService.ownerOf(claims, PLOT_B)
				t.expect(Rules.homeChargeAllowed(chargerOwnerA, ALICE, false)).toBe(true)
				t.expect(Rules.homeChargeAllowed(chargerOwnerB, ALICE, false)).toBe(false)
				t.expect(Rules.homeChargeAllowed(chargerOwnerB, BOB, false)).toBe(true)
				t.expect(Rules.homeChargeAllowed(chargerOwnerA, BOB, false)).toBe(false)
				-- Once Alice moves out, nobody's car charges at her old plot.
				HouseService.release(claims, ALICE)
				t.expect(Rules.homeChargeAllowed(HouseService.ownerOf(claims, PLOT_A), ALICE, false)).toBe(false)
			end)

			t.it("reads a charger's kW and price from its attributes, with safe fallbacks", function()
				local baseKW, basePrice = EnergyConfig.home.kW, EnergyConfig.home.costPerFull
				t.expect(Rules.homeKW(300, baseKW)).toBe(300)
				t.expect(Rules.homeKW(nil, baseKW)).toBe(baseKW)
				t.expect(Rules.homeKW(-5, baseKW)).toBe(baseKW)
				t.expect(Rules.homeKW(0 / 0, baseKW)).toBe(baseKW)
				t.expect(Rules.homeCostPerFull(100, basePrice)).toBe(100)
				t.expect(Rules.homeCostPerFull(0, basePrice)).toBe(0)
				t.expect(Rules.homeCostPerFull(basePrice * 10, basePrice)).toBe(basePrice) -- never above the base
				t.expect(Rules.homeCostPerFull(nil, basePrice)).toBe(basePrice)
				t.expect(Rules.homeCostPerFull(-1, basePrice)).toBe(basePrice)
				t.expect(Rules.homeCostPerFull(math.huge, basePrice)).toBe(basePrice)
			end)
		end)

		t.describe("garage door", function()
			t.it("opens only for the owner's own car", function()
				t.expect(HouseService.opensFor(ALICE, ALICE)).toBe(true)
				t.expect(HouseService.opensFor(ALICE, BOB)).toBe(false)
				t.expect(HouseService.opensFor(ALICE, nil)).toBe(false)
				t.expect(HouseService.opensFor(nil, ALICE)).toBe(false)
				t.expect(HouseService.opensFor(ALICE, tostring(ALICE))).toBe(false)
			end)

			t.it("tells points inside a turned box from points outside it", function()
				local frame = CFrame.new(10, 2, -4) * CFrame.Angles(0, math.rad(90), 0)
				local size = Vector3.new(4, 2, 10)
				t.expect(HouseService.insideBox(frame, size, frame.Position)).toBe(true)
				-- 4 studs along the box's own Z (its long side) is inside; 4 along its X (short side) is not.
				t.expect(HouseService.insideBox(frame, size, (frame * CFrame.new(0, 0, 4)).Position)).toBe(true)
				t.expect(HouseService.insideBox(frame, size, (frame * CFrame.new(4, 0, 0)).Position)).toBe(false)
				t.expect(HouseService.insideBox(frame, size, (frame * CFrame.new(0, 3, 0)).Position)).toBe(false)
			end)

			t.it(
				"lays out the bay: the charger inside the sensor, behind the door, in front of the back wall",
				function()
					local door = Houses.door
					local pad = Houses.chargerPad
					local sensor = CFrame.new(door.sensorOffset)
					t.expect(HouseService.insideBox(sensor, door.sensorSize, pad.offset)).toBe(true)
					local padFront = pad.offset.Z - pad.size.Z / 2
					local padBack = pad.offset.Z + pad.size.Z / 2
					t.expect(padFront > door.offset.Z + door.size.Z / 2).toBe(true)
					local back = pieceNamed("GarageWallBack")
					t.expect(padBack < back.offset.Z - back.size.Z / 2).toBe(true)
				end
			)

			t.it("keeps the bay 16 wide between the garage walls and the door as wide as the bay", function()
				local inner, outer = pieceNamed("GarageWallInner"), pieceNamed("GarageWallOuter")
				local bay = (outer.offset.X - outer.size.X / 2) - (inner.offset.X + inner.size.X / 2)
				t.expect(bay).toBe(Houses.door.size.X)
				t.expect(Houses.door.size.X >= 16).toBe(true)
			end)

			t.it("tells boxes that overlap from boxes beside or touching them, turned or not", function()
				local frame = CFrame.new()
				local size = Vector3.new(4, 4, 4)
				local stick = Vector3.new(4, 1, 1)
				t.expect(HouseService.overlapsBox(frame, size, CFrame.new(3, 0, 0), stick)).toBe(true)
				t.expect(HouseService.overlapsBox(frame, size, CFrame.new(4, 0, 0), stick)).toBe(false) -- touching
				t.expect(HouseService.overlapsBox(frame, size, CFrame.new(0, 0, 5), Vector3.new(1, 1, 4))).toBe(false)
				-- Turned a quarter about Y, a long box's length lies along X.
				local long = Vector3.new(1, 1, 8)
				local turned = CFrame.new(5, 0, 0) * CFrame.Angles(0, math.rad(90), 0)
				t.expect(HouseService.overlapsBox(frame, size, turned, long)).toBe(true)
				t.expect(HouseService.overlapsBox(frame, size, CFrame.new(5, 0, 0), long)).toBe(false)
			end)

			t.it("closes behind a car parked in the bay, but not on one standing in the doorway", function()
				local door = Houses.door
				local doorway = CFrame.new(door.offset)
				t.expect(door.doorwaySize.X >= door.size.X and door.doorwaySize.Y >= door.size.Y).toBe(true)
				t.expect(door.doorwaySize.Z > door.size.Z).toBe(true)
				t.expect(HouseService.overlapsBox(doorway, door.doorwaySize, doorway, door.size)).toBe(true)
				-- The biggest catalog car (18 long, 7 wide, 6.2 tall), pulled all the way in to the back wall.
				local car = Vector3.new(7, 6.2, 18)
				local back = pieceNamed("GarageWallBack")
				local wallFace = back.offset.Z - back.size.Z / 2
				local parked = CFrame.new(door.offset.X, car.Y / 2, wallFace - car.Z / 2)
				t.expect(HouseService.overlapsBox(doorway, door.doorwaySize, parked, car)).toBe(false)
				-- Halfway through the opening.
				local straddling = CFrame.new(door.offset.X, car.Y / 2, door.offset.Z)
				t.expect(HouseService.overlapsBox(doorway, door.doorwaySize, straddling, car)).toBe(true)
			end)

			t.it("closes to the ground and opens clear of the doorway, under the roof", function()
				local door = Houses.door
				local header = pieceNamed("GarageHeader")
				local roof = pieceNamed("GarageRoof")
				t.expect(door.offset.Y - door.size.Y / 2).toBe(0)
				-- Open, it lies flat (turned openTilt about X), so its thickness is its height.
				t.expect(door.openTilt).toBe(90)
				t.expect(door.openOffset.Y - door.size.Z / 2 >= header.offset.Y - header.size.Y / 2).toBe(true)
				t.expect(door.openOffset.Y + door.size.Z / 2 <= roof.offset.Y - roof.size.Y / 2).toBe(true)
			end)

			t.it("sweeps only through the garage's clear zones as it swings", function()
				local door = Houses.door
				local closed = CFrame.new(door.offset)
				local open = CFrame.new(door.openOffset) * CFrame.Angles(math.rad(door.openTilt), 0, 0)
				for step = 0, 10 do
					local frame = closed:Lerp(open, step / 10)
					-- Every corner of the door inside one of the zones (grown a hair for rounding).
					for _, x in { -1, 1 } do
						for _, y in { -1, 1 } do
							for _, z in { -1, 1 } do
								local point = (frame * CFrame.new(door.size * Vector3.new(x, y, z) / 2)).Position
								local inside = false
								for _, zone in Houses.garageClear do
									local grown = zone.size + Vector3.new(0.2, 0.8, 0.2)
									inside = inside or HouseService.insideBox(CFrame.new(zone.offset), grown, point)
								end
								t.expect(`step {step} corner {describe(point)} clear: {inside}`)
									.toBe(`step {step} corner {describe(point)} clear: true`)
							end
						end
					end
				end
			end)
		end)
	end)
end
