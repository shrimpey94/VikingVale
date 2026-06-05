extends CanvasLayer

## Phase 2 of the fishing rework. Modal pop-up that runs the reel duel for a
## single hooked fish. Spawn shape:
##
##   var rm := preload("res://scripts/ui/ReelMinigame.gd").new()
##   rm.setup(catch_dict)
##   get_tree().current_scene.add_child(rm)
##
## Lifecycle: input is captured for as long as the modal is alive. The player
## holds SPACE (or LMB) to reel — that drains the fish's stamina but builds
## line tension. Letting go lets tension fall (fast) and the fish recover
## stamina (slow). Reach max tension → line snaps, lose. Drain stamina to
## zero → catch lands, win. Either outcome emits `reel_minigame_ended` with
## the original catch dict + a success bool, then the panel self-frees.
##
## Stats scale with the catch's `min_lv` (deep-sea fish) so a silverfin is a
## quick reel and a kraken is a real fight. Tuning lives in the constants
## block below — adjust without touching flow logic.

const UITheme = preload("res://scripts/ui/UITheme.gd")

# Tuning constants. Picked so a constant-reel player snaps the line before
# draining stamina at any tier — must cycle reel/release. Adjust here, not
# in the loop body.
const MAX_TENSION             := 100.0
const REEL_STAMINA_PER_SEC    := 14.0   # fish HP drained while holding reel
const TENSION_RISE_PER_SEC    := 22.0   # tension gained while reeling
const TENSION_FALL_PER_SEC    := 34.0   # tension lost while easing
const STAMINA_RECOVER_PER_SEC := 4.0    # fish recovers while easing (slow)
const BASE_STAMINA            := 60.0
const STAMINA_PER_MIN_LV      := 1.2    # added per DEEP_FISH min_lv tier
const OUTRO_SECS              := 1.0    # show win/loss banner before closing

var _catch:       Dictionary  = {}
var _max_stamina: float       = BASE_STAMINA
var _stamina:     float       = BASE_STAMINA
var _tension:     float       = 0.0
var _reeling:    bool         = false
var _done:        bool        = false

var _tension_bar: ProgressBar = null
var _stamina_bar: ProgressBar = null
var _status_lbl:  Label       = null
var _hint_lbl:    Label       = null

## Call before adding to the tree. Sets the fish stats based on the catch.
func setup(catch: Dictionary) -> void:
	_catch = catch
	# Shoreline fish don't carry min_lv — default to BASE_STAMINA so they're
	# the easiest tier. Deep fish scale up: lv1 silverfin ≈ 61, lv95
	# leviathan_eye ≈ 174 → ~5s vs ~30s of optimal-cycle reel time.
	var min_lv := int(catch.get("min_lv", 1))
	_max_stamina = BASE_STAMINA + float(min_lv) * STAMINA_PER_MIN_LV
	_stamina = _max_stamina

func _ready() -> void:
	layer = 240
	_build_ui()
	set_process(true)
	set_process_input(true)

func _build_ui() -> void:
	# Full-viewport input-blocker + subtle dim so clicks outside the panel
	# don't fall through to the world (sailing / attacking) while the modal
	# is active. ColorRect has a `color` field, plain Control does not.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.color = Color(0, 0, 0, 0.35)
	add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		UITheme.sb(UITheme.BG, UITheme.GOLD, 3))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(360, 0)
	# Center the panel on screen. PRESET_CENTER pins the top-left at the
	# viewport center; offset by half the panel size after layout.
	panel.position = Vector2(-180, -120)
	bg.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "⚓  Reeling — %s" % str(_catch.get("name", "fish"))
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var t_label := Label.new()
	t_label.text = "Line tension"
	t_label.add_theme_color_override("font_color", UITheme.DIM)
	t_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(t_label)

	_tension_bar = ProgressBar.new()
	_tension_bar.max_value = MAX_TENSION
	_tension_bar.value = 0.0
	_tension_bar.show_percentage = true
	_tension_bar.custom_minimum_size = Vector2(340, 18)
	_tension_bar.add_theme_stylebox_override("fill",
		_bar_fill(Color(0.85, 0.20, 0.10)))   # tension = danger = red
	_tension_bar.add_theme_stylebox_override("background",
		_bar_bg())
	vb.add_child(_tension_bar)

	var s_label := Label.new()
	s_label.text = "Fish stamina"
	s_label.add_theme_color_override("font_color", UITheme.DIM)
	s_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(s_label)

	_stamina_bar = ProgressBar.new()
	_stamina_bar.max_value = _max_stamina
	_stamina_bar.value = _max_stamina
	_stamina_bar.show_percentage = false
	_stamina_bar.custom_minimum_size = Vector2(340, 18)
	_stamina_bar.add_theme_stylebox_override("fill",
		_bar_fill(Color(0.20, 0.55, 0.90)))   # stamina = water = blue
	_stamina_bar.add_theme_stylebox_override("background",
		_bar_bg())
	vb.add_child(_stamina_bar)

	_hint_lbl = Label.new()
	_hint_lbl.text = "Hold  SPACE  or  LMB  to reel.  Release to ease tension."
	_hint_lbl.add_theme_color_override("font_color", UITheme.DIM)
	_hint_lbl.add_theme_font_size_override("font_size", 11)
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
			_reeling = k.pressed
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_reeling = mb.pressed
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if _done:
		return
	if _reeling:
		_stamina -= REEL_STAMINA_PER_SEC * delta
		_tension += TENSION_RISE_PER_SEC * delta
	else:
		_tension -= TENSION_FALL_PER_SEC * delta
		_stamina += STAMINA_RECOVER_PER_SEC * delta
	_tension = clampf(_tension, 0.0, MAX_TENSION)
	_stamina = clampf(_stamina, 0.0, _max_stamina)
	if _tension_bar != null: _tension_bar.value = _tension
	if _stamina_bar != null: _stamina_bar.value = _stamina

	if _tension >= MAX_TENSION:
		_end(false, "The line snapped!")
	elif _stamina <= 0.0:
		_end(true, "You landed it!")

func _end(success: bool, status: String) -> void:
	_done = true
	_reeling = false
	if _status_lbl != null:
		_status_lbl.text = status
		_status_lbl.add_theme_color_override("font_color",
			Color(0.30, 0.85, 0.40) if success else Color(0.90, 0.30, 0.25))
	if _hint_lbl != null:
		_hint_lbl.text = ""
	# Brief outro so the player sees the result before the panel disappears.
	await get_tree().create_timer(OUTRO_SECS).timeout
	Events.reel_minigame_ended.emit(_catch, success)
	queue_free()
