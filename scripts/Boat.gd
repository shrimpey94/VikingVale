extends RefCounted

## Boat definitions + programmatic boat sprite. Accessed via
## `const Boats = preload("res://scripts/Boat.gd")` (static methods) so it resolves
## at compile time by path — no autoload / class-name dependency.

# id → { name, tier, speed (move multiplier), fish_bonus (added success chance),
#        req (Construction level), wood (hull colour),
#        hp / armor / cannon_dmg / harpoon_range — boat-combat stats added in
#        Phase 1 of the fishing rework. cannon_dmg == 0 means no cannons (Phase
#        3 boat-combat panel falls back to harpoon-only). Top 3 tiers carry
#        cannons. Harpoon range scales with hull size. }
const BOATS: Dictionary = {
	"oak_rowboat":       {"name": "Oak Rowboat",        "tier": 0, "speed": 1.00, "fish_bonus": 0.00, "req": 1,  "wood": Color(0.55, 0.36, 0.18),
		"hp":  30, "armor": 0, "cannon_dmg":  0, "harpoon_range":  80},
	"pine_canoe":        {"name": "Pine Canoe",         "tier": 1, "speed": 1.15, "fish_bonus": 0.05, "req": 15, "wood": Color(0.42, 0.26, 0.10),
		"hp":  45, "armor": 1, "cannon_dmg":  0, "harpoon_range": 100},
	"cherry_sailboat":   {"name": "Cherry Sailboat",    "tier": 2, "speed": 1.30, "fish_bonus": 0.10, "req": 30, "wood": Color(0.62, 0.30, 0.22),
		"hp":  65, "armor": 2, "cannon_dmg":  0, "harpoon_range": 120},
	"ironwood_longship": {"name": "Ironwood Longship",  "tier": 3, "speed": 1.50, "fish_bonus": 0.15, "req": 50, "wood": Color(0.26, 0.15, 0.07),
		"hp":  90, "armor": 4, "cannon_dmg": 12, "harpoon_range": 150},
	"frost_warship":     {"name": "Frost Warship",      "tier": 4, "speed": 1.70, "fish_bonus": 0.20, "req": 70, "wood": Color(0.60, 0.78, 0.92),
		"hp": 130, "armor": 6, "cannon_dmg": 18, "harpoon_range": 180},
	"ancient_dragonship":{"name": "Ancient Dragonship", "tier": 5, "speed": 2.00, "fish_bonus": 0.30, "req": 85, "wood": Color(0.55, 0.40, 0.12),
		"hp": 200, "armor": 9, "cannon_dmg": 28, "harpoon_range": 220},
}

static func is_boat(item_id: String) -> bool:
	return BOATS.has(item_id)

static func data(item_id: String) -> Dictionary:
	return BOATS.get(item_id, {})

static func name_of(item_id: String) -> String:
	return str(BOATS.get(item_id, {}).get("name", item_id))

## Best (highest-tier) boat the player currently carries, or "" if none.
static func best_in_inventory(inventory: Array) -> String:
	var best := ""
	var best_tier := -1
	for item: Dictionary in inventory:
		var iid := str(item.get("id", ""))
		if BOATS.has(iid) and int(BOATS[iid]["tier"]) > best_tier:
			best_tier = int(BOATS[iid]["tier"])
			best = iid
	return best

# ══════════════════════════════════════════════════════════════════════════════
# DRAW — hull centred on the canvas origin; player is drawn sitting on top.
# `facing` is -1 (left) or 1 (right). Higher tiers are larger, with sail / prow.
# ══════════════════════════════════════════════════════════════════════════════
static func draw_boat(ci: CanvasItem, boat_id: String, facing: float) -> void:
	var d := data(boat_id)
	if d.is_empty():
		return
	var tier: int = int(d["tier"])
	var wood: Color = d["wood"]
	var dk := wood.darkened(0.3)
	var lt := wood.lightened(0.25)
	var fdir: float = 1.0 if facing >= 0.0 else -1.0

	# Hull half-length / depth grow with tier (sized for the world sprite)
	var hl := 24.0 + tier * 3.5     # half length
	var hd := 10.0 + tier * 1.2     # hull depth

	# Water shadow
	ci.draw_circle(Vector2(0, 16), hl * 0.9, Color(0.02, 0.06, 0.18, 0.30))

	# Hull: a boat-shaped polygon (pointed bow on the facing side)
	var bow := hl * fdir
	var stern := -hl * fdir
	var hull := PackedVector2Array([
		Vector2(stern, 4),
		Vector2(stern * 0.7, 4 + hd),
		Vector2(bow * 0.6, 4 + hd),
		Vector2(bow, 6),            # bow tip
		Vector2(bow * 0.6, 2),
		Vector2(stern * 0.8, 2),
	])
	ci.draw_colored_polygon(hull, wood)
	# Plank lines / rim
	ci.draw_line(Vector2(stern * 0.8, 3), Vector2(bow * 0.85, 4), lt, 1.5)
	ci.draw_line(Vector2(stern * 0.7, 4 + hd), Vector2(bow * 0.6, 4 + hd), dk, 1.5)
	# Interior
	ci.draw_rect(Rect2(-hl * 0.55, 0, hl * 1.1, 3), dk)

	# Tier-specific superstructure
	if tier >= 2:
		# Mast + sail (scaled with hull size)
		var mast_x := -2.0 * fdir
		var mast_top := -26.0 - tier * 1.5
		ci.draw_line(Vector2(mast_x, 2), Vector2(mast_x, mast_top), Color(0.30, 0.20, 0.10), 2.5)
		var sail_col := Color(0.92, 0.90, 0.82) if tier < 5 else Color(0.85, 0.20, 0.18)
		var sail := PackedVector2Array([
			Vector2(mast_x, mast_top + 2.0), Vector2(mast_x + (16.0 + tier) * fdir, mast_top * 0.5), Vector2(mast_x, -2),
		])
		ci.draw_colored_polygon(sail, sail_col)
		ci.draw_line(Vector2(mast_x, mast_top + 2.0), Vector2(mast_x, -2), sail_col.darkened(0.2), 1.0)
	if tier == 5:
		# Dragon prow
		var px := bow * 0.95
		ci.draw_circle(Vector2(px, -4), 4.0, Color(0.20, 0.55, 0.30))
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(px, -8), Vector2(px + 6 * fdir, -10), Vector2(px + 2 * fdir, -3),
		]), Color(0.18, 0.48, 0.26))
		ci.draw_circle(Vector2(px + 1 * fdir, -5), 1.0, Color(0.95, 0.85, 0.10))   # eye
	if tier == 4:
		# Frost shields along the rim
		for sx: int in [-8, 0, 8]:
			ci.draw_circle(Vector2(sx, 4), 2.5, lt)
