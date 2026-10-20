--!strict
-- The phone's Settings app: speed units (mph or km/h), the camera every drive starts in (chase, orbit or hood)
-- and the music volume. Each change goes to the server through PhoneController (Net "UpdateSettings", which
-- validates it) and shows at once. The choices come from Config/Garage `settings`, so the phone never offers a
-- value the server would refuse. While the volume slider is dragged its value lives here; it is sent once, on
-- release.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)
local Garage = require(ReplicatedStorage.Shared.Config.Garage)
local Types = require(ReplicatedStorage.Shared.Types)

local Kit = require(script.Parent.Kit)
local PhoneConfig = require(script.Parent.PhoneConfig)
local Theme = require(script.Parent.Parent.Theme)

local e = React.createElement
local colors = Theme.colors

export type Props = {
	settings: Types.Settings,
	onUnits: (units: string) -> (),
	onCamera: (camera: string) -> (),
	onMusicVolume: (volume: number) -> (),
}

local function options(ids: { string }, labels: { [string]: string }): { Kit.Option }
	local list: { Kit.Option } = {}
	for _, id in ids do
		table.insert(list, { id = id, label = labels[id] or id })
	end
	return list
end

local function SettingsApp(props: Props)
	local copy = PhoneConfig.settings
	local dragging: number?, setDragging = React.useState(nil :: number?)
	local volume = if dragging ~= nil then dragging else props.settings.musicVolume

	return Kit.Page({ gap = Theme.spacing.sm }, {
		UnitsTitle = Kit.SectionTitle({ text = copy.units, order = 1 }),
		Units = e(Kit.Segmented, {
			options = options(Garage.settings.units, copy.unitOptions),
			selected = props.settings.units,
			onSelect = props.onUnits,
			order = 2,
		}),
		CameraTitle = Kit.SectionTitle({ text = copy.camera, order = 3 }),
		Camera = e(Kit.Segmented, {
			options = options(Garage.settings.cameras, copy.cameraOptions),
			selected = props.settings.camera,
			onSelect = props.onCamera,
			order = 4,
		}),
		CameraNote = Kit.Text({ text = copy.cameraNote, order = 5, size = Theme.text.small, color = colors.textDim }),
		MusicTitle = e("Frame", {
			LayoutOrder = 6,
			Size = UDim2.new(1, 0, 0, PhoneConfig.list.sectionHeight),
			BackgroundTransparency = 1,
		}, {
			Title = Kit.SectionTitle({ text = copy.music }),
			Value = e("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromScale(0.5, 1),
				BackgroundTransparency = 1,
				FontFace = Theme.fonts.bold,
				Text = string.format(copy.volumeFormat, math.round(volume * 100)),
				TextColor3 = colors.text,
				TextSize = Theme.text.small,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextYAlignment = Enum.TextYAlignment.Bottom,
			}, {
				Padding = e("UIPadding", { PaddingBottom = UDim.new(0, Theme.spacing.xs) }),
			}),
		}),
		Music = e(Kit.Slider, {
			value = volume,
			order = 7,
			onChange = function(value: number, final: boolean)
				if final then
					setDragging(nil)
					props.onMusicVolume(value)
				else
					setDragging(value)
				end
			end,
		}),
	})
end

return SettingsApp
