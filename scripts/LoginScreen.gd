extends CanvasLayer

## Polished login / register screen shown on game start.
## Auto-connects to the server and shows a live connection indicator.
## Sits on top of everything (layer 100) until the player logs in or goes offline.

const RS_BG     := Color(0.11, 0.07, 0.03)
const RS_BG_DEEP := Color(0.06, 0.04, 0.02)
const RS_BORDER := Color(0.64, 0.49, 0.14)
const RS_BTN_N  := Color(0.08, 0.05, 0.02)
const RS_BTN_H  := Color(0.20, 0.13, 0.05)
const RS_TEXT   := Color(0.92, 0.85, 0.62)
const RS_DIM    := Color(0.60, 0.55, 0.38)
const RS_GOLD   := Color(1.00, 0.85, 0.25)
const RS_RED    := Color(0.90, 0.30, 0.20)
const RS_GREEN  := Color(0.35, 0.88, 0.40)

const VERSION        := "v0.1.0"
const DEFAULT_SERVER := "147.185.221.211:21498"

var _status_lbl: Label    = null
var _user_field: LineEdit = null
var _pass_field: LineEdit = null
var _email_field: LineEdit = null
var _url_field:  LineEdit = null
var _status_dot: Panel    = null
var _addr_lbl:   Label    = null
var _server_row: Control  = null
var _nm: Node = null
var _connected: bool = false
var _pending_char_creation: bool = false

func _ready() -> void:
	layer = 100
	_nm = get_node_or_null("/root/NetworkManager")
	_build_ui()
	if _nm != null:
		_nm.connected_to_server.connect(_on_server_connected)
		_nm.disconnected_from_server.connect(_on_server_disconnected)
		_nm.login_ok.connect(_on_login_ok)
		_nm.login_fail.connect(_on_auth_fail)
		_nm.register_ok.connect(_on_register_ok)
		_nm.register_fail.connect(_on_auth_fail)
		_nm.kicked.connect(_on_kicked)
	_set_connected(false)
	_attempt_connect()

# ── UI construction ─────────────────────────────────────────────────────────
func _build_ui() -> void:
	# Deep gradient backdrop
	var backdrop := ColorRect.new()
	backdrop.color = RS_BG_DEEP
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	# Subtle animated radial vignette behind the panel (slow pulse)
	var glow_bg := ColorRect.new()
	glow_bg.color = Color(0.18, 0.12, 0.04, 0.0)
	glow_bg.anchor_left = 0.5; glow_bg.anchor_right = 0.5
	glow_bg.anchor_top  = 0.5; glow_bg.anchor_bottom = 0.5
	glow_bg.offset_left = -320; glow_bg.offset_right = 320
	glow_bg.offset_top  = -360; glow_bg.offset_bottom = 360
	add_child(glow_bg)
	var bg_tw := create_tween().set_loops()
	bg_tw.tween_property(glow_bg, "color", Color(0.18, 0.12, 0.04, 0.18), 2.6)
	bg_tw.tween_property(glow_bg, "color", Color(0.18, 0.12, 0.04, 0.04), 2.6)

	# Outer decorative (knotwork) border panel
	var outer := PanelContainer.new()
	outer.add_theme_stylebox_override("panel", _rs(RS_BG_DEEP, RS_BORDER.darkened(0.3), 2))
	outer.anchor_left = 0.5; outer.anchor_right = 0.5
	outer.anchor_top  = 0.5; outer.anchor_bottom = 0.5
	outer.offset_left = -218; outer.offset_right = 218
	outer.offset_top  = -288; outer.offset_bottom = 288
	add_child(outer)

	# Inner panel (the actual content frame)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 2))
	add_child(panel)
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -206; panel.offset_right = 206
	panel.offset_top  = -276; panel.offset_bottom = 276

	# Corner rune accents (Norse flavour)
	_add_corner_runes(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# ── Logo (glow + emboss) ──────────────────────────────────────────────────
	vbox.add_child(_make_logo())

	var tagline := Label.new()
	tagline.text = "Explore.  Skill.  Conquer."
	tagline.add_theme_color_override("font_color", RS_DIM)
	tagline.add_theme_font_size_override("font_size", 12)
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(tagline)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	# ── Credentials ───────────────────────────────────────────────────────────
	_user_field = _make_field("Username", false)
	vbox.add_child(_user_field)
	_pass_field = _make_field("Password", true)
	_pass_field.gui_input.connect(_on_pass_input)
	vbox.add_child(_pass_field)
	# Email field — optional, only used on Create Account. Login ignores it.
	# Helps brand-new accounts have a recovery channel out of the gate.
	_email_field = _make_field("Email (optional — for password recovery)", false)
	vbox.add_child(_email_field)

	# ── Primary buttons ───────────────────────────────────────────────────────
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)
	var login_btn := _btn("Login", true)
	login_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	login_btn.pressed.connect(_on_login_pressed)
	btn_row.add_child(login_btn)
	var reg_btn := _btn("Create Account", false)
	reg_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reg_btn.pressed.connect(_on_register_pressed)
	btn_row.add_child(reg_btn)

	# ── Forgot password link ──────────────────────────────────────────────────
	var forgot_row := HBoxContainer.new()
	forgot_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(forgot_row)
	var forgot_link := _link_btn("Forgot password?")
	forgot_link.pressed.connect(_on_forgot_pressed)
	forgot_row.add_child(forgot_link)

	# ── Status message (errors / progress) ────────────────────────────────────
	_status_lbl = Label.new()
	_status_lbl.text = ""
	_status_lbl.add_theme_color_override("font_color", RS_DIM)
	_status_lbl.add_theme_font_size_override("font_size", 11)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(_status_lbl)

	vbox.add_child(HSeparator.new())

	# ── Connection indicator row (dot + address) ──────────────────────────────
	var conn_row := HBoxContainer.new()
	conn_row.add_theme_constant_override("separation", 6)
	conn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(conn_row)
	_status_dot = Panel.new()
	_status_dot.custom_minimum_size = Vector2(12, 12)
	_status_dot.add_theme_stylebox_override("panel", _dot_style(RS_RED))
	conn_row.add_child(_status_dot)
	_addr_lbl = Label.new()
	_addr_lbl.text = DEFAULT_SERVER
	_addr_lbl.add_theme_color_override("font_color", RS_DIM)
	_addr_lbl.add_theme_font_size_override("font_size", 10)
	conn_row.add_child(_addr_lbl)
	var change := _link_btn("change")
	change.pressed.connect(func() -> void:
		_server_row.visible = not _server_row.visible
		if _server_row.visible:
			_url_field.grab_focus())
	conn_row.add_child(change)

	# ── Server address editor (hidden by default) ─────────────────────────────
	_server_row = HBoxContainer.new()
	(_server_row as HBoxContainer).add_theme_constant_override("separation", 4)
	_server_row.visible = false
	vbox.add_child(_server_row)
	_url_field = LineEdit.new()
	_url_field.text = DEFAULT_SERVER
	_url_field.placeholder_text = "host:port"
	_url_field.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER, 1))
	_url_field.add_theme_color_override("font_color", RS_TEXT)
	_url_field.add_theme_font_size_override("font_size", 11)
	_url_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_url_field.text_submitted.connect(func(_t: String) -> void: _reconnect())
	_server_row.add_child(_url_field)
	var recon := _btn("Connect", false)
	recon.custom_minimum_size = Vector2(80, 0)
	recon.pressed.connect(_reconnect)
	_server_row.add_child(recon)

	# ── Offline (kept available, subtle) ──────────────────────────────────────
	var offline := _link_btn("Play offline (no server)")
	offline.pressed.connect(_on_offline_pressed)
	vbox.add_child(offline)

	# ── Version (bottom-right corner of the screen) ───────────────────────────
	var ver := Label.new()
	ver.text = VERSION
	ver.add_theme_color_override("font_color", RS_DIM.darkened(0.2))
	ver.add_theme_font_size_override("font_size", 10)
	ver.anchor_left = 1.0; ver.anchor_right = 1.0
	ver.anchor_top  = 1.0; ver.anchor_bottom = 1.0
	ver.offset_left = -90; ver.offset_right = -10
	ver.offset_top  = -24; ver.offset_bottom = -6
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(ver)

func _make_logo() -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, 64)

	# Pulsing glow copy behind the title
	var glow := Label.new()
	glow.text = "VikingVale"
	glow.add_theme_color_override("font_color", Color(1.0, 0.78, 0.18))
	glow.add_theme_font_size_override("font_size", 40)
	glow.add_theme_constant_override("outline_size", 14)
	glow.add_theme_color_override("font_outline_color", Color(0.85, 0.55, 0.10))
	glow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glow.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.modulate = Color(1, 1, 1, 0.35)
	holder.add_child(glow)
	var tw := create_tween().set_loops()
	tw.tween_property(glow, "modulate:a", 0.75, 1.8).set_trans(Tween.TRANS_SINE)
	tw.tween_property(glow, "modulate:a", 0.30, 1.8).set_trans(Tween.TRANS_SINE)

	# Dark emboss shadow, offset down-right
	var shadow := Label.new()
	shadow.text = "VikingVale"
	shadow.add_theme_color_override("font_color", Color(0.0, 0.0, 0.0, 0.6))
	shadow.add_theme_font_size_override("font_size", 40)
	shadow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shadow.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.offset_left = 2; shadow.offset_right = 2
	shadow.offset_top  = 2; shadow.offset_bottom = 2
	holder.add_child(shadow)

	# Main gold title
	var title := Label.new()
	title.text = "VikingVale"
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_constant_override("outline_size", 3)
	title.add_theme_color_override("font_outline_color", Color(0.35, 0.22, 0.04))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(title)
	return holder

func _add_corner_runes(panel: Control) -> void:
	var runes := ["ᚠ", "ᚢ", "ᚦ", "ᚨ"]
	var corners := [
		[Vector2(0.0, 0.0),  Vector2(8, 4)],
		[Vector2(1.0, 0.0),  Vector2(-22, 4)],
		[Vector2(0.0, 1.0),  Vector2(8, -22)],
		[Vector2(1.0, 1.0),  Vector2(-22, -22)],
	]
	for i in range(4):
		var r := Label.new()
		r.text = runes[i]
		r.add_theme_color_override("font_color", RS_BORDER)
		r.add_theme_font_size_override("font_size", 16)
		var anch: Vector2 = corners[i][0]
		var off:  Vector2 = corners[i][1]
		r.anchor_left = anch.x; r.anchor_right = anch.x
		r.anchor_top  = anch.y; r.anchor_bottom = anch.y
		r.offset_left = off.x;  r.offset_right = off.x + 16
		r.offset_top  = off.y;  r.offset_bottom = off.y + 18
		panel.add_child(r)

func _make_field(placeholder: String, secret: bool) -> LineEdit:
	var f := LineEdit.new()
	f.placeholder_text = placeholder
	f.secret = secret
	f.alignment = HORIZONTAL_ALIGNMENT_CENTER
	f.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.2), 1))
	f.add_theme_stylebox_override("focus",  _rs(RS_BTN_N, RS_GOLD, 1))
	f.add_theme_color_override("font_color", RS_TEXT)
	f.add_theme_color_override("font_placeholder_color", RS_DIM.darkened(0.1))
	f.add_theme_font_size_override("font_size", 13)
	f.custom_minimum_size = Vector2(0, 34)
	return f

# ── Connection ───────────────────────────────────────────────────────────────
func _server_url() -> String:
	var raw := _url_field.text.strip_edges() if _url_field != null else DEFAULT_SERVER
	if raw.is_empty():
		raw = DEFAULT_SERVER
	if not raw.begins_with("ws://") and not raw.begins_with("wss://"):
		return "ws://" + raw
	return raw

func _attempt_connect() -> void:
	var addr := _url_field.text.strip_edges() if _url_field != null else DEFAULT_SERVER
	if _addr_lbl != null:
		_addr_lbl.text = addr
	_status("Connecting to server…", RS_DIM)
	if _nm != null:
		_nm.connect_to_server(_server_url())

func _reconnect() -> void:
	_server_row.visible = false
	if _nm != null:
		_nm.go_offline()
	_set_connected(false)
	_attempt_connect()

func _set_connected(on: bool) -> void:
	_connected = on
	if _status_dot != null:
		_status_dot.add_theme_stylebox_override("panel", _dot_style(RS_GREEN if on else RS_RED))

# ── Button events ──────────────────────────────────────────────────────────────
func _on_login_pressed() -> void:
	if not _connected:
		_status("Server offline — cannot reach %s." % _addr_lbl.text, RS_RED)
		_attempt_connect()
		return
	var u := _user_field.text.strip_edges()
	var p := _pass_field.text
	if u.is_empty() or p.is_empty():
		_status("Enter your username and password.", RS_RED)
		return
	_status("Logging in…", RS_DIM)
	if _nm != null:
		_nm.send_login(u, p)

func _on_register_pressed() -> void:
	if not _connected:
		_status("Server offline — cannot reach %s." % _addr_lbl.text, RS_RED)
		_attempt_connect()
		return
	var u := _user_field.text.strip_edges()
	var p := _pass_field.text
	var e := _email_field.text.strip_edges() if _email_field != null else ""
	if u.is_empty() or p.is_empty():
		_status("Choose a username and password to register.", RS_RED)
		return
	_status("Creating account…", RS_DIM)
	if _nm != null:
		_nm.send_register(u, p, e)

func _on_offline_pressed() -> void:
	if _nm != null:
		_nm.go_offline()
	_status("Playing offline.", RS_GREEN)
	_close()

# Open the password reset screen as a modal CanvasLayer overlay. Whatever
# the player typed in the username field carries forward as a prefill, so
# they don't have to re-type it if they just realized they forgot the pass.
func _on_forgot_pressed() -> void:
	if not _connected:
		_status("Server offline — connect first to request a reset.", RS_RED)
		_attempt_connect()
		return
	var screen_script := load("res://scripts/PasswordResetScreen.gd")
	if screen_script == null:
		_status("Reset screen unavailable.", RS_RED)
		return
	var prefill := _user_field.text.strip_edges()
	var modal: Node = screen_script.new()
	modal.set("prefill_username", prefill)
	add_child(modal)

func _on_pass_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		if (event as InputEventKey).keycode == KEY_ENTER:
			_on_login_pressed()

# ── NetworkManager callbacks ───────────────────────────────────────────────────
func _on_server_connected() -> void:
	_set_connected(true)
	_status("Connected — log in or create an account.", RS_GREEN)
	if _user_field != null:
		_user_field.grab_focus()

func _on_server_disconnected() -> void:
	_set_connected(false)
	_status("Cannot reach server. Check the address and retry.", RS_RED)

func _on_login_ok(player_data: Dictionary) -> void:
	GameManager.populate_from_server_data(player_data)
	if _pending_char_creation:
		_pending_char_creation = false
		_open_character_creation()
		return
	_status("Welcome, %s!" % player_data.get("username", ""), RS_GREEN)
	_close()

func _open_character_creation() -> void:
	var cc := CanvasLayer.new()
	cc.set_script(load("res://scripts/CharacterCreation.gd"))
	get_tree().root.add_child(cc)
	queue_free()

func _on_auth_fail(reason: String) -> void:
	_status(reason, RS_RED)

func _on_register_ok() -> void:
	_status("Account created — entering character creation…", RS_GREEN)
	_pending_char_creation = true
	var u := _user_field.text.strip_edges()
	var p := _pass_field.text
	if _nm != null:
		_nm.send_login(u, p)

func _on_kicked(reason: String) -> void:
	_set_connected(false)
	_status("Kicked: " + reason, RS_RED)

# ── Helpers ────────────────────────────────────────────────────────────────────
func _status(text: String, col: Color = RS_DIM) -> void:
	if _status_lbl != null:
		_status_lbl.text = text
		_status_lbl.add_theme_color_override("font_color", col)

func _close() -> void:
	await get_tree().create_timer(0.5).timeout
	queue_free()

func _rs(bg: Color, border: Color, bw: int = 3) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_border_width_all(bw)
	s.border_color = border
	s.set_corner_radius_all(2)
	return s

func _dot_style(col: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(6)
	return s

func _btn(label: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = label
	var border := RS_GOLD if primary else RS_BORDER.darkened(0.3)
	b.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, border, 2))
	b.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
	b.add_theme_stylebox_override("pressed", _rs(Color(0.20, 0.13, 0.05), RS_GOLD, 2))
	b.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, border, 2))
	b.add_theme_color_override("font_color",         RS_GOLD if primary else RS_TEXT)
	b.add_theme_color_override("font_hover_color",   RS_GOLD)
	b.add_theme_color_override("font_pressed_color", RS_GOLD)
	b.add_theme_font_size_override("font_size", 13)
	b.custom_minimum_size = Vector2(0, 36)
	return b

func _link_btn(label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.flat = true
	b.add_theme_color_override("font_color",       RS_DIM)
	b.add_theme_color_override("font_hover_color", RS_GOLD)
	b.add_theme_font_size_override("font_size", 10)
	return b
