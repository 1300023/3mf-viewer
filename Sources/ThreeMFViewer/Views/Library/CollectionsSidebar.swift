import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary

/// Left column: collections and their category tree (= folders on disk).
struct CollectionsSidebar: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var trashCandidate: CategoryNode?
    @State private var dropTargetID: String?

    var body: some View {
        Group {
            if library.collections.isEmpty {
                PlaceholderView(systemImage: "square.stack.3d.up",
                                title: "No collections",
                                message: String(localized: "Add a folder with 3D models (.3mf, .stl, .obj) as a collection. Its subfolders become categories."))
            } else {
                List(selection: $library.selectedCategoryID) {
                    // Every row comes from a ForEach whose id is the selection value, like the category rows:
                    // static rows with only a `.tag` could not be selected.
                    Section {
                        ForEach(shortcutRows) { item in
                            shortcutRow(item)
                        }
                    }
                    let tagRows = self.tagRows
                    if !tagRows.isEmpty {
                        Section("Tags") {
                            ForEach(tagRows) { item in
                                shortcutRow(item)
                            }
                        }
                    }
                    Section("Collections") {
                        ForEach(library.sidebarRows) { row in
                            CategoryRowView(row: row,
                                            isExpanded: library.isExpanded(row.node),
                                            isDropTarget: dropTargetID == row.id,
                                            toggle: { library.toggleExpanded(row.node) })
                                .tag(row.id as String?)
                                .contextMenu { contextMenu(for: row.node) }
                                .draggable(row.node.url)
                                .dropDestination(for: URL.self) { urls, _ in
                                    library.receive(urls, into: row.node.url)
                                } isTargeted: { targeted in
                                    if targeted {
                                        dropTargetID = row.id
                                    } else if dropTargetID == row.id {
                                        dropTargetID = nil
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .alert(promptTitle, isPresented: promptBinding) {
            TextField("Category name", text: $library.nameText)
            Button(promptAction) { commitPrompt() }
            Button("Cancel", role: .cancel) { library.namePrompt = nil }
        } message: {
            Text(promptMessage)
        }
        .alert(trashTitle, isPresented: trashBinding) {
            Button("Move to Trash", role: .destructive) {
                if let node = trashCandidate { library.trashCategory(node) }
                trashCandidate = nil
            }
            Button("Cancel", role: .cancel) { trashCandidate = nil }
        } message: {
            Text("The folder and all models inside it will be moved to the Trash.")
        }
    }

    /// A sidebar row that is not a folder: all models, the inbox, favourites, printed, a tag.
    private struct ShortcutRow: Identifiable {
        /// The selection value (`LibraryModel.allModelsID`, `inboxID`, a tag id…).
        let id: String
        let title: String
        let systemImage: String
        let count: Int
        var help: String?
    }

    private var shortcutRows: [ShortcutRow] {
        var rows = [ShortcutRow(id: LibraryModel.allModelsID, title: String(localized: "All Models"),
                                systemImage: "square.grid.2x2", count: library.totalModelCount)]
        if library.isInboxEnabled {
            rows.append(ShortcutRow(id: LibraryModel.inboxID, title: String(localized: "Inbox"),
                                    systemImage: "tray.and.arrow.down", count: library.inboxFiles.count,
                                    help: library.inboxFolder?.path))
        }
        rows.append(ShortcutRow(id: LibraryModel.favoritesID, title: String(localized: "Favorites"),
                                systemImage: "star", count: library.favoritesCount))
        rows.append(ShortcutRow(id: LibraryModel.printedID, title: String(localized: "Printed"),
                                systemImage: "checkmark.seal", count: library.printedCount))
        return rows
    }

    private var tagRows: [ShortcutRow] {
        library.tagCounts.map {
            ShortcutRow(id: LibraryModel.tagID($0.tag), title: $0.tag, systemImage: "tag", count: $0.count)
        }
    }

    private func shortcutRow(_ item: ShortcutRow) -> some View {
        countRow(item.title, systemImage: item.systemImage, count: item.count)
            .help(item.help ?? "")
            // Dropping models on Favorites, Printed or a tag marks them.
            .dropDestination(for: URL.self) { urls, _ in
                markDropped(urls, on: item.id)
            }
            .tag(item.id as String?)
    }

    private func markDropped(_ urls: [URL], on id: String) -> Bool {
        switch id {
        case LibraryModel.favoritesID:
            return library.mark(urls) { library.setFavorite(true, for: $0) }
        case LibraryModel.printedID:
            return library.mark(urls) { library.setPrinted(true, for: $0) }
        case let id where id.hasPrefix(LibraryModel.tagPrefix):
            let tag = String(id.dropFirst(LibraryModel.tagPrefix.count))
            return library.mark(urls) { library.addTag(tag, to: $0) }
        default:
            return false
        }
    }

    private func countRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Add Collection…") { library.addCollection() }
                Button("New Category…") { library.requestNewCategory() }
                    .disabled(library.importTarget == nil)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a collection or a category")

            Spacer()

            if library.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                library.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for node: CategoryNode) -> some View {
        Button("New Subcategory…") { library.namePrompt = .newCategory(parent: node) }
            .disabled(!node.isAvailable)
        if !node.isCollection {
            Button("Rename…") { library.namePrompt = .rename(node) }
        }
        Button("Show in Finder") { library.revealInFinder(node.url) }
            .disabled(!node.isAvailable)
        Divider()
        if node.isCollection {
            Button("Remove Collection from List") { library.removeCollection(node) }
        } else {
            Button("Move to Trash…") { trashCandidate = node }
        }
    }

    // MARK: - Prompts

    private var promptBinding: Binding<Bool> {
        Binding(get: { library.namePrompt != nil }, set: { if !$0 { library.namePrompt = nil } })
    }

    private var promptTitle: LocalizedStringKey {
        switch library.namePrompt {
        case .rename: return "Rename Category"
        default: return "New Category"
        }
    }

    private var promptAction: LocalizedStringKey {
        switch library.namePrompt {
        case .rename: return "Rename"
        default: return "Create"
        }
    }

    private var promptMessage: String {
        switch library.namePrompt {
        case .newCategory(let parent): return String(format: String(localized: "The folder will be created in “%@”."), parent.name)
        default: return ""
        }
    }

    private func commitPrompt() {
        switch library.namePrompt {
        case .newCategory(let parent): library.createCategory(named: library.nameText, in: parent)
        case .rename(let node): library.renameCategory(node, to: library.nameText)
        case nil: break
        }
        library.namePrompt = nil
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } })
    }

    private var trashTitle: String {
        String(format: String(localized: "Move “%@” to the Trash?"), trashCandidate?.name ?? "")
    }
}

private struct CategoryRowView: View {
    let row: SidebarRow
    let isExpanded: Bool
    let isDropTarget: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if row.depth > 0 {
                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            }
            if row.node.children.isEmpty {
                Color.clear.frame(width: 14, height: 1)
            } else {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Label {
                Text(row.node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                // Available folders use the sidebar's default tint (which also turns white when selected).
                if row.node.isAvailable {
                    Image(systemName: icon)
                } else {
                    Image(systemName: icon).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if row.node.modelCount > 0 {
                Text("\(row.node.modelCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .help(row.node.isAvailable ? row.node.url.path : String(localized: "Folder not found"))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-3)
                .opacity(isDropTarget ? 1 : 0)
        )
    }

    private var icon: String {
        if !row.node.isAvailable { return "exclamationmark.triangle" }
        return row.node.isCollection ? "square.stack.3d.up" : "folder"
    }
}
