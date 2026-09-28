import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
import ThreeMFRendering

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
                    InfoRow("Size", "\(format(size.x)) × \(format(size.y)) × \(format(size.z)) \(String(localized: "mm"))")
                }
                InfoRow("Objects", model.objectCount.formatted())
                InfoRow("Triangles", model.triangleCount.formatted())
            } else if let objects = objectCountWithoutModel, objects > 0 {
                InfoRow("Objects", objects.formatted())
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
                InfoRow("Format", format.displayName)
            }
            InfoRow("File size", ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
            InfoRow("Modified", file.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: AppLanguage.locale)))

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
                        InfoRow(LocalizedStringKey(entry.name), entry.value)
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


    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}
