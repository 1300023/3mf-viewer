import Foundation
import ThreeMFKit
import ThreeMFLibrary

/// The print cost settings of this Mac and the formatting of costs.
@MainActor
final class PrintCostStore: ObservableObject {
    private static let defaultsKey = "cost.settings"

    @Published var settings: PrintCostSettings {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(PrintCostSettings.self, from: data) {
            settings = stored
        } else {
            settings = PrintCostSettings.defaults(currencyCode: Self.localCurrency)
        }
    }

    private let defaults: UserDefaults

    /// Currency of the Mac's region ("RUB" in Russia).
    static var localCurrency: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    func restoreDefaults() {
        settings = PrintCostSettings.defaults(currencyCode: settings.currencyCode)
    }

    // MARK: - Estimates

    /// Cost of a whole sliced project from the library summary; nil when switched off or unknown.
    func cost(of summary: SliceSummary?) -> PrintCost? {
        guard let summary else { return nil }
        return cost(filamentGrams: summary.filamentGrams, printTime: summary.printTime)
    }

    func cost(filamentGrams: [String: Double], printTime: TimeInterval?) -> PrintCost? {
        guard settings.isEnabled else { return nil }
        return PrintCostCalculator.cost(filamentGrams: filamentGrams, printTime: printTime, settings: settings)
    }

    /// "≈ 45 ₽".
    func format(_ cost: PrintCost) -> String {
        "≈ " + format(amount: cost.total)
    }

    func format(amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = AppLanguage.locale
        formatter.currencyCode = settings.currencyCode
        let digits = amount < 10 ? 2 : 0
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.0f", amount)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
