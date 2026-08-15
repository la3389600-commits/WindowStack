import CoreGraphics
import Foundation

// 模拟真实触控板横向滑动手势：began -> changed×N -> ended
let direction = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "left"
let main = CGMainDisplayID()
let w = CGFloat(CGDisplayPixelsWide(main))
let h = CGFloat(CGDisplayPixelsHigh(main))
let center = CGPoint(x: w / 2, y: h / 2)
CGWarpMouseCursorPosition(center)
usleep(200_000)

let dx: Int64 = direction == "right" ? 8 : -8

func makeEvent(phase: Int64, delta: Int64) -> CGEvent? {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { return nil }
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
    e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: delta < 0 ? -1 : 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.location = center
    return e
}

// began
if let e = makeEvent(phase: 1, delta: dx) { e.post(tap: .cghidEventTap) }
usleep(40_000)
// changed × 8，累积 -64
for _ in 0..<8 {
    if let e = makeEvent(phase: 2, delta: dx) { e.post(tap: .cghidEventTap) }
    usleep(30_000)
}
// ended
if let e = makeEvent(phase: 4, delta: dx) { e.post(tap: .cghidEventTap) }
print("已投递真实手势: \(direction) delta=\(dx)")
