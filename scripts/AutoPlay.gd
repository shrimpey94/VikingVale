extends Node
## In-client AUTOPLAY AI — drives the REAL local player through the game so a
## recorded window IS a real player: real movement, real gather swings, real XP
## toasts, real inventory + craft UI. NO relay, NO spectator — everything is the
## genuine client doing genuine things, so it can't look "like a bot".
##
## Spawned by World when the client is launched with `--autoplay` (after login).
## It only ever calls the same public entry points a human click would:
## Player.autoplay_interact() (walk + gather/craft-station) and the HUD's craft
## helper. Decision cadence is deliberately unhurried so it reads as a real player.

const _CRAFT_STATIONS := ["crafting", "forge"]
const STATION_RANGE   := 96.0
const FIGHT_RADIUS    := 360.0   # only pick a fight with a monster this close
const MELEE_RANGE     := 44.0    # walk this near before swinging
const LOOT_RADIUS     := 320.0   # collect loot drops within this of the player

var _player: Node2D = null
var _hud: Node = null
var _decide_at: float = 0.0
var _started_at: float = 0.0
var _chat_tidied: bool = false   # minimized the chat/combat log once at startup
# Stuck handling: the real player only SLIDES along walls (no auto-path), so it can
# grind into a dead-end while still "moving" and never reach its target. We track
# PROGRESS toward the current move goal; if it stops improving, we're stuck → back
# off the wall + blacklist that whole area so we pick a REACHABLE target instead.
var _pursuing: Node2D = null
var _blacklist: Dictionary = {}      # instance_id -> expiry time
var _area_block: Array = []          # [[Vector2 center, radius, expiry], …]
var _move_target: Vector2 = Vector2.INF
var _best_dist: float = INF
var _progress_at: float = 0.0
# Side-step recovery: when blocked, step PERPENDICULAR around the obstacle (a tile
# or more, alternating sides + growing), then resume heading to the real goal.
var _resume_node: Node2D = null
var _resume_point: Vector2 = Vector2.INF
var _stuck_count: int = 0
var _stuck_side: float = 1.0
const SIDESTEP_TILE := 96.0          # ~1.5 tiles per side-step, ×_stuck_count
const MAX_SIDESTEPS := 4
const BLACKLIST_SECS   := 30.0
const REACHED_DIST     := 64.0       # "close enough that we actually got there"
const STUCK_NOPROGRESS := 2.0        # secs with no progress toward the goal = stuck
const RECOVER_STEP     := 180.0      # back this far off the obstacle to recover
const AREA_BLOCK_RADIUS := 120.0     # blacklist targets within this of a stuck spot

# Roam: travel to OTHER towns for variety + to show the world (user request). Town
# centres (server TOWN_CENTERS): bjorn / kjelvik / frostheim / ironwood / eastmark.
const TOWN_CENTERS := [
	Vector2(7823, 4488), Vector2(2780, 3760), Vector2(1390, 944),
	Vector2(3580, 4960), Vector2(5944, 5872)]
const ROAM_INTERVAL   := 300.0       # set off for a new town roughly every ~5 min
const ROAM_TIMEOUT    := 150.0       # give up a roam that can't reach in this long
const ROAM_ARRIVE     := 260.0       # "we made it to the town" radius
var _roam_target: Vector2 = Vector2.INF
var _next_roam_at: float = 0.0
var _roam_deadline: float = 0.0
# Admin-drawn road route the current roam is following (GameManager.road_path).
# Empty = no graph, walk straight (the stuck-watchdog still skirts obstacles).
var _road_route: PackedVector2Array = PackedVector2Array()
var _road_i: int = 0
const ROAD_WP_REACHED := 120.0   # "close enough" to advance to the next waypoint
# LOCAL detour: on a gather/bank/craft trip we walk STRAIGHT and only fall back
# to the road graph when side-stepping has failed (user: local trips use roads
# only if stuck). Following this route hands back to the original goal (held in
# _resume_node/_resume_point) once we've skirted the obstacle.
var _detour_route: PackedVector2Array = PackedVector2Array()
var _detour_i: int = 0
const DETOUR_MAX_FIRST := 1400.0   # bail if the nearest road node is this far off

# Scene timeline: log WHAT we're doing + WHEN (unix time) to a file next to the exe
# so AutoContent can slice scene-typed clips (gather 1.5-2s, travel 5-7s, craft
# 3.5-4s, combat 6-14s) instead of even chunks.
var _scene: String = ""
var _scene_log: String = ""

func _ready() -> void:
	_started_at = _now()
	# Settle in + play locally first; the first town-roam comes a few minutes in.
	_next_roam_at = _now() + ROAM_INTERVAL
	# Fresh scene log next to the running exe (AutoContent reads it to cut clips).
	_scene_log = OS.get_executable_path().get_base_dir().path_join("autoplay_scenes.jsonl")
	var f := FileAccess.open(_scene_log, FileAccess.WRITE)   # truncate for this run
	if f != null:
		f.close()
	set_process(true)

## Record a scene change (unix-timestamped) so the clip slicer knows what happened
## when. Cheap; only writes on an actual change.
func _set_scene(scene_name: String) -> void:
	if scene_name == _scene or _scene_log == "":
		return
	_scene = scene_name
	var f := FileAccess.open(_scene_log, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_scene_log, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify({
		"t": Time.get_unix_time_from_system(), "scene": scene_name}))
	f.close()

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		return
	if _hud == null:
		_hud = get_parent().get_node_or_null("HUD")
	# Tuck the chat/combat log away the moment we can — left open it sits over the
	# gameplay and ruins the clip. Do it once, as soon as the HUD exists.
	if not _chat_tidied and _hud != null and _hud.has_method("spectator_minimize_chat"):
		_hud.spectator_minimize_chat()
		_chat_tidied = true
	# Let the world stream in for a beat after spawn before we start acting.
	if _now() - _started_at < 3.0:
		return
	# STUCK WATCHDOG — runs EVERY tick (even while the player is sliding along a
	# wall, "moving" but not progressing). If we stop getting closer to the goal,
	# recover instead of grinding into the wall for the whole clip.
	if _move_target != Vector2.INF:
		var d: float = _player.global_position.distance_to(_move_target)
		if d <= REACHED_DIST:
			_stuck_count = 0        # got there — reset the side-step ladder
			_clear_move()
		elif d < _best_dist - 3.0:
			_best_dist = d
			_progress_at = _now()
		elif _now() - _progress_at > STUCK_NOPROGRESS:
			_on_stuck()
			return
	# Wait out a visible craft sequence in progress (window open, item being made).
	if _hud != null and _hud.has_method("autoplay_busy") and bool(_hud.call("autoplay_busy")):
		return
	if _now() < _decide_at:
		return
	# Only issue a new order when the player is free — never interrupt a real
	# walk/gather/fight in progress (that's what looked like "multiple things").
	if not bool(_player.call("autoplay_is_idle")):
		return
	_decide()

# ── movement + stuck recovery ─────────────────────────────────────────────────
func _set_move(point: Vector2, node: Node2D) -> void:
	_move_target = point
	_pursuing = node
	_best_dist = _player.global_position.distance_to(point)
	_progress_at = _now()

func _clear_move() -> void:
	_move_target = Vector2.INF
	_pursuing = null

func _go_interact(node: Node2D) -> void:
	_set_move((node as Node2D).global_position, node)
	_player.call("autoplay_interact", node)

func _go_walk(point: Vector2) -> void:
	_set_move(point, null)
	_player.call("autoplay_walk", point)

func _on_stuck() -> void:
	var stuck_at: Vector2 = _player.global_position
	# If a road DETOUR is already running and we STILL got stuck, the reroute
	# failed too — abandon it and give up on the goal it was serving.
	if _detour_route.size() > 0:
		_detour_route = PackedVector2Array()
		var dnode: Node2D = _resume_node
		var dpoint: Vector2 = _resume_point
		_resume_node = null
		_resume_point = Vector2.INF
		_give_up_goal(stuck_at, dnode, dpoint)
		return
	var goal_node: Node2D = _pursuing
	var goal_point: Vector2 = _move_target
	_stuck_count += 1
	if _stuck_count <= MAX_SIDESTEPS:
		# SIDE-STEP around the obstacle: a tile-or-more perpendicular to the goal
		# direction (alternating sides, growing each try), THEN resume the goal.
		# This is how a human walks around a wall/mountain/water edge.
		var to_goal: Vector2 = goal_point - stuck_at
		if to_goal.length() < 1.0:
			to_goal = Vector2(1, 0)
		to_goal = to_goal.normalized()
		_stuck_side = -_stuck_side
		var perp: Vector2 = Vector2(-to_goal.y, to_goal.x) * _stuck_side
		var waypoint: Vector2 = stuck_at + perp * (SIDESTEP_TILE * float(_stuck_count)) \
			+ to_goal * 24.0
		_resume_node = goal_node
		_resume_point = goal_point
		_set_move(waypoint, null)
		_player.call("autoplay_walk", waypoint)
		_decide_at = _now() + 1.2
		return
	# Side-steps exhausted. Before giving up, try a ROAD DETOUR toward the goal via
	# the admin-drawn graph (local trips only lean on the roads once truly stuck).
	if _try_road_detour(stuck_at, goal_point, goal_node):
		_stuck_count = 0
		return
	# No road help either — blacklist + back off and go play somewhere reachable.
	_give_up_goal(stuck_at, goal_node, goal_point)

## Route around a stubborn obstacle using the admin road graph: follow it toward
## the goal, then hand back to the goal (resume_*). Returns false when there's no
## usable graph (caller falls back to blacklist + back-off). Only reached after
## side-steps fail, so straight-line local trips are unaffected until stuck.
func _try_road_detour(stuck_at: Vector2, goal_point: Vector2, goal_node: Node2D) -> bool:
	if GameManager.road_nodes.size() < 2:
		return false
	var route := GameManager.road_path(stuck_at, goal_point)
	if route.size() < 2:
		return false
	# The first road node must be plausibly reachable (not across the same wall).
	if stuck_at.distance_to(route[0]) > DETOUR_MAX_FIRST:
		return false
	_detour_route = route
	_detour_i = 0
	_resume_node = goal_node      # reach/interact the real target once detour ends
	_resume_point = goal_point
	_set_scene("travel")
	_go_walk(_detour_next_point())
	_decide_at = _now() + 1.2
	return true

## Next detour waypoint, skipping any already reached. When consumed, _detour_i
## lands at/past the end and the caller hands back to the resume goal.
func _detour_next_point() -> Vector2:
	var ppos: Vector2 = _player.global_position
	while _detour_i < _detour_route.size() \
			and ppos.distance_to(_detour_route[_detour_i]) <= ROAD_WP_REACHED:
		_detour_i += 1
	if _detour_i < _detour_route.size():
		return _detour_route[_detour_i]
	return ppos

## Blacklist a goal + its area, back off, and clear pursuit state — the shared
## "can't reach this, move on" path used when both side-steps and a road detour
## have failed.
func _give_up_goal(stuck_at: Vector2, goal_node: Node2D, goal_point: Vector2) -> void:
	if goal_node != null and is_instance_valid(goal_node):
		_blacklist[goal_node.get_instance_id()] = _now() + BLACKLIST_SECS
	_area_block.append([goal_point, AREA_BLOCK_RADIUS, _now() + BLACKLIST_SECS])
	if _roam_target != Vector2.INF and goal_point == _roam_target:
		_roam_target = Vector2.INF   # can't reach that town — play here instead
	_stuck_count = 0
	_resume_node = null
	_resume_point = Vector2.INF
	var away: Vector2 = stuck_at - goal_point
	if away.length() < 1.0:
		away = Vector2(1, 0).rotated(randf() * TAU)
	_clear_move()
	_player.call("autoplay_walk", stuck_at + away.normalized() * RECOVER_STEP)
	_decide_at = _now() + 1.4

func _blocked_pos(pos: Vector2) -> bool:
	for e in _area_block:
		if float(e[2]) > _now() and pos.distance_to(e[0]) < float(e[1]):
			return true
	return false

func _blocked(node: Node) -> bool:
	if node == null:
		return false
	if float(_blacklist.get(node.get_instance_id(), 0.0)) > _now():
		return true
	return _blocked_pos((node as Node2D).global_position)

func _decide() -> void:
	# Road DETOUR in progress (a local trip got stuck and rerouted via the graph):
	# follow the road waypoints until we've skirted the obstacle, THEN fall through
	# to the resume-goal path below to actually reach/interact the original target.
	if _detour_route.size() > 0:
		var dp := _detour_next_point()
		if _detour_i < _detour_route.size():
			_set_scene("travel")
			_go_walk(dp)
			_decide_at = _now() + 1.2
			return
		_detour_route = PackedVector2Array()   # consumed → hand back to the goal

	# After a side-step around an obstacle, RESUME heading to the real goal (if it's
	# still valid/unblocked) — this is what actually gets us around walls.
	if _resume_point != Vector2.INF:
		var rn: Node2D = _resume_node
		var rp: Vector2 = _resume_point
		_resume_node = null
		_resume_point = Vector2.INF
		if rn != null and is_instance_valid(rn) and not _blocked(rn):
			_go_interact(rn)
			_decide_at = _now() + 1.0
			return
		elif not _blocked_pos(rp):
			_go_walk(rp)
			_decide_at = _now() + 1.0
			return
		# goal got blocked meanwhile — fall through and pick something fresh.

	# 0) Roam to another town periodically for variety + to show the world. When a
	#    road graph is drawn we FOLLOW it town-to-town (real road-following travel,
	#    user request); with no graph we walk straight and let the stuck-watchdog
	#    skirt walls. On arrival or timeout, play locally.
	if _roam_target != Vector2.INF:
		if _player.global_position.distance_to(_roam_target) <= ROAM_ARRIVE \
				or _now() > _roam_deadline:
			_roam_target = Vector2.INF   # arrived / gave up — gather here now
			_road_route = PackedVector2Array()
		else:
			_set_scene("travel")
			_go_walk(_road_next_point())
			_decide_at = _now() + 1.5
			return
	elif _now() > _next_roam_at:
		_next_roam_at = _now() + ROAM_INTERVAL
		_roam_deadline = _now() + ROAM_TIMEOUT
		_roam_target = _pick_far_town()
		# Precompute the road route (nearest node → BFS → nearest node → target).
		_road_route = GameManager.road_path(_player.global_position, _roam_target)
		_road_i = 0
		_set_scene("travel")
		_go_walk(_road_next_point())
		_decide_at = _now() + 1.5
		return

	# 1) Fight a winnable monster if one wandered close (walk into melee, then attack;
	#    the real combat window + swings take over, and autoplay_is_idle() blocks us
	#    until the fight ends).
	var mob := _best_monster()
	if mob != null:
		var md: float = _player.global_position.distance_to((mob as Node2D).global_position)
		if md > MELEE_RANGE:
			_set_scene("travel")   # walking TO the fight is travel, not combat
			_go_walk((mob as Node2D).global_position)
			_decide_at = _now() + 1.0
		else:
			_set_scene("combat")   # in melee + swinging = the actual fight
			_clear_move()   # stop tracking the approach, let combat run
			_player.call("autoplay_attack", mob)
			_decide_at = _now() + 3.0
		return

	# 1.5) Grab loot on the ground (from a kill / drop) before moving on — a real
	#      player never leaves their drops. set_pending_pickup makes the player
	#      auto-collect the instant it walks into range.
	var loot := _nearest_loot()
	if loot != null:
		_player.call("set_pending_pickup", loot)
		_go_walk((loot as Node2D).global_position)
		_decide_at = _now() + 1.5
		return

	# 2) Pack full → walk to a bank and deposit the surplus (keeping tools).
	if GameManager.free_slots() <= 0:
		_set_scene("bank")
		var bank := _nearest_of(["bank"])
		if bank != null and _player.global_position.distance_to(bank.global_position) > STATION_RANGE:
			_go_interact(bank)
			_decide_at = _now() + 2.0
			return
		if _hud != null and _hud.has_method("autoplay_bank_sequence"):
			if bool(_hud.call("autoplay_bank_sequence")):
				_decide_at = _now() + 5.0
				return

	# 3) Turn gathered materials into gear: walk to a crafting station, then craft
	#    VISIBLY (open window → make the item → close).
	if _can_craft():
		_set_scene("craft")
		var station := _nearest_of(_CRAFT_STATIONS)
		if station != null and _player.global_position.distance_to(station.global_position) > STATION_RANGE:
			_go_interact(station)   # walk to the forge first
			_decide_at = _now() + 2.0
			return
		if _hud != null and _hud.has_method("autoplay_craft_sequence"):
			if bool(_hud.call("autoplay_craft_sequence")):
				_decide_at = _now() + 5.0   # the visible sequence runs (window→make→close)
				return

	# 4) Cook a batch of raw food at a campfire (then it's eatable / bankable).
	if _hud != null and _hud.has_method("autoplay_should_cook") and bool(_hud.call("autoplay_should_cook")):
		_set_scene("cook")
		var fire := _nearest_of(["fire"])
		if fire != null and _player.global_position.distance_to(fire.global_position) > STATION_RANGE:
			_go_interact(fire)   # walk to the campfire first
			_decide_at = _now() + 2.0
			return
		if _hud.has_method("autoplay_cook_sequence") and bool(_hud.call("autoplay_cook_sequence")):
			_decide_at = _now() + 5.0
			return

	# 5) Wield any gear/tool upgrade we're carrying (shows progression on camera).
	if GameManager.autoplay_equip_upgrades():
		_decide_at = _now() + 1.4
		return

	# 6) Otherwise gather the nearest node we can work.
	var node := _best_gather_node()
	if node != null:
		_set_scene("gather")
		_go_interact(node)
		_decide_at = _now() + 2.0   # time to walk over + start swinging
		return

	# 7) Nothing workable nearby — brief wait; movement streams more nodes in.
	_decide_at = _now() + 1.0

# ── combat target ─────────────────────────────────────────────────────────────
func _best_monster() -> Node:
	# Nearest ALIVE monster within FIGHT_RADIUS that we can beat (its level ≤ our
	# melee level) and only when we're healthy enough to start a fight.
	var hp_frac: float = float(GameManager.current_hp) / float(maxi(1, GameManager.get_max_hp()))
	if hp_frac < 0.55:
		return null
	var melee: int = GameManager.get_skill_level("melee")
	var best: Node = null
	var best_d := FIGHT_RADIUS
	var ppos: Vector2 = _player.global_position
	for m in get_tree().get_nodes_in_group("monster"):
		if not (m is Node2D) or not is_instance_valid(m):
			continue
		if not bool(m.get("is_alive")):
			continue
		# NEVER attack the town watch — guards spawn to HELP; swinging at one
		# escalates the whole watch onto the bot (the "guards then kill me" bug).
		if str(m.get("monster_type")).begins_with("guard"):
			continue
		if int(m.get("level")) > melee:
			continue
		var d: float = ppos.distance_to((m as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = m
	return best

# ── target selection ──────────────────────────────────────────────────────────
func _best_gather_node() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	var ppos: Vector2 = _player.global_position
	for n in get_tree().get_nodes_in_group("interactable"):
		if not (n is Node2D) or not is_instance_valid(n):
			continue
		if not n.has_method("autoplay_gatherable") or not bool(n.call("autoplay_gatherable")):
			continue
		if _blocked(n):
			continue   # can't reach it (wall) — skip until the blacklist expires
		var d: float = ppos.distance_to((n as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = n as Node2D
	return best

func _nearest_of(types: Array) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	var ppos: Vector2 = _player.global_position
	for n in get_tree().get_nodes_in_group("interactable"):
		if not (n is Node2D) or not is_instance_valid(n):
			continue
		if str(n.get("interactable_type_str")) not in types:
			continue
		if _blocked(n):
			continue
		var d: float = ppos.distance_to((n as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = n as Node2D
	return best

## A town centre that isn't the one we're at — pick among the farthest few so the
## bot actually crosses the map instead of hopping next door.
func _nearest_loot() -> Node2D:
	var best: Node2D = null
	var best_d := LOOT_RADIUS
	var ppos: Vector2 = _player.global_position
	for l in get_tree().get_nodes_in_group("loot_drop"):
		if not (l is Node2D) or not is_instance_valid(l):
			continue
		if _blocked(l):
			continue
		var d: float = ppos.distance_to((l as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = l as Node2D
	return best

## The next point to walk toward on the current roam: the current road waypoint,
## advancing past any we've already reached. Falls back to the raw roam target
## when there's no route or we've consumed it (route's last point IS the target).
func _road_next_point() -> Vector2:
	var ppos: Vector2 = _player.global_position
	while _road_i < _road_route.size() \
			and ppos.distance_to(_road_route[_road_i]) <= ROAD_WP_REACHED:
		_road_i += 1
	if _road_i < _road_route.size():
		return _road_route[_road_i]
	return _roam_target

func _pick_far_town() -> Vector2:
	var ppos: Vector2 = _player.global_position
	var far: Array = TOWN_CENTERS.duplicate()
	far.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return ppos.distance_to(a) > ppos.distance_to(b))
	var pool: Array = far.slice(0, mini(3, far.size()))
	return pool[randi() % pool.size()]

func _can_craft() -> bool:
	return _hud != null and _hud.has_method("autoplay_can_craft") \
		and bool(_hud.call("autoplay_can_craft"))
