import AppKit
import CoreVideo

/// 切换时掠过一层毛玻璃，给"直接切换"加一点柔和的过渡感。
///
/// 改别的 app 的窗口透明度需要关 SIP 并往 Dock 注入代码（yabai 就是这么做的），
/// 这里换个思路：叠一层我们自己的无边框透明窗，用 NSVisualEffectView 实时虚化背后内容，
/// 淡入再淡出。全程公开 API，不需要额外权限，也不碰任何别人的窗口。
final class TransitionOverlay {
    /// 两端都用对称的缓入缓出：不透明度变化摊得更均匀，
    /// 同样时长下"渐变"比快起慢收的曲线看着长得多。
    private static let coverCurve = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
    private static let revealCurve = CAMediaTimingFunction(controlPoints: 0.38, 0, 0.5, 1)

    /// 揭开前至少停留这么久，避免快到看不清的一闪
    private static let minHold: TimeInterval = 0.06
    /// AX 写入返回不等于 app 已经把窗口重绘到新位置，写完再多压一会儿，
    /// 否则遮挡层揭开时还能瞟到窗口在归位。
    private static let settleHold: TimeInterval = 0.08
    /// 某个 app 的 AX 写入拖太久时的封顶，玻璃不能一直挂着
    private static let maxHold: TimeInterval = 0.55

    private var window: NSWindow?
    private var glass: NSVisualEffectView?
    private var tint: NSView?
    private var generation: UInt = 0
    private var showing = false

    /// - Parameters:
    ///   - frame: AppKit 屏幕坐标下的覆盖区域
    ///   - peak: 最浓时的不透明度，0 表示关闭特效
    ///   - brightness: 白色提亮层的浓度，0 表示只虚化不提亮
    ///   - direction: 滑动方向，+1 / -1，玻璃会朝同方向横扫，0 表示不带方向
    ///   - atPeak: 玻璃升到最浓时回调。窗口切换放这里才会被盖住；
    ///     切换真正落位后要调一次传入的闭包，玻璃才开始揭开。
    func flash(frame: NSRect,
               peak: CGFloat,
               duration: TimeInterval,
               brightness: CGFloat,
               direction: Int,
               atPeak: @escaping (@escaping () -> Void) -> Void) {
        guard peak > 0.01, duration > 0.01, frame.width > 1, frame.height > 1 else {
            atPeak({})
            return
        }

        generation &+= 1
        let gen = generation
        let overlay = ensureWindow()
        // 上一次还没退场就又切了：接着当前这层继续用，重新从 0 淡入会看到明显一顿
        let resuming = showing && overlay.isVisible
        overlay.setFrame(frame, display: false)
        if !resuming { overlay.alphaValue = 0 }
        overlay.orderFrontRegardless()
        showing = true

        // 玻璃比窗口宽出 travel，横扫时两侧才不会露边
        let travel = max(12, min(frame.width * 0.05, 72)) * CGFloat(direction == 0 ? 0 : 1)
        let sign = CGFloat(direction >= 0 ? 1 : -1)
        guard let glass else { atPeak({}); return }
        glass.frame = NSRect(x: -travel, y: 0, width: frame.width + travel * 2, height: frame.height)
        glass.setFrameOrigin(NSPoint(x: -travel + travel * (resuming ? 0 : sign), y: 0))
        // 遮挡层本身是不透明实色，靠 alpha 跟着爬坡：爬到顶时窗口交换被彻底盖住，
        // 爬坡途中半透明，底下的虚化和横扫照样看得见。
        guard let tint else { atPeak({}); return }
        tint.frame = NSRect(origin: .zero, size: frame.size)
        tint.layer?.backgroundColor = NSColor(
            white: 0.55 + 0.45 * max(0, min(1, brightness)), alpha: 1
        ).cgColor
        if !resuming { tint.alphaValue = 0 }

        var writesDone = false
        var holdPassed = false
        var revealed = false

        let reveal: () -> Void = { [weak self] in
            guard !revealed else { return }
            revealed = true
            guard let self, gen == self.generation, let glass = self.glass else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration * 0.58
                context.timingFunction = Self.revealCurve
                context.allowsImplicitAnimation = true
                overlay.animator().alphaValue = 0
                tint.animator().alphaValue = 0
                glass.animator().setFrameOrigin(NSPoint(x: -travel - travel * sign, y: 0))
            }, completionHandler: {
                guard gen == self.generation else { return }
                self.showing = false
                overlay.orderOut(nil)
            })
        }
        let maybeReveal = { if writesDone && holdPassed { reveal() } }

        var covered = false
        let onCovered: () -> Void = { [weak self] in
            guard !covered else { return }
            covered = true
            guard let self, gen == self.generation else { return }
            atPeak {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleHold) {
                    writesDone = true
                    maybeReveal()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.minHold) {
                holdPassed = true
                maybeReveal()
            }
            // 写入迟迟不回也得揭开，否则玻璃就挂死在屏幕上了
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxHold, execute: reveal)
        }

        guard !resuming else {
            overlay.alphaValue = peak
            tint.alphaValue = 1
            onCovered()
            return
        }

        let cover = duration * 0.42
        // 动画回调万一不来（比如系统降级了动画），窗口也必须切，这里留个兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + cover + 0.2, execute: onCovered)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = cover
            context.timingFunction = Self.coverCurve
            context.allowsImplicitAnimation = true
            overlay.animator().alphaValue = peak
            tint.animator().alphaValue = 1
            glass.animator().setFrameOrigin(NSPoint(x: -travel, y: 0))
        }, completionHandler: onCovered)
    }

    func hide() {
        generation &+= 1
        showing = false
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let created = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.ignoresMouseEvents = true
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // 钉死浅色外观：跟随系统的话深色模式下材质会变成深灰，看着像蒙了层脏东西
        created.appearance = NSAppearance(named: .aqua)

        // 圆角放在容器上，玻璃在里面横扫时圆角不会跟着跑
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        container.addSubview(effect)

        // 提亮层压在虚化之上，把灰底往白里拉
        let white = NSView()
        white.wantsLayer = true
        white.autoresizingMask = [.width, .height]
        container.addSubview(white)

        created.contentView = container
        glass = effect
        tint = white
        window = created
        return created
    }
}

/// 由 vsync 驱动的窗口动画器：按窗口数选帧率 + epsilon 过滤 + generation 竞态防护 + 可选弹性过冲。
/// 用于平铺/叠放的进场动画、翻页切换、叠放滚动与恢复布局。
final class WindowAnimator {
    private var displayLink: CVDisplayLink?
    private var records: [WindowRecord] = []
    private var startFrames: [CGRect] = []
    private var targetFrames: [CGRect] = []
    private var lastAppliedFrames: [CGRect] = []
    private var startTime: TimeInterval = 0
    private var lastAppliedTime: TimeInterval = 0
    private var duration: TimeInterval = 0.35
    private var overshoot: CGFloat = 1.0
    private var frameInterval: TimeInterval = 1.0 / 60.0
    private var setFrame: ((WindowRecord, CGRect) -> Void)?
    private var completion: (() -> Void)?
    private var generation: UInt = 0
    private let epsilon: CGFloat = 0.3
    /// 参与动画的窗口数在此以内用 60Hz，超过则降 30Hz。
    /// AX 写入已经全部挪到各 app 自己的后台队列，主线程不再被拖住，
    /// 这个阈值可以放得很宽；慢的 app 靠队列内合并自动丢中间帧。
    var max60HzRecords: Int = 64

    func animate(
        records: [WindowRecord],
        startFrames: [CGRect],
        targetFrames: [CGRect],
        duration: TimeInterval = 0.35,
        overshoot: CGFloat = 1.0,
        setFrame: @escaping (WindowRecord, CGRect) -> Void,
        completion: (() -> Void)? = nil
    ) {
        cancel()

        guard records.count == startFrames.count,
              records.count == targetFrames.count,
              !records.isEmpty else {
            completion?()
            return
        }

        generation &+= 1
        let gen = generation

        self.records = records
        self.startFrames = startFrames
        self.targetFrames = targetFrames
        self.lastAppliedFrames = startFrames
        self.duration = max(duration, 0.05)
        self.overshoot = overshoot
        self.setFrame = setFrame
        self.completion = completion
        self.frameInterval = records.count <= max60HzRecords ? 1.0 / 60.0 : 1.0 / 30.0
        startTime = ProcessInfo.processInfo.systemUptime
        lastAppliedTime = startTime

        tick(gen: gen)
        startDisplayLink(gen: gen)
    }

    func cancel() {
        stopDisplayLink()
        generation &+= 1
        records.removeAll()
        startFrames.removeAll()
        targetFrames.removeAll()
        lastAppliedFrames.removeAll()
        setFrame = nil
        completion = nil
    }

    deinit {
        stopDisplayLink()
    }

    private func tick(gen: UInt) {
        guard gen == generation else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let progress = min(max((now - startTime) / duration, 0), 1)
        let shouldApply = (now - lastAppliedTime) >= frameInterval || progress >= 1

        if shouldApply {
            lastAppliedTime = now
            let eased = overshoot > 1.01 ? easeOutBack(progress, overshoot: Double(overshoot)) : easeOutCubic(progress)
            for index in records.indices {
                let frame = interpolate(startFrames[index], targetFrames[index], eased)
                guard deltaExceeds(lastAppliedFrames[index], frame, epsilon) else { continue }
                lastAppliedFrames[index] = frame
                setFrame?(records[index], frame)
            }
        }

        guard progress >= 1 else { return }

        stopDisplayLink()
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    private func startDisplayLink(gen: UInt) {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        displayLink = link
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.tick(gen: gen)
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }

    private func easeOutCubic(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    /// ease-out + 轻微过冲回弹，模拟原生弹性切换。
    private func easeOutBack(_ progress: Double, overshoot c1: Double) -> Double {
        let c3 = c1 + 1
        let p = progress - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    private func interpolate(_ start: CGRect, _ end: CGRect, _ progress: Double) -> CGRect {
        let t = CGFloat(progress)
        return CGRect(
            x: start.minX + (end.minX - start.minX) * t,
            y: start.minY + (end.minY - start.minY) * t,
            width: start.width + (end.width - start.width) * t,
            height: start.height + (end.height - start.height) * t
        )
    }

    private func deltaExceeds(_ lhs: CGRect, _ rhs: CGRect, _ eps: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) >= eps ||
        abs(lhs.minY - rhs.minY) >= eps ||
        abs(lhs.width - rhs.width) >= eps ||
        abs(lhs.height - rhs.height) >= eps
    }
}

/// 低频驱动的窗口位移引擎：跟手拖动/惯性/吸附共用，静止即停（0 AX 调用）。
final class WindowMotionDriver {
    private var link: CVDisplayLink?
    private var lastTickTime: TimeInterval = 0
    private var generation: UInt = 0
    /// 应用帧率间隔：窗口少时 60Hz，窗口多时降 30Hz 保不卡。
    var frameInterval: TimeInterval = 1.0 / 60.0
    var tick: ((TimeInterval) -> Void)?

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        generation &+= 1
        let gen = generation
        lastTickTime = ProcessInfo.processInfo.systemUptime

        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let created else { return }
        link = created
        CVDisplayLinkSetOutputHandler(created) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.dispatchTick(gen: gen)
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(created)
    }

    func stop() {
        guard let link else { return }
        CVDisplayLinkStop(link)
        self.link = nil
        generation &+= 1
    }

    deinit {
        stop()
    }

    private func dispatchTick(gen: UInt) {
        guard gen == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTickTime >= frameInterval else { return }
        let dt = max(now - lastTickTime, 1.0 / 240.0)
        lastTickTime = now
        tick?(dt)
    }
}
