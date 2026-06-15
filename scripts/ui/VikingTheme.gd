extends RefCounted
class_name VikingTheme

## ── VikingTheme ─────────────────────────────────────────────────────────────
##
## Stateless helper for applying the QuestLog-grade Norse panel chrome to
## any UI piece. The full VikingPanel class (scripts/ui/VikingPanel.gd)
## remains the right choice for modal popups (QuestLog, QuestDialog).
##
## This helper exists because most in-game panels (SkillsPanel, SettingsPanel,
## Inventory rows, etc.) extend VBoxContainer for HUD tab-bar wiring
## reasons — they can't simply change their base class without breaking
## the parent layout. So instead we give them a consistent "skin" via
## helpers:
##
##   * VikingTheme.section_header(text)   — gold band title
##   * VikingTheme.section_card(child)    — wraps a Control in a bordered card
##   * VikingTheme.divider()              — Norse-styled HSeparator
##   * VikingTheme.apply_button(btn)      — full button skin (primary/secondary)
##   * VikingTheme.apply_field(line_edit) — line-edit skin
##
## Goal: every panel ends up looking like it came from the same workshop
## without anyone having to memorize stylebox colors.

const BG       := Color(0.11, 0.07, 0.03)
const BG_DEEP  := Color(0.06, 0.04, 0.02)
const BG_CARD  := Color(0.09, 0.06, 0.03)
const BORDER   := Color(0.64, 0.49, 0.14)
const BORDER_D := Color(0.40, 0.30, 0.10)
const BTN_N    := Color(0.08, 0.05, 0.02)
const BTN_H    := Color(0.20, 0.13, 0.05)
const BTN_A    := Color(0.32, 0.20, 0.07)
const TEXT     := Color(0.92, 0.85, 0.62)
const DIM      := Color(0.60, 0.55, 0.38)
const GOLD     := Color(1.00, 0.85, 0.25)
const RED      := Color(0.90, 0.30, 0.20)
const GREEN    := Color(0.35, 0.88, 0.40)


static func _sb(bg: Color, border: Color, border_w: int = 2,
		radius: int = 2) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(border_w)
	s.border_color = border
	s.content_margin_left = 8.0
	s.content_margin_right = 8.0
	s.content_margin_top = 6.0
	s.content_margin_bottom = 6.0
	return s


## Gold section header label — bigger than a plain Label, themed gold.
static func section_header(text: String, size: int = 13) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", GOLD)
	l.add_theme_font_size_override("font_size", size)
	return l


## Subdued body text — what most labels in a panel should look like.
static func body(text: String, size: int = 11) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", TEXT)
	l.add_theme_font_size_override("font_size", size)
	return l


## Dimmed caption — small, lower-priority info.
static func caption(text: String, size: int = 10) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", DIM)
	l.add_theme_font_size_override("font_size", size)
	return l


## Norse-styled separator. Thinner than default, bronze-gold tint.
static func divider() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", BORDER.darkened(0.35))
	return sep


## Card wrapper — a bordered PanelContainer holding `child`. Use this
## anywhere a panel has multiple discrete sections (Settings: Volume,
## Account, Logout). The card makes sections visually distinct.
static func card(child: Control) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", _sb(BG_CARD, BORDER_D, 1, 3))
	pc.add_child(child)
	return pc


## Apply a uniform button skin. `primary=true` = bold gold accent (the
## "main action" of a panel). Otherwise the neutral bronze look. Both
## share the same hover lift.
static func apply_button(btn: Button, primary: bool = false) -> void:
	var n_bg := BTN_N
	var h_bg := BTN_H
	var p_bg := BTN_A
	var n_border := BORDER if primary else BORDER_D
	var fg := GOLD if primary else TEXT
	btn.add_theme_stylebox_override("normal",  _sb(n_bg, n_border, 2))
	btn.add_theme_stylebox_override("hover",   _sb(h_bg, GOLD, 2))
	btn.add_theme_stylebox_override("pressed", _sb(p_bg, GOLD, 2))
	btn.add_theme_stylebox_override("disabled", _sb(BG, BORDER_D.darkened(0.4), 1))
	btn.add_theme_color_override("font_color", fg)
	btn.add_theme_color_override("font_disabled_color", DIM)
	btn.add_theme_font_size_override("font_size", 11)


## Apply a uniform LineEdit / TextEdit field skin.
static func apply_field(field: LineEdit) -> void:
	field.add_theme_stylebox_override("normal", _sb(BTN_N, BORDER_D, 1))
	field.add_theme_stylebox_override("focus",  _sb(BTN_N, GOLD, 1))
	field.add_theme_color_override("font_color", TEXT)
	field.add_theme_color_override("caret_color", GOLD)
	field.add_theme_color_override("font_placeholder_color", DIM)
	field.add_theme_font_size_override("font_size", 11)


## Apply the standard panel chrome to a PanelContainer (background + gold
## border + padding). Mostly useful for non-tabbed standalone overlays.
static func apply_panel(panel: PanelContainer, tint: String = "default") -> void:
	var border := GOLD if tint == "primary" else BORDER
	panel.add_theme_stylebox_override("panel", _sb(BG_DEEP, border, 3, 3))
