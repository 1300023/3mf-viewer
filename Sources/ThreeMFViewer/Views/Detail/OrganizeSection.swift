import SwiftUI
import ThreeMFLibrary

/// Favourite and "printed" marks, tags and a note of a model, stored as Finder tags and a Finder comment.
struct OrganizeSection: View {
    @EnvironmentObject private var library: LibraryModel
    let file: ModelFileItem

    @State private var newTag = ""
    @State private var note = ""
    /// The file the note text belongs to, and the text as it is on disk.
    @State private var noteFile: ModelFileItem?
    @State private var savedNote = ""
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { file.isFavorite }, set: { library.setFavorite($0, for: file) })) {
                    Label("Favorite", systemImage: file.isFavorite ? "star.fill" : "star")
                }
                Toggle(isOn: Binding(get: { file.isPrinted }, set: { library.setPrinted($0, for: file) })) {
                    Label("Printed", systemImage: file.isPrinted ? "checkmark.seal.fill" : "checkmark.seal")
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)

            if !file.userTags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(file.userTags, id: \.self) { tag in
                        TagChip(tag: tag) { library.removeTag(tag, from: file) }
                    }
                }
            }

            HStack(spacing: 4) {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                if !suggestedTags.isEmpty {
                    Menu {
                        ForEach(suggestedTags, id: \.self) { tag in
                            Button(tag) { library.addTag(tag, to: file) }
                        }
                    } label: {
                        Image(systemName: "tag")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an existing tag")
                }
            }
            .controlSize(.small)

            TextField("Note", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 5)
                .controlSize(.small)
                .focused($isNoteFocused)
                .onSubmit(saveNote)
                .onChange(of: isNoteFocused) { focused in
                    if !focused { saveNote() }
                }
        }
        .task(id: file.id) {
            saveNote()
            let text = library.note(for: file) ?? ""
            noteFile = file
            note = text
            savedNote = text
            newTag = ""
        }
        .onDisappear(perform: saveNote)
    }

    /// Tags used elsewhere in the library that this model does not have yet.
    private var suggestedTags: [String] {
        library.tagCounts.map(\.tag).filter { !file.userTags.contains($0) }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        library.addTag(tag, to: file)
        newTag = ""
    }

    private func saveNote() {
        guard let noteFile, note != savedNote else { return }
        library.setNote(note, for: noteFile)
        savedNote = note
    }
}

private struct TagChip: View {
    let tag: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove tag")
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

/// Lays children out in rows, wrapping to the next row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
