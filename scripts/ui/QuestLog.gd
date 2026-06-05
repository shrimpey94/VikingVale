extends CanvasLayer

## WoW-style QuestLog modal — master-detail split:
##   Left sidebar:  scrollable list of active quests (click to select).
##   Right detail:  large title, scrolled flavor text, objective list with
##                  counts + checkmarks, rewards row with gold + items, and
##                  an Abandon button at the bottom.
## Wrapped in a VikingPanelScene with QUEST tint. Opens on Events.open_quest_log.

const VikingPanelScene = preload("res://scripts/ui/VikingPanel.gd")
const QuestData   = preload("res://scripts/QuestData.gd")

const PANEL_SIZE := Vector2(640, 520)
const SIDEBAR_W  := 200.0

# Palette anchored to VikingPanelScene.QUEST tint so the inner contents read as
# part of the same frame instead of a generic gray box.
const TEXT_WARM    := Color(0.910, 0.835, 0.640)   # warm cream
const TEXT_DIM     := Color(0.690, 0.620, 0.450)   # darker cream for body
const TEXT_GOLD    := Color(0.957, 0.776, 0.298)
const TEXT_GREEN   := Color(0.55, 0.88, 0.55)
const TEXT_GREY    := Color(0.55, 0.55, 0.55)
const BG_SLOT      := Color(0.110, 0.075, 0.045)
const BG_SLOT_HOV  := Color(0.180, 0.122, 0.075)
const BG_SLOT_SEL  := Color(0.250, 0.165, 0.085)

var _panel:        VikingPanel    = null
var _sidebar:      VBoxContainer  = null
var _detail_root:  VBoxContainer  = null
var _selected_qid: String         = ""

func _ready() -> void:
	layer = 80   # above the world, below admin / modal overlays
	Events.open_quest_log.connect(_on_open)
	Events.quest_state_changed.connect(_on_state_changed)
	_build_panel()
	_panel.visible = false

func _build_panel() -> void:
	_panel = VikingPanelScene.new()
	_panel.title = "Quest Log"
	_panel.tint  = VikingPanelScene.Tint.QUEST
	_panel.anchor_left = 0.5; _panel.anchor_right  = 0.5
	_panel.anchor_top  = 0.5; _panel.anchor_bottom = 0.5
	_panel.offset_left   = -PANEL_SIZE.x * 0.5
	_panel.offset_top    = -PANEL_SIZE.y * 0.5
	_panel.offset_right  =  PANEL_SIZE.x * 0.5
	_panel.offset_bottom =  PANEL_SIZE.y * 0.5
	add_child(_panel)

	# X close button — sits in the panel header
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.anchor_left = 1.0; close.anchor_right = 1.0
	close.offset_left = -28; close.offset_right = -8
	close.offset_top = 4; close.offset_bottom = 24
	close.add_theme_color_override("font_color", TEXT_WARM)
	close.add_theme_font_size_override("font_size", 14)
	close.pressed.connect(func() -> void: _panel.visible = false)
	_panel.add_child(close)

	# Master-detail split inside the panel's content area.
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 10)
	split.anchor_left = 0.0; split.anchor_right = 1.0
	split.anchor_top  = 0.0; split.anchor_bottom = 1.0
	_panel.content.add_child(split)

	# ── Left sidebar: active-quest list ──
	var sidebar_wrap := VBoxContainer.new()
	sidebar_wrap.custom_minimum_size = Vector2(SIDEBAR_W, 0)
	sidebar_wrap.add_theme_constant_override("separation", 4)
	split.add_child(sidebar_wrap)
	sidebar_wrap.add_child(_make_section_label("Active Quests"))

	var sb_scroll := ScrollContainer.new()
	sb_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	sb_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar_wrap.add_child(sb_scroll)
	_sidebar = VBoxContainer.new()
	_sidebar.add_theme_constant_override("separation", 2)
	_sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_scroll.add_child(_sidebar)

	# ── Vertical separator (visual gold-bronze line) ──
	var sep := VSeparator.new()
	sep.add_theme_color_override("color", VikingPanelScene.KNOT_BRONZE)
	split.add_child(sep)

	# ── Right detail pane ──
	_detail_root = VBoxContainer.new()
	_detail_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_root.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_detail_root.add_theme_constant_override("separation", 6)
	split.add_child(_detail_root)

	_refresh()

func _on_open() -> void:
	_panel.visible = true
	_refresh()

func _on_state_changed() -> void:
	if _panel == null or not _panel.visible:
		return   # refresh on next open instead of fighting the UI invisibly
	_refresh()

# ── Refresh ──────────────────────────────────────────────────────────────────
func _refresh() -> void:
	_rebuild_sidebar()
	_rebuild_detail()

func _rebuild_sidebar() -> void:
	for c: Node in _sidebar.get_children():
		c.queue_free()
	var active: Array = GameManager.server_active_quests
	if active.is_empty():
		var none := Label.new()
		none.text = "(none)"
		none.add_theme_color_override("font_color", TEXT_GREY)
		none.add_theme_font_size_override("font_size", 11)
		_sidebar.add_child(none)
		_selected_qid = ""
		return
	# Preserve current selection if still active; otherwise pick the first.
	var have_selected := false
	for row: Variant in active:
		if row is Dictionary and str((row as Dictionary).get("quest_id", "")) == _selected_qid:
			have_selected = true
			break
	if not have_selected:
		_selected_qid = str((active[0] as Dictionary).get("quest_id", ""))
	for row: Variant in active:
		var qid: String = str((row as Dictionary).get("quest_id", ""))
		var def: Dictionary = QuestData.data(qid)
		var title: String = str(def.get("title", qid)) if not def.is_empty() else qid
		_sidebar.add_child(_make_sidebar_entry(qid, title))

func _make_sidebar_entry(qid: String, title: String) -> Button:
	var btn := Button.new()
	btn.text = title
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 12)
	var is_selected: bool = qid == _selected_qid
	var ready_to_turnin: bool = GameManager.is_quest_ready_for_turnin(qid, QuestData)
	var bg := BG_SLOT_SEL if is_selected else BG_SLOT
	btn.add_theme_stylebox_override("normal",  _flat_sb(bg))
	btn.add_theme_stylebox_override("hover",   _flat_sb(BG_SLOT_HOV))
	btn.add_theme_stylebox_override("pressed", _flat_sb(BG_SLOT_SEL))
	# Gold text when the quest is ready to hand in; warm cream otherwise.
	var col := TEXT_GOLD if ready_to_turnin else TEXT_WARM
	btn.add_theme_color_override("font_color",         col)
	btn.add_theme_color_override("font_hover_color",   col.lightened(0.10))
	btn.add_theme_color_override("font_pressed_color", col)
	btn.pressed.connect(func() -> void:
		_selected_qid = qid
		_refresh())
	return btn

func _rebuild_detail() -> void:
	for c: Node in _detail_root.get_children():
		c.queue_free()

	if _selected_qid == "":
		var empty := Label.new()
		empty.text = "Select a quest from the list."
		empty.add_theme_color_override("font_color", TEXT_DIM)
		empty.add_theme_font_size_override("font_size", 12)
		_detail_root.add_child(empty)
		return

	var def: Dictionary = QuestData.data(_selected_qid)
	if def.is_empty():
		var unknown := Label.new()
		unknown.text = "Unknown quest: %s" % _selected_qid
		unknown.add_theme_color_override("font_color", TEXT_DIM)
		_detail_root.add_child(unknown)
		return

	# ── Quest title (large gold) ──
	var title := Label.new()
	title.text = str(def.get("title", ""))
	title.add_theme_color_override("font_color", TEXT_GOLD)
	title.add_theme_font_size_override("font_size", 18)
	_detail_root.add_child(title)

	# Tag chip line (Daily / Repeatable / Boss)
	var tags: Array[String] = []
	if bool(def.get("daily", false)):      tags.append("Daily")
	if bool(def.get("repeatable", false)): tags.append("Repeatable")
	if bool(def.get("boss", false)):       tags.append("Boss")
	if tags.size() > 0:
		var tag_lbl := Label.new()
		tag_lbl.text = "  ·  ".join(tags)
		tag_lbl.add_theme_color_override("font_color", TEXT_DIM)
		tag_lbl.add_theme_font_size_override("font_size", 10)
		_detail_root.add_child(tag_lbl)

	# Giver NPC
	var giver := Label.new()
	giver.text = "Given by: %s" % str(def.get("giver_npc", "?"))
	giver.add_theme_color_override("font_color", TEXT_DIM)
	giver.add_theme_font_size_override("font_size", 11)
	_detail_root.add_child(giver)

	_detail_root.add_child(_thin_divider())

	# ── Description (scrollable) ──
	var desc_scroll := ScrollContainer.new()
	desc_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_scroll.custom_minimum_size   = Vector2(0, 80)
	desc_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_root.add_child(desc_scroll)
	var desc := Label.new()
	desc.text = str(def.get("description", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.add_theme_color_override("font_color", TEXT_WARM)
	desc.add_theme_font_size_override("font_size", 12)
	desc_scroll.add_child(desc)

	_detail_root.add_child(_thin_divider())

	# ── Objectives ──
	_detail_root.add_child(_make_section_label("Objectives"))
	var objs: Array = def.get("objectives", [])
	for i in range(objs.size()):
		_detail_root.add_child(_make_objective_row(objs[i] as Dictionary, i))

	_detail_root.add_child(_thin_divider())

	# ── Rewards ──
	_detail_root.add_child(_make_section_label("Rewards"))
	_detail_root.add_child(_make_rewards_block(def))

	# ── Spacer to push the abandon button to the bottom ──
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_root.add_child(spacer)

	# ── Abandon button ──
	var abandon_row := HBoxContainer.new()
	_detail_root.add_child(abandon_row)
	var abandon := Button.new()
	abandon.text = "Abandon Quest"
	abandon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	abandon.add_theme_stylebox_override("normal",
		_flat_sb(VikingPanelScene.TINT_COMBAT.darkened(0.50)))
	abandon.add_theme_stylebox_override("hover",
		_flat_sb(VikingPanelScene.TINT_COMBAT.darkened(0.30)))
	abandon.add_theme_stylebox_override("pressed",
		_flat_sb(VikingPanelScene.TINT_COMBAT.darkened(0.10)))
	abandon.add_theme_color_override("font_color", TEXT_WARM)
	abandon.add_theme_font_size_override("font_size", 12)
	abandon.pressed.connect(func() -> void: _on_abandon_pressed())
	abandon_row.add_child(abandon)

func _make_objective_row(obj: Dictionary, idx: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var need := int(obj.get("quantity", 1))
	var have := GameManager.quest_objective_progress(_selected_qid, idx)
	var done := have >= need
	# Checkbox glyph.
	var box := Label.new()
	box.text = "✔" if done else "☐"
	box.add_theme_color_override("font_color", TEXT_GREEN if done else TEXT_DIM)
	box.add_theme_font_size_override("font_size", 14)
	row.add_child(box)
	# Display name.
	var name_lbl := Label.new()
	name_lbl.text = str(obj.get("display", ""))
	name_lbl.add_theme_color_override("font_color",
		TEXT_GREEN if done else TEXT_WARM)
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	# Count.
	var count := Label.new()
	count.text = "%d / %d" % [have, need]
	count.add_theme_color_override("font_color",
		TEXT_GREEN if done else TEXT_GOLD)
	count.add_theme_font_size_override("font_size", 12)
	row.add_child(count)
	return row

## Rewards row: gold pill + each item as icon + qty. XP listed below (rewards
## always include XP; gold + items may be present or absent depending on the
## quest's boss flag and prior completion count).
func _make_rewards_block(def: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	var rewards: Dictionary = def.get("rewards", {})

	# Gold pill.
	var gold_amount := int(rewards.get("gold", 0))
	if gold_amount > 0:
		var gold_row := HBoxContainer.new()
		gold_row.add_theme_constant_override("separation", 4)
		var gold_dot := ColorRect.new()
		gold_dot.custom_minimum_size = Vector2(14, 14)
		gold_dot.color = TEXT_GOLD
		gold_row.add_child(gold_dot)
		var gold_lbl := Label.new()
		gold_lbl.text = "%d Gold" % gold_amount
		gold_lbl.add_theme_color_override("font_color", TEXT_GOLD)
		gold_lbl.add_theme_font_size_override("font_size", 12)
		gold_row.add_child(gold_lbl)
		col.add_child(gold_row)

	# Items — each gets an icon (or color tile fallback) + quantity.
	var items: Array = rewards.get("items", [])
	for it: Variant in items:
		if not (it is Dictionary):
			continue
		col.add_child(_make_reward_item_row(it as Dictionary))

	# XP block — usually multiple skills.
	var xp_dict: Dictionary = rewards.get("xp", {})
	for skill: Variant in xp_dict.keys():
		var n := int(xp_dict[skill])
		var xp_row := HBoxContainer.new()
		xp_row.add_theme_constant_override("separation", 4)
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(10, 10)
		dot.color = TEXT_DIM
		xp_row.add_child(dot)
		var xp_lbl := Label.new()
		xp_lbl.text = "+%d %s XP" % [n, str(skill).capitalize()]
		xp_lbl.add_theme_color_override("font_color", TEXT_WARM)
		xp_lbl.add_theme_font_size_override("font_size", 11)
		xp_row.add_child(xp_lbl)
		col.add_child(xp_row)

	# Boss-repeat note — only relevant on repeatable boss quests that have
	# been completed at least once. The actual server-side rule strips gold
	# and items on the second+ completion; we surface this in the UI.
	if bool(def.get("boss", false)) and bool(def.get("repeatable", false)):
		var counts: Dictionary = GameManager.server_completion_counts
		if int(counts.get(_selected_qid, 0)) >= 1:
			var note := Label.new()
			note.text = "(Repeat: XP only — gold and items already claimed.)"
			note.add_theme_color_override("font_color", TEXT_DIM)
			note.add_theme_font_size_override("font_size", 10)
			col.add_child(note)
	return col

func _make_reward_item_row(it: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var iid: String = str(it.get("id", ""))
	var qty: int    = int(it.get("qty", 1))
	# Try the generated icon first; fall back to a color tile.
	var ipath := "res://assets/icons/%s.png" % iid
	if ResourceLoader.exists(ipath):
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(24, 24)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = load(ipath) as Texture2D
		row.add_child(icon)
	else:
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(20, 20)
		var col_v: Variant = it.get("color", [0.7, 0.7, 0.7, 1.0])
		var col: Color = Color(0.7, 0.7, 0.7)
		if col_v is Array and (col_v as Array).size() >= 3:
			var ca := col_v as Array
			col = Color(float(ca[0]), float(ca[1]), float(ca[2]),
				float(ca[3]) if ca.size() >= 4 else 1.0)
		dot.color = col
		row.add_child(dot)
	var name_lbl := Label.new()
	name_lbl.text = "%d × %s" % [qty, str(it.get("name", iid))]
	name_lbl.add_theme_color_override("font_color", TEXT_WARM)
	name_lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(name_lbl)
	return row

func _on_abandon_pressed() -> void:
	if _selected_qid == "":
		return
	NetworkManager.send_quest_abandon(_selected_qid)
	# Server pushes quest_state back; _on_state_changed → _refresh will
	# rebuild the list once the row is gone. No need to mutate locally.

# ── Style helpers ────────────────────────────────────────────────────────────
func _flat_sb(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(2)
	s.set_border_width_all(1)
	s.border_color = VikingPanelScene.KNOT_BRONZE.darkened(0.20)
	s.content_margin_left = 6.0
	s.content_margin_right = 6.0
	s.content_margin_top = 3.0
	s.content_margin_bottom = 3.0
	return s

func _make_section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", TEXT_GOLD)
	lbl.add_theme_font_size_override("font_size", 13)
	return lbl

func _thin_divider() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("color",
		VikingPanelScene.KNOT_BRONZE.darkened(0.30))
	return sep
