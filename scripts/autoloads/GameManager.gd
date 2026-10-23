extends Node

## Global player state. Persists across scenes.

const GearDB    = preload("res://scripts/Equipment.gd")
const Fishing   = preload("res://scripts/Fishing.gd")
const Farming   = preload("res://scripts/Farming.gd")
# Backstory uses `class_name Backstory` so it's globally available — no
# preload const needed (would shadow the class_name symbol under strict mode).

var player_skill_xp: Dictionary = {
	"woodcutting":  0,
	"mining":        0,
	"fishing":       0,
	# Foraging was merged into Farming (Phase 1); its slot is now Jewelcrafting.
	"jewelcrafting": 0,
	"smithing":      0,
	"cooking":       0,
	"crafting":      0,
	"construction":  0,
	"farming":       0,
	"melee":         0,
	"ranged":        0,
	"magic":         0,
	"defense":       0,
	"vitality":      1154,  # starts at level 10 on the RS-style curve
	"soul":          0,
}

## Foraging → Farming merge (Phase 1). Any legacy "foraging" skill reference
## (herb/mushroom/berry nodes, old quests) redirects to "farming" so the
## existing string literals keep working without a mass rewrite.
func _canonical_skill(skill: String) -> String:
	return "farming" if skill == "foraging" else skill

const RESPAWN_POS := Vector2(7823, 4488)  # Bjorn's Landing coastal spawn — matches server-side INSERT default for new accounts
## Player's world px captured right before a 2D↔3D toggle (P7), so the new scene
## spawns them exactly where they were instead of at RESPAWN_POS (which would be a
## free fast-travel exploit). Vector2(-1,-1) = "none" (fresh boot uses the login pos).
var switch_pos: Vector2 = Vector2(-1, -1)

## First-login opening prologue (OpeningPrologue.gd runs as a persistent director on the
## tree root, so the book/white mask the 2D→3D→2D scene switches). `intro_active` = a
## director is running — worlds must NOT start their own or re-show the book across the
## switches. `intro_need_backstory` = defer character creation until AFTER the cinematic
## (the director shows BackstorySelectScreen at the end, in whatever scene we land in).
var intro_active: bool = false
var intro_need_backstory: bool = false

const BONE_XP: Dictionary = {
	"rat_bone":     5,
	"bone":         15,
	"goblin_ear":   10,
	"draugr_shard": 30,
	"dragon_scale": 50,
	# Generic Soul-skill remains — dropped by ANY monster (~50% chance, tiered by
	# the monster's level, see Monster.SOUL_DROPS). Bury for Soul XP like any bone.
	"bone_fragment": 8,
	"cursed_bone":   20,
	"soul_essence":  45,
}

## Cooked foods → HP healed when eaten (left-click in inventory). Higher cooking
## tiers heal more. Used by eat_food(); cook recipes live in HUD._COOK_RECIPES.
const FOOD_HEAL: Dictionary = {
	# Existing dishes
	"cooked_fish": 5, "herb_tea": 4, "cooked_salmon": 9, "cooked_lobster": 16,
	"cooked_shark": 22, "eel_stew": 30,
	# Lv 1–50 tiers
	"cooked_rat_meat": 3, "roasted_chicken": 4,
	"grilled_trout": 6, "baked_potato": 5,
	"vegetable_stew": 8,
	"meat_pie": 12, "fish_soup": 11,
	"hearty_stew": 15,
	"shark_steak": 20, "honey_glazed_ham": 19,
	"stuffed_boar": 24, "spiced_fish": 22,
	"dragon_fin_soup": 28, "mead_braised_ribs": 27,
	"frost_trout_fillet": 33, "venison_roast": 31,
	"magma_prawn": 37, "smoked_bear": 36,
	"elder_fish_platter": 42, "giants_feast": 46,
	# Lv 55–80 tiers (rarer ingredients, big heals)
	"leviathan_stew": 55, "kraken_platter": 66, "feast_of_valhalla": 80,
	# Pure-farming baseline dishes — playtest integration (crops → cooking).
	"wheat_bread": 5, "carrot_stew": 12, "moonwheat_loaf": 40,
	# Farming crop dishes (1.6.2) — basics + flagship dishes.
	"barley_porridge": 6, "steamed_cabbage": 6, "dark_bread": 8, "roasted_corn": 8,
	"boiled_potato": 9, "garden_salad": 15, "sweet_loaf": 14, "farmers_stew": 20,
	"ale": 10, "stuffed_pepper": 16, "melon_slice": 24, "apple_pie": 36,
	"berry_fruit_bowl": 30, "peach_cobbler": 42, "fine_wine": 46,
}

## Inventory items: Array of { "id", "name", "qty", "color" }
var inventory: Array[Dictionary] = []
var bank_inventory: Array[Dictionary] = []
var gold: int = 0

## Banked gold reserve (Phase 3 #3) — server-owned, moved via deposit/withdraw.
## Display-only mirror; the server is authoritative (synced by bank_gold_set).
var bank_gold: int = 0

## PvP Tokens — a SERVER-OWNED currency (Phase 1d), not an inventory item.
## Earned on PvP kills, spent at the PvP-Token NPC to permanently upgrade a
## gear piece. The server is authoritative: this local copy is display-only and
## is overwritten by every `pvp_tokens_set` / login payload. Never mutate it to
## grant tokens — only the server does that.
var pvp_tokens: int = 0

## Practice-makes-perfect counters — recipe_id → total attempts (success
## + fail). Feeds the cook/smith/farm success formula: every 100 attempts
## on a specific recipe adds +5% to that recipe's success chance, cap +30%.
## Persisted server-side in the players.recipe_counts JSON column.
var recipe_success_counts: Dictionary = {}

## Bump the counter for `recipe_id` — call on every craft attempt regardless
## of outcome. The next save round-trip persists to disk. Safe to call from
## anywhere on the client; caps at 999999 as a sanity guard.
func bump_recipe_count(recipe_id: String) -> void:
	if recipe_id == "":
		return
	var cur: int = int(recipe_success_counts.get(recipe_id, 0))
	recipe_success_counts[recipe_id] = mini(999999, cur + 1)

## Per-recipe practice bonus — every 100 attempts adds +5% success, cap
## +30%. Returned as a float in [0.0, 0.30] for the success roll.
func practice_bonus_for(recipe_id: String) -> float:
	@warning_ignore("integer_division")
	var bumps: int = int(recipe_success_counts.get(recipe_id, 0)) / 100
	return minf(0.30, float(bumps) * 0.05)

## Quest definitions ── type: "kill" | "collect"
const QUESTS: Array = [
	{"id":"q_rats",     "npc":"Elder Bjarne",      "title":"Rat Infestation",
	 "desc":"Kill 5 Giant Rats near the walls of Kjelvik.",
	 "type":"kill",    "target":"rat",          "qty":5,  "reward_xp":100, "skill":"combat"},
	{"id":"q_ironwood", "npc":"Torsten the Wanderer","title":"Into the Ironwood",
	 "desc":"Venture east and slay 3 Skeletons haunting the Ironwood.",
	 "type":"kill",    "target":"skeleton",     "qty":3,  "reward_xp":150, "skill":"combat"},
	{"id":"q_wolves",   "npc":"Hunter Ragnhild",    "title":"Goblin Hunt",
	 "desc":"Drive off 4 Goblins terrorising the Frostheim hunting grounds.",
	 "type":"kill",    "target":"goblin",       "qty":4,  "reward_xp":120, "skill":"combat"},
	{"id":"q_logs",     "npc":"Blacksmith Ulfr",    "title":"Ironwood Timber",
	 "desc":"Gather 3 Ironwood Logs for Ulfr's legendary blade.",
	 "type":"collect", "target":"ironwood_log", "qty":3,  "reward_xp":200, "skill":"woodcutting"},
	{"id":"q_ashlands", "npc":"Scout Halfdan",       "title":"Ashlands Menace",
	 "desc":"Investigate by slaying 5 Draugr in the ashlands.",
	 "type":"kill",    "target":"draugr",       "qty":5,  "reward_xp":350, "skill":"combat"},
	{"id":"q_fish",     "npc":"Merchant Eydis",      "title":"Eastern Waters",
	 "desc":"Bring back 3 Lobsters from the coastal waters east of Bjorn's Landing.",
	 "type":"collect", "target":"lobster",      "qty":3,  "reward_xp":180, "skill":"fishing"},
]

## Active quests: quest_id → {progress: int, completed: bool}
var active_quests: Dictionary = {}

## Post-quest-system server snapshot — mirrors what _handle_quest_*
## returned. The QuestLog + marker renderer drive entirely off this.
##   server_active_quests:    Array[Dictionary]  — [{quest_id, progress, accepted_at}]
##   server_completed_ids:    Array[String]      — distinct completed quest_ids
##   server_completion_counts: Dictionary        — {quest_id: count}
## Mutated only by `apply_quest_state` from the server push; never reconstructed
## locally so the client can't drift from the SQLite source of truth.
var server_active_quests: Array       = []
var server_completed_ids: Array       = []
var server_completion_counts: Dictionary = {}

var current_hp: int = 0
var equipped_boots: String = ""

## Character appearance (see Appearance.gd). Populated from server on login.
var appearance: Dictionary = {"skin": 2, "hair_style": 0, "hair_color": 1, "beard": 1, "body": 1, "tunic": 0}
## Equipped gear by slot id → item_id (e.g. {"head":"iron_helm"}). Server stores it.
var equipment: Dictionary = {}
## Combat-style preference — set via the persistent HUD toggle and consumed
## by HUD._launch_player_attack. Survives logout via the appearance JSON blob.
## Values: "melee" / "ranged" / "magic".
var combat_style: String = "melee"
## Backstory perk id ("viking" / "fisher" / "craftsman" / "mage" / "archer"
## or empty). Set on login from the server payload; re-applies its
## PlayerMods on every login. Selecting at character creation is a
## one-shot — see send_set_backstory in NetworkManager.
var backstory: String = ""
## When combat_style == "magic", the rune id this player is currently casting.
## Each cast consumes 1 of this item from inventory. Empty string until the
## player picks a rune in the magic sub-row. Persists with appearance.
var active_rune: String = ""
## Boat currently being sailed (Boat.gd id), or "" when on foot. In-memory only.
var current_boat: String = ""
## Current hull HP + max for the boat being sailed. Tracked here so it
## persists between Phase 3 sea-combat encounters within a single sailing
## session (`_launch_boat` sets both to max, `_dock_boat` and the "lose"
## outcome clear them to 0). Not server-persisted — surviving HP is intra-
## session only, by design. Player.gd reads these to draw the floating HP
## bar below the hull when current < max.
var current_boat_hp:     int = 0
var current_boat_max_hp: int = 0

## True when the local player is currently in a boat. Set by Player.gd
## on _launch_boat / _dock_boat so other systems (NetworkManager's shark
## bite handler, HUD, etc.) can gate boat-specific behavior without
## reaching into the Player node's private state.
var is_sailing: bool = false

## PvP flag — WoW-style toggle with a WoW-style safe-mode grace after a
## PvP death. Three states:
##   pvp_flagged == true  → PvP ON, damage-taking active
##   pvp_flagged == false + pvp_safe_until > now → SAFE MODE (post-death
##       grace, no PvP damage in or out, cannot be attacked). Clicking the
##       toggle DURING safe mode ends the grace early and flips straight
##       back to PvP ON — the user asked for an override.
##   pvp_flagged == false + pvp_safe_until <= now → PvP OFF
## Turning ON from OFF costs a `PVP_COOLDOWN_SEC` lockout during which the
## flag can't be turned off (prevents flicker exploits).
const PVP_COOLDOWN_SEC: float = 300.0
const PVP_SAFE_MODE_SEC: float = 60.0
var pvp_flagged: bool = false
var pvp_locked_until: float = 0.0
var pvp_safe_until: float = 0.0

## Interior decouple (bug batch 2026-07): interiors live at a far-off y≈12000
## island, so reading the raw player position for the minimap / biome music
## would show a wrong biome. While inside, consumers read `overworld_anchor`
## (the building's real exterior position) instead of the player position.
## Set by World._on_interior_entered / cleared on exit.
# ── Admin-drawn road/path network (v1.6.9) ──────────────────────────────────
## Waypoint graph the admin draws in-world (Roads tab) + the server persists.
## `road_nodes` = [{id:int, x:float, y:float}] · `road_edges` = [[a_id,b_id],…].
## The autoplay bot routes over it (road_path) for real road-following travel;
## NetworkManager keeps these in sync via set_road_graph on the road_graph msg.
var road_nodes: Array = []
var road_edges: Array = []

var in_interior: bool = false
var overworld_anchor: Vector2 = Vector2.ZERO
## Which interior the LOCAL player is currently in ("" = outside). Other players
## are only rendered when their interior_id matches this, so building occupants
## see each other and outsiders are hidden while you're inside.
var current_interior_id: String = ""

## The position the minimap / biome-audio should treat as "where you are":
## the building's exterior spot while inside, else the live player position.
func overworld_pos(player_pos: Vector2) -> Vector2:
	return overworld_anchor if in_interior else player_pos

# ── Road network sync + routing ─────────────────────────────────────────────
## Called by NetworkManager when a road_graph message arrives (login + edits).
func set_road_graph(nodes: Array, edges: Array) -> void:
	road_nodes = nodes
	road_edges = edges

## Next free node id — max existing + 1 (the admin editor assigns ids locally).
func road_next_node_id() -> int:
	var m: int = 0
	for n: Variant in road_nodes:
		m = maxi(m, int((n as Dictionary).get("id", 0)))
	return m + 1

func _road_node_pos(nid: int) -> Vector2:
	for n: Variant in road_nodes:
		var d := n as Dictionary
		if int(d.get("id", -1)) == nid:
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return Vector2.INF

func _road_nearest_node(pos: Vector2) -> int:
	var best_id: int = -1
	var best_d: float = INF
	for n: Variant in road_nodes:
		var d := n as Dictionary
		var np := Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		var dist := pos.distance_to(np)
		if dist < best_d:
			best_d = dist
			best_id = int(d.get("id", -1))
	return best_id

## Adjacency built on demand — the graph is small (dozens of nodes).
func _road_adjacency() -> Dictionary:
	var adj: Dictionary = {}
	for e: Variant in road_edges:
		if not (e is Array) or (e as Array).size() != 2:
			continue
		var a := int((e as Array)[0])
		var b := int((e as Array)[1])
		if not adj.has(a): adj[a] = []
		if not adj.has(b): adj[b] = []
		(adj[a] as Array).append(b)
		(adj[b] as Array).append(a)
	return adj

## Shortest sequence of world waypoints from `from_world` to `to_world` along the
## drawn road graph: nearest node to the start → BFS → nearest node to the goal,
## then the goal itself. Empty if there's no graph (caller falls back to a
## straight line). BFS is fine — edges are unweighted hops between hand-placed
## nodes that already sit on the roads.
func road_path(from_world: Vector2, to_world: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if road_nodes.size() < 2:
		return out
	var start := _road_nearest_node(from_world)
	var goal := _road_nearest_node(to_world)
	if start < 0 or goal < 0:
		return out
	if start == goal:
		out.append(_road_node_pos(goal))
		out.append(to_world)
		return out
	var adj := _road_adjacency()
	# Breadth-first search for the fewest-hops path.
	var came: Dictionary = {start: start}
	var queue: Array = [start]
	var found := false
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if cur == goal:
			found = true
			break
		for nb_v: Variant in adj.get(cur, []):
			var nb := int(nb_v)
			if not came.has(nb):
				came[nb] = cur
				queue.append(nb)
	if not found:
		return out
	# Walk the predecessor chain back to the start, then reverse into waypoints.
	var chain: Array = []
	var node := goal
	while node != start:
		chain.append(node)
		node = int(came[node])
	chain.append(start)
	chain.reverse()
	for nid_v: Variant in chain:
		out.append(_road_node_pos(int(nid_v)))
	out.append(to_world)   # final approach off the last node to the actual goal
	return out

func is_pvp_safe() -> bool:
	return not pvp_flagged and Time.get_unix_time_from_system() < pvp_safe_until

## Attempt to change PvP state. Returns "" on success, otherwise a
## user-facing reason string ("Locked for 4m 12s"). Enabling is always
## free and starts the lockout window. Disabling only succeeds after
## the lockout elapses. Clicking during safe mode overrides — flips
## straight back to full PvP ON and clears the grace timer.
func request_pvp_toggle(want_on: bool) -> String:
	var now: float = Time.get_unix_time_from_system()
	# Safe-mode override — user pressing the button during grace opts BACK IN.
	if is_pvp_safe():
		pvp_safe_until = 0.0
		pvp_flagged = true
		pvp_locked_until = now + PVP_COOLDOWN_SEC
		return ""
	if want_on == pvp_flagged:
		return ""
	if want_on:
		pvp_flagged = true
		pvp_locked_until = now + PVP_COOLDOWN_SEC
		pvp_safe_until = 0.0
		return ""
	if now < pvp_locked_until:
		var rem: int = int(ceil(pvp_locked_until - now))
		@warning_ignore("integer_division")
		var mins: int = rem / 60
		return "PvP locked for %dm %02ds" % [mins, rem % 60]
	pvp_flagged = false
	return ""

## Called on respawn after a PvP death. Drops PvP flag → SAFE mode for
## PVP_SAFE_MODE_SEC. When the grace elapses the player is left in PvP OFF
## (per the user's spec — "wait out the safe mode you go back to PVP off").
func begin_pvp_safe_mode() -> void:
	pvp_flagged = false
	pvp_locked_until = 0.0
	pvp_safe_until = Time.get_unix_time_from_system() + PVP_SAFE_MODE_SEC

## Deduct `dmg` from the current boat's hull. When HP hits 0 the boat
## sinks — Player.gd handles the actual dock transition on its next
## _process tick since it polls current_boat_hp for the HP-bar draw.
func apply_boat_damage(dmg: int) -> void:
	if current_boat_hp <= 0 or dmg <= 0:
		return
	current_boat_hp = max(0, current_boat_hp - dmg)
	Events.chat_message.emit("[Boat] Hull takes %d damage (%d/%d)."
			% [dmg, current_boat_hp, current_boat_max_hp])

# Boot move-speed bonus scales with tier: 8% base, +8% per tier step. Derived
# from the boot id's tier prefix so every current + future boot tier is
# covered without a hand-maintained per-id dict. Gold sits at the iron step
# (it's a jewelry/utility material, not a combat tier).
const _BOOT_SPEED_STEP: Dictionary = {
	"leather": 1, "copper": 2, "iron": 3, "gold": 3,
	"mithril": 4, "adamant": 5, "runite": 6, "dragon": 7,
}
const _BOOT_SPEED_PER_STEP := 0.08

## Fractional move-speed bonus for a boot id ("" or non-boot → 0.0).
## e.g. leather_boots → 0.08, iron_boots → 0.24, runite_boots → 0.48.
func boot_speed_bonus(boot_id: String) -> float:
	if boot_id == "" or not boot_id.ends_with("boots"):
		return 0.0
	var tier := boot_id.get_slice("_", 0)
	var step := int(_BOOT_SPEED_STEP.get(tier, 1))
	return _BOOT_SPEED_PER_STEP * float(step)

## True when the item id is any boot (for UI gating that used to check the
## old BOOT_SPEED_BONUS dict membership).
func is_boots(item_id: String) -> bool:
	return item_id.ends_with("boots")

func get_move_speed(base: float) -> float:
	return base * (1.0 + boot_speed_bonus(equipped_boots))

func equip_boots(item_id: String) -> void:
	equipped_boots = item_id
	Events.inventory_changed.emit()

func _ready() -> void:
	_build_xp_table()
	current_hp = get_max_hp()

# ── HP ───────────────────────────────────────────────────────────────────────
func get_max_hp() -> int:
	return get_skill_level("vitality") * 10 + get_equipment_bonus("hp")

func take_damage(amount: int) -> void:
	current_hp = maxi(0, current_hp - amount)
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	if current_hp <= 0:
		Events.player_died.emit()
		_on_player_death()

func heal(amount: int) -> void:
	var before := current_hp
	current_hp = mini(get_max_hp(), current_hp + amount)
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	# Report the REAL gain (post-cap) so the HUD floats an accurate "+N" and
	# never shows "+0" from an overheal.
	var gained := current_hp - before
	if gained > 0:
		Events.player_healed.emit(gained)

## Eat one of a cooked food item, healing its FOOD_HEAL value. Returns false if
## not edible or already at full HP.
## Metadata of the first inventory entry with `id` (e.g. a fish's "wnorm" /
## "weight" / "trophy"), or `default` if none carries it.
func item_meta(id: String, key: String, default: Variant = null) -> Variant:
	for item: Dictionary in inventory:
		if str(item.get("id", "")) == id:
			return item.get(key, default)
	return default

func eat_food(item_id: String) -> bool:
	if not FOOD_HEAL.has(item_id):
		return false
	if current_hp >= get_max_hp():
		Events.chat_message.emit("You're already at full health.")
		return false
	# Weight-scaled healing (1.6.3): a meal cooked from a bigger catch heals more.
	# Read the wnorm of the entry we're about to eat BEFORE removing it.
	var wnorm := float(item_meta(item_id, "wnorm", 0.0))
	if not remove_item_qty(item_id, 1):
		return false
	var amount := FOOD_HEAL[item_id] as int
	if wnorm > 0.0:
		amount = int(round(float(amount) * (1.0 + wnorm)))
	heal(amount)
	Events.chat_message.emit("You eat the %s. (+%d HP)" % [item_id.replace("_", " ").capitalize(), amount])
	return true

func _on_player_death() -> void:
	# Death-drop economics: tell the server we died at our current world
	# position BEFORE the respawn moves us. The server is authoritative
	# for the drop — it sorts inventory by ItemPrices.price_for, keeps
	# the top 4, drops the rest as world LootDrops, and spawns a gold
	# pile holding 25% of our current gold. Our inventory + gold get
	# pushed back via admin_inventory_set / gold_set after.
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		var p := players[0] as Node2D
		NetworkManager.send_player_died(p.global_position.x, p.global_position.y)
	current_hp = get_max_hp()
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	Events.combat_ended.emit()
	Events.player_respawned.emit(RESPAWN_POS)

func bury_bone(id: String) -> void:
	if not BONE_XP.has(id):
		return
	if not remove_item_qty(id, 1):
		return
	var xp := BONE_XP[id] as int
	add_xp("soul", xp)

# ── XP / Levels (RuneScape-style exponential curve) ──────────────────────────
# Cumulative XP to REACH each level. Built once in _ready(). Index = level (1..99);
# index 0 unused. Early levels are quick, 50+ ramps hard, 90-99 is a serious grind.
var _xp_table: Array[int] = []

func _build_xp_table() -> void:
	_xp_table.resize(100)
	_xp_table[0] = 0
	_xp_table[1] = 0
	var points := 0.0
	for lv in range(1, 99):
		points += floor(float(lv) + 300.0 * pow(2.0, float(lv) / 7.0))
		_xp_table[lv + 1] = int(floor(points / 4.0))

## XP threshold to reach a given level (clamped 1..99).
func xp_for_level(level: int) -> int:
	if _xp_table.is_empty():
		_build_xp_table()
	return _xp_table[clampi(level, 1, 99)]

func get_skill_level(skill: String) -> int:
	if _xp_table.is_empty():
		_build_xp_table()
	skill = _canonical_skill(skill)
	var xp := player_skill_xp.get(skill, 0) as int
	var lv := 1
	while lv < 99 and xp >= _xp_table[lv + 1]:
		lv += 1
	return lv

func get_skill_xp(skill: String) -> int:
	return player_skill_xp.get(_canonical_skill(skill), 0)

## Level for a raw XP value on the shared curve. Public so read-only views (the
## spectator HUD) can derive ANOTHER player's skill levels from their skill_xp
## without disturbing the local player's own state.
func level_for_xp(xp: int) -> int:
	if _xp_table.is_empty():
		_build_xp_table()
	var lv := 1
	while lv < 99 and xp >= _xp_table[lv + 1]:
		lv += 1
	return lv

## Overall "character level" — a COMBAT-WEIGHTED score, not a raw sum/average.
## The five combat skills pull CL_COMBAT_WEIGHT× harder than gathering/artisan
## skills, and the whole thing is normalized so an all-99 account lands on
## CL_TARGET_MAX (~150) instead of the ugly 1485 sum. Fresh account ≈ 1.
## The server mirrors this EXACTLY (server.py _character_level) so a player's
## nameplate level matches the Character Level in their own skills tab.
const CL_COMBAT_SKILLS: Array = ["melee", "ranged", "magic", "defense", "vitality"]
const CL_COMBAT_WEIGHT: int = 3
const CL_OTHER_WEIGHT: int = 1
const CL_TARGET_MAX: int = 150   # character level when every skill is 99

func get_character_level() -> int:
	var skills := player_skill_xp.keys()
	if skills.is_empty():
		return 1
	var weighted := 0
	var max_weighted := 0
	for s: String in skills:
		var w := CL_COMBAT_WEIGHT if CL_COMBAT_SKILLS.has(s) else CL_OTHER_WEIGHT
		weighted += get_skill_level(s) * w
		max_weighted += 99 * w
	if max_weighted == 0:
		return 1
	return maxi(1, int(round(float(weighted) / float(max_weighted) * float(CL_TARGET_MAX))))

func add_xp(skill: String, amount: int) -> void:
	skill = _canonical_skill(skill)
	if not player_skill_xp.has(skill):
		return
	# Apply PlayerMods multiplier so backstory perks / pet auras / future
	# buffs add up consistently across every XP-grant call site. Floor at
	# +1 if any positive multiplier — never make a positive grant zero.
	var mult: float = PlayerMods.xp_mult(skill)
	var final_amount: int = amount
	if mult != 1.0 and amount > 0:
		final_amount = maxi(1, int(round(float(amount) * mult)))
	var lv_before := get_skill_level(skill)
	player_skill_xp[skill] += final_amount
	Events.xp_gained.emit(skill, final_amount)
	var lv_after := get_skill_level(skill)
	# One emit per integer level crossed — a big XP grant that vaults
	# multiple levels fires once at the highest (the player only hears
	# one fanfare regardless).
	if lv_after > lv_before:
		Events.level_up.emit(skill, lv_after)

func get_level_progress(skill: String) -> float:
	skill = _canonical_skill(skill)
	var xp := player_skill_xp.get(skill, 0) as int
	var lv := get_skill_level(skill)
	if lv >= 99:
		return 1.0
	var cur := xp_for_level(lv)
	var nxt := xp_for_level(lv + 1)
	return clampf(float(xp - cur) / float(maxi(1, nxt - cur)), 0.0, 1.0)

func get_xp_to_next_level(skill: String) -> int:
	skill = _canonical_skill(skill)
	var xp := player_skill_xp.get(skill, 0) as int
	var lv := get_skill_level(skill)
	if lv >= 99:
		return 0
	return xp_for_level(lv + 1) - xp

# ── Tools ────────────────────────────────────────────────────────────────────
func has_tool_for_skill(skill: String) -> bool:
	var keyword := ""
	match skill:
		"woodcutting": keyword = "axe"
		"mining":      keyword = "pickaxe"
		# Fishing no longer requires a pole — fishing spots are usable
		# bare-handed. (Poles may return later purely as a catch-rate
		# bonus, not a hard gate.)
		_: return true
	for item: Dictionary in inventory:
		if (item["id"] as String).contains(keyword):
			return true
	return false

func tool_name_for_skill(skill: String) -> String:
	match skill:
		"woodcutting": return "an Axe"
		"mining":      return "a Pickaxe"
		"fishing":     return "a Fishing Pole"
	return ""

# ── Combat stats ─────────────────────────────────────────────────────────────
## Style-aware attack power. Universal `atk` bonus applies to every style
## (weapon damage baseline); style-specific bonuses stack on top:
##   melee  → +str (mace + shield strength)
##   ranged → +ratk (bow ranged bonus)
##   magic  → +matk (staff magic bonus)
func get_attack_power(style: String) -> int:
	var eq := get_equipment_bonus("atk")
	match style:
		"melee":
			return maxi(1, floori(get_skill_level("melee")  / 3.0) + 5 + eq
				+ get_equipment_bonus("str"))
		"ranged":
			return maxi(1, floori(get_skill_level("ranged") / 3.0) + 4 + eq
				+ get_equipment_bonus("ratk"))
		"magic":
			return maxi(1, floori(get_skill_level("magic")  / 3.0) + 3 + eq
				+ get_equipment_bonus("matk"))
	return 1

func get_defense_power() -> int:
	return maxi(0, floori(get_skill_level("defense") / 4.0)) + get_equipment_bonus("def")

# ── Combat depth (Phase 4) ──────────────────────────────────────────────────
const CRIT_BASE_CHANCE := 0.05
const CRIT_MULT := 1.5
const BLOCK_MULT := 0.5       # a block halves the incoming hit
const BLOCK_CHANCE_CAP := 0.75

## Attacker crit chance — 5% base + equipped `crit` stat (in %). Rolled on
## outgoing hits; a crit multiplies damage by CRIT_MULT.
func get_crit_chance() -> float:
	return clampf(CRIT_BASE_CHANCE + float(get_equipment_bonus("crit")) / 100.0, 0.0, 0.95)

## Defender block chance — from shields/gear `block` (in %), capped. On a block
## the incoming hit is halved.
func get_block_chance() -> float:
	return clampf(float(get_equipment_bonus("block")) / 100.0, 0.0, BLOCK_CHANCE_CAP)

## Style-aware defense (Phase 4 split): baseline def (all styles) + the matching
## def_<style> specialization. Magic bypasses shield/plate specialization, so an
## armored player still takes more from spells unless they carry magic-resist.
func get_defense_vs(style: String) -> int:
	var base := get_defense_power()
	if style == "melee" or style == "ranged" or style == "magic":
		base += maxi(0, get_equipment_bonus("def_" + style))
	return base

## Apply the defender's mitigation to an incoming hit (Phase 4): split defense
## then a block roll. Returns [final_damage, blocked]. `raw` is the pre-defense
## amount; `style` is the attacker's style.
func mitigate_incoming(raw: int, style: String) -> Array:
	var after_def := maxi(1, raw - get_defense_vs(style))
	var blocked := randf() < get_block_chance()
	if blocked:
		after_def = maxi(1, int(ceil(float(after_def) * BLOCK_MULT)))
	return [after_def, blocked]

## Roll a crit on outgoing damage (Phase 4). Returns [final_damage, was_crit].
func roll_crit(damage: int) -> Array:
	if randf() < get_crit_chance():
		return [maxi(1, int(round(float(damage) * CRIT_MULT))), true]
	return [damage, false]

## Product of every equipped piece's `atk_spd` — multiplies the base swing
## interval. Bow (0.85) + light gear can drop below 1.0 for a faster combat
## cadence; battleaxe (1.15) slows it. Combat tick paths in HUD multiply
## their fixed 2.4-second base by this value.
func get_attack_speed_mult() -> float:
	return GearDB.stat_speed_mult(equipment)

# ── Equipment ──────────────────────────────────────────────────────────────────
func get_equipment_bonus(stat: String) -> int:
	return GearDB.stat_total(equipment, stat)

## Gate an equip attempt by the item's level requirement. Returns "" on OK
## or a user-facing reason string. Consumers should chat the reason and
## bail before calling equip_item so the inventory isn't mutated.
func equip_gate(item_id: String) -> String:
	# Admins bypass every gear gate — they need to wield anything for
	# testing/building. (Full admin: owner or admin rank.)
	if is_admin():
		return ""
	var d := GearDB.def_for(item_id)
	if d.is_empty():
		return ""
	var min_lv: int = int(d.get("min_lv", 1))
	if min_lv <= 1:
		return ""
	var req_skill: String = str(d.get("req_skill", ""))
	if req_skill == "":
		return ""
	var have: int = get_skill_level(req_skill)
	if have < min_lv:
		return "Requires %s Lv %d (you are %d)." % [
			req_skill.capitalize(), min_lv, have]
	return ""

func equip_item(inv_index: int) -> void:
	if inv_index < 0 or inv_index >= inventory.size():
		return
	var item_id := inventory[inv_index]["id"] as String
	if not GearDB.is_equippable(item_id):
		return
	# Level gate — refuse before removing anything from inventory.
	var gate := equip_gate(item_id)
	if gate != "":
		Events.chat_message.emit(gate)
		return
	var slot := GearDB.target_slot(item_id, equipment)
	if slot == "":
		return
	if not remove_item_qty(item_id, 1):
		return
	var old_id := str(equipment.get(slot, ""))
	if old_id != "":
		var od := GearDB.def_for(old_id)
		add_item(old_id, str(od.get("name", old_id)), 1,
			_swap_color_for(old_id))
	equipment[slot] = item_id
	if slot == "boots":
		equipped_boots = item_id
	_after_equipment_change()
	Events.chat_message.emit("Equipped %s." % str(GearDB.def_for(item_id).get("name", item_id)))

func unequip_slot(slot: String) -> void:
	var iid := str(equipment.get(slot, ""))
	if iid == "":
		return
	if inventory.size() >= 28:
		Events.chat_message.emit("Inventory full — make room first.")
		return
	var d := GearDB.def_for(iid)
	add_item(iid, str(d.get("name", iid)), 1, _swap_color_for(iid))
	equipment.erase(slot)
	if slot == "boots":
		equipped_boots = ""
	_after_equipment_change()

## Set the server-owned PvP-Token balance + notify listeners (HUD counter,
## upgrade UI). Server is authoritative — this is only ever called from a
## server message (pvp_tokens_set / kill credit / login), never to self-grant.
func set_pvp_tokens(n: int) -> void:
	pvp_tokens = maxi(0, n)
	Events.pvp_tokens_changed.emit(pvp_tokens)

## Apply a server-approved token upgrade (Phase 1d). The server already
## deducted tokens + minted the new item id; here we just swap the piece in
## place (equipped slot or inventory) and sync the balance. `slot` is "" when
## the upgraded piece was in the backpack rather than worn.
func apply_token_upgrade(slot: String, old_id: String, new_id: String, new_balance: int) -> void:
	set_pvp_tokens(new_balance)
	var new_name := str(GearDB.def_for(new_id).get("name", new_id))
	# Equipped piece — swap the slot value and recompute stats.
	if slot != "" and str(equipment.get(slot, "")) == old_id:
		equipment[slot] = new_id
		if slot == "boots":
			equipped_boots = new_id
		_after_equipment_change()
		Events.chat_message.emit("Upgraded %s." % new_name)
		return
	# Otherwise find it in the backpack (gear is qty 1, so first match is it).
	for i in range(inventory.size()):
		if str(inventory[i].get("id", "")) == old_id:
			inventory[i]["id"] = new_id
			inventory[i]["name"] = new_name
			Events.inventory_changed.emit()
			Events.chat_message.emit("Upgraded %s." % new_name)
			return
	# Piece wasn't found where the client expected (moved/banked mid-request).
	# Balance still synced above; surface a soft note so the player re-checks.
	Events.chat_message.emit("Upgrade applied — item not found in its slot; check your gear.")

## Strict gate enforcement — called on login after equipment loads (Phase 1
## rescale). Walks every equipped slot; anything the player no longer meets
## the level requirement for is moved back to inventory. Admins bypass
## (equip_gate returns "" for them, so nothing is stripped). Forces the
## unequip even if inventory is at the soft cap — enforcement can't be
## blocked by a full bag.
func enforce_equip_gates() -> void:
	var strip: Array[String] = []
	for slot: String in equipment.keys():
		var iid := str(equipment[slot])
		if iid != "" and equip_gate(iid) != "":
			strip.append(slot)
	for slot: String in strip:
		var iid := str(equipment[slot])
		var d := GearDB.def_for(iid)
		add_item(iid, str(d.get("name", iid)), 1, _swap_color_for(iid))
		equipment.erase(slot)
		if slot == "boots":
			equipped_boots = ""
		Events.chat_message.emit(
			"Unequipped %s — you no longer meet its level requirement." %
			str(d.get("name", iid)))
	if not strip.is_empty():
		_after_equipment_change()
		Events.equipment_changed.emit()

## Picks the inventory tint to use when an equipped item returns to the bag.
## Gear is gray (matching the long-standing UI convention); bait/lures keep
## their real Fishing-table color so the inventory entry stays recognizable
## after a swap or unequip. Add cases here if new typed equipment categories
## need their own color preservation.
func _swap_color_for(item_id: String) -> Color:
	if Fishing.is_bait(item_id) or Fishing.is_lure(item_id):
		var td: Dictionary = Fishing.tackle_data(item_id)
		return td.get("color", Color.GRAY) as Color
	return Color.GRAY

## Phase 5 — id of the currently-equipped fishing tackle (bait OR lure), or
## "" if the bait slot is empty. Reads through `equipment` so it stays in
## sync with the existing equip / unequip / server-save path.
func equipped_bait() -> String:
	return str(equipment.get("bait", ""))

func _after_equipment_change() -> void:
	current_hp = mini(current_hp, get_max_hp())
	Events.equipment_changed.emit()
	Events.inventory_changed.emit()
	_broadcast_appearance()   # tell the server → other players re-render our gear live

## Push our appearance + equipment to the server so it broadcasts player_appearance
## to everyone else (they re-render our weapon/armor). No-ops if not logged in.
## Rides combat_style/active_rune along like set_combat_style so they aren't lost.
func _broadcast_appearance() -> void:
	var to_send := appearance.duplicate()
	to_send["combat_style"] = combat_style
	to_send["active_rune"]  = active_rune
	NetworkManager.send_set_appearance(to_send, equipment)

## ── Admin / capability gates ─────────────────────────────────────────────
## Three ranks live server-side: owner, admin, mapper. Client splits them
## into two capability tiers:
##   • is_full_admin() — owner + admin only. Gates economy tools (gold /
##     items), account admin, /wipemonsters, and the visibility of
##     dangerous AdminPanel tabs. Bypasses level/material checks.
##   • can_edit_map() — includes mapper on top. Gates the map-building
##     surface (tile paint / entity placement / zone editor).
## `is_admin()` remains as a compatibility shim returning is_full_admin(),
## so pre-existing call sites keep their conservative behavior; new gates
## on map building should use can_edit_map().
func is_full_admin() -> bool:
	var r: String = NetworkManager.my_admin_rank
	return r == "owner" or r == "admin"

func can_edit_map() -> bool:
	var r: String = NetworkManager.my_admin_rank
	return r == "owner" or r == "admin" or r == "mapper"

func is_admin() -> bool:
	return is_full_admin()

## Persist the combat-style toggle and the active rune. Called from the
## HUD's persistent style strip and rune sub-row. The save round-trips
## through send_set_appearance — server stores both values inside the
## appearance JSON blob, populate_from_server reads them back before
## Appearance.sanitize strips them off.
func set_combat_style(style: String, rune_id: String = "") -> void:
	if style != "melee" and style != "ranged" and style != "magic":
		return
	combat_style = style
	if style == "magic":
		active_rune = rune_id
	else:
		active_rune = ""
	Events.combat_style_changed.emit(combat_style, active_rune)
	# Persist via the appearance save path. The two prefs ride along inside
	# the appearance dict so the existing set_appearance handler stores them
	# without needing a new message type.
	var to_send := appearance.duplicate()
	to_send["combat_style"] = combat_style
	to_send["active_rune"]  = active_rune
	NetworkManager.send_set_appearance(to_send, equipment)
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	NetworkManager.send_set_appearance(appearance, equipment)
	for pl in get_tree().get_nodes_in_group("player"):
		(pl as Node2D).queue_redraw()

const INV_CAP := 28
# Only ammo / consumable-type items stack into one slot. Everything else (logs,
# ores, fish, food, armour, weapons, tools) takes one slot per item. Metal BARS
# are the exception (playtest ask) — they stack so mid-tier builds like boats
# (8 iron bars) don't devour the whole bag. Ores + logs deliberately stay
# one-per-slot.
const STACKABLE: Dictionary = {
	"arrows": true, "feather": true, "herbs": true, "stick": true,
	"stone": true, "magic_dust": true, "rune_essence": true,
}

const CROPS: Dictionary = {
	"wheat": true, "carrot": true, "barley": true, "cabbage": true, "rye": true,
	"corn": true, "potato": true, "cotton": true, "pepper": true, "sugarcane": true,
	"hops": true, "tomato": true, "moonwheat": true, "blueberry": true,
	"lingonberry": true, "strawberry": true, "peach": true, "apple": true,
	"watermelon": true, "grape": true,
}

## Grant a farm harvest (crop yield + Farming XP + practice bump), single-sourced
## so the 2D and 3D worlds award it identically. Crop colour comes from the roster.
func grant_farm_harvest(item_id: String, item_name: String, qty: int, xp: int, seed_id: String) -> void:
	var col := Color(0.90, 0.78, 0.35)
	if seed_id != "":
		var sd := Farming.seed_def(seed_id)
		if not sd.is_empty():
			col = Farming.color_of(sd)
	add_item(item_id, item_name, maxi(1, qty), col)
	if xp > 0:
		add_xp("farming", xp)
	if seed_id != "":
		bump_recipe_count(seed_id)

## Re-grant a seed the plant popup removed optimistically, when the server
## rejects the plant. No-op if the seed id isn't a known crop seed.
func refund_farm_seed(seed_id: String) -> void:
	if seed_id == "":
		return
	var sd := Farming.seed_def(seed_id)
	if not sd.is_empty():
		add_item(seed_id, str(sd.get("seed_name", seed_id)), 1, Farming.color_of(sd))

func is_stackable(id: String) -> bool:
	return STACKABLE.has(id) or id.ends_with("_rune") \
		or id.ends_with("_seed") or id.ends_with("_bar") or CROPS.has(id)

# ── Inventory ─────────────────────────────────────────────────────────────────
func get_item_qty(id: String) -> int:
	var total := 0
	for item: Dictionary in inventory:
		if item["id"] == id:
			total += item["qty"] as int
	return total

func free_slots() -> int:
	return maxi(0, INV_CAP - inventory.size())

## Remove `qty` of an item, spanning multiple (non-stacked) slots if needed.
func remove_item_qty(id: String, qty: int) -> bool:
	if get_item_qty(id) < qty:
		return false
	var remaining := qty
	var i := 0
	while i < inventory.size() and remaining > 0:
		var item: Dictionary = inventory[i]
		if item["id"] == id:
			var take := mini(remaining, item["qty"] as int)
			item["qty"] = (item["qty"] as int) - take
			remaining -= take
			if (item["qty"] as int) <= 0:
				inventory.remove_at(i)
				continue
		i += 1
	Events.inventory_changed.emit()
	return true

func add_item(id: String, item_name: String, qty: int, color: Color, extra: Dictionary = {}) -> void:
	# `extra` carries per-item metadata (e.g. a fish's {weight, trophy}) onto the
	# inventory entry. Only meaningful for non-stackable items — a stacked item
	# can't hold a per-unit weight.
	var added := 0
	if is_stackable(id):
		for item in inventory:
			if item["id"] == id:
				item["qty"] = (item["qty"] as int) + qty
				added = qty
				break
		if added == 0 and free_slots() > 0:
			inventory.append({"id": id, "name": item_name, "qty": qty, "color": color})
			added = qty
	else:
		# One slot per item; add as many separate stacks of 1 as fit.
		for _n in range(qty):
			if free_slots() <= 0:
				break
			var entry := {"id": id, "name": item_name, "qty": 1, "color": color}
			entry.merge(extra)
			inventory.append(entry)
			added += 1
	if added <= 0:
		Events.chat_message.emit("Your inventory is full.")
		return
	Events.inventory_changed.emit()
	Events.item_gained.emit(item_name, added)
	_check_collect_quests(id)

# ── Quest system ──────────────────────────────────────────────────────────────
func accept_quest(quest_id: String) -> void:
	if active_quests.has(quest_id):
		return
	active_quests[quest_id] = {"progress": 0, "completed": false}
	Events.quest_accepted.emit(quest_id)


# ── Server-pushed quest snapshot ─────────────────────────────────────────────
## Wholesale replace the cached state with whatever the server just pushed.
## `payload` is the `quest_state` message body (already arrived as a dict).
## Single signal emit so listeners refresh idempotently.
func apply_quest_state(payload: Dictionary) -> void:
	var a: Variant = payload.get("active", [])
	server_active_quests = a if a is Array else []
	# Compare old → new to detect freshly-completed quests so the audio
	# layer can chime once per completion. Repeated boss-quest turn-ins
	# bump completion_counts but the id is already in the set, so this
	# emits once per unique completion only — we layer the boss-repeat
	# chime off completion_counts in a future pass if desired.
	var prev_completed: Array = server_completed_ids.duplicate()
	var c: Variant = payload.get("completed_ids", [])
	server_completed_ids = c if c is Array else []
	var k: Variant = payload.get("completion_counts", {})
	server_completion_counts = k if k is Dictionary else {}
	for qid: Variant in server_completed_ids:
		var qs := String(qid)
		if not (qs in prev_completed):
			Events.quest_completed.emit(qs)
	Events.quest_state_changed.emit()

## Returns the active row for `quest_id` or {} if not active.
func get_active_quest(quest_id: String) -> Dictionary:
	for row: Variant in server_active_quests:
		if row is Dictionary and str((row as Dictionary).get("quest_id", "")) == quest_id:
			return row
	return {}

## Progress count for objective `obj_idx` of `quest_id`. Returns 0 for any
## unknown quest / objective so callers don't have to null-check.
func quest_objective_progress(quest_id: String, obj_idx: int) -> int:
	var row := get_active_quest(quest_id)
	if row.is_empty():
		return 0
	var prog: Variant = row.get("progress", {})
	if not (prog is Dictionary):
		return 0
	return int((prog as Dictionary).get(str(obj_idx), 0))

## True if every objective in `quest_id` has progress >= its quantity.
## Used by the QuestLog to show the ready-to-turn-in state and by the
## marker renderer to swap `!` → `+` on the giver NPC.
func is_quest_ready_for_turnin(quest_id: String, QuestData: GDScript) -> bool:
	var row := get_active_quest(quest_id)
	if row.is_empty():
		return false
	var def: Dictionary = QuestData.data(quest_id)
	if def.is_empty():
		return false
	var objs: Array = def.get("objectives", [])
	for i in range(objs.size()):
		var need := int((objs[i] as Dictionary).get("quantity", 1))
		if quest_objective_progress(quest_id, i) < need:
			return false
	return true

func on_monster_killed(mtype: String) -> void:
	for q: Dictionary in QUESTS:
		var qid: String = q["id"] as String
		if not active_quests.has(qid):
			continue
		var aq: Dictionary = active_quests[qid]
		if (aq["completed"] as bool):
			continue
		if (q["type"] as String) == "kill" and (q["target"] as String) == mtype:
			aq["progress"] = mini((aq["progress"] as int) + 1, q["qty"] as int)
			if (aq["progress"] as int) >= (q["qty"] as int):
				aq["completed"] = true
				add_xp(q["skill"] as String, q["reward_xp"] as int)
				Events.chat_message.emit("Quest complete: %s! +%d XP" % [q["title"], q["reward_xp"]])
			Events.quest_updated.emit(qid)

func _check_collect_quests(item_id: String) -> void:
	for q: Dictionary in QUESTS:
		var qid: String = q["id"] as String
		if not active_quests.has(qid):
			continue
		var aq: Dictionary = active_quests[qid]
		if (aq["completed"] as bool):
			continue
		if (q["type"] as String) == "collect" and (q["target"] as String) == item_id:
			var have := get_item_qty(item_id)
			aq["progress"] = mini(have, q["qty"] as int)
			if (aq["progress"] as int) >= (q["qty"] as int):
				aq["completed"] = true
				add_xp(q["skill"] as String, q["reward_xp"] as int)
				Events.chat_message.emit("Quest complete: %s! +%d XP" % [q["title"], q["reward_xp"]])
			Events.quest_updated.emit(qid)

# ── Bank ──────────────────────────────────────────────────────────────────────
func deposit_item(inv_index: int) -> void:
	if inv_index >= inventory.size():
		return
	var item: Dictionary = inventory[inv_index].duplicate()
	for b in bank_inventory:
		if b["id"] == item["id"]:
			b["qty"] = (b["qty"] as int) + (item["qty"] as int)
			inventory.remove_at(inv_index)
			Events.inventory_changed.emit()
			Events.bank_changed.emit()
			return
	bank_inventory.append(item)
	inventory.remove_at(inv_index)
	Events.inventory_changed.emit()
	Events.bank_changed.emit()

func _bank_merge(item: Dictionary) -> void:
	for b in bank_inventory:
		if b["id"] == item["id"]:
			b["qty"] = (b["qty"] as int) + (item["qty"] as int)
			return
	bank_inventory.append(item)

## Move every inventory item into the bank in one action.
# ── Autoplay: equip upgrades + deposit surplus ────────────────────────────────
## Rough power score of a gear item (higher = better), for deciding upgrades.
func _autoplay_gear_score(item_id: String) -> float:
	var d := GearDB.def_for(item_id)
	if d.is_empty():
		return -1.0
	return float(d.get("def", 0)) + float(d.get("atk", d.get("attack", 0))) \
		+ float(d.get("hp", 0)) * 0.5 + float(d.get("min_lv", 1)) * 0.15

## Would equipping this item be an upgrade (empty slot or higher score)? Used by
## the AI to decide which gear is worth crafting.
func autoplay_is_gear_upgrade(item_id: String) -> bool:
	if not GearDB.is_equippable(item_id) or equip_gate(item_id) != "":
		return false
	var slot := GearDB.target_slot(item_id, equipment)
	if slot == "":
		return false
	var cur := str(equipment.get(slot, ""))
	return cur == "" or _autoplay_gear_score(item_id) > _autoplay_gear_score(cur)

## Equip every carried gear/tool that is an UPGRADE over what's worn (or fills an
## empty slot). Wielding a crafted axe/weapon shows real progression on camera.
## Returns true if it equipped anything. Only ever a straight upgrade — never a
## downgrade — so it can't loop.
func autoplay_equip_upgrades() -> bool:
	var did := false
	var guard := 0
	while guard < 40:
		guard += 1
		var target := -1
		for i in range(inventory.size()):
			var iid := str(inventory[i]["id"])
			if not GearDB.is_equippable(iid) or equip_gate(iid) != "":
				continue
			var slot := GearDB.target_slot(iid, equipment)
			if slot == "":
				continue
			var cur := str(equipment.get(slot, ""))
			if cur == "" or _autoplay_gear_score(iid) > _autoplay_gear_score(cur):
				target = i
				break
		if target < 0:
			break
		equip_item(target)   # swaps the worse piece back into the bag
		did = true
	return did

## Deposit everything EXCEPT the tools we need to keep gathering (axe/pickaxe) and
## a little cooked food to eat in the next fight.
func autoplay_deposit_surplus() -> void:
	var food_kept := 0
	var guard := 0
	while guard < 80:
		guard += 1
		var idx := -1
		for i in range(inventory.size()):
			var iid := str(inventory[i]["id"])
			if iid.contains("axe") or iid.contains("pickaxe"):
				continue   # keep tools so the bot can keep working
			if FOOD_HEAL.has(iid) and food_kept < 4:
				food_kept += 1
				continue   # keep a few meals for combat
			idx = i
			break
		if idx < 0:
			break
		deposit_item(idx)

func deposit_all() -> void:
	if inventory.is_empty():
		return
	for item: Dictionary in inventory:
		_bank_merge(item.duplicate())
	inventory.clear()
	Events.inventory_changed.emit()
	Events.bank_changed.emit()

## Move every inventory item matching `item_id` into the bank.
func deposit_all_of(item_id: String) -> void:
	var moved := false
	for i in range(inventory.size() - 1, -1, -1):
		if str(inventory[i]["id"]) == item_id:
			_bank_merge(inventory[i].duplicate())
			inventory.remove_at(i)
			moved = true
	if moved:
		Events.inventory_changed.emit()
		Events.bank_changed.emit()

# ── Server data sync ──────────────────────────────────────────────────────────
## Called by LoginScreen after a successful server login.
## Overwrites local state with the server's saved data.
func populate_from_server_data(data: Dictionary) -> void:
	# Skill XP
	var srv_xp: Dictionary = data.get("skill_xp", {})
	for skill: String in player_skill_xp.keys():
		if srv_xp.has(skill):
			player_skill_xp[skill] = int(srv_xp[skill])
	# Foraging → Farming merge (Phase 1): fold any legacy foraging XP the save
	# still carries into farming. "foraging" is no longer a saved key, so once
	# the next save writes, this migrates exactly once (no double-count).
	if srv_xp.has("foraging"):
		player_skill_xp["farming"] = int(player_skill_xp.get("farming", 0)) \
			+ int(srv_xp["foraging"])

	# Practice-makes-perfect counters — per-recipe attempt totals feeding
	# the cook/smith/farm success formula. Empty {} for fresh accounts.
	recipe_success_counts.clear()
	var rc: Dictionary = data.get("recipe_counts", {}) if data.get("recipe_counts") is Dictionary else {}
	for k: String in rc.keys():
		recipe_success_counts[k] = int(rc[k])

	# Inventory
	inventory.clear()
	var inv_arr := data.get("inventory", []) as Array
	for item: Variant in inv_arr:
		if item is Dictionary:
			inventory.append(item as Dictionary)

	# Bank
	bank_inventory.clear()
	var bank_arr := data.get("bank", []) as Array
	for item: Variant in bank_arr:
		if item is Dictionary:
			bank_inventory.append(item as Dictionary)

	# Gold
	gold = int(data.get("gold", 0))
	# PvP Tokens (server-owned currency, Phase 1d)
	pvp_tokens = int(data.get("pvp_tokens", 0))
	# Banked gold reserve (Phase 3 #3)
	bank_gold = int(data.get("bank_gold", 0))

	# Appearance + equipped loadout. Read the raw appearance dict BEFORE
	# Appearance.sanitize discards non-cosmetic keys — combat_style and
	# active_rune ride along in the blob to survive logout.
	var raw_appr: Dictionary = data.get("appearance", {}) as Dictionary if data.get("appearance") is Dictionary else {}
	combat_style = str(raw_appr.get("combat_style", "melee"))
	if combat_style != "melee" and combat_style != "ranged" and combat_style != "magic":
		combat_style = "melee"
	active_rune  = str(raw_appr.get("active_rune", ""))
	appearance = Appearance.sanitize(raw_appr)
	var eq: Variant = data.get("equipment", {})
	equipment = (eq as Dictionary) if eq is Dictionary else {}
	equipped_boots = str(equipment.get("boots", equipped_boots))
	Events.equipment_changed.emit()
	# Phase 1 rescale — strict enforcement: strip any equipped gear the
	# player no longer qualifies for under the new level bands. Runs after
	# skills + equipment + admin rank are all loaded. Admins are exempt.
	enforce_equip_gates()

	# Server-pushed quest state — full snapshot in the login burst per the
	# "client never assumes" rule. Empty payload on a fresh account is fine
	# (apply_quest_state handles missing keys defensively).
	var qs: Variant = data.get("quest_state", {})
	if qs is Dictionary:
		apply_quest_state(qs as Dictionary)

	# Backstory perk — apply its PlayerMods on every login. Empty string
	# means "not yet picked" (new account / legacy account), which
	# Backstory.apply treats as a no-op. PlayerMods is cleared first so a
	# logout-then-login swap to a different account doesn't leak mods.
	backstory = str(data.get("backstory", ""))
	PlayerMods.remove_source("backstory")
	if backstory != "":
		Backstory.apply(backstory, PlayerMods)

	# Pet system — restore the saved pet type but DON'T auto-summon. The
	# live Pet node is RAM-only by design; player taps Summon when ready.
	PetManager.apply_login_pet(str(data.get("pet_type", "")))

	# Restore HP
	current_hp = get_max_hp()
	Events.player_hp_changed.emit(current_hp, get_max_hp())
	Events.inventory_changed.emit()

	# Teleport player to saved position
	var sx := float(data.get("x", RESPAWN_POS.x))
	var sy := float(data.get("y", RESPAWN_POS.y))
	Events.player_respawned.emit(Vector2(sx, sy))

## Move an entire bank stack into the inventory in one go. Splits across
## empty slots if the item isn't stackable and there's more than one unit.
## Silently no-ops when the bank slot is empty. Non-stackables that can't
## all fit deposit as many as they can and leave the remainder behind.
func withdraw_all_of(bank_index: int) -> void:
	if bank_index < 0 or bank_index >= bank_inventory.size():
		return
	var item: Dictionary = bank_inventory[bank_index]
	var iid := str(item["id"])
	if is_stackable(iid):
		if free_slots() <= 0:
			# Even a stack needs a target slot when the inventory has none.
			for inv in inventory:
				if inv["id"] == iid:
					inv["qty"] = (inv["qty"] as int) + (item["qty"] as int)
					bank_inventory.remove_at(bank_index)
					Events.inventory_changed.emit()
					Events.bank_changed.emit()
					return
			Events.chat_message.emit("Inventory full — make room first.")
			return
		for inv in inventory:
			if inv["id"] == iid:
				inv["qty"] = (inv["qty"] as int) + (item["qty"] as int)
				bank_inventory.remove_at(bank_index)
				Events.inventory_changed.emit()
				Events.bank_changed.emit()
				return
		inventory.append(item.duplicate())
		bank_inventory.remove_at(bank_index)
	else:
		while (item["qty"] as int) > 0 and free_slots() > 0:
			var one := item.duplicate()
			one["qty"] = 1
			inventory.append(one)
			item["qty"] = (item["qty"] as int) - 1
		if (item["qty"] as int) <= 0:
			bank_inventory.remove_at(bank_index)
	Events.inventory_changed.emit()
	Events.bank_changed.emit()

## Permanently delete a stack from the inventory. No refund, no bank move.
## Bank-side counterpart lives at `discard_bank_item`.
func discard_item(inv_index: int) -> void:
	if inv_index < 0 or inv_index >= inventory.size():
		return
	inventory.remove_at(inv_index)
	Events.inventory_changed.emit()

func discard_bank_item(bank_index: int) -> void:
	if bank_index < 0 or bank_index >= bank_inventory.size():
		return
	bank_inventory.remove_at(bank_index)
	Events.bank_changed.emit()

func withdraw_item(bank_index: int) -> void:
	if bank_index >= bank_inventory.size():
		return
	if free_slots() <= 0:
		Events.chat_message.emit("Inventory full — make room first.")
		return
	var item: Dictionary = bank_inventory[bank_index]
	var iid := str(item["id"])
	if is_stackable(iid):
		# Move the whole stack, merging with an existing inventory stack if any.
		var qty := item["qty"] as int
		for inv in inventory:
			if inv["id"] == iid:
				inv["qty"] = (inv["qty"] as int) + qty
				bank_inventory.remove_at(bank_index)
				Events.inventory_changed.emit()
				Events.bank_changed.emit()
				return
		inventory.append(item.duplicate())
		bank_inventory.remove_at(bank_index)
	else:
		# One unit per click — keeps non-stackable items at one slot each.
		var one := item.duplicate()
		one["qty"] = 1
		inventory.append(one)
		item["qty"] = (item["qty"] as int) - 1
		if (item["qty"] as int) <= 0:
			bank_inventory.remove_at(bank_index)
	Events.inventory_changed.emit()
	Events.bank_changed.emit()
