extends Node

## WebSocket client autoload.
## Connects to the VikingVale multiplayer server, handles login,
## syncs position, and manages other-player nodes.

const Boats = preload("res://scripts/Boat.gd")

# ── Signals ────────────────────────────────────────────────────────────────────
signal connected_to_server()
signal disconnected_from_server()
signal login_ok(player_data: Dictionary)
signal admin_rank_changed(rank: String)
signal login_fail(reason: String)
signal register_ok()
signal register_fail(reason: String)
signal kicked(reason: String)

# ── State ──────────────────────────────────────────────────────────────────────
enum NetState { OFFLINE, CONNECTING, CONNECTED, LOGGED_IN }

var state: NetState = NetState.OFFLINE
var my_username: String = ""
# Multi-admin: '', 'admin', or 'owner'. Set from login_ok.player_data and
# live-updated via the admin_rank_changed server push. HUD reads this to
# decide whether to enable admin chat commands and the F10 panel.
var my_admin_rank: String = ""

var _ws:            WebSocketPeer = WebSocketPeer.new()
var _server_url:    String        = "ws://147.185.221.211:21498"
var _other_players: Dictionary    = {}   # server_id → OtherPlayer Node2D
var _move_timer:    float         = 0.0
var _save_timer:    float         = 0.0
var _last_pos:      Vector2       = Vector2(-99999, -99999)
var _last_boat:     String        = ""
var _save_dirty:    bool          = false
var _dirty_timer:   float         = 0.0

const MOVE_INTERVAL := 0.1    # send position every 100 ms
const SAVE_INTERVAL := 30.0   # periodic auto-save fallback
const DIRTY_SAVE_DELAY := 2.0 # save this long after the last change (debounced)

# ── Lifecycle ──────────────────────────────────────────────────────────────────
func _ready() -> void:
	# Show login screen on game start (unless we're already in offline mode).
	_spawn_login_screen()
	# Persist promptly: any XP gain or inventory change schedules a debounced save.
	Events.xp_gained.connect(func(_skill: String, _amount: int) -> void: mark_dirty())
	Events.inventory_changed.connect(mark_dirty)

## Schedule a save shortly after the most recent change. Rapid changes coalesce
## into a single save so we never spam the server, while keeping the data-loss
## window to a couple of seconds rather than the full periodic interval.
func mark_dirty() -> void:
	_save_dirty  = true
	_dirty_timer = 0.0

func _process(delta: float) -> void:
	if state == NetState.OFFLINE:
		return

	_ws.poll()
	var ws_state := _ws.get_ready_state()

	match ws_state:
		WebSocketPeer.STATE_OPEN:
			if state == NetState.CONNECTING:
				state = NetState.CONNECTED
				connected_to_server.emit()
			_flush_packets()
			if state == NetState.LOGGED_IN:
				_move_timer += delta
				_save_timer += delta
				if _move_timer >= MOVE_INTERVAL:
					_move_timer = 0.0
					_sync_position()
				if _save_timer >= SAVE_INTERVAL:
					_save_timer = 0.0
					_save_to_server()
				if _save_dirty:
					_dirty_timer += delta
					if _dirty_timer >= DIRTY_SAVE_DELAY:
						_save_dirty  = false
						_dirty_timer = 0.0
						_save_to_server()

		WebSocketPeer.STATE_CLOSED:
			if state != NetState.OFFLINE:
				state = NetState.OFFLINE
				_other_players.clear()
				disconnected_from_server.emit()
				Events.chat_message.emit("[Server] Disconnected.")

		WebSocketPeer.STATE_CONNECTING:
			pass  # still waiting

# ── Public API ─────────────────────────────────────────────────────────────────
func connect_to_server(url: String) -> void:
	_server_url = url
	# The server sends the whole world state in one burst at login (all admin
	# entities, painted tiles, edits). Defaults (~64 KB / 2048 packets) overflow
	# and the socket closes, dropping the player to offline. Give it plenty of room.
	_ws.inbound_buffer_size  = 1 << 24   # 16 MB
	_ws.outbound_buffer_size = 1 << 22   # 4 MB
	_ws.max_queued_packets   = 32768
	var err := _ws.connect_to_url(url)
	if err != OK:
		Events.chat_message.emit("[Net] Connection failed (error %d)." % err)
		return
	state = NetState.CONNECTING

func send_login(username: String, password: String) -> void:
	_send({"type": "login", "username": username, "password": password})

func send_register(username: String, password: String) -> void:
	_send({"type": "register", "username": username, "password": password})

func send_set_appearance(appearance: Dictionary, equipment: Dictionary = {}) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "set_appearance", "appearance": appearance, "equipment": equipment})

func send_skill_action(action: String, node_type: String, skill: String,
		required_level: int, node_pos: Vector2) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({
		"type":           "skill_action",
		"action":         action,
		"node_type":      node_type,
		"skill":          skill,
		"required_level": required_level,
		"node_x":         node_pos.x,
		"node_y":         node_pos.y,
	})

func send_player_lookup(username: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "lookup_player", "username": username})

func send_chat(text: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "chat", "text": text})
	else:
		Events.chat_message.emit(text)

func send_task_queue(queue: Array) -> void:
	_send({"type": "set_task_queue", "queue": queue})

func send_ah_browse(search: String = "") -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "ah_browse", "search": search})

func send_ah_my_listings() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "ah_my_listings"})

func send_ah_list(item_id: String, item_name: String, qty: int, price_each: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "ah_list", "item_id": item_id, "item_name": item_name,
			   "qty": qty, "price_each": price_each})

func send_ah_buy(listing_id: String, qty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "ah_buy", "listing_id": listing_id, "qty": qty})

func send_ah_cancel(listing_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "ah_cancel", "listing_id": listing_id})

func send_trade_request(to_username: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "trade_request", "to": to_username})

func send_trade_accept(from_username: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "trade_accept", "from": from_username})

func send_trade_offer(items: Array, gold: int = 0) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "trade_offer", "items": items, "gold": gold})

func send_trade_lock() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "trade_lock"})

func send_trade_confirm() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "trade_confirm"})

func send_trade_cancel() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "trade_cancel"})

func send_friends_list() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "friends_list"})

func send_friend_request(target: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "friend_request", "target": target})

func send_friend_accept(from_username: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "friend_accept", "from": from_username})

func send_friend_decline(from_username: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "friend_decline", "from": from_username})

func send_friend_remove(target: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "friend_remove", "target": target})

func send_whisper(to_username: String, text: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "whisper", "to": to_username, "text": text})

# ── Admin (Busterrdust only) ─────────────────────────────────────────────────
## Cached on receipt of the login `world_entities` bulk message so the World
## scene (which loads after login) can pick them up even if it missed the packet.
var world_entities_cache: Array = []

func send_admin_place(kind: String, subtype: String, x: float, y: float, data: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_place", "kind": kind, "subtype": subtype,
			   "x": x, "y": y, "data": data})

func send_admin_delete(entity_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_delete", "id": entity_id})

func send_admin_move(entity_id: String, x: float, y: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_move", "id": entity_id, "x": x, "y": y})

func send_admin_gold(target: String, amount: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_gold", "target": target, "amount": amount})

func send_admin_spawn(subtype: String, level: int, x: float, y: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_spawn", "subtype": subtype, "level": level, "x": x, "y": y})

## Player died — server applies the keep-4-drop-rest + 25%-gold-pile
## economics and broadcasts world drops. Sent BEFORE the local respawn
## so the death position is the player's last live position, not the
## respawn point.
func send_player_died(x: float, y: float) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "player_died", "x": x, "y": y})

## Player dropped an item from inventory. Server validates inventory contents
## and broadcasts to others so the drop is visible world-wide. Local client
## already spawned its own LootDrop for immediate feedback; server echo is
## suppressed back to the sender by the existing _broadcast_near targeting.
func send_player_drop(item_id: String, item_name: String, qty: int,
		color: Color, x: float, y: float) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "player_drop",
		"item_id": item_id, "item_name": item_name, "qty": qty,
		"color": [color.r, color.g, color.b, color.a],
		"x": x, "y": y})

## Quest RPCs. Server validates everything; client just routes the action.
## Server replies via the quest_state message, which is handled by the
## central receive switch and populates GameManager.

func send_quest_accept(quest_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "quest_accept", "quest_id": quest_id})

func send_quest_complete(quest_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "quest_complete", "quest_id": quest_id})

func send_quest_abandon(quest_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "quest_abandon", "quest_id": quest_id})

func send_quest_talk(npc_name: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "quest_talk", "npc_name": npc_name})

# ── Admin item management ─────────────────────────────────────────────────────
# Five RPCs backing the AdminPanel "Items" tab and the chat shortcuts
# (/give /take /restore /inv). Server replies surface through Events signals
# (admin_player_list_received, admin_inventory_view_received) or the inventory
# replacement broadcast (admin_inventory_set, handled in the receive switch).

func send_admin_give_item(target: String, item_id: String, item_name: String,
		qty: int, color: Color) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({
		"type":    "admin_give_item",
		"target":  target,
		"item_id": item_id,
		"name":    item_name,
		"qty":     qty,
		"color":   [color.r, color.g, color.b, color.a],
	})

func send_admin_take_item(target: String, item_id: String, qty: int) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_take_item", "target": target, "item_id": item_id, "qty": qty})

func send_admin_view_inventory(target: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_view_inventory", "target": target})

func send_admin_list_players() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_list_players"})

func send_admin_restore_last_loss(target: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_restore_last_loss", "target": target})

# ── Shop economy (Phase 2 server / Phase 3 client) ───────────────────────────
# Four wire types backing the HUD shop panel. The server is authoritative on
# every transaction; the client never decrements local stock or local gold
# independently. Replies route through Events.shop_state_received /
# Events.shop_result_received plus the existing gold_set + admin_inventory_set
# pushes (reused unchanged).

func send_shop_open(npc_id: String, shop_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "shop_open", "npc_id": npc_id, "shop_id": shop_id})

func send_shop_buy(npc_id: String, item_id: String, qty: int) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "shop_buy", "npc_id": npc_id, "item_id": item_id, "qty": qty})

func send_shop_sell(npc_id: String, item_id: String, qty: int) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "shop_sell", "npc_id": npc_id, "item_id": item_id, "qty": qty})

func send_shop_close(npc_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "shop_close", "npc_id": npc_id})

# ── Gold piles (Phase 5 of the gold economy) ─────────────────────────────────
# Server-tracked piles spawned by monster_died. Client requests claim via
# this send; the server validates proximity (48 px) and credits gold via the
# existing gold_set push, then broadcasts gold_pile_remove to despawn the
# visual on every nearby client.

func send_gold_pile_pickup(pile_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "gold_pile_pickup", "id": pile_id})

# ── Interiors (Phase 6) ──────────────────────────────────────────────────────
# Client requests routed by door click (enter) or interior exit fixture (exit).
# Server validates and replies with interior_entered / interior_exited; Phase 7
# wires the InteriorCache + scene swap that responds to those signals.

func send_enter_interior(door_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "enter_interior", "door_id": door_id})

func send_exit_interior() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "exit_interior"})

func send_admin_tile_set(tx: int, ty: int, biome: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_set", "tx": tx, "ty": ty, "biome": biome})

func send_admin_tile_clear(tx: int, ty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_clear", "tx": tx, "ty": ty})

## Tells the server to flush its in-memory tile_overrides to tile_overrides.json
## right now (it normally autosaves every 30s when dirty). Wired to the admin
## Save Map button so the admin can force-persist mid-session.
func send_admin_save_map() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_save_map"})

func send_build_farm_plot(x: float, y: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "build_farm_plot", "x": x, "y": y})

func send_clan_info() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_info"})

func send_clan_create(clan_name: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_create", "name": clan_name})

func send_clan_invite(target: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_invite", "target": target})

func send_clan_accept(clan_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_accept", "clan_id": clan_id})

func send_clan_decline(from_username: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_decline", "from": from_username})

func send_clan_leave() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_leave"})

func send_clan_kick(target: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_kick", "target": target})

func send_clan_bank_deposit(item_id: String, qty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_bank_deposit", "item_id": item_id, "qty": qty})

func send_clan_bank_withdraw(item_id: String, qty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_bank_withdraw", "item_id": item_id, "qty": qty})

func send_gather_request(entity_id: String, x: float, y: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "gather_request", "id": entity_id, "x": x, "y": y})

func send_gather_complete(entity_id: String, regen: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "gather_complete", "id": entity_id, "regen": regen})

func send_gather_release(entity_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "gather_release", "id": entity_id})

func send_node_states(ids: Array) -> void:
	if state == NetState.LOGGED_IN and not ids.is_empty():
		_send({"type": "node_states", "ids": ids})

func send_monster_join(entity_id: String, x: float, y: float, max_hp: int, xp_reward: int,
		monster_type: String = "", level: int = 0, attack: int = 0) -> void:
	# Stage 1 of server-side AI — the new monster_type / level / attack
	# fields let the server seed hostility defaults (`chicken` / `rat` are
	# passive, everything else hostile), scale the aggro radius by level,
	# and pick a damage value for monster-initiated attacks. All three
	# parameters default to safe values so older callers still work; the
	# server falls back to a `rat`-ish entry when they're absent.
	if state == NetState.LOGGED_IN:
		_send({"type": "monster_join", "id": entity_id, "x": x, "y": y,
			   "max_hp": max_hp, "xp_reward": xp_reward,
			   "monster_type": monster_type, "level": level, "attack": attack})

func send_monster_damage(entity_id: String, amount: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "monster_damage", "id": entity_id, "amount": amount})

func send_monster_leave(entity_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "monster_leave", "id": entity_id})

func send_monster_states(ids: Array) -> void:
	if state == NetState.LOGGED_IN and not ids.is_empty():
		_send({"type": "monster_states", "ids": ids})

func go_offline() -> void:
	state = NetState.OFFLINE
	_ws.close()

## Save, hand off to the offline thrall simulation (the server starts it on
## disconnect from the already-synced task queue), drop remote players, then
## bring the login screen back without quitting the game.
func logout() -> void:
	if state == NetState.LOGGED_IN:
		# Stow an in-use boat back into the inventory so it isn't lost on logout.
		# If the bag is full, drop it as a world pickup at the player's feet
		# instead — same safety net as Player._dock_boat so a full-bag logout
		# never silently consumes the hull.
		if GameManager.current_boat != "":
			var bid: String = GameManager.current_boat
			var bdata: Dictionary = Boats.data(bid)
			var bname: String = str(bdata.get("name",
				bid.replace("_", " ").capitalize()))
			var wood:  Color  = bdata.get("wood", Color.SADDLE_BROWN)
			if GameManager.free_slots() > 0:
				GameManager.add_item(bid, bname, 1, wood)
			else:
				_drop_boat_pickup(bid, bname, wood)
				Events.chat_message.emit(
					"Inventory full — %s left where you stood." % bname)
			GameManager.current_boat = ""
			GameManager.current_boat_hp     = 0
			GameManager.current_boat_max_hp = 0
		_save_to_server()
		# Let the save packet flush before we close the socket.
		for _i in range(3):
			_ws.poll()
			await get_tree().process_frame
	_free_other_players()
	go_offline()
	my_username = ""
	my_admin_rank = ""
	_spawn_login_screen()

## Spawn a world LootDrop pickup at the player's current position for the
## supplied boat. Used by the logout-with-full-inventory path. Mirrors the
## Player._spawn_boat_pickup pattern (Area2D + LootDrop.gd script + setup),
## parented to the player's parent so it lands in the world scene next to
## the other loot drops.
func _drop_boat_pickup(bid: String, bname: String, wood: Color) -> void:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return  # no anchor node — caller falls through to the lost case
	var p := players[0] as Node2D
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = p.global_position
	p.get_parent().add_child(ld)
	(ld as Area2D).call("setup", bid, bname, 1, wood)

## Spawn a world LootDrop at world-coords (x, y) for an arbitrary item.
## Called from the player_drop_spawned receive branch and from any future
## server broadcast that wants to drop a generic item in the world. Color
## arrives as a 4-tuple list from JSON; we normalize back to Color here.
func _spawn_world_drop(item_id: String, item_name: String, qty: int,
		color: Variant, x: float, y: float) -> void:
	if item_id == "" or qty <= 0:
		return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var col: Color
	if color is Color:
		col = color
	elif color is Array and (color as Array).size() >= 3:
		var ca := color as Array
		col = Color(float(ca[0]), float(ca[1]), float(ca[2]),
			float(ca[3]) if ca.size() >= 4 else 1.0)
	else:
		col = Color(0.7, 0.7, 0.7)
	var anchor := players[0] as Node2D
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = Vector2(x, y)
	anchor.get_parent().add_child(ld)
	(ld as Area2D).call("setup", item_id, item_name, qty, col)

func _free_other_players() -> void:
	for pid: String in _other_players.keys():
		var op := _other_players[pid] as Node2D
		if is_instance_valid(op):
			op.queue_free()
	_other_players.clear()

# ── Internal send/receive ──────────────────────────────────────────────────────
func _send(msg: Dictionary) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))

func _flush_packets() -> void:
	while _ws.get_available_packet_count() > 0:
		var raw := _ws.get_packet().get_string_from_utf8()
		var msg: Variant = JSON.parse_string(raw)
		if msg is Dictionary:
			_handle(msg as Dictionary)

func _handle(msg: Dictionary) -> void:
	var t: String = msg.get("type", "")
	match t:
		"login_ok":
			state = NetState.LOGGED_IN
			_save_timer = 0.0
			var pdata := msg.get("player_data", {}) as Dictionary
			my_username = str(pdata.get("username", ""))
			my_admin_rank = str(pdata.get("admin_rank", ""))
			ThrallManager.populate_from_server(pdata)
			var idle_sum: Variant = pdata.get("idle_summary", null)
			if idle_sum != null and idle_sum is Dictionary:
				Events.idle_summary.emit(idle_sum as Dictionary)
			login_ok.emit(pdata)

		"login_fail":
			login_fail.emit(str(msg.get("reason", "Login failed.")))

		"admin_rank_changed":
			# Owner used /promote or /demote on us mid-session. Update the
			# cached rank so the next /command attempt or F10 press reflects
			# the new rights immediately; emit the signal so World can
			# spawn or tear down the F10 panel without a relogin.
			my_admin_rank = str(msg.get("rank", ""))
			admin_rank_changed.emit(my_admin_rank)

		"register_ok":
			register_ok.emit()

		"register_fail":
			register_fail.emit(str(msg.get("reason", "Register failed.")))

		"kicked":
			state = NetState.CONNECTED
			kicked.emit(str(msg.get("reason", "")))

		"player_join":
			_add_other_player(msg)

		"player_leave":
			_remove_other_player(str(msg.get("id", "")))

		"player_move":
			_move_other_player(msg)

		"player_appearance":
			var apid := str(msg.get("id", ""))
			if _other_players.has(apid):
				var aop := _other_players[apid] as Node2D
				aop.set_meta("appearance", msg.get("appearance", {}))
				aop.set_meta("equipment",  msg.get("equipment", {}))
				aop.queue_redraw()

		"skill_result":
			if not (msg.get("ok") as bool):
				Events.chat_message.emit("[Server] " + str(msg.get("reason", "Action denied.")))

		"request_save":
			_save_to_server()

		"chat":
			var uname := str(msg.get("username", "?"))
			var text  := str(msg.get("text", ""))
			Events.chat_message.emit("%s: %s" % [uname, text])

		"player_idle":
			var pid := str(msg.get("id", ""))
			if _other_players.has(pid):
				(_other_players[pid] as Node2D).call("set_idle", true)
			else:
				_add_other_player(msg)
				if _other_players.has(pid):
					(_other_players[pid] as Node2D).call("set_idle", true)

		"idle_move":
			var pid := str(msg.get("id", ""))
			if _other_players.has(pid):
				var op := _other_players[pid] as Node2D
				var nx := float(msg.get("x", op.global_position.x))
				var ny := float(msg.get("y", op.global_position.y))
				op.set_meta("target_pos", Vector2(nx, ny))

		"player_lookup":
			Events.player_lookup_result.emit(msg)

		"error":
			Events.chat_message.emit("[Server] " + str(msg.get("reason", "Unknown error.")))

		"ah_listings":
			Events.ah_listings_updated.emit(msg.get("listings", []) as Array)

		"ah_my_listings":
			Events.ah_my_listings_updated.emit(msg.get("listings", []) as Array)

		"ah_purchase_result":
			var ok: bool = bool(msg.get("ok", false))
			if ok:
				GameManager.gold = int(msg.get("gold", GameManager.gold))
				var inv: Variant = msg.get("inventory", null)
				if inv is Array:
					GameManager.inventory.clear()
					for item: Variant in (inv as Array):
						if item is Dictionary:
							GameManager.inventory.append(item as Dictionary)
					Events.inventory_changed.emit()
			Events.ah_purchase_result.emit(ok, str(msg.get("reason", "")))

		"ah_list_result":
			var ok: bool = bool(msg.get("ok", false))
			if ok:
				var inv: Variant = msg.get("inventory", null)
				if inv is Array:
					GameManager.inventory.clear()
					for item: Variant in (inv as Array):
						if item is Dictionary:
							GameManager.inventory.append(item as Dictionary)
					Events.inventory_changed.emit()
			Events.ah_list_result.emit(ok, str(msg.get("reason", "")))

		"ah_cancel_result":
			var ok: bool = bool(msg.get("ok", false))
			if ok:
				var inv: Variant = msg.get("inventory", null)
				if inv is Array:
					GameManager.inventory.clear()
					for item: Variant in (inv as Array):
						if item is Dictionary:
							GameManager.inventory.append(item as Dictionary)
					Events.inventory_changed.emit()
			Events.ah_cancel_result.emit(ok, str(msg.get("reason", "")))

		"trade_request":
			Events.trade_request_received.emit(str(msg.get("from", "")))

		"trade_offer":
			var their := msg.get("their_items", []) as Array
			var mine  := msg.get("your_items",  []) as Array
			Events.trade_offer_updated.emit(their, mine,
				int(msg.get("their_gold", 0)), int(msg.get("your_gold", 0)))

		"trade_status":
			var their_lock := bool(msg.get("their_lock", false))
			var your_lock  := bool(msg.get("your_lock",  false))
			Events.trade_confirmed.emit(their_lock, your_lock)

		"trade_complete":
			var inv: Variant = msg.get("inventory", null)
			if inv is Array:
				GameManager.inventory.clear()
				for item: Variant in (inv as Array):
					if item is Dictionary:
						GameManager.inventory.append(item as Dictionary)
			if msg.has("gold"):
				GameManager.gold = int(msg.get("gold", GameManager.gold))
			Events.inventory_changed.emit()
			Events.trade_completed.emit()

		"trade_cancel":
			Events.trade_cancelled.emit(str(msg.get("reason", "Trade cancelled.")))

		"gather_grant":
			Events.gather_granted.emit(str(msg.get("id", "")))

		"gather_busy":
			Events.gather_denied.emit(str(msg.get("id", "")))

		"node_locked":
			Events.node_remote_locked.emit(str(msg.get("id", "")), str(msg.get("username", "")))

		"node_unlocked":
			Events.node_remote_unlocked.emit(str(msg.get("id", "")))

		"node_depleted":
			Events.node_remote_depleted.emit(str(msg.get("id", "")), float(msg.get("respawn_in", 30.0)))

		"node_respawned":
			Events.node_remote_respawned.emit(str(msg.get("id", "")))

		"node_states":
			Events.node_states_received.emit(msg.get("nodes", []) as Array)

		"monster_state":
			Events.mob_state.emit(str(msg.get("id", "")),
				int(msg.get("hp", 0)), int(msg.get("max_hp", 1)))

		"monster_hit":
			Events.mob_hit.emit(str(msg.get("id", "")),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)),
				int(msg.get("amount", 0)), str(msg.get("by", "")),
				int(msg.get("hp", 0)), int(msg.get("max_hp", 1)))

		"monster_died":
			# xp_recipients defaults to participants for old server builds
			# that haven't shipped the eligibility-fix patch yet — keeps the
			# client compatible with both versions during the rollout.
			var xpr: Variant = msg.get("xp_recipients",
				msg.get("participants", []))
			Events.mob_died.emit(str(msg.get("id", "")), str(msg.get("killer", "")),
				int(msg.get("xp_each", 0)),
				msg.get("participants", []) as Array,
				xpr as Array)

		"monster_respawned":
			Events.mob_respawned.emit(str(msg.get("id", "")))

		"monster_dead":
			Events.mob_dead_on_join.emit(str(msg.get("id", "")), float(msg.get("respawn_in", 0.0)))

		"monster_full":
			Events.mob_full.emit(str(msg.get("id", "")))

		"monster_states":
			Events.mob_states_received.emit(msg.get("nodes", []) as Array)

		"monster_pos_update":
			# Stage 2 of server AI — batched position broadcast (one msg
			# per server tick, interest-filtered to nearby monsters).
			# Sanitize into a typed Array[Dictionary] before forwarding so
			# the World.gd handler can rely on the shape without re-checking.
			var raw_updates: Variant = msg.get("updates", [])
			var upd_arr: Array = []
			if raw_updates is Array:
				for u: Variant in (raw_updates as Array):
					if u is Dictionary:
						upd_arr.append(u as Dictionary)
			if not upd_arr.is_empty():
				Events.mob_positions_updated.emit(upd_arr)

		"monster_attack":
			# Stage 2 of server AI — monster initiated an attack on a
			# player. If we're the target, apply the damage locally;
			# GameManager.take_damage already emits player_hp_changed and
			# fires player_died at 0 HP, so no extra signaling needed.
			# Broadcasts for other players are received but ignored — a
			# future stage can show floating damage numbers above their
			# heads using the same payload.
			var target_uname := str(msg.get("target", ""))
			if target_uname != "" and target_uname == my_username:
				var dmg := int(msg.get("damage", 0))
				if dmg > 0:
					GameManager.take_damage(dmg)

		"friend_request":
			Events.friend_request_received.emit(str(msg.get("from", "")))

		"friends_list":
			Events.friends_list_updated.emit(msg.get("friends", []) as Array)

		"clan_info":
			var c: Variant = msg.get("clan", null)
			Events.clan_info_updated.emit((c as Dictionary) if c is Dictionary else {})

		"clan_invite":
			Events.clan_invite_received.emit(
				str(msg.get("from", "")), str(msg.get("clan_name", "")), str(msg.get("clan_id", "")))

		"clan_result":
			var ok: bool = bool(msg.get("ok", false))
			if msg.has("gold"):
				GameManager.gold = int(msg.get("gold", GameManager.gold))
				Events.inventory_changed.emit()
			var reason := str(msg.get("reason", ""))
			if not reason.is_empty():
				Events.chat_message.emit("[Clan] " + reason)
			Events.clan_result.emit(ok, reason)

		"world_entities":
			world_entities_cache = msg.get("entities", []) as Array
			Events.world_entities_received.emit(world_entities_cache)

		"world_entity_add":
			var ent: Variant = msg.get("entity", null)
			if ent is Dictionary:
				world_entities_cache.append(ent)
				Events.world_entity_added.emit(ent as Dictionary)

		"world_entity_remove":
			var rid := str(msg.get("id", ""))
			for i in range(world_entities_cache.size() - 1, -1, -1):
				if str((world_entities_cache[i] as Dictionary).get("id", "")) == rid:
					world_entities_cache.remove_at(i)
			Events.world_entity_removed.emit(rid)

		"world_entity_move":
			var emid := str(msg.get("id", ""))
			var emx := float(msg.get("x", 0.0))
			var emy := float(msg.get("y", 0.0))
			for e: Variant in world_entities_cache:
				if str((e as Dictionary).get("id", "")) == emid:
					(e as Dictionary)["x"] = emx
					(e as Dictionary)["y"] = emy
			Events.world_entity_moved.emit(emid, emx, emy)

		"gold_set":
			GameManager.gold = int(msg.get("gold", GameManager.gold))
			Events.inventory_changed.emit()

		"tile_overrides":
			Events.tile_overrides_received.emit(msg.get("overrides", []) as Array)

		"tile_set":
			Events.tile_override_set.emit(int(msg.get("tx", 0)), int(msg.get("ty", 0)),
				str(msg.get("biome", "plains")))

		"tile_clear":
			Events.tile_override_cleared.emit(int(msg.get("tx", 0)), int(msg.get("ty", 0)))

		"entity_edits":
			Events.entity_edits_received.emit(msg.get("edits", []) as Array)

		"entity_edit":
			Events.entity_edit_applied.emit(str(msg.get("id", "")),
				bool(msg.get("deleted", false)),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))

		"clan_bank_result":
			var inv: Variant = msg.get("inventory", null)
			if inv is Array:
				GameManager.inventory.clear()
				for item: Variant in (inv as Array):
					if item is Dictionary:
						GameManager.inventory.append(item as Dictionary)
				Events.inventory_changed.emit()

		"admin_inventory_set":
			# Sent to the RECIPIENT of an admin give/take/restore so the
			# client's local inventory matches the server's authoritative
			# copy. Same shape as clan_bank_result.
			var ainv: Variant = msg.get("inventory", null)
			if ainv is Array:
				GameManager.inventory.clear()
				for item: Variant in (ainv as Array):
					if item is Dictionary:
						GameManager.inventory.append(item as Dictionary)
				Events.inventory_changed.emit()

		"admin_player_list":
			var raw: Variant = msg.get("players", [])
			var names: Array = []
			if raw is Array:
				for n: Variant in (raw as Array):
					names.append(str(n))
			Events.admin_player_list_received.emit(names)

		"admin_inventory_view":
			var iraw: Variant = msg.get("inventory", [])
			var items: Array = []
			if iraw is Array:
				for it: Variant in (iraw as Array):
					if it is Dictionary:
						items.append(it as Dictionary)
			Events.admin_inventory_view_received.emit(
				str(msg.get("target", "")),
				bool(msg.get("online", false)),
				items)

		"shop_state":
			# Phase 3 — server reply to shop_open. Pass the whole msg as the
			# payload so the HUD can read shop_name, multipliers, and stock.
			Events.shop_state_received.emit(msg as Dictionary)

		"shop_result":
			# Phase 3 — server reply to shop_buy / shop_sell. ok=true with
			# current_stock means the transaction landed; ok=false carries a
			# reason for the chat log. Gold + inventory updates arrive on
			# separate gold_set + admin_inventory_set messages already wired.
			Events.shop_result_received.emit(msg as Dictionary)

		"quest_state":
			# Full quest snapshot pushed after accept / complete / abandon /
			# progress changes. Single source of truth — client mirrors the
			# whole payload onto GameManager and emits one change signal so
			# the QuestLog + marker renderer can refresh idempotently.
			GameManager.apply_quest_state(msg as Dictionary)

		"gold_pile_spawn":
			# Phase 5 — server-tracked gold pile broadcast on monster death.
			# World.gd listens to spawn a LootDrop with the pile_id; clicking
			# it sends gold_pile_pickup back to the server.
			Events.gold_pile_spawn.emit(
				str(msg.get("id", "")),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)),
				int(msg.get("amount", 0)))

		"gold_pile_remove":
			Events.gold_pile_remove.emit(str(msg.get("id", "")))

		"player_drop_spawned":
			# Another player dropped an item from their inventory. Spawn a
			# matching LootDrop in our world so we can see/pick it up. The
			# server suppresses echo to the sender — only OTHER clients ever
			# see this message.
			_spawn_world_drop(
				str(msg.get("item_id", "")),
				str(msg.get("item_name", "")),
				int(msg.get("qty", 1)),
				msg.get("color", [0.7, 0.7, 0.7, 1.0]),
				float(msg.get("x", 0.0)),
				float(msg.get("y", 0.0)))

		"interior_entered":
			# Phase 6 reply to enter_interior. Phase 7's InteriorCache
			# listens to swap scenes; Phase 6 just surfaces the event.
			Events.interior_entered.emit(
				str(msg.get("interior_id", "")),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)),
				float(msg.get("return_x", 0.0)),
				float(msg.get("return_y", 0.0)))

		"interior_exited":
			Events.interior_exited.emit(
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))

		"interior_error":
			# Surfaces "you're too far from the door" / "you're not inside"
			# etc. through the standard chat channel so the player sees
			# why their click didn't open anything.
			Events.interior_error.emit(str(msg.get("reason", "Interior error.")))
			Events.chat_message.emit(str(msg.get("reason", "Interior error.")))

# ── Position sync ──────────────────────────────────────────────────────────────
func _sync_position() -> void:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var pos := (players[0] as Node2D).global_position
	var boat: String = GameManager.current_boat
	if pos.distance_squared_to(_last_pos) > 4.0 or boat != _last_boat:
		_last_pos  = pos
		_last_boat = boat
		_send({"type": "move", "x": pos.x, "y": pos.y, "boat": boat})

# ── Save to server ─────────────────────────────────────────────────────────────
func _save_to_server() -> void:
	_send({
		"type":      "save",
		"skill_xp":  GameManager.player_skill_xp,
		"inventory": GameManager.inventory,
		"bank":      GameManager.bank_inventory,
		"equipment": GameManager.equipment,
	})

# ── Other player management ────────────────────────────────────────────────────
func _add_other_player(msg: Dictionary) -> void:
	var pid: String = str(msg.get("id", ""))
	if pid.is_empty() or _other_players.has(pid):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var uname   := str(msg.get("username", "?"))
	var is_idle := bool(msg.get("idle", false))
	var op: Node2D = (load("res://scripts/OtherPlayer.gd") as GDScript).new() as Node2D
	op.set_meta("server_id", pid)
	op.set_meta("username",  uname)
	op.set_meta("is_idle",   is_idle)
	op.set_meta("appearance", msg.get("appearance", {}))
	op.set_meta("equipment",  msg.get("equipment", {}))
	op.position = Vector2(float(msg.get("x", 0)), float(msg.get("y", 0)))
	scene.add_child(op)
	_other_players[pid] = op
	if not is_idle:
		Events.chat_message.emit("[%s has entered the realm]" % uname)

func _remove_other_player(pid: String) -> void:
	if _other_players.has(pid):
		var uname := str((_other_players[pid] as Node2D).get_meta("username", "?"))
		_other_players[pid].queue_free()
		_other_players.erase(pid)
		Events.chat_message.emit("[%s has left the realm]" % uname)

func _move_other_player(msg: Dictionary) -> void:
	var pid: String = str(msg.get("id", ""))
	if _other_players.has(pid):
		var op := _other_players[pid] as Node2D
		var nx := float(msg.get("x", op.global_position.x))
		var ny := float(msg.get("y", op.global_position.y))
		op.set_meta("target_pos", Vector2(nx, ny))
		op.set_meta("boat", str(msg.get("boat", "")))

# ── Login screen ───────────────────────────────────────────────────────────────
func _spawn_login_screen() -> void:
	var ls := CanvasLayer.new()
	ls.set_script(load("res://scripts/LoginScreen.gd"))
	add_child(ls)
