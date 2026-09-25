import AppKit
import SwiftUI

/// Interface language of the app. English is the default; Russian and "same as the system" can be
/// chosen in Settings or in the app menu. The choice is applied through the standard per-app
/// `AppleLanguages` preference, so it takes effect on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    case system

    static let defaultsKey = "app.language"

    var id: String { rawValue }

    /// Each language is shown in its own name, so it can be found whatever the current language is.
    var title: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .system: return String(localized: "System Language")
        }
    }

    /// The language chosen by the user (English until another one is picked).
    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .english
    }

    /// The choice that was applied when this process started.
    private(set) static var launched: AppLanguage = .english

    /// Must run before the first localized string is looked up, i.e. at the very start of `main`.
    static func applyAtLaunch() {
        let defaults = UserDefaults.standard
        launched = stored
        switch launched {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")  // fall back to the system list
        case .english, .russian:
            defaults.set([launched.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Locale for dates: the interface language combined with the user's region.
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        if let region = Locale.current.region?.identifier {
            return Locale(identifier: "\(language)_\(region)")
        }
        return Locale(identifier: language)
    }()

    static var needsRestart: Bool { stored != launched }

    /// Stores the choice and, when it differs from the running language, offers to restart.
    @MainActor
    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        guard needsRestart else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "The language will change after 3MF Viewer restarts.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Starts a fresh copy of the app and quits this one.
    @MainActor
    static func relaunch() {
        guard canRelaunch else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        UserDefaults.standard.synchronize()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The Settings window (⌘,).
struct SettingsView: View {
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
        .frame(width: 440)
        // Re-render when the stored value changes (the condition above reads UserDefaults).
        .id(language)
    }
}
