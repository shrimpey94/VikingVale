extends VBoxContainer

## Friends tab — extracted from HUD.gd (scenes/ui/friends_panel.tscn).
## Self-contained: owns the friends list + add-friend / friend-context dialogs,
## subscribes to Events.friends_list_updated, requests the list when shown.
## Whisper / Trade reach into HUD-owned systems, so those are emitted as
## Events.request_whisper / request_trade; everything else calls NetworkManager.

const UITheme = preload("res://scripts/ui/UITheme.gd")

var _friends: Array = []
var _list: VBoxContainer = null

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(UITheme.title("Friends"))
	add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size   = Vector2(0, 240)
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	add_child(HSeparator.new())
	var add_btn := Button.new()
	add_btn.text = "+ Add Friend"
	add_btn.add_theme_font_size_override("font_size", 11)
	add_btn.pressed.connect(_show_add_friend_dialog)
	add_child(add_btn)

	Events.friends_list_updated.connect(_on_friends_list_updated)
	visibility_changed.connect(func() -> void:
		if visible:
			NetworkManager.send_friends_list())
	_refresh()

func _on_friends_list_updated(friends: Array) -> void:
	_friends = friends
	_refresh()

func _refresh() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	for ch: Node in _list.get_children():
		ch.queue_free()

	if _friends.is_empty():
		var hint := Label.new()
		hint.text = "No friends yet.\nUse + Add Friend or\nright-click a player."
		hint.add_theme_color_override("font_color", UITheme.DIM)
		hint.add_theme_font_size_override("font_size", 10)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(hint)
		return

	var sorted := _friends.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ao := bool(a.get("online", false))
		var bo := bool(b.get("online", false))
		if ao != bo:
			return ao
		return str(a.get("username", "")).naturalnocasecmp_to(str(b.get("username", ""))) < 0)

	for f: Variant in sorted:
		if not (f is Dictionary):
			continue
		var fd: Dictionary = f as Dictionary
		var uname: String = str(fd.get("username", "?"))
		var online: bool  = bool(fd.get("online", false))

		var btn := Button.new()
		btn.text = "  ●  %s" % uname
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_stylebox_override("normal",  UITheme.sb(UITheme.BTN_N, UITheme.BORDER.darkened(0.5), 1))
		btn.add_theme_stylebox_override("hover",   UITheme.sb(UITheme.BTN_H, UITheme.BORDER.darkened(0.3), 1))
		btn.add_theme_stylebox_override("pressed", UITheme.sb(UITheme.BTN_A, UITheme.GOLD, 1))
		btn.add_theme_color_override("font_color", UITheme.GREEN if online else UITheme.DIM)
		btn.add_theme_font_size_override("font_size", 11)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_show_friend_menu.bind(uname, online))
		_list.add_child(btn)

func _show_add_friend_dialog() -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 202
	add_child(overlay)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.BORDER, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -130; panel.offset_right = 130
	panel.offset_top  = -50;  panel.offset_bottom = 50
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Add Friend"
	title.add_theme_color_override("font_color", UITheme.GOLD)
	title.add_theme_font_size_override("font_size", 12)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var field := LineEdit.new()
	field.placeholder_text = "Player name"
	field.add_theme_font_size_override("font_size", 11)
	vbox.add_child(field)

	var send := func() -> void:
		var fname := field.text.strip_edges()
		if not fname.is_empty():
			NetworkManager.send_friend_request(fname)
			Events.chat_message.emit("[Friend request sent to %s]" % fname)
		overlay.queue_free()
	field.text_submitted.connect(func(_t: String) -> void: send.call())

	var send_btn := Button.new()
	send_btn.text = "Send Request"
	send_btn.add_theme_font_size_override("font_size", 11)
	send_btn.pressed.connect(send)
	vbox.add_child(send_btn)
	field.grab_focus()

func _show_friend_menu(username: String, online: bool) -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 202
	add_child(overlay)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.4)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BG, UITheme.BORDER, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -90; panel.offset_right = 90
	panel.offset_top  = -80; panel.offset_bottom = 80
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	panel.add_child(vbox)

	var hdr := Label.new()
	hdr.text = "%s (%s)" % [username, "online" if online else "offline"]
	hdr.add_theme_color_override("font_color", UITheme.GREEN if online else UITheme.DIM)
	hdr.add_theme_font_size_override("font_size", 11)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)
	vbox.add_child(HSeparator.new())

	var mk := func(label: String, cb: Callable) -> Button:
		var b := Button.new()
		b.text = label
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_stylebox_override("normal",  UITheme.sb(UITheme.BG,    Color(0,0,0,0), 0))
		b.add_theme_stylebox_override("hover",   UITheme.sb(UITheme.BTN_H, UITheme.BORDER.darkened(0.5), 1))
		b.add_theme_stylebox_override("pressed", UITheme.sb(UITheme.BTN_A, Color(0,0,0,0), 0))
		b.add_theme_color_override("font_color", UITheme.TEXT)
		b.add_theme_font_size_override("font_size", 10)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(cb)
		return b

	vbox.add_child(mk.call("Whisper", func() -> void:
		overlay.queue_free()
		Events.request_whisper.emit(username)))
	vbox.add_child(mk.call("Trade", func() -> void:
		overlay.queue_free()
		Events.request_trade.emit(username)))
	vbox.add_child(mk.call("Remove Friend", func() -> void:
		overlay.queue_free()
		NetworkManager.send_friend_remove(username)
		Events.chat_message.emit("[Removed %s from friends.]" % username)))
