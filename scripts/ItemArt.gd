class_name ItemArt
extends RefCounted

## Central procedural draw registry for items that don't ship with a PNG in
## assets/icons/. Both the ground drop (LootDrop.gd) and the inventory /
## bank slot fill (HUD.gd) route missing-icon items through here so the
## visual is consistent everywhere the player sees the item.
##
## Two public entry points:
##   draw_ground_icon(ci, item_id, bob_y, item_color) → true if handled
##   draw_inventory_icon(ci, item_id, item_color, size) → true if handled
##
## Both fall back to `_draw_loot_pouch_*` for unknown ids so an unshipped
## item still reads as a proper pickup, not debug art.

const _Fishing = preload("res://scripts/Fishing.gd")

# ── Palette shortcuts ────────────────────────────────────────────────────────
const _CITY_HUE: Dictionary = {
	"pledge_kjelvik":   Color(0.85, 0.72, 0.30),   # gold-brown, hub town
	"pledge_bjorn":     Color(0.85, 0.45, 0.25),   # coastal orange
	"pledge_frostheim": Color(0.55, 0.85, 0.98),   # ice blue
	"pledge_ironwood":  Color(0.45, 0.72, 0.30),   # forest green
	"pledge_eastmark":  Color(0.72, 0.55, 0.30),   # sand brown
}

# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC ENTRY — ground drop (LootDrop._draw calls this)
# ══════════════════════════════════════════════════════════════════════════════
## Draws the item at (0, bob_y) in the LootDrop canvas. Returns true if the
## id was handled — LootDrop should skip its own fallback in that case.
## `_item_color` (unused today) stays on the signature so future per-id
## draws that WANT to tint from the item's palette have it available; the
## loot-pouch fallback uses `item_color` directly via `draw_ground_pouch`.
static func draw_ground_icon(ci: CanvasItem, item_id: String, bob_y: float,
		_item_color: Color) -> bool:
	# Token-upgraded gear (Phase 1d) carries a "~u{level}" id suffix — draw it
	# with its base icon so a "+3" runite body still looks like runite body.
	var _up := item_id.find("~u")
	if _up >= 0:
		item_id = item_id.substr(0, _up)
	# Political / faction tokens
	if item_id in _CITY_HUE:
		_draw_pledge(ci, bob_y, _CITY_HUE[item_id])
		return true
	if item_id == "high_seat_warrant":
		_draw_warrant_scroll(ci, bob_y)
		return true
	# Jewelcrafting gems — faceted cut with a bright glint.
	if item_id == "opal":
		_draw_gem(ci, bob_y, Color(0.82, 0.90, 0.95), Color(0.95, 0.98, 1.00))
		return true
	if item_id == "amethyst":
		_draw_gem(ci, bob_y, Color(0.62, 0.38, 0.85), Color(0.82, 0.60, 1.00))
		return true
	if item_id == "diamond":
		_draw_gem(ci, bob_y, Color(0.80, 0.92, 1.00), Color(1.00, 1.00, 1.00))
		return true
	if item_id == "frost_token":
		_draw_faction_token(ci, bob_y, "frost")
		return true
	if item_id == "iron_token":
		_draw_faction_token(ci, bob_y, "iron")
		return true
	if item_id == "sea_token":
		_draw_faction_token(ci, bob_y, "sea")
		return true
	if item_id == "grove_token":
		_draw_faction_token(ci, bob_y, "grove")
		return true
	if item_id == "ash_token":
		_draw_faction_token(ci, bob_y, "ash")
		return true
	# Teeth
	if item_id == "plague_tooth":
		_draw_tooth(ci, bob_y, Color(0.82, 0.85, 0.30))
		return true
	if item_id == "shark_tooth":
		_draw_tooth(ci, bob_y, Color(0.95, 0.95, 0.90))
		return true
	# Farm crops
	if item_id == "carrot":
		_draw_carrot(ci, bob_y)
		return true
	if item_id == "potato":
		_draw_potato(ci, bob_y)
		return true
	if item_id == "moonwheat":
		_draw_moonwheat(ci, bob_y)
		return true
	# Deep-fishing catches
	if item_id == "frost_cod":
		_draw_fish(ci, bob_y, Color(0.72, 0.85, 0.95), Color(0.42, 0.62, 0.85))
		return true
	if item_id == "void_squid":
		_draw_squid(ci, bob_y)
		return true
	if item_id == "deep_runefish":
		_draw_fish(ci, bob_y, Color(0.55, 0.35, 0.90), Color(0.25, 0.15, 0.60))
		return true
	if item_id == "lava_eel":
		_draw_eel(ci, bob_y, Color(0.95, 0.35, 0.10))
		return true
	if item_id == "abyssal_pearl":
		_draw_pearl(ci, bob_y)
		return true
	if item_id == "sea_serpent_scale":
		_draw_scale(ci, bob_y)
		return true
	if item_id == "kraken_meat":
		_draw_meat_chunk(ci, bob_y, Color(0.55, 0.30, 0.55))
		return true
	if item_id == "leviathan_eye":
		_draw_eye(ci, bob_y)
		return true
	# ── Gathered materials (art pass v1.5.3) — previously all fell through to
	# the generic loot pouch. Suffix-dispatched with a per-tier tint.
	if item_id.ends_with("_ore"):
		_draw_ore(ci, bob_y, _mat_tint(item_id))
		return true
	if item_id.ends_with("_bar"):
		_draw_bar(ci, bob_y, _mat_tint(item_id))
		return true
	if item_id.ends_with("_log"):
		_draw_log(ci, bob_y, _mat_tint(item_id))
		return true
	if item_id.ends_with("_pelt") or item_id.ends_with("_hide"):
		var hide_c := Color(0.55, 0.45, 0.32)
		if item_id.begins_with("wolf"):    hide_c = Color(0.55, 0.52, 0.48)
		elif item_id.begins_with("troll"): hide_c = Color(0.40, 0.46, 0.30)
		elif item_id.begins_with("bear"):  hide_c = Color(0.45, 0.30, 0.14)
		_draw_hide(ci, bob_y, hide_c)
		return true
	if item_id == "bone" or item_id == "rat_bone" or item_id.ends_with("_bone"):
		_draw_bone(ci, bob_y)
		return true
	if item_id in ["raw_fish", "raw_salmon", "raw_shark", "raw_trout", "lobster"]:
		var fbody := Color(0.72, 0.80, 0.88)
		var fback := Color(0.42, 0.55, 0.70)
		if item_id == "raw_salmon":
			fbody = Color(0.95, 0.58, 0.42); fback = Color(0.80, 0.38, 0.28)
		elif item_id == "lobster":
			fbody = Color(0.85, 0.30, 0.22); fback = Color(0.65, 0.18, 0.14)
		_draw_fish(ci, bob_y, fbody, fback)
		return true
	# ── Jewelry (v1.6.1) — metal tiers ship PNGs; GEM rings/amulets land here.
	if item_id.ends_with("_ring"):
		_draw_ring(ci, bob_y, _jewel_tint(item_id))
		return true
	if item_id.ends_with("_amulet"):
		_draw_amulet(ci, bob_y, _jewel_tint(item_id))
		return true
	# ── Pickaxes (v1.6.1) — some tiers lack a PNG; tier-tinted procedural head.
	if item_id.ends_with("_pickaxe"):
		_draw_pickaxe(ci, bob_y, _mat_tint(item_id))
		return true
	# ── Cooked food / gathered goods without a PNG (v1.6.1).
	if item_id == "wheat_bread" or item_id == "moonwheat_loaf":
		_draw_bread(ci, bob_y, item_id == "moonwheat_loaf")
		return true
	if item_id == "carrot_stew":
		_draw_stew(ci, bob_y)
		return true
	if item_id == "ale_keg":
		_draw_keg(ci, bob_y)
		return true
	if item_id == "salt_sack":
		_draw_sack(ci, bob_y, Color(0.90, 0.88, 0.82))
		return true
	if item_id == "fur_bundle":
		_draw_fur_bundle(ci, bob_y)
		return true
	if item_id == "wool_cloth":
		_draw_cloth(ci, bob_y, Color(0.92, 0.90, 0.82))
		return true
	if item_id == "troll_heart":
		_draw_organ(ci, bob_y, Color(0.58, 0.12, 0.30))
		return true
	# ── Farming (1.6.2): seeds, crops, and crop dishes tinted by roster colour.
	if item_id.ends_with("_seed"):
		_draw_seed(ci, bob_y, _item_color)
		return true
	if item_id == "carrot":
		_draw_carrot(ci, bob_y); return true
	if item_id == "potato":
		_draw_potato(ci, bob_y); return true
	if item_id == "moonwheat":
		_draw_moonwheat(ci, bob_y); return true
	if item_id in ["wheat", "barley", "rye", "corn", "cabbage", "cotton",
			"pepper", "sugarcane", "hops", "tomato", "blueberry", "lingonberry",
			"strawberry", "peach", "apple", "watermelon", "grape"]:
		_draw_produce(ci, bob_y, _item_color)
		return true
	if item_id == "ale" or item_id == "fine_wine":
		_draw_keg(ci, bob_y); return true
	# Bowled / stewed farming dishes.
	if item_id in ["garden_salad", "farmers_stew", "carrot_stew",
			"barley_porridge", "berry_fruit_bowl"]:
		_draw_stew(ci, bob_y); return true
	# Baked loaves / pies.
	if item_id in ["dark_bread", "apple_pie", "peach_cobbler", "sweet_loaf",
			"wheat_bread", "moonwheat_loaf"]:
		_draw_bread(ci, bob_y, false); return true
	# Plated single-crop dishes — tinted produce reads better than a pouch.
	if item_id in ["steamed_cabbage", "roasted_corn", "boiled_potato",
			"stuffed_pepper", "melon_slice"]:
		_draw_produce(ci, bob_y, _item_color); return true
	# Sea-combat consumables (1.6.3).
	if item_id == "hull_patch":
		_draw_hull_patch(ci, bob_y); return true
	if item_id == "fishing_net":
		_draw_fishing_net(ci, bob_y); return true
	if item_id == "chum_bucket":
		_draw_chum_bucket(ci, bob_y); return true
	# Mounted trophy fish — a plaque with a fish silhouette.
	if item_id.begins_with("mounted_"):
		_draw_mounted_fish(ci, bob_y, _item_color); return true
	# Fishing tackle (1.6.3) — bait = a grub on a hook, lure = a metal spoon.
	if _Fishing.is_lure(item_id):
		_draw_lure(ci, bob_y, _item_color); return true
	if _Fishing.is_bait(item_id):
		_draw_bait(ci, bob_y, _item_color); return true
	return false

# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC ENTRY — inventory / bank slot (HUD calls this when no PNG exists)
# ══════════════════════════════════════════════════════════════════════════════
## Draws the item icon centered inside a `size × size` slot on `ci`. The
## same procedural functions are reused with a bob_y of 0 and a small
## upscale via draw_set_transform so a 22-px slot fills correctly.
static func draw_inventory_icon(ci: CanvasItem, item_id: String,
		item_color: Color, size: float) -> bool:
	var s: float = size / 20.0   # LootDrop art is authored around ~20 px
	ci.draw_set_transform(Vector2(size * 0.5, size * 0.5), 0.0, Vector2(s, s))
	var handled := draw_ground_icon(ci, item_id, 0.0, item_color)
	if not handled:
		_draw_loot_pouch(ci, 0.0, item_color)
		handled = true
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return handled

## Loot-pouch fallback exposed publicly so LootDrop can use it as its own
## final fallback path (post-dispatch).
static func draw_ground_pouch(ci: CanvasItem, bob_y: float,
		item_color: Color) -> void:
	_draw_loot_pouch(ci, bob_y, item_color)

# ══════════════════════════════════════════════════════════════════════════════
# PROCEDURAL DRAWS
# ══════════════════════════════════════════════════════════════════════════════

## Faceted gem — a diamond/kite silhouette with a bright glint. `body` is the
## gem's main color, `glint` the highlight. Used for opal/amethyst/diamond.
static func _draw_gem(ci: CanvasItem, bob_y: float, body: Color, glint: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	# Kite-shaped gem outline.
	var pts := PackedVector2Array([
		Vector2(pos.x,        pos.y - 6.0),   # top point
		Vector2(pos.x + 5.0,  pos.y - 1.0),   # right
		Vector2(pos.x,        pos.y + 6.0),   # bottom point
		Vector2(pos.x - 5.0,  pos.y - 1.0)])  # left
	ci.draw_colored_polygon(pts, body)
	# Upper crown facet (lighter) + rim.
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x,       pos.y - 6.0),
		Vector2(pos.x + 5.0, pos.y - 1.0),
		Vector2(pos.x - 5.0, pos.y - 1.0)]), body.lightened(0.20))
	ci.draw_polyline(PackedVector2Array([
		pts[0], pts[1], pts[2], pts[3], pts[0]]), body.darkened(0.30), 0.8)
	# Center facet line + bright glint.
	ci.draw_line(Vector2(pos.x - 5.0, pos.y - 1.0),
		Vector2(pos.x + 5.0, pos.y - 1.0), body.darkened(0.20), 0.7)
	ci.draw_circle(Vector2(pos.x - 1.6, pos.y - 2.5), 1.1, glint)

## Material tint by tier prefix (metals + woods) — art pass v1.5.3.
static func _mat_tint(item_id: String) -> Color:
	if item_id.begins_with("copper"):   return Color(0.82, 0.52, 0.22)
	if item_id.begins_with("iron"):     return Color(0.62, 0.62, 0.68)
	if item_id.begins_with("gold"):     return Color(0.95, 0.82, 0.18)
	if item_id.begins_with("mithril"):  return Color(0.45, 0.72, 0.92)
	if item_id.begins_with("adamant"):  return Color(0.24, 0.70, 0.38)
	if item_id.begins_with("runite"):   return Color(0.72, 0.28, 0.90)
	if item_id.begins_with("oak"):      return Color(0.56, 0.40, 0.20)
	if item_id.begins_with("pine"):     return Color(0.70, 0.56, 0.34)
	if item_id.begins_with("cherry"):   return Color(0.60, 0.33, 0.28)
	if item_id.begins_with("ironwood"): return Color(0.36, 0.31, 0.27)
	if item_id.begins_with("frost"):    return Color(0.62, 0.80, 0.90)
	if item_id.begins_with("ancient"):  return Color(0.42, 0.35, 0.20)
	return Color(0.60, 0.58, 0.54)

## Raw ore — a grey rock lump with tinted metal veins glinting through.
static func _draw_ore(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var p := Vector2(0.0, bob_y)
	var rock := Color(0.40, 0.38, 0.37)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-6, 1), p + Vector2(-3, -5), p + Vector2(4, -6),
		p + Vector2(7, -1), p + Vector2(5, 5), p + Vector2(-4, 6)]), rock)
	ci.draw_polyline(PackedVector2Array([
		p + Vector2(-6, 1), p + Vector2(-3, -5), p + Vector2(4, -6),
		p + Vector2(7, -1), p + Vector2(5, 5), p + Vector2(-4, 6),
		p + Vector2(-6, 1)]), rock.darkened(0.35), 0.8)
	# Metal veins in the tier colour.
	ci.draw_circle(p + Vector2(-1, -1), 1.9, tint)
	ci.draw_circle(p + Vector2(3, 2), 1.4, tint.lightened(0.2))
	ci.draw_circle(p + Vector2(2, -3), 1.1, tint)
	ci.draw_circle(p + Vector2(-1.6, -1.6), 0.7, tint.lightened(0.5))   # glint

## Refined bar — a stacked ingot with a lit top face.
static func _draw_bar(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var y := bob_y + 1.0
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(-6, y - 1), Vector2(6, y - 1), Vector2(5, y + 4), Vector2(-5, y + 4)]),
		tint)                                              # front face
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(-6, y - 1), Vector2(6, y - 1), Vector2(6.5, y - 3.5),
		Vector2(-5.5, y - 3.5)]), tint.lightened(0.28))    # top face (lit)
	ci.draw_line(Vector2(-5, y - 3), Vector2(5.5, y - 3), tint.lightened(0.5), 0.8)
	ci.draw_line(Vector2(-5, y + 4), Vector2(5, y + 4), tint.darkened(0.3), 0.8)

## Log — a short round timber with a ringed cut end.
static func _draw_log(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var y := bob_y
	var bark := tint.darkened(0.25)
	ci.draw_rect(Rect2(-6, y - 3.2, 11, 6.4), bark)                 # side
	ci.draw_rect(Rect2(-6, y - 3.2, 11, 1.4), tint.darkened(0.05))  # lit top
	ci.draw_circle(Vector2(5, y), 3.4, tint.lightened(0.12))        # cut end
	ci.draw_arc(Vector2(5, y), 2.3, 0.0, TAU, 10, tint.darkened(0.2), 0.7)
	ci.draw_arc(Vector2(5, y), 1.2, 0.0, TAU, 8, tint.darkened(0.2), 0.7)
	ci.draw_circle(Vector2(5, y), 0.6, tint.darkened(0.35))

## Stretched pelt/hide — a soft cross-shaped skin.
static func _draw_hide(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var p := Vector2(0.0, bob_y)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(0, -6), p + Vector2(3, -3), p + Vector2(6, -1),
		p + Vector2(3, 2), p + Vector2(4, 6), p + Vector2(0, 3),
		p + Vector2(-4, 6), p + Vector2(-3, 2), p + Vector2(-6, -1),
		p + Vector2(-3, -3)]), tint)
	ci.draw_circle(p + Vector2(-1, -1), 2.0, tint.lightened(0.15))   # soft sheen
	ci.draw_circle(p, 0.8, tint.darkened(0.25))

## Bone — a simple femur shape.
static func _draw_bone(ci: CanvasItem, bob_y: float) -> void:
	var c := Color(0.90, 0.88, 0.78)
	ci.draw_line(Vector2(-4, bob_y - 4), Vector2(4, bob_y + 4), c, 2.4)
	ci.draw_circle(Vector2(-4, bob_y - 4), 1.8, c)
	ci.draw_circle(Vector2(-5.4, bob_y - 3), 1.4, c)
	ci.draw_circle(Vector2(4, bob_y + 4), 1.8, c)
	ci.draw_circle(Vector2(5.4, bob_y + 3), 1.4, c)

## Political pledge — a rolled cloth banner with a city-hued strip.
static func _draw_pledge(ci: CanvasItem, bob_y: float, hue: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	var cream := Color(0.92, 0.86, 0.68)
	var dark := Color(0.32, 0.24, 0.12)
	# Rolled cloth body
	ci.draw_rect(Rect2(pos.x - 6.0, pos.y - 6.0, 12.0, 12.0), cream)
	ci.draw_rect(Rect2(pos.x - 6.0, pos.y - 6.0, 12.0, 12.0), dark, false, 1.0)
	# City-color stripe across the middle
	ci.draw_rect(Rect2(pos.x - 6.0, pos.y - 1.5, 12.0, 3.0), hue)
	# Twin ribbon tails at the bottom
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 4.0, pos.y + 6.0),
		Vector2(pos.x - 2.5, pos.y + 6.0),
		Vector2(pos.x - 3.0, pos.y + 9.0)]), hue.darkened(0.15))
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x + 2.5, pos.y + 6.0),
		Vector2(pos.x + 4.0, pos.y + 6.0),
		Vector2(pos.x + 3.0, pos.y + 9.0)]), hue.darkened(0.15))

## High Seat Warrant — a longer parchment scroll with a red wax seal.
static func _draw_warrant_scroll(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	var parchment := Color(0.92, 0.85, 0.62)
	var edge := Color(0.55, 0.40, 0.18)
	# Scroll body (rolled — narrow at ends, wider in middle)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 8.0, pos.y - 4.0),
		Vector2(pos.x + 8.0, pos.y - 4.0),
		Vector2(pos.x + 8.0, pos.y + 4.0),
		Vector2(pos.x - 8.0, pos.y + 4.0)]), parchment)
	# Rolled caps
	ci.draw_circle(Vector2(pos.x - 8.0, pos.y), 4.0, edge)
	ci.draw_circle(Vector2(pos.x + 8.0, pos.y), 4.0, edge)
	# Red wax seal on the face
	ci.draw_circle(Vector2(pos.x, pos.y + 1.0), 2.8, Color(0.72, 0.10, 0.10))
	ci.draw_circle(Vector2(pos.x, pos.y + 1.0), 1.5, Color(0.55, 0.05, 0.05))

## Faction token — a small coin with a themed motif.
static func _draw_faction_token(ci: CanvasItem, bob_y: float, kind: String) -> void:
	var pos := Vector2(0.0, bob_y)
	var base: Color
	match kind:
		"frost":  base = Color(0.55, 0.85, 0.98)
		"iron":   base = Color(0.65, 0.65, 0.70)
		"sea":    base = Color(0.18, 0.55, 0.85)
		"grove":  base = Color(0.35, 0.62, 0.28)
		"ash":    base = Color(0.85, 0.35, 0.15)
		_:        base = Color(0.60, 0.60, 0.60)
	# Coin outer + inner ring
	ci.draw_circle(pos, 7.0, base.darkened(0.28))
	ci.draw_circle(pos, 6.0, base)
	ci.draw_circle(pos + Vector2(-1.5, -1.5), 1.4, base.lightened(0.35))
	match kind:
		"frost":
			# Snowflake — 3 crossed lines
			var c := Color(0.98, 0.98, 1.00)
			ci.draw_line(pos + Vector2(-3, 0), pos + Vector2(3, 0), c, 1.2)
			ci.draw_line(pos + Vector2(-2, -2), pos + Vector2(2, 2), c, 1.2)
			ci.draw_line(pos + Vector2(-2, 2), pos + Vector2(2, -2), c, 1.2)
		"iron":
			# Bar / ingot motif
			ci.draw_rect(Rect2(pos.x - 3.0, pos.y - 1.0, 6.0, 2.0), Color(0.30, 0.30, 0.32))
		"sea":
			# Wave motif — two arcs
			ci.draw_arc(pos + Vector2(-1, 0), 2.2, PI, TAU, 6, Color(0.90, 0.95, 1.00), 1.2)
			ci.draw_arc(pos + Vector2(2, 1), 1.8, PI, TAU, 6, Color(0.90, 0.95, 1.00), 1.0)
		"grove":
			# Leaf — two arcs meeting at a point, with a midrib
			var lc := Color(0.90, 0.98, 0.85)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(pos.x, pos.y - 3.2),
				Vector2(pos.x + 2.4, pos.y + 0.4),
				Vector2(pos.x, pos.y + 3.2),
				Vector2(pos.x - 2.4, pos.y + 0.4)]), lc)
			ci.draw_line(pos + Vector2(0, -3.0), pos + Vector2(0, 3.0), Color(0.30, 0.55, 0.25), 0.8)
		"ash":
			# Flame — a tapered ember tongue
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(pos.x, pos.y - 3.4),
				Vector2(pos.x + 2.2, pos.y + 1.0),
				Vector2(pos.x, pos.y + 3.0),
				Vector2(pos.x - 2.2, pos.y + 1.0)]), Color(1.00, 0.80, 0.30))
			ci.draw_circle(pos + Vector2(0, 1.2), 1.2, Color(1.00, 0.55, 0.15))

## Tooth — pointed enamel triangle with a shaded root.
static func _draw_tooth(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	# Crown (bright)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 3.5, pos.y - 3.0),
		Vector2(pos.x + 3.5, pos.y - 3.0),
		Vector2(pos.x + 2.5, pos.y + 4.5),
		Vector2(pos.x - 2.5, pos.y + 4.5)]), tint)
	# Root (darker)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 2.5, pos.y + 4.5),
		Vector2(pos.x + 2.5, pos.y + 4.5),
		Vector2(pos.x + 0.8, pos.y + 7.0),
		Vector2(pos.x - 0.8, pos.y + 7.0)]), tint.darkened(0.35))
	# Highlight
	ci.draw_line(Vector2(pos.x - 2.5, pos.y - 2.0),
		Vector2(pos.x - 1.0, pos.y + 3.5), tint.lightened(0.4), 0.7)

## Carrot — orange triangular root + green frond top.
static func _draw_carrot(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	# Root
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 3.0, pos.y - 2.0),
		Vector2(pos.x + 3.0, pos.y - 2.0),
		Vector2(pos.x, pos.y + 6.0)]), Color(0.95, 0.55, 0.20))
	# Root highlight
	ci.draw_line(Vector2(pos.x - 1.5, pos.y - 1.0),
		Vector2(pos.x - 0.5, pos.y + 3.0),
		Color(1.00, 0.75, 0.35), 0.8)
	# Green frond leaves
	for lx in [-2.5, 0.0, 2.5]:
		ci.draw_line(Vector2(pos.x + lx * 0.3, pos.y - 2.0),
			Vector2(pos.x + lx, pos.y - 6.0),
			Color(0.30, 0.62, 0.28), 1.2)

static func _draw_potato(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	# Lumpy tuber — approximated with three overlapping circles
	var brown := Color(0.62, 0.45, 0.28)
	ci.draw_circle(pos + Vector2(-2, 0), 3.5, brown.darkened(0.15))
	ci.draw_circle(pos + Vector2(2, 1), 3.2, brown.darkened(0.15))
	ci.draw_circle(pos + Vector2(0, -1), 4.0, brown)
	# Eye dots
	ci.draw_circle(pos + Vector2(-1, 1), 0.6, brown.darkened(0.4))
	ci.draw_circle(pos + Vector2(2, -2), 0.6, brown.darkened(0.4))

static func _draw_moonwheat(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	# Pale blue wheat sheaf — three angled stalks with grain kernels
	var stalk := Color(0.65, 0.75, 0.95)
	var grain := Color(0.85, 0.92, 1.00)
	for i in range(3):
		var ang: float = -PI * 0.5 + (float(i) - 1.0) * 0.35
		var tip := pos + Vector2(cos(ang), sin(ang)) * 6.0
		var base := pos + Vector2(cos(ang), sin(ang)) * 0.5
		ci.draw_line(base, tip, stalk, 1.4)
		# Kernel triangles on both sides of the stalk
		for j in range(3):
			var t: float = 0.4 + float(j) * 0.2
			var mid := base.lerp(tip, t)
			var perp := Vector2(-sin(ang), cos(ang)) * 1.5
			ci.draw_circle(mid + perp, 0.8, grain)
			ci.draw_circle(mid - perp, 0.8, grain)

## Generic seed packet — a paper sachet with a few tinted seeds spilling out.
## Tint is the crop's roster colour so every seed reads distinctly.
static func _draw_seed(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	var paper := Color(0.86, 0.80, 0.62)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 4.0, pos.y - 4.5), Vector2(pos.x + 4.0, pos.y - 4.5),
		Vector2(pos.x + 4.0, pos.y + 4.5), Vector2(pos.x - 4.0, pos.y + 4.5)]), paper)
	ci.draw_line(Vector2(pos.x - 4.0, pos.y - 2.0), Vector2(pos.x + 4.0, pos.y - 2.0),
		paper.darkened(0.25), 0.8)
	# Seeds spilling from the packet, tinted by crop.
	ci.draw_circle(pos + Vector2(-1.6, 1.6), 1.4, tint)
	ci.draw_circle(pos + Vector2(1.6, 2.2), 1.3, tint.darkened(0.12))
	ci.draw_circle(pos + Vector2(0.2, 0.2), 1.2, tint.lightened(0.18))

## Generic produce — a rounded fruit/veg with a little leaf, tinted by the
## crop's roster colour. Used for every crop without a bespoke drawer.
static func _draw_produce(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	ci.draw_circle(pos, 4.6, tint.darkened(0.14))
	ci.draw_circle(pos, 4.0, tint)
	ci.draw_circle(pos + Vector2(-1.4, -1.4), 1.3, tint.lightened(0.30))  # highlight
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x, pos.y - 3.8), Vector2(pos.x + 2.6, pos.y - 6.2),
		Vector2(pos.x + 0.6, pos.y - 3.2)]), Color(0.32, 0.62, 0.28))  # leaf

## Generic fish — top-down oval with tail fin + eye. Palette per species.
static func _draw_fish(ci: CanvasItem, bob_y: float, body: Color, back: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	# Body oval — approximated as two overlapping circles for a spindle shape
	ci.draw_circle(pos + Vector2(-1.5, 0), 3.5, body)
	ci.draw_circle(pos + Vector2(1.5, 0), 3.5, body)
	# Dorsal darker band
	ci.draw_line(Vector2(pos.x - 3.5, pos.y - 1.5),
		Vector2(pos.x + 3.5, pos.y - 1.5), back, 1.3)
	# Tail
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x + 4.5, pos.y),
		Vector2(pos.x + 7.5, pos.y - 3.0),
		Vector2(pos.x + 7.5, pos.y + 3.0)]), back.darkened(0.15))
	# Eye
	ci.draw_circle(Vector2(pos.x - 3.0, pos.y - 0.5), 0.7, Color(0.05, 0.05, 0.05))

## Squid — bulbous head + tentacles below. Void = deep purple with faint stars.
static func _draw_squid(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	var body := Color(0.28, 0.15, 0.42)
	var pale := Color(0.55, 0.35, 0.70)
	# Head
	ci.draw_circle(pos + Vector2(0, -2), 4.0, body)
	# Two fins on the sides of the head
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 5, pos.y - 3),
		Vector2(pos.x - 3, pos.y - 5),
		Vector2(pos.x - 3, pos.y - 1)]), pale)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x + 5, pos.y - 3),
		Vector2(pos.x + 3, pos.y - 5),
		Vector2(pos.x + 3, pos.y - 1)]), pale)
	# Tentacles
	for i in range(5):
		var tx: float = -3.0 + float(i) * 1.5
		ci.draw_line(Vector2(pos.x + tx, pos.y),
			Vector2(pos.x + tx * 0.7, pos.y + 5),
			body.darkened(0.15), 1.2)
	# Void starlets — two tiny highlights on the head
	ci.draw_circle(pos + Vector2(-1.5, -3), 0.5, Color(0.95, 0.95, 1.00))
	ci.draw_circle(pos + Vector2(1.0, -1.0), 0.4, Color(0.85, 0.85, 1.00))

static func _draw_eel(ci: CanvasItem, bob_y: float, body: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	# S-curved body: 3 overlapping circles along a subtle wave
	ci.draw_circle(pos + Vector2(-4, 1), 2.5, body)
	ci.draw_circle(pos + Vector2(0, -1), 3.0, body)
	ci.draw_circle(pos + Vector2(4, 1), 2.5, body)
	# Head + eye
	ci.draw_circle(pos + Vector2(-6, 1), 2.0, body.darkened(0.15))
	ci.draw_circle(pos + Vector2(-6.5, 0.5), 0.5, Color(0.10, 0.10, 0.05))
	# Tail fin
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x + 6, pos.y),
		Vector2(pos.x + 8, pos.y - 2),
		Vector2(pos.x + 8, pos.y + 2)]), body.darkened(0.2))

static func _draw_pearl(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	# Iridescent orb — layered gradient
	ci.draw_circle(pos, 5.5, Color(0.55, 0.60, 0.75))
	ci.draw_circle(pos, 4.5, Color(0.75, 0.80, 0.90))
	ci.draw_circle(pos, 3.0, Color(0.92, 0.95, 1.00))
	ci.draw_circle(pos + Vector2(-1.5, -1.5), 1.2, Color(1.00, 1.00, 1.00))

static func _draw_scale(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	# Fan-shaped opalescent scale
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x, pos.y - 6.0),
		Vector2(pos.x + 5.0, pos.y + 3.0),
		Vector2(pos.x - 5.0, pos.y + 3.0)]), Color(0.55, 0.75, 0.62))
	# Highlight streak
	ci.draw_line(Vector2(pos.x, pos.y - 5.0),
		Vector2(pos.x - 2.0, pos.y + 2.0),
		Color(0.85, 0.95, 0.90), 0.7)
	# Rim outline
	ci.draw_polyline(PackedVector2Array([
		Vector2(pos.x, pos.y - 6.0),
		Vector2(pos.x + 5.0, pos.y + 3.0),
		Vector2(pos.x - 5.0, pos.y + 3.0),
		Vector2(pos.x, pos.y - 6.0)]),
		Color(0.25, 0.42, 0.35), 0.7)

static func _draw_meat_chunk(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	# Meat chunk — pentagonal blob with a darker rim
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 4.5, pos.y),
		Vector2(pos.x - 2.5, pos.y - 4.5),
		Vector2(pos.x + 3.0, pos.y - 4.0),
		Vector2(pos.x + 4.5, pos.y + 2.0),
		Vector2(pos.x - 1.5, pos.y + 5.0)]), tint)
	# Fat marbling — pale streaks
	ci.draw_line(Vector2(pos.x - 3, pos.y - 1),
		Vector2(pos.x + 2, pos.y + 2), Color(0.95, 0.90, 0.85, 0.8), 0.9)

static func _draw_eye(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	# Sclera
	ci.draw_circle(pos, 6.0, Color(0.95, 0.95, 0.90))
	# Vein streaks
	ci.draw_line(pos + Vector2(-5, -2), pos + Vector2(-1, -1),
		Color(0.85, 0.15, 0.20, 0.65), 0.5)
	ci.draw_line(pos + Vector2(5, 2), pos + Vector2(2, 1),
		Color(0.85, 0.15, 0.20, 0.65), 0.5)
	# Iris + pupil
	ci.draw_circle(pos, 3.0, Color(0.20, 0.55, 0.85))
	ci.draw_circle(pos, 1.6, Color(0.05, 0.05, 0.05))
	ci.draw_circle(pos + Vector2(-0.8, -0.8), 0.6, Color(1, 1, 1))

## Loot pouch — better fallback than a bare colored disc. Rounded pouch
## silhouette with a drawstring at the top and a colored dot for the
## item's own tint so unknown items are still visually distinct.
static func _draw_loot_pouch(ci: CanvasItem, bob_y: float, item_color: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	var leather := Color(0.55, 0.36, 0.18)
	var leather_dk := leather.darkened(0.25)
	# Body — inverted teardrop
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 4.5, pos.y - 2.0),
		Vector2(pos.x + 4.5, pos.y - 2.0),
		Vector2(pos.x + 5.5, pos.y + 2.0),
		Vector2(pos.x + 3.5, pos.y + 6.0),
		Vector2(pos.x - 3.5, pos.y + 6.0),
		Vector2(pos.x - 5.5, pos.y + 2.0)]), leather)
	# Drawstring cinched neck
	ci.draw_rect(Rect2(pos.x - 3.5, pos.y - 3.0, 7.0, 2.0), leather_dk)
	# Bow / knot at top
	ci.draw_circle(Vector2(pos.x - 1.5, pos.y - 4.0), 1.0, leather_dk)
	ci.draw_circle(Vector2(pos.x + 1.5, pos.y - 4.0), 1.0, leather_dk)
	# Peeking contents — colored dot near the mouth
	ci.draw_circle(pos + Vector2(0, -0.5), 1.5, item_color)

## Bait — a plump grub curled on a barbed hook, tinted by the bait's colour.
static func _draw_bait(ci: CanvasItem, bob_y: float, item_color: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	var steel := Color(0.72, 0.75, 0.80)
	# Hook — vertical shank + a curved bend.
	ci.draw_line(pos + Vector2(2.5, -6.0), pos + Vector2(2.5, 2.0), steel, 1.2)
	ci.draw_arc(pos + Vector2(0.8, 2.0), 1.8, 0.0, PI, 10, steel, 1.2)
	ci.draw_line(pos + Vector2(-1.0, 2.0), pos + Vector2(-1.6, 0.6), steel, 1.0)  # barb
	ci.draw_circle(pos + Vector2(2.5, -6.2), 1.0, steel)                          # eyelet
	# Grub — three fat overlapping segments coiled over the shank.
	var seg := item_color
	ci.draw_circle(pos + Vector2(-1.2, -3.0), 2.4, seg)
	ci.draw_circle(pos + Vector2(0.6, -1.4), 2.6, seg.lightened(0.08))
	ci.draw_circle(pos + Vector2(-0.4, 0.4), 2.2, seg)
	ci.draw_circle(pos + Vector2(-1.8, -3.6), 0.7, seg.lightened(0.35))           # sheen

## Lure — a metal spoon body with a bright glint and a small treble hook.
static func _draw_lure(ci: CanvasItem, bob_y: float, item_color: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	var steel := Color(0.72, 0.75, 0.80)
	# Split ring at the top.
	ci.draw_arc(pos + Vector2(0, -6.0), 1.4, 0.0, TAU, 12, steel, 1.0)
	# Spoon body — a teardrop blade tinted by the lure colour with a highlight.
	var body := PackedVector2Array([
		pos + Vector2(0.0, -4.4), pos + Vector2(2.8, -2.0),
		pos + Vector2(2.4, 2.6),  pos + Vector2(0.0, 4.4),
		pos + Vector2(-2.4, 2.6), pos + Vector2(-2.8, -2.0)])
	ci.draw_colored_polygon(body, item_color)
	ci.draw_circle(pos + Vector2(-0.9, -1.4), 1.0, item_color.lightened(0.5))      # glint
	# Treble hook below the blade.
	ci.draw_line(pos + Vector2(0, 4.2), pos + Vector2(0, 6.4), steel, 1.0)
	ci.draw_line(pos + Vector2(0, 6.4), pos + Vector2(-1.6, 5.4), steel, 1.0)
	ci.draw_line(pos + Vector2(0, 6.4), pos + Vector2(1.6, 5.4), steel, 1.0)

## Hull Patch — a fresh oak plank over the old, with iron rivets in the corners.
static func _draw_hull_patch(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	var old_wood := Color(0.42, 0.30, 0.18)
	var plank := Color(0.66, 0.48, 0.26)
	var iron := Color(0.55, 0.57, 0.62)
	# Old darker hull behind.
	ci.draw_rect(Rect2(pos.x - 6.0, pos.y - 5.0, 12.0, 10.0), old_wood)
	# The patch plank (angled a touch), lighter, with a grain line.
	ci.draw_colored_polygon(PackedVector2Array([
		pos + Vector2(-5.0, -3.6), pos + Vector2(5.0, -4.4),
		pos + Vector2(5.0, 3.6),   pos + Vector2(-5.0, 4.4)]), plank)
	ci.draw_line(pos + Vector2(-4.5, -0.4), pos + Vector2(4.5, -1.0),
		plank.darkened(0.25), 1.0)
	# Iron rivets.
	for rv: Vector2 in [Vector2(-3.6, -2.6), Vector2(3.4, -3.0),
			Vector2(3.4, 2.4), Vector2(-3.6, 2.8)]:
		ci.draw_circle(pos + rv, 0.9, iron)
		ci.draw_circle(pos + rv + Vector2(-0.3, -0.3), 0.3, iron.lightened(0.4))

## Fishing Net — a draped diamond mesh with a weighted bottom edge.
static func _draw_fishing_net(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	var cord := Color(0.80, 0.76, 0.58)
	var cord_dk := cord.darkened(0.25)
	# Diagonal weave both ways over a rough triangle drape.
	for i in range(-3, 4):
		var x := float(i) * 1.7
		ci.draw_line(pos + Vector2(x, -5.0), pos + Vector2(x + 3.4, 5.0), cord, 0.8)
		ci.draw_line(pos + Vector2(x, -5.0), pos + Vector2(x - 3.4, 5.0), cord, 0.8)
	# Top rope + a couple of bottom sinker weights.
	ci.draw_line(pos + Vector2(-5.5, -5.0), pos + Vector2(5.5, -5.0), cord_dk, 1.4)
	ci.draw_circle(pos + Vector2(-2.2, 5.2), 1.1, cord_dk)
	ci.draw_circle(pos + Vector2(2.4, 5.0), 1.1, cord_dk)

## Chum Bucket — a wooden pail brimming with mashed fish bait.
static func _draw_chum_bucket(ci: CanvasItem, bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	var pail := Color(0.50, 0.38, 0.28)
	var band := pail.darkened(0.3)
	var chum := Color(0.72, 0.42, 0.44)
	# Tapered bucket body.
	ci.draw_colored_polygon(PackedVector2Array([
		pos + Vector2(-4.6, -2.0), pos + Vector2(4.6, -2.0),
		pos + Vector2(3.6, 6.0),   pos + Vector2(-3.6, 6.0)]), pail)
	ci.draw_line(pos + Vector2(-4.2, 2.0), pos + Vector2(4.2, 2.0), band, 1.0)
	# Chum heaped above the rim + a stray fish tail poking out.
	ci.draw_circle(pos + Vector2(-1.6, -2.4), 2.0, chum)
	ci.draw_circle(pos + Vector2(1.6, -2.6), 2.2, chum.lightened(0.1))
	ci.draw_colored_polygon(PackedVector2Array([
		pos + Vector2(3.0, -3.6), pos + Vector2(5.2, -5.2),
		pos + Vector2(4.4, -2.8)]), Color(0.62, 0.72, 0.78))
	# Handle.
	ci.draw_arc(pos + Vector2(0, -2.0), 4.2, PI, TAU, 12, band, 1.0)

## Mounted trophy fish — a wooden plaque with a fish silhouette tinted to species.
static func _draw_mounted_fish(ci: CanvasItem, bob_y: float, item_color: Color) -> void:
	var pos := Vector2(0.0, bob_y)
	var board := Color(0.46, 0.32, 0.18)
	var brass := Color(0.80, 0.66, 0.32)
	# Shield-shaped plaque.
	ci.draw_colored_polygon(PackedVector2Array([
		pos + Vector2(-5.5, -5.5), pos + Vector2(5.5, -5.5),
		pos + Vector2(5.5, 3.0),   pos + Vector2(0.0, 6.5),
		pos + Vector2(-5.5, 3.0)]), board)
	ci.draw_line(pos + Vector2(-5.0, -5.0), pos + Vector2(5.0, -5.0),
		board.lightened(0.2), 1.0)
	# Fish body + tail, tinted to the species.
	ci.draw_colored_polygon(PackedVector2Array([
		pos + Vector2(-3.6, -1.0), pos + Vector2(1.8, -2.4),
		pos + Vector2(3.2, -1.0),  pos + Vector2(1.8, 0.4),
		pos + Vector2(-3.6, -0.4)]), item_color)
	ci.draw_colored_polygon(PackedVector2Array([
		pos + Vector2(-3.6, -1.0), pos + Vector2(-5.2, -2.2),
		pos + Vector2(-5.0, 0.4),  pos + Vector2(-3.6, -0.4)]), item_color.darkened(0.1))
	ci.draw_circle(pos + Vector2(2.2, -1.4), 0.5, Color(0.1, 0.1, 0.1))   # eye
	# Brass nameplate.
	ci.draw_rect(Rect2(pos.x - 3.0, pos.y + 2.4, 6.0, 1.8), brass)

# ── Jewelry / tools / food (v1.6.1) ──────────────────────────────────────────

## Gem tint for a ring/amulet id — gem prefixes get their stone colour; metal
## tiers fall back to the shared material tint.
static func _jewel_tint(id: String) -> Color:
	if id.begins_with("opal"):     return Color(0.85, 0.92, 0.97)
	if id.begins_with("amethyst"): return Color(0.70, 0.45, 0.90)
	if id.begins_with("diamond"):  return Color(0.86, 0.95, 1.00)
	if id.begins_with("sapphire"): return Color(0.30, 0.45, 0.90)
	if id.begins_with("emerald"):  return Color(0.25, 0.75, 0.45)
	if id.begins_with("ruby"):     return Color(0.85, 0.20, 0.28)
	return _mat_tint(id)

## Ring — a gold band with a set gemstone.
static func _draw_ring(ci: CanvasItem, bob_y: float, gem: Color) -> void:
	var p := Vector2(0.0, bob_y + 1.0)
	var gold := Color(0.90, 0.75, 0.25)
	ci.draw_arc(p, 4.0, 0.0, TAU, 18, gold, 2.2)                       # band
	ci.draw_arc(p, 4.0, 0.0, TAU, 18, gold.darkened(0.3), 0.7)        # rim shade
	ci.draw_circle(p + Vector2(0, -4.6), 2.5, gem)                     # gemstone
	ci.draw_circle(p + Vector2(-0.8, -5.3), 0.9, gem.lightened(0.45))  # glint

## Amulet — a fine chain with a faceted pendant gem.
static func _draw_amulet(ci: CanvasItem, bob_y: float, gem: Color) -> void:
	var p := Vector2(0.0, bob_y)
	var gold := Color(0.90, 0.75, 0.25)
	ci.draw_arc(p + Vector2(0, -2.5), 5.0, PI * 1.15, TAU * 0.925, 14, gold, 1.4)   # chain
	# Pendant — kite-cut gem.
	var g := p + Vector2(0, 3.5)
	ci.draw_colored_polygon(PackedVector2Array([
		g + Vector2(0, -3.5), g + Vector2(3.0, 0.0),
		g + Vector2(0, 4.0), g + Vector2(-3.0, 0.0)]), gem)
	ci.draw_line(g + Vector2(-3.0, 0.0), g + Vector2(3.0, 0.0), gem.darkened(0.25), 0.7)
	ci.draw_circle(g + Vector2(-1.0, -1.2), 0.8, gem.lightened(0.45))
	ci.draw_circle(p + Vector2(0, -1.2), 1.0, gold)                    # bail

## Pickaxe — wooden haft with a curved tier-tinted head.
static func _draw_pickaxe(ci: CanvasItem, bob_y: float, tint: Color) -> void:
	var p := Vector2(0.0, bob_y)
	ci.draw_line(p + Vector2(0, -5.0), p + Vector2(0, 7.0), Color(0.50, 0.35, 0.18), 2.2)  # haft
	# Curved head — an arc across the top with two pointed tips.
	ci.draw_arc(p + Vector2(0, -3.0), 6.5, PI * 1.1, TAU * 0.95, 10, tint, 2.4)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-7.5, -3.5), p + Vector2(-5.0, -5.5), p + Vector2(-5.0, -2.5)]), tint.darkened(0.1))
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(7.5, -3.5), p + Vector2(5.0, -5.5), p + Vector2(5.0, -2.5)]), tint.darkened(0.1))
	ci.draw_circle(p + Vector2(0, -3.0), 1.6, tint.lightened(0.15))    # collar

## Bread loaf — a rounded loaf with score marks. `moon` = pale-blue moonwheat.
static func _draw_bread(ci: CanvasItem, bob_y: float, moon: bool) -> void:
	var p := Vector2(0.0, bob_y)
	var crust := Color(0.72, 0.50, 0.24) if not moon else Color(0.62, 0.72, 0.90)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-6, 2), p + Vector2(-5, -3), p + Vector2(0, -5),
		p + Vector2(5, -3), p + Vector2(6, 2), p + Vector2(0, 4)]), crust)
	ci.draw_line(p + Vector2(-4, -2.5), p + Vector2(-2.5, 1.5), crust.darkened(0.25), 0.9)  # scores
	ci.draw_line(p + Vector2(-1, -4.0), p + Vector2(0.5, 1.5), crust.darkened(0.25), 0.9)
	ci.draw_line(p + Vector2(2.5, -3.5), p + Vector2(3.5, 1.0), crust.darkened(0.25), 0.9)
	ci.draw_line(p + Vector2(-5, -2), p + Vector2(0, -4), crust.lightened(0.2), 0.8)        # top sheen

## Stew — a wooden bowl of broth with steam.
static func _draw_stew(ci: CanvasItem, bob_y: float) -> void:
	var p := Vector2(0.0, bob_y + 1.0)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-6, 0), p + Vector2(6, 0), p + Vector2(4.5, 4.5), p + Vector2(-4.5, 4.5)]),
		Color(0.45, 0.30, 0.16))                                       # bowl
	ci.draw_rect(Rect2(p.x - 6.5, p.y - 1.0, 13.0, 1.8), Color(0.55, 0.38, 0.20))  # rim
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-5.5, 0.2), p + Vector2(5.5, 0.2), p + Vector2(4.2, 2.0), p + Vector2(-4.2, 2.0)]),
		Color(0.55, 0.32, 0.14))                                       # broth
	ci.draw_circle(p + Vector2(-1.5, 0.8), 0.9, Color(0.80, 0.55, 0.25))   # carrot chunk
	ci.draw_circle(p + Vector2(2.0, 1.0), 0.8, Color(0.70, 0.60, 0.40))    # potato chunk
	# Steam.
	for sx: float in [-2.0, 1.5]:
		ci.draw_line(p + Vector2(sx, -2.0), p + Vector2(sx + 1.0, -5.0), Color(0.9, 0.9, 0.9, 0.4), 1.0)

## Ale keg — a wooden barrel with iron hoops.
static func _draw_keg(ci: CanvasItem, bob_y: float) -> void:
	var p := Vector2(0.0, bob_y)
	var wood := Color(0.55, 0.38, 0.20)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-5, -5), p + Vector2(5, -5), p + Vector2(6, 0),
		p + Vector2(5, 5), p + Vector2(-5, 5), p + Vector2(-6, 0)]), wood)  # barrel body
	ci.draw_line(p + Vector2(-5.5, -2.5), p + Vector2(5.5, -2.5), Color(0.35, 0.35, 0.40), 1.2)  # hoops
	ci.draw_line(p + Vector2(-5.5, 2.5), p + Vector2(5.5, 2.5), Color(0.35, 0.35, 0.40), 1.2)
	ci.draw_line(p + Vector2(-6, 0), p + Vector2(6, 0), Color(0.30, 0.30, 0.35), 1.4)
	ci.draw_circle(p + Vector2(-2.0, -2.0), 1.2, wood.lightened(0.2))   # stave sheen

## Sack — a tied cloth sack (salt / grain). `col` tints the cloth.
static func _draw_sack(ci: CanvasItem, bob_y: float, col: Color) -> void:
	var p := Vector2(0.0, bob_y)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-5, 6), p + Vector2(-5.5, -1), p + Vector2(-3, -4),
		p + Vector2(3, -4), p + Vector2(5.5, -1), p + Vector2(5, 6)]), col)
	ci.draw_rect(Rect2(p.x - 3.0, p.y - 5.0, 6.0, 1.6), col.darkened(0.2))  # tied neck
	ci.draw_circle(p + Vector2(-1.5, -5.5), 1.0, col.darkened(0.2))
	ci.draw_circle(p + Vector2(1.5, -5.5), 1.0, col.darkened(0.2))
	ci.draw_line(p + Vector2(-2, 1), p + Vector2(-1, 5), col.darkened(0.15), 0.8)   # fold

## Fur bundle — a rolled hide tied with twine.
static func _draw_fur_bundle(ci: CanvasItem, bob_y: float) -> void:
	var p := Vector2(0.0, bob_y)
	var fur := Color(0.52, 0.38, 0.24)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-6, -3), p + Vector2(6, -3), p + Vector2(6, 3), p + Vector2(-6, 3)]), fur)  # roll
	ci.draw_circle(p + Vector2(-6, 0), 3.0, fur.lightened(0.12))       # rolled ends
	ci.draw_circle(p + Vector2(6, 0), 3.0, fur.lightened(0.12))
	ci.draw_arc(p + Vector2(-6, 0), 1.5, 0.0, TAU, 8, fur.darkened(0.25), 0.7)
	ci.draw_arc(p + Vector2(6, 0), 1.5, 0.0, TAU, 8, fur.darkened(0.25), 0.7)
	ci.draw_line(p + Vector2(-1, -3.5), p + Vector2(-1, 3.5), Color(0.75, 0.68, 0.50), 1.2)  # twine
	ci.draw_line(p + Vector2(2, -3.5), p + Vector2(2, 3.5), Color(0.75, 0.68, 0.50), 1.2)

## Folded cloth — a neat square of woven fabric. `col` tints the weave.
static func _draw_cloth(ci: CanvasItem, bob_y: float, col: Color) -> void:
	var p := Vector2(0.0, bob_y)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-5, -4), p + Vector2(5, -4), p + Vector2(5, 5), p + Vector2(-5, 5)]), col)
	ci.draw_line(p + Vector2(-5, -1), p + Vector2(5, -1), col.darkened(0.15), 0.9)   # folds
	ci.draw_line(p + Vector2(-5, 2), p + Vector2(5, 2), col.darkened(0.15), 0.9)
	ci.draw_line(p + Vector2(-2, -4), p + Vector2(-2, 5), col.darkened(0.10), 0.7)   # weave
	ci.draw_line(p + Vector2(2, -4), p + Vector2(2, 5), col.darkened(0.10), 0.7)
	ci.draw_polyline(PackedVector2Array([
		p + Vector2(-5, -4), p + Vector2(5, -4), p + Vector2(5, 5),
		p + Vector2(-5, 5), p + Vector2(-5, -4)]), col.darkened(0.3), 0.8)

## Organ (troll heart etc) — a glistening heart-shaped chunk.
static func _draw_organ(ci: CanvasItem, bob_y: float, col: Color) -> void:
	var p := Vector2(0.0, bob_y)
	ci.draw_circle(p + Vector2(-2.4, -1.5), 3.0, col)
	ci.draw_circle(p + Vector2(2.4, -1.5), 3.0, col)
	ci.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-5.2, -0.5), p + Vector2(5.2, -0.5), p + Vector2(0, 6.0)]), col)
	ci.draw_line(p + Vector2(-1.5, -3.0), p + Vector2(-3.0, -4.5), col.lightened(0.2), 1.2)  # vessel
	ci.draw_circle(p + Vector2(-2.0, -2.5), 1.3, col.lightened(0.30))   # sheen
