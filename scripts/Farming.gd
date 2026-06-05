extends RefCounted

## Farming definitions — shared by FarmPlot.gd (planting/harvest) and Interactable
## (seed drops from foraging). Used via `const Farming = preload(...)` (static).
##
## lv    = Farming level required to PLANT the seed (seeds unlock as you level).
## grow  = seconds to mature (halved while watered).
## yield = crops harvested.  crop/crop_name = the harvested item (sellable / cooking).

const SEEDS: Array = [
	{"seed": "barley_seed",  "seed_name": "Barley Seed",  "crop": "barley",  "crop_name": "Barley",
	 "lv": 1,  "xp": 25,  "grow": 50.0,  "yield": 3, "color": [0.85, 0.78, 0.35, 1.0]},
	{"seed": "cabbage_seed", "seed_name": "Cabbage Seed", "crop": "cabbage", "crop_name": "Cabbage",
	 "lv": 10, "xp": 45,  "grow": 75.0,  "yield": 2, "color": [0.45, 0.78, 0.36, 1.0]},
	{"seed": "onion_seed",   "seed_name": "Onion Seed",   "crop": "onion",   "crop_name": "Onion",
	 "lv": 20, "xp": 70,  "grow": 100.0, "yield": 2, "color": [0.86, 0.74, 0.45, 1.0]},
	{"seed": "wheat_seed",   "seed_name": "Wheat Seed",   "crop": "wheat",   "crop_name": "Wheat",
	 "lv": 35, "xp": 100, "grow": 130.0, "yield": 3, "color": [0.90, 0.80, 0.30, 1.0]},
	{"seed": "tomato_seed",  "seed_name": "Tomato Seed",  "crop": "tomato",  "crop_name": "Tomato",
	 "lv": 50, "xp": 140, "grow": 160.0, "yield": 2, "color": [0.88, 0.26, 0.18, 1.0]},
]

static func seed_def(seed_id: String) -> Dictionary:
	for s: Dictionary in SEEDS:
		if str(s["seed"]) == seed_id:
			return s
	return {}

## Highest-tier seed the player both owns and is high enough Farming level to plant.
static func best_plantable(inventory: Array, farming_level: int) -> Dictionary:
	for i in range(SEEDS.size() - 1, -1, -1):
		var s: Dictionary = SEEDS[i]
		if farming_level < int(s["lv"]):
			continue
		for item: Variant in inventory:
			if item is Dictionary and str((item as Dictionary).get("id", "")) == str(s["seed"]):
				return s
	return {}

## Weighted random seed for a foraging drop — basics common, advanced rare.
static func random_seed_id() -> String:
	var r := randf()
	if r < 0.50: return "barley_seed"
	if r < 0.75: return "cabbage_seed"
	if r < 0.89: return "onion_seed"
	if r < 0.97: return "wheat_seed"
	return "tomato_seed"

static func color_of(seed_data: Dictionary) -> Color:
	var a: Array = seed_data.get("color", [0.7, 0.7, 0.4, 1.0]) as Array
	return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
