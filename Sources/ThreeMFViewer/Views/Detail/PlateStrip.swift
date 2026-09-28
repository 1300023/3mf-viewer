import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

/// Plate thumbnails shown under the 3D view of multi-plate projects.
struct PlateStrip: View {
    let project: PrintProject
    let selection: Int?
    let select: (Int?) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: true) { chips }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            PlateChip(title: String(localized: "All"),
                      subtitle: project.totalPrintTime.map(PrintFormatter.app.duration),
                      image: nil,
                      isSelected: selection == nil) { select(nil) }
                .help(String(localized: "All plates (\(project.plates.count))"))
            ForEach(project.plates) { plate in
                PlateChip(title: plate.name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(plate.index)",
                          subtitle: plate.slice?.printTime.map(PrintFormatter.app.duration),
                          image: plate.thumbnail.flatMap { NSImage(data: $0) },
                          isSelected: selection == plate.index) { select(plate.index) }
                    .help(plate.title)
            }
        }
        .padding(6)
    }
}

private struct PlateChip: View {
    let title: String
    let subtitle: String?
    let image: NSImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(2)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 64)
                Text(subtitle ?? " ")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
