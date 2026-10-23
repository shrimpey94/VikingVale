extends Node2D

## World-space speech bubble (Phase 9). Added as a child named "ChatBubble" of a
## Player / OtherPlayer node so it rides along above their head, then fades out
## after a few seconds. The BACKGROUND is 65% transparent (alpha 0.35) per spec;
## the text stays opaque for legibility. Re-`setup()` an existing bubble to
## replace its text + reset the timer (one bubble per speaker).

const LIFETIME    := 5.0      # total seconds before it frees
const FADE_START  := 3.6      # begins fading here → gone at LIFETIME
const ANCHOR_Y    := -52.0    # tail tip sits this far above the node origin
const FONT_SIZE   := 11
const MAX_WIDTH   := 168.0    # wrap width in px
const PAD         := 6.0

var _text: String = ""
var _life: float = 0.0

func setup(text: String) -> void:
	_text = text.strip_edges()
	_life = 0.0
	position = Vector2(0.0, ANCHOR_Y)
	z_index = 400            # above characters / world sprites
	z_as_relative = false
	modulate.a = 1.0
	queue_redraw()

func _process(delta: float) -> void:
	_life += delta
	if _life >= LIFETIME:
		queue_free()
		return
	if _life > FADE_START:
		modulate.a = clampf(1.0 - (_life - FADE_START) / (LIFETIME - FADE_START), 0.0, 1.0)
		queue_redraw()

func _draw() -> void:
	if _text == "":
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var block := font.get_multiline_string_size(
		_text, HORIZONTAL_ALIGNMENT_CENTER, MAX_WIDTH, FONT_SIZE)
	var w := block.x + PAD * 2.0
	var h := block.y + PAD * 2.0
	# Box grows UPWARD from the anchor (y=0 = tail tip, head is below).
	var rect := Rect2(-w * 0.5, -h - 4.0, w, h)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.06, 0.03, 0.35)          # 65% transparent
	sb.set_corner_radius_all(6)
	sb.border_color = Color(0.64, 0.49, 0.14, 0.55)
	sb.set_border_width_all(1)
	draw_style_box(sb, rect)
	# Little downward tail from the box to the head.
	draw_colored_polygon(
		PackedVector2Array([Vector2(-5.0, -5.0), Vector2(5.0, -5.0), Vector2(0.0, 1.0)]),
		Color(0.08, 0.06, 0.03, 0.35))
	# Text — opaque, centered, wrapped to the block width so it matches the box.
	draw_multiline_string(font, Vector2(-block.x * 0.5, rect.position.y + PAD + font.get_ascent(FONT_SIZE)),
		_text, HORIZONTAL_ALIGNMENT_CENTER, block.x + 1.0, FONT_SIZE, -1,
		Color(0.98, 0.94, 0.80, 1.0))
