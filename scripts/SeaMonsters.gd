extends RefCounted

## Sea-monster definitions for the fishing combat expansion. Accessed via
## `const SeaMonsters = preload("res://scripts/SeaMonsters.gd")` (matches the
## Boat.gd / Fishing.gd pattern). Phase 1: pure data — nothing spawns these yet.
## Phase 3 will wire random encounters during deep-ocean fishing, and Phase 4
## adds named-boss tiles that force specific entries from this table.
##
## Field shape is intentionally close to Monster.gd's _apply_type_stats output
## so that Phase 3's dispatch can fold these into the existing combat path with
## minimal glue:
##   name             — display name (HUD label)
##   level            — combat level (HP/dmg scaling reference)
##   max_hp / attack / defense / xp_reward — same semantics as Monster.gd
##   min_fishing_lv   — gate: encounter not rolled below this Fishing level
##   spawn_weight     — relative roll weight when an encounter triggers
##   boss             — true for fixed-tile named bosses (Phase 4)
##   shallow          — true for coast / shoreline-eligible encounters. Phase 3
##                      will use this to filter the random roll by water depth
##                      so deep-ocean tiles don't spawn river serpents and
##                      coastal tiles don't spawn krakens. Absent == false.
##   loot             — Array[{id, name, qty, color}] dropped on kill
const SEA_MONSTERS: Dictionary = {
	# Shallow-water encounters (lvl 1-5). Sized so a fresh player in an Oak
	# Rowboat (hp 30, no cannon, harpoon-only) can always win or flee. Spawn
	# weights are kept modest so they're an occasional event, not a constant
	# interrupt to fishing. Phase 3 will gate these to coast / shoreline tiles
	# via the `shallow: true` flag.
	"crab_swarm": {
		"name": "Crab Swarm", "level": 1, "max_hp": 12, "attack": 3, "defense": 1, "xp_reward": 15,
		"min_fishing_lv": 1, "spawn_weight": 0.70, "boss": false, "shallow": true,
		"loot": [{"id": "crab_claw", "name": "Crab Claw", "qty": 1, "color": Color(0.85, 0.35, 0.18)}],
	},
	"angry_seagull_flock": {
		"name": "Angry Seagull Flock", "level": 1, "max_hp": 8, "attack": 2, "defense": 0, "xp_reward": 10,
		"min_fishing_lv": 1, "spawn_weight": 0.60, "boss": false, "shallow": true,
		"loot": [{"id": "seagull_feather", "name": "Seagull Feather", "qty": 2, "color": Color(0.92, 0.92, 0.88)}],
	},
	"snapping_eel": {
		"name": "Snapping Eel", "level": 3, "max_hp": 18, "attack": 5, "defense": 1, "xp_reward": 22,
		"min_fishing_lv": 3, "spawn_weight": 0.60, "boss": false, "shallow": true,
		"loot": [{"id": "eel_skin", "name": "Eel Skin", "qty": 1, "color": Color(0.32, 0.38, 0.30)}],
	},
	"river_serpent": {
		"name": "River Serpent", "level": 5, "max_hp": 24, "attack": 7, "defense": 2, "xp_reward": 30,
		"min_fishing_lv": 5, "spawn_weight": 0.55, "boss": false, "shallow": true,
		"loot": [{"id": "serpent_scrap", "name": "Serpent Scrap", "qty": 1, "color": Color(0.40, 0.60, 0.42)}],
	},
	"giant_crab": {
		"name": "Giant Crab", "level": 8, "max_hp": 30, "attack": 8, "defense": 6, "xp_reward": 40,
		"min_fishing_lv": 1, "spawn_weight": 1.0, "boss": false,
		"loot": [{"id": "crab_claw", "name": "Crab Claw", "qty": 1, "color": Color(0.85, 0.35, 0.18)}],
	},
	"razorfin_shark": {
		"name": "Razorfin Shark", "level": 18, "max_hp": 55, "attack": 16, "defense": 5, "xp_reward": 90,
		"min_fishing_lv": 15, "spawn_weight": 0.85, "boss": false,
		"loot": [{"id": "razor_tooth", "name": "Razor Tooth", "qty": 1, "color": Color(0.92, 0.92, 0.95)}],
	},
	"tide_revenant": {
		"name": "Tide Revenant", "level": 25, "max_hp": 80, "attack": 22, "defense": 10, "xp_reward": 140,
		"min_fishing_lv": 25, "spawn_weight": 0.80, "boss": false,
		"loot": [{"id": "barnacle_shard", "name": "Barnacle Shard", "qty": 1, "color": Color(0.35, 0.55, 0.50)}],
	},
	"deep_squid": {
		"name": "Deep Squid", "level": 32, "max_hp": 110, "attack": 26, "defense": 8, "xp_reward": 200,
		"min_fishing_lv": 35, "spawn_weight": 0.75, "boss": false,
		"loot": [{"id": "squid_ink", "name": "Squid Ink", "qty": 1, "color": Color(0.08, 0.05, 0.18)}],
	},
	"abyss_serpent": {
		"name": "Abyss Serpent", "level": 40, "max_hp": 150, "attack": 32, "defense": 14, "xp_reward": 280,
		"min_fishing_lv": 45, "spawn_weight": 0.65, "boss": false,
		"loot": [{"id": "serpent_fang", "name": "Serpent Fang", "qty": 1, "color": Color(0.45, 0.70, 0.55)}],
	},
	"siren": {
		"name": "Siren", "level": 45, "max_hp": 170, "attack": 38, "defense": 12, "xp_reward": 340,
		"min_fishing_lv": 50, "spawn_weight": 0.55, "boss": false,
		"loot": [{"id": "siren_scale", "name": "Siren Scale", "qty": 1, "color": Color(0.55, 0.75, 0.92)}],
	},
	"tide_witch": {
		"name": "Tide Witch", "level": 52, "max_hp": 200, "attack": 44, "defense": 18, "xp_reward": 420,
		"min_fishing_lv": 60, "spawn_weight": 0.50, "boss": false,
		"loot": [{"id": "witch_pearl", "name": "Witch Pearl", "qty": 1, "color": Color(0.85, 0.62, 0.92)}],
	},
	"frost_leviathan": {
		"name": "Frost Leviathan", "level": 60, "max_hp": 260, "attack": 52, "defense": 22, "xp_reward": 540,
		"min_fishing_lv": 70, "spawn_weight": 0.40, "boss": false,
		"loot": [{"id": "frost_heart", "name": "Frost Heart", "qty": 1, "color": Color(0.55, 0.82, 0.98)}],
	},
	"flame_anglerfish": {
		"name": "Flame Anglerfish", "level": 65, "max_hp": 290, "attack": 58, "defense": 20, "xp_reward": 620,
		"min_fishing_lv": 75, "spawn_weight": 0.38, "boss": false,
		"loot": [{"id": "ember_lantern", "name": "Ember Lantern", "qty": 1, "color": Color(1.0, 0.55, 0.08)}],
	},
	"void_kraken": {
		"name": "Void Kraken", "level": 72, "max_hp": 340, "attack": 66, "defense": 25, "xp_reward": 740,
		"min_fishing_lv": 82, "spawn_weight": 0.30, "boss": false,
		"loot": [{"id": "void_tentacle", "name": "Void Tentacle", "qty": 1, "color": Color(0.25, 0.05, 0.45)}],
	},
	# Named bosses (Phase 4 spawns these at fixed deep-water tiles via the
	# BOSS_SPAWNS table below). Not in the random-encounter roll because
	# spawn_weight is 0 — Phase 3's roll loop skips zero-weight entries.
	# `phases` is the Phase 4 multi-stage hook: each entry triggers when the
	# boss's HP crosses `trigger_pct` (fraction of max). BoatCombat applies
	# `atk_mult` / `def_mult` to the (cloned, not table-mutating) monster
	# stats and prints `msg` to the combat log. Entries apply in array order
	# the first time their threshold is crossed.
	"jormungandr_spawn": {
		"name": "Jörmungandr's Spawn", "level": 82, "max_hp": 420, "attack": 78, "defense": 30, "xp_reward": 900,
		"min_fishing_lv": 88, "spawn_weight": 0.0, "boss": true,
		"loot": [{"id": "world_serpent_scale", "name": "World Serpent Scale", "qty": 1, "color": Color(0.20, 0.55, 0.40)}],
		"phases": [
			{"trigger_pct": 0.50, "atk_mult": 1.5, "def_mult": 0.70,
			 "msg": "Jörmungandr's coils tighten — its bite turns vicious!"},
		],
	},
	"drowned_god": {
		"name": "Drowned God", "level": 95, "max_hp": 600, "attack": 95, "defense": 38, "xp_reward": 1400,
		"min_fishing_lv": 95, "spawn_weight": 0.0, "boss": true,
		"loot": [{"id": "drowned_crown", "name": "Drowned Crown", "qty": 1, "color": Color(0.75, 0.78, 0.88)}],
		"phases": [
			{"trigger_pct": 0.50, "atk_mult": 1.4, "def_mult": 0.70,
			 "msg": "The Drowned God roars from the abyss!"},
			{"trigger_pct": 0.20, "atk_mult": 1.3, "def_mult": 0.80,
			 "msg": "The Drowned God unleashes its final wrath!"},
		],
	},
}

## Fixed-tile boss spawns (Phase 4). The player must sail their cast within
## `radius` tiles of the spawn point AND be in a boat of `min_boat_tier` or
## higher to trigger the encounter. IDs are SEA_MONSTERS keys with boss: true.
## Coords are deliberately inside the Serpent Sea (western ocean) so a player
## has to invest real travel time to reach them.
const BOSS_SPAWNS: Array = [
	{"id": "jormungandr_spawn", "tx":  6, "ty": 180, "radius": 3, "min_boat_tier": 3},
	{"id": "drowned_god",       "tx":  8, "ty": 110, "radius": 3, "min_boat_tier": 4},
]

## Returns the BOSS_SPAWNS entry (Dictionary) the given world position falls
## within range of, or {} if none matches. Caller is expected to filter by
## boat tier and per-session defeated state separately. tile_px == Ground's
## TILE constant (32 in this project).
static func boss_spawn_at(world_pos: Vector2, tile_px: float) -> Dictionary:
	for entry: Variant in BOSS_SPAWNS:
		if not entry is Dictionary:
			continue
		var d: Dictionary = entry
		var cx := (float(d.get("tx", 0)) + 0.5) * tile_px
		var cy := (float(d.get("ty", 0)) + 0.5) * tile_px
		var r  := float(d.get("radius", 1)) * tile_px
		if Vector2(cx, cy).distance_to(world_pos) <= r:
			return d
	return {}

static func is_sea_monster(monster_type: String) -> bool:
	return SEA_MONSTERS.has(monster_type)

static func data(monster_type: String) -> Dictionary:
	return SEA_MONSTERS.get(monster_type, {})

## Pick a random non-boss entry the player qualifies for. Weighted by
## `spawn_weight`; entries with weight 0 (bosses) are excluded. Filtered by
## tile depth — `shallow=true` only returns shoreline-flagged monsters
## (`shallow: true` in the table); `shallow=false` only returns the deep
## entries (absent flag == false). Returns "" if no eligible monster exists
## at this fishing level and depth.
static func roll_encounter(fishing_lv: int, shallow: bool) -> String:
	var pool: Array = []
	var weights: Array = []
	var total := 0.0
	for k: String in SEA_MONSTERS.keys():
		var m: Dictionary = SEA_MONSTERS[k]
		var w := float(m.get("spawn_weight", 0.0))
		if w <= 0.0: continue
		if fishing_lv < int(m.get("min_fishing_lv", 0)): continue
		if bool(m.get("shallow", false)) != shallow: continue
		pool.append(k)
		weights.append(w)
		total += w
	if pool.is_empty() or total <= 0.0:
		return ""
	var r := randf() * total
	var acc := 0.0
	for i in range(pool.size()):
		acc += float(weights[i])
		if r <= acc:
			return str(pool[i])
	return str(pool[pool.size() - 1])
