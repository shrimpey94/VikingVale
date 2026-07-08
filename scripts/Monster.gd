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
		"chicken":
			display_name = "Chicken";        level = 1;  max_hp = 3;   attack = 1;  defense = 0;  xp_reward = 3
			loot = [{"id":"feather","name":"Feather","qty":1,"color":Color(0.95,0.94,0.88)},
				{"id":"raw_chicken","name":"Raw Chicken","qty":1,"color":Color(0.92,0.80,0.62)}]
		"wolf":
			display_name = "Wolf";           level = 6;  max_hp = 18;  attack = 8;  defense = 2;  xp_reward = 20
			loot = [{"id":"wolf_pelt","name":"Wolf Pelt","qty":1,"color":Color(0.55,0.52,0.48)},
				{"id":"raw_meat","name":"Raw Meat","qty":1,"color":Color(0.78,0.30,0.28)}]
		"bandit":
			display_name = "Bandit";         level = 15; max_hp = 35;  attack = 13; defense = 6;  xp_reward = 45
			loot = [{"id":"bandit_hood","name":"Bandit Hood","qty":1,"color":Color(0.15,0.12,0.10)}]
			gold_min = 100;  gold_max = 2000
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
		"spider":
			display_name = "Spider";         level = 24; max_hp = 45;  attack = 19; defense = 4;  xp_reward = 65
			loot = [{"id":"spider_silk","name":"Spider Silk","qty":1,"color":Color(0.85,0.85,0.88)}]
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
		"lava_crawler":
			display_name = "Lava Crawler";   level = 60; max_hp = 140; attack = 48; defense = 22; xp_reward = 240
			loot = [{"id":"lava_carapace","name":"Lava Carapace","qty":1,"color":Color(0.80,0.30,0.05)}]
		"fire_giant":
			display_name = "Fire Giant";     level = 65; max_hp = 180; attack = 55; defense = 28; xp_reward = 300
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
		"frost_wyrm":
			display_name = "Frost Wyrm";      level = 62; max_hp = 190; attack = 50; defense = 25; xp_reward = 310
			loot = [{"id":"ice_shard","name":"Ice Shard","qty":1,"color":Color(0.55,0.80,0.95)}]
		"magma_elemental":
			display_name = "Magma Elemental"; level = 76; max_hp = 240; attack = 68; defense = 32; xp_reward = 430
			loot = [{"id":"giant_ember","name":"Giant Ember","qty":1,"color":Color(0.90,0.30,0.05)}]
	current_hp = max_hp

func scale_to_level(lv: int) -> void:
	var ratio := float(lv) / float(maxi(1, level))
	level     = lv
	max_hp    = maxi(5, roundi(float(max_hp) * ratio))
	current_hp = max_hp
	attack    = maxi(1, roundi(float(attack) * ratio))
	defense   = maxi(0, roundi(float(defense) * ratio))
	xp_reward = maxi(1, roundi(float(xp_reward) * ratio))

func _setup_collision() -> void:
	var cs   := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null:
		cs = CollisionShape2D.new()
		add_child(cs)
	var circ := CircleShape2D.new()
	match monster_type:
		"nidhogg": circ.radius = 22.0
		"draugr":  circ.radius = 16.0
		_:         circ.radius = 12.0
	cs.shape = circ

func _process(delta: float) -> void:
	_time += delta
	if _hit_flash > 0.0:
		_hit_flash -= delta
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

# ── Drawing ───────────────────────────────────────────────────────────────────
func _draw() -> void:
	if not is_alive:
		_draw_dead()
		return
	_draw_shadow()
	# Walking animation: stronger bob + a small horizontal sway when moving so
	# the body visibly steps rather than glides along. Idle uses the original
	# gentle breathing bob so a stationary monster doesn't look frozen.
	var bob: float
	var sway: float
	if _moving_anim:
		bob  = sin(_walk_time * 9.0) * 2.0
		sway = sin(_walk_time * 4.5) * 1.2
	else:
		bob  = sin(_time * 2.2) * 1.5
		sway = 0.0
	# Hit reaction — recoil shake while the damage flash is active.
	# Shake formula re-normalized for the shorter 0.10s flash window so the
	# motion still feels punchy rather than imperceptible.
	var shake := 0.0
	if _hit_flash > 0.0:
		shake = sin(_hit_flash * 120.0) * (_hit_flash / 0.10) * 3.0
	draw_set_transform(Vector2(shake + sway, bob), 0.0, Vector2.ONE)
	_draw_outline()
	match monster_type:
		"rat":            _draw_rat()
		"skeleton":       _draw_skeleton()
		"goblin":         _draw_goblin()
		"draugr":         _draw_draugr()
		"nidhogg":        _draw_nidhogg()
		"chicken":        _draw_chicken()
		"wolf":           _draw_wolf()
		"bandit":         _draw_bandit()
		"bear":           _draw_bear()
		"troll":          _draw_troll()
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
func _draw_shadow() -> void:
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
		"rat":                           return Vector2(9.0, 4.5)
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
		# Giant humanoids — large round oval
		"troll":                         return Vector2(16.0, 7.5)
		"ancient_troll":                 return Vector2(18.0, 8.5)
		"frost_giant", "fire_giant":     return Vector2(19.0, 9.0)
		# Spider — wider leggy footprint than tall
		"spider":                        return Vector2(15.0, 8.5)
		# Crawlers / serpents — very long horizontal
		"lava_crawler":                  return Vector2(18.0, 6.0)
		"frost_wyrm":                    return Vector2(22.0, 7.0)
		# Magma elemental — round ball, near-circular shadow
		"magma_elemental":               return Vector2(14.0, 10.0)
		# Boss — winged dragon, very wide
		"nidhogg":                       return Vector2(25.0, 10.0)
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
		"nidhogg":                    return 22.0
		"frost_giant", "fire_giant":  return 22.0
		"draugr":                     return 16.0
		"lava_crawler":               return 16.0
		"troll", "bear":              return 18.0
		"goblin", "skeleton":         return 13.0
		"forest_spirit":              return 13.0
		"ice_wolf":                   return 13.0
		"spider":                     return 14.0
		"ice_draugr", "shadow_draugr", "death_knight": return 15.0
		"spectral_warrior":           return 14.0
		"wolf", "bandit":             return 12.0
		"fire_imp":                   return 10.0
		"chicken":                    return 7.0
		"dire_wolf":                  return 14.0
		"elder_bear":                 return 20.0
		"ancient_troll":              return 20.0
		"frost_wyrm":                 return 18.0
		"magma_elemental":            return 18.0
		_:                            return 10.0

func _draw_dead() -> void:
	# Corpse silhouette only. The 16×8 black rect that used to draw above
	# the corpse was a label background for "DEAD" text that no longer
	# exists — it lingered as a floating black square over every corpse
	# until the respawn fired. Removed.
	draw_circle(Vector2.ZERO, _radius(), Color(0.2, 0.2, 0.2, 0.4))

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

func _draw_rat() -> void:
	var c  := Color(0.55, 0.38, 0.22)
	var cl := Color(0.65, 0.48, 0.30)
	# Tail
	draw_line(Vector2(8, 3), Vector2(14, 8), c, 1.5)
	draw_line(Vector2(14, 8), Vector2(16, 14), c, 1.5)
	draw_line(Vector2(16, 14), Vector2(14, 18), c, 1.5)
	# Body with fur layers
	draw_circle(Vector2(0, 2), 9, c)
	draw_circle(Vector2(-2, 0), 7, cl)
	draw_circle(Vector2(0, -5), 6, c)
	draw_circle(Vector2(1, -6), 4, cl)
	# Fur texture — short directional strokes
	var fc := c.darkened(0.22)
	draw_line(Vector2(-6, 2), Vector2(-4, -1), fc, 1.0)
	draw_line(Vector2(-2, 4), Vector2( 0,  1), fc, 1.0)
	draw_line(Vector2( 2, 3), Vector2( 4,  0), fc, 1.0)
	draw_line(Vector2(-3, -1), Vector2(-1, -4), fc, 1.0)
	draw_line(Vector2( 1, -2), Vector2( 3, -5), fc, 1.0)
	draw_line(Vector2(-5, -3), Vector2(-7,  0), fc, 1.0)
	# Belly highlight
	draw_circle(Vector2(-1, 3), 4.5, Color(0.72, 0.58, 0.40, 0.45))
	# Head shine
	draw_circle(Vector2(0, -7), 2.0, cl.lightened(0.18))
	# Ears
	draw_colored_polygon(PackedVector2Array([Vector2(-6, -9), Vector2(-9, -15), Vector2(-3, -12)]), c)
	draw_circle(Vector2(-6, -12), 2.0, Color(0.78, 0.52, 0.52))
	draw_colored_polygon(PackedVector2Array([Vector2(5, -9), Vector2(8, -15), Vector2(2, -12)]), c)
	draw_circle(Vector2(5, -12), 2.0, Color(0.78, 0.52, 0.52))
	# Eyes
	draw_circle(Vector2(-2, -5), 1.5, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(2, -5), 1.5, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(-1.5, -5.5), 0.6, Color(1, 1, 1, 0.6))
	draw_circle(Vector2( 2.5, -5.5), 0.6, Color(1, 1, 1, 0.6))
	# Pink nose
	draw_circle(Vector2(0, -2), 1.5, Color(0.85, 0.50, 0.50))
	# Whiskers
	draw_line(Vector2(-1, -3), Vector2(-12, -5), Color(0.85, 0.82, 0.78, 0.70), 0.8)
	draw_line(Vector2(-1, -2), Vector2(-12, -1), Color(0.85, 0.82, 0.78, 0.70), 0.8)
	draw_line(Vector2(1, -3), Vector2(12, -5), Color(0.85, 0.82, 0.78, 0.70), 0.8)
	draw_line(Vector2(1, -2), Vector2(12, -1), Color(0.85, 0.82, 0.78, 0.70), 0.8)

func _draw_skeleton() -> void:
	var c  := Color(0.90, 0.88, 0.74)
	var cd := Color(0.60, 0.58, 0.44)
	# Tattered cloth hanging at waist
	draw_colored_polygon(PackedVector2Array([
		Vector2(-5, 6), Vector2(5, 6), Vector2(4, 16), Vector2(-4, 16)]),
		Color(0.38, 0.30, 0.16, 0.60))
	draw_line(Vector2(-3, 6), Vector2(-4, 16), Color(0.28, 0.22, 0.10, 0.50), 1.0)
	draw_line(Vector2( 2, 6), Vector2( 3, 16), Color(0.28, 0.22, 0.10, 0.50), 1.0)
	# Legs
	draw_line(Vector2(-2, 7), Vector2(-4, 18), c, 2.5)
	draw_line(Vector2(2, 7), Vector2(4, 18), c, 2.5)
	draw_line(Vector2(-4, 18), Vector2(-3, 22), c, 2.0)
	draw_line(Vector2(4, 18), Vector2(3, 22), c, 2.0)
	draw_circle(Vector2(-4, 18), 2.0, cd)
	draw_circle(Vector2(4, 18), 2.0, cd)
	draw_circle(Vector2(-4, 18), 0.9, c.lightened(0.2))   # joint highlight
	draw_circle(Vector2( 4, 18), 0.9, c.lightened(0.2))
	# Arms
	draw_line(Vector2(-3, -5), Vector2(-9, 2), c, 2.0)
	draw_line(Vector2(3, -5), Vector2(9, 2), c, 2.0)
	draw_circle(Vector2(-9, 2), 1.8, cd)
	draw_circle(Vector2(-9, 2), 0.7, c.lightened(0.2))
	# Rusty sword (right hand)
	draw_rect(Rect2(7, -4, 3, 14), Color(0.62, 0.50, 0.38))
	draw_rect(Rect2(5, -4, 7, 2), cd)
	draw_rect(Rect2(8, -4, 1, 14), Color(0.74, 0.60, 0.44))   # blade edge shine
	# Torso with ribcage
	draw_rect(Rect2(-3, -7, 6, 14), c)
	for ri in range(4):
		draw_line(Vector2(-3, -5.0 + ri * 3.0), Vector2(3, -5.0 + ri * 3.0), cd, 1.0)
	# Rib crack
	draw_line(Vector2(-1, -5), Vector2(1, -2), cd.darkened(0.3), 1.0)
	# Skull
	draw_circle(Vector2(0, -14), 7, c)
	draw_circle(Vector2(0, -14), 5, c.lightened(0.05))
	draw_circle(Vector2(-2, -17), 1.8, c.lightened(0.25))   # skull dome highlight
	# Eye sockets (dark holes)
	draw_circle(Vector2(-2.5, -14), 2.0, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(2.5, -14), 2.0, Color(0.05, 0.05, 0.05))
	# Nasal cavity
	draw_colored_polygon(PackedVector2Array([Vector2(-1, -10), Vector2(1, -10), Vector2(0, -8)]),
		Color(0.05, 0.05, 0.05))
	# Teeth
	for ti in range(3):
		draw_rect(Rect2(float(-3 + ti * 2), -8.0, 1.0, 2.0), c)

func _draw_goblin() -> void:
	var c  := Color(0.22, 0.58, 0.18)
	var cd := c.darkened(0.35)
	# Legs
	draw_line(Vector2(-3, 14), Vector2(-4, 22), c, 2.5)
	draw_line(Vector2(3, 14), Vector2(4, 22), c, 2.5)
	# Body
	draw_circle(Vector2(0, 4), 10, c)
	draw_circle(Vector2(-2, 2), 7, c.lightened(0.08))
	# Belly shading
	draw_circle(Vector2(0, 7), 5, c.darkened(0.12))
	# Leather armor vest
	draw_rect(Rect2(-6, -3, 12, 10), Color(0.28, 0.18, 0.08))
	draw_rect(Rect2(-4, -2, 8, 7), Color(0.35, 0.22, 0.10))
	# Armor stitching + rivets
	draw_line(Vector2(0, -3), Vector2(0, 7), Color(0.20, 0.12, 0.04, 0.65), 1.0)
	draw_circle(Vector2(-4, -1), 1.2, Color(0.65, 0.50, 0.18))
	draw_circle(Vector2( 4, -1), 1.2, Color(0.65, 0.50, 0.18))
	draw_circle(Vector2(-4,  4), 1.2, Color(0.65, 0.50, 0.18))
	draw_circle(Vector2( 4,  4), 1.2, Color(0.65, 0.50, 0.18))
	# Belt + buckle
	draw_rect(Rect2(-6, 6, 12, 2), Color(0.35, 0.22, 0.08))
	draw_rect(Rect2(-2, 5, 4, 4), Color(0.60, 0.45, 0.15))
	# Head
	draw_circle(Vector2(0, -8), 8, c)
	draw_circle(Vector2(1, -9), 6, c.lightened(0.05))
	draw_circle(Vector2(-2, -12), 2.5, c.lightened(0.18))  # head shine
	# Pointy ears
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -10), Vector2(-14, -16), Vector2(-6, -6)]), c)
	draw_colored_polygon(PackedVector2Array([Vector2(8, -10), Vector2(14, -16), Vector2(6, -6)]), c)
	# Ear vein
	draw_line(Vector2(-9, -11), Vector2(-11, -14), c.darkened(0.25), 0.8)
	draw_line(Vector2( 9, -11), Vector2( 11, -14), c.darkened(0.25), 0.8)
	# Arms
	draw_line(Vector2(-6, 0), Vector2(-12, 6), c, 2.5)
	draw_line(Vector2(6, 0), Vector2(12, 4), c, 2.5)
	# Wooden club (right hand)
	draw_rect(Rect2(11, 0, 4, 12), Color(0.45, 0.28, 0.08))
	draw_rect(Rect2(9, 0, 8, 5), Color(0.50, 0.32, 0.10))
	draw_line(Vector2(13, 1), Vector2(13, 11), Color(0.30, 0.18, 0.04, 0.50), 1.0)  # club grain
	# Evil red eyes
	draw_circle(Vector2(-3, -9), 2, Color(0.88, 0.10, 0.10))
	draw_circle(Vector2(3, -9), 2, Color(0.88, 0.10, 0.10))
	draw_circle(Vector2(-2.5, -9.5), 0.8, Color(1, 1, 1, 0.5))
	draw_circle(Vector2( 3.5, -9.5), 0.8, Color(1, 1, 1, 0.5))
	# Mouth / wart
	draw_rect(Rect2(-3, -5, 6, 2), cd)
	draw_circle(Vector2(2.0, -6.0), 1.2, c.darkened(0.2))

func _draw_draugr() -> void:
	var c  := Color(0.30, 0.35, 0.55)
	var cl := c.lightened(0.25)
	var fr := Color(0.55, 0.80, 1.00, 0.30)  # frost
	# Frost aura
	draw_circle(Vector2(0, 0), 20.0, Color(0.55, 0.80, 1.0, 0.10))
	# Legs
	draw_line(Vector2(-5, 13), Vector2(-6, 24), c, 3.0)
	draw_line(Vector2(5, 13), Vector2(6, 24), c, 3.0)
	# Body armor
	draw_rect(Rect2(-8, -5, 16, 18), c)
	draw_rect(Rect2(-6, -4, 12, 14), cl.darkened(0.2))
	# Rune marks on chest
	draw_line(Vector2(-4, 0), Vector2(4, 0), fr, 1.5)
	draw_line(Vector2(0, -4), Vector2(0, 4), fr, 1.5)
	draw_line(Vector2(-3, -3), Vector2(3, 3), fr, 1.0)
	# Left arm + shield
	draw_line(Vector2(-8, -3), Vector2(-14, 6), c, 3.0)
	draw_circle(Vector2(-14.0, 4.0), 6.0, cl)
	draw_circle(Vector2(-14.0, 4.0), 4.0, c)
	draw_circle(Vector2(-14.0, 4.0), 1.5, Color(0.85, 0.75, 0.25))
	# Right arm + glowing sword
	draw_line(Vector2(8, -3), Vector2(18, -2), c, 3.0)
	draw_line(Vector2(18, -2), Vector2(18, 10), cl, 1.5)
	draw_rect(Rect2(17, -12, 3, 14), Color(0.58, 0.62, 0.80))
	draw_rect(Rect2(15, -12, 7, 2), Color(0.70, 0.65, 0.45))
	draw_line(Vector2(18, -12), Vector2(18, -20), Color(0.70, 0.85, 1.0, 0.60), 1.5)
	# Head
	draw_circle(Vector2(0, -12), 9, c)
	# Viking helmet
	draw_rect(Rect2(-8, -22, 16, 12), cl)
	draw_rect(Rect2(-6, -21, 12, 3), c.lightened(0.35))
	draw_rect(Rect2(-1, -22, 2, 12), c.lightened(0.35))
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -18), Vector2(-13, -12), Vector2(-4, -12)]), cl)
	draw_colored_polygon(PackedVector2Array([Vector2(8, -18), Vector2(13, -12), Vector2(4, -12)]), cl)
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

func _draw_nidhogg() -> void:
	var c  := Color(0.12, 0.48, 0.28)
	var cd := c.darkened(0.3)
	var ce := Color(0.95, 0.35, 0.05)
	var cy := Color(0.90, 0.90, 0.20)

	# Wings (behind body)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, -2), Vector2(-32, -18), Vector2(-28, 2),
		Vector2(-22, 8), Vector2(-14, 6)]), cd)
	draw_colored_polygon(PackedVector2Array([
		Vector2(14, -2), Vector2(32, -18), Vector2(28, 2),
		Vector2(22, 8), Vector2(14, 6)]), cd)
	# Wing veins
	draw_line(Vector2(-14, -2), Vector2(-30, -14), c.lightened(0.05), 1.0)
	draw_line(Vector2(-14, 0), Vector2(-26, 4), c.lightened(0.05), 1.0)
	draw_line(Vector2(14, -2), Vector2(30, -14), c.lightened(0.05), 1.0)
	draw_line(Vector2(14, 0), Vector2(26, 4), c.lightened(0.05), 1.0)

	# Body
	draw_circle(Vector2(0, 0), 20, cd)
	draw_circle(Vector2(0, -2), 17, c)

	# Scale pattern (overlapping arcs)
	for si in range(4):
		for sj in range(3):
			var sx := -9.0 + sj * 9.0
			var sy := -6.0 + si * 6.0
			draw_arc(Vector2(sx, sy), 4.5, PI, TAU, 6, cd, 1.2)

	# Spine spikes (back)
	for spi in range(5):
		var spx := -8.0 + spi * 4.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(spx - 2, -18), Vector2(spx + 2, -18), Vector2(spx, -26)]), cy)

	# Tail
	draw_line(Vector2(0, 18), Vector2(8, 26), cd, 5.0)
	draw_line(Vector2(8, 26), Vector2(12, 34), cd, 3.5)
	draw_colored_polygon(PackedVector2Array([
		Vector2(10, 32), Vector2(16, 38), Vector2(14, 42), Vector2(8, 36)]), cy)

	# Head
	draw_circle(Vector2(0, -8), 13, c)
	draw_circle(Vector2(0, -10), 10, c.lightened(0.08))
	# Horns
	draw_colored_polygon(PackedVector2Array([Vector2(-6, -18), Vector2(-10, -28), Vector2(-2, -22)]), cy)
	draw_colored_polygon(PackedVector2Array([Vector2(6, -18), Vector2(10, -28), Vector2(2, -22)]), cy)
	# Eyes — fiery glow
	draw_circle(Vector2(-5, -10), 3.5, ce)
	draw_circle(Vector2(5, -10), 3.5, ce)
	draw_circle(Vector2(-5, -10), 1.5, Color(1, 0.95, 0.40, 0.90))
	draw_circle(Vector2(5, -10), 1.5, Color(1, 0.95, 0.40, 0.90))
	# Scale highlight row
	for si in range(3):
		var sx := -6.0 + float(si) * 6.0
		draw_arc(Vector2(sx, -4.0), 2.8, PI, TAU, 5, c.lightened(0.22), 1.0)
	# Wing membrane cross-veins
	draw_line(Vector2(-22, -8), Vector2(-18,  4), c.lightened(0.08), 0.8)
	draw_line(Vector2( 22, -8), Vector2( 18,  4), c.lightened(0.08), 0.8)
	# Fire breath / snout glow
	draw_circle(Vector2(0, -4), 4.0, Color(1.00, 0.50, 0.05, 0.35))
	draw_circle(Vector2(0, -2), 2.5, Color(1.00, 0.75, 0.10, 0.45))
	# Ember sparks
	draw_circle(Vector2(-4.0, -8.0), 1.2, Color(1.0, 0.80, 0.10, 0.65))
	draw_circle(Vector2( 5.0, -6.0), 0.9, Color(1.0, 0.60, 0.05, 0.55))
	draw_circle(Vector2( 0.0,-10.0), 1.0, Color(1.0, 0.90, 0.30, 0.60))

func _draw_chicken() -> void:
	var white := Color(0.95, 0.94, 0.90)
	var cream := Color(0.88, 0.86, 0.80)
	# Body — round white blob
	draw_circle(Vector2(0, 2), 7, white)
	draw_circle(Vector2(0, 0), 5, cream)
	# Head
	draw_circle(Vector2(0, -8), 4, white)
	# Red comb — three bumps on top
	draw_circle(Vector2(-2, -13), 2.0, Color(0.85, 0.12, 0.12))
	draw_circle(Vector2( 0, -14), 2.5, Color(0.85, 0.12, 0.12))
	draw_circle(Vector2( 2, -13), 2.0, Color(0.85, 0.12, 0.12))
	# Red wattle
	draw_circle(Vector2(0, -5), 1.8, Color(0.80, 0.10, 0.10))
	# Yellow beak
	draw_colored_polygon(PackedVector2Array([Vector2(-2, -9), Vector2(2, -9), Vector2(0, -6)]),
		Color(0.95, 0.78, 0.10))
	# Eye
	draw_circle(Vector2(-1.5, -9), 1.2, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(-1.0, -9.4), 0.5, Color(1, 1, 1, 0.6))
	# Stick legs
	draw_line(Vector2(-2, 8), Vector2(-3, 16), Color(0.95, 0.75, 0.20), 1.5)
	draw_line(Vector2( 2, 8), Vector2( 3, 16), Color(0.95, 0.75, 0.20), 1.5)
	draw_line(Vector2(-3, 16), Vector2(-6, 18), Color(0.95, 0.75, 0.20), 1.5)
	draw_line(Vector2(-3, 16), Vector2(-2, 19), Color(0.95, 0.75, 0.20), 1.5)
	draw_line(Vector2( 3, 16), Vector2( 6, 18), Color(0.95, 0.75, 0.20), 1.5)
	draw_line(Vector2( 3, 16), Vector2( 2, 19), Color(0.95, 0.75, 0.20), 1.5)
	# Wing hint
	draw_arc(Vector2(3, 1), 5, -0.6, 1.0, 8, Color(0.78, 0.76, 0.70), 1.5)

func _draw_wolf() -> void:
	var grey  := Color(0.52, 0.50, 0.46)
	var dark  := Color(0.28, 0.26, 0.22)
	var light := Color(0.72, 0.70, 0.64)
	# Bushy tail curling up-right
	draw_line(Vector2(8, 5), Vector2(16, -2), grey, 4.0)
	draw_line(Vector2(16, -2), Vector2(18, -8), light, 3.0)
	draw_circle(Vector2(18, -9), 3.5, light)
	# Elongated body — quadruped shape
	draw_circle(Vector2(-2, 3), 10, grey)
	draw_circle(Vector2( 6, 2),  8, grey)
	draw_circle(Vector2(-4, 1),  7, light)
	# Belly (lighter underside)
	draw_circle(Vector2(0, 6), 6, Color(0.78, 0.76, 0.70, 0.6))
	# Four legs
	draw_line(Vector2(-6, 8), Vector2(-7, 18), dark, 2.5)
	draw_line(Vector2(-2, 9), Vector2(-2, 19), dark, 2.5)
	draw_line(Vector2( 4, 9), Vector2( 4, 19), dark, 2.5)
	draw_line(Vector2( 8, 8), Vector2( 9, 18), dark, 2.5)
	# Paws
	draw_circle(Vector2(-7, 18), 2.0, dark)
	draw_circle(Vector2(-2, 19), 2.0, dark)
	draw_circle(Vector2( 4, 19), 2.0, dark)
	draw_circle(Vector2( 9, 18), 2.0, dark)
	# Neck + head
	draw_line(Vector2(-6, -4), Vector2(-10, -10), grey, 5.0)
	draw_circle(Vector2(-10, -10), 6, grey)
	draw_circle(Vector2(-11, -12), 4, light)
	# Pointed snout
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, -10), Vector2(-20, -8), Vector2(-15, -5)]), grey)
	# Nose
	draw_circle(Vector2(-20, -8), 1.5, dark)
	# Ears
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -15), Vector2(-12, -22), Vector2(-5, -17)]), grey)
	draw_colored_polygon(PackedVector2Array([Vector2(-6, -15), Vector2(-4, -23), Vector2(-1, -17)]), grey)
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -15), Vector2(-12, -21), Vector2(-6, -17)]),
		Color(0.70, 0.50, 0.50, 0.5))
	# Eyes
	draw_circle(Vector2(-12, -11), 1.8, Color(0.88, 0.65, 0.10))
	draw_circle(Vector2(-12, -11), 0.8, Color(0.05, 0.05, 0.05))

func _draw_bandit() -> void:
	var cloth := Color(0.10, 0.10, 0.10)
	var brown := Color(0.28, 0.16, 0.06)
	# Cape/cloak back
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, -5), Vector2(8, -5), Vector2(12, 18), Vector2(-12, 18)]),
		Color(0.08, 0.06, 0.04))
	# Legs + boots
	draw_line(Vector2(-3, 12), Vector2(-4, 22), brown, 3.0)
	draw_line(Vector2( 3, 12), Vector2( 4, 22), brown, 3.0)
	draw_circle(Vector2(-4, 22), 2.5, brown.darkened(0.3))
	draw_circle(Vector2( 4, 22), 2.5, brown.darkened(0.3))
	# Body — dark tunic
	draw_rect(Rect2(-7, -6, 14, 18), cloth)
	draw_rect(Rect2(-5, -5, 10, 14), Color(0.15, 0.12, 0.10))
	# Belt
	draw_rect(Rect2(-7, 8, 14, 2), brown)
	draw_rect(Rect2(-2, 7, 4, 4), Color(0.65, 0.50, 0.15))
	# Arms
	draw_line(Vector2(-7, -2), Vector2(-12, 5), cloth, 3.5)
	draw_line(Vector2( 7, -2), Vector2( 12, 3), cloth, 3.5)
	# Dagger in right hand
	draw_rect(Rect2(11, -2, 2, 12), Color(0.75, 0.75, 0.80))
	draw_rect(Rect2(9, -2, 6, 2), brown)
	draw_rect(Rect2(12, -2, 1, 12), Color(0.92, 0.92, 0.95))
	# Hood (dark, pulled low)
	draw_circle(Vector2(0, -12), 9, cloth)
	draw_circle(Vector2(0, -14), 7, Color(0.08, 0.06, 0.04))
	# Shadow under hood hiding face — only eyes visible
	draw_circle(Vector2(0, -12), 7, Color(0.04, 0.04, 0.04, 0.85))
	# Glinting eyes in shadow
	draw_circle(Vector2(-3, -13), 1.5, Color(0.90, 0.70, 0.10))
	draw_circle(Vector2( 3, -13), 1.5, Color(0.90, 0.70, 0.10))
	# Hood rim highlight
	draw_arc(Vector2(0, -12), 9, PI + 0.3, TAU - 0.3, 10, Color(0.20, 0.18, 0.14), 1.5)

func _draw_bear() -> void:
	var brown := Color(0.45, 0.28, 0.10)
	var dark  := brown.darkened(0.35)
	var fur   := brown.lightened(0.12)
	# Massive round body
	draw_circle(Vector2(0, 4), 18, brown)
	draw_circle(Vector2(-2, 2), 14, fur)
	# Heavy shoulders/arms — thick limbs
	draw_circle(Vector2(-13, -2), 7, brown)
	draw_circle(Vector2( 13, -2), 7, brown)
	draw_line(Vector2(-13, -2), Vector2(-15, 12), dark, 6.0)
	draw_line(Vector2( 13, -2), Vector2( 15, 12), dark, 6.0)
	# Clawed paws
	draw_circle(Vector2(-15, 13), 5, dark)
	draw_circle(Vector2( 15, 13), 5, dark)
	for ci in range(3):
		draw_line(Vector2(-12 + float(ci) * 2, 16), Vector2(-13 + float(ci) * 2, 20),
			Color(0.88, 0.84, 0.78), 1.5)
		draw_line(Vector2( 12 + float(ci) * 2, 16), Vector2( 13 + float(ci) * 2, 20),
			Color(0.88, 0.84, 0.78), 1.5)
	# Legs
	draw_line(Vector2(-6, 18), Vector2(-7, 26), dark, 5.0)
	draw_line(Vector2( 6, 18), Vector2( 7, 26), dark, 5.0)
	# Belly lighter patch
	draw_circle(Vector2(0, 8), 8, Color(0.62, 0.45, 0.22, 0.5))
	# Head — round and large
	draw_circle(Vector2(0, -12), 11, brown)
	draw_circle(Vector2(0, -13), 9, fur)
	# Snout (muzzle protrusion)
	draw_circle(Vector2(0, -8), 5, fur.lightened(0.1))
	# Nose
	draw_circle(Vector2(0, -6), 2.5, dark)
	draw_circle(Vector2(-0.5, -6.8), 0.8, Color(0.6, 0.3, 0.3, 0.5))
	# Round ears
	draw_circle(Vector2(-8, -20), 4, brown)
	draw_circle(Vector2( 8, -20), 4, brown)
	draw_circle(Vector2(-8, -20), 2, dark)
	draw_circle(Vector2( 8, -20), 2, dark)
	# Eyes — small relative to head
	draw_circle(Vector2(-4, -14), 2, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2( 4, -14), 2, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2(-3.5, -14.5), 0.7, Color(1, 1, 1, 0.5))
	draw_circle(Vector2( 4.5, -14.5), 0.7, Color(1, 1, 1, 0.5))
	# Fur texture strokes on body
	var fc := brown.darkened(0.15)
	for fi in range(6):
		var fx := -10.0 + float(fi) * 4.0
		draw_line(Vector2(fx, 0), Vector2(fx + 1, 5), fc, 0.8)

func _draw_troll() -> void:
	var skin  := Color(0.32, 0.40, 0.22)
	var dark  := skin.darkened(0.35)
	var warty := skin.darkened(0.20)
	# Huge hunched body
	draw_circle(Vector2(0, 2), 18, skin)
	draw_circle(Vector2(-2, -2), 14, skin.lightened(0.06))
	# Hunchback bump
	draw_circle(Vector2(2, -12), 10, dark)
	# Long dangling arms nearly reaching ground
	draw_line(Vector2(-12, 0), Vector2(-18, 16), dark, 7.0)
	draw_line(Vector2( 12, 0), Vector2( 16, 14), dark, 7.0)
	# Big knuckled hands
	draw_circle(Vector2(-18, 17), 6, dark)
	draw_circle(Vector2( 16, 15), 6, dark)
	for ci in range(4):
		draw_circle(Vector2(-22 + float(ci) * 3, 15), 1.5, warty)
		draw_circle(Vector2( 12 + float(ci) * 3, 13), 1.5, warty)
	# Short thick legs
	draw_line(Vector2(-6, 16), Vector2(-7, 26), dark, 6.0)
	draw_line(Vector2( 6, 16), Vector2( 7, 26), dark, 6.0)
	draw_circle(Vector2(-7, 26), 5, dark)
	draw_circle(Vector2( 7, 26), 5, dark)
	# Wooden club raised in right hand
	draw_line(Vector2(14, 12), Vector2(22, -6), Color(0.40, 0.24, 0.08), 5.0)
	draw_circle(Vector2(22, -8), 7, Color(0.35, 0.20, 0.06))
	# Head — large and flat
	draw_circle(Vector2(-2, -14), 12, skin)
	draw_circle(Vector2(-3, -16), 9, skin.lightened(0.08))
	# Warts
	draw_circle(Vector2(-8, -12), 2, warty)
	draw_circle(Vector2( 4, -10), 1.5, warty)
	draw_circle(Vector2(-2, -18), 1.8, warty)
	draw_circle(Vector2( 6, -16), 1.2, warty)
	# Flat nose
	draw_circle(Vector2(-2, -11), 3.5, dark)
	draw_circle(Vector2(-4, -11), 1.5, Color(0.12, 0.08, 0.04))
	draw_circle(Vector2( 0, -11), 1.5, Color(0.12, 0.08, 0.04))
	# Small beady eyes
	draw_circle(Vector2(-6, -16), 2.5, Color(0.88, 0.55, 0.10))
	draw_circle(Vector2( 2, -16), 2.5, Color(0.88, 0.55, 0.10))
	draw_circle(Vector2(-6, -16), 1.0, Color(0.05, 0.05, 0.05))
	draw_circle(Vector2( 2, -16), 1.0, Color(0.05, 0.05, 0.05))
	# Protruding lower jaw / tusks
	draw_rect(Rect2(-8, -8, 14, 4), skin)
	draw_colored_polygon(PackedVector2Array([Vector2(-4, -5), Vector2(-3, -1), Vector2(-2, -5)]),
		Color(0.90, 0.87, 0.72))
	draw_colored_polygon(PackedVector2Array([Vector2(2, -5), Vector2(3, -1), Vector2(4, -5)]),
		Color(0.90, 0.87, 0.72))

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
	# Eight legs — radiating outward from center
	var leg_angles: Array[float] = [-1.2, -0.6, 0.0, 0.6, PI + 1.2, PI + 0.6, PI, PI - 0.6]
	for li in range(8):
		var la: float = leg_angles[li]
		var knee := Vector2(cos(la) * 10, sin(la) * 8)
		var foot := knee + Vector2(cos(la + 0.4) * 8, sin(la + 0.4) * 8)
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

func _draw_ice_wolf() -> void:
	var ice   := Color(0.60, 0.82, 0.96)
	var dark  := Color(0.25, 0.45, 0.65)
	var white := Color(0.88, 0.94, 0.98)
	# Glowing ice aura
	draw_circle(Vector2(0, 0), 16, Color(0.60, 0.85, 1.0, 0.10))
	# Tail with crystal shards at tip
	draw_line(Vector2(8, 4), Vector2(16, -4), ice, 4.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(15, -6), Vector2(18, -12), Vector2(20, -5)]), white)
	draw_colored_polygon(PackedVector2Array([
		Vector2(17, -4), Vector2(22, -8), Vector2(22, -2)]), Color(0.70, 0.90, 1.0, 0.75))
	# Angular body — more geometric than normal wolf
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, -2), Vector2(8, -4), Vector2(10, 8), Vector2(-8, 10)]), ice)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 0), Vector2(6, -2), Vector2(8, 6), Vector2(-6, 8)]), white)
	# Crystal spines along back
	for si in range(5):
		var sx := -8.0 + float(si) * 4.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(sx - 1.5, -4), Vector2(sx + 1.5, -4), Vector2(sx, -10)]),
			Color(0.78, 0.92, 1.0, 0.85))
	# Four angular legs
	draw_line(Vector2(-7, 7), Vector2(-8, 17), dark, 2.5)
	draw_line(Vector2(-2, 8), Vector2(-2, 18), dark, 2.5)
	draw_line(Vector2( 4, 8), Vector2( 4, 18), dark, 2.5)
	draw_line(Vector2( 8, 6), Vector2( 9, 16), dark, 2.5)
	draw_circle(Vector2(-8, 17), 2, dark)
	draw_circle(Vector2(-2, 18), 2, dark)
	draw_circle(Vector2( 4, 18), 2, dark)
	draw_circle(Vector2( 9, 16), 2, dark)
	# Head
	draw_circle(Vector2(-10, -8), 6, ice)
	draw_circle(Vector2(-11, -10), 4.5, white)
	# Angular snout
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, -8), Vector2(-20, -6), Vector2(-16, -4)]), ice)
	draw_circle(Vector2(-20, -6), 1.5, dark)
	# Icy ears (sharp crystal-like)
	draw_colored_polygon(PackedVector2Array([Vector2(-7, -13), Vector2(-10, -20), Vector2(-4, -15)]), ice)
	draw_colored_polygon(PackedVector2Array([Vector2(-5, -13), Vector2(-4, -21), Vector2(-1, -15)]), ice)
	# Eyes — glowing bright ice-blue
	draw_circle(Vector2(-12, -10), 2, Color(0.20, 0.90, 1.00))
	draw_circle(Vector2(-12, -10), 0.9, Color(0.90, 0.97, 1.0))
	# Breath mist
	draw_circle(Vector2(-18, -5), 2.5, Color(0.75, 0.90, 1.0, 0.25))

func _draw_frost_giant() -> void:
	var skin  := Color(0.62, 0.78, 0.90)
	var armor := Color(0.45, 0.62, 0.80)
	var ice   := Color(0.80, 0.94, 1.00)
	# Massive silhouette — huge humanoid
	draw_circle(Vector2(0, 0), 22, Color(0.40, 0.58, 0.78, 0.20))
	# Legs
	draw_line(Vector2(-8, 14), Vector2(-10, 28), armor, 7.0)
	draw_line(Vector2( 8, 14), Vector2( 10, 28), armor, 7.0)
	draw_circle(Vector2(-10, 28), 5.5, armor.darkened(0.3))
	draw_circle(Vector2( 10, 28), 5.5, armor.darkened(0.3))
	# Ice-plated torso
	draw_rect(Rect2(-12, -8, 24, 22), armor)
	draw_rect(Rect2(-10, -6, 20, 18), skin)
	# Ice plate seams
	draw_line(Vector2(-10, 2), Vector2(10, 2), ice, 1.5)
	draw_line(Vector2(-10, 8), Vector2(10, 8), ice, 1.5)
	draw_line(Vector2(0, -6), Vector2(0, 14), ice, 1.5)
	# Icicle decorations on shoulders
	for ii in range(3):
		var ix := -10.0 + float(ii) * 10.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(ix - 2, -8), Vector2(ix + 2, -8), Vector2(ix, -16)]),
			Color(ice.r, ice.g, ice.b, 0.80))
	# Arms — thick
	draw_line(Vector2(-12, -4), Vector2(-20, 8), armor, 8.0)
	draw_line(Vector2( 12, -4), Vector2( 22, 4), armor, 8.0)
	# Ice maul in right hand
	draw_line(Vector2(20, 2), Vector2(26, -14), Color(0.35, 0.28, 0.20), 4.0)
	draw_rect(Rect2(18, -22, 14, 10), ice)
	draw_rect(Rect2(16, -20, 18, 6), Color(0.68, 0.84, 0.95))
	# Head
	draw_circle(Vector2(0, -18), 13, skin)
	draw_circle(Vector2(0, -20), 10, skin.lightened(0.08))
	# Icicle beard — pointy downward spikes from chin
	for bi in range(5):
		var bx := -8.0 + float(bi) * 4.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(bx - 1.5, -8), Vector2(bx + 1.5, -8), Vector2(bx, -4)]),
			Color(ice.r, ice.g, ice.b, 0.85))
	# Eyes — cold glowing blue-white
	draw_circle(Vector2(-5, -20), 3, Color(0.20, 0.70, 1.00))
	draw_circle(Vector2( 5, -20), 3, Color(0.20, 0.70, 1.00))
	draw_circle(Vector2(-5, -20), 1.2, Color(0.85, 0.95, 1.0))
	draw_circle(Vector2( 5, -20), 1.2, Color(0.85, 0.95, 1.0))
	# Viking-style horned crown of ice
	draw_colored_polygon(PackedVector2Array([Vector2(-10, -28), Vector2(-14, -38), Vector2(-6, -30)]), ice)
	draw_colored_polygon(PackedVector2Array([Vector2(10, -28), Vector2(14, -38), Vector2(6, -30)]), ice)
	draw_rect(Rect2(-12, -30, 24, 4), armor)

func _draw_ice_draugr() -> void:
	var frost := Color(0.68, 0.86, 0.98)
	var dark  := Color(0.22, 0.35, 0.52)
	var ice   := Color(0.88, 0.96, 1.00, 0.85)
	# Ice encasement outer shell — crystalline shape
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, 22), Vector2(-12, 0), Vector2(-8, -20), Vector2(0, -25),
		Vector2(8, -20), Vector2(12, 0), Vector2(10, 22)]),
		Color(frost.r, frost.g, frost.b, 0.35))
	# Body beneath ice
	draw_rect(Rect2(-7, -6, 14, 18), dark)
	# Ice crystal facets on top
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, -5), Vector2(-8, -20), Vector2(0, -22), Vector2(8, -20), Vector2(10, -5)]),
		Color(frost.r, frost.g, frost.b, 0.55))
	# Frozen cracks across surface
	draw_line(Vector2(-5, -15), Vector2(3, -5), ice, 1.0)
	draw_line(Vector2(3, -5), Vector2(7, 0), ice, 0.8)
	draw_line(Vector2(-3, 0), Vector2(5, 10), ice, 1.0)
	draw_line(Vector2(-8, 8), Vector2(-2, 14), ice, 0.8)
	# Legs locked in frozen stance
	draw_line(Vector2(-4, 12), Vector2(-5, 22), dark, 3.0)
	draw_line(Vector2( 4, 12), Vector2( 5, 22), dark, 3.0)
	draw_colored_polygon(PackedVector2Array([Vector2(-8, 20), Vector2(-3, 20), Vector2(-4, 24)]),
		Color(frost.r, frost.g, frost.b, 0.6))
	draw_colored_polygon(PackedVector2Array([Vector2(3, 20), Vector2(8, 20), Vector2(4, 24)]),
		Color(frost.r, frost.g, frost.b, 0.6))
	# Frozen arm raised
	draw_line(Vector2(-7, 0), Vector2(-14, -8), dark, 3.5)
	draw_line(Vector2(7, 0), Vector2(16, -6), dark, 3.5)
	# Ice spike weapon
	draw_colored_polygon(PackedVector2Array([Vector2(14, -8), Vector2(18, -8), Vector2(16, -20)]),
		Color(ice.r, ice.g, ice.b, 0.90))
	# Head frozen in place
	draw_circle(Vector2(0, -14), 9, dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, -10), Vector2(-9, -20), Vector2(0, -23), Vector2(9, -20), Vector2(9, -10)]),
		Color(frost.r, frost.g, frost.b, 0.45))
	# Cold glowing eyes
	draw_circle(Vector2(-3, -15), 2.5, Color(0.50, 0.90, 1.00))
	draw_circle(Vector2( 3, -15), 2.5, Color(0.50, 0.90, 1.00))
	draw_circle(Vector2(-3, -15), 1.0, Color(0.90, 0.97, 1.0))
	draw_circle(Vector2( 3, -15), 1.0, Color(0.90, 0.97, 1.0))
	# Ice shard spikes on shoulders
	draw_colored_polygon(PackedVector2Array([Vector2(-9, -6), Vector2(-12, -6), Vector2(-10, -14)]),
		Color(ice.r, ice.g, ice.b, 0.80))
	draw_colored_polygon(PackedVector2Array([Vector2(9, -6), Vector2(12, -6), Vector2(10, -14)]),
		Color(ice.r, ice.g, ice.b, 0.80))

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
	var rock   := Color(0.22, 0.18, 0.14)
	var lava   := Color(1.00, 0.42, 0.05)
	var hot    := Color(1.00, 0.75, 0.20)
	# Long segmented body — centipede shape
	var seg_count := 6
	for si in range(seg_count):
		var sx := -18.0 + float(si) * 7.0
		var sy :=  sin(float(si) * 0.9) * 3.0
		var sr :=  6.0 - float(si) * 0.4
		draw_circle(Vector2(sx, sy), sr + 1, rock.darkened(0.2))
		draw_circle(Vector2(sx, sy), sr, rock)
		# Glowing lava cracks between segments
		if si < seg_count - 1:
			var nx := sx + 7.0
			var ny := sin(float(si + 1) * 0.9) * 3.0
			draw_line(Vector2(sx + sr * 0.6, sy), Vector2(nx - sr * 0.6, ny), lava, 1.5)
	# Lava glow seam along top of body
	for si in range(seg_count):
		var sx := -18.0 + float(si) * 7.0
		var sy :=  sin(float(si) * 0.9) * 3.0
		draw_arc(Vector2(sx, sy), 5.0 - float(si) * 0.3, PI + 0.5, TAU - 0.5, 6,
			Color(lava.r, lava.g, lava.b, 0.70), 2.0)
	# Pairs of legs along each segment
	for si in range(seg_count - 1):
		var sx := -14.0 + float(si) * 7.0
		var sy :=  sin(float(si) * 0.9) * 3.0
		draw_line(Vector2(sx, sy + 3), Vector2(sx - 4, sy + 10), rock, 2.0)
		draw_line(Vector2(sx, sy + 3), Vector2(sx + 4, sy + 10), rock, 2.0)
		draw_line(Vector2(sx - 4, sy + 10), Vector2(sx - 6, sy + 14), rock.lightened(0.1), 1.5)
		draw_line(Vector2(sx + 4, sy + 10), Vector2(sx + 6, sy + 14), rock.lightened(0.1), 1.5)
	# Head segment with mandibles
	draw_circle(Vector2(-20, 0), 8, rock)
	draw_circle(Vector2(-20, -1), 6, rock.lightened(0.12))
	draw_line(Vector2(-24, -2), Vector2(-30, -5), rock.darkened(0.1), 3.0)
	draw_line(Vector2(-24,  2), Vector2(-30,  6), rock.darkened(0.1), 3.0)
	draw_circle(Vector2(-30, -5), 2.5, rock)
	draw_circle(Vector2(-30,  6), 2.5, rock)
	# Eyes — hot orange glow
	draw_circle(Vector2(-22, -3), 2.5, lava)
	draw_circle(Vector2(-22, -3), 1.0, hot)
	draw_circle(Vector2(-18, -4), 2.0, lava)
	draw_circle(Vector2(-18, -4), 0.8, hot)
	# Inner lava glow on head
	draw_circle(Vector2(-20, 1), 3.5, Color(lava.r, lava.g, lava.b, 0.30))

func _draw_fire_giant() -> void:
	var fire   := Color(0.95, 0.38, 0.05)
	var hot    := Color(1.00, 0.90, 0.25)
	var ember  := Color(0.60, 0.12, 0.02)
	# Flames surrounding body (outermost)
	draw_circle(Vector2(0, 0), 25, Color(1.0, 0.30, 0.05, 0.12))
	draw_circle(Vector2(0, 0), 20, Color(1.0, 0.45, 0.08, 0.18))
	# Body — towering humanoid of solidified magma
	draw_rect(Rect2(-13, -8, 26, 22), ember)
	draw_rect(Rect2(-11, -6, 22, 18), fire)
	# Glowing lava cracks on torso
	draw_line(Vector2(-8, -4), Vector2(-2, 4), hot, 1.5)
	draw_line(Vector2(-2, 4), Vector2(4, 8), hot, 1.0)
	draw_line(Vector2(6, -5), Vector2(2, 2), hot, 1.5)
	draw_line(Vector2(2, 2), Vector2(8, 10), hot, 1.0)
	draw_line(Vector2(-5, 6), Vector2(5, 10), hot, 1.2)
	# Legs — thick pillars
	draw_line(Vector2(-8, 14), Vector2(-9, 28), ember, 8.0)
	draw_line(Vector2( 8, 14), Vector2( 9, 28), ember, 8.0)
	draw_circle(Vector2(-9, 28), 6, ember.darkened(0.2))
	draw_circle(Vector2( 9, 28), 6, ember.darkened(0.2))
	# Lava pools under feet
	draw_circle(Vector2(-9, 30), 7, Color(1.0, 0.45, 0.05, 0.35))
	draw_circle(Vector2( 9, 30), 7, Color(1.0, 0.45, 0.05, 0.35))
	# Arms — massive
	draw_line(Vector2(-13, -2), Vector2(-22, 8), ember, 9.0)
	draw_line(Vector2( 13, -2), Vector2( 24, 4), ember, 9.0)
	# Burning maul — right hand
	draw_line(Vector2(22, 2), Vector2(30, -16), Color(0.30, 0.22, 0.12), 5.0)
	draw_rect(Rect2(24, -28, 12, 14), ember)
	draw_rect(Rect2(22, -26, 16, 10), fire)
	# Fire emanating from maul
	draw_circle(Vector2(28, -26), 5, Color(1.0, 0.65, 0.10, 0.60))
	draw_circle(Vector2(30, -30), 4, Color(1.0, 0.85, 0.25, 0.40))
	# Left hand — open
	draw_circle(Vector2(-22, 10), 7, ember)
	# Flames rising from hand
	draw_colored_polygon(PackedVector2Array([
		Vector2(-22, 4), Vector2(-26, -4), Vector2(-22, -2), Vector2(-18, -6), Vector2(-18, 2)]),
		Color(1.0, 0.55, 0.08, 0.75))
	# Head
	draw_circle(Vector2(0, -20), 14, ember)
	draw_circle(Vector2(0, -22), 11, fire)
	# Molten face — eyes are intense bright cores
	draw_circle(Vector2(-5, -22), 4, Color(1.0, 0.85, 0.20))
	draw_circle(Vector2( 5, -22), 4, Color(1.0, 0.85, 0.20))
	draw_circle(Vector2(-5, -22), 2, hot)
	draw_circle(Vector2( 5, -22), 2, hot)
	# Crown of flames on head
	for fi in range(5):
		var fx := -8.0 + float(fi) * 4.0
		var fh := 6.0 + float(fi % 3) * 3.0
		draw_colored_polygon(PackedVector2Array([
			Vector2(fx - 2, -30), Vector2(fx + 2, -30), Vector2(fx, -30 - fh)]),
			Color(1.0, 0.65, 0.10, 0.80))
	# Ember sparks
	draw_circle(Vector2(-14, -10), 1.5, Color(1.0, 0.80, 0.20, 0.65))
	draw_circle(Vector2( 16, -8), 1.2, Color(1.0, 0.60, 0.05, 0.55))
	draw_circle(Vector2(  2, -32), 1.0, Color(1.0, 0.90, 0.30, 0.70))

func _draw_shadow_draugr() -> void:
	var shadow := Color(0.08, 0.04, 0.14)
	var void_c := Color(0.02, 0.00, 0.06)
	var purple := Color(0.55, 0.10, 0.80)
	# Shadow aura — barely defined edges
	draw_circle(Vector2(0, 0), 20, Color(0.10, 0.04, 0.16, 0.30))
	draw_circle(Vector2(0, 0), 16, Color(0.08, 0.02, 0.12, 0.50))
	# The form itself — dark blurred shape
	draw_circle(Vector2(0, 2), 14, shadow)
	draw_circle(Vector2(-1, 0), 11, void_c)
	# Wisps of shadow rising (tendrils)
	for wi in range(5):
		var wa := float(wi) * (TAU / 5.0) + _time * 0.5
		var wr := 10.0 + sin(_time * 2.0 + float(wi)) * 2.0
		draw_line(Vector2.ZERO,
			Vector2(cos(wa) * wr, sin(wa) * wr - 6),
			Color(shadow.r, shadow.g, shadow.b, 0.55), 2.5)
	# Limb suggestions — vague arm and leg shapes
	draw_line(Vector2(-8, 2), Vector2(-16, 12), shadow, 4.0)
	draw_line(Vector2( 8, 2), Vector2( 16, 10), shadow, 4.0)
	draw_line(Vector2(-4, 12), Vector2(-6, 22), shadow, 4.0)
	draw_line(Vector2( 4, 12), Vector2( 6, 22), shadow, 4.0)
	# Head — darker void shape
	draw_circle(Vector2(0, -12), 9, void_c)
	draw_circle(Vector2(0, -12), 7, shadow)
	# Glowing purple eyes — the only solid feature
	draw_circle(Vector2(-3, -13), 3, purple)
	draw_circle(Vector2( 3, -13), 3, purple)
	draw_circle(Vector2(-3, -13), 1.5, Color(0.80, 0.50, 1.00))
	draw_circle(Vector2( 3, -13), 1.5, Color(0.80, 0.50, 1.00))
	draw_circle(Vector2(-3, -13), 0.5, Color(1.0, 0.9, 1.0, 0.90))
	draw_circle(Vector2( 3, -13), 0.5, Color(1.0, 0.9, 1.0, 0.90))
	# Shadow wisps from head
	draw_line(Vector2(-4, -18), Vector2(-8, -26), Color(shadow.r, shadow.g, shadow.b, 0.45), 2.0)
	draw_line(Vector2( 4, -18), Vector2( 8, -26), Color(shadow.r, shadow.g, shadow.b, 0.45), 2.0)
	draw_line(Vector2( 0, -20), Vector2( 0, -28), Color(shadow.r, shadow.g, shadow.b, 0.35), 2.0)

func _draw_death_knight() -> void:
	var black := Color(0.06, 0.06, 0.08)
	var steel := Color(0.18, 0.20, 0.26)
	var glow  := Color(0.10, 0.90, 0.40)
	# Shadow aura
	draw_circle(Vector2(0, 0), 20, Color(0.05, 0.12, 0.08, 0.20))
	# Legs in black plate armor
	draw_line(Vector2(-5, 12), Vector2(-6, 24), steel, 5.0)
	draw_line(Vector2( 5, 12), Vector2( 6, 24), steel, 5.0)
	draw_circle(Vector2(-6, 24), 4, black)
	draw_circle(Vector2( 6, 24), 4, black)
	# Plate sabatons (boot caps)
	draw_rect(Rect2(-10, 22, 8, 4), steel)
	draw_rect(Rect2(  2, 22, 8, 4), steel)
	# Torso — full black plate
	draw_rect(Rect2(-10, -8, 20, 20), black)
	draw_rect(Rect2(-8, -6, 16, 16), steel)
	# Breastplate detail
	draw_line(Vector2(-6, -4), Vector2(6, -4), Color(glow.r, glow.g, glow.b, 0.30), 1.0)
	draw_line(Vector2(0, -6), Vector2(0, 6), Color(glow.r, glow.g, glow.b, 0.25), 1.0)
	# Rune on chest — glowing green
	draw_circle(Vector2(0, 0), 4, Color(glow.r, glow.g, glow.b, 0.15))
	draw_line(Vector2(-3, 0), Vector2(3, 0), glow, 1.2)
	draw_line(Vector2(0, -3), Vector2(0, 3), glow, 1.2)
	draw_line(Vector2(-2, -2), Vector2(2, 2), Color(glow.r, glow.g, glow.b, 0.60), 0.8)
	# Pauldrons (shoulder plates)
	draw_circle(Vector2(-12, -4), 6, steel)
	draw_circle(Vector2( 12, -4), 6, steel)
	draw_arc(Vector2(-12, -4), 6, PI, TAU, 8, black, 1.5)
	draw_arc(Vector2( 12, -4), 6, PI, TAU, 8, black, 1.5)
	# Arm + gauntlet
	draw_line(Vector2(-12, -4), Vector2(-18, 8), steel, 4.5)
	draw_line(Vector2( 12, -4), Vector2( 20, 4), steel, 4.5)
	draw_circle(Vector2(-18, 8), 4, black)
	draw_circle(Vector2( 20, 4), 4, black)
	# Greatsword — long dark blade
	draw_line(Vector2(18, 2), Vector2(24, -14), steel, 3.0)
	draw_rect(Rect2(22, -28, 4, 16), Color(0.25, 0.28, 0.35))
	draw_rect(Rect2(23, -28, 2, 16), Color(0.42, 0.45, 0.52))
	draw_rect(Rect2(19, -14, 10, 3), black)
	# Green rune glow on blade
	draw_line(Vector2(23, -26), Vector2(23, -18), Color(glow.r, glow.g, glow.b, 0.40), 1.0)
	# Full helm — closed visor
	draw_circle(Vector2(0, -18), 11, steel)
	draw_circle(Vector2(0, -19), 9, black)
	# Helm crest (ridge on top)
	draw_rect(Rect2(-1, -30, 2, 12), steel)
	draw_colored_polygon(PackedVector2Array([Vector2(-3, -30), Vector2(3, -30), Vector2(0, -34)]), steel)
	# Visor — T-slit with green glow
	draw_rect(Rect2(-7, -22, 14, 3), Color(0.04, 0.04, 0.06))
	draw_rect(Rect2(-1, -24, 2, 8), Color(0.04, 0.04, 0.06))
	# Eyes behind visor — green glow
	draw_circle(Vector2(-3, -21), 2.5, glow)
	draw_circle(Vector2( 3, -21), 2.5, glow)
	draw_circle(Vector2(-3, -21), 1.0, Color(0.70, 1.00, 0.80))
	draw_circle(Vector2( 3, -21), 1.0, Color(0.70, 1.00, 0.80))
	# Helm cheek plates
	draw_rect(Rect2(-10, -22, 4, 8), steel)
	draw_rect(Rect2(  6, -22, 4, 8), steel)

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
	var c  := Color(0.28, 0.36, 0.22)
	var cl := Color(0.40, 0.50, 0.32)
	draw_circle(Vector2(0, 5), 20, c)
	draw_circle(Vector2(0, -2), 16, cl)
	draw_circle(Vector2(0, -11), 12, c)
	draw_line(Vector2(-6, -19), Vector2(-10, -27), cl, 3.5)
	draw_line(Vector2( 6, -19), Vector2( 10, -27), cl, 3.5)
	draw_circle(Vector2(-3, -13), 2.2, Color(0.85, 0.20, 0.05))
	draw_circle(Vector2( 3, -13), 2.2, Color(0.85, 0.20, 0.05))
	draw_circle(Vector2(-15, 2), 6, c)
	draw_circle(Vector2( 15, 2), 6, c)

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
