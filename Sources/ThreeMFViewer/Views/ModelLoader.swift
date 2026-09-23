import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

struct LoadedModel {
    /// nil when the archive has no model part (e.g. a sliced ".gcode.3mf").
    let model: ThreeMFModel?
    let viewer: ViewerScene?
    /// Embedded preview, shown when there is nothing to render.
    let previewImage: NSImage?
}

@MainActor
final class ModelLoader: ObservableObject {
    enum State {
        case loading
        case loaded(LoadedModel)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    func load(_ file: ModelFileItem) async {
        state = .loading
        let url = file.url
        let work = Task.detached(priority: .userInitiated) { () throws -> LoadedModel in
            let model: ThreeMFModel?
            do {
                model = try ThreeMFReader.load(url: url)
            } catch ThreeMFError.missingModel {
                model = nil
            }
            try Task.checkCancellation()
            if let model, model.triangleCount > 0 {
                return LoadedModel(model: model, viewer: ViewerScene(model: model), previewImage: nil)
            }
            let image = (try? ThreeMFReader.thumbnailData(url: url)).flatMap { NSImage(data: $0) }
            return LoadedModel(model: model, viewer: nil, previewImage: image)
        }

        do {
            let loaded = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            state = .loaded(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
