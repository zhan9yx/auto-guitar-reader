# hold-011 verification (independent second pass)

Checked every system/measure against the image: header (title, artist, 选调 C, capo 2, 6/8, credits), all 22 chord marks + diagram strings (x/o markers, dot rows; no baseFret numbers printed), tab x strings per event (string index from line position), stem/beam durations (6/8: 1 beam = 1 beat), 6-note jianpu patterns, octave dots, underlines, dotted values, ties, 5 (3 in last system) lyric verses character by character, barlines/repeats, anchors, watermarks.

## Corrections (1)
- sys3 (s0l2) m5 leftBarline: endRepeat -> single. Reason: the thin-thick repeat sign at the end of m4 has dots only on its left (end repeat of m4); nothing is printed on its right, so it is not a shared sign and m5 starts with no barline of its own (spec: shared sign only for start/end pairs). m4.rightBarline stays endRepeat. meta.uncertain wording updated.

## Verified without change
- All chord diagrams: C [x,3,2,0,1,0], Em [0,2,2,0,0,0], F [x,x,3,2,1,1], G [3,2,0,0,0,3], Dm [x,x,0,2,3,1], Am [x,0,2,2,1,0].
- Tab strings per measure (C: s5 s3 s2 s1 s2 s3; Em/F/Am-type: s4 ...; G: s6 ...; sys3 m3 F|Dm: s4 s3 s2 s4 s3 s2 with Dm at beat 3), wavy up arrows s1-s6 (sys2 m2, 3 beats each, arc above not stored).
- Melody degrees, octave dots (sys3 m5 i x4; sys4 i/2/3/7 dots), dotted/underlined durations (sys4 m2 2. i 7 = 1.5/0.5/1), ties/slurs (5.-5., 5-4 arc, 1.-1, 6.-6., 2-2).
- All lyric rows (verses 1-5 for sys2/sys3, verses 1-3 for sys3 m5 and sys4); 器 not 嚣 not applicable here.

## Residual uncertainties
- Intro brackets "(" / ")" not stored; arc over the two wavy arrows not stored.
- Whether the arc 5->4 (sys3 m2, different pitches) is a slur (stored as tieToNext).
- No fret-number printed on any diagram -> baseFret 1.
