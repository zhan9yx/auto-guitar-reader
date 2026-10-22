import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AGRCore

final class CommunityProfileTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8000")!

    func client(base: URL? = nil) -> CommunityClient {
        CommunityClient(baseURL: base ?? self.base, deviceID: "device-1234", nickname: "小明")
    }

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try CommunityClient.decode(type, from: Data(json.utf8))
    }

    func jsonObject(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    // MARK: Decoding real server JSON

    func testDecodeDefaultMeProfile() throws {
        let p = try decode(CommunityProfile.self, ProfileSamples.meDefault)
        XCTAssertEqual(p.userID.count, 10)
        XCTAssertEqual(p.nickname, "匿名")
        XCTAssertEqual(p.bio, "")
        XCTAssertNil(p.level)
        XCTAssertNil(p.avatarEmoji)
        XCTAssertNil(p.avatarURL)
        XCTAssertEqual(p.genres, [])
        XCTAssertEqual(p.stats, CommunityProfileStats(uploads: 0, downloads: 0, favoritesReceived: 0))
        XCTAssertEqual(p.favoritesCount, 0)
        XCTAssertNotNil(p.updatedAt)
        XCTAssertEqual(p.id, p.userID)
    }

    func testDecodeFullMeProfile() throws {
        let p = try decode(CommunityProfile.self, ProfileSamples.meFull)
        XCTAssertEqual(p.nickname, "小明")
        XCTAssertEqual(p.bio, "爱弹吉他\n每天一小时")
        XCTAssertEqual(p.level, .intermediate)
        XCTAssertEqual(p.genres, ["民谣", "流行"])
        XCTAssertEqual(p.avatarEmoji, "🎸")
    }

    func testDecodeAvatarProfileAndResolveURL() throws {
        let p = try decode(CommunityProfile.self, ProfileSamples.meAvatar)
        let path = try XCTUnwrap(p.avatarURL)
        XCTAssertTrue(path.hasPrefix("/api/v1/users/\(p.userID)/avatar?v="), path)
        XCTAssertEqual(try client().avatarURL(for: p)?.absoluteString, "http://127.0.0.1:8000" + path)
        let prefixed = client(base: URL(string: "https://example.com/agr/")!)
        XCTAssertEqual(try prefixed.avatarURL(for: p)?.absoluteString, "https://example.com/agr" + path)
        var none = p
        none.avatarURL = nil
        XCTAssertNil(try client().avatarURL(for: none))
    }

    func testPublicProfileHasNoPrivateFields() throws {
        let p = try decode(CommunityProfile.self, ProfileSamples.publicProfile)
        XCTAssertNil(p.updatedAt)
        XCTAssertNil(p.favoritesCount)
        XCTAssertEqual(p.stats.uploads, 1)
    }

    func testDecodeSearchWithViewerFavorites() throws {
        let r = try decode(CommunitySearchResponse.self, ProfileSamples.searchWithViewer)
        XCTAssertEqual(r.total, 2)
        let fav = try XCTUnwrap(r.items.first { $0.title == "Fav" })
        XCTAssertTrue(fav.favoritedByMe)
        XCTAssertEqual(fav.favorites, 1)
        XCTAssertEqual(fav.uploaderID?.count, 10)
        let other = try XCTUnwrap(r.items.first { $0.title == "Not" })
        XCTAssertFalse(other.favoritedByMe)
        XCTAssertEqual(other.favorites, 0)
    }

    func testDecodeListsAndFavoriteState() throws {
        XCTAssertEqual(try decode(CommunitySearchResponse.self, ProfileSamples.myFavorites).items.map(\.title), ["T1", "T2", "T0"])
        XCTAssertEqual(try decode(CommunitySearchResponse.self, ProfileSamples.userScores).items.map(\.title), ["S2", "S1"])
        XCTAssertEqual(try decode(CommunitySearchResponse.self, ProfileSamples.myScores).items.map(\.title), ["mine2", "mine1"])
        XCTAssertEqual(try decode(CommunityFavoriteState.self, ProfileSamples.favoriteState), CommunityFavoriteState(favorited: true, favorites: 1))
    }

    func testOldSummaryWithoutNewFieldsStillDecodes() throws {
        let s = try decode(CommunityScoreSummary.self, CommunitySamples.summary)
        XCTAssertNil(s.uploaderID)
        XCTAssertEqual(s.favorites, 0)
        XCTAssertFalse(s.favoritedByMe)
    }

    func testSummaryRoundTripKeepsNewFields() throws {
        let s = CommunityScoreSummary(id: "x", title: "T", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      uploaderID: "abcdef0123", favorites: 4, favoritedByMe: true)
        let data = try JSONEncoder().encode(s)
        let obj = try jsonObject(data)
        XCTAssertEqual(obj["uploader_id"] as? String, "abcdef0123")
        XCTAssertEqual(obj["favorited_by_me"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(CommunityScoreSummary.self, from: data), s)
    }

    func testUnknownLevelDegradesToNil() throws {
        let json = #"{"user_id":"0123456789","nickname":"x","bio":"","level":"wizard","genres":[],"created_at":"2026-10-21T03:11:18Z","stats":{"uploads":1,"downloads":2,"favorites_received":3}}"#
        let p = try decode(CommunityProfile.self, json)
        XCTAssertNil(p.level)
        XCTAssertEqual(p.stats.favoritesReceived, 3)
    }

    func testProfileRoundTrip() throws {
        let p = CommunityProfile(userID: "0123456789", nickname: "n", bio: "b", avatarEmoji: "🎸", level: .advanced,
                                 genres: ["rock"], createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                 updatedAt: Date(timeIntervalSince1970: 1_800_000_100), favoritesCount: 2,
                                 stats: CommunityProfileStats(uploads: 1, downloads: 2, favoritesReceived: 3))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(CommunityProfile.self, from: data), p)
    }

    func testBadProfileDateMapsToDecodingError() {
        let json = #"{"user_id":"0123456789","nickname":"x","bio":"","genres":[],"created_at":"yesterday","stats":{"uploads":0,"downloads":0,"favorites_received":0}}"#
        XCTAssertThrowsError(try decode(CommunityProfile.self, json)) {
            guard case .decoding = $0 as? CommunityError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Request builders

    func testMeRequests() throws {
        let get = try client().makeMeRequest()
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(get.url?.absoluteString, "http://127.0.0.1:8000/api/v1/me")
        XCTAssertEqual(get.value(forHTTPHeaderField: "X-Device-Id"), "device-1234")
        XCTAssertEqual(try client().makeDeleteAvatarRequest().httpMethod, "DELETE")
        XCTAssertEqual(try client().makeDeleteAvatarRequest().url?.path, "/api/v1/me/avatar")
    }

    func testUpdateMeBodyOnlyContainsSetFields() throws {
        let only = try client().makeUpdateMeRequest(CommunityProfileUpdate(bio: "新的简介"))
        XCTAssertEqual(only.httpMethod, "PUT")
        XCTAssertEqual(only.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let obj = try jsonObject(only.httpBody)
        XCTAssertEqual(Set(obj.keys), ["bio"])
        XCTAssertEqual(obj["bio"] as? String, "新的简介")

        let full = try client().makeUpdateMeRequest(CommunityProfileUpdate(
            nickname: "小明", bio: "b", avatarEmoji: .some("🎸"), level: .some(.beginner), genres: ["民谣"]))
        let f = try jsonObject(full.httpBody)
        XCTAssertEqual(f["nickname"] as? String, "小明")
        XCTAssertEqual(f["avatar_emoji"] as? String, "🎸")
        XCTAssertEqual(f["level"] as? String, "beginner")
        XCTAssertEqual(f["genres"] as? [String], ["民谣"])
    }

    func testUpdateMeClearsWithExplicitNull() throws {
        let req = try client().makeUpdateMeRequest(CommunityProfileUpdate(avatarEmoji: .some(nil), level: .some(nil)))
        let obj = try jsonObject(req.httpBody)
        XCTAssertEqual(Set(obj.keys), ["avatar_emoji", "level"])
        XCTAssertTrue(obj["avatar_emoji"] is NSNull)
        XCTAssertTrue(obj["level"] is NSNull)
        let empty = try jsonObject(try client().makeUpdateMeRequest(CommunityProfileUpdate()).httpBody)
        XCTAssertTrue(empty.isEmpty)
    }

    func testAvatarUploadMultipart() throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let req = try client().makeAvatarUploadRequest(data: image, mimeType: "image/jpeg", boundary: "BOUND")
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.path, "/api/v1/me/avatar")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=BOUND")
        let body = try XCTUnwrap(req.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"avatar\"; filename=\"avatar.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertNotNil(body.range(of: image))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        let png = try client().makeAvatarUploadRequest(data: image, mimeType: "image/png", boundary: "B")
        XCTAssertTrue(String(decoding: png.httpBody ?? Data(), as: UTF8.self).contains("filename=\"avatar.png\""))
    }

    func testUserAndListRequests() throws {
        XCTAssertEqual(try client().makeUserRequest(id: "0123456789").url?.path, "/api/v1/users/0123456789")
        XCTAssertEqual(try client().makeUserRequest(id: "a/b").url?.absoluteString, "http://127.0.0.1:8000/api/v1/users/a%2Fb")
        XCTAssertEqual(try client().makeUserScoresRequest(userID: "0123456789", page: 2, pageSize: 10).url?.absoluteString,
                       "http://127.0.0.1:8000/api/v1/users/0123456789/scores?page=2&page_size=10")
        XCTAssertEqual(try client().makeMyScoresRequest().url?.absoluteString,
                       "http://127.0.0.1:8000/api/v1/me/scores?page=1&page_size=20")
        XCTAssertEqual(try client().makeFavoritesRequest(page: 3, pageSize: 5).url?.absoluteString,
                       "http://127.0.0.1:8000/api/v1/me/favorites?page=3&page_size=5")
    }

    func testFavoriteAndDeleteRequests() throws {
        let on = try client().makeFavoriteRequest(scoreID: "abc", on: true)
        XCTAssertEqual(on.httpMethod, "POST")
        XCTAssertEqual(on.url?.path, "/api/v1/scores/abc/favorite")
        let off = try client().makeFavoriteRequest(scoreID: "abc", on: false)
        XCTAssertEqual(off.httpMethod, "DELETE")
        let del = try client().makeDeleteScoreRequest(id: "abc")
        XCTAssertEqual(del.httpMethod, "DELETE")
        XCTAssertEqual(del.url?.path, "/api/v1/scores/abc")
    }

    func testResolveServerPathRejectsUnsafeInput() {
        XCTAssertThrowsError(try client().resolve(serverPath: "//evil.example/x"))
        XCTAssertThrowsError(try client().resolve(serverPath: "http://evil.example/x"))
        XCTAssertThrowsError(try client(base: URL(string: "/rel")!).resolve(serverPath: "/api/v1/x"))
    }

    func testUpdateIsRejectedOnInvalidBase() {
        let c = client(base: URL(string: "/relative")!)
        XCTAssertThrowsError(try c.makeMeRequest())
        XCTAssertThrowsError(try c.makeFavoriteRequest(scoreID: "x", on: true))
    }
}
