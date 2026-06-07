extends Area2D

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

func _input_event(_viewport: Viewport, event: InputEvent, _shape: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
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

	# Shadow audit: LootDrops are objects on the ground, not living actors,
	# so no ground shadow is drawn. The bob already animates the icon enough
	# to make it read as a pickup.
	if _icon_tex != null:
		# Draw the 16×16 icon centred, with bob offset. Hover indication is
		# delivered via self_modulate from the mouse_entered callback —
		# no yellow ring around the icon.
		draw_texture(_icon_tex, Vector2(-8.0, -8.0 + bob_y))
	else:
		# Fallback: simple coloured circle when icon not yet generated
		draw_circle(Vector2(0.0, bob_y), 7.0, item_color)
		draw_arc(Vector2(0.0, bob_y), 7.0, 0.0, TAU, 20, item_color.darkened(0.35), 1.5)

	if _hovered:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(-20.0, -14.0 + bob_y), item_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 1.0, 0.8, 0.95))

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
