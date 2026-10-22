import XCTest
@testable import AGRCore

/// A small v2 弹唱 score: 4/4, key C, 4 measures in one system (m3 has voltas via builder options), two verses.
enum V2 {
    static func ct(_ strings: [Int], _ beat: Double, _ dur: Double = 0.5, stroke: Stroke? = nil) -> TabEvent {
        TabEvent(beat: beat, duration: dur, notes: strings.map { TabNote.chordTone(string: $0) }, stroke: stroke)
    }

    static func measure(chord: String, shape: String? = nil, syllables: [[String]], tab: [TabEvent]? = nil,
                        left: BarlineKind = .single, right: BarlineKind = .single, volta: [Int] = []) -> NotationMeasure {
        var melody: [MelodyNote] = []
        for (i, s) in syllables.enumerated() {
            melody.append(MelodyNote(beat: Double(i), duration: 1, degree: (i % 7) + 1, octave: i == 2 ? 1 : 0, lyrics: s))
        }
        let tabEvents = tab ?? [ct([5, 3, 2, 1], 0, 1), ct([4], 1, 1), ct([3], 2, 1), ct([2], 3, 1)]
        return NotationMeasure(chords: [ChordMark(name: chord, beat: 0, shape: shape.flatMap(Voicing.init).map { ChordShape(frets: $0.frets) })],
                               tab: tabEvents, melody: melody, leftBarline: left, rightBarline: right, volta: volta)
    }

    static func score(mode: PlayMode = .strumSing, measures: [NotationMeasure]? = nil) -> Score {
        let ms = measures ?? [
            measure(chord: "C", shape: "x32010", syllables: [["小", "一"], ["星", "二"], ["星", "三"], ["你", "四"]], left: .startRepeat),
            measure(chord: "G7(3)", syllables: [["在", "五"], ["哪", "六"], ["里", "七"], ["呀", "八"]]),
            measure(chord: "Am", syllables: [["我", "甲"], ["在", "乙"], ["这", "丙"], ["里", "丁"]], right: .endRepeat),
            measure(chord: "F", syllables: [["好", "子"], ["想", "丑"], ["你", "寅"], ["啊", "卯"]], right: .final),
        ]
        var s = Score(meta: ScoreMeta(title: "小星云", artist: "测试", key: "C", tempo: 100, mode: mode),
                      sections: [Section(id: "s1", name: "主歌", kind: .verse, lines: [Line.system(NotationSystem(measures: ms))])])
        s.meta.timeSignature = TimeSignature(beats: 4, unit: 4)
        return s
    }
}
