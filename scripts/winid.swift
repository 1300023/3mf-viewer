import CoreGraphics
import Foundation

// Helper for the screenshot scripts.
//   winid <owner>           → CGWindowID of the owner's largest on-screen window (0 if none)
//   winid --bounds <owner>  → "x,y,width,height" of that window in screen points
//   winid --list            → all on-screen windows
let args = CommandLine.arguments
let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

func bounds(_ w: [String: Any]) -> (x: Double, y: Double, w: Double, h: Double) {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
}

if args.count > 1, args[1] == "--list" {
    for w in info {
        let b = bounds(w)
        print(w[kCGWindowNumber as String] as? Int ?? 0, w[kCGWindowLayer as String] as? Int ?? -1,
              w[kCGWindowOwnerName as String] as? String ?? "?", "|", w[kCGWindowName as String] as? String ?? "",
              "|", Int(b.x), Int(b.y), Int(b.w), Int(b.h))
    }
    exit(0)
}

let wantBounds = args.count > 2 && args[1] == "--bounds"
let owner = wantBounds ? args[2] : (args.count > 1 ? args[1] : "")
var best: [String: Any]?
for w in info where (w[kCGWindowOwnerName as String] as? String) == owner {
    let b = bounds(w), area = b.w * b.h
    if best == nil || area > bounds(best!).w * bounds(best!).h { best = w }
}
if wantBounds {
    let b = best.map(bounds) ?? (x: 0, y: 0, w: 0, h: 0)
    print("\(Int(b.x)),\(Int(b.y)),\(Int(b.w)),\(Int(b.h))")
} else {
    print(best?[kCGWindowNumber as String] as? Int ?? 0)
}
