"""Generate data-only Godot review scenes. No new GDScript or runtime adapter."""
from pathlib import Path
import json,math,sys
root=Path(__file__).resolve().parents[2];v=sys.argv[1]
dest=root/f'art_source/review_scenes/karl/{v}';dest.mkdir(parents=True,exist_ok=True)
base=f'res://assets/authored/characters/karl/{v}'
meta=json.loads((root/f'assets/authored/characters/karl/{v}/karl.sprites.json').read_text())
def norm(a):
 n=math.sqrt(sum(x*x for x in a));return [x/n for x in a]
def cross(a,b):return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def transform(pos,target):
 z=norm([a-b for a,b in zip(pos,target)]);x=norm(cross([0,1,0],z));y=cross(z,x)
 return 'Transform3D('+', '.join(str(round(q,6)) for q in x+y+z+list(pos))+')'
def label(name,text,x,y,size=20):return f'\n[node name="{name}" type="Label" parent="UI"]\noffset_left = {x}.0\noffset_top = {y}.0\ntheme_override_font_sizes/font_size = {size}\ntext = "{text}"\n'
for clip in meta['clips']:
 frames=meta['clips'][clip]['frames_per_direction'];duration=meta['clips'][clip]['duration']
 cell=meta['clips'][clip].get('cell_size',meta['cell_size'])[0]
 cell_h=meta['clips'][clip].get('cell_size',meta['cell_size'])[1]
 offset=meta['clips'][clip].get('draw_offset',meta['draw_offset'])
 sheet=meta['clips'][clip]['file']
 display_scale=meta['clips'][clip].get('display_scale',1.0)
 s=f'''[gd_scene load_steps={12+frames} format=3]
[ext_resource type="PackedScene" path="{base}/karl.glb" id="1"]
[ext_resource type="PackedScene" path="res://assets/authored/village/karl/v002/karl.glb" id="2"]
[ext_resource type="Script" path="res://scripts/NPC.gd" id="3"]
[ext_resource type="Texture2D" path="{base}/{sheet}" id="4"]
[sub_resource type="Environment" id="Env"]
background_mode = 1
background_color = Color(0.10, 0.13, 0.16, 1)
ambient_light_source = 2
ambient_light_color = Color(0.55, 0.60, 0.68, 1)
ambient_light_energy = 0.6
[sub_resource type="StandardMaterial3D" id="GroundMat"]
albedo_color = Color(0.20, 0.24, 0.19, 1)
roughness = 1.0
[sub_resource type="PlaneMesh" id="Ground"]
material = SubResource("GroundMat")
size = Vector2(8, 5)
'''
 for i in range(frames):s+=f'\n[sub_resource type="AtlasTexture" id="Frame{i}"]\natlas = ExtResource("4")\nregion = Rect2({i*cell}, 0, {cell}, {cell_h})\n'
 frame_defs=', '.join('{"duration": 1.0, "texture": SubResource("Frame'+str(i)+'")}' for i in range(frames))
 s+=f'''\n[sub_resource type="SpriteFrames" id="Frames"]
animations = [{{"frames": [{frame_defs}], "loop": true, "name": &"review", "speed": {frames/duration}}}]
[node name="KarlAssetReview" type="Node3D"]
[node name="Environment" type="WorldEnvironment" parent="."]
environment = SubResource("Env")
[node name="Sun" type="DirectionalLight3D" parent="."]
rotation = Vector3(-0.907571, -0.698132, 0)
light_energy = 1.15
shadow_enabled = true
[node name="Ground" type="MeshInstance3D" parent="."]
mesh = SubResource("Ground")
[node name="OldKarl" parent="." instance=ExtResource("2")]
position = Vector3(-1.8, 0, 0)
[node name="NewKarl" parent="." instance=ExtResource("1")]
position = Vector3(1.8, 0, 0)
[node name="AnimationPlayer" parent="NewKarl" index="1"]
autoplay = "{clip}"
[node name="Camera" type="Camera3D" parent="."]
position = Vector3(0,0.4,6)
rotation = Vector3(0,0,0)
projection = 1
size = 4.5
current = true
[node name="UI" type="CanvasLayer" parent="."]
[node name="Panel" type="ColorRect" parent="UI"]
offset_top = 510.0
offset_right = 1280.0
offset_bottom = 800.0
color = Color(0.07,0.08,0.10,1)
[node name="Original2D" type="Area2D" parent="UI"]
position = Vector2(340,650)
scale = Vector2(2.5,2.5)
process_mode = 4
script = ExtResource("3")
npc_type = "worker"
npc_name_str = "Karl"
region = "kjelvik"
[node name="New2D" type="AnimatedSprite2D" parent="UI"]
position = Vector2(850,650)
scale = Vector2({2.5*display_scale},{2.5*display_scale})
texture_filter = 1
sprite_frames = SubResource("Frames")
animation = &"review"
autoplay = "review"
centered = false
offset = Vector2({offset[0]},{offset[1]})
'''
 s+=label('Title',f'Karl / {v} / {clip} / asset review only',28,18,26)
 s+=label('Old3DLabel','Rigid v002 prototype',260,72)+label('New3DLabel','Skinned candidate / game light settings',700,72)
 s+=label('Old2DLabel','Original procedural Karl / Kjelvik',180,530)+label('New2DLabel','New sheet / 2.5x gameplay zoom',690,530)
 s+=label('Footer','No new runtime code. Existing NPC drawing is read-only. Visual approval pending.',28,697,18)
 (dest/f'review_{clip}.tscn').write_text(s,encoding='utf-8')
s=f'''[gd_scene load_steps=7 format=3]
[ext_resource type="PackedScene" path="{base}/karl.glb" id="1"]
[ext_resource type="PackedScene" path="res://assets/authored/village/oak_tree/v002/oak_tree.glb" id="2"]
[ext_resource type="PackedScene" path="res://assets/authored/village/timber_house/v002/timber_house.glb" id="3"]
[sub_resource type="Environment" id="Env"]
background_mode = 1
background_color = Color(0.53,0.68,0.83,1)
ambient_light_source = 2
ambient_light_color = Color(0.55,0.60,0.68,1)
ambient_light_energy = 0.6
[sub_resource type="StandardMaterial3D" id="Grass"]
albedo_color = Color(0.22,0.29,0.15,1)
roughness = 1.0
[sub_resource type="PlaneMesh" id="Plane"]
size = Vector2(18,18)
material = SubResource("Grass")
[node name="VillageStaging" type="Node3D"]
[node name="Environment" type="WorldEnvironment" parent="."]
environment = SubResource("Env")
[node name="Sun" type="DirectionalLight3D" parent="."]
rotation = Vector3(-0.907571,-0.698132,0)
light_energy = 1.15
shadow_enabled = true
[node name="Ground" type="MeshInstance3D" parent="."]
mesh = SubResource("Plane")
[node name="House" parent="." instance=ExtResource("3")]
position = Vector3(1.7,0,-1.7)
[node name="Oak" parent="." instance=ExtResource("2")]
position = Vector3(-2.6,0,-1.5)
[node name="Stump" parent="Oak" index="5"]
visible = false
[node name="Karl" parent="." instance=ExtResource("1")]
position = Vector3(0,0,1)
[node name="AnimationPlayer" parent="Karl" index="1"]
autoplay = "idle"
[node name="Camera" type="Camera3D" parent="."]
position = Vector3(0,{1.5+math.sin(.82)*24},{math.cos(.82)*24})
rotation = Vector3(-0.82,0,0)
current = true
[node name="UI" type="CanvasLayer" parent="."]
'''+label('Title','Village staging / original 3D camera distance and lighting / no gameplay',24,20,22)
(dest/'village_3d.tscn').write_text(s,encoding='utf-8')
s=f'''[gd_scene load_steps=7 format=3]
[ext_resource type="Texture2D" path="{base}/{meta['clips']['idle']['file']}" id="1"]
[ext_resource type="Texture2D" path="res://assets/authored/village/oak_tree/v002/oak_tree.png" id="2"]
[ext_resource type="Texture2D" path="res://assets/authored/village/timber_house/v002/timber_house.png" id="3"]
[sub_resource type="AtlasTexture" id="KarlFrame"]
atlas = ExtResource("1")
region = Rect2(0,0,{meta['cell_size'][0]},{meta['cell_size'][1]})
[sub_resource type="AtlasTexture" id="OakFrame"]
atlas = ExtResource("2")
region = Rect2(0,0,96,96)
[sub_resource type="AtlasTexture" id="HouseFrame"]
atlas = ExtResource("3")
region = Rect2(0,0,128,128)
[node name="Village2DStaging" type="Node2D"]
[node name="Ground" type="ColorRect" parent="."]
offset_right = 1280.0
offset_bottom = 720.0
color = Color(0.24,0.32,0.18,1)
[node name="World" type="Node2D" parent="."]
position = Vector2(640,420)
scale = Vector2(2.5,2.5)
texture_filter = 1
y_sort_enabled = true
[node name="House" type="Sprite2D" parent="World"]
position = Vector2(54.4,-54.4)
texture = SubResource("HouseFrame")
centered = false
offset = Vector2(-64,-75)
[node name="Oak" type="Sprite2D" parent="World"]
position = Vector2(-83.2,-48)
texture = SubResource("OakFrame")
centered = false
offset = Vector2(-48,-49)
[node name="Karl" type="Sprite2D" parent="World"]
position = Vector2(0,32)
scale = Vector2({meta.get('display_scale',1.0)},{meta.get('display_scale',1.0)})
texture = SubResource("KarlFrame")
centered = false
offset = Vector2({meta['draw_offset'][0]},{meta['draw_offset'][1]})
[node name="UI" type="CanvasLayer" parent="."]
'''+label('Title','Village staging / matching positions / 2D zoom 2.5 / existing oak and house',24,20,22)
(dest/'village_2d.tscn').write_text(s,encoding='utf-8')
print('Created data-only review scenes:',dest)
