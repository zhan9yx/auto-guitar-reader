"""Render an AGR v2 score (see gen_score.py) to page images with exact per-element ground truth.

Public entry point: `render_score(score, style_name_or_dict, seed, width=None) -> Rendered`.
Drawing happens at SS x supersampling and is downscaled with LANCZOS; all recorded geometry is in 1x pixel units of
the *clean* page (degrade.py maps it through its geometric transforms).
"""
import copy
import os
import random
from functools import lru_cache

from PIL import Image, ImageDraw, ImageFont

import styles as styles_mod

SS = 2
HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.path.join(HERE, "fonts")
FONT_FILES = {
    "sans_sc": "NotoSansSC.ttf", "serif_sc": "NotoSerifSC.ttf", "wenkai": "LXGWWenKai-Regular.ttf",
    "zcool": "ZCOOLXiaoWei-Regular.ttf", "dejavu": "DejaVuSans.ttf", "dejavu_b": "DejaVuSans-Bold.ttf",
    "arimo": "Arimo.ttf", "roboto": "Roboto.ttf", "notosans": "NotoSans.ttf", "mono": "NotoSansMono.ttf",
    "tinos": "Tinos-Regular.ttf",
}


@lru_cache(maxsize=512)
def get_font(key, size_px, weight=400):
    f = ImageFont.truetype(os.path.join(FONT_DIR, FONT_FILES[key]), max(4, int(round(size_px))))
    try:
        axes = f.get_variation_axes()
    except Exception:
        axes = None
    if axes:
        vals = []
        for a in axes:
            nm = a["name"]
            nm = nm.decode() if isinstance(nm, bytes) else nm
            if nm.lower().startswith("weight"):
                vals.append(min(max(weight, a["minimum"]), a["maximum"]))
            else:
                vals.append(a["maximum"] if "width" in nm.lower() else a["default"])
        f.set_variation_by_axes(vals)
    return f


def beam_runs(items, group_q, unit_scale):
    """items: list of (beat, q, active). Returns runs (lists of indices) of consecutive active items with q<=0.5
    inside the same beat group."""
    runs, cur, cur_g = [], [], None
    for i, (beat, q, active) in enumerate(items):
        g = int((beat / unit_scale + 1e-6) // group_q)
        if active and q <= 0.5 + 1e-9:
            if cur and g == cur_g:
                cur.append(i)
            else:
                if cur:
                    runs.append(cur)
                cur, cur_g = [i], g
        else:
            if cur:
                runs.append(cur)
            cur, cur_g = [], None
    if cur:
        runs.append(cur)
    return runs


class Canvas:
    def __init__(self, W, H, style, page_index):
        self.W, self.H, self.style = W, H, style
        self.img = Image.new("RGB", (W * SS, H * SS), (255, 255, 255))
        self.d = ImageDraw.Draw(self.img)
        self.els = []
        self.page = page_index
        self.ink = tuple(style["ink"])
        self.ctx = {}  # current system / measure tags added to every element
        self.systems = []

    # --- helpers
    @staticmethod
    def S(v):
        return int(round(v * SS))

    def add(self, label, bbox, nonScore=False, **kw):
        e = {"id": len(self.els), "label": label, "bbox": [round(float(v), 2) for v in bbox], "nonScore": nonScore}
        e.update(self.ctx)
        e.update(kw)
        self.els.append(e)
        return e

    def _t(self, w):
        return max(1, int(round(w * SS)))

    def hline(self, x0, x1, y, w, fill=None, label=None, **kw):
        t = self._t(w)
        top = self.S(y) - (t - 2) // 2
        self.d.rectangle([self.S(x0), top, self.S(x1) - 1, top + t - 1], fill=fill or self.ink)
        bb = [x0, top / SS, x1, (top + t) / SS]
        if label:
            self.add(label, bb, **kw)
        return bb

    def vline(self, x, y0, y1, w, fill=None, label=None, **kw):
        t = self._t(w)
        left = self.S(x) - (t - 2) // 2
        self.d.rectangle([left, self.S(y0), left + t - 1, self.S(y1) - 1], fill=fill or self.ink)
        bb = [left / SS, y0, (left + t) / SS, y1]
        if label:
            self.add(label, bb, **kw)
        return bb

    def line(self, x0, y0, x1, y1, w, fill=None):
        self.d.line([self.S(x0), self.S(y0), self.S(x1), self.S(y1)], fill=fill or self.ink, width=self._t(w))

    def rect(self, bb, fill=None, outline=None, w=1):
        self.d.rectangle([self.S(bb[0]), self.S(bb[1]), self.S(bb[2]), self.S(bb[3])], fill=fill, outline=outline,
                         width=self._t(w) if outline else 0)

    def circle(self, cx, cy, r, fill=None, outline=None, w=1):
        self.d.ellipse([self.S(cx - r), self.S(cy - r), self.S(cx + r), self.S(cy + r)], fill=fill, outline=outline,
                       width=self._t(w) if outline else 0)

    def poly(self, pts, fill=None):
        self.d.polygon([(self.S(x), self.S(y)) for x, y in pts], fill=fill or self.ink)

    def arc_up(self, x0, x1, y, h, w, fill=None):
        """Arc bulging upwards between x0 and x1 with its chord at y and height h."""
        self.d.arc([self.S(x0), self.S(y - h), self.S(x1), self.S(y + h)], 180, 360, fill=fill or self.ink, width=self._t(w))
        return [x0, y - h, x1, y + 1]

    def text(self, x, y, s, font, anchor="ls", fill=None, label=None, **kw):
        fill = fill or self.ink
        self.d.text((self.S(x), self.S(y)), s, font=font, fill=fill, anchor=anchor)
        bb = self.d.textbbox((self.S(x), self.S(y)), s, font=font, anchor=anchor)
        bb = [v / SS for v in bb]
        if label:
            self.add(label, bb, text=s, **kw)
        return bb

    def finish(self):
        return self.img.resize((self.W, self.H), Image.LANCZOS)


# ------------------------------------------------------------------------------------------------ policy

def prepare_score(score, style, rng):
    """Deep copy of the score with what is *printed* applied: diagram shapes only when a diagram is drawn,
    section names only when labels are shown. Returns (score, diagram_flags)."""
    sc = copy.deepcopy(score)
    dm = style["diagram"]["mode"]
    seen = set()
    prev = None
    flags = {}
    show_labels = style["sections_named"] and style["section"] != "none"
    sidx = 0
    new_sections = []
    for si, sec in enumerate(sc["sections"]):
        for li, line in enumerate(sec["lines"]):
            for mi, m in enumerate(line["system"]["measures"]):
                for ci, cm in enumerate(m["chords"]):
                    name = cm["name"]
                    if dm == "all":
                        show = True
                    elif dm == "none":
                        show = False
                    elif dm == "change":
                        show = name != prev
                    else:  # first
                        show = name not in seen
                    seen.add(name)
                    prev = name
                    flags[(si, li, mi, ci)] = show
                    cm["shape"] = copy.deepcopy(sc["chordDefinitions"][name]) if show else None
                m["marks"] = [x for x in m["marks"]]
        if show_labels:
            sec["lines"][0]["system"]["measures"][0]["marks"].insert(0, sec["name"])
            new_sections.append(sec)
        else:
            # no labels printed: one anonymous section per system
            for li, line in enumerate(sec["lines"]):
                new_sections.append({"id": "s%d" % sidx, "name": "", "kind": "other", "strumPatternID": None, "lines": [line]})
                sidx += 1
    if not show_labels:
        # flags keys referenced (si, li) -> keep a mapping through line ids
        pass
    sc["sections"] = new_sections
    sc["_flags_by_line"] = None
    return sc, flags


# ------------------------------------------------------------------------------------------------ main renderer

class Rendered:
    def __init__(self):
        self.pages = []   # dict(img, elements, systems)
        self.score = None
        self.W = self.H = 0
        self.style = None


def render_score(score, style, seed=0, width=None, aspect=None):
    rng = random.Random(seed ^ 0x5EED)
    if isinstance(style, str):
        style = styles_mod.get_style(style)
    style = copy.deepcopy(style)
    W = width or rng.randint(style["width"][0], style["width"][1])
    ratio = aspect or rng.uniform(*style["aspect"])
    H = int(round(W * ratio))
    k = W / 1080.0
    u = style["u"] * k * rng.uniform(0.95, 1.06)
    # keep original line ids -> diagram flags
    sc0 = copy.deepcopy(score)
    line_flags = {}
    for si, sec in enumerate(sc0["sections"]):
        for li, line in enumerate(sec["lines"]):
            line["_key"] = (si, li)
    sc, flags = prepare_score(sc0, style, rng)
    R = Renderer(sc, style, flags, W, H, u, k, rng)
    return R.run()


class Renderer:
    def __init__(self, sc, style, flags, W, H, u, k, rng):
        self.sc, self.st, self.flags, self.W, self.H, self.u, self.k, self.rng = sc, style, flags, W, H, u, k, rng
        self.meta = sc["meta"]
        ts = self.meta["timeSignature"]
        self.ts = (ts["beats"], ts["unit"])
        self.unit_scale = ts["unit"] / 4.0
        self.group_q = 1.5 if self.ts == (6, 8) else 1.0
        self.full_beats = float(ts["beats"])
        self.ink = tuple(style["ink"])
        lc = style["line_color"] or (style["line_gray"],) * 3
        self.line_col = tuple(lc)
        self.chord_col = tuple(style["chord_color"]) if style["chord_color"] else self.ink
        self.pages = []
        self.rendered = Rendered()
        self.sys_counter = 0
        self.ps_max = 1

    # fonts
    def F(self, role, size_u, mul=1.0):
        key, wt = self.st[role]
        return get_font(key, size_u * self.u * SS * mul, wt)

    # ---------------------------------------------------------------- run
    def run(self):
        st, u, W, H = self.st, self.u, self.W, self.H
        systems = []
        for si, sec in enumerate(self.sc["sections"]):
            for li, line in enumerate(sec["lines"]):
                systems.append(dict(si=si, li=li, line=line, key=line.get("_key"), first=(li == 0)))
        self.ps_max = max(len(s["line"]["system"]["measures"]) for s in systems)
        self.pageno_fmt = st["page_no"]
        cv = self.new_page()
        y = self.draw_header(cv, first=True)
        bottom_limit = H - st["margin_bottom"] * self.k
        first_sys = True
        for sd in systems:
            h = self.system_height(sd)
            if y + h > bottom_limit and not (y < st["margin_top"] * self.k + 5):
                cv = self.new_page()
                y = self.draw_header(cv, first=False)
            sd["page"] = len(self.pages) - 1
            y = self.draw_system(cv, sd, y, first_sys)
            first_sys = False
        N = len(self.pages)
        out = self.rendered
        for i, cv in enumerate(self.pages):
            self.draw_page_number(cv, i + 1, N)
            out.pages.append(dict(img=cv.finish(), elements=cv.els, systems=cv.systems))
        out.score = self.sc
        out.W, out.H, out.style = W, H, st
        return out

    def new_page(self):
        cv = Canvas(self.W, self.H, self.st, len(self.pages))
        self.pages.append(cv)
        return cv

    # ---------------------------------------------------------------- header / footer
    def draw_page_number(self, cv, n, N):
        st = self.st
        txt = st["page_no"].format(n=n, N=N)
        f = get_font("arimo", 1.6 * self.u * SS, 400) if "第" not in txt else get_font("sans_sc", 1.5 * self.u * SS, 400)
        cv.ctx = {}
        y = self.H - st["margin_bottom"] * self.k * 0.45
        cv.text(self.W / 2, y, txt, f, anchor="mm", fill=(60, 60, 60) if sum(self.ink) < 100 else self.ink,
                label="page_number", nonScore=True)

    def draw_header(self, cv, first):
        st, u, W = self.st, self.u, self.W
        m = self.meta
        hd = st["header"]
        top = st["margin_top"] * self.k
        cv.ctx = {}
        if not first:
            f = self.F("f_info", 1.5)
            cv.text(W - st["margin_r"] * self.k, top * 0.55, "%s - %s" % (m["title"], m.get("artist") or ""), f, anchor="rm",
                    fill=(110, 110, 110), label="page_header", nonScore=True)
            return top * 0.75
        lay = hd["layout"]
        ml = st["margin_l"] * self.k
        mr = W - st["margin_r"] * self.k
        y = top
        tf = self.F("f_title", hd["title_fs"])
        af = self.F("f_artist", hd["artist_fs"])
        inf = self.F("f_info", hd["info_fs"])
        tcol = self.ink
        if lay == "center":
            bb = cv.text(W / 2, y + hd["title_fs"] * u * 0.75, m["title"], tf, anchor="ms", fill=tcol, label="header_title")
            y = bb[3] + 0.9 * u
            if m.get("artist"):
                bb = cv.text(W / 2, y + hd["artist_fs"] * u * 0.78, m["artist"], af, anchor="ms", label="header_artist")
                y = bb[3] + 0.5 * u
        elif lay == "left":
            bb = cv.text(ml, y + hd["title_fs"] * u * 0.75, m["title"], tf, anchor="ls", label="header_title")
            y = bb[3] + 0.7 * u
            if m.get("artist"):
                bb = cv.text(ml, y + hd["artist_fs"] * u * 0.78, m["artist"], af, anchor="ls", label="header_artist")
                y = bb[3] + 0.4 * u
        else:  # boxed / decorated
            bb = cv.text(W / 2, y + hd["title_fs"] * u * 0.75, m["title"], tf, anchor="ms", label="header_title")
            cv.hline(ml, mr, bb[3] + 0.6 * u, 1.2, fill=self.line_col)
            y = bb[3] + 1.2 * u
            if m.get("artist"):
                bb = cv.text(W / 2, y + hd["artist_fs"] * u * 0.78, m["artist"], af, anchor="ms", label="header_artist")
                y = bb[3] + 0.5 * u
            cv.hline(ml, mr, y + 0.5 * u, 0.8, fill=self.line_col)
            y += 0.9 * u
        # credits (right aligned under artist or left)
        crow_y = y + 1.0 * u
        right_items = []
        for c in m["credits"]:
            right_items.append(c)
        # info row: key + timesig left; capo / tempo / credits right
        y = max(y, top) + 0.8 * u
        base = y + hd["info_fs"] * u * 0.85
        x = ml
        kname = m["key"] or "C"
        ktxt = hd["key_fmt"].format(k=kname)
        bb = cv.text(x, base, ktxt, inf if hd["key_fmt"][:1] in "1K原" and False else self.F("f_text", hd["info_fs"] * 1.05), anchor="ls",
                     label="header_key", value=kname)
        x = bb[2] + 0.6 * u
        if hd["ts_header"]:
            fn = self.F("f_clef", 1.15)
            a, b = str(self.ts[0]), str(self.ts[1])
            cx = x + 0.7 * u
            b1 = cv.text(cx, base - 0.95 * u, a, fn, anchor="ms", label="header_timesig", part="beats")
            cv.hline(cx - 0.5 * u, cx + 0.5 * u, base - 0.72 * u, 1.0)
            b2 = cv.text(cx, base + 0.45 * u, b, fn, anchor="ms", label="header_timesig", part="unit")
            x = cx + 1.5 * u
        # right side: capo / tempo
        rx = mr
        parts = []
        if m["capo"] > 0:
            parts.append((self.rng.choice(["变调夹：{c}品", "Capo {c}", "Capo: {c}", "CAPO {c}", "变调夹 {c} 品", "{c}品变调夹"]).format(c=m["capo"]), "header_capo"))
        tempo = int(m["tempo"])
        parts.append((self.rng.choice(["♩={t}", "♩ = {t}", "速度：{t}", "Tempo {t}", "BPM={t}", "演奏速度 ♩={t}"]).format(t=tempo), "header_tempo"))
        if m["capo"] > 0 and self.rng.random() < 0.3:
            parts.append(("原调 %s  选调 %s" % (self.rng.choice(["G", "C", "D", "A", "E"]), kname), "header_origkey"))
        for txt, lab in parts:
            fam = "f_text" if any(ord(c) > 0x2000 and c not in "♩" for c in txt) else "f_text"
            font = self.F(fam, hd["info_fs"])
            if "♩" in txt:
                # note glyph is not in CJK fonts everywhere: draw with DejaVu
                font = get_font("dejavu", hd["info_fs"] * u * SS, 400)
            bb = cv.text(rx, base, txt, font, anchor="rs", label=lab, value=(m["capo"] if lab == "header_capo" else tempo))
            rx = bb[0] - 1.6 * u
        yb = base + 0.9 * u
        if m["credits"]:
            cf = self.F("f_info", hd["info_fs"] * 0.85)
            cy = base + 0.4 * u
            for c in m["credits"]:
                bb = cv.text(mr, cy + 1.5 * u, c, cf, anchor="rs", label="header_credit", value=c)
                cy = bb[3] + 0.3 * u
            yb = max(yb, cy + 0.3 * u)
        return yb + 2.0 * u

    # ---------------------------------------------------------------- geometry
    def measure_weights(self, ms):
        ws = []
        for m in ms:
            L = m["beats"] if m["beats"] is not None else self.full_beats
            w = 0.35 + 0.65 * L / self.full_beats
            if any(abs(n["duration"] / self.unit_scale - 0.25) < 1e-9 for n in m["melody"]):
                w += 0.3
            ws.append(w)
        return ws

    def diagram_dims(self):
        d = self.st["diagram"]
        u = self.u
        sx, sy = d["sx"] * u, d["sy"] * u
        return sx, sy, 5 * sx, d["rows"] * sy

    def system_height(self, sd):
        st, u = self.st, self.u
        ms = sd["line"]["system"]["measures"]
        has_label = sd["first"] and st["sections_named"] and st["section"] != "none"
        sd["has_label"] = has_label
        h = 0.0
        if has_label:
            h += 2.3 * u
        # chord row
        key = sd["key"]
        any_diag = any(self.flags.get((key[0], key[1], mi, ci), False) for mi, m in enumerate(ms) for ci in range(len(m["chords"])))
        sd["any_diag"] = any_diag
        name_h = 1.9 * u
        if any_diag:
            sx, sy, gw, gh = self.diagram_dims()
            h += name_h + 0.9 * u + gh + 0.7 * u
        else:
            h += name_h + 0.5 * u
        if any(m["volta"] for m in ms):
            h += 1.6 * u
        h += 0.7 * u + 5 * u + st["stem_len"] * u + 0.5 * u
        h += st["jp"]["gap"] * u
        h += 3.4 * u  # jianpu row
        v = sd["line"]["system"]["measures"]
        vc = max((len(n["lyrics"]) for m in v for n in m["melody"]), default=0)
        sd["verses"] = vc
        h += vc * st["lyr"]["row_h"] * u
        h += 2.4 * u
        return h

    # ---------------------------------------------------------------- system
    def draw_system(self, cv, sd, y, first_sys):
        st, u, W = self.st, self.u, self.W
        ms = sd["line"]["system"]["measures"]
        si, li = sd["si"], sd["li"]
        sys_idx = self.sys_counter
        self.sys_counter += 1
        cv.ctx = {"sys": sys_idx, "sec": si, "line": li}
        y_start = y
        x0 = st["margin_l"] * self.k
        x1 = W - st["margin_r"] * self.k
        n = len(ms)
        # chord/label rows
        if sd["has_label"]:
            self.draw_section_label(cv, ms[0]["marks"][0] if ms[0]["marks"] else "", x0, y + 0.2 * u)
            y += 2.3 * u
        chord_top = y
        name_h = 1.9 * u
        if sd["any_diag"]:
            sx, sy, gw, gh = self.diagram_dims()
            y += name_h + 0.9 * u + gh + 0.7 * u
        else:
            y += name_h + 0.5 * u
        volta_y = None
        if any(m["volta"] for m in ms):
            volta_y = y + 0.9 * u
            y += 1.6 * u
        y += 0.7 * u
        staff_top = round(y)
        ly = [round(staff_top + i * u) for i in range(6)]
        staff_bot = ly[5]
        # horizontal extents
        clef_w = 4.6 * u
        first_piece = first_sys
        ts_w = 2.4 * u if (first_piece and True) else 0
        frac = 1.0
        if st["short_lines"] == "natural" and n < self.ps_max:
            frac = max(0.55, n / self.ps_max)
        avail_tot = (x1 - x0) * frac
        xs_end = x0 + avail_tot
        avail = avail_tot - clef_w - ts_w
        ws = self.measure_weights(ms)
        sw = sum(ws)
        bounds = []
        cx = x0 + clef_w + ts_w
        for w in ws:
            bounds.append((cx, cx + avail * w / sw))
            cx += avail * w / sw
        sys_bbox_top = y_start
        # staff lines
        cv.ctx.update({"m": None})
        for i in range(6):
            cv.hline(x0, xs_end, ly[i], st["line_w"], fill=self.line_col, label="staff_line", string=i + 1)
        # clef
        self.draw_clef(cv, x0, ly, first_piece)
        # jianpu geometry
        jp_gap = st["jp"]["gap"] * u
        stem_bottom = staff_bot + 0.3 * u + st["stem_len"] * u
        jp_yc = stem_bottom + 0.5 * u + jp_gap + 1.2 * u - 0.6 * u
        jp_h = 2.2 * u
        jp_top, jp_bot = jp_yc - jp_h / 2, jp_yc + jp_h / 2
        # barlines + measure content
        geom = []
        for mi, m in enumerate(ms):
            mx0, mx1 = bounds[mi]
            L = m["beats"] if m["beats"] is not None else self.full_beats
            padL = 2.1 * u + (1.6 * u if m["leftBarline"] in ("startRepeat", "startEndRepeat") else 0)
            padR = 1.3 * u + (1.6 * u if m["rightBarline"] in ("endRepeat", "startEndRepeat", "final") else 0)
            if mi + 1 < n and ms[mi + 1]["leftBarline"] in ("startRepeat", "startEndRepeat"):
                padR += 1.4 * u
            if mi > 0 and ms[mi - 1]["rightBarline"] in ("endRepeat", "startEndRepeat"):
                padL += 1.0 * u
            if mi == 0:
                padL -= 0.6 * u
            geom.append(dict(mx0=mx0, mx1=mx1, L=L, ix0=mx0 + padL, iw=mx1 - mx0 - padL - padR))
        for mi, m in enumerate(ms):
            g = geom[mi]
            cv.ctx.update({"m": mi})
            cv.add("measure", [g["mx0"], ly[0], g["mx1"], ly[5]], beats=g["L"])
        # barlines at boundaries
        for bi in range(n + 1):
            x = x0 if bi == 0 else (bounds[bi - 1][1])
            prev_r = ms[bi - 1]["rightBarline"] if bi > 0 else None
            cur_l = ms[bi]["leftBarline"] if bi < n else None
            cv.ctx.update({"m": bi})
            self.draw_barline(cv, x, ly[0], ly[5], prev_r, cur_l, "barline", rows=(ly[0] + 1.5 * u, ly[0] + 3.5 * u),
                              line_w=st["bar_w"])
            if st["jp"]["bars"]:
                bh = 0.95 * u
                self.draw_barline(cv, x, jp_yc - bh, jp_yc + bh * 0.9, prev_r, cur_l, "jianpu_barline",
                                  rows=(jp_yc - 0.4 * u, jp_yc + 0.4 * u), line_w=st["bar_w"], jp=True)
        if st["sys_line"]:
            cv.vline(x0, ly[5], jp_yc + 1.0 * u, st["bar_w"], label="system_line")
        # jianpu font shrink so adjacent digits never touch
        gap_min = 1e9
        for mi, m in enumerate(ms):
            for n in m["melody"]:
                gap_min = min(gap_min, n["duration"] / geom[mi]["L"] * geom[mi]["iw"])
        self.jp_fs_sys = max(1.5, min(st["jp"]["fs"], gap_min / (0.6 * 1.15 * u)))
        # chords, tab, jianpu, lyrics
        all_notes = []
        lyr_bottoms = []
        for mi, m in enumerate(ms):
            g = geom[mi]
            cv.ctx.update({"m": mi})
            self.draw_chords(cv, sd, mi, m, g, chord_top, name_h, ly)
            if m["volta"]:
                self.draw_volta(cv, g, volta_y, m["volta"], ly[0])
            self.draw_tab(cv, m, g, ly)
            notes = self.draw_jianpu(cv, m, g, jp_yc, mi)
            all_notes.append(notes)
        self.draw_ties(cv, ms, all_notes, jp_yc)
        # lyrics
        lyr_y0 = jp_yc + 1.9 * u
        nverse = sd["verses"]
        lyr_fs = st["lyr"]["fs"]
        # shrink if neighbours would collide
        for v in range(nverse):
            xs = sorted(nt["x"] for notes in all_notes for nt in notes if nt["lyr"][v:v + 1] and nt["lyr"][v])
            if len(xs) > 1:
                gap = min(b - a for a, b in zip(xs, xs[1:]))
                lyr_fs = min(lyr_fs, max(gap / u * 0.92, 1.5))
        lf = self.F("f_lyric", lyr_fs)
        for v in range(nverse):
            yy = lyr_y0 + (v + 0.5) * st["lyr"]["row_h"] * u
            for mi, notes in enumerate(all_notes):
                cv.ctx.update({"m": mi})
                for nt in notes:
                    if nt["lyr"][v:v + 1] and nt["lyr"][v]:
                        s = nt["lyr"][v]
                        main, punct = s[0], s[1:]
                        bb = cv.text(nt["x"], yy, main, lf, anchor="mm", label="lyric_char", verse=v, note=nt["idx"], value=main)
                        if punct:
                            cv.text(bb[2] + 0.1 * u, yy + 0.5 * u, punct, lf, anchor="lm", label="lyric_punct", verse=v,
                                    note=nt["idx"], value=punct)
        y_end = lyr_y0 + nverse * st["lyr"]["row_h"] * u + (0.4 * u if nverse == 0 else 0)
        # whole-system bbox
        cv.ctx = {"sys": sys_idx, "sec": si, "line": li}
        sys_top = y_start + (0.0 if True else 0)
        sys_box = [x0, chord_top - (0 if not sd["has_label"] else 0), xs_end, max(y_end, jp_bot + 0.3 * u)]
        cv.add("system", sys_box, measures=n, verses=nverse)
        self.pages[sd["page"]].systems.append(dict(sys=sys_idx, sec=si, line=li, bbox=[round(v, 2) for v in sys_box]))
        cv.ctx = {}
        sd["bbox"] = sys_box
        return y_end + 2.2 * u

    # ---------------------------------------------------------------- pieces
    def draw_section_label(self, cv, text, x, y):
        st, u = self.st, self.u
        if not text:
            return
        f = self.F("f_label", 1.55)
        if st["section"] == "box":
            bb0 = cv.d.textbbox((0, 0), text, font=f, anchor="ls")
            w = (bb0[2] - bb0[0]) / SS
            pad = 0.55 * u
            box = [x, y, x + w + 2 * pad, y + 1.9 * u]
            cv.rect(box, outline=self.ink, w=1.2)
            cv.text(x + pad, y + 1.45 * u, text, f, anchor="ls", label="section_label", value=text, box=True)
        else:
            cv.text(x, y + 1.5 * u, text, f, anchor="ls", label="section_label", value=text, box=False)

    def draw_clef(self, cv, x0, ly, first_piece):
        st, u = self.st, self.u
        top = ly[0]
        if st["clef"] == "stack":
            f = self.F("f_clef", 1.25)
            cx = x0 + 1.4 * u
            for i, ch in enumerate("TAB"):
                cv.text(cx, top + (0.9 + 1.7 * i) * u, ch, f, anchor="mm", label="tab_clef", value=ch)
        else:
            f = self.F("f_clef", 1.6)
            tmp = Image.new("L", (int(5 * u * SS), int(2.6 * u * SS)), 0)
            ImageDraw.Draw(tmp).text((tmp.width // 2, tmp.height // 2), "TAB", font=f, fill=255, anchor="mm")
            tmp = tmp.rotate(90, expand=True)
            bb = tmp.getbbox()
            tmp = tmp.crop(bb)
            px = int(round((x0 + 1.4 * u) * SS - tmp.width / 2))
            py = int(round(((top + ly[5]) / 2) * SS - tmp.height / 2))
            cv.img.paste(Image.new("RGB", tmp.size, cv.ink), (px, py), tmp)
            cv.add("tab_clef", [px / SS, py / SS, (px + tmp.width) / SS, (py + tmp.height) / SS], value="TAB")
        if first_piece:
            f = self.F("f_clef", 1.9)
            cx = x0 + 4.6 * u + 1.2 * u
            cv.text(cx, top + 1.3 * u, str(self.ts[0]), f, anchor="mm", label="tab_timesig", part="beats")
            cv.text(cx, top + 3.8 * u, str(self.ts[1]), f, anchor="mm", label="tab_timesig", part="unit")

    def draw_barline(self, cv, x, y0, y1, prev_r, cur_l, label, rows, line_w, jp=False):
        st, u = self.st, self.u
        thick = st["thick_w"] * self.k if not jp else st["thick_w"] * self.k * 0.8
        col = self.ink if jp else self.ink
        lw = line_w
        kind = "single"
        dots_l = dots_r = False
        if prev_r in ("endRepeat", "startEndRepeat") and cur_l in ("startRepeat", "startEndRepeat"):
            kind = "startEndRepeat"
        elif prev_r == "startEndRepeat":
            kind = "startEndRepeat"
        elif prev_r == "endRepeat":
            kind = "endRepeat"
        elif cur_l in ("startRepeat", "startEndRepeat"):
            kind = "startRepeat"
        elif prev_r == "double":
            kind = "double"
        elif prev_r == "final":
            kind = "final"
        xs = []
        if kind == "single":
            b = cv.vline(x, y0, y1, lw, fill=col)
            bbs = [b]
        elif kind == "double":
            bbs = [cv.vline(x - 0.2 * u, y0, y1, lw), cv.vline(x + 0.2 * u, y0, y1, lw)]
        elif kind == "final":
            bbs = [cv.vline(x - 0.5 * u, y0, y1, lw), cv.vline(x, y0, y1, thick)]
        elif kind == "endRepeat":
            bbs = [cv.vline(x - 0.5 * u, y0, y1, lw), cv.vline(x, y0, y1, thick)]
            dots_l = True
        elif kind == "startRepeat":
            bbs = [cv.vline(x, y0, y1, thick), cv.vline(x + 0.5 * u, y0, y1, lw)]
            dots_r = True
        else:
            bbs = [cv.vline(x - 0.15 * u - 0.35 * u, y0, y1, lw), cv.vline(x + 0.15 * u + 0.35 * u, y0, y1, lw)]
            dots_l = dots_r = True
        r = max(1.3, 0.2 * u)
        for flag, off in ((dots_l, -1.0 * u), (dots_r, 1.05 * u)):
            if flag:
                for yy in rows:
                    cv.circle(x + off, yy, r, fill=col)
                    bbs.append([x + off - r, yy - r, x + off + r, yy + r])
        bb = [min(b[0] for b in bbs), y0, max(b[2] for b in bbs), y1]
        cv.add(label, bb, kind=kind, x=round(x, 2))

    def draw_volta(self, cv, g, y, volta, staff_top):
        u = self.u
        f = self.F("f_text", 1.15)
        x0, x1 = g["mx0"] + 0.2 * u, g["mx1"] - 0.2 * u
        yy = round(y)
        bb1 = cv.hline(x0, x1, yy, 1.1)
        bb2 = cv.vline(x0, yy, yy + 1.0 * u, 1.1)
        txt = ",".join(str(v) for v in volta) + "."
        bb3 = cv.text(x0 + 0.35 * u, yy + 1.0 * u, txt, f, anchor="ls")
        cv.add("volta", [x0, yy - 1, x1, max(bb3[3], yy + 1.0 * u)], numbers=list(volta))

    # ---------------------------------------------------------------- chords
    def draw_chords(self, cv, sd, mi, m, g, chord_top, name_h, ly):
        st, u = self.st, self.u
        dg = st["diagram"]
        key = sd["key"]
        f = get_font(st["f_chord"][0], u * SS * dg["name_scale"], st["f_chord"][1] + (150 if dg["name_bold"] else 0))
        for ci, cm in enumerate(m["chords"]):
            ex = g["ix0"] + cm["beat"] / g["L"] * g["iw"]
            show_diag = self.flags.get((key[0], key[1], mi, ci), False) if key else False
            sx, sy, gw, gh = self.diagram_dims()
            half = max(gw / 2 + 0.6 * u, 0)
            cxm = min(max(ex + 0.9 * u, g["mx0"] + half), g["mx1"] - half) if show_diag else ex + 0.6 * u
            if not show_diag:
                cxm = min(max(cxm, g["mx0"] + 1.0 * u), g["mx1"] - 1.0 * u)
            nm_y = chord_top + name_h * 0.85
            if sd["any_diag"] and not show_diag:
                nm_y = chord_top + name_h * 0.85
            bb = cv.text(cxm, nm_y, cm["name"], f, anchor="ms", fill=self.chord_col, label="chord_name",
                         value=cm["name"], chord=ci, beat=cm["beat"])
            if show_diag and cm.get("shape"):
                self.draw_diagram(cv, cm, cxm, chord_top + name_h + 0.9 * u, ci)

    def draw_diagram(self, cv, cm, cx, top, ci):
        st, u = self.st, self.u
        dg = st["diagram"]
        sx, sy, gw, gh = self.diagram_dims()
        shape = cm["shape"]
        frets, base = shape["frets"], shape["baseFret"]
        fingers = shape.get("fingers") or [0] * 6
        rows = dg["rows"]
        col = tuple(dg["color"]) if dg["color"] else self.ink
        dcol = tuple(dg["dot_color"]) if dg["dot_color"] else self.ink
        x0 = cx - gw / 2
        lw = dg["lw"]
        # grid
        for i in range(6):
            cv.vline(x0 + i * sx, top, top + gh, lw, fill=col)
        for j in range(rows + 1):
            w = dg["nut"] if (j == 0 and base == 1) else lw
            cv.hline(x0, x0 + gw, round(top + j * sy), w, fill=col)
        grid_bb = [x0, top, x0 + gw, top + gh]
        # base fret number
        bbs = [grid_bb]
        if base > 1:
            fnt = get_font("arimo", 0.8 * u * SS, 400)
            bbs.append(cv.text(x0 - 0.35 * u, top + 0.55 * sy, str(base), fnt, anchor="rm", fill=col,
                               label="chord_basefret", value=base))
        # barre detection
        r = dg["dot_r"] * sx * 1.9 / 2 + 0.1
        r = max(r, 2.0)
        fretted = [f for f in frets if f > 0]
        barre_done = False
        if dg["barre"] and fretted:
            mn = min(fretted)
            idx = [i for i, f in enumerate(frets) if f == mn]
            if len(idx) >= 3 and (idx[-1] - idx[0]) >= 3:
                yy = top + (mn - base + 0.5) * sy
                cv.d.rounded_rectangle([cv.S(x0 + idx[0] * sx - r), cv.S(yy - r * 0.8), cv.S(x0 + idx[-1] * sx + r), cv.S(yy + r * 0.8)],
                                       radius=cv.S(r * 0.8), fill=dcol)
                barre_done = True
                cv.add("chord_barre", [x0 + idx[0] * sx - r, yy - r * 0.8, x0 + idx[-1] * sx + r, yy + r * 0.8],
                       strings=[6 - i for i in (idx[0], idx[-1])], fret=mn)
        for i, f in enumerate(frets):
            sxp = x0 + i * sx
            if f > 0:
                row = f - base
                if not (0 <= row < rows):
                    continue
                yy = top + (row + 0.5) * sy
                skip_draw = barre_done and f == min(fretted) and any(frets[j] == f for j in range(i)) and False
                if not (barre_done and f == min(fretted)):
                    if dg["dot"] == "square":
                        cv.rect([sxp - r, yy - r, sxp + r, yy + r], fill=dcol)
                    else:
                        cv.circle(sxp, yy, r, fill=dcol)
                    if dg["dot"] == "finger" and fingers[i]:
                        fnt = get_font("arimo", r * 1.6 * SS, 700)
                        cv.d.text((cv.S(sxp), cv.S(yy)), str(fingers[i]), font=fnt, fill=(255, 255, 255), anchor="mm")
                cv.add("chord_dot", [sxp - r, yy - r, sxp + r, yy + r], string=6 - i, fret=f, finger=fingers[i])
            elif f in (0, -1):
                my = top - 0.5 * sx - 0.3 * u * 0.5
                mr = 0.2 * sx + 0.8
                if f == 0:
                    cv.circle(sxp, my, mr, outline=col, w=0.9)
                else:
                    cv.line(sxp - mr, my - mr, sxp + mr, my + mr, 0.9, fill=col)
                    cv.line(sxp - mr, my + mr, sxp + mr, my - mr, 0.9, fill=col)
                bbs.append([sxp - mr, my - mr, sxp + mr, my + mr])
                cv.add("chord_marker", [sxp - mr, my - mr, sxp + mr, my + mr], string=6 - i, kind="open" if f == 0 else "muted")
        bb = [min(b[0] for b in bbs) - 0.5, min(b[1] for b in bbs), max(b[2] for b in bbs), max(b[3] for b in bbs)]
        cv.add("chord_diagram", bb, grid=[round(v, 2) for v in grid_bb], name=cm["name"], chord=ci,
               frets=frets, baseFret=base)

    # ---------------------------------------------------------------- tab
    def cross(self, cv, x, y, string, **kw):
        st, u = self.st, self.u
        c = st["cross"]
        r = c["r"] * u
        if st["halo"]:
            cv.rect([x - r - 1, y - r - 1, x + r + 1, y + r + 1], fill=(255, 255, 255))
        if c["mode"] == "draw":
            cv.line(x - r, y - r, x + r, y + r, c["w"] * self.k, fill=self.ink)
            cv.line(x - r, y + r, x + r, y - r, c["w"] * self.k, fill=self.ink)
            bb = [x - r, y - r, x + r, y + r]
            cv.add("tab_cross", bb, string=string, **kw)
        else:
            ch = "×" if c["mode"] == "glyph" else "x"
            font = get_font(st["f_digit"][0] if c["mode"] == "letter" else "dejavu_b", u * SS * (1.5 if c["mode"] == "glyph" else 1.3),
                            st["f_digit"][1])
            cv.text(x, y, ch, font, anchor="mm", label="tab_cross", string=string, **kw)

    def draw_tab(self, cv, m, g, ly):
        st, u = self.st, self.u
        events = m["tab"]
        L = g["L"]
        dfont = get_font(st["f_digit"][0], u * SS * st["digit_scale"], st["f_digit"][1])
        items = []
        pos = []
        for ei, e in enumerate(events):
            x = g["ix0"] + e["beat"] / L * g["iw"]
            pos.append(x)
            q = e["duration"] / self.unit_scale
            items.append((e["beat"], q, bool(e["notes"])))
            if not e["notes"]:
                y = ly[2]
                hw = 0.5 * u
                cv.rect([x - hw - 1, y - 2, x + hw + 1, y + 2], fill=(255, 255, 255))
                cv.hline(x - hw, x + hw, y, max(1.8, st["line_w"] * 1.8), label="tab_rest", event=ei, beat=e["beat"])
                continue
            ys = [ly[n["string"] - 1] for n in e["notes"]]
            if "stroke" in e:
                self.draw_strum(cv, e, ei, x, ly)
                continue
            for n in e["notes"]:
                y = ly[n["string"] - 1]
                if n.get("chordTone"):
                    self.cross(cv, x, y, n["string"], event=ei, beat=e["beat"])
                else:
                    s = str(n["fret"])
                    bb0 = cv.d.textbbox((0, 0), s, font=dfont, anchor="mm")
                    w, h = (bb0[2] - bb0[0]) / SS, (bb0[3] - bb0[1]) / SS
                    if st["halo"]:
                        cv.rect([x - w / 2 - 1, y - h / 2 - 1, x + w / 2 + 1, y + h / 2 + 1], fill=(255, 255, 255))
                    cv.text(x, y, s, dfont, anchor="mm", label="tab_fret", string=n["string"], value=n["fret"],
                            event=ei, beat=e["beat"], technique=n.get("technique"))
        # hammer / pull arcs
        for ei in range(1, len(events)):
            for n in events[ei]["notes"]:
                tq = n.get("technique")
                if tq in ("hammerOn", "pullOff") and not n.get("chordTone"):
                    prev = [p for p in events[ei - 1]["notes"] if p["string"] == n["string"]]
                    if not prev:
                        continue
                    xa, xb = pos[ei - 1], pos[ei]
                    y = ly[n["string"] - 1] - 0.85 * u
                    bb = cv.arc_up(xa + 0.1 * u, xb - 0.1 * u, y + 0.2 * u, 0.5 * u, 1.1 * self.k)
                    f = get_font("arimo", u * SS * 0.95, 600)
                    lab = "H" if tq == "hammerOn" else "P"
                    t = cv.text((xa + xb) / 2, y - 0.35 * u, lab, f, anchor="ms", label="tab_technique", value=lab,
                                event=ei, string=n["string"])
                    cv.add("tab_arc", bb, event=ei, string=n["string"], kind=tq)
        # stems / beams
        if st["stem_len"] > 0:
            self.draw_stems(cv, events, items, pos, ly)

    def draw_strum(self, cv, e, ei, x, ly):
        st, u = self.st, self.u
        strs = sorted(n["string"] for n in e["notes"])
        smin, smax = strs[0], strs[-1]
        yt, yb = ly[smin - 1], ly[smax - 1]
        down = e["stroke"] == "down"
        mode = st["strum"]
        w = 1.3 * self.k
        bbs = []
        if mode == "arrow":
            cv.vline(x, yt - 0.2 * u, yb + 0.2 * u, w)
            bbs.append([x - 1, yt - 0.2 * u, x + 1, yb + 0.2 * u])
            self.arrowhead(cv, x, yb + 0.2 * u if down else yt - 0.2 * u, down, bbs)
        elif mode == "xline":
            cv.vline(x, yt, yb, 1.0 * self.k)
            for n in e["notes"]:
                self.cross(cv, x, ly[n["string"] - 1], n["string"], event=ei, beat=e["beat"], strum=True)
            bbs.append([x - 0.4 * u, yt - 0.4 * u, x + 0.4 * u, yb + 0.4 * u])
            self.arrowhead(cv, x, yb + 0.45 * u if down else yt - 0.45 * u, down, bbs, size=0.4)
        else:  # slash
            ym = (yt + yb) / 2
            h = max((yb - yt) / 2, 0.8 * u)
            cv.rect([x - 0.45 * u, ym - h - 1, x + 0.45 * u, ym + h + 1], fill=(255, 255, 255))
            cv.line(x - 0.3 * u, ym + h, x + 0.3 * u, ym - h, 2.2 * self.k)
            bbs.append([x - 0.3 * u, ym - h, x + 0.3 * u, ym + h])
            self.arrowhead(cv, x + 0.3 * u if not down else x - 0.3 * u, ym - h - 0.3 * u if not down else ym + h + 0.3 * u, down, bbs, size=0.4)
        bb = [min(b[0] for b in bbs), min(b[1] for b in bbs), max(b[2] for b in bbs), max(b[3] for b in bbs)]
        cv.add("strum", bb, direction=e["stroke"], strings=strs, style=mode, event=ei, beat=e["beat"])

    def arrowhead(self, cv, x, y, down, bbs, size=0.5):
        u = self.u
        s = size * u
        if down:
            pts = [(x, y + 0.3 * u), (x - s * 0.55, y - s * 0.6), (x + s * 0.55, y - s * 0.6)]
        else:
            pts = [(x, y - 0.3 * u), (x - s * 0.55, y + s * 0.6), (x + s * 0.55, y + s * 0.6)]
        cv.poly(pts)
        bbs.append([x - s * 0.55, min(p[1] for p in pts), x + s * 0.55, max(p[1] for p in pts)])

    def draw_stems(self, cv, events, items, pos, ly):
        st, u = self.st, self.u
        y0 = ly[5] + 0.3 * u
        y1 = y0 + st["stem_len"] * u
        sw = st["stem_w"] * self.k
        for ei, e in enumerate(events):
            if not e["notes"]:
                continue
            q = e["duration"] / self.unit_scale
            if q >= 4 - 1e-9:
                pass
            bb = cv.vline(pos[ei], y0, y1, sw, label="stem", event=ei, beat=e["beat"], q=round(q, 3))
            if abs(q - 0.75) < 1e-6 or abs(q - 1.5) < 1e-6 or abs(q - 3) < 1e-6:
                cv.circle(pos[ei] + 0.55 * u, y1 - 0.3 * u, 0.15 * u, fill=self.ink)
                cv.add("stem_dot", [pos[ei] + 0.4 * u, y1 - 0.45 * u, pos[ei] + 0.7 * u, y1 - 0.15 * u], event=ei)
        runs = beam_runs(items, self.group_q, self.unit_scale)
        bw = st["beam_w"] * self.k
        gap = st["beam_gap"] * u
        for run in runs:
            if len(run) >= 2:
                xa, xb = pos[run[0]], pos[run[-1]]
                cv.hline(xa - sw / 2, xb + sw / 2, y1 - bw / 2 + 0.3, bw, label="beam", level=1, events=[run[0], run[-1]])
            else:
                i = run[0]
                cv.line(pos[i], y1 - 0.6 * u, pos[i] + 0.7 * u, y1 + 0.1, max(bw * 0.6, 1.2))
                cv.add("beam", [pos[i], y1 - 0.6 * u, pos[i] + 0.7 * u, y1 + 0.2], level=1, kind="flag", events=[i, i])
            # second beam for runs of 16ths
            qs = [items[i][1] for i in run]
            j = 0
            while j < len(run):
                if qs[j] <= 0.25 + 1e-9:
                    k2 = j
                    while k2 + 1 < len(run) and qs[k2 + 1] <= 0.25 + 1e-9:
                        k2 += 1
                    if k2 > j:
                        cv.hline(pos[run[j]] - sw / 2, pos[run[k2]] + sw / 2, y1 - gap - bw / 2 + 0.3, bw, label="beam", level=2,
                                 events=[run[j], run[k2]])
                    else:
                        i = run[j]
                        d = -0.7 * u if j > 0 else 0.7 * u
                        xa, xb = sorted([pos[i], pos[i] + d])
                        cv.hline(xa, xb, y1 - gap - bw / 2 + 0.3, bw, label="beam", level=2, kind="stub", events=[i, i])
                    j = k2 + 1
                else:
                    j += 1

    # ---------------------------------------------------------------- jianpu
    def draw_jianpu(self, cv, m, g, yc, mi):
        st, u = self.st, self.u
        jp = st["jp"]
        fs_j = getattr(self, "jp_fs_sys", jp["fs"])
        font = self.F("f_jp", fs_j)
        bb0 = cv.d.textbbox((0, 0), "0", font=font, anchor="ms")
        dh = (bb0[3] - bb0[1]) / SS
        dw = (bb0[2] - bb0[0]) / SS
        base = yc + dh / 2
        L = g["L"]
        mel = m["melody"]
        notes = []
        items = []
        for ni, n in enumerate(mel):
            x = g["ix0"] + n["beat"] / L * g["iw"]
            q = n["duration"] / self.unit_scale
            items.append((n["beat"], q, True))
            notes.append(dict(x=x, q=q, idx=ni, lyr=n["lyrics"], n=n, dw=dw))
        # parens
        if "jianpu-paren-open" in m["marks"] and notes:
            pf = get_font("sans_sc", fs_j * u * SS * jp["paren_scale"], 300)
            cv.text(notes[0]["x"] - dw / 2 - 0.9 * u, yc, "(", pf, anchor="mm", label="jianpu_paren", kind="open")
        if "jianpu-paren-close" in m["marks"] and notes:
            pf = get_font("sans_sc", fs_j * u * SS * jp["paren_scale"], 300)
            cv.text(notes[-1]["x"] + dw / 2 + 0.9 * u, yc, ")", pf, anchor="mm", label="jianpu_paren", kind="close")
        ulw = jp["ul_w"] * self.k
        gap = jp["ul_gap"] * u
        run_of = {}
        runs = beam_runs(items, self.group_q, self.unit_scale)
        for r in runs:
            for i in r:
                run_of[i] = r
        for nt in notes:
            n, x, q = nt["n"], nt["x"], nt["q"]
            ni = nt["idx"]
            deg = n["degree"]
            bb = cv.text(x, base, str(deg), font, anchor="ms", label="jianpu_digit", degree=deg, octave=n["octave"],
                         accidental=n["accidental"], note=ni, beat=n["beat"], q=round(q, 3), value=deg)
            nt["bb"] = bb
            nul = 0 if q > 0.5 + 1e-9 else (1 if q > 0.25 + 1e-9 else 2)
            nt["nul"] = nul
            if n["accidental"]:
                af = get_font("arimo", fs_j * u * SS * 0.62, 600)
                cv.text(bb[0] - 0.12 * u, yc - dh * 0.15, "#" if n["accidental"] > 0 else "b", af, anchor="rm",
                        label="jianpu_accidental", value=n["accidental"], note=ni)
            # octave dots
            r = max(1.1, jp["dot_r"] * u)
            if n["octave"] > 0 and deg:
                for j in range(min(n["octave"], 2)):
                    dy = yc - dh / 2 - 0.5 * u - j * 0.55 * u
                    cv.circle(x, dy, r, fill=self.ink)
                    cv.add("jianpu_dot", [x - r, dy - r, x + r, dy + r], pos="above", note=ni)
            if n["octave"] < 0 and deg:
                for j in range(min(-n["octave"], 2)):
                    dy = base + 0.5 * u + nul * gap + 0.35 * u + j * 0.55 * u
                    cv.circle(x, dy, r, fill=self.ink)
                    cv.add("jianpu_dot", [x - r, dy - r, x + r, dy + r], pos="below", note=ni)
            # augmentation dot / dashes
            if abs(q - 0.75) < 1e-6 or abs(q - 1.5) < 1e-6:
                ax = x + dw / 2 + 0.55 * u
                cv.circle(ax, base - 0.3 * u, r, fill=self.ink)
                cv.add("jianpu_aug_dot", [ax - r, base - 0.3 * u - r, ax + r, base - 0.3 * u + r], note=ni)
            if q >= 2 - 1e-9:
                for j in range(1, int(q + 1e-9)):
                    dx = g["ix0"] + (n["beat"] + j * self.unit_scale) / L * g["iw"]
                    hl = jp["dash_len"] * u / 2
                    cv.hline(dx - hl, dx + hl, round(yc), ulw * 1.1, label="jianpu_dash", note=ni, index=j)
        # underlines
        for r in runs:
            if len(r) >= 2 and jp["connected"]:
                xa = notes[r[0]]["x"] - dw / 2
                xb = notes[r[-1]]["x"] + dw / 2
                cv.hline(xa, xb, round(base + 0.38 * u), ulw, label="jianpu_underline", level=1, notes=[r[0], r[-1]])
            else:
                for i in r:
                    cv.hline(notes[i]["x"] - dw / 2, notes[i]["x"] + dw / 2, round(base + 0.38 * u), ulw, label="jianpu_underline",
                             level=1, notes=[i, i])
            j = 0
            while j < len(r):
                if notes[r[j]]["nul"] == 2:
                    k2 = j
                    while k2 + 1 < len(r) and notes[r[k2 + 1]]["nul"] == 2:
                        k2 += 1
                    if k2 > j and jp["connected"]:
                        cv.hline(notes[r[j]]["x"] - dw / 2, notes[r[k2]]["x"] + dw / 2, round(base + 0.38 * u + gap), ulw,
                                 label="jianpu_underline", level=2, notes=[r[j], r[k2]])
                    else:
                        for t in range(j, k2 + 1):
                            cv.hline(notes[r[t]]["x"] - dw / 2, notes[r[t]]["x"] + dw / 2, round(base + 0.38 * u + gap), ulw,
                                     label="jianpu_underline", level=2, notes=[r[t], r[t]])
                    j = k2 + 1
                else:
                    j += 1
        for nt in notes:
            nt["dh"] = dh
            nt["top"] = yc - dh / 2
        return notes

    def draw_ties(self, cv, ms, all_notes, yc):
        st, u = self.st, self.u
        for mi, notes in enumerate(all_notes):
            for ni, nt in enumerate(notes):
                if not nt["n"]["tieToNext"]:
                    continue
                if ni + 1 < len(notes):
                    nxt = notes[ni + 1]
                elif mi + 1 < len(all_notes) and all_notes[mi + 1]:
                    nxt = all_notes[mi + 1][0]
                else:
                    continue
                cv.ctx["m"] = mi
                ylev = nt["top"] - 0.45 * u
                hi = max(ms[mi]["melody"][ni]["octave"], ms[mi]["melody"][ni]["octave"] if False else 0)
                if nt["n"]["octave"] > 0 or (nxt["n"]["octave"] > 0):
                    ylev -= 0.65 * u
                xa, xb = nt["x"] + 0.1 * u, nxt["x"] - 0.1 * u
                if xb - xa < 0.6 * u:
                    continue
                h = min(0.7 * u, max(0.3 * u, (xb - xa) * 0.18))
                bb = cv.arc_up(xa, xb, ylev, h, 1.2 * self.k)
                cv.add("jianpu_tie", bb, note=nt["idx"], kind="tie" if (nt["n"]["degree"] == nxt["n"]["degree"] and nt["n"]["octave"] == nxt["n"]["octave"]) else "slur")
