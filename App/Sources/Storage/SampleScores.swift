import Foundation
import AGRCore

/// Built-in demo scores (original, made-up lyrics; no copyrighted material).
enum SampleScores {
    static let strumSingID = UUID(uuidString: "5A4E0C7E-0001-4C1B-9A1E-000000000001")!
    static let fingerstyleID = UUID(uuidString: "5A4E0C7E-0002-4C1B-9A1E-000000000002")!

    static var all: [Score] { [strumSingSample(), fingerstyleSample()] }

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
}
