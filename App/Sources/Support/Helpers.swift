import SwiftUI
import UniformTypeIdentifiers
import AGRCore

// NOTE: AGRCore declares a model type named `Section`, and SwiftUI declares a view
// named `Section`. In any file that imports both modules, never write an unqualified
// `Section`: use `ScoreSection` (model) or `SwiftUI.Section` (view).
typealias ScoreSection = AGRCore.Section

// MARK: - Display helpers

enum ScoreDisplayMode: String, CaseIterable, Identifiable {
    case text
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "文本谱"
        case .image: return "原图谱"
        }
    }
}

extension PlayMode {
    var displayName: String {
        switch self {
        case .strumSing: return "弹唱"
        case .fingerstyle: return "指弹"
        }
    }
}

// MARK: - Transposition helpers

enum TransposeHelper {
    /// Chord name shown after transposing `semitones` (keeps the written string if it is not a chord).
    static func displayName(for written: String, semitones: Int, preferFlats: Bool? = nil) -> String {
        guard semitones != 0 else { return written }
        guard let chord = ChordSymbol(written) else { return written }
        return chord.transposed(by: semitones, preferFlats: preferFlats).description
    }

    /// Flat/sharp spelling preference derived from the transposed key (nil = keep each chord's own spelling).
    static func preferFlats(forKey key: String?, semitones: Int) -> Bool? {
        guard semitones != 0, let key = key, let symbol = ChordSymbol(key) else { return nil }
        let target = symbol.transposed(by: semitones)
        let minorQualities: [ChordSymbol.Quality] = [.minor, .min7, .min6, .minAdd9, .min9, .min11, .minMaj7]
        let isMinor = minorQualities.contains(target.quality)
        let majorRoot = isMinor ? (target.root + 3) % 12 : target.root
        let flatMajorRoots: [Int] = [5, 10, 3, 8, 1]
        return flatMajorRoots.contains(majorRoot)
    }

    /// "G" / "G → A" style label for the key.
    static func keyLabel(original: String?, semitones: Int) -> String {
        guard let original = original, !original.isEmpty else {
            return semitones == 0 ? "原调" : "移调 \(signed(semitones))"
        }
        if semitones == 0 { return original }
        let flats = preferFlats(forKey: original, semitones: semitones)
        let current = displayName(for: original, semitones: semitones, preferFlats: flats)
        return "\(original) → \(current)"
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

// MARK: - Score statistics

enum ScoreStats {
    static func chordCount(_ score: Score) -> Int {
        var count = 0
        for section in score.sections {
            for line in section.lines {
                for segment in line.segments where segment.chord != nil {
                    count += 1
                }
                if let block = line.tab {
                    for measure in block.measures {
                        for event in measure.events where event.chord != nil {
                            count += 1
                        }
                    }
                }
            }
        }
        return count
    }

    static func lineCount(_ score: Score) -> Int {
        score.sections.reduce(0) { $0 + $1.lines.count }
    }

    static func tabLineCount(_ score: Score) -> Int {
        var count = 0
        for section in score.sections {
            for line in section.lines where line.kind == .tab {
                count += 1
            }
        }
        return count
    }
}

// MARK: - Page data

extension Score {
    /// Drops the original page images' metadata together with the per-line page anchors that point into them
    /// (text-only copies: `.agr` imports, community downloads whose images could not be fetched).
    mutating func removePageData() {
        pages = []
        for sectionIndex in sections.indices {
            for lineIndex in sections[sectionIndex].lines.indices {
                sections[sectionIndex].lines[lineIndex].anchor = nil
            }
        }
    }
}

// MARK: - Errors

func describeError(_ error: Error) -> String {
    if let communityError = error as? CommunityError {
        switch communityError {
        case .http(let status, let detail):
            if let detail = detail, !detail.trimmed.isEmpty {
                return "服务器返回错误（\(status)）：\(detail)"
            }
            return "服务器返回错误（\(status)）"
        case .decoding:
            return "无法解析服务器返回的数据，请确认服务器地址指向社区服务"
        case .invalidURL:
            return "服务器地址无效，请在“设置”中检查。"
        }
    }
    if let importError = error as? ImportError {
        switch importError {
        case .unsupportedFormat(let detail):
            return "不支持的文件格式（\(detail)）"
        case .empty:
            return "内容为空，没有识别到可用的谱面"
        case .malformed(let detail):
            return "文件内容有误：\(detail)"
        @unknown default:
            return "导入失败"
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return "无法连接社区服务器，请检查网络以及“设置”中的服务器地址"
        default:
            return urlError.localizedDescription
        }
    }
    return error.localizedDescription
}

// MARK: - Small utilities

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// File name without its (last) extension.
    var baseFileName: String {
        let name = (self as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }
}

extension Binding where Value == String? {
    /// Binds an optional string to a non-optional one (empty string <-> nil).
    func orEmpty() -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? "" },
            set: { newValue in self.wrappedValue = newValue.isEmpty ? nil : newValue }
        )
    }
}

// MARK: - Uniform type identifiers

extension UTType {
    /// `.agr` score package JSON (declared in Info.plist as an exported type).
    static let agrScore = UTType(exportedAs: "io.github.zhan9yx.agr-score", conformingTo: .json)
    /// ChordPro text (declared in Info.plist as an exported type: the identifier is in our own namespace).
    static let chordPro = UTType(exportedAs: "io.github.zhan9yx.chordpro", conformingTo: .plainText)
}

enum ImportTypes {
    /// Content types accepted by the Files importer.
    static var allowed: [UTType] {
        var types: [UTType] = [.plainText, .text, .json, .pdf, .image, .xml, .agrScore, .chordPro]
        let extensions = ["cho", "chopro", "chordpro", "pro", "crd", "agr", "musicxml", "mxl", "txt"]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }
}
