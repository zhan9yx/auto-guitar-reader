# hold-003 independent verification (gt-dev)
Result: 0 corrections. Every one of the 24 measures (8 systems x 3) was cropped at 3.5x and compared digit by digit (string line, onset, stem/beam duration), plus header, repeat, volta, footer.
- Ties: bare stems after an arc exist as real beamed/stem onsets (m1-4 beat 2 s2 f3; m16 beat 2 s1 f2 + s2 f3 (s6 3 NOT tied); m17 beat 2 s1 f2, s3 f2, s4 f0 (s2 f1 has no arc)). Each is one event with technique tie on the tied fret, no extra fabricated events; durations match the stems (0.5 in beamed pairs). Arc endpoints land on the bare stem, not on the following digit.
- Grace digits: small 2 (m6 s3, before 4 H) and small 0 (m20 s4, before 2 H) have no stem; destination stored with hammerOn, grace not stored (no grace concept in spec).
- m18 dotted-eighth pair (0.75,0.75) + flag eighth 0.5: dots seen under beam; m12 beat 2 and m20 beat 2, m21 beat 0, m22 beat 2, m24 beat 1.5 quarter stems confirmed.
- Repeat: thick-thin dotted sign between m4/m5 only; volta "1." over m20 only (bracket ends at m20's right barline). Header (title, subtitle, 久石让, Tabbed by, Moderate=90, Standard tuning, 1/3) matches.
Residual: grace notes unrepresented; whether tied bare stems should rather carry no event is a spec decision (kept as tie-technique events).
Lint: errors=0 warnings=0.
