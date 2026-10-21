import Foundation

/// Small deterministic RNG (SplitMix64). The same seed always yields the same sequence on every platform (unlike
/// `SystemRandomNumberGenerator`), which the performance planner, the synthetic evaluation takes and tests rely on.
/// Also conforms to `RandomNumberGenerator`, so it can drive `Array.shuffled(using:)` and friends.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in -1...1.
    public mutating func signed() -> Double {
        Double(next() >> 11) / Double(1 << 53) * 2 - 1
    }

    /// Uniform in 0...1.
    public mutating func uniform() -> Double { (signed() + 1) / 2 }

    /// Uniform in a...b.
    public mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }

    /// Standard normal (Box-Muller).
    public mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// Uniform integer in 0..<n (n >= 1).
    public mutating func int(_ n: Int) -> Int { min(n - 1, Int(uniform() * Double(n))) }
}
