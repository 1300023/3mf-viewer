import Foundation
import ThreeMFKit

/// Print time / weight of sliced projects, remembered per file version (`ModelFileItem.cacheKey`).
public struct SliceSummaryStore: Sendable {
    public struct Entry: Sendable {
        public let fileID: String
        public let cacheKey: String
        public let summary: SliceSummary?
    }

    private var summaries: [String: SliceSummary] = [:]
    /// File id → the cache key the stored result (or the absence of one) belongs to.
    private var keys: [String: String] = [:]

    public init() {}

    public func summary(for file: ModelFileItem) -> SliceSummary? {
        keys[file.id] == file.cacheKey ? summaries[file.id] : nil
    }

    /// Files that are new or changed since their summary was read.
    public func filesNeedingUpdate(_ files: [ModelFileItem]) -> [ModelFileItem] {
        files.filter { keys[$0.id] != $0.cacheKey }
    }

    public mutating func store(_ entries: [Entry]) {
        for entry in entries {
            keys[entry.fileID] = entry.cacheKey
            summaries[entry.fileID] = entry.summary
        }
    }

    /// Reads `slice_info.config` of each file (blocking I/O — call off the main thread).
    public static func read(_ files: [ModelFileItem]) -> [Entry] {
        files.map { Entry(fileID: $0.id, cacheKey: $0.cacheKey, summary: ThreeMFReader.sliceSummary(url: $0.url)) }
    }
}
