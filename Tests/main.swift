import AppKit
import ApplicationServices
import CoreGraphics

func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key, &value)
    return value
}

func stringValue(_ element: AXUIElement, _ key: CFString) -> String {
    attribute(element, key) as? String ?? ""
}

func pointValue(_ element: AXUIElement, _ key: CFString) -> CGPoint {
    guard let value = attribute(element, key),
          CFGetTypeID(value) == AXValueGetTypeID() else {
        return .zero
    }
    let axValue = value as! AXValue
    var point = CGPoint.zero
    AXValueGetValue(axValue, .cgPoint, &point)
    return point
}

func sizeValue(_ element: AXUIElement, _ key: CFString) -> CGSize {
    guard let value = attribute(element, key),
          CFGetTypeID(value) == AXValueGetTypeID() else {
        return .zero
    }
    let axValue = value as! AXValue
    var size = CGSize.zero
    AXValueGetValue(axValue, .cgSize, &size)
    return size
}

func visibleFrames() -> [(String, CGRect)] {
    var result: [(String, CGRect)] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            continue
        }
        for window in windows {
            guard stringValue(window, kAXRoleAttribute as CFString) == kAXWindowRole as String else { continue }
            let minimized = (attribute(window, kAXMinimizedAttribute as CFString) as? NSNumber)?.boolValue ?? false
            guard !minimized else { continue }
            let point = pointValue(window, kAXPositionAttribute as CFString)
            let size = sizeValue(window, kAXSizeAttribute as CFString)
            let title = stringValue(window, kAXTitleAttribute as CFString)
            if !title.isEmpty && size.width >= 100 && size.height >= 60 {
                result.append((title, CGRect(origin: point, size: size)))
            }
        }
    }
    return result
}

func wait(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

print("trusted:", AXIsProcessTrusted())

let arranger = WindowArranger()
let result = arranger.arrangeWindows(mode: .tile)
print("result:", result.message)
wait(2.5)

let frames = visibleFrames()
for (index, item) in frames.enumerated() {
    print(index, item.0, Int(item.1.minX), Int(item.1.minY), Int(item.1.width), Int(item.1.height))
}

var overlaps = 0
for i in 0..<frames.count {
    for j in (i + 1)..<frames.count {
        let intersection = frames[i].1.intersection(frames[j].1)
        if intersection.width > 1 && intersection.height > 1 {
            overlaps += 1
            print("OVERLAP", frames[i].0, frames[j].0, Int(intersection.width), Int(intersection.height))
        }
    }
}
print("overlaps:", overlaps)

arranger.restoreWindows()
wait(2.5)
print("restored")

let cascadeResult = arranger.arrangeWindows(mode: .cascade)
print("cascade result:", cascadeResult.message)
wait(4)

let cascadeFrames = visibleFrames()
for (index, item) in cascadeFrames.enumerated() {
    print("CASCADE", index, item.0, Int(item.1.minX), Int(item.1.minY), Int(item.1.width), Int(item.1.height))
}

arranger.restoreWindows()
wait(2.5)
print("cascade restored")
