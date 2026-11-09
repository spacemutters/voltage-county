"""Saves the textures packed in a GLB as PNG files next to it (for checking and for Roblox).

Run:  blender -b --factory-startup --python tools/blender_textures.py -- <folder with model.glb>
"""
import sys
from pathlib import Path

import bpy

folder = Path(sys.argv[sys.argv.index("--") + 1]).resolve()
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(folder / "model.glb"))
for image in bpy.data.images:
    if image.size[0] == 0:
        continue
    image.filepath_raw = str(folder / f"{image.name}.png")
    image.file_format = "PNG"
    image.save()
    print("saved", image.filepath_raw)
