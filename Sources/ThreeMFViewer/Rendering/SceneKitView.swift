import AppKit
import Metal
import SceneKit
import SwiftUI
import ThreeMFKit

/// Interactive 3D view: drag to orbit, scroll / pinch to zoom, right-drag or ⌥-drag to pan.
struct SceneKitView: NSViewRepresentable {
    let viewer: ViewerScene
    let options: ViewerOptions
    /// Increment to animate the camera back to its home position.
    let resetToken: Int

    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator {
        var viewer: ViewerScene?
        var resetToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.viewer !== viewer {
            coordinator.viewer = viewer
            coordinator.resetToken = resetToken
            view.scene = viewer.scene
            view.pointOfView = viewer.cameraNode
            configureCameraController(of: view)
        }
        viewer.apply(options)
        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            view.pointOfView = viewer.cameraNode
            viewer.resetCamera(animated: true)
            configureCameraController(of: view)
        }
        view.backgroundColor = colorScheme == .dark
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    private func configureCameraController(of view: SCNView) {
        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true
        controller.worldUp = SCNVector3(x: 0, y: 1, z: 0)
        controller.target = viewer.target
    }
}

/// Off-screen rendering for files that have no embedded preview image.
enum ThumbnailRenderer {
    static func render(model: ThreeMFModel, pixelSize: CGFloat) -> NSImage? {
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
