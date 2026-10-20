--!strict
-- The phone's Designer app icon (UI/Phone/Phone draws it on the home screen): a little car with a sparkle over it,
-- built from rounded frames like UI/Phone/Glyphs so the game needs no image assets and it stays crisp at every UI
-- scale. Positions and sizes are fractions of the glyph's box; `background` cuts the gaps round the wheels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local e = React.createElement

local LINE = 2.5 -- px, the cabin's outline (UI/Phone/Glyphs' stroke)
local THIN = 2 -- px, the ring cutting the wheels from the body

export type Props = {
	color: Color3,
	background: Color3,
	size: Vector2?,
}

local function piece(props: {
	at: Vector2,
	size: Vector2,
	color: Color3,
	radius: number,
	round: boolean?,
	outline: number?,
	ring: Color3?,
	rotation: number?,
	order: number,
})
	local children: { [string]: any } = {
		Corner = e("UICorner", { CornerRadius = UDim.new(props.radius, 0) }),
	}
	if props.outline then
		children.Stroke = e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = props.color,
			Thickness = props.outline,
		})
	elseif props.ring then
		children.Stroke = e("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = props.ring,
			Thickness = THIN,
		})
	end
	return e("Frame", {
		ZIndex = props.order,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(props.at.X, props.at.Y),
		Size = UDim2.fromScale(props.size.X, if props.round then props.size.X else props.size.Y),
		SizeConstraint = if props.round then Enum.SizeConstraint.RelativeXX else Enum.SizeConstraint.RelativeXY,
		Rotation = props.rotation or 0,
		BackgroundColor3 = props.color,
		BackgroundTransparency = if props.outline then 1 else 0,
		BorderSizePixel = 0,
	}, children)
end

local function DesignerGlyph(props: Props)
	local ink, paper = props.color, props.background
	local size = props.size
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if size then UDim2.fromOffset(size.X, size.Y) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Cabin = piece({
			at = Vector2.new(0.42, 0.5),
			size = Vector2.new(0.4, 0.2),
			color = ink,
			radius = 0.45,
			outline = LINE,
			order = 1,
		}),
		Body = piece({
			at = Vector2.new(0.45, 0.66),
			size = Vector2.new(0.78, 0.2),
			color = ink,
			radius = 0.4,
			order = 2,
		}),
		RearWheel = piece({
			at = Vector2.new(0.25, 0.78),
			size = Vector2.new(0.2, 0),
			color = ink,
			radius = 0.5,
			round = true,
			ring = paper,
			order = 3,
		}),
		FrontWheel = piece({
			at = Vector2.new(0.66, 0.78),
			size = Vector2.new(0.2, 0),
			color = ink,
			radius = 0.5,
			round = true,
			ring = paper,
			order = 3,
		}),
		-- The sparkle: a big and a small diamond above the hood.
		Spark = piece({
			at = Vector2.new(0.8, 0.24),
			size = Vector2.new(0.17, 0),
			color = ink,
			radius = 0.15,
			round = true,
			rotation = 45,
			order = 4,
		}),
		SparkSmall = piece({
			at = Vector2.new(0.62, 0.13),
			size = Vector2.new(0.09, 0),
			color = ink,
			radius = 0.15,
			round = true,
			rotation = 45,
			order = 4,
		}),
	})
end

return DesignerGlyph
