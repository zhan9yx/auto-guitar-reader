import Foundation

// MARK: - Patch format
//
//   {"ops":[{"op":"set"|"insert"|"delete","path":"sections[0]...","value":<json>,"issue":"<id>"}],"notes":"..."}
//
// `path` is a JSONPath-like location in the Score JSON. `issue` (optional on single-issue requests)
// ties the op to the flagged issue it fixes; ops of one issue are applied atomically.

public struct PatchOp: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case set, insert, delete }
    public var op: Kind
    public var path: String
    public var value: AIJSONValue?
    public var issue: String?

    public init(op: Kind, path: String, value: AIJSONValue? = nil, issue: String? = nil) {
        self.op = op
        self.path = path
        self.value = value
        self.issue = issue
    }

    enum CodingKeys: String, CodingKey { case op, path, value, issue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(Kind.self, forKey: .op)
        path = try c.decode(String.self, forKey: .path)
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        // Distinguish "value": null (explicit null) from a missing value.
        if c.contains(.value) { value = try c.decode(AIJSONValue.self, forKey: .value) } else { value = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(issue, forKey: .issue)
    }
}

public struct ScorePatch: Codable, Hashable, Sendable {
    public var ops: [PatchOp]
    public var notes: String

    public init(ops: [PatchOp] = [], notes: String = "") {
        self.ops = ops
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case ops, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.decodeIfPresent([PatchOp].self, forKey: .ops) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// Parses a model answer: plain JSON, JSON inside a markdown fence, or JSON surrounded by prose.
    public static func parse(modelOutput text: String) throws -> ScorePatch {
        var candidates: [String] = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let fenced = Self.fencedBlock(in: text) { candidates.append(fenced) }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            candidates.append(String(text[first...last]))
        }
        var lastError: Error = PatchError.malformedPatch("empty answer")
        for candidate in candidates where !candidate.isEmpty {
            do { return try JSONDecoder().decode(ScorePatch.self, from: Data(candidate.utf8)) }
            catch { lastError = error }
        }
        throw PatchError.malformedPatch(String(describing: lastError))
    }

    private static func fencedBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        var rest = text[open.upperBound...]
        if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }
        guard let close = rest.range(of: "```") else { return nil }
        return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

public enum PatchError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedPatch(String)
    case invalidPath(String)
    case notFound(String)
    case indexOutOfRange(path: String, index: Int, count: Int)
    case typeMismatch(String)
    case missingValue(String)
    case forbiddenPath(String)
    case unknownField(String)
    case decodeFailed(String)
    case validationFailed(String)

    public var description: String {
        switch self {
        case .malformedPatch(let m): return "补丁格式错误：\(m)"
        case .invalidPath(let p): return "路径无效：\(p)"
        case .notFound(let p): return "路径不存在：\(p)"
        case .indexOutOfRange(let p, let i, let n): return "下标越界：\(p)（\(i) / \(n)）"
        case .typeMismatch(let m): return "类型不符：\(m)"
        case .missingValue(let p): return "缺少 value：\(p)"
        case .forbiddenPath(let p): return "禁止修改：\(p)"
        case .unknownField(let p): return "未知字段：\(p)"
        case .decodeFailed(let m): return "结果无法解码：\(m)"
        case .validationFailed(let m): return "校验未通过：\(m)"
        }
    }
}

// MARK: - Paths

public enum PathToken: Hashable, Sendable {
    case key(String)
    case index(Int)
    /// `[-]` / `/-`: one past the last element (insert only).
    case append
}

public enum ScorePath {
    /// Accepted forms: `sections[0].lines[2].system`, `$.sections[0]`, `sections.0.lines.2`,
    /// `sections[0]["lines"][-]`, JSON Pointer `/sections/0/lines/-`.
    public static func parse(_ raw: String) throws -> [PathToken] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw PatchError.invalidPath("(empty)") }
        if s.hasPrefix("/") { return try parsePointer(s, raw: raw) }
        if s.hasPrefix("$") {
            s.removeFirst()
            if s.hasPrefix(".") { s.removeFirst() }
        }
        let chars = Array(s)
        var tokens: [PathToken] = []
        var i = 0
        func bad(_ why: String) -> PatchError { .invalidPath("\(raw) (\(why))") }
        var expectSegment = true
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                guard !expectSegment else { throw bad("empty segment") }
                expectSegment = true
                i += 1
                guard i < chars.count else { throw bad("trailing dot") }
            } else if c == "[" {
                i += 1
                guard i < chars.count else { throw bad("unclosed [") }
                if chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    var name = ""
                    while i < chars.count && chars[i] != quote { name.append(chars[i]); i += 1 }
                    guard i < chars.count, !name.isEmpty else { throw bad("unclosed quote") }
                    i += 1
                    guard i < chars.count, chars[i] == "]" else { throw bad("unclosed [") }
                    i += 1
                    tokens.append(.key(name))
                } else {
                    var body = ""
                    while i < chars.count && chars[i] != "]" { body.append(chars[i]); i += 1 }
                    guard i < chars.count else { throw bad("unclosed [") }
                    i += 1
                    if body == "-" { tokens.append(.append) }
                    else if !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(body) { tokens.append(.index(n)) }
                    else { throw bad("bad index [\(body)]") }
                }
                expectSegment = false
            } else {
                guard expectSegment else { throw bad("expected . or [") }
                var name = ""
                while i < chars.count && chars[i] != "." && chars[i] != "[" && chars[i] != "]" {
                    name.append(chars[i]); i += 1
                }
                guard !name.isEmpty, i >= chars.count || chars[i] != "]" else { throw bad("stray ]") }
                if name.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(name) { tokens.append(.index(n)) }
                else if name == "-" { tokens.append(.append) }
                else { tokens.append(.key(name)) }
                expectSegment = false
            }
        }
        guard !tokens.isEmpty, !expectSegment else { throw bad("empty path") }
        return tokens
    }

    private static func parsePointer(_ s: String, raw: String) throws -> [PathToken] {
        let segments = s.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, !segments.contains(where: { $0.isEmpty }) else { throw PatchError.invalidPath(raw) }
        return segments.map { seg in
            let name = seg.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if name == "-" { return .append }
            if name.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(name) { return .index(n) }
            return .key(name)
        }
    }

    public static func render(_ tokens: [PathToken]) -> String {
        var out = ""
        for t in tokens {
            switch t {
            case .key(let k): out += out.isEmpty ? k : ".\(k)"
            case .index(let i): out += "[\(i)]"
            case .append: out += "[-]"
            }
        }
        return out
    }
}

// MARK: - Patcher

public enum ScorePatcher {
    /// Top-level fields the AI may never touch.
    static let protectedTopLevel: Set<String> = ["format", "version", "id", "pages"]

    /// Applies all ops (atomically: any failure throws and nothing is returned) to `score`'s JSON
    /// representation, then validates that the result still decodes and did not get structurally worse.
    public static func apply(_ patch: ScorePatch, to score: Score) throws -> Score {
        try apply(patch.ops, to: score)
    }

    public static func apply(_ ops: [PatchOp], to score: Score) throws -> Score {
        guard !ops.isEmpty else { return score }
        var tree: AIJSONValue
        do { tree = try AIJSONValue.from(score) } catch { throw PatchError.decodeFailed("cannot encode score: \(error)") }
        for op in ops { try applyOp(op, to: &tree) }
        let result: Score
        do { result = try tree.decode(Score.self) } catch { throw PatchError.decodeFailed(String(describing: error)) }
        try checkUnknownFields(ops, in: result)
        try validate(before: score, after: result)
        return result
    }

    /// Value at `path` of the score's JSON tree (nil when it does not resolve).
    public static func value(at path: String, in score: Score) -> AIJSONValue? {
        guard let tree = try? AIJSONValue.from(score) else { return nil }
        return value(at: path, in: tree)
    }

    public static func value(at path: String, in tree: AIJSONValue) -> AIJSONValue? {
        guard let tokens = try? ScorePath.parse(path) else { return nil }
        return resolve(tokens[...], in: tree)
    }

    static func resolve(_ tokens: ArraySlice<PathToken>, in node: AIJSONValue) -> AIJSONValue? {
        guard let first = tokens.first else { return node }
        switch (node, first) {
        case (.object(let o), .key(let k)): return o[k].flatMap { resolve(tokens.dropFirst(), in: $0) }
        case (.array(let a), .index(let i)): return a.indices.contains(i) ? resolve(tokens.dropFirst(), in: a[i]) : nil
        default: return nil
        }
    }

    // MARK: Applying one op

    static func applyOp(_ op: PatchOp, to tree: inout AIJSONValue) throws {
        let tokens = try ScorePath.parse(op.path)
        if case .key(let top) = tokens[0], protectedTopLevel.contains(top) { throw PatchError.forbiddenPath(op.path) }
        if op.op != .delete && op.value == nil { throw PatchError.missingValue(op.path) }
        try mutate(&tree, tokens: tokens[...], consumed: [], op: op)
    }

    private static func mutate(_ node: inout AIJSONValue, tokens: ArraySlice<PathToken>, consumed: [PathToken], op: PatchOp) throws {
        let token = tokens.first!
        let here = ScorePath.render(consumed + [token])
        let isLeaf = tokens.count == 1
        switch node {
        case .object(var o):
            guard case .key(let k) = token else {
                throw PatchError.typeMismatch("\(ScorePath.render(consumed)) is an object, not an array (\(here))")
            }
            if isLeaf {
                switch op.op {
                case .set: o[k] = op.value!
                case .insert:
                    guard o[k] == nil else { throw PatchError.typeMismatch("\(here) already exists; use set") }
                    o[k] = op.value!
                case .delete:
                    guard o[k] != nil else { throw PatchError.notFound(here) }
                    o[k] = nil
                }
            } else {
                guard var child = o[k] else { throw PatchError.notFound(here) }
                try mutate(&child, tokens: tokens.dropFirst(), consumed: consumed + [token], op: op)
                o[k] = child
            }
            node = .object(o)
        case .array(var a):
            let parent = ScorePath.render(consumed)
            let index: Int
            switch token {
            case .index(let i): index = i
            case .append:
                guard isLeaf, op.op == .insert else { throw PatchError.invalidPath("[-] only valid as the target of insert (\(op.path))") }
                index = a.count
            case .key:
                throw PatchError.typeMismatch("\(parent) is an array, not an object (\(here))")
            }
            if isLeaf {
                switch op.op {
                case .set:
                    guard index >= 0, index < a.count else { throw PatchError.indexOutOfRange(path: parent, index: index, count: a.count) }
                    a[index] = op.value!
                case .insert:
                    guard index >= 0, index <= a.count else { throw PatchError.indexOutOfRange(path: parent, index: index, count: a.count) }
                    a.insert(op.value!, at: index)
                case .delete:
                    guard index >= 0, index < a.count else { throw PatchError.indexOutOfRange(path: parent, index: index, count: a.count) }
                    a.remove(at: index)
                }
            } else {
                guard index >= 0, index < a.count else { throw PatchError.indexOutOfRange(path: parent, index: index, count: a.count) }
                try mutate(&a[index], tokens: tokens.dropFirst(), consumed: consumed + [token], op: op)
            }
            node = .array(a)
        default:
            throw PatchError.typeMismatch("\(ScorePath.render(consumed)) is a scalar, cannot descend into \(here)")
        }
    }

    // MARK: Validation

    /// Fields that the decoded model does not know are silently dropped by `Codable`; a patch that
    /// sets one (typo like "chrod") would look applied but do nothing, so it is rejected.
    private static func checkUnknownFields(_ ops: [PatchOp], in result: Score) throws {
        guard let reencoded = try? AIJSONValue.from(result) else { return }
        for op in ops where op.op != .delete {
            guard let value = op.value, let tokens = try? ScorePath.parse(op.path), case .key = tokens.last! else { continue }
            if value.isNull || value == .bool(false) || value == .int(0) { continue }
            if tokens.count >= 2, let parent = resolve(tokens.dropLast(), in: reencoded), parent.objectValue != nil,
               resolve(tokens[...], in: reencoded) == nil {
                throw PatchError.unknownField(op.path)
            }
        }
    }

    static func validate(before: Score, after: Score) throws {
        let b = AIScoreMetrics(before), a = AIScoreMetrics(after)
        if a.structureViolations > b.structureViolations {
            throw PatchError.validationFailed("结构违规增加（\(b.structureViolations) → \(a.structureViolations)）：音符/弦/品位/时值越界")
        }
        if a.invalidBeatMeasures > b.invalidBeatMeasures {
            throw PatchError.validationFailed("拍数不符的小节增加（\(b.invalidBeatMeasures) → \(a.invalidBeatMeasures)）")
        }
        if a.beatErrorTotal > b.beatErrorTotal + 1e-6 {
            throw PatchError.validationFailed("拍数误差变大（\(b.beatErrorTotal) → \(a.beatErrorTotal)）")
        }
    }
}

/// Structural health of a score's notation systems (used to accept / reject patches and by tests).
public struct AIScoreMetrics: Equatable, Sendable {
    /// Measures whose melody durations do not sum to the measure length.
    public var invalidBeatMeasures = 0
    public var beatErrorTotal = 0.0
    /// Out-of-range values: degree, accidental, string, fret, negative beats / non-positive durations,
    /// events beyond the measure end.
    public var structureViolations = 0

    public static let epsilon = 1e-4

    public init(_ score: Score) {
        let ts = Double(max(score.meta.timeSignature.beats, 1))
        for section in score.sections {
            for line in section.lines {
                guard let system = line.system else { continue }
                for m in system.measures { add(m, defaultBeats: ts) }
            }
        }
    }

    private mutating func add(_ m: NotationMeasure, defaultBeats: Double) {
        let length = m.beats ?? defaultBeats
        if length <= 0 { structureViolations += 1 }
        if !m.melody.isEmpty {
            let sum = m.melody.reduce(0) { $0 + $1.duration }
            let err = abs(sum - length)
            if err > Self.epsilon {
                invalidBeatMeasures += 1
                beatErrorTotal += err
            }
        }
        for n in m.melody {
            if n.degree < 0 || n.degree > 7 { structureViolations += 1 }
            if n.accidental < -1 || n.accidental > 1 { structureViolations += 1 }
            if abs(n.octave) > 3 { structureViolations += 1 }
            if n.beat < -Self.epsilon || n.duration <= 0 || n.beat + n.duration > length + Self.epsilon { structureViolations += 1 }
        }
        for e in m.tab {
            if e.beat < -Self.epsilon || e.duration <= 0 || e.beat + e.duration > length + Self.epsilon { structureViolations += 1 }
            for n in e.notes {
                if n.string < 1 || n.string > 6 { structureViolations += 1 }
                if !n.chordTone && (n.fret < 0 || n.fret > 30) { structureViolations += 1 }
            }
        }
        for c in m.chords where c.name.trimmingCharacters(in: .whitespaces).isEmpty || c.beat < 0 || c.beat >= length + Self.epsilon {
            structureViolations += 1
        }
    }
}
