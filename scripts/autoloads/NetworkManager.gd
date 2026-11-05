extends Node

## WebSocket client autoload.
## Connects to the VikingVale multiplayer server, handles login,
## syncs position, and manages other-player nodes.

const Boats = preload("res://scripts/Boat.gd")

# ── Signals ────────────────────────────────────────────────────────────────────
signal connected_to_server()
signal disconnected_from_server()
## Emitted ONLY when an in-game (LOGGED_IN) socket drops unexpectedly — a real
## mid-play disconnect (server restart/crash), not an intentional "play offline"
## or logout. Consumers freeze the local player + show a reconnect overlay so
## the player can't keep walking through a dead world (Phase 7).
signal connection_lost(server_restarting: bool)
signal login_ok(player_data: Dictionary)
signal admin_rank_changed(rank: String)
## PvP — flag broadcasts + attack results. `pvp_hit_taken` is what the
## defender's local Player.gd hooks to apply damage; `pvp_hit_confirm` is
## the attacker's feedback for the combat log; `pvp_flag_changed` updates
## OtherPlayer name tint. `pvp_reject` surfaces server errors (out of
## range, not flagged, target offline).
# Player ids are TEXT hex tokens (players.id) — NOT integers. Passing them as
# String is mandatory: int()-ing a hex id collapses it to 0, which made the
# flag match every player (0==0) and attacks target session id 0 ("not online").
signal pvp_hit_taken(attacker_id: String, attacker_username: String, damage: int, style: String)
signal pvp_hit_confirm(target_id: String, damage: int)
signal pvp_flag_changed(id: String, username: String, flagged: bool)
signal pvp_reject(reason: String)
signal pvp_locked(remaining: int)
## PvP loot piles — spawn/remove/pickup-grant. `pvp_pile_spawn` fires on
## every nearby client so LootDrops materialise for everyone; the pickup
## flow mirrors gold piles with the ok+remove pair.
signal pvp_pile_spawn(id: String, x: float, y: float, item_id: String, item_name: String, qty: int, color: Color)
signal pvp_pile_remove(id: String)
signal pvp_pile_pickup_ok(item_id: String, item_name: String, qty: int, color: Color)
## Farming — server-authoritative plot stage + harvest grants.
signal farm_plot_state(entity_id: String, stage: int, seed_id: String, grow: float, eff: float, boost: float)
signal farm_plot_burst(plots: Array)
signal farm_harvest_ok(entity_id: String, item_id: String, item_name: String, qty: int, xp: int, seed_id: String)
signal farm_harvest_fail(entity_id: String, seed_id: String, reason: String, xp: int)
signal farm_reject(reason: String, seed_id: String)
## Monster projectile — ranged/magic monsters broadcast this alongside
## the standard monster_attack so the client can draw the visual shot.
## Damage still lands via monster_attack. `spread_orbs > 1` (e.g. nidhogg
## fire breath) tells the visual to spawn multiple orbs in a tight fan.
signal monster_projectile(entity_id: String, from_x: float, from_y: float, to_x: float, to_y: float, style: String, color: Color, spread_orbs: int)
## Kill credit — server sends this to the killer's ws when the victim's
## pvp_death arrives. `style` is the melee/ranged/magic skill to grant XP
## in; `xp` is the amount; `victim_username` is for the combat log line.
signal pvp_kill_credit(style: String, xp: int, victim_username: String)
## PvP-Token currency (Phase 1d) — server-owned balance + gear upgrade results.
## pvp_tokens_set: authoritative new balance (login/kill/admin/upgrade).
## token_upgrade_ok: the server approved + minted an upgraded item id.
## token_upgrade_reject: the server refused (reason for the player).
signal pvp_tokens_set(balance: int)
signal token_upgrade_ok(slot: String, old_id: String, new_id: String, level: int, balance: int)
signal token_upgrade_reject(reason: String, balance: int)
signal login_fail(reason: String)
signal register_ok()
signal register_fail(reason: String)
signal kicked(reason: String)
# Password recovery (Phase C handlers)
signal request_password_reset_ok(message: String)
signal verify_password_reset_token_result(ok: bool)
signal complete_password_reset_ok(username: String)
signal complete_password_reset_fail(reason: String)
# Account self-service (Account section in SettingsPanel)
signal account_info(data: Dictionary)
signal change_email_ok(email: String)
signal change_email_fail(reason: String)
signal change_password_ok()
signal change_password_fail(reason: String)
# Backstory perk
signal backstory_set(backstory: String)
signal backstory_fail(reason: String)

# ── State ──────────────────────────────────────────────────────────────────────
enum NetState { OFFLINE, CONNECTING, CONNECTED, LOGGED_IN, SPECTATING }

var state: NetState = NetState.OFFLINE
## Read-only spectator mode (auto_studio recording). Launched with
## `--spectate <username>`: we connect, send a `spectate` message (never a
## login), render the world via the normal OtherPlayer path, and the camera
## follows the target entity. A spectator NEVER sends moves/saves/actions —
## it holds no play session, so it can't affect game state.
var spectating: bool = false
## True when launched with `--autoplay` — this client plays ITSELF (real movement,
## gather, craft, combat) so a recording of it looks like a real player. World
## spawns the AutoPlay AI once we're logged in and in the world.
var autoplay: bool = false
## Username to follow (as typed on the command line; matched case-insensitively).
var spectate_target: String = ""
## Resolved player id of the target. Filled from the server's `spectate_ok`
## reply, or discovered from the first matching player_join if the target was
## offline at connect time.
var spectate_target_id: String = ""
## The watched player's shown-off state for the spectator HUD (server `spectate_state`):
## {skill_xp, inventory, equipment}. Drives health/level + wielded gear + inventory.
var spectate_state: Dictionary = {}
## True between an unexpected in-game disconnect and the next successful login.
## Player.gd freezes movement while this is set (Phase 7). Never set by the
## intentional offline/logout paths — only by a dropped LOGGED_IN socket.
var lost_connection: bool = false
## Set when the server told us it's restarting (server_shutdown message) just
## before the socket closed, so the overlay can say "restarting" vs "lost".
var _server_restarting: bool = false
var my_username: String = ""
## Set by an INTENTIONAL logout so the login screen that respawns does NOT
## auto-login again this session — the player asked to switch accounts, so they
## stay on the login screen. Runtime-only (resets on app restart), so auto-login
## resumes next launch. A dropped connection does NOT set this (seamless reconnect).
var suppress_auto_login: bool = false
# Multi-admin: '', 'admin', or 'owner'. Set from login_ok.player_data and
# live-updated via the admin_rank_changed server push. HUD reads this to
# decide whether to enable admin chat commands and the F10 panel.
var my_admin_rank: String = ""

var _ws:            WebSocketPeer = WebSocketPeer.new()
var _server_url:    String        = "wss://play.busterrdust.com"   # Cloudflare; LoginScreen falls back to Playit
var _other_players: Dictionary    = {}   # server_id → OtherPlayer Node2D (lives in the World scene)
## Cached join data per player (username/appearance/pos/…), kept current by moves.
## OtherPlayer NODES are children of the current scene, so a 2D↔3D toggle frees them
## and the server won't re-send already-present players → the switcher would go blind.
## `reattach_other_players()` (called by each World on load) rebuilds them from here.
var _player_roster: Dictionary    = {}   # server_id → last join msg (Dictionary)
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
	# Spectator launch (auto_studio): `VikingVale.exe --spectate <username>`
	# connects as a silent read-only observer instead of showing the login
	# screen. Optional `--server <addr>` overrides the target server.
	if _parse_spectate_args():
		var url := _server_url
		var srv := _cmdline_value("--server")
		if not srv.is_empty():
			url = srv if (srv.begins_with("ws://") or srv.begins_with("wss://")) else "ws://" + srv
		# Fire the spectate handshake as soon as the socket opens.
		connected_to_server.connect(_on_spectator_connected, CONNECT_ONE_SHOT)
		connect_to_server(url)
		return
	# Autoplay launch (content pipeline): `VikingVale.exe --autoplay [--account user:pass]`.
	# A REAL client that logs in and PLAYS ITSELF — recording the window looks like
	# (is) a real player. With --account it logs in headlessly (skip the login
	# screen); World spawns the AutoPlay AI once the player is in the world.
	if _has_flag("--autoplay"):
		autoplay = true
		var acct := _cmdline_value("--account")
		if not acct.is_empty() and acct.contains(":"):
			var parts := acct.split(":", true, 1)
			var au := str(parts[0]).strip_edges()
			var ap := str(parts[1]) if parts.size() > 1 else ""
			connected_to_server.connect(
				func() -> void: send_login(au, ap), CONNECT_ONE_SHOT)
			connect_to_server(_server_url)
			return
		# No explicit account — fall through to the normal login screen; the
		# auto-login toggle (if the player set it) will sign in automatically.
	# Show login screen on game start (unless we're already in offline mode).
	_spawn_login_screen()
	# Reconnect path: a real mid-game disconnect brings the login screen back so
	# the (now frozen) player can re-authenticate. Reuses the logout→login flow.
	connection_lost.connect(func(_restarting: bool) -> void: _ensure_login_screen())
	# Persist promptly: any XP gain or inventory change schedules a debounced save.
	Events.xp_gained.connect(func(_skill: String, _amount: int) -> void: mark_dirty())
	Events.inventory_changed.connect(mark_dirty)
	# Report HP fraction (throttled) so the town watch only helps when we're in real
	# trouble (≤60%), instead of one-shotting every monster we engage.
	Events.player_hp_changed.connect(_on_player_hp_changed)

var _hp_send_at: float = 0.0
func _on_player_hp_changed(cur: int, mx: int) -> void:
	if state != NetState.LOGGED_IN:
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - _hp_send_at < 0.4:
		return
	_hp_send_at = now
	_send({"type": "player_hp", "frac": float(cur) / float(maxi(1, mx))})

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
				# Was the player actively in-world? Then this is a real drop,
				# not a failed connect attempt — freeze + reconnect overlay.
				var was_playing := (state == NetState.LOGGED_IN)
				state = NetState.OFFLINE
				_other_players.clear()
				disconnected_from_server.emit()
				if was_playing:
					lost_connection = true
					connection_lost.emit(_server_restarting)
					Events.chat_message.emit("[Server] Connection lost."
						+ (" Server is restarting…" if _server_restarting else ""))
				else:
					Events.chat_message.emit("[Server] Disconnected.")

		WebSocketPeer.STATE_CONNECTING:
			pass  # still waiting

# ── Spectator mode (read-only recording observer) ───────────────────────────────
## Scan the command line for `--spectate <username>`. Returns true (and arms
## spectator mode) when present. `OS.get_cmdline_args()` excludes the engine's
## own flags, so a bare `--spectate <name>` after the exe is what we see.
func _parse_spectate_args() -> bool:
	var val := _cmdline_value("--spectate")
	if val.is_empty():
		return false
	spectating       = true
	spectate_target  = val
	return true

## Value following `flag` on the command line, or "" if absent/last. Accepts
## both `--flag value` and `--flag=value` forms.
## True if a bare flag (e.g. `--autoplay`) is present on the command line.
func _has_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_args()

func _cmdline_value(flag: String) -> String:
	var args := OS.get_cmdline_args()
	for i in args.size():
		var a := str(args[i])
		if a == flag and i + 1 < args.size():
			return str(args[i + 1]).strip_edges()
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1).strip_edges()
	return ""

## Socket is open — send the spectate handshake (never a login) and drop into
## the read-only SPECTATING state so the per-frame move/save loop stays off.
func _on_spectator_connected() -> void:
	state = NetState.SPECTATING
	_send({"type": "spectate", "target": spectate_target})

## Live world position of the followed target, or null until it's visible.
## Matches by resolved id first, then by username (so a target that logs in
## after we connect is picked up on its first join). Read by World.gd to drive
## the spectator camera + chunk streaming.
func get_spectate_target_pos() -> Variant:
	if not spectating:
		return null
	if not spectate_target_id.is_empty() and _other_players.has(spectate_target_id):
		return (_other_players[spectate_target_id] as Node2D).global_position
	var want := spectate_target.to_lower()
	for pid: String in _other_players:
		var op := _other_players[pid] as Node2D
		if str(op.get_meta("username", "")).to_lower() == want:
			spectate_target_id = pid   # cache for subsequent frames
			return op.global_position
	return null

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

## PvP wire — server mirrors the flag + gates attacks by mutual-flag +
## in-range. Client HUD calls these from the toggle chip / attack path.
func send_pvp_toggle(on: bool) -> void:
	_send({"type": "pvp_toggle", "on": on})

func send_pvp_attack(target_id: String, damage: int, style: String) -> void:
	_send({"type": "pvp_attack",
		"target_id": target_id, "damage": damage, "style": style})

## Request a token upgrade on a gear piece (Phase 1d). `item_id` is the piece's
## CURRENT id (may already carry a ~u suffix); `slot` is the equipped slot or ""
## when it's a backpack piece; `trait` is only used on the final (L4) step. The
## server validates the token balance, deducts, and replies token_upgrade_ok /
## token_upgrade_reject.
func send_token_upgrade(item_id: String, slot: String, trt: String = "") -> void:
	_send({"type": "token_upgrade",
		"item_id": item_id, "slot": slot, "trait": trt})

## Request fast travel to a discovered town (Phase 2b). The server owns the
## gold + validates the fee, then replies fast_travel_ok (with authoritative
## destination coords) or fast_travel_reject.
func send_fast_travel(town_id: String) -> void:
	_send({"type": "fast_travel", "town_id": town_id})

## Persist a fast-travel town unlock server-side (1-time, account-persistent).
func send_discover_town(town_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "discover_town", "town_id": town_id})

## Ask the server for the live rankings (Phase 3 #4). Reply → rankings_updated.
func send_rankings_request() -> void:
	_send({"type": "rankings_request"})

## Town standing (Phase 5a) — server replies with the full per-town snapshot.
## Also pushed automatically on login and after a quest that grants standing.
func send_reputation_request() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "reputation_request"})

## Damage a town NPC (Phase 5b). Server owns hp/death/respawn, applies the
## reputation penalty on a kill, and raises the city watch — the client never
## decides any of that. `name` lets the server resolve which town it belongs to.
func send_npc_damage(npc_id: String, npc_name: String, amount: int) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "npc_damage", "id": npc_id,
		"name": npc_name, "amount": amount})

## Raid a trade caravan (Phase 5c). Server owns hp/destruction/loot/standing and
## rejects the hit outright while the wagon is parked at a town.
func send_caravan_damage(caravan_id: String, amount: int) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "caravan_damage", "id": caravan_id, "amount": amount})

## Warband caravans (Phase 5c) — leader-only, server-validated (clan pool cost,
## cap, leadership). The server chats the outcome.
func send_warband_caravan_create() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "warband_caravan_create"})

func send_warband_caravan_disband() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "warband_caravan_disband"})

## Personal gold bank (Phase 3 #3) — server moves gold ↔ bank_gold and replies
## with gold_set + bank_gold_set (both server-authoritative).
func send_bank_gold_deposit(amount: int) -> void:
	_send({"type": "bank_gold_deposit", "amount": amount})

func send_bank_gold_withdraw(amount: int) -> void:
	_send({"type": "bank_gold_withdraw", "amount": amount})

## Notify server the local player just died in PvP. `drops` is the list of
## inventory items to spread on the ground (server auto-adds bones + one
## pvp_token). Position is snapshot at time-of-death.
func send_pvp_death(x: float, y: float, drops: Array) -> void:
	_send({"type": "pvp_death", "x": x, "y": y, "drops": drops})

## Extended death payload — carries killer info so the server can credit
## XP + a PvP token, plus current gold so the server can spawn the
## proportional gold pile at the death location.
func send_pvp_death_v2(x: float, y: float, drops: Array,
		killer_id: String, style: String, gold: int) -> void:
	_send({"type":       "pvp_death",
		"x":            x,
		"y":            y,
		"drops":        drops,
		"killer_id":    killer_id,
		"style":        style,
		"gold_carried": gold})

## Claim a PvP loot pile. First-click-wins is enforced server-side; the
## response comes back as pvp_pile_pickup_ok (grants the item) + a global
## pvp_pile_remove (frees the visual).
func send_pvp_pile_pickup(pile_id: String) -> void:
	_send({"type": "pvp_pile_pickup", "id": pile_id})

func send_login(username: String, password: String) -> void:
	_send({"type": "login", "username": username, "password": password})

func send_register(username: String, password: String, email: String = "") -> void:
	_send({"type": "register", "username": username, "password": password, "email": email})

# Account self-service (Account section in SettingsPanel)
func send_change_email(current_password: String, new_email: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "change_email", "current_password": current_password, "email": new_email})

func send_change_password(current_password: String, new_password: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "change_password",
		"current_password": current_password, "new_password": new_password})

func send_get_account_info() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "get_account_info"})

# Character backstory perk (Backstory.gd). One-shot pick — server rejects
# a second set. UI picker lives in BackstorySelectScreen.gd, opened from
# CharacterCreation when the login payload reports backstory == "".
func send_set_backstory(backstory: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "set_backstory", "backstory": backstory})

# Pet system — PetManager persists the type so re-login restores it.
func send_set_pet_type(pet_type: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "set_pet_type", "pet_type": pet_type})

# Seal of Kings — endgame event. seal_awaken asks the server to flip the
# statue to 'breaking' (requires all 5 tokens + not in ruling warband);
# seal_attack deals damage to a breaking statue. Both fail silently if
# requirements aren't met (server posts a chat message instead).
func send_seal_awaken() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "seal_awaken"})

func send_seal_attack(amount: int = 5) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "seal_attack", "amount": amount})

# Password recovery — three send methods matching the server handlers in
# server.py. The reset screen flow is: request → token email → user pastes
# token → verify (UX gate) → complete (commit new password).
func send_request_password_reset(username: String, email: String) -> void:
	_send({"type": "request_password_reset",
		"username": username, "email": email})

func send_verify_password_reset_token(token: String) -> void:
	_send({"type": "verify_password_reset_token", "token": token})

func send_complete_password_reset(token: String, new_password: String) -> void:
	_send({"type": "complete_password_reset",
		"token": token, "new_password": new_password})

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

# ── Thralls (Phase 10) ──────────────────────────────────────────────────────
func send_thralls_list() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "thralls_list"})

func send_thrall_assign(id: String, job: String, target: String, town: String = "") -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "thrall_assign", "id": id, "job": job,
			"target": target, "town": town})

func send_thrall_buy_slot() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "thrall_buy_slot"})

func send_thrall_backpack_deposit(id: String, item_id: String, qty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "thrall_backpack_deposit", "id": id, "item_id": item_id, "qty": qty})

func send_thrall_backpack_withdraw(id: String, item_id: String, qty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "thrall_backpack_withdraw", "id": id, "item_id": item_id, "qty": qty})

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
## Same idea for the admin tile-paint burst + pre-existing-entity edits (move/
## delete): the server sends each ONCE at login, so a scene switch (2D↔3D toggle)
## or late-loading world replays these caches instead of falling back to the
## bare procedural map. Kept current by the live tile_set/clear/bulk handlers.
var tile_overrides_cache: Array = []
var entity_edits_cache: Array = []
var terrain_heights_cache: Dictionary = {}   # idx_str → delta (admin sculpt; replayed on 2D↔3D switch)

## Keep tile_overrides_cache current when the admin paints live, so a scene switch
## mid-session restores those edits too. biome null/"" removes the tile (a clear).
func _update_tile_cache(tx: int, ty: int, biome: Variant) -> void:
	for i in range(tile_overrides_cache.size()):
		var d := tile_overrides_cache[i] as Dictionary
		if int(d.get("tx", -1)) == tx and int(d.get("ty", -1)) == ty:
			if biome == null or str(biome) == "":
				tile_overrides_cache.remove_at(i)
			else:
				d["biome"] = str(biome)
			return
	if biome != null and str(biome) != "":
		tile_overrides_cache.append({"tx": tx, "ty": ty, "biome": str(biome)})

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

func send_admin_rotate(entity_id: String, rot: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_rotate", "id": entity_id, "rot": rot})

## Live property edit of an admin-placed (a:) entity — `patch` carries only the
## changed data fields (level, display_name, quest_text, shop_id, …). The server
## merges it into the stored data JSON and re-emits the entity so it re-renders.
func send_admin_edit_entity(entity_id: String, patch: Dictionary) -> void:
	if state == NetState.LOGGED_IN and not entity_id.is_empty() and not patch.is_empty():
		_send({"type": "admin_edit_entity", "id": entity_id, "patch": patch})

func send_admin_sculpt(tiles: Dictionary) -> void:
	if state == NetState.LOGGED_IN and not tiles.is_empty():
		_send({"type": "admin_sculpt", "tiles": tiles})

## Push the whole admin-drawn road graph after an edit. Server persists it +
## broadcasts it back to everyone (so the graph is never client-local).
func send_admin_road_set(nodes: Array, edges: Array) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_road_set", "nodes": nodes, "edges": edges})

## The live OtherPlayer node for a username (mob_hit / combat carry usernames, but
## _other_players is keyed by pid) — used to play a remote attacker's swing.
func other_player_node_by_name(uname: String) -> Node:
	if uname == "":
		return null
	for pid: Variant in _other_players.keys():
		var op: Variant = _other_players[pid]
		if is_instance_valid(op) and str((op as Node).get_meta("username", "")) == uname:
			return op as Node
	return null

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

# Admin Accounts tab (Phase E)
func send_admin_list_accounts(query: String = "") -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_list_accounts", "query": query})

func send_admin_reset_password(username: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_reset_password", "username": username})

func send_admin_unlock_account(username: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_unlock_account", "username": username})

func send_admin_verify_email(username: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_verify_email", "username": username})

## Owner-only PERMANENT account deletion. Server re-checks _is_owner + refuses
## to delete the owner/self; the Accounts tab gates this behind a type-the-name
## confirm before calling.
func send_admin_delete_account(username: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_delete_account", "username": username})

## Owner-only mapper rank management — the Accounts tab surfaces these
## via per-row Grant / Revoke buttons. The server enforces owner-only;
## client just sends the request.
## Farming — plant a seed at a plot the player is standing near. Server
## validates and broadcasts the new stage; client removes the seed from
## inventory optimistically (server doesn't touch inventory since farm
## is client-authoritative on that front).
func send_farm_plant(entity_id: String, seed_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "farm_plant", "id": entity_id, "seed_id": seed_id})

func send_farm_water(entity_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "farm_water", "id": entity_id})

# Fishing biggest-catch leaderboard (1.6.3). Cached from the server on login +
# on each catch; the Rankings panel + Fishing Journal read these.
var fishing_records: Array = []   # [{species, name, weight, holder}] global bests
var fishing_journal: Array = []   # [{species, name, weight}] this player's bests

func send_fish_caught(species: String, species_name: String, weight: float, wnorm: float,
		xp: int = 0, color: Array = [], reeled: bool = false, bait_mult: float = 1.0) -> void:
	if state != NetState.LOGGED_IN:
		return
	# ⑥ — the server GRANTS the fish item + fishing XP + gold. `xp`/`color` are the
	# client's claim used only pre-bake; `reeled`/`bait_mult` scale XP post-bake.
	_send({"type": "fish_caught", "species": species, "species_name": species_name,
		"weight": weight, "wnorm": wnorm, "xp": xp, "color": color,
		"reeled": reeled, "bait_mult": bait_mult})

## ⑥ — upload the baked fish-species table (admin bake).
func send_admin_upload_fish(fish_map: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_upload_fish", "map": fish_map})

## ⑥ — upload the baked sea-monster loot table (admin bake).
func send_admin_upload_sea_loot(sea_map: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_upload_sea_loot", "map": sea_map})

## ⑥ — report a boat-fight WIN; the server grants the baked loot + XP. `claim` is
## the client's {name,xp_reward,loot} used only pre-bake. Client stops minting.
func send_sea_combat_win(monster_type: String, claim: Dictionary = {}) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "sea_combat_win", "monster_type": monster_type, "monster": claim})

func request_fishing_data() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "fishing_data_request"})

func send_farm_harvest(entity_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	# Farming level travels with the request so the server can roll the
	# success formula. Practice bonus is derived server-side from the
	# fresh recipe_counts snapshot (server picks the seed's key once it
	# looks the plot up in farm_plots).
	_send({"type":         "farm_harvest",
		"id":             entity_id,
		"farming_lv":     GameManager.get_skill_level("farming"),
		"recipe_counts":  GameManager.recipe_success_counts})

func send_admin_grant_mapper(username: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_grant_mapper", "username": username})

func send_admin_revoke_mapper(username: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_revoke_mapper", "username": username})

func send_admin_upload_terrain(bitmap_b64: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "admin_upload_terrain", "bitmap_b64": bitmap_b64})

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

func send_enter_interior(door_id: String, interior_id_hint: String = "") -> void:
	if state != NetState.LOGGED_IN:
		return
	# `interior_id_hint` covers hardcoded town buildings that live only
	# as client-side Interactable nodes with `t:N` ids (never inserted
	# into world_entities). Server tries the entity lookup first; if
	# that fails, it uses the hint as-is. Admin-placed buildings (in
	# world_entities) can leave the hint empty.
	_send({"type": "enter_interior",
		"door_id": door_id, "interior_id_hint": interior_id_hint})

func send_exit_interior() -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "exit_interior"})

## Enter a dungeon via its overworld entrance entity (v1.5.3). Server validates
## proximity + resolves the dungeon from the entity, then pushes the layout.
func send_dungeon_enter(entrance_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "dungeon_enter", "entrance_id": entrance_id})

func send_admin_tile_set(tx: int, ty: int, biome: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_set", "tx": tx, "ty": ty, "biome": biome})

func send_admin_tile_clear(tx: int, ty: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_clear", "tx": tx, "ty": ty})

# Tile editor v2 — brush sizes >1×1 emit a single bulk message with the
# whole stamp; flood fill is one (tx, ty, biome) seed that the server BFS-
# fills. `tiles` is Array[Dictionary{"tx": int, "ty": int, "biome": String}]
# — pass biome="" or omit to clear an override at that tile.
func send_admin_tile_set_bulk(tiles: Array) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_set_bulk", "tiles": tiles})

func send_admin_tile_flood_fill(tx: int, ty: int, biome: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_flood_fill",
			"tx": tx, "ty": ty, "biome": biome})

# Per-tile color tint. `h` + `v` are -100..100 mapping to ±20% hue + brightness
# in the shader. `tiles` is the stamp footprint.
func send_admin_tile_tint(tiles: Array, h: int, v: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_tint",
			"tiles": tiles, "h": h, "v": v})

# Per-tile passability flag. passable=false → blocks monster movement
# and is drawn with a red overlay while the admin is in Passability mode.
func send_admin_tile_passability(tiles: Array, passable: bool) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_tile_passability",
			"tiles": tiles, "passable": passable})

## Tells the server to flush its in-memory tile_overrides to tile_overrides.json
## right now (it normally autosaves every 30s when dirty). Wired to the admin
## Save Map button so the admin can force-persist mid-session.
func send_admin_save_map() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_save_map"})

func send_build_farm_plot(x: float, y: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "build_farm_plot", "x": x, "y": y})

## Player-crafted wall placement. `subtype` is "wall" or "fortified_wall";
## `wood` is the oak/pine/... key for the wood tier (or the bar key for
## fortified). Server gates on Construction level via the recipe map and
## consumes materials before inserting the world_entity.
func send_build_wall(subtype: String, wood: String, x: float, y: float,
		display_name: String, tier_color: Array) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "build_wall",
			"subtype": subtype, "wood": wood,
			"x": x, "y": y,
			"display_name": display_name,
			"color": tier_color})

## Warband-gated build for stronghold / banner / outpost. Server enforces
## per-warband caps + stronghold spacing + banner non-overlap rules and
## broadcasts world_entity_add on success.
func send_build_warband_structure(kind: String, x: float, y: float) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "build_warband_structure",
			"kind": kind, "x": x, "y": y})

## Banner click action — server inspects ownership and chooses raid (hostile)
## or reinforce (same-warband + bank gold spend). The client sends BOTH
## intents; server's auth handlers reject the one that doesn't apply.
func send_banner_action(entity_id: String) -> void:
	if state != NetState.LOGGED_IN:
		return
	_send({"type": "banner_raid", "entity_id": entity_id})
	_send({"type": "banner_reinforce", "entity_id": entity_id})

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

func send_clan_bank_deposit(item_id: String, qty: int, tab: int = 0) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_bank_deposit", "item_id": item_id, "qty": qty, "tab": tab})

func send_clan_bank_withdraw(item_id: String, qty: int, tab: int = 0) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_bank_withdraw", "item_id": item_id, "qty": qty, "tab": tab})

# Tiled clan bank + gold pool + permissions (Phase 3 #2/#3b).
func send_clan_buy_tab() -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_buy_tab"})

func send_clan_gold_deposit(amount: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_gold_deposit", "amount": amount})

func send_clan_gold_withdraw(amount: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_gold_withdraw", "amount": amount})

func send_clan_set_perm(username: String, tab: int, allow: bool) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_set_perm", "username": username, "tab": tab, "allow": allow})

func send_clan_set_gold_limit(username: String, limit: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "clan_set_gold_limit", "username": username, "limit": limit})

func send_gather_request(entity_id: String, x: float, y: float, tool: String = "") -> void:
	if state == NetState.LOGGED_IN:
		# `tool` = the gatherer's best axe/pickaxe id, echoed back to nearby
		# clients so they draw the right TIERED tool swinging (v1.6.5).
		_send({"type": "gather_request", "id": entity_id, "x": x, "y": y, "tool": tool})

## v1.7 B2a — send the resolved loot with the completion so the server can grant
## it authoritatively (baked map overrides this; the claim is only used pre-bake).
func send_gather_complete(entity_id: String, regen: float, loot: Dictionary = {}) -> void:
	if state == NetState.LOGGED_IN:
		var col: Variant = loot.get("color", Color(0.7, 0.7, 0.7))
		var carr: Array = [col.r, col.g, col.b, col.a] if col is Color else [0.7, 0.7, 0.7, 1.0]
		_send({"type": "gather_complete", "id": entity_id, "regen": regen,
			"drop_id": str(loot.get("id", "")), "drop_name": str(loot.get("name", "")),
			"skill": str(loot.get("skill", "")), "xp": int(loot.get("xp", 0)),
			"color": carr})

## Upload the baked node→drop map to the server (admin bake — B2a).
func send_admin_upload_node_map(node_map: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_upload_node_map", "map": node_map})

## Upload the baked monster-loot table to the server (admin bake — B3).
func send_admin_upload_monster_loot(loot_map: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_upload_monster_loot", "map": loot_map})

## Upload the baked craft-recipe table to the server (admin bake — ⑤).
func send_admin_upload_recipes(recipe_map: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "admin_upload_recipes", "map": recipe_map})

## ⑤ — Ask the SERVER to craft one item. The server validates skill +
## materials against its own DB inventory, rolls burn, consumes, grants, and
## pushes back the authoritative inventory (admin_inventory_set) + a
## craft_result. `payload` is the normalized recipe used as an unbaked
## fallback; once the recipe table is baked the server ignores it and uses
## its own copy. The client no longer mints craft output locally.
func send_craft(recipe_id: String, payload: Dictionary) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "craft", "recipe_id": recipe_id, "recipe": payload})

## Seasonal / major-update reset — wipe the selected player fields across ALL
## accounts (owner-only; the server backs up + kicks everyone).
func send_admin_season_reset(fields: Array) -> void:
	if state == NetState.LOGGED_IN and not fields.is_empty():
		_send({"type": "admin_season_reset", "fields": fields})

func send_gather_release(entity_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "gather_release", "id": entity_id})

func send_node_states(ids: Array) -> void:
	if state == NetState.LOGGED_IN and not ids.is_empty():
		_send({"type": "node_states", "ids": ids})

func send_monster_join(entity_id: String, x: float, y: float, max_hp: int, xp_reward: int,
		monster_type: String = "", level: int = 0, attack: int = 0,
		seed_only: bool = false) -> void:
	# Stage 1 of server-side AI — the new monster_type / level / attack
	# fields let the server seed hostility defaults (`chicken` / `rat` are
	# passive, everything else hostile), scale the aggro radius by level,
	# and pick a damage value for monster-initiated attacks. All three
	# parameters default to safe values so older callers still work; the
	# server falls back to a `rat`-ish entry when they're absent.
	#
	# `seed_only` disambiguates the two meanings of monster_join:
	#   - seed_only=false (default) → the caller is engaging combat (Attack
	#     click). Server aggros the monster onto the sender.
	#   - seed_only=true → the caller is just registering AI (chunk load,
	#     admin-entity rehydrate on login burst). Server sets up state
	#     without flipping the monster into aggro/chase mode. Fixes the
	#     "all monsters swarm the player on login / interior exit" glitch.
	if state == NetState.LOGGED_IN:
		_send({"type": "monster_join", "id": entity_id, "x": x, "y": y,
			   "max_hp": max_hp, "xp_reward": xp_reward,
			   "monster_type": monster_type, "level": level, "attack": attack,
			   "seed_only": seed_only})

func send_monster_damage(entity_id: String, amount: int) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "monster_damage", "id": entity_id, "amount": amount})

## v1.7 B1 — server-authoritative combat: send an ATTACK INTENT (no damage
## number). The server computes the hit from the attacker's stats + style.
func send_monster_attack(entity_id: String, style: String, xp: int = 4) -> void:
	if state == NetState.LOGGED_IN:
		# ⑦/⑧ — `xp` is the per-swing XP the client granted for this style, so the
		# server's grant ceiling matches (magic's rune-scaled per-hit up to ~84).
		_send({"type": "monster_attack", "id": entity_id, "style": style, "xp": xp})

func send_structure_damage(entity_id: String, amount: int, style: String = "melee") -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "structure_damage", "id": entity_id, "amount": amount, "style": style})

func send_structure_repair(entity_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "structure_repair", "id": entity_id})

func send_monster_leave(entity_id: String) -> void:
	if state == NetState.LOGGED_IN:
		_send({"type": "monster_leave", "id": entity_id})

func send_monster_states(ids: Array) -> void:
	if state == NetState.LOGGED_IN and not ids.is_empty():
		_send({"type": "monster_states", "ids": ids})

func go_offline() -> void:
	# Intentional offline/logout — never a "lost connection" freeze.
	lost_connection = false
	_server_restarting = false
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
	# A deliberate logout means "let me pick an account" — don't auto-login back
	# into the one we just left; the login screen stays up for this session.
	suppress_auto_login = true
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
			# Reconnected + re-authenticated — clear the lost-connection freeze.
			lost_connection = false
			_server_restarting = false
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

		"spectate_ok":
			# Server accepted the read-only observer and resolved the target's
			# id (may be "" if the target is offline; we then match by username).
			spectate_target_id = str(msg.get("target_id", ""))
			var tname := str(msg.get("target", spectate_target))
			Events.chat_message.emit("[Spectate] Watching %s." % tname)

		"spectate_state":
			# The watched player's skills/inventory/gear/bank (refreshed on saves).
			spectate_state = {
				"skill_xp":  msg.get("skill_xp",  {}),
				"inventory": msg.get("inventory", []),
				"equipment": msg.get("equipment", {}),
				"bank":      msg.get("bank",      []),
			}
			Events.spectate_state_updated.emit()

		"spectate_event":
			# Per-action feedback from the watched player relayed by the server, so
			# the spectator shows the SAME floating toast the real client would —
			# instantly, per action, never batched.
			# Diagnostic: prove the event reached this client (the far end of the
			# bot→server→client toast chain). Shows in the spectator's console/log.
			print("[spectate_event] recv kind=%s spectating=%s data=%s"
				% [str(msg.get("kind", "")), spectating, msg])
			if spectating:
				match str(msg.get("kind", "")):
					"xp":
						var xs := str(msg.get("skill", ""))
						var xa := int(msg.get("amount", 0))
						Events.xp_gained.emit(xs, xa)
						Events.spectate_feedback.emit(
							"+%d %s XP" % [xa, xs.capitalize()], "xp")
					"level":
						var ls := str(msg.get("skill", ""))
						var ll := int(msg.get("level", 0))
						Events.level_up.emit(ls, ll)
						Events.spectate_feedback.emit(
							"%s Level %d!" % [ls.capitalize(), ll], "level")
					"item":
						var iname := str(msg.get("name", ""))
						var iqty := int(msg.get("qty", 1))
						Events.item_gained.emit(iname, iqty)
						Events.spectate_feedback.emit(
							"+%d %s" % [iqty, iname.replace("_", " ")], "item")
					"combat_start":
						Events.spectate_combat_start.emit(
							str(msg.get("name", "")), int(msg.get("level", 0)))
					"combat":
						var cmine := bool(msg.get("mine", true))
						Events.spectate_combat_hit.emit(
							str(msg.get("name", "")), int(msg.get("amount", 0)), cmine)
						# Swing the watched avatar so the fight LOOKS like fighting.
						if cmine and _other_players.has(spectate_target_id):
							var cop: Variant = _other_players[spectate_target_id]
							if cop != null and cop.has_method("play_attack"):
								cop.play_attack(float(msg.get("mx", 0.0)))
					"combat_end":
						Events.spectate_combat_end.emit(
							str(msg.get("name", "")), str(msg.get("result", "win")))

		"player_level":
			# A player's overall level changed — update their nameplate live.
			var lvl_id := str(msg.get("id", ""))
			for op in get_tree().get_nodes_in_group("other_player"):
				if str(op.get_meta("server_id", "")) == lvl_id:
					op.set_meta("level", int(msg.get("level", 0)))
					(op as Node2D).queue_redraw()
					break

		"pvp_flag":
			pvp_flag_changed.emit(
				str(msg.get("id", "")),
				str(msg.get("username", "")),
				bool(msg.get("flagged", false)))
		"pvp_hit":
			pvp_hit_taken.emit(
				str(msg.get("attacker_id", "")),
				str(msg.get("attacker_username", "")),
				int(msg.get("damage", 0)),
				str(msg.get("style", "melee")))
		"pvp_hit_confirm":
			pvp_hit_confirm.emit(
				str(msg.get("target_id", "")),
				int(msg.get("damage", 0)))
		"pvp_reject":
			pvp_reject.emit(str(msg.get("reason", "PvP action refused.")))
		"pvp_locked":
			pvp_locked.emit(int(msg.get("remaining", 0)))
		"pvp_pile_spawn":
			var col_arr: Array = msg.get("color", [1, 1, 1, 1]) as Array
			var col := Color(1, 1, 1)
			if col_arr.size() >= 3:
				col = Color(float(col_arr[0]), float(col_arr[1]),
					float(col_arr[2]),
					float(col_arr[3]) if col_arr.size() >= 4 else 1.0)
			pvp_pile_spawn.emit(
				str(msg.get("id", "")),
				float(msg.get("x", 0.0)),
				float(msg.get("y", 0.0)),
				str(msg.get("item_id", "")),
				str(msg.get("item_name", "")),
				int(msg.get("qty", 1)),
				col)
		"pvp_pile_remove":
			pvp_pile_remove.emit(str(msg.get("id", "")))
		"farm_plot_state":
			farm_plot_state.emit(
				str(msg.get("id", "")),
				int(msg.get("stage", 0)),
				str(msg.get("seed_id", "")),
				float(msg.get("grow", 0.0)),
				float(msg.get("eff", 0.0)),
				float(msg.get("boost", 0.0)))
		"farm_plot_burst":
			var plots_v: Variant = msg.get("plots", [])
			var plots: Array = plots_v if plots_v is Array else []
			farm_plot_burst.emit(plots)
		"farm_harvest_ok":
			farm_harvest_ok.emit(
				str(msg.get("id", "")),
				str(msg.get("item_id", "")),
				str(msg.get("item_name", "")),
				int(msg.get("qty", 1)),
				int(msg.get("xp", 0)),
				str(msg.get("seed_id", "")))
		"farm_harvest_fail":
			farm_harvest_fail.emit(
				str(msg.get("id", "")),
				str(msg.get("seed_id", "")),
				str(msg.get("reason", "withered")),
				int(msg.get("xp", 0)))
		"farm_reject":
			farm_reject.emit(str(msg.get("reason", "Farming action refused.")),
				str(msg.get("seed_id", "")))
		"fishing_data":
			var recs_v: Variant = msg.get("records", [])
			var jrnl_v: Variant = msg.get("journal", [])
			fishing_records = recs_v if recs_v is Array else []
			fishing_journal = jrnl_v if jrnl_v is Array else []
			Events.fishing_data_updated.emit()
		"fish_caught_result":
			# ⑥ — a false `ok` means the SERVER refused the grant (unknown species
			# or under the fishing-level gate). Surface the reason to the player.
			if msg.has("ok") and not bool(msg.get("ok", true)):
				Events.chat_message.emit(str(msg.get("reason", "That catch was rejected.")))
			else:
				# The fish ITEM + gold arrived via admin_inventory_set/gold_set;
				# mirror the server-awarded fishing XP so the skill UI updates
				# live (client no longer mints it; B4 pushes XP directly later).
				var fxp := int(msg.get("xp", 0))
				if fxp > 0:
					GameManager.add_xp("fishing", fxp)
			# Update this player's journal cache locally so the UI is fresh
			# without a round-trip, and flag record/personal bests for a flourish.
			if bool(msg.get("world_record", false)):
				Events.top_toast.emit("🎣 NEW WORLD RECORD — %.1f kg %s!"
					% [float(msg.get("weight", 0.0)), str(msg.get("species", "fish"))])
			elif bool(msg.get("personal_best", false)):
				Events.top_toast.emit("🎣 New personal best — %.1f kg!"
					% float(msg.get("weight", 0.0)))
			request_fishing_data()   # refresh cached records/journal
		"monster_projectile":
			var col_arr: Array = msg.get("color", [1, 1, 1]) as Array
			var col := Color(1, 1, 1)
			if col_arr.size() >= 3:
				col = Color(float(col_arr[0]), float(col_arr[1]),
					float(col_arr[2]))
			monster_projectile.emit(
				str(msg.get("id", "")),
				float(msg.get("from_x", 0.0)),
				float(msg.get("from_y", 0.0)),
				float(msg.get("to_x", 0.0)),
				float(msg.get("to_y", 0.0)),
				str(msg.get("style", "melee")),
				col,
				int(msg.get("spread_orbs", 1)))

		"pvp_kill_credit":
			pvp_kill_credit.emit(
				str(msg.get("style", "melee")),
				int(msg.get("xp", 0)),
				str(msg.get("victim_username", "")))
			# Server-owned token balance rides along with the kill credit.
			if msg.has("pvp_tokens"):
				pvp_tokens_set.emit(int(msg.get("pvp_tokens", 0)))

		"pvp_tokens_set":
			pvp_tokens_set.emit(int(msg.get("pvp_tokens", 0)))

		"token_upgrade_ok":
			pvp_tokens_set.emit(int(msg.get("pvp_tokens", 0)))
			token_upgrade_ok.emit(
				str(msg.get("slot", "")),
				str(msg.get("old_item_id", "")),
				str(msg.get("new_item_id", "")),
				int(msg.get("level", 0)),
				int(msg.get("pvp_tokens", 0)))

		"token_upgrade_reject":
			token_upgrade_reject.emit(
				str(msg.get("reason", "Upgrade failed.")),
				int(msg.get("pvp_tokens", GameManager.pvp_tokens)))
		"pvp_pile_pickup_ok":
			var col_arr2: Array = msg.get("color", [1, 1, 1, 1]) as Array
			var col2 := Color(1, 1, 1)
			if col_arr2.size() >= 3:
				col2 = Color(float(col_arr2[0]), float(col_arr2[1]),
					float(col_arr2[2]),
					float(col_arr2[3]) if col_arr2.size() >= 4 else 1.0)
			pvp_pile_pickup_ok.emit(
				str(msg.get("item_id", "")),
				str(msg.get("item_name", "")),
				int(msg.get("qty", 1)),
				col2)

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

		"request_password_reset_ok":
			request_password_reset_ok.emit(str(msg.get("message", "")))

		"verify_password_reset_token_result":
			verify_password_reset_token_result.emit(bool(msg.get("ok", false)))

		"complete_password_reset_ok":
			complete_password_reset_ok.emit(str(msg.get("username", "")))

		"complete_password_reset_fail":
			complete_password_reset_fail.emit(str(msg.get("reason", "Reset failed.")))

		"account_info":
			account_info.emit({
				"username": str(msg.get("username", "")),
				"email": str(msg.get("email", "")),
				"email_verified": bool(msg.get("email_verified", false)),
				"last_login_at": float(msg.get("last_login_at", 0.0)),
			})

		"change_email_ok":
			change_email_ok.emit(str(msg.get("email", "")))

		"change_email_fail":
			change_email_fail.emit(str(msg.get("reason", "Email change failed.")))

		"change_password_ok":
			change_password_ok.emit()

		"change_password_fail":
			change_password_fail.emit(str(msg.get("reason", "Password change failed.")))

		"set_backstory_ok":
			backstory_set.emit(str(msg.get("backstory", "")))
		"set_backstory_fail":
			backstory_fail.emit(str(msg.get("reason", "Backstory pick failed.")))

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

		"server_shutdown":
			# Graceful restart notice (Phase 7). Push a final save immediately so
			# nothing is lost, and remember it was a restart so the imminent
			# socket close shows "restarting" rather than a generic drop.
			_server_restarting = true
			_save_to_server()
			Events.chat_message.emit("[Server] Restarting — saving your progress…")

		"chat":
			var uname := str(msg.get("username", "?"))
			var text  := str(msg.get("text", ""))
			var lname := uname.to_lower()
			if uname.begins_with("From ") or uname.begins_with("To "):
				# Whisper (server sends username "From X" / "To Y") — the bracket
				# wrap routes it to the Private tab in _categorize_chat.
				Events.chat_message.emit("[%s] %s" % [uname, text])
			elif lname == "server" or lname == "admin" or lname == "system":
				# System/admin notices are NOT chat — route to the Events tab.
				Events.chat_message.emit("[%s] %s" % [uname, text])
			else:
				# Genuine player chat — the ONLY thing that belongs in World.
				Events.world_chat.emit(uname, text)
				# World-space speech bubble over the speaker (Phase 9).
				Events.player_chatted.emit(uname, text)

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

		"loot_reward":
			# v1.7 B3 — SERVER-authoritative monster loot. Add the pushed item, or
			# (un-baked) fall back to a local roll so loot never breaks pre-bake.
			if bool(msg.get("fallback", false)):
				Events.loot_fallback.emit(str(msg.get("monster_id", "")))
			else:
				var lc: Variant = msg.get("color", [0.7, 0.7, 0.7, 1.0])
				var lcol := Color(0.7, 0.7, 0.7)
				if lc is Array and (lc as Array).size() >= 3:
					var la: Array = lc
					lcol = Color(float(la[0]), float(la[1]), float(la[2]),
						float(la[3]) if la.size() > 3 else 1.0)
				var lid := str(msg.get("id", ""))
				if lid != "":
					GameManager.add_item(lid, str(msg.get("name", lid)), 1, lcol)

		"gather_reward":
			# v1.7 B2a — SERVER-authoritative gather grant. Add exactly what the
			# server decided; the client no longer mints its own gather loot.
			if bool(msg.get("ok", false)):
				var carr: Variant = msg.get("color", [0.7, 0.7, 0.7, 1.0])
				var col := Color(0.7, 0.7, 0.7)
				if carr is Array and (carr as Array).size() >= 3:
					var a: Array = carr
					col = Color(float(a[0]), float(a[1]), float(a[2]),
						float(a[3]) if a.size() > 3 else 1.0)
				var did := str(msg.get("drop_id", ""))
				if did != "":
					GameManager.add_item(did, str(msg.get("drop_name", did)), 1, col)
				var sk := str(msg.get("skill", ""))
				var xp := int(msg.get("xp", 0))
				if sk != "" and xp > 0:
					GameManager.add_xp(sk, xp)
			else:
				var reason := str(msg.get("reason", ""))
				if reason != "":
					Events.chat_message.emit(reason)

		"craft_result":
			# ⑤ — SERVER-authoritative craft outcome. The authoritative
			# inventory already arrived via admin_inventory_set; here we
			# mirror the server-awarded XP (so the skill UI updates before
			# B4 pushes XP directly) and surface the success/burn toast.
			if bool(msg.get("ok", false)):
				var csk := str(msg.get("skill", ""))
				var cxp := int(msg.get("xp", 0))
				if csk != "" and cxp > 0:
					GameManager.add_xp(csk, cxp)
				var cname := str(msg.get("out_name", "item"))
				if bool(msg.get("burned", false)):
					Events.chat_message.emit("You burnt the %s." % cname)
				else:
					var cqty := int(msg.get("out_qty", 1))
					if cqty > 1:
						Events.chat_message.emit("Made %d× %s." % [cqty, cname])
					else:
						Events.chat_message.emit("Made a %s." % cname)
			else:
				var creason := str(msg.get("reason", ""))
				if creason != "":
					Events.chat_message.emit(creason)

		"sea_combat_result":
			# ⑥ — SERVER-authoritative boat-fight reward. Loot arrived via
			# admin_inventory_set; mirror the split fishing/melee XP + toast.
			if bool(msg.get("ok", false)):
				var fxp := int(msg.get("fishing_xp", 0))
				var mxp := int(msg.get("melee_xp", 0))
				if fxp > 0:
					GameManager.add_xp("fishing", fxp)
				if mxp > 0:
					GameManager.add_xp("melee", mxp)
			else:
				var sreason := str(msg.get("reason", ""))
				if sreason != "":
					Events.chat_message.emit(sreason)

		"node_locked":
			Events.node_remote_locked.emit(str(msg.get("id", "")), str(msg.get("username", "")))

		"node_unlocked":
			Events.node_remote_unlocked.emit(str(msg.get("id", "")))

		"node_depleted":
			Events.node_remote_depleted.emit(str(msg.get("id", "")), float(msg.get("respawn_in", 30.0)))

		"node_respawned":
			Events.node_remote_respawned.emit(str(msg.get("id", "")),
					float(msg.get("x", -1.0)), float(msg.get("y", -1.0)))

		"node_states":
			Events.node_states_received.emit(msg.get("nodes", []) as Array)

		"monster_state":
			Events.mob_state.emit(str(msg.get("id", "")),
				int(msg.get("hp", 0)), int(msg.get("max_hp", 1)))

		"monster_hit":
			Events.mob_hit.emit(str(msg.get("id", "")),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)),
				int(msg.get("amount", 0)), str(msg.get("by", "")),
				int(msg.get("hp", 0)), int(msg.get("max_hp", 1)),
				bool(msg.get("crit", false)), bool(msg.get("missed", false)))

		"player_action":
			# A remote player is gathering — swing their avatar at the node so they
			# don't look motionless (v1.6.4). Guarded so non-OtherPlayer nodes (3D)
			# are simply skipped.
			var apid := str(msg.get("id", ""))
			var pa_action := str(msg.get("action", "gather"))
			# Non-gather mimes (bank/craft/…) from the WATCHED player tell the
			# spectator HUD to open that window on camera (v1.6.5).
			if spectating and pa_action != "gather" and apid == spectate_target_id:
				Events.spectate_mime.emit(pa_action)
			if _other_players.has(apid) and is_instance_valid(_other_players[apid]):
				var aop := _other_players[apid] as Node2D
				if pa_action == "gather" and aop.has_method("play_gather"):
					# Pass coords (to look up the node's tool TYPE) + the gatherer's
					# tool id (for the tiered axe/pick art). Bare hand for forage.
					aop.play_gather(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)),
						str(msg.get("tool", "")))

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

		"structure_hp_changed":
			Events.structure_hp_changed.emit(
				str(msg.get("id", "")),
				int(msg.get("hp", 0)),
				int(msg.get("max_hp", 1)),
				bool(msg.get("alive", true)))

		"structure_destroyed":
			Events.structure_destroyed.emit(str(msg.get("id", "")))

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
			# Every nearby client animates the monster's swing (2D + 3D parity) —
			# melee attacks previously had NO visual on any client.
			Events.monster_attacked.emit(str(msg.get("id", "")))
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
					var m_type := str(msg.get("monster_type", ""))
					# Sharks damage the boat hull first when the player is
					# sailing. Player still takes HALF damage (bites over
					# the gunwale). When boat HP hits 0 the sailing HUD
					# handles the sinking transition on its own.
					var sailing := bool(GameManager.get("is_sailing"))
					if m_type == "shark" and sailing \
							and GameManager.has_method("apply_boat_damage"):
						GameManager.apply_boat_damage(dmg)
						GameManager.take_damage(int(ceil(dmg * 0.5)))
					else:
						GameManager.take_damage(dmg)
					# Match the local-fight path so AudioManager hears it
					# in server mode too (down-pitched melee_hit).
					Events.monster_attack_landed.emit()

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

		"world_entity_rotate":
			var erid := str(msg.get("id", ""))
			var erot := float(msg.get("rot", 0.0))
			# Keep the caches current so a 2D/3D scene switch replays the rotation.
			for e: Variant in world_entities_cache:
				if str((e as Dictionary).get("id", "")) == erid:
					var ed: Variant = (e as Dictionary).get("data")
					if ed is Dictionary:
						(ed as Dictionary)["rot"] = erot
			for ee: Variant in entity_edits_cache:
				if str((ee as Dictionary).get("id", "")) == erid:
					(ee as Dictionary)["rot"] = erot
			Events.world_entity_rotated.emit(erid, erot)

		"toast":
			Events.top_toast.emit(str(msg.get("text", "")))

		"terrain_heights":
			terrain_heights_cache = (msg.get("tiles", {}) as Dictionary)
			Events.terrain_heights_received.emit(terrain_heights_cache)

		"terrain_height_set":
			var th := (msg.get("tiles", {}) as Dictionary)
			for k: Variant in th.keys():
				if absf(float(th[k])) < 0.0001:
					terrain_heights_cache.erase(str(k))
				else:
					terrain_heights_cache[str(k)] = float(th[k])
			Events.terrain_height_set.emit(th)

		"road_graph":
			# Admin-drawn road/path network — store into GameManager (the shared
			# source for the road overlay, the editor, and the autoplay router).
			GameManager.set_road_graph(
				(msg.get("nodes", []) as Array), (msg.get("edges", []) as Array))
			Events.road_graph_updated.emit()

		"gold_set":
			GameManager.gold = int(msg.get("gold", GameManager.gold))
			Events.inventory_changed.emit()

		"fast_travel_ok":
			# Server approved + charged; teleport to its authoritative coords.
			var dest := Vector2(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))
			Events.player_respawned.emit(dest)
			Events.chat_message.emit("Fast-travelled for %dg." % int(msg.get("cost", 0)))

		"fast_travel_reject":
			Events.chat_message.emit("Travel: %s" % str(msg.get("reason", "unavailable")))

		"rankings":
			Events.rankings_updated.emit(msg.get("entries", []) as Array)

		"reputation":
			Events.reputation_updated.emit(
				msg.get("towns", []) as Array,
				bool(msg.get("in_warband", false)),
				msg.get("warbands", []) as Array)

		"npc_hit":
			Events.npc_hit.emit(str(msg.get("id", "")),
				int(msg.get("hp", 0)), int(msg.get("max_hp", 1)))

		"npc_died":
			Events.npc_died.emit(str(msg.get("id", "")))

		"npc_respawned":
			Events.npc_respawned.emit(str(msg.get("id", "")))

		"caravans":
			Events.caravans_updated.emit(msg.get("caravans", []) as Array)

		"caravan_hit":
			Events.caravan_hit.emit(str(msg.get("id", "")),
				int(msg.get("hp", 0)), int(msg.get("max_hp", 1)))

		"caravan_destroyed":
			Events.caravan_destroyed.emit(
				str(msg.get("id", "")), float(msg.get("x", 0.0)),
				float(msg.get("y", 0.0)), str(msg.get("by", "")))
			Events.chat_message.emit("[A trade caravan was destroyed on the road]")

		"caravan_survivor":
			# The driver stumbles clear of the wreck — flavour only; the server
			# doesn't track them, so this is a one-off chat beat.
			Events.chat_message.emit("[%s survived the caravan attack]"
				% str(msg.get("name", "A driver")))

		"caravan_remove":
			# A warband recalled its caravan — drop the node entirely.
			Events.caravan_removed.emit(str(msg.get("id", "")))

		"thralls":
			ThrallManager.populate_thralls(
				msg.get("thralls", []) as Array,
				int(msg.get("slots", 2)),
				int(msg.get("max_slots", 5)))

		"thrall_result":
			if not bool(msg.get("ok", false)):
				Events.chat_message.emit("Thrall: %s" % str(msg.get("reason", "failed")))

		"thrall_summary":
			# Offline thrall work report (Phase 10b) — shown as a popup on login.
			var tsum: Variant = msg.get("summary", {})
			if tsum is Dictionary:
				Events.thrall_summary.emit(tsum as Dictionary)

		"thrall_drop":
			# A monster kill yielded a thrall (Phase 10c). The roster refresh
			# rides in on the `thralls` push that follows this message.
			Events.chat_message.emit("⚔ You took a thrall! %s (Tier %d) joined your roster." % [
				str(msg.get("name", "A thrall")), int(msg.get("tier", 1))])

		"bank_gold_set":
			GameManager.bank_gold = int(msg.get("bank_gold", GameManager.bank_gold))
			Events.inventory_changed.emit()   # refreshes the bank gold row

		"tile_overrides":
			# Cache the login burst so a scene switch (2D↔3D toggle) can rebuild the
			# real admin-painted map — the server only sends this ONCE at login.
			tile_overrides_cache = msg.get("overrides", []) as Array
			Events.tile_overrides_received.emit(tile_overrides_cache)

		"tile_set":
			_update_tile_cache(int(msg.get("tx", 0)), int(msg.get("ty", 0)), msg.get("biome", "plains"))
			Events.tile_override_set.emit(int(msg.get("tx", 0)), int(msg.get("ty", 0)),
				str(msg.get("biome", "plains")))

		"tile_clear":
			_update_tile_cache(int(msg.get("tx", 0)), int(msg.get("ty", 0)), null)
			Events.tile_override_cleared.emit(int(msg.get("tx", 0)), int(msg.get("ty", 0)))

		"tile_set_bulk":
			# Broadcast for brush stamps + flood fill. Each entry has
			# tx/ty/biome (biome can be null to mean "clear").
			var bulk_raw: Variant = msg.get("tiles", [])
			if bulk_raw is Array:
				for e: Variant in bulk_raw:
					if e is Dictionary:
						var d := e as Dictionary
						_update_tile_cache(int(d.get("tx", -1)), int(d.get("ty", -1)), d.get("biome", null))
				Events.tile_overrides_bulk_received.emit(bulk_raw as Array)

		"tile_tint_bulk":
			var tint_raw: Variant = msg.get("tiles", [])
			if tint_raw is Array:
				Events.tile_tints_bulk_received.emit(tint_raw as Array)

		"tile_passability_bulk":
			var pass_raw: Variant = msg.get("tiles", [])
			if pass_raw is Array:
				Events.tile_passability_bulk_received.emit(pass_raw as Array)

		"entity_edits":
			entity_edits_cache = msg.get("edits", []) as Array
			Events.entity_edits_received.emit(entity_edits_cache)

		"entity_edit":
			Events.entity_edit_applied.emit(str(msg.get("id", "")),
				bool(msg.get("deleted", false)),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))

		"entity_data_edit":
			var ded: Variant = msg.get("data", {})
			Events.entity_data_edited.emit(str(msg.get("id", "")),
				(ded as Dictionary) if ded is Dictionary else {})

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

		"admin_placed":
			# Echo of a successful admin_place — carries the new a: id so the
			# editor's Undo stack can reverse the placement.
			Events.admin_entity_placed.emit(
				str(msg.get("id", "")), str(msg.get("kind", "")),
				str(msg.get("subtype", "")),
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))

		"admin_player_list":
			var raw: Variant = msg.get("players", [])
			var names: Array = []
			if raw is Array:
				for n: Variant in (raw as Array):
					names.append(str(n))
			Events.admin_player_list_received.emit(names)

		"admin_account_list":
			var araw: Variant = msg.get("accounts", [])
			var accounts: Array = []
			if araw is Array:
				for r: Variant in (araw as Array):
					if r is Dictionary:
						accounts.append(r as Dictionary)
			Events.admin_account_list_received.emit(accounts)

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

		"dungeon_entered":
			# Server pushes the canonical dungeon layout; World builds the scene.
			# Exit reuses the interior_exited path (same session fields).
			var lay: Variant = msg.get("layout", {})
			Events.dungeon_entered.emit(
				str(msg.get("dungeon_id", "")),
				str(msg.get("interior_id", "")),
				(lay as Dictionary) if lay is Dictionary else {},
				float(msg.get("x", 0.0)), float(msg.get("y", 0.0)),
				float(msg.get("return_x", 0.0)), float(msg.get("return_y", 0.0)))

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
		# Practice-makes-perfect counters — server persists as JSON in the
		# recipe_counts column. Sent every save so a client crash never
		# loses more than one save interval of progress.
		"recipe_counts": GameManager.recipe_success_counts,
	})

# ── Other player management ────────────────────────────────────────────────────
func _add_other_player(msg: Dictionary) -> void:
	var pid: String = str(msg.get("id", ""))
	if pid.is_empty() or (_other_players.has(pid) and is_instance_valid(_other_players[pid])):
		return
	_player_roster[pid] = msg.duplicate(true)   # remember so we can rebuild after a switch
	if _spawn_other_player(pid, msg) and not bool(msg.get("idle", false)):
		Events.chat_message.emit("[%s has entered the realm]" % str(msg.get("username", "?")))

## Build one OtherPlayer node from cached/join data + add it to the CURRENT scene.
## Shared by _add_other_player (join) and reattach_other_players (post scene-switch).
func _spawn_other_player(pid: String, data: Dictionary) -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var op: Node2D = (load("res://scripts/OtherPlayer.gd") as GDScript).new() as Node2D
	op.set_meta("server_id", pid)
	op.set_meta("username",  str(data.get("username", "?")))
	op.set_meta("is_idle",   bool(data.get("idle", false)))
	op.set_meta("appearance", data.get("appearance", {}))
	op.set_meta("equipment",  data.get("equipment", {}))
	op.set_meta("pvp_flagged", bool(data.get("flagged", false)))
	op.set_meta("level", int(data.get("level", 0)))
	op.set_meta("interior_id", str(data.get("interior_id", "")))
	op.position = Vector2(float(data.get("x", 0)), float(data.get("y", 0)))
	scene.add_child(op)
	_other_players[pid] = op
	_apply_interior_visibility(op)
	return true

## Rebuild OtherPlayer nodes into the current scene after a 2D↔3D toggle (the old
## scene freed them). Called by World.gd / World3D on load so the switcher never
## loses sight of anyone. Positions catch up on the next move broadcast.
func reattach_other_players() -> void:
	for pid: Variant in _player_roster.keys():
		if _other_players.has(pid) and is_instance_valid(_other_players[pid]):
			continue
		_spawn_other_player(str(pid), _player_roster[pid])

func _remove_other_player(pid: String) -> void:
	var uname := str(_player_roster.get(pid, {}).get("username", "?"))
	if _other_players.has(pid):
		if is_instance_valid(_other_players[pid]):
			uname = str((_other_players[pid] as Node2D).get_meta("username", uname))
			_other_players[pid].queue_free()
		_other_players.erase(pid)
	if _player_roster.has(pid):
		_player_roster.erase(pid)
		Events.chat_message.emit("[%s has left the realm]" % uname)

func _move_other_player(msg: Dictionary) -> void:
	var pid: String = str(msg.get("id", ""))
	# Keep the roster position current so a rebuild after a scene switch spawns the
	# player at (roughly) the right spot even before their next move arrives.
	if _player_roster.has(pid):
		var r: Dictionary = _player_roster[pid]
		r["x"] = float(msg.get("x", r.get("x", 0)))
		r["y"] = float(msg.get("y", r.get("y", 0)))
		if msg.has("boat"): r["boat"] = str(msg.get("boat", ""))
		if msg.has("interior_id"): r["interior_id"] = str(msg.get("interior_id", ""))
	if _other_players.has(pid):
		if not is_instance_valid(_other_players[pid]):   # freed mid-frame — CAST would throw
			return
		var op := _other_players[pid] as Node2D
		var nx := float(msg.get("x", op.global_position.x))
		var ny := float(msg.get("y", op.global_position.y))
		var new_pos := Vector2(nx, ny)
		# Big position jumps are TELEPORTS (interior enter/exit, fast travel,
		# respawn), not walks — snap instead of lerping. OtherPlayer lerps at
		# 200px/s, so an ~8000px interior hop would take ~40s to crawl there and
		# the player would never appear in the room (this broke interior co-op).
		if op.global_position.distance_to(new_pos) > 800.0:
			op.global_position = new_pos
		op.set_meta("target_pos", new_pos)
		op.set_meta("boat", str(msg.get("boat", "")))
		# player_move carries the sender's interior_id — keep it current so
		# visibility flips the instant they step in or out of a building.
		if msg.has("interior_id"):
			op.set_meta("interior_id", str(msg.get("interior_id", "")))
			_apply_interior_visibility(op)

## An OtherPlayer is visible only when its interior matches ours: same building
## occupants see each other, and outsiders are hidden while you're inside (and
## vice-versa). Interiors sit in a far-off coordinate band, so without this an
## occupant would otherwise render pinned at the world edge.
func _apply_interior_visibility(op: Node2D) -> void:
	if op == null or not is_instance_valid(op):
		return
	op.visible = str(op.get_meta("interior_id", "")) == GameManager.current_interior_id

## Re-evaluate every remote player's visibility — called when the LOCAL player
## enters or leaves an interior (our own interior_id changed).
func refresh_interior_visibility() -> void:
	for pid: Variant in _other_players:
		_apply_interior_visibility(_other_players[pid] as Node2D)

# ── Login screen ───────────────────────────────────────────────────────────────
func _spawn_login_screen() -> void:
	var ls := CanvasLayer.new()
	ls.set_script(load("res://scripts/LoginScreen.gd"))
	add_child(ls)

## Spawn the login screen only if one isn't already up — avoids stacking a
## second copy when connection_lost fires while a login screen is open.
func _ensure_login_screen() -> void:
	for c in get_children():
		var scr: Variant = (c as Node).get_script()
		if scr is Script and str((scr as Script).resource_path).ends_with("LoginScreen.gd"):
			return
	_spawn_login_screen()
