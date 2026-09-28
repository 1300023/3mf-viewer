import AppKit
import SwiftUI
import ThreeMFKit

/// Middle column: the models of the selected category (including its subcategories).
struct ModelListView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var isDropTargeted = false
    @AppStorage("library.viewMode") private var viewMode = LibraryViewMode.list
    @AppStorage("library.tileSize") private var tileSize = 150.0

    var body: some View {
        let files = library.visibleFiles
        VStack(spacing: 0) {
            header(count: files.count)
            Divider()
            if files.isEmpty {
                emptyState
            } else if viewMode == .grid {
                ModelGridView(files: files, tileSize: tileSize, showsFolder: showsFolder(of:))
                    .safeAreaInset(edge: .bottom) { tileSizeBar }
            } else {
                List(selection: $library.selection) {
                    ForEach(files) { file in
                        FileRowView(file: file,
                                    showsFolder: showsFolder(of: file),
                                    printTime: library.sliceSummary(for: file)?.printTime)
                            .tag(file.id as String?)
                            .draggable(file.url)
                            .contextMenu { ModelContextMenu(file: file) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $library.searchText, prompt: Text("Search models"))
        .dropDestination(for: URL.self) { urls, _ in
            guard let target = library.importTarget else { return false }
            return library.receive(urls, into: target.url)
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Models: \(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Picker("View", selection: $viewMode) {
                Image(systemName: "list.bullet").help("List").tag(LibraryViewMode.list)
                Image(systemName: "square.grid.2x2").help("Gallery").tag(LibraryViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("List or gallery")
            Menu {
                Picker("Sort By", selection: $library.sortOrder) {
                    ForEach(FileSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
                if let category = library.selectedCategory {
                    Divider()
                    Button("Show in Finder") { library.revealInFinder(category.url) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort By")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Thumbnail size slider under the gallery.
    private var tileSizeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $tileSize, in: 90 ... 260)
                .controlSize(.small)
                .frame(maxWidth: 180)
                .help("Thumbnail size")
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var title: String {
        library.selectedCategory?.name ?? String(localized: "All Models")
    }

    /// The row shows the category path when models from several folders are listed.
    private func showsFolder(of file: ModelFileItem) -> Bool {
        guard let category = library.selectedCategory else { return true }
        return file.folderPath != category.id
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.didScanOnce || library.isScanning && library.files.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !library.searchText.isEmpty {
            PlaceholderView(systemImage: "magnifyingglass", title: "No results")
        } else {
            PlaceholderView(systemImage: "tray",
                            title: "This category is empty",
                            message: String(localized: "Drag model files here from Finder or from another category."))
        }
    }
}

/// Context menu of a model: open / move / trash.
struct ModelContextMenu: View {
    @EnvironmentObject private var library: LibraryModel
    let file: ModelFileItem

    var body: some View {
        FileContextMenu(url: file.url)
        Divider()
        Menu("Move to") {
            MoveTargetsMenu(nodes: library.tree.filter(\.isAvailable), currentFolder: file.folderPath) { node in
                library.move(file, to: node)
            }
        }
        Button("Move to Trash") { library.trash(file) }
    }
}

/// Nested menu that mirrors the category tree.
struct MoveTargetsMenu: View {
    let nodes: [CategoryNode]
    let currentFolder: String
    let action: (CategoryNode) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                Button(node.name) { action(node) }
                    .disabled(node.id == currentFolder)
            } else {
                Menu(node.name) {
                    Button(node.name) { action(node) }
                        .disabled(node.id == currentFolder)
                    Divider()
                    MoveTargetsMenu(nodes: node.children, currentFolder: currentFolder, action: action)
                }
            }
        }
    }
}

struct FileRowView: View {
    let file: ModelFileItem
    var showsFolder = true
    /// Estimated print time of a sliced project.
    var printTime: TimeInterval?
    var body: some View {
        HStack(spacing: 10) {
            ModelThumbnail(file: file, cornerRadius: 8)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(details)
                        .lineLimit(1)
                    if let printTime {
                        Label(PrintFormat.duration(printTime), systemImage: "clock")
                            .labelStyle(CompactLabelStyle())
                            .lineLimit(1)
                            .help("Print time")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showsFolder, !file.relativeFolder.isEmpty {
                    Label(file.relativeFolder, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let date = file.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: AppLanguage.locale))
        return "\(size) · \(date)"
    }
}

/// Icon and title close together (the default label style spaces them widely).
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// Context menu shared by the file list and the detail toolbar.
struct FileContextMenu: View {
    let url: URL

    var body: some View {
        Button("Open in Default App") { NSWorkspace.shared.open(url) }
        OpenWithMenu(url: url)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

struct OpenWithMenu: View {
    let url: URL

    var body: some View {
        Menu("Open With") {
            let apps = Self.applications(for: url)
            if apps.isEmpty {
                Text("No applications found")
            } else {
                ForEach(apps, id: \.self) { app in
                    Button {
                        NSWorkspace.shared.open([url], withApplicationAt: app,
                                                configuration: NSWorkspace.OpenConfiguration(),
                                                completionHandler: nil)
                    } label: {
                        Label {
                            Text(Self.name(of: app))
                        } icon: {
                            Image(nsImage: Self.icon(of: app))
                        }
                    }
                }
            }
        }
    }

    static func applications(for url: URL) -> [URL] {
        let own = Bundle.main.bundleURL.standardizedFileURL
        return NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { $0.standardizedFileURL != own }
    }

    static func name(of app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(of app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
