import Foundation

// MARK: - Watermark / non-score content
//
// (a) text: `OMRWatermark.isNonScoreText` classifies OCR tokens. Strong signals (URLs, QR overlap, phone / QQ numbers,
//     huge diagonal boxes) apply everywhere. Weak ones (微信/公众号/扫码/淘宝/版权 phrases, page numbers, text repeated on other
//     pages, text outside the music) only apply to tokens OUTSIDE every system band: inside a system's vertical band
//     (chord names, jianpu, lyric rows) a phrase substring is far more likely a lyric than an ad.
// (b) pixels: `OMRWatermark.clean` removes pale / semi-transparent / wide-stroke overlays and QR codes from the image
//     while keeping the thin black notation (see OMRWatermarkPixels.swift).

/// Optional colour page (RGB, 8 bit interleaved). The OMR pipeline itself works on `GrayImage`; colour is only used to
/// find pale coloured overlays and logos.
public struct OMRRGBImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]       // r,g,b,r,g,b...
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3)
        self.width = width; self.height = height; self.pixels = pixels
    }
    public var gray: GrayImage {
        var g = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(pixels[3 * i]), gg = Int(pixels[3 * i + 1]), b = Int(pixels[3 * i + 2])
            g[i] = UInt8((299 * r + 587 * gg + 114 * b) / 1000)
        }
        return GrayImage(width: width, height: height, pixels: g)
    }
    /// P6 binary PPM.
    public static func decodePPM(_ data: Data) -> OMRRGBImage? {
        let b = [UInt8](data)
        var pos = 0
        func skip() { while pos < b.count { if b[pos] == 35 { while pos < b.count && b[pos] != 10 { pos += 1 } } else if b[pos] <= 32 { pos += 1 } else { break } } }
        func int() -> Int? { skip(); var v = 0, n = 0; while pos < b.count, b[pos] >= 48, b[pos] <= 57 { v = v * 10 + Int(b[pos] - 48); pos += 1; n += 1 }; return n == 0 ? nil : v }
        guard b.count > 2, b[0] == 80, b[1] == 54 else { return nil }
        pos = 2
        guard let w = int(), let h = int(), let mv = int(), mv == 255 else { return nil }
        pos += 1
        guard b.count - pos >= w * h * 3 else { return nil }
        return OMRRGBImage(width: w, height: h, pixels: Array(b[pos..<(pos + w * h * 3)]))
    }
}

public struct OMRTextContext: Sendable {
    public var pageIndex = 0
    public var pageWidth = 1000.0, pageHeight = 1500.0
    /// Staff line spacing in pixels (u).
    public var staffSpacing = 12.0
    /// Top of the first system (pixels); header text lies above.
    public var firstSystemTop: Double?
    /// Bottom of the last system including jianpu / lyric rows (pixels).
    public var lastSystemBottom: Double?
    /// Normalised texts (see `OMRWatermark.key`) that occur on other pages as well.
    public var repeatedElsewhere: Set<String> = []
    /// Vertical extent (pixels) of every system: from the top of its chord-name band down through its lyric rows.
    /// A token centred in one of these is music or lyrics and can only be removed by a strong signal.
    public var systemBands: [ClosedRange<Double>] = []
    /// QR-code boxes found on the page (pixels).
    public var qrRects: [OMRPixelBox] = []
    public init() {}
}

public struct OMRPixelBox: Sendable, Equatable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public init(x0: Double, y0: Double, x1: Double, y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
}

public enum OMRNonScoreReason: String, Sendable {
    case url, phrase, phoneNumber, pageNumber, outsideSystems, repeated, hugeBox, pageHeader, qrCode
}

public enum OMRWatermark {
    // MARK: Text classification

    static let urlRx = #"(?i)(https?:|www\.|[a-z0-9][a-z0-9\-]*\.(?:com|cn|net|org|cc|top|io|tv|me|info)\b|\.(?:com|cn|net)\b|taobao\.com|\\\\|//[a-z])"#
    static let phrases: [String] = [
        "微信", "公众号", "公眾號", "扫码", "扫一扫", "扫描", "二维码", "关注", "淘宝", "天猫", "店铺", "官方店", "版权", "版權",
        "转载", "轉載", "盗版", "盜版", "必究", "侵权", "严禁", "禁止转", "请勿", "未经", "获取更多", "更多吉他谱", "更多谱", "更多原版",
        "输入歌名", "回复歌名", "教学视频", "加入我们", "在线交流", "哔哩", "优酷", "抖音", "微博", "网易云", "订购", "答疑",
        "吉他专家", "谱集", "音乐是一种生活方式", "是一种生活方式", "专业教师", "老师在线", "视频教学", "视频课程", "扫码关注", "原创制谱", "学习交流", "仅供学习", "商业用途", "请支持", "下载", "关注我",
    ]
    /// Matched as whole words only ("scan" must not hit "scandal"). Bare "scan" / "follow" are ordinary English
    /// (titles, lyrics), so only their call-to-action forms are listed.
    static let latinPhrases = ["wechat", "weixin", "taobao", "tmall", "bilibili", "youtube", "tiktok", "scan qr", "scan to", "scan the", "scan me",
                               "follow us", "follow our", "copyright", "©", "all rights"]

    /// True when `phrase` occurs in `text` with no ASCII letter or digit directly before or after it.
    static func containsWord(_ text: String, _ phrase: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: phrase, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            func word(_ c: Character?) -> Bool { c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
            if !word(before) && !word(after) { return true }
            from = r.upperBound
        }
        return false
    }

    /// Vertical band of each system, top to bottom: the chord-name band above the staff (10.5u, the chord reader's reach)
    /// down to the next system's chord band, and for the last system 12u below the staff (jianpu + lyric rows, the same
    /// extent `lastSystemBottom` uses) plus the 3.5u margin the `outsideSystems` rule leaves. Bands do not overlap.
    static func systemBands(staves: [TabStaff]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for (i, st) in staves.enumerated() {
            let top = i == 0 ? st.top - 10.5 * st.u : out[i - 1].upperBound
            var bottom = st.bottom + 15.5 * st.u
            if i + 1 < staves.count { bottom = max(st.bottom, staves[i + 1].top - 10.5 * staves[i + 1].u) }
            out.append(min(top, st.top)...max(bottom, st.bottom))
        }
        return out
    }

    /// Normalised comparison key for repeated-text detection.
    public static func key(_ s: String) -> String {
        ChordNameNormalizer.foldWidth(s).lowercased().filter { !$0.isWhitespace && !"-–—~_·.,，。:：|".contains($0) }
    }

    static func looksLikeChordOrDigits(_ t: String) -> Bool {
        let f = ChordNameNormalizer.foldWidth(t).filter { !$0.isWhitespace }
        if f.isEmpty { return true }
        if f.allSatisfy({ $0.isNumber || "-–—~.|:()[]xXoO×/".contains($0) }) && (f.count <= 3 || f.contains(where: { "xXoO×".contains($0) })) { return true }
        return OMRChordReader.cleanName(f) != nil
    }

    /// Reason when the token is not part of the score, nil when it should be kept.
    public static func isNonScoreText(_ token: OCRToken, context c: OMRTextContext) -> OMRNonScoreReason? {
        let raw = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let t = ChordNameNormalizer.foldWidth(raw)
        let tl = t.lowercased()
        let H = c.pageHeight, W = c.pageWidth
        let cy = (token.y + token.height / 2) * H, cx = (token.x + token.width / 2) * W
        let h = token.height * H
        _ = cx
        // Inside a system's band (chord names, jianpu, lyrics) only strong signals may remove a token.
        let inSystem = c.systemBands.contains { $0.contains(cy) }

        // ---- strong signals: valid anywhere
        if Rx.test(urlRx, t) { return .url }
        let tx0 = token.x * W, tx1 = (token.x + token.width) * W, ty0 = token.y * H, ty1 = (token.y + token.height) * H
        if c.qrRects.contains(where: { max($0.x0, tx0) < min($0.x1, tx1) && max($0.y0, ty0) < min($0.y1, ty1) }) { return .qrCode }
        let compact = t.filter { !$0.isWhitespace && $0 != "-" }
        // phone / QQ numbers (jianpu rows are digit strings too, but only use 0...7)
        if Rx.test(#"^1[3-9]\d{9}$"#, compact) && compact.contains(where: { $0 == "8" || $0 == "9" }) { return .phoneNumber }
        if Rx.test(#"(?i)(微信|wx|qq|电话|tel|手机)\s*[:：]?\s*\d{5,}"#, t) { return .phoneNumber }
        if Rx.test(#"(?i)^\s*(qq|q\.q\.)\s*[:：]?\s*\d{5,}"#, t) { return .phoneNumber }
        // ---- weak signals: header, footer and margins only
        if !inSystem {
            for p in phrases where t.contains(p) { return .phrase }
            for p in latinPhrases where containsWord(tl, p) { return .phrase }
        }

        // page numbers: bare numbers in the outer margins, "第1页", "Page 1", "1/2", "- 1 -"
        let pageRx = #"(?i)^\s*(?:第\s*\d{1,3}\s*页|page\s*\d{1,3}|p\.?\s*\d{1,3}|页码\s*[:：]?\s*\d{1,3}|[-–—~]?\s*\d{1,3}\s*[-–—~]?|\d{1,3}\s*/\s*\d{1,3}|\d{1,3}\s*of\s*\d{1,3})\s*$"#
        if !inSystem, Rx.test(pageRx, t) {
            let nearBottom = cy > 0.9 * H
            let nearTop = cy < 0.035 * H
            if nearBottom || nearTop { return .pageNumber }
            if Rx.test(#"(?i)(第|page|页码|of|/)"#, t) { return .pageNumber }
        }
        // rotated watermark text: boxes of several characters that are as tall as wide (horizontal text is n times wider than tall)
        let cjk = Double(t.filter { $0.isCJK }.count), lat = Double(t.filter { $0.isLetter && !$0.isCJK }.count)
        let expectedAspect = cjk + 0.55 * lat
        let bw = token.width * W
        if h > 4 * c.staffSpacing, expectedAspect >= 3, bw / max(1, h) < 0.55 * expectedAspect, bw / max(1, h) > 0.5 { return .hugeBox }
        // rotated watermark text produces huge boxes
        if h > 9 * c.staffSpacing && token.width * W > 5 * c.staffSpacing { return .hugeBox }
        // page header repeated from page 2 on: "title - artist" in a thin strip at the very top
        if !inSystem, c.pageIndex > 0, cy < 0.09 * H, (c.firstSystemTop.map { $0 - cy > 6 * c.staffSpacing } ?? true), !Rx.test(#"[=:：]"#, t),
           let g = Rx.firstMatch(#"^(.{1,30}?)\s?[-–—]\s?(.{1,30})$"#, in: t), (g[1] ?? "").filter({ $0.isLetter }).count >= 2, (g[2] ?? "").filter({ $0.isLetter }).count >= 2 { return .pageHeader }
        // outside the music: below the last system (footers, banners)
        if !inSystem, let b = c.lastSystemBottom, cy > max(b + 3.5 * c.staffSpacing, 0.86 * H), !looksLikeChordOrDigits(raw) { return .outsideSystems }
        if !inSystem, c.repeatedElsewhere.contains(key(raw)), !looksLikeChordOrDigits(raw), raw.count >= 3 { return .repeated }
        return nil
    }

    /// Texts that occur on several pages (page headers, site names): candidates for `OMRTextContext.repeatedElsewhere`.
    public static func repeatedTexts(pages: [[OCRToken]]) -> [Set<String>] {
        var counts: [String: Int] = [:]
        for p in pages { for k in Set(p.map { key($0.text) }) where k.count >= 3 { counts[k, default: 0] += 1 } }
        return pages.map { p in Set(p.map { key($0.text) }.filter { (counts[$0] ?? 0) >= 2 }) }
    }
}
