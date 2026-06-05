extends VBoxContainer

## Hiscores tab — extracted from HUD.gd (scenes/ui/rankings_panel.tscn).
## Static placeholder until real leaderboards land.

const UITheme = preload("res://scripts/ui/UITheme.gd")

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	add_child(UITheme.title("Hiscores"))
	add_child(HSeparator.new())

	var rows: Array[Array] = [
		["1.", "Busterrdust",  "1,980"],
		["2.", "Thrallmaster", "1,350"],
		["3.", "FjordRunner",    "842"],
	]
	for row_data: Array in rows:
		var row := HBoxContainer.new()
		for i in range(3):
			var lbl := Label.new()
			lbl.text = row_data[i]
			lbl.add_theme_font_size_override("font_size", 11)
			lbl.add_theme_color_override("font_color", UITheme.GOLD if i == 0 else UITheme.TEXT)
			lbl.custom_minimum_size = Vector2([20, 110, 50][i], 0)
			row.add_child(lbl)
		add_child(row)

	var note := Label.new()
	note.text = "\nFull leaderboards\ncoming soon."
	note.add_theme_color_override("font_color", UITheme.DIM)
	note.add_theme_font_size_override("font_size", 10)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(note)
