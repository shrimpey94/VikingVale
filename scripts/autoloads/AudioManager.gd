extends Node

## ── AudioManager (autoload) ──────────────────────────────────────────────────
##
## Global audio router. v1 is fully procedural — every sound is synthesized
## once at startup into an AudioStreamWAV (PCM) and cached by ID. No .ogg/.wav
## assets ship with the game.
##
## Structure (this file): bus layout, player pools, public play_*() API,
## volume persistence, signal-bus integration points.
## Generation (TBD): the _generate_*_sound() helpers are stubs that the
## procedural-audio pass will fill in. Until that pass lands, play_*() calls
## are safe no-ops — they look up an empty stream and skip playback.
##
## Buses (created at runtime via AudioServer):
##   0  Master      (engine default)
##   1  Music       — looping music tracks (one at a time, crossfade)
##   2  SFX         — combat / gathering / UI one-shots
##   3  Ambience    — biome-driven looping atmospherics (one at a time, crossfade)
##
## Player pools:
##   SFX     6 voices, round-robin (polyphonic — overlapping swings/hits OK)
##   UI      4 voices, round-robin (UI clicks shouldn't queue)
##   Music   2 voices (A/B for crossfade between tracks)
##   Ambience 2 voices (A/B for biome crossfade)
##
## Volume model: slider 0..100 → linear_to_db(value/100). 100 = 0dB, 50 ≈ -6dB,
## 0 = -INF (muted). Persisted to user://audio.cfg via ConfigFile.

# ── Bus names + indices ──────────────────────────────────────────────────────
const BUS_MASTER   := "Master"
const BUS_MUSIC    := "Music"
const BUS_SFX      := "SFX"
const BUS_AMBIENCE := "Ambience"

const _CONFIG_PATH := "user://audio.cfg"
const _CONFIG_SECTION := "volumes"

# ── Sound catalog (IDs only — streams registered after generation) ───────────
# These IDs are the public contract. Triggers reference these names; the
# procedural-audio pass populates _streams[id] with AudioStreamWAV instances.

const SFX_IDS := [
	# Combat
	"sword_swing", "bow_release", "spell_cast",
	"melee_hit", "magic_hit", "arrow_impact",
	# Gathering
	"mining_hit", "wood_chop", "fishing_cast", "fishing_catch",
	# Footsteps
	"footstep_grass", "footstep_stone", "footstep_wood", "footstep_dirt",
]
const UI_IDS := [
	"click", "tab_switch", "quest_complete", "level_up",
	"item_pickup", "craft_success",
]
const AMBIENCE_IDS := ["ocean", "wind", "forest", "cave"]
const MUSIC_IDS    := ["town", "wilderness", "combat"]

# ── Pool sizes ───────────────────────────────────────────────────────────────
const POOL_SFX := 6
const POOL_UI  := 4
const POOL_MUSIC_BANK    := 2  # A/B for crossfade
const POOL_AMBIENCE_BANK := 2

# ── State ────────────────────────────────────────────────────────────────────
var _streams: Dictionary = {}            # id (String) → AudioStream
var _sfx_pool: Array[AudioStreamPlayer] = []
var _ui_pool: Array[AudioStreamPlayer] = []
var _music_pool: Array[AudioStreamPlayer] = []
var _ambience_pool: Array[AudioStreamPlayer] = []
var _sfx_idx: int = 0
var _ui_idx: int = 0
var _music_active: int = 0   # which music_pool slot is currently audible
var _amb_active: int = 0     # which ambience_pool slot is currently audible

var _volumes: Dictionary = {                 # bus name → 0..100
	BUS_MASTER:   80,
	BUS_MUSIC:    60,
	BUS_SFX:      80,
	BUS_AMBIENCE: 50,
}

# Footstep gating — Player.gd ticks play_footstep() every 4 movement frames;
# this is a backstop cooldown so a runaway caller can't queue rapid-fire steps.
var _footstep_cooldown: float = 0.0
const _FOOTSTEP_INTERVAL := 0.20
var _footstep_left: bool = true

# Track the currently-playing music + ambience track for skip-if-same checks.
var _current_music_id: String = ""
var _current_ambience_id: String = ""

# Biome poll — switches music (town/wilderness) and ambience based on the
# player's current tile. Music (mode + intensity + phrases) is owned by
# NorseMusic.gd; this poll only feeds the Ambience layer.
var _biome_poll_t: float = 0.0
const _BIOME_POLL_INTERVAL := 1.0
var _player_node: Node2D = null
var _ground_node: Node = null

# ── Lifecycle ────────────────────────────────────────────────────────────────
func _ready() -> void:
	_ensure_buses()
	_build_pools()
	_load_volumes()
	_apply_all_volumes()
	# Generation pass — currently a no-op. The procedural-audio pass will
	# populate _streams[id] with AudioStreamWAV instances inside these.
	_generate_sfx_sounds()
	_generate_ui_sounds()
	_generate_ambience_sounds()
	_generate_music_sounds()
	# Hook the signal bus so feature code doesn't need to know about audio.
	_wire_signal_bus()

func _process(delta: float) -> void:
	if _footstep_cooldown > 0.0:
		_footstep_cooldown -= delta
	_biome_poll_t += delta
	if _biome_poll_t >= _BIOME_POLL_INTERVAL:
		_biome_poll_t = 0.0
		_poll_biome_for_music_and_ambience()

# Biome-driven ambience poll. Music is now owned by NorseMusic.gd — this
# function ONLY handles the ambience layer (ocean/wind/forest/cave). The
# spec says "Existing Ambience Should Stay Dominant" so the ambience system
# stays here, unchanged, and plays UNDER whatever NorseMusic is rendering.
func _poll_biome_for_music_and_ambience() -> void:
	if _player_node == null or not is_instance_valid(_player_node):
		_player_node = get_tree().get_first_node_in_group("player") as Node2D
	if _ground_node == null or not is_instance_valid(_ground_node):
		_ground_node = get_tree().get_first_node_in_group("ground")
	if _player_node == null or _ground_node == null:
		return
	var biome: String = _ground_node.call("biome_at_world", _player_node.global_position) as String
	var amb := _ambience_id_for_biome(biome)
	if amb != "":
		play_ambience(amb)
	else:
		stop_ambience()

func _ambience_id_for_biome(biome: String) -> String:
	match biome:
		"coast", "ocean":
			return "ocean"
		"oak_forest", "pine_forest", "swamp":
			return "forest"
		"mountain", "cliff", "rocky":
			return "cave"
		"plains", "snow", "dark_forest":
			return "wind"
	return "wind"

# ── Bus setup ────────────────────────────────────────────────────────────────
func _ensure_buses() -> void:
	# Master is always index 0. Create the rest if missing (project_settings
	# default audio bus layout has only Master).
	_ensure_bus(BUS_MUSIC)
	_ensure_bus(BUS_SFX)
	_ensure_bus(BUS_AMBIENCE)

func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, BUS_MASTER)

# ── Pool setup ───────────────────────────────────────────────────────────────
func _build_pools() -> void:
	for i: int in range(POOL_SFX):
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		add_child(p)
		_sfx_pool.append(p)
	for i: int in range(POOL_UI):
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX           # UI rides the SFX bus — one slider covers both
		add_child(p)
		_ui_pool.append(p)
	for i: int in range(POOL_MUSIC_BANK):
		var p := AudioStreamPlayer.new()
		p.bus = BUS_MUSIC
		add_child(p)
		_music_pool.append(p)
	for i: int in range(POOL_AMBIENCE_BANK):
		var p := AudioStreamPlayer.new()
		p.bus = BUS_AMBIENCE
		add_child(p)
		_ambience_pool.append(p)

# ── Volume control ───────────────────────────────────────────────────────────
func set_bus_volume(bus_name: String, value: int) -> void:
	value = clampi(value, 0, 100)
	_volumes[bus_name] = value
	_apply_volume(bus_name)
	_save_volumes()

func get_bus_volume(bus_name: String) -> int:
	return int(_volumes.get(bus_name, 80))

func _apply_volume(bus_name: String) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	var v: int = int(_volumes.get(bus_name, 80))
	if v <= 0:
		AudioServer.set_bus_mute(idx, true)
		return
	AudioServer.set_bus_mute(idx, false)
	AudioServer.set_bus_volume_db(idx, linear_to_db(float(v) / 100.0))

func _apply_all_volumes() -> void:
	for bus_name: String in [BUS_MASTER, BUS_MUSIC, BUS_SFX, BUS_AMBIENCE]:
		_apply_volume(bus_name)

func _save_volumes() -> void:
	var cfg := ConfigFile.new()
	for bus_name: String in [BUS_MASTER, BUS_MUSIC, BUS_SFX, BUS_AMBIENCE]:
		cfg.set_value(_CONFIG_SECTION, bus_name, int(_volumes.get(bus_name, 80)))
	# Save errors are non-fatal — at worst the user has to re-set their volume.
	var _e := cfg.save(_CONFIG_PATH)

func _load_volumes() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_CONFIG_PATH) != OK:
		return
	for bus_name: String in [BUS_MASTER, BUS_MUSIC, BUS_SFX, BUS_AMBIENCE]:
		if cfg.has_section_key(_CONFIG_SECTION, bus_name):
			_volumes[bus_name] = int(cfg.get_value(_CONFIG_SECTION, bus_name, 80))

# ── Sound registration ───────────────────────────────────────────────────────
## Called by the procedural-audio pass to register a generated stream against
## a known catalog ID. Safe to call after _ready (e.g. to swap a placeholder).
func register_sound(id: String, stream: AudioStream) -> void:
	if id.is_empty() or stream == null:
		return
	_streams[id] = stream

func has_sound(id: String) -> bool:
	return _streams.has(id)

# ── Playback API ─────────────────────────────────────────────────────────────
## Plays a one-shot SFX (combat, gathering, footstep). Polyphonic via the
## round-robin pool. Optional pitch variance (±range, in semitones) for
## natural variation on repeated triggers.
func play_sfx(id: String, pitch_var: float = 0.0, vol_db: float = 0.0) -> void:
	if not _streams.has(id) or _sfx_pool.is_empty():
		return
	var p: AudioStreamPlayer = _sfx_pool[_sfx_idx]
	_sfx_idx = (_sfx_idx + 1) % _sfx_pool.size()
	p.stream = _streams[id]
	p.pitch_scale = 1.0 if pitch_var <= 0.0 else _rand_pitch(pitch_var)
	p.volume_db = vol_db
	p.play()

## Plays a UI sound — separate pool from SFX so a busy combat moment doesn't
## evict the click sound mid-press.
func play_ui(id: String) -> void:
	if not _streams.has(id) or _ui_pool.is_empty():
		return
	var p: AudioStreamPlayer = _ui_pool[_ui_idx]
	_ui_idx = (_ui_idx + 1) % _ui_pool.size()
	p.stream = _streams[id]
	p.pitch_scale = 1.0
	p.volume_db = 0.0
	p.play()

## Footstep — call from the player's movement code each frame they're moving;
## this rate-limits internally to a natural walk cadence and alternates feet
## via tiny pitch variation so the steps don't feel mechanical.
func play_footstep(biome: String) -> void:
	if _footstep_cooldown > 0.0:
		return
	_footstep_cooldown = _FOOTSTEP_INTERVAL
	var id := _footstep_id_for_biome(biome)
	# Subtle pitch shift between L/R feet to soften repetition.
	var pitch := 0.97 if _footstep_left else 1.03
	_footstep_left = not _footstep_left
	if not _streams.has(id):
		return
	var p: AudioStreamPlayer = _sfx_pool[_sfx_idx]
	_sfx_idx = (_sfx_idx + 1) % _sfx_pool.size()
	p.stream = _streams[id]
	p.pitch_scale = pitch
	p.volume_db = -4.0
	p.play()

func _footstep_id_for_biome(biome: String) -> String:
	match biome:
		"snow", "plains", "oak_forest", "pine_forest", "swamp":
			return "footstep_grass"
		"mountain", "cliff", "rocky":
			return "footstep_stone"
		"town", "road":
			return "footstep_wood"
		"coast", "ocean":
			return "footstep_dirt"
	return "footstep_dirt"

## Music — crossfades between two banked players when the track changes.
## fade_seconds 0 = instant cut.
func play_music(id: String, fade_seconds: float = 1.5) -> void:
	if id == _current_music_id:
		return
	_current_music_id = id
	if not _streams.has(id) or _music_pool.is_empty():
		return
	_crossfade_pool(_music_pool, id, fade_seconds, false)
	_music_active = 1 - _music_active

func stop_music(fade_seconds: float = 1.0) -> void:
	_current_music_id = ""
	for p: AudioStreamPlayer in _music_pool:
		_fade_out_stop(p, fade_seconds)

## Ambience — same pattern as music. Biome change crossfades.
func play_ambience(id: String, fade_seconds: float = 2.0) -> void:
	if id == _current_ambience_id:
		return
	_current_ambience_id = id
	if not _streams.has(id) or _ambience_pool.is_empty():
		return
	_crossfade_pool(_ambience_pool, id, fade_seconds, true)
	_amb_active = 1 - _amb_active

func stop_ambience(fade_seconds: float = 1.5) -> void:
	_current_ambience_id = ""
	for p: AudioStreamPlayer in _ambience_pool:
		_fade_out_stop(p, fade_seconds)

# ── Internals ────────────────────────────────────────────────────────────────
func _crossfade_pool(pool: Array[AudioStreamPlayer], id: String,
		fade_seconds: float, _is_ambience: bool) -> void:
	# Whichever slot is currently silent (or paused) becomes the new track.
	# The other fades out. With only two slots this means we keep at most one
	# old track audible while the new one ramps in.
	var current_slot: int = _music_active if pool == _music_pool else _amb_active
	var new_slot: int = 1 - current_slot
	var fresh: AudioStreamPlayer = pool[new_slot]
	var stale: AudioStreamPlayer = pool[current_slot]
	fresh.stream = _streams[id]
	fresh.volume_db = -60.0
	fresh.play()
	_fade_in(fresh, 0.0, fade_seconds)
	if stale.playing:
		_fade_out_stop(stale, fade_seconds)

func _fade_in(p: AudioStreamPlayer, target_db: float, seconds: float) -> void:
	if seconds <= 0.0:
		p.volume_db = target_db
		return
	var tween := create_tween()
	tween.tween_property(p, "volume_db", target_db, seconds)

func _fade_out_stop(p: AudioStreamPlayer, seconds: float) -> void:
	if not p.playing:
		return
	if seconds <= 0.0:
		p.stop()
		return
	var tween := create_tween()
	tween.tween_property(p, "volume_db", -60.0, seconds)
	tween.tween_callback(Callable(p, "stop"))

func _rand_pitch(semitones: float) -> float:
	var jitter := randf_range(-semitones, semitones)
	return pow(2.0, jitter / 12.0)

# ── Signal-bus integration ───────────────────────────────────────────────────
## Wired in _ready so feature code does NOT need to know AudioManager exists.
## Each handler is a one-line trigger; volume / variance lives here, not at
## the call site. Footsteps are an exception — the player's movement code
## must call play_footstep() per-frame because we don't have a global
## "player moved a tile" signal.
func _wire_signal_bus() -> void:
	Events.node_hit.connect(_on_node_hit)
	Events.inventory_changed.connect(_on_inventory_changed)
	Events.xp_gained.connect(_on_xp_gained)
	Events.quest_state_changed.connect(_on_quest_state_changed)
	Events.monster_killed.connect(_on_monster_killed)
	# open_combat / combat_ended music is owned by NorseMusic.gd now.
	Events.level_up.connect(_on_level_up)
	Events.quest_completed.connect(_on_quest_completed)
	Events.attack_swung.connect(_on_attack_swung)
	Events.attack_landed.connect(_on_attack_landed)
	Events.monster_attack_landed.connect(_on_monster_attack_landed)

func _on_level_up(_skill: String, _new_level: int) -> void:
	play_ui("level_up")

func _on_quest_completed(_quest_id: String) -> void:
	play_ui("quest_complete")

func _on_attack_swung(style: String) -> void:
	# Small pitch variance per swing so back-to-back combat doesn't sound
	# mechanically identical.
	match style:
		"melee":  play_sfx("sword_swing", 0.6)
		"ranged": play_sfx("bow_release", 0.4)
		"magic":  play_sfx("spell_cast",  0.3)

func _on_attack_landed(style: String) -> void:
	match style:
		"melee":  play_sfx("melee_hit",    0.5)
		"ranged": play_sfx("arrow_impact", 0.5)
		"magic":  play_sfx("magic_hit",    0.4)

# Down-pitched melee_hit so the player can hear who's hitting whom.
# Random pitch in [0.65, 0.80] — clearly below the player's swing range.
func _on_monster_attack_landed() -> void:
	if not _streams.has("melee_hit") or _sfx_pool.is_empty():
		return
	var p: AudioStreamPlayer = _sfx_pool[_sfx_idx]
	_sfx_idx = (_sfx_idx + 1) % _sfx_pool.size()
	p.stream = _streams["melee_hit"]
	p.pitch_scale = randf_range(0.65, 0.80)
	p.volume_db = -1.0
	p.play()

# Gathering hit — node_hit fires once per swing on a rock/tree/fish node.
# The interactable's `type_str` determines which sound to play.
func _on_node_hit(node: Node, _hp_remaining: int) -> void:
	if node == null:
		return
	var t: String = String(node.get("interactable_type_str")) if node.get("interactable_type_str") != null else ""
	match t:
		"rock":         play_sfx("mining_hit", 0.5)
		"tree":         play_sfx("wood_chop", 0.5)
		"fish":         play_sfx("fishing_cast", 0.3)

# Inventory change — used as a proxy for item pickup. Coarser than ideal
# (also fires on equip/sell), but the existing signal bus offers nothing
# more specific. UI sound stays subtle to forgive over-triggering.
func _on_inventory_changed() -> void:
	play_ui("item_pickup")

func _on_xp_gained(_skill: String, _amount: int) -> void:
	pass  # Level-up detection happens in GameManager; it can call play_ui("level_up").

func _on_quest_state_changed() -> void:
	# Conservative: the signal also fires on quest acceptance / progress.
	# Until we add a dedicated quest_completed signal, leave silent.
	pass

func _on_monster_killed(_monster_type: String) -> void:
	pass

# NOTE: Combat / biome / mode music handling moved to NorseMusic.gd.
# AudioManager retains only the SFX, UI, and Ambience layers; music is now
# fully owned by the Norse director. The play_music / stop_music API on
# this class is left in place as a no-op for any legacy caller — there
# should be none after the cutover, but keeping the surface stable avoids
# regressions if any test or admin tool calls it directly.

# ── Procedural generation stubs ──────────────────────────────────────────────
## Each generation pass calls SoundForge and registers the result by ID.
## Total startup cost: ≈ 1-2 seconds of GDScript loop work in dev builds —
## acceptable for a single boot, called once from _ready.

const _SoundForge = preload("res://scripts/autoloads/audio/SoundForge.gd")

func _generate_sfx_sounds() -> void:
	# Combat
	register_sound("sword_swing",    _SoundForge.gen_sword_swing())
	register_sound("bow_release",    _SoundForge.gen_bow_release())
	register_sound("spell_cast",     _SoundForge.gen_spell_cast())
	register_sound("melee_hit",      _SoundForge.gen_melee_hit())
	register_sound("magic_hit",      _SoundForge.gen_magic_hit())
	register_sound("arrow_impact",   _SoundForge.gen_arrow_impact())
	# Gathering
	register_sound("mining_hit",     _SoundForge.gen_mining_hit())
	register_sound("wood_chop",      _SoundForge.gen_wood_chop())
	register_sound("fishing_cast",   _SoundForge.gen_fishing_cast())
	register_sound("fishing_catch",  _SoundForge.gen_fishing_catch())
	# Footsteps
	register_sound("footstep_grass", _SoundForge.gen_footstep_grass())
	register_sound("footstep_stone", _SoundForge.gen_footstep_stone())
	register_sound("footstep_wood",  _SoundForge.gen_footstep_wood())
	register_sound("footstep_dirt",  _SoundForge.gen_footstep_dirt())

func _generate_ui_sounds() -> void:
	register_sound("click",          _SoundForge.gen_ui_click())
	register_sound("tab_switch",     _SoundForge.gen_ui_tab_switch())
	register_sound("quest_complete", _SoundForge.gen_quest_complete())
	register_sound("level_up",       _SoundForge.gen_level_up())
	register_sound("item_pickup",    _SoundForge.gen_item_pickup())
	register_sound("craft_success",  _SoundForge.gen_craft_success())

func _generate_ambience_sounds() -> void:
	register_sound("ocean",  _SoundForge.gen_amb_ocean())
	register_sound("wind",   _SoundForge.gen_amb_wind())
	register_sound("forest", _SoundForge.gen_amb_forest())
	register_sound("cave",   _SoundForge.gen_amb_cave())

func _generate_music_sounds() -> void:
	# Empty by design — NorseMusic.gd owns all music generation now (its
	# own _ready() pre-renders drones, phrase banks, and percussion loops).
	# The old town / wilderness / combat one-shots in SoundForge are no
	# longer referenced and would only burn ~3-5 s of startup time.
	pass
