"""Read-only GLB/sprite package checks; no runtime integration or image editing."""
from pathlib import Path
import json,struct,zlib,math,sys,hashlib
root=Path(__file__).resolve().parents[2];version=sys.argv[1]
folder=root/f'assets/authored/characters/karl/{version}'
out=root/f'art_source/previews/characters/karl/{version}'
def png(path):
 b=path.read_bytes();i=8;data=b''
 while i<len(b):
  n=struct.unpack_from('>I',b,i)[0];kind=b[i+4:i+8];payload=b[i+8:i+8+n];i+=12+n
  if kind==b'IHDR':w,h,depth,ct,_,_,interlace=struct.unpack('>IIBBBBB',payload)
  if kind==b'IDAT':data+=payload
 assert depth==8 and ct in (2,6) and not interlace
 channels=4 if ct==6 else 3;raw=zlib.decompress(data);stride=w*channels;rows=[];prev=bytearray(stride);j=0
 for y in range(h):
  filt=raw[j];row=bytearray(raw[j+1:j+1+stride]);j+=stride+1
  for x in range(stride):
   a=row[x-channels] if x>=channels else 0;b=prev[x];c=prev[x-channels] if x>=channels else 0
   if filt==1:q=a
   elif filt==2:q=b
   elif filt==3:q=(a+b)//2
   elif filt==4:
    p=a+b-c;pa,pb,pc=abs(p-a),abs(p-b),abs(p-c);q=a if pa<=pb and pa<=pc else b if pb<=pc else c
   else:q=0
   row[x]=(row[x]+q)&255
  rows.append(row);prev=row
 return w,h,channels,rows
checks=[]
def check(ok,name,detail=None):checks.append({'check':name,'passed':bool(ok),'detail':detail})
w,h,c,rows=png(folder/'karl_basecolor.png')
skin=list(rows[896][896*c:896*c+3]);blue=list(rows[896][384*c:384*c+3])
check(all(abs(a-b)<12 for a,b in zip(skin,[148,107,71])),'Authored sRGB skin palette survives PNG export',skin)
check(all(abs(a-b)<12 for a,b in zip(blue,[51,79,120])),'Authored sRGB blue palette survives PNG export',blue)
b=(folder/'karl.glb').read_bytes();n=struct.unpack_from('<I',b,12)[0];g=json.loads(b[20:20+n])
check(len(g.get('skins',[]))==1,'One exported skin')
check(len(g['skins'][0]['joints'])==46,'46 exported joints including sockets')
clips={a['name'] for a in g.get('animations',[])}
check(clips=={'idle','walk','look_left','look_right','arms_crossed','hit','death'},'Seven correct role-specific animation clips',sorted(clips))
check(len(g['meshes'])==1,'One skinned mesh')
attrs=g['meshes'][0]['primitives'][0]['attributes']
check(all(a in attrs for a in ['POSITION','NORMAL','TEXCOORD_0','JOINTS_0','WEIGHTS_0']),'Geometry, UVs, joints and weights in GLB')
mat=g['materials'][0]
check('baseColorTexture' in mat['pbrMetallicRoughness'] and 'metallicRoughnessTexture' in mat['pbrMetallicRoughness'] and 'normalTexture' in mat,'Base color / rough-metal / normal textures exported')
names={g['nodes'][i]['name'] for i in g['skins'][0]['joints']}
check(all(k in names for k in ['Socket.Hand.L','Socket.Hand.R','Socket.Back','Socket.Head']),'Attachment bones exported')
meta=json.loads((folder/'karl.sprites.json').read_text());sheets={}
if meta.get('display_scale'):
 pw,ph,pc,pr=png(folder/'karl_sprite_palette.png')
 for label,x,y,expected in [('skin',224,224,[148,107,71]),('city blue',96,224,[51,87,158]),('city gold',96,160,[209,168,51])]:
  actual=list(pr[y][x*pc:x*pc+3])
  check(all(abs(a-b)<=1 for a,b in zip(actual,expected)),'Original 2D palette: '+label,actual)
 check(all(abs((c['pivot'][1]+c['draw_offset'][1])*c['display_scale']-14)<.001 and abs((c['pivot'][0]+c['draw_offset'][0])*c['display_scale'])<.001 for c in meta['clips'].values()),'High-resolution sheets preserve original logical feet anchor')
for clip,cfg in meta['clips'].items():
 w,h,c,rows=png(folder/cfg['file']);cw,ch=cfg.get('cell_size',meta['cell_size']);count=cfg['frames_per_direction']
 check(w==cw*count and h==ch*4,'Sheet layout '+clip,[w,h])
 check(c==4,'RGBA alpha '+clip)
 clipped=[];empty=[]
 for direction in range(4):
  for f in range(count):
   x0=f*cw;y0=direction*ch
   edge=any(rows[y0][(x0+x)*c+3]>2 or rows[y0+ch-1][(x0+x)*c+3]>2 for x in range(cw)) or any(rows[y0+y][x0*c+3]>2 or rows[y0+y][(x0+cw-1)*c+3]>2 for y in range(ch))
   if edge:clipped.append([direction,f])
   if not any(rows[y][x*c+3]>2 for y in range(y0,y0+ch) for x in range(x0,x0+cw)):empty.append([direction,f])
 check(not clipped,'No clipped frame edges '+clip,clipped)
 check(not empty,'No empty frames '+clip,empty)
 sheets[clip]={'dimensions':[w,h],'cell_size':[cw,ch],'frames':count*4}
bounds=json.loads((out/'deformation_bounds.json').read_text())
check(all(b['finite'] for a in bounds.values() for b in a['sampled_bounds']),'All sampled skeletal poses finite')
check(min(a['lowest_z'] for a in bounds.values())>-.001,'Poses stay above floor within 1 mm',min(a['lowest_z'] for a in bounds.values()))
conventions=json.loads((out/'rig_conventions.json').read_text())
check(conventions['passed'],'Anatomical left/right bones and hand sockets use correct sides',conventions)
baseline=json.loads((root/'art_source/production/karl/v003/baseline_hashes.json').read_text())
changed=[p for p,digest in baseline.items() if hashlib.sha256((root/p).read_bytes()).hexdigest()!=digest]
check(not changed,'All pre-existing game scripts / project settings / version unchanged',changed)
report={'checks':checks,'failures':sum(not c['passed'] for c in checks),'sheets':sheets,'runtime_integration':'NOT PERFORMED','visual_approval':'PENDING'}
(out/'package_checks.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps({'checks':len(checks),'failures':report['failures'],'failed':[c for c in checks if not c['passed']]},indent=2))
sys.exit(1 if report['failures'] else 0)
