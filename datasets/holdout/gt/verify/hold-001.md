# Verification log hold-001

Method: every system and measure cropped at 4-5x and compared with the JSON (chord names/beats, diagram strings incl. markers and baseFret, tab strings/frets/durations, melody degree/octave/underlines/ties, lyrics, barlines/repeat, header).

## Corrections
1. agr.json line s0l3 anchor: y 0.729 -> 0.714, height 0.163 -> 0.178. Reason: chord name "#Cm" and the "13" measure number sit about 0.015 higher than the stored top (name top at ~0.716 of page height); bottom unchanged (0.892).
2. meta.json uncertain[]: text said the m16 final beat has a wavy up arrow. It has none (plain x on strings 1,2 with a quarter stem). Reworded; the arrows are only in m8 and m12 (beat 2, strings 1-6, up). The GT data itself was already correct.

## Checked and found correct (no change)
- All 16 measures of tab (x strings incl. bottom-line x on s6 in #Fm11/E measures, 6-7-6-7 sixteenth run + tied 7-7 in m1/m3, 0 on s2 in m2/m4), durations from stems/beams, arrow spans (s1-s6 up).
- Chord diagrams: A, A/D, #Fm11, Dsus2, E, Esus4 (open-string circles), #Cm baseFret 4 [4,4,6,6,5,4]; chord beats incl. E at beat 3 in m16.
- Melody: dotted/16th groups, low octave dots (7 in m11, 5 in m13/m16, 6 in m15), tie arcs (m7, m11, m12, m16), dashes (m4), lyrics per note (tied notes carry none). Start repeat at m13, final barlines single.
- No key/capo/tempo/artist printed; title 黑色幽默; page 第1页.

## Residual uncertainty
- Diagram strings without any marker are read as fret 0 per spec (A, A/D, #Fm11).
- Tab 7-7 equal-fret slur stored as technique "tie" (lint accepts).
