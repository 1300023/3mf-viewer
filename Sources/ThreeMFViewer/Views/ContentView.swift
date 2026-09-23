import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.open(urls)
            return !urls.isEmpty
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
    }

    @ViewBuilder
    private var detail: some View {
        if let file = library.selectedFile {
            ModelDetailView(file: file)
                .id(file.id)
        } else if library.folderURL == nil {
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
            Text("Choose a folder with .3mf models to browse them.")
                .foregroundStyle(.secondary)
            Button {
                library.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
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
