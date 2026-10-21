import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AGRCore

// Sample payloads copied verbatim from the real server (server/tests output) so both sides agree.
enum CommunitySamples {
    static let summary = #"{"id":"e30942e4-bb19-4e7f-9f50-4a5917bd2f40","title":"七里香","artist":"周杰伦","key":"G","mode":"strumSing","uploader":"小明","downloads":0,"created_at":"2026-10-21T03:11:18Z","page_count":1}"#
    static let searchResponse = #"{"items":[{"id":"266532cd-c75e-494e-b30d-4c45fb2161d3","title":"Yesterday","artist":null,"key":null,"mode":"fingerstyle","uploader":"匿名","downloads":0,"created_at":"2026-10-21T03:11:18Z","page_count":0},{"id":"e30942e4-bb19-4e7f-9f50-4a5917bd2f40","title":"七里香","artist":"周杰伦","key":"G","mode":"strumSing","uploader":"小明","downloads":0,"created_at":"2026-10-21T03:11:18Z","page_count":1}],"total":2,"page":1,"page_size":20}"#
    static let notFound = #"{"detail":"score not found"}"#
}

final class CommunityClientTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8000")!

    func client(nickname: String = "小明", base: URL? = nil) -> CommunityClient {
        CommunityClient(baseURL: base ?? self.base, deviceID: "device-1234", nickname: nickname)
    }

    func sampleScore(pages: [PageImage] = []) -> Score {
        Score(meta: ScoreMeta(title: "七里香", artist: "周杰伦", key: "G"),
              sections: [Section(id: "v1", name: "主歌", kind: .verse,
                                 lines: [Line(kind: .lyrics, segments: [ChordSegment(chord: "G", text: "窗外的麻雀")])])],
              pages: pages)
    }

    // MARK: URL building

    func testSearchRequestEncodesChineseQuery() throws {
        let req = try client().makeSearchRequest(query: "七里香", sort: .popular, page: 2, pageSize: 50)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString,
                       "http://127.0.0.1:8000/api/v1/scores?q=%E4%B8%83%E9%87%8C%E9%A6%99&sort=popular&page=2&page_size=50")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "q" })?.value, "七里香")
    }

    func testSearchRequestEscapesReservedCharacters() throws {
        let req = try client().makeSearchRequest(query: "C++ & more=1", sort: .recent)
        let q = req.url!.query!
        XCTAssertTrue(q.hasPrefix("q=C%2B%2B%20%26%20more%3D1&sort=recent"), q)
        let empty = try client().makeSearchRequest(query: "")
        XCTAssertTrue(empty.url!.query!.hasPrefix("q=&sort=recent&page=1&page_size=20"))
    }

    func testBaseURLWithPathPrefixAndTrailingSlash() throws {
        let c = client(base: URL(string: "https://example.com/agr/")!)
        XCTAssertEqual(try c.makeSearchRequest(query: "a").url?.path, "/agr/api/v1/scores")
        XCTAssertEqual(try c.makeFetchScoreRequest(id: "abc").url?.absoluteString, "https://example.com/agr/api/v1/scores/abc")
    }

    func testInvalidBaseURL() {
        let c = client(base: URL(string: "/relative/path")!)
        XCTAssertThrowsError(try c.makeSearchRequest(query: "x")) { XCTAssertEqual($0 as? CommunityError, .invalidURL) }
        XCTAssertThrowsError(try c.makeFetchScoreRequest(id: "x")) { XCTAssertEqual($0 as? CommunityError, .invalidURL) }
    }

    func testFetchAssetPathIsEncoded() throws {
        let req = try client().makeFetchAssetRequest(scoreID: "id-1", name: "page 0/../x.jpg")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8000/api/v1/scores/id-1/assets/page%200%2F..%2Fx.jpg")
        XCTAssertEqual(try client().makeFetchAssetRequest(scoreID: "id-1", name: "page-0.jpg").url?.lastPathComponent, "page-0.jpg")
    }

    // MARK: Headers

    func testHeaders() throws {
        let req = try client(nickname: "小明 & friends").makeSearchRequest(query: "x")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Id"), "device-1234")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Nickname"), "%E5%B0%8F%E6%98%8E%20%26%20friends")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Nickname")?.removingPercentEncoding, "小明 & friends")
    }

    func testEmptyNicknameOmitsHeader() throws {
        let req = try client(nickname: "").makeSearchRequest(query: "x")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Nickname"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Id"), "device-1234")
    }

    func testNicknameHeaderIsPureASCII() throws {
        let req = try client(nickname: "😀日本語\nX-Evil: 1").makeSearchRequest(query: "x")
        let v = req.value(forHTTPHeaderField: "X-Nickname")!
        XCTAssertTrue(v.utf8.allSatisfy { $0 < 128 && $0 != 10 && $0 != 13 })
    }

    // MARK: Multipart

    struct Part { var headers: [String: String]; var body: Data }

    /// Parses multipart/form-data back into parts (test-side reference parser).
    func parseMultipart(_ body: Data, boundary: String) throws -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        var ranges: [Range<Data.Index>] = []
        var cursor = body.startIndex
        while let r = body.range(of: delimiter, in: cursor..<body.endIndex) {
            ranges.append(r)
            cursor = r.upperBound
        }
        XCTAssertGreaterThanOrEqual(ranges.count, 2)
        // closing delimiter is followed by "--"
        XCTAssertEqual(body[ranges.last!.upperBound..<(ranges.last!.upperBound + 2)], Data("--".utf8))
        var parts: [Part] = []
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            var chunk = body[a.upperBound..<b.lowerBound]
            XCTAssertTrue(chunk.starts(with: Data("\r\n".utf8)))
            chunk = chunk.dropFirst(2)
            XCTAssertTrue(chunk.suffix(2) == Data("\r\n".utf8))
            chunk = chunk.dropLast(2)
            let sep = try XCTUnwrap(chunk.range(of: Data("\r\n\r\n".utf8)))
            let headerText = String(decoding: chunk[chunk.startIndex..<sep.lowerBound], as: UTF8.self)
            var headers: [String: String] = [:]
            for line in headerText.components(separatedBy: "\r\n") {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            parts.append(Part(headers: headers, body: Data(chunk[sep.upperBound...])))
        }
        return parts
    }

    func testUploadMultipartStructure() throws {
        let score = sampleScore(pages: [PageImage(fileName: "page-0.jpg", width: 100, height: 200),
                                        PageImage(fileName: "page-1.png", width: 100, height: 200)])
        let img0 = Data([0xFF, 0xD8, 0xFF, 0x00, 0x0D, 0x0A, 0x2D, 0x2D, 0xFF])  // includes CRLF + "--" bytes
        let img1 = Data("PNGDATA".utf8)
        let req = try client().makeUploadRequest(score: score, assets: [
            (name: "page-0.jpg", data: img0, mimeType: "image/jpeg"),
            (name: "page-1.png", data: img1, mimeType: "image/png"),
        ], boundary: "TESTBOUNDARY123")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8000/api/v1/scores")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=TESTBOUNDARY123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Id"), "device-1234")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Nickname"), "%E5%B0%8F%E6%98%8E")

        let parts = try parseMultipart(try XCTUnwrap(req.httpBody), boundary: "TESTBOUNDARY123")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].headers["content-disposition"], #"form-data; name="score"; filename="score.json""#)
        XCTAssertEqual(parts[0].headers["content-type"], "application/json")
        let decoded = try ScoreCoding.decode(parts[0].body)
        XCTAssertEqual(decoded, score)
        XCTAssertEqual(parts[1].headers["content-disposition"], #"form-data; name="assets"; filename="page-0.jpg""#)
        XCTAssertEqual(parts[1].headers["content-type"], "image/jpeg")
        XCTAssertEqual(parts[1].body, img0)
        XCTAssertEqual(parts[2].headers["content-disposition"], #"form-data; name="assets"; filename="page-1.png""#)
        XCTAssertEqual(parts[2].headers["content-type"], "image/png")
        XCTAssertEqual(parts[2].body, img1)
    }

    func testUploadWithoutAssetsHasOnlyScorePart() throws {
        let req = try client().makeUploadRequest(score: sampleScore(), assets: [], boundary: "B")
        let parts = try parseMultipart(try XCTUnwrap(req.httpBody), boundary: "B")
        XCTAssertEqual(parts.count, 1)
    }

    func testDefaultBoundaryIsUniqueAndHeaderInjectionIsStripped() throws {
        let a = try client().makeUploadRequest(score: sampleScore(), assets: [])
        let b = try client().makeUploadRequest(score: sampleScore(), assets: [])
        XCTAssertNotEqual(a.value(forHTTPHeaderField: "Content-Type"), b.value(forHTTPHeaderField: "Content-Type"))
        let evil = try client().makeUploadRequest(score: sampleScore(),
                                                  assets: [(name: "a\"\r\nX: y.jpg", data: Data([1]), mimeType: "image/jpeg\r\nX: z")],
                                                  boundary: "B")
        let parts = try parseMultipart(try XCTUnwrap(evil.httpBody), boundary: "B")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].headers["content-type"], "image/jpegX: z")
        XCTAssertNil(parts[1].headers["x"])
    }

    func testReportRequest() throws {
        let req = try client().makeReportRequest(scoreID: "abc", reason: "垃圾内容 \"spam\"")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/scores/abc/report")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let obj = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(obj, ["reason": "垃圾内容 \"spam\""])
    }

    // MARK: DTO decoding

    func testDecodeSummaryFromServerJSON() throws {
        let s = try CommunityClient.decode(CommunityScoreSummary.self, from: Data(CommunitySamples.summary.utf8))
        XCTAssertEqual(s.id, "e30942e4-bb19-4e7f-9f50-4a5917bd2f40")
        XCTAssertEqual(s.title, "七里香")
        XCTAssertEqual(s.artist, "周杰伦")
        XCTAssertEqual(s.key, "G")
        XCTAssertEqual(s.mode, .strumSing)
        XCTAssertEqual(s.uploader, "小明")
        XCTAssertEqual(s.downloads, 0)
        XCTAssertEqual(s.pageCount, 1)
        XCTAssertEqual(s.createdAt.timeIntervalSince1970, 1_792_552_278, accuracy: 0.5)  // 2026-10-21T03:11:18Z
    }

    func testDecodeSearchResponseFromServerJSON() throws {
        let r = try CommunityClient.decode(CommunitySearchResponse.self, from: Data(CommunitySamples.searchResponse.utf8))
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.page, 1)
        XCTAssertEqual(r.pageSize, 20)
        XCTAssertEqual(r.items.count, 2)
        XCTAssertNil(r.items[0].artist)
        XCTAssertNil(r.items[0].key)
        XCTAssertEqual(r.items[0].mode, .fingerstyle)
        XCTAssertEqual(r.items[0].uploader, "匿名")
        XCTAssertEqual(r.items[1].id, "e30942e4-bb19-4e7f-9f50-4a5917bd2f40")
    }

    func testDateDecodingToleratesFractionalSecondsAndOffsets() throws {
        func date(_ s: String) throws -> Date {
            let json = #"{"id":"x","title":"t","mode":"strumSing","uploader":"u","downloads":1,"created_at":"\#(s)","page_count":0}"#
            return try CommunityClient.decode(CommunityScoreSummary.self, from: Data(json.utf8)).createdAt
        }
        let ref = try date("2026-10-21T03:11:18Z")
        XCTAssertEqual(try date("2026-10-21T03:11:18.250Z").timeIntervalSince(ref), 0.25, accuracy: 0.001)
        XCTAssertEqual(try date("2026-10-21T03:11:18.123456Z").timeIntervalSince(ref), 0.123, accuracy: 0.001)
        XCTAssertEqual(try date("2026-10-21T03:11:18+00:00").timeIntervalSince(ref), 0, accuracy: 0.001)
        XCTAssertEqual(try date("2026-10-21T11:11:18+08:00").timeIntervalSince(ref), 0, accuracy: 0.001)
    }

    func testBadDateAndMissingFieldsMapToDecodingError() {
        let badDate = #"{"id":"x","title":"t","mode":"strumSing","uploader":"u","downloads":1,"created_at":"yesterday","page_count":0}"#
        XCTAssertThrowsError(try CommunityClient.decode(CommunityScoreSummary.self, from: Data(badDate.utf8))) { error in
            guard case .decoding = error as? CommunityError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try CommunityClient.decode(CommunitySearchResponse.self, from: Data("{}".utf8))) { error in
            guard case .decoding = error as? CommunityError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try CommunityClient.decode(CommunitySearchResponse.self, from: Data("<html>".utf8)))
    }

    func testSummaryRoundTripsWithSnakeCaseKeys() throws {
        let s = try CommunityClient.decode(CommunityScoreSummary.self, from: Data(CommunitySamples.summary.utf8))
        let data = try JSONEncoder().encode(s)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["created_at"])
        XCTAssertNotNil(obj["page_count"])
        XCTAssertNil(obj["createdAt"])
        XCTAssertEqual(try CommunityClient.decode(CommunityScoreSummary.self, from: data), s)
    }

    func testServerStoredScoreDecodesAsScore() throws {
        // Shape produced by the server's GET /scores/{id} (server id substituted, rest verbatim).
        let json = #"{"format":"agr-score","version":1,"id":"e30942e4-bb19-4e7f-9f50-4a5917bd2f40","meta":{"title":"七里香","capo":0,"tempo":80,"mode":"strumSing","artist":"周杰伦","key":"G"},"sections":[{"id":"v1","name":"主歌","kind":"verse","lines":[{"id":"l1","kind":"lyrics","segments":[{"chord":"G","text":"窗外的麻雀"}]}]}],"pages":[{"fileName":"page-0.jpg","width":100,"height":200}]}"#
        let score = try ScoreCoding.decode(Data(json.utf8))
        XCTAssertEqual(score.id.uuidString.lowercased(), "e30942e4-bb19-4e7f-9f50-4a5917bd2f40")
        XCTAssertEqual(score.meta.title, "七里香")
        XCTAssertEqual(score.pages.first?.fileName, "page-0.jpg")
    }

    // MARK: Error mapping

    func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testStatusMapping() {
        XCTAssertNoThrow(try CommunityClient.checkStatus(response: response(200), data: Data()))
        XCTAssertNoThrow(try CommunityClient.checkStatus(response: response(201), data: Data()))
        XCTAssertThrowsError(try CommunityClient.checkStatus(response: response(404), data: Data(CommunitySamples.notFound.utf8))) {
            XCTAssertEqual($0 as? CommunityError, .http(status: 404, detail: "score not found"))
        }
        XCTAssertThrowsError(try CommunityClient.checkStatus(response: response(429), data: Data(#"{"detail":"upload rate limit exceeded; try again later"}"#.utf8))) {
            XCTAssertEqual($0 as? CommunityError, .http(status: 429, detail: "upload rate limit exceeded; try again later"))
        }
        XCTAssertThrowsError(try CommunityClient.checkStatus(response: response(500), data: Data("Internal Server Error".utf8))) {
            XCTAssertEqual($0 as? CommunityError, .http(status: 500, detail: nil))
        }
        XCTAssertThrowsError(try CommunityClient.checkStatus(response: response(400), data: Data(#"{"detail":"meta.title must be a non-empty string"}"#.utf8))) {
            XCTAssertEqual($0 as? CommunityError, .http(status: 400, detail: "meta.title must be a non-empty string"))
        }
        XCTAssertThrowsError(try CommunityClient.checkStatus(response: response(302), data: Data())) {
            XCTAssertEqual($0 as? CommunityError, .http(status: 302, detail: nil))
        }
    }

    func testNonStringDetailAndNonHTTPResponse() {
        XCTAssertEqual(CommunityClient.parseDetail(Data(#"{"detail":[{"msg":"bad"}]}"#.utf8)), #"[{"msg":"bad"}]"#)
        XCTAssertNil(CommunityClient.parseDetail(Data("[]".utf8)))
        XCTAssertNil(CommunityClient.parseDetail(Data()))
        let plain = URLResponse(url: base, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertThrowsError(try CommunityClient.checkStatus(response: plain, data: Data())) {
            guard case .decoding = $0 as? CommunityError else { return XCTFail("\($0)") }
        }
    }
}
