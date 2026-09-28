import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary

/// Thumbnail of a model file (loaded through `ThumbnailStore`) with a format badge for STL / OBJ.
struct ModelThumbnail: View {
    let file: ModelFileItem
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?
    @State private var didLoad = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(cornerRadius / 2.5)
            } else if didLoad {
                Image(systemName: "cube")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let format = file.format, format != .threeMF {
                Text(format.displayName)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
        .task(id: file.cacheKey) {
            if let cached = ThumbnailStore.shared.cachedImage(for: file) {
                image = cached
                didLoad = true
                return
            }
            let loaded = await ThumbnailStore.shared.thumbnail(for: file)
            guard !Task.isCancelled else { return }
            image = loaded
            didLoad = true
        }
    }
}
