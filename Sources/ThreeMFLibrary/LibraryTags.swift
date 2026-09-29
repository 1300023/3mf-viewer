import Darwin
import Foundation

/// Favourites, "printed" marks and the user's tags are ordinary Finder tags, so they show up in Finder and
/// Spotlight and travel with the file. The note is kept in the file's Spotlight comment attribute.
public enum LibraryTags {
    /// Accepted names of the favourite tag (the first one of the interface language is written).
    public static let favoriteNames = ["Favorite", "Избранное"]
    public static let printedNames = ["Printed", "Напечатано"]

    public static func isFavorite(_ tags: [String]) -> Bool { tags.contains { favoriteNames.contains($0) } }
    public static func isPrinted(_ tags: [String]) -> Bool { tags.contains { printedNames.contains($0) } }
    public static func isSystemTag(_ tag: String) -> Bool { favoriteNames.contains(tag) || printedNames.contains(tag) }

    /// Tags after switching a marker on or off. `name` is the tag written when switching on.
    public static func setting(_ names: [String], on: Bool, name: String, in tags: [String]) -> [String] {
        var result = tags.filter { !names.contains($0) }
        if on { result.append(name) }
        return result
    }

    /// Adds a tag (ignoring case duplicates); returns the tags unchanged for an empty name.
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return tags
        }
        return tags + [trimmed]
    }

    // MARK: - Reading and writing

    public static func tags(of url: URL) -> [String] {
        // A fresh URL: URL objects cache resource values.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    public static func setTags(_ tags: [String], for url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// Extended attribute that Spotlight indexes as the file's comment.
    static let noteAttribute = "com.apple.metadata:kMDItemComment"

    public static func note(of url: URL) -> String? {
        let length = getxattr(url.path, noteAttribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, noteAttribute, $0.baseAddress, length, 0, 0) }
        guard read > 0 else { return nil }
        let value = try? PropertyListSerialization.propertyList(from: data.prefix(read), format: nil)
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves the note; an empty note removes the attribute.
    public static func setNote(_ note: String?, for url: URL) throws {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            if removexattr(url.path, noteAttribute, 0) != 0, errno != ENOATTR { throw posixError() }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, noteAttribute, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { throw posixError() }
    }

    private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
