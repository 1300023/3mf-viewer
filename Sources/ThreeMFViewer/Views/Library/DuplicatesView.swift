import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary

/// Looks for identical model files in all collections and moves the extra copies to the Trash.
struct DuplicatesView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [DuplicateGroup] = []
    @State private var progress = 0.0
    @State private var isSearching = true
    /// Group id → id of the file to keep.
    @State private var keep: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .task { await search() }
        // The window's own alert cannot appear while this sheet is shown.
        .alert("Could not complete the operation", isPresented: errorBinding) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates")
                    .font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            VStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(maxWidth: 280)
                Text("Comparing files…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            PlaceholderView(systemImage: "checkmark.circle",
                            title: "No duplicates",
                            message: String(localized: "Every model file in your collections is unique."))
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(file: file, isKept: keptID(in: group) == file.id) {
                                keep[group.id] = file.id
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.suggestedKeeper.displayName)
                            Spacer()
                            Button("Keep One") { trashExtras(of: [group]) }
                                .buttonStyle(.link)
                                .help("Move the other copies to the Trash")
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if !groups.isEmpty {
                Button("Move All Extra Copies to Trash") { trashExtras(of: groups) }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var summary: String {
        if isSearching { return String(localized: "Looking for identical files…") }
        let copies = groups.reduce(0) { $0 + $1.files.count - 1 }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.redundantBytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "Extra copies: \(copies) · \(size) can be freed")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
    }

    // MARK: - Actions

    private func keptID(in group: DuplicateGroup) -> String {
        keep[group.id] ?? group.suggestedKeeper.id
    }

    @MainActor
    private func search() async {
        let files = library.files
        let work = Task.detached(priority: .userInitiated) {
            DuplicateFinder.find(in: files) { value in
                Task { @MainActor in progress = value }
            }
        }
        // Closing the sheet cancels `.task`; pass that on so hashing stops.
        let found = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        groups = found
        isSearching = false
    }

    private func trashExtras(of selected: [DuplicateGroup]) {
        let extras = selected.flatMap { group in group.files.filter { $0.id != keptID(in: group) } }
        if library.trash(extras) {
            let handled = Set(selected.map(\.id))
            groups.removeAll { handled.contains($0.id) }
        } else {
            // Some copies may already be in the Trash: keep only groups that still have duplicates.
            groups = groups.compactMap { group in
                let remaining = group.files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
                return remaining.count > 1 ? DuplicateGroup(files: remaining, contentHash: group.contentHash) : nil
            }
        }
    }
}

private struct DuplicateRow: View {
    let file: ModelFileItem
    let isKept: Bool
    let keep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: keep) {
                Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isKept ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Keep this copy")

            ModelThumbnail(file: file, cornerRadius: 6)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(isKept ? String(localized: "Keep") : String(localized: "To Trash"))
                .font(.caption)
                .foregroundStyle(isKept ? Color.accentColor : Color.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: keep)
    }

    /// "Collection / Category · 6 Jul 2026".
    private var location: String {
        let collection = (file.collectionPath as NSString).lastPathComponent
        let folder = file.relativeFolder.isEmpty ? collection : "\(collection)/\(file.relativeFolder)"
        let date = file.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.locale))
        return "\(folder) · \(date)"
    }
}
