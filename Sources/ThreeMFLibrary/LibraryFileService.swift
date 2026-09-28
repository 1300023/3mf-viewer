import Foundation
import ThreeMFKit

public enum LibraryError: Error, LocalizedError, Equatable {
    case invalidName
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return NSLocalizedString("The name is not valid.", comment: "")
        case .alreadyExists(let name):
            return String(format: NSLocalizedString("A category named “%@” already exists.", comment: ""), name)
        }
    }
}

/// File operations behind collections: categories are folders, models are files.
public struct LibraryFileService {
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Categories

    @discardableResult
    public func createCategory(named rawName: String, in parent: URL) throws -> URL {
        guard let name = Self.sanitizedName(rawName) else { throw LibraryError.invalidName }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path) else { throw LibraryError.alreadyExists(name) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url.standardizedFileURL
    }

    /// Renames a category folder. Returns the new URL (the old one when the name did not change).
    @discardableResult
    public func renameCategory(at url: URL, to rawName: String) throws -> URL {
        guard let name = Self.sanitizedName(rawName) else { throw LibraryError.invalidName }
        guard name != url.lastPathComponent else { return url }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        // A change of letter case only is allowed on case-insensitive volumes.
        if fileManager.fileExists(atPath: destination.path),
           destination.path.lowercased() != url.path.lowercased() {
            throw LibraryError.alreadyExists(name)
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination.standardizedFileURL
    }

    /// Moves a folder (with everything inside) or a file to the Trash.
    public func trash(_ url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Models

    /// Moves a model to the Trash. An OBJ's own material library ("Model.mtl" next to "Model.obj") goes with it.
    public func trashModel(_ url: URL) throws {
        let ownLibraries = Self.materialLibraries(of: url, fileManager: fileManager).filter { Self.isOwnLibrary($0, of: url) }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
        for library in ownLibraries { try? fileManager.trashItem(at: library, resultingItemURL: nil) }
    }

    /// Moves or copies a model file or a folder into `folder`, renaming it ("Model 2.3mf") when the name is taken.
    /// OBJ files keep their colours: the own "Model.mtl" travels with the model, shared libraries are copied.
    @discardableResult
    public func transfer(_ url: URL, into folder: URL, move: Bool) throws -> URL {
        let destination = Self.uniqueDestination(for: url.lastPathComponent, in: folder, fileManager: fileManager)
        try transferMaterialLibraries(of: url, to: folder, move: move)
        if move {
            try fileManager.moveItem(at: url, to: destination)
        } else {
            try fileManager.copyItem(at: url, to: destination)
        }
        return destination.standardizedFileURL
    }

    private func transferMaterialLibraries(of url: URL, to folder: URL, move: Bool) throws {
        for library in Self.materialLibraries(of: url, fileManager: fileManager) {
            let destination = folder.appendingPathComponent(library.lastPathComponent)
            // A library with the same name already there is left alone.
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            if move && Self.isOwnLibrary(library, of: url) {
                try fileManager.moveItem(at: library, to: destination)
            } else {
                try fileManager.copyItem(at: library, to: destination)
            }
        }
    }

    // MARK: - Helpers

    public func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Trims the name and replaces characters that are not allowed in folder names. nil when nothing is left.
    public static func sanitizedName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// "Model.3mf" → "Model 2.3mf" (or "Folder" → "Folder 2") when the name is taken.
    public static func uniqueDestination(for name: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            number += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Material libraries (`mtllib`) an OBJ file refers to, if they exist next to it.
    public static func materialLibraries(of url: URL, fileManager: FileManager = .default) -> [URL] {
        guard ModelFileFormat(url: url) == .obj,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        // `mtllib` is normally among the first lines.
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return [] }
        let folder = url.deletingLastPathComponent()
        var result: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("mtllib ") || trimmed.hasPrefix("mtllib\t") else { continue }
            let argument = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            // File names may contain spaces; several libraries may be listed on one line.
            let candidates = [argument] + argument.split(separator: " ").map(String.init)
            for name in candidates where !name.contains("/") {
                let file = folder.appendingPathComponent(name)
                if fileManager.fileExists(atPath: file.path), !result.contains(file) {
                    result.append(file)
                    break
                }
            }
        }
        return result
    }

    /// "Model.mtl" belongs to "Model.obj"; any other library may be shared by several models.
    static func isOwnLibrary(_ library: URL, of model: URL) -> Bool {
        library.deletingPathExtension().lastPathComponent == model.deletingPathExtension().lastPathComponent
    }
}
