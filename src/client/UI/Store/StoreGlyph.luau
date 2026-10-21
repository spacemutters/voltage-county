--!strict
-- The phone's Store app icon (UI/Phone/Phone draws it on the home screen): a shopping bag with a little spark on
-- it, built from rounded frames like UI/Phone/Glyphs so the game needs no image assets and it stays crisp at every
-- UI scale. Positions and sizes are fractions of the glyph's box; `background` cuts the spark out of the bag.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local e = React.createElement

local LINE = 2.5 -- px, the handle's outline (UI/Phone/Glyphs' stroke)

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

local function StoreGlyph(props: Props)
	local ink, paper = props.color, props.background
	local size = props.size
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if size then UDim2.fromOffset(size.X, size.Y) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		-- The handle: an outlined loop whose lower half hides behind the bag.
		Handle = piece({
			at = Vector2.new(0.5, 0.3),
			size = Vector2.new(0.36, 0.34),
			color = ink,
			radius = 0.5,
			outline = LINE,
			order = 1,
		}),
		Bag = piece({
			at = Vector2.new(0.5, 0.64),
			size = Vector2.new(0.76, 0.56),
			color = ink,
			radius = 0.18,
			order = 2,
		}),
		-- The spark: a big and a small diamond cut out of the bag.
		Spark = piece({
			at = Vector2.new(0.5, 0.66),
			size = Vector2.new(0.17, 0),
			color = paper,
			radius = 0.15,
			round = true,
			rotation = 45,
			order = 3,
		}),
		SparkSmall = piece({
			at = Vector2.new(0.68, 0.52),
			size = Vector2.new(0.08, 0),
			color = paper,
			radius = 0.15,
			round = true,
			rotation = 45,
			order = 3,
		}),
	})
end

return StoreGlyph
