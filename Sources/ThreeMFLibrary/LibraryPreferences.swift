import Foundation

/// Library settings stored in user defaults.
public struct LibraryPreferences {
    private enum Keys {
        static let collections = "library.collections"
        static let legacyFolder = "library.folderPath"
        static let sortOrder = "library.sortOrder"
        static let expanded = "library.expandedCategories"
        static let selectedCategory = "library.selectedCategory"
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

    /// A category / collection path, or the app's "all models" id.
    public var selectedCategory: String? {
        get { defaults.string(forKey: Keys.selectedCategory) }
        nonmutating set { defaults.set(newValue, forKey: Keys.selectedCategory) }
    }
}
