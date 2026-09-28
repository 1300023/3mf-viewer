import Foundation

/// Model file formats the app can open.
public enum ModelFileFormat: String, CaseIterable, Sendable {
    case threeMF = "3mf"
    case stl
    case obj

    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }

    public static var fileExtensions: [String] { allCases.map(\.rawValue) }

    /// "3MF", "STL", "OBJ".
    public var displayName: String { rawValue.uppercased() }

    public static func isSupported(_ url: URL) -> Bool { ModelFileFormat(url: url) != nil }
}

public enum MeshFileError: Error, LocalizedError {
    case invalidSTL
    case invalidOBJ

    public var errorDescription: String? {
        switch self {
        case .invalidSTL: return NSLocalizedString("The file is not a valid STL file.", comment: "")
        case .invalidOBJ: return NSLocalizedString("The file is not a valid OBJ file.", comment: "")
        }
    }
}

/// Opens any supported model file.
public enum ModelReader {
    public static func load(url: URL) throws -> ThreeMFModel {
        switch ModelFileFormat(url: url) {
        case .stl: return try STLReader.load(url: url)
        case .obj: return try OBJReader.load(url: url)
        case .threeMF, nil: return try ThreeMFReader.load(url: url)
        }
    }

    /// A model made of one mesh in millimetres (STL and OBJ have no units; slicers assume mm).
    static func model(mesh: Mesh, name: String?, objectCount: Int) -> ThreeMFModel {
        let instance = MeshInstance(mesh: mesh, transform: .identity, extruder: nil, objectName: name)
        let instances = mesh.triangleCount > 0 ? [instance] : []
        return ThreeMFModel(unit: .millimeter,
                            metadata: [],
                            instances: instances,
                            filamentColors: [],
                            objectCount: instances.isEmpty ? 0 : max(1, objectCount),
                            bounds: ThreeMFReader.bounds(of: instances),
                            triangleCount: mesh.triangleCount)
    }
}

// MARK: - Text parsing helper

/// STL (ASCII) and OBJ are parsed with the C library (`strtof`, `strtol`, `strstr`), which needs a
/// NUL-terminated, writable copy of the text.
enum TextBuffer {
    static func make(_ data: Data) -> [CChar] {
        var buffer = [CChar](repeating: 0, count: data.count + 1)
        data.withUnsafeBytes { source in
            buffer.withUnsafeMutableBytes { destination in destination.copyMemory(from: source) }
        }
        return buffer
    }
}

// MARK: - STL

/// Binary and ASCII STL. Every triangle gets its own three vertices (the viewer is flat-shaded anyway).
public enum STLReader {
    public static func load(url: URL) throws -> ThreeMFModel {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let mesh = try parse(data, key: url.lastPathComponent)
        return ModelReader.model(mesh: mesh, name: url.deletingPathExtension().lastPathComponent, objectCount: 1)
    }

    static func parse(_ data: Data, key: String) throws -> Mesh {
        let size = data.count
        var binaryCount: Int?
        if size >= 84 {
            let count = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) }
            if 84 + count * 50 == size { binaryCount = count }
        }
        let startsWithSolid = data.prefix(5).elementsEqual("solid".utf8)

        if let count = binaryCount {
            return binary(data, count: count, key: key)
        }
        if startsWithSolid, let mesh = ascii(data, key: key) {
            return mesh
        }
        // Some exporters write a few extra bytes after the triangles.
        if size >= 84 {
            let count = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) }
            if count > 0, 84 + count * 50 <= size { return binary(data, count: count, key: key) }
        }
        throw MeshFileError.invalidSTL
    }

    private static func binary(_ data: Data, count: Int, key: String) -> Mesh {
        var positions = [Float](repeating: 0, count: count * 9)
        data.withUnsafeBytes { raw in
            positions.withUnsafeMutableBufferPointer { out in
                for t in 0 ..< count {
                    let base = 84 + t * 50 + 12  // skip the normal
                    for k in 0 ..< 9 {
                        let bits = raw.loadUnaligned(fromByteOffset: base + k * 4, as: UInt32.self)
                        out[t * 9 + k] = Float(bitPattern: UInt32(littleEndian: bits))
                    }
                }
            }
        }
        return mesh(positions: positions, key: key)
    }

    private static func ascii(_ data: Data, key: String) -> Mesh? {
        var positions: [Float] = []
        var buffer = TextBuffer.make(data)
        buffer.withUnsafeMutableBufferPointer { b in
            guard var p = b.baseAddress else { return }
            while let found = strstr(p, "vertex") {
                var cursor = found + 6
                var values: [Float] = []
                for _ in 0 ..< 3 {
                    var end: UnsafeMutablePointer<CChar>?
                    let value = strtof(cursor, &end)
                    guard let end, end != cursor else { break }
                    values.append(value)
                    cursor = end
                }
                guard values.count == 3 else { break }
                positions += values
                p = cursor
            }
        }
        positions.removeLast(positions.count % 9)
        return positions.isEmpty ? nil : mesh(positions: positions, key: key)
    }

    private static func mesh(positions: [Float], key: String) -> Mesh {
        let vertexCount = positions.count / 3
        return Mesh(key: key,
                    positions: positions,
                    indices: (0 ..< UInt32(vertexCount)).map { $0 },
                    palette: [.inherit],
                    triangleColors: [])
    }
}

// MARK: - OBJ

/// Wavefront OBJ: vertices, polygon faces (triangulated as fans) and material colours (`Kd`) from `.mtl` files.
public enum OBJReader {
    public static func load(url: URL) throws -> ThreeMFModel {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let result = try parse(data, key: url.lastPathComponent) { name in
            let base = url.deletingLastPathComponent()
            let candidates = [name] + name.split(separator: " ").map(String.init)
            for candidate in candidates {
                let file = base.appendingPathComponent(candidate)
                if let data = try? Data(contentsOf: file) { return data }
            }
            return nil
        }
        return ModelReader.model(mesh: result.mesh,
                                 name: url.deletingPathExtension().lastPathComponent,
                                 objectCount: result.objects)
    }

    /// `loadMaterials` returns the contents of a material library named in `mtllib`.
    static func parse(_ data: Data, key: String,
                      loadMaterials: (String) -> Data?) throws -> (mesh: Mesh, objects: Int) {
        var positions: [Float] = []
        var indices: [UInt32] = []
        var colors: [UInt16] = []
        var palette = PaletteBuilder()
        var materials: [String: RGBAColor] = [:]
        var current: ColorSource = .inherit
        var objects = 0

        var buffer = TextBuffer.make(data)
        buffer.withUnsafeMutableBufferPointer { b in
            guard let start = b.baseAddress else { return }
            let end = start + data.count
            var p = start
            var face: [Int] = []
            while p < end {
                // One line, terminated in place so that the C parsing functions stop at its end.
                var q = p
                while q < end, q.pointee != 10, q.pointee != 13 { q += 1 }
                q.pointee = 0
                var line = p
                while line.pointee == 32 || line.pointee == 9 { line += 1 }

                let c0 = line.pointee
                let c1 = c0 == 0 ? 0 : line[1]
                let isSeparator = { (c: CChar) in c == 32 || c == 9 }

                if c0 == 118, isSeparator(c1) { // "v "
                    var cursor = line + 1
                    for _ in 0 ..< 3 {
                        var next: UnsafeMutablePointer<CChar>?
                        let value = strtof(cursor, &next)
                        if let next, next != cursor { cursor = next }
                        positions.append(value)
                    }
                } else if c0 == 102, isSeparator(c1) { // "f "
                    face.removeAll(keepingCapacity: true)
                    let vertexCount = positions.count / 3
                    var cursor = line + 1
                    while true {
                        while isSeparator(cursor.pointee) { cursor += 1 }
                        if cursor.pointee == 0 { break }
                        var next: UnsafeMutablePointer<CChar>?
                        let raw = strtol(cursor, &next, 10)
                        guard let next, next != cursor else { break }
                        let index = raw > 0 ? raw - 1 : vertexCount + raw
                        face.append(index)
                        cursor = next
                        // Skip "/texture/normal".
                        while cursor.pointee != 0, !isSeparator(cursor.pointee) { cursor += 1 }
                    }
                    if face.count >= 3, face.allSatisfy({ $0 >= 0 && $0 < vertexCount }) {
                        let colorIndex = palette.index(for: current)
                        for k in 1 ..< face.count - 1 {
                            indices.append(UInt32(face[0]))
                            indices.append(UInt32(face[k]))
                            indices.append(UInt32(face[k + 1]))
                            colors.append(colorIndex)
                        }
                    }
                } else if c0 == 111, isSeparator(c1) { // "o "
                    objects += 1
                } else if let keyword = keyword(line), keyword.name == "usemtl" || keyword.name == "mtllib" {
                    let argument = String(cString: keyword.rest).trimmingCharacters(in: .whitespaces)
                    if keyword.name == "usemtl" {
                        current = materials[argument].map { ColorSource.color($0) } ?? ColorSource.inherit
                    } else if let library = loadMaterials(argument) {
                        materials.merge(parseMaterials(library)) { _, new in new }
                    }
                }
                p = q + 1
            }
        }

        guard !indices.isEmpty || !positions.isEmpty else { throw MeshFileError.invalidOBJ }
        positions.removeLast(positions.count % 3)
        let usedPalette = palette.palette.isEmpty ? [ColorSource.inherit] : palette.palette
        let mesh = Mesh(key: key,
                        positions: positions,
                        indices: indices,
                        palette: usedPalette,
                        triangleColors: usedPalette.count > 1 ? colors : [])
        return (mesh, objects)
    }

    /// Splits "keyword rest" at the first space or tab.
    private static func keyword(_ line: UnsafeMutablePointer<CChar>) -> (name: String, rest: UnsafeMutablePointer<CChar>)? {
        var cursor = line
        while cursor.pointee != 0, cursor.pointee != 32, cursor.pointee != 9 { cursor += 1 }
        guard cursor.pointee != 0 else { return nil }
        let length = cursor - line
        guard length > 0, length <= 8 else { return nil }
        let name = String(decoding: UnsafeRawBufferPointer(start: line, count: length), as: UTF8.self)
        return (name, cursor + 1)
    }

    /// `newmtl` blocks with a diffuse colour (`Kd`) and optional opacity (`d` / `Tr`).
    static func parseMaterials(_ data: Data) -> [String: RGBAColor] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }
        var result: [String: RGBAColor] = [:]
        var name: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            switch head {
            case "newmtl":
                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            case "Kd" where parts.count >= 4:
                if let name, let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    result[name] = RGBAColor(r: r, g: g, b: b, a: result[name]?.a ?? 1)
                }
            case "d" where parts.count >= 2:
                if let name, let alpha = Float(parts[1]), var color = result[name] {
                    color.a = alpha
                    result[name] = color
                }
            default:
                break
            }
        }
        return result
    }
}
