import Foundation

// MARK: - Built-in evaluation songs (original, made-up lyrics)
//
// Strum/sing songs are written in ChordPro and expanded with a play order that repeats progressions (the same
// chord loop appears in verses AND choruses, which is exactly what makes score following ambiguous).
// Fingerstyle pieces are built from picking patterns over a chord loop.

public enum FollowEvalSongs {
    public struct Song {
        public var name: String
        public var score: Score
        public init(name: String, score: Score) { self.name = name; self.score = score }
    }

    // MARK: strum + sing

    /// C major, 92 bpm. Verse and chorus share the C-G-Am-F loop.
    static let summerNight = """
    {title: 夏夜的风}
    {key: C}
    {tempo: 92}
    {start_of_part: 前奏}
    [C] [G] [Am] [F]
    {end_of_part}
    {start_of_verse: 主歌1}
    [C]夜色轻轻[G]落在窗台[Am]你的笑声[F]还在耳边
    [C]路灯慢慢[G]点亮回忆[Am]我却不敢[F]回头看
    {end_of_verse}
    {start_of_part: 导歌}
    [F]风吹过[G]海岸线[Em]带走了[Am]所有思念
    {end_of_part}
    {start_of_chorus}
    [C]夏夜的风[G]吹向远方[Am]吹不散[F]我的梦想
    [F]就让我[G]再唱一遍[C]你是我的[Am]永远
    {end_of_chorus}
    {start_of_verse: 主歌2}
    [C]清晨阳光[G]洒在肩膀[Am]旧的吉他[F]依然作响
    [C]我把故事[G]写进歌里[Am]留给下一个[F]夏天
    {end_of_verse}
    {start_of_part: 尾奏}
    [C] [G] [Am] [F]
    {end_of_part}
    """
    // sections: s0 intro, s1 verse1, s2 pre, s3 chorus, s4 verse2, s5 outro
    static let summerNightOrder = [0, 1, 2, 3, 4, 2, 3, 3, 5]

    /// G (capo 2), 76 bpm. G-D-Em-C in verse, C-G-D-Em in chorus, slash chords and sus chords.
    static let oldStation = """
    {title: 旧车站}
    {key: A}
    {capo: 2}
    {tempo: 76}
    {start_of_part: 前奏}
    [G] [D/F#] [Em7] [Cadd9]
    {end_of_part}
    {start_of_verse: 主歌1}
    [G]站台上的[D]钟早已停摆[Em]我拖着行李[C]不知去哪
    [G]那班列车[D]载走了春天[Em]留下我一个人[C]站在原地
    {end_of_verse}
    {start_of_part: 导歌}
    [Am]雨落在[D]铁轨上[Am]一滴一滴[D]敲着时光
    {end_of_part}
    {start_of_chorus}
    [C]回不去的[G]是那年夏天[D]走不完的[Em]是这条长街
    [C]如果还能[G]再见一面[D]我会说一句[Gsus4]对不起[G]
    {end_of_chorus}
    {start_of_verse: 主歌2}
    [G]月台上的[D]灯忽明忽暗[Em]有人在远处[C]轻轻呼唤
    [G]我回头望[D]只有风走过[Em]旧车票还在[C]口袋里面
    {end_of_verse}
    {start_of_part: 尾奏}
    [G] [D/F#] [Em7] [Cadd9] [G]
    {end_of_part}
    """
    // s0 intro, s1 verse1, s2 pre, s3 chorus, s4 verse2, s5 outro
    static let oldStationOrder = [0, 1, 2, 3, 4, 2, 3, 3, 5]

    /// A minor, 108 bpm. Am-F-C-G loop in verse and chorus (different order in the chorus's second line).
    static let rainyStreet = """
    {title: 雨后的街}
    {key: Am}
    {tempo: 108}
    {start_of_part: 前奏}
    [Am] [F] [C] [G]
    {end_of_part}
    {start_of_verse: 主歌1}
    [Am]雨后的街[F]空无一人[C]路灯下的[G]影子很长
    [Am]我数着步子[F]走过转角[C]还是没有[G]你的消息
    {end_of_verse}
    {start_of_part: 导歌}
    [Dm]也许明天[Am]会放晴[Dm]也许明天[E7]还是阴天
    {end_of_part}
    {start_of_chorus}
    [F]我不想[G]说再见[Am]也不想[Em]回到从前
    [F]让雨水[G]冲淡思念[C]让心跳[G]慢慢平静
    {end_of_chorus}
    {start_of_verse: 主歌2}
    [Am]咖啡凉了[F]故事还热[C]窗外的人[G]来来往往
    [Am]我写下名字[F]又轻轻擦去[C]像这场雨[G]没有方向
    {end_of_verse}
    {start_of_part: 尾奏}
    [Am] [F] [C] [G] [Am]
    {end_of_part}
    """
    static let rainyStreetOrder = [0, 1, 2, 3, 4, 2, 3, 3, 5]

    /// Parses ChordPro, assigns beats (short fragments = 2 beats, others = one 4/4 measure) and sets the play order.
    static func build(_ cho: String, order: [Int], mode: PlayMode = .strumSing) -> Score {
        var score = (try? ChordProParser.parse(cho)) ?? Score()
        for si in score.sections.indices {
            for li in score.sections[si].lines.indices where score.sections[si].lines[li].kind == .lyrics {
                for gi in score.sections[si].lines[li].segments.indices {
                    let seg = score.sections[si].lines[li].segments[gi]
                    guard seg.chord != nil else { continue }
                    let chars = seg.text.filter { !$0.isWhitespace }.count
                    score.sections[si].lines[li].segments[gi].beats = chars <= 3 ? 2 : 4
                }
            }
        }
        score.meta.mode = mode
        score.arrangement = order.compactMap { score.sections.indices.contains($0) ? score.sections[$0].id : nil }
        return score
    }

    public static var strumSongs: [Song] {
        [Song(name: "夏夜的风", score: build(summerNight, order: summerNightOrder)),
         Song(name: "旧车站", score: build(oldStation, order: oldStationOrder)),
         Song(name: "雨后的街", score: build(rainyStreet, order: rainyStreetOrder))]
    }

    // MARK: fingerstyle

    private static func n(_ string: Int, _ fret: Int) -> TabNote { TabNote(string: string, fret: fret) }

    /// One 4/4 measure of eighth-note arpeggio over a chord: bass / middle strings / melody on string 1 and 2.
    /// `bass`: (string, fret) of the two bass notes; `mid`: [(string, fret)] x3; `melody`: frets on the high E string
    /// for beats 1.5 and 3.5 plus an optional note at beat 0 together with the bass.
    private static func arpMeasure(bass: [(Int, Int)], mid: [(Int, Int)], melody: [Int], top: Int?) -> TabMeasure {
        var ev: [TabEvent] = []
        var b0 = [n(bass[0].0, bass[0].1)]
        if let top { b0.append(n(1, top)) }
        ev.append(TabEvent(beat: 0, duration: 1, notes: b0))
        ev.append(TabEvent(beat: 0.5, duration: 0.5, notes: [n(mid[0].0, mid[0].1)]))
        ev.append(TabEvent(beat: 1, duration: 0.5, notes: [n(mid[1].0, mid[1].1)]))
        ev.append(TabEvent(beat: 1.5, duration: 0.5, notes: [n(1, melody[0])]))
        ev.append(TabEvent(beat: 2, duration: 1, notes: [n(bass[1].0, bass[1].1)]))
        ev.append(TabEvent(beat: 2.5, duration: 0.5, notes: [n(mid[2].0, mid[2].1)]))
        ev.append(TabEvent(beat: 3, duration: 0.5, notes: [n(mid[1].0, mid[1].1)]))
        ev.append(TabEvent(beat: 3.5, duration: 0.5, notes: [n(1, melody[1])]))
        return TabMeasure(beats: 4, events: ev)
    }

    private struct ArpChord {
        var bass: [(Int, Int)]
        var mid: [(Int, Int)]
    }
    private static let cMaj = ArpChord(bass: [(5, 3), (4, 2)], mid: [(3, 0), (2, 1), (3, 0)])
    private static let aMin = ArpChord(bass: [(5, 0), (4, 2)], mid: [(3, 2), (2, 1), (3, 2)])
    private static let fMaj = ArpChord(bass: [(4, 3), (3, 2)], mid: [(3, 2), (2, 1), (3, 2)])
    private static let gMaj = ArpChord(bass: [(6, 3), (4, 0)], mid: [(3, 0), (2, 0), (3, 0)])
    private static let eMin = ArpChord(bass: [(6, 0), (5, 2)], mid: [(4, 2), (3, 0), (4, 2)])
    private static let dMaj = ArpChord(bass: [(4, 0), (3, 2)], mid: [(2, 3), (3, 2), (2, 3)])

    /// 16 measures, 128 events: C - Am - F - G loop with a varying melody (low-register picking pattern).
    public static func fingerstylePieceA() -> Score {
        let prog: [ArpChord] = [cMaj, aMin, fMaj, gMaj]
        let melodies: [[Int]] = [[0, 1], [0, 3], [3, 1], [3, 0], [1, 0], [3, 0], [1, 3], [0, 3]]
        let tops: [Int?] = [0, nil, 1, nil, 0, nil, 3, nil]
        var lines: [Line] = []
        for l in 0..<4 {
            var ms: [TabMeasure] = []
            for k in 0..<4 {
                let mi = l * 4 + k
                let c = prog[mi % 4]
                ms.append(arpMeasure(bass: c.bass, mid: c.mid, melody: melodies[(mi * 3) % melodies.count], top: tops[mi % tops.count]))
            }
            lines.append(Line(id: "a\(l)", kind: .tab, tab: TabBlock(measures: ms)))
        }
        let sec = Section(id: "tabA", name: "Arpeggio A", kind: .other, lines: lines)
        return Score(meta: ScoreMeta(title: "Arpeggio A", tempo: 84, mode: .fingerstyle), sections: [sec])
    }

    /// 12 measures: Em - D - C - G with a different feel (quarter-note bass + syncopated melody / double stops).
    public static func fingerstylePieceB() -> Score {
        func m(_ events: [(Double, Double, [(Int, Int)])]) -> TabMeasure {
            TabMeasure(beats: 4, events: events.map { TabEvent(beat: $0.0, duration: $0.1, notes: $0.2.map { n($0.0, $0.1) }) })
        }
        let em = m([(0, 1, [(6, 0), (2, 0)]), (1, 0.5, [(4, 2)]), (1.5, 0.5, [(3, 0)]), (2, 1, [(5, 2), (1, 3)]), (3, 0.5, [(2, 0)]), (3.5, 0.5, [(3, 0)])])
        let d = m([(0, 1, [(4, 0), (2, 3)]), (1, 0.5, [(3, 2)]), (1.5, 0.5, [(2, 3)]), (2, 1, [(4, 0), (1, 2)]), (3, 0.5, [(3, 2)]), (3.5, 0.5, [(2, 3)])])
        let c = m([(0, 1, [(5, 3), (2, 1)]), (1, 0.5, [(4, 2)]), (1.5, 0.5, [(3, 0)]), (2, 1, [(5, 3), (1, 0)]), (3, 0.5, [(3, 0)]), (3.5, 0.5, [(4, 2)])])
        let g = m([(0, 1, [(6, 3), (2, 0)]), (1, 0.5, [(5, 2)]), (1.5, 0.5, [(4, 0)]), (2, 1, [(6, 3), (1, 3)]), (3, 0.5, [(4, 0)]), (3.5, 0.5, [(3, 0)])])
        let loop = [em, d, c, g]
        var lines: [Line] = []
        for l in 0..<3 {
            lines.append(Line(id: "b\(l)", kind: .tab, tab: TabBlock(measures: loop)))
        }
        let sec = Section(id: "tabB", name: "Arpeggio B", kind: .other, lines: lines)
        return Score(meta: ScoreMeta(title: "Arpeggio B", tempo: 76, mode: .fingerstyle), sections: [sec])
    }

    public static var fingerstylePieces: [Song] {
        [Song(name: "Arpeggio A", score: fingerstylePieceA()), Song(name: "Arpeggio B", score: fingerstylePieceB())]
    }

    public static func songs(for mode: FollowMode) -> [Song] {
        mode == .strumSing ? strumSongs : fingerstylePieces
    }
}
