--!strict
-- The phone's Designer app (docs/phase-11-contracts.md "Client"; PLAN.md Phase 11): unlocked after the player's
-- first visit to the Design Studio, it opens the studio from anywhere in the county. It shows:
--
--   intro       what the designer does ("An AI designs your car from your words.")
--   status      while a design is being made, "View progress"; when a new design waits, "See it"
--   credits     the Design Credits balance, and that the first car is free while it is
--   open        "Open the Design Studio" (DesignerController puts the phone away and opens the studio sheet)
--   designs     how many design spaces are used, and the designs by name
--   tip         "Mod with AI" lives on each car in the Garage app
--
-- UI/Phone/Phone mounts it for the "designer" app. It reads the profile (ProfileController: the snapshot and its
-- designer part) and the designer's state (UI/Designer/DesignerStore, which re-renders it when it changes) itself;
-- the phone re-renders it with every new snapshot. Presentation only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)
local DesignerModel = require(script.Parent.Parent.Designer.DesignerModel)
local DesignerStore = require(script.Parent.Parent.Designer.DesignerStore)
local DesignerStyle = require(script.Parent.Parent.Designer.DesignerStyle)
local ProfileController = require(script.Parent.Parent.Parent.Controllers.ProfileController)

local e = React.createElement
local colors = Theme.colors
local text = DesignerStyle.app

local function DesignerApp(_props: {})
	local state = DesignerStore.useState()
	local profile = ProfileController.get()
	local designer = ProfileController.designer()
	if profile == nil or designer == nil then
		return Kit.Page({}, {
			Loading = Kit.Text({ text = PhoneConfig.labels.loading, color = colors.textDim }),
		})
	end

	local children: { [string]: any } = {
		Intro = Kit.Card({ order = 1, gap = Theme.spacing.xs, padding = Theme.spacing.lg }, {
			Title = Kit.Text({ text = text.title, order = 1, size = Theme.text.heading, font = Theme.fonts.bold }),
			Body = Kit.Text({ text = text.body, order = 2, color = colors.textDim }),
		}),
	}

	-- A design on its way, or one waiting to be seen.
	local waiting = state.status ~= "idle"
	if waiting then
		local ready = state.status == "ready"
		children.Status = Kit.Card({ order = 2, gap = Theme.spacing.sm, padding = Theme.spacing.lg }, {
			Line = Kit.Text({
				text = if ready then text.readyTitle else text.working,
				order = 1,
				font = Theme.fonts.bold,
			}),
			Button = e(Kit.Button, {
				label = if ready then text.see else text.watch,
				style = if ready then "primary" else "secondary",
				order = 2,
				onTap = DesignerStore.openStudio,
			}),
		})
	end

	-- The balance, and the free first car while it is unused.
	local credits: { [string]: any } = {
		Label = Kit.Text({
			text = text.credits,
			order = 1,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		}),
		Value = Kit.Text({
			text = DesignerModel.creditsText(designer.balance),
			order = 2,
			size = Theme.text.price,
			font = Theme.fonts.bold,
		}),
	}
	if not designer.freeDesignUsed then
		credits.Free = Kit.Text({ text = text.freeCar, order = 3, color = colors.success, font = Theme.fonts.medium })
	end
	children.Credits = Kit.Card({ order = 3, gap = Theme.spacing.xs, padding = Theme.spacing.lg }, credits)

	children.Open = e(Kit.Button, {
		label = text.open,
		style = if state.status == "ready" then "secondary" else "primary",
		order = 4,
		onTap = DesignerStore.openStudio,
	})

	-- The player's designs, by name (a hidden design shows the neutral name).
	children.DesignsTitle = Kit.SectionTitle({ text = text.designs, order = 5 })
	if designer.designCount == 0 then
		children.NoDesigns = Kit.Text({ text = text.noDesigns, order = 6, color = colors.textDim })
	else
		children.Slots = Kit.Text({
			text = string.format(text.slots, designer.designCount, profile.customSlots),
			order = 6,
			size = Theme.text.small,
			font = Theme.fonts.medium,
			color = colors.textDim,
		})
		local names: { string } = {}
		for _, design in designer.designs do
			table.insert(names, design.name or DesignerStyle.copy.yourDesign)
		end
		table.sort(names)
		local rows: { [string]: any } = {}
		for index, name in names do
			rows[`Design_{index}`] = Kit.Text({ text = name, order = index, font = Theme.fonts.medium })
		end
		children.Designs = Kit.Card({ order = 7, gap = Theme.spacing.sm }, rows)
	end
	children.Tip = Kit.Text({ text = text.modTip, order = 8, size = Theme.text.small, color = colors.textDim })

	return Kit.Page({}, children)
end

return DesignerApp
