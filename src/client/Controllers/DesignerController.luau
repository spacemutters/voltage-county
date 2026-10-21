--!strict
-- The AI Car Designer on the client (docs/phase-11-contracts.md "Client"; PLAN.md Phase 11). Owns the
-- "DesignStudio" ScreenGui and draws the designer's sheets with the shop kit (UI/Shop/ShopSheet, content from
-- UI/Designer/StudioSheet):
--
--   opening      a "Design a car" prompt this client puts on the Design Studio's location part (Config/MapLayout
--                pl_design_studio, found by its CollectionService tag); the first visit unlocks the phone's
--                Designer app (UI/Designer/DesignerStore), which opens the studio from anywhere after that. The
--                Garage app's "Mod with AI" and "Report" on each car open those sheets. Opening puts the phone away.
--   AI notice    before the player's first request the sheet shows the AI notice; "Got it" sets the LocalPlayer
--                attribute DesignerStyle.attributes.disclosureSeen. A profile with any design, mod or the free car
--                used counts as seen (DesignerModel.disclosureNeeded), so it shows once per player.
--   new car      the prompt (200 characters, counted), a class or "Surprise me", the cost ("Free" for the first
--                car): Design it -> Net DesignCar { prompt, classId? }. Not enough credits opens the Out of credits
--                sheet instead (Get credits opens the store's stub until Phase 12, and fires onGetCredits).
--   progress     until Net DesignResult { requestId, ok, message, design?, preview? } arrives for the request. The
--                sheet can be closed meanwhile; the answer shows as a notice and waits in the studio.
--   result       a preview built here with Vehicle/SpecBuilder from the spec (or the server's preview model), the
--                name, tagline and stats (SpecBuilder.stats): Build / Re-roll / Discard -> Net DesignChoice.
--                Re-roll is free while the design has a free one (the server's `rerollFree`; else Config/Designer
--                prices.rerollsPaid with a paid design, rerollsFree with the free car); after that it makes a new
--                paid design, so it needs the credits. Discard asks first. After Build, Drive it spawns the car (Net SpawnOwned) when the server said which.
--   mods         "Mod with AI": the car as it is (the player's car out in the world, or a design rebuilt from its
--                spec), the prompt and the cost -> Net ModCar { uid, prompt }; the result shows before and after
--                (Vehicle/ModBuilder on a copy of the car, or the server's preview).
--   report       reasons from Config/Designer (DesignerModel.reportReasons) -> Net ReportDesign { uid, reason }: an
--                owned car's uid from the Garage and the mod result, the requestId of a design not yet built.
--   closing      the close button, a tap on the dim area, gamepad B (above the phone's own Back), getting into a
--                car, the character resetting, or a pod ride's cutscene (the GUI hides while
--                PhoneConfig.cutsceneAttribute is true, like the other screens).
--
-- Server-authoritative: every one of these is a request. The server filters the text, checks and spends the
-- credits and decides every outcome; its words show as notices. One request at a time. Previews are built on this
-- client only, from specs the server already validated. No polling: prompt, remote, profile and attribute events,
-- and task.delay for the slow / give-up notes.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Spawning = require(ReplicatedStorage.Shared.Config.Spawning)
local Types = require(ReplicatedStorage.Shared.Types)
local DriveController = require(script.Parent.DriveController)
local HudController = require(script.Parent.HudController)
local InputController = require(script.Parent.InputController)
local NotifyController = require(script.Parent.NotifyController)
local PhoneController = require(script.Parent.PhoneController)
local ProfileController = require(script.Parent.ProfileController)

local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local PhoneConfig = require(UI.Phone.PhoneConfig)
local Primitives = require(UI.Shop.Primitives)
local ShopModel = require(UI.Shop.ShopModel)
local ShopSheet = require(UI.Shop.ShopSheet)
local DesignerModel = require(UI.Designer.DesignerModel)
local DesignerStore = require(UI.Designer.DesignerStore)
local DesignerStyle = require(UI.Designer.DesignerStyle)
local StudioSheet = require(UI.Designer.StudioSheet)

local GUI_NAME = "DesignStudio"
local CLOSE_ACTION = "DesignerClose"
local CLOSE_PRIORITY = Controls.actionPriority + DesignerStyle.priorityAbovePhone
local MAX_EARLY_RESULTS = 8 -- results that came before their request's reply (or after it was given up), kept

local e = React.createElement
local copy = DesignerStyle.copy

type Kind = DesignerModel.Kind
type Step =
	"disclosure"
	| "compose"
	| "progress"
	| "result"
	| "refused"
	| "built"
	| "modCompose"
	| "modResult"
	| "outOfCredits"
	| "store"
	| "report"

-- The sheet on screen.
type Sheet = {
	step: Step,
	kind: Kind, -- the flow it belongs to (a new car or a mod)
	back: Step?, -- where Got it, Not now, Back and a sent report go (nil: close)
	refusal: string, -- the refused screen's message
	reportTarget: string?, -- the uid ReportDesign sends
	reportName: string,
	reason: string?, -- the picked report reason
}

-- A request with the server (one at a time).
type Request = {
	kind: Kind,
	requestId: string?, -- nil until the server's reply names it
	paid: boolean, -- the design (the first of a re-roll chain) cost credits: it comes with free re-rolls
	rerolls: number, -- re-rolls used on this design so far
	uid: string?, -- mods: the car
	carName: string,
	modKind: DesignerModel.ModKind,
}

-- A new design waiting for Build / Re-roll / Discard.
type Finished = {
	result: DesignerModel.Result,
	card: DesignerModel.Card,
	stats: { Primitives.StatRow },
	model: Model?,
	paid: boolean,
	rerolls: number,
	rerollFree: boolean,
}

-- The mod sheet's car.
type ModSession = {
	uid: string,
	carName: string,
	modKind: DesignerModel.ModKind,
	before: Model?,
	after: Model?,
	title: string, -- the mod result's title
}

-- A design just built.
type Built = { card: DesignerModel.Card, model: Model?, uid: string? }

type Busy = StudioSheet.ResultBusy | "report" | "drive"

type View = {
	sheet: Sheet?,
	draft: string, -- the studio's prompt
	modDraft: string,
	choice: string, -- the class chip
	busy: Busy?,
	confirmDiscard: boolean,
	request: Request?,
	slow: boolean, -- the request is taking a while
	finished: Finished?,
	mod: ModSession?,
	built: Built?,
	scale: number,
	screen: Vector2, -- unscaled pixels inside the safe area
	cutscene: boolean,
}

local DesignerController = {}

-- Fires () when the player taps Get credits on the Out of credits sheet (the credit store, Phase 12, listens).
DesignerController.onGetCredits = InputController.newSignal()

local localPlayer = Players.LocalPlayer

local view: View = {
	sheet = nil,
	draft = "",
	modDraft = "",
	choice = DesignerModel.surpriseId,
	busy = nil,
	confirmDiscard = false,
	request = nil,
	slow = false,
	finished = nil,
	mod = nil,
	built = nil,
	scale = 1,
	screen = Vector2.new(Controls.hud.referenceShortSide, Controls.hud.referenceShortSide),
	cutscene = false,
}

local root: any = nil
local screenGui: ScreenGui? = nil
local session = 0 -- bumped whenever a sheet opens, so each one slides in fresh
local closeBound = false
local early: { [string]: DesignerModel.Result } = {} -- results whose request's reply hasn't named them yet
local earlyOrder: { string } = {}
local givenUp: { [string]: Request } = {} -- requests dropped from the screen whose answer may still come

-- Builders (Vehicle/SpecBuilder, Vehicle/ModBuilder), required when first needed so a missing one only costs
-- the previews.
local builders: { [string]: any } = {}

-- Forward declarations.
local render: () -> ()
local close: () -> ()

-- Small helpers ------------------------------------------------------------------------------------------------

local function builder(name: string): any
	local cached = builders[name]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local module = ReplicatedStorage.Shared.Vehicle:FindFirstChild(name)
	local ok, result = false, nil
	if module ~= nil and module:IsA("ModuleScript") then
		ok, result = pcall(require :: any, module)
	end
	if ok and type(result) == "table" then
		builders[name] = result
		return result
	end
	warn(`[DesignerController] Vehicle/{name} isn't usable; previews are off`)
	builders[name] = false
	return nil
end

local function destroy(model: Model?)
	if model ~= nil then
		model:Destroy()
	end
end

-- A design built from its spec (SpecBuilder.build), or nil. With the uid of a saved design the model is that design
-- ("custom:<uid>", which the server published), so the looks and extras sized by class fit it.
local function buildDesign(spec: { [string]: any }, designUid: string?): Model?
	local SpecBuilder = builder("SpecBuilder")
	if SpecBuilder == nil then
		return nil
	end
	local ok, model = pcall(SpecBuilder.build, spec, DesignerModel.kit, designUid)
	if ok and typeof(model) == "Instance" and model:IsA("Model") then
		return model
	end
	return nil
end

-- A design's stats (SpecBuilder.stats: from its class band and personality only), or nil.
local function designStats(spec: { [string]: any }): { [string]: any }?
	local SpecBuilder = builder("SpecBuilder")
	if SpecBuilder == nil then
		return nil
	end
	local ok, stats = pcall(SpecBuilder.stats, spec, DesignerModel.kit)
	return if ok and type(stats) == "table" then stats else nil
end

-- Puts a mod on a model (ModBuilder.apply). False when it couldn't.
local function applyMod(model: Model, modSpec: { [string]: any }, kind: DesignerModel.ModKind): boolean
	local ModBuilder = builder("ModBuilder")
	if ModBuilder == nil then
		return false
	end
	return (pcall(ModBuilder.apply, model, modSpec, DesignerModel.kit, kind))
end

-- A copy of a Model the server sent to preview (nil when it isn't one).
local function serverModel(value: any): Model?
	if typeof(value) == "Instance" and value:IsA("Model") then
		local ok, copyOf = pcall(function(): Model?
			return value:Clone()
		end)
		return if ok then copyOf else nil
	end
	return nil
end

local function profileCars(): { Types.SnapshotVehicle }
	local snapshot = ProfileController.get()
	return if snapshot ~= nil then snapshot.vehicles else {}
end

local function ownedCar(uid: string): Types.SnapshotVehicle?
	for _, car in profileCars() do
		if car.uid == uid then
			return car
		end
	end
	return nil
end

-- The car as it looks now, for the mod sheet's "before": a copy of the player's car out in the world, else a
-- design rebuilt from its spec with its current mod. nil when neither is possible (a catalog car in the garage).
local function currentLook(car: Types.SnapshotVehicle): Model?
	for _, instance in CollectionService:GetTagged(Spawning.vehicleTag) do
		if instance:IsA("Model") and instance:GetAttribute(Garage.ownedUidAttribute) == car.uid then
			local ok, copyOf = pcall(function(): Model?
				return instance:Clone()
			end)
			if ok and copyOf ~= nil then
				return copyOf
			end
		end
	end
	local designer = ProfileController.designer()
	local design = DesignerModel.designOf(car, designer)
	local spec = if design ~= nil then design.spec else nil
	if design == nil or spec == nil then
		return nil
	end
	local model = buildDesign(spec, design.uid) -- a hidden design's spec is already its plain look
	-- A hidden design spawns plain, without its mods (Services/VehicleService), so its preview does too.
	local mod = if designer ~= nil and not design.hidden then designer.mods[car.uid] else nil
	if model ~= nil and mod ~= nil and next(mod) ~= nil then
		applyMod(model, mod, "kit")
	end
	return model
end

-- Shows a server reply ({ ok, message }) as a notice. Returns (worked, reply as a table or nil).
local function showReply(called: boolean, reply: any): (boolean, { [string]: any }?)
	local ok, message, kind = ShopModel.outcome(called, reply)
	NotifyController.show(message, kind)
	return ok, if type(reply) == "table" then reply else nil
end

-- True when a refused reply says the player is short of credits.
local function outOfCreditsReply(reply: any): boolean
	return type(reply) == "table" and (reply.outOfCredits == true or reply.code == "credits")
end

local function credits(): ProfileController.Designer?
	return ProfileController.designer()
end

-- State for the phone ------------------------------------------------------------------------------------------

local function attributeTrue(name: string): boolean
	return localPlayer:GetAttribute(name) == true
end

local function syncStore()
	local status: DesignerStore.Status = if view.request ~= nil
		then "working"
		elseif view.finished ~= nil then "ready"
		else "idle"
	DesignerStore.set({
		unlocked = DesignerModel.unlocked(attributeTrue(DesignerStyle.attributes.unlocked), credits()),
		status = status,
	})
end

-- Rendering ----------------------------------------------------------------------------------------------------

local function costParts(kind: Kind): (string, string, Primitives.Tone)
	local prices = DesignerModel.prices()
	local designer = credits()
	local line: string, tone: Primitives.Tone = DesignerModel.balanceLine(kind, designer, prices)
	return DesignerModel.costLabel(kind, designer, prices), line, tone
end

-- The sheet's content and its confirm dialog (Discard asks first).
local function contentFor(sheet: Sheet, widths: StudioSheet.Widths): (Primitives.Content, Primitives.Confirm?)
	local step = sheet.step
	local keyboard = HudController.getInputKind() == "keyboard"
	if step == "disclosure" then
		return StudioSheet.disclosure({
			kind = sheet.kind,
			text = DesignerModel.disclosureText(),
			widths = widths,
			onAccept = DesignerController.acceptDisclosure,
		})
	elseif step == "compose" then
		local label: string, line: string, tone: Primitives.Tone = costParts("design")
		return StudioSheet.compose({
			text = view.draft,
			limit = DesignerModel.promptLimit("design"),
			options = DesignerModel.classOptions(DesignerModel.ownedClasses(profileCars())),
			choice = view.choice,
			costLabel = label,
			balanceLine = line,
			balanceTone = tone,
			sending = view.request ~= nil,
			autoFocus = keyboard,
			widths = widths,
			onText = DesignerController.setDraft,
			onPick = DesignerController.pickClass,
			onSend = DesignerController.sendDesign,
		})
	elseif step == "progress" then
		return StudioSheet.progress({ kind = sheet.kind, slow = view.slow, widths = widths, onClose = close })
	elseif step == "result" then
		local finished = view.finished
		if finished ~= nil then
			local busy = view.busy
			local resultBusy: StudioSheet.ResultBusy? = if busy == "build"
					or busy == "reroll"
					or busy == "discard"
				then busy
				else nil
			local content = StudioSheet.result({
				card = finished.card,
				model = finished.model,
				stats = finished.stats,
				rerollFree = finished.rerollFree,
				rerollCost = DesignerModel.creditsText(DesignerModel.prices().newCar),
				busy = resultBusy,
				widths = widths,
				onBuild = DesignerController.build,
				onReroll = DesignerController.reroll,
				onDiscard = DesignerController.askDiscard,
				onReport = DesignerController.reportResult,
			})
			local confirm = if view.confirmDiscard
				then StudioSheet.discardConfirm(
					busy == "discard",
					DesignerController.discard,
					DesignerController.cancelDiscard
				)
				else nil
			return content, confirm
		end
	elseif step == "refused" then
		return StudioSheet.refused({
			kind = sheet.kind,
			message = sheet.refusal,
			widths = widths,
			onRetry = DesignerController.retry,
			onClose = close,
		})
	elseif step == "built" then
		local built = view.built
		if built ~= nil then
			return StudioSheet.built({
				card = built.card,
				model = built.model,
				canDrive = built.uid ~= nil,
				busy = view.busy == "drive",
				widths = widths,
				onDrive = DesignerController.driveBuilt,
				onDone = close,
			})
		end
	elseif step == "modCompose" then
		local mod = view.mod
		if mod ~= nil then
			local label: string, line: string, tone: Primitives.Tone = costParts("mod")
			return StudioSheet.modCompose({
				carName = mod.carName,
				catalog = mod.modKind == "catalog",
				before = mod.before,
				text = view.modDraft,
				limit = DesignerModel.promptLimit("mod"),
				costLabel = label,
				balanceLine = line,
				balanceTone = tone,
				sending = view.request ~= nil,
				autoFocus = keyboard,
				widths = widths,
				onText = DesignerController.setModDraft,
				onSend = DesignerController.sendMod,
			})
		end
	elseif step == "modResult" then
		local mod = view.mod
		if mod ~= nil then
			return StudioSheet.modResult({
				title = mod.title,
				carName = mod.carName,
				before = mod.before,
				after = mod.after,
				widths = widths,
				onDone = close,
				onReport = function()
					DesignerController.openReport(mod.uid, "modResult")
				end,
			})
		end
	elseif step == "outOfCredits" then
		local prices = DesignerModel.prices()
		local designer = credits()
		return StudioSheet.outOfCredits({
			kind = sheet.kind,
			cost = DesignerModel.creditsText(if sheet.kind == "mod" then prices.mod else prices.newCar),
			balance = DesignerModel.creditsText(if designer ~= nil then designer.balance else 0),
			widths = widths,
			onGetCredits = DesignerController.getCredits,
			onClose = DesignerController.back,
		})
	elseif step == "store" then
		return StudioSheet.store(widths, DesignerController.back)
	elseif step == "report" then
		return StudioSheet.report({
			carName = sheet.reportName,
			reasons = DesignerModel.reportReasons(),
			selected = sheet.reason,
			busy = view.busy == "report",
			widths = widths,
			onPick = DesignerController.pickReason,
			onSend = DesignerController.sendReport,
			onCancel = DesignerController.back,
		})
	end
	-- The step's data went away (a result was used up elsewhere): the studio's start.
	return StudioSheet.compose({
		text = view.draft,
		limit = DesignerModel.promptLimit("design"),
		options = DesignerModel.classOptions(DesignerModel.ownedClasses(profileCars())),
		choice = view.choice,
		costLabel = (costParts("design")),
		balanceLine = copy.checking,
		balanceTone = "dim",
		sending = view.request ~= nil,
		autoFocus = false,
		widths = widths,
		onText = DesignerController.setDraft,
		onPick = DesignerController.pickClass,
		onSend = DesignerController.sendDesign,
	}),
		nil
end

local function App(props: { view: View, session: number })
	local current = props.view
	local sheet = current.sheet
	if sheet == nil then
		return nil
	end
	local sheetLayout = ShopModel.layoutFor(current.screen)
	local content, confirm = contentFor(sheet, StudioSheet.widthsFor(sheetLayout))
	return e("Frame", {
		Size = UDim2.fromScale(1 / current.scale, 1 / current.scale),
		BackgroundTransparency = 1,
	}, {
		Scale = e("UIScale", { Scale = current.scale }),
		[`Sheet{props.session}`] = e(ShopSheet.Sheet, {
			content = content,
			layout = sheetLayout,
			screen = current.screen,
			confirm = confirm,
			gamepad = HudController.getInputKind() == "gamepad",
			onClose = DesignerController.closeOrCancel,
		}),
	})
end

render = function()
	syncStore()
	if root == nil then
		return
	end
	if view.sheet == nil or view.cutscene then
		root:render(nil)
		return
	end
	root:render(e(App, { view = table.clone(view), session = session }))
end

-- Keys -----------------------------------------------------------------------------------------------------------

local function onCloseKey(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		DesignerController.closeOrCancel()
	end
	return Enum.ContextActionResult.Sink
end

local function bindCloseKey(on: boolean)
	if on == closeBound then
		return
	end
	closeBound = on
	if on then
		ContextActionService:BindActionAtPriority(
			CLOSE_ACTION,
			onCloseKey,
			false,
			CLOSE_PRIORITY,
			table.unpack(DesignerStyle.closeKeys)
		)
	else
		ContextActionService:UnbindAction(CLOSE_ACTION)
	end
end

-- Opening and closing ----------------------------------------------------------------------------------------------

local function needsDisclosure(): boolean
	return DesignerModel.disclosureNeeded(attributeTrue(DesignerStyle.attributes.disclosureSeen), credits())
end

local function newSheet(step: Step, kind: Kind): Sheet
	return {
		step = step,
		kind = kind,
		back = nil,
		refusal = "",
		reportTarget = nil,
		reportName = "",
		reason = nil,
	}
end

-- Puts a sheet on screen (sliding in when none was showing), putting the phone away.
local function show(sheet: Sheet)
	if view.cutscene then
		return
	end
	if view.sheet == nil then
		session += 1
	end
	view.sheet = sheet
	view.confirmDiscard = false
	PhoneController.close()
	bindCloseKey(true)
	render()
end

-- The studio's first screen: whatever is running or waiting, else the AI notice (once) or the prompt.
local function studioSheet(): Sheet
	local request = view.request
	if request ~= nil then
		return newSheet("progress", request.kind)
	elseif view.finished ~= nil then
		return newSheet("result", "design")
	elseif needsDisclosure() then
		local sheet = newSheet("disclosure", "design")
		sheet.back = "compose"
		return sheet
	end
	return newSheet("compose", "design")
end

-- Opens the Design Studio. From the studio's prompt it also unlocks the phone's Designer app.
function DesignerController.openStudio(fromPrompt: boolean?)
	if fromPrompt then
		localPlayer:SetAttribute(DesignerStyle.attributes.unlocked, true)
	end
	show(studioSheet())
end

-- Opens "Mod with AI" for one of the player's cars.
function DesignerController.openMod(uid: string)
	if view.request ~= nil then
		show(newSheet("progress", view.request.kind)) -- one request at a time: show the one running
		return
	end
	local car = ownedCar(uid)
	if car == nil then
		NotifyController.show(copy.failed, "error")
		return
	end
	local old = view.mod
	if old ~= nil then
		destroy(old.before)
		destroy(old.after)
	end
	view.mod = {
		uid = uid,
		carName = DesignerModel.carName(car, credits()),
		modKind = DesignerModel.modKind(car),
		before = currentLook(car),
		after = nil,
		title = copy.modDoneTitle,
	}
	view.modDraft = ""
	if needsDisclosure() then
		local sheet = newSheet("disclosure", "mod")
		sheet.back = "modCompose"
		show(sheet)
	else
		show(newSheet("modCompose", "mod"))
	end
end

-- Opens the Report sheet for `target` (an owned car's uid, or a design's requestId). `back`: the screen a sent or
-- cancelled report returns to (nil: close).
function DesignerController.openReport(target: string, back: Step?)
	local car = ownedCar(target)
	local name = if car ~= nil then DesignerModel.carName(car, credits()) else copy.reportTitle
	local finished = view.finished
	if car == nil and finished ~= nil and finished.result.requestId == target then
		name = finished.card.name
	end
	local current = view.sheet
	local sheet = newSheet("report", if current ~= nil then current.kind else "design")
	sheet.back = back
	sheet.reportTarget = target
	sheet.reportName = name
	show(sheet)
end

close = function()
	if view.sheet == nil then
		return
	end
	view.sheet = nil
	view.confirmDiscard = false
	if view.busy == "report" or view.busy == "drive" then
		view.busy = nil -- the call finishes on its own; its notice still shows
	end
	local built = view.built
	if built ~= nil then
		destroy(built.model)
		view.built = nil
	end
	local mod = view.mod
	if mod ~= nil and view.request == nil then
		destroy(mod.before)
		destroy(mod.after)
		view.mod = nil
	end
	bindCloseKey(false)
	local selected = GuiService.SelectedObject
	local gui = screenGui
	if selected ~= nil and gui ~= nil and selected:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	render()
end

function DesignerController.close()
	close()
end

-- True while a designer sheet is open.
function DesignerController.isOpen(): boolean
	return view.sheet ~= nil
end

-- One step back: the Discard question, then the credit sheets' and the report's way back, else close.
function DesignerController.back()
	local sheet = view.sheet
	if sheet == nil then
		return
	end
	if sheet.step == "store" then
		sheet.step = "outOfCredits"
		render()
		return
	end
	local back = sheet.back
	if (sheet.step == "outOfCredits" or sheet.step == "report") and back ~= nil and view.busy ~= "report" then
		sheet.step = back :: Step
		sheet.back = nil
		render()
		return
	end
	close()
end

-- The close button, the dim area and gamepad B: cancel the Discard question, step back from the store, or close.
function DesignerController.closeOrCancel()
	if view.confirmDiscard then
		DesignerController.cancelDiscard()
	elseif view.sheet ~= nil and view.sheet.step == "store" then
		DesignerController.back()
	else
		close()
	end
end

-- The AI notice --------------------------------------------------------------------------------------------------

function DesignerController.acceptDisclosure()
	local sheet = view.sheet
	localPlayer:SetAttribute(DesignerStyle.attributes.disclosureSeen, true)
	if sheet ~= nil and sheet.step == "disclosure" then
		sheet.step = sheet.back or (if sheet.kind == "mod" then "modCompose" else "compose")
		sheet.back = nil
		render()
	end
end

-- Typing and picking -----------------------------------------------------------------------------------------------

-- The prompt box's text, already cut to the limit by the box (cut again here in case).
function DesignerController.setDraft(text: string)
	local clamped = DesignerModel.clampPrompt(text, DesignerModel.promptLimit("design"))
	if clamped ~= view.draft then
		view.draft = clamped
		render()
	end
end

function DesignerController.setModDraft(text: string)
	local clamped = DesignerModel.clampPrompt(text, DesignerModel.promptLimit("mod"))
	if clamped ~= view.modDraft then
		view.modDraft = clamped
		render()
	end
end

function DesignerController.pickClass(id: string)
	if view.request == nil and id ~= view.choice then
		view.choice = id
		render()
	end
end

function DesignerController.pickReason(id: string)
	local sheet = view.sheet
	if sheet ~= nil and sheet.step == "report" and view.busy ~= "report" then
		sheet.reason = id
		render()
	end
end

-- Requests --------------------------------------------------------------------------------------------------------

local deliver: (request: Request, result: DesignerModel.Result) -> ()

-- Keeps a result that came before its request's reply named it (or after the request was given up).
local function keepEarly(result: DesignerModel.Result)
	if early[result.requestId] == nil then
		table.insert(earlyOrder, result.requestId)
	end
	early[result.requestId] = result
	while #earlyOrder > MAX_EARLY_RESULTS do
		early[table.remove(earlyOrder, 1) :: string] = nil
	end
end

local function takeEarly(requestId: string?): DesignerModel.Result?
	local id = requestId
	if id == nil then
		-- The reply named no request: the only result waiting is ours.
		id = if #earlyOrder == 1 then earlyOrder[1] else nil
	end
	if id == nil then
		return nil
	end
	local result = early[id]
	if result ~= nil then
		early[id] = nil
		local at = table.find(earlyOrder, id)
		if at ~= nil then
			table.remove(earlyOrder, at)
		end
	end
	return result
end

-- The progress sheet for a request that just started (when the player is looking at its flow).
local function showProgress(kind: Kind)
	local sheet = view.sheet
	if sheet ~= nil then
		sheet.step = "progress"
		sheet.kind = kind
		sheet.back = nil
	end
end

-- Starts waiting on a request: the slow note after a while, and giving up much later (a late answer still shows).
local function watch(request: Request)
	view.request = request
	view.slow = false
	local waiting = DesignerStyle.waiting
	task.delay(waiting.slowAfterSeconds, function()
		if view.request == request then
			view.slow = true
			render()
		end
	end)
	task.delay(waiting.giveUpSeconds, function()
		if view.request ~= request then
			return
		end
		view.request = nil
		view.slow = false
		local requestId = request.requestId
		if requestId ~= nil then
			givenUp[requestId] = request
		end
		NotifyController.show(copy.gaveUp, "warning")
		local sheet = view.sheet
		if sheet ~= nil and sheet.step == "progress" then
			sheet.step = if request.kind == "mod" and view.mod ~= nil then "modCompose" else "compose"
		end
		render()
	end)
end

-- The server's answer to DesignCar, ModCar or a re-roll: the request is under way (true), or it was turned down
-- (false: the notice says why, and the sheet goes back to where the player was).
local function started(request: Request, called: boolean, reply: any, backTo: Step): boolean
	local ok = called and type(reply) == "table" and reply.ok == true
	if not ok then
		if view.request == request then
			view.request = nil
		end
		local sheet = view.sheet
		if outOfCreditsReply(reply) then
			if sheet ~= nil then
				sheet.step = "outOfCredits"
				sheet.kind = request.kind
				sheet.back = backTo
			end
		else
			showReply(called, reply)
			if sheet ~= nil and sheet.step == "progress" then
				sheet.step = backTo
			end
		end
		return false
	end
	if type(reply.requestId) == "string" then
		request.requestId = reply.requestId
	end
	-- A reply that carries the design itself, or a result that came before the reply.
	local result = DesignerModel.readResult(reply)
	if result == nil or result.spec == nil then
		result = takeEarly(request.requestId)
	end
	if result ~= nil and view.request == request then
		deliver(request, result)
	end
	return true
end

function DesignerController.sendDesign()
	local sheet = view.sheet
	if sheet == nil or sheet.step ~= "compose" or view.request ~= nil then
		return
	end
	local problem = DesignerModel.promptProblem(view.draft, "design")
	if problem ~= nil then
		NotifyController.show(problem, "warning")
		return
	end
	local prices = DesignerModel.prices()
	local designer = credits()
	if not DesignerModel.canAfford("design", designer, prices) then
		sheet.step = "outOfCredits"
		sheet.kind = "design"
		sheet.back = "compose"
		render()
		return
	end
	local request: Request = {
		kind = "design",
		requestId = nil,
		paid = DesignerModel.costOf("design", designer, prices) > 0,
		rerolls = 0,
		uid = nil,
		carName = "",
		modKind = "kit",
	}
	local payload = {
		prompt = DesignerModel.cleanPrompt(view.draft),
		classId = DesignerModel.classIdFor(view.choice),
	}
	watch(request)
	showProgress("design")
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, "DesignCar", payload)
		started(request, called, reply, "compose")
		render()
	end)
end

function DesignerController.sendMod()
	local sheet = view.sheet
	local mod = view.mod
	if sheet == nil or sheet.step ~= "modCompose" or mod == nil or view.request ~= nil then
		return
	end
	local problem = DesignerModel.promptProblem(view.modDraft, "mod")
	if problem ~= nil then
		NotifyController.show(problem, "warning")
		return
	end
	if not DesignerModel.canAfford("mod", credits(), DesignerModel.prices()) then
		sheet.step = "outOfCredits"
		sheet.kind = "mod"
		sheet.back = "modCompose"
		render()
		return
	end
	local request: Request = {
		kind = "mod",
		requestId = nil,
		paid = true,
		rerolls = 0,
		uid = mod.uid,
		carName = mod.carName,
		modKind = mod.modKind,
	}
	local payload = { uid = mod.uid, prompt = DesignerModel.cleanPrompt(view.modDraft) }
	watch(request)
	showProgress("mod")
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, "ModCar", payload)
		started(request, called, reply, "modCompose")
		render()
	end)
end

-- Results ----------------------------------------------------------------------------------------------------------

local function clearFinished()
	local finished = view.finished
	if finished ~= nil then
		destroy(finished.model)
		view.finished = nil
	end
end

-- A new design came back.
local function deliverDesign(request: Request, result: DesignerModel.Result)
	local sheet = view.sheet
	local watching = sheet ~= nil and sheet.step == "progress" and sheet.kind == "design"
	local spec = result.spec
	if not result.ok or spec == nil then
		local message = if result.message ~= "" then result.message else copy.failed
		if watching and sheet ~= nil then
			sheet.step = "refused"
			sheet.refusal = message
		else
			NotifyController.show(message, "error")
		end
		return
	end
	clearFinished()
	local preview = serverModel(result.preview)
	local rerollFree = if result.rerollFree ~= nil
		then result.rerollFree
		else DesignerModel.rerollFree(request.paid, request.rerolls, DesignerModel.prices())
	view.finished = {
		result = result,
		card = DesignerModel.designCard(spec),
		-- The server's stats (from the class band and personality); worked out here only when it sent none.
		stats = DesignerModel.statRows(result.stats or designStats(spec), ProfileController.settings().units),
		model = preview or buildDesign(spec),
		paid = request.paid,
		rerolls = request.rerolls,
		rerollFree = rerollFree,
	}
	if watching and sheet ~= nil then
		sheet.step = "result"
		if result.message ~= "" then
			NotifyController.show(result.message, "success") -- e.g. a failed re-roll bringing the last design back
		end
	else
		NotifyController.show(copy.ready, "success")
	end
end

-- A mod came back (it is already on the car when it worked).
local function deliverMod(request: Request, result: DesignerModel.Result)
	local sheet = view.sheet
	local watching = sheet ~= nil and sheet.step == "progress" and sheet.kind == "mod"
	local spec = result.spec
	if not result.ok or spec == nil then
		local message = if result.message ~= "" then result.message else copy.failed
		if watching and sheet ~= nil then
			sheet.step = "refused"
			sheet.refusal = message
		else
			NotifyController.show(message, "error")
		end
		return
	end
	local mod = view.mod
	if not watching or mod == nil or mod.uid ~= request.uid then
		NotifyController.show(if result.message ~= "" then result.message else copy.modReady, "success")
		if mod ~= nil and not (sheet ~= nil and sheet.kind == "mod") then
			-- Nobody is looking at the mod sheet: let go of its previews.
			destroy(mod.before)
			destroy(mod.after)
			view.mod = nil
		end
		return
	end
	-- After: the server's preview, else the mod put on a copy of the car as it was.
	local preview = result.preview
	local after = serverModel(if type(preview) == "table" then preview.after else preview)
	local before = mod.before
	if after == nil and before ~= nil then
		local copyOf: Model? = before:Clone() -- nil when the model can't be copied
		if copyOf ~= nil and applyMod(copyOf, spec, request.modKind) then
			after = copyOf
		else
			destroy(copyOf)
		end
	end
	destroy(mod.after)
	mod.after = after
	mod.title = DesignerModel.modTitle(spec)
	if sheet ~= nil then
		sheet.step = "modResult"
	end
end

deliver = function(request: Request, result: DesignerModel.Result)
	if view.request == request then
		view.request = nil
		view.slow = false
	end
	if request.kind == "mod" then
		deliverMod(request, result)
	else
		deliverDesign(request, result)
	end
	render()
end

local function onDesignResult(payload: any)
	local result = DesignerModel.readResult(payload)
	if result == nil then
		return
	end
	local request = view.request
	if request ~= nil and request.requestId == result.requestId then
		deliver(request, result)
		return
	end
	local late = givenUp[result.requestId]
	if late ~= nil then
		givenUp[result.requestId] = nil
		deliver(late, result)
		return
	end
	keepEarly(result) -- its request's reply hasn't come back yet
end

-- Build, re-roll, discard ------------------------------------------------------------------------------------------------

-- Sends one DesignChoice for the waiting design and hands the reply to `finish`.
local function choose(choice: "build" | "reroll" | "discard", finish: (ok: boolean, reply: { [string]: any }?) -> ())
	local finished = view.finished
	if finished == nil or view.busy ~= nil or view.request ~= nil then
		return
	end
	view.busy = choice
	render()
	task.spawn(function()
		local called, reply =
			pcall(Net.invokeServer, "DesignChoice", { requestId = finished.result.requestId, choice = choice })
		view.busy = nil
		local ok = called and type(reply) == "table" and reply.ok == true
		if not ok and outOfCreditsReply(reply) then
			local sheet = view.sheet
			if sheet ~= nil then
				sheet.step = "outOfCredits"
				sheet.kind = "design"
				sheet.back = "result"
			end
			render()
			return
		end
		finish(ok, if type(reply) == "table" then reply else nil)
		if not ok then
			showReply(called, reply)
			if type(reply) == "table" and reply.code == "pending" and view.finished == finished then
				-- The server has no design waiting any more: drop ours and go back to the prompt.
				clearFinished()
				local sheet = view.sheet
				if sheet ~= nil and sheet.step == "result" then
					sheet.step = "compose"
				end
			end
		end
		render()
	end)
end

function DesignerController.build()
	local finished = view.finished
	if finished == nil then
		return
	end
	choose("build", function(ok: boolean, reply: { [string]: any }?)
		if not ok or reply == nil or view.finished ~= finished then
			return
		end
		NotifyController.show(if type(reply.message) == "string" then reply.message else copy.builtTitle, "success")
		local built = view.built
		if built ~= nil then
			destroy(built.model)
		end
		view.built = {
			card = finished.card,
			model = finished.model,
			uid = if type(reply.uid) == "string" then reply.uid else finished.result.uid,
		}
		finished.model = nil -- now the built screen's
		clearFinished()
		local sheet = view.sheet
		if sheet ~= nil and sheet.step == "result" then
			sheet.step = "built"
		else
			local orphan = view.built -- nobody is looking: let go of the preview
			if orphan ~= nil then
				destroy(orphan.model)
			end
			view.built = nil
		end
	end)
end

function DesignerController.reroll()
	local finished = view.finished
	if finished == nil or view.busy ~= nil then
		return
	end
	local free = finished.rerollFree
	if not free and not DesignerModel.canAfford("design", credits(), DesignerModel.prices()) then
		-- Once the free re-roll is used, a re-roll is a new paid design.
		local sheet = view.sheet
		if sheet ~= nil then
			sheet.step = "outOfCredits"
			sheet.kind = "design"
			sheet.back = "result"
			render()
		end
		return
	end
	choose("reroll", function(ok: boolean, reply: { [string]: any }?)
		if not ok or view.finished ~= finished then
			return
		end
		clearFinished()
		local request: Request = {
			kind = "design",
			requestId = nil,
			paid = if free then finished.paid else true,
			rerolls = if free then finished.rerolls + 1 else 0,
			uid = nil,
			carName = "",
			modKind = "kit",
		}
		watch(request)
		showProgress("design")
		started(request, true, reply, "compose")
	end)
end

function DesignerController.askDiscard()
	if view.finished ~= nil and view.busy == nil then
		view.confirmDiscard = true
		render()
	end
end

function DesignerController.cancelDiscard()
	if view.confirmDiscard and view.busy ~= "discard" then
		view.confirmDiscard = false
		render()
	end
end

function DesignerController.discard()
	local finished = view.finished
	if finished == nil or not view.confirmDiscard then
		return
	end
	choose("discard", function(ok: boolean, reply: { [string]: any }?)
		view.confirmDiscard = false
		if not ok or view.finished ~= finished then
			return
		end
		if reply ~= nil and type(reply.message) == "string" then
			NotifyController.show(reply.message, "info")
		end
		clearFinished()
		local sheet = view.sheet
		if sheet ~= nil and sheet.step == "result" then
			sheet.step = "compose" -- the prompt is still there to change and try again
		end
	end)
end

-- Refused: back to the prompt (kept) to change it and try again.
function DesignerController.retry()
	local sheet = view.sheet
	if sheet == nil then
		return
	end
	sheet.step = if sheet.kind == "mod" and view.mod ~= nil then "modCompose" else "compose"
	render()
end

-- Built: spawn the new car (the server answers like the Garage's Spawn).
function DesignerController.driveBuilt()
	local built = view.built
	local uid = if built ~= nil then built.uid else nil
	if uid == nil or view.busy ~= nil then
		return
	end
	view.busy = "drive"
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, "SpawnOwned", { uid = uid })
		if view.busy == "drive" then
			view.busy = nil
		end
		if showReply(called, reply) then
			close()
		end
		render()
	end)
end

-- Credits ------------------------------------------------------------------------------------------------------------

function DesignerController.getCredits()
	local sheet = view.sheet
	if sheet ~= nil and sheet.step == "outOfCredits" then
		sheet.step = "store"
		render()
	end
	DesignerController.onGetCredits:Fire()
end

-- Reports ------------------------------------------------------------------------------------------------------------

-- Report on the result card: the design isn't a car yet, so the report names its request.
function DesignerController.reportResult()
	local finished = view.finished
	if finished ~= nil and view.busy == nil then
		DesignerController.openReport(finished.result.requestId, "result")
	end
end

function DesignerController.sendReport()
	local sheet = view.sheet
	if sheet == nil or sheet.step ~= "report" or view.busy ~= nil then
		return
	end
	local target, reason = sheet.reportTarget, sheet.reason
	if target == nil or reason == nil then
		return
	end
	view.busy = "report"
	render()
	task.spawn(function()
		local called, reply = pcall(Net.invokeServer, "ReportDesign", { uid = target, reason = reason })
		if view.busy == "report" then
			view.busy = nil
		end
		local ok = showReply(called, reply)
		local now = view.sheet
		if ok and now == sheet then
			DesignerController.back()
		end
		render()
	end)
end

-- The studio's prompt ------------------------------------------------------------------------------------------------

-- The studio's location: its tag and display name (Config/MapLayout).
local function studioLocation(): MapLayout.Location?
	for _, location in MapLayout.locations do
		if location.id == DesignerStyle.studio.locationId then
			return location
		end
	end
	return nil
end

-- True when the prompt sits under the studio's location part.
local function isStudioPrompt(prompt: Instance, tag: string): boolean
	local node = prompt.Parent
	while node ~= nil and node ~= game do
		if CollectionService:HasTag(node, tag) then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Puts this client's "Design a car" prompt on a studio part (unless it already has one).
local function addPrompt(instance: Instance, location: MapLayout.Location)
	local settings = DesignerStyle.studio
	if not instance:IsA("BasePart") or instance:FindFirstChildOfClass("ProximityPrompt") ~= nil then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = settings.promptName
	prompt.ActionText = copy.promptAction
	prompt.ObjectText = location.displayName
	prompt.HoldDuration = settings.holdSeconds
	prompt.MaxActivationDistance = Vector2.new(instance.Size.X, instance.Size.Z).Magnitude / 2 + settings.reachMargin
	prompt.RequiresLineOfSight = false
	prompt.Parent = instance
end

-- Profile, cutscene, boot ----------------------------------------------------------------------------------------------

local function onCutsceneChanged()
	local cutscene = localPlayer:GetAttribute(PhoneConfig.cutsceneAttribute) == true
	if cutscene == view.cutscene then
		return
	end
	view.cutscene = cutscene
	if cutscene then
		close()
	end
	local gui = screenGui
	if gui ~= nil then
		gui.Enabled = not cutscene
	end
	render()
end

-- The screen in unscaled pixels and the UI scale (the HUD's rule: scale up from a landscape phone, never down).
local function measureScreen(): boolean
	local gui = screenGui
	if gui == nil then
		return false
	end
	local size = gui.AbsoluteSize
	local scale = HudController.scaleFor(size)
	local screen = Vector2.new(math.floor(size.X / scale), math.floor(size.Y / scale))
	if scale == view.scale and screen == view.screen then
		return false
	end
	view.scale = scale
	view.screen = screen
	return true
end

function DesignerController:Start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false -- one GUI for the whole session
	gui.DisplayOrder = Theme.displayOrder.shop
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Keep the sheet clear of the Roblox top bar, notches and the home indicator.
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.Parent = playerGui
	screenGui = gui

	root = ReactRoblox.createRoot(gui)
	measureScreen()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if measureScreen() and view.sheet ~= nil then
			render()
		end
	end)

	DesignerStore.register({
		openStudio = function()
			DesignerController.openStudio(false)
		end,
		openMod = DesignerController.openMod,
		openReport = function(uid: string)
			DesignerController.openReport(uid, nil)
		end,
	})

	Net.onClientEvent("DesignResult", onDesignResult)

	-- The balance, the free car and the unlock follow the profile; the attributes follow this client (or the server).
	ProfileController.onChanged:Connect(function()
		render()
	end)
	for _, attribute in DesignerStyle.attributes do
		localPlayer:GetAttributeChangedSignal(attribute):Connect(render)
	end
	-- Switching to a gamepad selects the sheet's main button.
	HudController.onInputKindChanged:Connect(function()
		if view.sheet ~= nil then
			render()
		end
	end)

	-- The studio's prompt, on its location part whenever that part streams in.
	local location = studioLocation()
	if location ~= nil then
		local tag = location.tag
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
			addPrompt(instance, location)
		end)
		for _, instance in CollectionService:GetTagged(tag) do
			addPrompt(instance, location)
		end
		ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
			if player == localPlayer and isStudioPrompt(prompt, tag) then
				DesignerController.openStudio(true)
			end
		end)
	else
		warn(`[DesignerController] No location "{DesignerStyle.studio.locationId}" in Config/MapLayout`)
	end

	DriveController.onDrivingChanged:Connect(function(driving: boolean)
		if driving then
			close()
		end
	end)
	localPlayer.CharacterRemoving:Connect(function()
		close()
	end)
	localPlayer:GetAttributeChangedSignal(PhoneConfig.cutsceneAttribute):Connect(onCutsceneChanged)
	onCutsceneChanged()

	render()
end

return DesignerController
