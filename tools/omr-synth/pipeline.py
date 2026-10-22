"""Score -> rendered, degraded page package on disk (png / jpg / pgm / boxes.json / score.agr.json / meta.json)."""
import json
import os
import random

import numpy as np
from PIL import Image

import degrade
import gen_score
import render
import styles


def write_pgm(path, img):
    g = np.asarray(img.convert("L"))
    with open(path, "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (g.shape[1], g.shape[0]))
        f.write(g.tobytes())


def produce(seed, style_name, out_dir, level="normal", score=None, formats=("png", "jpg", "pgm"), force_wm=None, width=None):
    """Generate (or take) a score, render it in `style_name`, degrade, write everything into out_dir.
    Returns a summary dict."""
    rng = random.Random(seed * 7919 + 13)
    st = styles.get_style(style_name)
    if score is None:
        ps = rng.choice(st["per_system"])
        score = gen_score.generate_score(seed, per_system=ps, tab_pref=st["tab_pref"])
        gen_score.validate_score(score)
    rr = render.render_score(score, st, seed, width=width)
    os.makedirs(out_dir, exist_ok=True)
    gt = rr.score
    for sec in gt["sections"]:
        for line in sec["lines"]:
            line.pop("_key", None)
    gt.pop("_flags_by_line", None)
    gt["pages"] = []
    pages_meta = []
    u = st["u"] * rr.W / 1080.0
    anchors = {}
    for pi, pg in enumerate(rr.pages):
        d = degrade.degrade_page(pg["img"], pg["elements"], pg["systems"], rng, u, bg_style=st["bg"], level=level, force_wm=force_wm)
        im = d["image"]
        w, h = im.size
        base = os.path.join(out_dir, "page-%d" % pi)
        if "png" in formats:
            im.save(base + ".png", optimize=False, compress_level=4)
        if "jpg" in formats:
            with open(base + ".jpg", "wb") as f:
                f.write(d["jpeg"])
        if "pgm" in formats:
            write_pgm(base + ".pgm", im)
        for s in d["systems"]:
            y0 = max(0.0, s["bbox"][1]) / h
            y1 = min(float(h), s["bbox"][3]) / h
            anchors[(s["sec"], s["line"])] = {"page": pi, "y": round(y0, 5), "height": round(y1 - y0, 5)}
        boxes = {"page": pi, "width": w, "height": h, "style": style_name, "seed": seed, "clean_size": [pg["img"].width, pg["img"].height],
                 "transform_clean_to_final": d["transform"], "degradations": d["record"], "systems": d["systems"],
                 "elements": d["elements"]}
        with open(base + ".boxes.json", "w") as f:
            json.dump(boxes, f, ensure_ascii=False, separators=(",", ":"))
        gt["pages"].append({"fileName": "page-%d.jpg" % pi, "width": w, "height": h})
        pages_meta.append({"page": pi, "width": w, "height": h, "degradations": d["record"], "elements": len(d["elements"])})
    for si, sec in enumerate(gt["sections"]):
        for li, line in enumerate(sec["lines"]):
            line["anchor"] = anchors.get((si, li))
    with open(os.path.join(out_dir, "score.agr.json"), "w") as f:
        json.dump(gt, f, ensure_ascii=False, indent=1)
    meta = {"seed": seed, "style": style_name, "pages": pages_meta, "level": level,
            "measures": sum(len(l["system"]["measures"]) for s in gt["sections"] for l in s["lines"]),
            "timeSignature": gt["meta"]["timeSignature"], "verses": max((len(n["lyrics"]) for s in gt["sections"] for l in s["lines"]
                                                                    for m in l["system"]["measures"] for n in m["melody"]), default=0)}
    with open(os.path.join(out_dir, "meta.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    return meta
