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
	"exploration": [50, 52, 53, 55, 57, 58, 60],      # D Aeolian (natural minor)
	"village":     [50, 52, 53, 55, 57, 59, 60],      # D Dorian (raised 6)
	"combat":      [50, 51, 53, 55, 57, 58, 60],      # D Phrygian (b2)
	"ritual":      [50, 51, 53, 55, 57, 58],          # D Phrygian, 6 notes
}

# ── Tempo + drone config per mode ───────────────────────────────────────────
const MODE_BPM := {
	"exploration": 60.0,
	"village":     78.0,
	"combat":     108.0,
	"ritual":      50.0,
}

const MODE_DRONE_NOTES := {
	"exploration": [
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.18},    # D2
		{"midi": 45, "instrument": "tagelharpa", "gain": 0.12},    # A2 (open fifth)
	],
	"village": [
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.20},    # D2 — warm
		{"midi": 45, "instrument": "tagelharpa", "gain": 0.14},
	],
	"combat": [
		{"midi": 26, "instrument": "tagelharpa", "gain": 0.18},    # D1 — depth
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.16},    # D2
		{"midi": 45, "instrument": "tagelharpa", "gain": 0.10},    # A2
	],
	"ritual": [
		{"midi": 26, "instrument": "throat_hum", "gain": 0.22},    # D1 throat-style
		{"midi": 38, "instrument": "tagelharpa", "gain": 0.10},    # D2 bowed
	],
}

# ── Melody phrase libraries (per mode) ──────────────────────────────────────
# Each entry: {"instrument": "lyre"|"flute"|"horn", "notes": [[scale_idx, beats], ...]}
# scale_idx is into SCALES[mode]. Use -1 in [midi, beats] form for rests
# at the renderer level; in phrase definitions here, we render -1 as rest
# by setting scale_idx = -1.
const PHRASE_LIBRARY := {
	"exploration": [
		# Sparse plaintive bone-flute calls
		{"instrument": "flute", "notes": [[0, 2.0], [-1, 1.0], [2, 3.0]]},
		{"instrument": "flute", "notes": [[4, 1.5], [3, 0.5], [2, 2.0], [-1, 1.0], [0, 2.0]]},
		{"instrument": "flute", "notes": [[5, 1.0], [4, 1.0], [3, 2.0], [-1, 1.0], [2, 1.0], [0, 3.0]]},
		{"instrument": "flute", "notes": [[2, 1.0], [4, 1.0], [5, 2.0], [4, 1.0], [2, 2.0]]},
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
	],
	"ritual": [
		# Distant horn calls
		{"instrument": "horn", "notes": [[0, 3.0], [-1, 1.0], [2, 4.0]]},
		{"instrument": "horn", "notes": [[3, 4.0], [-1, 2.0], [0, 4.0]]},
		{"instrument": "horn", "notes": [[0, 2.0], [3, 4.0], [-1, 1.0], [0, 3.0]]},
	],
}

# Percussion patterns per mode. dur_beats is the loop length in beats.
const PERCUSSION_PATTERNS := {
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
	"exploration": [10.0, 18.0],
	"village":      [5.0, 10.0],
	"combat":       [3.0,  6.0],
	"ritual":      [14.0, 26.0],
}

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
	_drone_a = AudioStreamPlayer.new(); _drone_a.bus = "Music"; add_child(_drone_a)
	_drone_b = AudioStreamPlayer.new(); _drone_b.bus = "Music"; add_child(_drone_b)
	_melody  = AudioStreamPlayer.new(); _melody.bus  = "Music"; add_child(_melody)
	_perc    = AudioStreamPlayer.new(); _perc.bus    = "Music"; add_child(_perc)
	_drone_a.volume_db = -60.0
	_drone_b.volume_db = -60.0
	_perc.volume_db    = -60.0

# ── Pre-generation ──────────────────────────────────────────────────────────
func _generate_all_streams() -> void:
	# Drones — one looping stream per mode.
	for mode: Variant in MODE_DRONE_NOTES.keys():
		var ms: String = String(mode)
		_drones[ms] = SoundForge.render_drone(MODE_DRONE_NOTES[ms], 24.0)
	# Phrases — render every phrase in every mode.
	for mode: Variant in PHRASE_LIBRARY.keys():
		var ms: String = String(mode)
		var bpm: float = MODE_BPM[ms]
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
					midi_notes.append([int(scale[idx % scale.size()]), beats])
			bank.append(SoundForge.render_phrase(midi_notes, instrument, bpm))
		_phrases[ms] = bank
	# Percussion — village clack + 3 combat intensity tiers.
	_percussion["village"]  = SoundForge.render_percussion(
		PERCUSSION_PATTERNS.village_clack.pattern,
		MODE_BPM.village, int(PERCUSSION_PATTERNS.village_clack.dur_beats))
	for tier: int in range(3):
		var key: String = "combat_%d" % tier
		_percussion[key] = SoundForge.render_percussion(
			PERCUSSION_PATTERNS[key].pattern,
			MODE_BPM.combat, int(PERCUSSION_PATTERNS[key].dur_beats))

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

func _evaluate_mode() -> void:
	if _player_ref == null or not is_instance_valid(_player_ref):
		_player_ref = get_tree().get_first_node_in_group("player") as Node2D
	if _ground_ref == null or not is_instance_valid(_ground_ref):
		_ground_ref = get_tree().get_first_node_in_group("ground")
	if _player_ref == null or _ground_ref == null:
		return

	var biome: String = _ground_ref.call(
		"biome_at_world", _player_ref.global_position) as String

	var mode: String
	var intensity_tier: int = 0

	# Spec rule order: town first, peaceful next, boss, combat, default.
	if biome == "town" or biome == "road":
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
	# Drone crossfade — A/B players. Pick the unused slot for the new track.
	var fresh: AudioStreamPlayer = _drone_b if _active_drone == 0 else _drone_a
	var stale: AudioStreamPlayer = _drone_a if _active_drone == 0 else _drone_b
	if _drones.has(mode):
		fresh.stream = _drones[mode]
		fresh.volume_db = -60.0
		fresh.play()
		_fade(fresh, -6.0, fade_seconds)
	if stale.playing:
		_fade_out_stop(stale, fade_seconds)
	_active_drone = 1 - _active_drone
	# Percussion — only village + combat have it.
	var perc_key := _percussion_key_for_mode(mode, intensity_tier)
	if perc_key.is_empty():
		_fade_out_stop(_perc, fade_seconds)
	else:
		_perc.stream = _percussion[perc_key]
		if not _perc.playing:
			_perc.volume_db = -60.0
			_perc.play()
		_fade(_perc, _perc_target_db(mode, intensity_tier), fade_seconds)
	# Trigger an immediate phrase so the mode change isn't silent for
	# the next phrase gap.
	_phrase_t = 0.0
	_next_phrase_at = 0.8

func _percussion_key_for_mode(mode: String, tier: int) -> String:
	match mode:
		"village":
			return "village"
		"combat":
			return "combat_%d" % tier
	return ""

func _perc_target_db(mode: String, tier: int) -> float:
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
