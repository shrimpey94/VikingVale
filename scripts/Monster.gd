extends Area2D

const LootDropScript := preload("res://scripts/LootDrop.gd")

# Rare boot drops: monster_type → {id, name, color, chance}
const BOOT_DROPS: Dictionary = {
	"goblin":           {"id":"leather_boots","name":"Leather Boots","color":Color(0.55,0.38,0.18),"chance":0.05},
	"bandit":           {"id":"leather_boots","name":"Leather Boots","color":Color(0.55,0.38,0.18),"chance":0.06},
	"skeleton":         {"id":"iron_boots",   "name":"Iron Boots",   "color":Color(0.60,0.62,0.65),"chance":0.05},
	"troll":            {"id":"iron_boots",   "name":"Iron Boots",   "color":Color(0.60,0.62,0.65),"chance":0.05},
	"frost_giant":      {"id":"mithril_boots","name":"Mithril Boots","color":Color(0.35,0.55,0.90),"chance":0.04},
	"ice_draugr":       {"id":"mithril_boots","name":"Mithril Boots","color":Color(0.35,0.55,0.90),"chance":0.04},
	"death_knight":     {"id":"mithril_boots","name":"Mithril Boots","color":Color(0.35,0.55,0.90),"chance":0.05},
	"dragon":           {"id":"dragon_boots", "name":"Dragon Boots", "color":Color(0.20,0.75,0.35),"chance":0.08},
	"nidhogg":          {"id":"dragon_boots", "name":"Dragon Boots", "color":Color(0.20,0.75,0.35),"chance":0.15},
}

# Rare boss gem drops (Phase 1 Jewelcrafting): monster_type → {id,name,color,chance}.
# Low chance, tougher bosses drop rarer gems. Diamond stays genuinely rare.
const GEM_DROPS: Dictionary = {
	"frost_giant":      {"id":"opal",     "name":"Opal",     "color":Color(0.82,0.90,0.95),"chance":0.05},
	"fire_giant":       {"id":"amethyst", "name":"Amethyst", "color":Color(0.62,0.38,0.85),"chance":0.05},
	"magma_elemental":  {"id":"amethyst", "name":"Amethyst", "color":Color(0.62,0.38,0.85),"chance":0.06},
	"death_knight":     {"id":"amethyst", "name":"Amethyst", "color":Color(0.62,0.38,0.85),"chance":0.05},
	"nidhogg":          {"id":"diamond",  "name":"Diamond",  "color":Color(0.85,0.95,1.00),"chance":0.10},
	"dragon":           {"id":"diamond",  "name":"Diamond",  "color":Color(0.85,0.95,1.00),"chance":0.08},
}

# Soul-skill remains: EVERY monster has a ~50% chance to drop one buriable item
# (bury for Soul XP). Tiered by the monster's level so tougher kills give better
# remains. [max_level_exclusive, id, name, color]; last tier catches everything.
# Ids must exist in GameManager.BONE_XP for the bury action to grant XP.
const SOUL_DROP_CHANCE := 0.5
const SOUL_DROPS: Array = [
	[20, "bone_fragment", "Bone Fragment", Color(0.90, 0.88, 0.75)],
	[45, "cursed_bone",   "Cursed Bone",   Color(0.62, 0.58, 0.40)],
	[9999, "soul_essence","Soul Essence",  Color(0.78, 0.48, 0.92)],
]

@export var monster_type: String = "rat"   # rat | skeleton | goblin | draugr | nidhogg

# ── Stats (set by World based on type) ───────────────────────────────────────
var display_name: String = "Rat"
var level:        int    = 1
var max_hp:       int    = 5
var current_hp:   int    = 5
var attack:       int    = 2
var defense:      int    = 0
var xp_reward:    int    = 8
var loot:         Array[Dictionary]  = []   # [{id, name, qty, color}]

# ── Stat rebalance (v1.5.3) ──────────────────────────────────────────────────
# `_apply_type_stats` sets the authored per-type BASE (its flavour: a giant is
# tankier than a rat at the same level). `_apply_toughness` then applies a
# super-linear LEVEL curve on top so a lv60 boss is a genuine wall instead of a
# ×(60/35) linear bump — that's why a lv14 could shred a lv60 boss before. The
# base is snapshotted so scale_to_level recomputes cleanly for ANY level.
const HP_PER_LEVEL  := 0.05    # +5% max_hp per level  → lv35 ≈ ×2.75, lv76 ≈ ×4.8
const ATK_PER_LEVEL := 0.015
const DEF_PER_LEVEL := 0.02
const XP_PER_LEVEL  := 0.02    # tankier high mobs pay out more, keeping XP/hr sane
var _base_hp:  int = 5
var _base_atk: int = 2
var _base_def: int = 0
var _base_xp:  int = 8
var _base_lv:  int = 1

# Phase 5 of the gold economy — guaranteed gold roll on death within
# [gold_min, gold_max]. 0..0 means "no gold drop" (most monsters). Set per
# type in _apply_type_stats. Server-managed kills route gold through the
# server's _monster_die → gold_pile_spawn broadcast; local kills (offline /
# non-server-tracked monsters) spawn the pile client-side via _spawn_local_gold_pile.
var gold_min:     int = 0
var gold_max:     int = 0

var is_alive:    bool    = true
var is_hovered:  bool    = false
var _regen_timer: float  = 0.0
var _time:        float  = 0.0
var _hit_flash:   float  = 0.0
## Attack profile — assigned per-type in `_apply_type_stats`. Default is
## melee at 32 px (a bit longer than the old ATTACK_RANGE 20 used server-side,
## letting a mob swing from just outside body contact). Ranged/magic types
## bump `attack_range` up + swap `attack_style` so server can gate LOS + fire
## the appropriate projectile broadcast.
var attack_style:     String = "melee"       # "melee" | "ranged" | "magic"
var attack_range_px:  int    = 32
var projectile_color: Color  = Color(1, 1, 1)
## Idle style — drives the per-type idle animation dispatch in _draw.
## "breathing" (default) = sin bob; "slithering" = horizontal sway only;
## "floating" = drift + rotation; "twitching" = periodic jitter;
## "perched" = subtle head bob, body stays still.
var idle_style:       String = "breathing"
## Twitch-idle state — jitter every few seconds for small critters. Only
## consulted when `idle_style == "twitching"`.
var _twitch_next_at:  float  = 0.0
var _twitch_offset:   Vector2 = Vector2.ZERO
## Attack wind-up telegraph — 0.20 s anticipation before a broadcast
## damage hit lands. Server sets `attack_wind_up_active` via a broadcast
## msg; client counts it down and draws the pre-attack pose.
var _atk_wind_t:      float  = 0.0
## Death animation — 0.6 s fall + fade after `is_alive` flips false.
## Applied by `_draw_dead` instead of the old static grey circle.
var _dead_t:          float  = 0.0
const _DEATH_ANIM_SEC := 0.6
# Walking animation state — _walk_time accumulates only while the body is
# actually translating (either pursue path locally or the server position
# tween pulling us toward a wander target). Driven by per-frame position
# delta in _process so it works for both server-managed and offline mobs.
var _walk_time:   float  = 0.0
var _last_pos:    Vector2 = Vector2.ZERO
var _moving_anim: bool   = false
const RESPAWN_TIME  := 45.0
const PURSUE_SPEED  := 39.0   # reduced 40% from 65 to match server's slowdown
const ATTACK_RANGE  := 50.0

var _pursuing:       bool    = false
var _pursue_target:  Node2D  = null
var _home_pos:       Vector2 = Vector2.ZERO

# Server-authoritative shared combat (set by World on chunk monsters).
var entity_id:       String  = ""

func _is_server_managed() -> bool:
	return entity_id != "" and NetworkManager.state == NetworkManager.NetState.LOGGED_IN

func _ready() -> void:
	_apply_type_stats()
	add_to_group("monster")
	input_pickable  = true
	collision_layer = 8
	collision_mask  = 0
	_setup_collision()
	_last_pos = global_position   # avoid 1-frame "moving" pose on spawn
	mouse_entered.connect(func() -> void:
		# Corpses shouldn't react to hover at all — they're not
		# interactive. Skip the is_hovered flag (which would otherwise
		# brighten the name label via _draw_name_label) AND the modulate.
		if not is_alive:
			return
		is_hovered = true
		self_modulate = Color(1.20, 1.20, 1.20)
		queue_redraw())
	mouse_exited.connect(func() -> void:
		is_hovered = false
		self_modulate = Color.WHITE
		queue_redraw())

func start_pursuit(player: Node2D) -> void:
	_pursuing      = true
	_pursue_target = player
	_home_pos      = global_position

func stop_pursuit() -> void:
	_pursuing      = false
	_pursue_target = null

func _apply_type_stats() -> void:
	match monster_type:
		"rat":
			display_name = "Giant Rat";  level = 2;  max_hp = 8;   attack = 3;  defense = 0;  xp_reward = 8
			loot = [{"id":"rat_bone","name":"Rat Bone","qty":1,"color":Color(0.85,0.82,0.70)},
				{"id":"raw_meat","name":"Raw Meat","qty":1,"color":Color(0.78,0.30,0.28)}]
			idle_style = "twitching"
		"plague_rat":
			# Mini-boss variant — semi-hostile pursuer. `plague_tooth` is a
			# rare crafting reagent (future Herblore plague-cure recipe hook).
			display_name = "Plague Rat"; level = 10; max_hp = 40; attack = 12; defense = 3; xp_reward = 55
			loot = [{"id":"rat_bone","name":"Rat Bone","qty":1,"color":Color(0.85,0.82,0.70)},
				{"id":"raw_meat","name":"Raw Meat","qty":1,"color":Color(0.78,0.30,0.28)},
				{"id":"plague_tooth","name":"Plague Tooth","qty":1,"color":Color(0.82,0.75,0.20)}]
			gold_min = 20; gold_max = 300
		"skeleton":
			display_name = "Skeleton";   level = 8;  max_hp = 25;  attack = 9;  defense = 5;  xp_reward = 35
			loot = [{"id":"bone","name":"Bone","qty":1,"color":Color(0.90,0.88,0.75)}]
			gold_min = 30;   gold_max = 500
		"goblin":
			display_name = "Goblin";     level = 5;  max_hp = 15;  attack = 7;  defense = 3;  xp_reward = 22
			loot = [{"id":"goblin_ear","name":"Goblin Ear","qty":1,"color":Color(0.25,0.55,0.15)}]
			gold_min = 5;    gold_max = 200
		"draugr":
			display_name = "Draugr";     level = 18; max_hp = 50;  attack = 16; defense = 10; xp_reward = 90
			loot = [{"id":"draugr_shard","name":"Draugr Shard","qty":1,"color":Color(0.35,0.40,0.60)}]
		"nidhogg":
			display_name = "Níðhöggr";   level = 35; max_hp = 120; attack = 28; defense = 18; xp_reward = 250
			loot = [{"id":"dragon_scale","name":"Dragon Scale","qty":1,"color":Color(0.20,0.60,0.35)}]
			# Fire breath — thicker magic projectile, longest range. Server
			# emits three orbs in a spread when it fires (visual only).
			attack_style = "magic"; attack_range_px = 260
			projectile_color = Color(1.00, 0.60, 0.15)
			idle_style = "perched"
		"chicken":
			display_name = "Chicken";        level = 1;  max_hp = 3;   attack = 1;  defense = 0;  xp_reward = 3
			loot = [{"id":"feather","name":"Feather","qty":1,"color":Color(0.95,0.94,0.88)},
				{"id":"raw_chicken","name":"Raw Chicken","qty":1,"color":Color(0.92,0.80,0.62)}]
			idle_style = "twitching"
		"wolf":
			display_name = "Wolf";           level = 6;  max_hp = 18;  attack = 8;  defense = 2;  xp_reward = 20
			loot = [{"id":"wolf_pelt","name":"Wolf Pelt","qty":1,"color":Color(0.55,0.52,0.48)},
				{"id":"raw_meat","name":"Raw Meat","qty":1,"color":Color(0.78,0.30,0.28)}]
		"bandit":
			display_name = "Bandit";         level = 15; max_hp = 35;  attack = 13; defense = 6;  xp_reward = 45
			loot = [{"id":"bandit_hood","name":"Bandit Hood","qty":1,"color":Color(0.15,0.12,0.10)}]
			gold_min = 100;  gold_max = 2000
			# Ranged bandit — wooden-arrow tint, mid range, LOS-gated by
			# the server so a bandit behind a hill won't sniff-shoot.
			attack_style = "ranged"; attack_range_px = 200
			projectile_color = Color(0.90, 0.85, 0.65)
		# ── Kjelvik city watch (Phase 5b) ────────────────────────────────────
		# Spawned by the SERVER in escalating waves when someone attacks a
		# townsperson, walks in PvP-flagged, or has tanked their standing. Mid/
		# high tier by design and they tier up per wave (the server scales the
		# level on spawn). Deliberately drop NOTHING and carry no gold — the
		# fight is a punishment, not a farm, and loot would invite griefing.
		"guard":
			display_name = "City Guard";     level = 30; max_hp = 90;  attack = 26; defense = 20; xp_reward = 110
			loot = []
		"guard_ranger":
			display_name = "Guard Ranger";   level = 40; max_hp = 85;  attack = 32; defense = 16; xp_reward = 150
			loot = []
			attack_style = "ranged"; attack_range_px = 220
			projectile_color = Color(0.95, 0.90, 0.70)
		"guard_magi":
			display_name = "Guard Magi";     level = 50; max_hp = 80;  attack = 40; defense = 14; xp_reward = 200
			loot = []
			attack_style = "magic"; attack_range_px = 240
			projectile_color = Color(0.45, 0.70, 1.00)
		"bear":
			display_name = "Bear";           level = 22; max_hp = 60;  attack = 18; defense = 8;  xp_reward = 70
			loot = [{"id":"bear_claw","name":"Bear Claw","qty":1,"color":Color(0.55,0.42,0.28)},
				{"id":"raw_meat","name":"Raw Meat","qty":2,"color":Color(0.78,0.30,0.28)}]
		"troll":
			display_name = "Troll";          level = 25; max_hp = 80;  attack = 20; defense = 12; xp_reward = 100
			loot = [{"id":"troll_hide","name":"Troll Hide","qty":1,"color":Color(0.35,0.42,0.28)},
				{"id":"raw_meat","name":"Raw Meat","qty":2,"color":Color(0.78,0.30,0.28)}]
			gold_min = 400;  gold_max = 600
		"forest_spirit":
			display_name = "Forest Spirit";  level = 30; max_hp = 55;  attack = 22; defense = 5;  xp_reward = 85
			loot = [{"id":"spirit_essence","name":"Spirit Essence","qty":1,"color":Color(0.40,0.90,0.50)}]
			idle_style = "floating"
		"spider":
			display_name = "Spider";         level = 24; max_hp = 45;  attack = 19; defense = 4;  xp_reward = 65
			loot = [{"id":"spider_silk","name":"Spider Silk","qty":1,"color":Color(0.85,0.85,0.88)}]
			idle_style = "twitching"
		"ice_wolf":
			display_name = "Ice Wolf";       level = 40; max_hp = 90;  attack = 30; defense = 15; xp_reward = 130
			loot = [{"id":"ice_fang","name":"Ice Fang","qty":1,"color":Color(0.70,0.88,0.98)}]
		"frost_giant":
			display_name = "Frost Giant";    level = 45; max_hp = 130; attack = 35; defense = 20; xp_reward = 180
			loot = [{"id":"frost_crystal","name":"Frost Crystal","qty":1,"color":Color(0.60,0.82,0.95)}]
			gold_min = 500;  gold_max = 2000
		"ice_draugr":
			display_name = "Ice Draugr";     level = 50; max_hp = 110; attack = 38; defense = 18; xp_reward = 160
			loot = [{"id":"ice_shard","name":"Ice Shard","qty":1,"color":Color(0.65,0.85,0.95)}]
		"fire_imp":
			display_name = "Fire Imp";       level = 55; max_hp = 95;  attack = 42; defense = 12; xp_reward = 200
			loot = [{"id":"imp_horn","name":"Imp Horn","qty":1,"color":Color(0.90,0.25,0.10)}]
			gold_min = 20;   gold_max = 100
			# Fireball caster — hot orange projectile, medium range.
			attack_style = "magic"; attack_range_px = 220
			projectile_color = Color(1.00, 0.50, 0.10)
			idle_style = "floating"
		"lava_crawler":
			display_name = "Lava Crawler";   level = 60; max_hp = 140; attack = 48; defense = 22; xp_reward = 240
			loot = [{"id":"lava_carapace","name":"Lava Carapace","qty":1,"color":Color(0.80,0.30,0.05)}]
			idle_style = "slithering"
		"fire_giant":
			display_name = "Fire Giant";     level = 45; max_hp = 180; attack = 55; defense = 28; xp_reward = 300
			loot = [{"id":"giant_ember","name":"Giant Ember","qty":1,"color":Color(1.00,0.55,0.10)}]
			gold_min = 700;  gold_max = 2000
		"shadow_draugr":
			display_name = "Shadow Draugr"; level = 68; max_hp = 160; attack = 58; defense = 25; xp_reward = 340
			loot = [{"id":"shadow_essence","name":"Shadow Essence","qty":1,"color":Color(0.25,0.05,0.35)}]
		"death_knight":
			display_name = "Death Knight";   level = 75; max_hp = 200; attack = 65; defense = 35; xp_reward = 400
			loot = [{"id":"death_rune","name":"Death Rune","qty":1,"color":Color(0.15,0.80,0.40)}]
			gold_min = 1000; gold_max = 4000
		"spectral_warrior":
			display_name = "Spectral Warrior"; level = 80; max_hp = 220; attack = 72; defense = 30; xp_reward = 450
			loot = [{"id":"spectral_essence","name":"Spectral Essence","qty":1,"color":Color(0.55,0.75,0.95)}]
			gold_min = 3000; gold_max = 10000
		# ── Water monsters (water-only pathing, semi-transparent) ──────────────
		"shark":
			display_name = "Shark";           level = 30; max_hp = 110; attack = 14; defense = 8;  xp_reward = 95
			loot = [{"id":"shark_tooth","name":"Shark Tooth","qty":1,"color":Color(0.95,0.94,0.88)},
				{"id":"raw_shark","name":"Raw Shark","qty":1,"color":Color(0.55,0.60,0.68)}]
			gold_min = 40; gold_max = 180
		# ── Bridge monsters (variable-level, zone transition) ──────────────────
		"dire_wolf":
			display_name = "Dire Wolf";       level = 15; max_hp = 40;  attack = 12; defense = 5;  xp_reward = 55
			loot = [{"id":"wolf_pelt","name":"Wolf Pelt","qty":1,"color":Color(0.30,0.25,0.35)}]
		"elder_bear":
			display_name = "Elder Bear";      level = 29; max_hp = 85;  attack = 22; defense = 11; xp_reward = 105
			loot = [{"id":"bear_claw","name":"Bear Claw","qty":1,"color":Color(0.40,0.30,0.18)}]
		"ancient_troll":
			display_name = "Ancient Troll";   level = 44; max_hp = 140; attack = 34; defense = 18; xp_reward = 200
			loot = [{"id":"troll_hide","name":"Troll Hide","qty":1,"color":Color(0.28,0.35,0.22)}]
		"swamp_troll":
			display_name = "Swamp Troll";     level = 30; max_hp = 100; attack = 24; defense = 13; xp_reward = 130
			loot = [{"id":"troll_hide","name":"Troll Hide","qty":1,"color":Color(0.22,0.34,0.20)},
				{"id":"herbs","name":"Herbs","qty":2,"color":Color(0.40,0.60,0.25)}]
		"ice_troll":
			display_name = "Ice Troll";       level = 40; max_hp = 130; attack = 30; defense = 16; xp_reward = 175
			loot = [{"id":"troll_hide","name":"Troll Hide","qty":1,"color":Color(0.55,0.72,0.85)},
				{"id":"ice_shard","name":"Ice Shard","qty":1,"color":Color(0.85,0.95,1.0)}]
		"cave_troll":
			display_name = "Cave Troll";      level = 45; max_hp = 155; attack = 36; defense = 20; xp_reward = 215
			loot = [{"id":"troll_hide","name":"Troll Hide","qty":1,"color":Color(0.42,0.40,0.36)},
				{"id":"iron_ore","name":"Iron Ore","qty":1,"color":Color(0.55,0.55,0.60)}]
		"frost_wyrm":
			display_name = "Frost Wyrm";      level = 62; max_hp = 190; attack = 50; defense = 25; xp_reward = 310
			loot = [{"id":"ice_shard","name":"Ice Shard","qty":1,"color":Color(0.55,0.80,0.95)}]
			idle_style = "slithering"
		"magma_elemental":
			display_name = "Magma Elemental"; level = 76; max_hp = 240; attack = 68; defense = 32; xp_reward = 430
			loot = [{"id":"giant_ember","name":"Giant Ember","qty":1,"color":Color(0.90,0.30,0.05)}]
			idle_style = "floating"
		# ── Slim dragon family (V1.5.4) — lean cousins of Níðhöggr ──────────────
		"drake":
			display_name = "Bronze Drake";    level = 48; max_hp = 150; attack = 44; defense = 22; xp_reward = 260
			loot = [{"id":"dragon_scale","name":"Dragon Scale","qty":1,"color":Color(0.62,0.40,0.18)}]
			gold_min = 400;  gold_max = 1800
			# Fire breath — like Níðhöggr but shorter range on the smaller drake.
			attack_style = "magic"; attack_range_px = 220
			projectile_color = Color(1.00, 0.60, 0.15)
		"wyvern":
			display_name = "Venom Wyvern";    level = 58; max_hp = 175; attack = 52; defense = 20; xp_reward = 320
			loot = [{"id":"dragon_scale","name":"Dragon Scale","qty":1,"color":Color(0.42,0.64,0.46)}]
			gold_min = 500;  gold_max = 2200
			attack_style = "magic"; attack_range_px = 240
			projectile_color = Color(0.60, 0.95, 0.35)
	# Snapshot the authored base (per-type flavour) BEFORE the level curve, so
	# scale_to_level can recompute cleanly and never double-apply toughness.
	_base_hp = max_hp; _base_atk = attack; _base_def = defense
	_base_xp = xp_reward; _base_lv = maxi(1, level)
	_apply_toughness(level)

## Final stats = authored base flavour scaled linearly to `lv`, then a
## super-linear level toughness curve on top. Always recomputed from the base
## snapshot, so it's idempotent for any level.
func _apply_toughness(lv: int) -> void:
	level = maxi(1, lv)
	var ratio := float(level) / float(maxi(1, _base_lv))
	max_hp    = maxi(6, roundi(float(_base_hp) * ratio * (1.0 + float(level) * HP_PER_LEVEL)))
	current_hp = max_hp
	attack    = maxi(1, roundi(float(_base_atk) * ratio * (1.0 + float(level) * ATK_PER_LEVEL)))
	defense   = maxi(0, roundi(float(_base_def) * ratio * (1.0 + float(level) * DEF_PER_LEVEL)))
	xp_reward = maxi(1, roundi(float(_base_xp) * ratio * (1.0 + float(level) * XP_PER_LEVEL)))

func scale_to_level(lv: int) -> void:
	_apply_toughness(lv)

func _setup_collision() -> void:
	var cs   := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null:
		cs = CollisionShape2D.new()
		add_child(cs)
	var circ := CircleShape2D.new()
	match monster_type:
		"nidhogg": circ.radius = 22.0
		"drake", "wyvern": circ.radius = 18.0
		"draugr":  circ.radius = 16.0
		_:         circ.radius = 12.0
	cs.shape = circ

func _process(delta: float) -> void:
	_time += delta
	if _hit_flash > 0.0:
		_hit_flash -= delta
	# Attack wind-up telegraph — count down + trigger redraw so the
	# anticipation pose renders during the 0.20 s pre-attack window.
	if _atk_wind_t > 0.0:
		_atk_wind_t -= delta
	# Death animation timer — feeds `_draw_dead`. Runs even while server
	# holds the entity so the corpse-fall reads on client immediately.
	if not is_alive:
		_dead_t += delta
	# Twitch idle — periodic small jitter for small critters. Only tick
	# when `idle_style == "twitching"` and the mob isn't moving.
	if idle_style == "twitching" and is_alive and not _moving_anim:
		if _time >= _twitch_next_at:
			_twitch_offset = Vector2(randf_range(-1.5, 1.5),
				randf_range(-1.0, 1.0))
			_twitch_next_at = _time + randf_range(3.0, 6.0)
		# Decay offset back toward zero so the jitter is a brief pop.
		_twitch_offset = _twitch_offset.lerp(Vector2.ZERO, delta * 4.0)
	if not is_alive:
		# Server drives respawn for shared monsters; only self-respawn offline/local.
		if not _is_server_managed():
			_regen_timer -= delta
			if _regen_timer <= 0.0:
				_respawn()
	elif _pursuing and _pursue_target != null and is_instance_valid(_pursue_target):
		# Local pursuit is the OFFLINE / fallback path. When the monster is
		# server-managed the server's AI loop owns the position, and
		# World.gd tweens it via monster_pos_update broadcasts. Running
		# local pursuit on top of that tween creates the "2-3 px shuffle"
		# bug — both writers race for global_position every frame and the
		# net movement is near zero. Guard so only the local-only path
		# advances the monster here.
		if not _is_server_managed():
			var dir := _pursue_target.global_position - global_position
			var dist := dir.length()
			if dist > ATTACK_RANGE:
				global_position += dir.normalized() * PURSUE_SPEED * delta
	# ── Walking animation — drive from actual per-frame position delta so this
	# works for both server-managed (tweened by World.gd from monster_pos_update)
	# and local-pursue paths without each having to flip an "I'm moving" flag.
	# Threshold of 0.4 px/frame filters out micro-jitter from sub-pixel rounding.
	if is_alive:
		var moved_px := global_position.distance_to(_last_pos)
		_moving_anim = moved_px > 0.4
		if _moving_anim:
			_walk_time += delta
	else:
		_moving_anim = false
	_last_pos = global_position
	queue_redraw()

func _input_event(_viewport: Viewport, event: InputEvent, _shape: int) -> void:
	if not is_alive:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			# Click pops the action menu — combat does NOT start until the
			# player picks "Attack" from the popup. Screen pos comes from the
			# viewport mouse position so the menu anchors under the cursor
			# regardless of camera zoom.
			Events.monster_clicked.emit(self, get_viewport().get_mouse_position())

func take_damage(amount: int) -> int:
	var dmg := maxi(1, amount - defense)
	current_hp = maxi(0, current_hp - dmg)
	_hit_flash = 0.10
	queue_redraw()
	if current_hp <= 0:
		_die()
	return dmg

func _die() -> void:
	is_alive        = false
	_regen_timer    = RESPAWN_TIME
	collision_layer = 0
	input_pickable  = false
	stop_pursuit()
	for drop: Dictionary in loot:
		_spawn_loot(drop)
	if BOOT_DROPS.has(monster_type):
		var bd := BOOT_DROPS[monster_type] as Dictionary
		if randf() < (bd["chance"] as float):
			_spawn_loot({"id": bd["id"] as String, "name": bd["name"] as String,
						 "qty": 1, "color": bd["color"] as Color})
	if GEM_DROPS.has(monster_type):
		var gd := GEM_DROPS[monster_type] as Dictionary
		if randf() < (gd["chance"] as float):
			_spawn_loot({"id": gd["id"] as String, "name": gd["name"] as String,
						 "qty": 1, "color": gd["color"] as Color})
	_roll_soul_drop()
	# Local-path gold drop (Phase 5). Server-managed monsters get a pile from
	# the server's gold_pile_spawn broadcast instead — this is only for solo /
	# offline kills where there's no server tracking. Pile spawns with no
	# pile_id so LootDrop knows to credit GameManager.gold directly on pickup.
	if gold_min > 0 and gold_max > 0:
		var amt := randi_range(gold_min, gold_max)
		if amt > 0:
			_spawn_local_gold_pile(amt)
	Events.monster_killed.emit(monster_type)
	GameManager.on_monster_killed(monster_type)
	Events.combat_ended.emit()
	queue_redraw()

## Spawns a non-server-tracked gold pile at the monster's position. Pile_id
## is empty — LootDrop interprets that as "local-only, credit gold directly
## on pickup without contacting the server."
func _spawn_local_gold_pile(amount: int) -> void:
	var ld := Area2D.new()
	ld.set_script(LootDropScript)
	var offset := Vector2(randf_range(-10.0, 10.0), randf_range(-6.0, 6.0))
	ld.global_position = global_position + offset
	get_parent().add_child(ld)
	(ld as Area2D).call("setup_gold_pile", "", amount)

func _spawn_loot(drop: Dictionary) -> void:
	var ld := Area2D.new()
	ld.set_script(LootDropScript)
	var offset := Vector2(randf_range(-14.0, 14.0), randf_range(-14.0, 14.0))
	var landing := global_position + offset
	# Spawn 18 px above the landing point and tween down with a TRANS_BOUNCE
	# curve. Items popping in flat reads as generic; the bounce makes the
	# drop feel like loot actually fell out of the corpse.
	ld.global_position = landing + Vector2(0.0, -18.0)
	get_parent().add_child(ld)
	(ld as Area2D).call("setup",
		drop["id"] as String,
		drop["name"] as String,
		drop["qty"] as int,
		drop["color"] as Color)
	var tw := ld.create_tween()
	tw.tween_property(ld, "global_position", landing, 0.40) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BOUNCE)

func _respawn() -> void:
	current_hp      = max_hp
	is_alive        = true
	collision_layer = 8
	input_pickable  = true
	_dead_t         = 0.0   # reset so next death animates fresh
	queue_redraw()

# ── Server-authoritative combat (shared HP / death / respawn) ─────────────────
## Set HP from the server's shared pool (does NOT trigger local death).
func set_server_hp(hp: int, maximum: int) -> void:
	max_hp     = maxi(1, maximum)
	current_hp = clampi(hp, 0, max_hp)
	queue_redraw()

func flash_hit() -> void:
	_hit_flash = 0.10
	queue_redraw()

## Visual death only — XP/loot are handled by World based on the server result.
## Does NOT emit combat_ended globally: each client ends its own fight when it
## notices its target died (HUD._combat_tick / Player target check), so an unrelated
## monster dying nearby never cancels your current fight.
func server_die() -> void:
	if not is_alive:
		return
	is_alive        = false
	current_hp      = 0
	collision_layer = 0
	input_pickable  = false
	stop_pursuit()
	queue_redraw()

func server_respawn() -> void:
	current_hp      = max_hp
	is_alive        = true
	collision_layer = 8
	input_pickable  = true
	queue_redraw()

## Drop this monster's loot — called only on the top-damage dealer's client.
func spawn_loot_drops() -> void:
	for drop: Dictionary in loot:
		_spawn_loot(drop)
	if BOOT_DROPS.has(monster_type):
		var bd := BOOT_DROPS[monster_type] as Dictionary
		if randf() < (bd["chance"] as float):
			_spawn_loot({"id": bd["id"] as String, "name": bd["name"] as String,
						 "qty": 1, "color": bd["color"] as Color})
	if GEM_DROPS.has(monster_type):
		var gd := GEM_DROPS[monster_type] as Dictionary
		if randf() < (gd["chance"] as float):
			_spawn_loot({"id": gd["id"] as String, "name": gd["name"] as String,
						 "qty": 1, "color": gd["color"] as Color})
	_roll_soul_drop()

## ~50% chance to drop a buriable Soul-skill item, tier picked by this monster's
## level (SOUL_DROPS). Guards drop nothing — the fight is a punishment, not a farm.
func _roll_soul_drop() -> void:
	if monster_type.begins_with("guard"):
		return
	if randf() >= SOUL_DROP_CHANCE:
		return
	for tier: Array in SOUL_DROPS:
		if level < int(tier[0]):
			_spawn_loot({"id": str(tier[1]), "name": str(tier[2]),
						 "qty": 1, "color": tier[3] as Color})
			return

# ── Drawing ───────────────────────────────────────────────────────────────────
# ── Multi-part rig (art pass v1.5.3) ─────────────────────────────────────────
# _draw() applies a whole-body transform (_body_xf: bob/sway/rot/scale/shake).
# A RIGGED monster poses each PART with its own animated sub-transform COMPOSED
# onto the body (via Transform2D multiplication for real hierarchical bones), so
# limbs/wings/tails move independently. Parts are authored in bone-LOCAL space
# (origin at the joint). Start a rigged draw normally; `_pose(local)` sets the
# compose per part; END with `_rig_end()` to restore the body transform so the
# shared hit-flash overlay in _draw() stays centred.
var _body_xf: Transform2D = Transform2D.IDENTITY

func _bone(pos: Vector2, angle: float = 0.0, scl: Vector2 = Vector2.ONE) -> Transform2D:
	return Transform2D(angle, scl, 0.0, pos)

func _pose(local: Transform2D) -> void:
	draw_set_transform_matrix(_body_xf * local)

func _rig_end() -> void:
	draw_set_transform_matrix(_body_xf)

func _draw() -> void:
	if not is_alive:
		_draw_dead()
		return
	_draw_shadow()
	# Walking animation: stronger bob + horizontal sway when moving.
	# Idle animation dispatched per `idle_style` so different creature
	# types feel distinct (a lava crawler slithers, a spirit floats, a
	# rat twitches). Wind-up telegraph adds a brief scale-up before an
	# attack lands. Death animation lives in _draw_dead.
	var bob: float
	var sway: float
	var rot: float = 0.0
	var sc: Vector2 = Vector2.ONE
	if _moving_anim:
		# Walk-cycle weight-shift: the body dips on each foot-plant (twice a
		# stride) instead of a fast ±2px sine HOP. Kept low + synced to the leg
		# sway so rigged monsters read as walking, not bouncing.
		bob  = -absf(sin(_walk_time * 4.5)) * 1.3
		sway = sin(_walk_time * 4.5) * 0.9
	else:
		match idle_style:
			"slithering":
				# Horizontal side-to-side, no vertical bob.
				bob  = 0.0
				sway = sin(_time * 3.0) * 2.5
			"floating":
				# Slow drift + faint rotation.
				bob  = sin(_time * 1.4) * 2.5
				sway = sin(_time * 0.9) * 1.5
				rot  = sin(_time * 0.7) * 0.05
			"twitching":
				# Base breathing + periodic jitter offset.
				bob  = sin(_time * 2.2) * 1.0 + _twitch_offset.y
				sway = _twitch_offset.x
			"perched":
				# Body still, no bob. Head-bob comes from per-type draw
				# reading _time if it wants.
				bob  = 0.0
				sway = 0.0
			_:  # "breathing" — the classic gentle bob.
				bob  = sin(_time * 2.2) * 1.5
				sway = 0.0
	# Attack wind-up telegraph — 0.20 s pre-attack anticipation. Melee
	# swells slightly, ranged shakes side-to-side (bow draw), magic
	# gets a pulse glow (drawn as a scale + slight lightening).
	if _atk_wind_t > 0.0:
		var t: float = clampf(_atk_wind_t / 0.20, 0.0, 1.0)
		match attack_style:
			"ranged":
				sway += sin(_atk_wind_t * 60.0) * 1.5 * t
			"magic":
				sc = Vector2.ONE * (1.0 + 0.15 * t)
			_:
				sc = Vector2.ONE * (1.0 + 0.10 * t)
	# Hit reaction — recoil shake while the damage flash is active.
	# Shake formula re-normalized for the shorter 0.10s flash window so the
	# motion still feels punchy rather than imperceptible.
	var shake := 0.0
	if _hit_flash > 0.0:
		shake = sin(_hit_flash * 120.0) * (_hit_flash / 0.10) * 3.0
	_body_xf = Transform2D(rot, sc, 0.0, Vector2(shake + sway, bob))
	draw_set_transform_matrix(_body_xf)
	_draw_outline()
	match monster_type:
		"rat":            _draw_rat()
		"plague_rat":     _draw_plague_rat()
		"skeleton":       _draw_skeleton()
		"goblin":         _draw_goblin()
		"draugr":         _draw_draugr()
		"nidhogg":        _draw_nidhogg()
		"chicken":        _draw_chicken()
		"wolf":           _draw_wolf()
		"bandit":         _draw_bandit()
		"guard":          _draw_guard("melee")
		"guard_ranger":   _draw_guard("ranged")
		"guard_magi":     _draw_guard("magic")
		"bear":           _draw_bear()
		"troll":          _draw_troll()
		"swamp_troll":    _draw_swamp_troll()
		"ice_troll":      _draw_ice_troll()
		"cave_troll":     _draw_cave_troll()
		"forest_spirit":  _draw_forest_spirit()
		"spider":         _draw_spider()
		"ice_wolf":       _draw_ice_wolf()
		"frost_giant":    _draw_frost_giant()
		"ice_draugr":     _draw_ice_draugr()
		"fire_imp":       _draw_fire_imp()
		"lava_crawler":   _draw_lava_crawler()
		"fire_giant":     _draw_fire_giant()
		"shadow_draugr":  _draw_shadow_draugr()
		"death_knight":   _draw_death_knight()
		"spectral_warrior": _draw_spectral_warrior()
		"dire_wolf":        _draw_dire_wolf()
		"elder_bear":       _draw_elder_bear()
		"ancient_troll":    _draw_ancient_troll()
		"frost_wyrm":       _draw_frost_wyrm()
		"magma_elemental":  _draw_magma_elemental()
		"shark":            _draw_shark()
		"drake":            _draw_drake()
		"wyvern":           _draw_wyvern()
	# Hover indication is delivered via self_modulate (see mouse_entered
	# callback) — no yellow halo circle. White hit-flash still draws as
	# before because it's a distinct combat signal, not a hover state.
	if _hit_flash > 0.0:
		# White flash sized to envelope the sprite — alpha tracks the timer
		# linearly so the pop fades cleanly over the 0.10s window.
		var a := clampf(_hit_flash / 0.10, 0.0, 1.0)
		draw_circle(Vector2.ZERO, _radius() + 2.0, Color(1.0, 1.0, 1.0, a * 0.85))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hp_bar()

## Ground shadow sized to the monster's actual sprite footprint instead of a
## uniform circle. Quadrupeds get a long horizontal oval, humanoids get a
## small round one, giants get a bigger round one, crawlers get a very long
## low oval. The base offset (slightly to the right + below the sprite
## origin) is preserved so the shadow still reads as "from an overhead sun".
## Types that skip the ground-shadow pass entirely. Lava-based creatures
## have their own animated ground glow that clashes with a dark ellipse.
const _NO_SHADOW_TYPES := ["lava_crawler"]

func _draw_shadow() -> void:
	if monster_type in _NO_SHADOW_TYPES:
		return
	var fp := _shadow_footprint()
	var r := _radius()
	_draw_ellipse(Vector2(3.0, r * 0.55), fp.x, fp.y,
		Color(0.02, 0.02, 0.04, 0.32))

## (rx, ry) of the shadow ellipse per monster type. ry < rx for everything
## that walks on legs (the shadow flattens to the ground); rx is wider for
## quadrupeds, crawlers, and wide creatures than for upright humanoids.
func _shadow_footprint() -> Vector2:
	match monster_type:
		"chicken":                       return Vector2(5.5, 3.0)
		"rat":                           return Vector2(11.0, 5.0)   # Norse-rat redraw is 2× the old body
		"plague_rat":                    return Vector2(16.0, 7.0)   # 1.5× mini-boss variant
		# Upright armoured humanoids — narrow footprint like a person.
		"guard", "guard_ranger", "guard_magi": return Vector2(9.0, 4.5)
		# Quadrupeds — long horizontal footprint
		"wolf", "bandit":                return Vector2(12.0, 5.0)
		"ice_wolf":                      return Vector2(13.0, 5.5)
		"dire_wolf":                     return Vector2(15.0, 6.0)
		"bear":                          return Vector2(18.0, 7.5)
		"elder_bear":                    return Vector2(20.0, 8.5)
		# Small/medium humanoids — upright, small oval
		"goblin":                        return Vector2(8.0, 4.5)
		"fire_imp":                      return Vector2(7.0, 4.0)
		"skeleton":                      return Vector2(8.5, 4.5)
		"forest_spirit":                 return Vector2(11.0, 5.5)
		# Standard humanoid armored — slightly wider
		"draugr", "ice_draugr", "shadow_draugr", "death_knight", "spectral_warrior":
			return Vector2(11.0, 5.5)
		# Giant humanoids — large round oval. Trolls bumped 1.5× for the
		# playtest fix pack; ancient troll 1.8×, variants ~1.6-1.7×.
		"troll":                         return Vector2(24.0, 11.0)
		"swamp_troll":                   return Vector2(25.5, 11.5)
		"ice_troll":                     return Vector2(27.0, 12.5)
		"cave_troll":                    return Vector2(27.0, 12.5)
		"ancient_troll":                 return Vector2(32.0, 15.0)
		"frost_giant", "fire_giant":     return Vector2(19.0, 9.0)
		# Spider — wider leggy footprint than tall
		"spider":                        return Vector2(15.0, 8.5)
		# Crawlers / serpents — very long horizontal
		"lava_crawler":                  return Vector2(45.0, 15.0)  # 2.5× per playtest fix
		"frost_wyrm":                    return Vector2(22.0, 7.0)
		# Magma elemental — round ball, near-circular shadow
		"magma_elemental":               return Vector2(14.0, 10.0)
		# Water — long silhouette, thin body
		"shark":                         return Vector2(18.0, 5.0)
		# Boss — winged dragon, very wide
		"nidhogg":                       return Vector2(125.0, 50.0)  # 5× per playtest fix
		# Slim winged dragons — wide but far smaller than Níðhöggr
		"drake":                         return Vector2(62.0, 24.0)
		"wyvern":                        return Vector2(70.0, 26.0)
		_:
			var r := _radius()
			return Vector2(r * 1.05, r * 0.55)

## Polygon-approximated ellipse — Godot 4 has no draw_ellipse primitive, and
## stacking draw_circle calls along the major axis leaves a lumpy outline.
## 18 segments is smooth enough at the rendered scale without burning the
## display list.
func _draw_ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	var n := 18
	for i in range(n):
		var a := float(i) * TAU / float(n)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)

func _draw_outline() -> void:
	draw_circle(Vector2.ZERO, _radius() + 1.8, Color(0.04, 0.04, 0.04, 0.85))

func _radius() -> float:
	match monster_type:
		"nidhogg":                    return 110.0  # 5× per playtest fix
		"frost_giant", "fire_giant":  return 22.0
		"draugr":                     return 16.0
		"lava_crawler":               return 40.0  # 2.5× per playtest fix
		"bear":                       return 18.0
		# Trolls bumped 1.5-1.8× per the playtest ask.
		"troll":                      return 27.0
		"swamp_troll":                return 29.0
		"ice_troll", "cave_troll":    return 31.0
		"goblin", "skeleton":         return 13.0
		"forest_spirit":              return 13.0
		"ice_wolf":                   return 13.0
		"spider":                     return 14.0
		"ice_draugr", "shadow_draugr", "death_knight": return 15.0
		"spectral_warrior":           return 14.0
		"shark":                      return 18.0
		"wolf", "bandit":             return 12.0
		"guard", "guard_ranger", "guard_magi": return 13.0
		"fire_imp":                   return 10.0
		"chicken":                    return 7.0
		"rat":                        return 12.0   # Norse-rat redraw
		"plague_rat":                 return 17.0   # 1.5× mini-boss
		"dire_wolf":                  return 14.0
		"elder_bear":                 return 20.0
		"ancient_troll":              return 36.0
		"frost_wyrm":                 return 18.0
		"magma_elemental":            return 18.0
		"drake":                      return 36.0
		"wyvern":                     return 40.0
		_:                            return 10.0

func _draw_dead() -> void:
	# Death animation — 0.6 s fall + fade. `_dead_t` accumulates in
	# _process while `is_alive == false`. After the animation duration
	# the corpse settles at the final rotation + faded alpha until
	# _respawn resets `_dead_t = 0`. Was: static grey circle.
	var t: float = clampf(_dead_t / _DEATH_ANIM_SEC, 0.0, 1.0)
	var r_final: float = PI * 0.5
	var alpha: float = lerpf(0.85, 0.30, t)
	var y_drop: float = lerpf(0.0, 4.0, t)
	draw_set_transform(Vector2(0.0, y_drop), r_final * t, Vector2.ONE)
	draw_circle(Vector2.ZERO, _radius(), Color(0.2, 0.2, 0.2, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Triggered by an incoming attack event so the sprite plays its 0.20 s
## anticipation pose before the damage broadcast lands. Server sends a
## `monster_attack_wind_up` prelude for ranged/magic mobs; melee ones
## use it too so a lunge feels weighty.
func play_attack_wind_up() -> void:
	_atk_wind_t = 0.20

func _draw_hp_bar() -> void:
	var ratio := float(current_hp) / float(max_hp)
	var bw    := _radius() * 2.2
	var bx    := -bw * 0.5
	var by    := -_radius() - 9.0
	draw_rect(Rect2(bx, by, bw, 4), Color(0.15, 0.15, 0.15, 0.85))
	draw_rect(Rect2(bx, by, bw * ratio, 4), Color(0.85 - 0.65 * (1.0 - ratio), 0.7 * ratio, 0.1, 0.9))
	_draw_name_label(by)

func _draw_name_label(hp_bar_y: float) -> void:
	var player_combat_lv := _player_combat_level()
	var diff := level - player_combat_lv
	var col: Color
	if diff <= -10:
		col = Color(0.40, 0.40, 0.40)   # grey — trivial
	elif diff <= -5:
		col = Color(0.20, 0.85, 0.20)   # green — easy
	elif diff <= 4:
		col = Color(0.90, 0.90, 0.90)   # white — even
	elif diff <= 9:
		col = Color(0.95, 0.80, 0.10)   # yellow — tough
	else:
		col = Color(0.95, 0.20, 0.15)   # red — dangerous
	# Subtle by default (15%), full opacity on hover. Background fades with
	# the same factor so the pill never floats independently of the text.
	var alpha := 1.0 if is_hovered else 0.15
	col.a = alpha
	var lbl := "%s [Lv %d]" % [display_name, level]
	var fs   := 8
	var approx_w := lbl.length() * (fs - 1)
	var lx   := -approx_w * 0.5
	var ly   := hp_bar_y - fs - 3
	# Rounded pill background with minimal padding (3px horizontal, 1px vertical).
	var pad_x := 3.0
	var pad_y := 1.0
	var bg := Rect2(lx - pad_x, ly - pad_y,
		float(approx_w) + pad_x * 2.0, float(fs) + pad_y * 2.0)
	_draw_rounded_rect(bg, 2.5, Color(0.0, 0.0, 0.0, alpha * 0.80))
	draw_string(ThemeDB.fallback_font, Vector2(lx, ly + fs - 2), lbl,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

## Draws a rounded rect by overlapping two rects (cross-shape) and filling
## the four corners with circles. Cheaper than a polygon for the small
## sizes we use here, and works at any opacity.
func _draw_rounded_rect(rect: Rect2, r: float, col: Color) -> void:
	var p := rect.position
	var s := rect.size
	# Horizontal band (between the rounded sides) and vertical band fill
	# the body without writing into the corners.
	draw_rect(Rect2(p.x + r, p.y, s.x - r * 2.0, s.y), col)
	draw_rect(Rect2(p.x, p.y + r, s.x, s.y - r * 2.0), col)
	# Corner discs.
	draw_circle(p + Vector2(r, r),                   r, col)
	draw_circle(p + Vector2(s.x - r, r),             r, col)
	draw_circle(p + Vector2(r, s.y - r),             r, col)
	draw_circle(p + Vector2(s.x - r, s.y - r),       r, col)

func _player_combat_level() -> int:
	var atk := GameManager.get_skill_level("melee")
	var def := GameManager.get_skill_level("defense")
	var vit := GameManager.get_skill_level("vitality")
	return maxi(1, floori((atk + def + vit) / 3.0))

## Parametric rat draw so `_draw_rat` and `_draw_plague_rat` share silhouette
## work. Big matted "Norse village" rat: torn ear, longer skinny tail, visible
## teeth, beady eyes with a red glint. `sc` scales the whole thing; `fur` /
## `belly` / `eye_glint` swap the palette; `sickly` adds plague-only overlays
## (tumor lumps + foam at the mouth + pus-yellow patches).
func _draw_rat_body(sc: float, fur: Color, belly: Color, eye_glint: Color, sickly: bool) -> void:
	var fur_l := fur.lightened(0.10)
	var fur_d := fur.darkened(0.28)

	# Longer skinny pink tail — segmented so it reads at a distance.
	var tail := Color(0.82, 0.55, 0.55)
	draw_line(Vector2(8, 4) * sc, Vector2(15, 9) * sc, tail, 1.6 * sc)
	draw_line(Vector2(15, 9) * sc, Vector2(20, 15) * sc, tail, 1.4 * sc)
	draw_line(Vector2(20, 15) * sc, Vector2(23, 22) * sc, tail, 1.2 * sc)
	draw_line(Vector2(23, 22) * sc, Vector2(22, 28) * sc, tail, 1.0 * sc)

	# Bigger body — matted brown-grey fur, 2× base rat proportions.
	draw_circle(Vector2(0, 4) * sc, 11.0 * sc, fur_d)
	draw_circle(Vector2(0, 2) * sc, 10.0 * sc, fur)
	draw_circle(Vector2(-2, 0) * sc, 8.0 * sc, fur_l)
	draw_circle(Vector2(0, -6) * sc, 7.0 * sc, fur)
	draw_circle(Vector2(1, -7) * sc, 4.5 * sc, fur_l)

	# Matted-fur texture — longer, more chaotic strokes than the old draw.
	var fc := fur_d.darkened(0.10)
	for stroke in [
			[Vector2(-8, 3), Vector2(-5, -1)],
			[Vector2(-3, 5), Vector2( 0,  1)],
			[Vector2( 3, 4), Vector2( 5,  0)],
			[Vector2(-4, -1), Vector2(-2, -5)],
			[Vector2( 2, -2), Vector2( 4, -6)],
			[Vector2(-7, -3), Vector2(-9,  1)],
			[Vector2( 7, -2), Vector2( 9,  1)],
			[Vector2(-2, 7), Vector2( 1,  4)]]:
		draw_line((stroke[0] as Vector2) * sc, (stroke[1] as Vector2) * sc, fc, 1.0 * sc)

	# Belly highlight
	draw_circle(Vector2(-1, 4) * sc, 5.5 * sc, belly)

	# Ears — LEFT ear intact, RIGHT ear torn (nick out of the top).
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, -10) * sc, Vector2(-10, -17) * sc, Vector2(-3, -13) * sc]), fur_d)
	draw_circle(Vector2(-6, -13) * sc, 2.2 * sc, Color(0.72, 0.48, 0.48))
	# Torn right ear — two smaller triangles with a gap for the "bite" nick.
	draw_colored_polygon(PackedVector2Array([
		Vector2(5, -10) * sc, Vector2(7, -15) * sc, Vector2(4, -12) * sc]), fur_d)
	draw_colored_polygon(PackedVector2Array([
		Vector2(7, -13) * sc, Vector2(9, -15) * sc, Vector2(8, -11) * sc]), fur_d)

	# Beady dark eyes with a red glint — sinister, not cute.
	draw_circle(Vector2(-2.5, -6) * sc, 1.8 * sc, Color(0.04, 0.04, 0.05))
	draw_circle(Vector2( 2.5, -6) * sc, 1.8 * sc, Color(0.04, 0.04, 0.05))
	draw_circle(Vector2(-2.0, -6.4) * sc, 0.7 * sc, eye_glint)
	draw_circle(Vector2( 3.0, -6.4) * sc, 0.7 * sc, eye_glint)

	# Snout + open mouth showing sharp teeth. Slight downturn shows aggression.
	draw_circle(Vector2(0, -2) * sc, 1.6 * sc, Color(0.85, 0.50, 0.50))  # nose
	draw_line(Vector2(-2, 1) * sc, Vector2(2, 1) * sc, Color(0.15, 0.05, 0.08), 1.0 * sc)  # mouth line
	# Two front teeth
	draw_colored_polygon(PackedVector2Array([
		Vector2(-1.4, 1) * sc, Vector2(-0.4, 1) * sc, Vector2(-0.9, 3) * sc]),
		Color(0.98, 0.95, 0.85))
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.4, 1) * sc, Vector2(1.4, 1) * sc, Vector2(0.9, 3) * sc]),
		Color(0.98, 0.95, 0.85))

	# Whiskers
	var wh := Color(0.85, 0.82, 0.78, 0.70)
	draw_line(Vector2(-1, -3) * sc, Vector2(-13, -5) * sc, wh, 0.8 * sc)
	draw_line(Vector2(-1, -1) * sc, Vector2(-13, 0) * sc, wh, 0.8 * sc)
	draw_line(Vector2(1, -3) * sc, Vector2(13, -5) * sc, wh, 0.8 * sc)
	draw_line(Vector2(1, -1) * sc, Vector2(13, 0) * sc, wh, 0.8 * sc)

	# Plague overlays — tumor lumps, pus-yellow patches, foaming maw.
	if sickly:
		var pus := Color(0.82, 0.75, 0.20)
		draw_circle(Vector2(-4, -2) * sc, 2.6 * sc, pus)
		draw_circle(Vector2( 3,  0) * sc, 2.2 * sc, pus)
		draw_circle(Vector2( 6, -4) * sc, 1.6 * sc, pus)
		# Tumor lumps on the back — darker green-brown bulges.
		var tumor := Color(0.35, 0.32, 0.14)
		draw_circle(Vector2(-3, -3) * sc, 2.2 * sc, tumor)
		draw_circle(Vector2( 2, -4) * sc, 1.8 * sc, tumor)
		# Foam at the mouth — pulsing so the disease reads as active.
		var foam_pulse: float = 0.6 + 0.4 * sin(_time * 4.0)
		var foam := Color(0.95, 0.93, 0.85, foam_pulse)
		draw_circle(Vector2(-1.5, 3) * sc, 0.9 * sc, foam)
		draw_circle(Vector2( 1.5, 3) * sc, 0.9 * sc, foam)
		draw_circle(Vector2( 0.0, 4) * sc, 0.7 * sc, foam)

func _draw_rat() -> void:
	# Base Giant Rat — Norse village nasty. Sized ~1× (visual mass already
	# doubled inside `_draw_rat_body` vs the old draw). Fur is warm brown-grey
	# with a subtle red eye glint.
	_draw_rat_body(1.0,
		Color(0.55, 0.38, 0.22),
		Color(0.72, 0.58, 0.40, 0.45),
		Color(0.85, 0.15, 0.10),
		false)

func _draw_plague_rat() -> void:
	# Plague Rat mini-boss — 1.5× base, sickly greenish-brown palette + pus
	# patches + tumor lumps + foaming maw. Eye glint pushed to a hotter red.
	_draw_rat_body(1.5,
		Color(0.42, 0.44, 0.24),
		Color(0.60, 0.62, 0.32, 0.50),
		Color(1.00, 0.20, 0.10),
		true)

## RIGGED (art pass v1.5.3) — articulated skeleton: hierarchical 2-segment legs
## + arms, a breathing ribcage, and a bobbing skull. Legs stride and arms
## counter-swing on `_walk_time`; everything idles on a gentle `_time` breathe.
func _draw_skeleton() -> void:
	var c  := Color(0.90, 0.88, 0.74)
	var cd := Color(0.60, 0.58, 0.44)
	var dark := Color(0.05, 0.05, 0.05)
	var moving := _moving_anim
	var gait := _walk_time * 8.0
	var amp := 0.55 if moving else 0.0
	var breathe := 1.0 + sin(_time * 2.4) * 0.05
	# ── Legs (hierarchical: thigh → shin), opposite phase ──
	_skel_leg(Vector2(-2, 7), sin(gait) * amp, c, cd)
	_skel_leg(Vector2(2, 7), sin(gait + PI) * amp, c, cd)
	# Tattered waist cloth (sways a touch with the gait).
	_pose(_bone(Vector2(0, 6), sin(gait) * amp * 0.15))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-5, 0), Vector2(5, 0), Vector2(4, 10), Vector2(-4, 10)]),
		Color(0.38, 0.30, 0.16, 0.60))
	# ── Ribcage torso (breathes) ──
	_pose(_bone(Vector2(0, 0), 0.0, Vector2(1.0, breathe)))
	draw_rect(Rect2(-3, -7, 6, 14), c)
	for ri in range(4):
		draw_line(Vector2(-3, -5.0 + ri * 3.0), Vector2(3, -5.0 + ri * 3.0), cd, 1.0)
	draw_line(Vector2(-1, -5), Vector2(1, -2), cd.darkened(0.3), 1.0)
	# ── Arms (counter-swing to the legs); right hand holds a rusty sword ──
	_skel_arm(Vector2(-3, -5), sin(gait + PI) * amp * 0.7, c, cd, false)
	_skel_arm(Vector2(3, -5), sin(gait) * amp * 0.7, c, cd, true)
	# ── Skull (bobs with the gait / breathes when idle) ──
	var head_a := sin(gait) * amp * 0.08 + sin(_time * 1.3) * 0.02
	_pose(_bone(Vector2(0, -14 - (sin(gait * 0.5) * amp)), head_a))
	draw_circle(Vector2(0, 0), 7, c)
	draw_circle(Vector2(0, 0), 5, c.lightened(0.05))
	draw_circle(Vector2(-2, -3), 1.8, c.lightened(0.25))
	draw_circle(Vector2(-2.5, 0), 2.0, dark)
	draw_circle(Vector2(2.5, 0), 2.0, dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-1, 4), Vector2(1, 4), Vector2(0, 6)]), dark)
	for ti in range(3):
		draw_rect(Rect2(float(-3 + ti * 2), 6.0, 1.0, 2.0), c)
	_rig_end()

## Hierarchical skeletal leg: thigh swings from the hip by `a`, shin bends the
## opposite way (composed onto the thigh bone), foot at the end.
func _skel_leg(hip: Vector2, a: float, c: Color, cd: Color) -> void:
	var thigh := _bone(hip, a)
	_pose(thigh)
	draw_line(Vector2(0, 0), Vector2(0, 6), c, 2.5)   # thigh
	draw_circle(Vector2(0, 6), 1.4, cd)                # knee
	var shin := thigh * _bone(Vector2(0, 6), -a * 0.5)
	_pose(shin)
	draw_line(Vector2(0, 0), Vector2(0, 6), c, 2.0)   # shin
	draw_circle(Vector2(0, 6), 2.0, cd)                # foot
	draw_circle(Vector2(0, 6), 0.9, c.lightened(0.2))

## Skeletal arm: upper swings from the shoulder; `sword` adds a rusty blade.
func _skel_arm(shoulder: Vector2, a: float, c: Color, cd: Color, sword: bool) -> void:
	var side := signf(shoulder.x) if shoulder.x != 0.0 else 1.0
	_pose(_bone(shoulder, a))
	draw_line(Vector2(0, 0), Vector2(side * 6.0, 7.0), c, 2.0)
	draw_circle(Vector2(side * 6.0, 7.0), 1.6, cd)
	if sword:
		# Blade points down past the hand.
		draw_rect(Rect2(side * 5.0, 7.0, 2.5, 13.0), Color(0.62, 0.50, 0.38))
		draw_rect(Rect2(side * 3.0, 6.0, 6.0, 2.0), cd)
		draw_rect(Rect2(side * 5.8, 7.0, 0.9, 13.0), Color(0.74, 0.60, 0.44))

## RIGGED (V1.5.4) — legs stride, arms swing (the club rides the right hand),
## the body + head breathe.
func _draw_goblin() -> void:
	var c  := Color(0.22, 0.58, 0.18)
	var cd := c.darkened(0.35)
	var gait := _walk_time * 8.0
	var amp := 0.5 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 2.2) * 0.05
	# Legs (opposite phase).
	_pose(_bone(Vector2(-3, 14), a1)); draw_line(Vector2.ZERO, Vector2(0, 8), c, 2.5)
	draw_circle(Vector2(0, 8), 1.6, cd)
	_pose(_bone(Vector2(3, 14), a2)); draw_line(Vector2.ZERO, Vector2(0, 8), c, 2.5)
	draw_circle(Vector2(0, 8), 1.6, cd)
	# Left arm (behind, swings opposite its leg).
	_pose(_bone(Vector2(-6, 0), a2 * 0.8)); draw_line(Vector2.ZERO, Vector2(-6, 6), c, 2.5)
	# Body + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_circle(Vector2(0, 4), 10, c)
	draw_circle(Vector2(-2, 2), 7, c.lightened(0.08))
	draw_circle(Vector2(0, 7), 5, c.darkened(0.12))
	draw_rect(Rect2(-6, -3, 12, 10), Color(0.28, 0.18, 0.08))
	draw_rect(Rect2(-4, -2, 8, 7), Color(0.35, 0.22, 0.10))
	draw_line(Vector2(0, -3), Vector2(0, 7), Color(0.20, 0.12, 0.04, 0.65), 1.0)
	draw_circle(Vector2(-4, -1), 1.2, Color(0.65, 0.50, 0.18))
	draw_circle(Vector2( 4, -1), 1.2, Color(0.65, 0.50, 0.18))
	draw_circle(Vector2(-4,  4), 1.2, Color(0.65, 0.50, 0.18))
	draw_circle(Vector2( 4,  4), 1.2, Color(0.65, 0.50, 0.18))
	draw_rect(Rect2(-6, 6, 12, 2), Color(0.35, 0.22, 0.08))
	draw_rect(Rect2(-2, 5, 4, 4), Color(0.60, 0.45, 0.15))
	draw_circle(Vector2(0, -8), 8, c)
	draw_circle(Vector2(1, -9), 6, c.lightened(0.05))
	draw_circle(Vector2(-2, -12), 2.5, c.lightened(0.18))
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -10), Vector2(-14, -16), Vector2(-6, -6)]), c)
	draw_colored_polygon(PackedVector2Array([Vector2(8, -10), Vector2(14, -16), Vector2(6, -6)]), c)
	draw_line(Vector2(-9, -11), Vector2(-11, -14), c.darkened(0.25), 0.8)
	draw_line(Vector2( 9, -11), Vector2( 11, -14), c.darkened(0.25), 0.8)
	draw_circle(Vector2(-3, -9), 2, Color(0.88, 0.10, 0.10))
	draw_circle(Vector2(3, -9), 2, Color(0.88, 0.10, 0.10))
	draw_circle(Vector2(-2.5, -9.5), 0.8, Color(1, 1, 1, 0.5))
	draw_circle(Vector2( 3.5, -9.5), 0.8, Color(1, 1, 1, 0.5))
	draw_rect(Rect2(-3, -5, 6, 2), cd)
	draw_circle(Vector2(2.0, -6.0), 1.2, c.darkened(0.2))
	# Right arm + club (swings with the left leg).
	_pose(_bone(Vector2(6, 0), a1 * 0.8))
	draw_line(Vector2.ZERO, Vector2(6, 4), c, 2.5)
	draw_rect(Rect2(5, 0, 4, 12), Color(0.45, 0.28, 0.08))
	draw_rect(Rect2(3, 0, 8, 5), Color(0.50, 0.32, 0.10))
	draw_line(Vector2(7, 1), Vector2(7, 11), Color(0.30, 0.18, 0.04, 0.50), 1.0)
	_rig_end()

## RIGGED (V1.5.4) — legs stride, arms swing (shield on the left, glowing sword
## on the right), armoured torso + helm breathe. Frost aura stays static.
func _draw_draugr() -> void:
	var c  := Color(0.30, 0.35, 0.55)
	var cl := c.lightened(0.25)
	var fr := Color(0.55, 0.80, 1.00, 0.30)  # frost
	var gait := _walk_time * 7.0
	var amp := 0.42 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 2.0) * 0.04
	# Frost aura (static, under the body transform).
	draw_circle(Vector2(0, 0), 20.0, Color(0.55, 0.80, 1.0, 0.10))
	# Legs (opposite phase).
	_pose(_bone(Vector2(-5, 13), a1)); draw_line(Vector2.ZERO, Vector2(0, 11), c, 3.0)
	_pose(_bone(Vector2(5, 13), a2)); draw_line(Vector2.ZERO, Vector2(0, 11), c, 3.0)
	# Left arm + shield (swings opposite its leg).
	_pose(_bone(Vector2(-8, -3), a2 * 0.7))
	draw_line(Vector2.ZERO, Vector2(-6, 9), c, 3.0)
	draw_circle(Vector2(-6, 7), 6.0, cl)
	draw_circle(Vector2(-6, 7), 4.0, c)
	draw_circle(Vector2(-6, 7), 1.5, Color(0.85, 0.75, 0.25))
	# Torso + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_rect(Rect2(-8, -5, 16, 18), c)
	draw_rect(Rect2(-6, -4, 12, 14), cl.darkened(0.2))
	draw_line(Vector2(-4, 0), Vector2(4, 0), fr, 1.5)
	draw_line(Vector2(0, -4), Vector2(0, 4), fr, 1.5)
	draw_line(Vector2(-3, -3), Vector2(3, 3), fr, 1.0)
	draw_circle(Vector2(0, -12), 9, c)
	draw_rect(Rect2(-8, -22, 16, 12), cl)
	draw_rect(Rect2(-6, -21, 12, 3), c.lightened(0.35))
	draw_rect(Rect2(-1, -22, 2, 12), c.lightened(0.35))
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -18), Vector2(-13, -12), Vector2(-4, -12)]), cl)
	draw_colored_polygon(PackedVector2Array([Vector2(8, -18), Vector2(13, -12), Vector2(4, -12)]), cl)
	# Right arm + glowing sword (swings with the left leg).
	_pose(_bone(Vector2(8, -3), a1 * 0.7))
	draw_line(Vector2.ZERO, Vector2(10, 1), c, 3.0)
	draw_line(Vector2(10, 1), Vector2(10, 13), cl, 1.5)
	draw_rect(Rect2(9, -9, 3, 14), Color(0.58, 0.62, 0.80))
	draw_rect(Rect2(7, -9, 7, 2), Color(0.70, 0.65, 0.45))
	draw_line(Vector2(10, -9), Vector2(10, -17), Color(0.70, 0.85, 1.0, 0.60), 1.5)
	_rig_end()
	# Frost crystals on armour
	var frost := Color(0.70, 0.90, 1.0, 0.55)
	for fi in range(4):
		var fx := -6.0 + float(fi) * 4.0
		var fy := -3.0 + float(fi % 2) * 3.0
		draw_line(Vector2(fx, fy - 3.0), Vector2(fx, fy + 3.0), frost, 1.0)
		draw_line(Vector2(fx - 2.0, fy), Vector2(fx + 2.0, fy), frost, 1.0)
	# Icy breath puff
	draw_circle(Vector2(0, -4), 3.5, Color(0.55, 0.80, 1.0, 0.20))
	# Glowing red eyes
	draw_circle(Vector2(-3, -13), 2.5, Color(0.95, 0.18, 0.05))
	draw_circle(Vector2(3, -13), 2.5, Color(0.95, 0.18, 0.05))
	draw_circle(Vector2(-3, -13), 1.0, Color(1, 0.75, 0.20, 0.80))
	draw_circle(Vector2(3, -13), 1.0, Color(1, 0.75, 0.20, 0.80))
	# Helmet shine
	draw_rect(Rect2(-5, -22, 10, 2), Color(0.88, 0.90, 0.95, 0.55))

## RIGGED + HD (art pass V1.5.5) — Níðhöggr, the endgame ancient wyrm. Wings
## beat, a 6-segment tail whips, the horned head sways on its neck, and the
## scaled body breathes. Kept CHUNKY/heavy per the dragon-family decision (the
## slim drake/wyvern are separate types).
func _draw_nidhogg() -> void:
	var sc := 5.0
	var scale_d := Color(0.08, 0.32, 0.19)
	var scale_m := Color(0.14, 0.50, 0.29)
	var scale_l := Color(0.26, 0.68, 0.42)
	var belly   := Color(0.52, 0.60, 0.30)
	var horn    := Color(0.86, 0.82, 0.58)
	var spike   := Color(0.92, 0.80, 0.24)
	var mem     := Color(0.16, 0.34, 0.22)
	var mem_l   := Color(0.28, 0.16, 0.14)   # reddish membrane between fingers
	var ember   := Color(1.00, 0.55, 0.08)
	var eye     := Color(1.00, 0.85, 0.15)
	var moving := _moving_anim
	var flap := sin(_time * (3.0 if moving else 1.5)) * 7.0 * sc   # wing-tip travel
	var breathe := 1.0 + sin(_time * 1.6) * 0.04
	var tail_ph := _time * 1.5 + (_walk_time * 2.0 if moving else 0.0)
	var head_sway := sin(_time * 1.1) * 0.06
	var pulse := 0.7 + 0.3 * sin(_time * 3.0)

	# ── Wings (behind everything) — membrane billows with `flap` ──
	_dragon_wing(-1.0, flap, sc, mem, mem_l, horn, scale_l)
	_dragon_wing( 1.0, flap, sc, mem, mem_l, horn, scale_l)
	# ── Tail (curling, behind body) ──
	_dragon_tail(Vector2(0, 15) * sc, sc, tail_ph, scale_m, scale_d, spike)
	# ── Body (breathes) ──
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_circle(Vector2(0, 0), 20.0 * sc, scale_d)
	draw_circle(Vector2(0, -2), 17.0 * sc, scale_m)
	# Belly plates (lower band).
	for bi in range(4):
		draw_arc(Vector2(0, (3.0 + float(bi) * 3.0) * sc), (12.0 - float(bi) * 2.0) * sc,
			0.35, PI - 0.35, 10, belly, 1.6 * sc)
	# Overlapping dorsal scales.
	for si in range(4):
		for sj in range(3):
			draw_arc(Vector2((-9.0 + sj * 9.0) * sc, (-8.0 + si * 5.0) * sc),
				4.5 * sc, PI, TAU, 6, scale_l, 1.2 * sc)
	# Spine ridge spikes.
	for spi in range(5):
		var spx := (-8.0 + spi * 4.0) * sc
		draw_colored_polygon(PackedVector2Array([
			Vector2(spx - 2.0 * sc, -16.0 * sc), Vector2(spx + 2.0 * sc, -16.0 * sc),
			Vector2(spx, -25.0 * sc)]), spike)
	# ── Front legs with claws (step in opposite phase when moving) ──
	var lstep := sin(_walk_time * 5.0) * (0.45 if moving else 0.0)
	_dragon_leg(Vector2(-11, 8) * sc, sc, scale_d, horn,  lstep)
	_dragon_leg(Vector2( 11, 8) * sc, sc, scale_d, horn, -lstep)
	# ── Neck + HD head (front, sways) ──
	var head_xf := _bone(Vector2(0, -8) * sc, head_sway)
	# Tapered neck under the head.
	_pose(head_xf)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-7 * sc, 8 * sc), Vector2(7 * sc, 8 * sc),
		Vector2(5 * sc, -2 * sc), Vector2(-5 * sc, -2 * sc)]), scale_m)
	_dragon_head(head_xf, sc, scale_m, scale_l, horn, spike, eye, ember, pulse)
	_rig_end()

## HD dragon head, posed at `base_xf` (origin at neck-top, snout points up/-y).
## `sc` is baked into the pose transform so local coords + line widths scale
## together (GDScript can't scalar-multiply a PackedVector2Array).
func _dragon_head(base_xf: Transform2D, sc: float, skin: Color, skin_l: Color,
		horn: Color, spike: Color, eye: Color, ember: Color, pulse: float) -> void:
	_pose(base_xf * _bone(Vector2.ZERO, 0.0, Vector2(sc, sc)))
	# Elongated skull (wide at the back, narrowing to the snout).
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 4), Vector2(-9, -3), Vector2(-5, -10), Vector2(-2.5, -14),
		Vector2(2.5, -14), Vector2(5, -10), Vector2(9, -3), Vector2(8, 4)]), skin)
	# Brow ridge + cheek scales (lighter).
	draw_arc(Vector2(0, -6), 7.0, PI + 0.4, TAU - 0.4, 10, skin_l, 1.4)
	# Back-swept horns — 2 large + 2 small.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, -2), Vector2(-15, -14), Vector2(-11, -1)]), horn)
	draw_colored_polygon(PackedVector2Array([
		Vector2(6, -2), Vector2(15, -14), Vector2(11, -1)]), horn)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4, -6), Vector2(-9, -13), Vector2(-3, -9)]), horn.darkened(0.1))
	draw_colored_polygon(PackedVector2Array([
		Vector2(4, -6), Vector2(9, -13), Vector2(3, -9)]), horn.darkened(0.1))
	# Cheek frill spikes.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 2), Vector2(-13, 4), Vector2(-8, -1)]), spike)
	draw_colored_polygon(PackedVector2Array([
		Vector2(8, 2), Vector2(13, 4), Vector2(8, -1)]), spike)
	# Lower jaw, slightly open, with a fiery maw glowing between the teeth.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4, -13), Vector2(4, -13), Vector2(3, -18), Vector2(-3, -18)]),
		skin.darkened(0.15))
	draw_circle(Vector2(0, -13), 3.4, Color(ember.r, ember.g, ember.b, 0.55 * pulse))
	draw_circle(Vector2(0, -13), 1.8, Color(1.0, 0.85, 0.30, 0.7 * pulse))
	for ti in range(3):   # upper teeth
		draw_colored_polygon(PackedVector2Array([
			Vector2(-3.0 + ti * 3.0, -12), Vector2(-2.0 + ti * 3.0, -12),
			Vector2(-2.5 + ti * 3.0, -14.5)]), Color(0.95, 0.93, 0.82))
	# Nostrils with an ember wisp.
	draw_circle(Vector2(-2, -12), 1.0, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2( 2, -12), 1.0, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(-2, -14), 1.2, Color(ember.r, ember.g, ember.b, 0.5 * pulse))
	# Slit-pupil glowing eyes under a heavy brow.
	for s in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(s * 3.0 - 2.0, -6), Vector2(s * 3.0 + 2.0, -6),
			Vector2(s * 3.0 + 1.5, -3), Vector2(s * 3.0 - 1.5, -3)]), eye)
		draw_line(Vector2(s * 3.0, -6.5), Vector2(s * 3.0, -2.5),
			Color(0.15, 0.05, 0.0), 0.8)   # vertical slit pupil
		draw_line(Vector2(s * 5.0, -8), Vector2(s * 1.5, -7),
			skin.darkened(0.25), 1.2)      # brow

## HD flapping wing. `xdir` ±1 selects the side; the membrane billows by `flap`.
func _dragon_wing(xdir: float, flap: float, sc: float, mem: Color, mem_l: Color,
		bone_c: Color, vein_c: Color) -> void:
	var root := Vector2(13.0 * xdir, -2.0) * sc
	var lift := Vector2(0, -flap)
	var wrist := Vector2(30.0 * xdir, -15.0) * sc + lift
	var f1 := Vector2(36.0 * xdir, -21.0) * sc + lift * 1.25
	var f2 := Vector2(35.0 * xdir, -6.0) * sc + lift * 0.85
	var f3 := Vector2(29.0 * xdir, 6.0) * sc + lift * 0.5
	var f4 := Vector2(19.0 * xdir, 11.0) * sc + lift * 0.25
	draw_colored_polygon(PackedVector2Array([root, wrist, f1, f2, f3, f4]), mem)
	# Reddish membrane webs between the finger struts.
	draw_colored_polygon(PackedVector2Array([wrist, f1, f2]), mem_l.lerp(mem, 0.4))
	draw_colored_polygon(PackedVector2Array([root, f3, f4]), mem_l.lerp(mem, 0.55))
	# Finger struts + arm bone.
	draw_line(root, wrist, bone_c, 1.7 * sc)
	for tip in [f1, f2, f3, f4]:
		draw_line(wrist, tip, bone_c, 1.1 * sc)
	# Wrist claw (leading edge).
	draw_colored_polygon(PackedVector2Array([
		wrist, wrist + Vector2(4.0 * xdir, -6.0) * sc, wrist + Vector2(xdir, -1.0) * sc]),
		bone_c)
	# Membrane veins.
	draw_line(root, f4, vein_c, 0.7 * sc)
	draw_line(root, f3, vein_c, 0.6 * sc)

## Curling multi-segment tail rooted at `root`, whipping on `phase`.
func _dragon_tail(root: Vector2, sc: float, phase: float,
		seg_c: Color, seg_d: Color, spike: Color) -> void:
	var seg_len := 7.0 * sc
	var xf := _bone(root)
	for i in range(6):
		var ang := sin(phase - float(i) * 0.7) * 0.4
		xf = xf * _bone(Vector2.ZERO, ang)
		_pose(xf)
		var w := maxf(1.0, 5.5 - float(i) * 0.8) * sc
		draw_colored_polygon(PackedVector2Array([
			Vector2(-w, 0), Vector2(w, 0),
			Vector2(w * 0.85, seg_len), Vector2(-w * 0.85, seg_len)]), seg_c)
		draw_line(Vector2(0, 0), Vector2(0, seg_len), seg_d, 0.8 * sc)
		draw_colored_polygon(PackedVector2Array([
			Vector2(-1.2 * sc, 0), Vector2(1.2 * sc, 0), Vector2(0, -4.0 * sc)]), spike)
		xf = xf * _bone(Vector2(0, seg_len))
	# Bladed spade tip.
	_pose(xf)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4.5 * sc, 0), Vector2(4.5 * sc, 0), Vector2(0, 10.0 * sc)]), spike)

## A clawed front leg swinging from the hip by `step` (0 when idle).
func _dragon_leg(hip: Vector2, sc: float, col: Color, claw: Color, step: float) -> void:
	_pose(_bone(hip, step))
	draw_line(Vector2(0, 0), Vector2(0, 8.0 * sc), col, 3.5 * sc)
	var foot := Vector2(0, 8.0 * sc)
	for ci in range(3):
		draw_line(foot, foot + Vector2((-3.0 + float(ci) * 3.0) * sc, 4.0 * sc), claw, 1.2 * sc)

## RIGGED (V1.5.4) — the slim dragon family (drake / wyvern). Same rig helpers
## as Níðhöggr but a leaner build: smaller body, longer neck, stepping legs, and
## a `wing_scale` that lets the wyvern beat bigger wings than the drake.
func _draw_slim_dragon(sc: float, scale_d: Color, scale_m: Color, scale_l: Color,
		belly: Color, horn: Color, spike: Color, mem: Color, mem_l: Color,
		ember: Color, eye: Color, wing_scale: float) -> void:
	var moving := _moving_anim
	var flap := sin(_time * (3.2 if moving else 1.6)) * 6.0 * sc * wing_scale
	var breathe := 1.0 + sin(_time * 1.7) * 0.045
	var tail_ph := _time * 1.7 + (_walk_time * 2.0 if moving else 0.0)
	var head_sway := sin(_time * 1.2) * 0.07
	var pulse := 0.7 + 0.3 * sin(_time * 3.2)
	# Wings (behind), scaled a touch smaller than the body.
	_dragon_wing(-1.0, flap, sc * 0.82, mem, mem_l, horn, scale_l)
	_dragon_wing( 1.0, flap, sc * 0.82, mem, mem_l, horn, scale_l)
	# Slimmer curling tail.
	_dragon_tail(Vector2(0, 11) * sc, sc * 0.8, tail_ph, scale_m, scale_d, spike)
	# Lean body (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_circle(Vector2(0, 0), 14.0 * sc, scale_d)
	draw_circle(Vector2(0, -2), 11.0 * sc, scale_m)
	for bi in range(3):
		draw_arc(Vector2(0, (2.0 + float(bi) * 3.0) * sc), (8.0 - float(bi) * 1.6) * sc,
			0.4, PI - 0.4, 8, belly, 1.3 * sc)
	for si in range(3):
		draw_arc(Vector2((-6.0 + si * 6.0) * sc, -6.0 * sc), 3.6 * sc, PI, TAU, 6, scale_l, 1.0 * sc)
	for spi in range(4):
		var spx := (-6.0 + spi * 4.0) * sc
		draw_colored_polygon(PackedVector2Array([
			Vector2(spx - 1.6 * sc, -11.0 * sc), Vector2(spx + 1.6 * sc, -11.0 * sc),
			Vector2(spx, -17.0 * sc)]), spike)
	# Stepping legs.
	var lstep := sin(_walk_time * 5.0) * (0.5 if moving else 0.0)
	_dragon_leg(Vector2(-8, 6) * sc, sc, scale_d, horn,  lstep)
	_dragon_leg(Vector2( 8, 6) * sc, sc, scale_d, horn, -lstep)
	# Long neck + HD head (sways).
	var head_xf := _bone(Vector2(0, -7) * sc, head_sway)
	_pose(head_xf)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6 * sc, 8 * sc), Vector2(6 * sc, 8 * sc),
		Vector2(4 * sc, -3 * sc), Vector2(-4 * sc, -3 * sc)]), scale_m)
	_dragon_head(head_xf, sc * 0.85, scale_m, scale_l, horn, spike, eye, ember, pulse)
	_rig_end()

func _draw_drake() -> void:
	# Bronze land-drake — compact, warm scales, modest wings.
	_draw_slim_dragon(2.6,
		Color(0.40, 0.22, 0.10), Color(0.58, 0.32, 0.14), Color(0.78, 0.48, 0.22),
		Color(0.72, 0.56, 0.30), Color(0.86, 0.80, 0.55), Color(0.92, 0.62, 0.20),
		Color(0.36, 0.20, 0.10), Color(0.50, 0.24, 0.12),
		Color(1.00, 0.55, 0.10), Color(1.00, 0.78, 0.16), 0.85)

func _draw_wyvern() -> void:
	# Green wing-armed wyvern — leaner still, larger wings, venom-green maw.
	_draw_slim_dragon(2.8,
		Color(0.18, 0.30, 0.22), Color(0.26, 0.44, 0.32), Color(0.42, 0.64, 0.46),
		Color(0.56, 0.62, 0.38), Color(0.80, 0.82, 0.58), Color(0.76, 0.86, 0.30),
		Color(0.16, 0.28, 0.20), Color(0.30, 0.20, 0.22),
		Color(0.60, 0.95, 0.35), Color(0.82, 1.00, 0.30), 1.18)

## RIGGED (art pass v1.5.3) — articulated chicken: striding legs, a bobbing
## head, a wing that flaps while moving, a breathing body and a swaying tail.
func _draw_chicken() -> void:
	var white := Color(0.98, 0.96, 0.92)
	var cream := Color(0.90, 0.86, 0.78)
	var shadow := Color(0.68, 0.65, 0.60)
	var beak := Color(0.98, 0.72, 0.15)
	var leg_c := beak.darkened(0.20)
	var comb := Color(0.88, 0.15, 0.15)
	var moving := _moving_anim
	var gait := _walk_time * 13.0        # chickens step fast
	var amp := 0.6 if moving else 0.0
	var breathe := 1.0 + sin(_time * 2.9) * 0.06
	var headbob := (cos(gait) * 1.3 if moving else sin(_time * 1.6) * 0.7)
	var tail_sway := sin((_walk_time * 8.0 if moving else _time * 2.0)) * 0.14
	# ── Far leg (behind the body) ──
	_chicken_leg(Vector2(2, 8), sin(gait + PI) * amp, leg_c.darkened(0.15))
	# ── Tail feathers (behind body, sway) ──
	_pose(_bone(Vector2(-7, 3), tail_sway))
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, 0), Vector2(-7, -5), Vector2(-6, 0), Vector2(-2, 2)]), white)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, 2), Vector2(-6, 3), Vector2(-5, 6), Vector2(-2, 4)]), cream)
	# ── Body (breathes vertically) ──
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 2), Vector2(-6, -2), Vector2(-2, -4),
		Vector2(4, -3), Vector2(7, 1), Vector2(6, 6), Vector2(2, 9),
		Vector2(-4, 8), Vector2(-8, 5)]), white)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, 4), Vector2(-2, 8), Vector2(4, 7), Vector2(6, 4)]), shadow)
	# ── Wing (flaps a little while moving) ──
	_pose(_bone(Vector2(1, 0), (sin(gait) * 0.18 if moving else sin(_time * 1.2) * 0.03)))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-2, -1), Vector2(3, -1), Vector2(4, 4), Vector2(0, 5)]), cream)
	draw_line(Vector2(-2, -1), Vector2(4, 4), shadow, 1.0)
	# ── Near leg (front) ──
	_chicken_leg(Vector2(-1, 8), sin(gait) * amp, leg_c)
	# ── Neck + head (bobs) ──
	_pose(_bone(Vector2(5, -6 + headbob), sin(_time * 1.1) * 0.03))
	draw_circle(Vector2(0, 0), 4.5, white)
	draw_circle(Vector2(-2, -5), 1.8, comb)          # comb bumps
	draw_circle(Vector2(0, -6), 2.2, comb)
	draw_circle(Vector2(2, -5), 1.6, comb)
	draw_circle(Vector2(-2, 3), 1.5, comb.darkened(0.15))   # wattle
	draw_colored_polygon(PackedVector2Array([
		Vector2(3, 0), Vector2(7, 1), Vector2(3, 2)]), beak)  # beak
	draw_circle(Vector2(1, -1), 1.0, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(1.3, -1.4), 0.4, Color(1, 1, 1, 0.85))
	_rig_end()

## A chicken leg swinging from the hip by `a` — shank + 3-toe foot.
func _chicken_leg(hip: Vector2, a: float, col: Color) -> void:
	_pose(_bone(hip, a))
	draw_line(Vector2(0, 0), Vector2(0, 7), col, 1.5)
	draw_line(Vector2(0, 7), Vector2(-3, 9), col, 1.2)
	draw_line(Vector2(0, 7), Vector2(0, 9.5), col, 1.2)
	draw_line(Vector2(0, 7), Vector2(3, 9), col, 1.2)

## A quadruped leg swinging from the hip by `a` (0 idle), paw at the end.
## Shared by the wolf / bear / rat families.
func _quad_leg(hip: Vector2, a: float, ln: float, w: float, col: Color) -> void:
	_pose(_bone(hip, a))
	draw_line(Vector2(0, 0), Vector2(0, ln), col, w)
	draw_circle(Vector2(0, ln), w * 0.85, col)

## RIGGED (V1.5.4) — four legs stride in diagonal pairs, body + head + tail breathe.
func _draw_wolf() -> void:
	var grey  := Color(0.52, 0.50, 0.46)
	var dark  := Color(0.28, 0.26, 0.22)
	var light := Color(0.72, 0.70, 0.64)
	var gait := _walk_time * 9.0
	var amp := 0.4 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 2.4) * 0.04
	# Four legs — diagonal pairs (front-near + back-far together).
	_quad_leg(Vector2(-6, 8), a1, 10, 2.5, dark)
	_quad_leg(Vector2(-2, 9), a2, 10, 2.5, dark)
	_quad_leg(Vector2( 4, 9), a2, 10, 2.5, dark)
	_quad_leg(Vector2( 8, 8), a1, 10, 2.5, dark)
	# Body + head + tail group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_line(Vector2(8, 5), Vector2(16, -2), grey, 4.0)
	draw_line(Vector2(16, -2), Vector2(18, -8), light, 3.0)
	draw_circle(Vector2(18, -9), 3.5, light)
	draw_circle(Vector2(-2, 3), 10, grey)
	draw_circle(Vector2( 6, 2),  8, grey)
	draw_circle(Vector2(-4, 1),  7, light)
	draw_circle(Vector2(0, 6), 6, Color(0.78, 0.76, 0.70, 0.6))
	draw_line(Vector2(-6, -4), Vector2(-10, -10), grey, 5.0)
	draw_circle(Vector2(-10, -10), 6, grey)
	draw_circle(Vector2(-11, -12), 4, light)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, -10), Vector2(-20, -8), Vector2(-15, -5)]), grey)
	draw_circle(Vector2(-20, -8), 1.5, dark)
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -15), Vector2(-12, -22), Vector2(-5, -17)]), grey)
	draw_colored_polygon(PackedVector2Array([Vector2(-6, -15), Vector2(-4, -23), Vector2(-1, -17)]), grey)
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -15), Vector2(-12, -21), Vector2(-6, -17)]),
		Color(0.70, 0.50, 0.50, 0.5))
	draw_circle(Vector2(-12, -11), 1.8, Color(0.88, 0.65, 0.10))
	draw_circle(Vector2(-12, -11), 0.8, Color(0.05, 0.05, 0.05))
	_rig_end()

## RIGGED (V1.5.4) — legs stride, arms swing (dagger rides the right hand),
## body + hooded head breathe. Cloak stays static behind.
func _draw_bandit() -> void:
	var cloth := Color(0.10, 0.10, 0.10)
	var brown := Color(0.28, 0.16, 0.06)
	var gait := _walk_time * 8.0
	var amp := 0.48 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 2.1) * 0.045
	# Cloak (static, behind).
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, -5), Vector2(8, -5), Vector2(12, 18), Vector2(-12, 18)]),
		Color(0.08, 0.06, 0.04))
	# Legs + boots (opposite phase).
	_pose(_bone(Vector2(-3, 12), a1)); draw_line(Vector2.ZERO, Vector2(0, 10), brown, 3.0)
	draw_circle(Vector2(0, 10), 2.5, brown.darkened(0.3))
	_pose(_bone(Vector2(3, 12), a2)); draw_line(Vector2.ZERO, Vector2(0, 10), brown, 3.0)
	draw_circle(Vector2(0, 10), 2.5, brown.darkened(0.3))
	# Left arm (behind, swings opposite its leg).
	_pose(_bone(Vector2(-7, -2), a2 * 0.8)); draw_line(Vector2.ZERO, Vector2(-5, 7), cloth, 3.5)
	# Body + hooded head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_rect(Rect2(-7, -6, 14, 18), cloth)
	draw_rect(Rect2(-5, -5, 10, 14), Color(0.15, 0.12, 0.10))
	draw_rect(Rect2(-7, 8, 14, 2), brown)
	draw_rect(Rect2(-2, 7, 4, 4), Color(0.65, 0.50, 0.15))
	draw_circle(Vector2(0, -12), 9, cloth)
	draw_circle(Vector2(0, -14), 7, Color(0.08, 0.06, 0.04))
	draw_circle(Vector2(0, -12), 7, Color(0.04, 0.04, 0.04, 0.85))
	draw_circle(Vector2(-3, -13), 1.5, Color(0.90, 0.70, 0.10))
	draw_circle(Vector2( 3, -13), 1.5, Color(0.90, 0.70, 0.10))
	draw_arc(Vector2(0, -12), 9, PI + 0.3, TAU - 0.3, 10, Color(0.20, 0.18, 0.14), 1.5)
	# Right arm + dagger (swings with the left leg).
	_pose(_bone(Vector2(7, -2), a1 * 0.8))
	draw_line(Vector2.ZERO, Vector2(5, 5), cloth, 3.5)
	draw_rect(Rect2(4, 0, 2, 12), Color(0.75, 0.75, 0.80))
	draw_rect(Rect2(2, 0, 6, 2), brown)
	draw_rect(Rect2(5, 0, 1, 12), Color(0.92, 0.92, 0.95))
	_rig_end()

## Kjelvik city watch. All three variants FLY THE CITY COLOURS (blue tabard,
## gold trim) so they read as the capital's guard at a glance; the variant is
## told apart by weapon + a small accent emblem, not a different tabard (Phase
## 5c). Blue/gold match NPC.gd KJELVIK_BLUE/KJELVIK_GOLD — keep in sync.
func _draw_guard(variant: String) -> void:
	var mail  := Color(0.46, 0.49, 0.55)          # steel
	var dark  := mail.darkened(0.4)
	var trim  := Color(0.82, 0.66, 0.20)          # Kjelvik gold
	var tabard := Color(0.20, 0.34, 0.62)         # Kjelvik blue — all variants
	# Per-variant accent (emblem + weapon glow) so melee/ranger/magi still read
	# apart while all wearing the same city colours.
	var accent := Color(0.60, 0.72, 1.00)         # melee — pale blue
	match variant:
		"ranged": accent = Color(0.50, 0.85, 0.55)   # green
		"magic":  accent = Color(0.72, 0.55, 1.00)   # violet
	# Cloak behind
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, -6), Vector2(8, -6), Vector2(11, 18), Vector2(-11, 18)]),
		tabard.darkened(0.45))
	# Legs + boots
	draw_line(Vector2(-3, 12), Vector2(-4, 22), dark, 3.0)
	draw_line(Vector2( 3, 12), Vector2( 4, 22), dark, 3.0)
	draw_circle(Vector2(-4, 22), 2.5, dark.darkened(0.3))
	draw_circle(Vector2( 4, 22), 2.5, dark.darkened(0.3))
	# Mail body + tabard over it
	draw_rect(Rect2(-7, -6, 14, 18), mail)
	draw_rect(Rect2(-4, -6, 8, 16), tabard)
	draw_rect(Rect2(-4, -6, 8, 1.6), trim)          # gold tabard trim
	# Variant emblem — a small accent diamond on the chest.
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, -3), Vector2(2.2, 0), Vector2(0, 3), Vector2(-2.2, 0)]), accent)
	draw_rect(Rect2(-7, 8, 14, 2), trim)            # belt
	# Pauldrons
	draw_circle(Vector2(-7, -4), 4, mail.lightened(0.15))
	draw_circle(Vector2( 7, -4), 4, mail.lightened(0.15))
	# Arms
	draw_line(Vector2(-7, -2), Vector2(-12, 5), mail, 3.5)
	draw_line(Vector2( 7, -2), Vector2( 12, 3), mail, 3.5)
	# Weapon per variant
	match variant:
		"ranged":
			# Longbow held out front
			draw_arc(Vector2(13, 4), 11, -1.2, 1.2, 12, Color(0.42, 0.28, 0.12), 2.0)
			draw_line(Vector2(13, -6), Vector2(13, 14), Color(0.88, 0.86, 0.78), 1.0)
		"magic":
			# Staff with a glowing focus stone
			draw_line(Vector2(12, 12), Vector2(12, -14), Color(0.38, 0.26, 0.12), 2.5)
			draw_circle(Vector2(12, -16), 4.0, Color(0.45, 0.70, 1.00, 0.85))
			draw_circle(Vector2(12, -16), 2.0, Color(0.85, 0.94, 1.00))
		_:
			# Spear + kite shield
			draw_line(Vector2(12, 14), Vector2(12, -18), Color(0.40, 0.27, 0.12), 2.5)
			draw_colored_polygon(PackedVector2Array([
				Vector2(12, -18), Vector2(9, -12), Vector2(15, -12)]),
				Color(0.85, 0.86, 0.90))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-16, -4), Vector2(-8, -4), Vector2(-8, 8),
				Vector2(-12, 13), Vector2(-16, 8)]), tabard)
			draw_polyline(PackedVector2Array([
				Vector2(-16, -4), Vector2(-8, -4), Vector2(-8, 8),
				Vector2(-12, 13), Vector2(-16, 8), Vector2(-16, -4)]), trim, 1.0)
	# Helm — nasal guard, visored slit
	draw_circle(Vector2(0, -12), 8, mail)
	draw_circle(Vector2(0, -13), 6.5, mail.lightened(0.12))
	draw_rect(Rect2(-6, -13, 12, 3), Color(0.10, 0.10, 0.12))   # eye slit
	draw_rect(Rect2(-1, -14, 2, 8), mail.darkened(0.2))          # nasal bar
	draw_arc(Vector2(0, -12), 8, PI + 0.2, TAU - 0.2, 10, trim, 1.2)

## A heavy bear foreleg + clawed paw swinging from the shoulder by `a`.
func _bear_arm(shoulder: Vector2, a: float, dir: float, brown: Color, dark: Color) -> void:
	_pose(_bone(shoulder, a))
	draw_circle(Vector2(0, 0), 7, brown)
	draw_line(Vector2(0, 0), Vector2(dir * 2, 14), dark, 6.0)
	var paw := Vector2(dir * 2, 15)
	draw_circle(paw, 5, dark)
	for ci in range(3):
		var cx := paw.x + (-3.0 + float(ci) * 3.0) * 0.6
		draw_line(Vector2(cx, 16), Vector2(cx, 20), Color(0.88, 0.84, 0.78), 1.5)

## RIGGED (V1.5.4) — hind legs stride, forelegs swing, body + head breathe.
func _draw_bear() -> void:
	var brown := Color(0.45, 0.28, 0.10)
	var dark  := brown.darkened(0.35)
	var fur   := brown.lightened(0.12)
	var gait := _walk_time * 6.5
	var amp := 0.34 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 1.9) * 0.04
	# Hind legs (behind), opposite phase.
	_quad_leg(Vector2(-6, 18), a1, 8, 5.0, dark)
	_quad_leg(Vector2( 6, 18), a2, 8, 5.0, dark)
	# Left foreleg (swings opposite its hind leg).
	_bear_arm(Vector2(-13, -2), a2 * 0.8, -1.0, brown, dark)
	# Body + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_circle(Vector2(0, 4), 18, brown)
	draw_circle(Vector2(-2, 2), 14, fur)
	draw_circle(Vector2(0, 8), 8, Color(0.62, 0.45, 0.22, 0.5))
	draw_circle(Vector2(0, -12), 11, brown)
	draw_circle(Vector2(0, -13), 9, fur)
	draw_circle(Vector2(0, -8), 5, fur.lightened(0.1))
	draw_circle(Vector2(0, -6), 2.5, dark)
	draw_circle(Vector2(-0.5, -6.8), 0.8, Color(0.6, 0.3, 0.3, 0.5))
	draw_circle(Vector2(-8, -20), 4, brown)
	draw_circle(Vector2( 8, -20), 4, brown)
	draw_circle(Vector2(-8, -20), 2, dark)
	draw_circle(Vector2( 8, -20), 2, dark)
	draw_circle(Vector2(-4, -14), 2, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2( 4, -14), 2, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(-3.5, -14.5), 0.7, Color(1, 1, 1, 0.5))
	draw_circle(Vector2( 4.5, -14.5), 0.7, Color(1, 1, 1, 0.5))
	var fc := brown.darkened(0.15)
	for fi in range(6):
		var fx := -10.0 + float(fi) * 4.0
		draw_line(Vector2(fx, 0), Vector2(fx + 1, 5), fc, 0.8)
	# Right foreleg (swings with the left hind leg).
	_bear_arm(Vector2(13, -2), a1 * 0.8, 1.0, brown, dark)
	_rig_end()

## Shared parametric troll body — all 5 troll types (base, ancient, swamp,
## ice, cave) reuse this at their preferred scale + palette. Extras are
## drawn by the caller AFTER this returns so per-variant decorations
## (ivy vines, icicles, glowing eyes, mossy plates) can layer on top.
## RIGGED (art pass v1.5.3) — shared by all 5 troll variants. Stubby legs stride
## and long arms swing (the club rides the right hand); the body + head breathe
## as one group. `sc` is the per-variant size scale.
func _draw_troll_body(sc: float, skin: Color, has_club: bool) -> void:
	var dark  := skin.darkened(0.35)
	var warty := skin.darkened(0.20)
	var gait := _walk_time * 6.0        # heavy, slow steps
	var amp := 0.32 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 1.8) * 0.05
	# ── Short thick legs (behind), opposite phase ──
	_troll_leg(Vector2(-6, 16) * sc, a1, sc, dark)
	_troll_leg(Vector2( 6, 16) * sc, a2, sc, dark)
	# ── Left arm (behind body, swings opposite its leg) ──
	_troll_arm(Vector2(-12, 0) * sc, a2 * 0.9, sc, dark, warty, -1.0, false)
	# ── Body + head group (breathes) ──
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_circle(Vector2(0, 2) * sc, 18.0 * sc, skin)
	draw_circle(Vector2(-2, -2) * sc, 14.0 * sc, skin.lightened(0.06))
	draw_circle(Vector2(2, -12) * sc, 10.0 * sc, dark)          # hunchback bump
	draw_circle(Vector2(-2, -14) * sc, 12.0 * sc, skin)         # head
	draw_circle(Vector2(-3, -16) * sc, 9.0 * sc, skin.lightened(0.08))
	draw_circle(Vector2(-8, -12) * sc, 2.0 * sc, warty)
	draw_circle(Vector2( 4, -10) * sc, 1.5 * sc, warty)
	draw_circle(Vector2(-2, -18) * sc, 1.8 * sc, warty)
	draw_circle(Vector2( 6, -16) * sc, 1.2 * sc, warty)
	draw_circle(Vector2(-2, -11) * sc, 3.5 * sc, dark)          # nose
	draw_circle(Vector2(-4, -11) * sc, 1.5 * sc, Color(0.12, 0.08, 0.04))
	draw_circle(Vector2( 0, -11) * sc, 1.5 * sc, Color(0.12, 0.08, 0.04))
	draw_circle(Vector2(-6, -16) * sc, 2.5 * sc, Color(0.88, 0.55, 0.10))
	draw_circle(Vector2( 2, -16) * sc, 2.5 * sc, Color(0.88, 0.55, 0.10))
	draw_circle(Vector2(-6, -16) * sc, 1.0 * sc, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2( 2, -16) * sc, 1.0 * sc, Color(0.05, 0.05, 0.05))
	draw_rect(Rect2(Vector2(-8, -8) * sc, Vector2(14, 4) * sc), skin)   # jaw
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4, -5) * sc, Vector2(-3, -1) * sc, Vector2(-2, -5) * sc]),
		Color(0.90, 0.87, 0.72))
	draw_colored_polygon(PackedVector2Array([
		Vector2(2, -5) * sc, Vector2(3, -1) * sc, Vector2(4, -5) * sc]),
		Color(0.90, 0.87, 0.72))
	# ── Right arm (in front, holds the club) swings with the left leg ──
	_troll_arm(Vector2(12, 0) * sc, a1 * 0.9, sc, dark, warty, 1.0, has_club)
	_rig_end()

## A thick troll leg swinging from the hip by `a`, foot at the end.
func _troll_leg(hip: Vector2, a: float, sc: float, col: Color) -> void:
	_pose(_bone(hip, a))
	draw_line(Vector2(0, 0), Vector2(0, 10 * sc), col, 6.0 * sc)
	draw_circle(Vector2(0, 10 * sc), 5.0 * sc, col)

## A long dangling troll arm swinging from the shoulder by `a`; `dir` is ±1
## (left/right), and the right arm optionally hoists a wooden club.
func _troll_arm(shoulder: Vector2, a: float, sc: float, col: Color,
		warty: Color, dir: float, club: bool) -> void:
	_pose(_bone(shoulder, a))
	var hand := Vector2(dir * 5.0 * sc, 15.0 * sc)
	draw_line(Vector2(0, 0), hand, col, 7.0 * sc)
	draw_circle(hand, 6.0 * sc, col)
	for ci in range(4):
		draw_circle(hand + Vector2((-4.5 + float(ci) * 3.0) * sc, -2.0 * sc),
			1.5 * sc, warty)
	if club:
		draw_line(hand, hand + Vector2(7, -20) * sc, Color(0.40, 0.24, 0.08), 5.0 * sc)
		draw_circle(hand + Vector2(8, -22) * sc, 7.0 * sc, Color(0.35, 0.20, 0.06))


func _draw_troll() -> void:
	# Base troll — bumped to 1.5× per the playtest ask so it visibly
	# dwarfs the player instead of matching them.
	_draw_troll_body(1.5, Color(0.32, 0.40, 0.22), true)

func _draw_forest_spirit() -> void:
	var glow  := Color(0.30, 0.90, 0.45, 0.85)
	var leaf  := Color(0.18, 0.72, 0.28)
	# Outer ethereal aura
	draw_circle(Vector2(0, 0), 16, Color(0.20, 0.85, 0.40, 0.12))
	draw_circle(Vector2(0, 0), 12, Color(0.30, 0.90, 0.45, 0.18))
	# Core wisp — bright glowing center
	draw_circle(Vector2(0, 0), 7, glow)
	draw_circle(Vector2(0, 0), 4, Color(0.70, 1.00, 0.75, 0.90))
	draw_circle(Vector2(0, 0), 2, Color(0.95, 1.00, 0.95))
	# Orbiting wisps (3 satellites)
	var wt := _time * 1.8
	for wi in range(3):
		var wa := wt + float(wi) * (TAU / 3.0)
		var wx := cos(wa) * 10.0
		var wy := sin(wa) * 7.0
		draw_circle(Vector2(wx, wy), 3.0, Color(0.40, 0.95, 0.55, 0.75))
		draw_circle(Vector2(wx, wy), 1.5, Color(0.80, 1.00, 0.85, 0.90))
	# Leaf shapes radiating outward
	for li in range(6):
		var la := float(li) * (TAU / 6.0) + wt * 0.4
		var lx := cos(la) * 11.0
		var ly := sin(la) * 11.0
		var tip := Vector2(lx, ly)
		var base_l := Vector2(lx - sin(la) * 3, ly + cos(la) * 3)
		var base_r := Vector2(lx + sin(la) * 3, ly - cos(la) * 3)
		draw_colored_polygon(PackedVector2Array([tip, base_l, base_r]), Color(leaf.r, leaf.g, leaf.b, 0.65))
	# Tendrils of light
	for ti in range(4):
		var ta := wt * 0.6 + float(ti) * (TAU / 4.0)
		draw_line(Vector2.ZERO, Vector2(cos(ta) * 13, sin(ta) * 10),
			Color(0.50, 1.00, 0.60, 0.25), 1.5)

func _draw_spider() -> void:
	var black := Color(0.08, 0.06, 0.06)
	var dark  := Color(0.18, 0.14, 0.14)
	# Eight legs — radiating outward. RIGGED (V1.5.4): they SCUTTLE — alternating
	# legs extend/retract in an even-odd rhythm (tetrapod gait) while moving, and
	# flex faintly when idle so the spider never freezes.
	var leg_angles: Array[float] = [-1.2, -0.6, 0.0, 0.6, PI + 1.2, PI + 0.6, PI, PI - 0.6]
	var scuttle := _walk_time * 14.0
	for li in range(8):
		var la: float = leg_angles[li]
		var ph := scuttle + (0.0 if li % 2 == 0 else PI)
		var reach: float = (1.0 + sin(ph) * 0.18) if _moving_anim else (1.0 + sin(_time * 2.0 + float(li)) * 0.05)
		var knee := Vector2(cos(la) * 10, sin(la) * 8) * reach
		var foot := knee + Vector2(cos(la + 0.4) * 8, sin(la + 0.4) * 8) * reach
		draw_line(Vector2.ZERO, knee, black, 2.0)
		draw_line(knee, foot, black, 1.5)
	# Abdomen — large oval at back
	draw_circle(Vector2(0, 6), 9, black)
	draw_circle(Vector2(0, 5), 7, dark)
	# Hourglass marking on abdomen (red)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-2, 2), Vector2(2, 2), Vector2(1, 6), Vector2(-1, 6)]),
		Color(0.90, 0.10, 0.10, 0.85))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-2, 8), Vector2(2, 8), Vector2(1, 12), Vector2(-1, 12)]),
		Color(0.90, 0.10, 0.10, 0.85))
	# Cephalothorax — smaller front segment
	draw_circle(Vector2(0, -4), 6, black)
	draw_circle(Vector2(0, -5), 4.5, dark)
	# Eight eyes — two rows
	var eye_positions := [Vector2(-4, -7), Vector2(-2, -8), Vector2(2, -8), Vector2(4, -7),
						   Vector2(-3, -5), Vector2(-1, -4), Vector2(1, -4), Vector2(3, -5)]
	for ep: Vector2 in eye_positions:
		draw_circle(ep, 1.2, Color(0.90, 0.10, 0.10))
		draw_circle(ep + Vector2(0.3, -0.3), 0.4, Color(1, 0.8, 0.8, 0.7))
	# Chelicerae (fangs)
	draw_colored_polygon(PackedVector2Array([Vector2(-3, -1), Vector2(-1, -1), Vector2(-2, 3)]),
		dark)
	draw_colored_polygon(PackedVector2Array([Vector2(1, -1), Vector2(3, -1), Vector2(2, 3)]),
		dark)
	draw_circle(Vector2(-2, 3), 1.5, Color(0.15, 0.75, 0.30, 0.80))
	draw_circle(Vector2( 2, 3), 1.5, Color(0.15, 0.75, 0.30, 0.80))

## RIGGED (V1.5.4) — four legs stride in diagonal pairs, body + head breathe.
func _draw_ice_wolf() -> void:
	var ice   := Color(0.60, 0.82, 0.96)
	var dark  := Color(0.25, 0.45, 0.65)
	var white := Color(0.88, 0.94, 0.98)
	var gait := _walk_time * 9.5
	var amp := 0.38 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 2.5) * 0.04
	draw_circle(Vector2(0, 0), 16, Color(0.60, 0.85, 1.0, 0.10))   # aura (static)
	# Four legs (diagonal pairs).
	_quad_leg(Vector2(-7, 7), a1, 10, 2.5, dark)
	_quad_leg(Vector2(-2, 8), a2, 10, 2.5, dark)
	_quad_leg(Vector2( 4, 8), a2, 10, 2.5, dark)
	_quad_leg(Vector2( 8, 6), a1, 10, 2.5, dark)
	# Body + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_line(Vector2(8, 4), Vector2(16, -4), ice, 4.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(15, -6), Vector2(18, -12), Vector2(20, -5)]), white)
	draw_colored_polygon(PackedVector2Array([
		Vector2(17, -4), Vector2(22, -8), Vector2(22, -2)]), Color(0.70, 0.90, 1.0, 0.75))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, -2), Vector2(8, -4), Vector2(10, 8), Vector2(-8, 10)]), ice)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 0), Vector2(6, -2), Vector2(8, 6), Vector2(-6, 8)]), white)
	for si in range(5):
		var sx := -8.0 + float(si) * 4.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(sx - 1.5, -4), Vector2(sx + 1.5, -4), Vector2(sx, -10)]),
			Color(0.78, 0.92, 1.0, 0.85))
	draw_circle(Vector2(-10, -8), 6, ice)
	draw_circle(Vector2(-11, -10), 4.5, white)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, -8), Vector2(-20, -6), Vector2(-16, -4)]), ice)
	draw_circle(Vector2(-20, -6), 1.5, dark)
	draw_colored_polygon(PackedVector2Array([Vector2(-7, -13), Vector2(-10, -20), Vector2(-4, -15)]), ice)
	draw_colored_polygon(PackedVector2Array([Vector2(-5, -13), Vector2(-4, -21), Vector2(-1, -15)]), ice)
	draw_circle(Vector2(-12, -10), 2, Color(0.20, 0.90, 1.00))
	draw_circle(Vector2(-12, -10), 0.9, Color(0.90, 0.97, 1.0))
	draw_circle(Vector2(-18, -5), 2.5, Color(0.75, 0.90, 1.0, 0.25))
	_rig_end()

## RIGGED (V1.5.4) — heavy legs stride, arms swing (ice maul rides the right
## hand), plated torso + crowned head breathe.
func _draw_frost_giant() -> void:
	var skin  := Color(0.62, 0.78, 0.90)
	var armor := Color(0.45, 0.62, 0.80)
	var ice   := Color(0.80, 0.94, 1.00)
	var gait := _walk_time * 6.0
	var amp := 0.34 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 1.8) * 0.04
	draw_circle(Vector2(0, 0), 22, Color(0.40, 0.58, 0.78, 0.20))   # aura (static)
	# Legs (opposite phase).
	_pose(_bone(Vector2(-8, 14), a1)); draw_line(Vector2.ZERO, Vector2(0, 14), armor, 7.0)
	draw_circle(Vector2(0, 14), 5.5, armor.darkened(0.3))
	_pose(_bone(Vector2(8, 14), a2)); draw_line(Vector2.ZERO, Vector2(0, 14), armor, 7.0)
	draw_circle(Vector2(0, 14), 5.5, armor.darkened(0.3))
	# Left arm (swings opposite its leg).
	_pose(_bone(Vector2(-12, -4), a2 * 0.8)); draw_line(Vector2.ZERO, Vector2(-8, 12), armor, 8.0)
	# Torso + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_rect(Rect2(-12, -8, 24, 22), armor)
	draw_rect(Rect2(-10, -6, 20, 18), skin)
	draw_line(Vector2(-10, 2), Vector2(10, 2), ice, 1.5)
	draw_line(Vector2(-10, 8), Vector2(10, 8), ice, 1.5)
	draw_line(Vector2(0, -6), Vector2(0, 14), ice, 1.5)
	for ii in range(3):
		var ix := -10.0 + float(ii) * 10.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(ix - 2, -8), Vector2(ix + 2, -8), Vector2(ix, -16)]),
			Color(ice.r, ice.g, ice.b, 0.80))
	draw_circle(Vector2(0, -18), 13, skin)
	draw_circle(Vector2(0, -20), 10, skin.lightened(0.08))
	for bi in range(5):
		var bx := -8.0 + float(bi) * 4.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(bx - 1.5, -8), Vector2(bx + 1.5, -8), Vector2(bx, -4)]),
			Color(ice.r, ice.g, ice.b, 0.85))
	draw_circle(Vector2(-5, -20), 3, Color(0.20, 0.70, 1.00))
	draw_circle(Vector2( 5, -20), 3, Color(0.20, 0.70, 1.00))
	draw_circle(Vector2(-5, -20), 1.2, Color(0.85, 0.95, 1.0))
	draw_circle(Vector2( 5, -20), 1.2, Color(0.85, 0.95, 1.0))
	draw_colored_polygon(PackedVector2Array([Vector2(-10, -28), Vector2(-14, -38), Vector2(-6, -30)]), ice)
	draw_colored_polygon(PackedVector2Array([Vector2(10, -28), Vector2(14, -38), Vector2(6, -30)]), ice)
	draw_rect(Rect2(-12, -30, 24, 4), armor)
	# Right arm + ice maul (swings with the left leg).
	_pose(_bone(Vector2(12, -4), a1 * 0.8))
	draw_line(Vector2.ZERO, Vector2(10, 8), armor, 8.0)
	draw_line(Vector2(8, 6), Vector2(14, -10), Color(0.35, 0.28, 0.20), 4.0)
	draw_rect(Rect2(6, -18, 14, 10), ice)
	draw_rect(Rect2(4, -16, 18, 6), Color(0.68, 0.84, 0.95))
	_rig_end()

## RIGGED (V1.5.4) — a slow FROZEN shamble (low stride amp to keep the
## "ice-locked" read); the ice shell + head breathe.
func _draw_ice_draugr() -> void:
	var frost := Color(0.68, 0.86, 0.98)
	var dark  := Color(0.22, 0.35, 0.52)
	var ice   := Color(0.88, 0.96, 1.00, 0.85)
	var gait := _walk_time * 5.0
	var amp := 0.22 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 1.6) * 0.03
	# Legs (frozen shamble).
	_pose(_bone(Vector2(-4, 12), a1)); draw_line(Vector2.ZERO, Vector2(0, 10), dark, 3.0)
	draw_colored_polygon(PackedVector2Array([Vector2(-4, 8), Vector2(1, 8), Vector2(0, 12)]),
		Color(frost.r, frost.g, frost.b, 0.6))
	_pose(_bone(Vector2(4, 12), a2)); draw_line(Vector2.ZERO, Vector2(0, 10), dark, 3.0)
	draw_colored_polygon(PackedVector2Array([Vector2(-1, 8), Vector2(4, 8), Vector2(0, 12)]),
		Color(frost.r, frost.g, frost.b, 0.6))
	# Left arm (behind).
	_pose(_bone(Vector2(-7, 0), a2 * 0.6)); draw_line(Vector2.ZERO, Vector2(-7, -8), dark, 3.5)
	# Body + shell + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, 22), Vector2(-12, 0), Vector2(-8, -20), Vector2(0, -25),
		Vector2(8, -20), Vector2(12, 0), Vector2(10, 22)]),
		Color(frost.r, frost.g, frost.b, 0.35))
	draw_rect(Rect2(-7, -6, 14, 18), dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, -5), Vector2(-8, -20), Vector2(0, -22), Vector2(8, -20), Vector2(10, -5)]),
		Color(frost.r, frost.g, frost.b, 0.55))
	draw_line(Vector2(-5, -15), Vector2(3, -5), ice, 1.0)
	draw_line(Vector2(3, -5), Vector2(7, 0), ice, 0.8)
	draw_line(Vector2(-3, 0), Vector2(5, 10), ice, 1.0)
	draw_line(Vector2(-8, 8), Vector2(-2, 14), ice, 0.8)
	draw_circle(Vector2(0, -14), 9, dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, -10), Vector2(-9, -20), Vector2(0, -23), Vector2(9, -20), Vector2(9, -10)]),
		Color(frost.r, frost.g, frost.b, 0.45))
	draw_circle(Vector2(-3, -15), 2.5, Color(0.50, 0.90, 1.00))
	draw_circle(Vector2( 3, -15), 2.5, Color(0.50, 0.90, 1.00))
	draw_circle(Vector2(-3, -15), 1.0, Color(0.90, 0.97, 1.0))
	draw_circle(Vector2( 3, -15), 1.0, Color(0.90, 0.97, 1.0))
	draw_colored_polygon(PackedVector2Array([Vector2(-9, -6), Vector2(-12, -6), Vector2(-10, -14)]),
		Color(ice.r, ice.g, ice.b, 0.80))
	draw_colored_polygon(PackedVector2Array([Vector2(9, -6), Vector2(12, -6), Vector2(10, -14)]),
		Color(ice.r, ice.g, ice.b, 0.80))
	# Right arm + ice spike (swings with the left leg).
	_pose(_bone(Vector2(7, 0), a1 * 0.6))
	draw_line(Vector2.ZERO, Vector2(9, -6), dark, 3.5)
	draw_colored_polygon(PackedVector2Array([Vector2(7, -8), Vector2(11, -8), Vector2(9, -20)]),
		Color(ice.r, ice.g, ice.b, 0.90))
	_rig_end()

func _draw_fire_imp() -> void:
	var red    := Color(0.90, 0.18, 0.05)
	var orange := Color(1.00, 0.52, 0.05)
	var dark   := Color(0.50, 0.06, 0.02)
	# Fire glow aura
	draw_circle(Vector2(0, 0), 14, Color(1.0, 0.40, 0.05, 0.15))
	# Bat wings — leathery
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4, -4), Vector2(-18, -16), Vector2(-20, -4), Vector2(-12, 2), Vector2(-4, 0)]),
		dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(4, -4), Vector2(18, -16), Vector2(20, -4), Vector2(12, 2), Vector2(4, 0)]),
		dark)
	# Wing veins
	draw_line(Vector2(-4, -2), Vector2(-18, -12), red.darkened(0.2), 0.8)
	draw_line(Vector2(-4, -1), Vector2(-14, 0), red.darkened(0.2), 0.8)
	draw_line(Vector2(4, -2), Vector2(18, -12), red.darkened(0.2), 0.8)
	draw_line(Vector2(4, -1), Vector2(14, 0), red.darkened(0.2), 0.8)
	# Small body
	draw_circle(Vector2(0, 2), 9, red)
	draw_circle(Vector2(0, 0), 7, orange.darkened(0.1))
	# Belly lighter (fire glow from within)
	draw_circle(Vector2(0, 4), 4, Color(1.0, 0.70, 0.20, 0.40))
	# Spindly legs
	draw_line(Vector2(-3, 9), Vector2(-4, 16), dark, 1.8)
	draw_line(Vector2( 3, 9), Vector2( 4, 16), dark, 1.8)
	draw_circle(Vector2(-4, 17), 2, dark)
	draw_circle(Vector2( 4, 17), 2, dark)
	# Pointed tail
	draw_line(Vector2(4, 6), Vector2(10, 10), dark, 2.0)
	draw_colored_polygon(PackedVector2Array([Vector2(9, 8), Vector2(12, 14), Vector2(13, 8)]), dark)
	# Arms
	draw_line(Vector2(-6, 0), Vector2(-10, 5), dark, 2.0)
	draw_line(Vector2( 6, 0), Vector2( 10, 5), dark, 2.0)
	# Head with two horns
	draw_circle(Vector2(0, -8), 8, red)
	draw_circle(Vector2(0, -9), 6, orange.darkened(0.05))
	# Horns
	draw_colored_polygon(PackedVector2Array([Vector2(-4, -13), Vector2(-6, -21), Vector2(-1, -15)]), dark)
	draw_colored_polygon(PackedVector2Array([Vector2(4, -13), Vector2(6, -21), Vector2(1, -15)]), dark)
	draw_line(Vector2(-5, -14), Vector2(-6, -20), orange, 0.8)
	draw_line(Vector2( 5, -14), Vector2( 6, -20), orange, 0.8)
	# Eyes — fiery yellow-orange
	draw_circle(Vector2(-3, -9), 2, Color(1.0, 0.85, 0.10))
	draw_circle(Vector2( 3, -9), 2, Color(1.0, 0.85, 0.10))
	draw_circle(Vector2(-3, -9), 0.8, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2( 3, -9), 0.8, Color(0.05, 0.05, 0.05))
	# Grinning mouth with little fangs
	draw_arc(Vector2(0, -6), 3, 0.2, PI - 0.2, 8, dark, 1.5)
	draw_colored_polygon(PackedVector2Array([Vector2(-2, -4), Vector2(-1, -4), Vector2(-1.5, -2)]),
		Color(0.95, 0.92, 0.85))
	draw_colored_polygon(PackedVector2Array([Vector2(1, -4), Vector2(2, -4), Vector2(1.5, -2)]),
		Color(0.95, 0.92, 0.85))
	# Ember sparks floating
	draw_circle(Vector2(-8, -6), 1.0, Color(1.0, 0.80, 0.10, 0.70))
	draw_circle(Vector2( 9, -4), 0.8, Color(1.0, 0.60, 0.05, 0.60))

func _draw_lava_crawler() -> void:
	# 2.5× overall scale so the beast reads as monumental. Animated lava
	# cracks pulse via _time and 3 drip streams fall + reset from
	# the underside. Shadow is disabled for this type (see _has_shadow).
	var sc := 2.5
	var rock   := Color(0.22, 0.18, 0.14)
	var lava   := Color(1.00, 0.42, 0.05)
	var hot    := Color(1.00, 0.75, 0.20)
	# Pulsing crack brightness — swings 0.7..1.0 alpha with time.
	var pulse: float = 0.7 + 0.3 * sin(_time * 3.0)
	var lava_pulse := Color(lava.r, lava.g, lava.b, pulse)
	# Long segmented body — centipede shape.
	var seg_count := 6
	for si in range(seg_count):
		var sx := (-18.0 + float(si) * 7.0) * sc
		var sy := sin(float(si) * 0.9) * 3.0 * sc
		var sr := (6.0 - float(si) * 0.4) * sc
		draw_circle(Vector2(sx, sy), sr + sc, rock.darkened(0.2))
		draw_circle(Vector2(sx, sy), sr, rock)
		# Glowing lava cracks between segments — pulsing.
		if si < seg_count - 1:
			var nx := (-18.0 + float(si + 1) * 7.0) * sc
			var ny := sin(float(si + 1) * 0.9) * 3.0 * sc
			draw_line(Vector2(sx + sr * 0.6, sy), Vector2(nx - sr * 0.6, ny),
				lava_pulse, 1.5 * sc)
	# Lava glow seam along top of body.
	for si in range(seg_count):
		var sx := (-18.0 + float(si) * 7.0) * sc
		var sy := sin(float(si) * 0.9) * 3.0 * sc
		draw_arc(Vector2(sx, sy), (5.0 - float(si) * 0.3) * sc,
			PI + 0.5, TAU - 0.5, 6,
			Color(lava.r, lava.g, lava.b, 0.70 * pulse), 2.0 * sc)
	# Pairs of legs along each segment.
	for si in range(seg_count - 1):
		var sx := (-14.0 + float(si) * 7.0) * sc
		var sy := sin(float(si) * 0.9) * 3.0 * sc
		draw_line(Vector2(sx, sy + 3 * sc), Vector2(sx - 4 * sc, sy + 10 * sc),
			rock, 2.0 * sc)
		draw_line(Vector2(sx, sy + 3 * sc), Vector2(sx + 4 * sc, sy + 10 * sc),
			rock, 2.0 * sc)
		draw_line(Vector2(sx - 4 * sc, sy + 10 * sc),
			Vector2(sx - 6 * sc, sy + 14 * sc), rock.lightened(0.1), 1.5 * sc)
		draw_line(Vector2(sx + 4 * sc, sy + 10 * sc),
			Vector2(sx + 6 * sc, sy + 14 * sc), rock.lightened(0.1), 1.5 * sc)
	# Head segment with mandibles.
	draw_circle(Vector2(-20, 0) * sc, 8.0 * sc, rock)
	draw_circle(Vector2(-20, -1) * sc, 6.0 * sc, rock.lightened(0.12))
	draw_line(Vector2(-24, -2) * sc, Vector2(-30, -5) * sc,
		rock.darkened(0.1), 3.0 * sc)
	draw_line(Vector2(-24,  2) * sc, Vector2(-30,  6) * sc,
		rock.darkened(0.1), 3.0 * sc)
	draw_circle(Vector2(-30, -5) * sc, 2.5 * sc, rock)
	draw_circle(Vector2(-30,  6) * sc, 2.5 * sc, rock)
	# Eyes — hot orange glow, brightened by the pulse.
	draw_circle(Vector2(-22, -3) * sc, 2.5 * sc, lava)
	draw_circle(Vector2(-22, -3) * sc, 1.0 * sc, hot)
	draw_circle(Vector2(-18, -4) * sc, 2.0 * sc, lava)
	draw_circle(Vector2(-18, -4) * sc, 0.8 * sc, hot)
	# Inner lava glow on head.
	draw_circle(Vector2(-20, 1) * sc, 3.5 * sc,
		Color(lava.r, lava.g, lava.b, 0.30 * pulse))
	# ── Animated lava drips ──
	# 3 drip streams from the underside — each cycles through fall + reset
	# with a staggered phase. Position + size derived from _time.
	for di in range(3):
		var drip_sx := (-10.0 + float(di) * 8.0) * sc
		var phase: float = fmod(_time * 1.8 + float(di) * 1.2, 2.0)
		var drip_y := 10.0 * sc + phase * 18.0 * sc
		var drip_r := 3.0 * sc * (1.0 - phase * 0.5)
		if drip_r > 0.5:
			draw_circle(Vector2(drip_sx, drip_y), drip_r, lava)
			draw_circle(Vector2(drip_sx, drip_y), drip_r * 0.5, hot)

## RIGGED (V1.5.4) — pillar legs stride, arms swing (burning maul rides the
## right hand, flames the open left), molten torso + head breathe.
func _draw_fire_giant() -> void:
	var fire   := Color(0.95, 0.38, 0.05)
	var hot    := Color(1.00, 0.90, 0.25)
	var ember  := Color(0.60, 0.12, 0.02)
	var gait := _walk_time * 6.0
	var amp := 0.32 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 1.8) * 0.04
	draw_circle(Vector2(0, 0), 25, Color(1.0, 0.30, 0.05, 0.12))   # flame aura (static)
	draw_circle(Vector2(0, 0), 20, Color(1.0, 0.45, 0.08, 0.18))
	# Legs (opposite phase) + lava pools.
	_pose(_bone(Vector2(-8, 14), a1)); draw_line(Vector2.ZERO, Vector2(0, 14), ember, 8.0)
	draw_circle(Vector2(0, 14), 6, ember.darkened(0.2))
	draw_circle(Vector2(0, 16), 7, Color(1.0, 0.45, 0.05, 0.35))
	_pose(_bone(Vector2(8, 14), a2)); draw_line(Vector2.ZERO, Vector2(0, 14), ember, 8.0)
	draw_circle(Vector2(0, 14), 6, ember.darkened(0.2))
	draw_circle(Vector2(0, 16), 7, Color(1.0, 0.45, 0.05, 0.35))
	# Left arm + open flaming hand (swings opposite its leg).
	_pose(_bone(Vector2(-13, -2), a2 * 0.8))
	draw_line(Vector2.ZERO, Vector2(-9, 10), ember, 9.0)
	draw_circle(Vector2(-9, 12), 7, ember)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, 6), Vector2(-13, -2), Vector2(-9, 0), Vector2(-5, -4), Vector2(-5, 4)]),
		Color(1.0, 0.55, 0.08, 0.75))
	# Torso + head group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_rect(Rect2(-13, -8, 26, 22), ember)
	draw_rect(Rect2(-11, -6, 22, 18), fire)
	draw_line(Vector2(-8, -4), Vector2(-2, 4), hot, 1.5)
	draw_line(Vector2(-2, 4), Vector2(4, 8), hot, 1.0)
	draw_line(Vector2(6, -5), Vector2(2, 2), hot, 1.5)
	draw_line(Vector2(2, 2), Vector2(8, 10), hot, 1.0)
	draw_line(Vector2(-5, 6), Vector2(5, 10), hot, 1.2)
	draw_circle(Vector2(0, -20), 14, ember)
	draw_circle(Vector2(0, -22), 11, fire)
	draw_circle(Vector2(-5, -22), 4, Color(1.0, 0.85, 0.20))
	draw_circle(Vector2( 5, -22), 4, Color(1.0, 0.85, 0.20))
	draw_circle(Vector2(-5, -22), 2, hot)
	draw_circle(Vector2( 5, -22), 2, hot)
	for fi in range(5):
		var fx := -8.0 + float(fi) * 4.0
		var fh := 6.0 + float(fi % 3) * 3.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(fx - 2, -30), Vector2(fx + 2, -30), Vector2(fx, -30 - fh)]),
			Color(1.0, 0.65, 0.10, 0.80))
	draw_circle(Vector2(-14, -10), 1.5, Color(1.0, 0.80, 0.20, 0.65))
	draw_circle(Vector2( 16, -8), 1.2, Color(1.0, 0.60, 0.05, 0.55))
	draw_circle(Vector2(  2, -32), 1.0, Color(1.0, 0.90, 0.30, 0.70))
	# Right arm + burning maul (swings with the left leg).
	_pose(_bone(Vector2(13, -2), a1 * 0.8))
	draw_line(Vector2.ZERO, Vector2(11, 6), ember, 9.0)
	draw_line(Vector2(9, 4), Vector2(17, -14), Color(0.30, 0.22, 0.12), 5.0)
	draw_rect(Rect2(11, -26, 12, 14), ember)
	draw_rect(Rect2(9, -24, 16, 10), fire)
	draw_circle(Vector2(15, -24), 5, Color(1.0, 0.65, 0.10, 0.60))
	draw_circle(Vector2(17, -28), 4, Color(1.0, 0.85, 0.25, 0.40))
	_rig_end()

## RIGGED (V1.5.4) — the vague limbs now shamble; the shadow form + head breathe
## while the tendril wisps keep drifting on their own `_time` clock.
func _draw_shadow_draugr() -> void:
	var shadow := Color(0.08, 0.04, 0.14)
	var void_c := Color(0.02, 0.00, 0.06)
	var purple := Color(0.55, 0.10, 0.80)
	var gait := _walk_time * 6.0
	var amp := 0.30 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 1.7) * 0.04
	draw_circle(Vector2(0, 0), 20, Color(0.10, 0.04, 0.16, 0.30))   # aura (static)
	draw_circle(Vector2(0, 0), 16, Color(0.08, 0.02, 0.12, 0.50))
	# Leg suggestions (opposite phase).
	_pose(_bone(Vector2(-4, 12), a1)); draw_line(Vector2.ZERO, Vector2(-2, 10), shadow, 4.0)
	_pose(_bone(Vector2(4, 12), a2)); draw_line(Vector2.ZERO, Vector2(2, 10), shadow, 4.0)
	# Left arm suggestion (behind).
	_pose(_bone(Vector2(-8, 2), a2 * 0.7)); draw_line(Vector2.ZERO, Vector2(-8, 10), shadow, 4.0)
	# Body + head + wisps group (breathes).
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_circle(Vector2(0, 2), 14, shadow)
	draw_circle(Vector2(-1, 0), 11, void_c)
	for wi in range(5):
		var wa := float(wi) * (TAU / 5.0) + _time * 0.5
		var wr := 10.0 + sin(_time * 2.0 + float(wi)) * 2.0
		draw_line(Vector2.ZERO, Vector2(cos(wa) * wr, sin(wa) * wr - 6),
			Color(shadow.r, shadow.g, shadow.b, 0.55), 2.5)
	draw_circle(Vector2(0, -12), 9, void_c)
	draw_circle(Vector2(0, -12), 7, shadow)
	draw_circle(Vector2(-3, -13), 3, purple)
	draw_circle(Vector2( 3, -13), 3, purple)
	draw_circle(Vector2(-3, -13), 1.5, Color(0.80, 0.50, 1.00))
	draw_circle(Vector2( 3, -13), 1.5, Color(0.80, 0.50, 1.00))
	draw_circle(Vector2(-3, -13), 0.5, Color(1.0, 0.9, 1.0, 0.90))
	draw_circle(Vector2( 3, -13), 0.5, Color(1.0, 0.9, 1.0, 0.90))
	draw_line(Vector2(-4, -18), Vector2(-8, -26), Color(shadow.r, shadow.g, shadow.b, 0.45), 2.0)
	draw_line(Vector2( 4, -18), Vector2( 8, -26), Color(shadow.r, shadow.g, shadow.b, 0.45), 2.0)
	draw_line(Vector2( 0, -20), Vector2( 0, -28), Color(shadow.r, shadow.g, shadow.b, 0.35), 2.0)
	# Right arm suggestion (swings with the left leg).
	_pose(_bone(Vector2(8, 2), a1 * 0.7)); draw_line(Vector2.ZERO, Vector2(8, 8), shadow, 4.0)
	_rig_end()

## RIGGED (art pass v1.5.3) — plated legs stride, arms swing, the greatsword
## rides the right hand; the armoured torso + helm breathe as one group.
func _draw_death_knight() -> void:
	var black := Color(0.06, 0.06, 0.08)
	var steel := Color(0.18, 0.20, 0.26)
	var glow  := Color(0.10, 0.90, 0.40)
	var gait := _walk_time * 7.0
	var amp := 0.4 if _moving_anim else 0.0
	var a1 := sin(gait) * amp
	var a2 := sin(gait + PI) * amp
	var breathe := 1.0 + sin(_time * 2.0) * 0.04
	# Shadow aura (static, under the body transform).
	draw_circle(Vector2(0, 0), 20, Color(0.05, 0.12, 0.08, 0.20))
	# ── Legs (opposite phase) ──
	_dk_leg(Vector2(-5, 12), a1, steel, black)
	_dk_leg(Vector2( 5, 12), a2, steel, black)
	# ── Left arm (behind, swings opposite its leg) ──
	_dk_arm(Vector2(-12, -4), a2 * 0.8, steel, black, glow, -1.0, false)
	# ── Torso + helm group (breathes) ──
	_pose(_bone(Vector2.ZERO, 0.0, Vector2(1.0, breathe)))
	draw_rect(Rect2(-10, -8, 20, 20), black)
	draw_rect(Rect2(-8, -6, 16, 16), steel)
	draw_line(Vector2(-6, -4), Vector2(6, -4), Color(glow.r, glow.g, glow.b, 0.30), 1.0)
	draw_line(Vector2(0, -6), Vector2(0, 6), Color(glow.r, glow.g, glow.b, 0.25), 1.0)
	draw_circle(Vector2(0, 0), 4, Color(glow.r, glow.g, glow.b, 0.15))
	draw_line(Vector2(-3, 0), Vector2(3, 0), glow, 1.2)
	draw_line(Vector2(0, -3), Vector2(0, 3), glow, 1.2)
	# Pauldrons (shoulder plates, stay with the torso).
	draw_circle(Vector2(-12, -4), 6, steel)
	draw_circle(Vector2( 12, -4), 6, steel)
	draw_arc(Vector2(-12, -4), 6, PI, TAU, 8, black, 1.5)
	draw_arc(Vector2( 12, -4), 6, PI, TAU, 8, black, 1.5)
	# Full helm + crest + visor + green eyes.
	draw_circle(Vector2(0, -18), 11, steel)
	draw_circle(Vector2(0, -19), 9, black)
	draw_rect(Rect2(-1, -30, 2, 12), steel)
	draw_colored_polygon(PackedVector2Array([Vector2(-3, -30), Vector2(3, -30), Vector2(0, -34)]), steel)
	draw_rect(Rect2(-7, -22, 14, 3), Color(0.04, 0.04, 0.06))
	draw_rect(Rect2(-1, -24, 2, 8), Color(0.04, 0.04, 0.06))
	draw_circle(Vector2(-3, -21), 2.5, glow)
	draw_circle(Vector2( 3, -21), 2.5, glow)
	draw_circle(Vector2(-3, -21), 1.0, Color(0.70, 1.00, 0.80))
	draw_circle(Vector2( 3, -21), 1.0, Color(0.70, 1.00, 0.80))
	draw_rect(Rect2(-10, -22, 4, 8), steel)
	draw_rect(Rect2(  6, -22, 4, 8), steel)
	# ── Right arm hoisting the greatsword, swings with the left leg ──
	_dk_arm(Vector2(12, -4), a1 * 0.8, steel, black, glow, 1.0, true)
	_rig_end()

func _dk_leg(hip: Vector2, a: float, steel: Color, black: Color) -> void:
	_pose(_bone(hip, a))
	draw_line(Vector2(0, 0), Vector2(0, 12), steel, 5.0)
	draw_circle(Vector2(0, 12), 4, black)
	draw_rect(Rect2(-4, 10, 8, 4), steel)   # sabaton

func _dk_arm(shoulder: Vector2, a: float, steel: Color, black: Color,
		glow: Color, dir: float, sword: bool) -> void:
	_pose(_bone(shoulder, a))
	var hand := Vector2(dir * 7.0, 11.0)
	draw_line(Vector2(0, 0), hand, steel, 4.5)
	draw_circle(hand, 4.0, black)   # gauntlet
	if sword:
		# Greatsword held point-up in the hand — swings with the arm.
		draw_rect(Rect2(hand.x - 5, hand.y - 2, 12, 3), black)          # crossguard
		draw_rect(Rect2(hand.x - 1, hand.y - 34, 4, 32), Color(0.25, 0.28, 0.35))
		draw_rect(Rect2(hand.x, hand.y - 34, 2, 32), Color(0.42, 0.45, 0.52))
		draw_line(Vector2(hand.x + 1, hand.y - 30), Vector2(hand.x + 1, hand.y - 12),
			Color(glow.r, glow.g, glow.b, 0.40), 1.0)

func _draw_spectral_warrior() -> void:
	var ghost := Color(0.62, 0.82, 0.96, 0.75)
	var bright := Color(0.85, 0.95, 1.00, 0.90)
	# Ethereal outer glow
	draw_circle(Vector2(0, 0), 18, Color(0.55, 0.80, 1.0, 0.12))
	draw_circle(Vector2(0, 0), 14, Color(0.65, 0.88, 1.0, 0.18))
	# Fading lower body — ghost trail (no legs, just wisps)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 8), Vector2(8, 8), Vector2(6, 22), Vector2(0, 28), Vector2(-6, 22)]),
		Color(ghost.r, ghost.g, ghost.b, 0.30))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-5, 14), Vector2(5, 14), Vector2(3, 26), Vector2(-3, 26)]),
		Color(ghost.r, ghost.g, ghost.b, 0.15))
	# Torso — translucent warrior form
	draw_rect(Rect2(-8, -8, 16, 18), Color(ghost.r, ghost.g, ghost.b, 0.55))
	draw_rect(Rect2(-6, -6, 12, 14), Color(bright.r, bright.g, bright.b, 0.35))
	# Ghostly armor details
	draw_line(Vector2(-5, -4), Vector2(5, -4), Color(bright.r, bright.g, bright.b, 0.50), 1.0)
	draw_line(Vector2(-5,  2), Vector2(5,  2), Color(bright.r, bright.g, bright.b, 0.40), 1.0)
	# Spectral arms
	draw_line(Vector2(-8, -4), Vector2(-16, 6), Color(ghost.r, ghost.g, ghost.b, 0.65), 4.0)
	draw_line(Vector2( 8, -4), Vector2( 18, 2), Color(ghost.r, ghost.g, ghost.b, 0.65), 4.0)
	# Ghostly shield (left)
	draw_circle(Vector2(-16, 6), 6, Color(ghost.r, ghost.g, ghost.b, 0.50))
	draw_circle(Vector2(-16, 6), 4, Color(bright.r, bright.g, bright.b, 0.35))
	draw_circle(Vector2(-16, 6), 1.5, Color(bright.r, bright.g, bright.b, 0.70))
	# Spectral sword (right) — glowing
	draw_line(Vector2(18, 0), Vector2(24, -14), Color(ghost.r, ghost.g, ghost.b, 0.80), 2.5)
	draw_rect(Rect2(22, -26, 4, 14), Color(bright.r, bright.g, bright.b, 0.75))
	draw_rect(Rect2(23, -26, 2, 14), Color(1.0, 1.0, 1.0, 0.90))
	draw_rect(Rect2(18, -14, 12, 2.5), Color(ghost.r, ghost.g, ghost.b, 0.65))
	# Sword glow
	draw_circle(Vector2(24, -24), 3, Color(0.70, 0.90, 1.0, 0.40))
	# Head — ghostly helm
	draw_circle(Vector2(0, -16), 10, Color(ghost.r, ghost.g, ghost.b, 0.65))
	draw_circle(Vector2(0, -17), 8, Color(bright.r, bright.g, bright.b, 0.45))
	# Helm ridge
	draw_rect(Rect2(-1, -27, 2, 12), Color(ghost.r, ghost.g, ghost.b, 0.70))
	draw_colored_polygon(PackedVector2Array([Vector2(-3, -27), Vector2(3, -27), Vector2(0, -31)]),
		Color(ghost.r, ghost.g, ghost.b, 0.65))
	# Face — two piercing bright blue eyes
	draw_circle(Vector2(-3, -17), 3, Color(0.30, 0.80, 1.00, 0.95))
	draw_circle(Vector2( 3, -17), 3, Color(0.30, 0.80, 1.00, 0.95))
	draw_circle(Vector2(-3, -17), 1.5, Color(0.90, 0.97, 1.00))
	draw_circle(Vector2( 3, -17), 1.5, Color(0.90, 0.97, 1.00))
	# Ghost particle wisps rising
	var wt := _time * 1.2
	for wi in range(4):
		var wa := float(wi) * (TAU / 4.0) + wt
		var wr := 12.0 + sin(wt + float(wi)) * 2.0
		draw_circle(
			Vector2(cos(wa) * wr * 0.6, sin(wa) * wr * 0.5 - 4),
			1.5, Color(ghost.r, ghost.g, ghost.b, 0.35))

func _draw_dire_wolf() -> void:
	var c  := Color(0.20, 0.18, 0.22)
	var cl := Color(0.32, 0.28, 0.38)
	draw_circle(Vector2(8, 3),  13, c)
	draw_circle(Vector2(-1, 2), 12, c)
	draw_circle(Vector2(-1, -3), 9, cl)
	draw_circle(Vector2(0, -8), 7, c)
	draw_circle(Vector2(-4, -13), 3, c)
	draw_circle(Vector2( 4, -13), 3, c)
	draw_circle(Vector2(-2, -9), 1.5, Color(0.95, 0.10, 0.10))
	draw_circle(Vector2( 2, -9), 1.5, Color(0.95, 0.10, 0.10))
	draw_line(Vector2(12, 2), Vector2(16, -2), c, 2.5)
	draw_line(Vector2(16, -2), Vector2(14, -8), c, 2.0)

func _draw_elder_bear() -> void:
	var c  := Color(0.22, 0.14, 0.08)
	var cl := Color(0.38, 0.26, 0.16)
	draw_circle(Vector2(0, 4), 20, c)
	draw_circle(Vector2(-1, -1), 16, cl)
	draw_circle(Vector2(0, -9), 11, c)
	draw_circle(Vector2(-6, -16), 5, c)
	draw_circle(Vector2( 6, -16), 5, c)
	draw_circle(Vector2(-2, -10), 1.8, Color(0.06, 0.04, 0.02))
	draw_circle(Vector2( 2, -10), 1.8, Color(0.06, 0.04, 0.02))
	draw_circle(Vector2(-14, 2), 6, c)
	draw_circle(Vector2( 14, 2), 6, c)

func _draw_ancient_troll() -> void:
	# 1.8× scale + deep-forest palette. Base body first, then mossy-stone
	# shoulder plates + dark ivy vines coiling around the arms + a leather
	# harness with rune-carved pauldrons on top.
	_draw_troll_body(1.8, Color(0.22, 0.30, 0.16), false)
	# Mossy stone shoulder pauldrons — dark rock plates with a moss overlay.
	var stone := Color(0.35, 0.32, 0.28)
	var moss  := Color(0.35, 0.55, 0.28)
	var rune  := Color(0.98, 0.75, 0.20)
	# Left pauldron.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-22, -6), Vector2(-14, -14), Vector2(-8, -8), Vector2(-14, 4)]),
		stone)
	draw_circle(Vector2(-15, -6), 3.5, moss)
	# Right pauldron.
	draw_colored_polygon(PackedVector2Array([
		Vector2(22, -6), Vector2(14, -14), Vector2(8, -8), Vector2(14, 4)]),
		stone)
	draw_circle(Vector2(15, -6), 3.5, moss)
	# Rune glyph on the right pauldron.
	draw_line(Vector2(13, -8), Vector2(17, -4), rune, 1.5)
	draw_line(Vector2(17, -8), Vector2(13, -4), rune, 1.5)
	# Ivy vines coiling around the arms.
	var vine := Color(0.14, 0.35, 0.12)
	draw_line(Vector2(-22, 12), Vector2(-24, 20), vine, 2.5)
	draw_line(Vector2(-24, 20), Vector2(-20, 26), vine, 2.5)
	draw_line(Vector2(20, 10), Vector2(22, 18), vine, 2.5)
	draw_line(Vector2(22, 18), Vector2(18, 24), vine, 2.5)
	# Leather harness across the chest.
	var leather := Color(0.35, 0.20, 0.10)
	draw_line(Vector2(-14, 4), Vector2(14, 4), leather, 3.0)
	draw_line(Vector2(-8, -10), Vector2(-6, 10), leather, 2.5)
	draw_line(Vector2( 8, -10), Vector2( 6, 10), leather, 2.5)

func _draw_frost_wyrm() -> void:
	var c  := Color(0.55, 0.80, 0.96)
	var cl := Color(0.80, 0.94, 1.00)
	var cd := Color(0.22, 0.46, 0.72)
	draw_circle(Vector2(4, 5),   16, cd)
	draw_circle(Vector2(-3, -2), 13, c)
	draw_circle(Vector2(-4, -10), 9, c)
	draw_circle(Vector2(-4, -17), 6, cl)
	draw_circle(Vector2(-7, -11), 2.0, Color(0.10, 0.82, 0.96))
	draw_circle(Vector2(-1, -11), 2.0, Color(0.10, 0.82, 0.96))
	draw_line(Vector2(8, -4),  Vector2(15, -11), cl, 2.5)
	draw_line(Vector2(12, 2),  Vector2(19, -3),  cl, 2.5)
	draw_line(Vector2(14, 8),  Vector2(20, 4),   cl, 2.0)

func _draw_magma_elemental() -> void:
	var c  := Color(0.90, 0.30, 0.05)
	var cl := Color(1.00, 0.65, 0.10)
	var cd := Color(0.50, 0.08, 0.02)
	draw_circle(Vector2(0, 4),   18, cd)
	draw_circle(Vector2(-2, -1), 15, c)
	draw_circle(Vector2(3, -5),  11, cl)
	draw_circle(Vector2(-3, -9),  8, c)
	draw_circle(Vector2(0, -4),   5, Color(1.0, 0.95, 0.50))
	draw_circle(Vector2(-10, 6),  4, c)
	draw_circle(Vector2( 10, 4),  4, c)
	draw_circle(Vector2(-6, 10),  3, cd)
	draw_circle(Vector2( 6,  9),  3, cd)


func _draw_shark() -> void:
	# Sleek underwater silhouette. Semi-transparent so the water tile
	# shows through, reinforcing the "swimming below the surface" read.
	# ALPHA on every fill: 0.75 (body) / 0.60 (belly/fins) — combat hit
	# flashes still show correctly because white modulate stacks on top.
	var top := Color(0.20, 0.28, 0.38, 0.75)      # dark grey-blue back
	var side := Color(0.42, 0.50, 0.60, 0.75)     # mid-grey side
	var belly := Color(0.75, 0.80, 0.85, 0.60)    # pale underbelly
	var edge := Color(0.10, 0.15, 0.22, 0.85)     # sharp outline
	# Elongated body — draw as a series of overlapping ellipses growing
	# toward the head. Faces LEFT by default; _facing sign flip happens
	# via the Monster parent transform.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-16, 0), Vector2(-12, -4), Vector2(4, -6),
		Vector2(14, -1), Vector2(14, 3), Vector2(4, 5), Vector2(-12, 3)]),
		side)
	# Dark top stripe.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-15, -1), Vector2(-12, -4), Vector2(4, -6),
		Vector2(14, -1), Vector2(4, -2), Vector2(-12, -1)]),
		top)
	# Pale underbelly.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-15, 1), Vector2(-12, 3), Vector2(4, 5),
		Vector2(14, 3), Vector2(4, 2), Vector2(-12, 1)]),
		belly)
	# Dorsal fin — triangular peak on the back.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, -4), Vector2(-2, -12), Vector2(2, -4)]),
		top)
	# Pectoral fins — angled down/back.
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, 3), Vector2(-4, 8), Vector2(2, 5)]),
		side)
	# Tail fluke.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-16, 0), Vector2(-22, -5), Vector2(-19, 0),
		Vector2(-22, 5)]),
		side)
	# Eye and mouth line.
	draw_circle(Vector2(10, -2), 1.2, Color(0.05, 0.05, 0.05, 0.9))
	draw_line(Vector2(8, 2), Vector2(14, 0), edge, 1.2)
	# Silhouette outline for readability against water.
	draw_line(Vector2(-16, 0), Vector2(-12, -4), edge, 1.0)
	draw_line(Vector2(-12, -4), Vector2(4, -6), edge, 1.0)
	draw_line(Vector2(4, -6), Vector2(14, -1), edge, 1.0)
	draw_line(Vector2(14, 3), Vector2(4, 5), edge, 1.0)
	draw_line(Vector2(4, 5), Vector2(-12, 3), edge, 1.0)
	draw_line(Vector2(-12, 3), Vector2(-16, 0), edge, 1.0)


# ── Troll biome variants (playtest fix pack) ─────────────────────────────────

func _draw_swamp_troll() -> void:
	# Murky green swamp troll — wet-looking sickly skin, reeds hanging
	# from limbs, muddy slime drip patches.
	_draw_troll_body(1.6, Color(0.22, 0.34, 0.20), false)
	# Slime drips — dark green translucent blobs.
	var slime := Color(0.20, 0.32, 0.10, 0.85)
	draw_circle(Vector2(-14, 24), 2.5, slime)
	draw_circle(Vector2(14, 22), 2.0, slime)
	draw_circle(Vector2(-4, 28), 1.5, slime)
	# Reeds hanging from arms — thin brown/green vertical lines.
	var reed := Color(0.42, 0.48, 0.16)
	for i in range(3):
		var lx := -22.0 + float(i) * 4.0
		draw_line(Vector2(lx, 24), Vector2(lx + 1, 34), reed, 1.5)
	for i in range(3):
		var rx := 20.0 - float(i) * 4.0
		draw_line(Vector2(rx, 22), Vector2(rx - 1, 32), reed, 1.5)
	# Mud splash on the chest.
	draw_circle(Vector2(-4, 6), 3.5, Color(0.30, 0.22, 0.12, 0.80))
	# Bulging swamp eyes — extra bright yellow-green.
	draw_circle(Vector2(-9, -24), 2.0, Color(0.72, 0.98, 0.30, 0.95))
	draw_circle(Vector2( 3, -24), 2.0, Color(0.72, 0.98, 0.30, 0.95))


func _draw_ice_troll() -> void:
	# Frost-cold troll — blue-white skin, icicle spikes on shoulders,
	# frozen breath puffing from the mouth.
	_draw_troll_body(1.7, Color(0.55, 0.72, 0.85), false)
	# Icicle spikes on the shoulders — pointing downward.
	var ice := Color(0.85, 0.95, 1.0)
	var ice_dk := Color(0.55, 0.72, 0.88)
	for i in range(4):
		var ix := -18.0 + float(i) * 5.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(ix - 1, -8), Vector2(ix + 1, -8),
			Vector2(ix, -1)]), ice)
	for i in range(4):
		var ix := 8.0 + float(i) * 5.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(ix - 1, -8), Vector2(ix + 1, -8),
			Vector2(ix, -1)]), ice)
	# Frost patches on the body.
	draw_circle(Vector2(-6, 8), 3.0, ice_dk)
	draw_circle(Vector2( 8, 12), 2.5, ice_dk)
	# Frozen breath — soft white puff from the mouth.
	draw_circle(Vector2(-4, -6), 3.0, Color(1.0, 1.0, 1.0, 0.60))
	draw_circle(Vector2(-8, -4), 2.0, Color(1.0, 1.0, 1.0, 0.45))
	# Ice-glow eyes — sharp cyan.
	draw_circle(Vector2(-9, -24), 2.0, Color(0.55, 0.92, 1.0))
	draw_circle(Vector2( 3, -24), 2.0, Color(0.55, 0.92, 1.0))


func _draw_cave_troll() -> void:
	# Grey stone-textured troll — cavern-dwelling, rocky knuckles,
	# glowing red eyes that read at any zoom.
	_draw_troll_body(1.7, Color(0.42, 0.40, 0.36), true)
	# Rocky knuckles — angular chunks on the hands.
	var rock := Color(0.28, 0.26, 0.22)
	var rock_hi := Color(0.55, 0.52, 0.46)
	# Left hand rock chunks.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-32, 22), Vector2(-28, 30), Vector2(-24, 26), Vector2(-26, 22)]),
		rock)
	draw_circle(Vector2(-30, 26), 2.0, rock_hi)
	# Right hand rock chunks.
	draw_colored_polygon(PackedVector2Array([
		Vector2(26, 20), Vector2(30, 28), Vector2(24, 26), Vector2(22, 22)]),
		rock)
	draw_circle(Vector2(26, 24), 2.0, rock_hi)
	# Stone plates on the back/shoulders.
	draw_circle(Vector2(-8, -8), 3.5, rock)
	draw_circle(Vector2( 6, -8), 3.5, rock)
	# Cracked stone chest plate.
	draw_rect(Rect2(-8, 2, 16, 8), rock)
	draw_line(Vector2(-6, 4), Vector2(6, 8), Color(0.20, 0.18, 0.14), 1.5)
	# Glowing red eyes — huge and menacing for cave darkness.
	draw_circle(Vector2(-9, -24), 3.0, Color(1.0, 0.20, 0.10))
	draw_circle(Vector2( 3, -24), 3.0, Color(1.0, 0.20, 0.10))
	draw_circle(Vector2(-9, -24), 1.2, Color(1.0, 0.85, 0.72))
	draw_circle(Vector2( 3, -24), 1.2, Color(1.0, 0.85, 0.72))
