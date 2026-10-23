extends Node3D

## CSG SANDBOX — a place to hand-build models in the Godot editor with mouse +
## keyboard (Godot's answer to Unity ProBuilder). Edit the shapes under the
## "MyBuilding" node in the Scene panel + the 3D viewport. This script just adds a
## sun, sky, and a camera on RUN (F6) so your model is lit + framed; while EDITING,
## the editor's own preview lighting shows everything. See handmade/CSG_HOWTO.md.

func _ready() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -40, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.53, 0.68, 0.83)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.60, 0.64, 0.70)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.current = true
	add_child(cam)
	cam.look_at_from_position(Vector3(7, 6, 9), Vector3(0, 1.5, 0), Vector3.UP)

	print(">>> CSG SANDBOX — build under 'MyBuilding'. Read handmade/CSG_HOWTO.md <<<")
