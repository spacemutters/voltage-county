"""Renders a car model from three angles so it can be checked by eye, with no screen.

Run:  blender -b --factory-startup --python tools/blender_preview.py -- <model.glb> <out folder> [samples]
Writes <out>/view_front.png, view_side.png, view_rear.png and prints the triangle count and size.
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1 :]
model, out = Path(args[0]).resolve(), Path(args[1]).resolve()
samples = int(args[2]) if len(args) > 2 else 24
out.mkdir(parents=True, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
if model.suffix.lower() == ".fbx":
    bpy.ops.import_scene.fbx(filepath=str(model))
else:
    bpy.ops.import_scene.gltf(filepath=str(model))
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in meshes)

lo = Vector((1e9, 1e9, 1e9))
hi = Vector((-1e9, -1e9, -1e9))
for o in meshes:
    for corner in o.bound_box:
        p = o.matrix_world @ Vector(corner)
        lo = Vector(map(min, lo, p))
        hi = Vector(map(max, hi, p))
centre = (lo + hi) / 2
size = hi - lo
print(f"triangles {tris}, size {size.x:.2f} x {size.y:.2f} x {size.z:.2f}")

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = samples
scene.render.resolution_x, scene.render.resolution_y = 768, 512
world = bpy.data.worlds.new("World")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.82, 0.84, 0.88, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy = 3
sun.rotation_euler = (math.radians(50), 0, math.radians(30))
scene.collection.objects.link(sun)

cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
scene.collection.objects.link(cam)
scene.camera = cam
reach = max(size.x, size.y, size.z) * 1.6
for name, angle in (("front", 35), ("side", 90), ("rear", 215)):
    a = math.radians(angle)
    cam.location = centre + Vector((math.cos(a) * reach, math.sin(a) * reach, size.z * 0.9))
    direction = centre - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = str(out / f"view_{name}.png")
    bpy.ops.render.render(write_still=True)
print("rendered", out)
