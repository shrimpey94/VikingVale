extends RefCounted

## Shared UI palette + builder helpers for the panel scenes under scenes/ui/.
## Used via `const UITheme = preload("res://scripts/ui/UITheme.gd")` (static),
## so panels don't depend on HUD.gd for styling. Mirrors HUD's palette/_rs.

const BG     := Color(0.11, 0.07, 0.03)
const BORDER := Color(0.64, 0.49, 0.14)
const BTN_N  := Color(0.08, 0.05, 0.02)
const BTN_A  := Color(0.20, 0.13, 0.05)
const BTN_H  := Color(0.15, 0.09, 0.03)
const TEXT   := Color(0.92, 0.85, 0.62)
const DIM    := Color(0.60, 0.55, 0.38)
const GOLD   := Color(1.00, 0.85, 0.25)
const GREEN  := Color(0.40, 0.90, 0.40)

## StyleBoxFlat with a border and 2px rounded corners (matches HUD._rs).
static func sb(bg: Color, border: Color, bw: int = 3) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_border_width_all(bw)
	s.border_color = border
	s.set_corner_radius_all(2)
	return s

## Centred gold panel title label (matches HUD._tab_title).
static func title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", GOLD)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl
