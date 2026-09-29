import Foundation

/// Filament prices and printer cost used to estimate what a print costs.
public struct PrintCostSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// ISO 4217 code, e.g. "RUB", "USD".
    public var currencyCode: String
    /// Price of 1 kg by filament type (upper-case: "PLA", "PETG"…).
    public var pricePerKg: [String: Double]
    /// For filament types that are not listed.
    public var otherPricePerKg: Double
    /// Electricity, wear and so on per hour of printing (0 = ignore).
    public var hourlyRate: Double

    public init(isEnabled: Bool = true, currencyCode: String, pricePerKg: [String: Double],
                otherPricePerKg: Double, hourlyRate: Double = 0) {
        self.isEnabled = isEnabled
        self.currencyCode = currencyCode
        self.pricePerKg = pricePerKg
        self.otherPricePerKg = otherPricePerKg
        self.hourlyRate = hourlyRate
    }

    /// Filament types shown in the settings.
    public static let commonTypes = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC"]

    /// Typical prices for the currency of `locale` (roubles or a dollar-like currency).
    public static func defaults(currencyCode: String) -> PrintCostSettings {
        if currencyCode == "RUB" {
            return PrintCostSettings(currencyCode: currencyCode,
                                     pricePerKg: ["PLA": 1500, "PETG": 1500, "ABS": 1600, "ASA": 2200,
                                                  "TPU": 2800, "PA": 4500, "PC": 3500],
                                     otherPricePerKg: 2000)
        }
        return PrintCostSettings(currencyCode: currencyCode,
                                 pricePerKg: ["PLA": 20, "PETG": 20, "ABS": 22, "ASA": 28,
                                              "TPU": 35, "PA": 60, "PC": 45],
                                 otherPricePerKg: 25)
    }

    /// Price of 1 kg of `type`. Variants use the base price ("PLA-CF", "PLA Silk" → "PLA") unless listed themselves.
    public func pricePerKg(forType type: String?) -> Double {
        guard let raw = type?.trimmingCharacters(in: .whitespaces).uppercased(), !raw.isEmpty else { return otherPricePerKg }
        if let exact = pricePerKg[raw] { return exact }
        let base = pricePerKg.keys
            .filter { raw.hasPrefix($0) }
            .max { $0.count < $1.count }
        return base.flatMap { pricePerKg[$0] } ?? otherPricePerKg
    }
}

/// Estimated cost of a print.
public struct PrintCost: Equatable, Sendable {
    public let material: Double
    public let machine: Double

    public var total: Double { material + machine }
}

public enum PrintCostCalculator {
    /// `filamentGrams` maps a filament type (nil / "" = unknown) to the grams used.
    /// Returns nil when nothing is known about the print.
    public static func cost(filamentGrams: [String: Double], printTime: TimeInterval?,
                            settings: PrintCostSettings) -> PrintCost? {
        guard !filamentGrams.isEmpty || printTime != nil else { return nil }
        let material = filamentGrams.reduce(0) { sum, entry in
            sum + entry.value / 1000 * settings.pricePerKg(forType: entry.key.isEmpty ? nil : entry.key)
        }
        let machine = (printTime ?? 0) / 3600 * settings.hourlyRate
        return PrintCost(material: material, machine: machine)
    }
}
