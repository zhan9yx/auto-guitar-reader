import Foundation

/// Layout reconstruction over OCR text boxes (the iOS app feeds Vision results; no image processing here).
///
/// Steps per page: cluster tokens into rows by vertical position → classify rows (chord row, lyric row,
/// tab-digit row, metadata, section header, title) → attach every chord to the lyric character below it
/// (per-character x positions are estimated by dividing the token box width by its display columns) →
/// write `Line.anchor` so the original image can be shown and scrolled in sync.
public enum OCRScoreReconstructor {
    /// Rebuilds a `Score` from OCR pages. Never throws: empty input yields a score without sections.
    public static func reconstruct(pages: [OCRPage], fallbackTitle: String? = nil) -> Score {
        var meta = ScoreMeta(source: ScoreSource(kind: .image))
        var builder = SectionBuilder()
        var pageImages: [PageImage] = []

        for (pageIndex, page) in pages.enumerated() {
            pageImages.append(PageImage(fileName: page.imageFileName ?? "page-\(pageIndex).jpg",
                                        width: page.pixelWidth, height: page.pixelHeight))
            var rows = OCRRowBuilder.rows(from: page.tokens)
            for i in rows.indices { rows[i].kind = OCRRowClassifier.classify(rows[i]) }
            if pageIndex == 0 { OCRRowClassifier.markTitle(in: &rows) }
            rows = OCRRowClassifier.groupTabRows(rows)
            assemble(rows: rows, page: pageIndex, meta: &meta, builder: &builder)
        }
        if meta.title.isEmpty, let t = fallbackTitle?.agrTrimmed, !t.isEmpty { meta.title = t }
        return Score(meta: meta, sections: builder.finish(), pages: pageImages)
    }

    // MARK: Assembly

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func anchor(page: Int, top: Double, bottom: Double) -> PageAnchor {
        PageAnchor(page: page, y: clamp(top), height: clamp(max(0, bottom - top)))
    }

    private static func assemble(rows: [OCRRow], page: Int, meta: inout ScoreMeta, builder: inout SectionBuilder) {
        var pending: OCRRow?
        func flushPending() {
            guard let p = pending, case .chord(let parts) = p.kind else { pending = nil; return }
            let segs = parts.map { ChordSegment(chord: $0.chord, text: "") }
            builder.add(Line(kind: .chords, segments: segs, anchor: anchor(page: page, top: p.top, bottom: p.bottom)))
            pending = nil
        }

        for row in rows {
            switch row.kind {
            case .chord:
                flushPending()
                pending = row
            case .lyric:
                if let p = pending, case .chord(let parts) = p.kind, row.top - p.bottom <= 2.0 * max(p.height, row.height) {
                    let segs = attach(parts, to: row)
                    builder.add(Line(kind: .lyrics, segments: segs, anchor: anchor(page: page, top: min(p.top, row.top), bottom: max(p.bottom, row.bottom))))
                    pending = nil
                } else {
                    flushPending()
                    let text = row.text.agrTrimmed
                    builder.add(Line(kind: .lyrics, segments: [ChordSegment(chord: nil, text: text)],
                                     anchor: anchor(page: page, top: row.top, bottom: row.bottom)))
                }
            case .header(let h):
                flushPending()
                builder.begin(name: h.name, kind: h.kind)
            case .meta(let items):
                flushPending()
                items.forEach { $0.apply(to: &meta) }
            case .title(let title, let artist):
                flushPending()
                meta.title = title
                if let artist { meta.artist = artist }
            case .tabGroup:
                flushPending()
                builder.add(Line(kind: .comment, text: "[tab]", anchor: anchor(page: page, top: row.top, bottom: row.bottom)))
            case .tabDigits, .noise, .unclassified:
                break
            }
        }
        flushPending()
    }

    /// Attaches chords to lyric characters by x position.
    private static func attach(_ parts: [OCRChordPart], to row: OCRRow) -> [ChordSegment] {
        let chars = OCRRowBuilder.lyricChars(row)
        guard !chars.isEmpty else { return parts.map { ChordSegment(chord: $0.chord, text: "") } }
        let widths = chars.map(\.width).filter { $0 > 0 }.sorted()
        let medianW = widths.isEmpty ? 0.02 : widths[widths.count / 2]
        let lastRight = (chars.last?.left ?? 0) + (chars.last?.width ?? 0)

        var placed: [(index: Int, chord: String)] = []
        for part in parts {
            let anchorX = part.left + min(part.width, medianW) / 2
            var idx = 0
            if anchorX >= lastRight + 0.25 * medianW {
                idx = chars.count
            } else {
                for (i, c) in chars.enumerated() where c.left <= anchorX { idx = i }
            }
            placed.append((idx, part.chord))
        }
        return ChordLyricMerger.segments(chars: chars.map(\.ch), chords: placed)
    }
}

// MARK: - Row model

struct OCRChordPart: Equatable {
    var chord: String
    var left: Double
    var width: Double
}

struct OCRLyricChar {
    var ch: Character
    var left: Double
    var width: Double
}

struct OCRRow {
    enum Kind {
        case unclassified
        case chord([OCRChordPart])
        case lyric
        case tabDigits
        case tabGroup
        case meta([MetaItem])
        case header(SectionHeader)
        case title(String, String?)
        case noise
    }

    var tokens: [OCRToken]
    var kind: Kind = .unclassified
    var top: Double
    var bottom: Double
    var left: Double
    var right: Double
    var height: Double
    var text: String

    var center: Double { (top + bottom) / 2 }
}

enum OCRRowBuilder {
    /// Clusters tokens into rows (top → bottom), tokens within a row sorted left → right.
    static func rows(from tokens: [OCRToken]) -> [OCRRow] {
        let usable = tokens.filter { !$0.text.agrTrimmed.isEmpty && $0.width > 0 && $0.height > 0 }
        let sorted = usable.sorted { ($0.y + $0.height / 2, $0.x) < ($1.y + $1.height / 2, $1.x) }
        var groups: [[OCRToken]] = []
        for t in sorted {
            let cy = t.y + t.height / 2
            if let last = groups.last {
                let rowCy = last.map { $0.y + $0.height / 2 }.reduce(0, +) / Double(last.count)
                let rowH = median(last.map(\.height))
                if abs(cy - rowCy) <= 0.5 * min(t.height, rowH) {
                    groups[groups.count - 1].append(t)
                    continue
                }
            }
            groups.append([t])
        }
        return groups.map(makeRow)
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    private static func makeRow(_ group: [OCRToken]) -> OCRRow {
        let toks = group.sorted { $0.x < $1.x }
        var text = ""
        var prevRight: Double?
        for t in toks {
            let cols = max(1, TextWidth.columns(t.text.agrTrimmed))
            let colW = t.width / Double(cols)
            if let pr = prevRight, t.x - pr > colW * 0.9 { text += " " }
            text += t.text.agrTrimmed
            prevRight = t.x + t.width
        }
        return OCRRow(tokens: toks,
                      top: toks.map(\.y).min() ?? 0,
                      bottom: toks.map { $0.y + $0.height }.max() ?? 0,
                      left: toks.map(\.x).min() ?? 0,
                      right: toks.map { $0.x + $0.width }.max() ?? 0,
                      height: median(toks.map(\.height)),
                      text: text)
    }

    /// Per-character horizontal boxes of a lyric row (box width divided by display columns).
    static func lyricChars(_ row: OCRRow) -> [OCRLyricChar] {
        var result: [OCRLyricChar] = []
        var prevRight: Double?
        for t in row.tokens {
            let text = t.text.agrTrimmed
            let cols = max(1, TextWidth.columns(text))
            let colW = t.width / Double(cols)
            if let pr = prevRight, t.x - pr > colW * 0.9 {
                result.append(OCRLyricChar(ch: " ", left: pr, width: t.x - pr))
            }
            var col = 0
            for ch in text {
                let w = TextWidth.columns(of: ch)
                if w == 0 { continue }
                result.append(OCRLyricChar(ch: ch, left: t.x + Double(col) * colW, width: Double(w) * colW))
                col += w
            }
            prevRight = t.x + t.width
        }
        return result
    }
}

// MARK: - Classification

enum OCRRowClassifier {
    static func classify(_ row: OCRRow) -> OCRRow.Kind {
        let folded = foldFullWidth(row.text)
        if isTabDigits(folded) { return .tabDigits }
        if let parts = chordParts(row), !parts.isEmpty { return .chord(parts) }
        let items = metaItems(folded)
        if !items.isEmpty { return .meta(items) }
        if let h = SectionHeaderParser.parse(row.text) { return .header(h) }
        if row.text.contains(where: { $0.isLetter }) { return .lyric }
        return .noise
    }

    // MARK: tab digits

    static func isTabDigits(_ folded: String) -> Bool {
        let s = folded.filter { !$0.isWhitespace }
        guard s.count >= 4 else { return false }
        let allowed = s.filter { $0.isASCII && ($0.isNumber || "-|~hpbx/\\.".contains($0)) }.count
        let digits = s.filter { $0.isASCII && $0.isNumber }.count
        return Double(allowed) / Double(s.count) >= 0.85 && (digits >= 2 || s.filter({ $0 == "-" }).count >= 4)
    }

    /// Consecutive tab-digit rows are chunked by 6 into tab groups (chunks of < 3 rows are dropped).
    static func groupTabRows(_ rows: [OCRRow]) -> [OCRRow] {
        var result: [OCRRow] = []
        var i = 0
        while i < rows.count {
            guard case .tabDigits = rows[i].kind else { result.append(rows[i]); i += 1; continue }
            var j = i
            while j < rows.count, case .tabDigits = rows[j].kind { j += 1 }
            var k = i
            while k < j {
                let end = min(k + 6, j)
                if end - k >= 3 {
                    let chunk = Array(rows[k..<end])
                    var g = chunk[0]
                    g.kind = .tabGroup
                    g.top = chunk.map(\.top).min() ?? g.top
                    g.bottom = chunk.map(\.bottom).max() ?? g.bottom
                    result.append(g)
                }
                k = end
            }
            i = j
        }
        return result
    }

    // MARK: chords

    private enum Piece { case chord(String), filler, other }

    /// Row → chord parts with estimated x boxes, or nil if fewer than 70% of the parts are chords.
    static func chordParts(_ row: OCRRow) -> [OCRChordPart]? {
        var parts: [OCRChordPart] = []
        var chordCount = 0, otherCount = 0
        for t in row.tokens {
            let text = t.text.agrTrimmed
            let cols = max(1, TextWidth.columns(text))
            let colW = t.width / Double(cols)
            for (piece, col) in ChordLineParser.tokenize(text) {
                switch normalizeOCRChord(piece) {
                case .chord(let c):
                    chordCount += 1
                    let len = max(1, TextWidth.columns(piece))
                    parts.append(OCRChordPart(chord: c, left: t.x + Double(col) * colW, width: Double(len) * colW))
                case .filler: break
                case .other: otherCount += 1
                }
            }
        }
        guard chordCount > 0, Double(chordCount) / Double(chordCount + otherCount) >= 0.7 else { return nil }
        return parts
    }

    private static func normalizeOCRChord(_ raw: String) -> Piece {
        let t = ChordNames.normalize(raw)
        if t.isEmpty || ChordNames.isFiller(t) || ChordNames.isFiller(raw) { return .filler }
        if ChordNames.isChord(t) { return .chord(t) }
        let stripped = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:'`"))
        for base in [t, stripped] where !base.isEmpty {
            for candidate in ocrVariants(base) where ChordNames.isChord(candidate) { return .chord(candidate) }
        }
        return .other
    }

    /// Common OCR confusions: `rn`→`m`, `1`/`l`/`I`/`|`/`\` used for the slash of slash chords.
    private static func ocrVariants(_ s: String) -> [String] {
        let m = s.replacingOccurrences(of: "rn", with: "m")
        let slashed = fixSlash(s)
        return [s, m, slashed, fixSlash(m)]
    }

    private static func fixSlash(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= 3 else { return s }
        for i in stride(from: chars.count - 2, to: 0, by: -1) where "1lI|\\".contains(chars[i]) && "ABCDEFG".contains(chars[i + 1]) {
            var c = chars
            c[i] = "/"
            return String(c)
        }
        return s
    }

    // MARK: metadata

    private static func metaItems(_ folded: String) -> [MetaItem] {
        let direct = MetaLineParser.parse(folded)
        if !direct.isEmpty { return direct }
        if let g = Rx.firstMatch(#"^(?:演唱者|演唱|原唱|歌手|(?i:artist|singer))\s*[:：]?\s*(\S.*)$"#, in: folded), let v = g[1] {
            return [.artist(v.agrTrimmed)]
        }
        return []
    }

    // MARK: title

    /// Marks the topmost clearly taller lyric-like row on the first page as title (unless a chord row sits right above it).
    static func markTitle(in rows: inout [OCRRow]) {
        guard let idx = rows.firstIndex(where: { if case .lyric = $0.kind { return true }; return false }) else { return }
        let row = rows[idx]
        if idx > 0, case .chord = rows[idx - 1].kind { return }
        let others = rows.indices.filter { $0 != idx }.compactMap { i -> Double? in
            switch rows[i].kind {
            case .chord, .lyric, .header: return rows[i].height
            default: return nil
            }
        }
        let isLarge: Bool
        if others.isEmpty {
            isLarge = row.top < 0.4
        } else {
            isLarge = row.height >= 1.3 * OCRRowBuilder.median(others)
        }
        guard isLarge else { return }
        var title = MetaLineParser.cleanTitle(row.text)
        var artist: String?
        for sep in [" - ", " – ", " — ", "—"] {
            if let r = title.range(of: sep) {
                let left = String(title[..<r.lowerBound]).agrTrimmed
                let right = String(title[r.upperBound...]).agrTrimmed
                if !left.isEmpty, !right.isEmpty { title = MetaLineParser.cleanTitle(left); artist = MetaLineParser.cleanTitle(right); break }
            }
        }
        rows[idx].kind = .title(title, artist)
    }
}
