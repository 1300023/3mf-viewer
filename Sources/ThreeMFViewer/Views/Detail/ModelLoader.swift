import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
import ThreeMFRendering

struct LoadedModel {
    /// nil when the archive has no model part.
    let model: ThreeMFModel?
    /// Printer, plates and slicing results (also available for files without geometry, e.g. ".gcode.3mf").
    let project: PrintProject
    /// Embedded preview, shown when there is nothing to render.
    let previewImage: NSImage?
    /// Photos and description published by the model's author.
    let extras: ModelExtras
    /// `extras.photos`, decoded.
    let photos: [LoadedPhoto]
}

struct LoadedPhoto: Identifiable {
    let photo: ModelPhoto
    let image: NSImage?

    var id: String { photo.id }
}

/// What the detail view shows for the selected plate (or for all plates).
struct PlateContent {
    /// The model restricted to the plate; nil when the file has no model part.
    let model: ThreeMFModel?
    let viewer: ViewerScene?
    /// Shown instead of the 3D view when the plate has no geometry.
    let image: NSImage?
}

@MainActor
final class ModelLoader: ObservableObject {
    enum State {
        case loading
        case loaded(LoadedModel)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// nil = all plates.
    @Published private(set) var selectedPlate: Int?
    @Published private(set) var content: PlateContent?
    @Published private(set) var isSwitchingPlate = false

    private var cache: [Int: PlateContent] = [:]   // key 0 = all plates
    private var plateTask: Task<Void, Never>?

    func load(_ file: ModelFileItem) async {
        state = .loading
        selectedPlate = nil
        content = nil
        cache = [:]
        plateTask?.cancel()

        let url = file.url
        let work = Task.detached(priority: .userInitiated) { () throws -> (LoadedModel, PlateContent, Int?) in
            let isThreeMF = ModelFileFormat(url: url) == .threeMF
            var model: ThreeMFModel?
            var project: PrintProject
            do {
                let loaded = try ModelReader.load(url: url)
                model = loaded
                project = loaded.project
            } catch ThreeMFError.missingModel {
                model = nil
                project = (try? ThreeMFReader.printProject(url: url)) ?? PrintProject()
            }
            try Task.checkCancellation()
            let preview = isThreeMF
                ? (try? ThreeMFReader.thumbnailData(url: url)).flatMap { NSImage(data: $0) }
                : nil
            let extras = isThreeMF
                ? (try? ThreeMFReader.extras(url: url, metadata: model?.metadata ?? [])) ?? ModelExtras()
                : ModelExtras()
            let photos = extras.photos.map { LoadedPhoto(photo: $0, image: NSImage(data: $0.data)) }
            let loaded = LoadedModel(model: model, project: project, previewImage: preview,
                                     extras: extras, photos: photos)
            // Multi-plate projects open on their first plate: all plates side by side are tiny.
            if let model, model.triangleCount > 0, project.plates.count > 1, let first = project.plates.first {
                let plateModel = model.onPlate(first.index)
                if plateModel.triangleCount > 0 {
                    return (loaded, Self.makeContent(model: plateModel, image: nil), first.index)
                }
            }
            return (loaded, Self.makeContent(model: model, image: preview), nil)
        }

        do {
            let (loaded, content, plate) = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            cache[plate ?? 0] = content
            self.content = content
            selectedPlate = plate
            state = .loaded(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Shows one plate (or all of them when `plate` is nil). Scenes are built in the background and cached.
    func select(plate: Int?) {
        guard case .loaded(let loaded) = state, plate != selectedPlate else { return }
        selectedPlate = plate
        plateTask?.cancel()
        isSwitchingPlate = false

        let key = plate ?? 0
        if let cached = cache[key] {
            content = cached
            return
        }
        let plateImage = plate.flatMap { loaded.project.plate($0)?.image }.flatMap { NSImage(data: $0) }
        let fallbackImage = plateImage ?? loaded.previewImage
        let model = loaded.model
        isSwitchingPlate = true
        plateTask = Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) {
                let restricted = plate.flatMap { p in model?.onPlate(p) } ?? model
                return Self.makeContent(model: restricted, image: fallbackImage)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cache[key] = content
            self.content = content
            self.isSwitchingPlate = false
        }
    }

    nonisolated private static func makeContent(model: ThreeMFModel?, image: NSImage?) -> PlateContent {
        if let model, model.triangleCount > 0 {
            return PlateContent(model: model, viewer: ViewerScene(model: model), image: nil)
        }
        return PlateContent(model: model, viewer: nil, image: image)
    }
}
