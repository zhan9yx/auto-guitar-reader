# Module contracts (AGRCore public API)

Workstreams implement against these signatures. Names are binding; add helpers freely,
but do not rename/remove these without the main agent's approval.
All public types are `Sendable` value types unless noted. Everything in `Core/` must
compile on Linux (Swift 6.0 toolchain, Swift 5 language mode): no UIKit, AVFoundation,
Vision, Accelerate (Accelerate only behind `#if canImport(Accelerate)` with a pure-Swift fallback).
Use `import FoundationXML` / `import FoundationNetworking` behind `#if canImport(...)`.

Already implemented by the main agent (do not change semantics):
`Model/Score.swift` (all model types, `ScoreCoding`), `Theory/ChordSymbol.swift`.

---

## A. Import (`Sources/AGRCore/Import/`)

```swift
public enum ImportError: Error, Equatable { case unsupportedFormat(String), empty, malformed(String) }

public enum ScoreFormat: String, Sendable { case agr, chordpro, chordText, asciiTab, musicXML }

public enum ScoreImporter {
    /// Sniff by extension then content. Text decoding: UTF-8, UTF-16 (BOM), GB18030 fallback.
    public static func detectFormat(data: Data, fileName: String?) -> ScoreFormat?
    public static func importData(_ data: Data, fileName: String?) throws -> Score
    /// Pasted text (chordpro / chord-over-lyrics / ascii tab, auto-detected; may be mixed).
    public static func importText(_ text: String, title: String? = nil) throws -> Score
}

public enum ChordProParser   { public static func parse(_ text: String) throws -> Score }
public enum ChordTextParser  { public static func parse(_ text: String) throws -> Score }   // chord-over-lyrics (UG / Chinese sites)
public enum AsciiTabParser   { public static func parseBlock(_ lines: [String]) -> TabBlock?   // 6 string lines
                               public static func parse(_ text: String) throws -> Score }
public enum MusicXMLParser   { public static func parse(_ data: Data) throws -> Score }
public enum ChordProExporter { public static func export(_ score: Score) -> String }       // round-trips through ChordProParser

/// Display-column width: CJK / full-width = 2, others = 1 (for chord-over-lyrics alignment).
public enum TextWidth { public static func columns(_ s: Substring) -> Int }

// OCR layout reconstruction. Boxes are normalized to the page: origin top-left, 0...1.
public struct OCRToken: Codable, Hashable, Sendable {
    public var text: String; public var x: Double; public var y: Double
    public var width: Double; public var height: Double; public var confidence: Double
}
public struct OCRPage: Codable, Hashable, Sendable {
    public var tokens: [OCRToken]; public var imageFileName: String?; public var pixelWidth: Int; public var pixelHeight: Int
}
public enum OCRScoreReconstructor {
    /// Rows by y-clustering; classify rows (chords / lyrics / tab digits / metadata / section header);
    /// attach chords to lyric characters by x; set Line.anchor; fill Score.pages; parse 原调/选调/Capo/变调夹/BPM/♩=.
    public static func reconstruct(pages: [OCRPage], fallbackTitle: String? = nil) -> Score
}
```

## B. Timeline, voicing, playback, DSP

```swift
// Theory/Voicing.swift
public struct Voicing: Hashable, Sendable {
    public var frets: [Int]              // 6 entries low→high, -1 muted
    public func midiNotes(tuning: [Int], capo: Int) -> [Int]   // low→high, muted skipped
}
public enum VoicingLibrary {
    /// chordDefinitions override → built-in open-chord table → movable barre shapes (E/A forms).
    public static func voicing(for chord: ChordSymbol, definitions: [String: ChordShape], written: String?) -> Voicing
}

// Timeline/Timeline.swift
public struct LineRef: Hashable, Sendable { public var sectionIndex: Int; public var lineIndex: Int }  // indices into score.sections
public enum TimelineEventKind: String, Sendable { case chord, notes, rest }
public struct TimelineEvent: Hashable, Sendable {
    public var index: Int
    public var kind: TimelineEventKind
    public var line: LineRef
    public var passIndex: Int                 // which repetition of the section in the arrangement (0-based)
    public var segmentIndex: Int?             // lyrics/chords lines
    public var tabMeasureIndex: Int?; public var tabEventIndex: Int?  // tab lines
    public var chord: ChordSymbol?            // already transposed (sounding chord name = written + transpose)
    public var midiNotes: [Int]               // sounding notes (chord voicing incl. capo+transpose, or tab notes)
    public var startBeat: Double; public var beats: Double
    public var lyric: String                  // text sung over this event ("" if none)
    public var progressInLine: ClosedRange<Double>  // fraction of the line's width/time this event spans (0...1)
}
public struct TimelineOptions: Sendable { public var transpose: Int = 0; public var tempo: Double? = nil; public init(...) }
public struct Timeline: Sendable {
    public var events: [TimelineEvent]; public var tempo: Double; public var timeSignature: TimeSignature
    public var totalBeats: Double
    public static func build(from score: Score, options: TimelineOptions = .init()) -> Timeline
    public func seconds(forBeat b: Double) -> Double
    public func eventIndex(atBeat b: Double) -> Int?
    /// First event of each section pass (for follower jump targets).
    public var sectionStartIndices: [Int]
}

// Playback/
public struct NoteEvent: Hashable, Sendable { public var time: Double; public var midi: Int; public var velocity: Float; public var duration: Double; public var stringIndex: Int /*0=low E*/; public var eventIndex: Int }
public struct PlaybackOptions: Sendable { public var tempoScale: Double = 1; public var strumPattern: StrumPattern? = nil; public var countInBeats: Int = 0; public var swing: Double = 0; public var humanize: Double = 0.3; public var seed: UInt64 = 1 }
public enum PerformancePlanner { public static func plan(_ timeline: Timeline, score: Score, options: PlaybackOptions) -> [NoteEvent] }

/// Real-time-safe extended Karplus-Strong guitar. Not thread-safe; owned by the audio thread.
public final class GuitarSynth {
    public init(sampleRate: Double)
    public var brightness: Float      // 0...1
    public var bodyResonance: Float   // 0...1
    public var volume: Float          // 0...1
    public func pluck(midi: Int, velocity: Float, stringIndex: Int)  // retriggers that string
    public func mute(stringIndex: Int?)                              // nil = all
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int)   // mono, adds nothing else; zero-alloc
}
/// Schedules NoteEvents against a sample clock and drives GuitarSynth. Used by the app's AVAudioSourceNode
/// and by the offline renderer.
public final class SequencerEngine {
    public init(sampleRate: Double, events: [NoteEvent])
    public var isPlaying: Bool
    public var positionSeconds: Double { get }
    public func seek(toSeconds: Double)
    public let synth: GuitarSynth
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int)
}
public enum OfflineRenderer { public static func render(_ events: [NoteEvent], sampleRate: Double, tail: Double = 1.5) -> [Float]
                               public static func wavData(_ samples: [Float], sampleRate: Double) -> Data }  // 16-bit PCM mono

// DSP/
public struct FeatureConfig: Sendable { public var sampleRate: Double = 22050; public var windowSize = 4096; public var hopSize = 512; public var minMidi = 40; public var maxMidi = 88 }
public struct FeatureFrame: Sendable {
    public var time: Double
    public var semitone: [Float]   // maxMidi-minMidi+1 bins, log-compressed
    public var chroma: [Float]     // 12, L2-normalized (zeros if silent)
    public var bassChroma: [Float] // 12, L2-normalized
    public var onset: Float        // spectral flux (>= 0)
    public var rms: Float
    public var isSilent: Bool      // adaptive noise gate
}
/// Streaming: push arbitrary-size chunks at any input sample rate; resamples to config.sampleRate internally.
public final class FeatureExtractor {
    public init(config: FeatureConfig = .init(), inputSampleRate: Double)
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [FeatureFrame]
    public func process(_ samples: [Float]) -> [FeatureFrame]
    public func reset()
}
public enum FFT { /* real FFT magnitude; vDSP when available */ }
```

## C. Follow + Scroll

```swift
public enum FollowMode: String, Sendable { case strumSing, fingerstyle }
public struct FollowState: Sendable, Equatable {
    public var eventIndex: Int            // into timeline.events
    public var progressInEvent: Double    // 0...1
    public var confidence: Double         // 0...1
    public var tempoRatio: Double         // performed / notated
    public var isPaused: Bool             // sustained silence
    public var time: Double
}
public struct FollowerConfig: Sendable { /* κ, transition probs, jump ε, gate params… with documented defaults */ }
public final class ScoreFollower {
    public init(timeline: Timeline, mode: FollowMode, featureConfig: FeatureConfig = .init(), config: FollowerConfig = .init())
    public func process(_ frame: FeatureFrame) -> FollowState
    public func relocate(toEvent index: Int)
    /// Soft evidence from LyricsAligner: per-event likelihood multipliers (len == events.count), weight 0...1.
    public func applyLyricsEvidence(_ evidence: [Double], weight: Double)
    public var state: FollowState { get }
}
public final class LyricsAligner {
    public init(timeline: Timeline)
    /// Recognized text so far (streaming partial transcript). Returns evidence vector + weight, or nil if no confident match.
    public func update(transcript: String) -> (evidence: [Double], weight: Double)?
}

public struct ScrollConfig: Sendable {
    public var anchorRatio: Double = 0.30          // current line position in viewport
    public var maxSpeed: Double = 0.6              // viewport heights / second
    public var maxAcceleration: Double = 1.5       // viewport heights / second^2
    public var deadZone: Double = 0.04             // viewport heights
    public var jumpThreshold: Double = 1.0         // viewport heights; beyond → crossfade jump
    public var backwardConfirmSeconds: Double = 1.5
    public var lowConfidence: Double = 0.35
    public var coastSeconds: Double = 4
    public var manualOverrideSeconds: Double = 3
}
public struct LineGeometry: Sendable { public var lineIndexInDocument: Int; public var minY: Double; public var height: Double }
public enum ScrollAction: Sendable, Equatable { case none, setOffset(Double), jump(to: Double) }
public final class ScrollController {
    public init(config: ScrollConfig = .init())
    public var viewportHeight: Double; public var contentHeight: Double
    public private(set) var offset: Double
    /// Target from follower/playback: document y of the current reading position + confidence.
    public func setTarget(y: Double, confidence: Double, at time: Double)
    public func userDidScroll(to offset: Double, at time: Double)
    /// Call every display frame; returns the action to apply to the scroll view.
    public func step(now: Double) -> ScrollAction
}
/// Maps (FollowState, Timeline, line frames) → document y.
public enum ReadingPosition { public static func documentY(state: FollowState, timeline: Timeline, lineFrame: (LineRef) -> (minY: Double, height: Double)?) -> Double? }

// Evaluation
public struct FollowEvalReport: Codable, Sendable { public var exactAccuracy: Double; public var withinOneAccuracy: Double; public var medianLatency: Double; public var frames: Int }
public enum FollowEvaluator {
    public static func evaluate(score: Score, mode: FollowMode, audio: [Float], sampleRate: Double, groundTruth: [(time: Double, eventIndex: Int)]?) -> FollowEvalReport
    public static func synthesizeTake(score: Score, mode: FollowMode, seed: UInt64, tempoDrift: Double, snrDB: Double, withVoice: Bool) -> (audio: [Float], sampleRate: Double, truth: [(time: Double, eventIndex: Int)])
}
```

## D. Community DTOs (`Sources/AGRCore/Community/`) — shared with server/

```swift
public struct CommunityScoreSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String; public var title: String; public var artist: String?; public var key: String?
    public var mode: PlayMode; public var uploader: String; public var downloads: Int; public var createdAt: Date; public var pageCount: Int
}
public struct CommunitySearchResponse: Codable, Sendable { public var items: [CommunityScoreSummary]; public var total: Int; public var page: Int; public var pageSize: Int }
public enum CommunitySort: String, Sendable { case recent, popular }
public struct CommunityClient: Sendable {
    public init(baseURL: URL, deviceID: String, nickname: String, session: URLSession = .shared)
    public func search(query: String, sort: CommunitySort = .recent, page: Int = 1, pageSize: Int = 20) async throws -> CommunitySearchResponse
    public func fetchScore(id: String) async throws -> Score
    public func fetchAsset(scoreID: String, name: String) async throws -> Data
    public func upload(score: Score, assets: [(name: String, data: Data, mimeType: String)]) async throws -> CommunityScoreSummary
    public func report(scoreID: String, reason: String) async throws
}
```
HTTP: JSON dates ISO-8601; snake_case on the wire ↔ camelCase in Swift (use explicit CodingKeys);
`POST /api/v1/scores` multipart fields: `score` (application/json file), `assets` (repeatable files);
headers `X-Device-Id`, `X-Nickname` (percent-encoded UTF-8). Errors: `{"detail": "..."}` with 4xx.
