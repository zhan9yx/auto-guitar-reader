import Foundation
import AGRCore

/// Lightweight index entry for a score package (what the library list shows).
struct ScoreSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var artist: String?
    var key: String?
    var mode: PlayMode
    var updatedAt: Date
    var hasPages: Bool

    init(score: Score, updatedAt: Date = Date()) {
        self.id = score.id
        self.title = score.meta.title
        self.artist = score.meta.artist
        self.key = score.meta.key
        self.mode = score.meta.mode
        self.updatedAt = updatedAt
        self.hasPages = !score.pages.isEmpty
    }

    var displayTitle: String { title.isEmpty ? "未命名曲谱" : title }
}
