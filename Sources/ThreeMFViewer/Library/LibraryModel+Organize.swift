import Foundation
import ThreeMFKit
import ThreeMFLibrary

/// Inbox, favourites, "printed" marks, tags, notes and the facts used by search and filters.
extension LibraryModel {
    // MARK: - Facts for search and filters

    func facts(for file: ModelFileItem) -> FileFacts {
        let details = modelDetails.details(for: file)
        return FileFacts(printTime: sliceSummaries.summary(for: file)?.printTime,
                         details: details,
                         fits: details.flatMap { buildVolume.fits(plateSizes: $0.plateSizeVectors) })
    }

    func details(for file: ModelFileItem) -> ModelDetails? {
        modelDetails.details(for: file)
    }

    /// Whether every plate of the model fits the printer; nil while unknown.
    func fitsPrinter(_ file: ModelFileItem) -> Bool? {
        details(for: file).flatMap { buildVolume.fits(plateSizes: $0.plateSizeVectors) }
    }

    /// Filament types found in the library, for the filter menu.
    var availableFilamentTypes: [String] {
        Array(Set(allFiles.flatMap { modelDetails.details(for: $0)?.filamentTypes ?? [] })).sorted()
    }

    /// Reads every model completely in the background (4 at a time) and keeps the result on disk.
    func loadModelDetails() {
        let all = allFiles
        modelDetails.keepOnly(all)
        let pending = modelDetails.filesNeedingUpdate(all)
        guard !pending.isEmpty else { return }
        detailsTask?.cancel()
        let previous = detailsTask
        isReadingDetails = true
        detailsTask = Task { [weak self] in
            // Let a cancelled run write its cache first, so saves never overtake each other.
            await previous?.value
            let batchSize = 4
            var unsaved = 0
            for start in stride(from: 0, to: pending.count, by: batchSize) {
                guard !Task.isCancelled else { break }
                let batch = Array(pending[start ..< min(start + batchSize, pending.count)])
                let entries = await Task.detached(priority: .utility) { ModelDetailsStore.read(batch) }.value
                guard let self else { return }
                self.modelDetails.store(entries)
                unsaved += entries.count
                // Save now and then during a long first read, and at the end.
                if unsaved >= 100 {
                    await self.saveModelDetails()
                    unsaved = 0
                }
            }
            if unsaved > 0 { await self?.saveModelDetails() }
            if !Task.isCancelled { self?.isReadingDetails = false }
        }
    }

    private func saveModelDetails() async {
        guard let url = detailsCacheURL else { return }
        let store = modelDetails
        await Task.detached(priority: .background) { store.save(to: url) }.value
    }

    // MARK: - Sidebar

    var favoritesCount: Int { allFiles.filter(\.isFavorite).count }
    var printedCount: Int { allFiles.filter(\.isPrinted).count }

    /// The user's own Finder tags in the library with the number of models, by name.
    var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for file in allFiles {
            for tag in file.userTags { counts[tag, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// Header of the model list.
    var selectionTitle: String {
        switch selectedCategoryID {
        case Self.inboxID?: return String(localized: "Inbox")
        case Self.favoritesID?: return String(localized: "Favorites")
        case Self.printedID?: return String(localized: "Printed")
        case let id? where id.hasPrefix(Self.tagPrefix): return String(id.dropFirst(Self.tagPrefix.count))
        default: return selectedCategory?.name ?? String(localized: "All Models")
        }
    }

    func isInInbox(_ url: URL) -> Bool {
        guard isInboxEnabled, let inboxFolder else { return false }
        return LibraryPaths.isSameOrInside(url.standardizedFileURL.path, inboxFolder.path)
    }

    // MARK: - Favourites, printed, tags, notes

    /// Tag names written in the interface language ("Favorite" / "Избранное").
    static var favoriteTagName: String { localizedTag(String(localized: "Favorite"), in: LibraryTags.favoriteNames) }
    static var printedTagName: String { localizedTag(String(localized: "Printed"), in: LibraryTags.printedNames) }

    private static func localizedTag(_ name: String, in names: [String]) -> String {
        names.contains(name) ? name : names[0]
    }

    func setFavorite(_ on: Bool, for file: ModelFileItem) {
        updateTags(of: file) { LibraryTags.setting(LibraryTags.favoriteNames, on: on, name: Self.favoriteTagName, in: $0) }
    }

    func setPrinted(_ on: Bool, for file: ModelFileItem) {
        updateTags(of: file) { LibraryTags.setting(LibraryTags.printedNames, on: on, name: Self.printedTagName, in: $0) }
    }

    func addTag(_ tag: String, to file: ModelFileItem) {
        updateTags(of: file) { LibraryTags.adding(tag, to: $0) }
    }

    func removeTag(_ tag: String, from file: ModelFileItem) {
        updateTags(of: file) { $0.filter { $0 != tag } }
    }

    /// Applies `change` to the library models among dropped `urls`; false when none of them is a model.
    func mark(_ urls: [URL], _ change: (ModelFileItem) -> Void) -> Bool {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        let targets = allFiles.filter { paths.contains($0.id) }
        targets.forEach(change)
        return !targets.isEmpty
    }

    func note(for file: ModelFileItem) -> String? {
        LibraryTags.note(of: file.url)
    }

    func setNote(_ note: String, for file: ModelFileItem) {
        do {
            try LibraryTags.setNote(note, for: file.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateTags(of file: ModelFileItem, _ change: ([String]) -> [String]) {
        let current = LibraryTags.tags(of: file.url)
        let updated = change(current)
        guard updated != current else { return }
        do {
            try LibraryTags.setTags(updated, for: file.url)
            applyTagsLocally(updated, to: file.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
