extends Node

## ── TouchInput ──────────────────────────────────────────────────────────────
##
## Mobile input adapter. The game's input pipeline is built around mouse
## left/right click. On touch devices there's no right-click — so we
## translate **long-press** into a synthetic right-click MouseButton event.
##
## How it fires:
##   - Touch begins → start timer
##   - Finger moves more than DRAG_CANCEL_PX → cancel timer (it's a drag)
##   - Finger held still for LONG_PRESS_SECONDS → synthesize a press +
##     release of MOUSE_BUTTON_RIGHT at the touch position, and SUPPRESS
##     the corresponding tap-release so we don't also trigger left-click.
##
## On desktop (no touch events) this autoload is a no-op. The
## `emulate_mouse_from_touch=true` project setting in [input_devices]
## handles the normal tap → left-click translation; this only intercepts
## the long-press case.
##
## Visual hint: when the long-press window passes the halfway mark the
## node fires Events.touch_long_press_armed so a UI overlay (future)
## can show a ring fill. Until that overlay exists this is just a no-op
## emit.

const LONG_PRESS_SECONDS := 0.55     # 550ms — feels intentional, not laggy
const DRAG_CANCEL_PX     := 12.0     # finger jitter tolerance before cancel

var _pressing: bool = false
var _press_start_t: float = 0.0
var _press_pos: Vector2 = Vector2.ZERO
var _press_index: int = -1
var _suppress_next_release: bool = false
var _armed_emitted: bool = false


func _ready() -> void:
	# Only relevant on devices that actually report touch. Process every
	# frame regardless — the cost is one `if` per frame on desktop.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _process(_delta: float) -> void:
	if not _pressing:
		return
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _press_start_t
	# Halfway-armed hint — future UI can use this to start a ring fill.
	if not _armed_emitted and elapsed >= LONG_PRESS_SECONDS * 0.5:
		_armed_emitted = true
		# Soft signal — only fires if Events exposes it. Silent if not.
		if Events.has_signal("touch_long_press_armed"):
			Events.emit_signal("touch_long_press_armed", _press_pos)
	if elapsed >= LONG_PRESS_SECONDS:
		_fire_synthetic_right_click(_press_pos)
		_pressing = false
		_armed_emitted = false


func _handle_touch(t: InputEventScreenTouch) -> void:
	if t.pressed:
		# Track only the FIRST finger. Multi-touch is for camera pinch +
		# pan in a later pass; for now we just don't get confused by it.
		if _pressing:
			return
		_pressing = true
		_press_start_t = Time.get_ticks_msec() / 1000.0
		_press_pos = t.position
		_press_index = t.index
		_armed_emitted = false
		_suppress_next_release = false
	else:
		# Release. If we already synthesized a right-click, swallow this
		# release so it doesn't ALSO fire a left-click via the engine's
		# emulate_mouse_from_touch translation.
		if t.index != _press_index:
			return
		_pressing = false
		_press_index = -1
		_armed_emitted = false
		if _suppress_next_release:
			_suppress_next_release = false
			get_viewport().set_input_as_handled()


func _handle_drag(d: InputEventScreenDrag) -> void:
	if not _pressing or d.index != _press_index:
		return
	if _press_pos.distance_to(d.position) > DRAG_CANCEL_PX:
		_pressing = false
		_armed_emitted = false


## Build a press + release MOUSE_BUTTON_RIGHT pair at `pos` and push them
## into the engine input queue. Player._unhandled_input picks them up via
## its existing right-click branch — no other code needs to know about
## touch.
func _fire_synthetic_right_click(pos: Vector2) -> void:
	_suppress_next_release = true
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = pos
	press.global_position = pos
	Input.parse_input_event(press)
	# Release in the same frame — the action-menu handler treats only
	# the press as the trigger, but a balanced release keeps Godot's
	# input state machine tidy.
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_RIGHT
	release.pressed = false
	release.position = pos
	release.global_position = pos
	Input.parse_input_event(release)
