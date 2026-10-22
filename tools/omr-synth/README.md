# omr-synth: synthetic 弹唱六线谱 dataset for the OMR engine

Generates random but musically plausible AGR v2 scores, renders them as page images in 8 "site style" presets,
degrades them like real downloads/screenshots, and writes pixel-exact ground truth. Pure Python (Pillow, numpy, qrcode).

```
tools/omr-synth/
  gen_score.py     random AGR v2 score (dict / JSON)           python gen_score.py --seed 3 --out x.agr.json
  styles.py        the 8 style presets (+ DEFAULT)
  render.py        score -> page canvases + element geometry   (library; layout engine)
  degrade.py       watermarks, QR, tint, rotation, screenshot margins, blur, JPEG ...
  pipeline.py      produce(seed, style, out_dir): score + render + degrade + write files
  make_dataset.py  splits train/val/test/test_unseen_style + manifest.json
  verify.py        consistency checks score <-> boxes (+ `agr-tool import` decode of every score)
  viz_boxes.py     debug overlay of the boxes on a page PNG
  make_examples.py regenerates examples/*.png
  fonts.txt, fetch_fonts.sh   open-licensed fonts (URLs + licenses); fonts/ itself is gitignored
```

## Setup
```
cd tools/omr-synth
python3 -m venv .venv && export PIP_CACHE_DIR=$PWD/.pip-cache TMPDIR=$PWD/tmp && mkdir -p tmp
.venv/bin/pip install -r requirements.txt
./fetch_fonts.sh                      # downloads fonts listed in fonts.txt into ./fonts (no system fonts are used)
```

## Usage
```
# dataset (train = --count pages; val/test/test_unseen_style = count/4 pages each)
.venv/bin/python make_dataset.py --out ../../../../datasets/synth/v1 --count 400 --seed 1 --styles all
# one score in one style, optionally clean (--level none) -- from Python:
python -c "import pipeline; pipeline.produce(5, 'classic_ref', 'out/x', level='none')"
# check
.venv/bin/python verify.py <dataset> --agr-tool Core/.build/debug/agr-tool
```
Dataset layout: `<split>/sNNNNN/{score.agr.json, meta.json, page-K.png, page-K.jpg, page-K.pgm, page-K.boxes.json}`.
`page-K.jpg` is the encoded JPEG (quality 70-95); `.png` and `.pgm` (binary P5, 8-bit gray, what the Swift OMR reads
on Linux) are decoded from that JPEG, so all three are the same pixels. `Score.pages[i].fileName` is `page-K.jpg`.
`test_unseen_style/` only contains the held-out preset (default `wenkai_hand`), which never appears in the other splits.
Seeds are disjoint per split (`seed*1e6 + {0, 2e5, 4e5, 6e5} + index`). `manifest.json` lists every score (style, seed,
pages, measures, time signature, verses), per-split counts and total bytes.

## Style presets
| preset | what it mimics |
|---|---|
| `classic_ref` | the reference sample: crisp 1 px black lines, grotesque digits, bracket-style stems below the tab, no section labels (one anonymous section per system) |
| `serif_print` | serif fonts (Noto Serif SC/Tinos), thin dark-gray lines, finger numbers in 5-row diagrams (diagram only at first occurrence of a chord), left header, "- 1 -" page numbers |
| `wenkai_hand` | LXGW WenKai text, heavy lines, square diagram dots, boxed header, boxed section labels, "第1页". **Held out as the unseen style** |
| `bold_app` | phone-app look: heavy sans, thick lines, glyph "×", barre bars, diagram only when the chord changes, boxed labels, "1/2" |
| `compact_dense` | 1200-1240 px wide, 5 measures per system, small staff, gray hairlines, stacked-x strums, short last lines |
| `mono_site` | monospace digits and lowercase "x", rotated "TAB" clef, chord names without diagrams, "Page 1" |
| `zcool_color` | ZCOOL XiaoWei text on warm paper background, red chord names/diagram dots, gray lines, slash strums, ruled header |
| `slash_rhythm` | DejaVu glyphs, 5-row diagrams with barre bars, strums drawn as rhythm slashes + arrowheads, "1/N" |
Per-document jitter: page width (1080-1240), aspect (1.4-1.62), staff spacing +-5 %, measures per system (3-5).

## Score generator conventions (AGR v2, see `Core/.../Score.swift`)
* Keys: shapes in C/G/D/A/F with optional capo (0-5); `meta.key` = the "1=" tonic as printed (sounding key), chord names are play shapes.
  Time signatures 4/4 (70 %), 3/4, 6/8 (**beat unit = denominator**: 6/8 has 6 beats of an eighth). 9-24 measures, sections intro/verse/chorus/interlude/outro,
  pickup measures (`beats` set), repeats (`startRepeat`/`endRepeat`), voltas, double/final barlines.
* Chord names are kept verbatim (`D7(5)`, `G7(3)`, `Am7(5)`, `D(7)`, `C/G`, `Gsus4` ...). `ChordMark.shape` is set **only when a diagram is printed**
  (finger numbers are a heuristic). Names are printed for every chord in every preset, so names always match the page.
* Tab: `chordTone` = "x" (string of the current chord); explicit digits have `fret`; `hammerOn`/`pullOff` sit on the second note of a pair; strum events have `stroke`
  and chord-tone notes on the strummed strings; **a TabEvent with empty `notes` is a rest** (printed "-").
* Melody fills each measure exactly (durations 4,3,2,1.5,1,.75,.5,.25 quarter notes; rests = degree 0; octave dots, accidentals, ties/slurs
  via `tieToNext`, never across a system). Lyrics: 1-3 verses (`lyrics[v]`, `""` = none, length = verse rows printed under that system, `[]` if none);
  a syllable may carry a trailing `，`/`。`.
* `NotationMeasure.marks`: section label text (first measure of a section, only if the preset prints labels; otherwise sections are
  anonymous, `kind: other`, one per system), `jianpu-paren-open` / `jianpu-paren-close` for "( 0 0 0 0 )" style parentheses.
* `Line.anchor = {page, y, height}` is normalized to the **final degraded page image** (bbox of the transformed system region, chord row to last lyric row).

## Ground truth: `page-K.boxes.json`
```
{ page, width, height, style, seed, clean_size:[w,h],
  transform_clean_to_final:[a,b,c,d,e,f],   # x' = a x + b y + c ; y' = d x + e y + f (rotation / screenshot margins)
  degradations:{background, watermarks[], geometry{rotation_deg, screenshot{mode,...}}, photometric{contrast, down_up_scale, blur_radius, noise_sigma}, jpeg_quality},
  systems:[{sys, sec, line, bbox}],
  elements:[{id, label, bbox:[x0,y0,x1,y1] (final px), nonScore, sys, sec, line, m (measure index in system), ...extra}] }
```
`sec`/`line`/`m` index into `score.agr.json` (`sections[sec].lines[line].system.measures[m]`). Boxes are axis-aligned boxes of the (possibly rotated) element.
Labels and extras:
* structure: `system`, `measure`, `staff_line` (string 1..6, top to bottom), `barline` / `jianpu_barline` (kind), `system_line`, `tab_clef`, `tab_timesig`, `volta` (numbers), `section_label`
* tab: `tab_cross` (string, event, beat), `tab_fret` (string, value, technique), `tab_rest`, `tab_technique` (H/P), `tab_arc`, `strum` (direction, strings, style), `stem` (event, q), `stem_dot`, `beam` (level, kind, events)
* chords: `chord_name` (value, beat), `chord_diagram` (grid bbox, frets, baseFret), `chord_dot` (string, fret, finger), `chord_marker` (open/muted per string), `chord_basefret`, `chord_barre`
* jianpu: `jianpu_digit` (degree, octave, accidental, note, q), `jianpu_dot` (above/below), `jianpu_accidental`, `jianpu_aug_dot`, `jianpu_dash`, `jianpu_underline` (level), `jianpu_tie` (tie/slur), `jianpu_paren`
* lyrics: `lyric_char` (verse, note, value), `lyric_punct`
* header (score content): `header_title`, `header_artist`, `header_key`, `header_timesig`, `header_capo`, `header_tempo`, `header_origkey`, `header_credit`
* `nonScore: true`: `page_number`, `page_header`, `wm_text` (diag/side/QR caption/gray background tiles; opacity, color, rotation), `wm_logo`, `wm_qr` (url), `wm_url` (footer/header URLs), `wm_gray_text`.
  Watermarks are drawn over/under the score (opacity 5-35 % for transparent ones); QR codes / URL lines avoid score elements, transparent text may cross them.

## Degradations (each recorded in `degradations`)
background tint/paper texture (also the preset's own bg), watermarks (diagonal site name 1-3x, corner logo, QR + "扫码关注" caption, footer/header URL, side text, tiled gray text),
rotation <= 1.5 deg on 20 % of pages, phone-screenshot bars/padding/crop on ~25 %, contrast loss, down-up scaling, Gaussian blur, noise, JPEG q70-95.

## Examples (`examples/`)
`classic_ref_clean.png` (6/8, capo, voltas absent, clean), `bold_app_watermarked.png` (diag URL watermark, QR, footer URL, logo, bold_app preset, 900 px, 20 colors),
`compact_dense_screenshot.png` (5 measures/system, 3/4, 3-verse lyrics, paper tint, screenshot padding, diagonal site-name watermark).

## Visual fidelity vs the reference image (honest notes)
Matches: header (title/artist/`1= C 4/4`), chord name + diagram above every measure, six-line staff with stacked T/A/B and time signature (first system),
x marks on string lines with halo, digits with H/P arcs, stems and beams under the staff in the same bracket shape, the long gap down to a bold numbered-notation row with octave dots,
underlines, dashes, dotted values, ties, parentheses, 1-3 lyric rows, repeat barlines, left system line, page number. Differences:
* x marks, fonts and diagram dots are vector-perfect while the reference has slightly uneven pixel rasterization; beam/stem lengths are fixed per preset.
* Tab rhythm is generated from pattern libraries (arpeggio / strum); real songs vary more and use many more fingering idioms (slides, bends, rasgueado marks, rests inside beams).
* Reference prints the same diagram under every measure with real fingerings; ours uses a table of ~55 shapes, heuristic fingers, and some invented names for the "(n)" variants (shape for `D7(5)` etc. is plausible, not canonical).
* Jianpu notes are placed linearly in time; dense 16th measures shrink the digit font, the reference keeps equal spacing and font size. Lyrics are random characters, so no real phrasing.
* Rests in the tab are the "-" dash only; no multi-measure rests, no lyrics with several chars per note, no fermatas/D.S./coda marks, no chord-diagram fret numbers other than the base fret.
* Sites that print staff-less rhythm slashes only, or fingerstyle (note-level) tabs without chords, are not covered.
