#!/usr/bin/env python3
"""Generate the synthetic OMR dataset.

  make_dataset.py --out S/datasets/synth/v1 --count 400 --seed 1 --styles all

Splits (pages): train=--count, val/test/test_unseen_style = --count//4 each (override with --val-count etc.).
`train`, `val`, `test` use the seen style presets; `test_unseen_style` uses only the held-out preset (default
wenkai_hand) which never appears in train/val/test.  Every score is a directory:
  <split>/sNNNNN/{score.agr.json, meta.json, page-K.{png,jpg,pgm,boxes.json}}
"""
import argparse
import json
import multiprocessing as mp
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline  # noqa: E402
import styles  # noqa: E402

OFFSETS = {"train": 0, "val": 200_000, "test": 400_000, "test_unseen_style": 600_000}


def _job(args):
    split, idx, seed, style, out, level, formats = args
    d = os.path.join(out, split, "s%05d" % idx)
    if os.path.isdir(d):
        shutil.rmtree(d)
    meta = pipeline.produce(seed, style, d, level=level, formats=formats)
    return dict(split=split, idx=idx, id="s%05d" % idx, style=style, seed=seed, pages=len(meta["pages"]), measures=meta["measures"],
                timeSignature=meta["timeSignature"], verses=meta["verses"])


def build_split(pool, split, target, base_seed, allowed, out, level, formats):
    results = {}
    n_pages = 0
    next_idx = 0
    t0 = time.time()
    while True:
        # submit a batch sized for the missing pages (~1.8 pages per score)
        need = max(8, int((target - n_pages) / 1.8) + 2)
        jobs = []
        for _ in range(need):
            i = next_idx
            next_idx += 1
            jobs.append((split, i, base_seed * 1_000_000 + OFFSETS[split] + i, allowed[i % len(allowed)], out, level, formats))
        for r in pool.imap_unordered(_job, jobs):
            results[r["idx"]] = r
        ordered = [results[i] for i in sorted(results)]
        n_pages = 0
        keep = []
        for r in ordered:
            keep.append(r)
            n_pages += r["pages"]
            if n_pages >= target:
                break
        if n_pages >= target:
            break
    for r in ordered[len(keep):]:
        shutil.rmtree(os.path.join(out, split, r["id"]), ignore_errors=True)
    print("%-18s %4d scores %4d pages (%.0fs)" % (split, len(keep), n_pages, time.time() - t0), flush=True)
    return keep


def dir_size(p):
    t = 0
    for root, _, files in os.walk(p):
        for f in files:
            t += os.path.getsize(os.path.join(root, f))
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=400, help="train pages")
    ap.add_argument("--val-count", type=int)
    ap.add_argument("--test-count", type=int)
    ap.add_argument("--unseen-count", type=int)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--styles", default="all", help="'all' or comma separated preset names")
    ap.add_argument("--unseen-style", default=styles.DEFAULT_UNSEEN)
    ap.add_argument("--workers", type=int, default=min(32, os.cpu_count() or 4))
    ap.add_argument("--level", default="normal", choices=["normal", "none"], help="'none' = clean pages, only JPEG")
    ap.add_argument("--formats", default="png,jpg,pgm")
    a = ap.parse_args()
    all_names = styles.STYLE_NAMES
    chosen = all_names if a.styles == "all" else a.styles.split(",")
    for n in chosen + [a.unseen_style]:
        if n not in all_names:
            sys.exit("unknown style %s (have %s)" % (n, ", ".join(all_names)))
    seen = [n for n in chosen if n != a.unseen_style]
    formats = tuple(a.formats.split(","))
    os.makedirs(a.out, exist_ok=True)
    targets = {"train": a.count, "val": a.val_count or a.count // 4, "test": a.test_count or a.count // 4,
               "test_unseen_style": a.unseen_count or a.count // 4}
    allowed = {"train": seen, "val": seen, "test": seen, "test_unseen_style": [a.unseen_style]}
    manifest = {"name": os.path.basename(os.path.normpath(a.out)), "seed": a.seed, "styles_seen": seen, "style_unseen": a.unseen_style,
                "level": a.level, "formats": list(formats), "splits": {}}
    with mp.Pool(a.workers) as pool:
        for split in ("train", "val", "test", "test_unseen_style"):
            keep = build_split(pool, split, targets[split], a.seed, allowed[split], a.out, a.level, formats)
            manifest["splits"][split] = {"scores": len(keep), "pages": sum(r["pages"] for r in keep),
                                         "styles": {s: sum(r["pages"] for r in keep if r["style"] == s) for s in allowed[split]},
                                         "entries": [{k: r[k] for k in ("id", "style", "seed", "pages", "measures", "timeSignature", "verses")} for r in keep]}
    manifest["totals"] = {"scores": sum(s["scores"] for s in manifest["splits"].values()),
                          "pages": sum(s["pages"] for s in manifest["splits"].values()), "bytes": dir_size(a.out)}
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    manifest["totals"]["bytes"] = dir_size(a.out)
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print(json.dumps(manifest["totals"]))


if __name__ == "__main__":
    main()
