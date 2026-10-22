import Foundation

// MARK: - OMR scoring metric
//
// Compares a predicted AGR v2 score against a ground truth. Only `.system` lines are scored (measure content);
// header fields come from `Score.meta`. Measures of GT and prediction are aligned by sequence alignment
// (Needleman-Wunsch over a per-measure similarity), so a missing / extra measure only costs that measure.
//
// Per-category counts (tp / fp / fn):
//  * header      : non-default fields (title, artist, composer, lyricist, arranger, key, capo, tempo, time, tuning,
//                  mode) as tokens; a wrong value is one fn + one fp.
//  * chords      : chord marks matched by normalized name (`ChordNameNormalizer.key`) + beat (±1/16 beat) in aligned measures.
//  * chordShapes : printed chord diagrams (six frets) of matched chord marks; missing / different = fn (+ fp if different).
//  * tab         : tab NOTES (string + chord-tone/fret + technique) of tab events matched by beat (±1/16).
//  * tabEvents   : informational, event level (beat matched and note sets identical).
//  * strokes     : strum direction of matched tab events.
//  * rhythm      : durations (±1/16 beat) of matched tab events and matched melody notes, plus measure lengths.
//  * melody      : melody notes matched by beat: degree, octave, accidental (rests: degree only) and tie; the
//                  duration of melody notes is scored in `rhythm`.
//  * lyrics      : characters per verse (whitespace ignored) via edit distance per aligned measure; counts are derived
//                  from the edit script, `accuracy = 1 - CER`.
//  * barlines    : non-default barlines, voltas and marks as tokens.
//  * measures    : alignment result (tp = aligned pairs, fn = missing, fp = extra).
//
// Overall = weighted mean of group accuracies (groups without any item in GT and prediction are skipped and the
// weights renormalized): tab 30% (tab + strokes), melody 20%, lyrics 20%, chords 15% (chords + shapes),
// rhythm 5%, barlines 5% (barlines + measures), header 5%.

public struct CategoryScore: Codable, Hashable, Sendable {
    public var tp: Int = 0
    public var fp: Int = 0
    public var fn: Int = 0
    public init(tp: Int = 0, fp: Int = 0, fn: Int = 0) { self.tp = tp; self.fp = fp; self.fn = fn }

    /// Number of items in GT / prediction.
    public var groundTruthCount: Int { tp + fn }
    public var predictedCount: Int { tp + fp }
    public var isEmpty: Bool { tp + fp + fn == 0 }
    public var precision: Double { tp + fp == 0 ? (fn == 0 ? 1 : 0) : Double(tp) / Double(tp + fp) }
    public var recall: Double { tp + fn == 0 ? (fp == 0 ? 1 : 0) : Double(tp) / Double(tp + fn) }
    public var f1: Double { isEmpty ? 1 : 2 * Double(tp) / Double(2 * tp + fp + fn) }
    /// tp / (tp + fp + fn); 1 when the category is empty.
    public var accuracy: Double { isEmpty ? 1 : Double(tp) / Double(tp + fp + fn) }

    mutating func add(_ o: CategoryScore) { tp += o.tp; fp += o.fp; fn += o.fn }

    enum CodingKeys: String, CodingKey { case tp, fp, fn, precision, recall, f1, accuracy }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tp = try c.decode(Int.self, forKey: .tp); fp = try c.decode(Int.self, forKey: .fp); fn = try c.decode(Int.self, forKey: .fn)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(tp, forKey: .tp); try c.encode(fp, forKey: .fp); try c.encode(fn, forKey: .fn)
        try c.encode(precision, forKey: .precision); try c.encode(recall, forKey: .recall)
        try c.encode(f1, forKey: .f1); try c.encode(accuracy, forKey: .accuracy)
    }
}

public struct LyricsScore: Codable, Hashable, Sendable {
    public var counts = CategoryScore()
    public var groundTruthChars = 0
    public var predictedChars = 0
    public var editDistance = 0
    /// Character error rate = editDistance / max(groundTruthChars, 1).
    public var cer: Double { Double(editDistance) / Double(max(groundTruthChars, 1)) }
    /// 1 - CER, clamped to 0...1 (1 when there are no lyrics at all).
    public var accuracy: Double { groundTruthChars == 0 && predictedChars == 0 ? 1 : min(max(1 - cer, 0), 1) }
    public init() {}
    enum CodingKeys: String, CodingKey { case counts, groundTruthChars, predictedChars, editDistance, cer, accuracy }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        counts = try c.decode(CategoryScore.self, forKey: .counts)
        groundTruthChars = try c.decode(Int.self, forKey: .groundTruthChars)
        predictedChars = try c.decode(Int.self, forKey: .predictedChars)
        editDistance = try c.decode(Int.self, forKey: .editDistance)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(counts, forKey: .counts); try c.encode(groundTruthChars, forKey: .groundTruthChars)
        try c.encode(predictedChars, forKey: .predictedChars); try c.encode(editDistance, forKey: .editDistance)
        try c.encode(cer, forKey: .cer); try c.encode(accuracy, forKey: .accuracy)
    }
}

public struct OMRGroupScore: Codable, Hashable, Sendable {
    public var weight: Double
    public var accuracy: Double
    /// False when the group had nothing to score (skipped in the overall mean).
    public var included: Bool
}

public struct OMRMeasureAlignment: Codable, Hashable, Sendable {
    public var groundTruthMeasures = 0
    public var predictedMeasures = 0
    /// (gt index, predicted index) pairs over the flattened measure sequences.
    public var pairs: [[Int]] = []
    public var missing: [Int] = []
    public var extra: [Int] = []
}

public struct OMRScoreReport: Codable, Hashable, Sendable {
    public var header = CategoryScore()
    public var chords = CategoryScore()
    public var chordShapes = CategoryScore()
    public var tab = CategoryScore()
    public var tabEvents = CategoryScore()
    public var strokes = CategoryScore()
    public var rhythm = CategoryScore()
    public var melody = CategoryScore()
    public var lyrics = LyricsScore()
    public var barlines = CategoryScore()
    public var measures = CategoryScore()
    public var alignment = OMRMeasureAlignment()
    /// Weighted groups (see file header): keys tab, melody, lyrics, chords, rhythm, barlines, header.
    public var groups: [String: OMRGroupScore] = [:]
    /// Weighted overall accuracy 0...1.
    public var overall: Double = 1
    public init() {}

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Human-readable table.
    public var summary: String {
        func row(_ name: String, _ c: CategoryScore) -> String {
            name.padding(toLength: 12, withPad: " ", startingAt: 0)
                + String(format: " tp %4d fp %4d fn %4d  acc %6.2f%%  f1 %6.2f%%", c.tp, c.fp, c.fn, c.accuracy * 100, c.f1 * 100)
        }
        var l = [row("header", header), row("chords", chords), row("chordShapes", chordShapes), row("tab", tab),
                 row("tabEvents", tabEvents), row("strokes", strokes), row("rhythm", rhythm), row("melody", melody),
                 row("barlines", barlines), row("measures", measures),
                 String(format: "lyrics       chars gt %d pred %d  edit %d  CER %.2f%%  acc %.2f%%", lyrics.groundTruthChars,
                        lyrics.predictedChars, lyrics.editDistance, lyrics.cer * 100, lyrics.accuracy * 100)]
        for k in ["tab", "melody", "lyrics", "chords", "rhythm", "barlines", "header"] {
            if let g = groups[k] {
                l.append(String(format: "  group %-8@ w %.2f acc %6.2f%%%@", k as NSString, g.weight, g.accuracy * 100, g.included ? "" : " (skipped)"))
            }
        }
        l.append(String(format: "OVERALL      %.2f%%", overall * 100))
        return l.joined(separator: "\n")
    }
}

public enum OMRScorer {
    public static let weights: [String: Double] = [
        "tab": 0.30, "melody": 0.20, "lyrics": 0.20, "chords": 0.15, "rhythm": 0.05, "barlines": 0.05, "header": 0.05,
    ]
    /// Beat tolerance for matching events (1/16 beat).
    public static let beatTolerance = 1.0 / 16 + 1e-9

    public static func compare(groundTruth gt: Score, predicted pred: Score) -> OMRScoreReport {
        var r = OMRScoreReport()
        r.header = compareHeader(gt.meta, pred.meta)

        let g = flatten(gt), p = flatten(pred)
        let al = align(g.map(\.m), p.map(\.m), gtBeats: g.map(\.defaultBeats), predBeats: p.map(\.defaultBeats))
        r.alignment = OMRMeasureAlignment(groundTruthMeasures: g.count, predictedMeasures: p.count,
                                          pairs: al.pairs.map { [$0.0, $0.1] }, missing: al.missing, extra: al.extra)
        r.measures = CategoryScore(tp: al.pairs.count, fp: al.extra.count, fn: al.missing.count)

        var lyricOps = (match: 0, sub: 0, del: 0, ins: 0)
        for (gi, pi) in al.pairs {
            let a = g[gi], b = p[pi]
            scoreMeasure(a.m, b.m, a.defaultBeats, b.defaultBeats, into: &r)
            let d = lyricEdit(a.m, b.m)
            lyricOps.match += d.match; lyricOps.sub += d.sub; lyricOps.del += d.del; lyricOps.ins += d.ins
        }
        for gi in al.missing {
            scoreOnly(g[gi].m, asGroundTruth: true, into: &r)
            lyricOps.del += lyricChars(g[gi].m).values.reduce(0) { $0 + $1.count }
        }
        for pi in al.extra {
            scoreOnly(p[pi].m, asGroundTruth: false, into: &r)
            lyricOps.ins += lyricChars(p[pi].m).values.reduce(0) { $0 + $1.count }
        }
        r.lyrics.counts = CategoryScore(tp: lyricOps.match, fp: lyricOps.sub + lyricOps.ins, fn: lyricOps.sub + lyricOps.del)
        r.lyrics.groundTruthChars = lyricOps.match + lyricOps.sub + lyricOps.del
        r.lyrics.predictedChars = lyricOps.match + lyricOps.sub + lyricOps.ins
        r.lyrics.editDistance = lyricOps.sub + lyricOps.del + lyricOps.ins

        finish(&r)
        return r
    }

    private static func finish(_ r: inout OMRScoreReport) {
        func merged(_ a: CategoryScore, _ b: CategoryScore) -> CategoryScore { var c = a; c.add(b); return c }
        let lyricsEmpty = r.lyrics.groundTruthChars == 0 && r.lyrics.predictedChars == 0
        let parts: [(String, CategoryScore, Double?)] = [
            ("tab", merged(r.tab, r.strokes), nil),
            ("melody", r.melody, nil),
            ("lyrics", r.lyrics.counts, lyricsEmpty ? nil : r.lyrics.accuracy),
            ("chords", merged(r.chords, r.chordShapes), nil),
            ("rhythm", r.rhythm, nil),
            ("barlines", merged(r.barlines, r.measures), nil),
            ("header", r.header, nil),
        ]
        var wsum = 0.0, acc = 0.0
        for (name, c, override) in parts {
            let w = weights[name] ?? 0
            let included = override != nil || !c.isEmpty
            let a = override ?? c.accuracy
            r.groups[name] = OMRGroupScore(weight: w, accuracy: included ? a : 1, included: included)
            if included { wsum += w; acc += w * a }
        }
        r.overall = wsum > 0 ? acc / wsum : 1
    }

    // MARK: Header

    private static func compareHeader(_ a: ScoreMeta, _ b: ScoreMeta) -> CategoryScore {
        func tokens(_ m: ScoreMeta) -> [String] {
            func norm(_ s: String?) -> String? {
                guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return ChordNameNormalizer.foldWidth(s).lowercased()
            }
            var t: [String] = []
            for (k, v) in [("title", m.title), ("artist", m.artist ?? ""), ("composer", m.composer ?? ""),
                           ("lyricist", m.lyricist ?? ""), ("arranger", m.arranger ?? "")] {
                if let n = norm(v) { t.append("\(k)=\(n)") }
            }
            if let k = norm(m.key) { t.append("key=\(k.replacingOccurrences(of: "1=", with: ""))") }
            if m.capo != 0 { t.append("capo=\(m.capo)") }
            if m.tempo != 80 { t.append("tempo=\(Int(m.tempo.rounded()))") }
            if m.timeSignature != TimeSignature() { t.append("time=\(m.timeSignature.beats)/\(m.timeSignature.unit)") }
            if m.tuning != ScoreMeta.standardTuning { t.append("tuning=\(m.tuning)") }
            if m.mode != .strumSing { t.append("mode=\(m.mode.rawValue)") }
            return t
        }
        return multiset(tokens(a), tokens(b))
    }

    private static func multiset(_ gt: [String], _ pred: [String]) -> CategoryScore {
        var counts: [String: Int] = [:]
        for t in pred { counts[t, default: 0] += 1 }
        var c = CategoryScore()
        for t in gt {
            if let n = counts[t], n > 0 { counts[t] = n - 1; c.tp += 1 } else { c.fn += 1 }
        }
        c.fp = counts.values.reduce(0, +)
        return c
    }

    // MARK: Flatten / alignment

    struct FlatMeasure { var m: NotationMeasure; var defaultBeats: Double }

    static func flatten(_ s: Score) -> [FlatMeasure] {
        var out: [FlatMeasure] = []
        let d = Double(max(s.meta.timeSignature.beats, 1))
        for sec in s.sections { for l in sec.lines where l.kind == .system {
            for m in l.system?.measures ?? [] { out.append(FlatMeasure(m: m, defaultBeats: d)) }
        } }
        return out
    }

    static func q(_ beat: Double, _ per: Double = 4) -> Int { Int((beat * per).rounded()) }

    static func signature(_ m: NotationMeasure) -> [String] {
        var t: [String] = []
        for c in m.chords { t.append("c|\(ChordNameNormalizer.key(c.name))|\(q(c.beat))") }
        for e in m.tab { for n in e.notes { t.append("t|\(q(e.beat))|\(n.string)|\(n.chordTone ? "x" : String(n.fret))") } }
        for n in m.melody { t.append("m|\(q(n.beat))|\(n.degree)|\(n.octave)|\(n.accidental)") }
        for (v, chars) in lyricChars(m) { for ch in chars { t.append("l|\(v)|\(ch)") } }
        return t
    }

    static func similarity(_ a: [String], _ b: [String]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        var counts: [String: Int] = [:]
        for t in b { counts[t, default: 0] += 1 }
        var common = 0
        for t in a { if let n = counts[t], n > 0 { counts[t] = n - 1; common += 1 } }
        return 2 * Double(common) / Double(a.count + b.count)
    }

    static func align(_ g: [NotationMeasure], _ p: [NotationMeasure], gtBeats: [Double], predBeats: [Double])
        -> (pairs: [(Int, Int)], missing: [Int], extra: [Int]) {
        let n = g.count, m = p.count
        if n == 0 || m == 0 { return ([], Array(0..<n), Array(0..<m)) }
        let gs = g.map(signature), ps = p.map(signature)
        let gap = -0.3, offset = -0.2
        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var from = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)  // 0 diag, 1 up (gt gap), 2 left
        for i in 1...n { dp[i][0] = Double(i) * gap; from[i][0] = 1 }
        for j in 1...m { dp[0][j] = Double(j) * gap; from[0][j] = 2 }
        for i in 1...n { for j in 1...m {
            let diag = dp[i - 1][j - 1] + similarity(gs[i - 1], ps[j - 1]) + offset
            let up = dp[i - 1][j] + gap, left = dp[i][j - 1] + gap
            if diag >= up && diag >= left { dp[i][j] = diag; from[i][j] = 0 }
            else if up >= left { dp[i][j] = up; from[i][j] = 1 }
            else { dp[i][j] = left; from[i][j] = 2 }
        } }
        var pairs: [(Int, Int)] = [], missing: [Int] = [], extra: [Int] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            switch from[i][j] {
            case 0: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            case 1: missing.append(i - 1); i -= 1
            default: extra.append(j - 1); j -= 1
            }
        }
        return (pairs.reversed(), missing.reversed(), extra.reversed())
    }

    // MARK: Per-measure scoring

    /// Greedy one-to-one matching by |beat difference| ≤ tolerance, optionally restricted by `ok`.
    static func matchByBeat(_ g: [Double], _ p: [Double], ok: (Int, Int) -> Bool = { _, _ in true }) -> [(Int, Int)] {
        var cands: [(d: Double, i: Int, j: Int)] = []
        for i in g.indices { for j in p.indices {
            let d = abs(g[i] - p[j])
            if d <= beatTolerance, ok(i, j) { cands.append((d, i, j)) }
        } }
        cands.sort { $0.d != $1.d ? $0.d < $1.d : ($0.i != $1.i ? $0.i < $1.i : $0.j < $1.j) }
        var usedG = Set<Int>(), usedP = Set<Int>(), out: [(Int, Int)] = []
        for c in cands where !usedG.contains(c.i) && !usedP.contains(c.j) {
            usedG.insert(c.i); usedP.insert(c.j); out.append((c.i, c.j))
        }
        return out
    }

    static func noteToken(_ n: TabNote) -> String {
        "\(n.string)|\(n.chordTone ? "x" : String(n.fret))|\(n.technique?.rawValue ?? "")"
    }

    static func barToken(_ m: NotationMeasure) -> [String] {
        var t: [String] = []
        if m.leftBarline != .single { t.append("L:\(m.leftBarline.rawValue)") }
        if m.rightBarline != .single { t.append("R:\(m.rightBarline.rawValue)") }
        for v in m.volta.sorted() { t.append("V:\(v)") }
        for mk in m.marks { t.append("M:\(mk.lowercased().trimmingCharacters(in: .whitespaces))") }
        return t
    }

    static func scoreMeasure(_ a: NotationMeasure, _ b: NotationMeasure, _ da: Double, _ db: Double, into r: inout OMRScoreReport) {
        // Chords + shapes.
        let cm = matchByBeat(a.chords.map(\.beat), b.chords.map(\.beat)) {
            ChordNameNormalizer.key(a.chords[$0].name) == ChordNameNormalizer.key(b.chords[$1].name)
        }
        r.chords.tp += cm.count
        r.chords.fn += a.chords.count - cm.count
        r.chords.fp += b.chords.count - cm.count
        let matchedG = Set(cm.map(\.0)), matchedP = Set(cm.map(\.1))
        for (i, j) in cm {
            let sg = a.chords[i].shape?.frets, sp = b.chords[j].shape?.frets
            switch (sg, sp) {
            case let (x?, y?): if x == y { r.chordShapes.tp += 1 } else { r.chordShapes.fn += 1; r.chordShapes.fp += 1 }
            case (_?, nil): r.chordShapes.fn += 1
            case (nil, _?): r.chordShapes.fp += 1
            default: break
            }
        }
        for (i, c) in a.chords.enumerated() where !matchedG.contains(i) && c.shape != nil { r.chordShapes.fn += 1 }
        for (j, c) in b.chords.enumerated() where !matchedP.contains(j) && c.shape != nil { r.chordShapes.fp += 1 }

        // Tab events.
        let tm = matchByBeat(a.tab.map(\.beat), b.tab.map(\.beat))
        let tg = Set(tm.map(\.0)), tp = Set(tm.map(\.1))
        for (i, j) in tm {
            let ea = a.tab[i], eb = b.tab[j]
            let n = multiset(ea.notes.map(noteToken), eb.notes.map(noteToken))
            r.tab.add(n)
            r.tabEvents.add(n.fp == 0 && n.fn == 0 ? CategoryScore(tp: 1) : CategoryScore(fp: 1, fn: 1))
            switch (ea.stroke, eb.stroke) {
            case let (x?, y?): if x == y { r.strokes.tp += 1 } else { r.strokes.fn += 1; r.strokes.fp += 1 }
            case (_?, nil): r.strokes.fn += 1
            case (nil, _?): r.strokes.fp += 1
            default: break
            }
            if abs(ea.duration - eb.duration) <= beatTolerance { r.rhythm.tp += 1 } else { r.rhythm.fn += 1; r.rhythm.fp += 1 }
        }
        for (i, e) in a.tab.enumerated() where !tg.contains(i) {
            r.tab.fn += e.notes.count; r.tabEvents.fn += 1; if e.stroke != nil { r.strokes.fn += 1 }
        }
        for (j, e) in b.tab.enumerated() where !tp.contains(j) {
            r.tab.fp += e.notes.count; r.tabEvents.fp += 1; if e.stroke != nil { r.strokes.fp += 1 }
        }

        // Melody.
        let mm = matchByBeat(a.melody.map(\.beat), b.melody.map(\.beat))
        let mg = Set(mm.map(\.0)), mp = Set(mm.map(\.1))
        for (i, j) in mm {
            let x = a.melody[i], y = b.melody[j]
            let same: Bool
            if x.degree == 0 || y.degree == 0 { same = x.degree == y.degree }
            else { same = x.degree == y.degree && x.octave == y.octave && x.accidental == y.accidental && x.tieToNext == y.tieToNext }
            if same { r.melody.tp += 1 } else { r.melody.fn += 1; r.melody.fp += 1 }
            if abs(x.duration - y.duration) <= beatTolerance { r.rhythm.tp += 1 } else { r.rhythm.fn += 1; r.rhythm.fp += 1 }
        }
        r.melody.fn += a.melody.count - mg.count
        r.melody.fp += b.melody.count - mp.count

        // Measure length (only when either side states one).
        if a.beats != nil || b.beats != nil {
            if abs((a.beats ?? da) - (b.beats ?? db)) <= beatTolerance { r.rhythm.tp += 1 } else { r.rhythm.fn += 1; r.rhythm.fp += 1 }
        }

        r.barlines.add(multiset(barToken(a), barToken(b)))
    }

    /// Counts a measure that has no counterpart: everything in it is fn (GT) or fp (prediction).
    static func scoreOnly(_ m: NotationMeasure, asGroundTruth gt: Bool, into r: inout OMRScoreReport) {
        func add(_ c: inout CategoryScore, _ n: Int) { if gt { c.fn += n } else { c.fp += n } }
        add(&r.chords, m.chords.count)
        add(&r.chordShapes, m.chords.filter { $0.shape != nil }.count)
        add(&r.tab, m.tab.reduce(0) { $0 + $1.notes.count })
        add(&r.tabEvents, m.tab.count)
        add(&r.strokes, m.tab.filter { $0.stroke != nil }.count)
        add(&r.melody, m.melody.count)
        add(&r.barlines, barToken(m).count)
    }

    // MARK: Lyrics

    static func lyricChars(_ m: NotationMeasure) -> [Int: [Character]] {
        var out: [Int: [Character]] = [:]
        for n in m.melody.sorted(by: { $0.beat < $1.beat }) {
            for (v, s) in n.lyrics.enumerated() {
                let cs = s.filter { !$0.isWhitespace }
                if !cs.isEmpty { out[v, default: []].append(contentsOf: cs) }
            }
        }
        return out
    }

    static func lyricEdit(_ a: NotationMeasure, _ b: NotationMeasure) -> (match: Int, sub: Int, del: Int, ins: Int) {
        let la = lyricChars(a), lb = lyricChars(b)
        var tot = (match: 0, sub: 0, del: 0, ins: 0)
        for v in Set(la.keys).union(lb.keys) {
            let e = editScript(la[v] ?? [], lb[v] ?? [])
            tot.match += e.match; tot.sub += e.sub; tot.del += e.del; tot.ins += e.ins
        }
        return tot
    }

    /// Levenshtein alignment: counts of matches, substitutions, deletions (in `a` only) and insertions (in `b` only).
    static func editScript(_ a: [Character], _ b: [Character]) -> (match: Int, sub: Int, del: Int, ins: Int) {
        let n = a.count, m = b.count
        if n == 0 { return (0, 0, 0, m) }
        if m == 0 { return (0, 0, n, 0) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n { for j in 1...m {
            d[i][j] = min(d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
        } }
        var i = n, j = m
        var r = (match: 0, sub: 0, del: 0, ins: 0)
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                if a[i - 1] == b[j - 1] { r.match += 1 } else { r.sub += 1 }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 { r.del += 1; i -= 1 }
            else { r.ins += 1; j -= 1 }
        }
        return r
    }
}
