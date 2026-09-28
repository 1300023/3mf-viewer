import Foundation

/// Turns build items and their component chains (possibly spread over several model parts, as in the
/// production extension used by Bambu Studio / OrcaSlicer) into placed meshes.
final class BuildFlattener {
    private let archive: ZipArchive
    /// Model parts parsed so far, by lookup key.
    private var parts: [String: ParsedModelPart] = [:]
    /// Extruder for meshes without one when the project defines filaments.
    private let defaultExtruder: Int?
    private(set) var instances: [MeshInstance] = []

    /// Component chains deeper than this are ignored (protects against cycles).
    private static let maxDepth = 32

    init(archive: ZipArchive, defaultExtruder: Int?) {
        self.archive = archive
        self.defaultExtruder = defaultExtruder
    }

    /// Parses (once) and returns the model part at `path`.
    func part(_ path: String) throws -> ParsedModelPart? {
        let key = ZipArchive.lookupKey(path)
        if let cached = parts[key] { return cached }
        guard let data = try archive.contents(path: path) else { return nil }
        if Task.isCancelled { throw ThreeMFError.cancelled }
        let parsed = try ModelPartParser.parse(data: data, partPath: key)
        parts[key] = parsed
        return parsed
    }

    /// Replaces a parsed part (after slicer-specific post-processing).
    func replacePart(_ part: ParsedModelPart, key: String) {
        parts[key] = part
    }

    /// Adds every mesh reachable from `objectID`. `settings` (Bambu per-part extruders / subtypes)
    /// apply to the object's direct components only.
    func add(partKey: String, objectID: Int, transform: Transform3D, depth: Int = 0,
             extruder: Int?, settings: BambuObjectSettings?, name: String?) throws {
        guard depth < Self.maxDepth, let model = try part(partKey), let object = model.objects[objectID] else { return }
        if object.type == "support" { return }
        switch object.content {
        case .mesh(let mesh):
            instances.append(MeshInstance(mesh: mesh,
                                          transform: transform,
                                          extruder: extruder ?? defaultExtruder,
                                          objectName: name ?? object.name))
        case .components(let components):
            for component in components {
                var componentExtruder = extruder
                if depth == 0, let partSettings = settings?.parts[component.objectID] {
                    if !partSettings.isModelPart { continue }  // modifiers, negative volumes…
                    if let e = partSettings.extruder, e > 0 { componentExtruder = e }
                }
                try add(partKey: component.path.map(ZipArchive.lookupKey) ?? partKey,
                        objectID: component.objectID,
                        transform: component.transform.then(transform),
                        depth: depth + 1,
                        extruder: componentExtruder,
                        settings: nil,
                        name: name ?? object.name)
            }
        case .empty:
            break
        }
    }

    /// Marks the instances added since `index` as belonging to `plate`.
    func assign(plate: Int, fromInstance index: Int) {
        for i in index ..< instances.count { instances[i].plate = plate }
    }
}

/// Bambu Studio numbers the build items of one object 0, 1, 2… and lists each (object, number) pair under a plate.
struct PlateAssigner {
    private var plateOf: [BambuInstanceRef: Int] = [:]
    private var seen: [Int: Int] = [:]

    init(plates: [BambuPlate]) {
        for plate in plates {
            for ref in plate.instances { plateOf[ref] = plate.index }
        }
    }

    /// The plate of the next build item of `objectID` (build items are visited in file order).
    mutating func nextPlate(forObject objectID: Int) -> Int? {
        let number = seen[objectID, default: 0]
        seen[objectID] = number + 1
        return plateOf[BambuInstanceRef(objectID: objectID, instanceID: number)]
    }
}
