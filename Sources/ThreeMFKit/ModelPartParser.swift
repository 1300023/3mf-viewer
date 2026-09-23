import Foundation

struct ComponentRef {
    var objectID: Int
    /// Production extension: the model part that contains the object (nil = same part).
    var path: String?
    var transform: Transform3D
}

struct BuildItem {
    var objectID: Int
    var path: String?
    var transform: Transform3D
}

enum ObjectContent {
    case mesh(Mesh)
    case components([ComponentRef])
    case empty
}

struct ObjectDefinition {
    var id: Int
    var name: String?
    var type: String?
    var content: ObjectContent
}

/// The result of parsing one `.model` part of a 3MF package.
struct ParsedModelPart {
    var unit: LengthUnit?
    var metadata: [MetadataEntry] = []
    var objects: [Int: ObjectDefinition] = [:]
    var buildItems: [BuildItem] = []
}

/// Parses a 3MF model part (core spec + materials / production extensions + slicer painting).
enum ModelPartParser {
    static func parse(data: Data, partPath: String) throws -> ParsedModelPart {
        var result = ParsedModelPart()

        try XMLBytes.with(data) { doc in
            // Property groups (basematerials / colorgroup) → colours by index.
            var propertyGroups: [Int: [RGBAColor?]] = [:]
            var groupID: Int?
            var group: [RGBAColor?] = []

            // Current object.
            var inObject = false
            var objectID = 0
            var objectName: String?
            var objectType: String?
            var objectPID: Int?
            var objectPIndex: Int?
            var positions: [Float] = []
            var indices: [UInt32] = []
            var triangleColors: [UInt16] = []
            var palette = PaletteBuilder()
            var components: [ComponentRef] = []

            var inBuild = false
            var metadataName: String?
            var metadataGroupDepth = 0

            func finishObject() {
                let content: ObjectContent
                if !indices.isEmpty {
                    let paletteEntries = palette.palette.isEmpty ? [ColorSource.inherit] : palette.palette
                    content = .mesh(Mesh(key: "\(partPath)#\(objectID)",
                                         positions: positions,
                                         indices: indices,
                                         palette: paletteEntries,
                                         triangleColors: paletteEntries.count > 1 ? triangleColors : []))
                } else if !components.isEmpty {
                    content = .components(components)
                } else {
                    content = .empty
                }
                result.objects[objectID] = ObjectDefinition(id: objectID, name: objectName, type: objectType, content: content)
                inObject = false
                positions = []
                indices = []
                triangleColors = []
                palette = PaletteBuilder()
                components = []
            }

            try doc.scan { tag in
                let name = tag.name
                switch tag.kind {
                case .start, .empty:
                    // Hot path first: there are millions of these.
                    if doc.equals(name, "vertex") {
                        guard inObject,
                              let x = doc.attribute(tag, "x").flatMap(doc.float),
                              let y = doc.attribute(tag, "y").flatMap(doc.float),
                              let z = doc.attribute(tag, "z").flatMap(doc.float) else { return }
                        positions.append(x)
                        positions.append(y)
                        positions.append(z)
                    } else if doc.equals(name, "triangle") {
                        guard inObject else { return }
                        var v1 = -1, v2 = -1, v3 = -1
                        var pid: Int? = nil
                        var p1: Int? = nil
                        var paint: Range<Int>? = nil
                        for attribute in tag.attributes {
                            let n = attribute.name
                            if doc.equals(n, "v1") { v1 = doc.int(attribute.value) ?? -1 }
                            else if doc.equals(n, "v2") { v2 = doc.int(attribute.value) ?? -1 }
                            else if doc.equals(n, "v3") { v3 = doc.int(attribute.value) ?? -1 }
                            else if doc.equals(n, "pid") { pid = doc.int(attribute.value) }
                            else if doc.equals(n, "p1") { p1 = doc.int(attribute.value) }
                            else if doc.equals(n, "paint_color") || doc.equals(n, "mmu_segmentation") {
                                if !attribute.value.isEmpty { paint = attribute.value }
                            }
                        }
                        let vertexCount = positions.count / 3
                        guard v1 >= 0, v2 >= 0, v3 >= 0,
                              v1 < vertexCount, v2 < vertexCount, v3 < vertexCount else { return }

                        var source = ColorSource.inherit
                        if let groupPID = pid ?? objectPID, let colors = propertyGroups[groupPID] {
                            let index = p1 ?? objectPIndex ?? 0
                            if index >= 0, index < colors.count, let color = colors[index] {
                                source = .color(color)
                            }
                        }
                        if let paint {
                            let state = PaintDecoder.dominantState(doc, paint)
                            if state > 0 { source = .extruder(state) }
                        }
                        indices.append(UInt32(v1))
                        indices.append(UInt32(v2))
                        indices.append(UInt32(v3))
                        triangleColors.append(palette.index(for: source))
                    } else if doc.equals(name, "object") {
                        inObject = true
                        objectID = doc.attributeInt(tag, "id") ?? 0
                        objectName = doc.attributeString(tag, "name")
                        objectType = doc.attributeString(tag, "type")
                        objectPID = doc.attributeInt(tag, "pid")
                        objectPIndex = doc.attributeInt(tag, "pindex")
                        if tag.kind == .empty { finishObject() }
                    } else if doc.equals(name, "component") {
                        guard inObject, let id = doc.attributeInt(tag, "objectid") else { return }
                        let transform = doc.attributeString(tag, "transform").flatMap(Transform3D.init(string:)) ?? .identity
                        components.append(ComponentRef(objectID: id, path: doc.attributeString(tag, "path"), transform: transform))
                    } else if doc.equals(name, "item") {
                        guard inBuild, let id = doc.attributeInt(tag, "objectid") else { return }
                        let transform = doc.attributeString(tag, "transform").flatMap(Transform3D.init(string:)) ?? .identity
                        result.buildItems.append(BuildItem(objectID: id, path: doc.attributeString(tag, "path"), transform: transform))
                    } else if doc.equals(name, "build") {
                        inBuild = tag.kind == .start
                    } else if doc.equals(name, "basematerials") || doc.equals(name, "colorgroup") {
                        groupID = doc.attributeInt(tag, "id")
                        group = []
                        if tag.kind == .empty, let id = groupID { propertyGroups[id] = []; groupID = nil }
                    } else if doc.equals(name, "base") {
                        guard groupID != nil else { return }
                        group.append(doc.attributeString(tag, "displaycolor").flatMap(RGBAColor.init(hex:)))
                    } else if doc.equals(name, "color") {
                        guard groupID != nil else { return }
                        group.append(doc.attributeString(tag, "color").flatMap(RGBAColor.init(hex:)))
                    } else if doc.equals(name, "metadatagroup") {
                        if tag.kind == .start { metadataGroupDepth += 1 }
                    } else if doc.equals(name, "metadata") {
                        if tag.kind == .start, !inObject, metadataGroupDepth == 0 {
                            metadataName = doc.attributeString(tag, "name")
                        }
                    } else if doc.equals(name, "model") {
                        if let unit = doc.attributeString(tag, "unit") {
                            result.unit = LengthUnit(rawValue: unit.lowercased())
                        }
                    }
                case .end:
                    if doc.equals(name, "object") {
                        if inObject { finishObject() }
                    } else if doc.equals(name, "metadata") {
                        if let metadataName {
                            var value = doc.string(tag.textBefore).trimmingCharacters(in: .whitespacesAndNewlines)
                            // Some slicers escape metadata twice ("&amp;quot;").
                            if value.contains("&") { value = XMLBytes.decodeEntities(value) }
                            if !value.isEmpty { result.metadata.append(MetadataEntry(name: metadataName, value: value)) }
                        }
                        metadataName = nil
                    } else if doc.equals(name, "metadatagroup") {
                        metadataGroupDepth = max(0, metadataGroupDepth - 1)
                    } else if doc.equals(name, "basematerials") || doc.equals(name, "colorgroup") {
                        if let id = groupID { propertyGroups[id] = group }
                        groupID = nil
                        group = []
                    } else if doc.equals(name, "build") {
                        inBuild = false
                    }
                }
            }
        }
        return result
    }
}
