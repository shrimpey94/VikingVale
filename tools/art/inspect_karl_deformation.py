"""Blender asset QA only; opens a master read-only and writes a QA report."""
import sys,json,math
sys.dont_write_bytecode=True
from pathlib import Path
import bpy
import numpy as np
root=next(p for p in Path(__file__).resolve().parents if (p/'project.godot').exists())
version=sys.argv[sys.argv.index('--')+1]
bpy.ops.wm.open_mainfile(filepath=str(root/f'art_source/blender/characters/karl/{version}/karl.blend'))
rig=bpy.data.objects['Karl_Rig'];obj=bpy.data.objects['Karl_SkinnedMesh'];scene=bpy.context.scene
report={}
for action in bpy.data.actions:
    rig.animation_data.action=action;lo,hi=action.frame_range
    bounds=[]
    for frame in np.linspace(lo,hi,13):
        scene.frame_set(int(frame),subframe=float(frame%1));bpy.context.view_layer.update()
        ev=obj.evaluated_get(bpy.context.evaluated_depsgraph_get());m=ev.to_mesh()
        a=np.array([tuple(v.co) for v in m.vertices]);ev.to_mesh_clear()
        bounds.append({'frame':float(frame),'min':a.min(axis=0).tolist(),'max':a.max(axis=0).tolist(),'finite':bool(np.isfinite(a).all())})
    report[action.name]={'duration_frames':[lo,hi],'sampled_bounds':bounds,'lowest_z':min(b['min'][2] for b in bounds)}
dest=root/f'art_source/previews/characters/karl/{version}/deformation_bounds.json'
dest.write_text(json.dumps(report,indent=2),encoding='utf-8')
conventions={name:list(rig.data.bones[name].head_local) for name in ['Hand.L','Hand.R','Socket.Hand.L','Socket.Hand.R']}
assert conventions['Hand.L'][0]>0 and conventions['Hand.R'][0]<0
assert conventions['Socket.Hand.L'][0]>0 and conventions['Socket.Hand.R'][0]<0
(dest.parent/'rig_conventions.json').write_text(json.dumps({'anatomical_left':'source/export +X','anatomical_right':'source/export -X','bone_head_positions':conventions,'passed':True},indent=2))
print('DEFORMATION_BOUNDS',json.dumps({k:v['lowest_z'] for k,v in report.items()}))
