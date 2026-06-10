extends CanvasLayer

## Single VikingPanel modal that handles all three NPC quest interactions:
##   - OFFER     : NPC has a quest available. Shows preview + Accept/Decline.
##   - TURN_IN   : Active quest's objectives are all met. Shows completion
##                 banner + Complete/Close.
##   - REMINDER  : Active quest with objectives still pending. Shows progress
##                 + Close.
## Triggered via Events.show_quest_dialogue(quest_id, mode, npc_name).
## Closes via the X, the Decline/Close button, or by accepting/completing —
## the action sends the RPC; the server's `quest_state` push triggers any
## downstream marker/QuestLog refresh.

const VikingPanelScene = preload("res://scripts/ui/VikingPanel.gd")
const QuestData   = preload("res://scripts/QuestData.gd")
const Lore        = preload("res://scripts/Lore.gd")

const PANEL_SIZE := Vector2(440, 480)

const TEXT_WARM  := Color(0.910, 0.835, 0.640)
const TEXT_DIM   := Color(0.690, 0.620, 0.450)
const TEXT_GOLD  := Color(0.957, 0.776, 0.298)
const TEXT_GREEN := Color(0.55, 0.88, 0.55)

var _panel:      VikingPanel    = null
var _body_root:  VBoxContainer  = null
var _btn_row:    HBoxContainer  = null
# Current modal context — refreshed every time the modal opens.
var _quest_id:   String = ""
var _mode:       String = ""
var _npc_name:   String = ""
# When the user clicks "About this town", we stash the prior mode so the
# Back button can restore the offer/reminder/turnin view rather than
# defaulting to reminder.
var _saved_mode: String = ""

func _ready() -> void:
	layer = 85   # above QuestLog (80) so it overlays if both pop together
	Events.show_quest_dialogue.connect(_on_show)
	# When the server pushes new quest state, re-render in case progress
	# bumped while the modal was open (e.g. a kill landed mid-dialogue).
	Events.quest_state_changed.connect(_on_state_changed)
	_build_panel()
	_panel.visible = false

func _build_panel() -> void:
	_panel = VikingPanel.new()
	_panel.tint  = VikingPanel.Tint.QUEST
	_panel.title = "Quest"
	_panel.anchor_left = 0.5; _panel.anchor_right = 0.5
	_panel.anchor_top  = 0.5; _panel.anchor_bottom = 0.5
	_panel.offset_left   = -PANEL_SIZE.x * 0.5
	_panel.offset_top    = -PANEL_SIZE.y * 0.5
	_panel.offset_right  =  PANEL_SIZE.x * 0.5
	_panel.offset_bottom =  PANEL_SIZE.y * 0.5
	add_child(_panel)

	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.anchor_left = 1.0; close.anchor_right = 1.0
	close.offset_left = -28; close.offset_right = -8
	close.offset_top = 4;    close.offset_bottom = 24
	close.add_theme_color_override("font_color", TEXT_WARM)
	close.add_theme_font_size_override("font_size", 14)
	close.pressed.connect(func() -> void: _close())
	_panel.add_child(close)

	# Vertical body — title, content, button row at bottom.
	var root := VBoxContainer.new()
	root.anchor_left = 0.0; root.anchor_right = 1.0
	root.anchor_top  = 0.0; root.anchor_bottom = 1.0
	root.add_theme_constant_override("separation", 6)
	_panel.content.add_child(root)

	_body_root = VBoxContainer.new()
	_body_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_root.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_body_root.add_theme_constant_override("separation", 6)
	root.add_child(_body_root)

	_btn_row = HBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", 6)
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(_btn_row)

func _on_show(quest_id: String, mode: String, npc_name: String) -> void:
	_quest_id = quest_id
	_mode     = mode
	_npc_name = npc_name
	_panel.visible = true
	_refresh()

func _on_state_changed() -> void:
	# Only react if the modal is currently rendering an active quest — the
	# turn-in state can flip from REMINDER to TURN_IN mid-view (kill landed
	# while looking at progress). Re-derive mode rather than refreshing
	# blindly so the buttons reflect the new state.
	if _panel == null or not _panel.visible:
		return
	if _quest_id == "" or _npc_name == "":
		return
	# If the player abandoned this quest from somewhere else, just close.
	var dlg: Dictionary = QuestData.dialogue_for_npc(
		_npc_name,
		GameManager.server_active_quests,
		GameManager.server_completed_ids,
		_npc_skill_levels())
	var new_mode := str(dlg.get("mode", ""))
	if new_mode == "":
		_close()
		return
	# Match the quest_id too — completing a turn-in may roll us into the
	# chained NEXT quest (offer mode for a different quest_id).
	_quest_id = str(dlg.get("quest_id", _quest_id))
	_mode     = new_mode
	_refresh()

func _close() -> void:
	if _panel != null:
		_panel.visible = false
	_quest_id = ""
	_mode     = ""
	_npc_name = ""

# ── Render ───────────────────────────────────────────────────────────────────
func _refresh() -> void:
	for c: Node in _body_root.get_children():
		c.queue_free()
	for c: Node in _btn_row.get_children():
		c.queue_free()
	var def: Dictionary = QuestData.data(_quest_id)
	if def.is_empty():
		var lbl := Label.new()
		lbl.text = "(quest data missing)"
		lbl.add_theme_color_override("font_color", TEXT_DIM)
		_body_root.add_child(lbl)
		return
	# Title.
	var title := Label.new()
	title.text = str(def.get("title", ""))
	title.add_theme_color_override("font_color", TEXT_GOLD)
	title.add_theme_font_size_override("font_size", 16)
	_body_root.add_child(title)

	# Giver subtitle.
	var subtitle := Label.new()
	subtitle.text = "%s · %s" % [_npc_name, _mode_label()]
	subtitle.add_theme_color_override("font_color", TEXT_DIM)
	subtitle.add_theme_font_size_override("font_size", 11)
	_body_root.add_child(subtitle)

	_body_root.add_child(_thin_divider())

	match _mode:
		"offer":   _render_offer(def)
		"turnin":  _render_turnin(def)
		"reminder": _render_reminder(def)
		"lore":    _render_lore(def)
		_:         _render_reminder(def)
	# "About this town" button — only on quest modes, never lore mode itself.
	if _mode != "lore":
		_add_lore_button()

func _mode_label() -> String:
	match _mode:
		"offer":    return "New Quest"
		"turnin":   return "Ready to Turn In"
		"reminder": return "In Progress"
		"lore":     return "About This Town"
	return ""

## LORE: town description + Jarl bio + Back button.
func _render_lore(_def: Dictionary) -> void:
	var town_id := Lore.town_of_npc(_npc_name)
	var town: Dictionary = Lore.town(town_id) if town_id != "" else {}
	if town.is_empty():
		var lbl := Label.new()
		lbl.text = "Little is known of this place."
		lbl.add_theme_color_override("font_color", TEXT_DIM)
		_body_root.add_child(lbl)
		_add_btn("Back", TEXT_DIM, func() -> void:
			_mode = "reminder"
			_refresh())
		return
	# Region subtitle.
	var region := Label.new()
	region.text = str(town.get("region", ""))
	region.add_theme_color_override("font_color", TEXT_DIM)
	region.add_theme_font_size_override("font_size", 11)
	_body_root.add_child(region)
	# Description scroll.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 160)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	scroll.add_child(col)
	var desc := Label.new()
	desc.text = str(town.get("description", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.add_theme_color_override("font_color", TEXT_WARM)
	desc.add_theme_font_size_override("font_size", 12)
	col.add_child(desc)
	col.add_child(_thin_divider())
	var jarl_head := Label.new()
	jarl_head.text = "Jarl · %s" % str(town.get("jarl", ""))
	jarl_head.add_theme_color_override("font_color", TEXT_GOLD)
	jarl_head.add_theme_font_size_override("font_size", 12)
	col.add_child(jarl_head)
	var jarl_bio := Label.new()
	jarl_bio.text = str(town.get("jarl_bio", ""))
	jarl_bio.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	jarl_bio.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jarl_bio.add_theme_color_override("font_color", TEXT_WARM)
	jarl_bio.add_theme_font_size_override("font_size", 12)
	col.add_child(jarl_bio)
	_body_root.add_child(scroll)
	_add_btn("Back", TEXT_DIM, func() -> void:
		_mode = _saved_mode if _saved_mode != "" else "reminder"
		_refresh())

func _add_lore_button() -> void:
	var town_id := Lore.town_of_npc(_npc_name)
	if town_id == "":
		return
	var town: Dictionary = Lore.town(town_id)
	if town.is_empty():
		return
	var label := "About %s" % str(town.get("name", "this town"))
	_add_btn(label, TEXT_DIM, func() -> void:
		_saved_mode = _mode
		_mode = "lore"
		_refresh())

## OFFER: description + objectives (no progress) + rewards preview + Accept/Decline
func _render_offer(def: Dictionary) -> void:
	_body_root.add_child(_make_description(def))
	_body_root.add_child(_thin_divider())
	_body_root.add_child(_section_label("Objectives"))
	var objs: Array = def.get("objectives", [])
	for i in range(objs.size()):
		var obj := objs[i] as Dictionary
		_body_root.add_child(_make_bullet_row(
			str(obj.get("display", "")),
			"× %d" % int(obj.get("quantity", 1)),
			TEXT_WARM))
	_body_root.add_child(_thin_divider())
	_body_root.add_child(_section_label("Rewards"))
	_body_root.add_child(_make_rewards_block(def))
	_add_btn("Accept", TEXT_GREEN, func() -> void:
		NetworkManager.send_quest_accept(_quest_id)
		_close())
	_add_btn("Decline", TEXT_DIM, func() -> void: _close())

## TURN_IN: completion banner + reward summary + Complete/Close
func _render_turnin(def: Dictionary) -> void:
	var banner := Label.new()
	banner.text = "All objectives complete! Claim your reward."
	banner.add_theme_color_override("font_color", TEXT_GREEN)
	banner.add_theme_font_size_override("font_size", 12)
	banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_root.add_child(banner)
	_body_root.add_child(_thin_divider())
	_body_root.add_child(_section_label("Rewards"))
	_body_root.add_child(_make_rewards_block(def))
	# Boss-repeat caveat — the server WILL strip gold/items on this
	# completion if the rule applies, so we mirror that in the UI.
	if bool(def.get("boss", false)) and bool(def.get("repeatable", false)):
		var counts: Dictionary = GameManager.server_completion_counts
		if int(counts.get(_quest_id, 0)) >= 1:
			var note := Label.new()
			note.text = "(Boss-repeat: gold and items already claimed on a prior turn-in. This time grants XP only.)"
			note.add_theme_color_override("font_color", TEXT_DIM)
			note.add_theme_font_size_override("font_size", 10)
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_body_root.add_child(note)
	_add_btn("Complete", TEXT_GOLD, func() -> void:
		NetworkManager.send_quest_complete(_quest_id)
		_close())
	_add_btn("Close", TEXT_DIM, func() -> void: _close())

## REMINDER: description + objectives WITH current progress + Close
func _render_reminder(def: Dictionary) -> void:
	_body_root.add_child(_make_description(def))
	_body_root.add_child(_thin_divider())
	_body_root.add_child(_section_label("Progress"))
	var objs: Array = def.get("objectives", [])
	for i in range(objs.size()):
		var obj := objs[i] as Dictionary
		var need := int(obj.get("quantity", 1))
		var have := GameManager.quest_objective_progress(_quest_id, i)
		var done := have >= need
		var icon := "✔ " if done else "☐ "
		var trail := "%d / %d" % [have, need]
		var col := TEXT_GREEN if done else TEXT_WARM
		_body_root.add_child(_make_bullet_row(
			icon + str(obj.get("display", "")), trail, col))
	_add_btn("Close", TEXT_DIM, func() -> void: _close())

# ── Shared widgets ───────────────────────────────────────────────────────────
func _make_description(def: Dictionary) -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 80)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var lbl := Label.new()
	lbl.text = str(def.get("description", ""))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", TEXT_WARM)
	lbl.add_theme_font_size_override("font_size", 12)
	scroll.add_child(lbl)
	return scroll

func _make_rewards_block(def: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	var rewards: Dictionary = def.get("rewards", {})
	# Gold.
	var gold := int(rewards.get("gold", 0))
	if gold > 0:
		col.add_child(_make_bullet_row("Gold", "%dg" % gold, TEXT_GOLD))
	# Items.
	for it: Variant in rewards.get("items", []):
		if not (it is Dictionary):
			continue
		var d := it as Dictionary
		col.add_child(_make_bullet_row(
			"%s" % str(d.get("name", d.get("id", ""))),
			"× %d" % int(d.get("qty", 1)),
			TEXT_WARM))
	# XP per skill.
	for skill: Variant in rewards.get("xp", {}).keys():
		var n := int(rewards["xp"][skill])
		col.add_child(_make_bullet_row(
			"%s XP" % str(skill).capitalize(),
			"+%d" % n,
			TEXT_WARM))
	if col.get_child_count() == 0:
		col.add_child(_make_bullet_row("(no rewards)", "", TEXT_DIM))
	return col

func _make_bullet_row(text: String, trail: String, col: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(6, 6)
	dot.color = col
	# Center the dot vertically with the text.
	var dot_wrap := CenterContainer.new()
	dot_wrap.add_child(dot)
	row.add_child(dot_wrap)
	var lbl := Label.new()
	lbl.text = text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	if trail != "":
		var t := Label.new()
		t.text = trail
		t.add_theme_color_override("font_color", col)
		t.add_theme_font_size_override("font_size", 12)
		row.add_child(t)
	return row

func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", TEXT_GOLD)
	lbl.add_theme_font_size_override("font_size", 13)
	return lbl

func _thin_divider() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("color",
		VikingPanel.KNOT_BRONZE.darkened(0.30))
	return sep

func _add_btn(text: String, col: Color, cb: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(110, 30)
	btn.add_theme_color_override("font_color", col)
	btn.add_theme_color_override("font_hover_color", col.lightened(0.15))
	btn.add_theme_color_override("font_pressed_color", col)
	btn.add_theme_font_size_override("font_size", 12)
	var sb_n := _flat_sb(VikingPanel.BG_COLOR.lightened(0.04))
	var sb_h := _flat_sb(VikingPanel.BG_COLOR.lightened(0.10))
	var sb_p := _flat_sb(VikingPanel.BG_COLOR.lightened(0.16))
	btn.add_theme_stylebox_override("normal",  sb_n)
	btn.add_theme_stylebox_override("hover",   sb_h)
	btn.add_theme_stylebox_override("pressed", sb_p)
	btn.pressed.connect(cb)
	_btn_row.add_child(btn)

func _flat_sb(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(2)
	s.set_border_width_all(1)
	s.border_color = VikingPanel.KNOT_BRONZE.darkened(0.20)
	s.content_margin_left = 8.0
	s.content_margin_right = 8.0
	s.content_margin_top = 4.0
	s.content_margin_bottom = 4.0
	return s

## Same {skill: level} builder NPC.gd uses — duplicated here so the
## state-change re-render path doesn't have to round-trip through NPC.
func _npc_skill_levels() -> Dictionary:
	var out: Dictionary = {}
	for skill: Variant in GameManager.player_skill_xp.keys():
		out[str(skill)] = GameManager.get_skill_level(str(skill))
	return out
