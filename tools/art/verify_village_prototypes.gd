extends Node
const Art = preload("res://scripts/art/VillagePrototypeArt.gd")
const WorldVisual = preload("res://scripts/World3D.gd")
const MeshFactory = preload("res://scripts/Mesh3D.gd")
const Interactable = preload("res://scenes/Interactable.tscn")
const NPC = preload("res://scripts/NPC.gd")
var results: Array = []
var failures := 0

func check(ok: bool, description: String) -> void:
	results.append({"check": description, "passed": ok})
	if not ok: failures += 1; push_error(description)

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var authored := not ("--procedural-village" in OS.get_cmdline_user_args())
	check(NetworkManager.state == 0, "Offline transport disabled")
	for key: String in Art.VERSIONS:
		var base: String = "res://assets/authored/village/%s/%s/%s" % [key,Art.VERSIONS[key],key]
		var texture := load(base+".png") as Texture2D
		var image := texture.get_image()
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base+".frames.json"))
		var exported_size := Vector2(data["frame_size"][0],data["frame_size"][1])
		var runtime_size := Vector2(Art.FRAMES[key]["frame_size"][0],Art.FRAMES[key]["frame_size"][1])
		var exported_offset := Vector2(data["draw_offset"][0],data["draw_offset"][1])
		var runtime_offset := Vector2(Art.FRAMES[key]["draw_offset"][0],Art.FRAMES[key]["draw_offset"][1])
		check(exported_size==runtime_size and exported_offset==runtime_offset,"Runtime frame contract matches export: "+key)
		check(image.get_width()==int(data["frame_size"][0])*data["states"].size(),"Sprite-sheet dimensions: "+key)
		check(image.get_pixel(0,0).a==0.0,"Transparent sprite corners: "+key)
		var all_frames_clear := true
		var size := int(data["frame_size"][0])
		for frame in data["states"].size():
			for x in range(size):
				if image.get_pixel(frame*size+x,0).a>.01 or image.get_pixel(frame*size+x,size-1).a>.01: all_frames_clear=false
		check(all_frames_clear,"No top/bottom sprite clipping: "+key)
	var world := WorldVisual.new()
	var factory := MeshFactory.new()
	world.set("_mesh", factory); world.set("_mesh_mat", factory.mat)
	world.set("_in_interior", true)
	var container := Node2D.new(); add_child(container);world.set("_ent_container", container)
	var roots: Array[Node] = []
	for item in [["tree", "Oak Tree", "oak_tree", Color(.18,.55,.15)], ["building", "House", "timber_house", Color(.65,.52,.35)]]:
		var logic := Interactable.instantiate()
		logic.interactable_type_str=item[0];logic.display_name=item[1];logic.color=item[3];logic.entity_id="test:"+item[2]
		container.add_child(logic);logic.position=Vector2(320,640);logic.set_process(false)
		var visual := world._interactable_node(item[0],item[3],item[1],logic)
		add_child(visual);roots.append(visual)
		world._place(visual,logic.position)
		check(Art.available(item[2])==authored, "Paired availability: "+item[2])
		check(visual.has_meta("village_asset")==authored,"Exact route: "+item[2])
		check(logic.entity_id=="test:"+item[2] and logic.position==Vector2(320,640),"Logical identity preserved: "+item[2])
		check(visual.position.is_equal_approx(Vector3(10,0,20)),"World coordinate conversion: "+item[2])
		check(visual.find_children("*","CollisionObject3D",true,false).is_empty(),"Visual has no physics: "+item[2])
		var before: Rect2 = logic.get_node("CollisionShape2D").shape.get_rect()
		Art.enabled=false
		var baseline := Interactable.instantiate();baseline.interactable_type_str=item[0];baseline.display_name=item[1];container.add_child(baseline)
		check(before==baseline.get_node("CollisionShape2D").shape.get_rect(),"Original pick shape retained: "+item[2])
		Art.enabled=true;baseline.queue_free()
		if item[0]=="tree":
			logic._max_hp=100
			for idx in range(4):
				logic._hp=[100,70,40,20][idx]
				check(Art.state_frame("oak_tree",logic)==idx,"2D oak damage state "+str(idx))
				if authored:
					visual.refresh()
					var count:=0
					for i in range(4):
						if visual.find_child("Canopy"+str(i),true,false).visible: count+=1
					check(count==[4,3,1,0][idx],"3D oak canopy state "+str(idx))
			logic.apply_depleted(45)
			check(Art.state_frame("oak_tree",logic)==4,"2D depleted stump selected")
			if authored:
				visual.refresh();check(visual.find_child("Stump",true,false).visible and not visual.find_child("LiveTrunk",true,false).visible,"3D stump replaces trunk")
			logic.apply_respawn()
			if authored:
				visual.refresh();check(not visual.find_child("Stump",true,false).visible,"Respawn restores live oak")
		else:
			world._ensure_structure_collision(logic,"building")
			var bodies:=logic.find_children("*","StaticBody2D",true,false)
			check(bodies.size()==1,"Existing 3D house blocker retained")
			if not bodies.is_empty():
				check(bodies[0].get_child(0).shape.size==Vector2(84,84),"House 84x84 blocking footprint retained")
	for item in [["tree","Pine Tree"],["tree","Cherry Tree"],["building","Tavern"],["building","Town Building"],["building","Great Hall"],["rock","Copper Ore"]]:
		var visual:=world._interactable_node(item[0],Color(.4,.5,.3),item[1])
		check(not visual.has_meta("village_asset"),"Unrelated visual untouched: "+item[1]);visual.free()
	var npc:=Area2D.new();npc.set_script(NPC);npc.set("npc_type","worker");npc.set("npc_name_str","Karl");npc.set("entity_id","test:karl")
	container.add_child(npc);npc.set_process(false)
	var karl:=world._npc_node("worker","Kjelvik","Karl",npc);add_child(karl);roots.append(karl)
	check(karl.has_meta("village_asset")==authored,"Only Karl gets character prototype")
	for name_str in ["Sigrid","Hakon the Farmer"]:
		var other:=world._npc_node("worker","Kjelvik",name_str)
		check(not other.has_meta("village_asset"),"Other worker unchanged: "+name_str);other.free()
	npc.set("_idle_timer",5.0);npc.set("_iv_kind",0)
	check(Art.state_frame("karl",npc)==0,"Karl idle")
	for i in range(8):
		npc.set("_idle_timer",-1.0);npc.set("_time",float(i)/8.0)
		check(Art.state_frame("karl",npc)==i+1,"Karl walk frame "+str(i))
		if authored:
			karl.refresh()
			if i == 2:
				var leg := karl.find_child("LegL",true,false) as Node3D
				check(leg != null and absf(leg.rotation.x) > .1,"GLB walk pose actually moves the leg")
	if authored:
		var players:=karl.find_children("*","AnimationPlayer",true,false)
		check(players.size()==1,"Imported GLB animation exists")
		if not players.is_empty():
			check(players[0].get_animation_list().size()>0,"GLB pose timeline available")
		for move in [Vector2(1,0),Vector2(0,1),Vector2(-1,0),Vector2(0,-1)]:
			npc.position+=move;karl.refresh()
			check(is_equal_approx(karl.rotation.y,atan2(move.x,move.y)),"Karl cardinal facing "+str(move))
	npc.set("_idle_timer",5.0);npc.set("_iv_kind",1);npc.set("_iv_dir",-1.0)
	check(Art.state_frame("karl",npc)==9,"Karl head turn left")
	npc.set("_iv_dir",1.0);check(Art.state_frame("karl",npc)==10,"Karl head turn right")
	npc.set("_iv_kind",2);check(Art.state_frame("karl",npc)==11,"Karl crossed arms")
	npc.call("_on_npc_hit","test:karl",30,60);check(npc.get("current_hp")==30,"Original NPC hit handler")
	npc.call("_on_npc_died","test:karl");check(not npc.visible and not npc.input_pickable,"Original NPC death disables visual/picking")
	npc.call("_on_npc_respawned","test:karl");check(npc.visible and npc.input_pickable and npc.get("is_alive"),"Original NPC respawn restores visual/picking")
	for node in roots:node.queue_free()
	container.queue_free();world.free();factory.free()
	var mode:="authored" if authored else "fallback"
	var file:=FileAccess.open(OS.get_environment("VIKINGVALE_TEST_OUTPUT").path_join("checks_"+mode+".json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":results,"failures":failures},"\t"));file.close()
	print("VILLAGE_CHECKS: ",results.size()," checks, ",failures," failures")
	get_tree().quit(0 if failures==0 else 1)
