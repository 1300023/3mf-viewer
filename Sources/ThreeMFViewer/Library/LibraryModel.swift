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
    static let inboxID = "::inbox"
    static let favoritesID = "::favorites"
    static let printedID = "::printed"
    static let tagPrefix = "::tag:"
    static func tagID(_ tag: String) -> String { tagPrefix + tag }
    /// Sidebar rows that are not folders.
    static func isSpecial(_ id: String) -> Bool { id.hasPrefix("::") }

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
    /// Titles, descriptions, filaments, colours and sizes, read in the background and cached on disk.
    /// (Updated from `LibraryModel+Organize.swift`.)
    @Published var modelDetails = ModelDetailsStore()
    /// Filters of the model list.
    @Published var filters = LibraryFilters()
    /// Model details are still being read (filters may not show every match yet).
    @Published var isReadingDetails = false

    /// Model files in the inbox folder (new downloads).
    @Published private(set) var inboxFiles: [ModelFileItem] = []
    @Published var isInboxEnabled: Bool {
        didSet {
            preferences.isInboxEnabled = isInboxEnabled
            if !isInboxEnabled, selectedCategoryID == Self.inboxID { selectedCategoryID = Self.allModelsID }
            startWatching()
            refresh()
        }
    }
    @Published var inboxFolder: URL? {
        didSet {
            preferences.inboxFolder = inboxFolder
            startWatching()
            refresh()
        }
    }
    /// The printer's build volume for "fits the printer".
    @Published var buildVolume: BuildVolume {
        didSet { preferences.buildVolume = buildVolume }
    }
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
    /// The "Find Duplicates" sheet.
    @Published var isShowingDuplicates = false

    private let preferences: LibraryPreferences
    private let fileService: LibraryFileService
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    var detailsTask: Task<Void, Never>?
    let detailsCacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ThreeMFViewer", isDirectory: true)
        .appendingPathComponent("model-details.json")
    /// Selected once the next scan finds it (a file that was just moved, copied or opened).
    private var pendingSelection: String?
    private var watcher: FolderWatcher?

    init(preferences: LibraryPreferences = LibraryPreferences(), fileService: LibraryFileService = LibraryFileService()) {
        self.preferences = preferences
        self.fileService = fileService
        sortOrder = preferences.sortOrder
        expanded = preferences.expandedCategories
        isInboxEnabled = preferences.isInboxEnabled
        _inboxFolder = Published(initialValue: preferences.inboxFolder)
        buildVolume = preferences.buildVolume
        if let detailsCacheURL { modelDetails = ModelDetailsStore.load(from: detailsCacheURL) }
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

    /// Models of the selected row (a category with its subcategories, the inbox, favourites, a tag…),
    /// searched, filtered and sorted.
    var visibleFiles: [ModelFileItem] {
        var category: CategoryNode?
        let base: [ModelFileItem]
        switch selectedCategoryID {
        case Self.inboxID?:
            base = inboxFiles
        case Self.favoritesID?:
            base = allFiles.filter(\.isFavorite)
        case Self.printedID?:
            base = allFiles.filter(\.isPrinted)
        case let id? where id.hasPrefix(Self.tagPrefix):
            let tag = String(id.dropFirst(Self.tagPrefix.count))
            base = allFiles.filter { $0.tags.contains(tag) }
        default:
            base = files
            category = selectedCategory
        }
        return LibraryQuery(category: category, searchText: searchText, sortOrder: sortOrder, filters: filters)
            .apply(to: base) { facts(for: $0) }
    }

    /// Library models plus the inbox models that are not inside a collection.
    var allFiles: [ModelFileItem] {
        guard !inboxFiles.isEmpty else { return files }
        let known = Set(files.map(\.id))
        return files + inboxFiles.filter { !known.contains($0.id) }
    }

    var selectedFile: ModelFileItem? {
        guard let selection else { return nil }
        return files.first { $0.id == selection } ?? inboxFiles.first { $0.id == selection }
    }

    /// The folder new models go to: the selected category, or the first collection.
    var importTarget: CategoryNode? {
        if let category = selectedCategory, category.isAvailable { return category }
        return tree.first { $0.isAvailable }
    }

    /// Shows changed Finder tags right away, without waiting for a rescan of every collection.
    func applyTagsLocally(_ tags: [String], to id: String) {
        if let index = snapshot.files.firstIndex(where: { $0.id == id }) {
            var files = snapshot.files
            files[index] = files[index].withTags(tags)
            snapshot = LibrarySnapshot(tree: snapshot.tree, files: files)
        }
        if let index = inboxFiles.firstIndex(where: { $0.id == id }) {
            inboxFiles[index] = inboxFiles[index].withTags(tags)
        }
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
                // Files are moved out of collections and out of the inbox, and copied from anywhere else.
                let isMove = collectionRoot(containing: url) != nil || isInInbox(url)
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
        trash([file])
    }

    /// Moves models to the Trash; stops at the first file that cannot be moved.
    @discardableResult
    func trash(_ files: [ModelFileItem]) -> Bool {
        perform {
            for file in files {
                try fileService.trashModel(file.url)
                if selection == file.id { selection = nil }
            }
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
        let inbox = isInboxEnabled ? inboxFolder : nil
        scanTask = Task { [weak self] in
            let (snapshot, inboxFiles) = await Task.detached(priority: .userInitiated) {
                (LibraryScanner.scan(roots: roots), inbox.map { LibraryScanner.scanInbox($0) } ?? [])
            }.value
            guard let self, !Task.isCancelled else { return }
            self.inboxFiles = inboxFiles
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
        isScanning = false
        didScanOnce = true

        if let selected = selectedCategoryID, !Self.isSpecial(selected), snapshot.index[selected] == nil {
            selectedCategoryID = Self.allModelsID
        }
        if selectedCategoryID == Self.inboxID, !isInboxEnabled {
            selectedCategoryID = Self.allModelsID
        }
        let known = Set((files + inboxFiles).map(\.id))
        if let pending = pendingSelection, known.contains(pending) {
            selection = pending
        }
        pendingSelection = nil
        if let selected = selection, !known.contains(selected) {
            selection = nil
        }
        loadSliceSummaries()
        loadModelDetails()
    }

    /// Reads `slice_info.config` of new or changed files in the background, in small batches.
    private func loadSliceSummaries() {
        let pending = sliceSummaries.filesNeedingUpdate(files + inboxFiles)
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
        var paths = collections.map(\.path)
        if isInboxEnabled, let inboxFolder { paths.append(inboxFolder.path) }
        watcher = FolderWatcher(paths: paths) { [weak self] in
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
