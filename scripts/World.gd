extends Node2D

const TILE := 32
const COLS := 300
const ROWS := 300

# Chunk streaming
const CHUNK_SIZE    := 16    # tiles per chunk side
const CHUNK_PX      := 512   # CHUNK_SIZE * TILE
const ACTIVE_RADIUS := 3     # chunks in each direction (= 48 tiles)
const RES_ATTEMPTS  := 8     # resource spawn attempts per chunk
const MON_ATTEMPTS  := 4     # monster spawn attempts per chunk

const _Interactable := preload("res://scenes/Interactable.tscn")
const _Monster      := preload("res://scripts/Monster.gd")
const _NPC          := preload("res://scripts/NPC.gd")
const _FarmPlot     := preload("res://scripts/FarmPlot.gd")

# Monster-free buffers around each town (pixel bounds + 15-tile margin)
const _SAFE_ZONES: Array = [
	Rect2(1984, 3008, 1376, 1376),   # Kjelvik
	Rect2( 704,  256, 1376, 1376),   # Frostheim
	Rect2(2880, 4288, 1376, 1376),   # Ironwood Keep
	Rect2(5248, 5184, 1376, 1376),   # Eastmark Post
	Rect2(7200, 3744, 1376, 1376),   # Bjorn's Landing
]

## Town buildings and fixed structures (static, always active once world starts)
const _TOWN_NODES: Array = [
	# ══ KJELVIK ══════════════════════════════════════════════════════════════════
	[Vector2(2528, 3520), "building",     "House",             "soul",         1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(2720, 3520), "building",     "House",             "soul",         1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(2816, 3552), "building",     "Tavern",            "soul",         1, "Inspect", Color(0.70, 0.48, 0.22)],
	[Vector2(2624, 3552), "building",     "Great Hall",        "soul",         1, "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(2528, 3680), "building",     "Warehouse",         "soul",         1, "Inspect", Color(0.50, 0.44, 0.32)],
	[Vector2(2752, 3680), "building",     "Chapel",            "soul",         1, "Inspect", Color(0.75, 0.72, 0.66)],
	[Vector2(2848, 3744), "building",     "House",             "soul",         1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(2624, 3744), "forge",        "Smithing Forge",    "smithing",     1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(2720, 3744), "fire",         "Campfire",          "cooking",      1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(2464, 3616), "bank",         "Bank",              "soul",         1, "Access",  Color(0.75, 0.65, 0.20)],
	[Vector2(2528, 3808), "crafting",     "Crafting Bench",    "crafting",     1, "Craft",   Color(0.55, 0.38, 0.18)],
	[Vector2(2848, 3616), "archery",      "Archery Range",     "ranged",       1, "Train",   Color(0.80, 0.22, 0.10)],
	[Vector2(2848, 3808), "runestone",    "Runestone",         "magic",        1, "Study",   Color(0.58, 0.25, 0.82)],
	[Vector2(2720, 3808), "construction", "Construction Site", "construction", 1, "Build",   Color(0.55, 0.40, 0.20)],
	[Vector2(2464, 3808), "auction_house","Auction House",     "soul",         1, "Browse",  Color(0.45, 0.60, 0.85)],
	# ══ FROSTHEIM ════════════════════════════════════════════════════════════════
	[Vector2(1312, 768),  "auction_house","Auction House", "soul",     1, "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(1216, 768),  "building", "House",             "soul",     1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(1408, 768),  "building", "House",             "soul",     1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(1312, 896),  "building", "Tavern",            "soul",     1, "Inspect", Color(0.70, 0.48, 0.22)],
	[Vector2(1216, 992),  "building", "Great Hall",        "soul",     1, "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(1344, 992),  "forge",    "Smithing Forge",    "smithing", 1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(1440, 992),  "fire",     "Campfire",          "cooking",  1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(1184, 896),  "crafting", "Crafting Bench",    "crafting", 1, "Craft",   Color(0.55, 0.38, 0.18)],
	[Vector2(1440, 896),  "archery",  "Archery Range",     "ranged",   1, "Train",   Color(0.80, 0.22, 0.10)],
	[Vector2(1184, 992),  "bank",     "Frost Vault",       "soul",     1, "Access",  Color(0.75, 0.65, 0.20)],
	# ══ IRONWOOD KEEP ════════════════════════════════════════════════════════════
	[Vector2(3680, 5024), "auction_house","Auction House",       "soul",         1, "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(3392, 4800), "building",     "House",               "soul",         1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(3584, 4800), "building",     "Great Hall",          "soul",         1, "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(3680, 4832), "building",     "House",               "soul",         1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(3424, 4928), "building",     "Warehouse",           "soul",         1, "Inspect", Color(0.50, 0.44, 0.32)],
	[Vector2(3456, 5024), "forge",        "Smithing Forge",      "smithing",     1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(3584, 5008), "fire",         "Campfire",            "cooking",      1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(3680, 4944), "bank",         "Bank",                "soul",         1, "Access",  Color(0.75, 0.65, 0.20)],
	[Vector2(3360, 5024), "construction", "Construction Site",   "construction", 5, "Build",   Color(0.55, 0.40, 0.20)],
	[Vector2(3520, 4960), "runestone",    "Ancient Runestone",   "magic",        5, "Study",   Color(0.58, 0.25, 0.82)],
	# ══ EASTMARK POST ════════════════════════════════════════════════════════════
	[Vector2(6048, 5984), "auction_house","Auction House", "soul",     1, "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(5760, 5696), "building", "House",             "soul",     1, "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(5952, 5696), "building", "House",             "soul",     1, "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(5856, 5792), "building", "Tavern",            "soul",     1, "Inspect", Color(0.70, 0.48, 0.22)],
	[Vector2(5760, 5888), "forge",    "Smithing Forge",    "smithing", 1, "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(5888, 5888), "fire",     "Campfire",          "cooking",  1, "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(6048, 5760), "archery",  "Archery Range",     "ranged",   1, "Train",   Color(0.80, 0.22, 0.10)],
	[Vector2(5760, 5984), "crafting", "Crafting Bench",    "crafting", 1, "Craft",   Color(0.55, 0.38, 0.18)],
	[Vector2(5952, 5984), "bank",     "Outpost Vault",     "soul",     1, "Access",  Color(0.75, 0.65, 0.20)],
	# ══ BJORN'S LANDING ══════════════════════════════════════════════════════════
	[Vector2(7936, 4480), "auction_house","Auction House",     "soul",         1,  "Browse",  Color(0.45, 0.60, 0.85)],
	[Vector2(7712, 4256), "building",     "House",             "soul",         1,  "Inspect", Color(0.65, 0.52, 0.35)],
	[Vector2(7872, 4256), "building",     "House",             "soul",         1,  "Inspect", Color(0.62, 0.50, 0.33)],
	[Vector2(7808, 4384), "building",     "Great Hall",        "soul",         1,  "Inspect", Color(0.35, 0.22, 0.12)],
	[Vector2(7936, 4352), "building",     "Warehouse",         "soul",         1,  "Inspect", Color(0.50, 0.44, 0.32)],
	[Vector2(7744, 4480), "forge",        "Smithing Forge",    "smithing",     1,  "Smith",   Color(0.80, 0.35, 0.12)],
	[Vector2(7872, 4480), "fire",         "Campfire",          "cooking",      1,  "Cook",    Color(1.00, 0.55, 0.10)],
	[Vector2(8000, 4352), "bank",         "Bank",              "soul",         1,  "Access",  Color(0.75, 0.65, 0.20)],
	[Vector2(7712, 4480), "construction", "Construction Site", "construction", 10, "Build",   Color(0.55, 0.40, 0.20)],
	[Vector2(8032, 4448), "runestone",    "Sea Runestone",     "magic",        10, "Study",   Color(0.58, 0.25, 0.82)],
]

## NPC spawn data: [pos, npc_type, npc_name, quest_text, wander_radius]
const _NPCS: Array = [
	# ── Kjelvik ──────────────────────────────────────────────────────────────────
	[Vector2(2672, 3648), "quest",      "Elder Bjarne",
		"Prove your worth, warrior — clear the rats nesting near our walls.", 32.0],
	[Vector2(2576, 3680), "worker",     "Karl",   "", 56.0],
	[Vector2(2784, 3664), "worker",     "Sigrid", "", 64.0],
	[Vector2(2496, 3744), "shopkeeper", "Trader Hroar",
		"Rope, string, provisions — if you need it, I have it.", 24.0],
	[Vector2(2464, 3616), "banker",     "Gunhild the Treasurer",
		"Your gold is safe with me. Deposit or withdraw — the choice is yours.", 16.0],
	[Vector2(2848, 3680), "tutor",      "Valgerd the Craftswoman",
		"Gather sticks and stones from the forest floor. Lash them together at the workbench.", 20.0],
	[Vector2(2848, 3744), "trainer",    "Eirik Ironarm",
		"Train at the archery range daily. Combat is the fastest path to strength.", 20.0],
	[Vector2(2720, 3808), "quest",      "Torsten the Wanderer",
		"The Ironwood to the east holds great treasure — and greater danger.", 48.0],
	[Vector2(2624, 3808), "shopkeeper", "Merchant Dalla",
		"Potions, tools, and curiosities from every corner of the realm.", 20.0],
	[Vector2(2560, 3616), "worker",     "Hakon the Farmer", "", 80.0],
	# ── Frostheim ────────────────────────────────────────────────────────────────
	[Vector2(1312, 880),  "quest",      "Hunter Ragnhild",
		"A frost wolf prowls the northern peaks. Bring back its pelt!", 32.0],
	[Vector2(1216, 880),  "worker",     "Leif",   "", 48.0],
	[Vector2(1408, 912),  "worker",     "Astrid", "", 48.0],
	[Vector2(1184, 992),  "banker",     "Sigvard the Frost Keeper",
		"Cold as the vault, steady as the mountain. Your wealth is secure here.", 16.0],
	[Vector2(1408, 768),  "shopkeeper", "Merchant Bera",
		"Furs, cold-weather gear, and the finest brews north of Kjelvik.", 24.0],
	[Vector2(1312, 992),  "trainer",    "Gunnar Coldhand",
		"The cold sharpens the warrior. Train here and grow stronger.", 20.0],
	# ── Ironwood Keep ────────────────────────────────────────────────────────────
	[Vector2(3520, 4896), "quest",      "Blacksmith Ulfr",
		"I need ironwood logs to forge a legendary blade. Gather what you can.", 32.0],
	[Vector2(3392, 4960), "worker",     "Gorm",   "", 64.0],
	[Vector2(3680, 4976), "worker",     "Brynja", "", 48.0],
	[Vector2(3680, 4944), "banker",     "Armgard the Treasurer",
		"The keep's vault is yours to use. What do you need?", 16.0],
	[Vector2(3456, 4960), "shopkeeper", "Trader Thorvald",
		"Deep forest supplies — lanterns, rope, antidotes. You'll need them.", 24.0],
	[Vector2(3584, 4960), "tutor",      "Runa the Herbalist",
		"The ironwood holds rare plants. Pick mushrooms and moonbloom.", 32.0],
	# ── Eastmark Post ────────────────────────────────────────────────────────────
	[Vector2(5888, 5760), "quest",      "Scout Halfdan",
		"Strange creatures roam the ashlands. Investigate and report back.", 32.0],
	[Vector2(5760, 5760), "worker",     "Vigdis", "", 48.0],
	[Vector2(6016, 5760), "worker",     "Olaf",   "", 64.0],
	[Vector2(5952, 5984), "banker",     "Outpost Treasurer Hrodgar",
		"We keep a small vault here for travellers passing through the ashlands.", 16.0],
	[Vector2(5856, 5888), "shopkeeper", "Wandering Merchant Freyja",
		"Fire resistance potions are my specialty.", 20.0],
	# ── Bjorn's Landing ──────────────────────────────────────────────────────────
	[Vector2(7840, 4400), "quest",      "Merchant Eydis",
		"Bring me rare fish from the eastern waters and I will reward you generously.", 32.0],
	[Vector2(7712, 4448), "worker",     "Sturla",   "", 64.0],
	[Vector2(7968, 4416), "worker",     "Hallgerd", "", 48.0],
	[Vector2(8000, 4352), "banker",     "Harbor Master Ingolf",
		"Everything of value that passes through this port, I account for.", 16.0],
	[Vector2(7808, 4480), "shopkeeper", "Fish Trader Knud",
		"The finest catch from these waters.", 24.0],
	# Sea Captain Valdis — Jarl of Bjorn's Landing in the lore. Quest-giver
	# type so the `!` / `+` markers render on her for the Token + Pledge
	# chain. Her dialogue/shop functions still work via name lookup.
	[Vector2(7936, 4256), "quest",      "Sea Captain Valdis",
		"The ocean depths hold monsters unlike any you've seen on land.", 32.0],
	# ── Wilderness outposts ──────────────────────────────────────────────────────
	[Vector2(2080, 1600), "worker", "Mountain Pass Guard Bjork",
		"Turn back, traveller. The peaks ahead are treacherous.", 48.0],
	# Skade's hermitage — central plains, the empty zone in the world map.
	# Quest-load-bearing for q_old_bjarnes_letter and q_token_heart.
	[Vector2(4800, 4800), "worker", "Ironwood Hermit Skade",
		"I have walked between the burning ones for forty years. Sit. Speak only what you must.", 32.0],
	[Vector2(6400, 4200), "worker", "Coastal Scout Hafi",
		"The eastern road is clear — for now. Keep your sword ready.", 64.0],
]

## Níðhöggr boss spawns — static positions in helheim
const _BOSS_SPAWNS: Array = [
	[Vector2(1792, 6656), "nidhogg"],
	[Vector2(2560, 6912), "nidhogg"],
	[Vector2(1344, 7168), "nidhogg"],
	[Vector2(3072, 6784), "nidhogg"],
	[Vector2(2048, 7424), "nidhogg"],
	[Vector2(2816, 7680), "nidhogg"],
	[Vector2(1600, 7296), "nidhogg"],
	[Vector2(3456, 7168), "nidhogg"],
	[Vector2(2304, 6528), "nidhogg"],
]

# ── Chunk streaming state ─────────────────────────────────────────────────────
var _active_chunks: Dictionary = {}   # Vector2i → Array of Node
var _player:        Node2D     = null
var _last_chunk:    Vector2i   = Vector2i(-9999, -9999)
var _world_ready:   bool       = false
var _chunk_timer:   float      = 0.0

# Server-authoritative world state: maps a stable entity_id → live node.
var _node_registry:    Dictionary = {}   # resource nodes (Interactable)
var _monster_registry: Dictionary = {}   # monsters
var _admin_registry:   Dictionary = {}   # admin-placed entities (id → node)
# Stage 2 server-side AI — per-monster in-flight position tween. Stored so
# the next position update (every ~0.5s) can `.kill()` the previous tween
# before starting a fresh one, instead of stacking parallel tweens that
# would race for the same property.
var _monster_pos_tweens: Dictionary = {}   # monster_id (String) → Tween

# Phase 5 of the gold economy — server-broadcast gold pile world nodes,
# keyed by pile_id so a `gold_pile_remove` from the server can find and
# free the visual without a scan.
var _gold_pile_nodes: Dictionary = {}     # pile_id (String) → LootDrop Area2D
# Admin edits to pre-existing entities, loaded from the server on login.
var _deleted_ids: Dictionary = {}        # edit_id → true (don't spawn / despawn)
var _moved:       Dictionary = {}         # edit_id → Vector2 (override spawn pos)

func _ready() -> void:
	_player = get_node_or_null("Player") as Node2D
	_create_border_walls()
	_setup_camera_limits()
	Events.player_respawned.connect(_on_player_respawned)
	# Server-driven resource-node state (shared world)
	Events.gather_granted.connect(_on_gather_granted)
	Events.gather_denied.connect(_on_gather_denied)
	Events.node_remote_locked.connect(_on_node_remote_locked)
	Events.node_remote_unlocked.connect(_on_node_remote_unlocked)
	Events.node_remote_depleted.connect(_on_node_remote_depleted)
	Events.node_remote_respawned.connect(_on_node_remote_respawned)
	Events.node_states_received.connect(_on_node_states_received)
	# Server-driven monster state (shared combat)
	Events.mob_state.connect(_on_mob_state)
	Events.mob_hit.connect(_on_mob_hit)
	Events.mob_died.connect(_on_mob_died)
	Events.mob_respawned.connect(_on_mob_respawned)
	Events.mob_states_received.connect(_on_mob_states_received)
	# Stage 2 server-side AI — batched monster position updates every 0.5s.
	Events.mob_positions_updated.connect(_on_mob_positions_updated)
	# Phase 5 — server-tracked gold piles broadcast on monster death + claim.
	Events.gold_pile_spawn.connect(_on_gold_pile_spawn)
	Events.gold_pile_remove.connect(_on_gold_pile_remove)
	# Admin-placed persistent entities (shared world)
	Events.world_entities_received.connect(_on_world_entities_received)
	Events.world_entity_added.connect(_spawn_admin_entity)
	Events.world_entity_removed.connect(_on_world_entity_removed)
	Events.world_entity_moved.connect(_on_world_entity_moved)
	# Admin-painted persistent terrain overrides
	Events.tile_overrides_received.connect(_on_tile_overrides_received)
	Events.tile_override_set.connect(_on_tile_override_set)
	Events.tile_override_cleared.connect(_on_tile_override_cleared)
	# Admin edits (delete/move) to pre-existing entities
	Events.entity_edits_received.connect(_on_entity_edits_received)
	Events.entity_edit_applied.connect(_on_entity_edit_applied)
	# The admin toolbox is created on login (world.tscn loads before login, so
	# my_username is still empty here). Handles re-login too via the signal.
	NetworkManager.login_ok.connect(_on_login_spawn_admin)
	NetworkManager.admin_rank_changed.connect(_on_admin_rank_changed)
	_spawn_admin_panel_if_admin()
	# Deferred so Ground._ready() and Player._ready() finish first
	Events.player_respawned.emit.call_deferred(GameManager.RESPAWN_POS)

# ── Admin toolbox ──────────────────────────────────────────────────────────────
var _admin_panel: Node = null

func _on_login_spawn_admin(_player_data: Dictionary) -> void:
	_spawn_admin_panel_if_admin()

func _on_admin_rank_changed(rank: String) -> void:
	# Promoted mid-session — spawn the panel right now. Demoted mid-session
	# — tear it down so the now-non-admin can't keep pressing F10.
	if rank == "":
		if _admin_panel != null and is_instance_valid(_admin_panel):
			_admin_panel.queue_free()
			_admin_panel = null
	else:
		_spawn_admin_panel_if_admin()

func _spawn_admin_panel_if_admin() -> void:
	if _admin_panel != null and is_instance_valid(_admin_panel):
		return
	# Multi-admin: any rank ('admin' or 'owner') gets the F10 panel. The
	# server is the source of truth for the rank value, set on login_ok.
	if NetworkManager.my_admin_rank == "":
		return
	_admin_panel = (load("res://scripts/ui/AdminPanel.gd") as GDScript).new() as Node
	add_child(_admin_panel)
	Events.chat_message.emit("[Admin] Tools loaded — press F10 or click the ⚙ ADMIN button (top-left).")

func _on_tile_overrides_received(overrides: Array) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("apply_tile_overrides", overrides)

func _on_tile_override_set(tx: int, ty: int, biome: String) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("set_tile_override", tx, ty, biome)

func _on_tile_override_cleared(tx: int, ty: int) -> void:
	var g := get_node_or_null("Ground")
	if g != null:
		g.call("clear_tile_override", tx, ty)

# ── Admin-placed entities ──────────────────────────────────────────────────────
func _on_world_entities_received(entities: Array) -> void:
	# Clear any existing admin entities, then (re)spawn the authoritative set.
	for id: Variant in _admin_registry.keys():
		_remove_admin_node(str(id))
	if _world_ready:
		for e: Variant in entities:
			if e is Dictionary:
				_spawn_admin_entity(e as Dictionary)

func _spawn_admin_entities_from_cache() -> void:
	for e: Variant in NetworkManager.world_entities_cache:
		if e is Dictionary:
			_spawn_admin_entity(e as Dictionary)

func _arr_to_color(raw: Variant) -> Color:
	if raw is Array and (raw as Array).size() >= 3:
		var a: Array = raw as Array
		return Color(float(a[0]), float(a[1]), float(a[2]),
					 float(a[3]) if a.size() > 3 else 1.0)
	return Color(0.7, 0.7, 0.7)

func _spawn_admin_entity(entity: Dictionary) -> void:
	var id := str(entity.get("id", ""))
	if id.is_empty() or _admin_registry.has(id):
		return
	var kind := str(entity.get("kind", ""))
	var data: Dictionary = (entity.get("data", {}) as Dictionary) if entity.get("data") is Dictionary else {}
	var pos := Vector2(float(entity.get("x", 0.0)), float(entity.get("y", 0.0)))
	var c := $Interactables
	match kind:
		"resource":
			var node: Node2D = _Interactable.instantiate()
			node.position              = pos
			node.interactable_type_str = str(data.get("type_str", "tree"))
			node.display_name          = str(data.get("display_name", "Resource"))
			node.required_skill        = str(data.get("skill", "woodcutting"))
			node.required_level        = int(data.get("level", 1))
			node.action_label          = str(data.get("action", "Interact"))
			node.color                 = _arr_to_color(data.get("color"))
			node.entity_id             = id
			_node_registry[id]  = node
			_admin_registry[id] = node
			c.add_child(node)
		"monster":
			var m := Area2D.new()
			m.set_script(_Monster)
			m.position     = pos
			m.monster_type = str(data.get("monster_type", "rat"))
			m.entity_id    = id
			_monster_registry[id] = m
			_admin_registry[id]   = m
			c.add_child(m)
			var lv := int(data.get("level", 0))
			if lv > 0:
				m.call("scale_to_level", lv)
			# Stage 1 server AI seed. Live admin-place runs through the
			# server's `_handle_admin_place` and seeds AI synchronously,
			# but DB-loaded entries arrive via the login burst with no
			# server-side AI registered — this join is what restores it.
			# Server is idempotent (existing entry → AI fields preserved).
			NetworkManager.send_monster_join(id, pos.x, pos.y,
				int(m.get("max_hp")), int(m.get("xp_reward")),
				str(m.get("monster_type")), int(m.get("level")),
				int(m.get("attack")))
		"npc":
			var n := Area2D.new()
			n.set_script(_NPC)
			n.position      = pos
			n.npc_type      = str(data.get("npc_type", "worker"))
			n.npc_name_str  = str(data.get("npc_name", "Villager"))
			n.quest_text    = str(data.get("quest_text", ""))
			n.wander_radius = float(data.get("wander_radius", 32.0))
			# Phase 4 — shopkeeper NPCs carry their shop_id in data so the
			# click dispatcher in NPC._on_player_interacted knows which
			# ShopCatalog template to open. Empty string for non-shopkeepers.
			n.shop_id       = str(data.get("shop_id", ""))
			_admin_registry[id] = n
			c.add_child(n)
		"farm_plot":
			var fp := Area2D.new()
			fp.set_script(_FarmPlot)
			fp.position = pos
			fp.set("entity_id", id)
			_admin_registry[id] = fp
			c.add_child(fp)
		"stronghold", "banner", "outpost":
			# Warband structures spawn as Interactable nodes with a custom
			# type_str so they reuse all the depth-pass, hover, and
			# collision plumbing. No gather logic — they're decorative for
			# v1 (clicking later opens a warband info popup).
			var ws_node: Node2D = _Interactable.instantiate()
			ws_node.position              = pos
			ws_node.interactable_type_str = kind
			ws_node.display_name          = "Warband %s" % kind.capitalize()
			ws_node.required_skill        = ""
			ws_node.required_level        = 1
			ws_node.action_label          = "Inspect"
			# Owner warband_id stored in entity meta so click-handlers can
			# look up which warband this belongs to.
			ws_node.color                 = Color(0.55, 0.30, 0.18)
			ws_node.entity_id             = id
			ws_node.set_meta("warband_id", str(data.get("warband_id", "")))
			_admin_registry[id] = ws_node
			c.add_child(ws_node)
	# Tag so the editor's unified click-search finds admin entities too (their
	# a: id routes back to the admin placement handlers on delete/move).
	if _admin_registry.has(id):
		(_admin_registry[id] as Node).set_meta("edit_id", id)

func _remove_admin_node(id: String) -> void:
	var node: Variant = _admin_registry.get(id)
	if node != null and is_instance_valid(node as Node):
		(node as Node).queue_free()
	_admin_registry.erase(id)
	_node_registry.erase(id)
	_monster_registry.erase(id)

## Nearest editable entity id within `radius` px of a world position, or "".
## Searches ALL tagged entities (admin-placed + procedural + town/NPC/boss), so
## the editor can delete/move anything. Returns the entity's stable edit id.
func admin_entity_at(world_pos: Vector2, radius: float = 44.0) -> String:
	var best := ""
	var best_d := radius * radius
	for grp: String in ["interactable", "monster"]:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if not n.has_meta("edit_id"):
				continue
			var d := (n as Node2D).global_position.distance_squared_to(world_pos)
			if d < best_d:
				best_d = d
				best = str(n.get_meta("edit_id"))
	return best

# ── Edit-persistence for pre-existing entities ────────────────────────────────
## Tag a freshly-built entity with its stable id and apply any saved edit.
## Returns false if the entity is deleted (caller must NOT add it to the tree).
func _register_editable(node: Node2D, id: String) -> bool:
	if _deleted_ids.has(id):
		return false
	node.set_meta("edit_id", id)
	if _moved.has(id):
		node.position = _moved[id] as Vector2
	return true

func _find_editable_node(id: String) -> Node2D:
	for grp: String in ["interactable", "monster"]:
		for n: Node in get_tree().get_nodes_in_group(grp):
			if n.has_meta("edit_id") and str(n.get_meta("edit_id")) == id:
				return n as Node2D
	return null

func _on_entity_edits_received(edits: Array) -> void:
	_deleted_ids.clear()
	_moved.clear()
	for e: Variant in edits:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		var id := str(d.get("id", ""))
		if id.is_empty():
			continue
		if bool(d.get("deleted", false)):
			_deleted_ids[id] = true
		elif d.get("x") != null and d.get("y") != null:
			_moved[id] = Vector2(float(d["x"]), float(d["y"]))
	# Apply to anything already spawned (towns/NPCs/bosses, loaded chunks).
	for id: Variant in _deleted_ids.keys():
		var dn := _find_editable_node(str(id))
		if dn != null:
			dn.queue_free()
	for id: Variant in _moved.keys():
		var mn := _find_editable_node(str(id))
		if mn != null:
			mn.global_position = _moved[id] as Vector2

func _on_entity_edit_applied(entity_id: String, deleted: bool, x: float, y: float) -> void:
	if deleted:
		_deleted_ids[entity_id] = true
		_moved.erase(entity_id)
		var n := _find_editable_node(entity_id)
		if n != null:
			n.queue_free()
	else:
		_moved[entity_id] = Vector2(x, y)
		_deleted_ids.erase(entity_id)
		var n := _find_editable_node(entity_id)
		if n != null:
			n.global_position = Vector2(x, y)

func _on_world_entity_removed(entity_id: String) -> void:
	_remove_admin_node(entity_id)

func _on_world_entity_moved(entity_id: String, x: float, y: float) -> void:
	var node: Variant = _admin_registry.get(entity_id)
	if node != null and is_instance_valid(node as Node):
		(node as Node2D).global_position = Vector2(x, y)

# ── Server combat dispatch (route by entity_id to the live monster) ────────────
func _reg_mob(entity_id: String):
	var m: Variant = _monster_registry.get(entity_id)
	if m != null and is_instance_valid(m as Node):
		return m
	return null

func _on_mob_state(entity_id: String, hp: int, max_hp: int) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null: m.call("set_server_hp", hp, max_hp)

func _on_mob_hit(entity_id: String, _x: float, _y: float, _amount: int, _by: String, hp: int, max_hp: int) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null:
		m.call("set_server_hp", hp, max_hp)
		m.call("flash_hit")

func _on_mob_died(entity_id: String, killer: String, xp_each: int,
		_participants: Array, xp_recipients: Array) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m == null:
		return
	var me := NetworkManager.my_username
	# Eligibility now lives in xp_recipients (damagers + warband-shared),
	# NOT in participants. Chunk-streamers who joined for visibility but
	# never dealt damage are intentionally excluded from this list.
	if me in xp_recipients and xp_each > 0:
		# Kill reward, split evenly by the server, mirrors the local _award_combat_xp split.
		GameManager.add_xp("melee", xp_each)
		GameManager.add_xp("defense", maxi(1, floori(xp_each * 0.3)))
		GameManager.add_xp("vitality", maxi(1, floori(xp_each * 0.3)))
		Events.monster_killed.emit(str(m.get("monster_type")))
		GameManager.on_monster_killed(str(m.get("monster_type")))
	if me == killer:
		m.call("spawn_loot_drops")
	m.call("server_die")

func _on_mob_respawned(entity_id: String) -> void:
	var m: Variant = _reg_mob(entity_id)
	if m != null: m.call("server_respawn")

func _on_mob_states_received(nodes: Array) -> void:
	for entry: Variant in nodes:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry as Dictionary
		var m: Variant = _reg_mob(str(d.get("id", "")))
		if m == null:
			continue
		if bool(d.get("alive", true)):
			m.call("set_server_hp", int(d.get("hp", 1)), int(d.get("max_hp", 1)))
		else:
			m.call("server_die")

## Stage 2 server-side AI — batched position broadcast. The server fires this
## every 0.5s with one entry per nearby alive monster; we tween each Monster
## node's global_position toward the new server-authoritative coords over
## 0.45s (50ms of curve margin to the next tick so motion never pauses). A
## per-monster tween is killed before a new one starts so updates don't stack.
## Also stamps `server_state` / `server_target` metadata on the node so the
## sprite layer can later read aggro / target without re-listening.
func _on_mob_positions_updated(updates: Array) -> void:
	for u: Variant in updates:
		if not (u is Dictionary):
			continue
		var d: Dictionary = u as Dictionary
		var mid := str(d.get("id", ""))
		if mid.is_empty():
			continue
		var node: Variant = _monster_registry.get(mid)
		if node == null or not is_instance_valid(node as Node):
			continue
		var n: Node2D = node as Node2D
		# Kill any in-flight tween for this monster before starting a new
		# one — otherwise the previous tween keeps writing global_position
		# in parallel and the motion jitters.
		var prev: Variant = _monster_pos_tweens.get(mid)
		if prev != null:
			var prev_tw := prev as Tween
			if prev_tw != null and prev_tw.is_valid():
				prev_tw.kill()
		var target := Vector2(float(d.get("x", n.global_position.x)),
							  float(d.get("y", n.global_position.y)))
		var tween := create_tween()
		tween.tween_property(n, "global_position", target, 0.45)
		_monster_pos_tweens[mid] = tween
		# Stamp server-side AI state on the node for later visual hooks
		# (Stage 3+ will tint the sprite or show aggro indicators using
		# these). Strings come straight from server: "idle" / "wander" /
		# "aggro" for state, username or "" for target.
		n.set_meta("server_state", str(d.get("state", "")))
		n.set_meta("server_target", str(d.get("target", "")))

# ── Gold piles (Phase 5 of the gold economy) ─────────────────────────────────
# Server broadcasts gold_pile_spawn on monster death; we instantiate a
# shared LootDrop visual via the existing LootDrop.gd script (mirrors the
# Monster._spawn_loot pattern). The pile_id is what links the visual to the
# server's authoritative state — clicking sends gold_pile_pickup, server
# validates proximity + claims, broadcasts gold_pile_remove to despawn.

func _on_gold_pile_spawn(pile_id: String, x: float, y: float, amount: int) -> void:
	if pile_id == "" or amount <= 0:
		return
	# Defensive: if a stale local node still exists under this id, free it
	# first so we don't leak duplicates after a race.
	if _gold_pile_nodes.has(pile_id):
		var old: Variant = _gold_pile_nodes[pile_id]
		if old != null and is_instance_valid(old as Node):
			(old as Node).queue_free()
		_gold_pile_nodes.erase(pile_id)
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = Vector2(x, y)
	$Interactables.add_child(ld)
	(ld as Area2D).call("setup_gold_pile", pile_id, amount)
	_gold_pile_nodes[pile_id] = ld

func _on_gold_pile_remove(pile_id: String) -> void:
	if not _gold_pile_nodes.has(pile_id):
		return
	var node: Variant = _gold_pile_nodes[pile_id]
	if node != null and is_instance_valid(node as Node):
		(node as Node).queue_free()
	_gold_pile_nodes.erase(pile_id)

# ── Server world-state dispatch (route by entity_id to the live node) ──────────
func _reg_node(entity_id: String):
	var n: Variant = _node_registry.get(entity_id)
	if n != null and is_instance_valid(n as Node):
		return n
	return null

func _on_gather_granted(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("begin_gather")

func _on_gather_denied(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("on_gather_busy")

func _on_node_remote_locked(entity_id: String, username: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("set_remote_gathering", true, username)

func _on_node_remote_unlocked(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("set_remote_gathering", false, "")

func _on_node_remote_depleted(entity_id: String, respawn_in: float) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("apply_depleted", respawn_in)

func _on_node_remote_respawned(entity_id: String) -> void:
	var n: Variant = _reg_node(entity_id)
	if n != null: n.call("apply_respawn")

func _on_node_states_received(nodes: Array) -> void:
	for entry: Variant in nodes:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry as Dictionary
		var n: Variant = _reg_node(str(d.get("id", "")))
		if n == null:
			continue
		var depleted_in := float(d.get("depleted_in", 0.0))
		var locked_by   := str(d.get("locked_by", ""))
		if depleted_in > 0.0:
			n.call("apply_depleted", depleted_in)
		elif not locked_by.is_empty():
			n.call("set_remote_gathering", true, locked_by)

func _process(delta: float) -> void:
	if not _world_ready or _player == null:
		return
	_chunk_timer -= delta
	if _chunk_timer > 0.0:
		return
	_chunk_timer = 0.5
	_update_chunks(_player.global_position)

# Called when player spawns or respawns
func _on_player_respawned(pos: Vector2) -> void:
	if not _world_ready:
		_world_ready = true
		_spawn_interactables()
		_spawn_npcs()
		_spawn_bosses()
		_spawn_admin_entities_from_cache()
	_update_chunks(pos)

# ── Chunk management ──────────────────────────────────────────────────────────
func _update_chunks(player_pos: Vector2) -> void:
	var pcx := floori(player_pos.x / float(CHUNK_PX))
	var pcy := floori(player_pos.y / float(CHUNK_PX))
	var center := Vector2i(pcx, pcy)
	if center == _last_chunk:
		return
	_last_chunk = center

	var max_cx := ceili(float(COLS * TILE) / float(CHUNK_PX))
	var max_cy := ceili(float(ROWS * TILE) / float(CHUNK_PX))

	# Build desired set
	var desired: Dictionary = {}
	for dx in range(-ACTIVE_RADIUS, ACTIVE_RADIUS + 1):
		for dy in range(-ACTIVE_RADIUS, ACTIVE_RADIUS + 1):
			var cx := pcx + dx
			var cy := pcy + dy
			if cx < 0 or cy < 0 or cx >= max_cx or cy >= max_cy:
				continue
			desired[Vector2i(cx, cy)] = true

	# Collect chunks to unload (don't modify dict during iteration)
	var to_unload: Array = []
	for key: Variant in _active_chunks.keys():
		if not desired.has(key):
			to_unload.append(key)
	for key: Variant in to_unload:
		_unload_chunk(key as Vector2i)

	# Load chunks not yet active
	for key: Variant in desired.keys():
		if not _active_chunks.has(key):
			_load_chunk((key as Vector2i).x, (key as Vector2i).y)

func _load_chunk(cx: int, cy: int) -> void:
	var key    := Vector2i(cx, cy)
	var nodes: Array = []
	_spawn_chunk_resources(cx, cy, nodes)
	_spawn_chunk_monsters(cx, cy, nodes)
	_active_chunks[key] = nodes
	# Ask the server for the current shared state of this chunk's entities.
	var node_ids: Array = []
	var mob_ids:  Array = []
	for node: Variant in nodes:
		var obj := node as Object
		if obj.has_method("begin_gather"):
			node_ids.append(str((node as Node).get("entity_id")))
		elif obj.has_method("set_server_hp"):
			mob_ids.append(str((node as Node).get("entity_id")))
	if not node_ids.is_empty():
		NetworkManager.send_node_states(node_ids)
	if not mob_ids.is_empty():
		NetworkManager.send_monster_states(mob_ids)

func _unload_chunk(key: Vector2i) -> void:
	if not _active_chunks.has(key):
		return
	for node: Variant in _active_chunks[key]:
		# Defensive: entities can be removed from another path while their Node
		# ref still sits in this chunk's list — e.g. admin delete or a server
		# entity_remove broadcast that calls queue_free() before this chunk
		# unloads. Casting a freed-object Variant throws, so check validity
		# (which accepts freed refs and returns false) before any `as` cast.
		if not is_instance_valid(node):
			continue
		var n: Node = node as Node
		if n == null:
			continue
		if n.has_method("begin_gather"):
			_node_registry.erase(str(n.get("entity_id")))
		elif n.has_method("set_server_hp"):
			_monster_registry.erase(str(n.get("entity_id")))
		n.queue_free()
	_active_chunks.erase(key)

# ── Procedural chunk content ──────────────────────────────────────────────────
func _spawn_chunk_resources(cx: int, cy: int, out: Array) -> void:
	var ground := get_node_or_null("Ground")
	var c      := $Interactables
	var rng    := RandomNumberGenerator.new()
	rng.seed   = (cx * 7919 + cy * 6271) ^ 0xA3C5F1
	var ox     := float(cx * CHUNK_PX)
	var oy     := float(cy * CHUNK_PX)
	for _i in range(RES_ATTEMPTS):
		var pos := Vector2(
			clampf(ox + rng.randf() * CHUNK_PX, 64, COLS * TILE - 64),
			clampf(oy + rng.randf() * CHUNK_PX, 64, ROWS * TILE - 64))
		var biome: String = ""
		if ground != null:
			biome = ground.call("biome_at_world", pos)
		var d := _resource_data(biome, pos, rng, ground)
		if d.size() == 0:
			continue
		var node: Node2D = _Interactable.instantiate()
		node.position              = pos
		node.interactable_type_str = d[0]
		node.display_name          = d[1]
		node.required_skill        = d[2]
		node.required_level        = d[3]
		node.action_label          = d[4]
		node.color                 = d[5]
		# Stable, deterministic id (chunk + spawn attempt). Both clients and the
		# server derive the same id without communication, so server-owned state
		# (locks / depletion / respawn) maps 1:1 to each client's node.
		node.entity_id = "r:%d:%d:%d" % [cx, cy, _i]
		if not _register_editable(node, node.entity_id):
			node.queue_free()
			continue
		_node_registry[node.entity_id] = node
		c.add_child(node)
		out.append(node)

func _spawn_chunk_monsters(cx: int, cy: int, out: Array) -> void:
	var ground := get_node_or_null("Ground")
	var c      := $Interactables
	var rng    := RandomNumberGenerator.new()
	rng.seed   = (cx * 9901 + cy * 8317) ^ 0x7F3A9B
	var ox     := float(cx * CHUNK_PX)
	var oy     := float(cy * CHUNK_PX)
	for _i in range(MON_ATTEMPTS):
		var pos := Vector2(
			clampf(ox + rng.randf() * CHUNK_PX, 64, COLS * TILE - 64),
			clampf(oy + rng.randf() * CHUNK_PX, 64, ROWS * TILE - 64))
		if _in_safe_zone(pos):
			continue
		var biome: String = ""
		if ground != null:
			biome = ground.call("biome_at_world", pos)
		var mtype := _monster_type(biome, pos, rng)
		if mtype.is_empty():
			continue
		var m := Area2D.new()
		m.set_script(_Monster)
		m.position     = pos
		m.monster_type = mtype
		m.entity_id    = "m:%d:%d:%d" % [cx, cy, _i]
		if not _register_editable(m, m.entity_id):
			m.queue_free()
			continue
		_monster_registry[m.entity_id] = m
		c.add_child(m)
		# Stage 1 server AI seed — every chunk monster needs to register
		# with the server so _monster_ai_loop sees it. _ready ran during
		# add_child, so max_hp / attack / level / xp_reward are set.
		# Server's _handle_monster_join is idempotent (existing-entry path
		# leaves AI fields alone), so duplicate calls from multiple
		# clients in the same chunk are safe.
		NetworkManager.send_monster_join(m.entity_id, m.position.x, m.position.y,
			int(m.get("max_hp")), int(m.get("xp_reward")),
			str(m.get("monster_type")), int(m.get("level")),
			int(m.get("attack")))
		out.append(m)
	# Bridge monster — spawn one per border chunk (30% chance)
	if ground != null and rng.randi() % 10 < 3:
		var center := Vector2(ox + CHUNK_PX * 0.5, oy + CHUNK_PX * 0.5)
		if not _in_safe_zone(center):
			var cb := ground.call("biome_at_world", center) as String
			var biome_set: Dictionary = {}
			biome_set[cb] = true
			for corner: Vector2 in [Vector2(0.1, 0.1), Vector2(0.9, 0.1),
									Vector2(0.1, 0.9), Vector2(0.9, 0.9)]:
				var bm := ground.call("biome_at_world",
					Vector2(ox + CHUNK_PX * corner.x, oy + CHUNK_PX * corner.y)) as String
				biome_set[bm] = true
			if biome_set.size() > 1:
				var bridge := _bridge_monster_for_biomes(biome_set, rng)
				if not bridge.is_empty():
					var bm2 := Area2D.new()
					bm2.set_script(_Monster)
					bm2.position     = center
					bm2.monster_type = bridge
					var lv_range := _BRIDGE_LEVEL_RANGE.get(bridge, [1, 1]) as Array
					var lv := (lv_range[0] as int) + rng.randi() % maxi(1, (lv_range[1] as int) - (lv_range[0] as int) + 1)
					bm2.entity_id    = "m:%d:%d:b" % [cx, cy]
					if not _register_editable(bm2, bm2.entity_id):
						bm2.queue_free()
					else:
						_monster_registry[bm2.entity_id] = bm2
						c.add_child(bm2)
						bm2.call("scale_to_level", lv)
						# Bridge monster also needs to register for AI —
						# call AFTER scale_to_level so the server sees the
						# scaled max_hp / attack, not the base type stats.
						NetworkManager.send_monster_join(bm2.entity_id,
							bm2.position.x, bm2.position.y,
							int(bm2.get("max_hp")), int(bm2.get("xp_reward")),
							str(bm2.get("monster_type")), int(bm2.get("level")),
							int(bm2.get("attack")))
						out.append(bm2)

# ── Static entity spawning (called once after first login) ───────────────────
func _spawn_interactables() -> void:
	var c := $Interactables
	for i in range(_TOWN_NODES.size()):
		var d: Array = _TOWN_NODES[i]
		var node: Node2D = _Interactable.instantiate()
		node.position              = d[0]
		node.interactable_type_str = d[1]
		node.display_name          = d[2]
		node.required_skill        = d[3]
		node.required_level        = d[4]
		node.action_label          = d[5]
		node.color                 = d[6]
		if not _register_editable(node, "t:%d" % i):
			node.queue_free()
			continue
		c.add_child(node)

func _spawn_npcs() -> void:
	var c := $Interactables
	for i in range(_NPCS.size()):
		var d: Array = _NPCS[i]
		var n := Area2D.new()
		n.set_script(_NPC)
		n.position      = d[0]
		n.npc_type      = d[1]
		n.npc_name_str  = d[2]
		n.quest_text    = d[3]
		n.wander_radius = d[4]
		if not _register_editable(n, "n:%d" % i):
			n.queue_free()
			continue
		c.add_child(n)

func _spawn_bosses() -> void:
	var c := $Interactables
	for i in range(_BOSS_SPAWNS.size()):
		var d: Array = _BOSS_SPAWNS[i]
		var m := Area2D.new()
		m.set_script(_Monster)
		m.position     = d[0]
		m.monster_type = d[1]
		if not _register_editable(m, "b:%d" % i):
			m.queue_free()
			continue
		c.add_child(m)

# ── Helpers ───────────────────────────────────────────────────────────────────
func _in_safe_zone(pos: Vector2) -> bool:
	for z: Variant in _SAFE_ZONES:
		if (z as Rect2).has_point(pos):
			return true
	return false

# Returns [type, name, skill, req_level, action, color] or []
func _is_shoreline(pos: Vector2, ground: Node) -> bool:
	if ground == null:
		return false
	for off: Vector2 in [Vector2(32, 0), Vector2(-32, 0), Vector2(0, 32), Vector2(0, -32)]:
		var nb: String = ground.call("biome_at_world", pos + off) as String
		if nb != "coast" and nb != "ocean":
			return true
	return false

func _resource_data(biome: String, pos: Vector2, rng: RandomNumberGenerator, ground: Node) -> Array:
	var r := rng.randi() % 10
	match biome:
		"plains":
			if r < 4: return ["herb",  "Herb Patch", "foraging", 1, "Pick", Color(0.62, 0.82, 0.20)]
			if r < 7: return ["stick", "Stick",       "foraging", 1, "Pick", Color(0.55, 0.36, 0.14)]
			if r < 9: return ["stone", "Stone",       "foraging", 1, "Pick", Color(0.58, 0.56, 0.52)]
		"oak_forest":
			if r < 4: return ["tree",  "Oak Tree",  "woodcutting",  1, "Chop", Color(0.18, 0.55, 0.15)]
			if r < 6: return ["herb",  "Wild Bush", "foraging",     1, "Pick", Color(0.72, 0.22, 0.52)]
			if r < 7: return ["stone", "Stone",     "foraging",     1, "Pick", Color(0.58, 0.56, 0.52)]
			if r < 9: return ["stick", "Stick",     "foraging",     1, "Pick", Color(0.55, 0.36, 0.14)]
		"pine_forest":
			if r < 5: return ["tree", "Pine Tree",      "woodcutting",  5, "Chop", Color(0.10, 0.42, 0.20)]
			if r < 7: return ["herb", "Mushroom Patch", "foraging",    10, "Pick", Color(0.72, 0.55, 0.38)]
			if r < 8: return ["stone","Stone",           "foraging",     1, "Pick", Color(0.58, 0.56, 0.52)]
			if r < 9: return ["stick","Stick",           "foraging",     1, "Pick", Color(0.55, 0.36, 0.14)]
		"dark_forest":
			if r < 3: return ["tree", "Cherry Tree",     "woodcutting", 20, "Chop", Color(0.98, 0.72, 0.80)]
			if r < 5: return ["herb", "Mushroom Patch",  "foraging",    10, "Pick", Color(0.72, 0.55, 0.38)]
			if r < 8: return ["herb", "Moonbloom Patch", "foraging",    40, "Pick", Color(0.78, 0.62, 0.95)]
		"swamp":
			if r < 3: return ["herb", "Mushroom Patch",  "foraging", 10, "Pick", Color(0.72, 0.55, 0.38)]
			if r < 6: return ["herb", "Moonbloom Patch", "foraging", 40, "Pick", Color(0.78, 0.62, 0.95)]
			if r < 8: return ["herb", "Ancient Root",    "foraging", 60, "Dig",  Color(0.42, 0.28, 0.12)]
		"mountain":
			if r >= 7: return []
			var ty := floori(pos.y / float(TILE))
			if ty < 30:
				if r < 2: return ["rock", "Runite Rock",  "mining", 85, "Mine", Color(0.65, 0.20, 0.82)]
				if r < 5: return ["rock", "Adamant Rock", "mining", 70, "Mine", Color(0.20, 0.65, 0.30)]
				return         ["rock", "Mithril Rock", "mining", 50, "Mine", Color(0.40, 0.65, 0.90)]
			elif ty < 70:
				if r < 2: return ["rock", "Adamant Rock", "mining", 70, "Mine", Color(0.20, 0.65, 0.30)]
				if r < 4: return ["rock", "Mithril Rock", "mining", 50, "Mine", Color(0.40, 0.65, 0.90)]
				if r < 6: return ["rock", "Gold Vein",    "mining", 40, "Mine", Color(0.88, 0.72, 0.12)]
				return         ["rock", "Iron Rock",    "mining", 15, "Mine", Color(0.55, 0.55, 0.60)]
			else:
				if r < 4: return ["rock", "Iron Rock",   "mining", 15, "Mine", Color(0.55, 0.55, 0.60)]
				return         ["rock", "Copper Rock", "mining",  1, "Mine", Color(0.72, 0.42, 0.22)]
		"rocky":
			if r < 3: return ["rock", "Copper Rock", "mining",  1, "Mine", Color(0.72, 0.42, 0.22)]
			if r < 6: return ["rock", "Iron Rock",   "mining", 15, "Mine", Color(0.55, 0.55, 0.60)]
			if r < 9: return ["rock", "Gold Vein",   "mining", 30, "Mine", Color(0.88, 0.72, 0.12)]
		"coast":
			# Only at the land-water edge so players can fish from shore
			if not _is_shoreline(pos, ground):
				return []
			var tx := floori(pos.x / float(TILE))
			if tx > 270:
				if r < 4: return ["fish", "Abyssal Depth", "fishing", 80, "Fish", Color(0.28, 0.45, 0.35)]
				if r < 7: return ["fish", "Shark Waters",  "fishing", 60, "Fish", Color(0.55, 0.58, 0.62)]
				return         ["fish", "Lobster Pot",   "fishing", 40, "Fish", Color(0.90, 0.30, 0.20)]
			elif tx > 255:
				if r < 3: return ["fish", "Shark Waters",  "fishing", 60, "Fish", Color(0.55, 0.58, 0.62)]
				if r < 6: return ["fish", "Lobster Pot",   "fishing", 40, "Fish", Color(0.90, 0.30, 0.20)]
				if r < 9: return ["fish", "Salmon Spot",   "fishing", 20, "Fish", Color(0.95, 0.55, 0.30)]
			else:
				if r < 5: return ["fish", "Fishing Spot", "fishing",  1, "Fish", Color(0.18, 0.52, 0.82)]
				if r < 8: return ["fish", "Salmon Spot",  "fishing", 20, "Fish", Color(0.95, 0.55, 0.30)]
		"ocean":
			pass  # no fishing in open ocean — players cannot reach it
		"snow":
			if r < 3: return ["tree", "Frost Tree",   "woodcutting", 50, "Chop", Color(0.72, 0.90, 0.98)]
			if r < 5: return ["rock", "Mithril Rock", "mining",      50, "Mine", Color(0.40, 0.65, 0.90)]
			if r < 7: return ["rock", "Adamant Rock", "mining",      70, "Mine", Color(0.20, 0.65, 0.30)]
			if r < 9: return ["rock", "Runite Rock",  "mining",      85, "Mine", Color(0.65, 0.20, 0.82)]
		"helheim":
			if r < 3: return ["tree", "Ancient Tree", "woodcutting", 70, "Chop", Color(0.35, 0.20, 0.08)]
			if r < 6: return ["herb", "Ancient Root", "foraging",    60, "Dig",  Color(0.42, 0.28, 0.12)]
			if r < 8: return ["rock", "Runite Rock",  "mining",      85, "Mine", Color(0.65, 0.20, 0.82)]
		"ashlands":
			if r < 3: return ["herb", "Ancient Root",    "foraging", 60, "Dig",  Color(0.42, 0.28, 0.12)]
			if r < 5: return ["rock", "Adamant Rock",    "mining",   70, "Mine", Color(0.20, 0.65, 0.30)]
			if r < 7: return ["rock", "Runite Rock",     "mining",   85, "Mine", Color(0.65, 0.20, 0.82)]
			if r < 9: return ["herb", "Moonbloom Patch", "foraging", 40, "Pick", Color(0.78, 0.62, 0.95)]
	return []

const _BRIDGE_LEVEL_RANGE: Dictionary = {
	"dire_wolf":       [12, 18],
	"elder_bear":      [26, 32],
	"ancient_troll":   [40, 48],
	"frost_wyrm":      [58, 67],
	"magma_elemental": [72, 80],
}

func _bridge_monster_for_biomes(biome_set: Dictionary, _rng: RandomNumberGenerator) -> String:
	var has_plains   := biome_set.has("plains")
	var has_forest   := biome_set.has("pine_forest") or biome_set.has("oak_forest")
	var has_dark     := biome_set.has("dark_forest") or biome_set.has("swamp")
	var has_mountain := biome_set.has("mountain") or biome_set.has("rocky")
	var has_snow     := biome_set.has("snow")
	var has_ash      := biome_set.has("ashlands")
	var has_helheim  := biome_set.has("helheim")
	if has_plains and has_forest:   return "dire_wolf"
	if has_forest and has_dark:     return "elder_bear"
	if has_mountain and has_forest: return "ancient_troll"
	if has_snow and has_mountain:   return "frost_wyrm"
	if has_ash and has_helheim:     return "magma_elemental"
	return ""

func _monster_type(biome: String, pos: Vector2, rng: RandomNumberGenerator) -> String:
	if rng.randi() % 10 >= 4:
		return ""
	var r := rng.randi() % 4
	match biome:
		"plains":
			# Distance to the starter town (Bjorn's Landing). Within 20 tiles
			# new players see the easy mobs; weak-to-strong gradient outward.
			var dist := floori(pos.distance_to(Vector2(7823, 4488)) / float(TILE))
			if dist < 20:
				if r == 0 or r == 2: return "rat"
				if r == 1:           return "chicken"
			elif dist < 40:
				if r == 0: return "rat"
				if r == 1: return "wolf"
				if r == 2: return "goblin"
			elif dist < 70:
				if r == 0: return "wolf"
				if r == 1: return "goblin"
				if r == 2: return "bandit"
				return "skeleton"
			else:
				if r == 0: return "wolf"
				if r == 1: return "bandit"
				if r == 2: return "bear"
				return "skeleton"
		"oak_forest":
			if r == 0: return "goblin"
			if r == 1: return "wolf"
			if r == 2: return "bandit"
		"pine_forest":
			if r == 0: return "wolf"
			if r == 1: return "bandit"
			if r == 2: return "bear"
		"dark_forest":
			if r == 0: return "skeleton"
			if r == 1: return "spider"
			if r == 2: return "forest_spirit"
		"swamp":
			if r == 0: return "skeleton"
			if r == 1: return "spider"
			if r == 2: return "forest_spirit"
		"mountain":
			var ty := floori(pos.y / float(TILE))
			if ty < 25:
				if r == 0: return "frost_giant"
				if r == 1: return "ice_draugr"
			elif ty < 60:
				if r == 0: return "ice_wolf"
				if r == 1: return "frost_giant"
				if r == 2: return "troll"
			else:
				if r == 0: return "bear"
				if r == 1: return "troll"
				if r == 2: return "ice_wolf"
		"rocky":
			if r == 0: return "bandit"
			if r == 1: return "bear"
			if r == 2: return "troll"
		"coast":
			pass  # no land monsters on water tiles
		"snow":
			if r == 0: return "ice_wolf"
			if r == 1: return "frost_giant"
			if r == 2: return "ice_draugr"
		"helheim":
			if r == 0: return "death_knight"
			if r == 1: return "spectral_warrior"
			if r == 2: return "shadow_draugr"
		"ashlands":
			if r == 0: return "fire_imp"
			if r == 1: return "lava_crawler"
			if r == 2: return "fire_giant"
			return "shadow_draugr"
	return ""

func _create_border_walls() -> void:
	var w := float(COLS * TILE)
	var h := float(ROWS * TILE)
	var t := 64.0
	var borders: Array[Array] = [
		[Vector2(w * 0.5, -t * 0.5),      Vector2(w + t * 2.0, t)],
		[Vector2(w * 0.5, h + t * 0.5),   Vector2(w + t * 2.0, t)],
		[Vector2(-t * 0.5, h * 0.5),      Vector2(t, h)],
		[Vector2(w + t * 0.5, h * 0.5),   Vector2(t, h)],
	]
	for bd: Array in borders:
		var body := StaticBody2D.new()
		body.collision_layer = 2
		body.collision_mask  = 0
		add_child(body)
		body.global_position = bd[0]
		var cs   := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = bd[1]
		cs.shape  = rect
		body.add_child(cs)

func _setup_camera_limits() -> void:
	var player := get_node_or_null("Player")
	if player == null:
		return
	var cam := player.get_node_or_null("Camera2D") as Camera2D
	if cam == null:
		return
	cam.limit_left   = 0
	cam.limit_top    = 0
	cam.limit_right  = COLS * TILE
	cam.limit_bottom = ROWS * TILE
