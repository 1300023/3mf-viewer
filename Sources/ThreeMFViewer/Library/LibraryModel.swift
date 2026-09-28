import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary

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

extension FileSortOrder {
    var title: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .printTime: return "Print Time"
        }
    }
}

/// State of the library window: collections, the selected category and model, search and sorting.
///
/// Each collection is a folder; its subfolders are categories and subcategories. The actual work is done by
/// `ThreeMFLibrary`: `LibraryScanner` reads the folders, `LibraryFileService` changes them, `LibraryQuery`
/// filters and sorts. Changes made in Finder show up here through `FolderWatcher`.
@MainActor
final class LibraryModel: ObservableObject {
    static let allModelsID = "::all-models"

    @Published private(set) var collections: [URL] = [] {
        didSet {
            preferences.collections = collections
            startWatching()
        }
    }
    @Published private(set) var snapshot = LibrarySnapshot.empty
    @Published private(set) var isScanning = false
    @Published private(set) var didScanOnce = false

    /// Selected sidebar row: a category/collection path or `allModelsID`.
    @Published var selectedCategoryID: String? = LibraryModel.allModelsID {
        didSet {
            preferences.selectedCategory = selectedCategoryID
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
        didSet { preferences.sortOrder = sortOrder }
    }
    @Published private(set) var expanded: Set<String> {
        didSet { preferences.expandedCategories = expanded }
    }
    /// Print time and weight of sliced projects, read in the background after each scan.
    @Published private(set) var sliceSummaries = SliceSummaryStore()
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

    private let preferences: LibraryPreferences
    private let fileService: LibraryFileService
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    /// Selected once the next scan finds it (a file that was just moved, copied or opened).
    private var pendingSelection: String?
    private var watcher: FolderWatcher?

    init(preferences: LibraryPreferences = LibraryPreferences(), fileService: LibraryFileService = LibraryFileService()) {
        self.preferences = preferences
        self.fileService = fileService
        sortOrder = preferences.sortOrder
        expanded = preferences.expandedCategories
        selectedCategoryID = preferences.selectedCategory ?? Self.allModelsID

        var collections = preferences.collections
        if collections.isEmpty, let legacy = preferences.legacyFolder {
            // Migrate from the single-folder version.
            collections = [legacy]
            expanded.insert(legacy.path)
        }
        self.collections = collections
        preferences.collections = collections
        startWatching()
        refresh()
    }

    // MARK: - Derived data

    var tree: [CategoryNode] { snapshot.tree }
    var files: [ModelFileItem] { snapshot.files }
    var totalModelCount: Int { files.count }

    /// Rows of the sidebar tree, honouring the expanded state.
    var sidebarRows: [SidebarRow] { CategoryTree.visibleRows(tree, expanded: expanded) }

    var selectedCategory: CategoryNode? {
        selectedCategoryID.flatMap { snapshot.index[$0] }
    }

    /// Models of the selected category (including its subcategories), filtered and sorted.
    var visibleFiles: [ModelFileItem] {
        LibraryQuery(category: selectedCategory, searchText: searchText, sortOrder: sortOrder)
            .apply(to: files) { [sliceSummaries] in sliceSummaries.summary(for: $0)?.printTime }
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

    func sliceSummary(for file: ModelFileItem) -> SliceSummary? {
        sliceSummaries.summary(for: file)
    }

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
        var updated = collections.filter { !LibraryPaths.isSameOrInside($0.path, url.path) }
        updated.append(url)
        collections = updated
        expanded.insert(url.path)
        selectedCategoryID = url.path
        refresh()
    }

    func removeCollection(_ node: CategoryNode) {
        guard node.isCollection else { return }
        collections.removeAll { $0.path == node.id }
        forget(node)
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

    func createCategory(named name: String, in parent: CategoryNode) {
        guard LibraryFileService.sanitizedName(name) != nil else { return }  // empty prompt: nothing to do
        perform {
            let url = try fileService.createCategory(named: name, in: parent.url)
            expanded.insert(parent.id)
            selectedCategoryID = url.path
        }
    }

    func renameCategory(_ node: CategoryNode, to name: String) {
        guard LibraryFileService.sanitizedName(name) != nil else { return }
        perform {
            let url = try fileService.renameCategory(at: node.url, to: name)
            if url.path != node.id { remapPaths(from: node.id, to: url.path) }
        }
    }

    /// Moves the category folder (with everything inside) to the Trash.
    func trashCategory(_ node: CategoryNode) {
        guard !node.isCollection else { return }
        perform {
            try fileService.trash(node.url)
            forget(node)
        }
    }

    // MARK: - Models

    /// Handles files and folders dropped onto a category (or the collection root).
    /// Items from inside a collection are moved, items from elsewhere are copied.
    @discardableResult
    func receive(_ urls: [URL], into folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        let items = urls.map(\.standardizedFileURL).filter(canReceive(into: folder))
        guard !items.isEmpty else { return false }
        var importedModel: URL?
        let ok = perform {
            for url in items {
                let isMove = collectionRoot(containing: url) != nil
                let destination = try fileService.transfer(url, into: folder, move: isMove)
                if fileService.isDirectory(destination) {
                    if isMove { remapPaths(from: url.path, to: destination.path) }
                } else if !isMove {
                    importedModel = destination
                } else if selection == url.path {
                    pendingSelection = destination.path
                }
            }
        }
        // A newly imported model gets selected (it lands in the category being viewed).
        if let importedModel, pendingSelection == nil {
            pendingSelection = importedModel.path
        }
        return ok
    }

    /// Model files and folders, except those already in `folder`, a folder into itself and collection roots.
    private func canReceive(into folder: URL) -> (URL) -> Bool {
        { [collections, fileService] url in
            if url.deletingLastPathComponent().path == folder.path { return false }
            guard fileService.isDirectory(url) else { return ModelFileFormat.isSupported(url) }
            if LibraryPaths.isSameOrInside(folder.path, url.path) { return false }
            return !collections.contains { $0.path == url.path }
        }
    }

    func move(_ file: ModelFileItem, to category: CategoryNode) {
        receive([file.url], into: category.url)
    }

    func trash(_ file: ModelFileItem) {
        perform {
            try fileService.trashModel(file.url)
            if selection == file.id { selection = nil }
        }
    }

    /// Drop on the window: folders become collections, model files are imported into the current category.
    @discardableResult
    func importDropped(_ urls: [URL]) -> Bool {
        let folders = urls.filter { fileService.isDirectory($0) && collectionRoot(containing: $0) == nil }
        folders.forEach { addCollection($0) }
        let models = urls.filter { ModelFileFormat.isSupported($0) && !fileService.isDirectory($0) }
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
            if fileService.isDirectory(url) {
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
            let snapshot = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(roots: roots)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
        isScanning = false
        didScanOnce = true

        if let selected = selectedCategoryID, selected != Self.allModelsID, snapshot.index[selected] == nil {
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

    /// Reads `slice_info.config` of new or changed files in the background, in small batches.
    private func loadSliceSummaries() {
        let pending = sliceSummaries.filesNeedingUpdate(files)
        guard !pending.isEmpty else { return }
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            let batchSize = 32
            for start in stride(from: 0, to: pending.count, by: batchSize) {
                let batch = Array(pending[start ..< min(start + batchSize, pending.count)])
                let entries = await Task.detached(priority: .utility) { SliceSummaryStore.read(batch) }.value
                guard let self, !Task.isCancelled else { return }
                self.sliceSummaries.store(entries)
            }
        }
    }

    // MARK: - Helpers

    /// Runs file operations, reports the error if one is thrown, rescans afterwards.
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
        if let category = selectedCategory, !category.contains(path: path) {
            selectedCategoryID = Self.allModelsID
        }
        if files.contains(where: { $0.id == path }) {
            selection = path
        } else {
            pendingSelection = path
            refresh()
        }
    }

    /// Expands the parents of `folder` and selects it.
    private func reveal(folder: URL, in collection: URL) {
        var current = folder.deletingLastPathComponent()
        while current.path.hasPrefix(collection.path) {
            expanded.insert(current.path)
            if current.path == collection.path { break }
            current = current.deletingLastPathComponent()
        }
        selectedCategoryID = folder.path
    }

    /// Drops the selection when it pointed into a folder that is gone from the library.
    private func forget(_ node: CategoryNode) {
        if let selected = selectedCategoryID, node.contains(path: selected) {
            selectedCategoryID = node.isCollection ? Self.allModelsID : node.url.deletingLastPathComponent().path
        }
        if let selection, node.contains(path: selection) { self.selection = nil }
    }

    /// Keeps collections, selection and expanded state when a folder moves or is renamed.
    private func remapPaths(from old: String, to new: String) {
        func remap(_ path: String) -> String { LibraryPaths.remap(path, from: old, to: new) }
        if let index = collections.firstIndex(where: { $0.path == old }) {
            collections[index] = URL(fileURLWithPath: new, isDirectory: true)
        }
        expanded = Set(expanded.map(remap))
        if let selected = selectedCategoryID { selectedCategoryID = remap(selected) }
        if let selection { pendingSelection = remap(selection) }
    }

    private func collectionRoot(containing url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return collections.first { LibraryPaths.isSameOrInside(path, $0.path) }
    }

    private func startWatching() {
        watcher = FolderWatcher(paths: collections.map(\.path)) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// FSEvents arrive in bursts: wait until they settle before rescanning.
    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
