# AGR Score JSON v1 (`agr-score`)

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
Line    { id, kind, segments[], tab?, text?, anchor? }
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
