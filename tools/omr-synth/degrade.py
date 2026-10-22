"""Degradations for rendered pages: background tint/texture, watermarks, QR codes, URLs, rotation, phone-screenshot
margins, blur, down/up-scaling, noise, JPEG.  Every degradation is recorded, and all geometric changes are tracked as
one affine transform so element boxes stay exact (axis-aligned bounding boxes of the transformed rectangles)."""
import io
import math
import random

import numpy as np
import qrcode
from PIL import Image, ImageDraw, ImageFilter

import render as R

SITE_NAMES = ["吉他谱大全", "弹唱谱网", "六线谱之家", "琴谱天地", "指弹社区", "阿谱吉他", "木吉他谱库", "Guitar Hub", "TabNest",
              "六弦谱站", "民谣吉他网", "弹唱圈", "吉他控", "Chord Garden"]
DOMAINS = ["www.jitapu123.com", "www.tabnest.cn", "jita.example.com", "www.liuxianpu.net", "www.guitar-hub.cc", "pu.tanchang.cn",
           "www.qinpu8.com", "m.jitakong.com"]
SLOGANS = ["更多吉他谱请访问", "免费下载六线谱", "扫码关注公众号获取更多谱子", "版权所有 请勿转载", "原创制谱 盗版必究", "关注我们 学更多弹唱"]
WM_COLORS = [(128, 128, 128), (90, 90, 90), (200, 40, 40), (40, 90, 200), (30, 140, 90), (230, 120, 20), (150, 60, 160), (0, 0, 0)]


def _font_for(rng, text, size_px, cjk=None):
    has_cjk = any(ord(c) > 0x2E80 for c in text)
    if has_cjk or cjk:
        key = rng.choice(["sans_sc", "sans_sc", "serif_sc", "wenkai", "zcool"])
        return R.get_font(key, size_px, rng.choice([400, 500, 700]))
    return R.get_font(rng.choice(["arimo", "roboto", "dejavu_b", "notosans"]), size_px, rng.choice([400, 700]))


def _text_mask(text, font, pad=4):
    tmp = Image.new("L", (10, 10), 0)
    bb = ImageDraw.Draw(tmp).textbbox((0, 0), text, font=font, anchor="ls")
    w, h = bb[2] - bb[0] + 2 * pad, bb[3] - bb[1] + 2 * pad
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).text((pad - bb[0], pad - bb[1]), text, font=font, fill=255, anchor="ls")
    return m


def _paste(img, mask, pos, color, opacity):
    if opacity < 1:
        mask = mask.point(lambda v: int(v * opacity))
    img.paste(Image.new("RGB", mask.size, tuple(color)), (int(pos[0]), int(pos[1])), mask)


def _mask_bbox(mask, pos):
    bb = mask.point(lambda v: 255 if v > 8 else 0).getbbox()
    if not bb:
        return None
    return [pos[0] + bb[0], pos[1] + bb[1], pos[0] + bb[2], pos[1] + bb[3]]


class Degrader:
    def __init__(self, rng, W, H, u, elements, bg_style=(255, 255, 255)):
        self.rng, self.W, self.H, self.u = rng, W, H, u
        self.els = elements
        self.new_els = []
        self.rec = {}
        self.bg_style = tuple(bg_style)

    def add_el(self, label, bbox, **kw):
        self.new_els.append(dict(label=label, bbox=[round(float(v), 2) for v in bbox], nonScore=True, **kw))

    def blocked(self, bb, margin=6):
        for e in self.els:
            if e.get("nonScore") or e["label"] in ("system", "measure", "staff_line", "header_title", "header_artist"):
                continue
            b = e["bbox"]
            if b[0] < bb[2] + margin and b[2] > bb[0] - margin and b[1] < bb[3] + margin and b[3] > bb[1] - margin:
                return True
        return False

    # ---- background
    def background(self, img):
        rng = self.rng
        r = rng.random()
        base = self.bg_style
        tint = None
        tex = False
        if base != (255, 255, 255):
            tint = base
        elif r < 0.25:
            c = rng.choice([(250, 247, 238), (245, 245, 245), (252, 250, 240), (242, 246, 250), (248, 244, 232)])
            tint = c
        if rng.random() < 0.2:
            tex = True
        if tint is None and not tex:
            self.rec["background"] = {"tint": None, "texture": False}
            return img
        arr = np.asarray(img).astype(np.float32)
        bg = np.ones_like(arr) * (np.array(tint if tint else (255, 255, 255), dtype=np.float32))
        if tex:
            nrng = np.random.default_rng(rng.getrandbits(32))
            small = nrng.normal(0, 1, (self.H // 24 + 2, self.W // 24 + 2)).astype(np.float32)
            big = np.asarray(Image.fromarray(small).resize((self.W, self.H), Image.BICUBIC))
            fine = nrng.normal(0, 1, (self.H, self.W)).astype(np.float32)
            amp = rng.uniform(2.5, 7.0)
            bg = bg + (big * amp * 0.7 + fine * amp * 0.5)[..., None]
        out = arr * np.clip(bg, 0, 255) / 255.0
        self.rec["background"] = {"tint": list(tint) if tint else None, "texture": tex}
        return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))

    # ---- watermarks
    def watermarks(self, img, force=None):
        rng = self.rng
        W, H, u = self.W, self.H, self.u
        wms = []
        kinds = []
        if rng.random() < 0.40:
            kinds.append("diag_text")
        if rng.random() < 0.30:
            kinds.append("corner_logo")
        if rng.random() < 0.25:
            kinds.append("qr")
        if rng.random() < 0.40:
            kinds.append("footer_url")
        if rng.random() < 0.20:
            kinds.append("header_url")
        if rng.random() < 0.15:
            kinds.append("gray_bg_text")
        if rng.random() < 0.15:
            kinds.append("side_text")
        if force is not None:
            kinds = list(force)
        for kd in kinds:
            getattr(self, "wm_" + kd)(img, wms)
        self.rec["watermarks"] = wms

    def _rot_text(self, img, text, size, color, opacity, angle, cx, cy, label, wms, kind, **extra):
        rng = self.rng
        font = _font_for(rng, text, size)
        m = _text_mask(text, font)
        if angle:
            m = m.rotate(angle, expand=True, resample=Image.BICUBIC)
        pos = (cx - m.width / 2, cy - m.height / 2)
        _paste(img, m, pos, color, opacity)
        bb = _mask_bbox(m, pos)
        if bb:
            self.add_el(label, bb, text=text, opacity=round(opacity, 3), color=list(color), rotation=round(angle, 1), kind=kind, **extra)
            wms.append(dict(type=kind, text=text, opacity=round(opacity, 3), color=list(color), rotation=round(angle, 1), bbox=[round(v, 1) for v in bb]))
        return bb

    def wm_diag_text(self, img, wms):
        rng = self.rng
        text = rng.choice(SITE_NAMES + DOMAINS)
        color = rng.choice(WM_COLORS)
        op = rng.uniform(0.05, 0.35)
        ang = rng.choice([1, -1]) * rng.uniform(20, 50)
        n = rng.choice([1, 1, 2, 3])
        size = rng.uniform(4.5, 8.0) * self.u
        for i in range(n):
            cx = self.W * (0.5 if n == 1 else (i + 0.5) / n) + rng.uniform(-60, 60)
            cy = self.H * (0.5 if n == 1 else rng.uniform(0.2, 0.8)) + rng.uniform(-80, 80)
            self._rot_text(img, text, size, color, op, ang, cx, cy, "wm_text", wms, "diag_text")

    def wm_gray_bg_text(self, img, wms):
        rng = self.rng
        text = rng.choice(SITE_NAMES)
        op = rng.uniform(0.05, 0.12)
        size = rng.uniform(3.0, 4.5) * self.u
        ang = rng.uniform(-35, -20)
        step_x, step_y = rng.uniform(260, 380), rng.uniform(220, 320)
        col = (rng.choice([100, 128, 160]),) * 3
        y = 40
        row = 0
        while y < self.H:
            x = 40 + (row % 2) * step_x / 2
            while x < self.W:
                self._rot_text(img, text, size, col, op, ang, x, y, "wm_gray_text", wms, "gray_bg_text")
                x += step_x
            y += step_y
            row += 1

    def wm_corner_logo(self, img, wms):
        rng = self.rng
        W, H, u = self.W, self.H, self.u
        size = rng.uniform(4.0, 6.0) * u
        color = rng.choice(WM_COLORS[2:6])
        op = rng.uniform(0.12, 0.35)
        name = rng.choice(SITE_NAMES)
        shape = rng.choice(["round", "rect", "circle"])
        ww, hh = int(size * 2.4), int(size)
        m = Image.new("L", (ww, hh), 0)
        d = ImageDraw.Draw(m)
        if shape == "circle":
            d.ellipse([0, 0, hh - 1, hh - 1], fill=255)
            d.text((hh / 2, hh / 2), name[0], font=_font_for(rng, name[0], hh * 0.6, True), fill=0, anchor="mm")
            d.text((hh + 6, hh / 2), name, font=_font_for(rng, name, hh * 0.42), fill=255, anchor="lm")
        else:
            d.rounded_rectangle([0, 0, ww - 1, hh - 1], radius=hh // 4 if shape == "round" else 0, outline=255, width=3)
            d.text((ww / 2, hh / 2), name, font=_font_for(rng, name, hh * 0.45), fill=255, anchor="mm")
        corner = rng.choice(["tl", "tr", "bl", "br"])
        x = 12 if corner[1] == "l" else W - ww - 12
        y = 10 if corner[0] == "t" else H - hh - 10
        _paste(img, m, (x, y), color, op)
        bb = _mask_bbox(m, (x, y))
        self.add_el("wm_logo", bb, text=name, opacity=round(op, 3), color=list(color), rotation=0, kind="corner_logo")
        wms.append(dict(type="corner_logo", text=name, opacity=round(op, 3), color=list(color), rotation=0, bbox=[round(v, 1) for v in bb]))

    def wm_qr(self, img, wms):
        rng = self.rng
        W, H = self.W, self.H
        size = int(rng.uniform(85, 150) * W / 1080)
        url = "https://%s/p/%d" % (rng.choice(DOMAINS), rng.randint(1000, 99999))
        qr = qrcode.QRCode(border=0, box_size=1, error_correction=qrcode.constants.ERROR_CORRECT_M)
        qr.add_data(url)
        mat = np.array(qr.get_matrix(), dtype=np.uint8)
        n = mat.shape[0]
        cell = max(2, size // n)
        arr = np.kron(1 - mat, np.ones((cell, cell), dtype=np.uint8)) * 255
        q = Image.fromarray(arr, "L")
        pad = cell * 2
        card = Image.new("L", (q.width + 2 * pad, q.height + 2 * pad), 255)
        card.paste(q, (pad, pad))
        cap = rng.choice(["扫码关注", "扫码领取谱子", "微信扫一扫", "关注公众号"])
        font = _font_for(rng, cap, max(14, cell * 3), True)
        capm = _text_mask(cap, font, pad=2)
        cands = [(W - card.width - 14, H - card.height - 70), (14, H - card.height - 70), (W - card.width - 14, 14),
                 (14, 14), (W - card.width - 14, H - card.height - capm.height - 6)]
        rng.shuffle(cands)
        for (x, y) in cands:
            bb = [x, y, x + card.width, y + card.height + capm.height + 4]
            if x < 0 or y < 0 or bb[3] > H or self.blocked(bb, 10):
                continue
            op = rng.uniform(0.7, 1.0)
            img.paste(card.convert("RGB"), (int(x), int(y)))
            cc = rng.choice([(0, 0, 0), (60, 60, 60), (200, 40, 40)])
            _paste(img, capm, (x + (card.width - capm.width) / 2, y + card.height + 2), cc, 1.0)
            self.add_el("wm_qr", [x, y, x + card.width, y + card.height], kind="qr", url=url, opacity=1.0)
            self.add_el("wm_text", [x + (card.width - capm.width) / 2, y + card.height + 2, x + (card.width + capm.width) / 2, y + card.height + 2 + capm.height],
                        text=cap, kind="qr_caption", opacity=1.0, color=list(cc), rotation=0)
            wms.append(dict(type="qr", text=url, caption=cap, opacity=1.0, bbox=[round(v, 1) for v in bb]))
            return

    def _line_text(self, img, wms, text, y, kind, label, align="c", size_u=1.5):
        rng = self.rng
        W = self.W
        font = _font_for(rng, text, size_u * self.u * rng.uniform(0.9, 1.15))
        m = _text_mask(text, font)
        col = rng.choice([(110, 110, 110), (150, 150, 150), (60, 60, 60), (40, 90, 200)])
        op = rng.uniform(0.5, 1.0)
        x = {"c": (W - m.width) / 2, "l": 18, "r": W - m.width - 18}[align]
        bb = [x, y, x + m.width, y + m.height]
        if self.blocked(bb, 4):
            return
        _paste(img, m, (x, y), col, op)
        b2 = _mask_bbox(m, (x, y))
        self.add_el(label, b2, text=text, opacity=round(op, 3), color=list(col), rotation=0, kind=kind)
        wms.append(dict(type=kind, text=text, opacity=round(op, 3), color=list(col), rotation=0, bbox=[round(v, 1) for v in b2]))

    def wm_footer_url(self, img, wms):
        rng = self.rng
        txt = rng.choice(["%s  %s", "%s | %s", "%s %s"]) % (rng.choice(SLOGANS), rng.choice(DOMAINS))
        if rng.random() < 0.4:
            txt = rng.choice(DOMAINS)
        self._line_text(img, wms, txt, self.H - rng.uniform(20, 38) * self.W / 1080 - self.u, "footer_url", "wm_url", align=rng.choice(["c", "c", "l", "r"]))

    def wm_header_url(self, img, wms):
        rng = self.rng
        self._line_text(img, wms, rng.choice(DOMAINS), rng.uniform(8, 20), "header_url", "wm_url", align=rng.choice(["l", "r", "c"]), size_u=1.2)

    def wm_side_text(self, img, wms):
        rng = self.rng
        text = rng.choice(SITE_NAMES) + " " + rng.choice(DOMAINS)
        font = _font_for(rng, text, 1.3 * self.u)
        m = _text_mask(text, font).rotate(90, expand=True)
        x = rng.choice([4, self.W - m.width - 4])
        y = rng.uniform(self.H * 0.2, self.H * 0.6)
        bb = [x, y, x + m.width, y + m.height]
        if self.blocked(bb, 3):
            return
        col = rng.choice([(120, 120, 120), (180, 180, 180)])
        op = rng.uniform(0.3, 0.8)
        _paste(img, m, (x, y), col, op)
        b2 = _mask_bbox(m, (x, y))
        self.add_el("wm_text", b2, text=text, opacity=round(op, 3), color=list(col), rotation=90, kind="side_text")
        wms.append(dict(type="side_text", text=text, opacity=round(op, 3), color=list(col), rotation=90, bbox=[round(v, 1) for v in b2]))

    # ---- geometry
    def geometry(self, img):
        """rotation + phone-screenshot margins. Returns (img, M) with M mapping clean -> final: [a,b,c,d,e,f]."""
        rng = self.rng
        W, H = img.size
        M = np.eye(3)
        fill = tuple(int(v) for v in np.asarray(img.crop((0, 0, 20, 20))).reshape(-1, 3).mean(0))
        geo = {}
        if rng.random() < 0.20:
            ang = rng.choice([-1, 1]) * rng.uniform(0.2, 1.5)
            c = math.cos(math.radians(ang))
            s = math.sin(math.radians(ang))
            cx, cy = W / 2, H / 2
            img = img.rotate(ang, resample=Image.BICUBIC, center=(cx, cy), fillcolor=fill)
            # PIL: counter-clockwise by ang in y-down coords
            R_ = np.array([[c, s, cx - c * cx - s * cy], [-s, c, cy + s * cx - c * cy], [0, 0, 1]])
            M = R_ @ M
            geo["rotation_deg"] = round(ang, 3)
        r = rng.random()
        if r < 0.25:
            # phone screenshot: bars + side padding, or tight crop
            mode = rng.choice(["bars", "bars", "crop", "pad"])
            if mode == "bars":
                top = int(rng.uniform(50, 130) * W / 1080)
                bot = int(rng.uniform(0, 120) * W / 1080)
                side = int(rng.uniform(0, 30) * W / 1080)
                bar = rng.choice([(20, 20, 24), (245, 245, 245), (255, 255, 255), (40, 44, 52)])
                new = Image.new("RGB", (W + 2 * side, H + top + bot), bar)
                new.paste(img, (side, top))
                d = ImageDraw.Draw(new)
                fg = (230, 230, 230) if sum(bar) < 300 else (60, 60, 60)
                f = R.get_font("dejavu", 0.3 * top, 400)
                d.text((side + 24, top * 0.5), "%d:%02d" % (rng.randint(8, 23), rng.randint(0, 59)), font=f, fill=fg, anchor="lm")
                d.rounded_rectangle([new.width - side - 90, top * 0.35, new.width - side - 30, top * 0.65], radius=4, outline=fg, width=2)
                img = new
                M = np.array([[1, 0, side], [0, 1, top], [0, 0, 1]], float) @ M
                geo["screenshot"] = {"mode": "bars", "top": top, "bottom": bot, "side": side}
            elif mode == "pad":
                p = [int(rng.uniform(10, 80) * W / 1080) for _ in range(4)]
                bar = rng.choice([(235, 235, 235), (30, 30, 30), (255, 255, 255), (210, 220, 235)])
                new = Image.new("RGB", (W + p[0] + p[2], H + p[1] + p[3]), bar)
                new.paste(img, (p[0], p[1]))
                img = new
                M = np.array([[1, 0, p[0]], [0, 1, p[1]], [0, 0, 1]], float) @ M
                geo["screenshot"] = {"mode": "pad", "left": p[0], "top": p[1], "right": p[2], "bottom": p[3]}
            else:
                c = [int(rng.uniform(0, 28) * W / 1080) for _ in range(4)]
                img = img.crop((c[0], c[1], W - c[2], H - c[3]))
                M = np.array([[1, 0, -c[0]], [0, 1, -c[1]], [0, 0, 1]], float) @ M
                geo["screenshot"] = {"mode": "crop", "left": c[0], "top": c[1], "right": c[2], "bottom": c[3]}
        self.rec["geometry"] = geo
        return img, M

    # ---- photometric
    def photometric(self, img):
        rng = self.rng
        rec = {}
        if rng.random() < 0.15:
            c = rng.uniform(0.72, 0.94)
            a = np.asarray(img).astype(np.float32)
            img = Image.fromarray(np.clip(255 - (255 - a) * c, 0, 255).astype(np.uint8))
            rec["contrast"] = round(c, 3)
        if rng.random() < 0.30:
            f = rng.uniform(0.55, 0.88)
            w, h = img.size
            img = img.resize((max(8, int(w * f)), max(8, int(h * f))), Image.BILINEAR).resize((w, h), rng.choice([Image.BICUBIC, Image.BILINEAR]))
            rec["down_up_scale"] = round(f, 3)
        if rng.random() < 0.30:
            r = rng.uniform(0.3, 0.9)
            img = img.filter(ImageFilter.GaussianBlur(r))
            rec["blur_radius"] = round(r, 3)
        if rng.random() < 0.40:
            s = rng.uniform(1.5, 5.0)
            a = np.asarray(img).astype(np.float32)
            nrng = np.random.default_rng(rng.getrandbits(32))
            a = a + nrng.normal(0, s, a.shape[:2])[..., None]
            img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
            rec["noise_sigma"] = round(s, 2)
        self.rec["photometric"] = rec
        return img

    def jpeg(self, img):
        q = self.rng.randint(70, 95)
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=q, subsampling=self.rng.choice([0, 2]))
        data = buf.getvalue()
        self.rec["jpeg_quality"] = q
        return data, Image.open(io.BytesIO(data)).convert("RGB")


def transform_bbox(b, M):
    pts = [(b[0], b[1]), (b[2], b[1]), (b[2], b[3]), (b[0], b[3])]
    xs, ys = [], []
    for x, y in pts:
        v = M @ np.array([x, y, 1.0])
        xs.append(v[0])
        ys.append(v[1])
    return [round(min(xs), 2), round(min(ys), 2), round(max(xs), 2), round(max(ys), 2)]


def degrade_page(img, elements, systems, rng, u, bg_style=(255, 255, 255), level="normal", force_wm=None):
    """Returns dict(jpeg=bytes, image=PIL RGB (decoded JPEG), elements, systems, transform, record)."""
    W, H = img.size
    dg = Degrader(rng, W, H, u, elements, bg_style)
    if level == "none":
        data, dec = dg.jpeg(img)
        dg.rec = {"jpeg_quality": dg.rec["jpeg_quality"]}
        return dict(jpeg=data, image=dec, elements=elements, systems=systems, transform=[1, 0, 0, 0, 1, 0], record=dg.rec)
    img = dg.background(img)
    dg.watermarks(img, force_wm)
    img, M = dg.geometry(img)
    img = dg.photometric(img)
    data, dec = dg.jpeg(img)
    # new_els (watermarks) were created before geometry: also transform
    els = []
    for e in elements:
        e2 = dict(e)
        e2["bbox"] = transform_bbox(e["bbox"], M)
        els.append(e2)
    for e in dg.new_els:
        e2 = dict(e)
        e2["bbox"] = transform_bbox(e["bbox"], M)
        e2["id"] = len(els)
        els.append(e2)
    for wm in dg.rec.get("watermarks", []):
        wm["bbox"] = transform_bbox(wm["bbox"], M)
    sysl = []
    for s in systems:
        s2 = dict(s)
        s2["bbox"] = transform_bbox(s["bbox"], M)
        sysl.append(s2)
    tf = [round(float(v), 6) for v in (M[0, 0], M[0, 1], M[0, 2], M[1, 0], M[1, 1], M[1, 2])]
    return dict(jpeg=data, image=dec, elements=els, systems=sysl, transform=tf, record=dg.rec)
