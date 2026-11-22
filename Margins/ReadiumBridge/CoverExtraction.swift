import Foundation
@preconcurrency import ReadiumShared
import UIKit

enum CoverExtraction {
    /// Longest edge of the stored cover thumbnail, in pixels.
    static let maxPixelDimension: CGFloat = 900

    /// The publication's cover (EPUB 3 `cover-image` or EPUB 2 `<meta name="cover">`, via
    /// Readium's cover service), downscaled and PNG-encoded. Returns nil if there is none.
    nonisolated static func coverPNG(of publication: Publication) async -> Data? {
        guard case let .success(image?) = await publication.cover() else {
            return nil
        }
        return downscaled(image).pngData()
    }

    nonisolated private static func downscaled(_ image: UIImage) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxPixelDimension, longest > 0 else {
            return image
        }
        let factor = maxPixelDimension / longest
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // UIGraphicsImageRenderer is thread-safe, so this can run off the main actor.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
