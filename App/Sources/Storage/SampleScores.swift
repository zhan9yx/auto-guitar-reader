import Foundation
import AGRCore

/// Built-in demo scores (original, made-up lyrics; no copyrighted material).
enum SampleScores {
    static let strumSingID = UUID(uuidString: "5A4E0C7E-0001-4C1B-9A1E-000000000001")!
    static let fingerstyleID = UUID(uuidString: "5A4E0C7E-0002-4C1B-9A1E-000000000002")!
    static let notationID = UUID(uuidString: "5A4E0C7E-0003-4C1B-9A1E-000000000003")!

    static var all: [Score] { [strumSingSample(), fingerstyleSample(), notationSample()] }

    // MARK: 弹唱示例

    private static func seg(_ chord: String?, _ text: String) -> ChordSegment {
        ChordSegment(chord: chord, text: text)
    }

    private static func lyricsLine(_ segments: [ChordSegment]) -> Line {
        Line(kind: .lyrics, segments: segments)
    }

    static func strumSingSample() -> Score {
        var meta = ScoreMeta(
            title: "小路与晨光（示例）",
            artist: "示例曲谱",
            key: "C",
            capo: 0,
            tempo: 76,
            mode: .strumSing,
            source: ScoreSource(kind: .manual, fileName: nil, importedAt: nil)
        )
        meta.lyricist = "示例原创"

        let intro = ScoreSection(
            id: "intro",
            name: "前奏",
            kind: .intro,
            lines: [
                Line(kind: .chords, segments: [seg("C", ""), seg("G", ""), seg("Am", ""), seg("F", "")])
            ]
        )

        let verse = ScoreSection(
            id: "verse1",
            name: "主歌 1",
            kind: .verse,
            lines: [
                lyricsLine([seg("C", "清晨的风轻轻地"), seg("G", "吹过旧窗台")]),
                lyricsLine([seg("Am", "背起小小的行囊"), seg("F", "走向山那一边")]),
                lyricsLine([seg("C", "路边的野花在笑"), seg("G", "对我说早安")]),
                lyricsLine([seg("F", "每一步都是新的"), seg("G", "方向")]),
                Line(kind: .comment, text: "示例曲谱：歌词为原创占位文字，和弦走向为常见的 C–G–Am–F。")
            ]
        )

        let chorus = ScoreSection(
            id: "chorus1",
            name: "副歌",
            kind: .chorus,
            lines: [
                lyricsLine([seg("F", "啦啦啦 让我们一起"), seg("C", "唱到天亮")]),
                lyricsLine([seg("G", "把故事"), seg("Am", "写进风里"), seg("F", "带向远方")]),
                lyricsLine([seg("F", "Hey, "), seg("C", "walk along the "), seg("G", "morning road")]),
                lyricsLine([seg("Am", "光在前面"), seg("F", "等着我们"), seg("C", "回响")])
            ]
        )

        let outro = ScoreSection(
            id: "outro",
            name: "尾奏",
            kind: .outro,
            lines: [
                Line(kind: .chords, segments: [seg("F", ""), seg("G", ""), seg("C", "")])
            ]
        )

        var score = Score(
            id: strumSingID,
            meta: meta,
            strumPatterns: [StrumPattern.defaultPop, StrumPattern.arpeggio],
            sections: [intro, verse, chorus, outro]
        )
        score.arrangement = ["intro", "verse1", "chorus1", "outro"]
        return score
    }

    // MARK: 指弹示例

    private static func note(_ string: Int, _ fret: Int) -> TabNote {
        TabNote(string: string, fret: fret)
    }

    private static func arpeggioMeasure(chord: String, bass: TabNote, pattern: [TabNote]) -> TabMeasure {
        var events: [TabEvent] = [TabEvent(beat: 0, duration: 0.5, notes: [bass], chord: chord)]
        for (index, tabNote) in pattern.enumerated() {
            events.append(TabEvent(beat: 0.5 * Double(index + 1), duration: 0.5, notes: [tabNote]))
        }
        return TabMeasure(beats: 4, events: events)
    }

    static func fingerstyleSample() -> Score {
        let meta = ScoreMeta(
            title: "琶音练习 C–Am–F–G（示例）",
            artist: "示例曲谱",
            key: "C",
            capo: 0,
            tempo: 72,
            mode: .fingerstyle,
            source: ScoreSource(kind: .manual, fileName: nil, importedAt: nil)
        )

        let cMeasure = arpeggioMeasure(
            chord: "C", bass: note(5, 3),
            pattern: [note(3, 0), note(2, 1), note(1, 0), note(2, 1), note(3, 0), note(2, 1), note(1, 0)]
        )
        let amMeasure = arpeggioMeasure(
            chord: "Am", bass: note(5, 0),
            pattern: [note(3, 2), note(2, 1), note(1, 0), note(2, 1), note(3, 2), note(2, 1), note(1, 0)]
        )
        let fMeasure = arpeggioMeasure(
            chord: "F", bass: note(4, 3),
            pattern: [note(3, 2), note(2, 1), note(1, 0), note(2, 1), note(3, 2), note(2, 1), note(1, 0)]
        )
        let gMeasure = arpeggioMeasure(
            chord: "G", bass: note(6, 3),
            pattern: [note(4, 0), note(3, 0), note(2, 0), note(1, 3), note(2, 0), note(3, 0), note(4, 0)]
        )

        let partA = ScoreSection(
            id: "partA",
            name: "A 段",
            kind: .verse,
            lines: [
                Line(kind: .tab, tab: TabBlock(measures: [cMeasure, amMeasure])),
                Line(kind: .tab, tab: TabBlock(measures: [fMeasure, gMeasure]))
            ]
        )
        let partB = ScoreSection(
            id: "partB",
            name: "B 段",
            kind: .chorus,
            lines: [
                Line(kind: .tab, tab: TabBlock(measures: [fMeasure, gMeasure])),
                Line(kind: .tab, tab: TabBlock(measures: [cMeasure, cMeasure]))
            ]
        )

        var score = Score(id: fingerstyleID, meta: meta, sections: [partA, partB])
        score.arrangement = ["partA", "partB"]
        return score
    }

    // MARK: 弹唱六线谱示例（v2 notation system）

    private static let notationShapes: [String: ChordShape] = [
        "C": ChordShape(frets: [-1, 3, 2, 0, 1, 0]),
        "G": ChordShape(frets: [3, 2, 0, 0, 0, 3]),
        "Am": ChordShape(frets: [-1, 0, 2, 2, 1, 0]),
        "Em": ChordShape(frets: [0, 2, 2, 0, 0, 0]),
        "F": ChordShape(frets: [1, 3, 3, 2, 1, 1])
    ]

    /// 8th-note arpeggio of "×" chord-tone picks: bass string, then 3-2-1-2-3-2-1.
    private static func xArpeggio(bassString: Int) -> [TabEvent] {
        let strings = [bassString, 3, 2, 1, 2, 3, 2, 1]
        return strings.enumerated().map { index, string in
            TabEvent(beat: 0.5 * Double(index), duration: 0.5, notes: [TabNote.chordTone(string: string)])
        }
    }

    /// Down-down-up-up-down-up strum on all strings (beats 0, 1, 1.5, 2.5, 3, 3.5).
    private static func strumEvents() -> [TabEvent] {
        let pattern: [(Double, Double, Stroke)] = [
            (0, 1, .down), (1, 0.5, .down), (1.5, 1, .up), (2.5, 0.5, .up), (3, 0.5, .down), (3.5, 0.5, .up)
        ]
        return pattern.map { TabEvent(beat: $0.0, duration: $0.1, notes: [], stroke: $0.2) }
    }

    /// Six melody notes per measure: 8th 8th quarter 8th 8th quarter. `lyrics` = [verse1, verse2], one syllable each.
    private static func melodyMeasure(_ degrees: [(Int, Int)], v1: [String], v2: [String], tieLast: Bool = false)
        -> [MelodyNote] {
        let beats: [(Double, Double)] = [(0, 0.5), (0.5, 0.5), (1, 1), (2, 0.5), (2.5, 0.5), (3, 1)]
        return beats.enumerated().map { index, slot in
            MelodyNote(beat: slot.0, duration: slot.1, degree: degrees[index].0, octave: degrees[index].1,
                       tieToNext: tieLast && index == beats.count - 1, lyrics: [v1[index], v2[index]])
        }
    }

    static func notationSample() -> Score {
        var meta = ScoreMeta(
            title: "晨光小路（六线谱示例）",
            artist: "示例曲谱",
            key: "C",
            capo: 0,
            tempo: 72,
            mode: .strumSing,
            source: ScoreSource(kind: .manual, fileName: nil, importedAt: nil)
        )
        meta.lyricist = "示例原创"

        func mark(_ name: String) -> [ChordMark] { [ChordMark(name: name, beat: 0, shape: notationShapes[name])] }

        var m1 = NotationMeasure(chords: mark("C"), tab: xArpeggio(bassString: 5),
                                 melody: melodyMeasure([(3, 0), (3, 0), (5, 0), (5, 0), (6, 0), (5, 0)],
                                                       v1: ["清", "风", "轻", "轻", "吹", "过"],
                                                       v2: ["夜", "色", "慢", "慢", "落", "下"]),
                                 leftBarline: .startRepeat)
        m1.marks = ["♩=72"]
        let m2 = NotationMeasure(chords: mark("G"), tab: xArpeggio(bassString: 6),
                                 melody: melodyMeasure([(3, 0), (2, 0), (1, 0), (2, 0), (3, 0), (2, 0)],
                                                       v1: ["窗", "外", "的", "小", "路", "上"],
                                                       v2: ["星", "星", "亮", "在", "山", "岗"]))
        let m3 = NotationMeasure(chords: mark("Am"), tab: xArpeggio(bassString: 5),
                                 melody: melodyMeasure([(6, -1), (1, 0), (3, 0), (3, 0), (2, 0), (3, 0)],
                                                       v1: ["我", "背", "着", "旧", "吉", "他"],
                                                       v2: ["你", "唱", "着", "旧", "歌", "谣"]),
                                 volta: [])
        var m4 = NotationMeasure(chords: mark("Em"), tab: xArpeggio(bassString: 6),
                                 melody: melodyMeasure([(5, 0), (3, 0), (2, 0), (3, 0), (2, 0), (1, 0)],
                                                       v1: ["慢", "慢", "走", "向", "前", "方"],
                                                       v2: ["轻", "轻", "走", "进", "梦", "乡"]),
                                 rightBarline: .endRepeat, volta: [1])
        m4.melody[5].lyrics = ["方", "乡"]
        let m5 = NotationMeasure(chords: mark("F"), tab: xArpeggio(bassString: 4),
                                 melody: melodyMeasure([(6, 0), (6, 0), (1, 1), (7, 0), (6, 0), (5, 0)],
                                                       v1: ["晨", "光", "落", "在", "肩", "头"],
                                                       v2: ["微", "风", "吹", "在", "脸", "庞"]),
                                 volta: [2])
        let m6 = NotationMeasure(chords: mark("C"), tab: xArpeggio(bassString: 5),
                                 melody: melodyMeasure([(3, 0), (5, 0), (5, 0), (3, 0), (2, 0), (3, 0)],
                                                       v1: ["照", "亮", "每", "个", "梦", "想"],
                                                       v2: ["温", "暖", "每", "个", "晚", "上"],
                                                       tieLast: true))
        // Strum measure: rhythm strums with a sung phrase on a held tone.
        let m7 = NotationMeasure(
            chords: [ChordMark(name: "G", beat: 0, shape: notationShapes["G"]),
                     ChordMark(name: "Am", beat: 2, shape: notationShapes["Am"])],
            tab: strumEvents(),
            melody: [MelodyNote(beat: 0, duration: 1, degree: 3, lyrics: ["啦", "哦"]),
                     MelodyNote(beat: 1, duration: 1, degree: 5, lyrics: ["啦", "哦"]),
                     MelodyNote(beat: 2, duration: 1, degree: 6, lyrics: ["啦", "哦"]),
                     MelodyNote(beat: 3, duration: 1, degree: 5, lyrics: ["啦", "哦"])])
        let m8 = NotationMeasure(
            chords: mark("C"),
            tab: [TabEvent(beat: 0, duration: 3, notes: [TabNote.chordTone(string: 5), TabNote.chordTone(string: 3),
                                                       TabNote.chordTone(string: 2), TabNote.chordTone(string: 1)],
                           stroke: .down)],
            melody: [MelodyNote(beat: 0, duration: 3, degree: 1, lyrics: ["亮", "乡"]),
                     MelodyNote(beat: 3, duration: 1, degree: 0, lyrics: ["", ""])],
            rightBarline: .final)

        let line1 = Line(id: "sys1", kind: .system, system: NotationSystem(measures: [m1, m2, m3, m4]))
        let line2 = Line(id: "sys2", kind: .system, system: NotationSystem(measures: [m5, m6, m7, m8]))
        let section = ScoreSection(id: "main", name: "主歌", kind: .verse, lines: [line1, line2])
        var defs = notationShapes
        defs["Em"] = notationShapes["Em"]
        return Score(id: notationID, meta: meta, chordDefinitions: defs, sections: [section])
    }
}
