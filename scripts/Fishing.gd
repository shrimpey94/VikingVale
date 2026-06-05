extends RefCounted

## Fishing data tables — bait, lures, and any shared catch metadata. Accessed
## via `const Fishing = preload("res://scripts/Fishing.gd")` so it resolves at
## compile time by path (matches Boat.gd's pattern — no autoload dependency).
##
## Phase 1 of the fishing rework: these tables are data only. Phase 2 wires the
## reel minigame to read them; Phase 5 (skill rework) adds the equip slot UI.

# Consumable bait. One unit is spent per cast (Phase 5 wires the consumption).
#   tier          — sort order in shop UIs (0 = lowest)
#   min_fishing   — required Fishing level to use this bait
#   catch_bonus   — added to base catch success (0..1)
#   rare_bonus    — added to the deep-sea rare-pick chance (0..1)
#   monster_bonus — added to the sea-monster encounter chance per cast (0..1)
const BAIT: Dictionary = {
	"earthworm": {
		"name": "Earthworm",   "tier": 0, "min_fishing": 1,
		"catch_bonus": 0.00,   "rare_bonus": 0.00,   "monster_bonus": 0.00,
		"color": Color(0.55, 0.30, 0.20),
	},
	"fatty_lard": {
		"name": "Fatty Lard",  "tier": 1, "min_fishing": 25,
		"catch_bonus": 0.03,   "rare_bonus": 0.05,   "monster_bonus": 0.00,
		"color": Color(0.92, 0.86, 0.62),
	},
	"kraken_bait": {
		"name": "Kraken Bait", "tier": 3, "min_fishing": 75,
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
