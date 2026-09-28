import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary

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
