extends CanvasLayer

const GearDB             = preload("res://scripts/Equipment.gd")
# ItemArt is `class_name ItemArt` in scripts/ItemArt.gd — the global
# identifier resolves automatically, so no preload const (which would
# just shadow the global class name).
const Boats              = preload("res://scripts/Boat.gd")
const ReelMinigame       = preload("res://scripts/ui/ReelMinigame.gd")
const SkillMinigame      = preload("res://scripts/ui/SkillMinigame.gd")
const BoatCombat         = preload("res://scripts/ui/BoatCombat.gd")
const CastBalanceMinigame = preload("res://scripts/ui/CastBalanceMinigame.gd")
const ShopCatalog        = preload("res://scripts/ShopCatalog.gd")
const ItemPrices         = preload("res://scripts/ItemPrices.gd")
const RuneSpells         = preload("res://scripts/RuneSpells.gd")
const _GuideData         = preload("res://scripts/GuideData.gd")

## Full HUD — built entirely in code, no .tscn needed.
##
## Layout
## ──────────────────────────────────────────────────────────────
##  Left edge             Right of strip
##  [Tab strip 48px]      [Content panel 224px]   ← both bottom-left
##  Bottom-center                                  ← interaction popup
##  Top-center                                     ← hover tooltip
##  Bottom-left (below strip)                      ← tile coords

# ── Palette ────────────────────────────────────────────────────────────────
const RS_BG     := Color(0.11, 0.07, 0.03)
const RS_BORDER := Color(0.64, 0.49, 0.14)
const RS_BTN_N  := Color(0.08, 0.05, 0.02)
const RS_BTN_A  := Color(0.20, 0.13, 0.05)   # active tab bg
const RS_BTN_H  := Color(0.15, 0.09, 0.03)   # hover

const RS_TEXT   := Color(0.92, 0.85, 0.62)
const RS_DIM    := Color(0.60, 0.55, 0.38)

# Proximity gate for right-click gather / interact actions. The player must
# be within 1.5 tiles (48 px) of the target node or the action is refused
# with a top-of-screen toast. Excludes Attack (its own range system),
# Talk / Browse / Examine / Enter (dialog or warp actions that don't need
# you to be hugging the node).
const ACTION_PROXIMITY      := 48.0
const GATED_ACTION_LABELS := {
	"Chop": true, "Mine": true, "Fish": true, "Pick": true, "Gather": true,
	"Smith": true, "Cook": true, "Craft": true, "Build": true,
	"Study": true, "Runesmith": true, "Train": true, "Use Bank": true,
}

# Max distance at which the Attack button is enabled. 14 tiles × 32 px = 448 px.
# The chase across this distance now actually completes — the server's home
# leash used to teleport the monster back to spawn after ~300 px of chasing
# regardless of aggro state, and Monster.gd's local pursuit fought with the
# server's tween. Both fixed; this range is the new ceiling for engagement.
# Also enforces a walkability check — the panel won't let you engage across
# water or other impassable terrain since the monster's straight-line pathing
# can't cross it.
const ATTACK_INITIATE_RANGE := 448.0
const RS_GOLD   := Color(1.00, 0.85, 0.25)
const RS_GREEN  := Color(0.40, 0.90, 0.40)

const SKILL_COLORS := {
	"woodcutting":  Color(0.30, 0.80, 0.25),
	"mining":       Color(0.70, 0.68, 0.75),
	"fishing":      Color(0.25, 0.70, 0.92),
	"farming":      Color(0.50, 0.88, 0.30),
	"jewelcrafting":Color(0.95, 0.82, 0.35),
	"melee":        Color(0.92, 0.28, 0.28),
	"defense":      Color(0.28, 0.45, 0.88),
	"ranged":       Color(0.72, 0.88, 0.22),
	"magic":        Color(0.55, 0.28, 0.92),
	"cooking":      Color(0.92, 0.60, 0.18),
	"smithing":     Color(0.68, 0.65, 0.28),
	"crafting":     Color(0.82, 0.55, 0.18),
	"construction": Color(0.78, 0.55, 0.28),
	"vitality":     Color(0.92, 0.22, 0.22),
	"soul":         Color(0.78, 0.48, 0.92),
}

var _active_toasts: int = 0

# ── Tab definitions ─────────────────────────────────────────────────────────
const TABS := [
	{"id": "inv",  "icon": "⚔",  "img": "tab_inv",    "tip": "Inventory"},
	{"id": "eqp",  "icon": "🛡",  "img": "tab_equip",  "tip": "Equipment"},
	{"id": "crf",  "icon": "💎",  "img": "tab_craft",  "tip": "Crafting"},
	{"id": "lvl",  "icon": "★",  "img": "tab_skills",  "tip": "Skills"},
	{"id": "qst",  "icon": "!",  "tip": "Quests"},
	{"id": "thr",  "icon": "⚒",  "img": "tab_thrall", "tip": "Thrall"},
	# Warband + Friends merged into one Social tab (Phase 3).
	{"id": "wrb",  "icon": "☻",  "tip": "Warband & Friends"},
	{"id": "rep",  "icon": "⚑",  "tip": "Reputation"},
	{"id": "rnk",  "icon": "◈",  "img": "tab_rank",   "tip": "Rankings"},
	{"id": "set",  "icon": "⚙",  "tip": "Settings"},
]

# ── State ───────────────────────────────────────────────────────────────────
var _active_tab    := ""          # "" = panel closed
var _tab_buttons   := {}          # id → Button
var _tab_contents  := {}          # id → Control
var _content_panel: PanelContainer = null
var _popup:         PanelContainer = null
var _action_lbl:    Label          = null
var _target_lbl:    Label          = null
var _hover_lbl:     Label          = null
var _coords_lbl:    Label          = null
var _inv_slots:        Array[Dictionary] = []   # {slot, color_rect, name_lbl, qty_lbl}
var _inv_gold_lbl:     Label             = null
var _inv_boots_lbl:    Label             = null
var _equip_slots:      Dictionary        = {}   # slot_id → {icon_rect, lbl}
var _equip_stats_lbl:  Label             = null
var _equip_panel:      PanelContainer    = null
var _boat_prompt_btn:  Button            = null
var _forge_window:     PanelContainer    = null
var _forge_recipe_btns: Array[Button]  = []
var _cook_window:      PanelContainer   = null
var _cook_recipe_btns: Array[Button]   = []
var _craft_window:        PanelContainer  = null
var _craft_recipe_btns:   Array[Button]  = []
var _construct_window:    PanelContainer  = null
var _construct_recipe_btns: Array[Button] = []
var _rune_window:         PanelContainer  = null
var _rune_recipe_btns:    Array[Button]   = []
var _skill_info_window: PanelContainer  = null
var _skill_info_title:  Label           = null
var _skill_info_body:   VBoxContainer   = null
var _hp_bar:            ProgressBar     = null
var _hp_lbl:            Label           = null
## Active-craft state — one timed cook / smelt at a time across every
## recipe window. Field bag: `recipe_id`, `recipe`, `remaining`, `qty`,
## `tick_left`, `tick_dur`, `card`, `prog_bar`, `prog_row`, `btn`,
## `qty_spin`, `verb`, `skill`, `single_action`. Empty when nothing is
## running. `_process` ticks it every frame; the recipe cards read
## `_active_craft.recipe_id` on refresh to disable everything else.
var _active_craft: Dictionary = {}
## Every card ever built, keyed by recipe_id, so refresh + cancel can
## reach into a card's prog bar / button without a full tree walk.
var _recipe_card_index: Dictionary = {}

var _combat_window:     PanelContainer  = null
## Header-drag + minimize state — the entire panel body below the header
## lives in `_combat_content` so the minimize toggle hides one node. Drag
## captures via gui_input on the top_row and shifts all four offsets by
## the mouse delta each frame (keeps size stable across the right-anchored
## origin).
var _combat_content:    VBoxContainer   = null
var _combat_min_btn:    Button          = null
var _combat_minimized:  bool            = false
var _combat_drag:       bool            = false
const _COMBAT_WIN_H_OPEN: int = 296
const _COMBAT_WIN_H_MIN:  int = 44
var _combat_monster:    Node            = null
# Unified panel — _selected_target is the monster currently shown in the
# panel's target section. May be set without _in_combat being true (player
# clicked but hasn't pressed Attack yet). Cleared when the player closes
# the panel, right-clicks, or the target dies.
var _selected_target:   Node            = null
var _target_section:    VBoxContainer   = null   # parent for the target rows (name/level/HP/Attack)
var _target_name_lbl:   Label           = null
var _target_lvl_lbl:    Label           = null
var _target_hp_bar:     ProgressBar     = null
var _target_hp_lbl:     Label           = null
var _attack_btn:        Button          = null
var _flee_btn:          Button          = null
var _combat_log_box:    VBoxContainer   = null   # wraps log + flee, shown only in combat
var _combat_plr_bar:    ProgressBar     = null
var _combat_plr_lbl:    Label           = null
var _combat_log:        Label           = null
var _combat_style:      String          = "melee"
var _style_btns:        Dictionary      = {}
# Rune sub-row — kept the `_persist_*` names because the existing rune-row
# refresh/click handlers reference them. The row now lives inside the
# unified panel, not in a separate persistent strip.
var _persist_rune_row:    HBoxContainer = null   # visible only when style == "magic"
var _persist_rune_btns:   Dictionary    = {}     # rune_id → Button
# Per-fight "out of ammo / runes" fallback chat dedupe.
var _out_of_resource_chatted: bool      = false
var _in_combat:         bool            = false
var _combat_atk_timer:  float           = 0.0
var _combat_mon_timer:  float           = 0.0
# Shared (server-authoritative) combat
var _combat_server:        bool         = false   # this fight is server-driven
var _combat_join_pending:  bool         = false   # waiting for server to ack the join
# ⑦/⑧ — the per-swing XP + skill of the CURRENT swing, so the attack intent can
# carry it to the server (which sets its grant ceiling to match what we granted).
var _swing_xp_pending:     int          = 4
var _swing_skill_pending:  String       = "melee"
var _combat_join_wait:     float        = 0.0
const COMBAT_JOIN_TIMEOUT := 2.0
var _popup_tween:   Tween          = null
var _player:        Node           = null
var _cam_lock_btn:  Button         = null

# Bank window
var _bank_window:      PanelContainer    = null
var _bank_gold_lbl:    Label             = null   # gold-bank row (Phase 3 #3)
var _bank_gold_amount: LineEdit          = null

# Auction House window
var _ah_window:          PanelContainer    = null
var _ah_listings:        Array             = []
var _ah_my_listings:     Array             = []
var _ah_browse_list:     VBoxContainer     = null
var _ah_mine_list:       VBoxContainer     = null
var _ah_sell_inv_list:   VBoxContainer     = null
var _ah_search_field:    LineEdit          = null

# Trade window
var _trade_window:       PanelContainer    = null
var _trade_your_items:   Array[Dictionary] = []   # items we're offering
var _trade_their_items:  Array[Dictionary] = []   # items they're offering
var _trade_partner:      String            = ""
var _trade_your_locked:  bool              = false
var _trade_their_locked: bool              = false
var _trade_your_slots:   Array[Control]    = []
var _trade_their_slots:  Array[Control]    = []
var _trade_lock_btn:     Button            = null
var _trade_confirm_btn:  Button            = null
var _trade_status_lbl:   Label             = null
var _trade_your_gold:    int               = 0
var _trade_their_gold:   int               = 0
var _trade_gold_field:   LineEdit          = null
var _trade_their_gold_lbl: Label           = null

var _chat_line_edit: LineEdit      = null

# Clan / Warband
var _warband_root: VBoxContainer = null
var _clan:         Dictionary    = {}   # {} = not in a clan
# Tiled clan bank state (Phase 3 #2)
const _CLAN_MAX_TABS := 3
var _clan_active_tab: int = 0
var _clan_gold_amount: LineEdit = null

var _bank_inv_slots:   Array[Dictionary] = []   # {slot, color_rect, name_lbl, qty_lbl}
var _bank_stash_slots: Array[Dictionary] = []   # same, for bank storage

# Chat
var _chat_vbox:       VBoxContainer  = null
# Each history entry: {text: String, category: String} — category is one of
# "world" / "private" / "events". Used to filter the displayed list when
# the player switches tabs. CHAT_MAX caps the buffer globally; per-tab
# display is just a filter over the same buffer.
var _chat_history:    Array[Dictionary] = []
const CHAT_MAX       := 120
const CHAT_CAT_WORLD   := "world"
const CHAT_CAT_PRIVATE := "private"
const CHAT_CAT_EVENTS  := "events"
var _chat_active_cat:  String = "world"
var _chat_tab_btns:    Dictionary = {}    # category → Button
var _chat_panel:      PanelContainer = null
var _chat_content:    VBoxContainer  = null   # scroll + line_edit wrapper
var _chat_minimized:  bool           = false
var _chat_collapse_btn: Button       = null   # the ▲/▼ collapse toggle (spectator uses it)
var _chat_notif_dot:  Label          = null   # red "new messages" dot (minimized)
var _chat_drag:       bool           = false  # header being dragged


# Minimap
var _minimap_canvas:    Control        = null
var _minimap_texture:   ImageTexture   = null
var _minimap_panel:     PanelContainer = null
var _minimap_content:   Control        = null   # the canvas control
var _minimap_minimized: bool           = false
## Minimap heading (radians) — the 3D client sets this to the camera yaw so the map
## rotates with the view (forward = up). 0 in 2D → no rotation.
var minimap_heading: float = 0.0
func set_minimap_heading(h: float) -> void:
	if absf(h - minimap_heading) < 0.005:
		return
	minimap_heading = h
	if _minimap_canvas != null:
		_minimap_canvas.queue_redraw()
# Fullscreen minimap viewer — playtest addition. Opened by clicking the
# corner minimap. Zoom via wheel, pan via click-drag, ESC/X to close.
var _mm_full_panel:     PanelContainer = null
var _mm_full_canvas:    Control        = null
var _mm_full_zoom:      float          = 1.5   # 1.0 = whole world fits; higher zooms in
var _mm_full_center_tx: float          = 150.0
var _mm_full_center_ty: float          = 150.0
var _mm_full_dragging:  bool           = false
## Admin-only: when true, a left-click on the fullscreen map teleports the
## player to that spot instead of panning. Toggled by the ⚡ button.
var _mm_teleport_mode:  bool           = false

# NPC dialogue popup
var _dialogue_window:  PanelContainer = null
var _dialogue_npc_lbl: Label          = null
var _dialogue_text_lbl: Label         = null

# Proximity auto-close for location-tied panels. Maps panel Control nodes to
# the world position of the interactable that opened them. Checked every
# 0.5s in _process; when the player exceeds CLOSE_RADIUS, the panel is hidden
# and a chat message fires. Player-owned panels (inventory, skills, map,
# quest log) are NEVER added to this map.
var _proximity_panels: Dictionary = {}   # Control → Vector2 world pos
var _proximity_timer: float       = 0.0
const PROXIMITY_TICK   := 0.5
const PROXIMITY_RADIUS := 96.0   # 3 tiles at 32 px/tile
# Last interactable world pos seen via player_interacted — used as the
# anchor for whichever open_* event fires next.
var _last_interaction_pos: Vector2 = Vector2.ZERO
var _has_last_interaction: bool    = false

# Dedicated CanvasLayer at layer 95 for floating damage numbers + the red
# vignette flash. Lives above every HUD modal so combat feedback is never
# occluded by a panel that happened to be open. Lazy-built on first use.
var _dmg_layer: CanvasLayer = null

# Thrall tab internals
var _thrall_roster_list: VBoxContainer = null
var _thrall_slot_lbl: Label = null
var _thrall_buy_slot_btn: Button = null

# ── Lifecycle ────────────────────────────────────────────────────────────────
func _ready() -> void:
	add_to_group("hud")
	_build_ui()
	Events.ui_show_interaction.connect(_on_show)
	Events.ui_hide_interaction.connect(_on_hide)
	Events.boat_prompt.connect(_on_boat_prompt)
	Events.skill_cell_pressed.connect(_on_skill_cell_pressed)
	Events.top_toast.connect(func(text: String) -> void:
		if text != "": _show_top_toast(text, Color(0.95, 0.55, 0.30)))
	Events.inventory_changed.connect(_refresh_inventory)
	# Live-refresh the forge + construction recipe buttons when materials change
	# while the window is open (e.g. mining ore, or an admin granting items to
	# test). Without this they stay frozen in their open-time disabled state and
	# never light up — the "buttons don't become clickable" playtest bug.
	Events.inventory_changed.connect(_refresh_forge_if_visible)
	Events.inventory_changed.connect(_refresh_construction_if_visible)
	Events.inventory_changed.connect(_refresh_bank_gold)
	Events.equipment_changed.connect(_refresh_equipment)
	Events.xp_gained.connect(_on_xp_gained)
	Events.open_forge.connect(_on_open_forge)
	Events.open_cooking.connect(_on_open_cooking)
	Events.minimap_refresh.connect(_regen_minimap)
	# First-login tutorial (Phase 2a): auto-run once per account, replayable
	# from Settings. login_ok is deferred so the local player exists first.
	NetworkManager.login_ok.connect(func(pdata: Dictionary) -> void:
		var uname := str(pdata.get("username", ""))
		_load_discovered_towns(uname)
		# Server-persisted unlocks are authoritative (1-time, account-level) — merge
		# them in so fast-travel stays unlocked across logouts + devices.
		for t: Variant in (pdata.get("discovered_towns", []) as Array):
			_discovered_towns[str(t)] = true
		if not _tutorial_seen(uname):
			call_deferred("start_tutorial"))
	Events.replay_tutorial.connect(start_tutorial)
	Events.show_guides.connect(_show_guides)
	Events.open_combat.connect(_on_open_combat)
	Events.combat_ended.connect(_on_combat_ended)
	Events.mob_hit.connect(_on_mob_hit_hud)
	Events.mob_state.connect(_on_mob_state_hud)
	Events.mob_dead_on_join.connect(_on_mob_dead_on_join_hud)
	Events.mob_full.connect(_on_mob_full_hud)
	Events.player_hp_changed.connect(_on_player_hp_changed)
	Events.player_healed.connect(_on_player_healed)
	Events.player_chatted.connect(_on_player_chatted)
	Events.camera_free_mode_changed.connect(_on_camera_free_mode_changed)
	Events.open_bank.connect(_on_open_bank)
	Events.bank_changed.connect(_refresh_bank)
	Events.xp_gained.connect(_on_chat_xp)
	Events.thrall_returned.connect(_on_thrall_returned)
	# Phase 2 fishing rework — Player.gd fires reel_minigame_start when a big
	# fish bites; spawn the modal as a HUD child so it cleans up with the HUD
	# if the player logs out mid-reel.
	Events.reel_minigame_start.connect(_on_reel_minigame_start)
	Events.skill_minigame_start.connect(_on_skill_minigame_start)
	Events.skill_minigame_ended.connect(_on_skill_minigame_ended)
	# Phase 3 fishing rework — Player.gd fires sea_combat_start when an
	# encounter roll triggers a monster instead of a fish.
	Events.sea_combat_start.connect(_on_sea_combat_start)
	# Phase 5 fishing rework — Player.gd fires cast_minigame_start when the
	# player clicks water with a pole equipped. The modal replaces the old
	# 3.5s passive wait with active play.
	Events.cast_minigame_start.connect(_on_cast_minigame_start)
	Events.chat_message.connect(_add_chat_message)
	# Genuine player chat is the only thing that lands in the World tab; all the
	# incidental status lines on chat_message fall to Events (see _categorize_chat).
	Events.world_chat.connect(func(uname: String, text: String) -> void:
		_add_chat_message_typed("%s: %s" % [uname, text], CHAT_CAT_WORLD))
	Events.npc_dialogue.connect(_on_npc_dialogue)
	Events.open_crafting.connect(_on_open_crafting)
	Events.open_construction.connect(_on_open_construction)
	Events.farm_plant_requested.connect(_open_farm_plant_popup)
	Events.open_fishing_journal.connect(_open_fishing_journal)
	Events.open_runesmithing.connect(_on_open_runesmithing)
	# Phase 3 of the gold economy — NPC dispatch (Phase 4) fires open_shop;
	# server replies route through the two received signals.
	Events.open_shop.connect(_on_open_shop)
	Events.shop_state_received.connect(_on_shop_state_received)
	Events.shop_result_received.connect(_on_shop_result_received)
	Events.open_auction_house.connect(_on_open_auction_house)
	Events.ah_listings_updated.connect(_on_ah_listings_updated)
	Events.ah_my_listings_updated.connect(_on_ah_my_listings_updated)
	Events.ah_purchase_result.connect(_on_ah_purchase_result)
	Events.ah_list_result.connect(_on_ah_list_result)
	Events.ah_cancel_result.connect(_on_ah_cancel_result)
	Events.idle_summary.connect(_show_idle_summary)
	Events.thrall_summary.connect(_show_thrall_summary)
	Events.player_context_menu.connect(_on_player_context_menu)
	Events.monster_clicked.connect(_on_monster_clicked)
	Events.action_menu_requested.connect(_on_action_menu_requested)
	Events.target_cleared.connect(_clear_target)
	Events.player_lookup_result.connect(_on_player_lookup_result)
	Events.xp_gained.connect(_on_toast_xp)
	Events.item_gained.connect(_on_toast_item)
	Events.spectate_feedback.connect(_on_spectate_feedback)
	Events.player_died.connect(_on_player_died)
	Events.trade_request_received.connect(_on_trade_request_received)
	Events.trade_offer_updated.connect(_on_trade_offer_updated)
	Events.trade_confirmed.connect(_on_trade_confirmed)
	Events.trade_completed.connect(_on_trade_completed)
	Events.trade_cancelled.connect(_on_trade_cancelled)
	Events.friend_request_received.connect(_on_friend_request_received)
	Events.request_whisper.connect(_start_whisper)
	Events.request_trade.connect(_on_request_trade)
	Events.clan_info_updated.connect(_on_clan_info_updated)
	# CraftMinigame reward hook — every completed round trims the current
	# item's tick + grants small bonus XP in the active skill.
	Events.craft_minigame_completed.connect(_on_craft_minigame_completed)
	Events.clan_invite_received.connect(_on_clan_invite_received)
	# Proximity auto-close: track the world position of whichever interactable
	# the player just reached, so the next open_* event can anchor here.
	Events.player_interacted.connect(_on_player_interacted_for_proximity)

func _process(delta: float) -> void:
	_autoplay_ui_failsafe()
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player != null and _coords_lbl != null:
		var tx := int(_player.global_position.x / 32)
		var ty := int(_player.global_position.y / 32)
		_coords_lbl.text = "(%d, %d)" % [tx, ty]
	if _in_combat:
		_combat_tick(delta)
	# Timed batch cook/smelt — one active at a time across every recipe
	# window. Ticked every frame; cheap check when nothing is running.
	if not _active_craft.is_empty():
		_tick_active_craft(delta)
	# PvP swing loop is orthogonal to _in_combat (monster combat) — it
	# only fires when `_pvp_target` is set, regardless of whether we're
	# also mid-fight with a monster. Cheap enough to check every frame.
	if _pvp_target != null:
		_pvp_swing_tick(delta)
	_position_pvp_attacker_panel()
	if _tutorial_step >= 0:
		_tutorial_tick(delta)
	_discovery_tick(delta)
	if _pvp_target == null and _selected_target != null:
		# Out of combat but a target is selected — keep the panel's target
		# HP bar live (target may be taking damage from other players or
		# despawning). _update_combat_ui handles invalid/dead self-clear.
		_update_combat_ui()
	if _minimap_canvas != null:
		_minimap_canvas.queue_redraw()
	if _mm_full_panel != null and _mm_full_panel.visible:
		_mm_full_canvas.queue_redraw()
	# PvP button label is stateful (cooldown mm:ss). Refreshing every frame
	# is cheap — a single string swap on one Button.
	if _pvp_btn != null:
		_refresh_pvp_btn()
	# Proximity auto-close — only ticks every PROXIMITY_TICK seconds to keep
	# the per-frame cost flat. Walks the tracked-panel dict and closes any
	# panel whose owning interactable is now too far from the player.
	_proximity_timer += delta
	if _proximity_timer >= PROXIMITY_TICK:
		_proximity_timer = 0.0
		_tick_proximity_panels()

# ── Proximity auto-close for location-tied panels ────────────────────────────
## Player got close to an interactable and the action fired — snapshot its
## world position so whichever panel opens next anchors here. The position
## is cleared after one open_* event consumes it so a stale interactable
## can't pin a panel that opens later for unrelated reasons.
func _on_player_interacted_for_proximity(node: Node) -> void:
	if node == null or not (node is Node2D):
		return
	_last_interaction_pos = (node as Node2D).global_position
	_has_last_interaction = true

## Called by each open_* handler that's tied to a world location. Registers
## the panel with the world position captured at the last player_interacted
## event. Falls back to the player's current position if no recent
## interaction is on file (e.g. a panel opened via hotkey, not by clicking
## an interactable) — that effectively disables the auto-close for that
## open, which is the right behaviour.
func _register_proximity_panel(panel: Control) -> void:
	if panel == null:
		return
	var anchor: Vector2
	if _has_last_interaction:
		anchor = _last_interaction_pos
		_has_last_interaction = false   # one-shot consume
	elif _player != null:
		anchor = (_player as Node2D).global_position
	else:
		return
	_proximity_panels[panel] = anchor

## Walks the tracker dict once per PROXIMITY_TICK. Closes any panel whose
## anchor distance from the player exceeds PROXIMITY_RADIUS. Skips invisible
## entries (player already closed them via the X button) so the dict gets
## pruned naturally as panels are dismissed.
func _tick_proximity_panels() -> void:
	if _proximity_panels.is_empty() or _player == null:
		return
	var p_pos := (_player as Node2D).global_position
	var to_remove: Array[Control] = []
	for panel: Variant in _proximity_panels.keys():
		var c := panel as Control
		if c == null or not is_instance_valid(c):
			to_remove.append(c)
			continue
		if not c.visible:
			to_remove.append(c)   # closed via the X button — prune
			continue
		var pos: Vector2 = _proximity_panels[panel]
		if p_pos.distance_to(pos) > PROXIMITY_RADIUS:
			c.visible = false
			to_remove.append(c)
			Events.chat_message.emit("You moved too far away.")
	for c: Control in to_remove:
		_proximity_panels.erase(c)

# ── StyleBox helper ──────────────────────────────────────────────────────────
func _rs(bg: Color, border: Color, bw: int = 3) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_border_width_all(bw)
	s.border_color = border
	s.set_corner_radius_all(2)
	return s

# ── Master build ────────────────────────────────────────────────────────────
func _build_ui() -> void:
	_build_tab_strip()
	_build_content_panel()
	_build_equipment_panel()
	_build_boat_prompt()
	_build_hover_label()
	_build_interaction_popup()
	_build_coords_label()
	_build_hp_bar()
	_build_pvp_toggle()
	# Persistent strip merged into the unified panel; no separate build call.
	_build_forge_window()
	_build_cook_window()
	_build_craft_window()
	_build_skill_info_window()
	_build_combat_window()
	_build_cam_lock_button()
	_build_bank_window()
	_build_chat_box()
	_build_minimap()
	_build_dialogue_window()
	_build_construction_window()
	_build_shop_window()
	_build_rune_window()
	_build_quest_log()
	_build_quest_dialog()
	_build_quest_markers()
	_build_token_upgrade_window()
	_build_pvp_attacker_panel()
	_build_tutorial()
	_build_travel_window()
	_build_vignette()

# Post-processing vignette — fullscreen ColorRect at layer 2, above world
# (layer 0) and HUD UI (default layer 1) but below QuestMarkers (5), quest
# modals (80/85), and the damage layer (95). Modal panels and combat
# feedback stay undimmed; the world and HUD chrome get the cinematic edge.
const _VIGNETTE_SHADER = preload("res://shaders/vignette.gdshader")
var _vignette_layer: CanvasLayer = null
func _build_vignette() -> void:
	_vignette_layer = CanvasLayer.new()
	_vignette_layer.layer = 2
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.color = Color.WHITE   # shader overwrites COLOR in fragment
	var mat := ShaderMaterial.new()
	mat.shader = _VIGNETTE_SHADER
	rect.material = mat
	_vignette_layer.add_child.call_deferred(rect)
	get_tree().root.add_child.call_deferred(_vignette_layer)

# Floating WoW-style QuestLog modal. Self-managing: spawns once at startup
# and listens for Events.open_quest_log to show itself; auto-refreshes on
# Events.quest_state_changed. No HUD references stored beyond the spawn.
const _QuestLogScene = preload("res://scripts/ui/QuestLog.gd")
func _build_quest_log() -> void:
	var ql := _QuestLogScene.new()
	add_child(ql)

# NPC quest-interaction modal (offer / turn-in / reminder). Self-managing:
# listens for Events.show_quest_dialogue. NPC.gd emits the signal after
# evaluating quest priority on every interactable click.
const _QuestDialogScene = preload("res://scripts/ui/QuestDialog.gd")
func _build_quest_dialog() -> void:
	var qd := _QuestDialogScene.new()
	add_child(qd)

# Quest marker overlay — purple ! / + above active-quest targets. Hosted INSIDE
# this HUD (layer 1) as the BOTTOM-most child, so markers render ABOVE the world
# (layer 0) but BELOW every HUD element — the minimap, panels, chat — and below all
# modals. (They used to live on their own CanvasLayer at layer 5, which drew OVER
# the minimap + UI; the user wants them to always lay UNDER the UI.) The Control
# fills the screen and reads world→screen via the viewport's canvas_transform.
const _QuestMarkers = preload("res://scripts/ui/QuestMarkers.gd")
func _build_quest_markers() -> void:
	var marker := _QuestMarkers.new() as Control
	_quest_marker = marker
	# Deferred because we're still inside HUD._ready; add it, then send it to the
	# BACK (child index 0) so all other HUD controls draw on top of it.
	_install_quest_markers.call_deferred(marker)

func _install_quest_markers(marker: Control) -> void:
	if not is_instance_valid(marker):
		return
	add_child(marker)
	move_child(marker, 0)   # bottom-most: above the world, below all HUD UI

## These layers are parented to the SceneTree ROOT (so they sit above the world +
## modals), which means they SURVIVE a scene change — on a 2D↔3D toggle the old
## HUD's copies would linger and STACK (each vignette darkens the screen more). Free
## them when this HUD leaves the tree so the next scene starts clean.
# The quest markers are now a child of THIS HUD, so they're freed with it on a
# scene change (no stacking) — only the root-parented layers need manual cleanup.
var _quest_marker: Control = null
func _exit_tree() -> void:
	for lyr: CanvasLayer in [_vignette_layer, _dmg_layer]:
		if lyr != null and is_instance_valid(lyr):
			lyr.queue_free()

# ── Tab strip (left edge, 2×4 grid, anchored bottom-left) ───────────────────
func _build_tab_strip() -> void:
	var strip := PanelContainer.new()
	strip.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	strip.anchor_left   = 0.0;  strip.anchor_right  = 0.0
	strip.anchor_top    = 1.0;  strip.anchor_bottom = 1.0
	strip.offset_left   = 6;    strip.offset_right  = 102  # 2 columns × 48px
	strip.offset_top    = -248; strip.offset_bottom = -6   # 5 rows × 48px + padding
	add_child(strip)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 0)
	grid.add_theme_constant_override("v_separation", 0)
	strip.add_child(grid)

	for tab: Variant in TABS:
		var btn := Button.new()
		btn.custom_minimum_size  = Vector2(44, 44)
		# Prefer a generated PNG icon; fall back to the emoji glyph until icons exist.
		var img_id := str(tab.get("img", ""))
		var icon_path := "res://assets/icons/%s.png" % img_id
		if img_id != "" and ResourceLoader.exists(icon_path):
			btn.icon = load(icon_path) as Texture2D
			btn.expand_icon = true
			btn.add_theme_constant_override("icon_max_width", 26)
		else:
			btn.text = tab["icon"]
		btn.tooltip_text         = tab["tip"]
		btn.add_theme_stylebox_override("normal",   _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
		btn.add_theme_stylebox_override("hover",    _rs(RS_BTN_H, RS_BORDER, 2))
		btn.add_theme_stylebox_override("pressed",  _rs(RS_BTN_A, RS_GOLD,   2))
		btn.add_theme_stylebox_override("focus",    _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
		btn.add_theme_color_override("font_color",         RS_TEXT)
		btn.add_theme_color_override("font_hover_color",   RS_GOLD)
		btn.add_theme_color_override("font_pressed_color", RS_GOLD)
		btn.add_theme_font_size_override("font_size", 18)
		btn.pressed.connect(_on_tab_pressed.bind(tab["id"]))
		grid.add_child(btn)
		_tab_buttons[tab["id"]] = btn

# ── Content panel (right of strip, same vertical anchor) ────────────────────
func _build_content_panel() -> void:
	_content_panel = PanelContainer.new()
	_content_panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_content_panel.anchor_left   = 0.0;  _content_panel.anchor_right  = 0.0
	_content_panel.anchor_top    = 1.0;  _content_panel.anchor_bottom = 1.0
	_content_panel.offset_left   = 102;  _content_panel.offset_right  = 332
	_content_panel.offset_top    = -200; _content_panel.offset_bottom = -6
	_content_panel.visible       = false
	add_child(_content_panel)

	# Scrollable inner area
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content_panel.add_child(scroll)

	# Each tab content added to a stack; we show/hide via visible
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stack)

	# Build all tabs
	_tab_contents["inv"] = _build_inventory_tab()
	_tab_contents["lvl"] = preload("res://scenes/ui/skills_panel.tscn").instantiate()
	_tab_contents["qst"] = preload("res://scenes/ui/quests_panel.tscn").instantiate()
	_tab_contents["thr"] = _build_thrall_tab()
	# Friends panel is now embedded inside the merged Warband & Friends tab.
	_tab_contents["wrb"] = _build_warband_tab()
	_tab_contents["rep"] = _build_reputation_tab()
	_tab_contents["rnk"] = preload("res://scenes/ui/rankings_panel.tscn").instantiate()
	_tab_contents["set"] = preload("res://scenes/ui/settings_panel.tscn").instantiate()

	for tc: Variant in _tab_contents.values():
		tc.visible = false
		stack.add_child(tc)

# ── Spectator recording hooks (read-only; driven by SpectatorDirector) ────────
## Collapse the chat window, like a player tidying their screen before playing.
func spectator_minimize_chat() -> void:
	if not _chat_minimized and _chat_collapse_btn != null:
		_chat_collapse_btn.pressed.emit()

## Open a main tab (inv/eqp/lvl/…) without the click-again-to-close ambiguity.
func spectator_open_tab(tab_id: String) -> void:
	if _active_tab != tab_id:
		_on_tab_pressed(tab_id)

## Close whatever main tab is currently open.
func spectator_close_tab() -> void:
	if _active_tab != "":
		_on_tab_pressed(_active_tab)

## Show/hide the BANK window for a spectator (bypasses the proximity auto-close,
## which needs a real bank station). Populates from GameManager.bank_inventory,
## which the SpectatorDirector fills from the watched player's state.
func spectator_open_bank() -> void:
	if _bank_window == null:
		return
	_refresh_bank()
	_bank_window.visible = true

func spectator_close_bank() -> void:
	if _bank_window != null:
		_bank_window.visible = false

## Show/hide the CRAFTING window for a spectator so a watched player visibly
## opens the craft screen when they make something (bypasses proximity, which
## needs a real crafting station). Populated from the watched inventory.
func spectator_open_craft() -> void:
	if _craft_window == null:
		return
	_refresh_craft()
	_craft_window.visible = true

func spectator_close_craft() -> void:
	if _craft_window != null:
		_craft_window.visible = false

## Spectator COMBAT readout — driven by the watched bot's relayed fight so the
## combat window opens + logs like a real player's (engage → blows → outcome).
func spectator_combat_begin(monster_name: String, level: int) -> void:
	if _combat_window == null or _combat_log == null:
		return
	_combat_log_box.visible = true
	_combat_log.text = ""
	_combat_window.visible = true
	if level > 0:
		_combat_log_append("You engage the %s (lv %d)!" % [monster_name, level])
	else:
		_combat_log_append("You engage the %s!" % monster_name)

func spectator_combat_log_hit(monster_name: String, amount: int, mine: bool) -> void:
	if _combat_log == null:
		return
	_combat_window.visible = true   # keep it up while blows land
	if mine:
		_combat_log_append("You hit the %s for %d." % [monster_name, amount])
	else:
		_combat_log_append("The %s hits you for %d." % [monster_name, amount])

func spectator_combat_end(monster_name: String, result: String) -> void:
	if _combat_log == null:
		return
	match result:
		"win":
			_combat_log_append("You defeated the %s!" % monster_name)
		"flee":
			_combat_log_append("You flee from the %s." % monster_name)
		_:
			_combat_log_append("You break off from the %s." % monster_name)

func spectator_combat_hide() -> void:
	if _combat_log_box != null:
		_combat_log_box.visible = false
	if _combat_window != null:
		_combat_window.visible = false

# ── Tab switch ───────────────────────────────────────────────────────────────
func _on_tab_pressed(tab_id: String) -> void:
	var was_active := _active_tab == tab_id

	# Reset everything first so only one panel can ever be visible.
	for tid: Variant in _tab_contents.keys():
		(_tab_contents[tid] as Control).visible = false
	for tid: Variant in _tab_buttons.keys():
		(_tab_buttons[tid] as Button).add_theme_stylebox_override(
			"normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	_content_panel.visible = false
	if _equip_panel != null:
		_equip_panel.visible = false

	# Crafting is a pop-up window, not a content panel — toggle it directly.
	if tab_id == "crf":
		_active_tab = ""
		_refresh_craft()
		_craft_window.visible = not _craft_window.visible
		return

	# Quests tab opens the new floating QuestLog (VikingPanel-styled). The
	# old in-strip QuestsPanel is bypassed for player-owned quest viewing.
	if tab_id == "qst":
		_active_tab = ""
		Events.open_quest_log.emit()
		return

	if was_active:
		# Clicking the active tab closes the panel (toggle behaviour).
		_active_tab = ""
		return

	_active_tab = tab_id
	(_tab_buttons[tab_id] as Button).add_theme_stylebox_override("normal", _rs(RS_BTN_A, RS_GOLD, 2))

	# Equipment uses its own non-scrolling panel above the strip, not the content panel.
	if tab_id == "eqp":
		_equip_panel.visible = true
		_refresh_equipment()
		return

	_content_panel.visible                     = true
	(_tab_contents[tab_id] as Control).visible = true
	if tab_id == "wrb":
		# Merged Social tab: refresh both the warband roster and the embedded
		# friends list (the friends panel's own visibility hook won't fire when
		# only its ancestor toggles).
		NetworkManager.send_clan_info()
		NetworkManager.send_friends_list()
	elif tab_id == "thr":
		# Roster is server-owned and isn't in the login payload — pull it fresh.
		NetworkManager.send_thralls_list()
	elif tab_id == "rep":
		# Standing is pushed on login + after rep-granting quests; re-pull on
		# open so the tab is never stale.
		NetworkManager.send_reputation_request()

# ── INVENTORY tab ─────────────────────────────────────────────────────────────
func _build_inventory_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tab_title("Inventory"))
	root.add_child(HSeparator.new())

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 3)
	grid.add_theme_constant_override("v_separation", 3)
	root.add_child(grid)

	_inv_slots.clear()
	for _i in range(28):
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(48, 48)

		var bg := Panel.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)

		# 24×24 icon centred in the 48×48 slot
		var icon_rect := TextureRect.new()
		icon_rect.expand_mode   = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.custom_minimum_size = Vector2(24, 24)
		icon_rect.anchor_left   = 0.5; icon_rect.anchor_right  = 0.5
		icon_rect.anchor_top    = 0.0; icon_rect.anchor_bottom = 0.0
		icon_rect.offset_left   = -12; icon_rect.offset_right  = 12
		icon_rect.offset_top    =  4;  icon_rect.offset_bottom = 28
		icon_rect.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon_rect)

		# Fallback colour tint shown behind icon (also visible when no texture)
		var color_rect := ColorRect.new()
		color_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		color_rect.color = Color.TRANSPARENT
		color_rect.z_index = -1
		color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(color_rect)

		# Procedural art overlay — only draws for items without a PNG.
		# `_refresh_inventory` wires + unwires its draw signal per-slot so
		# a slot's art matches the current item id.
		var art_ctrl := Control.new()
		art_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
		art_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(art_ctrl)

		var qty_lbl := Label.new()
		qty_lbl.anchor_left   = 0.0; qty_lbl.anchor_right  = 1.0
		qty_lbl.anchor_top    = 0.65; qty_lbl.anchor_bottom = 1.0
		qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty_lbl.add_theme_font_size_override("font_size", 9)
		qty_lbl.add_theme_color_override("font_color", RS_GOLD)
		qty_lbl.add_theme_constant_override("outline_size", 2)
		qty_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		qty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(qty_lbl)

		var slot_index := _inv_slots.size()
		slot.gui_input.connect(func(ev: InputEvent) -> void:
			if not (ev is InputEventMouseButton):
				return
			var mb := ev as InputEventMouseButton
			if not mb.pressed:
				return
			if slot_index >= GameManager.inventory.size():
				return
			var item_id := GameManager.inventory[slot_index]["id"] as String
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if _trade_window != null and is_instance_valid(_trade_window):
					_trade_add_item(slot_index)
					return
				if GameManager.BONE_XP.has(item_id):
					GameManager.bury_bone(item_id)
				elif GameManager.FOOD_HEAL.has(item_id):
					GameManager.eat_food(item_id)
			elif mb.button_index == MOUSE_BUTTON_RIGHT:
				# Always show the context menu on right-click; it composes its
				# own entries based on what the item allows (Equip / Drop). If
				# nothing applies, _show_inv_context bails without a popup.
				_show_inv_context(slot_index, mb.global_position))
		grid.add_child(slot)
		_inv_slots.append({"slot": slot, "bg": bg, "icon_rect": icon_rect,
							"color_rect": color_rect, "qty_lbl": qty_lbl,
							"art_ctrl": art_ctrl})

	var gold_row := HBoxContainer.new()
	root.add_child(gold_row)
	_inv_gold_lbl = Label.new()
	_inv_gold_lbl.text = "Gold:  0"
	_inv_gold_lbl.add_theme_color_override("font_color", RS_GOLD)
	_inv_gold_lbl.add_theme_font_size_override("font_size", 11)
	gold_row.add_child(_inv_gold_lbl)

	var boots_row := HBoxContainer.new()
	root.add_child(boots_row)
	_inv_boots_lbl = Label.new()
	_inv_boots_lbl.text = "Boots: None"
	_inv_boots_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_inv_boots_lbl.add_theme_font_size_override("font_size", 11)
	_inv_boots_lbl.tooltip_text = "Right-click boots in inventory to equip"
	boots_row.add_child(_inv_boots_lbl)

	return root

func _item_abbrev(item_name: String) -> String:
	var parts := (item_name as String).split(" ")
	var r := ""
	for p: String in parts:
		if p.length() > 0:
			r += p[0].to_upper()
	return r.left(3)

func _refresh_inventory() -> void:
	var inv := GameManager.inventory
	for i in range(_inv_slots.size()):
		var s: Dictionary = _inv_slots[i]
		var icon_rect  := s["icon_rect"]  as TextureRect
		var color_rect := s["color_rect"] as ColorRect
		var qty_lbl    := s["qty_lbl"]    as Label
		var slot_ctrl  := s["slot"]       as Control
		var art_ctrl   := s.get("art_ctrl") as Control
		# Clear any previous procedural draw connection so we don't
		# stack them across refreshes (or leak captures of stale item
		# state). Fresh signal wired below only when a fallback fires.
		if art_ctrl != null:
			for c: Dictionary in art_ctrl.draw.get_connections():
				art_ctrl.draw.disconnect(c["callable"])
			art_ctrl.queue_redraw()
		if i < inv.size():
			var item: Dictionary = inv[i]
			var item_id_  := item["id"]   as String
			var item_name_ := item["name"] as String
			# Load icon texture (24×24 PNG generated by gen_icons.gd)
			var icon_path := "res://assets/icons/" + item_id_ + ".png"
			if ResourceLoader.exists(icon_path):
				icon_rect.texture = load(icon_path) as Texture2D
				color_rect.color  = Color.TRANSPARENT
			else:
				# Fallback path — procedural art via ItemArt for known
				# icon-less items (crops, tokens, teeth, sea creatures),
				# or a generic loot pouch for anything else. Way better
				# than the old bare colored square.
				icon_rect.texture = null
				color_rect.color  = Color.TRANSPARENT
				var raw_col: Variant = item.get("color", Color.GRAY)
				var col: Color
				if raw_col is Array:
					var a := raw_col as Array
					col = Color(float(a[0]), float(a[1]), float(a[2]))
				elif raw_col is Color:
					col = raw_col as Color
				else:
					col = Color.GRAY
				var iid := item_id_
				var icol := col
				if art_ctrl != null:
					art_ctrl.draw.connect(func() -> void:
						ItemArt.draw_inventory_icon(art_ctrl, iid, icol,
							min(art_ctrl.size.x, art_ctrl.size.y)))
					art_ctrl.queue_redraw()
			qty_lbl.text = "x%d" % item["qty"] if (item["qty"] as int) > 1 else ""
			var tip_ := item_name_
			# Equippable gear — surface the full stat block so a player can
			# compare pieces without having to equip each one.
			if GearDB.is_equippable(item_id_):
				var d := GearDB.def_for(item_id_)
				var block := _gear_stat_block(d)
				if block != "":
					tip_ += "\n" + block
			if GameManager.BONE_XP.has(item_id_):
				tip_ += "\nClick to bury (+%d Soul XP)" % (GameManager.BONE_XP[item_id_] as int)
			elif GameManager.is_boots(item_id_):
				var pct := int(GameManager.boot_speed_bonus(item_id_) * 100.0)
				tip_ += "\nRight-click to equip (+%d%% speed)" % pct
			slot_ctrl.tooltip_text = tip_
		else:
			icon_rect.texture  = null
			color_rect.color   = Color.TRANSPARENT
			qty_lbl.text       = ""
			slot_ctrl.tooltip_text = ""
	if _inv_gold_lbl != null:
		_inv_gold_lbl.text = "Gold:  %d" % GameManager.gold
	if _inv_boots_lbl != null:
		if GameManager.equipped_boots.is_empty():
			_inv_boots_lbl.text = "Boots: None"
		else:
			var pct := int(GameManager.boot_speed_bonus(GameManager.equipped_boots) * 100.0)
			_inv_boots_lbl.text = "Boots: %s (+%d%% spd)" % [GameManager.equipped_boots.replace("_", " ").capitalize(), pct]

# ── Inventory right-click context menu ───────────────────────────────────────
const _CTX_EQUIP := 0
const _CTX_DROP  := 1
const _CTX_EAT   := 2
const _CTX_BURY  := 3
const _CTX_MOUNT := 4

func _show_inv_context(slot_index: int, screen_pos: Vector2) -> void:
	if slot_index < 0 or slot_index >= GameManager.inventory.size():
		return
	var item: Dictionary = GameManager.inventory[slot_index]
	var item_id := str(item.get("id", ""))
	if item_id == "":
		return
	var menu := PopupMenu.new()
	# Eat / Bury sit at the TOP — they're the primary use of food/bones and a
	# new player naturally right-clicks looking for them (left-click also works).
	# Trophy catch (1.6.3): mount it as a wall trophy INSTEAD of cooking it. The
	# leaderboard/journal record was logged at catch, so it lives on either way —
	# but a fish can only be used once (cook OR mount, not both).
	if bool(item.get("trophy", false)):
		menu.add_item("🏆 Mount as trophy", _CTX_MOUNT)
	if GameManager.FOOD_HEAL.has(item_id):
		var heal_amt := int(GameManager.FOOD_HEAL[item_id])
		var wn := float(item.get("wnorm", 0.0))
		if wn > 0.0:
			heal_amt = int(round(float(heal_amt) * (1.0 + wn)))
		menu.add_item("Eat  (+%d HP)" % heal_amt, _CTX_EAT)
	if GameManager.BONE_XP.has(item_id):
		menu.add_item("Bury", _CTX_BURY)
	if GearDB.is_equippable(item_id):
		menu.add_item("Equip", _CTX_EQUIP)
	if _is_item_droppable(item_id):
		menu.add_item("Drop", _CTX_DROP)
	if menu.item_count == 0:
		menu.queue_free()
		return
	menu.id_pressed.connect(func(id: int) -> void:
		if id == _CTX_EQUIP:
			GameManager.equip_item(slot_index)
		elif id == _CTX_DROP:
			_drop_inventory_item(slot_index)
		elif id == _CTX_EAT:
			GameManager.eat_food(item_id)
		elif id == _CTX_BURY:
			GameManager.bury_bone(item_id)
		elif id == _CTX_MOUNT:
			_mount_trophy(slot_index)
		menu.queue_free())
	menu.close_requested.connect(menu.queue_free)
	add_child(menu)
	menu.position = Vector2i(int(screen_pos.x), int(screen_pos.y))
	menu.popup()

## True iff the item can be dumped on the ground. Soulbound items (per the
## ItemPrices.SOULBOUND stub) and the boat the player is currently sailing
## stay glued to the inventory; equipped items are off the table because
## the equipment slot still references them. The check is intentionally
## conservative — when in doubt, hide Drop rather than risk losing gear.
func _is_item_droppable(item_id: String) -> bool:
	if item_id == "":
		return false
	if ItemPrices.is_soulbound(item_id):
		return false
	if GameManager.current_boat == item_id:
		return false
	for slot_id in GameManager.equipment.keys():
		if str(GameManager.equipment[slot_id]) == item_id:
			return false
	return true

## Turn a trophy catch into a keepable "Mounted <Fish>" wall trophy (1.6.3).
## Consumes the fish — so it can no longer be cooked. The record already lives in
## the journal/leaderboard, so the catch is remembered either way.
func _mount_trophy(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= GameManager.inventory.size():
		return
	var item: Dictionary = GameManager.inventory[slot_index]
	if not bool(item.get("trophy", false)):
		return
	var weight := float(item.get("weight", 0.0))
	var fish_name := str(item.get("name", "Fish")).replace("Raw ", "")
	var col_v: Variant = item.get("color", Color(0.80, 0.70, 0.35))
	var col: Color = col_v if col_v is Color else Color(0.80, 0.70, 0.35)
	# Remove the fish (consumed), then add the mounted trophy in the freed slot.
	GameManager.inventory.remove_at(slot_index)
	Events.inventory_changed.emit()
	GameManager.add_item("mounted_" + str(item.get("id", "fish")),
		"Mounted %s (%.1f kg)" % [fish_name, weight], 1, col.lightened(0.10),
		{"weight": weight, "mounted": true})
	Events.chat_message.emit("🏆 You mounted the %s (%.1f kg) as a wall trophy!"
		% [fish_name, weight])

## Pulls the slot out of the inventory, spawns a world LootDrop at the
## player's position, and tells the server so other players see the same
## pickup. The local spawn is what the dropping player sees; the server
## echo handles everyone else via player_drop_spawned.
func _drop_inventory_item(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= GameManager.inventory.size():
		return
	var item: Dictionary = GameManager.inventory[slot_index].duplicate()
	var item_id := str(item.get("id", ""))
	if not _is_item_droppable(item_id):
		return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var p := players[0] as Node2D
	var name_s := str(item.get("name", item_id))
	var qty    := int(item.get("qty", 1))
	var col_v: Variant = item.get("color", Color(0.7, 0.7, 0.7))
	var col: Color
	if col_v is Color:
		col = col_v
	elif col_v is Array and (col_v as Array).size() >= 3:
		var ca := col_v as Array
		col = Color(float(ca[0]), float(ca[1]), float(ca[2]),
			float(ca[3]) if ca.size() >= 4 else 1.0)
	else:
		col = Color(0.7, 0.7, 0.7)
	GameManager.remove_item_qty(item_id, qty)
	var ld := Area2D.new()
	ld.set_script(load("res://scripts/LootDrop.gd"))
	ld.global_position = p.global_position
	p.get_parent().add_child(ld)
	(ld as Area2D).call("setup", item_id, name_s, qty, col)
	NetworkManager.send_player_drop(item_id, name_s, qty, col,
		p.global_position.x, p.global_position.y)
	Events.chat_message.emit("You drop %s." % name_s)

# ── EQUIPMENT panel (paper-doll; opens above the tab strip, non-scrolling) ────
func _build_equipment_panel() -> void:
	_equip_panel = PanelContainer.new()
	_equip_panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_equip_panel.anchor_left = 0.0; _equip_panel.anchor_right = 0.0
	_equip_panel.anchor_top  = 1.0; _equip_panel.anchor_bottom = 1.0
	_equip_panel.offset_left = 6;    _equip_panel.offset_right = 250
	_equip_panel.offset_top  = -596; _equip_panel.offset_bottom = -252
	_equip_panel.visible = false
	add_child(_equip_panel)
	var margin := MarginContainer.new()
	for m: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 8)
	_equip_panel.add_child(margin)
	margin.add_child(_build_equipment_tab())

# ── EQUIPMENT tab (paper-doll) ────────────────────────────────────────────────
func _build_equipment_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.add_child(_tab_title("Equipment"))
	root.add_child(HSeparator.new())

	_equip_slots.clear()

	# Paper-doll: a fixed canvas with the character preview in the centre and
	# equipment slots arranged around it.
	var doll := Control.new()
	doll.custom_minimum_size = Vector2(210, 200)
	root.add_child(doll)

	var preview := (load("res://scripts/CharPreview.gd") as GDScript).new() as Node2D
	preview.scale = Vector2(2.7, 2.7)
	preview.position = Vector2(105, 130)
	doll.add_child(preview)
	preview.set_meta("is_equip_preview", true)
	_equip_slots["__preview"] = {"node": preview}

	var layout: Dictionary = {
		"head": Vector2(85, 2),   "neck": Vector2(128, 2),
		"body": Vector2(6, 44),   "arms": Vector2(164, 44),
		"hands": Vector2(6, 88),  "legs": Vector2(164, 88),
		"weapon": Vector2(6, 132),"offhand": Vector2(164, 132),
		"boots": Vector2(85, 158),
		# Bait slot (Phase 5) — sits to the right of boots, on the doll's
		# waist line. Accepts items where Fishing.is_bait/is_lure is true.
		"bait":  Vector2(128, 158),
	}
	for slot_id: String in layout.keys():
		var s := _make_equip_slot(slot_id, 40)
		s.position = layout[slot_id]
		doll.add_child(s)

	# Ring slots (8) in a row
	var rings_lbl := Label.new()
	rings_lbl.text = "Rings"
	rings_lbl.add_theme_color_override("font_color", RS_DIM)
	rings_lbl.add_theme_font_size_override("font_size", 10)
	root.add_child(rings_lbl)
	var ring_grid := GridContainer.new()
	ring_grid.columns = 8
	ring_grid.add_theme_constant_override("h_separation", 2)
	root.add_child(ring_grid)
	for ri in range(8):
		var rs := _make_equip_slot("ring%d" % (ri + 1), 22)
		ring_grid.add_child(rs)

	root.add_child(HSeparator.new())
	_equip_stats_lbl = Label.new()
	_equip_stats_lbl.add_theme_color_override("font_color", RS_TEXT)
	_equip_stats_lbl.add_theme_font_size_override("font_size", 11)
	_equip_stats_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_equip_stats_lbl)

	return root

func _make_equip_slot(slot_id: String, sz: int) -> Control:
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(sz, sz)

	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(bg)

	var icon_rect := TextureRect.new()
	icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon_rect)

	# Empty-slot hint label (slot name) shown when nothing equipped
	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_FULL_RECT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", RS_DIM.darkened(0.1))
	hint.add_theme_font_size_override("font_size", 8)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not slot_id.begins_with("ring"):
		hint.text = str(GearDB.SLOT_LABELS.get(slot_id, ""))
	slot.add_child(hint)

	slot.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			GameManager.unequip_slot(slot_id))

	_equip_slots[slot_id] = {"icon_rect": icon_rect, "hint": hint, "slot": slot}
	return slot

func _refresh_equipment() -> void:
	if _equip_slots.is_empty():
		return
	for slot_id: String in GearDB.SLOTS:
		if not _equip_slots.has(slot_id):
			continue
		var s: Dictionary = _equip_slots[slot_id]
		var icon_rect := s["icon_rect"] as TextureRect
		var hint := s["hint"] as Label
		var slot_ctrl := s["slot"] as Control
		var iid := str(GameManager.equipment.get(slot_id, ""))
		if iid != "":
			var icon_path := "res://assets/icons/" + iid + ".png"
			icon_rect.texture = load(icon_path) as Texture2D if ResourceLoader.exists(icon_path) else null
			hint.visible = false
			var d := GearDB.def_for(iid)
			slot_ctrl.tooltip_text = "%s\n%s\nClick to unequip" % [str(d.get("name", iid)), _stat_str(d)]
		else:
			icon_rect.texture = null
			hint.visible = true
			slot_ctrl.tooltip_text = ""
	if _equip_slots.has("__preview"):
		var pv := (_equip_slots["__preview"] as Dictionary)["node"] as Node2D
		pv.call("set_appearance", GameManager.appearance)
		pv.call("set_equipment", GameManager.equipment)
	if _equip_stats_lbl != null:
		# Paperdoll bonus totals — expanded from Atk/Def/HP/Acc to include
		# Str (melee bonus), Ratk (ranged bonus), Matk (magic bonus), and
		# the swing-speed multiplier. Non-zero values only, so an unarmored
		# character doesn't see a wall of "+0".
		var lines: Array[String] = []
		var line1: Array[String] = []
		for k: String in ["atk", "str", "ratk", "matk", "acc"]:
			var v: int = GameManager.get_equipment_bonus(k)
			if v != 0:
				line1.append("%s +%d" % [k.to_upper(), v])
		if not line1.is_empty():
			lines.append("  ".join(line1))
		var line2: Array[String] = []
		for k: String in ["def", "hp"]:
			var v: int = GameManager.get_equipment_bonus(k)
			if v != 0:
				line2.append("%s +%d" % [k.to_upper(), v])
		var spd: float = GameManager.get_attack_speed_mult()
		if abs(spd - 1.0) > 0.001:
			line2.append("Speed x%.2f" % spd)
		if not line2.is_empty():
			lines.append("  ".join(line2))
		# Full-set bonus line — visible only when every required piece for
		# a registered set is equipped. Human-readable summary of the set
		# bonus stats + name.
		var sb: Dictionary = GearDB.equipped_set_bonus(GameManager.equipment)
		if not sb.is_empty():
			var parts: Array[String] = []
			var b: Dictionary = sb["bonus"]
			for k: String in ["hp", "def", "atk", "str", "acc"]:
				if int(b.get(k, 0)) != 0:
					parts.append("+%d %s" % [int(b[k]), k.to_upper()])
			var set_spd: float = float(b.get("atk_spd", 1.0))
			if abs(set_spd - 1.0) > 0.001:
				parts.append("x%.2f Speed" % set_spd)
			lines.append("Set: %s  (%s)" % [str(sb["name"]),
				"  ".join(parts) if not parts.is_empty() else "—"])
		_equip_stats_lbl.text = "Bonuses — " + (
			"   ".join(lines) if not lines.is_empty() else "none")

## Short single-line stat summary — used by the equipped-slot tooltip
## ("Atk +18, Str +3, Acc +5"). Empty defs render as "—" so the tooltip
## never dangles a bare newline.
func _stat_str(d: Dictionary) -> String:
	var parts: Array[String] = []
	for k: String in ["atk", "str", "ratk", "matk", "acc", "def", "hp"]:
		if int(d.get(k, 0)) != 0:
			parts.append("%s +%d" % [k.to_upper(), int(d[k])])
	return ", ".join(parts) if not parts.is_empty() else "—"

## Multi-line stat block used by inventory tooltips, recipe cards, shop
## cards. Groups related stats onto one line, adds attack-speed + level
## requirement lines when present.
func _gear_stat_block(d: Dictionary) -> String:
	if d == null or d.is_empty():
		return ""
	# Fishing tackle carries a prebuilt description instead of gear stat lines.
	if str(d.get("desc", "")) != "":
		return str(d["desc"])
	var lines: Array[String] = []
	# Offense line — attack + style-specific bonuses + accuracy + crit%.
	var off: Array[String] = []
	for k: String in ["atk", "str", "ratk", "matk", "acc"]:
		if int(d.get(k, 0)) != 0:
			off.append("%s +%d" % [k.to_upper(), int(d[k])])
	if int(d.get("crit", 0)) != 0:
		off.append("CRIT +%d%%" % int(d["crit"]))
	if not off.is_empty():
		lines.append("  ".join(off))
	# Defense line — armor + hp + block% + split-defense specializations.
	var defn: Array[String] = []
	for k: String in ["def", "hp"]:
		if int(d.get(k, 0)) != 0:
			defn.append("%s +%d" % [k.to_upper(), int(d[k])])
	if int(d.get("block", 0)) != 0:
		defn.append("BLOCK +%d%%" % int(d["block"]))
	for sk: Array in [["def_melee", "vMelee"], ["def_ranged", "vRanged"], ["def_magic", "vMagic"]]:
		if int(d.get(sk[0], 0)) != 0:
			defn.append("%s +%d" % [str(sk[1]), int(d[sk[0]])])
	if not defn.is_empty():
		lines.append("  ".join(defn))
	# Speed / requirements line.
	var last: Array[String] = []
	var spd: float = float(d.get("atk_spd", 1.0))
	if abs(spd - 1.0) > 0.001:
		last.append("Speed x%.2f" % spd)
	var spd_boots: float = float(d.get("speed", 0.0))
	if spd_boots > 0.0:
		last.append("Move +%d%%" % int(spd_boots * 100.0))
	var min_lv: int = int(d.get("min_lv", 1))
	if min_lv > 1:
		var req: String = str(d.get("req_skill", "level"))
		last.append("Lv %d %s" % [min_lv, req.capitalize()])
	if not last.is_empty():
		lines.append("  ".join(last))
	return "\n".join(lines)


# ── WARBAND tab ───────────────────────────────────────────────────────────────
func _build_warband_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tab_title("Warband & Friends"))
	root.add_child(HSeparator.new())

	# Pending warband invites (Phase 3) — persistent so a missed toast isn't
	# lost. Populated by _on_clan_invite_received, cleared on accept/decline.
	_invites_root = VBoxContainer.new()
	_invites_root.add_theme_constant_override("separation", 3)
	_invites_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_invites_root)

	_warband_root = VBoxContainer.new()
	_warband_root.add_theme_constant_override("separation", 4)
	_warband_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_warband_root)

	root.add_child(HSeparator.new())

	# Friends — embed the existing self-contained panel wholesale.
	var friends: Control = preload("res://scenes/ui/friends_panel.tscn").instantiate() as Control
	friends.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(friends)

	_refresh_warband()
	_refresh_invites()
	return root

# ── Warband invites (Phase 3) — routed to a persistent list in the tab ────────
var _invites_root: VBoxContainer = null
var _pending_invites: Array = []   # each: {from, clan_name, clan_id}

func _remove_pending_invite(clan_id: String) -> void:
	for i in range(_pending_invites.size() - 1, -1, -1):
		if str((_pending_invites[i] as Dictionary).get("clan_id", "")) == clan_id:
			_pending_invites.remove_at(i)
	_refresh_invites()

func _refresh_invites() -> void:
	if _invites_root == null or not is_instance_valid(_invites_root):
		return
	for ch: Node in _invites_root.get_children():
		ch.queue_free()
	if _pending_invites.is_empty():
		return
	var hdr := Label.new()
	hdr.text = "Warband Invites"
	hdr.add_theme_color_override("font_color", RS_GOLD)
	hdr.add_theme_font_size_override("font_size", 11)
	_invites_root.add_child(hdr)
	for inv: Variant in _pending_invites:
		var d: Dictionary = inv as Dictionary
		var cid := str(d.get("clan_id", ""))
		var cname := str(d.get("clan_name", "?"))
		var from := str(d.get("from", "?"))
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _rs(Color(0.16, 0.11, 0.05), RS_GOLD, 1))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		row.add_child(vb)
		var lbl := Label.new()
		lbl.text = "'%s' — from %s" % [cname, from]
		lbl.add_theme_color_override("font_color", RS_TEXT)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(lbl)
		var btns := HBoxContainer.new()
		btns.add_theme_constant_override("separation", 6)
		vb.add_child(btns)
		var acc := Button.new()
		acc.text = "Accept"
		acc.add_theme_font_size_override("font_size", 10)
		acc.add_theme_color_override("font_color", RS_GREEN)
		acc.pressed.connect(func() -> void:
			NetworkManager.send_clan_accept(cid)
			_remove_pending_invite(cid))
		btns.add_child(acc)
		var dec := Button.new()
		dec.text = "Decline"
		dec.add_theme_font_size_override("font_size", 10)
		dec.pressed.connect(func() -> void:
			NetworkManager.send_clan_decline(from)
			_remove_pending_invite(cid))
		btns.add_child(dec)
		_invites_root.add_child(row)
	_invites_root.add_child(HSeparator.new())

func _on_clan_info_updated(clan: Dictionary) -> void:
	_clan = clan
	# Joined a warband → any outstanding invites are moot; clear the list.
	if not _clan.is_empty() and not _pending_invites.is_empty():
		_pending_invites.clear()
		_refresh_invites()
	_refresh_warband()

func _refresh_warband() -> void:
	if _warband_root == null or not is_instance_valid(_warband_root):
		return
	for ch: Node in _warband_root.get_children():
		ch.queue_free()
	if _clan.is_empty():
		_build_warband_none()
	else:
		_build_warband_clan()

func _build_warband_none() -> void:
	var info := Label.new()
	info.text = "You are not in a Warband.\n\nFound one to share a\nbank with your allies."
	info.add_theme_color_override("font_color", RS_DIM)
	info.add_theme_font_size_override("font_size", 11)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warband_root.add_child(info)

	var btn := Button.new()
	btn.text = "Create Warband\n(10,000 gold)"
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(_show_create_clan_dialog)
	_warband_root.add_child(btn)

func _build_warband_clan() -> void:
	var clan_name := str(_clan.get("name", "Clan"))
	var leader    := str(_clan.get("leader", ""))
	var is_leader: bool = leader == str(NetworkManager.my_username)

	var name_lbl := Label.new()
	name_lbl.text = clan_name
	name_lbl.add_theme_color_override("font_color", RS_GOLD)
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warband_root.add_child(name_lbl)

	# Members
	var mem_hdr := Label.new()
	mem_hdr.text = "Members"
	mem_hdr.add_theme_color_override("font_color", RS_TEXT)
	mem_hdr.add_theme_font_size_override("font_size", 11)
	_warband_root.add_child(mem_hdr)

	for m: Variant in (_clan.get("members", []) as Array):
		if not (m is Dictionary):
			continue
		var md: Dictionary = m as Dictionary
		var uname: String  = str(md.get("username", "?"))
		var role: String   = str(md.get("role", "member"))
		var online: bool   = bool(md.get("online", false))

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nm := Label.new()
		nm.text = "● %s%s" % [uname, "  (leader)" if role == "leader" else ""]
		nm.add_theme_color_override("font_color", RS_GREEN if online else RS_DIM)
		nm.add_theme_font_size_override("font_size", 10)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(nm)
		if is_leader and uname != NetworkManager.my_username:
			var kick := Button.new()
			kick.text = "Kick"
			kick.add_theme_font_size_override("font_size", 9)
			kick.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
			kick.pressed.connect(func() -> void: NetworkManager.send_clan_kick(uname))
			row.add_child(kick)
		_warband_root.add_child(row)

	# Membership controls
	var ctrl := HBoxContainer.new()
	ctrl.add_theme_constant_override("separation", 4)
	if is_leader:
		var inv_btn := Button.new()
		inv_btn.text = "Invite"
		inv_btn.add_theme_font_size_override("font_size", 10)
		inv_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inv_btn.pressed.connect(_show_clan_invite_dialog)
		ctrl.add_child(inv_btn)
	var leave_btn := Button.new()
	leave_btn.text = "Leave"
	leave_btn.add_theme_font_size_override("font_size", 10)
	leave_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leave_btn.pressed.connect(func() -> void: NetworkManager.send_clan_leave())
	ctrl.add_child(leave_btn)
	_warband_root.add_child(ctrl)

	_warband_root.add_child(HSeparator.new())

	# ── Clan gold pool (Phase 3 #3b) — anyone deposits; leader withdraws
	# freely, members up to a leader-set allowance.
	var pool := int(_clan.get("gold", 0))
	var gold_hdr := Label.new()
	gold_hdr.text = "Clan Gold Pool:  %d" % pool
	gold_hdr.add_theme_color_override("font_color", RS_GOLD)
	gold_hdr.add_theme_font_size_override("font_size", 11)
	_warband_root.add_child(gold_hdr)
	var gp := HBoxContainer.new()
	gp.add_theme_constant_override("separation", 4)
	_clan_gold_amount = LineEdit.new()
	_clan_gold_amount.placeholder_text = "gold"
	_clan_gold_amount.custom_minimum_size = Vector2(60, 0)
	_clan_gold_amount.add_theme_font_size_override("font_size", 10)
	gp.add_child(_clan_gold_amount)
	var gdep := Button.new(); gdep.text = "Deposit"; gdep.add_theme_font_size_override("font_size", 9)
	gdep.pressed.connect(func() -> void: _clan_gold_action(true))
	gp.add_child(gdep)
	var gwd := Button.new(); gwd.text = "Withdraw"; gwd.add_theme_font_size_override("font_size", 9)
	gwd.pressed.connect(func() -> void: _clan_gold_action(false))
	gp.add_child(gwd)
	_warband_root.add_child(gp)
	if not is_leader:
		var rem := _clan_my_gold_remaining()
		var ah := Label.new()
		ah.text = "Your withdraw allowance left: %d" % rem
		ah.add_theme_color_override("font_color", RS_DIM)
		ah.add_theme_font_size_override("font_size", 8)
		_warband_root.add_child(ah)

	_warband_root.add_child(HSeparator.new())

	# ── Clan bank (tiled — Phase 3 #2) ───────────────────────────────────────
	var bank_hdr := Label.new()
	bank_hdr.text = "Clan Bank"
	bank_hdr.add_theme_color_override("font_color", RS_GOLD)
	bank_hdr.add_theme_font_size_override("font_size", 11)
	_warband_root.add_child(bank_hdr)

	var tab_count := int(_clan.get("bank_tabs", 1))
	var tab_costs: Dictionary = _clan.get("tab_costs", {}) as Dictionary
	if _clan_active_tab >= tab_count:
		_clan_active_tab = 0
	var tabrow := HBoxContainer.new()
	tabrow.add_theme_constant_override("separation", 3)
	for ti in range(_CLAN_MAX_TABS):
		var tb := Button.new()
		tb.add_theme_font_size_override("font_size", 9)
		if ti < tab_count:
			tb.text = "Tab %d" % (ti + 1)
			if ti == _clan_active_tab:
				tb.add_theme_color_override("font_color", RS_GOLD)
			var sel := ti
			tb.pressed.connect(func() -> void:
				_clan_active_tab = sel
				_refresh_warband())
		elif ti == tab_count and is_leader:
			var cost := int(tab_costs.get(str(ti + 1), 0))
			tb.text = "Buy T%d (%dg)" % [ti + 1, cost]
			tb.pressed.connect(func() -> void: NetworkManager.send_clan_buy_tab())
		else:
			tb.text = "🔒 T%d" % (ti + 1)
			tb.disabled = true
		tabrow.add_child(tb)
	_warband_root.add_child(tabrow)

	var tabs: Array = _clan.get("tabs", []) as Array
	var items: Array = (tabs[_clan_active_tab] as Array) if _clan_active_tab < tabs.size() else []
	var slots := int(_clan.get("tab_slots", 20))
	var can_wd := is_leader or _clan_my_can_withdraw(_clan_active_tab)
	var slot_lbl := Label.new()
	slot_lbl.text = "Slots %d / %d%s" % [items.size(), slots, "" if can_wd else "   (deposit only)"]
	slot_lbl.add_theme_color_override("font_color", RS_DIM)
	slot_lbl.add_theme_font_size_override("font_size", 8)
	_warband_root.add_child(slot_lbl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 120)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_warband_root.add_child(scroll)
	var bank_vbox := VBoxContainer.new()
	bank_vbox.add_theme_constant_override("separation", 2)
	bank_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(bank_vbox)
	if items.is_empty():
		var empty := Label.new()
		empty.text = "This tab is empty."
		empty.add_theme_color_override("font_color", RS_DIM)
		empty.add_theme_font_size_override("font_size", 10)
		bank_vbox.add_child(empty)
	else:
		for b: Variant in items:
			if not (b is Dictionary):
				continue
			var bd: Dictionary = b as Dictionary
			var bid: String = str(bd.get("id", ""))
			var bnm: String = str(bd.get("name", bid))
			var bq: int     = int(bd.get("qty", 0))
			var brow := HBoxContainer.new()
			brow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var bl := Label.new()
			bl.text = "%s x%d" % [bnm, bq]
			bl.add_theme_color_override("font_color", RS_TEXT)
			bl.add_theme_font_size_override("font_size", 10)
			bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			brow.add_child(bl)
			if can_wd:
				var take := Button.new()
				take.text = "Take"
				take.add_theme_font_size_override("font_size", 9)
				var tk_tab := _clan_active_tab
				take.pressed.connect(func() -> void:
					NetworkManager.send_clan_bank_withdraw(bid, bq, tk_tab))
				brow.add_child(take)
			bank_vbox.add_child(brow)

	var dep_btn := Button.new()
	dep_btn.text = "Deposit Item → Tab %d" % (_clan_active_tab + 1)
	dep_btn.add_theme_font_size_override("font_size", 10)
	dep_btn.pressed.connect(_show_clan_deposit_dialog)
	_warband_root.add_child(dep_btn)

	if is_leader:
		var perm_btn := Button.new()
		perm_btn.text = "⚙ Manage Permissions"
		perm_btn.add_theme_font_size_override("font_size", 10)
		perm_btn.pressed.connect(_show_clan_perm_editor)
		_warband_root.add_child(perm_btn)

		# Trade caravans (Phase 5c) — hired from the clan pool; each safe town
		# arrival pays gold + standing + occasional rare mats to the warband.
		var cvn_btn := Button.new()
		cvn_btn.text = "🐎 Hire Trade Caravan (5,000g)"
		cvn_btn.add_theme_font_size_override("font_size", 10)
		cvn_btn.pressed.connect(func() -> void:
			NetworkManager.send_warband_caravan_create())
		_warband_root.add_child(cvn_btn)
		var recall_btn := Button.new()
		recall_btn.text = "↩ Recall Caravans"
		recall_btn.add_theme_font_size_override("font_size", 9)
		recall_btn.pressed.connect(func() -> void:
			NetworkManager.send_warband_caravan_disband())
		_warband_root.add_child(recall_btn)

func _show_create_clan_dialog() -> void:
	_show_text_input_dialog("Create Warband", "Clan name", "Found (10,000g)",
		func(txt: String) -> void:
			NetworkManager.send_clan_create(txt))

func _show_clan_invite_dialog() -> void:
	_show_text_input_dialog("Invite to Warband", "Player name", "Invite",
		func(txt: String) -> void:
			NetworkManager.send_clan_invite(txt))

func _show_text_input_dialog(title: String, placeholder: String, ok_label: String, on_ok: Callable) -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 202
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -130; panel.offset_right = 130
	panel.offset_top  = -50;  panel.offset_bottom = 50
	overlay.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)
	var tl := Label.new()
	tl.text = title
	tl.add_theme_color_override("font_color", RS_GOLD)
	tl.add_theme_font_size_override("font_size", 12)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(tl)
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.add_theme_font_size_override("font_size", 11)
	vbox.add_child(field)
	var go := func() -> void:
		var txt := field.text.strip_edges()
		if not txt.is_empty():
			on_ok.call(txt)
		overlay.queue_free()
	field.text_submitted.connect(func(_t: String) -> void: go.call())
	var ok_btn := Button.new()
	ok_btn.text = ok_label
	ok_btn.add_theme_font_size_override("font_size", 11)
	ok_btn.pressed.connect(go)
	vbox.add_child(ok_btn)
	field.grab_focus()

func _show_clan_deposit_dialog() -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 202
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -140; panel.offset_right = 140
	panel.offset_top  = -150; panel.offset_bottom = 150
	overlay.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)
	var tl := Label.new()
	tl.text = "Deposit to Tab %d" % (_clan_active_tab + 1)
	tl.add_theme_color_override("font_color", RS_GOLD)
	tl.add_theme_font_size_override("font_size", 12)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(tl)
	vbox.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 220)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	if GameManager.inventory.is_empty():
		var e := Label.new()
		e.text = "Inventory empty."
		e.add_theme_color_override("font_color", RS_DIM)
		e.add_theme_font_size_override("font_size", 10)
		list.add_child(e)
	for item: Dictionary in GameManager.inventory:
		var iid: String = str(item.get("id", ""))
		var inm: String = str(item.get("name", iid))
		var iq: int     = int(item.get("qty", 0))
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var l := Label.new()
		l.text = "%s x%d" % [inm, iq]
		l.add_theme_color_override("font_color", RS_TEXT)
		l.add_theme_font_size_override("font_size", 10)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var dep := Button.new()
		dep.text = "Deposit"
		dep.add_theme_font_size_override("font_size", 9)
		var dep_tab := _clan_active_tab
		dep.pressed.connect(func() -> void:
			NetworkManager.send_clan_bank_deposit(iid, iq, dep_tab)
			overlay.queue_free())
		row.add_child(dep)
		list.add_child(row)

# ── Clan gold + permission helpers (Phase 3 #2/#3b) ──────────────────────────
func _clan_gold_action(deposit: bool) -> void:
	var t := _clan_gold_amount.text.strip_edges() if _clan_gold_amount != null else ""
	var amt := int(t) if t.is_valid_int() else 0
	if amt <= 0:
		Events.chat_message.emit("Enter a gold amount.")
		return
	if deposit:
		NetworkManager.send_clan_gold_deposit(amt)
	else:
		NetworkManager.send_clan_gold_withdraw(amt)
	if _clan_gold_amount != null:
		_clan_gold_amount.text = ""

func _clan_my_member() -> Dictionary:
	for m: Variant in (_clan.get("members", []) as Array):
		if m is Dictionary and str((m as Dictionary).get("username", "")) == NetworkManager.my_username:
			return m as Dictionary
	return {}

func _clan_my_can_withdraw(tab: int) -> bool:
	var me := _clan_my_member()
	if str(me.get("role", "")) == "leader":
		return true
	for t: Variant in (me.get("withdraw_tabs", []) as Array):
		if int(t) == tab:
			return true
	return false

func _clan_my_gold_remaining() -> int:
	var me := _clan_my_member()
	return maxi(0, int(me.get("gold_limit", 0)) - int(me.get("gold_withdrawn", 0)))

## Leader-only editor: per-member withdraw toggles per tab + clan-gold allowance.
func _show_clan_perm_editor() -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 204
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_GOLD, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -215; panel.offset_right = 215
	panel.offset_top = -210;  panel.offset_bottom = 210
	overlay.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 5)
	panel.add_child(root)
	var tl := Label.new()
	tl.text = "Clan Bank Permissions"
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.add_theme_color_override("font_color", RS_GOLD)
	tl.add_theme_font_size_override("font_size", 13)
	root.add_child(tl)
	var hint := Label.new()
	hint.text = "Everyone can view + deposit. Toggle each member's WITHDRAW right per tab, and set their clan-gold withdraw allowance."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", RS_DIM)
	hint.add_theme_font_size_override("font_size", 9)
	root.add_child(hint)
	root.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var tab_count := int(_clan.get("bank_tabs", 1))
	var any_member := false
	for m: Variant in (_clan.get("members", []) as Array):
		if not (m is Dictionary):
			continue
		var md: Dictionary = m as Dictionary
		if str(md.get("role", "")) == "leader":
			continue
		any_member = true
		var uname := str(md.get("username", ""))
		var wt: Array = md.get("withdraw_tabs", []) as Array
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _rs(Color(0.16, 0.11, 0.05), RS_BORDER, 1))
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 3)
		card.add_child(cv)
		var nm := Label.new()
		nm.text = uname
		nm.add_theme_color_override("font_color", RS_TEXT)
		nm.add_theme_font_size_override("font_size", 11)
		cv.add_child(nm)
		var trow := HBoxContainer.new()
		trow.add_theme_constant_override("separation", 4)
		var wl := Label.new()
		wl.text = "Withdraw:"
		wl.add_theme_color_override("font_color", RS_DIM)
		wl.add_theme_font_size_override("font_size", 9)
		trow.add_child(wl)
		for ti in range(tab_count):
			var cb := CheckBox.new()
			cb.text = "T%d" % (ti + 1)
			cb.add_theme_font_size_override("font_size", 9)
			cb.set_pressed_no_signal(_arr_has_int(wt, ti))
			var cap_u := uname
			var cap_t := ti
			cb.toggled.connect(func(on: bool) -> void:
				NetworkManager.send_clan_set_perm(cap_u, cap_t, on))
			trow.add_child(cb)
		cv.add_child(trow)
		var grow := HBoxContainer.new()
		grow.add_theme_constant_override("separation", 4)
		var gl := Label.new()
		gl.text = "Gold allowance:"
		gl.add_theme_color_override("font_color", RS_DIM)
		gl.add_theme_font_size_override("font_size", 9)
		grow.add_child(gl)
		var gf := LineEdit.new()
		gf.text = str(int(md.get("gold_limit", 0)))
		gf.custom_minimum_size = Vector2(60, 0)
		gf.add_theme_font_size_override("font_size", 10)
		grow.add_child(gf)
		var gset := Button.new()
		gset.text = "Set"
		gset.add_theme_font_size_override("font_size", 9)
		var cap_u2 := uname
		var cap_gf := gf
		gset.pressed.connect(func() -> void:
			var vt := cap_gf.text.strip_edges()
			NetworkManager.send_clan_set_gold_limit(cap_u2, int(vt) if vt.is_valid_int() else 0))
		grow.add_child(gset)
		var used := Label.new()
		used.text = "(used %d)" % int(md.get("gold_withdrawn", 0))
		used.add_theme_color_override("font_color", RS_DIM)
		used.add_theme_font_size_override("font_size", 8)
		grow.add_child(used)
		cv.add_child(grow)
		list.add_child(card)
	if not any_member:
		var none := Label.new()
		none.text = "No other members yet."
		none.add_theme_color_override("font_color", RS_DIM)
		none.add_theme_font_size_override("font_size", 10)
		list.add_child(none)
	var close := Button.new()
	close.text = "Close"
	close.add_theme_font_size_override("font_size", 11)
	close.pressed.connect(func() -> void: overlay.queue_free())
	root.add_child(close)

func _arr_has_int(arr: Array, n: int) -> bool:
	for v: Variant in arr:
		if int(v) == n:
			return true
	return false

func _on_clan_invite_received(from_username: String, clan_name: String, clan_id: String) -> void:
	# Persist it in the tab's Invites list (so a dismissed toast isn't lost),
	# de-duped by clan id.
	var dup := false
	for inv: Variant in _pending_invites:
		if str((inv as Dictionary).get("clan_id", "")) == clan_id:
			dup = true
			break
	if not dup:
		_pending_invites.append({"from": from_username, "clan_name": clan_name, "clan_id": clan_id})
		_refresh_invites()
		Events.chat_message.emit("[Warband invite from %s — see the Warband & Friends tab]" % from_username)
	# Also pop the immediate toast for convenience.
	var overlay := CanvasLayer.new()
	overlay.layer = 203
	add_child(overlay)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_GOLD, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.0; panel.anchor_bottom = 0.0
	panel.offset_left = -160; panel.offset_right = 160
	panel.offset_top  = 50;   panel.offset_bottom = 140
	overlay.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)
	var lbl := Label.new()
	lbl.text = "%s invites you to join the warband '%s'." % [from_username, clan_name]
	lbl.add_theme_color_override("font_color", RS_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)
	var acc := Button.new()
	acc.text = "Accept"
	acc.add_theme_font_size_override("font_size", 11)
	acc.add_theme_color_override("font_color", RS_GREEN)
	acc.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_clan_accept(clan_id)
		_remove_pending_invite(clan_id))
	hbox.add_child(acc)
	var dec := Button.new()
	dec.text = "Decline"
	dec.add_theme_font_size_override("font_size", 11)
	dec.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_clan_decline(from_username)
		_remove_pending_invite(clan_id))
	hbox.add_child(dec)

# ── FRIENDS tab ──────────────────────────────────────────────────────────────
func _on_request_trade(username: String) -> void:
	_trade_partner = username
	NetworkManager.send_trade_request(username)
	Events.chat_message.emit("[Trade request sent to %s]" % username)

func _start_whisper(username: String) -> void:
	if _chat_line_edit == null or not is_instance_valid(_chat_line_edit):
		return
	if _chat_minimized:
		_chat_minimized = false
		_chat_content.visible = true
		_chat_panel.offset_top = _chat_panel.offset_bottom - float(CHAT_H)
		_clamp_chat_to_viewport()
	_chat_line_edit.text = "/w %s " % username
	_chat_line_edit.grab_focus()
	_chat_line_edit.caret_column = _chat_line_edit.text.length()

func _send_chat_or_whisper(text: String) -> void:
	# Admin-only commands — handled silently, never broadcast to global chat.
	# Multi-admin: any rank ('admin' or 'owner') gets the admin slash commands.
	# /promote and /demote are owner-only, gated inside _try_admin_command.
	# Server-side gating is the source of truth — the client check just avoids
	# round-tripping commands that would be rejected.
	if NetworkManager.my_admin_rank != "" and text.begins_with("/"):
		if _try_admin_command(text):
			return
	# /promote and /demote are routed through normal chat so the server
	# parses them — never broadcast. Done for both ranks so an admin who
	# tries it gets a clean server-side rejection instead of leaking text.
	if text.begins_with("/promote ") or text.begins_with("/demote "):
		NetworkManager.send_chat(text)
		return
	if text.begins_with("/w "):
		var rest := text.substr(3).strip_edges()
		var sp := rest.find(" ")
		if sp > 0:
			var target := rest.substr(0, sp)
			var body := rest.substr(sp + 1).strip_edges()
			if not body.is_empty():
				NetworkManager.send_whisper(target, body)
				return
		Events.chat_message.emit("[Usage: /w <name> <message>]")
		return
	NetworkManager.send_chat(text)

## Returns true if `text` was an admin command (and was handled / consumed).
func _try_admin_command(text: String) -> bool:
	var parts := text.strip_edges().split(" ", false)
	if parts.is_empty():
		return false
	var cmd := str(parts[0])
	if cmd == "/gold":
		if parts.size() < 3:
			Events.chat_message.emit("[Usage: /gold <name> <amount>]")
			return true
		NetworkManager.send_admin_gold(str(parts[1]), int(str(parts[2])))
		return true
	if cmd == "/exportmap":
		# Dump live tile paints for the 3D prototype (client-side, local file).
		var g := get_tree().get_first_node_in_group("ground")
		if g != null and g.has_method("export_overrides_to_user"):
			var n: int = g.call("export_overrides_to_user")
			Events.chat_message.emit("[Exported %d tile paints → user://map_export.json]" % n)
		else:
			Events.chat_message.emit("[Ground not found — can't export map]")
		return true
	if cmd == "/spawn":
		if parts.size() < 2:
			Events.chat_message.emit("[Usage: /spawn <type> <level>]")
			return true
		var subtype := str(parts[1])
		var level := int(str(parts[2])) if parts.size() >= 3 else 1
		var pos := Vector2.ZERO
		var players := get_tree().get_nodes_in_group("player")
		if not players.is_empty():
			pos = (players[0] as Node2D).global_position
		NetworkManager.send_admin_spawn(subtype, level, pos.x, pos.y)
		return true
	# Generic item give. Server-side defaults fill in a gray color and the id
	# as the display name. For boats use /giveboat instead so the name + hull
	# color come from Boats.data().
	if cmd == "/give":
		if parts.size() < 4:
			Events.chat_message.emit("[Usage: /give <name> <item_id> <qty>]")
			return true
		NetworkManager.send_admin_give_item(str(parts[1]), str(parts[2]),
			str(parts[2]).replace("_", " ").capitalize(),
			int(str(parts[3])), Color(0.7, 0.7, 0.7, 1.0))
		return true
	# Boat give — looks up the boat name + hull colour from Boats.data() so
	# the inventory entry renders correctly. Defaults qty to 1.
	if cmd == "/giveboat":
		if parts.size() < 3:
			Events.chat_message.emit("[Usage: /giveboat <name> <boat_id>]")
			return true
		var bid := str(parts[2])
		var bdata: Dictionary = Boats.data(bid)
		if bdata.is_empty():
			Events.chat_message.emit("[Unknown boat id: %s]" % bid)
			return true
		var bname := str(bdata.get("name", bid))
		var bcol: Color = bdata.get("wood", Color(0.55, 0.36, 0.18))
		NetworkManager.send_admin_give_item(str(parts[1]), bid, bname, 1, bcol)
		return true
	if cmd == "/take":
		if parts.size() < 4:
			Events.chat_message.emit("[Usage: /take <name> <item_id> <qty>]")
			return true
		NetworkManager.send_admin_take_item(str(parts[1]), str(parts[2]),
			int(str(parts[3])))
		return true
	if cmd == "/restore":
		if parts.size() < 2:
			Events.chat_message.emit("[Usage: /restore <name>]")
			return true
		NetworkManager.send_admin_restore_last_loss(str(parts[1]))
		return true
	if cmd == "/inv":
		if parts.size() < 2:
			Events.chat_message.emit("[Usage: /inv <name>]")
			return true
		NetworkManager.send_admin_view_inventory(str(parts[1]))
		return true
	return false

## Spawn the reel minigame as a HUD child. Player.gd has already set its
## internal `_reeling` flag so further catch rolls are blocked; the modal
## emits `reel_minigame_ended` when the player wins or snaps the line, which
## Player.gd handles (apply or chat-fail).
func _on_reel_minigame_start(catch_data: Dictionary) -> void:
	var rm := ReelMinigame.new()
	rm.setup(catch_data)
	add_child(rm)

## Skill training mini-game (v1.6.6). A training station emits
## `skill_minigame_start` with a config dict; spawn the modal. When it ends it
## has already consumed the ammo per shot — we just award the accuracy-scaled XP.
func _on_skill_minigame_start(cfg: Dictionary) -> void:
	var mg := SkillMinigame.new()
	mg.setup(cfg)
	add_child(mg)

func _on_skill_minigame_ended(result: Dictionary) -> void:
	var skill := str(result.get("skill", ""))
	var xp := int(result.get("xp", 0))
	if skill != "" and xp > 0:
		GameManager.add_xp(skill, xp)
		Events.chat_message.emit("Training complete — +%d %s xp." % [xp, skill])

## Spawn the boat-combat modal for a sea-monster encounter. Player.gd has set
## `_in_sea_combat = true`; the modal emits `sea_combat_ended` with the
## outcome (win/flee/lose), which Player.gd handles for loot/XP/sink.
func _on_sea_combat_start(monster_type: String) -> void:
	var bc := BoatCombat.new()
	bc.setup(monster_type)
	add_child(bc)

## Spawn the cast balance minigame. Player.gd has set `_casting = true`;
## the modal emits `cast_minigame_ended(success)` which Player.gd uses to
## either resolve the catch (success) or chat the snap (fail).
func _on_cast_minigame_start() -> void:
	var cb := CastBalanceMinigame.new()
	add_child(cb)

func _on_friend_request_received(from_username: String) -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 203
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_GOLD, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top  = 0.0; panel.anchor_bottom = 0.0
	panel.offset_left = -150; panel.offset_right = 150
	panel.offset_top  = 50;   panel.offset_bottom = 130
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "%s wants to add you as a friend." % from_username
	lbl.add_theme_color_override("font_color", RS_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	var acc := Button.new()
	acc.text = "Accept"
	acc.add_theme_font_size_override("font_size", 11)
	acc.add_theme_color_override("font_color", RS_GREEN)
	acc.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_friend_accept(from_username))
	hbox.add_child(acc)

	var dec := Button.new()
	dec.text = "Decline"
	dec.add_theme_font_size_override("font_size", 11)
	dec.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_friend_decline(from_username))
	hbox.add_child(dec)

# ── RANKINGS tab ─────────────────────────────────────────────────────────────

# ── Generic placeholder tab ───────────────────────────────────────────────────
func _build_placeholder_tab(title: String, body: String) -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	root.add_child(_tab_title(title))
	root.add_child(HSeparator.new())
	var lbl := Label.new()
	lbl.text = body
	lbl.add_theme_color_override("font_color", RS_DIM)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(lbl)
	return root

# ── Tab title helper ─────────────────────────────────────────────────────────
func _tab_title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", RS_GOLD)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl

# ── Hover tooltip (top-center) ────────────────────────────────────────────────
func _build_hover_label() -> void:
	_hover_lbl = Label.new()
	_hover_lbl.anchor_left   = 0.5;  _hover_lbl.anchor_right  = 0.5
	_hover_lbl.anchor_top    = 0.0;  _hover_lbl.anchor_bottom = 0.0
	_hover_lbl.offset_left   = -160; _hover_lbl.offset_top    = 10
	_hover_lbl.offset_right  = 160;  _hover_lbl.offset_bottom = 38
	_hover_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hover_lbl.add_theme_color_override("font_color", RS_GOLD)
	_hover_lbl.add_theme_font_size_override("font_size", 13)
	_hover_lbl.visible = false
	add_child(_hover_lbl)

func show_hover(text: String) -> void:
	if _hover_lbl:
		_hover_lbl.text    = text
		_hover_lbl.visible = true

func hide_hover() -> void:
	if _hover_lbl:
		_hover_lbl.visible = false

# ── Interaction popup (bottom-center) ─────────────────────────────────────────
func _build_interaction_popup() -> void:
	_popup = PanelContainer.new()
	_popup.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_popup.anchor_left   = 0.5;  _popup.anchor_right  = 0.5
	_popup.anchor_top    = 1.0;  _popup.anchor_bottom = 1.0
	_popup.offset_left   = -140; _popup.offset_top    = -80
	_popup.offset_right  = 140;  _popup.offset_bottom = -10
	_popup.visible       = false
	add_child(_popup)

	var vbox := VBoxContainer.new()
	_popup.add_child(vbox)

	_action_lbl = Label.new()
	_action_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_action_lbl.add_theme_color_override("font_color", RS_GOLD)
	_action_lbl.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_action_lbl)

	_target_lbl = Label.new()
	_target_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_lbl.add_theme_color_override("font_color", RS_TEXT)
	_target_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_target_lbl)

func _on_show(data: Dictionary) -> void:
	if _popup == null:
		return
	if data.get("type") == "action":
		_action_lbl.text = "%s  %s" % [data.get("action","Interact"), data.get("target","")]
		_target_lbl.text = "(%s)" % (data.get("skill","") as String).capitalize()
	else:
		_action_lbl.text = data.get("message","Can't do that.")
		_target_lbl.text = ""
	_popup.visible = true
	if _popup_tween:
		_popup_tween.kill()
	_popup_tween = create_tween()
	_popup_tween.tween_interval(3.5)
	_popup_tween.tween_callback(func() -> void:
		if is_instance_valid(_popup):
			_popup.visible = false)

func _on_hide() -> void:
	if _popup:
		_popup.visible = false
	if _popup_tween:
		_popup_tween.kill()

# ── Boat launch/dock prompt (persistent while at a water/land edge) ───────────
func _build_boat_prompt() -> void:
	_boat_prompt_btn = Button.new()
	_boat_prompt_btn.visible = false
	_boat_prompt_btn.anchor_left = 0.5; _boat_prompt_btn.anchor_right = 0.5
	_boat_prompt_btn.anchor_top  = 1.0; _boat_prompt_btn.anchor_bottom = 1.0
	_boat_prompt_btn.offset_left = -120; _boat_prompt_btn.offset_right = 120
	_boat_prompt_btn.offset_top  = -90;  _boat_prompt_btn.offset_bottom = -58
	_boat_prompt_btn.add_theme_stylebox_override("normal",  _rs(Color(0.06, 0.10, 0.22, 0.92), RS_GOLD, 2))
	_boat_prompt_btn.add_theme_stylebox_override("hover",   _rs(Color(0.10, 0.16, 0.34, 0.95), RS_GOLD, 2))
	_boat_prompt_btn.add_theme_stylebox_override("pressed", _rs(Color(0.08, 0.12, 0.28, 0.95), RS_GOLD, 2))
	_boat_prompt_btn.add_theme_color_override("font_color", RS_GOLD)
	_boat_prompt_btn.add_theme_font_size_override("font_size", 13)
	_boat_prompt_btn.pressed.connect(func() -> void: Events.boat_toggle.emit())
	add_child(_boat_prompt_btn)

func _on_boat_prompt(text: String) -> void:
	if _boat_prompt_btn == null:
		return
	_boat_prompt_btn.text = text
	_boat_prompt_btn.visible = not text.is_empty()

# ── Tile coordinates (below tab strip) ────────────────────────────────────────
## K opens/closes the full-screen Skills Book. Handled here rather than a
## Player input map action so opening a UI panel doesn't fire a movement
## keybind on the way through. Ignored while a text input is focused.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var kev := event as InputEventKey
	if not kev.pressed or kev.echo:
		return
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	if kev.keycode == KEY_K:
		if _skills_book_window != null and _skills_book_window.visible:
			_skills_book_window.visible = false
		else:
			open_skills_book()
		get_viewport().set_input_as_handled()

## PvP toggle chip — sits just under the minimap corner panel. Click to
## flip the flag via `GameManager.request_pvp_toggle`; the cooldown gate
## lives in the autoload so the same rule applies if a chat command or
## debug hook fires the request later. Countdown updates in `_process`.
var _pvp_btn: Button = null

## Track the last attacker for kill-credit routing. `pvp_death` uses these
## so the server can credit XP + a token to the correct killer even when
## the killing blow arrived milliseconds before the victim's client saw HP
## reach zero. Cleared on respawn.
var _last_pvp_attacker_id: String = ""
var _last_pvp_attacker_name: String = ""
var _last_pvp_attacker_style: String = "melee"

## PvP incoming — hooked once at HUD build time. Rejection reasons chat.
## `pvp_hit_taken` routes to Player.gd via a call so damage + hit-flash
## apply through the same path used for monster attacks.
func _wire_pvp_signals() -> void:
	NetworkManager.pvp_reject.connect(func(reason: String) -> void:
		Events.chat_message.emit(reason))
	NetworkManager.pvp_locked.connect(func(remaining: int) -> void:
		@warning_ignore("integer_division")
		var mins: int = remaining / 60
		Events.chat_message.emit("PvP locked for %dm %02ds" % [mins, remaining % 60]))
	NetworkManager.pvp_flag_changed.connect(func(id: String, uname: String, flagged: bool) -> void:
		if uname == NetworkManager.my_username:
			# Server confirmed our flag; keep GameManager in sync in case
			# a reset came from elsewhere.
			GameManager.pvp_flagged = flagged
			_refresh_pvp_btn()
		# Apply to the ONE matching OtherPlayer. Player ids are TEXT hex tokens
		# (players.id), so compare as STRINGS — int()-ing a hex id collapses it
		# to 0 and would flag EVERY player (0==0). `id` and `server_id` are both
		# the raw hex string.
		for op in get_tree().get_nodes_in_group("other_player"):
			if str(op.get_meta("server_id", "")) == id \
					and op.has_method("set_pvp_flagged"):
				op.call("set_pvp_flagged", flagged)
				break)
	NetworkManager.pvp_hit_taken.connect(func(att: String, uname: String, dmg: int, style: String) -> void:
		# Reject damage during post-death grace — server should already
		# refuse but the client mirror keeps the UI honest if a stale
		# packet crosses the grace boundary.
		if GameManager.is_pvp_safe():
			return
		# Remember who hit us + with what — the kill-credit payload uses
		# the LAST attacker's identity even if multiple players were on us.
		_last_pvp_attacker_id = att
		_last_pvp_attacker_name = uname
		_last_pvp_attacker_style = style
		# Surface the attacker: register them in the docked list, show the
		# incoming attack visual, and auto-target if we had nobody selected —
		# so a defender with chat closed still SEES who's on them.
		_pvp_register_attacker(att, uname, style)
		var att_node: Node2D = null
		if _pvp_attackers.has(att):
			att_node = _pvp_attackers[att]["node"]
		_pvp_show_incoming(att_node, style)
		# Defender-side mitigation (Phase 4): split defense vs the attacker's
		# style + a block roll. The attacker already rolled their own crit.
		var pmit := GameManager.mitigate_incoming(dmg, style)
		var take: int = int(pmit[0])
		var pblk: bool = bool(pmit[1])
		# Apply the incoming damage via the same GameManager HP path used
		# for monster hits. Player.gd's hit-flash listens to `player_hp_changed`.
		GameManager.current_hp = maxi(0, GameManager.current_hp - take)
		Events.player_hp_changed.emit(GameManager.current_hp, GameManager.get_max_hp())
		Events.chat_message.emit("%s hit you for %d%s." % [uname, take, "  (Blocked!)" if pblk else ""])
		if GameManager.current_hp <= 0:
			_on_pvp_death(uname))
	NetworkManager.pvp_hit_confirm.connect(func(_tid: String, dmg: int) -> void:
		Events.chat_message.emit("Hit for %d." % dmg))
	NetworkManager.pvp_kill_credit.connect(func(style: String, xp: int, victim: String) -> void:
		# Server confirmed we killed `victim` with `style`. Award XP only
		# in the combat skill used. The PvP Token is now a SERVER-OWNED
		# currency (Phase 1d) credited by the server — the new balance arrives
		# via pvp_tokens_set, so we don't add an inventory item here.
		if xp > 0:
			GameManager.add_xp(style, xp)
		Events.chat_message.emit("Slain %s. +%d %s XP, +1 PvP Token." % [
			victim, xp, style.capitalize()]))
	# Server-owned PvP-Token balance sync (login / kill / admin / upgrade).
	NetworkManager.pvp_tokens_set.connect(func(bal: int) -> void:
		GameManager.set_pvp_tokens(bal))
	# Approved gear upgrade — swap the piece in place + sync balance.
	NetworkManager.token_upgrade_ok.connect(func(slot: String, old_id: String, new_id: String, _lvl: int, bal: int) -> void:
		GameManager.apply_token_upgrade(slot, old_id, new_id, bal)
		_refresh_token_upgrade_ui())
	NetworkManager.token_upgrade_reject.connect(func(reason: String, _bal: int) -> void:
		Events.chat_message.emit("Upgrade: %s" % reason))

## PvP death drop policy — RuneScape-style protection:
##   • Everything EQUIPPED stays (already excluded — equipment lives in
##     GameManager.equipment, not inventory).
##   • The top-3 most-valuable inventory stacks are kept (protect list).
##   • Everything else drops as LootDrops.
##   • 25% of gold drops as a gold pile; 75% is kept.
## Server also auto-adds 1 bone + 1 pvp_token piles + credits the killer.
const PVP_DEATH_PROTECT_COUNT: int = 3
const PVP_DEATH_GOLD_DROP_FRAC: float = 0.25

func _on_pvp_death(killer_uname: String) -> void:
	if _player == null:
		return
	var pos: Vector2 = (_player as Node2D).global_position
	# Build a value-ranked list of inventory slot indices so we can decide
	# which ones survive. Value estimate uses the tier prefix hierarchy
	# (runite > adamant > mithril > gold > iron > copper > default) plus a
	# small bonus for larger stacks. Not perfect but keeps runite gear +
	# stacked shards safe over stone.
	var ranked: Array = []
	for i in range(GameManager.inventory.size()):
		var iid := str(GameManager.inventory[i]["id"])
		var qty := int(GameManager.inventory[i]["qty"])
		ranked.append({"idx": i, "value": _pvp_death_item_value(iid, qty)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["value"]) > int(b["value"]))
	var protected_set: Dictionary = {}
	for j in range(min(PVP_DEATH_PROTECT_COUNT, ranked.size())):
		protected_set[int((ranked[j] as Dictionary)["idx"])] = true

	# Drops payload — everything NOT in the protected set.
	var drops: Array = []
	for i in range(GameManager.inventory.size()):
		if protected_set.has(i):
			continue
		var item: Dictionary = GameManager.inventory[i]
		var col: Color = Color.WHITE
		if item.get("color") is Color:
			col = item["color"] as Color
		drops.append({
			"id":    str(item["id"]),
			"name":  str(item.get("name", item["id"])),
			"qty":   int(item["qty"]),
			"color": [col.r, col.g, col.b, col.a],
		})

	# Attach killer + style so the server can credit XP + a token.
	NetworkManager.send_pvp_death_v2(pos.x, pos.y, drops,
		_last_pvp_attacker_id, _last_pvp_attacker_style,
		int(GameManager.gold))

	# Locally: strip everything except the protected slots + drop 25% gold.
	var keep_items: Array[Dictionary] = []
	for i in range(GameManager.inventory.size()):
		if protected_set.has(i):
			keep_items.append(GameManager.inventory[i])
	GameManager.inventory = keep_items
	var lost_gold: int = int(float(GameManager.gold) * PVP_DEATH_GOLD_DROP_FRAC)
	GameManager.gold = maxi(0, GameManager.gold - lost_gold)
	Events.inventory_changed.emit()
	Events.chat_message.emit("You were slain by %s." % killer_uname)
	if lost_gold > 0:
		Events.chat_message.emit("You dropped %d gold." % lost_gold)
	# Respawn: match the normal death path (teleport + full HP), then start
	# the safe-mode grace. Uses Events.player_respawned so Player.gd handles
	# the actual position warp uniformly with other respawn paths.
	GameManager.current_hp = GameManager.get_max_hp()
	Events.player_hp_changed.emit(GameManager.current_hp, GameManager.get_max_hp())
	Events.player_respawned.emit(GameManager.RESPAWN_POS)
	GameManager.begin_pvp_safe_mode()
	# Server clears our flag automatically when it processes pvp_death, so
	# there's no explicit toggle-off needed here — the pvp_flag broadcast
	# reaches every other client the same way as a manual toggle.
	_refresh_pvp_btn()

func _pvp_death_item_value(item_id: String, qty: int) -> int:
	# Coarse tier-based value estimate — no live item DB on the client,
	# so we bucket by material prefix. Runite/adamant/mithril at the top
	# so end-game gear is protected first; stack size adds a small boost
	# so a big pile of arrows/runes edges out one cheap tool.
	var base: int = 10
	if item_id.begins_with("runite"):   base = 900
	elif item_id.begins_with("adamant"): base = 500
	elif item_id.begins_with("mithril"): base = 260
	elif item_id.begins_with("gold"):    base = 180
	elif item_id.begins_with("iron"):    base = 90
	elif item_id.begins_with("copper"):  base = 30
	elif item_id.begins_with("leather"): base = 25
	elif item_id.begins_with("dragon"):  base = 1400
	elif "rune_" in item_id:             base = 12
	return base + qty * 2

func _build_pvp_toggle() -> void:
	_wire_pvp_signals()
	_pvp_btn = Button.new()
	_pvp_btn.anchor_left  = 1.0; _pvp_btn.anchor_right  = 1.0
	_pvp_btn.anchor_top   = 0.0; _pvp_btn.anchor_bottom = 0.0
	# Directly below the minimap panel (offset_bottom 182 → start at 186).
	_pvp_btn.offset_left  = -174; _pvp_btn.offset_right  = -6
	_pvp_btn.offset_top   = 186;  _pvp_btn.offset_bottom = 210
	_pvp_btn.add_theme_font_size_override("font_size", 11)
	_pvp_btn.pressed.connect(_on_pvp_toggle_pressed)
	add_child(_pvp_btn)
	_refresh_pvp_btn()
	# "Upgrades" entry — spend PvP Tokens to permanently boost gear (Phase 1d).
	# Sits directly under the PvP toggle. In-world this is also opened by the
	# PvP-Token NPC (open_shop "token_upgrade").
	_token_open_btn = Button.new()
	_token_open_btn.anchor_left = 1.0; _token_open_btn.anchor_right = 1.0
	_token_open_btn.anchor_top  = 0.0; _token_open_btn.anchor_bottom = 0.0
	_token_open_btn.offset_left = -174; _token_open_btn.offset_right = -6
	_token_open_btn.offset_top  = 214;  _token_open_btn.offset_bottom = 238
	_token_open_btn.add_theme_font_size_override("font_size", 11)
	_token_open_btn.pressed.connect(open_token_upgrade_window)
	add_child(_token_open_btn)
	_refresh_token_open_btn()
	Events.pvp_tokens_changed.connect(func(_b: int) -> void: _refresh_token_open_btn())

func _on_pvp_toggle_pressed() -> void:
	# Mirror the toggle to the server so mutual-flag PvP attacks resolve
	# server-side. If the client-side rule refuses (still in cooldown),
	# don't bother firing the server request.
	var want_on := not GameManager.pvp_flagged
	var msg := GameManager.request_pvp_toggle(want_on)
	if msg != "":
		Events.chat_message.emit(msg)
	else:
		NetworkManager.send_pvp_toggle(want_on)
	_refresh_pvp_btn()

func _refresh_pvp_btn() -> void:
	if _pvp_btn == null:
		return
	var now: float = Time.get_unix_time_from_system()
	if GameManager.pvp_flagged:
		var rem: float = GameManager.pvp_locked_until - now
		if rem > 0.0:
			var s: int = int(ceil(rem))
			@warning_ignore("integer_division")
			var mins: int = s / 60
			_pvp_btn.text = "⚔ PvP  ON  (%dm %02ds)" % [mins, s % 60]
		else:
			_pvp_btn.text = "⚔ PvP  ON  (click to disable)"
		_pvp_btn.add_theme_color_override("font_color", Color(1.00, 0.35, 0.30))
	elif GameManager.is_pvp_safe():
		var srem: int = int(ceil(GameManager.pvp_safe_until - now))
		# Three-state UI: SAFE reads as blue-shield; clicking here opts back
		# into full PvP (override) per the user's post-death design.
		_pvp_btn.text = "🛡 SAFE  (%02ds — click to re-enable)" % srem
		_pvp_btn.add_theme_color_override("font_color", Color(0.55, 0.75, 1.00))
	else:
		_pvp_btn.text = "🛡 PvP  OFF"
		_pvp_btn.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55))

func _build_coords_label() -> void:
	_coords_lbl = Label.new()
	_coords_lbl.anchor_left   = 0.0;  _coords_lbl.anchor_right  = 0.0
	_coords_lbl.anchor_top    = 1.0;  _coords_lbl.anchor_bottom = 1.0
	_coords_lbl.offset_left   = 6;    _coords_lbl.offset_top    = -20
	_coords_lbl.offset_right  = 160;  _coords_lbl.offset_bottom = -2
	_coords_lbl.add_theme_color_override("font_color", RS_DIM)
	_coords_lbl.add_theme_font_size_override("font_size", 10)
	add_child(_coords_lbl)

# ── Floating XP text ──────────────────────────────────────────────────────────
func _on_xp_gained(skill: String, amount: int) -> void:
	if _player == null:
		return
	var screen_pos: Vector2 = get_viewport().get_canvas_transform() * _player.global_position
	var lbl := Label.new()
	lbl.text = "+%d %s XP" % [amount, (skill as String).capitalize()]
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", RS_GREEN)
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.position = screen_pos + Vector2(-50, -40)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "position", lbl.position + Vector2(0, -55), 1.6)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.6)
	tw.chain().tween_callback(lbl.queue_free)

# ── Forge window ──────────────────────────────────────────────────────────────
const _FORGE_RECIPES: Array = [
	{"name": "Copper Bar",  "id": "copper_bar",  "color": Color(0.80, 0.50, 0.20),
	 "input": [{"id": "copper_ore",  "name": "Copper Ore",  "qty": 2}], "xp": 25,  "req_lv": 1},
	{"name": "Iron Bar",    "id": "iron_bar",    "color": Color(0.60, 0.60, 0.65),
	 "input": [{"id": "iron_ore",    "name": "Iron Ore",    "qty": 2}], "xp": 50,  "req_lv": 15},
	{"name": "Gold Bar",    "id": "gold_bar",    "color": Color(0.95, 0.80, 0.15),
	 "input": [{"id": "gold_ore",    "name": "Gold Ore",    "qty": 2}], "xp": 65,  "req_lv": 30},
	{"name": "Mithril Bar", "id": "mithril_bar", "color": Color(0.40, 0.65, 0.90),
	 "input": [{"id": "mithril_ore", "name": "Mithril Ore", "qty": 2}], "xp": 90,  "req_lv": 50},
	{"name": "Adamant Bar", "id": "adamant_bar", "color": Color(0.20, 0.65, 0.30),
	 "input": [{"id": "adamant_ore", "name": "Adamant Ore", "qty": 2}], "xp": 110, "req_lv": 70},
	{"name": "Runite Bar",  "id": "runite_bar",  "color": Color(0.65, 0.20, 0.82),
	 "input": [{"id": "runite_ore",  "name": "Runite Ore",  "qty": 2}], "xp": 125, "req_lv": 85},
]

func _build_forge_window() -> void:
	_forge_window = PanelContainer.new()
	_forge_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_forge_window.anchor_left   = 0.5;  _forge_window.anchor_right  = 0.5
	_forge_window.anchor_top    = 0.5;  _forge_window.anchor_bottom = 0.5
	_forge_window.offset_left   = -160; _forge_window.offset_right  = 160
	_forge_window.offset_top    = -190; _forge_window.offset_bottom = 190
	_forge_window.visible       = false
	add_child(_forge_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_forge_window.add_child(root)

	# Title row with close button
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title_lbl := _tab_title("⚒  Forge")
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)
	# Playtest split — weapons + armor moved off the Crafting Bench onto the
	# smithing skill. Button opens the dedicated gear window built in
	# _build_craft_window (`_smith_gear_window`).
	var gear_btn := Button.new()
	gear_btn.text = "⚔ Weapons & Armor"
	gear_btn.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_GOLD, 2))
	gear_btn.add_theme_stylebox_override("hover",  _rs(RS_BTN_H, RS_GOLD, 2))
	gear_btn.add_theme_color_override("font_color", RS_GOLD)
	gear_btn.add_theme_font_size_override("font_size", 11)
	gear_btn.pressed.connect(func() -> void:
		if _smith_gear_window != null:
			_refresh_craft()
			_smith_gear_window.visible = true
			_register_proximity_panel(_smith_gear_window))
	title_row.add_child(gear_btn)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_color_override("font_color", RS_DIM)
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.pressed.connect(func() -> void: _forge_window.visible = false)
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	var skill_lbl := Label.new()
	skill_lbl.text = "Smithing level: %d" % GameManager.get_skill_level("smithing")
	skill_lbl.add_theme_color_override("font_color", RS_DIM)
	skill_lbl.add_theme_font_size_override("font_size", 10)
	root.add_child(skill_lbl)

	_forge_recipe_btns.clear()
	for recipe: Dictionary in _FORGE_RECIPES:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
		root.add_child(card)

		var cvbox := VBoxContainer.new()
		cvbox.add_theme_constant_override("separation", 3)
		card.add_child(cvbox)

		# Name row — real bar icon (falls back to the color swatch only if
		# the sprite isn't shipped yet). Playtest ask: cards need to look
		# like the other recipe lists, not swatched.
		var name_row := HBoxContainer.new()
		name_row.add_theme_constant_override("separation", 6)
		cvbox.add_child(name_row)
		var out_icon := TextureRect.new()
		out_icon.custom_minimum_size = Vector2(24, 24)
		out_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var out_icon_path := "res://assets/icons/" + str(recipe["id"]) + ".png"
		if ResourceLoader.exists(out_icon_path):
			out_icon.texture = load(out_icon_path) as Texture2D
		else:
			# Fallback swatch — still 24×24 so row heights stay consistent.
			var fb := ColorRect.new()
			fb.custom_minimum_size = Vector2(24, 24)
			fb.color = recipe["color"] as Color
			out_icon.add_child(fb)
		name_row.add_child(out_icon)
		var rname := Label.new()
		rname.text = recipe["name"]
		rname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rname.add_theme_color_override("font_color", RS_GOLD)
		rname.add_theme_font_size_override("font_size", 12)
		name_row.add_child(rname)

		# Ingredient row — one icon+qty pill per input. Matches how the
		# other recipe windows lay out inputs.
		var reqs_row := HBoxContainer.new()
		reqs_row.add_theme_constant_override("separation", 8)
		cvbox.add_child(reqs_row)
		var req_prefix := Label.new()
		req_prefix.text = "Needs:"
		req_prefix.add_theme_color_override("font_color", RS_DIM)
		req_prefix.add_theme_font_size_override("font_size", 10)
		reqs_row.add_child(req_prefix)
		for ing: Dictionary in recipe["input"] as Array:
			var ing_pill := HBoxContainer.new()
			ing_pill.add_theme_constant_override("separation", 3)
			reqs_row.add_child(ing_pill)
			var ing_icon := TextureRect.new()
			ing_icon.custom_minimum_size = Vector2(16, 16)
			ing_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var ing_path := "res://assets/icons/" + str(ing["id"]) + ".png"
			if ResourceLoader.exists(ing_path):
				ing_icon.texture = load(ing_path) as Texture2D
			ing_pill.add_child(ing_icon)
			var ing_lbl := Label.new()
			ing_lbl.text = "%d× %s" % [int(ing["qty"]), str(ing["name"])]
			ing_lbl.add_theme_color_override("font_color", RS_TEXT)
			ing_lbl.add_theme_font_size_override("font_size", 10)
			ing_pill.add_child(ing_lbl)

		var xp_lbl := Label.new()
		xp_lbl.text = "+%d Smithing XP  |  Req. Lv %d" % [recipe["xp"], recipe["req_lv"]]
		xp_lbl.add_theme_color_override("font_color", RS_DIM)
		xp_lbl.add_theme_font_size_override("font_size", 9)
		cvbox.add_child(xp_lbl)

		var smelt_btn := Button.new()
		smelt_btn.text = "Smelt"
		smelt_btn.add_theme_stylebox_override("normal",   _rs(RS_BTN_A, RS_GOLD, 2))
		smelt_btn.add_theme_stylebox_override("hover",    _rs(RS_BTN_H, RS_GOLD, 2))
		smelt_btn.add_theme_stylebox_override("disabled", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 2))
		smelt_btn.add_theme_color_override("font_color",          RS_GOLD)
		smelt_btn.add_theme_color_override("font_disabled_color", RS_DIM)
		smelt_btn.add_theme_font_size_override("font_size", 11)
		smelt_btn.pressed.connect(_smelt.bind(recipe))
		cvbox.add_child(smelt_btn)
		_forge_recipe_btns.append(smelt_btn)

func _on_open_forge() -> void:
	_refresh_forge()
	_forge_window.visible = true
	_register_proximity_panel(_forge_window)

## inventory_changed hook — only does work while the forge panel is open.
func _refresh_forge_if_visible() -> void:
	if _forge_window != null and _forge_window.visible:
		_refresh_forge()

func _refresh_forge() -> void:
	var smithing_lv := GameManager.get_skill_level("smithing")
	for i in range(_forge_recipe_btns.size()):
		var recipe: Dictionary = _FORGE_RECIPES[i]
		var btn := _forge_recipe_btns[i]
		# Show WHY a bar can't be smelted right on the button, instead of a
		# silent grey — the top playtest confusion ("I don't know why").
		var reason := ""
		if smithing_lv < (recipe["req_lv"] as int):
			reason = "Req Smithing Lv %d" % int(recipe["req_lv"])
		else:
			for ing: Dictionary in recipe["input"] as Array:
				var have := GameManager.get_item_qty(ing["id"] as String)
				if have < (ing["qty"] as int):
					reason = "Need %d× %s (have %d)" % [int(ing["qty"]), str(ing["name"]), have]
					break
		if reason == "":
			btn.text = "Smelt"
			btn.disabled = false
			btn.tooltip_text = ""
		else:
			btn.text = "Smelt  —  %s" % reason
			btn.disabled = true
			btn.tooltip_text = reason

## ⑤ SERVER-AUTHORITY — the single choke point every item-craft flows through
## (smelt / cook / craft / rune / construct-item). Instead of consuming mats +
## granting the output + XP locally (which the server would then have to trust
## at save time), we ask the SERVER to craft one: it validates skill+materials
## against its own DB inventory, rolls burn, consumes, grants, and pushes the
## authoritative inventory back (admin_inventory_set) + a craft_result toast/XP.
## `recipe` is the client's recipe dict; we normalise it to the server shape and
## send it as an UNBAKED fallback — once the recipe table is baked the server
## ignores the claim and uses its own copy. The client mints nothing locally.
func _request_server_craft(recipe: Dictionary, skill: String) -> void:
	if NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
		Events.chat_message.emit("You must be online to craft.")
		return
	var col: Color = recipe.get("color", Color(0.7, 0.7, 0.7)) as Color
	var inputs: Array = []
	for ing: Dictionary in recipe.get("input", []) as Array:
		inputs.append({"id": str(ing.get("id", "")), "qty": int(ing.get("qty", 1))})
	var payload := {
		"skill":     skill,
		"req_lv":    int(recipe.get("req_lv", 1)),
		"xp":        int(recipe.get("xp", 0)),
		"out_id":    str(recipe.get("id", "")),
		"out_name":  str(recipe.get("name", "")),
		"out_color": [col.r, col.g, col.b, col.a],
		"out_qty":   int(recipe.get("out_qty", 1)),
		"input":     inputs,
	}
	NetworkManager.send_craft(str(recipe.get("id", "")), payload)

## ⑤ BAKE — one recipe → server shape, keyed into `out` by id.
func _bake_recipe_into(out: Dictionary, recipe: Dictionary, skill: String) -> void:
	var rid := str(recipe.get("id", ""))
	if rid == "":
		return
	var col: Color = recipe.get("color", Color(0.7, 0.7, 0.7)) as Color
	var inputs: Array = []
	for ing: Dictionary in recipe.get("input", []) as Array:
		inputs.append({"id": str(ing.get("id", "")), "qty": int(ing.get("qty", 1))})
	out[rid] = {
		"skill":     skill,
		"req_lv":    int(recipe.get("req_lv", 1)),
		"xp":        int(recipe.get("xp", 0)),
		"out_id":    rid,
		"out_name":  str(recipe.get("name", rid)),
		"out_color": [col.r, col.g, col.b, col.a],
		"out_qty":   int(recipe.get("out_qty", 1)),
		"input":     inputs,
	}

## ⑤ BAKE — snapshot every craftable recipe into the server-authoritative table
## {recipe_id: {skill, req_lv, xp, out_id, out_name, out_color, out_qty, input}}.
## The AdminPanel bake button uploads this so the server crafts from its OWN copy
## and the client can no longer mint items. PLACEMENT recipes (walls, farm plots,
## warband settlements) are excluded — they aren't inventory items and never flow
## through the `craft` handler.
func bake_recipes() -> Dictionary:
	var out: Dictionary = {}
	for r: Dictionary in _FORGE_RECIPES:                       # bars (smithing)
		_bake_recipe_into(out, r, "smithing")
	for r: Dictionary in _COOK_RECIPES:                        # cooking
		_bake_recipe_into(out, r, str(r.get("skill", "cooking")))
	for r: Dictionary in _build_all_craft_recipes():           # bench/gear/jewel
		_bake_recipe_into(out, r, str(r.get("skill", "crafting")))
	for r: Dictionary in _RUNE_RECIPES:                        # runes (magic)
		_bake_recipe_into(out, r, "magic")
	for r: Dictionary in _build_all_construction_recipes():    # item constructs + boats
		var rid := str(r.get("id", ""))
		if rid.ends_with("_wall") or rid.ends_with("_fortified_wall"):
			continue
		if rid == "farm_plot" or rid == "stronghold" or rid == "banner" or rid == "outpost":
			continue
		_bake_recipe_into(out, r, "construction")
	return out

## ⑥ BAKE — snapshot the fishing species table so the SERVER grants catches.
## {species_id: {base_xp, wr_lv, min_catch_lv, name, color}}. `wr_lv` feeds the
## weight-range math; `min_catch_lv` is the fishing level below which the species
## can't be claimed (boat fish: the previous tier's `max`; deep fish: `min_lv`).
const _FishDefs = preload("res://scripts/Player.gd")   # _BOAT_FISH / _DEEP_FISH consts
func bake_fishing() -> Dictionary:
	var out: Dictionary = {}
	var boat: Array = _FishDefs._BOAT_FISH
	for i in range(boat.size()):
		var f: Dictionary = boat[i]
		var col: Color = f.get("color", Color(0.7, 0.7, 0.7)) as Color
		var min_catch: int = 0 if i == 0 else int((boat[i - 1] as Dictionary).get("max", 0))
		out[str(f.get("id", ""))] = {
			"base_xp": int(f.get("xp", 0)), "wr_lv": 1, "min_catch_lv": min_catch,
			"name": str(f.get("name", "")), "color": [col.r, col.g, col.b, col.a]}
	for f: Dictionary in _FishDefs._DEEP_FISH:
		var dcol: Color = f.get("color", Color(0.7, 0.7, 0.7)) as Color
		var lv := int(f.get("min_lv", 1))
		out[str(f.get("id", ""))] = {
			"base_xp": int(f.get("xp", 0)), "wr_lv": lv, "min_catch_lv": lv,
			"name": str(f.get("name", "")), "color": [dcol.r, dcol.g, dcol.b, dcol.a]}
	return out

## ⑥ BAKE — snapshot the sea-monster loot table so the SERVER grants boat-fight
## wins. {monster_type: {name, xp_reward, loot:[{id,name,qty,color}]}}.
const _SeaDefs = preload("res://scripts/SeaMonsters.gd")
func bake_sea_loot() -> Dictionary:
	var out: Dictionary = {}
	for mtype: Variant in _SeaDefs.SEA_MONSTERS.keys():
		var m: Dictionary = _SeaDefs.SEA_MONSTERS[mtype]
		var loot_out: Array = []
		for it: Variant in (m.get("loot", []) as Array):
			if it is Dictionary:
				var d: Dictionary = it
				var col: Color = d.get("color", Color(0.7, 0.7, 0.7)) as Color
				loot_out.append({"id": str(d.get("id", "")), "name": str(d.get("name", "")),
					"qty": int(d.get("qty", 1)), "color": [col.r, col.g, col.b, col.a]})
		out[str(mtype)] = {"name": str(m.get("name", mtype)),
			"xp_reward": int(m.get("xp_reward", 0)), "loot": loot_out}
	return out

func _smelt(recipe: Dictionary) -> void:
	var smithing_lv := GameManager.get_skill_level("smithing")
	if smithing_lv < (recipe["req_lv"] as int):
		Events.chat_message.emit("Requires Smithing Lv %d to smelt %s (you're %d)." % [
			int(recipe["req_lv"]), str(recipe["name"]), smithing_lv])
		return
	for ing: Dictionary in recipe["input"] as Array:
		var have := GameManager.get_item_qty(ing["id"] as String)
		if have < (ing["qty"] as int):
			Events.chat_message.emit("Need %d× %s to smelt %s (you have %d)." % [
				int(ing["qty"]), str(ing["name"]), str(recipe["name"]), have])
			return
	# Server owns the consume + grant + XP + burn roll; it pushes the result.
	_request_server_craft(recipe, "smithing")
	_refresh_forge()

# ── HP bar (always-visible, bottom-right) ─────────────────────────────────────
func _build_hp_bar() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 2))
	panel.anchor_left   = 1.0; panel.anchor_right  = 1.0
	panel.anchor_top    = 1.0; panel.anchor_bottom = 1.0
	# Bigger + more legible (playtest ask): wider and taller than before.
	panel.offset_left   = -260; panel.offset_right  = -6
	panel.offset_top    = -62;  panel.offset_bottom = -6
	add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	panel.add_child(hbox)

	var heart := Label.new()
	heart.text = "❤"
	heart.add_theme_color_override("font_color", Color(0.95, 0.20, 0.20))
	heart.add_theme_font_size_override("font_size", 22)
	hbox.add_child(heart)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 3)
	hbox.add_child(vbox)

	_hp_lbl = Label.new()
	_hp_lbl.add_theme_color_override("font_color", RS_TEXT)
	_hp_lbl.add_theme_font_size_override("font_size", 15)
	vbox.add_child(_hp_lbl)

	_hp_bar = ProgressBar.new()
	_hp_bar.max_value       = 100
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size = Vector2(0, 20)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hp_bar.add_theme_stylebox_override("fill",       _rs(Color(0.75,0.10,0.10), Color(0.95,0.20,0.20), 0))
	_hp_bar.add_theme_stylebox_override("background", _rs(Color(0.05,0.05,0.05), RS_BORDER.darkened(0.6), 0))
	vbox.add_child(_hp_bar)

	_on_player_hp_changed(GameManager.current_hp, GameManager.get_max_hp())

func _on_player_hp_changed(current: int, maximum: int) -> void:
	if _hp_bar == null or _hp_lbl == null:
		return
	_hp_bar.max_value = maximum
	_hp_bar.value     = current
	_hp_lbl.text      = "HP  %d / %d" % [current, maximum]

# ── Rune sub-row (lives inside the unified panel; built next to style btns) ─
## A rune icon in the sub-row was clicked — set it as the active spell.
func _on_persist_rune_pressed(rune_id: String) -> void:
	GameManager.set_combat_style("magic", rune_id)
	_combat_style = "magic"
	_refresh_style_btns()
	_refresh_persist_rune_row()

## Rebuild the rune sub-row to show only runes the player owns AND is
## level-gated for. Hidden entirely when style != "magic".
func _refresh_persist_rune_row() -> void:
	if _persist_rune_row == null:
		return
	for child: Node in _persist_rune_row.get_children():
		child.queue_free()
	_persist_rune_btns.clear()
	if _combat_style != "magic":
		_persist_rune_row.visible = false
		return
	_persist_rune_row.visible = true
	var mlv := GameManager.get_skill_level("magic")
	var admin: bool = GameManager.is_admin()
	for rune_id: String in RuneSpells.usable_runes_for(mlv, admin):
		if GameManager.get_item_qty(rune_id) <= 0 and not admin:
			continue   # don't show runes the player can't cast right now
		var rb := Button.new()
		rb.text = ""
		rb.custom_minimum_size = Vector2(22, 22)
		rb.tooltip_text = "%s — Magic Lv %d" % [
			RuneSpells.name_for(rune_id), RuneSpells.req_lv(rune_id)]
		var col: Color = RuneSpells.color_for(rune_id)
		var active: bool = rune_id == GameManager.active_rune
		var border: Color = col if active else RS_BORDER.darkened(0.4)
		rb.add_theme_stylebox_override("normal", _rs(col.darkened(0.45), border, 2))
		rb.add_theme_stylebox_override("hover",  _rs(col.darkened(0.25), RS_GOLD, 2))
		rb.add_theme_stylebox_override("pressed",_rs(col.darkened(0.10), RS_GOLD, 2))
		rb.pressed.connect(func() -> void: _on_persist_rune_pressed(rune_id))
		_persist_rune_row.add_child(rb)
		_persist_rune_btns[rune_id] = rb

func _on_combat_style_changed_external(style: String, _rune: String) -> void:
	# Source-of-truth lives on GameManager; mirror to the local var and the
	# in-panel style buttons. The persistent-strip mirror is gone — the
	# unified panel's style row is the only style UI now.
	_combat_style = style
	_refresh_persist_rune_row()
	_refresh_style_btns()

func _on_xp_gained_for_rune_row(skill: String, _amount: int) -> void:
	# Hitting a magic level threshold unlocks more runes in the sub-row.
	if skill == "magic" and _combat_style == "magic":
		_refresh_persist_rune_row()

func _on_admin_rank_for_rune_row(_rank: String) -> void:
	# Promotion unlocks every rune; demotion re-engages level gating. Either
	# way the sub-row needs a rebuild.
	_refresh_persist_rune_row()

## Pick the highest-tier rune the player meets req_lv for AND has in stock.
## Returns "" if none qualify — caller treats that as "fall back to melee
## on the next swing." Admins also need a stocked rune (we don't gift them
## free casts — they just bypass the level requirement).
func _best_available_rune() -> String:
	var mlv := GameManager.get_skill_level("magic")
	var admin: bool = GameManager.is_admin()
	var best := ""
	for rune_id: String in RuneSpells.usable_runes_for(mlv, admin):
		if GameManager.get_item_qty(rune_id) > 0:
			best = rune_id   # iteration is low→high, so last hit is the best
	return best

# ── Cooking window ────────────────────────────────────────────────────────────
const _COOK_RECIPES: Array = [
	# Lv 1
	{"name": "Cooked Fish",      "id": "cooked_fish",      "color": Color(0.85, 0.65, 0.35), "skill": "cooking",
	 "input": [{"id": "raw_fish", "name": "Raw Fish", "qty": 1}], "xp": 30, "req_lv": 1},
	{"name": "Herb Tea",         "id": "herb_tea",         "color": Color(0.55, 0.85, 0.45), "skill": "cooking",
	 "input": [{"id": "herbs", "name": "Herbs", "qty": 2}], "xp": 20, "req_lv": 1},
	{"name": "Cooked Rat Meat",  "id": "cooked_rat_meat",  "color": Color(0.62, 0.40, 0.28), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}], "xp": 25, "req_lv": 1},
	{"name": "Roasted Chicken",  "id": "roasted_chicken",  "color": Color(0.86, 0.66, 0.40), "skill": "cooking",
	 "input": [{"id": "raw_chicken", "name": "Raw Chicken", "qty": 1}], "xp": 30, "req_lv": 1},
	# Lv 5
	{"name": "Grilled Trout",    "id": "grilled_trout",    "color": Color(0.80, 0.58, 0.40), "skill": "cooking",
	 "input": [{"id": "raw_fish", "name": "Raw Fish", "qty": 1}], "xp": 35, "req_lv": 5},
	{"name": "Baked Potato",     "id": "baked_potato",     "color": Color(0.74, 0.58, 0.34), "skill": "cooking",
	 "input": [{"id": "mushrooms", "name": "Mushrooms", "qty": 1}], "xp": 32, "req_lv": 5},
	# Lv 10
	{"name": "Cooked Salmon",    "id": "cooked_salmon",    "color": Color(0.95, 0.52, 0.28), "skill": "cooking",
	 "input": [{"id": "raw_salmon", "name": "Raw Salmon", "qty": 1}], "xp": 50, "req_lv": 10},
	# Vegetable Stew — playtest integration: swap the herbs for a carrot so
	# the recipe reads as "vegetables". Mushrooms stay for texture.
	{"name": "Vegetable Stew",   "id": "vegetable_stew",   "color": Color(0.40, 0.62, 0.30), "skill": "cooking",
	 "input": [{"id": "mushrooms", "name": "Mushrooms", "qty": 1}, {"id": "carrot", "name": "Carrot", "qty": 1}], "xp": 48, "req_lv": 10},
	# Lv 15
	# Meat Pie — wheat pastry crust added per farming integration.
	{"name": "Meat Pie",         "id": "meat_pie",         "color": Color(0.72, 0.50, 0.26), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}, {"id": "wheat", "name": "Wheat", "qty": 1}], "xp": 62, "req_lv": 15},
	# Fish Soup — carrot in the broth.
	{"name": "Fish Soup",        "id": "fish_soup",        "color": Color(0.55, 0.70, 0.78), "skill": "cooking",
	 "input": [{"id": "raw_fish", "name": "Raw Fish", "qty": 2}, {"id": "carrot", "name": "Carrot", "qty": 1}], "xp": 58, "req_lv": 15},
	# Lv 20
	{"name": "Cooked Lobster",   "id": "cooked_lobster",   "color": Color(0.90, 0.30, 0.20), "skill": "cooking",
	 "input": [{"id": "lobster", "name": "Lobster", "qty": 1}], "xp": 70, "req_lv": 20},
	# Hearty Stew — carrot addition.
	{"name": "Hearty Stew",      "id": "hearty_stew",      "color": Color(0.60, 0.42, 0.24), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}, {"id": "mushrooms", "name": "Mushrooms", "qty": 1}, {"id": "carrot", "name": "Carrot", "qty": 1}], "xp": 76, "req_lv": 20},
	# Lv 25
	{"name": "Shark Steak",      "id": "shark_steak",      "color": Color(0.55, 0.58, 0.62), "skill": "cooking",
	 "input": [{"id": "raw_shark", "name": "Raw Shark", "qty": 1}], "xp": 90, "req_lv": 25},
	# Honey-Glazed Ham — wheat for the glaze base.
	{"name": "Honey-Glazed Ham", "id": "honey_glazed_ham", "color": Color(0.82, 0.50, 0.22), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}, {"id": "berries", "name": "Berries", "qty": 1}, {"id": "wheat", "name": "Wheat", "qty": 1}], "xp": 86, "req_lv": 25},
	# Lv 30
	{"name": "Stuffed Boar",     "id": "stuffed_boar",     "color": Color(0.58, 0.38, 0.22), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 2}], "xp": 100, "req_lv": 30},
	{"name": "Spiced Fish",      "id": "spiced_fish",      "color": Color(0.92, 0.58, 0.34), "skill": "cooking",
	 "input": [{"id": "raw_salmon", "name": "Raw Salmon", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 96, "req_lv": 30},
	# Lv 35
	# Dragon Fin Soup — moonwheat elevates the high-tier soup.
	{"name": "Dragon Fin Soup",  "id": "dragon_fin_soup",  "color": Color(0.45, 0.66, 0.55), "skill": "cooking",
	 "input": [{"id": "raw_shark", "name": "Raw Shark", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}, {"id": "moonwheat", "name": "Moonwheat", "qty": 1}], "xp": 115, "req_lv": 35},
	{"name": "Mead-Braised Ribs","id": "mead_braised_ribs","color": Color(0.66, 0.34, 0.18), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 2}, {"id": "berries", "name": "Berries", "qty": 1}], "xp": 110, "req_lv": 35},
	# Lv 40
	{"name": "Frost Trout Fillet","id": "frost_trout_fillet","color": Color(0.62, 0.78, 0.90), "skill": "cooking",
	 "input": [{"id": "silverfin", "name": "Silverfin", "qty": 1}], "xp": 130, "req_lv": 40},
	{"name": "Venison Roast",    "id": "venison_roast",    "color": Color(0.56, 0.32, 0.20), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 2}], "xp": 125, "req_lv": 40},
	# Lv 45
	{"name": "Magma Prawn",      "id": "magma_prawn",      "color": Color(0.95, 0.42, 0.18), "skill": "cooking",
	 "input": [{"id": "lobster", "name": "Lobster", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 140, "req_lv": 45},
	{"name": "Smoked Bear",      "id": "smoked_bear",      "color": Color(0.48, 0.32, 0.20), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 3}], "xp": 138, "req_lv": 45},
	# Lv 50
	{"name": "Elder Fish Platter","id": "elder_fish_platter","color": Color(0.40, 0.50, 0.40), "skill": "cooking",
	 "input": [{"id": "anglerfish", "name": "Anglerfish", "qty": 1}], "xp": 160, "req_lv": 50},
	{"name": "Giant's Feast",    "id": "giants_feast",     "color": Color(0.70, 0.46, 0.24), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 3}, {"id": "mushrooms", "name": "Mushrooms", "qty": 2}], "xp": 170, "req_lv": 50},
	# Lv 55+
	{"name": "Eel Stew",         "id": "eel_stew",         "color": Color(0.28, 0.45, 0.35), "skill": "cooking",
	 "input": [{"id": "abyssal_eel", "name": "Abyssal Eel", "qty": 1}], "xp": 180, "req_lv": 55},
	{"name": "Leviathan Stew",   "id": "leviathan_stew",   "color": Color(0.20, 0.46, 0.42), "skill": "cooking",
	 "input": [{"id": "leviathan_eel", "name": "Leviathan Eel", "qty": 1}], "xp": 210, "req_lv": 60},
	{"name": "Kraken Platter",   "id": "kraken_platter",   "color": Color(0.45, 0.30, 0.55), "skill": "cooking",
	 "input": [{"id": "anglerfish", "name": "Anglerfish", "qty": 1}, {"id": "raw_shark", "name": "Raw Shark", "qty": 1}], "xp": 250, "req_lv": 70},
	# Feast of Valhalla — endgame farming inclusion (2 wheat + 1 moonwheat).
	{"name": "Feast of Valhalla","id": "feast_of_valhalla","color": Color(0.95, 0.82, 0.30), "skill": "cooking",
	 "input": [{"id": "leviathan_eel", "name": "Leviathan Eel", "qty": 1}, {"id": "raw_meat", "name": "Raw Meat", "qty": 3}, {"id": "mushrooms", "name": "Mushrooms", "qty": 2}, {"id": "wheat", "name": "Wheat", "qty": 2}, {"id": "moonwheat", "name": "Moonwheat", "qty": 1}], "xp": 320, "req_lv": 80},
	# ── Pure-Farming dishes (playtest integration) — give crops their own
	# baseline cooking ladder so a farmer can level cooking with just their
	# own crop supply.
	{"name": "Wheat Bread",      "id": "wheat_bread",      "color": Color(0.88, 0.72, 0.35), "skill": "cooking",
	 "input": [{"id": "wheat", "name": "Wheat", "qty": 3}], "xp": 30, "req_lv": 3},
	{"name": "Carrot Stew",      "id": "carrot_stew",      "color": Color(0.95, 0.60, 0.25), "skill": "cooking",
	 "input": [{"id": "carrot", "name": "Carrot", "qty": 2}, {"id": "mushrooms", "name": "Mushrooms", "qty": 1}], "xp": 55, "req_lv": 18},
	{"name": "Moonwheat Loaf",   "id": "moonwheat_loaf",   "color": Color(0.82, 0.90, 1.00), "skill": "cooking",
	 "input": [{"id": "moonwheat", "name": "Moonwheat", "qty": 2}], "xp": 150, "req_lv": 45},
	# ── Farming crop dishes (1.6.2) — a basic use for every crop plus flagship
	# multi-crop dishes (salad / stew / ale / pie / cobbler / fruit bowl / wine).
	{"name": "Barley Porridge",  "id": "barley_porridge",  "color": Color(0.82, 0.74, 0.52), "skill": "cooking",
	 "input": [{"id": "barley", "name": "Barley", "qty": 2}], "xp": 24, "req_lv": 4},
	{"name": "Steamed Cabbage",  "id": "steamed_cabbage",  "color": Color(0.50, 0.75, 0.40), "skill": "cooking",
	 "input": [{"id": "cabbage", "name": "Cabbage", "qty": 2}], "xp": 26, "req_lv": 5},
	{"name": "Dark Bread",       "id": "dark_bread",       "color": Color(0.45, 0.30, 0.16), "skill": "cooking",
	 "input": [{"id": "rye", "name": "Rye", "qty": 3}], "xp": 34, "req_lv": 6},
	{"name": "Roasted Corn",     "id": "roasted_corn",     "color": Color(0.95, 0.82, 0.30), "skill": "cooking",
	 "input": [{"id": "corn", "name": "Corn", "qty": 2}], "xp": 40, "req_lv": 10},
	{"name": "Boiled Potato",    "id": "boiled_potato",    "color": Color(0.80, 0.68, 0.45), "skill": "cooking",
	 "input": [{"id": "potato", "name": "Potato", "qty": 2}], "xp": 48, "req_lv": 12},
	{"name": "Garden Salad",     "id": "garden_salad",     "color": Color(0.40, 0.72, 0.35), "skill": "cooking",
	 "input": [{"id": "cabbage", "name": "Cabbage", "qty": 1}, {"id": "tomato", "name": "Tomato", "qty": 1}, {"id": "pepper", "name": "Pepper", "qty": 1}], "xp": 70, "req_lv": 20},
	{"name": "Sweet Loaf",       "id": "sweet_loaf",       "color": Color(0.90, 0.78, 0.45), "skill": "cooking",
	 "input": [{"id": "sugarcane", "name": "Sugarcane", "qty": 2}, {"id": "wheat", "name": "Wheat", "qty": 1}], "xp": 72, "req_lv": 22},
	{"name": "Farmer's Stew",    "id": "farmers_stew",     "color": Color(0.60, 0.45, 0.28), "skill": "cooking",
	 "input": [{"id": "potato", "name": "Potato", "qty": 1}, {"id": "carrot", "name": "Carrot", "qty": 1}, {"id": "cabbage", "name": "Cabbage", "qty": 1}, {"id": "corn", "name": "Corn", "qty": 1}], "xp": 95, "req_lv": 25},
	{"name": "Frontier Ale",     "id": "ale",              "color": Color(0.80, 0.55, 0.20), "skill": "cooking",
	 "input": [{"id": "hops", "name": "Hops", "qty": 2}, {"id": "wheat", "name": "Wheat", "qty": 1}], "xp": 88, "req_lv": 28},
	{"name": "Stuffed Pepper",   "id": "stuffed_pepper",   "color": Color(0.85, 0.30, 0.22), "skill": "cooking",
	 "input": [{"id": "pepper", "name": "Pepper", "qty": 2}, {"id": "rye", "name": "Rye", "qty": 1}], "xp": 92, "req_lv": 30},
	{"name": "Melon Slice",      "id": "melon_slice",      "color": Color(0.90, 0.35, 0.40), "skill": "cooking",
	 "input": [{"id": "watermelon", "name": "Watermelon", "qty": 1}], "xp": 120, "req_lv": 40},
	{"name": "Apple Pie",        "id": "apple_pie",        "color": Color(0.85, 0.60, 0.35), "skill": "cooking",
	 "input": [{"id": "apple", "name": "Apple", "qty": 2}, {"id": "sugarcane", "name": "Sugarcane", "qty": 1}, {"id": "wheat", "name": "Wheat", "qty": 1}], "xp": 155, "req_lv": 50},
	{"name": "Berry Fruit Bowl", "id": "berry_fruit_bowl", "color": Color(0.55, 0.25, 0.55), "skill": "cooking",
	 "input": [{"id": "blueberry", "name": "Blueberry", "qty": 1}, {"id": "strawberry", "name": "Strawberry", "qty": 1}, {"id": "lingonberry", "name": "Lingonberry", "qty": 1}], "xp": 160, "req_lv": 52},
	{"name": "Peach Cobbler",    "id": "peach_cobbler",    "color": Color(0.95, 0.70, 0.45), "skill": "cooking",
	 "input": [{"id": "peach", "name": "Peach", "qty": 2}, {"id": "sugarcane", "name": "Sugarcane", "qty": 1}], "xp": 185, "req_lv": 60},
	{"name": "Fine Wine",        "id": "fine_wine",        "color": Color(0.55, 0.15, 0.35), "skill": "cooking",
	 "input": [{"id": "grape", "name": "Grape", "qty": 3}], "xp": 210, "req_lv": 65},
]

func _build_cook_window() -> void:
	_cook_window = _build_recipe_window("🔥  Campfire", _COOK_RECIPES, "cooking",
		func(r: Dictionary) -> void: _cook(r))
	# Offsets set inside the builder (viewport-capped at 80%).
	_cook_window.visible = false

func _on_open_cooking() -> void:
	_refresh_cook()
	_cook_window.visible = true
	_register_proximity_panel(_cook_window)

func _refresh_cook() -> void:
	_refresh_recipe_window(_COOK_RECIPES, "cooking", _cook_recipe_btns)

func _cook(recipe: Dictionary) -> void:
	# ⑤ Server owns the consume + grant + XP + burn roll (pushes the result).
	# NOTE: the fish-weight → bigger-heal carry (`wnorm`) is dropped under
	# server authority for now — meals heal their base amount; restoring the
	# weight-scaled bonus needs the server to track item meta (later pass).
	_request_server_craft(recipe, "cooking")
	_refresh_cook()

# ── Crafting window ───────────────────────────────────────────────────────────
## All armor and tools live under Smithing now (the user's economy rebalance
## — metalwork and toolmaking are forge-side). Wood-only tools, jewellery,
## arrows, and the items absorbed from Construction (campfire, storage crate,
## bookshelf, torch post) stay in Crafting. Every entry carries an explicit
## `skill` so the dispatcher in `_craft` doesn't fall back to a default.
const _CRAFT_RECIPES: Array = [
	# ── Wooden tools (Crafting — pure woodwork, no forge needed) ─────────────
	{"name": "Wooden Axe",          "id": "wooden_axe",          "color": Color(0.55, 0.38, 0.16), "skill": "crafting",
	 "input": [{"id": "stick", "name": "Stick", "qty": 3},
			   {"id": "stone", "name": "Stone", "qty": 2}], "xp": 5, "req_lv": 1},
	{"name": "Wooden Pickaxe",      "id": "wooden_pickaxe",      "color": Color(0.50, 0.34, 0.14), "skill": "crafting",
	 "input": [{"id": "stick", "name": "Stick", "qty": 3},
			   {"id": "stone", "name": "Stone", "qty": 2}], "xp": 5, "req_lv": 1},
	{"name": "Wooden Fishing Pole", "id": "wooden_fishing_pole", "color": Color(0.45, 0.28, 0.08), "skill": "crafting",
	 "input": [{"id": "stick", "name": "Stick", "qty": 4},
			   {"id": "herbs",  "name": "Herbs",  "qty": 1}], "xp": 5, "req_lv": 1},
	{"name": "Fishing Pole",   "id": "fishing_pole",   "color": Color(0.48, 0.30, 0.08), "skill": "crafting",
	 "input": [{"id": "oak_log", "name": "Oak Log", "qty": 3},
			   {"id": "herbs",   "name": "Herbs",   "qty": 1}], "xp": 15, "req_lv": 1},
	# ── Sea-combat consumables (1.6.3) — used in the boat-combat modal; run out
	# and the action nulls with a "craft more" toast.
	{"name": "Hull Patch",     "id": "hull_patch",     "color": Color(0.60, 0.45, 0.25), "skill": "crafting",
	 "input": [{"id": "oak_log",  "name": "Oak Log",  "qty": 2},
			   {"id": "iron_bar", "name": "Iron Bar", "qty": 1}], "xp": 20, "req_lv": 1},
	{"name": "Fishing Net",    "id": "fishing_net",    "color": Color(0.75, 0.72, 0.55), "skill": "crafting",
	 "input": [{"id": "herbs", "name": "Herbs", "qty": 3},
			   {"id": "stick", "name": "Stick", "qty": 2}], "xp": 18, "req_lv": 1},
	{"name": "Chum Bucket",    "id": "chum_bucket",    "color": Color(0.52, 0.40, 0.30), "skill": "crafting",
	 "input": [{"id": "raw_fish", "name": "Raw Fish", "qty": 2}], "xp": 15, "req_lv": 1},

	# ── Metal tools & weapons (Smithing — bar + matching wood handle) ────────
	{"name": "Copper Axe",     "id": "copper_axe",     "color": Color(0.78, 0.48, 0.22), "skill": "smithing",
	 "input": [{"id": "copper_bar", "name": "Copper Bar", "qty": 1},
			   {"id": "oak_log",    "name": "Oak Log",    "qty": 2}], "xp": 40, "req_lv": 1},
	{"name": "Copper Pickaxe", "id": "copper_pickaxe", "color": Color(0.72, 0.44, 0.18), "skill": "smithing",
	 "input": [{"id": "copper_bar", "name": "Copper Bar", "qty": 2},
			   {"id": "oak_log",    "name": "Oak Log",    "qty": 1},
			   {"id": "stick",      "name": "Stick",      "qty": 2}], "xp": 40, "req_lv": 1},
	{"name": "Iron Axe",       "id": "iron_axe",       "color": Color(0.55, 0.55, 0.60), "skill": "smithing",
	 "input": [{"id": "iron_bar", "name": "Iron Bar", "qty": 1},
			   {"id": "oak_log",  "name": "Oak Log",  "qty": 2}], "xp": 75, "req_lv": 5},
	{"name": "Iron Pickaxe",   "id": "iron_pickaxe",   "color": Color(0.50, 0.50, 0.55), "skill": "smithing",
	 "input": [{"id": "iron_bar",     "name": "Iron Bar",     "qty": 2},
			   {"id": "oak_log",      "name": "Oak Log",      "qty": 1},
			   {"id": "stick",        "name": "Stick",        "qty": 2}], "xp": 75,  "req_lv": 10},
	{"name": "Ironwood Bow",   "id": "ironwood_bow",   "color": Color(0.28, 0.14, 0.06), "skill": "smithing",
	 "input": [{"id": "ironwood_log", "name": "Ironwood Log", "qty": 2},
			   {"id": "stick",        "name": "Stick",        "qty": 3}], "xp": 90,  "req_lv": 20},
	{"name": "Mithril Sword",  "id": "mithril_sword",  "color": Color(0.40, 0.65, 0.90), "skill": "smithing",
	 "input": [{"id": "mithril_bar",  "name": "Mithril Bar",  "qty": 1},
			   {"id": "cherry_log",   "name": "Cherry Log",   "qty": 1}],              "xp": 140, "req_lv": 50},
	{"name": "Adamant Axe",    "id": "adamant_axe",    "color": Color(0.20, 0.65, 0.30), "skill": "smithing",
	 "input": [{"id": "adamant_bar",  "name": "Adamant Bar",  "qty": 1},
			   {"id": "pine_log",     "name": "Pine Log",     "qty": 2}],              "xp": 165, "req_lv": 70},
	{"name": "Runite Pickaxe", "id": "runite_pickaxe", "color": Color(0.65, 0.20, 0.82), "skill": "smithing",
	 "input": [{"id": "runite_bar",   "name": "Runite Bar",   "qty": 2},
			   {"id": "frost_log",    "name": "Frost Log",    "qty": 1},
			   {"id": "stick",        "name": "Stick",        "qty": 2}], "xp": 190, "req_lv": 85},
	# Mid-tier pickaxes — were missing (only copper/iron/runite existed).
	# Gate on the smithing level where the matching bar becomes available.
	{"name": "Gold Pickaxe",    "id": "gold_pickaxe",    "color": Color(0.95, 0.82, 0.18), "skill": "smithing",
	 "input": [{"id": "gold_bar",    "name": "Gold Bar",    "qty": 2},
			   {"id": "cherry_log",  "name": "Cherry Log",  "qty": 1},
			   {"id": "stick",       "name": "Stick",       "qty": 2}], "xp": 110, "req_lv": 30},
	{"name": "Mithril Pickaxe", "id": "mithril_pickaxe", "color": Color(0.40, 0.65, 0.90), "skill": "smithing",
	 "input": [{"id": "mithril_bar", "name": "Mithril Bar", "qty": 2},
			   {"id": "ironwood_log","name": "Ironwood Log","qty": 1},
			   {"id": "stick",       "name": "Stick",       "qty": 2}], "xp": 140, "req_lv": 50},
	{"name": "Adamant Pickaxe", "id": "adamant_pickaxe", "color": Color(0.20, 0.65, 0.30), "skill": "smithing",
	 "input": [{"id": "adamant_bar", "name": "Adamant Bar", "qty": 2},
			   {"id": "pine_log",    "name": "Pine Log",    "qty": 1},
			   {"id": "stick",       "name": "Stick",       "qty": 2}], "xp": 165, "req_lv": 70},

	# ── Jewellery (Crafting — metalwork that's adornment, not tools) ─────────
	# Gold Amulet — jewelry, so it lives under Jewelcrafting now (was crafting).
	{"name": "Gold Amulet",    "id": "gold_amulet",    "color": Color(0.95, 0.80, 0.15), "skill": "jewelcrafting",
	 "input": [{"id": "gold_bar",     "name": "Gold Bar",     "qty": 2}],              "xp": 110, "req_lv": 20},

	# ── Absorbed-from-Construction (small items / cooking fire / furniture) ──
	# These were previously generated per-tier in _BUILDABLES. Moved to a
	# single canonical recipe each — they're inventory items, not warband
	# structures, so a six-tier ladder for "campfire" was overkill.
	{"name": "Campfire",       "id": "campfire",       "color": Color(0.85, 0.45, 0.10), "skill": "crafting",
	 "input": [{"id": "oak_log", "name": "Oak Log", "qty": 3},
			   {"id": "stick",   "name": "Stick",   "qty": 3}], "xp": 25, "req_lv": 1},
	{"name": "Storage Crate",  "id": "storage_crate",  "color": Color(0.55, 0.38, 0.16), "skill": "crafting",
	 "input": [{"id": "oak_log", "name": "Oak Log", "qty": 5},
			   {"id": "stick",   "name": "Stick",   "qty": 4}], "xp": 35, "req_lv": 1},
	{"name": "Torch Post",     "id": "torch_post",     "color": Color(0.65, 0.40, 0.15), "skill": "crafting",
	 "input": [{"id": "stick", "name": "Stick", "qty": 4},
			   {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 18, "req_lv": 1},
	{"name": "Bookshelf",      "id": "bookshelf",      "color": Color(0.42, 0.28, 0.14), "skill": "crafting",
	 "input": [{"id": "oak_log", "name": "Oak Log", "qty": 6},
			   {"id": "stick",   "name": "Stick",   "qty": 3}], "xp": 70, "req_lv": 20},
]

var _all_craft_recipes: Array = []
## Smithing-only slice of `_build_all_craft_recipes()` — weapons + armor +
## shields. Lives in its own window opened from the Forge so the Crafting
## Bench isn't cluttered with metal gear the smithing skill ought to own.
var _smith_gear_recipes: Array = []
var _smith_gear_window: PanelContainer = null
# Jewelcrafting (Phase 1) — its own window, opened from the crafting bench's
# Jewelcraft action. Gem jewelry recipes (skill == "jewelcrafting").
var _jewel_recipes: Array = []
var _jewel_window: PanelContainer = null
var _jewel_recipe_btns: Array[Button] = []
var _smith_gear_recipe_btns: Array[Button] = []

func _build_craft_window() -> void:
	# Playtest split — Crafting Bench shows ONLY crafting-skill recipes
	# (wooden tools, jewelry, arrows, campfire, etc.). Smithing-skill gear
	# lives in a separate window opened from the Forge.
	var all: Array = _build_all_craft_recipes()
	_all_craft_recipes = all.filter(func(r: Dictionary) -> bool:
		return str(r.get("skill", "crafting")) == "crafting")
	_smith_gear_recipes = all.filter(func(r: Dictionary) -> bool:
		return str(r.get("skill", "crafting")) == "smithing")
	_craft_window = _build_recipe_window("💎  Crafting", _all_craft_recipes, "crafting",
		func(r: Dictionary) -> void: _craft(r))
	_craft_window.visible = false
	# The smithing-gear window uses the same builder + tabs but its own
	# button list so refresh doesn't collide with the bench window.
	var prev_btns := _craft_recipe_btns
	_craft_recipe_btns = []
	_smith_gear_window = _build_recipe_window("⚔  Weapons & Armor",
		_smith_gear_recipes, "smithing",
		func(r: Dictionary) -> void: _craft(r))
	_smith_gear_window.visible = false
	_smith_gear_recipe_btns = _craft_recipe_btns
	# Jewelcrafting window — same transfer-var pattern.
	_jewel_recipes = all.filter(func(r: Dictionary) -> bool:
		return str(r.get("skill", "crafting")) == "jewelcrafting")
	_craft_recipe_btns = []
	_jewel_window = _build_recipe_window("💍  Jewelcrafting",
		_jewel_recipes, "jewelcrafting",
		func(r: Dictionary) -> void: _craft(r))
	_jewel_window.visible = false
	_jewel_recipe_btns = _craft_recipe_btns
	_craft_recipe_btns = prev_btns

func _refresh_craft() -> void:
	_refresh_recipe_window(_all_craft_recipes, "crafting", _craft_recipe_btns)
	if _smith_gear_window != null:
		_refresh_recipe_window(_smith_gear_recipes, "smithing", _smith_gear_recipe_btns)
	if _jewel_window != null:
		_refresh_recipe_window(_jewel_recipes, "jewelcrafting", _jewel_recipe_btns)

## Open the Jewelcrafting window (from the crafting bench's Jewelcraft action).
func open_jewelcrafting() -> void:
	if _jewel_window == null:
		return
	_refresh_craft()
	_jewel_window.visible = true
	_register_proximity_panel(_jewel_window)

# ── Autoplay craft hooks (in-client AI makes PURPOSEFUL items) ────────────────
# The craft "list key": what the AI actually wants to make, IN ORDER. Tools first
# (so it can gather at all), then a fishing pole, then metal tool upgrades. Beyond
# this list it only crafts equippable GEAR UPGRADES — never random items.
const _AUTOPLAY_CRAFT_PRIORITY := [
	"wooden_axe", "wooden_pickaxe", "wooden_fishing_pole",
	"copper_axe", "copper_pickaxe", "iron_axe", "iron_pickaxe",
]

func _autoplay_owns(item_id: String) -> bool:
	return GameManager.get_item_qty(item_id) >= 1 \
		or item_id in GameManager.equipment.values()

func _autoplay_can_make(recipe: Dictionary) -> bool:
	for ing: Variant in recipe["input"] as Array:
		if GameManager.get_item_qty((ing as Dictionary)["id"] as String) \
				< int((ing as Dictionary)["qty"]):
			return false
	return true

func _autoplay_recipe_by_id(item_id: String) -> Dictionary:
	for r: Variant in _all_craft_recipes:
		if str((r as Dictionary)["id"]) == item_id:
			return r as Dictionary
	return {}

## The next thing worth crafting: priority list first (tools → pole → metal tools),
## then any equippable gear that would be an UPGRADE. {} = craft nothing (don't
## waste materials on random junk).
func _autoplay_next_recipe() -> Dictionary:
	for want: Variant in _AUTOPLAY_CRAFT_PRIORITY:
		var recipe := _autoplay_recipe_by_id(str(want))
		if not recipe.is_empty() and not _autoplay_owns(str(want)) and _autoplay_can_make(recipe):
			return recipe
	for r: Variant in _all_craft_recipes:
		var recipe := r as Dictionary
		var rid := str(recipe["id"])
		if _autoplay_owns(rid) or not _autoplay_can_make(recipe):
			continue
		if GameManager.autoplay_is_gear_upgrade(rid):
			return recipe
	return {}

func autoplay_can_craft() -> bool:
	return not _autoplay_next_recipe().is_empty()

var _autoplay_crafting: bool = false
var _autoplay_banking: bool = false
var _autoplay_cooking: bool = false
var _autoplay_seq_at: float = 0.0   # when the current UI sequence began (failsafe)
## True while a visible craft / bank / cook sequence is playing (AutoPlay waits).
func autoplay_busy() -> bool:
	return _autoplay_crafting or _autoplay_banking or _autoplay_cooking

## FAILSAFE: if a UI sequence's await chain ever hangs (freed timer / scene swap),
## the window would stay open forever and the bot would freeze. If we've been
## "busy" too long, force every autoplay window shut and clear the flags so the AI
## recovers. (Fixes the "a UI screen was still up past crafting" bad recordings.)
func _autoplay_ui_failsafe() -> void:
	if not autoplay_busy():
		return
	var t := float(Time.get_ticks_msec()) / 1000.0
	if _autoplay_seq_at <= 0.0:
		_autoplay_seq_at = t
		return
	if t - _autoplay_seq_at > 14.0:
		_autoplay_crafting = false
		_autoplay_banking = false
		_autoplay_cooking = false
		_autoplay_seq_at = 0.0
		if _craft_window != null: _craft_window.visible = false
		if _bank_window != null:  _bank_window.visible = false
		if _cook_window != null:  _cook_window.visible = false

# ── Autoplay cooking (turn raw food into eatable cooked food, on camera) ───────
func _autoplay_raw_food_count() -> int:
	var n := 0
	for item: Dictionary in GameManager.inventory:
		if str(item["id"]).begins_with("raw_"):
			n += int(item["qty"])
	return n

## Enough raw food piled up (≥5) to bother cooking a batch at a fire?
func autoplay_should_cook() -> bool:
	return _autoplay_raw_food_count() >= 5

## Cook the raw food VISIBLY at the campfire: open the cook window, cook a batch,
## close. Cooked food is the eat item (kept for fights; surplus banked). Async.
func autoplay_cook_sequence() -> bool:
	if _autoplay_cooking:
		return true
	if not autoplay_should_cook():
		return false
	_autoplay_cooking = true
	_autoplay_seq_at = float(Time.get_ticks_msec()) / 1000.0
	_run_autoplay_cook()
	return true

func _run_autoplay_cook() -> void:
	Events.open_cooking.emit()
	if _cook_window != null:
		_cook_window.visible = true
	await get_tree().create_timer(1.2).timeout
	var made := 0
	for r: Variant in _COOK_RECIPES:
		var recipe := r as Dictionary
		while made < 10 and _autoplay_can_make(recipe) and GameManager.free_slots() >= 0:
			_craft(recipe)                 # raw → cooked (+cooking XP), real inventory
			made += 1
			await get_tree().create_timer(0.5).timeout
	if _cook_window != null:
		_cook_window.visible = false
	_autoplay_cooking = false

## Bank like a real player, VISIBLY: open the bank, dwell, deposit the surplus
## (keeping tools), linger, then close. Async; AutoPlay gates on autoplay_busy().
func autoplay_bank_sequence() -> bool:
	if _autoplay_banking:
		return true
	_autoplay_banking = true
	_autoplay_seq_at = float(Time.get_ticks_msec()) / 1000.0
	_run_autoplay_bank()
	return true

func _run_autoplay_bank() -> void:
	Events.open_bank.emit()
	if _bank_window != null:
		_bank_window.visible = true
		_refresh_bank()
	await get_tree().create_timer(1.3).timeout
	GameManager.autoplay_deposit_surplus()      # items slide into the bank on camera
	if _bank_window != null:
		_refresh_bank()
	await get_tree().create_timer(1.6).timeout
	if _bank_window != null:
		_bank_window.visible = false
	_autoplay_banking = false

## Craft like a REAL player would, VISIBLY: open the crafting window, dwell on it,
## highlight + "click" the recipe (the item lands in the bag on camera), linger on
## the result, then CLOSE the window. Crafting itself is instant in-game, so the
## dwell timers are what make it read as a real crafting action. Async; returns
## immediately after kicking off. AutoPlay gates on `autoplay_busy()`.
func autoplay_craft_sequence() -> bool:
	if _autoplay_crafting:
		return true
	var recipe := _autoplay_next_recipe()
	if recipe.is_empty():
		return false
	_autoplay_crafting = true
	_autoplay_seq_at = float(Time.get_ticks_msec()) / 1000.0
	_run_autoplay_craft(recipe)
	return true

func _run_autoplay_craft(recipe: Dictionary) -> void:
	Events.open_crafting.emit()                 # open the crafting screen
	if _craft_window != null:
		_craft_window.visible = true
	await get_tree().create_timer(1.4).timeout  # look over the recipes
	_craft(recipe)                              # make it — item lands in the bag (+XP)
	_refresh_craft()                            # the window updates on camera
	await get_tree().create_timer(1.8).timeout  # admire the result
	if _craft_window != null:
		_craft_window.visible = false           # close the window, done
	_autoplay_crafting = false

func _craft(recipe: Dictionary) -> void:
	# ⑤ Server owns the consume + grant + XP + burn roll (pushes the result).
	# Each recipe carries its own `skill` (crafting / smithing / jewelcrafting).
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
			return
	_request_server_craft(recipe, str(recipe.get("skill", "crafting")))
	_refresh_craft()

# ══════════════════════════════════════════════════════════════════════════════
# TIMED BATCH ORCHESTRATION — Track 2 of the cooking/farming pass
# ══════════════════════════════════════════════════════════════════════════════

## Per-recipe base cook/smelt time. `req_lv` sets a tier-derived floor;
## skill level then scales it down. Crafting stays instant (returns 0.0
## so `_start_batch_craft` shortcuts to per-tick immediate processing).
func _recipe_time_sec(recipe: Dictionary, skill: String) -> float:
	if skill == "crafting":
		return 0.0
	var req_lv: int = int(recipe.get("req_lv", 1))
	@warning_ignore("integer_division")
	var tier_steps: int = req_lv / 10
	var base_time: float = 2.0 + float(tier_steps) * 1.5
	var lv: int = GameManager.get_skill_level(skill)
	var factor: float = clampf(1.0 - float(lv - req_lv) * 0.008, 0.4, 1.0)
	return base_time * factor

## Per-recipe success chance for Cook / Smith / Farming.
## base 0.60 at req_lv → +0.35 at req_lv+40 → clamped [0.15, 0.99]
## Practice bonus from recipe_success_counts (every 100 → +5%, cap +30%).
## ⑤ NOTE: the SERVER now rolls burn (server.py `_craft_success_chance` mirrors
## this BASE curve, minus the client-only practice bonus). Kept as the reference
## the server mirrors + still used to display odds if a UI needs them.
func _recipe_success_chance(recipe: Dictionary, skill: String) -> float:
	if skill == "crafting":
		return 1.0
	var req_lv: int = int(recipe.get("req_lv", 1))
	var lv: int = GameManager.get_skill_level(skill)
	var base: float = 0.60 + clampf(float(lv - req_lv) / 40.0, 0.0, 0.35)
	var practice: float = GameManager.practice_bonus_for(str(recipe["id"]))
	return clampf(base + practice, 0.15, 0.99)

## Kick off a batched craft. Fires immediately if crafting; otherwise
## arms `_active_craft` and lets `_tick_active_craft` drive it. Lockout:
## every OTHER recipe's button is disabled while this batch runs.
func _start_batch_craft(recipe: Dictionary, qty: int, skill: String,
		single_action: Callable, btn: Button, spin: SpinBox) -> void:
	if not _active_craft.is_empty():
		Events.chat_message.emit("Finish or cancel the current cook first.")
		return
	if qty <= 0:
		return
	# Ingredient stock check — cap qty to what the player can actually
	# afford so a "cook 100" with 3 fish doesn't lock up and refuse.
	var max_qty: int = qty
	for ing: Dictionary in recipe["input"] as Array:
		var have: int = GameManager.get_item_qty(ing["id"] as String)
		var need_per: int = int(ing["qty"])
		if need_per > 0:
			@warning_ignore("integer_division")
			var afford := have / need_per   # whole batches only — floor is intended
			max_qty = mini(max_qty, afford)
	if max_qty <= 0:
		Events.chat_message.emit("Not enough ingredients.")
		return
	var tier_lv: int = int(recipe.get("req_lv", 1))
	if GameManager.get_skill_level(skill) < tier_lv:
		Events.chat_message.emit("Requires %s Lv %d." % [
			skill.capitalize(), tier_lv])
		return
	# Crafting fast-path — never times, always succeeds. Just loop the
	# existing single-action call and refresh.
	if skill == "crafting":
		for _i in range(max_qty):
			single_action.call(recipe)
			GameManager.bump_recipe_count(str(recipe["id"]))
		return
	var tick_dur: float = _recipe_time_sec(recipe, skill)
	var card_variant: Variant = _recipe_card_index.get(str(recipe["id"]), null)
	if card_variant == null:
		return
	var card := card_variant as PanelContainer
	var prog_row := card.get_meta("prog_row") as HBoxContainer
	var prog_bar := card.get_meta("prog_bar") as ProgressBar
	var verb := str(card.get_meta("verb", "Cook"))
	_active_craft = {
		"recipe_id":     str(recipe["id"]),
		"recipe":        recipe,
		"qty":           max_qty,
		"remaining":     max_qty,
		"tick_left":     tick_dur,
		"tick_dur":      tick_dur,
		"card":          card,
		"prog_bar":      prog_bar,
		"prog_row":      prog_row,
		"btn":           btn,
		"qty_spin":      spin,
		"verb":          verb,
		"skill":         skill,
		"single_action": single_action,
	}
	prog_row.visible = true
	prog_bar.value = 0.0
	btn.text = "%s… 1/%d" % [verb, max_qty]
	spin.editable = false
	_refresh_all_recipe_cards()
	# Spawn the idle minigame overlay so the player has something to do
	# while the batch runs — but only when the batch is actually worth it:
	# 5+ items OR a total wait of at least 30s. Trivial one-off jobs skip it.
	# (Optional either way — closing it doesn't affect the timer.)
	var total_wait := float(max_qty) * tick_dur
	if max_qty >= 5 or total_wait >= 30.0:
		_spawn_craft_minigame(skill)

## Only one active minigame at a time. Reuses the existing instance if
## still alive; otherwise spawns a fresh CanvasLayer child.
var _craft_minigame_node: Node = null
func _spawn_craft_minigame(skill: String) -> void:
	if _craft_minigame_node != null and is_instance_valid(_craft_minigame_node):
		return
	var scr := load("res://scripts/ui/CraftMinigame.gd") as GDScript
	if scr == null:
		return
	# `scr.new()` returns Variant under strict mode — annotate as
	# CanvasLayer (CraftMinigame extends CanvasLayer) so the compiler
	# stops inferring Variant + treating it as a warning-as-error.
	var mg: CanvasLayer = scr.new() as CanvasLayer
	if mg == null:
		return
	if mg.has_method("set_skill"):
		mg.call("set_skill", skill)
	add_child(mg)
	_craft_minigame_node = mg

func _tick_active_craft(delta: float) -> void:
	if _active_craft.is_empty():
		return
	var tick_left: float = float(_active_craft.get("tick_left", 0.0))
	var tick_dur: float = float(_active_craft.get("tick_dur", 1.0))
	tick_left -= delta
	_active_craft["tick_left"] = tick_left
	var prog_bar := _active_craft.get("prog_bar") as ProgressBar
	if prog_bar != null and tick_dur > 0.0:
		prog_bar.value = 1.0 - clampf(tick_left / tick_dur, 0.0, 1.0)
	if tick_left > 0.0:
		return
	# ⑤ Produce one item. The SERVER now owns the success/burn roll, the
	# material consume, the grant, and the XP — `single_action` fires a `craft`
	# request and the authoritative result is pushed back (admin_inventory_set +
	# craft_result). The old client-side burn roll is gone so the two can't
	# disagree; this tick only paces the batch + guards the client mirror.
	var recipe: Dictionary = _active_craft["recipe"]
	var skill := str(_active_craft["skill"])
	var single_action: Callable = _active_craft["single_action"]
	# Ingredient stock double-check against the (server-synced) client mirror —
	# stop the batch early rather than firing requests the server will reject.
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < int(ing["qty"]):
			Events.chat_message.emit("Ran out of ingredients.")
			_cancel_active_craft()
			return
	single_action.call(recipe)
	GameManager.bump_recipe_count(str(recipe["id"]))
	var remaining: int = int(_active_craft.get("remaining", 0)) - 1
	_active_craft["remaining"] = remaining
	if remaining <= 0:
		_finish_active_craft()
		return
	# Roll next tick — recompute duration in case level ticked up mid-batch.
	var next_dur: float = _recipe_time_sec(recipe, skill)
	_active_craft["tick_dur"] = next_dur
	_active_craft["tick_left"] = next_dur
	if prog_bar != null:
		prog_bar.value = 0.0
	var btn := _active_craft.get("btn") as Button
	var qty: int = int(_active_craft.get("qty", 1))
	var verb := str(_active_craft.get("verb", "Cook"))
	if btn != null:
		btn.text = "%s… %d/%d" % [verb, qty - remaining + 1, qty]

func _finish_active_craft() -> void:
	if _active_craft.is_empty():
		return
	var prog_row := _active_craft.get("prog_row") as HBoxContainer
	if prog_row != null:
		prog_row.visible = false
	var btn := _active_craft.get("btn") as Button
	var qty_spin := _active_craft.get("qty_spin") as SpinBox
	var verb := str(_active_craft.get("verb", "Cook"))
	if btn != null and qty_spin != null:
		btn.text = "%s %d" % [verb, int(qty_spin.value)]
	if qty_spin != null:
		qty_spin.editable = true
	_active_craft = {}
	_refresh_all_recipe_cards()
	# Auto-close the minigame overlay so it doesn't linger past the
	# batch it was spawned for. Player can start another batch to
	# open a fresh one.
	if _craft_minigame_node != null and is_instance_valid(_craft_minigame_node):
		_craft_minigame_node.queue_free()
	_craft_minigame_node = null

## Idle-minigame reward — trim the current item's tick_left + grant a
## small bonus XP in the active skill. Applied even mid-tick so a burst
## of rounds during a single 20-s Feast visibly speeds the bar forward.
func _on_craft_minigame_completed(speed_frac: float, bonus_xp: int) -> void:
	if _active_craft.is_empty():
		return
	var tick_dur: float = float(_active_craft.get("tick_dur", 1.0))
	var tick_left: float = float(_active_craft.get("tick_left", 0.0))
	_active_craft["tick_left"] = maxf(0.0, tick_left - tick_dur * speed_frac)
	var skill := str(_active_craft.get("skill", ""))
	if skill != "" and bonus_xp > 0:
		GameManager.add_xp(skill, bonus_xp)

func _cancel_active_craft() -> void:
	if _active_craft.is_empty():
		return
	Events.chat_message.emit("Batch cancelled.")
	_finish_active_craft()

## Walks every registered recipe card. If a batch is running, every card
## except the running one has its button disabled; when nothing is
## running, buttons re-enable per their normal ingredient gate.
func _refresh_all_recipe_cards() -> void:
	var active_id: String = str(_active_craft.get("recipe_id", ""))
	for rid_v: Variant in _recipe_card_index.keys():
		var rid: String = str(rid_v)
		var card := _recipe_card_index[rid] as PanelContainer
		if card == null:
			continue
		var btn := card.get_meta("craft_btn") as Button
		var spin := card.get_meta("qty_spin") as SpinBox
		if btn == null:
			continue
		if active_id != "" and rid != active_id:
			btn.disabled = true
			if spin != null:
				spin.editable = false
		else:
			# Re-enable the quantity box on non-active cards. Without this,
			# a spin locked during ANOTHER card's batch never came back
			# (only the active card's spin was restored in _finish_active_craft),
			# so those boxes stayed stuck at 1. Button enabling is still owned
			# by the per-window ingredient-gate refreshers below.
			if spin != null:
				spin.editable = true
		# The per-window refresh functions (_refresh_cook, _refresh_craft,
		# etc.) still own ingredient-gate enabling; this just applies the
		# batch-active lockout on top.

## Tools (from _CRAFT_RECIPES) + generated armour / weapon / jewellery tiers.
## Item ids follow the "{tier}_{piece}" convention so GearDB.def_for derives stats.
func _build_all_craft_recipes() -> Array:
	var out: Array = _CRAFT_RECIPES.duplicate(true)

	# Leather armour — Crafting skill (per the playtest "leather doesn't belong
	# at the forge" pass). Metal armours stay on Smithing below; leather is
	# stitched, not smithed, so it lives at the Crafting Bench.
	var leather: Array = [["helm", 2], ["body", 3], ["legs", 3], ["gloves", 1], ["boots", 1], ["shield", 2]]
	for p: Array in leather:
		var piece := p[0] as String
		var amt := p[1] as int
		out.append({"name": "Leather %s" % piece.capitalize(), "id": "leather_%s" % piece,
			"color": Color(0.45, 0.30, 0.14), "skill": "crafting",
			"input": [{"id": "wolf_pelt", "name": "Wolf Pelt", "qty": amt}],
			"xp": 20 + amt * 5, "req_lv": 1})

	# Metal tiers: bar id/name, smithing req level, sprite colour, weapon log
	var tiers: Array = [
		{"t": "copper",  "bar": "copper_bar",  "bn": "Copper Bar",  "req": 1,  "col": Color(0.82, 0.52, 0.22), "log": ["oak_log", "Oak Log"]},
		{"t": "iron",    "bar": "iron_bar",    "bn": "Iron Bar",    "req": 15, "col": Color(0.62, 0.62, 0.68), "log": ["pine_log", "Pine Log"]},
		{"t": "gold",    "bar": "gold_bar",    "bn": "Gold Bar",    "req": 30, "col": Color(0.95, 0.82, 0.18), "log": ["cherry_log", "Cherry Log"]},
		{"t": "mithril", "bar": "mithril_bar", "bn": "Mithril Bar", "req": 50, "col": Color(0.45, 0.72, 0.92), "log": ["ironwood_log", "Ironwood Log"]},
		{"t": "adamant", "bar": "adamant_bar", "bn": "Adamant Bar", "req": 70, "col": Color(0.24, 0.70, 0.38), "log": ["frost_log", "Frost Log"]},
		{"t": "runite",  "bar": "runite_bar",  "bn": "Runite Bar",  "req": 85, "col": Color(0.72, 0.28, 0.90), "log": ["ancient_log", "Ancient Log"]},
	]
	var armour: Array = [["helm", 3], ["body", 5], ["legs", 4], ["gloves", 2], ["boots", 2], ["shield", 4]]
	var weapons: Array = ["sword", "battleaxe", "mace", "bow", "staff"]
	for tier: Dictionary in tiers:
		var tname := (tier["t"] as String).capitalize()
		# Armour set (Smithing)
		for p: Array in armour:
			var piece := p[0] as String
			var amt := p[1] as int
			out.append({"name": "%s %s" % [tname, piece.capitalize()], "id": "%s_%s" % [tier["t"], piece],
				"color": tier["col"], "skill": "smithing",
				"input": [{"id": tier["bar"], "name": tier["bn"], "qty": amt}],
				"xp": (tier["req"] as int) * 2 + amt * 8, "req_lv": tier["req"]})
		# Weapons (Smithing): bars + matching log
		for w: String in weapons:
			var bars := 1 if w == "bow" else 2
			var logs := 2 if w == "bow" else 1
			out.append({"name": "%s %s" % [tname, w.capitalize()], "id": "%s_%s" % [tier["t"], w],
				"color": tier["col"], "skill": "smithing",
				"input": [{"id": tier["bar"], "name": tier["bn"], "qty": bars},
						  {"id": (tier["log"] as Array)[0], "name": (tier["log"] as Array)[1], "qty": logs}],
				"xp": (tier["req"] as int) * 2 + 20, "req_lv": tier["req"]})
		# (Rings/amulets are no longer metal-tier crafting recipes — they moved
		# to the gem-based Jewelcrafting skill below.)

	# ── Dragon tier (Phase 1) — craftable but HARD. Every piece needs a rare
	# Dragon Scale (Nidhögg / dragon boss drop) plus runite bars, a diamond,
	# and ancient logs for weapons. Top-tier smithing (req 90). The WEAR
	# requirement (85-99) comes from the dragon tier band in def_for.
	var _dc := Color(0.75, 0.18, 0.15)
	var _ds := {"id": "dragon_scale", "name": "Dragon Scale", "qty": 1}
	var dragon_recipes: Array = [
		["Dragon Helm",      "dragon_helm",   [_ds, {"id":"runite_bar","name":"Runite Bar","qty":2}, {"id":"diamond","name":"Diamond","qty":1}], 300],
		["Dragon Body",      "dragon_body",   [{"id":"dragon_scale","name":"Dragon Scale","qty":2}, {"id":"runite_bar","name":"Runite Bar","qty":4}, {"id":"diamond","name":"Diamond","qty":2}], 380],
		["Dragon Legs",      "dragon_legs",   [_ds, {"id":"runite_bar","name":"Runite Bar","qty":3}, {"id":"diamond","name":"Diamond","qty":1}], 340],
		["Dragon Gloves",    "dragon_gloves", [_ds, {"id":"runite_bar","name":"Runite Bar","qty":1}], 240],
		["Dragon Boots",     "dragon_boots",  [_ds, {"id":"runite_bar","name":"Runite Bar","qty":2}], 260],
		["Dragon Shield",    "dragon_shield", [_ds, {"id":"runite_bar","name":"Runite Bar","qty":3}, {"id":"diamond","name":"Diamond","qty":1}], 340],
		["Dragon Sword",     "dragon_sword",     [_ds, {"id":"runite_bar","name":"Runite Bar","qty":3}, {"id":"diamond","name":"Diamond","qty":1}, {"id":"ancient_log","name":"Ancient Log","qty":1}], 360],
		["Dragon Battleaxe", "dragon_battleaxe", [_ds, {"id":"runite_bar","name":"Runite Bar","qty":4}, {"id":"diamond","name":"Diamond","qty":1}, {"id":"ancient_log","name":"Ancient Log","qty":1}], 380],
		["Dragon Mace",      "dragon_mace",      [_ds, {"id":"runite_bar","name":"Runite Bar","qty":3}, {"id":"ancient_log","name":"Ancient Log","qty":1}], 350],
		["Dragon Bow",       "dragon_bow",       [_ds, {"id":"runite_bar","name":"Runite Bar","qty":2}, {"id":"ancient_log","name":"Ancient Log","qty":2}], 350],
		["Dragon Staff",     "dragon_staff",     [_ds, {"id":"runite_bar","name":"Runite Bar","qty":2}, {"id":"diamond","name":"Diamond","qty":1}, {"id":"ancient_log","name":"Ancient Log","qty":1}], 350],
	]
	for dr: Array in dragon_recipes:
		out.append({"name": dr[0], "id": dr[1], "color": _dc, "skill": "smithing",
			"input": dr[2], "xp": int(dr[3]), "req_lv": 90})

	# ── Jewelcrafting (Phase 1) — gold bar + gem → ring/amulet. Three gems:
	# opal (low) → amethyst (mid) → diamond (high). Gated by jewelcrafting
	# level; surfaced in the Jewelcrafting window.
	var _opal_col := Color(0.82, 0.90, 0.95)
	var _ame_col  := Color(0.62, 0.38, 0.85)
	var _dia_col  := Color(0.85, 0.95, 1.00)
	out.append({"name": "Opal Ring", "id": "opal_ring", "color": _opal_col, "skill": "jewelcrafting",
		"input": [{"id": "gold_bar", "name": "Gold Bar", "qty": 1}, {"id": "opal", "name": "Opal", "qty": 1}],
		"xp": 30, "req_lv": 1})
	out.append({"name": "Opal Amulet", "id": "opal_amulet", "color": _opal_col, "skill": "jewelcrafting",
		"input": [{"id": "gold_bar", "name": "Gold Bar", "qty": 1}, {"id": "opal", "name": "Opal", "qty": 1}],
		"xp": 40, "req_lv": 10})
	out.append({"name": "Amethyst Ring", "id": "amethyst_ring", "color": _ame_col, "skill": "jewelcrafting",
		"input": [{"id": "gold_bar", "name": "Gold Bar", "qty": 1}, {"id": "amethyst", "name": "Amethyst", "qty": 1}],
		"xp": 90, "req_lv": 30})
	out.append({"name": "Amethyst Amulet", "id": "amethyst_amulet", "color": _ame_col, "skill": "jewelcrafting",
		"input": [{"id": "gold_bar", "name": "Gold Bar", "qty": 2}, {"id": "amethyst", "name": "Amethyst", "qty": 1}],
		"xp": 110, "req_lv": 40})
	out.append({"name": "Diamond Ring", "id": "diamond_ring", "color": _dia_col, "skill": "jewelcrafting",
		"input": [{"id": "gold_bar", "name": "Gold Bar", "qty": 2}, {"id": "diamond", "name": "Diamond", "qty": 1}],
		"xp": 180, "req_lv": 65})
	out.append({"name": "Diamond Amulet", "id": "diamond_amulet", "color": _dia_col, "skill": "jewelcrafting",
		"input": [{"id": "gold_bar", "name": "Gold Bar", "qty": 2}, {"id": "diamond", "name": "Diamond", "qty": 1}],
		"xp": 220, "req_lv": 75})

	# Arrows (Crafting): sticks + feathers + a metal tip → a stack
	out.append({"name": "Arrows", "id": "arrows", "color": Color(0.62, 0.62, 0.64), "skill": "crafting",
		"input": [{"id": "stick", "name": "Stick", "qty": 4}, {"id": "feather", "name": "Feather", "qty": 4},
				  {"id": "copper_bar", "name": "Copper Bar", "qty": 1}],
		"xp": 15, "req_lv": 1, "out_qty": 12})

	# Keep first recipe per id so hand-tuned originals (mithril_sword, gold_amulet,
	# ironwood_bow, tool axes) win over any generated duplicate.
	var seen: Dictionary = {}
	var deduped: Array = []
	for r: Dictionary in out:
		var rid := str(r["id"])
		if seen.has(rid):
			continue
		seen[rid] = true
		deduped.append(r)
	return deduped

# ── Generic recipe window builder ─────────────────────────────────────────────
## Recipe-category classifier. Reads the recipe's `id` + skill and returns a
## human-friendly category string used to group cards under tabs. Same
## recipe types across the game share ids (e.g. every construction wall is
## `<wood>_wall`), so a substring match is enough for MVP; a dedicated
## `category` field on each recipe dict could replace this later.
func _recipe_category(recipe: Dictionary, skill: String) -> String:
	var rid := str(recipe.get("id", ""))
	# Construction — pattern is "<wood>_<kind>" or a bespoke id (farm_plot,
	# stronghold, banner, outpost, boats).
	if skill == "construction":
		if rid in ["stronghold", "banner", "outpost"]:
			return "Warband"
		if rid == "farm_plot":
			return "Farming"
		# Strip the wood-tier prefix to get the buildable kind.
		var kind := rid
		for wood: String in ["oak", "pine", "cherry", "ironwood", "frost", "ancient"]:
			if kind.begins_with(wood + "_"):
				kind = kind.substr(wood.length() + 1)
				break
		# Category from kind.
		match kind:
			"wall", "fortified_wall", "fence", "gate":
				return "Walls"
			"watchtower", "guard_tower":
				return "Defense"
			"house_frame", "large_house", "grand_hall", "clan_hall":
				return "Housing"
			"well", "altar", "dock", "market_stall", "site_marker", "portal_shrine":
				return "Civic"
			"workbench", "smith_station", "bank_chest", "armory_rack", "plant_bed":
				return "Utility"
		# Boats (rowboat/canoe/skiff/longship/…) live at the construction
		# bench. Anything the checks above didn't catch — boats or a
		# stray uncategorized recipe — folds into the Boats tab per the
		# user's request that "Other" merge with Boats.
		return "Boats"
	# Crafting — group by output item type. Recipe ids are usually the
	# output item id. Note: `_build_all_craft_recipes` generates recipes
	# tagged with skill "smithing" for the metal armor/weapon ladders,
	# but the window it opens is the Crafting window — so all of them
	# fall through to this branch. That's why the checks below cover
	# gear ids (swords, helms, etc.) even though their skill is smithing.
	if skill == "crafting" or skill == "smithing":
		# Armor first — matches piece names as SUFFIX so `leather_helm`,
		# `iron_body`, `runite_shield`, etc. all land here regardless of
		# tier prefix.
		for suf in ["_helm", "_body", "_legs", "_gloves", "_boots", "_shield"]:
			if rid.ends_with(suf):
				return "Armor"
		# Tools — pickaxes, woodcutting axes, fishing poles are gathering
		# gear, NOT weapons. All `_axe` tools (copper_axe … adamant_axe)
		# land in Utility. `_battleaxe` is a real weapon and is distinct:
		# "copper_battleaxe".ends_with("_axe") is false (no underscore
		# before "axe"), so the two never collide.
		if rid.ends_with("_pickaxe") or rid.ends_with("_axe") \
				or rid.ends_with("_fishing_pole"):
			return "Utility"
		# Weapons — swords / battleaxes / maces / bows / staves + arrows.
		for suf in ["_sword", "_battleaxe", "_mace", "_bow", "_staff"]:
			if rid.ends_with(suf):
				return "Weapons"
		if rid == "arrows":
			return "Weapons"
		# Non-gear categories.
		if "bone" in rid or "skull" in rid:
			return "Bone"
		if "rune" in rid:
			return "Runes"
		if rid.ends_with("_ring") or rid.ends_with("_amulet") \
				or "necklace" in rid or "gem" in rid or "jewel" in rid:
			return "Jewelry"
		# Utility furnishings + fires.
		if rid in ["torch_post", "campfire", "storage_crate", "bookshelf"] \
				or "torch" in rid or "candle" in rid or "lantern" in rid:
			return "Utility"
		return "Other"
	# Cooking / smithing / magic — leave uncategorized (one flat list). If
	# these grow past ~30 recipes a category pass would help; not yet.
	return "All"


## Group recipes by category, sort each bucket by req_lv ascending. Returns
## a Dictionary { "All": recipes, category: [...], ... } — "All" always
## exists and always contains the full sorted list.
func _bucket_recipes_by_category(recipes: Array, skill: String) -> Dictionary:
	var buckets: Dictionary = {"All": []}
	for r_v: Variant in recipes:
		var r: Dictionary = r_v as Dictionary
		var cat := _recipe_category(r, skill)
		if not buckets.has(cat):
			buckets[cat] = []
		(buckets[cat] as Array).append(r)
		# Only mirror into "All" when the recipe's category is something
		# else — otherwise cooking/magic (which classify as "All" already)
		# would double every entry.
		if cat != "All":
			(buckets["All"] as Array).append(r)
	# Sort each bucket by req_lv ascending — low-tier first, matching the
	# user's ask. Ties broken by name for stable ordering.
	for k: Variant in buckets.keys():
		var arr: Array = buckets[k] as Array
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var la: int = int(a.get("req_lv", 1))
			var lb: int = int(b.get("req_lv", 1))
			if la != lb:
				return la < lb
			return str(a.get("name", "")) < str(b.get("name", "")))
	return buckets


func _build_recipe_window(title: String, recipes: Array, _skill: String,
		on_craft: Callable, _scroll_h: float = 380.0) -> PanelContainer:
	# ── Window: dynamically sized but capped at 80% of viewport so the X
	# button + tabs never fall off-screen, no matter the resolution. ──
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var cap_w: float = vp_size.x * 0.80
	var cap_h: float = vp_size.y * 0.80
	var win := PanelContainer.new()
	win.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	win.anchor_left = 0.5; win.anchor_right  = 0.5
	win.anchor_top  = 0.5; win.anchor_bottom = 0.5
	# Centered — anchors + negative half-offsets do the centering. Actual
	# size is capped so growth stops at 80% of viewport.
	var win_w: float = clampf(560.0, 360.0, cap_w)
	var win_h: float = clampf(500.0, 360.0, cap_h)
	win.offset_left = -win_w * 0.5
	win.offset_right = win_w * 0.5
	win.offset_top = -win_h * 0.5
	win.offset_bottom = win_h * 0.5
	add_child(win)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	win.add_child(root)

	# ── Title row + X button. Both always visible above the tab bar. ──
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var tlbl := _tab_title(title)
	tlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(tlbl)
	var xbtn := Button.new()
	xbtn.text = "✕"; xbtn.flat = true
	xbtn.add_theme_color_override("font_color", RS_DIM)
	xbtn.add_theme_font_size_override("font_size", 14)
	xbtn.custom_minimum_size = Vector2(28, 24)
	xbtn.pressed.connect(func() -> void: win.visible = false)
	title_row.add_child(xbtn)
	root.add_child(HSeparator.new())

	# ── Category tab row. Small buttons above the scrolling list. Tab
	# switching just toggles per-card visibility — one card per recipe,
	# same order as the flat `recipes` array, so the existing refresh
	# contract (btns[i] parallels recipes[i]) is preserved. ──
	var buckets: Dictionary = _bucket_recipes_by_category(recipes, _skill)
	# Order tabs: "All" first, then alphabetical. Skip empty categories.
	var tab_names: Array = ["All"]
	var other_names: Array = []
	for k: Variant in buckets.keys():
		if str(k) == "All":
			continue
		if (buckets[k] as Array).is_empty():
			continue
		other_names.append(str(k))
	other_names.sort()
	tab_names.append_array(other_names)

	# Which category each recipe belongs to (for visibility filtering).
	var recipe_cats: Array = []
	recipe_cats.resize(recipes.size())
	for i in range(recipes.size()):
		recipe_cats[i] = _recipe_category(recipes[i], _skill)

	# Category tab bar row (below title, above scroll).
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 3)
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(tab_row)
	var tab_btns: Dictionary = {}
	for tab: String in tab_names:
		var b := Button.new()
		b.text = "%s (%d)" % [tab, (buckets[tab] as Array).size()]
		b.add_theme_font_size_override("font_size", 11)
		b.toggle_mode = true
		b.button_pressed = (tab == "All")
		tab_row.add_child(b)
		tab_btns[tab] = b
	root.add_child(HSeparator.new())

	# ── Scroll + Grid. Cards ordered by category then req_lv ascending. ──
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	# Insertion order = sorted "All" order (low-tier → high-tier within
	# each category, categories in tab-name order). Refresh still walks
	# `recipes` in original order via a parallel index map.
	var btns: Array[Button] = []
	btns.resize(recipes.size())
	var recipe_idx_by_id: Dictionary = {}
	for i in range(recipes.size()):
		recipe_idx_by_id[str(recipes[i].get("id", ""))] = i

	# Parallel card list for visibility-toggling on tab change.
	var cards_by_idx: Array = []
	cards_by_idx.resize(recipes.size())

	# Emit cards in "All" sorted order (which is already sorted by req_lv
	# via _bucket_recipes_by_category).
	for r_v: Variant in (buckets["All"] as Array):
		var r: Dictionary = r_v as Dictionary
		var idx: int = int(recipe_idx_by_id.get(str(r.get("id", "")), -1))
		if idx < 0:
			continue
		var card := _make_recipe_card(r, _skill, on_craft)
		grid.add_child(card)
		btns[idx] = card.get_meta("craft_btn") as Button
		cards_by_idx[idx] = card

	# Wire tab buttons to toggle card visibility.
	for tab: String in tab_names:
		var b := tab_btns[tab] as Button
		b.pressed.connect(func() -> void:
			for other_v in tab_names:
				var other: String = other_v
				(tab_btns[other] as Button).button_pressed = (other == tab)
			for card_idx in range(cards_by_idx.size()):
				var c: PanelContainer = cards_by_idx[card_idx] as PanelContainer
				if c == null:
					continue
				c.visible = (tab == "All"
						or str(recipe_cats[card_idx]) == tab))

	# Persist the button list per skill so the existing refresh code path
	# still updates disabled state. Refresh only touches the FIRST card of
	# each recipe; per-tab duplicates rely on that same disabled state
	# being applied via the metadata list.
	# `crafting` AND `smithing` both funnel through `_craft_recipe_btns` — the
	# smith-gear window build in _build_craft_window uses it as a transfer
	# variable (clears it, builds, then copies into _smith_gear_recipe_btns).
	# Without the smithing case the gear window's button list stayed empty, so
	# _refresh_recipe_window never disabled the Smelt button — it was always
	# lit regardless of materials. (Bug fix.)
	if _skill == "crafting" or _skill == "smithing" or _skill == "jewelcrafting":
		_craft_recipe_btns = btns
	elif _skill == "cooking":
		_cook_recipe_btns = btns
	elif _skill == "construction":
		_construct_recipe_btns = btns
	elif _skill == "magic":
		_rune_recipe_btns = btns
	return win


## Builds one recipe card. Compact by default (icon + name + level chip +
## Craft button); click the header to expand and reveal materials + XP.
## Card node carries meta "craft_btn" so the caller can index it into the
## flat btns[] array used by _refresh_recipe_window.
func _make_recipe_card(recipe: Dictionary, skill: String,
		on_craft: Callable) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			_rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	card.custom_minimum_size = Vector2(240, 0)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 3)
	card.add_child(cv)

	# Compact header row — icon, name, level chip, Craft button.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	cv.add_child(head)
	var ipath := "res://assets/icons/%s.png" % (recipe["id"] as String)
	if ResourceLoader.exists(ipath):
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(22, 22)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture = load(ipath) as Texture2D
		head.add_child(icon)
	else:
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(18, 18)
		dot.color = recipe["color"] as Color
		head.add_child(dot)
	var nl := Label.new()
	nl.text = str(recipe.get("name", ""))
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nl.add_theme_color_override("font_color", RS_GOLD)
	nl.add_theme_font_size_override("font_size", 12)
	head.add_child(nl)
	var lvl := Label.new()
	lvl.text = "Lv %d" % int(recipe.get("req_lv", 1))
	lvl.add_theme_color_override("font_color", RS_DIM)
	lvl.add_theme_font_size_override("font_size", 10)
	head.add_child(lvl)
	# Batch quantity — small SpinBox before the action button. Cooking +
	# Smithing timed skills read this; Crafting reads it for the loop
	# count but processes each unit instantly (crafting never fails per
	# design). Max 100 keeps a single click bounded.
	var qty_spin := SpinBox.new()
	qty_spin.min_value = 1
	qty_spin.max_value = 100
	qty_spin.value = 1
	qty_spin.step = 1
	qty_spin.custom_minimum_size = Vector2(52, 0)
	qty_spin.add_theme_font_size_override("font_size", 10)
	head.add_child(qty_spin)
	var btn := Button.new()
	# Action label carries the current batch size so the player sees the
	# commit count before pressing. Cook / Smelt / Craft chosen by
	# skill; matches the persistent verb the player expects.
	var verb: String = _craft_verb_for(str(recipe.get("skill", skill)))
	btn.text = "%s 1" % verb
	btn.custom_minimum_size = Vector2(72, 0)
	btn.add_theme_stylebox_override("normal",   _rs(RS_BTN_A, RS_GOLD, 2))
	btn.add_theme_stylebox_override("hover",    _rs(RS_BTN_H, RS_GOLD, 2))
	btn.add_theme_stylebox_override("disabled", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 2))
	btn.add_theme_color_override("font_color",          RS_GOLD)
	btn.add_theme_color_override("font_disabled_color", RS_DIM)
	btn.add_theme_font_size_override("font_size", 11)
	qty_spin.value_changed.connect(func(v: float) -> void:
		if _active_craft.is_empty() or str(_active_craft.get("recipe_id", "")) != str(recipe["id"]):
			btn.text = "%s %d" % [verb, int(v)])
	btn.pressed.connect(func() -> void:
		_start_batch_craft(recipe, int(qty_spin.value), str(recipe.get("skill", skill)),
			on_craft, btn, qty_spin))
	head.add_child(btn)

	# Expanded body — hidden by default. Materials + XP.
	var expanded := VBoxContainer.new()
	expanded.add_theme_constant_override("separation", 2)
	expanded.visible = false
	cv.add_child(expanded)
	var parts: Array[String] = []
	for ing: Dictionary in recipe["input"] as Array:
		parts.append("%dx %s" % [ing["qty"], ing["name"]])
	var rl := Label.new()
	rl.text = "Needs: %s" % "  +  ".join(parts)
	rl.add_theme_color_override("font_color", RS_TEXT)
	rl.add_theme_font_size_override("font_size", 10)
	rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	expanded.add_child(rl)
	var xl := Label.new()
	var rs_skill := str(recipe.get("skill", skill)).capitalize()
	xl.text = "+%d %s XP" % [int(recipe.get("xp", 0)), rs_skill]
	xl.add_theme_color_override("font_color", RS_DIM)
	xl.add_theme_font_size_override("font_size", 9)
	expanded.add_child(xl)
	# Gear stat block for equippable outputs — a player can compare, say,
	# a mithril sword vs a mithril battleaxe recipe without needing to
	# craft one first. Only appears for items GearDB recognises.
	var out_id := str(recipe.get("id", ""))
	if GearDB.is_equippable(out_id):
		var stat_block := _gear_stat_block(GearDB.def_for(out_id))
		if stat_block != "":
			var sl := Label.new()
			sl.text = stat_block
			sl.add_theme_color_override("font_color", Color(0.85, 0.75, 0.35))
			sl.add_theme_font_size_override("font_size", 9)
			expanded.add_child(sl)

	# Progress bar + Cancel row for the active batch — hidden until this
	# specific card is the running _active_craft. Fire-orange fill; the
	# small "flame" ColorRect below wobbles as the bar advances so the
	# player has a moving visual, not just a static bar.
	var prog_row := HBoxContainer.new()
	prog_row.add_theme_constant_override("separation", 4)
	prog_row.visible = false
	cv.add_child(prog_row)
	var prog := ProgressBar.new()
	prog.custom_minimum_size = Vector2(0, 10)
	prog.min_value = 0.0
	prog.max_value = 1.0
	prog.value = 0.0
	prog.show_percentage = false
	prog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prog.add_theme_stylebox_override("fill",
		_rs(Color(0.95, 0.45, 0.10), Color(1.00, 0.75, 0.20), 0))
	prog.add_theme_stylebox_override("background",
		_rs(Color(0.10, 0.06, 0.04), RS_BORDER.darkened(0.6), 0))
	prog_row.add_child(prog)
	var cancel := Button.new()
	cancel.text = "✕"
	cancel.custom_minimum_size = Vector2(28, 0)
	cancel.tooltip_text = "Cancel batch"
	cancel.add_theme_font_size_override("font_size", 10)
	cancel.pressed.connect(func() -> void:
		if not _active_craft.is_empty() and str(_active_craft.get("recipe_id", "")) == str(recipe["id"]):
			_cancel_active_craft())
	prog_row.add_child(cancel)

	# Click the header (anywhere but the Craft button) → toggle expand.
	# Uses gui_input on the head container; the Craft button consumes its
	# own input via `accept_event` so we don't double-fire.
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton \
				and (event as InputEventMouseButton).pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			expanded.visible = not expanded.visible)

	card.set_meta("craft_btn", btn)
	card.set_meta("qty_spin", qty_spin)
	card.set_meta("prog_row", prog_row)
	card.set_meta("prog_bar", prog)
	card.set_meta("recipe_id", str(recipe["id"]))
	card.set_meta("verb", verb)
	card.set_meta("all_buttons", [btn])
	# Register so _refresh_all_recipe_cards + cancel can find this card
	# by recipe_id from anywhere.
	_recipe_card_index[str(recipe["id"])] = card
	return card

## Verb per skill — read in the action button label so "Cook", "Smelt",
## and "Craft" each match player expectation. Fallback "Craft".
func _craft_verb_for(skill: String) -> String:
	match skill:
		"cooking":  return "Cook"
		"smithing": return "Smelt"
		"magic":    return "Inscribe"
		_:          return "Craft"

func _refresh_recipe_window(recipes: Array, skill: String, btns: Array[Button]) -> void:
	for i in range(btns.size()):
		var recipe: Dictionary = recipes[i]
		var rskill := str(recipe.get("skill", skill))
		var lv := GameManager.get_skill_level(rskill)
		# Compute the FIRST blocking reason so the disabled button can explain
		# itself on hover (playtest: "I have the stuff but can't build, no idea
		# why"). Level gate first, then the first short ingredient.
		var reason := ""
		if lv < (recipe["req_lv"] as int):
			reason = "Requires %s Lv %d (you're %d)" % [rskill.capitalize(), int(recipe["req_lv"]), lv]
		else:
			for ing: Dictionary in recipe["input"] as Array:
				var have := GameManager.get_item_qty(ing["id"] as String)
				if have < (ing["qty"] as int):
					reason = "Need %d× %s (have %d)" % [int(ing["qty"]), str(ing["name"]), have]
					break
		btns[i].disabled = reason != ""
		btns[i].tooltip_text = reason

# ── Skill info window ─────────────────────────────────────────────────────────
const _SKILL_INFO: Dictionary = {
	"woodcutting": [
		["Lv 1",  "Oak Tree → Oak Log (25 XP)"],
		["Lv 5",  "Pine Tree → Pine Log (35 XP)"],
		["Lv 20", "Cherry Tree → Cherry Log (50 XP)"],
		["Lv 35", "Ironwood Tree → Ironwood Log (75 XP)"],
		["Lv 50", "Frost Tree → Frost Log (100 XP)"],
		["Lv 70", "Ancient Tree → Ancient Log (130 XP)"],
	],
	"mining": [
		["Lv 1",  "Copper Rock → Copper Ore (30 XP)"],
		["Lv 15", "Iron Rock → Iron Ore (55 XP)"],
		["Lv 30", "Gold Vein → Gold Ore (65 XP)"],
		["Lv 50", "Mithril Rock → Mithril Ore (90 XP)"],
		["Lv 70", "Adamant Rock → Adamant Ore (110 XP)"],
		["Lv 85", "Runite Rock → Runite Ore (125 XP)"],
	],
	"fishing": [
		["Lv 1",  "Fishing Spot → Raw Fish (20 XP)"],
		["Lv 20", "Salmon Spot → Raw Salmon (35 XP)"],
		["Lv 40", "Lobster Pot → Lobster (60 XP)"],
		["Lv 60", "Shark Waters → Raw Shark (90 XP)"],
		["Lv 80", "Abyssal Depth → Abyssal Eel (120 XP)"],
	],
	"smithing": [
		["Lv 1",  "2× Copper Ore → Copper Bar  (use Forge)"],
		["Lv 15", "2× Iron Ore → Iron Bar  (use Forge)"],
		["Lv 30", "2× Gold Ore → Gold Bar  (use Forge)"],
		["Lv 50", "2× Mithril Ore → Mithril Bar  (use Forge)"],
		["Lv 70", "2× Adamant Ore → Adamant Bar  (use Forge)"],
		["Lv 85", "2× Runite Ore → Runite Bar  (use Forge)"],
	],
	# Farming absorbed Foraging (Phase 1) — herb/mushroom/berry gathering now
	# grants Farming XP alongside crop growing.
	"farming": [
		["Lv 1",  "Herb Patch → Herbs (15 XP)"],
		["Lv 1",  "Wheat Seed → Wheat  (Farm Plot, ~1 min)"],
		["Lv 10", "Mushroom Patch → Mushrooms (20 XP)"],
		["Lv 15", "Carrot Seed → Carrot  (Farm Plot, ~3 min)"],
		["Lv 25", "Berry Bush → Berries (30 XP)"],
		["Lv 40", "Moonbloom Patch → Moonbloom (50 XP)"],
		["Lv 40", "Moonwheat Seed → Moonwheat  (Farm Plot, ~7 min)"],
		["Lv 60", "Ancient Root → Ancient Root (70 XP)"],
	],
	# New skill (Phase 1) — gold bar + gem into rings/amulets. Three gems:
	# opal (low) → amethyst (mid) → diamond (high). Gems drop from higher-tier
	# ore mining, a rare gem shop, or low-chance boss loot. Recipes in the
	# Jewelcrafting window.
	"jewelcrafting": [
		["Lv 1",  "Gold Bar + Opal → Opal Ring (30 XP)"],
		["Lv 10", "Gold Bar + Opal → Opal Amulet (40 XP)"],
		["Lv 30", "Gold Bar + Amethyst → Amethyst Ring (90 XP)"],
		["Lv 40", "Gold Bar + Amethyst → Amethyst Amulet (110 XP)"],
		["Lv 65", "Gold Bar + Diamond → Diamond Ring (180 XP)"],
		["Lv 75", "Gold Bar + Diamond → Diamond Amulet (220 XP)"],
	],
	"cooking": [
		["Lv 1",  "Raw Fish → Cooked Fish  (Campfire)"],
		["Lv 1",  "2× Herbs → Herb Tea  (Campfire)"],
		["Lv 20", "Raw Salmon → Cooked Salmon  (Campfire)"],
		["Lv 40", "Lobster → Cooked Lobster  (Campfire)"],
		["Lv 60", "Raw Shark → Cooked Shark  (Campfire)"],
		["Lv 80", "Abyssal Eel → Eel Stew  (Campfire)"],
	],
	"crafting": [
		["Lv 1",  "3 Sticks + 2 Stones → Wooden Axe / Pickaxe (5 XP)"],
		["Lv 1",  "3× Oak Log → Fishing Pole (15 XP)"],
		["Lv 1",  "Copper Bar + 2× Oak Log → Copper Axe (40 XP)"],
		["Lv 1",  "2× Copper Bar → Copper Pickaxe (40 XP)"],
		["Lv 5",  "Iron Bar + 2× Oak Log → Iron Axe (75 XP)"],
		["Lv 10", "2× Iron Bar + Oak Log → Iron Pickaxe (75 XP)"],
		["Lv 20", "2× Ironwood Log → Ironwood Bow (90 XP)"],
		["Lv 35", "2× Gold Bar → Gold Amulet (110 XP)"],
		["Lv 50", "Mithril Bar + Cherry Log → Mithril Sword (140 XP)"],
		["Lv 70", "Adamant Bar + 2× Pine Log → Adamant Axe (165 XP)"],
		["Lv 85", "2× Runite Bar + Frost Log → Runite Pickaxe (190 XP)"],
	],
	"construction": [
		["Lv 1",  "5× Oak Log → Wooden Chair (20 XP)  — use Construction Site"],
		["Lv 10", "10× Oak Log → Wooden Table (40 XP)"],
		["Lv 20", "5× Pine Log → Pine Bookshelf (60 XP)"],
		["Lv 30", "8× Cherry Log → Cherry Chest (80 XP)"],
		["Lv 50", "6× Ironwood Log → Ironwood Gate (120 XP)"],
		["Lv 70", "10× Frost Log → Frost Cabin (160 XP)"],
	],
	"melee": [
		["Lv 1",  "Attack monsters → Melee XP per hit"],
		["Lv 10", "Damage bonus: +1 per 10 levels above 1"],
		["Lv 25", "Double-strike: 20% chance to hit twice  [coming soon]"],
		["Lv 50", "Berserker Stance: +50% dmg, -25% def  [coming soon]"],
		["Lv 75", "Execution Strike: +100% dmg below 25% HP  [coming soon]"],
		["Lv 99", "Ragnarok Blow: guaranteed max damage  [coming soon]"],
	],
	"ranged": [
		["Lv 1",  "Attack with Ranged style → Ranged XP"],
		["Lv 10", "Accuracy and XP gain improved"],
		["Lv 25", "Multi-shot: hits twice per attack  [coming soon]"],
		["Lv 50", "Eagle Eye: +30% accuracy  [coming soon]"],
		["Lv 75", "Snipe: guaranteed critical hit  [coming soon]"],
		["Lv 99", "Valkyrie Shot: pierces defense entirely  [coming soon]"],
	],
	"magic": [
		["Lv 1",  "Attack with Magic style → Magic XP"],
		["Lv 10", "Frost Bolt: chance to slow enemy  [coming soon]"],
		["Lv 25", "Fireball: AoE splash damage  [coming soon]"],
		["Lv 40", "Chain Lightning: hits up to 3 targets  [coming soon]"],
		["Lv 60", "Blizzard: DoT frost damage  [coming soon]"],
		["Lv 80", "Meteor Strike: massive single hit  [coming soon]"],
		["Lv 99", "Valhalla Storm: all elements combined  [coming soon]"],
	],
	"defense": [
		["Lv 1",  "Reduces all incoming damage"],
		["Lv 10", "Block: floor(Lv / 4) flat damage reduced per hit"],
		["Lv 25", "Fortify: +15 max HP bonus  [coming soon]"],
		["Lv 40", "Shield Wall: 15% chance to block entirely  [coming soon]"],
		["Lv 60", "Thorns: reflects 10% of received damage  [coming soon]"],
		["Lv 80", "Rune Ward: magic damage halved  [coming soon]"],
		["Lv 99", "Aegis: 5% chance to be immune each hit  [coming soon]"],
	],
	"vitality": [
		["Lv 1",  "Max HP = Level × 10"],
		["Lv 10", "100 HP  (starting level)"],
		["Lv 20", "200 HP + slow natural regen begins  [coming soon]"],
		["Lv 40", "400 HP"],
		["Lv 60", "600 HP + regen rate increases  [coming soon]"],
		["Lv 80", "800 HP"],
		["Lv 99", "990 HP  (maximum)"],
	],
	"soul": [
		["Lv 1",  "Bury bones from your inventory to gain Soul XP"],
		["Lv 1",  "Rat Bone → 5 XP  |  Goblin Ear → 10 XP"],
		["Lv 1",  "Bone → 15 XP  |  Draugr Shard → 30 XP"],
		["Lv 1",  "Dragon Scale → 50 XP"],
		["Lv 10", "Bone Altar: bury at shrine for 2× XP  [coming soon]"],
		["Lv 25", "Protection Prayer: -10% dmg taken 30s  [coming soon]"],
		["Lv 50", "Smite: drain enemy defense on hit  [coming soon]"],
		["Lv 75", "Ancestral Ward: auto-revive once per combat  [coming soon]"],
		["Lv 99", "Godhood: passive +20% to all combat stats  [coming soon]"],
	],
}

## ── Skills Book — full-screen per-skill viewer. Playtest ask: a proper
## "book" style, not the small popup. Opens with the K keybind or from the
## button under the minimap. Rebuilds the selected skill's page on any
## XP/level event so numbers stay live.
var _skills_book_window: PanelContainer = null
var _skills_book_sidebar: VBoxContainer = null
var _skills_book_body: VBoxContainer = null
var _skills_book_selected: String = "woodcutting"
var _skills_book_row_btns: Dictionary = {}   # skill → Button

const _SKILL_ORDER: Array[String] = [
	"woodcutting", "mining", "fishing", "farming", "jewelcrafting",
	"smithing", "cooking", "crafting", "construction",
	"melee", "ranged", "magic", "defense", "vitality", "soul",
]
const _SKILL_GLYPH: Dictionary = {
	"woodcutting": "🪓", "mining": "⛏", "fishing": "🎣", "jewelcrafting": "💍",
	"farming":     "🌾", "smithing": "⚒", "cooking": "🍳", "crafting": "💎",
	"construction":"🔨", "melee":    "⚔", "ranged":  "🏹", "magic":   "🔮",
	"defense":     "🛡", "vitality": "❤", "soul":    "✨",
}

func _build_skills_book_window() -> void:
	_skills_book_window = PanelContainer.new()
	_skills_book_window.add_theme_stylebox_override("panel",
		_rs(Color(0.06, 0.04, 0.03, 0.96), Color(0.72, 0.55, 0.20), 4))
	_skills_book_window.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_skills_book_window.offset_left   = 40
	_skills_book_window.offset_top    = 40
	_skills_book_window.offset_right  = -40
	_skills_book_window.offset_bottom = -40
	_skills_book_window.visible = false
	add_child(_skills_book_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	_skills_book_window.add_child(root)

	# Title bar
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := Label.new()
	title.text = "📖  Skills"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 18)
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(32, 24)
	close_btn.pressed.connect(func() -> void: _skills_book_window.visible = false)
	title_row.add_child(close_btn)
	root.add_child(HSeparator.new())

	# Split: sidebar (skill list) | body (details)
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 8)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var side_scroll := ScrollContainer.new()
	side_scroll.custom_minimum_size = Vector2(240, 0)
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(side_scroll)
	_skills_book_sidebar = VBoxContainer.new()
	_skills_book_sidebar.add_theme_constant_override("separation", 2)
	_skills_book_sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_scroll.add_child(_skills_book_sidebar)

	var body_scroll := ScrollContainer.new()
	body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(body_scroll)
	_skills_book_body = VBoxContainer.new()
	_skills_book_body.add_theme_constant_override("separation", 6)
	_skills_book_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.add_child(_skills_book_body)

	_build_skills_book_sidebar_rows()
	Events.xp_gained.connect(func(_s: String, _a: int) -> void: _refresh_skills_book())
	Events.level_up.connect(func(_s: String, _l: int) -> void: _refresh_skills_book())

func _build_skills_book_sidebar_rows() -> void:
	for skill: String in _SKILL_ORDER:
		var row := Button.new()
		row.custom_minimum_size = Vector2(0, 32)
		row.flat = true
		row.add_theme_font_size_override("font_size", 12)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.text = "  %s  %s   Lv %d" % [
			str(_SKILL_GLYPH.get(skill, "•")),
			skill.capitalize(),
			GameManager.get_skill_level(skill)]
		row.add_theme_color_override("font_color", RS_TEXT)
		var s := skill
		row.pressed.connect(func() -> void:
			_skills_book_selected = s
			_refresh_skills_book())
		_skills_book_sidebar.add_child(row)
		_skills_book_row_btns[skill] = row

func _refresh_skills_book() -> void:
	if _skills_book_window == null or not _skills_book_window.visible:
		return
	# Sidebar labels — level numbers may have advanced since last open.
	for skill: String in _SKILL_ORDER:
		var btn := _skills_book_row_btns.get(skill, null) as Button
		if btn == null:
			continue
		btn.text = "  %s  %s   Lv %d" % [
			str(_SKILL_GLYPH.get(skill, "•")),
			skill.capitalize(),
			GameManager.get_skill_level(skill)]
		# Highlight the selected row.
		var col := RS_GOLD if skill == _skills_book_selected else RS_TEXT
		btn.add_theme_color_override("font_color", col)
	# Body — one page for the currently selected skill.
	for c in _skills_book_body.get_children():
		c.queue_free()
	var s := _skills_book_selected
	var lv := GameManager.get_skill_level(s)
	var total_xp := GameManager.get_skill_xp(s)
	var to_next := GameManager.get_xp_to_next_level(s)
	var prog := GameManager.get_level_progress(s)

	# Big header
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 12)
	_skills_book_body.add_child(hdr)
	var glyph_lbl := Label.new()
	glyph_lbl.text = str(_SKILL_GLYPH.get(s, "•"))
	glyph_lbl.add_theme_font_size_override("font_size", 40)
	hdr.add_child(glyph_lbl)
	var name_v := VBoxContainer.new()
	name_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(name_v)
	var name_lbl := Label.new()
	name_lbl.text = s.capitalize()
	name_lbl.add_theme_color_override("font_color", RS_GOLD)
	name_lbl.add_theme_font_size_override("font_size", 22)
	name_v.add_child(name_lbl)
	var lv_lbl := Label.new()
	lv_lbl.text = "Level %d / 99" % lv
	lv_lbl.add_theme_color_override("font_color", RS_TEXT)
	lv_lbl.add_theme_font_size_override("font_size", 14)
	name_v.add_child(lv_lbl)

	# XP progress bar
	var pbar := ProgressBar.new()
	pbar.min_value = 0.0
	pbar.max_value = 1.0
	pbar.value = prog
	pbar.custom_minimum_size = Vector2(0, 18)
	pbar.show_percentage = false
	_skills_book_body.add_child(pbar)
	var xp_lbl := Label.new()
	xp_lbl.text = "%s XP total   |   %s XP to level %d" % [
		_fmt_int(total_xp),
		"—" if lv >= 99 else _fmt_int(to_next),
		lv + 1]
	xp_lbl.add_theme_color_override("font_color", RS_DIM)
	xp_lbl.add_theme_font_size_override("font_size", 11)
	_skills_book_body.add_child(xp_lbl)

	_skills_book_body.add_child(HSeparator.new())

	# Unlocks list
	var unlocks_hdr := Label.new()
	unlocks_hdr.text = "Unlocks"
	unlocks_hdr.add_theme_color_override("font_color", RS_GOLD)
	unlocks_hdr.add_theme_font_size_override("font_size", 14)
	_skills_book_body.add_child(unlocks_hdr)

	var rows: Array = _SKILL_INFO.get(s, [])
	if rows.is_empty():
		var none := Label.new()
		none.text = "  No unlock table for this skill yet."
		none.add_theme_color_override("font_color", RS_DIM)
		none.add_theme_font_size_override("font_size", 11)
		_skills_book_body.add_child(none)
	for row: Array in rows:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 10)
		_skills_book_body.add_child(line)
		# Green check if unlocked at this level, dim otherwise.
		var lvl_str := str(row[0])
		var lv_num := _parse_lv(lvl_str)
		var check := Label.new()
		check.text = "✓" if lv >= lv_num else "○"
		check.custom_minimum_size = Vector2(18, 0)
		check.add_theme_color_override("font_color",
			Color(0.55, 0.85, 0.45) if lv >= lv_num else RS_DIM)
		check.add_theme_font_size_override("font_size", 12)
		line.add_child(check)
		var lv_col := Label.new()
		lv_col.text = lvl_str
		lv_col.custom_minimum_size = Vector2(48, 0)
		lv_col.add_theme_color_override("font_color", RS_GOLD)
		lv_col.add_theme_font_size_override("font_size", 11)
		line.add_child(lv_col)
		var desc := Label.new()
		desc.text = str(row[1])
		desc.add_theme_color_override("font_color",
			RS_TEXT if lv >= lv_num else RS_DIM)
		desc.add_theme_font_size_override("font_size", 11)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(desc)

func _parse_lv(s: String) -> int:
	# "Lv 25" → 25, "Lv1" → 1, everything else → 1.
	var digits := ""
	for c in s:
		if c.is_valid_int():
			digits += c
	return int(digits) if digits != "" else 1

func _fmt_int(n: int) -> String:
	# Thousands separator without printf locale headaches.
	var s := str(absi(n))
	var out := ""
	var i := s.length()
	while i > 3:
		out = "," + s.substr(i - 3, 3) + out
		i -= 3
	out = s.substr(0, i) + out
	return ("-" + out) if n < 0 else out

## Farming plant popup — small centered PanelContainer listing every
## `*_seed` item in the player's inventory. Clicking a row sends
## `farm_plant` for the target plot; the server broadcasts the new
## stage back so the visual updates. Popup closes on any plant click or
## via the ✕ button. Recreated on every open so a fresh inventory
## snapshot always renders.
## Fishing Journal window (1.6.3) — spawned as a HUD child so it cleans up with
## the player on logout, like the reel/boat-combat modals.
func _open_fishing_journal() -> void:
	add_child(preload("res://scripts/ui/FishingJournal.gd").new())

func _open_farm_plant_popup(entity_id: String) -> void:
	var win := PanelContainer.new()
	win.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	win.anchor_left  = 0.5; win.anchor_right  = 0.5
	win.anchor_top   = 0.5; win.anchor_bottom = 0.5
	win.offset_left  = -140; win.offset_right  = 140
	win.offset_top   = -120; win.offset_bottom = 120
	add_child(win)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	win.add_child(vb)
	var hdr := HBoxContainer.new()
	vb.add_child(hdr)
	var title := Label.new()
	title.text = "🌾  Plant a seed"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 12)
	hdr.add_child(title)
	var xbtn := Button.new()
	xbtn.text = "✕"
	xbtn.custom_minimum_size = Vector2(24, 0)
	xbtn.pressed.connect(func() -> void: win.queue_free())
	hdr.add_child(xbtn)
	vb.add_child(HSeparator.new())
	var found := false
	for item: Dictionary in GameManager.inventory:
		var iid := str(item["id"])
		if not iid.ends_with("_seed"):
			continue
		found = true
		var row := HBoxContainer.new()
		vb.add_child(row)
		var lbl := Label.new()
		lbl.text = "  %s  ×%d" % [str(item.get("name", iid)), int(item["qty"])]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", RS_TEXT)
		lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(lbl)
		var pb := Button.new()
		pb.text = "Plant"
		pb.add_theme_font_size_override("font_size", 10)
		var seed_id := iid
		pb.pressed.connect(func() -> void:
			# Optimistic client removal — the server-authoritative stage
			# broadcast confirms the plant landed. If it rejected, the
			# player sees the chat reason and can re-plant.
			GameManager.remove_item_qty(seed_id, 1)
			NetworkManager.send_farm_plant(entity_id, seed_id)
			win.queue_free())
		row.add_child(pb)
	if not found:
		var none := Label.new()
		none.text = "  (no seeds — buy from a farmer or find them foraging)"
		none.add_theme_color_override("font_color", RS_DIM)
		none.add_theme_font_size_override("font_size", 10)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vb.add_child(none)

## Combat loadout window — playtest-ask revamp. Opens from the ⚙ button on
## the combat panel. Three tabs (Melee/Ranged/Magic) each show: currently
## equipped weapon summary, list of owned style-matching weapons with a
## one-click Equip button, and (magic only) a rune viewer with click-to-set
## the active rune. Rebuilt on every open so newly picked-up gear appears
## without a stale-cache dance.
## Header drag — captures left-mouse on the combat window's title row and
## shifts all four offsets by the mouse delta each move. The panel is
## right-anchored (anchor_left = anchor_right = 1.0) with negative
## offsets, so adding delta.x to BOTH offset_left and offset_right keeps
## the width constant while translating; same for Y. Clamped so at least
## a strip of the header stays on-screen.
func _on_combat_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_combat_drag = mb.pressed
	elif event is InputEventMouseMotion and _combat_drag:
		if _combat_window == null:
			return
		var mm := event as InputEventMouseMotion
		var dx: float = mm.relative.x
		var dy: float = mm.relative.y
		_combat_window.offset_left  += dx
		_combat_window.offset_right += dx
		_combat_window.offset_top   += dy
		_combat_window.offset_bottom += dy
		# Viewport clamp — keep 40 px of the header grabbable so the user
		# can always drag it back. Screen bounds via viewport size.
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var edge_pad: float = 40.0
		# Right-anchored: offset_right must stay <= -edge_pad OR the panel
		# is off the right edge. offset_left is the *left edge* relative
		# to right anchor, so it must be <= offset_right - min_width.
		if _combat_window.offset_right > -edge_pad:
			var shift: float = -edge_pad - _combat_window.offset_right
			_combat_window.offset_right += shift
			_combat_window.offset_left  += shift
		# Clamp left off-screen: offset_left must be >= -vp.x + edge_pad.
		if _combat_window.offset_left < -vp.x + edge_pad:
			var shift2: float = (-vp.x + edge_pad) - _combat_window.offset_left
			_combat_window.offset_left  += shift2
			_combat_window.offset_right += shift2
		# Top/bottom — same idea with the top-anchored origin. offset_top
		# is measured from the top edge; keep it >= 0 and <= vp.y-edge_pad.
		if _combat_window.offset_top < 0.0:
			var shift3: float = -_combat_window.offset_top
			_combat_window.offset_top    += shift3
			_combat_window.offset_bottom += shift3
		if _combat_window.offset_top > vp.y - edge_pad:
			var shift4: float = (vp.y - edge_pad) - _combat_window.offset_top
			_combat_window.offset_top    += shift4
			_combat_window.offset_bottom += shift4

## Drag the chat panel by its header (playtest ask — movable like the combat
## window). Chat is bottom-right anchored, so all four offsets are negative;
## move them together, then clamp so the header stays grabbable on-screen.
func _on_chat_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_chat_drag = mb.pressed
	elif event is InputEventMouseMotion and _chat_drag:
		if _chat_panel == null:
			return
		var mm := event as InputEventMouseMotion
		_chat_panel.offset_left   += mm.relative.x
		_chat_panel.offset_right  += mm.relative.x
		_chat_panel.offset_top    += mm.relative.y
		_chat_panel.offset_bottom += mm.relative.y
		_clamp_chat_to_viewport()

## Keep the (bottom-right anchored) chat panel fully reachable on screen. Shared
## by the drag handler, the minimize/expand toggle, and the whisper un-minimize
## path — expanding a top-docked panel used to push its header above the
## viewport where it couldn't be grabbed to move or minimize again.
func _clamp_chat_to_viewport() -> void:
	if _chat_panel == null:
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var pad := 40.0
	# Horizontal (right-anchored): keep part of the panel on-screen either side.
	if _chat_panel.offset_right > -pad:
		var s := -pad - _chat_panel.offset_right
		_chat_panel.offset_right += s; _chat_panel.offset_left += s
	if _chat_panel.offset_left < -vp.x + pad:
		var s2 := (-vp.x + pad) - _chat_panel.offset_left
		_chat_panel.offset_left += s2; _chat_panel.offset_right += s2
	# Vertical (bottom-anchored). Clamp the TOP first so a downward-expanding
	# panel whose header went above the screen is pushed back down, THEN keep the
	# bottom from sliding too far off — order matters for the expand case.
	if _chat_panel.offset_top < -vp.y + pad:
		var s4 := (-vp.y + pad) - _chat_panel.offset_top
		_chat_panel.offset_top += s4; _chat_panel.offset_bottom += s4
	if _chat_panel.offset_bottom > -6.0:
		var s3 := -6.0 - _chat_panel.offset_bottom
		_chat_panel.offset_bottom += s3; _chat_panel.offset_top += s3

## Minimize / restore toggle — matches the chat + minimap idiom: hide the
## content container + swap the glyph + collapse the panel height so only
## the header shows.
func _on_combat_minimize_toggle() -> void:
	if _combat_window == null or _combat_content == null:
		return
	_combat_minimized = not _combat_minimized
	_combat_content.visible = not _combat_minimized
	_combat_min_btn.text = "▼" if _combat_minimized else "▲"
	# Panel height — the top offset stays put; the bottom offset shifts
	# to give us either the header-only height or the full open height.
	var target_h: int = _COMBAT_WIN_H_MIN if _combat_minimized else _COMBAT_WIN_H_OPEN
	_combat_window.offset_bottom = _combat_window.offset_top + target_h

## Loadout section — inlined into the combat window per playtest. `_loadout_section`
## is the collapsible VBox added to the combat root; the ⚙ button in the style
## row toggles its visibility. `_loadout_body` holds the per-tab content that
## `_refresh_loadout` rebuilds on inventory/equipment change.
var _loadout_section: VBoxContainer = null
var _loadout_body: VBoxContainer = null
var _loadout_tab: String = "melee"

## Toggle the inline loadout section on/off inside the combat window. When
## opening, sync the visible tab to the player's current combat style so
## a magic caster's ⚙ click doesn't dump them onto the melee tab.
func open_loadout_window() -> void:
	if _loadout_section == null:
		return
	if _loadout_section.visible:
		_loadout_section.visible = false
		return
	_loadout_tab = GameManager.combat_style
	if _loadout_tab != "melee" and _loadout_tab != "ranged" and _loadout_tab != "magic":
		_loadout_tab = "melee"
	_loadout_section.visible = true
	_refresh_loadout()

## Builds the loadout tab-row + scrollable body under `parent`. Starts
## hidden — open via the ⚙ toggle. Only wires the Events refresh signals
## once, per _loadout_signals_wired guard, in case _build_combat_window
## is ever invoked twice.
var _loadout_signals_wired: bool = false

func _build_loadout_section(parent: Control) -> void:
	_loadout_section = VBoxContainer.new()
	_loadout_section.add_theme_constant_override("separation", 4)
	_loadout_section.visible = false
	parent.add_child(_loadout_section)
	_loadout_section.add_child(HSeparator.new())

	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	_loadout_section.add_child(tab_row)
	for tab_data: Array in [["⚔ Melee","melee"], ["🏹 Ranged","ranged"], ["✨ Magic","magic"]]:
		var tb := Button.new()
		tb.text = tab_data[0]
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.add_theme_font_size_override("font_size", 11)
		var t: String = tab_data[1]
		tb.pressed.connect(func() -> void:
			_loadout_tab = t
			_refresh_loadout())
		tab_row.add_child(tb)

	# Scroll bounds so the loadout doesn't push the combat window off-screen
	# when it fills up with weapons — a bounded viewport with vertical scroll
	# keeps the combat panel a manageable size when open.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 220)
	_loadout_section.add_child(scroll)
	_loadout_body = VBoxContainer.new()
	_loadout_body.add_theme_constant_override("separation", 4)
	_loadout_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_loadout_body)

	if not _loadout_signals_wired:
		Events.inventory_changed.connect(_refresh_loadout)
		Events.equipment_changed.connect(_refresh_loadout)
		_loadout_signals_wired = true

## Fallback swatch color per combat style — used only when an item's icon
## sprite is missing, so a bow-shaped row still shows a green-tinted dot
## rather than a bland grey square.
func _style_swatch(style: String) -> Color:
	match style:
		"ranged": return Color(0.40, 0.75, 0.35)
		"magic":  return Color(0.55, 0.35, 0.85)
		_:        return Color(0.75, 0.60, 0.20)

## Icon helper for loadout rows — TextureRect at ~22×22 loading the item's
## icon, or a colored dot fallback when the sprite is missing so row heights
## stay consistent. Uses the same `assets/icons/<id>.png` convention as
## inventory + craft cards.
func _loadout_row_icon(item_id: String, tint: Color) -> Control:
	var icon_path := "res://assets/icons/" + item_id + ".png"
	if ResourceLoader.exists(icon_path):
		var trect := TextureRect.new()
		trect.custom_minimum_size = Vector2(22, 22)
		trect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		trect.texture = load(icon_path) as Texture2D
		return trect
	# Fallback swatch — 22×22 to match, tinted from the passed color (item
	# color from the recipe / def) so at least the row reads as *something*.
	var cr := ColorRect.new()
	cr.custom_minimum_size = Vector2(22, 22)
	cr.color = tint
	return cr

func _refresh_loadout() -> void:
	if _loadout_section == null or not _loadout_section.visible:
		return
	for c in _loadout_body.get_children():
		c.queue_free()

	# Equipped weapon summary — read equipment slot and cross-check the
	# def to make sure the weapon's style matches the active tab. If the
	# player has a Ranged bow equipped but is viewing the Melee tab, show
	# "None" so the tab feels self-contained.
	var equipped_id := str(GameManager.equipment.get("weapon", ""))
	var equipped_def: Dictionary = GearDB.def_for(equipped_id) if equipped_id != "" else {}
	var eq_style := str(equipped_def.get("style", ""))

	var eq_hdr := Label.new()
	eq_hdr.text = "Equipped (%s):" % _loadout_tab.capitalize()
	eq_hdr.add_theme_color_override("font_color", RS_GOLD)
	eq_hdr.add_theme_font_size_override("font_size", 12)
	_loadout_body.add_child(eq_hdr)

	if equipped_id != "" and eq_style == _loadout_tab:
		var eq_row := HBoxContainer.new()
		eq_row.add_theme_constant_override("separation", 6)
		_loadout_body.add_child(eq_row)
		eq_row.add_child(_loadout_row_icon(equipped_id,
			_style_swatch(_loadout_tab)))
		var eq_lbl := Label.new()
		eq_lbl.text = "%s  —  %s" % [
			str(equipped_def.get("name", equipped_id)),
			_stat_str(equipped_def)]
		eq_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		eq_lbl.add_theme_color_override("font_color", RS_TEXT)
		eq_lbl.add_theme_font_size_override("font_size", 11)
		eq_lbl.tooltip_text = _gear_stat_block(equipped_def)
		eq_row.add_child(eq_lbl)
		var uneq_btn := Button.new()
		uneq_btn.text = "Unequip"
		uneq_btn.add_theme_font_size_override("font_size", 10)
		uneq_btn.pressed.connect(func() -> void:
			GameManager.unequip_slot("weapon"))
		eq_row.add_child(uneq_btn)
	else:
		var none_lbl := Label.new()
		none_lbl.text = "  (no %s weapon equipped)" % _loadout_tab
		none_lbl.add_theme_color_override("font_color", RS_DIM)
		none_lbl.add_theme_font_size_override("font_size", 11)
		_loadout_body.add_child(none_lbl)

	_loadout_body.add_child(HSeparator.new())

	# Owned weapons matching the tab's style — quick-equip button per row.
	var owned_hdr := Label.new()
	owned_hdr.text = "Owned %s weapons:" % _loadout_tab
	owned_hdr.add_theme_color_override("font_color", RS_GOLD)
	owned_hdr.add_theme_font_size_override("font_size", 12)
	_loadout_body.add_child(owned_hdr)

	var found := false
	for i in range(GameManager.inventory.size()):
		var item: Dictionary = GameManager.inventory[i]
		var iid := str(item["id"])
		var d := GearDB.def_for(iid)
		if str(d.get("slot", "")) != "weapon":
			continue
		if str(d.get("style", "")) != _loadout_tab:
			continue
		found = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_loadout_body.add_child(row)
		row.add_child(_loadout_row_icon(iid, _style_swatch(_loadout_tab)))
		var name_lbl := Label.new()
		# Compact one-line stat summary — full block goes into the tooltip
		# so hover shows atk/str/acc/atk_spd/min_lv without cluttering the
		# row height.
		name_lbl.text = "%s  (%s)" % [
			str(d.get("name", iid)),
			_stat_str(d)]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_color_override("font_color", RS_TEXT)
		name_lbl.add_theme_font_size_override("font_size", 11)
		name_lbl.tooltip_text = _gear_stat_block(d)
		row.add_child(name_lbl)
		var eq_btn := Button.new()
		eq_btn.text = "Equip"
		eq_btn.add_theme_font_size_override("font_size", 10)
		var idx := i
		eq_btn.pressed.connect(func() -> void:
			GameManager.equip_item(idx))
		row.add_child(eq_btn)
	if not found:
		var empty_lbl := Label.new()
		empty_lbl.text = "  (none in inventory — craft or buy some)"
		empty_lbl.add_theme_color_override("font_color", RS_DIM)
		empty_lbl.add_theme_font_size_override("font_size", 11)
		_loadout_body.add_child(empty_lbl)

	# Magic tab: rune viewer + active-rune picker. Runes are stackable items
	# in the inventory; the "active" one is what magic combat consumes.
	if _loadout_tab == "magic":
		_loadout_body.add_child(HSeparator.new())
		var rune_hdr := Label.new()
		rune_hdr.text = "Runes:"
		rune_hdr.add_theme_color_override("font_color", RS_GOLD)
		rune_hdr.add_theme_font_size_override("font_size", 12)
		_loadout_body.add_child(rune_hdr)

		var active := GameManager.active_rune
		var rune_found := false
		for item: Dictionary in GameManager.inventory:
			var iid := str(item["id"])
			if not iid.begins_with("rune_"):
				continue
			rune_found = true
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			_loadout_body.add_child(row)
			row.add_child(_loadout_row_icon(iid, Color(0.55, 0.35, 0.85)))
			var lbl := Label.new()
			lbl.text = "%s  ×%d" % [str(item.get("name", iid)), int(item["qty"])]
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.add_theme_color_override("font_color",
				RS_GOLD if iid == active else RS_TEXT)
			lbl.add_theme_font_size_override("font_size", 11)
			row.add_child(lbl)
			var set_btn := Button.new()
			set_btn.text = "Active" if iid == active else "Use"
			set_btn.disabled = iid == active
			set_btn.add_theme_font_size_override("font_size", 10)
			var rid := iid
			set_btn.pressed.connect(func() -> void:
				GameManager.set_combat_style("magic", rid))
			row.add_child(set_btn)
		if not rune_found:
			var no_rune := Label.new()
			no_rune.text = "  (no runes — buy from Eirik the Rune-Master)"
			no_rune.add_theme_color_override("font_color", RS_DIM)
			no_rune.add_theme_font_size_override("font_size", 11)
			_loadout_body.add_child(no_rune)

func open_skills_book() -> void:
	if _skills_book_window == null:
		_build_skills_book_window()
	_skills_book_window.visible = true
	_refresh_skills_book()

func _build_skill_info_window() -> void:
	_skill_info_window = PanelContainer.new()
	_skill_info_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_skill_info_window.anchor_left   = 0.5; _skill_info_window.anchor_right  = 0.5
	_skill_info_window.anchor_top    = 0.5; _skill_info_window.anchor_bottom = 0.5
	_skill_info_window.offset_left   = -155; _skill_info_window.offset_right  = 155
	_skill_info_window.offset_top    = -180; _skill_info_window.offset_bottom = 180
	_skill_info_window.visible       = false
	add_child(_skill_info_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 5)
	_skill_info_window.add_child(root)

	var hdr := HBoxContainer.new()
	root.add_child(hdr)
	_skill_info_title = Label.new()
	_skill_info_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skill_info_title.add_theme_color_override("font_color", RS_GOLD)
	_skill_info_title.add_theme_font_size_override("font_size", 13)
	_skill_info_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_child(_skill_info_title)
	var xbtn := Button.new()
	xbtn.text = "✕"; xbtn.flat = true
	xbtn.add_theme_color_override("font_color", RS_DIM)
	xbtn.add_theme_font_size_override("font_size", 13)
	xbtn.pressed.connect(func() -> void: _skill_info_window.visible = false)
	hdr.add_child(xbtn)

	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	_skill_info_body = VBoxContainer.new()
	_skill_info_body.add_theme_constant_override("separation", 4)
	_skill_info_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_skill_info_body)

func _show_skill_info(skill: String) -> void:
	_skill_info_title.text = skill.capitalize()
	for child in _skill_info_body.get_children():
		child.queue_free()
	var rows: Array = _SKILL_INFO.get(skill, [])
	for row: Array in rows:
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		_skill_info_body.add_child(hbox)
		var lv_lbl := Label.new()
		lv_lbl.text = row[0] as String
		lv_lbl.custom_minimum_size = Vector2(36, 0)
		lv_lbl.add_theme_color_override("font_color", RS_GOLD)
		lv_lbl.add_theme_font_size_override("font_size", 10)
		hbox.add_child(lv_lbl)
		var desc := Label.new()
		desc.text = row[1] as String
		desc.add_theme_color_override("font_color", RS_TEXT)
		desc.add_theme_font_size_override("font_size", 10)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(desc)
	_skill_info_window.visible = true

func _on_skill_cell_pressed(skill: String) -> void:
	match skill:
		"crafting":
			_refresh_craft()
			_craft_window.visible = true
		"smithing":
			if _near_type("forge"):
				_on_open_forge()
			else:
				_show_skill_info(skill)
		"cooking":
			if _near_type("fire"):
				_on_open_cooking()
			else:
				_show_skill_info(skill)
		_:
			_show_skill_info(skill)

func _near_type(type_str: String, range_px: float = 80.0) -> bool:
	if _player == null:
		return false
	for node in get_tree().get_nodes_in_group("interactable"):
		if node.get("interactable_type_str") == type_str:
			if (_player as Node2D).global_position.distance_to(
					(node as Node2D).global_position) <= range_px:
				return true
	return false

# ── Combat window ─────────────────────────────────────────────────────────────
## Unified Target / Combat panel. Replaces the old separate combat window +
## persistent style strip. Lives top-right, default visible, collapsible.
##
## Sections (top → bottom):
##   1. Header (title + collapse ✕)
##   2. Target section (name + level + HP + Attack/Flee button)
##      — hidden when no target selected, no monster in combat
##   3. Player HP (always visible)
##   4. Style toggles (melee / ranged / magic) — always visible
##   5. Rune sub-row (visible only when style == magic)
##   6. Combat log — visible only during combat
##
## State flow:
##   - Left-click monster → _select_target sets _selected_target, panel
##     auto-shows, Attack button enabled.
##   - Click Attack → emits monster_attack_chosen, Player opens combat,
##     panel switches Attack→Flee, log appears.
##   - Combat ends → log + Flee hide, target stays selected so the player
##     can press Attack again. Player can clear target via right-click.
func _build_combat_window() -> void:
	_combat_window = PanelContainer.new()
	_combat_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	# Top-right, immediately LEFT of the minimap (minimap spans offset_left -174..-6).
	_combat_window.anchor_left   = 1.0; _combat_window.anchor_right  = 1.0
	_combat_window.anchor_top    = 0.0; _combat_window.anchor_bottom = 0.0
	_combat_window.offset_left   = -468; _combat_window.offset_right  = -182
	_combat_window.offset_top    = 6;    _combat_window.offset_bottom = 302
	_combat_window.visible       = true   # default visible — replaces the persistent strip
	add_child(_combat_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_combat_window.add_child(root)

	# ── Header: title + minimize ▲ + close ✕. The header row also acts as
	# the drag handle for the whole window (gui_input below).
	var top_row := HBoxContainer.new()
	top_row.mouse_filter = Control.MOUSE_FILTER_STOP
	top_row.gui_input.connect(_on_combat_header_input)
	root.add_child(top_row)
	var title := _tab_title("⚔  Combat")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_PASS  # let drag bubble to header
	top_row.add_child(title)
	# Minimize ▲ — hides `_combat_content` and shrinks the panel to just
	# the header (playtest ask). Sits left of ✕ so the close button stays
	# in the same corner.
	_combat_min_btn = Button.new()
	_combat_min_btn.text = "▲"
	_combat_min_btn.custom_minimum_size = Vector2(36, 36)
	_combat_min_btn.add_theme_stylebox_override("normal", _rs(RS_BG, RS_BORDER, 2))
	_combat_min_btn.add_theme_color_override("font_color", RS_TEXT)
	_combat_min_btn.add_theme_font_size_override("font_size", 12)
	_combat_min_btn.tooltip_text = "Minimize (▲) / Restore (▼)"
	_combat_min_btn.pressed.connect(_on_combat_minimize_toggle)
	top_row.add_child(_combat_min_btn)
	var close_btn := Button.new()
	close_btn.text = "✕"
	# 36×36 — meets Apple HIG 44 px touch-target close enough for a
	# corner button, comfortable thumb-tap on Android. Up from 26×0.
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.add_theme_stylebox_override("normal", _rs(RS_BG, RS_BORDER, 2))
	close_btn.add_theme_color_override("font_color", RS_TEXT)
	close_btn.add_theme_font_size_override("font_size", 14)
	close_btn.tooltip_text = "Hide panel (right-click any monster to reopen)"
	close_btn.pressed.connect(func() -> void: _combat_window.visible = false)
	top_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	# Everything below the header lives in a single container so the
	# minimize toggle can hide/show it in one call (mirrors the minimap +
	# chat pattern).
	_combat_content = VBoxContainer.new()
	_combat_content.add_theme_constant_override("separation", 6)
	root.add_child(_combat_content)

	# ── Target section (hidden when no target) ──
	_target_section = VBoxContainer.new()
	_target_section.add_theme_constant_override("separation", 4)
	_combat_content.add_child(_target_section)

	var t_header_row := HBoxContainer.new()
	t_header_row.add_theme_constant_override("separation", 6)
	_target_section.add_child(t_header_row)
	var t_ico := Label.new()
	t_ico.text = "☠"
	t_ico.add_theme_color_override("font_color", Color(0.8,0.8,0.8))
	t_ico.add_theme_font_size_override("font_size", 14)
	t_header_row.add_child(t_ico)
	var t_vbox := VBoxContainer.new()
	t_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t_vbox.add_theme_constant_override("separation", 0)
	t_header_row.add_child(t_vbox)
	_target_name_lbl = Label.new()
	_target_name_lbl.add_theme_color_override("font_color", RS_GOLD)
	_target_name_lbl.add_theme_font_size_override("font_size", 11)
	t_vbox.add_child(_target_name_lbl)
	_target_lvl_lbl = Label.new()
	_target_lvl_lbl.add_theme_color_override("font_color", RS_DIM)
	_target_lvl_lbl.add_theme_font_size_override("font_size", 9)
	t_vbox.add_child(_target_lvl_lbl)

	_target_hp_lbl = Label.new()
	_target_hp_lbl.add_theme_color_override("font_color", RS_TEXT)
	_target_hp_lbl.add_theme_font_size_override("font_size", 10)
	_target_section.add_child(_target_hp_lbl)
	_target_hp_bar = ProgressBar.new()
	_target_hp_bar.show_percentage = false
	_target_hp_bar.custom_minimum_size = Vector2(0, 8)
	_target_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_hp_bar.add_theme_stylebox_override("fill",       _rs(Color(0.7,0.12,0.12), Color(0.95,0.2,0.2), 0))
	_target_hp_bar.add_theme_stylebox_override("background", _rs(Color(0.05,0.05,0.05), RS_BORDER.darkened(0.6), 0))
	_target_section.add_child(_target_hp_bar)

	# Action button row: Attack (out of combat) → Flee (in combat). Both
	# share the same slot so the layout doesn't shift when combat starts.
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 4)
	_target_section.add_child(action_row)
	_attack_btn = Button.new()
	_attack_btn.text = "Attack"
	_attack_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_attack_btn.custom_minimum_size = Vector2(0, 28)
	_attack_btn.add_theme_stylebox_override("normal",  _rs(Color(0.20,0.08,0.06), RS_GOLD, 2))
	_attack_btn.add_theme_stylebox_override("hover",   _rs(Color(0.30,0.10,0.08), RS_GOLD, 2))
	_attack_btn.add_theme_stylebox_override("pressed", _rs(Color(0.15,0.06,0.05), RS_GOLD, 2))
	_attack_btn.add_theme_color_override("font_color", RS_GOLD)
	_attack_btn.add_theme_font_size_override("font_size", 12)
	_attack_btn.pressed.connect(_on_attack_btn_pressed)
	action_row.add_child(_attack_btn)
	_flee_btn = Button.new()
	_flee_btn.text = "Flee"
	_flee_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flee_btn.custom_minimum_size = Vector2(0, 28)
	_flee_btn.add_theme_stylebox_override("normal", _rs(Color(0.25,0.05,0.05), RS_BORDER, 2))
	_flee_btn.add_theme_color_override("font_color", Color(1,0.4,0.4))
	_flee_btn.add_theme_font_size_override("font_size", 12)
	_flee_btn.pressed.connect(func() -> void:
		# Flee doubles as "stop attacking this player" during PvP. Clears
		# the swing loop; the target itself stays valid so the player can
		# still re-click Attack without hunting them down again.
		if _pvp_target != null:
			_pvp_target = null
			_attack_btn.visible = true
			_flee_btn.visible = false
			Events.chat_message.emit("Stopped attacking.")
			return
		Events.combat_ended.emit())
	_flee_btn.visible = false
	action_row.add_child(_flee_btn)

	_target_section.add_child(HSeparator.new())
	_target_section.visible = false   # nothing selected yet

	# Player HP
	var p_row := HBoxContainer.new()
	p_row.add_theme_constant_override("separation", 6)
	_combat_content.add_child(p_row)
	var p_ico := Label.new()
	p_ico.text = "❤"
	p_ico.add_theme_color_override("font_color", Color(0.95,0.20,0.20))
	p_ico.add_theme_font_size_override("font_size", 14)
	p_row.add_child(p_ico)
	var p_vbox := VBoxContainer.new()
	p_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p_vbox.add_theme_constant_override("separation", 1)
	p_row.add_child(p_vbox)
	_combat_plr_lbl = Label.new()
	_combat_plr_lbl.add_theme_color_override("font_color", RS_TEXT)
	_combat_plr_lbl.add_theme_font_size_override("font_size", 10)
	p_vbox.add_child(_combat_plr_lbl)
	_combat_plr_bar = ProgressBar.new()
	_combat_plr_bar.show_percentage = false
	_combat_plr_bar.custom_minimum_size = Vector2(0, 8)
	_combat_plr_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_plr_bar.add_theme_stylebox_override("fill",       _rs(Color(0.12,0.65,0.12), Color(0.2,0.9,0.2), 0))
	_combat_plr_bar.add_theme_stylebox_override("background", _rs(Color(0.05,0.05,0.05), RS_BORDER.darkened(0.6), 0))
	p_vbox.add_child(_combat_plr_bar)

	_combat_content.add_child(HSeparator.new())

	# Attack style
	var style_lbl := Label.new()
	style_lbl.text = "Attack Style:"
	style_lbl.add_theme_color_override("font_color", RS_DIM)
	style_lbl.add_theme_font_size_override("font_size", 10)
	_combat_content.add_child(style_lbl)

	var style_row := HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 4)
	_combat_content.add_child(style_row)
	for style_data: Array in [["⚔ Melee","melee"], ["🏹 Ranged","ranged"], ["✨ Magic","magic"]]:
		var sb := Button.new()
		sb.text = style_data[0] as String
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
		sb.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
		sb.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD, 2))
		sb.add_theme_color_override("font_color", RS_TEXT)
		sb.add_theme_font_size_override("font_size", 11)
		var sval: String = style_data[1] as String
		_style_btns[sval] = sb
		sb.pressed.connect(func() -> void:
			# Route through GameManager so the persistent strip + save state
			# pick up the change. Magic with no rune picks the best available.
			var rune: String = GameManager.active_rune
			if sval == "magic" and rune == "":
				rune = _best_available_rune()
			GameManager.set_combat_style(sval, rune)
			_combat_style = sval
			_refresh_style_btns()
			_refresh_persist_rune_row())
		style_row.add_child(sb)
	# Playtest ask: expose weapon quick-equip + rune viewer without the
	# player having to leave the combat panel. Small gear button opens
	# the dedicated loadout window.
	var loadout_btn := Button.new()
	loadout_btn.text = "⚙"
	loadout_btn.tooltip_text = "Combat loadout — weapons + runes"
	loadout_btn.custom_minimum_size = Vector2(28, 0)
	loadout_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	loadout_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
	loadout_btn.add_theme_color_override("font_color", RS_GOLD)
	loadout_btn.add_theme_font_size_override("font_size", 12)
	loadout_btn.pressed.connect(open_loadout_window)
	style_row.add_child(loadout_btn)
	_refresh_style_btns()

	# Rune sub-row — replaces the old persistent-strip rune row. Visible
	# only when style == magic. Same data feed (`_refresh_persist_rune_row`)
	# so existing handlers don't need to be split.
	_persist_rune_row = HBoxContainer.new()
	_persist_rune_row.add_theme_constant_override("separation", 2)
	_combat_content.add_child(_persist_rune_row)

	# ── Combat log (visible only during combat) ──
	_combat_log_box = VBoxContainer.new()
	_combat_log_box.add_theme_constant_override("separation", 4)
	_combat_content.add_child(_combat_log_box)
	_combat_log_box.add_child(HSeparator.new())
	_combat_log = Label.new()
	_combat_log.add_theme_color_override("font_color", RS_TEXT)
	_combat_log.add_theme_font_size_override("font_size", 10)
	_combat_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_combat_log.custom_minimum_size = Vector2(0, 40)
	_combat_log_box.add_child(_combat_log)
	_combat_log_box.visible = false

	# ⚙ Loadout — inline section (starts hidden). The ⚙ button in the style
	# row toggles _loadout_section.visible.
	_build_loadout_section(_combat_content)

	# Initial style + rune state mirrors GameManager (loaded from server on login).
	_combat_style = GameManager.combat_style
	_refresh_persist_rune_row()
	# Listen for any external style change so the in-panel buttons sync.
	Events.combat_style_changed.connect(_on_combat_style_changed_external)
	Events.inventory_changed.connect(_refresh_persist_rune_row)
	# Re-tint Ranged/Magic style buttons when arrows/runes change so the
	# red "out of resource" hint clears the moment the player resupplies.
	Events.inventory_changed.connect(_refresh_style_btns)
	Events.xp_gained.connect(_on_xp_gained_for_rune_row)
	NetworkManager.admin_rank_changed.connect(_on_admin_rank_for_rune_row)

## Attack button pressed inside the unified panel. Same wire as the old
## monster-click popup's Attack row: emits monster_attack_chosen, Player
## opens combat instantly without moving.
func _on_attack_btn_pressed() -> void:
	if _selected_target == null or not is_instance_valid(_selected_target):
		return
	# PvP branch — the combat panel doubles as the PvP UI. Attacker + target
	# must both be flagged. The dedicated `_pvp_swing_tick` fires attacks on
	# a fixed cadence via NetworkManager.send_pvp_attack — server validates
	# each swing (range + mutual flag).
	if _selected_target.is_in_group("other_player"):
		if _selected_target.has_method("is_pvp_flagged") \
				and not bool(_selected_target.call("is_pvp_flagged")):
			Events.chat_message.emit("Target is not PvP-flagged.")
			return
		# Auto-flag (Phase 8): attacking opts YOU into PvP if you weren't already.
		# request_pvp_toggle(true) always succeeds for turning on / safe-override.
		if not GameManager.pvp_flagged:
			if GameManager.request_pvp_toggle(true) == "":
				NetworkManager.send_pvp_toggle(true)
				_refresh_pvp_btn()
				Events.chat_message.emit("PvP enabled — you are now attackable.")
		_pvp_target = _selected_target as Node2D
		_pvp_swing_timer = 0.0    # swing immediately
		_attack_btn.visible = false
		_flee_btn.visible = true
		return
	if not (_selected_target.get("is_alive") as bool):
		_clear_target()
		return
	if _in_combat:
		return   # already engaged with this target
	Events.monster_attack_chosen.emit(_selected_target)

## PvP combat cadence — fires a pvp_attack every PVP_SWING_INTERVAL while
## `_pvp_target` is set + in range + still flagged. Damage rolls locally
## (same style-aware roll used by the monster combat path) and the server
## re-checks range/flag before forwarding to the defender.
const PVP_SWING_INTERVAL: float = 2.4
## Style-based PvP reach, in TILES (Phase 8). Melee is fixed & short; ranged /
## magic reach further and grow with the equipped weapon's tier (a dragon bow
## outranges a copper bow). Tune these four to change the feel.
const PVP_TILE_PX: float = 32.0
const PVP_MELEE_TILES: float = 2.0
const PVP_RANGED_BASE_TILES: float = 6.0
const PVP_MAGIC_BASE_TILES: float = 7.0
const PVP_RANGE_PER_TIER: float = 0.5
## Weapon tier → index (mirror of Equipment.TIER_INDEX; kept local to avoid a
## cross-script const dependency). Only the ranged/magic reach uses it.
const _PVP_WEAPON_TIER: Dictionary = {
	"leather": 0, "copper": 1, "bronze": 1, "iron": 2, "gold": 1,
	"mithril": 4, "adamant": 5, "runite": 6, "dragon": 7,
}
var _pvp_target: Node2D = null
var _pvp_swing_timer: float = 0.0
## Debounce for the "no line of sight" / "out of range" chat so a blocked shot
## doesn't spam every frame; resets once the shot connects again.
var _pvp_los_warned: bool = false
var _ground_ref: Node = null

## Tier index of the equipped weapon (0 if none / unknown). Strips any ~u
## upgrade suffix, then reads the "{tier}_..." prefix.
func _pvp_weapon_tier_index() -> int:
	var wid := str(GameManager.equipment.get("weapon", ""))
	var up := wid.find("~u")
	if up >= 0:
		wid = wid.substr(0, up)
	var tier_name := wid.split("_")[0] if wid.contains("_") else wid
	return int(_PVP_WEAPON_TIER.get(tier_name, 0))

## Max PvP reach in pixels for the current style + equipped weapon tier.
func _pvp_max_range_px() -> float:
	match GameManager.combat_style:
		"ranged":
			return (PVP_RANGED_BASE_TILES + PVP_RANGE_PER_TIER * float(_pvp_weapon_tier_index())) * PVP_TILE_PX
		"magic":
			return (PVP_MAGIC_BASE_TILES + PVP_RANGE_PER_TIER * float(_pvp_weapon_tier_index())) * PVP_TILE_PX
		_:
			return PVP_MELEE_TILES * PVP_TILE_PX

## Line-of-sight: false if any impassable tile (water / cliffs) sits on the
## segment between the two world points. Hills are passable so they don't
## block yet (needs elevation data — deferred). Samples every ~half tile.
func _pvp_line_of_sight_clear(from: Vector2, to: Vector2) -> bool:
	if _ground_ref == null or not is_instance_valid(_ground_ref):
		_ground_ref = get_tree().get_first_node_in_group("ground")
	if _ground_ref == null or not _ground_ref.has_method("is_tile_impassable"):
		return true
	var dist := from.distance_to(to)
	if dist < 1.0:
		return true
	var steps := int(ceil(dist / (PVP_TILE_PX * 0.5)))
	for i in range(1, steps):
		var p := from.lerp(to, float(i) / float(steps))
		var tx := int(floor(p.x / PVP_TILE_PX))
		var ty := int(floor(p.y / PVP_TILE_PX))
		if bool(_ground_ref.call("is_tile_impassable", tx, ty)):
			return false
	return true

func _pvp_swing_tick(delta: float) -> void:
	if _pvp_target == null or not is_instance_valid(_pvp_target):
		return
	if _player == null:
		return
	# Bail on state changes (either party toggled off, we entered safe
	# mode, or target walked into safe mode). Clears the target so the
	# combat panel doesn't linger with a stale name.
	var target_flagged: bool = _pvp_target.has_method("is_pvp_flagged") \
		and bool(_pvp_target.call("is_pvp_flagged"))
	if not GameManager.pvp_flagged or not target_flagged or GameManager.is_pvp_safe():
		_pvp_target = null
		_clear_target()
		return
	# Player ids are TEXT hex tokens — send the raw string, never int() it.
	var target_id: String = str(_pvp_target.get_meta("server_id", "")) \
		if _pvp_target.has_meta("server_id") else ""
	if target_id == "":
		_pvp_target = null
		return
	_pvp_swing_timer -= delta
	if _pvp_swing_timer > 0.0:
		return
	var ppos := (_player as Node2D).global_position
	var tpos := _pvp_target.global_position
	# Style + gear based reach. Out of range holds the swing ready (no timer
	# reset) so it fires the instant you close the gap.
	if ppos.distance_to(tpos) > _pvp_max_range_px():
		if not _pvp_los_warned:
			_pvp_los_warned = true
			Events.chat_message.emit("Out of range — move closer.")
		return
	# Line-of-sight — water / cliffs break it; auto-resumes when either player
	# moves clear (this re-checks every tick).
	if not _pvp_line_of_sight_clear(ppos, tpos):
		if not _pvp_los_warned:
			_pvp_los_warned = true
			Events.chat_message.emit("No line of sight to your target.")
		return
	_pvp_los_warned = false
	_pvp_swing_timer = PVP_SWING_INTERVAL * GameManager.get_attack_speed_mult()
	# Play the matching attack visual (arrow / magic orb / melee swing). Falls
	# back to a melee swing if out of arrows/runes, and returns the style
	# actually used so the damage packet + XP match what was shown.
	var style := _pvp_play_attack_visual(_pvp_target)
	# Hit-chance vs a nominal PvP defense — the server doesn't yet expose the
	# defender's def to the attacker, so we assume a modest baseline.
	var acc: int = GameManager.get_equipment_bonus("acc")
	var hit_chance: float = clampf(0.55 + float(acc) * 0.02 - 0.05, 0.15, 0.95)
	if randf() > hit_chance:
		Events.chat_message.emit("You miss.")
		return
	var dmg: int = maxi(1, GameManager.get_attack_power(style) + randi_range(-2, 2))
	# Crit roll (Phase 4) — attacker side.
	var pcrit := GameManager.roll_crit(dmg)
	dmg = int(pcrit[0])
	if bool(pcrit[1]):
		Events.chat_message.emit("Critical hit!")
	NetworkManager.send_pvp_attack(target_id, dmg, style)

## Play the local attack animation for a PvP swing and return the style used.
## Mirrors the monster-combat visuals: arrow / magic projectile toward the
## target node, or a melee weapon swing. Consumes arrows/runes like PvE; if the
## resource is out it degrades to a melee swing for that tick.
func _pvp_play_attack_visual(target_node: Node2D) -> String:
	var style := GameManager.combat_style
	if style == "ranged":
		if GameManager.get_item_qty("arrows") > 0:
			GameManager.remove_item_qty("arrows", 1)
			_spawn_pvp_projectile(target_node, "arrow", Color(0.85, 0.85, 0.9))
			return "ranged"
		style = "melee"
	elif style == "magic":
		var rune := GameManager.active_rune
		if rune != "" and GameManager.get_item_qty(rune) > 0:
			GameManager.remove_item_qty(rune, 1)
			_spawn_pvp_projectile(target_node, "magic", RuneSpells.color_for(rune))
			return "magic"
		style = "melee"
	if _player != null and _player.has_method("play_swing"):
		_player.call("play_swing", target_node.global_position.x)
	return "melee"

## Visual-only projectile from the local player to a target node (PvP). Damage
## is server-authoritative (send_pvp_attack), so on_hit is a no-op.
func _spawn_pvp_projectile(target_node: Node2D, kind: String, col: Color) -> void:
	if _player == null or target_node == null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var proj: Node2D = _PROJECTILE.new() as Node2D
	proj.call("setup", (_player as Node2D).global_position, target_node, kind, col)
	proj.set("on_hit", func() -> void: pass)
	scene.add_child(proj)

# ── PvP attacker list (Phase 8) — docked to the LEFT of the combat panel. Every
# player currently hitting you shows as a clickable chip so you can instantly
# switch your attack focus (and so you're never "attacked by a ghost" with chat
# closed). Auto-prunes attackers who stop / leave.
var _pvp_attacker_panel: PanelContainer = null
var _pvp_attacker_list: VBoxContainer = null
var _pvp_attackers: Dictionary = {}   # att_id → {name, node, style, last}
const PVP_ATTACKER_TIMEOUT: float = 12.0

func _build_pvp_attacker_panel() -> void:
	_pvp_attacker_panel = PanelContainer.new()
	_pvp_attacker_panel.add_theme_stylebox_override("panel", _rs(RS_BG, Color(0.85, 0.25, 0.20), 2))
	_pvp_attacker_panel.visible = false
	_pvp_attacker_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_pvp_attacker_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	_pvp_attacker_panel.add_child(vb)
	var hdr := Label.new()
	hdr.text = "⚠ Attacking you"
	hdr.add_theme_color_override("font_color", Color(1.0, 0.40, 0.35))
	hdr.add_theme_font_size_override("font_size", 10)
	vb.add_child(hdr)
	_pvp_attacker_list = VBoxContainer.new()
	_pvp_attacker_list.add_theme_constant_override("separation", 2)
	vb.add_child(_pvp_attacker_list)

func _pvp_glyph_for(style: String) -> String:
	match style:
		"ranged": return "➹"
		"magic":  return "✦"
		_:        return "⚔"

## Record an incoming attacker (from pvp_hit_taken) + auto-focus them if we
## don't already have a target, so the defender immediately sees WHO is on them.
func _pvp_register_attacker(att_id: String, uname: String, style: String) -> void:
	if att_id == "":
		return
	var node: Node2D = null
	for op in get_tree().get_nodes_in_group("other_player"):
		if str(op.get_meta("server_id", "")) == att_id:
			node = op as Node2D
			break
	_pvp_attackers[att_id] = {"name": uname, "node": node, "style": style,
		"last": Time.get_unix_time_from_system()}
	if _pvp_target == null and node != null:
		_select_target(node)
	_refresh_pvp_attacker_panel()

func _refresh_pvp_attacker_panel() -> void:
	if _pvp_attacker_list == null:
		return
	var now := Time.get_unix_time_from_system()
	for aid: String in _pvp_attackers.keys():
		var e: Dictionary = _pvp_attackers[aid]
		if now - float(e["last"]) > PVP_ATTACKER_TIMEOUT \
				or e["node"] == null or not is_instance_valid(e["node"]):
			_pvp_attackers.erase(aid)
	for c in _pvp_attacker_list.get_children():
		c.queue_free()
	if _pvp_attackers.is_empty():
		_pvp_attacker_panel.visible = false
		return
	for aid: String in _pvp_attackers.keys():
		var e: Dictionary = _pvp_attackers[aid]
		var b := Button.new()
		b.text = "%s %s" % [_pvp_glyph_for(str(e["style"])), str(e["name"])]
		b.add_theme_font_size_override("font_size", 10)
		b.tooltip_text = "Attack %s" % str(e["name"])
		# Highlight the one we're currently focused on.
		if _pvp_target != null and e["node"] == _pvp_target:
			b.add_theme_color_override("font_color", RS_GOLD)
		var focus_id := aid
		b.pressed.connect(func() -> void: _pvp_focus_attacker(focus_id))
		_pvp_attacker_list.add_child(b)
	_pvp_attacker_panel.visible = true

func _pvp_focus_attacker(att_id: String) -> void:
	if not _pvp_attackers.has(att_id):
		return
	var node: Variant = _pvp_attackers[att_id]["node"]
	if node == null or not is_instance_valid(node as Node):
		return
	_select_target(node as Node)
	_on_attack_btn_pressed()   # engage (auto-flags us if needed)
	_refresh_pvp_attacker_panel()

## Keep the attacker panel pinned just left of the combat window.
func _position_pvp_attacker_panel() -> void:
	if _pvp_attacker_panel == null or not _pvp_attacker_panel.visible:
		return
	if _combat_window == null or not _combat_window.visible:
		_pvp_attacker_panel.visible = false
		return
	var r := _combat_window.get_global_rect()
	var w := _pvp_attacker_panel.size.x
	_pvp_attacker_panel.global_position = Vector2(maxf(2.0, r.position.x - w - 4.0), r.position.y)

## The incoming attack visual the DEFENDER sees: a projectile flying from the
## attacker toward us (ranged/magic) or the attacker's melee swing.
func _pvp_show_incoming(att_node: Node2D, style: String) -> void:
	if att_node == null or _player == null:
		return
	if style == "ranged" or style == "magic":
		var scene := get_tree().current_scene
		if scene == null:
			return
		var kind := "arrow" if style == "ranged" else "magic"
		var col := Color(0.85, 0.85, 0.9) if style == "ranged" else Color(0.62, 0.40, 0.95)
		var proj: Node2D = _PROJECTILE.new() as Node2D
		proj.call("setup", att_node.global_position, _player as Node2D, kind, col)
		proj.set("on_hit", func() -> void: pass)
		scene.add_child(proj)
	elif att_node.has_method("play_swing"):
		att_node.call("play_swing", (_player as Node2D).global_position.x)

## Set the panel's selected target and make sure the panel is visible. Does
## NOT enter combat — that requires the Attack button. If the target dies
## or becomes invalid the panel auto-clears via _update_combat_ui.
func _select_target(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		_clear_target()
		return
	_selected_target = target
	_target_section.visible = true
	_attack_btn.visible = not _in_combat
	_flee_btn.visible = _in_combat
	_combat_window.visible = true
	_update_combat_ui()

## Drop the current target and hide the target section. Style toggles stay
## visible — the panel itself only collapses on the ✕ button or right-click
## anywhere the player chooses to clear.
func _clear_target() -> void:
	_selected_target = null
	_target_section.visible = false
	_combat_log_box.visible = false
	_attack_btn.visible = true
	_flee_btn.visible = false

func _refresh_style_btns() -> void:
	for sval: Variant in _style_btns:
		var sb := _style_btns[sval] as Button
		# Out-of-resource tint — red font when the style has no ammo
		# (ranged → arrows) / no rune in stock (magic → active rune).
		# Melee never goes out. Applied to the inactive button too so
		# the player can SEE it's broken even when not currently using
		# that style. The first out-of-ammo swing chats once; this is
		# the persistent visual signal so subsequent swings aren't silent.
		var s_str: String = str(sval)
		var out_of_resource: bool = false
		if s_str == "ranged":
			out_of_resource = GameManager.get_item_qty("arrows") <= 0
		elif s_str == "magic":
			var rune_id: String = GameManager.active_rune
			out_of_resource = rune_id == "" or GameManager.get_item_qty(rune_id) <= 0
		var active: bool = sval == _combat_style
		if active:
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_A, RS_GOLD, 2))
			sb.add_theme_color_override("font_color", Color(0.95, 0.30, 0.30) if out_of_resource else RS_GOLD)
		else:
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
			sb.add_theme_color_override("font_color", Color(0.85, 0.30, 0.30) if out_of_resource else RS_TEXT)

func _on_open_combat(monster: Node) -> void:
	_combat_monster   = monster
	# Honor the persistent strip selection — do NOT force back to melee here.
	# The player picked their style BEFORE engaging; respecting it is the whole
	# point of the persistent toggle.
	_combat_style     = GameManager.combat_style
	_combat_atk_timer = 2.4 * GameManager.get_attack_speed_mult()
	_combat_mon_timer = 2.0
	_in_combat        = true
	_combat_server    = false
	_combat_join_pending = false
	_combat_join_wait = 0.0
	_out_of_resource_chatted = false
	_refresh_style_btns()
	_refresh_persist_rune_row()
	# Switch the action button slot: Attack hides, Flee appears. Target
	# section is auto-shown by _select_target — if combat opened via a
	# different path (legacy entry point) we ensure it's set here too.
	_selected_target = monster
	_target_section.visible = true
	_attack_btn.visible = false
	_flee_btn.visible = true
	# Briefly disable Flee until the server acks our join (or the join
	# timeout falls back to local). Without this the button shows but
	# the player can't actually act on it — looks like a stuck button.
	# Re-enabled in _on_mob_state_hud or after COMBAT_JOIN_TIMEOUT.
	_flee_btn.disabled = false   # default — flipped to true below if joining
	_flee_btn.tooltip_text = ""
	_combat_log_box.visible = true
	_combat_log.text = ""   # fresh log per fight
	_combat_window.visible = true
	Events.player_stop_action.emit()
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player != null:
		monster.call("start_pursuit", _player as Node2D)
	# Join the shared fight if the server owns this monster.
	var eid := str(monster.get("entity_id"))
	if not eid.is_empty() and NetworkManager.state == NetworkManager.NetState.LOGGED_IN:
		_combat_join_pending = true
		_flee_btn.disabled = true
		_flee_btn.tooltip_text = "Joining server fight…"
		var mpos := (monster as Node2D).global_position
		NetworkManager.send_monster_join(eid, mpos.x, mpos.y,
			monster.get("max_hp") as int, monster.get("xp_reward") as int,
			str(monster.get("monster_type")), int(monster.get("level")),
			int(monster.get("attack")))
	_update_combat_ui()
	_combat_window.visible = true

func _on_combat_ended() -> void:
	if _combat_monster != null and is_instance_valid(_combat_monster):
		_combat_monster.call("stop_pursuit")
		if _combat_server:
			NetworkManager.send_monster_leave(str(_combat_monster.get("entity_id")))
	_in_combat             = false
	_combat_server         = false
	_combat_join_pending   = false
	_combat_monster        = null
	# Panel stays open. Switch back to "browsing" mode: Attack button
	# restored, Flee hidden, log collapses. The selected target persists
	# so the player can press Attack to re-engage — common in PvE where
	# you might pull, flee, recover, re-engage. The target clears on
	# right-click or when it dies (handled in _update_combat_ui).
	_combat_log_box.visible = false
	_flee_btn.visible = false
	if _selected_target != null and is_instance_valid(_selected_target) \
			and (_selected_target.get("is_alive") as bool):
		_attack_btn.visible = true
	else:
		# Target slain (or vanished). Briefly tell the player so they
		# don't wonder why the panel just emptied, then clear. 2s on a
		# scene-tree timer — small enough not to block the next click,
		# long enough to register.
		if _selected_target != null:
			_combat_log_append("> Target slain — click another to engage.")
			_combat_log_box.visible = true
			get_tree().create_timer(2.0).timeout.connect(func() -> void:
				_clear_target()
				_combat_log_box.visible = false)
		else:
			_clear_target()

# ── Shared-combat signal handlers ─────────────────────────────────────────────
func _combat_target_id() -> String:
	if _combat_monster == null or not is_instance_valid(_combat_monster):
		return ""
	return str(_combat_monster.get("entity_id"))

func _on_mob_state_hud(entity_id: String, _hp: int, _max_hp: int) -> void:
	# Server acknowledged our join — this fight is now server-authoritative.
	if entity_id == _combat_target_id():
		_combat_join_pending = false
		_combat_server       = true
		# Re-enable Flee — server now knows about us, leave is meaningful.
		if _flee_btn != null:
			_flee_btn.disabled = false
			_flee_btn.tooltip_text = ""
		_update_combat_ui()

func _on_mob_hit_hud(entity_id: String, x: float, y: float, amount: int, by_username: String, _hp: int, _max_hp: int, _crit: bool = false, _missed: bool = false) -> void:
	if entity_id != _combat_target_id():
		return
	var mine := by_username == NetworkManager.my_username
	# B1 — server owns the damage; render its number (crit = gold). A miss
	# broadcasts amount 0: log it for us, show nothing floating.
	if _missed:
		if mine:
			_combat_log_append("> You miss.")
		_update_combat_ui()
		return
	# Show every fighter's damage on the shared monster in real time.
	_show_damage_number(Vector2(x, y), amount, mine, _crit)
	if mine:
		_combat_log_append("> You hit for %d dmg  [%s]%s" % [
			amount, _combat_style, "  CRIT!" if _crit else ""])
	_update_combat_ui()

func _on_mob_dead_on_join_hud(entity_id: String, _respawn_in: float) -> void:
	if entity_id == _combat_target_id():
		# Someone else got the kill while we were initiating combat.
		# Combat panel was already open mid-build; rather than collapsing
		# silently, post a top-of-screen toast so the player understands
		# "I didn't break the game, someone beat me to it."
		_show_top_toast("Target already slain — another fighter beat you to it.",
			Color(0.95, 0.78, 0.18))
		_on_combat_ended()

func _on_mob_full_hud(entity_id: String) -> void:
	if entity_id == _combat_target_id():
		_combat_log_append("That fight is full (5 players).")
		_on_combat_ended()

func _update_combat_ui() -> void:
	# Selected target — same renderer for "just clicked, browsing" and
	# "actively fighting". `_combat_monster` takes priority because it's
	# the authoritative engaged target; otherwise we paint _selected_target.
	var t: Node = _combat_monster if _combat_monster != null else _selected_target
	# Defensive: if the selected target was freed between frames (admin
	# delete, chunk stream-out, scene clean), the panel would otherwise
	# keep showing stale label text. Clear it so the UI matches reality.
	if t != null and not is_instance_valid(t):
		if not _in_combat:
			_clear_target()
		return
	if t != null and is_instance_valid(t):
		# PvP branch — OtherPlayer nodes don't carry monster stat fields.
		# Show username + a PvP indicator instead of a HP bar (the server
		# doesn't yet expose defender HP to the attacker).
		if t.is_in_group("other_player"):
			var uname: String = str(t.get_meta("username", "?"))
			var flagged: bool = t.has_method("is_pvp_flagged") \
				and bool(t.call("is_pvp_flagged"))
			_target_name_lbl.text = uname
			_target_lvl_lbl.text  = "Player  " + ("[PvP]" if flagged else "[safe]")
			_target_hp_lbl.text   = ""
			_target_hp_bar.max_value = 1.0
			_tween_bar(_target_hp_bar, 1.0)
			return
		var m_hp  := t.get("current_hp") as int
		var m_max := t.get("max_hp")     as int
		var m_lv  := t.get("level")      as int
		var m_nm  := t.get("display_name") as String
		_target_name_lbl.text  = m_nm
		_target_lvl_lbl.text   = "Level %d" % m_lv
		_target_hp_lbl.text    = "%d / %d HP" % [m_hp, m_max]
		_target_hp_bar.max_value = m_max
		_tween_bar(_target_hp_bar, float(m_hp))
		if not (t.get("is_alive") as bool):
			# Target died — drop selection but keep panel open with style
			# toggles + player HP. _on_combat_ended already runs through
			# the combat path; this catches the browsing-only case.
			if not _in_combat:
				_clear_target()
		else:
			# Live target out of combat — gate the Attack button on
			# proximity + walkability. In combat the button is hidden
			# (Flee takes its slot) so the gate is moot.
			if not _in_combat and _attack_btn != null:
				var gate := _can_engage_target(t)
				var ok: bool = bool(gate.get("ok", false))
				_attack_btn.disabled = not ok
				_attack_btn.tooltip_text = "" if ok else str(gate.get("reason", ""))
				if ok:
					_attack_btn.add_theme_color_override("font_color", RS_GOLD)
				else:
					_attack_btn.add_theme_color_override("font_color", RS_DIM)
	# Player HP — always painted, regardless of target.
	var p_hp  := GameManager.current_hp
	var p_max := GameManager.get_max_hp()
	_combat_plr_lbl.text      = "You   %d / %d HP" % [p_hp, p_max]
	_combat_plr_bar.max_value = p_max
	_tween_bar(_combat_plr_bar, float(p_hp))


## 0.2s gold flash over the combat panel's target section on a kill.
## Pairs with the quest_complete chime fired alongside. Reads as a clear
## "the fight ended in your favor" cue without disrupting the player's
## attention from the next target.
func _flash_target_section_gold() -> void:
	if _target_section == null or not is_instance_valid(_target_section):
		return
	var flash := ColorRect.new()
	flash.color = Color(1.0, 0.85, 0.20, 0.55)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.anchor_right = 1.0
	flash.anchor_bottom = 1.0
	_target_section.add_child(flash)
	var tw := flash.create_tween()
	tw.tween_property(flash, "modulate:a", 0.0, 0.20) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(func() -> void: flash.queue_free())


## Smoothly animate a ProgressBar to its new value over 0.3s with an
## EASE_OUT curve. HP bars currently jump when damage applies — tweening
## adds weight to every hit and reads as "the system is breathing." Kills
## any prior tween on the bar so rapid-fire hits don't stack tweens
## fighting each other.
func _tween_bar(bar: ProgressBar, target_value: float) -> void:
	if bar == null:
		return
	target_value = clampf(target_value, 0.0, bar.max_value)
	if bar.has_meta("_hp_tween"):
		var prev: Variant = bar.get_meta("_hp_tween")
		if prev is Tween and (prev as Tween).is_valid():
			(prev as Tween).kill()
	var tw := create_tween()
	tw.tween_property(bar, "value", target_value, 0.3) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	bar.set_meta("_hp_tween", tw)


## Engage gate. Returns {ok: bool, reason: String}:
##   - ok=false, reason="Too far" — target > ATTACK_INITIATE_RANGE px away
##   - ok=false, reason="No path" — water/coast tile between player & target
##   - ok=true,  reason="Attack" — engagement allowed
##
## The walkability check is a 32-px line sample. Each sample point is asked
## `Ground.biome_at_world()`; an "ocean" or "coast" tile along the line
## means the monster's straight-line chase can't reach the player, so the
## button stays disabled. Same rule the player's `_tile_is_water` uses.
func _can_engage_target(target: Node) -> Dictionary:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player == null or not is_instance_valid(_player) \
			or not (target is Node2D):
		return {"ok": false, "reason": "No target"}
	var p_pos: Vector2 = (_player as Node2D).global_position
	var t_pos: Vector2 = (target as Node2D).global_position
	var dist := p_pos.distance_to(t_pos)
	if dist > ATTACK_INITIATE_RANGE:
		return {"ok": false, "reason": "Too far — get closer (%d / %d tiles)" % [
			int(dist / 32.0), int(ATTACK_INITIATE_RANGE / 32.0)]}
	# Walkability sample. Step from player → target every 32 px and ask
	# the ground node whether the biome is impassable. Ocean/coast/hills/
	# cliffs/walls all block the monster's straight-line chase (matches
	# server-side `_monster_can_step`). Was: only water rejected.
	var ground: Node = get_tree().get_first_node_in_group("ground")
	if ground != null and ground.has_method("biome_at_world") \
			and ground.has_method("is_biome_impassable"):
		var steps := maxi(1, int(dist / 32.0))
		for i: int in range(1, steps):
			var sample := p_pos.lerp(t_pos, float(i) / float(steps))
			var biome: String = ground.call("biome_at_world", sample) as String
			if bool(ground.call("is_biome_impassable", biome)):
				return {"ok": false,
					"reason": "No path — obstacle blocks the route"}
	return {"ok": true, "reason": "Attack"}

func _combat_log_append(line: String) -> void:
	var lines := _combat_log.text.split("\n")
	lines.append(line)
	if lines.size() > 4:
		lines = lines.slice(lines.size() - 4)
	_combat_log.text = "\n".join(lines)

func _combat_tick(delta: float) -> void:
	if _combat_monster == null or not is_instance_valid(_combat_monster):
		# Monster despawned out from under us (admin delete, chunk
		# stream-out, server purge). Surface SOMETHING in the combat log
		# so the player isn't left wondering why their target vanished.
		# Plain "Combat ended." beats a silent panel collapse.
		_combat_log_append("Combat ended — your target has vanished.")
		_on_combat_ended()
		return

	# Fall back to local combat if the server never acknowledges the join.
	if _combat_join_pending:
		_combat_join_wait += delta
		if _combat_join_wait >= COMBAT_JOIN_TIMEOUT:
			_combat_join_pending = false
			_combat_server       = false
			_combat_log_append("[Server slow — fighting locally.]")
			# Local fallback — Flee is meaningful again (just stops the
			# local fight without a server hop).
			if _flee_btn != null:
				_flee_btn.disabled = false
				_flee_btn.tooltip_text = ""

	if not (_combat_monster.get("is_alive") as bool):
		# In server mode the kill reward is granted by the server (via World);
		# only award locally when fighting offline/fallback.
		if not _combat_server:
			_award_combat_xp()
		# Gold flash on the target section + quest-complete chime. The
		# combat log line on its own is too easy to miss in a brawl;
		# the flash + audio cue make the kill register every time.
		_flash_target_section_gold()
		AudioManager.play_ui("quest_complete")
		_on_combat_ended()
		return

	# Player attack (suppressed while waiting on the server to confirm the join)
	if not _combat_join_pending:
		_combat_atk_timer -= delta
		if _combat_atk_timer <= 0.0:
			var mon_pos := (_combat_monster as Node2D).global_position
			var pdist := 99999.0
			if _player != null:
				pdist = mon_pos.distance_to((_player as Node2D).global_position)
			# Melee only connects within ~1 tile; wait (retry soon) until in range.
			if _combat_style == "melee" and pdist > MELEE_HIT_RANGE:
				_combat_atk_timer = 0.25
			else:
				# Swing cadence scales with equipment atk_spd — a bow drops
				# this to ~2.0s, a battleaxe pushes it to ~2.75s.
				_combat_atk_timer = 2.4 * GameManager.get_attack_speed_mult()
				_launch_player_attack(_combat_monster, mon_pos)

	# Monster attack — local-only path. In server mode the authoritative
	# monster_attack broadcast handles damage + sound (see NetworkManager
	# monster_attack handler); running the local tick on top would double-
	# apply damage. This matters more under the new combat flow because the
	# server's aggro chase can pursue across 600+ px, so monster_attack
	# broadcasts arrive reliably.
	if not _combat_server:
		_combat_mon_timer -= delta
		if _combat_mon_timer <= 0.0:
			_combat_mon_timer = 2.0
			var in_range := false
			if _player != null:
				var mdist := (_combat_monster as Node2D).global_position.distance_to((_player as Node2D).global_position)
				in_range = mdist <= MELEE_HIT_RANGE
			if in_range:
				# Guard the player reference — if the player just logged
				# out or was freed (race between the 2s monster tick and
				# logout), skip the damage apply entirely. The vignette
				# and damage number both deref _player; without this
				# guard they spawn at a null position and the combat log
				# would still chat "X hits you for N" against a dead
				# session.
				if _player == null or not is_instance_valid(_player):
					return
				var m_atk := _combat_monster.get("attack") as int
				var raw   := m_atk + randi() % 3
				# Over-level monsters hit harder — the other half of the level
				# gate (v1.5.3), so a boss above you also kills you faster.
				var amp := _level_gap_atk_mult(
					int(_combat_monster.get("level")) if _combat_monster.get("level") != null else 1)
				if amp > 1.0:
					raw = int(round(float(raw) * amp))
				# Split defense (by the monster's style) + block roll (Phase 4).
				var mstyle: String = str(_combat_monster.get("attack_style")) \
					if _combat_monster.get("attack_style") != null else "melee"
				var mit := GameManager.mitigate_incoming(raw, mstyle)
				var mdmg: int = int(mit[0])
				var blk: bool = bool(mit[1])
				GameManager.take_damage(mdmg)
				GameManager.add_xp("vitality", 2)
				Events.monster_attack_landed.emit()
				_combat_log_append("> %s hits you for %d dmg%s" % [
					_combat_monster.get("display_name"), mdmg, "  (Blocked!)" if blk else ""])
				_show_damage_number((_player as Node2D).global_position, mdmg, false)
			else:
				_combat_log_append("> %s closing in..." % _combat_monster.get("display_name"))

	_update_combat_ui()

## Single source of truth for melee reach. The player's swing gate AND
## the monster's bite-back gate both consult this constant — without
## that, the player feels "I can hit but they can't" or vice versa,
## which reads as a bug even when neither system is wrong on its own.
const MELEE_HIT_RANGE := 55.0   # ~1.7 tiles, generous enough that visual reach matches damage reach
const _PROJECTILE := preload("res://scripts/Projectile.gd")

## Begin an attack: play the visible action (swing / projectile) and apply damage
## only when it connects — no instant hits.
##
## Magic / Ranged route through resource checks first. If the player has no
## stocked rune (or active rune fails the level gate, or arrows are out)
## the swing falls back to melee for that one tick so the fight keeps going.
## Admins skip the level gate but still need physical ammo / runes.
# ── Level-gap combat gate (v1.5.3) ───────────────────────────────────────────
# Fixes "a lv14 kills a lv60 boss": swinging up guts your damage, and a monster
# swinging down hits harder — together they make out-levelling content by gear
# impossible without touching per-monster stats.
const LEVEL_GAP_THRESHOLD := 8      # levels you can punch up freely
const LEVEL_GAP_PENALTY   := 0.10   # -10% YOUR damage per level beyond that
const LEVEL_GAP_MIN_MULT  := 0.05   # floor — a chip, never fully zero
const LEVEL_GAP_ATK_AMP   := 0.06   # +6% MONSTER damage per level you're under
const LEVEL_GAP_ATK_CAP   := 4.0

## "Effective combat level" = your best offensive school, so a stray off-style
## swing never makes a legitimately high-level player read as under-levelled.
func _player_combat_level() -> int:
	return maxi(GameManager.get_skill_level("melee"),
		maxi(GameManager.get_skill_level("ranged"),
			GameManager.get_skill_level("magic")))

func _level_gap_dmg_mult(target_level: int) -> float:
	var gap := target_level - _player_combat_level()
	if gap <= LEVEL_GAP_THRESHOLD:
		return 1.0
	return clampf(1.0 - float(gap - LEVEL_GAP_THRESHOLD) * LEVEL_GAP_PENALTY,
		LEVEL_GAP_MIN_MULT, 1.0)

func _level_gap_atk_mult(attacker_level: int) -> float:
	var gap := attacker_level - _player_combat_level()
	if gap <= LEVEL_GAP_THRESHOLD:
		return 1.0
	return minf(1.0 + float(gap - LEVEL_GAP_THRESHOLD) * LEVEL_GAP_ATK_AMP,
		LEVEL_GAP_ATK_CAP)

func _launch_player_attack(mon: Node, mon_pos: Vector2) -> void:
	var style := _combat_style
	var rune_to_consume := ""
	var atk: int
	var xp_skill := style
	var xp_amount := 4
	var proj_color: Color
	var proj_kind := ""

	if style == "magic":
		var rune_id: String = GameManager.active_rune
		var mlv := GameManager.get_skill_level("magic")
		var admin: bool = GameManager.is_admin()
		# Gate 1: rune meets req_lv (admins skip).
		if rune_id == "" or (not admin and mlv < RuneSpells.req_lv(rune_id)):
			style = "melee"
			_warn_out_of_resource("No rune ready — swinging melee.")
		# Gate 2: at least 1 of the chosen rune in stock.
		elif GameManager.get_item_qty(rune_id) <= 0:
			style = "melee"
			_warn_out_of_resource("Out of runes — swinging melee.")
		else:
			rune_to_consume = rune_id
			atk = RuneSpells.damage_for(rune_id, mlv)
			xp_amount = RuneSpells.xp_per_hit(rune_id)
			xp_skill = "magic"
			proj_color = RuneSpells.color_for(rune_id)
			proj_kind = "magic"

	if style == "ranged":
		var rlv := GameManager.get_skill_level("ranged")
		var admin_r: bool = GameManager.is_admin()
		var weapon_lv := _equipped_weapon_min_lv("ranged")
		# Gate: equipped bow meets ranged requirement (admins skip).
		if not admin_r and rlv < weapon_lv:
			Events.chat_message.emit("Requires Ranged Lv %d." % weapon_lv)
			style = "melee"
			_warn_out_of_resource("Bow too strong — swinging melee.")
		elif GameManager.get_item_qty("arrows") <= 0:
			style = "melee"
			_warn_out_of_resource("Out of arrows — swinging melee.")
		else:
			GameManager.remove_item_qty("arrows", 1)
			atk = GameManager.get_attack_power("ranged")
			proj_color = Color(0.85, 0.85, 0.9)
			proj_kind = "arrow"

	if style == "melee":
		atk = GameManager.get_attack_power("melee")
		xp_skill = "melee"

	# PlayerMods damage multiplier — backstory perks / pet auras add up
	# here. 1.0 when nothing is registered, so no behaviour change for
	# vanilla characters. Floor at 1 so a buff never zeros a hit.
	var dmg_mult: float = PlayerMods.dmg_mult(style)
	if dmg_mult != 1.0:
		atk = maxi(1, int(round(float(atk) * dmg_mult)))

	# Level-gap penalty (v1.5.3) — swinging at something far above your combat
	# level guts your damage, so a low-level player can't out-gear the level
	# curve and cheese a high boss. Near-level fights (within the threshold) are
	# untouched. See _level_gap_dmg_mult.
	var gap_mult := _level_gap_dmg_mult(int(mon.get("level")) if mon.get("level") != null else 1)
	if gap_mult < 1.0:
		atk = maxi(1, int(round(float(atk) * gap_mult)))

	# Consume the rune AFTER all gates pass (so a level-gated cast doesn't
	# burn the rune as a side-effect).
	if rune_to_consume != "":
		GameManager.remove_item_qty(rune_to_consume, 1)

	# Hit-chance roll — makes `acc` matter. Formula: 0.55 base + 2% per
	# equipped accuracy point − 1% per point of target defense, clamped to
	# [0.15, 0.95]. On a miss we still count the swing (XP + animation) but
	# skip the damage schedule so the target takes 0.
	var target_def: int = int(mon.get("defense")) if mon.get("defense") != null else 0
	var acc: int = GameManager.get_equipment_bonus("acc")
	var hit_chance: float = clampf(0.55 + float(acc) * 0.02
		- float(target_def) * 0.01, 0.15, 0.95)
	var missed: bool = randf() > hit_chance

	# ⑦/⑧ — remember this swing's XP + skill so the attack intent sent from
	# _apply_player_hit tells the server the exact amount to allow (magic rune XP).
	_swing_xp_pending = xp_amount
	_swing_skill_pending = xp_skill
	GameManager.add_xp(xp_skill, xp_amount)
	GameManager.add_xp("defense", 1)
	Events.attack_swung.emit(style)

	# In SERVER mode the server owns hit/miss (B1) — always send the intent and
	# let it decide. Only the offline/local fallback resolves misses here.
	if missed and not _combat_server:
		Events.chat_message.emit("You miss.")
		# Still play the swing animation for melee so the player sees the
		# whiff. Ranged/magic just skip the projectile — arrows/runes were
		# already consumed above (part of the swing cost).
		if style == "melee" and _player != null and _player.has_method("play_swing"):
			_player.call("play_swing", mon_pos.x)
		return

	# Crit roll (Phase 4) — attacker rolls on the landed hit; 1.5× + gold number.
	var crit_res := GameManager.roll_crit(atk)
	atk = int(crit_res[0])
	var was_crit: bool = bool(crit_res[1])
	if was_crit:
		Events.chat_message.emit("Critical hit!")

	match style:
		"ranged", "magic":
			_spawn_combat_projectile(mon, atk, proj_kind, proj_color, was_crit)
		_:
			if _player != null and _player.has_method("play_swing"):
				_player.call("play_swing", mon_pos.x)
			var t := get_tree().create_timer(0.16)
			t.timeout.connect(func() -> void: _apply_player_hit(mon, atk, was_crit))

## One-line helper for the per-fight chat dedupe — only the first fallback
## of a fight surfaces a message; subsequent swings degrade silently so the
## chat log doesn't spam.
func _warn_out_of_resource(text: String) -> void:
	if _out_of_resource_chatted:
		return
	_out_of_resource_chatted = true
	Events.chat_message.emit(text)

## Returns the highest min_lv among equipped items in slots that contribute
## to the named style. For ranged this is typically the bow in the weapon
## slot. Default 1 means "no gate" — a melee character with no bow equipped
## isn't blocked from a bare-handed ranged toggle.
func _equipped_weapon_min_lv(style: String) -> int:
	var weapon_id := str(GameManager.equipment.get("weapon", ""))
	if weapon_id == "":
		return 1
	var def := GearDB.def_for(weapon_id)
	if def == null or not (def is Dictionary):
		return 1
	var d := def as Dictionary
	if str(d.get("style", "")) != style:
		return 1
	return int(d.get("min_lv", 1))

func _spawn_combat_projectile(mon: Node, atk: int, kind: String, col: Color, is_crit: bool = false) -> void:
	if _player == null:
		_apply_player_hit(mon, atk, is_crit)
		return
	var scene := get_tree().current_scene
	if scene == null:
		_apply_player_hit(mon, atk, is_crit)
		return
	var proj: Node2D = _PROJECTILE.new() as Node2D
	proj.call("setup", (_player as Node2D).global_position, mon as Node2D, kind, col)
	proj.set("on_hit", func() -> void: _apply_player_hit(mon, atk, is_crit))
	scene.add_child(proj)

func _apply_player_hit(mon: Node, atk: int, is_crit: bool = false) -> void:
	if mon == null or not is_instance_valid(mon) or not (mon.get("is_alive") as bool):
		return
	var mon_pos := (mon as Node2D).global_position
	var crit_tag := "  CRIT!" if is_crit else ""
	# Town NPCs (Phase 5b) are ALWAYS server-authoritative: the server owns
	# their hp/death/respawn, applies the reputation penalty, and raises the
	# city watch. Never resolve an NPC kill locally.
	# Caravans (Phase 5c) are server-authoritative too — it owns destruction,
	# the cargo spill, the standing hit, and the bodyguard roll.
	if mon.is_in_group("caravan"):
		NetworkManager.send_caravan_damage(str(mon.get("entity_id")), atk)
		mon.call("flash_hit")
		_combat_log_append("> You strike the caravan for %d dmg%s" % [atk, crit_tag])
		Events.attack_landed.emit(_combat_style)
		_update_combat_ui()
		return
	if mon.is_in_group("npc"):
		NetworkManager.send_npc_damage(str(mon.get("entity_id")),
			str(mon.get("display_name")), atk)
		mon.call("flash_hit")
		_combat_log_append("> You hit %s for %d dmg%s" % [
			str(mon.get("display_name")), atk, crit_tag])
		Events.attack_landed.emit(_combat_style)
		_update_combat_ui()
		return
	if _combat_server:
		# B1 — send an ATTACK INTENT; the server computes the damage and the
		# floating number + log come back via monster_hit (_on_mob_hit_number).
		# ⑦/⑧ — carry this swing's XP + skill so the server's grant ceiling matches.
		NetworkManager.send_monster_attack(str(mon.get("entity_id")),
			_swing_skill_pending, _swing_xp_pending)
		mon.call("flash_hit")
	else:
		var dmg := (mon as Object).call("take_damage", atk) as int
		_combat_log_append("> You hit for %d dmg  [%s]%s" % [dmg, _combat_style, crit_tag])
		_show_damage_number(mon_pos, dmg, true, is_crit)
	Events.attack_landed.emit(_combat_style)
	_update_combat_ui()

func _award_combat_xp() -> void:
	if _combat_monster == null:
		return
	var reward := _combat_monster.get("xp_reward") as int
	GameManager.add_xp(_combat_style, reward)
	GameManager.add_xp("defense",  floori(reward * 0.3))
	GameManager.add_xp("vitality", floori(reward * 0.2))
	_combat_log_append("» Defeated! +%d %s XP" % [reward, _combat_style.capitalize()])

# ── Overworld combat helpers ──────────────────────────────────────────────────

## Floating damage number above the world target. Lives on a dedicated
## CanvasLayer at layer 95 (above HUD UI / QuestLog modal / everything) so
## the readout is never occluded by panels that pop mid-fight.
##
## `from_player` = true  → monster took damage. White/yellow text.
## `from_player` = false → player took damage. Red text + screen vignette.
## `critical`   = true   → gold text, +4 font size. Hook is in place for
##                         when the combat system flags crits; no path
##                         currently sets it.
## When true (set by the 3D client, World3D), the HUD's 2D world-space floating UI
## (damage numbers, heal popups, chat bubbles) is suppressed because it projects
## via the 2D canvas transform, which can't match a perspective 3D camera. World3D
## renders 3D-native versions instead. Default false → the 2D client is unchanged.
var world_ui_3d := false

func _show_damage_number(world_pos: Vector2, amount: int,
		from_player: bool, critical: bool = false) -> void:
	if world_ui_3d:
		return
	if _dmg_layer == null:
		_build_dmg_layer()
	var canvas_pos: Vector2 = get_viewport().get_canvas_transform() * world_pos
	var lbl := Label.new()
	lbl.text = "-%d" % amount
	# Palette per spec: white/yellow for the player's hits, red for the
	# monster's hits, gold for crits. Bold outline for legibility on bright
	# tile backgrounds.
	var col: Color
	var fs: int = 16
	if critical:
		col = Color(1.00, 0.85, 0.20)
		fs  = 20
	elif from_player:
		col = Color(1.00, 0.98, 0.65)   # warm yellow-white
	else:
		col = Color(1.00, 0.30, 0.30)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", fs)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	lbl.add_theme_constant_override("outline_size", 3)
	var start_x: float = canvas_pos.x + randf_range(-8.0, 8.0)
	var start_y: float = canvas_pos.y - 24.0
	lbl.position = Vector2(start_x - 12.0, start_y)
	_dmg_layer.add_child(lbl)
	# Float upward 30 px over 0.8 s, fade to transparent in the same window.
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "position:y", start_y - 30.0, 0.8) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.8) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.chain().tween_callback(func() -> void: lbl.queue_free())
	# Player took damage → flash the screen edges red. The vignette also
	# lives on _dmg_layer so it sits above all other UI.
	if not from_player:
		_show_damage_vignette()

## Green "+N" that floats over the player on a heal (food, etc.). Deliberately
## slower + longer-lived than damage numbers (~2.5 s) so the player can't miss
## that the heal landed.
func _on_player_healed(amount: int) -> void:
	if world_ui_3d:
		return
	if _player == null or not is_instance_valid(_player):
		return
	if _dmg_layer == null:
		_build_dmg_layer()
	var canvas_pos: Vector2 = get_viewport().get_canvas_transform() * (_player as Node2D).global_position
	var lbl := Label.new()
	lbl.text = "+%d" % amount
	lbl.add_theme_color_override("font_color", Color(0.35, 1.00, 0.45))
	lbl.add_theme_font_size_override("font_size", 19)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 1.0))
	lbl.add_theme_constant_override("outline_size", 3)
	var start_x: float = canvas_pos.x + randf_range(-6.0, 6.0)
	var start_y: float = canvas_pos.y - 34.0
	lbl.position = Vector2(start_x - 12.0, start_y)
	_dmg_layer.add_child(lbl)
	# Rise slowly over 2.5 s; hold opaque, then fade only in the last ~0.9 s.
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "position:y", start_y - 42.0, 2.5) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.9) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD).set_delay(1.6)
	tw.chain().tween_callback(func() -> void: lbl.queue_free())

# ── Chat bubbles (Phase 9) — world-space speech over the speaker's head ────────
const _CHAT_BUBBLE := preload("res://scripts/ChatBubble.gd")
## Bubbles from remote players only render when they're within ~15 tiles so the
## whole map doesn't fill with unreadable far-off chatter. Your own always shows.
const CHAT_BUBBLE_RANGE: float = 15.0 * 32.0

func _on_player_chatted(username: String, text: String) -> void:
	if world_ui_3d:
		return   # World3D renders 3D-native chat bubbles
	if text.strip_edges() == "":
		return
	var speaker := _find_chat_speaker(username)
	if speaker == null:
		return
	if username != NetworkManager.my_username and _player != null:
		if (_player as Node2D).global_position.distance_to(speaker.global_position) > CHAT_BUBBLE_RANGE:
			return
	# One bubble per speaker: reuse the existing node (resets its timer + text)
	# rather than stacking, so rapid messages replace cleanly.
	var existing := speaker.get_node_or_null("ChatBubble")
	if existing != null:
		existing.call("setup", text)
		return
	var bubble := _CHAT_BUBBLE.new() as Node2D
	bubble.name = "ChatBubble"
	speaker.add_child(bubble)
	bubble.call("setup", text)

## The world node for a chat username: the local Player for our own messages,
## otherwise the matching OtherPlayer. null if not currently in the scene.
func _find_chat_speaker(username: String) -> Node2D:
	if username == NetworkManager.my_username:
		var players := get_tree().get_nodes_in_group("player")
		return players[0] as Node2D if not players.is_empty() else null
	for op in get_tree().get_nodes_in_group("other_player"):
		if str(op.get_meta("username", "")) == username:
			return op as Node2D
	return null

## Lazy-init the dedicated CanvasLayer for damage numbers + vignette. Layer
## 95 puts it above QuestLog (80) and quest dialog (85) so combat feedback
## never gets hidden behind a modal that was already open.
func _build_dmg_layer() -> void:
	_dmg_layer = CanvasLayer.new()
	_dmg_layer.layer = 95
	get_tree().root.add_child.call_deferred(_dmg_layer)

## Red screen-edge vignette — four ColorRects (top/bottom/left/right) that
## fade from full alpha to transparent over 0.2 s. Approximates a real
## radial vignette without needing a shader. Spawned only on player hits.
func _show_damage_vignette() -> void:
	if _dmg_layer == null:
		_build_dmg_layer()
	# Punchy 0.10s camera shake to pair with the red vignette — red bars
	# alone don't sell impact. ±4 px feels weighty without becoming
	# nauseating. Targets the player's Camera2D via offset, which the
	# existing _update_camera helper writes to.
	_shake_camera(4.0, 0.10)
	# `wrapper` rather than `wrap` — strict mode flags `wrap` as a shadow
	# of @GlobalScope.wrap() (a math helper).
	var wrapper := Control.new()
	wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dmg_layer.add_child(wrapper)
	var thickness := 80.0
	var col := Color(0.95, 0.10, 0.10, 0.55)
	# Top bar
	var top := ColorRect.new()
	top.color = col
	top.anchor_left = 0.0; top.anchor_right = 1.0
	top.offset_bottom = thickness
	wrapper.add_child(top)
	# Bottom bar
	var bot := ColorRect.new()
	bot.color = col
	bot.anchor_left = 0.0; bot.anchor_right = 1.0
	bot.anchor_top  = 1.0; bot.anchor_bottom = 1.0
	bot.offset_top  = -thickness
	wrapper.add_child(bot)
	# Left bar
	var lft := ColorRect.new()
	lft.color = col
	lft.anchor_top = 0.0; lft.anchor_bottom = 1.0
	lft.offset_right = thickness
	wrapper.add_child(lft)
	# Right bar
	var rgt := ColorRect.new()
	rgt.color = col
	rgt.anchor_left  = 1.0; rgt.anchor_right = 1.0
	rgt.anchor_top   = 0.0; rgt.anchor_bottom = 1.0
	rgt.offset_left  = -thickness
	wrapper.add_child(rgt)
	# Single tween on the wrapping Control's modulate handles all four bars
	# at once. 0.2 s fade per spec.
	var tw := wrapper.create_tween()
	tw.tween_property(wrapper, "modulate:a", 0.0, 0.2) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.chain().tween_callback(func() -> void: wrapper.queue_free())


## Brief camera offset shake on player damage. Looks up the player's
## Camera2D (it lives as a child of Player), records the current offset,
## tweens it to a random direction, then back to zero. 8 small jolts in
## one short window give the "kick" feel without the slow swing a single
## big offset produces.
func _shake_camera(magnitude_px: float, duration_s: float) -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		return
	var cam: Camera2D = null
	for child in _player.get_children():
		if child is Camera2D:
			cam = child as Camera2D
			break
	if cam == null:
		return
	# Eight jolts across the duration window — short enough to read as a
	# single hit rather than a sustained earthquake.
	var steps := 8
	var step_dur: float = duration_s / float(steps)
	var tw := create_tween()
	for i in range(steps):
		var ang := randf() * TAU
		var off := Vector2(cos(ang), sin(ang)) * (magnitude_px * (1.0 - float(i) / float(steps)))
		tw.tween_property(cam, "offset", off, step_dur).set_trans(Tween.TRANS_SINE)
	tw.tween_property(cam, "offset", Vector2.ZERO, step_dur)


func _on_player_died() -> void:
	var flash := ColorRect.new()
	flash.color = Color(0.8, 0.0, 0.0, 0.50)
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(flash)
	var tw := flash.create_tween()
	tw.tween_property(flash, "modulate:a", 0.0, 1.2).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(func() -> void: flash.queue_free())


# ── Camera lock button (top-right, visible only in free-cam mode) ─────────────
func _build_cam_lock_button() -> void:
	_cam_lock_btn = Button.new()
	_cam_lock_btn.text    = "⊕ Lock Camera"
	_cam_lock_btn.visible = false
	_cam_lock_btn.anchor_left   = 0.5; _cam_lock_btn.anchor_right  = 0.5
	_cam_lock_btn.anchor_top    = 1.0; _cam_lock_btn.anchor_bottom = 1.0
	_cam_lock_btn.offset_left   = -72; _cam_lock_btn.offset_right  = 72
	_cam_lock_btn.offset_top    = -42; _cam_lock_btn.offset_bottom = -14
	_cam_lock_btn.add_theme_stylebox_override("normal",  _rs(Color(0.06, 0.04, 0.01, 0.92), RS_GOLD, 2))
	_cam_lock_btn.add_theme_stylebox_override("hover",   _rs(Color(0.16, 0.12, 0.04, 0.95), RS_GOLD, 2))
	_cam_lock_btn.add_theme_stylebox_override("pressed", _rs(Color(0.22, 0.16, 0.06, 0.95), RS_GOLD, 2))
	_cam_lock_btn.add_theme_stylebox_override("focus",   _rs(Color(0.06, 0.04, 0.01, 0.92), RS_GOLD, 2))
	_cam_lock_btn.add_theme_color_override("font_color",         RS_GOLD)
	_cam_lock_btn.add_theme_color_override("font_hover_color",   Color(1, 1, 0.6))
	_cam_lock_btn.add_theme_color_override("font_pressed_color", RS_TEXT)
	_cam_lock_btn.add_theme_font_size_override("font_size", 11)
	_cam_lock_btn.pressed.connect(_on_cam_lock_pressed)
	add_child(_cam_lock_btn)

func _on_cam_lock_pressed() -> void:
	if _player != null:
		_player.call("lock_camera")

func _on_camera_free_mode_changed(is_free: bool) -> void:
	if _cam_lock_btn != null:
		_cam_lock_btn.visible = is_free

# ── REPUTATION tab (Phase 5a) ─────────────────────────────────────────────────
## Standing with each of the five towns. Server is authoritative: the snapshot
## arrives on login, after a standing-changing quest, and on tab open.
## `effective` blends your personal standing with a share of your warband's —
## that's why warband deeds move every member's number.
var _rep_list: VBoxContainer = null
var _rep_hint: Label = null

## Tier colours, worst → best. Keys match the server's REP_TIERS names.
const _REP_TIER_COLORS: Dictionary = {
	"Hated":      Color(0.90, 0.25, 0.22),
	"Hostile":    Color(0.88, 0.40, 0.24),
	"Unfriendly": Color(0.85, 0.62, 0.28),
	"Neutral":    Color(0.72, 0.70, 0.58),
	"Friendly":   Color(0.55, 0.82, 0.45),
	"Honored":    Color(0.40, 0.85, 0.55),
	"Revered":    Color(0.35, 0.80, 0.85),
	"Exalted":    Color(1.00, 0.85, 0.25),
}

func _build_reputation_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tab_title("Reputation"))
	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 260)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_rep_list = VBoxContainer.new()
	_rep_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rep_list.add_theme_constant_override("separation", 5)
	scroll.add_child(_rep_list)

	_rep_hint = Label.new()
	_rep_hint.text = "Complete a town's quests to raise its standing."
	_rep_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rep_hint.add_theme_color_override("font_color", RS_DIM)
	_rep_hint.add_theme_font_size_override("font_size", 8)
	root.add_child(_rep_hint)

	Events.reputation_updated.connect(_on_reputation_updated)
	return root

func _on_reputation_updated(towns: Array, in_warband: bool, warbands: Array) -> void:
	if _rep_list == null:
		return
	for c in _rep_list.get_children():
		c.queue_free()
	if towns.is_empty():
		var empty := Label.new()
		empty.text = "No standing recorded yet."
		empty.add_theme_color_override("font_color", RS_DIM)
		empty.add_theme_font_size_override("font_size", 10)
		_rep_list.add_child(empty)
	else:
		for t: Variant in towns:
			if t is Dictionary:
				_rep_list.add_child(_make_rep_card(t as Dictionary))
	# Warband standings (Phase 5c) — only warbands you've tangled with appear.
	if not warbands.is_empty():
		var hdr := Label.new()
		hdr.text = "Warbands"
		hdr.add_theme_color_override("font_color", RS_DIM)
		hdr.add_theme_font_size_override("font_size", 9)
		_rep_list.add_child(hdr)
		for w: Variant in warbands:
			if w is Dictionary:
				_rep_list.add_child(_make_warband_rep_card(w as Dictionary))
	if _rep_hint != null:
		_rep_hint.text = ("Standing = your own deeds + a share of your warband's."
			if in_warband else
			"Complete a town's quests to raise its standing. Join a warband and its deeds count too.")

func _make_rep_card(t: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _rs(Color(0.13, 0.10, 0.05), RS_BORDER, 1))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)

	var tier := str(t.get("tier", "Neutral"))
	var tier_col: Color = _REP_TIER_COLORS.get(tier, RS_TEXT)
	var eff := int(t.get("effective", 0))

	var hdr := HBoxContainer.new()
	vb.add_child(hdr)
	var nm := Label.new()
	nm.text = str(t.get("name", "?"))
	nm.add_theme_color_override("font_color", RS_GOLD)
	nm.add_theme_font_size_override("font_size", 11)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(nm)
	if bool(t.get("held_by_us", false)):
		var flag := Label.new()
		flag.text = "⚑ held"
		flag.add_theme_color_override("font_color", RS_GREEN)
		flag.add_theme_font_size_override("font_size", 8)
		hdr.add_child(flag)
	var tier_lbl := Label.new()
	tier_lbl.text = tier
	tier_lbl.add_theme_color_override("font_color", tier_col)
	tier_lbl.add_theme_font_size_override("font_size", 11)
	hdr.add_child(tier_lbl)

	# Progress toward the next tier (or a full bar at the top tier).
	var next_v: Variant = t.get("next_at", null)
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 10)
	bar.show_percentage = false
	bar.min_value = float(int(t.get("floor", -6000)))
	bar.max_value = float(int(t.get("ceil", 12000)))
	bar.value = float(eff)
	bar.add_theme_stylebox_override("background", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
	var fill := StyleBoxFlat.new()
	fill.bg_color = tier_col
	bar.add_theme_stylebox_override("fill", fill)
	vb.add_child(bar)

	var detail := Label.new()
	var next_txt := "max tier" if next_v == null else "next at %d" % int(next_v)
	detail.text = "%d  (you %d · warband %d)  —  %s" % [
		eff, int(t.get("personal", 0)), int(t.get("warband", 0)), next_txt]
	detail.add_theme_color_override("font_color", RS_DIM)
	detail.add_theme_font_size_override("font_size", 8)
	vb.add_child(detail)
	return card

## Compact card for player↔warband standing (Phase 5c). Only warbands you've
## made an enemy (or friend) of appear, so this stays short.
func _make_warband_rep_card(w: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _rs(Color(0.11, 0.07, 0.11), RS_BORDER, 1))
	var hb := HBoxContainer.new()
	card.add_child(hb)
	var nm := Label.new()
	nm.text = str(w.get("name", "A warband"))
	nm.add_theme_color_override("font_color", RS_TEXT)
	nm.add_theme_font_size_override("font_size", 10)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(nm)
	var tier := str(w.get("tier", "Neutral"))
	var tier_col: Color = _REP_TIER_COLORS.get(tier, RS_TEXT)
	var val := Label.new()
	val.text = "%s  (%d)" % [tier, int(w.get("value", 0))]
	val.add_theme_color_override("font_color", tier_col)
	val.add_theme_font_size_override("font_size", 10)
	hb.add_child(val)
	return card

# ── THRALL tab ────────────────────────────────────────────────────────────────
func _make_opt(font_size: int = 10) -> OptionButton:
	var o := OptionButton.new()
	o.add_theme_font_size_override("font_size", font_size)
	o.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	o.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 2))
	o.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   2))
	o.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	o.add_theme_color_override("font_color", RS_TEXT)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return o

## Thrall roster tab (Phase 10) — one card per owned thrall (name / tier / Lv /
## HP / task) with Assign + Bag; a Buy-Slot button expands capacity 2→5.
const _THRALL_SLOT_COST := {3: 25000, 4: 75000, 5: 150000}

func _build_thrall_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := _tab_title("Thralls")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	_thrall_slot_lbl = Label.new()
	_thrall_slot_lbl.add_theme_color_override("font_color", RS_DIM)
	_thrall_slot_lbl.add_theme_font_size_override("font_size", 10)
	title_row.add_child(_thrall_slot_lbl)
	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 250)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_thrall_roster_list = VBoxContainer.new()
	_thrall_roster_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thrall_roster_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_thrall_roster_list)

	_thrall_buy_slot_btn = Button.new()
	_thrall_buy_slot_btn.add_theme_font_size_override("font_size", 10)
	_thrall_buy_slot_btn.pressed.connect(func() -> void: NetworkManager.send_thrall_buy_slot())
	root.add_child(_thrall_buy_slot_btn)

	var info := Label.new()
	info.text = "Thralls work while you're offline. Combat thralls take damage — put food in their bag or they can DIE and be lost."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", RS_DIM)
	info.add_theme_font_size_override("font_size", 8)
	root.add_child(info)

	Events.thralls_updated.connect(_refresh_thrall_tab)
	_refresh_thrall_tab()
	return root

func _refresh_thrall_tab() -> void:
	if _thrall_roster_list == null:
		return
	for c in _thrall_roster_list.get_children():
		c.queue_free()
	var roster: Array = ThrallManager.roster
	if roster.is_empty():
		var empty := Label.new()
		empty.text = "No thralls yet.\nDefeat monsters for a chance to take one\n(bandits for a Tier 1 worker)."
		empty.add_theme_color_override("font_color", RS_DIM)
		empty.add_theme_font_size_override("font_size", 10)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_thrall_roster_list.add_child(empty)
	else:
		for t: Variant in roster:
			if t is Dictionary:
				_thrall_roster_list.add_child(_make_thrall_card(t as Dictionary))
	if _thrall_slot_lbl != null:
		_thrall_slot_lbl.text = "%d / %d thralls" % [roster.size(), ThrallManager.slots]
	if _thrall_buy_slot_btn != null:
		if ThrallManager.slots < ThrallManager.max_slots:
			var nxt := ThrallManager.slots + 1
			_thrall_buy_slot_btn.text = "Buy Thrall Slot %d  (%dg)" % [nxt, int(_THRALL_SLOT_COST.get(nxt, 0))]
			_thrall_buy_slot_btn.visible = true
		else:
			_thrall_buy_slot_btn.visible = false

func _make_thrall_card(t: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _rs(Color(0.16, 0.11, 0.05), RS_BORDER, 1))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)
	var hdr := Label.new()
	hdr.text = "%s   —   Tier %d · Lv %d" % [str(t.get("name", "?")), int(t.get("tier", 1)), int(t.get("level", 1))]
	hdr.add_theme_color_override("font_color", RS_GOLD)
	hdr.add_theme_font_size_override("font_size", 11)
	vb.add_child(hdr)
	var hp := int(t.get("hp", 0))
	var mhp := maxi(1, int(t.get("max_hp", 1)))
	var hp_lbl := Label.new()
	hp_lbl.text = "❤ %d / %d" % [hp, mhp]
	hp_lbl.add_theme_color_override("font_color", RS_GREEN if hp * 3 > mhp else Color(0.9, 0.4, 0.35))
	hp_lbl.add_theme_font_size_override("font_size", 9)
	vb.add_child(hp_lbl)
	var job := str(t.get("job", ""))
	var target := str(t.get("target", ""))
	var task_lbl := Label.new()
	task_lbl.text = "Idle — assign a task" if job == "" else "Task: %s — %s" % [job.capitalize(), target.capitalize()]
	task_lbl.add_theme_color_override("font_color", RS_TEXT if job != "" else RS_DIM)
	task_lbl.add_theme_font_size_override("font_size", 9)
	vb.add_child(task_lbl)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 4)
	var assign := Button.new()
	assign.text = "Assign"
	assign.add_theme_font_size_override("font_size", 9)
	assign.pressed.connect(func() -> void: _show_thrall_assign_dialog(t))
	btns.add_child(assign)
	var bag := Button.new()
	bag.text = "Bag (%d)" % (t.get("backpack", []) as Array).size()
	bag.add_theme_font_size_override("font_size", 9)
	bag.pressed.connect(func() -> void: _show_thrall_backpack_dialog(t))
	btns.add_child(bag)
	vb.add_child(btns)
	return card

## Assign dialog — job dropdown + target dropdown filtered to the thrall's tier.
func _show_thrall_assign_dialog(t: Dictionary) -> void:
	var tid := str(t.get("id", ""))
	var thr_tier := int(t.get("tier", 1))
	var overlay := CanvasLayer.new()
	overlay.layer = 204
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_GOLD, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -150; panel.offset_right = 150
	panel.offset_top = -148;  panel.offset_bottom = 148
	overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)
	var tl := Label.new()
	tl.text = "Assign %s  (Tier %d)" % [str(t.get("name", "?")), thr_tier]
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.add_theme_color_override("font_color", RS_GOLD)
	tl.add_theme_font_size_override("font_size", 12)
	vb.add_child(tl)
	var job_opt := _make_opt()
	for j in ThrallManager.TASK_TYPES:
		job_opt.add_item((j as Dictionary)["label"] as String)
	vb.add_child(job_opt)
	var tgt_opt := _make_opt()
	vb.add_child(tgt_opt)
	# Town picker — where the thrall works (V1.5.5). Only towns that offer the
	# chosen target's tier are listed (gated per TOWN_RESOURCES).
	var town_lbl := Label.new()
	town_lbl.text = "Send to:"
	town_lbl.add_theme_color_override("font_color", RS_DIM)
	town_lbl.add_theme_font_size_override("font_size", 10)
	vb.add_child(town_lbl)
	var town_opt := _make_opt()
	vb.add_child(town_opt)
	var hint := Label.new()
	hint.add_theme_color_override("font_color", Color(0.90, 0.55, 0.35))
	hint.add_theme_font_size_override("font_size", 9)
	hint.visible = false
	vb.add_child(hint)
	var ok := Button.new()
	ok.text = "Assign"
	ok.add_theme_font_size_override("font_size", 11)
	vb.add_child(ok)
	var cur_town := str(t.get("town", ""))
	# Parallel arrays: tgt_ids/tgt_tiers ↔ tgt_opt items; town_ids ↔ town_opt.
	var tgt_ids: Array = []
	var tgt_tiers: Array = []
	var town_ids: Array = []
	var repop_towns := func() -> void:
		var jid: String = (ThrallManager.TASK_TYPES[job_opt.selected] as Dictionary)["id"] as String
		var cur_tier := 1
		if tgt_opt.selected >= 0 and tgt_opt.selected < tgt_tiers.size():
			cur_tier = int(tgt_tiers[tgt_opt.selected])
		town_opt.clear()
		town_ids.clear()
		for tw: Variant in ThrallManager.TOWNS:
			var twid := str((tw as Dictionary)["id"])
			if ThrallManager.town_offers(twid, jid, cur_tier):
				town_opt.add_item(str((tw as Dictionary)["label"]))
				town_ids.append(twid)
		if town_ids.has(cur_town):
			town_opt.selected = town_ids.find(cur_town)
		var none: bool = town_ids.is_empty()
		hint.text = "No town offers this yet."
		hint.visible = none
		ok.disabled = none
	var repop := func() -> void:
		tgt_opt.clear()
		tgt_ids.clear()
		tgt_tiers.clear()
		var jid: String = (ThrallManager.TASK_TYPES[job_opt.selected] as Dictionary)["id"] as String
		for tgt: Variant in (ThrallManager.TASK_TARGETS.get(jid, []) as Array):
			var td := tgt as Dictionary
			if int(td.get("tier", 1)) <= thr_tier:
				tgt_opt.add_item(str(td["label"]))
				tgt_ids.append(str(td["id"]))
				tgt_tiers.append(int(td.get("tier", 1)))
		repop_towns.call()
	repop.call()
	job_opt.item_selected.connect(func(_i: int) -> void: repop.call())
	tgt_opt.item_selected.connect(func(_i: int) -> void: repop_towns.call())
	ok.pressed.connect(func() -> void:
		if tgt_opt.selected >= 0 and tgt_opt.selected < tgt_ids.size() \
				and town_opt.selected >= 0 and town_opt.selected < town_ids.size():
			var jid: String = (ThrallManager.TASK_TYPES[job_opt.selected] as Dictionary)["id"] as String
			NetworkManager.send_thrall_assign(tid, jid,
				str(tgt_ids[tgt_opt.selected]), str(town_ids[town_opt.selected]))
		overlay.queue_free())
	var unassign := Button.new()
	unassign.text = "Unassign (idle)"
	unassign.add_theme_font_size_override("font_size", 10)
	unassign.pressed.connect(func() -> void:
		NetworkManager.send_thrall_assign(tid, "", "")
		overlay.queue_free())
	vb.add_child(unassign)

## Backpack dialog — stock FOOD in (from inventory) + take loot OUT.
func _show_thrall_backpack_dialog(t: Dictionary) -> void:
	var tid := str(t.get("id", ""))
	var overlay := CanvasLayer.new()
	overlay.layer = 204
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -160; panel.offset_right = 160
	panel.offset_top = -180;  panel.offset_bottom = 180
	overlay.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	panel.add_child(root)
	var tl := Label.new()
	tl.text = "%s's Bag" % str(t.get("name", "?"))
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.add_theme_color_override("font_color", RS_GOLD)
	tl.add_theme_font_size_override("font_size", 12)
	root.add_child(tl)
	# Backpack contents (take out).
	var bp_hdr := Label.new()
	bp_hdr.text = "In the bag (tap to take):"
	bp_hdr.add_theme_color_override("font_color", RS_DIM)
	bp_hdr.add_theme_font_size_override("font_size", 9)
	root.add_child(bp_hdr)
	var pack: Array = t.get("backpack", []) as Array
	if pack.is_empty():
		var e := Label.new()
		e.text = "  (empty)"
		e.add_theme_color_override("font_color", RS_DIM)
		e.add_theme_font_size_override("font_size", 9)
		root.add_child(e)
	for it: Variant in pack:
		var bd := it as Dictionary
		var bid := str(bd.get("id", ""))
		var bq := int(bd.get("qty", 0))
		var r := Button.new()
		r.text = "%s x%d" % [str(bd.get("name", bid)), bq]
		r.alignment = HORIZONTAL_ALIGNMENT_LEFT
		r.add_theme_font_size_override("font_size", 9)
		r.pressed.connect(func() -> void:
			NetworkManager.send_thrall_backpack_withdraw(tid, bid, bq)
			overlay.queue_free())
		root.add_child(r)
	root.add_child(HSeparator.new())
	# Food from inventory (deposit).
	var fd_hdr := Label.new()
	fd_hdr.text = "Add food (tap to give):"
	fd_hdr.add_theme_color_override("font_color", RS_DIM)
	fd_hdr.add_theme_font_size_override("font_size", 9)
	root.add_child(fd_hdr)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 120)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var food_list := VBoxContainer.new()
	food_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(food_list)
	var any_food := false
	for item: Dictionary in GameManager.inventory:
		var iid := str(item.get("id", ""))
		if not GameManager.FOOD_HEAL.has(iid):
			continue
		any_food = true
		var iq := int(item.get("qty", 0))
		var r := Button.new()
		r.text = "%s x%d" % [str(item.get("name", iid)), iq]
		r.alignment = HORIZONTAL_ALIGNMENT_LEFT
		r.add_theme_font_size_override("font_size", 9)
		r.pressed.connect(func() -> void:
			NetworkManager.send_thrall_backpack_deposit(tid, iid, iq)
			overlay.queue_free())
		food_list.add_child(r)
	if not any_food:
		var e := Label.new()
		e.text = "  No food in your inventory."
		e.add_theme_color_override("font_color", RS_DIM)
		e.add_theme_font_size_override("font_size", 9)
		food_list.add_child(e)

# ── Idle summary popup ────────────────────────────────────────────────────────
func _show_idle_summary(data: Dictionary) -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 200
	add_child(overlay)

	# Dark full-screen backdrop
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.anchor_right  = 1.0
	bg.anchor_bottom = 1.0
	overlay.add_child(bg)

	# Panel
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left   = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left   = -160; panel.offset_right  = 160
	panel.offset_top    = -200; panel.offset_bottom = 200
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "While You Were Away"
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# Time offline
	var secs: int = int(data.get("elapsed_seconds", 0))
	var hrs  := int(secs / 3600.0)
	var mins := int((secs % 3600) / 60.0)
	var time_lbl := Label.new()
	time_lbl.text = "Time offline: %dh %dm" % [hrs, mins]
	time_lbl.add_theme_color_override("font_color", RS_TEXT)
	time_lbl.add_theme_font_size_override("font_size", 10)
	vbox.add_child(time_lbl)

	# XP gained
	var xp_gained: Dictionary = data.get("xp_gained", {}) as Dictionary
	if not xp_gained.is_empty():
		var xp_title := Label.new()
		xp_title.text = "XP Gained:"
		xp_title.add_theme_color_override("font_color", RS_DIM)
		xp_title.add_theme_font_size_override("font_size", 9)
		vbox.add_child(xp_title)
		for skill: Variant in xp_gained.keys():
			var row := HBoxContainer.new()
			vbox.add_child(row)
			var sk_lbl := Label.new()
			sk_lbl.text = "  " + str(skill).capitalize()
			sk_lbl.add_theme_color_override("font_color", RS_TEXT)
			sk_lbl.add_theme_font_size_override("font_size", 10)
			sk_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(sk_lbl)
			var val_lbl := Label.new()
			val_lbl.text = "+%d" % int(xp_gained[skill])
			val_lbl.add_theme_color_override("font_color", RS_GREEN)
			val_lbl.add_theme_font_size_override("font_size", 10)
			row.add_child(val_lbl)

	# Items collected
	var items: Dictionary = data.get("items_gained", {}) as Dictionary
	if not items.is_empty():
		var it_title := Label.new()
		it_title.text = "Items Collected:"
		it_title.add_theme_color_override("font_color", RS_DIM)
		it_title.add_theme_font_size_override("font_size", 9)
		vbox.add_child(it_title)
		for item: Variant in items.keys():
			var row := HBoxContainer.new()
			vbox.add_child(row)
			var it_lbl := Label.new()
			it_lbl.text = "  " + str(item).capitalize()
			it_lbl.add_theme_color_override("font_color", RS_TEXT)
			it_lbl.add_theme_font_size_override("font_size", 10)
			it_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(it_lbl)
			var qty_lbl := Label.new()
			qty_lbl.text = "×%d" % int(items[item])
			qty_lbl.add_theme_color_override("font_color", RS_TEXT)
			qty_lbl.add_theme_font_size_override("font_size", 10)
			row.add_child(qty_lbl)

	# Deaths
	var deaths: int = int(data.get("deaths", 0))
	if deaths > 0:
		var d_lbl := Label.new()
		d_lbl.text = "Deaths: %d  (respawned at Bjorn's Landing)" % deaths
		d_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		d_lbl.add_theme_font_size_override("font_size", 10)
		d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(d_lbl)

	# Stop reason
	var reason: String = str(data.get("stop_reason", ""))
	if not reason.is_empty():
		var r_lbl := Label.new()
		r_lbl.text = "Stopped: " + reason
		r_lbl.add_theme_color_override("font_color", RS_DIM)
		r_lbl.add_theme_font_size_override("font_size", 9)
		r_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(r_lbl)

	vbox.add_child(HSeparator.new())

	# Continue button
	var cont_btn := Button.new()
	cont_btn.text = "Continue"
	cont_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_GOLD.darkened(0.3), 2))
	cont_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
	cont_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD, 2))
	cont_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_GOLD.darkened(0.3), 2))
	cont_btn.add_theme_color_override("font_color", RS_GOLD)
	cont_btn.add_theme_font_size_override("font_size", 11)
	cont_btn.pressed.connect(func() -> void: overlay.queue_free())
	vbox.add_child(cont_btn)

# ── Thrall offline summary popup (Phase 10b) ──────────────────────────────────
## Per-thrall report of offline work: XP earned (fed to your skills), levels
## gained, loot banked in each thrall's bag, and any that DIED for lack of food.
func _show_thrall_summary(summary: Dictionary) -> void:
	var reports: Array = summary.get("thralls", []) as Array
	if reports.is_empty():
		return

	var overlay := CanvasLayer.new()
	overlay.layer = 200
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	overlay.add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -180; panel.offset_right = 180
	panel.offset_top = -210;  panel.offset_bottom = 210
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Your Thralls Worked"
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var secs: int = int(summary.get("elapsed_seconds", 0))
	var time_lbl := Label.new()
	time_lbl.text = "Over %dh %dm away" % [int(secs / 3600.0), int((secs % 3600) / 60.0)]
	time_lbl.add_theme_color_override("font_color", RS_DIM)
	time_lbl.add_theme_font_size_override("font_size", 9)
	time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(time_lbl)
	vbox.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 5)
	scroll.add_child(list)

	for rv: Variant in reports:
		if not (rv is Dictionary):
			continue
		var rep := rv as Dictionary
		var dead := bool(rep.get("dead", false))
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel",
			_rs(Color(0.20, 0.08, 0.05) if dead else Color(0.16, 0.11, 0.05), RS_BORDER, 1))
		var cb := VBoxContainer.new()
		cb.add_theme_constant_override("separation", 1)
		card.add_child(cb)
		var lv_before := int(rep.get("level_before", 1))
		var lv_after := int(rep.get("level_after", 1))
		var hdr := Label.new()
		var lv_txt := "Lv %d" % lv_after if lv_after <= lv_before else "Lv %d → %d" % [lv_before, lv_after]
		hdr.text = "%s  (Tier %d · %s)" % [str(rep.get("name", "?")), int(rep.get("tier", 1)), lv_txt]
		hdr.add_theme_color_override("font_color", Color(0.95, 0.45, 0.4) if dead else RS_GOLD)
		hdr.add_theme_font_size_override("font_size", 11)
		cb.add_child(hdr)
		var note := Label.new()
		note.text = str(rep.get("note", ""))
		note.add_theme_color_override("font_color", RS_TEXT)
		note.add_theme_font_size_override("font_size", 9)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cb.add_child(note)
		if not dead:
			var gain := Label.new()
			gain.text = "  +%d %s XP → you  ·  %d loot in bag" % [
				int(rep.get("player_xp", 0)), str(rep.get("skill", "")).capitalize(),
				int(rep.get("loot", 0))]
			gain.add_theme_color_override("font_color", RS_GREEN)
			gain.add_theme_font_size_override("font_size", 9)
			cb.add_child(gain)
		list.add_child(card)

	vbox.add_child(HSeparator.new())
	var cont := Button.new()
	cont.text = "Continue"
	cont.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_GOLD.darkened(0.3), 2))
	cont.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
	cont.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD, 2))
	cont.add_theme_color_override("font_color", RS_GOLD)
	cont.add_theme_font_size_override("font_size", 11)
	cont.pressed.connect(func() -> void: overlay.queue_free())
	vbox.add_child(cont)

# ── BANK window ───────────────────────────────────────────────────────────────
func _build_bank_window() -> void:
	_bank_window = PanelContainer.new()
	_bank_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_bank_window.anchor_left   = 0.5; _bank_window.anchor_right  = 0.5
	_bank_window.anchor_top    = 0.5; _bank_window.anchor_bottom = 0.5
	_bank_window.offset_left   = -240; _bank_window.offset_right  = 240
	_bank_window.offset_top    = -260; _bank_window.offset_bottom = 260
	_bank_window.visible       = false
	add_child(_bank_window)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	_bank_window.add_child(outer)

	# Title row
	var title_row := HBoxContainer.new()
	outer.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "Bank"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_color_override("font_color", RS_GOLD)
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_row.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(36, 36)   # touch-friendly (was 26×26)
	close_btn.add_theme_font_size_override("font_size", 14)
	close_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	close_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 2))
	close_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   2))
	close_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	close_btn.add_theme_color_override("font_color", RS_DIM)
	close_btn.pressed.connect(func() -> void: _bank_window.visible = false)
	title_row.add_child(close_btn)

	outer.add_child(HSeparator.new())

	# ── Gold bank (Phase 3 #3) — move carried gold ↔ a server-owned reserve.
	var gold_row := PanelContainer.new()
	gold_row.add_theme_stylebox_override("panel", _rs(Color(0.16, 0.12, 0.05), RS_GOLD.darkened(0.4), 1))
	outer.add_child(gold_row)
	var grow := VBoxContainer.new()
	grow.add_theme_constant_override("separation", 3)
	gold_row.add_child(grow)
	_bank_gold_lbl = Label.new()
	_bank_gold_lbl.add_theme_color_override("font_color", RS_GOLD)
	_bank_gold_lbl.add_theme_font_size_override("font_size", 11)
	grow.add_child(_bank_gold_lbl)
	var gctrl := HBoxContainer.new()
	gctrl.add_theme_constant_override("separation", 4)
	grow.add_child(gctrl)
	_bank_gold_amount = LineEdit.new()
	_bank_gold_amount.placeholder_text = "amount"
	_bank_gold_amount.custom_minimum_size = Vector2(72, 0)
	_bank_gold_amount.add_theme_font_size_override("font_size", 11)
	gctrl.add_child(_bank_gold_amount)
	for spec: Array in [["Deposit", true, false], ["Withdraw", false, false],
			["Dep All", true, true], ["WD All", false, true]]:
		var gb := Button.new()
		gb.text = str(spec[0])
		gb.add_theme_font_size_override("font_size", 9)
		var is_dep: bool = spec[1]
		var is_all: bool = spec[2]
		gb.pressed.connect(func() -> void: _bank_gold_action(is_dep, is_all))
		gctrl.add_child(gb)
	_refresh_bank_gold()

	# Inventory half
	var inv_hdr := HBoxContainer.new()
	outer.add_child(inv_hdr)
	var inv_lbl := Label.new()
	inv_lbl.text = "Inventory (click deposits; right-click for actions)"
	inv_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_lbl.add_theme_color_override("font_color", RS_DIM)
	inv_lbl.add_theme_font_size_override("font_size", 10)
	inv_hdr.add_child(inv_lbl)
	var dep_all_btn := Button.new()
	dep_all_btn.text = "Deposit All"
	dep_all_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_A, RS_GOLD, 2))
	dep_all_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
	dep_all_btn.add_theme_color_override("font_color", RS_GOLD)
	dep_all_btn.add_theme_font_size_override("font_size", 10)
	dep_all_btn.pressed.connect(func() -> void: GameManager.deposit_all())
	inv_hdr.add_child(dep_all_btn)

	var inv_grid := GridContainer.new()
	inv_grid.columns = 7
	inv_grid.add_theme_constant_override("h_separation", 3)
	inv_grid.add_theme_constant_override("v_separation", 3)
	outer.add_child(inv_grid)

	_bank_inv_slots.clear()
	for i in range(28):
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(44, 44)

		var bg := Panel.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)

		var cr := ColorRect.new()
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		cr.color = Color.TRANSPARENT
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(cr)

		var ir := TextureRect.new()
		ir.set_anchors_preset(Control.PRESET_FULL_RECT)
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ir.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(ir)

		# Procedural art overlay — draws only when the item lacks a PNG.
		# _fill_bank_slot wires + unwires its draw signal per refresh.
		var art_ctrl := Control.new()
		art_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
		art_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(art_ctrl)

		var nl := Label.new()
		nl.set_anchors_preset(Control.PRESET_FULL_RECT)
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		nl.add_theme_font_size_override("font_size", 10)
		nl.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		nl.add_theme_constant_override("outline_size", 3)
		nl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(nl)

		var ql := Label.new()
		ql.anchor_left = 0.0; ql.anchor_right  = 1.0
		ql.anchor_top  = 0.6; ql.anchor_bottom = 1.0
		ql.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ql.add_theme_font_size_override("font_size", 8)
		ql.add_theme_color_override("font_color", RS_GOLD)
		ql.add_theme_constant_override("outline_size", 2)
		ql.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		ql.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(ql)

		var si := i
		slot.gui_input.connect(func(ev: InputEvent) -> void:
			if not (ev is InputEventMouseButton) or not (ev as InputEventMouseButton).pressed:
				return
			if si >= GameManager.inventory.size():
				return
			var btn := (ev as InputEventMouseButton).button_index
			if btn == MOUSE_BUTTON_LEFT:
				GameManager.deposit_item(si)
			elif btn == MOUSE_BUTTON_RIGHT:
				# Playtest: right-click opens the context menu instead of a
				# blind "deposit all". Menu action is what the user picks.
				_show_bank_context_menu(true, si,
					(ev as InputEventMouseButton).global_position))
		inv_grid.add_child(slot)
		_bank_inv_slots.append({"slot": slot, "color_rect": cr, "icon_rect": ir, "name_lbl": nl, "qty_lbl": ql, "art_ctrl": art_ctrl})

	outer.add_child(HSeparator.new())

	# Bank stash half
	var stash_lbl := Label.new()
	stash_lbl.text = "Bank Storage — 100 slots (click withdraws; right-click for actions)"
	stash_lbl.add_theme_color_override("font_color", RS_DIM)
	stash_lbl.add_theme_font_size_override("font_size", 10)
	outer.add_child(stash_lbl)

	var stash_scroll := ScrollContainer.new()
	stash_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stash_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(stash_scroll)

	var stash_grid := GridContainer.new()
	stash_grid.columns = 7
	stash_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stash_grid.add_theme_constant_override("h_separation", 3)
	stash_grid.add_theme_constant_override("v_separation", 3)
	stash_scroll.add_child(stash_grid)

	_bank_stash_slots.clear()
	# Playtest: bank capacity 36 → 100. Grid stays 7 cols → ~15 rows;
	# stash_scroll is already a ScrollContainer so extra rows scroll cleanly.
	for i in range(100):
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(44, 44)

		var bg := Panel.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)

		var cr := ColorRect.new()
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		cr.color = Color.TRANSPARENT
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(cr)

		var ir := TextureRect.new()
		ir.set_anchors_preset(Control.PRESET_FULL_RECT)
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ir.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(ir)

		# Procedural art overlay — draws only when the item lacks a PNG.
		# _fill_bank_slot wires + unwires its draw signal per refresh.
		var art_ctrl := Control.new()
		art_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
		art_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(art_ctrl)

		var nl := Label.new()
		nl.set_anchors_preset(Control.PRESET_FULL_RECT)
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		nl.add_theme_font_size_override("font_size", 10)
		nl.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		nl.add_theme_constant_override("outline_size", 3)
		nl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(nl)

		var ql := Label.new()
		ql.anchor_left = 0.0; ql.anchor_right  = 1.0
		ql.anchor_top  = 0.6; ql.anchor_bottom = 1.0
		ql.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ql.add_theme_font_size_override("font_size", 8)
		ql.add_theme_color_override("font_color", RS_GOLD)
		ql.add_theme_constant_override("outline_size", 2)
		ql.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		ql.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(ql)

		var si := i
		slot.gui_input.connect(func(ev: InputEvent) -> void:
			if not (ev is InputEventMouseButton) or not (ev as InputEventMouseButton).pressed:
				return
			if si >= GameManager.bank_inventory.size():
				return
			var btn := (ev as InputEventMouseButton).button_index
			if btn == MOUSE_BUTTON_LEFT:
				GameManager.withdraw_item(si)
			elif btn == MOUSE_BUTTON_RIGHT:
				_show_bank_context_menu(false, si,
					(ev as InputEventMouseButton).global_position))
		stash_grid.add_child(slot)
		_bank_stash_slots.append({"slot": slot, "color_rect": cr, "icon_rect": ir, "name_lbl": nl, "qty_lbl": ql, "art_ctrl": art_ctrl})

func _on_open_bank() -> void:
	_refresh_bank()
	_refresh_bank_gold()
	_bank_window.visible = true
	_register_proximity_panel(_bank_window)

## Gold-bank row (Phase 3 #3). Kept live off inventory_changed (gold_set +
## bank_gold_set both emit it).
func _refresh_bank_gold() -> void:
	if _bank_gold_lbl == null:
		return
	_bank_gold_lbl.text = "Gold — Carried: %d      Banked: %d" % [GameManager.gold, GameManager.bank_gold]

func _bank_gold_action(deposit: bool, use_all: bool) -> void:
	var amt := 0
	if use_all:
		amt = GameManager.gold if deposit else GameManager.bank_gold
	else:
		var t := _bank_gold_amount.text.strip_edges()
		amt = int(t) if t.is_valid_int() else 0
	if amt <= 0:
		Events.chat_message.emit("Enter a gold amount.")
		return
	if deposit:
		NetworkManager.send_bank_gold_deposit(amt)
	else:
		NetworkManager.send_bank_gold_withdraw(amt)
	_bank_gold_amount.text = ""

func _to_color(raw: Variant) -> Color:
	if raw is Color:
		return raw as Color
	if raw is Array:
		var a := raw as Array
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color.GRAY

func _refresh_bank() -> void:
	var inv   := GameManager.inventory
	var stash: Array[Dictionary] = GameManager.bank_inventory

	for i in range(_bank_inv_slots.size()):
		_fill_bank_slot(_bank_inv_slots[i], inv, i)
	for i in range(_bank_stash_slots.size()):
		_fill_bank_slot(_bank_stash_slots[i], stash, i)

func _fill_bank_slot(s: Dictionary, items: Array, i: int) -> void:
	var slot_ctrl := s["slot"]      as Control
	var icon_rect := s["icon_rect"]  as TextureRect
	var color_rect := s["color_rect"] as ColorRect
	var name_lbl  := s["name_lbl"]   as Label
	var qty_lbl   := s["qty_lbl"]    as Label
	var art_ctrl  := s.get("art_ctrl") as Control
	# Clear any prior procedural draw connections so refresh doesn't stack them.
	if art_ctrl != null:
		for c: Dictionary in art_ctrl.draw.get_connections():
			art_ctrl.draw.disconnect(c["callable"])
		art_ctrl.queue_redraw()
	if i >= items.size():
		icon_rect.texture = null
		color_rect.color  = Color.TRANSPARENT
		name_lbl.text     = ""
		qty_lbl.text      = ""
		slot_ctrl.tooltip_text = ""
		return
	var item: Dictionary = items[i]
	var icon_path := "res://assets/icons/" + (item["id"] as String) + ".png"
	if ResourceLoader.exists(icon_path):
		icon_rect.texture = load(icon_path) as Texture2D
		color_rect.color  = Color.TRANSPARENT
		name_lbl.text     = ""
	else:
		# Route through ItemArt for procedural draws. Abbreviation label
		# stays as a secondary fallback — the pouch/procedural art draws
		# behind it so the slot always reads.
		icon_rect.texture = null
		color_rect.color  = Color.TRANSPARENT
		name_lbl.text     = _item_abbrev(item["name"] as String)
		var iid := item["id"] as String
		var icol := _to_color(item.get("color"))
		if art_ctrl != null:
			art_ctrl.draw.connect(func() -> void:
				ItemArt.draw_inventory_icon(art_ctrl, iid, icol,
					min(art_ctrl.size.x, art_ctrl.size.y)))
			art_ctrl.queue_redraw()
	qty_lbl.text = "x%d" % item["qty"]
	# Hover tooltip — Godot's built-in floating label. Right-click hint keeps
	# the context menu discoverable without a permanent on-screen legend.
	slot_ctrl.tooltip_text = "%s  ×%d\nRight-click for actions" % [
		str(item.get("name", item["id"])), int(item["qty"])]

## Right-click context menu for a bank slot. `inv_side` = true means the
## slot belongs to the top (inventory) half; false = bank stash. Actions
## are filtered to the side that makes sense (no "Deposit" from a bank
## slot). Delete opens a confirmation dialog because it's irreversible.
var _bank_ctx_menu: PopupMenu = null
var _bank_ctx_side_is_inv: bool = false
var _bank_ctx_index: int = -1

func _show_bank_context_menu(inv_side: bool, index: int, at_screen: Vector2) -> void:
	if _bank_ctx_menu == null:
		_bank_ctx_menu = PopupMenu.new()
		add_child(_bank_ctx_menu)
		_bank_ctx_menu.id_pressed.connect(_on_bank_ctx_selected)
	_bank_ctx_side_is_inv = inv_side
	_bank_ctx_index = index
	_bank_ctx_menu.clear()
	if inv_side:
		if index >= GameManager.inventory.size():
			return
		var iid := str(GameManager.inventory[index]["id"])
		_bank_ctx_menu.add_item("Deposit one",       0)
		_bank_ctx_menu.add_item("Deposit all (%s)" % iid, 1)
		_bank_ctx_menu.add_separator()
		_bank_ctx_menu.add_item("Delete",            9)
	else:
		if index >= GameManager.bank_inventory.size():
			return
		_bank_ctx_menu.add_item("Withdraw one", 2)
		_bank_ctx_menu.add_item("Withdraw all", 3)
		_bank_ctx_menu.add_separator()
		_bank_ctx_menu.add_item("Delete",       9)
	_bank_ctx_menu.reset_size()
	_bank_ctx_menu.position = Vector2i(at_screen)
	_bank_ctx_menu.popup()

func _on_bank_ctx_selected(id: int) -> void:
	var idx := _bank_ctx_index
	var inv_side := _bank_ctx_side_is_inv
	if idx < 0:
		return
	match id:
		0:
			if inv_side and idx < GameManager.inventory.size():
				GameManager.deposit_item(idx)
		1:
			if inv_side and idx < GameManager.inventory.size():
				GameManager.deposit_all_of(str(GameManager.inventory[idx]["id"]))
		2:
			if not inv_side and idx < GameManager.bank_inventory.size():
				GameManager.withdraw_item(idx)
		3:
			if not inv_side and idx < GameManager.bank_inventory.size():
				GameManager.withdraw_all_of(idx)
		9:
			_confirm_bank_delete(inv_side, idx)

func _confirm_bank_delete(inv_side: bool, idx: int) -> void:
	var items: Array = GameManager.inventory if inv_side else GameManager.bank_inventory
	if idx < 0 or idx >= items.size():
		return
	var item: Dictionary = items[idx]
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Permanently delete %s ×%d?\nThis cannot be undone." % [
		str(item.get("name", item["id"])), int(item["qty"])]
	dlg.title = "Delete item"
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		if inv_side:
			GameManager.discard_item(idx)
		else:
			GameManager.discard_bank_item(idx)
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered()

# ── CHAT BOX ──────────────────────────────────────────────────────────────────
## Chat panel — 2.5× larger than the original (480×400 vs 280×176) with
## three filter tabs at the top: World, Private, Events. Messages flow
## into a single history buffer with per-message category tagging; the
## active tab filters which messages render.
const CHAT_W := 480
const CHAT_H := 400
func _build_chat_box() -> void:
	var chat_bg := StyleBoxFlat.new()
	chat_bg.bg_color = Color(0.06, 0.04, 0.02, 0.90)
	chat_bg.set_border_width_all(2)
	chat_bg.border_color = RS_BORDER.darkened(0.3)
	chat_bg.set_corner_radius_all(3)

	_chat_panel = PanelContainer.new()
	_chat_panel.add_theme_stylebox_override("panel", chat_bg)
	# Bottom-right, immediately LEFT of the HP bar (HP bar spans offset_left -260..-6,
	# offset_top -62..-6), sitting flush with the screen bottom.
	_chat_panel.anchor_left   = 1.0; _chat_panel.anchor_right  = 1.0
	_chat_panel.anchor_top    = 1.0; _chat_panel.anchor_bottom = 1.0
	_chat_panel.offset_left   = -CHAT_W - 266; _chat_panel.offset_right  = -266
	_chat_panel.offset_top    = -CHAT_H - 6; _chat_panel.offset_bottom = -6
	add_child(_chat_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_chat_panel.add_child(vbox)

	# Header: title + collapse button. Doubles as the drag handle (like the
	# combat window) — grab it to move the chat panel anywhere.
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 4)
	hdr.mouse_filter = Control.MOUSE_FILTER_STOP
	hdr.gui_input.connect(_on_chat_header_input)
	vbox.add_child(hdr)
	# Red "new messages" dot — sits left of the title, shown only while the
	# chat is minimized and something new arrived. Cleared on expand.
	_chat_notif_dot = Label.new()
	_chat_notif_dot.text = "●"
	_chat_notif_dot.add_theme_color_override("font_color", Color(1.0, 0.30, 0.25))
	_chat_notif_dot.add_theme_font_size_override("font_size", 13)
	_chat_notif_dot.visible = false
	_chat_notif_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hdr.add_child(_chat_notif_dot)
	var chat_title := Label.new()
	chat_title.text = "Chat"
	chat_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_title.mouse_filter = Control.MOUSE_FILTER_PASS   # let drag bubble up
	chat_title.add_theme_color_override("font_color", RS_DIM)
	chat_title.add_theme_font_size_override("font_size", 13)
	hdr.add_child(chat_title)
	var chat_collapse := Button.new()
	chat_collapse.text = "▲"
	chat_collapse.flat = true
	chat_collapse.custom_minimum_size = Vector2(28, 22)
	chat_collapse.add_theme_font_size_override("font_size", 12)
	chat_collapse.add_theme_color_override("font_color", RS_DIM)
	hdr.add_child(chat_collapse)
	_chat_collapse_btn = chat_collapse

	# Tab row — World / Private / Events filter.
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	vbox.add_child(tab_row)
	for entry: Array in [
			["World",   CHAT_CAT_WORLD],
			["Private", CHAT_CAT_PRIVATE],
			["Events",  CHAT_CAT_EVENTS],
		]:
		var btn := Button.new()
		btn.text = entry[0]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 26)
		btn.add_theme_font_size_override("font_size", 12)
		var cat: String = entry[1]
		btn.pressed.connect(func() -> void: _set_chat_category(cat))
		tab_row.add_child(btn)
		_chat_tab_btns[cat] = btn

	# Content: scroll + input (wrapped so we can hide both at once).
	_chat_content = VBoxContainer.new()
	_chat_content.add_theme_constant_override("separation", 4)
	_chat_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_chat_content)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_content.add_child(scroll)

	_chat_vbox = VBoxContainer.new()
	_chat_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(_chat_vbox)

	var line_edit := LineEdit.new()
	line_edit.placeholder_text = "Type to chat..."
	line_edit.custom_minimum_size = Vector2(0, 30)
	line_edit.add_theme_font_size_override("font_size", 14)
	line_edit.add_theme_color_override("font_color", RS_TEXT)
	line_edit.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 1))
	line_edit.add_theme_stylebox_override("focus",  _rs(RS_BTN_N, RS_BORDER, 1))
	line_edit.text_submitted.connect(func(t: String) -> void:
		var trimmed := t.strip_edges()
		if not trimmed.is_empty():
			_send_chat_or_whisper(trimmed)
		line_edit.clear()
	)
	_chat_line_edit = line_edit
	_chat_content.add_child(line_edit)

	chat_collapse.pressed.connect(func() -> void:
		_chat_minimized = not _chat_minimized
		_chat_content.visible = not _chat_minimized
		chat_collapse.text = "▼" if _chat_minimized else "▲"
		# Grow/shrink from the CURRENT bottom edge (relative to offset_bottom)
		# so a dragged panel keeps its position instead of snapping back.
		var h := 40.0 if _chat_minimized else float(CHAT_H)
		_chat_panel.offset_top = _chat_panel.offset_bottom - h
		# A top-docked panel expanding downward can push its header off the top
		# of the screen — clamp it back so it stays grabbable.
		_clamp_chat_to_viewport()
		# Expanding = you've seen the messages → clear the notification dot.
		if not _chat_minimized and _chat_notif_dot != null:
			_chat_notif_dot.visible = false)

	_set_chat_category(CHAT_CAT_WORLD)

## Switch the visible tab. Updates highlight on the tab buttons and
## refilters the rendered message list — history is untouched.
func _set_chat_category(cat: String) -> void:
	_chat_active_cat = cat
	for c: Variant in _chat_tab_btns.keys():
		var b := _chat_tab_btns[c] as Button
		var active: bool = (c == cat)
		var sb_n := _rs(RS_BTN_A if active else RS_BTN_N,
			RS_GOLD if active else RS_BORDER.darkened(0.4), 2)
		b.add_theme_stylebox_override("normal", sb_n)
		b.add_theme_color_override("font_color", RS_GOLD if active else RS_TEXT)
	_refresh_chat_display()

## Wipes and rebuilds the rendered chat list from `_chat_history`, keeping
## only messages whose category matches the active tab.
func _refresh_chat_display() -> void:
	if _chat_vbox == null:
		return
	for child: Node in _chat_vbox.get_children():
		child.queue_free()
	for entry: Dictionary in _chat_history:
		if str(entry.get("category", CHAT_CAT_WORLD)) != _chat_active_cat:
			continue
		var lbl := Label.new()
		lbl.text = str(entry.get("text", ""))
		lbl.add_theme_color_override("font_color", RS_TEXT)
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_chat_vbox.add_child(lbl)

## Public entry point used by Events.chat_message. Auto-classifies the
## message by content — XP / quest / loss notifications go to Events,
## anything starting with the whisper marker goes to Private, the rest
## are World chat. Callers that already know the category should use
## `_add_chat_message_typed(msg, cat)` directly.
func _add_chat_message(msg: String) -> void:
	_add_chat_message_typed(msg, _categorize_chat(msg))

func _categorize_chat(msg: String) -> String:
	# Everything arriving via Events.chat_message is a status/notification line,
	# NOT player chat — genuine chat comes through Events.world_chat and is
	# forced to CHAT_CAT_WORLD directly. So the World tab stays clean: here we
	# only split whisper banners into Private and drop everything else into
	# Events (previously unmatched lines leaked into World, which was the spam).
	if msg.begins_with("[Whisper") or msg.begins_with("[From ") \
			or msg.begins_with("[To "):
		return CHAT_CAT_PRIVATE
	return CHAT_CAT_EVENTS

## Append a chat line with an explicit category. The list renders only
## when the message matches the active tab — but it ALWAYS lives in
## history so toggling tabs reveals prior traffic.
func _add_chat_message_typed(msg: String, category: String) -> void:
	if _chat_vbox == null:
		return
	# New message while the chat is collapsed → light the red notification dot.
	if _chat_minimized and _chat_notif_dot != null:
		_chat_notif_dot.visible = true
	_chat_history.append({"text": msg, "category": category})
	while _chat_history.size() > CHAT_MAX:
		_chat_history.pop_front()
	# Append directly only if this message belongs to the active tab —
	# faster than rebuilding the whole list on every chat line.
	if category == _chat_active_cat:
		var lbl := Label.new()
		lbl.text = msg
		lbl.add_theme_color_override("font_color", RS_TEXT)
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_chat_vbox.add_child(lbl)
		# Trim the visible list if it's outgrown the buffer.
		while _chat_vbox.get_child_count() > CHAT_MAX:
			_chat_vbox.get_child(0).queue_free()
		# Auto-scroll to bottom.
		await get_tree().process_frame
		var scroll := _chat_vbox.get_parent() as ScrollContainer
		if scroll != null:
			scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)

func _on_chat_xp(skill: String, amount: int) -> void:
	_add_chat_message_typed("+%d %s XP" % [amount, skill.capitalize()],
		CHAT_CAT_EVENTS)

func _on_thrall_returned(gains: Dictionary) -> void:
	for skill: Variant in gains.keys():
		var val: int = gains[skill]
		_add_chat_message_typed(
			"Thrall returned: +%d %s XP" % [val, (skill as String).capitalize()],
			CHAT_CAT_EVENTS)

# ── MINIMAP ───────────────────────────────────────────────────────────────────
func _build_minimap() -> void:
	_minimap_panel = PanelContainer.new()
	_minimap_panel.add_theme_stylebox_override("panel", _rs(Color(0.04, 0.04, 0.06, 0.92), RS_BORDER, 0))
	_minimap_panel.anchor_left   = 1.0; _minimap_panel.anchor_right  = 1.0
	_minimap_panel.anchor_top    = 0.0; _minimap_panel.anchor_bottom = 0.0
	_minimap_panel.offset_left   = -174; _minimap_panel.offset_right  = -6
	_minimap_panel.offset_top    = 6;    _minimap_panel.offset_bottom = 182
	add_child(_minimap_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_minimap_panel.add_child(vbox)

	# Header row with title + collapse button
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 0)
	hdr.custom_minimum_size = Vector2(0, 16)
	vbox.add_child(hdr)
	var map_lbl := Label.new()
	map_lbl.text = "Map"
	map_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_lbl.add_theme_color_override("font_color", RS_DIM)
	map_lbl.add_theme_font_size_override("font_size", 8)
	hdr.add_child(map_lbl)
	var mm_collapse := Button.new()
	mm_collapse.text = "▲"
	mm_collapse.flat = true
	mm_collapse.custom_minimum_size = Vector2(16, 16)
	mm_collapse.add_theme_font_size_override("font_size", 8)
	mm_collapse.add_theme_color_override("font_color", RS_DIM)
	hdr.add_child(mm_collapse)

	# Canvas control (the actual map). Click opens the fullscreen viewer —
	# STOP filter so the click doesn't leak through to the world underneath.
	_minimap_content = Control.new()
	_minimap_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_minimap_content.mouse_filter = Control.MOUSE_FILTER_STOP
	# Clip to the panel so a ROTATED map (3D mode) can't spill its corners past the
	# circular frame; the corner mask + border then keep it a clean circle.
	_minimap_content.clip_contents = true
	_minimap_content.draw.connect(_on_minimap_draw)
	_minimap_content.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				_open_minimap_fullscreen())
	vbox.add_child(_minimap_content)
	_minimap_canvas = _minimap_content   # keep draw reference pointing to same node

	mm_collapse.pressed.connect(func() -> void:
		_minimap_minimized = not _minimap_minimized
		_minimap_content.visible = not _minimap_minimized
		mm_collapse.text = "▼" if _minimap_minimized else "▲"
		# Resize panel: collapsed = header only (~20px), expanded = full (176px)
		_minimap_panel.offset_bottom = 26 if _minimap_minimized else 182)

	# Defer minimap generation so Ground._ready() has finished building its cache.
	_minimap_texture = null
	call_deferred("_regen_minimap")

func _on_minimap_draw() -> void:
	if _minimap_canvas == null or _minimap_texture == null:
		return
	if _minimap_minimized:
		return

	var CANVAS_W  := _minimap_canvas.size.x
	var CANVAS_H  := _minimap_canvas.size.y
	if CANVAS_W < 4.0 or CANVAS_H < 4.0:
		return
	const VIEW_TILES := 60.0
	var TILE_PX   := CANVAS_W / VIEW_TILES

	# Player tile position (default to world centre if no player yet). While
	# inside an interior, use the building's exterior anchor so the minimap
	# stays in the local biome instead of clamping to the far-off interior band.
	var ptx := 150.0
	var pty := 150.0
	if _player != null:
		var mpos: Vector2 = GameManager.overworld_pos(_player.global_position)
		ptx = mpos.x / 32.0
		pty = mpos.y / 32.0

	# Source rect in the 300×300 texture (one pixel = one tile)
	var half := VIEW_TILES * 0.5
	var src_x := clampf(ptx - half, 0.0, 300.0 - VIEW_TILES)
	var src_y := clampf(pty - half, 0.0, 300.0 - VIEW_TILES)
	var src_rect := Rect2(src_x, src_y, VIEW_TILES, VIEW_TILES)

	# 3D mode: rotate the map + markers around the centre so camera-forward is "up".
	# The player dot, frame and border are drawn AFTER a reset so they stay fixed.
	var mm_center := Vector2(CANVAS_W * 0.5, CANVAS_H * 0.5)
	if absf(minimap_heading) > 0.001:
		_minimap_canvas.draw_set_transform_matrix(
			Transform2D(minimap_heading, mm_center - mm_center.rotated(minimap_heading)))

	_minimap_canvas.draw_texture_rect_region(
		_minimap_texture, Rect2(0.0, 0.0, CANVAS_W, CANVAS_H), src_rect)

	# Interactable dots
	for node in get_tree().get_nodes_in_group("interactable"):
		if not node is Node2D:
			continue
		var n2d := node as Node2D
		var wx := n2d.global_position.x / 32.0
		var wy := n2d.global_position.y / 32.0
		var cx := (wx - src_x) * TILE_PX
		var cy := (wy - src_y) * TILE_PX
		if cx < 0.0 or cx > CANVAS_W or cy < 0.0 or cy > CANVAS_H:
			continue
		var itype: String = n2d.get("interactable_type_str") if n2d.get("interactable_type_str") != null else ""
		var dot_col: Color
		match itype:
			"rock":          dot_col = Color(0.65, 0.62, 0.60)
			"fish":          dot_col = Color(0.25, 0.55, 0.90)
			"herb":          dot_col = Color(0.45, 0.90, 0.30)
			"forge", "fire": dot_col = Color(0.90, 0.45, 0.10)
			"bank":          dot_col = Color(0.85, 0.70, 0.10)
			_:               dot_col = Color(0.20, 0.65, 0.20)
		_minimap_canvas.draw_rect(Rect2(cx - 1.5, cy - 1.5, 3.0, 3.0), dot_col)

	# Banner territory overlay — drawn AFTER terrain so radii are visible,
	# tinted by warband_id sigil colour. Banners claim a 16-tile radius.
	for node in get_tree().get_nodes_in_group("interactable"):
		if not node is Node2D:
			continue
		var b2d := node as Node2D
		var btype: String = b2d.get("interactable_type_str") if b2d.get("interactable_type_str") != null else ""
		if btype != "banner":
			continue
		var bwx := b2d.global_position.x / 32.0
		var bwy := b2d.global_position.y / 32.0
		var bcx := (bwx - src_x) * TILE_PX
		var bcy := (bwy - src_y) * TILE_PX
		var brad := 16.0 * TILE_PX
		if bcx + brad < 0.0 or bcx - brad > CANVAS_W or bcy + brad < 0.0 or bcy - brad > CANVAS_H:
			continue
		var warband_id: String = ""
		if b2d.has_meta("warband_id"):
			warband_id = String(b2d.get_meta("warband_id"))
		var sigil := _warband_sigil_color(warband_id)
		_minimap_canvas.draw_circle(Vector2(bcx, bcy), brad, Color(sigil.r, sigil.g, sigil.b, 0.22))
		_minimap_canvas.draw_arc(Vector2(bcx, bcy), brad, 0.0, TAU, 24, Color(sigil.r, sigil.g, sigil.b, 0.85), 1.5)

	# Reset the rotation — the player marker, corner frame and border are screen-fixed.
	_minimap_canvas.draw_set_transform_matrix(Transform2D.IDENTITY)

	# Player dot — always at canvas centre
	_minimap_canvas.draw_circle(Vector2(CANVAS_W * 0.5, CANVAS_H * 0.5), 3.0, Color.WHITE)

	# Corner mask outside the circle. Playtest fix — was flat black which read
	# as "broken triangles". Warm dark oak here reads as a Norse frame; the
	# gold arc below layers on top as the knotwork inner ring.
	var bg_col := Color(0.14, 0.09, 0.05, 1.0)
	var mm_cx  := CANVAS_W * 0.5
	var mm_cy  := CANVAS_H * 0.5
	var mm_r   := CANVAS_W * 0.5 - 0.5
	if mm_r > 1.0:
		const SEGS := 16
		var corners: Array[Array] = [
			[Vector2(0, 0),               PI,       PI * 1.5],
			[Vector2(CANVAS_W, 0),        PI * 1.5, PI * 2.0],
			[Vector2(CANVAS_W, CANVAS_H), 0.0,      PI * 0.5],
			[Vector2(0, CANVAS_H),        PI * 0.5, PI],
		]
		for cd: Array in corners:
			var cpt: Vector2 = (cd as Array)[0]
			var a0:  float   = (cd as Array)[1]
			var a1:  float   = (cd as Array)[2]
			var prev := Vector2(mm_cx + cos(a0) * mm_r, mm_cy + sin(a0) * mm_r)
			for j in range(1, SEGS + 1):
				var ang: float = lerp(a0, a1, float(j) / float(SEGS))
				var cur := Vector2(mm_cx + cos(ang) * mm_r, mm_cy + sin(ang) * mm_r)
				var area := (prev.x - cpt.x) * (cur.y - cpt.y) - (cur.x - cpt.x) * (prev.y - cpt.y)
				if absf(area) > 0.01:
					_minimap_canvas.draw_colored_polygon(PackedVector2Array([cpt, prev, cur]), bg_col)
				prev = cur
	# Circular border ring — outer dark, inner gold for a Norse ring feel.
	_minimap_canvas.draw_arc(Vector2(mm_cx, mm_cy), mm_r, 0.0, TAU, 48, RS_BORDER, 2.0)
	_minimap_canvas.draw_arc(Vector2(mm_cx, mm_cy), mm_r - 3.0, 0.0, TAU, 48,
		Color(0.72, 0.55, 0.20, 0.85), 1.2)
	# Four cardinal-point knot glyphs — small triangles pointing inward.
	# Adds Norse-shield readability without a texture asset.
	var knot := Color(0.85, 0.68, 0.25, 0.95)
	var knot_r := mm_r + 1.0
	for k in range(4):
		var a: float = float(k) * PI * 0.5
		var kx: float = mm_cx + cos(a) * knot_r
		var ky: float = mm_cy + sin(a) * knot_r
		var perp: Vector2 = Vector2(-sin(a), cos(a)) * 3.5
		var tip: Vector2 = Vector2(mm_cx + cos(a) * (mm_r - 4.0),
			mm_cy + sin(a) * (mm_r - 4.0))
		_minimap_canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(kx, ky) + perp, Vector2(kx, ky) - perp, tip]), knot)

func _regen_minimap() -> void:
	var ground := get_tree().get_first_node_in_group("ground") as Node
	var img := Image.create(300, 300, false, Image.FORMAT_RGB8)
	for ty: int in range(300):
		for tx: int in range(300):
			var bname: String
			if ground != null:
				bname = ground.call("biome_at_world", Vector2(tx * 32.0 + 16.0, ty * 32.0 + 16.0)) as String
			else:
				bname = "plains"
			img.set_pixel(tx, ty, _mm_color_for_biome(bname))
	_minimap_texture = ImageTexture.create_from_image(img)

## Named world zones for the fullscreen map — rect in tile coords (300×300
## world), display name, and a suggested level range so players can eyeball
## where they should be pushing next. Kept adjacent-to-the-code so tuning
## boundaries or names doesn't require a data file. Level ranges are best
## guesses from the current quest + monster placement; adjust as balance
## shifts. Colors are the WoW-style zone tints — semi-transparent overlays
## drawn on top of the terrain so each area reads as a distinct region.
## Zone definitions — polygon-based so admins can freehand irregular shapes
## via the in-map editor (rects were too coarse per the playtest). Each entry
## carries a display name, level range, and PackedVector2Array of tile-space
## vertices (0-300 range). Ships with a rectangular baseline; the admin editor
## rewrites the polygon and persists overrides to user://world_zones.json so
## the const stays clean while shape edits survive sessions.
##
## Level ranges: Bjorn's Landing is the starter spot (1-25), Kjelvik the
## next-step hub (25-40) — swapped from the previous defaults per playtest.
## `var` rather than `const` because Godot 4 rejects PackedVector2Array
## literals inside a constant expression. Treated as read-only — never
## mutated; `_init_world_zones` deep-copies into the live `_WORLD_ZONES`.
var _WORLD_ZONES_DEFAULT: Array = [
	{"name": "Bjorn's Landing", "lv": "1-25",   "col": Color(0.85, 0.45, 0.25),
		"poly": PackedVector2Array([Vector2(220,115), Vector2(280,115), Vector2(280,165), Vector2(220,165)])},
	{"name": "Kjelvik",         "lv": "25-40",  "col": Color(0.85, 0.72, 0.30),
		"poly": PackedVector2Array([Vector2(60,90), Vector2(105,90), Vector2(105,135), Vector2(60,135)])},
	{"name": "Frostheim",       "lv": "15-25",  "col": Color(0.55, 0.85, 0.98),
		"poly": PackedVector2Array([Vector2(20,5), Vector2(75,5), Vector2(75,60), Vector2(20,60)])},
	{"name": "Ironwood Keep",   "lv": "20-35",  "col": Color(0.45, 0.72, 0.30),
		"poly": PackedVector2Array([Vector2(85,135), Vector2(140,135), Vector2(140,180), Vector2(85,180)])},
	{"name": "Eastmark Post",   "lv": "30-45",  "col": Color(0.72, 0.55, 0.30),
		"poly": PackedVector2Array([Vector2(155,155), Vector2(210,155), Vector2(210,210), Vector2(155,210)])},
	{"name": "Northern Wastes", "lv": "30-50",  "col": Color(0.72, 0.85, 0.90),
		"poly": PackedVector2Array([Vector2(0,0), Vector2(300,0), Vector2(300,25), Vector2(0,25)])},
	{"name": "Ashlands",        "lv": "50-70",  "col": Color(0.65, 0.32, 0.18),
		"poly": PackedVector2Array([Vector2(0,220), Vector2(250,220), Vector2(250,270), Vector2(0,270)])},
	{"name": "Helheim",         "lv": "70-99",  "col": Color(0.45, 0.20, 0.55),
		"poly": PackedVector2Array([Vector2(230,240), Vector2(300,240), Vector2(300,300), Vector2(230,300)])},
	{"name": "Wildlands",       "lv": "10-25",  "col": Color(0.55, 0.70, 0.35),
		"poly": PackedVector2Array([Vector2(110,60), Vector2(190,60), Vector2(190,110), Vector2(110,110)])},
	{"name": "Deep Wilds",      "lv": "35-55",  "col": Color(0.30, 0.55, 0.35),
		"poly": PackedVector2Array([Vector2(195,60), Vector2(280,60), Vector2(280,120), Vector2(195,120)])},
]

## Live zone list — copy of the default on boot, replaced from disk when a
## user:// override exists, mutated live by the admin editor. Iterate this
## in draw code (never `_WORLD_ZONES_DEFAULT`).
var _WORLD_ZONES: Array = []
const _ZONES_OVERRIDE_PATH := "user://world_zones.json"

## Playtest track 3 — full-screen minimap viewer. Built lazily on first click
## and reused. The `_minimap_texture` is shared with the corner minimap;
## a fresh regen isn't needed on open. `_process` refreshes the canvas so
## the player marker stays live as the player moves.
var _mm_full_overview: bool = false  # WoW-style: sections + labels, less terrain
## Legend-key state — labels + interactable dots can be toggled off so a
## cluttered map reduces to just terrain + zone shapes. Default on.
var _mm_show_zone_labels: bool = true
var _mm_show_interactables: bool = true
var _mm_show_zones: bool = true
## Admin zone editor state — active mode, selected zone index, currently
## dragging vertex index (-1 = nothing being dragged). Vertex handles are
## 8×8 canvas-space squares; hit test is inclusive of that radius.
var _mm_zone_edit_mode: bool = false
var _mm_edit_zone_idx: int = -1
var _mm_edit_drag_vidx: int = -1
const _MM_HANDLE_R: float = 6.0
var _mm_legend_panel: PanelContainer = null
var _mm_edit_panel: PanelContainer = null
## Copy the const default into the live list, then apply any admin overrides
## from disk. Called lazily on first map open — no perf cost until then.
func _init_world_zones() -> void:
	if not _WORLD_ZONES.is_empty():
		return
	for z: Dictionary in _WORLD_ZONES_DEFAULT:
		_WORLD_ZONES.append({
			"name": str(z["name"]),
			"lv":   str(z["lv"]),
			"col":  z["col"] as Color,
			"poly": (z["poly"] as PackedVector2Array).duplicate(),
		})
	_load_zone_overrides()

func _load_zone_overrides() -> void:
	if not FileAccess.file_exists(_ZONES_OVERRIDE_PATH):
		return
	var f := FileAccess.open(_ZONES_OVERRIDE_PATH, FileAccess.READ)
	if f == null:
		return
	var raw: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (raw is Array):
		return
	var loaded: Array = []
	for item: Variant in (raw as Array):
		if not (item is Dictionary):
			continue
		var d: Dictionary = item as Dictionary
		var pts_raw: Array = d.get("poly", []) as Array
		var pts := PackedVector2Array()
		for p: Variant in pts_raw:
			if p is Array and (p as Array).size() >= 2:
				pts.append(Vector2(float((p as Array)[0]), float((p as Array)[1])))
		var col_arr: Array = d.get("col", [1, 1, 1, 1]) as Array
		var col := Color(1, 1, 1)
		if col_arr.size() >= 3:
			col = Color(float(col_arr[0]), float(col_arr[1]), float(col_arr[2]),
				float(col_arr[3]) if col_arr.size() >= 4 else 1.0)
		loaded.append({
			"name": str(d.get("name", "Zone")),
			"lv":   str(d.get("lv", "?")),
			"col":  col,
			"poly": pts,
		})
	if not loaded.is_empty():
		_WORLD_ZONES = loaded

func _save_zone_overrides() -> void:
	var out: Array = []
	for z: Dictionary in _WORLD_ZONES:
		var pts: Array = []
		for v in (z["poly"] as PackedVector2Array):
			pts.append([v.x, v.y])
		var c: Color = z["col"]
		out.append({
			"name": str(z["name"]),
			"lv":   str(z["lv"]),
			"col":  [c.r, c.g, c.b, c.a],
			"poly": pts,
		})
	var f := FileAccess.open(_ZONES_OVERRIDE_PATH, FileAccess.WRITE)
	if f == null:
		Events.chat_message.emit("Failed to save zones.")
		return
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	Events.chat_message.emit("Zone shapes saved.")

## Walks up from the player to the World/World3D node (the one exposing
## admin_teleport). Independent of exact scene nesting, so it works in both clients.
func _world_with_teleport() -> Node:
	var n: Node = _player
	while n != null:
		if n.has_method("admin_teleport"):
			return n
		n = n.get_parent()
	return null

func _open_minimap_fullscreen() -> void:
	_init_world_zones()
	if _mm_full_panel == null:
		_build_minimap_fullscreen()
	# Center the initial view on the player's current tile so opening
	# doesn't jarringly jump to (150,150). Use the exterior anchor while inside.
	if _player != null:
		var fpos: Vector2 = GameManager.overworld_pos(_player.global_position)
		_mm_full_center_tx = fpos.x / 32.0
		_mm_full_center_ty = fpos.y / 32.0
	_mm_full_panel.visible = true
	_mm_full_canvas.grab_focus()   # so ESC works without a title-bar click first
	_mm_full_canvas.queue_redraw()

func _build_minimap_fullscreen() -> void:
	_mm_full_panel = PanelContainer.new()
	_mm_full_panel.add_theme_stylebox_override("panel",
		_rs(Color(0.06, 0.04, 0.03, 0.96), Color(0.72, 0.55, 0.20), 4))
	_mm_full_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Inset so the Norse frame reads as a border, not a fullscreen wash.
	_mm_full_panel.offset_left   = 32
	_mm_full_panel.offset_top    = 32
	_mm_full_panel.offset_right  = -32
	_mm_full_panel.offset_bottom = -32
	_mm_full_panel.visible = false
	add_child(_mm_full_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	_mm_full_panel.add_child(root)

	# Title row with close button
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := Label.new()
	title.text = "🗺  World Map"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color(0.85, 0.68, 0.25))
	title.add_theme_font_size_override("font_size", 16)
	title_row.add_child(title)
	# Overview toggle — WoW-style zone-shape view vs detailed terrain view.
	var overview_btn := Button.new()
	overview_btn.text = "Overview"
	overview_btn.toggle_mode = true
	overview_btn.add_theme_font_size_override("font_size", 11)
	overview_btn.toggled.connect(func(pressed: bool) -> void:
		_mm_full_overview = pressed
		_mm_full_canvas.queue_redraw())
	title_row.add_child(overview_btn)
	# Admin-only teleport toggle — click the map to warp there. Mappers included
	# (can_edit_map), matching the zone editor's gate.
	if GameManager.can_edit_map():
		var tp_btn := Button.new()
		tp_btn.text = "⚡ Teleport"
		tp_btn.toggle_mode = true
		tp_btn.tooltip_text = "Admin: when on, click the map to teleport the player there."
		tp_btn.add_theme_font_size_override("font_size", 11)
		tp_btn.add_theme_color_override("font_color", Color(0.95, 0.80, 0.30))
		tp_btn.toggled.connect(func(pressed: bool) -> void:
			_mm_teleport_mode = pressed
			_mm_full_canvas.queue_redraw())
		title_row.add_child(tp_btn)
	var zoom_out := Button.new()
	zoom_out.text = "−"
	zoom_out.custom_minimum_size = Vector2(28, 20)
	zoom_out.pressed.connect(func() -> void:
		_mm_full_zoom = clampf(_mm_full_zoom / 1.25, 0.5, 4.0)
		_mm_full_canvas.queue_redraw())
	title_row.add_child(zoom_out)
	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.custom_minimum_size = Vector2(28, 20)
	zoom_in.pressed.connect(func() -> void:
		_mm_full_zoom = clampf(_mm_full_zoom * 1.25, 0.5, 4.0)
		_mm_full_canvas.queue_redraw())
	title_row.add_child(zoom_in)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(28, 20)
	close_btn.add_theme_color_override("font_color", Color(0.85, 0.68, 0.25))
	close_btn.pressed.connect(func() -> void: _mm_full_panel.visible = false)
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	# Map canvas + overlays. Wrapped in a ratio-flex Control so the legend
	# key + admin editor panel float in the corners without breaking the
	# canvas's fill-expand behavior.
	var canvas_wrap := Control.new()
	canvas_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(canvas_wrap)

	_mm_full_canvas = Control.new()
	_mm_full_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mm_full_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_mm_full_canvas.focus_mode = Control.FOCUS_ALL
	_mm_full_canvas.draw.connect(_on_mm_full_draw)
	_mm_full_canvas.gui_input.connect(_on_mm_full_input)
	canvas_wrap.add_child(_mm_full_canvas)

	_build_minimap_legend(canvas_wrap)
	# Zone editor is a map-building surface — mapper rank included, not
	# just full admin. is_admin() would exclude the tester's mapper role.
	if GameManager.can_edit_map():
		_build_minimap_zone_editor(canvas_wrap)

## Legend key — floats top-left of the map canvas. Lists symbol meanings and
## exposes visibility toggles for zone labels / zone fills / interactable
## dots. `_labels_key` also serves as the answer to the user's ask that "the
## words should be a toggle on a key in the corner of the map".
func _build_minimap_legend(parent: Control) -> void:
	_mm_legend_panel = PanelContainer.new()
	_mm_legend_panel.add_theme_stylebox_override("panel",
		_rs(Color(0.06, 0.04, 0.03, 0.92), Color(0.72, 0.55, 0.20), 2))
	_mm_legend_panel.anchor_left  = 0.0; _mm_legend_panel.anchor_right  = 0.0
	_mm_legend_panel.anchor_top   = 0.0; _mm_legend_panel.anchor_bottom = 0.0
	_mm_legend_panel.offset_left  = 8;   _mm_legend_panel.offset_top    = 8
	_mm_legend_panel.mouse_filter = Control.MOUSE_FILTER_STOP  # don't leak clicks
	parent.add_child(_mm_legend_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	_mm_legend_panel.add_child(vb)

	var title := Label.new()
	title.text = "Key"
	title.add_theme_color_override("font_color", Color(0.85, 0.68, 0.25))
	title.add_theme_font_size_override("font_size", 12)
	vb.add_child(title)
	vb.add_child(HSeparator.new())

	# Symbol swatches. Each row is a small ColorRect + a label — no icons
	# needed because these are also drawn as colored rects on the map.
	var symbols: Array = [
		[Color(1.00, 0.90, 0.20), "You are here"],
		[Color(0.20, 0.65, 0.20), "NPC / other"],
		[Color(0.65, 0.62, 0.60), "Rock"],
		[Color(0.25, 0.55, 0.90), "Fishing"],
		[Color(0.45, 0.90, 0.30), "Herb"],
		[Color(0.90, 0.45, 0.10), "Forge / fire"],
		[Color(0.85, 0.70, 0.10), "Bank"],
	]
	for sym: Array in symbols:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		vb.add_child(row)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(10, 10)
		swatch.color = sym[0]
		row.add_child(swatch)
		var lbl := Label.new()
		lbl.text = str(sym[1])
		lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85))
		lbl.add_theme_font_size_override("font_size", 10)
		row.add_child(lbl)

	vb.add_child(HSeparator.new())

	# Visibility toggles — checkboxes so the state is obvious at a glance.
	var lbl_chk := CheckBox.new()
	lbl_chk.text = "Zone labels"
	lbl_chk.button_pressed = _mm_show_zone_labels
	lbl_chk.add_theme_font_size_override("font_size", 10)
	lbl_chk.toggled.connect(func(pressed: bool) -> void:
		_mm_show_zone_labels = pressed
		_mm_full_canvas.queue_redraw())
	vb.add_child(lbl_chk)

	var zn_chk := CheckBox.new()
	zn_chk.text = "Zone fills"
	zn_chk.button_pressed = _mm_show_zones
	zn_chk.add_theme_font_size_override("font_size", 10)
	zn_chk.toggled.connect(func(pressed: bool) -> void:
		_mm_show_zones = pressed
		_mm_full_canvas.queue_redraw())
	vb.add_child(zn_chk)

	var dot_chk := CheckBox.new()
	dot_chk.text = "Interactable dots"
	dot_chk.button_pressed = _mm_show_interactables
	dot_chk.add_theme_font_size_override("font_size", 10)
	dot_chk.toggled.connect(func(pressed: bool) -> void:
		_mm_show_interactables = pressed
		_mm_full_canvas.queue_redraw())
	vb.add_child(dot_chk)

## Admin-only editor — sits top-right of the map. Only ever built when
## `GameManager.is_admin()` is true at map-open time; a non-admin who
## somehow toggles the mode after gaining admin still won't have this
## panel until they reopen the map (cheap re-open, acceptable).
func _build_minimap_zone_editor(parent: Control) -> void:
	_mm_edit_panel = PanelContainer.new()
	_mm_edit_panel.add_theme_stylebox_override("panel",
		_rs(Color(0.08, 0.02, 0.02, 0.94), Color(0.90, 0.35, 0.30), 2))
	_mm_edit_panel.anchor_left  = 1.0; _mm_edit_panel.anchor_right  = 1.0
	_mm_edit_panel.anchor_top   = 0.0; _mm_edit_panel.anchor_bottom = 0.0
	_mm_edit_panel.offset_left  = -230; _mm_edit_panel.offset_top    = 8
	_mm_edit_panel.offset_right = -8
	_mm_edit_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_mm_edit_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	_mm_edit_panel.add_child(vb)

	var title := Label.new()
	title.text = "⚙ Admin: Zone Editor"
	title.add_theme_color_override("font_color", Color(0.95, 0.55, 0.45))
	title.add_theme_font_size_override("font_size", 11)
	vb.add_child(title)
	vb.add_child(HSeparator.new())

	var mode_chk := CheckBox.new()
	mode_chk.text = "Edit mode"
	mode_chk.button_pressed = _mm_zone_edit_mode
	mode_chk.add_theme_font_size_override("font_size", 10)
	mode_chk.toggled.connect(func(pressed: bool) -> void:
		_mm_zone_edit_mode = pressed
		_mm_full_canvas.queue_redraw())
	vb.add_child(mode_chk)

	# Zone dropdown — pick which zone the click-to-edit actions affect.
	var zone_opt := OptionButton.new()
	zone_opt.add_theme_font_size_override("font_size", 10)
	_mm_zone_opt = zone_opt
	_refresh_zone_options()
	zone_opt.item_selected.connect(func(idx: int) -> void:
		_mm_edit_zone_idx = idx
		_mm_full_canvas.queue_redraw())
	vb.add_child(zone_opt)

	var hint := Label.new()
	hint.text = "Left-click empty: add vertex.\nDrag handle: move vertex.\nRight-click handle: delete."
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.80))
	hint.add_theme_font_size_override("font_size", 9)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.custom_minimum_size = Vector2(210, 0)
	vb.add_child(hint)

	# ── New Zone row — LineEdit for the name + button that appends a
	# starter triangle at world center and immediately selects it so the
	# admin can start dragging its handles right away.
	vb.add_child(HSeparator.new())
	var new_row := HBoxContainer.new()
	new_row.add_theme_constant_override("separation", 4)
	vb.add_child(new_row)
	var name_field := LineEdit.new()
	name_field.placeholder_text = "New zone name"
	name_field.custom_minimum_size = Vector2(120, 0)
	name_field.add_theme_font_size_override("font_size", 10)
	new_row.add_child(name_field)
	var new_btn := Button.new()
	new_btn.text = "＋ New"
	new_btn.add_theme_font_size_override("font_size", 10)
	new_btn.pressed.connect(func() -> void:
		var nm: String = name_field.text.strip_edges()
		if nm == "":
			nm = "New Zone %d" % (_WORLD_ZONES.size() + 1)
		# Starter triangle at world center (tile 150,150). Delete-vertex
		# guards `poly.size() > 3`, so this can't be reduced below a valid
		# polygon — the admin drags/adds vertices to shape it from here.
		var starter := PackedVector2Array([
			Vector2(140.0, 140.0),
			Vector2(160.0, 140.0),
			Vector2(150.0, 160.0)])
		_WORLD_ZONES.append({
			"name": nm,
			"lv":   "?",
			"col":  Color(0.70, 0.70, 0.35),
			"poly": starter,
		})
		_mm_edit_zone_idx = _WORLD_ZONES.size() - 1
		_refresh_zone_options()
		if _mm_zone_opt != null:
			_mm_zone_opt.select(_mm_edit_zone_idx)
		name_field.text = ""
		_mm_full_canvas.queue_redraw())
	new_row.add_child(new_btn)

	var save_btn := Button.new()
	save_btn.text = "💾 Save Zones"
	save_btn.add_theme_font_size_override("font_size", 10)
	save_btn.pressed.connect(_save_zone_overrides)
	vb.add_child(save_btn)

	var reset_btn := Button.new()
	reset_btn.text = "↺ Reset to Defaults"
	reset_btn.add_theme_font_size_override("font_size", 10)
	reset_btn.pressed.connect(func() -> void:
		_WORLD_ZONES.clear()
		_init_world_zones()
		_refresh_zone_options()
		_mm_full_canvas.queue_redraw())
	vb.add_child(reset_btn)

var _mm_zone_opt: OptionButton = null

func _refresh_zone_options() -> void:
	if _mm_zone_opt == null:
		return
	_mm_zone_opt.clear()
	for i in range(_WORLD_ZONES.size()):
		_mm_zone_opt.add_item("%d: %s" % [i, str(_WORLD_ZONES[i]["name"])], i)
	if _mm_edit_zone_idx >= 0 and _mm_edit_zone_idx < _WORLD_ZONES.size():
		_mm_zone_opt.select(_mm_edit_zone_idx)
	elif _WORLD_ZONES.size() > 0:
		_mm_edit_zone_idx = 0
		_mm_zone_opt.select(0)

## Draggable vertex handles + polyline outline on the SELECTED zone only,
## drawn on top of the normal zone fill so the admin can see exactly which
## points they're manipulating.
func _draw_zone_edit_overlay(src_x: float, src_y: float,
		tile_px_x: float, tile_px_y: float, cw: float, ch: float) -> void:
	if _mm_edit_zone_idx < 0 or _mm_edit_zone_idx >= _WORLD_ZONES.size():
		return
	var z: Dictionary = _WORLD_ZONES[_mm_edit_zone_idx]
	var poly: PackedVector2Array = z["poly"]
	for i in range(poly.size()):
		var v: Vector2 = poly[i]
		var cx: float = (v.x - src_x) * tile_px_x
		var cy: float = (v.y - src_y) * tile_px_y
		if cx < -20.0 or cx > cw + 20.0 or cy < -20.0 or cy > ch + 20.0:
			continue
		var handle := Rect2(cx - _MM_HANDLE_R, cy - _MM_HANDLE_R,
			_MM_HANDLE_R * 2.0, _MM_HANDLE_R * 2.0)
		_mm_full_canvas.draw_rect(handle, Color(1.0, 0.90, 0.20, 0.95))
		_mm_full_canvas.draw_rect(handle, Color(0.20, 0.10, 0.05, 1.0), false, 1.5)

## Convert a canvas-space point back to tile-space using the current
## viewport transform. Used by the admin editor to place new vertices
## where the user clicked.
func _mm_canvas_to_tile(pt: Vector2) -> Vector2:
	var cw := _mm_full_canvas.size.x
	var ch := _mm_full_canvas.size.y
	if cw <= 0.0 or ch <= 0.0:
		return Vector2.ZERO
	var view_tiles: float = 300.0 / _mm_full_zoom
	var half: float = view_tiles * 0.5
	var src_x: float = clampf(_mm_full_center_tx - half, 0.0, 300.0 - view_tiles)
	var src_y: float = clampf(_mm_full_center_ty - half, 0.0, 300.0 - view_tiles)
	return Vector2(src_x + pt.x / cw * view_tiles,
		src_y + pt.y / ch * view_tiles)

## Hit-test the handles of the currently selected zone. Returns the vertex
## index at `canvas_pt`, or -1 if none hit.
func _mm_hit_test_handle(canvas_pt: Vector2) -> int:
	if _mm_edit_zone_idx < 0 or _mm_edit_zone_idx >= _WORLD_ZONES.size():
		return -1
	var cw := _mm_full_canvas.size.x
	var ch := _mm_full_canvas.size.y
	var view_tiles: float = 300.0 / _mm_full_zoom
	var half: float = view_tiles * 0.5
	var src_x: float = clampf(_mm_full_center_tx - half, 0.0, 300.0 - view_tiles)
	var src_y: float = clampf(_mm_full_center_ty - half, 0.0, 300.0 - view_tiles)
	var tpx: float = cw / view_tiles
	var tpy: float = ch / view_tiles
	var poly: PackedVector2Array = _WORLD_ZONES[_mm_edit_zone_idx]["poly"]
	for i in range(poly.size()):
		var v: Vector2 = poly[i]
		var cx: float = (v.x - src_x) * tpx
		var cy: float = (v.y - src_y) * tpy
		if abs(canvas_pt.x - cx) <= _MM_HANDLE_R + 1.0 \
				and abs(canvas_pt.y - cy) <= _MM_HANDLE_R + 1.0:
			return i
	return -1

func _on_mm_full_input(ev: InputEvent) -> void:
	# ── Admin teleport mode: left-click warps the player, wheel still zooms. ──
	if _mm_teleport_mode and ev is InputEventMouseButton:
		var tmb := ev as InputEventMouseButton
		if tmb.button_index == MOUSE_BUTTON_WHEEL_UP and tmb.pressed:
			_mm_full_zoom = clampf(_mm_full_zoom * 1.15, 0.5, 4.0)
			_mm_full_canvas.queue_redraw()
			return
		if tmb.button_index == MOUSE_BUTTON_WHEEL_DOWN and tmb.pressed:
			_mm_full_zoom = clampf(_mm_full_zoom / 1.15, 0.5, 4.0)
			_mm_full_canvas.queue_redraw()
			return
		if tmb.button_index == MOUSE_BUTTON_LEFT and tmb.pressed:
			var tile := _mm_canvas_to_tile(tmb.position)
			var wpos := Vector2(clampf(tile.x, 0.0, 299.0) * 32.0,
				clampf(tile.y, 0.0, 299.0) * 32.0)
			var w := _world_with_teleport()
			if w != null:
				w.call("admin_teleport", wpos)
				_mm_full_panel.visible = false   # land in the world
			return
	# ── Admin edit mode intercepts pan/click. Zoom still works. ──
	if _mm_zone_edit_mode and ev is InputEventMouseButton:
		var emb := ev as InputEventMouseButton
		if emb.button_index == MOUSE_BUTTON_WHEEL_UP and emb.pressed:
			_mm_full_zoom = clampf(_mm_full_zoom * 1.15, 0.5, 4.0)
			_mm_full_canvas.queue_redraw()
			return
		if emb.button_index == MOUSE_BUTTON_WHEEL_DOWN and emb.pressed:
			_mm_full_zoom = clampf(_mm_full_zoom / 1.15, 0.5, 4.0)
			_mm_full_canvas.queue_redraw()
			return
		if emb.button_index == MOUSE_BUTTON_LEFT:
			if emb.pressed:
				var vidx := _mm_hit_test_handle(emb.position)
				if vidx >= 0:
					_mm_edit_drag_vidx = vidx  # start drag
				else:
					# Click empty space → append vertex to selected zone.
					# PackedVector2Array is a value type in Godot 4 — the
					# `as PackedVector2Array` cast on the dict lookup made a
					# temporary copy that `.append()` mutated then threw
					# away. Read-append-writeback matches the delete + drag
					# branches below.
					if _mm_edit_zone_idx >= 0 \
							and _mm_edit_zone_idx < _WORLD_ZONES.size():
						var t := _mm_canvas_to_tile(emb.position)
						var poly_a: PackedVector2Array = \
							_WORLD_ZONES[_mm_edit_zone_idx]["poly"]
						poly_a.append(t)
						_WORLD_ZONES[_mm_edit_zone_idx]["poly"] = poly_a
						_mm_full_canvas.queue_redraw()
			else:
				_mm_edit_drag_vidx = -1
			return
		if emb.button_index == MOUSE_BUTTON_RIGHT and emb.pressed:
			var vidx2 := _mm_hit_test_handle(emb.position)
			if vidx2 >= 0 and _mm_edit_zone_idx >= 0:
				var poly: PackedVector2Array = _WORLD_ZONES[_mm_edit_zone_idx]["poly"]
				if poly.size() > 3:
					poly.remove_at(vidx2)
					_WORLD_ZONES[_mm_edit_zone_idx]["poly"] = poly
					_mm_full_canvas.queue_redraw()
			return
	if _mm_zone_edit_mode and ev is InputEventMouseMotion and _mm_edit_drag_vidx >= 0:
		var mm := ev as InputEventMouseMotion
		var t := _mm_canvas_to_tile(mm.position)
		if _mm_edit_zone_idx >= 0 and _mm_edit_zone_idx < _WORLD_ZONES.size():
			var poly2: PackedVector2Array = _WORLD_ZONES[_mm_edit_zone_idx]["poly"]
			if _mm_edit_drag_vidx < poly2.size():
				poly2[_mm_edit_drag_vidx] = t
				_WORLD_ZONES[_mm_edit_zone_idx]["poly"] = poly2
				_mm_full_canvas.queue_redraw()
		return
	# ── Normal (non-edit) map input. ──
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_mm_full_zoom = clampf(_mm_full_zoom * 1.15, 0.5, 4.0)
			_mm_full_canvas.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_mm_full_zoom = clampf(_mm_full_zoom / 1.15, 0.5, 4.0)
			_mm_full_canvas.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_mm_full_dragging = mb.pressed
	elif ev is InputEventMouseMotion and _mm_full_dragging:
		var mm := ev as InputEventMouseMotion
		# One canvas pixel ≈ (view_tiles / canvas_w) world tiles. Reverse
		# so drag-right pans the map right (view center moves left).
		var canvas_w := _mm_full_canvas.size.x
		if canvas_w > 0.0:
			var view_tiles: float = 300.0 / _mm_full_zoom
			var tile_per_px: float = view_tiles / canvas_w
			_mm_full_center_tx = clampf(_mm_full_center_tx - mm.relative.x * tile_per_px,
				0.0, 300.0)
			_mm_full_center_ty = clampf(_mm_full_center_ty - mm.relative.y * tile_per_px,
				0.0, 300.0)
			_mm_full_canvas.queue_redraw()
	elif ev is InputEventKey:
		var kev := ev as InputEventKey
		if kev.pressed and kev.keycode == KEY_ESCAPE:
			_mm_full_panel.visible = false

func _on_mm_full_draw() -> void:
	if _mm_full_canvas == null or _mm_full_texture_ready() == false:
		return
	var cw := _mm_full_canvas.size.x
	var ch := _mm_full_canvas.size.y
	if cw < 4.0 or ch < 4.0:
		return
	var view_tiles: float = 300.0 / _mm_full_zoom
	var half: float = view_tiles * 0.5
	var src_x: float = clampf(_mm_full_center_tx - half, 0.0, 300.0 - view_tiles)
	var src_y: float = clampf(_mm_full_center_ty - half, 0.0, 300.0 - view_tiles)
	# Overview mode washes out the terrain so the tinted zone panels read
	# as the primary layer (WoW-style continent view).
	var terrain_mod: Color = Color(0.55, 0.55, 0.55, 1.0) if _mm_full_overview \
		else Color.WHITE
	_mm_full_canvas.draw_texture_rect_region(_minimap_texture,
		Rect2(0.0, 0.0, cw, ch), Rect2(src_x, src_y, view_tiles, view_tiles),
		terrain_mod)

	# Zone overlays — polygon-based so admin freehand shapes render as-is.
	# Overview mode fills more opaquely so zones read as flat colored
	# regions; detail mode keeps fill subtle so terrain shows through.
	var fill_alpha: float = 0.35 if _mm_full_overview else 0.14
	var border_alpha: float = 0.95 if _mm_full_overview else 0.60
	var tile_px_x: float = cw / view_tiles
	var tile_px_y: float = ch / view_tiles
	var font := ThemeDB.fallback_font
	# Zone-fills legend toggle. Edit mode always forces zones visible so
	# the admin can see what they're editing regardless of the checkbox.
	var draw_zones: bool = _mm_show_zones or _mm_zone_edit_mode
	for z: Dictionary in (_WORLD_ZONES if draw_zones else []):
		var poly_world: PackedVector2Array = z["poly"]
		if poly_world.size() < 3:
			continue
		var col: Color = z["col"]
		# Project every tile-space vertex into canvas space + build a bbox
		# for the label + off-screen cull.
		var poly_canvas := PackedVector2Array()
		var bb_min := Vector2(INF, INF)
		var bb_max := Vector2(-INF, -INF)
		for v in poly_world:
			var cvx := (v.x - src_x) * tile_px_x
			var cvy := (v.y - src_y) * tile_px_y
			poly_canvas.append(Vector2(cvx, cvy))
			bb_min.x = min(bb_min.x, cvx)
			bb_min.y = min(bb_min.y, cvy)
			bb_max.x = max(bb_max.x, cvx)
			bb_max.y = max(bb_max.y, cvy)
		if bb_max.x < 0.0 or bb_min.x > cw or bb_max.y < 0.0 or bb_min.y > ch:
			continue
		_mm_full_canvas.draw_colored_polygon(poly_canvas,
			Color(col.r, col.g, col.b, fill_alpha))
		# Border — polyline that closes the loop.
		var border_pts := poly_canvas.duplicate()
		border_pts.append(poly_canvas[0])
		_mm_full_canvas.draw_polyline(border_pts,
			Color(col.r, col.g, col.b, border_alpha), 2.0)

		# Labels — toggled by the legend key so a cluttered map can be
		# stripped to just terrain + player. bbox center reads well enough
		# for convex zones; concave shapes may drift, easy to eyeball.
		if _mm_show_zone_labels:
			var name_size: int = 18 if _mm_full_overview else 13
			var lv_size: int = 12 if _mm_full_overview else 10
			var center := (bb_min + bb_max) * 0.5
			var name_str: String = str(z["name"])
			var lv_str: String = "Lv " + str(z["lv"])
			var nw: float = font.get_string_size(name_str, HORIZONTAL_ALIGNMENT_CENTER,
				-1, name_size).x
			var lw: float = font.get_string_size(lv_str, HORIZONTAL_ALIGNMENT_CENTER,
				-1, lv_size).x
			_mm_full_canvas.draw_string(font,
				Vector2(center.x - nw * 0.5, center.y),
				name_str, HORIZONTAL_ALIGNMENT_CENTER, -1, name_size,
				Color(1.0, 0.95, 0.75, 0.95))
			_mm_full_canvas.draw_string(font,
				Vector2(center.x - lw * 0.5, center.y + float(name_size)),
				lv_str, HORIZONTAL_ALIGNMENT_CENTER, -1, lv_size,
				Color(0.95, 0.85, 0.45, 0.90))

	# Admin edit overlay — draggable vertex handles on the selected zone.
	if _mm_zone_edit_mode:
		_draw_zone_edit_overlay(src_x, src_y, tile_px_x, tile_px_y, cw, ch)

	# Interactable dots — scale up so they read at high zoom. Skipped in
	# overview mode (zones are the story there) and when the legend key
	# toggles them off.
	if not _mm_full_overview and _mm_show_interactables:
		for node in get_tree().get_nodes_in_group("interactable"):
			if not node is Node2D:
				continue
			var n2d := node as Node2D
			var wx := n2d.global_position.x / 32.0
			var wy := n2d.global_position.y / 32.0
			var dx := (wx - src_x) * tile_px_x
			var dy := (wy - src_y) * tile_px_y
			if dx < 0.0 or dx > cw or dy < 0.0 or dy > ch:
				continue
			var itype: String = n2d.get("interactable_type_str") if n2d.get("interactable_type_str") != null else ""
			var dot_col: Color
			match itype:
				"rock":          dot_col = Color(0.65, 0.62, 0.60)
				"fish":          dot_col = Color(0.25, 0.55, 0.90)
				"herb":          dot_col = Color(0.45, 0.90, 0.30)
				"forge", "fire": dot_col = Color(0.90, 0.45, 0.10)
				"bank":          dot_col = Color(0.85, 0.70, 0.10)
				_:               dot_col = Color(0.20, 0.65, 0.20)
			_mm_full_canvas.draw_rect(Rect2(dx - 2.0, dy - 2.0, 4.0, 4.0), dot_col)

	# Player marker — bright yellow with heading arrow. Reads from anywhere.
	# Anchor to the building's exterior spot while inside an interior.
	if _player != null:
		var pmpos: Vector2 = GameManager.overworld_pos(_player.global_position)
		var pwx: float = pmpos.x / 32.0
		var pwy: float = pmpos.y / 32.0
		var px: float = (pwx - src_x) * tile_px_x
		var py: float = (pwy - src_y) * tile_px_y
		if px >= 0.0 and px <= cw and py >= 0.0 and py <= ch:
			_mm_full_canvas.draw_circle(Vector2(px, py), 6.0,
				Color(0.10, 0.10, 0.05))
			_mm_full_canvas.draw_circle(Vector2(px, py), 4.5,
				Color(1.0, 0.90, 0.20))
			# Heading arrow if the player exposes a facing hint.
			var facing: Variant = _player.get("_facing")
			if facing is Vector2:
				var f: Vector2 = (facing as Vector2).normalized() * 10.0
				_mm_full_canvas.draw_line(Vector2(px, py),
					Vector2(px + f.x, py + f.y),
					Color(1.0, 0.90, 0.20), 2.0)

func _mm_full_texture_ready() -> bool:
	return _minimap_texture != null

func _warband_sigil_color(warband_id: String) -> Color:
	if warband_id.is_empty():
		return Color(0.75, 0.20, 0.20)
	var h: int = warband_id.hash()
	var hue: float = float(h & 0xFFFF) / 65535.0
	return Color.from_hsv(hue, 0.65, 0.95, 1.0)

func _mm_color_for_biome(bname: String) -> Color:
	# Hills of ANY biome variant read as elevated terrain — grey per playtest.
	# Covers plains_hills / oak_hills / pine_hills / snow_hills / ashlands_hills
	# / helheim_hills / rocky_hills / sand_hills without a per-name row.
	if bname.ends_with("_hills"):
		# Tinted per parent biome so the map still reads which region the hill
		# sits in — snow hills lighter, helheim hills darker, etc.
		var base := Color(0.55, 0.53, 0.50)
		if bname.begins_with("snow"):
			return base.lightened(0.25)
		if bname.begins_with("helheim"):
			return base.darkened(0.35)
		if bname.begins_with("ashlands"):
			return Color(0.50, 0.40, 0.32)
		if bname.begins_with("sand"):
			return Color(0.68, 0.60, 0.42)
		return base
	match bname:
		"town":        return Color(0.52, 0.46, 0.36)
		"road":        return Color(0.52, 0.43, 0.28)
		"coast":       return Color(0.18, 0.50, 0.82)
		"ocean":       return Color(0.05, 0.12, 0.55)
		"snow":        return Color(0.82, 0.90, 0.96)
		"mountain":    return Color(0.52, 0.50, 0.48)
		"cliff":       return Color(0.30, 0.27, 0.25)
		"rocky":       return Color(0.42, 0.40, 0.37)
		"hills":       return Color(0.55, 0.53, 0.50)   # grey per playtest, not green
		"hill":        return Color(0.55, 0.53, 0.50)
		"dark_forest": return Color(0.07, 0.10, 0.06)
		"oak_forest":  return Color(0.16, 0.38, 0.12)
		"pine_forest": return Color(0.10, 0.26, 0.12)
		"swamp":       return Color(0.20, 0.27, 0.14)
		"helheim":     return Color(0.22, 0.06, 0.28)
		"ashlands":    return Color(0.42, 0.22, 0.06)
		_:             return Color(0.27, 0.46, 0.18)  # plains

# ── NPC Dialogue window ───────────────────────────────────────────────────────
func _build_dialogue_window() -> void:
	_dialogue_window = PanelContainer.new()
	_dialogue_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_dialogue_window.anchor_left   = 0.5; _dialogue_window.anchor_right  = 0.5
	_dialogue_window.anchor_top    = 1.0; _dialogue_window.anchor_bottom = 1.0
	_dialogue_window.offset_left   = -200; _dialogue_window.offset_right  = 200
	_dialogue_window.offset_top    = -320; _dialogue_window.offset_bottom = -180
	_dialogue_window.visible       = false
	add_child(_dialogue_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	_dialogue_window.add_child(root)

	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	_dialogue_npc_lbl = Label.new()
	_dialogue_npc_lbl.add_theme_color_override("font_color", RS_GOLD)
	_dialogue_npc_lbl.add_theme_font_size_override("font_size", 13)
	_dialogue_npc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_dialogue_npc_lbl)
	var xbtn := Button.new()
	xbtn.text = "✕"; xbtn.flat = true
	xbtn.add_theme_color_override("font_color", RS_DIM)
	xbtn.add_theme_font_size_override("font_size", 12)
	xbtn.pressed.connect(func() -> void: _dialogue_window.visible = false)
	title_row.add_child(xbtn)

	root.add_child(HSeparator.new())

	_dialogue_text_lbl = Label.new()
	_dialogue_text_lbl.add_theme_color_override("font_color", RS_TEXT)
	_dialogue_text_lbl.add_theme_font_size_override("font_size", 11)
	_dialogue_text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_text_lbl.custom_minimum_size = Vector2(360, 60)
	root.add_child(_dialogue_text_lbl)

	root.add_child(HSeparator.new())

	var dismiss := Button.new()
	dismiss.text = "Farewell"
	dismiss.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.3), 2))
	dismiss.add_theme_stylebox_override("hover",  _rs(RS_BTN_H, RS_BORDER, 2))
	dismiss.add_theme_color_override("font_color", RS_TEXT)
	dismiss.add_theme_font_size_override("font_size", 11)
	dismiss.pressed.connect(func() -> void: _dialogue_window.visible = false)
	root.add_child(dismiss)

func _on_npc_dialogue(npc_name: String, text: String) -> void:
	if _dialogue_window == null:
		return
	_dialogue_npc_lbl.text  = npc_name
	_dialogue_text_lbl.text = text
	_dialogue_window.visible = true
	_register_proximity_panel(_dialogue_window)

func _on_open_crafting() -> void:
	_refresh_craft()
	_craft_window.visible = true
	_register_proximity_panel(_craft_window)

# ── Construction window ───────────────────────────────────────────────────────
## Boats only — buildable structures are generated across material tiers by
## _build_all_construction_recipes() and combined with these at window build.
## Boat recipes — rebalanced so each hull needs hull-wood + metal fittings +
## a hide/sail material. User's spec for the Oak Rowboat (10-15 logs, 5-15
## iron bars, 2-5 hide) is anchored here; higher tiers scale all three
## ingredient groups along with their tier wood / bar / scale.
const _CONSTRUCTION_RECIPES: Array = [
	# ── Boats (the only way to travel on water) ───────────────────────────────
	{"name": "Oak Rowboat",       "id": "oak_rowboat",       "color": Color(0.55, 0.36, 0.18),
	 "input": [{"id": "oak_log",      "name": "Oak Log",      "qty": 12},
			   {"id": "iron_bar",     "name": "Iron Bar",     "qty": 8},
			   {"id": "wolf_pelt",    "name": "Wolf Pelt",    "qty": 3}],   "xp": 60,  "req_lv": 1},
	{"name": "Pine Canoe",        "id": "pine_canoe",        "color": Color(0.42, 0.26, 0.10),
	 "input": [{"id": "pine_log",     "name": "Pine Log",     "qty": 16},
			   {"id": "iron_bar",     "name": "Iron Bar",     "qty": 10},
			   {"id": "wolf_pelt",    "name": "Wolf Pelt",    "qty": 4}],  "xp": 120, "req_lv": 15},
	{"name": "Cherry Sailboat",   "id": "cherry_sailboat",   "color": Color(0.62, 0.30, 0.22),
	 "input": [{"id": "cherry_log",   "name": "Cherry Log",   "qty": 20},
			   {"id": "mithril_bar",  "name": "Mithril Bar",  "qty": 12},
			   {"id": "wolf_pelt",    "name": "Wolf Pelt",    "qty": 5}],   "xp": 220, "req_lv": 30},
	{"name": "Ironwood Longship", "id": "ironwood_longship", "color": Color(0.26, 0.15, 0.07),
	 "input": [{"id": "ironwood_log", "name": "Ironwood Log", "qty": 26},
			   {"id": "mithril_bar",  "name": "Mithril Bar",  "qty": 16},
			   {"id": "wolf_pelt",    "name": "Wolf Pelt",    "qty": 8}], "xp": 360, "req_lv": 50},
	{"name": "Frost Warship",     "id": "frost_warship",     "color": Color(0.60, 0.78, 0.92),
	 "input": [{"id": "frost_log",    "name": "Frost Log",    "qty": 32},
			   {"id": "adamant_bar",  "name": "Adamant Bar",  "qty": 20},
			   {"id": "wolf_pelt",    "name": "Wolf Pelt",    "qty": 10},
			   {"id": "dragon_scale", "name": "Dragon Scale", "qty": 1}], "xp": 520, "req_lv": 70},
	{"name": "Ancient Dragonship","id": "ancient_dragonship","color": Color(0.55, 0.40, 0.12),
	 "input": [{"id": "ancient_log",  "name": "Ancient Log",  "qty": 40},
			   {"id": "runite_bar",   "name": "Runite Bar",   "qty": 26},
			   {"id": "wolf_pelt",    "name": "Wolf Pelt",    "qty": 14},
			   {"id": "dragon_scale", "name": "Dragon Scale", "qty": 5}], "xp": 750, "req_lv": 85},
]

# Buildable structures. Every entry is generated in all six wood tiers (oak →
# ancient); higher tiers cost their tier's log (and scaled stone/metal/dust where
# noted), require more Construction, and award more XP (the tier "bonus").
# Row: [key, label, base_lv, log_count, extra]  extra ∈ {"", "stone", "bar", "dust"}
# Campfire / Storage Crate / Torch Post / Bookshelf moved to Crafting (small
# items + cooking fire + light furniture). Construction keeps only permanent
# structures, defensive works, civic buildings, and tier-scaled walls/gates.
const _BUILDABLES: Array = [
	["wall",           "Wooden Wall",     1,  4,  ""],
	["workbench",      "Workbench",       10, 6,  ""],
	["fence",          "Fence",           10, 4,  ""],
	["gate",           "Gate",            10, 6,  ""],
	["smith_station",  "Smith Station",   20, 8,  "bar"],
	["house_frame",    "House Frame",     20, 10, ""],
	["site_marker",    "Site Marker",     30, 4,  ""],
	["well",           "Well",            30, 8,  "stone"],
	["market_stall",   "Market Stall",    30, 8,  ""],
	["bank_chest",     "Bank Chest",      35, 10, "bar"],
	["plant_bed",      "Plant Bed",       35, 6,  ""],
	["altar",          "Altar",           40, 12, "stone"],
	["watchtower",     "Watchtower",      40, 14, "stone"],
	["large_house",    "Large House",     50, 20, "stone"],
	["dock",           "Dock",            50, 16, "stone"],
	["clan_hall",      "Clan Hall Frame", 60, 30, "bar"],
	["armory_rack",    "Armory Rack",     60, 12, "bar"],
	["fortified_wall", "Fortified Wall",  70, 10, "bar"],
	["guard_tower",    "Guard Tower",     70, 20, "stone"],
	["grand_hall",     "Grand Hall",      80, 40, "bar"],
	["portal_shrine",  "Portal Shrine",   80, 24, "dust"],
]
const _CONSTR_WOOD: Array = [
	["oak",      "oak_log",      "Oak Log",      Color(0.55, 0.36, 0.18)],
	["pine",     "pine_log",     "Pine Log",     Color(0.42, 0.30, 0.14)],
	["cherry",   "cherry_log",   "Cherry Log",   Color(0.72, 0.38, 0.42)],
	["ironwood", "ironwood_log", "Ironwood Log", Color(0.30, 0.18, 0.08)],
	["frost",    "frost_log",    "Frost Log",    Color(0.72, 0.90, 0.98)],
	["ancient",  "ancient_log",  "Ancient Log",  Color(0.55, 0.40, 0.12)],
]
const _CONSTR_BAR: Array = [
	["copper_bar", "Copper Bar"], ["iron_bar", "Iron Bar"], ["gold_bar", "Gold Bar"],
	["mithril_bar", "Mithril Bar"], ["adamant_bar", "Adamant Bar"], ["runite_bar", "Runite Bar"],
]

var _all_construction_recipes: Array = []

func _build_all_construction_recipes() -> Array:
	var out: Array = []
	for b: Array in _BUILDABLES:
		var key     := b[0] as String
		var label   := b[1] as String
		var base_lv := b[2] as int
		var logs    := b[3] as int
		var extra   := b[4] as String
		for ti in range(_CONSTR_WOOD.size()):
			var w: Array = _CONSTR_WOOD[ti]
			var input: Array = [{"id": w[1], "name": w[2], "qty": logs}]
			match extra:
				"stone":
					input.append({"id": "stone", "name": "Stone", "qty": 4 + ti})
				"bar":
					var bar: Array = _CONSTR_BAR[ti]
					input.append({"id": bar[0], "name": bar[1], "qty": 3 + ti})
				"dust":
					input.append({"id": "magic_dust", "name": "Magic Dust", "qty": 4 + ti})
			out.append({
				"name":   "%s %s" % [(w[0] as String).capitalize(), label],
				"id":     "%s_%s" % [w[0], key],
				"color":  w[3] as Color,
				"skill":  "construction",
				"input":  input,
				"xp":     int((base_lv * 2 + logs * 3) * (1.0 + ti * 0.5)),
				"req_lv": mini(99, base_lv + ti * 8),
			})
	# Farm Plot — late-game, gated by warband membership + Construction 10. Built
	# (not stored as an item): placed in the world and persisted server-side.
	out.append({"name": "Farm Plot", "id": "farm_plot", "color": Color(0.45, 0.30, 0.16),
		"skill": "construction",
		"input": [{"id": "oak_log", "name": "Oak Log", "qty": 10},
				  {"id": "stick",   "name": "Stick",   "qty": 5}],
		"xp": 120, "req_lv": 10})

	# ── Warband settlements (placed in world, persisted server-side) ──────
	# All three follow the farm_plot pattern: not added to inventory; the
	# server inserts them into `world_entities` with warband_id in `data`
	# JSON. Caps enforced server-side (1 stronghold + 12 banners + 3
	# outposts per banner per warband).
	out.append({"name": "Warband Stronghold", "id": "stronghold",
		"color": Color(0.55, 0.30, 0.18), "skill": "construction",
		"input": [{"id": "ironwood_log", "name": "Ironwood Log", "qty": 40},
				  {"id": "mithril_bar",  "name": "Mithril Bar",  "qty": 20},
				  {"id": "frost_log",    "name": "Frost Log",    "qty": 15}],
		"xp": 800, "req_lv": 50})
	out.append({"name": "Warband Banner", "id": "banner",
		"color": Color(0.85, 0.25, 0.25), "skill": "construction",
		"input": [{"id": "oak_log",  "name": "Oak Log",  "qty": 15},
				  {"id": "iron_bar", "name": "Iron Bar", "qty": 5}],
		"xp": 250, "req_lv": 5})
	out.append({"name": "Warband Outpost", "id": "outpost",
		"color": Color(0.62, 0.42, 0.20), "skill": "construction",
		"input": [{"id": "pine_log",  "name": "Pine Log",  "qty": 20},
				  {"id": "iron_bar",  "name": "Iron Bar",  "qty": 3}],
		"xp": 180, "req_lv": 5})

	# Boats remain craftable at the construction bench.
	for boat: Dictionary in _CONSTRUCTION_RECIPES:
		out.append(boat)
	return out

func _build_construction_window() -> void:
	_all_construction_recipes = _build_all_construction_recipes()
	# Taller window — ~4 rows of cards visible instead of 2.
	_construct_window = _build_recipe_window("🔨  Construction", _all_construction_recipes,
		"construction", func(r: Dictionary) -> void: _construct(r), 720.0)
	# Offsets are now managed inside _build_recipe_window (viewport-capped
	# at 80% of screen size so the X button stays reachable). The manual
	# override below was the source of the "800 px tall — X off-screen"
	# bug on smaller resolutions.
	_construct_window.visible = false

# ── Rune smithing window (right-click runestone) ──────────────────────────────
## Polish v3 — runestone right-click opens this; each recipe consumes essence
## (and dust at higher tiers) and produces a stackable rune the player can
## later use as ammo for Magic-style attacks. Recipes climb in 10-level steps
## from Air (lv 1) to Blood (lv 85), mirroring the forge/cooking cadence.
const _RUNE_RECIPES: Array = [
	{"name": "Air Rune",    "id": "air_rune",    "color": Color(0.78, 0.88, 0.95), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}], "xp": 5,   "req_lv": 1},
	{"name": "Mind Rune",   "id": "mind_rune",   "color": Color(0.55, 0.55, 0.85), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}], "xp": 7,   "req_lv": 5},
	{"name": "Water Rune",  "id": "water_rune",  "color": Color(0.30, 0.55, 0.90), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}], "xp": 10,  "req_lv": 10},
	{"name": "Earth Rune",  "id": "earth_rune",  "color": Color(0.45, 0.32, 0.18), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}], "xp": 12,  "req_lv": 15},
	{"name": "Fire Rune",   "id": "fire_rune",   "color": Color(0.90, 0.35, 0.18), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}], "xp": 15,  "req_lv": 20},
	{"name": "Ice Rune",    "id": "ice_rune",    "color": Color(0.60, 0.85, 0.95), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}], "xp": 17,  "req_lv": 22},
	{"name": "Body Rune",   "id": "body_rune",   "color": Color(0.80, 0.45, 0.45), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 1}], "xp": 18,  "req_lv": 25},
	{"name": "Cosmic Rune", "id": "cosmic_rune", "color": Color(0.65, 0.80, 0.95), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 1}], "xp": 22,  "req_lv": 35},
	{"name": "Chaos Rune",  "id": "chaos_rune",  "color": Color(0.70, 0.30, 0.55), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 2}], "xp": 30,  "req_lv": 45},
	{"name": "Nature Rune", "id": "nature_rune", "color": Color(0.30, 0.75, 0.35), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 2}], "xp": 38,  "req_lv": 55},
	{"name": "Law Rune",    "id": "law_rune",    "color": Color(0.90, 0.85, 0.40), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 3}], "xp": 50,  "req_lv": 65},
	{"name": "Death Rune",  "id": "death_rune",  "color": Color(0.45, 0.40, 0.55), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 3}], "xp": 62,  "req_lv": 75},
	{"name": "Blood Rune",  "id": "blood_rune",  "color": Color(0.65, 0.15, 0.20), "skill": "magic",
	 "input": [{"id": "rune_essence", "name": "Rune Essence", "qty": 1}, {"id": "magic_dust", "name": "Magic Dust", "qty": 4}], "xp": 78,  "req_lv": 85},
]

func _build_rune_window() -> void:
	_rune_window = _build_recipe_window("🜂  Rune Smithing", _RUNE_RECIPES, "magic",
		func(r: Dictionary) -> void: _craft_rune(r), 420.0)
	# Offsets set inside the builder (viewport-capped at 80%).
	_rune_window.visible = false

func _on_open_runesmithing() -> void:
	_refresh_rune()
	_rune_window.visible = true
	_register_proximity_panel(_rune_window)

func _refresh_rune() -> void:
	_refresh_recipe_window(_RUNE_RECIPES, "magic", _rune_recipe_btns)

func _craft_rune(recipe: Dictionary) -> void:
	var magic_lv := GameManager.get_skill_level("magic")
	if magic_lv < (recipe["req_lv"] as int):
		return
	# ⑤ Server owns the consume + grant + XP + burn roll (pushes the result).
	_request_server_craft(recipe, "magic")
	_refresh_rune()

## inventory_changed hook — only does work while the construction panel is open.
func _refresh_construction_if_visible() -> void:
	if _construct_window != null and _construct_window.visible:
		_refresh_construction()

func _refresh_construction() -> void:
	_refresh_recipe_window(_all_construction_recipes, "construction", _construct_recipe_btns)

func _construct(recipe: Dictionary) -> void:
	# Farm Plot + warband structures are placed in the world (warband-gated),
	# not added as inventory items. The server persists them in world_entities.
	var rid := str(recipe.get("id", ""))
	if rid == "farm_plot":
		_build_farm_plot(recipe)
		return
	if rid == "stronghold" or rid == "banner" or rid == "outpost":
		_build_warband_structure(rid, recipe)
		return
	# Wall + fortified_wall recipes: place at the player's position rather
	# than adding an inventory item. The recipe id is "<wood>_wall" or
	# "<wood>_fortified_wall" — split to derive the subtype + wood tier.
	if rid.ends_with("_wall") or rid.ends_with("_fortified_wall"):
		_build_wall(recipe)
		return
	# Item constructs (campfire / storage crate / torch post / bookshelf) — these
	# land in the bag, so route through the ⑤ server choke point. The placement
	# builds above (farm plot / warband / wall) stay on their own server RPCs.
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
			return
	_request_server_craft(recipe, "construction")
	_refresh_construction()

## Player-crafted wall placement. Mirrors _build_farm_plot — deducts
## materials, grants XP, then RPCs the server to insert a world_entity at
## the player's current position. Server does its own construction-level
## check but does NOT re-validate materials (client already deducted).
func _build_wall(recipe: Dictionary) -> void:
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
			Events.chat_message.emit("You lack the materials for a %s." % recipe["name"])
			return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	for ing: Dictionary in recipe["input"] as Array:
		GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int)
	GameManager.add_xp("construction", recipe["xp"] as int)
	var pos := (players[0] as Node2D).global_position
	var rid := str(recipe["id"])
	var subtype: String = "fortified_wall" if rid.ends_with("_fortified_wall") else "wall"
	var wood: String = rid.replace("_fortified_wall", "").replace("_wall", "")
	var c: Color = recipe["color"] as Color
	NetworkManager.send_build_wall(subtype, wood, pos.x, pos.y,
		str(recipe["name"]),
		[c.r, c.g, c.b, c.a])
	_refresh_construction()

func _build_farm_plot(recipe: Dictionary) -> void:
	if _clan.is_empty():
		Events.chat_message.emit("You must be in a warband to build a farm plot.")
		return
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
			Events.chat_message.emit("You lack the materials for a farm plot.")
			return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	for ing: Dictionary in recipe["input"] as Array:
		GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int)
	GameManager.add_xp("construction", recipe["xp"] as int)
	var pos := (players[0] as Node2D).global_position
	NetworkManager.send_build_farm_plot(pos.x, pos.y)
	_refresh_construction()

## Place a warband structure (stronghold / banner / outpost) at the player's
## current world position. Same envelope as `_build_farm_plot`: gate on
## warband membership, take materials, grant XP, RPC the server. The server
## enforces all spacing / cap rules and broadcasts world_entity_add for
## every nearby client to render.
func _build_warband_structure(kind: String, recipe: Dictionary) -> void:
	if _clan.is_empty():
		Events.chat_message.emit("You must be in a warband to build a %s." % kind)
		return
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
			Events.chat_message.emit("You lack the materials for a %s." % kind)
			return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	# Local mat deduction + XP grant. Server can still reject (cap hit /
	# spacing violation) — if it does, the server's chat_message response
	# tells the player and the mats/XP need to be refunded. v1 ships
	# optimistic; refund path comes later if the rejection rate is high.
	for ing: Dictionary in recipe["input"] as Array:
		GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int)
	GameManager.add_xp("construction", recipe["xp"] as int)
	var pos := (players[0] as Node2D).global_position
	NetworkManager.send_build_warband_structure(kind, pos.x, pos.y)
	_refresh_construction()

func _on_open_construction() -> void:
	_refresh_construction()
	_construct_window.visible = true

# ── Shop window (Phase 3 of the gold economy) ────────────────────────────────
# Built once at startup, never freed. Per-shop buy rows cached so reopening
# the same shop is just a visibility toggle (the cache rule). Sell rows are
# rebuilt only when inventory_changed fires AND the panel is visible.

var _shop_window:        PanelContainer  = null
var _shop_title_lbl:     Label           = null
var _shop_gold_lbl:      Label           = null
var _shop_buy_tab_btn:   Button          = null
var _shop_sell_tab_btn:  Button          = null
var _shop_buy_scroll:    ScrollContainer = null
var _shop_sell_scroll:   ScrollContainer = null
var _shop_buy_root:      VBoxContainer   = null    # parent of per-shop VBoxes
var _shop_sell_list:     VBoxContainer   = null

var _shop_current_npc_id:    String     = ""
var _shop_current_shop_id:   String     = ""
var _shop_current_buy_mult:  float      = 1.0
var _shop_current_sell_mult: float      = 0.20

## Cache of fully-built per-shop buy sections so reopening a shop never
## rebuilds rows. Shape per shop_id:
##   { "container": VBoxContainer, "rows": {item_id: {row, stock_lbl, buy_btn1, buy_btn10}} }
var _shop_buy_section_cache: Dictionary = {}

# ── PvP-Token gear upgrades (Phase 1d) ──────────────────────────────────────
# Spend the server-owned PvP-Token currency to permanently boost a gear piece.
# 4 levels; cumulative stat multiplier +4% / +10% / +15% / +30% (see
# Equipment._UP_MULT); the final (+4) step also grants a chosen bonus trait.
# Every upgrade is a server round-trip — the server validates + deducts tokens
# and mints the new item id, so a client can't fake a boost.
var _token_window: PanelContainer = null
var _token_balance_lbl: Label = null
var _token_list: VBoxContainer = null
var _token_trait_opt: OptionButton = null
var _token_open_btn: Button = null
const _TOKEN_TRAIT_KEYS: Array = ["hp", "def", "atk", "ratk", "matk"]
const _TOKEN_TRAIT_LABELS: Array = ["+30 Health", "+10 Defense", "+6 Melee Atk",
	"+6 Ranged Atk", "+6 Magic Atk"]
## Cumulative % boost shown per level (index = level). Mirrors Equipment._UP_MULT.
const _TOKEN_PCT: Array = [0, 4, 10, 15, 30]
## Display mirrors of Equipment.UPGRADE_MAX_LEVEL / UPGRADE_COST. HUD is
## display-only here — the server is authoritative on cost, and Equipment.gd
## owns the real stat math — so keeping local copies avoids coupling the HUD's
## parse to Equipment internals (and keeps these values in one obvious place).
## Keep in sync with Equipment.UPGRADE_COST + server TOKEN_UPGRADE_COST.
const _TOKEN_MAX_LEVEL: int = 4
const _TOKEN_COST: Dictionary = {1: 10, 2: 20, 3: 30, 4: 100}

## Current upgrade level encoded in an item id's "~u{level}" suffix (0 = none).
## Local parse mirror of Equipment.upgrade_level so the row builder doesn't
## depend on that static func resolving through the preload.
func _token_level_of(item_id: String) -> int:
	var i := item_id.find("~u")
	if i < 0:
		return 0
	var rest := item_id.substr(i + 2)
	var t := rest.find("~")
	return clampi(int(rest if t < 0 else rest.substr(0, t)), 0, _TOKEN_MAX_LEVEL)

func _refresh_token_open_btn() -> void:
	if _token_open_btn == null:
		return
	_token_open_btn.text = "⚒ Upgrades (%d)" % GameManager.pvp_tokens

func _build_token_upgrade_window() -> void:
	_token_window = PanelContainer.new()
	_token_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_token_window.anchor_left = 0.5; _token_window.anchor_right = 0.5
	_token_window.anchor_top  = 0.5; _token_window.anchor_bottom = 0.5
	_token_window.offset_left = -230; _token_window.offset_right = 230
	_token_window.offset_top  = -270; _token_window.offset_bottom = 270
	_token_window.visible = false
	add_child(_token_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_token_window.add_child(root)

	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := _tab_title("⚒  Gear Upgrades")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"; close_btn.flat = true
	close_btn.add_theme_color_override("font_color", RS_DIM)
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.pressed.connect(func() -> void: _token_window.visible = false)
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	_token_balance_lbl = Label.new()
	_token_balance_lbl.add_theme_color_override("font_color", RS_GOLD)
	_token_balance_lbl.add_theme_font_size_override("font_size", 12)
	root.add_child(_token_balance_lbl)

	# Final-tier (+4) bonus picker — applies only to the +4 step.
	var trait_row := HBoxContainer.new()
	trait_row.add_theme_constant_override("separation", 4)
	root.add_child(trait_row)
	var trait_lbl := Label.new()
	trait_lbl.text = "Final (+4) bonus:"
	trait_lbl.add_theme_color_override("font_color", RS_TEXT)
	trait_lbl.add_theme_font_size_override("font_size", 10)
	trait_row.add_child(trait_lbl)
	_token_trait_opt = OptionButton.new()
	_token_trait_opt.add_theme_font_size_override("font_size", 10)
	for i in range(_TOKEN_TRAIT_LABELS.size()):
		_token_trait_opt.add_item(str(_TOKEN_TRAIT_LABELS[i]), i)
	trait_row.add_child(_token_trait_opt)

	var hint := Label.new()
	hint.text = "Boosts: +4% / +10% / +15% / +30% stats.  Cost 10 / 20 / 30 / 100 tokens."
	hint.add_theme_color_override("font_color", RS_DIM)
	hint.add_theme_font_size_override("font_size", 9)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)

	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_token_list = VBoxContainer.new()
	_token_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_token_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_token_list)

	Events.pvp_tokens_changed.connect(func(_b: int) -> void: _refresh_token_upgrade_ui())
	Events.equipment_changed.connect(_refresh_token_upgrade_ui_if_visible)
	Events.inventory_changed.connect(_refresh_token_upgrade_ui_if_visible)

func open_token_upgrade_window() -> void:
	_refresh_token_upgrade_ui()
	_token_window.visible = true
	_register_proximity_panel(_token_window)

func _refresh_token_upgrade_ui_if_visible() -> void:
	if _token_window != null and _token_window.visible:
		_refresh_token_upgrade_ui()

## Rebuild the upgrade list from the current loadout + backpack. A piece is
## upgradeable if it's equippable combat gear (weapon/armor/jewelry, not bait)
## and — for backpack pieces — a single (qty 1) item.
func _refresh_token_upgrade_ui() -> void:
	if _token_list == null:
		return
	_refresh_token_open_btn()
	if _token_balance_lbl != null:
		_token_balance_lbl.text = "PvP Tokens: %d" % GameManager.pvp_tokens
	for c in _token_list.get_children():
		c.queue_free()
	var candidates: Array = []   # each: {"slot": String, "id": String}
	for slot: String in GameManager.equipment.keys():
		var eid := str(GameManager.equipment[slot])
		if eid != "" and _token_can_upgrade(eid):
			candidates.append({"slot": slot, "id": eid})
	for item: Dictionary in GameManager.inventory:
		var iid := str(item.get("id", ""))
		if int(item.get("qty", 1)) <= 1 and _token_can_upgrade(iid):
			candidates.append({"slot": "", "id": iid})
	if candidates.is_empty():
		var empty := Label.new()
		empty.text = "No upgradeable gear equipped or in your bag."
		empty.add_theme_color_override("font_color", RS_DIM)
		empty.add_theme_font_size_override("font_size", 10)
		_token_list.add_child(empty)
		return
	for cand: Dictionary in candidates:
		_token_list.add_child(_make_token_upgrade_row(
			str(cand["slot"]), str(cand["id"])))

func _token_can_upgrade(item_id: String) -> bool:
	if not GearDB.is_equippable(item_id):
		return false
	var d := GearDB.def_for(item_id)
	return str(d.get("slot", "")) != "bait"

func _make_token_upgrade_row(slot: String, item_id: String) -> Control:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _rs(Color(0.16, 0.11, 0.05), RS_BORDER, 1))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	row.add_child(hb)

	var cur := _token_level_of(item_id)
	var d := GearDB.def_for(item_id)
	var where := " (worn)" if slot != "" else " (bag)"

	var name_lbl := Label.new()
	name_lbl.text = "%s%s" % [str(d.get("name", item_id)), where]
	name_lbl.add_theme_color_override("font_color", RS_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(name_lbl)

	if cur >= _TOKEN_MAX_LEVEL:
		var maxed := Label.new()
		maxed.text = "MAX +%d" % _TOKEN_MAX_LEVEL
		maxed.add_theme_color_override("font_color", RS_GREEN)
		maxed.add_theme_font_size_override("font_size", 11)
		hb.add_child(maxed)
		return row

	var next := cur + 1
	var cost := int(_TOKEN_COST.get(next, 0))
	var btn := Button.new()
	var pct := int(_TOKEN_PCT[next]) if next < _TOKEN_PCT.size() else 0
	if next >= _TOKEN_MAX_LEVEL:
		btn.text = "+%d  (%d tok, +%d%%+trait)" % [next, cost, pct]
	else:
		btn.text = "+%d  (%d tok, +%d%%)" % [next, cost, pct]
	btn.add_theme_font_size_override("font_size", 10)
	btn.disabled = GameManager.pvp_tokens < cost
	btn.pressed.connect(func() -> void:
		var trt := ""
		if next >= _TOKEN_MAX_LEVEL:
			var idx: int = _token_trait_opt.get_selected_id() if _token_trait_opt != null else 0
			if idx < 0 or idx >= _TOKEN_TRAIT_KEYS.size():
				idx = 0
			trt = str(_TOKEN_TRAIT_KEYS[idx])
		NetworkManager.send_token_upgrade(item_id, slot, trt))
	hb.add_child(btn)
	return row

# ── How-to Guides overlay (V1.5.5) ──────────────────────────────────────────
## A simple library of how-to pages (GuideData.GUIDES) — topic list on the left,
## the selected page's text on the right. Opened from Settings → Guides.
func _show_guides() -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 205
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			overlay.queue_free())
	overlay.add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_GOLD, 3))
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5;  panel.anchor_bottom = 0.5
	panel.offset_left = -300; panel.offset_right = 300
	panel.offset_top = -215;  panel.offset_bottom = 215
	overlay.add_child(panel)
	var margin := MarginContainer.new()
	for m: String in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	panel.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "📖  Guides"
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var start_tut := Button.new()
	start_tut.text = "▶ Start Tutorial"
	start_tut.add_theme_font_size_override("font_size", 12)
	start_tut.add_theme_color_override("font_color", RS_GOLD)
	header.add_child(start_tut)
	var close := Button.new()
	close.text = "✕"
	close.add_theme_font_size_override("font_size", 14)
	close.pressed.connect(func() -> void: overlay.queue_free())
	header.add_child(close)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(190, 0)
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(list_scroll)
	var list_vb := VBoxContainer.new()
	list_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_vb.add_theme_constant_override("separation", 3)
	list_scroll.add_child(list_vb)

	var text_scroll := ScrollContainer.new()
	text_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(text_scroll)
	var text_lbl := Label.new()
	text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_lbl.add_theme_color_override("font_color", RS_TEXT)
	text_lbl.add_theme_font_size_override("font_size", 13)
	text_scroll.add_child(text_lbl)

	# Shared holder so the Start-Tutorial button always targets the shown topic
	# (GDScript lambdas capture by value, so mutate through this dict).
	var cur := {"g": {}}
	var show_guide := func(g: Dictionary) -> void:
		cur["g"] = g
		text_lbl.text = "%s\n\n%s" % [str(g.get("title", "")), str(g.get("body", ""))]
		var gid := str(g.get("id", ""))
		var has_tut := gid == "start" or (_GuideData.TUTORIALS as Dictionary).has(gid)
		start_tut.visible = has_tut
	start_tut.pressed.connect(func() -> void:
		var g := cur["g"] as Dictionary
		if g.is_empty():
			return
		overlay.queue_free()
		start_topic_tutorial(str(g.get("id", "")), str(g.get("title", "")))
	)
	for entry: Variant in _GuideData.GUIDES:
		var g := entry as Dictionary
		var b := Button.new()
		b.text = "%s  %s" % [str(g.get("icon", "•")), str(g.get("title", ""))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 12)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void: show_guide.call(g))
		list_vb.add_child(b)
	if not (_GuideData.GUIDES as Array).is_empty():
		show_guide.call(_GuideData.GUIDES[0] as Dictionary)

# ── First-login tutorial (Phase 2a) ────────────────────────────────────────
# A skippable, pointer-guided first run: gather sticks → gather stones → open
# Crafting → craft a Wooden Axe. Auto-runs once per account (a client-side
# per-username flag), replayable from Settings. The gold arrow points at the
# current target (nearest world node, or a UI button); the box at top-center
# holds the instruction + a persistent Skip.
const _TUTORIAL_CFG := "user://tutorial.cfg"
const _TUTORIAL_STICKS := 3
const _TUTORIAL_STONES := 2
var _tutorial_step: int = -1          # -1 = inactive; 0-3 = active auto steps
var _tutorial_layer: CanvasLayer = null
var _tutorial_box: PanelContainer = null
var _tutorial_title_lbl: Label = null
var _tutorial_lbl: Label = null
var _tutorial_arrow: Label = null
var _tutorial_next_btn: Button = null
var _tutorial_t: float = 0.0
# Manual (guide-topic) walkthrough state: a list of instruction steps advanced by
# the Next button. Runs independently of the auto-detected getting-started flow
# (which uses _tutorial_step >= 0); manual mode leaves _tutorial_step at -1.
var _tut_manual: Array = []
var _tut_manual_idx: int = -1

func _tutorial_seen(username: String) -> bool:
	if username == "":
		return true   # no account context → don't auto-run
	var cfg := ConfigFile.new()
	cfg.load(_TUTORIAL_CFG)   # missing file → all defaults (not seen)
	return bool(cfg.get_value("seen", username, false))

func _mark_tutorial_seen(username: String) -> void:
	if username == "":
		return
	var cfg := ConfigFile.new()
	cfg.load(_TUTORIAL_CFG)
	cfg.set_value("seen", username, true)
	cfg.save(_TUTORIAL_CFG)

func _build_tutorial() -> void:
	_tutorial_layer = CanvasLayer.new()
	_tutorial_layer.layer = 90
	_tutorial_layer.visible = false
	add_child(_tutorial_layer)

	_tutorial_arrow = Label.new()
	_tutorial_arrow.text = "▼"
	_tutorial_arrow.add_theme_font_size_override("font_size", 40)
	_tutorial_arrow.add_theme_color_override("font_color", RS_GOLD)
	_tutorial_arrow.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_tutorial_arrow.add_theme_constant_override("outline_size", 4)
	_tutorial_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tutorial_layer.add_child(_tutorial_arrow)

	_tutorial_box = PanelContainer.new()
	_tutorial_box.add_theme_stylebox_override("panel", _rs(RS_BG, RS_GOLD, 3))
	_tutorial_box.anchor_left = 0.5; _tutorial_box.anchor_right = 0.5
	_tutorial_box.anchor_top = 0.0;  _tutorial_box.anchor_bottom = 0.0
	_tutorial_box.offset_left = -235; _tutorial_box.offset_right = 235
	_tutorial_box.offset_top = 64;    _tutorial_box.offset_bottom = 150
	_tutorial_layer.add_child(_tutorial_box)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_tutorial_box.add_child(vb)
	_tutorial_title_lbl = Label.new()
	_tutorial_title_lbl.text = "⭐  Getting Started"
	_tutorial_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tutorial_title_lbl.add_theme_color_override("font_color", RS_GOLD)
	_tutorial_title_lbl.add_theme_font_size_override("font_size", 13)
	vb.add_child(_tutorial_title_lbl)
	_tutorial_lbl = Label.new()
	_tutorial_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tutorial_lbl.custom_minimum_size = Vector2(0, 30)
	_tutorial_lbl.add_theme_color_override("font_color", RS_TEXT)
	_tutorial_lbl.add_theme_font_size_override("font_size", 12)
	vb.add_child(_tutorial_lbl)
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 8)
	vb.add_child(btn_row)
	var stop := Button.new()
	stop.text = "✕ Stop Tutorial"
	stop.add_theme_font_size_override("font_size", 11)
	stop.pressed.connect(func() -> void: _end_tutorial())
	btn_row.add_child(stop)
	# Only shown for guide-topic walkthroughs (the auto flow advances itself).
	_tutorial_next_btn = Button.new()
	_tutorial_next_btn.text = "Next ▶"
	_tutorial_next_btn.add_theme_font_size_override("font_size", 11)
	_tutorial_next_btn.visible = false
	_tutorial_next_btn.pressed.connect(func() -> void: _tut_manual_advance())
	btn_row.add_child(_tutorial_next_btn)

func start_tutorial() -> void:
	if _tutorial_layer == null:
		return
	_tut_manual = []
	_tut_manual_idx = -1
	if _tutorial_next_btn != null:
		_tutorial_next_btn.visible = false
	if _tutorial_title_lbl != null:
		_tutorial_title_lbl.text = "⭐  Getting Started"
	_tutorial_step = 0
	_tutorial_t = 0.0
	_tutorial_layer.visible = true
	_tutorial_update_text()

func _end_tutorial() -> void:
	var was_manual := _tut_manual_idx >= 0
	_tutorial_step = -1
	_tut_manual = []
	_tut_manual_idx = -1
	if _tutorial_next_btn != null:
		_tutorial_next_btn.visible = false
	if _tutorial_arrow != null:
		_tutorial_arrow.visible = false
	if _tutorial_layer != null:
		_tutorial_layer.visible = false
	# Only the getting-started auto flow counts as "seen" (so it stops
	# auto-running on login); stopping a guide walkthrough must not suppress it.
	if not was_manual:
		_mark_tutorial_seen(NetworkManager.my_username)

# ── Guide-topic walkthroughs (Guides double as tutorials) ──────────────────
# Runs a stepped, Next-advanced walkthrough for a guide topic. The "start" topic
# instead launches the hands-on gather→craft first-run tutorial.
func start_topic_tutorial(guide_id: String, guide_title: String) -> void:
	if _tutorial_layer == null:
		return
	if guide_id == "start":
		start_tutorial()
		return
	var steps: Array = (_GuideData.TUTORIALS as Dictionary).get(guide_id, [])
	if steps.is_empty():
		Events.top_toast.emit("No walkthrough for this topic yet.")
		return
	# Leave the auto flow off; drive purely off the manual step list.
	_tutorial_step = -1
	_tut_manual = steps
	_tut_manual_idx = 0
	if _tutorial_title_lbl != null:
		_tutorial_title_lbl.text = "📖  %s" % guide_title
	if _tutorial_arrow != null:
		_tutorial_arrow.visible = false
	_tutorial_layer.visible = true
	_tut_manual_show()

func _tut_manual_show() -> void:
	if _tut_manual_idx < 0 or _tut_manual_idx >= _tut_manual.size():
		return
	if _tutorial_lbl != null:
		_tutorial_lbl.text = "(%d/%d)  %s" % [_tut_manual_idx + 1, _tut_manual.size(), str(_tut_manual[_tut_manual_idx])]
	if _tutorial_next_btn != null:
		_tutorial_next_btn.visible = true
		_tutorial_next_btn.text = "Finish ✓" if _tut_manual_idx >= _tut_manual.size() - 1 else "Next ▶"

func _tut_manual_advance() -> void:
	_tut_manual_idx += 1
	if _tut_manual_idx >= _tut_manual.size():
		_end_tutorial()
		return
	_tut_manual_show()

func _tutorial_finish() -> void:
	_tutorial_step = -1
	if _tutorial_arrow != null:
		_tutorial_arrow.visible = false
	if _tutorial_lbl != null:
		_tutorial_lbl.text = "🎉  You crafted your first tool — you're all set!\nReplay anytime from Settings."
	_mark_tutorial_seen(NetworkManager.my_username)
	get_tree().create_timer(4.5).timeout.connect(func() -> void:
		if _tutorial_layer != null:
			_tutorial_layer.visible = false)

func _tutorial_update_text() -> void:
	match _tutorial_step:
		0: _tutorial_lbl.text = "Gather %d Sticks — click the sticks lying on the ground." % _TUTORIAL_STICKS
		1: _tutorial_lbl.text = "Now gather %d Stones — click the stones on the ground." % _TUTORIAL_STONES
		2: _tutorial_lbl.text = "Open Crafting — click the 💎 button on the tab bar (bottom-left)."
		3: _tutorial_lbl.text = "Craft a Wooden Axe — press its Craft button (needs %d sticks + %d stones)." % [_TUTORIAL_STICKS, _TUTORIAL_STONES]

func _tutorial_tick(delta: float) -> void:
	_tutorial_t += delta
	var advance := false
	match _tutorial_step:
		0: advance = GameManager.get_item_qty("stick") >= _TUTORIAL_STICKS
		1: advance = GameManager.get_item_qty("stone") >= _TUTORIAL_STONES
		2: advance = _craft_window != null and _craft_window.visible
		3: advance = GameManager.get_item_qty("wooden_axe") >= 1
	if advance:
		_tutorial_step += 1
		if _tutorial_step > 3:
			_tutorial_finish()
			return
		_tutorial_update_text()
	# Point the bouncing arrow at the current target (world node or UI button).
	var target := _tutorial_target_pos()
	if target.x <= -9000.0:
		_tutorial_arrow.visible = false
	else:
		_tutorial_arrow.visible = true
		var bounce := sin(_tutorial_t * 5.0) * 6.0
		_tutorial_arrow.position = target + Vector2(-13.0, -52.0 + bounce)

func _tutorial_target_pos() -> Vector2:
	match _tutorial_step:
		0: return _nearest_node_screen("stick")
		1: return _nearest_node_screen("stone")
		2:
			var b := _tab_buttons.get("crf") as Control
			if b != null:
				return b.get_global_rect().get_center()
		3:
			if _craft_window != null and _craft_window.visible:
				return _craft_window.get_global_rect().get_center()
	return Vector2(-9999.0, -9999.0)

## Screen position of the nearest world node with the given interactable type,
## or a sentinel far off-screen if none exist / the player isn't spawned.
func _nearest_node_screen(type_str: String) -> Vector2:
	if _player == null or not is_instance_valid(_player):
		return Vector2(-9999.0, -9999.0)
	var ppos := (_player as Node2D).global_position
	var best: Node2D = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("interactable"):
		if str(n.get("interactable_type_str")) == type_str:
			var d := ppos.distance_squared_to((n as Node2D).global_position)
			if d < best_d:
				best_d = d
				best = n as Node2D
	if best == null:
		return Vector2(-9999.0, -9999.0)
	return get_viewport().get_canvas_transform() * best.global_position

# ── Fast travel (Phase 2b) — discover-then-pay ─────────────────────────────
# Towns unlock as fast-travel destinations once you've walked near them; after
# that you can jump there for a gold fee (server-charged). Discovered set is a
# client-side per-username flag (user://travel.cfg). Town centers mirror the
# server's _TRAVEL_TOWNS + Ground.gd _is_town ranges.
const _TRAVEL_CFG := "user://travel.cfg"
const _TRAVEL_DISCOVER_RADIUS := 320.0   # ~10 tiles
const _TRAVEL_TOWNS: Array = [
	{"id": "kjelvik",   "name": "Kjelvik",         "pos": Vector2(2672, 3696)},
	{"id": "frostheim", "name": "Frostheim",       "pos": Vector2(1392, 944)},
	{"id": "ironwood",  "name": "Ironwood Keep",   "pos": Vector2(3568, 4976)},
	{"id": "eastmark",  "name": "Eastmark Post",   "pos": Vector2(5936, 5872)},
	{"id": "bjorn",     "name": "Bjorn's Landing", "pos": Vector2(7888, 4432)},
]
var _discovered_towns: Dictionary = {}
var _discover_timer: float = 0.0
var _travel_window: PanelContainer = null
var _travel_list: VBoxContainer = null
var _travel_open_btn: Button = null

func _load_discovered_towns(username: String) -> void:
	_discovered_towns.clear()
	if username == "":
		return
	var cfg := ConfigFile.new()
	cfg.load(_TRAVEL_CFG)
	for t: Variant in (cfg.get_value("discovered", username, []) as Array):
		_discovered_towns[str(t)] = true

func _save_discovered_towns() -> void:
	var u := NetworkManager.my_username
	if u == "":
		return
	var cfg := ConfigFile.new()
	cfg.load(_TRAVEL_CFG)
	cfg.set_value("discovered", u, _discovered_towns.keys())
	cfg.save(_TRAVEL_CFG)

## Throttled proximity check (every 0.5s) that unlocks a town on foot.
func _discovery_tick(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	_discover_timer -= delta
	if _discover_timer > 0.0:
		return
	_discover_timer = 0.5
	var ppos := (_player as Node2D).global_position
	for t: Dictionary in _TRAVEL_TOWNS:
		var tid := str(t["id"])
		if _discovered_towns.has(tid):
			continue
		if ppos.distance_to(t["pos"] as Vector2) <= _TRAVEL_DISCOVER_RADIUS:
			_discovered_towns[tid] = true
			_save_discovered_towns()
			NetworkManager.send_discover_town(tid)   # persist the 1-time unlock server-side
			Events.chat_message.emit("🗺  Discovered %s — fast travel unlocked!" % str(t["name"]))
			if _travel_window != null and _travel_window.visible:
				_refresh_travel_window()

## Client cost preview — mirrors the server's _fast_travel_cost. The server
## re-derives + charges the authoritative amount.
func _travel_cost(town_pos: Vector2) -> int:
	if _player == null:
		return 100
	var dist_tiles := (_player as Node2D).global_position.distance_to(town_pos) / 32.0
	return clampi(int(50 + dist_tiles * 2.0), 50, 300)

func _build_travel_window() -> void:
	_travel_window = PanelContainer.new()
	_travel_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_travel_window.anchor_left = 0.5; _travel_window.anchor_right = 0.5
	_travel_window.anchor_top = 0.5;  _travel_window.anchor_bottom = 0.5
	_travel_window.offset_left = -185; _travel_window.offset_right = 185
	_travel_window.offset_top = -175;  _travel_window.offset_bottom = 175
	_travel_window.visible = false
	add_child(_travel_window)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_travel_window.add_child(root)
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := _tab_title("🗺  Fast Travel")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"; close_btn.flat = true
	close_btn.add_theme_color_override("font_color", RS_DIM)
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.pressed.connect(func() -> void: _travel_window.visible = false)
	title_row.add_child(close_btn)
	root.add_child(HSeparator.new())
	var hint := Label.new()
	hint.text = "Visit a town on foot to unlock it, then travel there for a small fee."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", RS_DIM)
	hint.add_theme_font_size_override("font_size", 9)
	root.add_child(hint)
	root.add_child(HSeparator.new())
	_travel_list = VBoxContainer.new()
	_travel_list.add_theme_constant_override("separation", 4)
	_travel_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_travel_list)

	# Open button — right edge, under the ⚒ Upgrades button.
	_travel_open_btn = Button.new()
	_travel_open_btn.anchor_left = 1.0; _travel_open_btn.anchor_right = 1.0
	_travel_open_btn.anchor_top = 0.0;  _travel_open_btn.anchor_bottom = 0.0
	_travel_open_btn.offset_left = -174; _travel_open_btn.offset_right = -6
	_travel_open_btn.offset_top = 242;   _travel_open_btn.offset_bottom = 266
	_travel_open_btn.text = "🗺 Travel"
	_travel_open_btn.add_theme_font_size_override("font_size", 11)
	_travel_open_btn.pressed.connect(open_travel_window)
	add_child(_travel_open_btn)

func open_travel_window() -> void:
	_refresh_travel_window()
	_travel_window.visible = true
	_register_proximity_panel(_travel_window)

func _refresh_travel_window() -> void:
	if _travel_list == null:
		return
	for c in _travel_list.get_children():
		c.queue_free()
	for t: Dictionary in _TRAVEL_TOWNS:
		var tid := str(t["id"])
		var tpos := t["pos"] as Vector2
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _rs(Color(0.16, 0.11, 0.05), RS_BORDER, 1))
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		row.add_child(hb)
		var name_lbl := Label.new()
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 11)
		hb.add_child(name_lbl)
		if _discovered_towns.has(tid):
			var cost := _travel_cost(tpos)
			var here := _player != null and (_player as Node2D).global_position.distance_to(tpos) < 96.0
			name_lbl.text = str(t["name"])
			name_lbl.add_theme_color_override("font_color", RS_TEXT)
			var btn := Button.new()
			btn.text = "You're here" if here else "Travel (%dg)" % cost
			btn.add_theme_font_size_override("font_size", 10)
			btn.disabled = here or GameManager.gold < cost
			var jump_id := tid
			btn.pressed.connect(func() -> void:
				_travel_window.visible = false
				NetworkManager.send_fast_travel(jump_id))
			hb.add_child(btn)
		else:
			name_lbl.text = str(t["name"])
			name_lbl.add_theme_color_override("font_color", RS_DIM)
			var lock := Label.new()
			lock.text = "🔒 visit on foot"
			lock.add_theme_color_override("font_color", RS_DIM)
			lock.add_theme_font_size_override("font_size", 9)
			hb.add_child(lock)
		_travel_list.add_child(row)

func _build_shop_window() -> void:
	_shop_window = PanelContainer.new()
	_shop_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	_shop_window.anchor_left   = 0.5;  _shop_window.anchor_right  = 0.5
	_shop_window.anchor_top    = 0.5;  _shop_window.anchor_bottom = 0.5
	_shop_window.offset_left   = -200; _shop_window.offset_right  = 200
	_shop_window.offset_top    = -260; _shop_window.offset_bottom = 260
	_shop_window.visible       = false
	add_child(_shop_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_shop_window.add_child(root)

	# Title row + close
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	_shop_title_lbl = _tab_title("Shop")
	_shop_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_shop_title_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.flat = true
	close_btn.add_theme_color_override("font_color", RS_DIM)
	close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.pressed.connect(_on_shop_close_pressed)
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	# Gold display
	_shop_gold_lbl = Label.new()
	_shop_gold_lbl.add_theme_color_override("font_color", RS_GOLD)
	_shop_gold_lbl.add_theme_font_size_override("font_size", 11)
	root.add_child(_shop_gold_lbl)

	# Tab buttons
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	root.add_child(tab_row)
	_shop_buy_tab_btn = _shop_make_tab_btn("Buy", true)
	_shop_sell_tab_btn = _shop_make_tab_btn("Sell", false)
	_shop_buy_tab_btn.pressed.connect(func() -> void: _shop_show_tab("buy"))
	_shop_sell_tab_btn.pressed.connect(func() -> void: _shop_show_tab("sell"))
	tab_row.add_child(_shop_buy_tab_btn)
	tab_row.add_child(_shop_sell_tab_btn)

	# Buy scroll (holds per-shop VBoxes, only one visible at a time)
	_shop_buy_scroll = ScrollContainer.new()
	_shop_buy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_shop_buy_scroll)
	_shop_buy_root = VBoxContainer.new()
	_shop_buy_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_buy_root.add_theme_constant_override("separation", 2)
	_shop_buy_scroll.add_child(_shop_buy_root)

	# Sell scroll (single list, rebuilt on inventory_changed)
	_shop_sell_scroll = ScrollContainer.new()
	_shop_sell_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shop_sell_scroll.visible = false
	root.add_child(_shop_sell_scroll)
	_shop_sell_list = VBoxContainer.new()
	_shop_sell_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_sell_list.add_theme_constant_override("separation", 2)
	_shop_sell_scroll.add_child(_shop_sell_list)

	# Inventory updates while the panel is visible should refresh the sell
	# tab so qty-owned columns stay in sync with bag state.
	Events.inventory_changed.connect(_refresh_shop_sell_if_visible)

func _shop_make_tab_btn(label: String, active: bool) -> Button:
	var b := Button.new()
	b.text = label
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bg := RS_BTN_A if active else RS_BTN_N
	b.add_theme_stylebox_override("normal",
		_rs(bg, RS_GOLD if active else RS_BORDER.darkened(0.4), 2))
	b.add_theme_stylebox_override("hover", _rs(RS_BTN_H, RS_BORDER, 2))
	b.add_theme_color_override("font_color", RS_GOLD)
	b.add_theme_font_size_override("font_size", 11)
	return b

func _shop_show_tab(which: String) -> void:
	var is_buy := which == "buy"
	if _shop_buy_scroll != null:  _shop_buy_scroll.visible = is_buy
	if _shop_sell_scroll != null: _shop_sell_scroll.visible = not is_buy
	if _shop_buy_tab_btn != null:
		_shop_buy_tab_btn.add_theme_stylebox_override("normal",
			_rs(RS_BTN_A if is_buy else RS_BTN_N,
				RS_GOLD if is_buy else RS_BORDER.darkened(0.4), 2))
	if _shop_sell_tab_btn != null:
		_shop_sell_tab_btn.add_theme_stylebox_override("normal",
			_rs(RS_BTN_A if not is_buy else RS_BTN_N,
				RS_GOLD if not is_buy else RS_BORDER.darkened(0.4), 2))
	if not is_buy:
		_refresh_shop_sell_if_visible()

## Returns the cached per-shop buy section, building it on first miss. Rows
## inside are cached too — switching shops or stock counts never tears them
## down. The container's visibility is the only thing that changes.
func _shop_get_or_build_buy_section(shop_id: String) -> Dictionary:
	if _shop_buy_section_cache.has(shop_id):
		return _shop_buy_section_cache[shop_id]
	var template: Dictionary = ShopCatalog.data(shop_id)
	var container := VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 2)
	container.visible = false
	_shop_buy_root.add_child(container)
	var rows: Dictionary = {}
	for entry: Variant in template.get("stock_template", []):
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry as Dictionary
		var row_info := _shop_build_buy_row(e, shop_id)
		container.add_child(row_info["row"] as Control)
		rows[str(e["id"])] = row_info
	var section := {"container": container, "rows": rows}
	_shop_buy_section_cache[shop_id] = section
	return section

func _shop_build_buy_row(entry: Dictionary, _shop_id: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	# Color dot
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	var col_arr: Array = entry.get("color", [0.7, 0.7, 0.7, 1.0]) as Array
	dot.color = Color(float(col_arr[0]), float(col_arr[1]), float(col_arr[2]),
		float(col_arr[3]) if col_arr.size() > 3 else 1.0)
	row.add_child(dot)
	# Name (expands)
	var name_lbl := Label.new()
	name_lbl.text = str(entry.get("name", entry.get("id", "?")))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color", RS_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(name_lbl)
	# Stock label
	var stock_lbl := Label.new()
	stock_lbl.text = "—"
	stock_lbl.custom_minimum_size = Vector2(54, 0)
	stock_lbl.add_theme_color_override("font_color", RS_DIM)
	stock_lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(stock_lbl)
	# Price label
	var price := int(round(float(ItemPrices.price_for(str(entry["id"])))))
	var price_lbl := Label.new()
	price_lbl.text = "%dg" % price
	price_lbl.custom_minimum_size = Vector2(48, 0)
	price_lbl.add_theme_color_override("font_color", RS_GOLD)
	price_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(price_lbl)
	# Buy buttons
	var item_id := str(entry["id"])
	# Gear stat block goes into the row tooltip so an equippable line
	# reveals its stats on hover without breaking the single-line layout.
	if GearDB.is_equippable(item_id):
		var block := _gear_stat_block(GearDB.def_for(item_id))
		if block != "":
			var full: String = "%s\n%s" % [str(entry.get("name", item_id)), block]
			row.tooltip_text = full
			name_lbl.tooltip_text = full
	var buy1 := _shop_make_action_btn("Buy 1")
	buy1.pressed.connect(_on_shop_buy_pressed.bind(item_id, 1))
	row.add_child(buy1)
	var buy10 := _shop_make_action_btn("Buy 10")
	buy10.pressed.connect(_on_shop_buy_pressed.bind(item_id, 10))
	row.add_child(buy10)
	return {"row": row, "stock_lbl": stock_lbl, "price_lbl": price_lbl,
			"buy1": buy1, "buy10": buy10}

func _shop_make_action_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(54, 22)
	b.add_theme_stylebox_override("normal",   _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	b.add_theme_stylebox_override("hover",    _rs(RS_BTN_H, RS_BORDER, 2))
	b.add_theme_stylebox_override("pressed",  _rs(RS_BTN_A, RS_GOLD, 2))
	b.add_theme_stylebox_override("disabled", _rs(RS_BTN_N, RS_BORDER.darkened(0.6), 1))
	b.add_theme_color_override("font_color", RS_GOLD)
	b.add_theme_color_override("font_disabled_color", RS_DIM)
	b.add_theme_font_size_override("font_size", 10)
	return b

func _shop_refresh_gold() -> void:
	if _shop_gold_lbl != null:
		_shop_gold_lbl.text = "Gold:  %d" % GameManager.gold

## Apply the {item_id → int qty} stock dict to the active section's cached
## row labels. No rebuild — just text updates and a button disable when
## stock hits zero.
func _shop_apply_stock(shop_id: String, stock: Dictionary) -> void:
	if not _shop_buy_section_cache.has(shop_id):
		return
	var rows: Dictionary = _shop_buy_section_cache[shop_id]["rows"]
	for item_id: String in rows.keys():
		var ri: Dictionary = rows[item_id]
		var qty: int = int(stock.get(item_id, 0))
		(ri["stock_lbl"] as Label).text = "Stock: %d" % qty
		(ri["buy1"]  as Button).disabled = qty < 1
		(ri["buy10"] as Button).disabled = qty < 1

func _refresh_shop_sell_if_visible() -> void:
	if _shop_window == null or not _shop_window.visible:
		return
	if _shop_sell_scroll == null or not _shop_sell_scroll.visible:
		# Refresh only when the sell tab is the active view — buy tab doesn't
		# care about inventory changes. Still cheap to skip otherwise.
		_shop_refresh_gold()
		return
	_shop_rebuild_sell_list()
	_shop_refresh_gold()

func _shop_rebuild_sell_list() -> void:
	if _shop_sell_list == null:
		return
	# Sell list rebuilds rather than caches — inventory is dynamic and
	# rebuilding ~28 rows on inventory_changed is cheap. The buy tab's row
	# cache remains intact across this.
	for ch: Node in _shop_sell_list.get_children():
		ch.queue_free()
	# Group inventory by item id so multiple stacks/slots collapse into one row.
	var by_id: Dictionary = {}
	for item: Dictionary in GameManager.inventory:
		var iid := str(item.get("id", ""))
		if iid == "":
			continue
		if ItemPrices.is_soulbound(iid):
			continue
		if not ItemPrices.is_priced(iid):
			continue
		if not by_id.has(iid):
			by_id[iid] = {"name": str(item.get("name", iid)),
						  "color": item.get("color", [0.7, 0.7, 0.7, 1.0]),
						  "qty": 0}
		(by_id[iid] as Dictionary)["qty"] = int((by_id[iid] as Dictionary)["qty"]) \
			+ int(item.get("qty", 1))
	if by_id.is_empty():
		var hint := Label.new()
		hint.text = "Nothing in your bag the shopkeeper will buy."
		hint.add_theme_color_override("font_color", RS_DIM)
		hint.add_theme_font_size_override("font_size", 11)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_shop_sell_list.add_child(hint)
		return
	for iid: String in by_id.keys():
		var info: Dictionary = by_id[iid]
		var row := _shop_build_sell_row(iid, info)
		_shop_sell_list.add_child(row)

func _shop_build_sell_row(item_id: String, info: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	var col_arr: Variant = info.get("color", [0.7, 0.7, 0.7, 1.0])
	if col_arr is Array:
		var ca: Array = col_arr as Array
		dot.color = Color(float(ca[0]), float(ca[1]), float(ca[2]),
			float(ca[3]) if ca.size() > 3 else 1.0)
	elif col_arr is Color:
		dot.color = col_arr as Color
	else:
		dot.color = Color(0.7, 0.7, 0.7)
	row.add_child(dot)
	var name_lbl := Label.new()
	name_lbl.text = str(info.get("name", item_id))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color", RS_TEXT)
	name_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(name_lbl)
	var qty: int = int(info.get("qty", 0))
	var qty_lbl := Label.new()
	qty_lbl.text = "Owned: %d" % qty
	qty_lbl.custom_minimum_size = Vector2(70, 0)
	qty_lbl.add_theme_color_override("font_color", RS_DIM)
	qty_lbl.add_theme_font_size_override("font_size", 10)
	row.add_child(qty_lbl)
	var unit := int(round(float(ItemPrices.price_for(item_id)) * _shop_current_sell_mult))
	var price_lbl := Label.new()
	price_lbl.text = "%dg" % unit
	price_lbl.custom_minimum_size = Vector2(48, 0)
	price_lbl.add_theme_color_override("font_color", RS_GOLD)
	price_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(price_lbl)
	var sell1 := _shop_make_action_btn("Sell 1")
	sell1.pressed.connect(_on_shop_sell_pressed.bind(item_id, 1))
	row.add_child(sell1)
	var sell_all_qty: int = qty
	var sell_all := _shop_make_action_btn("Sell %d" % sell_all_qty)
	sell_all.pressed.connect(_on_shop_sell_pressed.bind(item_id, sell_all_qty))
	row.add_child(sell_all)
	return row

# ── Shop event handlers ──────────────────────────────────────────────────────

func _on_open_shop(npc_id: String, shop_id: String) -> void:
	# Reserved id: the PvP-Token NPC opens the gear-upgrade window (Phase 1d)
	# instead of a buy/sell shop.
	if shop_id == "token_upgrade":
		open_token_upgrade_window()
		return
	if not ShopCatalog.is_shop(shop_id):
		Events.chat_message.emit("Unknown shop.")
		return
	_shop_current_npc_id  = npc_id
	_shop_current_shop_id = shop_id
	NetworkManager.send_shop_open(npc_id, shop_id)

func _on_shop_state_received(state: Dictionary) -> void:
	var shop_id := str(state.get("shop_id", ""))
	if shop_id == "":
		return
	_shop_current_shop_id   = shop_id
	_shop_current_npc_id    = str(state.get("npc_id", _shop_current_npc_id))
	_shop_current_buy_mult  = float(state.get("buy_multiplier", 1.0))
	_shop_current_sell_mult = float(state.get("sell_back_mult", 0.20))
	# Title
	if _shop_title_lbl != null:
		var sname := str(state.get("shop_name", ""))
		var town := str(ShopCatalog.data(shop_id).get("town", ""))
		_shop_title_lbl.text = "🏪  %s" % sname if town == "" else \
			"🏪  %s  (%s)" % [sname, town]
	# Buy section: ensure cached, hide all others, show this one, apply stock.
	_shop_get_or_build_buy_section(shop_id)
	for sid: String in _shop_buy_section_cache.keys():
		(_shop_buy_section_cache[sid]["container"] as Control).visible = (sid == shop_id)
	var stock_v: Variant = state.get("current_stock", {})
	var stock: Dictionary = stock_v if stock_v is Dictionary else {}
	_shop_apply_stock(shop_id, stock)
	# Reset to Buy tab on every open
	_shop_show_tab("buy")
	_shop_refresh_gold()
	_shop_window.visible = true
	_register_proximity_panel(_shop_window)

func _on_shop_result_received(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		var reason := str(result.get("reason", "Transaction failed."))
		Events.chat_message.emit(reason)
		return
	var stock_v: Variant = result.get("current_stock", null)
	if stock_v is Dictionary:
		_shop_apply_stock(_shop_current_shop_id, stock_v as Dictionary)
	# Server pushes gold_set + admin_inventory_set separately; refresh sell
	# tab here so its qty-owned column stays accurate on buy too.
	_refresh_shop_sell_if_visible()
	_shop_refresh_gold()

func _on_shop_buy_pressed(item_id: String, qty: int) -> void:
	if _shop_current_npc_id == "" or qty <= 0:
		return
	NetworkManager.send_shop_buy(_shop_current_npc_id, item_id, qty)

func _on_shop_sell_pressed(item_id: String, qty: int) -> void:
	if _shop_current_npc_id == "" or qty <= 0:
		return
	NetworkManager.send_shop_sell(_shop_current_npc_id, item_id, qty)

func _on_shop_close_pressed() -> void:
	if _shop_current_npc_id != "":
		NetworkManager.send_shop_close(_shop_current_npc_id)
	if _shop_window != null:
		_shop_window.visible = false
	_shop_current_npc_id  = ""
	_shop_current_shop_id = ""

# ── XP / Item toasts ─────────────────────────────────────────────────────────
## Coalescer for XP toasts. Without this, four parallel +5 Combat XP
## grants in the same combat tick spawn four separate floating labels
## that look like a glitch. Now a 0.5s window per skill batches them
## into a single "+20 Combat XP" toast.
var _xp_toast_buckets: Dictionary = {}    # skill → {amount: int, timer: Timer}

func _on_toast_xp(skill: String, amount: int) -> void:
	# In spectator mode the robust fixed-position spectate_feedback toast handles
	# this (the player-anchored path below doesn't render off the invisible puppet).
	if NetworkManager.spectating:
		return
	if _xp_toast_buckets.has(skill):
		var bucket: Dictionary = _xp_toast_buckets[skill]
		bucket["amount"] = int(bucket["amount"]) + amount
		return
	# First grant in this window — open a bucket with a one-shot timer.
	var t := get_tree().create_timer(0.5)
	_xp_toast_buckets[skill] = {"amount": amount, "timer": t}
	t.timeout.connect(func() -> void:
		if not _xp_toast_buckets.has(skill):
			return
		var b: Dictionary = _xp_toast_buckets[skill]
		var total: int = int(b["amount"])
		_xp_toast_buckets.erase(skill)
		var col: Color = SKILL_COLORS.get(skill, RS_GOLD) as Color
		_show_toast("+%d %s XP" % [total, skill.capitalize()], col))

func _on_toast_item(item_name: String, qty: int) -> void:
	if NetworkManager.spectating:
		return   # spectate_feedback handles it (see _on_spectate_feedback)
	_show_toast("+%d %s" % [qty, item_name], RS_TEXT)

## Robust spectator toast — fixed screen position, big + shadowed, independent of
## the (invisible puppet) player + camera. GUARANTEES the watched bot's XP/loot/
## level shows on the recording. Colour by kind.
var _spectate_toast_n: int = 0
func _on_spectate_feedback(text: String, kind: String) -> void:
	var col: Color = RS_GOLD
	match kind:
		"item":  col = Color(0.75, 0.95, 1.0)
		"level": col = Color(1.0, 0.95, 0.45)
		_:       col = RS_GOLD
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size = Vector2(300, 30)
	var start_y: float = vp.y * 0.40 - float(_spectate_toast_n) * 32.0
	lbl.position = Vector2(vp.x * 0.5 - 150.0, start_y)
	_spectate_toast_n += 1
	add_child(lbl)
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "position:y", start_y - 55.0, 1.9).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.9).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void:
		lbl.queue_free()
		_spectate_toast_n = maxi(0, _spectate_toast_n - 1))

func _show_toast(text: String, col: Color) -> void:
	if _player == null:
		return
	var canvas_pos: Vector2 = get_viewport().get_canvas_transform() * (_player as Node2D).global_position
	var lbl        := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	# Stack upward: each active toast shifts the next one higher
	var start_y: float = canvas_pos.y - 60.0 - _active_toasts * 18.0
	lbl.position = Vector2(canvas_pos.x - 38.0, start_y)
	_active_toasts += 1
	add_child(lbl)
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "position:y", start_y - 30.0, 1.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(lbl, "modulate:a", 0.0,            1.5).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.chain().tween_callback(func() -> void:
		lbl.queue_free()
		_active_toasts = maxi(0, _active_toasts - 1))

# ── Player context menu ───────────────────────────────────────────────────────
## Kjelvik castle is the ONE no-PvP zone in the world (everywhere else PvP is
## purely the player's own toggle). Mirrors server.py's CASTLE_SAFE_* bounds and
## Ground._is_town's Kjelvik range — keep all three in sync.
const _CASTLE_SAFE := Rect2(71 * 32, 105 * 32, 26 * 32, 24 * 32)

func _in_castle_safe_zone(world_pos: Vector2) -> bool:
	return _CASTLE_SAFE.has_point(world_pos)

func _on_player_context_menu(username: String, screen_pos: Vector2) -> void:
	var existing := get_node_or_null("PlayerCtxOverlay")
	if existing != null:
		existing.queue_free()

	# Invisible full-screen backdrop — catches outside clicks to dismiss
	var overlay := Control.new()
	overlay.name = "PlayerCtxOverlay"
	overlay.anchor_right  = 1.0
	overlay.anchor_bottom = 1.0
	overlay.mouse_filter  = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	overlay.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			overlay.queue_free())

	# Menu panel
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	var vp    := get_viewport().get_visible_rect().size
	var pw    := 148.0
	var px    := minf(screen_pos.x + 4.0, vp.x - pw - 4.0)
	var py    := minf(screen_pos.y + 4.0, vp.y - 136.0 - 4.0)
	panel.anchor_left   = 0.0; panel.anchor_top    = 0.0
	panel.offset_left   = px;  panel.offset_right  = px + pw
	panel.offset_top    = py;  panel.offset_bottom = py + 136.0
	panel.mouse_filter  = Control.MOUSE_FILTER_STOP
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	panel.add_child(vbox)

	# Player name header
	var hdr := Label.new()
	hdr.text = username
	hdr.add_theme_color_override("font_color", RS_GOLD)
	hdr.add_theme_font_size_override("font_size", 11)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)
	vbox.add_child(HSeparator.new())

	# Helper to create a menu row button
	var _row_btn := func(label: String, cb: Callable) -> Button:
		var b := Button.new()
		b.text = label
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_stylebox_override("normal",  _rs(RS_BG,    Color(0,0,0,0), 0))
		b.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER.darkened(0.5), 1))
		b.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, Color(0,0,0,0), 0))
		b.add_theme_stylebox_override("focus",   _rs(RS_BG,    Color(0,0,0,0), 0))
		b.add_theme_color_override("font_color", RS_TEXT)
		b.add_theme_font_size_override("font_size", 10)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(cb)
		return b

	# PvP "Attack" — only when BOTH sides are flagged and we're not in post-death
	# safe mode. Find the target's OtherPlayer node by username so we can check
	# its flag + engage the swing loop. Sits at the top of the menu.
	var target_node: Node = null
	for op in get_tree().get_nodes_in_group("other_player"):
		if str(op.get_meta("username", "")) == username:
			target_node = op
			break
	var target_flagged: bool = target_node != null \
		and target_node.has_method("is_pvp_flagged") \
		and bool(target_node.call("is_pvp_flagged"))
	# Attack shows whenever the TARGET is flagged. You don't have to be flagged
	# first — clicking Attack auto-flags you (handled in _on_attack_btn_pressed).
	# Hidden inside the Kjelvik castle walls — the one no-PvP zone (the server
	# rejects the swing there too; this just avoids offering a dead option).
	if target_flagged and not _in_castle_safe_zone(_player.global_position) \
			and not _in_castle_safe_zone((target_node as Node2D).global_position):
		vbox.add_child(_row_btn.call("⚔ Attack", func() -> void:
			overlay.queue_free()
			_select_target(target_node)
			_on_attack_btn_pressed()))

	vbox.add_child(_row_btn.call("Add Friend", func() -> void:
		overlay.queue_free()
		Events.chat_message.emit("[Friend request sent to %s]" % username)
		NetworkManager.send_friend_request(username)))

	vbox.add_child(_row_btn.call("Block", func() -> void:
		overlay.queue_free()
		Events.chat_message.emit("[%s has been blocked]" % username)
		NetworkManager._send({"type": "block_player", "target": username})))

	vbox.add_child(_row_btn.call("Trade", func() -> void:
		overlay.queue_free()
		_trade_partner = username
		NetworkManager.send_trade_request(username)
		Events.chat_message.emit("[Trade request sent to %s]" % username)))

	vbox.add_child(_row_btn.call("Highscores", func() -> void:
		overlay.queue_free()
		Events.chat_message.emit("[Looking up %s...]" % username)
		NetworkManager.send_player_lookup(username)))

## Left-click on a monster: select it as the panel target. The popup-menu
## flow is gone — the Attack button now lives INSIDE the unified combat /
## target panel ([HUD.gd _build_combat_window]) which auto-opens when a
## target is set. Clicking on the same monster again is a no-op so a
## fast double-click doesn't churn the panel state.
func _on_monster_clicked(monster: Node, _screen_pos: Vector2) -> void:
	if monster == null or not is_instance_valid(monster):
		return
	if _selected_target == monster:
		_combat_window.visible = true
		return
	_select_target(monster)

## Right-click on any actionable node — dispatches to a type-specific
## option list. The popup pattern mirrors the existing player context
## menu: a full-screen invisible overlay catches outside clicks to
## dismiss, the menu panel anchors under the cursor (clamped to viewport).
func _on_action_menu_requested(node: Node, screen_pos: Vector2) -> void:
	if node == null or not is_instance_valid(node):
		return
	var options := _action_menu_options(node)
	if options.is_empty():
		return   # nothing actionable — silent no-op

	var existing := get_node_or_null("ActionMenuOverlay")
	if existing != null:
		existing.queue_free()
	var overlay := Control.new()
	overlay.name = "ActionMenuOverlay"
	overlay.anchor_right  = 1.0
	overlay.anchor_bottom = 1.0
	overlay.mouse_filter  = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	overlay.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			overlay.queue_free())

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	var vp := get_viewport().get_visible_rect().size
	var pw := 150.0
	# 16 px header + 18 px per option (rough).
	var ph := 18.0 + float(options.size()) * 22.0 + 12.0
	var px := minf(screen_pos.x + 4.0, vp.x - pw - 4.0)
	var py := minf(screen_pos.y + 4.0, vp.y - ph - 4.0)
	panel.anchor_left = 0.0; panel.anchor_top = 0.0
	panel.offset_left = px;  panel.offset_right  = px + pw
	panel.offset_top  = py;  panel.offset_bottom = py + ph
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	panel.add_child(vbox)

	var hdr := Label.new()
	hdr.text = _action_menu_title(node)
	hdr.add_theme_color_override("font_color", RS_GOLD)
	hdr.add_theme_font_size_override("font_size", 10)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)
	vbox.add_child(HSeparator.new())

	var row_btn := func(label: String, cb: Callable) -> Button:
		var b := Button.new()
		b.text = label
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_stylebox_override("normal",  _rs(RS_BG,    Color(0,0,0,0), 0))
		b.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER.darkened(0.5), 1))
		b.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, Color(0,0,0,0), 0))
		b.add_theme_stylebox_override("focus",   _rs(RS_BG,    Color(0,0,0,0), 0))
		b.add_theme_color_override("font_color", RS_TEXT)
		b.add_theme_font_size_override("font_size", 10)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(cb)
		return b

	for opt: Dictionary in options:
		var label: String = str(opt.get("label", "?"))
		var cb: Callable = opt.get("cb", Callable())
		vbox.add_child(row_btn.call(label, func() -> void:
			overlay.queue_free()
			# Proximity gate for gather/interact actions. Action labels in
			# GATED_ACTION_LABELS require the player to be within
			# ACTION_PROXIMITY pixels of `node`; otherwise we toast and skip.
			if GATED_ACTION_LABELS.has(label) \
					and not _check_action_proximity(node, label):
				return
			if cb.is_valid():
				cb.call()))

## Returns true if the player is within ACTION_PROXIMITY px of `node`.
## On failure, fires a top-of-screen toast naming the node so the player
## knows what they're too far from. Used by the right-click action menu.
func _check_action_proximity(node: Node, _action_label: String) -> bool:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player == null or not (node is Node2D):
		return false
	# Measure distance to the structure's FOOTPRINT EDGE, not its centre — a
	# building's blocking body keeps the player at its wall, so a centre check
	# can never pass for anything larger than ACTION_PROXIMITY across. This adds
	# the ~1-tile ACTION_PROXIMITY tolerance OUT from the walls, as intended.
	var pp := (_player as Node2D).global_position
	var np := (node as Node2D).global_position
	var half := _structure_footprint_half(node)
	var dx := maxf(0.0, absf(pp.x - np.x) - half.x)
	var dy := maxf(0.0, absf(pp.y - np.y) - half.y)
	var dist := Vector2(dx, dy).length()
	if dist <= ACTION_PROXIMITY:
		return true
	var name_s: String = "that"
	if node.get("display_name") != null:
		name_s = str(node.get("display_name"))
	_show_top_toast("You need to get closer to %s." % name_s,
		Color(0.95, 0.55, 0.30))
	return false

## Half-extents (px) of a structure's blocking body, so proximity can measure to
## its edge. Scans for any StaticBody2D child with a RectangleShape2D (covers the
## 2D _STRUCTURE_SIZES bodies AND the 3D client's added building collision).
func _structure_footprint_half(node: Node) -> Vector2:
	for child in node.get_children():
		if child is StaticBody2D:
			for gc in (child as Node).get_children():
				if gc is CollisionShape2D:
					var shp := (gc as CollisionShape2D).shape
					if shp is RectangleShape2D:
						return (shp as RectangleShape2D).size * 0.5
	return Vector2.ZERO

## Top-of-screen status toast. Anchored under the minimap-clear zone,
## centered horizontally. Holds 1 s then fades out over 1 s for a total
## 2 s lifespan. Replaces any existing top toast so spam doesn't stack.
func _show_top_toast(text: String, col: Color) -> void:
	var existing := get_node_or_null("TopToast")
	if existing != null:
		existing.queue_free()
	var lbl := Label.new()
	lbl.name = "TopToast"
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.anchor_left   = 0.0
	lbl.anchor_right  = 1.0
	lbl.offset_top    = 70.0
	lbl.offset_bottom = 92.0
	add_child(lbl)
	var tw := lbl.create_tween()
	tw.tween_interval(1.0)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.0)
	tw.tween_callback(func() -> void: lbl.queue_free())

## Build the action list for `node`. Monsters get Attack/Examine; each
## interactable type gets its own short list. Unknown types return an
## "Examine" fallback so the menu is never empty for a node the player
## could see and right-click. Each entry: { "label": String, "cb": Callable }.
func _action_menu_options(node: Node) -> Array:
	if node.is_in_group("other_player"):
		# PvP right-click menu — Attack only appears when both sides are
		# flagged. Examine reports HP would be ideal but the client only
		# knows what it's rendered; username is enough.
		var uname: String = str(node.get_meta("username", "?"))
		var flagged: bool = bool(node.call("is_pvp_flagged")) \
			if node.has_method("is_pvp_flagged") else false
		var opts: Array = [
			{"label": "Examine", "cb": func() -> void:
				var tag: String = "  [PvP]" if flagged else ""
				Events.chat_message.emit("> %s%s" % [uname, tag])},
		]
		if flagged and GameManager.pvp_flagged:
			# Route through _select_target so the combat panel shows the
			# player as the current target; the swing loop dispatches to
			# pvp_attack in _combat_tick.
			opts.insert(0, {"label": "Attack", "cb": func() -> void:
				_select_target(node)})
		return opts
	if node.is_in_group("monster"):
		# Hide Attack entirely on a corpse — the action would race the
		# despawn and spawn-then-collapse the combat panel. Examine
		# still works as a quick "what was this" peek.
		var monster_alive: bool = bool(node.get("is_alive")) if node.get("is_alive") != null else true
		if not monster_alive:
			return [
				{"label": "Examine", "cb": func() -> void:
					Events.chat_message.emit("> %s — slain." % str(node.get("display_name")))},
			]
		return [
			{"label": "Attack", "cb": func() -> void:
				_select_target(node)
				Events.monster_attack_chosen.emit(node)},
			{"label": "Examine", "cb": func() -> void:
				Events.chat_message.emit("> %s — Level %d, %d/%d HP." % [
					str(node.get("display_name")), int(node.get("level")),
					int(node.get("current_hp")), int(node.get("max_hp"))])},
		]
	if node.is_in_group("caravan"):
		# Trade caravans (Phase 5c). Only raidable in transit — the server
		# rejects hits on a parked wagon, so don't offer a dead option.
		var cv_alive: bool = bool(node.get("is_alive")) if node.get("is_alive") != null else false
		var cv_state: String = str(node.get("state"))
		if not cv_alive:
			return [{"label": "Examine", "cb": func() -> void:
				Events.chat_message.emit("> Trade caravan — wrecked." if cv_state != "stopped"
					else "> Trade caravan — parked under town protection.")}]
		if cv_state == "stopped":
			return [{"label": "Examine", "cb": func() -> void:
				Events.chat_message.emit("> Trade caravan — parked under town protection.")}]
		return [
			{"label": "Raid", "cb": func() -> void:
				_select_target(node)
				Events.monster_attack_chosen.emit(node)},
			{"label": "Examine", "cb": func() -> void:
				Events.chat_message.emit("> Trade caravan — %d/%d, bound for %s." % [
					int(node.get("current_hp")), int(node.get("max_hp")),
					str(node.get("next_town")).capitalize()])},
		]
	if node.is_in_group("npc"):
		# Town NPCs are killable (Phase 5b). Talk stays the primary action —
		# Attack is listed after it so a misclick doesn't start a murder.
		var npc_alive: bool = bool(node.get("is_alive")) if node.get("is_alive") != null else true
		var npc_name: String = str(node.get("display_name"))
		if not npc_alive:
			return [{"label": "Examine", "cb": func() -> void:
				Events.chat_message.emit("> %s — slain." % npc_name)}]
		var npc_opts: Array = []
		# Shopkeepers: a direct "Trade" that opens the shop straight away — no
		# talking through dialogue first (playtest ask). Listed FIRST so it's the
		# default action for a merchant.
		var npc_shop: String = str(node.get("shop_id")) if node.get("shop_id") != null else ""
		if str(node.get("npc_type")) == "shopkeeper" and npc_shop != "":
			var npc_eid: String = str(node.get_meta("edit_id", ""))
			npc_opts.append({"label": "Trade", "cb": func() -> void:
				Events.open_shop.emit(npc_eid, npc_shop)})
		npc_opts.append({"label": "Talk", "cb": func() -> void:
			Events.player_interacted.emit(node)})
		npc_opts.append({"label": "Attack", "cb": func() -> void:
			_select_target(node)
			Events.monster_attack_chosen.emit(node)})
		npc_opts.append({"label": "Examine", "cb": func() -> void:
			Events.chat_message.emit("> %s — %d/%d HP." % [
				npc_name, int(node.get("current_hp")), int(node.get("max_hp"))])})
		return npc_opts
	var t: String = str(node.get("interactable_type_str")) if node.get("interactable_type_str") != null else ""
	var name_s: String = str(node.get("display_name")) if node.get("display_name") != null else "this"
	match t:
		"tree":
			return [{"label": "Chop", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"rock":
			return [{"label": "Mine", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"fish":
			return [{"label": "Fish", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"herb":
			return [{"label": "Pick", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"essence":
			return [{"label": "Gather", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"forge":
			return [{"label": "Smith", "cb": func() -> void:
				Events.open_forge.emit()}]
		"fire":
			return [{"label": "Cook", "cb": func() -> void:
				Events.open_cooking.emit()}]
		"bank":
			return [{"label": "Use Bank", "cb": func() -> void:
				Events.open_bank.emit()}]
		"crafting":
			return [
				{"label": "Craft", "cb": func() -> void:
					Events.open_crafting.emit()},
				{"label": "Jewelcraft", "cb": func() -> void:
					open_jewelcrafting()},
			]
		"farm_plot":
			# Action depends on the plot's (locally-promoted) stage: empty →
			# plant popup; growing → Water (when the 5-min boost window is up)
			# + Examine; ripe → Harvest.
			var eid: String = str(node.get("entity_id"))
			var stage: int = int(node.call("get_farm_stage")) if node.has_method("get_farm_stage") else 0
			match stage:
				2:
					return [{"label": "Harvest", "cb": func() -> void:
						NetworkManager.send_farm_harvest(eid)}]
				1:
					var acts: Array = [{"label": "Examine", "cb": func() -> void:
						Events.chat_message.emit("> Still growing…")}]
					if node.has_method("farm_can_water") and bool(node.call("farm_can_water")):
						acts.push_front({"label": "💧 Water", "cb": func() -> void:
							NetworkManager.send_farm_water(eid)})
					return acts
				_:
					return [{"label": "Plant", "cb": func() -> void:
						_open_farm_plant_popup(eid)}]
		"construction":
			return [{"label": "Build", "cb": func() -> void:
				Events.open_construction.emit()}]
		"runestone":
			return [
				{"label": "Study",      "cb": func() -> void: Events.player_interacted.emit(node)},
				{"label": "Runesmith",  "cb": func() -> void: Events.open_runesmithing.emit()},
			]
		"archery":
			return [{"label": "Train", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"auction_house":
			return [{"label": "Browse", "cb": func() -> void:
				Events.open_auction_house.emit()}]
		"door", "building":
			return [{"label": "Enter", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"dungeon_entrance":
			return [{"label": "Enter cave", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"exit_door":
			return [{"label": "Leave building", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"banner":
			return [{"label": "Raid / Reinforce", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"stronghold", "outpost":
			return [{"label": "Inspect", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
		"wall", "fortified_wall", "fence", "gate", \
		"watchtower", "guard_tower", "house_frame", "large_house", \
		"grand_hall", "clan_hall", "well", "altar", "dock", \
		"market_stall", "site_marker", "portal_shrine", "workbench", \
		"smith_station", "bank_chest", "armory_rack", "plant_bed":
			var opts: Array = []
			var alive: bool = bool(node.get("structure_alive"))
			var s_hp: int = int(node.get("structure_hp"))
			var s_max: int = int(node.get("structure_max_hp"))
			# Attack fires the left-click damage flow via Events.player_interacted.
			if alive:
				opts.append({"label": "Attack", "cb": func() -> void:
					Events.player_interacted.emit(node)})
			# Repair only shows when damaged. Server enforces owner/warband
			# gate; the client shows the option regardless of who owns it,
			# so a non-eligible player gets a "Only the owner..." chat back.
			if alive and s_max > 0 and s_hp < s_max and s_hp > 0:
				var eid: String = str(node.get("entity_id"))
				opts.append({"label": "Repair", "cb": func() -> void:
					NetworkManager.send_structure_repair(eid)})
			opts.append({"label": "Inspect", "cb": func() -> void:
				Events.chat_message.emit("You inspect the %s. (%d/%d HP)"
					% [str(node.get("display_name")),
					   max(0, s_hp), max(1, s_max)])})
			return opts
		"seal_statue":
			# The seal's action depends on its current state, which is
			# stored on the entity's meta. 'charged' → Awaken (gated
			# server-side on tokens + warband eligibility). 'breaking'
			# → Attack (chips integrity until shatter).
			var st: String = str(node.get_meta("seal_state", "charged"))
			if st == "breaking":
				return [{"label": "Attack the Seal", "cb": func() -> void:
					NetworkManager.send_seal_attack(8)}]
			return [{"label": "Awaken the Seal", "cb": func() -> void:
				NetworkManager.send_seal_awaken()}]
		"world_eater":
			return [{"label": "Witness", "cb": func() -> void:
				Events.chat_message.emit("> The Doom walks. Its eyes turn elsewhere.")}]
		"npc":
			return [{"label": "Talk", "cb": func() -> void:
				Events.player_interacted.emit(node)}]
	# Unknown interactable — still offer Examine so right-click is never silent.
	return [{"label": "Examine", "cb": func() -> void:
		Events.chat_message.emit("> You see %s." % name_s)}]

func _action_menu_title(node: Node) -> String:
	if node.is_in_group("monster"):
		return "%s (Lv %d)" % [str(node.get("display_name")), int(node.get("level"))]
	var nm: String = str(node.get("display_name")) if node.get("display_name") != null else "?"
	return nm

func _on_player_lookup_result(data: Dictionary) -> void:
	var username: String = str(data.get("username", "?"))
	var found: bool      = bool(data.get("found", false))

	# Modal overlay
	var overlay := CanvasLayer.new()
	overlay.layer = 201
	add_child(overlay)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	overlay.add_child(bg)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left   = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left   = -130; panel.offset_right  = 130
	panel.offset_top    = -180; panel.offset_bottom = 180
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "%s — Highscores" % username
	title.add_theme_color_override("font_color", RS_GOLD)
	title.add_theme_font_size_override("font_size", 12)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	if not found:
		var nl := Label.new()
		nl.text = "Player not found."
		nl.add_theme_color_override("font_color", RS_DIM)
		nl.add_theme_font_size_override("font_size", 10)
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(nl)
	else:
		var skill_xp: Dictionary = data.get("skill_xp", {}) as Dictionary
		var skills: Array[String] = ["woodcutting","mining","fishing","farming","jewelcrafting","combat",
					   "smithing","cooking","crafting","magic","ranged","construction"]
		for sk: String in skills:
			var xp: int = int(skill_xp.get(sk, 0))
			var lv: int = _xp_to_level(xp)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			vbox.add_child(row)
			var sk_lbl := Label.new()
			sk_lbl.text = sk.capitalize()
			sk_lbl.add_theme_color_override("font_color", RS_TEXT)
			sk_lbl.add_theme_font_size_override("font_size", 10)
			sk_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(sk_lbl)
			var lv_lbl := Label.new()
			lv_lbl.text = "Lv %d" % lv
			lv_lbl.add_theme_color_override("font_color", RS_GOLD)
			lv_lbl.add_theme_font_size_override("font_size", 10)
			row.add_child(lv_lbl)

	vbox.add_child(HSeparator.new())
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.3), 2))
	close_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 2))
	close_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   2))
	close_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.3), 2))
	close_btn.add_theme_color_override("font_color", RS_GOLD)
	close_btn.add_theme_font_size_override("font_size", 10)
	close_btn.pressed.connect(func() -> void: overlay.queue_free())
	vbox.add_child(close_btn)

func _xp_to_level(xp: int) -> int:
	var level := 1
	var needed := 0
	for i in range(1, 99):
		needed += int((i + 300.0 * pow(2.0, i / 7.0)) / 4.0)
		if xp >= needed:
			level = i + 1
		else:
			break
	return level

# ── Trading ───────────────────────────────────────────────────────────────────

func _on_trade_request_received(from_username: String) -> void:
	Events.chat_message.emit("[%s wants to trade with you.]" % from_username)
	# Inline accept/decline prompt in chat area
	var overlay := Control.new()
	overlay.name = "TradeRequestOverlay"
	overlay.anchor_right  = 1.0
	overlay.anchor_bottom = 1.0
	overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	panel.anchor_left   = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left   = -110; panel.offset_right  = 110
	panel.offset_top    = -32;  panel.offset_bottom = 32
	panel.mouse_filter  = Control.MOUSE_FILTER_STOP
	overlay.add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	panel.add_child(hbox)

	var lbl := Label.new()
	lbl.text = "Trade with %s?" % from_username
	lbl.add_theme_color_override("font_color", RS_TEXT)
	lbl.add_theme_font_size_override("font_size", 10)
	hbox.add_child(lbl)

	var acc := Button.new()
	acc.text = "Accept"
	acc.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
	acc.add_theme_font_size_override("font_size", 10)
	acc.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_trade_accept(from_username)
		_trade_partner = from_username
		_open_trade_window())
	hbox.add_child(acc)

	var dec := Button.new()
	dec.text = "Decline"
	dec.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	dec.add_theme_font_size_override("font_size", 10)
	dec.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_trade_cancel()
		Events.chat_message.emit("[Trade declined.]"))
	hbox.add_child(dec)

	# Auto-dismiss after 20 s
	var tw := overlay.create_tween()
	tw.tween_interval(20.0)
	tw.tween_callback(func() -> void:
		if is_instance_valid(overlay): overlay.queue_free())

func _open_trade_window() -> void:
	if _trade_window != null and is_instance_valid(_trade_window):
		_trade_window.queue_free()
	_trade_your_items.clear()
	_trade_their_items.clear()
	_trade_your_locked  = false
	_trade_their_locked = false
	_trade_your_gold    = 0
	_trade_their_gold   = 0
	_trade_gold_field   = null
	_trade_their_gold_lbl = null

	var win := PanelContainer.new()
	win.name = "TradeWindow"
	win.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	win.anchor_left   = 0.5; win.anchor_right  = 0.5
	win.anchor_top    = 0.5; win.anchor_bottom = 0.5
	win.offset_left   = -220; win.offset_right  = 220
	win.offset_top    = -200; win.offset_bottom = 200
	win.mouse_filter  = Control.MOUSE_FILTER_STOP
	add_child(win)
	_trade_window = win

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	win.add_child(root)

	# Title row
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title_lbl := Label.new()
	title_lbl.text = "Trade with %s" % _trade_partner
	title_lbl.add_theme_color_override("font_color", RS_GOLD)
	title_lbl.add_theme_font_size_override("font_size", 11)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.add_theme_font_size_override("font_size", 10)
	close_btn.pressed.connect(func() -> void:
		NetworkManager.send_trade_cancel()
		_trade_window.queue_free()
		_trade_window = null)
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	# Two-column item grids
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 6)
	root.add_child(cols)

	var your_box  := _trade_side_box("Your Offer", true)
	var their_box := _trade_side_box("Their Offer", false)
	cols.add_child(your_box)
	cols.add_child(VSeparator.new())
	cols.add_child(their_box)

	root.add_child(HSeparator.new())

	# Status label
	_trade_status_lbl = Label.new()
	_trade_status_lbl.text = "Add items, then Lock your offer."
	_trade_status_lbl.add_theme_color_override("font_color", RS_TEXT)
	_trade_status_lbl.add_theme_font_size_override("font_size", 10)
	_trade_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_trade_status_lbl)

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(btn_row)

	_trade_lock_btn = Button.new()
	_trade_lock_btn.text = "Lock Offer"
	_trade_lock_btn.add_theme_font_size_override("font_size", 10)
	_trade_lock_btn.pressed.connect(func() -> void:
		NetworkManager.send_trade_lock()
		_trade_your_locked = true
		_trade_lock_btn.disabled = true
		_trade_refresh_status())
	btn_row.add_child(_trade_lock_btn)

	_trade_confirm_btn = Button.new()
	_trade_confirm_btn.text = "Confirm Trade"
	_trade_confirm_btn.disabled = true
	_trade_confirm_btn.add_theme_font_size_override("font_size", 10)
	_trade_confirm_btn.pressed.connect(func() -> void:
		NetworkManager.send_trade_confirm()
		_trade_confirm_btn.disabled = true)
	btn_row.add_child(_trade_confirm_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 10)
	cancel_btn.pressed.connect(func() -> void:
		NetworkManager.send_trade_cancel()
		if _trade_window != null and is_instance_valid(_trade_window):
			_trade_window.queue_free()
			_trade_window = null)
	btn_row.add_child(cancel_btn)

func _trade_side_box(header: String, is_yours: bool) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var lbl := Label.new()
	lbl.text = header
	lbl.add_theme_color_override("font_color", RS_GOLD)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(lbl)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	box.add_child(grid)

	var slots: Array[Control] = []
	for i in range(16):
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(40, 40)
		var bg := Panel.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(bg)
		var icon := TextureRect.new()
		icon.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(20, 20)
		icon.anchor_left  = 0.5; icon.anchor_right  = 0.5
		icon.anchor_top   = 0.0; icon.anchor_bottom = 0.0
		icon.offset_left  = -10; icon.offset_right  = 10
		icon.offset_top   =  2;  icon.offset_bottom = 22
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon)
		var qty_lbl := Label.new()
		qty_lbl.anchor_left   = 0.0; qty_lbl.anchor_right  = 1.0
		qty_lbl.anchor_top    = 0.6; qty_lbl.anchor_bottom = 1.0
		qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty_lbl.add_theme_font_size_override("font_size", 8)
		qty_lbl.add_theme_color_override("font_color", RS_GOLD)
		qty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(qty_lbl)
		if is_yours:
			var si := i
			slot.gui_input.connect(func(ev: InputEvent) -> void:
				if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
						and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
						and not _trade_your_locked:
					_trade_remove_item(si))
		grid.add_child(slot)
		slots.append(slot)

	if is_yours:
		_trade_your_slots  = slots
	else:
		_trade_their_slots = slots

	# Gold row: editable field on your side, read-only label on theirs.
	var gold_row := HBoxContainer.new()
	gold_row.add_theme_constant_override("separation", 3)
	box.add_child(gold_row)
	var gicon := Label.new()
	gicon.text = "Gold:"
	gicon.add_theme_color_override("font_color", RS_GOLD)
	gicon.add_theme_font_size_override("font_size", 10)
	gold_row.add_child(gicon)
	if is_yours:
		_trade_gold_field = LineEdit.new()
		_trade_gold_field.placeholder_text = "0"
		_trade_gold_field.text = str(_trade_your_gold)
		_trade_gold_field.add_theme_font_size_override("font_size", 10)
		_trade_gold_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_trade_gold_field.text_changed.connect(func(t: String) -> void:
			if _trade_your_locked:
				return
			_trade_your_gold = clampi(t.to_int(), 0, GameManager.gold)
			NetworkManager.send_trade_offer(_trade_your_items, _trade_your_gold))
		gold_row.add_child(_trade_gold_field)
	else:
		_trade_their_gold_lbl = Label.new()
		_trade_their_gold_lbl.text = "0"
		_trade_their_gold_lbl.add_theme_color_override("font_color", RS_TEXT)
		_trade_their_gold_lbl.add_theme_font_size_override("font_size", 10)
		_trade_their_gold_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gold_row.add_child(_trade_their_gold_lbl)
	return box

func _trade_add_item(inv_index: int) -> void:
	# Click an inventory item to move its whole stack into your trade offer.
	if _trade_your_locked:
		return
	if inv_index >= GameManager.inventory.size():
		return
	var inv_item: Dictionary = GameManager.inventory[inv_index]
	var iid := str(inv_item.get("id", ""))
	for off: Dictionary in _trade_your_items:
		if str(off.get("id", "")) == iid:
			return  # already offering this stack
	if _trade_your_items.size() >= 16:
		Events.chat_message.emit("[Trade offer is full.]")
		return
	_trade_your_items.append(inv_item.duplicate())
	_trade_refresh_your_slots()
	NetworkManager.send_trade_offer(_trade_your_items, _trade_your_gold)

func _trade_remove_item(slot_idx: int) -> void:
	# Click an item in your offer grid to take it back.
	if _trade_your_locked:
		return
	if slot_idx >= _trade_your_items.size():
		return
	_trade_your_items.remove_at(slot_idx)
	_trade_refresh_your_slots()
	NetworkManager.send_trade_offer(_trade_your_items, _trade_your_gold)

func _trade_refresh_your_slots() -> void:
	for i in range(_trade_your_slots.size()):
		var slot := _trade_your_slots[i]
		var icon  := slot.get_child(1) as TextureRect
		var qty_l := slot.get_child(2) as Label
		if i < _trade_your_items.size() and not _trade_your_items[i].is_empty():
			var item := _trade_your_items[i]
			var path := "res://assets/icons/" + (item["id"] as String) + ".png"
			icon.texture = load(path) as Texture2D if ResourceLoader.exists(path) else null
			qty_l.text = "x%d" % (item["qty"] as int) if (item["qty"] as int) > 1 else ""
		else:
			icon.texture = null
			qty_l.text   = ""

func _trade_refresh_their_slots() -> void:
	for i in range(_trade_their_slots.size()):
		var slot := _trade_their_slots[i]
		var icon  := slot.get_child(1) as TextureRect
		var qty_l := slot.get_child(2) as Label
		if i < _trade_their_items.size() and not _trade_their_items[i].is_empty():
			var item := _trade_their_items[i]
			var path := "res://assets/icons/" + (item["id"] as String) + ".png"
			icon.texture = load(path) as Texture2D if ResourceLoader.exists(path) else null
			qty_l.text = "x%d" % (item["qty"] as int) if (item["qty"] as int) > 1 else ""
		else:
			icon.texture = null
			qty_l.text   = ""

func _trade_refresh_status() -> void:
	if _trade_status_lbl == null or not is_instance_valid(_trade_status_lbl):
		return
	if _trade_your_locked and _trade_their_locked:
		_trade_status_lbl.text = "Both locked — click Confirm to complete."
		if _trade_confirm_btn != null:
			_trade_confirm_btn.disabled = false
	elif _trade_your_locked:
		_trade_status_lbl.text = "Waiting for %s to lock..." % _trade_partner
	elif _trade_their_locked:
		_trade_status_lbl.text = "%s has locked their offer. Lock yours to proceed." % _trade_partner
	else:
		_trade_status_lbl.text = "Click inventory items to offer them. Then Lock."

func _on_trade_offer_updated(their_items: Array, your_items: Array, their_gold: int, your_gold: int) -> void:
	_trade_their_items.clear()
	for item: Variant in their_items:
		if item is Dictionary:
			_trade_their_items.append(item as Dictionary)
	_trade_your_items.clear()
	for item: Variant in your_items:
		if item is Dictionary:
			_trade_your_items.append(item as Dictionary)
	_trade_their_gold = their_gold
	_trade_your_gold  = your_gold
	if _trade_window == null or not is_instance_valid(_trade_window):
		_open_trade_window()
	_trade_refresh_their_slots()
	_trade_refresh_your_slots()
	if _trade_their_gold_lbl != null and is_instance_valid(_trade_their_gold_lbl):
		_trade_their_gold_lbl.text = str(_trade_their_gold)
	# Reflect the authoritative gold figure without stomping the field mid-type.
	if _trade_gold_field != null and is_instance_valid(_trade_gold_field) \
			and not _trade_gold_field.has_focus():
		_trade_gold_field.text = str(_trade_your_gold)

func _on_trade_confirmed(their_lock: bool, your_lock: bool) -> void:
	_trade_their_locked = their_lock
	_trade_your_locked  = your_lock
	if _trade_lock_btn != null:
		_trade_lock_btn.disabled = _trade_your_locked
	_trade_refresh_status()

func _on_trade_completed() -> void:
	Events.chat_message.emit("[Trade complete!]")
	if _trade_window != null and is_instance_valid(_trade_window):
		_trade_window.queue_free()
		_trade_window = null
	_trade_your_items.clear()
	_trade_their_items.clear()

func _on_trade_cancelled(reason: String) -> void:
	Events.chat_message.emit("[Trade cancelled: %s]" % reason)
	if _trade_window != null and is_instance_valid(_trade_window):
		_trade_window.queue_free()
		_trade_window = null

# ── Auction House ─────────────────────────────────────────────────────────────

func _on_open_auction_house() -> void:
	# Toggle close if already open
	if _ah_window != null and is_instance_valid(_ah_window):
		_ah_window.queue_free()
		_ah_window = null
		return
	# Require an active server connection — the AH is fully server-authoritative
	if NetworkManager.state != NetworkManager.NetState.LOGGED_IN:
		Events.chat_message.emit("[Auction House unavailable — no server connection.]")
		return
	_ah_window = _build_ah_window()
	add_child(_ah_window)
	NetworkManager.send_ah_browse()
	NetworkManager.send_ah_my_listings()

func _build_ah_window() -> PanelContainer:
	var win := PanelContainer.new()
	win.name = "AuctionHouseWindow"
	win.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	win.anchor_left   = 0.5; win.anchor_right  = 0.5
	win.anchor_top    = 0.5; win.anchor_bottom = 0.5
	win.offset_left   = -270; win.offset_right  = 270
	win.offset_top    = -230; win.offset_bottom = 230
	win.mouse_filter  = Control.MOUSE_FILTER_STOP

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	win.add_child(root)

	# Title row
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title_lbl := Label.new()
	title_lbl.text = "Auction House"
	title_lbl.add_theme_color_override("font_color", RS_GOLD)
	title_lbl.add_theme_font_size_override("font_size", 12)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.add_theme_font_size_override("font_size", 10)
	close_btn.pressed.connect(func() -> void:
		if _ah_window != null and is_instance_valid(_ah_window):
			_ah_window.queue_free()
			_ah_window = null)
	title_row.add_child(close_btn)
	root.add_child(HSeparator.new())

	# Tab bar
	var tab_bar := TabContainer.new()
	tab_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_bar.add_theme_font_size_override("font_size", 10)
	root.add_child(tab_bar)

	# ── Browse tab ────────────────────────────────────────
	var browse_root := VBoxContainer.new()
	browse_root.name = "Browse"
	browse_root.add_theme_constant_override("separation", 3)
	tab_bar.add_child(browse_root)

	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 4)
	browse_root.add_child(search_row)
	_ah_search_field = LineEdit.new()
	_ah_search_field.placeholder_text = "Search items..."
	_ah_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ah_search_field.add_theme_font_size_override("font_size", 10)
	search_row.add_child(_ah_search_field)
	var search_btn := Button.new()
	search_btn.text = "Search"
	search_btn.add_theme_font_size_override("font_size", 10)
	search_btn.pressed.connect(func() -> void:
		NetworkManager.send_ah_browse(_ah_search_field.text))
	search_row.add_child(search_btn)

	# Column headers
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 2)
	browse_root.add_child(hdr_row)
	for hdr_pair: Array in [["Item", 140], ["Qty", 40], ["Price ea.", 60], ["Seller", 80], ["", 60]]:
		var lbl := Label.new()
		lbl.text = hdr_pair[0] as String
		lbl.custom_minimum_size = Vector2(hdr_pair[1] as int, 0)
		lbl.add_theme_color_override("font_color", RS_GOLD)
		lbl.add_theme_font_size_override("font_size", 9)
		hdr_row.add_child(lbl)

	var browse_scroll := ScrollContainer.new()
	browse_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	browse_root.add_child(browse_scroll)
	_ah_browse_list = VBoxContainer.new()
	_ah_browse_list.add_theme_constant_override("separation", 1)
	_ah_browse_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browse_scroll.add_child(_ah_browse_list)

	# ── Sell tab ──────────────────────────────────────────
	var sell_root := VBoxContainer.new()
	sell_root.name = "Sell"
	sell_root.add_theme_constant_override("separation", 3)
	tab_bar.add_child(sell_root)

	var sell_hdr := Label.new()
	sell_hdr.text = "Select an item from your inventory to list:"
	sell_hdr.add_theme_color_override("font_color", RS_TEXT)
	sell_hdr.add_theme_font_size_override("font_size", 10)
	sell_root.add_child(sell_hdr)

	var sell_scroll := ScrollContainer.new()
	sell_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sell_root.add_child(sell_scroll)
	_ah_sell_inv_list = VBoxContainer.new()
	_ah_sell_inv_list.add_theme_constant_override("separation", 2)
	_ah_sell_inv_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sell_scroll.add_child(_ah_sell_inv_list)
	_ah_refresh_sell_list()

	# ── My Listings tab ───────────────────────────────────
	var mine_root := VBoxContainer.new()
	mine_root.name = "My Listings"
	mine_root.add_theme_constant_override("separation", 3)
	tab_bar.add_child(mine_root)

	var mine_scroll := ScrollContainer.new()
	mine_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mine_root.add_child(mine_scroll)
	_ah_mine_list = VBoxContainer.new()
	_ah_mine_list.add_theme_constant_override("separation", 1)
	_ah_mine_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mine_scroll.add_child(_ah_mine_list)

	return win

func _ah_refresh_sell_list() -> void:
	if _ah_sell_inv_list == null or not is_instance_valid(_ah_sell_inv_list):
		return
	for ch: Node in _ah_sell_inv_list.get_children():
		ch.queue_free()
	for item: Dictionary in GameManager.inventory:
		var iid   := item["id"]   as String
		var iname := item["name"] as String
		var iqty  := item["qty"]  as int
		var row   := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_ah_sell_inv_list.add_child(row)
		var nm := Label.new()
		nm.text = "%s x%d" % [iname, iqty]
		nm.custom_minimum_size = Vector2(160, 0)
		nm.add_theme_font_size_override("font_size", 10)
		nm.add_theme_color_override("font_color", RS_TEXT)
		row.add_child(nm)
		var price_field := LineEdit.new()
		price_field.placeholder_text = "Price ea."
		price_field.custom_minimum_size = Vector2(64, 0)
		price_field.add_theme_font_size_override("font_size", 10)
		row.add_child(price_field)
		var qty_field := LineEdit.new()
		qty_field.placeholder_text = "Qty"
		qty_field.text = str(iqty)
		qty_field.custom_minimum_size = Vector2(40, 0)
		qty_field.add_theme_font_size_override("font_size", 10)
		row.add_child(qty_field)
		var list_btn := Button.new()
		list_btn.text = "List"
		list_btn.add_theme_font_size_override("font_size", 10)
		list_btn.pressed.connect(func() -> void:
			var price := price_field.text.to_int()
			var qty   := clampi(qty_field.text.to_int(), 1, iqty)
			if price <= 0:
				Events.chat_message.emit("[Set a price > 0 to list.]")
				return
			# Server validates and confirms — do not touch inventory until ah_list_result arrives
			NetworkManager.send_ah_list(iid, iname, qty, price))
		row.add_child(list_btn)

func _ah_populate_browse() -> void:
	if _ah_browse_list == null or not is_instance_valid(_ah_browse_list):
		return
	for ch: Node in _ah_browse_list.get_children():
		ch.queue_free()
	if _ah_listings.is_empty():
		var empty := Label.new()
		empty.text = "No listings found."
		empty.add_theme_color_override("font_color", RS_TEXT)
		empty.add_theme_font_size_override("font_size", 10)
		_ah_browse_list.add_child(empty)
		return
	for listing: Variant in _ah_listings:
		if not (listing is Dictionary):
			continue
		var d       := listing as Dictionary
		var lid     := d.get("id",         "") as String
		var iname   := d.get("item_name",  "?") as String
		var qty     := d.get("qty",        0) as int
		var price   := d.get("price_each", 0) as int
		var seller  := d.get("seller_name", "?") as String
		var row     := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		_ah_browse_list.add_child(row)
		var nm := Label.new()
		nm.text = iname
		nm.custom_minimum_size = Vector2(140, 0)
		nm.add_theme_font_size_override("font_size", 10)
		nm.add_theme_color_override("font_color", RS_TEXT)
		row.add_child(nm)
		var ql := Label.new()
		ql.text = str(qty)
		ql.custom_minimum_size = Vector2(40, 0)
		ql.add_theme_font_size_override("font_size", 10)
		ql.add_theme_color_override("font_color", RS_TEXT)
		row.add_child(ql)
		var pl := Label.new()
		pl.text = "%dg" % price
		pl.custom_minimum_size = Vector2(60, 0)
		pl.add_theme_font_size_override("font_size", 10)
		pl.add_theme_color_override("font_color", RS_GOLD)
		row.add_child(pl)
		var sl := Label.new()
		sl.text = seller
		sl.custom_minimum_size = Vector2(80, 0)
		sl.add_theme_font_size_override("font_size", 10)
		sl.add_theme_color_override("font_color", RS_TEXT)
		row.add_child(sl)
		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.custom_minimum_size = Vector2(60, 0)
		buy_btn.add_theme_font_size_override("font_size", 10)
		buy_btn.pressed.connect(func() -> void:
			NetworkManager.send_ah_buy(lid, 1))
		row.add_child(buy_btn)

func _ah_populate_my_listings() -> void:
	if _ah_mine_list == null or not is_instance_valid(_ah_mine_list):
		return
	for ch: Node in _ah_mine_list.get_children():
		ch.queue_free()
	if _ah_my_listings.is_empty():
		var empty := Label.new()
		empty.text = "You have no active listings."
		empty.add_theme_color_override("font_color", RS_TEXT)
		empty.add_theme_font_size_override("font_size", 10)
		_ah_mine_list.add_child(empty)
		return
	for listing: Variant in _ah_my_listings:
		if not (listing is Dictionary):
			continue
		var d     := listing as Dictionary
		var lid   := d.get("id",         "") as String
		var iname := d.get("item_name",  "?") as String
		var qty   := d.get("qty",        0) as int
		var price := d.get("price_each", 0) as int
		var row   := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_ah_mine_list.add_child(row)
		var lbl := Label.new()
		lbl.text = "%s x%d @ %dg ea." % [iname, qty, price]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", RS_TEXT)
		row.add_child(lbl)
		var cancel_btn := Button.new()
		cancel_btn.text = "Cancel"
		cancel_btn.add_theme_font_size_override("font_size", 10)
		cancel_btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		cancel_btn.pressed.connect(func() -> void:
			NetworkManager.send_ah_cancel(lid))
		row.add_child(cancel_btn)

func _on_ah_listings_updated(listings: Array) -> void:
	_ah_listings = listings
	_ah_populate_browse()

func _on_ah_my_listings_updated(listings: Array) -> void:
	_ah_my_listings = listings
	_ah_populate_my_listings()

func _on_ah_purchase_result(ok: bool, reason: String) -> void:
	if ok:
		Events.chat_message.emit("[Purchase successful!]")
		# Server has updated gold/inventory — re-fetch server state
		NetworkManager.send_ah_browse(_ah_search_field.text if _ah_search_field != null else "")
	else:
		Events.chat_message.emit("[Purchase failed: %s]" % reason)

func _on_ah_list_result(ok: bool, reason: String) -> void:
	if ok:
		Events.chat_message.emit("[Item listed successfully!]")
		NetworkManager.send_ah_my_listings()
		_ah_refresh_sell_list()
	else:
		Events.chat_message.emit("[Listing failed: %s]" % reason)

func _on_ah_cancel_result(ok: bool, reason: String) -> void:
	if ok:
		Events.chat_message.emit("[Listing cancelled — item returned to inventory.]")
		NetworkManager.send_ah_my_listings()
		_ah_refresh_sell_list()
	else:
		Events.chat_message.emit("[Cancel failed: %s]" % reason)
