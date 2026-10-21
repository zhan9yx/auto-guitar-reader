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

    // MARK: Request building (pure, testable without network)

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
