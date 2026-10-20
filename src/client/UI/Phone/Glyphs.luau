--!strict
-- The phone's little drawings: one per app (GPS, Garage, Jobs, Fleet, Wallet, Codes, Settings) and the phone on
-- the phone button. Each is built from rounded frames and strokes, so the game needs no image assets and the
-- drawings stay crisp at every UI scale. Positions and sizes are fractions of the glyph's box; line widths are
-- pixels. `background` is the color behind the glyph, used to cut gaps and holes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Packages.React)

local PhoneConfig = require(script.Parent.PhoneConfig)

local e = React.createElement

local LINE = 2.5 -- px, the stroke of outlined shapes
local THIN = 2 -- px, rings drawn in the background color to separate touching shapes

type Shape = {
	at: Vector2, -- centre, as a fraction of the box
	size: Vector2, -- as a fraction of the box (round: X only, Y follows X)
	color: Color3,
	radius: number?, -- corner radius as a fraction of the shorter side (0.5 = fully round)
	round: boolean?, -- a circle: both sides take the box width's fraction
	outline: number?, -- px: drawn as an outline of this width instead of filled
	ring: Color3?, -- a THIN ring of this color around a filled shape
	order: number,
}

local function shape(props: Shape)
	local children: { [string]: any } = {
		Corner = e("UICorner", { CornerRadius = UDim.new(props.radius or 0, 0) }),
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
		BackgroundColor3 = props.color,
		BackgroundTransparency = if props.outline then 1 else 0,
		BorderSizePixel = 0,
	}, children)
end

local function v(x: number, y: number): Vector2
	return Vector2.new(x, y)
end

-- Checks a drawing's shapes against the Shape type (optional fields may be left out).
local function drawing(shapes: { Shape }): { Shape }
	return shapes
end

-- Each drawing: the shapes, back to front.
local DRAWINGS: { [PhoneConfig.Glyph]: (ink: Color3, paper: Color3) -> { Shape } } = {
	phone = function(ink: Color3, _paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.5), size = v(1, 1), color = ink, radius = 0.22, outline = THIN, order = 1 },
			{ at = v(0.5, 0.82), size = v(0.4, 0.07), color = ink, radius = 0.5, order = 2 },
		})
	end,
	gps = function(ink: Color3, _paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.5), size = v(0.6, 0), color = ink, round = true, radius = 0.5, outline = LINE, order = 1 },
			{ at = v(0.5, 0.5), size = v(0.2, 0), color = ink, round = true, radius = 0.5, order = 2 },
			{ at = v(0.5, 0.08), size = v(0.08, 0.16), color = ink, radius = 0.5, order = 2 },
			{ at = v(0.5, 0.92), size = v(0.08, 0.16), color = ink, radius = 0.5, order = 2 },
			{ at = v(0.08, 0.5), size = v(0.16, 0.08), color = ink, radius = 0.5, order = 2 },
			{ at = v(0.92, 0.5), size = v(0.16, 0.08), color = ink, radius = 0.5, order = 2 },
		})
	end,
	garage = function(ink: Color3, paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.42), size = v(0.52, 0.26), color = ink, radius = 0.45, order = 1 },
			{ at = v(0.5, 0.6), size = v(0.94, 0.3), color = ink, radius = 0.4, order = 2 },
			{ at = v(0.26, 0.76), size = v(0.24, 0), color = ink, round = true, radius = 0.5, ring = paper, order = 3 },
			{ at = v(0.74, 0.76), size = v(0.24, 0), color = ink, round = true, radius = 0.5, ring = paper, order = 3 },
		})
	end,
	jobs = function(ink: Color3, paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.24), size = v(0.36, 0.22), color = ink, radius = 0.3, outline = LINE, order = 1 },
			{ at = v(0.5, 0.6), size = v(0.9, 0.58), color = ink, radius = 0.22, order = 2 },
			{ at = v(0.5, 0.56), size = v(0.9, 0.06), color = paper, order = 3 },
			{ at = v(0.5, 0.56), size = v(0.16, 0.14), color = ink, radius = 0.3, order = 4 },
		})
	end,
	fleet = function(ink: Color3, paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.18), size = v(0.12, 0), color = ink, round = true, radius = 0.5, order = 1 },
			{ at = v(0.5, 0.18), size = v(0.3, 0), color = ink, round = true, radius = 0.5, outline = THIN, order = 1 },
			{ at = v(0.5, 0.62), size = v(0.86, 0.4), color = ink, radius = 0.5, order = 2 },
			{ at = v(0.5, 0.56), size = v(0.46, 0.12), color = paper, radius = 0.5, order = 3 },
			{ at = v(0.28, 0.82), size = v(0.18, 0), color = ink, round = true, radius = 0.5, ring = paper, order = 4 },
			{ at = v(0.72, 0.82), size = v(0.18, 0), color = ink, round = true, radius = 0.5, ring = paper, order = 4 },
		})
	end,
	wallet = function(ink: Color3, paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.56), size = v(0.88, 0.64), color = ink, radius = 0.2, outline = LINE, order = 1 },
			{ at = v(0.8, 0.56), size = v(0.36, 0.28), color = ink, radius = 0.3, order = 2 },
			{ at = v(0.74, 0.56), size = v(0.09, 0), color = paper, round = true, radius = 0.5, order = 3 },
		})
	end,
	codes = function(ink: Color3, paper: Color3): { Shape }
		return drawing({
			{ at = v(0.5, 0.5), size = v(0.94, 0.58), color = ink, radius = 0.16, order = 1 },
			{ at = v(0.03, 0.5), size = v(0.2, 0), color = paper, round = true, radius = 0.5, order = 2 },
			{ at = v(0.97, 0.5), size = v(0.2, 0), color = paper, round = true, radius = 0.5, order = 2 },
			{ at = v(0.66, 0.32), size = v(0.06, 0.1), color = paper, radius = 0.5, order = 2 },
			{ at = v(0.66, 0.5), size = v(0.06, 0.1), color = paper, radius = 0.5, order = 2 },
			{ at = v(0.66, 0.68), size = v(0.06, 0.1), color = paper, radius = 0.5, order = 2 },
		})
	end,
	settings = function(ink: Color3, paper: Color3): { Shape }
		local shapes: { Shape } = {}
		for index, row in { { y = 0.22, knob = 0.3 }, { y = 0.5, knob = 0.68 }, { y = 0.78, knob = 0.44 } } do
			table.insert(shapes, { at = v(0.5, row.y), size = v(0.9, 0.08), color = ink, radius = 0.5, order = index })
			table.insert(shapes, {
				at = v(row.knob, row.y),
				size = v(0.26, 0),
				color = ink,
				round = true,
				radius = 0.5,
				ring = paper,
				order = index + 1,
			})
		end
		return shapes
	end,
}

-- One glyph, filling its parent (or `size` px when given), centred.
local function Glyph(props: {
	name: PhoneConfig.Glyph,
	color: Color3,
	background: Color3,
	size: Vector2?,
	order: number?,
})
	local draw = DRAWINGS[props.name]
	local children: { [string]: any } = {}
	if draw then
		for index, item in draw(props.color, props.background) do
			children[`Shape{index}`] = shape(item)
		end
	end
	local size = props.size
	return e("Frame", {
		LayoutOrder = props.order or 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if size then UDim2.fromOffset(size.X, size.Y) else UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, children)
end

return Glyph
