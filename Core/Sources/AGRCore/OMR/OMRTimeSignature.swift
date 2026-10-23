import Foundation

/// Reads the time signature printed on the first tab staff: two stacked numbers between the TAB clef and the first note.
/// The upper number is centred on the upper half of the staff and the lower one on the lower half; in bold fonts the two
/// numbers touch and form one tall component, which is cut before classification.
///
/// The glyph classifier knows only a few fonts, so each glyph keeps its ranked digit candidates and the signature is chosen
/// jointly: a pair must be a plausible signature (numerator 1...12 over 2/4/8/16) and the usual ones (4/4, 3/4, 6/8 ...)
/// get a prior bonus over unusual ones (8/8).
enum OMRTimeSignatureReader {
    struct Part { var rect: IRect; var bm: Bitmap }
    typealias Ranked = [(digit: Int, conf: Double)]

    static let common: Set<String> = ["4/4", "3/4", "2/4", "6/8", "2/2", "3/8", "9/8", "12/8", "6/4", "5/4", "3/2", "7/8", "5/8"]
    static let priorBonus = 0.15

    /// Digit candidates of a glyph, best first (closeness 0...1 as in `OMRGlyphClassifier.classify`).
    static func rank(_ bm: Bitmap, classifier: OMRGlyphClassifier) -> Ranked {
        guard let f = OMRGlyphFeatures.vector(bm) else { return [] }
        var per: [Int: Double] = [:]
        for t in classifier.templates {
            guard let v = Int(t.label), (0...9).contains(v) else { continue }
            var d = 0
            for i in 0..<f.v.count { d += abs(Int(f.v[i]) - Int(t.v[i])) }
            let dist = Double(d) / Double(f.v.count * 255) + 0.35 * Double(abs(f.aspect - t.aspect)) / 100.0
            if dist < (per[v] ?? .infinity) { per[v] = dist }
        }
        return per.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(3).map { (digit: $0.key, conf: max(0, 1 - $0.value / 0.45)) }
    }

    /// - Parameters:
    ///   - clean: page bitmap with the staff lines removed.
    ///   - limitX: right end of the search window (first note / stem of the first measure); nil -> 16u from the staff start.
    static func read(clean: Bitmap, staff st: TabStaff, limitX: Double? = nil, classifier: OMRGlyphClassifier = .shared) -> (beats: Int, unit: Int)? {
        let u = st.u
        let x0 = max(0, st.x0 + Int(0.3 * u))
        let x1 = min(clean.w, Int(limitX ?? (Double(st.x0) + 16 * u)))
        let y0 = max(0, Int(st.top - 0.8 * u)), y1 = min(clean.h, Int(st.bottom + 0.8 * u))
        guard x1 > x0 + 4, y1 > y0 + 4 else { return nil }
        let crop = OMRVision.crop(clean, IRect(x0: x0, y0: y0, x1: x1, y1: y1))
        let lab = OMRVision.label(crop)
        // tall components that may hold one or two numbers; the TAB letters are matched by validity below
        var singles: [Part] = [], merged: [Part] = []
        for c in lab.comps where c.area >= 8 {
            let h = Double(c.rect.h), w = Double(c.rect.w)
            guard h >= 0.9 * u, h <= 4.4 * u, w >= 0.25 * u, w <= 2.4 * u else { continue }
            let r = IRect(x0: c.rect.x0 + x0, y0: c.rect.y0 + y0, x1: c.rect.x1 + x0, y1: c.rect.y1 + y0)
            let p = Part(rect: r, bm: OMRVision.extract(lab, c))
            if h > 2.1 * u { merged.append(p) } else { singles.append(p) }
        }
        let mid = st.top + 2.5 * u
        struct Digit { var rank: Ranked; var cx: Double; var x0: Int; var x1: Int }
        var best: (score: Double, sig: (Int, Int))?
        func consider(_ up: [Digit], _ lo: [Digit]) {
            // numbers: adjacent digits (gap < 0.8u) in a row, at most two digits
            func numbers(_ ds: [Digit]) -> [[Digit]] {
                var groups: [[Digit]] = []
                for d in ds.sorted(by: { $0.cx < $1.cx }) {
                    if let g = groups.last, Double(d.x0 - g.last!.x1) < 0.8 * u { groups[groups.count - 1].append(d) } else { groups.append([d]) }
                }
                return groups.filter { $0.count <= 2 }
            }
            func values(_ g: [Digit]) -> [(Int, Double)] {
                if g.count == 1 { return g[0].rank.map { ($0.digit, $0.conf) } }
                var out: [(Int, Double)] = []
                for a in g[0].rank { for b in g[1].rank { out.append((a.digit * 10 + b.digit, (a.conf + b.conf) / 2)) } }
                return out
            }
            for gu in numbers(up) { for gl in numbers(lo) {
                let cu = gu.map(\.cx).reduce(0, +) / Double(gu.count), cl = gl.map(\.cx).reduce(0, +) / Double(gl.count)
                guard abs(cu - cl) <= 1.0 * u else { continue }
                for (a, ca) in values(gu) { for (b, cb) in values(gl) where (1...12).contains(a) && [2, 4, 8, 16].contains(b) && (a != b || common.contains("\(a)/\(b)")) {
                    // both numbers must be read with some confidence; the prior only breaks near ties between plausible readings
                    guard ca >= 0.3, cb >= 0.3 else { continue }
                    let score = ca + cb + (common.contains("\(a)/\(b)") ? priorBonus : 0)
                    if best == nil || score > best!.score + 1e-9 { best = (score, (a, b)) }
                } }
            } }
        }
        // 1. numbers drawn as separate glyphs
        var ups: [Digit] = [], lows: [Digit] = []
        for p in singles {
            let r = rank(p.bm, classifier: classifier)
            guard !r.isEmpty else { continue }
            let d = Digit(rank: r, cx: p.rect.cx, x0: p.rect.x0, x1: p.rect.x1)
            if p.rect.cy < mid { ups.append(d) } else { lows.append(d) }
        }
        consider(ups, lows)
        // 2. both numbers in one component (bold fonts): try every cut near the centre, keep the best-reading one
        for p in merged {
            if OMRTrace.flag("OMR_DEBUG_TS") { for y in 0..<p.bm.h { FileHandle.standardError.write(Data(("bm " + (0..<p.bm.w).map { p.bm.d[y * p.bm.w + $0] != 0 ? "#" : "." }.joined() + "\n").utf8)) } }
            for cut in Int(Double(p.bm.h) * 0.35)...Int(Double(p.bm.h) * 0.65) {
                let top = OMRVision.crop(p.bm, IRect(x0: 0, y0: 0, x1: p.bm.w, y1: cut))
                let bot = OMRVision.crop(p.bm, IRect(x0: 0, y0: cut + 1, x1: p.bm.w, y1: p.bm.h))
                let rt = rank(top, classifier: classifier), rb = rank(bot, classifier: classifier)
                guard !rt.isEmpty, !rb.isEmpty else { continue }
                let t = Digit(rank: rt, cx: p.rect.cx, x0: p.rect.x0, x1: p.rect.x1)
                let b = Digit(rank: rb, cx: p.rect.cx, x0: p.rect.x0, x1: p.rect.x1)
                consider([t], [b])
            }
        }
        if OMRTrace.flag("OMR_DEBUG_TS") { FileHandle.standardError.write(Data("ts singles \(singles.count) merged \(merged.count) -> \(String(describing: best))\n".utf8)) }
        return best.map { $0.sig }
    }
}
