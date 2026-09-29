import Foundation
import ThreeMFKit

/// Typical filament densities, g/cm³.
public enum FilamentDensity {
    public static let table: [String: Double] = [
        "PLA": 1.24, "PETG": 1.27, "ABS": 1.04, "ASA": 1.07, "TPU": 1.21, "PA": 1.14, "PC": 1.20,
    ]
    /// For unknown types.
    public static let fallback = 1.24

    /// Variants use the base type ("PLA-CF", "PETG HF" → "PLA", "PETG").
    public static func density(forType type: String?) -> Double {
        guard let raw = type?.trimmingCharacters(in: .whitespaces).uppercased(), !raw.isEmpty else { return fallback }
        if let exact = table[raw] { return exact }
        let base = table.keys.filter { raw.hasPrefix($0) }.max { $0.count < $1.count }
        return base.flatMap { table[$0] } ?? fallback
    }
}

/// What the same print would cost in one filament.
public struct MaterialCostRow: Equatable, Sendable, Identifiable {
    public let type: String
    public let grams: Double
    public let cost: PrintCost
    /// The project is sliced for this filament.
    public let isCurrent: Bool

    public var id: String { type }
}

/// The print in each common filament: from the slicer's result, or estimated from the model's shape.
public struct MaterialComparison: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Plastic volume taken from the sliced project.
        case sliced
        /// Plastic volume estimated from the model's volume and surface (walls + infill).
        case estimated
    }

    public let source: Source
    /// Plastic used, cm³.
    public let volume: Double
    public let rows: [MaterialCostRow]
}

public enum MaterialCostCalculator {
    /// Walls and top / bottom layers of a typical profile (2 perimeters of 0.42 mm, about 1 mm top and bottom).
    public static let shellThickness = 0.9

    /// Plastic a slicer would use for a solid of `measure`, cm³: the shell plus `infill` (0…1) of the inside.
    public static func printedVolume(_ measure: MeshMeasure, infill: Double) -> Double {
        let shell = min(measure.volume, measure.surfaceArea * shellThickness)
        let inside = max(measure.volume - shell, 0)
        return (shell + inside * min(max(infill, 0), 1)) / 1000
    }

    /// Plastic volume of a sliced print, cm³, from the grams used per filament type.
    public static func volume(filamentGrams: [String: Double]) -> Double {
        filamentGrams.reduce(0) { sum, entry in
            sum + entry.value / FilamentDensity.density(forType: entry.key.isEmpty ? nil : entry.key)
        }
    }

    /// Cost of `volume` cm³ of plastic in each of `types`; the print time (if known) adds electricity (hotter
    /// filaments draw more power) and the printer's hourly cost.
    public static func compare(volume: Double, printTime: TimeInterval?, source: MaterialComparison.Source,
                               currentTypes: Set<String> = [], settings: PrintCostSettings, printerName: String? = nil,
                               types: [String] = PrintCostSettings.commonTypes) -> MaterialComparison? {
        guard volume > 0, !types.isEmpty else { return nil }
        let current = Set(currentTypes.map { baseType(of: $0, in: types) })
        let rows = types.map { type -> MaterialCostRow in
            let grams = volume * FilamentDensity.density(forType: type)
            let cost = PrintCostCalculator.cost(filamentGrams: [type: grams], printTime: printTime,
                                                settings: settings, printerName: printerName)
                ?? PrintCost(material: 0)
            return MaterialCostRow(type: type, grams: grams, cost: cost, isCurrent: current.contains(type))
        }
        return MaterialComparison(source: source, volume: volume, rows: rows)
    }

    /// The listed type a filament belongs to ("PLA Silk" → "PLA").
    static func baseType(of type: String, in types: [String]) -> String {
        let raw = type.trimmingCharacters(in: .whitespaces).uppercased()
        return types.filter { raw.hasPrefix($0) }.max { $0.count < $1.count } ?? raw
    }
}
