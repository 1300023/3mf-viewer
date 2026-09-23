import Foundation

public enum ThreeMFError: Error, LocalizedError {
    case missingModel
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return NSLocalizedString("The file does not contain a 3D model part.", comment: "")
        case .cancelled:
            return NSLocalizedString("Loading was cancelled.", comment: "")
        }
    }
}

/// Reads 3MF packages.
///
/// Supported: 3MF core spec, materials extension colours (`basematerials`, `colorgroup`),
/// production extension (components in other model parts — used by Bambu Studio / OrcaSlicer),
/// Bambu/Orca/Prusa filament colours, multi-material painting and embedded thumbnails.
public enum ThreeMFReader {
    static let modelRelationshipType = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"
    static let thumbnailRelationshipSuffix = "/metadata/thumbnail"

    // MARK: - Public API

    public static func load(url: URL) throws -> ThreeMFModel {
        try load(archive: ZipArchive(url: url))
    }

    public static func load(data: Data) throws -> ThreeMFModel {
        try load(archive: ZipArchive(data: data))
    }

    /// Returns the embedded preview image (PNG/JPEG) if the file has one. Cheap: does not parse the model.
    public static func thumbnailData(url: URL) throws -> Data? {
        try thumbnailData(archive: ZipArchive(url: url))
    }

    public static func thumbnailData(archive: ZipArchive) throws -> Data? {
        var candidates: [String] = relationships(in: archive)
            .filter { $0.type.lowercased().hasSuffix(thumbnailRelationshipSuffix) }
            .map(\.target)
        candidates += [
            "Metadata/plate_1.png",           // Bambu Studio / OrcaSlicer
            "Metadata/thumbnail.png",         // PrusaSlicer, Cura, many others
            "Thumbnails/thumbnail.png",
            "Metadata/plate_1_small.png",
        ]
        for candidate in candidates {
            if let entry = archive.entry(candidate), entry.uncompressedSize > 0,
               let data = try? archive.contents(of: entry) {
                return data
            }
        }

        let images = archive.entries.filter {
            let p = $0.path.lowercased()
            return (p.hasSuffix(".png") || p.hasSuffix(".jpg") || p.hasSuffix(".jpeg")) && $0.uncompressedSize > 0
        }
        let fallback = images.first { $0.path.lowercased().contains("thumbnail") }
            ?? images.first {
                let p = $0.path.lowercased()
                return p.contains("plate") && !p.contains("pick") && !p.contains("no_light")
            }
        if let fallback { return try? archive.contents(of: fallback) }
        return nil
    }

    // MARK: - Loading

    static func load(archive: ZipArchive) throws -> ThreeMFModel {
        guard let rootPath = rootModelPath(in: archive) else { throw ThreeMFError.missingModel }
        let rootKey = ZipArchive.lookupKey(rootPath)

        var parts: [String: ParsedModelPart] = [:]
        func part(_ path: String) throws -> ParsedModelPart? {
            let key = ZipArchive.lookupKey(path)
            if let cached = parts[key] { return cached }
            guard let data = try archive.contents(path: path) else { return nil }
            if Task.isCancelled { throw ThreeMFError.cancelled }
            let parsed = try ModelPartParser.parse(data: data, partPath: key)
            parts[key] = parsed
            return parsed
        }

        guard var root = try part(rootPath) else { throw ThreeMFError.missingModel }

        // Slicer project data.
        let bambuObjects = (try? archive.contents(path: "Metadata/model_settings.config"))
            .flatMap { $0 }
            .map(SlicerConfig.parseBambuModelSettings) ?? [:]
        var filamentColors = (try? archive.contents(path: "Metadata/project_settings.config"))
            .flatMap { $0 }
            .map(SlicerConfig.parseBambuFilamentColors) ?? []
        let prusaObjects = (try? archive.contents(path: "Metadata/Slic3r_PE_model.config"))
            .flatMap { $0 }
            .map(SlicerConfig.parsePrusaModelConfig) ?? [:]
        if filamentColors.isEmpty {
            filamentColors = (try? archive.contents(path: "Metadata/Slic3r_PE.config"))
                .flatMap { $0 }
                .map(SlicerConfig.parsePrusaExtruderColors) ?? []
        }

        // PrusaSlicer stores volumes (parts, modifiers…) as triangle ranges of one mesh.
        if !prusaObjects.isEmpty {
            for (id, settings) in prusaObjects {
                guard let object = root.objects[id], case .mesh(let mesh) = object.content else { continue }
                root.objects[id]?.content = .mesh(SlicerConfig.applyPrusaVolumes(mesh, settings: settings))
            }
            parts[rootKey] = root
        }

        // Flatten build items → mesh instances.
        var instances: [MeshInstance] = []
        let defaultExtruder: Int? = filamentColors.isEmpty ? nil : 1

        func flatten(partKey: String, objectID: Int, transform: Transform3D, depth: Int,
                     extruder: Int?, settings: BambuObjectSettings?, name: String?) throws {
            guard depth < 32, let model = try part(partKey), let object = model.objects[objectID] else { return }
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
                        if !partSettings.isModelPart { continue }
                        if let e = partSettings.extruder, e > 0 { componentExtruder = e }
                    }
                    let childKey = component.path.map(ZipArchive.lookupKey) ?? partKey
                    try flatten(partKey: childKey,
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

        for item in root.buildItems {
            let settings = bambuObjects[item.objectID]
            let extruder = settings?.extruder.flatMap { $0 > 0 ? $0 : nil }
            try flatten(partKey: item.path.map(ZipArchive.lookupKey) ?? rootKey,
                        objectID: item.objectID,
                        transform: item.transform,
                        depth: 0,
                        extruder: extruder,
                        settings: settings,
                        name: settings?.name)
        }
        // Files without a <build> section: show every mesh object of the root part.
        if root.buildItems.isEmpty {
            for id in root.objects.keys.sorted() {
                try flatten(partKey: rootKey, objectID: id, transform: .identity, depth: 0,
                            extruder: nil, settings: nil, name: nil)
            }
        }

        return ThreeMFModel(unit: root.unit ?? .millimeter,
                            metadata: root.metadata,
                            instances: instances,
                            filamentColors: filamentColors,
                            objectCount: root.buildItems.isEmpty ? instances.count : root.buildItems.count,
                            bounds: bounds(of: instances),
                            triangleCount: instances.reduce(0) { $0 + $1.mesh.triangleCount })
    }

    // MARK: - Helpers

    struct Relationship {
        var type: String
        var target: String
    }

    static func relationships(in archive: ZipArchive) -> [Relationship] {
        guard let data = try? archive.contents(path: "_rels/.rels") else { return [] }
        var result: [Relationship] = []
        _ = try? XMLBytes.with(data) { doc in
            try doc.scan { tag in
                guard tag.kind != .end, doc.equals(tag.name, "Relationship"),
                      let type = doc.attributeString(tag, "Type"),
                      let target = doc.attributeString(tag, "Target") else { return }
                result.append(Relationship(type: type, target: target))
            }
        }
        return result
    }

    static func rootModelPath(in archive: ZipArchive) -> String? {
        if let rel = relationships(in: archive).first(where: {
            $0.type.caseInsensitiveCompare(modelRelationshipType) == .orderedSame
        }), archive.entry(rel.target) != nil {
            return rel.target
        }
        if archive.entry("3D/3dmodel.model") != nil { return "3D/3dmodel.model" }
        return archive.entries.first { $0.path.lowercased().hasSuffix(".model") }?.path
    }

    static func bounds(of instances: [MeshInstance]) -> BoundingBox? {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        var any = false
        for instance in instances {
            let m = instance.transform.m
            let m0 = m[0], m1 = m[1], m2 = m[2], m3 = m[3], m4 = m[4], m5 = m[5]
            let m6 = m[6], m7 = m[7], m8 = m[8], m9 = m[9], m10 = m[10], m11 = m[11]
            // Only vertices that are referenced by triangles count (PrusaSlicer modifiers leave unused ones).
            var used = [Bool](repeating: false, count: instance.mesh.vertexCount)
            for index in instance.mesh.indices { used[Int(index)] = true }
            instance.mesh.positions.withUnsafeBufferPointer { p in
                for vertex in 0 ..< used.count where used[vertex] {
                    let i = vertex * 3
                    let x = Double(p[i]), y = Double(p[i + 1]), z = Double(p[i + 2])
                    let v = SIMD3<Double>(x * m0 + y * m3 + z * m6 + m9,
                                          x * m1 + y * m4 + z * m7 + m10,
                                          x * m2 + y * m5 + z * m8 + m11)
                    lo = pointwiseMin(lo, v)
                    hi = pointwiseMax(hi, v)
                }
            }
            any = any || instance.mesh.triangleCount > 0
        }
        return any ? BoundingBox(min: lo, max: hi) : nil
    }
}
