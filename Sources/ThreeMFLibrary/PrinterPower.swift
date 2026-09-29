import Foundation

/// Average electrical power of a printer while printing, by filament group.
///
/// Values are typical averages over a whole print (heating up draws more for a short time).
/// Bambu Lab: wiki "Printer and AMS power parameters" (P2S: steady state at 220 V from its FAQ);
/// Prusa MK4: Prusa knowledge base (80 W PLA, 120 W ABS); others: published measurements.
/// Where a maker gives only PLA, PETG and ABS are extrapolated.
public struct PrinterPower: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Watts while printing PLA (also used for TPU and unknown filaments).
    public var pla: Double
    /// Watts while printing PETG.
    public var petg: Double
    /// Watts while printing ABS, ASA, PC, PA (hot bed and chamber).
    public var abs: Double

    public init(id: String, name: String, pla: Double, petg: Double, abs: Double) {
        self.id = id
        self.name = name
        self.pla = pla
        self.petg = petg
        self.abs = abs
    }

    /// Average power while printing `type`.
    public func watts(forType type: String?) -> Double {
        let raw = type?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        if raw.hasPrefix("PETG") || raw.hasPrefix("PCTG") { return petg }
        if ["ABS", "ASA", "PC", "PA", "PPS", "PET-CF", "HIPS"].contains(where: { raw.hasPrefix($0) }) { return abs }
        return pla
    }

    public static let customID = "custom"

    /// Popular printers. More specific names come first, so that "A1 mini" wins over "A1".
    public static let presets: [PrinterPower] = [
        PrinterPower(id: "bambu-a1-mini", name: "Bambu Lab A1 mini", pla: 80, petg: 75, abs: 110),
        PrinterPower(id: "bambu-a1", name: "Bambu Lab A1", pla: 95, petg: 120, abs: 200),
        PrinterPower(id: "bambu-p1p", name: "Bambu Lab P1P", pla: 110, petg: 160, abs: 170),
        PrinterPower(id: "bambu-p1s", name: "Bambu Lab P1S", pla: 105, petg: 135, abs: 140),
        PrinterPower(id: "bambu-p2s", name: "Bambu Lab P2S", pla: 200, petg: 250, abs: 270),
        PrinterPower(id: "bambu-x1e", name: "Bambu Lab X1E", pla: 185, petg: 230, abs: 260),
        PrinterPower(id: "bambu-x1c", name: "Bambu Lab X1 / X1 Carbon", pla: 105, petg: 135, abs: 150),
        PrinterPower(id: "bambu-h2d", name: "Bambu Lab H2D", pla: 197, petg: 150, abs: 250),
        PrinterPower(id: "prusa-mk4", name: "Original Prusa MK4 / MK4S", pla: 80, petg: 95, abs: 120),
        PrinterPower(id: "prusa-core-one", name: "Prusa CORE One", pla: 120, petg: 140, abs: 170),
        PrinterPower(id: "creality-k1-max", name: "Creality K1 Max", pla: 200, petg: 240, abs: 270),
        PrinterPower(id: "creality-k1", name: "Creality K1 / K1C", pla: 100, petg: 125, abs: 140),
        PrinterPower(id: "creality-ender3-v3", name: "Creality Ender-3 V3", pla: 125, petg: 140, abs: 160),
        PrinterPower(id: "anycubic-kobra3", name: "Anycubic Kobra 3", pla: 180, petg: 200, abs: 230),
        PrinterPower(id: "voron-2.4", name: "Voron 2.4 (350)", pla: 180, petg: 200, abs: 225),
    ]

    /// Patterns for printer names written by slicers ("Bambu Lab P1S 0.4 nozzle", "Original Prusa MK4S"…).
    private static let patterns: [String: String] = [
        "bambu-a1-mini": #"\ba1\s*mini\b"#,
        "bambu-a1": #"\ba1\b"#,
        "bambu-p1p": #"\bp1p\b"#,
        "bambu-p1s": #"\bp1s\b"#,
        "bambu-p2s": #"\bp2s\b"#,
        "bambu-x1e": #"\bx1e\b"#,
        "bambu-x1c": #"\bx1(c|\s*carbon)?\b"#,
        "bambu-h2d": #"\bh2d\b"#,
        "prusa-mk4": #"\bmk4s?\b"#,
        "prusa-core-one": #"\bcore\s*one\b"#,
        "creality-k1-max": #"\bk1\s*max\b"#,
        "creality-k1": #"\bk1c?\b"#,
        "creality-ender3-v3": #"\bender[\s-]*3\s*v3\b"#,
        "anycubic-kobra3": #"\bkobra\s*3\b"#,
        "voron-2.4": #"\bvoron\b"#,
    ]

    public static func preset(id: String) -> PrinterPower? {
        presets.first { $0.id == id }
    }

    /// The preset for a printer name from a slicer project, if it is one of the known printers.
    public static func preset(forPrinterName name: String?) -> PrinterPower? {
        guard let name, !name.isEmpty else { return nil }
        return presets.first { preset in
            guard let pattern = patterns[preset.id] else { return false }
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
