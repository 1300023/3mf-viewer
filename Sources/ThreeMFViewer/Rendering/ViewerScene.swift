import AppKit
import SceneKit
import ThreeMFKit

struct ViewerOptions: Equatable {
    var showColors = true
    var wireframe = false
    var showPlate = true
}

/// A SceneKit scene built from a `ThreeMFModel`.
///
/// 3MF is Z-up and measured in model units; SceneKit is Y-up. The model is converted to
/// millimetres, centred on the origin and put on the "build plate" (z = 0).
final class ViewerScene: @unchecked Sendable {
    static let defaultColor = NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.80, alpha: 1)

    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Point the camera orbits around (scene coordinates).
    private(set) var target = SCNVector3(x: 0, y: 0, z: 0)
    /// Model size in millimetres.
    let size: SIMD3<Double>

    private let worldNode = SCNNode()
    private let modelContainer = SCNNode()
    private var plateNode: SCNNode?
    private var modelNodes: [(node: SCNNode, colored: SCNGeometry)] = []
    private var plainGeometries: [ObjectIdentifier: SCNGeometry] = [:]
    private var appliedOptions: ViewerOptions?
    private var homePosition = SCNVector3(x: 0, y: 0, z: 1)
    private let fieldOfView: CGFloat = 30

    init(model: ThreeMFModel, includePlate: Bool = true) {
        let unitScale = model.unit.millimeters
        let bounds = model.bounds ?? BoundingBox(min: .zero, max: .zero)
        let lo = bounds.min * unitScale
        let hi = bounds.max * unitScale
        size = hi - lo

        // Z-up (3MF) → Y-up (SceneKit): rotate -90° around X. (x, y, z) → (x, z, -y)
        worldNode.eulerAngles = SCNVector3(x: -CGFloat.pi / 2, y: 0, z: 0)
        scene.rootNode.addChildNode(worldNode)

        modelContainer.scale = SCNVector3(x: CGFloat(unitScale), y: CGFloat(unitScale), z: CGFloat(unitScale))
        modelContainer.position = SCNVector3(x: CGFloat(-(lo.x + hi.x) / 2),
                                             y: CGFloat(-(lo.y + hi.y) / 2),
                                             z: CGFloat(-lo.z))
        worldNode.addChildNode(modelContainer)

        var geometryCache: [String: SCNGeometry] = [:]
        for instance in model.instances where instance.mesh.triangleCount > 0 {
            let colors = model.resolvedColors(for: instance)
            let key = instance.mesh.key + "|" + colors.map { color in
                color.map { "\($0.r),\($0.g),\($0.b),\($0.a)" } ?? "-"
            }.joined(separator: ";")

            let geometry: SCNGeometry
            if let cached = geometryCache[key] {
                geometry = cached
            } else {
                geometry = GeometryFactory.makeGeometry(mesh: instance.mesh, colors: colors)
                geometryCache[key] = geometry
            }
            let node = SCNNode(geometry: geometry)
            node.transform = instance.transform.scnMatrix
            node.name = instance.objectName
            modelContainer.addChildNode(node)
            modelNodes.append((node, geometry))
        }

        if includePlate {
            let plate = GeometryFactory.makePlateGrid(width: size.x, depth: size.y)
            worldNode.addChildNode(plate)
            plateNode = plate
        }

        setUpLights()
        setUpCamera()
    }

    // MARK: - Options

    func apply(_ options: ViewerOptions) {
        guard options != appliedOptions else { return }
        appliedOptions = options
        for entry in modelNodes {
            let geometry = options.showColors ? entry.colored : plainGeometry(for: entry.colored)
            if entry.node.geometry !== geometry { entry.node.geometry = geometry }
            for material in geometry.materials {
                material.fillMode = options.wireframe ? .lines : .fill
            }
        }
        plateNode?.isHidden = !options.showPlate
    }

    /// The same geometry without vertex colours, painted with the neutral default colour.
    private func plainGeometry(for geometry: SCNGeometry) -> SCNGeometry {
        let id = ObjectIdentifier(geometry)
        if let cached = plainGeometries[id] { return cached }
        let sources = geometry.sources.filter { $0.semantic != .color }
        let plain = SCNGeometry(sources: sources, elements: geometry.elements)
        plain.materials = [GeometryFactory.makeMaterial(color: Self.defaultColor)]
        plainGeometries[id] = plain
        return plain
    }

    // MARK: - Camera & lights

    func resetCamera(animated: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        cameraNode.camera?.fieldOfView = fieldOfView
        cameraNode.position = homePosition
        cameraNode.look(at: target)
        SCNTransaction.commit()
    }

    private func setUpCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.projectionDirection = .vertical
        camera.automaticallyAdjustsZRange = true
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)

        // After centring, the model occupies x ∈ ±w/2, y ∈ [0, h], z ∈ ±d/2 (scene coordinates).
        let height = max(size.z, 0)
        target = SCNVector3(x: 0, y: CGFloat(height / 2), z: 0)
        let radius = max((size.x * size.x + size.y * size.y + size.z * size.z).squareRoot() / 2, 1)
        let halfFOV = Double(fieldOfView) / 2 * .pi / 180
        let distance = radius / sin(halfFOV) * 1.3

        // Look from the front-right, slightly above.
        var direction = SIMD3<Double>(0.75, 0.62, 1.25)
        direction /= (direction * direction).sum().squareRoot()
        homePosition = SCNVector3(x: CGFloat(direction.x * distance),
                                  y: CGFloat(height / 2 + direction.y * distance),
                                  z: CGFloat(direction.z * distance))
        resetCamera(animated: false)
    }

    private func setUpLights() {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 320
        ambient.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Head light: always shines from the viewer's direction.
        let head = SCNLight()
        head.type = .directional
        head.intensity = 700
        let headNode = SCNNode()
        headNode.light = head
        headNode.eulerAngles = SCNVector3(x: -0.25, y: 0.3, z: 0)
        cameraNode.addChildNode(headNode)

        // Key light from above.
        let top = SCNLight()
        top.type = .directional
        top.intensity = 380
        let topNode = SCNNode()
        topNode.light = top
        topNode.eulerAngles = SCNVector3(x: -CGFloat.pi / 2.6, y: CGFloat.pi / 5, z: 0)
        scene.rootNode.addChildNode(topNode)
    }
}

extension Transform3D {
    /// 3MF uses the row-vector convention, exactly like SceneKit's `SCNMatrix4` (translation in m41…m43).
    var scnMatrix: SCNMatrix4 {
        let v = m.map { CGFloat($0) }
        return SCNMatrix4(m11: v[0], m12: v[1], m13: v[2], m14: 0,
                          m21: v[3], m22: v[4], m23: v[5], m24: 0,
                          m31: v[6], m32: v[7], m33: v[8], m34: 0,
                          m41: v[9], m42: v[10], m43: v[11], m44: 1)
    }
}
