import CoreGraphics
import Foundation

// usage: winid <owner name>   → prints the CGWindowID of the owner's largest normal window
//        winid --list          → prints all on-screen windows
let args = CommandLine.arguments
let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
if args.count > 1, args[1] == "--list" {
    for w in info {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let name = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let id = w[kCGWindowNumber as String] as? Int ?? 0
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(id, layer, owner, "|", name, "|", Int(b["Width"] ?? 0), "x", Int(b["Height"] ?? 0))
    }
    exit(0)
}
let owner = args.count > 1 ? args[1] : ""
var best = (id: 0, area: 0.0)
for w in info where (w[kCGWindowOwnerName as String] as? String) == owner {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if area > best.area { best = (w[kCGWindowNumber as String] as? Int ?? 0, area) }
}
print(best.id)
