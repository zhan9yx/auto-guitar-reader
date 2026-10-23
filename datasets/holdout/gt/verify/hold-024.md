# hold-024 verification (independent second pass)

Result: 0 corrections to hold-024.agr.json / hold-024.meta.json. Lint: 0 errors, 0 warnings (5 systems, 18 measures).

## Checked field by field (all matched the pixels)
- Header: title 魔鬼中的天使, "此谱由爱乐谱提供 演唱：田馥甄", "1=#F 4/4", "降半音调弦"; measure numbers 5/8/12/16 are not score content.
- Barlines: only repeat is the start repeat between m10 and m11 (thick+thin+dots, no end repeat on this page); all others single.
- Chord diagrams (string by string, x/o, dot rows, baseFret): Em, D, C, Am7, G, Cmaj7, B7 (open 6th string as printed: [0,2,1,2,0,2]), Bm7 (small "2" beside first row -> baseFret 2, frets [-1,2,4,2,3,2]). Chord beats checked against arrow x positions (diagram left edge = event x): D/Bm7/Cmaj7/D beat 2 in sys1-3, D at beat 3 in m16, G at beat 2 in m17/m18.
- System 1 tab (x pick marks on strings): all 4 measures, string and beat of each x, beam groups (8th/16th) - correct.
- Strum arrows: arrow extents measured by pixel scan of every arrow in systems 2-5 (not just by eye). Quarter arrows at beats 0 and 2: strings 1-5 (tail ends just under line 5); beamed 8th/16th arrows (up and down): strings 1-4; dotted-8th arrows in m17/m18 start on string 2 (head on line 2) and end on string 5 -> strings 2-5. All match the JSON, including up/down directions. Rolled (wavy) arrows zoomed 12x: m4 head on line 1, tail just past line 4 -> up 1-4; m10 head on line 2, tail just past line 5 -> up 2-5. The vertical line right of m10's last down arrow is that arrow, not a barline.
- Rests: m4 dashes at beats 1,2,3; m10 dash at beat 3; no events.
- Melody: all degrees, octave dots (dots on 1^ in triplets, 2^ in m5/m11, all dotted notes in m16-m18 etc.), underline counts, dotted notes, ties (m5/m11 7-7 and 2-2, m6/m12/m13 2 -> 2, m9 3 -> m10 3, m15 7-7 and final 6 -> m16 6, m18 3-3), triplets (m5, m11), dashes (3 - in m10, 2 - in m14, 6 - in m16). Grace notes (m7, m8, m13, m15) intentionally not transcribed.
- Lyrics: every syllable compared character by character; empty slots under tied/continued notes are correct.
- Anchors consistent; meta watermarks/features consistent.

## C / B7 placement in m9 and m15
m9: C diagram left edge sits 45 px (at 4x zoom) left of the beat-2 arrow, B7 diagram left edge aligns with the beat-3 arrow. m15: C diagram is 32 px left of the beat-2 arrow, B7 aligned with beat 3. Unshifted, the beat-2 C diagram would overlap the B7 diagram in both measures, so the layout engine shifted it left. Reading C at beat 2 and B7 at beat 3 (as in JSON) is the only musically sensible one (Am7 | C | B7 over 念头 在 吼叫 / 想都别 想我 求饶); the alternative (C at the beat-1.75 down-strum, which is nearer in m9) is rejected. Kept; already recorded in meta.uncertain.

## Residual uncertainties
- C chord beat 2 (shifted diagram) in m9/m15, as above.
- Triplet representation (1/3-beat notes) and untranscribed grace notes: format limitations, unchanged.
