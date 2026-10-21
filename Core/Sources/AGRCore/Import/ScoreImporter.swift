import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Text decoding

/// Decodes raw file data: UTF-8 (with/without BOM), UTF-16 (BOM or detected), GB18030/GBK fallback, Latin-1 last.
enum TextDecoder {
    static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        // NUL bytes never occur in UTF-8 text, so check the UTF-16 zero-byte pattern first.
        if let enc = bomlessUTF16(data), let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = GB18030.decode(data) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Detects UTF-16 without BOM by the zero-byte pattern typical of ASCII-heavy text.
    private static func bomlessUTF16(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(400))
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, byte) in sample.enumerated() where byte == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
        let pairs = sample.count / 2
        if oddZeros * 3 >= pairs && evenZeros == 0 { return .utf16LittleEndian }
        if evenZeros * 3 >= pairs && oddZeros == 0 { return .utf16BigEndian }
        return nil
    }
}

/// GB18030 decoding. Apple platforms: CFString encoding 0x80000632 via `String.Encoding`.
/// Linux: swift-corelibs-foundation does not implement it, so glibc `iconv` is used when available.
enum GB18030 {
    static let encoding = String.Encoding(rawValue: 0x8000_0632)

    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: encoding) { return s }
        #if canImport(Glibc)
        return iconvDecode(data, from: "GB18030") ?? iconvDecode(data, from: "GBK")
        #else
        return nil
        #endif
    }

    #if canImport(Glibc)
    private static func iconvDecode(_ data: Data, from charset: String) -> String? {
        let cd = iconv_open("UTF-8", charset)
        guard cd != iconv_t(bitPattern: -1) else { return nil }
        defer { iconv_close(cd) }
        var input = data.map { CChar(bitPattern: $0) }
        var output = [CChar](repeating: 0, count: data.count * 4 + 8)
        var inLeft = input.count
        var outLeft = output.count
        let status: Int = input.withUnsafeMutableBufferPointer { ib in
            output.withUnsafeMutableBufferPointer { ob in
                var ip: UnsafeMutablePointer<CChar>? = ib.baseAddress
                var op: UnsafeMutablePointer<CChar>? = ob.baseAddress
                return iconv(cd, &ip, &inLeft, &op, &outLeft)
            }
        }
        guard status != -1 else { return nil }
        let produced = output.count - outLeft
        return String(decoding: output[0..<produced].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #endif
}

// MARK: - ScoreImporter

/// Unified entry point: format detection by extension + content sniffing, then dispatch to the parsers.
public enum ScoreImporter {
    private static let chordProExtensions: Set<String> = ["cho", "chopro", "chordpro", "pro", "crd"]
    private static let directivePattern =
        #"^\s*\{\s*(?:title|t|subtitle|st|artist|composer|lyricist|arranger|key|capo|tempo|time|tuning|define|meta|comment|comment_italic|comment_box|c|ci|cb|soc|eoc|sov|eov|sob|eob|sot|eot|sog|eog|new_song|ns|start_of_\w+|end_of_\w+)\s*(?::[^}]*)?\}\s*$"#

    /// Sniff by extension then content. Text decoding: UTF-8, UTF-16 (BOM), GB18030 fallback.
    public static func detectFormat(data: Data, fileName: String?) -> ScoreFormat? {
        let name = (fileName ?? "").lowercased()
        let ext = (name as NSString).pathExtension
        if name.hasSuffix(".agr.json") { return .agr }
        if chordProExtensions.contains(ext) { return .chordpro }
        if ext == "musicxml" || ext == "mxl" { return .musicXML }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .musicXML }
        guard let text = TextDecoder.decode(data), !text.agrTrimmed.isEmpty else { return nil }
        let head = String(text.prefix(2000))
        let trimmedHead = head.agrTrimmed
        if trimmedHead.hasPrefix("<?xml") || trimmedHead.hasPrefix("<score-partwise") || trimmedHead.hasPrefix("<!DOCTYPE score") {
            if head.contains("score-partwise") || head.contains("score-timewise") || ext == "musicxml" { return .musicXML }
            return nil
        }
        if looksLikeAGR(trimmedHead) { return .agr }
        if ext == "json" { return nil }
        let fmt = detectTextFormat(text)
        if ext == "tab", fmt == .chordText, !AsciiTabParser.findGroups(in: splitLines(text)).isEmpty { return .asciiTab }
        return fmt
    }

    private static func looksLikeAGR(_ head: String) -> Bool {
        guard head.hasPrefix("{") else { return false }
        return head.contains("\"agr-score\"") || (head.contains("\"sections\"") && head.contains("\"meta\""))
    }

    /// Classifies pasted text: ChordPro (directives), ASCII tab (tab blocks and little else) or chord-over-lyrics.
    static func detectTextFormat(_ text: String) -> ScoreFormat {
        let lines = splitLines(text)
        if lines.contains(where: { Rx.test(directivePattern, $0) }) { return .chordpro }
        let groups = AsciiTabParser.findGroups(in: lines)
        guard !groups.isEmpty else { return .chordText }
        var content = 0
        for (i, line) in lines.enumerated() {
            let t = line.agrTrimmed
            if t.isEmpty || groups.contains(where: { $0.contains(i) }) { continue }
            if groups.contains(where: { $0.lowerBound == i + 1 }) && ChordLineParser.parse(line) != nil { continue }
            if !MetaLineParser.parse(line).isEmpty || SectionHeaderParser.parse(line) != nil { continue }
            content += 1
        }
        return content <= 2 ? .asciiTab : .chordText
    }

    public static func importData(_ data: Data, fileName: String?) throws -> Score {
        guard !data.isEmpty else { throw ImportError.empty }
        guard let format = detectFormat(data: data, fileName: fileName) else {
            let ext = ((fileName ?? "") as NSString).pathExtension
            if TextDecoder.decode(data)?.agrTrimmed.isEmpty == true { throw ImportError.empty }
            throw ImportError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
        }
        var score: Score
        switch format {
        case .agr:
            do {
                var raw = data
                if raw.starts(with: [0xEF, 0xBB, 0xBF]) { raw = raw.dropFirst(3) }
                score = try ScoreCoding.decode(raw)
            } catch {
                throw ImportError.malformed("invalid AGR JSON: \(error.localizedDescription)")
            }
            return score
        case .musicXML:
            score = try MusicXMLParser.parse(data)
        case .chordpro, .chordText, .asciiTab:
            guard let text = TextDecoder.decode(data) else { throw ImportError.malformed("cannot decode text") }
            score = try parse(text, as: format)
        }
        var source = score.meta.source ?? ScoreSource(kind: .manual)
        source.fileName = fileName
        source.importedAt = Date()
        score.meta.source = source
        if score.meta.title.isEmpty, let fileName {
            score.meta.title = titleFromFileName(fileName)
        }
        return score
    }

    /// Pasted text (chordpro / chord-over-lyrics / ascii tab, auto-detected; may be mixed).
    public static func importText(_ text: String, title: String? = nil) throws -> Score {
        guard !text.agrTrimmed.isEmpty else { throw ImportError.empty }
        var score = try parse(text, as: detectTextFormat(text))
        if score.meta.title.isEmpty, let title, !title.agrTrimmed.isEmpty { score.meta.title = title.agrTrimmed }
        return score
    }

    private static func parse(_ text: String, as format: ScoreFormat) throws -> Score {
        switch format {
        case .chordpro: return try ChordProParser.parse(text)
        case .asciiTab: return try AsciiTabParser.parse(text)
        default: return try ChordTextParser.parse(text)
        }
    }

    static func titleFromFileName(_ fileName: String) -> String {
        var base = (fileName as NSString).lastPathComponent
        let lower = base.lowercased()
        if lower.hasSuffix(".agr.json") { base = String(base.dropLast(9)) } else { base = (base as NSString).deletingPathExtension }
        return base
    }
}
