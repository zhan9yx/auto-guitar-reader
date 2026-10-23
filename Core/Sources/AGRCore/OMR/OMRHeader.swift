import Foundation

// MARK: - Page header (title, artist, key, time signature, capo, tempo, credits)

public struct OMRHeaderResult: Sendable {
    public var meta = ScoreMeta()
    public var issues: [OMRIssue] = []
    /// Text judged to be watermark / ad / page number (kept for the report, never part of credits).
    public var nonScoreText: [String] = []
    /// Fields that were actually found ("title", "artist", "key", "capo", "tempo", "time").
    public var found: Set<String> = []
    public init() {}
}

public enum OMRHeaderReader {
    /// Reads the header of a page.
    /// - Parameters:
    ///   - ocr: OCR tokens (normalised page coordinates, top-left origin) incl. region-pass tokens.
    ///   - firstStaffTop: y (px) of the first tab staff's top line; header text lies above it. nil -> top 35% of the page.
    ///   - staffSpacing: tab line spacing u in px (used for size thresholds).
    ///   - timeSignature: time signature read from the tab staff (stacked digits next to the clef), preferred over OCR.
    public static func read(ocr: [OCRToken], pageWidth: Int, pageHeight: Int, firstStaffTop: Double? = nil, staffSpacing: Double? = nil,
                            timeSignature: (beats: Int, unit: Int)? = nil, pageIndex: Int = 0, lastSystemBottom: Double? = nil,
                            repeatedElsewhere: Set<String> = []) -> OMRHeaderResult {
        var res = OMRHeaderResult()
        let W = Double(pageWidth), H = Double(pageHeight)
        let u = staffSpacing ?? max(8, 0.0075 * H)
        let top = firstStaffTop ?? 0.35 * H
        var ctx = OMRTextContext()
        ctx.pageIndex = pageIndex; ctx.pageWidth = W; ctx.pageHeight = H; ctx.staffSpacing = u
        ctx.firstSystemTop = firstStaffTop; ctx.lastSystemBottom = lastSystemBottom; ctx.repeatedElsewhere = repeatedElsewhere

        var keep: [OCRToken] = []
        for t in ocr {
            let cy = (t.y + t.height / 2) * H
            if let why = OMRWatermark.isNonScoreText(t, context: ctx) {
                if cy < top { res.nonScoreText.append(t.text) }
                _ = why
                continue
            }
            if cy < top - 0.3 * u { keep.append(t) }
        }
        // rows
        let rows = OCRRowBuilder.rows(from: keep)
        struct Row { var text: String; var folded: String; var cy: Double; var h: Double; var cx: Double; var tokens: [OCRToken] }
        var rs: [Row] = rows.map { r in
            let folded = ChordNameNormalizer.foldWidth(r.text)
            return Row(text: r.text, folded: folded, cy: r.center * H, h: r.height * H, cx: (r.left + r.right) / 2 * W, tokens: r.tokens)
        }
        rs.sort { $0.cy < $1.cy }

        var priorityKey = -1
        var titleCandidates: [Int] = []
        var creditRows: [Int] = []
        var metaRows = Set<Int>()
        var timeFromText: (Int, Int)?
        var capoShapeKey: String?
        var origKey: String?
        var selKey: String?
        var plainKey: String?
        for (i, r) in rs.enumerated() {
            let Trow = r.folded.filter { !$0.isWhitespace }
            // single-spaced text keeps the gap between a note letter and a stray glyph (a "#" that is really a time signature)
            let Srow = r.folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            var isMeta = false
            let cands = r.tokens.map { ChordNameNormalizer.foldWidth($0.text) } + [r.folded]
            let note = #"([#b]?[A-G][#b]?m?)"#
            for c in cands {
                let T = c.filter { !$0.isWhitespace }
                let S = c.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                // key (accidentals must touch the note letter)
                if let g = Rx.firstMatch("(?:选调|演奏调|选用调|弹奏调|(?i:played))\\s*[:：=]?\\s*(?:1\\s*=\\s*)?" + note, in: S) { selKey = selKey ?? normalizeKey(g[1] ?? ""); isMeta = true }
                if let g = Rx.firstMatch("原调(?:为|是)?\\s*[:：=]?\\s*(?:1\\s*=\\s*)?" + note, in: S) { origKey = origKey ?? normalizeKey(g[1] ?? ""); isMeta = true }
                if let g = Rx.firstMatch("(?:^|[^A-Za-z])(?i:key)\\s*[:：]?\\s*" + note, in: S) { plainKey = plainKey ?? normalizeKey(g[1] ?? ""); isMeta = true }
                for g in Rx.matches("[1lI]\\s*=\\s*" + note, in: S) {
                    let nk = normalizeKey(g.groups[1] ?? "")
                    let before = (S as NSString).substring(to: g.location)
                    if before.contains("原调") { origKey = origKey ?? nk } else { plainKey = plainKey ?? nk }
                    isMeta = true
                }
                if let g = Rx.firstMatch(#"([A-G][#b]?)调(?:指法|版|编配|和弦|谱)"#, in: T) { capoShapeKey = capoShapeKey ?? normalizeKey(g[1] ?? ""); isMeta = true }
                // "J=723品变调夹" : tempo 72 immediately followed by the capo digit
                if let g = Rx.firstMatch(#"(?:[♩♪♫Jj]=?|bpm=?|tempo=?|速度[:：=]?)(\d{2})(\d)品变调夹"#, in: T), !res.found.contains("tempo"), let bpm = Double(g[1] ?? ""), let cp = Int(g[2] ?? "") {
                    res.meta.tempo = bpm; res.found.insert("tempo")
                    if !res.found.contains("capo") { res.meta.capo = cp; res.found.insert("capo") }
                    isMeta = true
                }
                // capo
                if let g = Rx.firstMatch(#"(?i)(?:变调夹|capo|cap0|夹)[:：=]?(?:第|在)?(-?\d{1,2}|[一二两三四五六七八九十]{1,2})(?:品|fret)?"#, in: T)
                    ?? Rx.firstMatch(#"(\d{1,2})品变调夹"#, in: T), let v = g[1] {
                    if !res.found.contains("capo"), let n = MetaLineParser.parseSmallInt(v), n >= 0, n <= 12 { res.meta.capo = n; res.found.insert("capo") }
                    isMeta = true
                } else if Rx.test(#"(?i)(无变调夹|不用变调夹|nocapo)"#, T) { res.found.insert("capo"); isMeta = true }
                // tempo
                do {
                    var bpm: Double?
                    if let g = Rx.firstMatch(#"(?i)(?:bpm|tempo|速度)[:：=]?(?:[♩♪♫]=?|[Jj]=?)?(?:≈|约)?(\d{2,3})"#, in: T) ?? Rx.firstMatch(#"[♩♪♫][=≈](\d{2,3})"#, in: T)
                        ?? Rx.firstMatch(#"(?:^|[^\d=A-Za-z])[Jj]=(\d{2,3})"#, in: T) ?? Rx.firstMatch(#"(\d{2,3})(?i:bpm)"#, in: T)
                        ?? Rx.firstMatch(#"(?:速度|演奏速度)[:：=]?.{0,3}?=?(\d{2,3})"#, in: T), let v = g[1] { bpm = Double(v) }
                    else if let g = Rx.firstMatch(#"(?:^|[^\d])=\s*(\d{2,3})$"#, in: T), let v = g[1], !T.contains("1="), r.cy < top - 0.5 * u { bpm = Double(v) }
                    else if let g = Rx.firstMatch(#"^(\d{2,3})=[□■口]*$"#, in: T), let v = g[1] { bpm = Double(v) }      // "96=□□" (note glyph lost by OCR)
                    if let b = bpm, (30...300).contains(b) { if !res.found.contains("tempo") { res.meta.tempo = b; res.found.insert("tempo") }; isMeta = true }
                }
            }
            let T = Trow; _ = Srow
            // time signature written as text
            if timeFromText == nil, let g = Rx.firstMatch(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:拍)?(?![\d/])"#, in: T), let b = Int(g[1] ?? ""), let un = Int(g[2] ?? ""),
               (1...12).contains(b), [2, 4, 8, 16].contains(un), r.cy < top - 0.5 * u, Rx.test(#"(?i)(1=|key|调|拍|bpm|tempo|capo)"#, T) || T.count <= 5 {
                timeFromText = (b, un); isMeta = true
            }
            // credits / artist labels
            let creditRx = #"(?:作词|作曲|词曲|曲词|词|曲|编配|编曲|编谱|制谱|整理|记谱|扒谱|校对|吉他谱|吉他编配|演唱者|演唱|原唱|歌手|主唱|arranged|transcribed|music|lyrics|words|artist|singer)\s*[:：]|(?:作词|作曲|编配|编曲|制谱|整理|演唱|原唱|歌手)\s*\S"#
            if Rx.test("(?i)" + creditRx, r.folded) || Rx.test(#"(词曲|编\s*配|制\s*谱)\s*$"#, T) { creditRows.append(i); isMeta = true }
            if isMeta { metaRows.insert(i) }
            else if !SectionHeaderParser.isSectionLabel(r.folded), !looksLikeChordRow(r.tokens), OMRChordReader.cleanName(T) == nil || T.count > 6 { titleCandidates.append(i) }
        }
        // "后来" sits on the same baseline as "1=C" / "原唱" / "变调夹", so that row is meta
        // and the centered title token never becomes a candidate.
        for i in metaRows {
            for t in centeredTitleTokens(rs[i].tokens, pageWidth: W) {
                let cx = (t.x + t.width / 2) * W
                rs.append(Row(text: t.text, folded: ChordNameNormalizer.foldWidth(t.text),
                              cy: (t.y + t.height / 2) * H, h: t.height * H, cx: cx, tokens: [t]))
                titleCandidates.append(rs.count - 1)
            }
        }
        _ = priorityKey

        // key resolution: 选调 > shape key from "X调指法" (+capo) > 原调 (shifted down by capo)
        if let k = selKey ?? plainKey { res.meta.key = k; res.found.insert("key") }
        else if let k = capoShapeKey { res.meta.key = transpose(k, res.meta.capo); res.found.insert("key") }
        else if let k = origKey { res.meta.key = res.meta.capo > 0 && !res.found.isEmpty && res.found.contains("capo") ? transpose(k, -res.meta.capo) : k; res.found.insert("key") }

        // time signature
        if let t = timeSignature { res.meta.timeSignature = TimeSignature(beats: t.beats, unit: t.unit); res.found.insert("time") }
        else if let t = timeFromText ?? stackedTimeSignature(keep, H: H, W: W, top: top, u: u) {
            res.meta.timeSignature = TimeSignature(beats: t.0, unit: t.1); res.found.insert("time")
        }

        // title: tallest candidate row in the upper region (centered rows win ties); artist: next smaller row below
        let region = titleCandidates.filter { rs[$0].cy < top - (firstStaffTop == nil ? 1.0 : 7.5) * u && rs[$0].tokens.allSatisfy { $0.confidence >= 0.5 } }
        func score(_ i: Int) -> Double {
            let r = rs[i]
            let centered = 1 - min(1, abs(r.cx - W / 2) / (W / 2)) * 0.25
            return r.h * centered - 0.0004 * r.cy
        }
        if let ti = region.max(by: { score($0) < score($1) }) {
            let r = rs[ti]
            var title = cleanTitle(r.text)
            var artist: String?
            for sep in [" - ", " – ", " — ", "—"] {
                if let rg = title.range(of: sep) {
                    let l = String(title[..<rg.lowerBound]).agrTrimmed, rr = String(title[rg.upperBound...]).agrTrimmed
                    if !l.isEmpty, !rr.isEmpty { title = cleanTitle(l); artist = cleanTitle(rr); break }
                }
            }
            res.meta.title = title; res.found.insert("title")
            if let a = artist { res.meta.artist = a; res.found.insert("artist") }
            else if let ai = region.filter({ rs[$0].cy > r.cy && rs[$0].cy - r.cy < 4.0 * r.h && rs[$0].h <= 0.95 * r.h }).min(by: { rs[$0].cy < rs[$1].cy }) {
                let a = cleanTitle(rs[ai].text)
                if a.count <= 40 { res.meta.artist = a; res.found.insert("artist") }
            }
        }
        // labelled artist overrides a line picked up under the title (演唱 / 原唱 / 歌手)
        for i in creditRows {
            if let g = Rx.firstMatch(#"(?:演唱者|演唱|原\s*唱|歌手|主唱|(?i:singer|artist))\s*[:：]?\s*(\S.*)$"#, in: rs[i].folded) {
                let v = (g[1] ?? "").agrTrimmed
                if !v.isEmpty { res.meta.artist = v; res.found.insert("artist"); break }
            }
        }
        for i in creditRows { let t = rs[i].text.agrTrimmed; if !res.meta.credits.contains(t) { res.meta.credits.append(t) } }
        if res.meta.title.isEmpty { res.issues.append(OMRIssue(kind: .headerMissing, path: "meta.title", message: "no title found")) }
        return res
    }

    // MARK: Time signature from the tab staff

    /// Reads the stacked digits ("3" over "4") after the TAB clef of the first staff.
    static func readTimeSignature(bm: Bitmap, staff st: TabStaff) -> (beats: Int, unit: Int)? {
        let u = st.u
        let clean = OMRStaffDetector.removeLines(bm, staves: [st])
        let x0 = st.x0 + Int(0.4 * u), x1 = min(bm.w, st.x0 + Int(16 * u))
        let y0 = Int(st.top - 0.8 * u), y1 = Int(st.bottom + 0.8 * u)
        guard x1 > x0, y1 > y0, y0 >= 0, y1 < bm.h else { return nil }
        let crop = OMRVision.crop(clean, IRect(x0: x0, y0: y0, x1: x1, y1: y1))
        let lab = OMRVision.label(crop)
        let mid = st.top + 2.5 * u
        struct G { var rect: IRect; var bm: Bitmap }
        var gs: [G] = []
        for c in lab.comps where Double(c.rect.h) >= 1.15 * u && Double(c.rect.h) <= 3.3 * u && Double(c.rect.w) >= 0.3 * u && Double(c.rect.w) <= 2.4 * u && c.area >= 8 {
            let r = IRect(x0: c.rect.x0 + x0, y0: c.rect.y0 + y0, x1: c.rect.x1 + x0, y1: c.rect.y1 + y0)
            gs.append(G(rect: r, bm: OMRVision.extract(lab, c)))
        }
        gs.sort { $0.rect.x0 < $1.rect.x0 }
        // numbers = horizontally adjacent glyphs on the same row; pair an upper with a lower number at the same x
        func number(_ g: G) -> (v: Int, cx: Double, cy: Double)? {
            guard let (l, c) = OMRGlyphClassifier.shared.classify(g.bm, role: .tabDigit, allowed: Set((0...9).map(String.init))), c >= 0.35, let v = Int(l) else { return nil }
            return (v, g.rect.cx, g.rect.cy)
        }
        var ups: [(Int, Double, Double, Double)] = [], lows: [(Int, Double, Double, Double)] = []
        for g in gs {
            guard let n = number(g) else { continue }
            if n.cy < mid { ups.append((n.v, n.cx, n.cy, Double(g.rect.h))) } else { lows.append((n.v, n.cx, n.cy, Double(g.rect.h))) }
        }
        for a in ups { for b in lows where abs(a.1 - b.1) <= 0.9 * u && b.2 > a.2 && (a.3 + b.3) / 2 >= 1.15 * u {
            if (1...12).contains(a.0), [2, 4, 8, 16].contains(b.0) { return (a.0, b.0) }
            if b.0 == 6 || b.0 == 1 { continue }
        } }
        return nil
    }

    // MARK: Helpers

    /// Centered title words that share a header row with a key / credit label.
    private static func centeredTitleTokens(_ tokens: [OCRToken], pageWidth W: Double) -> [OCRToken] {
        tokens.filter { t in
            let cx = (t.x + t.width / 2) * W
            guard abs(cx - W / 2) <= 0.18 * W else { return false }
            let label = cleanTitle(t.text)
            guard (2...24).contains(label.count) else { return false }
            let folded = ChordNameNormalizer.foldWidth(t.text)
            if Rx.test(#"(?i)(1\s*=|原调|选调|变调|capo|原唱|演唱|作词|作曲|编配|制谱|编谱|bpm|速度|http|www\.|淘宝|微信|公众号)"#, folded) { return false }
            if looksLikeChordRow([t]) { return false }
            return true
        }
    }

    /// Trims spaces and quote marks, but keeps 《…》 that wrap only part of the title ("《不染》G调精华版").
    static func cleanTitle(_ s: String) -> String {
        var t = s.agrTrimmed
        for (o, c) in [("《", "》"), ("「", "」"), ("“", "”"), ("\"", "\"")] where t.hasPrefix(o) && t.hasSuffix(c) && t.count > 2 {
            let inner = t.dropFirst().dropLast()
            if !inner.contains(o) && !inner.contains(c) { t = String(inner).agrTrimmed }
        }
        return t
    }

    /// "#C" / "bB" / "C#" / "c" -> "C#" / "Bb" / "C#" / "C".
    static func normalizeKey(_ s: String) -> String {
        var t = ChordNameNormalizer.foldWidth(s).filter { !$0.isWhitespace }
        guard !t.isEmpty else { return t }
        var acc = ""
        if t.first == "#" || (t.first == "b" && t.count > 1 && "ABCDEFG".contains(t[t.index(after: t.startIndex)])) { acc = String(t.removeFirst()) }
        guard let root = t.first else { return acc }
        var rest = String(t.dropFirst())
        if rest.hasPrefix("#") || rest.hasPrefix("b") { acc = String(rest.removeFirst()) }
        return String(root).uppercased() + acc + rest
    }

    static func transpose(_ key: String, _ semitones: Int) -> String {
        guard semitones != 0 else { return key }
        let minor = key.hasSuffix("m")
        let base = minor ? String(key.dropLast()) : key
        guard let s = ChordSymbol(base) else { return key }
        let t = s.transposed(by: semitones, preferFlats: base.contains("b") || semitones < 0 && !base.contains("#"))
        return t.description + (minor ? "m" : "")
    }

    static func looksLikeChordRow(_ tokens: [OCRToken]) -> Bool {
        let cs = tokens.filter { OMRChordReader.cleanName($0.text) != nil }.count
        return !tokens.isEmpty && cs == tokens.count
    }

    /// Two stacked small numbers (e.g. "4" over "4") -> time signature.
    static func stackedTimeSignature(_ tokens: [OCRToken], H: Double, W: Double, top: Double, u: Double) -> (Int, Int)? {
        let nums = tokens.compactMap { t -> (Int, Double, Double, Double)? in
            let s = ChordNameNormalizer.foldWidth(t.text).filter { !$0.isWhitespace }
            guard let v = Int(s), s.count <= 2, v >= 1, v <= 16 else { return nil }
            return (v, (t.x + t.width / 2) * W, (t.y + t.height / 2) * H, t.height * H)
        }
        for a in nums { for b in nums where b.2 > a.2 && b.2 - a.2 < 2.5 * max(a.3, b.3) && abs(a.1 - b.1) < 0.8 * max(a.3, b.3) {
            if [2, 4, 8, 16].contains(b.0), (1...12).contains(a.0) { return (a.0, b.0) }
        } }
        return nil
    }
}

extension SectionHeaderParser {
    /// Section marks such as 前奏 / 主歌 / Intro / Verse 1 (also without brackets).
    static func isSectionLabel(_ s: String) -> Bool {
        if parse(s) != nil { return true }
        return Rx.test(#"^(?i)\s*(前奏|间奏|尾奏|主歌|副歌|桥段|过门|尾声|结尾|intro|outro|verse|chorus|bridge|solo)\s*\d?\s*[:：]?\s*$"#, s)
    }
}
