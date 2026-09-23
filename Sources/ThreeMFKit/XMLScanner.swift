import Foundation

/// A tiny, allocation-free (per element) XML tokenizer.
///
/// 3MF model files can contain millions of `<vertex>` / `<triangle>` elements, which makes
/// `XMLParser` (with a String dictionary per element) the bottleneck. This scanner works on
/// raw UTF-8 bytes and hands out byte ranges instead of strings.
struct XMLAttribute {
    var name: Range<Int>   // local name (namespace prefix stripped)
    var value: Range<Int>  // raw value (entities not decoded)
}

struct XMLTag {
    enum Kind { case start, end, empty }
    var kind: Kind = .start
    /// Local name of the element (namespace prefix stripped).
    var name: Range<Int> = 0 ..< 0
    var attributes: [XMLAttribute] = []
    /// Raw character data between the previous tag and this one.
    var textBefore: Range<Int> = 0 ..< 0
}

enum XMLScanError: Error, LocalizedError {
    case malformed(offset: Int)

    var errorDescription: String? {
        switch self {
        case .malformed(let offset):
            return String(format: NSLocalizedString("Malformed XML near byte %d.", comment: ""), offset)
        }
    }
}

struct XMLBytes {
    let buf: UnsafeBufferPointer<UInt8>

    /// Runs `body` with a document over `data`. The document must not escape the closure.
    static func with<T>(_ data: Data, _ body: (XMLBytes) throws -> T) throws -> T {
        let utf8 = normalizedUTF8(data)
        return try utf8.withUnsafeBytes { raw in
            try body(XMLBytes(buf: raw.bindMemory(to: UInt8.self)))
        }
    }

    /// Converts UTF-16 encoded XML (rare, but allowed) to UTF-8.
    private static func normalizedUTF8(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF),
           let string = String(data: data, encoding: .utf16) {
            return Data(string.utf8)
        }
        return data
    }

    // MARK: - Scanning

    func scan(_ body: (XMLTag) throws -> Void) throws {
        let n = buf.count
        var i = 0
        if n >= 3, buf[0] == 0xEF, buf[1] == 0xBB, buf[2] == 0xBF { i = 3 } // UTF-8 BOM
        var textStart = i
        var tag = XMLTag()
        tag.attributes.reserveCapacity(16)

        while let lt = find(0x3C, from: i) { // '<'
            var j = lt + 1
            guard j < n else { throw XMLScanError.malformed(offset: lt) }
            let c = buf[j]

            if c == 0x3F { // "<?" processing instruction / XML declaration
                guard let end = find(sequence: "?>", from: j) else { throw XMLScanError.malformed(offset: lt) }
                i = end + 2
                textStart = i
                continue
            }
            if c == 0x21 { // "<!" comment, CDATA or DOCTYPE
                if matches("!--", at: j) {
                    guard let end = find(sequence: "-->", from: j + 3) else { throw XMLScanError.malformed(offset: lt) }
                    i = end + 3
                } else if matches("![CDATA[", at: j) {
                    guard let end = find(sequence: "]]>", from: j + 8) else { throw XMLScanError.malformed(offset: lt) }
                    i = end + 3
                } else {
                    guard let end = find(0x3E, from: j) else { throw XMLScanError.malformed(offset: lt) }
                    i = end + 1
                }
                textStart = i
                continue
            }

            tag.attributes.removeAll(keepingCapacity: true)
            tag.textBefore = textStart ..< lt

            if c == 0x2F { // "</name>"
                j += 1
                let nameStart = j
                while j < n, !Self.isNameTerminator(buf[j]) { j += 1 }
                tag.name = localName(nameStart ..< j)
                guard let gt = find(0x3E, from: j) else { throw XMLScanError.malformed(offset: lt) }
                tag.kind = .end
                i = gt + 1
            } else {
                let nameStart = j
                while j < n, !Self.isNameTerminator(buf[j]) { j += 1 }
                tag.name = localName(nameStart ..< j)

                var kind: XMLTag.Kind?
                while kind == nil {
                    while j < n, Self.isSpace(buf[j]) { j += 1 }
                    guard j < n else { throw XMLScanError.malformed(offset: lt) }
                    let ch = buf[j]
                    if ch == 0x3E { // '>'
                        kind = .start
                        j += 1
                    } else if ch == 0x2F { // "/>"
                        guard let gt = find(0x3E, from: j) else { throw XMLScanError.malformed(offset: lt) }
                        kind = .empty
                        j = gt + 1
                    } else {
                        let attrStart = j
                        while j < n {
                            let b = buf[j]
                            if b == 0x3D || b == 0x3E || b == 0x2F || Self.isSpace(b) { break }
                            j += 1
                        }
                        let attrName = attrStart ..< j
                        while j < n, Self.isSpace(buf[j]) { j += 1 }
                        var value = j ..< j
                        if j < n, buf[j] == 0x3D { // '='
                            j += 1
                            while j < n, Self.isSpace(buf[j]) { j += 1 }
                            guard j < n, buf[j] == 0x22 || buf[j] == 0x27 else {
                                throw XMLScanError.malformed(offset: j)
                            }
                            let quote = buf[j]
                            guard let close = find(quote, from: j + 1) else { throw XMLScanError.malformed(offset: j) }
                            value = (j + 1) ..< close
                            j = close + 1
                        }
                        if attrName.isEmpty {
                            j += 1 // skip an unexpected character instead of looping forever
                            continue
                        }
                        tag.attributes.append(XMLAttribute(name: localName(attrName), value: value))
                    }
                }
                tag.kind = kind ?? .start
                i = j
            }
            textStart = i
            try body(tag)
        }
    }

    // MARK: - Helpers

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09
    }

    @inline(__always) static func isNameTerminator(_ b: UInt8) -> Bool {
        b == 0x3E || b == 0x2F || isSpace(b)
    }

    @inline(__always) func find(_ byte: UInt8, from start: Int) -> Int? {
        guard start < buf.count, let base = buf.baseAddress else { return nil }
        guard let hit = memchr(base + start, Int32(byte), buf.count - start) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
    }

    func find(sequence: StaticString, from start: Int) -> Int? {
        let first = sequence.utf8Start.pointee
        var i = start
        while let hit = find(first, from: i) {
            if matches(sequence, at: hit) { return hit }
            i = hit + 1
        }
        return nil
    }

    func matches(_ literal: StaticString, at offset: Int) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard offset >= 0, offset + count <= buf.count else { return false }
        let p = literal.utf8Start
        for k in 0 ..< count where buf[offset + k] != p[k] { return false }
        return true
    }

    /// Strips an XML namespace prefix ("p:path" → "path").
    @inline(__always) func localName(_ r: Range<Int>) -> Range<Int> {
        var k = r.upperBound - 1
        while k >= r.lowerBound {
            if buf[k] == 0x3A { return (k + 1) ..< r.upperBound }
            k -= 1
        }
        return r
    }

    /// Compares a byte range with an ASCII literal.
    @inline(__always) func equals(_ r: Range<Int>, _ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard r.count == count else { return false }
        let p = literal.utf8Start
        var k = 0
        while k < count {
            if buf[r.lowerBound + k] != p[k] { return false }
            k += 1
        }
        return true
    }

    @inline(__always) func attribute(_ tag: XMLTag, _ name: StaticString) -> Range<Int>? {
        for attribute in tag.attributes where equals(attribute.name, name) {
            return attribute.value
        }
        return nil
    }

    func string(_ r: Range<Int>) -> String {
        guard !r.isEmpty else { return "" }
        let raw = String(decoding: UnsafeBufferPointer(rebasing: buf[r]), as: UTF8.self)
        return raw.contains("&") ? Self.decodeEntities(raw) : raw
    }

    func attributeString(_ tag: XMLTag, _ name: StaticString) -> String? {
        attribute(tag, name).map { string($0) }
    }

    func attributeInt(_ tag: XMLTag, _ name: StaticString) -> Int? {
        attribute(tag, name).flatMap { int($0) }
    }

    static func decodeEntities(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var index = s.startIndex
        while let amp = s[index...].firstIndex(of: "&") {
            out += s[index ..< amp]
            guard let semi = s[amp...].firstIndex(of: ";"), s.distance(from: amp, to: semi) <= 10 else {
                out += "&"
                index = s.index(after: amp)
                continue
            }
            let entity = s[s.index(after: amp) ..< semi]
            var replacement: String?
            switch entity {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            default:
                var code: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    code = UInt32(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    code = UInt32(entity.dropFirst(1))
                }
                if let code, let scalar = Unicode.Scalar(code) { replacement = String(Character(scalar)) }
            }
            if let replacement {
                out += replacement
                index = s.index(after: semi)
            } else {
                out += "&"
                index = s.index(after: amp)
            }
        }
        out += s[index...]
        return out
    }

    // MARK: - Numbers

    func int(_ range: Range<Int>) -> Int? {
        var i = range.lowerBound
        var end = range.upperBound
        while i < end, Self.isSpace(buf[i]) { i += 1 }
        while end > i, Self.isSpace(buf[end - 1]) { end -= 1 }
        guard i < end else { return nil }
        var negative = false
        if buf[i] == 0x2D { negative = true; i += 1 } else if buf[i] == 0x2B { i += 1 }
        guard i < end, end - i <= 18 else { return nil }
        var value = 0
        while i < end {
            let d = buf[i] &- 0x30
            if d >= 10 { return nil }
            value = value * 10 + Int(d)
            i += 1
        }
        return negative ? -value : value
    }

    @inline(__always) func float(_ range: Range<Int>) -> Float? {
        double(range).map { Float($0) }
    }

    func double(_ range: Range<Int>) -> Double? {
        var i = range.lowerBound
        var end = range.upperBound
        while i < end, Self.isSpace(buf[i]) { i += 1 }
        while end > i, Self.isSpace(buf[end - 1]) { end -= 1 }
        guard i < end else { return nil }

        var negative = false
        if buf[i] == 0x2D { negative = true; i += 1 } else if buf[i] == 0x2B { i += 1 }

        var mantissa: UInt64 = 0
        var exponent = 0
        var sawDigit = false
        while i < end {
            let d = buf[i] &- 0x30
            if d >= 10 { break }
            sawDigit = true
            if mantissa < 100_000_000_000_000_000 {
                mantissa = mantissa * 10 + UInt64(d)
            } else {
                exponent += 1
            }
            i += 1
        }
        if i < end, buf[i] == 0x2E { // '.'
            i += 1
            while i < end {
                let d = buf[i] &- 0x30
                if d >= 10 { break }
                sawDigit = true
                if mantissa < 100_000_000_000_000_000 {
                    mantissa = mantissa * 10 + UInt64(d)
                    exponent -= 1
                }
                i += 1
            }
        }
        guard sawDigit else { return slowDouble(range) }

        if i < end, buf[i] | 0x20 == 0x65 { // 'e' / 'E'
            i += 1
            var expNegative = false
            if i < end, buf[i] == 0x2D { expNegative = true; i += 1 } else if i < end, buf[i] == 0x2B { i += 1 }
            var e = 0
            var sawExpDigit = false
            while i < end {
                let d = buf[i] &- 0x30
                if d >= 10 { break }
                sawExpDigit = true
                if e < 10_000 { e = e * 10 + Int(d) }
                i += 1
            }
            guard sawExpDigit else { return slowDouble(range) }
            exponent += expNegative ? -e : e
        }
        guard i == end else { return slowDouble(range) }

        var value = Double(mantissa)
        if exponent > 0 {
            value = exponent < powersOfTen.count ? value * powersOfTen[exponent] : value * pow(10, Double(exponent))
        } else if exponent < 0 {
            value = -exponent < powersOfTen.count ? value / powersOfTen[-exponent] : value * pow(10, Double(exponent))
        }
        return negative ? -value : value
    }

    private func slowDouble(_ range: Range<Int>) -> Double? {
        Double(string(range).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private let powersOfTen: [Double] = {
    var table: [Double] = []
    var value = 1.0
    for _ in 0 ... 22 {
        table.append(value)
        value *= 10
    }
    return table
}()
