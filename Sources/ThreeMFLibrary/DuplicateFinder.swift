import CryptoKit
import Foundation

/// Model files with identical contents.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    /// The suggested file to keep comes first (see `DuplicateFinder.keepOrder`).
    public let files: [ModelFileItem]
    /// SHA-256 of the contents.
    public let contentHash: String

    public init(files: [ModelFileItem], contentHash: String) {
        self.files = files
        self.contentHash = contentHash
    }

    public var id: String { contentHash }
    public var suggestedKeeper: ModelFileItem { files[0] }
    /// Space freed by keeping one copy.
    public var redundantBytes: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

/// Finds identical model files: only files of equal size are read, then compared by SHA-256.
public enum DuplicateFinder {
    /// Stops early (returning what was found so far) when the calling task is cancelled.
    public static func find(in files: [ModelFileItem], progress: ((Double) -> Void)? = nil) -> [DuplicateGroup] {
        let candidates = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 && $0[0].size > 0 }
        let total = candidates.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        for sameSize in candidates {
            if Task.isCancelled { break }
            var byHash: [String: [ModelFileItem]] = [:]
            for file in sameSize {
                if let hash = contentHash(of: file.url) { byHash[hash, default: []].append(file) }
                done += 1
                progress?(Double(done) / Double(max(total, 1)))
            }
            for (hash, identical) in byHash where identical.count > 1 {
                groups.append(DuplicateGroup(files: identical.sorted(by: keepOrder), contentHash: hash))
            }
        }
        // Biggest savings first.
        return groups.sorted {
            $0.redundantBytes != $1.redundantBytes
                ? $0.redundantBytes > $1.redundantBytes
                : $0.suggestedKeeper.displayName.localizedStandardCompare($1.suggestedKeeper.displayName) == .orderedAscending
        }
    }

    /// Which copy to keep: the one without a copy suffix ("Model (2)", "Model — копия"), then the oldest,
    /// then the shortest name.
    public static func keepOrder(_ a: ModelFileItem, _ b: ModelFileItem) -> Bool {
        let aCopy = looksLikeCopy(a.displayName), bCopy = looksLikeCopy(b.displayName)
        if aCopy != bCopy { return !aCopy }
        if a.modified != b.modified { return a.modified < b.modified }
        if a.displayName.count != b.displayName.count { return a.displayName.count < b.displayName.count }
        return a.id < b.id
    }

    /// "Model(2)", "Model (3)", "Model 2", "Model copy", "Model — копия 2"…
    public static func looksLikeCopy(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return copySuffix.firstMatch(in: trimmed, range: range) != nil
    }

    private static let copySuffix: NSRegularExpression = {
        let space = "[\\s\\u00A0]"
        let separator = "(\(space)+|\(space)*[—–-]\(space)*)"
        let pattern = "(\\(\\d+\\)|\(space)+\\d+|\(separator)(copy|копия|kopie|copie)(\(space)+\\d+)?)$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// SHA-256 of a file, read in 1 MB chunks.
    static func contentHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil (not empty data) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                if Task.isCancelled { return nil }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
