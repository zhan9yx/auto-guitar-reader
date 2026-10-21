import Foundation

// MARK: - Synthetic takes for evaluation (DESIGN §4.5)
//
// Renders the score with PerformancePlanner + OfflineRenderer (GuitarSynth) and then "performs" it:
//  * global tempo drift (bounded random walk of the playing speed, +-tempoDrift),
//  * per-event timing jitter,
//  * optional 1-2 s pauses between sections,
//  * optional voice: one harmonic tone per lyric syllable (150-400 Hz fundamental, 6-10 harmonics with a formant-like
//    envelope, 5-6 Hz vibrato, +-30 cents drift) on a chord tone or scale tone, 0-6 dB LOUDER than the guitar,
//  * pink noise at the requested SNR, optional room smearing.
// The ground truth is the (warped) start time of every timeline event.

public struct TakeOptions: Sendable {
    public var seed: UInt64 = 1
    /// Max deviation of the playing speed from the notated tempo (0.15 = +-15 %).
    public var tempoDrift: Double = 0.15
    public var snrDB: Double = 15
    public var withVoice: Bool = false
    /// Voice level relative to the guitar (dB, positive = louder), drawn per take.
    public var voiceLevelDB: ClosedRange<Double> = 0...6
    /// Std of the per-event timing jitter in seconds (limited to 12 % of the event length).
    public var timingJitter: Double = 0.03
    public var sectionPauses: Bool = false
    public var room: Bool = false
    public var sampleRate: Double = 44100
    /// Planner humanisation (strum timing / velocity randomness).
    public var humanize: Double = 0.3
    public var tempoScale: Double = 1
    /// Notes ring at most this long into a pause.
    public var pauseRing: Double = 0.5

    public init() {}
}

public struct SyntheticTake: Sendable {
    public var audio: [Float]
    public var sampleRate: Double
    /// Change points: event `eventIndex` starts at `time` (sorted by time).
    public var truth: [(time: Double, eventIndex: Int)]
    /// Time at which the last event nominally ends (end of the scored region).
    public var scoreEndTime: Double
    /// Each sung syllable (character of the lyrics), its start time and the event it belongs to.
    public var lyricChars: [(time: Double, char: Character, eventIndex: Int)]
    public var timeline: Timeline
}

enum TakeSynthesizer {
    // MARK: random helpers
    struct Rng {
        var g: SplitMix64
        init(seed: UInt64) { g = SplitMix64(seed: seed) }
        mutating func uniform() -> Double { (g.signed() + 1) / 2 }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
        mutating func gauss() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
        mutating func int(_ n: Int) -> Int { min(n - 1, Int(uniform() * Double(n))) }
    }

    // MARK: tempo / time warp

    struct Warp {
        let dt: Double
        var cum: [Double]            // actual time at nominal k*dt
        var pauses: [(at: Double, length: Double)]   // nominal time, extra seconds

        func base(_ t: Double) -> Double {
            if t <= 0 { return t }
            let x = t / dt
            let k = min(Int(x), cum.count - 2)
            let f = x - Double(k)
            if k < 0 { return t }
            return cum[k] + f * (cum[k + 1] - cum[k])
        }
        func shift(before t: Double) -> Double {
            var s = 0.0
            for p in pauses where p.at <= t + 1e-9 { s += p.length }
            return s
        }
        /// Actual time of a nominal time (pauses starting at or before it are included).
        func map(_ t: Double) -> Double { base(t) + shift(before: t) }
    }

    static func makeWarp(duration: Double, drift: Double, pauses: [(at: Double, length: Double)], rng: inout Rng) -> Warp {
        let dt = 0.5
        let steps = Int(duration / dt) + 8
        var cum = [0.0]
        var x = rng.range(-0.6, 0.6) * drift          // speed deviation
        let sigma = drift * 0.18
        for _ in 0..<steps {
            let speed = 1 + x
            cum.append(cum.last! + dt / max(speed, 0.2))
            x += sigma * rng.gauss() - 0.02 * x        // slight pull to the centre
            if x > drift { x = 2 * drift - x }
            if x < -drift { x = -2 * drift - x }
            x = min(max(x, -drift), drift)
        }
        return Warp(dt: dt, cum: cum, pauses: pauses)
    }

    // MARK: main entry

    static func synthesize(score: Score, timeline: Timeline, options o: TakeOptions) -> SyntheticTake {
        var rng = Rng(seed: o.seed &* 0x9E37_79B9 &+ 17)
        let events = timeline.events
        let popts = PlaybackOptions(tempoScale: o.tempoScale, humanize: o.humanize, seed: o.seed)
        let spb = PerformancePlanner.secondsPerBeat(timeline, popts)
        let planned = PerformancePlanner.plan(timeline, score: score, options: popts)
        let nominalEnd = timeline.totalBeats * spb

        // Pauses at section pass starts.
        var pauses: [(at: Double, length: Double)] = []
        if o.sectionPauses {
            for sp in timeline.sectionPasses.dropFirst() where sp.firstEvent < events.count {
                if rng.uniform() < 0.7 { pauses.append((events[sp.firstEvent].startBeat * spb, rng.range(1, 2))) }
            }
        }
        let warp = makeWarp(duration: nominalEnd + 5, drift: o.tempoDrift, pauses: pauses, rng: &rng)

        // Per-event jitter (seconds), limited by the event length.
        var jitter = [Double](repeating: 0, count: events.count)
        for (i, e) in events.enumerated() {
            let len = e.beats * spb
            let s = min(o.timingJitter, 0.12 * len)
            jitter[i] = max(-2 * s, min(2 * s, rng.gauss() * s))
        }
        var eventStart = [Double](repeating: 0, count: events.count)
        for (i, e) in events.enumerated() {
            eventStart[i] = max(0, warp.map(e.startBeat * spb) + jitter[i])
        }
        // Keep starts strictly increasing.
        for i in 1..<max(events.count, 1) where eventStart[i] <= eventStart[i - 1] + 0.02 { eventStart[i] = eventStart[i - 1] + 0.02 }

        // Warp the planned notes.
        var warped: [NoteEvent] = []
        warped.reserveCapacity(planned.count)
        for ne in planned {
            var n = ne
            let j = ne.eventIndex >= 0 && ne.eventIndex < jitter.count ? jitter[ne.eventIndex] : 0
            let t0 = warp.map(ne.time)
            n.time = max(0, t0 + j)
            var end = warp.base(ne.time + ne.duration) + warp.shift(before: ne.time) + j
            // A pause that starts while the note rings: let it decay for `pauseRing` seconds only.
            for p in pauses where p.at > ne.time && p.at < ne.time + ne.duration {
                end = min(end, warp.base(p.at) + warp.shift(before: ne.time) + o.pauseRing + j)
            }
            n.duration = max(0.02, end - n.time)
            warped.append(n)
        }
        var guitar = OfflineRenderer.render(warped, sampleRate: o.sampleRate, tail: 1.5)

        // Voice.
        var lyricChars: [(time: Double, char: Character, eventIndex: Int)] = []
        let endTimes: [Double] = (0..<events.count).map { i in
            i + 1 < events.count ? eventStart[i + 1] : warp.map(nominalEnd) + jitter[i]
        }
        var voice = [Float](repeating: 0, count: guitar.count)
        // Syllable schedule (also used for the lyric simulation, independent of `withVoice`).
        struct Syl { var t0: Double; var t1: Double; var event: Int; var ch: Character }
        var syls: [Syl] = []
        for (i, e) in events.enumerated() {
            let chars = Array(e.lyric.filter { $0.isLetter || $0.isNumber })
            guard !chars.isEmpty else { continue }
            var span = endTimes[i] - eventStart[i]
            // A pause at the end of a section: the singer finishes before it.
            span = min(span, max(0.8, e.beats * spb * 1.3))
            let each = span / Double(chars.count)
            for (k, c) in chars.enumerated() {
                let off = rng.range(-0.03, 0.03)
                let t0 = max(0, eventStart[i] + Double(k) * each + off + 0.02)
                let dur = min(max(each * 0.82, 0.12), 0.9)
                syls.append(Syl(t0: t0, t1: t0 + dur, event: i, ch: c))
                lyricChars.append((t0, c, i))
            }
        }

        if o.withVoice && !syls.isEmpty {
            let rate = o.sampleRate
            var prevMidi = 60.0
            var drift = 0.0
            for s in syls {
                let e = events[s.event]
                // Pitch: chord tone (55 %) or scale tone of the chord root.
                var pcs: [Int] = Array(Set(e.midiNotes.map { (($0 % 12) + 12) % 12 })).sorted()
                let rootPC = e.chord.map { ($0.root + timeline.capo) % 12 } ?? (e.midiNotes.min().map { $0 % 12 } ?? 0)
                let minor = e.chord.map { [.minor, .min7, .min9, .min6, .minAdd9, .min11].contains($0.quality) } ?? false
                let scale = (minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { (rootPC + $0) % 12 }
                if pcs.isEmpty || rng.uniform() > 0.55 { pcs = scale }
                let pc = pcs[rng.int(pcs.count)]
                var cands: [Int] = []
                for m in 51...67 where m % 12 == pc { cands.append(m) }
                if cands.isEmpty { cands = [60] }
                // Prefer continuity with the previous pitch.
                let scored = cands.map { (abs(Double($0) - prevMidi) + rng.uniform() * 3, $0) }
                let m = scored.min { $0.0 < $1.0 }!.1
                prevMidi = Double(m)
                let nHarm = 6 + rng.int(5)
                let (f1, f2) = formants(rng.int(5))
                let f0 = 440 * pow(2, (Double(m) - 69) / 12)
                // Harmonic table.
                let tableSize = 1024
                var table = [Float](repeating: 0, count: tableSize + 1)
                var amps: [Double] = []
                for h in 1...nHarm {
                    let f = f0 * Double(h)
                    let g1 = exp(-0.5 * pow((f - f1) / (0.35 * f1), 2)), g2 = exp(-0.5 * pow((f - f2) / (0.3 * f2), 2))
                    amps.append(pow(Double(h), -0.8) * (0.25 + g1 + 0.6 * g2))
                }
                for k in 0...tableSize {
                    let ph = 2 * Double.pi * Double(k) / Double(tableSize)
                    var v = 0.0
                    for (h, a) in amps.enumerated() { v += a * sin(ph * Double(h + 1)) }
                    table[k] = Float(v)
                }
                let a0 = Int(s.t0 * rate), a1 = min(Int(s.t1 * rate), voice.count)
                guard a1 > a0 else { continue }
                let vibRate = rng.range(5, 6), vibDepth = rng.range(12, 30)
                let vibPhase = rng.range(0, 2 * Double.pi)
                var phase = rng.range(0, 1)
                let att = max(Int(0.03 * rate), 1), rel = max(Int(0.05 * rate), 1)
                for i in a0..<a1 {
                    let t = Double(i - a0) / rate
                    drift += 0.0004 * rng.gauss()
                    drift = max(-30, min(30, drift)) * 0.9999
                    let cents = vibDepth * sin(2 * Double.pi * vibRate * t + vibPhase) + drift
                    let f = f0 * pow(2, cents / 1200)
                    phase += f / rate
                    phase -= floor(phase)
                    let x = phase * Double(tableSize)
                    let k = Int(x)
                    let fr = Float(x - Double(k))
                    var v = table[k] * (1 - fr) + table[k + 1] * fr
                    let pos = i - a0, left = a1 - i
                    if pos < att { v *= Float(pos) / Float(att) }
                    if left < rel { v *= Float(left) / Float(rel) }
                    voice[i] = v
                }
            }
            // Level relative to the guitar (RMS over the active parts of each).
            let gRMS = activeRMS(guitar, rate: rate)
            let vRMS = activeRMS(voice, rate: rate)
            let level = rng.range(o.voiceLevelDB.lowerBound, o.voiceLevelDB.upperBound)
            if vRMS > 1e-9 {
                let gain = Float(gRMS * pow(10, level / 20) / vRMS)
                for i in 0..<guitar.count { guitar[i] += voice[i] * gain }
            }
        }

        // Room smearing.
        var mix = guitar
        if o.room { mix = roomSmear(mix, rate: o.sampleRate, rng: &rng) }

        // Pink noise at the requested SNR (relative to the active signal RMS).
        let sRMS = activeRMS(mix, rate: o.sampleRate)
        if sRMS > 1e-9 && o.snrDB < 200 {
            var noise = pinkNoise(mix.count, rng: &rng)
            var nr = 0.0
            for x in noise { nr += Double(x) * Double(x) }
            nr = (nr / Double(max(noise.count, 1))).squareRoot()
            let target = sRMS / pow(10, o.snrDB / 20)
            let g = Float(target / max(nr, 1e-12))
            for i in 0..<noise.count { noise[i] *= g; mix[i] += noise[i] }
        }
        // Normalise the peak (microphone gain), keeps the SNR.
        var peak: Float = 0
        for x in mix { peak = max(peak, abs(x)) }
        if peak > 1e-6 { let g = 0.5 / peak; for i in 0..<mix.count { mix[i] *= g } }

        var truth: [(time: Double, eventIndex: Int)] = []
        for i in 0..<events.count { truth.append((eventStart[i], i)) }
        let scoreEnd = warp.map(nominalEnd) + (jitter.last ?? 0)
        return SyntheticTake(audio: mix, sampleRate: o.sampleRate, truth: truth, scoreEndTime: scoreEnd,
                             lyricChars: lyricChars, timeline: timeline)
    }

    // MARK: voice / noise helpers

    static func formants(_ vowel: Int) -> (Double, Double) {
        switch vowel {
        case 0: return (800, 1200)   // a
        case 1: return (500, 1800)   // e
        case 2: return (300, 2300)   // i
        case 3: return (450, 800)    // o
        default: return (325, 700)   // u
        }
    }

    /// RMS over 50 ms blocks whose own RMS is above -50 dBFS relative to the loudest block.
    static func activeRMS(_ x: [Float], rate: Double) -> Double {
        let block = max(Int(0.05 * rate), 1)
        var sums: [Double] = []
        var i = 0
        while i + block <= x.count {
            var s = 0.0
            for j in i..<(i + block) { s += Double(x[j]) * Double(x[j]) }
            sums.append(s / Double(block))
            i += block
        }
        guard let mx = sums.max(), mx > 0 else { return 0 }
        var tot = 0.0, c = 0
        for s in sums where s > mx * 1e-4 { tot += s; c += 1 }
        return c > 0 ? (tot / Double(c)).squareRoot() : 0
    }

    /// Paul Kellet's economy pink filter driven by uniform noise.
    static func pinkNoise(_ n: Int, rng: inout Rng) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for i in 0..<n {
            let w = rng.g.signed()
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            out[i] = Float(b0 + b1 + b2 + w * 0.1848)
        }
        return out
    }

    /// Schroeder reverb: 4 feedback combs (RT60 ~ 0.4 s) + 2 all-passes, 30 % wet.
    static func roomSmear(_ x: [Float], rate: Double, rng: inout Rng) -> [Float] {
        let delays = [0.0297, 0.0371, 0.0411, 0.0437].map { Int($0 * rate * rng.range(0.95, 1.05)) }
        let rt60 = 0.4
        var wet = [Float](repeating: 0, count: x.count)
        for d in delays {
            let g = Float(pow(10, -3 * Double(d) / rate / rt60))
            var buf = [Float](repeating: 0, count: d)
            var p = 0
            for i in 0..<x.count {
                let y = x[i] + g * buf[p]
                buf[p] = y
                p += 1; if p == d { p = 0 }
                wet[i] += y * 0.25
            }
        }
        for (d, g) in [(Int(0.005 * rate), Float(0.7)), (Int(0.0017 * rate), Float(0.7))] {
            var buf = [Float](repeating: 0, count: d)
            var p = 0
            for i in 0..<wet.count {
                let v = wet[i] - g * buf[p]
                let y = buf[p] + g * v
                buf[p] = v
                p += 1; if p == d { p = 0 }
                wet[i] = y
            }
        }
        var out = x
        for i in 0..<x.count { out[i] = 0.7 * x[i] + 0.3 * wet[i] }
        return out
    }
}
