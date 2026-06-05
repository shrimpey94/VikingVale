extends RefCounted

## Phase 1 of the gold economy — base item prices, equipment-tier derivation,
## soulbound stub, and the player-progression-scaled sell-back multiplier.
## Accessed via `const ItemPrices = preload("res://scripts/ItemPrices.gd")`
## so it resolves at compile time by path (matches Boat / Fishing / SeaMonsters
## conventions — no autoload dependency).
##
## Resolution order in `price_for(id)`:
##   1. Explicit entry in PRICES
##   2. Equipment naming convention {tier}_{piece} — tier index via
##      Equipment.TIER_INDEX, base via WEAPON_BASE / ARMOR_BASE / TOOL_BASE,
##      final price = base · 2^tier_index
##   3. Falls through to 0 → item is non-tradeable
##
## Bartering math (buy_multiplier, junk_multiplier, etc.) lives in
## ShopCatalog.gd. This file owns base prices only.

const Equipment = preload("res://scripts/Equipment.gd")

# ── Soulbound stub ────────────────────────────────────────────────────────────
## Item ids that refuse to be sold via the shop "Sell" tab. Empty for v1 —
## reserved for future quest rewards, unique boss drops, and other items the
## player should not be able to liquidate to an NPC. ShopCatalog's sell handler
## checks via `is_soulbound(item_id)` before accepting the transaction.
const SOULBOUND: Dictionary = {}

# ── Equipment tier-derived bases ──────────────────────────────────────────────
# Pricing bases for items whose id follows the {tier}_{piece} convention. The
# tier prefix is looked up in Equipment.TIER_INDEX (leather=0, copper/bronze/
# gold=1, iron=2, mithril=4, adamant=5, runite=6, dragon=7) and the final price
# is `base · 2^tier_index`. Examples:
#   iron_sword     = 40 · 2^2 =   160
#   mithril_sword  = 40 · 2^4 =   640
#   dragon_boots   = 25 · 2^7 = 3,200
#   runite_pickaxe = 50 · 2^6 = 3,200

const WEAPON_BASE: Dictionary = {
	"sword":     40,
	"axe":       50,    # also a woodcutting tool, dual-use
	"battleaxe": 60,
	"mace":      35,
	"bow":       35,
	"staff":     30,
}

const ARMOR_BASE: Dictionary = {
	"helm":       30, "helmet":     30,
	"body":       80, "platebody":  80, "chestplate": 80,
	"legs":       60, "platelegs":  60, "leg":        60,
	"boots":      25, "boot":       25,
	"gloves":     20, "gauntlets":  20, "glove":      20,
	"bracers":    25, "vambraces":  25, "arms":       25,
	"shield":     40, "quiver":     40,
	"amulet":     80, "necklace":   80,
	"ring":       30,
}

const TOOL_BASE: Dictionary = {
	"pickaxe":      50,
	# "axe" overlaps with WEAPON_BASE and resolves there.
	# Wooden tools and "fishing_pole" (no tier prefix) live in PRICES below.
}

# ── Hardcoded base prices ─────────────────────────────────────────────────────
# Everything not coverable by the {tier}_{piece} formula. Grouped by source
# so balance passes can scan a section without scrolling the whole table.

const PRICES: Dictionary = {
	# ── Pickups + stackable consumables ───────────────────────────────────────
	"stick":         2,
	"stone":         3,
	"feather":       1,
	"arrows":        2,    # per unit; stackable
	"rune_essence": 80,    # per unit; stackable (mined from the world-only essence node)
	"magic_dust":   15,    # per unit; stackable
	"craft_kit":    10,    # crafting node drop
	"arrow_bundle":  8,    # archery range drop
	"timber":       12,    # construction-bench drop

	# ── Woodcutting logs ──────────────────────────────────────────────────────
	"oak_log":       10,
	"pine_log":      15,
	"cherry_log":    35,
	"ironwood_log":  80,
	"frost_log":    150,
	"ancient_log":  300,

	# ── Mining ores ───────────────────────────────────────────────────────────
	"copper_ore":   12,
	"iron_ore":     25,
	"gold_ore":     60,
	"mithril_ore": 140,
	"adamant_ore": 280,
	"runite_ore":  550,

	# ── Smithing bars (2 ore → 1 bar) ─────────────────────────────────────────
	"copper_bar":    35,
	"iron_bar":      75,
	"gold_bar":     180,
	"mithril_bar":  400,
	"adamant_bar":  800,
	"runite_bar": 1_600,

	# ── Foraging ──────────────────────────────────────────────────────────────
	"herbs":          5,
	"mushrooms":      8,
	"berries":       15,
	"moonbloom":     30,
	"ancient_root":  60,

	# ── Shoreline + boat fishing (raw) ────────────────────────────────────────
	"raw_fish":      8,
	"raw_salmon":   20,
	"lobster":      45,
	"raw_shark":   120,
	"abyssal_eel": 220,
	"raw_meat":      4,
	"raw_chicken":   5,

	# ── Deep-sea fish ladder (Fishing rework Phase 1) ─────────────────────────
	"silverfin":           60,
	"frost_cod":           90,
	"void_squid":         130,
	"anglerfish":         180,
	"deep_runefish":      240,
	"lava_eel":           310,
	"abyssal_pearl":      390,
	"leviathan_eel":      480,
	"sea_serpent_scale": 580,
	"kraken_meat":        700,
	"leviathan_eye":   1_000,

	# ── Standard monster drops ────────────────────────────────────────────────
	"rat_bone":          5,
	"bone":             15,
	"goblin_ear":       12,
	"wolf_pelt":        30,
	"bandit_hood":      40,
	"bear_claw":        60,
	"draugr_shard":     60,
	"spider_silk":      80,
	"troll_hide":      100,
	"spirit_essence": 120,
	"ice_fang":        180,
	"ice_shard":       200,
	"frost_crystal":   250,
	"imp_horn":        280,
	"lava_carapace":   380,
	"dragon_scale":    400,
	"giant_ember":     450,
	"shadow_essence": 520,
	"death_rune":      600,
	"spectral_essence":700,

	# ── Runes (Polish v3 — rune smithing at the runestone pillar) ─────────────
	"air_rune":      8,
	"mind_rune":    12,
	"water_rune":   18,
	"earth_rune":   22,
	"fire_rune":    28,
	"ice_rune":     32,
	"body_rune":    55,
	"cosmic_rune":  90,
	"chaos_rune":  140,
	"nature_rune": 220,
	"law_rune":    340,
	# death_rune already priced above at 600.
	"blood_rune":  900,

	# ── Sea-monster drops (Phase 3 fishing rework) ────────────────────────────
	"crab_claw":             10,
	"seagull_feather":        3,
	"eel_skin":              15,
	"serpent_scrap":         25,
	"razor_tooth":           60,
	"barnacle_shard":       100,
	"squid_ink":            140,
	"serpent_fang":         200,
	"siren_scale":          260,
	"witch_pearl":          340,
	"frost_heart":          450,
	"ember_lantern":        520,
	"void_tentacle":        650,
	"world_serpent_scale": 1_200,
	"drowned_crown":       3_000,

	# ── Cooked food (Cooking outputs; values ≈ raw + cooking labor) ───────────
	"cooked_fish":         12,
	"herb_tea":             8,
	"cooked_rat_meat":      8,
	"roasted_chicken":     10,
	"grilled_trout":       18,
	"baked_potato":        14,
	"cooked_salmon":       28,
	"vegetable_stew":      24,
	"meat_pie":            30,
	"fish_soup":           28,
	"cooked_lobster":      60,
	"hearty_stew":         40,
	"shark_steak":        180,
	"honey_glazed_ham":    60,
	"stuffed_boar":        80,
	"spiced_fish":         50,
	"dragon_fin_soup":    200,
	"mead_braised_ribs":   90,
	"frost_trout_fillet":150,
	"venison_roast":       95,
	"magma_prawn":        220,
	"smoked_bear":        180,
	"elder_fish_platter":350,
	"giants_feast":      320,
	"eel_stew":          260,
	"leviathan_stew":    550,
	"kraken_platter":    900,
	"feast_of_valhalla":2_000,

	# ── Bait / lures (Phase 5 fishing rework) ─────────────────────────────────
	"earthworm":      3,
	"fatty_lard":    50,
	"runic_lure": 2_500,
	"kraken_bait":5_000,

	# ── Farming (seeds + crops) ───────────────────────────────────────────────
	"barley_seed":   10,
	"cabbage_seed":  25,
	"onion_seed":    45,
	"wheat_seed":    80,
	"tomato_seed": 150,
	"barley":         5,
	"cabbage":       15,
	"onion":         30,
	"wheat":         50,
	"tomato":        90,

	# ── Tools that don't fit {tier}_{piece} ───────────────────────────────────
	"wooden_axe":          5,
	"wooden_pickaxe":      5,
	"wooden_fishing_pole": 5,
	"fishing_pole":       15,

	# ── Boats (Boat.BOATS tiers; construction outputs) ────────────────────────
	"oak_rowboat":         200,
	"pine_canoe":          500,
	"cherry_sailboat":   1_200,
	"ironwood_longship": 3_000,
	"frost_warship":     6_000,
	"ancient_dragonship":15_000,

	# ── Named Equipment.gd DEFS entries whose tier prefix isn't in TIER_INDEX
	# (everything else in DEFS derives through the formula correctly).
	"ironwood_bow": 600,
}

# ── Skill list (canonical) ────────────────────────────────────────────────────
# Same 15 skills GameManager.player_skill_xp tracks. Kept here so the
# sell-back multiplier never drifts if a skill is added or renamed — update
# this list alongside GameManager and the function picks up the change.
const _SKILLS: Array[String] = [
	"woodcutting", "mining", "fishing", "foraging",
	"smithing", "cooking", "crafting", "construction", "farming",
	"melee", "ranged", "magic", "defense", "vitality", "soul",
]

# ── Public API ────────────────────────────────────────────────────────────────

## Base gold value of an item. Returns 0 for non-tradeable / unknown ids.
## Shop UIs multiply this by their buy_multiplier (player buys) or by
## `sell_back_multiplier(player)` (player sells).
static func price_for(item_id: String) -> int:
	if PRICES.has(item_id):
		return int(PRICES[item_id])
	return _derive_from_naming(item_id)

## True if `price_for(item_id) > 0`. Convenience for the sell-tab filter to
## hide non-tradeable items rather than showing them at "Sell: 0g".
static func is_priced(item_id: String) -> bool:
	return price_for(item_id) > 0

## True if the item is in the soulbound set and cannot be sold to NPCs.
## Buying is unaffected — only sell-side refuses.
static func is_soulbound(item_id: String) -> bool:
	return SOULBOUND.has(item_id)

## Sell-back multiplier as a function of total player progression.
##
## Formula (per design doc):
##   floor(sum_of_all_15_skill_levels / 15 / 10) · 0.05 + 0.20
##
## Equivalently:  0.20 + floor(total_levels / 150) · 0.05, clamped [0.20, 0.50].
## Hits the 0.50 cap at sum_of_levels = 900 (every skill averaging 60).
##
## `player` is duck-typed — must expose `get_skill_level(skill: String) -> int`.
## GameManager satisfies this. Null returns the floor multiplier.
static func sell_back_multiplier(player) -> float:
	if player == null:
		return 0.20
	var total := 0
	for skill: String in _SKILLS:
		total += int(player.get_skill_level(skill))
	return clampf(0.20 + floor(float(total) / 150.0) * 0.05, 0.20, 0.50)

# ── Internals ─────────────────────────────────────────────────────────────────

## Tries to derive a price from the {tier}_{piece} naming convention. Returns
## 0 if the tier prefix isn't in Equipment.TIER_INDEX OR the piece keyword
## isn't in any of the base tables. Items that fail derivation should be
## listed explicitly in PRICES if they're meant to be tradeable.
static func _derive_from_naming(item_id: String) -> int:
	var parts := item_id.split("_", false)
	if parts.size() < 2:
		return 0
	var tier_key: String = parts[0]
	if not Equipment.TIER_INDEX.has(tier_key):
		return 0
	var tier_idx: int = int(Equipment.TIER_INDEX[tier_key])
	var piece: String = parts[parts.size() - 1]
	var base := 0
	if WEAPON_BASE.has(piece):
		base = int(WEAPON_BASE[piece])
	elif ARMOR_BASE.has(piece):
		base = int(ARMOR_BASE[piece])
	elif TOOL_BASE.has(piece):
		base = int(TOOL_BASE[piece])
	else:
		return 0
	return int(round(float(base) * pow(2.0, float(tier_idx))))
