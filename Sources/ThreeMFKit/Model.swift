import Foundation

// MARK: - Basic types

public struct RGBAColor: Hashable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parses `#RGB`, `#RRGGBB` and `#RRGGBBAA` (the `#` is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard !s.isEmpty, let v = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 3:
            r = Float((v >> 8) & 0xF) / 15
            g = Float((v >> 4) & 0xF) / 15
            b = Float(v & 0xF) / 15
            a = 1
        case 6:
            r = Float((v >> 16) & 0xFF) / 255
            g = Float((v >> 8) & 0xFF) / 255
            b = Float(v & 0xFF) / 255
            a = 1
        case 8:
            r = Float((v >> 24) & 0xFF) / 255
            g = Float((v >> 16) & 0xFF) / 255
            b = Float((v >> 8) & 0xFF) / 255
            a = Float(v & 0xFF) / 255
        default:
            return nil
        }
    }

    public var hexString: String {
        func c(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

public enum LengthUnit: String, Sendable {
    case micron, millimeter, centimeter, inch, foot, meter

    /// How many millimetres one unit is.
    public var millimeters: Double {
        switch self {
        case .micron: return 0.001
        case .millimeter: return 1
        case .centimeter: return 10
        case .inch: return 25.4
        case .foot: return 304.8
        case .meter: return 1000
        }
    }
}

/// An affine transform in 3MF notation: 12 numbers, row-vector convention
/// (`p' = p · M`, translation in the last row: m30 m31 m32).
public struct Transform3D: Equatable, Sendable {
    public private(set) var m: [Double]

    public static let identity = Transform3D(m: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])

    public init(m: [Double]) {
        precondition(m.count == 12, "A 3MF transform has 12 components")
        self.m = m
    }

    /// Parses the value of a `transform` attribute.
    public init?(string: String) {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "," })
        guard parts.count == 12 else { return nil }
        var values: [Double] = []
        values.reserveCapacity(12)
        for part in parts {
            guard let value = Double(part) else { return nil }
            values.append(value)
        }
        self.m = values
    }

    public var isIdentity: Bool { self == .identity }

    @inline(__always)
    public func apply(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        (x * m[0] + y * m[3] + z * m[6] + m[9],
         x * m[1] + y * m[4] + z * m[7] + m[10],
         x * m[2] + y * m[5] + z * m[8] + m[11])
    }

    /// The transform that applies `self` first and `other` afterwards.
    public func then(_ other: Transform3D) -> Transform3D {
        let o = other.m
        var result = [Double](repeating: 0, count: 12)
        for row in 0 ..< 4 {
            let a0 = m[row * 3], a1 = m[row * 3 + 1], a2 = m[row * 3 + 2]
            let w: Double = row == 3 ? 1 : 0
            for col in 0 ..< 3 {
                result[row * 3 + col] = a0 * o[col] + a1 * o[3 + col] + a2 * o[6 + col] + w * o[9 + col]
            }
        }
        return Transform3D(m: result)
    }
}

public struct BoundingBox: Sendable, Equatable {
    public var min: SIMD3<Double>
    public var max: SIMD3<Double>

    public init(min: SIMD3<Double>, max: SIMD3<Double>) {
        self.min = min
        self.max = max
    }

    public var size: SIMD3<Double> { max - min }
    public var center: SIMD3<Double> { (min + max) * 0.5 }
}

// MARK: - Geometry

/// Where the colour of a triangle comes from.
public enum ColorSource: Hashable, Sendable {
    /// No explicit colour: use the object's filament / the default colour.
    case inherit
    /// An explicit material colour (3MF `basematerials` / `colorgroup`).
    case color(RGBAColor)
    /// A 1-based extruder / filament slot (multi-material painting in Bambu Studio, OrcaSlicer, PrusaSlicer).
    case extruder(Int)
}

/// A triangle mesh exactly as stored in the file (local coordinates, model units).
public struct Mesh: Sendable {
    /// Unique key ("<part path>#<object id>") — instances of the same object share it.
    public let key: String
    /// Flat xyz array.
    public internal(set) var positions: [Float]
    /// Three vertex indices per triangle.
    public internal(set) var indices: [UInt32]
    /// Distinct colour sources used by this mesh (never empty for a non-empty mesh).
    public internal(set) var palette: [ColorSource]
    /// Palette index per triangle. Empty when every triangle uses `palette[0]`.
    public internal(set) var triangleColors: [UInt16]

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    @inline(__always)
    public func paletteIndex(ofTriangle t: Int) -> Int {
        triangleColors.isEmpty ? 0 : Int(triangleColors[t])
    }
}

/// One placed copy of a mesh (build item × component chain).
public struct MeshInstance: Sendable {
    public var mesh: Mesh
    /// Mesh coordinates → build-plate coordinates (model units).
    public var transform: Transform3D
    /// Extruder / filament slot assigned by the slicer project, if any.
    public var extruder: Int?
    public var objectName: String?
}

public struct MetadataEntry: Hashable, Sendable {
    public let name: String
    public let value: String
}

/// A fully resolved 3MF file, ready to be rendered.
public struct ThreeMFModel: Sendable {
    public var unit: LengthUnit
    public var metadata: [MetadataEntry]
    public var instances: [MeshInstance]
    /// Filament colours from the slicer project (index 0 = extruder 1). Empty for plain 3MF files.
    public var filamentColors: [RGBAColor]
    /// Number of build items (printable objects on the plate).
    public var objectCount: Int
    /// Bounds of all instances in model units.
    public var bounds: BoundingBox?
    public var triangleCount: Int

    public func metadataValue(_ name: String) -> String? {
        metadata.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Model size in millimetres.
    public var sizeInMillimeters: SIMD3<Double>? {
        bounds.map { $0.size * unit.millimeters }
    }

    /// Resolves every palette entry of `instance.mesh` to a colour.
    /// `nil` means "no colour information" — the viewer's default colour should be used.
    public func resolvedColors(for instance: MeshInstance) -> [RGBAColor?] {
        instance.mesh.palette.map { source in
            switch source {
            case .color(let color):
                return color
            case .extruder(let slot):
                return filamentColor(slot) ?? inheritedColor(instance)
            case .inherit:
                return inheritedColor(instance)
            }
        }
    }

    public func filamentColor(_ slot: Int) -> RGBAColor? {
        slot >= 1 && slot <= filamentColors.count ? filamentColors[slot - 1] : nil
    }

    private func inheritedColor(_ instance: MeshInstance) -> RGBAColor? {
        instance.extruder.flatMap { filamentColor($0) }
    }
}

// MARK: - Palette helper

struct PaletteBuilder {
    private(set) var palette: [ColorSource] = []
    private var lookup: [ColorSource: UInt16] = [:]
    private var lastSource: ColorSource?
    private var lastIndex: UInt16 = 0

    mutating func index(for source: ColorSource) -> UInt16 {
        if let lastSource, lastSource == source { return lastIndex }
        let index: UInt16
        if let existing = lookup[source] {
            index = existing
        } else if palette.count < Int(UInt16.max) {
            index = UInt16(palette.count)
            palette.append(source)
            lookup[source] = index
        } else {
            index = 0 // absurd number of colours — fall back to the first one
        }
        lastSource = source
        lastIndex = index
        return index
    }
}
