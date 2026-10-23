# hold-014 verification (independent second pass)

Checked every system/measure against the image at 4-8x zoom: header (title glyphs, artist 黑龙, capo 1, 4/4, credit 编配), chord diagrams (AM, A5, G5: baseFret 5/5/3, x/o markers, dot rows), every tab event (x strings, '8' on s2 with s6 x, 4-x column s1-s4, x s2+s6 pairs, arrow direction and string span via shaft length, dotted-eighth + sixteenth beam stubs), beam levels for 0.5/0.25 durations, jianpu rests/digits/underline counts (single/double stubs), octave dots, ties, lyrics, barlines, anchors, watermark list.

## Corrections: 0
No field disagreed with the image. Re-derived in particular:
- sys1 m1/m3/m5 and sys2 m2: beat 2 = {s2 fret 8, s6 x} d0.75 + s1 x d0.25 (the dash right of the dot is the second-beam stub of a sixteenth); beat 3 = s1-s4 column d0.5, then s2+s6 x d0.5.
- sys1 m5 / sys2 m2 beat 0 up arrow is continuous into the stem (s1-s6); other arrows end at s5 (gap to stem); sys2 m3 and sys2 m4 onward arrows span s4-s6.
- Rhythm groupings with second-level beams in sys2 m4, sys3, sys4 (eighth + two sixteenths, four sixteenths, eighth + two sixteenths).
- Jianpu double-underline stubs: 5(.25) 5(.5) 5(.25) 5(.5) in sys3 m2 / sys4 m3; 6(.25) 6(.5) 6(.25) 6(.5) 5(.5) 6(1) in sys4 m1; 3 5 as sixteenths before barline.
- Title: first two glyphs are identical, both 摆 -> 《摆摆绅士》 kept as printed. 眸 and 器 read as printed.

## Residual uncertainties
- Arrow shaft span on beat-1 up arrows of sys1 m1/m3 (gap in the JPEG line between s3 and s4) - read as s1-s6.
- Lyric glyph 眸 (sys3 m3) and 器 (sys4 m2) low-res.
- '8' digit glyph is small; read as 8.

## Follow-up (coordinator decision): PM columns -> mute
Legend 注："一排X"为"PM"拍弦. Every stacked x column (>=3 x on adjacent strings, same beat, no arrow) re-encoded from chordTone to {string, fret:0, technique:"mute"} per string. Events changed: 4 (sys1 m1, m3, m5 beat 3: s1-s4; sys2 m2 beat 3: s1-s4). Single x, x pairs (s2+s6, s1+s6) and all arrows unchanged. meta.uncertain PM entry rewritten accordingly.
