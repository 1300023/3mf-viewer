import Foundation

public enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name, modified, size, printTime

    public var id: String { rawValue }
}

/// Which models the list shows: the selected category (with its subcategories), the search text and the order.
public struct LibraryQuery: Sendable {
    /// nil = all models.
    public var category: CategoryNode?
    public var searchText: String
    public var sortOrder: FileSortOrder

    public init(category: CategoryNode? = nil, searchText: String = "", sortOrder: FileSortOrder = .name) {
        self.category = category
        self.searchText = searchText
        self.sortOrder = sortOrder
    }

    /// Filters and sorts `files`. `printTime` supplies the estimated print time of sliced projects.
    public func apply(to files: [ModelFileItem],
                      printTime: (ModelFileItem) -> TimeInterval? = { _ in nil }) -> [ModelFileItem] {
        var result = files
        if let category {
            result = result.filter { category.contains(path: $0.folderPath) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || $0.relativeFolder.localizedCaseInsensitiveContains(query)
            }
        }
        return sorted(result, printTime: printTime)
    }

    private func sorted(_ files: [ModelFileItem], printTime: (ModelFileItem) -> TimeInterval?) -> [ModelFileItem] {
        func byName(_ a: ModelFileItem, _ b: ModelFileItem) -> Bool {
            a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        switch sortOrder {
        case .name:
            return files.sorted(by: byName)
        case .modified:
            return files.sorted { $0.modified > $1.modified }
        case .size:
            return files.sorted { $0.size > $1.size }
        case .printTime:
            // Shortest prints first; files that were never sliced go to the end, by name.
            let times = Dictionary(files.map { ($0.id, printTime($0)) }, uniquingKeysWith: { first, _ in first })
            return files.sorted { a, b in
                switch (times[a.id] ?? nil, times[b.id] ?? nil) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        }
    }
}
