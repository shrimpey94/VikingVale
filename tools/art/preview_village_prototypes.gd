extends Node
const Art = preload("res://scripts/art/VillagePrototypeArt.gd")
const WorldVisual = preload("res://scripts/World3D.gd")
const MeshFactory = preload("res://scripts/Mesh3D.gd")
const Interactable = preload("res://scenes/Interactable.tscn")
const NPC = preload("res://scripts/NPC.gd")

func label_at(text: String, pos: Vector2, size := 20) -> void:
	var label := Label.new();label.text=text;label.position=pos;label.add_theme_font_size_override("font_size",size);add_child(label)

func _ready() -> void:
	get_window().content_scale_size=Vector2i(1440,900)
	_capture.call_deferred()

func _capture() -> void:
	var bg:=ColorRect.new();bg.color=Color(.075,.09,.11);bg.size=Vector2(1440,900);add_child(bg)
	var mode:="fallback" if "--procedural-village" in OS.get_cmdline_user_args() else "authored"
	label_at("VikingVale / Oak, House, Karl / "+mode,Vector2(28,16),26)
	var world:=WorldVisual.new();var factory:=MeshFactory.new();world.set("_mesh",factory);world.set("_mesh_mat",factory.mat)
	for i in range(3):
		var x:=28+i*470
		label_at(["Oak Tree / five states","House / ordinary houses only","Karl / one named worker"][i],Vector2(x,66),22)
		label_at("2D in-game drawing / 2x",Vector2(x,102),16)
		var vp2:=SubViewport.new();vp2.size=Vector2i(210,148);vp2.transparent_bg=true;vp2.render_target_update_mode=SubViewport.UPDATE_ALWAYS;add_child(vp2)
		var logic:Node2D
		var visual:Node3D
		if i<2:
			logic=Interactable.instantiate();logic.set("interactable_type_str","tree" if i==0 else "building");logic.set("display_name","Oak Tree" if i==0 else "House");logic.set("color",Color(.18,.55,.15) if i==0 else Color(.65,.52,.35))
			vp2.add_child(logic);logic.position=Vector2(105,105)
			visual=world._interactable_node(logic.get("interactable_type_str"),logic.get("color"),logic.get("display_name"),logic)
		else:
			logic=Area2D.new();logic.set_script(NPC);logic.set("npc_type","worker");logic.set("npc_name_str","Karl");vp2.add_child(logic);logic.position=Vector2(105,85);logic.set("_idle_timer",5.0);logic.set("_iv_kind",0)
			visual=world._npc_node("worker","Kjelvik","Karl",logic)
		logic.set_process(false)
		var tex2:=TextureRect.new();tex2.texture=vp2.get_texture();tex2.texture_filter=CanvasItem.TEXTURE_FILTER_NEAREST;tex2.position=Vector2(x,126);tex2.scale=Vector2(2,2);add_child(tex2)
		label_at("3D imported GLB / live lighting",Vector2(x,432),16)
		var vp3:=SubViewport.new();vp3.size=Vector2i(430,365);vp3.own_world_3d=true;vp3.render_target_update_mode=SubViewport.UPDATE_ALWAYS;add_child(vp3)
		visual.scale=Vector3.ONE;visual.rotation=Vector3.ZERO;vp3.add_child(visual);visual.set_process(false)
		var camera:=Camera3D.new();camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=5.2 if i<2 else 2.3;vp3.add_child(camera)
		var target:=Vector3(0,1.7 if i<2 else .85,0);camera.position=target+Vector3(2.4,2.1,5);camera.look_at(target)
		var light:=DirectionalLight3D.new();light.rotation_degrees=Vector3(-55,-35,0);light.light_energy=1.2;vp3.add_child(light)
		var env:=WorldEnvironment.new();env.environment=Environment.new();env.environment.background_mode=Environment.BG_COLOR;env.environment.background_color=Color(.13,.16,.19);env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;env.environment.ambient_light_color=Color(.65,.72,.8);env.environment.ambient_light_energy=.7;vp3.add_child(env)
		var tex3:=TextureRect.new();tex3.texture=vp3.get_texture();tex3.position=Vector2(x,460);add_child(tex3)
	label_at("Actual visual adapters. Offline capture; original interactions and procedural fallbacks retained.",Vector2(28,856),18)
	for i in range(8):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path:=OS.get_environment("VIKINGVALE_TEST_OUTPUT").path_join("godot_"+mode+".png")
	var error:=get_viewport().get_texture().get_image().save_png(path)
	world.free();factory.free();print("VILLAGE_PREVIEW: ",path," result=",error);get_tree().quit(error)
