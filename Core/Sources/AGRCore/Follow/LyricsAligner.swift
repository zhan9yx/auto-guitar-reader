import Foundation

// MARK: - LyricsAligner (DESIGN §4.3)
//
// Fuses streaming speech-recognition text with the lyrics of the timeline to disambiguate repeated chord progressions.
// * The lyrics of all events are normalised (letters/digits only, lowercase) and concatenated; `charEvent` maps every
//   character back to its event.
// * The tail (6...12 characters) of the normalised transcript is aligned with Smith-Waterman (match +2, mismatch -1,
//   gap -1); the last DP row gives, for every corpus position, the best local alignment ending there with the newest
//   recognised character. Local maxima are the candidate positions.
// * A candidate becomes a smooth bump over events (plateau on the event holding the end of the match and the
//   following `forwardEvents`, compensating ~1 s ASR latency). If several distant candidates score similarly (a
//   repeated chorus line) the evidence is multi-modal with a reduced weight; if the best match is weak: nil.
// * Only changed transcripts are processed: the common prefix with the previously seen text is tracked, so repeated
//   calls with the same partial result (or one that only revises earlier words) do not re-fire stale evidence.

public struct LyricsAlignerConfig: Sendable {
    public var minQueryChars = 6
    public var maxQueryChars = 12
    public var matchScore = 2
    public var mismatchScore = -1
    public var gapScore = -1
    /// Minimum normalised score (score / (match * queryLength)) of the best alignment.
    public var minNormalizedScore = 0.55
    /// Minimum absolute score (guards short queries against chance matches of common characters).
    public var minAbsoluteScore = 8
    /// A second candidate with at least this fraction of the best score and `ambiguousEventDistance` events away makes
    /// the evidence multi-modal.
    public var ambiguityRatio = 0.8
    public var ambiguousEventDistance = 2
    /// Weight multiplier when the evidence is multi-modal.
    public var ambiguousWeightFactor = 0.6
    /// Events after the match end that are also fully plausible (ASR latency).
    public var forwardEvents = 1
    public var maxWeight = 0.85
    /// Evidence value of events far away from every candidate.
    public var floorEvidence = 0.05
    public init() {}
}

public final class LyricsAligner {
    public let config: LyricsAlignerConfig
    private let corpus: [UInt32]
    private let charEvent: [Int]
    private let eventCount: Int
    private var previous: [UInt32] = []
    private var rowA: [Int]
    private var rowB: [Int]

    /// Lowercased letters / digits only (punctuation, spaces and symbols removed).
    static func normalize(_ text: String) -> [UInt32] {
        var out: [UInt32] = []
        for ch in text.lowercased() where ch.isLetter || ch.isNumber {
            for u in ch.unicodeScalars { out.append(u.value) }
        }
        return out
    }

    public init(timeline: Timeline, config: LyricsAlignerConfig = .init()) {
        self.config = config
        var c: [UInt32] = [], m: [Int] = []
        for e in timeline.events {
            for u in LyricsAligner.normalize(e.lyric) { c.append(u); m.append(e.index) }
        }
        corpus = c
        charEvent = m
        eventCount = timeline.events.count
        rowA = [Int](repeating: 0, count: c.count + 1)
        rowB = rowA
    }

    public func reset() { previous = [] }

    /// Number of characters of lyrics in the timeline.
    public var corpusLength: Int { corpus.count }

    /// `transcript`: the recognised text so far (a streaming partial result, possibly revised). Returns evidence over
    /// events (length == events.count, values 0...1) and a weight 0...1, or nil when there is nothing new or no
    /// confident match.
    public func update(transcript: String) -> (evidence: [Double], weight: Double)? {
        let norm = LyricsAligner.normalize(transcript)
        defer { previous = norm }
        guard !corpus.isEmpty, norm.count >= config.minQueryChars else { return nil }
        // Anything new beyond the previously consumed text?
        var common = 0
        while common < min(previous.count, norm.count), previous[common] == norm[common] { common += 1 }
        if common == norm.count && norm.count <= previous.count { return nil }
        let q = Array(norm.suffix(config.maxQueryChars))
        return align(query: q)
    }

    private func align(query q: [UInt32]) -> (evidence: [Double], weight: Double)? {
        let L = corpus.count, Q = q.count
        // SW rows over the corpus; keep the last row.
        for j in 0...L { rowA[j] = 0 }
        let mt = config.matchScore, mm = config.mismatchScore, gp = config.gapScore
        for i in 1...Q {
            rowB[0] = 0
            let qc = q[i - 1]
            for j in 1...L {
                let diag = rowA[j - 1] + (corpus[j - 1] == qc ? mt : mm)
                let up = rowA[j] + gp
                let left = rowB[j - 1] + gp
                rowB[j] = max(0, max(diag, max(up, left)))
            }
            swap(&rowA, &rowB)
        }
        // rowA = last row: score of the best alignment ending at (Q, j), corpus char j-1.
        var best = 0
        for j in 1...L { best = max(best, rowA[j]) }
        let minScore = max(config.minAbsoluteScore, Int((config.minNormalizedScore * Double(mt * Q)).rounded(.up)))
        guard best >= minScore else { return nil }

        // Candidates: local maxima with a decent score, best first.
        var cands: [(score: Int, pos: Int)] = []
        let floorScore = max(minScore, Int(config.ambiguityRatio * Double(best)))
        for j in 1...L where rowA[j] >= floorScore {
            let l = j > 1 ? rowA[j - 1] : 0, r = j < L ? rowA[j + 1] : 0
            if rowA[j] >= l && rowA[j] > r { cands.append((rowA[j], j - 1)) }
        }
        cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.pos < $1.pos }
        guard let top = cands.first else { return nil }

        // Distinct events (>= ambiguousEventDistance apart) among the candidates.
        var chosen: [(score: Int, pos: Int)] = [top]
        for c in cands.dropFirst() {
            let ev = charEvent[c.pos]
            if chosen.allSatisfy({ abs(charEvent[$0.pos] - ev) >= config.ambiguousEventDistance }) { chosen.append(c) }
        }
        let multimodal = chosen.count > 1

        var evidence = [Double](repeating: config.floorEvidence, count: eventCount)
        func bump(_ e: Int) {
            for d in -1...(config.forwardEvents + 1) {
                let idx = e + d
                guard idx >= 0 && idx < eventCount else { continue }
                var v: Double
                if d < 0 { v = 0.35 } else if d <= config.forwardEvents { v = 1 } else { v = 0.2 }
                v = max(v, config.floorEvidence)
                evidence[idx] = max(evidence[idx], v)
            }
        }
        for c in chosen { bump(charEvent[c.pos]) }

        let norm = Double(top.score) / Double(mt * Q)
        let span = max(0.9 - config.minNormalizedScore, 1e-6)
        var weight = config.maxWeight * (0.4 + 0.6 * min(1, max(0, (norm - config.minNormalizedScore) / span)))
        if multimodal { weight *= config.ambiguousWeightFactor }
        return (evidence, min(max(weight, 0), 1))
    }
}
