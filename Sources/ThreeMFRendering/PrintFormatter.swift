import Foundation

/// Formats print data for display: durations, filament weight and length, millimetres.
/// Shared by the app and the Quick Look extension.
public struct PrintFormatter: Sendable {
    public let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// "1h 25m" / "1 ч 25 мин".
    public func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        if seconds >= 3600 {
            formatter.allowedUnits = [.hour, .minute]
        } else if seconds >= 60 {
            formatter.allowedUnits = [.minute]
        } else {
            formatter.allowedUnits = [.second]
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: seconds.rounded()) ?? ""
    }

    public func grams(_ value: Double) -> String {
        measurement(value, UnitMass.grams, fractionDigits: value < 10 ? 1 : 0)
    }

    public func meters(_ value: Double) -> String {
        measurement(value, UnitLength.meters, fractionDigits: value < 10 ? 2 : 1)
    }

    /// "0.4" → "0.4 mm". Values that are not numbers are returned as they are.
    public func millimeters(_ text: String) -> String {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return text }
        return measurement(value, UnitLength.millimeters, fractionDigits: 2)
    }

    /// "30.5 g · 10.2 m" (nil when neither is known).
    public func filament(grams: Double?, meters: Double?) -> String? {
        let parts = [grams.map(self.grams), meters.map(self.meters)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func measurement<U: Dimension>(_ value: Double, _ unit: U, fractionDigits: Int) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.minimumFractionDigits = 0
        formatter.numberFormatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: Measurement(value: value, unit: unit))
    }
}
