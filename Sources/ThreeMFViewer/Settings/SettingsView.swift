import SwiftUI
import ThreeMFLibrary

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            CostSettingsView()
                .tabItem { Label("Print Cost", systemImage: "banknote") }
        }
        .frame(width: 480)
    }
}

/// "General" tab of the Settings window.
struct GeneralSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.english.rawValue

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            if AppLanguage.stored != AppLanguage.launched {
                HStack(spacing: 12) {
                    Text("The language will change after 3MF Viewer restarts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if AppLanguage.canRelaunch {
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(24)
        // Re-render when the stored value changes (the condition above reads UserDefaults).
        .id(language)
    }
}

/// "Print Cost" tab: filament prices per kg and the printer's cost per hour.
struct CostSettingsView: View {
    @EnvironmentObject private var costs: PrintCostStore

    var body: some View {
        Form {
            Toggle("Show print cost", isOn: $costs.settings.isEnabled)

            Picker("Currency", selection: $costs.settings.currencyCode) {
                ForEach(currencies, id: \.self) { code in
                    Text(currencyTitle(code)).tag(code)
                }
            }

            Section {
                ForEach(PrintCostSettings.commonTypes, id: \.self) { type in
                    TextField(type, value: price(for: type), format: .number)
                }
                TextField("Other types", value: $costs.settings.otherPricePerKg, format: .number)
            } header: {
                Text("Filament price per kg")
            }

            Section {
                TextField("Printer cost per hour", value: $costs.settings.hourlyRate, format: .number)
            } footer: {
                Text("Cost = filament used × price per kg + print time × printer cost per hour. Filament variants such as PLA-CF use the base price.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") { costs.restoreDefaults() }
            }
        }
        .padding(24)
    }

    private var currencies: [String] {
        var codes = ["RUB", "USD", "EUR", "GBP", "CNY", "KZT", "BYN", "UAH", "TRY", "PLN", "JPY", "INR", "BRL", "CAD", "AUD"]
        if !codes.contains(costs.settings.currencyCode) { codes.insert(costs.settings.currencyCode, at: 0) }
        return codes
    }

    private func currencyTitle(_ code: String) -> String {
        let name = AppLanguage.locale.localizedString(forCurrencyCode: code) ?? code
        return "\(code) — \(name)"
    }

    private func price(for type: String) -> Binding<Double> {
        Binding(
            get: { costs.settings.pricePerKg[type] ?? costs.settings.otherPricePerKg },
            set: { costs.settings.pricePerKg[type] = max(0, $0) }
        )
    }
}
