--!strict
-- What a built site's street front holds (Dev/City/Street/Frontage reads it; Config/CityStreet frontage.scan). Pure.
-- Every part of the site is a box in the site's own frame (x along the road, y up from the ground, z away from the
-- road; the front line at z = -depth/2): the whole box, whatever the part's shape or turn, so every test errs toward
-- "in the way". From the boxes:
--   walls     the runs of wall its ground floor shows the street: at each sample along the front, the frontmost solid,
--             unturned block that comes down to the ground and rises high enough to carry a shop's sign, grouped while
--             it keeps to one plane and one kind (an opaque wall, or glass)
--   floor     the ground underfoot: the highest low part (a terrace's slab, a plinth) under a spot, or the paved lot
--   free      whether a box of space is clear of every part (with a wall's plane given, the parts wholly behind it are
--             left out: a piece set into that wall)
--   openings  the stretches along the front where a band of space is clear
-- The frontage adds its own pieces as it places them (Scan.add), so they keep off each other too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityStreet = require(ReplicatedStorage.Shared.Config.CityStreet)
local Kit = require(script.Parent.Parent.Kit)
local Types = require(script.Parent.Parent.Types)

type PartSpec = Types.PartSpec
type Site = Types.Site

local SCAN = CityStreet.frontage.scan
local SHOP = CityStreet.frontage.shop
local ALIGN = 0.999 -- a part whose axes are within this (a cosine) of the site's is unturned

export type Box = {
	lo: Vector3,
	hi: Vector3,
	solid: boolean, -- it collides and can be seen
	glass: boolean,
	upright: boolean, -- an unturned block, so its box is the part itself
	low: boolean, -- ground underfoot: no higher than scan.floorTop
}

-- One run of wall along the front, from x0 to x1: its face at z (the run's frontmost), opaque or glass, and the lowest
-- top of the parts that make it.
export type Wall = { x0: number, x1: number, z: number, glass: boolean, top: number }

export type Scan = { site: Site, hw: number, hd: number, boxes: { Box } }

local FrontageScan = {}

local function upright(frame: CFrame, spec: PartSpec): boolean
	if spec.shape ~= "block" or spec.class ~= "Part" then
		return false
	end
	local rel = frame:ToObjectSpace(spec.cframe)
	local right = rel.RightVector
	return math.abs(rel.UpVector.Y) >= ALIGN and (math.abs(right.X) >= ALIGN or math.abs(right.Z) >= ALIGN)
end

-- Whether a low part is paving to stand on (scan.notFloor: not water, a pool, a lawn, a drive or a ramp).
local function paving(spec: PartSpec): boolean
	if table.find(SCAN.notFloor.materials, spec.material) then
		return false
	end
	for _, word in SCAN.notFloor.names do
		if string.find(spec.name, word, 1, true) then
			return false
		end
	end
	return true
end

-- A part as a box in its site's frame.
function FrontageScan.box(site: Site, spec: PartSpec): Box
	local lo, hi = Kit.localBounds(site.frame, spec)
	return {
		lo = lo,
		hi = hi,
		solid = spec.collide and spec.transparency < 1,
		glass = spec.material == Enum.Material.Glass,
		upright = upright(site.frame, spec),
		low = hi.Y <= SCAN.floorTop and paving(spec),
	}
end

-- A site's street front from the parts it was built with.
function FrontageScan.new(site: Site, specs: { PartSpec }): Scan
	local boxes: { Box } = {}
	for _, spec in specs do
		table.insert(boxes, FrontageScan.box(site, spec))
	end
	return { site = site, hw = site.width / 2, hd = site.depth / 2, boxes = boxes }
end

-- Puts a placed piece in, so later pieces keep off it.
function FrontageScan.add(scan: Scan, spec: PartSpec)
	table.insert(scan.boxes, FrontageScan.box(scan.site, spec))
end

local function overlaps(b: Box, lo: Vector3, hi: Vector3): boolean
	local e = SCAN.eps
	return b.lo.X < hi.X - e
		and b.hi.X > lo.X + e
		and b.lo.Y < hi.Y - e
		and b.hi.Y > lo.Y + e
		and b.lo.Z < hi.Z - e
		and b.hi.Z > lo.Z + e
end

-- Whether the box lo..hi (site frame) is clear of every part. With `wall`, the parts wholly behind the plane z = wall
-- (the wall a piece is set into, and what stands behind it) don't count.
function FrontageScan.free(scan: Scan, lo: Vector3, hi: Vector3, wall: number?): boolean
	for _, b in scan.boxes do
		if wall and b.lo.Z >= wall - SCAN.eps then
			continue
		end
		if overlaps(b, lo, hi) then
			return false
		end
	end
	return true
end

-- Whether a box lies wholly inside the site's footprint, between the ground and `top`.
function FrontageScan.inside(scan: Scan, lo: Vector3, hi: Vector3, top: number): boolean
	local e = 1e-3
	return lo.X >= -scan.hw - e
		and hi.X <= scan.hw + e
		and lo.Z >= -scan.hd - e
		and hi.Z <= scan.hd + e
		and lo.Y >= -e
		and hi.Y <= top + e
end

-- The floor under the plan rectangle x0..x1, z0..z1: the highest low part reaching under it, or the paved lot.
function FrontageScan.floor(scan: Scan, x0: number, x1: number, z0: number, z1: number): number
	local top = SCAN.ground
	for _, b in scan.boxes do
		if b.low and b.lo.X < x1 and b.hi.X > x0 and b.lo.Z < z1 and b.hi.Z > z0 then
			top = math.max(top, b.hi.Y)
		end
	end
	return top
end

-- The runs of wall the ground floor shows the street, in order along x (see the header). A wall stands between
-- scan.setback.min and .max behind the front line; anything nearer or further is no shop wall.
function FrontageScan.walls(scan: Scan): { Wall }
	local hw, hd = scan.hw, scan.hd
	local tall: { Box } = {}
	for _, b in scan.boxes do
		if
			b.solid
			and b.upright
			and not b.low
			and b.lo.Y <= SCAN.ground + SCAN.reach
			and b.hi.Y >= SCAN.ground + SHOP.top
		then
			table.insert(tall, b)
		end
	end
	local walls: { Wall } = {}
	local current: Wall? = nil
	local ref = 0 -- the plane the current run started on
	local x = -hw + SCAN.side
	while x <= hw - SCAN.side + 1e-6 do
		local best: Box? = nil
		for _, b in tall do
			if b.lo.X <= x and b.hi.X >= x and (best == nil or b.lo.Z < (best :: Box).lo.Z) then
				best = b
			end
		end
		local face: Box? = nil
		if best then
			local back = best.lo.Z + hd
			if back >= SCAN.setback.min and back <= SCAN.setback.max then
				face = best
			end
		end
		local run = current
		if face and run and run.glass == face.glass and math.abs(face.lo.Z - ref) <= SCAN.jitter then
			run.x1 = x
			run.z = math.min(run.z, face.lo.Z)
			run.top = math.min(run.top, face.hi.Y)
		else
			if run then
				table.insert(walls, run)
			end
			if face then
				current = { x0 = x, x1 = x, z = face.lo.Z, glass = face.glass, top = face.hi.Y }
				ref = face.lo.Z
			else
				current = nil
			end
		end
		x += SCAN.step
	end
	if current then
		table.insert(walls, current)
	end
	return walls
end

-- The stretches of x0..x1 (each as Vector2(from, to), in order) where the band y0..y1, z0..z1 is clear of every part
-- that isn't ground underfoot.
function FrontageScan.openings(
	scan: Scan,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number
): { Vector2 }
	local e = SCAN.eps
	local blocked: { Vector2 } = {}
	for _, b in scan.boxes do
		if
			not b.low
			and b.lo.Y < y1 - e
			and b.hi.Y > y0 + e
			and b.lo.Z < z1 - e
			and b.hi.Z > z0 + e
			and b.lo.X < x1
			and b.hi.X > x0
		then
			table.insert(blocked, Vector2.new(b.lo.X, b.hi.X))
		end
	end
	table.sort(blocked, function(a: Vector2, b: Vector2): boolean
		if a.X ~= b.X then
			return a.X < b.X
		end
		return a.Y < b.Y
	end)
	local open: { Vector2 } = {}
	local at = x0
	for _, span in blocked do
		if span.X > at then
			table.insert(open, Vector2.new(at, math.min(span.X, x1)))
		end
		at = math.max(at, span.Y)
		if at >= x1 then
			break
		end
	end
	if at < x1 then
		table.insert(open, Vector2.new(at, x1))
	end
	return open
end

return FrontageScan
