import AppKit
import SceneKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

/// Interactive 3D view: drag to orbit, scroll / pinch to zoom, right-drag or ⌥-drag to pan.
/// In ruler mode a click on the model picks a measuring point.
struct SceneKitView: NSViewRepresentable {
    let viewer: ViewerScene
    let options: ViewerOptions
    /// Increment to animate the camera back to its home position.
    let resetToken: Int
    /// Printer build volume to outline (mm), or nil.
    var buildVolume: SIMD3<Double>?
    var fitsBuildVolume = true
    /// Ruler points (plate-space millimetres) and the click handler of ruler mode (nil = ruler off).
    var measurePoints: [SIMD3<Double>] = []
    var onMeasureClick: ((SIMD3<Double>) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator: NSObject {
        var viewer: ViewerScene?
        var resetToken = 0
        var onMeasureClick: ((SIMD3<Double>) -> Void)?
        weak var view: SCNView?
        var appliedVolume: SIMD3<Double>??
        var appliedFits: Bool?
        var appliedPoints: [SIMD3<Double>]?

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let onMeasureClick, let view, let viewer else { return }
            let location = recognizer.location(in: view)
            let hits = view.hitTest(location, options: [
                .rootNode: viewer.hitTestRoot,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true,
            ])
            guard let hit = hits.first else { return }
            onMeasureClick(viewer.platePoint(fromScene: hit.worldCoordinates))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        // Let drags still reach the camera controller.
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onMeasureClick = onMeasureClick
        if coordinator.viewer !== viewer {
            coordinator.viewer = viewer
            coordinator.resetToken = resetToken
            coordinator.appliedVolume = nil
            coordinator.appliedFits = nil
            coordinator.appliedPoints = nil
            viewer.attach(to: view)
        }
        viewer.apply(options)
        if coordinator.appliedVolume != .some(buildVolume) || coordinator.appliedFits != fitsBuildVolume {
            coordinator.appliedVolume = .some(buildVolume)
            coordinator.appliedFits = fitsBuildVolume
            viewer.setBuildVolume(buildVolume, fits: fitsBuildVolume)
        }
        if coordinator.appliedPoints != measurePoints {
            coordinator.appliedPoints = measurePoints
            viewer.showMeasurement(measurePoints)
        }
        // Keep rendering while the turntable spins; otherwise draw only on changes.
        view.rendersContinuously = options.autoRotate
        view.isPlaying = options.autoRotate
        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken
            viewer.resetCamera(animated: true)
            viewer.attach(to: view)
        }
        view.backgroundColor = ViewerScene.backgroundColor(dark: colorScheme == .dark)
    }
}
