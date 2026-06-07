extends Area2D

@export var display_name: String          = "Resource Node"
@export var required_skill: String        = "woodcutting"
@export var required_level: int           = 1
@export var color: Color                  = Color(0.2, 0.7, 0.2)
@export var action_label: String          = "Interact"
@export var interactable_type_str: String = "tree"

enum State { IDLE, BEING_HIT, DEPLETED }

var _state           := State.IDLE
var _hp              := 1      # successes needed to deplete (always 1 for resource nodes)
var _max_hp          := 1
var _swing_interval  := 2.5    # seconds between swings
var _success_at_req  := 0.80   # success chance at required_level
var _success_at_99   := 0.95   # success chance at level 99
var _regen_delay     := 45.0   # seconds before respawn
var _swing_elapsed   := 0.0
var _regen_elapsed   := 0.0
var _origin_pos      := Vector2.ZERO
var _shake           := Vector2.ZERO
var _shake_timer     := 0.0
var _time_elapsed    := 0.0    # for forge flame animation
var _particles: Array[Dictionary] = []     # [{pos, vel, life, color}]

var is_hovered       := false
var _xp_cooldown     := 0.0   # cooldown for archery/runestone training

# Server-authoritative shared state (set by World on chunk resource nodes).
var entity_id        := ""
var _i_am_gathering  := false   # this client's player is the one gathering
var _remote_gathering := false  # another player is gathering this node
var _remote_anim_t   := 0.0
# Fallback: if the server never answers a gather_request, gather locally so the
# game is never broken (e.g. server not running the world-state build yet).
var _gather_pending  := false
var _gather_wait     := 0.0
var _local_fallback  := false

const PART_LIFE      := 0.55
const GATHER_TIMEOUT := 2.0   # seconds to wait for a server grant before going local

func _is_server_managed() -> bool:
	return entity_id != "" and NetworkManager.state == NetworkManager.NetState.LOGGED_IN \
		and not _local_fallback

func _ready() -> void:
	add_to_group("interactable")
	input_pickable  = true
	collision_layer = 4
	collision_mask  = 0
	_origin_pos     = position
	_set_stats()
	_setup_collision()
	mouse_entered.connect(_on_hover_enter)
	mouse_exited.connect(_on_hover_exit)
	Events.player_interacted.connect(_on_player_interacted)
	Events.player_stop_action.connect(_on_player_stop_action)

# ── Per-type stats ───────────────────────────────────────────────────────────
# Tiers (shared by tree / rock / fish / herb) use required_level ranges.
# success_at_req / success_at_99 are interpolated at runtime by _success_chance().
# All resource nodes use hp=1: one successful swing depletes the node.
func _set_stats() -> void:
	match interactable_type_str:
		"tree", "rock":
			# Longer swings so gathering takes real effort: ~5s base → ~8s high tier.
			_max_hp = 1
			if required_level < 15:
				_swing_interval = 5.0; _success_at_req = 0.80; _success_at_99 = 0.95
				_regen_delay = 30.0
			elif required_level < 30:
				_swing_interval = 5.5; _success_at_req = 0.55; _success_at_99 = 0.90
				_regen_delay = 45.0
			elif required_level < 50:
				_swing_interval = 6.0; _success_at_req = 0.40; _success_at_99 = 0.80
				_regen_delay = 60.0
			elif required_level < 70:
				_swing_interval = 6.5; _success_at_req = 0.30; _success_at_99 = 0.70
				_regen_delay = 75.0
			elif required_level < 85:
				_swing_interval = 7.0; _success_at_req = 0.25; _success_at_99 = 0.60
				_regen_delay = 90.0
			else:
				_swing_interval = 8.0; _success_at_req = 0.20; _success_at_99 = 0.50
				_regen_delay = 120.0
		"fish":
			_max_hp = 1
			if required_level < 20:
				_swing_interval = 5.0; _success_at_req = 0.75; _success_at_99 = 0.95; _regen_delay = 30.0
			elif required_level < 40:
				_swing_interval = 5.5; _success_at_req = 0.55; _success_at_99 = 0.90; _regen_delay = 35.0
			elif required_level < 60:
				_swing_interval = 6.5; _success_at_req = 0.40; _success_at_99 = 0.80; _regen_delay = 45.0
			else:
				_swing_interval = 8.0; _success_at_req = 0.25; _success_at_99 = 0.70; _regen_delay = 60.0
		"essence":
			# Rune Essence node — admin-placed only (never spawned procedurally
			# by the chunk generator). Mining-skill gated, 7s respawn after
			# depletion. Server enforces the single-player lock so only one
			# miner can extract at a time; all other clients see node_locked.
			_max_hp = 4
			_swing_interval = 4.0; _success_at_req = 0.60; _success_at_99 = 0.95
			_regen_delay = 7.0
		"herb":
			_max_hp = 1
			_swing_interval = 5.0; _success_at_req = 0.90; _success_at_99 = 0.99; _regen_delay = 25.0
		"forge", "fire":
			_max_hp = 9999; _swing_interval = 2.0; _success_at_req = 1.0; _success_at_99 = 1.0; _regen_delay = 0.0
		"bank", "building":
			_max_hp = 9999; _swing_interval = 1.0; _success_at_req = 1.0; _success_at_99 = 1.0; _regen_delay = 0.0
		"crafting", "archery", "runestone", "construction", "auction_house":
			_max_hp = 9999; _swing_interval = 1.0; _success_at_req = 1.0; _success_at_99 = 1.0; _regen_delay = 0.0
		"stick", "stone":
			_max_hp = 1; _swing_interval = 5.0; _success_at_req = 1.0; _success_at_99 = 1.0; _regen_delay = 25.0
		"door":
			# Door — instant-click interactive, never depletes. Click sends
			# enter_interior to the server (Phase 6); Phase 7 swaps scenes.
			_max_hp = 9999; _swing_interval = 1.0; _success_at_req = 1.0; _success_at_99 = 1.0; _regen_delay = 0.0
		_:
			_max_hp = 1; _swing_interval = 5.0; _success_at_req = 0.80; _success_at_99 = 0.95; _regen_delay = 45.0
	_hp = _max_hp

func _setup_collision() -> void:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null:
		return
	var rect := RectangleShape2D.new()
	match interactable_type_str:
		"tree":
			# Ancient Tree's sprite is ~2.5× the others; the click area
			# follows so the player can reliably hit anywhere on the canopy.
			if display_name == "Ancient Tree":
				rect.size = Vector2(56, 68)
			else:
				rect.size = Vector2(24, 34)
		"rock":     rect.size = Vector2(32, 26)
		"essence":  rect.size = Vector2(30, 30)
		"fish":     rect.size = Vector2(42, 22)
		"building": rect.size = Vector2(44, 40)
		"stick":    rect.size = Vector2(18, 10)
		"stone":    rect.size = Vector2(16, 12)
		"door":     rect.size = Vector2(28, 38)
		_:          rect.size = Vector2(32, 32)
	cs.shape = rect

# ── Process: action loop + regen + particles + shake ───────────────────────
func _process(delta: float) -> void:
	_time_elapsed += delta
	if _xp_cooldown > 0.0:
		_xp_cooldown -= delta

	# Waiting on the server to grant a gather — fall back to local after a timeout.
	if _gather_pending:
		_gather_wait += delta
		if _gather_wait >= GATHER_TIMEOUT:
			_gather_pending = false
			_local_fallback = true
			Events.chat_message.emit("[Server slow to respond — gathering locally.]")
			_start_swinging()

	if _state == State.BEING_HIT:
		_swing_elapsed += delta
		if _swing_elapsed >= _swing_interval:
			_swing_elapsed = 0.0
			_apply_hit()
		_shake_timer -= delta
		if _shake_timer <= 0.0:
			_shake = Vector2.ZERO
		_update_particles(delta)
		queue_redraw()

	elif _state == State.DEPLETED:
		# When the server owns this node's state, respawn is driven by the server
		# (apply_respawn). Self-respawn in offline OR local-fallback mode.
		if _local_fallback or not _is_server_managed():
			_regen_elapsed += delta
			if _regen_elapsed >= _regen_delay:
				_respawn()

	elif _remote_gathering and _state == State.IDLE:
		# Another player is gathering this node — show their progress visually.
		_remote_anim_t += delta
		if _remote_anim_t >= _swing_interval:
			_remote_anim_t = 0.0
			_shake       = Vector2(randf_range(-3.5, 3.5), randf_range(-3.5, 3.5))
			_shake_timer = 0.12
			_spawn_particles()
		_shake_timer -= delta
		if _shake_timer <= 0.0:
			_shake = Vector2.ZERO
		_update_particles(delta)
		queue_redraw()

	elif interactable_type_str in ["forge", "fire", "building", "auction_house", "essence"]:
		queue_redraw()

# ── Hit ─────────────────────────────────────────────────────────────────────
func _apply_hit() -> void:
	_shake       = Vector2(randf_range(-3.5, 3.5), randf_range(-3.5, 3.5))
	_shake_timer = 0.12
	_spawn_particles()
	if randf() >= _success_chance():
		return  # miss — visual shake/particles only, no reward or HP damage
	_hp = max(0, _hp - 1)
	Events.node_hit.emit(self, _hp)
	if _hp <= 0:
		_deplete()

func _success_chance() -> float:
	if _success_at_req >= 1.0:
		return 1.0
	var lv := GameManager.get_skill_level(required_skill)
	var t  := 0.0
	if required_level < 99:
		t = clampf(float(lv - required_level) / float(99 - required_level), 0.0, 1.0)
	return clampf(lerpf(_success_at_req, _success_at_99, t) + _get_tool_bonus(), 0.0, 1.0)

func _get_tool_bonus() -> float:
	var keyword := ""
	match required_skill:
		"woodcutting": keyword = "axe"
		"mining":      keyword = "pickaxe"
		"fishing":     keyword = "fishing_pole"
		_: return 0.0
	for item: Dictionary in GameManager.inventory:
		var iid: String = item.get("id", "") as String
		if keyword in iid:
			if "runite"  in iid: return 0.30
			if "adamant" in iid: return 0.25
			if "mithril" in iid: return 0.20
			if "gold"    in iid: return 0.15
			if "iron"    in iid: return 0.10
			return 0.05
	return 0.0

func _deplete() -> void:
	_state          = State.DEPLETED   # set BEFORE emitting so _on_player_stop_action ignores it
	collision_layer = 0
	input_pickable  = false
	_regen_elapsed  = 0.0
	_particles.clear()
	_shake          = Vector2.ZERO
	# Award loot + XP (the gathering client awards locally)
	var loot := _loot_data()
	if not loot.is_empty():
		GameManager.add_item(loot["id"], loot["name"], 1, loot["color"])
		GameManager.add_xp(required_skill, loot["xp"])
	# Rune essence — secondary Magic XP scaling with the player's Magic level
	# so a high-magic miner gets compounding reward from extracting essence.
	# Formula: 5 + magic_level / 4, capped at 30, so lv 1 ≈ 5 xp, lv 99 ≈ 29.
	if interactable_type_str == "essence":
		var mlv := GameManager.get_skill_level("magic")
		@warning_ignore("integer_division")
		var bonus := mini(30, 5 + mlv / 4)
		GameManager.add_xp("magic", bonus)
	# Foraging herbs occasionally yield a farming seed.
	if interactable_type_str == "herb" and randf() < 0.15:
		var Farming := preload("res://scripts/Farming.gd")
		var sd: Dictionary = Farming.seed_def(Farming.random_seed_id())
		if not sd.is_empty():
			GameManager.add_item(str(sd["seed"]), str(sd["seed_name"]), 1, Farming.color_of(sd))
	# Tell the server it's depleted so every nearby client sees it deplete + respawn.
	if _is_server_managed() and _i_am_gathering:
		NetworkManager.send_gather_complete(entity_id, _regen_delay)
		_i_am_gathering = false
	Events.node_depleted.emit(self)
	Events.player_stop_action.emit()
	Events.ui_show_interaction.emit({
		"type":   "action",
		"action": "Obtained",
		"target": loot.get("name", display_name),
		"skill":  required_skill,
	})

func _respawn() -> void:
	var angle   := randf() * TAU
	var dist    := randf_range(2.0, 5.0) * 32.0
	var new_pos := _origin_pos + Vector2(cos(angle) * dist, sin(angle) * dist)
	new_pos.x   = clampf(new_pos.x, 48.0, 300 * 32.0 - 48.0)
	new_pos.y   = clampf(new_pos.y, 48.0, 300 * 32.0 - 48.0)
	position        = new_pos
	_hp             = _max_hp
	_state          = State.IDLE
	_regen_elapsed  = 0.0
	_swing_elapsed  = 0.0
	_particles.clear()
	_shake          = Vector2.ZERO
	collision_layer = 4
	input_pickable  = true
	queue_redraw()

# ── Particles ────────────────────────────────────────────────────────────────
func _spawn_particles() -> void:
	var chip: Color
	match interactable_type_str:
		"tree": chip = Color(0.55, 0.35, 0.12)
		"rock": chip = Color(0.65, 0.62, 0.58)
		"fish": chip = Color(0.55, 0.78, 0.95)
		_:      chip = color.lightened(0.2)
	for _i in range(5):
		var spd := randf_range(28.0, 80.0)
		var ang := randf() * TAU
		_particles.append({
			"pos":   Vector2(randf_range(-8, 8), randf_range(-8, 8)),
			"vel":   Vector2(cos(ang) * spd, sin(ang) * spd - 20.0),
			"life":  PART_LIFE,
			"color": chip,
		})

func _update_particles(delta: float) -> void:
	var i := _particles.size() - 1
	while i >= 0:
		var p: Dictionary = _particles[i]
		p["life"] -= delta
		if p["life"] <= 0.0:
			_particles.remove_at(i)
		else:
			p["pos"] += (p["vel"] as Vector2) * delta
			p["vel"]  = (p["vel"] as Vector2) + Vector2(0, 60) * delta  # gravity
		i -= 1

# ── Loot table ───────────────────────────────────────────────────────────────
func _loot_data() -> Dictionary:
	match interactable_type_str:
		"tree":
			match display_name:
				"Cherry Tree":
					return {"id":"cherry_log", "name":"Cherry Log", "color":Color(0.72,0.38,0.42), "xp":50}
				"Ironwood Tree":
					return {"id":"ironwood_log","name":"Ironwood Log","color":Color(0.30,0.18,0.08),"xp":75}
				"Frost Tree":
					return {"id":"frost_log",   "name":"Frost Log",   "color":Color(0.75,0.90,0.98), "xp":100}
				"Ancient Tree":
					return {"id":"ancient_log", "name":"Ancient Log", "color":Color(0.35,0.20,0.08), "xp":130}
				"Pine Tree":
					return {"id":"pine_log",   "name":"Pine Log",   "color":Color(0.45,0.30,0.10), "xp":35}
				_:
					return {"id":"oak_log",    "name":"Oak Log",    "color":Color(0.60,0.40,0.15), "xp":25}
		"rock":
			if required_level < 15:
				return {"id":"copper_ore",  "name":"Copper Ore",  "color":Color(0.75,0.45,0.20), "xp":30}
			elif required_level < 30:
				return {"id":"iron_ore",    "name":"Iron Ore",    "color":Color(0.55,0.55,0.60), "xp":55}
			elif required_level < 50:
				return {"id":"gold_ore",    "name":"Gold Ore",    "color":Color(0.92,0.78,0.12), "xp":65}
			elif required_level < 70:
				return {"id":"mithril_ore", "name":"Mithril Ore", "color":Color(0.40,0.65,0.90), "xp":90}
			elif required_level < 85:
				return {"id":"adamant_ore", "name":"Adamant Ore", "color":Color(0.20,0.65,0.30), "xp":110}
			else:
				return {"id":"runite_ore",  "name":"Runite Ore",  "color":Color(0.65,0.20,0.82), "xp":125}
		"fish":
			if required_level < 20:
				return {"id":"raw_fish",    "name":"Raw Fish",    "color":Color(0.70,0.90,0.95), "xp":20}
			elif required_level < 40:
				return {"id":"raw_salmon",  "name":"Raw Salmon",  "color":Color(0.95,0.55,0.30), "xp":35}
			elif required_level < 60:
				return {"id":"lobster",     "name":"Lobster",     "color":Color(0.90,0.30,0.20), "xp":60}
			elif required_level < 80:
				return {"id":"raw_shark",   "name":"Raw Shark",   "color":Color(0.55,0.58,0.62), "xp":90}
			else:
				return {"id":"abyssal_eel", "name":"Abyssal Eel", "color":Color(0.28,0.45,0.35), "xp":120}
		"herb":
			match display_name:
				"Mushroom Patch":
					return {"id":"mushrooms",   "name":"Mushrooms",   "color":Color(0.72,0.55,0.38), "xp":20}
				"Berry Bush":
					return {"id":"berries",     "name":"Berries",     "color":Color(0.72,0.18,0.50), "xp":30}
				"Moonbloom Patch":
					return {"id":"moonbloom",   "name":"Moonbloom",   "color":Color(0.78,0.62,0.95), "xp":50}
				"Ancient Root":
					return {"id":"ancient_root","name":"Ancient Root","color":Color(0.42,0.28,0.12), "xp":70}
				_:
					return {"id":"herbs",       "name":"Herbs",       "color":Color(0.45,0.80,0.20), "xp":15}
		"crafting":
			return {"id":"craft_kit",    "name":"Craft Kit",    "color":Color(0.72,0.58,0.30), "xp":25}
		"archery":
			return {"id":"arrow_bundle", "name":"Arrow Bundle", "color":Color(0.52,0.38,0.18), "xp":20}
		"runestone":
			return {"id":"magic_dust",   "name":"Magic Dust",   "color":Color(0.65,0.35,0.80), "xp":30}
		"essence":
			# Mining-skill primary XP — 60 is on the gold-ore tier given the
			# 7s respawn is what really gates throughput. Magic-level bonus
			# is granted in _deplete on top of this, so a high-magic miner
			# extracts essence faster in terms of total XP per cycle.
			return {"id":"rune_essence", "name":"Rune Essence", "color":Color(0.55,0.35,0.85), "xp":60}
		"construction":
			return {"id":"timber",       "name":"Timber",       "color":Color(0.55,0.38,0.18), "xp":25}
		"stick":
			return {"id":"stick", "name":"Stick", "color":Color(0.55, 0.36, 0.14), "xp":2}
		"stone":
			return {"id":"stone", "name":"Stone", "color":Color(0.58, 0.56, 0.52), "xp":2}
		_:
			return {}

func _skill_to_action() -> String:
	match required_skill:
		"woodcutting":  return "chop"
		"mining":       return "mine"
		"fishing":      return "fish"
		"construction": return "mine"
		_:              return "chop"

# ── Hover ────────────────────────────────────────────────────────────────────
func _on_hover_enter() -> void:
	is_hovered = true
	# Whole-sprite 20% brightness boost via CanvasItem.self_modulate.
	# Applies to every sub-draw inside _draw_body without touching the
	# per-type draw functions. Depleted nodes don't get the boost — they
	# read as "spent" and shouldn't pulse like they're selectable.
	if _state != State.DEPLETED:
		self_modulate = Color(1.20, 1.20, 1.20)
	queue_redraw()
	var hud := _find_hud()
	if hud and _state != State.DEPLETED:
		hud.show_hover("[%s]  %s" % [action_label, display_name])

func _on_hover_exit() -> void:
	is_hovered = false
	self_modulate = Color.WHITE
	queue_redraw()
	var hud := _find_hud()
	if hud:
		hud.hide_hover()

func _find_hud() -> Node:
	var nodes := get_tree().get_nodes_in_group("hud")
	return nodes[0] if nodes.size() > 0 else null

# ── Interaction ───────────────────────────────────────────────────────────────
func _on_player_interacted(node: Node) -> void:
	if node != self or _state == State.DEPLETED:
		return
	if interactable_type_str == "forge":
		Events.open_forge.emit()
		return
	if interactable_type_str == "fire":
		Events.open_cooking.emit()
		return
	if interactable_type_str == "bank":
		Events.open_bank.emit()
		return
	if interactable_type_str == "building":
		Events.chat_message.emit("You enter the %s." % display_name)
		return
	if interactable_type_str == "crafting":
		Events.open_crafting.emit()
		return
	if interactable_type_str == "archery":
		if _xp_cooldown > 0.0:
			Events.chat_message.emit("You need to rest before training again. (%.0fs)" % _xp_cooldown)
			return
		GameManager.add_xp("ranged", 5)
		_xp_cooldown = 30.0
		Events.ui_show_interaction.emit({"type": "action", "action": "Train", "target": display_name, "skill": "ranged"})
		return
	if interactable_type_str == "runestone":
		if _xp_cooldown > 0.0:
			Events.chat_message.emit("The rune is still recharging. (%.0fs)" % _xp_cooldown)
			return
		GameManager.add_xp("magic", 5)
		_xp_cooldown = 30.0
		Events.ui_show_interaction.emit({"type": "action", "action": "Study", "target": display_name, "skill": "magic"})
		return
	if interactable_type_str == "construction":
		Events.open_construction.emit()
		return
	if interactable_type_str == "auction_house":
		Events.open_auction_house.emit()
		return
	if interactable_type_str == "door":
		# Phase 6 — door click sends enter_interior to the server with the
		# door's admin entity_id. Server resolves the bound interior_id and
		# updates the session state. Phase 7 wires the visual scene swap;
		# for now this is protocol-only (server logs the request).
		if entity_id != "":
			NetworkManager.send_enter_interior(entity_id)
		return
	if interactable_type_str in ["stick", "stone"]:
		if _is_server_managed():
			_request_gather()
			return
		_state         = State.BEING_HIT
		_swing_elapsed = _swing_interval * 0.9
		Events.player_start_action.emit("chop", self)
		return
	if not GameManager.has_tool_for_skill(required_skill):
		Events.ui_show_interaction.emit({
			"type": "error",
			"message": "You need %s to do this." % GameManager.tool_name_for_skill(required_skill),
		})
		return
	var plv := GameManager.get_skill_level(required_skill)
	if plv < required_level:
		Events.ui_show_interaction.emit({
			"type":    "error",
			"message": "Requires level %d %s." % [required_level, required_skill.capitalize()],
		})
		return
	# Server owns this node: ask permission first, start swinging only on grant.
	if _is_server_managed():
		_request_gather()
		return
	_state          = State.BEING_HIT
	_swing_elapsed  = _swing_interval * 0.85   # first hit comes quickly
	Events.player_start_action.emit(_skill_to_action(), self)
	Events.ui_show_interaction.emit({
		"type":   "action",
		"action": action_label,
		"target": display_name,
		"skill":  required_skill,
	})

# ── Server-authoritative gather flow ──────────────────────────────────────────
func _request_gather() -> void:
	# Retry the server each time the player initiates (recovers if it comes back).
	_local_fallback = false
	_gather_pending = true
	_gather_wait    = 0.0
	NetworkManager.send_gather_request(entity_id, global_position.x, global_position.y)

## Shared swing-start used by both the server-granted and local-fallback paths.
func _start_swinging() -> void:
	if _state == State.DEPLETED:
		return
	_remote_gathering = false
	_state          = State.BEING_HIT
	_swing_elapsed  = _swing_interval * 0.85
	Events.player_start_action.emit(_skill_to_action(), self)
	Events.ui_show_interaction.emit({
		"type":   "action",
		"action": action_label,
		"target": display_name,
		"skill":  required_skill,
	})

## Called by World when the server grants the gather lock.
func begin_gather() -> void:
	if not _gather_pending:
		return  # already timed out into local fallback — ignore the late grant
	_gather_pending = false
	_i_am_gathering = true
	_start_swinging()

## Called by World when the server says another player holds the lock.
func on_gather_busy() -> void:
	if not _gather_pending:
		return  # already fell back to local — ignore the late reply
	_gather_pending = false
	Events.ui_show_interaction.emit({"type": "error", "message": "This resource is busy."})
	Events.player_stop_action.emit()

## Called by World when another player starts/stops gathering this node.
func set_remote_gathering(on: bool, _username: String) -> void:
	if _local_fallback or _state == State.DEPLETED:
		return
	_remote_gathering = on
	if not on:
		_shake = Vector2.ZERO
		_particles.clear()
	queue_redraw()

## Called by World when the server reports this node depleted (no local loot).
func apply_depleted(_respawn_in: float) -> void:
	if _local_fallback:
		return  # this node is locally managed; ignore server state
	_i_am_gathering   = false
	_remote_gathering = false
	if _state == State.DEPLETED:
		return
	_state          = State.DEPLETED
	collision_layer = 0
	input_pickable  = false
	_particles.clear()
	_shake          = Vector2.ZERO
	queue_redraw()

## Called by World when the server respawns this node (in place, no move).
func apply_respawn() -> void:
	if _local_fallback:
		return
	position        = _origin_pos
	_hp             = _max_hp
	_state          = State.IDLE
	_regen_elapsed  = 0.0
	_swing_elapsed  = 0.0
	_remote_gathering = false
	_i_am_gathering = false
	_particles.clear()
	_shake          = Vector2.ZERO
	collision_layer = 4
	input_pickable  = true
	queue_redraw()

func _on_player_stop_action() -> void:
	_gather_pending = false   # cancel any in-flight gather request
	if _state == State.BEING_HIT:
		_state         = State.IDLE
		_swing_elapsed = 0.0
		# Release the server lock so the node frees up for others.
		if _is_server_managed() and _i_am_gathering:
			NetworkManager.send_gather_release(entity_id)
			_i_am_gathering = false

# ── Drawing ──────────────────────────────────────────────────────────────────
func _draw() -> void:
	# Shadow audit: shadows are reserved for LIVING MOVING entities (players,
	# monsters, NPCs). Static resource nodes (trees, rocks, herbs, fish spots,
	# stations) no longer draw a ground shadow — they're terrain, not actors.
	# Depleted state already hides the sprite so no special case is needed
	# beyond not drawing the shadow up here.
	draw_set_transform(_shake, 0.0, Vector2.ONE)
	_draw_body()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Particles (no shake offset — they move in world/local space)
	for p in _particles:
		var a := (p["life"] as float) / PART_LIFE
		var r := maxf(1.0, 3.5 * a)
		var c := p["color"] as Color
		draw_circle(p["pos"], r, Color(c.r, c.g, c.b, a))

	# Hover indication is delivered via self_modulate (set in the
	# mouse_entered / mouse_exited callbacks), not a yellow outline rect.
	# Whole-sprite brightness boost reads as "selectable" without the
	# clutter of a bounding box around every node.

func _draw_body() -> void:
	var ratio := float(_hp) / float(max(_max_hp, 1))
	var c  := color.lightened(0.22) if is_hovered else color
	var cd := color.darkened(0.35)

	# Depth pass — bracket every LIVE sprite with a back-halo (magical types
	# only), an organic ground stain (resource nodes only), the per-type
	# draw, then a directional gradient overlay. Depleted nodes intentionally
	# skip the entire bracketing pass: the depth overlay's 36×36 bounding
	# rect bleeds past the small stump/broken/empty depleted sprites and
	# reads as a subtle dark square ghost over the ground. The depleted art
	# stands on its own without any post-pass help.
	var depleted := _state == State.DEPLETED
	if not depleted:
		if _has_ground_stain():
			_draw_organic_stain()
		var glow := _magic_glow_color()
		if glow.a > 0.0:
			_draw_magic_inner_glow(glow)

	match interactable_type_str:
		"tree":     _draw_tree(ratio, c, cd)
		"rock":     _draw_rock(ratio, c, cd)
		"essence":  _draw_essence(ratio)
		"fish":     _draw_fish(ratio, c, cd)
		"forge":    _draw_forge(c, cd)
		"fire":     _draw_fire(c)
		"herb":     _draw_herb(ratio, c, cd)
		"bank":         _draw_bank(c)
		"building":     _draw_building(c, cd)
		"crafting":     _draw_crafting_bench(ratio, c, cd)
		"archery":      _draw_archery_target(ratio, c, cd)
		"runestone":    _draw_runestone(ratio, c, cd)
		"construction": _draw_construction(ratio, c, cd)
		"auction_house": _draw_auction_house(c, cd)
		"door":         _draw_door(c, cd)
		"stick":        _draw_stick(c)
		"stone":        _draw_stone(c, cd)
		_:              draw_rect(Rect2(-14, -14, 28, 28), c)

	# Directional shading overlay — top-down light from upper-left. Matches
	# the terrain shader's directional pass so sprites read as part of the
	# same scene rather than flat decals sitting on top of shaded ground.
	# Gated on live state: see the comment above the bracket helpers.
	if not depleted:
		_draw_depth_overlay()

	# (Removed) Depleted state used to draw a 40×44 dark rect overlay on top
	# of the sprite. That stacked on top of each type's already-distinct
	# depleted art (tree stump, broken rock, empty soil patch, etc.) and
	# leaked a visible black square onto the world after every gather /
	# combat resolution. The depleted sprites stand on their own.

## True for node types that exist as physical objects on the ground
## (trees, rocks, foragables, mining nodes, runestone, pickups). False for
## structures, doors, etc. which read as built-on-top-of-the-tile.
func _has_ground_stain() -> bool:
	# Small ground pickups (stick, stone) read better WITHOUT a shadow —
	# they're flat litter on the ground, not 3D objects casting one.
	# Same rule for LootDrop and gold piles (see LootDrop._draw).
	match interactable_type_str:
		"tree", "rock", "essence", "fish", "herb", "runestone":
			return true
	return false

## Three-circle organic blob beneath the sprite. Wider than a single ellipse
## and asymmetric so it doesn't read as a perfect oval. Pure dark alpha so
## it stacks correctly on top of grass/rock/whatever biome the tile is.
func _draw_organic_stain() -> void:
	var col := Color(0.03, 0.02, 0.02, 0.32)
	draw_circle(Vector2( 2.0, 14.0), 13.0, col)
	draw_circle(Vector2(-4.0, 13.0),  9.0, col)
	draw_circle(Vector2( 6.0, 16.0),  8.0, Color(0.03, 0.02, 0.02, 0.22))

## Per-vertex-color polygon: dark across the top, lighter across the bottom.
## Subtle gradient overlay that matches the terrain's top-down lighting.
## Same low amplitudes as the shader pass so sprites integrate seamlessly.
func _draw_depth_overlay() -> void:
	# Conservative bounding box — wide enough to envelope most sprites,
	# narrow enough not to bleed onto neighbors. Trees extend above this
	# but the canopy detail itself dominates so the overlay reads cleanly.
	var pts := PackedVector2Array([
		Vector2(-18, -22), Vector2(18, -22),
		Vector2( 18,  14), Vector2(-18,  14),
	])
	var top_dark   := Color(0.0, 0.0, 0.0, 0.18)   # -18% multiplicative-ish
	var bot_light  := Color(1.0, 1.0, 1.0, 0.08)   # +8% lightening
	var cols := PackedColorArray([
		top_dark, top_dark, bot_light, bot_light,
	])
	draw_polygon(pts, cols)

## Subtle pulsing inner halo behind the sprite for magical nodes. Drawn
## BEFORE the sprite so it sits underneath, reading as "this thing glows
## from within" rather than a particle effect on top of it.
func _draw_magic_inner_glow(c: Color) -> void:
	var pulse := 0.55 + sin(_time_elapsed * 1.6) * 0.20
	draw_circle(Vector2(0, -2), 18.0, Color(c.r, c.g, c.b, 0.08 * pulse))
	draw_circle(Vector2(0, -2), 12.0, Color(c.r, c.g, c.b, 0.16 * pulse))
	draw_circle(Vector2(0, -2),  7.0, Color(c.r, c.g, c.b, 0.22 * pulse))

## Returns a non-transparent color when the node has a magical inner glow.
## Triggers for: rune essence (always), runestone, ancient root, and the
## two top-tier mining rocks (mithril/runite). Color picked to match the
## ore tint so the halo reads as "the rock itself is glowing".
func _magic_glow_color() -> Color:
	if interactable_type_str == "essence":
		return Color(0.65, 0.45, 1.00)
	if interactable_type_str == "runestone":
		return Color(0.80, 0.45, 1.00)
	if interactable_type_str == "herb" and display_name == "Ancient Root":
		return Color(1.00, 0.60, 0.18)
	if interactable_type_str == "rock":
		if required_level >= 85:
			return Color(0.85, 0.40, 1.00)   # runite — purple
		elif required_level >= 50:
			return Color(0.55, 0.78, 1.00)   # mithril — blue
	return Color(0, 0, 0, 0)

# ── Tree variant + dome-shading helpers ──────────────────────────────────────
## Deterministic per-position variant index in [0, modulo). Same tree at the
## same world position always renders the same variant; place two trees at
## (x, y) and (x+1, y) and they'll often pick different variants — making
## forests look natural rather than copy-pasted. Used by oak / pine / cherry.
func _tree_variant_index(modulo: int = 3) -> int:
	var h: int = int(abs(position.x * 73.0 + position.y * 31.0))
	return h % maxi(1, modulo)

## Small bright shine dot drawn near the top-center of a circular canopy,
## simulating the specular peak where overhead light hits the dome's
## highest point. Paired with the rim-darken / top-lighten pass each tree
## branch does explicitly.
func _draw_canopy_shine(center: Vector2, base: Color) -> void:
	draw_circle(center + Vector2(-2.5, -2.0), 2.2,
		Color(1.0, 1.0, 1.0, 0.55))
	draw_circle(center + Vector2(-2.5, -2.0), 1.0,
		base.lightened(0.85).blend(Color(1, 1, 1, 0.85)))

# ── HP-stage draw functions ───────────────────────────────────────────────────
func _draw_tree(ratio: float, _c: Color, _cd: Color) -> void:
	var trunk_brown  := Color(0.42, 0.26, 0.10)
	var trunk_dark   := Color(0.28, 0.16, 0.06)
	var tname        := display_name

	if _state == State.DEPLETED:
		draw_rect(Rect2(-6, 0, 12, 14), trunk_dark)
		draw_rect(Rect2(-4, -4, 8, 6), trunk_dark.lightened(0.1))
		draw_rect(Rect2(-11, 10, 7, 3), trunk_dark)
		draw_rect(Rect2(4, 10, 7, 3), trunk_dark)
		return

	# Root flares
	draw_colored_polygon(PackedVector2Array([Vector2(-5, 8), Vector2(-13, 14), Vector2(-5, 14)]),
		trunk_dark)
	draw_colored_polygon(PackedVector2Array([Vector2(5, 8), Vector2(13, 14), Vector2(5, 14)]),
		trunk_dark)

	# Trunk — width varies by per-position variant for oak/pine/cherry so
	# a forest reads as a mix of stocky and slim trunks instead of identical
	# silhouettes. Other tree types keep the standard 10-wide trunk.
	var trunk_w := 10
	if tname == "Oak Tree" or tname == "Pine Tree" or tname == "Cherry Tree" \
			or tname == "":
		match _tree_variant_index(3):
			1: trunk_w = 12
			2: trunk_w = 8
			_: trunk_w = 10
	var tw_half := float(trunk_w) * 0.5
	draw_rect(Rect2(-tw_half, 6, float(trunk_w), 16), trunk_brown)
	draw_line(Vector2(-tw_half + 3.0, 7), Vector2(-tw_half + 3.0, 20), trunk_dark, 1.0)
	draw_line(Vector2( tw_half - 3.0, 7), Vector2( tw_half - 3.0, 20), trunk_dark, 1.0)

	if ratio <= 0.5:
		draw_colored_polygon(
			PackedVector2Array([Vector2(-5, 8), Vector2(0, 14), Vector2(5, 8)]),
			Color(0.05, 0.05, 0.05))

	if tname == "Pine Tree":
		# Variants: 0 = standard, 1 = tall/narrow, 2 = squat/wide. Selected
		# deterministically from world position so a forest never repeats
		# in a uniform line. Color hue shift is ±5% green for subtle variety.
		var pv := _tree_variant_index(3)
		var c_base := Color(0.10, 0.42, 0.20)
		match pv:
			1: c_base = Color(0.08, 0.44, 0.18)
			2: c_base = Color(0.12, 0.40, 0.22)
		var width_mul := 1.0
		var height_mul := 1.0
		match pv:
			1: width_mul = 0.85; height_mul = 1.15
			2: width_mul = 1.15; height_mul = 0.90
		var c := c_base
		if ratio > 0.75:
			# Three layered triangles (back→front, dark→light) — dome shading
			# via top-tip lighter color emulating overhead light. Rim is the
			# back layer's darkened polygon at base. Tip shine added at the
			# very top to sell the rounded surface.
			draw_colored_polygon(PackedVector2Array([
				Vector2(-14.0 * width_mul, 4),
				Vector2( 14.0 * width_mul, 4),
				Vector2( 0, -18.0 * height_mul)]), c.darkened(0.22))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-11.0 * width_mul, -2),
				Vector2( 11.0 * width_mul, -2),
				Vector2( 0, -24.0 * height_mul)]), c)
			draw_colored_polygon(PackedVector2Array([
				Vector2(-8.0 * width_mul, -8),
				Vector2( 8.0 * width_mul, -8),
				Vector2( 0, -30.0 * height_mul)]), c.lightened(0.18))
			# Top tip shine — pine's "dome" highlight.
			draw_circle(Vector2(-1.5, -29.0 * height_mul + 1.0), 1.6,
				Color(1.0, 1.0, 1.0, 0.55))
		elif ratio > 0.5:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-14.0 * width_mul, 4),
				Vector2( 14.0 * width_mul, 4),
				Vector2( 0, -18.0 * height_mul)]), c.darkened(0.22))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-10.0 * width_mul, -3),
				Vector2( 10.0 * width_mul, -3),
				Vector2( 0, -22.0 * height_mul)]), c)
			draw_circle(Vector2(-1.5, -21.0 * height_mul + 1.0), 1.4,
				Color(1.0, 1.0, 1.0, 0.45))
		elif ratio > 0.25:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-10.0 * width_mul, 4),
				Vector2( 10.0 * width_mul, 4),
				Vector2( 0, -16.0 * height_mul)]), c.darkened(0.12))
		else:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-6, 4), Vector2(6, 4), Vector2(0, -10)]), c.darkened(0.35))

	elif tname == "Cherry Tree":
		# Variants: 0 standard round, 1 large oval-tall, 2 small wide-oval.
		# Color shift ±5% on bloom hue for subtle pinkness variety.
		var cv := _tree_variant_index(3)
		var bloom_base := Color(0.98, 0.72, 0.80)
		match cv:
			1: bloom_base = Color(1.00, 0.68, 0.82)
			2: bloom_base = Color(0.96, 0.76, 0.78)
		var sx := 1.0
		var sy := 1.0
		match cv:
			1: sx = 1.05; sy = 1.15
			2: sx = 1.15; sy = 0.92
		var bloom  := bloom_base
		var bloom2 := bloom.lightened(0.18)
		if ratio > 0.75:
			# Rim — slightly oversized darkened pass for the dome edge.
			draw_circle(Vector2(0, -4), 17.0 * sx, bloom.darkened(0.20))
			draw_circle(Vector2(-9.0 * sx, 3), 12.0 * sx, bloom.darkened(0.22))
			draw_circle(Vector2( 9.0 * sx, 3), 12.0 * sx, bloom.darkened(0.20))
			# Main canopy.
			draw_circle(Vector2(0, -4), 15.0 * sx, bloom)
			draw_circle(Vector2(-9.0 * sx, 3), 10.0 * sx, bloom.darkened(0.08))
			draw_circle(Vector2( 9.0 * sx, 3), 10.0 * sx, bloom.darkened(0.05))
			# Top-center lighter pop.
			draw_circle(Vector2(0, -6.0 * sy), 12.0 * sx, bloom2)
			# Petal highlights.
			for pi_i in range(5):
				var pa := pi_i * TAU / 5.0
				draw_circle(Vector2(cos(pa) * 8.0 * sx, sin(pa) * 6.0 - 4.0),
					3.5, bloom2)
			# Specular shine dot.
			_draw_canopy_shine(Vector2(0, -7.0 * sy), bloom)
		elif ratio > 0.5:
			draw_circle(Vector2(0, -4), 16.0 * sx, bloom.darkened(0.18))
			draw_circle(Vector2(0, -4), 14.0 * sx, bloom)
			draw_circle(Vector2(-8.0 * sx, 3), 9.0 * sx, bloom.darkened(0.08))
			draw_circle(Vector2(0, -6.0 * sy), 8.0 * sx, bloom2)
			_draw_canopy_shine(Vector2(0, -6.0 * sy), bloom)
		elif ratio > 0.25:
			draw_circle(Vector2(0, -4), 12.0 * sx, bloom.darkened(0.22))
			draw_circle(Vector2(0, -4), 10.0 * sx, bloom.darkened(0.10))
		else:
			draw_circle(Vector2(0, -5), 6, bloom.darkened(0.3))

	elif tname == "Ironwood Tree":
		# Dark burgundy-brown hard canopy. Dome shading via darker rim at
		# the base polygon + lighter top polygon + tip shine.
		var c := Color(0.28, 0.14, 0.08)
		var cl := Color(0.40, 0.22, 0.12)
		if ratio > 0.75:
			# Rim base — darkened version of the base layer.
			draw_colored_polygon(PackedVector2Array([
				Vector2(-14, 6), Vector2(14, 6), Vector2(0, -21)]), c.darkened(0.20))
			# Mid layer.
			draw_colored_polygon(PackedVector2Array([
				Vector2(-13, 5), Vector2(13, 5), Vector2(0, -20)]), c)
			draw_colored_polygon(PackedVector2Array([
				Vector2(-10, -2), Vector2(10, -2), Vector2(0, -26)]), cl)
			# Top layer — lightened "dome top".
			draw_colored_polygon(PackedVector2Array([
				Vector2(-7, -9), Vector2(7, -9), Vector2(0, -32)]), c.lightened(0.18))
			# Leaf dots
			for li in range(6):
				var la := li * TAU / 6.0
				draw_circle(Vector2(cos(la) * 10.0, sin(la) * 6.0 - 6.0), 2.5,
					Color(0.55, 0.30, 0.15, 0.70))
			# Tip shine.
			draw_circle(Vector2(-1.5, -30.0), 1.6, Color(1.0, 1.0, 1.0, 0.50))
		elif ratio > 0.5:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-14, 6), Vector2(14, 6), Vector2(0, -19)]), c.darkened(0.20))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-13, 5), Vector2(13, 5), Vector2(0, -20)]), c)
			draw_colored_polygon(PackedVector2Array([
				Vector2(-10, -2), Vector2(10, -2), Vector2(0, -24)]), cl.lightened(0.10))
			draw_circle(Vector2(-1.0, -22.0), 1.3, Color(1.0, 1.0, 1.0, 0.42))
		elif ratio > 0.25:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-9, 5), Vector2(9, 5), Vector2(0, -16)]), c.darkened(0.15))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-8, 4), Vector2(8, 4), Vector2(0, -15)]), c)
		else:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-5, 5), Vector2(5, 5), Vector2(0, -10)]), c.darkened(0.3))

	elif tname == "Frost Tree":
		# Icy crystalline canopy. Dome via darker rim crystals + a central
		# lighter core with a specular highlight on the top-facing spike.
		var ice   := Color(0.72, 0.90, 0.98)
		var ice2  := Color(0.90, 0.97, 1.00)
		var icedm := ice.darkened(0.18)
		if ratio > 0.75:
			# Dark rim ring — slightly larger crystals drawn first, become
			# the outer edge of the dome.
			for ri in range(6):
				var ra := ri * TAU / 6.0 - PI / 6.0
				var rr := 11.0 + (ri % 2) * 4.0
				draw_colored_polygon(PackedVector2Array([
					Vector2(cos(ra) * 5.0, sin(ra) * 3.5 - 4.0),
					Vector2(cos(ra + 0.4) * 5.0, sin(ra + 0.4) * 3.5 - 4.0),
					Vector2(cos(ra + 0.2) * float(rr), sin(ra + 0.2) * float(rr) - 4.0)]),
					icedm)
			# Main crystal spikes.
			for ci in range(6):
				var ca := ci * TAU / 6.0 - PI / 6.0
				var cr := 9.0 + (ci % 2) * 4.0
				draw_colored_polygon(PackedVector2Array([
					Vector2(cos(ca) * 5.0, sin(ca) * 3.5 - 4.0),
					Vector2(cos(ca + 0.4) * 5.0, sin(ca + 0.4) * 3.5 - 4.0),
					Vector2(cos(ca + 0.2) * float(cr), sin(ca + 0.2) * float(cr) - 4.0)]),
					ice if ci % 2 == 0 else ice2)
			# Lighter dome core.
			draw_circle(Vector2(0, -4), 7, ice2)
			# Specular shine on the top-facing tip.
			draw_circle(Vector2(-1.5, -10.0), 1.8, Color(1.0, 1.0, 1.0, 0.65))
			draw_circle(Vector2(-1.5, -10.0), 0.8, Color(1.0, 1.0, 1.0, 0.95))
		elif ratio > 0.5:
			for ci in range(4):
				var ca := ci * TAU / 4.0
				draw_colored_polygon(PackedVector2Array([
					Vector2(cos(ca) * 4.0, sin(ca) * 3.0 - 4.0),
					Vector2(cos(ca + 0.5) * 4.0, sin(ca + 0.5) * 3.0 - 4.0),
					Vector2(cos(ca + 0.25) * 11.0, sin(ca + 0.25) * 11.0 - 4.0)]), icedm)
			draw_circle(Vector2(0, -4), 5, ice)
		elif ratio > 0.25:
			draw_circle(Vector2(0, -4), 9, icedm)
		else:
			draw_circle(Vector2(0, -5), 5, icedm.darkened(0.3))
		# Frost trunk override
		draw_rect(Rect2(-5, 6, 10, 16), Color(0.75, 0.88, 0.95))
		draw_line(Vector2(-2, 7), Vector2(-2, 20), Color(0.55, 0.75, 0.88), 1.0)
		draw_line(Vector2(2, 7), Vector2(2, 20), Color(0.55, 0.75, 0.88), 1.0)

	elif tname == "Ancient Tree":
		_draw_ancient_tree(ratio)

	else:
		# Oak (default tname or unmatched). Variants: 0 standard round,
		# 1 large tall-oval, 2 small wide-oval. Green hue shifts ±5%.
		var ov := _tree_variant_index(3)
		var c_base := Color(0.18, 0.55, 0.15)
		match ov:
			1: c_base = Color(0.16, 0.58, 0.13)
			2: c_base = Color(0.20, 0.52, 0.17)
		var sx := 1.0
		var sy := 1.0
		match ov:
			1: sx = 1.05; sy = 1.15
			2: sx = 1.15; sy = 0.88
		var c := c_base
		if ratio > 0.75:
			# Dome shading: darker outer rim ring → main canopy → lighter
			# top pop → specular shine dot. The rim is drawn as oversized
			# darkened versions of each cluster circle so the silhouette
			# rim reads consistently around the entire canopy footprint.
			draw_circle(Vector2(0, -4),       17.0 * sx, c.darkened(0.20))
			draw_circle(Vector2(-9.0 * sx, 3), 11.5 * sx, c.darkened(0.22))
			draw_circle(Vector2( 9.0 * sx, 3), 11.5 * sx, c.darkened(0.20))
			# Main canopy.
			draw_circle(Vector2(0, -4),       15.0 * sx, c.darkened(0.05))
			draw_circle(Vector2(-9.0 * sx, 3), 10.0 * sx, c)
			draw_circle(Vector2( 9.0 * sx, 3), 10.0 * sx, c)
			# Top-center lighter pop — the dome's overhead-lit surface.
			draw_circle(Vector2(0, -6.0 * sy), 12.0 * sx, c.lightened(0.18))
			draw_circle(Vector2(-3, -8.0 * sy), 5.5 * sx, c.lightened(0.28))
			# Specular shine dot.
			_draw_canopy_shine(Vector2(0, -7.0 * sy), c)
		elif ratio > 0.5:
			draw_circle(Vector2(0, -4),       16.5 * sx, c.darkened(0.22))
			draw_circle(Vector2(0, -4),       15.0 * sx, c)
			draw_circle(Vector2(-9.0 * sx, 3), 10.0 * sx, c)
			draw_circle(Vector2(8.0 * sx, 4),  5.0,       c.darkened(0.3))
			draw_circle(Vector2(0, -6.0 * sy), 10.0 * sx, c.lightened(0.15))
			_draw_canopy_shine(Vector2(0, -6.0 * sy), c)
		elif ratio > 0.25:
			draw_circle(Vector2(0, -4), 13.0 * sx, c.darkened(0.22))
			draw_circle(Vector2(0, -4), 12.0 * sx, c)
		else:
			draw_circle(Vector2(0, -5), 7, c.darkened(0.2))

## Ancient Tree — 2.5× the size of any other tree. Deep gold-green canopy,
## visible golden glow aura radiating outward in pulsing rings, massive
## dark trunk with five root flares spreading from the base. Most impressive
## sprite in the game by design — readable from across the screen.
func _draw_ancient_tree(ratio: float) -> void:
	var trunk_dark   := Color(0.18, 0.10, 0.04)
	var trunk_mid    := Color(0.30, 0.18, 0.08)
	var trunk_lt     := Color(0.45, 0.28, 0.12)
	var canopy_dk    := Color(0.18, 0.30, 0.10)
	var canopy_md    := Color(0.32, 0.50, 0.18)
	var canopy_lt    := Color(0.62, 0.78, 0.32)
	var gold         := Color(0.98, 0.82, 0.30)
	var gold_warm    := Color(1.00, 0.90, 0.50)
	# Pulsing aura modulates alpha + radius over a ~3s cycle.
	var pulse := 0.85 + sin(_time_elapsed * 1.1) * 0.15
	var pulse2 := 0.70 + sin(_time_elapsed * 1.1 + 0.8) * 0.30

	# ── Massive root spread (drawn first, sits under trunk) ─────────────
	var roots: Array[Vector2] = [
		Vector2(-26, 22), Vector2(-16, 28), Vector2( 0, 30),
		Vector2( 16, 28), Vector2( 26, 22),
	]
	for rp: Vector2 in roots:
		draw_colored_polygon(PackedVector2Array([
			Vector2(rp.x * 0.3, 8.0), rp, Vector2(rp.x * 0.6, rp.y + 4.0),
		]), trunk_dark)
		draw_line(Vector2(rp.x * 0.4, 9.0), rp, trunk_mid, 1.0)

	# ── Massive trunk ────────────────────────────────────────────────────
	draw_rect(Rect2(-9, 4, 18, 32), trunk_dark)
	draw_rect(Rect2(-7, 4, 14, 32), trunk_mid)
	draw_rect(Rect2(-7, 4, 3,  32), trunk_dark)            # left shadow strip
	draw_rect(Rect2( 5, 4, 2,  32), trunk_lt)              # right highlight strip
	# Bark grain — diagonal cracks.
	for bi in range(4):
		var by := 8 + bi * 7
		draw_line(Vector2(-5, by), Vector2(-2, by + 5), trunk_dark, 1.0)
		draw_line(Vector2( 5, by), Vector2( 2, by + 5), trunk_dark, 1.0)
	# Trunk knot detail at mid-height.
	draw_circle(Vector2(-2, 18), 2.0, trunk_dark)
	draw_circle(Vector2(-2, 18), 1.1, trunk_lt.darkened(0.20))

	# ── Golden glow aura (3 rings of pulsing low-alpha gold) ────────────
	if ratio > 0.25:
		var aura_r := 50.0
		draw_circle(Vector2(0, -14), aura_r * pulse,
			Color(gold.r, gold.g, gold.b, 0.06))
		draw_circle(Vector2(0, -14), aura_r * 0.78,
			Color(gold.r, gold.g, gold.b, 0.10 * pulse))
		draw_circle(Vector2(0, -14), aura_r * 0.58,
			Color(gold.r, gold.g, gold.b, 0.16 * pulse))

	# ── Canopy — layered circles for depth, scale by ratio ──────────────
	if ratio > 0.75:
		# Full canopy — five layers stacking dark→mid→light.
		draw_circle(Vector2( 0,  -8), 34, canopy_dk)
		draw_circle(Vector2(-22, -2), 18, canopy_dk)
		draw_circle(Vector2( 22, -2), 18, canopy_dk)
		draw_circle(Vector2( 0, -14), 30, canopy_md)
		draw_circle(Vector2(-18, -8), 14, canopy_md)
		draw_circle(Vector2( 18, -8), 14, canopy_md)
		draw_circle(Vector2( 0, -20), 24, canopy_lt)
		draw_circle(Vector2(-10, -24), 12, canopy_lt)
		draw_circle(Vector2( 10, -24), 12, canopy_lt)
		# Golden leaf sparkles around the canopy edge.
		for li in range(10):
			var la := float(li) * TAU / 10.0
			var lr := 22.0 + float(li % 3) * 5.0
			draw_circle(Vector2(cos(la) * lr, sin(la) * lr * 0.7 - 14.0),
				2.2, Color(gold_warm.r, gold_warm.g, gold_warm.b, 0.85 * pulse2))
		# Central highlight bloom.
		draw_circle(Vector2(0, -18), 8.0,
			Color(gold_warm.r, gold_warm.g, gold_warm.b, 0.45 * pulse))
	elif ratio > 0.5:
		draw_circle(Vector2( 0,  -8), 30, canopy_dk)
		draw_circle(Vector2(-18, -2), 14, canopy_dk)
		draw_circle(Vector2( 18, -2), 14, canopy_dk)
		draw_circle(Vector2( 0, -14), 24, canopy_md)
		draw_circle(Vector2( 0, -18), 16, canopy_lt)
		for li in range(6):
			var la := float(li) * TAU / 6.0
			draw_circle(Vector2(cos(la) * 18.0, sin(la) * 12.0 - 12.0),
				1.8, Color(gold.r, gold.g, gold.b, 0.65 * pulse2))
	elif ratio > 0.25:
		draw_circle(Vector2(0, -10), 22, canopy_dk)
		draw_circle(Vector2(0, -14), 16, canopy_md)
	else:
		draw_circle(Vector2(0, -10), 12, canopy_dk.darkened(0.25))

## Mining rock dispatch. Each tier has a distinct silhouette so the player
## can read the ore type at a glance without relying purely on color:
##   copper   — chunky lumpy boulder (warm orange-brown)
##   iron     — angular faceted polygon (cool gray-blue)
##   gold     — gray host rock with bright yellow vein + flecks
##   mithril  — tall pointy crystal cluster with a glowing aura
##   adamant  — small dense faceted polygon (dark green)
##   runite   — tall jagged spires (deep red)
## Hover lightening is applied per-helper via `is_hovered` rather than the
## caller's `c`/`cd` so each tier can use its own spec palette regardless of
## what the spawn color was set to. The cracks overlay (mining progress) is
## shared by all tiers and drawn after the per-tier shape.
func _draw_rock(ratio: float, _c: Color, cd: Color) -> void:
	if _state == State.DEPLETED:
		draw_circle(Vector2(-8, 4), 5, cd)
		draw_circle(Vector2(4, 6), 4, cd)
		draw_circle(Vector2(-1, 8), 3, cd.darkened(0.2))
		return
	if required_level < 15:
		_draw_rock_copper()
	elif required_level < 30:
		_draw_rock_iron()
	elif required_level < 50:
		_draw_rock_gold()
	elif required_level < 70:
		_draw_rock_mithril()
	elif required_level < 85:
		_draw_rock_adamant()
	else:
		_draw_rock_runite()
	# Mining-progress cracks — shown on top of every tier's silhouette.
	var cracks := 4 - int(ratio * 4.0 + 0.99)
	if cracks >= 1:
		draw_line(Vector2(-8, -6), Vector2(4, 8), Color(0.05, 0.05, 0.05, 0.85), 1.5)
	if cracks >= 2:
		draw_line(Vector2(6, -8), Vector2(-2, 6), Color(0.05, 0.05, 0.05, 0.85), 1.5)
	if cracks >= 3:
		draw_line(Vector2(-4, -10), Vector2(8, 4), Color(0.05, 0.05, 0.05, 0.70), 1.2)

func _hover_tint(col: Color) -> Color:
	return col.lightened(0.18) if is_hovered else col

## Copper — chunky boulder. Multiple overlapping rounded lobes for a "bumpy
## potato" feel. Warm orange-brown with darker undersides and a few specks.
func _draw_rock_copper() -> void:
	var base := _hover_tint(Color(0.65, 0.40, 0.20))
	var dark := base.darkened(0.30)
	var light := base.lightened(0.20)
	draw_circle(Vector2(0, 4), 13, dark)
	draw_circle(Vector2(-7, -1), 8, base)
	draw_circle(Vector2(6, -2), 9, light)
	draw_circle(Vector2(2, 6), 7, base.darkened(0.15))
	draw_circle(Vector2(-3, -7), 5, base.lightened(0.25))
	# Copper specks
	draw_circle(Vector2(-4, 2), 1.2, Color(0.95, 0.55, 0.20))
	draw_circle(Vector2(5, 4), 1.0, Color(0.85, 0.45, 0.15))

## Iron — angular jagged polygon with faceted shadow/highlight planes.
func _draw_rock_iron() -> void:
	var base := _hover_tint(Color(0.55, 0.58, 0.65))
	var dark := base.darkened(0.35)
	var light := base.lightened(0.25)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-12, 2), Vector2(-9, -7), Vector2(-3, -10), Vector2(4, -9),
		Vector2(10, -3), Vector2(11, 5), Vector2(6, 9), Vector2(-4, 10),
		Vector2(-10, 7),
	]), base)
	# Dark facet on the lower-right
	draw_colored_polygon(PackedVector2Array([
		Vector2(4, -9), Vector2(10, -3), Vector2(11, 5), Vector2(6, 9),
		Vector2(0, 4),
	]), dark)
	# Highlight facet on the upper-left
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, -7), Vector2(-3, -10), Vector2(0, -4), Vector2(-6, -2),
	]), light)
	# Sharp edge line — emphasizes the angular shape
	draw_line(Vector2(-9, -7), Vector2(4, -9), dark.darkened(0.2), 1.0)
	draw_line(Vector2(4, -9), Vector2(11, 5), dark.darkened(0.2), 1.0)

## Gold — gray host rock with bright yellow vein lines threading through
## and scattered flecks. The host is intentionally neutral so the gold reads.
func _draw_rock_gold() -> void:
	var host := _hover_tint(Color(0.50, 0.46, 0.40))
	var host_d := host.darkened(0.25)
	draw_circle(Vector2(0, 3), 13, host_d)
	draw_circle(Vector2(2, -1), 10, host)
	draw_circle(Vector2(-5, 2), 7, host.darkened(0.10))
	# Veins — strong diagonal lines suggesting an ore seam
	var gold := Color(1.00, 0.85, 0.20)
	draw_line(Vector2(-9, -4), Vector2(8, 6), gold, 2.0)
	draw_line(Vector2(-6, 4), Vector2(5, -7), gold, 1.8)
	draw_line(Vector2(2, -6), Vector2(10, 0), gold.lightened(0.15), 1.4)
	# Flecks
	for p: Vector2 in [Vector2(-4, -1), Vector2(3, 3), Vector2(6, -3),
			Vector2(-7, 5), Vector2(0, 7), Vector2(-2, -6)]:
		draw_circle(p, 1.2, gold.lightened(0.2))

## Mithril — tall pointy crystal cluster with a soft glowing aura. Distinct
## "cluster of triangles" silhouette so it doesn't read as a rock at all.
func _draw_rock_mithril() -> void:
	var base := _hover_tint(Color(0.45, 0.55, 0.95))
	var glow := Color(0.55, 0.40, 0.95, 0.35)
	# Glow aura behind the crystals
	draw_circle(Vector2(0, -1), 16, glow)
	draw_circle(Vector2(0, -1), 12, Color(0.65, 0.55, 1.0, 0.30))
	# Crystal cluster — three pointy spires
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, 8), Vector2(-4, -10), Vector2(0, 8),
	]), base.darkened(0.20))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-3, 9), Vector2(2, -13), Vector2(6, 9),
	]), base)
	draw_colored_polygon(PackedVector2Array([
		Vector2(4, 8), Vector2(9, -8), Vector2(12, 8),
	]), base.darkened(0.10))
	# Bright facets / inner shine
	draw_line(Vector2(2, -13), Vector2(2, 4), base.lightened(0.45), 1.4)
	draw_line(Vector2(-4, -10), Vector2(-4, 2), base.lightened(0.30), 1.0)
	draw_line(Vector2(9, -8), Vector2(9, 2), base.lightened(0.30), 1.0)

## Adamant — small dense faceted block. Deep green, compact (implies weight).
## Smaller silhouette than other tiers reinforces "dense" reading.
func _draw_rock_adamant() -> void:
	var base := _hover_tint(Color(0.20, 0.50, 0.28))
	var dark := base.darkened(0.40)
	var light := base.lightened(0.25)
	# Compact angular block — fewer vertices, tighter shape
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, 0), Vector2(-6, -8), Vector2(2, -9), Vector2(9, -4),
		Vector2(9, 4), Vector2(3, 8), Vector2(-5, 7),
	]), base)
	# Strong diagonal shadow facet (lower-right)
	draw_colored_polygon(PackedVector2Array([
		Vector2(2, -9), Vector2(9, -4), Vector2(9, 4), Vector2(3, 8),
		Vector2(0, 0),
	]), dark)
	# Top highlight facet
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, -8), Vector2(2, -9), Vector2(0, -4), Vector2(-4, -3),
	]), light)
	# A couple of bright green pinpoint flecks
	draw_circle(Vector2(-3, 2), 1.1, base.lightened(0.55))
	draw_circle(Vector2(4, -2), 1.0, base.lightened(0.55))

## Runite — tall jagged spires (deep red). Multiple overlapping triangles
## form a stalagmite-like formation. Spec was "deep red"; loot color is
## purple elsewhere — visual matches the spec, the inventory drop still
## uses its existing purple via _loot_for_node, by design.
func _draw_rock_runite() -> void:
	var base := _hover_tint(Color(0.62, 0.12, 0.16))
	var dark := base.darkened(0.40)
	var light := base.lightened(0.25)
	# Backdrop spires (darker, behind)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-11, 9), Vector2(-7, -8), Vector2(-3, 9),
	]), dark)
	draw_colored_polygon(PackedVector2Array([
		Vector2(4, 9), Vector2(9, -6), Vector2(13, 9),
	]), dark)
	# Foreground spires (lighter, in front)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-7, 10), Vector2(-2, -12), Vector2(4, 10),
	]), base)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, 10), Vector2(6, -4), Vector2(10, 10),
	]), base.darkened(0.15))
	# Bright crystalline edge highlights
	draw_line(Vector2(-2, -12), Vector2(-2, 4), light, 1.4)
	draw_line(Vector2(6, -4), Vector2(6, 6), light, 1.0)
	# A few crimson glow specks
	draw_circle(Vector2(-2, -7), 1.2, Color(1.0, 0.30, 0.25))
	draw_circle(Vector2(6, -1), 1.0, Color(1.0, 0.30, 0.25))

func _draw_fish(ratio: float, c: Color, _cd: Color) -> void:
	if _state == State.DEPLETED:
		draw_rect(Rect2(-18, -9, 36, 18), Color(0.52, 0.42, 0.28))
		draw_line(Vector2(-14, 0), Vector2(14, 0), Color(0.30, 0.20, 0.10), 1.5)
		draw_line(Vector2(-6, -6), Vector2(6, 6), Color(0.30, 0.20, 0.10), 1.5)
		return

	# Water with depth layers
	draw_rect(Rect2(-18, -9, 36, 18), c.darkened(0.22))
	draw_rect(Rect2(-14, -7, 28, 12), c)
	draw_rect(Rect2(-10, -5, 18, 7), c.lightened(0.08))

	# Ripples
	var ripples := int(ratio * 3.0) + 1
	for i in range(ripples):
		var ry := -4.0 + i * 3.5
		draw_arc(Vector2(0.0, ry), float(8 - i * 2), 0.0, PI, 8, Color(1, 1, 1, 0.22), 1.0)

	# Reeds on edges
	draw_line(Vector2(-16.0, 3.0), Vector2(-15.0, -12.0), Color(0.35, 0.55, 0.18, 0.80), 2.0)
	draw_circle(Vector2(-15.0, -12.0), 2.5, Color(0.55, 0.30, 0.08, 0.75))
	draw_line(Vector2(15.0, 1.0), Vector2(16.0, -13.0), Color(0.35, 0.55, 0.18, 0.80), 2.0)
	draw_circle(Vector2(16.0, -13.0), 2.5, Color(0.55, 0.30, 0.08, 0.75))

	# Fish silhouette in water
	if ratio > 0.6:
		draw_colored_polygon(PackedVector2Array([
			Vector2(-5, -1), Vector2(5, -1), Vector2(3, 2), Vector2(-3, 2)]),
			Color(0.28, 0.55, 0.75, 0.45))
		draw_colored_polygon(PackedVector2Array([
			Vector2(5, -1), Vector2(8, -4), Vector2(8, 2)]),
			Color(0.28, 0.55, 0.75, 0.45))

	# Bubbles
	if ratio > 0.85:
		draw_circle(Vector2(-5.0, -13.0), 2.5, Color(0.82, 0.95, 1.0, 0.55))
		draw_circle(Vector2(4.0, -11.0), 1.5, Color(0.82, 0.95, 1.0, 0.45))

func _draw_forge(c: Color, cd: Color) -> void:
	draw_rect(Rect2(-13, -8, 26, 22), cd)
	draw_rect(Rect2(-10, -8, 20, 16), c)
	var fr := 6.0 + sin(_time_elapsed * 4.5) * 1.8
	draw_circle(Vector2( 0, -14), fr,   Color(1.00, 0.50, 0.05))
	draw_circle(Vector2(-4, -10), 4.5,  Color(1.00, 0.70, 0.10))
	draw_circle(Vector2( 4, -10), 4.5,  Color(1.00, 0.70, 0.10))
	draw_circle(Vector2( 0, -14), fr * 0.5, Color(1.00, 0.90, 0.40, 0.75))  # bright core

func _draw_herb(ratio: float, c: Color, cd: Color) -> void:
	if _state == State.DEPLETED:
		draw_rect(Rect2(-9, -2, 18, 10), cd.darkened(0.5))
		return
	# Dispatch by name so each forageable can read distinct at a glance.
	match display_name:
		"Berry Bush":    _draw_berry_bush(ratio); return
		"Ancient Root":  _draw_ancient_root(ratio); return
		_:               pass

	# Soil patch
	draw_rect(Rect2(-10, -1, 20, 12), cd.darkened(0.4))
	draw_rect(Rect2(-8, -3, 16, 8), cd.darkened(0.15))

	var count := int(ratio * 2.0) + 1
	if count >= 3:
		draw_circle(Vector2(-5, -5), 5, c)
		draw_circle(Vector2(-6, -8), 3.5, c.lightened(0.1))
		draw_circle(Vector2(5, -5), 5, c.lightened(0.05))
		draw_circle(Vector2(6, -8), 3.5, c)
		draw_circle(Vector2(0, -7), 5, c.lightened(0.12))
		# Flower
		draw_circle(Vector2(0.0, -12.0), 3.0, Color(1.00, 0.88, 0.20, 0.90))
		draw_circle(Vector2(0.0, -12.0), 1.5, Color(0.95, 0.55, 0.05, 0.90))
	elif count >= 2:
		draw_circle(Vector2(-4, -4), 5, c)
		draw_circle(Vector2(-5, -7), 3.5, c.lightened(0.1))
		draw_circle(Vector2(4, -4), 5, c.lightened(0.05))
	else:
		draw_circle(Vector2(0, -3), 4, c.darkened(0.10))

## Berry Bush — overlapping leaf-cluster bush, slightly wider than tall.
## Red and purple berries scattered across the canopy with tiny highlights,
## soft ground stain beneath. Quantity of berries scales with `ratio`.
func _draw_berry_bush(ratio: float) -> void:
	var leaf_dk := Color(0.10, 0.32, 0.10)
	var leaf_md := Color(0.22, 0.48, 0.18)
	var leaf_lt := Color(0.40, 0.65, 0.25)
	var red    := Color(0.85, 0.18, 0.22)
	var purple := Color(0.55, 0.18, 0.65)
	# Soft ground stain (wider than tall).
	draw_circle(Vector2(0.0, 8.0), 13.0, Color(0.04, 0.04, 0.03, 0.30))
	draw_circle(Vector2(-3.0, 10.0), 8.0, Color(0.04, 0.04, 0.03, 0.22))
	# Bush body — three large dark clusters forming a wide footprint.
	draw_circle(Vector2(-8.0, -1.0), 9.5, leaf_dk)
	draw_circle(Vector2( 8.0, -1.0), 9.5, leaf_dk)
	draw_circle(Vector2( 0.0, -6.0), 10.0, leaf_dk)
	# Mid-tone overlay — slightly inset so the dark forms a rim.
	draw_circle(Vector2(-6.0, -2.0), 7.0, leaf_md)
	draw_circle(Vector2( 6.0, -2.0), 7.0, leaf_md)
	draw_circle(Vector2( 0.0, -5.0), 8.0, leaf_md)
	# Highlight pops.
	draw_circle(Vector2(-3.0, -4.0), 4.5, leaf_lt)
	draw_circle(Vector2( 4.0, -5.0), 4.0, leaf_lt)
	# Berries — scattered across the surface, count scales with ratio.
	var berries := PackedVector2Array([
		Vector2(-6, -4), Vector2( 3, -2), Vector2(-2, -8),
		Vector2( 7, -4), Vector2(-8,  1), Vector2( 2,  2),
		Vector2(-4, -7), Vector2( 6,  1), Vector2( 0, -3),
	])
	var berry_cols: Array[Color] = [
		red, purple, red, red, purple, red, purple, red, purple,
	]
	var berry_count: int = clampi(int(ratio * float(berries.size())) + 2, 2, berries.size())
	for i in range(berry_count):
		var p: Vector2 = berries[i]
		var bc: Color = berry_cols[i]
		draw_circle(p, 1.7, bc.darkened(0.30))
		draw_circle(p, 1.4, bc)
		draw_circle(p + Vector2(-0.4, -0.4), 0.5, bc.lightened(0.55))

## Ancient Root — gnarled twisted root emerging from ground with multiple
## dark brown tendrils spreading outward and small glowing amber rune
## carvings etched into the surface. Pulse on the runes drives the eye.
func _draw_ancient_root(_ratio: float) -> void:
	var root_dk := Color(0.10, 0.06, 0.03)
	var root_md := Color(0.28, 0.18, 0.08)
	var root_lt := Color(0.45, 0.30, 0.14)
	var rune := Color(1.00, 0.65, 0.18)
	var pulse := 0.65 + sin(_time_elapsed * 2.4) * 0.30
	# Dark ground stain with radiating root lines (six of them).
	draw_circle(Vector2(0.0, 6.0), 16.0, Color(0.05, 0.03, 0.02, 0.45))
	draw_circle(Vector2(2.0, 8.0), 11.0, Color(0.05, 0.03, 0.02, 0.40))
	for ri in range(6):
		var ra := float(ri) * TAU / 6.0
		draw_line(
			Vector2(cos(ra) * 6.0, sin(ra) * 4.0 + 4.0),
			Vector2(cos(ra) * 17.0, sin(ra) * 11.0 + 4.0),
			Color(0.05, 0.03, 0.02, 0.65), 1.6)
	# Tendrils spreading out from the central root (5 of them, biased upward).
	for ti in range(5):
		var ta := -PI * 0.5 + (float(ti) - 2.0) * 0.55
		var tx := cos(ta) * 13.0
		var ty := sin(ta) * 6.0
		draw_line(Vector2(0.0, 0.0), Vector2(tx, ty), root_dk, 3.0)
		draw_line(Vector2(0.0, 0.0), Vector2(tx, ty), root_md, 1.8)
	# Main twisted root body — dark base + mid-tone interior + highlight ridge.
	draw_colored_polygon(PackedVector2Array([
		Vector2(-8, 6), Vector2(-4, -8), Vector2( 4,-10),
		Vector2( 8,-2), Vector2( 6, 6), Vector2(-6, 8),
	]), root_dk)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-6, 4), Vector2(-2, -6), Vector2( 3, -8),
		Vector2( 6,-1), Vector2( 4, 4), Vector2(-4, 5),
	]), root_md)
	draw_line(Vector2(-4, 4), Vector2(-1, -6), root_lt, 1.2)
	draw_line(Vector2( 1,-6), Vector2( 5, -1), root_lt, 1.2)
	# Rune carvings — geometric glowing symbols. Pulse modulates alpha.
	var rune_a := Color(rune.r, rune.g, rune.b, pulse)
	# Triangle (top of root)
	draw_line(Vector2(-3, -3), Vector2( 0, -6), rune_a, 1.6)
	draw_line(Vector2( 0, -6), Vector2( 3, -3), rune_a, 1.6)
	draw_line(Vector2(-3, -3), Vector2( 3, -3), rune_a, 1.6)
	# Twin vertical bars
	draw_line(Vector2(-2,  0), Vector2(-2,  3), rune_a, 1.6)
	draw_line(Vector2( 2,  0), Vector2( 2,  3), rune_a, 1.6)
	# Small diamond
	draw_line(Vector2( 0,  1), Vector2( 2,  3), rune_a, 1.6)
	draw_line(Vector2( 2,  3), Vector2( 0,  5), rune_a, 1.6)
	draw_line(Vector2( 0,  5), Vector2(-2,  3), rune_a, 1.6)
	draw_line(Vector2(-2,  3), Vector2( 0,  1), rune_a, 1.6)
	# Rune sparkle center dot
	draw_circle(Vector2(0, -1), 0.8, Color(1.0, 0.92, 0.55, pulse))

func _draw_fire(_c: Color) -> void:
	# Stone ring
	for i in range(6):
		var a := i * TAU / 6.0
		draw_circle(Vector2(cos(a) * 10.0, sin(a) * 3.5 + 5.0), 3.5, Color(0.35, 0.32, 0.28))
	# Log pile
	draw_rect(Rect2(-11, 1, 22, 4), Color(0.42, 0.26, 0.08))
	draw_line(Vector2(-10.0, 5.0), Vector2(10.0, 1.0), Color(0.38, 0.22, 0.06), 3.0)
	# Ember glow at base
	draw_circle(Vector2(0.0, -1.0), 5.5, Color(1.00, 0.55, 0.10, 0.55))
	# Animated flame layers
	var f := _time_elapsed * 5.0
	var fl := 8.0 + sin(f) * 2.5
	draw_circle(Vector2(0.0, -(fl * 0.6)), fl * 0.70, Color(1.00, 0.40, 0.05, 0.88))
	draw_circle(Vector2(-3.0, -(fl * 0.5)), fl * 0.55, Color(1.00, 0.60, 0.08, 0.82))
	draw_circle(Vector2(3.0, -(fl * 0.5)), fl * 0.55, Color(1.00, 0.60, 0.08, 0.82))
	draw_circle(Vector2(0.0, -(fl * 0.85)), fl * 0.35, Color(1.00, 0.88, 0.35, 0.78))

func _draw_bank(_c: Color) -> void:
	# Stone base
	draw_rect(Rect2(-16, 2, 32, 16), Color(0.48, 0.45, 0.40))
	draw_rect(Rect2(-14, 0, 28, 6),  Color(0.58, 0.54, 0.48))
	# Pillar left
	draw_rect(Rect2(-15, -18, 6, 22), Color(0.55, 0.52, 0.46))
	draw_rect(Rect2(-13, -16, 3, 18), Color(0.66, 0.62, 0.54))
	# Pillar right
	draw_rect(Rect2(9, -18, 6, 22),  Color(0.55, 0.52, 0.46))
	draw_rect(Rect2(10, -16, 3, 18), Color(0.66, 0.62, 0.54))
	# Roof beam
	draw_rect(Rect2(-17, -22, 34, 6), Color(0.52, 0.48, 0.42))
	draw_rect(Rect2(-15, -21, 30, 3), Color(0.68, 0.64, 0.56))
	# Door arch
	draw_rect(Rect2(-5, -6, 10, 14),  Color(0.28, 0.18, 0.08))
	draw_circle(Vector2(0.0, -6.0), 5.0, Color(0.28, 0.18, 0.08))
	# Door handle
	draw_circle(Vector2(3.0, -1.0), 1.5, Color(0.80, 0.68, 0.20))
	# Gold coin symbol on facade
	draw_circle(Vector2(0.0, -13.0), 4.5, Color(0.85, 0.70, 0.10))
	draw_circle(Vector2(0.0, -13.0), 3.0, Color(0.95, 0.82, 0.22))
	draw_rect(Rect2(-1.5, -16.0, 3.0, 6.0), Color(0.80, 0.65, 0.08))

func _draw_building(c: Color, cd: Color) -> void:
	match display_name:
		"Great Hall":
			draw_rect(Rect2(-22, -19, 44, 37), cd)
			draw_rect(Rect2(-20, -17, 40, 33), c)
			draw_rect(Rect2(-20, -17, 40, 5), c.lightened(0.18))
			draw_rect(Rect2(-6, -2, 12, 20), Color(0.20, 0.12, 0.04))
			draw_rect(Rect2(-4, 0, 8, 14), Color(0.30, 0.18, 0.06))
			draw_rect(Rect2(-16, -9, 6, 6), Color(0.68, 0.72, 0.50, 0.75))
			draw_rect(Rect2(10,  -9, 6, 6), Color(0.68, 0.72, 0.50, 0.75))
			draw_rect(Rect2(-1.5, -17, 3, 5), c.lightened(0.35))  # roof ridge
		"Tavern":
			draw_rect(Rect2(-18, -15, 36, 29), cd)
			draw_rect(Rect2(-16, -13, 32, 25), c)
			draw_rect(Rect2(-16, -13, 32, 5), c.lightened(0.20))
			draw_rect(Rect2(-5, -1, 10, 15), Color(0.22, 0.12, 0.04))
			draw_rect(Rect2(-10, -23, 20, 8), Color(0.55, 0.38, 0.14))
			draw_rect(Rect2(-8,  -22, 16, 5), Color(0.75, 0.55, 0.22))
			draw_rect(Rect2(-13, -7, 6, 6), Color(0.72, 0.78, 0.52, 0.78))
			draw_rect(Rect2(7,   -7, 6, 6), Color(0.72, 0.78, 0.52, 0.78))
		"Warehouse":
			draw_rect(Rect2(-20, -11, 40, 25), cd)
			draw_rect(Rect2(-18,  -9, 36, 21), c)
			draw_rect(Rect2(-18,  -9, 36, 4), c.lightened(0.12))
			draw_rect(Rect2(-10,  1, 20, 13), Color(0.30, 0.22, 0.10))
			draw_line(Vector2(0, 1), Vector2(0, 13), Color(0.42, 0.32, 0.16), 1.5)
			draw_line(Vector2(-18, -2), Vector2(18, -2), c.darkened(0.35), 1.0)
			draw_line(Vector2(-18,  2), Vector2(18,  2), c.darkened(0.35), 1.0)
		"Chapel":
			draw_rect(Rect2(-13, -13, 26, 27), cd)
			draw_rect(Rect2(-11, -11, 22, 23), c)
			draw_rect(Rect2(-5,   1, 10, 13), Color(0.25, 0.20, 0.14))
			draw_circle(Vector2(0, 1), 5, Color(0.25, 0.20, 0.14))
			draw_rect(Rect2(-1.5, -11, 3, 10), Color(0.88, 0.85, 0.78))
			draw_rect(Rect2(-5, -7, 10, 3),    Color(0.88, 0.85, 0.78))
			draw_circle(Vector2(0, -3), 4, Color(0.62, 0.72, 0.88, 0.72))
		_:  # House
			draw_rect(Rect2(-15, -13, 30, 27), cd)
			draw_rect(Rect2(-13, -11, 26, 23), c)
			draw_rect(Rect2(-13, -11, 26, 4), c.lightened(0.18))
			draw_rect(Rect2(-5,  -1, 10, 14), Color(0.28, 0.18, 0.08))
			draw_circle(Vector2(3.0, 6.0), 1.5, Color(0.82, 0.66, 0.15))
			draw_rect(Rect2(-11, -5, 7, 7), Color(0.68, 0.74, 0.52, 0.78))

func _draw_crafting_bench(ratio: float, _c: Color, _cd: Color) -> void:
	var wood := Color(0.52, 0.34, 0.14)
	var wdark := wood.darkened(0.30)
	# Legs
	draw_rect(Rect2(-16, 2, 4, 16), wdark)
	draw_rect(Rect2(12, 2, 4, 16), wdark)
	# Under-shelf
	draw_rect(Rect2(-14, 10, 28, 3), wdark)
	# Table top
	draw_rect(Rect2(-18, -2, 36, 6), wood)
	draw_rect(Rect2(-18, -2, 36, 2), wood.lightened(0.12))
	# Hammer on top
	draw_rect(Rect2(-10, -14, 3, 14), Color(0.48, 0.30, 0.10))
	draw_rect(Rect2(-13, -16, 10, 5), Color(0.62, 0.60, 0.58))
	draw_rect(Rect2(-13, -16, 10, 2), Color(0.78, 0.76, 0.74))
	# Saw on top
	draw_rect(Rect2(2, -10, 14, 2), Color(0.70, 0.70, 0.68))
	for ti in range(5):
		draw_line(Vector2(float(3 + ti * 3), -10.0), Vector2(float(2 + ti * 3), -12.0),
				Color(0.75, 0.74, 0.72), 1.0)
	if ratio < 0.6:
		draw_line(Vector2(-14, 0), Vector2(-8, 3), wdark.darkened(0.3), 1.0)

func _draw_archery_target(ratio: float, _c: Color, _cd: Color) -> void:
	# Post
	draw_rect(Rect2(-2, 2, 4, 18), Color(0.45, 0.30, 0.12))
	draw_rect(Rect2(-5, 14, 10, 4), Color(0.38, 0.24, 0.08))
	# Target rings outer → inner
	draw_circle(Vector2(0, -8), 15, Color(0.85, 0.22, 0.10))
	draw_circle(Vector2(0, -8), 11, Color(0.92, 0.88, 0.18))
	draw_circle(Vector2(0, -8), 7,  Color(0.20, 0.45, 0.82))
	draw_circle(Vector2(0, -8), 4,  Color(0.10, 0.10, 0.10))
	draw_circle(Vector2(0, -8), 2,  Color(0.92, 0.92, 0.92))
	# Embedded arrow
	draw_line(Vector2(-3, -13), Vector2(0, -8), Color(0.45, 0.28, 0.10), 1.5)
	draw_colored_polygon(PackedVector2Array([Vector2(-5, -15), Vector2(-3, -13), Vector2(-1, -17)]),
			Color(0.45, 0.28, 0.10))
	if ratio < 0.5:
		draw_line(Vector2(6, -10), Vector2(3, -6), Color(0.45, 0.28, 0.10), 1.5)
		draw_circle(Vector2(3, -6), 1.5, Color(0.92, 0.88, 0.18))

func _draw_runestone(ratio: float, _c: Color, _cd: Color) -> void:
	var stone := Color(0.45, 0.43, 0.40)
	# Base platform
	draw_rect(Rect2(-10, 12, 26, 6), stone.darkened(0.15))
	# Main pillar
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, 16), Vector2(10, 16), Vector2(8, -20), Vector2(-8, -20)
	]), stone)
	# Pillar left-face highlight
	draw_colored_polygon(PackedVector2Array([
		Vector2(-9, 14), Vector2(-2, 14), Vector2(-3, -18), Vector2(-8, -18)
	]), Color(0.60, 0.57, 0.53, 0.35))
	# Rune glyphs
	var glow := Color(0.60, 0.22, 0.95, 0.85)
	draw_line(Vector2(-5, -14), Vector2(-5,  -6), glow, 1.5)
	draw_line(Vector2( 5, -14), Vector2( 5,  -6), glow, 1.5)
	draw_line(Vector2(-5, -10), Vector2( 5, -10), glow, 1.5)
	draw_line(Vector2( 0,  -2), Vector2( 0,   6), glow, 1.5)
	draw_line(Vector2( 0,  -2), Vector2(-4,   2), glow, 1.5)
	draw_line(Vector2( 0,  -2), Vector2( 4,   2), glow, 1.5)
	draw_circle(Vector2(0, -4), 15, Color(0.55, 0.20, 0.90, 0.07))
	if ratio > 0.6:
		draw_circle(Vector2(-8, -18), 1.5, Color(0.85, 0.65, 1.0, 0.70))
		draw_circle(Vector2( 9, -10), 1.2, Color(0.85, 0.65, 1.0, 0.60))

## Distinct purple/blue crystalline rock — clearly not a mining rock. Three
## faceted shards growing out of a small dark base; inner cyan glow that
## pulses softly via `_time`, dimmer as ratio drops so a near-depleted node
## visibly fades. Admin-placed only — no procedural variant exists.
func _draw_essence(ratio: float) -> void:
	var base := Color(0.16, 0.10, 0.24)
	var crystal_a := Color(0.45, 0.30, 0.90)   # deep violet
	var crystal_b := Color(0.30, 0.55, 0.95)   # icy blue
	var glow_col  := Color(0.65, 0.55, 1.00, 0.18 + 0.10 * sin(_time_elapsed * 2.5))
	# Base mound
	draw_colored_polygon(PackedVector2Array([
		Vector2(-14, 14), Vector2(14, 14), Vector2(10, 6), Vector2(-10, 6)
	]), base)
	# Soft glow halo (drawn before crystals so they sit on top)
	draw_circle(Vector2(0, -2), 18.0, glow_col)
	# Center shard — tallest
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4, 8), Vector2(4, 8), Vector2(2, -16), Vector2(0, -20), Vector2(-2, -16)
	]), crystal_a)
	# Center shard highlight
	draw_line(Vector2(-1, 6), Vector2(0, -18), Color(0.95, 0.85, 1.0, 0.65), 1.0)
	# Left shard — shorter, blue-leaning
	draw_colored_polygon(PackedVector2Array([
		Vector2(-10, 10), Vector2(-3, 10), Vector2(-5, -8), Vector2(-8, -6)
	]), crystal_b)
	# Right shard — slim
	draw_colored_polygon(PackedVector2Array([
		Vector2(4, 10), Vector2(10, 10), Vector2(8, -4), Vector2(6, -10)
	]), crystal_a.lightened(0.10))
	# Sparkle dots (only when not near-depleted)
	if ratio > 0.5:
		draw_circle(Vector2(-7, -2), 1.2, Color(0.95, 0.92, 1.00, 0.85))
		draw_circle(Vector2(5, -6),  1.0, Color(0.95, 0.92, 1.00, 0.70))
		draw_circle(Vector2(0, -12), 1.0, Color(1.00, 0.95, 1.00, 0.90))

func _draw_construction(ratio: float, _c: Color, _cd: Color) -> void:
	var wood := Color(0.52, 0.36, 0.14)
	var wdark := wood.darkened(0.28)
	# Ground planks
	draw_rect(Rect2(-18, 14, 36, 4), wdark)
	for pi in range(3):
		draw_line(Vector2(float(-8 + pi * 10), 14.0), Vector2(float(-8 + pi * 10), 18.0),
				wdark.darkened(0.2), 1.0)
	# Vertical posts
	draw_rect(Rect2(-16, -14, 4, 30), wood)
	draw_rect(Rect2( 12, -14, 4, 30), wood)
	# Top beam
	draw_rect(Rect2(-16, -16, 32, 4), wood)
	draw_rect(Rect2(-16, -16, 32, 2), wood.lightened(0.12))
	# Diagonal brace
	draw_line(Vector2(-14, -12), Vector2(14, 12), wdark, 2.0)
	# Stacked planks
	draw_rect(Rect2(-6,  2, 14, 4), wood.lightened(0.05))
	draw_rect(Rect2(-6,  6, 14, 4), wood)
	draw_rect(Rect2(-6, 10, 14, 4), wood.darkened(0.08))
	# Pickaxe resting on frame
	draw_rect(Rect2(5, -10, 2, 8), Color(0.45, 0.28, 0.08))
	draw_rect(Rect2(2, -12, 8, 4), Color(0.62, 0.60, 0.58))
	draw_rect(Rect2(2, -12, 8, 2), Color(0.75, 0.74, 0.72))
	if ratio < 0.4:
		draw_line(Vector2(-12, -8), Vector2(-6, 2), wdark.darkened(0.4), 1.5)

func _draw_stick(c: Color) -> void:
	# A couple of small twigs on the ground
	draw_line(Vector2(-8, 2), Vector2(7, -1), c, 2.0)
	draw_line(Vector2(-4, 4), Vector2(4, -3), c.darkened(0.15), 1.5)
	draw_line(Vector2(2, 0), Vector2(8, 3), c.lightened(0.1), 1.5)

func _draw_stone(c: Color, cd: Color) -> void:
	# Rounded pebble cluster
	draw_circle(Vector2(0, 2), 7, cd)
	draw_circle(Vector2(0, 1), 6, c)
	draw_circle(Vector2(-4, 3), 5, cd)
	draw_circle(Vector2(-4, 2), 4, c.lightened(0.05))
	draw_circle(Vector2(3, 3), 4, cd)
	draw_circle(Vector2(3, 2), 3, c.lightened(0.08))
	draw_circle(Vector2(-1, -2), 2, c.lightened(0.18))  # highlight

func _draw_auction_house(c: Color, cd: Color) -> void:
	# Base structure — wide hall
	draw_rect(Rect2(-20, -10, 40, 22), cd)
	draw_rect(Rect2(-18,  -8, 36, 18), c)
	# Roof — triangular peaked roof
	draw_colored_polygon(PackedVector2Array([
		Vector2(-22, -10), Vector2(22, -10), Vector2(0, -26)]),
		cd.lightened(0.1))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-20, -10), Vector2(20, -10), Vector2(0, -24)]),
		c.lightened(0.15))
	# Door
	draw_rect(Rect2(-5, 0, 10, 12), cd.darkened(0.4))
	draw_rect(Rect2(-4, 1, 4, 11), cd.darkened(0.5))
	draw_rect(Rect2( 1, 1, 3, 11), cd.darkened(0.5))
	# Windows
	draw_rect(Rect2(-16, -6, 8, 7), cd.darkened(0.3))
	draw_rect(Rect2( 8,  -6, 8, 7), cd.darkened(0.3))
	draw_rect(Rect2(-15, -5, 6, 5), Color(0.45, 0.65, 0.90, 0.70))
	draw_rect(Rect2(  9, -5, 6, 5), Color(0.45, 0.65, 0.90, 0.70))
	# Gold coin sign above door
	draw_circle(Vector2(0, -13), 4, Color(0.88, 0.72, 0.12))
	draw_circle(Vector2(0, -13), 2.5, Color(1.00, 0.90, 0.30))

## Standalone door (Phase 6) — placeable by admin as the entry point to an
## interior. Click sends enter_interior to the server. `c` is the door's
## display color from data (admin can recolor per door); `cd` is the darker
## variant used for trim/depth. Default brown-wood look when `c` arrives
## from the catalog's brown palette.
func _draw_door(c: Color, cd: Color) -> void:
	# Stone-or-wood frame around the door — sits on the ground line.
	var frame_c := cd.darkened(0.25)
	draw_rect(Rect2(-14, -19, 28, 38), frame_c)
	# Wooden door panel — vertical plank look via two darker grooves.
	draw_rect(Rect2(-11, -16, 22, 32), c)
	draw_line(Vector2(-4, -15), Vector2(-4, 15), cd.darkened(0.40), 1.0)
	draw_line(Vector2( 4, -15), Vector2( 4, 15), cd.darkened(0.40), 1.0)
	# Iron banding — two horizontal bars top and bottom.
	var iron := Color(0.18, 0.18, 0.20)
	draw_rect(Rect2(-12, -11, 24, 2), iron)
	draw_rect(Rect2(-12,   9, 24, 2), iron)
	# Top edge of frame as a stone lintel.
	draw_rect(Rect2(-15, -20, 30, 3), frame_c.darkened(0.20))
	# Knob — small gold circle on the right side, ~hand height.
	draw_circle(Vector2(7, 0), 1.6, Color(0.95, 0.78, 0.20))
	draw_circle(Vector2(7, 0), 0.8, Color(1.00, 0.92, 0.55))
	# Subtle threshold shadow at the base.
	draw_rect(Rect2(-13, 16, 26, 3), Color(0.0, 0.0, 0.0, 0.30))
