import AppKit

// 图标生成脚本：渐变圆角底 + 三层白色窗口错落叠放（呼应菜单栏图标）。
// 用法：swift generate_icon.swift <输出目录>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func drawIcon(pixels: Int, to path: String) {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 圆角渐变背景
    let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.56, green: 0.32, blue: 0.95, alpha: 1)
    ])!
    gradient.draw(in: bg, angle: -70)

    // 三层窗口错落叠放
    let ww = size * 0.62
    let wh = size * 0.47
    let radius = size * 0.05
    let windows: [(x: CGFloat, y: CGFloat, alpha: CGFloat)] = [
        (x: size * 0.52, y: size * 0.52, alpha: 0.60),
        (x: size * 0.38, y: size * 0.38, alpha: 0.80),
        (x: size * 0.24, y: size * 0.24, alpha: 1.0)
    ]
    for w in windows {
        let rect = NSRect(x: w.x, y: w.y, width: ww, height: wh)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 1.0, alpha: w.alpha).setFill()
        path.fill()
    }

    // 卡通表情：只保留最前面窗口的笑脸，后两层保持干净。
    let faceColor = NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.28, alpha: 1)
    func drawEye(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let circle = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        faceColor.setFill()
        circle.fill()
    }
    let frontWindow = windows[windows.count - 1]
    let eyeY = frontWindow.y + wh * 0.62
    let eyeR = size * 0.024
    drawEye(cx: frontWindow.x + ww * 0.32, cy: eyeY, r: eyeR)
    drawEye(cx: frontWindow.x + ww * 0.64, cy: eyeY, r: eyeR)

    let smile = NSBezierPath()
    let cx = frontWindow.x + ww * 0.48
    let cy = frontWindow.y + wh * 0.38
    let sr = ww * 0.13
    smile.move(to: NSPoint(x: cx - sr, y: cy))
    smile.curve(
        to: NSPoint(x: cx + sr, y: cy),
        controlPoint1: NSPoint(x: cx - sr * 0.35, y: cy - sr * 1.15),
        controlPoint2: NSPoint(x: cx + sr * 0.35, y: cy - sr * 1.15)
    )
    smile.lineWidth = size * 0.014
    smile.lineCapStyle = .round
    faceColor.setStroke()
    smile.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]
for spec in specs {
    drawIcon(pixels: spec.pixels, to: "\(outputDir)/\(spec.name)")
    print("wrote \(spec.name)")
}
