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
	Color(0.20, 0.13, 0.08), Color(0.52, 0.26, 0.10), Color(0.95, 0.85, 0.60),
	Color(0.72, 0.45, 0.18), Color(0.42, 0.30, 0.56), Color(0.20, 0.55, 0.58),
]

const TUNIC_COLORS: Array[Color] = [
	Color(0.55, 0.14, 0.12), Color(0.20, 0.42, 0.66), Color(0.24, 0.50, 0.28),
	Color(0.55, 0.42, 0.14), Color(0.40, 0.24, 0.52), Color(0.32, 0.32, 0.36),
]

# Iris colors (V1.5.4). Everyone used to have flat black eyes.
const EYE_COLORS: Array[Color] = [
	Color(0.28, 0.16, 0.06), Color(0.20, 0.45, 0.78), Color(0.22, 0.55, 0.32),
	Color(0.82, 0.56, 0.14), Color(0.46, 0.50, 0.52), Color(0.46, 0.38, 0.20),
	Color(0.46, 0.28, 0.62), Color(0.10, 0.10, 0.10),
]

# Free-hand face-mark ink colors (V1.5.4). Index into this from each stroke.
# The last two are scar tones (light + dark) so scars read as skin, not paint.
const FACE_MARK_COLORS: Array[Color] = [
	Color(0.16, 0.22, 0.52), Color(0.90, 0.92, 0.95), Color(0.06, 0.06, 0.08),
	Color(0.62, 0.12, 0.10), Color(0.14, 0.48, 0.50), Color(0.80, 0.66, 0.18),
	Color(0.55, 0.16, 0.42), Color(0.86, 0.60, 0.52), Color(0.44, 0.28, 0.20),
]
const FACE_MARK_COLOR_NAMES: Array[String] = [
	"Woad Blue", "White", "Black", "Blood Red", "Teal", "Gold", "Purple",
	"Scar (light)", "Scar (dark)",
]
const FACE_MARK_MAX_STROKES := 28
const FACE_MARK_MAX_PTS      := 96   # floats → 48 points per stroke

# Preset stamp designs (V1.5.4). Placed centred on the active region; the UI
# feeds the chosen ink for tattoos, while scars force their own scar tones.
const TATTOO_NAMES: Array[String] = [
	"Dragon", "Heart", "Rune", "Wolf", "Hammer", "Serpent", "Sun", "Star",
	"Spiral", "Cross",
]
const SCAR_NAMES: Array[String] = [
	"Bear Claw", "Slash", "Cross Scar", "Scorched Eye", "Stitches", "Burn",
]

# Body half-width by body type (slim, medium, broad)
const BODY_HALF_W: Array[int] = [7, 8, 10]

const HAIR_STYLE_NAMES: Array[String] = [
	"Short", "Long", "Braided", "Mohawk", "Bald", "Ponytail",
	"Undercut", "Topknot", "Loose", "Dreads", "Warrior", "Buzz",
]
const HAIR_COLOR_NAMES: Array[String] = [
	"Black", "Brown", "Blonde", "Red", "Gray", "White", "Blue", "Green",
	"Dark Brown", "Auburn", "Platinum", "Ginger", "Violet", "Teal",
]
const BEARD_NAMES: Array[String] = [
	"None", "Short", "Long", "Braided", "Forked",
	"Goatee", "Muttonchops", "Stubble", "Full", "Double Braid",
]
const EYE_COLOR_NAMES: Array[String] = [
	"Brown", "Blue", "Green", "Amber", "Gray", "Hazel", "Violet", "Black",
]
const BODY_NAMES: Array[String] = ["Slim", "Medium", "Broad"]

# ── Data helpers ─────────────────────────────────────────────────────────────
static func default() -> Dictionary:
	return {"skin": 2, "hair_style": 0, "hair_color": 1, "beard": 1, "body": 1,
		"tunic": 0, "eye_color": 0, "face_marks": []}

static func sanitize(d: Variant) -> Dictionary:
	var src: Dictionary = d if d is Dictionary else {}
	var out := default()
	out["skin"]       = clampi(int(src.get("skin",       out["skin"])),       0, SKIN_TONES.size() - 1)
	out["hair_style"] = clampi(int(src.get("hair_style", out["hair_style"])), 0, HAIR_STYLE_NAMES.size() - 1)
	out["hair_color"] = clampi(int(src.get("hair_color", out["hair_color"])), 0, HAIR_COLORS.size() - 1)
	out["beard"]      = clampi(int(src.get("beard",      out["beard"])),      0, BEARD_NAMES.size() - 1)
	out["body"]       = clampi(int(src.get("body",       out["body"])),       0, BODY_HALF_W.size() - 1)
	out["tunic"]      = clampi(int(src.get("tunic",      out["tunic"])),      0, TUNIC_COLORS.size() - 1)
	out["eye_color"]  = clampi(int(src.get("eye_color",  out["eye_color"])),  0, EYE_COLORS.size() - 1)
	out["face_marks"] = _sanitize_marks(src.get("face_marks", []))
	return out

## Validate the free-hand face-paint strokes coming off the wire / save file:
## cap stroke + point counts, clamp coords to the face box, clamp color/width.
static func _sanitize_marks(raw: Variant) -> Array:
	var marks: Array = []
	if not (raw is Array):
		return marks
	for m: Variant in (raw as Array):
		if not (m is Dictionary):
			continue
		var md: Dictionary = m
		var pts_raw: Variant = md.get("pts", [])
		if not (pts_raw is Array):
			continue
		var pts: Array = []
		for v: Variant in (pts_raw as Array):
			pts.append(clampf(float(v), -12.0, 12.0))
			if pts.size() >= FACE_MARK_MAX_PTS:
				break
		if pts.size() < 4:   # need at least two points to draw a line
			continue
		if pts.size() % 2 == 1:
			pts.resize(pts.size() - 1)
		marks.append({
			"r": clampi(int(md.get("r", 0)), 0, 2),   # 0 face · 1 left arm · 2 right arm
			"c": clampi(int(md.get("c", 0)), 0, FACE_MARK_COLORS.size() - 1),
			"w": clampf(float(md.get("w", 1.5)), 0.15, 4.0),
			"pts": pts,
		})
		if marks.size() >= FACE_MARK_MAX_STROKES:
			break
	return marks

## Where each paint region's local origin sits in character space. Arms depend
## on body width so shoulder ink tracks the limb when body type changes.
static func region_anchor(region: int, bw: int) -> Vector2:
	match region:
		1:  return Vector2(-bw - 1, -1)   # left shoulder / upper arm
		2:  return Vector2(bw + 1, -1)    # right shoulder / upper arm
		_:  return Vector2(0, -16)        # face

static func skin_of(a: Dictionary) -> Color:  return SKIN_TONES[clampi(int(a.get("skin", 2)), 0, SKIN_TONES.size() - 1)]
static func hair_of(a: Dictionary) -> Color:  return HAIR_COLORS[clampi(int(a.get("hair_color", 1)), 0, HAIR_COLORS.size() - 1)]
static func tunic_of(a: Dictionary) -> Color: return TUNIC_COLORS[clampi(int(a.get("tunic", 0)), 0, TUNIC_COLORS.size() - 1)]
static func eye_of(a: Dictionary) -> Color:   return EYE_COLORS[clampi(int(a.get("eye_color", 0)), 0, EYE_COLORS.size() - 1)]

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
	var eye_color: int = clampi(int(a.get("eye_color", 0)), 0, EYE_COLORS.size() - 1)
	var face_marks: Array = a.get("face_marks", []) as Array

	var walk_sw: float    = float(p.get("walk_sw", 0.0))
	var left_arm: float   = float(p.get("left_arm", 0.0))
	var right_arm: float  = float(p.get("right_arm", 0.0))
	var acting: bool      = bool(p.get("acting", false))
	var action_type: String = str(p.get("action_type", ""))
	var tool_id: String   = str(p.get("tool", ""))   # gather tool (tier-drawn)
	var equip: Dictionary = p.get("equip", {}) as Dictionary
	var has_helm: bool = str(equip.get("head", "")) != ""

	var leg_w := 6
	var left_leg_x := -bw + 1
	var right_leg_x := bw - 1 - leg_w
	# RIG (V1.5.5): legs swing from the hip. `walk_sw` drives the stride angle
	# while moving; a faint desynced counter-sway keeps a standing character
	# alive. Posed as ROTATED QUADS (no draw_set_transform) so this composes with
	# any transform a caller (NPC sway/bob, WorldThrall bob/flip) already set.
	var is_moving := absf(walk_sw) > 0.01
	var leg_a: float
	if is_moving:
		leg_a = clampf(walk_sw * 0.09, -0.45, 0.45)
	else:
		var ph := float(Time.get_ticks_msec()) * 0.0015 + float(ci.get_instance_id() % 100) * 0.06
		leg_a = sin(ph) * 0.03

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
	var lhx := float(left_leg_x) + leg_w * 0.5   # left hip x
	var rhx := float(right_leg_x) + leg_w * 0.5  # right hip x
	ci.draw_colored_polygon(_leg_quad(lhx, 7.0, leg_w, 10.0,  leg_a), c_trouser)
	ci.draw_colored_polygon(_leg_quad(rhx, 7.0, leg_w, 10.0, -leg_a), c_trouser)
	# Per-tier boot silhouette — a rotated foot cap, plus a tier-specific overlay
	# so a Dragon Boot doesn't look identical to a Copper Boot beyond hue.
	ci.draw_colored_polygon(_boot_quad(lhx, 7.0, leg_w,  leg_a), c_boot)
	ci.draw_colored_polygon(_boot_quad(rhx, 7.0, leg_w, -leg_a), c_boot)
	if str(equip.get("boots", "")) != "":
		# Overlay art stays upright but follows the foot to its swung position.
		var lfoot := Vector2(lhx, 7.0) + Vector2(-leg_w * 0.5 - 1.0, 8.0).rotated(leg_a)
		var rfoot := Vector2(rhx, 7.0) + Vector2(-leg_w * 0.5, 8.0).rotated(-leg_a)
		_draw_boot_overlay(ci, str(equip["boots"]), c_boot, lfoot, rfoot, leg_w + 1)

	# Left arm
	_draw_arm(ci, Vector2(-bw - 1, -6), left_arm, skin, false, "", {})
	# Left-shoulder ink on the bare arm skin (torso/armour below cover strays).
	if not face_marks.is_empty():
		_draw_marks(ci, face_marks, 1, region_anchor(1, bw))

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
		# Pauldrons — small dome caps over each shoulder. Adds enough
		# silhouette to distinguish armored vs plain-tunic characters.
		ci.draw_circle(Vector2(-bw - 1.0, -6.0), 3.5, bc.darkened(0.15))
		ci.draw_circle(Vector2( bw + 1.0, -6.0), 3.5, bc.darkened(0.15))
		ci.draw_circle(Vector2(-bw - 1.0, -7.2), 2.0, bc.lightened(0.28))
		ci.draw_circle(Vector2( bw + 1.0, -7.2), 2.0, bc.lightened(0.28))
		# Central chest plate stripe for a heavy-armor read.
		ci.draw_rect(Rect2(-2, -8, 4, 13), bc.lightened(0.12))

	# Head
	ci.draw_circle(Vector2(0, -16), 9, skin)
	ci.draw_circle(Vector2(-5, -14), 3, Color(0.90, 0.62, 0.52, 0.45))
	ci.draw_circle(Vector2( 5, -14), 3, Color(0.90, 0.62, 0.52, 0.45))

	# Face paint on the SKIN — drawn now, so beard/hair/eyes below cover it and
	# it can never paint over a feature. Skipped under a full helm.
	if not has_helm and not face_marks.is_empty():
		_draw_marks(ci, face_marks, 0, Vector2(0, -16))

	# Beard (colored from hair)
	_draw_beard(ci, beard_style, hair)

	# Hair (skipped if a helm is equipped)
	if not has_helm:
		_draw_hair(ci, hair_style, hair)

	# Helm overlay (equipment) — drawn before the eyes so the eyes stay visible.
	if has_helm:
		_draw_helm(ci, str(equip.get("head", "")))

	# Eyes (always on top, so an equipped helm never covers the face). Coloured
	# iris + dark pupil + white glint reads as a real eye instead of a dot.
	var iris := EYE_COLORS[eye_color]
	ci.draw_circle(Vector2(-3, -17), 2.2, Color(0.92, 0.90, 0.86))   # sclera
	ci.draw_circle(Vector2( 3, -17), 2.2, Color(0.92, 0.90, 0.86))
	ci.draw_circle(Vector2(-3, -17), 1.7, iris)
	ci.draw_circle(Vector2( 3, -17), 1.7, iris)
	ci.draw_circle(Vector2(-3, -17), 0.9, Color(0.05, 0.05, 0.06))
	ci.draw_circle(Vector2( 3, -17), 0.9, Color(0.05, 0.05, 0.06))
	ci.draw_circle(Vector2(-2.4, -17.6), 0.6, Color(1, 1, 1, 0.85))
	ci.draw_circle(Vector2( 3.6, -17.6), 0.6, Color(1, 1, 1, 0.85))

	# Right arm + weapon
	_draw_arm(ci, Vector2(bw + 1, -6), right_arm, skin, acting, action_type, equip, tool_id)
	# Right-shoulder ink on the bare arm skin (front arm — nothing covers it).
	if not face_marks.is_empty():
		_draw_marks(ci, face_marks, 2, region_anchor(2, bw))

# ── Leg rig helpers (V1.5.5) ─────────────────────────────────────────────────
## A leg quad (thigh+shin as one tapering-free rect) swung around the hip
## (hx, hy) by `ang`, returned as rotated corners for draw_colored_polygon.
static func _leg_quad(hx: float, hy: float, w: float, h: float, ang: float) -> PackedVector2Array:
	var hip := Vector2(hx, hy)
	return PackedVector2Array([
		hip + Vector2(-w * 0.5, 0.0).rotated(ang),
		hip + Vector2( w * 0.5, 0.0).rotated(ang),
		hip + Vector2( w * 0.5, h).rotated(ang),
		hip + Vector2(-w * 0.5, h).rotated(ang),
	])

## The boot cap at the foot (y 8-12 below the hip), swung with the same angle.
static func _boot_quad(hx: float, hy: float, w: float, ang: float) -> PackedVector2Array:
	var hip := Vector2(hx, hy)
	return PackedVector2Array([
		hip + Vector2(-w * 0.5 - 1.0, 8.0).rotated(ang),
		hip + Vector2( w * 0.5, 8.0).rotated(ang),
		hip + Vector2( w * 0.5, 12.0).rotated(ang),
		hip + Vector2(-w * 0.5 - 1.0, 12.0).rotated(ang),
	])

# ── Arm + weapon ─────────────────────────────────────────────────────────────
static func _draw_arm(ci: CanvasItem, pivot: Vector2, angle: float, skin: Color,
		acting: bool, action_type: String, equip: Dictionary,
		tool_id: String = "") -> void:
	ci.draw_set_transform(pivot, angle, Vector2.ONE)
	var c_rod := Color(0.48, 0.30, 0.08)
	var arm_col := c_rod if (acting and action_type == "fish") else skin
	ci.draw_rect(Rect2(-2.5, 0, 5, 12), arm_col)

	if acting:
		match action_type:
			"chop":
				_draw_gather_axe(ci, tool_id)
			"mine":
				_draw_gather_pick(ci, tool_id)
			"fish":
				ci.draw_rect(Rect2(-1, 12, 2, 10), c_rod)
				ci.draw_line(Vector2(0, 22), Vector2(5, 35), Color(0.85, 0.85, 0.85, 0.65), 1.0)
			# "forage" / "" -> nothing: a bare hand for herbs/sticks/stones.
	elif equip.get("weapon", "") != "":
		# Weapon-type-aware silhouettes — playtest polish so a sword actually
		# reads as a sword, an axe as an axe, etc. Dispatch on id suffix
		# (matches the recipe naming: `<tier>_<kind>`).
		_draw_weapon(ci, str(equip.get("weapon", "")))

	# Gauntlet over the arm's end when gloves are equipped — small metal cuff.
	if str(equip.get("gloves", "")) != "":
		var gc := _gear_color(str(equip.get("gloves", "")))
		ci.draw_rect(Rect2(-3, 10, 6, 5), gc)
		ci.draw_rect(Rect2(-3, 10, 6, 1), gc.lightened(0.3))

	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Best gathering tool of a given kind in an inventory, tier-ordered, or "" if
## none. `action` = "chop" (axe) / "mine" (pickaxe). Used to draw the highest-tier
## tool the gatherer actually owns. Excludes the battleAXE weapon from "chop".
static func best_tool(inventory: Array, action: String) -> String:
	var best_id := ""
	var best_tier := -1
	for item: Variant in inventory:
		if not (item is Dictionary):
			continue
		var iid := str((item as Dictionary).get("id", ""))
		var ok := false
		if action == "chop":
			ok = iid.ends_with("_axe") and not iid.ends_with("_battleaxe")
		elif action == "mine":
			ok = iid.ends_with("_pickaxe") or iid == "pickaxe"
		if ok:
			var t := _gear_tier(iid)
			if t >= best_tier:
				best_tier = t
				best_id = iid
	return best_id

## Tier-drawn gathering AXE in the swinging hand (arm-local coords, +Y = down
## toward the hand). Colour + sheen/gem scale with the tool's material tier, so a
## runite hatchet reads richer than a wooden one. Empty id -> plain steel head.
static func _draw_gather_axe(ci: CanvasItem, tool_id: String) -> void:
	var wc := _gear_color(tool_id) if tool_id != "" else Color(0.72, 0.72, 0.75)
	var tier := _gear_tier(tool_id) if tool_id != "" else 0
	var haft := Color(0.42, 0.28, 0.12)
	if tier >= 6:
		ci.draw_circle(Vector2(4.5, 10.5), 7.5, Color(_wpn_gem(tier), 0.16))
	ci.draw_rect(Rect2(-1, 7, 2.4, 12), haft)               # haft down from hand
	ci.draw_colored_polygon(PackedVector2Array([            # blade wedge
		Vector2(1, 8), Vector2(8, 7), Vector2(8, 14), Vector2(1, 13)]), wc)
	ci.draw_rect(Rect2(-1, 6, 2, 3), wc)                    # top spike
	ci.draw_line(Vector2(7.5, 7.5), Vector2(7.5, 13.5), wc.lightened(0.3), 1.0)
	if tier >= 4:
		ci.draw_circle(Vector2(1.5, 10.5), 1.4, _wpn_gem(tier))

## Tier-drawn gathering PICKAXE — a double-pointed head across the top of a haft.
static func _draw_gather_pick(ci: CanvasItem, tool_id: String) -> void:
	var wc := _gear_color(tool_id) if tool_id != "" else Color(0.60, 0.60, 0.62)
	var tier := _gear_tier(tool_id) if tool_id != "" else 0
	var haft := Color(0.42, 0.28, 0.12)
	if tier >= 6:
		ci.draw_circle(Vector2(0, 10.0), 7.5, Color(_wpn_gem(tier), 0.16))
	ci.draw_rect(Rect2(-1, 6, 2.4, 13), haft)               # haft down from hand
	ci.draw_colored_polygon(PackedVector2Array([            # double-pointed head
		Vector2(-8, 10.5), Vector2(0, 8), Vector2(8, 10.5),
		Vector2(8, 11.8), Vector2(0, 10), Vector2(-8, 11.8)]), wc)
	ci.draw_line(Vector2(-8, 10.5), Vector2(8, 10.5), wc.lightened(0.3), 1.0)
	if tier >= 4:
		ci.draw_circle(Vector2(0, 9.5), 1.4, _wpn_gem(tier))

## Draws the equipped weapon along the extended right arm. Origin is the
## arm pivot after rotation, so all coords are in arm-local space
## (positive Y goes down toward the hand).
static func _draw_weapon(ci: CanvasItem, weapon_id: String) -> void:
	var wc := _gear_color(weapon_id)
	var haft := Color(0.32, 0.20, 0.08)
	var haft_dk := haft.darkened(0.2)
	# Tier drives ornament/sheen/glow so material reads at a glance (art pass).
	var tier := _gear_tier(weapon_id)
	var sheen := wc.lightened(0.28 + float(tier) * 0.04)   # brighter at high tier
	var gem := _wpn_gem(tier)
	var gold := Color(0.90, 0.75, 0.20)
	# Suffix dispatch — order matters (`_battleaxe` before `_axe`).
	if weapon_id.ends_with("_battleaxe"):
		# Two-handed axe: long haft + double-blade fan.
		if tier >= 6:  # energy glow behind the heads
			ci.draw_circle(Vector2(0, 21), 12.0, Color(gem, 0.22))
		ci.draw_rect(Rect2(-1.5, 2, 3, 22), haft)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(-1, 18), Vector2(-9, 15), Vector2(-8, 26), Vector2(-1, 24)]), wc)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(1, 18), Vector2(9, 15), Vector2(8, 26), Vector2(1, 24)]), wc)
		# Edge sheen scaling with tier.
		ci.draw_line(Vector2(-8, 15.5), Vector2(-8.5, 25.5), sheen, 1.0)
		ci.draw_line(Vector2(8, 15.5), Vector2(8.5, 25.5), sheen, 1.0)
		if tier >= 4:  # binding jewel where the heads meet the haft
			ci.draw_circle(Vector2(0, 21), 1.6, gem)
		if tier >= 7:  # dragon — flared bottom fang on each head
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-8, 26), Vector2(-11, 29), Vector2(-6, 26)]), wc.darkened(0.1))
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(8, 26), Vector2(11, 29), Vector2(6, 26)]), wc.darkened(0.1))
		ci.draw_rect(Rect2(-1.5, 22, 3, 4), haft_dk)
		return
	if weapon_id.ends_with("_axe") or weapon_id == "wooden_axe":
		# Single-hand axe: shorter haft + one blade + top spike.
		if tier >= 6:
			ci.draw_circle(Vector2(5, 16), 9.0, Color(gem, 0.20))
		ci.draw_rect(Rect2(-1.5, 3, 3, 18), haft)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(1, 12), Vector2(9, 10), Vector2(8, 22), Vector2(1, 20)]), wc)
		ci.draw_line(Vector2(8.5, 10.5), Vector2(7.5, 21.5), sheen, 1.0)   # blade sheen
		ci.draw_rect(Rect2(-1, 1, 2, 4), wc)
		if tier >= 5:  # gold langets down the haft
			ci.draw_rect(Rect2(-1.5, 11, 3, 1.2), gold)
		if tier >= 4:
			ci.draw_circle(Vector2(0, 11), 1.4, gem)
		return
	if weapon_id.ends_with("_sword"):
		# Sword: pommel + crossguard + blade + tapered tip. Higher tiers gain a
		# jewelled pommel, a wider gold-trimmed guard, a stronger fuller sheen,
		# and (runite/dragon) an aura.
		if tier >= 6:
			ci.draw_line(Vector2(0, 11), Vector2(0, 28), Color(gem, 0.35), 5.0)
		ci.draw_circle(Vector2(0, 3), 2.5, wc.darkened(0.25))       # pommel
		if tier >= 4:
			ci.draw_circle(Vector2(0, 3), 1.4, gem)
		ci.draw_rect(Rect2(-1.5, 4, 3, 5), haft)                     # grip
		var guard_w := 10.0 + float(tier) * 0.7
		ci.draw_rect(Rect2(-guard_w * 0.5, 9, guard_w, 2), wc.darkened(0.15))
		if tier >= 5:
			ci.draw_rect(Rect2(-guard_w * 0.5, 9, guard_w, 0.8), gold)
		ci.draw_rect(Rect2(-1.5, 11, 3, 14), wc)                     # blade
		if tier >= 7:  # dragon — fanged quillons
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-guard_w * 0.5, 9), Vector2(-guard_w * 0.5 - 3, 6),
				Vector2(-guard_w * 0.5, 11)]), wc)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(guard_w * 0.5, 9), Vector2(guard_w * 0.5 + 3, 6),
				Vector2(guard_w * 0.5, 11)]), wc)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(-1.5, 25), Vector2(1.5, 25), Vector2(0, 29)]), wc)
		ci.draw_line(Vector2(0, 12), Vector2(0, 24), sheen, 0.9)     # fuller sheen
		return
	if weapon_id.ends_with("_mace"):
		# Mace: haft + spiked ball head.
		if tier >= 6:
			ci.draw_circle(Vector2(0, 20), 11.0, Color(gem, 0.20))
		ci.draw_rect(Rect2(-1.5, 4, 3, 14), haft)
		if tier >= 5:
			ci.draw_rect(Rect2(-1.5, 4, 3, 1.2), gold)
		ci.draw_circle(Vector2(0, 20), 4.5, wc)
		ci.draw_circle(Vector2(-1.5, 18.5), 1.6, sheen)   # head highlight
		# Spikes — longer/more for higher tier.
		var spikes: Array = [0.0, PI * 0.5, PI, PI * 1.5]
		if tier >= 5:
			spikes = [0.0, PI * 0.25, PI * 0.5, PI * 0.75, PI, PI * 1.25, PI * 1.5, PI * 1.75]
		var slen := 6.5 + float(tier) * 0.3
		for angle in spikes:
			var tip := Vector2(cos(angle), sin(angle)) * slen + Vector2(0, 20)
			var base_a := Vector2(cos(angle + 0.5), sin(angle + 0.5)) * 3.5 + Vector2(0, 20)
			var base_b := Vector2(cos(angle - 0.5), sin(angle - 0.5)) * 3.5 + Vector2(0, 20)
			ci.draw_colored_polygon(PackedVector2Array([base_a, tip, base_b]),
				wc.darkened(0.15))
		if tier >= 4:
			ci.draw_circle(Vector2(0, 20), 1.6, gem)   # core gem
		return
	if weapon_id.ends_with("_bow"):
		# Bow: curved limb + string. Higher tiers get a thicker recurve, gold
		# nocks, a grip wrap, and a gem riser.
		var pts := PackedVector2Array()
		for i in range(9):
			var t: float = float(i) / 8.0
			var y: float = 2.0 + t * 20.0
			var x: float = sin(t * PI) * (6.0 + float(tier) * 0.4)
			pts.append(Vector2(x, y))
		ci.draw_polyline(pts, wc.darkened(0.2), 2.0 + float(tier) * 0.15)
		if tier >= 5:  # gold limb tips
			ci.draw_circle(Vector2(0, 2), 1.4, gold)
			ci.draw_circle(Vector2(0, 22), 1.4, gold)
		if tier >= 4:  # gem on the riser (grip)
			ci.draw_circle(Vector2(sin(0.5 * PI) * (6.0 + float(tier) * 0.4), 12), 1.6, gem)
		if tier >= 7:  # dragon — ember aura along the limb
			ci.draw_polyline(pts, Color(gem, 0.3), 4.0)
		ci.draw_line(Vector2(0, 2), Vector2(0, 22),
			Color(0.92, 0.90, 0.82, 0.85), 0.8)   # string
		return
	if weapon_id.ends_with("_staff"):
		# Staff: long shaft + gem-tipped orb. Orb + glow scale with tier.
		ci.draw_rect(Rect2(-1, 2, 2, 24), haft)
		if tier >= 5:  # gold ferrule bands
			ci.draw_rect(Rect2(-1, 6, 2, 1.2), gold)
			ci.draw_rect(Rect2(-1, 22, 2, 1.2), gold)
		var orb_r := 3.5 + float(tier) * 0.25
		if tier >= 4:  # aura behind the orb
			ci.draw_circle(Vector2(0, 1), orb_r + 3.0, Color(gem, 0.28))
		ci.draw_circle(Vector2(0, 1), orb_r, wc if tier < 4 else gem)
		ci.draw_circle(Vector2(0, 1), orb_r * 0.5, Color(1, 1, 1, 0.7))   # hot core
		return
	if weapon_id.ends_with("_pickaxe"):
		ci.draw_rect(Rect2(-1.5, 4, 3, 16), haft)
		ci.draw_rect(Rect2(-5, 14, 10, 2), wc.darkened(0.15))
		ci.draw_rect(Rect2(-6, 12, 2, 4), wc)
		ci.draw_rect(Rect2( 4, 12, 2, 4), wc)
		return
	# Unique-weapon overrides — id-specific silhouettes for named uniques
	# whose ids don't route to a suffix branch above. Add entries here as
	# unique weapons ship. Everything else falls through to the fallback +
	# a printerr note so a missing weapon draw is easy to spot in the log.
	match weapon_id:
		"high_seat_blade":
			# Ornate longsword with jeweled pommel.
			ci.draw_circle(Vector2(0, 3), 3.0, Color(0.85, 0.15, 0.15))  # ruby pommel
			ci.draw_rect(Rect2(-1.5, 5, 3, 6), haft)
			ci.draw_rect(Rect2(-6, 10, 12, 2.5), Color(0.90, 0.75, 0.20))  # gold crossguard
			ci.draw_rect(Rect2(-2, 12, 4, 16), wc.lightened(0.15))         # wide blade
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-2, 28), Vector2(2, 28), Vector2(0, 32)]), wc.lightened(0.15))
			return
		"dragon_sword":
			# Curved dragon-scale blade.
			ci.draw_circle(Vector2(0, 3), 2.5, Color(0.35, 0.05, 0.05))
			ci.draw_rect(Rect2(-1.5, 4, 3, 5), haft)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-4, 9), Vector2(4, 9),
				Vector2(3, 11), Vector2(-3, 11)]), wc.darkened(0.10))  # crossguard
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-2, 11), Vector2(2, 11),
				Vector2(3, 25), Vector2(0, 30), Vector2(-1, 25)]), wc)
			return
	# Fallback — generic hafted club. Prints a one-line warning so the
	# omission is visible in the log; suppress in exported builds by
	# swapping to `print_verbose`.
	push_warning("[Appearance] no draw for weapon id '%s' — using club fallback" % weapon_id)
	ci.draw_rect(Rect2(-1.5, 4, 3, 16), haft)
	ci.draw_rect(Rect2(-3, 16, 6, 6), wc)

# ── Hair styles (HD redraw + expanded set, V1.5.4) ────────────────────────────
# All styles keep the front hairline above the eyes (y = -17) so hair never
# covers the face. `sh`/`hl` = shade/highlight derived from the base colour for
# volume + strand texture instead of flat fills.
static func _draw_hair(ci: CanvasItem, style: int, hair: Color) -> void:
	var sh := hair.darkened(0.30)
	var hl := hair.lightened(0.24)
	match style:
		0:  # Short
			_hair_cap(ci, hair)
		1:  # Long — a full mane down the back & sides (NOT two thin pigtails)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-10, -24), Vector2(-11, -2), Vector2(-8, 3), Vector2(-8, -19),
				Vector2(8, -19), Vector2(8, 3), Vector2(11, -2), Vector2(10, -24)]), sh)
			_hair_cap(ci, hair)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-10, -22), Vector2(-8, -15), Vector2(-8, 2), Vector2(-11, -2)]), hair)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(10, -22), Vector2(8, -15), Vector2(8, 2), Vector2(11, -2)]), hair)
			ci.draw_line(Vector2(-9.5, -20), Vector2(-9.5, -1), hl, 0.5)
			ci.draw_line(Vector2( 9.5, -20), Vector2( 9.5, -1), hl, 0.5)
		2:  # Braided — crown + two symmetric braids hanging beside the face
			_hair_cap(ci, hair)
			for side: float in [-1.0, 1.0]:
				var bx: float = 8.5 * side
				for i in range(4):
					ci.draw_circle(Vector2(bx, -14 + i * 4), 1.9, hair if i % 2 == 0 else sh)
					ci.draw_line(Vector2(bx - 1.5, -15 + i * 4), Vector2(bx + 1.5, -15 + i * 4), hl, 0.4)
		3:  # Mohawk
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-3.5, -23), Vector2(-2, -33), Vector2(0, -34),
				Vector2(2, -33), Vector2(3.5, -23)]), sh)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-2.5, -23), Vector2(-1, -32), Vector2(1, -32), Vector2(2.5, -23)]), hair)
			ci.draw_line(Vector2(0, -32), Vector2(0, -23), hl, 0.6)
			ci.draw_rect(Rect2(-3, -25, 6, 3), hair)
		4:  # Bald — clean shaved scalp (matches Buzz)
			_hair_shaved(ci, hair)
		5:  # Ponytail
			_hair_cap(ci, hair)
			for i in range(6):
				ci.draw_circle(Vector2(9 + i * 0.8, -21 + i * 3), 2.6 - i * 0.25,
					hair if i % 2 == 0 else sh)
		6:  # Undercut — full on top, shaved sides, hard part line
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-7, -20), Vector2(-7, -24), Vector2(0, -26.5), Vector2(7, -24),
				Vector2(7, -20), Vector2(4, -19), Vector2(-4, -19)]), hair)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-5, -23), Vector2(0, -25.5), Vector2(4, -23), Vector2(0, -22)]), hl)
			ci.draw_line(Vector2(-6, -19.5), Vector2(6, -19.5), sh, 0.8)
		7:  # Topknot — cap + a bound bun
			_hair_cap(ci, hair)
			ci.draw_circle(Vector2(0, -27), 3.2, hair)
			ci.draw_circle(Vector2(-0.8, -27.8), 1.4, hl)
			ci.draw_rect(Rect2(-3, -24.5, 6, 2), sh)   # tie
		8:  # Loose — fuller flowing hair framing the face
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-11, -20), Vector2(-9, -25), Vector2(0, -27), Vector2(9, -25),
				Vector2(11, -20), Vector2(11, -2), Vector2(8, 0), Vector2(8, -19),
				Vector2(-8, -19), Vector2(-8, 0), Vector2(-11, -2)]), sh)
			_hair_cap(ci, hair)
			ci.draw_rect(Rect2(-11, -20, 3, 18), hair)
			ci.draw_rect(Rect2( 8, -20, 3, 18), hair)
			ci.draw_line(Vector2(-9.5, -19), Vector2(-9.5, -3), hl, 0.5)
			ci.draw_line(Vector2( 9.5, -19), Vector2( 9.5, -3), hl, 0.5)
		9:  # Dreads — shaded rope locks hanging at the SIDES (off the face)
			_hair_cap(ci, hair)
			for dx: float in [-8.5, -6.5, 6.5, 8.5]:
				var ln := 15.0 if absf(dx) > 7.5 else 12.0
				ci.draw_rect(Rect2(dx - 1.2, -20, 2.4, ln), sh)          # shaded core
				ci.draw_rect(Rect2(dx - 0.7, -20, 1.4, ln), hair)        # lit face
				ci.draw_circle(Vector2(dx, -20 + ln), 1.3, hair)         # rounded end
				for k in range(3):
					ci.draw_line(Vector2(dx - 1.2, -16 + k * 4),
						Vector2(dx + 1.2, -16 + k * 4), sh, 0.4)         # lock ticks
		10:  # Warrior — shaved sides, a braided crest on TOP, a side braid trailing
			ci.draw_rect(Rect2(-2.5, -26, 5, 7), hair)                   # crest base (crown only)
			for i in range(3):
				ci.draw_circle(Vector2(0, -25 + i * 2.2), 2.0, hair if i % 2 == 0 else sh)
			for i in range(4):                                           # braid trailing beside the head
				ci.draw_circle(Vector2(9, -18 + i * 3), 1.7, hair if i % 2 == 0 else sh)
			ci.draw_rect(Rect2(-9, -19, 1.5, 4), hair)                   # thin sideburns
			ci.draw_rect(Rect2( 7.5, -19, 1.5, 4), hair)
		11:  # Buzz — clean shaved head (matches Bald)
			_hair_shaved(ci, hair)

static func _hair_cap(ci: CanvasItem, hair: Color) -> void:
	# Dome that follows the top of the skull; front hairline stops just above
	# the eyes (eyes sit at y = -17) so hair never covers the face.
	var sh := hair.darkened(0.32)
	var hl := hair.lightened(0.24)
	# Under-shadow layer (slightly larger, reads as volume behind the crown).
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(-9, -18), Vector2(-9, -23.5), Vector2(-4.5, -26.5),
		Vector2(0, -27), Vector2(4.5, -26.5), Vector2(9, -23.5), Vector2(9, -18),
	]), sh)
	# Main hair mass.
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(-8, -19), Vector2(-8, -23), Vector2(-4, -25.5),
		Vector2(0, -26), Vector2(4, -25.5), Vector2(8, -23), Vector2(8, -19),
	]), hair)
	# Top highlight sweep.
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(-6, -22.5), Vector2(-2, -25), Vector2(2, -25),
		Vector2(5, -23), Vector2(1, -22), Vector2(-4, -22),
	]), hl)
	# Strand texture — fine lines fanning from the crown.
	for i in range(5):
		var sx := -6.0 + float(i) * 3.0
		ci.draw_line(Vector2(sx * 0.4, -25.0), Vector2(sx, -19.5), sh, 0.6)
	# Sideburns down the sides of the face (clear of the eyes at x = ±3).
	ci.draw_rect(Rect2(-9, -19, 2, 5), hair)
	ci.draw_rect(Rect2( 7, -19, 2, 5), hair)

## Bald / Buzz — a clean empty head with only the faintest shaved-scalp shadow.
static func _hair_shaved(ci: CanvasItem, hair: Color) -> void:
	ci.draw_arc(Vector2(0, -18), 8.2, PI + 0.45, TAU - 0.45, 12,
		Color(hair.r, hair.g, hair.b, 0.12), 1.2)

# ── Beard styles (HD redraw + expanded set, V1.5.4) ───────────────────────────
static func _draw_beard(ci: CanvasItem, style: int, col: Color) -> void:
	var sh := col.darkened(0.28)
	var hl := col.lightened(0.20)
	match style:
		0:  # None
			pass
		1:  # Short
			ci.draw_rect(Rect2(-5, -12, 10, 6), col)
			ci.draw_circle(Vector2(0, -7), 3, col)
			ci.draw_line(Vector2(-4, -9), Vector2(4, -9), sh, 0.5)
		2:  # Long
			ci.draw_rect(Rect2(-5, -12, 10, 9), col)
			ci.draw_circle(Vector2(0, -3), 4, col)
			ci.draw_line(Vector2(0, -11), Vector2(0, 0), sh, 0.5)
		3:  # Braided
			ci.draw_rect(Rect2(-5, -12, 10, 7), col)
			for i in range(3):
				ci.draw_circle(Vector2(-3, -4 + i * 3), 2.0, col if i % 2 == 0 else sh)
				ci.draw_circle(Vector2( 3, -4 + i * 3), 2.0, col if i % 2 == 0 else sh)
		4:  # Forked
			ci.draw_rect(Rect2(-5, -12, 10, 5), col)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-5, -7), Vector2(-1, -7), Vector2(-3, 0)]), col)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(1, -7), Vector2(5, -7), Vector2(3, 0)]), col)
		5:  # Goatee — chin + mustache only
			ci.draw_rect(Rect2(-4, -13, 8, 2), col)   # mustache
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-2.5, -9), Vector2(2.5, -9), Vector2(1.5, -3), Vector2(-1.5, -3)]), col)
		6:  # Muttonchops — cheeks + sideburns, bare chin
			ci.draw_rect(Rect2(-6, -13, 3, 8), col)
			ci.draw_rect(Rect2( 3, -13, 3, 8), col)
			ci.draw_rect(Rect2(-4, -13, 8, 2), col)   # thin mustache link
		7:  # Stubble — a soft shadow hugging the jaw & chin (no bulk)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-6, -12), Vector2(-6, -10), Vector2(-3, -6), Vector2(0, -5),
				Vector2(3, -6), Vector2(6, -10), Vector2(6, -12), Vector2(3, -11),
				Vector2(-3, -11)]), Color(col.r, col.g, col.b, 0.38))
		8:  # Full — big bushy beard
			ci.draw_rect(Rect2(-6, -12, 12, 8), col)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(-6, -4), Vector2(6, -4), Vector2(3, 3), Vector2(-3, 3)]), col)
			ci.draw_rect(Rect2(-6, -12, 12, 2), hl)
			ci.draw_line(Vector2(0, -11), Vector2(0, 1), sh, 0.5)
		9:  # Double Braid — two long bound braids
			ci.draw_rect(Rect2(-5, -12, 10, 5), col)
			for i in range(4):
				ci.draw_circle(Vector2(-3, -6 + i * 3), 1.8, col if i % 2 == 0 else sh)
				ci.draw_circle(Vector2( 3, -6 + i * 3), 1.8, col if i % 2 == 0 else sh)

# ── Free-hand marks (war paint / tattoos / scars, V1.5.4) ─────────────────────
# Strokes are stored region-local; they render at the region anchor and are
# drawn UNDER hair/beard/eyes/clothing (skin-only by layering — see the call
# sites in draw_character), so paint can never cover a feature or garment.
## Build ready-to-append strokes for a preset stamp, centred on `region`.
## Tattoos take the caller's `ink`; scars force their own tones. Designs are
## authored face-sized and scaled to 0.55 on the narrower shoulder regions.
static func preset_strokes(kind: String, idx: int, region: int, ink: int) -> Array:
	var lines: Array = []
	var w := 1.2
	var col := ink
	if kind == "scar":
		col = 8   # dark scar tone by default
		w = 1.0
		match idx:
			0:  # Bear Claw — three raking slashes
				lines = [[-4, -4, -1, 4], [-2, -4.5, 1, 3.5], [0, -4, 3, 4]]
			1:  # Slash
				lines = [[-4, -3, 4, 3]]
			2:  # Cross Scar
				lines = [[-3, -3, 3, 3], [3, -3, -3, 3]]
			3:  # Scorched Eye — burn streaks around the right eye
				col = 8
				lines = [[3, -3, 6, -4], [4, -1, 6, -1], [3, 1, 6, 2], [2, -4, 3, -5.5]]
			4:  # Stitches
				lines = [[-4, 0, 4, 0], [-3, -1, -3, 1], [-1, -1, -1, 1],
					[1, -1, 1, 1], [3, -1, 3, 1]]
			_:  # Burn — blotchy scribble
				col = 7
				w = 1.4
				lines = [[-2, -2, 1, -1, -1, 1, 2, 2], [-1, -2, 2, 0]]
	else:
		match idx:
			0:  # Dragon — serpent body + head + wing
				lines = [[-5, 3, -3, 1, -1, 2, 1, 0, 3, 1, 5, -1],
					[5, -1, 6.5, -2, 5, -3], [1, 0, 2.5, -3, 4.5, -2]]
			1:  # Heart
				w = 1.4
				lines = [[0, 3, -4, -1, -3, -4, 0, -2, 3, -4, 4, -1, 0, 3]]
			2:  # Rune (algiz)
				lines = [[0, -4, 0, 4], [0, -1, -3, -4], [0, -1, 3, -4]]
			3:  # Wolf head
				lines = [[-4, 3, -3, -2, -1, -4, -1, -1, 1, -1, 1, -4, 3, -2, 4, 3, 0, 4.5, -4, 3]]
			4:  # Hammer (Mjölnir)
				lines = [[-3, -3, 3, -3, 3, -1, -3, -1, -3, -3], [0, -1, 0, 4]]
			5:  # Serpent — S-curve
				lines = [[-4, -3, -1, -4, 1, -2, -1, 0, 1, 2, 3, 3.5], [3, 3.5, 4.5, 3]]
			6:  # Sun — core + rays
				w = 1.1
				lines = [[-1, 0, 1, 0, 1, 0], [0, -5, 0, -3], [0, 5, 0, 3],
					[-5, 0, -3, 0], [5, 0, 3, 0], [-3.5, -3.5, -2, -2],
					[3.5, -3.5, 2, -2], [-3.5, 3.5, -2, 2], [3.5, 3.5, 2, 2]]
			7:  # Star (5-point)
				lines = [[0, -5, 1.2, -1.5, 4.7, -1.5, 1.9, 0.6, 3, 4,
					0, 1.9, -3, 4, -1.9, 0.6, -4.7, -1.5, -1.2, -1.5, 0, -5]]
			8:  # Spiral
				lines = [[0, 0, 1.4, -0.6, 1.2, -2.4, -1, -3, -3, -1.4, -2.6, 1.8,
					0.6, 3.4, 3.6, 2.2, 4.4, -1.4]]
			_:  # Cross (tribal)
				lines = [[0, -4.5, 0, 4.5], [-3.5, -0.5, 3.5, -0.5]]
	var sc := 1.0 if region == 0 else 0.55
	var out: Array = []
	for ln: Array in lines:
		var pts: Array = []
		for v: float in ln:
			pts.append(v * sc)
		out.append({"r": region, "c": col, "w": w, "pts": pts})
	return out

static func _draw_marks(ci: CanvasItem, marks: Array, region: int, anchor: Vector2) -> void:
	for m: Variant in marks:
		if not (m is Dictionary):
			continue
		var md: Dictionary = m
		if int(md.get("r", 0)) != region:
			continue
		var pts: Variant = md.get("pts", [])
		if not (pts is Array) or (pts as Array).size() < 2:
			continue
		var pa: Array = pts
		var col := FACE_MARK_COLORS[clampi(int(md.get("c", 0)), 0, FACE_MARK_COLORS.size() - 1)]
		var w := clampf(float(md.get("w", 1.5)), 0.15, 4.0)
		var pv := PackedVector2Array()
		var i := 0
		while i + 1 < pa.size():
			pv.append(anchor + Vector2(float(pa[i]), float(pa[i + 1])))
			i += 2
		if pv.size() == 1:
			ci.draw_circle(pv[0], w * 0.5, col)
		elif pv.size() >= 2:
			ci.draw_polyline(pv, col, w, true)

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
	# Playtest polish — unique tier prefixes that previously fell through
	# to neutral grey. Dragon scale-red, bandit leather-brown, ancient
	# forest-teak, bone off-white.
	if item_id.begins_with("dragon"):  return Color(0.75, 0.18, 0.15)
	if item_id.begins_with("bandit"):  return Color(0.30, 0.20, 0.14)
	if item_id.begins_with("ancient"): return Color(0.38, 0.28, 0.14)
	if item_id.begins_with("bone"):    return Color(0.88, 0.85, 0.72)
	return Color(0.60, 0.60, 0.64)

## Gear tier 0-7 (leather → dragon). Drives how much ORNAMENT + SHEEN + GLOW a
## weapon gets, so a runite blade reads richer than a copper one at a glance —
## not just a colour swap (art pass v1.5.3).
static func _gear_tier(item_id: String) -> int:
	if item_id.begins_with("dragon"):  return 7
	if item_id.begins_with("runite"):  return 6
	if item_id.begins_with("adamant"): return 5
	if item_id.begins_with("mithril"): return 4
	if item_id.begins_with("gold"):    return 3
	if item_id.begins_with("iron"):    return 2
	if item_id.begins_with("copper") or item_id.begins_with("bronze"): return 1
	return 0

## Accent gem colour for a tier — the pommel/guard jewel + high-tier glow hue.
static func _wpn_gem(tier: int) -> Color:
	match tier:
		7: return Color(1.00, 0.48, 0.16)   # dragon — ember
		6: return Color(0.82, 0.40, 1.00)   # runite — amethyst
		5: return Color(0.40, 0.95, 0.55)   # adamant — emerald
		4: return Color(0.55, 0.85, 1.00)   # mithril — sapphire
		_: return Color(0.92, 0.80, 0.35)   # low — amber

## Per-tier boot silhouette overlay. Draws distinctive detail on top of
## the base foot rect: soft cuff for leather, plated calf for iron,
## kneecap for mithril, studs for adamant, sabaton for runite, clawed
## heel + scale for dragon. `left`/`right` are the top-left origins of
## the two foot rects that `_draw_character` already painted; `w` is
## their width. No-ops for unrecognised ids (older / neutral boots).
static func _draw_boot_overlay(ci: CanvasItem, boot_id: String,
		boot_col: Color, left: Vector2, right: Vector2, w: float) -> void:
	if boot_id.begins_with("leather"):
		# Soft short cuff — thin darker band above the foot.
		var cuff := boot_col.darkened(0.25)
		ci.draw_rect(Rect2(left.x, left.y - 2.0, w, 2.0), cuff)
		ci.draw_rect(Rect2(right.x, right.y - 2.0, w, 2.0), cuff)
	elif boot_id.begins_with("copper"):
		# Simple stud row along the ankle.
		var stud := boot_col.lightened(0.30)
		ci.draw_circle(Vector2(left.x + 1.0, left.y + 1.0), 0.6, stud)
		ci.draw_circle(Vector2(right.x + w - 1.0, right.y + 1.0), 0.6, stud)
	elif boot_id.begins_with("iron"):
		# Plated calf — taller band + rivet dots.
		var plate := boot_col.darkened(0.15)
		var shine := boot_col.lightened(0.20)
		ci.draw_rect(Rect2(left.x, left.y - 3.0, w, 3.0), plate)
		ci.draw_rect(Rect2(right.x, right.y - 3.0, w, 3.0), plate)
		ci.draw_circle(Vector2(left.x + w * 0.5, left.y - 1.5), 0.7, shine)
		ci.draw_circle(Vector2(right.x + w * 0.5, right.y - 1.5), 0.7, shine)
	elif boot_id.begins_with("mithril"):
		# Greaves with a knee cap.
		var plate := boot_col.darkened(0.15)
		var shine := boot_col.lightened(0.30)
		ci.draw_rect(Rect2(left.x, left.y - 5.0, w, 5.0), plate)
		ci.draw_rect(Rect2(right.x, right.y - 5.0, w, 5.0), plate)
		ci.draw_circle(Vector2(left.x + w * 0.5, left.y - 5.0), 2.0, shine)
		ci.draw_circle(Vector2(right.x + w * 0.5, right.y - 5.0), 2.0, shine)
	elif boot_id.begins_with("adamant"):
		# Studded plate — multiple rivets down the shin.
		var plate := boot_col.darkened(0.15)
		var stud := boot_col.lightened(0.35)
		ci.draw_rect(Rect2(left.x, left.y - 4.0, w, 4.0), plate)
		ci.draw_rect(Rect2(right.x, right.y - 4.0, w, 4.0), plate)
		for row in range(2):
			var sy: float = -1.0 - float(row) * 2.0
			ci.draw_circle(Vector2(left.x + 1.0, left.y + sy), 0.5, stud)
			ci.draw_circle(Vector2(left.x + w - 1.0, left.y + sy), 0.5, stud)
			ci.draw_circle(Vector2(right.x + 1.0, right.y + sy), 0.5, stud)
			ci.draw_circle(Vector2(right.x + w - 1.0, right.y + sy), 0.5, stud)
	elif boot_id.begins_with("runite"):
		# Full sabaton — wide overhanging toe + tall calf.
		var plate := boot_col.darkened(0.15)
		var shine := boot_col.lightened(0.25)
		ci.draw_rect(Rect2(left.x - 1.0, left.y - 6.0, w + 1.0, 6.0), plate)
		ci.draw_rect(Rect2(right.x, right.y - 6.0, w + 1.0, 6.0), plate)
		# Toe overhang
		ci.draw_rect(Rect2(left.x - 1.5, left.y + 3.0, w + 2.0, 1.5), plate.darkened(0.15))
		ci.draw_rect(Rect2(right.x - 0.5, right.y + 3.0, w + 2.0, 1.5), plate.darkened(0.15))
		# Highlight ridge
		ci.draw_line(Vector2(left.x + w * 0.5, left.y - 5.5),
			Vector2(left.x + w * 0.5, left.y + 2.5), shine, 0.7)
		ci.draw_line(Vector2(right.x + w * 0.5, right.y - 5.5),
			Vector2(right.x + w * 0.5, right.y + 2.5), shine, 0.7)
	elif boot_id.begins_with("dragon"):
		# Clawed heel + scale texture — a red-scale sabaton with talons
		# poking out the front.
		var scale_col := boot_col.darkened(0.10)
		var scale_lt := boot_col.lightened(0.25)
		ci.draw_rect(Rect2(left.x - 1.0, left.y - 6.0, w + 1.0, 6.0), scale_col)
		ci.draw_rect(Rect2(right.x, right.y - 6.0, w + 1.0, 6.0), scale_col)
		# Scale arcs
		for r in range(3):
			var sy: float = -1.0 - float(r) * 2.0
			ci.draw_arc(Vector2(left.x + w * 0.5, left.y + sy), 1.6,
				PI, TAU, 6, scale_lt, 0.7)
			ci.draw_arc(Vector2(right.x + w * 0.5, right.y + sy), 1.6,
				PI, TAU, 6, scale_lt, 0.7)
		# Talon tips
		for tx in [-1.0, 1.0, 3.0]:
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(left.x + tx, left.y + 4.0),
				Vector2(left.x + tx + 1.0, left.y + 4.0),
				Vector2(left.x + tx + 0.5, left.y + 6.5)]),
				Color(0.95, 0.95, 0.85))
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(right.x + tx + 1.0, right.y + 4.0),
				Vector2(right.x + tx + 2.0, right.y + 4.0),
				Vector2(right.x + tx + 1.5, right.y + 6.5)]),
				Color(0.95, 0.95, 0.85))
	# Unknown boot id → no overlay, base rect stays.
