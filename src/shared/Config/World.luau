--!strict
-- World scale and bounds (PLAN.md §5).

local World = {
	-- Speed display: one stud is this many meters. Start at 0.28 and tune for feel.
	metersPerStud = 0.28,
	-- Keep all geometry within this many studs of the origin on X and Z.
	mapHalfExtent = 5000,
	-- One road lane, in studs.
	laneWidth = 12,
	-- Avatar height, in studs (cars are sized so an avatar fits the seat).
	avatarHeight = 5,
}

return World
