"""Draws the pane-variety overlays for the city's glass (Config/City textures.paneVariety, Dev/City/Kit glass).

Each image is one tile of 4 bays x 4 floors: every cell is one pane, drawn inside a small margin so the curtain-wall
texture's mullions under it stay crisp. Most of the image is clear; a pane may carry a sky reflection, blinds part
way down, sheer curtains, a dark room or a warm lamp-lit room. Kit.glass lays it over the mullion texture at four times
the bay and floor size, so no two neighbouring panes match and the city's glass stops reading as one flat colour.

Usage:  python tools/facade_textures.py            -> assets/textures/pane_variety_a.png, pane_variety_b.png
The images are uploaded once through Studio (upload_image) and their ids go in Config/City textures.
"""
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "textures"
SIZE = 1024
CELLS = 4
MARGIN = 0.045  # of a cell, left clear on every side for the mullions underneath


def pane_box(ix: int, iy: int):
    cell = SIZE / CELLS
    m = cell * MARGIN
    return (ix * cell + m, iy * cell + m, (ix + 1) * cell - m, (iy + 1) * cell - m)


def reflection(layer: Image.Image, box, rng: random.Random):
    # A soft diagonal sheet of sky: brightest along one edge, fading across the pane.
    x0, y0, x1, y1 = (int(v) for v in box)
    w, h = x1 - x0, y1 - y0
    peak = rng.randint(85, 135)
    flip = rng.random() < 0.5
    sheet = Image.new("RGBA", (w, h))
    px = sheet.load()
    for y in range(h):
        for x in range(w):
            t = (x / w * 0.6 + y / h * 0.4)
            if flip:
                t = 1 - t
            a = int(peak * max(0.0, 1 - t * 1.6))
            px[x, y] = (255, 255, 255, a)
    layer.alpha_composite(sheet, (x0, y0))


def blinds(draw: ImageDraw.ImageDraw, box, rng: random.Random):
    x0, y0, x1, y1 = box
    drop = y0 + (y1 - y0) * rng.uniform(0.25, 0.95)
    shade = rng.choice([(236, 232, 222), (214, 214, 210), (196, 190, 178)])
    draw.rectangle((x0, y0, x1, drop), fill=shade + (215,))
    slat = max(3.0, (y1 - y0) / 34)
    y = y0 + slat
    while y < drop - 1:
        draw.line((x0, y, x1, y), fill=(120, 116, 108, 70), width=1)
        y += slat
    draw.rectangle((x0, drop - 3, x1, drop), fill=(150, 144, 132, 200))  # the bottom rail


def curtains(draw: ImageDraw.ImageDraw, box, rng: random.Random):
    x0, y0, x1, y1 = box
    w = x1 - x0
    tint = rng.choice([(246, 240, 226), (232, 226, 212), (240, 232, 236)])
    for side in (0, 1):
        reach = w * rng.uniform(0.18, 0.46)
        a, b = (x0, x0 + reach) if side == 0 else (x1 - reach, x1)
        draw.rectangle((a, y0, b, y1), fill=tint + (195,))
        folds = max(3, int(reach / 9))
        for k in range(1, folds):
            fx = a + (b - a) * k / folds
            draw.line((fx, y0, fx, y1), fill=(170, 160, 146, 60), width=2)


def dark_room(draw: ImageDraw.ImageDraw, box, rng: random.Random):
    x0, y0, x1, y1 = box
    draw.rectangle(box, fill=(8, 12, 16, rng.randint(70, 110)))
    # The ceiling and its light line read through the glass.
    ceiling = y0 + (y1 - y0) * 0.14
    draw.rectangle((x0, y0, x1, ceiling), fill=(28, 32, 36, 90))
    draw.line((x0 + (x1 - x0) * 0.2, ceiling + 2, x1 - (x1 - x0) * 0.2, ceiling + 2), fill=(200, 210, 220, 60), width=2)


def warm_room(draw: ImageDraw.ImageDraw, box, rng: random.Random):
    x0, y0, x1, y1 = box
    draw.rectangle(box, fill=(255, 214, 160, rng.randint(60, 90)))
    ceiling = y0 + (y1 - y0) * 0.12
    draw.rectangle((x0, y0, x1, ceiling), fill=(255, 236, 200, 70))


def spandrel(draw: ImageDraw.ImageDraw, box):
    # An opaque panel band at the foot of a pane: the floor slab's cover, a little darker than the glass.
    x0, y0, x1, y1 = box
    top = y1 - (y1 - y0) * 0.16
    draw.rectangle((x0, top, x1, y1), fill=(30, 36, 42, 120))


def make(name: str, seed: int, weights):
    rng = random.Random(seed)
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    kinds = [k for k, _ in weights]
    odds = [w for _, w in weights]
    for iy in range(CELLS):
        for ix in range(CELLS):
            box = pane_box(ix, iy)
            kind = rng.choices(kinds, odds)[0]
            draw = ImageDraw.Draw(layer)
            if kind == "reflection":
                reflection(layer, box, rng)
            elif kind == "blinds":
                blinds(draw, box, rng)
            elif kind == "curtains":
                curtains(draw, box, rng)
            elif kind == "dark":
                dark_room(draw, box, rng)
            elif kind == "warm":
                warm_room(draw, box, rng)
            if name.endswith("b"):
                spandrel(ImageDraw.Draw(layer), box)
    # A whisper of softness so the edges don't alias at a distance.
    layer = layer.filter(ImageFilter.GaussianBlur(0.6))
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"pane_variety_{name}.png"
    layer.save(path, optimize=True)
    return path


if __name__ == "__main__":
    # a: offices and condos (more reflection and blinds); b: residential (curtains, lit rooms, a spandrel band).
    print(make("a", 7, [("clear", 30), ("reflection", 26), ("blinds", 22), ("dark", 16), ("warm", 6)]))
    print(make("b", 11, [("clear", 22), ("reflection", 18), ("blinds", 18), ("curtains", 20), ("dark", 12), ("warm", 10)]))
