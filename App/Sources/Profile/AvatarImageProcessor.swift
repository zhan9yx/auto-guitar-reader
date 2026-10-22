import UIKit

/// Prepares a picked photo for upload: centered square crop, downscaled to `side` px, JPEG under the server's 1 MB limit.
enum AvatarImageProcessor {
    static let side: CGFloat = 512
    static let maxBytes = 1024 * 1024

    static func squareJPEG(from data: Data, side: CGFloat = AvatarImageProcessor.side) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // `side` is in pixels
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let scale = max(side / image.size.width, side / image.size.height)   // aspect fill = center crop
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let squared = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            // UIImage.draw honors the image orientation, so rotated camera photos come out upright.
            image.draw(in: CGRect(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2,
                                  width: drawSize.width, height: drawSize.height))
        }
        for quality in [0.85, 0.7, 0.5, 0.3] as [CGFloat] {
            if let jpeg = squared.jpegData(compressionQuality: quality), jpeg.count <= maxBytes { return jpeg }
        }
        return nil
    }
}
