extends Node
## Isolated GPU capture of the real Interactable and World3D visual factory.
const Art = preload("res://scripts/art/StonePickupArt.gd")
const WorldVisual = preload("res://scripts/World3D.gd")
const MeshFactory = preload("res://scripts/Mesh3D.gd")
const Interactable = preload("res://scenes/Interactable.tscn")

func label_at(text: String, pos: Vector2, font_size := 20) -> void:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	add_child(label)

func _ready() -> void:
	get_window().content_scale_size = Vector2i(1000, 640)
	_capture.call_deferred()

func _capture() -> void:
	var procedural := "--procedural-stone" in OS.get_cmdline_user_args()
	var mode := "procedural fallback" if procedural else "authored v001"
	var bg := ColorRect.new()
	bg.color = Color(.075, .09, .11)
	bg.size = Vector2(1000, 640)
	add_child(bg)
	label_at("VikingVale / Stone Pickup / " + mode, Vector2(28, 20), 26)
	label_at("2D Interactable drawing (4x inspection scale)", Vector2(28, 72), 18)
	var vp2 := SubViewport.new()
	vp2.size = Vector2i(112, 42)
	vp2.transparent_bg = true
	vp2.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp2)
	for index in range(3):
		var node := Interactable.instantiate()
		node.interactable_type_str = "stone"
		node.required_skill = "foraging"
		node.color = Color(.58, .56, .52)
		node.position = Vector2(20 + index * 36, 20)
		vp2.add_child(node)
		node.set_process(false)
		if index == 1:
			node._on_hover_enter()
		elif index == 2:
			node.apply_depleted(45)
	var tex2 := TextureRect.new()
	tex2.texture = vp2.get_texture()
	tex2.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tex2.position = Vector2(28, 105)
	tex2.scale = Vector2(4, 4)
	add_child(tex2)
	label_at("Normal                 Hover                  Collected (hidden)", Vector2(28, 279), 16)
	label_at("Original 16x12 pick shape and world anchor retained", Vector2(28, 308), 15)
	label_at("3D GLB / same master / live lighting", Vector2(525, 72), 20)
	var vp3 := SubViewport.new()
	vp3.size = Vector2i(448, 430)
	vp3.own_world_3d = true
	vp3.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp3)
	var world := WorldVisual.new()
	var factory := MeshFactory.new()
	world.set("_mesh", factory)
	world.set("_mesh_mat", factory.mat)
	var visual := world._interactable_node("stone", Color(.58, .56, .52))
	# Fixed view isolates artwork; actual world placement retains random transforms.
	visual.scale = Vector3.ONE
	visual.rotation = Vector3.ZERO
	vp3.add_child(visual)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = .85
	vp3.add_child(camera)
	camera.position = Vector3(.35, .85, 1.15)
	camera.look_at(Vector3(0, .13, 0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.25
	vp3.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(.13, .16, .19)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(.65, .72, .8)
	env.environment.ambient_light_energy = .7
	vp3.add_child(env)
	var tex3 := TextureRect.new()
	tex3.texture = vp3.get_texture()
	tex3.position = Vector2(525, 108)
	add_child(tex3)
	label_at("Sprite at gameplay zoom (2.5x)", Vector2(28, 375), 18)
	var small := TextureRect.new()
	small.texture = vp2.get_texture()
	small.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	small.scale = Vector2(2.5, 2.5)
	small.position = Vector2(28, 410)
	add_child(small)
	label_at("Offline inspection only; no gameplay or server session started.", Vector2(28, 580), 18)
	for frame in range(8):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var suffix := "fallback" if procedural else "authored"
	var path := OS.get_environment("VIKINGVALE_TEST_OUTPUT").path_join("godot_" + suffix + ".png")
	var err := get_viewport().get_texture().get_image().save_png(path)
	world.free()
	factory.free()
	print("STONE_PREVIEW: ", path, " result=", err)
	get_tree().quit(err)
