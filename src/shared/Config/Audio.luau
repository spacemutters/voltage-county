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
--
-- Car sounds (roast fixes, 2026-10-24): the looping sounds in `loops` and the indicator tick in `sfx` were made with
-- Davis's ElevenLabs account (paid plan, so they may be used in a published game) and uploaded to his Roblox account
-- as audio on 2026-10-24; the source files are in assets/audio/ (raw generations in assets/audio/raw/). Uploaded
-- audio goes through Roblox moderation and plays once it is approved. `car` says how Controllers/
-- VehicleSoundController plays them: which cars get sounds, and how pitch and volume follow each car's motion. The
-- same placeholder rule holds: a loop with assetId 0 is never created.

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

-- A looping sound, played in 3D from a car's chassis (or flat, for the wind in the car you sit in).
export type Loop = {
	assetId: number, -- Roblox audio asset id; 0 = placeholder, never created
	volume: number, -- 0..1 at full effect; the curves in `car` scale it down from there
	rollOffMinDistance: number, -- studs; full volume inside this
	rollOffMaxDistance: number, -- studs; silent beyond this
}

-- How one fuel engine loop follows the gearbox (Config/Driving powertrain.fuel; Controllers/VehicleSoundController).
export type EngineSound = {
	loop: string, -- id into `loops`
	idlePitch: number, -- PlaybackSpeed at idle (no revs in the gear)
	redlinePitch: number, -- PlaybackSpeed at the top of a gear
	idleVolume: number, -- share of the loop's volume off the throttle
	loadVolume: number, -- extra share at full throttle
}

export type CarAudio = {
	maxDistance: number, -- studs from the camera; cars farther away make no sound
	maxEngines: number, -- engines (and tyres) that play at once, nearest first
	rankInterval: number, -- seconds between picking the nearest cars again
	-- Battery cars: a motor whine that rises with speed (share of the trim's top speed).
	ev: {
		loop: string,
		minPitch: number, -- at a standstill
		maxPitch: number, -- at top speed
		idleVolume: number, -- share of the loop's volume at a standstill
		speedVolume: number, -- extra share at top speed
		loadVolume: number, -- extra share at full throttle
	},
	-- Fuel cars: which engine loop a car gets (by vehicle id first, then by class, then the default).
	engines: { [string]: EngineSound },
	engineByVehicle: { [string]: string },
	engineByClass: { [string]: string },
	defaultEngine: string,
	shiftDip: number, -- engine volume share while an upshift's dip lasts (Config/Driving fuel.shiftTime)
	-- Other players' throttle never reaches this client, so it is read from their acceleration.
	load: {
		fullAccel: number, -- studs/s^2 of acceleration that sounds like full throttle
		cruiseLoad: number, -- throttle share that holding top speed sounds like (it scales with speed)
		filterTime: number, -- seconds; low-pass filter on the measured acceleration (network jitter)
	},
	-- Tyre squeal while the car slides sideways (lateral speed of the chassis, mph).
	tyre: {
		loop: string,
		slipStartMph: number, -- sideways speed where the squeal starts
		slipFullMph: number, -- sideways speed where it is loudest
		minSpeedMph: number, -- slower cars never squeal (a parked car settling)
		groundProbe: number, -- studs below the chassis that count as on the ground (no squeal in the air)
		minPitch: number,
		maxPitch: number,
		filterTime: number, -- seconds; smooths the squeal in and out
	},
	-- Wind in the car the local player sits in, from startMph to fullMph.
	wind: { loop: string, startMph: number, fullMph: number, minPitch: number, maxPitch: number, curve: number },
	horn: { loop: string },
	-- The driver's indicator tick: one click as the lamps come on, a lower one as they go off.
	indicatorTick: { sfx: string, onPlaybackSpeed: number, offPlaybackSpeed: number },
	minChange: number, -- smallest change of a Sound's Volume or PlaybackSpeed worth writing
}

export type Audio = {
	tracks: { [string]: Track },
	-- Order the tracks are listed in (phone, dev tools); ids into `tracks`.
	trackOrder: { string },
	sfx: { [string]: Sfx },
	loops: { [string]: Loop },
	car: CarAudio,
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
		-- Roast fixes: the driver's indicator relay click (played flat, for the driver only).
		indicatorTick = {
			assetId = 75313445954583,
			volume = 0.45,
			playbackSpeed = 1,
			rollOffMaxDistance = 20,
			maxSeconds = 1,
		},
	},
	-- Roast fixes (2026-10-24): every loop is 2-4 s and seamless (crossfaded at the seam), mono, recorded at one
	-- steady pitch so PlaybackSpeed can carry the revs.
	loops = {
		evWhine = { assetId = 102120070632373, volume = 0.45, rollOffMinDistance = 14, rollOffMaxDistance = 160 },
		engineSmall = { assetId = 80252530438440, volume = 0.5, rollOffMinDistance = 16, rollOffMaxDistance = 220 },
		engineRumble = { assetId = 91483557684133, volume = 0.55, rollOffMinDistance = 18, rollOffMaxDistance = 260 },
		engineHigh = { assetId = 82030106933608, volume = 0.5, rollOffMinDistance = 18, rollOffMaxDistance = 260 },
		tyreSqueal = { assetId = 98997571941576, volume = 0.5, rollOffMinDistance = 14, rollOffMaxDistance = 180 },
		wind = { assetId = 93819952415798, volume = 0.4, rollOffMinDistance = 10, rollOffMaxDistance = 40 },
		horn = { assetId = 87090727663980, volume = 0.8, rollOffMinDistance = 25, rollOffMaxDistance = 400 },
	},
	car = {
		maxDistance = 260,
		maxEngines = 6,
		rankInterval = 0.25,
		ev = {
			loop = "evWhine",
			minPitch = 0.55,
			maxPitch = 1.6,
			idleVolume = 0.05, -- an electric car at rest is all but silent
			speedVolume = 0.6,
			loadVolume = 0.35,
		},
		engines = {
			-- A small four-cylinder: buzzy, revs high.
			small = { loop = "engineSmall", idlePitch = 0.6, redlinePitch = 1.55, idleVolume = 0.35, loadVolume = 0.65 },
			-- A big eight-cylinder rumble: low and heavy, short of breath at the top.
			rumble = {
				loop = "engineRumble",
				idlePitch = 0.62,
				redlinePitch = 1.4,
				idleVolume = 0.4,
				loadVolume = 0.6,
			},
			-- A high-revving supercar engine, recorded near the top of its range.
			high = { loop = "engineHigh", idlePitch = 0.45, redlinePitch = 1.12, idleVolume = 0.3, loadVolume = 0.7 },
		},
		engineByVehicle = {},
		engineByClass = {
			economy = "small",
			sedan = "small",
			minivan = "small",
			van = "small",
			suv = "rumble",
			pickup = "rumble",
			offroad = "rumble",
			luxury = "rumble",
			muscle = "rumble",
			heavy = "rumble",
			service = "rumble",
			sports = "high",
			exotic = "high",
			hypercar = "high",
		},
		defaultEngine = "small",
		shiftDip = 0.55,
		load = {
			fullAccel = 14,
			cruiseLoad = 0.35,
			filterTime = 0.18,
		},
		tyre = {
			loop = "tyreSqueal",
			slipStartMph = 5,
			slipFullMph = 16,
			minSpeedMph = 8,
			groundProbe = 6,
			minPitch = 0.92,
			maxPitch = 1.08,
			filterTime = 0.12,
		},
		wind = { loop = "wind", startMph = 30, fullMph = 120, minPitch = 0.85, maxPitch = 1.25, curve = 1.6 },
		horn = { loop = "horn" },
		indicatorTick = { sfx = "indicatorTick", onPlaybackSpeed = 1, offPlaybackSpeed = 0.86 },
		minChange = 0.01,
	},
}

return Audio
