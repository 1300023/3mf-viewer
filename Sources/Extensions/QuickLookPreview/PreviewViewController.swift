import AppKit
import Quartz
import SceneKit
import ThreeMFKit
import ThreeMFRendering

/// Quick Look preview (space bar in Finder): an interactive 3D view of the model.
/// Drag to rotate, scroll or pinch to zoom.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    /// Bigger files show only the embedded picture (Quick Look extensions have a tight memory budget).
    private static let maxModelFileSize = 200 * 1024 * 1024

    private let sceneView = SCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), options: nil)
    private let imageView = NSImageView()
    private let infoLabel = NSTextField(labelWithString: "")
    private var viewer: ViewerScene?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = false
        sceneView.isHidden = true
        container.addSubview(sceneView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true
        container.addSubview(imageView)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: container.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            imageView.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -8),
            infoLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        view = container
        preferredContentSize = NSSize(width: 800, height: 600)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        sceneView.backgroundColor = ViewerScene.backgroundColor(dark: dark)

        DispatchQueue.global(qos: .userInitiated).async {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var model: ThreeMFModel?
            var loadError: Error?
            if fileSize <= Self.maxModelFileSize {
                do {
                    model = try ThreeMFReader.load(url: url)
                } catch {
                    loadError = error
                }
            }

            var viewer: ViewerScene?
            var picture: CGImage?
            if let model, model.triangleCount > 0 {
                viewer = ViewerScene(model: model)
                viewer?.apply(ViewerOptions(showColors: true, wireframe: false, showPlate: true))
            } else {
                picture = EmbeddedThumbnail.image(url: url, maxPixelSize: 1200)
            }
            let info = model.map(Self.summary(of:)) ?? ""

            DispatchQueue.main.async {
                if let viewer {
                    self.viewer = viewer
                    viewer.attach(to: self.sceneView)
                    self.sceneView.isHidden = false
                } else if let picture {
                    self.imageView.image = NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
                    self.imageView.isHidden = false
                } else {
                    handler(loadError ?? ThreeMFError.missingModel)
                    return
                }
                self.infoLabel.stringValue = info
                handler(nil)
            }
        }
    }

    private static func summary(of model: ThreeMFModel) -> String {
        var parts: [String] = []
        if let size = model.sizeInMillimeters, model.triangleCount > 0 {
            func f(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0 ... 1))) }
            parts.append("\(f(size.x)) × \(f(size.y)) × \(f(size.z)) " + NSLocalizedString("mm", comment: ""))
        }
        if model.triangleCount > 0 {
            parts.append(String(format: NSLocalizedString("Triangles: %@", comment: ""),
                                model.triangleCount.formatted()))
        }
        if let title = model.metadataValue("Title"), !title.isEmpty {
            parts.append(title)
        }
        return parts.joined(separator: "  ·  ")
    }
}
