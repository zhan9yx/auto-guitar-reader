import Foundation

// MARK: - GuitarSynth
//
// Extended Karplus-Strong plucked string (Jaffe & Smith), six independent voices (one per string):
//
//   excitation (noise burst, velocity-shaped one-pole lowpass, pick-position comb)
//        -> delay line (N samples) -> one-pole loop lowpass (brightness) -> first-order allpass
//           (fractional delay, exactly tuned at f0 so pitch error is well below 1 cent) -> loop gain
//
// Loop delay bookkeeping:  N + phaseDelay(lowpass @ f0) + D(allpass) = fs / f0,   D in [1, 2).
// Loop gain is derived from the desired T60 of the fundamental (low strings ~6 s, high ~2.5 s).
// Output stage: DC blocker -> parallel body resonances (~100 / 200 / 400 Hz biquad band-passes) -> soft limiter.
//
// Real-time safety: every buffer is allocated in `init`; `pluck`, `mute` and `render` do not allocate,
// lock or call into Foundation types (only libm math functions in `pluck`).
// Threading: not thread-safe. `render`, `pluck`, `mute` and the parameter properties must be used from one thread
// (the audio thread). `render` OVERWRITES `buffer` (mono).

public final class GuitarSynth {
    public let sampleRate: Double
    /// 0...1: loop damping (higher = brighter, longer-lived harmonics).
    public var brightness: Float = 0.5
    /// 0...1: amount of body resonance mixed in.
    public var bodyResonance: Float = 0.5
    /// 0...1: output gain.
    public var volume: Float = 0.8

    static let voiceCount = 6
    static let chunk = 4096

    private struct Voice {
        var buf: UnsafeMutablePointer<Float>
        var length: Int = 2
        var idx: Int = 0
        var p: Float = 0
        var y1: Float = 0
        var a: Float = 0
        var apIn: Float = 0
        var apOut: Float = 0
        var gain: Float = 0
        var active: Bool = false
        var muteGain: Float = 1
        var muteMul: Float = 1
        var quiet: Int = 0
    }

    private let voices: UnsafeMutablePointer<Voice>
    private let capacity: Int
    private let acc: UnsafeMutablePointer<Float>
    private var noiseState: UInt32 = 0x1234_5678

    // Output stage state.
    private var dcX: Float = 0, dcY: Float = 0
    private let dcR: Float
    private struct Biquad {
        var b0: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0
        var gain: Float = 1
    }
    private let body: UnsafeMutablePointer<Biquad>
    private let muteMulPerSample: Float

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let minFreq = 50.0
        capacity = Int(sampleRate / minFreq) + 16
        voices = UnsafeMutablePointer<Voice>.allocate(capacity: GuitarSynth.voiceCount)
        for i in 0..<GuitarSynth.voiceCount {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            b.initialize(repeating: 0, count: capacity)
            (voices + i).initialize(to: Voice(buf: b))
        }
        acc = UnsafeMutablePointer<Float>.allocate(capacity: GuitarSynth.chunk)
        acc.initialize(repeating: 0, count: GuitarSynth.chunk)
        dcR = Float(1 - 2 * Double.pi * 20 / sampleRate)
        muteMulPerSample = Float(pow(10.0, -3.0 / (0.04 * sampleRate)))
        body = UnsafeMutablePointer<Biquad>.allocate(capacity: 3)
        let specs: [(Double, Double, Float)] = [(100, 5, 1.0), (200, 6, 0.8), (400, 5, 0.5)]
        for (i, s) in specs.enumerated() {
            let w0 = 2 * Double.pi * s.0 / sampleRate
            let alpha = sin(w0) / (2 * s.1)
            let a0 = 1 + alpha
            var bq = Biquad()
            bq.b0 = Float(alpha / a0)
            bq.b2 = Float(-alpha / a0)
            bq.a1 = Float(-2 * cos(w0) / a0)
            bq.a2 = Float((1 - alpha) / a0)
            bq.gain = s.2
            (body + i).initialize(to: bq)
        }
    }

    deinit {
        for i in 0..<GuitarSynth.voiceCount { voices[i].buf.deallocate() }
        voices.deallocate()
        acc.deallocate()
        body.deallocate()
    }

    // MARK: Parameters derived per note

    /// T60 of the fundamental in seconds: ~6 s at E2 falling to ~2.5 s at E4.
    static func fundamentalT60(midi: Double) -> Double {
        min(max(6.0 - (midi - 40) * 0.1458, 1.2), 7.0)
    }

    @inline(__always)
    private func nextNoise() -> Float {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Float(Int32(bitPattern: noiseState)) * (1.0 / 2_147_483_648.0)
    }

    /// Strikes string `stringIndex` (0 = lowest) with the given pitch; retriggers the string.
    public func pluck(midi: Int, velocity: Float, stringIndex: Int) {
        let s = min(max(stringIndex, 0), GuitarSynth.voiceCount - 1)
        let vel = min(max(velocity, 0), 1)
        let fs = sampleRate
        var f0 = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
        f0 = min(max(f0, 50.0), 0.40 * fs)
        let w0 = 2 * Double.pi * f0 / fs
        let period = fs / f0

        // Loop lowpass: pick p so a harmonic near 2.5 kHz decays with T60h (brightness-dependent).
        let b = Double(min(max(brightness, 0), 1))
        let t60h = 0.06 + (0.70 - 0.06) * b
        let fh = min(max(2500.0, 3 * f0), 0.45 * fs)
        let wh = 2 * Double.pi * fh / fs
        let m = min(max(pow(10.0, -3.0 / (t60h * f0)), 0.05), 0.99999)
        let qa = 1 - m * m
        var p = 0.0
        if qa > 1e-9 {
            let qb = -2 * (1 - m * m * cos(wh))
            let disc = max(qb * qb - 4 * qa * qa, 0)
            p = (-qb - disc.squareRoot()) / (2 * qa)
        }
        p = min(max(p, 0), 0.92)
        let tau = atan2(p * sin(w0), 1 - p * cos(w0)) / w0                 // lowpass phase delay (samples)
        let h0 = (1 - p) / (1 - 2 * p * cos(w0) + p * p).squareRoot()       // lowpass gain at f0
        let t60 = GuitarSynth.fundamentalT60(midi: Double(midi))
        let gTarget = pow(10.0, -3.0 / (t60 * f0))
        let g = min(gTarget / h0, 0.99995)

        var n = Int((period - tau - 1.0).rounded(.down))
        n = min(max(n, 2), capacity - 4)
        let d = period - tau - Double(n)                                     // allpass delay, ~[1,2)
        let a = sin(w0 * (1 - d) / 2) / sin(w0 * (1 + d) / 2)

        // Excitation: white noise through a one-pole lowpass whose corner (in Hz) depends on velocity and
        // brightness (softer = darker), pick-position comb, DC removal. Loudness is scaled with sqrt(N) so partial
        // amplitudes below the corner are comparable across strings (a periodic buffer of N noise samples spreads
        // its power over ~N/2 harmonics, so low strings would otherwise have thin fundamentals).
        let buf = voices[s].buf
        let velCurve = pow(Double(vel), 0.8)
        let fcExc = (600 + 4400 * velCurve) * (0.6 + 0.8 * b)
        let c = Float(min(exp(-2 * Double.pi * fcExc / fs), 0.97))
        var prev: Float = 0
        var sum: Float = 0
        for i in 0..<n {
            let x = nextNoise()
            prev = (1 - c) * x + c * prev
            buf[i] = prev
            sum += prev
        }
        let k = max(1, Int((0.13 * Double(n)).rounded()))
        if k < n {
            var i = n - 1
            while i >= k { buf[i] -= buf[i - k]; i -= 1 }
        }
        sum = 0
        for i in 0..<n { sum += buf[i] }
        let mean = sum / Float(n)
        var e2: Float = 0
        for i in 0..<n { buf[i] -= mean; e2 += buf[i] * buf[i] }
        let rms = (e2 / Float(n)).squareRoot()
        let target = Float((0.02 + 0.11 * pow(Double(vel), 1.4)) * pow(Double(n) / 120.0, 0.4))
        let scale = rms > 1e-9 ? target / rms : 0
        for i in 0..<n { buf[i] *= scale }

        voices[s].length = n
        voices[s].idx = 0
        voices[s].p = Float(p)
        voices[s].y1 = 0
        voices[s].a = Float(a)
        voices[s].apIn = 0
        voices[s].apOut = 0
        voices[s].gain = Float(g)
        voices[s].muteGain = 1
        voices[s].muteMul = 1
        voices[s].quiet = 0
        voices[s].active = vel > 0
    }

    /// Fast damping of one string (or all when nil).
    public func mute(stringIndex: Int?) {
        if let si = stringIndex {
            guard si >= 0, si < GuitarSynth.voiceCount else { return }
            if voices[si].active { voices[si].muteMul = muteMulPerSample }
        } else {
            for i in 0..<GuitarSynth.voiceCount where voices[i].active { voices[i].muteMul = muteMulPerSample }
        }
    }

    /// True if any string is still audible.
    public var isSounding: Bool {
        for i in 0..<GuitarSynth.voiceCount where voices[i].active { return true }
        return false
    }

    // MARK: Render

    /// Renders `frameCount` mono samples into `buffer` (overwrites).
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        var done = 0
        while done < frameCount {
            let n = min(frameCount - done, GuitarSynth.chunk)
            renderChunk(buffer + done, n)
            done += n
        }
    }

    private func renderChunk(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n { acc[i] = 0 }
        for v in 0..<GuitarSynth.voiceCount where voices[v].active {
            var st = voices[v]
            let buf = st.buf
            let len = st.length
            var idx = st.idx
            let p1 = 1 - st.p, p = st.p, a = st.a, g = st.gain
            var y1 = st.y1, apIn = st.apIn, apOut = st.apOut
            var mg = st.muteGain
            let mm = st.muteMul
            var quiet = st.quiet
            var dead = false
            for i in 0..<n {
                let x = buf[idx]
                y1 = p1 * x + p * y1
                var o = a * (y1 - apOut) + apIn
                if abs(o) < 1e-18 { o = 0 }
                apIn = y1
                apOut = o
                buf[idx] = o * g
                idx += 1
                if idx == len { idx = 0 }
                let s = o * mg
                acc[i] += s
                mg *= mm
                // Deactivation depends only on the sample sequence (never on block boundaries).
                if mg < 1e-4 { dead = true; break }
                if abs(s) < 1e-6 {
                    quiet += 1
                    if quiet >= 2048 { dead = true; break }
                } else {
                    quiet = 0
                }
            }
            st.idx = idx; st.y1 = y1; st.apIn = apIn; st.apOut = apOut; st.muteGain = mg; st.quiet = quiet
            if dead { st.active = false }
            voices[v] = st
        }

        // Output stage (denormals are flushed per sample so the result never depends on block boundaries).
        let res = bodyResonance * 0.8
        let vol = volume
        var xPrev = dcX, yPrev = dcY
        let r = dcR
        for i in 0..<n {
            let x = acc[i]
            let y = x - xPrev + r * yPrev
            xPrev = x
            yPrev = abs(y) < 1e-18 ? 0 : y
            var b: Float = 0
            for k in 0..<3 {
                let bq = body[k]
                var o = bq.b0 * y + bq.z1
                if abs(o) < 1e-18 { o = 0 }
                body[k].z1 = -bq.a1 * o + bq.z2
                body[k].z2 = bq.b2 * y - bq.a2 * o
                b += bq.gain * o
            }
            var z = (yPrev + res * b) * vol
            if z.isNaN { z = 0 }
            out[i] = GuitarSynth.softLimit(z)
        }
        dcX = xPrev
        dcY = yPrev
    }

    /// Linear up to |x| = 0.6, then a smooth tanh knee towards (but never reaching) ±1.
    @inline(__always)
    static func softLimit(_ x: Float) -> Float {
        let ax = abs(x)
        if ax <= 0.6 { return x }
        let y = 0.6 + 0.4 * tanhf((ax - 0.6) / 0.4)
        return x < 0 ? -y : y
    }
}
