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
## PvP-Token currency balance changed (server-owned, Phase 1d).
@warning_ignore("unused_signal") signal pvp_tokens_changed(balance: int)
## A player said something in world chat (Phase 9) — used to spawn a world-space
## speech bubble above the speaker. Fires for local + remote (the server echoes
## the sender's own message back), NOT for system/[Server] lines.
@warning_ignore("unused_signal") signal player_chatted(username: String, text: String)
## Request to (re)play the first-login tutorial (Phase 2a) — fired by the
## Settings panel's "Replay Tutorial" button.
@warning_ignore("unused_signal") signal replay_tutorial()
## Open the how-to Guides overlay (Settings → Guides). Handled by HUD.
@warning_ignore("unused_signal") signal show_guides()
## Replay the opening storybook prologue (Settings → Replay Opening). Handled by
## World / World3D, which add a fresh OpeningPrologue (bypassing the first-login flag).
@warning_ignore("unused_signal") signal replay_prologue()
## Emitted by World / World3D when a scene's world FINISHES building (fresh login or a
## scene switch). `is_3d` says which client. The OpeningPrologue intro director waits on
## this to time its reveals so a scene load never shows through the book / white mask.
@warning_ignore("unused_signal") signal world_build_ready(is_3d: bool)
## Live rankings arrived from the server (Phase 3 #4) — real-account highscores.
@warning_ignore("unused_signal") signal rankings_updated(entries: Array)
## Town standing snapshot (Phase 5a). `towns` is one entry per town with
## personal / warband / effective values + tier. Read by the Reputation tab.
@warning_ignore("unused_signal") signal reputation_updated(towns: Array, in_warband: bool, warbands: Array)
## Killable town NPCs (Phase 5b) — server-authoritative hp/death/respawn,
## broadcast to everyone so a murdered NPC drops for all witnesses at once.
@warning_ignore("unused_signal") signal npc_hit(id: String, hp: int, max_hp: int)
@warning_ignore("unused_signal") signal npc_died(id: String)
@warning_ignore("unused_signal") signal npc_respawned(id: String)
## Trade caravans (Phase 5c) — server-owned position/state for both wagons,
## broadcast every tick. World.gd spawns/updates the Caravan nodes from this.
@warning_ignore("unused_signal") signal caravans_updated(list: Array)
@warning_ignore("unused_signal") signal caravan_hit(id: String, hp: int, max_hp: int)
@warning_ignore("unused_signal") signal caravan_destroyed(id: String, x: float, y: float, by: String)
@warning_ignore("unused_signal") signal caravan_removed(id: String)
## Dungeon entry (v1.5.3) — the server pushes the canonical layout; World builds
## the DungeonScene from it. `x`/`y` is the entry spawn, `return_*` the overworld
## exit coord. Reuses the interior exit path (Events has no separate exit signal).
@warning_ignore("unused_signal") signal dungeon_entered(dungeon_id: String, interior_id: String, layout: Dictionary, x: float, y: float, return_x: float, return_y: float)
## Thrall roster refreshed from the server (Phase 10). Read ThrallManager.roster.
@warning_ignore("unused_signal") signal thralls_updated()
## Offline thrall-work report delivered on login (Phase 10b). HUD shows a popup.
@warning_ignore("unused_signal") signal thrall_summary(summary: Dictionary)
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
## CraftMinigame → HUD active-craft. Reward per completed round:
## `speed_boost_frac` (0.20 = 20% faster on the current item),
## `bonus_xp` granted in the active craft's skill. HUD is the sole listener.
@warning_ignore("unused_signal") signal craft_minigame_completed(speed_boost_frac: float, bonus_xp: int)
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
## A monster (id) launched an attack — every nearby client plays its attack anim so
## fights read the same in 2D and 3D. Fired for ALL recipients, not just the target.
@warning_ignore("unused_signal") signal monster_attacked(entity_id: String)
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
## Emitted when the player actually gains HP (food, etc.) — carries the real
## amount healed (post-cap), so the HUD can float a "+N" over the player.
@warning_ignore("unused_signal") signal player_healed(amount: int)
@warning_ignore("unused_signal") signal player_respawned(pos: Vector2)
@warning_ignore("unused_signal") signal camera_free_mode_changed(is_free: bool)
@warning_ignore("unused_signal") signal open_bank()
@warning_ignore("unused_signal") signal bank_changed()
@warning_ignore("unused_signal") signal thrall_deployed()
@warning_ignore("unused_signal") signal thrall_recalled()
@warning_ignore("unused_signal") signal thrall_returned(gains: Dictionary)
@warning_ignore("unused_signal") signal chat_message(text: String)
## Genuine multiplayer player chat — the ONLY source routed to the World tab.
## Everything on `chat_message` (status/notifications) goes to the Events tab.
@warning_ignore("unused_signal") signal world_chat(username: String, text: String)
@warning_ignore("unused_signal") signal npc_dialogue(npc_name: String, text: String)
@warning_ignore("unused_signal") signal open_crafting()
@warning_ignore("unused_signal") signal open_construction()
@warning_ignore("unused_signal") signal open_runesmithing()
## Left-clicking an empty Farm Plot asks the HUD to open the seed-plant popup.
@warning_ignore("unused_signal") signal farm_plant_requested(entity_id: String)
## Fishing biggest-catch records / journal were refreshed (NetworkManager caches).
@warning_ignore("unused_signal") signal fishing_data_updated()
## Open the Fishing Journal window (personal bests vs world records).
@warning_ignore("unused_signal") signal open_fishing_journal()
## Spectator recording: the watched player's HUD state (skills/inventory/gear)
## arrived from the server. SpectatorHUD listens to refresh its display.
@warning_ignore("unused_signal") signal spectate_state_updated()
## A watched player mimed an action the spectator should SHOW on camera by opening
## the matching window (e.g. "bank", "craft"). Emitted by NetworkManager when the
## player_action is for the spectate target; handled by SpectatorDirector.
@warning_ignore("unused_signal") signal spectate_mime(action: String)
## Spectator combat readout — the watched bot relays its fight so the spectator's
## combat window opens + logs like a real player. start = engage (open the window),
## hit = one blow (mine=true: we hit the mob; false: it hit us), end = fight over.
## Robust spectator feedback toast (fixed screen position, independent of the
## camera/player) so a watched bot's XP/loot/level ALWAYS shows on the recording —
## the normal _show_toast path anchors to the local player, which is an invisible
## puppet in spectator mode. kind ∈ {"xp","item","level"} for colouring.
@warning_ignore("unused_signal") signal spectate_feedback(text: String, kind: String)
@warning_ignore("unused_signal") signal spectate_combat_start(monster_name: String, level: int)
@warning_ignore("unused_signal") signal spectate_combat_hit(monster_name: String, amount: int, mine: bool)
@warning_ignore("unused_signal") signal spectate_combat_end(monster_name: String, result: String)
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
@warning_ignore("unused_signal") signal node_remote_respawned(entity_id: String, x: float, y: float)
@warning_ignore("unused_signal") signal node_states_received(nodes: Array)

## Shared combat (server-authoritative monsters)
@warning_ignore("unused_signal") signal mob_state(entity_id: String, hp: int, max_hp: int)
@warning_ignore("unused_signal") signal mob_hit(entity_id: String, x: float, y: float, amount: int, by_username: String, hp: int, max_hp: int, crit: bool, missed: bool)
## v1.7 B3 — server told us to roll a killed monster's loot locally (un-baked
## fallback so loot never breaks pre-bake). World finds the mob + spawn_loot_drops.
@warning_ignore("unused_signal") signal loot_fallback(monster_id: String)
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
@warning_ignore("unused_signal") signal world_entity_rotated(entity_id: String, rot: float)
## Server-driven top-of-screen toast (e.g. "Get closer to attack the wall.").
@warning_ignore("unused_signal") signal top_toast(text: String)
@warning_ignore("unused_signal") signal terrain_heights_received(tiles: Dictionary)
@warning_ignore("unused_signal") signal terrain_height_set(tiles: Dictionary)
## Admin-drawn road network updated (login burst or a live edit). The road
## overlay + editor redraw from GameManager.road_nodes/road_edges.
@warning_ignore("unused_signal") signal road_graph_updated()
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
## Admin DATA override for a pre-existing entity (n:/b:/…) — name/dialogue/level.
## Worlds apply it to the live node + cache it for re-spawn.
@warning_ignore("unused_signal") signal entity_data_edited(entity_id: String, data: Dictionary)
@warning_ignore("unused_signal") signal minimap_refresh()

## Admin item-management (panel + chat commands). Replies routed back from
## the server's admin_give_item / admin_take_item / admin_view_inventory /
## admin_list_players / admin_restore_last_loss handlers.
@warning_ignore("unused_signal") signal admin_player_list_received(usernames: Array)
## Echo of a successful admin_place — the AdminPanel Undo stack listens so it can
## reverse a placement (the client only learns the new a: id from this reply).
@warning_ignore("unused_signal") signal admin_entity_placed(id: String, kind: String, subtype: String, x: float, y: float)
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

## Skill training mini-games (v1.6.6). A training station (Archery/Runestone/melee
## dummy) emits `skill_minigame_start` with a config dict {skill, level, shots,
## ammo_id, theme, station}; HUD spawns the SkillMinigame modal. The modal consumes
## ammo per shot and emits `skill_minigame_ended` with a result dict {skill, score,
## shots_fired, xp}; HUD awards the (accuracy-scaled) XP + a toast.
@warning_ignore("unused_signal") signal skill_minigame_start(cfg: Dictionary)
@warning_ignore("unused_signal") signal skill_minigame_ended(result: Dictionary)

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
