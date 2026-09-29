import SwiftUI
import ThreeMFLibrary

/// Popover with the filters of the model list.
struct FiltersView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Print time", selection: $library.filters.printTime) {
                    ForEach(LibraryFilters.PrintTime.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Slicing", selection: $library.filters.slicing) {
                    ForEach(LibraryFilters.Slicing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Filament", selection: $library.filters.filamentType) {
                    Text("Any").tag(String?.none)
                    ForEach(filamentTypes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Colors", selection: $library.filters.colors) {
                    ForEach(LibraryFilters.Colors.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Printer", selection: $library.filters.fit) {
                    ForEach(LibraryFilters.Fit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Printed", selection: $library.filters.printed) {
                    ForEach(LibraryFilters.Printed.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Favorites only", isOn: $library.filters.favoritesOnly)
            }

            Text("Search also looks in the title, author and description inside the files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Reset Filters") { library.filters = LibraryFilters() }
                    .disabled(!library.filters.isActive)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Types found in the library, plus the selected one while the library is still being read.
    private var filamentTypes: [String] {
        var types = library.availableFilamentTypes
        if let selected = library.filters.filamentType, !types.contains(selected) { types.insert(selected, at: 0) }
        return types
    }
}

extension LibraryFilters.PrintTime {
    var title: LocalizedStringKey {
        switch self {
        case .any: return "Any"
        case .upTo1h: return "Up to 1 hour"
        case .upTo3h: return "Up to 3 hours"
        case .upTo8h: return "Up to 8 hours"
        case .over8h: return "Over 8 hours"
        }
    }
}

extension LibraryFilters.Slicing {
    var title: LocalizedStringKey {
        switch self {
        case .any: return "Any"
        case .sliced: return "Sliced"
        case .notSliced: return "Not sliced"
        }
    }
}

extension LibraryFilters.Colors {
    var title: LocalizedStringKey {
        switch self {
        case .any: return "Any"
        case .single: return "Single color"
        case .multi: return "Multicolor"
        }
    }
}

extension LibraryFilters.Fit {
    var title: LocalizedStringKey {
        switch self {
        case .any: return "Any"
        case .fits: return "Fits"
        case .tooBig: return "Too big"
        }
    }
}

extension LibraryFilters.Printed {
    var title: LocalizedStringKey {
        switch self {
        case .any: return "Any"
        case .printed: return "Printed"
        case .notPrinted: return "Not printed"
        }
    }
}
