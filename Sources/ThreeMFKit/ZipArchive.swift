import Foundation
#if canImport(Compression)
import Compression
#endif

/// Errors thrown while reading a ZIP container.
public enum ZipError: Error, LocalizedError {
    case notAZipArchive
    case corrupted(String)
    case unsupportedCompression(method: UInt16, path: String)
    case encrypted(String)
    case decompressionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return NSLocalizedString("The file is not a valid 3MF (ZIP) archive.", comment: "")
        case .corrupted(let details):
            return String(format: NSLocalizedString("The archive is damaged: %@", comment: ""), details)
        case .unsupportedCompression(let method, let path):
            return String(format: NSLocalizedString("Unsupported compression method %d in %@.", comment: ""), Int(method), path)
        case .encrypted(let path):
            return String(format: NSLocalizedString("The entry %@ is encrypted.", comment: ""), path)
        case .decompressionFailed(let path):
            return String(format: NSLocalizedString("Could not decompress %@.", comment: ""), path)
        }
    }
}

/// A minimal, read-only ZIP reader (stored + deflate, ZIP64 aware).
///
/// 3MF files are OPC packages, i.e. ordinary ZIP archives. The file is memory-mapped,
/// so opening large archives only touches the central directory.
public final class ZipArchive {
    public struct Entry: Sendable {
        public let path: String
        public let uncompressedSize: Int
        public let compressedSize: Int
        let method: UInt16
        let flags: UInt16
        let localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data
    private let lookup: [String: Int]

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data)
    }

    public init(data: Data) throws {
        // Re-base so that indices always start at zero.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        let entries = try Self.readCentralDirectory(data)
        self.entries = entries
        var lookup: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let key = Self.lookupKey(entry.path)
            if lookup[key] == nil { lookup[key] = index }
        }
        self.lookup = lookup
    }

    // MARK: - Lookup

    /// Normalises an OPC part name ("/3D/3dmodel.model", "3D%20Files/a.model") to a lookup key.
    static func lookupKey(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return p.lowercased()
    }

    public func entry(_ path: String) -> Entry? {
        if let index = lookup[Self.lookupKey(path)] { return entries[index] }
        if let decoded = path.removingPercentEncoding, decoded != path,
           let index = lookup[Self.lookupKey(decoded)] {
            return entries[index]
        }
        return nil
    }

    /// Returns the decompressed contents of the entry at `path`, or `nil` if there is no such entry.
    public func contents(path: String) throws -> Data? {
        guard let entry = entry(path) else { return nil }
        return try contents(of: entry)
    }

    public func contents(of entry: Entry) throws -> Data {
        if entry.flags & 0x1 != 0 { throw ZipError.encrypted(entry.path) }
        let count = data.count
        let lho = entry.localHeaderOffset
        guard lho >= 0, lho + 30 <= count else { throw ZipError.corrupted(entry.path) }

        let start: Int = try data.withUnsafeBytes { raw in
            let r = ByteReader(raw)
            guard r.u32(lho) == 0x0403_4B50 else { throw ZipError.corrupted(entry.path) }
            let nameLength = Int(r.u16(lho + 26))
            let extraLength = Int(r.u16(lho + 28))
            return lho + 30 + nameLength + extraLength
        }
        guard start + entry.compressedSize <= count else { throw ZipError.corrupted(entry.path) }

        switch entry.method {
        case 0:
            return data.subdata(in: start ..< start + entry.compressedSize)
        case 8:
            return try inflate(entry: entry, from: start)
        default:
            throw ZipError.unsupportedCompression(method: entry.method, path: entry.path)
        }
    }

    private func inflate(entry: Entry, from start: Int) throws -> Data {
        let outputSize = entry.uncompressedSize
        if outputSize == 0 { return Data() }
        guard entry.compressedSize > 0 else { throw ZipError.corrupted(entry.path) }

        #if canImport(Compression)
        var output = Data(count: outputSize)
        let written: Int = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951) — exactly what ZIP uses.
                return compression_decode_buffer(dstBase, outputSize,
                                                 srcBase + start, entry.compressedSize,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == outputSize else { throw ZipError.decompressionFailed(entry.path) }
        return output
        #else
        throw ZipError.unsupportedCompression(method: entry.method, path: entry.path)
        #endif
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        try data.withUnsafeBytes { raw -> [Entry] in
            let r = ByteReader(raw)
            let count = raw.count
            guard count >= 22 else { throw ZipError.notAZipArchive }

            // 1. End of central directory record (search backwards, comment can be up to 64 KiB).
            var eocd = -1
            var position = count - 22
            let lowest = max(0, count - 22 - 0xFFFF)
            while position >= lowest {
                if r.u32(position) == 0x0605_4B50 { eocd = position; break }
                position -= 1
            }
            guard eocd >= 0 else { throw ZipError.notAZipArchive }

            var totalEntries = Int(r.u16(eocd + 10))
            var directorySize = Int(r.u32(eocd + 12))
            var directoryOffset = Int(r.u32(eocd + 16))

            // 2. ZIP64 end of central directory (locator sits right before the EOCD record).
            let locator = eocd - 20
            if locator >= 0, r.u32(locator) == 0x0706_4B50 {
                let zip64Offset = Int(clamping: r.u64(locator + 8))
                if zip64Offset >= 0, zip64Offset + 56 <= count, r.u32(zip64Offset) == 0x0606_4B50 {
                    totalEntries = Int(clamping: r.u64(zip64Offset + 32))
                    directorySize = Int(clamping: r.u64(zip64Offset + 40))
                    directoryOffset = Int(clamping: r.u64(zip64Offset + 48))
                }
            }
            guard directoryOffset >= 0, directoryOffset <= count,
                  directorySize >= 0, directoryOffset + directorySize <= count else {
                throw ZipError.corrupted("central directory")
            }

            // 3. Central directory file headers.
            var entries: [Entry] = []
            entries.reserveCapacity(min(totalEntries, 100_000))
            var offset = directoryOffset
            let end = directoryOffset + directorySize
            while offset + 46 <= end, r.u32(offset) == 0x0201_4B50 {
                let flags = r.u16(offset + 8)
                let method = r.u16(offset + 10)
                var compressed = UInt64(r.u32(offset + 20))
                var uncompressed = UInt64(r.u32(offset + 24))
                let nameLength = Int(r.u16(offset + 28))
                let extraLength = Int(r.u16(offset + 30))
                let commentLength = Int(r.u16(offset + 32))
                var localOffset = UInt64(r.u32(offset + 42))

                let nameStart = offset + 46
                let extraStart = nameStart + nameLength
                let next = extraStart + extraLength + commentLength
                guard next <= count else { throw ZipError.corrupted("central directory entry") }

                // ZIP64 extended information extra field.
                var e = extraStart
                while e + 4 <= extraStart + extraLength {
                    let headerID = r.u16(e)
                    let size = Int(r.u16(e + 2))
                    if headerID == 0x0001 {
                        var q = e + 4
                        let limit = e + 4 + size
                        if uncompressed == 0xFFFF_FFFF, q + 8 <= limit { uncompressed = r.u64(q); q += 8 }
                        if compressed == 0xFFFF_FFFF, q + 8 <= limit { compressed = r.u64(q); q += 8 }
                        if localOffset == 0xFFFF_FFFF, q + 8 <= limit { localOffset = r.u64(q) }
                    }
                    e += 4 + size
                }

                let nameBytes = UnsafeRawBufferPointer(rebasing: raw[nameStart ..< extraStart])
                let path = String(bytes: nameBytes, encoding: .utf8)
                    ?? String(bytes: nameBytes, encoding: .isoLatin1)
                    ?? ""
                if !path.isEmpty, !path.hasSuffix("/") {
                    entries.append(Entry(path: path,
                                         uncompressedSize: Int(clamping: uncompressed),
                                         compressedSize: Int(clamping: compressed),
                                         method: method,
                                         flags: flags,
                                         localHeaderOffset: Int(clamping: localOffset)))
                }
                offset = next
            }
            return entries
        }
    }
}

/// Little-endian unaligned reads from a raw buffer. Out-of-range reads return 0.
struct ByteReader {
    let raw: UnsafeRawBufferPointer
    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    @inline(__always) func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= raw.count else { return 0 }
        return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always) func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= raw.count else { return 0 }
        return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always) func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= raw.count else { return 0 }
        return UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}
