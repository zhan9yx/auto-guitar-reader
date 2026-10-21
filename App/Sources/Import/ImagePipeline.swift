import Foundation
import UIKit
import PDFKit

/// One processed page: JPEG bytes (long side <= 2400 px, quality 0.85) and its pixel size.
struct PreparedPage: Sendable {
    let fileName: String
    let jpeg: Data
    let width: Int
    let height: Int
}

struct PDFRenderResult: Sendable {
    var pages: [PreparedPage]
    /// Concatenated PDF text layer (may be empty for scanned PDFs).
    var text: String
    var truncated: Bool
}

/// Image / PDF preprocessing for score import. All functions are synchronous and thread-safe
/// (call from a background task).
enum ImagePipeline {
    static let maxLongSide: CGFloat = 2400
    static let jpegQuality: CGFloat = 0.85
    static let maxPDFPages = 40

    /// Downscales (never upscales) so the long side is <= `maxLongSide` pixels and JPEG-encodes on white.
    /// Orientation is baked into the pixels.
    static func prepareJPEG(from image: UIImage) -> (data: Data, width: Int, height: Int)? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let longSide = max(pixelWidth, pixelHeight)
        let ratio = min(1, maxLongSide / longSide)
        let target = CGSize(width: max((pixelWidth * ratio).rounded(), 1), height: max((pixelHeight * ratio).rounded(), 1))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.jpegData(compressionQuality: jpegQuality) else { return nil }
        return (data, Int(target.width), Int(target.height))
    }

    /// Decodes each image data blob and prepares it as `page-N.jpg` (undecodable blobs are skipped).
    static func prepare(imageDatas: [Data]) -> [PreparedPage] {
        var pages: [PreparedPage] = []
        for data in imageDatas {
            autoreleasepool {
                guard let image = UIImage(data: data),
                      let jpeg = prepareJPEG(from: image) else { return }
                pages.append(
                    PreparedPage(
                        fileName: "page-\(pages.count).jpg",
                        jpeg: jpeg.data,
                        width: jpeg.width,
                        height: jpeg.height
                    )
                )
            }
        }
        return pages
    }

    /// Renders PDF pages at 2x (capped at `maxLongSide` px) and collects the text layer.
    static func renderPDF(data: Data) -> PDFRenderResult? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        let count = min(document.pageCount, maxPDFPages)
        var pages: [PreparedPage] = []
        var text = ""
        for index in 0..<count {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                if let pageText = page.string, !pageText.isEmpty {
                    text += pageText + "\n"
                }
                let bounds = page.bounds(for: .mediaBox)
                let rotated = page.rotation % 180 != 0
                let pageWidth = rotated ? bounds.height : bounds.width
                let pageHeight = rotated ? bounds.width : bounds.height
                let longest = max(pageWidth, pageHeight)
                guard longest > 0 else { return }
                let scale = min(2.0, maxLongSide / longest)
                let size = CGSize(width: pageWidth * scale, height: pageHeight * scale)
                let image = page.thumbnail(of: size, for: .mediaBox)
                guard let jpeg = prepareJPEG(from: image) else { return }
                pages.append(
                    PreparedPage(
                        fileName: "page-\(pages.count).jpg",
                        jpeg: jpeg.data,
                        width: jpeg.width,
                        height: jpeg.height
                    )
                )
            }
        }
        return PDFRenderResult(pages: pages, text: text, truncated: document.pageCount > count)
    }
}
