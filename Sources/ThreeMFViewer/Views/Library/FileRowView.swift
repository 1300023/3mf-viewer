import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
import ThreeMFRendering

struct FileRowView: View {
    let file: ModelFileItem
    var showsFolder = true
    /// Print time and filament of a sliced project.
    var summary: SliceSummary?

    var body: some View {
        HStack(spacing: 10) {
            ModelThumbnail(file: file, cornerRadius: 8)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(file.displayName)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    FileStatusBadges(file: file)
                }
                HStack(spacing: 6) {
                    Text(details)
                        .lineLimit(1)
                    PrintBadges(summary: summary)
                        .lineLimit(1)
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
