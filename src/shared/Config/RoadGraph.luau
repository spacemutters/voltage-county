--!strict
-- The one road graph (PLAN.md §5). It drives greybox road generation, GPS, NPC pods, job destinations and
-- the AutoDriver. Filled in Phase 2.

export type Node = {
	id: string,
	position: Vector3,
	zone: string,
}

export type Edge = {
	from: string,
	to: string,
	lanes: number,
	speedLimitMph: number,
	surface: "asphalt" | "dirt" | "concrete",
}

local RoadGraph: { nodes: { Node }, edges: { Edge } } = {
	nodes = {},
	edges = {},
}

return RoadGraph
