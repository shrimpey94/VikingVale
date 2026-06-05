class_name Appearance
extends RefCounted

## Single source of truth for character appearance: palettes, the default/sanitize
## helpers, and one programmatic draw routine shared by Player and OtherPlayer.
## Equipment overlays (helm/body/weapon) are layered on top via the `equip` param.

# ── Palettes ─────────────────────────────────────────────────────────────────
const SKIN_TONES: Array[Color] = [
	Color(0.96, 0.84, 0.70), Color(0.91, 0.76, 0.60), Color(0.87, 0.70, 0.52),
	Color(0.78, 0.60, 0.42), Color(0.66, 0.48, 0.32), Color(0.54, 0.38, 0.24),
	Color(0.42, 0.28, 0.18), Color(0.30, 0.20, 0.12),
]

const HAIR_COLORS: Array[Color] = [
	Color(0.10, 0.09, 0.10), Color(0.36, 0.22, 0.10), Color(0.85, 0.68, 0.30),
	Color(0.66, 0.20, 0.10), Color(0.55, 0.55, 0.58), Color(0.90, 0.90, 0.92),
	Color(0.22, 0.42, 0.82), Color(0.20, 0.62, 0.32),
]

const TUNIC_COLORS: Array[Color] = [
	Color(0.55, 0.14, 0.12), Color(0.20, 0.42, 0.66), Color(0.24, 0.50, 0.28),
	Color(0.55, 0.42, 0.14), Color(0.40, 0.24, 0.52), Color(0.32, 0.32, 0.36),
]

# Body half-width by body type (slim, medium, broad)
const BODY_HALF_W: Array[int] = [7, 8, 10]

const HAIR_STYLE_NAMES: Array[String] = ["Short", "Long", "Braided", "Mohawk", "Bald", "Ponytail"]
const HAIR_COLOR_NAMES: Array[String] = ["Black", "Brown", "Blonde", "Red", "Gray", "White", "Blue", "Green"]
const BEARD_NAMES:      Array[String] = ["None", "Short", "Long", "Braided", "Forked"]
const BODY_NAMES:       Array[String] = ["Slim", "Medium", "Broad"]

# ── Data helpers ─────────────────────────────────────────────────────────────
static func default() -> Dictionary:
	return {"skin": 2, "hair_style": 0, "hair_color": 1, "beard": 1, "body": 1, "tunic": 0}

static func sanitize(d: Variant) -> Dictionary:
	var src: Dictionary = d if d is Dictionary else {}
	var out := default()
	out["skin"]       = clampi(int(src.get("skin",       out["skin"])),       0, SKIN_TONES.size() - 1)
	out["hair_style"] = clampi(int(src.get("hair_style", out["hair_style"])), 0, HAIR_STYLE_NAMES.size() - 1)
	out["hair_color"] = clampi(int(src.get("hair_color", out["hair_color"])), 0, HAIR_COLORS.size() - 1)
	out["beard"]      = clampi(int(src.get("beard",      out["beard"])),      0, BEARD_NAMES.size() - 1)
	out["body"]       = clampi(int(src.get("body",       out["body"])),       0, BODY_HALF_W.size() - 1)
	out["tunic"]      = clampi(int(src.get("tunic",      out["tunic"])),      0, TUNIC_COLORS.size() - 1)
	return out

static func skin_of(a: Dictionary) -> Color:  return SKIN_TONES[clampi(int(a.get("skin", 2)), 0, SKIN_TONES.size() - 1)]
static func hair_of(a: Dictionary) -> Color:  return HAIR_COLORS[clampi(int(a.get("hair_color", 1)), 0, HAIR_COLORS.size() - 1)]
static func tunic_of(a: Dictionary) -> Color: return TUNIC_COLORS[clampi(int(a.get("tunic", 0)), 0, TUNIC_COLORS.size() - 1)]

# ══════════════════════════════════════════════════════════════════════════════
# DRAW
# ══════════════════════════════════════════════════════════════════════════════
## p keys (all optional):
##   walk_sw:float leg-swing offset · left_arm:float · right_arm:float
##   acting:bool · action_type:String · equip:Dictionary (equipment overlay)
static func draw_character(ci: CanvasItem, appr: Variant, p: Dictionary) -> void:
	var a := sanitize(appr)
	var skin  := skin_of(a)
	var hair  := hair_of(a)
	var tunic := tunic_of(a)
	var bw: int = BODY_HALF_W[clampi(int(a.get("body", 1)), 0, BODY_HALF_W.size() - 1)]
	var hair_style: int = int(a.get("hair_style", 0))
	var beard_style: int = int(a.get("beard", 1))

	var walk_sw: float    = float(p.get("walk_sw", 0.0))
	var left_arm: float   = float(p.get("left_arm", 0.0))
	var right_arm: float  = float(p.get("right_arm", 0.0))
	var acting: bool      = bool(p.get("acting", false))
	var action_type: String = str(p.get("action_type", ""))
	var equip: Dictionary = p.get("equip", {}) as Dictionary

	var leg_w := 6
	var left_leg_x := -bw + 1
	var right_leg_x := bw - 1 - leg_w
	var ll := walk_sw
	var rl := -walk_sw

	# Ground shadow
	ci.draw_circle(Vector2(0.0, 20.0), 11.0, Color(0.02, 0.02, 0.04, 0.28))

	# Dark silhouette outline
	var dark := Color(0.04, 0.04, 0.06, 0.80)
	ci.draw_rect(Rect2(-bw - 1, 6, (bw + 1) * 2, 14), dark)
	ci.draw_rect(Rect2(-bw - 1, -9, (bw + 1) * 2, 16), dark)
	ci.draw_circle(Vector2(0, -16), 10.5, dark)

	# Cape (tunic-derived, darkened)
	ci.draw_rect(Rect2(-bw + 1, -4, (bw - 1) * 2, 18), tunic.darkened(0.45))

	# Legs + boots (tinted by equipped gear when present)
	var c_trouser := Color(0.22, 0.18, 0.12)
	var c_boot := Color(0.16, 0.10, 0.04)
	if str(equip.get("legs", "")) != "":
		c_trouser = _gear_color(str(equip["legs"]))
	if str(equip.get("boots", "")) != "":
		c_boot = _gear_color(str(equip["boots"]))
	ci.draw_rect(Rect2(left_leg_x,  7 + ll, leg_w, 10), c_trouser)
	ci.draw_rect(Rect2(right_leg_x, 7 + rl, leg_w, 10), c_trouser)
	ci.draw_rect(Rect2(left_leg_x - 1,  15 + ll, leg_w + 1, 4), c_boot)
	ci.draw_rect(Rect2(right_leg_x,     15 + rl, leg_w + 1, 4), c_boot)

	# Left arm
	_draw_arm(ci, Vector2(-bw - 1, -6), left_arm, skin, false, "", {})

	# Off-hand shield (drawn over the left arm)
	if str(equip.get("offhand", "")) != "":
		var sc := _gear_color(str(equip["offhand"]))
		ci.draw_rect(Rect2(-bw - 5, -4, 6, 12), sc)
		ci.draw_rect(Rect2(-bw - 4, -3, 4, 10), sc.lightened(0.2))
		ci.draw_rect(Rect2(-bw - 3, 0, 2, 4), sc.darkened(0.3))

	# Torso (tunic)
	ci.draw_rect(Rect2(-bw, -8, bw * 2, 16), tunic)
	ci.draw_rect(Rect2(-bw + 2, -7, bw * 2 - 4, 8), tunic.lightened(0.18))
	ci.draw_rect(Rect2(-2, -8, 4, 16), tunic.darkened(0.12))
	ci.draw_rect(Rect2(-bw, 7, bw * 2, 3), Color(0.30, 0.18, 0.06))   # belt
	ci.draw_circle(Vector2(0, 8), 2.5, Color(0.78, 0.62, 0.12))       # buckle

	# Body armour overlay (equipment)
	if equip.get("body", "") != "":
		var bc := _gear_color(str(equip.get("body", "")))
		ci.draw_rect(Rect2(-bw, -8, bw * 2, 13), bc)
		ci.draw_rect(Rect2(-bw + 2, -7, bw * 2 - 4, 5), bc.lightened(0.22))

	# Head
	ci.draw_circle(Vector2(0, -16), 9, skin)
	ci.draw_circle(Vector2(-5, -14), 3, Color(0.90, 0.62, 0.52, 0.45))
	ci.draw_circle(Vector2( 5, -14), 3, Color(0.90, 0.62, 0.52, 0.45))

	# Beard (colored from hair)
	_draw_beard(ci, beard_style, hair)

	# Hair (skipped if a helm is equipped)
	var has_helm: bool = equip.get("head", "") != ""
	if not has_helm:
		_draw_hair(ci, hair_style, hair)

	# Helm overlay (equipment) — drawn before the eyes so the eyes stay visible.
	if has_helm:
		_draw_helm(ci, str(equip.get("head", "")))

	# Eyes (always on top, so an equipped helm never covers the face)
	ci.draw_circle(Vector2(-3, -17), 2.0, Color(0.08, 0.08, 0.08))
	ci.draw_circle(Vector2( 3, -17), 2.0, Color(0.08, 0.08, 0.08))
	ci.draw_circle(Vector2(-2, -18), 0.8, Color(1, 1, 1, 0.7))
	ci.draw_circle(Vector2( 4, -18), 0.8, Color(1, 1, 1, 0.7))

	# Right arm + weapon
	_draw_arm(ci, Vector2(bw + 1, -6), right_arm, skin, acting, action_type, equip)

# ── Arm + weapon ─────────────────────────────────────────────────────────────
static func _draw_arm(ci: CanvasItem, pivot: Vector2, angle: float, skin: Color,
		acting: bool, action_type: String, equip: Dictionary) -> void:
	ci.draw_set_transform(pivot, angle, Vector2.ONE)
	var c_rod := Color(0.48, 0.30, 0.08)
	var arm_col := c_rod if (acting and action_type == "fish") else skin
	ci.draw_rect(Rect2(-2.5, 0, 5, 12), arm_col)

	if acting:
		match action_type:
			"chop":
				ci.draw_rect(Rect2(1, 9, 7, 6), Color(0.72, 0.72, 0.75))
				ci.draw_rect(Rect2(7, 10, 2, 4), Color(0.68, 0.70, 0.72))
			"mine":
				ci.draw_rect(Rect2(-6, 10, 12, 3), Color(0.60, 0.60, 0.62))
				ci.draw_rect(Rect2(-7, 13, 4, 5), Color(0.60, 0.60, 0.62))
			"fish":
				ci.draw_rect(Rect2(-1, 12, 2, 10), c_rod)
				ci.draw_line(Vector2(0, 22), Vector2(5, 35), Color(0.85, 0.85, 0.85, 0.65), 1.0)
	elif equip.get("weapon", "") != "":
		# Idle equipped weapon held along the arm
		var wc := _gear_color(str(equip.get("weapon", "")))
		ci.draw_rect(Rect2(-1.5, 4, 3, 16), Color(0.30, 0.18, 0.06))  # haft
		ci.draw_rect(Rect2(-3, 16, 6, 6), wc)                          # head/blade

	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# ── Hair styles ──────────────────────────────────────────────────────────────
static func _draw_hair(ci: CanvasItem, style: int, hair: Color) -> void:
	match style:
		0:  # Short
			_hair_cap(ci, hair)
		1:  # Long
			_hair_cap(ci, hair)
			ci.draw_rect(Rect2(-11, -22, 3, 18), hair)
			ci.draw_rect(Rect2( 8, -22, 3, 18), hair)
		2:  # Braided
			_hair_cap(ci, hair)
			ci.draw_rect(Rect2(-11, -22, 3, 14), hair)
			for i in range(5):
				ci.draw_circle(Vector2(10, -12 + i * 4), 2.0, hair if i % 2 == 0 else hair.darkened(0.2))
		3:  # Mohawk
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-3, -24), Vector2(0, -32), Vector2(3, -24)]), hair)
			ci.draw_rect(Rect2(-3, -26, 6, 4), hair)
		4:  # Bald
			pass
		5:  # Ponytail
			_hair_cap(ci, hair)
			for i in range(5):
				ci.draw_circle(Vector2(9 + i, -20 + i * 3), 2.5 - i * 0.2, hair)

static func _hair_cap(ci: CanvasItem, hair: Color) -> void:
	# Dome that follows the top of the skull; front hairline stops just above
	# the eyes (eyes sit at y = -17) so hair never covers the face.
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(-8, -19), Vector2(-8, -23), Vector2(-4, -25.5),
		Vector2(0, -26), Vector2(4, -25.5), Vector2(8, -23), Vector2(8, -19),
	]), hair)
	# sideburns down the sides of the face (clear of the eyes at x = ±3)
	ci.draw_rect(Rect2(-9, -19, 2, 5), hair)
	ci.draw_rect(Rect2( 7, -19, 2, 5), hair)

# ── Beard styles ─────────────────────────────────────────────────────────────
static func _draw_beard(ci: CanvasItem, style: int, col: Color) -> void:
	match style:
		0:  # None
			pass
		1:  # Short
			ci.draw_rect(Rect2(-5, -12, 10, 6), col)
			ci.draw_circle(Vector2(0, -7), 3, col)
		2:  # Long
			ci.draw_rect(Rect2(-5, -12, 10, 9), col)
			ci.draw_circle(Vector2(0, -3), 4, col)
		3:  # Braided
			ci.draw_rect(Rect2(-5, -12, 10, 7), col)
			for i in range(3):
				ci.draw_circle(Vector2(-3, -4 + i * 3), 2.0, col if i % 2 == 0 else col.darkened(0.2))
				ci.draw_circle(Vector2( 3, -4 + i * 3), 2.0, col if i % 2 == 0 else col.darkened(0.2))
		4:  # Forked
			ci.draw_rect(Rect2(-5, -12, 10, 5), col)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-5, -7), Vector2(-1, -7), Vector2(-3, 0)]), col)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(1, -7), Vector2(5, -7), Vector2(3, 0)]), col)

# ── Equipment visual helpers ─────────────────────────────────────────────────
static func _draw_helm(ci: CanvasItem, item_id: String) -> void:
	var c := _gear_color(item_id)
	ci.draw_rect(Rect2(-9, -26, 18, 12), c)
	ci.draw_rect(Rect2(-7, -25, 14, 3), c.lightened(0.3))
	ci.draw_rect(Rect2(-1, -26, 2, 12), c.lightened(0.3))
	ci.draw_colored_polygon(PackedVector2Array([Vector2(-9,-22), Vector2(-15,-15), Vector2(-4,-15)]), c.lightened(0.2))
	ci.draw_colored_polygon(PackedVector2Array([Vector2(9,-22), Vector2(15,-15), Vector2(4,-15)]), c.lightened(0.2))

## Maps an equipment item_id to a representative color by metal/material tier.
static func _gear_color(item_id: String) -> Color:
	if item_id.begins_with("leather"): return Color(0.45, 0.30, 0.14)
	if item_id.begins_with("copper"):  return Color(0.82, 0.52, 0.22)
	if item_id.begins_with("iron"):    return Color(0.62, 0.62, 0.68)
	if item_id.begins_with("gold"):    return Color(0.95, 0.82, 0.18)
	if item_id.begins_with("mithril"): return Color(0.45, 0.72, 0.92)
	if item_id.begins_with("adamant"): return Color(0.24, 0.70, 0.38)
	if item_id.begins_with("runite"):  return Color(0.72, 0.28, 0.90)
	return Color(0.60, 0.60, 0.64)
