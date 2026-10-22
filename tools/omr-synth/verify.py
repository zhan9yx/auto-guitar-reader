#!/usr/bin/env python3
"""Consistency checks between score.agr.json and page-N.boxes.json (+ optional agr-tool decode).
usage: verify.py DATASET_DIR [--agr-tool PATH] [--limit N]"""
import argparse
import collections
import glob
import json
import os
import subprocess
import sys


def check_score(d):
    errs = []
    sc = json.load(open(os.path.join(d, "score.agr.json")))
    exp = collections.Counter()
    pages = sc["pages"]
    for sec in sc["sections"]:
        for line in sec["lines"]:
            a = line.get("anchor")
            if not a or not (0 <= a["page"] < len(pages)) or not (0 <= a["y"] < 1) or not (0 < a["height"] <= 1):
                errs.append("bad anchor %s" % a)
            for m in line["system"]["measures"]:
                exp["measure"] += 1
                exp["chord_name"] += len(m["chords"])
                exp["chord_diagram"] += sum(1 for c in m["chords"] if c.get("shape"))
                for e in m["tab"]:
                    if not e["notes"]:
                        exp["tab_rest"] += 1
                    elif "stroke" in e:
                        exp["strum"] += 1
                    for n in e["notes"]:
                        if "stroke" in e:
                            continue
                        exp["tab_cross" if n.get("chordTone") else "tab_fret"] += 1
                for n in m["melody"]:
                    exp["jianpu_digit"] += 1
                    for s in n["lyrics"]:
                        if s:
                            exp["lyric_char"] += 1
                            if len(s) > 1:
                                exp["lyric_punct"] += 1
    got = collections.Counter()
    for pi, p in enumerate(pages):
        b = json.load(open(os.path.join(d, "page-%d.boxes.json" % pi)))
        for e in b["elements"]:
            got[e["label"]] += 1
            x0, y0, x1, y1 = e["bbox"]
            if x1 < x0 or y1 < y0:
                errs.append("inverted bbox %s" % e["label"])
        sz = os.path.getsize(os.path.join(d, "page-%d.pgm" % pi)) if os.path.exists(os.path.join(d, "page-%d.pgm" % pi)) else None
        if sz is not None and sz < b["width"] * b["height"]:
            errs.append("pgm too small")
    for k in exp:
        g = got[k]
        if k == "tab_cross":  # xline strums add crosses
            if g < exp[k]:
                errs.append("%s expected>=%d got %d" % (k, exp[k], g))
        elif g != exp[k]:
            errs.append("%s expected %d got %d" % (k, exp[k], g))
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--agr-tool")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    dirs = sorted(os.path.dirname(p) for p in glob.glob(os.path.join(a.root, "*", "s*", "score.agr.json")))
    if a.limit:
        dirs = dirs[::max(1, len(dirs) // a.limit)]
    bad = 0
    for d in dirs:
        errs = check_score(d)
        if a.agr_tool:
            r = subprocess.run([a.agr_tool, "import", os.path.join(d, "score.agr.json")], capture_output=True)
            if r.returncode != 0:
                errs.append("agr-tool failed: %s" % r.stderr[:200])
        if errs:
            bad += 1
            print(d, errs[:5])
    print("checked %d scores, %d with problems" % (len(dirs), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
