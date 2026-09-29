import Foundation

/// The printable volume of a printer in millimetres.
public struct BuildVolume: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var depth: Double
    public var height: Double

    public init(width: Double, depth: Double, height: Double) {
        self.width = width
        self.depth = depth
        self.height = height
    }

    public var size: SIMD3<Double> { SIMD3(width, depth, height) }

    private static let tolerance = 0.01

    /// Whether a part of `size` (x, y, z in mm) fits, allowing a 90° turn on the bed.
    public func fits(_ size: SIMD3<Double>) -> Bool {
        fitsStraight(size) || fitsTurned(size)
    }

    private func fitsStraight(_ size: SIMD3<Double>) -> Bool {
        let t = Self.tolerance
        return size.x <= width + t && size.y <= depth + t && size.z <= height + t
    }

    private func fitsTurned(_ size: SIMD3<Double>) -> Bool {
        let t = Self.tolerance
        return size.y <= width + t && size.x <= depth + t && size.z <= height + t
    }

    /// The box to draw around a part of `size`: turned by 90° when the part only fits that way.
    public func outline(for size: SIMD3<Double>?) -> SIMD3<Double> {
        guard let size, !fitsStraight(size), fitsTurned(size) else { return self.size }
        return SIMD3(depth, width, height)
    }

    /// nil when the sizes are unknown (e.g. a sliced .gcode.3mf without geometry).
    public func fits(plateSizes: [SIMD3<Double>]) -> Bool? {
        plateSizes.isEmpty ? nil : plateSizes.allSatisfy { fits($0) }
    }

    public struct Preset: Identifiable, Hashable, Sendable {
        public let name: String
        public let volume: BuildVolume
        public var id: String { name }
    }

    public static let presets: [Preset] = [
        Preset(name: "Bambu Lab X1 / P1 / P2S / A1", volume: BuildVolume(width: 256, depth: 256, height: 256)),
        Preset(name: "Bambu Lab A1 mini / Prusa MINI+", volume: BuildVolume(width: 180, depth: 180, height: 180)),
        Preset(name: "Original Prusa MK4 / MK4S", volume: BuildVolume(width: 250, depth: 210, height: 220)),
        Preset(name: "Prusa Core One", volume: BuildVolume(width: 250, depth: 220, height: 270)),
        Preset(name: "Creality Ender-3 V3 / K1 / K1C", volume: BuildVolume(width: 220, depth: 220, height: 250)),
        Preset(name: "Creality K1 Max", volume: BuildVolume(width: 300, depth: 300, height: 300)),
        Preset(name: "Voron 2.4 350", volume: BuildVolume(width: 350, depth: 350, height: 340)),
    ]

    public static let `default` = presets[0].volume
}
