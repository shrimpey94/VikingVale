extends Area2D

## Procedural draw dispatch — ItemArt is `class_name ItemArt` so it
## resolves globally without a preload const (which would just shadow
## the global class name).

var item_id:    String   = ""
var item_name:  String   = ""
var item_qty:   int      = 1
var item_color: Color    = Color.WHITE

# Phase 5 gold-pile mode. When `is_gold_pile`, item_qty IS the gold amount,
# item_id is "gold_coins" (display label only). `pile_id` is empty for
# local-only piles (offline kills) and non-empty for server-tracked piles
# (online kills). The two pickup paths differ:
#   pile_id == "": credit GameManager.gold directly + queue_free
#   pile_id != "": send gold_pile_pickup to the server, DO NOT queue_free —
#                  wait for the server's gold_pile_remove broadcast which
#                  World.gd routes back here via _gold_pile_nodes lookup.
var is_gold_pile: bool   = false
var pile_id:      String = ""

## PvP death pile — server-tracked stack of any single item (bones,
## pvp_token, or a dropped inventory item). Pickup routes through the
## dedicated pvp_pile_pickup message so first-click-wins is enforced
## server-side. Distinct from a gold pile because the payload is an item,
## not a gold amount.
var is_pvp_pile: bool = false

## PvP pile setup — pid is the server's pile_id (required, always non-empty
## since pvp piles are always server-tracked).
func setup_pvp_pile(pid: String, id: String, iname: String, qty: int,
		col: Color) -> void:
	is_pvp_pile = true
	pile_id     = pid
	item_id     = id
	item_name   = iname
	item_qty    = qty
	item_color  = col
	var path := "res://assets/icons/drop_" + id + ".png"
	if ResourceLoader.exists(path):
		_icon_tex = load(path) as Texture2D

var _bob:      float    = 0.0
var _lifetime: float    = 120.0   # matches server GOLD_PILE_LIFETIME
var _hovered:  bool     = false
var _icon_tex: Texture2D = null

func setup(id: String, iname: String, qty: int, col: Color) -> void:
	item_id    = id
	item_name  = iname
	item_qty   = qty
	item_color = col
	var path := "res://assets/icons/drop_" + id + ".png"
	if ResourceLoader.exists(path):
		_icon_tex = load(path) as Texture2D

## Gold pile setup. `pid` is the server's pile_id ("" for local-only piles).
## `amount` is stored in item_qty so all the existing tooltip / draw helpers
## have a single qty field to read.
func setup_gold_pile(pid: String, amount: int) -> void:
	is_gold_pile = true
	pile_id      = pid
	item_id      = "gold_coins"
	item_name    = "Coins"
	item_qty     = amount
	item_color   = Color(1.0, 0.85, 0.25)

func _ready() -> void:
	input_pickable  = true
	add_to_group("loot_drop")   # so the autoplay AI can find + collect drops
	collision_layer = 16
	collision_mask  = 0
	var cs   := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = 9.0
	cs.shape = circ
	add_child(cs)
	mouse_entered.connect(func() -> void:
		_hovered = true
		self_modulate = Color(1.20, 1.20, 1.20)
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hovered = false
		self_modulate = Color.WHITE
		queue_redraw())

func _process(delta: float) -> void:
	_bob      += delta * 2.8
	_lifetime -= delta
	if _lifetime <= 0.0:
		queue_free()
		return
	queue_redraw()

## Pickup proximity — the player must be physically touching the drop
## before pickup fires. Clicking loot from across the map used to insta-grant
## it; now it just sets a walk target and the pickup completes when the
## player arrives.
const PICKUP_RANGE := 40.0

func _input_event(_viewport: Viewport, event: InputEvent, _shape: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		perform_pickup()
		return
	# Adjacency gate — if the player is already within PICKUP_RANGE fire
	# pickup immediately; otherwise stage a pending pickup and walk them
	# to the drop's position. Player._physics_process closes the loop.
	if global_position.distance_to(player.global_position) <= PICKUP_RANGE:
		perform_pickup()
	else:
		# Set the pending pickup + walk target on the player. Any manual
		# WASD input or a new click on something else clears it.
		player.set("_target_pos", global_position)
		if player.has_method("set_pending_pickup"):
			player.call("set_pending_pickup", self)

## Called by the click handler (if player already close) or by Player.gd
## when the walk-toward-pickup completes. Extracted so the pickup logic
## has a single entry point regardless of how it was triggered.
func perform_pickup() -> void:
	if is_pvp_pile:
		# Server-tracked stack — request the claim. World.gd's
		# `_pvp_pile_nodes` lookup will free this node when the server's
		# pvp_pile_remove broadcast arrives. Inventory-full check is
		# advisory here; the server always sends the grant, and the
		# client's add_item is fine dropping to the floor at max.
		# Stackable items can always merge into an existing stack; non-
		# stackables need a free slot. Anything else is silently rejected
		# so the pile stays on the ground for someone else.
		if GameManager.free_slots() <= 0 and not GameManager.is_stackable(item_id):
			Events.chat_message.emit("Inventory full — make room first.")
			return
		NetworkManager.send_pvp_pile_pickup(pile_id)
		return
	if is_gold_pile:
		if pile_id == "":
			# Local pile — solo / offline kill path. Credit gold directly
			# and clean up the visual. No server roundtrip.
			GameManager.gold += item_qty
			Events.inventory_changed.emit()   # refreshes gold display in HUD
			Events.chat_message.emit("Picked up %d gold." % item_qty)
			queue_free()
		else:
			# Server-tracked pile — request claim. World.gd will free this
			# node when the server's gold_pile_remove broadcast arrives.
			# Two clicks before that arrives no-op silently on the server.
			NetworkManager.send_gold_pile_pickup(pile_id)
		return
	GameManager.add_item(item_id, item_name, item_qty, item_color)
	queue_free()

func _draw() -> void:
	var bob_y := sin(_bob) * 2.5

	if is_gold_pile:
		_draw_gold_pile(bob_y)
		return
	# PvP token gets a distinct procedural render — gold coin base + red
	# ribbon banner + skull-and-bones glyph + white V. Reads as spoils of
	# combat rather than a generic pickup.
	if item_id == "pvp_token":
		_draw_pvp_token(bob_y)
		return

	# Shadow audit: LootDrops are objects on the ground, not living actors,
	# so no ground shadow is drawn. The bob already animates the icon enough
	# to make it read as a pickup.
	if _icon_tex != null:
		# Draw the 16×16 icon centred, with bob offset. Hover indication is
		# delivered via self_modulate from the mouse_entered callback —
		# no yellow ring around the icon.
		draw_texture(_icon_tex, Vector2(-8.0, -8.0 + bob_y))
	else:
		# Procedural dispatch — most icon-less items have a bespoke draw
		# in ItemArt (crops, teeth, tokens, sea creatures, warrants).
		# Unknown / unshipped ids fall through to the loot pouch so a
		# fresh item never renders as debug art.
		if not ItemArt.draw_ground_icon(self, item_id, bob_y, item_color):
			ItemArt.draw_ground_pouch(self, bob_y, item_color)

	if _hovered:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(-20.0, -14.0 + bob_y), item_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 1.0, 0.8, 0.95))

## PvP token render — user asked for "a gold coin with a V and a red ribbon
## with skull-bones, or as close as possible". Composed procedurally so we
## don't need an art asset: gold coin base + inner disc, red ribbon banner
## behind it, white V glyph on the face, and a small skull-and-crossbones
## motif in the ribbon. Rendered per-frame; cheap.
func _draw_pvp_token(bob_y: float) -> void:
	var pos := Vector2(0.0, bob_y)
	var gold := Color(1.00, 0.85, 0.20)
	var gold_dk := Color(0.72, 0.52, 0.08)
	var gold_lt := Color(1.00, 0.95, 0.55)
	var ribbon := Color(0.75, 0.10, 0.12)
	var ribbon_dk := Color(0.50, 0.06, 0.08)
	# ── Ribbon banner behind the coin. Two rectangular tails flanking the
	#    coin form the classic banner silhouette.
	var rib_h := 3.0
	draw_rect(Rect2(pos.x - 12.0, pos.y - rib_h, 24.0, rib_h * 2.0), ribbon)
	# Notched tails
	draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - 12.0, pos.y - rib_h),
		Vector2(pos.x - 16.0, pos.y),
		Vector2(pos.x - 12.0, pos.y + rib_h)]), ribbon_dk)
	draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x + 12.0, pos.y - rib_h),
		Vector2(pos.x + 16.0, pos.y),
		Vector2(pos.x + 12.0, pos.y + rib_h)]), ribbon_dk)
	# Ribbon highlight
	draw_line(Vector2(pos.x - 11.0, pos.y - rib_h + 0.7),
		Vector2(pos.x + 11.0, pos.y - rib_h + 0.7),
		ribbon.lightened(0.35), 0.7)
	# Tiny skull-and-bones on the ribbon (left tail side).
	var sk_x := pos.x - 8.0
	var sk_y := pos.y + 0.2
	draw_circle(Vector2(sk_x, sk_y), 1.2, Color(0.95, 0.92, 0.85))
	draw_rect(Rect2(sk_x - 0.6, sk_y - 0.2, 0.5, 0.6), Color(0.10, 0.06, 0.06))
	draw_rect(Rect2(sk_x + 0.2, sk_y - 0.2, 0.5, 0.6), Color(0.10, 0.06, 0.06))
	# Crossbones — two short diagonal lines behind the skull
	draw_line(Vector2(sk_x - 2.0, sk_y + 1.4),
		Vector2(sk_x + 2.0, sk_y - 1.4),
		Color(0.95, 0.92, 0.85, 0.9), 0.7)
	draw_line(Vector2(sk_x - 2.0, sk_y - 1.4),
		Vector2(sk_x + 2.0, sk_y + 1.4),
		Color(0.95, 0.92, 0.85, 0.9), 0.7)

	# ── Coin body — outer ring + inner disc + top-left highlight.
	draw_circle(pos, 7.0, gold_dk)
	draw_circle(pos, 6.2, gold)
	draw_circle(pos, 5.4, gold.lightened(0.10))
	draw_circle(pos + Vector2(-1.6, -1.6), 1.6, gold_lt)

	# ── V glyph — two diagonal strokes meeting at the bottom-centre.
	var v_col := Color(0.98, 0.96, 0.88)
	var v_shadow := Color(0.45, 0.30, 0.05, 0.85)
	# Shadow layer for depth
	draw_line(Vector2(pos.x - 3.0, pos.y - 2.4),
		Vector2(pos.x + 0.2, pos.y + 2.6), v_shadow, 1.6)
	draw_line(Vector2(pos.x + 3.0, pos.y - 2.4),
		Vector2(pos.x - 0.2, pos.y + 2.6), v_shadow, 1.6)
	# Foreground strokes
	draw_line(Vector2(pos.x - 2.6, pos.y - 2.6),
		Vector2(pos.x, pos.y + 2.4), v_col, 1.3)
	draw_line(Vector2(pos.x + 2.6, pos.y - 2.6),
		Vector2(pos.x, pos.y + 2.4), v_col, 1.3)

	# Hover label — "PvP Token ×N"
	if _hovered:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(-24.0, -14.0 + bob_y),
			"%s ×%d" % [item_name, item_qty],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.90, 0.30, 0.95))

## RuneScape-style coin-pile rendering with three size tiers. Composed of
## overlapping yellow circles + a darker rim per coin so the pile reads as
## stacked metal even at 1px-zoom. The bob animation is shared with regular
## drops; we add a subtle yellow glow on the medium/large tiers so big
## piles draw the eye from further away.
func _draw_gold_pile(bob_y: float) -> void:
	var qty := item_qty
	var tier := 0   # 0 = small (<100), 1 = medium (100-999), 2 = large (1000+)
	if qty >= 1000:
		tier = 2
	elif qty >= 100:
		tier = 1
	# Shadow audit: gold piles are pickups, not actors — no ground shadow.
	# The bob and overlapping coin geometry give the pile enough visual mass
	# to read from a distance without a planar shadow under it.

	var gold     := Color(1.00, 0.85, 0.20)
	var gold_dk  := Color(0.78, 0.58, 0.10)
	var gold_lt  := Color(1.00, 0.95, 0.55)
	# Soft glow halo for medium/large piles.
	if tier >= 1:
		var glow_r := 9.0 + float(tier) * 3.0
		draw_circle(Vector2(0.0, bob_y), glow_r,
			Color(1.0, 0.85, 0.25, 0.18))

	# Coin positions per tier. Each tuple is offset from center.
	var coins: Array[Vector2]
	if tier == 0:
		coins = [Vector2(0, 0)]
	elif tier == 1:
		coins = [Vector2(-3, 1), Vector2(3, 1), Vector2(0, -2)]
	else:
		coins = [Vector2(-5, 2), Vector2(0, 2), Vector2(5, 2),
				 Vector2(-2, -1), Vector2(2, -1), Vector2(0, -4)]
	var coin_r := 3.5 if tier == 0 else 3.0
	for c: Vector2 in coins:
		draw_circle(c + Vector2(0.0, bob_y), coin_r, gold)
		draw_arc(c + Vector2(0.0, bob_y), coin_r, 0.0, TAU, 12, gold_dk, 0.8)
		# Tiny highlight
		draw_circle(c + Vector2(-0.8, -0.8 + bob_y), 0.8, gold_lt)

	# Hover label: "Coins: N"
	if _hovered:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(-20.0, -14.0 + bob_y),
			"Coins: %d" % qty,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 1.0, 0.8, 0.95))
