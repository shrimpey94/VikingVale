extends VBoxContainer

## Settings tab — extracted from HUD.gd into scenes/ui/settings_panel.tscn.
## Self-contained: static keybind list, a volume slider, and a Log Out button
## that confirms then calls NetworkManager.logout directly.

const UITheme = preload("res://scripts/ui/UITheme.gd")

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build()

func _build() -> void:
	add_child(UITheme.title("Settings"))
	add_child(HSeparator.new())

	var binds: Array[Array] = [
		["WASD",         "Move character"],
		["Arrow Keys",   "Pan camera (free mode)"],
		["Scroll Wheel", "Zoom in / out"],
		["Left Click",   "Move / Interact"],
		["Right Click",  "Cancel action"],
		["E",            "Launch / dock boat"],
	]
	for b: Array in binds:
		var row := HBoxContainer.new()
		var key := Label.new()
		key.text = b[0]
		key.custom_minimum_size = Vector2(110, 0)
		key.add_theme_color_override("font_color", UITheme.GOLD)
		key.add_theme_font_size_override("font_size", 10)
		var act := Label.new()
		act.text = b[1]
		act.add_theme_color_override("font_color", UITheme.TEXT)
		act.add_theme_font_size_override("font_size", 10)
		row.add_child(key)
		row.add_child(act)
		add_child(row)

	add_child(HSeparator.new())
	var vol_header := Label.new()
	vol_header.text = "Volume"
	vol_header.add_theme_color_override("font_color", UITheme.GOLD)
	vol_header.add_theme_font_size_override("font_size", 11)
	add_child(vol_header)
	# Bus names match AudioManager.BUS_* constants. Using string literals
	# here lets the editor's static analyzer resolve before the autoload
	# loads; AudioManager looks them up at runtime by name anyway.
	_add_volume_slider("Master",   "Master")
	_add_volume_slider("Music",    "Music")
	_add_volume_slider("Effects",  "SFX")
	_add_volume_slider("Ambience", "Ambience")

	add_child(HSeparator.new())
	var logout_btn := Button.new()
	logout_btn.text = "Log Out"
	logout_btn.custom_minimum_size = Vector2(0, 32)
	logout_btn.add_theme_stylebox_override("normal",  UITheme.sb(Color(0.25, 0.05, 0.05), UITheme.BORDER, 2))
	logout_btn.add_theme_stylebox_override("hover",   UITheme.sb(Color(0.38, 0.08, 0.06), UITheme.GOLD, 2))
	logout_btn.add_theme_stylebox_override("pressed", UITheme.sb(Color(0.20, 0.04, 0.04), UITheme.GOLD, 2))
	logout_btn.add_theme_color_override("font_color", UITheme.TEXT)
	logout_btn.add_theme_font_size_override("font_size", 12)
	logout_btn.pressed.connect(_on_logout_pressed)
	add_child(logout_btn)

func _add_volume_slider(label_text: String, bus_name: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(70, 0)
	lbl.add_theme_color_override("font_color", UITheme.TEXT)
	lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = AudioManager.get_bus_volume(bus_name)
	slider.custom_minimum_size = Vector2(140, 20)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(v: float) -> void:
		AudioManager.set_bus_volume(bus_name, int(v)))
	row.add_child(slider)
	add_child(row)

func _on_logout_pressed() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Log Out"
	dlg.dialog_text = "Are you sure you want to log out?"
	dlg.ok_button_text = "Log Out"
	dlg.confirmed.connect(func() -> void:
		NetworkManager.logout()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()
