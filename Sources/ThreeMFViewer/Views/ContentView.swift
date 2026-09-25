import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            CollectionsSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 380)
        } content: {
            ModelListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 560)
        } detail: {
            detail
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.importDropped(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .alert("Could not complete the operation", isPresented: errorBinding) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
    }

    @ViewBuilder
    private var detail: some View {
        if let file = library.selectedFile {
            ModelDetailView(file: file)
                .id(file.id)
        } else if library.collections.isEmpty {
            WelcomeView()
        } else {
            PlaceholderView(systemImage: "cube",
                            title: "Select a model",
                            message: String(localized: "Choose a .3mf file in the list to preview it."))
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text("3MF Viewer")
                .font(.largeTitle.weight(.semibold))
            Text("Add a folder with .3mf models as a collection. Its subfolders become categories.")
                .foregroundStyle(.secondary)
            Button {
                library.addCollection()
            } label: {
                Label("Add Collection…", systemImage: "square.stack.3d.up")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text("…or drag a folder or a .3mf file into this window.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlaceholderView: View {
    let systemImage: String
    let title: LocalizedStringKey
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
