#!/usr/bin/env python3
"""Random but musically plausible AGR v2 scores (弹唱六线谱) for the OMR synthetic dataset.

The score is returned as a plain dict with exactly the key names / defaults of the Swift model
(`Core/Sources/AGRCore/Model/Score.swift`, "agr-score" version 2) so it can be written with json.dump and
decoded by `agr-tool import`.

Conventions used by this generator (documented again in README.md):
  * Every `Section` holds `Line(kind="system")` objects, one per printed system; a section always starts a system.
  * TabEvent with empty `notes` = a rest (printed as the "-" dash on the tab staff).
  * `TabNote.chordTone` = the "x" mark (pluck this string of the current chord); `fret` digits are explicit.
    `technique` hammerOn / pullOff sit on the *destination* note (the second of the pair).
  * Strum events: `stroke` = down/up and `notes` = the chord-tone notes of the strummed strings.
  * `NotationMeasure.marks`: section label text (first measure of a section if the label is printed),
    "jianpu-paren-open" / "jianpu-paren-close" (parentheses around the melody row, e.g. intro "(0 0 0 0)").
  * `beat` unit = denominator unit of the time signature (6/8: one beat = one eighth, 6 beats per measure).
"""
import argparse
import json
import os
import random
import subprocess
import sys
import uuid

# --------------------------------------------------------------------------- vocab

COMMON_CHARS = (
    "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还"
    "发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全"
    "工话儿者向情部正名定女问力机给等几很业最间新什写相关内次应加度风雨花雪夜光梦海云山水星空爱恋唱歌听见走远回忆笑泪等待告别永远陪伴"
    "温柔春夏秋冬街灯城南北东西路过想念孤单自由飞翔青草地阳窗外旧时像总是每次终于寂静世界温暖未来拥抱微笑沉默相遇离开故事等候灿烂星辰"
    "清晨黄昏夕阳月光街角河流麦田田野故乡少年岁月青春时光诺言誓言转身背影眼泪守候流浪天涯远方旅行脚步心跳呼吸放手勇气信仰"
)
COMMON_CHARS = "".join(dict.fromkeys(COMMON_CHARS))

SURNAMES = "田周林陈王李张刘杨黄赵吴徐孙朱马胡郭何高罗郑梁谢宋唐许韩冯邓曹彭曾萧蔡潘袁蒋蔡余杜叶程魏苏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤"
GIVEN = "馥甄雨轩子涵欣怡梓萱浩然宇航思远嘉豪俊杰佳琪诗涵晨曦明哲睿泽雅静梦琪若汐一诺安然天佑启航志远晓东文杰海涛建国秀英"
TITLE_FRAGS = ["小", "幸运", "晴天", "夜", "光", "海", "风", "雨", "花", "城市", "旅行", "时光", "回忆", "星空", "远方", "故乡",
               "爱", "梦", "夏天", "冬天", "月亮", "少年", "平凡", "后来", "遇见", "告白", "等你", "陪你", "我们", "未来", "孤单",
               "温柔", "自由", "离别", "思念", "晚安", "天空", "路", "背影", "诺言", "彩虹", "稻香", "南山", "北方", "老街"]
CREDIT_NAMES = ["阿宽", "小明", "吉他手老陈", "琴谱君", "木吉他", "六弦琴", "Echo", "弹唱工作室", "阿杰", "Mr.Lin", "Kiki", "海盐"]

# --------------------------------------------------------------------------- chords

# frets low E (string 6) -> high E (string 1); -1 muted, 0 open.
SHAPES = {
    "C": [-1, 3, 2, 0, 1, 0], "D": [-1, -1, 0, 2, 3, 2], "E": [0, 2, 2, 1, 0, 0], "F": [1, 3, 3, 2, 1, 1],
    "G": [3, 2, 0, 0, 0, 3], "A": [-1, 0, 2, 2, 2, 0], "B": [-1, 2, 4, 4, 4, 2],
    "Am": [-1, 0, 2, 2, 1, 0], "Dm": [-1, -1, 0, 2, 3, 1], "Em": [0, 2, 2, 0, 0, 0], "Bm": [-1, 2, 4, 4, 3, 2],
    "F#m": [2, 4, 4, 2, 2, 2], "Gm": [3, 5, 5, 3, 3, 3], "Bb": [-1, 1, 3, 3, 3, 1],
    "C7": [-1, 3, 2, 3, 1, 0], "D7": [-1, -1, 0, 2, 1, 2], "E7": [0, 2, 0, 1, 0, 0], "G7": [3, 2, 0, 0, 0, 1],
    "A7": [-1, 0, 2, 0, 2, 0], "B7": [-1, 2, 1, 2, 0, 2],
    "Am7": [-1, 0, 2, 0, 1, 0], "Dm7": [-1, -1, 0, 2, 1, 1], "Em7": [0, 2, 0, 0, 0, 0], "Bm7": [-1, 2, 0, 2, 0, 2],
    "Cmaj7": [-1, 3, 2, 0, 0, 0], "Fmaj7": [-1, -1, 3, 2, 1, 0], "Gmaj7": [3, 2, 0, 0, 0, 2], "Dmaj7": [-1, -1, 0, 2, 2, 2],
    "Gsus4": [3, 3, 0, 0, 1, 3], "Csus4": [-1, 3, 3, 0, 1, 1], "Dsus4": [-1, -1, 0, 2, 3, 3], "Asus4": [-1, 0, 2, 2, 3, 0],
    "Cadd9": [-1, 3, 2, 0, 3, 0], "G/B": [-1, 2, 0, 0, 0, 3], "C/G": [3, 3, 2, 0, 1, 0], "D/F#": [2, 0, 0, 2, 3, 2],
    "Am/G": [3, 0, 2, 2, 1, 0], "Am/E": [0, 0, 2, 2, 1, 0], "F/C": [-1, 3, 3, 2, 1, 1],
    # numbered bass / variant names kept verbatim as seen on Chinese tab sites
    "D7(5)": [-1, 0, 0, 2, 1, 2], "G7(3)": [-1, 2, 0, 0, 0, 1], "D(7)": [-1, -1, 0, 2, 1, 2], "C(3)": [0, 3, 2, 0, 1, 0],
    "G(3)": [-1, 2, 0, 0, 0, 3], "D(5)": [-1, 0, 0, 2, 3, 2], "C(5)": [3, 3, 2, 0, 1, 0], "Am7(5)": [0, 0, 2, 0, 1, 0],
    "Em7(5)": [-1, 2, 0, 0, 0, 0], "A7(3)": [-1, 4, 2, 0, 2, 0], "E7(5)": [-1, 2, 0, 1, 0, 0],
}
# variants offered per plain chord
VARIANTS = {
    "C": ["Cadd9", "Cmaj7", "C(3)", "C/G", "C(5)", "Csus4"],
    "G": ["G7", "G7(3)", "Gsus4", "G/B", "G(3)", "Gmaj7"],
    "D": ["D7", "D7(5)", "Dsus4", "D(5)", "D(7)", "D/F#", "Dmaj7"],
    "A": ["A7", "Asus4", "A7(3)"],
    "E": ["E7", "E7(5)"],
    "F": ["Fmaj7", "F/C"],
    "Am": ["Am7", "Am7(5)", "Am/G", "Am/E"],
    "Em": ["Em7", "Em7(5)"],
    "Dm": ["Dm7"],
    "Bm": ["Bm7"],
}
# play key -> diatonic chords by degree (None = not available as a shape)
KEYS = {
    "C": ["C", "Dm", "Em", "F", "G", "Am"],
    "G": ["G", "Am", "Bm", "C", "D", "Em"],
    "D": ["D", "Em", "F#m", "G", "A", "Bm"],
    "A": ["A", "Bm", None, "D", "E", None],
    "F": ["F", "Gm", "Am", "Bb", "C", "Dm"],
}
V7 = {"C": "G7", "G": "D7", "D": "A7", "A": "E7", "F": "C7"}
SHARP_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
FLAT_NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
PC = {"C": 0, "G": 7, "D": 2, "A": 9, "F": 5}
LOOPS = [[0, 4, 5, 3], [5, 3, 0, 4], [0, 5, 3, 4], [0, 2, 3, 4], [0, 3, 4, 0], [5, 4, 3, 4], [3, 4, 2, 5], [0, 4, 3, 4], [0, 5, 1, 4]]
ROMAN_DEG = [1, 2, 3, 4, 5, 6]  # chord index -> scale degree of its root


def shape_for(name):
    frets = list(SHAPES[name])
    fretted = [f for f in frets if f > 0]
    base = 1
    if fretted:
        mn = min(fretted)
        if mn >= 3 or (mn >= 2 and 0 not in frets):
            base = mn
        if max(fretted) - base >= 5:
            base = mn
    return {"frets": frets, "fingers": guess_fingers(frets), "baseFret": base}


def guess_fingers(frets):
    """Heuristic finger numbers (0 = open/muted); only used for diagram labels in some styles."""
    fretted = [(f, i) for i, f in enumerate(frets) if f > 0]
    out = [0] * 6
    if not fretted:
        return out
    fmin = min(f for f, _ in fretted)
    barre = [i for f, i in fretted if f == fmin]
    nxt = 1
    if len(barre) >= 3 or (fmin > 1 and 0 not in frets):
        for i in barre:
            out[i] = 1
        nxt = 2
    for f, i in sorted((f, i) for f, i in fretted if out[i] == 0):
        out[i] = min(nxt, 4)
        nxt += 1
    return out


# --------------------------------------------------------------------------- tab patterns
# slot lists: (start_slot, length_slots, roles) ; roles None = rest.  One slot = 0.5 q-beat (eighth).
# roles: 'B' lowest sounding string, 'b' second lowest, '1'..'4' string number (mapped to sounding), 'D' 'U' strums.
ARP_44 = [
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "3"), (4, 1, "1"), (5, 1, "3"), (6, 1, "2"), (7, 1, "3")],
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "1"), (4, 1, "2"), (5, 1, "3"), (6, 1, "2"), (7, 1, "1")],
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "3"), (4, 1, "b"), (5, 1, "3"), (6, 1, "2"), (7, 1, "3")],
    [(0, 2, "B1"), (2, 1, "3"), (3, 1, "2"), (4, 2, "B1"), (6, 1, "3"), (7, 1, "2")],
    [(0, 1, "B"), (1, 1, "2"), (2, 1, "3"), (3, 1, "2"), (4, 1, "b"), (5, 1, "2"), (6, 1, "3"), (7, 1, "2")],
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "3"), (4, 1, "1"), (5, 1, "3"), (6, 2, None)],
    [(0, 1, "B"), (1, 1, "4"), (2, 1, "3"), (3, 1, "2"), (4, 1, "B"), (5, 1, "4"), (6, 1, "3"), (7, 1, "1")],
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "3"), (4, 1, "B1"), (5, 1, "3"), (6, 1, "2"), (7, 1, "3")],
    [(0, 2, "B"), (2, 1, "3"), (3, 1, "2"), (4, 1, "b"), (5, 1, "2"), (6, 2, "3")],
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "3"), (4, 1, "2"), (5, 1, "3"), (6, 2, None)],
]
STRUM_44 = [
    [(0, 3, "D"), (3, 1, "U"), (4, 2, "U"), (6, 1, "D"), (7, 1, "U")],      # D-DU-UDU style D..-U..
    [(0, 2, "D"), (2, 1, "D"), (3, 1, "U"), (4, 1, "U"), (5, 1, "D"), (6, 1, "U"), (7, 1, "D")],
    [(0, 2, "D"), (2, 2, "D"), (4, 1, "U"), (5, 1, "D"), (6, 1, "D"), (7, 1, "U")],
    [(0, 2, "Db"), (2, 1, "D"), (3, 1, "U"), (4, 2, "Db"), (6, 1, "D"), (7, 1, "U")],
    [(0, 4, "D"), (4, 4, "D")],
    [(0, 2, "D"), (2, 2, "D"), (4, 2, "D"), (6, 2, "D")],
    [(0, 1, "D"), (1, 1, "U"), (2, 1, "D"), (3, 1, "U"), (4, 1, "D"), (5, 1, "U"), (6, 1, "D"), (7, 1, "U")],
]
ARP_34 = [
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "3"), (4, 1, "1"), (5, 1, "3")],
    [(0, 1, "B"), (1, 1, "2"), (2, 1, "3"), (3, 1, "2"), (4, 1, "3"), (5, 1, "2")],
    [(0, 2, "B"), (2, 1, "3"), (3, 1, "2"), (4, 1, "3"), (5, 1, "2")],
]
STRUM_34 = [
    [(0, 2, "D"), (2, 2, "D"), (4, 1, "D"), (5, 1, "U")],
    [(0, 1, "Db"), (1, 1, "U"), (2, 2, "D"), (4, 1, "D"), (5, 1, "U")],
]
ARP_68 = [  # 6 slots of one beat (eighth)
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "1"), (4, 1, "2"), (5, 1, "3")],
    [(0, 1, "B"), (1, 1, "3"), (2, 1, "2"), (3, 1, "b"), (4, 1, "2"), (5, 1, "3")],
    [(0, 1, "B"), (1, 1, "2"), (2, 1, "3"), (3, 1, "1"), (4, 1, "3"), (5, 1, "2")],
]
STRUM_68 = [
    [(0, 2, "D"), (2, 1, "U"), (3, 2, "D"), (5, 1, "U")],
    [(0, 3, "D"), (3, 2, "D"), (5, 1, "U")],
]
TIME_SIGS = [(4, 4)] * 14 + [(3, 4)] * 3 + [(6, 8)] * 3

# --------------------------------------------------------------------------- melody rhythm (in quarter-note units)
RHYTHMS = {
    (4, 4): [([0.5] * 8, 8), ([1, 1, 1, 1], 3), ([1, 0.5, 0.5, 1, 1], 3), ([1.5, 0.5, 1, 1], 2), ([2, 1, 1], 2), ([1, 1, 2], 2),
             ([0.5, 0.5, 1, 0.5, 0.5, 1], 4), ([1, 0.5, 0.5, 0.5, 0.5, 1], 3), ([2, 2], 2), ([4], 1), ([3, 1], 1),
             ([0.5, 0.5, 0.5, 0.5, 1, 1], 3), ([1, 1, 0.5, 0.5, 1], 3), ([0.5, 1, 0.5, 1, 1], 2), ([0.75, 0.25, 1, 1, 1], 1),
             ([1, 0.5, 0.25, 0.25, 1, 1], 1), ([1.5, 0.5, 2], 1)],
    (3, 4): [([1, 1, 1], 4), ([0.5] * 6, 4), ([2, 1], 2), ([1, 0.5, 0.5, 1], 3), ([3], 1), ([1.5, 0.5, 1], 2), ([1, 2], 2)],
    (6, 8): [([1.5, 1.5], 3), ([0.5] * 6, 5), ([0.5, 0.5, 0.5, 1.5], 3), ([1, 0.5, 0.5, 0.5, 0.5], 3), ([3], 1), ([1.5, 0.5, 0.5, 0.5], 2)],
}


def rhythm_free(rng, total_q):
    """Random fill for odd-length (pickup) measures."""
    out, left = [], total_q
    while left > 1e-9:
        opts = [d for d in (1.5, 1, 0.5, 0.5, 0.5) if d <= left + 1e-9]
        d = rng.choice(opts)
        out.append(d)
        left -= d
    return out


def beat_group_q(ts):
    return 1.5 if ts == (6, 8) else 1.0


# --------------------------------------------------------------------------- generator

class Gen:
    def __init__(self, rng, ts, per_system, opts):
        self.rng = rng
        self.ts = ts
        self.ps = per_system
        self.opts = opts
        self.unit_scale = ts[1] / 4.0  # beats per quarter
        self.measure_beats = float(ts[0])
        self.slot_beats = 1.0 if ts == (6, 8) else 0.5
        self.shapes = {}
        self.pos = 0  # abs scale position of last melody note
        self.verses = 1

    # ----- chords
    def chord_name(self, key, idx, variant_p):
        base = KEYS[key][idx]
        if base is None:
            base = KEYS[key][0]
        rng = self.rng
        name = base
        if idx == 4 and rng.random() < 0.30 and V7.get(key) in SHAPES:
            name = V7[key]
        if rng.random() < variant_p and base in VARIANTS:
            name = rng.choice(VARIANTS[base])
        return name

    def make_loop(self, key, idx_loop, variant_p):
        loop = []
        for idx in idx_loop:
            if KEYS[key][idx] is None:
                idx = 0
            loop.append((idx, self.chord_name(key, idx, variant_p)))
        return loop

    # ----- tab
    def sounding(self, name):
        fr = SHAPES[name]
        return sorted([6 - i for i, f in enumerate(fr) if f >= 0], reverse=True)  # low -> high pitch (6 -> 1)

    def pick_string(self, role, S):
        if role == "B":
            return S[0]
        if role == "b":
            return S[1] if len(S) > 1 else S[0]
        want = int(role)
        return min(S, key=lambda s: (abs(s - want), s))

    def tab_for_measure(self, pat, kind, chords, beats, pickup_beats):
        """chords: [(beat, name)]; pat from the pattern libs; returns list of events."""
        sb = self.slot_beats
        slots = pat
        if pickup_beats is not None:
            nsl = int(round(pickup_beats / sb))
            total = int(round(self.measure_beats / sb))
            start = total - nsl
            slots = []
            for (s, l, r) in pat:
                if s + l <= start:
                    continue
                s2 = max(s, start)
                slots.append((s2 - start, s + l - s2, r))
        events = []
        for (s, l, roles) in slots:
            beat = s * sb
            dur = l * sb
            if beat + dur > beats + 1e-9:
                dur = beats - beat
            if dur <= 0:
                continue
            cname = chords[0][1]
            for (cb, cn) in chords:
                if beat + 1e-9 >= cb:
                    cname = cn
            S = self.sounding(cname)
            if roles is None:
                events.append({"beat": beat, "duration": dur, "notes": []})
                continue
            if roles in ("D", "Db", "U"):
                if roles == "D":
                    strs = S
                elif roles == "Db":
                    strs = S[:max(3, len(S) - 2)]
                else:
                    strs = S[-3:]
                strs = sorted(strs)
                notes = [{"string": s_, "chordTone": True} for s_ in strs]
                events.append({"beat": beat, "duration": dur, "notes": notes,
                               "stroke": "up" if roles == "U" else "down"})
                continue
            strs = []
            if roles == "B1":
                strs = [S[0], S[-1]]
            else:
                strs = [self.pick_string(roles, S)]
            strs = sorted(set(strs))
            events.append({"beat": beat, "duration": dur, "notes": [{"string": s_, "chordTone": True} for s_ in strs]})
        # merge identical consecutive rests? keep as is
        return events

    def explicit_digits(self, events, chords_at):
        """Turn some chord-tone picks into explicit frets, add H/P pairs."""
        rng = self.rng
        def fret_of(ev, note):
            cname = chords_at(ev["beat"])
            return SHAPES[cname][6 - note["string"]]
        singles = [i for i, e in enumerate(events) if len(e["notes"]) == 1 and "stroke" not in e]
        mode = rng.random()
        if mode < 0.25 and singles:  # whole-measure explicit digits
            for e in events:
                for n in e["notes"]:
                    n["fret"] = fret_of(e, n)
                    n.pop("chordTone", None)
                    n["chordTone"] = False
            return
        if singles:
            i = rng.choice(singles)
            n = events[i]["notes"][0]
            n["fret"] = fret_of(events[i], n)
            n["chordTone"] = False
        # hammer-on / pull-off pair
        for _ in range(3):
            if len(events) < 3:
                break
            i = rng.randrange(0, len(events) - 1)
            a, b = events[i], events[i + 1]
            if len(a["notes"]) != 1 or len(b["notes"]) != 1 or "stroke" in a or "stroke" in b:
                continue
            s = a["notes"][0]["string"]
            f = fret_of(a, a["notes"][0])
            if f < 0 or f > 8:
                continue
            if rng.random() < 0.7:
                a["notes"][0] = {"string": s, "fret": f, "chordTone": False}
                b["notes"][0] = {"string": s, "fret": f + rng.choice([1, 2, 2, 2]), "chordTone": False, "technique": "hammerOn"}
            else:
                hi = f + rng.choice([2, 2, 3])
                a["notes"][0] = {"string": s, "fret": hi, "chordTone": False}
                b["notes"][0] = {"string": s, "fret": f, "chordTone": False, "technique": "pullOff"}
            break

    # ----- melody
    def pos_to_note(self, p):
        return (p % 7) + 1, p // 7

    def melody_for_measure(self, rng, ts, beats, tonic_deg, total_q, kind):
        """kind: 'rest' | 'melody'. returns list of note dicts (no lyrics yet)."""
        scale = self.unit_scale
        if kind == "rest":
            durs = [1.0] * int(round(total_q)) if abs(total_q - round(total_q)) < 1e-9 else rhythm_free(rng, total_q)
            if ts == (6, 8):
                durs = [1.5, 1.5] if total_q == 3 else rhythm_free(rng, total_q)
            return [{"beat": 0, "duration": 0, "degree": 0, "accidental": 0, "octave": 0, "tieToNext": False, "lyrics": [], "_q": d} for d in durs]
        if abs(total_q - (ts[0] * 4.0 / ts[1])) < 1e-9:
            weights = RHYTHMS[ts]
            durs = rng.choices([w[0] for w in weights], [w[1] for w in weights])[0]
            durs = list(durs)
            # occasionally split an 8th into two 16ths
            if rng.random() < 0.12:
                idx = [i for i, d in enumerate(durs) if d == 0.5]
                if idx:
                    i = rng.choice(idx)
                    durs[i:i + 1] = [0.25, 0.25]
        else:
            durs = rhythm_free(rng, total_q)
        notes = []
        t = 0.0
        chord_tones = [(tonic_deg - 1 + k) % 7 for k in (0, 2, 4)]
        for d in durs:
            if rng.random() < 0.07:
                notes.append({"degree": 0, "octave": 0, "accidental": 0, "_q": d, "_t": t})
                t += d
                continue
            # choose position
            if rng.random() < 0.55:
                cands = [p for p in range(-4, 9) if p % 7 in chord_tones and abs(p - self.pos) <= 4]
                p = rng.choice(cands) if cands else self.pos
            else:
                p = self.pos + rng.choice([-2, -1, -1, 0, 1, 1, 2])
            p = max(-4, min(9, p))
            self.pos = p
            deg, octv = self.pos_to_note(p)
            acc = 0
            if rng.random() < 0.04 and deg in (4, 7):
                acc = 1 if deg == 4 else -1
            notes.append({"degree": deg, "octave": octv, "accidental": acc, "_q": d, "_t": t})
            t += d
        return notes

    # ----- build
    def build(self):
        rng = self.rng
        opts = self.opts
        ts = self.ts
        play_key = rng.choice(list(KEYS))
        if opts.get("force_key"):
            play_key = opts["force_key"]
        capo = rng.choice([0, 0, 0, 0, 1, 2, 2, 3, 3, 4, 5]) if not opts.get("no_capo") else 0
        tonic_pc = (PC[play_key] + capo) % 12
        names = FLAT_NAMES if play_key in ("F", "C") and capo else SHARP_NAMES
        if capo and rng.random() < 0.4:
            names = FLAT_NAMES
        key_name = names[tonic_pc]
        tempo = rng.choice([60, 66, 72, 76, 80, 84, 88, 92, 96, 104, 112, 120]) if ts[0] != 3 else rng.choice([60, 72, 84, 96])
        title = self.make_title()
        artist = self.make_artist()
        credits = []
        if rng.random() < 0.45:
            credits.append(rng.choice(["制谱：", "编配：", "吉他谱：", "整理：", "谱：", "制谱/编配："]) + rng.choice(CREDIT_NAMES))
        self.verses = rng.choices([1, 2, 3], [4, 4, 2])[0]
        # sections
        ps = self.ps
        tokens = [("intro", ps), ("verse", 2 * ps), ("chorus", 2 * ps), ("interlude", ps), ("verse", 2 * ps), ("chorus", 2 * ps), ("outro", ps)]
        if opts.get("sectionless"):
            pass
        prefixes = []
        tot = 0
        for i, (_, n) in enumerate(tokens):
            tot += n
            if 8 <= tot <= 24:
                prefixes.append(i + 1)
        if not prefixes:
            prefixes = [2]
        k = rng.choice(prefixes)
        plan = [list(t) for t in tokens[:k]]
        # drop intro sometimes
        if rng.random() < 0.15 and len(plan) > 2 and sum(n for _, n in plan[1:]) >= 8:
            plan = plan[1:]
        # lengthen/shorten a verse by 2 now and then (short last line)
        if rng.random() < 0.2:
            for p in plan:
                if p[0] in ("verse", "chorus") and p[1] > 4 and sum(n for _, n in plan) + 2 <= 24:
                    p[1] += 2
                    break
        kind_label = {"intro": ("前奏", "intro"), "verse": ("主歌", "verse"), "chorus": ("副歌", "chorus"),
                      "interlude": ("间奏", "interlude"), "outro": ("尾奏", "outro")}
        loops = {"verse": self.make_loop(play_key, rng.choice(LOOPS), 0.22),
                 "chorus": self.make_loop(play_key, rng.choice(LOOPS), 0.22)}
        loops["intro"] = loops["verse"]
        loops["interlude"] = loops["chorus"] if rng.random() < 0.5 else loops["verse"]
        loops["outro"] = loops["verse"]
        tab_kind_pref = rng.choice(["arp", "arp", "strum", "mixed"])
        chord_defs = {}
        sections = []
        verse_no = 0
        chorus_no = 0
        n_total = sum(n for _, n in plan)
        pickup = rng.random() < 0.12
        ref_style_rest_intro = rng.random() < 0.5
        measure_global = 0
        sec_pattern = {}
        for si, (kind, n) in enumerate(plan):
            if kind == "verse":
                verse_no += 1
                nm = "主歌" + (str(verse_no) if verse_no > 1 else "")
            elif kind == "chorus":
                chorus_no += 1
                nm = "副歌" + (str(chorus_no) if chorus_no > 1 else "")
            else:
                nm = kind_label[kind][0]
            loop = loops[kind]
            # tab pattern for this section
            if kind not in sec_pattern or rng.random() < 0.3:
                use_strum = (tab_kind_pref == "strum") or (tab_kind_pref == "mixed" and kind in ("chorus", "outro"))
                if kind == "intro" and tab_kind_pref == "mixed":
                    use_strum = False
                lib = (STRUM_44 if use_strum else ARP_44) if ts == (4, 4) else \
                      (STRUM_34 if use_strum else ARP_34) if ts == (3, 4) else (STRUM_68 if use_strum else ARP_68)
                sec_pattern[kind] = (rng.choice(lib), "strum" if use_strum else "arp")
            pat, patkind = sec_pattern[kind]
            digits_p = 0.30 if rng.random() < 0.4 else 0.04
            rest_intro = kind == "intro" and ref_style_rest_intro
            melody_in_paren = kind == "intro" and not ref_style_rest_intro and rng.random() < 0.3
            use_repeat = kind in ("verse", "chorus") and n >= 4 and rng.random() < 0.2
            use_volta = use_repeat and n >= 4 and rng.random() < 0.6
            measures = []
            for mi in range(n):
                is_pick = pickup and si == 0 and mi == 0
                mbeats = self.measure_beats
                pk_beats = None
                if is_pick:
                    pk_beats = rng.choice([1.0, 2.0, 3.0] if ts == (6, 8) else [1.0, 2.0])
                    mbeats = pk_beats
                lp_i = mi % len(loop)
                lp_idx, cname = loop[lp_i]
                chords = [(0.0, cname)]
                if not is_pick and rng.random() < 0.18 and mbeats >= 4:
                    j2 = (lp_i + 1) % len(loop)
                    chords.append((mbeats / 2.0, loop[j2][1] if rng.random() < 0.6 else self.chord_name(play_key, loop[j2][0], 0.0)))
                for _, cn in chords:
                    chord_defs[cn] = shape_for(cn)
                tonic_deg = ROMAN_DEG[lp_idx]
                # tab
                events = self.tab_for_measure(pat, patkind, chords, mbeats, pk_beats)
                if patkind == "arp" and rng.random() < digits_p and len(events) >= 4:
                    def chords_at(b, chords=chords):
                        c = chords[0][1]
                        for cb, cn in chords:
                            if b + 1e-9 >= cb:
                                c = cn
                        return c
                    self.explicit_digits(events, chords_at)
                # melody
                total_q = mbeats / self.unit_scale
                mk = "rest" if (rest_intro and not is_pick) else "melody"
                mel = self.melody_for_measure(rng, ts, mbeats, tonic_deg, total_q, mk)
                t = 0.0
                for nt in mel:
                    q = nt.pop("_q")
                    nt.pop("_t", None)
                    nt["beat"] = t * self.unit_scale
                    nt["duration"] = q * self.unit_scale
                    nt["tieToNext"] = False
                    nt["lyrics"] = []
                    t += q
                m = {
                    "beats": pk_beats if is_pick else None,
                    "chords": [{"name": cn, "beat": cb} for cb, cn in chords],
                    "tab": events, "melody": mel,
                    "leftBarline": "single", "rightBarline": "single", "volta": [], "marks": [],
                    "_kind": kind, "_paren": rest_intro or melody_in_paren,
                }
                measures.append(m)
            # repeats
            if use_repeat:
                measures[0]["leftBarline"] = "startRepeat"
                measures[-1]["rightBarline"] = "endRepeat"
                if use_volta and n >= 4:
                    measures[-2]["volta"] = [1]
                    measures[-2]["rightBarline"] = "endRepeat"
                    measures[-1]["volta"] = [2]
                    measures[-1]["rightBarline"] = "single"
            elif rng.random() < 0.3 and si < len(plan) - 1:
                measures[-1]["rightBarline"] = "double"
            sections.append({"name": nm, "kind": kind_label[kind][1], "measures": measures, "_k": kind})
        sections[-1]["measures"][-1]["rightBarline"] = "final"
        # ties / slurs
        for sec in sections:
            ms = sec["measures"]
            for mi, m in enumerate(ms):
                mel = m["melody"]
                for ni, nt in enumerate(mel):
                    if nt["degree"] == 0 or rng.random() > 0.09:
                        continue
                    nxt = None
                    if ni + 1 < len(mel):
                        nxt = mel[ni + 1]
                    elif mi + 1 < len(ms) and (mi + 1) % self.ps != 0 and ms[mi + 1]["melody"]:
                        nxt = ms[mi + 1]["melody"][0]
                    if nxt is None or nxt["degree"] == 0:
                        continue
                    if rng.random() < 0.65:  # real tie: same pitch
                        nxt["degree"], nxt["octave"], nxt["accidental"] = nt["degree"], nt["octave"], nt["accidental"]
                    nt["tieToNext"] = True
        # a tie never leaves its printed system
        for sec in sections:
            ms = sec["measures"]
            for mi in range(len(ms)):
                if (mi + 1) % self.ps == 0 or mi == len(ms) - 1:
                    if ms[mi]["melody"]:
                        ms[mi]["melody"][-1]["tieToNext"] = False
        # lyrics
        punct_p = 0.55 if opts.get("lyric_punct", True) else 0.0
        for sec in sections:
            if sec["_k"] not in ("verse", "chorus"):
                continue
            ms = sec["measures"]
            for mi, m in enumerate(ms):
                if rng.random() < 0.10:
                    continue
                prev_tied = False
                last_idx = None
                for ni, nt in enumerate(m["melody"]):
                    if mi == 0 and ni == 0:
                        pass
                    cont = prev_tied
                    prev_tied = nt["tieToNext"]
                    if nt["degree"] == 0 or cont:
                        continue
                    q = nt["duration"] / self.unit_scale
                    ok = q >= 0.5 or (q == 0.25 and abs((nt["beat"] / self.unit_scale) % 0.5) < 1e-9)
                    if not ok:
                        continue
                    nt["_lyr"] = True
                    last_idx = ni
                if last_idx is not None and mi % 2 == 1:
                    m["melody"][last_idx]["_punct"] = rng.random() < punct_p
        # assemble lines (systems)
        for sec in sections:
            ms = sec["measures"]
            lines = []
            i = 0
            while i < len(ms):
                chunk = ms[i:i + self.ps]
                i += self.ps
                # avoid a 1-measure orphan line
                if len(ms) - i == 1:
                    chunk = ms[i - self.ps:i + 1]
                    i += 1
                lines.append(chunk)
            sec["lines"] = lines
        for sec in sections:
            for chunk in sec["lines"]:
                has_lyr = any(n.get("_lyr") for m in chunk for n in m["melody"])
                v_sys = 0
                if has_lyr:
                    v_sys = self.verses if rng.random() < 0.85 else max(1, self.verses - 1)
                for m in chunk:
                    for n in m["melody"]:
                        lyr = []
                        if v_sys:
                            for v in range(v_sys):
                                if n.get("_lyr") and (v == 0 or rng.random() < 0.93):
                                    ch = rng.choice(COMMON_CHARS)
                                    if n.get("_punct"):
                                        ch += rng.choice(["，", "，", "。"])
                                    lyr.append(ch)
                                else:
                                    lyr.append("")
                        n["lyrics"] = lyr
                        n.pop("_lyr", None)
                        n.pop("_punct", None)
        # parens for melody row: first & last measure of a line when all measures flagged
        out_sections = []
        for si, sec in enumerate(sections):
            lines = []
            for li, chunk in enumerate(sec["lines"]):
                for m in chunk:
                    pass
                if all(m["_paren"] for m in chunk) and chunk[0]["_paren"]:
                    chunk[0]["marks"].append("jianpu-paren-open")
                    chunk[-1]["marks"].append("jianpu-paren-close")
                lines.append(chunk)
            out_sections.append((sec, lines))
        sid = 0
        score_sections = []
        for si, (sec, lines) in enumerate(out_sections):
            score_sections.append({
                "id": "s%d" % si, "name": sec["name"], "kind": sec["kind"], "strumPatternID": None,
                "lines": [
                    {"id": "l%d_%d" % (si, li), "kind": "system", "segments": [], "tab": None, "text": None, "anchor": None,
                     "system": {"measures": [strip_private(m) for m in chunk]}}
                    for li, chunk in enumerate(lines)],
            })
        meta = {
            "title": title, "artist": artist, "composer": None, "lyricist": None, "arranger": None,
            "key": key_name, "capo": capo, "tempo": float(tempo),
            "timeSignature": {"beats": ts[0], "unit": ts[1]},
            "tuning": [40, 45, 50, 55, 59, 64], "mode": "strumSing",
            "source": {"kind": "image", "fileName": None, "importedAt": None},
            "tags": ["synthetic"], "credits": credits,
        }
        score = {
            "format": "agr-score", "version": 2,
            "id": str(uuid.UUID(int=rng.getrandbits(128), version=4)).upper(),
            "meta": meta, "chordDefinitions": chord_defs, "strumPatterns": [],
            "sections": score_sections, "arrangement": None, "pages": [],
        }
        return score

    def make_title(self):
        rng = self.rng
        r = rng.random()
        if r < 0.5:
            t = "".join(rng.choice(TITLE_FRAGS) for _ in range(rng.choice([1, 2, 2])))
        elif r < 0.8:
            t = rng.choice(COMMON_CHARS) + "的" + "".join(rng.choice(COMMON_CHARS) for _ in range(rng.choice([1, 2])))
        else:
            t = "".join(rng.choice(COMMON_CHARS) for _ in range(rng.randint(2, 6)))
        return t[:8]

    def make_artist(self):
        rng = self.rng
        return rng.choice(SURNAMES) + "".join(rng.choice(GIVEN) for _ in range(rng.choice([1, 2, 2])))


def strip_private(m):
    m = dict(m)
    for k in [k for k in m if k.startswith("_")]:
        del m[k]
    # normalise tab events to the exact Swift key set
    ev = []
    for e in m["tab"]:
        d = {"beat": e["beat"], "duration": e["duration"], "notes": [norm_note(n) for n in e["notes"]]}
        if "stroke" in e:
            d["stroke"] = e["stroke"]
        ev.append(d)
    m["tab"] = ev
    return m


def norm_note(n):
    if n.get("chordTone"):
        d = {"string": n["string"], "chordTone": True}
    else:
        d = {"string": n["string"], "fret": n["fret"]}
    if n.get("technique"):
        d["technique"] = n["technique"]
    return d


def generate_score(seed, per_system=4, time_signature=None, **opts):
    """Return an AGR v2 score dict. `per_system` = max measures per printed system line."""
    rng = random.Random(seed)
    ts = time_signature or rng.choice(TIME_SIGS)
    if isinstance(ts, list):
        ts = tuple(ts)
    g = Gen(rng, ts, per_system, opts)
    return g.build()


def validate_score(score):
    """Structural checks the generator guarantees (measure durations, string ranges, ...). Raises AssertionError."""
    ts = score["meta"]["timeSignature"]
    full = float(ts["beats"])
    n = 0
    for sec in score["sections"]:
        for line in sec["lines"]:
            for m in line["system"]["measures"]:
                n += 1
                L = m["beats"] if m["beats"] is not None else full
                mel = m["melody"]
                tot = sum(x["duration"] for x in mel)
                assert abs(tot - L) < 1e-6, ("melody does not fill measure", tot, L)
                t = 0.0
                for x in mel:
                    assert abs(x["beat"] - t) < 1e-6, "melody gap"
                    t += x["duration"]
                te = m["tab"]
                for e in te:
                    assert 0 <= e["beat"] < L and e["beat"] + e["duration"] <= L + 1e-6, "tab out of measure"
                    for nn in e["notes"]:
                        assert 1 <= nn["string"] <= 6
                assert m["chords"], "measure without chord"
    return n


def main():
    ap = argparse.ArgumentParser(description="Generate a random AGR v2 score as JSON.")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--per-system", type=int, default=4)
    ap.add_argument("--out", default="-")
    ap.add_argument("--validate", action="store_true", help="also run $AGR_TOOL import on the output (needs --out file)")
    a = ap.parse_args()
    sc = generate_score(a.seed, a.per_system)
    validate_score(sc)
    s = json.dumps(sc, ensure_ascii=False, indent=1)
    if a.out == "-":
        print(s)
    else:
        with open(a.out, "w") as f:
            f.write(s)
        if a.validate:
            tool = os.environ.get("AGR_TOOL")
            if not tool:
                sys.exit("set AGR_TOOL to the agr-tool binary")
            sys.exit(subprocess.call([tool, "import", a.out]))


if __name__ == "__main__":
    main()
