import Foundation
import ThreeMFKit

/// A model file found in a collection.
public struct ModelFileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    /// Root folder of the collection that contains the file.
    public let collectionPath: String
    /// Category path inside the collection ("" = collection root), e.g. "Kitchen/Hooks".
    public let relativeFolder: String

    public init(url: URL, size: Int64, modified: Date, collectionPath: String, relativeFolder: String) {
        self.url = url
        self.size = size
        self.modified = modified
        self.collectionPath = collectionPath
        self.relativeFolder = relativeFolder
    }

    public var id: String { url.path }
    public var folderPath: String { url.deletingLastPathComponent().path }
    public var format: ModelFileFormat? { ModelFileFormat(url: url) }

    /// File name without the model extension ("Hook.3mf" → "Hook", "Part.gcode.3mf" → "Part.gcode").
    public var displayName: String {
        let name = url.lastPathComponent
        return format != nil ? (name as NSString).deletingPathExtension : name
    }

    /// Changes whenever the file changes — used for caching thumbnails and slicing summaries.
    public var cacheKey: String { "\(url.path)|\(size)|\(Int(modified.timeIntervalSince1970))" }
}

/// A collection (root folder) or a category (any subfolder of it). The folder tree on disk *is* the category tree.
public struct CategoryNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isCollection: Bool
    /// False when a collection's folder is missing (e.g. an external disk is not connected).
    public let isAvailable: Bool
    public var children: [CategoryNode]
    /// Number of models in this folder and all of its subfolders.
    public var modelCount: Int

    public init(url: URL, name: String, isCollection: Bool, isAvailable: Bool,
                children: [CategoryNode] = [], modelCount: Int = 0) {
        self.url = url
        self.name = name
        self.isCollection = isCollection
        self.isAvailable = isAvailable
        self.children = children
        self.modelCount = modelCount
    }

    public var id: String { url.path }

    /// True for this folder's own path and every path inside it.
    public func contains(path: String) -> Bool {
        LibraryPaths.isSameOrInside(path, id)
    }
}

/// One visible row of the sidebar tree.
public struct SidebarRow: Identifiable, Hashable, Sendable {
    public let node: CategoryNode
    public let depth: Int

    public init(node: CategoryNode, depth: Int) {
        self.node = node
        self.depth = depth
    }

    public var id: String { node.id }
}

public enum CategoryTree {
    /// Every node of the tree by its id (folder path).
    public static func index(_ nodes: [CategoryNode]) -> [String: CategoryNode] {
        var index: [String: CategoryNode] = [:]
        func add(_ nodes: [CategoryNode]) {
            for node in nodes {
                index[node.id] = node
                add(node.children)
            }
        }
        add(nodes)
        return index
    }

    /// Rows of the sidebar: children are listed only under expanded nodes.
    public static func visibleRows(_ nodes: [CategoryNode], expanded: Set<String>) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        func add(_ nodes: [CategoryNode], depth: Int) {
            for node in nodes {
                rows.append(SidebarRow(node: node, depth: depth))
                if expanded.contains(node.id) { add(node.children, depth: depth + 1) }
            }
        }
        add(nodes, depth: 0)
        return rows
    }
}

public enum LibraryPaths {
    /// `path` equals `folder` or lies somewhere inside it.
    public static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// Rewrites `path` after the folder `old` was moved or renamed to `new`.
    public static func remap(_ path: String, from old: String, to new: String) -> String {
        if path == old { return new }
        if path.hasPrefix(old + "/") { return new + String(path.dropFirst(old.count)) }
        return path
    }
}
