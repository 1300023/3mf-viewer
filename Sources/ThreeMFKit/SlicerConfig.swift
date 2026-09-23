import Foundation

/// Per-object settings from Bambu Studio / OrcaSlicer (`Metadata/model_settings.config`).
struct BambuObjectSettings {
    var name: String?
    var extruder: Int?
    /// Keyed by the `objectid` of the corresponding component.
    var parts: [Int: BambuPartSettings] = [:]
}

struct BambuPartSettings {
    var name: String?
    var extruder: Int?
    var subtype: String?

    /// Modifiers, negative volumes and support blockers/enforcers are not printed.
    var isModelPart: Bool { subtype == nil || subtype == "" || subtype == "normal_part" }
}

/// Per-object settings from PrusaSlicer (`Metadata/Slic3r_PE_model.config`).
struct PrusaObjectSettings {
    var extruder: Int?
    var volumes: [PrusaVolume] = []
}

/// A PrusaSlicer volume is a range of triangles inside the object's mesh.
struct PrusaVolume {
    var firstTriangle: Int
    var lastTriangle: Int
    var extruder: Int?
    var volumeType: String?

    var isModelPart: Bool { volumeType == nil || volumeType == "" || volumeType == "ModelPart" }
}

enum SlicerConfig {
    // MARK: Bambu Studio / OrcaSlicer

    static func parseBambuModelSettings(_ data: Data) -> [Int: BambuObjectSettings] {
        var objects: [Int: BambuObjectSettings] = [:]
        _ = try? XMLBytes.with(data) { doc in
            var objectID: Int?
            var object = BambuObjectSettings()
            var partID: Int?
            var part = BambuPartSettings()

            try doc.scan { tag in
                switch tag.kind {
                case .start, .empty:
                    if doc.equals(tag.name, "object") {
                        objectID = doc.attributeInt(tag, "id")
                        object = BambuObjectSettings()
                        if tag.kind == .empty, let id = objectID { objects[id] = object; objectID = nil }
                    } else if doc.equals(tag.name, "part"), objectID != nil {
                        partID = doc.attributeInt(tag, "id")
                        part = BambuPartSettings(subtype: doc.attributeString(tag, "subtype"))
                        if tag.kind == .empty, let id = partID { object.parts[id] = part; partID = nil }
                    } else if doc.equals(tag.name, "metadata"), objectID != nil {
                        guard let key = doc.attributeString(tag, "key") else { return }
                        let value = doc.attributeString(tag, "value") ?? ""
                        if partID != nil {
                            if key == "extruder" { part.extruder = Int(value) }
                            if key == "name" { part.name = value }
                        } else {
                            if key == "extruder" { object.extruder = Int(value) }
                            if key == "name" { object.name = value }
                        }
                    }
                case .end:
                    if doc.equals(tag.name, "part") {
                        if let id = partID { object.parts[id] = part }
                        partID = nil
                    } else if doc.equals(tag.name, "object") {
                        if let id = objectID { objects[id] = object }
                        objectID = nil
                    }
                }
            }
        }
        return objects
    }

    /// `Metadata/project_settings.config` is JSON with a `filament_colour` array.
    static func parseBambuFilamentColors(_ data: Data) -> [RGBAColor] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let values = (json["filament_colour"] as? [String]) ?? (json["extruder_colour"] as? [String]) ?? []
        return values.map { RGBAColor(hex: $0) ?? RGBAColor(r: 0.8, g: 0.8, b: 0.8) }
    }

    // MARK: PrusaSlicer

    static func parsePrusaModelConfig(_ data: Data) -> [Int: PrusaObjectSettings] {
        var objects: [Int: PrusaObjectSettings] = [:]
        _ = try? XMLBytes.with(data) { doc in
            var objectID: Int?
            var object = PrusaObjectSettings()
            var volume: PrusaVolume?

            try doc.scan { tag in
                switch tag.kind {
                case .start, .empty:
                    if doc.equals(tag.name, "object") {
                        objectID = doc.attributeInt(tag, "id")
                        object = PrusaObjectSettings()
                    } else if doc.equals(tag.name, "volume"), objectID != nil {
                        let first = doc.attributeInt(tag, "firstid") ?? 0
                        let last = doc.attributeInt(tag, "lastid") ?? -1
                        volume = PrusaVolume(firstTriangle: first, lastTriangle: last)
                        if tag.kind == .empty, let v = volume { object.volumes.append(v); volume = nil }
                    } else if doc.equals(tag.name, "metadata"), objectID != nil {
                        guard let key = doc.attributeString(tag, "key") else { return }
                        let value = doc.attributeString(tag, "value") ?? ""
                        if volume != nil {
                            if key == "extruder" { volume?.extruder = Int(value) }
                            if key == "volume_type" { volume?.volumeType = value }
                        } else if key == "extruder" {
                            object.extruder = Int(value)
                        }
                    }
                case .end:
                    if doc.equals(tag.name, "volume") {
                        if let v = volume { object.volumes.append(v) }
                        volume = nil
                    } else if doc.equals(tag.name, "object") {
                        if let id = objectID { objects[id] = object }
                        objectID = nil
                    }
                }
            }
        }
        return objects
    }

    /// `Metadata/Slic3r_PE.config` is an INI-like file with lines such as
    /// `; extruder_colour = "#FF8000";"#DB5182"` and `; filament_colour = #FF8000;#DB5182`.
    static func parsePrusaExtruderColors(_ data: Data) -> [RGBAColor] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var extruderColours: [String] = []
        var filamentColours: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = Substring(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
            let items = value.split(separator: ";", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            }
            if key == "extruder_colour" { extruderColours = items }
            if key == "filament_colour" { filamentColours = items }
        }
        let count = max(extruderColours.count, filamentColours.count)
        var colors: [RGBAColor] = []
        for index in 0 ..< count {
            if index < extruderColours.count, let c = RGBAColor(hex: extruderColours[index]) {
                colors.append(c)
            } else if index < filamentColours.count, let c = RGBAColor(hex: filamentColours[index]) {
                colors.append(c)
            } else {
                colors.append(RGBAColor(r: 0.8, g: 0.8, b: 0.8))
            }
        }
        return colors
    }

    /// Splits a PrusaSlicer object mesh by its volumes: drops modifier / negative volumes and
    /// assigns extruders to unpainted triangles.
    static func applyPrusaVolumes(_ mesh: Mesh, settings: PrusaObjectSettings) -> Mesh {
        let objectExtruder = (settings.extruder ?? 0) > 0 ? settings.extruder! : 1
        let volumes = settings.volumes.sorted { $0.firstTriangle < $1.firstTriangle }

        var palette = PaletteBuilder()
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        var colors: [UInt16] = []
        colors.reserveCapacity(mesh.triangleCount)

        var volumeIndex = 0
        for t in 0 ..< mesh.triangleCount {
            while volumeIndex < volumes.count, volumes[volumeIndex].lastTriangle < t { volumeIndex += 1 }
            var volume: PrusaVolume?
            if volumeIndex < volumes.count, volumes[volumeIndex].firstTriangle <= t { volume = volumes[volumeIndex] }
            if let volume, !volume.isModelPart { continue }

            var source = mesh.palette[mesh.paletteIndex(ofTriangle: t)]
            if case .inherit = source {
                let volumeExtruder = volume?.extruder ?? 0
                source = .extruder(volumeExtruder > 0 ? volumeExtruder : objectExtruder)
            }
            indices.append(mesh.indices[t * 3])
            indices.append(mesh.indices[t * 3 + 1])
            indices.append(mesh.indices[t * 3 + 2])
            colors.append(palette.index(for: source))
        }
        return Mesh(key: mesh.key,
                    positions: mesh.positions,
                    indices: indices,
                    palette: palette.palette.isEmpty ? [.inherit] : palette.palette,
                    triangleColors: palette.palette.count > 1 ? colors : [])
    }
}
