extends CanvasLayer

const GearDB             = preload("res://scripts/Equipment.gd")
const Boats              = preload("res://scripts/Boat.gd")
const ReelMinigame       = preload("res://scripts/ui/ReelMinigame.gd")
const BoatCombat         = preload("res://scripts/ui/BoatCombat.gd")
const CastBalanceMinigame = preload("res://scripts/ui/CastBalanceMinigame.gd")
const ShopCatalog        = preload("res://scripts/ShopCatalog.gd")
const ItemPrices         = preload("res://scripts/ItemPrices.gd")
const RuneSpells         = preload("res://scripts/RuneSpells.gd")

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
const RS_GOLD   := Color(1.00, 0.85, 0.25)
const RS_GREEN  := Color(0.40, 0.90, 0.40)

const SKILL_COLORS := {
	"woodcutting":  Color(0.30, 0.80, 0.25),
	"mining":       Color(0.70, 0.68, 0.75),
	"fishing":      Color(0.25, 0.70, 0.92),
	"foraging":     Color(0.50, 0.88, 0.30),
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
	{"id": "fnd",  "icon": "☻",  "tip": "Friends"},
	{"id": "wrb",  "icon": "⚑",  "tip": "Warband"},
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
var _combat_window:     PanelContainer  = null
var _combat_monster:    Node            = null
var _combat_mon_bar:    ProgressBar     = null
var _combat_mon_lbl:    Label           = null
var _combat_plr_bar:    ProgressBar     = null
var _combat_plr_lbl:    Label           = null
var _combat_log:        Label           = null
var _combat_style:      String          = "melee"
var _style_btns:        Dictionary      = {}
# Persistent-toggle UI (lives near the HP bar, mirrors GameManager state).
var _persist_style_btns:  Dictionary    = {}     # "melee" / "ranged" / "magic" → Button
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
var _combat_join_wait:     float        = 0.0
const COMBAT_JOIN_TIMEOUT := 2.0
var _popup_tween:   Tween          = null
var _player:        Node           = null
var _cam_lock_btn:  Button         = null

# Bank window
var _bank_window:      PanelContainer    = null

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

var _bank_inv_slots:   Array[Dictionary] = []   # {slot, color_rect, name_lbl, qty_lbl}
var _bank_stash_slots: Array[Dictionary] = []   # same, for bank storage

# Chat
var _chat_vbox:       VBoxContainer  = null
var _chat_history:    Array[String]  = []
const CHAT_MAX       := 40
var _chat_panel:      PanelContainer = null
var _chat_content:    VBoxContainer  = null   # scroll + line_edit wrapper
var _chat_minimized:  bool           = false


# Minimap
var _minimap_canvas:    Control        = null
var _minimap_texture:   ImageTexture   = null
var _minimap_panel:     PanelContainer = null
var _minimap_content:   Control        = null   # the canvas control
var _minimap_minimized: bool           = false

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
var _thrall_task_list: VBoxContainer = null

# ── Lifecycle ────────────────────────────────────────────────────────────────
func _ready() -> void:
	add_to_group("hud")
	_build_ui()
	Events.ui_show_interaction.connect(_on_show)
	Events.ui_hide_interaction.connect(_on_hide)
	Events.boat_prompt.connect(_on_boat_prompt)
	Events.skill_cell_pressed.connect(_on_skill_cell_pressed)
	Events.inventory_changed.connect(_refresh_inventory)
	Events.equipment_changed.connect(_refresh_equipment)
	Events.xp_gained.connect(_on_xp_gained)
	Events.open_forge.connect(_on_open_forge)
	Events.open_cooking.connect(_on_open_cooking)
	Events.minimap_refresh.connect(_regen_minimap)
	Events.open_combat.connect(_on_open_combat)
	Events.combat_ended.connect(_on_combat_ended)
	Events.mob_hit.connect(_on_mob_hit_hud)
	Events.mob_state.connect(_on_mob_state_hud)
	Events.mob_dead_on_join.connect(_on_mob_dead_on_join_hud)
	Events.mob_full.connect(_on_mob_full_hud)
	Events.player_hp_changed.connect(_on_player_hp_changed)
	Events.camera_free_mode_changed.connect(_on_camera_free_mode_changed)
	Events.open_bank.connect(_on_open_bank)
	Events.bank_changed.connect(_refresh_bank)
	Events.xp_gained.connect(_on_chat_xp)
	Events.thrall_returned.connect(_on_thrall_returned)
	# Phase 2 fishing rework — Player.gd fires reel_minigame_start when a big
	# fish bites; spawn the modal as a HUD child so it cleans up with the HUD
	# if the player logs out mid-reel.
	Events.reel_minigame_start.connect(_on_reel_minigame_start)
	# Phase 3 fishing rework — Player.gd fires sea_combat_start when an
	# encounter roll triggers a monster instead of a fish.
	Events.sea_combat_start.connect(_on_sea_combat_start)
	# Phase 5 fishing rework — Player.gd fires cast_minigame_start when the
	# player clicks water with a pole equipped. The modal replaces the old
	# 3.5s passive wait with active play.
	Events.cast_minigame_start.connect(_on_cast_minigame_start)
	Events.chat_message.connect(_add_chat_message)
	Events.npc_dialogue.connect(_on_npc_dialogue)
	Events.open_crafting.connect(_on_open_crafting)
	Events.open_construction.connect(_on_open_construction)
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
	Events.player_context_menu.connect(_on_player_context_menu)
	Events.player_lookup_result.connect(_on_player_lookup_result)
	Events.xp_gained.connect(_on_toast_xp)
	Events.item_gained.connect(_on_toast_item)
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
	Events.clan_invite_received.connect(_on_clan_invite_received)
	# Proximity auto-close: track the world position of whichever interactable
	# the player just reached, so the next open_* event can anchor here.
	Events.player_interacted.connect(_on_player_interacted_for_proximity)

func _process(delta: float) -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player != null and _coords_lbl != null:
		var tx := int(_player.global_position.x / 32)
		var ty := int(_player.global_position.y / 32)
		_coords_lbl.text = "(%d, %d)" % [tx, ty]
	if _in_combat:
		_combat_tick(delta)
	if _minimap_canvas != null:
		_minimap_canvas.queue_redraw()
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
	_build_persistent_combat_strip()
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

# Quest marker overlay — purple ! / + above active-quest targets. Lives on
# its own CanvasLayer at layer 5: above HUD (layer 1) and the world (layer 0),
# below the QuestLog modal (layer 80). The Control inside reads world→screen
# via the viewport's canvas_transform; the CanvasLayer itself doesn't follow
# the camera, so the markers project to screen space cleanly.
const _QuestMarkers = preload("res://scripts/ui/QuestMarkers.gd")
func _build_quest_markers() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 5
	var marker := _QuestMarkers.new() as Control
	# Deferred because we're still inside HUD._ready when this runs — adding
	# nodes to other parts of the tree mid-ready throws the SceneTree-busy
	# warning. Deferring lets the current ready chain finish first.
	cl.add_child.call_deferred(marker)
	get_tree().root.add_child.call_deferred(cl)

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
	_tab_contents["fnd"] = preload("res://scenes/ui/friends_panel.tscn").instantiate()
	_tab_contents["wrb"] = _build_warband_tab()
	_tab_contents["rnk"] = preload("res://scenes/ui/rankings_panel.tscn").instantiate()
	_tab_contents["set"] = preload("res://scenes/ui/settings_panel.tscn").instantiate()

	for tc: Variant in _tab_contents.values():
		tc.visible = false
		stack.add_child(tc)

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
		NetworkManager.send_clan_info()

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
							"color_rect": color_rect, "qty_lbl": qty_lbl})

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
				# Fallback: show coloured background tile until icons are generated
				icon_rect.texture = null
				var raw_col: Variant = item.get("color", Color.GRAY)
				var col: Color
				if raw_col is Array:
					var a := raw_col as Array
					col = Color(float(a[0]), float(a[1]), float(a[2]))
				elif raw_col is Color:
					col = raw_col as Color
				else:
					col = Color.GRAY
				color_rect.color = col.darkened(0.3)
			qty_lbl.text = "x%d" % item["qty"] if (item["qty"] as int) > 1 else ""
			var tip_ := item_name_
			if GameManager.BONE_XP.has(item_id_):
				tip_ += "\nClick to bury (+%d Soul XP)" % (GameManager.BONE_XP[item_id_] as int)
			elif GameManager.BOOT_SPEED_BONUS.has(item_id_):
				var pct := int((GameManager.BOOT_SPEED_BONUS[item_id_] as float) * 100.0)
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
			var pct := int((GameManager.BOOT_SPEED_BONUS.get(GameManager.equipped_boots, 0.0) as float) * 100.0)
			_inv_boots_lbl.text = "Boots: %s (+%d%% spd)" % [GameManager.equipped_boots.replace("_", " ").capitalize(), pct]

# ── Inventory right-click context menu ───────────────────────────────────────
const _CTX_EQUIP := 0
const _CTX_DROP  := 1

func _show_inv_context(slot_index: int, screen_pos: Vector2) -> void:
	if slot_index < 0 or slot_index >= GameManager.inventory.size():
		return
	var item: Dictionary = GameManager.inventory[slot_index]
	var item_id := str(item.get("id", ""))
	if item_id == "":
		return
	var menu := PopupMenu.new()
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
		_equip_stats_lbl.text = "Bonuses — Atk +%d   Def +%d   HP +%d   Acc +%d" % [
			GameManager.get_equipment_bonus("atk"), GameManager.get_equipment_bonus("def"),
			GameManager.get_equipment_bonus("hp"),  GameManager.get_equipment_bonus("acc")]

func _stat_str(d: Dictionary) -> String:
	var parts: Array[String] = []
	for k: String in ["atk", "def", "hp", "acc"]:
		if int(d.get(k, 0)) != 0:
			parts.append("%s +%d" % [k.to_upper(), int(d[k])])
	return ", ".join(parts) if not parts.is_empty() else "—"


# ── WARBAND tab ───────────────────────────────────────────────────────────────
func _build_warband_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tab_title("Warband"))
	root.add_child(HSeparator.new())

	_warband_root = VBoxContainer.new()
	_warband_root.add_theme_constant_override("separation", 4)
	_warband_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_warband_root)

	_refresh_warband()
	return root

func _on_clan_info_updated(clan: Dictionary) -> void:
	_clan = clan
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

	# Clan bank
	var bank_hdr := Label.new()
	bank_hdr.text = "Clan Bank"
	bank_hdr.add_theme_color_override("font_color", RS_GOLD)
	bank_hdr.add_theme_font_size_override("font_size", 11)
	_warband_root.add_child(bank_hdr)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 130)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_warband_root.add_child(scroll)
	var bank_vbox := VBoxContainer.new()
	bank_vbox.add_theme_constant_override("separation", 2)
	bank_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(bank_vbox)

	var bank: Array = _clan.get("bank", []) as Array
	if bank.is_empty():
		var empty := Label.new()
		empty.text = "Bank is empty."
		empty.add_theme_color_override("font_color", RS_DIM)
		empty.add_theme_font_size_override("font_size", 10)
		bank_vbox.add_child(empty)
	else:
		for b: Variant in bank:
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
			var take := Button.new()
			take.text = "Take"
			take.add_theme_font_size_override("font_size", 9)
			take.pressed.connect(func() -> void:
				NetworkManager.send_clan_bank_withdraw(bid, bq))
			brow.add_child(take)
			bank_vbox.add_child(brow)

	var dep_btn := Button.new()
	dep_btn.text = "Deposit Item"
	dep_btn.add_theme_font_size_override("font_size", 10)
	dep_btn.pressed.connect(_show_clan_deposit_dialog)
	_warband_root.add_child(dep_btn)

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
	tl.text = "Deposit to Clan Bank"
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
		dep.pressed.connect(func() -> void:
			NetworkManager.send_clan_bank_deposit(iid, iq)
			overlay.queue_free())
		row.add_child(dep)
		list.add_child(row)

func _on_clan_invite_received(from_username: String, clan_name: String, clan_id: String) -> void:
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
		NetworkManager.send_clan_accept(clan_id))
	hbox.add_child(acc)
	var dec := Button.new()
	dec.text = "Decline"
	dec.add_theme_font_size_override("font_size", 11)
	dec.pressed.connect(func() -> void:
		overlay.queue_free()
		NetworkManager.send_clan_decline(from_username))
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
		_chat_panel.offset_top = -220
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

		var name_row := HBoxContainer.new()
		cvbox.add_child(name_row)
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(10, 10)
		dot.color = recipe["color"] as Color
		name_row.add_child(dot)
		var rname := Label.new()
		rname.text = "  %s" % recipe["name"]
		rname.add_theme_color_override("font_color", RS_GOLD)
		rname.add_theme_font_size_override("font_size", 12)
		name_row.add_child(rname)

		var reqs_lbl := Label.new()
		var req_parts: Array[String] = []
		for ing: Dictionary in recipe["input"] as Array:
			req_parts.append("%dx %s" % [ing["qty"], ing["name"]])
		reqs_lbl.text = "Requires: %s" % "  +  ".join(req_parts)
		reqs_lbl.add_theme_color_override("font_color", RS_TEXT)
		reqs_lbl.add_theme_font_size_override("font_size", 10)
		cvbox.add_child(reqs_lbl)

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

func _refresh_forge() -> void:
	var smithing_lv := GameManager.get_skill_level("smithing")
	for i in range(_forge_recipe_btns.size()):
		var recipe: Dictionary = _FORGE_RECIPES[i]
		var can_smelt := smithing_lv >= (recipe["req_lv"] as int)
		for ing: Dictionary in recipe["input"] as Array:
			if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
				can_smelt = false
		_forge_recipe_btns[i].disabled = not can_smelt

func _smelt(recipe: Dictionary) -> void:
	var smithing_lv := GameManager.get_skill_level("smithing")
	if smithing_lv < (recipe["req_lv"] as int):
		return
	for ing: Dictionary in recipe["input"] as Array:
		if not GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int):
			return
	GameManager.add_item(recipe["id"] as String, recipe["name"] as String, 1, recipe["color"] as Color)
	GameManager.add_xp("smithing", recipe["xp"] as int)
	_refresh_forge()

# ── HP bar (always-visible, bottom-right) ─────────────────────────────────────
func _build_hp_bar() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 2))
	panel.anchor_left   = 1.0; panel.anchor_right  = 1.0
	panel.anchor_top    = 1.0; panel.anchor_bottom = 1.0
	panel.offset_left   = -160; panel.offset_right  = -6
	panel.offset_top    = -38;  panel.offset_bottom = -6
	add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	panel.add_child(hbox)

	var heart := Label.new()
	heart.text = "❤"
	heart.add_theme_color_override("font_color", Color(0.95, 0.20, 0.20))
	heart.add_theme_font_size_override("font_size", 14)
	hbox.add_child(heart)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 1)
	hbox.add_child(vbox)

	_hp_lbl = Label.new()
	_hp_lbl.add_theme_color_override("font_color", RS_TEXT)
	_hp_lbl.add_theme_font_size_override("font_size", 10)
	vbox.add_child(_hp_lbl)

	_hp_bar = ProgressBar.new()
	_hp_bar.max_value       = 100
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size = Vector2(0, 8)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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

# ── Persistent combat-style toggle (near the HP bar) ─────────────────────────
## Three style buttons + a rune sub-row visible only when Magic is active.
## Pushes through GameManager.set_combat_style so the choice persists across
## logout. Combat-window buttons mirror via the combat_style_changed signal.
func _build_persistent_combat_strip() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 2))
	panel.anchor_left = 1.0; panel.anchor_right = 1.0
	panel.anchor_top  = 1.0; panel.anchor_bottom = 1.0
	# Sits ABOVE the chat panel (chat occupies offset_top -220 → bottom -44).
	# Width matches the chat for visual alignment. Tall enough for both the
	# style row and a rune sub-row underneath.
	panel.offset_left   = -286; panel.offset_right  = -6
	panel.offset_top    = -286; panel.offset_bottom = -224
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	panel.add_child(root)

	# Three style buttons in a row.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	root.add_child(row)
	for entry: Array in [["⚔", "melee"], ["🏹", "ranged"], ["✨", "magic"]]:
		var sb := Button.new()
		sb.text = entry[0] as String
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.custom_minimum_size = Vector2(0, 22)
		sb.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
		sb.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_GOLD, 2))
		sb.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD, 2))
		sb.add_theme_color_override("font_color", RS_TEXT)
		sb.add_theme_font_size_override("font_size", 14)
		var sval: String = entry[1] as String
		_persist_style_btns[sval] = sb
		sb.pressed.connect(func() -> void: _on_persist_style_pressed(sval))
		row.add_child(sb)

	# Rune sub-row — populated on demand by _refresh_persist_rune_row.
	_persist_rune_row = HBoxContainer.new()
	_persist_rune_row.add_theme_constant_override("separation", 2)
	root.add_child(_persist_rune_row)

	# Sync initial state from GameManager (loaded from server on login).
	_combat_style = GameManager.combat_style
	_refresh_persist_style_btns()
	_refresh_persist_rune_row()

	# Listen for any other path mutating combat style (combat window today; in
	# theory other panels in the future).
	Events.combat_style_changed.connect(_on_combat_style_changed_external)
	# Inventory changes invalidate the rune row (player gained/lost runes).
	Events.inventory_changed.connect(_refresh_persist_rune_row)
	Events.xp_gained.connect(_on_xp_gained_for_rune_row)
	# Server can change rank mid-session — admin gates may unlock more runes.
	NetworkManager.admin_rank_changed.connect(_on_admin_rank_for_rune_row)

## A style button on the persistent strip was clicked. Push through GameManager
## so the value persists, then locally refresh both the strip highlight and
## the combat-window mirror.
func _on_persist_style_pressed(style: String) -> void:
	# Magic with no active rune defaults to the highest-tier rune the player
	# meets the level for AND owns (so the row never opens empty when the
	# player has runes available).
	var rune: String = GameManager.active_rune
	if style == "magic" and rune == "":
		rune = _best_available_rune()
	GameManager.set_combat_style(style, rune)
	_combat_style = style
	_refresh_persist_style_btns()
	_refresh_persist_rune_row()
	_refresh_style_btns()   # combat-window mirror (no-op if window not built)

## A rune icon in the sub-row was clicked — set it as the active spell.
func _on_persist_rune_pressed(rune_id: String) -> void:
	GameManager.set_combat_style("magic", rune_id)
	_combat_style = "magic"
	_refresh_persist_style_btns()
	_refresh_persist_rune_row()

func _refresh_persist_style_btns() -> void:
	for sval: Variant in _persist_style_btns:
		var sb := _persist_style_btns[sval] as Button
		var active: bool = sval == _combat_style
		if active and sval == "magic" and GameManager.active_rune != "":
			# Tint the magic button with the active rune's color so the player
			# sees at a glance which spell is loaded.
			var col: Color = RuneSpells.color_for(GameManager.active_rune)
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_A, col, 2))
			sb.add_theme_color_override("font_color", col)
		elif active:
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_A, RS_GOLD, 2))
			sb.add_theme_color_override("font_color", RS_GOLD)
		else:
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
			sb.add_theme_color_override("font_color", RS_TEXT)

## Rebuild the rune sub-row to show only runes the player owns AND is
## level-gated for. Hidden entirely when style != "magic" so the strip
## takes minimal screen real estate when not casting.
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
	# combat-window buttons too (their state used to drive damage routing).
	_combat_style = style
	_refresh_persist_style_btns()
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
	{"name": "Vegetable Stew",   "id": "vegetable_stew",   "color": Color(0.40, 0.62, 0.30), "skill": "cooking",
	 "input": [{"id": "mushrooms", "name": "Mushrooms", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 48, "req_lv": 10},
	# Lv 15
	{"name": "Meat Pie",         "id": "meat_pie",         "color": Color(0.72, 0.50, 0.26), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 62, "req_lv": 15},
	{"name": "Fish Soup",        "id": "fish_soup",        "color": Color(0.55, 0.70, 0.78), "skill": "cooking",
	 "input": [{"id": "raw_fish", "name": "Raw Fish", "qty": 2}], "xp": 58, "req_lv": 15},
	# Lv 20
	{"name": "Cooked Lobster",   "id": "cooked_lobster",   "color": Color(0.90, 0.30, 0.20), "skill": "cooking",
	 "input": [{"id": "lobster", "name": "Lobster", "qty": 1}], "xp": 70, "req_lv": 20},
	{"name": "Hearty Stew",      "id": "hearty_stew",      "color": Color(0.60, 0.42, 0.24), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}, {"id": "mushrooms", "name": "Mushrooms", "qty": 1}], "xp": 76, "req_lv": 20},
	# Lv 25
	{"name": "Shark Steak",      "id": "shark_steak",      "color": Color(0.55, 0.58, 0.62), "skill": "cooking",
	 "input": [{"id": "raw_shark", "name": "Raw Shark", "qty": 1}], "xp": 90, "req_lv": 25},
	{"name": "Honey-Glazed Ham", "id": "honey_glazed_ham", "color": Color(0.82, 0.50, 0.22), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 1}, {"id": "berries", "name": "Berries", "qty": 1}], "xp": 86, "req_lv": 25},
	# Lv 30
	{"name": "Stuffed Boar",     "id": "stuffed_boar",     "color": Color(0.58, 0.38, 0.22), "skill": "cooking",
	 "input": [{"id": "raw_meat", "name": "Raw Meat", "qty": 2}], "xp": 100, "req_lv": 30},
	{"name": "Spiced Fish",      "id": "spiced_fish",      "color": Color(0.92, 0.58, 0.34), "skill": "cooking",
	 "input": [{"id": "raw_salmon", "name": "Raw Salmon", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 96, "req_lv": 30},
	# Lv 35
	{"name": "Dragon Fin Soup",  "id": "dragon_fin_soup",  "color": Color(0.45, 0.66, 0.55), "skill": "cooking",
	 "input": [{"id": "raw_shark", "name": "Raw Shark", "qty": 1}, {"id": "herbs", "name": "Herbs", "qty": 1}], "xp": 115, "req_lv": 35},
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
	{"name": "Feast of Valhalla","id": "feast_of_valhalla","color": Color(0.95, 0.82, 0.30), "skill": "cooking",
	 "input": [{"id": "leviathan_eel", "name": "Leviathan Eel", "qty": 1}, {"id": "raw_meat", "name": "Raw Meat", "qty": 3}, {"id": "mushrooms", "name": "Mushrooms", "qty": 2}], "xp": 320, "req_lv": 80},
]

func _build_cook_window() -> void:
	_cook_window = _build_recipe_window("🔥  Campfire", _COOK_RECIPES, "cooking",
		func(r: Dictionary) -> void: _cook(r))
	_cook_window.offset_left = -170; _cook_window.offset_right  = 170
	_cook_window.offset_top  = -220; _cook_window.offset_bottom = 220
	_cook_window.visible = false

func _on_open_cooking() -> void:
	_refresh_cook()
	_cook_window.visible = true
	_register_proximity_panel(_cook_window)

func _refresh_cook() -> void:
	_refresh_recipe_window(_COOK_RECIPES, "cooking", _cook_recipe_btns)

func _cook(recipe: Dictionary) -> void:
	for ing: Dictionary in recipe["input"] as Array:
		if not GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int):
			return
	GameManager.add_item(recipe["id"] as String, recipe["name"] as String, 1, recipe["color"] as Color)
	GameManager.add_xp("cooking", recipe["xp"] as int)
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

	# ── Jewellery (Crafting — metalwork that's adornment, not tools) ─────────
	{"name": "Gold Amulet",    "id": "gold_amulet",    "color": Color(0.95, 0.80, 0.15), "skill": "crafting",
	 "input": [{"id": "gold_bar",     "name": "Gold Bar",     "qty": 2}],              "xp": 110, "req_lv": 35},

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

func _build_craft_window() -> void:
	_all_craft_recipes = _build_all_craft_recipes()
	_craft_window = _build_recipe_window("💎  Crafting", _all_craft_recipes, "crafting",
		func(r: Dictionary) -> void: _craft(r))
	_craft_window.offset_left = -170; _craft_window.offset_right  = 170
	_craft_window.offset_top  = -220; _craft_window.offset_bottom = 220
	_craft_window.visible = false

func _refresh_craft() -> void:
	_refresh_recipe_window(_all_craft_recipes, "crafting", _craft_recipe_btns)

func _craft(recipe: Dictionary) -> void:
	for ing: Dictionary in recipe["input"] as Array:
		if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
			return
	for ing: Dictionary in recipe["input"] as Array:
		GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int)
	var out_qty := int(recipe.get("out_qty", 1))
	GameManager.add_item(recipe["id"] as String, recipe["name"] as String, out_qty, recipe["color"] as Color)
	GameManager.add_xp(str(recipe.get("skill", "crafting")), recipe["xp"] as int)
	_refresh_craft()

## Tools (from _CRAFT_RECIPES) + generated armour / weapon / jewellery tiers.
## Item ids follow the "{tier}_{piece}" convention so GearDB.def_for derives stats.
func _build_all_craft_recipes() -> Array:
	var out: Array = _CRAFT_RECIPES.duplicate(true)

	# Leather armour — Smithing per the "all armor = smithing" rebalance.
	# Pelts are the only ingredient; the user kept this as a separate ladder
	# from the metal-tier armours so a fresh fighter has a non-metal entry.
	var leather: Array = [["helm", 2], ["body", 3], ["legs", 3], ["gloves", 1], ["boots", 1], ["shield", 2]]
	for p: Array in leather:
		var piece := p[0] as String
		var amt := p[1] as int
		out.append({"name": "Leather %s" % piece.capitalize(), "id": "leather_%s" % piece,
			"color": Color(0.45, 0.30, 0.14), "skill": "smithing",
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
		# Ring + amulet (Crafting)
		out.append({"name": "%s Ring" % tname, "id": "%s_ring" % tier["t"], "color": tier["col"],
			"skill": "crafting", "input": [{"id": tier["bar"], "name": tier["bn"], "qty": 1}],
			"xp": (tier["req"] as int) * 2, "req_lv": tier["req"]})
		out.append({"name": "%s Amulet" % tname, "id": "%s_amulet" % tier["t"], "color": tier["col"],
			"skill": "crafting", "input": [{"id": tier["bar"], "name": tier["bn"], "qty": 2}],
			"xp": (tier["req"] as int) * 2 + 10, "req_lv": tier["req"]})

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
func _build_recipe_window(title: String, recipes: Array, _skill: String,
		on_craft: Callable, scroll_h: float = 380.0) -> PanelContainer:
	var win := PanelContainer.new()
	win.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	win.anchor_left = 0.5; win.anchor_right  = 0.5
	win.anchor_top  = 0.5; win.anchor_bottom = 0.5
	add_child(win)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	win.add_child(root)

	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var tlbl := _tab_title(title)
	tlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(tlbl)
	var xbtn := Button.new()
	xbtn.text = "✕"; xbtn.flat = true
	xbtn.add_theme_color_override("font_color", RS_DIM)
	xbtn.add_theme_font_size_override("font_size", 13)
	xbtn.pressed.connect(func() -> void: win.visible = false)
	title_row.add_child(xbtn)
	root.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(300, scroll_h)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var list := GridContainer.new()
	list.columns = 2
	list.add_theme_constant_override("h_separation", 6)
	list.add_theme_constant_override("v_separation", 6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var btns: Array[Button] = []
	for recipe: Dictionary in recipes:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
		card.custom_minimum_size = Vector2(142, 0)
		list.add_child(card)
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 3)
		card.add_child(cv)

		var nr := HBoxContainer.new()
		cv.add_child(nr)
		var ipath := "res://assets/icons/%s.png" % (recipe["id"] as String)
		if ResourceLoader.exists(ipath):
			var icon := TextureRect.new()
			icon.custom_minimum_size = Vector2(24, 24)
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.texture = load(ipath) as Texture2D
			nr.add_child(icon)
		else:
			var dot := ColorRect.new()
			dot.custom_minimum_size = Vector2(20, 20)
			dot.color = recipe["color"] as Color
			nr.add_child(dot)
		var nl := Label.new()
		nl.text = "  %s" % recipe["name"]
		nl.add_theme_color_override("font_color", RS_GOLD)
		nl.add_theme_font_size_override("font_size", 12)
		nr.add_child(nl)

		var parts: Array[String] = []
		for ing: Dictionary in recipe["input"] as Array:
			parts.append("%dx %s" % [ing["qty"], ing["name"]])
		var rl := Label.new()
		rl.text = "Needs: %s" % "  +  ".join(parts)
		rl.add_theme_color_override("font_color", RS_TEXT)
		rl.add_theme_font_size_override("font_size", 10)
		cv.add_child(rl)

		var xl := Label.new()
		var rs_skill := str(recipe.get("skill", _skill)).capitalize()
		xl.text = "+%d %s XP  |  Req. %s Lv %d" % [recipe["xp"], rs_skill, rs_skill, recipe["req_lv"]]
		xl.add_theme_color_override("font_color", RS_DIM)
		xl.add_theme_font_size_override("font_size", 9)
		cv.add_child(xl)

		var btn := Button.new()
		btn.text = "Make"
		btn.add_theme_stylebox_override("normal",   _rs(RS_BTN_A, RS_GOLD, 2))
		btn.add_theme_stylebox_override("hover",    _rs(RS_BTN_H, RS_GOLD, 2))
		btn.add_theme_stylebox_override("disabled", _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 2))
		btn.add_theme_color_override("font_color",          RS_GOLD)
		btn.add_theme_color_override("font_disabled_color", RS_DIM)
		btn.add_theme_font_size_override("font_size", 11)
		btn.pressed.connect(on_craft.bind(recipe))
		cv.add_child(btn)
		btns.append(btn)

	if _skill == "crafting":
		_craft_recipe_btns = btns
	elif _skill == "cooking":
		_cook_recipe_btns = btns
	elif _skill == "construction":
		_construct_recipe_btns = btns
	elif _skill == "magic":
		_rune_recipe_btns = btns
	return win

func _refresh_recipe_window(recipes: Array, skill: String, btns: Array[Button]) -> void:
	for i in range(btns.size()):
		var recipe: Dictionary = recipes[i]
		var rskill := str(recipe.get("skill", skill))
		var ok := GameManager.get_skill_level(rskill) >= (recipe["req_lv"] as int)
		for ing: Dictionary in recipe["input"] as Array:
			if GameManager.get_item_qty(ing["id"] as String) < (ing["qty"] as int):
				ok = false
		btns[i].disabled = not ok

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
	"foraging": [
		["Lv 1",  "Herb Patch → Herbs (15 XP)"],
		["Lv 10", "Mushroom Patch → Mushrooms (20 XP)"],
		["Lv 25", "Berry Bush → Berries (30 XP)"],
		["Lv 40", "Moonbloom Patch → Moonbloom (50 XP)"],
		["Lv 60", "Ancient Root → Ancient Root (70 XP)"],
	],
	"smithing": [
		["Lv 1",  "2× Copper Ore → Copper Bar  (use Forge)"],
		["Lv 15", "2× Iron Ore → Iron Bar  (use Forge)"],
		["Lv 30", "2× Gold Ore → Gold Bar  (use Forge)"],
		["Lv 50", "2× Mithril Ore → Mithril Bar  (use Forge)"],
		["Lv 70", "2× Adamant Ore → Adamant Bar  (use Forge)"],
		["Lv 85", "2× Runite Ore → Runite Bar  (use Forge)"],
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
func _build_combat_window() -> void:
	_combat_window = PanelContainer.new()
	_combat_window.add_theme_stylebox_override("panel", _rs(RS_BG, RS_BORDER, 3))
	# Anchored top-right, sits below the minimap (minimap bottom ≈ 204px from top)
	_combat_window.anchor_left   = 1.0; _combat_window.anchor_right  = 1.0
	_combat_window.anchor_top    = 0.0; _combat_window.anchor_bottom = 0.0
	_combat_window.offset_left   = -292; _combat_window.offset_right  = -6
	_combat_window.offset_top    = 208;  _combat_window.offset_bottom = 428
	_combat_window.visible       = false
	add_child(_combat_window)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_combat_window.add_child(root)

	# Title + flee
	var top_row := HBoxContainer.new()
	root.add_child(top_row)
	var title := _tab_title("⚔  Combat")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(title)
	var flee_btn := Button.new()
	flee_btn.text = "Flee"
	flee_btn.add_theme_stylebox_override("normal", _rs(Color(0.25,0.05,0.05), RS_BORDER, 2))
	flee_btn.add_theme_color_override("font_color", Color(1,0.4,0.4))
	flee_btn.add_theme_font_size_override("font_size", 11)
	flee_btn.pressed.connect(func() -> void: Events.combat_ended.emit())
	top_row.add_child(flee_btn)

	root.add_child(HSeparator.new())

	# Monster HP
	var m_row := HBoxContainer.new()
	m_row.add_theme_constant_override("separation", 6)
	root.add_child(m_row)
	var m_ico := Label.new()
	m_ico.text = "☠"
	m_ico.add_theme_color_override("font_color", Color(0.8,0.8,0.8))
	m_ico.add_theme_font_size_override("font_size", 14)
	m_row.add_child(m_ico)
	var m_vbox := VBoxContainer.new()
	m_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m_vbox.add_theme_constant_override("separation", 1)
	m_row.add_child(m_vbox)
	_combat_mon_lbl = Label.new()
	_combat_mon_lbl.add_theme_color_override("font_color", RS_TEXT)
	_combat_mon_lbl.add_theme_font_size_override("font_size", 10)
	m_vbox.add_child(_combat_mon_lbl)
	_combat_mon_bar = ProgressBar.new()
	_combat_mon_bar.show_percentage = false
	_combat_mon_bar.custom_minimum_size = Vector2(0, 8)
	_combat_mon_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_combat_mon_bar.add_theme_stylebox_override("fill",       _rs(Color(0.7,0.12,0.12), Color(0.95,0.2,0.2), 0))
	_combat_mon_bar.add_theme_stylebox_override("background", _rs(Color(0.05,0.05,0.05), RS_BORDER.darkened(0.6), 0))
	m_vbox.add_child(_combat_mon_bar)

	# Player HP
	var p_row := HBoxContainer.new()
	p_row.add_theme_constant_override("separation", 6)
	root.add_child(p_row)
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

	root.add_child(HSeparator.new())

	# Attack style
	var style_lbl := Label.new()
	style_lbl.text = "Attack Style:"
	style_lbl.add_theme_color_override("font_color", RS_DIM)
	style_lbl.add_theme_font_size_override("font_size", 10)
	root.add_child(style_lbl)

	var style_row := HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 4)
	root.add_child(style_row)
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
			_refresh_persist_style_btns()
			_refresh_persist_rune_row())
		style_row.add_child(sb)
	_refresh_style_btns()

	root.add_child(HSeparator.new())

	# Combat log
	_combat_log = Label.new()
	_combat_log.add_theme_color_override("font_color", RS_TEXT)
	_combat_log.add_theme_font_size_override("font_size", 10)
	_combat_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_combat_log.custom_minimum_size = Vector2(0, 40)
	root.add_child(_combat_log)

func _refresh_style_btns() -> void:
	for sval: Variant in _style_btns:
		var sb := _style_btns[sval] as Button
		if sval == _combat_style:
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_A, RS_GOLD, 2))
			sb.add_theme_color_override("font_color", RS_GOLD)
		else:
			sb.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
			sb.add_theme_color_override("font_color", RS_TEXT)

func _on_open_combat(monster: Node) -> void:
	_combat_monster   = monster
	# Honor the persistent strip selection — do NOT force back to melee here.
	# The player picked their style BEFORE engaging; respecting it is the whole
	# point of the persistent toggle.
	_combat_style     = GameManager.combat_style
	_combat_atk_timer = 2.4
	_combat_mon_timer = 2.0
	_in_combat        = true
	_combat_server    = false
	_combat_join_pending = false
	_combat_join_wait = 0.0
	_out_of_resource_chatted = false
	_refresh_style_btns()
	_refresh_persist_style_btns()
	_refresh_persist_rune_row()
	Events.player_stop_action.emit()
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player != null:
		monster.call("start_pursuit", _player as Node2D)
	# Join the shared fight if the server owns this monster.
	var eid := str(monster.get("entity_id"))
	if not eid.is_empty() and NetworkManager.state == NetworkManager.NetState.LOGGED_IN:
		_combat_join_pending = true
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
	_combat_window.visible = false
	_combat_log_append("Combat ended.")

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
		_update_combat_ui()

func _on_mob_hit_hud(entity_id: String, x: float, y: float, amount: int, by_username: String, _hp: int, _max_hp: int) -> void:
	if entity_id != _combat_target_id():
		return
	# Show every fighter's damage on the shared monster in real time.
	_show_damage_number(Vector2(x, y), amount, by_username == NetworkManager.my_username)
	_update_combat_ui()

func _on_mob_dead_on_join_hud(entity_id: String, _respawn_in: float) -> void:
	if entity_id == _combat_target_id():
		_combat_log_append("That monster is already dead.")
		_on_combat_ended()

func _on_mob_full_hud(entity_id: String) -> void:
	if entity_id == _combat_target_id():
		_combat_log_append("That fight is full (5 players).")
		_on_combat_ended()

func _update_combat_ui() -> void:
	if _combat_monster == null:
		return
	var m     := _combat_monster
	var m_hp  := m.get("current_hp") as int
	var m_max := m.get("max_hp")     as int
	var m_lv  := m.get("level")      as int
	var m_nm  := m.get("display_name") as String
	_combat_mon_lbl.text      = "%s  (Lv %d)   %d / %d HP" % [m_nm, m_lv, m_hp, m_max]
	_combat_mon_bar.max_value = m_max
	_combat_mon_bar.value     = m_hp
	var p_hp  := GameManager.current_hp
	var p_max := GameManager.get_max_hp()
	_combat_plr_lbl.text      = "You   %d / %d HP" % [p_hp, p_max]
	_combat_plr_bar.max_value = p_max
	_combat_plr_bar.value     = p_hp

func _combat_log_append(line: String) -> void:
	var lines := _combat_log.text.split("\n")
	lines.append(line)
	if lines.size() > 4:
		lines = lines.slice(lines.size() - 4)
	_combat_log.text = "\n".join(lines)

func _combat_tick(delta: float) -> void:
	if _combat_monster == null or not is_instance_valid(_combat_monster):
		_on_combat_ended()
		return

	# Fall back to local combat if the server never acknowledges the join.
	if _combat_join_pending:
		_combat_join_wait += delta
		if _combat_join_wait >= COMBAT_JOIN_TIMEOUT:
			_combat_join_pending = false
			_combat_server       = false
			_combat_log_append("[Server slow — fighting locally.]")

	if not (_combat_monster.get("is_alive") as bool):
		# In server mode the kill reward is granted by the server (via World);
		# only award locally when fighting offline/fallback.
		if not _combat_server:
			_award_combat_xp()
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
				_combat_atk_timer = 2.4
				_launch_player_attack(_combat_monster, mon_pos)

	# Monster attack (only deals damage when physically in range)
	_combat_mon_timer -= delta
	if _combat_mon_timer <= 0.0:
		_combat_mon_timer = 2.0
		var in_range := false
		if _player != null:
			var mdist := (_combat_monster as Node2D).global_position.distance_to((_player as Node2D).global_position)
			in_range = mdist <= 55.0
		if in_range:
			var m_atk := _combat_monster.get("attack") as int
			var raw   := m_atk + randi() % 3
			var def   := GameManager.get_defense_power()
			var mdmg  := maxi(1, raw - def)
			GameManager.take_damage(mdmg)
			GameManager.add_xp("vitality", 2)
			_combat_log_append("> %s hits you for %d dmg" % [
				_combat_monster.get("display_name"), mdmg])
			_show_damage_number((_player as Node2D).global_position, mdmg, false)
		else:
			_combat_log_append("> %s closing in..." % _combat_monster.get("display_name"))

	_update_combat_ui()

const MELEE_HIT_RANGE := 52.0   # ~1.5 tiles — must be adjacent to swing
const _PROJECTILE := preload("res://scripts/Projectile.gd")

## Begin an attack: play the visible action (swing / projectile) and apply damage
## only when it connects — no instant hits.
##
## Magic / Ranged route through resource checks first. If the player has no
## stocked rune (or active rune fails the level gate, or arrows are out)
## the swing falls back to melee for that one tick so the fight keeps going.
## Admins skip the level gate but still need physical ammo / runes.
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

	# Consume the rune AFTER all gates pass (so a level-gated cast doesn't
	# burn the rune as a side-effect).
	if rune_to_consume != "":
		GameManager.remove_item_qty(rune_to_consume, 1)

	GameManager.add_xp(xp_skill, xp_amount)
	GameManager.add_xp("defense", 1)

	match style:
		"ranged", "magic":
			_spawn_combat_projectile(mon, atk, proj_kind, proj_color)
		_:
			if _player != null and _player.has_method("play_swing"):
				_player.call("play_swing", mon_pos.x)
			var t := get_tree().create_timer(0.16)
			t.timeout.connect(func() -> void: _apply_player_hit(mon, atk))

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

func _spawn_combat_projectile(mon: Node, atk: int, kind: String, col: Color) -> void:
	if _player == null:
		_apply_player_hit(mon, atk)
		return
	var scene := get_tree().current_scene
	if scene == null:
		_apply_player_hit(mon, atk)
		return
	var proj: Node2D = _PROJECTILE.new() as Node2D
	proj.call("setup", (_player as Node2D).global_position, mon as Node2D, kind, col)
	proj.set("on_hit", func() -> void: _apply_player_hit(mon, atk))
	scene.add_child(proj)

func _apply_player_hit(mon: Node, atk: int) -> void:
	if mon == null or not is_instance_valid(mon) or not (mon.get("is_alive") as bool):
		return
	var mon_pos := (mon as Node2D).global_position
	if _combat_server:
		NetworkManager.send_monster_damage(str(mon.get("entity_id")), atk)
		mon.call("flash_hit")
		_combat_log_append("> You hit for %d dmg  [%s]" % [atk, _combat_style])
	else:
		var dmg := (mon as Object).call("take_damage", atk) as int
		_combat_log_append("> You hit for %d dmg  [%s]" % [dmg, _combat_style])
		_show_damage_number(mon_pos, dmg, true)
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
func _show_damage_number(world_pos: Vector2, amount: int,
		from_player: bool, critical: bool = false) -> void:
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
	var wrap := Control.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dmg_layer.add_child(wrap)
	var thickness := 80.0
	var col := Color(0.95, 0.10, 0.10, 0.55)
	# Top bar
	var top := ColorRect.new()
	top.color = col
	top.anchor_left = 0.0; top.anchor_right = 1.0
	top.offset_bottom = thickness
	wrap.add_child(top)
	# Bottom bar
	var bot := ColorRect.new()
	bot.color = col
	bot.anchor_left = 0.0; bot.anchor_right = 1.0
	bot.anchor_top  = 1.0; bot.anchor_bottom = 1.0
	bot.offset_top  = -thickness
	wrap.add_child(bot)
	# Left bar
	var lft := ColorRect.new()
	lft.color = col
	lft.anchor_top = 0.0; lft.anchor_bottom = 1.0
	lft.offset_right = thickness
	wrap.add_child(lft)
	# Right bar
	var rgt := ColorRect.new()
	rgt.color = col
	rgt.anchor_left  = 1.0; rgt.anchor_right = 1.0
	rgt.anchor_top   = 0.0; rgt.anchor_bottom = 1.0
	rgt.offset_left  = -thickness
	wrap.add_child(rgt)
	# Single tween on the wrapping Control's modulate handles all four bars
	# at once. 0.2 s fade per spec.
	var tw := wrap.create_tween()
	tw.tween_property(wrap, "modulate:a", 0.0, 0.2) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.chain().tween_callback(func() -> void: wrap.queue_free())

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

func _build_thrall_tab() -> VBoxContainer:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_tab_title("Thrall Tasks"))
	root.add_child(HSeparator.new())

	# Task list (scrollable)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 110)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	_thrall_task_list = VBoxContainer.new()
	_thrall_task_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thrall_task_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_thrall_task_list)

	root.add_child(HSeparator.new())

	# ── Add Task form ──────────────────────────────────────────────────────
	var add_title := Label.new()
	add_title.text = "Add Task"
	add_title.add_theme_color_override("font_color", RS_DIM)
	add_title.add_theme_font_size_override("font_size", 10)
	root.add_child(add_title)

	# Type dropdown
	var type_opt := _make_opt()
	for t in ThrallManager.TASK_TYPES:
		type_opt.add_item((t as Dictionary)["label"] as String)
	root.add_child(type_opt)

	# Target dropdown (repopulates when type changes)
	var target_opt := _make_opt()
	root.add_child(target_opt)

	var _populate_targets := func() -> void:
		target_opt.clear()
		var type_id: String = (ThrallManager.TASK_TYPES[type_opt.selected] as Dictionary)["id"] as String
		var targets: Array = ThrallManager.TASK_TARGETS.get(type_id, []) as Array
		for tgt: Variant in targets:
			target_opt.add_item((tgt as Dictionary)["label"] as String)

	_populate_targets.call()
	type_opt.item_selected.connect(func(_i: int) -> void: _populate_targets.call())

	# Condition dropdown
	var cond_opt := _make_opt()
	for c in ThrallManager.CONDITIONS:
		cond_opt.add_item((c as Dictionary)["label"] as String)
	root.add_child(cond_opt)

	# Condition value field (only visible when condition has_value)
	var val_edit := LineEdit.new()
	val_edit.placeholder_text = "Value"
	val_edit.add_theme_font_size_override("font_size", 10)
	val_edit.add_theme_stylebox_override("normal", _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	val_edit.add_theme_color_override("font_color", RS_TEXT)
	val_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_edit.visible = false
	root.add_child(val_edit)

	cond_opt.item_selected.connect(func(idx: int) -> void:
		val_edit.visible = (ThrallManager.CONDITIONS[idx] as Dictionary).get("has_value", false) as bool)

	# Add button
	var add_btn := Button.new()
	add_btn.text = "+ Add Task"
	add_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	add_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 2))
	add_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   2))
	add_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	add_btn.add_theme_color_override("font_color", RS_TEXT)
	add_btn.add_theme_font_size_override("font_size", 10)
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func() -> void:
		var type_id: String  = (ThrallManager.TASK_TYPES[type_opt.selected] as Dictionary)["id"] as String
		var targets: Array   = ThrallManager.TASK_TARGETS.get(type_id, []) as Array
		var target_id: String = (targets[target_opt.selected] as Dictionary)["id"] as String
		var cond_id: String  = (ThrallManager.CONDITIONS[cond_opt.selected] as Dictionary)["id"] as String
		var cond_val: float  = val_edit.text.to_float() if val_edit.visible else 0.0
		ThrallManager.add_task(type_id, target_id, cond_id, cond_val)
		_refresh_thrall_tab())
	root.add_child(add_btn)

	# Info label
	var info_lbl := Label.new()
	info_lbl.text = "55% XP  ·  100% items  ·  24h max"
	info_lbl.add_theme_color_override("font_color", RS_DIM)
	info_lbl.add_theme_font_size_override("font_size", 9)
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(info_lbl)

	_refresh_thrall_tab()
	return root

func _refresh_thrall_tab() -> void:
	if _thrall_task_list == null:
		return
	for child in _thrall_task_list.get_children():
		child.queue_free()

	var tasks: Array = ThrallManager.tasks
	for i in range(tasks.size()):
		var task: Dictionary = tasks[i]
		var idx := i

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		_thrall_task_list.add_child(row)

		# Up / Down buttons
		var up_btn := Button.new()
		up_btn.text = "↑"
		up_btn.custom_minimum_size = Vector2(18, 18)
		up_btn.add_theme_font_size_override("font_size", 8)
		up_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		up_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 1))
		up_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   1))
		up_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		up_btn.add_theme_color_override("font_color", RS_DIM)
		up_btn.disabled = (idx == 0)
		up_btn.pressed.connect(func() -> void:
			ThrallManager.move_up(idx)
			_refresh_thrall_tab())
		row.add_child(up_btn)

		var dn_btn := Button.new()
		dn_btn.text = "↓"
		dn_btn.custom_minimum_size = Vector2(18, 18)
		dn_btn.add_theme_font_size_override("font_size", 8)
		dn_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		dn_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 1))
		dn_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   1))
		dn_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		dn_btn.add_theme_color_override("font_color", RS_DIM)
		dn_btn.disabled = (idx == tasks.size() - 1)
		dn_btn.pressed.connect(func() -> void:
			ThrallManager.move_down(idx)
			_refresh_thrall_tab())
		row.add_child(dn_btn)

		# Task label
		var lbl := Label.new()
		lbl.text = task.get("label", "?") as String
		lbl.add_theme_color_override("font_color", RS_TEXT)
		lbl.add_theme_font_size_override("font_size", 9)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.clip_text = true
		row.add_child(lbl)

		# Remove button
		var rm_btn := Button.new()
		rm_btn.text = "✕"
		rm_btn.custom_minimum_size = Vector2(18, 18)
		rm_btn.add_theme_font_size_override("font_size", 8)
		rm_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		rm_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 1))
		rm_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   1))
		rm_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.5), 1))
		rm_btn.add_theme_color_override("font_color", RS_DIM)
		rm_btn.pressed.connect(func() -> void:
			ThrallManager.remove_task(idx)
			_refresh_thrall_tab())
		row.add_child(rm_btn)

	if tasks.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No tasks queued.\nAdd a task below."
		empty_lbl.add_theme_color_override("font_color", RS_DIM)
		empty_lbl.add_theme_font_size_override("font_size", 9)
		_thrall_task_list.add_child(empty_lbl)

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
	close_btn.custom_minimum_size = Vector2(26, 26)
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.add_theme_stylebox_override("normal",  _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	close_btn.add_theme_stylebox_override("hover",   _rs(RS_BTN_H, RS_BORDER, 2))
	close_btn.add_theme_stylebox_override("pressed", _rs(RS_BTN_A, RS_GOLD,   2))
	close_btn.add_theme_stylebox_override("focus",   _rs(RS_BTN_N, RS_BORDER.darkened(0.4), 2))
	close_btn.add_theme_color_override("font_color", RS_DIM)
	close_btn.pressed.connect(func() -> void: _bank_window.visible = false)
	title_row.add_child(close_btn)

	outer.add_child(HSeparator.new())

	# Inventory half
	var inv_hdr := HBoxContainer.new()
	outer.add_child(inv_hdr)
	var inv_lbl := Label.new()
	inv_lbl.text = "Inventory (click deposits; right-click deposits all of a type)"
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
				GameManager.deposit_all_of(str(GameManager.inventory[si]["id"])))
		inv_grid.add_child(slot)
		_bank_inv_slots.append({"slot": slot, "color_rect": cr, "icon_rect": ir, "name_lbl": nl, "qty_lbl": ql})

	outer.add_child(HSeparator.new())

	# Bank stash half
	var stash_lbl := Label.new()
	stash_lbl.text = "Bank Storage (click to withdraw)"
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
	for i in range(36):
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
			if ev is InputEventMouseButton \
					and (ev as InputEventMouseButton).pressed \
					and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				if si < GameManager.bank_inventory.size():
					GameManager.withdraw_item(si))
		stash_grid.add_child(slot)
		_bank_stash_slots.append({"slot": slot, "color_rect": cr, "icon_rect": ir, "name_lbl": nl, "qty_lbl": ql})

func _on_open_bank() -> void:
	_refresh_bank()
	_bank_window.visible = true
	_register_proximity_panel(_bank_window)

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
	var icon_rect := s["icon_rect"]  as TextureRect
	var color_rect := s["color_rect"] as ColorRect
	var name_lbl  := s["name_lbl"]   as Label
	var qty_lbl   := s["qty_lbl"]    as Label
	if i >= items.size():
		icon_rect.texture = null
		color_rect.color  = Color.TRANSPARENT
		name_lbl.text     = ""
		qty_lbl.text      = ""
		return
	var item: Dictionary = items[i]
	var icon_path := "res://assets/icons/" + (item["id"] as String) + ".png"
	if ResourceLoader.exists(icon_path):
		icon_rect.texture = load(icon_path) as Texture2D
		color_rect.color  = Color.TRANSPARENT
		name_lbl.text     = ""
	else:
		icon_rect.texture = null
		color_rect.color  = _to_color(item.get("color")).darkened(0.2)
		name_lbl.text     = _item_abbrev(item["name"] as String)
	qty_lbl.text = "x%d" % item["qty"]

# ── CHAT BOX ──────────────────────────────────────────────────────────────────
func _build_chat_box() -> void:
	var chat_bg := StyleBoxFlat.new()
	chat_bg.bg_color = Color(0.06, 0.04, 0.02, 0.88)
	chat_bg.set_border_width_all(2)
	chat_bg.border_color = RS_BORDER.darkened(0.3)
	chat_bg.set_corner_radius_all(2)

	_chat_panel = PanelContainer.new()
	_chat_panel.add_theme_stylebox_override("panel", chat_bg)
	_chat_panel.anchor_left   = 1.0; _chat_panel.anchor_right  = 1.0
	_chat_panel.anchor_top    = 1.0; _chat_panel.anchor_bottom = 1.0
	_chat_panel.offset_left   = -286; _chat_panel.offset_right  = -6
	_chat_panel.offset_top    = -220; _chat_panel.offset_bottom = -44
	add_child(_chat_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	_chat_panel.add_child(vbox)

	# Header row with title + collapse button
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 0)
	vbox.add_child(hdr)
	var chat_title := Label.new()
	chat_title.text = "Chat"
	chat_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_title.add_theme_color_override("font_color", RS_DIM)
	chat_title.add_theme_font_size_override("font_size", 9)
	hdr.add_child(chat_title)
	var chat_collapse := Button.new()
	chat_collapse.text = "▲"
	chat_collapse.flat = true
	chat_collapse.custom_minimum_size = Vector2(16, 14)
	chat_collapse.add_theme_font_size_override("font_size", 8)
	chat_collapse.add_theme_color_override("font_color", RS_DIM)
	hdr.add_child(chat_collapse)

	# Content: scroll + input (wrapped so we can hide both at once)
	_chat_content = VBoxContainer.new()
	_chat_content.add_theme_constant_override("separation", 2)
	_chat_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_chat_content)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_content.add_child(scroll)

	_chat_vbox = VBoxContainer.new()
	_chat_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_vbox.add_theme_constant_override("separation", 1)
	scroll.add_child(_chat_vbox)

	var line_edit := LineEdit.new()
	line_edit.placeholder_text = "..."
	line_edit.add_theme_font_size_override("font_size", 9)
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
		# Collapsed: panel shrinks to header only (~22px from bottom)
		_chat_panel.offset_top = -66 if _chat_minimized else -220)

func _add_chat_message(msg: String) -> void:
	if _chat_vbox == null:
		return
	_chat_history.append(msg)
	while _chat_history.size() > CHAT_MAX:
		_chat_history.pop_front()
		if _chat_vbox.get_child_count() > 0:
			_chat_vbox.get_child(0).queue_free()

	var lbl := Label.new()
	lbl.text = msg
	lbl.add_theme_color_override("font_color", RS_TEXT)
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chat_vbox.add_child(lbl)

	# Auto-scroll to bottom
	await get_tree().process_frame
	var scroll := _chat_vbox.get_parent() as ScrollContainer
	if scroll != null:
		scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value as int

func _on_chat_xp(skill: String, amount: int) -> void:
	_add_chat_message("+%d %s XP" % [amount, skill.capitalize()])

func _on_thrall_returned(gains: Dictionary) -> void:
	for skill: Variant in gains.keys():
		var val: int = gains[skill]
		_add_chat_message("Thrall returned: +%d %s XP" % [val, (skill as String).capitalize()])

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

	# Canvas control (the actual map)
	_minimap_content = Control.new()
	_minimap_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_minimap_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap_content.draw.connect(_on_minimap_draw)
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

	# Player tile position (default to world centre if no player yet)
	var ptx := 150.0
	var pty := 150.0
	if _player != null:
		ptx = _player.global_position.x / 32.0
		pty = _player.global_position.y / 32.0

	# Source rect in the 300×300 texture (one pixel = one tile)
	var half := VIEW_TILES * 0.5
	var src_x := clampf(ptx - half, 0.0, 300.0 - VIEW_TILES)
	var src_y := clampf(pty - half, 0.0, 300.0 - VIEW_TILES)
	var src_rect := Rect2(src_x, src_y, VIEW_TILES, VIEW_TILES)

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

	# Player dot — always at canvas centre
	_minimap_canvas.draw_circle(Vector2(CANVAS_W * 0.5, CANVAS_H * 0.5), 3.0, Color.WHITE)

	# Circular mask — cover the 4 corners (outside the circle) with the bg colour.
	# Drawn as individual triangles instead of one big wedge polygon: Godot could
	# not triangulate the wedge and spammed "Invalid polygon data" every frame.
	# A 3-vertex polygon is always triangulable; degenerate slivers are skipped.
	var bg_col := Color(0.04, 0.04, 0.06, 1.0)
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
	# Circular border ring (this is the only visible border now)
	_minimap_canvas.draw_arc(Vector2(mm_cx, mm_cy), mm_r, 0.0, TAU, 48, RS_BORDER, 2.0)

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

func _mm_color_for_biome(bname: String) -> Color:
	match bname:
		"town":        return Color(0.52, 0.46, 0.36)
		"road":        return Color(0.52, 0.43, 0.28)
		"coast":       return Color(0.18, 0.50, 0.82)
		"ocean":       return Color(0.05, 0.12, 0.55)
		"snow":        return Color(0.82, 0.90, 0.96)
		"mountain":    return Color(0.52, 0.50, 0.48)
		"cliff":       return Color(0.30, 0.27, 0.25)
		"rocky":       return Color(0.42, 0.40, 0.37)
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
	# Boats remain craftable at the construction bench.
	for boat: Dictionary in _CONSTRUCTION_RECIPES:
		out.append(boat)
	return out

func _build_construction_window() -> void:
	_all_construction_recipes = _build_all_construction_recipes()
	# Taller window — ~4 rows of cards visible instead of 2.
	_construct_window = _build_recipe_window("🔨  Construction", _all_construction_recipes,
		"construction", func(r: Dictionary) -> void: _construct(r), 720.0)
	_construct_window.offset_left = -170; _construct_window.offset_right  = 170
	_construct_window.offset_top  = -400; _construct_window.offset_bottom = 400
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
	_rune_window.offset_left = -170; _rune_window.offset_right  = 170
	_rune_window.offset_top  = -240; _rune_window.offset_bottom = 240
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
	for ing: Dictionary in recipe["input"] as Array:
		if not GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int):
			return
	GameManager.add_item(recipe["id"] as String, recipe["name"] as String, 1, recipe["color"] as Color)
	GameManager.add_xp("magic", recipe["xp"] as int)
	_refresh_rune()

func _refresh_construction() -> void:
	_refresh_recipe_window(_all_construction_recipes, "construction", _construct_recipe_btns)

func _construct(recipe: Dictionary) -> void:
	# Farm Plot is built in the world (warband-gated), not added as an item.
	if str(recipe.get("id", "")) == "farm_plot":
		_build_farm_plot(recipe)
		return
	for ing: Dictionary in recipe["input"] as Array:
		if not GameManager.remove_item_qty(ing["id"] as String, ing["qty"] as int):
			return
	GameManager.add_item(recipe["id"] as String, recipe["name"] as String, 1, recipe["color"] as Color)
	GameManager.add_xp("construction", recipe["xp"] as int)
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
func _on_toast_xp(skill: String, amount: int) -> void:
	var col: Color = SKILL_COLORS.get(skill, RS_GOLD) as Color
	_show_toast("+%d %s XP" % [amount, skill.capitalize()], col)

func _on_toast_item(item_name: String, qty: int) -> void:
	_show_toast("+%d %s" % [qty, item_name], RS_TEXT)

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
		var skills: Array[String] = ["woodcutting","mining","fishing","foraging","combat",
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
