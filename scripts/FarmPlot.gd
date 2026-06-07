extends Area2D

## A player-built farm plot (placed via Construction, gated by warband + Construction 10).
## The plot structure persists server-side; the grow cycle is tended in-session:
##   empty  → click with seeds to plant (uses your best plantable seed)
##   growing → click to water (one-time, doubles growth speed) or check time left
##   ready  → click to harvest the crop (+ Farming XP)

const Farming = preload("res://scripts/Farming.gd")

enum St { EMPTY, GROWING, READY }

var entity_id: String = ""   # the a: id (set by World) so the admin editor can move/delete it
var _st: int = St.EMPTY
var _seed: Dictionary = {}
var _grow_elapsed: float = 0.0
var _watered: bool = false
var _is_hovered: bool = false

func _ready() -> void:
	add_to_group("interactable")
	input_pickable  = true
	collision_layer = 4
	collision_mask  = 0
	z_index = 0
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(44, 34)
	cs.shape  = rect
	add_child(cs)
	mouse_entered.connect(func() -> void:
		_is_hovered = true
		self_modulate = Color(1.20, 1.20, 1.20)
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_is_hovered = false
		self_modulate = Color.WHITE
		queue_redraw())
	Events.player_interacted.connect(_on_player_interacted)
	queue_redraw()

func _process(delta: float) -> void:
	if _st == St.GROWING:
		_grow_elapsed += delta * (2.0 if _watered else 1.0)
		if _grow_elapsed >= float(_seed.get("grow", 60.0)):
			_st = St.READY
			queue_redraw()

func _on_player_interacted(node: Node) -> void:
	if node != self:
		return
	match _st:
		St.EMPTY:   _try_plant()
		St.GROWING: _tend()
		St.READY:   _harvest()

func _try_plant() -> void:
	var lv := GameManager.get_skill_level("farming")
	var sd: Dictionary = Farming.best_plantable(GameManager.inventory, lv)
	if sd.is_empty():
		Events.chat_message.emit("You have no plantable seeds (forage herbs to find seeds).")
		return
	if not GameManager.remove_item_qty(str(sd["seed"]), 1):
		return
	_seed = sd
	_st = St.GROWING
	_grow_elapsed = 0.0
	_watered = false
	Events.chat_message.emit("You plant %s." % str(sd["seed_name"]))
	queue_redraw()

func _tend() -> void:
	if not _watered:
		_watered = true
		Events.chat_message.emit("You water the %s — it will grow faster." % str(_seed.get("crop_name", "crop")))
		queue_redraw()
	else:
		var left := int(maxf(0.0, float(_seed.get("grow", 60.0)) - _grow_elapsed))
		Events.chat_message.emit("The %s is still growing (%ds left)." % [str(_seed.get("crop_name", "crop")), left])

func _harvest() -> void:
	var amt := int(_seed.get("yield", 1))
	GameManager.add_item(str(_seed["crop"]), str(_seed["crop_name"]), amt, Farming.color_of(_seed))
	GameManager.add_xp("farming", int(_seed.get("xp", 10)))
	Events.chat_message.emit("You harvest %dx %s." % [amt, str(_seed["crop_name"])])
	_st = St.EMPTY
	_seed = {}
	_grow_elapsed = 0.0
	_watered = false
	queue_redraw()

func _draw() -> void:
	# Tilled soil bed.
	var soil := Color(0.34, 0.22, 0.12)
	draw_rect(Rect2(-22, -16, 44, 32), soil)
	draw_rect(Rect2(-22, -16, 44, 32), soil.darkened(0.4), false, 2.0)
	# Furrows.
	for fx in range(-16, 20, 8):
		draw_line(Vector2(fx, -14), Vector2(fx, 14), soil.darkened(0.25), 1.5)
	# Wooden corner posts.
	for c: Vector2 in [Vector2(-22, -16), Vector2(18, -16), Vector2(-22, 12), Vector2(18, 12)]:
		draw_rect(Rect2(c.x, c.y, 4, 4), Color(0.45, 0.30, 0.16))

	if _st == St.GROWING or _st == St.READY:
		var prog: float = 1.0 if _st == St.READY else clampf(_grow_elapsed / float(_seed.get("grow", 60.0)), 0.0, 1.0)
		var crop := Farming.color_of(_seed)
		var stalk := Color(0.20, 0.50, 0.18)
		for sx in range(-14, 18, 8):
			var h := lerpf(3.0, 16.0, prog)
			draw_line(Vector2(sx, 12), Vector2(sx, 12 - h), stalk, 2.0)
			if _st == St.READY:
				draw_circle(Vector2(sx, 12 - h), 3.0, crop)
			elif prog > 0.5:
				draw_circle(Vector2(sx, 12 - h), 1.6, crop.lightened(0.1))
	if _watered and _st == St.GROWING:
		draw_circle(Vector2(16, -12), 2.0, Color(0.40, 0.70, 0.95, 0.8))

	if _is_hovered:
		# Hover indication is delivered via self_modulate from the
		# mouse_entered callback — no outline rect.
		pass
		var font := ThemeDB.fallback_font
		if font != null:
			var label := "Farm Plot"
			match _st:
				St.GROWING: label = "Growing %s" % str(_seed.get("crop_name", ""))
				St.READY:   label = "Harvest %s" % str(_seed.get("crop_name", ""))
				_:          label = "Farm Plot — plant"
			draw_string(font, Vector2(-tw_half(font, label), -24), label,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.55, 0.95, 0.45))

func tw_half(font: Font, s: String) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x * 0.5
