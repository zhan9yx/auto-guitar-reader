import Foundation

/// Minimal multipart/form-data body builder.
struct MultipartFormData {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "AGR-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addFile(field: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(field))\"; filename=\"\(Self.escape(fileName))\"\r\n")
        append("Content-Type: \(Self.sanitizeHeaderValue(mimeType))\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Appends the closing boundary and returns the finished body.
    func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private mutating func append(_ s: String) { body.append(Data(s.utf8)) }

    static func escape(_ s: String) -> String {
        sanitizeHeaderValue(s).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func sanitizeHeaderValue(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}
