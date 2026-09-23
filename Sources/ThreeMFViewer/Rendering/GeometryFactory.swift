import AppKit
import SceneKit
import ThreeMFKit

enum GeometryFactory {
    /// Builds flat-shaded geometry: every triangle gets its own three vertices and a face normal,
    /// which is how STL/3MF viewers and slicers display printable meshes.
    /// Multi-coloured meshes use per-vertex colours (one draw call regardless of colour count).
    static func makeGeometry(mesh: Mesh, colors: [RGBAColor?]) -> SCNGeometry {
        let triangleCount = mesh.triangleCount
        let vertexCount = triangleCount * 3
        let fallback = RGBAColor(r: Float(ViewerScene.defaultColor.redComponent),
                                 g: Float(ViewerScene.defaultColor.greenComponent),
                                 b: Float(ViewerScene.defaultColor.blueComponent))
        let resolved = colors.map { $0 ?? fallback }

        // Is the mesh effectively single-coloured?
        var uniform: RGBAColor? = resolved.first ?? fallback
        if !mesh.triangleColors.isEmpty, let first = resolved.first {
            if resolved.contains(where: { $0 != first }) { uniform = nil }
        }

        var positions = [Float](repeating: 0, count: vertexCount * 3)
        var normals = [Float](repeating: 0, count: vertexCount * 3)

        mesh.positions.withUnsafeBufferPointer { p in
            mesh.indices.withUnsafeBufferPointer { idx in
                positions.withUnsafeMutableBufferPointer { out in
                    normals.withUnsafeMutableBufferPointer { nout in
                        for t in 0 ..< triangleCount {
                            let a = Int(idx[t * 3]) * 3
                            let b = Int(idx[t * 3 + 1]) * 3
                            let c = Int(idx[t * 3 + 2]) * 3
                            let ax = p[a], ay = p[a + 1], az = p[a + 2]
                            let bx = p[b], by = p[b + 1], bz = p[b + 2]
                            let cx = p[c], cy = p[c + 1], cz = p[c + 2]

                            let ux = bx - ax, uy = by - ay, uz = bz - az
                            let vx = cx - ax, vy = cy - ay, vz = cz - az
                            var nx = uy * vz - uz * vy
                            var ny = uz * vx - ux * vz
                            var nz = ux * vy - uy * vx
                            let length = (nx * nx + ny * ny + nz * nz).squareRoot()
                            if length > 0 {
                                nx /= length; ny /= length; nz /= length
                            } else {
                                nx = 0; ny = 0; nz = 1
                            }

                            let o = t * 9
                            out[o] = ax; out[o + 1] = ay; out[o + 2] = az
                            out[o + 3] = bx; out[o + 4] = by; out[o + 5] = bz
                            out[o + 6] = cx; out[o + 7] = cy; out[o + 8] = cz
                            nout[o] = nx; nout[o + 1] = ny; nout[o + 2] = nz
                            nout[o + 3] = nx; nout[o + 4] = ny; nout[o + 5] = nz
                            nout[o + 6] = nx; nout[o + 7] = ny; nout[o + 8] = nz
                        }
                    }
                }
            }
        }

        let stride = MemoryLayout<Float>.size * 3
        var sources = [
            SCNGeometrySource(data: positions.withUnsafeBytes { Data($0) },
                              semantic: .vertex,
                              vectorCount: vertexCount,
                              usesFloatComponents: true,
                              componentsPerVector: 3,
                              bytesPerComponent: MemoryLayout<Float>.size,
                              dataOffset: 0,
                              dataStride: stride),
            SCNGeometrySource(data: normals.withUnsafeBytes { Data($0) },
                              semantic: .normal,
                              vectorCount: vertexCount,
                              usesFloatComponents: true,
                              componentsPerVector: 3,
                              bytesPerComponent: MemoryLayout<Float>.size,
                              dataOffset: 0,
                              dataStride: stride),
        ]

        if uniform == nil {
            var vertexColors = [Float](repeating: 0, count: vertexCount * 3)
            vertexColors.withUnsafeMutableBufferPointer { out in
                for t in 0 ..< triangleCount {
                    let color = resolved[mesh.paletteIndex(ofTriangle: t)]
                    let o = t * 9
                    for k in 0 ..< 3 {
                        out[o + k * 3] = color.r
                        out[o + k * 3 + 1] = color.g
                        out[o + k * 3 + 2] = color.b
                    }
                }
            }
            sources.append(SCNGeometrySource(data: vertexColors.withUnsafeBytes { Data($0) },
                                             semantic: .color,
                                             vectorCount: vertexCount,
                                             usesFloatComponents: true,
                                             componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size,
                                             dataOffset: 0,
                                             dataStride: stride))
        }

        let indices = [UInt32](0 ..< UInt32(vertexCount))
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) },
                                         primitiveType: .triangles,
                                         primitiveCount: triangleCount,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let materialColor = uniform.map(nsColor) ?? .white // vertex colours are multiplied with diffuse
        geometry.materials = [makeMaterial(color: materialColor)]
        return geometry
    }

    static func makeMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.specular.contents = NSColor(white: 0.22, alpha: 1)
        material.shininess = 0.25
        material.isDoubleSided = true
        material.locksAmbientWithDiffuse = true
        return material
    }

    static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))
    }

    /// A millimetre grid in the XY plane (3MF coordinates), slightly below z = 0.
    static func makePlateGrid(width: Double, depth: Double) -> SCNNode {
        let span = max(width, depth, 40) * 1.5
        let step: Double = span > 600 ? 50 : (span > 250 ? 20 : 10)
        let half = (span / 2 / step).rounded(.up) * step
        let z: Float = -0.05

        var vertices: [Float] = []
        var indices: [UInt32] = []
        var value = -half
        while value <= half + 0.0001 {
            let v = Float(value), h = Float(half)
            let base = UInt32(vertices.count / 3)
            vertices += [v, -h, z, v, h, z, -h, v, z, h, v, z]
            indices += [base, base + 1, base + 2, base + 3]
            value += step
        }

        let source = SCNGeometrySource(data: vertices.withUnsafeBytes { Data($0) },
                                       semantic: .vertex,
                                       vectorCount: vertices.count / 3,
                                       usesFloatComponents: true,
                                       componentsPerVector: 3,
                                       bytesPerComponent: MemoryLayout<Float>.size,
                                       dataOffset: 0,
                                       dataStride: MemoryLayout<Float>.size * 3)
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) },
                                         primitiveType: .line,
                                         primitiveCount: indices.count / 2,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(white: 0.5, alpha: 0.45)
        material.isDoubleSided = true
        material.blendMode = .alpha
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "plate"
        node.renderingOrder = -1
        return node
    }
}
