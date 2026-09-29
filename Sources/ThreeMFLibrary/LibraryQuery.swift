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
    public var filters: LibraryFilters

    public init(category: CategoryNode? = nil, searchText: String = "", sortOrder: FileSortOrder = .name,
                filters: LibraryFilters = LibraryFilters()) {
        self.category = category
        self.searchText = searchText
        self.sortOrder = sortOrder
        self.filters = filters
    }

    /// Filters and sorts `files`. `facts` supplies print times and model details for search and filters.
    public func apply(to files: [ModelFileItem],
                      facts: (ModelFileItem) -> FileFacts = { _ in FileFacts() }) -> [ModelFileItem] {
        var result = files
        if let category {
            result = result.filter { category.contains(path: $0.folderPath) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsFacts = !query.isEmpty || filters.isActive || sortOrder == .printTime
        let factsByID = needsFacts
            ? Dictionary(result.map { ($0.id, facts($0)) }, uniquingKeysWith: { first, _ in first })
            : [:]
        if !query.isEmpty {
            // File name, category, tags, and the title, designer and description inside the file.
            result = result.filter { file in
                file.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || file.relativeFolder.localizedCaseInsensitiveContains(query)
                    || file.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                    || factsByID[file.id]?.details?.matches(query) == true
            }
        }
        if filters.isActive {
            result = result.filter { file in filters.matches(file, factsByID[file.id] ?? FileFacts()) }
        }
        return sorted(result) { factsByID[$0.id]?.printTime }
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
