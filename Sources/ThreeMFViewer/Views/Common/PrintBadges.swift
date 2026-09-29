import SwiftUI
import ThreeMFKit
import ThreeMFRendering

/// Print time and estimated cost of a sliced project, for list rows and gallery tiles.
struct PrintBadges: View {
    @EnvironmentObject private var costs: PrintCostStore
    let summary: SliceSummary?

    var body: some View {
        if let summary {
            Label(PrintFormatter.app.duration(summary.printTime), systemImage: "clock")
                .labelStyle(CompactLabelStyle())
                .help("Print time")
            if let cost = costs.cost(of: summary) {
                Text(costs.format(cost))
                    .help("Estimated print cost")
            }
        }
    }
}
