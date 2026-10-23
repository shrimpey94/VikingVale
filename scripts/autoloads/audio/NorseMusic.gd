extends Node

## ── NorseMusic ──────────────────────────────────────────────────────────────
##
## Layered procedural music director. Replaces AudioManager's old single-
## track music system with a 3-layer streaming model:
##
##   drone player      — continuous low note, crossfades on mode change
##   melody player     — short phrases triggered at intervals; silent between
##   percussion player — looping rhythm pattern, only in modes that use it
##
## Ambience (ocean/wind/forest/cave) stays in AudioManager — the user spec
## says "Existing Ambience Should Stay Dominant." This director sits on the
## SFX→Music bus path and never touches the Ambience bus.
##
## Mode selection (per the spec):
##   biome=town/road        → village,     intensity=0
##   peaceful UI active     → exploration, intensity=0
##   near boss / boss zone  → ritual,      intensity=0
##   in combat              → combat,      intensity=hp+enemy formula
##   default                → exploration, intensity=0
##
## Combat intensity is the only place dynamic intensity changes the layers.

# SoundForge uses `class_name SoundForge` — globally available, no preload
# const needed (would shadow the class_name symbol under strict mode).

# ── Modal scales (5-7 note Norse-friendly modes) ────────────────────────────
const SCALES := {
	"exploration": [38, 40, 41, 43, 45, 46, 48],      # D Aeolian, DOWN an octave — deep foghorn/war-horn register
	"village":     [50, 52, 53, 55, 57, 59, 60],      # D Dorian (raised 6)
	"combat":      [50, 51, 53, 55, 57, 58, 60],      # D Phrygian (b2)
	"ritual":      [50, 51, 53, 55, 57, 58],          # D Phrygian, 6 notes
	"dungeon":     [50, 51, 53, 55, 56, 58, 60],      # D Locrian-ish (b2 b5) — ominous
}

# ── Tempo + drone config per mode ───────────────────────────────────────────
const MODE_BPM := {
	"exploration": 60.0,
	"village":     78.0,
	"combat":     108.0,
	"ritual":      50.0,
	"dungeon":     46.0,
}

const MODE_DRONE_NOTES := {
	"exploration": [
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.18},    # D2
		{"midi": 45, "instrument": "tagelharpa", "gain": 0.12},    # A2 (open fifth)
		{"midi": 38, "instrument": "throat_hum", "gain": 0.14},    # low viking HUM
	],
	"village": [
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.20},    # D2 — warm
		{"midi": 45, "instrument": "tagelharpa", "gain": 0.14},
	],
	"combat": [
		{"midi": 26, "instrument": "tagelharpa", "gain": 0.18},    # D1 — depth
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.16},    # D2
		{"midi": 45, "instrument": "tagelharpa", "gain": 0.10},    # A2
		{"midi": 38, "instrument": "throat_hum", "gain": 0.20},    # battle war-hum
		{"midi": 45, "instrument": "throat_hum", "gain": 0.12},    # A2 hum (open fifth)
	],
	"ritual": [
		{"midi": 26, "instrument": "throat_hum", "gain": 0.24},    # D1 deep hum
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.10},    # D2 bowed
	],
	# Dungeon: dark + heavy + sparse — cavernous low hum + a low bowed fifth.
	"dungeon": [
		{"midi": 26, "instrument": "throat_hum", "gain": 0.22},    # D1 — cavernous hum
		{"midi": 33, "instrument": "tagelharpa", "gain": 0.09},    # A1 — low fifth
	],
}

# ── Melody phrase libraries (per mode) ──────────────────────────────────────
# Each entry: {"instrument": "lyre"|"flute"|"horn", "notes": [[scale_idx, beats], ...]}
# scale_idx is into SCALES[mode]. Use -1 in [midi, beats] form for rests
# at the renderer level; in phrase definitions here, we render -1 as rest
# by setting scale_idx = -1.
const PHRASE_LIBRARY := {
	"exploration": [
		# Deep war-horn MELODIES — actual singable Viking tunes (a "heave-ho" line),
		# not sparse airy calls. All horn, in the low foghorn register (scale is octave-down).
		{"instrument": "horn", "notes": [[0, 1.5], [2, 1.0], [3, 1.0], [4, 2.0], [3, 1.0], [2, 1.0], [0, 2.0]]},   # D F G A G F D
		{"instrument": "horn", "notes": [[4, 2.0], [3, 1.0], [2, 1.0], [0, 2.0], [2, 1.0], [0, 2.0]]},             # A G F D  F D
		{"instrument": "horn", "notes": [[0, 1.0], [0, 1.0], [2, 1.0], [3, 1.0], [4, 2.0], [3, 1.0], [2, 2.0]]},   # rising heave
		{"instrument": "horn", "notes": [[2, 1.0], [3, 1.0], [2, 1.0], [0, 2.0], [1, 1.0], [0, 2.0]]},             # sway, resolves to D
		{"instrument": "horn", "notes": [[0, 3.0], [4, 3.0], [3, 1.0], [2, 1.0], [0, 3.0]]},                       # long horn call
		{"instrument": "horn", "notes": [[0, 1.0], [2, 1.0], [3, 1.5], [4, 1.5], [3, 1.0], [0, 2.0]]},             # D F G A G D
	],
	"village": [
		# Warm lyre plucks — short, repeating
		{"instrument": "lyre", "notes": [[0, 0.5], [2, 0.5], [4, 0.5], [2, 0.5], [0, 1.0]]},
		{"instrument": "lyre", "notes": [[3, 0.5], [4, 0.5], [3, 0.5], [2, 0.5], [0, 1.0]]},
		{"instrument": "lyre", "notes": [[0, 1.0], [2, 0.5], [4, 0.5], [5, 1.0], [4, 0.5], [2, 0.5]]},
		{"instrument": "lyre", "notes": [[4, 0.5], [5, 0.5], [4, 0.5], [3, 0.5], [2, 1.0], [0, 1.0]]},
	],
	"combat": [
		# Short aggressive bone-flute motifs — Phrygian b2 prominent
		{"instrument": "flute", "notes": [[0, 0.5], [1, 0.5], [0, 1.0]]},      # D → Eb → D
		{"instrument": "flute", "notes": [[0, 0.25], [1, 0.25], [3, 0.5], [0, 1.0]]},
		{"instrument": "flute", "notes": [[5, 0.5], [3, 0.5], [1, 0.5], [0, 0.5]]},
		{"instrument": "flute", "notes": [[0, 0.5], [3, 0.5], [5, 0.5], [3, 0.5], [0, 1.0]]},
		{"instrument": "flute", "notes": [[1, 0.25], [0, 0.25], [1, 0.25], [0, 0.25], [3, 1.0]]},
		{"instrument": "horn",  "notes": [[0, 1.0], [4, 1.0], [0, 2.0]]},                       # war-horn
		{"instrument": "flute", "notes": [[0, 0.5], [1, 0.5], [3, 0.5], [4, 0.5], [3, 0.5], [0, 1.0]]},
		{"instrument": "horn",  "notes": [[3, 1.0], [4, 1.0], [5, 2.0]]},
	],
	"ritual": [
		# Distant horn calls
		{"instrument": "horn", "notes": [[0, 3.0], [-1, 1.0], [2, 4.0]]},
		{"instrument": "horn", "notes": [[3, 4.0], [-1, 2.0], [0, 4.0]]},
		{"instrument": "horn", "notes": [[0, 2.0], [3, 4.0], [-1, 1.0], [0, 3.0]]},
	],
	"dungeon": [
		# Sparse + oppressive — lone flute/horn shapes with long silences between.
		{"instrument": "horn",  "notes": [[0, 4.0], [-1, 3.0], [1, 3.0]]},
		{"instrument": "flute", "notes": [[0, 1.0], [1, 1.0], [-1, 2.0], [4, 3.0]]},
		{"instrument": "horn",  "notes": [[4, 3.0], [-1, 4.0], [0, 5.0]]},
		{"instrument": "flute", "notes": [[1, 0.5], [0, 0.5], [-1, 3.0], [3, 2.0], [1, 2.0]]},
	],
}

# Percussion patterns per mode. dur_beats is the loop length in beats.
const PERCUSSION_PATTERNS := {
	# Soft, slow war-drum heartbeat under the open-world hum — "drums + humming".
	"exploration_march": {
		"dur_beats": 8,
		"pattern": [
			[0.0, "drum", 0.45],
			[1.5, "drum", 0.22],
			[4.0, "drum", 0.38],
			[5.5, "drum", 0.20],
		],
	},
	"village_clack": {
		"dur_beats": 8,
		"pattern": [
			[0.0,   "clack", 0.55],
			[4.0,   "clack", 0.55],
		],
	},
	"combat_0": {
		"dur_beats": 4,
		"pattern": [
			[0.0, "drum", 0.70],
			[2.0, "drum", 0.50],
		],
	},
	"combat_1": {
		"dur_beats": 4,
		"pattern": [
			[0.0, "drum", 0.80],
			[1.0, "drum", 0.40],
			[2.0, "drum", 0.65],
			[3.0, "drum", 0.40],
		],
	},
	"combat_2": {
		"dur_beats": 4,
		"pattern": [
			[0.0, "drum", 0.90],
			[0.5, "rattle", 0.45],
			[1.0, "drum", 0.55],
			[1.5, "rattle", 0.45],
			[2.0, "drum", 0.80],
			[2.5, "rattle", 0.45],
			[3.0, "drum", 0.55],
			[3.5, "rattle", 0.45],
		],
	},
}

# ── Phrase scheduling cadence per mode (sec between phrases) ────────────────
const PHRASE_GAP := {
	"exploration": [6.0, 12.0],
	"village":      [5.0, 10.0],
	"combat":       [3.0,  6.0],
	"ritual":      [14.0, 26.0],
	"dungeon":     [16.0, 30.0],
}

# Open-world CHORD PROGRESSIONS ("verses") — rotated at random so exploration
# EVOLVES instead of droning one chord. D-minor / Aeolian, open + adventurous
# (root+fifth power chords, no spooky diminished). Each bar = {chord, beats};
# render_progression adds a grounded BASS VOICE an octave under each chord + the
# bowed tagelharpa. 8 verses rotate randomly over the soft war-drum heartbeat.
const EXPLORATION_PROGRESSIONS := [
	[{"chord": [50, 57], "beats": 4}, {"chord": [46, 53], "beats": 4},   # i-VI-VII-i
	 {"chord": [48, 55], "beats": 4}, {"chord": [50, 57], "beats": 4}],
	[{"chord": [50, 57], "beats": 4}, {"chord": [48, 55], "beats": 4},   # i-VII-VI-VII
	 {"chord": [46, 53], "beats": 4}, {"chord": [48, 55], "beats": 4}],
	[{"chord": [50, 57], "beats": 4}, {"chord": [43, 50], "beats": 4},   # i-iv-VII-i
	 {"chord": [48, 55], "beats": 4}, {"chord": [50, 57], "beats": 4}],
	[{"chord": [50, 57], "beats": 4}, {"chord": [46, 53], "beats": 4},   # i-VI-III-VII
	 {"chord": [53, 60], "beats": 4}, {"chord": [48, 55], "beats": 4}],
	[{"chord": [50, 57], "beats": 4}, {"chord": [45, 52], "beats": 4},   # i-v-VI-VII
	 {"chord": [46, 53], "beats": 4}, {"chord": [48, 55], "beats": 4}],
	[{"chord": [50, 57], "beats": 4}, {"chord": [53, 60], "beats": 4},   # i-III-VII-i
	 {"chord": [48, 55], "beats": 4}, {"chord": [50, 57], "beats": 4}],
	[{"chord": [46, 53], "beats": 4}, {"chord": [48, 55], "beats": 4},   # VI-VII-i-i
	 {"chord": [50, 57], "beats": 4}, {"chord": [50, 57], "beats": 4}],
	[{"chord": [50, 57], "beats": 4}, {"chord": [48, 55], "beats": 4},   # i-VII-iv-VI
	 {"chord": [43, 50], "beats": 4}, {"chord": [46, 53], "beats": 4}],
]

# Open-world DRUM patterns (5 "tracks") — rotate with the verses so the rhythm
# also changes instead of one loop. Each = [[beat, "drum", strength], …] over 8
# beats. render_percussion turns "drum" into the war-drum hit.
const EXPLORATION_DRUM_BEATS := 8
const EXPLORATION_DRUMS := [
	[[0.0, "drum", 0.50], [1.5, "drum", 0.24], [4.0, "drum", 0.42], [5.5, "drum", 0.22]],
	[[0.0, "drum", 0.46], [2.0, "drum", 0.38], [4.0, "drum", 0.46], [6.0, "drum", 0.38]],
	[[0.0, "drum", 0.50], [1.0, "drum", 0.22], [2.0, "drum", 0.40], [3.0, "drum", 0.22],
	 [4.0, "drum", 0.50], [5.0, "drum", 0.22], [6.0, "drum", 0.40], [7.0, "drum", 0.22]],
	[[0.0, "drum", 0.55], [4.0, "drum", 0.46]],
	[[0.0, "drum", 0.50], [0.75, "drum", 0.26], [1.5, "drum", 0.34],
	 [4.0, "drum", 0.50], [4.75, "drum", 0.26], [5.5, "drum", 0.34]],
]

# ── Boss detection constants ────────────────────────────────────────────────
const BOSS_MONSTER_TYPES := {"nidhogg": true, "draugr": true}
const BOSS_BIOMES := {"helheim": true, "ashlands": true}
const BOSS_PROXIMITY := 192.0   # 6 tiles

# Peaceful-activity lock: any open_shop / open_bank / open_crafting /
# open_cooking / open_forge / player_start_action sets this for N seconds.
# It re-arms every time an event fires while the panel is in use. After
# the timeout it expires naturally — the player has walked off.
const PEACEFUL_LOCK_SECONDS := 6.0

# ── State ───────────────────────────────────────────────────────────────────
var _drone_a: AudioStreamPlayer = null
var _drone_b: AudioStreamPlayer = null
var _melody:  AudioStreamPlayer = null
var _perc:    AudioStreamPlayer = null
var _active_drone: int = 0   # 0 → _drone_a, 1 → _drone_b

var _current_mode: String = "exploration"
var _current_intensity_tier: int = 0       # 0..2; only set by combat
var _in_combat: bool = false
var _peaceful_until: float = -1e9

var _player_ref: Node2D = null
var _ground_ref: Node = null

# Pre-generated stream banks
var _drones: Dictionary = {}                # mode -> AudioStreamWAV
var _phrases: Dictionary = {}               # mode -> Array[AudioStreamWAV]
var _percussion: Dictionary = {}            # key (e.g. "combat_1") -> AudioStreamWAV
var _expl_progs: Array = []                 # exploration verse streams (rotated)
var _expl_prog_idx: int = -1
var _expl_perc: Array = []                  # exploration drum-pattern streams (rotated)
var _expl_perc_idx: int = -1
var _prog_rotate_t: float = 0.0
var _next_prog_at: float = 40.0             # seconds until the next verse swap

# Polling cadence
var _mode_poll_t: float = 0.0
var _phrase_t: float = 0.0
var _next_phrase_at: float = 1.0            # first phrase after 1 s

# Seeded RNG for phrase selection (consistency between sessions)
var _rng: RandomNumberGenerator = null
const _RNG_SEED: int = 0x4E_4F_52_53      # "NORS"

func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = _RNG_SEED
	_build_players()
	_generate_all_streams()
	_wire_signals()
	# Start in exploration — no fade in.
	_apply_mode("exploration", 0, 0.5)

# ── Player nodes ────────────────────────────────────────────────────────────
func _build_players() -> void:
	# Per-layer sub-buses (→ Music) so the admin mixer can balance drone / voices,
	# melody and drums LIVE without regenerating anything.
	_ensure_bus("MusicDrone", "Music")
	_ensure_bus("MusicMelody", "Music")
	_ensure_bus("MusicPerc", "Music")
	_drone_a = AudioStreamPlayer.new(); _drone_a.bus = "MusicDrone"; add_child(_drone_a)
	_drone_b = AudioStreamPlayer.new(); _drone_b.bus = "MusicDrone"; add_child(_drone_b)
	_melody  = AudioStreamPlayer.new(); _melody.bus  = "MusicMelody"; add_child(_melody)
	_perc    = AudioStreamPlayer.new(); _perc.bus    = "MusicPerc"; add_child(_perc)
	_drone_a.volume_db = -60.0
	_drone_b.volume_db = -60.0
	_perc.volume_db    = -60.0

## Create a sub-bus routed to `send_to` (falls back to Master) if it doesn't exist.
func _ensure_bus(bus_name: String, send_to: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	var send := send_to if AudioServer.get_bus_index(send_to) != -1 else "Master"
	AudioServer.set_bus_send(idx, send)

# ── Admin mixer API (live tuning without a game restart) ────────────────────
var _forced_mode: String = ""
var _forced_until: float = -1e9
var _root_transpose: int = 0     # semitones the whole key is shifted by (regen)
var _tempo_scale: float = 1.0    # multiplies every mode's BPM (regen)

func current_mode() -> String:
	return _current_mode

func current_verse() -> int:
	return _expl_prog_idx + 1        # 1-based; 0 = none playing yet

func verse_count() -> int:
	return _expl_progs.size()

func current_drum() -> int:
	return _expl_perc_idx + 1

func drum_count() -> int:
	return _expl_perc.size()

## Shift the whole key (semitones) — takes effect on the next regenerate().
func set_root_transpose(semitones: int) -> void:
	_root_transpose = clampi(semitones, -12, 12)

## Scale the tempo of every mode — takes effect on the next regenerate().
func set_tempo_scale(scale: float) -> void:
	_tempo_scale = clampf(scale, 0.6, 1.6)

## Regenerate every stream from the CURRENT code/params, then re-apply the mode.
## Lets the admin re-roll the music (and pick up hot-reloaded code) without a
## full game restart.
func regenerate() -> void:
	_drones.clear()
	_phrases.clear()
	_percussion.clear()
	_expl_progs.clear()
	_expl_prog_idx = -1
	_generate_all_streams()
	var m: String = _current_mode
	_current_mode = "__reload__"   # ensure _apply_mode actually swaps the drone
	_apply_mode(m, _current_intensity_tier, 0.4)

## Force a mode for ~30 s so the admin can AUDITION it (exploration re-rolls its
## verse if already there). Auto-expires back to normal evaluation.
func force_mode(mode: String, tier: int = 0) -> void:
	_forced_mode = mode
	_forced_until = _now() + 30.0
	if _current_mode != mode:
		_apply_mode(mode, tier, 0.8)
	elif mode == "exploration":
		_rotate_expl_drone()

# ── Pre-generation ──────────────────────────────────────────────────────────
func _generate_all_streams() -> void:
	# Drones — one looping stream per mode (transposed by the admin's key shift).
	for mode: Variant in MODE_DRONE_NOTES.keys():
		var ms: String = String(mode)
		var notes: Array = []
		for nd: Variant in (MODE_DRONE_NOTES[ms] as Array):
			var d: Dictionary = (nd as Dictionary).duplicate()
			d["midi"] = int(d.get("midi", 50)) + _root_transpose
			notes.append(d)
		_drones[ms] = SoundForge.render_drone(notes, 24.0)
	# Phrases — render every phrase in every mode.
	for mode: Variant in PHRASE_LIBRARY.keys():
		var ms: String = String(mode)
		var bpm: float = float(MODE_BPM[ms]) * _tempo_scale
		var bank: Array = []
		for phrase_def: Variant in PHRASE_LIBRARY[ms]:
			var pd: Dictionary = phrase_def as Dictionary
			var instrument: String = str(pd.get("instrument", "lyre"))
			var raw_notes: Array = pd.get("notes", []) as Array
			# Translate scale indices to midi values using the mode's scale.
			var scale: Array = SCALES[ms] as Array
			var midi_notes: Array = []
			for nv: Variant in raw_notes:
				var na: Array = nv as Array
				var idx: int = int(na[0])
				var beats: float = float(na[1])
				if idx < 0:
					midi_notes.append([-1, beats])
				else:
					midi_notes.append([int(scale[idx % scale.size()]) + _root_transpose, beats])
			bank.append(SoundForge.render_phrase(midi_notes, instrument, bpm))
		_phrases[ms] = bank
	# Percussion. Exploration gets a BANK of 5 rotating drum patterns; village +
	# combat keep their fixed patterns. All tempo-scaled by the admin control.
	for pat: Variant in EXPLORATION_DRUMS:
		_expl_perc.append(SoundForge.render_percussion(
			pat as Array, float(MODE_BPM.exploration) * _tempo_scale, EXPLORATION_DRUM_BEATS))
	_percussion["exploration"] = _expl_perc[0]   # fallback if the bank is bypassed
	_percussion["village"]  = SoundForge.render_percussion(
		PERCUSSION_PATTERNS.village_clack.pattern,
		float(MODE_BPM.village) * _tempo_scale, int(PERCUSSION_PATTERNS.village_clack.dur_beats))
	for tier: int in range(3):
		var key: String = "combat_%d" % tier
		_percussion[key] = SoundForge.render_percussion(
			PERCUSSION_PATTERNS[key].pattern,
			float(MODE_BPM.combat) * _tempo_scale, int(PERCUSSION_PATTERNS[key].dur_beats))
	# Exploration verses — rotating chord progressions (transposed + tempo-scaled).
	for prog: Variant in EXPLORATION_PROGRESSIONS:
		var tprog: Array = []
		for bar: Variant in (prog as Array):
			var bd: Dictionary = bar as Dictionary
			var ch: Array = []
			for mv: Variant in (bd.get("chord", []) as Array):
				ch.append(int(mv) + _root_transpose)
			tprog.append({"chord": ch, "beats": bd.get("beats", 4.0)})
		_expl_progs.append(
			SoundForge.render_progression(tprog, float(MODE_BPM.exploration) * _tempo_scale))

# ── Signal wiring ───────────────────────────────────────────────────────────
func _wire_signals() -> void:
	Events.open_combat.connect(_on_combat_start)
	Events.combat_ended.connect(_on_combat_end)
	# Peaceful activities — each fires the lock so the music drops to
	# exploration even mid-biome.
	Events.open_shop.connect(_on_peaceful_event_2arg)
	Events.open_bank.connect(_on_peaceful_event)
	Events.open_crafting.connect(_on_peaceful_event)
	Events.open_cooking.connect(_on_peaceful_event)
	Events.open_forge.connect(_on_peaceful_event)
	Events.open_construction.connect(_on_peaceful_event)
	Events.open_runesmithing.connect(_on_peaceful_event)
	Events.open_auction_house.connect(_on_peaceful_event)
	Events.player_start_action.connect(_on_player_action_start)
	# trade_request_received fires when someone proposes a trade — that
	# moment is also peaceful (trade UI opens).
	Events.trade_request_received.connect(_on_peaceful_event_str)
	# Feel-good audio cues — pair with HUD visual feedback so each
	# moment has both a sound + a visual punch.
	Events.monster_attack_landed.connect(_duck_music_on_damage)
	Events.level_up.connect(_pulse_master_on_level_up)


## Briefly dip the Music bus by 6 dB when the player gets hit. The pause
## lets the SFX layer (damage thud, monster grunt) read clearly without
## fighting the looping drone for attention. Snaps back over 0.4s so the
## music doesn't feel chopped — just "the room held its breath."
func _duck_music_on_damage() -> void:
	var bus_idx: int = AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		return
	var original_db: float = AudioServer.get_bus_volume_db(bus_idx)
	AudioServer.set_bus_volume_db(bus_idx, original_db - 6.0)
	# Restore on a one-shot timer so a rapid-fire string of hits doesn't
	# stack the duck (the second hit overwrites the first with the same
	# original_db captured at its moment, then both restore correctly).
	get_tree().create_timer(0.40).timeout.connect(func() -> void:
		AudioServer.set_bus_volume_db(bus_idx, original_db))


## +2 dB pulse on the Master bus for 0.3s when the player levels up.
## Pairs with the existing ascending chime from AudioManager.play_ui
## "level_up" — together they make the moment feel celebratory rather
## than just "the number went up."
func _pulse_master_on_level_up(_skill: String, _new_level: int) -> void:
	var bus_idx: int = AudioServer.get_bus_index("Master")
	if bus_idx == -1:
		return
	var original_db: float = AudioServer.get_bus_volume_db(bus_idx)
	AudioServer.set_bus_volume_db(bus_idx, original_db + 2.0)
	get_tree().create_timer(0.30).timeout.connect(func() -> void:
		AudioServer.set_bus_volume_db(bus_idx, original_db))


func _on_combat_start(_monster: Node) -> void:
	_in_combat = true

func _on_combat_end() -> void:
	_in_combat = false

func _on_peaceful_event() -> void:
	_peaceful_until = _now() + PEACEFUL_LOCK_SECONDS

func _on_peaceful_event_2arg(_a: Variant, _b: Variant) -> void:
	_peaceful_until = _now() + PEACEFUL_LOCK_SECONDS

func _on_peaceful_event_str(_a: String) -> void:
	_peaceful_until = _now() + PEACEFUL_LOCK_SECONDS

func _on_player_action_start(_action_type: String, _target: Node) -> void:
	_peaceful_until = _now() + PEACEFUL_LOCK_SECONDS

# ── Polling + scheduling ────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_mode_poll_t += delta
	if _mode_poll_t >= 1.0:
		_mode_poll_t = 0.0
		_evaluate_mode()
	# Phrase scheduling — one phrase at a time on the melody layer.
	_phrase_t += delta
	if _phrase_t >= _next_phrase_at:
		_phrase_t = 0.0
		_play_next_phrase()
		_schedule_next_phrase()
	# Rotate the open-world "verse" so exploration keeps evolving (not one loop).
	if _current_mode == "exploration" and not _expl_progs.is_empty():
		_prog_rotate_t += delta
		if _prog_rotate_t >= _next_prog_at:
			_prog_rotate_t = 0.0
			_next_prog_at = _rng.randf_range(30.0, 50.0)
			_rotate_expl_drone()

func _evaluate_mode() -> void:
	# Admin audition override — hold the forced mode until it expires.
	if _forced_mode != "":
		if _now() < _forced_until:
			return
		_forced_mode = ""
	if _player_ref == null or not is_instance_valid(_player_ref):
		_player_ref = get_tree().get_first_node_in_group("player") as Node2D
	if _ground_ref == null or not is_instance_valid(_ground_ref):
		_ground_ref = get_tree().get_first_node_in_group("ground")
	if _player_ref == null or _ground_ref == null:
		return

	# Inside an interior, read the biome at the building's exterior anchor so
	# music matches the local area rather than the far-off interior band.
	var _mpos: Vector2 = GameManager.overworld_pos(_player_ref.global_position)
	var biome: String = _ground_ref.call(
		"biome_at_world", _mpos) as String

	var mode: String
	var intensity_tier: int = 0

	# A dungeon is its own world — the dark dungeon theme wins over biome/peaceful,
	# but an actual fight down there still swaps to combat music.
	var in_dungeon: bool = GameManager.in_interior \
		and str(GameManager.current_interior_id).begins_with("dungeon")

	# Spec rule order: dungeon, town, peaceful, boss, combat, default.
	if in_dungeon:
		if _in_combat:
			mode = "combat"
			intensity_tier = _compute_combat_tier()
		else:
			mode = "dungeon"
	elif biome == "town" or biome == "road":
		mode = "village"
	elif _is_peaceful_lock_active():
		mode = "exploration"
	elif _is_near_boss() or BOSS_BIOMES.has(biome):
		mode = "ritual"
	elif _in_combat:
		mode = "combat"
		intensity_tier = _compute_combat_tier()
	else:
		mode = "exploration"

	if mode != _current_mode or intensity_tier != _current_intensity_tier:
		_apply_mode(mode, intensity_tier, 3.0)

func _is_peaceful_lock_active() -> bool:
	return _now() < _peaceful_until

# Combat intensity formula from the spec:
#   intensity = (1 - HP%) * 0.6 + (nearbyEnemies/maxEnemies) * 0.4
# Mapped to 3 tiers: <0.33 → 0, <0.66 → 1, else 2.
func _compute_combat_tier() -> int:
	var hp_pct: float = 1.0
	var max_hp: int = int(GameManager.get_max_hp())
	if max_hp > 0:
		hp_pct = clampf(float(GameManager.current_hp) / float(max_hp), 0.0, 1.0)
	# Count aggroed monsters within 400 px of the player.
	var enemies: int = 0
	const RADIUS := 400.0
	const MAX_ENEMIES := 4.0
	for n: Node in get_tree().get_nodes_in_group("monster"):
		if not (n is Node2D):
			continue
		if not (n.get("is_alive") as bool):
			continue
		if (n as Node2D).global_position.distance_to(_player_ref.global_position) <= RADIUS:
			enemies += 1
	var enemy_factor: float = clampf(float(enemies) / MAX_ENEMIES, 0.0, 1.0)
	var intensity: float = (1.0 - hp_pct) * 0.6 + enemy_factor * 0.4
	intensity = clampf(intensity, 0.0, 1.0)
	if intensity < 0.33:
		return 0
	elif intensity < 0.66:
		return 1
	return 2

func _is_near_boss() -> bool:
	if _player_ref == null:
		return false
	var ppos: Vector2 = _player_ref.global_position
	for n: Node in get_tree().get_nodes_in_group("monster"):
		if not (n is Node2D):
			continue
		var mt: Variant = n.get("monster_type")
		if mt == null:
			continue
		if not BOSS_MONSTER_TYPES.has(str(mt)):
			continue
		if not (n.get("is_alive") as bool):
			continue
		if (n as Node2D).global_position.distance_to(ppos) <= BOSS_PROXIMITY:
			return true
	return false

# ── Mode apply / layer fades ────────────────────────────────────────────────
func _apply_mode(mode: String, intensity_tier: int, fade_seconds: float) -> void:
	_current_mode = mode
	_current_intensity_tier = intensity_tier
	# Drone crossfade — A/B players. Exploration plays a random rotating "verse"
	# (chord progression); every other mode uses its single looping drone.
	var fresh: AudioStreamPlayer = _drone_b if _active_drone == 0 else _drone_a
	var stale: AudioStreamPlayer = _drone_a if _active_drone == 0 else _drone_b
	var new_stream: AudioStream = null
	if mode == "exploration" and not _expl_progs.is_empty():
		new_stream = _pick_expl_stream()
		_prog_rotate_t = 0.0
		_next_prog_at = _rng.randf_range(30.0, 50.0)
	elif _drones.has(mode):
		new_stream = _drones[mode]
	if new_stream != null:
		fresh.stream = new_stream
		fresh.volume_db = -60.0
		fresh.play()
		_fade(fresh, -6.0, fade_seconds)
	if stale.playing:
		_fade_out_stop(stale, fade_seconds)
	_active_drone = 1 - _active_drone
	# Percussion. Exploration draws from its 5-pattern drum BANK (rotates with the
	# verses); other modes use their single fixed pattern.
	var perc_stream: AudioStream = null
	if mode == "exploration" and not _expl_perc.is_empty():
		perc_stream = _pick_expl_perc()
	else:
		var perc_key := _percussion_key_for_mode(mode, intensity_tier)
		if not perc_key.is_empty():
			perc_stream = _percussion.get(perc_key)
	if perc_stream == null:
		_fade_out_stop(_perc, fade_seconds)
	else:
		_perc.stream = perc_stream
		if not _perc.playing:
			_perc.volume_db = -60.0
			_perc.play()
		_fade(_perc, _perc_target_db(mode, intensity_tier), fade_seconds)
	# Trigger an immediate phrase so the mode change isn't silent for
	# the next phrase gap.
	_phrase_t = 0.0
	_next_phrase_at = 0.8

## Pick a random exploration verse stream, avoiding an immediate repeat.
func _pick_expl_stream() -> AudioStream:
	var i: int = _rng.randi() % _expl_progs.size()
	if _expl_progs.size() > 1 and i == _expl_prog_idx:
		i = (i + 1) % _expl_progs.size()
	_expl_prog_idx = i
	return _expl_progs[i]

## Pick a random exploration drum pattern, avoiding an immediate repeat.
func _pick_expl_perc() -> AudioStream:
	var i: int = _rng.randi() % _expl_perc.size()
	if _expl_perc.size() > 1 and i == _expl_perc_idx:
		i = (i + 1) % _expl_perc.size()
	_expl_perc_idx = i
	return _expl_perc[i]

## Crossfade the open-world drone to a fresh random verse (called on a timer
## while in exploration so the overworld music keeps evolving).
func _rotate_expl_drone() -> void:
	if _expl_progs.is_empty():
		return
	var fresh: AudioStreamPlayer = _drone_b if _active_drone == 0 else _drone_a
	var stale: AudioStreamPlayer = _drone_a if _active_drone == 0 else _drone_b
	fresh.stream = _pick_expl_stream()
	fresh.volume_db = -60.0
	fresh.play()
	_fade(fresh, -6.0, 5.0)
	if stale.playing:
		_fade_out_stop(stale, 5.0)
	_active_drone = 1 - _active_drone
	# Roll the drum pattern too, so the rhythm changes with the verse.
	if not _expl_perc.is_empty():
		_perc.stream = _pick_expl_perc()
		if not _perc.playing:
			_perc.volume_db = -60.0
			_perc.play()
		_fade(_perc, _perc_target_db("exploration", 0), 2.0)

func _percussion_key_for_mode(mode: String, tier: int) -> String:
	match mode:
		"exploration":
			return "exploration"
		"village":
			return "village"
		"combat":
			return "combat_%d" % tier
	return ""

func _perc_target_db(mode: String, tier: int) -> float:
	if mode == "exploration":
		return -10.0     # present war-drums under the open-world music
	if mode == "village":
		return -10.0
	if mode == "combat":
		return -8.0 + float(tier) * 1.5     # tier 0: -8, tier 1: -6.5, tier 2: -5
	return -60.0

# ── Phrase scheduling ──────────────────────────────────────────────────────
func _play_next_phrase() -> void:
	if not _phrases.has(_current_mode):
		return
	var bank: Array = _phrases[_current_mode] as Array
	if bank.is_empty():
		return
	# Seeded random selection — the same scene state produces the same
	# phrase sequence run-to-run (the spec asks for seed-based generation).
	var idx: int = _rng.randi() % bank.size()
	_melody.stop()
	_melody.stream = bank[idx]
	_melody.volume_db = _melody_target_db()
	_melody.play()

func _melody_target_db() -> float:
	# Combat melody sits a bit louder, ritual softer (distant horns).
	match _current_mode:
		"combat":
			return -6.0
		"ritual":
			return -10.0
		"village":
			return -7.0
		"dungeon":
			return -13.0
		"exploration":
			return -5.0   # the deep war-horn melody is now the THEME — present, not hidden
	return -8.0

func _schedule_next_phrase() -> void:
	var gap_range: Array = PHRASE_GAP.get(_current_mode, [12.0, 20.0]) as Array
	# Combat intensity shortens the gap further.
	var lo: float = float(gap_range[0])
	var hi: float = float(gap_range[1])
	if _current_mode == "combat":
		var scale: float = 1.0 - 0.20 * float(_current_intensity_tier)
		lo *= scale
		hi *= scale
	_next_phrase_at = _rng.randf_range(lo, hi)

# ── Fade helpers ────────────────────────────────────────────────────────────
func _fade(p: AudioStreamPlayer, target_db: float, seconds: float) -> void:
	if seconds <= 0.0:
		p.volume_db = target_db
		return
	var tw := create_tween()
	tw.tween_property(p, "volume_db", target_db, seconds)

func _fade_out_stop(p: AudioStreamPlayer, seconds: float) -> void:
	if not p.playing:
		return
	if seconds <= 0.0:
		p.stop()
		return
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -60.0, seconds)
	tw.tween_callback(Callable(p, "stop"))

func _now() -> float:
	return Time.get_unix_time_from_system()
