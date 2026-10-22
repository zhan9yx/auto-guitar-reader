#!/usr/bin/env python3
"""Linux OCR sidecar: image -> JSON array of OCRToken (AGRCore Import/ImportTypes.swift schema).

Usage (venv at tools/ocr/.venv, see tools/ocr/README.md):
  tools/ocr/.venv/bin/python -I tools/ocr/ocr.py IMAGE [IMAGE...] [--out-dir DIR] [--force]

Writes <out-dir or <image dir>/ocr>/<image stem>.ocr.json. Token: {text,x,y,width,height,confidence},
coordinates normalized to the page, origin top-left (same as the iOS VisionOCR adapter).

Differences from iOS Vision (risk): RapidOCR (PP-OCRv4) has a different error profile. This script
(a) runs the detector at full resolution, (b) adds a second pass over overlapping 2x-upscaled bands so
small chord names ("C", "G7") are found, (c) emits word tokens for chord-like / Latin multi-word lines
and line tokens for CJK lines, like VisionOCR.makeTokens. Vision itself finds most chord names in one pass.
"""
import json, os, re, sys
import numpy as np
from PIL import Image

CHORD_RE = re.compile(r"^[A-G][#b♯♭]?(m|maj|min|dim|aug|sus|add|M)?[0-9]*(sus[0-9]?|add[0-9]+|\([#b]?[0-9]+\))*(/[A-G][#b]?)?$")


def is_cjk(ch):
    v = ord(ch)
    return 0x2E80 <= v <= 0x9FFF or 0xF900 <= v <= 0xFAFF or 0xFF00 <= v <= 0xFFEF or 0x3000 <= v <= 0x303F


def box_rect(b):
    xs = [p[0] for p in b]
    ys = [p[1] for p in b]
    return min(xs), min(ys), max(xs), max(ys)


def run_pass(engine, arr, scale=1.0, yoff=0.0):
    r, _ = engine(arr, limit_side_len=max(arr.shape[:2]) + 8, limit_type='max', box_thresh=0.4,
                  unclip_ratio=1.8, text_score=0.3)
    out = []
    for item in (r or []):
        x0, y0, x1, y1 = box_rect(item[0])
        out.append((item[1], x0 / scale, y0 / scale + yoff, x1 / scale, y1 / scale + yoff, float(item[2])))
    return out


def overlaps(a, b):
    ix = min(a[3], b[3]) - max(a[1], b[1])
    iy = min(a[4], b[4]) - max(a[2], b[2])
    if ix <= 0 or iy <= 0:
        return False
    inter = ix * iy
    area = min((a[3] - a[1]) * (a[4] - a[2]), (b[3] - b[1]) * (b[4] - b[2]))
    return inter > 0.3 * max(area, 1e-6)


def recognize(path, engine):
    im = Image.open(path).convert("RGB")
    W, H = im.size
    arr = np.array(im)
    items = run_pass(engine, arr)
    band, step = 130, 65
    y = 0
    while y < H:
        y1 = min(H, y + band)
        crop = im.crop((0, y, W, y1)).resize((W * 2, (y1 - y) * 2), Image.LANCZOS)
        for it in run_pass(engine, np.array(crop), 2.0, y):
            # keep only compact tokens from the band pass (the point is small chord names / marks)
            if it[3] - it[1] > 0.25 * W:
                continue
            if not any(overlaps(it, e) for e in items):
                items.append(it)
        if y1 >= H:
            break
        y += step
    tokens = []
    for text, x0, y0, x1, y1, conf in items:
        text = text.strip()
        if not text:
            continue
        words = text.split()
        chordish = words and all(CHORD_RE.match(w) or set(w) <= set("|｜/\\-—") for w in words)
        cjk = any(is_cjk(c) for c in text)
        if len(words) >= 2 and (chordish or not cjk):
            total = len(text)
            pos = 0
            for w in words:
                i = text.index(w, pos)
                pos = i + len(w)
                wx0 = x0 + (x1 - x0) * i / total
                wx1 = x0 + (x1 - x0) * (i + len(w)) / total
                tokens.append((w, wx0, y0, wx1, y1, conf))
        else:
            tokens.append((text, x0, y0, x1, y1, conf))
    return [{"text": t, "x": round(a / W, 5), "y": round(b / H, 5), "width": round((c - a) / W, 5),
             "height": round((d - b) / H, 5), "confidence": round(e, 3)} for t, a, b, c, d, e in tokens], (W, H)


def main(argv):
    from rapidocr_onnxruntime import RapidOCR
    args = [a for a in argv if not a.startswith("--")]
    out_dir = None
    if "--out-dir" in argv:
        out_dir = argv[argv.index("--out-dir") + 1]
        args = [a for a in args if a != out_dir]
    force = "--force" in argv
    engine = RapidOCR()
    for p in args:
        d = out_dir or os.path.join(os.path.dirname(os.path.abspath(p)), "ocr")
        os.makedirs(d, exist_ok=True)
        stem = os.path.splitext(os.path.basename(p))[0]
        dst = os.path.join(d, stem + ".ocr.json")
        if os.path.exists(dst) and not force:
            continue
        toks, _ = recognize(p, engine)
        with open(dst, "w", encoding="utf-8") as f:
            json.dump(toks, f, ensure_ascii=False)
        print(dst, len(toks), flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
