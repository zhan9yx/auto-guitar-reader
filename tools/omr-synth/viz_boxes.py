#!/usr/bin/env python3
"""Debug helper: draw the ground-truth boxes of a page over its PNG. usage: viz_boxes.py page-0 out.png [label,label,...]"""
import json
import sys

from PIL import Image, ImageDraw

COL = {"tab_cross": (255, 0, 0), "tab_fret": (255, 100, 0), "stem": (0, 160, 0), "beam": (0, 120, 0), "jianpu_digit": (0, 0, 255),
       "jianpu_dot": (200, 0, 200), "jianpu_underline": (0, 150, 150), "lyric_char": (150, 80, 0), "chord_name": (200, 0, 100),
       "chord_diagram": (0, 100, 200), "barline": (120, 0, 200), "jianpu_barline": (120, 0, 200), "strum": (255, 0, 120),
       "jianpu_tie": (0, 200, 100), "tab_rest": (255, 160, 0), "jianpu_dash": (0, 90, 255), "system": (160, 160, 160),
       "chord_dot": (0, 0, 0), "staff_line": (255, 200, 200), "tab_technique": (255, 0, 255), "tab_arc": (255, 0, 255)}


def main():
    base, out = sys.argv[1], sys.argv[2]
    only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None
    im = Image.open(base + ".png").convert("RGB")
    b = json.load(open(base + ".boxes.json"))
    d = ImageDraw.Draw(im)
    for e in b["elements"]:
        lab = e["label"]
        if only and lab not in only:
            continue
        c = (255, 0, 0) if e.get("nonScore") else COL.get(lab, (90, 90, 90))
        d.rectangle(e["bbox"], outline=c, width=1)
    im.save(out)


if __name__ == "__main__":
    main()
