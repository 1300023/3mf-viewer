import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
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
    @State private var tab: DetailTab = .model

    enum DetailTab: Hashable {
        case model, photos, description
    }

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
            VStack(spacing: 0) {
                if !loaded.extras.isEmpty {
                    tabPicker(loaded)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
                switch tab {
                case .photos where !loaded.photos.isEmpty:
                    PhotoGalleryView(photos: loaded.photos)
                case .description where loaded.extras.hasDescription:
                    ModelDescriptionView(model: loaded.model, extras: loaded.extras)
                default:
                    modelView(loaded)
                }
            }
        }
    }

    private func tabPicker(_ loaded: LoadedModel) -> some View {
        Picker("View", selection: $tab) {
            Text("3D").tag(DetailTab.model)
            if !loaded.photos.isEmpty {
                Text("Photos (\(loaded.photos.count))").tag(DetailTab.photos)
            }
            if loaded.extras.hasDescription {
                Text("Description").tag(DetailTab.description)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func modelView(_ loaded: LoadedModel) -> some View {
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
