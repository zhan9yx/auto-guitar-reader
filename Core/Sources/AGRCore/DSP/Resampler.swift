import Foundation

// MARK: - Streaming resampler
//
// Windowed-sinc (Kaiser, beta = 8) polyphase interpolator with linear interpolation between 256 phase rows.
// Cutoff = 0.46 x output sample rate (anti-aliasing when downsampling), 10 zero-crossings per side.
// Quality: > 70 dB stop-band rejection above the output Nyquist, passband ripple < 0.01 dB up to ~0.40 x output rate
// (the feature extractor only uses < 1.3 kHz). Latency: `halfWidth` input samples of look-ahead (output sample
// time is exact: output sample m corresponds to input time m * inRate / outRate).
// When input and output rates are equal the stage is a pass-through.

final class StreamResampler {
    let inputRate: Double
    let outputRate: Double
    let passThrough: Bool
    private let step: Double
    private let halfWidth: Int
    private let phases = 256
    private var table: [Float] = []      // (phases + 1) rows x (2 * halfWidth)
    private var hist: [Float] = []
    private var base: Int = 0            // absolute input index of hist[0]
    private var outCount: Int = 0

    init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.passThrough = abs(inputRate - outputRate) < 1e-9
        self.step = inputRate / outputRate
        let fcn = min(0.5 * 0.95, 0.46 * outputRate / inputRate)   // cutoff, cycles per input sample
        self.halfWidth = passThrough ? 0 : Int((10.0 / (2 * fcn)).rounded(.up))
        if !passThrough { buildTable(fcn: fcn) }
        reset()
    }

    func reset() {
        hist = [Float](repeating: 0, count: halfWidth)
        base = -halfWidth
        outCount = 0
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        var k = 1.0
        while term > 1e-12 * sum {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }

    private func buildTable(fcn: Double) {
        let h = halfWidth, taps = 2 * h
        let beta = 8.0
        let i0b = StreamResampler.besselI0(beta)
        table = [Float](repeating: 0, count: (phases + 1) * taps)
        for r in 0...phases {
            let frac = Double(r) / Double(phases)
            for j in 0..<taps {
                let d = frac + Double(h) - 1 - Double(j)
                let x = 2 * fcn * d
                let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let u = d / Double(h)
                let win = abs(u) >= 1 ? 0.0 : StreamResampler.besselI0(beta * (1 - u * u).squareRoot()) / i0b
                table[r * taps + j] = Float(2 * fcn * sinc * win)
            }
        }
    }

    /// Appends resampled output for `input` to `out`.
    func process(_ input: UnsafeBufferPointer<Float>, into out: inout [Float]) {
        if passThrough {
            out.append(contentsOf: input)
            return
        }
        hist.append(contentsOf: input)
        let total = base + hist.count
        let h = halfWidth, taps = 2 * h
        table.withUnsafeBufferPointer { tb in
            hist.withUnsafeBufferPointer { hb in
                while true {
                    let pos = Double(outCount) * step
                    let n0 = Int(pos.rounded(.down))
                    if n0 + h >= total { break }
                    let fr = (pos - Double(n0)) * Double(phases)
                    let r = min(Int(fr), phases - 1)
                    let t = Float(fr - Double(r))
                    let row0 = tb.baseAddress! + r * taps
                    let row1 = row0 + taps
                    let start = n0 - h + 1 - base
                    var acc: Float = 0
                    for j in 0..<taps {
                        let c = row0[j] + t * (row1[j] - row0[j])
                        acc += hb[start + j] * c
                    }
                    out.append(acc)
                    outCount += 1
                }
            }
        }
        // Drop history we no longer need.
        let nextN0 = Int((Double(outCount) * step).rounded(.down))
        let drop = nextN0 - h + 1 - base
        if drop > 4096 {
            hist.removeFirst(drop)
            base += drop
        }
    }
}
