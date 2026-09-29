import SwiftUI
import ThreeMFLibrary

/// Favourite / printed marks and the "too big for the printer" warning of a model.
struct FileStatusBadges: View {
    @EnvironmentObject private var library: LibraryModel
    let file: ModelFileItem

    var body: some View {
        HStack(spacing: 3) {
            if file.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .help("Favorite")
            }
            if file.isPrinted {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Printed")
            }
            if library.fitsPrinter(file) == false {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("Too big for the printer")
            }
        }
        .imageScale(.small)
    }
}
