import AppKit
import SwiftUI
import ThreeMFKit
import ThreeMFRendering

// MARK: - Formatting

enum PrintFormat {
    /// "1h 25m" / "1 ч 25 мин".
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        if seconds >= 3600 {
            formatter.allowedUnits = [.hour, .minute]
        } else if seconds >= 60 {
            formatter.allowedUnits = [.minute]
        } else {
            formatter.allowedUnits = [.second]
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLanguage.locale
        formatter.calendar = calendar
        return formatter.string(from: seconds.rounded()) ?? ""
    }

    static func grams(_ value: Double) -> String {
        measurement(value, UnitMass.grams, fractionDigits: value < 10 ? 1 : 0)
    }

    static func meters(_ value: Double) -> String {
        measurement(value, UnitLength.meters, fractionDigits: value < 10 ? 2 : 1)
    }

    /// "0.4" → "0.4 mm". Values that are not numbers are shown as they are.
    static func millimeters(_ text: String) -> String {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return text }
        return measurement(value, UnitLength.millimeters, fractionDigits: 2)
    }

    /// "30.5 g · 10.2 m"
    static func filament(grams: Double?, meters: Double?) -> String? {
        let parts = [grams.map(Self.grams), meters.map(Self.meters)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func measurement<U: Dimension>(_ value: Double, _ unit: U, fractionDigits: Int) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = AppLanguage.locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.minimumFractionDigits = 0
        formatter.numberFormatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    static func plateTitle(_ plate: PlateInfo) -> String {
        if let name = plate.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return "\(plate.index). \(name)"
        }
        return String(localized: "Plate \(plate.index)")
    }
}

// MARK: - Info panel section

/// Printer, profile and slicing results in the info panel.
struct PrintInfoSection: View {
    let project: PrintProject
    /// nil = all plates.
    let plate: Int?

    var body: some View {
        Divider()
        if project.plates.count > 1 {
            row("Plate", plateLabel)
        }
        if let printer = project.printerName {
            row("Printer", printer)
        }
        if let nozzle = project.nozzleDiameter {
            row("Nozzle", PrintFormat.millimeters(nozzle))
        }
        if let layer = project.layerHeight {
            row("Layer height", PrintFormat.millimeters(layer))
        }
        slicingRows
    }

    private var plateLabel: String {
        if let plate, let info = project.plate(plate) { return PrintFormat.plateTitle(info) }
        return String(localized: "All plates (\(project.plates.count))")
    }

    @ViewBuilder
    private var slicingRows: some View {
        if let plate {
            if let slice = project.plate(plate)?.slice {
                sliceRows(time: slice.printTime, weight: slice.weight, meters: slice.meters,
                          filaments: slice.filaments, note: nil)
            } else if !project.plates.isEmpty {
                row("Print time", String(localized: "Not sliced"))
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
            row("Print time", String(localized: "Not sliced"))
        }
    }

    @ViewBuilder
    private func sliceRows(time: TimeInterval?, weight: Double?, meters: Double?,
                           filaments: [FilamentUsage], note: String?) -> some View {
        if let time {
            row("Print time", PrintFormat.duration(time))
        }
        if let text = PrintFormat.filament(grams: weight, meters: meters) {
            row("Filament", text)
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

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
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
            Text(PrintFormat.filament(grams: usage.grams, meters: usage.meters) ?? "")
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.leading, 8)
        .help(usage.color?.hexString ?? "")
    }
}

// MARK: - Plate picker

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
                      subtitle: project.totalPrintTime.map(PrintFormat.duration),
                      image: nil,
                      isSelected: selection == nil) { select(nil) }
                .help(String(localized: "All plates (\(project.plates.count))"))
            ForEach(project.plates) { plate in
                PlateChip(title: plate.name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(plate.index)",
                          subtitle: plate.slice?.printTime.map(PrintFormat.duration),
                          image: plate.thumbnail.flatMap { NSImage(data: $0) },
                          isSelected: selection == plate.index) { select(plate.index) }
                    .help(PrintFormat.plateTitle(plate))
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
