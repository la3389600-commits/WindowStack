import CoreGraphics
import Foundation

// 列出当前屏幕可见普通窗口的位置尺寸，用于验证排列是否生效。
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("无法读取窗口列表")
    exit(1)
}
let ownPID = ProcessInfo.processInfo.processIdentifier
for w in info {
    guard let pid = w[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value != ownPID else { continue }
    if let layer = w[kCGWindowLayer as String] as? Int, layer != 0 { continue }
    if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
    guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
          let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
          width >= 100, height >= 60 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    print("\(owner): x=\(Int(x)) y=\(Int(y)) w=\(Int(width)) h=\(Int(height))")
}
