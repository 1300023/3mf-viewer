import Foundation

/// Library settings stored in user defaults.
public struct LibraryPreferences {
    private enum Keys {
        static let collections = "library.collections"
        static let legacyFolder = "library.folderPath"
        static let sortOrder = "library.sortOrder"
        static let expanded = "library.expandedCategories"
        static let selectedCategory = "library.selectedCategory"
        static let inboxEnabled = "library.inboxEnabled"
        static let inboxFolder = "library.inboxFolder"
        static let buildVolume = "printer.buildVolume"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var collections: [URL] {
        get {
            (defaults.stringArray(forKey: Keys.collections) ?? [])
                .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        }
        nonmutating set { defaults.set(newValue.map(\.path), forKey: Keys.collections) }
    }

    /// The single folder of versions before collections existed (migrated to a collection once).
    public var legacyFolder: URL? {
        defaults.string(forKey: Keys.legacyFolder).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    public var expandedCategories: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.expanded) ?? []) }
        nonmutating set { defaults.set(Array(newValue), forKey: Keys.expanded) }
    }

    public var sortOrder: FileSortOrder {
        get { FileSortOrder(rawValue: defaults.string(forKey: Keys.sortOrder) ?? "") ?? .name }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.sortOrder) }
    }

    /// Show the Inbox (new downloads). On by default.
    public var isInboxEnabled: Bool {
        get { defaults.object(forKey: Keys.inboxEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Keys.inboxEnabled) }
    }

    /// The folder the Inbox shows; ~/Downloads by default.
    public var inboxFolder: URL? {
        get {
            if let path = defaults.string(forKey: Keys.inboxFolder) {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.standardizedFileURL
        }
        nonmutating set { defaults.set(newValue?.path, forKey: Keys.inboxFolder) }
    }

    /// The printer's build volume, for "fits the printer" checks.
    public var buildVolume: BuildVolume {
        get {
            guard let data = defaults.data(forKey: Keys.buildVolume),
                  let volume = try? JSONDecoder().decode(BuildVolume.self, from: data) else { return .default }
            return volume
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.buildVolume) }
    }

    /// A category / collection path, or the app's "all models" id.
    public var selectedCategory: String? {
        get { defaults.string(forKey: Keys.selectedCategory) }
        nonmutating set { defaults.set(newValue, forKey: Keys.selectedCategory) }
    }
}
