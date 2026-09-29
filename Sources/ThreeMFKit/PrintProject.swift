import Foundation

// MARK: - Public types

/// How much of one filament a sliced plate uses.
public struct FilamentUsage: Hashable, Sendable {
    /// 1-based filament slot in the project.
    public var slot: Int
    /// "PLA", "PETG", …
    public var type: String?
    public var color: RGBAColor?
    public var meters: Double?
    public var grams: Double?

    public init(slot: Int, type: String? = nil, color: RGBAColor? = nil, meters: Double? = nil, grams: Double? = nil) {
        self.slot = slot
        self.type = type
        self.color = color
        self.meters = meters
        self.grams = grams
    }
}

/// Slicing results that Bambu Studio / OrcaSlicer store for a plate (`Metadata/slice_info.config`).
public struct SliceInfo: Hashable, Sendable {
    /// Estimated print time in seconds.
    public var printTime: TimeInterval?
    /// Total filament weight in grams.
    public var weight: Double?
    public var filaments: [FilamentUsage] = []
    /// Bambu printer code, e.g. "C12" (P1S).
    public var printerModelID: String?
    public var nozzleDiameter: String?
    public var supportUsed: Bool?

    public init() {}

    /// Total filament length in metres.
    public var meters: Double? {
        let values = filaments.compactMap(\.meters)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

/// One build plate of a multi-plate project.
public struct PlateInfo: Identifiable, Sendable {
    /// 1-based plate number.
    public let index: Int
    public var name: String?
    /// Small PNG preview rendered by the slicer (for pickers).
    public var thumbnail: Data?
    /// Full-size PNG preview.
    public var image: Data?
    /// Number of printable objects on the plate.
    public var objectCount: Int = 0
    /// Present when the plate has been sliced.
    public var slice: SliceInfo?

    public var id: Int { index }

    public init(index: Int) { self.index = index }
}

/// Printer, profile and plate information from a slicer project. Empty for plain 3MF files.
public struct PrintProject: Sendable {
    /// "Bambu Lab P1S", "Original Prusa MK4", …
    public var printerName: String?
    public var nozzleDiameter: String?
    public var layerHeight: String?
    /// Filament types per slot ("PLA", "PETG", …).
    public var filamentTypes: [String] = []
    /// Plates in order. Empty when the file has no plate information.
    public var plates: [PlateInfo] = []

    public init() {}

    public var isEmpty: Bool {
        printerName == nil && nozzleDiameter == nil && layerHeight == nil && plates.isEmpty
    }

    public var slicedPlates: [PlateInfo] { plates.filter { $0.slice != nil } }

    /// Sum of the print times of all sliced plates.
    public var totalPrintTime: TimeInterval? {
        let times = plates.compactMap { $0.slice?.printTime }
        return times.isEmpty ? nil : times.reduce(0, +)
    }

    public var totalWeight: Double? {
        let values = plates.compactMap { $0.slice?.weight }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Grams per filament type over all sliced plates ("" = unknown type).
    public var totalGramsByType: [String: Double] {
        plates.compactMap(\.slice).reduce(into: [:]) { result, slice in
            result.merge(slice.gramsByType, uniquingKeysWith: +)
        }
    }

    /// Filament usage of all sliced plates, merged by slot.
    public var totalFilaments: [FilamentUsage] {
        Self.merge(plates.compactMap(\.slice).flatMap(\.filaments))
    }

    public func plate(_ index: Int) -> PlateInfo? { plates.first { $0.index == index } }

    static func merge(_ usages: [FilamentUsage]) -> [FilamentUsage] {
        var bySlot: [Int: FilamentUsage] = [:]
        for usage in usages {
            guard var merged = bySlot[usage.slot] else { bySlot[usage.slot] = usage; continue }
            if let m = usage.meters { merged.meters = (merged.meters ?? 0) + m }
            if let g = usage.grams { merged.grams = (merged.grams ?? 0) + g }
            merged.type = merged.type ?? usage.type
            merged.color = merged.color ?? usage.color
            bySlot[usage.slot] = merged
        }
        return bySlot.values.sorted { $0.slot < $1.slot }
    }
}

/// A lightweight summary used by the library list (print time sorting).
public struct SliceSummary: Hashable, Sendable {
    public var printTime: TimeInterval
    public var weight: Double?
    public var slicedPlates: Int
    /// Grams per filament type ("" = type unknown), for cost estimates.
    public var filamentGrams: [String: Double]
    /// The printer the project was sliced for (Bambu Lab printers), for its power use.
    public var printerName: String?

    public init(printTime: TimeInterval, weight: Double? = nil, slicedPlates: Int = 1,
                filamentGrams: [String: Double] = [:], printerName: String? = nil) {
        self.printTime = printTime
        self.weight = weight
        self.slicedPlates = slicedPlates
        self.filamentGrams = filamentGrams
        self.printerName = printerName
    }
}

extension FilamentUsage {
    /// Grams per filament type ("" = unknown). When no filament lists its grams, the whole `weight` counts as unknown.
    public static func gramsByType(_ usages: [FilamentUsage], weight: Double?) -> [String: Double] {
        var result: [String: Double] = [:]
        for usage in usages {
            guard let grams = usage.grams, grams > 0 else { continue }
            result[usage.type?.uppercased() ?? "", default: 0] += grams
        }
        if result.isEmpty, let weight, weight > 0 { result[""] = weight }
        return result
    }
}

extension SliceInfo {
    /// Grams per filament type of this plate.
    public var gramsByType: [String: Double] { FilamentUsage.gramsByType(filaments, weight: weight) }
}

// MARK: - Parsing

/// A plate as described in Bambu Studio / OrcaSlicer `Metadata/model_settings.config`.
struct BambuPlate {
    var index: Int
    var name: String?
    var thumbnailFile: String?
    /// (object id, instance number) pairs; the instance number counts build items with the same object id.
    var instances: [BambuInstanceRef] = []
}

struct BambuInstanceRef: Hashable {
    var objectID: Int
    var instanceID: Int
}

enum PrintProjectParser {
    static func parseBambuPlates(_ data: Data) -> [BambuPlate] {
        var plates: [BambuPlate] = []
        _ = try? XMLBytes.with(data) { doc in
            var plate: BambuPlate?
            var instance: (objectID: Int?, instanceID: Int?)?
            try doc.scan { tag in
                switch tag.kind {
                case .start, .empty:
                    if doc.equals(tag.name, "plate") {
                        plate = BambuPlate(index: plates.count + 1)
                        if tag.kind == .empty, let p = plate { plates.append(p); plate = nil }
                    } else if doc.equals(tag.name, "model_instance"), plate != nil {
                        instance = (nil, nil)
                    } else if doc.equals(tag.name, "metadata"), plate != nil {
                        guard let key = doc.attributeString(tag, "key") else { return }
                        let value = doc.attributeString(tag, "value") ?? ""
                        if instance != nil {
                            if key == "object_id" { instance?.objectID = Int(value) }
                            if key == "instance_id" { instance?.instanceID = Int(value) }
                        } else {
                            switch key {
                            case "plater_id": if let i = Int(value) { plate?.index = i }
                            case "plater_name": plate?.name = value.isEmpty ? nil : value
                            case "thumbnail_file": plate?.thumbnailFile = value.isEmpty ? nil : value
                            default: break
                            }
                        }
                    }
                case .end:
                    if doc.equals(tag.name, "model_instance") {
                        if let object = instance?.objectID {
                            plate?.instances.append(BambuInstanceRef(objectID: object, instanceID: instance?.instanceID ?? 0))
                        }
                        instance = nil
                    } else if doc.equals(tag.name, "plate") {
                        if let p = plate { plates.append(p) }
                        plate = nil
                    }
                }
            }
        }
        return plates
    }

    /// Parses `Metadata/slice_info.config`. Returns slice results keyed by plate number and, per plate,
    /// the number of objects that are not skipped.
    static func parseSliceInfo(_ data: Data) -> [Int: (info: SliceInfo, objects: Int)] {
        var result: [Int: (info: SliceInfo, objects: Int)] = [:]
        _ = try? XMLBytes.with(data) { doc in
            var inPlate = false
            var index: Int?
            var info = SliceInfo()
            var objects = 0
            try doc.scan { tag in
                switch tag.kind {
                case .start, .empty:
                    if doc.equals(tag.name, "plate") {
                        inPlate = tag.kind == .start
                        index = nil
                        info = SliceInfo()
                        objects = 0
                    } else if inPlate, doc.equals(tag.name, "metadata") {
                        guard let key = doc.attributeString(tag, "key") else { return }
                        let value = doc.attributeString(tag, "value") ?? ""
                        switch key {
                        case "index": index = Int(value)
                        case "prediction": info.printTime = Double(value)
                        case "weight": info.weight = Double(value)
                        case "printer_model_id": info.printerModelID = value.isEmpty ? nil : value
                        case "nozzle_diameters": info.nozzleDiameter = value.isEmpty ? nil : value
                        case "support_used": info.supportUsed = value == "true"
                        default: break
                        }
                    } else if inPlate, doc.equals(tag.name, "filament") {
                        let slot = doc.attributeInt(tag, "id") ?? (info.filaments.count + 1)
                        info.filaments.append(FilamentUsage(
                            slot: slot,
                            type: doc.attributeString(tag, "type").flatMap { $0.isEmpty ? nil : $0 },
                            color: doc.attributeString(tag, "color").flatMap(RGBAColor.init(hex:)),
                            meters: doc.attributeString(tag, "used_m").flatMap(Double.init),
                            grams: doc.attributeString(tag, "used_g").flatMap(Double.init)))
                    } else if inPlate, doc.equals(tag.name, "object") {
                        if doc.attributeString(tag, "skipped") != "true" { objects += 1 }
                    }
                case .end:
                    if doc.equals(tag.name, "plate") {
                        if let index { result[index] = (info, objects) }
                        inPlate = false
                    }
                }
            }
        }
        return result
    }

    /// Names of Bambu Lab printers for the codes used in `slice_info.config`.
    static func bambuPrinterName(code: String) -> String? {
        let names = [
            "BL-P001": "Bambu Lab X1 Carbon",
            "BL-P002": "Bambu Lab X1",
            "C13": "Bambu Lab X1E",
            "C11": "Bambu Lab P1P",
            "C12": "Bambu Lab P1S",
            "N7": "Bambu Lab P2S",
            "N1": "Bambu Lab A1 mini",
            "N2S": "Bambu Lab A1",
            "O1D": "Bambu Lab H2D",
        ]
        return names[code]
    }

    /// Reads everything except the meshes. `objectsPerPlate` comes from the build items when the model was loaded.
    static func project(archive: ZipArchive, settings: ProjectSettings,
                        bambuPlates: [BambuPlate], objectsPerPlate: [Int: Int]) -> PrintProject {
        var project = PrintProject()
        project.printerName = settings.printerName
        project.nozzleDiameter = settings.nozzleDiameter
        project.layerHeight = settings.layerHeight
        project.filamentTypes = settings.filamentTypes

        let slices = (try? archive.contents(path: "Metadata/slice_info.config"))
            .flatMap { $0 }
            .map(parseSliceInfo) ?? [:]

        var indices = Set(bambuPlates.map(\.index))
        indices.formUnion(slices.keys)
        for index in indices.sorted() {
            var plate = PlateInfo(index: index)
            let bambu = bambuPlates.first { $0.index == index }
            plate.name = bambu?.name
            plate.slice = slices[index]?.info
            plate.objectCount = objectsPerPlate[index] ?? slices[index]?.objects ?? bambu?.instances.count ?? 0

            let imagePath = bambu?.thumbnailFile ?? "Metadata/plate_\(index).png"
            plate.image = nonEmptyContents(archive, imagePath)
            let smallPath = imagePath.lowercased().hasSuffix(".png")
                ? String(imagePath.dropLast(4)) + "_small.png"
                : "Metadata/plate_\(index)_small.png"
            plate.thumbnail = nonEmptyContents(archive, smallPath) ?? plate.image
            project.plates.append(plate)
        }

        if project.printerName == nil,
           let code = project.plates.lazy.compactMap({ $0.slice?.printerModelID }).first {
            project.printerName = bambuPrinterName(code: code) ?? code
        }
        if project.nozzleDiameter == nil {
            project.nozzleDiameter = project.plates.lazy.compactMap { $0.slice?.nozzleDiameter }.first
        }
        return project
    }

    private static func nonEmptyContents(_ archive: ZipArchive, _ path: String) -> Data? {
        guard let entry = archive.entry(path), entry.uncompressedSize > 0 else { return nil }
        return try? archive.contents(of: entry)
    }
}
