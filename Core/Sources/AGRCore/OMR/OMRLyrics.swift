import Foundation

/// One lyric syllable with its horizontal centre (pixels). Punctuation is attached to the previous syllable
/// (opening quotes / brackets to the next one).
struct LyricSyllable: Equatable {
    var text: String
    var x: Double
}

/// One printed lyric line (= one verse) below the numbered-notation row.
struct LyricRow {
    var syllables: [LyricSyllable]
    var top: Double
    var bottom: Double
}

enum OMRLyrics {
    // MARK: character classes

    static let openers: Set<Character> = ["(", "（", "“", "‘", "《", "「", "『", "[", "【", "\""]
    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }
    static func isPunct(_ c: Character) -> Bool {
        if c.isWhitespace { return false }
        if isCJK(c) { return false }
        if c.isLetter || c.isNumber { return false }
        return true
    }

    /// Chord names / diagram markers ("Dm", "G7(3)", "XXO", "C/G") that must not be taken for lyrics.
    static func isChordLike(_ text: String) -> Bool {
        let t = text.filter { !$0.isWhitespace }
        if t.isEmpty { return false }
        if t.allSatisfy({ "xXoO0-—_?×*".contains($0) }) { return true }
        if t.contains(where: { isCJK($0) }) { return false }
        let scalars = Array(t)
        guard let f = scalars.first, "ABCDEFG".contains(f) else { return false }
        return t.count <= 9 && t.allSatisfy { "ABCDEFGabdgijmnsuM#b0123456789()/+-".contains($0) } && t.contains(where: { !$0.isLowercase || t.count <= 3 })
    }

    // MARK: lyric rows

    /// Builds the lyric rows from OCR tokens lying below the numbered-notation row.
    /// - Parameters:
    ///   - yFrom: pixel y of the bottom of the numbered-notation digits (incl. dots handled by caller).
    ///   - yTo: pixel y below which text belongs to the next system.
    ///   - xRange: horizontal pixel range of the staff.
    ///   - digitH: height of the digits (pixels), used as a size reference.
    static func rows(ocr: [OCRToken], width W: Int, height H: Int, bm: Bitmap, yFrom: Double, yTo: Double,
                     xRange: ClosedRange<Double>, digitH: Double, u: Double) -> [LyricRow] {
        let xRange = xRange
        struct Tok { var t: OCRToken; var x0: Double, y0: Double, x1: Double, y1: Double }
        var toks: [Tok] = []
        for t in ocr {
            let x0 = t.x * Double(W), x1 = (t.x + t.width) * Double(W)
            let y0 = t.y * Double(H), y1 = (t.y + t.height) * Double(H)
            let cy = (y0 + y1) / 2, cx = (x0 + x1) / 2
            guard cy > yFrom + 0.3 * digitH, cy < yTo, cx >= xRange.lowerBound - 0.5 * u, cx <= xRange.upperBound + 0.5 * u else { continue }
            guard y1 - y0 >= 0.4 * u, y1 - y0 <= 3.2 * u else { continue }
            let text = t.text.filter { !$0.isWhitespace || true }
            guard text.contains(where: { isCJK($0) || $0.isLetter }) else { continue }
            // digits-only tokens (page numbers, misread jianpu) are not lyrics
            if !text.contains(where: { isCJK($0) || $0.isLetter }) && text.contains(where: { $0.isNumber }) { continue }
            if text.contains("页") && text.count <= 6 { continue }
            if isChordLike(text) { continue }
            if text.lowercased().hasPrefix("page") { continue }
            if text.lowercased().contains("www.") || text.lowercased().contains("http") || text.lowercased().contains(".com") { continue }
            // must contain ink (watermarks are removed by binarisation)
            let ix0 = Int(x0.rounded(.down)), ix1 = Int(x1.rounded(.up)), iy0 = Int(y0.rounded(.down)), iy1 = Int(y1.rounded(.up))
            let area = max(1, (ix1 - ix0) * (iy1 - iy0))
            let ink = bm.count(x0: ix0, y0: iy0, x1: ix1, y1: iy1)
            let onlyPunct = !text.contains(where: { isCJK($0) || $0.isLetter })
            if Double(ink) / Double(area) < (onlyPunct ? 0.004 : 0.04) { continue }
            toks.append(Tok(t: t, x0: x0, y0: y0, x1: x1, y1: y1))
        }
        guard !toks.isEmpty else { return [] }
        toks.sort { ($0.y0 + $0.y1) < ($1.y0 + $1.y1) }
        // cluster into rows by vertical centre
        var rowsTok: [[Tok]] = []
        for t in toks {
            let cy = (t.y0 + t.y1) / 2
            if var last = rowsTok.last {
                let rc = last.map { ($0.y0 + $0.y1) / 2 }.reduce(0, +) / Double(last.count)
                let rh = last.map { $0.y1 - $0.y0 }.max() ?? 1
                if abs(cy - rc) <= 0.55 * max(rh, t.y1 - t.y0) { last.append(t); rowsTok[rowsTok.count - 1] = last; continue }
            }
            rowsTok.append([t])
        }
        // keep the consecutive rows starting right below the jianpu row
        var kept: [[Tok]] = []
        var prevBottom = yFrom
        for (i, r) in rowsTok.enumerated() {
            let top = r.map { $0.y0 }.min() ?? 0, bottom = r.map { $0.y1 }.max() ?? 0
            let rh = bottom - top
            let gap = top - prevBottom
            if i == 0 { if gap > 3.6 * u { break } } else if gap > max(1.0 * rh, 0.9 * u) { break }
            kept.append(r)
            prevBottom = bottom
        }
        var out: [LyricRow] = []
        for r in kept {
            let sorted = r.sorted { $0.x0 < $1.x0 }
            var syl: [LyricSyllable] = []
            var pendingOpen = ""
            for tk in sorted {
                let rowH = tk.y1 - tk.y0
                var s = syllables(of: tk.t.text, x0: tk.x0, x1: tk.x1, y0: tk.y0, y1: tk.y1, bm: bm, rowH: rowH)
                if !pendingOpen.isEmpty, !s.isEmpty { s[0].text = pendingOpen + s[0].text; pendingOpen = "" }
                for x in s {
                    // a pure-punctuation syllable attaches to the previous one
                    if x.text.allSatisfy({ isPunct($0) }) && !(x.text.first.map { openers.contains($0) } ?? false) {
                        if !syl.isEmpty { syl[syl.count - 1].text += x.text }
                        continue
                    }
                    syl.append(x)
                }
            }
            let rowTop = r.map { $0.y0 }.min() ?? 0, rowBottom = r.map { $0.y1 }.max() ?? 0
            // OCR engines often drop the character 一 (a single horizontal stroke): recover isolated strokes
            for x in missingDashes(bm: bm, top: rowTop, bottom: rowBottom, covered: r.map { ($0.x0, $0.x1) }, xRange: xRange) {
                syl.append(LyricSyllable(text: "一", x: x))
            }
            syl.sort { $0.x < $1.x }
            out.append(LyricRow(syllables: syl, top: rowTop, bottom: rowBottom))
        }
        return out
    }

    /// Isolated horizontal strokes of character width at mid-height of a lyric row that no OCR token covers.
    static func missingDashes(bm: Bitmap, top: Double, bottom: Double, covered: [(Double, Double)], xRange: ClosedRange<Double>) -> [Double] {
        let H = bottom - top
        guard H >= 8 else { return [] }
        let cy = (top + bottom) / 2
        let xa = max(0, Int(xRange.lowerBound)), xb = min(bm.w, Int(xRange.upperBound))
        var found: [(Int, Int)] = []
        for yy in Int(cy - 0.2 * H)...Int(cy + 0.2 * H) where yy >= 0 && yy < bm.h {
            var x = xa
            while x < xb {
                if bm.d[yy * bm.w + x] != 0 {
                    var e = x
                    while e < xb && bm.d[yy * bm.w + e] != 0 { e += 1 }
                    let len = Double(e - x)
                    if len >= 0.5 * H && len <= 1.3 * H { found.append((x, e)) }
                    x = e
                } else { x += 1 }
            }
        }
        var out: [Double] = []
        var done: [(Int, Int)] = []
        for (xs, xe) in found {
            if done.contains(where: { abs($0.0 - xs) <= 2 && abs($0.1 - xe) <= 2 }) { continue }
            let c = Double(xs + xe) / 2
            if covered.contains(where: { c >= $0.0 - 0.3 * H && c <= $0.1 + 0.3 * H }) { continue }
            // isolated: no ink above / below the stroke
            var clear = true
            for yy in [Int(cy - 0.55 * H), Int(cy - 0.4 * H), Int(cy + 0.4 * H), Int(cy + 0.55 * H)] where yy >= 0 && yy < bm.h {
                for x in xs..<xe where bm.d[yy * bm.w + x] != 0 { clear = false; break }
                if !clear { break }
            }
            if clear {
                done.append((xs, xe))
                if !out.contains(where: { abs($0 - c) < 0.5 * H }) { out.append(c) }
            }
        }
        return out
    }

    /// Splits an OCR text line token into syllables with estimated x centres.
    static func syllables(of text: String, x0: Double, x1: Double, y0: Double, y1: Double, bm: Bitmap, rowH: Double) -> [LyricSyllable] {
        // 1. tokenise: CJK char = syllable; Latin/digit run = word syllable; punctuation attaches.
        var items: [String] = []        // syllable texts (with attached punctuation)
        var weights: [Int] = []         // character widths used for the fallback proportional split
        var pendingOpen = ""
        var word = ""
        func flushWord() { if !word.isEmpty { items.append(word); weights.append(max(1, word.count)); word = "" } }
        for c in text {
            if c.isWhitespace { flushWord(); continue }
            if isCJK(c) {
                flushWord()
                items.append(pendingOpen + String(c)); pendingOpen = ""; weights.append(2)
            } else if c.isLetter || c.isNumber || c == "'" && !word.isEmpty {
                word.append(c)
            } else if isPunct(c) {
                if openers.contains(c) { flushWord(); pendingOpen.append(c); continue }
                flushWord()
                if items.isEmpty { items.append(String(c)); weights.append(0) } else { items[items.count - 1].append(c) }
            }
        }
        flushWord()
        guard !items.isEmpty else { return [] }
        // the pure-punctuation first item (weight 0) has no position
        let charIdx = items.indices.filter { weights[$0] > 0 }
        guard !charIdx.isEmpty else { return items.map { LyricSyllable(text: $0, x: (x0 + x1) / 2) } }
        let n = charIdx.count
        // 2. positions
        var xs: [Double]?
        if charIdx.allSatisfy({ items[$0].contains(where: { isCJK($0) }) }) {
            xs = pixelCenters(x0: x0, x1: x1, y0: y0, y1: y1, bm: bm, n: n, rowH: rowH)
        }
        if xs == nil {
            let total = Double(charIdx.map { weights[$0] }.reduce(0, +))
            var acc = 0.0
            var p: [Double] = []
            for i in charIdx { let w = Double(weights[i]); p.append(x0 + (acc + w / 2) / total * (x1 - x0)); acc += w }
            xs = p
        }
        var out: [LyricSyllable] = []
        var k = 0
        for (i, it) in items.enumerated() {
            if weights[i] > 0 { out.append(LyricSyllable(text: it, x: xs![k])); k += 1 }
            else { out.append(LyricSyllable(text: it, x: x0)) }
        }
        return out
    }

    /// Estimates the centres of `n` CJK characters of a text line from the ink columns of the line image.
    static func pixelCenters(x0: Double, x1: Double, y0: Double, y1: Double, bm: Bitmap, n: Int, rowH: Double) -> [Double]? {
        let H = max(8.0, rowH)
        let ya = max(0, Int(y0.rounded(.down)) - 1), yb = min(bm.h, Int(y1.rounded(.up)) + 2)
        let xa = max(0, Int((x0 - 0.35 * H).rounded(.down))), xb = min(bm.w, Int((x1 + 0.35 * H).rounded(.up)))
        guard xb - xa >= n, yb > ya else { return nil }
        // column projection
        var col = [Bool](repeating: false, count: xb - xa)
        var colTop = [Int](repeating: Int.max, count: xb - xa), colBot = [Int](repeating: -1, count: xb - xa)
        for x in xa..<xb {
            for y in ya..<yb where bm.d[y * bm.w + x] != 0 {
                col[x - xa] = true
                colTop[x - xa] = min(colTop[x - xa], y); colBot[x - xa] = max(colBot[x - xa], y)
            }
        }
        struct Cl { var a: Int; var b: Int; var top: Int; var bot: Int; var w: Int { b - a + 1 }; var c: Double { Double(a + b) / 2 + 0.5 } }
        var cls: [Cl] = []
        let gapTol = max(1, Int((0.10 * H).rounded()))
        var x = 0
        while x < col.count {
            if col[x] {
                var e = x, t = colTop[x], b = colBot[x]
                var last = x
                var k = x
                while k < col.count && k - last <= gapTol + 1 {
                    if col[k] { last = k; t = min(t, colTop[k]); b = max(b, colBot[k]) }
                    k += 1
                }
                e = last
                cls.append(Cl(a: x + xa, b: e + xa, top: t, bot: b))
                x = e + 1
            } else { x += 1 }
        }
        // drop punctuation-like clusters (small, low) and specks
        cls = cls.filter { c in
            let h = Double(c.bot - c.top + 1)
            if h < 0.45 * H && Double(c.w) < 0.5 * H { return false }
            return Double(c.w) >= 0.12 * H || h >= 0.5 * H
        }
        guard !cls.isEmpty else { return nil }
        // merge fragments until we have n clusters
        while cls.count > n {
            var best = -1, bestGap = Double.infinity
            for i in 0..<(cls.count - 1) {
                let gap = Double(cls[i + 1].a - cls[i].b - 1)
                let comb = Double(cls[i + 1].b - cls[i].a + 1)
                if comb > 1.25 * H { continue }
                if gap < bestGap { bestGap = gap; best = i }
            }
            if best < 0 { break }
            var m = cls[best]
            m.b = cls[best + 1].b; m.top = min(m.top, cls[best + 1].top); m.bot = max(m.bot, cls[best + 1].bot)
            cls[best] = m; cls.remove(at: best + 1)
        }
        // split wide clusters (touching characters)
        while cls.count < n {
            guard let wi = cls.indices.max(by: { cls[$0].w < cls[$1].w }), Double(cls[wi].w) >= 1.45 * H else { break }
            let c = cls[wi]
            let pieces = max(2, Int((Double(c.w) / (1.0 * H)).rounded()))
            let take = min(pieces, n - cls.count + 1)
            var parts: [Cl] = []
            for p in 0..<take {
                let a = c.a + Int(Double(c.w) * Double(p) / Double(take)), b = c.a + Int(Double(c.w) * Double(p + 1) / Double(take)) - 1
                parts.append(Cl(a: a, b: b, top: c.top, bot: c.bot))
            }
            cls.replaceSubrange(wi...wi, with: parts)
        }
        guard cls.count == n else { return nil }
        return cls.map(\.c)
    }

    // MARK: alignment

    struct NoteSlot { var x: Double; var isRest: Bool }

    /// Assigns the syllables of each lyric row to notes (monotone, one syllable per note when possible).
    /// Returns `[verse][note]` strings and the number of alignment conflicts.
    static func align(rows: [LyricRow], notes: [NoteSlot], pitch: Double) -> (lyrics: [[String]], conflicts: Int) {
        var result = [[String]](repeating: [String](repeating: "", count: notes.count), count: rows.count)
        var conflicts = 0
        guard !notes.isEmpty else { return (result, rows.reduce(0) { $0 + ($1.syllables.isEmpty ? 0 : 1) }) }
        for (vi, row) in rows.enumerated() {
            let s = row.syllables.sorted { $0.x < $1.x }
            let k = s.count, m = notes.count
            if k == 0 { continue }
            func cost(_ i: Int, _ j: Int) -> Double {
                var c = abs(s[i].x - notes[j].x) / max(pitch, 1)
                if notes[j].isRest { c += 0.8 }
                return c
            }
            if k <= m {
                // dp[i][j]: best cost with first i syllables placed, syllable i-1 at note j-1 (injective, increasing)
                let inf = 1e18
                var dp = [[Double]](repeating: [Double](repeating: inf, count: m + 1), count: k + 1)
                var from = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: k + 1)
                dp[0][0] = 0
                for i in 1...k {
                    // prefix minima over j' < j
                    var bestPrev = inf, bestIdx = 0
                    for j in 1...m {
                        let prevJ = j - 1
                        if dp[i - 1][prevJ] < bestPrev { bestPrev = dp[i - 1][prevJ]; bestIdx = prevJ }
                        if bestPrev < inf {
                            dp[i][j] = bestPrev + cost(i - 1, j - 1)
                            from[i][j] = bestIdx
                        }
                    }
                }
                var j = (1...m).min(by: { dp[k][$0] < dp[k][$1] })!
                var i = k
                var assign = [Int](repeating: 0, count: k)
                while i > 0 { assign[i - 1] = j - 1; j = from[i][j]; i -= 1 }
                for (si, nj) in assign.enumerated() {
                    result[vi][nj] = s[si].text
                    if abs(s[si].x - notes[nj].x) > 0.9 * pitch { conflicts += 1 }
                    else if notes[nj].isRest { conflicts += 1 }
                }
            } else {
                conflicts += k - m
                for sy in s {
                    var bj = 0, bd = Double.infinity
                    for j in 0..<m { let d = abs(sy.x - notes[j].x); if d < bd { bd = d; bj = j } }
                    result[vi][bj] += sy.text
                }
            }
        }
        return (result, conflicts)
    }
}
