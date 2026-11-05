"""Blender-only, deterministic Stone Pickup v001 authoring/export pipeline.

Run with Blender --background --factory-startup --python-exit-code 1 --python
this_file -- --manifest art_source/manifests/stone_pickup_v001.json.
Refuses to overwrite outputs. All authored writes are confined to this project.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import hashlib
import json
import math
from pathlib import Path
import random

import bpy
from mathutils import Vector
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
args = argparse.ArgumentParser()
args.add_argument('--manifest', required=True)
opts = args.parse_args(sys.argv[sys.argv.index('--') + 1:])
manifest_path = (ROOT / opts.manifest).resolve()
assert manifest_path.is_relative_to(ROOT)
cfg = json.loads(manifest_path.read_text(encoding='utf-8'))

def project_dir(key):
    path = (ROOT / cfg[key]).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError('Output outside project')
    return path

source = project_dir('source_dir')
output = project_dir('output_dir')
preview = project_dir('preview_dir')
paths = {
    'blend': source / 'stone_pickup.blend',
    'glb': output / 'stone_pickup.glb',
    'texture': output / 'stone_pickup_basecolor.png',
    'sprite': output / 'stone_pickup.png',
    'metadata': output / 'stone_pickup.frames.json',
    'large': preview / 'stone_pickup_preview.png',
    'supersampled': preview / 'stone_pickup_128.png',
}
if any(p.exists() for p in paths.values()):
    raise FileExistsError('Version outputs already exist; select a new manifest/version')
for folder in (source, output, preview):
    folder.mkdir(parents=True, exist_ok=True)

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
bpy.context.preferences.filepaths.save_version = 0
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = 1.0
rng = random.Random(cfg['seed'])

# An editable UV atlas: broad painted mineral patches, soft worn highlights and
# a few narrow seams. Three strips give each stone a restrained warm/cool tint.
n = cfg['texture_size']
y, x = np.mgrid[0:n, 0:n].astype(np.float32)
u, v = (x + .5) / n, (y + .5) / n
strip = np.minimum((u * 3).astype(int), 2)
su = (u * 3) % 1
colors = np.array([[119, 125, 131], [139, 136, 125], [126, 131, 132]], dtype=np.float32) / 255
patch = .035 * np.sin(su * 14 + np.sin(v * 9) * 1.8) + .022 * np.cos(v * 21 + su * 7)
seam_curve = .32 + .09 * np.sin(v * 11)
seam = np.exp(-((su - seam_curve) / .009)**2) * np.exp(-((v - .52) / .18)**6)
wear = .045 * np.exp(-((v - .70) / .18)**2)
noise = np.random.default_rng(cfg['seed']).normal(0, .004, (n, n))
rgb = np.clip(colors[strip] + (patch + wear + noise - seam * .10)[..., None], 0, 1)
rgba = np.concatenate([rgb, np.ones((n, n, 1))], axis=2).astype(np.float32)
tex = bpy.data.images.new('Stone_Painted_Atlas_256', width=n, height=n, alpha=True)
tex.colorspace_settings.name = 'sRGB'
tex.pixels.foreach_set(rgba.ravel())
tex.filepath_raw = str(paths['texture'])
tex.file_format = 'PNG'
tex.save()

mat = bpy.data.materials.new('Stone_Painted_Matte')
mat.use_nodes = True
bsdf = mat.node_tree.nodes.get('Principled BSDF')
bsdf.inputs['Roughness'].default_value = .9
bsdf.inputs['Metallic'].default_value = 0
texture_node = mat.node_tree.nodes.new('ShaderNodeTexImage')
texture_node.image = tex
mat.node_tree.links.new(texture_node.outputs['Color'], bsdf.inputs['Base Color'])

stones = []
for index, (name, location, radius) in enumerate([
    ('Broad_Rear_Stone', (.035, .055, .125), (.205, .155, .155)),
    ('Front_Left_Wedge', (-.160, -.085, .080), (.125, .115, .090)),
    ('Front_Right_Pebble', (.170, -.095, .065), (.105, .095, .075)),
]):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, radius=1)
    ob = bpy.context.object
    ob.name = name
    for vertex in ob.data.vertices:
        p = vertex.co
        # Low-frequency asymmetry rather than random spiky triangles.
        f = 1 + .055 * math.sin(p.x * 5 + index) * math.cos(p.y * 4 - p.z * 3)
        p.x = p.x * radius[0] * f + location[0]
        p.y = p.y * radius[1] * f + location[1]
        p.z = max(.0, p.z * radius[2] * f + location[2])
    for loop in ob.data.uv_layers.active.data:
        loop.uv.x = (index + .025 + loop.uv.x * .95) / 3
    ob.data.materials.append(mat)
    for face in ob.data.polygons:
        face.use_smooth = True
    stones.append(ob)

# One mesh/material for efficient world instances; disconnected stone islands
# remain editable with Separate by Loose Parts in Blender.
bpy.ops.object.select_all(action='DESELECT')
for ob in stones:
    ob.select_set(True)
bpy.context.view_layer.objects.active = stones[0]
bpy.ops.object.join()
asset = bpy.context.object
asset.name = 'StonePickup_v001'
coords = np.array([tuple(v.co) for v in asset.data.vertices])
lo, hi = coords.min(axis=0), coords.max(axis=0)
scale = np.array(cfg['dimensions_xyz_blender']) / (hi - lo)
center = np.array([(hi[0]+lo[0])/2, (hi[1]+lo[1])/2, lo[2]])
for vertex in asset.data.vertices:
    vertex.co = (np.array(vertex.co) - center) * scale
asset.data.update()
asset.data.calc_loop_triangles()
triangles = len(asset.data.loop_triangles)
assert 250 <= triangles <= 450, triangles
assert len(asset.data.materials) == 1

export_collection = bpy.data.collections.new('EXPORT_StonePickup')
scene.collection.children.link(export_collection)
for collection in list(asset.users_collection):
    collection.objects.unlink(asset)
export_collection.objects.link(asset)
studio = bpy.data.collections.new('STUDIO_DoNotExport')
scene.collection.children.link(studio)

def studio_link(ob):
    for collection in list(ob.users_collection):
        collection.objects.unlink(ob)
    studio.objects.link(ob)

def area(name, location, power, color, size):
    data = bpy.data.lights.new(name, 'AREA')
    data.energy, data.color, data.shape, data.size = power, color, 'DISK', size
    ob = bpy.data.objects.new(name, data)
    studio.objects.link(ob)
    ob.location = location
    ob.rotation_euler = (Vector((0, 0, .1)) - ob.location).to_track_quat('-Z', 'Y').to_euler()

area('Warm_UpperLeft_Key', (-2, -3, 4), 350, (1.0, .94, .86), 3.0)
area('Cool_Fill', (3, -1, 2), 175, (.80, .88, 1.0), 4.0)
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.55, .60, .68, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .35
bpy.ops.object.camera_add()
camera = bpy.context.object
camera.name = 'Sprite_Orthographic_60deg'
studio_link(camera)
angle = math.radians(cfg['camera_elevation_degrees'])
target = Vector((0, 0, .10))
camera.location = target + Vector((0, -3 * math.cos(angle), 3 * math.sin(angle)))
camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
camera.data.type = 'ORTHO'
camera.data.ortho_scale = cfg['orthographic_scale']
scene.camera = camera
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 48
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.image_settings.color_depth = '8'
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.view_settings.exposure = 0
scene.view_settings.gamma = 1
scene.render.resolution_percentage = 100

bpy.ops.object.select_all(action='DESELECT')
asset.select_set(True)
bpy.context.view_layer.objects.active = asset
bpy.ops.export_scene.gltf(filepath=str(paths['glb']), export_format='GLB',
                          use_selection=True, export_animations=False, export_cameras=False,
                          export_lights=False, export_yup=True)
tex.pack()
scene.render.resolution_x = scene.render.resolution_y = cfg['sprite_size'] * cfg['supersample']
scene.render.filepath = str(paths['supersampled'])
bpy.ops.wm.save_as_mainfile(filepath=str(paths['blend']))
bpy.ops.render.render(write_still=True)

# Box downsample in premultiplied alpha, then unpremultiply, avoiding dark edges.
render = bpy.data.images.load(str(paths['supersampled']), check_existing=False)
w, h = render.size
pixels = np.array(render.pixels[:], dtype=np.float32).reshape(h, w, 4)
pixels[:, :, :3] *= pixels[:, :, 3:4]
s, k = cfg['sprite_size'], cfg['supersample']
small = pixels.reshape(s, k, s, k, 4).mean(axis=(1, 3))
small[:, :, :3] /= np.maximum(small[:, :, 3:4], 1e-8)
sprite = bpy.data.images.new('StonePickup_Sprite_32', width=s, height=s, alpha=True)
sprite.pixels.foreach_set(small.ravel())
sprite.filepath_raw = str(paths['sprite'])
sprite.file_format = 'PNG'
sprite.save()

scene.render.resolution_x = scene.render.resolution_y = 512
camera.data.ortho_scale = .8
scene.render.filepath = str(paths['large'])
bpy.ops.render.render(write_still=True)
metadata = dict(cfg)
metadata.update({'triangles': triangles, 'materials': 1, 'blender_actual': bpy.app.version_string,
                 'blender_build_hash': bpy.app.build_hash.decode(), 'render_engine': 'CYCLES_CPU',
                 'samples': 48, 'color_management': 'Standard / None / exposure 0 / gamma 1',
                 'godot_dimensions_xyz': [.55, .30, .40], 'animations': [],
                 'sha256': {key: hashlib.sha256(path.read_bytes()).hexdigest()
                            for key, path in paths.items() if key != 'metadata'},
                 'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
paths['metadata'].write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
print('STONE_EXPORT_OK', json.dumps({'triangles': triangles, 'files': [str(p) for p in paths.values()]}))
