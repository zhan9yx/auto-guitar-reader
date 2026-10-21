import Foundation
import AGRCore

// Framework-free playback planning: everything that decides *what* is played and how engine time maps back to the
// score. No AVFoundation / UIKit here, so it is unit-tested on Linux.

/// Everything that changes the planned notes. Volume / brightness are not part of it (they are live synth knobs).
struct PlaybackParameters: Equatable {
    /// 0.5 ... 1.5 (1 = notated tempo).
    var tempoScale: Double = 1
    /// Semitones, shared with the reader's transposition.
    var transpose: Int = 0
    /// nil = every section plays its own strum pattern ("跟随谱面"); non-nil = explicit user choice.
    var strumPattern: StrumPattern? = nil
    var countInBeats: Int = 0
    var metronome: Bool = false
    /// Index into `Timeline.sectionPasses` of the section pass to loop, nil = play the whole piece once.
    var loopPass: Int? = nil

    static let tempoRange: ClosedRange<Double> = 0.5...1.5

    var clampedTempoScale: Double { min(max(tempoScale, Self.tempoRange.lowerBound), Self.tempoRange.upperBound) }
}

/// Where playback currently is, expressed on the (transposition independent) timeline structure.
struct PlaybackReading: Equatable {
    var eventIndex: Int
    /// 0...1 inside the event.
    var progressInEvent: Double
    var beat: Double
    var engineSeconds: Double
    /// True while the count-in clicks are sounding.
    var isCountIn: Bool
}

/// A planned performance plus the mapping between engine time (seconds since the engine's start, count-in included)
/// and timeline beats.
///
/// Section loops are *unrolled* into the note list (the notes of the section are repeated `loopRepeats` times), so the
/// loop is sample-accurate and needs no main-thread intervention while the audio thread runs.
struct PlaybackPlan {
    let timeline: Timeline
    let params: PlaybackParameters
    /// Notes handed to `SequencerEngine` (count-in clicks, metronome clicks and - with a loop - the unrolled loop).
    let events: [NoteEvent]
    let secondsPerBeat: Double
    let countInSeconds: Double
    /// Beat range of the looped section pass (nil = no loop).
    let loopBeats: Range<Double>?
    let loopRepeats: Int
    /// Engine time at which playback is over (last note + a short tail; with a loop the end of the last repeat).
    let finishSeconds: Double

    /// Loop length is capped so a very short loop does not unroll into millions of notes.
    static let maxLoopRepeats = 1000
    static let targetLoopSeconds = 3600.0
    static let tailSeconds = 1.5

    static func make(score: Score, params rawParams: PlaybackParameters) -> PlaybackPlan {
        var params = rawParams
        params.tempoScale = rawParams.clampedTempoScale
        let timeline = Timeline.build(from: score, options: TimelineOptions(transpose: params.transpose))
        let options = PlaybackOptions(tempoScale: params.tempoScale, strumPattern: params.strumPattern,
                                      countInBeats: max(params.countInBeats, 0), metronome: params.metronome)
        let planned = PerformancePlanner.plan(timeline, score: score, options: options)
        let spb = PerformancePlanner.secondsPerBeat(timeline, options)
        let countIn = PerformancePlanner.countInSeconds(timeline, options)

        // Section loop.
        if let k = params.loopPass, timeline.sectionPasses.indices.contains(k) {
            let pass = timeline.sectionPasses[k]
            let lastIndex = pass.firstEvent + pass.eventCount - 1
            if pass.eventCount > 0, timeline.events.indices.contains(pass.firstEvent), timeline.events.indices.contains(lastIndex) {
                let b0 = timeline.events[pass.firstEvent].startBeat
                let b1 = timeline.events[lastIndex].endBeat
                let length = (b1 - b0) * spb
                if b1 - b0 > 1e-6, length > 0.05 {
                    let repeats = min(max(Int((targetLoopSeconds / length).rounded(.up)), 1), maxLoopRepeats)
                    let s0 = countIn + b0 * spb
                    var out: [NoteEvent] = planned.filter { $0.isClick && $0.time < countIn - 1e-9 }   // count-in
                    var body: [NoteEvent] = []
                    for e in planned {
                        let inRange: Bool
                        if e.isClick {
                            inRange = e.time >= countIn - 1e-9 && e.time >= s0 - 1e-9 && e.time < s0 + length - 1e-9
                        } else {
                            inRange = e.eventIndex >= pass.firstEvent && e.eventIndex <= lastIndex
                        }
                        guard inRange else { continue }
                        var n = e
                        let local = min(max(e.time - s0, 0), length - 1e-3)
                        n.time = local
                        n.duration = min(e.duration, max(length - local, 0.01))
                        body.append(n)
                    }
                    out.reserveCapacity(out.count + body.count * repeats)
                    for r in 0..<repeats {
                        let base = countIn + Double(r) * length
                        for var n in body {
                            n.time += base
                            out.append(n)
                        }
                    }
                    return PlaybackPlan(timeline: timeline, params: params, events: out, secondsPerBeat: spb,
                                        countInSeconds: countIn, loopBeats: b0..<b1, loopRepeats: repeats,
                                        finishSeconds: countIn + Double(repeats) * length)
                }
            }
            // Invalid loop selection: fall through to normal playback.
            params.loopPass = nil
        }

        return PlaybackPlan(timeline: timeline, params: params, events: planned, secondsPerBeat: spb,
                            countInSeconds: countIn, loopBeats: nil, loopRepeats: 1,
                            finishSeconds: countIn + timeline.totalBeats * spb + tailSeconds)
    }

    // MARK: Mapping

    /// Beats of engine time `t` (negative during the count-in).
    func beat(atEngineSeconds t: Double) -> Double {
        if t < countInSeconds { return (t - countInSeconds) / secondsPerBeat }
        let music = t - countInSeconds
        if let loop = loopBeats {
            let length = (loop.upperBound - loop.lowerBound) * secondsPerBeat
            let local = music.truncatingRemainder(dividingBy: length)
            return loop.lowerBound + local / secondsPerBeat
        }
        return music / secondsPerBeat
    }

    /// Engine time at which `beat` sounds for the first time (loop: inside the first repeat; a beat outside the loop
    /// maps to the loop start).
    func engineSeconds(forBeat b: Double) -> Double {
        if let loop = loopBeats {
            if b < 0 { return max(countInSeconds + b * secondsPerBeat, 0) }
            guard loop.contains(b) else { return countInSeconds }
            return countInSeconds + (b - loop.lowerBound) * secondsPerBeat
        }
        return max(countInSeconds + b * secondsPerBeat, 0)
    }

    func reading(atEngineSeconds t: Double) -> PlaybackReading? {
        guard !timeline.events.isEmpty else { return nil }
        let b = beat(atEngineSeconds: t)
        if b < 0 {
            return PlaybackReading(eventIndex: loopStartEvent ?? 0, progressInEvent: 0, beat: b, engineSeconds: t, isCountIn: true)
        }
        let idx = timeline.eventIndex(atBeat: b) ?? (b >= timeline.totalBeats ? timeline.events.count - 1 : 0)
        let e = timeline.events[idx]
        let p = e.beats > 1e-9 ? min(max((b - e.startBeat) / e.beats, 0), 1) : 0
        return PlaybackReading(eventIndex: idx, progressInEvent: p, beat: b, engineSeconds: t, isCountIn: false)
    }

    private var loopStartEvent: Int? {
        guard let loop = loopBeats else { return nil }
        return timeline.eventIndex(atBeat: loop.lowerBound)
    }

    /// Notated BPM scaled by the tempo slider.
    var bpm: Double { timeline.tempo * params.tempoScale }

    /// Engine position in `new` that corresponds to the musical position `oldSeconds` of `old` (parameter change while
    /// playing: same beat, new tempo / transposition / count-in / loop).
    static func resumeSeconds(from old: PlaybackPlan, atEngineSeconds oldSeconds: Double, to new: PlaybackPlan) -> Double {
        let b = old.beat(atEngineSeconds: oldSeconds)
        return new.engineSeconds(forBeat: b)
    }
}

/// A selectable section pass for looping ("主歌", "副歌 · 第2遍").
struct LoopOption: Identifiable, Equatable {
    var id: Int { passIndex }
    var passIndex: Int
    var title: String

    static func options(for score: Score, timeline: Timeline) -> [LoopOption] {
        var perSection: [Int: Int] = [:]
        for p in timeline.sectionPasses { perSection[p.sectionIndex, default: 0] += 1 }
        return timeline.sectionPasses.enumerated().map { k, p in
            let name: String
            if score.sections.indices.contains(p.sectionIndex) {
                let s = score.sections[p.sectionIndex]
                name = s.name.isEmpty ? "段落 \(p.sectionIndex + 1)" : s.name
            } else {
                name = "段落 \(p.sectionIndex + 1)"
            }
            let title = (perSection[p.sectionIndex] ?? 1) > 1 ? "\(name) · 第\(p.passIndex + 1)遍" : name
            return LoopOption(passIndex: k, title: title)
        }
    }
}
