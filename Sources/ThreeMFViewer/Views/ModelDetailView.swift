import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

struct ModelDetailView: View {
    let file: ModelFileItem

    @StateObject private var loader = ModelLoader()
    @AppStorage("viewer.showColors") private var showColors = true
    @AppStorage("viewer.wireframe") private var wireframe = false
    @AppStorage("viewer.showPlate") private var showPlate = true
    @AppStorage("viewer.showInfo") private var showInfo = true
    @AppStorage("viewer.autoRotate") private var autoRotate = false
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
                plateView(loaded)

                if showInfo {
                    let panel = InfoPanel(file: file,
                                          model: loader.content?.model ?? loaded.model,
                                          project: loaded.project,
                                          plate: loader.selectedPlate)
                    // Scrolls when the window is too low for all the rows.
                    ViewThatFits(in: .vertical) {
                        panel
                        ScrollView(.vertical) { panel }
                            .frame(width: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(12)
                    .padding(.bottom, loaded.project.plates.count > 1 ? 110 : 0)
                }
            }
            .overlay(alignment: .bottom) {
                if loaded.project.plates.count > 1 {
                    PlateStrip(project: loaded.project, selection: loader.selectedPlate) { plate in
                        loader.select(plate: plate)
                    }
                    .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private func plateView(_ loaded: LoadedModel) -> some View {
        ZStack {
            if let viewer = loader.content?.viewer {
                SceneKitView(viewer: viewer,
                             options: ViewerOptions(showColors: showColors,
                                                    wireframe: wireframe,
                                                    showPlate: showPlate,
                                                    autoRotate: autoRotate),
                             resetToken: resetToken)
                    .ignoresSafeArea()
            } else if let image = loader.content?.image {
                VStack(spacing: 12) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 520)
                    if (loaded.model?.triangleCount ?? 0) > 0 {
                        Text("There are no objects on this plate.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("This file has no 3D geometry — showing the embedded preview.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(40)
                .padding(.bottom, loaded.project.plates.count > 1 ? 90 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loader.content != nil {
                PlaceholderView(systemImage: "cube.transparent",
                                title: "No geometry",
                                message: String(localized: "The file does not contain any printable meshes."))
            }

            if loader.isSwitchingPlate {
                ProgressView()
                    .controlSize(.large)
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

            Toggle(isOn: $autoRotate) {
                Label("Auto-Rotate", systemImage: "rotate.3d")
            }
            .help("Rotate the model like a turntable")

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
    var project = PrintProject()
    /// Selected plate; nil = all plates.
    var plate: Int?

    private static let metadataKeys = ["Title", "Designer", "Application", "CreationDate", "License", "Copyright"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.displayName)
                .font(.headline)
                .lineLimit(3)
            Divider()

            // Files such as ".gcode.3mf" have a model part without meshes: take the counts from the slicer data.
            if let model, model.triangleCount > 0 {
                if let size = model.sizeInMillimeters {
                    row("Size", "\(format(size.x)) × \(format(size.y)) × \(format(size.z)) \(String(localized: "mm"))")
                }
                row("Objects", model.objectCount.formatted())
                row("Triangles", model.triangleCount.formatted())
            } else if let objects = objectCountWithoutModel, objects > 0 {
                row("Objects", objects.formatted())
            }
            if let model, !model.filamentColors.isEmpty {
                HStack(alignment: .center) {
                    Text("Filaments").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        ForEach(Array(model.filamentColors.prefix(16).enumerated()), id: \.offset) { item in
                            Circle()
                                .fill(Color(GeometryFactory.nsColor(item.element)))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                .frame(width: 12, height: 12)
                                .help(filamentHelp(slot: item.offset + 1, color: item.element))
                        }
                    }
                }
            }

            if !project.isEmpty {
                PrintInfoSection(project: project, plate: plate)
            }
            if let format = file.format {
                row("Format", format.displayName)
            }
            row("File size", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            row("Modified", file.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.locale)))

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

    /// Object count of a file without a model part (e.g. ".gcode.3mf"), from the slicer data.
    private var objectCountWithoutModel: Int? {
        if let plate, let info = project.plate(plate) { return info.objectCount }
        let total = project.plates.reduce(0) { $0 + $1.objectCount }
        return total > 0 ? total : nil
    }

    private func filamentHelp(slot: Int, color: RGBAColor) -> String {
        let type = slot <= project.filamentTypes.count ? project.filamentTypes[slot - 1] : nil
        return [String(slot) + ":", type, color.hexString].compactMap { $0 }.joined(separator: " ")
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
