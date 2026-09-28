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
        let byTime = LibraryQuery(sortOrder: .printTime).apply(to: files) { times[$0.id] }
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
