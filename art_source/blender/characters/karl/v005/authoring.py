"""Asset authoring only. Lofted deforming surfaces, armature, UVs and clips.
Blender 5.2, no game-code edits. Existing version directories are protected.
--version v003 --stage build|sheets (sheets opens the saved master).
"""
import sys
sys.dont_write_bytecode=True
import argparse, math, json, hashlib
from pathlib import Path
import bpy
import numpy as np
from mathutils import Vector, Matrix, Euler
from bpy_extras.object_utils import world_to_camera_view

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'project.godot').exists())
ap=argparse.ArgumentParser();ap.add_argument('--version',default='v003');ap.add_argument('--stage',default='build',choices=['build','sheets'])
args=ap.parse_args(sys.argv[sys.argv.index('--')+1:]);ver=args.version
assert ver.startswith('v') and ver[1:].isdigit()
SRC=ROOT/f'art_source/blender/characters/karl/{ver}'
OUT=ROOT/f'assets/authored/characters/karl/{ver}'
PRE=ROOT/f'art_source/previews/characters/karl/{ver}'
if args.stage=='build':
    assert not any(p.exists() and any(p.iterdir()) for p in [SRC,OUT,PRE]),'Select unused version; originals protected'
for p in [SRC,OUT,PRE]:p.mkdir(parents=True,exist_ok=True)
CLIPS={'idle':(60,True),'walk':(30,True),'look_left':(36,False),'look_right':(36,False),'arms_crossed':(48,False),'hit':(9,False),'death':(45,False)}

def save_rgba(name,array,path,noncolor=False):
    h,w=array.shape[:2];im=bpy.data.images.new(name,width=w,height=h,alpha=True)
    if noncolor:im.colorspace_settings.name='Non-Color'
    im.pixels.foreach_set(array.astype('float32').ravel());im.filepath_raw=str(path);im.file_format='PNG';im.save();im.pack();return im

def camera_at(cam,target,azimuth=0,elevation=15,distance=6):
    a,e=math.radians(azimuth),math.radians(elevation)
    cam.location=Vector(target)+Vector((math.sin(a)*math.cos(e),-math.cos(a)*math.cos(e),math.sin(e)))*distance
    cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler()

if args.stage=='build':
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
    bpy.context.preferences.filepaths.save_version=0
    scene=bpy.context.scene;scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=1
    scene.render.fps=30
    # Shared, UV-mapped textile/leather/skin palette. Normal + packed ORM textures.
    palette=['78604A','334F78','3D3026','946B47','513823','D1AB57','D2BFA0','25272A',
             'A17C53','604E40','695B4D','8D704D','7B604A','3C3832','8C6B52','BDA66F']
    n=1024;y,x=np.mgrid[0:n,0:n];u=(x%256+.5)/256;v=(y%256+.5)/256;tile=x//256+(y//256)*4
    cols=np.array([[int(c[i:i+2],16)/255 for i in (0,2,4)] for c in palette])
    textile=np.isin(tile,[0,1,6,8,11]);leather=np.isin(tile,[2,9,10]);skin=tile==3
    broad=.025*np.sin(u*13+v*7)+.012*np.sin(u*33-v*17)
    weave=.012*(np.cos(u*math.tau*45)*np.cos(v*math.tau*39))
    pores=np.random.default_rng(2703).normal(0,.006,(n,n))
    variation=broad+np.where(textile,weave,pores)
    # Cloth edges have a subtle stitched border; metallic palette tile is brass.
    stitch=np.where(textile & (u<.025),.035*(np.cos(v*math.tau*24)>.2),0)
    rgb=np.clip(cols[tile]+(variation+stitch)[...,None],0,1)
    # Image pixels are scene-linear; palette entries above are authored sRGB.
    linear=np.where(rgb<=.04045,rgb/12.92,((rgb+.055)/1.055)**2.4)
    base=save_rgba('Karl_Textiles_Leather_Skin_1024',np.dstack([linear,np.ones((n,n))]),OUT/'karl_basecolor.png')
    rough=np.where(tile==5,.38,np.where(leather,.69,np.where(skin,.74,.9)))
    orm=save_rgba('Karl_ORM',np.dstack([np.ones((n,n)),rough,(tile==5)*.72,np.ones((n,n))]),OUT/'karl_orm.png',True)
    height=np.where(textile,weave*.25,pores*.15)
    gy,gx=np.gradient(height);norm=np.dstack([-gx*10,-gy*10,np.ones((n,n))]);norm/=np.linalg.norm(norm,axis=2)[...,None]
    normal=save_rgba('Karl_Surface_Normal',np.dstack([norm*.5+.5,np.ones((n,n))]),OUT/'karl_normal.png',True)
    mat=bpy.data.materials.new('Karl_Woven_Cloth_Worn_Leather');mat.use_nodes=True
    nodes=mat.node_tree.nodes;links=mat.node_tree.links;bs=next(q for q in nodes if q.type=='BSDF_PRINCIPLED')
    for im,kind in [(base,'base'),(orm,'orm'),(normal,'normal')]:
        t=nodes.new('ShaderNodeTexImage');t.image=im
        if kind=='base':links.new(t.outputs['Color'],bs.inputs['Base Color'])
        elif kind=='orm':
            split=nodes.new('ShaderNodeSeparateColor');links.new(t.outputs['Color'],split.inputs['Color']);links.new(split.outputs['Green'],bs.inputs['Roughness']);links.new(split.outputs['Blue'],bs.inputs['Metallic'])
        else:
            nm=nodes.new('ShaderNodeNormalMap');nm.inputs['Strength'].default_value=.28;links.new(t.outputs['Color'],nm.inputs['Color']);links.new(nm.outputs['Normal'],bs.inputs['Normal'])

    # Explicit anatomical guide skeleton; a Karl benchmark, not yet a universal rig.
    bones={
      'Root':((0,0,0),(0,0,.15),None),
      'Hips':((0,0,.91),(0,0,1.04),'Root'),
      'Spine':((0,0,1.04),(0,0,1.25),'Hips'),
      'Chest':((0,0,1.25),(0,0,1.43),'Spine'),
      'Neck':((0,0,1.43),(0,0,1.54),'Chest'),
      'Head':((0,0,1.54),(0,0,1.80),'Neck'),
    }
    for side,sg in [('L',-1),('R',1)]:
        bones.update({
          f'Clavicle.{side}':((sg*.045,0,1.43),(sg*.245,0,1.43),'Chest'),
          f'UpperArm.{side}':((sg*.245,0,1.43),(sg*.44,-.01,1.16),f'Clavicle.{side}'),
          f'Forearm.{side}':((sg*.44,-.01,1.16),(sg*.54,-.025,.91),f'UpperArm.{side}'),
          f'Hand.{side}':((sg*.54,-.025,.91),(sg*.58,-.035,.79),f'Forearm.{side}'),
          f'Thigh.{side}':((sg*.105,0,.91),(sg*.115,-.018,.51),'Hips'),
          f'Shin.{side}':((sg*.115,-.018,.51),(sg*.115,0,.12),f'Thigh.{side}'),
          f'Foot.{side}':((sg*.115,0,.12),(sg*.115,-.17,.07),f'Shin.{side}'),
          f'Toe.{side}':((sg*.115,-.17,.07),(sg*.115,-.235,.07),f'Foot.{side}'),
        })
        # Separate finger roots for attachment/posing. Two joints for each digit.
        for finger in range(4):
            yy=-.065+finger*.026
            a=(sg*.579,yy,.81);b=(sg*.596,yy,.756);c=(sg*.603,yy,.715+abs(finger-1)*.008)
            bones[f'Finger{finger+1}A.{side}']=(a,b,f'Hand.{side}')
            bones[f'Finger{finger+1}B.{side}']=(b,c,f'Finger{finger+1}A.{side}')
        bones[f'ThumbA.{side}']=((sg*.535,-.07,.86),(sg*.515,-.105,.81),f'Hand.{side}')
        bones[f'ThumbB.{side}']=((sg*.515,-.105,.81),(sg*.52,-.11,.77),f'ThumbA.{side}')
    for name,point,parent in [('Socket.Hand.L',(-.58,-.035,.80),'Hand.L'),('Socket.Hand.R',(.58,-.035,.80),'Hand.R'),('Socket.Back',(0,.16,1.30),'Chest'),('Socket.Head',(0,0,1.81),'Head')]:
        bones[name]=(point,tuple(Vector(point)+Vector((0,0,.06))),parent)
    arm=bpy.data.armatures.new('Karl_Armature');rig=bpy.data.objects.new('Karl_Rig',arm);scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active=rig;rig.select_set(True);bpy.ops.object.mode_set(mode='EDIT')
    for name,(head,tail,parent) in bones.items():
        eb=arm.edit_bones.new(name);eb.head=head;eb.tail=tail
        if parent:eb.parent=arm.edit_bones[parent]
        eb.align_roll(Vector((0,-1,0)));eb.use_deform=not name.startswith('Socket') and name!='Root'
    bpy.ops.object.mode_set(mode='OBJECT');rig.show_in_front=True
    verts=[];faces=[];uvfaces=[];weights=[];part_ranges={}

    def smooth(t):return max(0,min(1,t))**2*(3-2*max(0,min(1,t)))
    def blend(a,b,t):
        t=smooth(t);return {a:1-t,b:t} if a!=b else {a:1.0}
    def body_weights(p):
        z=p[2]
        if z<1.13:return blend('Hips','Spine',(z-.97)/.18)
        if z<1.39:return blend('Spine','Chest',(z-1.18)/.18)
        return blend('Chest','Neck',(z-1.43)/.11)
    def leg_weights(p,side):
        z=p[2]
        if z<.24:return blend('Foot.'+side,'Shin.'+side,(z-.12)/.12)
        if z<.63:return blend('Shin.'+side,'Thigh.'+side,(z-.43)/.16)
        return blend('Thigh.'+side,'Hips',(z-.88)/.13)
    def arm_weights(p,side):
        z=p[2]
        if z<1.0:return blend('Hand.'+side,'Forearm.'+side,(z-.87)/.13)
        if z<1.27:return blend('Forearm.'+side,'UpperArm.'+side,(z-1.10)/.13)
        return blend('UpperArm.'+side,'Chest',(z-1.37)/.15)
    def addface(ids,uv,col):
        faces.append(ids);uvfaces.append([((col%4+.03+u*.94)/4,(col//4+.03+v*.94)/4) for u,v in uv])
    def surface(name,rings,segments,col,wfun,sculpt=None,caps=True):
        """Loft explicit elliptical cross-sections; quad joint loops, UV seam."""
        start=len(verts)
        for j,(cx,cy,z,rx,ry) in enumerate(rings):
            for i in range(segments+1):
                a=i*math.tau/segments;p=Vector((cx+rx*math.sin(a),cy-ry*math.cos(a),z))
                if sculpt:p=sculpt(p,a,j)
                verts.append(tuple(p));weights.append(wfun(p))
        for j in range(len(rings)-1):
            for i in range(segments):
                k=start+j*(segments+1)+i
                addface([k,k+1,k+segments+2,k+segments+1],[(i/segments,j/(len(rings)-1)),((i+1)/segments,j/(len(rings)-1)),((i+1)/segments,(j+1)/(len(rings)-1)),(i/segments,(j+1)/(len(rings)-1))],col)
        if caps:
            for j,reverse in [(0,True),(len(rings)-1,False)]:
                ids=[start+j*(segments+1)+i for i in range(segments)]
                if reverse:ids.reverse()
                addface(ids,[(.5+.45*math.sin(i*math.tau/segments),.5+.45*math.cos(i*math.tau/segments)) for i in range(segments)],col)
        part_ranges[name]=[start,len(verts)]
    def tube(name,points,radii,col,wfun,segments=10):
        start=len(verts)
        for j,point in enumerate(points):
            p=Vector(point);axis=Vector(points[min(j+1,len(points)-1)])-Vector(points[max(j-1,0)])
            axis.normalize();v=axis.cross(Vector((0,1,0)))
            if v.length<.01:v=axis.cross(Vector((1,0,0)))
            v.normalize();w=axis.cross(v).normalized()
            for i in range(segments+1):
                a=i*math.tau/segments;q=p+radii[j]*(v*math.cos(a)+w*math.sin(a));verts.append(tuple(q));weights.append(wfun(q))
        for j in range(len(points)-1):
            for i in range(segments):
                k=start+j*(segments+1)+i;addface([k,k+1,k+segments+2,k+segments+1],[(i/segments,j/(len(points)-1)),((i+1)/segments,j/(len(points)-1)),((i+1)/segments,(j+1)/(len(points)-1)),(i/segments,(j+1)/(len(points)-1))],col)
        part_ranges[name]=[start,len(verts)]
    def oval(name,center,radii,col,bone):
        cx,cy,cz=center;rx,ry,rz=radii
        rings=[(cx,cy,cz-rz*math.cos(j*math.pi/12),max(.0002,rx*math.sin(j*math.pi/12)),max(.0002,ry*math.sin(j*math.pi/12))) for j in range(13)]
        surface(name,rings,24,col,lambda p:{bone:1})

    torso_profile=[(.78,.22,.13),(.80,.225,.135),(.84,.22,.133),(.90,.21,.13),(.98,.195,.121),(1.03,.19,.12),(1.08,.197,.125),(1.16,.22,.139),(1.25,.245,.146),(1.32,.254,.14),(1.38,.257,.129),(1.43,.25,.112),(1.46,.185,.09),(1.49,.07,.065)]
    def cloth(p,a,j):
        # Broad tailored folds; stronger near hem/belt, restrained on chest.
        f=1+.018*math.sin(a*9+j*.35)*(1 if p.z<1.12 else .45);p.x*=f;p.y*=f;return p
    surface('Wool tunic with joint-ready shoulder loops',[(0,0,z,rx,ry) for z,rx,ry in torso_profile],48,0,body_weights,cloth)
    surface('Neck',[(0,0,z,rx,rx*.88) for z,rx in [(1.43,.065),(1.48,.061),(1.52,.062),(1.56,.07)]],32,3,lambda p:blend('Neck','Head',(p.z-1.49)/.07))
    for side,sg in [('L',-1),('R',1)]:
        profile=[(.21,.067,.072),(.25,.074,.078),(.32,.083,.087),(.40,.085,.092),(.46,.083,.089),(.49,.078,.083),(.51,.077,.08),(.53,.079,.084),(.56,.088,.092),(.62,.101,.105),(.72,.111,.115),(.82,.116,.12),(.91,.118,.12),(.97,.11,.11)]
        surface('Trousers '+side,[(sg*.112,-.012*math.exp(-((z-.51)/.12)**2),z,rx,ry) for z,rx,ry in profile],32,9,lambda p,s=side:leg_weights(p,s),cloth)
        # Boot with ankle, instep, broad toe and outsole, all deforming with foot.
        surface('Boot '+side,[(sg*.115,cy,z,rx,ry) for z,cy,rx,ry in [(0,-.075,.072,.135),(.018,-.075,.08,.145),(.038,-.075,.08,.145),(.065,-.073,.078,.139),(.10,-.052,.075,.115),(.14,-.018,.068,.077),(.20,0,.069,.067),(.27,0,.073,.067),(.285,0,.075,.07)]],32,2,lambda p,s=side:leg_weights(p,s))
        surface('Boot cuff '+side,[(sg*.115,0,z,.078,.073) for z in [.255,.26,.28,.29]],32,10,lambda p,s=side:leg_weights(p,s))
        for zz in [.14,.175,.21,.245]:tube('Boot lace '+side+str(zz),[(sg*.115-.035,-.071,zz),(sg*.115+.035,-.072,zz+.014)],[.003,.003],8,lambda p,s=side:leg_weights(p,s),6)
        armrings=[]
        for z in [.925,.94,.97,1.0,1.05,1.10,1.135,1.15,1.16,1.175,1.19,1.22,1.27,1.32,1.37,1.41,1.44,1.465,1.477]:
            xx=np.interp(z,[.91,1.16,1.43,1.477],[.54,.44,.245,.235]);radius=np.interp(z,[.91,1.16,1.30,1.41,1.44,1.477],[.045,.070,.082,.085,.063,.006])
            armrings.append((sg*xx,-.012,z,radius,radius*.94))
        surface('Continuous sleeve '+side,armrings,32,0,lambda p,s=side:arm_weights(p,s),cloth)
        surface('Blue cuff '+side,[(sg*np.interp(z,[.91,1.16],[.54,.44]),-.012,z,.051,.049) for z in [.927,.935,.955,.962]],32,1,lambda p,s=side:arm_weights(p,s))
        surface('Cuff gold piping '+side,[(sg*.528,-.012,z,.052,.05) for z in [.956,.960,.964]],32,5,lambda p,s=side:arm_weights(p,s))
        surface('Palm '+side,[(sg*xx,-.03,z,rx,ry) for z,xx,rx,ry in [(.795,.578,.025,.048),(.82,.57,.032,.051),(.855,.556,.034,.049),(.89,.545,.027,.038),(.925,.537,.024,.033)]],24,3,lambda p,s=side:arm_weights(p,s))
        for finger in range(4):
            b1=f'Finger{finger+1}A.{side}';b2=f'Finger{finger+1}B.{side}';a,b,_=bones[b1];_,c,_=bones[b2]
            pts=[Vector(a).lerp(Vector(b),t) for t in [0,.4,.8,1]]+[Vector(b).lerp(Vector(c),t) for t in [.2,.7,1]]
            tube('Finger '+side+str(finger),pts,[.012,.012,.011,.0105,.0105,.009,.004],3,lambda p,a=b1,b=b2,z=Vector(b).z:blend(b,a,(p.z-z+.012)/.024),12)
        a,b,_=bones['ThumbA.'+side];_,c,_=bones['ThumbB.'+side]
        tube('Thumb '+side,[a,Vector(a).lerp(Vector(b),.5),b,Vector(b).lerp(Vector(c),.6),c],[.018,.017,.015,.013,.006],3,lambda p,s=side:blend('ThumbB.'+s,'ThumbA.'+s,(p.z-.80)/.025),14)
    headprofile=[(1.51,.06,.056),(1.53,.078,.065),(1.55,.094,.075),(1.58,.115,.083),(1.61,.126,.092),(1.64,.128,.096),(1.67,.123,.095),(1.70,.122,.098),(1.73,.12,.098),(1.76,.111,.09),(1.79,.086,.067),(1.805,.045,.038),(1.811,.003,.003)]
    def face_shape(p,a,j):
        front=max(0,math.cos(a))
        p.y-=front**8*(.043*math.exp(-(p.x/.024)**2-((p.z-1.642)/.032)**2)+.008*math.exp(-((p.z-1.71)/.013)**2))
        return p
    surface('Sculpted head with cheek brow nose and chin loops',[(0,0,z,rx,ry) for z,rx,ry in headprofile],64,3,lambda p:{'Head':1},face_shape)
    # Short stubble and moustache preserve original Karl, not prototype long beard.
    for sg in [-1,1]:
        oval('Ear '+str(sg),(sg*.124,.0,1.65),(.023,.021,.044),3,'Head')
        oval('Eye '+str(sg),(sg*.046,-.091,1.680),(.019,.008,.008),6,'Head')
        oval('Iris '+str(sg),(sg*.046,-.099,1.680),(.006,.002,.0065),4,'Head')
        oval('Pupil '+str(sg),(sg*.046,-.101,1.680),(.003,.001,.0045),7,'Head')
        tube('Brow '+str(sg),[(sg*.021,-.102,1.704),(sg*.045,-.103,1.710),(sg*.072,-.087,1.703)],[.004,.006,.003],4,lambda p:{'Head':1},10)
        tube('Moustache '+str(sg),[(sg*.003,-.112,1.607),(sg*.018,-.110,1.602),(sg*.035,-.099,1.603)],[.004,.006,.002],4,lambda p:{'Head':1},10)
    tube('Mouth',[(-.024,-.100,1.588),(0,-.107,1.585),(.024,-.10,1.588)],[.0025,.003,.0025],4,lambda p:{'Head':1},10)
    # Surface stubble patch, tightly fitted rather than a separate beard lump.
    start=len(verts);nr=7;ns=22
    for j in range(nr):
        z=1.542+j*.008;rx=np.interp(z,[q[0] for q in headprofile],[q[1] for q in headprofile]);ry=np.interp(z,[q[0] for q in headprofile],[q[2] for q in headprofile])
        for i in range(ns+1):
            a=-1.12+2.24*i/ns;p=face_shape(Vector(((rx+.001)*math.sin(a),-(ry+.0015)*math.cos(a),z)),a,0);verts.append(tuple(p));weights.append({'Head':1})
    for j in range(nr-1):
        for i in range(ns):
            k=start+j*(ns+1)+i;addface([k,k+1,k+ns+2,k+ns+1],[(i/ns,j/nr),((i+1)/ns,j/nr),((i+1)/ns,(j+1)/nr),(i/ns,(j+1)/nr)],14)
    surface('Worker wool cap',[(cx,0,z,rx,ry) for z,cx,rx,ry in [(1.738,0,.126,.104),(1.75,0,.13,.107),(1.78,.002,.13,.108),(1.82,.012,.117,.096),(1.855,.02,.087,.072),(1.878,.025,.035,.032),(1.881,.025,.002,.002)]],48,8,lambda p:{'Head':1},cloth)
    surface('Kjelvik blue cap band',[(0,0,z,.138,.114) for z in [1.744,1.75,1.773,1.778]],48,1,lambda p:{'Head':1})
    surface('Cap gold stripe',[(0,0,z,.139,.115) for z in [1.746,1.75,1.754]],48,5,lambda p:{'Head':1})
    # Tailored blue front panel, following the tunic's actual elliptical surface.
    start=len(verts);zs=np.linspace(.805,1.418,20);xs=np.linspace(-.082,.082,12)
    for z in zs:
        rx=np.interp(z,[r[0] for r in torso_profile],[r[1] for r in torso_profile]);ry=np.interp(z,[r[0] for r in torso_profile],[r[2] for r in torso_profile])
        for xx in xs:
            p=(xx,-ry*math.sqrt(1-(xx/rx)**2)-.004,z);verts.append(p);weights.append(body_weights(p))
    for j in range(len(zs)-1):
        for i in range(len(xs)-1):
            k=start+j*len(xs)+i;addface([k,k+1,k+len(xs)+1,k+len(xs)],[(i/11,j/19),((i+1)/11,j/19),((i+1)/11,(j+1)/19),(i/11,(j+1)/19)],1)
    for xx in [-.083,.083]:
        points=[]
        for z in zs:
            rx=np.interp(z,[r[0] for r in torso_profile],[r[1] for r in torso_profile]);ry=np.interp(z,[r[0] for r in torso_profile],[r[2] for r in torso_profile]);points.append((xx,-ry*math.sqrt(1-(xx/rx)**2)-.006,z))
        tube('Tabard gold seam '+str(xx),points,[.003]*len(points),5,body_weights,8)
    surface('Leather belt',[(0,0,z,.201,.134) for z in [.99,.995,1.027,1.032]],48,2,lambda p:{'Hips':1})
    tube('Brass belt buckle',[(-.028,-.139,.994),(-.028,-.139,1.03),(.028,-.139,1.03),(.028,-.139,.994),(-.028,-.139,.994)],[.005]*5,5,lambda p:{'Hips':1},8)
    surface('Leather pouch',[(.20,-.04,z,rx,ry) for z,rx,ry in [(.84,.02,.02),(.85,.055,.04),(.89,.065,.045),(.96,.06,.04),(.99,.04,.03),(1.005,.027,.02)]],24,10,lambda p:{'Hips':1})
    # Small interlaced breast badge, legible as gold identity accent at game size.
    for phase in [0,math.tau/3,2*math.tau/3]:
        pts=[(.015*math.sin(t+phase),-.154,1.29+.019*math.sin(2*t+phase)) for t in np.linspace(0,math.tau,28)]
        tube('Knotwork badge '+str(phase),pts,[.002]*len(pts),5,body_weights,6)
    mesh=bpy.data.meshes.new('Karl_Tailored_Deformation_Topology');mesh.from_pydata(verts,[],faces);mesh.update()
    obj=bpy.data.objects.new('Karl_SkinnedMesh',mesh);scene.collection.objects.link(obj);mesh.materials.append(mat)
    uv=mesh.uv_layers.new(name='Karl_Painted_UV')
    for poly,coords in zip(mesh.polygons,uvfaces):
        poly.use_smooth=True
        for li,coord in zip(poly.loop_indices,coords):uv.data[li].uv=coord
    # Correct normals consistently, without changing the authored edge loops.
    bpy.ops.object.select_all(action='DESELECT');obj.select_set(True);bpy.context.view_layer.objects.active=obj
    bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.mesh.normals_make_consistent(inside=False);bpy.ops.object.mode_set(mode='OBJECT')
    for name in bones:obj.vertex_groups.new(name=name)
    for i,ww in enumerate(weights):
        ww={k:v for k,v in ww.items() if v>.00001};total=sum(ww.values())
        for name,w in ww.items():obj.vertex_groups[name].add([i],w/total,'REPLACE')
    mod=obj.modifiers.new('Weighted skeletal deformation','ARMATURE');mod.object=rig;mod.use_deform_preserve_volume=False
    obj.parent=rig
    # Curves are authored in anatomical/world axes, converted to each bone basis.
    def rotate(name,angles):
        q=Euler(angles,'XYZ').to_quaternion();rest=rig.data.bones[name].matrix_local.to_quaternion()
        pb=rig.pose.bones[name];pb.rotation_mode='QUATERNION';pb.rotation_quaternion=rest.inverted()@q@rest
    def aim(name,head,tail):
        b=rig.data.bones[name];rest=b.matrix_local.to_quaternion()
        q=(b.tail_local-b.head_local).normalized().rotation_difference((tail-head).normalized())@rest
        rig.pose.bones[name].matrix=Matrix.LocRotScale(head,q,Vector((1,1,1)))
        bpy.context.view_layer.update()
    def solve_two(first,second,target,pole):
        bpy.context.view_layer.update();s=rig.pose.bones[first].head.copy()
        l1=rig.data.bones[first].length;l2=rig.data.bones[second].length
        d=min((target-s).length,l1+l2-.0005);axis=(target-s).normalized()
        along=(l1*l1-l2*l2+d*d)/(2*d);height=math.sqrt(max(0,l1*l1-along*along))
        side=(pole-s)-axis*(pole-s).dot(axis);side.normalize()
        elbow=s+axis*along+side*height;end=s+axis*d
        aim(first,s,elbow);aim(second,elbow,end);return end
    rig.animation_data_create()
    for clip,(length,loop) in CLIPS.items():
        action=bpy.data.actions.new(clip);action.use_fake_user=True;rig.animation_data.action=action
        for f in sorted(set(list(range(0,length+1,2))+[length])):
            t=f/length;phase=t*math.tau
            for pb in rig.pose.bones:pb.rotation_mode='QUATERNION';pb.rotation_quaternion=(1,0,0,0);pb.location=(0,0,0)
            for side,sg in [('L',-1),('R',1)]:
                rotate('UpperArm.'+side,(0,sg*math.radians(23),0));rotate('Forearm.'+side,(math.radians(-5),0,0))
                for finger in range(4):rotate(f'Finger{finger+1}A.{side}',(.10,0,0));rotate(f'Finger{finger+1}B.{side}',(.12,0,0))
            if clip=='idle':
                rotate('Chest',(math.sin(phase)*.012,0,0));rotate('Head',(0,0,math.sin(phase)*.018))
            elif clip=='walk':
                for side,sg in [('L',-1),('R',1)]:
                    s=math.sin(phase)*sg
                    rotate('Thigh.'+side,(s*.34,0,0));rotate('Shin.'+side,(-max(0,-s)*.55,0,0));rotate('Foot.'+side,(max(0,s)*-.13,0,0))
                    rotate('UpperArm.'+side,(-s*.24,sg*math.radians(23),0));rotate('Forearm.'+side,(-.12-max(0,s)*.12,0,0))
                rotate('Hips',(0,0,math.sin(phase)*.035));rotate('Chest',(0,0,-math.sin(phase)*.04))
                rig.pose.bones['Hips'].location=rig.data.bones['Hips'].matrix_local.to_3x3().inverted()@Vector((0,0,-.036))
                for side,sg in [('L',-1),('R',1)]:
                    s=math.sin(phase)*sg
                    target=Vector((sg*.115,-.22*s,.12+max(0,-s)*.10))
                    end=solve_two('Thigh.'+side,'Shin.'+side,target,Vector((sg*.115,-.5,.5)))
                    rig.pose.bones['Foot.'+side].matrix=Matrix.LocRotScale(end,rig.data.bones['Foot.'+side].matrix_local.to_quaternion(),Vector((1,1,1)))
            elif clip.startswith('look_'):
                envelope=math.sin(math.pi*t)**1.3;sg=1 if clip=='look_left' else -1
                rotate('Head',(0,0,sg*.55*envelope));rotate('Chest',(0,0,sg*.08*envelope))
            elif clip=='arms_crossed':
                envelope=math.sin(math.pi*t)**.6
                for side,sg in [('L',-1),('R',1)]:
                    bpy.context.view_layer.update()
                    initial=rig.pose.bones['Forearm.'+side].tail.copy()
                    target=initial.lerp(Vector((-sg*.025,-.20 if side=='L' else -.24,1.21 if side=='L' else 1.13)),envelope)
                    end=solve_two('UpperArm.'+side,'Forearm.'+side,target,Vector((sg*.6,-.12,1.08)))
                    hand=rig.pose.bones['Hand.'+side]
                    direction=(end-rig.pose.bones['Forearm.'+side].head).normalized()
                    aim('Hand.'+side,end,end+direction*rig.data.bones['Hand.'+side].length)
            elif clip=='hit':
                envelope=math.sin(math.pi*t);rotate('Spine',(-.17*envelope,0,.06*envelope));rotate('Head',(-.12*envelope,0,0))
            elif clip=='death':
                v=smooth(t);rotate('Root',(-math.pi*.48*v,0,.12*v))
                # Authored collapse only. Gameplay must still hide at server death.
                rig.pose.bones['Root'].location=(0,0,.06*v)
                rotate('Spine',(.12*math.sin(math.pi*t),0,0))
                for side,sg in [('L',-1),('R',1)]:rotate('UpperArm.'+side,(-.12*v,sg*(.40+.35*v),0))
            for pb in rig.pose.bones:
                if pb.name.startswith('Socket'):continue
                pb.keyframe_insert('rotation_quaternion',frame=f,group=pb.name)
                pb.keyframe_insert('location',frame=f,group=pb.name)
        action['loop']=loop;action['duration_seconds']=length/30
    rig.animation_data.action=bpy.data.actions['idle'];scene.frame_set(0)
    # Studio remains editable in .blend and is excluded from the GLB.
    world=bpy.data.worlds.new('Karl neutral studio');scene.world=world;world.use_nodes=True;world.node_tree.nodes['Background'].inputs[0].default_value=(.48,.55,.65,1);world.node_tree.nodes['Background'].inputs[1].default_value=.35
    for name,loc,power,col in [('Warm key',(-3,-4,5),450,(1,.90,.79)),('Cool fill',(3,-2,3),240,(.78,.86,1)),('Rim',(1,3,4),500,(1,.94,.85))]:
        data=bpy.data.lights.new(name,'AREA');data.energy=power;data.color=col;data.size=3
        light=bpy.data.objects.new(name,data);scene.collection.objects.link(light);light.location=loc;light.rotation_euler=(Vector((0,0,1))-light.location).to_track_quat('-Z','Y').to_euler()
    cam=bpy.data.objects.new('Karl review camera',bpy.data.cameras.new('Orthographic'));scene.collection.objects.link(cam);cam.data.type='ORTHO';cam.data.ortho_scale=2.3;scene.camera=cam;camera_at(cam,(0,0,.94),20,12)
    scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.samples=32;scene.cycles.use_denoising=True;scene.render.film_transparent=True
    scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.resolution_percentage=100
    scene.view_settings.view_transform='Standard';scene.view_settings.look='None'
    scene.render.resolution_x=scene.render.resolution_y=768
    # Export all armature actions as separate named clips; no root-motion gameplay.
    bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);obj.select_set(True);bpy.context.view_layer.objects.active=rig
    bpy.ops.export_scene.gltf(filepath=str(OUT/'karl.glb'),export_format='GLB',use_selection=True,export_animations=True,export_animation_mode='ACTIONS',export_def_bones=False,export_force_sampling=True,export_frame_range=False,export_cameras=False,export_lights=False)
    bpy.ops.wm.save_as_mainfile(filepath=str(SRC/'karl.blend'))
    # Validate evaluated deformation and weight normalization from actual Blender mesh.
    weighted=sum(1 for vv in obj.data.vertices if len([g for g in vv.groups if g.weight>.001])>1)
    sums=[sum(g.weight for g in vv.groups) for vv in obj.data.vertices]
    checks={'armature_modifiers':sum(m.type=='ARMATURE' for m in obj.modifiers),'vertices':len(mesh.vertices),'triangles':sum(len(f.vertices)-2 for f in mesh.polygons),'bones':len(bones),'multi_bone_vertices':weighted,'unweighted_vertices':sum(abs(s)<.00001 for s in sums),'max_weight_sum_error':max(abs(s-1) for s in sums),'max_influences':max(len(v.groups) for v in mesh.vertices),'uv_layers':len(mesh.uv_layers),'clips':{k:{'duration':v[0]/30,'loop':v[1]} for k,v in CLIPS.items()}}
    assert checks['unweighted_vertices']==0 and checks['max_weight_sum_error']<.0001 and weighted>100
    positions={}
    for clip,frame in [('idle',0),('walk',8),('arms_crossed',24),('hit',4),('death',45)]:
        rig.animation_data.action=bpy.data.actions[clip];scene.frame_set(frame);bpy.context.view_layer.update()
        ev=obj.evaluated_get(bpy.context.evaluated_depsgraph_get());mm=ev.to_mesh();coords=np.array([tuple(v.co) for v in mm.vertices]);positions[clip]=coords
        checks[clip+'_finite']=bool(np.isfinite(coords).all());ev.to_mesh_clear()
        scene.render.filepath=str(PRE/f'{clip}_review.png');bpy.ops.render.render(write_still=True)
    checks['walk_vertices_moved']=int((np.linalg.norm(positions['walk']-positions['idle'],axis=1)>.001).sum())
    assert checks['walk_vertices_moved']>200
    (PRE/'blender_checks.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
    (SRC/'authoring.py').write_bytes(Path(__file__).read_bytes())
    manifest={'asset_id':'npc.karl','existing_id':'n:4','match':{'npc_type':'worker','npc_name':'Karl','region':'kjelvik'},'version':ver,'status':'IN PRODUCTION','visual_approval':'PENDING','runtime_integration':'NOT INTEGRATED; Claude Code handoff','source_forward':'Blender -Y / Godot +Z','world_scale':'1 unit = 32 logical pixels','feet_origin':[0,0,0],'source':str((SRC/'karl.blend').relative_to(ROOT)),'model':str((OUT/'karl.glb').relative_to(ROOT)),'clips':checks['clips'],'sockets':[k for k in bones if k.startswith('Socket')],'rig_status':'Karl-specific benchmark; not approved as shared family','death_policy':'Do not delay server-driven hide/disable; clip is optional presentation only','attack_policy':'No attack clip: NPC attack=0, townsfolk do not fight back','triangles':checks['triangles'],'bones':len(bones),'materials':1,'textures':['karl_basecolor.png','karl_normal.png','karl_orm.png']}
    (OUT/'karl.manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print('KARL_BUILD_OK',json.dumps(checks))
else:
    bpy.ops.wm.open_mainfile(filepath=str(SRC/'karl.blend'))
    scene=bpy.context.scene;rig=bpy.data.objects['Karl_Rig'];cam=scene.camera
    camera_at(cam,(0,0,.94),0,12);cam.data.ortho_scale=2.9
    size=64;scale=3
    scene.render.resolution_x=scene.render.resolution_y=size*scale;scene.cycles.samples=16
    meta={'asset_id':'npc.karl','version':ver,'cell_size':[size,size],'directions':['front','right','back','left'],'fps':12,'clips':{},'preserve_original_2d_ground_y':14}
    origin=world_to_camera_view(scene,cam,Vector((0,0,0)))
    meta['pivot']=[round(origin.x*size),round((1-origin.y)*size)]
    meta['draw_offset']=[-meta['pivot'][0],14-meta['pivot'][1]]
    for clip,(length,loop) in CLIPS.items():
        path=OUT/f'karl_{clip}.png';assert not path.exists(),'Sheet exists; select a new version'
        count=max(4,math.ceil(length/30*12));frames=np.linspace(0,length,count,endpoint=not loop)
        rows=[];rig.animation_data.action=bpy.data.actions[clip]
        for direction,angle in zip(meta['directions'],[0,90,180,270]):
            camera_at(cam,(0,0,.94),angle,12);cells=[]
            for idx,frame in enumerate(frames):
                scene.frame_set(int(frame),subframe=float(frame%1));bpy.context.view_layer.update()
                tmp=PRE/'render_work.png';scene.render.filepath=str(tmp);bpy.ops.render.render(write_still=True)
                im=bpy.data.images.load(str(tmp),check_existing=False);pix=np.array(im.pixels[:],dtype='float32').reshape(size*scale,size*scale,4);bpy.data.images.remove(im)
                pix[:,:,:3]*=pix[:,:,3:4];small=pix.reshape(size,scale,size,scale,4).mean(axis=(1,3));small[:,:,:3]/=np.maximum(small[:,:,3:4],1e-8);cells.append(small)
            rows.append(np.concatenate(cells,axis=1))
        # Blender buffers are bottom-up; front should be the TOP row in PNG.
        sheet=np.concatenate(rows[::-1],axis=0);save_rgba('Karl_'+clip,sheet,path)
        meta['clips'][clip]={'file':path.name,'frames_per_direction':count,'duration':length/30,'loop':loop,'direction_rows':{'front':0,'right':1,'back':2,'left':3}}
    (OUT/'karl.sprites.json').write_text(json.dumps(meta,indent=2),encoding='utf-8')
    print('KARL_SHEETS_OK',json.dumps(meta))
