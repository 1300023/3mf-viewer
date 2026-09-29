import Foundation
import simd

/// Volume and surface area of a model, in millimetres.
public struct MeshMeasure: Equatable, Sendable {
    /// mm³, enclosed by the meshes.
    public var volume: Double
    /// mm².
    public var surfaceArea: Double

    public init(volume: Double, surfaceArea: Double) {
        self.volume = volume
        self.surfaceArea = surfaceArea
    }
}

public extension ThreeMFModel {
    /// Volume and surface area of every placed mesh; nil for a model without triangles.
    /// Blocking and linear in the number of triangles — call it off the main thread for big models.
    func measure() -> MeshMeasure? {
        guard triangleCount > 0 else { return nil }
        var volume = 0.0
        var area = 0.0
        for instance in instances where instance.mesh.triangleCount > 0 {
            let part = Self.measure(instance)
            volume += part.volume
            area += part.surfaceArea
        }
        let mm = unit.millimeters
        return MeshMeasure(volume: volume * mm * mm * mm, surfaceArea: area * mm * mm)
    }

    /// In model units. The signed volume is taken as absolute per mesh (inverted or mirrored meshes).
    private static func measure(_ instance: MeshInstance) -> MeshMeasure {
        let m = instance.transform.m
        let m0 = m[0], m1 = m[1], m2 = m[2], m3 = m[3], m4 = m[4], m5 = m[5]
        let m6 = m[6], m7 = m[7], m8 = m[8], m9 = m[9], m10 = m[10], m11 = m[11]
        var signedVolume = 0.0
        var area = 0.0
        instance.mesh.positions.withUnsafeBufferPointer { p in
            instance.mesh.indices.withUnsafeBufferPointer { idx in
                func vertex(_ index: UInt32) -> SIMD3<Double> {
                    let i = Int(index) * 3
                    let x = Double(p[i]), y = Double(p[i + 1]), z = Double(p[i + 2])
                    return SIMD3(x * m0 + y * m3 + z * m6 + m9,
                                 x * m1 + y * m4 + z * m7 + m10,
                                 x * m2 + y * m5 + z * m8 + m11)
                }
                let vertexCount = p.count / 3
                var t = 0
                while t + 2 < idx.count {
                    let ia = idx[t], ib = idx[t + 1], ic = idx[t + 2]
                    t += 3
                    guard Int(ia) < vertexCount, Int(ib) < vertexCount, Int(ic) < vertexCount else { continue }
                    let a = vertex(ia), b = vertex(ib), c = vertex(ic)
                    // Signed volume of the tetrahedron (origin, a, b, c) and the triangle area.
                    let cross = simd_cross(b, c)
                    signedVolume += simd_dot(a, cross) / 6
                    let normal = simd_cross(b - a, c - a)
                    area += simd_length(normal) / 2
                }
            }
        }
        return MeshMeasure(volume: abs(signedVolume), surfaceArea: area)
    }
}
