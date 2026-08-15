import CoreGraphics
import Foundation

// 模拟一次横向滑动（左滑）触发逐组切换/叠放换层。
// 用法: swift swipe.swift <方向: left|right>
let direction = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "left"

// 把光标移到主屏中央（排列区域）
let main = CGMainDisplayID()
let w = CGFloat(CGDisplayPixelsWide(main))
let h = CGFloat(CGDisplayPixelsHigh(main))
CGWarpMouseCursorPosition(CGPoint(x: w / 2, y: h / 2))
usleep(200_000)

let dx: Int64 = direction == "right" ? 40 : -40
guard let source = CGEventSource(stateID: .combinedSessionState),
      let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else {
    print("投递失败")
    exit(1)
}
event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: dx < 0 ? -1 : 1)
event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
event.location = CGPoint(x: w / 2, y: h / 2)
// 连续投递 3 次，累计超过触发阈值
for _ in 0..<3 {
    event.post(tap: .cghidEventTap)
    usleep(50_000)
}
print("已投递横向滑动×3: \(direction) dx=\(dx) at (\(w/2), \(h/2))")
