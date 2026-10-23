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

# Shown only if version.txt can't be read — keep it at the current release so a
# missing file degrades gracefully instead of showing something ancient.
const VERSION_FALLBACK := "v1.4.2"
const DEFAULT_SERVER := "147.185.221.211:21498"
# Preloaded (not via class_name) so a stale editor parse can't fail to resolve
# the changelog data — same defensive pattern used elsewhere in the codebase.
const _ChangelogData := preload("res://scripts/Changelog.gd")

## The displayed version, sourced from version.txt (the single source of truth
## release.bat bumps + updater.py maintains) so the login screen never drifts.
## Editor reads res://version.txt; a shipped build reads the exe-adjacent copy
## (where updater.py keeps it, matching its app_dir()/version.txt). version.txt
## has an inconsistent trailing newline, so always strip.
func _read_version() -> String:
	var path := "res://version.txt"
	if not OS.has_feature("editor"):
		path = OS.get_executable_path().get_base_dir().path_join("version.txt")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return VERSION_FALLBACK
	var raw := f.get_as_text().strip_edges()
	f.close()
	if raw == "":
		return VERSION_FALLBACK
	return raw if raw.begins_with("v") else "v" + raw
# Last-used server address persists across launches so mobile players (and
# anyone running their own server) don't have to re-type the address every
# time. ConfigFile at `user://server_address.cfg` — Godot maps user:// to
# the per-OS app data dir, works identically on Windows and Android.
const SERVER_ADDRESS_CFG := "user://server_address.cfg"

# ── Auto-login ──────────────────────────────────────────────────────────────
# After the first successful sign-in the credentials are remembered so the game
# logs itself in on every later launch — the player types them ONCE. Stored in
# `user://login.cfg`; the password is XOR+base64 OBFUSCATED (local deterrent only,
# NOT real encryption — it's a single-user desktop client). Switched off in
# Settings (which clears the saved credentials). A manual Log Out keeps the creds
# but suppresses auto-login for the current session so the player can switch users.
const LOGIN_CFG := "user://login.cfg"
const _OBF_KEY := "vv_local_login_v1"

static func load_login() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(LOGIN_CFG) != OK:
		return {"auto": false, "username": "", "password": ""}
	return {
		"auto": bool(cfg.get_value("login", "auto", false)),
		"username": str(cfg.get_value("login", "username", "")),
		"password": _deobfuscate(str(cfg.get_value("login", "password", ""))),
	}

static func save_login(username: String, password: String, auto: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("login", "auto", auto)
	cfg.set_value("login", "username", username)
	cfg.set_value("login", "password", _obfuscate(password))
	var _e := cfg.save(LOGIN_CFG)

## Toggle auto-login without needing the password (called from Settings). ON just
## flips the flag — the password is already saved from the last sign-in; OFF wipes
## the saved credentials entirely.
static func set_auto_login(enabled: bool) -> void:
	var d := load_login()
	if enabled:
		save_login(str(d["username"]), str(d["password"]), true)
	else:
		clear_login()

static func clear_login() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("login", "auto", false)
	cfg.set_value("login", "username", "")
	cfg.set_value("login", "password", "")
	var _e := cfg.save(LOGIN_CFG)

static func _obfuscate(s: String) -> String:
	if s == "":
		return ""
	var raw := s.to_utf8_buffer()
	var key := _OBF_KEY.to_utf8_buffer()
	for i in range(raw.size()):
		raw[i] = raw[i] ^ key[i % key.size()]
	return Marshalls.raw_to_base64(raw)

static func _deobfuscate(s: String) -> String:
	if s == "":
		return ""
	var raw := Marshalls.base64_to_raw(s)
	if raw.is_empty():
		return ""
	var key := _OBF_KEY.to_utf8_buffer()
	for i in range(raw.size()):
		raw[i] = raw[i] ^ key[i % key.size()]
	return raw.get_string_from_utf8()

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
## Auto-login: armed in _ready when saved credentials should be used; fires once
## the socket connects. `_was_auto_attempt` marks that the CURRENT in-flight login
## came from auto-login, so a rejection can wipe the stale saved credentials.
var _auto_login_pending: bool = false
var _was_auto_attempt: bool = false

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
	# Auto-login: prefill the last username always (one-click re-login), and if
	# auto-login is on with saved credentials — and a manual logout hasn't
	# suppressed it this session — arm it to fire the moment we connect.
	var saved := load_login()
	if str(saved["username"]) != "" and _user_field != null:
		_user_field.text = str(saved["username"])
	if bool(saved["auto"]) and str(saved["username"]) != "" \
			and str(saved["password"]) != "" and not _auto_login_suppressed():
		if _pass_field != null:
			_pass_field.text = str(saved["password"])
		_auto_login_pending = true
	_attempt_connect()

func _auto_login_suppressed() -> bool:
	return _nm != null and bool(_nm.get("suppress_auto_login"))

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

	# ── Discord invite (always open) ──────────────────────────────────────────
	var discord_row := HBoxContainer.new()
	discord_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(discord_row)
	var discord := _link_btn("💬  Join our Discord")
	discord.add_theme_color_override("font_color", Color(0.45, 0.55, 0.95))
	discord.add_theme_color_override("font_hover_color", Color(0.65, 0.75, 1.0))
	discord.pressed.connect(func() -> void: OS.shell_open("https://discord.gg/uajgxvU3c"))
	discord_row.add_child(discord)

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
	_addr_lbl.text = _load_saved_server_address()
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
	_url_field.text = _load_saved_server_address()
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

	# ── Version — prominent, invites a click to see the changelog ─────────────
	var ver := Button.new()
	ver.text = "v%s  —  Click me to see updates!" % _read_version()
	ver.flat = true
	ver.focus_mode = Control.FOCUS_NONE
	ver.add_theme_color_override("font_color", RS_GOLD)
	ver.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.7))
	ver.add_theme_color_override("font_pressed_color", RS_GOLD)
	ver.add_theme_font_size_override("font_size", 17)
	ver.tooltip_text = "What's new"
	ver.anchor_left = 0.5; ver.anchor_right = 0.5
	ver.anchor_top  = 1.0; ver.anchor_bottom = 1.0
	ver.offset_left = -190; ver.offset_right = 190
	ver.offset_top  = -40; ver.offset_bottom = -8
	ver.alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.pressed.connect(_show_changelog)
	add_child(ver)

## Changelog overlay — current version on top, scrollable history below. Data
## lives in Changelog.gd; the header version comes from _read_version so it
## always matches the real release.
func _show_changelog() -> void:
	if get_node_or_null("ChangelogOverlay") != null:
		return
	var overlay := Control.new()
	overlay.name = "ChangelogOverlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_sb())
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -240; panel.offset_right = 240
	panel.offset_top = -220;  panel.offset_bottom = 220
	overlay.add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	panel.add_child(root)

	var head := HBoxContainer.new()
	root.add_child(head)
	var title := Label.new()
	title.text = "What's New  —  %s" % _read_version()
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.add_theme_color_override("font_color", RS_DIM)
	close.add_theme_color_override("font_hover_color", RS_GOLD)
	close.pressed.connect(func() -> void: overlay.queue_free())
	head.add_child(close)

	var sep := HSeparator.new()
	root.add_child(sep)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	var entries: Array = _ChangelogData.ENTRIES
	for i in range(entries.size()):
		list.add_child(_changelog_entry(entries[i] as Dictionary, i == 0))

func _changelog_entry(entry: Dictionary, is_current: bool) -> Control:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)

	var hdr := Label.new()
	var vtxt := "v%s" % str(entry.get("version", "?"))
	var ttl := str(entry.get("title", ""))
	hdr.text = "%s  —  %s" % [vtxt, ttl] if ttl != "" else vtxt
	if str(entry.get("date", "")) != "":
		hdr.text += "   (%s)" % str(entry.get("date"))
	hdr.add_theme_color_override("font_color", RS_GOLD if is_current else RS_TEXT)
	hdr.add_theme_font_size_override("font_size", 13 if is_current else 12)
	box.add_child(hdr)
	if is_current:
		var badge := Label.new()
		badge.text = "current version"
		badge.add_theme_color_override("font_color", RS_GREEN)
		badge.add_theme_font_size_override("font_size", 9)
		box.add_child(badge)

	for note: Variant in (entry.get("notes", []) as Array):
		var n := Label.new()
		n.text = "•  %s" % str(note)
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		n.add_theme_color_override("font_color", RS_DIM if not is_current else RS_TEXT)
		n.add_theme_font_size_override("font_size", 10)
		box.add_child(n)
	return box

## Reusable dark panel stylebox matching the login screen's look.
func _panel_sb() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = RS_BG
	sb.border_color = RS_BORDER
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	return sb

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

# ── Server address persistence ─────────────────────────────────────────────
## Loads the last successfully-used server address from
## `user://server_address.cfg`. Falls back to DEFAULT_SERVER on first
## launch (or if the file is corrupt). Mobile players especially benefit —
## they don't want to re-type a playit.gg subdomain every time the app
## starts.
func _load_saved_server_address() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SERVER_ADDRESS_CFG) != OK:
		return DEFAULT_SERVER
	var addr := str(cfg.get_value("server", "address", DEFAULT_SERVER)).strip_edges()
	if addr.is_empty():
		return DEFAULT_SERVER
	return addr

## Persist the currently-typed address. Called from _on_server_connected
## so we only save addresses that actually work (no risk of "saved" a
## typo and locking the user out on next launch).
func _save_server_address() -> void:
	if _url_field == null:
		return
	var addr := _url_field.text.strip_edges()
	if addr.is_empty() or addr == DEFAULT_SERVER:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("server", "address", addr)
	# Save errors are non-fatal — at worst the user retypes next launch.
	var _e := cfg.save(SERVER_ADDRESS_CFG)

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
	# Persist the working address — by the time we're here we know it
	# actually connects, so saving a typo is impossible.
	_save_server_address()
	# Armed auto-login fires now that we're connected (once — if it's rejected the
	# player finishes on the manual screen).
	if _auto_login_pending and not _auto_login_suppressed():
		_auto_login_pending = false
		var u := _user_field.text.strip_edges()
		var p := _pass_field.text
		if _nm != null and u != "" and p != "":
			_was_auto_attempt = true
			_status("Welcome back — signing in as %s…" % u, RS_DIM)
			_nm.send_login(u, p)
			return
	_status("Connected — log in or create an account.", RS_GREEN)
	if _user_field != null:
		_user_field.grab_focus()

func _on_server_disconnected() -> void:
	_set_connected(false)
	_status("Cannot reach server. Check the address and retry.", RS_RED)

func _on_login_ok(player_data: Dictionary) -> void:
	GameManager.populate_from_server_data(player_data)
	# Remember these credentials so the game logs itself in next launch, PRESERVING
	# the player's auto-login preference (defaults ON for the very first sign-in;
	# stays OFF if they switched it off in Settings).
	_was_auto_attempt = false
	var prev := load_login()
	var uname := str(player_data.get("username", _user_field.text.strip_edges()))
	save_login(uname, _pass_field.text, bool(prev.get("auto", true)))
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
	# If the rejected attempt was an AUTO-login, the saved credentials are stale
	# (password changed / account gone). Wipe them so we don't loop next launch and
	# let the player sign in fresh — the username stays prefilled.
	if _was_auto_attempt:
		_was_auto_attempt = false
		clear_login()
		if _pass_field != null:
			_pass_field.text = ""
		_status("Saved login is no longer valid — please sign in.", RS_RED)
		return
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
