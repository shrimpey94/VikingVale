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
## persisted to the shop_stock table and restocked by a 60s loop. The server
## is authoritative — the client never decrements stock locally.
##
## ONE source of truth: server/server.py parses the block between the two
## marker lines as JSON (it used to keep a hand-synced copy, which drifted).
## Keep it strict JSON — double quotes, no trailing commas, no comments inside.
## Prices are NOT here; they come from ItemPrices / the server price table.
##
## Shop notes (moved out of the JSON block):
##   general_store      — Kjelvik hub: basic tools, cheapest supplies, low-tier
##                        farming seeds (an on-ramp; higher tiers forage-only).
##   weapons_smith      — Frostheim: bars + iron-tier gear.
##   fishmonger         — Bjorn's: bait, raw + cooked fish, premium deep-water tackle
##                        (low stock, slow restock).
##   apothecary         — Brynhildr in Frostheim: herbs, cooked food, healing.
##   magic_vendor       — Ironwood: runes, magic materials, jewellery; rare gems are
##                        very low stock + slow restock (a luxury buy, not a supply).
##   kjelvik_garrison   — Quartermaster Ase: copper fighting gear for new fighters.
##   kjelvik_provisions — Trader Hroar: raw materials a step above the General Store.
##   kjelvik_curios     — Merchant Dalla: healing food, copper tools, one curiosity.
##   frostheim_furs     — Merchant Bera: leather "cold-weather" set, pelts, brews.
##   ironwood_outfitter — Trader Thorvald: dark-forest kit (no ironwood logs — those
##                        stay a woodcutting job for Ulfr's quests).
##   eastmark_wagon     — Wandering Merchant Freyja: high-heal food + rare metal for
##                        the Ashlands, all low stock.
##   bjorn_catch        — Fish Trader Knud: deep-sea fish and cooked seafood.

# BEGIN_SHOP_CATALOG_JSON
const SHOPS: Dictionary = {
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
			{"id": "wheat_seed",            "name": "Wheat Seed",           "color": [0.90, 0.80, 0.30, 1.0], "max":  40, "restock_per_tick":  4.0},
			{"id": "carrot_seed",           "name": "Carrot Seed",          "color": [0.90, 0.55, 0.20, 1.0], "max":  40, "restock_per_tick":  4.0},
			{"id": "barley_seed",           "name": "Barley Seed",          "color": [0.82, 0.72, 0.40, 1.0], "max":  30, "restock_per_tick":  3.0},
			{"id": "cabbage_seed",          "name": "Cabbage Seed",         "color": [0.45, 0.72, 0.36, 1.0], "max":  30, "restock_per_tick":  3.0},
			{"id": "rye_seed",              "name": "Rye Seed",             "color": [0.72, 0.62, 0.32, 1.0], "max":  25, "restock_per_tick":  2.5},
			{"id": "corn_seed",             "name": "Corn Seed",            "color": [0.92, 0.80, 0.25, 1.0], "max":  20, "restock_per_tick":  2.0},
			{"id": "potato_seed",           "name": "Potato Seed",          "color": [0.72, 0.56, 0.36, 1.0], "max":  20, "restock_per_tick":  2.0}
		]
	},
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
			{"id": "iron_boots",     "name": "Iron Boots",     "color": [0.60, 0.62, 0.65, 1.0], "max":  3, "restock_per_tick": 0.3}
		]
	},
	"fishmonger": {
		"name":           "Bjorn's Fishmonger",
		"town":           "Bjorn's Landing",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "earthworm",     "name": "Earthworm",     "color": [0.55, 0.30, 0.20, 1.0], "max": 50, "restock_per_tick": 10.0},
			{"id": "shrimp_bait",   "name": "Shrimp Bait",   "color": [0.95, 0.62, 0.55, 1.0], "max": 40, "restock_per_tick":  5.0},
			{"id": "fatty_lard",    "name": "Fatty Lard",    "color": [0.92, 0.86, 0.62, 1.0], "max": 20, "restock_per_tick":  2.0},
			{"id": "calming_chum",  "name": "Calming Chum",  "color": [0.55, 0.72, 0.66, 1.0], "max": 15, "restock_per_tick":  1.5},
			{"id": "glimmer_roe",   "name": "Glimmer Roe",   "color": [0.95, 0.85, 0.45, 1.0], "max":  8, "restock_per_tick":  0.5},
			{"id": "raw_fish",      "name": "Raw Fish",      "color": [0.70, 0.90, 0.95, 1.0], "max": 30, "restock_per_tick":  3.0},
			{"id": "raw_salmon",    "name": "Raw Salmon",    "color": [0.95, 0.55, 0.30, 1.0], "max": 15, "restock_per_tick":  1.0},
			{"id": "cooked_fish",   "name": "Cooked Fish",   "color": [0.85, 0.65, 0.35, 1.0], "max": 12, "restock_per_tick":  1.0},
			{"id": "cooked_salmon", "name": "Cooked Salmon", "color": [0.95, 0.52, 0.28, 1.0], "max":  8, "restock_per_tick":  0.5},
			{"id": "runic_lure",    "name": "Runic Lure",    "color": [0.40, 0.60, 0.85, 1.0], "max":  3, "restock_per_tick":  0.15},
			{"id": "trophy_spoon",  "name": "Trophy Spoon",  "color": [0.85, 0.85, 0.90, 1.0], "max":  2, "restock_per_tick":  0.10},
			{"id": "serpent_lure",  "name": "Serpent Lure",  "color": [0.30, 0.65, 0.45, 1.0], "max":  2, "restock_per_tick":  0.10},
			{"id": "kraken_bait",   "name": "Kraken Bait",   "color": [0.35, 0.10, 0.45, 1.0], "max":  3, "restock_per_tick":  0.15}
		]
	},
	"apothecary": {
		"name":           "Frostheim Apothecary",
		"town":           "Frostheim",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "herbs",            "name": "Herbs",            "color": [0.45, 0.80, 0.20, 1.0], "max": 50, "restock_per_tick": 5.0},
			{"id": "mushrooms",        "name": "Mushrooms",        "color": [0.72, 0.55, 0.38, 1.0], "max": 30, "restock_per_tick": 3.0},
			{"id": "berries",          "name": "Berries",          "color": [0.72, 0.18, 0.50, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "moonbloom",        "name": "Moonbloom",        "color": [0.78, 0.62, 0.95, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "herb_tea",         "name": "Herb Tea",         "color": [0.55, 0.85, 0.45, 1.0], "max": 15, "restock_per_tick": 1.5},
			{"id": "baked_potato",     "name": "Baked Potato",     "color": [0.74, 0.58, 0.34, 1.0], "max":  8, "restock_per_tick": 0.5},
			{"id": "cooked_rat_meat",  "name": "Cooked Rat Meat",  "color": [0.62, 0.40, 0.28, 1.0], "max": 10, "restock_per_tick": 1.0}
		]
	},
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
			{"id": "opal",         "name": "Opal",         "color": [0.82, 0.90, 0.95, 1.0], "max":  3, "restock_per_tick": 0.10},
			{"id": "amethyst",     "name": "Amethyst",     "color": [0.62, 0.38, 0.85, 1.0], "max":  2, "restock_per_tick": 0.05},
			{"id": "diamond",      "name": "Diamond",      "color": [0.85, 0.95, 1.00, 1.0], "max":  1, "restock_per_tick": 0.02}
		]
	},
	"kjelvik_garrison": {
		"name":           "Garrison Armoury",
		"town":           "Kjelvik",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "copper_sword",  "name": "Copper Sword",  "color": [0.82, 0.52, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "copper_mace",   "name": "Copper Mace",   "color": [0.82, 0.52, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "copper_bow",    "name": "Copper Bow",    "color": [0.82, 0.52, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "copper_shield", "name": "Copper Shield", "color": [0.82, 0.52, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "copper_helm",   "name": "Copper Helm",   "color": [0.82, 0.52, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "copper_body",   "name": "Copper Body",   "color": [0.82, 0.52, 0.22, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "copper_legs",   "name": "Copper Legs",   "color": [0.82, 0.52, 0.22, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "copper_boots",  "name": "Copper Boots",  "color": [0.82, 0.52, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "arrows",        "name": "Arrows",        "color": [0.72, 0.65, 0.50, 1.0], "max": 200, "restock_per_tick": 20.0},
			{"id": "wheat_bread",   "name": "Wheat Bread",   "color": [0.88, 0.72, 0.35, 1.0], "max": 20, "restock_per_tick": 2.0}
		]
	},
	"kjelvik_provisions": {
		"name":           "Hroar's Provisions",
		"town":           "Kjelvik",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "pine_log",        "name": "Pine Log",        "color": [0.42, 0.30, 0.14, 1.0], "max": 30, "restock_per_tick": 3.0},
			{"id": "iron_ore",        "name": "Iron Ore",        "color": [0.55, 0.55, 0.60, 1.0], "max": 30, "restock_per_tick": 3.0},
			{"id": "feather",         "name": "Feather",         "color": [0.95, 0.94, 0.88, 1.0], "max": 50, "restock_per_tick": 5.0},
			{"id": "wheat_bread",     "name": "Wheat Bread",     "color": [0.88, 0.72, 0.35, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "barley_porridge", "name": "Barley Porridge", "color": [0.82, 0.74, 0.52, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "dark_bread",      "name": "Dark Bread",      "color": [0.45, 0.30, 0.16, 1.0], "max": 15, "restock_per_tick": 1.5},
			{"id": "ale",             "name": "Frontier Ale",    "color": [0.80, 0.55, 0.20, 1.0], "max": 10, "restock_per_tick": 1.0}
		]
	},
	"kjelvik_curios": {
		"name":           "Dalla's Curiosities",
		"town":           "Kjelvik",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "herb_tea",       "name": "Herb Tea",       "color": [0.55, 0.85, 0.45, 1.0], "max": 15, "restock_per_tick": 1.5},
			{"id": "vegetable_stew", "name": "Vegetable Stew", "color": [0.40, 0.62, 0.30, 1.0], "max": 12, "restock_per_tick": 1.0},
			{"id": "meat_pie",       "name": "Meat Pie",       "color": [0.72, 0.50, 0.26, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "copper_axe",     "name": "Copper Axe",     "color": [0.78, 0.48, 0.22, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "copper_pickaxe", "name": "Copper Pickaxe", "color": [0.72, 0.44, 0.18, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "shrimp_bait",    "name": "Shrimp Bait",    "color": [0.95, 0.62, 0.55, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "opal",           "name": "Opal",           "color": [0.82, 0.90, 0.95, 1.0], "max":  1, "restock_per_tick": 0.05}
		]
	},
	"frostheim_furs": {
		"name":           "Bera's Furs & Brews",
		"town":           "Frostheim",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "leather_helm",      "name": "Leather Helm",      "color": [0.45, 0.30, 0.14, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "leather_body",      "name": "Leather Body",      "color": [0.45, 0.30, 0.14, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "leather_legs",      "name": "Leather Legs",      "color": [0.45, 0.30, 0.14, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "leather_gloves",    "name": "Leather Gloves",    "color": [0.45, 0.30, 0.14, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "leather_boots",     "name": "Leather Boots",     "color": [0.45, 0.30, 0.14, 1.0], "max":  4, "restock_per_tick": 0.4},
			{"id": "leather_shield",    "name": "Leather Shield",    "color": [0.45, 0.30, 0.14, 1.0], "max":  3, "restock_per_tick": 0.3},
			{"id": "wolf_pelt",         "name": "Wolf Pelt",         "color": [0.55, 0.52, 0.48, 1.0], "max": 20, "restock_per_tick": 2.0},
			{"id": "ale",               "name": "Frontier Ale",      "color": [0.80, 0.55, 0.20, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "mead_braised_ribs", "name": "Mead-Braised Ribs", "color": [0.66, 0.34, 0.18, 1.0], "max":  8, "restock_per_tick": 0.5},
			{"id": "fine_wine",         "name": "Fine Wine",         "color": [0.55, 0.15, 0.35, 1.0], "max":  2, "restock_per_tick": 0.1}
		]
	},
	"ironwood_outfitter": {
		"name":           "Thorvald's Forest Supplies",
		"town":           "Ironwood Keep",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "iron_axe",      "name": "Iron Axe",      "color": [0.55, 0.55, 0.60, 1.0], "max":   3, "restock_per_tick": 0.3},
			{"id": "arrows",        "name": "Arrows",        "color": [0.72, 0.65, 0.50, 1.0], "max": 200, "restock_per_tick": 20.0},
			{"id": "hearty_stew",   "name": "Hearty Stew",   "color": [0.60, 0.42, 0.24, 1.0], "max":  10, "restock_per_tick": 1.0},
			{"id": "fish_soup",     "name": "Fish Soup",     "color": [0.55, 0.70, 0.78, 1.0], "max":  12, "restock_per_tick": 1.0},
			{"id": "cooked_salmon", "name": "Cooked Salmon", "color": [0.95, 0.52, 0.28, 1.0], "max":  12, "restock_per_tick": 1.0},
			{"id": "herb_tea",      "name": "Herb Tea",      "color": [0.55, 0.85, 0.45, 1.0], "max":  15, "restock_per_tick": 1.5},
			{"id": "berries",       "name": "Berries",       "color": [0.72, 0.18, 0.50, 1.0], "max":  20, "restock_per_tick": 2.0}
		]
	},
	"eastmark_wagon": {
		"name":           "Freyja's Wagon",
		"town":           "Eastmark Post",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "shark_steak", "name": "Shark Steak", "color": [0.55, 0.58, 0.62, 1.0], "max": 5, "restock_per_tick": 0.3},
			{"id": "smoked_bear", "name": "Smoked Bear", "color": [0.48, 0.32, 0.20, 1.0], "max": 5, "restock_per_tick": 0.3},
			{"id": "magma_prawn", "name": "Magma Prawn", "color": [0.95, 0.42, 0.18, 1.0], "max": 4, "restock_per_tick": 0.2},
			{"id": "eel_stew",    "name": "Eel Stew",    "color": [0.28, 0.45, 0.35, 1.0], "max": 4, "restock_per_tick": 0.2},
			{"id": "gold_bar",    "name": "Gold Bar",    "color": [0.95, 0.80, 0.15, 1.0], "max": 5, "restock_per_tick": 0.3},
			{"id": "mithril_bar", "name": "Mithril Bar", "color": [0.40, 0.65, 0.90, 1.0], "max": 3, "restock_per_tick": 0.15},
			{"id": "adamant_ore", "name": "Adamant Ore", "color": [0.20, 0.65, 0.30, 1.0], "max": 3, "restock_per_tick": 0.15}
		]
	},
	"bjorn_catch": {
		"name":           "Knud's Catch",
		"town":           "Bjorn's Landing",
		"buy_multiplier": 1.0,
		"stock_template": [
			{"id": "silverfin",      "name": "Silverfin",      "color": [0.62, 0.70, 0.82, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "frost_cod",      "name": "Frost Cod",      "color": [0.72, 0.84, 0.92, 1.0], "max":  8, "restock_per_tick": 0.6},
			{"id": "grilled_trout",  "name": "Grilled Trout",  "color": [0.80, 0.58, 0.40, 1.0], "max": 15, "restock_per_tick": 1.5},
			{"id": "spiced_fish",    "name": "Spiced Fish",    "color": [0.92, 0.58, 0.34, 1.0], "max": 10, "restock_per_tick": 1.0},
			{"id": "fish_soup",      "name": "Fish Soup",      "color": [0.55, 0.70, 0.78, 1.0], "max": 12, "restock_per_tick": 1.0},
			{"id": "cooked_lobster", "name": "Cooked Lobster", "color": [0.90, 0.30, 0.20, 1.0], "max":  6, "restock_per_tick": 0.5}
		]
	}
}
# END_SHOP_CATALOG_JSON

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
