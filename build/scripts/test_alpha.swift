import AppKit
import ApplicationServices

// 测试 AX 是否支持设置窗口透明度（kAXAlphaAttribute）
for app in NSWorkspace.shared.runningApplications where app.localizedName == "Google Chrome" {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        print("Chrome: 无法获取窗口")
        continue
    }
    guard let win = windows.first else { print("Chrome: 无窗口"); continue }

    // 读当前 alpha
    var alphaRef: CFTypeRef?
    let readStatus = AXUIElementCopyAttributeValue(win, "AXAlpha" as CFString, &alphaRef)
    print("读 AXAlpha status=\(readStatus.rawValue) value=\(alphaRef.map { String(describing: $0) } ?? "nil")")

    // 设置 alpha 0.5
    let half = 0.5 as CFNumber
    let setStatus = AXUIElementSetAttributeValue(win, "AXAlpha" as CFString, half)
    print("设 AXAlpha=0.5 status=\(setStatus.rawValue)")

    // 恢复 1.0
    sleep(1)
    let one = 1.0 as CFNumber
    AXUIElementSetAttributeValue(win, "AXAlpha" as CFString, one)
    print("恢复 alpha=1.0 done")
    break
}
