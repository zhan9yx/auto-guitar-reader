import Foundation

// MARK: - Audio front-end (DESIGN §4.1)

public struct FeatureConfig: Sendable {
    public var sampleRate: Double = 22050
    public var windowSize = 4096
    public var hopSize = 512
    public var minMidi = 40
    public var maxMidi = 88
    /// Log compression: log(1 + gamma * x), x = band amplitude (sqrt of band power, sine amplitude = 1).
    public var gamma: Double = 100
    /// Frames below this RMS are always silent (about -54 dBFS).
    public var absoluteFloor: Double = 0.002
    /// Gate opens above `noiseFloor * gateRatio`; closes below 0.7 x that (hysteresis).
    public var gateRatio: Double = 3
    /// The tracked noise floor never exceeds this (a sustained loud signal must not raise the gate forever).
    public var noiseFloorCeiling: Double = 0.02
    /// Time for the tracked floor to double while the signal stays above it.
    public var noiseFloorDoublingSeconds: Double = 20
    /// Spectral peaks below this frequency are assigned to semitones by parabolic interpolation of the peak
    /// position (energy of the 3 bins around the peak) instead of by band overlap, which would smear low notes
    /// over +-2 semitones. 0 disables.
    public var sharpenBelowHz: Double = 400

    public init() {}
    public init(sampleRate: Double = 22050, windowSize: Int = 4096, hopSize: Int = 512, minMidi: Int = 40, maxMidi: Int = 88) {
        self.sampleRate = sampleRate
        self.windowSize = windowSize
        self.hopSize = hopSize
        self.minMidi = minMidi
        self.maxMidi = maxMidi
    }

    public var frameRate: Double { sampleRate / Double(hopSize) }
}

public struct FeatureFrame: Sendable {
    /// Seconds: centre of the analysis window (frame k is centred on k * hop / sampleRate; the first frame sees
    /// window/2 samples of zero padding). A live frame is therefore available window/2 after its `time`.
    public var time: Double
    public var semitone: [Float]
    public var chroma: [Float]
    public var bassChroma: [Float]
    public var onset: Float
    public var rms: Float
    public var isSilent: Bool

    public init(time: Double, semitone: [Float], chroma: [Float], bassChroma: [Float],
                onset: Float, rms: Float, isSilent: Bool) {
        self.time = time
        self.semitone = semitone
        self.chroma = chroma
        self.bassChroma = bassChroma
        self.onset = onset
        self.rms = rms
        self.isSilent = isSilent
    }
}

/// Streaming feature extractor. Push arbitrary-size chunks at any input sample rate; audio is resampled to
/// `config.sampleRate` (windowed-sinc, see `StreamResampler`), framed with a Hann window and analysed:
/// * semitone spectrum S[m], MIDI minMidi...maxMidi: each FFT bin's power is distributed over semitone bands
///   (centre ± 50 cents) proportionally to overlap, so low notes (bins sparser than semitones) conserve energy;
///   then log(1 + gamma x) with x = sqrt(band power) in amplitude units (a full-scale sine gives x ~ 1);
/// * chroma (folded from S, mild low-frequency emphasis, L2-normalised), bass chroma (MIDI 40...55, L2-normalised);
/// * onset = half-wave-rectified spectral flux of S; rms of the window;
/// * adaptive noise gate with hysteresis (slow-rising running minimum of RMS as noise floor).
/// Not thread-safe.
public final class FeatureExtractor {
    public let config: FeatureConfig
    public let inputSampleRate: Double

    private let resampler: StreamResampler
    private let fft: FFT
    private let window: [Float]
    private let nSemi: Int
    private let semiStart: [Int]
    private let binIdx: [Int]
    private let binW: [Float]
    private let chromaW: [Float]
    private let bassCount: Int
    private let bassW: [Float]
    private let kSharp: Int
    private let binHz: Double
    private var low: [Float]
    private let normScale: Float

    private var sig: [Float] = []
    private var frameStart = 0
    private var frameIndex = 0
    private var scratchIn: [Float]
    private var re: [Float], im: [Float], power: [Float]
    private var prevSemi: [Float]
    private var havePrev = false
    private var noiseFloor: Double
    private var silent = true
    private let floorRise: Double
    private var resampled: [Float] = []

    public init(config: FeatureConfig = .init(), inputSampleRate: Double) {
        self.config = config
        self.inputSampleRate = inputSampleRate
        resampler = StreamResampler(inputRate: inputSampleRate, outputRate: config.sampleRate)
        let n = config.windowSize
        fft = FFT(size: n)
        var w = [Float](repeating: 0, count: n)
        var sumW = 0.0
        for i in 0..<n {
            let v = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            w[i] = Float(v); sumW += v
        }
        window = w
        normScale = Float(2.0 / sumW)

        nSemi = config.maxMidi - config.minMidi + 1
        let df = config.sampleRate / Double(n)
        let nBins = n / 2
        // Below `sharpenBelowHz` the bins are too coarse for band summation (Hann main lobe of +-2 bins spans
        // several semitones around 100 Hz); those peaks are located by parabolic interpolation instead.
        let ks = max(3, Int((config.sharpenBelowHz / df).rounded()))
        kSharp = ks
        binHz = df
        var start = [0], idx: [Int] = [], wts: [Float] = []
        for m in config.minMidi...config.maxMidi {
            let fc = 440.0 * pow(2.0, Double(m - 69) / 12.0)
            let lo = fc * pow(2.0, -1.0 / 24.0), hi = fc * pow(2.0, 1.0 / 24.0)
            let kLo = max(ks, Int(floor(lo / df)) - 1), kHi = min(nBins, Int(ceil(hi / df)) + 1)
            if kLo <= kHi {
                for k in kLo...kHi {
                    let a = max(lo, (Double(k) - 0.5) * df), b = min(hi, (Double(k) + 0.5) * df)
                    let ov = b - a
                    if ov > 0 { idx.append(k); wts.append(Float(ov / df)) }
                }
            }
            start.append(idx.count)
        }
        semiStart = start; binIdx = idx; binW = wts
        // Mild emphasis of low notes (their partials are weaker than the upper harmonics they generate).
        chromaW = (0..<(config.maxMidi - config.minMidi + 1)).map { i in
            Float(1.4 - 0.7 * Double(i) / Double(max(config.maxMidi - config.minMidi, 1)))
        }
        bassCount = max(0, min(55, config.maxMidi) - config.minMidi + 1)
        // Bass chroma favours the lowest notes (weight 1.0 at MIDI 40 down to 0.6 at MIDI 55).
        bassW = (0..<max(bassCount, 0)).map { Float(1.0 - 0.4 * Double($0) / 15.0) }
        low = [Float](repeating: 0, count: config.maxMidi - config.minMidi + 1)

        scratchIn = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n / 2 + 1)
        im = re
        power = re
        prevSemi = [Float](repeating: 0, count: nSemi)
        noiseFloor = config.noiseFloorCeiling
        floorRise = pow(2.0, (Double(config.hopSize) / config.sampleRate) / max(config.noiseFloorDoublingSeconds, 1e-3))
        reset()
    }

    public func reset() {
        resampler.reset()
        sig = [Float](repeating: 0, count: config.windowSize / 2)
        frameStart = 0
        frameIndex = 0
        havePrev = false
        for i in 0..<nSemi { prevSemi[i] = 0 }
        noiseFloor = config.noiseFloorCeiling
        silent = true
    }

    public func process(_ samples: [Float]) -> [FeatureFrame] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) -> [FeatureFrame] {
        resampled.removeAll(keepingCapacity: true)
        resampler.process(samples, into: &resampled)
        sig.append(contentsOf: resampled)
        var frames: [FeatureFrame] = []
        let n = config.windowSize
        while frameStart + n <= sig.count {
            frames.append(analyse(at: frameStart))
            frameStart += config.hopSize
            frameIndex += 1
        }
        if frameStart >= 16 * n {
            sig.removeFirst(frameStart)
            frameStart = 0
        }
        return frames
    }

    private func analyse(at start: Int) -> FeatureFrame {
        let n = config.windowSize
        var sumSq = 0.0
        sig.withUnsafeBufferPointer { sp in
            window.withUnsafeBufferPointer { wp in
                scratchIn.withUnsafeMutableBufferPointer { ip in
                    var s: Float = 0
                    for i in 0..<n {
                        let x = sp[start + i]
                        s += x * x
                        ip[i] = x * wp[i]
                    }
                    sumSq = Double(s)
                }
            }
        }
        let rms = (sumSq / Double(n)).squareRoot()

        var semi = [Float](repeating: 0, count: nSemi)
        scratchIn.withUnsafeBufferPointer { ip in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { imp in
                    power.withUnsafeMutableBufferPointer { pp in
                        fft.powerSpectrum(ip.baseAddress!, power: pp.baseAddress!, re: rp.baseAddress!, im: imp.baseAddress!)
                        let gamma = Float(config.gamma)
                        let ns2 = normScale * normScale
                        sharpenLowPeaks(pp)
                        for m in 0..<nSemi {
                            var x: Float = low[m]
                            for j in semiStart[m]..<semiStart[m + 1] { x += binW[j] * pp[binIdx[j]] }
                            semi[m] = logf(1 + gamma * (x * ns2).squareRoot())
                        }
                    }
                }
            }
        }

        // Onset: half-wave rectified flux (0 for the very first frame).
        var flux: Float = 0
        if havePrev {
            for m in 0..<nSemi { let d = semi[m] - prevSemi[m]; if d > 0 { flux += d } }
        }
        prevSemi = semi
        havePrev = true

        // Noise gate with hysteresis.
        noiseFloor = min(noiseFloor * floorRise, rms, config.noiseFloorCeiling)
        noiseFloor = max(noiseFloor, 1e-7)
        let open = max(config.absoluteFloor, noiseFloor * config.gateRatio)
        if silent { if rms > open { silent = false } } else if rms < 0.7 * open { silent = true }

        var chroma = [Float](repeating: 0, count: 12)
        var bass = [Float](repeating: 0, count: 12)
        if !silent {
            for m in 0..<nSemi {
                let pc = (config.minMidi + m) % 12
                chroma[pc] += semi[m] * chromaW[m]
                if m < bassCount { bass[pc] += semi[m] * bassW[m] }
            }
            FeatureExtractor.l2Normalize(&chroma)
            FeatureExtractor.l2Normalize(&bass)
        }
        let time = Double(frameIndex * config.hopSize) / config.sampleRate
        return FeatureFrame(time: time, semitone: semi, chroma: chroma, bassChroma: bass,
                            onset: flux, rms: Float(rms), isSilent: silent)
    }

    /// Fills `low[m]` with the energy of spectral peaks below `sharpenBelowHz`, assigned to the semitone containing
    /// the parabolically interpolated peak frequency.
    private func sharpenLowPeaks(_ pp: UnsafeMutableBufferPointer<Float>) {
        for i in 0..<nSemi { low[i] = 0 }
        guard config.sharpenBelowHz > 0 else { return }
        let top = min(kSharp, pp.count - 2)
        guard top > 2 else { return }
        for k in 2..<top {
            let c = pp[k]
            guard c > 1e-14, c > pp[k - 1], c >= pp[k + 1] else { continue }
            let l0 = logf(pp[k - 1] + 1e-20), l1 = logf(c), l2 = logf(pp[k + 1] + 1e-20)
            let den = l0 - 2 * l1 + l2
            var d: Float = den < -1e-9 ? 0.5 * (l0 - l2) / den : 0
            d = min(max(d, -0.5), 0.5)
            let f = (Double(k) + Double(d)) * binHz
            let m = Int((12 * log2(f / 440.0) + 69).rounded()) - config.minMidi
            if m >= 0 && m < nSemi { low[m] += pp[k - 1] + c + pp[k + 1] }
        }
    }

    static func l2Normalize(_ v: inout [Float]) {
        var s: Float = 0
        for x in v { s += x * x }
        guard s > 1e-12 else { for i in v.indices { v[i] = 0 }; return }
        let inv = 1 / s.squareRoot()
        for i in v.indices { v[i] *= inv }
    }
}
