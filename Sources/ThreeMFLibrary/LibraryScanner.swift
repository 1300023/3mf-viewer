import Foundation
import ThreeMFKit

/// The result of scanning the collections: the category tree and every model file in it.
public struct LibrarySnapshot: Sendable {
    public let tree: [CategoryNode]
    public let files: [ModelFileItem]
    /// Every category / collection by id (folder path).
    public let index: [String: CategoryNode]

    public init(tree: [CategoryNode], files: [ModelFileItem]) {
        self.tree = tree
        self.files = files
        self.index = CategoryTree.index(tree)
    }

    public static let empty = LibrarySnapshot(tree: [], files: [])
}

/// Walks collection folders. Hidden files, packages and symbolic links are skipped.
public enum LibraryScanner {
    /// Folders nested deeper than this are ignored.
    public static let maxDepth = 16

    /// Model files of an inbox folder such as ~/Downloads: the folder itself and its direct subfolders
    /// (downloaded archives are often unpacked into a folder).
    public static func scanInbox(_ folder: URL, fileManager: FileManager = .default) -> [ModelFileItem] {
        var files: [ModelFileItem] = []
        _ = scanFolder(folder, collection: folder, depth: 0, maxDepth: 1, fileManager: fileManager, files: &files)
        return files
    }

    public static func scan(roots: [URL], fileManager: FileManager = .default) -> LibrarySnapshot {
        var files: [ModelFileItem] = []
        var tree: [CategoryNode] = []
        for root in roots {
            if let node = scanFolder(root, collection: root, depth: 0, maxDepth: maxDepth,
                                     fileManager: fileManager, files: &files) {
                tree.append(node)
            } else {
                // The collection folder is gone (e.g. an external disk is not connected).
                tree.append(CategoryNode(url: root,
                                         name: fileManager.displayName(atPath: root.path),
                                         isCollection: true,
                                         isAvailable: false))
            }
        }
        return LibrarySnapshot(tree: tree, files: files)
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .tagNamesKey,
    ]

    private static func scanFolder(_ folder: URL, collection: URL, depth: Int, maxDepth: Int,
                                   fileManager: FileManager, files: inout [ModelFileItem]) -> CategoryNode? {
        guard let items = try? fileManager.contentsOfDirectory(at: folder,
                                                               includingPropertiesForKeys: resourceKeys,
                                                               options: [.skipsHiddenFiles]) else { return nil }
        var children: [CategoryNode] = []
        var count = 0
        let collectionPath = collection.path
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            if values.isDirectory == true {
                if values.isPackage == true || values.isSymbolicLink == true || depth >= maxDepth { continue }
                if let child = scanFolder(item, collection: collection, depth: depth + 1, maxDepth: maxDepth,
                                          fileManager: fileManager, files: &files) {
                    children.append(child)
                    count += child.modelCount
                }
            } else if values.isRegularFile == true, ModelFileFormat.isSupported(item) {
                let url = item.standardizedFileURL
                files.append(ModelFileItem(url: url,
                                           size: Int64(values.fileSize ?? 0),
                                           modified: values.contentModificationDate ?? .distantPast,
                                           collectionPath: collectionPath,
                                           relativeFolder: relativeFolder(of: url, in: collectionPath),
                                           tags: values.tagNames ?? []))
                count += 1
            }
        }
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let url = folder.standardizedFileURL
        let isCollection = depth == 0
        return CategoryNode(url: url,
                            name: isCollection ? fileManager.displayName(atPath: url.path) : url.lastPathComponent,
                            isCollection: isCollection,
                            isAvailable: true,
                            children: children,
                            modelCount: count)
    }

    /// "…/Collection/Kitchen/Hooks/file.3mf" → "Kitchen/Hooks".
    static func relativeFolder(of file: URL, in collectionPath: String) -> String {
        let parent = file.deletingLastPathComponent().path
        guard parent.hasPrefix(collectionPath) else { return "" }
        var relative = String(parent.dropFirst(collectionPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
