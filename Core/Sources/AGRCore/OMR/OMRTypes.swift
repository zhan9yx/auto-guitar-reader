import Foundation

public struct OMROptions: Sendable {
    /// Collect per-page debug overlays (slower).
    public var debug = false
    /// Drop text recognised as watermark / ad / page number from credits.
    public var removeWatermarkText = true
    public init() {}
}

public enum OMRIssueKind: String, Codable, Sendable {
    case beatSumMismatch, lowConfidenceGlyph, unknownChord, lyricAlignment, suspectedWatermark
    case noStaff, barlineMismatch, chordShapeUnread, jianpuUnread, headerMissing, stringAmbiguous
}

/// Problem found by the engine; convertible to the AI-assist `AIIssue` contract
/// `{ id, kind, path, message, context, ocrSnippets, imageCrop? }`.
public struct OMRIssue: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: OMRIssueKind
    /// JSON path into the Score, e.g. "sections[0].lines[2].system.measures[3].tab[1]".
    public var path: String
    public var message: String
    /// Short textual description of the surrounding recognised content.
    public var context: String
    public var ocrSnippets: [String]
    /// Normalised crop of the page the issue refers to (page, x, y, w, h in 0...1).
    public var imageCrop: OMRCrop?
    public var confidence: Double

    public init(id: String = UUID().uuidString, kind: OMRIssueKind, path: String, message: String,
                context: String = "", ocrSnippets: [String] = [], imageCrop: OMRCrop? = nil, confidence: Double = 0) {
        self.id = id; self.kind = kind; self.path = path; self.message = message
        self.context = context; self.ocrSnippets = ocrSnippets; self.imageCrop = imageCrop; self.confidence = confidence
    }
}

public struct OMRCrop: Codable, Hashable, Sendable {
    public var page: Int, x: Double, y: Double, width: Double, height: Double
    public init(page: Int, x: Double, y: Double, width: Double, height: Double) {
        self.page = page; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct OMRReport: Codable, Sendable {
    public var issues: [OMRIssue] = []
    /// Mean confidence per element class ("tab", "melody", "lyrics", "chords", "shapes", "header").
    public var confidence: [String: Double] = [:]
    public var pageCount = 0
    public var systemCount = 0
    public var milliseconds: Double = 0
    /// Text tokens judged to be watermark / non-score content.
    public var removedText: [String] = []
    public init() {}
    /// True when at least one tab system was found.
    public var foundSystems: Bool { systemCount > 0 }
}
