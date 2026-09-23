import AppKit
import SceneKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

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
            viewer.attach(to: view)
        }
        viewer.apply(options)
        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            viewer.resetCamera(animated: true)
            viewer.attach(to: view)
        }
        view.backgroundColor = ViewerScene.backgroundColor(dark: colorScheme == .dark)
    }
}
