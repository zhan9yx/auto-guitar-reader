import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the community server (`server/`). Anonymous: identified by a device id + nickname.
public struct CommunityClient: Sendable {
    public let baseURL: URL
    public let deviceID: String
    public let nickname: String
    private let session: URLSession

    public init(baseURL: URL, deviceID: String, nickname: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.nickname = nickname
        self.session = session
    }

    // MARK: Public API

    public func search(query: String, sort: CommunitySort = .recent, page: Int = 1, pageSize: Int = 20) async throws -> CommunitySearchResponse {
        let request = try makeSearchRequest(query: query, sort: sort, page: page, pageSize: pageSize)
        let (data, response) = try await send(request)
        try Self.checkStatus(response: response, data: data)
        return try Self.decode(CommunitySearchResponse.self, from: data)
    }

    public func fetchScore(id: String) async throws -> Score {
        let request = try makeFetchScoreRequest(id: id)
        let (data, response) = try await send(request)
        try Self.checkStatus(response: response, data: data)
        do { return try ScoreCoding.decode(data) } catch { throw CommunityError.decoding(String(describing: error)) }
    }

    public func fetchAsset(scoreID: String, name: String) async throws -> Data {
        let request = try makeFetchAssetRequest(scoreID: scoreID, name: name)
        let (data, response) = try await send(request)
        try Self.checkStatus(response: response, data: data)
        return data
    }

    public func upload(score: Score, assets: [(name: String, data: Data, mimeType: String)]) async throws -> CommunityScoreSummary {
        let request = try makeUploadRequest(score: score, assets: assets)
        let (data, response) = try await send(request)
        try Self.checkStatus(response: response, data: data)
        return try Self.decode(CommunityScoreSummary.self, from: data)
    }

    public func report(scoreID: String, reason: String) async throws {
        let request = try makeReportRequest(scoreID: scoreID, reason: reason)
        let (data, response) = try await send(request)
        try Self.checkStatus(response: response, data: data)
    }

    // MARK: Profiles, favorites, my uploads

    public func me() async throws -> CommunityProfile {
        try await perform(makeMeRequest(), as: CommunityProfile.self)
    }

    public func updateMe(_ update: CommunityProfileUpdate) async throws -> CommunityProfile {
        try await perform(makeUpdateMeRequest(update), as: CommunityProfile.self)
    }

    /// `data` must be a JPEG or PNG of at most `CommunityProfile.maxAvatarBytes`.
    public func uploadAvatar(data: Data, mimeType: String = "image/jpeg") async throws -> CommunityProfile {
        try await perform(makeAvatarUploadRequest(data: data, mimeType: mimeType), as: CommunityProfile.self)
    }

    public func deleteAvatar() async throws -> CommunityProfile {
        try await perform(makeDeleteAvatarRequest(), as: CommunityProfile.self)
    }

    public func user(id: String) async throws -> CommunityProfile {
        try await perform(makeUserRequest(id: id), as: CommunityProfile.self)
    }

    public func userScores(userID: String, page: Int = 1, pageSize: Int = 20) async throws -> CommunitySearchResponse {
        try await perform(makeUserScoresRequest(userID: userID, page: page, pageSize: pageSize), as: CommunitySearchResponse.self)
    }

    public func myScores(page: Int = 1, pageSize: Int = 20) async throws -> CommunitySearchResponse {
        try await perform(makeMyScoresRequest(page: page, pageSize: pageSize), as: CommunitySearchResponse.self)
    }

    public func favorites(page: Int = 1, pageSize: Int = 20) async throws -> CommunitySearchResponse {
        try await perform(makeFavoritesRequest(page: page, pageSize: pageSize), as: CommunitySearchResponse.self)
    }

    @discardableResult
    public func favorite(scoreID: String) async throws -> CommunityFavoriteState {
        try await perform(makeFavoriteRequest(scoreID: scoreID, on: true), as: CommunityFavoriteState.self)
    }

    @discardableResult
    public func unfavorite(scoreID: String) async throws -> CommunityFavoriteState {
        try await perform(makeFavoriteRequest(scoreID: scoreID, on: false), as: CommunityFavoriteState.self)
    }

    /// Deletes one of my uploads (server answers 403 for scores of other users).
    public func deleteScore(id: String) async throws {
        _ = try await performRaw(makeDeleteScoreRequest(id: id))
    }

    /// Downloads avatar image bytes for a profile's server-relative `avatarURL`.
    public func fetchAvatar(for profile: CommunityProfile) async throws -> Data? {
        guard let url = try avatarURL(for: profile) else { return nil }
        return try await performRaw(baseRequest(url: url, method: "GET"))
    }

    /// Absolute avatar URL (nil when the profile has no uploaded image).
    public func avatarURL(for profile: CommunityProfile) throws -> URL? {
        guard let path = profile.avatarURL, !path.isEmpty else { return nil }
        return try resolve(serverPath: path)
    }

    // MARK: Request building (pure, testable without network)

    func makeMeRequest() throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["me"]), method: "GET")
    }

    func makeUpdateMeRequest(_ update: CommunityProfileUpdate) throws -> URLRequest {
        var request = baseRequest(url: try makeURL(pathComponents: ["me"]), method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(update) } catch { throw CommunityError.invalidURL }
        return request
    }

    func makeAvatarUploadRequest(data: Data, mimeType: String = "image/jpeg",
                                 boundary: String = "AGR-\(UUID().uuidString)") throws -> URLRequest {
        var request = baseRequest(url: try makeURL(pathComponents: ["me", "avatar"]), method: "PUT")
        var form = MultipartFormData(boundary: boundary)
        let ext = mimeType.lowercased().contains("png") ? "png" : "jpg"
        form.addFile(field: "avatar", fileName: "avatar.\(ext)", mimeType: mimeType, data: data)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }

    func makeDeleteAvatarRequest() throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["me", "avatar"]), method: "DELETE")
    }

    func makeUserRequest(id: String) throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["users", id]), method: "GET")
    }

    func makeUserScoresRequest(userID: String, page: Int = 1, pageSize: Int = 20) throws -> URLRequest {
        let url = try makeURL(pathComponents: ["users", userID, "scores"],
                              query: [("page", String(page)), ("page_size", String(pageSize))])
        return baseRequest(url: url, method: "GET")
    }

    func makeMyScoresRequest(page: Int = 1, pageSize: Int = 20) throws -> URLRequest {
        let url = try makeURL(pathComponents: ["me", "scores"], query: [("page", String(page)), ("page_size", String(pageSize))])
        return baseRequest(url: url, method: "GET")
    }

    func makeFavoritesRequest(page: Int = 1, pageSize: Int = 20) throws -> URLRequest {
        let url = try makeURL(pathComponents: ["me", "favorites"], query: [("page", String(page)), ("page_size", String(pageSize))])
        return baseRequest(url: url, method: "GET")
    }

    func makeFavoriteRequest(scoreID: String, on: Bool) throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["scores", scoreID, "favorite"]), method: on ? "POST" : "DELETE")
    }

    func makeDeleteScoreRequest(id: String) throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["scores", id]), method: "DELETE")
    }

    /// `<baseURL prefix><path>?<query>` for a server-relative path such as `/api/v1/users/x/avatar?v=3`.
    func resolve(serverPath: String) throws -> URL {
        guard serverPath.hasPrefix("/"), !serverPath.hasPrefix("//"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil, components.host != nil else { throw CommunityError.invalidURL }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        let parts = serverPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.percentEncodedPath = prefix + String(parts[0])
        components.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        guard let url = components.url else { throw CommunityError.invalidURL }
        return url
    }

    func makeSearchRequest(query: String, sort: CommunitySort = .recent, page: Int = 1, pageSize: Int = 20) throws -> URLRequest {
        let items: [(String, String)] = [
            ("q", query), ("sort", sort.rawValue), ("page", String(page)), ("page_size", String(pageSize)),
        ]
        let url = try makeURL(pathComponents: ["scores"], query: items)
        return baseRequest(url: url, method: "GET")
    }

    func makeFetchScoreRequest(id: String) throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["scores", id]), method: "GET")
    }

    func makeFetchAssetRequest(scoreID: String, name: String) throws -> URLRequest {
        baseRequest(url: try makeURL(pathComponents: ["scores", scoreID, "assets", name]), method: "GET")
    }

    func makeUploadRequest(score: Score, assets: [(name: String, data: Data, mimeType: String)],
                           boundary: String = "AGR-\(UUID().uuidString)") throws -> URLRequest {
        var request = baseRequest(url: try makeURL(pathComponents: ["scores"]), method: "POST")
        let scoreData: Data
        do { scoreData = try ScoreCoding.encode(score) } catch { throw CommunityError.decoding("cannot encode score: \(error)") }
        var form = MultipartFormData(boundary: boundary)
        form.addFile(field: "score", fileName: "score.json", mimeType: "application/json", data: scoreData)
        for asset in assets {
            form.addFile(field: "assets", fileName: asset.name, mimeType: asset.mimeType, data: asset.data)
        }
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }

    func makeReportRequest(scoreID: String, reason: String) throws -> URLRequest {
        var request = baseRequest(url: try makeURL(pathComponents: ["scores", scoreID, "report"]), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(["reason": reason]) } catch { throw CommunityError.invalidURL }
        return request
    }

    private func baseRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        if !nickname.isEmpty {
            request.setValue(Self.percentEncode(nickname), forHTTPHeaderField: "X-Nickname")
        }
        return request
    }

    /// `<baseURL>/api/v1/<components…>?<query>`; keeps any path prefix of `baseURL`.
    func makeURL(pathComponents: [String], query: [(String, String)] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil, components.host != nil else { throw CommunityError.invalidURL }
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + "/api/v1/" + pathComponents.map(Self.percentEncode).joined(separator: "/")
        components.percentEncodedQuery = query.isEmpty ? nil
            : query.map { "\(Self.percentEncode($0.0))=\(Self.percentEncode($0.1))" }.joined(separator: "&")
        guard let url = components.url else { throw CommunityError.invalidURL }
        return url
    }

    /// Strict UTF-8 percent-encoding (unreserved characters only; `+`, `/`, `&` are escaped).
    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Response handling

    static func checkStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CommunityError.decoding("non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CommunityError.http(status: http.statusCode, detail: parseDetail(data))
        }
    }

    /// Extracts `detail` from `{"detail": "..."}`; non-string details are returned as compact JSON text.
    static func parseDetail(_ data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] else { return nil }
        if let s = detail as? String { return s }
        if JSONSerialization.isValidJSONObject(detail), let d = try? JSONSerialization.data(withJSONObject: detail) {
            return String(data: d, encoding: .utf8)
        }
        return String(describing: detail)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CommunityError.decoding(String(describing: error)) }
    }

    // MARK: Transport

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        try Self.checkStatus(response: response, data: data)
        return data
    }

    private func perform<T: Decodable>(_ request: @autoclosure () throws -> URLRequest, as type: T.Type) async throws -> T {
        let data = try await performRaw(try request())
        return try Self.decode(type, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation: bridge the completion-handler API.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                else { continuation.resume(throwing: URLError(.badServerResponse)) }
            }
            task.resume()
        }
        #else
        return try await session.data(for: request)
        #endif
    }
}
