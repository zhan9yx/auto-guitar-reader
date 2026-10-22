"""Style presets for the OMR synthetic renderer.

Every preset is a dict of layout / glyph parameters; `get_style(name)` merges it over DEFAULT.
Sizes marked (u) are multiples of the staff line spacing u (u itself is in px at 1080 px page width and is scaled by
page_width/1080).  Font entries are (font_key, weight) -- see FONT_FILES in render.py.
"""
import copy

DEFAULT = dict(
    name="default",
    width=(1080, 1080), aspect=(1.5, 1.58),
    u=12.6,
    margin_l=46, margin_r=38, margin_top=70, margin_bottom=70,
    per_system=[4, 4, 5],
    # fonts: (key, weight)
    f_title=("sans_sc", 500), f_artist=("sans_sc", 400), f_text=("sans_sc", 400), f_chord=("arimo", 500),
    f_digit=("arimo", 500), f_jp=("arimo", 700), f_lyric=("sans_sc", 400), f_label=("sans_sc", 500),
    f_clef=("arimo", 700), f_info=("sans_sc", 400),
    # line geometry (px at 1080)
    line_w=1.0, bar_w=1.2, thick_w=3.2, stem_w=1.1, beam_w=2.6, line_gray=0,
    cross=dict(mode="draw", r=0.36, w=1.3), halo=True, digit_scale=1.30,
    stem_len=1.7, beam_gap=0.34,
    strum="arrow",       # arrow | xline | slash
    diagram=dict(mode="all", rows=4, sx=0.6, sy=0.68, dot="filled", dot_r=0.30, lw=1.0, nut=2.2, barre=False,
                 name_scale=1.3, name_bold=False, color=None, dot_color=None),
    jp=dict(fs=2.05, dot_r=0.17, ul_w=1.3, ul_gap=0.30, connected=True, dash_len=0.95, gap=4.3, bars=True,
            paren_scale=1.1),
    lyr=dict(fs=1.9, row_h=2.25, punct=True),
    header=dict(layout="center", title_fs=3.0, artist_fs=1.9, key_fmt="1= {k}", info_fs=1.85, ts_header=True),
    section="box",       # box | plain | none
    sys_line=True,       # left connector from tab through jianpu row
    clef="stack",        # stack | rot
    page_no="{n}",       # format; {n} page, {N} total
    short_lines="full",  # full | natural
    ink=(0, 0, 0), chord_color=None, bg=(255, 255, 255), line_color=None,
    sections_named=True,
    tab_pref=None,       # None = random, "arp" or "strum" to bias the generator
    note="",
)

PRESETS = {
    "classic_ref": dict(
        note="Closest to the reference sample: crisp 1px black lines, grotesque digits, bracket-style stems.",
        width=(1080, 1100), per_system=[4, 4, 4, 5], sections_named=False, section="none",
    ),
    "serif_print": dict(
        note="Serif fonts, thin dark-gray lines, finger numbers in chord diagrams, left-aligned header.",
        width=(1100, 1180), u=12.0, per_system=[4],
        f_title=("serif_sc", 700), f_artist=("serif_sc", 400), f_text=("serif_sc", 500), f_chord=("tinos", 400),
        f_digit=("tinos", 400), f_jp=("tinos", 700), f_lyric=("serif_sc", 500), f_label=("serif_sc", 700),
        f_clef=("tinos", 700), f_info=("serif_sc", 400),
        line_w=0.8, bar_w=1.0, line_gray=50, stem_w=0.9, beam_w=2.2,
        cross=dict(mode="draw", r=0.32, w=1.0),
        diagram=dict(mode="first", rows=5, sx=0.62, sy=0.66, dot="finger", dot_r=0.34, lw=0.8, nut=2.0, barre=False,
                     name_scale=1.35, name_bold=True, color=None, dot_color=None),
        jp=dict(fs=2.0, dot_r=0.15, ul_w=1.0, ul_gap=0.3, connected=True, dash_len=0.85, gap=4.0, bars=True, paren_scale=1.1),
        lyr=dict(fs=1.85, row_h=2.2, punct=True),
        header=dict(layout="left", title_fs=3.2, artist_fs=1.8, key_fmt="1={k}", info_fs=1.8, ts_header=True),
        section="plain", sys_line=True, page_no="- {n} -", aspect=(1.4, 1.5),
    ),
    "wenkai_hand": dict(
        note="LXGW WenKai handwriting-ish text, heavier lines, square diagram dots, boxed title. Held out as the unseen style.",
        width=(1120, 1200), u=13.4, per_system=[4],
        f_title=("wenkai", 400), f_artist=("wenkai", 400), f_text=("wenkai", 400), f_chord=("roboto", 600),
        f_digit=("roboto", 600), f_jp=("roboto", 800), f_lyric=("wenkai", 400), f_label=("wenkai", 400),
        f_clef=("roboto", 800), f_info=("wenkai", 400),
        line_w=1.6, bar_w=1.8, thick_w=3.8, stem_w=1.6, beam_w=3.2,
        cross=dict(mode="draw", r=0.4, w=1.9), digit_scale=1.4,
        diagram=dict(mode="all", rows=4, sx=0.66, sy=0.72, dot="square", dot_r=0.30, lw=1.3, nut=2.8, barre=False,
                     name_scale=1.35, name_bold=True, color=None, dot_color=None),
        jp=dict(fs=2.2, dot_r=0.2, ul_w=1.7, ul_gap=0.32, connected=False, dash_len=1.0, gap=4.6, bars=True, paren_scale=1.1),
        lyr=dict(fs=2.0, row_h=2.35, punct=True),
        header=dict(layout="boxed", title_fs=3.2, artist_fs=1.9, key_fmt="1={k}", info_fs=1.9, ts_header=True),
        section="box", sys_line=False, page_no="第{n}页", aspect=(1.45, 1.55),
    ),
    "bold_app": dict(
        note="Phone-app look: heavy sans, thick lines, bold glyph x, barre bars in diagrams, diagram only when chord changes.",
        width=(1080, 1160), u=14.2, per_system=[4],
        f_title=("sans_sc", 800), f_artist=("sans_sc", 500), f_text=("sans_sc", 600), f_chord=("roboto", 700),
        f_digit=("roboto", 700), f_jp=("roboto", 700), f_lyric=("sans_sc", 500), f_label=("sans_sc", 700),
        f_clef=("roboto", 900), f_info=("sans_sc", 500),
        line_w=1.9, bar_w=2.0, thick_w=4.2, stem_w=1.9, beam_w=3.6, ink=(20, 20, 30),
        cross=dict(mode="glyph", r=0.4, w=2.0), digit_scale=1.45, stem_len=1.8,
        diagram=dict(mode="change", rows=5, sx=0.64, sy=0.7, dot="filled", dot_r=0.33, lw=1.3, nut=3.0, barre=True,
                     name_scale=1.4, name_bold=True, color=None, dot_color=None),
        jp=dict(fs=2.2, dot_r=0.2, ul_w=1.9, ul_gap=0.34, connected=True, dash_len=1.0, gap=4.4, bars=True, paren_scale=1.0),
        lyr=dict(fs=2.0, row_h=2.35, punct=True),
        header=dict(layout="center", title_fs=3.4, artist_fs=2.0, key_fmt="1={k}", info_fs=2.0, ts_header=True),
        section="box", strum="arrow", page_no="{n}/{N}", aspect=(1.5, 1.62),
    ),
    "compact_dense": dict(
        note="Dense 5-measure systems, small staff, gray hairlines, stacked-x strums, no left connector.",
        width=(1200, 1240), u=10.6, per_system=[5], margin_l=34, margin_r=30, margin_top=50,
        f_title=("sans_sc", 700), f_artist=("sans_sc", 400), f_text=("sans_sc", 400), f_chord=("notosans", 600),
        f_digit=("notosans", 500), f_jp=("notosans", 600), f_lyric=("sans_sc", 400),
        line_w=1.0, bar_w=1.0, line_gray=90, stem_w=1.0, beam_w=2.2, stem_len=1.6,
        cross=dict(mode="draw", r=0.34, w=1.1),
        diagram=dict(mode="all", rows=4, sx=0.62, sy=0.7, dot="filled", dot_r=0.3, lw=0.9, nut=1.8, barre=False,
                     name_scale=1.35, name_bold=False, color=None, dot_color=None),
        jp=dict(fs=2.0, dot_r=0.15, ul_w=1.1, ul_gap=0.28, connected=True, dash_len=0.8, gap=3.6, bars=True, paren_scale=1.1),
        lyr=dict(fs=1.8, row_h=2.1, punct=True),
        header=dict(layout="left", title_fs=2.8, artist_fs=1.7, key_fmt="Key: {k}", info_fs=1.7, ts_header=True),
        section="plain", sys_line=False, strum="xline", page_no="{n}", aspect=(1.4, 1.46), short_lines="natural",
    ),
    "mono_site": dict(
        note="Monospace digits and lowercase-x marks, rotated TAB clef, chord names without diagrams.",
        width=(1100, 1180), u=12.8, per_system=[4, 5],
        f_title=("sans_sc", 700), f_text=("sans_sc", 400), f_chord=("mono", 700), f_digit=("mono", 600), f_jp=("mono", 700),
        f_lyric=("sans_sc", 500), f_clef=("mono", 700),
        line_w=1.2, bar_w=1.4, stem_w=1.2, beam_w=2.8,
        cross=dict(mode="letter", r=0.4, w=1.2), digit_scale=1.25, clef="rot",
        diagram=dict(mode="none", rows=4, sx=0.6, sy=0.68, dot="filled", dot_r=0.3, lw=1.0, nut=2.2, barre=False,
                     name_scale=1.5, name_bold=True, color=None, dot_color=None),
        jp=dict(fs=2.0, dot_r=0.17, ul_w=1.3, ul_gap=0.3, connected=False, dash_len=0.9, gap=3.6, bars=True, paren_scale=1.0),
        header=dict(layout="center", title_fs=3.0, artist_fs=1.8, key_fmt="Key: {k}", info_fs=1.8, ts_header=True),
        section="plain", strum="xline", page_no="Page {n}", aspect=(1.45, 1.55),
    ),
    "zcool_color": dict(
        note="Warm paper background, red chord names with colored diagram dots, gray lines, slash strums, decorative header.",
        width=(1100, 1180), u=12.4, per_system=[4],
        f_title=("zcool", 400), f_artist=("zcool", 400), f_text=("zcool", 400), f_chord=("dejavu_b", 700),
        f_digit=("dejavu_b", 700), f_jp=("dejavu_b", 700), f_lyric=("zcool", 400), f_label=("zcool", 400),
        f_clef=("dejavu_b", 700), f_info=("zcool", 400),
        line_w=1.1, bar_w=1.3, line_gray=70, ink=(35, 30, 30), chord_color=(190, 45, 45), bg=(251, 246, 232),
        cross=dict(mode="draw", r=0.36, w=1.5), digit_scale=1.25,
        diagram=dict(mode="all", rows=4, sx=0.62, sy=0.68, dot="filled", dot_r=0.3, lw=1.0, nut=2.4, barre=False,
                     name_scale=1.4, name_bold=True, color=(190, 45, 45), dot_color=(190, 45, 45)),
        jp=dict(fs=2.05, dot_r=0.17, ul_w=1.3, ul_gap=0.3, connected=True, dash_len=0.95, gap=4.3, bars=True, paren_scale=1.1),
        header=dict(layout="boxed", title_fs=3.3, artist_fs=1.9, key_fmt="原调：{k}", info_fs=1.9, ts_header=True),
        section="box", strum="slash", page_no="{n}", aspect=(1.45, 1.6),
    ),
    "slash_rhythm": dict(
        note="Arimo/DejaVu, large stacked TAB clef, strum arrows drawn as rhythm slashes, 1/N page numbers.",
        width=(1140, 1240), u=12.0, per_system=[4, 5],
        f_digit=("dejavu", 400), f_chord=("dejavu_b", 700), f_jp=("dejavu_b", 700), f_clef=("dejavu_b", 700),
        line_w=1.2, bar_w=1.4, stem_w=1.2, beam_w=3.0, thick_w=3.6,
        cross=dict(mode="draw", r=0.4, w=1.6), digit_scale=1.2,
        diagram=dict(mode="all", rows=5, sx=0.6, sy=0.62, dot="filled", dot_r=0.28, lw=1.0, nut=2.0, barre=True,
                     name_scale=1.3, name_bold=True, color=None, dot_color=None),
        jp=dict(fs=2.0, dot_r=0.17, ul_w=1.4, ul_gap=0.3, connected=True, dash_len=0.95, gap=4.0, bars=True, paren_scale=1.0),
        header=dict(layout="center", title_fs=2.9, artist_fs=1.8, key_fmt="1={k}", info_fs=1.8, ts_header=True),
        section="box", strum="slash", page_no="{n}/{N}", aspect=(1.5, 1.6), tab_pref="strum",
    ),
}

STYLE_NAMES = list(PRESETS)
DEFAULT_UNSEEN = "wenkai_hand"


def get_style(name):
    s = copy.deepcopy(DEFAULT)
    p = copy.deepcopy(PRESETS[name])
    for k, v in p.items():
        if isinstance(v, dict) and isinstance(s.get(k), dict):
            s[k].update(v)
        else:
            s[k] = v
    s["name"] = name
    return s
