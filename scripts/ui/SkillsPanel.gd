extends VBoxContainer

## Skills tab — extracted from HUD.gd into its own scene (scenes/ui/skills_panel.tscn).
## Self-contained: builds its grid in _ready, refreshes on Events.xp_gained, and
## emits Events.skill_cell_pressed so HUD keeps ownership of the windows a cell opens.

const UITheme = preload("res://scripts/ui/UITheme.gd")
# VikingTheme uses `class_name VikingTheme` — globally available, no
# preload const needed (would shadow the class_name symbol).

const _ICONS: Dictionary = {
	"woodcutting": "🪓", "mining": "⛏", "fishing": "🎣", "foraging": "🌿",
	"smithing": "🔨", "cooking": "🍖", "crafting": "💎", "construction": "🏗",
	"farming": "🌱",
	"melee": "⚔", "ranged": "🏹", "magic": "✨", "defense": "🛡",
	"vitality": "❤", "soul": "🦴",
}
const _SHORT: Dictionary = {
	"woodcutting": "Woodcut.", "mining": "Mining", "fishing": "Fishing",
	"foraging": "Forage", "smithing": "Smithing", "cooking": "Cooking",
	"crafting": "Crafting", "construction": "Constr.", "farming": "Farming",
	"melee": "Melee", "ranged": "Ranged", "magic": "Magic",
	"defense": "Defense", "vitality": "Vitality", "soul": "Soul",
}

var _skill_rows: Dictionary = {}   # skill → {cell, bar, lbl}
var _total_lbl: Label = null

func _ready() -> void:
	add_theme_constant_override("separation", 2)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build()
	Events.xp_gained.connect(func(_s: String, _a: int) -> void: _refresh())
	visibility_changed.connect(func() -> void:
		if visible:
			_refresh())

func _build() -> void:
	add_child(VikingTheme.section_header("Skills", 14))
	add_child(VikingTheme.divider())

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(grid)

	for skill: String in GameManager.player_skill_xp.keys():
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", UITheme.sb(UITheme.BTN_N, UITheme.BORDER.darkened(0.5), 1))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 3)
		cell.add_child(hbox)

		var ico := Label.new()
		ico.text = _ICONS.get(skill, "•")
		ico.custom_minimum_size = Vector2(16, 0)
		ico.add_theme_font_size_override("font_size", 11)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(ico)

		var vbox := VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 0)
		vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(vbox)

		var name_lbl := Label.new()
		name_lbl.text = _SHORT.get(skill, skill.capitalize())
		name_lbl.add_theme_color_override("font_color", UITheme.DIM)
		name_lbl.add_theme_font_size_override("font_size", 7)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(name_lbl)

		var lv := GameManager.get_skill_level(skill)
		var lv_lbl := Label.new()
		lv_lbl.text = "%d/99" % lv
		lv_lbl.add_theme_color_override("font_color", UITheme.GOLD)
		lv_lbl.add_theme_font_size_override("font_size", 10)
		lv_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(lv_lbl)

		var bar := ProgressBar.new()
		bar.max_value       = 1000
		bar.value           = int(GameManager.get_level_progress(skill) * 1000)
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 3)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.mouse_filter    = Control.MOUSE_FILTER_IGNORE
		bar.add_theme_stylebox_override("fill",       UITheme.sb(UITheme.GREEN.darkened(0.25), UITheme.GREEN, 0))
		bar.add_theme_stylebox_override("background", UITheme.sb(Color(0.05, 0.05, 0.05), UITheme.BORDER.darkened(0.6), 0))
		vbox.add_child(bar)

		cell.tooltip_text = _skill_tooltip(skill)
		cell.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		cell.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
					and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				Events.skill_cell_pressed.emit(skill))
		_skill_rows[skill] = {"cell": cell, "bar": bar, "lbl": lv_lbl}
		grid.add_child(cell)

	add_child(HSeparator.new())

	var total_row := HBoxContainer.new()
	total_row.add_theme_constant_override("separation", 6)
	add_child(total_row)
	var star := Label.new()
	star.text = "★"
	star.add_theme_color_override("font_color", UITheme.GOLD)
	star.add_theme_font_size_override("font_size", 14)
	total_row.add_child(star)
	_total_lbl = Label.new()
	_total_lbl.add_theme_color_override("font_color", UITheme.TEXT)
	_total_lbl.add_theme_font_size_override("font_size", 11)
	total_row.add_child(_total_lbl)
	_refresh()

func _refresh() -> void:
	for skill: String in _skill_rows.keys():
		var lv  := GameManager.get_skill_level(skill)
		var row: Dictionary = _skill_rows[skill]
		(row["lbl"]  as Label).text        = "%d/99" % lv
		(row["bar"]  as ProgressBar).value = int(GameManager.get_level_progress(skill) * 1000)
		(row["cell"] as PanelContainer).tooltip_text = _skill_tooltip(skill)
	if _total_lbl != null:
		_total_lbl.text = "Total Level:  %d / %d" % [_total_level(), GameManager.player_skill_xp.size() * 99]

func _total_level() -> int:
	var t := 0
	for skill: String in GameManager.player_skill_xp.keys():
		t += GameManager.get_skill_level(skill)
	return t

func _skill_tooltip(skill: String) -> String:
	var xp := GameManager.get_skill_xp(skill)
	var lv := GameManager.get_skill_level(skill)
	if lv >= 99:
		return "%s — Max Level!\nTotal XP: %d" % [skill.capitalize(), xp]
	var to_next := GameManager.get_xp_to_next_level(skill)
	var next_xp: int = GameManager.xp_for_level(lv + 1)
	return "%s  (Lv %d)\nXP: %d / %d\n%d XP to next level" % [
		skill.capitalize(), lv, xp, next_xp, to_next]
