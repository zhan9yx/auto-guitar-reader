import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import AGRCore

// Lazily-generated share items. Both read the score from disk inside the export closure
// so the library list never has to encode scores while rendering.

/// Shares a score package as an `.agr` JSON file.
struct AGRFileShare: Transferable {
    let rootURL: URL
    let scoreID: UUID
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .agrScore) { (item: AGRFileShare) in
            let score = try ScoreStore.readScore(rootURL: item.rootURL, id: item.scoreID)
            let data = try ScoreCoding.encode(score)
            let url = try ShareFileWriter.write(data: data, baseName: item.title, pathExtension: "agr")
            return SentTransferredFile(url)
        }
    }
}

/// Shares a score as ChordPro text (`.cho`).
struct ChordProFileShare: Transferable {
    let rootURL: URL
    let scoreID: UUID
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .chordPro) { (item: ChordProFileShare) in
            let score = try ScoreStore.readScore(rootURL: item.rootURL, id: item.scoreID)
            let text = ChordProExporter.export(score)
            let url = try ShareFileWriter.write(data: Data(text.utf8), baseName: item.title, pathExtension: "cho")
            return SentTransferredFile(url)
        }
    }
}

enum ShareFileWriter {
    static func write(data: Data, baseName: String, pathExtension: String) throws -> URL {
        let cleaned = baseName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "score" : cleaned
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}
