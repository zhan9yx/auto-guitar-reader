import Foundation

/// Built-in demo score used by `agr-tool render --demo` and tests: a C–G–Am–F strummed progression with lyrics
/// followed by a short fingerstyle tab line (Am / C arpeggios).
public enum DemoScore {
    public static func make() -> Score {
        let verse = Section(id: "verse", name: "主歌", kind: .verse, lines: [
            Line(id: "v1", kind: .lyrics, segments: [
                ChordSegment(chord: "C", text: "我曾经"),
                ChordSegment(chord: "G", text: "跨过山和大海"),
                ChordSegment(chord: "Am", text: "也穿过"),
                ChordSegment(chord: "F", text: "人山人海"),
            ]),
        ])
        func n(_ string: Int, _ fret: Int) -> TabNote { TabNote(string: string, fret: fret) }
        // 4/4, eighth-note arpeggios: Am (x02210) then C (x32010).
        func arpeggio(_ bass: Int, _ f5: Int, _ f4: Int, _ f3: Int, _ f2: Int, _ f1: Int) -> TabMeasure {
            TabMeasure(beats: 4, events: [
                TabEvent(beat: 0, duration: 1, notes: [n(bass, f5)]),
                TabEvent(beat: 0.5, duration: 0.5, notes: [n(3, f3)]),
                TabEvent(beat: 1, duration: 0.5, notes: [n(2, f2)]),
                TabEvent(beat: 1.5, duration: 0.5, notes: [n(1, f1)]),
                TabEvent(beat: 2, duration: 1, notes: [n(4, f4), n(1, f1)]),
                TabEvent(beat: 3, duration: 0.5, notes: [n(2, f2)]),
                TabEvent(beat: 3.5, duration: 0.5, notes: [n(3, f3)]),
            ])
        }
        let tab = Section(id: "tab", name: "指弹", kind: .interlude, lines: [
            Line(id: "t1", kind: .tab, tab: TabBlock(measures: [
                arpeggio(5, 0, 2, 2, 1, 0),
                arpeggio(5, 3, 2, 0, 1, 0),
            ])),
        ])
        return Score(meta: ScoreMeta(title: "Demo", tempo: 80, mode: .strumSing), sections: [verse, tab])
    }
}
