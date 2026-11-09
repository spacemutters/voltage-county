"""Draws the ground overlays (Config/MapLayout zone groundTexture; MapBuilder ground).

concrete_slabs.png: one tile of 4 x 4 poured concrete slabs for downtown's pale ground. Mostly transparent: dark saw-cut
joints, each slab a shade lighter or darker than the next, soft rain and oil stains, a few hairline cracks and the odd
patched rectangle. Laid over the ground part's own Concrete, tinted white, so the ground keeps its colour and gains the
wear a real Miami sidewalk-to-kerb plaza has.

Usage:  python tools/ground_textures.py  -> assets/textures/concrete_slabs.png
"""
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "textures"
SIZE = 1024
SLABS = 4


def concrete(seed: int = 5) -> Path:
    rng = random.Random(seed)
    cell = SIZE / SLABS
    base = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(base)

    # Each slab a little lighter or darker: poured on different days.
    for iy in range(SLABS):
        for ix in range(SLABS):
            box = (ix * cell, iy * cell, (ix + 1) * cell, (iy + 1) * cell)
            if rng.random() < 0.5:
                draw.rectangle(box, fill=(255, 255, 255, rng.randint(8, 22)))
            else:
                draw.rectangle(box, fill=(40, 36, 30, rng.randint(8, 24)))

    # Soft stains: rain streaks, drips and the odd oil spot, blurred.
    stains = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stains)
    for _ in range(38):
        x, y = rng.uniform(0, SIZE), rng.uniform(0, SIZE)
        r = rng.uniform(10, 70)
        a = rng.randint(14, 40)
        tone = rng.choice([(50, 44, 36), (70, 64, 52), (30, 30, 32)])
        sd.ellipse((x - r, y - r * rng.uniform(0.5, 1), x + r, y + r * rng.uniform(0.5, 1)), fill=tone + (a,))
    stains = stains.filter(ImageFilter.GaussianBlur(14))
    base.alpha_composite(stains)

    draw = ImageDraw.Draw(base)
    # A patched rectangle or two: a newer, paler pour.
    for _ in range(2):
        ix, iy = rng.randrange(SLABS), rng.randrange(SLABS)
        x0 = ix * cell + rng.uniform(20, cell * 0.4)
        y0 = iy * cell + rng.uniform(20, cell * 0.4)
        w, h = rng.uniform(50, 110), rng.uniform(40, 90)
        draw.rectangle((x0, y0, x0 + w, y0 + h), fill=(255, 252, 244, 26))

    # Hairline cracks: a few wandering lines.
    for _ in range(7):
        x, y = rng.uniform(0, SIZE), rng.uniform(0, SIZE)
        angle = rng.uniform(0, math.tau)
        points = [(x, y)]
        for _ in range(rng.randint(6, 14)):
            angle += rng.uniform(-0.6, 0.6)
            step = rng.uniform(8, 22)
            x, y = x + math.cos(angle) * step, y + math.sin(angle) * step
            points.append((x, y))
        draw.line(points, fill=(40, 36, 32, 90), width=2)

    # The saw-cut joints between slabs: dark, a light lip on one side. Drawn on the tile's edges too, half each side, so
    # the joints line up across tiles.
    for k in range(SLABS + 1):
        p = round(k * cell)
        for q in (p - 2, p + 1):
            draw.line((q, 0, q, SIZE), fill=(34, 32, 30, 150), width=2)
            draw.line((0, q, SIZE, q), fill=(34, 32, 30, 150), width=2)
        draw.line((p + 3, 0, p + 3, SIZE), fill=(255, 255, 255, 40), width=1)
        draw.line((0, p + 3, SIZE, p + 3), fill=(255, 255, 255, 40), width=1)

    base = base.filter(ImageFilter.GaussianBlur(0.5))
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "concrete_slabs.png"
    base.save(path, optimize=True)
    return path


if __name__ == "__main__":
    print(concrete())
