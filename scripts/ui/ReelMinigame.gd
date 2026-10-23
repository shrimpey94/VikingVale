extends CanvasLayer

## Fishing reel duel — QTE version (1.6.3). Modal pop-up for a single hooked
## fish. Spawn shape (unchanged):
##
##   var rm := preload("res://scripts/ui/ReelMinigame.gd").new()
##   rm.setup(catch_dict)
##   get_tree().current_scene.add_child(rm)
##
## Loop: timed PROMPTS appear one at a time — a key (SPACE / W / A / S / D) over
## a sweeping timing bar with a green sweet-spot. Press the shown key while the
## marker is in the green to REEL (drain the fish's stamina); nail the centre for
## a PERFECT (bonus + eases tension). Wrong key, mistimed, or a let-the-marker-run-
## out miss SPIKES line tension. Tension maxes → line snaps (lose). Fish stamina
## hits 0 → catch lands (win). Emits `reel_minigame_ended(catch, success)`.
##
## Difficulty scales with the catch's `min_lv`: more stamina (more prompts), a
## faster marker, and a narrower sweet-spot. Tune in the constants block.

const UITheme = preload("res://scripts/ui/UITheme.gd")

const MAX_TENSION      := 100.0
const BASE_STAMINA     := 60.0
const STAMINA_PER_MIN_LV := 1.2
const HIT_DMG          := 12.0   # stamina drained on a good hit
const PERFECT_BONUS    := 8.0    # extra stamina drained on a centre hit
const MISS_TENSION     := 18.0   # tension gained on a miss
const PERFECT_RELIEF   := 7.0    # tension eased on a perfect hit
const TENSION_DECAY    := 6.0    # tension bleeds off per second
const STAMINA_RECOVER  := 2.0    # fish recovers slowly per second (pressure)
const GAP_SECS         := 0.30   # pause between prompts
const OUTRO_SECS       := 1.0
const PROMPT_KEYS: Array = [KEY_SPACE, KEY_W, KEY_A, KEY_S, KEY_D]

var _catch:       Dictionary = {}
var _max_stamina: float = BASE_STAMINA
var _stamina:     float = BASE_STAMINA
var _tension:     float = 0.0
var _done:        bool = false

# Difficulty-scaled per catch.
var _marker_speed: float = 1.1   # bar-lengths per second
var _zone_w:       float = 0.28  # green sweet-spot width (fraction of bar)

# Active-prompt state.
var _prompt_active: bool = false
var _prompt_key:    int = KEY_SPACE
var _marker:        float = 0.0   # 0..1 across the timing bar
var _zone_lo:       float = 0.0
var _gap_timer:     float = 0.4

var _feedback:   String = ""
var _feedback_c: Color = Color.WHITE
var _feedback_t: float = 0.0
var _shake:      float = 0.0   # panel-shake timer (juice on a miss/snap)

var _panel:       PanelContainer = null
var _panel_home:  Vector2 = Vector2.ZERO
var _tension_bar: ProgressBar = null
var _stamina_bar: ProgressBar = null
var _key_lbl:     Label = null
var _timing:      Control = null
var _feedback_lbl: Label = null
var _status_lbl:  Label = null

func setup(catch: Dictionary) -> void:
	_catch = catch
	var min_lv := int(catch.get("min_lv", 1))
	_max_stamina = BASE_STAMINA + float(min_lv) * STAMINA_PER_MIN_LV
	_stamina = _max_stamina
	var t := clampf(float(min_lv) / 95.0, 0.0, 1.0)
	_marker_speed = lerpf(0.9, 1.9, t)   # faster sweep for deeper fish
	_zone_w = lerpf(0.30, 0.13, t)       # narrower sweet-spot for deeper fish

func _ready() -> void:
	layer = 240
	_build_ui()
	set_process(true)
	set_process_input(true)
	_gap_timer = 0.5   # a beat before the first prompt

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.color = Color(0, 0, 0, 0.35)
	add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.GOLD, 3))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(380, 0)
	panel.position = Vector2(-190, -140)
	bg.add_child(panel)
	_panel = panel
	_panel_home = panel.position

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "⚓  Reeling — %s" % str(_catch.get("name", "fish"))
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	vb.add_child(_mk_label("Line tension", UITheme.DIM, 11))
	_tension_bar = _mk_bar(MAX_TENSION, 0.0, Color(0.85, 0.20, 0.10), true)
	vb.add_child(_tension_bar)

	vb.add_child(_mk_label("Fish stamina", UITheme.DIM, 11))
	_stamina_bar = _mk_bar(_max_stamina, _max_stamina, Color(0.20, 0.55, 0.90), false)
	vb.add_child(_stamina_bar)

	# Prompt: the key to press + the sweeping timing bar.
	_key_lbl = Label.new()
	_key_lbl.text = "get ready…"
	_key_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	_key_lbl.add_theme_font_size_override("font_size", 22)
	_key_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_key_lbl)

	_timing = Control.new()
	_timing.custom_minimum_size = Vector2(340, 24)
	_timing.draw.connect(_draw_timing)
	vb.add_child(_timing)

	_feedback_lbl = Label.new()
	_feedback_lbl.text = ""
	_feedback_lbl.add_theme_font_size_override("font_size", 14)
	_feedback_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_feedback_lbl)

	var hint := _mk_label("Press the key while the marker is in the GREEN. Centre = PERFECT.",
		UITheme.DIM, 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)

	_status_lbl = Label.new()
	_status_lbl.add_theme_color_override("font_color", UITheme.GOLD)
	_status_lbl.add_theme_font_size_override("font_size", 14)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_status_lbl)

func _mk_label(text: String, col: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	return l

func _mk_bar(maxv: float, val: float, fill: Color, pct: bool) -> ProgressBar:
	var b := ProgressBar.new()
	b.max_value = maxv
	b.value = val
	b.show_percentage = pct
	b.custom_minimum_size = Vector2(340, 18)
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(2)
	b.add_theme_stylebox_override("fill", sb)
	var bgs := StyleBoxFlat.new()
	bgs.bg_color = UITheme.BTN_N
	bgs.border_color = UITheme.BORDER
	bgs.set_border_width_all(1)
	b.add_theme_stylebox_override("background", bgs)
	return b

func _draw_timing() -> void:
	var w: float = _timing.size.x
	var h: float = _timing.size.y
	_timing.draw_rect(Rect2(0, 0, w, h), UITheme.BTN_N)
	_timing.draw_rect(Rect2(0, 0, w, h), UITheme.BORDER, false, 1.0)
	if not _prompt_active:
		return
	# Green sweet-spot; brighter centre = the PERFECT band.
	var zx := _zone_lo * w
	var zw := _zone_w * w
	_timing.draw_rect(Rect2(zx, 0, zw, h), Color(0.20, 0.65, 0.28))
	_timing.draw_rect(Rect2(zx + zw * 0.34, 0, zw * 0.32, h), Color(0.45, 0.95, 0.45))
	# Marker.
	var mx := _marker * w
	_timing.draw_rect(Rect2(mx - 2.0, -2.0, 4.0, h + 4.0), Color(1, 1, 1, 0.95))

func _spawn_prompt() -> void:
	_prompt_key = PROMPT_KEYS[randi() % PROMPT_KEYS.size()]
	_marker = 0.0
	_zone_lo = randf_range(0.12, 0.88 - _zone_w)
	_prompt_active = true
	if _key_lbl != null:
		_key_lbl.text = "▶  %s" % _key_name(_prompt_key)

func _key_name(kc: int) -> String:
	match kc:
		KEY_SPACE: return "SPACE"
		KEY_W: return "W"
		KEY_A: return "A"
		KEY_S: return "S"
		KEY_D: return "D"
	return "?"

func _input(event: InputEvent) -> void:
	if _done or not _prompt_active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc := (event as InputEventKey).keycode
		# LMB-friendly alias: treat a SPACE prompt as clickable too (below).
		if kc in PROMPT_KEYS:
			get_viewport().set_input_as_handled()
			if kc == _prompt_key:
				_resolve_press()
			else:
				_miss("Wrong key!")
	elif event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and _prompt_key == KEY_SPACE:
		get_viewport().set_input_as_handled()
		_resolve_press()

func _resolve_press() -> void:
	var lo := _zone_lo
	var hi := _zone_lo + _zone_w
	if _marker < lo or _marker > hi:
		_miss("Miss!")
		return
	# In the green — perfect if within the centre band.
	var c_lo := _zone_lo + _zone_w * 0.34
	var c_hi := _zone_lo + _zone_w * 0.66
	if _marker >= c_lo and _marker <= c_hi:
		_stamina -= HIT_DMG + PERFECT_BONUS
		_tension = maxf(0.0, _tension - PERFECT_RELIEF)
		_flash("PERFECT!", Color(0.45, 0.95, 0.45))
		AudioManager.play_ui("craft_success")
	else:
		_stamina -= HIT_DMG
		_flash("Reel!", Color(0.55, 0.85, 1.0))
		AudioManager.play_ui("click")
	_end_prompt()

func _miss(msg: String) -> void:
	_tension += MISS_TENSION
	_flash(msg, Color(0.95, 0.35, 0.30))
	AudioManager.play_sfx("melee_hit", 0.0, -4.0)   # a dull thud on a miss
	_shake = 0.28
	_end_prompt()

func _end_prompt() -> void:
	_prompt_active = false
	_gap_timer = GAP_SECS
	if _key_lbl != null:
		_key_lbl.text = ""

func _flash(text: String, col: Color) -> void:
	_feedback = text
	_feedback_c = col
	_feedback_t = 0.6

func _process(delta: float) -> void:
	if _done:
		return
	# Tension always bleeds; fish always recovers a little — so stalling loses.
	_tension = clampf(_tension - TENSION_DECAY * delta, 0.0, MAX_TENSION)
	_stamina = clampf(_stamina + STAMINA_RECOVER * delta, 0.0, _max_stamina)

	if _prompt_active:
		_marker += _marker_speed * delta
		if _marker >= 1.0:
			_miss("Too slow!")
	else:
		_gap_timer -= delta
		if _gap_timer <= 0.0:
			_spawn_prompt()

	if _feedback_t > 0.0:
		_feedback_t -= delta
		if _feedback_lbl != null:
			_feedback_lbl.text = _feedback
			var a := clampf(_feedback_t / 0.6, 0.0, 1.0)
			_feedback_lbl.add_theme_color_override("font_color",
				Color(_feedback_c.r, _feedback_c.g, _feedback_c.b, a))
	elif _feedback_lbl != null and _feedback_lbl.text != "":
		_feedback_lbl.text = ""

	if _tension_bar != null: _tension_bar.value = _tension
	if _stamina_bar != null: _stamina_bar.value = _stamina
	if _timing != null: _timing.queue_redraw()

	# Panel shake — a quick decaying jitter on a miss/snap for tactile feedback.
	if _panel != null:
		if _shake > 0.0:
			_shake = maxf(0.0, _shake - delta)
			var mag := _shake * 22.0
			_panel.position = _panel_home + Vector2(
				randf_range(-mag, mag), randf_range(-mag, mag))
		elif _panel.position != _panel_home:
			_panel.position = _panel_home

	if _tension >= MAX_TENSION:
		_end(false, "The line snapped!")
	elif _stamina <= 0.0:
		_end(true, "You landed it!")

func _end(success: bool, status: String) -> void:
	_done = true
	_prompt_active = false
	if success:
		AudioManager.play_sfx("fishing_catch")
	else:
		AudioManager.play_sfx("melee_hit", 0.0, -1.0)   # the line snaps
		_shake = 0.4
	if _key_lbl != null: _key_lbl.text = ""
	if _feedback_lbl != null: _feedback_lbl.text = ""
	if _status_lbl != null:
		_status_lbl.text = status
		_status_lbl.add_theme_color_override("font_color",
			Color(0.30, 0.85, 0.40) if success else Color(0.90, 0.30, 0.25))
	await get_tree().create_timer(OUTRO_SECS).timeout
	Events.reel_minigame_ended.emit(_catch, success)
	queue_free()
