import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - FFT
//
// Real-input FFT of power-of-two size N. Pure Swift iterative radix-2 (a real FFT is computed as one
// N/2-point complex FFT plus an unpacking step). On Apple platforms (`#if canImport(Accelerate)`) the transform
// itself is done by vDSP_fft_zrip; the pure-Swift path is always compiled and is what Linux (and the tests'
// reference comparisons) use. `allowAccelerate: false` forces the pure path on Apple platforms.
//
// Instances own scratch buffers and are NOT thread-safe (use one per thread).

public final class FFT {
    /// Number of real input samples (power of two, >= 4).
    public let size: Int
    public let usesAccelerate: Bool

    private let half: Int
    private let log2n: Int
    private let bitrev: UnsafeMutablePointer<Int>
    private let twRe: UnsafeMutablePointer<Float>     // e^{-2 pi i k / half}, k < half/2
    private let twIm: UnsafeMutablePointer<Float>
    private let wRe: UnsafeMutablePointer<Float>      // e^{-2 pi i k / size}, k <= half
    private let wIm: UnsafeMutablePointer<Float>
    private let zr: UnsafeMutablePointer<Float>
    private let zi: UnsafeMutablePointer<Float>
    #if canImport(Accelerate)
    private var setup: FFTSetup?
    #endif

    public static func isPowerOfTwo(_ n: Int) -> Bool { n > 0 && (n & (n - 1)) == 0 }

    public init(size: Int, allowAccelerate: Bool = true) {
        precondition(FFT.isPowerOfTwo(size) && size >= 4, "FFT size must be a power of two >= 4")
        self.size = size
        half = size / 2
        var l = 0
        while (1 << l) < size { l += 1 }
        log2n = l
        let m = half
        bitrev = .allocate(capacity: m)
        var lm = 0
        while (1 << lm) < m { lm += 1 }
        for i in 0..<m {
            var r = 0, x = i
            for _ in 0..<lm { r = (r << 1) | (x & 1); x >>= 1 }
            bitrev[i] = r
        }
        twRe = .allocate(capacity: max(m / 2, 1))
        twIm = .allocate(capacity: max(m / 2, 1))
        for k in 0..<max(m / 2, 1) {
            let a = -2.0 * Double.pi * Double(k) / Double(m)
            twRe[k] = Float(cos(a)); twIm[k] = Float(sin(a))
        }
        wRe = .allocate(capacity: m + 1)
        wIm = .allocate(capacity: m + 1)
        for k in 0...m {
            let a = -2.0 * Double.pi * Double(k) / Double(size)
            wRe[k] = Float(cos(a)); wIm[k] = Float(sin(a))
        }
        zr = .allocate(capacity: m + 1)
        zi = .allocate(capacity: m + 1)
        zr.initialize(repeating: 0, count: m + 1)
        zi.initialize(repeating: 0, count: m + 1)
        #if canImport(Accelerate)
        if allowAccelerate, let s = vDSP_create_fftsetup(vDSP_Length(l), FFTRadix(kFFTRadix2)) {
            setup = s
            usesAccelerate = true
        } else {
            setup = nil
            usesAccelerate = false
        }
        #else
        usesAccelerate = false
        #endif
    }

    deinit {
        bitrev.deallocate(); twRe.deallocate(); twIm.deallocate()
        wRe.deallocate(); wIm.deallocate(); zr.deallocate(); zi.deallocate()
        #if canImport(Accelerate)
        if let s = setup { vDSP_destroy_fftsetup(s) }
        #endif
    }

    /// Forward transform of `size` real samples. Writes bins 0...size/2 (so `size/2 + 1` values) to `re` / `im`
    /// (no scaling: X[k] = sum x[n] e^{-2 pi i k n / size}).
    public func forward(_ input: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        #if canImport(Accelerate)
        if let s = setup {
            var split = DSPSplitComplex(realp: zr, imagp: zi)
            input.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
            }
            vDSP_fft_zrip(s, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            // vDSP packs Nyquist into imag[0] and scales the result by 2.
            for k in 0..<half { re[k] = zr[k] * 0.5; im[k] = zi[k] * 0.5 }
            re[half] = zi[0] * 0.5
            im[half] = 0
            im[0] = 0
            return
        }
        #endif
        let m = half
        for n in 0..<m {
            let r = bitrev[n]
            zr[r] = input[2 * n]
            zi[r] = input[2 * n + 1]
        }
        // Iterative radix-2 DIT on M complex points.
        var len = 2
        while len <= m {
            let h = len / 2
            let step = m / len
            var i = 0
            while i < m {
                var k = 0
                for j in 0..<h {
                    let wr = twRe[k], wi = twIm[k]
                    let a = i + j, b = a + h
                    let tr = zr[b] * wr - zi[b] * wi
                    let ti = zr[b] * wi + zi[b] * wr
                    zr[b] = zr[a] - tr; zi[b] = zi[a] - ti
                    zr[a] += tr; zi[a] += ti
                    k += step
                }
                i += len
            }
            len <<= 1
        }
        // Unpack: X[k] = Fe[k] + w_k Fo[k].
        for k in 0...m {
            let a = k == m ? 0 : k
            let b = k == 0 ? 0 : m - k
            let ar = zr[a], ai = zi[a], br = zr[b], bi = zi[b]
            let fer = 0.5 * (ar + br), fei = 0.5 * (ai - bi)
            let for_ = 0.5 * (ai + bi), foi = -0.5 * (ar - br)
            let wr = wRe[k], wi = wIm[k]
            re[k] = fer + wr * for_ - wi * foi
            im[k] = fei + wr * foi + wi * for_
        }
    }

    /// |X[k]|^2 for bins 0...size/2 (needs `size/2 + 1` outputs; `re`/`im` are caller scratch of the same length).
    public func powerSpectrum(_ input: UnsafePointer<Float>, power: UnsafeMutablePointer<Float>,
                              re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        forward(input, re: re, im: im)
        for k in 0...half { power[k] = re[k] * re[k] + im[k] * im[k] }
    }

    /// Convenience: magnitude spectrum (size/2 + 1 values) of `samples` (zero-padded / truncated to a power of two
    /// >= samples.count). Allocates; not for real-time paths.
    public static func magnitudes(of samples: [Float]) -> [Float] {
        var n = 4
        while n < samples.count { n <<= 1 }
        var x = samples
        x.append(contentsOf: [Float](repeating: 0, count: n - samples.count))
        let fft = FFT(size: n)
        var re = [Float](repeating: 0, count: n / 2 + 1)
        var im = re
        x.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re: &re, im: &im) }
        return (0...(n / 2)).map { (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
    }
}
