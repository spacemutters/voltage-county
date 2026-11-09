"""Turns an image-to-3D car (tools/hf_car.py) into an art-pass draft, in Blender, with no screen.

Run:  blender -b --factory-startup --python tools/blender_car.py -- build/cars/<car id>
Reads model.glb; writes parts.fbx (one object per part, texture embedded), base_color.png and parts.json.

The model is one textured mesh with its paint drawn white. What comes out (object names follow the draft contract,
docs/art-pass-contracts.md):
  painted body panels_geom  the whole body, texture kept: the game tints it (SurfaceAppearance.Color), so white paint
                            takes the colour while glass, tyres and grilles stay dark (Dev/ArtPass "tinted" drafts)
  windows_geom              the dark, blue-tinted glass faces over the cabin, cut out of the body (tint still works)
  headlights_geom           a copy of the front lamp band (the art pass makes the lamps' glow from it)
  tail lights_geom          a copy of the red tail-lamp faces
The wheels are cut out of the body (a cylinder round each hub, the hubs found where the tyres touch the ground); the
art pass puts real spinning wheels in from the car's earlier Studio draft. The floor some models stand on is dropped,
and the body is kept under Roblox's 20,000 triangles a mesh.
"""
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
import numpy as np

folder = Path(sys.argv[sys.argv.index("--") + 1]).resolve()
BODY_MAX = 19500

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(folder / "model.glb"))
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
car = bpy.context.view_layer.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def tris(obj) -> int:
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def components(bm):
    seen: set[int] = set()
    for start in bm.faces:
        if start.index in seen:
            continue
        piece, stack = [], [start]
        seen.add(start.index)
        while stack:
            f = stack.pop()
            piece.append(f)
            for e in f.edges:
                for g in e.link_faces:
                    if g.index not in seen:
                        seen.add(g.index)
                        stack.append(g)
        yield piece


# 1. Drop the floor (a flat loose piece at the bottom, wider than the car) and loose edges and points.
bm = bmesh.new()
bm.from_mesh(car.data)
bm.faces.ensure_lookup_table()
zs = [v.co.z for v in bm.verts]
z_min, z_span = min(zs), max(zs) - min(zs)
floor = []
for piece in components(bm):
    vs = {v for f in piece for v in f.verts}
    pz = [v.co.z for v in vs]
    px = [v.co.x for v in vs]
    py = [v.co.y for v in vs]
    if max(pz) - min(pz) < 0.06 * z_span and min(pz) < z_min + 0.06 * z_span and \
            min(max(px) - min(px), max(py) - min(py)) > 1.8 * z_span:
        floor.extend(piece)
print(f"floor: {len(floor)} faces of {len(bm.faces)} (z span {z_span:.3f})")
bmesh.ops.delete(bm, geom=floor, context="FACES")
# Scraps of floor left over: anything outside the car's footprint (taken from its upper body), and flat faces looking
# straight up at the very bottom (the floor under the car).
bm.faces.ensure_lookup_table()
upper = [v.co for v in bm.verts if v.co.z > z_min + 0.3 * z_span]
fx = (min(p.x for p in upper), max(p.x for p in upper))
fy = (min(p.y for p in upper), max(p.y for p in upper))
mx, my = 0.03 * (fx[1] - fx[0]), 0.03 * (fy[1] - fy[0])
scraps = []
for f in bm.faces:
    c = f.calc_center_median()
    outside = c.x < fx[0] - mx or c.x > fx[1] + mx or c.y < fy[0] - my or c.y > fy[1] + my
    flat_bottom = f.normal.z > 0.9 and c.z < z_min + 0.05 * z_span
    if outside or flat_bottom:
        scraps.append(f)
print(f"floor scraps: {len(scraps)}")
bmesh.ops.delete(bm, geom=scraps, context="FACES")
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
bmesh.ops.delete(bm, geom=[e for e in bm.edges if not e.link_faces], context="EDGES")
bm.to_mesh(car.data)
bm.free()
car.data.update()
_zs = [v.co.z for v in car.data.vertices]
_xs = [v.co.x for v in car.data.vertices]
print(f"after floor: {len(car.data.vertices)} verts, x {min(_xs):.3f}..{max(_xs):.3f}, z {min(_zs):.3f}..{max(_zs):.3f}")

# 2. The texture, for colours at a face.
image = None
for slot in car.material_slots:
    tree = slot.material and slot.material.node_tree
    for node in (tree.nodes if tree else []):
        if node.type == "BSDF_PRINCIPLED":
            links = node.inputs["Base Color"].links
            if links and links[0].from_node.type == "TEX_IMAGE":
                image = links[0].from_node.image
if image is None:
    raise SystemExit("no base colour texture")
iw, ih = image.size
pixels = np.empty(iw * ih * 4, dtype=np.float32)
image.pixels.foreach_get(pixels)
pixels = pixels.reshape(ih, iw, 4)
image.filepath_raw = str(folder / "base_color.png")
image.file_format = "PNG"
image.save()

# 3. Decimate so the body (everything but the wheels) ends near BODY_MAX.
if tris(car) > BODY_MAX * 1.12:
    mod = car.modifiers.new("Decimate", "DECIMATE")
    mod.ratio = BODY_MAX * 1.12 / tris(car)
    bpy.ops.object.modifier_apply(modifier=mod.name)

bm = bmesh.new()
bm.from_mesh(car.data)
bm.faces.ensure_lookup_table()
uv = bm.loops.layers.uv.active
co = np.array([v.co[:] for v in bm.verts])
lo, hi = co.min(axis=0), co.max(axis=0)
L_AX = 0 if (hi[0] - lo[0]) >= (hi[1] - lo[1]) else 1
W_AX = 1 - L_AX
length, width, height = hi[L_AX] - lo[L_AX], hi[W_AX] - lo[W_AX], hi[2] - lo[2]
mid_l, mid_w = (hi[L_AX] + lo[L_AX]) / 2, (hi[W_AX] + lo[W_AX]) / 2

faces = []
for f in bm.faces:
    c = f.calc_center_median()
    u = sum(l[uv].uv.x for l in f.loops) / len(f.loops)
    v = sum(l[uv].uv.y for l in f.loops) / len(f.loops)
    rgb = pixels[min(ih - 1, max(0, int((v % 1) * ih))), min(iw - 1, max(0, int((u % 1) * iw))), :3]
    faces.append({
        "a": c[L_AX] - mid_l, "w": c[W_AX] - mid_w, "z": c[2] - lo[2], "rgb": rgb,
        "lum": float(0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]),
        "nz": float(f.normal.z),
        "na": float(f.normal[L_AX]),
        "nw": float(f.normal[W_AX]),
        "area": float(f.calc_area()),
    })

# 4. Hubs: where the body's underside touches the ground, front and back.
verts = co - np.array([0, 0, lo[2]])
along = verts[:, L_AX] - mid_l
side = verts[:, W_AX] - mid_w
low = verts[:, 2] < 0.06 * height
outer = np.abs(side) > 0.2 * width
contact = along[low & outer]
if len(contact) < 10:
    raise SystemExit("no tyre contact found")
# Front and rear tyres: split the contact points at the widest gap between them.
ordered = np.sort(contact)
gaps = np.diff(ordered)
split = float((ordered[np.argmax(gaps)] + ordered[np.argmax(gaps) + 1]) / 2)
print(f"size L {length:.3f} W {width:.3f} H {height:.3f}; contact {len(contact)} from {contact.min():.3f} to "
      f"{contact.max():.3f}, split {split:.3f}")
hubs = []
for group in (contact[contact < split], contact[contact >= split]):
    a0, a1 = np.percentile(group, 3), np.percentile(group, 97)
    centre = (a0 + a1) / 2
    # The tyre's height: the highest dark, outer, low-ish faces round that hub.
    near = [f for f in faces if abs(f["a"] - centre) < 0.12 * length and abs(f["w"]) > 0.25 * width and
            f["z"] < 0.5 * height and f["lum"] < 0.25]
    top = np.percentile([f["z"] for f in near], 95) if near else 0.3 * height
    radius = max(top / 2, 0.08 * length)
    print(f"hub at {centre:.3f}: tyre top {top:.3f}, radius {radius:.3f}, {len(near)} dark faces near")
    for sgn in (-1.0, 1.0):
        band = side[(np.sign(side) == sgn) & (np.abs(along - centre) < radius) & (verts[:, 2] < 2 * radius)]
        outer_w = float(np.percentile(np.abs(band), 99)) if len(band) else 0.5 * width
        hubs.append({"along": float(centre), "up": float(radius), "side": sgn, "radius": float(radius),
                     "outer": float(outer_w)})

tread = 0.32 * width


def wheel_at(f) -> int | None:
    for n, hub in enumerate(hubs):
        if np.sign(f["w"]) != hub["side"]:
            continue
        if abs(f["w"]) < hub["outer"] - tread:
            continue
        if math.hypot(f["a"] - hub["along"], f["z"] - hub["up"]) <= hub["radius"] * 1.15:
            return n
        if f["z"] < hub["up"] and abs(f["a"] - hub["along"]) <= hub["radius"] * 1.2:
            return n
    return None


def in_wheel(f) -> bool:
    for hub in hubs:
        if np.sign(f["w"]) != hub["side"]:
            continue
        if abs(f["w"]) < hub["outer"] - tread:
            continue
        if math.hypot(f["a"] - hub["along"], f["z"] - hub["up"]) <= hub["radius"] * 1.15:
            return True
        # Below the hub, everything over the tyre's length is tyre (its scraps hang under the arch otherwise).
        if f["z"] < hub["up"] and abs(f["a"] - hub["along"]) <= hub["radius"] * 1.2:
            return True
    return False


# 5. Front and back: the red tail lamps are at the back.
def is_red(f) -> bool:
    r, g, b = f["rgb"]
    return r > 0.22 and r > 2.2 * g and r > 2.2 * b


red = [f for f in faces if is_red(f) and not in_wheel(f) and abs(f["a"]) > 0.3 * length]
print(f"red faces: {len(red)}")
# The windscreen faces forward and up: the area-weighted lean of the raked, dark, upper glass says which end is the
# front (a rear window leans the other way, but it is smaller). Red tail lamps, when there are any, agree or decide.
lean = 0.0
for f in faces:
    if f["lum"] < 0.25 and f["z"] > 0.55 * height and 0.25 < f["nz"] < 0.9 and abs(f["nw"]) < 0.5 and \
            abs(f["a"]) < 0.35 * length:
        lean += f["na"] * f["area"]
print(f"windscreen lean {lean:.5f}")
if len(red) >= 6:
    back = float(np.sign(np.mean([f["a"] for f in red])))
elif lean != 0:
    back = -float(np.sign(lean))
else:
    back = -1.0
front = -back

wheel_idx, glass_idx, head_idx, tail_idx = [], [], [], []
for i, f in enumerate(faces):
    if in_wheel(f):
        wheel_idx.append(i)
        continue
    r, g, b = f["rgb"]
    toward_front = f["a"] * front
    # Glass: dark and a little blue, over the cabin, and steep (a windscreen or a side window, never a flat deck).
    if f["lum"] < 0.18 and b > r + 0.02 and f["z"] > 0.62 * height and abs(f["a"]) < 0.26 * length and \
            abs(f["nz"]) < 0.85:
        glass_idx.append(i)
    if is_red(f) and f["a"] * back > 0.3 * length:
        tail_idx.append(i)
    if toward_front > 0.36 * length and 0.25 * height < f["z"] < 0.65 * height and f["lum"] > 0.55 and \
            abs(f["w"]) > 0.12 * width:
        head_idx.append(i)

# Glass keeps only its big connected panes (windscreen, side windows): small dark islands are baked reflections.
glass_set = set(glass_idx)
islands, seen_glass = [], set()
for start in glass_idx:
    if start in seen_glass:
        continue
    island, stack = [], [start]
    seen_glass.add(start)
    while stack:
        i = stack.pop()
        island.append(i)
        for e in bm.faces[i].edges:
            for g in e.link_faces:
                if g.index in glass_set and g.index not in seen_glass:
                    seen_glass.add(g.index)
                    stack.append(g.index)
    islands.append(island)
total_area = sum(faces[i]["area"] for i in glass_idx) or 1
glass_idx = [i for island in islands if sum(faces[j]["area"] for j in island) > 0.004 * total_area for i in island]
print(f"glass islands: {len(islands)}, kept faces {len(glass_idx)}")

# The paint mask, drawn face by face into the texture's UV space (paint_mask.png, white = paint): bright grey faces,
# and dark faces on the upper body outside the cabin (reflections the image-to-3D baked into the paint, which must
# take the paint colour too). Glass, wheels, lamps and the low dark trim (grilles, sills, diffuser) stay out.
polys = []
glass_set = set(glass_idx)
head_set = set(head_idx)
wheel_set = set(wheel_idx)
paint_faces = 0
for i, f in enumerate(faces):
    if i in glass_set or i in wheel_set or i in head_set:
        continue
    r, g, b = f["rgb"]
    sat = max(r, g, b) - min(r, g, b)
    in_cabin = abs(f["a"]) < 0.3 * length and f["z"] > 0.55 * height
    bright = f["lum"] > 0.4 and sat < 0.22
    at_end = abs(f["a"]) > 0.4 * length
    low_trim = f["z"] < 0.22 * height or (at_end and f["z"] < 0.42 * height)
    reflection = f["lum"] <= 0.4 and not in_cabin and not low_trim and sat < 0.3 and f["nz"] > -0.3
    if not (bright or reflection):
        continue
    polys.append([[round(l[uv].uv.x % 1, 5), round(1 - (l[uv].uv.y % 1), 5)] for l in bm.faces[i].loops])
    paint_faces += 1
# tools/paint_mask.py draws these (UV, 0..1 from the top-left) into paint_mask.png.
(folder / "paint_polys.json").write_text(json.dumps({"size": [iw, ih], "polys": polys}), encoding="utf-8")
print(f"paint mask: {paint_faces} faces")
bm.free()


def piece(name: str, keep: set[int]):
    obj = car.copy()
    obj.data = car.data.copy()
    obj.name = name
    bpy.context.collection.objects.link(obj)
    pb = bmesh.new()
    pb.from_mesh(obj.data)
    pb.faces.ensure_lookup_table()
    bmesh.ops.delete(pb, geom=[f for j, f in enumerate(pb.faces) if j not in keep], context="FACES")
    bmesh.ops.delete(pb, geom=[v for v in pb.verts if not v.link_faces], context="VERTS")
    pb.to_mesh(obj.data)
    pb.free()
    return obj


everything = set(range(len(faces)))
# The glass stays in the body too (its texture already draws it dark); windows_geom is a thin overlay just above it
# that gives the real glass shine and takes the window tint.
body = everything - set(wheel_idx)
made = {
    "painted body panels_geom": piece("painted body panels_geom", body),
    "windows_geom": piece("windows_geom", set(glass_idx)),
    "headlights_geom": piece("headlights_geom", set(head_idx)),
}
if tail_idx:
    made["tail lights_geom"] = piece("tail lights_geom", set(tail_idx))
# The model's own wheels, one per hub (the art pass pairs wheels by position, never by name).
for n, hub in enumerate(hubs):
    keep = {i for i in wheel_idx if wheel_at(faces[i]) == n}
    end = "front" if hub["along"] * front > 0 else "rear"
    name = f"{end} {'left' if hub['side'] < 0 else 'right'} wheel_geom"
    if keep and name not in made:
        made[name] = piece(name, keep)
bpy.data.objects.remove(car)
glass_obj = made["windows_geom"]
offset = 0.003 * float(length)
for v in glass_obj.data.vertices:
    v.co += v.normal * offset
body_obj = made["painted body panels_geom"]
if tris(body_obj) > BODY_MAX:
    bpy.context.view_layer.objects.active = body_obj
    mod = body_obj.modifiers.new("Decimate", "DECIMATE")
    mod.ratio = BODY_MAX / tris(body_obj)
    bpy.ops.object.modifier_apply(modifier=mod.name)

# Smooth shading (split only at real creases), so paint reads as one surface instead of facets.
for obj in made.values():
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.fbx(
    filepath=str(folder / "parts.fbx"),
    use_selection=True,
    object_types={"MESH"},
    path_mode="COPY",
    embed_textures=True,
    axis_forward="-Z",
    axis_up="Y",
)
report = {
    "triangles": {name: tris(obj) for name, obj in made.items()},
    "faces": {"wheels": len(wheel_idx), "glass": len(glass_idx), "head": len(head_idx), "tail": len(tail_idx)},
    "hubs": hubs,
    "size": [float(length), float(width), float(height)],
    "front": front,
}
(folder / "parts.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
print("parts:", json.dumps(report["triangles"]), json.dumps(report["faces"]))
