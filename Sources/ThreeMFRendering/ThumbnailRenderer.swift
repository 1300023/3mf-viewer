import AppKit
import Metal
import SceneKit
import ThreeMFKit

/// Off-screen rendering for files that have no embedded preview image.
public enum ThumbnailRenderer {
    public static func render(model: ThreeMFModel, pixelSize: CGFloat) -> NSImage? {
        guard model.triangleCount > 0, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let viewer = ViewerScene(model: model, includePlate: false)
        viewer.apply(ViewerOptions(showColors: true, wireframe: false, showPlate: false))
        viewer.scene.background.contents = NSColor.clear

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = viewer.scene
        renderer.pointOfView = viewer.cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0,
                                 with: CGSize(width: pixelSize, height: pixelSize),
                                 antialiasingMode: .multisampling4X)
    }
}
