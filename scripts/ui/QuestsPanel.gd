extends VBoxContainer

## Quests tab — extracted from HUD.gd (scenes/ui/quests_panel.tscn).
## Self-contained: lists active quests from GameManager, refreshes on
## Events.quest_accepted / quest_updated.

const UITheme = preload("res://scripts/ui/UITheme.gd")

var _list: VBoxContainer = null

func _ready() -> void:
	add_theme_constant_override("separation", 6)
	add_child(UITheme.title("Quests"))
	add_child(HSeparator.new())
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	add_child(_list)
	Events.quest_accepted.connect(func(_id: String) -> void: _refresh())
	Events.quest_updated.connect(func(_id: String) -> void: _refresh())
	visibility_changed.connect(func() -> void:
		if visible:
			_refresh())
	_refresh()

func _refresh() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()

	var any := false
	for q: Dictionary in GameManager.QUESTS:
		var qid: String = q["id"] as String
		if not GameManager.active_quests.has(qid):
			continue
		any = true
		var aq: Dictionary = GameManager.active_quests[qid]
		var prog: int  = aq["progress"] as int
		var need: int  = q["qty"] as int
		var done: bool = aq["completed"] as bool

		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 2)

		var title_lbl := Label.new()
		title_lbl.text = ("[DONE]  " if done else "") + (q["title"] as String)
		title_lbl.add_theme_color_override("font_color", UITheme.GREEN if done else UITheme.GOLD)
		title_lbl.add_theme_font_size_override("font_size", 11)
		card.add_child(title_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = q["desc"] as String
		desc_lbl.add_theme_color_override("font_color", UITheme.DIM)
		desc_lbl.add_theme_font_size_override("font_size", 10)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card.add_child(desc_lbl)

		var prog_lbl := Label.new()
		prog_lbl.text = "Progress: %d / %d" % [prog, need]
		prog_lbl.add_theme_color_override("font_color", UITheme.TEXT)
		prog_lbl.add_theme_font_size_override("font_size", 10)
		card.add_child(prog_lbl)

		var bar := ProgressBar.new()
		bar.min_value = 0; bar.max_value = need; bar.value = prog
		bar.custom_minimum_size = Vector2(0, 8)
		bar.show_percentage = false
		card.add_child(bar)

		_list.add_child(card)
		_list.add_child(HSeparator.new())

	if not any:
		var hint := Label.new()
		hint.text = "Talk to Quest NPCs\n(marked with !) to\naccept quests."
		hint.add_theme_color_override("font_color", UITheme.DIM)
		hint.add_theme_font_size_override("font_size", 11)
		_list.add_child(hint)
