import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AGRCore

enum AITestSupport {
    static func melody(_ durations: [Double], lyrics: [String] = []) -> [MelodyNote] {
        var beat = 0.0
        var out: [MelodyNote] = []
        for (i, d) in durations.enumerated() {
            out.append(MelodyNote(beat: beat, duration: d, degree: (i % 7) + 1, lyrics: i < lyrics.count ? [lyrics[i]] : []))
            beat += d
        }
        return out
    }

    /// Two measures; measure 1 has a beat-sum error (3 beats of melody in 4/4).
    static func score() -> Score {
        let m0 = NotationMeasure(chords: [ChordMark(name: "G")],
                                 tab: [TabEvent(beat: 0, duration: 2, notes: [.chordTone(string: 6), .chordTone(string: 3)]),
                                       TabEvent(beat: 2, duration: 2, notes: [TabNote(string: 2, fret: 3)])],
                                 melody: melody([1, 1, 1, 1], lyrics: ["我", "曾", "经", "跨"]))
        let m1 = NotationMeasure(chords: [ChordMark(name: "Cx")], melody: melody([1, 1, 1], lyrics: ["过", "山", "和"]))
        let line = Line(id: "l0", kind: .system, system: NotationSystem(measures: [m0, m1]))
        return Score(meta: ScoreMeta(title: "T", key: "G"), sections: [Section(id: "s0", name: "主歌", kind: .verse, lines: [line])])
    }

    static func issue(_ id: String = "i1", path: String = "sections[0].lines[0].system.measures[1]",
                      kind: AIIssueKind = .beatSumMismatch, crop: Data? = nil) -> AIIssue {
        AIIssue(id: id, kind: kind, path: path, message: "melody sums to 3 beats, expected 4",
                context: "m1: Cx | mel 1(0+1) 2(1+1) 3(2+1)", ocrSnippets: ["过山和"], imageCrop: crop)
    }

    static let fixPatch = """
    {"ops":[{"op":"insert","path":"sections[0].lines[0].system.measures[1].melody[-]","value":{"beat":3,"duration":1,"degree":4,"lyrics":["海"]},"issue":"i1"}],"notes":"add missing note"}
    """

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agr-ai-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// Scripted transport: returns queued (status, headers, body) tuples and records requests.
final class MockTransport: AIHTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body: String }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    private func next(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? Reply(status: 500, body: "{}") : replies.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = next(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (Data(r.body.utf8), resp)
    }
}

func completionBody(_ content: String) -> String {
    let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
    return #"{"model":"m-x","choices":[{"message":{"role":"assistant","content":\#(escaped)}}]}"#
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []
    func add(_ v: TimeInterval) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _values }
}
