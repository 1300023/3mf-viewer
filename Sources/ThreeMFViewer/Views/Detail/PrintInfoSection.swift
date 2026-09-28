import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

/// Printer, profile and slicing results in the info panel.
struct PrintInfoSection: View {
    let project: PrintProject
    /// nil = all plates.
    let plate: Int?

    var body: some View {
        Divider()
        if project.plates.count > 1 {
            InfoRow("Plate", plateLabel)
        }
        if let printer = project.printerName {
            InfoRow("Printer", printer)
        }
        if let nozzle = project.nozzleDiameter {
            InfoRow("Nozzle", PrintFormatter.app.millimeters(nozzle))
        }
        if let layer = project.layerHeight {
            InfoRow("Layer height", PrintFormatter.app.millimeters(layer))
        }
        slicingRows
    }

    private var plateLabel: String {
        if let plate, let info = project.plate(plate) { return info.title }
        return String(localized: "All plates (\(project.plates.count))")
    }

    @ViewBuilder
    private var slicingRows: some View {
        if let plate {
            if let slice = project.plate(plate)?.slice {
                sliceRows(time: slice.printTime, weight: slice.weight, meters: slice.meters,
                          filaments: slice.filaments, note: nil)
            } else if !project.plates.isEmpty {
                InfoRow("Print time", String(localized: "Not sliced"))
            }
        } else if !project.slicedPlates.isEmpty {
            let sliced = project.slicedPlates.count
            let total = project.plates.count
            let filaments = project.totalFilaments
            let meters = filaments.compactMap(\.meters)
            sliceRows(time: project.totalPrintTime,
                      weight: project.totalWeight,
                      meters: meters.isEmpty ? nil : meters.reduce(0, +),
                      filaments: filaments,
                      note: sliced < total ? String(localized: "Sliced plates: \(sliced) of \(total)") : nil)
        } else if !project.plates.isEmpty {
            InfoRow("Print time", String(localized: "Not sliced"))
        }
    }

    @ViewBuilder
    private func sliceRows(time: TimeInterval?, weight: Double?, meters: Double?,
                           filaments: [FilamentUsage], note: String?) -> some View {
        if let time {
            InfoRow("Print time", PrintFormatter.app.duration(time))
        }
        if let text = PrintFormatter.app.filament(grams: weight, meters: meters) {
            InfoRow("Filament", text)
        }
        if filaments.count > 1 || filaments.first?.type != nil {
            ForEach(filaments, id: \.slot) { usage in
                FilamentUsageRow(usage: usage)
            }
        }
        if let note {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

private struct FilamentUsageRow: View {
    let usage: FilamentUsage

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(usage.color.map { Color(GeometryFactory.nsColor($0)) } ?? Color.secondary)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 10, height: 10)
            Text(usage.type ?? String(localized: "Filament \(usage.slot)"))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(PrintFormatter.app.filament(grams: usage.grams, meters: usage.meters) ?? "")
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.leading, 8)
        .help(usage.color?.hexString ?? "")
    }
}
