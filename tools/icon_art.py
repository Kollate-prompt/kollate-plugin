#!/usr/bin/env python3
"""Regenerate ICON_ART_PACKED in hooks/kollate.py from a favicon PNG.
usage: python3 tools/icon_art.py path/to/favicon-32x32.png
Prints the new packed constant; paste it over ICON_ART_PACKED."""
import base64, sys, zlib
from PIL import Image
img = Image.open(sys.argv[1]).convert("RGBA").resize((14, 14), Image.LANCZOS)
px = img.load()
rows = []
for y in range(0, 14, 2):
    line = []
    for x in range(14):
        rt, gt, bt, at_ = px[x, y]
        rb, gb, bb, ab = px[x, y + 1]
        if at_ < 40 and ab < 40:
            line.append(" ")
            continue
        line.append(f"\033[38;2;{rt};{gt};{bt}m\033[48;2;{rb};{gb};{bb}m▀\033[0m")
    rows.append("".join(line))
print(base64.b64encode(zlib.compress("\n".join(rows).encode())).decode())
