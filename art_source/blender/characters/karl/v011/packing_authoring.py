"""Blender export packing: crop only shared transparent frame margins, retain exact pixels."""
from pathlib import Path
import json,shutil,sys
import bpy,numpy as np
root=next(p for p in Path(__file__).resolve().parents if (p/'project.godot').exists());old=root/'assets/authored/characters/karl/v010';out=root/'assets/authored/characters/karl/v011';src=root/'art_source/blender/characters/karl/v011';pre=root/'art_source/previews/characters/karl/v011'
assert not out.exists(),'Select a new output version'
for p in [out,src,pre]:p.mkdir(parents=True,exist_ok=True)
for name in ['karl.glb','karl_basecolor.png','karl_normal.png','karl_orm.png','karl_sprite_palette.png']:shutil.copy2(old/name,out/name)
for name in ['karl.blend','karl_sprite_studio_crisp.blend','sprite_authoring.py']:shutil.copy2(root/'art_source/blender/characters/karl/v010'/name,src/name)
for name in ['blender_checks.json','deformation_bounds.json','rig_conventions.json','unchanged_3d_checks.json']:shutil.copy2(root/'art_source/previews/characters/karl/v010'/name,pre/name)
meta=json.loads((old/'karl.sprites.json').read_text());meta['version']='v011';saved=0;original=0;report={}
for clip,cfg in meta['clips'].items():
 size=cfg['cell_size'][0];count=cfg['frames_per_direction'];im=bpy.data.images.load(str(old/cfg['file']));pixels=np.array(im.pixels[:],dtype='float32').reshape(4,size,count,size,4).transpose(0,2,1,3,4);bpy.data.images.remove(im)
 occupied=np.any(pixels[:,:,:,:,3]>0,axis=(0,1));yy,xx=np.where(occupied);x0=max(0,int(xx.min())-4);x1=min(size,int(xx.max())+5);y0=max(0,int(yy.min())-4);y1=min(size,int(yy.max())+5)
 width=x1-x0;height=y1-y0;top=size-y1;crop=pixels[:,:,y0:y1,x0:x1,:];packed=crop.transpose(0,2,1,3,4).reshape(4*height,count*width,4)
 im=bpy.data.images.new('Packed_'+clip,width=count*width,height=4*height,alpha=True);im.pixels.foreach_set(packed.ravel());im.filepath_raw=str(out/cfg['file']);im.file_format='PNG';im.save();bpy.data.images.remove(im)
 cfg['cell_size']=[width,height];cfg['pivot']=[cfg['pivot'][0]-x0,cfg['pivot'][1]-top];cfg['draw_offset']=[cfg['draw_offset'][0]+x0,cfg['draw_offset'][1]+top];cfg['source_crop_top_left']=[x0,top]
 original+=size*size*count*4*4;saved+=width*height*count*4*4
 report[clip]={'cell_size':[width,height],'crop_top_left':[x0,top],'no_nontransparent_pixels_removed':int(np.count_nonzero(pixels[:,:,:,:,3]))==int(np.count_nonzero(crop[:,:,:,:,3]))}
for key in ['cell_size','pivot','draw_offset']:meta[key]=meta['clips']['idle'][key]
meta['packing']={'method':'Same transparent-margin crop for every frame/direction within each clip','source_version':'v010','rgba8_bytes_before':original,'rgba8_bytes_after':saved}
(out/'karl.sprites.json').write_text(json.dumps(meta,indent=2)+'\n')
m=json.loads((old/'karl.manifest.json').read_text());m['version']='v011'
for k in ['source','model','source_2d','sprite_contract']:m[k]=m[k].replace('v010','v011')
m['changes']='Original-color, sharp 2D sheets with transparent-margin packing; 3D unchanged from v009';(out/'karl.manifest.json').write_text(json.dumps(m,indent=2)+'\n')
(pre/'packing_checks.json').write_text(json.dumps(report,indent=2)+'\n');(src/'packing_authoring.py').write_bytes(Path(__file__).read_bytes());print('PACKED_MiB',original/1048576,saved/1048576)
