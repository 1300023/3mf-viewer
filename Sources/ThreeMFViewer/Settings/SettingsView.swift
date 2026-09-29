import AppKit
import SwiftUI
import ThreeMFLibrary

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            PrinterSettingsView()
                .tabItem { Label("Printer", systemImage: "printer") }
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

/// "Library" tab: the Inbox folder.
struct LibrarySettingsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        Form {
            Toggle("Show Inbox", isOn: $library.isInboxEnabled)
            HStack {
                Text("Inbox folder")
                Spacer()
                Text(library.inboxFolder.map { FileManager.default.displayName(atPath: $0.path) } ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(library.inboxFolder?.path ?? "")
                Button("Choose…", action: chooseFolder)
            }
            .disabled(!library.isInboxEnabled)
            Text("New model files in this folder (and one level of subfolders) are listed in the Inbox. Drag them to a category to move them into the library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.inboxFolder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            library.inboxFolder = url.standardizedFileURL
        }
    }
}

/// "Printer" tab: the build volume used for "fits the printer".
struct PrinterSettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @AppStorage("viewer.showBuildVolume") private var showBuildVolume = false

    var body: some View {
        Form {
            LabeledContent("Printer") {
                Menu {
                    ForEach(BuildVolume.presets) { preset in
                        Button(preset.name) { library.buildVolume = preset.volume }
                    }
                } label: {
                    Text(presetName ?? String(localized: "Custom"))
                }
                .fixedSize()
            }

            Section {
                TextField("Width (X)", value: dimension(\.width), format: .number)
                TextField("Depth (Y)", value: dimension(\.depth), format: .number)
                TextField("Height (Z)", value: dimension(\.height), format: .number)
            } header: {
                Text("Build volume, mm")
            }

            Toggle("Show build volume in 3D", isOn: $showBuildVolume)

            Text("Models with a plate larger than the build volume are marked in the list. A model that fits only when turned by 90° counts as fitting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private var presetName: String? {
        BuildVolume.presets.first { $0.volume == library.buildVolume }?.name
    }

    private func dimension(_ keyPath: WritableKeyPath<BuildVolume, Double>) -> Binding<Double> {
        Binding(
            get: { library.buildVolume[keyPath: keyPath] },
            set: { value in
                guard value > 0 else { return }
                library.buildVolume[keyPath: keyPath] = min(value, 5000)
            }
        )
    }
}
