import Foundation
import ThreeMFKit

/// What the library knows about a model after reading it completely: texts for searching, filaments,
/// colours and sizes for filters. Built in the background and cached on disk.
public struct ModelDetails: Codable, Equatable, Sendable {
    public var title: String?
    public var designer: String?
    /// The author's description as plain text (shortened), for searching.
    public var descriptionText: String?
    /// Upper-case types of the filaments the model is printed with ("PLA", "PETG").
    public var filamentTypes: [String]
    /// Number of different colours the model uses (0 = unknown).
    public var colorCount: Int
    /// Size in mm (x, y, z) of each plate, or of the whole model; empty when there is no geometry.
    public var plateSizes: [[Double]]

    public init(title: String? = nil, designer: String? = nil, descriptionText: String? = nil,
                filamentTypes: [String] = [], colorCount: Int = 0, plateSizes: [[Double]] = []) {
        self.title = title
        self.designer = designer
        self.descriptionText = descriptionText
        self.filamentTypes = filamentTypes
        self.colorCount = colorCount
        self.plateSizes = plateSizes
    }

    public var plateSizeVectors: [SIMD3<Double>] {
        plateSizes.compactMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
    }

    /// Whether any of the texts contains `query` (case- and diacritic-insensitive).
    public func matches(_ query: String) -> Bool {
        [title, designer, descriptionText].contains { text in
            text?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

public enum ModelDetailsReader {
    /// Longest description kept for searching.
    static let maxDescriptionLength = 4000
    /// Bigger files are not loaded completely (that would take gigabytes of memory): only their slicer data is read.
    static let maxFullReadSize: Int64 = 256 * 1024 * 1024

    /// Reads the whole file (blocking — call off the main thread). nil when it cannot be read.
    public static func read(url: URL) -> ModelDetails? {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if size > maxFullReadSize {
            return ModelFileFormat(url: url) == .threeMF ? slicerDetails(url: url) : ModelDetails()
        }
        do {
            return details(of: try ModelReader.load(url: url))
        } catch ThreeMFError.missingModel {
            // A sliced ".gcode.3mf" without a model part: only the slicer data is there.
            return slicerDetails(url: url)
        } catch {
            return nil
        }
    }

    /// Filament types and colours from the slicer data only (no sizes).
    private static func slicerDetails(url: URL) -> ModelDetails? {
        guard let project = try? ThreeMFReader.printProject(url: url) else { return nil }
        let usages = project.totalFilaments
        return ModelDetails(filamentTypes: normalizedTypes(usages.compactMap(\.type)),
                            colorCount: Set(usages.compactMap(\.color)).count)
    }

    static func details(of model: ThreeMFModel) -> ModelDetails {
        func text(_ name: String) -> String? {
            guard let value = model.metadataValue(name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        var details = ModelDetails()
        details.title = text("Title")
        details.designer = text("Designer")
        details.descriptionText = text("Description").map {
            String(ThreeMFReader.plainText(fromHTML: $0).prefix(maxDescriptionLength))
        }.flatMap { $0.isEmpty ? nil : $0 }

        // Colours and filament slots that the model really uses.
        var colors = Set<RGBAColor>()
        var slots = Set<Int>()
        for instance in model.instances where instance.mesh.triangleCount > 0 {
            if let extruder = instance.extruder { slots.insert(extruder) }
            for source in instance.mesh.palette {
                if case .extruder(let slot) = source { slots.insert(slot) }
            }
            colors.formUnion(model.resolvedColors(for: instance).compactMap { $0 })
        }
        details.colorCount = colors.isEmpty ? (model.triangleCount > 0 ? 1 : 0) : colors.count

        let project = model.project
        if !project.slicedPlates.isEmpty {
            details.filamentTypes = normalizedTypes(project.totalFilaments.compactMap(\.type))
        } else {
            let types = slots.sorted().compactMap { slot in
                slot >= 1 && slot <= project.filamentTypes.count ? project.filamentTypes[slot - 1] : nil
            }
            details.filamentTypes = normalizedTypes(types)
        }

        var sizes: [SIMD3<Double>] = []
        if project.plates.count > 1 {
            for plate in project.plates {
                let onPlate = model.onPlate(plate.index)
                if onPlate.triangleCount > 0, let size = onPlate.sizeInMillimeters { sizes.append(size) }
            }
        } else if model.triangleCount > 0, let size = model.sizeInMillimeters {
            sizes.append(size)
        }
        details.plateSizes = sizes.map { [rounded($0.x), rounded($0.y), rounded($0.z)] }
        return details
    }

    static func normalizedTypes(_ types: [String]) -> [String] {
        Array(Set(types.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })).sorted()
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

/// Details of every file, remembered per file version and saved between launches.
public struct ModelDetailsStore: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let fileID: String
        public let cacheKey: String
        public let details: ModelDetails?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func details(for file: ModelFileItem) -> ModelDetails? {
        guard let entry = entries[file.id], entry.cacheKey == file.cacheKey else { return nil }
        return entry.details
    }

    public func filesNeedingUpdate(_ files: [ModelFileItem]) -> [ModelFileItem] {
        files.filter { entries[$0.id]?.cacheKey != $0.cacheKey }
    }

    public mutating func store(_ newEntries: [Entry]) {
        for entry in newEntries { entries[entry.fileID] = entry }
    }

    /// Forgets files that are no longer in the library (keeps the cache file small).
    public mutating func keepOnly(_ files: [ModelFileItem]) {
        let ids = Set(files.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }

    public static func read(_ files: [ModelFileItem]) -> [Entry] {
        files.map { Entry(fileID: $0.id, cacheKey: $0.cacheKey, details: ModelDetailsReader.read(url: $0.url)) }
    }

    // MARK: - Disk cache

    public static func load(from url: URL) -> ModelDetailsStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(ModelDetailsStore.self, from: data) else { return ModelDetailsStore() }
        return store
    }

    public func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
