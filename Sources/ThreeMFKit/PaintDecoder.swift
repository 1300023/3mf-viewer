import Foundation

/// Decodes multi-material painting data written by PrusaSlicer (`slic3rpe:mmu_segmentation`)
/// and Bambu Studio / OrcaSlicer (`paint_color`).
///
/// Each triangle stores a serialized "TriangleSelector" tree as hex nibbles, read from the
/// END of the string. Every node starts with a nibble: the low two bits are the number of split
/// sides (0 = leaf). For a leaf the high two bits are the state; the value 3 means "read one more
/// nibble and add 3". A split node with N split sides has N + 1 children that follow depth-first.
///
/// A viewer does not need sub-triangle precision, so we return the state that covers the largest
/// part of the triangle's area. State 0 means "not painted", state k means extruder k.
enum PaintDecoder {
    static func dominantState(_ doc: XMLBytes, _ range: Range<Int>) -> Int {
        var position = range.upperBound
        return dominantState {
            while position > range.lowerBound {
                position -= 1
                if let value = hexValue(doc.buf[position]) { return value }
                if !XMLBytes.isSpace(doc.buf[position]) { return nil }
            }
            return nil
        }
    }

    /// Convenience overload used by tests.
    static func dominantState(hex: String) -> Int {
        var bytes = Array(hex.utf8)
        return dominantState {
            while let last = bytes.popLast() {
                if let value = hexValue(last) { return value }
            }
            return nil
        }
    }

    private static func dominantState(nextNibble: () -> Int?) -> Int {
        var weights = [Double](repeating: 0, count: 19) // states 0...18
        var stack: [Double] = [1]
        var nodes = 0
        while let weight = stack.popLast() {
            nodes += 1
            guard nodes < 100_000, let code = nextNibble() else { break }
            let splitSides = code & 0b11
            if splitSides == 0 {
                var state = code >> 2
                if state == 3 {
                    guard let extra = nextNibble() else { break }
                    state = 3 + extra
                }
                if state < weights.count { weights[state] += weight }
            } else {
                let children = splitSides + 1
                let childWeight = weight / Double(children)
                for _ in 0 ..< children { stack.append(childWeight) }
            }
        }
        var best = 0
        for state in 1 ..< weights.count where weights[state] > weights[best] {
            best = state
        }
        return best
    }

    @inline(__always)
    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30 ... 0x39: return Int(byte - 0x30)
        case 0x41 ... 0x46: return Int(byte - 0x41 + 10)
        case 0x61 ... 0x66: return Int(byte - 0x61 + 10)
        default: return nil
        }
    }
}
