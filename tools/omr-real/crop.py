#!/usr/bin/env python3
"""crop.py <id> <x0> <y0> <x1> <y1> [scale] [out.png]  -- fractions 0..1 of the page; writes a zoomed crop (default under datasets/real/tmp/crops/)."""
import sys, glob, os
from PIL import Image
R = os.environ.get('OMR_REAL_ROOT', os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../../datasets/real')))
i = sys.argv[1]; x0, y0, x1, y1 = map(float, sys.argv[2:6])
scale = float(sys.argv[6]) if len(sys.argv) > 6 else 2.0
f = (glob.glob(f'{R}/images/{i}.png') + glob.glob(f'{R}/images/{i}.jpg'))[0]
im = Image.open(f).convert('RGB'); W, H = im.size
c = im.crop((int(x0*W), int(y0*H), int(x1*W), int(y1*H)))
c = c.resize((int(c.width*scale), int(c.height*scale)), Image.LANCZOS)
out = sys.argv[7] if len(sys.argv) > 7 else f'{R}/tmp/crops/{i}_{x0:.2f}_{y0:.2f}_{x1:.2f}_{y1:.2f}.png'
os.makedirs(os.path.dirname(out), exist_ok=True); c.save(out); print(out, c.size)
