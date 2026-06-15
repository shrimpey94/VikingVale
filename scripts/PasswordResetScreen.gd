extends CanvasLayer

## Three-stage password reset modal:
##   STAGE_REQUEST  — enter username or email; server emails a token
##   STAGE_TOKEN    — paste token from email + new password
##   STAGE_DONE     — confirmation; tap "Close" to return to login
##
## Server endpoints used (via NetworkManager):
##   send_request_password_reset(username, email)
##   send_verify_password_reset_token(token)   — gates the new-password form
##   send_complete_password_reset(token, new_password)
##
## Style mirrors LoginScreen.gd's Norse-gold palette. Sits at layer 101
## (one above the login screen so the modal feels "on top" without
## requiring a second layer manager).

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

enum Stage { REQUEST, TOKEN, DONE }

var prefill_username: String = ""

var _nm: Node = null
var _stage: Stage = Stage.REQUEST
var _root_panel: PanelContainer = null
var _body: VBoxContainer = null
var _status_lbl: Label = null
var _last_token: String = ""   # carried across verify → complete


func _ready() -> void:
	layer = 101
	_nm = get_node_or_null("/root/NetworkManager")
	_build_backdrop()
	_build_panel()
	_render_stage()
	if _nm != null:
		_nm.request_password_reset_ok.connect(_on_request_ok)
		_nm.verify_password_reset_token_result.connect(_on_verify_result)
		_nm.complete_password_reset_ok.connect(_on_complete_ok)
		_nm.complete_password_reset_fail.connect(_on_complete_fail)


# ── UI shell ────────────────────────────────────────────────────────────────
func _build_backdrop() -> void:
	# Dimmer that swallows clicks behind the modal.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.anchor_right = 1.0; dim.anchor_bottom = 1.0
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)


func _build_panel() -> void:
	_root_panel = PanelContainer.new()
	_root_panel.add_theme_stylebox_override("panel", _rs(RS_BG_DEEP, RS_BORDER, 3))
	_root_panel.anchor_left = 0.5; _root_panel.anchor_right = 0.5
	_root_panel.anchor_top  = 0.5; _root_panel.anchor_bottom = 0.5
	_root_panel.offset_left   = -220
	_root_panel.offset_right  =  220
	_root_panel.offset_top    = -180
	_root_panel.offset_bottom =  180
	add_child(_root_panel)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", 18)
	outer.add_theme_constant_override("margin_right", 18)
	outer.add_theme_constant_override("margin_top", 18)
	outer.add_theme_constant_override("margin_bottom", 18)
	_root_panel.add_child(outer)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 10)
	outer.add_child(_body)


# ── Stage rendering ────────────────────────────────────────────────────────
func _render_stage() -> void:
	for c: Node in _body.get_children():
		c.queue_free()
	match _stage:
		Stage.REQUEST: _render_request()
		Stage.TOKEN:   _render_token()
		Stage.DONE:    _render_done()


func _render_request() -> void:
	_body.add_child(_title("Forgot password"))
	_body.add_child(_dim_lbl(
		"Enter your username OR email. If an account is found and has "
		"an email on file, a reset token will be sent to that address."))

	var u_field := _make_field("Username", false)
	u_field.text = prefill_username
	_body.add_child(u_field)

	var e_field := _make_field("Email (optional)", false)
	_body.add_child(e_field)

	_status_lbl = _make_status()
	_body.add_child(_status_lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	var send_btn := _btn("Send reset link", true)
	send_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_btn.pressed.connect(func() -> void:
		var u := u_field.text.strip_edges()
		var e := e_field.text.strip_edges()
		if u.is_empty() and e.is_empty():
			_status("Enter username or email.", RS_RED)
			return
		_status("Sending…", RS_DIM)
		_nm.send_request_password_reset(u, e))
	row.add_child(send_btn)
	var have_token_btn := _btn("I have a token", false)
	have_token_btn.pressed.connect(func() -> void:
		_stage = Stage.TOKEN
		_render_stage())
	row.add_child(have_token_btn)

	var close := _link_btn("Cancel")
	close.pressed.connect(_close)
	_body.add_child(close)


func _render_token() -> void:
	_body.add_child(_title("Set a new password"))
	_body.add_child(_dim_lbl(
		"Paste the token from your reset email, then choose a new "
		"password (4+ characters)."))

	var token_field := _make_field("Token (64 characters)", false)
	_body.add_child(token_field)

	var pass_field := _make_field("New password", true)
	_body.add_child(pass_field)

	_status_lbl = _make_status()
	_body.add_child(_status_lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_body.add_child(row)
	var commit := _btn("Set password", true)
	commit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit.pressed.connect(func() -> void:
		var t := token_field.text.strip_edges()
		var p := pass_field.text
		if t.length() != 64:
			_status("Token must be 64 characters.", RS_RED)
			return
		if p.length() < 4:
			_status("Password must be at least 4 characters.", RS_RED)
			return
		_last_token = t
		_status("Verifying…", RS_DIM)
		# Pre-flight verify so we don't waste the user's typed-out
		# password on an expired token. The verify_password_reset_token
		# response handler completes the flow.
		_nm.send_verify_password_reset_token(t)
		# Hold onto the password until we hear back.
		set_meta("_pending_pw", p))
	row.add_child(commit)
	var back := _btn("Back", false)
	back.pressed.connect(func() -> void:
		_stage = Stage.REQUEST
		_render_stage())
	row.add_child(back)


func _render_done() -> void:
	_body.add_child(_title("Password updated"))
	_body.add_child(_dim_lbl(
		"Your password has been changed. You can log in now with your "
		"new password."))
	var close := _btn("Close", true)
	close.pressed.connect(_close)
	_body.add_child(close)


# ── NetworkManager signal handlers ─────────────────────────────────────────
func _on_request_ok(message: String) -> void:
	if _stage != Stage.REQUEST:
		return
	_status(message, RS_GREEN)


func _on_verify_result(ok: bool) -> void:
	if _stage != Stage.TOKEN:
		return
	if not ok:
		_status("That token is invalid or has expired. Try requesting "
			"a new one.", RS_RED)
		remove_meta("_pending_pw")
		return
	var pw: String = str(get_meta("_pending_pw", ""))
	remove_meta("_pending_pw")
	if pw.is_empty():
		_status("Password missing — try again.", RS_RED)
		return
	_status("Setting new password…", RS_DIM)
	_nm.send_complete_password_reset(_last_token, pw)


func _on_complete_ok(_username: String) -> void:
	if _stage != Stage.TOKEN:
		return
	_stage = Stage.DONE
	_render_stage()


func _on_complete_fail(reason: String) -> void:
	if _stage != Stage.TOKEN:
		return
	_status(reason, RS_RED)


# ── UI helpers (small subset of LoginScreen's style) ───────────────────────
func _title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", RS_GOLD)
	l.add_theme_font_size_override("font_size", 18)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _dim_lbl(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", RS_DIM)
	l.add_theme_font_size_override("font_size", 11)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _make_field(placeholder: String, is_password: bool) -> LineEdit:
	var f := LineEdit.new()
	f.placeholder_text = placeholder
	f.secret = is_password
	f.custom_minimum_size = Vector2(0, 30)
	f.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER, 1))
	f.add_theme_color_override("font_color", RS_TEXT)
	f.add_theme_color_override("caret_color", RS_GOLD)
	f.add_theme_font_size_override("font_size", 12)
	return f


func _make_status() -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", RS_DIM)
	l.add_theme_font_size_override("font_size", 11)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(0, 28)
	return l


func _status(text: String, col: Color) -> void:
	if _status_lbl == null:
		return
	_status_lbl.text = text
	_status_lbl.add_theme_color_override("font_color", col)


func _btn(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(110, 32)
	var border := RS_GOLD if primary else RS_BORDER
	var fg := RS_GOLD if primary else RS_TEXT
	b.add_theme_stylebox_override("normal", _rs(RS_BTN_N, border, 2))
	b.add_theme_stylebox_override("hover",  _rs(RS_BTN_H, border, 2))
	b.add_theme_stylebox_override("pressed", _rs(RS_BTN_N, border, 2))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_font_size_override("font_size", 12)
	return b


func _link_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.add_theme_color_override("font_color", RS_DIM)
	b.add_theme_color_override("font_hover_color", RS_GOLD)
	b.add_theme_font_size_override("font_size", 10)
	return b


func _rs(bg: Color, border: Color, border_w: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(2)
	s.set_border_width_all(border_w)
	s.border_color = border
	s.content_margin_left = 8.0
	s.content_margin_right = 8.0
	s.content_margin_top = 4.0
	s.content_margin_bottom = 4.0
	return s


func _close() -> void:
	queue_free()
