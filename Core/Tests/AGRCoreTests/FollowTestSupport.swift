import XCTest
@testable import AGRCore

/// Helpers for follower tests: scores from ChordPro, synthetic feature frames from event templates.
enum FollowTest {
    static func timeline(_ cho: String, beatsPerChord: Double? = nil, order: [Int]? = nil) -> Timeline {
        var score = try! ChordProParser.parse(cho)
        if let b = beatsPerChord {
            for si in score.sections.indices { for li in score.sections[si].lines.indices {
                for gi in score.sections[si].lines[li].segments.indices where score.sections[si].lines[li].segments[gi].chord != nil {
                    score.sections[si].lines[li].segments[gi].beats = b
                }
            } }
        }
        if let order { score.arrangement = order.map { score.sections[$0].id } }
        return Timeline.build(from: score)
    }

    static let fc = FeatureConfig()

    /// A synthetic frame whose chroma/bass/semitone are derived from the notes of `event` (noise-free) plus optional
    /// extra pitch classes (voice) with weight.
    static func frame(time: Double, notes: [Int], voicePCs: [Int] = [], voiceWeight: Float = 0, onset: Float = 0, silent: Bool = false) -> FeatureFrame {
        var semi = [Float](repeating: 0, count: fc.maxMidi - fc.minMidi + 1)
        for n in notes {
            for (h, w) in [(0, 1.0), (12, 0.5), (19, 0.35), (24, 0.25)] as [(Int, Float)] {
                let m = n + h - fc.minMidi
                if m >= 0 && m < semi.count { semi[m] += w }
            }
        }
        for pc in voicePCs {
            var m = 55 + ((pc - 55) % 12 + 12) % 12
            if m > 66 { m -= 12 }
            for (h, w) in [(0, 1.0), (12, 0.5), (19, 0.4), (24, 0.3)] as [(Int, Float)] {
                let k = m + h - fc.minMidi
                if k >= 0 && k < semi.count { semi[k] += w * voiceWeight }
            }
        }
        var chroma = [Float](repeating: 0, count: 12), bass = chroma
        for (i, v) in semi.enumerated() {
            chroma[(fc.minMidi + i) % 12] += v
            if fc.minMidi + i <= 55 { bass[(fc.minMidi + i) % 12] += v }
        }
        FeatureExtractor.l2Normalize(&chroma); FeatureExtractor.l2Normalize(&bass)
        if silent { chroma = [Float](repeating: 0, count: 12); bass = chroma }
        return FeatureFrame(time: time, semitone: silent ? [Float](repeating: 0, count: semi.count) : semi,
                            chroma: chroma, bassChroma: bass, onset: onset, rms: silent ? 0 : 0.1, isSilent: silent)
    }

    /// Plays the events in order at `speed` (1 = notated tempo): returns (time, true event) per frame fed.
    @discardableResult
    static func play(_ f: ScoreFollower, timeline: Timeline, events: [Int]? = nil, speed: Double = 1, startTime: Double = 0,
                     voicePCs: [Int] = [], voiceWeight: Float = 0, check: ((Int, FollowState) -> Void)? = nil) -> Double {
        let fps = fc.frameRate
        var t = startTime
        let spb = 60.0 / timeline.tempo
        for ei in events ?? Array(timeline.events.indices) {
            let e = timeline.events[ei]
            let frames = Int((e.beats * spb * fps / speed).rounded())
            for k in 0..<frames {
                let onset: Float = k < 2 ? 3 : 0.1
                let fr = frame(time: t, notes: e.midiNotes, voicePCs: voicePCs, voiceWeight: voiceWeight, onset: onset)
                let st = f.process(fr)
                check?(ei, st)
                t += 1 / fps
            }
        }
        return t
    }

    static let loop = """
    {title: t}
    {tempo: 120}
    [C] [G] [Am] [F]
    """
}
