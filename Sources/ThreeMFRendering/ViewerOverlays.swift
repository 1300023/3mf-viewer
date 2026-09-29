import AppKit
import SceneKit
import simd

/// Build volume outline and ruler markers drawn over the model. Coordinates are millimetres in the
/// plate space of `ViewerScene` (x, y centred on the model, z = 0 on the plate, Z up).
public extension ViewerScene {
    /// Shows the printer's build volume as a box standing on the plate under the model, or hides it (nil).
    /// The box turns red when the model does not fit.
    func setBuildVolume(_ volume: SIMD3<Double>?, fits: Bool) {
        overlayNode(named: "buildVolume")?.removeFromParentNode()
        guard let volume, volume.x > 0, volume.y > 0, volume.z > 0 else { return }
        let color = fits ? NSColor.systemGreen : NSColor.systemRed
        let node = GeometryFactory.makeBoxOutline(size: volume, color: color)
        node.name = "buildVolume"
        plateSpaceNode.addChildNode(node)
    }

    /// Converts a hit-test point (scene coordinates) to plate-space millimetres.
    func platePoint(fromScene point: SCNVector3) -> SIMD3<Double> {
        let local = plateSpaceNode.convertPosition(point, from: nil)
        return SIMD3(Double(local.x), Double(local.y), Double(local.z))
    }

    /// The node to hit-test against: only the model, not the plate grid or overlays.
    var hitTestRoot: SCNNode { modelRootNode }

    /// Draws ruler markers for 0, 1 or 2 points (and the line between two).
    func showMeasurement(_ points: [SIMD3<Double>]) {
        overlayNode(named: "measurement")?.removeFromParentNode()
        guard !points.isEmpty else { return }
        let group = SCNNode()
        group.name = "measurement"
        let radius = CGFloat(max(size.max() / 140, 0.25))
        let color = NSColor.systemOrange
        for point in points.prefix(2) {
            let sphere = SCNSphere(radius: radius)
            sphere.firstMaterial = GeometryFactory.makeOverlayMaterial(color: color)
            let marker = SCNNode(geometry: sphere)
            marker.position = SCNVector3(x: CGFloat(point.x), y: CGFloat(point.y), z: CGFloat(point.z))
            marker.renderingOrder = 10
            group.addChildNode(marker)
        }
        if points.count >= 2 {
            let line = GeometryFactory.makeLine(from: points[0], to: points[1], radius: radius / 3, color: color)
            line.renderingOrder = 10
            group.addChildNode(line)
        }
        plateSpaceNode.addChildNode(group)
    }

    private func overlayNode(named name: String) -> SCNNode? {
        plateSpaceNode.childNode(withName: name, recursively: false)
    }
}

extension GeometryFactory {
    /// The 12 edges of a box of `size` standing on z = 0, centred on the origin in x and y.
    /// Drawn as thin bars (1-pixel lines are hard to see on a light background).
    static func makeBoxOutline(size: SIMD3<Double>, color: NSColor) -> SCNNode {
        let x = Float(size.x / 2), y = Float(size.y / 2), z = Float(size.z)
        let corners: [SIMD3<Float>] = [
            SIMD3(-x, -y, 0), SIMD3(x, -y, 0), SIMD3(x, y, 0), SIMD3(-x, y, 0),
            SIMD3(-x, -y, z), SIMD3(x, -y, z), SIMD3(x, y, z), SIMD3(-x, y, z),
        ]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        let radius = CGFloat(max(size.max() / 450, 0.3))
        // The box is hidden behind the model like a real object.
        let material = makeOverlayMaterial(color: color, alwaysOnTop: false)
        let group = SCNNode()
        for (a, b) in edges {
            group.addChildNode(bar(from: corners[a], to: corners[b], radius: radius, material: material))
        }
        return group
    }

    /// A bar between two points (the ruler line), drawn on top of the model.
    static func makeLine(from a: SIMD3<Double>, to b: SIMD3<Double>, radius: CGFloat, color: NSColor) -> SCNNode {
        bar(from: SIMD3<Float>(a), to: SIMD3<Float>(b), radius: radius,
            material: makeOverlayMaterial(color: color, alwaysOnTop: true))
    }

    static func makeOverlayMaterial(color: NSColor, alwaysOnTop: Bool = true) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.isDoubleSided = true
        // Ruler markers stay visible even behind the model.
        material.readsFromDepthBuffer = !alwaysOnTop
        return material
    }

    /// A thin cylinder from `a` to `b`.
    private static func bar(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let delta = b - a
        let length = simd_length(delta)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(max(length, 0.001)))
        cylinder.radialSegmentCount = 8
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) / 2
        guard length > 0 else { return node }
        // SCNCylinder stands along +Y: turn it onto the segment.
        let direction = delta / length
        let up = SIMD3<Float>(0, 1, 0)
        if simd_dot(up, direction) < -0.9999 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else {
            node.simdOrientation = simd_quatf(from: up, to: direction)
        }
        return node
    }
}
