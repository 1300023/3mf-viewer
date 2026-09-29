import AppKit
import SwiftUI
import ThreeMFKit

/// The author's photos stored in the file: a large image and a strip of thumbnails.
/// ← and → switch photos (macOS 14+).
struct PhotoGalleryView: View {
    let photos: [LoadedPhoto]

    @State private var index = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let image = photos[safe: index]?.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                } else {
                    PlaceholderView(systemImage: "photo", title: "Can't show this image")
                }
                HStack {
                    arrow("chevron.left", enabled: index > 0) { step(-1) }
                    Spacer()
                    arrow("chevron.right", enabled: index < photos.count - 1) { step(1) }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            thumbnails

            if let photo = photos[safe: index] {
                Text("\(index + 1) / \(photos.count) · \(photo.photo.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .modifier(GridKeyboardNavigation(isFocused: $isFocused) { direction in
            switch direction {
            case .left, .up: step(-1)
            case .right, .down: step(1)
            }
        })
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                        Button {
                            index = offset
                            isFocused = true
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                                if let image = photo.image {
                                    Image(nsImage: image)
                                        .resizable()
                                        .interpolation(.medium)
                                        .scaledToFill()
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(offset == index ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(offset)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 68)
            .onChange(of: index) { value in
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    private func step(_ delta: Int) {
        index = min(max(index + delta, 0), photos.count - 1)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
