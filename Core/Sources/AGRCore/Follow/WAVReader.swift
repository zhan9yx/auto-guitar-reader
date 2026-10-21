import Foundation

/// Tiny WAV reader for `agr-tool follow-eval --audio`: PCM 8/16/24/32-bit and IEEE float 32/64, any channel count
/// (mixed down to mono), including WAVE_FORMAT_EXTENSIBLE.
public enum WAVReader {
    public enum WAVError: Error, Equatable { case notWAV, unsupported(String), truncated }

    public static func read(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE"
        else { throw WAVError.notWAV }
        var pos = 12
        var fmtTag = 0, channels = 1, rate = 44100, bits = 16
        var haveFmt = false
        var dataRange: Range<Int>?
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            var size = u32(pos + 4)
            let body = pos + 8
            if id == "data" {
                size = min(size, b.count - body)          // tolerate streaming headers with bogus sizes
                dataRange = body..<(body + size)
                break
            }
            guard body + size <= b.count else { throw WAVError.truncated }
            if id == "fmt " && size >= 16 {
                fmtTag = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if fmtTag == 0xFFFE && size >= 26 { fmtTag = u16(body + 24) }
                haveFmt = true
            }
            pos = body + size + (size & 1)
        }
        guard haveFmt, let range = dataRange, channels >= 1 else { throw WAVError.notWAV }
        let bytes = bits / 8
        guard bytes >= 1 else { throw WAVError.unsupported("bits \(bits)") }
        let frames = range.count / (bytes * channels)
        var out = [Float](repeating: 0, count: frames)
        let base = range.lowerBound
        func sample(_ o: Int) throws -> Float {
            switch (fmtTag, bits) {
            case (1, 8): return (Float(b[o]) - 128) / 128
            case (1, 16): return Float(Int16(bitPattern: UInt16(u16(o)))) / 32768
            case (1, 24):
                var v = Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16
                if v & 0x80_0000 != 0 { v -= 0x100_0000 }
                return Float(v) / 8_388_608
            case (1, 32): return Float(Int32(bitPattern: UInt32(u32(o)))) / 2_147_483_648
            case (3, 32): return Float(bitPattern: UInt32(u32(o)))
            case (3, 64):
                let lo = UInt64(u32(o)), hi = UInt64(u32(o + 4))
                return Float(Double(bitPattern: lo | hi << 32))
            default: throw WAVError.unsupported("format \(fmtTag) / \(bits) bit")
            }
        }
        for i in 0..<frames {
            var acc: Float = 0
            for c in 0..<channels { acc += try sample(base + (i * channels + c) * bytes) }
            out[i] = acc / Float(channels)
        }
        return (out, Double(rate))
    }

    /// 16-bit mono WAV (delegates to the planner's writer so the two stay consistent).
    public static func write(_ samples: [Float], sampleRate: Double) -> Data {
        OfflineRenderer.wavData(samples, sampleRate: sampleRate)
    }
}

/// `time,eventIndex` change points (one row per event start). Header, comments (#) and blank lines are ignored.
public enum TruthCSV {
    public static func parse(_ text: String) -> [(time: Double, eventIndex: Int)] {
        var out: [(time: Double, eventIndex: Int)] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == ";" || $0 == " " })
            guard parts.count >= 2, let t = Double(parts[0]), let e = Int(parts[1]) else { continue }
            out.append((t, e))
        }
        return out.sorted { $0.time < $1.time }
    }

    public static func format(_ truth: [(time: Double, eventIndex: Int)]) -> String {
        "time,eventIndex\n" + truth.map { String(format: "%.4f,%d", $0.time, $0.eventIndex) }.joined(separator: "\n") + "\n"
    }
}
