import CoreGraphics
import UIKit
import AGRCore

/// Turns one prepared page into the inputs `OMREngine.recognize` expects.
///
/// Luma matches `OMRRGBImage.gray`: Rec. 601, `Y = (299*R + 587*G + 114*B) / 1000`,
/// 0 black, 255 white, row-major. OCR boxes are already normalised top-left, so
/// tokens are not rewritten.
enum OMRPageAdapter {
    /// Decodes a prepared JPEG (orientation is already baked by `ImagePipeline`).
    static func grayImage(jpegData: Data) -> GrayImage? {
        guard let cgImage = UIImage(data: jpegData)?.cgImage else { return nil }
        return grayImage(from: cgImage)
    }

    static func grayImage(from cgImage: CGImage) -> GrayImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 255, count: height * bytesPerRow)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            // Row 0 of this bitmap is the top of the page. Do not flip the CTM.
            if let white = CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1]) {
                context.setFillColor(white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let alpha = Int(rgba[offset + 3])
            // Premultiplied RGBA over the white fill: stored channel + (255 - alpha).
            let red = min(255, Int(rgba[offset]) + (255 - alpha))
            let green = min(255, Int(rgba[offset + 1]) + (255 - alpha))
            let blue = min(255, Int(rgba[offset + 2]) + (255 - alpha))
            pixels[index] = UInt8((299 * red + 587 * green + 114 * blue) / 1000)
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    static func tokens(_ tokens: [OCRToken]) -> [OCRToken] {
        tokens
    }
}
