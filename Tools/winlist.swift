// Lists on-screen windows of one process: `winlist <pid>` → "id<TAB>width x height<TAB>title".
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count > 1, let pid = Int(args[1]) else { print("usage: winlist <pid>"); exit(1) }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerPID as String] as? Int) == pid {
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard layer == 0 || layer == 3 else { continue }
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let title = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("\(id)\t\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))\t\(title)")
}
