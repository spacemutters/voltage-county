--!strict
-- Music and sound effects the game plays (Phase 7 light shows and beyond; docs/phase-7-contracts.md "Light
-- shows"; Phase 10 thruster hiss, docs/phase-10-contracts.md "Abilities, client").
--
-- Davis allowed two sources only: Roblox's own licensed music library (audio published by Roblox, picked in the
-- Creator Store; audio only, never models or scripts) or original music made with his ElevenLabs account. Never
-- insert anything from the Creator Store from code or tooling; the lead pastes the asset ids here once tracks are
-- picked.
--
-- Until then every track is a placeholder with assetId = 0: everything that plays music must treat 0 as "no audio"
-- and carry on silently (the light shows still run, timed by bpm and length). A real track must keep the bpm,
-- length and downbeat written here, or the routines in Config/LightShows drift off the music: if a picked track
-- differs, update these numbers (tests/LightShows.spec checks every routine still fits).
--
-- Sound effects (`sfx`) follow the same two sources and the same placeholder rule: assetId = 0 plays nothing, and
-- whatever plays them (Controllers/AbilityController for the thruster hiss) never creates a Sound for it.

export type Track = {
	assetId: number, -- Roblox audio asset id; 0 = placeholder, plays nothing
	displayName: string, -- shown to players (an original title, never a real artist or song name)
	bpm: number, -- beats per minute; light-show cues are placed on this beat grid
	length: number, -- seconds of music the routine may use (the show ends here)
	downbeat: number, -- seconds into the audio of beat 0 (any silence or pickup before the first bar)
	volume: number, -- 0..1 before the player's music volume setting
}

-- A short sound effect, played in 3D from the thing that makes it.
export type Sfx = {
	assetId: number, -- Roblox audio asset id; 0 = placeholder, plays nothing
	volume: number, -- 0..1
	playbackSpeed: number, -- 1 = as recorded
	rollOffMaxDistance: number, -- studs; silent beyond this
	maxSeconds: number, -- the Sound is cleaned up after this long even if it never reports ending
}

export type Audio = {
	tracks: { [string]: Track },
	-- Order the tracks are listed in (phone, dev tools); ids into `tracks`.
	trackOrder: { string },
	sfx: { [string]: Sfx },
}

local Audio: Audio = {
	tracks = {
		-- 120 bpm, 32 bars of 4/4 = 128 beats = 64 s.
		midnight_circuit = {
			assetId = 0,
			displayName = "Midnight Circuit",
			bpm = 120,
			length = 64,
			downbeat = 0,
			volume = 0.6,
		},
		-- 100 bpm, 30 bars of 4/4 = 120 beats = 72 s.
		harbor_lights = {
			assetId = 0,
			displayName = "Harbor Lights",
			bpm = 100,
			length = 72,
			downbeat = 0,
			volume = 0.6,
		},
		-- 128 bpm, 32 bars of 4/4 = 128 beats = 60 s.
		neon_mesa = {
			assetId = 0,
			displayName = "Neon Mesa",
			bpm = 128,
			length = 60,
			downbeat = 0,
			volume = 0.6,
		},
	},
	trackOrder = { "midnight_circuit", "harbor_lights", "neon_mesa" },
	sfx = {
		-- Phase 10: the cold-gas hiss when the Arc's boost-hop or flight starts (Config/Thrusters.hissSound).
		thrusterHiss = {
			assetId = 0,
			volume = 0.5,
			playbackSpeed = 1,
			rollOffMaxDistance = 150,
			maxSeconds = 3,
		},
	},
}

return Audio
