extends Control
class_name VikingPanel

## Norse-themed panel wrapper — the universal style for VikingVale panels,
## modals, shops, lists, tabs, and windows. Everything is drawn procedurally
## in _draw() with no image files, so it scales gracefully from small
## tooltips to large shop windows.
##
## Usage:
##   var panel := VikingPanel.new()
##   panel.title = "Smithing"
##   panel.tint  = VikingPanel.Tint.SHOP
##   panel.size  = Vector2(320, 280)
##   add_child(panel)
##   panel.content.add_child(my_vbox)
##
## `content` is a MarginContainer anchored to fill the body region (below the
## header bar, inside the decorative border). Add UI children there.

enum Tint { DEFAULT, SHOP, COMBAT, MAGIC, QUEST }

# ── Layout constants ─────────────────────────────────────────────────────────
const HEADER_HEIGHT      := 28      # px from top of panel to bottom of header bar
const CORNER_SIZE        := 18      # bounding box of each corner knot, in px
const EDGE_INSET         := 6       # how far the edge pattern sits from the panel rim
const CONTENT_MARGIN     := 12      # gap between border art and content area
const MIN_WIDTH          := 200
const MIN_HEIGHT         := 150
const EDGE_DIAMOND_GAP   := 18      # spacing between diamonds along the long edges
const DIVIDER_DIAMOND_GAP := 20     # spacing for the header divider chain

# ── Palette ──────────────────────────────────────────────────────────────────
const BG_COLOR     := Color(0.165, 0.102, 0.055)   # #2A1A0E aged wood
const HEADER_BG    := Color(0.102, 0.055, 0.024)   # #1A0E06 darker brown
const KNOT_GOLD    := Color(0.784, 0.588, 0.243)   # #C8963E aged gold
const KNOT_BRONZE  := Color(0.545, 0.412, 0.078)   # #8B6914 worn bronze
const RIVET        := Color(0.361, 0.290, 0.165)   # #5C4A2A dark iron
const TEXT_COLOR   := Color(0.910, 0.835, 0.640)   # #E8D5A3 warm cream

# ── Tint overrides ───────────────────────────────────────────────────────────
const TINT_SHOP    := Color(0.957, 0.776, 0.298)   # brighter gold
const TINT_COMBAT  := Color(0.545, 0.227, 0.227)   # #8B3A3A red-bronze
const TINT_MAGIC   := Color(0.353, 0.227, 0.545)   # #5A3A8B purple-bronze
const TINT_QUEST   := Color(0.227, 0.420, 0.227)   # #3A6B3A green-bronze

# ── Public properties ────────────────────────────────────────────────────────
@export var title: String = "":
	set(v):
		title = v
		queue_redraw()

@export var tint: Tint = Tint.DEFAULT:
	set(v):
		tint = v
		queue_redraw()

## MarginContainer where panel users attach their content. Anchored to fill
## the body region; children resize with the panel automatically.
var content: MarginContainer = null

func _ready() -> void:
	custom_minimum_size = Vector2(MIN_WIDTH, MIN_HEIGHT)
	_build_content_root()
	resized.connect(queue_redraw)

func _build_content_root() -> void:
	content = MarginContainer.new()
	content.anchor_left   = 0.0; content.anchor_right  = 1.0
	content.anchor_top    = 0.0; content.anchor_bottom = 1.0
	content.offset_left   = CONTENT_MARGIN
	content.offset_right  = -CONTENT_MARGIN
	content.offset_top    = HEADER_HEIGHT + 4
	content.offset_bottom = -CONTENT_MARGIN
	add_child(content)

## Returns the knotwork color for the current tint variant — used both for
## the corner knots and the edge chain so the whole frame stays cohesive.
func _knot_color() -> Color:
	match tint:
		Tint.SHOP:   return TINT_SHOP
		Tint.COMBAT: return TINT_COMBAT
		Tint.MAGIC:  return TINT_MAGIC
		Tint.QUEST:  return TINT_QUEST
		_:           return KNOT_GOLD

## Tint-aware bronze accent — sits half-way between the tint color and the
## base bronze so knot interweaves still read as two strands.
func _accent_color() -> Color:
	if tint == Tint.DEFAULT:
		return KNOT_BRONZE
	return _knot_color().darkened(0.40)

# ─────────────────────────────────────────────────────────────────────────────
# DRAW
# ─────────────────────────────────────────────────────────────────────────────
func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 4.0 or h < 4.0:
		return

	# Body background + 1px inner shadow to give the wood a small bevel.
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
	draw_rect(Rect2(Vector2(1, 1), size - Vector2(2, 2)),
		BG_COLOR.lightened(0.04), false, 1.0)

	# Header bar (darker rect from y=0 to HEADER_HEIGHT).
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, float(HEADER_HEIGHT))), HEADER_BG)

	# Header rune-chain divider just below the header.
	_draw_chain_divider(float(HEADER_HEIGHT))

	# Decorative border: edges first, then corners overlay on top.
	_draw_edge_pattern_top()
	_draw_edge_pattern_bottom()
	_draw_edge_pattern_left()
	_draw_edge_pattern_right()

	_draw_corner_knot(0)   # top-left
	_draw_corner_knot(1)   # top-right
	_draw_corner_knot(2)   # bottom-right
	_draw_corner_knot(3)   # bottom-left

	# Rivets at the four corners + midpoints for large panels.
	_draw_rivets()

	# Title centered in the header.
	if title != "":
		var font := ThemeDB.fallback_font
		var fs := 13
		var ts := font.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
		var tx := (w - ts.x) * 0.5
		var ty := (float(HEADER_HEIGHT) + float(fs)) * 0.5 + 1.0
		draw_string(font, Vector2(tx, ty), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT_COLOR)

# ── Corner knotwork ──────────────────────────────────────────────────────────
## quadrant: 0=TL, 1=TR, 2=BR, 3=BL. Each corner is an L-shape of two
## interlocking strands. The strands cross at the corner tip and curl
## inward into a small terminal loop where they meet the edge pattern.
func _draw_corner_knot(quadrant: int) -> void:
	var gold := _knot_color()
	var bronze := _accent_color()
	var w := size.x
	var h := size.y
	var s := float(CORNER_SIZE)
	var inset := float(EDGE_INSET)

	# Origin = the corner tip pixel; sx/sy = direction multipliers (1 or -1).
	var ox: float; var oy: float; var sx: float; var sy: float
	match quadrant:
		0: ox = 0.0;  oy = 0.0;  sx = 1.0;  sy = 1.0
		1: ox = w;    oy = 0.0;  sx = -1.0; sy = 1.0
		2: ox = w;    oy = h;    sx = -1.0; sy = -1.0
		_: ox = 0.0;  oy = h;    sx = 1.0;  sy = -1.0

	# OUTER strand — runs along the rim and forms the visible L.
	# Two segments meeting at the corner tip just inside the rim.
	var p_tip := Vector2(ox + sx * inset, oy + sy * inset)
	var p_h_end := Vector2(ox + sx * s,   oy + sy * inset)
	var p_v_end := Vector2(ox + sx * inset, oy + sy * s)
	draw_line(p_tip, p_h_end, gold, 2.0)
	draw_line(p_tip, p_v_end, gold, 2.0)

	# INNER strand — offset 4px in from the outer, slightly thinner. Renders
	# the over/under braid where it crosses the outer at the corner.
	var oi := inset + 4.0
	var p_itip := Vector2(ox + sx * oi, oy + sy * oi)
	var p_ih_end := Vector2(ox + sx * (s - 1.0), oy + sy * oi)
	var p_iv_end := Vector2(ox + sx * oi, oy + sy * (s - 1.0))
	draw_line(p_itip, p_ih_end, bronze, 1.5)
	draw_line(p_itip, p_iv_end, bronze, 1.5)

	# Terminal loops — small arcs where each strand curls inward into a knob.
	# These give the knot a finished look instead of looking like cut lines.
	_draw_terminal_loop(p_h_end, sy, gold)
	_draw_terminal_loop_vertical(p_v_end, sx, gold)
	_draw_terminal_loop(p_ih_end, sy, bronze)
	_draw_terminal_loop_vertical(p_iv_end, sx, bronze)

	# Center weave — a tiny diamond where the strands cross at the corner.
	_draw_diamond(p_tip + Vector2(sx * 2.0, sy * 2.0), 2.0, gold)

## Curling terminal cap: a half-arc going INWARD from a horizontal strand.
## `vertical_sign` decides whether the arc curls up or down.
func _draw_terminal_loop(p: Vector2, vertical_sign: float, c: Color) -> void:
	var r := 2.5
	var center := p + Vector2(0.0, vertical_sign * r)
	draw_arc(center, r, -PI * 0.5 if vertical_sign > 0.0 else PI * 0.5,
		PI * 0.5 if vertical_sign > 0.0 else PI * 1.5,
		10, c, 1.5)

## Same as _draw_terminal_loop but for vertical strands. `horizontal_sign`
## decides which side the cap curls toward.
func _draw_terminal_loop_vertical(p: Vector2, horizontal_sign: float, c: Color) -> void:
	var r := 2.5
	var center := p + Vector2(horizontal_sign * r, 0.0)
	draw_arc(center, r,
		0.0 if horizontal_sign > 0.0 else PI,
		PI if horizontal_sign > 0.0 else TAU,
		10, c, 1.5)

# ── Edge patterns ────────────────────────────────────────────────────────────
## Repeating chain of small diamonds connected by thin lines along each edge,
## skipping the corner zones so the knotwork doesn't clash with the chain.
func _draw_edge_pattern_top() -> void:
	var y := float(EDGE_INSET) + 1.0
	var start_x := float(CORNER_SIZE) + 4.0
	var end_x := size.x - float(CORNER_SIZE) - 4.0
	_draw_diamond_chain(Vector2(start_x, y), Vector2(end_x, y), true)

func _draw_edge_pattern_bottom() -> void:
	var y := size.y - float(EDGE_INSET) - 1.0
	var start_x := float(CORNER_SIZE) + 4.0
	var end_x := size.x - float(CORNER_SIZE) - 4.0
	_draw_diamond_chain(Vector2(start_x, y), Vector2(end_x, y), true)

func _draw_edge_pattern_left() -> void:
	var x := float(EDGE_INSET) + 1.0
	# Don't overlap the header divider.
	var start_y := float(HEADER_HEIGHT) + 6.0
	var end_y := size.y - float(CORNER_SIZE) - 4.0
	if end_y - start_y < EDGE_DIAMOND_GAP:
		return
	_draw_diamond_chain(Vector2(x, start_y), Vector2(x, end_y), false)

func _draw_edge_pattern_right() -> void:
	var x := size.x - float(EDGE_INSET) - 1.0
	var start_y := float(HEADER_HEIGHT) + 6.0
	var end_y := size.y - float(CORNER_SIZE) - 4.0
	if end_y - start_y < EDGE_DIAMOND_GAP:
		return
	_draw_diamond_chain(Vector2(x, start_y), Vector2(x, end_y), false)

## Walks from `a` to `b` painting a thin line + evenly-spaced diamonds. Uses
## the tint's knot color so all decorations are visually unified.
func _draw_diamond_chain(a: Vector2, b: Vector2, horizontal: bool) -> void:
	var gold := _knot_color()
	# Thin connector line.
	draw_line(a, b, gold.darkened(0.20), 1.0)
	# Diamonds along the line.
	var d := 2.5
	if horizontal:
		var x := a.x + EDGE_DIAMOND_GAP * 0.5
		while x < b.x:
			_draw_diamond(Vector2(x, a.y), d, gold)
			x += EDGE_DIAMOND_GAP
	else:
		var y := a.y + EDGE_DIAMOND_GAP * 0.5
		while y < b.y:
			_draw_diamond(Vector2(a.x, y), d, gold)
			y += EDGE_DIAMOND_GAP

## Filled diamond (rotated square) centered at p, with radius r.
func _draw_diamond(p: Vector2, r: float, c: Color) -> void:
	var pts := PackedVector2Array([
		p + Vector2(0.0, -r), p + Vector2(r, 0.0),
		p + Vector2(0.0,  r), p + Vector2(-r, 0.0),
	])
	draw_colored_polygon(pts, c)

# ── Header divider ───────────────────────────────────────────────────────────
## Full-width chain pattern just below the header bar — main horizontal
## stroke with evenly-spaced larger diamonds, each diamond paired with a tiny
## center dot so the line reads as a stitched rune chain.
func _draw_chain_divider(y: float) -> void:
	var gold := _knot_color()
	var bronze := _accent_color()
	var x0 := float(EDGE_INSET) + 2.0
	var x1 := size.x - float(EDGE_INSET) - 2.0
	if x1 - x0 < DIVIDER_DIAMOND_GAP:
		return
	# Main line + drop shadow.
	draw_line(Vector2(x0, y + 0.5), Vector2(x1, y + 0.5), bronze, 1.0)
	draw_line(Vector2(x0, y - 0.5), Vector2(x1, y - 0.5), gold, 1.0)
	# Diamond + dot pattern.
	var x := x0 + DIVIDER_DIAMOND_GAP * 0.5
	while x < x1:
		_draw_diamond(Vector2(x, y), 3.5, gold)
		draw_circle(Vector2(x, y), 0.8, BG_COLOR)
		x += DIVIDER_DIAMOND_GAP

# ── Rivets ───────────────────────────────────────────────────────────────────
## Corner rivets always; long-edge midpoints get them too once the panel is
## big enough that empty edge runs would otherwise look bare.
func _draw_rivets() -> void:
	var r := 1.8
	var i := float(EDGE_INSET)
	var corners := [
		Vector2(i, i),
		Vector2(size.x - i, i),
		Vector2(i, size.y - i),
		Vector2(size.x - i, size.y - i),
	]
	for p: Vector2 in corners:
		draw_circle(p, r + 0.6, RIVET.darkened(0.30))   # outer dark ring
		draw_circle(p, r, RIVET)
		draw_circle(p + Vector2(-0.6, -0.6), 0.6,
			RIVET.lightened(0.50))                      # tiny specular dot

	# Midpoints for larger panels (only when the edge is meaningfully long).
	if size.x > 320.0:
		var mx := size.x * 0.5
		_paint_rivet(Vector2(mx, i), r)
		_paint_rivet(Vector2(mx, size.y - i), r)
	if size.y > 280.0:
		var my := size.y * 0.5
		_paint_rivet(Vector2(i, my), r)
		_paint_rivet(Vector2(size.x - i, my), r)

func _paint_rivet(p: Vector2, r: float) -> void:
	draw_circle(p, r + 0.6, RIVET.darkened(0.30))
	draw_circle(p, r, RIVET)
	draw_circle(p + Vector2(-0.6, -0.6), 0.6, RIVET.lightened(0.50))
