#!/usr/bin/env python3
"""convert.py <rawdir> <outdir> : normalise every raw image to real-NNN.(jpg|png) + grayscale real-NNN.pgm (P5).
Deterministic order (sorted site/name). Writes <outdir>/map.json (id -> raw relative path). Treats inputs as untrusted data (Pillow only)."""
import json, os, sys, shutil
from PIL import Image
Image.MAX_IMAGE_PIXELS = 60_000_000
raw, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
mp = os.path.join(out, 'map.json')
old = json.load(open(mp)) if os.path.exists(mp) else {}
rev = {v: k for k, v in old.items()}
files = sorted(os.path.join(s, f) for s in os.listdir(raw) if os.path.isdir(os.path.join(raw, s)) for f in os.listdir(os.path.join(raw, s)))
n = max([int(k.split('-')[1]) for k in old] + [-1])
for rel in files:
    if rel in rev: continue
    n += 1; i = 'real-%03d' % n; old[i] = rel; rev[rel] = i
for rel, i in rev.items():
    src = os.path.join(raw, rel)
    im = Image.open(src); im.load()
    ext = 'png' if im.format in ('PNG', 'GIF') else 'jpg'
    dst = os.path.join(out, i + '.' + ext)
    if im.format == 'GIF' or im.mode in ('P', 'RGBA', 'LA'):
        im = im.convert('RGBA'); bg = Image.new('RGBA', im.size, 'white'); bg.alpha_composite(im); im = bg.convert('RGB'); ext = 'png'; dst = os.path.join(out, i + '.png')
        im.save(dst)
    else:
        shutil.copyfile(src, dst)
    g = im.convert('L')
    with open(os.path.join(out, i + '.pgm'), 'wb') as f:
        f.write(b'P5\n%d %d\n255\n' % g.size); f.write(g.tobytes())
json.dump(old, open(mp, 'w'), indent=1, sort_keys=True)
print(len(old), 'images')
