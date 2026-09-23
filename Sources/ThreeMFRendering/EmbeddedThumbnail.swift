import CoreGraphics
import Foundation
import ImageIO
import ThreeMFKit

/// The preview image that slicers embed into .3mf files.
public enum EmbeddedThumbnail {
    /// Decodes and downsizes the embedded thumbnail (nil if the file has none).
    public static func image(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let data = try? ThreeMFReader.thumbnailData(url: url) else { return nil }
        return image(data: data, maxPixelSize: maxPixelSize)
    }

    public static func image(data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
