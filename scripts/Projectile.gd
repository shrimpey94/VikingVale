extends Node2D

## A travelling combat projectile (ranged arrow / magic bolt). Spawned into the
## world by the HUD combat loop; flies from the player to the target and invokes
## `on_hit` on arrival so damage lands only when the projectile connects.

var _target: Node2D = null
var _target_pos: Vector2 = Vector2.ZERO
var _speed: float = 620.0
var _kind: String = "arrow"      # "arrow" | "magic"
var _color: Color = Color.WHITE
var on_hit: Callable
var _done: bool = false
var _life: float = 1.2           # safety despawn

func setup(start: Vector2, target_node: Node2D, kind: String, color: Color) -> void:
	global_position = start
	_target = target_node
	_target_pos = target_node.global_position if target_node != null else start
	_kind = kind
	_color = color
	z_index = 6

func _process(delta: float) -> void:
	_life -= delta
	if _target != null and is_instance_valid(_target):
		_target_pos = _target.global_position
	var to := _target_pos - global_position
	var d := to.length()
	if d <= 10.0 or _life <= 0.0:
		_arrive()
		return
	global_position += (to / d) * _speed * delta
	rotation = to.angle()
	queue_redraw()

func _arrive() -> void:
	if _done:
		return
	_done = true
	if on_hit.is_valid():
		on_hit.call()
	queue_free()

func _draw() -> void:
	if _kind == "magic":
		draw_circle(Vector2.ZERO, 6.0, Color(_color.r, _color.g, _color.b, 0.4))
		draw_circle(Vector2.ZERO, 4.0, _color)
		draw_circle(Vector2(-1, -1), 1.6, Color(1, 1, 1, 0.85))
	else:
		draw_line(Vector2(-7, 0), Vector2(6, 0), Color(0.55, 0.38, 0.18), 2.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(9, 0), Vector2(3, -3), Vector2(3, 3)]), Color(0.82, 0.82, 0.88))
		draw_line(Vector2(-7, 0), Vector2(-4, -2), Color(0.9, 0.9, 0.9), 1.0)
		draw_line(Vector2(-7, 0), Vector2(-4,  2), Color(0.9, 0.9, 0.9), 1.0)
