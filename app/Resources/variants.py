"""Three treatments of the same generated symbol."""
from compose import build
# 1 — teal mark on a near-black tile, the sober Dock citizen
build("A.png", "out/opt1.png", tile="#1A1918", accent="#3AA99F", glyph_frac=0.46)
# 2 — inverted: the tile is the accent, the mark is cut out of it
build("A.png", "out/opt2.png", tile="#3AA99F", accent="#100F0F", glyph_frac=0.46)
# 3 — the aperture, same sober tile
build("B.png", "out/opt3.png", tile="#1A1918", accent="#3AA99F", glyph_frac=0.48)
print("ok")
