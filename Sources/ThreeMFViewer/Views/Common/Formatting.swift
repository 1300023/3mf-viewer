import SwiftUI
import ThreeMFKit
import ThreeMFRendering

extension PrintFormatter {
    /// Formats in the interface language chosen in the app.
    static let app = PrintFormatter(locale: AppLanguage.locale)
}

extension PlateInfo {
    /// "2. Hooks" or "Plate 2".
    var title: String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return "\(index). \(name)"
        }
        return String(localized: "Plate \(index)")
    }
}
