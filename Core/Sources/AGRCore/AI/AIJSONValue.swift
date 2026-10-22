import Foundation

/// Minimal JSON tree used by the AI layer (patching, request bodies). Keeps integers and
/// doubles apart so a `Score` round-trips without `3` turning into `3.0`.
public enum AIJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AIJSONValue])
    case object([String: AIJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AIJSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: AIJSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) throws -> AIJSONValue {
        try JSONDecoder().decode(AIJSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> AIJSONValue {
        try parse(Data(text.utf8))
    }

    /// Deterministic encoding (sorted keys, unescaped slashes); `pretty` adds indentation.
    public func data(pretty: Bool = false) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// Compact deterministic JSON text.
    public var compactText: String {
        guard let d = try? data(), let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var arrayValue: [AIJSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: AIJSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public subscript(key: String) -> AIJSONValue? { objectValue?[key] }

    /// Encodes any `Encodable` into a tree.
    public static func from<T: Encodable>(_ value: T, encoder: JSONEncoder = ScoreCoding.encoder()) throws -> AIJSONValue {
        try parse(try encoder.encode(value))
    }

    /// Decodes the tree into `T`.
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = ScoreCoding.decoder()) throws -> T {
        try decoder.decode(type, from: try data())
    }
}
