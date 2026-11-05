"""Blender 5.2: project-confined, versioned oak/house/Karl paired export.
Run --background --factory-startup --python-exit-code 1 --python THIS -- --asset KEY.
No downloads, scene colliders, gameplay edits, or overwrite of existing versions.
"""
import sys
sys.dont_write_bytecode = True
import argparse, json, math, hashlib, random
from pathlib import Path
import bpy
import numpy as np
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--asset', choices=['oak_tree', 'timber_house', 'karl'])
p.add_argument('--version', default='v001')
args = p.parse_args(sys.argv[sys.argv.index('--') + 1:])
assert args.version.startswith('v') and args.version[1:].isdigit()
key = args.asset
src = ROOT / f'art_source/blender/village/{key}/{args.version}'
out = ROOT / f'assets/authored/village/{key}/{args.version}'
pre = ROOT / f'art_source/previews/village/{key}/{args.version}'
for folder in (src, out, pre):
    assert folder.resolve().is_relative_to(ROOT)
    if folder.exists() and any(folder.iterdir()):
        raise FileExistsError(f'Existing version protected: {folder}')
for folder in (src, out, pre): folder.mkdir(parents=True, exist_ok=True)
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
bpy.context.preferences.filepaths.save_version = 0
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'; scene.unit_settings.scale_length = 1
rng = random.Random(271026)

# Shared palette atlas: wood grain, cloth weave and broad brush-like color
# variation. All parts share one material, including articulated NPC limbs.
palette = ['665044','382C24','526D42','84925A','B49159','74502E',
           '777C80','C99A73','784A2D','556A77','3B454D','C4B798',
           'A3AA80','CFAD6F','B47D43','262D36']
n=512; y,x=np.mgrid[0:n,0:n]; cu=(x%128)/128; cv=(y%128)/128
ci=x//128 + (y//128)*4
base=np.array([[int(c[i:i+2],16)/255 for i in (0,2,4)] for c in palette])
grain=.022*np.sin(cu*82+np.sin(cv*13)*1.1)+.025*np.sin(cu*19+cv*8)
brush=.035*np.sin(cu*7+cv*12)+.015*np.cos(cv*33+cu*14)
variation=np.where(np.isin(ci,[0,1,4,5,8,14]),grain,brush)
rgba=np.concatenate([np.clip(base[ci]+variation[...,None],0,1),np.ones((n,n,1))],axis=2).astype('float32')
tex=bpy.data.images.new('Village_Painted_Palette',width=n,height=n,alpha=True)
tex.pixels.foreach_set(rgba.ravel());tex.filepath_raw=str(out/f'{key}_basecolor.png');tex.file_format='PNG';tex.save()
mat=bpy.data.materials.new('Village_Painted_Matte');mat.use_nodes=True
bsdf=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED')
bsdf.inputs['Roughness'].default_value=.86
t=mat.node_tree.nodes.new('ShaderNodeTexImage');t.image=tex
mat.node_tree.links.new(t.outputs['Color'],bsdf.inputs['Base Color'])
parts=[]

def finish(ob,name,color,parent=None):
    ob.name=name;ob.data.materials.clear();ob.data.materials.append(mat)
    if not ob.data.uv_layers: ob.data.uv_layers.new()
    for uv in ob.data.uv_layers.active.data:
        uv.uv=((color%4+.06+float(uv.uv.x)*.88)/4,(color//4+.06+float(uv.uv.y)*.88)/4)
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    if parent: ob.parent=parent
    parts.append(ob);return ob

def box(name,loc,size,color,parent=None,bevel=.025):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);ob=bpy.context.object;ob.scale=size
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    if bevel:
        m=ob.modifiers.new('Worn corners','BEVEL');m.width=bevel;m.segments=2
        bpy.ops.object.modifier_apply(modifier=m.name)
    return finish(ob,name,color,parent)

def ball(name,loc,size,color,parent=None,rough=0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12,ring_count=7,radius=1,location=loc)
    ob=bpy.context.object
    for v in ob.data.vertices:
        v.co *= 1+rng.uniform(-rough,rough)
    ob.scale=size
    for face in ob.data.polygons:face.use_smooth=True
    return finish(ob,name,color,parent)

def beam(name,a,b,r,color,parent=None,r2=None):
    a,b=Vector(a),Vector(b);d=b-a
    bpy.ops.mesh.primitive_cone_add(vertices=10,radius1=r,radius2=r if r2 is None else r2,depth=d.length,location=(a+b)/2)
    ob=bpy.context.object;ob.rotation_euler=d.to_track_quat('Z','Y').to_euler()
    return finish(ob,name,color,parent)

def group(name,objects):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in objects:ob.select_set(True)
    bpy.context.view_layer.objects.active=objects[0];bpy.ops.object.join()
    ob=bpy.context.object;ob.name=name
    scene.cursor.location=(0,0,0);bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
    return ob

def empty(name,loc,parent=None):
    ob=bpy.data.objects.new(name,None);scene.collection.objects.link(ob);ob.location=loc;ob.parent=parent;return ob

states=[];animated=[]
if key=='oak_tree':
    beam('Crooked bole',(0,0,0),(.10,.04,1.55),.25,0,r2=.17)
    beam('Left fork',(.05,0,1.05),(-.72,.08,2.55),.15,0,r2=.055)
    beam('Right fork',(.05,0,1.25),(.65,.12,2.80),.14,0,r2=.055)
    beam('Back fork',(.1,0,1.5),(.05,.60,2.65),.12,0,r2=.04)
    for i in range(6):
        a=i*math.tau/6
        beam('Root',(.04,0,.25),(math.cos(a)*.56,math.sin(a)*.48,.035),.12,0,r2=.035)
    trunk=group('LiveTrunk',list(parts));parts=[trunk]
    canopies=[]
    clusters=[(-.72,.05,2.25,.78),(.60,.12,2.4,.83),(.0,.45,2.8,.88),(-.1,-.15,3.25,.78)]
    for i,(cx,cy,cz,r) in enumerate(clusters):
        start=len(parts)
        ball('Leaf mass',(cx,cy,cz),(r,r*.82,r*.72),2,rough=.13)
        for j in range(4):
            a=j*math.tau/4
            ball('Leaf lobe',(cx+math.cos(a)*r*.5,cy+math.sin(a)*r*.4,cz+.18),(r*.56,r*.5,r*.5),3 if j==2 else 2,rough=.12)
        ob=group('Canopy'+str(i),parts[start:]);parts=parts[:start]+[ob];canopies.append(ob)
    start=len(parts)
    beam('Cut stump',(0,0,0),(0,0,.38),.25,0,r2=.22)
    beam('Cut face',(0,0,.375),(0,0,.39),.215,11)
    for r in [.07,.13,.18]:
        bpy.ops.mesh.primitive_torus_add(major_segments=20,minor_segments=4,location=(0,0,.396),major_radius=r,minor_radius=.007)
        finish(bpy.context.object,'Growth ring',5)
    for i in range(5):
        a=i*math.tau/5;beam('Stump root',(0,0,.16),(math.cos(a)*.5,math.sin(a)*.45,.03),.08,0,r2=.02)
    stump=group('Stump',parts[start:]);parts=parts[:start]+[stump]
    states=['full','three_quarters','half','bare','stump']
    def pose(frame):
        trunk.hide_render=frame==4;stump.hide_render=frame!=4
        for i,ob in enumerate(canopies):ob.hide_render=i>=[4,3,1,0,0][frame]
    size=96;ortho=5.4;target=Vector((0,0,1.8));elev=45;anchor_ground=22
elif key=='timber_house':
    box('Stone footing',(0,0,.10),(2.4,2.2,.20),6)
    # Individual wall planks with subtle tone variation and rounded wear.
    for i in range(12):
        xx=-1.1+i*.2
        box('Front plank',(xx,-1.05,1.04),(.195,.12,1.68),0 if i%3 else 5)
        box('Back plank',(xx,1.05,1.04),(.195,.12,1.68),0)
    for sign in [-1,1]:
        for i in range(10):box('Side plank',(sign*1.14,-.94+i*.21,1.04),(.12,.2,1.68),0 if i%3 else 5)
        for yy in [-1.1,1.1]:box('Corner post',(sign*1.15,yy,1),(.18,.20,1.9),1)
        box('Eave beam',(sign*1.16,0,1.85),(.2,2.6,.19),1)
    box('Sill',(0,-1.14,.23),(2.4,.17,.16),1)
    box('Front lintel',(0,-1.14,1.82),(2.4,.16,.18),1)
    # Deep thatch courses; ridge runs along Y. Separate narrow strips read as straw.
    roof_angle=math.atan2(1.18,1.42)
    for sign in [-1,1]:
        ob=box('Thatch roof',(sign*.71,0,2.43),(1.85,2.65,.19),4,bevel=.07)
        ob.rotation_euler.y=sign*roof_angle
        for course in range(6):
            xx=sign*(.12+course*.235);zz=3.02-abs(xx)*1.18/1.42
            ob=box('Thatch course',(xx,0,zz+.10),(.13,2.67,.09),14 if course%3==0 else 4,bevel=.03);ob.rotation_euler.y=sign*roof_angle
        for yy in [-1.34,1.34]:
            beam('Gable bar',(sign*1.45,yy,1.84),(0,yy,3.12),.065,1)
    beam('Ridge',(0,-1.48,3.13),(0,1.48,3.13),.10,5)
    for yy in [-1.42,1.42]:
        beam('Carved ridge neck',(0,yy,3.12),(.09,yy*1.12,3.40),.055,5,r2=.04)
        ball('Carved beast head',(.09,yy*1.13,3.4),(.09,.12,.07),5)
    # Door is decorative; independent existing door entities still control entry.
    box('Door recess',(.25,-1.135,.77),(.72,.08,1.18),1)
    for i in range(5):box('Door plank',(.25-.27+i*.135,-1.19,.77),(.129,.055,1.1),5)
    for zz in [.43,1.10]:box('Iron strap',(.25,-1.23,zz),(.64,.035,.065),10,bevel=.01)
    ball('Door handle',(.45,-1.27,.78),(.028,.025,.04),13)
    box('Window surround',(-.66,-1.16,1.18),(.48,.13,.57),1)
    box('Amber window',(-.66,-1.235,1.18),(.35,.02,.43),13)
    box('Window mullion',(-.66,-1.25,1.18),(.045,.03,.44),1)
    box('Window crossbar',(-.66,-1.25,1.18),(.36,.03,.045),1)
    box('Chimney',(.73,.48,2.85),(.34,.40,.85),6)
    box('Chimney cap',(.73,.48,3.30),(.43,.48,.10),10)
    house=group('TimberHouse',list(parts));parts=[house]
    states=['default'];pose=lambda frame:None
    size=128;ortho=4.6;target=Vector((0,0,1.6));elev=35;anchor_ground=21
else:
    torso=empty('Body',(0,0,.72))
    head=empty('Head',(0,0,.67),torso)
    la=empty('ArmL',(-.27,0,.48),torso);ra=empty('ArmR',(.27,0,.48),torso)
    ll=empty('LegL',(-.12,0,0),torso);rl=empty('LegR',(.12,0,0),torso)
    ball('Wool tunic',(0,0,.25),(.30,.19,.37),9,torso)
    box('Tunic hem',(0,0,.02),(.49,.34,.16),9,torso,bevel=.06)
    box('Leather belt',(0,-.005,.10),(.51,.36,.065),1,torso)
    box('Buckle',(0,-.195,.10),(.09,.025,.075),13,torso,.01)
    ball('Pouch',(.24,-.10,.02),(.075,.07,.12),5,torso)
    for arm in [la,ra]:
        ball('Sleeve',(0,0,-.14),(.105,.115,.23),9,arm)
        beam('Cuff',(0,0,-.30),(0,0,-.36),.09,5,arm)
        ball('Hand',(0,-.015,-.405),(.085,.075,.105),7,arm)
    for leg in [ll,rl]:
        ball('Trousers',(0,0,-.20),(.115,.13,.27),10,leg)
        box('Boot',(0,-.045,-.52),(.20,.32,.32),1,leg,.065)
        beam('Boot cuff',(0,0,-.36),(0,0,-.40),.115,5,leg)
    ball('Face',(0,-.015,.10),(.205,.18,.235),7,head)
    ball('Hair cap',(0,.035,.23),(.218,.18,.15),8,head)
    for xx in [-.18,.18]:ball('Ear',(xx,-.005,.09),(.055,.042,.075),7,head)
    ball('Beard',(0,-.135,-.025),(.17,.09,.15),8,head)
    ball('Nose',(0,-.195,.08),(.048,.065,.061),7,head)
    for xx in [-.075,.075]:
        ball('Eye',(xx,-.179,.14),(.027,.018,.025),15,head)
        beam('Brow',(xx-.035,-.19,.183),(xx+.035,-.19,.187),.012,8,head)
    # Rigid articulated parts are editable and reusable; no gameplay skeleton.
    for joint in [torso,head,la,ra,ll,rl]:
        children=[ob for ob in parts if ob.parent==joint]
        if children:
            remaining=[ob for ob in parts if ob.parent!=joint]
            bpy.ops.object.select_all(action='DESELECT')
            for ob in children:ob.select_set(True)
            bpy.context.view_layer.objects.active=children[0];bpy.ops.object.join()
            merged=bpy.context.object;merged.name=joint.name+'_Mesh'
            parts=remaining+[merged]
    animated=[torso,head,la,ra,ll,rl]
    states=['idle']+[f'walk_{i}' for i in range(8)]+['look_left','look_right','arms_crossed']
    def pose(frame):
        for ob in animated:ob.rotation_euler=(0,0,0)
        torso.location.z=.72
        if 1<=frame<=8:
            phase=(frame-1)*math.tau/8;s=math.sin(phase)
            ll.rotation_euler.x=s*.55;rl.rotation_euler.x=-s*.55
            la.rotation_euler.x=-s*.4;ra.rotation_euler.x=s*.4
            torso.location.z+=abs(s)*.025
        elif frame in [9,10]:head.rotation_euler.z=.38 if frame==9 else -.38
        elif frame==11:
            la.rotation_euler=(.65,-.6,0);ra.rotation_euler=(.65,.6,0)
    scene.render.fps=8;scene.frame_start=0;scene.frame_end=11
    for frame in range(12):
        pose(frame)
        for ob in animated:
            ob.keyframe_insert(data_path='rotation_euler',frame=frame)
            ob.keyframe_insert(data_path='location',frame=frame)
    size=64;ortho=2.6;target=Vector((0,0,.85));elev=20;anchor_ground=14

asset_objects=list(parts)+animated
# Shared studio, excluded from GLB selection.
world=bpy.data.worlds.new('Village studio');scene.world=world;world.use_nodes=True
world.node_tree.nodes.get('Background').inputs[0].default_value=(.55,.63,.72,1)
world.node_tree.nodes.get('Background').inputs[1].default_value=.4
for name,loc,power,color in [('Warm key',(-3,-4,7),650,(1,.87,.72)),('Cool fill',(4,-1,5),320,(.72,.84,1))]:
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.color=color;data.shape='DISK';data.size=5
    ob=bpy.data.objects.new(name,data);scene.collection.objects.link(ob);ob.location=loc;ob.rotation_euler=(target-ob.location).to_track_quat('-Z','Y').to_euler()
cam=bpy.data.objects.new('Sprite camera',bpy.data.cameras.new('Orthographic'));scene.collection.objects.link(cam)
angle=math.radians(elev);cam.location=target+Vector((0,-8*math.cos(angle),8*math.sin(angle)))
cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=ortho;scene.camera=cam
scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.samples=24;scene.cycles.use_denoising=True
scene.render.film_transparent=True;scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
scene.view_settings.view_transform='Standard';scene.view_settings.look='None'
scene.render.resolution_percentage=100;scene.render.resolution_x=scene.render.resolution_y=size*3
pose(0);scene.frame_set(0);bpy.context.view_layer.update()
for ob in parts:ob.hide_render=False
bpy.ops.object.select_all(action='DESELECT')
for ob in asset_objects:ob.select_set(True)
export_args=dict(filepath=str(out/f'{key}.glb'),export_format='GLB',use_selection=True,export_cameras=False,export_lights=False,export_yup=True,export_animations=bool(animated))
if animated:export_args.update(export_animation_mode='SCENE',export_frame_range=True,export_force_sampling=True)
bpy.ops.export_scene.gltf(**export_args)
tex.pack();pose(0);bpy.ops.wm.save_as_mainfile(filepath=str(src/f'{key}.blend'))
frames=[]
for frame in range(len(states)):
    scene.frame_set(frame);pose(frame);bpy.context.view_layer.update()
    scene.render.filepath=str(pre/f'{key}_{frame:02d}_3x.png');bpy.ops.render.render(write_still=True)
    im=bpy.data.images.load(scene.render.filepath,check_existing=False)
    pix=np.array(im.pixels[:],dtype=np.float32).reshape(size*3,size*3,4)
    pix[:,:,:3]*=pix[:,:,3:4]
    small=pix.reshape(size,3,size,3,4).mean(axis=(1,3));small[:,:,:3]/=np.maximum(small[:,:,3:4],1e-8)
    frames.append(small)
    bpy.data.images.remove(im)
sheet=np.concatenate(frames,axis=1)
im=bpy.data.images.new(key+'_sheet',width=size*len(frames),height=size,alpha=True);im.pixels.foreach_set(sheet.ravel())
im.filepath_raw=str(out/f'{key}.png');im.file_format='PNG';im.save()
scene.frame_set(0);pose(0);bpy.context.view_layer.update()
projected=world_to_camera_view(scene,cam,Vector((0,0,0)))
offset=[-round(projected.x*size),anchor_ground-round((1-projected.y)*size)]
scene.render.resolution_x=scene.render.resolution_y=512;scene.render.filepath=str(pre/f'{key}_preview.png');bpy.ops.render.render(write_still=True)
triangles=sum(sum(len(face.vertices)-2 for face in ob.data.polygons) for ob in parts)
metadata={'asset':key,'version':args.version,'blender':bpy.app.version_string,'triangles_all_states':triangles,'materials':1,'frame_size':[size,size],'states':states,'draw_offset':offset,'source_forward_blender':'-Y','godot_forward':'+Z','animation_fps':8 if animated else 0,'animation':'Scene timeline, one pose per frame' if animated else None,'camera_elevation':elev,'orthographic_scale':ortho,'scale':'1 Blender unit = 1 Godot unit = 32 world pixels; preserve existing 2D art envelope separately','generator_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'sha256':{q.name:hashlib.sha256(q.read_bytes()).hexdigest() for q in [src/f'{key}.blend',out/f'{key}.glb',out/f'{key}.png',out/f'{key}_basecolor.png']}}
(out/f'{key}.frames.json').write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf-8')
print('VILLAGE_EXPORT_OK',json.dumps(metadata))
