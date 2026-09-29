import Foundation

/// A photo stored in the file by the model's author (MakerWorld puts them into `Auxiliaries/`).
public struct ModelPhoto: Identifiable, Hashable, Sendable {
    /// Path inside the archive.
    public let path: String
    public let data: Data

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// What the author published together with the model: photos, description and print profile notes.
public struct ModelExtras: Sendable {
    public var photos: [ModelPhoto] = []
    /// Plain text (converted from the HTML that MakerWorld stores).
    public var description: String?
    /// Name of the print profile, e.g. "0.16mm layer, 2 walls, 15% infill".
    public var profileTitle: String?
    public var profileDescription: String?

    public init() {}

    public var hasDescription: Bool {
        description != nil || profileTitle != nil || profileDescription != nil
    }

    public var isEmpty: Bool { photos.isEmpty && !hasDescription }
}

extension ThreeMFReader {
    /// Readable text from the HTML that slicers and MakerWorld store in metadata such as "Description".
    public static func plainText(fromHTML html: String) -> String {
        HTMLText.plainText(html)
    }

    /// Photos from `Auxiliaries/` and the texts from `metadata` (`ThreeMFModel.metadata`).
    public static func extras(url: URL, metadata: [MetadataEntry]) throws -> ModelExtras {
        try extras(archive: ZipArchive(url: url), metadata: metadata)
    }

    static func extras(archive: ZipArchive, metadata: [MetadataEntry]) -> ModelExtras {
        var extras = ModelExtras()
        extras.photos = photos(in: archive)

        func text(_ name: String) -> String? {
            guard let value = metadata.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value else {
                return nil
            }
            let plain = HTMLText.plainText(value)
            return plain.isEmpty ? nil : plain
        }
        extras.description = text("Description")
        extras.profileTitle = text("ProfileTitle")
        extras.profileDescription = text("ProfileDescription")
        return extras
    }

    /// Author's photos: "Model Pictures" first, then "Profile Pictures" and the rest; the slicer's own
    /// thumbnails (`.thumbnails`) are skipped, and so are copies with the same name and size.
    static func photos(in archive: ZipArchive) -> [ModelPhoto] {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
        func rank(_ path: String) -> Int {
            let lower = path.lowercased()
            if lower.contains("/model pictures/") { return 0 }
            if lower.contains("/profile pictures/") { return 1 }
            return 2
        }
        let entries = archive.entries
            .filter { entry in
                let lower = entry.path.lowercased()
                return lower.hasPrefix("auxiliaries/")
                    && !lower.contains("/.thumbnails/")
                    && imageExtensions.contains((lower as NSString).pathExtension)
                    && entry.uncompressedSize > 0
            }
            .sorted { rank($0.path) != rank($1.path) ? rank($0.path) < rank($1.path) : $0.path < $1.path }

        var seen = Set<String>()
        var photos: [ModelPhoto] = []
        for entry in entries {
            let key = "\((entry.path as NSString).lastPathComponent.lowercased())|\(entry.uncompressedSize)"
            guard seen.insert(key).inserted, let data = try? archive.contents(of: entry) else { continue }
            photos.append(ModelPhoto(path: entry.path, data: data))
        }
        return photos
    }
}

/// Turns the HTML of model descriptions into readable plain text (no network, no WebKit).
enum HTMLText {
    static func plainText(_ html: String) -> String {
        var text = html
        // Descriptions are sometimes escaped twice.
        for _ in 0 ..< 2 where text.contains("&lt;") || text.contains("&#60;") {
            text = decodeEntities(text)
        }
        let replacements: [(String, String)] = [
            ("(?is)<(script|style)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)<li[^>]*>", "\n• "),
            ("(?i)</(p|div|h[1-6]|tr|ul|ol|figure|blockquote)>", "\n"),
            ("(?i)<(p|div|h[1-6]|tr|ul|ol|blockquote)(\\s[^>]*)?>", "\n"),
            ("<[^>]+>", ""),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
        }
        // At most one empty line between paragraphs.
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                     "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»", "reg": "®",
                     "copy": "©", "trade": "™", "deg": "°", "times": "×", "rsquo": "’", "lsquo": "‘",
                     "rdquo": "”", "ldquo": "“", "bull": "•"]
        var result = ""
        var index = string.startIndex
        while let amp = string[index...].firstIndex(of: "&") {
            result += string[index ..< amp]
            guard let semicolon = string[amp...].prefix(12).firstIndex(of: ";") else {
                result += "&"
                index = string.index(after: amp)
                continue
            }
            let entity = string[string.index(after: amp) ..< semicolon]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity.lowercased()]
            }
            if let replacement {
                result += replacement
                index = string.index(after: semicolon)
            } else {
                result += "&"
                index = string.index(after: amp)
            }
        }
        result += string[index...]
        return result
    }
}
