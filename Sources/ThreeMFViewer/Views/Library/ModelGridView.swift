import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
import ThreeMFRendering

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list, grid

    var id: String { rawValue }
}

/// Gallery of large thumbnails. Click selects, arrow keys move the selection (macOS 14+).
struct ModelGridView: View {
    @EnvironmentObject private var library: LibraryModel
    let files: [ModelFileItem]
    let tileSize: Double
    let showsFolder: (ModelFileItem) -> Bool

    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 12

    private var columnCount: Int {
        let available = width - padding * 2
        return max(1, Int((available + spacing) / (CGFloat(tileSize) + spacing)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.15), spacing: spacing)],
                          alignment: .leading,
                          spacing: spacing) {
                    ForEach(files) { file in
                        ModelTile(file: file,
                                  isSelected: library.selection == file.id,
                                  summary: library.sliceSummary(for: file),
                                  showsFolder: showsFolder(file))
                            .id(file.id)
                            .draggable(file.url)
                            .onTapGesture {
                                library.selection = file.id
                                isFocused = true
                            }
                            .contextMenu { ModelContextMenu(file: file) }
                    }
                }
                .padding(padding)
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { width = $0 }
                }
            )
            .modifier(GridKeyboardNavigation(isFocused: $isFocused, move: move))
            .onChange(of: library.selection) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    /// Moves the selection by `step` tiles (±1 horizontally, ±columns vertically).
    private func move(_ direction: GridKeyboardNavigation.Direction) {
        guard !files.isEmpty else { return }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columnCount
        case .down: step = columnCount
        }
        let current = library.selection.flatMap { id in files.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), files.count - 1) } ?? 0
        library.selection = files[next].id
    }
}

struct GridKeyboardNavigation: ViewModifier {
    enum Direction { case left, right, up, down }

    var isFocused: FocusState<Bool>.Binding
    let move: (Direction) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusable()
                .focused(isFocused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(.left); return .handled }
                .onKeyPress(.rightArrow) { move(.right); return .handled }
                .onKeyPress(.upArrow) { move(.up); return .handled }
                .onKeyPress(.downArrow) { move(.down); return .handled }
        } else {
            content
        }
    }
}

private struct ModelTile: View {
    let file: ModelFileItem
    let isSelected: Bool
    let summary: SliceSummary?
    let showsFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ModelThumbnail(file: file, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
            Text(file.displayName)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                // A tile is narrow: sliced projects show time and cost instead of the file size.
                if summary == nil {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                }
                PrintBadges(summary: summary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if showsFolder, !file.relativeFolder.isEmpty {
                Label(file.relativeFolder, systemImage: "folder")
                    .labelStyle(CompactLabelStyle())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .help(file.url.lastPathComponent)
    }
}
