extends CanvasLayer

## Skill-training mini-game (v1.6.6) — the interactive replacement for the old
## flat `add_xp(...,5)` training stations (Archery Range, Runestone, melee dummy).
## Modal pop-up. Spawn shape mirrors ReelMinigame:
##
##   var mg := preload("res://scripts/ui/SkillMinigame.gd").new()
##   mg.setup({"skill":"ranged", "level":42, "shots":5, "ammo_id":"arrows",
##             "theme":"archery", "station":"Archery Range"})
##   get_tree().current_scene.add_child(mg)
##
## Per shot: a two-press AIM — a sweeper oscillates horizontally (SPACE locks X),
## then vertically (SPACE locks Y); the arrow lands on the concentric TARGET and
## the ring under it scores 0..1 (bullseye = 1). A `shots`-shot volley sums the
## per-shot scores; XP = round(base_xp × sum). One `ammo_id` is spent per shot
## (skipped when ammo_id == ""); the volley ends early if you run out. On finish
## it emits `Events.skill_minigame_ended({skill, score, shots_fired, xp})`.
##
## The reward is pure PLAYER ACCURACY — `level` only grants a little aim-forgiveness
## so a high-level trainer isn't punished, but a bullseye volley always beats a
## sloppy one (the whole point: earn your XP).

const UITheme = preload("res://scripts/ui/UITheme.gd")

const DEFAULT_SHOTS   := 5
const BASE_XP         := 6.0    # per perfect shot → a 5-shot bullseye volley = ~30
const SWEEP_PERIOD    := 1.15   # seconds for one full 0→1→0 sweep
const OUTRO_SECS      := 1.2
const SHOT_GAP        := 0.45   # beat between shots (show where the last arrow hit)

# Ring thresholds (normalized radius from centre) → score. Outer→inner.
const RINGS: Array = [
	[0.10, 1.00], [0.25, 0.80], [0.45, 0.60], [0.65, 0.40], [0.85, 0.20],
]
const EDGE_SCORE := 0.05

# ── config ───────────────────────────────────────────────────────────────────
var _skill:   String = "ranged"
var _level:   int = 1
var _shots:   int = DEFAULT_SHOTS
var _ammo_id: String = ""
var _theme:   String = "archery"
var _station: String = "Training"

# ── run state ─────────────────────────────────────────────────────────────────
var _shot_index:  int = 0       # shots STARTED
var _shots_fired: int = 0       # shots that actually loosed (had ammo)
var _score_sum:   float = 0.0
var _phase:       int = 0       # 0=sweep X, 1=sweep Y, 2=resolved(gap), 3=done
var _sweep_t:     float = 0.0
var _aim_x:       float = 0.5
var _aim_y:       float = 0.5
var _hit_r:       float = -1.0  # last arrow's landed radius (for the draw)
var _gap:         float = 0.0
var _done:        bool = false

var _feedback:   String = ""
var _feedback_c: Color = Color.WHITE
var _feedback_t: float = 0.0

var _panel:    PanelContainer = null
var _target:   Control = null
var _prompt:   Label = null
var _status:   Label = null
var _feedback_lbl: Label = null

func setup(cfg: Dictionary) -> void:
	_skill   = str(cfg.get("skill", "ranged"))
	_level   = int(cfg.get("level", 1))
	_shots   = maxi(1, int(cfg.get("shots", DEFAULT_SHOTS)))
	_ammo_id = str(cfg.get("ammo_id", ""))
	_theme   = str(cfg.get("theme", "archery"))
	_station = str(cfg.get("station", "Training"))

func _ready() -> void:
	layer = 240
	_build_ui()
	set_process(true)
	set_process_input(true)
	_start_shot()

# ── UI ────────────────────────────────────────────────────────────────────────
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.color = Color(0, 0, 0, 0.35)
	add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, _accent(), 3))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(360, 0)
	panel.position = Vector2(-180, -210)
	bg.add_child(panel)
	_panel = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "%s  %s" % [_glyph(), _station]
	title.add_theme_color_override("font_color", _accent())
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	_target = Control.new()
	_target.custom_minimum_size = Vector2(300, 300)
	_target.draw.connect(_draw_target)
	vb.add_child(_target)

	_prompt = _mk_label("", _accent(), 18)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_prompt)

	_feedback_lbl = _mk_label("", Color.WHITE, 14)
	_feedback_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_feedback_lbl)

	var hint := _mk_label("SPACE locks the sweeping line. Two presses per shot — nail the centre.",
		UITheme.DIM, 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)

	_status = _mk_label("", _accent(), 13)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_status)

func _mk_label(text: String, col: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	return l

# ── shot flow ─────────────────────────────────────────────────────────────────
func _start_shot() -> void:
	if _shot_index >= _shots:
		_finish()
		return
	# Consume one unit of ammo up front; out of ammo ends the volley early.
	if _ammo_id != "":
		if GameManager.get_item_qty(_ammo_id) <= 0:
			_finish("Out of " + _ammo_id.replace("_", " ") + "!")
			return
		GameManager.remove_item_qty(_ammo_id, 1)
	_shot_index += 1
	_shots_fired += 1
	_phase = 0
	_sweep_t = 0.0
	_hit_r = -1.0
	_update_prompt()
	_update_status()

func _update_prompt() -> void:
	if _prompt == null:
		return
	match _phase:
		0: _prompt.text = "◀  aim  ▶     (SPACE)"
		1: _prompt.text = "▲  aim  ▼     (SPACE)"
		_: _prompt.text = ""

func _update_status() -> void:
	if _status != null:
		_status.text = "Shot %d / %d      score %.1f" % [_shot_index, _shots, _score_sum]

func _input(event: InputEvent) -> void:
	if _done or _phase >= 2:
		return
	var pressed := false
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_SPACE:
		pressed = true
	elif event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		pressed = true
	if not pressed:
		return
	get_viewport().set_input_as_handled()
	var val := _sweep_value()
	if _phase == 0:
		_aim_x = val
		_phase = 1
		_sweep_t = 0.0
		AudioManager.play_ui("click")
		_update_prompt()
	elif _phase == 1:
		_aim_y = val
		_resolve_shot()

func _sweep_value() -> float:
	# Ping-pong 0..1..0 so the centre (0.5) is the hard-to-hit sweet spot.
	var f := fmod(_sweep_t / SWEEP_PERIOD, 1.0)
	return 1.0 - absf(f * 2.0 - 1.0)   # triangle wave 0→1→0

func _resolve_shot() -> void:
	# A little aim-forgiveness at high level; the shot still lands on real accuracy.
	var spread := lerpf(0.06, 0.0, clampf(float(_level) / 99.0, 0.0, 1.0))
	var nx := (_aim_x - 0.5) * 2.0 + randf_range(-spread, spread)
	var ny := (_aim_y - 0.5) * 2.0 + randf_range(-spread, spread)
	var r := clampf(sqrt(nx * nx + ny * ny), 0.0, 1.2)
	_hit_r = r
	var score := EDGE_SCORE
	for ring: Array in RINGS:
		if r <= float(ring[0]):
			score = float(ring[1])
			break
	_score_sum += score
	if score >= 1.0:
		_flash("BULLSEYE!", Color(1.0, 0.85, 0.25)); AudioManager.play_ui("craft_success")
	elif score >= 0.6:
		_flash("Good hit!", Color(0.55, 0.85, 1.0)); _shoot_sfx()
	elif score >= 0.2:
		_flash("Grazed it", Color(0.80, 0.80, 0.55)); _shoot_sfx()
	else:
		_flash("Missed the mark", Color(0.90, 0.40, 0.30)); AudioManager.play_sfx("melee_hit", 0.0, -4.0)
	_phase = 2
	_gap = SHOT_GAP
	_update_status()

func _shoot_sfx() -> void:
	if _theme == "archery":
		AudioManager.play_sfx("bow_release", 0.3)
	else:
		AudioManager.play_ui("click")

func _flash(text: String, col: Color) -> void:
	_feedback = text
	_feedback_c = col
	_feedback_t = 0.7

func _finish(reason: String = "") -> void:
	if _done:
		return
	_done = true
	_phase = 3
	if _prompt != null: _prompt.text = ""
	var xp := int(round(BASE_XP * _score_sum))
	if _shots_fired > 0:
		xp = maxi(1, xp)
	if _status != null:
		var msg := reason if reason != "" else "Volley complete"
		_status.text = "%s   +%d %s xp" % [msg, xp, _skill]
	if _target != null: _target.queue_redraw()
	await get_tree().create_timer(OUTRO_SECS).timeout
	Events.skill_minigame_ended.emit({
		"skill": _skill, "score": _score_sum, "shots_fired": _shots_fired, "xp": xp,
	})
	queue_free()

func _process(delta: float) -> void:
	if _done:
		return
	if _phase <= 1:
		_sweep_t += delta
		if _target != null: _target.queue_redraw()
	elif _phase == 2:
		_gap -= delta
		if _gap <= 0.0:
			_start_shot()
			if _target != null: _target.queue_redraw()
	if _feedback_t > 0.0:
		_feedback_t -= delta
		if _feedback_lbl != null:
			var a := clampf(_feedback_t / 0.7, 0.0, 1.0)
			_feedback_lbl.text = _feedback
			_feedback_lbl.add_theme_color_override("font_color",
				Color(_feedback_c.r, _feedback_c.g, _feedback_c.b, a))
	elif _feedback_lbl != null and _feedback_lbl.text != "":
		_feedback_lbl.text = ""

# ── target draw ───────────────────────────────────────────────────────────────
func _draw_target() -> void:
	var sz: Vector2 = _target.size
	var c := sz * 0.5
	var rad: float = minf(sz.x, sz.y) * 0.48
	# Rings, outer → inner (thresholds are normalized radii).
	var pal := _palette()
	var prev := 1.0
	for i in range(RINGS.size() + 1):
		var thr: float = float(RINGS[i][0]) if i < RINGS.size() else 0.0
		var col: Color = pal[min(i, pal.size() - 1)]
		_target.draw_circle(c, prev * rad, col)
		prev = thr
	# The two sweeping aim lines.
	if _phase == 0:
		var x := (_sweep_value() * 2.0 - 1.0) * rad
		_target.draw_line(c + Vector2(x, -rad), c + Vector2(x, rad), Color(1, 1, 1, 0.95), 2.0)
	elif _phase == 1:
		var xl := (_aim_x * 2.0 - 1.0) * rad
		_target.draw_line(c + Vector2(xl, -rad), c + Vector2(xl, rad), Color(1, 1, 1, 0.55), 1.5)
		var y := (_sweep_value() * 2.0 - 1.0) * rad
		_target.draw_line(c + Vector2(-rad, y), c + Vector2(rad, y), Color(1, 1, 1, 0.95), 2.0)
	# Last arrow's landing point.
	if _hit_r >= 0.0:
		var hp := c + Vector2((_aim_x * 2.0 - 1.0) * rad, (_aim_y * 2.0 - 1.0) * rad)
		_target.draw_circle(hp, 4.0, Color(0.10, 0.10, 0.10))
		_target.draw_circle(hp, 2.5, Color(1.0, 0.95, 0.4))

# ── theming ───────────────────────────────────────────────────────────────────
func _accent() -> Color:
	match _theme:
		"rune":  return Color(0.58, 0.35, 0.92)
		"melee": return Color(0.85, 0.45, 0.25)
		_:       return UITheme.GOLD
func _glyph() -> String:
	match _theme:
		"rune":  return "🔮"
		"melee": return "⚔"
		_:       return "🏹"
func _palette() -> Array:
	# outer → inner ring colours (6 bands).
	match _theme:
		"rune":
			return [Color(0.14,0.10,0.20), Color(0.24,0.16,0.36), Color(0.36,0.22,0.54),
					Color(0.50,0.30,0.74), Color(0.66,0.42,0.92), Color(0.90,0.78,1.0)]
		"melee":
			return [Color(0.30,0.22,0.14), Color(0.42,0.30,0.18), Color(0.55,0.40,0.24),
					Color(0.68,0.24,0.18), Color(0.80,0.34,0.22), Color(0.95,0.85,0.35)]
		_:  # archery — classic target
			return [Color(0.96,0.96,0.96), Color(0.15,0.15,0.15), Color(0.20,0.45,0.85),
					Color(0.85,0.20,0.18), Color(1.0,0.82,0.20), Color(1.0,0.90,0.35)]
