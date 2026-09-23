import AppKit
import SwiftUI

struct ModelFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date
    /// Folder relative to the library root ("" for files directly in it).
    let relativeFolder: String

    var id: String { url.path }

    var displayName: String {
        let name = url.lastPathComponent
        return name.lowercased().hasSuffix(".3mf") ? String(name.dropLast(4)) : name
    }

    /// Changes whenever the file changes — used for thumbnail caching.
    var cacheKey: String { "\(url.path)|\(size)|\(Int(modified.timeIntervalSince1970))" }
}

enum FileSortOrder: String, CaseIterable, Identifiable {
    case name, modified, size

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        }
    }
}

/// The list of .3mf files in the chosen folder.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var folderURL: URL?
    @Published private(set) var files: [ModelFileItem] = []
    @Published private(set) var isScanning = false
    @Published var selection: ModelFileItem.ID?
    @Published var searchText = ""
    @Published var sortOrder: FileSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Keys.sortOrder) }
    }
    @Published var includeSubfolders: Bool {
        didSet {
            defaults.set(includeSubfolders, forKey: Keys.includeSubfolders)
            refresh()
        }
    }

    private enum Keys {
        static let folder = "library.folderPath"
        static let sortOrder = "library.sortOrder"
        static let includeSubfolders = "library.includeSubfolders"
    }

    private let defaults = UserDefaults.standard
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingSelection: String?
    private var watcher: FolderWatcher?

    init() {
        let stored = UserDefaults.standard
        sortOrder = FileSortOrder(rawValue: stored.string(forKey: Keys.sortOrder) ?? "") ?? .name
        includeSubfolders = stored.object(forKey: Keys.includeSubfolders) as? Bool ?? true
        if let path = stored.string(forKey: Keys.folder), Self.isDirectory(URL(fileURLWithPath: path)) {
            setFolder(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    // MARK: - Derived data

    var visibleFiles: [ModelFileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? files : files.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || $0.relativeFolder.localizedCaseInsensitiveContains(query)
        }
        switch sortOrder {
        case .name:
            return filtered.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .modified:
            return filtered.sorted { $0.modified > $1.modified }
        case .size:
            return filtered.sorted { $0.size > $1.size }
        }
    }

    var selectedFile: ModelFileItem? {
        guard let selection else { return nil }
        return files.first { $0.id == selection }
    }

    var folderName: String {
        folderURL.map { FileManager.default.displayName(atPath: $0.path) } ?? ""
    }

    // MARK: - Actions

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder with .3mf models")
        if let folderURL { panel.directoryURL = folderURL }
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url)
        }
    }

    /// Opens a folder, or a .3mf file (its folder is opened and the file selected).
    func open(_ urls: [URL]) {
        guard let url = urls.first?.standardizedFileURL else { return }
        if Self.isDirectory(url) {
            setFolder(url)
            return
        }
        guard url.pathExtension.lowercased() == "3mf",
              FileManager.default.fileExists(atPath: url.path) else { return }
        if files.contains(where: { $0.id == url.path }) {
            selection = url.path
        } else {
            pendingSelection = url.path
            setFolder(url.deletingLastPathComponent())
        }
    }

    func setFolder(_ url: URL) {
        let url = url.standardizedFileURL
        folderURL = url
        defaults.set(url.path, forKey: Keys.folder)
        selection = nil
        files = []
        watcher = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
    }

    func refresh() {
        guard let folder = folderURL else { return }
        scanTask?.cancel()
        isScanning = true
        let recursive = includeSubfolders
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LibraryModel.scan(folder: folder, recursive: recursive)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.files = result
            self.isScanning = false
            if let pending = self.pendingSelection, result.contains(where: { $0.id == pending }) {
                self.selection = pending
            }
            self.pendingSelection = nil
            if let selected = self.selection, !result.contains(where: { $0.id == selected }) {
                self.selection = nil
            }
        }
    }

    func revealInFinder() {
        guard let folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: - Scanning

    nonisolated static func scan(folder: URL, recursive: Bool) -> [ModelFileItem] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var urls: [URL] = []

        if recursive {
            if let enumerator = fileManager.enumerator(at: folder,
                                                       includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                while let url = enumerator.nextObject() as? URL {
                    if url.pathExtension.lowercased() == "3mf" { urls.append(url) }
                }
            }
        } else {
            urls = ((try? fileManager.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "3mf" }
        }

        let rootPath = folder.standardizedFileURL.path
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                return nil
            }
            let standardized = url.standardizedFileURL
            let parent = standardized.deletingLastPathComponent().path
            var relative = parent.hasPrefix(rootPath) ? String(parent.dropFirst(rootPath.count)) : ""
            while relative.hasPrefix("/") { relative.removeFirst() }
            return ModelFileItem(url: standardized,
                                 size: Int64(values.fileSize ?? 0),
                                 modified: values.contentModificationDate ?? .distantPast,
                                 relativeFolder: relative)
        }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Watches the top level of a folder for added / removed / renamed files.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                           eventMask: [.write, .rename, .delete],
                                                           queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
