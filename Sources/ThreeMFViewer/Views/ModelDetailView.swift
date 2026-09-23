import AppKit
import SwiftUI
import ThreeMFKit

struct ModelDetailView: View {
    let file: ModelFileItem

    @StateObject private var loader = ModelLoader()
    @AppStorage("viewer.showColors") private var showColors = true
    @AppStorage("viewer.wireframe") private var wireframe = false
    @AppStorage("viewer.showPlate") private var showPlate = true
    @AppStorage("viewer.showInfo") private var showInfo = true
    @State private var resetToken = 0

    var body: some View {
        content
            .navigationTitle(file.displayName)
            .navigationSubtitle(file.relativeFolder)
            .toolbar { toolbar }
            .task(id: file.id) {
                await loader.load(file)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView("Loading model…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            PlaceholderView(systemImage: "exclamationmark.triangle",
                            title: "Couldn't open the file",
                            message: message)
        case .loaded(let loaded):
            ZStack(alignment: .topTrailing) {
                if let viewer = loaded.viewer {
                    SceneKitView(viewer: viewer,
                                 options: ViewerOptions(showColors: showColors,
                                                        wireframe: wireframe,
                                                        showPlate: showPlate),
                                 resetToken: resetToken)
                        .ignoresSafeArea()
                } else if let image = loaded.previewImage {
                    VStack(spacing: 12) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(maxWidth: 520, maxHeight: 520)
                        Text("This file has no 3D geometry — showing the embedded preview.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlaceholderView(systemImage: "cube.transparent",
                                    title: "No geometry",
                                    message: String(localized: "The file does not contain any printable meshes."))
                }

                if showInfo {
                    InfoPanel(file: file, model: loaded.model)
                        .padding(12)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                resetToken += 1
            } label: {
                Label("Reset View", systemImage: "arrow.counterclockwise")
            }
            .help("Reset camera")
            .keyboardShortcut("0", modifiers: .command)

            Toggle(isOn: $showColors) {
                Label("Colors", systemImage: "paintpalette")
            }
            .help("Show filament and material colors")

            Toggle(isOn: $wireframe) {
                Label("Wireframe", systemImage: "cube.transparent")
            }
            .help("Wireframe")

            Toggle(isOn: $showPlate) {
                Label("Build Plate", systemImage: "square.grid.3x3")
            }
            .help("Show build plate grid")

            Toggle(isOn: $showInfo) {
                Label("Info", systemImage: "info.circle")
            }
            .help("Show model information")

            Menu {
                FileContextMenu(url: file.url)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            } primaryAction: {
                NSWorkspace.shared.open(file.url)
            }
            .help("Open in the default app (click) or choose another app (hold)")
        }
    }
}

struct InfoPanel: View {
    let file: ModelFileItem
    let model: ThreeMFModel?

    private static let metadataKeys = ["Title", "Designer", "Application", "CreationDate", "License", "Copyright"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.displayName)
                .font(.headline)
                .lineLimit(3)
            Divider()

            if let model {
                if let size = model.sizeInMillimeters {
                    row("Size", "\(format(size.x)) × \(format(size.y)) × \(format(size.z)) \(String(localized: "mm"))")
                }
                row("Objects", model.objectCount.formatted())
                row("Triangles", model.triangleCount.formatted())
                if !model.filamentColors.isEmpty {
                    HStack(alignment: .center) {
                        Text("Filaments").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            ForEach(Array(model.filamentColors.prefix(16).enumerated()), id: \.offset) { item in
                                Circle()
                                    .fill(Color(GeometryFactory.nsColor(item.element)))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                    .frame(width: 12, height: 12)
                                    .help("\(item.offset + 1): \(item.element.hexString)")
                            }
                        }
                    }
                }
            }
            row("File size", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            row("Modified", file.modified.formatted(date: .abbreviated, time: .shortened))

            if let model {
                let entries = Self.metadataKeys.compactMap { key in
                    model.metadata.first {
                        $0.name.caseInsensitiveCompare(key) == .orderedSame
                            && !$0.value.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' ")).isEmpty
                    }
                }
                if !entries.isEmpty {
                    Divider()
                    ForEach(entries, id: \.self) { entry in
                        row(LocalizedStringKey(entry.name), entry.value)
                    }
                }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}
