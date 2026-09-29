import XCTest
import ThreeMFKit
@testable import ThreeMFLibrary

final class ThreeMFLibraryTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("ThreeMFLibraryTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ relativePath: String, contents: String = "x", in base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url.standardizedFileURL
    }

    private func makeFolder(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func item(_ name: String, size: Int64 = 1, modified: TimeInterval = 0, folder: String = "") -> ModelFileItem {
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        return ModelFileItem(url: url, size: size, modified: Date(timeIntervalSince1970: modified),
                             collectionPath: root.path, relativeFolder: folder)
    }

    // MARK: - Scanner

    func testScannerBuildsCategoryTreeFromFolders() throws {
        let collection = try makeFolder("Prints")
        try makeFile("Prints/Top.3mf")
        try makeFile("Prints/Kitchen/Hooks/Hook.3mf")
        try makeFile("Prints/Kitchen/Cup.STL")
        try makeFile("Prints/Kitchen/notes.txt")
        try makeFile("Prints/Toys/Car.obj")
        try makeFile("Prints/Toys/Car.mtl")
        try makeFile("Prints/.hidden/Secret.3mf")
        _ = try makeFolder("Prints/Empty")

        let missing = root.appendingPathComponent("Unplugged disk", isDirectory: true)
        let snapshot = LibraryScanner.scan(roots: [collection, missing])

        XCTAssertEqual(snapshot.files.count, 4)
        XCTAssertEqual(Set(snapshot.files.map(\.displayName)), ["Top", "Hook", "Cup", "Car"])
        XCTAssertEqual(snapshot.files.first { $0.displayName == "Hook" }?.relativeFolder, "Kitchen/Hooks")
        XCTAssertEqual(snapshot.files.first { $0.displayName == "Top" }?.relativeFolder, "")

        let tree = try XCTUnwrap(snapshot.tree.first)
        XCTAssertTrue(tree.isCollection)
        XCTAssertEqual(tree.modelCount, 4)
        XCTAssertEqual(tree.children.map(\.name), ["Empty", "Kitchen", "Toys"])
        XCTAssertEqual(tree.children[1].modelCount, 2)
        XCTAssertEqual(tree.children[1].children.map(\.name), ["Hooks"])

        let unavailable = snapshot.tree[1]
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertTrue(unavailable.isCollection)

        XCTAssertNotNil(snapshot.index[collection.appendingPathComponent("Kitchen/Hooks").path])
    }

    func testVisibleRowsFollowExpandedState() throws {
        let collection = try makeFolder("C")
        try makeFile("C/A/Deep/x.3mf")
        let tree = LibraryScanner.scan(roots: [collection]).tree

        XCTAssertEqual(CategoryTree.visibleRows(tree, expanded: []).map(\.node.name).count, 1)
        let rows = CategoryTree.visibleRows(tree, expanded: [collection.path, collection.appendingPathComponent("A").path])
        XCTAssertEqual(rows.map(\.node.name), ["C", "A", "Deep"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }

    // MARK: - Query

    func testQueryFiltersByCategoryAndSearch() {
        let files = [item("Hook.3mf", folder: "Kitchen/Hooks"), item("Cup.3mf", folder: "Kitchen"),
                     item("Car.3mf", folder: "Toys"), item("Kitten.3mf", folder: "")]
        let kitchen = CategoryNode(url: root.appendingPathComponent("Kitchen"), name: "Kitchen",
                                   isCollection: false, isAvailable: true)

        let inKitchen = LibraryQuery(category: kitchen).apply(to: files)
        XCTAssertEqual(inKitchen.map(\.displayName), ["Cup", "Hook"])

        // The search looks at file names and category paths.
        XCTAssertEqual(LibraryQuery(searchText: " kit ").apply(to: files).map(\.displayName), ["Cup", "Hook", "Kitten"])
        XCTAssertEqual(LibraryQuery(searchText: "toys").apply(to: files).map(\.displayName), ["Car"])
    }

    func testQuerySortOrders() {
        let a = item("A 10.3mf", size: 5, modified: 100)
        let b = item("A 9.3mf", size: 50, modified: 300)
        let c = item("B.3mf", size: 20, modified: 200)
        let files = [c, a, b]

        XCTAssertEqual(LibraryQuery(sortOrder: .name).apply(to: files).map(\.displayName), ["A 9", "A 10", "B"])
        XCTAssertEqual(LibraryQuery(sortOrder: .modified).apply(to: files).map(\.displayName), ["A 9", "B", "A 10"])
        XCTAssertEqual(LibraryQuery(sortOrder: .size).apply(to: files).map(\.displayName), ["A 9", "B", "A 10"])

        // Shortest print first, never sliced last (by name).
        let times: [String: TimeInterval] = [c.id: 60, a.id: 3600]
        let byTime = LibraryQuery(sortOrder: .printTime).apply(to: files) { FileFacts(printTime: times[$0.id]) }
        XCTAssertEqual(byTime.map(\.displayName), ["B", "A 10", "A 9"])
    }

    // MARK: - File service

    func testCreateAndRenameCategory() throws {
        let service = LibraryFileService()
        let collection = try makeFolder("C")

        let created = try service.createCategory(named: "  Kit/chen: ", in: collection)
        XCTAssertEqual(created.lastPathComponent, "Kit-chen-")
        XCTAssertThrowsError(try service.createCategory(named: "Kit-chen-", in: collection)) { error in
            XCTAssertEqual(error as? LibraryError, .alreadyExists("Kit-chen-"))
        }
        XCTAssertThrowsError(try service.createCategory(named: " ... ", in: collection)) { error in
            XCTAssertEqual(error as? LibraryError, .invalidName)
        }

        try makeFile("C/Kit-chen-/Hook.3mf")
        let renamed = try service.renameCategory(at: created, to: "Kitchen")
        XCTAssertEqual(renamed.lastPathComponent, "Kitchen")
        XCTAssertTrue(fileManager.fileExists(atPath: renamed.appendingPathComponent("Hook.3mf").path))
        XCTAssertEqual(try service.renameCategory(at: renamed, to: "Kitchen"), renamed)

        _ = try service.createCategory(named: "Toys", in: collection)
        XCTAssertThrowsError(try service.renameCategory(at: renamed, to: "Toys"))
    }

    func testTransferRenamesOnConflict() throws {
        let service = LibraryFileService()
        let source = try makeFile("A/Model.3mf", contents: "new")
        let target = try makeFolder("B")
        try makeFile("B/Model.3mf", contents: "old")

        let moved = try service.transfer(source, into: target, move: true)
        XCTAssertEqual(moved.lastPathComponent, "Model 2.3mf")
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))

        let copy = try service.transfer(moved, into: target.deletingLastPathComponent().appendingPathComponent("A"), move: false)
        XCTAssertEqual(copy.lastPathComponent, "Model 2.3mf")
        XCTAssertTrue(fileManager.fileExists(atPath: moved.path))
    }

    func testObjMaterialLibrariesTravelWithTheModel() throws {
        let service = LibraryFileService()
        let obj = try makeFile("A/Car.obj", contents: "mtllib Car.mtl\nmtllib shared lib.mtl\nv 0 0 0\n")
        try makeFile("A/Car.mtl", contents: "newmtl Red\nKd 1 0 0\n")
        try makeFile("A/shared lib.mtl", contents: "newmtl Blue\nKd 0 0 1\n")
        let target = try makeFolder("B")

        XCTAssertEqual(LibraryFileService.materialLibraries(of: obj).map(\.lastPathComponent).sorted(),
                       ["Car.mtl", "shared lib.mtl"])

        try service.transfer(obj, into: target, move: true)
        // The model's own library moves, the shared one is copied.
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("Car.mtl").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("A/Car.mtl").path))
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("shared lib.mtl").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("A/shared lib.mtl").path))
    }

    func testNameHelpers() {
        XCTAssertEqual(LibraryFileService.sanitizedName(" .hidden "), "hidden")
        XCTAssertNil(LibraryFileService.sanitizedName("   "))
        XCTAssertEqual(LibraryPaths.remap("/a/b/c", from: "/a/b", to: "/a/x"), "/a/x/c")
        XCTAssertEqual(LibraryPaths.remap("/a/bb", from: "/a/b", to: "/a/x"), "/a/bb")
        XCTAssertTrue(LibraryPaths.isSameOrInside("/a/b", "/a/b"))
        XCTAssertFalse(LibraryPaths.isSameOrInside("/a/bc", "/a/b"))
        XCTAssertEqual(item("Part.gcode.3mf").displayName, "Part.gcode")
        XCTAssertEqual(item("readme.txt").displayName, "readme.txt")
    }

    // MARK: - Duplicates

    func testDuplicateFinderGroupsIdenticalFiles() throws {
        let collection = try makeFolder("C")
        try makeFile("C/Hook.3mf", contents: "same")
        try makeFile("C/Hook(2).3mf", contents: "same")
        try makeFile("C/Other/Hook — копия.3mf", contents: "same")
        try makeFile("C/Different.3mf", contents: "diff")   // same size, other contents
        try makeFile("C/Big.3mf", contents: "unique contents")

        let files = LibraryScanner.scan(roots: [collection]).files
        var lastProgress = 0.0
        let groups = DuplicateFinder.find(in: files) { lastProgress = $0 }

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.files.count, 3)
        XCTAssertEqual(group.suggestedKeeper.displayName, "Hook")
        XCTAssertEqual(group.redundantBytes, 8)
        XCTAssertEqual(lastProgress, 1, accuracy: 1e-9)
    }

    func testCopyNames() {
        XCTAssertTrue(DuplicateFinder.looksLikeCopy("Hook(2)"))
        XCTAssertTrue(DuplicateFinder.looksLikeCopy("Hook (3)"))
        XCTAssertTrue(DuplicateFinder.looksLikeCopy("Board\u{00A0}— копия"))
        XCTAssertTrue(DuplicateFinder.looksLikeCopy("Board copy 2"))
        XCTAssertFalse(DuplicateFinder.looksLikeCopy("Seed_Spacer_2025-Nov-09"))
        XCTAssertFalse(DuplicateFinder.looksLikeCopy("装配体2"))

        // Without copy markers the oldest file is kept.
        let old = item("B.3mf", modified: 100), new = item("A.3mf", modified: 200)
        XCTAssertTrue(DuplicateFinder.keepOrder(old, new))
    }

    // MARK: - Cost

    func testPrintCost() throws {
        var settings = PrintCostSettings(currencyCode: "RUB", pricePerKg: ["PLA": 1500, "PETG": 2000],
                                         otherPricePerKg: 1000, hourlyRate: 20)
        XCTAssertEqual(settings.pricePerKg(forType: "pla"), 1500)
        XCTAssertEqual(settings.pricePerKg(forType: "PLA-CF"), 1500)   // variant → base type
        XCTAssertEqual(settings.pricePerKg(forType: "PETG HF"), 2000)
        XCTAssertEqual(settings.pricePerKg(forType: "TPU"), 1000)
        XCTAssertEqual(settings.pricePerKg(forType: nil), 1000)

        let cost = try XCTUnwrap(PrintCostCalculator.cost(filamentGrams: ["PLA": 100, "PETG": 50, "": 10],
                                                          printTime: 5400, settings: settings))
        XCTAssertEqual(cost.material, 150 + 100 + 10, accuracy: 1e-9)
        XCTAssertEqual(cost.machine, 30, accuracy: 1e-9)
        XCTAssertEqual(cost.total, 290, accuracy: 1e-9)

        settings.hourlyRate = 0
        XCTAssertEqual(PrintCostCalculator.cost(filamentGrams: [:], printTime: 3600, settings: settings)?.total, 0)
        XCTAssertNil(PrintCostCalculator.cost(filamentGrams: [:], printTime: nil, settings: settings))

        XCTAssertEqual(PrintCostSettings.defaults(currencyCode: "RUB").pricePerKg["PLA"], 1500)
        XCTAssertEqual(PrintCostSettings.defaults(currencyCode: "EUR").pricePerKg["PLA"], 20)
    }

    // MARK: - Tags, notes, filters, build volume

    func testFinderTagsAndNotes() throws {
        let url = try makeFile("C/Hook.3mf")
        XCTAssertEqual(LibraryTags.tags(of: url), [])

        var tags = LibraryTags.setting(LibraryTags.favoriteNames, on: true, name: "Favorite", in: [])
        tags = LibraryTags.adding("  Kitchen ", to: tags)
        tags = LibraryTags.adding("kitchen", to: tags)   // case-insensitive duplicate
        try LibraryTags.setTags(tags, for: url)
        XCTAssertEqual(Set(LibraryTags.tags(of: url)), ["Favorite", "Kitchen"])

        let scanned = try XCTUnwrap(LibraryScanner.scan(roots: [root.appendingPathComponent("C")]).files.first)
        XCTAssertTrue(scanned.isFavorite)
        XCTAssertFalse(scanned.isPrinted)
        XCTAssertEqual(scanned.userTags, ["Kitchen"])

        let unfavorited = LibraryTags.setting(LibraryTags.favoriteNames, on: false, name: "Favorite", in: ["Избранное", "A"])
        XCTAssertEqual(unfavorited, ["A"])

        XCTAssertNil(LibraryTags.note(of: url))
        try LibraryTags.setNote("PETG, 0.2, no supports", for: url)
        XCTAssertEqual(LibraryTags.note(of: url), "PETG, 0.2, no supports")
        try LibraryTags.setNote("  ", for: url)
        XCTAssertNil(LibraryTags.note(of: url))
        try LibraryTags.setNote(nil, for: url)   // removing a missing note is fine
    }

    func testInboxScanGoesOneLevelDeep() throws {
        let inbox = try makeFolder("Downloads")
        try makeFile("Downloads/New.3mf")
        try makeFile("Downloads/Pack/Part.stl")
        try makeFile("Downloads/Pack/Deeper/Hidden.3mf")
        try makeFile("Downloads/readme.pdf")
        let files = LibraryScanner.scanInbox(inbox)
        XCTAssertEqual(Set(files.map(\.displayName)), ["New", "Part"])
    }

    func testBuildVolumeFit() {
        let bed = BuildVolume(width: 250, depth: 210, height: 220)
        XCTAssertTrue(bed.fits(SIMD3(240, 200, 100)))
        XCTAssertTrue(bed.fits(SIMD3(200, 240, 100)))    // turned by 90°
        XCTAssertFalse(bed.fits(SIMD3(240, 240, 100)))
        XCTAssertFalse(bed.fits(SIMD3(100, 100, 230)))
        XCTAssertNil(bed.fits(plateSizes: []))
        XCTAssertEqual(bed.fits(plateSizes: [SIMD3(10, 10, 10), SIMD3(300, 10, 10)]), false)
        // The outline turns only for a part that fits only when turned.
        XCTAssertEqual(bed.outline(for: SIMD3(240, 200, 100)), SIMD3(250, 210, 220))
        XCTAssertEqual(bed.outline(for: SIMD3(200, 240, 100)), SIMD3(210, 250, 220))
        XCTAssertEqual(bed.outline(for: SIMD3(300, 300, 100)), SIMD3(250, 210, 220))
        XCTAssertEqual(bed.outline(for: nil), SIMD3(250, 210, 220))
        XCTAssertEqual(Set(BuildVolume.presets.map(\.id)).count, BuildVolume.presets.count)
    }

    func testFiltersAndSearchInDetails() {
        let hook = item("Hook.3mf"), vase = item("Vase.3mf"), big = item("Big.3mf"), raw = item("Raw.stl")
        let facts: [String: FileFacts] = [
            hook.id: FileFacts(printTime: 1800,
                               details: ModelDetails(title: "Wall hook", designer: "Kong 3D", filamentTypes: ["PLA"], colorCount: 1),
                               fits: true),
            vase.id: FileFacts(printTime: 5 * 3600,
                               details: ModelDetails(descriptionText: "Spiral vase mode", filamentTypes: ["PETG", "PLA"], colorCount: 3),
                               fits: true),
            big.id: FileFacts(printTime: 10 * 3600, details: ModelDetails(colorCount: 1), fits: false),
            raw.id: FileFacts(details: ModelDetails(colorCount: 1, plateSizes: [[10, 10, 10]]), fits: true),
        ]
        let files = [hook, vase, big, raw]
        func names(_ configure: (inout LibraryQuery) -> Void) -> [String] {
            var query = LibraryQuery()
            configure(&query)
            return query.apply(to: files) { facts[$0.id] ?? FileFacts() }.map(\.displayName)
        }

        XCTAssertEqual(names { $0.searchText = "kong" }, ["Hook"])
        XCTAssertEqual(names { $0.searchText = "SPIRAL" }, ["Vase"])
        XCTAssertEqual(names { $0.filters.printTime = .upTo1h }, ["Hook"])
        XCTAssertEqual(names { $0.filters.printTime = .over8h }, ["Big"])
        XCTAssertEqual(names { $0.filters.slicing = .notSliced }, ["Raw"])
        XCTAssertEqual(names { $0.filters.filamentType = "PETG" }, ["Vase"])
        XCTAssertEqual(names { $0.filters.colors = .multi }, ["Vase"])
        XCTAssertEqual(names { $0.filters.fit = .tooBig }, ["Big"])
        XCTAssertEqual(names {
            $0.filters.fit = .fits
            $0.filters.colors = .single
        }, ["Hook", "Raw"])

        var filters = LibraryFilters()
        XCTAssertEqual(filters.activeCount, 0)
        filters.favoritesOnly = true
        filters.filamentType = "PLA"
        XCTAssertEqual(filters.activeCount, 2)
    }

    func testDetailsStoreRoundTrip() throws {
        let file = item("A.3mf", size: 5, modified: 10)
        var store = ModelDetailsStore()
        store.store([ModelDetailsStore.Entry(fileID: file.id, cacheKey: file.cacheKey,
                                             details: ModelDetails(title: "A", filamentTypes: ["PLA"], colorCount: 2))])
        let cache = root.appendingPathComponent("cache/details.json")
        store.save(to: cache)
        let loaded = ModelDetailsStore.load(from: cache)
        XCTAssertEqual(loaded.details(for: file)?.title, "A")
        XCTAssertEqual(loaded.details(for: file)?.colorCount, 2)
        XCTAssertNil(loaded.details(for: item("A.3mf", size: 6, modified: 10)))
    }

    // MARK: - Preferences & summaries

    func testPreferencesRoundTrip() throws {
        let suite = "ThreeMFLibraryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LibraryPreferences(defaults: defaults)

        XCTAssertEqual(preferences.sortOrder, .name)
        XCTAssertNil(preferences.legacyFolder)
        preferences.collections = [root]
        preferences.expandedCategories = ["/x", "/y"]
        preferences.sortOrder = .printTime
        preferences.selectedCategory = "/x"

        let reloaded = LibraryPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.collections.map(\.path), [root.path])
        XCTAssertEqual(reloaded.expandedCategories, ["/x", "/y"])
        XCTAssertEqual(reloaded.sortOrder, .printTime)
        XCTAssertEqual(reloaded.selectedCategory, "/x")
    }

    func testSliceSummaryStoreTracksFileVersions() {
        let file = item("A.3mf", size: 10, modified: 100)
        var store = SliceSummaryStore()
        XCTAssertEqual(store.filesNeedingUpdate([file]).count, 1)

        let summary = SliceSummary(printTime: 90, weight: 3, slicedPlates: 1)
        store.store([SliceSummaryStore.Entry(fileID: file.id, cacheKey: file.cacheKey, summary: summary)])
        XCTAssertEqual(store.summary(for: file)?.printTime, 90)
        XCTAssertTrue(store.filesNeedingUpdate([file]).isEmpty)

        // The file changed on disk: the old summary no longer applies.
        let changed = item("A.3mf", size: 11, modified: 100)
        XCTAssertNil(store.summary(for: changed))
        XCTAssertEqual(store.filesNeedingUpdate([changed]).count, 1)
    }
}
