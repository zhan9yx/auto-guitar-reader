# Ground-truth transcription conventions (real dataset)
(Beat unit: see the last section - beat = denominator unit, so 6/8 has 6 beats per measure.)

Output per page `<id>`: `gt/<id>.agr.json` (AGR v2 Score) and `gt/<id>.meta.json` (sidecar). Accuracy is paramount: transcribe what is PRINTED, never what you expect musically.

## Score skeleton
`{"format":"agr-score","version":2,"id":"<uuid4>","meta":{title,artist,key,capo,tempo,timeSignature:{beats,unit},mode:"strumSing","source":{"kind":"image","fileName":"<id>.<ext>"},"credits":[...]},"chordDefinitions":{},"strumPatterns":[],"sections":[{"id":"s0","name":"","kind":"other","lines":[ ...system lines... ]}],"pages":[{"fileName":"<id>.<ext>","width":W,"height":H}]}`
* Header fields only if printed on this page (continuation pages: title "" unless printed; copy key/time/capo from the song's first page only if printed on THIS page, else use title "" key null capo 0 and defaults — the time signature then comes from the barline context; use 4/4 unless printed).
* `key` = printed "1=X" as `X` (e.g. "C", "G", "#F"->"F#"); `capo` = printed Capo/变调夹 fret (0 if none); `tempo` printed BPM (omit→default 80); `credits` = printed 制谱/编配/词曲/公众号 style text lines that belong to the score header (strings verbatim).
* Section labels printed on the page (前奏/主歌/副歌/间奏/Verse...) -> put in the first measure of that system as `marks:["前奏"]` (verbatim text), keep one section.
* Every system (one row of staves: chord diagrams + 6-line tab + rhythm stems + jianpu + lyrics) = one line: `{"id":"s0l<k>","kind":"system","segments":[],"anchor":{"page":0,"y":..,"height":..},"system":{"measures":[...]}}`; anchor = normalized (0..1, top-left origin) vertical extent of the whole system block from top of chord names/diagrams to bottom of last lyric line.
* If a page shows only tab / only jianpu / no chord diagrams, leave those arrays empty. Never invent content.

## Measure
`{"beats":<only if not the time-signature length>,"chords":[{"name","beat","shape"}],"tab":[events],"melody":[notes],"leftBarline","rightBarline","volta":[],"marks":[]}`
* Measures are delimited by the barlines of the 六线谱 staff (jianpu barlines normally align). A measure with no barline on the left of the first measure uses `single`.
* barline kinds: single, double, final, startRepeat (`|:`), endRepeat (`:|`), startEndRepeat. Thick-thin = final/repeat as drawn. A repeat sign shared by two measures sets rightBarline of the first and leftBarline of the second consistently (endRepeat/startRepeat, or startEndRepeat on both sides).
* `volta`: `[1]` / `[2]` for 1./2. brackets over that measure. Other text above (D.S., Fine, rit., 第x遍) -> `marks`.
### Chords
* `name` verbatim as printed with spaces removed ("D7 (5)" -> "D7(5)", "Gsus4", "Am7", "G/B"). `beat` = position inside measure measured in beats (0-based) by horizontal alignment within the measure; if the name is printed once over the measure start it is 0. Chord names that are printed above the staff only (no diagram) still count. If a diagram is printed ONLY for the first occurrence, later repeats of the same chord name have no shape (don't copy).
* `shape` only when a diagram is printed for that chord mark: `{"frets":[f6,f5,f4,f3,f2,f1],"baseFret":b}` leftmost vertical line = 6th string (low E) ... rightmost = 1st string. Above the nut: `x`/× -> -1, `o`/hollow circle -> 0, nothing printed -> 0. A dot in diagram row r (r=1 is the first row below the top line) gives absolute fret `b + r - 1`. `b` = the small number printed beside the diagram (e.g. "3" -> baseFret 3, then top line is fret 3's top... i.e. row 1 = fret 3); no number -> baseFret 1 with a thick nut. Barre drawn as bar/arc over several strings: the fret is on every spanned string. If diagram unreadable, omit `shape` and add `"marks":["shape?"]`... but try hard to read via zoomed crops.
### Tab events (六线谱)
* `{"beat":b,"duration":d,"notes":[...],"stroke":"down"|"up" (only for arrow strums)}`. Units are quarter-note beats (4/4 -> 4 beats per measure).
* Event onset = horizontal order/alignment within the measure; use the rhythm stems drawn beneath the staff: plain stem = 1 beat; stem with one beam/flag = 1/2 beat; two beams = 1/4 beat; dot = x1.5; a beamed pair spans consecutive onsets. Printed rest dashes/rest signs produce NO event (leave the gap). `duration` of each event = the note value implied by its stem (not the gap to the next event). If NO stems are printed (e.g. pure arrow strums or plain digits), set duration = distance to next event (or to the barline), quantised to 1/4 beat.
* Pick mark `×` on a string line: `{"string":n,"chordTone":true}` (no fret). Digit: `{"string":n,"fret":f}`. String number from the line: top line = string 1 ... bottom line = string 6. Notes that sound together (same x, or one arrow/vertical line connecting them) share ONE event.
* Strum arrow spanning several strings: one event; `notes` = one chordTone note for each string line the arrow spans (from its start string to its end string inclusive), `stroke` = direction of the arrowhead (head pointing towards string 6/bottom = "down"; towards string 1/top = "up"). If the same page also prints digits for those strings, use fret notes instead.
* Technique on the DESTINATION note: `H` hammer-on -> hammerOn, `P` pull-off -> pullOff, `S`/slash/slide line -> slideUp / slideDown, bend -> bend, harmonic `<>` -> harmonic, muted x with no chordTone semantics (e.g. "X" in a strum row printed as muted) -> `fret 0, technique mute` ONLY when the page's legend says so; otherwise × is chordTone. Slur arc between two fret digits without letter -> destination hammerOn if rising, pullOff if falling.
### Melody (简谱 row)
* One entry per note/rest in order. `degree` 1..7 (0 = rest, printed "0"), `octave` = dots above (+1,+2) / below (-1,-2), `accidental` +1 for ♯/#, -1 for ♭/b printed in front of the digit.
* `duration` in quarter-note beats: plain digit = 1; each underline (减时线) halves (1 line 0.5, 2 lines 0.25); each following "-" adds 1; dot after the digit x1.5. Beamed groups share the underline over several digits. `beat` = running sum from measure start. Rests also have entries (degree 0). Notes must exactly fill the measure (or set `beats` for a pickup).
* `tieToNext` = true when an arc (tie/slur) starts at this note and ends at the next note. Dash "-" extension belongs to the previous note's duration (no separate entry).
* `lyrics`: array per verse = printed text under that note; `["我"]`, for 2 lyric lines `["爱","青"]`. Index = order of lyric rows from top. A lyric char printed under a note sits at the same x; trailing punctuation printed with the char is kept ("地,"; use the characters as printed, Chinese punctuation as printed). "" if verse has nothing under that note (when other verses do). Chars of one syllable group "The+rain" printed under one note stay in one string. Lyric text with no melody notes (pages w/o 简谱) -> not representable: add the characters to `marks` of the measure as "lyric:<text>".

## Sidecar `<id>.meta.json`
`{"id":"real-NNN","site":"jitabang","style":"short style tag","pageNumber":<printed page number or null>,"watermarks":["every non-score text/graphic printed on the page: site names, URLs, QR code, 'WeChat' blurbs, taobao banners, logos, diagonal watermark text — verbatim; for QR codes write 'QR code (location)'"],"features":["strum arrows","fingerpicking x","multi-verse","repeat","volta","capo", ...],"uncertain":["list of glyphs you could not read with confidence: system/measure/what"]}`

## Tools (read-only usage of images)
Python venv: `<R>/.venv/bin/python -I`; crop+zoom: `OMR_REAL_ROOT=<R> <py> <T>/crop.py <id> x0 y0 x1 y1 [scale] [out]` (fractions of page; crops land in `<R>/tmp/crops/`), then view the PNG with the image-reading tool (Read). Zoom each measure; target crops <= ~1400 px wide. Lint: `<py> <T>/check_gt.py gt/<id>.agr.json`.

## Worked example (reference page real-000, system 1, measures 1-2)
Chord C diagram (x o o above strings 6,... read from image) etc. Tab m1: × s5 beat0 (d .5), × s3 beat .5 (d .5), × s1 beat 1 (d .5), × s5 beat 1.5 (d .5), × s3 beat 2 (d 1), rest beat 3 (no event); melody "(0 0 0 0" = four rests d 1 (the "(" is not stored; add marks:["("]? no: ignore bracket). Chord names verbatim; page-number "1" and nothing else is non-score.

## Beat unit (IMPORTANT)
A "beat" = one unit of the time-signature DENOMINATOR (AGR/Timeline convention): in 4/4 a beat is a quarter note; in 6/8 a beat is an EIGHTH note (6 beats per measure, quarter = 2 beats, 0.5 = sixteenth); in 3/4 a beat is a quarter. All `beat`, `duration` and chord-mark beats use that unit; do not set `beats` on a measure unless it is a pickup/irregular measure. Melody underline rule in 6/8: plain digit = 2 beats (a quarter), one underline = 1 beat.
