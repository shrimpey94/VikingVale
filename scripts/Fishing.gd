extends RefCounted

## Fishing data tables — bait, lures, and any shared catch metadata. Accessed
## via `const Fishing = preload("res://scripts/Fishing.gd")` so it resolves at
## compile time by path (matches Boat.gd's pattern — no autoload dependency).
##
## Phase 1 of the fishing rework: these tables are data only. Phase 2 wires the
## reel minigame to read them; Phase 5 (skill rework) adds the equip slot UI.

# Consumable bait. One unit is spent per cast (Phase 5 wires the consumption).
#   tier           — sort order in shop UIs (0 = lowest)
#   min_fishing    — required Fishing level to use this bait
#   catch_bonus    — added to base catch success (0..1)
#   rare_bonus     — added to the deep-sea rare-pick chance (0..1)
#   monster_bonus  — added to the sea-monster encounter chance per cast; may be
#                    NEGATIVE to CALM the water (fewer encounters) for safe farming
#   weight_skew    — 0..1, fattens the catch-weight roll → better TROPHY odds (1.6.3)
#   monster_weaken — 0..1, if this tackle is equipped when a sea encounter starts,
#                    the monster's attack is reduced by this fraction (1.6.3)
const BAIT: Dictionary = {
	"earthworm": {
		"name": "Earthworm",   "tier": 0, "min_fishing": 1,
		"catch_bonus": 0.00,   "rare_bonus": 0.00,   "monster_bonus": 0.00,
		"color": Color(0.55, 0.30, 0.20),
	},
	"shrimp_bait": {
		"name": "Shrimp Bait", "tier": 1, "min_fishing": 10,
		"catch_bonus": 0.02,   "rare_bonus": 0.02,   "monster_bonus": 0.00,
		"color": Color(0.95, 0.62, 0.55),
	},
	"fatty_lard": {
		"name": "Fatty Lard",  "tier": 2, "min_fishing": 25,
		"catch_bonus": 0.03,   "rare_bonus": 0.05,   "monster_bonus": 0.00,
		"color": Color(0.92, 0.86, 0.62),
	},
	"calming_chum": {
		"name": "Calming Chum", "tier": 2, "min_fishing": 20,
		"catch_bonus": 0.02,    "rare_bonus": 0.00,   "monster_bonus": -0.06,
		"color": Color(0.55, 0.72, 0.66),
	},
	"glimmer_roe": {
		"name": "Glimmer Roe", "tier": 3, "min_fishing": 45,
		"catch_bonus": 0.04,   "rare_bonus": 0.06,   "monster_bonus": 0.00,
		"weight_skew": 0.35,
		"color": Color(0.95, 0.85, 0.45),
	},
	"kraken_bait": {
		"name": "Kraken Bait", "tier": 4, "min_fishing": 75,
		"catch_bonus": 0.00,   "rare_bonus": 0.20,   "monster_bonus": 0.30,
		"color": Color(0.35, 0.10, 0.45),
	},
}

# Persistent lures. Equipped (not consumed) — boosts every cast while attached
# to the pole. Phase 5 adds an equip slot in the equipment UI; for now these
# are inventory items that exist so loot tables / shop wires can reference them.
#   tier        — sort order
#   min_fishing — required level to equip
#   catch_bonus / rare_bonus / monster_bonus — same semantics as BAIT
const LURES: Dictionary = {
	"runic_lure": {
		"name": "Runic Lure",  "tier": 2, "min_fishing": 50,
		"catch_bonus": 0.05,   "rare_bonus": 0.10,   "monster_bonus": 0.10,
		"color": Color(0.40, 0.60, 0.85),
	},
	"trophy_spoon": {
		"name": "Trophy Spoon", "tier": 3, "min_fishing": 65,
		"catch_bonus": 0.06,    "rare_bonus": 0.15,   "monster_bonus": 0.00,
		"weight_skew": 0.55,
		"color": Color(0.85, 0.85, 0.90),
	},
	"serpent_lure": {
		"name": "Serpent Lure", "tier": 3, "min_fishing": 70,
		"catch_bonus": 0.03,    "rare_bonus": 0.10,   "monster_bonus": 0.20,
		"monster_weaken": 0.25,
		"color": Color(0.30, 0.65, 0.45),
	},
}

static func is_bait(item_id: String) -> bool:
	return BAIT.has(item_id)

static func is_lure(item_id: String) -> bool:
	return LURES.has(item_id)

static func bait_data(item_id: String) -> Dictionary:
	return BAIT.get(item_id, {})

static func lure_data(item_id: String) -> Dictionary:
	return LURES.get(item_id, {})

## Combined accessor — checks bait first, then lures. Returns {} if unknown.
static func tackle_data(item_id: String) -> Dictionary:
	if BAIT.has(item_id):  return BAIT[item_id]
	if LURES.has(item_id): return LURES[item_id]
	return {}

## Human-readable summary of what a bait/lure does, for the equip/shop tooltip.
## Returns "" for a non-tackle id. Only lists the effects that actually apply.
static func tackle_desc(item_id: String) -> String:
	var td: Dictionary = tackle_data(item_id)
	if td.is_empty():
		return ""
	var kind := "Lure (equipped)" if is_lure(item_id) else "Bait (equipped)"
	var parts: Array[String] = []
	var cb := float(td.get("catch_bonus", 0.0))
	if cb != 0.0:   parts.append("+%d%% catch XP" % int(round(cb * 100.0)))
	var rb := float(td.get("rare_bonus", 0.0))
	if rb != 0.0:   parts.append("+%d%% rare/deep fish" % int(round(rb * 100.0)))
	var ws := float(td.get("weight_skew", 0.0))
	if ws != 0.0:   parts.append("+%d%% trophy odds" % int(round(ws * 100.0)))
	var mb := float(td.get("monster_bonus", 0.0))
	if mb > 0.0:    parts.append("+%d%% sea monsters" % int(round(mb * 100.0)))
	elif mb < 0.0:  parts.append("calms the water (fewer monsters)")
	var mw := float(td.get("monster_weaken", 0.0))
	if mw != 0.0:   parts.append("sea monsters -%d%% attack" % int(round(mw * 100.0)))
	var lv := int(td.get("min_fishing", 1))
	var head := "%s  ·  Lv %d Fishing" % [kind, lv]
	if parts.is_empty():
		return head
	return "%s\n%s" % [head, "  ·  ".join(parts)]

# ── Catch weight (1.6.3) ──────────────────────────────────────────────────────
# Every catch rolls a weight in its species' range, auto-derived from the fish's
# tier (min_lv). Bigger = rarer (skewed roll), more XP, a heavier cooked meal,
# and TROPHY status past a threshold.
const TROPHY_NORM := 0.85   # top 15% of a species' range = a trophy

static func weight_range(catch: Dictionary) -> Vector2:
	# Median grows with tier; a shoreline fish (no min_lv) is tiny, a leviathan
	# is enormous. A catch lands in [0.4x, 1.8x] of the median.
	var lv := int(catch.get("min_lv", 1))
	var median := 0.5 + float(lv * lv) * 0.04
	return Vector2(median * 0.4, median * 1.8)

## `skew` (0..1, from equipped tackle's `weight_skew`) FATTENS the roll toward
## the big end — a trophy-hunter's lure lowers the exponent so heavy catches
## (and trophies) come up more often. 0 = the default rare-big curve.
static func roll_weight(catch: Dictionary, skew: float = 0.0) -> float:
	var r := weight_range(catch)
	var expo := lerpf(2.2, 0.8, clampf(skew, 0.0, 1.0))
	var f := pow(randf(), expo)   # lower expo → weighted toward big catches
	return snappedf(lerpf(r.x, r.y, f), 0.1)

## 0 (smallest) .. 1 (record-size) for this species — drives XP / heal scaling.
static func weight_norm(catch: Dictionary, weight: float) -> float:
	var r := weight_range(catch)
	return clampf((weight - r.x) / maxf(0.001, r.y - r.x), 0.0, 1.0)

## XP / cooked-heal multiplier from a catch weight (1.0 small .. 2.0 record).
static func weight_mult(catch: Dictionary, weight: float) -> float:
	return 1.0 + weight_norm(catch, weight)

static func is_trophy(catch: Dictionary, weight: float) -> bool:
	return weight_norm(catch, weight) >= TROPHY_NORM
