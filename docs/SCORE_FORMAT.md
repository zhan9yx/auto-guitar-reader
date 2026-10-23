# AGR Score JSON (`agr-score`, v1 core + v2 notation systems)

The standardized score format of Auto Guitar Reader. Every importer (ChordPro, chord-over-lyrics text,
ASCII tab, MusicXML, OCR) produces it, and the timeline, playback, follower and UI consume it.
The Swift definition is `Core/Sources/AGRCore/Model/Score.swift` (this document is the human-readable spec;
if they disagree, the Swift code wins). Files use the extension `.agr.json`, UTF-8, any JSON formatting.

Decoding is lenient at the top level and in `meta`: a missing `meta`, `sections`, `chordDefinitions`,
`strumPatterns`, `pages` or any `meta` field decodes to its default. Below that level the decoder is strict:
`Section` needs `id`, `name`, `kind`, `lines`; `Line` needs `id`, `kind`, `segments` (use `[]` for tab/comment lines);
`ChordSegment` needs `text`; `ChordShape` needs `frets` and `baseFret`; tab events need `beat`, `duration`, `notes`.

## 1. Top level

| Field | Type | Meaning |
|---|---|---|
| `format` | string | Always `"agr-score"`. |
| `version` | int | `1`. Bumped together with this document on incompatible changes. |
| `id` | UUID string | Identity of the score (library key, community id basis). |
| `meta` | object | Title, artist, key, capo, tempo, time signature, tuning, mode, source. |
| `chordDefinitions` | `{ "Am": ChordShape }` | Fingerings keyed by chord symbol **as written**; override the built-in chord library. |
| `strumPatterns` | `[StrumPattern]` | Strumming patterns; sections refer to them by id. |
| `sections` | `[Section]` | The song, in written order. |
| `arrangement` | `[string]?` | Play order as section ids (repeats allowed). `null` = `sections` in order. |
| `pages` | `[PageImage]` | Original page images for image/PDF imports (files live next to the JSON in the score package). |

## 2. `meta`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `title` | string | `""` | Song title. |
| `artist`, `composer`, `lyricist`, `arranger` | string? | null | Credits. |
| `key` | string? | null | Original key as written (原调), e.g. `"G"`, `"Em"`. Informational; transposition is done on chords. |
| `capo` | int | `0` | Capo fret (变调夹). See "Capo semantics". |
| `tempo` | number | `80` | BPM; the beat is the denominator unit of `timeSignature`. |
| `timeSignature` | `{beats, unit}` | `4/4` | Used for default measure length. |
| `tuning` | `[int]` (6) | `[40,45,50,55,59,64]` | Open-string MIDI notes, **low (6th string) → high (1st string)**. |
| `mode` | `"strumSing"` \| `"fingerstyle"` | `strumSing` | 弹唱 (chords + lyrics) or 指弹 (note-level tab). Selects follower and planner. |
| `source` | `{kind, fileName?, importedAt?}` | null | `kind` ∈ `agr, chordpro, chordText, asciiTab, musicXML, guitarPro, image, pdf, manual`. |
| `tags` | `[string]` | `[]` | Free-form tags. |

### Capo semantics
Chord names and fret numbers always describe the **fingering as played** (the shapes you form relative to the capo).
The sounding pitch is `tuning[string] + capo + fret` (open string with capo 2 on E = F#). For chords, the sounding
chord is the written chord transposed up by `capo` semitones; the app shows both ("Capo 2 · play G, sounds A").
`key` is the original (sounding) key of the song; with `capo = 2` and `key = "A"` the written shapes are in G.

## 3. Sections and lines

```
Section { id, name, kind, lines[], strumPatternID? }
Line    { id, kind, segments[], tab?, text?, anchor?, system? }
```

* `Section.name` is the display name as written (`"主歌 1"`, `"Chorus"`); `kind` ∈
  `intro, verse, preChorus, chorus, bridge, interlude, solo, outro, other` (used for jumps and styling).
  Importers recognise `Verse/Chorus/Intro/Outro/Bridge/Pre-Chorus/Solo/Interlude` and `前奏/主歌/副歌/间奏/尾奏/桥段/过门`.
  Text before any section label goes to an unnamed section (`name: ""`, `kind: "other"`).
* Importers use stable ids: sections `s0, s1, …`, lines `s<i>l<j>` (e.g. `s0l3`). Any unique strings are valid.
* `Line.kind`:
  * `lyrics` — chords placed over lyric text (`segments`).
  * `chords` — chord-only line (intro/interlude), `segments` with empty `text`.
  * `tab` — one system of six-line tablature (`tab`).
  * `system` — full notation system (v2, §9): measures with chord marks/diagrams, printed tab incl. "×" chord-tone
    picks and strums, 简谱 melody and multi-verse lyrics (`system`).
  * `comment` — free text (`text`), never played. Image imports use `"[tab]"` comments as placeholders for tab systems
    that were detected but not transcribed.
* `anchor` (`{page, y, height}`): region of the original page image (page index into `pages`, `y`/`height`
  normalized 0…1, origin top-left). Lets the original-image view highlight and scroll to the line.

### Chord segments
`ChordSegment { chord?, text, beats? }`. `"[G]我曾经[C]跨过山和大海"` is
`[{"chord":"G","text":"我曾经"},{"chord":"C","text":"跨过山和大海"}]`. A first segment with `chord: null` holds text
before the first chord. `chord` is the symbol as written; parse with `ChordSymbol(_:)`. Non-chord markers such as
`"N.C."` may appear and must be treated as "no chord / rest". `beats` overrides the default duration.

### Default durations (`beats == nil`)
* Each chord segment lasts **one measure** (`timeSignature.beats` beats).
* Lyric text before the first chord of a line belongs to the previous chord.
* A lyric line without any chord continues the previous chord and lasts `max(1, ceil(characterCount / 8))` measures.
* A `chords` line gives one measure per chord.
* Tab events use their own `beat` / `duration` (below).

## 4. Tab

```
TabBlock   { measures[] }
TabMeasure { beats?, events[] }          // beats = length in beats, null = timeSignature.beats
TabEvent   { beat, duration, notes[], chord?, stroke? }
TabNote    { string, fret, technique? }
```

* `beat` is the onset in beats from the start of the measure; `duration` is in beats. Notes that sound together
  (same column in ASCII tab, `<chord/>` in MusicXML) share one event.
* **String numbering**: `1` = high E (1st string) … `6` = low E (6th string). In ASCII tab the top line is string 1.
  `tuning[6 - string]` is the open pitch; sounding MIDI = `tuning[6 - string] + capo + fret`.
* `fret` is the fret as played (relative to the capo); `0` = open. A muted note is `fret: 0, technique: "mute"`.
* `technique` ∈ `hammerOn, pullOff, slideUp, slideDown, bend, harmonic, mute, tie`. `hammerOn`, `pullOff`,
  `slideUp`, `slideDown` and `tie` describe **how the note is reached**, so they sit on the *destination* note
  (`5h7` → notes `5` and `7{hammerOn}`). `bend` and `harmonic` sit on the note itself (a bend target such as the `9`
  in `7b9` is not stored).
* `chord` is a chord name shown above the event (chord names written above ASCII tab attach to the nearest column).
* `stroke` (`down`/`up`) marks strum direction for rhythm-tab notation.
* A `.tab` line holds a few measures (importers write ~4 per line).

### ASCII tab → beats
Within a measure the column position maps linearly to the beat: `beat = column / measureWidth × measureBeats`,
quantized to 1/8 beat. An event lasts until the next event (or the end of the measure).

## 5. Chord definitions and strumming

* `ChordShape { frets[6], fingers?, baseFret }` — frets low E → high E, **absolute** fret numbers, `-1` = muted,
  `0` = open. `baseFret` only tells the UI which fret the diagram starts at.
  (ChordPro `{define}` frets are relative to `base-fret`; the importer converts.)
* `StrumPattern { id, name, subdivision, strokes }` — one measure; `strokes` has `timeSignature.beats × subdivision`
  characters: `D` down, `U` up, `-` rest/sustain, `X` muted chuck, `B` bass note, `1`–`6` single-string pluck.
  Example (4/4 eighths): `"D-DU-UDU"`.

## 6. Import mapping cheat-sheet

| Source | Notes |
|---|---|
| ChordPro | `{title}{artist}{key}{capo}{tempo}{time}{define}`; `{soc}`, `{sov}`, `{sob}`, `{start_of_part: Intro}` → sections; `[C]` inline chords; `{sot}` ASCII tab; `{c:}` → `comment`. |
| Chord-over-lyrics text | A chord line merges with the following lyric line by **display columns** (CJK / full-width = 2 columns). Chord line + blank line → `chords` line. Embedded tab blocks → `tab` lines. |
| ASCII tab | Six-line groups; `\|` splits measures; `h p / \ b ~ x <n>` techniques. |
| MusicXML | `<harmony>` → chords, `<lyric>` → text, `<technical><string/><fret/>` → tab; `<rehearsal>` → sections. |
| OCR | Rows by y-clustering; chords attach to lyric characters by x; `anchor` per line; `meta.source.kind = "image"`. |

`ChordProExporter` writes the same information back (round-trip through `ChordProParser`), so scores can be edited as text.

## 7. Example: short Chinese 弹唱 song

```json
{
  "format": "agr-score",
  "version": 1,
  "id": "6F1B8C52-4C2E-4C0B-9E55-0A5E7C1D2B11",
  "meta": {
    "title": "示例之歌",
    "artist": "测试歌手",
    "key": "A",
    "capo": 2,
    "tempo": 76,
    "timeSignature": { "beats": 4, "unit": 4 },
    "tuning": [40, 45, 50, 55, 59, 64],
    "mode": "strumSing",
    "source": { "kind": "chordText", "fileName": "示例之歌.txt" },
    "tags": ["demo"]
  },
  "chordDefinitions": {
    "Am": { "frets": [-1, 0, 2, 2, 1, 0], "baseFret": 1 }
  },
  "strumPatterns": [
    { "id": "pop8", "name": "流行八分", "subdivision": 2, "strokes": "D-DU-UDU" }
  ],
  "sections": [
    {
      "id": "s0", "name": "前奏", "kind": "intro",
      "lines": [
        { "id": "s0l0", "kind": "chords",
          "segments": [
            { "chord": "G", "text": "" }, { "chord": "D", "text": "" },
            { "chord": "Em", "text": "" }, { "chord": "C", "text": "" }
          ] }
      ]
    },
    {
      "id": "s1", "name": "主歌 1", "kind": "verse", "strumPatternID": "pop8",
      "lines": [
        { "id": "s1l0", "kind": "lyrics",
          "segments": [
            { "chord": "G", "text": "我曾经跨过" },
            { "chord": "D", "text": "山和大" },
            { "chord": "Em", "text": "海" }
          ] },
        { "id": "s1l1", "kind": "lyrics",
          "segments": [
            { "chord": "C", "text": "也穿过人" },
            { "chord": "G", "text": "山人海", "beats": 8 }
          ] },
        { "id": "s1l2", "kind": "comment", "segments": [], "text": "(x2)" }
      ]
    },
    {
      "id": "s2", "name": "副歌", "kind": "chorus",
      "lines": [
        { "id": "s2l0", "kind": "lyrics",
          "segments": [ { "chord": "Am", "text": "啦啦啦" }, { "chord": "C", "text": "啦啦啦" } ] }
      ]
    }
  ],
  "arrangement": ["s0", "s1", "s2", "s1", "s2"],
  "pages": []
}
```

Reading it: capo 2 means the shapes G-D-Em-C sound as A-E-F#m-D (the original key A). `s1l1` second segment
lasts 8 beats instead of the default 4. The `arrangement` plays the verse and chorus twice.

## 8. Example: short fingerstyle tab

```json
{
  "format": "agr-score",
  "version": 1,
  "id": "0B7D6E3A-52D1-4E0B-8F45-3C9A1D7E4F22",
  "meta": {
    "title": "示例指弹",
    "tempo": 90,
    "timeSignature": { "beats": 4, "unit": 4 },
    "mode": "fingerstyle",
    "source": { "kind": "asciiTab" }
  },
  "chordDefinitions": {},
  "strumPatterns": [],
  "sections": [
    {
      "id": "s0", "name": "", "kind": "other",
      "lines": [
        { "id": "s0l0", "kind": "tab",
          "segments": [],
          "tab": {
            "measures": [
              { "events": [
                  { "beat": 0, "duration": 1, "chord": "Am",
                    "notes": [ { "string": 5, "fret": 0 }, { "string": 2, "fret": 1 } ] },
                  { "beat": 1, "duration": 1, "notes": [ { "string": 3, "fret": 2 } ] },
                  { "beat": 2, "duration": 0.5, "notes": [ { "string": 2, "fret": 1 } ] },
                  { "beat": 2.5, "duration": 1.5,
                    "notes": [ { "string": 2, "fret": 3, "technique": "hammerOn" } ] }
              ] },
              { "events": [
                  { "beat": 0, "duration": 2, "chord": "E",
                    "notes": [ { "string": 6, "fret": 0 }, { "string": 1, "fret": 0 } ] },
                  { "beat": 2, "duration": 2, "notes": [ { "string": 1, "fret": 2, "technique": "slideUp" } ] }
              ] }
            ]
          } }
      ]
    }
  ],
  "pages": []
}
```

The same music as ASCII tab (what `AsciiTabParser` reads and `ChordProExporter` writes inside `{sot}`…`{eot}`;
8 slots per 4/4 measure, 2 characters per slot):

```
  Am               E
e|----------------|0------/2-------|
B|1-------1h3-----|----------------|
G|----2-----------|----------------|
D|----------------|----------------|
A|0---------------|----------------|
E|----------------|0---------------|
```

## 9. Notation systems (v2, `Line.kind = "system"`)

The common Chinese 弹唱六线谱 layout: per system a row of measures, each with chord names (+ chord diagrams), a
six-line tab (× / fret digits / strums), a numbered-notation (简谱) melody and 1..N verses of lyrics. Produced by the
OMR engine (see `docs/OMR.md`); consumed by timeline, playback, follower and the OMR scorer. Decoding is lenient:
every field below except those marked *required* has a default.

```
Line.system = NotationSystem { measures[] }
NotationMeasure {
  beats?        length in beats; nil = time-signature beats (pickup measures set it)
  chords[]      ChordMark { name, beat, shape? }
  tab[]         TabEvent  { beat, duration, notes[], chord?, stroke? }      (same type as v1 tab)
  melody[]      MelodyNote { beat, duration, degree, accidental, octave, tieToNext, lyrics[] }
  leftBarline, rightBarline   single | double | final | startRepeat | endRepeat | startEndRepeat   (default single)
  volta[]       ending numbers this measure belongs to ([1], [2]); [] = every pass
  marks[]       free text: "D.S.", "D.C.", "Segno", "Fine", "To Coda", "Coda", "rit.", section labels
}
```

* `ChordMark.name` is kept **as printed** ("D7(5)", "G7(3)", "D(7)", full-width allowed). Harmony comes from
  `ChordNameNormalizer`: a trailing `(n)` after a chord that already has its quality (D7(5), C(5)) is a string/fingering
  variant and the chord is D7 / C; `(7)` / `(9)` after a plain triad is an optional extension (D(7) → D7, D(9) → Dadd9);
  `(b5)`, `(add9)` etc. are folded into the name; full-width characters and ♯/♭ are folded; "N.C." has no harmony.
  `ChordMark.shape` is the printed diagram: `ChordShape { frets[6] low E → high E, -1 = muted, 0 = open (absolute frets),
  fingers?, baseFret }`. Shape priority for sound: `ChordMark.shape` → `Score.chordDefinitions[name]` → built-in library
  (the library is used when the song is transposed).
* A chord stays in effect until the next `ChordMark`, also across measures and systems.
* `TabNote { string 1..6 (1 = high E), fret, technique?, chordTone }` — `chordTone: true` is the printed "×": play that
  string as fretted by the chord in effect at that beat (fret taken from the shape; a string the shape mutes is skipped).
  Digits are absolute frets as printed. `TabEvent.stroke` (`down`/`up`) marks a strum over the listed strings.
  JSON of a × is `{"string": 5, "chordTone": true}` (no `fret`).
* `MelodyNote.degree` 1…7 (0 = rest) in the key of `meta.key` ("C", "1=D", "Am" = relative major): `octave` = dots above (+)
  / below (−), `accidental` ±1, `duration` in beats, `tieToNext` ties to the next note of the same pitch. `lyrics[v]` is the
  syllable of verse v (`""` = none); `verseCount` of a measure is the longest `lyrics`.
* Repeats: `startRepeat`/`endRepeat`/`startEndRepeat` and voltas apply across the systems of one section (each repeat plays
  twice, `n` voltas play `n` passes); `D.S.`/`D.C.` (to "Segno"/start) with "Fine" and "To Coda"/"Coda" marks are honoured.
  Verse of a pass: the repeat pass index (or the section's arrangement pass when the section has no repeats), clamped to the
  verses the measure has. Implemented in `RepeatExpander`.
* Playback: the printed tab is played (× via the chord shape, strokes strummed low→high / high→low); default strum patterns
  only apply to measures without any tab. `PlaybackOptions.playMelody` adds the 简谱 melody as a soft voice.
* Timeline: `TimelineOptions.granularity` — `.chord` (default for `strumSing`: one event per chord span with the verse's
  syllables and the chord voicing) or `.tabEvent` (default for `fingerstyle`: one `.notes` event per tab event).
  `progressInLine` is measured in beats over the printed system. `Timeline.systemMeasures` holds the play-order expansion.

Example (two measures, key C, 4/4; chord diagrams for C and G7(3), × picks, 2 verses, start repeat):

```json
{
  "id": "s0l0", "kind": "system", "segments": [],
  "system": { "measures": [
    { "leftBarline": "startRepeat",
      "chords": [ { "name": "C", "beat": 0, "shape": { "frets": [-1, 3, 2, 0, 1, 0], "baseFret": 1 } } ],
      "tab": [
        { "beat": 0, "duration": 1, "stroke": "down", "notes": [ { "string": 5, "chordTone": true }, { "string": 3, "chordTone": true },
                                                                  { "string": 2, "chordTone": true }, { "string": 1, "chordTone": true } ] },
        { "beat": 1, "duration": 1, "notes": [ { "string": 4, "chordTone": true } ] },
        { "beat": 2, "duration": 1, "notes": [ { "string": 3, "chordTone": true } ] },
        { "beat": 3, "duration": 1, "notes": [ { "string": 2, "chordTone": true } ] } ],
      "melody": [
        { "beat": 0, "duration": 1, "degree": 3, "lyrics": ["小", "一"] },
        { "beat": 1, "duration": 1, "degree": 3, "lyrics": ["星", "二"] },
        { "beat": 2, "duration": 1, "degree": 5, "lyrics": ["星", "三"] },
        { "beat": 3, "duration": 1, "degree": 1, "octave": 1, "lyrics": ["你", "四"] } ] },
    { "rightBarline": "endRepeat",
      "chords": [ { "name": "G7(3)", "beat": 0, "shape": { "frets": [3, 2, 0, 0, 0, 1], "baseFret": 1 } } ],
      "tab": [
        { "beat": 0, "duration": 2, "notes": [ { "string": 6, "chordTone": true }, { "string": 4, "chordTone": true } ] },
        { "beat": 2, "duration": 2, "notes": [ { "string": 3, "chordTone": true }, { "string": 1, "fret": 1, "technique": "hammerOn" } ] } ],
      "melody": [
        { "beat": 0, "duration": 2, "degree": 2, "tieToNext": true, "lyrics": ["在", "五"] },
        { "beat": 2, "duration": 1, "degree": 2, "lyrics": ["", ""] },
        { "beat": 3, "duration": 1, "degree": 7, "octave": -1, "lyrics": ["哪", "六"] } ] }
  ] }
}
```

Tools: `NotationSystemFormatter.asciiTab(system)` renders the system as aligned text for diffing; `ChordProExporter` exports
systems lossily (chords + verse-1 lyrics + `{c:}` notes); `agr-tool omr-score --gt a.agr.json --pred b.agr.json [--json]`
scores a predicted score against a ground truth (`OMRScorer`: per-category tp/fp/fn with precision and recall, and a weighted
overall accuracy; `--metric v1|v2`, default v2; `--meta gt.meta.json` supplies the GT `watermarks` for v2 cleanliness).
Groups: tab 29% (tab notes + strokes), melody 19%, lyrics 19% (1 − CER), chords 15% (marks + diagrams), rhythm 5%,
barlines 5% (barlines/repeats/voltas/marks + measure alignment), header 5%, cleanliness 3% (v1 weights: tab 30, melody 20,
lyrics 20, chords 15, rhythm 5, barlines 5, header 5, no cleanliness). Categories empty in both GT and prediction are
skipped and the weights renormalized; a category empty only in the prediction scores 0.

Scorer v2 (honest metric; v1 kept for comparability):
- Measures of GT and prediction are aligned by sequence alignment, but two measures are paired only when their content
  similarity (Dice over chord/tab/melody/lyric tokens) is at least 0.3; otherwise the GT measure is missing and the predicted
  one extra, and everything in them is fn / fp.
- Rhythm counts every GT tab event, melody note and measure length as an item: a matched event with the wrong duration is
  fn + fp, a missed event is fn, an extra predicted event is fp. Measure length is always compared (effective length
  from the time signature), so a wrong time signature costs rhythm and header.
- Barlines: the right barline of every measure is counted (single included), plus non-default left barlines, voltas, marks.
- Header: also credits (normalized text) and capo/tempo/time/tuning/mode whenever either side is non-default.
- Cleanliness: literal strings extracted from the GT `watermarks` of `<id>.meta.json` (CJK runs of 4+ characters, digit runs
  of 7+, parentheticals dropped, strings that are part of the GT's own text excluded) must not appear in predicted
  title/artist/credits/lyrics: tp = absent, fp = leaked.
- `agr-tool omr eval --images dir --gt dir [--ocr dir] [--ids a,b] [--metric v1|v2] [--json out]` prints pooled and macro
  P/R/accuracy per category, groups and a per-page table; output is deterministic for identical recognizer output (the engine
  is not deterministic across processes: average over a shell loop, `for r in 1 2 3; do agr-tool omr eval ... > run.$r.txt; done`).
