extends RefCounted

## Phase 2 of the gold economy — shop templates. Accessed via
## `const ShopCatalog = preload("res://scripts/ShopCatalog.gd")` (same pattern
## as AdminCatalog / Boat / Fishing / SeaMonsters).
##
## Sell-back is universal per design: every shop accepts every priced
## non-soulbound item at `ItemPrices.sell_back_multiplier(player)`. Shops
## therefore differ only in WHAT THEY SELL (the `stock_template` field)
## and their location (the `town` flavor field).
##
## Stock entries are seeded server-side on first `shop_open` per NPC, then
## persisted to `server/shop_stock.json` and restocked by a 60s loop. The
## server is authoritative — the client never decrements stock locally.

const SHOPS: Dictionary = {
	# ── General Store — Kjelvik (the hub) ─────────────────────────────────────
	# Carries basic tools and the cheapest supplies. Fishing pole sold here so
	# new players can buy one if they can't craft yet.
	"general_store": {
		"name":           "Kjelvik General Store",
		"town":           "Kjelvik",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "stick",                 "name": "Stick",                "color": [0.55, 0.36, 0.14, 1.0], "max": 100, "restock_per_tick": 10.0},
			{"id": "stone",                 "name": "Stone",                "color": [0.58, 0.56, 0.52, 1.0], "max": 100, "restock_per_tick": 10.0},
			{"id": "arrows",                "name": "Arrows",               "color": [0.72, 0.65, 0.50, 1.0], "max": 200, "restock_per_tick": 20.0},
			{"id": "oak_log",               "name": "Oak Log",              "color": [0.60, 0.40, 0.15, 1.0], "max":  30, "restock_per_tick":  3.0},
			{"id": "copper_ore",            "name": "Copper Ore",           "color": [0.75, 0.45, 0.20, 1.0], "max":  30, "restock_per_tick":  3.0},
			{"id": "wooden_axe",            "name": "Wooden Axe",           "color": [0.55, 0.38, 0.16, 1.0], "max":   5, "restock_per_tick":  0.5},
			{"id": "wooden_pickaxe",        "name": "Wooden Pickaxe",       "color": [0.50, 0.34, 0.14, 1.0], "max":   5, "restock_per_tick":  0.5},
			{"id": "wooden_fishing_pole",   "name": "Wooden Fishing Pole",  "color": [0.45, 0.28, 0.08, 1.0], "max":   5, "restock_per_tick":  0.5},
			{"id": "fishing_pole",          "name": "Fishing Pole",         "color": [0.48, 0.30, 0.08, 1.0], "max":   3, "restock_per_tick":  0.3},
		],
	},

	# ── Frostheim Smith — bars + iron-tier gear ───────────────────────────────
	"weapons_smith": {
		"name":           "Frostheim Smith",
		"town":           "Frostheim",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "copper_bar",     "name": "Copper Bar",     "color": [0.80, 0.50, 0.20, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "iron_bar",       "name": "Iron Bar",       "color": [0.60, 0.60, 0.65, 1.0], "max": 15, "restock_per_tick": 1.5},
			{"id": "copper_axe",     "name": "Copper Axe",     "color": [0.78, 0.48, 0.22, 1.0], "max":  5, "restock_per_tick": 0.5},
			{"id": "copper_pickaxe", "name": "Copper Pickaxe", "color": [0.72, 0.44, 0.18, 1.0], "max":  5, "restock_per_tick": 0.5},
			{"id": "iron_axe",       "name": "Iron Axe",       "color": [0.55, 0.55, 0.60, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "iron_pickaxe",   "name": "Iron Pickaxe",   "color": [0.50, 0.50, 0.55, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "iron_sword",     "name": "Iron Sword",     "color": [0.55, 0.55, 0.60, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "iron_helm",      "name": "Iron Helm",      "color": [0.55, 0.55, 0.60, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "iron_body",      "name": "Iron Body",      "color": [0.55, 0.55, 0.60, 1.0], "max":  2, "restock_per_tick": 0.2},
			{"id": "iron_legs",      "name": "Iron Legs",      "color": [0.55, 0.55, 0.60, 1.0], "max":  2, "restock_per_tick": 0.2},
			{"id": "iron_boots",     "name": "Iron Boots",     "color": [0.60, 0.62, 0.65, 1.0], "max":  3, "restock_per_tick": 0.3},
		],
	},

	# ── Bjorn's Fishmonger — bait, raw + cooked fish ──────────────────────────
	"fishmonger": {
		"name":           "Bjorn's Fishmonger",
		"town":           "Bjorn's Landing",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "earthworm",     "name": "Earthworm",     "color": [0.55, 0.30, 0.20, 1.0], "max": 50, "restock_per_tick": 10.0},
			{"id": "fatty_lard",    "name": "Fatty Lard",    "color": [0.92, 0.86, 0.62, 1.0], "max": 20, "restock_per_tick":  2.0},
			{"id": "raw_fish",      "name": "Raw Fish",      "color": [0.70, 0.90, 0.95, 1.0], "max": 30, "restock_per_tick":  3.0},
			{"id": "raw_salmon",    "name": "Raw Salmon",    "color": [0.95, 0.55, 0.30, 1.0], "max": 15, "restock_per_tick":  1.0},
			{"id": "cooked_fish",   "name": "Cooked Fish",   "color": [0.85, 0.65, 0.35, 1.0], "max": 12, "restock_per_tick":  1.0},
			{"id": "cooked_salmon", "name": "Cooked Salmon", "color": [0.95, 0.52, 0.28, 1.0], "max":  8, "restock_per_tick":  0.5},
		],
	},

	# ── Eastmark Apothecary — herbs, cooked food, healing ─────────────────────
	"apothecary": {
		"name":           "Eastmark Apothecary",
		"town":           "Eastmark Post",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "herbs",            "name": "Herbs",            "color": [0.45, 0.80, 0.20, 1.0], "max": 50, "restock_per_tick": 5.0},
			{"id": "mushrooms",        "name": "Mushrooms",        "color": [0.72, 0.55, 0.38, 1.0], "max": 30, "restock_per_tick": 3.0},
			{"id": "berries",          "name": "Berries",          "color": [0.72, 0.18, 0.50, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "moonbloom",        "name": "Moonbloom",        "color": [0.78, 0.62, 0.95, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "herb_tea",         "name": "Herb Tea",         "color": [0.55, 0.85, 0.45, 1.0], "max": 15, "restock_per_tick": 1.5},
			{"id": "baked_potato",     "name": "Baked Potato",     "color": [0.74, 0.58, 0.34, 1.0], "max":  8, "restock_per_tick": 0.5},
			{"id": "cooked_rat_meat",  "name": "Cooked Rat Meat",  "color": [0.62, 0.40, 0.28, 1.0], "max": 10, "restock_per_tick": 1.0},
		],
	},

	# ── Ironwood Magic Vendor — runes, magic materials, jewellery ─────────────
	"magic_vendor": {
		"name":           "Ironwood Magic Vendor",
		"town":           "Ironwood Keep",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "rune_essence", "name": "Rune Essence", "color": [0.65, 0.35, 0.80, 1.0], "max": 50, "restock_per_tick": 5.0},
			{"id": "magic_dust",   "name": "Magic Dust",   "color": [0.65, 0.35, 0.80, 1.0], "max": 30, "restock_per_tick": 3.0},
			{"id": "feather",      "name": "Feather",      "color": [0.95, 0.94, 0.88, 1.0], "max": 50, "restock_per_tick": 5.0},
			{"id": "copper_bar",   "name": "Copper Bar",   "color": [0.80, 0.50, 0.20, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "gold_amulet",  "name": "Gold Amulet",  "color": [0.95, 0.80, 0.15, 1.0], "max":  2, "restock_per_tick": 0.1},
			{"id": "ironwood_bow", "name": "Ironwood Bow", "color": [0.28, 0.14, 0.06, 1.0], "max":  2, "restock_per_tick": 0.1},
		],
	},
}

# ── Public API ────────────────────────────────────────────────────────────────

static func is_shop(shop_id: String) -> bool:
	return SHOPS.has(shop_id)

static func data(shop_id: String) -> Dictionary:
	return SHOPS.get(shop_id, {})

static func shop_ids() -> Array:
	return SHOPS.keys()

## Item entry from a shop's stock template (the static catalog row, not the
## per-NPC runtime stock count). Returns {} if the item isn't sold here.
static func stock_entry(shop_id: String, item_id: String) -> Dictionary:
	var sd: Dictionary = SHOPS.get(shop_id, {})
	if sd.is_empty():
		return {}
	for entry: Variant in sd.get("stock_template", []):
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == item_id:
			return entry as Dictionary
	return {}

## True if `shop_id` lists `item_id` in its stock template. (Used by the
## client to label "in stock here" vs "general sell" in the future UI.)
static func sells(shop_id: String, item_id: String) -> bool:
	return not stock_entry(shop_id, item_id).is_empty()
