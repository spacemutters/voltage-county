"""Makes the palm templates' leaves feathery (docs/city/SCENERY.md section 1).

Studio's mesh generator draws palm fronds as broad paddles (they read as banana leaves). This tool keeps the generated
mesh and cuts its leaves into leaflets through the texture's alpha instead: for every leaf triangle it rasterises the
triangle in UV space and, per texel, works out where that texel sits on its frond in 3D (how far out from the crown,
how far either side of the frond's midrib), then keeps the texel only on a leaflet (a chevron of narrow, pointed
leaflets for a feather palm; stiff radiating slits for a fan palm). The MeshPart then wears the result as a
SurfaceAppearance ColorMap with AlphaMode Transparency and the part's Transparency 0, which Roblox renders as a cutout
(opaque, depth-sorted, no blending cost).

Steps (the data folder defaults to build/palms, which git ignores):
  1. python tools/palm_leaflets.py serve            serves the folder on 127.0.0.1:8771
  2. in Studio, execute_luau tools/PalmExport.luau  (edit its list first) - POSTs each mesh's vertices, faces and
     UVs (<key>.json) and its 1024x1024 texture (<key>.hex) to the server
  3. python tools/palm_leaflets.py cut <key> <pinnate|fan> [option=value ...]   writes out/<name>.png
  4. upload_image http://127.0.0.1:8771/<name>.png (Studio connector), then give the template a SurfaceAppearance with
     that ColorMap and AlphaMode Transparency

Options: name (output file), centre=x,y,z (where the fronds spring from, mesh space; by default found from the trunk),
period (studs between leaflets, or radians between fan slits), duty (share of each period kept), sweep (how far
leaflets angle toward the tip), taper (how much they narrow toward their tips), rib (half-width of the midrib kept
solid), petiole (bare stalk length at the base), fruit=keep|drop|green (a fruit cluster under the crown: kept, cut away,
or repainted as the green crownshaft it hides), shaft=r,g,b (that green).

The three templates in the place (2026-10-26):
  royal    cut royal pinnate period=0.6 sweep=0.9 taper=0.6 fruit=green shaft=70,104,62 centre=0.02,3.47,-0.03
  coconut  cut coconut pinnate period=0.55 sweep=0.9 taper=0.6 centre=2.0,3.0,0.5
  sabal    cut sabal fan period=0.14 duty=0.62 petiole=1.6 centre=-0.3,1.5,0
Needs numpy, scipy and Pillow.
"""

import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.environ.get("PALM_DIR", os.path.join(HERE, "..", "build", "palms"))
W = H = 1024


# ---------------------------------------------------------------------------------------------------------------
# The data a Studio export leaves in DIR/in
# ---------------------------------------------------------------------------------------------------------------


def load(key):
    data = json.load(open(os.path.join(DIR, "in", key + ".json")))
    pos = np.array([[float(c) for c in p.split(",")] for p in data["pos"]])
    faces, uvs = [], []
    for f in data["faces"]:
        corners = [c.split(",") for c in f.split(";")]
        faces.append([int(c[0]) for c in corners])
        uvs.append([[float(c[1]), float(c[2])] for c in corners])
    raw = open(os.path.join(DIR, "in", key + ".hex"), "rb").read()
    tex = np.frombuffer(bytes.fromhex(raw.decode()), dtype=np.uint8).reshape(H, W, 4)
    return data, pos, np.array(faces), np.array(uvs), tex


# ---------------------------------------------------------------------------------------------------------------
# The palm's shape: its trunk, which faces are leaves, where the fronds spring from
# ---------------------------------------------------------------------------------------------------------------


def surface_points(tri, per=12):
    """Points spread over every triangle (a dense cloud even where the trunk has few vertices)."""
    steps = [(i / per, j / per) for i in range(per + 1) for j in range(per + 1 - i)]
    return np.concatenate([tri[:, 0] * (1 - a - b) + tri[:, 1] * a + tri[:, 2] * b for a, b in steps])


def trunk_line(pos, slice_h=0.5):
    """The trunk's centre line from the foot up, slice by slice, until the crown spreads out."""
    y0, y1 = pos[:, 1].min(), pos[:, 1].max()
    foot = pos[:, 1] < y0 + 0.02 * (y1 - y0)
    centre = pos[foot][:, [0, 2]].mean(0)
    radius = max(np.ptp(pos[foot][:, 0]), np.ptp(pos[foot][:, 2])) / 2
    pts, radii = [(centre[0], y0, centre[1])], [radius]
    y = y0 + slice_h
    while y < y1:
        xz = pos[(pos[:, 1] >= y - slice_h / 2) & (pos[:, 1] < y + slice_h / 2)][:, [0, 2]]
        if len(xz) == 0:
            y += slice_h
            continue
        near = xz[np.linalg.norm(xz - centre, axis=1) < radius * 2.2 + 0.6]
        if len(near) < 3:
            break
        spread = np.linalg.norm(near - near.mean(0), axis=1).max()
        if np.linalg.norm(xz - centre, axis=1).max() > radius * 4 + 2:
            break  # the crown begins
        centre = near.mean(0) * 0.7 + centre * 0.3
        radius = max(0.25, 0.6 * radius + 0.4 * spread)
        pts.append((centre[0], y, centre[1]))
        radii.append(radius)
        y += slice_h
    return np.array(pts), np.array(radii)


def dist_to_line(p, line):
    best = np.full(len(p), np.inf)
    for a, b in zip(line[:-1], line[1:]):
        ab = b - a
        t = np.clip(((p - a) @ ab) / max(ab @ ab, 1e-9), 0, 1)
        best = np.minimum(best, np.linalg.norm(p - (a + t[:, None] * ab), axis=1))
    return best


def is_green(rgb):
    """Leafy: a yellow-green to blue-green hue (pale and grey-green leaves included), not brown, orange or grey."""
    c = rgb.astype(float) / 255
    mx, mn = c.max(-1), c.min(-1)
    delta = np.maximum(mx - mn, 1e-6)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    hue = np.where(
        mx == r,
        (60 * ((g - b) / delta)) % 360,
        np.where(mx == g, 60 * ((b - r) / delta) + 120, 60 * ((r - g) / delta) + 240),
    )
    return (hue > 48) & (hue < 190) & (delta / np.maximum(mx, 1e-6) > 0.06)


def crown_centre(tri, leaf, top, rounds=4):
    pts = surface_points(tri[leaf], 6)
    c = np.array(top, dtype=float)
    for _ in range(rounds):
        near = pts[(np.linalg.norm(pts[:, [0, 2]] - c[[0, 2]], axis=1) < 2.5) & (pts[:, 1] > top[1] - 1)]
        if len(near) < 10:
            break
        c[0], c[2] = near[:, 0].mean(), near[:, 2].mean()
        c[1] = max(top[1], np.percentile(near[:, 1], 70))
    return c


# ---------------------------------------------------------------------------------------------------------------
# The cut
# ---------------------------------------------------------------------------------------------------------------


def cut(key, style, opts):
    period = float(opts.get("period", 0.75))
    duty = float(opts.get("duty", 0.6))
    sweep = float(opts.get("sweep", 0.7))
    rib = float(opts.get("rib", 0.12))
    petiole = float(opts.get("petiole", 1.2))
    taper = float(opts.get("taper", 0.6))
    fruit_mode = opts.get("fruit", "keep")

    _, pos, faces, uvs, tex = load(key)
    line, radii = trunk_line(surface_points(pos[faces]))
    top, r_trunk = line[-1], float(np.median(radii))
    tri = pos[faces]
    cen = tri.mean(1)
    uvpx = uvs * np.array([W, H])  # U right, V down: the texture's pixel rows
    uvc = np.clip(uvpx.mean(1).astype(int), 0, W - 1)
    col = tex[uvc[:, 1], uvc[:, 0], :3]
    d_axis = dist_to_line(cen, line)
    leaf = (d_axis > r_trunk * 1.6 + 0.4) & is_green(col) & (cen[:, 1] > pos[:, 1].min() + 0.3 * np.ptp(pos[:, 1]))

    # Fronds: the leaf faces grouped by UV island (vertex ids are split at UV seams).
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for fi in np.nonzero(leaf)[0]:
        a, b, c = faces[fi]
        parent[find(b)] = find(a)
        parent[find(c)] = find(a)
    group = np.array([find(faces[fi][0]) if leaf[fi] else -1 for fi in range(len(faces))])
    groups = {g: np.nonzero(group == g)[0] for g in set(group.tolist()) if g >= 0}
    C = (
        np.array([float(v) for v in opts["centre"].split(",")])
        if "centre" in opts
        else crown_centre(tri, leaf, top)
    )
    print(f"{key}: trunk to y={top[1]:.2f}, r={r_trunk:.2f}; {leaf.sum()} leaf faces in {len(groups)} fronds; crown {C}")

    alpha = np.full((H, W), 255, dtype=np.uint8)
    leafmask = np.zeros((H, W), dtype=bool)
    solidmask = np.zeros((H, W), dtype=bool)
    ribmask = np.zeros((H, W), dtype=bool)
    fruitmask = np.zeros((H, W), dtype=bool)

    def raster(fi):
        p = uvpx[fi]
        x0, y0 = np.maximum(np.floor(p.min(0) - 1).astype(int), 0)
        x1, y1 = np.minimum(np.ceil(p.max(0) + 1).astype(int), W - 1)
        if x1 < x0 or y1 < y0:
            return None
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        v0, v1 = p[1] - p[0], p[2] - p[0]
        den = v0[0] * v1[1] - v1[0] * v0[1]
        if abs(den) < 1e-9:
            return None
        dx, dy = xs - p[0][0], ys - p[0][1]
        b1 = (dx * v1[1] - v1[0] * dy) / den
        b2 = (v0[0] * dy - dx * v0[1]) / den
        b0 = 1 - b1 - b2
        inside = (b0 >= -0.02) & (b1 >= -0.02) & (b2 >= -0.02)
        if not inside.any():
            return None
        return xs[inside].astype(int), ys[inside].astype(int), b0[inside], b1[inside], b2[inside]

    fruit = np.zeros(len(faces), dtype=bool)
    if fruit_mode in ("drop", "green"):
        fruit = (~leaf) & (d_axis > r_trunk * 1.15 + 0.2) & (col[:, 0] > col[:, 1] * 1.05) & (cen[:, 1] > top[1] - 6)
    for fi in np.nonzero(~leaf & ~fruit)[0]:
        r = raster(fi)
        if r:
            solidmask[r[1], r[0]] = True
    for fi in np.nonzero(fruit)[0]:
        r = raster(fi)
        if r and fruit_mode == "green":
            solidmask[r[1], r[0]] = True
            fruitmask[r[1], r[0]] = True
        elif r:
            leafmask[r[1], r[0]] = True
            alpha[r[1], r[0]] = 0

    rng = np.random.default_rng(7)
    for members in groups.values():
        verts = tri[members].reshape(-1, 3)
        rel = verts - C
        far = rel[np.argmax(np.linalg.norm(rel, axis=1))]
        az = np.array([far[0], 0, far[2]])
        az = az / np.linalg.norm(az) if np.linalg.norm(az) > 1e-3 else np.array([1.0, 0, 0])
        n = np.array([-az[2], 0, az[0]])  # across the frond, level
        wmax = max(float(np.percentile(np.abs(rel @ n), 95)), 0.3)
        phase = rng.random()  # so neighbouring fronds' leaflets don't line up
        for fi in members:
            r = raster(fi)
            if not r:
                continue
            xs, ys, b0, b1, b2 = r
            P = b0[:, None] * tri[fi][0] + b1[:, None] * tri[fi][1] + b2[:, None] * tri[fi][2]
            rel = P - C
            w = rel @ n  # either side of the midrib
            t = np.sqrt(np.maximum((rel**2).sum(1) - w**2, 0))  # out along the frond
            aw = np.abs(w)
            if style == "pinnate":
                s = (t - sweep * aw) / period + phase
                local = duty * (1 - taper * np.clip(aw / wmax, 0, 1) ** 1.6)
                isrib = aw < rib
                keep = ((s - np.floor(s) < local) & (t > petiole * 0.6)) | isrib
            else:
                a = np.arctan2(w, np.maximum(t, 1e-3)) / period + phase
                isrib = np.zeros(len(xs), dtype=bool)
                keep = (a - np.floor(a) < duty) | (t < petiole)
            leafmask[ys, xs] = True
            alpha[ys, xs] = np.where(keep, 255, 0)
            ribmask[ys, xs] |= isrib

    # Texels no triangle covers: clear near leaves, solid near the rest, so filtering at an island's edge never draws
    # the old paddle's outline round the leaflets.
    uncovered = ~(leafmask | solidmask)
    nearer_leaf = ndimage.distance_transform_edt(~leafmask) < ndimage.distance_transform_edt(~solidmask)
    alpha[uncovered & nearer_leaf] = 0
    alpha[solidmask & ~leafmask] = 255

    out = tex.copy()
    rgb = out[..., :3].astype(float)
    rgb[ribmask] = rgb[ribmask] * 0.55 + np.array([196, 204, 128.0]) * 0.45
    if fruitmask.any():
        lum = rgb[fruitmask].mean(1)
        shade = np.clip(lum / max(lum.mean(), 1), 0.85, 1.12) ** 0.6
        green = np.array([float(v) for v in opts.get("shaft", "92,142,78").split(",")])
        rgb[fruitmask] = green[None, :] * shade[:, None]
    out[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    out[..., 3] = alpha
    os.makedirs(os.path.join(DIR, "out"), exist_ok=True)
    name = opts.get("name", f"{key}_leaflets")
    Image.fromarray(out, "RGBA").save(os.path.join(DIR, "out", name + ".png"), optimize=True)
    print("wrote", os.path.normpath(os.path.join(DIR, "out", name + ".png")))


# ---------------------------------------------------------------------------------------------------------------
# The localhost server Studio posts to and upload_image reads from
# ---------------------------------------------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        name = os.path.basename(q.get("name", ["blob"])[0])
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        os.makedirs(os.path.join(DIR, "in"), exist_ok=True)
        with open(os.path.join(DIR, "in", name), "ab" if q.get("mode", ["a"])[0] == "a" else "wb") as f:
            f.write(body)
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        path = os.path.join(DIR, "out", os.path.basename(urllib.parse.urlparse(self.path).path))
        if not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        data = open(path, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "serve":
        print(f"serving {os.path.normpath(DIR)} on http://127.0.0.1:8771")
        ThreadingHTTPServer(("127.0.0.1", 8771), Handler).serve_forever()
    elif len(sys.argv) >= 4 and sys.argv[1] == "cut":
        cut(sys.argv[2], sys.argv[3], dict(a.split("=", 1) for a in sys.argv[4:]))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
