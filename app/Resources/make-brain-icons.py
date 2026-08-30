"""Three bookmark-with-meaning candidates, drawn in code.

The intelligence has to arrive as geometry: a dot field on the ribbon, not a
brain. Everything is drawn 4x and downsampled, so edges stay Apple-crisp.
"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

SS = 4
C = 1024
TILE = 824
TILE_COL = "#1A1918"
ACCENT = (0x3A, 0xA9, 0x9F, 255)
DIM = (0x2E, 0x6D, 0x68, 255)   # the one intermediate tone

OUT = os.path.dirname(os.path.abspath(__file__))


def squircle(size, n=5.1):
    s = size * SS
    m = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(m)
    r = s / 2.0
    pts = []
    for i in range(2000):
        t = 2 * math.pi * i / 2000
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2.0 / n), ct)
        y = math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((r + x * r, r + y * r))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def bookmark(draw, x, y, w, h, notch=0.26, rad=0.10, fill=255):
    """Ribbon: rounded rect with a triangular notch cut from the bottom edge."""
    r = w * rad
    draw.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=fill)
    # notch: cut with background value 0 later by caller if needed
    return (x, y, w, h, notch)


def ribbon_mask(w, h, notch=0.28, rad=0.11):
    """Standalone L mask of one bookmark ribbon, at supersampled scale."""
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=w * rad, fill=255)
    nd = h * notch
    d.polygon([(0, h), (w / 2, h - nd), (w, h), (w, h + 2), (0, h + 2)], fill=0)
    return m


def punch_dots(mask, dots, w, h):
    d = ImageDraw.Draw(mask)
    for (cx, cy, r) in dots:
        px, py, pr = cx * w, cy * h, r * w
        d.ellipse([px - pr, py - pr, px + pr, py + pr], fill=0)


def punch_links(mask, links, dots, w, h, thick=0.030):
    d = ImageDraw.Draw(mask)
    for (a, b) in links:
        ax, ay, _ = dots[a]
        bx, by, _ = dots[b]
        d.line([(ax * w, ay * h), (bx * w, by * h)], fill=0, width=int(thick * w))


def compose(layers, name, shadow=True):
    """layers: list of (RGBA image at tile*SS scale). Bottom first."""
    ts = TILE * SS
    tile = Image.new("RGBA", (ts, ts), TILE_COL)
    for l in layers:
        tile = Image.alpha_composite(tile, l)
    tile = tile.resize((TILE, TILE), Image.LANCZOS)
    tile.putalpha(squircle(TILE))

    canvas = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    off = (C - TILE) // 2
    if shadow:
        sh = Image.new("RGBA", (C, C), (0, 0, 0, 0))
        sh.paste(Image.new("RGBA", (TILE, TILE), (0, 0, 0, 110)),
                 (off, off + 10), squircle(TILE))
        canvas = Image.alpha_composite(canvas, sh.filter(ImageFilter.GaussianBlur(18)))
    canvas.paste(tile, (off, off), tile)
    p = os.path.join(OUT, "candidates", name + "-1024.png")
    canvas.save(p)
    return p


def blank():
    ts = TILE * SS
    return Image.new("RGBA", (ts, ts), (0, 0, 0, 0))


def place(layer, mask, colour, cx, cy):
    """Paste a coloured mask centred on (cx, cy) in tile*SS coords."""
    col = Image.new("RGBA", mask.size, colour)
    layer.paste(col, (int(cx - mask.size[0] / 2), int(cy - mask.size[1] / 2)), mask)


# ---------------------------------------------------------------- candidates

GW = int(TILE * SS * 0.335)          # ribbon width
GH = int(GW / 0.655)                 # ribbon height
CXY = TILE * SS / 2


def cand_constellation():
    """A — the ribbon's surface is a star field: dots punched out, three linked."""
    m = ribbon_mask(GW, GH)
    dots = [(0.31, 0.19, 0.058), (0.69, 0.29, 0.058), (0.26, 0.45, 0.058),
            (0.63, 0.55, 0.086), (0.36, 0.68, 0.058)]
    punch_links(m, [(0, 1), (0, 2), (2, 3), (3, 4)], dots, GW, GH, thick=0.018)
    punch_dots(m, dots, GW, GH)
    l = blank()
    place(l, m, ACCENT, CXY, CXY - GH * 0.06)
    return compose([l], "a-constellation")


# The depth candidate is the one that was chosen, so its numbers are tuned rather
# than round. Two ghost ribbons sit close and dark (GHOST, well below the accent)
# so that at 16px they sink into the tile and the silhouette is a plain ribbon
# again — the stack is a bonus you only get above 32px, never a tax below it.
GHOST = (0x1E, 0x45, 0x43, 255)
DEPTH_SCALE = 1.08


def cand_depth():
    """B — ribbons in depth; the front one carries the linked dots."""
    gw, gh = int(GW * DEPTH_SCALE), int(GH * DEPTH_SCALE)
    back = blank()
    for (dx, sc, dy) in [(0.22, 0.88, 0.02), (0.12, 0.94, 0.01)]:
        place(back, ribbon_mask(int(gw * sc), int(gh * sc)), GHOST,
              CXY + gw * dx, CXY - gh * 0.06 + gh * dy)
    GW_, GH_ = GW, GH
    globals().update(GW=gw, GH=gh)
    m = ribbon_mask(gw, gh)
    dots = [(0.33, 0.24, 0.062), (0.70, 0.37, 0.062), (0.31, 0.54, 0.092)]
    punch_links(m, [(0, 1), (1, 2)], dots, gw, gh, thick=0.020)
    punch_dots(m, dots, gw, gh)
    front = blank()
    place(front, m, ACCENT, CXY - gw * 0.10, CXY - gh * 0.06)
    globals().update(GW=GW_, GH=GH_)
    return compose([back, front], "b-depth")


def cand_result():
    """C — dim ribbon carrying a field of dots; one dot wins, neighbours fade."""
    base = blank()
    place(base, ribbon_mask(GW, GH), DIM, CXY, CXY - GH * 0.06)

    top = blank()
    d = ImageDraw.Draw(top)
    ox = CXY - GW / 2
    oy = CXY - GH * 0.06 - GH / 2
    field = [(0.29, 0.15, 0.058, 255), (0.69, 0.23, 0.058, 255),
             (0.21, 0.37, 0.058, 255), (0.50, 0.45, 0.170, 255),
             (0.78, 0.51, 0.058, 255), (0.28, 0.63, 0.058, 255),
             (0.62, 0.71, 0.058, 255)]
    for (x, y, r, a) in field:
        px, py, pr = ox + x * GW, oy + y * GH, r * GW
        d.ellipse([px - pr, py - pr, px + pr, py + pr],
                  fill=(ACCENT[0], ACCENT[1], ACCENT[2], a))
    return compose([base, top], "c-result")


if __name__ == "__main__":
    for f in (cand_constellation, cand_depth, cand_result):
        print(f())
