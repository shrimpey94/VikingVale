extends RefCounted

## Farming definitions — the CLIENT mirror of the server's FARM_* tables
## (server/server.py: FARM_GROWTH_SEC / FARM_CROP_OF / _FARM_REQ_LV). Used by the
## plant popup, the grow/water bars, and foraging seed drops. Keep in sync with
## the server — the server is authoritative on plant/water/harvest.
##
## Per seed:
##   lv      = Farming level required to PLANT it (also the server gate).
##   grow    = seconds to mature (watering boosts effective speed ~2×; see FarmPlot bars).
##   xp      = Farming XP granted on a successful harvest.
##   yield   = crops harvested.  crop/crop_name = the harvested item.
##   fw      = LEGACY (unused). Forage drop rarity is now derived from `lv` in
##             roll_forage_seed() — mid tiers ~1/20, scaling rarer with level.
##   shop    = true if the seed is also sold cheap in town general stores (low tiers).
##   color   = crop colour [r,g,b,a] for the plot render + item icon fallback.

const SEEDS: Array = [
	{"seed": "wheat_seed",       "seed_name": "Wheat Seed",       "crop": "wheat",       "crop_name": "Wheat",       "lv": 1,  "grow": 50.0,  "xp": 20,  "yield": 3, "fw": 100.0, "shop": true,  "color": [0.90, 0.80, 0.30, 1.0]},
	{"seed": "carrot_seed",      "seed_name": "Carrot Seed",      "crop": "carrot",      "crop_name": "Carrot",      "lv": 1,  "grow": 52.0,  "xp": 22,  "yield": 3, "fw": 100.0, "shop": true,  "color": [0.90, 0.55, 0.20, 1.0]},
	{"seed": "barley_seed",      "seed_name": "Barley Seed",      "crop": "barley",      "crop_name": "Barley",      "lv": 5,  "grow": 58.0,  "xp": 28,  "yield": 3, "fw": 80.0,  "shop": true,  "color": [0.82, 0.72, 0.40, 1.0]},
	{"seed": "cabbage_seed",     "seed_name": "Cabbage Seed",     "crop": "cabbage",     "crop_name": "Cabbage",     "lv": 5,  "grow": 62.0,  "xp": 30,  "yield": 2, "fw": 80.0,  "shop": true,  "color": [0.45, 0.72, 0.36, 1.0]},
	{"seed": "rye_seed",         "seed_name": "Rye Seed",         "crop": "rye",         "crop_name": "Rye",         "lv": 8,  "grow": 68.0,  "xp": 34,  "yield": 3, "fw": 60.0,  "shop": true,  "color": [0.72, 0.62, 0.32, 1.0]},
	{"seed": "corn_seed",        "seed_name": "Corn Seed",        "crop": "corn",        "crop_name": "Corn",        "lv": 10, "grow": 78.0,  "xp": 40,  "yield": 2, "fw": 50.0,  "shop": true,  "color": [0.92, 0.80, 0.25, 1.0]},
	{"seed": "potato_seed",      "seed_name": "Potato Seed",      "crop": "potato",      "crop_name": "Potato",      "lv": 15, "grow": 92.0,  "xp": 50,  "yield": 3, "fw": 34.0,  "shop": true,  "color": [0.72, 0.56, 0.36, 1.0]},
	{"seed": "cotton_seed",      "seed_name": "Cotton Seed",      "crop": "cotton",      "crop_name": "Cotton",      "lv": 20, "grow": 108.0, "xp": 60,  "yield": 2, "fw": 22.0,  "shop": false, "color": [0.92, 0.92, 0.90, 1.0]},
	{"seed": "pepper_seed",      "seed_name": "Pepper Seed",      "crop": "pepper",      "crop_name": "Pepper",      "lv": 25, "grow": 122.0, "xp": 70,  "yield": 2, "fw": 16.0,  "shop": false, "color": [0.85, 0.22, 0.18, 1.0]},
	{"seed": "sugarcane_seed",   "seed_name": "Sugarcane Seed",   "crop": "sugarcane",   "crop_name": "Sugarcane",   "lv": 30, "grow": 138.0, "xp": 80,  "yield": 2, "fw": 11.0,  "shop": false, "color": [0.70, 0.82, 0.40, 1.0]},
	{"seed": "hops_seed",        "seed_name": "Hops Seed",        "crop": "hops",        "crop_name": "Hops",        "lv": 35, "grow": 150.0, "xp": 90,  "yield": 2, "fw": 7.0,   "shop": false, "color": [0.55, 0.70, 0.35, 1.0]},
	{"seed": "tomato_seed",      "seed_name": "Tomato Seed",      "crop": "tomato",      "crop_name": "Tomato",      "lv": 40, "grow": 160.0, "xp": 100, "yield": 2, "fw": 5.0,   "shop": false, "color": [0.88, 0.26, 0.18, 1.0]},
	{"seed": "moonwheat_seed",   "seed_name": "Moonwheat Seed",   "crop": "moonwheat",   "crop_name": "Moonwheat",   "lv": 45, "grow": 175.0, "xp": 115, "yield": 2, "fw": 3.2,   "shop": false, "color": [0.70, 0.78, 0.95, 1.0]},
	{"seed": "blueberry_seed",   "seed_name": "Blueberry Seed",   "crop": "blueberry",   "crop_name": "Blueberry",   "lv": 50, "grow": 185.0, "xp": 125, "yield": 2, "fw": 2.0,   "shop": false, "color": [0.30, 0.42, 0.80, 1.0]},
	{"seed": "lingonberry_seed", "seed_name": "Lingonberry Seed", "crop": "lingonberry", "crop_name": "Lingonberry", "lv": 52, "grow": 190.0, "xp": 130, "yield": 2, "fw": 1.6,   "shop": false, "color": [0.80, 0.20, 0.28, 1.0]},
	{"seed": "strawberry_seed",  "seed_name": "Strawberry Seed",  "crop": "strawberry",  "crop_name": "Strawberry",  "lv": 55, "grow": 200.0, "xp": 140, "yield": 2, "fw": 1.2,   "shop": false, "color": [0.86, 0.24, 0.30, 1.0]},
	{"seed": "peach_seed",       "seed_name": "Peach Seed",       "crop": "peach",       "crop_name": "Peach",       "lv": 60, "grow": 215.0, "xp": 155, "yield": 1, "fw": 0.7,   "shop": false, "color": [0.96, 0.70, 0.45, 1.0]},
	{"seed": "apple_seed",       "seed_name": "Apple Seed",       "crop": "apple",       "crop_name": "Apple",       "lv": 68, "grow": 235.0, "xp": 175, "yield": 2, "fw": 0.4,   "shop": false, "color": [0.85, 0.20, 0.20, 1.0]},
	{"seed": "watermelon_seed",  "seed_name": "Watermelon Seed",  "crop": "watermelon",  "crop_name": "Watermelon",  "lv": 75, "grow": 260.0, "xp": 200, "yield": 1, "fw": 0.25,  "shop": false, "color": [0.30, 0.62, 0.32, 1.0]},
	{"seed": "grape_seed",       "seed_name": "Grape Seed",       "crop": "grape",       "crop_name": "Grape",       "lv": 90, "grow": 300.0, "xp": 250, "yield": 2, "fw": 0.1,   "shop": false, "color": [0.55, 0.30, 0.65, 1.0]},
]

static func seed_def(seed_id: String) -> Dictionary:
	for s: Dictionary in SEEDS:
		if str(s["seed"]) == seed_id:
			return s
	return {}

## Farming level required to plant a seed (0 if unknown).
static func req_level(seed_id: String) -> int:
	var s := seed_def(seed_id)
	return int(s.get("lv", 0)) if not s.is_empty() else 0

## Grow seconds for a seed (fallback 60).
static func grow_secs(seed_id: String) -> float:
	var s := seed_def(seed_id)
	return float(s.get("grow", 60.0)) if not s.is_empty() else 60.0

## Highest-tier seed the player both owns and is high enough Farming level to plant.
static func best_plantable(inventory: Array, farming_level: int) -> Dictionary:
	var best: Dictionary = {}
	for s: Dictionary in SEEDS:
		if farming_level < int(s["lv"]):
			continue
		for item: Variant in inventory:
			if item is Dictionary and str((item as Dictionary).get("id", "")) == str(s["seed"]):
				if best.is_empty() or int(s["lv"]) >= int(best["lv"]):
					best = s
				break
	return best

## Per-forage seed drop with TIERED rarity derived from the seed's level:
## roughly 1-in-(5 · 1.0606^lv) — lv1 ≈ 1/5, lv20 ≈ 1/16, lv40 ≈ 1/50,
## lv90 ≈ 1/1000. Rolls high tier → low so a rare seed gets its shot first;
## returns "" when nothing drops (the common case). One seed at most per forage.
static func forage_drop_one_in(lv: int) -> float:
	return 5.0 * pow(1.0606, float(lv))

static func roll_forage_seed() -> String:
	for i in range(SEEDS.size() - 1, -1, -1):
		var s: Dictionary = SEEDS[i]
		if randf() < 1.0 / forage_drop_one_in(int(s.get("lv", 1))):
			return str(s["seed"])
	return ""

static func color_of(seed_data: Dictionary) -> Color:
	var a: Array = seed_data.get("color", [0.7, 0.7, 0.4, 1.0]) as Array
	return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
