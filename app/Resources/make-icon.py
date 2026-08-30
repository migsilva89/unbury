"""Rebuild a macOS icon from a generated symbol: extract the glyph, drop it on a
true Apple squircle. The model gives us the shape; the geometry is ours."""
import sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SS = 4  # supersample

def squircle(size, n=5.1):
    """Superellipse mask — the continuous-curvature shape, not a rounded rect."""
    s = size * SS
    m = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(m)
    pts = []
    steps = 2000
    r = s / 2.0
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2.0 / n), ct)
        y = math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((r + x * r, r + y * r))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)

def glyph_mask(path, teal=(0x3A, 0xA9, 0x9F), tol=90):
    """Alpha of everything that is the accent colour, trimmed to its bounds."""
    im = Image.open(path).convert("RGB")
    px = im.load()
    w, h = im.size
    m = Image.new("L", (w, h), 0)
    mp = m.load()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            d = abs(r - teal[0]) + abs(g - teal[1]) + abs(b - teal[2])
            mp[x, y] = 255 if d < tol * 3 else 0
    return m

def build(src, out, tile="#1A1918", accent="#3AA99F", glyph_frac=0.42, shadow=True):
    C = 1024
    tile_size = 824
    canvas = Image.new("RGBA", (C, C), (0, 0, 0, 0))

    sq = squircle(tile_size)
    tile_img = Image.new("RGBA", (tile_size, tile_size), tile)
    tile_img.putalpha(sq)

    g = glyph_mask(src)
    bbox = g.getbbox()
    g = g.crop(bbox)
    gw, gh = g.size
    target = int(C * glyph_frac)
    scale = target / max(gw, gh)
    g = g.resize((max(1, int(gw * scale)), max(1, int(gh * scale))), Image.LANCZOS)

    layer = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
    col = Image.new("RGBA", g.size, accent)
    ox = (tile_size - g.size[0]) // 2
    oy = (tile_size - g.size[1]) // 2
    gp = g.load()
    gw2, gh2 = g.size
    tot = my = 0
    for y in range(gh2):
        row = sum(gp[x, y] for x in range(gw2))
        tot += row; my += row * y
    if tot:
        oy += int(gh2 / 2 - my / tot)
    layer.paste(col, (ox, oy), g)
    tile_img = Image.alpha_composite(tile_img, layer)

    off = (C - tile_size) // 2
    if shadow:
        sh = Image.new("RGBA", (C, C), (0, 0, 0, 0))
        sh.paste(Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 110)), (off, off + 10), sq)
        sh = sh.filter(ImageFilter.GaussianBlur(18))
        canvas = Image.alpha_composite(canvas, sh)

    canvas.paste(tile_img, (off, off), tile_img)
    canvas.save(out)
    return out

if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], glyph_frac=float(sys.argv[3]) if len(sys.argv) > 3 else 0.42)
