import Foundation

/// 8-bit grayscale image (0 = black, 255 = white), row-major. Platform independent.
public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must equal width*height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Copy of a sub-rectangle (clamped to the image).
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> GrayImage {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return GrayImage(width: 0, height: 0, pixels: []) }
        var out = [UInt8]()
        out.reserveCapacity((x1 - x0) * (y1 - y0))
        for yy in y0..<y1 { out.append(contentsOf: pixels[(yy * width + x0)..<(yy * width + x1)]) }
        return GrayImage(width: x1 - x0, height: y1 - y0, pixels: out)
    }

    // MARK: PGM (P5 binary, also tolerates P2 ascii)

    public enum PGMError: Error { case malformed, unsupported }

    public static func decodePGM(_ data: Data) throws -> GrayImage {
        let bytes = [UInt8](data)
        var pos = 0
        func skipSpace() {
            while pos < bytes.count {
                if bytes[pos] == 35 { while pos < bytes.count && bytes[pos] != 10 { pos += 1 } }
                else if bytes[pos] == 32 || bytes[pos] == 10 || bytes[pos] == 13 || bytes[pos] == 9 { pos += 1 }
                else { break }
            }
        }
        func readInt() throws -> Int {
            skipSpace()
            var v = 0, n = 0
            while pos < bytes.count, bytes[pos] >= 48, bytes[pos] <= 57 { v = v * 10 + Int(bytes[pos] - 48); pos += 1; n += 1 }
            if n == 0 { throw PGMError.malformed }
            return v
        }
        guard bytes.count > 2, bytes[0] == 80 else { throw PGMError.malformed }
        let kind = bytes[1]
        guard kind == 53 || kind == 50 else { throw PGMError.unsupported }
        pos = 2
        let w = try readInt(), h = try readInt(), maxv = try readInt()
        guard w > 0, h > 0, maxv > 0, maxv < 65536 else { throw PGMError.malformed }
        var px = [UInt8](repeating: 0, count: w * h)
        if kind == 53 {
            pos += 1
            let bps = maxv > 255 ? 2 : 1
            guard bytes.count - pos >= w * h * bps else { throw PGMError.malformed }
            for i in 0..<(w * h) {
                if bps == 1 { px[i] = maxv == 255 ? bytes[pos + i] : UInt8(Int(bytes[pos + i]) * 255 / maxv) }
                else { px[i] = UInt8((Int(bytes[pos + 2 * i]) << 8 | Int(bytes[pos + 2 * i + 1])) * 255 / maxv) }
            }
        } else {
            for i in 0..<(w * h) { px[i] = UInt8(try readInt() * 255 / maxv) }
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    public static func readPGM(path: String) throws -> GrayImage {
        try decodePGM(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public func encodePGM() -> Data {
        var d = Data("P5\n\(width) \(height)\n255\n".utf8)
        d.append(contentsOf: pixels)
        return d
    }

    public func writePGM(path: String) throws { try encodePGM().write(to: URL(fileURLWithPath: path)) }
}
