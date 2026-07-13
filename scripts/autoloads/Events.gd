extends Node

## Global signal bus — emit from anywhere, listen from anywhere.

@warning_ignore("unused_signal") signal player_interacted(interactable: Node)
@warning_ignore("unused_signal") signal ui_show_interaction(data: Dictionary)
@warning_ignore("unused_signal") signal ui_hide_interaction()

## Action loop
@warning_ignore("unused_signal") signal player_start_action(action_type: String, target: Node)
@warning_ignore("unused_signal") signal player_stop_action()
@warning_ignore("unused_signal") signal node_hit(node: Node, hp_remaining: int)
@warning_ignore("unused_signal") signal node_depleted(node: Node)
@warning_ignore("unused_signal") signal inventory_changed()
@warning_ignore("unused_signal") signal equipment_changed()
@warning_ignore("unused_signal") signal boat_prompt(text: String)
@warning_ignore("unused_signal") signal boat_toggle()
@warning_ignore("unused_signal") signal skill_cell_pressed(skill: String)
@warning_ignore("unused_signal") signal request_whisper(username: String)
@warning_ignore("unused_signal") signal request_trade(username: String)
@warning_ignore("unused_signal") signal xp_gained(skill: String, amount: int)
## Fired by GameManager.add_xp the moment a skill crosses an integer level
## threshold. AudioManager listens for the fanfare; HUD listens for the
## floating level-up banner. Skill name is canonical ("attack", "fishing"…),
## new_level is the level just reached.
@warning_ignore("unused_signal") signal level_up(skill: String, new_level: int)
## Fired by GameManager the instant a quest's turn-in is acknowledged by the
## server. Distinct from quest_state_changed which also fires on accept /
## progress / abandon — this one is "the chime moment".
@warning_ignore("unused_signal") signal quest_completed(quest_id: String)
## Player started an attack swing. `style` is "melee" / "ranged" / "magic".
## Fired BEFORE damage resolves (during the windup) so the swing sound is
## tightly coupled to the visible action.
@warning_ignore("unused_signal") signal attack_swung(style: String)
## Damage from the player landed on a target. Same style values. Fires once
## per confirmed hit — projectile-on-arrival for ranged/magic, immediate
## for melee.
@warning_ignore("unused_signal") signal attack_landed(style: String)
## Monster connected on the player. No params — AudioManager plays a
## down-pitched, slightly randomized melee_hit so the player can tell
## "I got hit" apart from "I hit them".
@warning_ignore("unused_signal") signal monster_attack_landed()
## Player left-clicked a monster. Carries the monster ref + viewport-space
## screen position for the HUD to anchor the action popup. The popup decides
## what happens next — combat is NOT auto-entered on click anymore.
@warning_ignore("unused_signal") signal monster_clicked(monster: Node, screen_pos: Vector2)
## Player picked "Attack" in the monster action popup. Combat starts
## immediately on receipt — no proximity walk, no auto-engage. The player
## stays where they are; the monster chases. Range / movement logic lives
## on the server's aggro chase.
@warning_ignore("unused_signal") signal monster_attack_chosen(monster: Node)
## Right-click on any actionable node (monster, NPC, interactable) — HUD
## inspects `node` and pops the type-appropriate menu (Attack/Examine for
## a monster, Mine/Examine for a rock, Use Bank for a bank, Talk for an
## NPC, etc.). `screen_pos` is viewport-space for menu anchoring.
@warning_ignore("unused_signal") signal action_menu_requested(node: Node, screen_pos: Vector2)
## Right-click on empty world space — drops the panel target selection so
## the panel returns to the "no target" state (player HP + style toggles
## only).
@warning_ignore("unused_signal") signal target_cleared()
@warning_ignore("unused_signal") signal item_gained(item_name: String, qty: int)
@warning_ignore("unused_signal") signal open_forge()
@warning_ignore("unused_signal") signal open_cooking()
@warning_ignore("unused_signal") signal open_combat(monster: Node)
@warning_ignore("unused_signal") signal combat_ended()
@warning_ignore("unused_signal") signal player_hp_changed(current: int, maximum: int)
@warning_ignore("unused_signal") signal player_respawned(pos: Vector2)
@warning_ignore("unused_signal") signal camera_free_mode_changed(is_free: bool)
@warning_ignore("unused_signal") signal open_bank()
@warning_ignore("unused_signal") signal bank_changed()
@warning_ignore("unused_signal") signal thrall_deployed()
@warning_ignore("unused_signal") signal thrall_recalled()
@warning_ignore("unused_signal") signal thrall_returned(gains: Dictionary)
@warning_ignore("unused_signal") signal chat_message(text: String)
@warning_ignore("unused_signal") signal npc_dialogue(npc_name: String, text: String)
@warning_ignore("unused_signal") signal open_crafting()
@warning_ignore("unused_signal") signal open_construction()
@warning_ignore("unused_signal") signal open_runesmithing()
## Persistent combat-style toggle near the HP bar pushes this; the combat
## window's existing style buttons also listen so both UIs stay in sync.
## `active_rune` is "" unless `style == "magic"`.
@warning_ignore("unused_signal") signal combat_style_changed(style: String, active_rune: String)
@warning_ignore("unused_signal") signal monster_killed(monster_type: String)
@warning_ignore("unused_signal") signal quest_accepted(quest_id: String)
@warning_ignore("unused_signal") signal quest_updated(quest_id: String)
## Server pushed a fresh quest_state snapshot. Carries the full picture so
## listeners (QuestLog panel, marker renderer, NPC dialogue) never have to
## reconstruct from deltas — client mirrors the server's state.
@warning_ignore("unused_signal") signal quest_state_changed()
## Fired by HUD or hotkeys to open the floating QuestLog. The panel listens
## for this so any caller can pop it without touching the HUD directly.
@warning_ignore("unused_signal") signal open_quest_log()
## NPC click resolved to a quest interaction — show the modal in the given
## mode ("offer" / "turnin" / "reminder"). `quest_id` is the specific quest
## the modal renders; `npc_name` is the giver for chat-message context.
@warning_ignore("unused_signal") signal show_quest_dialogue(quest_id: String, mode: String, npc_name: String)
@warning_ignore("unused_signal") signal idle_summary(data: Dictionary)
@warning_ignore("unused_signal") signal player_context_menu(username: String, screen_pos: Vector2)
@warning_ignore("unused_signal") signal player_lookup_result(data: Dictionary)
@warning_ignore("unused_signal") signal monster_targeted(monster: Node)
@warning_ignore("unused_signal") signal player_died()

## Shared world state (server-authoritative resource nodes)
@warning_ignore("unused_signal") signal gather_granted(entity_id: String)
@warning_ignore("unused_signal") signal gather_denied(entity_id: String)
@warning_ignore("unused_signal") signal node_remote_locked(entity_id: String, username: String)
@warning_ignore("unused_signal") signal node_remote_unlocked(entity_id: String)
@warning_ignore("unused_signal") signal node_remote_depleted(entity_id: String, respawn_in: float)
@warning_ignore("unused_signal") signal node_remote_respawned(entity_id: String)
@warning_ignore("unused_signal") signal node_states_received(nodes: Array)

## Shared combat (server-authoritative monsters)
@warning_ignore("unused_signal") signal mob_state(entity_id: String, hp: int, max_hp: int)
@warning_ignore("unused_signal") signal mob_hit(entity_id: String, x: float, y: float, amount: int, by_username: String, hp: int, max_hp: int)
## xp_recipients is the AUTHORITATIVE list of usernames that should award
## XP for this kill. Computed server-side from the damage dict + the
## warband rule (2+ same-warband damagers → all warband participants share).
## participants is preserved for UI display ("Bjorn and Sigrid killed the
## troll") but never used for XP eligibility.
@warning_ignore("unused_signal") signal mob_died(entity_id: String, killer: String, xp_each: int, participants: Array, xp_recipients: Array)
@warning_ignore("unused_signal") signal mob_respawned(entity_id: String)

## Structure HP + destruction — emitted when the server broadcasts
## structure_hp_changed / structure_destroyed. Interactable nodes listen
## for their own id and update HP bars + kill the collision body.
@warning_ignore("unused_signal") signal structure_hp_changed(entity_id: String, hp: int, max_hp: int, alive: bool)
@warning_ignore("unused_signal") signal structure_destroyed(entity_id: String)
@warning_ignore("unused_signal") signal mob_dead_on_join(entity_id: String, respawn_in: float)
@warning_ignore("unused_signal") signal mob_full(entity_id: String)
@warning_ignore("unused_signal") signal mob_states_received(nodes: Array)
## Stage 2 server-side AI — batched position broadcast every 0.5s.
## NetworkManager emits this on each `monster_pos_update` message; World.gd
## listens and tweens each Monster node's global_position to the new coords
## over 0.45s (matched to the server tick so the motion looks smooth, with
## a 50ms safety margin so we don't run out of curve mid-transit).
## `updates` is an Array of {id, x, y, state, target} Dictionaries.
@warning_ignore("unused_signal") signal mob_positions_updated(updates: Array)

## Phase 3 of the gold economy — shop panel triggers and server replies.
##   open_shop:              NPC dispatch (Phase 4) emits this when the player
##                           clicks a shopkeeper; HUD listens, sends shop_open
##                           to the server, the server replies with shop_state.
##   shop_state_received:    Forwarded from NetworkManager on every shop_state
##                           message. Carries shop_name, multipliers, stock.
##   shop_result_received:   Forwarded from NetworkManager on every shop_result
##                           message (buy/sell outcome). Carries ok, reason,
##                           updated stock.
@warning_ignore("unused_signal") signal open_shop(npc_id: String, shop_id: String)
@warning_ignore("unused_signal") signal shop_state_received(state: Dictionary)
@warning_ignore("unused_signal") signal shop_result_received(result: Dictionary)

## Phase 5 of the gold economy — server-tracked gold piles broadcast on
## monster death. World.gd listens for spawn to instantiate a LootDrop pile
## visual at (x,y), and for remove to despawn the local node when the
## server confirms the pile was claimed or expired.
@warning_ignore("unused_signal") signal gold_pile_spawn(pile_id: String, x: float, y: float, amount: int)
@warning_ignore("unused_signal") signal gold_pile_remove(pile_id: String)

## Phase 6 of interiors — server replies to enter_interior / exit_interior.
## Phase 7's InteriorCache listens to these to fade-to-black and swap
## scenes. `interior_entered` carries the interior key and the entry
## position (local to the interior); `interior_exited` carries the return
## position on the exterior.
@warning_ignore("unused_signal") signal interior_entered(interior_id: String, x: float, y: float, return_x: float, return_y: float)
@warning_ignore("unused_signal") signal interior_exited(x: float, y: float)
@warning_ignore("unused_signal") signal interior_error(reason: String)

## Auction House
@warning_ignore("unused_signal") signal open_auction_house()
@warning_ignore("unused_signal") signal ah_listings_updated(listings: Array)
@warning_ignore("unused_signal") signal ah_my_listings_updated(listings: Array)
@warning_ignore("unused_signal") signal ah_purchase_result(ok: bool, reason: String)
@warning_ignore("unused_signal") signal ah_list_result(ok: bool, reason: String)
@warning_ignore("unused_signal") signal ah_cancel_result(ok: bool, reason: String)

## Trading
@warning_ignore("unused_signal") signal trade_request_received(from_username: String)
@warning_ignore("unused_signal") signal trade_offer_updated(their_items: Array, your_items: Array, their_gold: int, your_gold: int)
@warning_ignore("unused_signal") signal trade_confirmed(their_lock: bool, your_lock: bool)
@warning_ignore("unused_signal") signal trade_completed()
@warning_ignore("unused_signal") signal trade_cancelled(reason: String)

## Friends
@warning_ignore("unused_signal") signal friend_request_received(from_username: String)
@warning_ignore("unused_signal") signal friends_list_updated(friends: Array)

## Admin (Busterrdust) — server-persisted world entities
@warning_ignore("unused_signal") signal world_entities_received(entities: Array)
@warning_ignore("unused_signal") signal world_entity_added(entity: Dictionary)
@warning_ignore("unused_signal") signal world_entity_removed(entity_id: String)
@warning_ignore("unused_signal") signal world_entity_moved(entity_id: String, x: float, y: float)
@warning_ignore("unused_signal") signal tile_overrides_received(overrides: Array)
@warning_ignore("unused_signal") signal tile_override_set(tx: int, ty: int, biome: String)
@warning_ignore("unused_signal") signal tile_override_cleared(tx: int, ty: int)
## Tile editor v2 — bulk paint (brush stamp + flood fill), per-tile color
## tints, and per-tile passability paints. Each `entries` array carries
## the same per-tile dicts the server stored: `tile_set_bulk` entries are
## {tx, ty, biome|null}; `tile_tint_bulk` are {tx, ty, h, v}; passability
## entries are {tx, ty, passable}.
@warning_ignore("unused_signal") signal tile_overrides_bulk_received(entries: Array)
@warning_ignore("unused_signal") signal tile_tints_bulk_received(entries: Array)
@warning_ignore("unused_signal") signal tile_passability_bulk_received(entries: Array)
@warning_ignore("unused_signal") signal entity_edits_received(edits: Array)
@warning_ignore("unused_signal") signal entity_edit_applied(entity_id: String, deleted: bool, x: float, y: float)
@warning_ignore("unused_signal") signal minimap_refresh()

## Admin item-management (panel + chat commands). Replies routed back from
## the server's admin_give_item / admin_take_item / admin_view_inventory /
## admin_list_players / admin_restore_last_loss handlers.
@warning_ignore("unused_signal") signal admin_player_list_received(usernames: Array)
## Admin Accounts tab — each entry is a Dictionary with keys: username,
## email, email_verified, last_login_at, last_login_ip, locked_until,
## failed_login_count, created_at. See _handle_admin_list_accounts.
@warning_ignore("unused_signal") signal admin_account_list_received(accounts: Array)
## Touch-input adapter — fires at the halfway point of a long-press so a
## future UI overlay can show a ring-fill / progress hint. The actual
## right-click synthesis happens in TouchInput.gd at LONG_PRESS_SECONDS.
@warning_ignore("unused_signal") signal touch_long_press_armed(pos: Vector2)
@warning_ignore("unused_signal") signal admin_inventory_view_received(target: String, online: bool, inventory: Array)

## Fishing reel minigame (Phase 2 of the fishing rework). Player.gd emits
## `reel_minigame_start` instead of immediately granting the catch when a
## big/deep fish bites; the HUD spawns the modal panel and the panel emits
## `reel_minigame_ended` once the player wins (stamina drained) or loses
## (line snapped from tension). Player.gd grants XP+item only on success.
@warning_ignore("unused_signal") signal reel_minigame_start(catch_data: Dictionary)
@warning_ignore("unused_signal") signal reel_minigame_ended(catch_data: Dictionary, success: bool)

## Phase 3 fishing rework — random sea-monster encounters during deep/coast
## fishing. Player.gd rolls the encounter chance after a successful cast and
## emits `sea_combat_start` with the SeaMonsters table key. HUD spawns the
## boat-combat modal; the modal emits `sea_combat_ended` with the outcome
## ("win" → loot+xp, "flee" → no penalty, "lose" → boat sunk + HP damage).
@warning_ignore("unused_signal") signal sea_combat_start(monster_type: String)
@warning_ignore("unused_signal") signal sea_combat_ended(monster_type: String, outcome: String)
## Fired whenever the boat's hull HP changes mid-sail (Phase 3 sea combat
## damage). Player.gd watches this to refresh the floating HP bar drawn
## below the hull. Carried HP is the persistent value in GameManager.
@warning_ignore("unused_signal") signal boat_hp_changed(current: int, maximum: int)

## Phase 5 — cast balance minigame. Player.gd emits `cast_minigame_start`
## when the player clicks water with a fishing pole equipped; HUD spawns
## the modal. The modal emits `cast_minigame_ended` when the player wins
## (held green long enough) or loses (needle hit red). Player.gd uses the
## success boolean to gate the rest of the catch resolution.
@warning_ignore("unused_signal") signal cast_minigame_start()
## tier_bonus: 0 = normal catch, 1 = upgraded (teal zone), 2 = rare (gold zone).
## Only meaningful when success == true. On failure (orange miss / red snap)
## it's always 0.
@warning_ignore("unused_signal") signal cast_minigame_ended(success: bool, tier_bonus: int)

## Clan / Warband
@warning_ignore("unused_signal") signal clan_info_updated(clan: Dictionary)
@warning_ignore("unused_signal") signal clan_invite_received(from_username: String, clan_name: String, clan_id: String)
@warning_ignore("unused_signal") signal clan_result(ok: bool, reason: String)
