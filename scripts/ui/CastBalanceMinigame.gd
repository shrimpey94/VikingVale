extends CanvasLayer

## Phase 5 of the fishing rework (post-polish v2). Modal that runs the cast-
## balance duel for a single cast. Spawn shape:
##
##   var cb := preload("res://scripts/ui/CastBalanceMinigame.gd").new()
##   get_tree().current_scene.add_child(cb)   # reads fishing level from GameManager
##
## Lifecycle: input is captured by the modal. A needle drifts on a horizontal
## arc; drift gain ramps with elapsed time. SPACE/LMB hold pushes back toward
## center. A countdown timer (6-10s scaled by Fishing level) runs the cast.
##
## Five nested zones, center → edge:
##   GOLD    — rare fish (very narrow center band, ~2-5% of the arc)
##   TEAL    — upgraded catch tier
##   GREEN   — normal catch
##   ORANGE  — no catch (fish escapes, no penalty)
##   RED     — line snap (instant fail, ends the cast immediately)
##
## Outcomes (emitted via cast_minigame_ended(success, tier_bonus)):
##   needle hits RED at any time      → success=false, tier_bonus=0  (snap)
##   timer expires & needle in ORANGE → success=false, tier_bonus=0  (miss)
##   timer expires & needle in GREEN  → success=true,  tier_bonus=0  (normal)
##   timer expires & needle in TEAL   → success=true,  tier_bonus=1  (upgraded)
##   timer expires & needle in GOLD   → success=true,  tier_bonus=2  (rare)
##
## Player.gd uses tier_bonus to shift the catch-table index up so a TEAL/GOLD
## land yields a higher-tier fish than the player's level would normally allow.
##
## All tuning is in the constants block below.

const UITheme = preload("res://scripts/ui/UITheme.gd")

# ── Tuning ────────────────────────────────────────────────────────────────────
const NEEDLE_LIMIT   := PI * 0.50    # arc spans -90°..+90°
const RED_THRESHOLD  := PI * 0.46    # ~83° each side = instant snap

# Zone OUTER half-widths (each side). Bands: 0..gold..teal..green..RED..edge.
# Orange occupies the implicit band between `green_h` and `RED_THRESHOLD`, so
# there's no separate orange constant. All scale by Fishing level so higher
# levels grow the safe zones.
const GREEN_HALFWIDTH_LV0   := PI * 0.20    # ~36° at lv 0
const GREEN_HALFWIDTH_LV99  := PI * 0.28    # ~50° at lv 99
const TEAL_HALFWIDTH_LV0    := PI * 0.06    # ~11° at lv 0
const TEAL_HALFWIDTH_LV99   := PI * 0.10    # ~18° at lv 99
const GOLD_HALFWIDTH_LV0    := PI * 0.012   # ~2.2° (2.4% of full arc)
const GOLD_HALFWIDTH_LV99   := PI * 0.025   # ~4.5° (5% of full arc)

# Duration: lower at higher level (the player is faster / more skilled).
const DURATION_LV0   := 10.0
const DURATION_LV99  := 6.0

const DRIFT_BASE         := 0.8
const DRIFT_ACCEL_PER_S  := 0.06
const NOISE_AMPLITUDE    := 0.6
const CLICK_IMPULSE      := 2.4
const DAMPING_PER_SEC    := 0.55
const OUTRO_SECS         := 0.9
# ── /Tuning ───────────────────────────────────────────────────────────────────

var _angle:    float = 0.0
var _omega:    float = 0.0
var _elapsed:  float = 0.0
var _holding:  bool  = false
var _done:     bool  = false

# Per-level scaled zone half-widths and duration (computed once on _ready).
# Orange band is the implicit space between `_green_h` and `RED_THRESHOLD`,
# so no separate orange var.
var _gold_h:   float = GOLD_HALFWIDTH_LV0
var _teal_h:   float = TEAL_HALFWIDTH_LV0
var _green_h:  float = GREEN_HALFWIDTH_LV0
var _duration: float = DURATION_LV0

var _arc:           Control     = null
var _progress_bar:  ProgressBar = null
var _status_lbl:    Label       = null
var _hint_lbl:      Label       = null
var _rng:           RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	layer = 240
	_rng.randomize()
	var lv := GameManager.get_skill_level("fishing")
	var t := clampf(float(lv) / 99.0, 0.0, 1.0)
	_gold_h   = lerpf(GOLD_HALFWIDTH_LV0,   GOLD_HALFWIDTH_LV99,   t)
	_teal_h   = lerpf(TEAL_HALFWIDTH_LV0,   TEAL_HALFWIDTH_LV99,   t)
	_green_h  = lerpf(GREEN_HALFWIDTH_LV0,  GREEN_HALFWIDTH_LV99,  t)
	_duration = lerpf(DURATION_LV0,         DURATION_LV99,         t)
	_build_ui()
	set_process(true)
	set_process_input(true)

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.color = Color(0, 0, 0, 0.40)
	add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.sb(UITheme.BG, UITheme.GOLD, 3))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(440, 0)
	panel.position = Vector2(-220, -200)
	bg.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "⚓  Casting line — stay off red, aim for the gold center"
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	_arc = _ArcDisplay.new()
	_arc.custom_minimum_size = Vector2(420, 180)
	(_arc as Object).set("mg", self)
	vb.add_child(_arc)

	var p_label := Label.new()
	p_label.text = "Time remaining"
	p_label.add_theme_color_override("font_color", UITheme.DIM)
	p_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(p_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.max_value = _duration
	_progress_bar.value = _duration
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(420, 16)
	_progress_bar.add_theme_stylebox_override("fill",
		_bar_fill(Color(0.95, 0.80, 0.20)))
	_progress_bar.add_theme_stylebox_override("background", _bar_bg())
	vb.add_child(_progress_bar)

	_hint_lbl = Label.new()
	_hint_lbl.text = ("Hold SPACE or LMB to nudge the needle. Land gold → rare, " +
		"teal → upgraded, green → normal. Orange = miss, red = snap. (%.0fs cast)" % _duration)
	_hint_lbl.add_theme_color_override("font_color", UITheme.DIM)
	_hint_lbl.add_theme_font_size_override("font_size", 11)
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_lbl.custom_minimum_size = Vector2(420, 0)
	vb.add_child(_hint_lbl)

	_status_lbl = Label.new()
	_status_lbl.text = ""
	_status_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	_status_lbl.add_theme_font_size_override("font_size", 14)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_status_lbl)

func _bar_fill(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_top_left     = 2
	sb.corner_radius_top_right    = 2
	sb.corner_radius_bottom_left  = 2
	sb.corner_radius_bottom_right = 2
	return sb

func _bar_bg() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.BTN_N
	sb.border_color = UITheme.BORDER
	sb.set_border_width_all(1)
	return sb

func _input(event: InputEvent) -> void:
	if _done:
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_SPACE and not k.echo:
			_holding = k.pressed
			if k.pressed:
				_apply_click_impulse()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_holding = mb.pressed
			if mb.pressed:
				_apply_click_impulse()
			get_viewport().set_input_as_handled()

func _apply_click_impulse() -> void:
	var dir: float = -signf(_angle) if absf(_angle) > 0.01 else -0.5
	_omega += CLICK_IMPULSE * dir

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	var drift := DRIFT_BASE + _elapsed * DRIFT_ACCEL_PER_S
	_omega += sin(_angle) * drift * delta
	if _holding:
		var dir: float = -signf(_angle) if absf(_angle) > 0.01 else -0.5
		_omega += CLICK_IMPULSE * 0.5 * dir * delta * 4.0
	_omega += _rng.randf_range(-NOISE_AMPLITUDE, NOISE_AMPLITUDE) * delta
	_omega *= exp(-DAMPING_PER_SEC * delta)
	_angle += _omega * delta
	_angle = clampf(_angle, -NEEDLE_LIMIT, NEEDLE_LIMIT)

	# Countdown timer + bar.
	var time_left := maxf(0.0, _duration - _elapsed)
	if _progress_bar != null:
		_progress_bar.value = time_left

	if _arc != null:
		_arc.queue_redraw()

	# Red zone hit at any point → instant snap, ends cast immediately.
	if absf(_angle) >= RED_THRESHOLD:
		_end(false, 0, "The line snapped!")
		return
	# Timer expired → resolve outcome from final needle position.
	if time_left <= 0.0:
		_resolve_outcome()

func _resolve_outcome() -> void:
	var a := absf(_angle)
	if a <= _gold_h:
		_end(true, 2, "Rare catch!")
	elif a <= _teal_h:
		_end(true, 1, "Great cast! Upgraded catch!")
	elif a <= _green_h:
		_end(true, 0, "Cast set!")
	elif a <= RED_THRESHOLD:
		# Orange band — between green outer edge and red threshold.
		_end(false, 0, "Fish escaped…")
	else:
		# Shouldn't reach here — red triggers earlier — but defensive.
		_end(false, 0, "The line snapped!")

func _end(success: bool, tier_bonus: int, status: String) -> void:
	_done = true
	_holding = false
	if _status_lbl != null:
		_status_lbl.text = status
		var status_col: Color
		if tier_bonus >= 2:
			status_col = Color(1.00, 0.85, 0.20)   # gold
		elif tier_bonus == 1:
			status_col = Color(0.30, 0.85, 0.80)   # teal
		elif success:
			status_col = Color(0.30, 0.85, 0.40)   # green
		else:
			status_col = Color(0.90, 0.30, 0.25)   # red
		_status_lbl.add_theme_color_override("font_color", status_col)
	if _hint_lbl != null:
		_hint_lbl.text = ""
	await get_tree().create_timer(OUTRO_SECS).timeout
	Events.cast_minigame_ended.emit(success, tier_bonus)
	queue_free()

# ── Arc display (inner Control) ──────────────────────────────────────────────
class _ArcDisplay extends Control:
	var mg = null
	func _draw() -> void:
		if mg == null:
			return
		mg.call("_draw_arc", self)

func _draw_arc(ci: CanvasItem) -> void:
	var sz: Vector2 = (ci as Control).size
	var center := Vector2(sz.x * 0.5, sz.y * 0.95)
	var radius := minf(sz.x * 0.45, sz.y * 0.90)
	var thickness := 16.0

	# Backdrop arc (full range) — gives the speedometer a base ring.
	_draw_zone(ci, center, radius, -NEEDLE_LIMIT, NEEDLE_LIMIT,
		UITheme.BTN_N, thickness)

	# Zones drawn outer-to-inner. Each ring is split into a left half (negative
	# range) and a right half (positive range) — except gold, which is a single
	# band spanning the center.
	var c_red    := Color(0.85, 0.20, 0.18)
	var c_orange := Color(0.92, 0.55, 0.18)
	var c_green  := Color(0.25, 0.78, 0.35)
	var c_teal   := Color(0.20, 0.75, 0.78)
	var c_gold   := Color(1.00, 0.85, 0.20)

	# Red (outermost) — between RED_THRESHOLD and NEEDLE_LIMIT on each side.
	_draw_zone(ci, center, radius, -NEEDLE_LIMIT, -RED_THRESHOLD, c_red, thickness)
	_draw_zone(ci, center, radius,  RED_THRESHOLD, NEEDLE_LIMIT,  c_red, thickness)
	# Orange — between green's outer edge and red threshold.
	_draw_zone(ci, center, radius, -RED_THRESHOLD, -_green_h, c_orange, thickness)
	_draw_zone(ci, center, radius,  _green_h, RED_THRESHOLD,   c_orange, thickness)
	# Green — between teal edge and green edge.
	_draw_zone(ci, center, radius, -_green_h, -_teal_h, c_green, thickness)
	_draw_zone(ci, center, radius,  _teal_h, _green_h,  c_green, thickness)
	# Teal — between gold edge and teal edge.
	_draw_zone(ci, center, radius, -_teal_h, -_gold_h, c_teal, thickness)
	_draw_zone(ci, center, radius,  _gold_h, _teal_h,  c_teal, thickness)
	# Gold — single center band, narrow.
	_draw_zone(ci, center, radius, -_gold_h, _gold_h, c_gold, thickness)

	# Tick marks at zone boundaries.
	for a in [-RED_THRESHOLD, RED_THRESHOLD,
			  -_green_h, _green_h,
			  -_teal_h, _teal_h,
			  -_gold_h, _gold_h]:
		_draw_tick(ci, center, radius, a)

	# Needle.
	var danger := clampf(absf(_angle) / RED_THRESHOLD, 0.0, 1.0)
	var needle_col := Color(0.95, 0.95, 0.95).lerp(Color(0.95, 0.30, 0.20), danger)
	var tip := center + Vector2(sin(_angle) * radius, -cos(_angle) * radius)
	ci.draw_line(center, tip, needle_col, 3.0, true)
	ci.draw_circle(center, 4.0, UITheme.GOLD)

func _draw_zone(ci: CanvasItem, center: Vector2, radius: float,
		a0: float, a1: float, col: Color, thickness: float) -> void:
	# Godot's draw_arc uses standard math angles (0 = +x, positive = CCW).
	# We want 0 = up, +x = right (screen). Translate.
	var g0 := -PI * 0.5 + a0
	var g1 := -PI * 0.5 + a1
	if g1 < g0:
		var t := g0; g0 = g1; g1 = t
	var steps := maxi(8, int((g1 - g0) * 32.0))
	ci.draw_arc(center, radius, g0, g1, steps, col, thickness, true)

func _draw_tick(ci: CanvasItem, center: Vector2, radius: float, a: float) -> void:
	var outer := center + Vector2(sin(a) * (radius + 4.0), -cos(a) * (radius + 4.0))
	var inner := center + Vector2(sin(a) * (radius - 10.0), -cos(a) * (radius - 10.0))
	ci.draw_line(inner, outer, UITheme.GOLD.darkened(0.2), 2.0)
