import Foundation

// MARK: - Playback model

public struct NoteEvent: Hashable, Sendable {
    /// Seconds from the start of playback (count-in included).
    public var time: Double
    public var midi: Int
    public var velocity: Float
    public var duration: Double
    /// 0 = lowest (6th) string. -1 for clicks.
    public var stringIndex: Int
    /// Index into `Timeline.events` (-1 for clicks).
    public var eventIndex: Int
    /// Metronome / count-in click (rendered by the sequencer as a short noise burst; `midi` is ignored).
    public var isClick: Bool
    /// Melody voice note (简谱 melody of system lines, `PlaybackOptions.playMelody`); `stringIndex` is -2.
    /// Rendered by the sequencer with a soft sine-ish voice, monophonic.
    public var isMelody: Bool

    public init(time: Double, midi: Int, velocity: Float, duration: Double, stringIndex: Int,
                eventIndex: Int, isClick: Bool = false, isMelody: Bool = false) {
        self.time = time
        self.midi = midi
        self.velocity = velocity
        self.duration = duration
        self.stringIndex = stringIndex
        self.eventIndex = eventIndex
        self.isClick = isClick
        self.isMelody = isMelody
    }
}

public struct PlaybackOptions: Sendable {
    public var tempoScale: Double = 1
    /// Strum pattern used when the section has none (see `PerformancePlanner`).
    public var strumPattern: StrumPattern? = nil
    public var countInBeats: Int = 0
    /// 0...1: delays odd subdivisions (0 = straight, 1 = triplet feel).
    public var swing: Double = 0
    /// 0...1 timing / velocity randomness (seeded, deterministic).
    public var humanize: Double = 0.3
    public var seed: UInt64 = 1
    /// Click on every beat for the whole piece (not only the count-in).
    public var metronome: Bool = false
    /// Also render the 简谱 melody of `.system` lines as a soft melody voice (`NoteEvent.isMelody`).
    public var playMelody: Bool = false

    public init(tempoScale: Double = 1, strumPattern: StrumPattern? = nil, countInBeats: Int = 0,
                swing: Double = 0, humanize: Double = 0.3, seed: UInt64 = 1, metronome: Bool = false,
                playMelody: Bool = false) {
        self.playMelody = playMelody
        self.tempoScale = tempoScale
        self.strumPattern = strumPattern
        self.countInBeats = countInBeats
        self.swing = swing
        self.humanize = humanize
        self.seed = seed
        self.metronome = metronome
    }
}

// MARK: - Planner

public enum PerformancePlanner {
    /// Seconds per beat after tempo scaling.
    public static func secondsPerBeat(_ timeline: Timeline, _ options: PlaybackOptions) -> Double {
        60.0 / (max(timeline.tempo, 1e-6) * max(options.tempoScale, 1e-3))
    }

    /// Length of the count-in in seconds (music starts at this time).
    public static func countInSeconds(_ timeline: Timeline, _ options: PlaybackOptions) -> Double {
        Double(max(options.countInBeats, 0)) * secondsPerBeat(timeline, options)
    }

    /// Playback time (seconds, count-in included) at which `beat` of the timeline sounds.
    public static func seconds(forBeat beat: Double, timeline: Timeline, options: PlaybackOptions) -> Double {
        countInSeconds(timeline, options) + beat * secondsPerBeat(timeline, options)
    }

    /// Plans playback.
    ///
    /// Strum pattern priority per chord event: `options.strumPattern` (the user's explicit choice in the UI)
    /// → the section's `strumPatternID` (looked up in `score.strumPatterns`) → `.arpeggio` if the score mode
    /// is fingerstyle, otherwise `.defaultPop`. Patterns are phased to the measure grid (beat 0 = measure start).
    /// Tab events produce exact notes (string/fret + capo + transpose, via `TimelineEvent.midiNotes`).
    ///
    /// `.system` lines (v2) play the printed tab from `Timeline.systemMeasures`: "×" picks sound the fret of the
    /// chord shape in effect, digits as printed, events with a `stroke` are strummed over the listed strings
    /// (down = low → high, up = high → low). Default strum patterns are NOT applied there, except for measures
    /// that print no tab at all (chord-only systems), which fall back to the usual pattern per chord span.
    /// With `options.playMelody` the 简谱 melody is added as `isMelody` notes (key from `meta.key`).
    public static func plan(_ timeline: Timeline, score: Score, options: PlaybackOptions) -> [NoteEvent] {
        var p = Planner(timeline: timeline, score: score, options: options)
        return p.run()
    }
}

struct RawNote {
    var time: Double          // seconds, before count-in offset
    var midi: Int
    var velocity: Float
    var string: Int
    var event: Int
    var fixedDuration: Double?
    var minDuration: Double
}

struct Planner {
    let timeline: Timeline
    let score: Score
    let options: PlaybackOptions
    let spb: Double
    let measureBeats: Double
    var rng: SplitMix64
    var notes: [RawNote] = []
    var barriers: [(time: Double, string: Int)] = []
    let maxRing = 6.0

    init(timeline: Timeline, score: Score, options: PlaybackOptions) {
        self.timeline = timeline
        self.score = score
        self.options = options
        self.spb = PerformancePlanner.secondsPerBeat(timeline, options)
        self.measureBeats = Double(max(timeline.timeSignature.beats, 1))
        self.rng = SplitMix64(seed: options.seed)
    }

    var tuning: [Int] { score.meta.tuning }
    var capo: Int { score.meta.capo }

    mutating func jitter(_ amount: Double) -> Double {
        options.humanize > 0 ? rng.signed() * amount * options.humanize : 0
    }

    mutating func run() -> [NoteEvent] {
        for e in timeline.events where !e.fromSystem {
            switch e.kind {
            case .chord: strum(e)
            case .notes: tabNotes(e)
            case .rest: break
            }
        }
        for inst in timeline.systemMeasures { systemMeasure(inst) }
        var out = finalize()
        let offset = PerformancePlanner.countInSeconds(timeline, options)
        if options.playMelody { out.append(contentsOf: melody(offset: offset)) }
        out.append(contentsOf: clicks(offset: offset))
        out.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            if a.stringIndex != b.stringIndex { return a.stringIndex < b.stringIndex }
            return a.midi < b.midi
        }
        return out
    }

    // MARK: clicks

    func clicks(offset: Double) -> [NoteEvent] {
        var out: [NoteEvent] = []
        let n = max(options.countInBeats, 0)
        for i in 0..<n {
            out.append(NoteEvent(time: Double(i) * spb, midi: 0, velocity: i == 0 ? 1.0 : 0.7, duration: 0.03,
                                 stringIndex: -1, eventIndex: -1, isClick: true))
        }
        if options.metronome {
            let beats = Int(timeline.totalBeats.rounded(.up))
            let mb = Int(measureBeats)
            for b in 0..<max(beats, 0) {
                out.append(NoteEvent(time: offset + Double(b) * spb, midi: 0, velocity: b % mb == 0 ? 0.9 : 0.55,
                                     duration: 0.03, stringIndex: -1, eventIndex: -1, isClick: true))
            }
        }
        return out
    }

    // MARK: strumming

    func pattern(for e: TimelineEvent) -> StrumPattern {
        if let p = options.strumPattern { return p }
        let sec = score.sections.indices.contains(e.line.sectionIndex) ? score.sections[e.line.sectionIndex] : nil
        if let id = sec?.strumPatternID, let p = score.strumPatterns.first(where: { $0.id == id }) { return p }
        return score.meta.mode == .fingerstyle ? .arpeggio : .defaultPop
    }

    mutating func strum(_ e: TimelineEvent) {
        guard e.beats > 1e-9 else { return }
        let voicing: Voicing
        if let v = e.voicing { voicing = v }
        else if let c = e.chord { voicing = VoicingLibrary.voicing(for: c) }
        else { return }
        let stringNotes = voicing.stringNotes(tuning: tuning, capo: capo)
        guard !stringNotes.isEmpty else { return }
        let t0 = e.startBeat * spb

        // Chord change damps strings that the new shape does not play.
        for s in 0..<voicing.frets.count where voicing.frets[s] < 0 { barriers.append((t0, s)) }

        let pat = pattern(for: e)
        let chars = Array(pat.strokes)
        guard !chars.isEmpty else { return }
        let sub = max(pat.subdivision, 1)
        let slot = 1.0 / Double(sub)
        let phase = e.startBeat.truncatingRemainder(dividingBy: measureBeats)
        let k0 = Int((phase * Double(sub)).rounded())
        let nSlots = max(1, Int((e.beats * Double(sub) - 1e-6).rounded(.up)))
        var produced = 0
        for j in 0..<nSlots {
            let ch = chars[(k0 + j) % chars.count]
            if ch == "-" || ch == " " { continue }
            let inMeasure = (phase + Double(j) * slot).truncatingRemainder(dividingBy: measureBeats)
            produced += stroke(ch, e: e, notes: stringNotes, voicing: voicing, startBeat: e.startBeat + Double(j) * slot,
                               inMeasure: inMeasure, slotIndex: k0 + j, sub: sub)
        }
        if produced == 0 {
            _ = stroke("D", e: e, notes: stringNotes, voicing: voicing, startBeat: e.startBeat, inMeasure: phase,
                       slotIndex: k0, sub: sub)
        }
    }

    /// Emits one stroke; returns the number of notes added.
    mutating func stroke(_ ch: Character, e: TimelineEvent, notes: [(string: Int, midi: Int)], voicing: Voicing,
                         startBeat: Double, inMeasure: Double, slotIndex: Int, sub: Int) -> Int {
        let onBeat = abs(inMeasure - inMeasure.rounded()) < 1e-6
        let beatIndex = Int(inMeasure.rounded(.down) + 1e-6)
        var t = startBeat * spb
        if options.swing > 0, sub == 2, slotIndex % 2 == 1 {
            t += options.swing * (1.0 / Double(sub)) / 3.0 * spb
        }
        t = max(0, t + jitter(0.010))
        let vJit = Float(jitter(0.12))
        func vel(_ v: Float) -> Float { min(max(v + vJit, 0.05), 1.0) }
        let ringMin = e.beats * spb
        var added = 0

        func add(_ s: Int, _ m: Int, _ time: Double, _ v: Float, fixed: Double? = nil) {
            notes_append(RawNote(time: time, midi: m, velocity: v, string: s, event: e.index,
                                 fixedDuration: fixed, minDuration: ringMin))
            added += 1
        }

        switch ch {
        case "D", "d":
            let base: Float = onBeat ? (beatIndex == 0 ? 0.95 : (beatIndex == 2 ? 0.85 : 0.75)) : 0.62
            let v = vel(base)
            let d = 0.025 - 0.017 * Double(v)
            for (i, n) in notes.enumerated() {
                add(n.string, n.midi, t + Double(i) * d, vel(v * (1 - 0.04 * Float(i))))
            }
        case "U", "u":
            let v = vel(onBeat ? 0.58 : 0.5)
            let d = (0.025 - 0.017 * Double(v)) * 0.85
            let top = Array(notes.suffix(min(4, notes.count)).reversed())
            for (i, n) in top.enumerated() {
                add(n.string, n.midi, t + Double(i) * d, vel(v * 0.9 * (1 - 0.05 * Float(i))))
            }
        case "X", "x":
            let top = Array(notes.suffix(min(4, notes.count)))
            for (i, n) in top.enumerated() {
                add(n.string, n.midi, t + Double(i) * 0.004, vel(0.28), fixed: 0.045)
            }
        case "B", "b":
            var n = notes[0]
            if beatIndex == 2, onBeat, notes.count > 1 {
                let fifth = ((e.chord?.root ?? 0) + 7) % 12
                n = notes.dropFirst().first(where: { $0.midi % 12 == fifth }) ?? notes[1]
            }
            add(n.string, n.midi, t, vel(onBeat ? 0.85 : 0.7))
        default:
            guard let d = ch.wholeNumberValue, (1...6).contains(d) else { break }
            let idx = voicing.frets.count - d
            let n = notes.first(where: { $0.string == idx })
                ?? notes.min(by: { abs($0.string - idx) < abs($1.string - idx) || (abs($0.string - idx) == abs($1.string - idx) && $0.string > $1.string) })!
            add(n.string, n.midi, t, vel(onBeat ? 0.68 : 0.58))
        }
        return added
    }

    mutating func notes_append(_ n: RawNote) { notes.append(n) }

    // MARK: tab

    mutating func tabNotes(_ e: TimelineEvent) {
        guard let mi = e.tabMeasureIndex, let ei = e.tabEventIndex,
              score.sections.indices.contains(e.line.sectionIndex),
              score.sections[e.line.sectionIndex].lines.indices.contains(e.line.lineIndex),
              let tab = score.sections[e.line.sectionIndex].lines[e.line.lineIndex].tab,
              tab.measures.indices.contains(mi), tab.measures[mi].events.indices.contains(ei)
        else { return }
        let tev = tab.measures[mi].events[ei]
        let t0 = e.startBeat * spb
        let phase = e.startBeat.truncatingRemainder(dividingBy: measureBeats)
        let onBeat = abs(phase - phase.rounded()) < 1e-6
        var entries: [(string: Int, midi: Int, note: TabNote)] = []
        for (i, n) in tev.notes.enumerated() where i < e.midiNotes.count && n.fret >= 0 {
            let idx = tuning.count - n.string
            guard idx >= 0, idx < tuning.count else { continue }
            entries.append((idx, e.midiNotes[i], n))
        }
        entries.sort { $0.string < $1.string }
        let roll = entries.count >= 3
        var order = entries
        if roll, tev.stroke == .up { order.reverse() }
        let evDur = max(tev.duration, 0.05) * spb
        let tj = jitter(0.008)
        for (i, en) in order.enumerated() {
            if en.note.technique == .tie { continue }
            var v: Float = onBeat ? 0.78 : 0.7
            if en.string <= 1 && entries.count > 1 { v += 0.05 }
            if en.note.technique == .hammerOn || en.note.technique == .pullOff { v *= 0.75 }
            v = min(max(v + Float(jitter(0.1)), 0.05), 1)
            var fixed: Double? = nil
            if en.note.technique == .mute { v = 0.35; fixed = 0.06 }
            notes_append(RawNote(time: max(0, t0 + tj + (roll ? Double(i) * 0.007 : 0)), midi: en.midi, velocity: v,
                                 string: en.string, event: e.index, fixedDuration: fixed, minDuration: evDur))
        }
    }

    // MARK: durations

    /// Notes ring until the next stroke on the same string (or a chord change that damps it).
    func finalize() -> [NoteEvent] {
        var byString: [Int: [Int]] = [:]
        for (i, n) in notes.enumerated() { byString[n.string, default: []].append(i) }
        var barrierByString: [Int: [Double]] = [:]
        for b in barriers { barrierByString[b.string, default: []].append(b.time) }
        for k in barrierByString.keys { barrierByString[k]!.sort() }
        let offset = PerformancePlanner.countInSeconds(timeline, options)
        var out: [NoteEvent] = []
        out.reserveCapacity(notes.count)
        for (s, idxs) in byString {
            let times = idxs.map { notes[$0].time }.sorted()
            let bars = barrierByString[s] ?? []
            for i in idxs {
                let n = notes[i]
                var dur: Double
                if let f = n.fixedDuration {
                    dur = f
                } else {
                    var next = Double.infinity
                    if let nt = firstGreater(times, n.time + 1e-9) { next = nt }
                    if let bt = firstGreater(bars, n.time + 1e-9) { next = min(next, bt) }
                    if next.isFinite { dur = next - n.time } else { dur = max(n.minDuration, 4.0) }
                    dur = min(dur, maxRing)
                    dur = max(dur, 0.02)
                }
                out.append(NoteEvent(time: n.time + offset, midi: n.midi, velocity: n.velocity, duration: dur,
                                     stringIndex: s, eventIndex: n.event))
            }
        }
        return out
    }

    func firstGreater(_ sorted: [Double], _ x: Double) -> Double? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] > x { hi = mid } else { lo = mid + 1 }
        }
        return lo < sorted.count ? sorted[lo] : nil
    }
}
