--!strict
-- Studio-only spawn menu (docs/phase-1-contracts.md "Client"; CLAUDE.md hard rule 8, dev tools stay dev).
-- A compact, collapsible panel in the top-left corner listing every player-drivable vehicle and its trims from
-- Vehicle/Catalog. Picking one fires Net "DevSpawnVehicle" {vehicleId, trim}; VehicleService spawns the car
-- next to the player, and refuses outside Studio. Outside Studio this component renders nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local React = require(ReplicatedStorage.Packages.React)
local Catalog = require(ReplicatedStorage.Shared.Vehicle.Catalog)
local Controls = require(ReplicatedStorage.Shared.Config.Controls)
local Net = require(ReplicatedStorage.Shared.Net)

local e = React.createElement

type Choice = { vehicleId: string, trim: string, label: string }
type Section = { title: string, choices: { Choice } }

-- Every drivable vehicle (sorted by id) with its trims in catalog order. Names come only from the catalog.
local function buildSections(): { Section }
	local sections: { Section } = {}
	for _, vehicleId in Catalog.vehicleIds() do
		local vehicle = Catalog.getVehicle(vehicleId)
		if vehicle and vehicle.playerDrivable then
			local choices: { Choice } = {}
			for _, trim in vehicle.trims do
				table.insert(choices, { vehicleId = vehicleId, trim = trim.id, label = trim.displayName })
			end
			table.insert(sections, { title = vehicle.displayName, choices = choices })
		end
	end
	return sections
end

local function choiceKey(choice: Choice): string
	return Catalog.modelName(choice.vehicleId, choice.trim)
end

local function DevSpawnMenu(_props: {})
	local open, setOpen = React.useState(false)
	local picked: string?, setPicked = React.useState(nil :: string?)
	local sections = React.useMemo(buildSections, {})
	-- Lets the delayed "un-highlight" skip a component that has since unmounted.
	local mounted = React.useRef(true)
	React.useEffect(function()
		mounted.current = true
		return function()
			mounted.current = false
		end
	end, {})

	if not RunService:IsStudio() then
		return nil
	end

	local theme = Controls.theme
	local menu = Controls.devMenu

	local function spawn(choice: Choice)
		Net.fireServer("DevSpawnVehicle", { vehicleId = choice.vehicleId, trim = choice.trim })
		local key = choiceKey(choice)
		setPicked(key)
		task.delay(menu.pickedFlashSeconds, function()
			if mounted.current then
				setPicked(function(current: string?)
					return if current == key then nil else current
				end)
			end
		end)
	end

	-- The scrolling list: a small heading per vehicle, then one row per trim.
	local rows: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local order = 0
	for _, section in sections do
		order += 1
		rows[`Section{order}`] = e("TextLabel", {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, menu.sectionHeight),
			BackgroundTransparency = 1,
			FontFace = theme.fonts.medium,
			Text = section.title,
			TextColor3 = theme.textDim,
			TextSize = menu.sectionTextSize,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
		}, {
			Padding = e("UIPadding", { PaddingLeft = UDim.new(0, menu.rowPadding) }),
		})
		for _, choice in section.choices do
			order += 1
			local isPicked = picked == choiceKey(choice)
			rows[choiceKey(choice)] = e("TextButton", {
				LayoutOrder = order,
				Size = UDim2.new(1, 0, 0, menu.rowHeight),
				BackgroundColor3 = if isPicked then theme.accent else theme.panelRaised,
				BackgroundTransparency = if isPicked then 0 else 1,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				FontFace = theme.fonts.medium,
				Text = choice.label,
				TextColor3 = if isPicked then theme.onAccent else theme.text,
				TextSize = menu.textSize,
				TextXAlignment = Enum.TextXAlignment.Left,
				[React.Event.Activated] = function()
					spawn(choice)
				end,
			}, {
				Padding = e("UIPadding", { PaddingLeft = UDim.new(0, menu.rowPadding) }),
				Corner = e("UICorner", { CornerRadius = UDim.new(0, menu.rowCornerRadius) }),
			})
		end
	end

	local margin = Controls.hud.margin
	return e("Frame", {
		Position = UDim2.fromOffset(margin, margin),
		Size = UDim2.fromOffset(menu.width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = theme.panelTransparency,
		BorderSizePixel = 0,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, Controls.hud.cornerRadius) }),
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Header = e("TextButton", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, menu.rowHeight),
			BackgroundTransparency = 1,
			FontFace = theme.fonts.bold,
			Text = menu.title,
			TextColor3 = theme.text,
			TextSize = menu.textSize,
			TextXAlignment = Enum.TextXAlignment.Left,
			[React.Event.Activated] = function()
				setOpen(not open)
			end,
		}, {
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, menu.rowPadding),
				PaddingRight = UDim.new(0, menu.rowPadding),
			}),
			Toggle = e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromScale(0.4, 1),
				BackgroundTransparency = 1,
				FontFace = theme.fonts.medium,
				Text = if open then menu.hideLabel else menu.showLabel,
				TextColor3 = theme.accent,
				TextSize = menu.textSize,
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		}),
		List = if open
			then e("ScrollingFrame", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, menu.maxListHeight),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				ScrollBarThickness = menu.scrollBarThickness,
				ScrollBarImageColor3 = theme.textDim,
			}, {
				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, menu.listInset),
					PaddingRight = UDim.new(0, menu.listInset),
					PaddingBottom = UDim.new(0, menu.listInset),
				}),
				Rows = e("Frame", {
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
				}, rows),
			})
			else nil,
	})
end

return DevSpawnMenu
