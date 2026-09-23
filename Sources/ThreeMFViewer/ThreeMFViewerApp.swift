import AppKit
import SwiftUI

@main
struct ThreeMFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        Window("3MF Viewer", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.attach(library) }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { library.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Refresh") { library.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Clear Thumbnail Cache") {
                    ThumbnailStore.shared.clearDiskCache()
                    library.refresh()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var library: LibraryModel?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` (no .app bundle): show a Dock icon and a menu bar.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Files / folders dropped on the Dock icon or opened via Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        if let library {
            library.open(urls)
        } else {
            pendingURLs += urls
        }
    }

    func attach(_ library: LibraryModel) {
        self.library = library
        if !pendingURLs.isEmpty {
            library.open(pendingURLs)
            pendingURLs = []
        }
    }
}
