"""Draws the scenery's overlay images (docs/city/SCENERY.md, Config/CityScenery) into assets/city/.

White with alpha, so a Texture's Color3 tints them. Each tile is one repeat of the pattern:
  crosswalk_zebra.png   zebra bars: the left half of the tile white, the right half clear (bars along V)
  balustrade_x.png      a pierced balustrade panel: posts at the side edges, rails top and bottom, an X between
  water_ripple.png      thin glinting lines for the water's top (a light chop), faint and tileable

Run: python tools/draw_scenery_overlays.py   (needs Pillow). Upload them as TECH.md's appendix says.
"""

import math
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "city")
WHITE = (255, 255, 255, 255)


def zebra(n=256):
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(img).rectangle([0, 0, n // 2 - 1, n - 1], fill=WHITE)
    return img


def balustrade(n=256, line=22):
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    half = line // 2
    # Posts: half a post at each side edge, so tiles join into whole posts.
    d.rectangle([0, 0, half - 1, n - 1], fill=WHITE)
    d.rectangle([n - half, 0, n - 1, n - 1], fill=WHITE)
    # Rails along the top and bottom.
    d.rectangle([0, 0, n - 1, line - 1], fill=WHITE)
    d.rectangle([0, n - line, n - 1, n - 1], fill=WHITE)
    # The X.
    d.line([(0, 0), (n - 1, n - 1)], fill=WHITE, width=line)
    d.line([(0, n - 1), (n - 1, 0)], fill=WHITE, width=line)
    return img


def ripple(n=256):
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    tau = 2 * math.pi
    for y in range(n):
        for x in range(n):
            u, v = x / n, y / n
            # Two wavy wave trains (whole periods across the tile, so it repeats without a seam); bright thin lines
            # where they cross zero, like sun glinting on a light chop.
            a = math.sin(tau * (2 * u + v) + 0.9 * math.sin(tau * (u - 2 * v)))
            b = math.sin(tau * (3 * v - u) + 0.8 * math.sin(tau * (3 * u + v)))
            line = max(0.0, 1 - abs(a + b) / 0.22)
            px[x, y] = (255, 255, 255, int(255 * line * 0.7))
    return img


def glints(n=256, count=150, seed=11):
    """Sun glinting on a light chop: short, thin, soft-ended streaks lying mostly across the tile (U), scattered and
    tileable (each streak wraps round the edges). Reads as sparkle on open water, not a pool's caustic net."""
    import random

    rnd = random.Random(seed)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    for _ in range(count):
        cx, cy = rnd.random() * n, rnd.random() * n
        length = rnd.uniform(5, 16)
        thick = rnd.uniform(0.7, 1.5)
        angle = rnd.uniform(-0.35, 0.35)
        strength = rnd.uniform(0.45, 1.0)
        ux, uy = math.cos(angle), math.sin(angle)
        r = int(length / 2 + 3)
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                along = dx * ux + dy * uy
                across = -dx * uy + dy * ux
                if abs(along) > length / 2:
                    continue
                fade = 1 - (2 * along / length) ** 2  # soft ends
                a = max(0.0, 1 - abs(across) / thick) * fade * strength
                if a <= 0:
                    continue
                x, y = int(cx + dx) % n, int(cy + dy) % n
                old = px[x, y][3] / 255
                px[x, y] = (255, 255, 255, int(255 * min(1.0, old + a * (1 - old))))
    return img


def ramp(w=256, h=8):
    """A fade from clear (U = 0) to solid white (U = 1), eased at both ends: laid across a water band and tinted with
    the next band's colour, it blends one band into the next with no hard line."""
    img = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    px = img.load()
    for x in range(w):
        t = x / (w - 1)
        a = t * t * (3 - 2 * t)
        for y in range(h):
            px[x, y] = (255, 255, 255, int(round(255 * a)))
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, image in (
        ("crosswalk_zebra.png", zebra()),
        ("balustrade_x.png", balustrade()),
        ("water_ripple.png", ripple()),
        ("water_glints.png", glints()),
        ("water_ramp.png", ramp()),
    ):
        path = os.path.join(OUT, name)
        image.save(path)
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
