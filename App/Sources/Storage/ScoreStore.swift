import Foundation
import Observation
import UIKit
import AGRCore

enum ScoreStoreError: LocalizedError {
    case notFound
    case invalidFileName(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "找不到这份曲谱"
        case .invalidFileName(let name): return "无效的文件名：\(name)"
        }
    }
}

/// On-disk score library: `<root>/<uuid>/score.json` + page images, plus `<root>/index.json`.
@Observable
@MainActor
final class ScoreStore {
    static let seededDefaultsKey = "ScoreStore.didSeedSamples.v1"
    static let scoreFileName = "score.json"
    static let indexFileName = "index.json"

    let rootURL: URL
    private let defaults: UserDefaults

    /// Library index, most recently updated first.
    private(set) var summaries: [ScoreSummary] = []

    init(rootURL: URL? = nil, defaults: UserDefaults = .standard, seedSamples: Bool = false) {
        let root = rootURL ?? ScoreStore.defaultRootURL()
        self.rootURL = root
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        if seedSamples {
            seedSamplesIfNeeded()
        }
    }

    static func defaultRootURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Scores", isDirectory: true)
    }

    // MARK: Paths

    private var indexURL: URL { rootURL.appendingPathComponent(ScoreStore.indexFileName) }

    func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func pageImageURL(scoreID: UUID, name: String) -> URL? {
        guard let safe = try? ScoreStore.sanitizedFileName(name) else { return nil }
        return directory(for: scoreID).appendingPathComponent(safe)
    }

    static func sanitizedFileName(_ name: String) throws -> String {
        let last = (name as NSString).lastPathComponent
        if last.isEmpty || last == "." || last == ".." || last.lowercased() == scoreFileName {
            throw ScoreStoreError.invalidFileName(name)
        }
        return last
    }

    // MARK: Index

    /// Rebuilds `summaries` from index.json + the package directories on disk.
    func reload() {
        let fm = FileManager.default
        var known: [UUID: ScoreSummary] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? ScoreCoding.decoder().decode([ScoreSummary].self, from: data) {
            for summary in decoded {
                known[summary.id] = summary
            }
        }

        var result: [ScoreSummary] = []
        let entries = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            let scoreFile = url.appendingPathComponent(ScoreStore.scoreFileName)
            guard fm.fileExists(atPath: scoreFile.path) else { continue }
            if let summary = known[id] {
                result.append(summary)
            } else if let score = try? ScoreStore.readScore(rootURL: rootURL, id: id) {
                let attributes = try? fm.attributesOfItem(atPath: scoreFile.path)
                let modified = (attributes?[.modificationDate] as? Date) ?? Date()
                result.append(ScoreSummary(score: score, updatedAt: modified))
            }
        }
        summaries = result.sorted { $0.updatedAt > $1.updatedAt }
        persistIndex()
    }

    private func persistIndex() {
        guard let data = try? ScoreCoding.encoder().encode(summaries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func upsert(_ summary: ScoreSummary) {
        summaries.removeAll { $0.id == summary.id }
        summaries.append(summary)
        summaries.sort { $0.updatedAt > $1.updatedAt }
        persistIndex()
    }

    func summary(for id: UUID) -> ScoreSummary? {
        summaries.first { $0.id == id }
    }

    // MARK: Read

    nonisolated static func readScore(rootURL: URL, id: UUID) throws -> Score {
        let file = rootURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("score.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ScoreStoreError.notFound
        }
        let data = try Data(contentsOf: file)
        return try ScoreCoding.decode(data)
    }

    func loadScore(id: UUID) throws -> Score {
        try ScoreStore.readScore(rootURL: rootURL, id: id)
    }

    func loadPageImage(scoreID: UUID, name: String) -> UIImage? {
        guard let url = pageImageURL(scoreID: scoreID, name: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    func pageImageData(scoreID: UUID, name: String) -> Data? {
        guard let url = pageImageURL(scoreID: scoreID, name: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: Write

    /// Writes score.json (and any given page images) into the score's package directory.
    @discardableResult
    func save(score: Score, pageImages: [(name: String, data: Data)] = []) throws -> ScoreSummary {
        let dir = directory(for: score.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for image in pageImages {
            let name = try ScoreStore.sanitizedFileName(image.name)
            try image.data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        let data = try ScoreCoding.encode(score)
        try data.write(to: dir.appendingPathComponent(ScoreStore.scoreFileName), options: .atomic)
        let summary = ScoreSummary(score: score)
        upsert(summary)
        return summary
    }

    func rename(id: UUID, title: String) throws {
        var score = try loadScore(id: id)
        score.meta.title = title.trimmed
        try save(score: score)
    }

    @discardableResult
    func duplicate(id: UUID) throws -> ScoreSummary {
        var score = try loadScore(id: id)
        let newID = UUID()
        let fm = FileManager.default
        try fm.copyItem(at: directory(for: id), to: directory(for: newID))
        score.id = newID
        score.meta.title = (score.meta.title.isEmpty ? "未命名曲谱" : score.meta.title) + " 副本"
        return try save(score: score)
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        summaries.removeAll { $0.id == id }
        persistIndex()
    }

    // MARK: Samples

    func seedSamplesIfNeeded() {
        guard !defaults.bool(forKey: ScoreStore.seededDefaultsKey) else { return }
        defaults.set(true, forKey: ScoreStore.seededDefaultsKey)
        restoreSamples()
    }

    /// (Re)creates the built-in demo scores (stable ids, so this never duplicates them).
    func restoreSamples() {
        for sample in SampleScores.all {
            _ = try? save(score: sample)
        }
    }
}
