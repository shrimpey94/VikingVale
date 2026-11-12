extends Node3D

## v1.6 3D MIGRATION — P1 skeleton (networked). A PARALLEL 3D client that reuses
## every autoload (NetworkManager/GameManager/Events/…) + the server UNCHANGED.
## NOT the default main scene — run via the 3D dev launcher (world3d.tscn).
##
## What P1 proves: the real map as 3D heightmap terrain, a tilt/orbit/zoom follow
## camera, a networked LOCAL PLAYER (click/keyboard move → the SAME "move" the
## server expects, via a hidden Node2D proxy in group "player" that
## NetworkManager._sync_position reads), and OTHER PLAYERS as billboards mirrored
## off NetworkManager._other_players. Coordinate glue: 3D = px * SCALE, height on y.
##
## Controls: click / WASD = move · Q/E orbit · R/F tilt · wheel zoom · Esc quit.

const GroundScript      := preload("res://scripts/Ground.gd")
const Mesh3DScript      := preload("res://scripts/Mesh3D.gd")
const VillageArt = preload("res://scripts/art/VillagePrototypeArt.gd")
const StonePickupArt = preload("res://scripts/art/StonePickupArt.gd")
const ForestArt = preload("res://scripts/art/ForestArt.gd")
# Real 2D LOGIC nodes (gather/combat/collision) live off-screen paired to each 3D
# mesh visual; picking routes to them so the whole 2D interaction pipeline reuses.
const InteractableTscn  := preload("res://scenes/Interactable.tscn")
const MonsterScript      := preload("res://scripts/Monster.gd")
const NPCScript          := preload("res://scripts/NPC.gd")
const CaravanScript      := preload("res://scripts/Caravan.gd")
const LootDropScript     := preload("res://scripts/LootDrop.gd")
const WorldThrallScript  := preload("res://scripts/WorldThrall.gd")
const WorldScript        := preload("res://scripts/World.gd")

const MAP_N := 300
const CELL  := 1.0
const SCALE := CELL / 32.0          # 3D units per SERVER px
const CHUNK := 30
const N1 := MAP_N + 1
const SEA_LEVEL := -1.0
const PLAYER_SPEED_PX := 78.0       # mirror Player.BASE_SPEED
const GROUND_LIFT := 0.15           # keep mesh feet a hair above the terrain (anti-clip)

# Terrain
var _tile_col: PackedColorArray
var _tile_h: PackedFloat32Array
var _corner: PackedFloat32Array
var _terrain_mat: StandardMaterial3D
var _chunks: Dictionary = {}   # "cx,cy" → MeshInstance3D (reused on rebuild)
var _env: Environment          # for fog (raised to isolate the overworld in interiors)
var _water: MeshInstance3D
# P6 interiors/dungeons — a themed 3D room the player is dropped into (overworld
# hidden while inside). The real InteriorScene provides wall collision + exit + decor.
var _in_interior := false
var _dungeon_mode := false     # in an instanced DUNGEON (entities stay live) vs a decor interior
var _interior_scene: Node2D
var _interior_room: MeshInstance3D
var _interior_ret := Vector2.ZERO
const INTERIOR_Y := 0.0

# Local player — the REAL Player node (player.tscn, group "player") is the shared
# LOGIC driver: it owns movement, collision, gather, combat, and position-sync to
# the server (external_control suppresses its own 2D mouse input). World3D only
# READS its px position to place the 3D billboard + follow-camera, and feeds it
# click-to-move targets from 3D rays.
var _player_node: Node2D
var _ground_node: Node2D      # hidden 2D Ground child — collision + biome data only
var _spawned := false
var _player_spr: Node3D            # the player's rigged low-poly body (CharRig)
var _kb_active := false        # true while a WASD key is feeding a move-target

# Other players
var _op_bb: Dictionary = {}   # pid → MeshInstance3D
var _mesh: Node               # Mesh3D — shared low-poly meshes per type/look
var _mesh_mat: Material       # the factory's shared flat-shaded material

# ── P3 world entities ─────────────────────────────────────────────────────────
# Every entity is a PAIR keyed by server id: a 2D logic node (gather/combat/
# collision + the interaction API) added to $Interactables (renders off-screen),
# and a 3D mesh visual mirrored to its position each frame. Static town geometry
# uses ids t:/kc:/n:/b:; admin + live entities use their server id.
var _ent: Dictionary = {}          # id → {"n": Node2D logic, "v": MeshInstance3D visual}
## Raw wire dict per admin entity (id → {kind,subtype,x,y,data}) for the Inspect editor.
var _admin_entity_data: Dictionary = {}

# ── Unified streaming for admin (a:) entities (mirrors World.gd) ──────────────
## Numerous types (trees/rocks/herbs/fish/monsters/NPCs) stream by chunk at the
## same radius as wild resources; the few semi-permanent types stay always-loaded.
const _ADMIN_GATHER_TYPES3D := ["tree", "rock", "herb", "fish", "essence", "stick", "stone"]
var _admin_index3d: Dictionary = {}      # chunk Vector2i → Array[entity dict]
var _admin_id_chunk3d: Dictionary = {}   # id → chunk Vector2i
var _admin_loaded3d: Dictionary = {}     # chunk Vector2i → Array[id]
## id → data override (name/dialogue/level) for pre-existing NPCs/bosses (n:/b:).
var _edits_data3d: Dictionary = {}
var _ent_container: Node2D         # $Interactables — holds the off-screen 2D logic nodes
var _mob_target: Dictionary = {}   # monster id → latest server target px (smoothed)
var _dead_mobs: Dictionary = {}    # monster id → true while dead (mesh faded out, sync skipped)
var _loot: Dictionary = {}         # LootDrop (Area2D) → 3D pickup mesh
var _gold_piles: Dictionary = {}   # pile_id → LootDrop node
var _pvp_piles: Dictionary = {}    # pile_id → LootDrop node
var _static_built := false
# P6 — chunk-streamed procedural WILD resources (trees/rocks/herbs outside towns),
# reusing World.gd's deterministic generators so ids + placement match the 2D world.
const RES_CHUNK_PX := 512
const RES_ATTEMPTS := 8
const RES_RADIUS := 2                 # chunks each direction around the player
var _wdata: Object                    # tree-less World instance = resource generator
var _res_chunks: Dictionary = {}      # Vector2i chunk → Array[entity id]
var _last_res_chunk := Vector2i(99999, 99999)
# Terrain edits (paint + sculpt) mark only the touched chunks dirty; _process
# rebuilds them on a short throttle so a drag stays responsive (no 90k-quad churn).
var _dirty_chunks: Dictionary = {}   # "cx,cy" → true
var _dirty_accum := 0.0
# P5 — admin height sculpt
var _h_delta: Dictionary = {}        # tile idx → height delta (biome base offset)
var _sculpt := false                 # H-key sculpt mode active (admin only)
var _brush := 3.0                    # H-key sculpt brush radius, tiles
var _h_changed := false              # sculpt edited → flush to server on next rebuild
var _pending_sculpt: Dictionary = {} # idx_str → absolute delta, flushed to the server
const _SCULPT_STRENGTH := 0.9        # units added/removed per second under the brush

## Which town an entity stands in, for the NPC regional wardrobe. Mirrors
## World._REGION_RECTS so admin NPCs read as belonging to their town.
const _REGION_RECTS: Array = [
	["kjelvik",   Rect2(1984, 3008, 1376, 1376)],
	["frostheim", Rect2( 704,  256, 1376, 1376)],
	["ironwood",  Rect2(2880, 4288, 1376, 1376)],
	["eastmark",  Rect2(5248, 5184, 1376, 1376)],
	["bjorn",     Rect2(7200, 3744, 1376, 1376)],
]

## Interactable type_strs that are big built structures (vs small resource nodes).
## Drives billboard size/scale so a longhouse isn't rendered mushroom-sized.
const _STRUCTURE_TYPES: Dictionary = {
	"building": true, "large_house": true, "grand_hall": true, "forge": true,
	"fire": true, "bank": true, "crafting": true, "archery": true,
	"runestone": true, "construction": true, "auction_house": true, "well": true,
	"armory_rack": true, "market_stall": true, "clan_hall": true,
	"fortified_wall": true, "watchtower": true, "guard_tower": true,
	"stronghold": true, "banner": true, "outpost": true, "seal_statue": true,
	"world_eater": true, "farm_plot": true,
}

# Camera
var _cam: Camera3D
var _cam_yaw := 0.0
var _cam_pitch := 0.82
var _cam_dist := 24.0

func _ready() -> void:
	print(">>> WORLD3D (v1.6 P1) RUNNING <<<")
	# Child Ground (built in its own _ready before ours) supplies collision +
	# biome data for the real Player/HUD; it must NEVER render (it would draw the
	# flat 2D terrain over the 3D view), so we force it hidden every frame.
	_ground_node = $Ground as Node2D
	_build_environment()
	_import_map()
	_load_sculpt()          # admin height edits layer on the biome base
	_precompute_corners()
	_build_all_chunks()
	_build_water()
	_build_camera()
	_mesh = Mesh3DScript.new()
	add_child(_mesh)
	_mesh_mat = _mesh.get("mat") as Material
	# The real Player (scene child, group "player") drives all gameplay; put it in
	# external-control mode and silence its 2D camera so the 3D view owns the
	# screen and the 2D canvas stays at identity (its 2D sprite renders off-screen).
	_player_node = $Player as Node2D
	if _player_node != null:
		_player_node.set("external_control", true)
		_player_node.visible = false   # the 3D mesh is the visual; its 2D art must not draw
		var pcam := _player_node.get_node_or_null("Camera2D") as Camera2D
		if pcam != null:
			pcam.enabled = false
	_ent_container = $Interactables as Node2D
	# P4 — the HUD's 2D world-space UI can't project onto a 3D camera; suppress it
	# and render 3D-native nameplates/HP bars/damage numbers/bubbles ourselves.
	($HUD as CanvasLayer).set("world_ui_3d", true)
	_white_tex = _make_white_tex()
	Events.world_chat.connect(_on_world_chat3d)
	Events.replay_prologue.connect(_on_replay_prologue)
	# The 2D logic nodes render their own art in the canvas at their px position —
	# for low-px towns (e.g. Frostheim) that lands ON-SCREEN, "stuck" to the view.
	# Hide the whole layer; collision (StaticBody) + logic are unaffected by
	# visibility, and per-node `.visible` flags (used for the mesh mirror) still read.
	_ent_container.visible = false
	NetworkManager.login_ok.connect(_on_login_ok)
	# Live admin tile-paints from the server (the EXACT map) — arrives after login.
	Events.tile_overrides_received.connect(_on_overrides)
	Events.terrain_heights_received.connect(_on_terrain_heights_full)
	Events.terrain_height_set.connect(_on_terrain_height_set)
	# P3 — world entities off the SAME server feeds the 2D World.gd consumes.
	Events.world_entities_received.connect(_on_world_entities3d)
	Events.world_entity_added.connect(_ingest_admin_ent3d)
	Events.world_entity_removed.connect(_remove_ent3d)
	Events.world_entity_moved.connect(_on_ent_moved3d)
	Events.world_entity_rotated.connect(_on_ent_rotated3d)
	# Admin edits (move/delete) to PRE-EXISTING entities (towns/NPCs/bosses) come
	# through the entity-edit feed, not world_entity_moved.
	Events.entity_edit_applied.connect(_on_entity_edit_applied3d)
	Events.entity_edits_received.connect(_on_entity_edits3d)
	Events.entity_data_edited.connect(_on_entity_data_edited3d)
	# Shared monster combat state (routed to the paired 2D Monster nodes).
	Events.mob_state.connect(_on_mob_state)
	Events.mob_hit.connect(_on_mob_hit)
	Events.mob_died.connect(_on_mob_died)
	Events.mob_respawned.connect(_on_mob_respawned)
	Events.mob_states_received.connect(_on_mob_states_received)
	Events.mob_positions_updated.connect(_on_mob_positions3d)
	# Shared resource-node state (routed to the paired 2D Interactable nodes).
	Events.gather_granted.connect(_on_gather_granted)
	Events.gather_denied.connect(_on_gather_denied)
	Events.node_remote_locked.connect(_on_node_remote_locked)
	Events.node_remote_unlocked.connect(_on_node_remote_unlocked)
	Events.node_remote_depleted.connect(_on_node_remote_depleted)
	Events.node_remote_respawned.connect(_on_node_remote_respawned)
	Events.node_states_received.connect(_on_node_states_received)
	# Loot — Monster.spawn_loot adds LootDrop nodes to $Interactables; mirror any that
	# appear to 3D pickups. Gold/PvP piles are event-driven → we create the LootDrop
	# (which then mirrors through the same signal), matching World.gd's 2D handling.
	_ent_container.child_entered_tree.connect(_on_container_child)
	Events.gold_pile_spawn.connect(_on_gold_pile_spawn3d)
	Events.gold_pile_remove.connect(_on_gold_pile_remove3d)
	NetworkManager.pvp_pile_spawn.connect(_on_pvp_pile_spawn3d)
	NetworkManager.pvp_pile_remove.connect(_on_pvp_pile_remove3d)
	# P6 — trade caravans (moving wagons) + monster projectiles (ranged/magic FX).
	Events.caravans_updated.connect(_on_caravans_updated3d)
	Events.caravan_hit.connect(_on_caravan_hit3d)
	Events.caravan_removed.connect(_on_caravan_removed3d)
	NetworkManager.monster_projectile.connect(_on_projectile3d)
	# Farming — the 3D client wires these too (was 2D-only, so 3D never showed
	# plot stages or granted harvests). Routes to the paired Interactable's
	# set_farm_stage + the shared GameManager grant/refund helpers.
	NetworkManager.farm_plot_state.connect(_on_farm_plot_state3d)
	NetworkManager.farm_plot_burst.connect(_on_farm_plot_burst3d)
	NetworkManager.farm_harvest_ok.connect(_on_farm_harvest_ok3d)
	NetworkManager.farm_harvest_fail.connect(_on_farm_harvest_fail3d)
	NetworkManager.farm_reject.connect(_on_farm_reject3d)
	Events.thralls_updated.connect(_on_thralls_updated3d)   # visible assigned thralls
	# P6 — interiors: drop into a themed 3D room (overworld hidden while inside).
	Events.interior_entered.connect(_on_interior_entered3d)
	Events.interior_exited.connect(_on_interior_exited3d)
	Events.dungeon_entered.connect(_on_dungeon_entered3d)   # direct-portal instanced dungeon
	# P-ANIM — drive the player rig's action swing from the gather/action signals.
	Events.player_start_action.connect(func(atype: String, _t: Node) -> void:
		if _player_spr != null and _player_spr.has_method("play_action"):
			_player_spr.call("play_action", atype))
	Events.player_stop_action.connect(func() -> void:
		if _player_spr != null and _player_spr.has_method("stop_action"):
			_player_spr.call("stop_action"))
	# Combat swings (synced): the LOCAL player's attack swing + any monster's attack.
	Events.attack_swung.connect(func(_style: String) -> void:
		if _player_spr != null and _player_spr.has_method("play_action"):
			_player_spr.call("play_action", "attack"))
	Events.monster_attacked.connect(_on_monster_attacked3d)
	Events.equipment_changed.connect(_rebuild_player_visual)   # swap weapon mesh on equip
	# Live admin tile-painting (server broadcasts each edit) → repaint 3D terrain.
	Events.tile_override_set.connect(_on_tile_override_set)
	Events.tile_override_cleared.connect(_on_tile_override_cleared)
	Events.tile_overrides_bulk_received.connect(_on_tile_overrides_bulk3d)
	# Admin tools in 3D — panel on login (gated on rank), teardown on demote.
	NetworkManager.admin_rank_changed.connect(_on_admin_rank_changed3d)
	# Static town geometry needs no network — build it as soon as terrain exists.
	_build_static_entities()
	_wdata = WorldScript.new()   # persistent data/generator bag (never entered in tree)
	if NetworkManager.state == NetworkManager.NetState.LOGGED_IN:
		_on_login_ok(GameManager.appearance if GameManager != null else {})

## Apply the server's live tile-paints onto the base terrain + repaint the mesh.
func _on_overrides(overrides: Array) -> void:
	if _ground_node != null:
		_ground_node.call("apply_tile_overrides", overrides)   # collision + AdminPanel biome reads
	var touched := false
	for o: Variant in overrides:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var tx := int(d.get("tx", -1))
		var ty := int(d.get("ty", -1))
		if tx < 0 or tx >= MAP_N or ty < 0 or ty >= MAP_N:   # exterior tiles only
			continue
		var nm := str(d.get("biome", ""))
		if nm == "":
			continue
		var idx := ty * MAP_N + tx
		_tile_h[idx] = _biome_height(nm)
		_tile_col[idx] = _biome_color(nm)
		touched = true
	if touched:
		_precompute_corners()
		_rebuild_all_chunks()
		_reseat_static_and_entities()   # terrain moved → re-seat once-placed billboards

## Re-place billboards that are seated only once (static town geometry + admin/live
## entities) onto the CURRENT terrain. Heights change when the server's admin
## paints arrive after login, so their y goes stale and they sink/float. The
## player + other players are already re-placed every frame.
func _reseat_static_and_entities() -> void:
	for id: Variant in _ent.keys():
		var d: Dictionary = _ent[id]
		if not is_instance_valid(d["v"]):
			continue
		var v := d["v"] as Node3D
		_place(v, (d["n"] as Node2D).global_position if is_instance_valid(d["n"]) else v.get_meta("epx", Vector2.ZERO))

const LoadingScreenScript := preload("res://scripts/LoadingScreen.gd")
const _OpeningPrologue := preload("res://scripts/ui/OpeningPrologue.gd")
var _loading: CanvasLayer

func _on_login_ok(_pdata: Dictionary) -> void:
	# Cover the post-login / switch world-build with a loading page.
	if _loading == null or not is_instance_valid(_loading):
		_loading = LoadingScreenScript.new()
		add_child(_loading)
	# The real Player is positioned by GameManager.apply_login (emits
	# player_respawned with the saved x,y) — World3D just reads it. Build the
	# player billboard + snap the camera onto it.
	_spawn_player()
	# On a scene switch (2D↔3D toggle) the server's one-time login bursts already
	# fired in the OLD scene, so replay the NetworkManager caches to rebuild the
	# REAL admin map (heights/paints), entities, and edits — not the bare procedural.
	if not NetworkManager.tile_overrides_cache.is_empty():
		_on_overrides(NetworkManager.tile_overrides_cache)   # terrain heights/colours FIRST
	if not NetworkManager.terrain_heights_cache.is_empty():
		_on_terrain_heights_full(NetworkManager.terrain_heights_cache)   # admin sculpt
	for e: Variant in NetworkManager.world_entities_cache:
		if e is Dictionary:
			_spawn_admin_ent3d(e as Dictionary)
	if not NetworkManager.entity_edits_cache.is_empty():
		_on_entity_edits3d(NetworkManager.entity_edits_cache)   # apply moves/deletes
	_spawn_admin_panel_if_admin()   # admin toolbox in the 3D client
	NetworkManager.reattach_other_players.call_deferred()   # rebuild others after a switch
	# Position continuity across a 2D↔3D switch (fresh login keeps the server pos).
	# 3D buildings have collision the 2D side lacks, so if the carried spot lands
	# INSIDE a structure, nudge to the nearest outside wall so we never spawn stuck.
	if GameManager.switch_pos.x >= 0.0 and _player_node != null:
		var sp := _resolve_spawn_px(GameManager.switch_pos)
		_player_node.global_position = sp
		_player_node.set("_target_pos", sp)
		GameManager.switch_pos = Vector2(-1, -1)
	if _loading != null and is_instance_valid(_loading):
		_loading.call("set_ready")   # world state applied → let the player continue
	Events.world_build_ready.emit(true)   # the intro director times reveals on this

## Push `px` out to the nearest wall of any structure whose blocking footprint it
## sits inside (so a 2D→3D switch onto a house doesn't trap the player in collision).
func _resolve_spawn_px(px: Vector2) -> Vector2:
	for id: Variant in _ent.keys():
		if not is_instance_valid((_ent[id] as Dictionary)["n"]):
			continue
		var n := (_ent[id] as Dictionary)["n"] as Node2D
		var body := n.get_node_or_null("StructureBody")
		if body == null:
			body = n.get_node_or_null("StructureBody3D")
		if body == null:
			continue
		var half := _body_half(body as Node)
		if half == Vector2.ZERO:
			continue
		var c := n.global_position
		var dx := px.x - c.x
		var dy := px.y - c.y
		if absf(dx) < half.x and absf(dy) < half.y:   # inside the footprint → eject
			var pen_x := half.x - absf(dx)
			var pen_y := half.y - absf(dy)
			var margin := 26.0
			if pen_x <= pen_y:
				px.x = c.x + (signf(dx) if dx != 0.0 else 1.0) * (half.x + margin)
			else:
				px.y = c.y + (signf(dy) if dy != 0.0 else 1.0) * (half.y + margin)
			return px
	return px

func _body_half(body: Node) -> Vector2:
	for gc: Node in body.get_children():
		if gc is CollisionShape2D and (gc as CollisionShape2D).shape is RectangleShape2D:
			return ((gc as CollisionShape2D).shape as RectangleShape2D).size * 0.5
	return Vector2.ZERO

func _spawn_player() -> void:
	if _spawned:
		return
	_spawned = true
	_player_spr = _make_char_node(_player_appearance())
	add_child(_player_spr)
	_update_player_visual()
	_cam.position = _player_3d()   # snap camera onto the player
	_update_camera()
	_maybe_show_prologue()

# First-login storybook — shown ONCE per account (same `user://prologue.cfg` flag as
# the 2D client, keyed by username). In 3D there's no Camera2D, so the prologue plays
# the book + white→shore dissolve without the pan-out.
func _maybe_show_prologue() -> void:
	if NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
		return   # never before login (defensive; _spawn_player already runs post-login)
	if GameManager.intro_active:
		return   # the persistent director (started in the 2D client) owns the intro
	var uname := NetworkManager.my_username
	if uname.is_empty():
		uname = "_offline"
	var cfg := ConfigFile.new()
	cfg.load("user://prologue.cfg")
	if bool(cfg.get_value("seen", uname, false)) or _player_node == null:
		return
	# Rare (new players default to 2D): a first login already in the 3D client. Run the
	# same director on the tree root; at the end it stays in 3D (renderer preference).
	GameManager.intro_active = true
	var pro := _OpeningPrologue.new()
	get_tree().root.add_child(pro)
	pro.call("start_intro", _player_px())

# Settings → "Replay Opening": play the storybook again on demand, IN PLACE (no
# routing on a replay). Stays in the 3D client.
func _on_replay_prologue() -> void:
	if _spawned:
		add_child(_OpeningPrologue.new())

# ── 3D shore flythrough — 2D-px waypoints mapped to 3D; the orbit params (dist/pitch/
#    yaw) + a cinematic target animate while _update_camera keeps applying them every
#    frame. TUNE these after watching. Bjorn's ≈ Rect2(7200,3744,1376,1376). ──
const _CINE3D_BEACH       := Vector2(8360, 5000)   # sand SE of the Landing
const _CINE3D_OCEAN       := Vector2(8900, 4300)   # out over the water NE/E
const _CINE3D_BEACH_DIST  := 16.0
const _CINE3D_BEACH_PITCH := 0.32                  # low, near eye-level over the sand
const _CINE3D_BEACH_YAW   := -0.5
const _CINE3D_OCEAN_DIST  := 48.0                  # pulled up + back over the harbour
const _CINE3D_OCEAN_PITCH := 0.62
const _CINE3D_OCEAN_YAW   := -0.2
const _CINE3D_GAME_DIST   := 24.0                  # = gameplay orbit (World3D defaults)
const _CINE3D_GAME_PITCH  := 0.82
const _CINE3D_GAME_YAW    := 0.0
const _CINE3D_SEG1        := 3.2
const _CINE3D_SEG2        := 3.6
var _cine_active := false
var _cine_target := Vector3.ZERO

## Called by OpeningPrologue during the shore reveal — a Camera3D flythrough over the
## real harbour: beach → up-and-out over the ocean → sweep back and settle on the
## character. At the end, if we were routed from the 2D client, fade to black and
## switch back to it; otherwise (a 3D-native intro/replay) let the prologue finish.
func play_shore_cinematic(prologue: Node) -> void:
	if _cam == null or _player_node == null:
		if prologue != null and prologue.has_method("cinematic_done"):
			prologue.call("cinematic_done")
		return
	var beach := Vector3(_CINE3D_BEACH.x, _height_at_world(_CINE3D_BEACH.x, _CINE3D_BEACH.y) + 1.5, _CINE3D_BEACH.y)
	var ocean := Vector3(_CINE3D_OCEAN.x, _height_at_world(_CINE3D_OCEAN.x, _CINE3D_OCEAN.y) + 3.0, _CINE3D_OCEAN.y)
	var pchar := _player_3d() + Vector3(0.0, 1.5, 0.0)
	_cine_active = true   # _update_camera now targets _cine_target, input is gated
	_cine_target = beach
	_cam_dist = _CINE3D_BEACH_DIST
	_cam_pitch = _CINE3D_BEACH_PITCH
	_cam_yaw = _CINE3D_BEACH_YAW
	_update_camera()
	var t := create_tween()
	t.tween_interval(0.9)   # hold on the beach as the white clears
	# 1) up-and-out: sweep the target over the water, pull the camera up + back.
	t.tween_property(self, "_cine_target", ocean, _CINE3D_SEG1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(self, "_cam_dist", _CINE3D_OCEAN_DIST, _CINE3D_SEG1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(self, "_cam_pitch", _CINE3D_OCEAN_PITCH, _CINE3D_SEG1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(self, "_cam_yaw", _CINE3D_OCEAN_YAW, _CINE3D_SEG1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_interval(0.6)
	# 2) sweep back to the character, settling into the gameplay orbit.
	t.tween_property(self, "_cine_target", pchar, _CINE3D_SEG2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(self, "_cam_dist", _CINE3D_GAME_DIST, _CINE3D_SEG2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(self, "_cam_pitch", _CINE3D_GAME_PITCH, _CINE3D_SEG2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.parallel().tween_property(self, "_cam_yaw", _CINE3D_GAME_YAW, _CINE3D_SEG2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.tween_callback(_end_shore_cinematic.bind(prologue))

func _end_shore_cinematic(prologue: Node) -> void:
	_cine_active = false   # camera follows the player again
	# The prologue director owns any 3D→2D handoff (behind its white mask); we just
	# report the flythrough is done.
	if prologue != null and is_instance_valid(prologue) and prologue.has_method("cinematic_done"):
		prologue.call("cinematic_done")

## The player's appearance + their equipped WEAPON id, so the rig shows the real
## weapon (type + tier) instead of a generic axe.
func _player_appearance() -> Dictionary:
	var appr: Dictionary = (GameManager.appearance as Dictionary).duplicate() if GameManager != null else {}
	if GameManager != null:
		return _appr_with_gear(appr, GameManager.equipment)
	return appr

## Fold an equipment dict into an appearance dict as `weapon` + `gear` so
## build_char_rig renders the worn weapon + armour. Shared by the local player and
## other players (their equipment arrives over the wire in the appearance metas).
func _appr_with_gear(appr: Dictionary, eq: Dictionary) -> Dictionary:
	var a := appr.duplicate()
	a["weapon"] = str(eq.get("weapon", ""))
	a["gear"] = {
		"head":    str(eq.get("head", "")),
		"body":    str(eq.get("body", "")),
		"legs":    str(eq.get("legs", "")),
		"hands":   str(eq.get("hands", "")),
		"boots":   str(eq.get("boots", "")),
		"offhand": str(eq.get("offhand", "")),
	}
	return a

## Rebuild the player's 3D body when gear changes (equip a new weapon → new mesh).
func _rebuild_player_visual() -> void:
	if not _spawned or _player_spr == null:
		return
	var px := _player_spr.position
	if is_instance_valid(_player_spr):
		_player_spr.queue_free()
	_player_spr = _make_char_node(_player_appearance())
	_player_spr.position = px
	add_child(_player_spr)

# ── Map import (real biomes + admin paints, from the prototype) ───────────────
func _import_map() -> void:
	# Read the procedural BASE biomes from the child Ground (its _build_cache
	# already ran in its own _ready); the server's live admin paints arrive after
	# login via Events.tile_overrides_received → _on_overrides (see _ready).
	var ground: Object = _ground_node
	if ground == null:                       # headless / safety fallback
		ground = GroundScript.new()
		ground.call("_build_cache")
	_tile_h = PackedFloat32Array(); _tile_h.resize(MAP_N * MAP_N)
	_tile_col = PackedColorArray(); _tile_col.resize(MAP_N * MAP_N)
	for ty in range(MAP_N):
		for tx in range(MAP_N):
			var nm: String = ground.call("_biome_at", tx, ty)
			var idx := ty * MAP_N + tx
			_tile_h[idx] = _biome_height(nm)
			_tile_col[idx] = _biome_color(nm)
	if ground != _ground_node:               # only free the throwaway fallback
		(ground as Object).free()

func _load_map_export() -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists("user://map_export.json"):
		return out
	var f := FileAccess.open("user://map_export.json", FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("overrides"):
		for k: Variant in (parsed as Dictionary)["overrides"].keys():
			out[int(str(k))] = int((parsed as Dictionary)["overrides"][k])
	return out

func _biome_height(nm: String) -> float:
	if "mountain" in nm or "cliff" in nm or "granite" in nm or "alpine" in nm or "scree" in nm: return 13.0
	# Hills ARE mountains (owner call 2026-09-25) — same height as a peak, so a painted
	# hill region (e.g. the whole Ashlands) reads as real elevation in the 3D client.
	if "_hills" in nm or "mound" in nm or "dune" in nm: return 13.0
	if "rocky" in nm or "basalt" in nm or "obsidian" in nm: return 6.0
	if "ocean" in nm: return -5.0
	if "coast" in nm or "shallow" in nm or "reef" in nm or "tidepool" in nm or "kelp" in nm or "wet_sand" in nm or "lily" in nm: return -2.0
	return 0.0

func _biome_color(nm: String) -> Color:
	if "ocean" in nm: return Color(0.13, 0.30, 0.52)
	if "coast" in nm or "shallow" in nm or "tidepool" in nm or "reef" in nm or "kelp" in nm: return Color(0.26, 0.50, 0.66)
	if "wet_sand" in nm or "sand" in nm or "shore" in nm or "driftwood" in nm: return Color(0.78, 0.72, 0.50)
	if "snow" in nm or "tundra" in nm or "ice" in nm: return Color(0.86, 0.90, 0.96)
	if "mountain" in nm or "cliff" in nm or "rocky" in nm or "granite" in nm or "alpine" in nm or "scree" in nm or "moss_rock" in nm: return Color(0.50, 0.50, 0.53)
	if "basalt" in nm or "obsidian" in nm or "volcanic" in nm or "lava" in nm or "ash" in nm or "scorched" in nm or "geothermal" in nm: return Color(0.26, 0.18, 0.16)
	if "helheim" in nm: return Color(0.36, 0.22, 0.44)
	if "pine" in nm or "dark_forest" in nm or "dark_root" in nm or "dark_mush" in nm: return Color(0.16, 0.32, 0.20)
	if "oak" in nm or "forest" in nm or "birch" in nm or "bamboo" in nm or "clearing" in nm or "meadow" in nm: return Color(0.24, 0.44, 0.24)
	if "swamp" in nm or "reeds" in nm or "lily" in nm or "mud" in nm: return Color(0.30, 0.36, 0.24)
	if "town" in nm or "floor" in nm or "carpet" in nm or "hearth" in nm or "wall" in nm or "longhouse" in nm or "fur_rug" in nm or "fire_pit" in nm: return Color(0.62, 0.50, 0.36)
	if "road" in nm or "path" in nm or "dirt" in nm or "bridge" in nm: return Color(0.50, 0.42, 0.30)
	if "farm" in nm or "wheat" in nm or "tilled" in nm or "pasture" in nm or "vineyard" in nm or "orchard" in nm or "crops" in nm: return Color(0.60, 0.55, 0.25)
	if "rubble" in nm or "broken" in nm or "cracked" in nm or "ruins" in nm or "cemetery" in nm or "grave" in nm or "rune" in nm: return Color(0.45, 0.43, 0.40)
	return Color(0.30, 0.52, 0.26)

# ── Terrain mesh ─────────────────────────────────────────────────────────────
func _precompute_corners() -> void:
	# Blur the tile heights first so biome height steps become rounded slopes
	# instead of cliffs/spikes; corners are the average of the 4 surrounding
	# SMOOTHED tiles (no more sine ripple — that was the corduroy bumpiness).
	var sm := _smoothed_heights(4)
	_corner = PackedFloat32Array(); _corner.resize(N1 * N1)
	for cy in range(N1):
		for cx in range(N1):
			var sum := 0.0
			var cnt := 0
			for oy: int in [-1, 0]:
				for ox: int in [-1, 0]:
					var tx := cx + ox
					var ty := cy + oy
					if tx >= 0 and tx < MAP_N and ty >= 0 and ty < MAP_N:
						sum += sm[ty * MAP_N + tx]
					cnt += 1
			_corner[cy * N1 + cx] = sum / float(cnt)

## Box-blur the tile height field `iters` times (self + 4 neighbours) so hard
## biome height jumps round out. Colours are untouched — this is height only.
func _smoothed_heights(iters: int) -> PackedFloat32Array:
	var h := _tile_h.duplicate()
	# Admin height sculpt (P5) — per-tile deltas layered on the biome base BEFORE
	# blurring, so raised/lowered ground rounds naturally into its surroundings.
	for idx: Variant in _h_delta.keys():
		var i := int(idx)
		if i >= 0 and i < h.size():
			h[i] += float(_h_delta[idx])
	for _p in range(iters):
		var out := h.duplicate()
		for ty in range(MAP_N):
			for tx in range(MAP_N):
				var i := ty * MAP_N + tx
				var s := h[i]
				var c := 1.0
				if tx > 0:
					s += h[i - 1]; c += 1.0
				if tx < MAP_N - 1:
					s += h[i + 1]; c += 1.0
				if ty > 0:
					s += h[i - MAP_N]; c += 1.0
				if ty < MAP_N - 1:
					s += h[i + MAP_N]; c += 1.0
				out[i] = s / c
		h = out
	return h

func _corner_h(cx: int, cy: int) -> float:
	return _corner[cy * N1 + cx]

## World-3D (x,z units) → interpolated height.
func _height_at_world(wx: float, wz: float) -> float:
	var fx := wx / CELL
	var fy := wz / CELL
	var x0 := clampi(int(floor(fx)), 0, MAP_N)
	var y0 := clampi(int(floor(fy)), 0, MAP_N)
	var x1 := mini(x0 + 1, MAP_N)
	var y1 := mini(y0 + 1, MAP_N)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var a := lerpf(_corner_h(x0, y0), _corner_h(x1, y0), tx)
	var b := lerpf(_corner_h(x0, y1), _corner_h(x1, y1), tx)
	return lerpf(a, b, ty)

func _build_all_chunks() -> void:
	_terrain_mat = StandardMaterial3D.new()
	_terrain_mat.vertex_color_use_as_albedo = true
	_terrain_mat.roughness = 1.0
	_terrain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rebuild_all_chunks()

func _rebuild_all_chunks() -> void:
	var nchunks := int(ceil(float(MAP_N) / float(CHUNK)))
	for ccy in range(nchunks):
		for ccx in range(nchunks):
			_build_chunk(ccx, ccy)

func _build_chunk(ccx: int, ccy: int) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tx0 := ccx * CHUNK
	var ty0 := ccy * CHUNK
	for ty in range(ty0, mini(ty0 + CHUNK, MAP_N)):
		for tx in range(tx0, mini(tx0 + CHUNK, MAP_N)):
			var col := _tile_col[ty * MAP_N + tx]
			var x0 := float(tx) * CELL
			var x1 := float(tx + 1) * CELL
			var z0 := float(ty) * CELL
			var z1 := float(ty + 1) * CELL
			var p00 := Vector3(x0, _corner_h(tx, ty), z0)
			var p10 := Vector3(x1, _corner_h(tx + 1, ty), z0)
			var p11 := Vector3(x1, _corner_h(tx + 1, ty + 1), z1)
			var p01 := Vector3(x0, _corner_h(tx, ty + 1), z1)
			# Per-CORNER shade (hashed by corner coord → seamless across tiles) so
			# large biome areas read with texture/depth instead of one flat colour.
			var c00 := _terrain_shade(col, tx, ty)
			var c10 := _terrain_shade(col, tx + 1, ty)
			var c11 := _terrain_shade(col, tx + 1, ty + 1)
			var c01 := _terrain_shade(col, tx, ty + 1)
			_tri3(st, c00, c01, c11, p00, p01, p11)
			_tri3(st, c00, c11, c10, p00, p11, p10)
	st.generate_normals()
	var key := "%d,%d" % [ccx, ccy]
	var mi: MeshInstance3D = _chunks.get(key)
	if mi == null or not is_instance_valid(mi):
		mi = MeshInstance3D.new()
		mi.material_override = _terrain_mat
		add_child(mi)
		_chunks[key] = mi
	mi.mesh = st.commit()

func _tri(st: SurfaceTool, col: Color, a: Vector3, b: Vector3, c: Vector3) -> void:
	for v: Vector3 in [a, b, c]:
		st.set_color(col)
		st.add_vertex(v)

## Per-vertex-coloured triangle (terrain corner shading).
func _tri3(st: SurfaceTool, ca: Color, cb: Color, cc: Color, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_color(ca); st.add_vertex(a)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cc); st.add_vertex(c)

## Deterministic brightness jitter per terrain CORNER (0.90–1.08×), hashed by the
## integer corner coord so a corner shared by neighbouring tiles gets the SAME shade
## (no seams). Breaks up flat single-colour biome expanses.
func _terrain_shade(col: Color, cx: int, cy: int) -> Color:
	var h := (cx * 73856093) ^ (cy * 19349663)
	var f := 0.90 + float(h & 1023) / 1023.0 * 0.18
	return Color(col.r * f, col.g * f, col.b * f, col.a)

# ── Environment / water ──────────────────────────────────────────────────────
func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52), deg_to_rad(-40), 0)
	sun.light_energy = 1.15
	add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.53, 0.68, 0.83)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.68)
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.60, 0.72, 0.85)
	env.fog_density = 0.004
	we.environment = env
	add_child(we)
	_env = env

func _build_water() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(MAP_N * CELL * 1.5, MAP_N * CELL * 1.5)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = Vector3(MAP_N * CELL * 0.5, SEA_LEVEL, MAP_N * CELL * 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.42, 0.66, 0.66)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.12
	mi.material_override = mat
	add_child(mi)
	_water = mi

# ── Low-poly 3D object nodes (procedural shared meshes) ───────────────────────
## Wrap a shared Mesh (from the Mesh3D factory) in a MeshInstance3D with the
## factory's shared flat-shaded material. All same-type objects reuse one Mesh.
func _mesh_instance(m: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _mesh_mat
	return mi

## A RIGGED low-poly viking (Node3D of animated parts) — colours from appearance.
func _make_char_node(appr: Dictionary) -> Node3D:
	return _mesh.call("build_char_rig", appr if not appr.is_empty() else {}) as Node3D

## Seat a 3D object so its base (mesh y=0 = feet) rests on the interpolated terrain
## at server-px `px`; stores epx so it can be re-seated when heights change.
func _place(node: Node3D, px: Vector2) -> void:
	var wx := px.x * SCALE
	var wz := px.y * SCALE
	var y: float = INTERIOR_Y if _in_interior else _height_at_world(wx, wz) + GROUND_LIFT
	node.position = Vector3(wx, y, wz)
	node.set_meta("epx", px)

## Current player position in SERVER px (read from the real Player node).
func _player_px() -> Vector2:
	return _player_node.global_position if _player_node != null else Vector2.ZERO

func _player_3d() -> Vector3:
	var px := _player_px()
	var wx := px.x * SCALE
	var wz := px.y * SCALE
	var y: float = INTERIOR_Y if _in_interior else _height_at_world(wx, wz)
	if not _in_interior and _player_node != null and bool(_player_node.get("_sailing")):
		y = SEA_LEVEL
	return Vector3(wx, y, wz)

var _boat_vis: MeshInstance3D

func _update_player_visual() -> void:
	if _player_spr == null:
		return
	var px := _player_px()
	var sailing: bool = bool(_player_node.get("_sailing")) if _player_node != null and _player_node.get("_sailing") != null else false
	if _in_interior:
		_player_spr.position = Vector3(px.x * SCALE, INTERIOR_Y, px.y * SCALE)
	elif sailing:
		# On water: seat the boat + player at the WATER surface (terrain here is the
		# seabed, below sea level, so a terrain-height placement would be underwater).
		var wx := px.x * SCALE
		var wz := px.y * SCALE
		if _boat_vis == null or not is_instance_valid(_boat_vis):
			_boat_vis = _mesh_instance(_mesh.call("boat", Color(0.45, 0.3, 0.16)) as Mesh)
			add_child(_boat_vis)
		_boat_vis.visible = true
		_boat_vis.position = Vector3(wx, SEA_LEVEL, wz)
		_player_spr.position = Vector3(wx, SEA_LEVEL + 0.35, wz)
	else:
		if _boat_vis != null and is_instance_valid(_boat_vis):
			_boat_vis.visible = false
		_place(_player_spr, px)

# ── Camera (tilt/orbit/zoom FOLLOW the player) ───────────────────────────────
func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.current = true
	_cam.far = 2000.0
	add_child(_cam)
	_update_camera()

func _update_camera() -> void:
	var tgt := _cine_target if _cine_active else _player_3d() + Vector3(0, 1.5, 0)
	var dir := Vector3(0.0, sin(_cam_pitch), cos(_cam_pitch)).rotated(Vector3.UP, _cam_yaw)
	_cam.position = tgt + dir * _cam_dist
	_cam.look_at(tgt, Vector3.UP)
	# Rotate the minimap with the camera so "up" on the map = the way we're facing.
	var hud := get_node_or_null("HUD")
	if hud != null and hud.has_method("set_minimap_heading"):
		hud.call("set_minimap_heading", _cam_yaw)

## Camera-relative WASD → a move-target ahead of the player in the camera's
## facing frame. The Player node walks toward it (its own physics/collision/sync);
## on key release we pin the target to the current spot so the player stops.
## True when a text field (chat, search…) has keyboard focus — WASD + camera keys
## then belong to the typist, not the game.
func _text_input_focused() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var f := vp.gui_get_focus_owner()
	return f is LineEdit or f is TextEdit

func _handle_kb_move() -> void:
	if _player_node == null or _text_input_focused():
		return
	var kb := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): kb.y -= 1.0
	if Input.is_key_pressed(KEY_S): kb.y += 1.0
	if Input.is_key_pressed(KEY_A): kb.x -= 1.0
	if Input.is_key_pressed(KEY_D): kb.x += 1.0
	if kb != Vector2.ZERO:
		var d3 := Vector3(kb.x, 0.0, kb.y).rotated(Vector3.UP, _cam_yaw).normalized()
		var camrel := Vector2(d3.x, d3.z)   # px-plane direction (x→x, z→y)
		_player_node.set("_target_interactable", null)
		_player_node.set("_target_monster", null)
		_player_node.set("_target_pos", _player_px() + camrel * 240.0)
		_kb_active = true
	elif _kb_active:
		_kb_active = false
		_player_node.set("_target_pos", _player_px())   # release → stop here

# ── Loop / input ─────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _cam == null:
		return
	# Keep the 2D Ground from ever painting over the 3D world (its own reveal
	# timer / override path would flip it visible).
	if _ground_node != null and _ground_node.visible:
		_ground_node.visible = false
	if not _cine_active and not GameManager.intro_active and not _text_input_focused():   # not while typing / mid-intro
		if Input.is_key_pressed(KEY_Q): _cam_yaw += 1.1 * delta
		if Input.is_key_pressed(KEY_E): _cam_yaw -= 1.1 * delta
		if Input.is_key_pressed(KEY_R): _cam_pitch = clampf(_cam_pitch + 0.7 * delta, 0.25, 1.4)
		if Input.is_key_pressed(KEY_F): _cam_pitch = clampf(_cam_pitch - 0.7 * delta, 0.25, 1.4)
	# Camera-relative WASD — feed the real Player a move-target in the direction
	# the camera faces (Player owns the actual walk + collision + sync).
	if _spawned and not _cine_active and not GameManager.intro_active:
		_handle_kb_move()
	# World3D mirrors the Player's px position to the 3D mesh + camera, and each
	# entity mesh to its 2D logic node.
	if _spawned:
		_update_player_visual()
		if _dungeon_mode:
			# Dungeon: its monsters/ore are live entities — keep them syncing (at the
			# dungeon floor via INTERIOR_Y in _place); just no wild-resource streaming.
			_sync_other_players()
			_sync_entity_meshes()
			_sync_hpbars()
			_sync_loot()
		elif not _in_interior:   # overworld; interiors freeze it entirely
			_sync_other_players()
			_sync_entity_meshes()
			_sync_hpbars()
			_sync_pet()
			_sync_loot()
			_update_res_chunks()   # stream wild resources around the player
	# Admin sculpt while a mouse button is held (polled so it works continuously).
	if _sculpt:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_apply_sculpt(true, delta)
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_apply_sculpt(false, delta)
	# Terrain edits (paint/sculpt) → rebuild only the DIRTY chunks, throttled.
	if not _dirty_chunks.is_empty():
		_dirty_accum += delta
		if _dirty_accum >= 0.1:
			_dirty_accum = 0.0
			_precompute_corners()   # global (blur is field-wide) but cheap vs chunk meshing
			for key: Variant in _dirty_chunks.keys():
				var p: PackedStringArray = str(key).split(",")
				_build_chunk(int(p[0]), int(p[1]))
			_dirty_chunks.clear()
			_reseat_static_and_entities()
			if _h_changed:
				_h_changed = false
				_flush_sculpt()   # persist admin height edits to the SERVER
	_update_hover()
	_update_camera()

## Show the hovered object/node/loot name at the top of the screen (like 2D). The
## 2D nodes render off-screen in 3D so their mouse_entered never fires — we detect
## the hover ourselves via screen-space picking and drive the reused HUD's tooltip.
func _update_hover() -> void:
	var hud := get_node_or_null("HUD")
	if hud == null:
		return
	var text := ""
	var loot := _pick_loot_screen(46.0)
	if loot != null:
		var iname: String = str(loot.get("item_name")) if loot.get("item_name") != null else "Item"
		var q: int = int(loot.get("item_qty")) if loot.get("item_qty") != null else 1
		text = ("%s  x%d" % [iname, q]) if q > 1 else iname
	else:
		var ent := _pick_entity_screen(52.0)
		if ent != null:
			text = _hover_text_for(ent)
	if text != "":
		hud.call("show_hover", text)
	else:
		hud.call("hide_hover")

func _hover_text_for(n: Node2D) -> String:
	var dn := ""
	if n.get("display_name") != null and str(n.get("display_name")) != "":
		dn = str(n.get("display_name"))
	elif n.get("npc_name_str") != null and str(n.get("npc_name_str")) != "":
		dn = str(n.get("npc_name_str"))
	if dn == "":
		dn = "Object"
	var act: Variant = n.get("action_label")
	if act != null and str(act) != "":
		return "[%s]  %s" % [str(act), dn]
	return dn

func _unhandled_input(event: InputEvent) -> void:
	if _cine_active or GameManager.intro_active:
		return   # no zoom / click-through during the intro or the shore flythrough
	if event is InputEventMouseButton and event.pressed:
		var b := (event as InputEventMouseButton).button_index
		# Never zoom/click-through when the mouse is over a UI panel (e.g. scrolling a
		# list past its end used to spill into camera zoom).
		if get_viewport().gui_get_hovered_control() != null:
			return
		if b == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist = maxf(6.0, _cam_dist - 3.0)
		elif b == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist = minf(120.0, _cam_dist + 3.0)
		elif _sculpt:
			pass   # sculpt handled by polling in _process; swallow the click
		elif b == MOUSE_BUTTON_LEFT and _spawned:
			_click_left()
		elif b == MOUSE_BUTTON_RIGHT and _spawned:
			_click_right()
	elif event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE: get_tree().quit()
			KEY_H:      _toggle_sculpt()
			KEY_BRACKETLEFT:  if _sculpt: _brush = maxf(1.0, _brush - 1.0)
			KEY_BRACKETRIGHT: if _sculpt: _brush = minf(16.0, _brush + 1.0)

## LMB: click an interactable → walk to it and gather (reuses Player._fire_interaction);
## otherwise walk to the clicked ground point.
func _click_left() -> void:
	var hit := _ray_to_ground()
	if hit.x == INF or _player_node == null:
		return
	var px := Vector2(hit.x / SCALE, hit.z / SCALE)
	# Loot first — walk to it and pick up (Player fires perform_pickup within range).
	var ld := _pick_loot_screen(46.0)
	if ld != null:
		_player_node.set("_target_interactable", null)
		_player_node.set("_target_monster", null)
		_player_node.set("_pending_pickup", ld)
		_player_node.set("_target_pos", ld.global_position)
		return
	var node := _pick_entity_screen(46.0)
	if node != null and node.is_in_group("interactable"):
		_player_node.set("_target_monster", null)
		_player_node.set("_target_interactable", node)
		_player_node.set("_target_pos", node.global_position)
	else:
		_player_node.set("_target_interactable", null)
		_player_node.set("_target_monster", null)
		_player_node.set("_target_pos", px)

## RMB: open the SAME action menu the 2D client uses on the picked entity
## (Attack / Talk / Chop / Mine / Access …). The HUD builds + routes it.
func _click_right() -> void:
	var node := _pick_entity_screen(52.0)
	if node != null:
		Events.action_menu_requested.emit(node, get_viewport().get_mouse_position())

func _ray_to_ground(screen := Vector2(-1.0, -1.0)) -> Vector3:
	var mp := screen if screen.x >= 0.0 else get_viewport().get_mouse_position()
	var o := _cam.project_ray_origin(mp)
	var dn := _cam.project_ray_normal(mp)
	var lim := MAP_N * CELL
	var t := 0.0
	for i in range(700):
		t += 1.0
		var p := o + dn * t
		if p.x < 0.0 or p.x > lim or p.z < 0.0 or p.z > lim:
			if t > 2000.0:
				break
			continue
		if p.y <= _height_at_world(p.x, p.z):
			return p
	return Vector3(INF, 0, 0)

# ── Other players (mirror NetworkManager._other_players → 3D billboards) ──────
func _sync_other_players() -> void:
	var live: Dictionary = NetworkManager._other_players
	for pid: Variant in live.keys():
		var raw: Variant = live[pid]
		if not is_instance_valid(raw):   # a departed player freed mid-frame — CAST would throw
			continue
		var op := raw as Node2D
		op.visible = false   # hide the 2D node; we render a 3D billboard instead
		var appr := op.get_meta("appearance", {}) as Dictionary
		var equip := op.get_meta("equipment", {}) as Dictionary
		# Rebuild the rig when their look OR gear changes (player_appearance updates
		# the metas), so remote players' weapon + armour show + update live.
		var sig := "%d:%d" % [appr.hash(), equip.hash()]
		var spr: Node3D = _op_bb.get(pid)
		if spr == null or not is_instance_valid(spr) or str(spr.get_meta("look_sig", "")) != sig:
			if spr != null and is_instance_valid(spr):
				spr.queue_free()
			spr = _make_char_node(_appr_with_gear(appr, equip))
			spr.set_meta("look_sig", sig)
			add_child(spr)
			_attach_nameplate(spr, str(op.get_meta("username", "")), Color(1, 1, 0.65))
			_op_bb[pid] = spr
		_place(spr, op.position)
	for pid: Variant in _op_bb.keys():
		if not live.has(pid):
			var s: Node3D = _op_bb[pid]
			if is_instance_valid(s):
				s.queue_free()
			_op_bb.erase(pid)

# ══ P3 — WORLD ENTITIES (low-poly 3D) ═════════════════════════════════════════
# Structures, resources, NPCs, monsters rendered as shared low-poly MESHES (the
# Mesh3D factory keys by type, so one Mesh serves every instance) off the SAME
# server feeds the 2D World.gd consumes. Static town geometry is reused verbatim
# from World.gd's const data; admin-placed + live entities come off the
# world_entity_* / mob_* signals. Visual only — picking is P3b-2/3.

## An Interactable type_str → its visual (mesh or imported scene). Resource nodes get
## a small per-instance size jitter so a grove/field doesn't look stamped-out.
func _interactable_node(type_str: String, col: Color, nm: String = "", logic: Node2D = null) -> Node3D:
	var authored := VillageArt.instantiate_visual(VillageArt.asset_for(type_str, nm), logic, col)
	if authored != null:
		if type_str == "tree":
			authored.scale = Vector3.ONE * randf_range(0.86, 1.16)
			authored.rotation.y = randf() * TAU
		return authored
	# Family 03 trees + Stick Pickup keep the same per-instance jitter as the meshes.
	var forest := ForestArt.instantiate_visual(ForestArt.asset_for(type_str, nm), logic, col)
	if forest != null:
		forest.scale = Vector3.ONE * randf_range(0.86, 1.16)
		forest.rotation.y = randf() * TAU
		return forest
	if _STRUCTURE_TYPES.has(type_str):
		return _mesh_instance(_mesh.call("structure", type_str, col) as Mesh)
	var node: Node3D
	if type_str == "dungeon_entrance":   # big cave mouth, full-size, no random jitter
		return _mesh_instance(_mesh.call("cave_mouth", col) as Mesh)
	match type_str:
		"tree":
			# Conifer (pine = dark green, frost = light blue) vs broadleaf (oak/cherry/…).
			var conifer := (col.g < 0.5 and col.r < 0.25) or (col.b > 0.85 and col.g > 0.8)
			node = _mesh_instance(_mesh.call("pine" if conifer else "tree", col) as Mesh)
		"rock":  node = _mesh_instance(_mesh.call("rock", col) as Mesh)
		"herb":  node = _mesh_instance(_mesh.call("bush", col) as Mesh)
		"fish":  node = _mesh_instance(_mesh.call("fishing", col) as Mesh)
		"stick": node = _mesh_instance(_mesh.call("stick", col) as Mesh)
		"stone":
			node = StonePickupArt.instantiate_visual(col)
			if node == null:
				node = _mesh_instance(_mesh.call("stone", col) as Mesh)
		_:       node = _mesh_instance(_mesh.call("nodelet", col) as Mesh)
	node.scale = Vector3.ONE * randf_range(0.86, 1.16)
	node.rotation.y = randf() * TAU   # vary orientation so a grove isn't stamped-out
	return node

func _monster_node(mtype: String) -> Node3D:
	# Every archetype is now an animated rig (walk/idle/attack/die + hover/flap).
	var rig := _mesh.call("build_monster_rig", mtype, _monster_color(mtype), _monster_scale(mtype)) as Node3D
	rig.set_meta("rig", true)
	return rig

## Rough per-type size — a rat is small, a giant/dragon is huge.
func _monster_scale(mtype: String) -> float:
	if "rat" in mtype or "chicken" in mtype: return 0.62
	if "goblin" in mtype or "spider" in mtype or "imp" in mtype: return 0.85
	if "bear" in mtype or "troll" in mtype or "draugr" in mtype or "knight" in mtype: return 1.35
	if "giant" in mtype: return 1.75
	if "nidhogg" in mtype or "hogg" in mtype: return 3.2   # the boss dragon, monumental
	if "wyvern" in mtype or "drake" in mtype: return 1.9
	if "dragon" in mtype or "wyrm" in mtype: return 2.3
	return 1.0

func _npc_node(ntype: String, _region: String, nm: String = "", logic: Node2D = null) -> Node3D:
	var authored := VillageArt.instantiate_visual(VillageArt.asset_for(ntype, nm), logic)
	if authored != null: return authored
	# NPCs carry no appearance dict on the wire — seed a stable look from the type.
	var h := hash(ntype)
	return _make_char_node({"skin": h % 8, "hair_color": (h >> 3) % 14,
		"tunic": (h >> 6) % 6, "beard": (h >> 9) % 4, "hair_style": (h >> 11) % 6})

## Per-type monster tint. Biome / element PREFIXES win first so variants read
## distinctly (an ice troll is icy, a swamp troll murky, a fire giant red).
func _monster_color(mtype: String) -> Color:
	if "swamp" in mtype:  return Color(0.30, 0.42, 0.22)   # murky bog green
	if "ice" in mtype or "frost" in mtype:
		return Color(0.72, 0.82, 0.92) if "wolf" in mtype else Color(0.60, 0.78, 0.90)
	if "fire" in mtype or "lava" in mtype or "magma" in mtype: return Color(0.85, 0.32, 0.12)
	if "shadow" in mtype:   return Color(0.28, 0.24, 0.34)
	if "spectral" in mtype: return Color(0.64, 0.78, 0.92)
	if "death" in mtype:    return Color(0.30, 0.32, 0.38)   # dark steel
	if "cave" in mtype:     return Color(0.44, 0.40, 0.36)   # rocky grey
	if "ancient" in mtype:  return Color(0.36, 0.46, 0.28)   # mossy
	if "plague" in mtype:   return Color(0.52, 0.58, 0.32)   # sickly
	if "dire" in mtype:     return Color(0.34, 0.32, 0.36)   # dark wolf
	if "elder" in mtype:    return Color(0.34, 0.22, 0.12)   # dark bear
	if "wolf" in mtype: return Color(0.55, 0.55, 0.60)
	if "bear" in mtype: return Color(0.42, 0.28, 0.16)
	if "goblin" in mtype: return Color(0.35, 0.55, 0.28)
	if "skeleton" in mtype or "draugr" in mtype: return Color(0.82, 0.80, 0.72)
	if "troll" in mtype: return Color(0.40, 0.50, 0.36)
	if "giant" in mtype: return Color(0.60, 0.62, 0.68)
	if "imp" in mtype: return Color(0.82, 0.32, 0.14)
	if "spider" in mtype: return Color(0.26, 0.20, 0.28)
	if "rat" in mtype: return Color(0.50, 0.42, 0.34)
	if "chicken" in mtype: return Color(0.92, 0.90, 0.82)
	if "bandit" in mtype: return Color(0.46, 0.34, 0.26)
	return Color(0.55, 0.40, 0.45)

func _arr_to_color(raw: Variant) -> Color:
	if raw is Array and (raw as Array).size() >= 3:
		var a: Array = raw as Array
		return Color(float(a[0]), float(a[1]), float(a[2]),
			float(a[3]) if a.size() > 3 else 1.0)
	return Color(0.7, 0.7, 0.7)

func _region_for_pos(p: Vector2) -> String:
	for entry: Array in _REGION_RECTS:
		if (entry[1] as Rect2).has_point(p):
			return str(entry[0])
	return ""

# ── Pair a 2D logic node with its 3D mesh visual ──────────────────────────────
## The 2D node (added to $Interactables) renders off-screen (no current Camera2D)
## but carries all gather/combat/collision + the interaction API; the mesh mirrors
## its position each frame. Keyed by server entity id so the feeds can find it.
func _pair(id: String, node2d: Node2D, mesh: Node3D, px: Vector2) -> void:
	node2d.position = px
	_ent_container.add_child(node2d)
	add_child(mesh)
	_place(mesh, px)
	_ent[id] = {"n": node2d, "v": mesh}

func _make_interactable2d(type_str: String, nm: String, skill: String, level: int,
		action: String, col: Color, id: String) -> Node2D:
	var it: Node2D = InteractableTscn.instantiate()
	it.set("interactable_type_str", type_str)
	it.set("display_name", nm)
	it.set("required_skill", skill)
	it.set("required_level", level)
	it.set("action_label", action)
	it.set("color", col)
	it.set("entity_id", id)
	return it

# Solid structure footprints (px) that should block the player in 3D but whose
# type_str is NOT in Interactable._STRUCTURE_SIZES (so the 2D node adds no body of
# its own — e.g. "building" houses). Added client-side; the 2D game is unchanged.
const _SOLID_3D: Dictionary = {
	"building": 84, "forge": 84, "bank": 92, "crafting": 42, "archery": 56,
	"runestone": 40, "construction": 48, "auction_house": 108,
	"stronghold": 92, "banner": 36, "outpost": 84, "seal_statue": 44,
}

func _spawn_interactable(id: String, type_str: String, nm: String, skill: String,
		level: int, action: String, col: Color, px: Vector2) -> void:
	var it := _make_interactable2d(type_str, nm, skill, level, action, col, id)
	_pair(id, it, _interactable_node(type_str, col, nm, it), px)
	_ensure_structure_collision(it, type_str)

## Give solid buildings a blocking StaticBody2D (layer 2) if the Interactable didn't
## already add one (it only bodies types in its own _STRUCTURE_SIZES).
func _ensure_structure_collision(node2d: Node2D, type_str: String) -> void:
	if not _SOLID_3D.has(type_str):
		return
	if node2d.get_node_or_null("StructureBody") != null:
		return   # 2D node already blocks this type — don't double up
	var body := StaticBody2D.new()
	body.name = "StructureBody3D"
	body.collision_layer = 2
	body.collision_mask = 0
	node2d.add_child(body)
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	var s: float = float(_SOLID_3D[type_str])
	rect.size = Vector2(s, s)
	cs.shape = rect
	body.add_child(cs)

func _spawn_monster(id: String, mtype: String, level: int, px: Vector2, join := true) -> void:
	var m := Area2D.new()
	m.set_script(MonsterScript)
	m.set("monster_type", mtype)
	m.set("entity_id", id)
	_pair(id, m, _monster_node(mtype), px)   # _ready runs on add → stats are set
	if level > 0:
		m.call("scale_to_level", level)
	# Admin/live monsters register server AI (seed_only); static bosses do NOT
	# (mirrors World._spawn_bosses vs _spawn_admin_entity).
	if join:
		NetworkManager.send_monster_join(id, px.x, px.y,
			int(m.get("max_hp")), int(m.get("xp_reward")), mtype,
			int(m.get("level")), int(m.get("attack")), true)

func _spawn_npc(id: String, ntype: String, nm: String, quest: String, wander: float,
		region: String, shop_id: String, px: Vector2) -> void:
	var n := Area2D.new()
	n.set_script(NPCScript)
	n.set("npc_type", ntype)
	n.set("npc_name_str", nm)
	n.set("quest_text", quest)
	n.set("wander_radius", wander)
	n.set("region", region)
	n.set("shop_id", shop_id)
	n.set("entity_id", id)
	_pair(id, n, _npc_node(ntype, region, nm, n), px)
	_attach_nameplate((_ent[id] as Dictionary)["v"] as Node3D, nm, Color(0.82, 0.9, 1.0))

## Ids NOT managed by the admin world_entities feed (so the bulk refresh must not
## free them): static town geo (t:/kc:/n:/b:), streamed wild resources (r:), caravans (cv:).
func _is_static_id(id: String) -> bool:
	return id.begins_with("t:") or id.begins_with("kc:") \
		or id.begins_with("n:") or id.begins_with("b:") \
		or id.begins_with("r:") or id.begins_with("cv:") or id.begins_with("th:")

func _free_ent(id: String) -> void:
	var e: Variant = _ent.get(id)
	if e == null:
		return
	var d: Dictionary = e
	if is_instance_valid(d["n"]): (d["n"] as Node).queue_free()
	if is_instance_valid(d["v"]): (d["v"] as Node).queue_free()
	_ent.erase(id)
	_admin_entity_data.erase(id)
	_dead_mobs.erase(id)
	_mob_target.erase(id)

# ── Static town geometry (reused from World.gd's const data) ──────────────────
func _build_static_entities() -> void:
	if _static_built:
		return
	_static_built = true
	# A tree-less World instance is just a data bag here (pure const reads); free it.
	var w: Object = WorldScript.new()
	var towns: Array  = w.call("get_town_nodes")
	var castle: Array = w.call("get_castle_nodes")
	var npcs: Array   = w.call("get_npcs")
	var bosses: Array = w.call("get_boss_spawns")
	w.free()
	for i in range(towns.size()):
		_static_structure(towns[i] as Array, "t:%d" % i)
	for i in range(castle.size()):
		_static_structure(castle[i] as Array, "kc:%d" % i)
	for i in range(npcs.size()):
		var d: Array = npcs[i]
		var nid := "n:%d" % i
		_spawn_npc(nid, str(d[1]), str(d[2]), str(d[3]), float(d[4]),
			_region_for_pos(d[0] as Vector2), "", d[0] as Vector2)
		_apply_entity_data3d(_node_of(nid), _edits_data3d.get(nid, {}) as Dictionary)
	for i in range(bosses.size()):
		var b: Array = bosses[i]
		var bid := "b:%d" % i
		_spawn_monster(bid, str(b[1]), 0, b[0] as Vector2, false)   # bosses: no AI join
		_apply_entity_data3d(_node_of(bid), _edits_data3d.get(bid, {}) as Dictionary)

func _static_structure(row: Array, id: String) -> void:   # [pos,type,name,skill,lvl,action,color]
	_spawn_interactable(id, str(row[1]), str(row[2]), str(row[3]),
		int(row[4]), str(row[5]), row[6] as Color, row[0] as Vector2)

# ── P6: chunk-streamed wild resources (match World.gd's deterministic layout) ─
## Stream procedural resource chunks around the player (only when they cross into
## a new chunk). Reuses World's generators (`_resource_data`/`_in_safe_zone`) +
## the SAME chunk seed + `r:cx:cy:i` ids, so placement + server gather-state map 1:1.
func _update_res_chunks() -> void:
	if _wdata == null:
		return
	var ppx := _player_px()
	var pcx := floori(ppx.x / float(RES_CHUNK_PX))
	var pcy := floori(ppx.y / float(RES_CHUNK_PX))
	if Vector2i(pcx, pcy) == _last_res_chunk:
		return
	_last_res_chunk = Vector2i(pcx, pcy)
	var max_c := ceili(float(MAP_N * 32) / float(RES_CHUNK_PX))
	var desired: Dictionary = {}
	for dx in range(-RES_RADIUS, RES_RADIUS + 1):
		for dy in range(-RES_RADIUS, RES_RADIUS + 1):
			var cx := pcx + dx
			var cy := pcy + dy
			if cx >= 0 and cy >= 0 and cx < max_c and cy < max_c:
				desired[Vector2i(cx, cy)] = true
	for key: Variant in _res_chunks.keys():
		if not desired.has(key):
			_unload_res_chunk(key as Vector2i)
	for key: Variant in desired.keys():
		if not _res_chunks.has(key):
			_load_res_chunk((key as Vector2i).x, (key as Vector2i).y)
	# Stream admin (a:) entities at the same radius.
	_update_admin_chunks3d(desired)

func _load_res_chunk(cx: int, cy: int) -> void:
	var ids: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = (cx * 7919 + cy * 6271) ^ 0xA3C5F1   # SAME seed as World._spawn_chunk_resources
	var ox := float(cx * RES_CHUNK_PX)
	var oy := float(cy * RES_CHUNK_PX)
	var lim := float(MAP_N * 32 - 64)
	for i in range(RES_ATTEMPTS):
		var pos := Vector2(clampf(ox + rng.randf() * RES_CHUNK_PX, 64.0, lim),
			clampf(oy + rng.randf() * RES_CHUNK_PX, 64.0, lim))
		if bool(_wdata.call("_in_safe_zone", pos)):
			continue
		var biome := str(_ground_node.call("biome_at_world", pos))
		var d: Array = _wdata.call("_resource_data", biome, pos, rng, _ground_node)
		if d.size() == 0:
			continue
		var id := "r:%d:%d:%d" % [cx, cy, i]
		if _ent.has(id):
			continue
		_spawn_interactable(id, str(d[0]), str(d[1]), str(d[2]), int(d[3]), str(d[4]), d[5] as Color, pos)
		ids.append(id)
	_res_chunks[Vector2i(cx, cy)] = ids
	if not ids.is_empty():
		NetworkManager.send_node_states(ids)   # shared lock/depletion state

func _unload_res_chunk(key: Vector2i) -> void:
	for id: Variant in _res_chunks.get(key, []):
		_free_ent(str(id))
	_res_chunks.erase(key)

## Remove a (moved) resource id from every chunk's cull-list so unloading its home
## chunk can't free it — it persists at its new spot instead of vanishing in front
## of the player. The loader's `if _ent.has(id): continue` prevents a re-spawn dup.
func _unfile_res(id: String) -> void:
	for key: Variant in _res_chunks.keys():
		var arr: Array = _res_chunks[key]
		var i := arr.find(id)
		if i >= 0:
			arr.remove_at(i)
			return

# ── Admin-placed + live entities (mirror World._spawn_admin_entity's dispatch) ─
func _spawn_admin_ent3d(entity: Dictionary) -> void:
	var id := str(entity.get("id", ""))
	if id == "" or _ent.has(id):
		return
	var kind := str(entity.get("kind", ""))
	var data: Dictionary = (entity.get("data", {}) as Dictionary) if entity.get("data") is Dictionary else {}
	var px := Vector2(float(entity.get("x", 0.0)), float(entity.get("y", 0.0)))
	match kind:
		"resource":
			_spawn_interactable(id, str(data.get("type_str", "tree")),
				str(data.get("display_name", "Resource")), str(data.get("skill", "woodcutting")),
				int(data.get("level", 1)), str(data.get("action", "Interact")),
				_arr_to_color(data.get("color")), px)
		"monster":
			_spawn_monster(id, str(data.get("monster_type", "rat")), int(data.get("level", 0)), px)
		"npc":
			_spawn_npc(id, str(data.get("npc_type", "worker")), str(data.get("npc_name", "Villager")),
				str(data.get("quest_text", "")), float(data.get("wander_radius", 32.0)),
				_region_for_pos(px), str(data.get("shop_id", "")), px)
		"farm_plot":
			_spawn_interactable(id, "farm_plot", "Farm Plot", "farming", 1, "Tend", Color(0.42, 0.30, 0.16), px)
		"stronghold", "banner", "outpost":
			_spawn_interactable(id, kind, "Warband %s" % kind.capitalize(), "", 1, "Inspect", Color(0.55, 0.30, 0.18), px)
		"seal_statue":
			_spawn_interactable(id, "seal_statue", "Seal of Kings", "", 1, "Inspect", Color(0.95, 0.78, 0.18), px)
		"world_eater":
			_spawn_interactable(id, "world_eater", "The World-Eater", "", 1, "Witness", Color(0.35, 0.05, 0.45), px)
	# Restore a saved admin rotation (v1.6.1) after the visual exists.
	var rot := float(data.get("rot", 0.0))
	if rot != 0.0:
		_apply_ent_rot3d(id, rot)
	if _ent.has(id):
		_admin_entity_data[id] = entity.duplicate(true)   # seed the Inspect editor

## Authoritative bulk set — clear the admin/live layer (keep static town geo) +
## the stream index, then re-ingest.
func _on_world_entities3d(entities: Array) -> void:
	for id: Variant in _ent.keys():
		if not _is_static_id(str(id)):
			_free_ent(str(id))
	_admin_index3d.clear()
	_admin_id_chunk3d.clear()
	_admin_loaded3d.clear()
	for e: Variant in entities:
		if e is Dictionary:
			_ingest_admin_ent3d(e as Dictionary)
	_refresh_admin_stream_now3d()

## Load admin entities around the player's CURRENT position without waiting for a
## chunk change (fixes "missing on login until you move").
func _refresh_admin_stream_now3d() -> void:
	var ppx := _player_px()
	var pcx := floori(ppx.x / float(RES_CHUNK_PX))
	var pcy := floori(ppx.y / float(RES_CHUNK_PX))
	for dx in range(-RES_RADIUS, RES_RADIUS + 1):
		for dy in range(-RES_RADIUS, RES_RADIUS + 1):
			var ch := Vector2i(pcx + dx, pcy + dy)
			if _admin_index3d.has(ch) and not _admin_loaded3d.has(ch):
				_load_admin_chunk3d(ch)

func _remove_ent3d(entity_id: String) -> void:
	_free_ent(entity_id)
	_deindex_admin3d(entity_id)

# ── Admin (a:) entity streaming ──────────────────────────────────────────────
func _admin_streamable3d(entity: Dictionary) -> bool:
	var kind := str(entity.get("kind", ""))
	if kind == "monster" or kind == "npc":
		return true
	if kind == "resource":
		var data: Dictionary = entity.get("data", {}) as Dictionary if entity.get("data") is Dictionary else {}
		return str(data.get("type_str", "")) in _ADMIN_GATHER_TYPES3D
	return false

func _admin_chunk_of3d(entity: Dictionary) -> Vector2i:
	return Vector2i(floori(float(entity.get("x", 0.0)) / float(RES_CHUNK_PX)),
		floori(float(entity.get("y", 0.0)) / float(RES_CHUNK_PX)))

func _ingest_admin_ent3d(entity: Dictionary) -> void:
	var id := str(entity.get("id", ""))
	if id.is_empty():
		return
	if not _admin_streamable3d(entity):
		_spawn_admin_ent3d(entity)
		return
	var ch := _admin_chunk_of3d(entity)
	if not _admin_index3d.has(ch):
		_admin_index3d[ch] = []
	(_admin_index3d[ch] as Array).append(entity)
	_admin_id_chunk3d[id] = ch
	if _admin_loaded3d.has(ch):
		_spawn_admin_ent3d(entity)
		(_admin_loaded3d[ch] as Array).append(id)

func _load_admin_chunk3d(ch: Vector2i) -> void:
	if _admin_loaded3d.has(ch):
		return
	var ids: Array = []
	for e: Variant in _admin_index3d.get(ch, []):
		var id := str((e as Dictionary).get("id", ""))
		if id.is_empty() or _ent.has(id):
			continue
		_spawn_admin_ent3d(e as Dictionary)
		ids.append(id)
	_admin_loaded3d[ch] = ids

func _unload_admin_chunk3d(ch: Vector2i) -> void:
	for id: Variant in _admin_loaded3d.get(ch, []):
		_free_ent(str(id))
	_admin_loaded3d.erase(ch)

func _update_admin_chunks3d(desired: Dictionary) -> void:
	var to_unload: Array = []
	for ch: Variant in _admin_loaded3d.keys():
		if not desired.has(ch):
			to_unload.append(ch)
	for ch: Variant in to_unload:
		_unload_admin_chunk3d(ch as Vector2i)
	for ch: Variant in desired.keys():
		if _admin_index3d.has(ch) and not _admin_loaded3d.has(ch):
			_load_admin_chunk3d(ch as Vector2i)

func _deindex_admin3d(entity_id: String) -> void:
	if not _admin_id_chunk3d.has(entity_id):
		return
	var ch: Vector2i = _admin_id_chunk3d[entity_id]
	_admin_id_chunk3d.erase(entity_id)
	if _admin_index3d.has(ch):
		var arr: Array = _admin_index3d[ch]
		for i in range(arr.size() - 1, -1, -1):
			if str((arr[i] as Dictionary).get("id", "")) == entity_id:
				arr.remove_at(i)
	if _admin_loaded3d.has(ch):
		(_admin_loaded3d[ch] as Array).erase(entity_id)

## Set a logic node's world pos, re-anchoring an NPC's wander home (admin_set_position)
## so a moved NPC stays put instead of drifting back to its spawn. Mesh follows per-frame.
func _relocate3d(n: Node, gpos: Vector2) -> void:
	if n.has_method("admin_set_position"):
		n.call("admin_set_position", gpos)
	else:
		(n as Node2D).global_position = gpos

func _on_ent_moved3d(entity_id: String, x: float, y: float) -> void:
	var n := _node_of(entity_id)   # mesh follows via the per-frame sync
	if n != null:
		_relocate3d(n, Vector2(x, y))
		_unfile_res(entity_id)   # persist a moved wild resource past its home chunk
	_reindex_admin_move3d(entity_id, x, y)

## Re-file a moved streamed admin entity into whatever chunk it's now in.
func _reindex_admin_move3d(entity_id: String, x: float, y: float) -> void:
	if _admin_entity_data.has(entity_id):
		var info: Dictionary = _admin_entity_data[entity_id]
		info["x"] = x
		info["y"] = y
	if not _admin_id_chunk3d.has(entity_id):
		return
	var old_ch: Vector2i = _admin_id_chunk3d[entity_id]
	var new_ch := Vector2i(floori(x / float(RES_CHUNK_PX)), floori(y / float(RES_CHUNK_PX)))
	# Always patch the stored x/y (same-chunk moves too) so a stream-out/in
	# respawns at the moved position — not the original.
	var moved_e: Dictionary = {}
	if _admin_index3d.has(old_ch):
		var arr: Array = _admin_index3d[old_ch]
		for i in range(arr.size() - 1, -1, -1):
			if str((arr[i] as Dictionary).get("id", "")) == entity_id:
				moved_e = arr[i]
				arr.remove_at(i)
				break
	if moved_e.is_empty():
		return
	moved_e["x"] = x
	moved_e["y"] = y
	if not _admin_index3d.has(new_ch):
		_admin_index3d[new_ch] = []
	(_admin_index3d[new_ch] as Array).append(moved_e)
	_admin_id_chunk3d[entity_id] = new_ch
	if new_ch != old_ch:
		if _admin_loaded3d.has(old_ch):
			(_admin_loaded3d[old_ch] as Array).erase(entity_id)
		if _admin_loaded3d.has(new_ch) and not (_admin_loaded3d[new_ch] as Array).has(entity_id):
			(_admin_loaded3d[new_ch] as Array).append(entity_id)

## Admin rotated an entity (v1.6.1). Set the 3D visual's Y rotation + stash it as
## meta so the per-frame _place (position-only) never clobbers it, and re-spawns
## can restore it. Live-facing monsters ignore this (you rotate buildings/nodes).
func _on_ent_rotated3d(entity_id: String, rot: float) -> void:
	_apply_ent_rot3d(entity_id, rot)

func _apply_ent_rot3d(entity_id: String, rot: float) -> void:
	if not _ent.has(entity_id):
		return
	var v: Variant = (_ent[entity_id] as Dictionary)["v"]
	if is_instance_valid(v):
		(v as Node3D).rotation.y = rot
		(v as Node3D).set_meta("admin_rot", rot)

## Current admin Y-rotation of an entity (radians), or 0 — read by the AdminPanel
## rotate tool to compute the next step.
func admin_entity_rot(entity_id: String) -> float:
	if not _ent.has(entity_id):
		return 0.0
	var v: Variant = (_ent[entity_id] as Dictionary)["v"]
	if is_instance_valid(v) and (v as Node3D).has_meta("admin_rot"):
		return float((v as Node3D).get_meta("admin_rot"))
	return 0.0

## Admin moved/deleted a pre-existing entity (server confirms with this).
func _on_entity_edit_applied3d(entity_id: String, deleted: bool, x: float, y: float) -> void:
	if deleted:
		_free_ent(entity_id)
	else:
		var n := _node_of(entity_id)
		if n != null:
			_relocate3d(n, Vector2(x, y))   # mesh follows per-frame
			_unfile_res(entity_id)          # persist a moved wild resource

## Bulk edit set on login — apply saved deletes/moves to the static town geometry.
func _on_entity_edits3d(edits: Array) -> void:
	for e: Variant in edits:
		if not (e is Dictionary): continue
		var d: Dictionary = e
		var id := str(d.get("id", ""))
		if id.is_empty(): continue
		if bool(d.get("deleted", false)):
			_free_ent(id)
			continue
		if d.get("x") != null and d.get("y") != null:
			var n := _node_of(id)
			if n != null:
				_relocate3d(n, Vector2(float(d["x"]), float(d["y"])))
				_unfile_res(id)
		var er := float(d.get("rot", 0.0))
		if er != 0.0:
			_apply_ent_rot3d(id, er)
		if d.get("data") is Dictionary and not (d["data"] as Dictionary).is_empty():
			_edits_data3d[id] = d["data"]
			var dn := _node_of(id)
			if dn != null:
				_apply_entity_data3d(dn, d["data"] as Dictionary)

## Apply a data override to a pre-existing NPC/monster logic node (mirrors World).
func _apply_entity_data3d(node: Node, data: Dictionary) -> void:
	if data.is_empty() or not is_instance_valid(node):
		return
	if data.has("npc_name"):
		node.set("npc_name_str", str(data["npc_name"]))
	if data.has("quest_text"):
		node.set("quest_text", str(data["quest_text"]))
	if data.has("wander_radius"):
		node.set("wander_radius", float(data["wander_radius"]))
	if data.has("shop_id"):
		node.set("shop_id", str(data["shop_id"]))
	if data.has("level") and node.has_method("scale_to_level"):
		node.call("scale_to_level", int(data["level"]))

func _on_entity_data_edited3d(entity_id: String, data: Dictionary) -> void:
	_edits_data3d[entity_id] = data
	var n := _node_of(entity_id)
	if n != null:
		_apply_entity_data3d(n, data)

# ── P6: caravans (paired Caravan node + wagon mesh) ──────────────────────────
func _on_caravans_updated3d(list: Array) -> void:
	for entry: Variant in list:
		if not (entry is Dictionary): continue
		var d: Dictionary = entry
		var cid := str(d.get("id", ""))
		if cid.is_empty(): continue
		var key := "cv:" + cid
		if not _ent.has(key):
			var cv := Area2D.new()
			cv.set_script(CaravanScript)
			cv.set("caravan_id", cid)
			cv.set("entity_id", cid)
			_pair(key, cv, _mesh_instance(_mesh.call("wagon", Color(0.5, 0.34, 0.2)) as Mesh),
				Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0))))
		var node := _node_of(key)
		if node != null: node.call("apply_state", d)

func _on_caravan_hit3d(id: String, hp: int, mhp: int) -> void:
	var node := _node_of("cv:" + id)
	if node != null:
		node.set("current_hp", hp)
		node.set("max_hp", maxi(1, mhp))
		if node.has_method("flash_hit"): node.call("flash_hit")

func _on_caravan_removed3d(id: String) -> void:
	_free_ent("cv:" + id)

# ── P6: visible thralls (paired WorldThrall node + char mesh) ────────────────
## Mirror the owner's assigned-thrall roster. WorldThrall is self-driving (walks to
## real resource/monster nodes near its town + "works"), so the mesh just follows.
func _on_thralls_updated3d() -> void:
	var seen: Dictionary = {}
	for entry: Variant in ThrallManager.roster:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry
		if not (d.get("work_spot", null) is Array):
			continue   # unassigned → not on the map
		var id := str(d.get("id", ""))
		if id.is_empty():
			continue
		var key := "th:" + id
		seen[key] = true
		if not _ent.has(key):
			var raw: Dictionary = (d.get("appearance", {}) as Dictionary) if d.get("appearance") is Dictionary else {}
			var spot: Array = d.get("work_spot") as Array
			_pair(key, WorldThrallScript.new(), _make_char_node(raw),
				Vector2(float(spot[0]), float(spot[1])))
		var node := _node_of(key)
		if node != null:
			node.call("apply_state", d)
	for k: Variant in _ent.keys():
		var sk := str(k)
		if sk.begins_with("th:") and not seen.has(sk):
			_free_ent(sk)

# ── P6: summoned pet (mirror PetManager's 2D node → small creature mesh) ─────
var _pet_vis: MeshInstance3D

func _sync_pet() -> void:
	var summoned: bool = PetManager != null and PetManager.is_summoned()
	if summoned:
		var pn := PetManager.get("_pet_node") as Node2D
		if pn != null and is_instance_valid(pn):
			pn.visible = false
			if _pet_vis == null or not is_instance_valid(_pet_vis):
				var pt := str(PetManager.pet_type)
				_pet_vis = _mesh_instance(_mesh.call("monster", pt, _monster_color(pt), 0.5) as Mesh)
				add_child(_pet_vis)
			_place(_pet_vis, pn.global_position)
			return
	if _pet_vis != null and is_instance_valid(_pet_vis):
		_pet_vis.queue_free()
		_pet_vis = null

# ── P6: interiors — drop into a themed 3D room ───────────────────────────────
func _on_interior_entered3d(interior_id: String, x: float, y: float,
		return_x: float, return_y: float) -> void:
	_leave_interior()
	_interior_ret = Vector2(return_x, return_y)
	GameManager.in_interior = true
	GameManager.overworld_anchor = Vector2(return_x, return_y)
	GameManager.current_interior_id = interior_id
	NetworkManager.refresh_interior_visibility()
	# The real InteriorScene (offscreen 2D) provides wall collision + the exit
	# door + decor logic; we mirror its bounds/theme into a 3D room.
	var sc := (load("res://scripts/InteriorScene.gd") as GDScript).new() as Node2D
	sc.name = "InteriorScene"
	sc.global_position = Vector2(x, y)
	_ent_container.add_child(sc)
	sc.call("setup", interior_id)
	if _ground_node != null:
		sc.set("exterior_biome", str(_ground_node.call("biome_at_world", Vector2(return_x, return_y))))
	sc.call("apply_exterior_backdrop")
	_interior_scene = sc
	var w := float(sc.get("width")) * SCALE
	var h := float(sc.get("height")) * SCALE
	_interior_room = _mesh_instance(_mesh.call("room", w, h,
		sc.get("floor_color"), sc.get("wall_color")) as Mesh)
	_interior_room.position = Vector3(x * SCALE, INTERIOR_Y, y * SCALE)
	add_child(_interior_room)
	# Drop the player in near the south door + stop them.
	var ppx := Vector2(x + randf_range(-60.0, 60.0), y + randf_range(-24.0, 4.0))
	_player_node.global_position = ppx
	_player_node.set("_target_pos", ppx)
	_player_node.set("_target_interactable", null)
	_player_node.set("_target_monster", null)
	_in_interior = true
	_set_overworld_visible(false)
	if _env != null:
		_env.fog_density = 0.05   # smother the far-off overworld
	Events.chat_message.emit("[Interior] Entered %s. Walk through the EXIT (south) to leave." % interior_id)

func _on_interior_exited3d(return_x: float, return_y: float) -> void:
	_leave_interior()
	GameManager.in_interior = false
	GameManager.current_interior_id = ""
	if _player_node != null:
		_player_node.global_position = Vector2(return_x, return_y)
		_player_node.set("_target_pos", Vector2(return_x, return_y))
	NetworkManager.refresh_interior_visibility()

func _leave_interior() -> void:
	if _interior_scene != null and is_instance_valid(_interior_scene):
		_interior_scene.queue_free()
	_interior_scene = null
	if _interior_room != null and is_instance_valid(_interior_room):
		_interior_room.queue_free()
	_interior_room = null
	if _in_interior:
		_in_interior = false
		_dungeon_mode = false
		_set_overworld_visible(true)
		if _env != null:
			_env.fog_density = 0.004

# ── P6: dungeons — instanced 3D cave from the server's carved layout ─────────
func _on_dungeon_entered3d(dungeon_id: String, interior_id: String, layout: Dictionary,
		x: float, y: float, return_x: float, return_y: float) -> void:
	_leave_interior()
	_interior_ret = Vector2(return_x, return_y)
	GameManager.in_interior = true
	GameManager.overworld_anchor = Vector2(return_x, return_y)
	GameManager.current_interior_id = interior_id
	NetworkManager.refresh_interior_visibility()
	var sc := (load("res://scripts/DungeonScene.gd") as GDScript).new() as Node2D
	sc.name = "DungeonScene"
	# Anchor at the region origin so cell-local collision lands where the server
	# spawned the monsters/ore (they arrive as ordinary world_entities → pairs).
	var origin := Vector2(float(layout.get("region_tx", 0)) * 32.0, float(layout.get("region_ty", 0)) * 32.0)
	sc.global_position = origin
	_ent_container.add_child(sc)
	sc.call("setup", layout)
	_interior_scene = sc
	_interior_room = _build_dungeon_mesh(sc, origin)
	add_child(_interior_room)
	var ppx := Vector2(x, y - 72.0)      # a couple tiles clear of the exit portal
	_player_node.global_position = ppx
	_player_node.set("_target_pos", ppx)
	_player_node.set("_target_interactable", null)
	_player_node.set("_target_monster", null)
	_in_interior = true
	_dungeon_mode = true
	_set_overworld_visible(false, false)   # hide terrain/water; KEEP the dungeon entities
	if _env != null:
		_env.fog_density = 0.06
	Events.chat_message.emit("[Dungeon] You enter %s. Return via the glowing portal."
		% str(layout.get("name", dungeon_id)))

## Build 3D floor quads for FLOOR cells + wall blocks for WALL cells bordering a
## floor, straight from DungeonScene's carved grid so visuals match its collision.
func _build_dungeon_mesh(sc: Node2D, origin_px: Vector2) -> MeshInstance3D:
	var gw := int(sc.get("gw"))
	var gh := int(sc.get("gh"))
	var floor_c := Color(0.20, 0.18, 0.17)
	var wall_c := Color(0.12, 0.11, 0.13)
	var wall_h := 3.2
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for cy in range(gh):
		for cx in range(gw):
			var x0 := (origin_px.x + float(cx) * 32.0) * SCALE
			var x1 := (origin_px.x + float(cx + 1) * 32.0) * SCALE
			var z0 := (origin_px.y + float(cy) * 32.0) * SCALE
			var z1 := (origin_px.y + float(cy + 1) * 32.0) * SCALE
			if bool(sc.call("is_floor", cx, cy)):
				_dq(st, Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1), floor_c)
			elif _borders_floor(sc, cx, cy):
				_dbox(st, x0, z0, x1, z1, wall_h, wall_c)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _mesh_mat
	return mi

func _borders_floor(sc: Node2D, cx: int, cy: int) -> bool:
	return bool(sc.call("is_floor", cx - 1, cy)) or bool(sc.call("is_floor", cx + 1, cy)) \
		or bool(sc.call("is_floor", cx, cy - 1)) or bool(sc.call("is_floor", cx, cy + 1))

func _dq(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(st, col, a, b, c); _tri(st, col, a, c, d)

func _dbox(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float, h: float, col: Color) -> void:
	var b0 := Vector3(x0, 0, z0); var b1 := Vector3(x1, 0, z0)
	var b2 := Vector3(x1, 0, z1); var b3 := Vector3(x0, 0, z1)
	var t0 := Vector3(x0, h, z0); var t1 := Vector3(x1, h, z0)
	var t2 := Vector3(x1, h, z1); var t3 := Vector3(x0, h, z1)
	_dq(st, t0, t1, t2, t3, col)     # top
	_dq(st, b0, b1, t1, t0, col)     # -z
	_dq(st, b1, b2, t2, t1, col)     # +x
	_dq(st, b2, b3, t3, t2, col)     # +z
	_dq(st, b3, b0, t0, t3, col)     # -x

## Show/hide the overworld to isolate an instanced room. Terrain + water always
## toggle; entities/actors toggle only when `include_entities` (interiors hide
## everything; DUNGEONS keep entities — the dungeon's monsters/ore ARE entities).
func _set_overworld_visible(v: bool, include_entities := true) -> void:
	for key: Variant in _chunks.keys():
		var c := _chunks[key] as MeshInstance3D
		if is_instance_valid(c): c.visible = v
	if _water != null: _water.visible = v
	if not include_entities:
		return
	for id: Variant in _ent.keys():
		if is_instance_valid((_ent[id] as Dictionary)["v"]):
			((_ent[id] as Dictionary)["v"] as Node3D).visible = v
	for pid: Variant in _op_bb.keys():
		if is_instance_valid(_op_bb[pid]):
			(_op_bb[pid] as Node3D).visible = v
	if _pet_vis != null and is_instance_valid(_pet_vis): _pet_vis.visible = v
	if _boat_vis != null and is_instance_valid(_boat_vis): _boat_vis.visible = v

# ── P6: monster projectiles (ranged/magic attack → tweened 3D orbs) ──────────
func _px3(px: Vector2, yoff: float) -> Vector3:
	var wx := px.x * SCALE
	var wz := px.y * SCALE
	return Vector3(wx, _height_at_world(wx, wz) + yoff, wz)

func _on_projectile3d(_entity_id: String, fx: float, fy: float, tx: float, ty: float,
		_style: String, color: Color, spread_orbs: int) -> void:
	var orbs := maxi(1, spread_orbs)
	for i in range(orbs):
		var lateral := 0.0
		if orbs > 1:
			lateral = (float(i) - float(orbs - 1) * 0.5) * 14.0
		_spawn_orb3d(Vector2(fx, fy), Vector2(tx, ty), color, lateral)

func _spawn_orb3d(from_px: Vector2, to_px: Vector2, color: Color, lateral: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.24; sm.height = 0.48; sm.radial_segments = 7; sm.rings = 4
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.6
	mi.material_override = mat
	var start := from_px
	if absf(lateral) > 0.01:
		var dir := (to_px - start).normalized()
		start += Vector2(-dir.y, dir.x) * lateral
	mi.position = _px3(start, 1.1)
	add_child(mi)
	var tw := mi.create_tween()
	tw.tween_property(mi, "position", _px3(to_px, 1.1), 0.4).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(mi.queue_free)

# ── P6: loot — mirror LootDrop 2D nodes → 3D pickups, click to collect ───────
func _on_container_child(node: Node) -> void:
	if node.has_method("perform_pickup"):   # a LootDrop just spawned (item/gold/pvp)
		_mirror_loot.call_deferred(node)     # deferred: its setup() runs after add_child

func _mirror_loot(node: Node) -> void:
	if not is_instance_valid(node) or _loot.has(node):
		return
	var col: Color = node.get("item_color") if node.get("item_color") != null else Color(0.9, 0.85, 0.4)
	# Category-specific pickup mesh matching the 2D ItemArt icon (ore/bar/log/gem/
	# coin/fish/weapon…). Gold + PvP piles carry their own ids ("gold_coins" → coin).
	var item_id: String = str(node.get("item_id")) if node.get("item_id") != null else ""
	var mi := _mesh_instance(_mesh.call("item_mesh", item_id, col))
	add_child(mi)
	_loot[node] = mi
	_place_loot(mi, (node as Node2D).global_position)

func _place_loot(mesh: Node3D, px: Vector2) -> void:
	var wx := px.x * SCALE
	var wz := px.y * SCALE
	var y: float = INTERIOR_Y if _in_interior else _height_at_world(wx, wz)
	var t := float(Time.get_ticks_msec()) / 1000.0
	mesh.position = Vector3(wx, y + 0.42 + sin(t * 2.6 + wx) * 0.05, wz)   # gentle float
	mesh.rotation.y = t * 1.4                                             # slow spin

func _sync_loot() -> void:
	var dead: Array = []
	for ld: Variant in _loot.keys():
		if not is_instance_valid(ld):
			dead.append(ld); continue
		_place_loot(_loot[ld], (ld as Node2D).global_position)
	for ld: Variant in dead:
		if is_instance_valid(_loot[ld]): (_loot[ld] as Node).queue_free()
		_loot.erase(ld)

## Nearest loot node to the mouse in screen space, within `radius` px, or null.
func _pick_loot_screen(radius: float) -> Node2D:
	var mp := get_viewport().get_mouse_position()
	var best: Node2D = null
	var best_d := radius * radius
	for ld: Variant in _loot.keys():
		var mesh: Node3D = _loot[ld]
		if not is_instance_valid(ld) or not is_instance_valid(mesh):
			continue
		if _cam.is_position_behind(mesh.position):
			continue
		var dd := _cam.unproject_position(mesh.position).distance_squared_to(mp)
		if dd < best_d:
			best_d = dd
			best = ld as Node2D
	return best

# Gold + PvP piles are event-driven (server broadcast) — create the LootDrop like
# World.gd does; it mirrors to 3D through _on_container_child automatically.
func _on_gold_pile_spawn3d(pile_id: String, x: float, y: float, amount: int) -> void:
	if pile_id == "" or amount <= 0:
		return
	_free_pile(_gold_piles, pile_id)
	var ld := Area2D.new()
	ld.set_script(LootDropScript)
	ld.global_position = Vector2(x, y)
	_ent_container.add_child(ld)
	ld.call("setup_gold_pile", pile_id, amount)
	_gold_piles[pile_id] = ld

func _on_gold_pile_remove3d(pile_id: String) -> void:
	_free_pile(_gold_piles, pile_id)

func _on_pvp_pile_spawn3d(pile_id: String, x: float, y: float,
		item_id: String, item_name: String, qty: int, col: Color) -> void:
	if pile_id == "" or qty <= 0:
		return
	_free_pile(_pvp_piles, pile_id)
	var ld := Area2D.new()
	ld.set_script(LootDropScript)
	ld.global_position = Vector2(x, y)
	_ent_container.add_child(ld)
	ld.call("setup_pvp_pile", pile_id, item_id, item_name, qty, col)
	_pvp_piles[pile_id] = ld

func _on_pvp_pile_remove3d(pile_id: String) -> void:
	_free_pile(_pvp_piles, pile_id)

func _free_pile(reg: Dictionary, pile_id: String) -> void:
	if reg.has(pile_id):
		var ld: Variant = reg[pile_id]
		if is_instance_valid(ld):
			(ld as Node).queue_free()
		reg.erase(pile_id)

# ── mob + gather feed routing (mirror World.gd, routed to the paired 2D node) ──
func _node_of(id: String) -> Node:
	var e: Variant = _ent.get(id)
	if e == null:
		return null
	var n: Variant = (e as Dictionary)["n"]
	return n if is_instance_valid(n) else null

# ── Farming (3D) — mirror World.gd's routing onto the paired Interactable ──────
func _on_farm_plot_state3d(entity_id: String, stage: int, seed_id: String,
		grow: float, eff: float, boost: float) -> void:
	var n := _node_of(entity_id)
	if n != null and n.has_method("set_farm_stage"):
		n.call("set_farm_stage", stage, seed_id, grow, eff, boost)

func _on_farm_plot_burst3d(plots: Array) -> void:
	for entry: Variant in plots:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry
		var n := _node_of(str(d.get("id", "")))
		if n != null and n.has_method("set_farm_stage"):
			n.call("set_farm_stage", int(d.get("stage", 0)), str(d.get("seed_id", "")),
				float(d.get("grow", 0.0)), float(d.get("eff", 0.0)), float(d.get("boost", 0.0)))

func _on_farm_harvest_ok3d(_entity_id: String, item_id: String,
		item_name: String, qty: int, xp: int, seed_id: String) -> void:
	GameManager.grant_farm_harvest(item_id, item_name, qty, xp, seed_id)
	Events.chat_message.emit("Harvested %d× %s. +%d Farming XP." % [maxi(1, qty), item_name, xp])

func _on_farm_harvest_fail3d(_entity_id: String, seed_id: String,
		reason: String, xp: int) -> void:
	if xp > 0:
		GameManager.add_xp("farming", xp)
	if seed_id != "":
		GameManager.bump_recipe_count(seed_id)
	var pretty := seed_id.replace("_seed", "").capitalize()
	Events.chat_message.emit("The %s %s. +%d Farming XP." % [pretty, reason, xp])

func _on_farm_reject3d(reason: String, seed_id: String) -> void:
	GameManager.refund_farm_seed(seed_id)
	Events.chat_message.emit(reason)

## Like _node_of but ONLY returns actual Monster nodes — the mob_* feeds are
## global, so an id can land on a resource/NPC we also track; guard against
## calling monster-only methods (server_die, set_server_hp…) on them.
func _mob_of(id: String) -> Node:
	var n := _node_of(id)
	return n if n != null and n.has_method("server_die") else null

func _on_mob_state(id: String, hp: int, mhp: int) -> void:
	var n := _mob_of(id)
	if n != null: n.call("set_server_hp", hp, mhp)

func _on_mob_hit(id: String, x: float, y: float, amt: int, by: String, hp: int, mhp: int, _crit: bool = false, _missed: bool = false) -> void:
	var n := _mob_of(id)
	if n != null:
		n.call("set_server_hp", hp, mhp)
		n.call("flash_hit")
	# Rigged monsters flinch on being hit.
	var e: Variant = _ent.get(id)
	if e != null and is_instance_valid((e as Dictionary)["v"]):
		var v := (e as Dictionary)["v"] as Node3D
		if v.has_method("play_hit"):
			v.call("play_hit")
	# A REMOTE player landed this hit → play THEIR swing (local swing rides
	# Events.attack_swung). Keeps "see others fighting" true in 3D.
	if by != "" and by != NetworkManager.my_username:
		var av := _other_vis_by_name(by)
		if av != null and av.has_method("play_action"):
			av.call("play_action", "attack")
	if amt > 0:
		_spawn_dmg3d(Vector2(x, y), amt, by == NetworkManager.my_username)

## Monster launched an attack (server broadcast) → play its rig attack swing.
func _on_monster_attacked3d(id: String) -> void:
	var e: Variant = _ent.get(id)
	if e != null and is_instance_valid((e as Dictionary)["v"]):
		var v := (e as Dictionary)["v"] as Node3D
		if v.has_method("play_action"):
			v.call("play_action", "attack")

## The 3D rig visual for another player by username, or null.
func _other_vis_by_name(uname: String) -> Node3D:
	for pid: Variant in NetworkManager._other_players.keys():
		var op: Variant = NetworkManager._other_players[pid]
		if is_instance_valid(op) and str((op as Node).get_meta("username", "")) == uname:
			var vis: Variant = _op_bb.get(pid)
			return vis if is_instance_valid(vis) else null
	return null

func _on_mob_died(id: String, killer: String, xp_each: int,
		_participants: Array, xp_recipients: Array) -> void:
	var n := _mob_of(id)
	if n == null:
		return
	var me := NetworkManager.my_username
	if me in xp_recipients and xp_each > 0:
		GameManager.add_xp("melee", xp_each)
		GameManager.add_xp("defense", maxi(1, floori(xp_each * 0.3)))
		GameManager.add_xp("vitality", maxi(1, floori(xp_each * 0.3)))
		Events.monster_killed.emit(str(n.get("monster_type")))
		GameManager.on_monster_killed(str(n.get("monster_type")))
	if me == killer:
		n.call("spawn_loot_drops")
	n.call("server_die")
	_kill_mob_visual(id)

## Play a 3D death: the 2D node's fall+fade isn't mirrored, so sink + shrink the mesh
## then hide it. Skipped by _sync_entity_meshes while dead so the tween owns it.
func _kill_mob_visual(id: String) -> void:
	var e: Variant = _ent.get(id)
	if e == null or not is_instance_valid((e as Dictionary)["v"]):
		return
	var v := (e as Dictionary)["v"] as Node3D
	_dead_mobs[id] = true
	# Rigged monsters play a topple/sink death; single meshes shrink + fade.
	if v.has_method("play_death"):
		v.call("play_death")
		return
	v.set_meta("base_scale", v.scale)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(v, "scale", v.scale * 0.04, 0.55).set_ease(Tween.EASE_IN)
	tw.tween_property(v, "position:y", v.position.y - 0.6, 0.55)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(v):
			v.visible = false)

func _on_mob_respawned(id: String) -> void:
	var n := _mob_of(id)
	if n != null: n.call("server_respawn")
	_dead_mobs.erase(id)
	var e: Variant = _ent.get(id)
	if e != null and is_instance_valid((e as Dictionary)["v"]):
		var v := (e as Dictionary)["v"] as Node3D
		if v.has_method("play_respawn"):
			v.call("play_respawn")   # un-topple the rig
		else:
			v.scale = v.get_meta("base_scale", v.scale)
		v.visible = true   # position restored by the next _sync

func _on_mob_states_received(nodes: Array) -> void:
	for entry: Variant in nodes:
		if not (entry is Dictionary): continue
		var d: Dictionary = entry
		var mid := str(d.get("id", ""))
		var n := _mob_of(mid)
		if n == null: continue
		if bool(d.get("alive", true)):
			n.call("set_server_hp", int(d.get("hp", 1)), int(d.get("max_hp", 1)))
		else:
			n.call("server_die")
			_kill_mob_visual(mid)

## Server AI position batch — steer each live monster's 2D node toward the target;
## the mesh mirrors it (smoothed in _sync_entity_meshes so motion isn't steppy).
func _on_mob_positions3d(updates: Array) -> void:
	for u: Variant in updates:
		if not (u is Dictionary): continue
		var d: Dictionary = u
		var id := str(d.get("id", ""))
		var n := _mob_of(id)
		if n == null: continue
		var n2 := n as Node2D
		_mob_target[id] = Vector2(float(d.get("x", n2.global_position.x)),
			float(d.get("y", n2.global_position.y)))

func _on_gather_granted(id: String) -> void:
	var n := _node_of(id)
	if n != null: n.call("begin_gather")

func _on_gather_denied(id: String) -> void:
	var n := _node_of(id)
	if n != null: n.call("on_gather_busy")

func _on_node_remote_locked(id: String, username: String) -> void:
	var n := _node_of(id)
	if n != null: n.call("set_remote_gathering", true, username)

func _on_node_remote_unlocked(id: String) -> void:
	var n := _node_of(id)
	if n != null: n.call("set_remote_gathering", false, "")

func _on_node_remote_depleted(id: String, respawn_in: float) -> void:
	var n := _node_of(id)
	if n != null: n.call("apply_depleted", respawn_in)

func _on_node_remote_respawned(id: String, x: float = -1.0, y: float = -1.0) -> void:
	var n := _node_of(id)
	if n == null:
		return
	# Admin gatherables wander on respawn (x/y ≥ 0) — relocate before un-depleting.
	if x >= 0.0:
		_relocate3d(n, Vector2(x, y))
	n.call("apply_respawn")

func _on_node_states_received(nodes: Array) -> void:
	for entry: Variant in nodes:
		if not (entry is Dictionary): continue
		var d: Dictionary = entry
		var n := _node_of(str(d.get("id", "")))
		if n == null: continue
		var depleted_in := float(d.get("depleted_in", 0.0))
		var locked_by := str(d.get("locked_by", ""))
		if depleted_in > 0.0: n.call("apply_depleted", depleted_in)
		elif not locked_by.is_empty(): n.call("set_remote_gathering", true, locked_by)

# ── per-frame: mirror each mesh to its (possibly moving) 2D logic node ─────────
func _sync_entity_meshes() -> void:
	var dead: Array = []
	for id: Variant in _ent.keys():
		var d: Dictionary = _ent[id]
		if not is_instance_valid(d["n"]) or not is_instance_valid(d["v"]):   # check BEFORE casting
			dead.append(id); continue
		if _dead_mobs.has(id):
			continue   # a dying monster — its death-fade tween owns the mesh
		var n := d["n"] as Node2D
		var v := d["v"] as Node3D
		# Smooth server-driven monster motion toward its last target.
		if _mob_target.has(id):
			n.global_position = n.global_position.lerp(_mob_target[id] as Vector2, 0.18)
		var prev: Vector2 = v.get_meta("epx", n.global_position)
		_place(v, n.global_position)
		v.visible = n.visible   # server_die / depletion hides the 2D node → hide the mesh
		# Single-mesh monsters face their movement direction here (models front
		# toward -Z, so +PI). RIGGED monsters self-face from their own motion.
		if n.get("monster_type") != null and not v.has_meta("rig"):
			var mv := n.global_position - prev
			if mv.length() > 0.5:
				v.rotation.y = lerp_angle(v.rotation.y, atan2(mv.x, mv.y) + PI, 0.2)
	for id: Variant in dead:
		_mob_target.erase(id)
		_free_ent(str(id))

# ── 3D ray picking → the existing 2D interaction pipeline ─────────────────────
## Nearest entity 2D node within `radius` px of a world-px point, or null.
func _pick_entity(px: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius * radius
	for id: Variant in _ent.keys():
		if not is_instance_valid((_ent[id] as Dictionary)["n"]):
			continue
		var n := (_ent[id] as Dictionary)["n"] as Node2D
		if not n.visible:
			continue
		var dd := n.global_position.distance_squared_to(px)
		if dd < best_d:
			best_d = dd
			best = n
	return best

## Nearest entity to the MOUSE in SCREEN space (camera-angle + zoom independent, so
## it matches what you click). Samples the mesh base + a mid-height point so tall
## trees pick along their whole silhouette. Returns null if nothing's within `radius`.
func _pick_entity_screen(radius: float) -> Node2D:
	var mp := get_viewport().get_mouse_position()
	var best: Node2D = null
	var best_d := radius * radius
	for id: Variant in _ent.keys():
		var d: Dictionary = _ent[id]
		if not is_instance_valid(d["n"]) or not is_instance_valid(d["v"]):
			continue
		var n := d["n"] as Node2D
		var v := d["v"] as Node3D
		if not n.visible:
			continue
		var sy: float = v.scale.y
		for wp: Vector3 in [v.position + Vector3(0, 0.3 * sy, 0),
				v.position + Vector3(0, 1.5 * sy, 0)]:
			if _cam.is_position_behind(wp):
				continue
			var dd := _cam.unproject_position(wp).distance_squared_to(mp)
			if dd < best_d:
				best_d = dd
				best = n
	return best

# ══ ADMIN TOOLS in 3D ═════════════════════════════════════════════════════════
# The real AdminPanel is reused (place/delete/move/paint). It converts a mouse
# click to a world position via _screen_to_world + finds entities via the parent's
# admin_entity_at — both hooked below to the 3D ground ray. Placement/delete/move
# just send to the server; the world_entity_* feeds then spawn/free/move the pairs.
var _admin_panel: Node

func _spawn_admin_panel_if_admin() -> void:
	if _admin_panel != null and is_instance_valid(_admin_panel):
		return
	if NetworkManager.my_admin_rank == "":
		return
	_admin_panel = (load("res://scripts/ui/AdminPanel.gd") as GDScript).new() as Node
	add_child(_admin_panel)
	Events.chat_message.emit("[Admin] 3D tools loaded — press F10 or the ⚙ ADMIN button.")

func _on_admin_rank_changed3d(rank: String) -> void:
	if rank == "":
		if _admin_panel != null and is_instance_valid(_admin_panel):
			_admin_panel.queue_free()
			_admin_panel = null
	else:
		_spawn_admin_panel_if_admin()

## AdminPanel hook — screen px → world px via the 3D ground ray.
func world_pos_from_screen(screen_pos: Vector2) -> Vector2:
	var hit := _ray_to_ground(screen_pos)
	if hit.x == INF:
		return _player_px()   # off-terrain click → harmless fallback
	return Vector2(hit.x / SCALE, hit.z / SCALE)

## AdminPanel hook — nearest editable entity id within `radius` px, or "".
func admin_entity_at(world_pos: Vector2, radius: float = 44.0) -> String:
	var best := ""
	var best_d := radius * radius
	for id: Variant in _ent.keys():
		if not is_instance_valid((_ent[id] as Dictionary)["n"]):
			continue
		var n := (_ent[id] as Dictionary)["n"] as Node2D
		var dd := n.global_position.distance_squared_to(world_pos)
		if dd < best_d:
			best_d = dd
			best = str(id)
	return best

## Raw stored wire dict for an admin-placed entity (id → {kind,subtype,x,y,data}),
## or {} if not cached. The Inspect editor seeds its form from this.
func admin_entity_info(id: String) -> Dictionary:
	var v: Variant = _admin_entity_data.get(id, {})
	if v is Dictionary and not (v as Dictionary).is_empty():
		return v as Dictionary
	if _admin_id_chunk3d.has(id):
		var ch: Vector2i = _admin_id_chunk3d[id]
		for e: Variant in _admin_index3d.get(ch, []):
			if str((e as Dictionary).get("id", "")) == id:
				return e as Dictionary
	if not id.begins_with("a:"):
		var n := _node_of(id)
		if n != null:
			return _synth_info_for3d(n, id)
	return {}

func _synth_info_for3d(node: Node, id: String) -> Dictionary:
	var ntype: Variant = node.get("npc_type")
	if ntype is String and str(ntype) != "":
		var wr: Variant = node.get("wander_radius")
		return {"id": id, "kind": "npc", "subtype": str(ntype), "data": {
			"npc_name": str(node.get("npc_name_str")),
			"quest_text": str(node.get("quest_text")),
			"wander_radius": float(wr) if wr != null else 32.0,
			"shop_id": str(node.get("shop_id"))}}
	var mtype: Variant = node.get("monster_type")
	if mtype is String and str(mtype) != "":
		var lv: Variant = node.get("level")
		return {"id": id, "kind": "monster", "subtype": str(mtype),
			"data": {"level": int(lv) if lv != null else 1}}
	return {}

## All loaded editable entities as [{id, name, pos}], name-sorted, for the browser.
func admin_entity_list() -> Array:
	var out: Array = []
	for id_v: Variant in _ent.keys():
		var id := str(id_v)
		var e: Dictionary = _ent[id]
		if not is_instance_valid(e["n"]):
			continue
		var n := e["n"] as Node2D
		out.append({"id": id, "name": _editable_name3d(n), "pos": n.global_position})
	# Streamed-out admin entities (indexed, not currently spawned).
	var seen: Dictionary = {}
	for r: Variant in out:
		seen[str((r as Dictionary)["id"])] = true
	for ch: Variant in _admin_index3d.keys():
		for ev: Variant in _admin_index3d[ch]:
			var ed: Dictionary = ev
			var eid := str(ed.get("id", ""))
			if eid.is_empty() or seen.has(eid):
				continue
			seen[eid] = true
			var data: Dictionary = ed.get("data", {}) as Dictionary if ed.get("data") is Dictionary else {}
			out.append({"id": eid,
				"name": str(data.get("npc_name", data.get("display_name", data.get("monster_type", eid)))),
				"pos": Vector2(float(ed.get("x", 0.0)), float(ed.get("y", 0.0)))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out

func _editable_name3d(n: Node) -> String:
	for prop: String in ["npc_name_str", "display_name"]:
		var v: Variant = n.get(prop)
		if v is String and not (v as String).is_empty():
			return v as String
	var mt: Variant = n.get("monster_type")
	if mt is String and not (mt as String).is_empty():
		return (mt as String).capitalize()
	return str(n.name)

## Live world-px position of an admin entity's logic node (for Undo of a Move).
func admin_entity_pos(id: String) -> Vector2:
	if _ent.has(id) and is_instance_valid((_ent[id] as Dictionary)["n"]):
		return ((_ent[id] as Dictionary)["n"] as Node2D).global_position
	return Vector2.ZERO

## Admin minimap teleport — jump the player to a world-px position (overworld only).
func admin_teleport(world_pos: Vector2) -> void:
	if _player_node == null:
		return
	if GameManager.in_interior:
		NetworkManager.send_exit_interior()
		Events.chat_message.emit("[Admin] Left the interior — open the map again to teleport.")
		return
	_player_node.global_position = world_pos
	Events.chat_message.emit("[Admin] Teleported to (%d, %d)." % [int(world_pos.x), int(world_pos.y)])

## AdminPanel hook — the 3D client has no 2D passability overlay (no-op stub).
func set_passability_overlay_visible(_v: bool) -> void:
	pass

# ── live admin tile-painting (server broadcasts → repaint 3D terrain) ─────────
func _on_tile_override_set(tx: int, ty: int, biome: String) -> void:
	_apply_tile(tx, ty, biome)
	if _ground_node != null:
		_ground_node.call("set_tile_override", tx, ty, biome)

func _on_tile_override_cleared(tx: int, ty: int) -> void:
	if _ground_node != null:
		_ground_node.call("clear_tile_override", tx, ty)
		_apply_tile(tx, ty, str(_ground_node.call("_biome_at", tx, ty)))   # back to procedural base

func _on_tile_overrides_bulk3d(entries: Array) -> void:
	if _ground_node != null:
		_ground_node.call("apply_tile_overrides_bulk", entries)
	for e: Variant in entries:
		if e is Dictionary:
			var d: Dictionary = e
			_apply_tile(int(d.get("tx", -1)), int(d.get("ty", -1)), str(d.get("biome", "")))

## Stamp one tile's height+colour and flag the terrain dirty (rebuilt, throttled,
## in _process so a paint-drag doesn't rebuild 90k quads per tile).
func _apply_tile(tx: int, ty: int, biome: String) -> void:
	if tx < 0 or tx >= MAP_N or ty < 0 or ty >= MAP_N or biome == "":
		return
	var idx := ty * MAP_N + tx
	_tile_h[idx] = _biome_height(biome)
	_tile_col[idx] = _biome_color(biome)
	_mark_dirty(tx, ty)

## Flag the chunk containing (tx,ty) + its neighbours dirty (the smoothing blur
## spreads a few tiles across chunk edges, so neighbours must rebuild too).
func _mark_dirty(tx: int, ty: int) -> void:
	var ccx := floori(float(tx) / float(CHUNK))
	var ccy := floori(float(ty) / float(CHUNK))
	var nch := int(ceil(float(MAP_N) / float(CHUNK)))
	for oy: int in [-1, 0, 1]:
		for ox: int in [-1, 0, 1]:
			var cx := ccx + ox
			var cy := ccy + oy
			if cx >= 0 and cx < nch and cy >= 0 and cy < nch:
				_dirty_chunks["%d,%d" % [cx, cy]] = true

# ══ P4 — WORLD-ANCHORED UI (3D-native) ═══════════════════════════════════════
# Nameplates (players/NPCs), billboarded HP bars (monsters), floating damage
# numbers, and chat bubbles — all real 3D nodes (Label3D / Sprite3D) so they sit
# correctly over the perspective world. Driven by the same entity data + Events.
var _white_tex: Texture2D           # 1×1 white for the HP-bar sprites
var _hpbars: Dictionary = {}        # monster id → Node3D (billboarded bar above it)
var _bubbles: Dictionary = {}       # speaker key → Label3D (one bubble per speaker)

func _make_white_tex() -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color.WHITE)
	return ImageTexture.create_from_image(img)

## Billboarded text tag (nameplate / bubble / damage number).
func _label3d(text: String, col: Color, font := 48, pixel := 0.006) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = font
	l.pixel_size = pixel
	l.modulate = col
	l.outline_size = 12
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.no_depth_test = true
	return l

## Attach a nameplate above a scale-1 actor mesh (players / NPCs).
func _attach_nameplate(mesh: Node3D, text: String, col: Color) -> void:
	if text.strip_edges().is_empty():
		return
	var l := _label3d(text, col, 40, 0.0055)
	l.position = Vector3(0, 2.35, 0)
	mesh.add_child(l)

## A center-shrinking HP bar (two billboarded sprites; no offset → billboard-safe).
func _make_hpbar() -> Node3D:
	var root := Node3D.new()
	var bg := Sprite3D.new()
	bg.texture = _white_tex
	bg.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bg.modulate = Color(0.08, 0.03, 0.03)
	bg.scale = Vector3(1.5, 0.22, 1)
	bg.no_depth_test = true
	bg.render_priority = 10
	root.add_child(bg)
	var fill := Sprite3D.new()
	fill.name = "Fill"
	fill.texture = _white_tex
	fill.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	fill.scale = Vector3(1.4, 0.15, 1)
	fill.no_depth_test = true
	fill.render_priority = 11
	root.add_child(fill)
	return root

func _update_hpbar(bar: Node3D, frac: float) -> void:
	var f := clampf(frac, 0.0, 1.0)
	var fill := bar.get_node("Fill") as Sprite3D
	fill.scale.x = 1.4 * f
	fill.modulate = Color(1.0 - f, 0.25 + 0.55 * f, 0.15)   # green → red as HP drops

## Refresh monster HP bars from the paired 2D node hp (called each frame). Bars
## show only for alive, damaged monsters and float above the (scaled) mesh.
func _sync_hpbars() -> void:
	for id: Variant in _ent.keys():
		var d: Dictionary = _ent[id]
		if not is_instance_valid(d["n"]) or not is_instance_valid(d["v"]):   # before casting
			_drop_hpbar(id); continue
		var n := d["n"] as Node2D
		var v := d["v"] as Node3D
		if n.get("monster_type") == null:
			_drop_hpbar(id); continue
		var alive := bool(n.get("is_alive")) if n.get("is_alive") != null else true
		var hp := int(n.get("current_hp")) if n.get("current_hp") != null else 0
		var mhp := maxi(1, int(n.get("max_hp")) if n.get("max_hp") != null else 1)
		if not alive or not n.visible or hp >= mhp:
			_drop_hpbar(id); continue
		var bar: Node3D = _hpbars.get(id)
		if bar == null or not is_instance_valid(bar):
			bar = _make_hpbar()
			add_child(bar)
			_hpbars[id] = bar
		bar.position = v.position + Vector3(0, 2.2 * v.scale.y + 0.5, 0)
		_update_hpbar(bar, float(hp) / float(mhp))

func _drop_hpbar(id: Variant) -> void:
	var bar: Node3D = _hpbars.get(id)
	if bar != null and is_instance_valid(bar):
		bar.queue_free()
	_hpbars.erase(id)

## Floating "-N" damage number at a world-px hit point.
func _spawn_dmg3d(px: Vector2, amount: int, from_player: bool) -> void:
	var l := _label3d("-%d" % amount,
		Color(1, 0.96, 0.6) if from_player else Color(1, 0.32, 0.32), 44, 0.008)
	l.render_priority = 20
	var wx := px.x * SCALE
	var wz := px.y * SCALE
	var base := Vector3(wx, _height_at_world(wx, wz) + 2.2 + randf_range(-0.1, 0.2), wz)
	l.position = base
	add_child(l)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", base.y + 1.4, 0.8).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "modulate:a", 0.0, 0.8).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(l.queue_free)

## World-chat → a 3D speech bubble above the speaker (one per speaker, ~4 s).
func _on_world_chat3d(username: String, text: String) -> void:
	if text.strip_edges().is_empty():
		return
	var mesh := _chat_speaker_mesh(username)
	if mesh == null:
		return
	var old: Label3D = _bubbles.get(username)
	if old != null and is_instance_valid(old):
		old.queue_free()
	var l := _label3d(text, Color(1, 1, 1), 36, 0.006)
	l.position = Vector3(0, 3.0, 0)
	l.modulate = Color(1, 1, 1)
	mesh.add_child(l)
	_bubbles[username] = l
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if is_instance_valid(l):
			l.queue_free())

func _chat_speaker_mesh(username: String) -> Node3D:
	if username == NetworkManager.my_username:
		return _player_spr
	for pid: Variant in _op_bb.keys():
		var op: Variant = NetworkManager._other_players.get(pid)
		if op != null and is_instance_valid(op) and str((op as Node2D).get_meta("username", "")) == username:
			return _op_bb[pid]
	return null

# ══ P5 — ADMIN HEIGHT SCULPT (client-side; visual, saved to user://) ══════════
# H toggles sculpt (admin only): LMB raise / RMB lower the terrain under the
# cursor with a smooth brush, [ / ] shrink/grow the brush. Deltas layer on the
# biome base (blurred → rounded) so you can flatten a town or round a hill by
# hand. Saved to user://height3d.json (loaded on start). Server sync = a later
# step; for now it's a local visual edit per the plan's "visual-first" elevation.
func _toggle_sculpt() -> void:
	if NetworkManager.my_admin_rank == "":
		Events.chat_message.emit("[Sculpt] Admin only.")
		return
	_sculpt = not _sculpt
	if _sculpt:
		Events.chat_message.emit("[Sculpt] ON — LMB raise · RMB lower · [ / ] brush (%d)." % int(_brush))
	else:
		_flush_sculpt()
		Events.chat_message.emit("[Sculpt] OFF — synced to server.")

func _apply_sculpt(raise: bool, dt: float) -> void:
	var hit := _ray_to_ground()
	if hit.x == INF:
		return
	_sculpt_brush(int(hit.x / CELL), int(hit.z / CELL), _brush,
		_SCULPT_STRENGTH * dt * (1.0 if raise else -1.0))

## AdminPanel Height tab hook — sculpt at a world px with the given brush (tiles).
## Called on LMB-drag; a small fixed amount per stroke accumulates over the drag.
func sculpt_at(wpos: Vector2, raise: bool, brush: int) -> void:
	if NetworkManager.my_admin_rank == "":
		return
	_sculpt_brush(int(wpos.x / 32.0), int(wpos.y / 32.0), float(maxi(1, brush)),
		0.06 * (1.0 if raise else -1.0))

## Add `amt` (× smooth falloff) to _h_delta for every tile within `radius` of the
## brush centre, marking touched chunks dirty. Shared by the H-key + AdminPanel paths.
func _sculpt_brush(ctx: int, cty: int, radius: float, amt: float) -> void:
	var r := int(ceil(radius))
	for oy in range(-r, r + 1):
		for ox in range(-r, r + 1):
			var tx := ctx + ox
			var ty := cty + oy
			if tx < 0 or tx >= MAP_N or ty < 0 or ty >= MAP_N:
				continue
			var dist := sqrt(float(ox * ox + oy * oy))
			if dist > radius:
				continue
			var fall := 1.0 - smoothstep(0.0, radius, dist)
			var idx := ty * MAP_N + tx
			_h_delta[idx] = float(_h_delta.get(idx, 0.0)) + amt * fall
			_pending_sculpt[str(idx)] = _h_delta[idx]   # absolute delta → server
			_mark_dirty(tx, ty)
	_h_changed = true

## Push queued sculpt edits to the SERVER (v1.6.1 — was a local file). The server
## persists + broadcasts them, so admin height edits sync to every 3D client.
func _flush_sculpt() -> void:
	if _pending_sculpt.is_empty():
		return
	NetworkManager.send_admin_sculpt(_pending_sculpt.duplicate())
	_pending_sculpt.clear()

## Full server height set on login/switch. Server is authoritative; any LOCAL-only
## sculpt (from the pre-1.6.1 client-local file) is migrated UP so the admin's
## in-progress map isn't lost, then the local file is retired.
func _on_terrain_heights_full(tiles: Dictionary) -> void:
	var migrate: Dictionary = {}
	for idx: Variant in _h_delta.keys():
		var ks := str(idx)
		if not tiles.has(ks):
			migrate[ks] = _h_delta[idx]
	_h_delta.clear()
	for k: Variant in tiles.keys():
		_h_delta[int(str(k))] = float(tiles[k])
	for k2: Variant in migrate.keys():
		_h_delta[int(str(k2))] = float(migrate[k2])   # keep local-only until pushed
	if not migrate.is_empty():
		NetworkManager.send_admin_sculpt(migrate)
		_retire_local_sculpt()
	_rebuild_terrain_full()

## Incremental server broadcast (our own echo + other admins' edits).
func _on_terrain_height_set(tiles: Dictionary) -> void:
	for k: Variant in tiles.keys():
		var idx := int(str(k))
		var d := float(tiles[k])
		if absf(d) < 0.0001:
			_h_delta.erase(idx)
		else:
			_h_delta[idx] = d
		@warning_ignore("integer_division")
		var ty := idx / MAP_N
		_mark_dirty(idx % MAP_N, ty)
	# Dirty chunks rebuild in _process; don't set _h_changed (incoming, not ours).

func _rebuild_terrain_full() -> void:
	_precompute_corners()
	_rebuild_all_chunks()
	_reseat_static_and_entities()

## One-time migration: the old client-local height file has been pushed to the
## server, so rename it aside to avoid resurrecting server-deleted sculpts.
func _retire_local_sculpt() -> void:
	var da := DirAccess.open("user://")
	if da != null and da.file_exists("height3d.json"):
		da.rename("height3d.json", "height3d.json.migrated")

## Load the pre-1.6.1 client-local sculpt file, if present — used only as the
## migration source (its tiles get pushed to the server on the next login).
func _load_sculpt() -> void:
	if not FileAccess.file_exists("user://height3d.json"):
		return
	var f := FileAccess.open("user://height3d.json", FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("h"):
		var hm: Dictionary = (parsed as Dictionary)["h"]
		for k: Variant in hm.keys():
			_h_delta[int(str(k))] = float(hm[k])
