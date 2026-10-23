extends Node

## Owner-only live MUSIC MIXER (autoload). Press F9 to toggle. Lets you balance
## the procedural music layers BY EAR in real time — drums vs bass/voices vs
## melody — without a game restart, plus re-roll ("Regenerate") the music and
## audition any mode. Sliders drive the audio sub-buses NorseMusic routes to.
##
## This is a tuning tool: everything it changes is live and non-destructive
## (bus volumes reset on restart; tune, note the numbers, then I bake them in).

# Slider label → audio bus name (NorseMusic._build_players creates the sub-buses).
const BUSES: Array = [
	["Master (all music)", "Music"],
	["Drone + Bass voices", "MusicDrone"],
	["Melody (flute/horn)", "MusicMelody"],
	["Drums", "MusicPerc"],
]
const MODES: Array = ["exploration", "village", "combat", "ritual", "dungeon"]

var _layer: CanvasLayer = null
var _mode_lbl: Label = null
var _refresh_t: float = 0.0

func _ready() -> void:
	set_process(true)
	_build()

func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 200
	add_child(_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(24, 130)
	panel.custom_minimum_size = Vector2(320, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.15, 0.94)
	sb.border_color = Color(0.85, 0.70, 0.25)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", sb)
	_layer.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "🎚  MUSIC MIXER   (F9)"
	title.add_theme_color_override("font_color", Color(0.95, 0.82, 0.30))
	vb.add_child(title)

	_mode_lbl = Label.new()
	_mode_lbl.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95))
	vb.add_child(_mode_lbl)

	for entry: Array in BUSES:
		vb.add_child(_slider_row(str(entry[0]), str(entry[1])))

	# Generative tuners — change the music itself; apply on Regenerate.
	vb.add_child(_tuner_row("Key (semitones)", -12.0, 12.0, 1.0, 0.0,
		func(v: float) -> void:
			var nm := _norse()
			if nm != null and nm.has_method("set_root_transpose"):
				nm.call("set_root_transpose", int(v))))
	vb.add_child(_tuner_row("Tempo (×)", 0.7, 1.4, 0.05, 1.0,
		func(v: float) -> void:
			var nm := _norse()
			if nm != null and nm.has_method("set_tempo_scale"):
				nm.call("set_tempo_scale", v)))
	var gh := Label.new()
	gh.text = "↑ Key & Tempo take effect on Regenerate ↓"
	gh.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	gh.add_theme_font_size_override("font_size", 10)
	vb.add_child(gh)

	var regen := Button.new()
	regen.text = "↻  Regenerate music (re-roll)"
	regen.pressed.connect(func() -> void:
		var nm := _norse()
		if nm != null:
			nm.call("regenerate")
		_refresh_mode())
	vb.add_child(regen)

	var mlabel := Label.new()
	mlabel.text = "Audition a mode:"
	mlabel.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	mlabel.add_theme_font_size_override("font_size", 11)
	vb.add_child(mlabel)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 3)
	for m: String in MODES:
		var b := Button.new()
		b.text = m.substr(0, 4).capitalize()
		b.tooltip_text = "Audition '%s' (~30s)" % m
		b.add_theme_font_size_override("font_size", 10)
		b.pressed.connect(func(mm: String = m) -> void:
			var nm := _norse()
			if nm != null:
				nm.call("force_mode", mm)
			_refresh_mode())
		mode_row.add_child(b)
	vb.add_child(mode_row)

	var hint := Label.new()
	hint.text = "Tune by ear, then tell me the numbers to bake in.\n(Levels reset on restart — this is a tuning tool.)"
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hint.add_theme_font_size_override("font_size", 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(300, 0)
	vb.add_child(hint)

	_layer.visible = false

func _slider_row(label: String, bus: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(140, 0)
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = -40.0
	s.max_value = 6.0
	s.step = 0.5
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var idx := AudioServer.get_bus_index(bus)
	s.value = AudioServer.get_bus_volume_db(idx) if idx != -1 else 0.0
	var val := Label.new()
	val.custom_minimum_size = Vector2(44, 0)
	val.text = "%.1f" % s.value
	s.value_changed.connect(func(v: float) -> void:
		var bi := AudioServer.get_bus_index(bus)
		if bi != -1:
			AudioServer.set_bus_volume_db(bi, v)
		val.text = "%.1f" % v)
	row.add_child(s)
	row.add_child(val)
	return row

## A generic labelled slider that calls `on_change(value)` live.
func _tuner_row(label: String, minv: float, maxv: float, step: float,
		cur: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(140, 0)
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = cur
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var val := Label.new()
	val.custom_minimum_size = Vector2(44, 0)
	val.text = ("%d" % int(cur)) if step >= 1.0 else ("%.2f" % cur)
	s.value_changed.connect(func(v: float) -> void:
		val.text = ("%d" % int(v)) if step >= 1.0 else ("%.2f" % v)
		on_change.call(v))
	row.add_child(s)
	row.add_child(val)
	return row

func _norse() -> Node:
	return get_node_or_null("/root/NorseMusic")

func _refresh_mode() -> void:
	var nm := _norse()
	if _mode_lbl != null and nm != null:
		var mode := str(nm.call("current_mode"))
		var txt := "Now playing: %s" % mode
		if mode == "exploration" and nm.has_method("current_verse"):
			txt += "\n   verse %d/%d" % [int(nm.call("current_verse")), int(nm.call("verse_count"))]
			if nm.has_method("current_drum"):
				txt += "   ·   drum %d/%d" % [int(nm.call("current_drum")), int(nm.call("drum_count"))]
		_mode_lbl.text = txt

func _process(delta: float) -> void:
	if _layer == null or not _layer.visible:
		return
	_refresh_t += delta
	if _refresh_t >= 0.5:
		_refresh_t = 0.0
		_refresh_mode()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F9:
		if not GameManager.is_full_admin():
			return
		_layer.visible = not _layer.visible
		if _layer.visible:
			_refresh_mode()
		get_viewport().set_input_as_handled()
