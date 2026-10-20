--!strict
-- The live preview on the player's own car, on this client only (docs/phase-7-contracts.md "Client").
--
-- apply(car, look) puts a look on the car with Vehicle/Appearance.apply, the same code the server runs when a car
-- spawns or a purchase lands, so what the player sees is what they buy. Nobody else sees it: these are local
-- edits to the car model, which the server never hears of. Appearance records the applied look on the model, and
-- Appearance.lookOf reads it back: on a car this client hasn't touched, that is the server's look (plate text
-- already filtered), which is how the shop knows what the car wears.
--
-- Following the server. Pieces Appearance builds here (wrap vinyl, rims, extras, plates; all tagged
-- Config/Customization.lookTag) are this client's own copies. When the server later puts its own look on the car
-- (after a purchase or a new plate, or for any other reason) its pieces replicate in beside ours and the car would
-- show both. So this module remembers which pieces it built and which look it applied last; when a tagged piece it
-- didn't build lands on such a car, or the car's recorded look changes to one it didn't apply, it calls the
-- handler set with onServerLook (on the next resumption point, once per burst). CustomizationController answers
-- by applying the look the player should see now, which clears every tagged piece and builds one set.
--
-- No polling: one CollectionService added-signal for the tag, and one AttributeChanged connection per car this
-- client has previewed on (dropped when the car is destroyed).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Customization = require(ReplicatedStorage.Shared.Config.Customization)
local Appearance = require(ReplicatedStorage.Shared.Vehicle.Appearance)

export type Look = Customization.Look

-- Told when the server put a look on a car this client previewed on. `look` is the server's new look when the
-- car's record says so; nil when only its pieces have landed so far (the record still matches ours).
export type ServerLookHandler = (car: Model, look: Look?) -> ()

type CarState = {
	own: { [Instance]: boolean }, -- the tagged pieces this client built in its last apply (weak keys)
	ownLook: Look?, -- the look this client applied last, as Appearance recorded it
	serverLook: Look?, -- a server look waiting to be handed over
	scheduled: boolean,
	applying: boolean, -- inside our own Appearance.apply: its signals are ours (whatever Workspace.SignalBehavior)
	connections: { RBXScriptConnection },
}

local Preview = {}

local cars: { [Model]: CarState } = setmetatable({}, { __mode = "k" }) :: any
local handler: ServerLookHandler? = nil
local pieceWatch: RBXScriptConnection? = nil

-- Two recorded looks are the same when every field Appearance uses matches.
local function sameRecord(a: Look, b: Look): boolean
	if a.uid ~= b.uid or a.plateText ~= b.plateText or a.paint ~= b.paint or a.finish ~= b.finish then
		return false
	end
	if a.wrap ~= b.wrap or a.wheels ~= b.wheels or a.rideHeight ~= b.rideHeight or a.tint ~= b.tint then
		return false
	end
	if a.caliper ~= b.caliper or a.plateFormat ~= b.plateFormat or #a.extras ~= #b.extras then
		return false
	end
	for index, id in a.extras do
		if b.extras[index] ~= id then
			return false
		end
	end
	return true
end

-- Hands the car to the handler on the next resumption point (several pieces landing at once make one call).
local function schedule(car: Model, state: CarState)
	if state.scheduled then
		return
	end
	state.scheduled = true
	task.defer(function()
		state.scheduled = false
		if cars[car] ~= state or car.Parent == nil then
			return
		end
		local look = state.serverLook
		state.serverLook = nil
		local current = handler
		if current ~= nil then
			current(car, look)
		end
	end)
end

-- A tagged piece landed somewhere: if it's on a car we previewed on and we didn't build it, the server did.
local function onPieceAdded(instance: Instance)
	for car, state in cars do
		if not state.applying and not state.own[instance] and instance:IsDescendantOf(car) then
			schedule(car, state)
			return
		end
	end
end

local function forget(car: Model)
	local state = cars[car]
	if state == nil then
		return
	end
	cars[car] = nil
	for _, connection in state.connections do
		connection:Disconnect()
	end
end

local function watch(car: Model): CarState
	local existing = cars[car]
	if existing ~= nil then
		return existing
	end
	if pieceWatch == nil then
		pieceWatch = CollectionService:GetInstanceAddedSignal(Customization.lookTag):Connect(onPieceAdded)
	end
	local state: CarState = {
		own = setmetatable({}, { __mode = "k" }) :: any,
		ownLook = nil,
		serverLook = nil,
		scheduled = false,
		applying = false,
		connections = {},
	}
	-- The car's recorded look changed to one we didn't apply: the server put a new look on it.
	table.insert(
		state.connections,
		car.AttributeChanged:Connect(function()
			if state.applying then
				return -- our own apply recording the try-on look, not the server
			end
			local look = Appearance.lookOf(car)
			local own = state.ownLook
			if look == nil or (own ~= nil and sameRecord(look, own)) then
				return
			end
			state.serverLook = look
			schedule(car, state)
		end)
	)
	table.insert(
		state.connections,
		car.Destroying:Connect(function()
			forget(car)
		end)
	)
	cars[car] = state
	return state
end

-- Puts `look` on `car` on this client. Returns false (and warns) if Appearance refused it; the car then keeps
-- whatever it showed before.
function Preview.apply(car: Model, look: Look): boolean
	local state = watch(car)
	-- With immediate signals the pieces and LookData this apply writes would fire our handlers before ownLook is
	-- set; `applying` makes them ignore their own echo.
	state.applying = true
	local ok, err = pcall(Appearance.apply :: any, car, look)
	if not ok then
		warn(`[Customize] couldn't preview the look on {car.Name}: {err}`)
	end
	-- Every tagged piece on the car now is ours (Appearance clears the old ones before it builds).
	local own: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	for _, descendant in car:GetDescendants() do
		if CollectionService:HasTag(descendant, Customization.lookTag) then
			own[descendant] = true
		end
	end
	state.own = own
	state.ownLook = Appearance.lookOf(car)
	state.applying = false
	return ok
end

-- The look the car wears as far as this client knows: the one last applied to it (by the server, or by this
-- client's own preview), or nil if no look was ever applied.
function Preview.lookOf(car: Model): Look?
	return Appearance.lookOf(car)
end

-- Sets who is told when the server puts a look on a car this client previewed on (see the header).
function Preview.onServerLook(callback: ServerLookHandler)
	handler = callback
end

-- True while this client has applied a look to `car` (its pieces there are this client's own copies).
function Preview.isPreviewed(car: Model): boolean
	return cars[car] ~= nil
end

return Preview
