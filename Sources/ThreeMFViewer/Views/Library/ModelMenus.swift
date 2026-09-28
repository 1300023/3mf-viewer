import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary

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
