#!/usr/bin/env python3
"""check_gt.py <file.agr.json>... : structural + musical-consistency lint for real-dataset ground truth (AGR v2).
Beat = one unit of the time-signature denominator (6/8 -> 6 beats). Exit 1 on errors. Warnings (not errors) for beat-sum mismatches, which may be genuine (pickups, printed rests)."""
import json, sys
def main():
    bad = 0
    for p in sys.argv[1:]:
        errs, warns = [], []
        d = json.load(open(p, encoding='utf-8'))
        if d.get('format') != 'agr-score' or d.get('version') != 2: errs.append('format/version')
        ts = d['meta'].get('timeSignature', {'beats': 4, 'unit': 4}); nb = ts['beats']
        nm = 0; ns = 0
        for s in d['sections']:
            for ln in s['lines']:
                if ln['kind'] != 'system': continue
                ns += 1
                a = ln.get('anchor')
                if not a or not (0 <= a['y'] <= 1 and 0 < a['height'] <= 1 and a['y'] + a['height'] <= 1.001): errs.append(f"{ln['id']}: bad anchor")
                for mi, m in enumerate(ln['system']['measures']):
                    nm += 1; tag = f"{ln['id']}m{mi}"; L = m.get('beats') or nb
                    for c in m.get('chords', []):
                        sh = c.get('shape')
                        if sh and (len(sh['frets']) != 6 or sh.get('baseFret', 1) < 1): errs.append(f'{tag}: bad shape {c["name"]}')
                        if not (0 <= c['beat'] < L): errs.append(f'{tag}: chord beat')
                    end = 0
                    for e in sorted(m.get('tab', []), key=lambda e: e['beat']):
                        if e['beat'] < end - 1e-6: warns.append(f'{tag}: tab overlap at {e["beat"]}')
                        end = e['beat'] + e['duration']
                        if end > L + 1e-6: errs.append(f'{tag}: tab past barline')
                        for n in e['notes']:
                            if not 1 <= n['string'] <= 6: errs.append(f'{tag}: string')
                            if not n.get('chordTone') and 'fret' not in n: errs.append(f'{tag}: note needs fret or chordTone')
                    mel = m.get('melody', [])
                    if mel:
                        t = sum(n['duration'] for n in mel)
                        if abs(t - L) > 1e-6: warns.append(f'{tag}: melody sums to {t} != {L}')
                        x = 0
                        for n in mel:
                            if abs(n['beat'] - x) > 1e-6: errs.append(f'{tag}: melody beat gap at {n["beat"]} (expected {x})')
                            x = n['beat'] + n['duration']
                            if not 0 <= n['degree'] <= 7: errs.append(f'{tag}: degree')
        print(f'{p}: systems={ns} measures={nm} errors={len(errs)} warnings={len(warns)}')
        for e in errs: print('  ERROR', e)
        for w in warns: print('  warn ', w)
        bad += bool(errs)
    sys.exit(1 if bad else 0)
main()
