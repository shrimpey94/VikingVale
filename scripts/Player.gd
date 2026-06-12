extends CharacterBody2D

const Boats       = preload("res://scripts/Boat.gd")
const SeaMonsters = preload("res://scripts/SeaMonsters.gd")
const Fishing     = preload("res://scripts/Fishing.gd")

const BASE_SPEED := 120.0
const TILE := 32.0
const INTERACT_RANGE  := 54.0
const MELEE_RANGE     := 40.0
const DISENGAGE_RANGE := 160.0
# Combat-style attack ranges. On melee, the engagement distance is computed
# per-monster from its shadow footprint (edge-to-edge gap of MELEE_EDGE_GAP);
# ranged and magic use a fixed cone the player must already be inside when
# clicking. Disengage extends each by 20% so a target nudging out a few
# pixels doesn't immediately break the fight.
const MELEE_EDGE_GAP  := 2.0     # px gap between player edge and monster edge
const PLAYER_RADIUS   := 8.0     # rough horizontal half-width of the sprite
const RANGED_RANGE    := 350.0
const MAGIC_RANGE     := 400.0

enum PlayerState { IDLE, MOVING, ACTING }

var _state            := PlayerState.IDLE
var _action_type      := ""       # "chop" | "mine" | "fish"
var _action_frame     := 0.0      # 0→1 per swing cycle
var _action_interval  := 2.5      # mirrors the target's swing_interval
var _target_pos       := Vector2.ZERO
var _target_interactable: Node = null
var _target_monster:  Node = null
var _in_combat:       bool = false
var _walk_time        := 0.0      # accumulates while MOVING for leg animation
var _ground:          Node = null  # cached reference to Ground node
var _footstep_frame:  int  = 0    # 0..3, ticks AudioManager.play_footstep on rollover

# ── Boat / sailing state ─────────────────────────────────────────────────────
var _sailing:         bool = false
var _boat_id:         String = ""
var _facing:          float = 1.0   # -1 left, 1 right (for boat sprite)
var _boat_prompt_kind: String = ""  # "" | "launch" | "dock"
var _boat_fishing:    bool = false
# True between a successful hook and the reel minigame closing. Blocks new
# catch rolls so the action loop can't stack reel modals while one is open.
var _reeling:         bool = false
# True while the boat-combat modal is open (Phase 3). Same gating idea as
# _reeling — the action loop must not roll fresh casts during an encounter.
var _in_sea_combat:   bool = false
# Phase 4 — boss IDs the player has cleared during this sailing session.
# Prevents re-triggering the same boss every cast inside the spawn radius.
# Resets on login (Player respawns), no server persistence yet.
var _defeated_bosses: Array[String] = []
# Phase 5 — true while the cast balance minigame is open. Same gating idea
# as _reeling / _in_sea_combat — the per-frame action loop must not fire
# fresh catches while the player is mid-cast.
var _casting:         bool = false
# Polish v2 — tier shift from a teal/gold-zone cast minigame win. 0 = normal,
# 1 = upgraded (teal), 2 = rare (gold). Set in _on_cast_minigame_ended,
# read by _pick_catch, cleared after the catch is resolved.
var _cast_tier_bonus: int  = 0

# Combat melee swing animation (triggered by HUD when a melee hit lands)
var _swing_t: float = 0.0
const SWING_DUR := 0.28

const FISH_RANGE := 150.0   # how close to click to fish from a boat
# Standard catch table by fishing level (mirrors shoreline fishing).
const _BOAT_FISH: Array = [
	{"max": 20, "id": "raw_fish",    "name": "Raw Fish",    "color": Color(0.70, 0.90, 0.95), "xp": 20},
	{"max": 40, "id": "raw_salmon",  "name": "Raw Salmon",  "color": Color(0.95, 0.55, 0.30), "xp": 35},
	{"max": 60, "id": "lobster",     "name": "Lobster",     "color": Color(0.90, 0.30, 0.20), "xp": 60},
	{"max": 80, "id": "raw_shark",   "name": "Raw Shark",   "color": Color(0.55, 0.58, 0.62), "xp": 90},
	{"max": 99, "id": "abyssal_eel", "name": "Abyssal Eel", "color": Color(0.28, 0.45, 0.35), "xp": 120},
]
# Rare deep-sea fish — only catchable from a boat in open ocean. Each entry
# carries a `min_lv` Fishing gate; _pick_catch() returns the highest-tier fish
# the player qualifies for. Expanded in Phase 1 of the fishing rework from 3
# entries to 11 (tiered every ~10 Fishing levels). Phase 5's skill rework
# replaces the deterministic tier pick with a weighted bait/lure roll.
const _DEEP_FISH: Array = [
	{"id": "silverfin",         "name": "Silverfin",            "color": Color(0.62, 0.70, 0.82), "xp":  80, "min_lv":  1},
	{"id": "frost_cod",         "name": "Frost Cod",            "color": Color(0.72, 0.84, 0.92), "xp": 110, "min_lv": 10},
	{"id": "void_squid",        "name": "Void Squid",           "color": Color(0.20, 0.08, 0.32), "xp": 150, "min_lv": 20},
	{"id": "anglerfish",        "name": "Anglerfish",           "color": Color(0.24, 0.28, 0.20), "xp": 190, "min_lv": 30},
	{"id": "deep_runefish",     "name": "Deep Runefish",        "color": Color(0.45, 0.30, 0.70), "xp": 240, "min_lv": 40},
	{"id": "lava_eel",          "name": "Lava Eel",             "color": Color(0.95, 0.40, 0.10), "xp": 300, "min_lv": 50},
	{"id": "abyssal_pearl",     "name": "Abyssal Pearl-bearer", "color": Color(0.92, 0.90, 0.80), "xp": 360, "min_lv": 60},
	{"id": "leviathan_eel",     "name": "Leviathan Eel",        "color": Color(0.18, 0.42, 0.38), "xp": 430, "min_lv": 70},
	{"id": "sea_serpent_scale", "name": "Sea Serpent",          "color": Color(0.32, 0.62, 0.45), "xp": 510, "min_lv": 80},
	{"id": "kraken_meat",       "name": "Kraken",               "color": Color(0.42, 0.20, 0.55), "xp": 620, "min_lv": 90},
	{"id": "leviathan_eye",     "name": "Leviathan Eye",        "color": Color(0.85, 0.95, 0.65), "xp": 800, "min_lv": 95},
]

# ── Camera control ─────────────────────────────────────────────────────────
var _cam:        Camera2D = null
var _cam_free:   bool     = false
var _cam_offset: Vector2  = Vector2.ZERO
const CAM_PAN_SPEED := 400.0

# ── Colour palette ─────────────────────────────────────────────────────────
const C_SKIN    := Color(0.87, 0.70, 0.52)
const C_MAIL    := Color(0.22, 0.48, 0.82)
const C_MAIL_LT := Color(0.34, 0.60, 0.92)
const C_HELM    := Color(0.52, 0.55, 0.58)
const C_HELM_LT := Color(0.68, 0.70, 0.72)
const C_BEARD   := Color(0.72, 0.50, 0.18)
const C_LEATHER := Color(0.30, 0.18, 0.06)
const C_TROUSER := Color(0.22, 0.18, 0.12)
const C_BOOT    := Color(0.16, 0.10, 0.04)
const C_CAPE    := Color(0.50, 0.08, 0.06)
const C_AXE     := Color(0.72, 0.72, 0.75)
const C_PICKAXE := Color(0.60, 0.60, 0.62)
const C_ROD     := Color(0.48, 0.30, 0.08)
const C_LINE    := Color(0.85, 0.85, 0.85, 0.65)

func _ready() -> void:
	_target_pos = global_position
	add_to_group("player")
	Events.player_start_action.connect(_on_start_action)
	Events.player_stop_action.connect(_on_stop_action)
	Events.player_respawned.connect(_on_player_respawned)
	Events.monster_attack_chosen.connect(_on_monster_attack_chosen)
	Events.combat_ended.connect(_on_combat_ended_player)
	Events.boat_toggle.connect(_toggle_boat)
	# Reel minigame outcome — applies the catch on win, chats the loss on fail.
	# `_reeling` blocks fresh catch rolls until this fires so the action loop
	# doesn't stack reel modals.
	Events.reel_minigame_ended.connect(_on_reel_minigame_ended)
	# Phase 3 sea-combat outcome — applies loot/XP on win, damages the player
	# and clears the boat on lose, no-op on flee. `_in_sea_combat` blocks
	# fresh casts until the modal closes.
	Events.sea_combat_ended.connect(_on_sea_combat_ended)
	# Floating hull HP bar refresh. The regular sailing-physics loop already
	# queue_redraws every frame while sailing, but tying it to the signal
	# means the bar reacts even if the player is standing still (post-flee
	# stationary, etc.).
	Events.boat_hp_changed.connect(_on_boat_hp_changed)
	# Phase 5 cast minigame outcome — success runs the existing catch
	# resolution; fail just chats and clears the busy flag.
	Events.cast_minigame_ended.connect(_on_cast_minigame_ended)
	_cam = get_node_or_null("Camera2D") as Camera2D

# ── Action signals ──────────────────────────────────────────────────────────
func _on_start_action(atype: String, _target: Node) -> void:
	_state           = PlayerState.ACTING
	_action_type     = atype
	_action_frame    = 0.0
	_action_interval = _interval_for(atype)

func _on_stop_action() -> void:
	if _state == PlayerState.ACTING:
		_state        = PlayerState.IDLE
		_action_type  = ""
		_action_frame = 0.0
		_boat_fishing = false
		queue_redraw()

func _on_player_respawned(pos: Vector2) -> void:
	global_position      = pos
	_target_pos          = pos
	_target_interactable = null
	_target_monster      = null
	_in_combat           = false
	velocity             = Vector2.ZERO
	_state               = PlayerState.IDLE
	if _sailing:
		_sailing = false
		_boat_id = ""
		set_collision_mask_value(2, true)
		_boat_prompt_kind = ""
		Events.boat_prompt.emit("")
	queue_redraw()

## Player picked "Attack" from the monster action popup. Combat starts
## immediately — no proximity walk, no range check, no automated movement.
## The player stays exactly where they are; the server's aggro chase brings
## the monster to the player (DE_AGGRO leash raised to support 600+ px
## engagement on the server side). Ranged / magic resource checks still
## fire — if you click Attack with no arrows / no runes, the open_combat
## call still goes through and HUD._launch_player_attack will fall back to
## melee or post a chat warning. That keeps the popup decision authoritative
## and matches "Attack means combat starts."
func _on_monster_attack_chosen(monster: Node) -> void:
	if monster == null or not (monster is Node2D) or not (monster.get("is_alive") as bool):
		print("[combat-debug] attack chosen but monster invalid")
		return
	if _state == PlayerState.ACTING:
		Events.player_stop_action.emit()
	_target_interactable = null
	_target_monster      = monster
	_target_pos          = global_position   # stand-still — explicit
	velocity             = Vector2.ZERO
	_in_combat           = true
	print("[combat-debug] attack_chosen: instant combat open, no movement, style=%s" % GameManager.combat_style)
	Events.open_combat.emit(monster)

## Edge-to-edge stop distance for melee. Sum of player radius + the monster's
## horizontal shadow-footprint radius + MELEE_EDGE_GAP. Falls back to a
## sensible default if the monster doesn't expose _shadow_footprint.
func _melee_stop_dist(monster: Node) -> float:
	var mr := 10.0
	if monster.has_method("_shadow_footprint"):
		var fp: Vector2 = monster.call("_shadow_footprint") as Vector2
		mr = fp.x
	return PLAYER_RADIUS + mr + MELEE_EDGE_GAP

## World-space point on the line from monster→player at the stop distance.
## The player walks here instead of the monster's center so they end up just
## outside the body silhouette.
func _melee_stop_pos(monster: Node2D, stop_dist: float) -> Vector2:
	var to_player := global_position - monster.global_position
	if to_player.length() < 0.5:
		return monster.global_position + Vector2(stop_dist, 0.0)
	return monster.global_position + to_player.normalized() * stop_dist

func _on_combat_ended_player() -> void:
	_target_monster = null
	_in_combat      = false

## Triggered by the HUD when a melee blow lands — plays a visible weapon swing.
func play_swing(target_x: float) -> void:
	_swing_t = SWING_DUR
	if absf(target_x - global_position.x) > 1.0:
		_facing = signf(target_x - global_position.x)
	queue_redraw()

func _interval_for(atype: String) -> float:
	# Roughly matches Interactable swing intervals (gathering now takes 5-8s).
	match atype:
		"mine": return 5.5
		"fish": return 6.0
		_:      return 5.0   # chop + default

# ── Physics ─────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	_update_camera(delta)
	if _swing_t > 0.0:
		_swing_t -= delta
		queue_redraw()
	if _state == PlayerState.ACTING:
		if _keyboard_direction() != Vector2.ZERO:
			Events.player_stop_action.emit()   # player cancels by moving
			# state is now IDLE; fall through to normal movement
		else:
			var prev_frame := _action_frame
			_action_frame = fmod(_action_frame + delta / _action_interval, 1.0)
			# Phase 5 — while the cast balance minigame is open, the action
			# loop drives the rod-swing animation but does NOT fire a catch
			# on frame wrap. The minigame's `cast_minigame_ended` handler
			# kicks off `_attempt_boat_catch()` on success instead.
			if _boat_fishing and not _casting and _action_frame < prev_frame:
				_attempt_boat_catch()
			velocity      = Vector2.ZERO
			queue_redraw()
			move_and_slide()
			return

	if _ground == null:
		_ground = get_tree().get_first_node_in_group("ground")

	# Monster state cleanup. The old auto-approach / auto-engage path is
	# gone — combat is only entered from the "Attack" popup. This branch now
	# does ONE job: drop _target_monster + _in_combat the moment the target
	# becomes invalid (despawned, died, or admin-purged). The server's aggro
	# chase governs distance, not the client.
	if _target_monster != null:
		if not is_instance_valid(_target_monster) or not (_target_monster.get("is_alive") as bool):
			_target_monster = null
			_in_combat      = false

	var spd := _move_speed()
	var kb := _keyboard_direction()
	if kb != Vector2.ZERO:
		_target_interactable = null
		_target_pos = global_position   # cancel any click destination so we stop on key release
		if not _in_combat:
			_target_monster = null
		velocity = kb * spd
		_state   = PlayerState.MOVING
	elif _target_pos.distance_to(global_position) > 4.0:
		velocity = global_position.direction_to(_target_pos) * spd
		_state   = PlayerState.MOVING
		if _target_interactable != null:
			if global_position.distance_to(_target_interactable.global_position) <= INTERACT_RANGE:
				_fire_interaction()
	else:
		if _state == PlayerState.MOVING:
			_walk_time = 0.0
			queue_redraw()
		velocity = Vector2.ZERO
		_state   = PlayerState.IDLE
		if _target_interactable != null:
			_fire_interaction()

	if velocity.x != 0.0:
		_facing = signf(velocity.x)

	# Movement / terrain rules: on foot you can't enter water; in a boat you can
	# only travel on water (never beach onto land).
	if _ground != null and velocity != Vector2.ZERO:
		var next := global_position + velocity * get_physics_process_delta_time()
		if _tile_is_water(next) == _sailing:
			pass  # allowed (on foot→land, sailing→water)
		else:
			velocity    = Vector2.ZERO
			_target_pos = global_position

	_update_boat_prompt()

	if _state == PlayerState.MOVING:
		_walk_time += get_physics_process_delta_time()
		queue_redraw()
		# Footstep cadence — fire every 4 movement frames while actually
		# moving (skip while sailing). AudioManager handles biome→sample
		# mapping and alternates pitch internally so the L/R feet diverge.
		if not _sailing and velocity != Vector2.ZERO:
			_footstep_frame += 1
			if _footstep_frame >= 4:
				_footstep_frame = 0
				var biome: String = _ground.biome_at_world(global_position) as String if _ground != null else "plains"
				AudioManager.play_footstep(biome)

	move_and_slide()

func _move_speed() -> float:
	if _sailing:
		return BASE_SPEED * float(Boats.data(_boat_id).get("speed", 1.0))
	return GameManager.get_move_speed(BASE_SPEED)

func _tile_is_water(p: Vector2) -> bool:
	if _ground == null:
		return false
	var b: String = _ground.biome_at_world(p) as String
	return b == "ocean" or b == "coast"

func _tile_center(p: Vector2) -> Vector2:
	return Vector2((floorf(p.x / TILE) + 0.5) * TILE, (floorf(p.y / TILE) + 0.5) * TILE)

## Returns a water tile-centre adjacent to the player, or Vector2.INF if none.
func _adjacent_water() -> Vector2:
	for d: Vector2 in [Vector2(TILE,0), Vector2(-TILE,0), Vector2(0,TILE), Vector2(0,-TILE),
			Vector2(TILE,TILE), Vector2(-TILE,TILE), Vector2(TILE,-TILE), Vector2(-TILE,-TILE)]:
		if _tile_is_water(global_position + d):
			return _tile_center(global_position + d)
	return Vector2.INF

## Returns a land tile-centre adjacent to the player, or Vector2.INF if none.
func _adjacent_land() -> Vector2:
	for d: Vector2 in [Vector2(TILE,0), Vector2(-TILE,0), Vector2(0,TILE), Vector2(0,-TILE),
			Vector2(TILE,TILE), Vector2(-TILE,TILE), Vector2(TILE,-TILE), Vector2(-TILE,-TILE)]:
		if not _tile_is_water(global_position + d):
			return _tile_center(global_position + d)
	return Vector2.INF

func _update_boat_prompt() -> void:
	if _ground == null:
		return
	var kind := ""
	if _sailing:
		if _adjacent_land() != Vector2.INF:
			kind = "dock"
	elif Boats.best_in_inventory(GameManager.inventory) != "" and _adjacent_water() != Vector2.INF:
		kind = "launch"
	if kind == _boat_prompt_kind:
		return
	_boat_prompt_kind = kind
	if kind == "launch":
		Events.boat_prompt.emit("Launch %s  (E)" % Boats.name_of(Boats.best_in_inventory(GameManager.inventory)))
	elif kind == "dock":
		Events.boat_prompt.emit("Dock boat  (E)")
	else:
		Events.boat_prompt.emit("")

func _toggle_boat() -> void:
	if _sailing:
		_dock_boat()
	else:
		_launch_boat()

func _launch_boat() -> void:
	if _sailing:
		return
	var bid := Boats.best_in_inventory(GameManager.inventory)
	if bid == "":
		return
	var water := _adjacent_water()
	if water == Vector2.INF:
		return
	GameManager.remove_item_qty(bid, 1)
	GameManager.current_boat = bid
	# Seed the persistent hull HP for Phase 3 sea-combat encounters. Launch
	# always starts at max — getting the boat out of the bag is the implicit
	# "repair" step. _dock_boat clears these back to 0.
	var hp_max := int(Boats.data(bid).get("hp", 30))
	GameManager.current_boat_max_hp = hp_max
	GameManager.current_boat_hp     = hp_max
	_sailing = true
	_boat_id = bid
	set_collision_mask_value(2, false)   # stop colliding with the water body
	global_position = water
	_target_pos     = water
	velocity        = Vector2.ZERO
	if _state == PlayerState.ACTING:
		Events.player_stop_action.emit()
	Events.boat_prompt.emit("")
	_boat_prompt_kind = ""
	Events.chat_message.emit("You launch the %s." % Boats.name_of(bid))
	queue_redraw()

func _dock_boat() -> void:
	if not _sailing:
		return
	var land := _adjacent_land()
	if land == Vector2.INF:
		return
	var wood: Color = Boats.data(_boat_id).get("wood", Color.SADDLE_BROWN)
	var bname := Boats.name_of(_boat_id)
	# Inventory-full safety: GameManager.add_item silently no-ops when there
	# are no free slots, which would lose the boat permanently on a full-bag
	# dock. Drop it as a world pickup instead so the player can clear a slot
	# and grab it back.
	if GameManager.free_slots() > 0:
		GameManager.add_item(_boat_id, bname, 1, wood)
	else:
		_spawn_boat_pickup(land, _boat_id, bname, wood)
		Events.chat_message.emit(
			"Inventory full — %s left on the shore." % bname)
	GameManager.current_boat = ""
	# Clear persistent hull HP — no boat in the water, no bar to draw.
	GameManager.current_boat_hp     = 0
	GameManager.current_boat_max_hp = 0
	_sailing = false
	set_collision_mask_value(2, true)
	global_position = land
	_target_pos     = land
	velocity        = Vector2.ZERO
	Events.boat_prompt.emit("")
	_boat_prompt_kind = ""
	Events.chat_message.emit("You dock your boat.")
	_boat_id = ""
	_boat_fishing = false
	queue_redraw()

## Spawn a world LootDrop pickup carrying the boat. Used by _dock_boat when
## the inventory is full so the boat isn't silently lost. Mirrors Monster.gd's
## _spawn_loot pattern: Area2D + LootDrop script + setup() with the boat's
## id / name / qty=1 / hull colour. Parented to the World node so it lives in
## the same scene as the rest of the loot drops.
func _spawn_boat_pickup(at: Vector2, bid: String, bname: String, wood: Color) -> void:
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = at
	get_parent().add_child(ld)
	(ld as Area2D).call("setup", bid, bname, 1, wood)

# ── Boat fishing ─────────────────────────────────────────────────────────────
## Left-click while sailing: nearby water → fish there; otherwise sail toward it.
func _handle_sail_click(p: Vector2) -> void:
	if _tile_is_water(p) and global_position.distance_to(p) <= FISH_RANGE:
		if not GameManager.has_tool_for_skill("fishing"):
			Events.chat_message.emit("You need a fishing pole to fish.")
			return
		# Block re-entry while any fishing modal is already open. The cast
		# minigame, reel modal, and sea-combat modal each set their own
		# busy flag; treat them uniformly so a stray click while modals
		# are up doesn't fire a second one underneath.
		if _casting or _reeling or _in_sea_combat:
			return
		_facing = signf(p.x - global_position.x) if absf(p.x - global_position.x) > 1.0 else _facing
		_boat_fishing = true
		_state         = PlayerState.ACTING
		_action_type   = "fish"
		_action_frame  = 0.0
		# `_action_interval` left at its previous value — the per-frame
		# auto-fire path is gated on `not _casting` below, so the interval
		# only drives the rod-swing animation while the modal is open.
		_action_interval = 3.5
		_target_pos    = global_position
		velocity       = Vector2.ZERO
		# Phase 5 — the cast balance minigame replaces the 3.5s passive
		# wait. HUD listens for this signal and spawns the modal; the
		# modal emits `cast_minigame_ended` which lands in our handler.
		_casting = true
		Events.cast_minigame_start.emit()
		queue_redraw()
	else:
		if _state == PlayerState.ACTING:
			Events.player_stop_action.emit()
		_target_interactable = null
		_target_monster      = null
		_target_pos          = p

func _attempt_boat_catch() -> void:
	# A reel modal or sea-combat encounter is already open — don't roll a
	# fresh catch on top of it.
	if _reeling or _in_sea_combat:
		return
	if not GameManager.has_tool_for_skill("fishing"):
		Events.chat_message.emit("You need a fishing pole to fish.")
		Events.player_stop_action.emit()
		return
	var lv := GameManager.get_skill_level("fishing")
	# Phase 5 — the balance minigame IS the success check. Winning it always
	# resolves to a catch (or one of the modal branches below); no second
	# RNG gate. The previous `chance := 0.55 + lv*0.003 + boat_fish_bonus`
	# roll and the "the fish got away…" chat are gone by spec. Only a full
	# inventory can cause a no-catch outcome, handled just before the reel
	# trigger / instant catch below. (Boat.fish_bonus is now unused —
	# revisit it if a future system wants a passive bonus surface.)
	var deep: bool = _ground != null and _ground.is_deep_ocean(global_position)
	# Phase 4 — boss tile check fires first. If the cast lands within range
	# of a fixed-tile boss spawn AND the player is in a tier-appropriate
	# boat AND the boss hasn't been cleared this session, open the boss
	# encounter and bypass the random table entirely.
	var boss: Dictionary = SeaMonsters.boss_spawn_at(global_position, 32.0)
	if not boss.is_empty():
		var bid := str(boss.get("id", ""))
		if _defeated_bosses.has(bid):
			pass    # already cleared this session — fall through to normal catch
		else:
			var min_tier := int(boss.get("min_boat_tier", 0))
			var boat_tier := int(Boats.data(_boat_id).get("tier", 0))
			if boat_tier < min_tier:
				Events.chat_message.emit(
					"Something vast stirs beneath you — your %s is too small to face it."
					% Boats.name_of(_boat_id))
			else:
				_in_sea_combat = true
				Events.sea_combat_start.emit(bid)
				return
	# Phase 3: a successful bite has a chance to be a sea monster instead of
	# a fish. Shallow casts (coast) only roll shallow-flagged entries; deep
	# casts (open ocean) only roll the rest. If the roll fires AND the table
	# has an eligible entry at this Fishing level, open the boat-combat modal
	# in place of the catch.
	if randf() < _sea_encounter_chance(deep):
		var monster_type := SeaMonsters.roll_encounter(lv, not deep)
		if monster_type != "":
			_in_sea_combat = true
			Events.sea_combat_start.emit(monster_type)
			return
	var catch := _pick_catch(lv, deep)
	# Phase 5 — full-inventory safety. Winning the balance guarantees a catch
	# unless there's nowhere to put it. Pre-check here so the player doesn't
	# fight a 30-second reel for a fish they can't land. This is the only
	# allowed failure path after a successful balance (per spec).
	if not _has_inventory_room_for(str(catch["id"])):
		Events.chat_message.emit(
			"%s slipped from your hands — inventory is full." % str(catch["name"]))
		return
	# Phase 2: defer item + XP grant to the reel minigame outcome if this fish
	# fights back. Otherwise — small shoreline fish — apply immediately as
	# before. `_maybe_trigger_reel` consumes the trigger-chance roll itself so
	# a false return means "instant catch, no reel was rolled".
	if _maybe_trigger_reel(catch, deep):
		_reeling = true
		Events.reel_minigame_start.emit(catch)
		return
	GameManager.add_item(str(catch["id"]), str(catch["name"]), 1, catch["color"] as Color)
	# Phase 5 Part 3 — bait `catch_bonus` applies as a flat XP multiplier on
	# the landed catch (1.0 if no bait, 1.0 + catch_bonus if bait equipped).
	# Lures don't apply here — their bonus lives in _pick_catch's rare lift.
	GameManager.add_xp("fishing",
		int(round(float(catch["xp"]) * _bait_xp_mult())))

## Returns true if this catch should open the reel minigame. Rolls + consumes
## the trigger chance internally so callers don't need to know the table:
##   - any deep-sea catch (DEEP_FISH carries `min_lv`) — 50% base
##   - top two shoreline tiers (raw_shark, abyssal_eel)  — 30% base
##   - everything else                                    — never
## Phase 5 — bait/lure `rare_bonus` adds to the base trigger chance (capped
## at 0.95). Empty bait slot keeps the original 0.50/0.30 numbers.
func _maybe_trigger_reel(catch: Dictionary, deep: bool) -> bool:
	var iid := str(catch.get("id", ""))
	var td: Dictionary = _tackle_data()
	var rb := float(td.get("rare_bonus", 0.0))
	if deep and catch.has("min_lv"):
		return randf() < clampf(0.50 + rb, 0.0, 0.95)
	if iid == "raw_shark" or iid == "abyssal_eel":
		return randf() < clampf(0.30 + rb, 0.0, 0.95)
	return false

func _on_reel_minigame_ended(catch_data: Dictionary, success: bool) -> void:
	_reeling = false
	var iname := str(catch_data.get("name", "fish"))
	if success:
		var col_v: Variant = catch_data.get("color", Color.WHITE)
		var col: Color = col_v if col_v is Color else Color.WHITE
		GameManager.add_item(str(catch_data["id"]), iname, 1, col)
		# Double XP for the reeled catch — the player earned it through
		# active play, not just the cast-and-wait loop. Phase 5 Part 3 —
		# bait `catch_bonus` multiplies on top via `_bait_xp_mult()`.
		GameManager.add_xp("fishing",
			int(round(float(catch_data.get("xp", 0)) * 2.0 * _bait_xp_mult())))
		Events.chat_message.emit("You landed the %s!" % iname)
	else:
		Events.chat_message.emit("The line snapped — the %s escaped." % iname)
	# Phase 5 — one-cast-per-click model. Whatever the reel outcome, this
	# cast is over; player must click to fire another.
	Events.player_stop_action.emit()

## Per-cast base chance that the bite is a sea-monster encounter rather than
## a fish. Shallow casts (coast) and deep casts (open ocean) have distinct
## rates so early-game players see the occasional shallow scrap without deep
## fishing becoming a meatgrinder. Phase 5 — bait/lure `monster_bonus` adds
## on top (kraken_bait at 0.30 swings deep encounters from 8% to 38%).
func _sea_encounter_chance(deep: bool) -> float:
	var td: Dictionary = _tackle_data()
	var base := 0.08 if deep else 0.05
	return clampf(base + float(td.get("monster_bonus", 0.0)), 0.0, 0.95)

## Outcome of the boat-combat modal. `monster_type` is the SeaMonsters key;
## `outcome` is "win", "flee", or "lose".
##   win  — drop the monster's loot into inventory + grant XP. Half to
##          fishing (this is a fishing-context encounter), half to melee.
##   flee — no penalty, no reward. Just clear the busy flag.
##   lose — boat is sunk: clear GameManager.current_boat (the boat is gone),
##          damage the player 25% of max HP, force-dock back to land via the
##          normal docking path so they don't drown in open water.
@warning_ignore("integer_division")
func _on_sea_combat_ended(monster_type: String, outcome: String) -> void:
	_in_sea_combat = false
	var m: Dictionary = SeaMonsters.data(monster_type)
	if m.is_empty():
		return
	var mname := str(m.get("name", "creature"))
	match outcome:
		"win":
			var loot_v: Variant = m.get("loot", [])
			if loot_v is Array:
				for it: Variant in (loot_v as Array):
					if it is Dictionary:
						var d: Dictionary = it
						var col_v: Variant = d.get("color", Color.WHITE)
						var col: Color = col_v if col_v is Color else Color.WHITE
						GameManager.add_item(str(d.get("id", "")),
							str(d.get("name", "")),
							int(d.get("qty", 1)), col)
			var xp := int(m.get("xp_reward", 0))
			@warning_ignore("integer_division")
			GameManager.add_xp("fishing", xp / 2)
			@warning_ignore("integer_division")
			GameManager.add_xp("melee",   xp - xp / 2)
			# Phase 4 — record boss kills so the spawn radius doesn't keep
			# re-triggering the same fight every cast for the rest of the
			# session. List resets on next login (no server persistence).
			if bool(m.get("boss", false)) and not _defeated_bosses.has(monster_type):
				_defeated_bosses.append(monster_type)
			Events.chat_message.emit("You defeated the %s!" % mname)
		"flee":
			Events.chat_message.emit("You escaped from the %s." % mname)
		"lose":
			GameManager.current_boat        = ""
			GameManager.current_boat_hp     = 0
			GameManager.current_boat_max_hp = 0
			@warning_ignore("integer_division")
			GameManager.take_damage(maxi(1, GameManager.get_max_hp() / 4))
			# Land the player so they're not stuck in open water without a boat.
			if _sailing:
				_force_dock_to_shore()
			Events.chat_message.emit(
				"Your boat was sunk by the %s — you wash ashore." % mname)
	# Phase 5 — one-cast-per-click model. End the cast's action loop on
	# any outcome (lose already cleared sailing state via _force_dock_to_shore).
	Events.player_stop_action.emit()

## Emergency dock — called when the boat is destroyed mid-sail. Walks outward
## from the player until it finds a land tile and snaps them onto it. Mirrors
## the shape of _dock_boat() but without the inventory restore (boat is gone)
## or the adjacency requirement (might be deep at sea).
func _force_dock_to_shore() -> void:
	_sailing = false
	_boat_id = ""
	set_collision_mask_value(2, true)
	# Spiral outward looking for a non-water tile. Step size = one tile.
	var step := 32.0
	var max_radius := 50
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue   # only check the ring's perimeter
				var p := global_position + Vector2(dx, dy) * step
				if not _tile_is_water(p):
					global_position = p
					_target_pos = p
					velocity = Vector2.ZERO
					queue_redraw()
					return

func _pick_catch(lv: int, deep: bool) -> Dictionary:
	# Phase 5 Part 3 — only LURES lift the deep-fish pick chance here. Bait
	# `rare_bonus` still applies to the reel-trigger threshold (via
	# _maybe_trigger_reel) but not to the deep-pick chance, by spec. Empty
	# bait slot or bait equipped → +0.0 → identical to pre-Phase-5 behavior.
	var ld: Dictionary = _lure_data()
	var deep_chance := clampf(0.40 + float(ld.get("rare_bonus", 0.0)), 0.0, 0.95)
	# Polish v2 — cast-minigame teal/gold zone wins shift the catch table up
	# by 1/2 tiers. tier_bonus = 0 → unchanged. Gold also forces the deep-fish
	# branch so a rare cast on shoreline still gets boosted reliably.
	var tb: int = _cast_tier_bonus
	if deep and (randf() < deep_chance or tb >= 2):
		var qualified_idx: int = 0
		for i: int in range(_DEEP_FISH.size()):
			if lv >= int(_DEEP_FISH[i]["min_lv"]):
				qualified_idx = i
		var picked_idx: int = mini(qualified_idx + tb, _DEEP_FISH.size() - 1)
		return _DEEP_FISH[picked_idx]
	var base_idx: int = _BOAT_FISH.size() - 1
	for i: int in range(_BOAT_FISH.size()):
		if lv < int(_BOAT_FISH[i]["max"]):
			base_idx = i
			break
	var boat_idx: int = mini(base_idx + tb, _BOAT_FISH.size() - 1)
	return _BOAT_FISH[boat_idx]

## Returns the equipped fishing tackle's data dict (Fishing.BAIT or LURES
## entry) or {} if the bait slot is empty. Used by _maybe_trigger_reel and
## _sea_encounter_chance, which read fields that apply to either bait OR
## lure (rare_bonus for the reel trigger, monster_bonus for sea encounters).
func _tackle_data() -> Dictionary:
	var iid: String = GameManager.equipped_bait()
	if iid == "":
		return {}
	return Fishing.tackle_data(iid)

## Phase 5 Part 3 — bait-only data accessor. Returns the equipped item's
## entry if and only if it's a bait (not a lure). `catch_bonus` from this
## dict becomes the flat XP multiplier on a landed catch.
func _bait_data() -> Dictionary:
	var iid: String = GameManager.equipped_bait()
	if iid == "" or not Fishing.is_bait(iid):
		return {}
	return Fishing.bait_data(iid)

## Phase 5 Part 3 — lure-only data accessor. `_pick_catch` reads `rare_bonus`
## from this to lift the deep-fish rare-pick chance above its 0.40 base.
## Returns {} if the equipped item is bait, not a lure.
func _lure_data() -> Dictionary:
	var iid: String = GameManager.equipped_bait()
	if iid == "" or not Fishing.is_lure(iid):
		return {}
	return Fishing.lure_data(iid)

## XP multiplier applied to landed catches when bait is equipped. 1.0 with
## no bait (or a lure equipped); 1.0 + bait.catch_bonus otherwise. Called by
## the instant-catch and reel-success XP grants so both paths benefit.
func _bait_xp_mult() -> float:
	return 1.0 + float(_bait_data().get("catch_bonus", 0.0))

## Phase 5 — true if the player's inventory can absorb one of `item_id`. A
## free slot is always enough. For stackable ids, an existing stack of the
## same id is also fine even when slots are full. Used to short-circuit the
## catch pipeline before opening a 30s reel modal for a fish that can't be
## picked up — the only allowed failure path after a successful balance.
func _has_inventory_room_for(item_id: String) -> bool:
	if GameManager.free_slots() > 0:
		return true
	if not GameManager.is_stackable(item_id):
		return false
	for item: Variant in GameManager.inventory:
		if item is Dictionary and str((item as Dictionary).get("id", "")) == item_id:
			return true
	return false

## Phase 5 cast minigame outcome. Success runs the normal catch resolution
## (which itself routes into boss check / sea encounter / reel modal / instant
## catch); fail chats the snap and clears the busy flag without rolling.
## Each cast is one-shot — when the resolution doesn't chain into a follow-up
## modal (reel or sea combat), we stop the action loop here so the next cast
## requires another deliberate click rather than auto-firing every 3.5s.
##
## `tier_bonus` 0/1/2 (normal/upgraded/rare from teal/gold zones) is stored
## on `_cast_tier_bonus` so `_pick_catch` can shift up the catch table for
## this one cast. Cleared after _attempt_boat_catch consumes it.
func _on_cast_minigame_ended(success: bool, tier_bonus: int) -> void:
	_casting = false
	if not success:
		Events.chat_message.emit("The line snapped! Cast failed.")
		Events.player_stop_action.emit()
		return
	_cast_tier_bonus = tier_bonus
	_attempt_boat_catch()
	_cast_tier_bonus = 0  # consumed
	# If the cast didn't chain into another modal (reel / sea combat), this
	# cast is fully resolved — return the player to IDLE. Chained modals
	# stop the action themselves when they end.
	if not _reeling and not _in_sea_combat:
		Events.player_stop_action.emit()

func _keyboard_direction() -> Vector2:
	var d := Vector2.ZERO
	if Input.is_key_pressed(KEY_A): d.x -= 1
	if Input.is_key_pressed(KEY_D): d.x += 1
	if Input.is_key_pressed(KEY_W): d.y -= 1
	if Input.is_key_pressed(KEY_S): d.y += 1
	return d.normalized() if d != Vector2.ZERO else Vector2.ZERO

# ── Input ───────────────────────────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_E and _boat_prompt_kind != "":
			_toggle_boat()
			get_viewport().set_input_as_handled()
		return
	if not event is InputEventMouseButton or not event.pressed:
		return
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if _sailing:
				_handle_sail_click(get_global_mouse_position())
				return
			var hit := _query_interactable(get_global_mouse_position())
			if _state == PlayerState.ACTING:
				Events.player_stop_action.emit()
			if hit != null:
				_target_interactable = hit
				_target_pos          = hit.global_position
				_target_monster      = null
			else:
				var mon := _query_monster(get_global_mouse_position())
				if mon != null:
					# Monster._input_event already emitted monster_clicked
					# which routed to HUD's action popup. Player does NOT
					# move on a monster click — combat only enters via the
					# popup's "Attack" choice. We clear the stale
					# interactable target but leave _target_pos alone so
					# the player stands still while choosing.
					_target_interactable = null
				else:
					_target_monster      = null
					_target_interactable = null
					_target_pos          = get_global_mouse_position()
		MOUSE_BUTTON_RIGHT:
			# Generic right-click action menu. Routing order: monster → any
			# interactable (rocks, trees, fish, herbs, NPCs, banks, forges,
			# banners, doors, …) → other player → empty space.
			var screen_pos := get_viewport().get_mouse_position()
			var mon_r := _query_monster(get_global_mouse_position())
			if mon_r != null:
				Events.action_menu_requested.emit(mon_r, screen_pos)
				get_viewport().set_input_as_handled()
				return
			var ihit := _query_interactable(get_global_mouse_position())
			if ihit != null:
				Events.action_menu_requested.emit(ihit, screen_pos)
				get_viewport().set_input_as_handled()
				return
			var op := _query_other_player(get_global_mouse_position())
			if op != null:
				var uname := str((op as Node2D).get_meta("username", "?"))
				Events.player_context_menu.emit(uname, screen_pos)
				get_viewport().set_input_as_handled()
				return
			# Empty space — cancel current action, stop movement, drop the
			# panel's selected target (combat-end is separately driven by
			# the Flee button in the panel; right-click no longer kills an
			# active fight by surprise).
			if _state == PlayerState.ACTING:
				Events.player_stop_action.emit()
			_target_interactable = null
			_target_pos          = global_position
			velocity             = Vector2.ZERO
			Events.target_cleared.emit()
		MOUSE_BUTTON_WHEEL_UP:
			if _cam != null:
				_cam.zoom = (_cam.zoom * 1.1).clamp(Vector2(0.5, 0.5), Vector2(3.0, 3.0))
		MOUSE_BUTTON_WHEEL_DOWN:
			if _cam != null:
				_cam.zoom = (_cam.zoom * 0.9).clamp(Vector2(0.5, 0.5), Vector2(3.0, 3.0))

# ── Camera pan / lock ────────────────────────────────────────────────────────
func _update_camera(delta: float) -> void:
	if _cam == null:
		return
	var pan := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):  pan.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT): pan.x += 1.0
	if Input.is_key_pressed(KEY_UP):    pan.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):  pan.y += 1.0
	if pan != Vector2.ZERO:
		if not _cam_free:
			_cam_free = true
			Events.camera_free_mode_changed.emit(true)
		_cam_offset += pan.normalized() * CAM_PAN_SPEED * delta
		_cam_offset.x = clampf(_cam_offset.x, -1200.0, 1200.0)
		_cam_offset.y = clampf(_cam_offset.y, -1200.0, 1200.0)
	_cam.offset = _cam_offset

func lock_camera() -> void:
	if _cam == null or not _cam_free:
		return
	_cam_offset = Vector2.ZERO
	_cam.offset = Vector2.ZERO
	_cam_free   = false
	Events.camera_free_mode_changed.emit(false)

func _query_interactable(pos: Vector2) -> Node:
	var space  := get_world_2d().direct_space_state
	var params := PhysicsPointQueryParameters2D.new()
	params.position            = pos
	params.collision_mask      = 4
	params.collide_with_areas  = true
	params.collide_with_bodies = false
	for r: Dictionary in space.intersect_point(params):
		var col := r["collider"] as Node
		if col != null and col.is_in_group("interactable"):
			return col
	return null

func _query_other_player(world_pos: Vector2) -> Node2D:
	for op in get_tree().get_nodes_in_group("other_player"):
		if (op as Node2D).global_position.distance_to(world_pos) <= 24.0:
			return op as Node2D
	return null

func _query_monster(pos: Vector2) -> Node:
	var space  := get_world_2d().direct_space_state
	var params := PhysicsPointQueryParameters2D.new()
	params.position            = pos
	params.collision_mask      = 8
	params.collide_with_areas  = true
	params.collide_with_bodies = false
	for r: Dictionary in space.intersect_point(params):
		var col := r["collider"] as Node
		if col != null and col.is_in_group("monster"):
			return col
	return null

func _fire_interaction() -> void:
	if _state == PlayerState.ACTING:
		Events.player_stop_action.emit()
	var node             := _target_interactable
	_target_interactable  = null
	_target_pos           = global_position
	velocity              = Vector2.ZERO
	Events.player_interacted.emit(node)

# ── Drawing ─────────────────────────────────────────────────────────────────
func _draw() -> void:
	var arm_a := _arm_angle()
	var moving := _state == PlayerState.MOVING and not _sailing
	var acting := _state == PlayerState.ACTING
	var walk_sw := sin(_walk_time * 9.0) * 3.5 if moving else 0.0
	var left_a: float
	if acting:
		left_a = lerp(0.0, 0.25, _action_frame)
	elif moving:
		left_a = -sin(_walk_time * 9.0) * 0.3
	else:
		left_a = 0.0
	var walk_arm_a := sin(_walk_time * 9.0) * 0.3 if moving else 0.0
	# Combat swing: a strong forward arc of the weapon arm when a melee blow lands.
	var swing_a := 0.0
	if _swing_t > 0.0:
		swing_a = sin((1.0 - _swing_t / SWING_DUR) * PI) * 1.7
	Appearance.draw_character(self, GameManager.appearance, {
		"walk_sw":      walk_sw,
		"left_arm":     left_a,
		"right_arm":    arm_a + walk_arm_a + swing_a,
		"acting":       acting,
		"action_type":  _action_type,
		"equip":        GameManager.equipment,
	})
	# Boat drawn in front of and slightly below the character, so the rower sits
	# up behind the hull rather than standing on top of it.
	if _sailing:
		draw_set_transform(Vector2(0, 6), 0.0, Vector2.ONE)
		Boats.draw_boat(self, _boat_id, _facing)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		_draw_boat_hp_bar()

## Floating hull HP bar — only drawn when the boat has taken at least 1 point
## of damage in the current sailing session. Positioned just below the boat
## sprite's bottom edge (hull bottom = 4 + hd in boat-local coords, plus the
## y=6 boat draw offset). Fill color shifts green → yellow → red as HP drops.
func _draw_boat_hp_bar() -> void:
	var cur:   int = GameManager.current_boat_hp
	var maxhp: int = GameManager.current_boat_max_hp
	if maxhp <= 0 or cur >= maxhp:
		return  # no boat tracked OR full HP — nothing to show
	var tier := int(Boats.data(_boat_id).get("tier", 0))
	var hd := 10.0 + float(tier) * 1.2
	# Sit a few px below the hull bottom. The boat sprite was drawn with a
	# (0, 6) transform offset, so its hull bottom in our local coords is at
	# y = 6 + 4 + hd. Add 6 px of padding so the bar floats clear of the hull.
	var by := 6.0 + 4.0 + hd + 6.0
	var bw := 36.0
	var bh := 4.0
	var frac := clampf(float(cur) / float(maxhp), 0.0, 1.0)
	# Background + 1 px dark border.
	draw_rect(Rect2(-bw * 0.5 - 1, by - 1, bw + 2, bh + 2),
		Color(0.05, 0.05, 0.05, 0.85))
	draw_rect(Rect2(-bw * 0.5, by, bw, bh), Color(0.18, 0.10, 0.06, 0.95))
	# Fill — green > 60%, yellow 30-60%, red < 30%.
	var fill_col := (Color(0.30, 0.80, 0.30) if frac > 0.60
		else (Color(0.95, 0.78, 0.20) if frac > 0.30
		else Color(0.90, 0.25, 0.18)))
	draw_rect(Rect2(-bw * 0.5, by, bw * frac, bh), fill_col)

func _on_boat_hp_changed(_current: int, _maximum: int) -> void:
	queue_redraw()

# ── Arm angle based on action frame ─────────────────────────────────────────
func _arm_angle() -> float:
	if _state != PlayerState.ACTING:
		return 0.0
	var f := _action_frame
	match _action_type:
		"chop", "mine":
			if f < 0.25:
				return lerp(0.0, -2.0, f / 0.25)
			elif f < 0.50:
				return lerp(-2.0, 0.7, (f - 0.25) / 0.25)
			else:
				return lerp(0.7, 0.0, (f - 0.50) / 0.50)
		"fish":
			if f < 0.40:
				return lerp(0.0, -0.9, f / 0.40)
			elif f < 0.55:
				return lerp(-0.9, 0.3, (f - 0.40) / 0.15)
			else:
				return lerp(0.3, 0.18, (f - 0.55) / 0.45)
	return 0.0

