import XCTest
import Foundation
@testable import AGRCore

/// End-to-end test against a running community server.
/// Skipped unless `AGR_COMMUNITY_URL` is set, e.g.
///   AGR_COMMUNITY_URL=http://127.0.0.1:8765 swift test --filter CommunityIntegrationTests
final class CommunityIntegrationTests: XCTestCase {
    func testUploadSearchFetchReportAgainstRealServer() async throws {
        guard let raw = ProcessInfo.processInfo.environment["AGR_COMMUNITY_URL"], let url = URL(string: raw) else {
            throw XCTSkip("AGR_COMMUNITY_URL not set")
        }
        let run = String(UUID().uuidString.prefix(8)).lowercased()
        let client = CommunityClient(baseURL: url, deviceID: "swift-it-\(run)", nickname: "测试用户 \(run)")
        let title = "集成测试曲目\(run)"

        var score = Score(meta: ScoreMeta(title: title, artist: "周杰伦", key: "G", mode: .strumSing),
                          sections: [Section(id: "v1", name: "主歌", kind: .verse,
                                             lines: [Line(kind: .lyrics, segments: [ChordSegment(chord: "G", text: "窗外的麻雀"),
                                                                                     ChordSegment(chord: "C", text: "在电线杆上")])])])
        score.pages = [PageImage(fileName: "page-0.jpg", width: 10, height: 20)]
        let image = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        // upload
        let summary = try await client.upload(score: score, assets: [(name: "page-0.jpg", data: image, mimeType: "image/jpeg")])
        XCTAssertEqual(summary.title, title)
        XCTAssertEqual(summary.artist, "周杰伦")
        XCTAssertEqual(summary.uploader, "测试用户 \(run)")
        XCTAssertEqual(summary.pageCount, 1)
        XCTAssertNotEqual(summary.id.lowercased(), score.id.uuidString.lowercased(), "server must assign its own id")
        XCTAssertLessThan(abs(summary.createdAt.timeIntervalSinceNow), 120)

        // search: exact title, Chinese substring, pinyin of artist, initials
        let byTitle = try await client.search(query: title)
        XCTAssertTrue(byTitle.items.contains { $0.id == summary.id })
        let byArtistPinyin = try await client.search(query: "zhoujielun", sort: .popular, page: 1, pageSize: 50)
        XCTAssertTrue(byArtistPinyin.items.contains { $0.id == summary.id })
        let byInitials = try await client.search(query: "jccsqm\(run)")
        XCTAssertTrue(byInitials.items.contains { $0.id == summary.id }, "pinyin initials of the title should match")
        XCTAssertGreaterThanOrEqual(byTitle.total, 1)
        let none = try await client.search(query: "zzz-no-such-song-\(run)")
        XCTAssertEqual(none.total, 0)

        // fetch score + asset
        let fetched = try await client.fetchScore(id: summary.id)
        XCTAssertEqual(fetched.id.uuidString.lowercased(), summary.id.lowercased())
        XCTAssertEqual(fetched.meta.title, title)
        XCTAssertEqual(fetched.sections, score.sections)
        XCTAssertEqual(fetched.pages, score.pages)
        let asset = try await client.fetchAsset(scoreID: summary.id, name: "page-0.jpg")
        XCTAssertEqual(asset, image)
        let after = try await client.search(query: title)
        XCTAssertEqual(after.items.first { $0.id == summary.id }?.downloads, 1)

        // errors
        do {
            _ = try await client.fetchScore(id: UUID().uuidString.lowercased())
            XCTFail("expected 404")
        } catch let error as CommunityError {
            XCTAssertEqual(error, .http(status: 404, detail: "score not found"))
        }
        do {
            _ = try await client.upload(score: Score(meta: ScoreMeta(title: "  ")), assets: [])
            XCTFail("expected 400")
        } catch let error as CommunityError {
            guard case .http(let status, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 400)
            XCTAssertNotNil(detail)
        }
        do {
            _ = try await client.fetchAsset(scoreID: summary.id, name: "../../etc/passwd")
            XCTFail("expected 404")
        } catch let error as CommunityError {
            guard case .http(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 404)
        }

        // report
        try await client.report(scoreID: summary.id, reason: "集成测试举报")
        do {
            try await client.report(scoreID: UUID().uuidString.lowercased(), reason: "x")
            XCTFail("expected 404")
        } catch let error as CommunityError {
            XCTAssertEqual(error, .http(status: 404, detail: "score not found"))
        }
    }
}
