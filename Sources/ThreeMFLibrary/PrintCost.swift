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
    /// Wear, maintenance and so on per hour of printing (0 = ignore). Electricity is counted separately.
    public var hourlyRate: Double
    /// Infill (0…1) assumed when estimating the plastic of a model that was not sliced.
    public var estimateInfill: Double
    /// Price of 1 kWh (0 = ignore electricity).
    public var electricityPrice: Double
    /// `PrinterPower.presets` id of the user's printer, or `PrinterPower.customID`.
    public var printerID: String
    /// Power of the user's printer when `printerID` is custom.
    public var customPower: PrinterPower
    /// Use the power of the printer a project was sliced for, when it is a known one.
    public var usesProjectPrinter: Bool

    public static let defaultInfill = 0.15
    public static let defaultPrinterID = "bambu-p1s"
    public static let defaultCustomPower = PrinterPower(id: PrinterPower.customID, name: "", pla: 100, petg: 130, abs: 150)

    public init(isEnabled: Bool = true, currencyCode: String, pricePerKg: [String: Double],
                otherPricePerKg: Double, hourlyRate: Double = 0, estimateInfill: Double = PrintCostSettings.defaultInfill,
                electricityPrice: Double = 0, printerID: String = PrintCostSettings.defaultPrinterID,
                customPower: PrinterPower = PrintCostSettings.defaultCustomPower, usesProjectPrinter: Bool = true) {
        self.isEnabled = isEnabled
        self.currencyCode = currencyCode
        self.pricePerKg = pricePerKg
        self.otherPricePerKg = otherPricePerKg
        self.hourlyRate = hourlyRate
        self.estimateInfill = estimateInfill
        self.electricityPrice = electricityPrice
        self.printerID = printerID
        self.customPower = customPower
        self.usesProjectPrinter = usesProjectPrinter
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, currencyCode, pricePerKg, otherPricePerKg, hourlyRate, estimateInfill
        case electricityPrice, printerID, customPower, usesProjectPrinter
    }

    /// Settings saved by older versions miss the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        pricePerKg = try container.decode([String: Double].self, forKey: .pricePerKg)
        otherPricePerKg = try container.decode(Double.self, forKey: .otherPricePerKg)
        hourlyRate = try container.decodeIfPresent(Double.self, forKey: .hourlyRate) ?? 0
        estimateInfill = try container.decodeIfPresent(Double.self, forKey: .estimateInfill) ?? Self.defaultInfill
        electricityPrice = try container.decodeIfPresent(Double.self, forKey: .electricityPrice)
            ?? Self.defaultElectricityPrice(currencyCode: currencyCode)
        printerID = try container.decodeIfPresent(String.self, forKey: .printerID) ?? Self.defaultPrinterID
        customPower = try container.decodeIfPresent(PrinterPower.self, forKey: .customPower) ?? Self.defaultCustomPower
        usesProjectPrinter = try container.decodeIfPresent(Bool.self, forKey: .usesProjectPrinter) ?? true
    }

    /// Typical household tariff per kWh.
    public static func defaultElectricityPrice(currencyCode: String) -> Double {
        switch currencyCode {
        case "RUB": return 8
        case "KZT": return 30
        case "BYN": return 0.3
        case "UAH": return 4.3
        case "TRY": return 3
        case "CNY": return 0.6
        case "JPY": return 30
        case "INR": return 8
        default: return 0.2
        }
    }

    /// The user's printer.
    public var printerPower: PrinterPower {
        printerID == PrinterPower.customID ? customPower : (PrinterPower.preset(id: printerID) ?? customPower)
    }

    /// The printer whose power is used for a project sliced for `printerName`.
    public func power(forPrinterName printerName: String?) -> PrinterPower {
        if usesProjectPrinter, let preset = PrinterPower.preset(forPrinterName: printerName) { return preset }
        return printerPower
    }

    /// Filament types shown in the settings.
    public static let commonTypes = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC"]

    /// Typical prices for the currency of `locale` (roubles or a dollar-like currency).
    public static func defaults(currencyCode: String) -> PrintCostSettings {
        let electricity = defaultElectricityPrice(currencyCode: currencyCode)
        if currencyCode == "RUB" {
            return PrintCostSettings(currencyCode: currencyCode,
                                     pricePerKg: ["PLA": 1500, "PETG": 1500, "ABS": 1600, "ASA": 2200,
                                                  "TPU": 2800, "PA": 4500, "PC": 3500],
                                     otherPricePerKg: 2000, electricityPrice: electricity)
        }
        return PrintCostSettings(currencyCode: currencyCode,
                                 pricePerKg: ["PLA": 20, "PETG": 20, "ABS": 22, "ASA": 28,
                                              "TPU": 35, "PA": 60, "PC": 45],
                                 otherPricePerKg: 25, electricityPrice: electricity)
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
    /// Filament.
    public let material: Double
    /// Electricity.
    public let energy: Double
    /// Wear and other costs per hour.
    public let machine: Double
    /// Electricity used, kWh.
    public let kilowattHours: Double
    /// The printer whose power was used (nil when the print time is unknown) and its power for this filament, W.
    public let printer: PrinterPower?
    public let watts: Double

    public init(material: Double, energy: Double = 0, machine: Double = 0, kilowattHours: Double = 0,
                printer: PrinterPower? = nil, watts: Double = 0) {
        self.material = material
        self.energy = energy
        self.machine = machine
        self.kilowattHours = kilowattHours
        self.printer = printer
        self.watts = watts
    }

    public var total: Double { material + energy + machine }
}

public enum PrintCostCalculator {
    /// `filamentGrams` maps a filament type (nil / "" = unknown) to the grams used; `printerName` is the printer the
    /// project was sliced for. Returns nil when nothing is known about the print.
    public static func cost(filamentGrams: [String: Double], printTime: TimeInterval?,
                            settings: PrintCostSettings, printerName: String? = nil) -> PrintCost? {
        guard !filamentGrams.isEmpty || printTime != nil else { return nil }
        let material = filamentGrams.reduce(0) { sum, entry in
            sum + entry.value / 1000 * settings.pricePerKg(forType: entry.key.isEmpty ? nil : entry.key)
        }
        guard let printTime, printTime > 0 else { return PrintCost(material: material) }
        let hours = printTime / 3600
        // The filament used most decides how hot the bed and chamber are.
        let mainType = filamentGrams.max { $0.value < $1.value }?.key
        let printer = settings.power(forPrinterName: printerName)
        let watts = printer.watts(forType: mainType)
        let kilowattHours = hours * watts / 1000
        return PrintCost(material: material,
                         energy: kilowattHours * settings.electricityPrice,
                         machine: hours * settings.hourlyRate,
                         kilowattHours: kilowattHours,
                         printer: printer,
                         watts: watts)
    }
}
