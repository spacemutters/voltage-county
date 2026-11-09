"""Renders parts.fbx with each part in its own flat colour (paint white, glass blue, trim dark grey, head lamps
yellow, tail lamps red, wheels green/orange), to check tools/blender_car.py's split by eye.

Run:  blender -b --factory-startup --python tools/blender_parts_debug.py -- build/cars/<id>
Writes build/cars/<id>/debug_front.png and debug_rear.png.
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

folder = Path(sys.argv[sys.argv.index("--") + 1]).resolve()
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=str(folder / "parts.fbx"))
COLOURS = {
    "painted body panels": (0.9, 0.9, 0.9),
    "windows": (0.1, 0.3, 0.9),
    "trim": (0.12, 0.12, 0.12),
    "headlights": (1.0, 0.85, 0.1),
    "tail lights": (0.9, 0.05, 0.05),
}
lo = Vector((1e9,) * 3)
hi = Vector((-1e9,) * 3)
for o in bpy.context.scene.objects:
    if o.type != "MESH":
        continue
    name = o.name.split("_geom")[0]
    colour = COLOURS.get(name, (0.1, 0.8, 0.2) if "front" in name else (1.0, 0.5, 0.05))
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*colour, 1)
    o.data.materials.clear()
    o.data.materials.append(mat)
    for c in o.bound_box:
        p = o.matrix_world @ Vector(c)
        lo = Vector(map(min, lo, p))
        hi = Vector(map(max, hi, p))
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.color_type = "MATERIAL"
scene.render.resolution_x, scene.render.resolution_y = 768, 512
centre, size = (lo + hi) / 2, hi - lo
cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
scene.collection.objects.link(cam)
scene.camera = cam
reach = max(size) * 1.5
for name, angle in (("front", 40), ("rear", 220)):
    a = math.radians(angle)
    cam.location = centre + Vector((math.cos(a) * reach, math.sin(a) * reach, size.z * 1.6))
    cam.rotation_euler = (centre - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = str(folder / f"debug_{name}.png")
    bpy.ops.render.render(write_still=True)
print("debug rendered")
