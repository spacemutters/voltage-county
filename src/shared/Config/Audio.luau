--!strict
-- Audio asset ids (Phase 7 light shows and beyond). Licensed tracks only.

export type Track = {
	assetId: number,
	displayName: string,
	bpm: number?,
}

local Audio: { tracks: { [string]: Track } } = {
	tracks = {},
}

return Audio
