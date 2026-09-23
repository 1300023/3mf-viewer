import AppKit
import QuickLookThumbnailing
import ThreeMFKit
import ThreeMFRendering

/// Finder icons for .3mf files: the preview picture embedded by the slicer, or a SceneKit render.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    /// Files without an embedded picture are rendered only up to this size.
    private static let maxRenderFileSize = 80 * 1024 * 1024

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        let pixelSize = max(maximumSize.width, maximumSize.height) * max(request.scale, 1)

        var image = EmbeddedThumbnail.image(url: url, maxPixelSize: pixelSize)
        if image == nil {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize <= Self.maxRenderFileSize,
               let model = try? ThreeMFReader.load(url: url),
               let rendered = ThumbnailRenderer.render(model: model, pixelSize: min(pixelSize, 1024)) {
                image = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        guard let image, image.width > 0, image.height > 0 else {
            handler(nil, ThreeMFError.missingModel)
            return
        }

        // Fit the picture into the requested box, keeping its aspect ratio.
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var size = maximumSize
        if aspect >= 1 {
            size.height = maximumSize.width / aspect
        } else {
            size.width = maximumSize.height * aspect
        }

        let reply = QLThumbnailReply(contextSize: size) { context -> Bool in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }
        reply.extensionBadge = "3MF"
        handler(reply, nil)
    }
}
