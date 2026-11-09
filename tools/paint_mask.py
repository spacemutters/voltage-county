"""Makes a tintable car texture from an image-to-3D car's base colour (tools/blender_car.py writes base_color.png).

Writes, next to it:
  paint_overlay.png  the base colour with alpha = how much of each pixel is NOT paint. In a SurfaceAppearance with
                     AlphaMode Overlay, the paint (white, unsaturated, bright) shows the car's Color and everything
                     else (glass, tyres, grilles, lamps) keeps its texture. The paint keeps a little of its baked shading.
  roughness.png      glossy paint (low), satin trim (higher): the engine's own reflections do the rest.
  metalness.png      black (paint is not metal here; chrome trim reads through its texture).
Usage:  python tools/paint_mask.py build/cars/<car id>
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

folder = Path(sys.argv[1])
# blender_car.py's paint faces (UV polygons) become paint_mask.png.
if (folder / "paint_polys.json").exists():
    data = json.loads((folder / "paint_polys.json").read_text(encoding="utf-8"))
    w, h = data["size"]
    drawn = Image.new("L", (w, h), 0)
    pen = ImageDraw.Draw(drawn)
    for poly in data["polys"]:
        pen.polygon([(u * w, v * h) for u, v in poly], fill=255)
    drawn.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(1.2)).save(folder / "paint_mask.png")
rgb = np.asarray(Image.open(folder / "base_color.png").convert("RGB")).astype(np.float32) / 255
lum = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
sat = rgb.max(axis=2) - rgb.min(axis=2)


def ramp(x, a, b):
    return np.clip((x - a) / (b - a), 0, 1)


# Paint: blender_car.py's face-by-face mask when there is one (it knows where the glass and the baked reflections
# are); otherwise bright and nearly grey. Soft edges so the tint doesn't stop on a hard line.
if (folder / "paint_mask.png").exists():
    paint = np.asarray(Image.open(folder / "paint_mask.png").convert("L")).astype(np.float32) / 255
    # Inside the mask, keep the texture's own shading a little: dark baked reflections tint fully, highlights stay.
    paint = paint * (0.85 + 0.15 * ramp(lum, 0.3, 0.7))
else:
    paint = ramp(lum, 0.42, 0.62) * (1 - ramp(sat, 0.10, 0.22))
    paint_img = Image.fromarray((paint * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.5))
    paint = np.asarray(paint_img).astype(np.float32) / 255
# Keep a share of the baked shading on the paint: the overlay shows Color where alpha is 0, so a little alpha keeps the
# texture's light and dark folded into it.
alpha = np.clip(1 - paint * 0.86, 0, 1)
rgba = np.dstack([rgb, alpha])
Image.fromarray((rgba * 255).astype(np.uint8), "RGBA").save(folder / "paint_overlay.png", optimize=True)

rough = 0.62 - 0.44 * paint  # paint about 0.18, trim about 0.62
Image.fromarray((rough * 255).astype(np.uint8)).convert("RGB").save(folder / "roughness.png", optimize=True)
Image.new("RGB", (64, 64), (0, 0, 0)).save(folder / "metalness.png")
print(f"paint share {paint.mean():.2f}")
