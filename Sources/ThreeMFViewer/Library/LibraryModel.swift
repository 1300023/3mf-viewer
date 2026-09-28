import AppKit
import CoreServices
import SwiftUI
import ThreeMFKit

struct ModelFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date
    /// Root folder of the collection that contains the file.
    let collectionPath: String
    /// Category path inside the collection ("" = collection root), e.g. "Kitchen/Hooks".
    let relativeFolder: String

    var id: String { url.path }
    var folderPath: String { url.deletingLastPathComponent().path }

    var displayName: String {
        let name = url.lastPathComponent
        return format != nil ? (name as NSString).deletingPathExtension : name
    }

    var format: ModelFileFormat? { ModelFileFormat(url: url) }

    /// Changes whenever the file changes — used for thumbnail caching.
    var cacheKey: String { "\(url.path)|\(size)|\(Int(modified.timeIntervalSince1970))" }
}

/// A collection (root folder) or a category (any subfolder of it). The folder tree on disk *is* the category tree.
struct CategoryNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isCollection: Bool
    /// False when a collection's folder is missing (e.g. an external disk is not connected).
    let isAvailable: Bool
    var children: [CategoryNode]
    /// Number of models in this folder and all of its subfolders.
    var modelCount: Int

    var id: String { url.path }
}

/// One visible row of the sidebar tree.
struct SidebarRow: Identifiable, Hashable {
    let node: CategoryNode
    let depth: Int
    var id: String { node.id }
}

enum FileSortOrder: String, CaseIterable, Identifiable {
    case name, modified, size, printTime

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .printTime: return "Print Time"
        }
    }
}

/// Requests for the name prompt shown by the sidebar (also triggered from the menu bar).
enum NamePrompt: Identifiable {
    case newCategory(parent: CategoryNode)
    case rename(CategoryNode)

    var id: String {
        switch self {
        case .newCategory(let parent): return "new:" + parent.id
        case .rename(let node): return "rename:" + node.id
        }
    }
}

/// Collections of .3mf models. Each collection is a folder; its subfolders are categories and
/// subcategories. Every change made in the app (create / rename / delete a category, move a model)
/// is performed on the folders themselves, and changes made in Finder show up in the app.
@MainActor
final class LibraryModel: ObservableObject {
    static let allModelsID = "::all-models"

    @Published private(set) var collections: [URL] = []
    @Published private(set) var tree: [CategoryNode] = []
    @Published private(set) var files: [ModelFileItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var didScanOnce = false

    /// Selected sidebar row: a category/collection path or `allModelsID`.
    @Published var selectedCategoryID: String? = LibraryModel.allModelsID {
        didSet {
            defaults.set(selectedCategoryID, forKey: Keys.selectedCategory)
            // Don't keep showing a model that is not part of the newly selected category.
            if selectedCategoryID != oldValue, let current = selection,
               !visibleFiles.contains(where: { $0.id == current }) {
                selection = nil
            }
        }
    }
    /// Selected model.
    @Published var selection: ModelFileItem.ID?
    @Published var searchText = ""
    @Published var sortOrder: FileSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Keys.sortOrder) }
    }
    @Published private(set) var expanded: Set<String> {
        didSet { defaults.set(Array(expanded), forKey: Keys.expanded) }
    }
    /// Print time and weight of sliced projects, read in the background after each scan (keyed by file id).
    @Published private(set) var sliceSummaries: [String: SliceSummary] = [:]
    @Published var namePrompt: NamePrompt? {
        didSet {
            guard namePrompt?.id != oldValue?.id else { return }
            switch namePrompt {
            case .rename(let node): nameText = node.name
            default: nameText = ""
            }
        }
    }
    /// Text of the name prompt (pre-filled with the current name when renaming).
    @Published var nameText = ""
    @Published var errorMessage: String?

    private enum Keys {
        static let collections = "library.collections"
        static let legacyFolder = "library.folderPath"
        static let sortOrder = "library.sortOrder"
        static let expanded = "library.expandedCategories"
        static let selectedCategory = "library.selectedCategory"
    }

    private let defaults = UserDefaults.standard
    private var nodeIndex: [String: CategoryNode] = [:]
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingSelection: String?
    private var watcher: FolderWatcher?
    /// File id → cache key the summary (or its absence) was computed for.
    private var summaryKeys: [String: String] = [:]
    private var summaryTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard
        sortOrder = FileSortOrder(rawValue: stored.string(forKey: Keys.sortOrder) ?? "") ?? .name
        expanded = Set(stored.stringArray(forKey: Keys.expanded) ?? [])
        var paths = stored.stringArray(forKey: Keys.collections) ?? []
        if paths.isEmpty, let legacy = stored.string(forKey: Keys.legacyFolder) {
            paths = [legacy]  // migrate from the single-folder version
            expanded.insert(URL(fileURLWithPath: legacy).standardizedFileURL.path)
        }
        collections = paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        selectedCategoryID = stored.string(forKey: Keys.selectedCategory) ?? Self.allModelsID
        saveCollections()
        startWatching()
        refresh()
    }

    // MARK: - Derived data

    /// Rows of the sidebar tree, honouring the expanded state.
    var sidebarRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        func add(_ nodes: [CategoryNode], depth: Int) {
            for node in nodes {
                rows.append(SidebarRow(node: node, depth: depth))
                if expanded.contains(node.id) { add(node.children, depth: depth + 1) }
            }
        }
        add(tree, depth: 0)
        return rows
    }

    var selectedCategory: CategoryNode? {
        selectedCategoryID.flatMap { nodeIndex[$0] }
    }

    var totalModelCount: Int { files.count }

    /// Models of the selected category (including its subcategories), filtered and sorted.
    var visibleFiles: [ModelFileItem] {
        var result = files
        if let category = selectedCategory {
            let prefix = category.id + "/"
            result = result.filter { $0.folderPath == category.id || $0.folderPath.hasPrefix(prefix) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || $0.relativeFolder.localizedCaseInsensitiveContains(query)
            }
        }
        switch sortOrder {
        case .name:
            return result.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .modified:
            return result.sorted { $0.modified > $1.modified }
        case .size:
            return result.sorted { $0.size > $1.size }
        case .printTime:
            // Shortest prints first; files that were never sliced go to the end, by name.
            return result.sorted {
                switch (sliceSummary(for: $0)?.printTime, sliceSummary(for: $1)?.printTime) {
                case let (a?, b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            }
        }
    }

    var selectedFile: ModelFileItem? {
        guard let selection else { return nil }
        return files.first { $0.id == selection }
    }

    /// The folder new models go to: the selected category, or the first collection.
    var importTarget: CategoryNode? {
        if let category = selectedCategory, category.isAvailable { return category }
        return tree.first { $0.isAvailable }
    }

    func node(id: String) -> CategoryNode? { nodeIndex[id] }

    func isExpanded(_ node: CategoryNode) -> Bool { expanded.contains(node.id) }

    func toggleExpanded(_ node: CategoryNode) {
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    // MARK: - Collections

    func addCollection() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a folder for the collection")
        if panel.runModal() == .OK {
            for url in panel.urls { addCollection(url) }
        }
    }

    func addCollection(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = collectionRoot(containing: url) {
            // Already part of a collection: just show it.
            reveal(folder: url, in: existing)
            return
        }
        // A folder that contains existing collections replaces them.
        collections.removeAll { $0.path.hasPrefix(url.path + "/") }
        collections.append(url)
        expanded.insert(url.path)
        selectedCategoryID = url.path
        saveCollections()
        startWatching()
        refresh()
    }

    func removeCollection(_ node: CategoryNode) {
        guard node.isCollection else { return }
        collections.removeAll { $0.path == node.id }
        if let selected = selectedCategoryID, selected == node.id || selected.hasPrefix(node.id + "/") {
            selectedCategoryID = Self.allModelsID
        }
        if let selection, selection.hasPrefix(node.id + "/") { self.selection = nil }
        saveCollections()
        startWatching()
        refresh()
    }

    // MARK: - Categories (folders)

    func requestNewCategory() {
        guard let parent = importTarget else {
            addCollection()
            return
        }
        namePrompt = .newCategory(parent: parent)
    }

    @discardableResult
    func createCategory(named rawName: String, in parent: CategoryNode) -> Bool {
        guard let name = Self.sanitizedName(rawName) else { return false }
        let url = parent.url.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = String(format: String(localized: "A category named “%@” already exists."), name)
            return false
        }
        return perform {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            expanded.insert(parent.id)
            selectedCategoryID = url.standardizedFileURL.path
        }
    }

    @discardableResult
    func renameCategory(_ node: CategoryNode, to rawName: String) -> Bool {
        guard let name = Self.sanitizedName(rawName), name != node.name else { return false }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path),
           destination.path.lowercased() != node.url.path.lowercased() {
            errorMessage = String(format: String(localized: "A category named “%@” already exists."), name)
            return false
        }
        return perform {
            try FileManager.default.moveItem(at: node.url, to: destination)
            remapPaths(from: node.id, to: destination.standardizedFileURL.path)
        }
    }

    /// Moves the category folder (with everything inside) to the Trash.
    func trashCategory(_ node: CategoryNode) {
        guard !node.isCollection else { return }
        perform {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if let selected = selectedCategoryID, selected == node.id || selected.hasPrefix(node.id + "/") {
                selectedCategoryID = node.url.deletingLastPathComponent().standardizedFileURL.path
            }
            if let selection, selection.hasPrefix(node.id + "/") { self.selection = nil }
        }
    }

    // MARK: - Models

    /// Handles files and folders dropped onto a category (or the collection root).
    /// Items from inside a collection are moved, items from elsewhere are copied.
    @discardableResult
    func receive(_ urls: [URL], into folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        let items = urls.map(\.standardizedFileURL).filter { url in
            if isDirectory(url) { return true }
            return ModelFileFormat.isSupported(url)
        }
        guard !items.isEmpty else { return false }
        var moved: [URL] = []
        var copiedModels: [URL] = []
        let ok = perform {
            for url in items {
                if url.deletingLastPathComponent().path == folder.path { continue }
                if isDirectory(url) {
                    // Refuse to move a folder into itself or a collection root anywhere.
                    if folder.path == url.path || folder.path.hasPrefix(url.path + "/") { continue }
                    if collections.contains(where: { $0.path == url.path }) { continue }
                }
                let destination = Self.uniqueDestination(for: url.lastPathComponent, in: folder)
                let isMove = collectionRoot(containing: url) != nil
                try Self.transferMaterialLibraries(of: url, to: folder, move: isMove)
                if isMove {
                    try FileManager.default.moveItem(at: url, to: destination)
                    if isDirectory(destination) {
                        remapPaths(from: url.path, to: destination.path)
                    } else if selection == url.path {
                        pendingSelection = destination.path
                    }
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                    if !isDirectory(destination) { copiedModels.append(destination) }
                }
                moved.append(destination)
            }
        }
        // Newly imported models get selected (they land in the category being viewed).
        if let last = copiedModels.last, pendingSelection == nil {
            pendingSelection = last.standardizedFileURL.path
        }
        return ok && !moved.isEmpty
    }

    func move(_ file: ModelFileItem, to category: CategoryNode) {
        receive([file.url], into: category.url)
    }

    func trash(_ file: ModelFileItem) {
        perform {
            // The OBJ's own material library ("Model.mtl" next to "Model.obj") goes with it.
            let ownLibraries = Self.materialLibraries(of: file.url).filter {
                $0.deletingPathExtension().lastPathComponent == file.url.deletingPathExtension().lastPathComponent
            }
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            for library in ownLibraries { try? FileManager.default.trashItem(at: library, resultingItemURL: nil) }
            if selection == file.id { selection = nil }
        }
    }

    /// Drop on the window: folders become collections, .3mf files are imported into the current category.
    @discardableResult
    func importDropped(_ urls: [URL]) -> Bool {
        let folders = urls.filter { isDirectory($0) && collectionRoot(containing: $0) == nil }
        folders.forEach { addCollection($0) }
        let models = urls.filter { ModelFileFormat.isSupported($0) && !isDirectory($0) }
        if !models.isEmpty {
            let external = models.filter { collectionRoot(containing: $0) == nil }
            if external.isEmpty {
                select(file: models[0])
            } else if let target = importTarget {
                receive(external, into: target.url)
            } else {
                addCollection(external[0].deletingLastPathComponent())
                pendingSelection = external[0].standardizedFileURL.path
            }
        }
        return !folders.isEmpty || !models.isEmpty
    }

    /// Files / folders opened from Finder ("Open With", Dock icon).
    func open(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) {
            if isDirectory(url) {
                addCollection(url)
            } else if ModelFileFormat.isSupported(url) {
                if collectionRoot(containing: url) != nil {
                    select(file: url)
                } else {
                    pendingSelection = url.path
                    addCollection(url.deletingLastPathComponent())
                }
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Scanning

    func refresh() {
        scanTask?.cancel()
        isScanning = true
        let roots = collections
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LibraryModel.scan(roots: roots)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: (tree: [CategoryNode], files: [ModelFileItem])) {
        tree = result.tree
        files = result.files
        var index: [String: CategoryNode] = [:]
        func add(_ nodes: [CategoryNode]) {
            for node in nodes {
                index[node.id] = node
                add(node.children)
            }
        }
        add(tree)
        nodeIndex = index
        isScanning = false
        didScanOnce = true

        if let selected = selectedCategoryID, selected != Self.allModelsID, index[selected] == nil {
            selectedCategoryID = Self.allModelsID
        }
        if let pending = pendingSelection, files.contains(where: { $0.id == pending }) {
            selection = pending
        }
        pendingSelection = nil
        if let selected = selection, !files.contains(where: { $0.id == selected }) {
            selection = nil
        }
        loadSliceSummaries()
    }

    // MARK: - Slicing summaries

    func sliceSummary(for file: ModelFileItem) -> SliceSummary? {
        summaryKeys[file.id] == file.cacheKey ? sliceSummaries[file.id] : nil
    }

    /// Reads `slice_info.config` of new or changed files in the background, in small batches.
    private func loadSliceSummaries() {
        let pending = files.filter { summaryKeys[$0.id] != $0.cacheKey }
        guard !pending.isEmpty else { return }
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            let batchSize = 32
            for start in stride(from: 0, to: pending.count, by: batchSize) {
                let batch = Array(pending[start ..< min(start + batchSize, pending.count)])
                let results = await Task.detached(priority: .utility) {
                    batch.map { (id: $0.id, key: $0.cacheKey, summary: ThreeMFReader.sliceSummary(url: $0.url)) }
                }.value
                guard let self, !Task.isCancelled else { return }
                var summaries = self.sliceSummaries
                for result in results {
                    self.summaryKeys[result.id] = result.key
                    summaries[result.id] = result.summary
                }
                self.sliceSummaries = summaries
            }
        }
    }

    nonisolated static func scan(roots: [URL]) -> (tree: [CategoryNode], files: [ModelFileItem]) {
        var allFiles: [ModelFileItem] = []
        var nodes: [CategoryNode] = []
        for root in roots {
            var collectionFiles: [ModelFileItem] = []
            if let node = scanFolder(root, collection: root, isCollection: true, depth: 0, files: &collectionFiles) {
                nodes.append(node)
            } else {
                nodes.append(CategoryNode(url: root, name: FileManager.default.displayName(atPath: root.path),
                                          isCollection: true, isAvailable: false, children: [], modelCount: 0))
            }
            allFiles += collectionFiles
        }
        return (nodes, allFiles)
    }

    private nonisolated static func scanFolder(_ folder: URL, collection: URL, isCollection: Bool, depth: Int,
                                               files: inout [ModelFileItem]) -> CategoryNode? {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) else { return nil }
        var children: [CategoryNode] = []
        var count = 0
        let collectionPath = collection.path
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if values.isPackage == true || values.isSymbolicLink == true || depth >= 16 { continue }
                if let child = scanFolder(item, collection: collection, isCollection: false, depth: depth + 1, files: &files) {
                    children.append(child)
                    count += child.modelCount
                }
            } else if values.isRegularFile == true, ModelFileFormat.isSupported(item) {
                let url = item.standardizedFileURL
                let parent = url.deletingLastPathComponent().path
                var relative = parent.hasPrefix(collectionPath) ? String(parent.dropFirst(collectionPath.count)) : ""
                while relative.hasPrefix("/") { relative.removeFirst() }
                files.append(ModelFileItem(url: url,
                                           size: Int64(values.fileSize ?? 0),
                                           modified: values.contentModificationDate ?? .distantPast,
                                           collectionPath: collectionPath,
                                           relativeFolder: relative))
                count += 1
            }
        }
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let url = folder.standardizedFileURL
        return CategoryNode(url: url,
                            name: isCollection ? fileManager.displayName(atPath: url.path) : url.lastPathComponent,
                            isCollection: isCollection,
                            isAvailable: true,
                            children: children,
                            modelCount: count)
    }

    // MARK: - Helpers

    /// Runs file operations, reports the first error, rescans afterwards.
    @discardableResult
    private func perform(_ body: () throws -> Void) -> Bool {
        defer { refresh() }
        do {
            try body()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func select(file url: URL) {
        let path = url.standardizedFileURL.path
        if let category = selectedCategory, !path.hasPrefix(category.id + "/") {
            selectedCategoryID = Self.allModelsID
        }
        if files.contains(where: { $0.id == path }) {
            selection = path
        } else {
            pendingSelection = path
            refresh()
        }
    }

    private func reveal(folder: URL, in collection: URL) {
        var current = folder.deletingLastPathComponent()
        while current.path.hasPrefix(collection.path) {
            expanded.insert(current.path)
            if current.path == collection.path { break }
            current = current.deletingLastPathComponent()
        }
        selectedCategoryID = folder.path
    }

    /// Keeps selection / expanded state when a folder moves or is renamed.
    private func remapPaths(from old: String, to new: String) {
        func remap(_ path: String) -> String {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + String(path.dropFirst(old.count)) }
            return path
        }
        if let index = collections.firstIndex(where: { $0.path == old }) {
            collections[index] = URL(fileURLWithPath: new, isDirectory: true)
            saveCollections()
            startWatching()
        }
        expanded = Set(expanded.map(remap))
        if let selected = selectedCategoryID { selectedCategoryID = remap(selected) }
        if let selection { pendingSelection = remap(selection) }
    }

    private func collectionRoot(containing url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return collections.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    private func saveCollections() {
        defaults.set(collections.map(\.path), forKey: Keys.collections)
    }

    private func startWatching() {
        watcher = FolderWatcher(paths: collections.map(\.path)) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func isDirectory(_ url: URL) -> Bool { Self.isDirectory(url) }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Trims the name and replaces characters that are not allowed in folder names.
    static func sanitizedName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// "Model.3mf" → "Model 2.3mf" (or "Folder 2") when the name is taken.
    /// Material libraries (`mtllib`) an OBJ file refers to, if they exist next to it.
    nonisolated static func materialLibraries(of url: URL) -> [URL] {
        guard ModelFileFormat(url: url) == .obj,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        // `mtllib` is normally among the first lines.
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return [] }
        let folder = url.deletingLastPathComponent()
        var result: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("mtllib ") || trimmed.hasPrefix("mtllib\t") else { continue }
            let argument = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let candidates = [argument] + argument.split(separator: " ").map(String.init)
            for name in candidates where !name.contains("/") {
                let file = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path), !result.contains(file) {
                    result.append(file)
                    break
                }
            }
        }
        return result
    }

    /// Keeps an OBJ's colours when it is moved or copied: its own "Model.mtl" moves with it,
    /// shared material libraries are copied. Existing files at the destination are left alone.
    nonisolated static func transferMaterialLibraries(of url: URL, to folder: URL, move: Bool) throws {
        for library in materialLibraries(of: url) {
            let destination = folder.appendingPathComponent(library.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            let isOwn = library.deletingPathExtension().lastPathComponent == url.deletingPathExtension().lastPathComponent
            if move && isOwn {
                try FileManager.default.moveItem(at: library, to: destination)
            } else {
                try FileManager.default.copyItem(at: library, to: destination)
            }
        }
    }

    nonisolated static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            number += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Watches whole folder trees (FSEvents) and calls `onChange` when anything inside changes.
final class FolderWatcher {
    private final class Handler {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) { self.callback = callback }
    }

    private var stream: FSEventStreamRef?

    init?(paths: [String], onChange: @escaping () -> Void) {
        guard !paths.isEmpty else { return nil }
        let handler = Unmanaged.passRetained(Handler(onChange))
        var context = FSEventStreamContext(version: 0,
                                           info: handler.toOpaque(),
                                           retain: nil,
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<Handler>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().callback()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else {
            handler.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
