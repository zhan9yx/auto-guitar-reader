#!/usr/bin/env python3
"""Regenerate the small README example images (examples/*.png) deterministically."""
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline  # noqa: E402
from PIL import Image  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.join(HERE, "tmp", "examples")


def save_small(src, dst, colors=None):
    im = Image.open(src)
    if colors:
        im = im.convert("RGB")
        im = im.resize((900, int(im.height * 900 / im.width)), Image.LANCZOS).quantize(colors, method=Image.MEDIANCUT, dither=Image.NONE)
    else:
        im = im.convert("L")
    im.save(dst, optimize=True)
    print(dst, os.path.getsize(dst) // 1024, "KB")


def main():
    os.makedirs(os.path.join(HERE, "examples"), exist_ok=True)
    shutil.rmtree(TMP, ignore_errors=True)
    # 1: reference-like, clean
    d = os.path.join(TMP, "a")
    pipeline.produce(5, "classic_ref", d, level="none", formats=("png",))
    save_small(os.path.join(d, "page-0.png"), os.path.join(HERE, "examples", "classic_ref_clean.png"))
    # 2: app style + watermarks + QR + footer url
    d = os.path.join(TMP, "b")
    pipeline.produce(23, "bold_app", d, level="normal", formats=("png",), force_wm=["diag_text", "qr", "footer_url", "corner_logo"])
    save_small(os.path.join(d, "page-0.png"), os.path.join(HERE, "examples", "bold_app_watermarked.png"), colors=20)
    # 3: strum/slash style with phone-screenshot margins (search a seed that has them)
    for seed in range(100, 400):
        d = os.path.join(TMP, "c")
        m = pipeline.produce(seed, "compact_dense", d, level="normal", formats=("png",))
        g = m["pages"][0]["degradations"]["geometry"]
        if "screenshot" in g and m["pages"][0]["degradations"]["watermarks"]:
            save_small(os.path.join(d, "page-0.png"), os.path.join(HERE, "examples", "compact_dense_screenshot.png"), colors=20)
            print("screenshot seed", seed, g)
            break


if __name__ == "__main__":
    main()
