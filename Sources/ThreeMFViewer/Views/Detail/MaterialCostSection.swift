import SwiftUI
import ThreeMFKit
import ThreeMFLibrary
import ThreeMFRendering

/// What the print would cost in PLA, PETG, ABS… — from the sliced project, or estimated from the model's shape.
struct MaterialCostSection: View {
    @EnvironmentObject private var costs: PrintCostStore
    @AppStorage("info.showMaterialCosts") private var isExpanded = true
    let project: PrintProject
    /// nil = all plates.
    let plate: Int?
    /// Volume and surface of the shown model (or plate).
    let measure: MeshMeasure?

    var body: some View {
        if costs.settings.isEnabled, let comparison {
            Divider()
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(comparison.rows) { row in
                        MaterialCostRowView(row: row, costs: costs)
                    }
                    Text(footnote(comparison))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.top, 4)
            } label: {
                Text("Cost by material")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var comparison: MaterialComparison? {
        let settings = costs.settings
        if let sliced = slicedUsage {
            let volume = MaterialCostCalculator.volume(filamentGrams: sliced.grams)
            let types = Set(sliced.grams.keys.filter { !$0.isEmpty })
            return MaterialCostCalculator.compare(volume: volume, printTime: sliced.time, source: .sliced,
                                                  currentTypes: types, settings: settings,
                                                  printerName: project.printerName)
        }
        guard let measure else { return nil }
        let volume = MaterialCostCalculator.printedVolume(measure, infill: settings.estimateInfill)
        return MaterialCostCalculator.compare(volume: volume, printTime: nil, source: .estimated, settings: settings)
    }

    /// Filament and time of the shown plate (or of the whole project when every plate is sliced).
    private var slicedUsage: (grams: [String: Double], time: TimeInterval?)? {
        if let plate {
            guard let slice = project.plate(plate)?.slice else { return nil }
            let grams = slice.gramsByType
            return grams.isEmpty ? nil : (grams, slice.printTime)
        }
        guard !project.slicedPlates.isEmpty, project.slicedPlates.count == project.plates.count else { return nil }
        let grams = project.totalGramsByType
        return grams.isEmpty ? nil : (grams, project.totalPrintTime)
    }

    private func footnote(_ comparison: MaterialComparison) -> String {
        let volume = comparison.volume.formatted(.number.precision(.fractionLength(0 ... 1)).locale(AppLanguage.locale))
        switch comparison.source {
        case .sliced:
            return String(localized: "The sliced amount of plastic (\(volume) cm³) in each filament, with the same print time. Hotter filaments use more electricity.")
        case .estimated:
            let infill = costs.settings.estimateInfill.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.locale))
            return String(localized: "Estimate from the model's shape: \(volume) cm³ of plastic with walls and \(infill) infill, without printer time. Slice the model for exact numbers.")
        }
    }
}

private struct MaterialCostRowView: View {
    let row: MaterialCostRow
    let costs: PrintCostStore

    var body: some View {
        HStack(spacing: 6) {
            Text(row.type)
                .fontWeight(row.isCurrent ? .semibold : .regular)
            if row.isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Filament of the sliced project")
            }
            Spacer(minLength: 8)
            Text(PrintFormatter.app.grams(row.grams))
                .foregroundStyle(.secondary)
            Text(costs.format(amount: row.cost.total))
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
        .help(help)
    }

    private var help: String { costs.breakdown(row.cost) }
}
