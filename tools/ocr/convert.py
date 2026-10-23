#!/usr/bin/env python3
"""Image -> 8-bit grayscale PGM (P5) for agr-tool omr.  usage: convert.py IN OUT.pgm [--max-side N]"""
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L")
if "--max-side" in sys.argv:
    n = int(sys.argv[sys.argv.index("--max-side") + 1])
    s = max(im.size)
    if s > n:
        im = im.resize((round(im.width * n / s), round(im.height * n / s)), Image.LANCZOS)
im.save(sys.argv[2], format="PPM")
