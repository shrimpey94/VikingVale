extends VBoxContainer

## Settings tab — extracted from HUD.gd into scenes/ui/settings_panel.tscn.
## Self-contained: static keybind list, a volume slider, and a Log Out button
## that confirms then calls NetworkManager.logout directly.

const UITheme = preload("res://scripts/ui/UITheme.gd")
# LoginScreen holds the auto-login credential store (static helpers) — reused here
# so the toggle reads/writes the same `user://login.cfg`.
const LoginScreenCls = preload("res://scripts/LoginScreen.gd")
# VikingTheme uses `class_name VikingTheme` — globally available, no
# preload const needed (would shadow the class_name symbol).

# Account section state — populated from server account_info push.
var _acct_email_lbl: Label = null
var _acct_status_lbl: Label = null

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build()
	# Listen for account info pushes (used after login + after any change).
	NetworkManager.account_info.connect(_on_account_info)
	NetworkManager.change_email_ok.connect(_on_change_email_ok)
	NetworkManager.change_email_fail.connect(_on_account_op_fail)
	NetworkManager.change_password_ok.connect(_on_change_password_ok)
	NetworkManager.change_password_fail.connect(_on_account_op_fail)
	# Fetch on first open. If not yet logged in this no-ops cleanly.
	NetworkManager.send_get_account_info()

func _build() -> void:
	add_child(VikingTheme.section_header("Settings", 14))
	add_child(VikingTheme.divider())

	# Keybind section
	add_child(VikingTheme.section_header("Controls", 11))
	var binds: Array[Array] = [
		["WASD",         "Move character"],
		["Arrow Keys",   "Pan camera (free mode)"],
		["Scroll Wheel", "Zoom in / out"],
		["Left Click",   "Select / move / action menu"],
		["Right Click",  "Action menu on objects, cancel on empty"],
		["Long Press",   "Touch equivalent of right click (mobile)"],
		["E",            "Launch / dock boat"],
	]
	for b: Array in binds:
		var row := HBoxContainer.new()
		var key := Label.new()
		key.text = b[0]
		key.custom_minimum_size = Vector2(110, 0)
		key.add_theme_color_override("font_color", VikingTheme.GOLD)
		key.add_theme_font_size_override("font_size", 10)
		var act := Label.new()
		act.text = b[1]
		act.add_theme_color_override("font_color", VikingTheme.TEXT)
		act.add_theme_font_size_override("font_size", 10)
		row.add_child(key)
		row.add_child(act)
		add_child(row)

	add_child(VikingTheme.divider())
	add_child(VikingTheme.section_header("Volume", 11))
	# Bus names match AudioManager.BUS_* constants. Using string literals
	# here lets the editor's static analyzer resolve before the autoload
	# loads; AudioManager looks them up at runtime by name anyway.
	_add_volume_slider("Master",   "Master")
	_add_volume_slider("Music",    "Music")
	_add_volume_slider("Effects",  "SFX")
	_add_volume_slider("Ambience", "Ambience")

	add_child(VikingTheme.divider())
	_build_graphics_section()

	add_child(VikingTheme.divider())
	_build_account_section()

	add_child(VikingTheme.divider())
	add_child(VikingTheme.section_header("Help", 11))
	var tut_btn := Button.new()
	tut_btn.text = "Replay Tutorial"
	tut_btn.custom_minimum_size = Vector2(0, 30)
	VikingTheme.apply_button(tut_btn, false)
	tut_btn.pressed.connect(func() -> void: Events.replay_tutorial.emit())
	add_child(tut_btn)

	var guides_btn := Button.new()
	guides_btn.text = "📖 Guides"
	guides_btn.custom_minimum_size = Vector2(0, 30)
	VikingTheme.apply_button(guides_btn, false)
	guides_btn.pressed.connect(func() -> void: Events.show_guides.emit())
	add_child(guides_btn)

	var intro_btn := Button.new()
	intro_btn.text = "📖 Replay Opening"
	intro_btn.custom_minimum_size = Vector2(0, 30)
	VikingTheme.apply_button(intro_btn, false)
	intro_btn.pressed.connect(func() -> void: Events.replay_prologue.emit())
	add_child(intro_btn)

	add_child(VikingTheme.divider())
	# Auto-login toggle — when on, the game signs itself in on launch with the last
	# saved account. Turning it off wipes the stored credentials.
	var auto_btn := CheckButton.new()
	auto_btn.text = "Auto-login on launch"
	auto_btn.button_pressed = bool(LoginScreenCls.load_login().get("auto", false))
	auto_btn.add_theme_color_override("font_color", VikingTheme.TEXT)
	auto_btn.add_theme_font_size_override("font_size", 11)
	auto_btn.toggled.connect(_on_auto_login_toggled)
	add_child(auto_btn)
	var auto_hint := Label.new()
	auto_hint.text = "Log in once; later launches connect automatically."
	auto_hint.add_theme_color_override("font_color", VikingTheme.DIM)
	auto_hint.add_theme_font_size_override("font_size", 9)
	auto_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(auto_hint)

	var logout_btn := Button.new()
	logout_btn.text = "Log Out"
	logout_btn.custom_minimum_size = Vector2(0, 32)
	VikingTheme.apply_button(logout_btn, false)
	logout_btn.add_theme_color_override("font_color", VikingTheme.RED)
	logout_btn.pressed.connect(_on_logout_pressed)
	add_child(logout_btn)

func _on_auto_login_toggled(on: bool) -> void:
	LoginScreenCls.set_auto_login(on)

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

## Graphics section — Terrain quality toggle (Crisp vs Smooth). Reads the
## live Ground node's current mode so the button reflects the persisted
## setting on open; on toggle, drives Ground.set_terrain_smooth() which
## saves the pref + re-bakes + swaps the shader live (no restart).
func _build_graphics_section() -> void:
	add_child(VikingTheme.section_header("Graphics", 11))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "Terrain"
	lbl.custom_minimum_size = Vector2(70, 0)
	lbl.add_theme_color_override("font_color", UITheme.TEXT)
	lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(lbl)
	var toggle := CheckButton.new()
	toggle.text = "Smooth (Civ-style)"
	toggle.add_theme_font_size_override("font_size", 10)
	# Reflect the current live mode. Ground exposes `_terrain_smooth`; fall
	# back to reading graphics.cfg directly if the world isn't loaded yet.
	toggle.button_pressed = _current_terrain_smooth()
	toggle.toggled.connect(func(on: bool) -> void:
		var ground := get_tree().get_first_node_in_group("ground")
		if ground != null and ground.has_method("set_terrain_smooth"):
			ground.call("set_terrain_smooth", on))
	row.add_child(toggle)
	add_child(row)
	var hint := Label.new()
	hint.text = "Smooth melts biome borders + softens detail. Off = crisp tiles."
	hint.add_theme_color_override("font_color", UITheme.DIM)
	hint.add_theme_font_size_override("font_size", 9)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint)

	# ── 2D / 3D renderer toggle (v1.6 P7) ──
	var row3d := HBoxContainer.new()
	row3d.add_theme_constant_override("separation", 6)
	var lbl3d := Label.new()
	lbl3d.text = "World"
	lbl3d.custom_minimum_size = Vector2(70, 0)
	lbl3d.add_theme_color_override("font_color", UITheme.TEXT)
	lbl3d.add_theme_font_size_override("font_size", 10)
	row3d.add_child(lbl3d)
	var t3d := CheckButton.new()
	t3d.text = "3D (beta)"
	t3d.add_theme_font_size_override("font_size", 10)
	t3d.button_pressed = _renderer_3d_pref()
	t3d.toggled.connect(func(on: bool) -> void:
		_save_renderer_3d_pref(on)
		# Carry the player's CURRENT position across the switch (else they'd respawn
		# at Bjorn's = a free fast-travel). If inside an interior/dungeon, use the
		# overworld return anchor so we never land in the far-Y interior band.
		if GameManager.in_interior:
			GameManager.switch_pos = GameManager.overworld_anchor
		else:
			var p := get_tree().get_first_node_in_group("player")
			if p != null and p is Node2D:
				GameManager.switch_pos = (p as Node2D).global_position
		# Switch live — both clients reuse the autoloads + LoginScreen, so if you're
		# already logged in the other client spawns you straight back in.
		get_tree().change_scene_to_file("res://world3d.tscn" if on else "res://world.tscn"))
	row3d.add_child(t3d)
	add_child(row3d)
	var hint3d := Label.new()
	hint3d.text = "Play in the low-poly 3D world (in development) or the classic 2D world. Switches immediately."
	hint3d.add_theme_color_override("font_color", UITheme.DIM)
	hint3d.add_theme_font_size_override("font_size", 9)
	hint3d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint3d)

## Persisted renderer choice (user://graphics.cfg, section [graphics]). Read by
## Boot.gd at launch AND to init the toggle here.
func _renderer_3d_pref() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load("user://graphics.cfg") != OK:
		return false
	return bool(cfg.get_value("graphics", "renderer_3d", false))

func _save_renderer_3d_pref(on: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://graphics.cfg")   # keep other graphics keys (e.g. terrain_smooth)
	cfg.set_value("graphics", "renderer_3d", on)
	cfg.save("user://graphics.cfg")

## Current terrain-smooth state — prefer the live Ground node, fall back to
## the persisted config file if the world scene isn't up yet.
func _current_terrain_smooth() -> bool:
	var ground := get_tree().get_first_node_in_group("ground")
	if ground != null:
		var v: Variant = ground.get("_terrain_smooth")
		if v != null:
			return bool(v)
	var cfg := ConfigFile.new()
	if cfg.load("user://graphics.cfg") != OK:
		return false
	return bool(cfg.get_value("graphics", "terrain_smooth", false))

func _on_logout_pressed() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Log Out"
	# Warn if any thrall is idle or a combat thrall has no food (Phase 10b) —
	# leaving now wastes the offline window or risks a starving thrall's death.
	var warn: Array = ThrallManager.attention_notes()
	if warn.is_empty():
		dlg.dialog_text = "Are you sure you want to log out?"
	else:
		dlg.dialog_text = ("⚠ Your thralls need attention:\n• "
			+ "\n• ".join(warn) + "\n\nLog out anyway?")
	dlg.ok_button_text = "Log Out"
	dlg.confirmed.connect(func() -> void:
		NetworkManager.logout()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()

# ── Account section ────────────────────────────────────────────────────────
## Self-service email + password management. Closes the loop on the
## recovery system shipped last pass: now users can add their own email
## (required for password recovery) and rotate their password without
## needing an admin.
##
## Also exposes a "Choose backstory" button for any account that doesn't
## yet have one. Busterrdust and other accounts that predate the v13
## migration come in with backstory='' — the auto-popup at login is the
## main path, but if it ever fails to show, this button is the manual
## fallback. The button hides itself once a backstory is set.
var _backstory_btn: Button = null

func _build_account_section() -> void:
	var header := Label.new()
	header.text = "Account"
	header.add_theme_color_override("font_color", UITheme.GOLD)
	header.add_theme_font_size_override("font_size", 11)
	add_child(header)

	# Backstory row — only relevant for old accounts without a backstory
	# yet. Visibility refreshed on login + on backstory_set.
	_backstory_btn = Button.new()
	_backstory_btn.text = "Choose backstory perk…"
	_backstory_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backstory_btn.custom_minimum_size = Vector2(0, 28)
	VikingTheme.apply_button(_backstory_btn, true)
	_backstory_btn.pressed.connect(_open_backstory_picker)
	add_child(_backstory_btn)
	_refresh_backstory_btn()
	NetworkManager.backstory_set.connect(func(_bs: String) -> void:
		_refresh_backstory_btn())
	# Also refresh on every login_ok — handles the case where the panel
	# was already built BEFORE the player logged in (so backstory was ""
	# at build time but is now valid, or vice versa for legacy accounts).
	NetworkManager.login_ok.connect(func(_pd: Dictionary) -> void:
		_refresh_backstory_btn())

	_acct_email_lbl = Label.new()
	_acct_email_lbl.text = "Email: (loading…)"
	_acct_email_lbl.add_theme_color_override("font_color", UITheme.DIM)
	_acct_email_lbl.add_theme_font_size_override("font_size", 10)
	add_child(_acct_email_lbl)

	# Inline status line — success/error feedback for any account op.
	_acct_status_lbl = Label.new()
	_acct_status_lbl.add_theme_color_override("font_color", UITheme.DIM)
	_acct_status_lbl.add_theme_font_size_override("font_size", 9)
	_acct_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_acct_status_lbl)

	# Action buttons — open a small dialog with the required fields.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var email_btn := _acct_action_btn("Set / change email")
	email_btn.pressed.connect(_open_change_email_dialog)
	row.add_child(email_btn)
	var pw_btn := _acct_action_btn("Change password")
	pw_btn.pressed.connect(_open_change_password_dialog)
	row.add_child(pw_btn)

func _acct_action_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 26)
	VikingTheme.apply_button(b, false)
	return b

func _on_account_info(data: Dictionary) -> void:
	if _acct_email_lbl == null:
		return
	var email := str(data.get("email", ""))
	var verified := bool(data.get("email_verified", false))
	if email.is_empty():
		_acct_email_lbl.text = "Email: (none — no password recovery)"
		_acct_email_lbl.add_theme_color_override("font_color", UITheme.DIM)
	else:
		_acct_email_lbl.text = "Email: %s%s" % [email, "  ✓ verified" if verified else "  (unverified)"]
		_acct_email_lbl.add_theme_color_override("font_color",
			UITheme.TEXT if verified else UITheme.DIM)

func _on_change_email_ok(_new_email: String) -> void:
	_acct_status("Email updated.", UITheme.GOLD)
	# Re-fetch so the label refreshes with verified state.
	NetworkManager.send_get_account_info()

func _on_change_password_ok() -> void:
	_acct_status("Password updated.", UITheme.GOLD)

func _on_account_op_fail(reason: String) -> void:
	_acct_status(reason, Color(0.95, 0.40, 0.30))

func _acct_status(text: String, col: Color) -> void:
	if _acct_status_lbl == null:
		return
	_acct_status_lbl.text = text
	_acct_status_lbl.add_theme_color_override("font_color", col)

# ── Self-service dialogs ───────────────────────────────────────────────────
# ── Backstory picker fallback ──────────────────────────────────────────────
## Shows the button only when no backstory has been picked yet. Old accounts
## (pre-v13 migration) come in with backstory='', the login auto-pop is the
## primary path, this is the manual escape hatch in case it doesn't show.
func _refresh_backstory_btn() -> void:
	if _backstory_btn == null:
		return
	_backstory_btn.visible = str(GameManager.backstory) == ""

## Pop the BackstorySelectScreen as a modal on the current scene root. Works
## from any login state — World.gd's auto-pop and this button take the same
## path, so anything that would have blocked the auto-pop also doesn't apply
## here either.
func _open_backstory_picker() -> void:
	var script := load("res://scripts/BackstorySelectScreen.gd")
	if script == null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Don't double-spawn if one is already up.
	if scene.get_node_or_null("BackstorySelectScreen") != null:
		return
	var screen: Node = script.new()
	screen.name = "BackstorySelectScreen"
	scene.add_child(screen)

func _open_change_email_dialog() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Set / change email"
	dlg.ok_button_text = "Save"
	dlg.add_cancel_button("Cancel")
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 4)
	var lbl1 := Label.new()
	lbl1.text = "Current password:"
	lbl1.add_theme_font_size_override("font_size", 10)
	box.add_child(lbl1)
	var pw := LineEdit.new()
	pw.secret = true
	box.add_child(pw)
	var lbl2 := Label.new()
	lbl2.text = "New email (leave blank to remove):"
	lbl2.add_theme_font_size_override("font_size", 10)
	box.add_child(lbl2)
	var em := LineEdit.new()
	box.add_child(em)
	dlg.add_child(box)
	dlg.confirmed.connect(func() -> void:
		NetworkManager.send_change_email(pw.text, em.text.strip_edges()))
	add_child(dlg)
	dlg.popup_centered()

func _open_change_password_dialog() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Change password"
	dlg.ok_button_text = "Save"
	dlg.add_cancel_button("Cancel")
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 4)
	var lbl1 := Label.new()
	lbl1.text = "Current password:"
	lbl1.add_theme_font_size_override("font_size", 10)
	box.add_child(lbl1)
	var cur := LineEdit.new()
	cur.secret = true
	box.add_child(cur)
	var lbl2 := Label.new()
	lbl2.text = "New password (4+ characters):"
	lbl2.add_theme_font_size_override("font_size", 10)
	box.add_child(lbl2)
	var nw := LineEdit.new()
	nw.secret = true
	box.add_child(nw)
	dlg.add_child(box)
	dlg.confirmed.connect(func() -> void:
		NetworkManager.send_change_password(cur.text, nw.text))
	add_child(dlg)
	dlg.popup_centered()
