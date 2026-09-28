import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
import ThreeMFRendering

struct FileRowView: View {
    let file: ModelFileItem
    var showsFolder = true
    /// Estimated print time of a sliced project.
    var printTime: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            ModelThumbnail(file: file, cornerRadius: 8)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(details)
                        .lineLimit(1)
                    if let printTime {
                        Label(PrintFormatter.app.duration(printTime), systemImage: "clock")
                            .labelStyle(CompactLabelStyle())
                            .lineLimit(1)
                            .help("Print time")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showsFolder, !file.relativeFolder.isEmpty {
                    Label(file.relativeFolder, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let date = file.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: AppLanguage.locale))
        return "\(size) · \(date)"
    }
}
