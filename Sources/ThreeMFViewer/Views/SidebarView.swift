import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            if library.folderURL != nil {
                FolderHeader()
                Divider()
            }
            content
        }
        .searchable(text: $library.searchText, placement: .sidebar, prompt: Text("Search models"))
        .navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 560)
    }

    @ViewBuilder
    private var content: some View {
        let files = library.visibleFiles
        if library.folderURL == nil {
            PlaceholderView(systemImage: "folder",
                            title: "No folder",
                            message: String(localized: "Choose a folder with .3mf models."))
        } else if files.isEmpty {
            if library.isScanning {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.searchText.isEmpty {
                PlaceholderView(systemImage: "cube.transparent",
                                title: "No .3mf files",
                                message: String(localized: "This folder doesn't contain any .3mf models."))
            } else {
                PlaceholderView(systemImage: "magnifyingglass", title: "No results")
            }
        } else {
            List(selection: $library.selection) {
                ForEach(files) { file in
                    FileRowView(file: file)
                        .contextMenu { FileContextMenu(url: file.url) }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct FolderHeader: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(library.folderName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if library.isScanning {
                        Text("Scanning…")
                    } else {
                        Text("Files: \(library.files.count)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .help(library.folderURL?.path ?? "")
            Spacer(minLength: 4)
            Menu {
                Button("Choose Folder…") { library.chooseFolder() }
                Button("Refresh") { library.refresh() }
                Button("Show in Finder") { library.revealInFinder() }
                Divider()
                Toggle("Include Subfolders", isOn: $library.includeSubfolders)
                Picker("Sort By", selection: $library.sortOrder) {
                    ForEach(FileSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Folder options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct FileRowView: View {
    let file: ModelFileItem
    @State private var thumbnail: NSImage?
    @State private var didLoad = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(3)
                } else if didLoad {
                    Image(systemName: "cube")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !file.relativeFolder.isEmpty {
                    Label(file.relativeFolder, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 3)
        .task(id: file.cacheKey) {
            if let cached = ThumbnailStore.shared.cachedImage(for: file) {
                thumbnail = cached
                didLoad = true
                return
            }
            let image = await ThumbnailStore.shared.thumbnail(for: file)
            guard !Task.isCancelled else { return }
            thumbnail = image
            didLoad = true
        }
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let date = file.modified.formatted(date: .abbreviated, time: .omitted)
        return "\(size) · \(date)"
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
