"""Karl v010 sprite-only refinement. Blender authors/renders assets; no game edits."""
from pathlib import Path
import sys,json,math,shutil,colorsys
import bpy,numpy as np
from mathutils import Vector
root=next(p for p in Path(__file__).resolve().parents if (p/'project.godot').exists())
full='--full' in sys.argv
src=root/'art_source/blender/characters/karl/v010';out=root/'assets/authored/characters/karl/v010';pre=root/'art_source/previews/characters/karl/v010'
if full:assert not any(out.glob('karl_*_crisp.png')),'Select a fresh version; existing sprite exports are protected'
for p in [src,out,pre]:p.mkdir(parents=True,exist_ok=True)
old=root/'assets/authored/characters/karl/v009'
for name in ['karl.glb','karl_basecolor.png','karl_normal.png','karl_orm.png']:
 if not (out/name).exists():shutil.copy2(old/name,out/name)
if not (src/'karl.blend').exists():shutil.copy2(root/'art_source/blender/characters/karl/v009/karl.blend',src/'karl.blend')
bpy.ops.wm.open_mainfile(filepath=str(root/'art_source/blender/characters/karl/v009/karl_sprite_studio_readable.blend'))
bpy.context.preferences.filepaths.save_version=0
scene=bpy.context.scene;rig=bpy.data.objects['Karl_Rig'];obj=bpy.data.objects['Karl_SkinnedMesh'];mesh=obj.data;cam=scene.camera
# Exact original NPC.gd palette; remove warm studio illumination from 2D colors.
h=2089278383;shift=((h>>7)&255)/255*.20-.10
hh,ss,vv=colorsys.rgb_to_hsv(.60,.45,.30);body=colorsys.hsv_to_rgb((hh+shift*.1)%1,ss*.95,vv*(.92+shift*.1))
blue=(.20,.34,.62);gold=(.82,.66,.20);skin=(.58,.42,.28);hair=(.55,.35,.15)
colors=[body,blue,tuple(c*.8 for c in body),skin,hair,gold,(.95,.92,.82),(.035,.025,.02),(.48,.30,.10),tuple(c*.8 for c in body),tuple(c*.8 for c in body),body,body,tuple(c*.55 for c in hair),tuple(c*.85 for c in hair),gold]
n=256;y,x=np.mgrid[0:n,0:n];tile=x//64+(y//64)*4;rgba=np.ones((n,n,4),dtype='float32');rgba[:,:,:3]=np.array(colors)[tile]
im=bpy.data.images.new('Karl_original_2D_palette',width=n,height=n,alpha=True);im.pixels.foreach_set(rgba.ravel());im.filepath_raw=str(out/'karl_sprite_palette.png');im.file_format='PNG';im.save();im.pack()
mat=bpy.data.materials.new('Karl_2D_original_colors');mat.use_nodes=True;nodes=mat.node_tree.nodes;nodes.clear();links=mat.node_tree.links
tex=nodes.new('ShaderNodeTexImage');tex.image=im;tex.interpolation='Closest'
facing=nodes.new('ShaderNodeLayerWeight');shade=nodes.new('ShaderNodeMath');shade.operation='MULTIPLY_ADD';shade.inputs[1].default_value=-.18;shade.inputs[2].default_value=1
links.new(facing.outputs['Facing'],shade.inputs[0])
mul=nodes.new('ShaderNodeMixRGB');mul.blend_type='MULTIPLY';mul.inputs[0].default_value=1;links.new(tex.outputs['Color'],mul.inputs[1]);links.new(shade.outputs[0],mul.inputs[2])
em=nodes.new('ShaderNodeEmission');links.new(mul.outputs[0],em.inputs['Color']);dest=nodes.new('ShaderNodeOutputMaterial');links.new(em.outputs[0],dest.inputs['Surface']);mesh.materials.clear();mesh.materials.append(mat)
parts=json.loads(obj['authored_part_ranges']);uv=mesh.uv_layers.active.data
# Restore the prominent blue cap top and gold waist band from the original.
for poly in mesh.polygons:
 ids=set(poly.vertices)
 for name,newtile in [('Worker wool cap',1),('Leather belt',5)]:
  a,b=parts[name]
  if all(a<=i<b for i in ids) and (name!='Worker wool cap' or poly.center.z>1.775):
   for li in poly.loop_indices:
    olduv=uv[li].uv.copy();uv[li].uv=((newtile%4+(olduv.x*4)%1)/4,(newtile//4+(olduv.y*4)%1)/4)
# Face marks get their original dark accents and sit clearly above the face.
for name,(a,b) in parts.items():
 if name.startswith(('Mouth','Moustache','Brow')):
  for vertex in list(mesh.vertices)[a:b]:vertex.co.y-=.018
  if name.startswith(('Mouth','Brow')):
   for poly in mesh.polygons:
    if all(a<=i<b for i in poly.vertices):
     for li in poly.loop_indices:
      q=uv[li].uv.copy();uv[li].uv=((1+(q.x*4)%1)/4,(3+(q.y*4)%1)/4)
# Enlarge the emblem only in the compact sprite studio.
for name,(a,b) in parts.items():
 if name.startswith('Knotwork badge'):
  for vertex in list(mesh.vertices)[a:b]:
   vertex.co.x*=3;vertex.co.z=1.29+(vertex.co.z-1.29)*2.5;vertex.co.y-=.008
mesh.update()
scene.render.engine='CYCLES';scene.cycles.samples=16;scene.cycles.use_denoising=False
scene.view_settings.view_transform='Standard';scene.view_settings.look='None';scene.view_settings.exposure=0;scene.render.film_transparent=True
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.image_settings.color_depth='8'
scene.render.filter_size=.5
clips={'idle':(60,True),'walk':(30,True),'look_left':(36,False),'look_right':(36,False),'arms_crossed':(48,False),'hit':(9,False),'death':(45,False)}
meta=json.loads((old/'karl.sprites.json').read_text());meta.update(version='v010',cell_size=[256,256],pivot=[128,208],draw_offset=[-128,-152],display_scale=.25)
meta['presentation'].update(method='4x resolution native render; no downsampling or denoising; original NPC palette with restrained facing shading',palette_source='scripts/NPC.gd: Karl hash 2089278383, worker, kjelvik',palette={'skin':skin,'hair':hair,'tunic':body,'blue':blue,'gold':gold},head_scale=1.8)
meta['clips']={}
def camera(angle):
 a=math.radians(angle);e=math.radians(12);target=Vector((0,0,.94));cam.location=target+Vector((math.sin(a)*math.cos(e),-math.cos(a)*math.cos(e),math.sin(e)))*6;cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
camera(0);cam.data.ortho_scale=2.9;rig.animation_data.action=bpy.data.actions['idle'];scene.frame_set(0)
scene.render.resolution_x=scene.render.resolution_y=256
bpy.ops.wm.save_as_mainfile(filepath=str(src/'karl_sprite_studio_crisp.blend'))
if not full:
 scene.render.filepath=str(pre/'idle_crisp.png');bpy.ops.render.render(write_still=True)
else:
 for clip,(frames,loop) in clips.items():
  size=512 if clip=='death' else 256;cam.data.ortho_scale=5.8 if clip=='death' else 2.9;scene.render.resolution_x=scene.render.resolution_y=size
  count=max(4,math.ceil(frames/30*12));rows=[];rig.animation_data.action=bpy.data.actions[clip]
  for angle in [0,90,180,270]:
   camera(angle);cells=[]
   for frame in np.linspace(0,frames,count,endpoint=not loop):
    scene.frame_set(int(frame),subframe=float(frame%1));scene.render.filepath=str(pre/'render_work.png');bpy.ops.render.render(write_still=True)
    temp=bpy.data.images.load(scene.render.filepath,check_existing=False);cells.append(np.array(temp.pixels[:],dtype='float32').reshape(size,size,4));bpy.data.images.remove(temp)
   rows.append(np.concatenate(cells,axis=1))
  pixels=np.concatenate(rows[::-1],axis=0);image=bpy.data.images.new('Sheet_'+clip,width=size*count,height=size*4,alpha=True);image.pixels.foreach_set(pixels.ravel());image.filepath_raw=str(out/f'karl_{clip}_crisp.png');image.file_format='PNG';image.save();bpy.data.images.remove(image)
  meta['clips'][clip]={'file':f'karl_{clip}_crisp.png','frames_per_direction':count,'duration':frames/30,'loop':loop,'cell_size':[size,size],'pivot':[256,336] if clip=='death' else [128,208],'draw_offset':[-256,-280] if clip=='death' else [-128,-152],'display_scale':.25,'direction_rows':{'front':0,'left':1,'back':2,'right':3}}
 (out/'karl.sprites.json').write_text(json.dumps(meta,indent=2)+'\n')
 (src/'sprite_authoring.py').write_bytes(Path(__file__).read_bytes())
 print('CRISP_SHEETS_DONE')
