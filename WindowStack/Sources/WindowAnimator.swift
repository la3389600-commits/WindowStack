import AppKit
import CoreVideo

/// 切换时掠过一层毛玻璃，给"直接切换"加一点柔和的过渡感。
///
/// 改别的 app 的窗口透明度需要关 SIP 并往 Dock 注入代码（yabai 就是这么做的），
/// 这里换个思路：叠一层我们自己的无边框透明窗，用 NSVisualEffectView 实时虚化背后内容，
/// 淡入再淡出。全程公开 API，不需要额外权限，也不碰任何别人的窗口。
final class TransitionOverlay {
    private var window: NSWindow?
    private var generation: UInt = 0

    /// - Parameters:
    ///   - frame: AppKit 屏幕坐标下的覆盖区域
    ///   - peak: 最浓时的不透明度，0 表示关闭特效
    func flash(frame: NSRect, peak: CGFloat, duration: TimeInterval) {
        guard peak > 0.01, duration > 0.01, frame.width > 1, frame.height > 1 else { return }

        generation &+= 1
        let gen = generation
        let overlay = ensureWindow()
        overlay.setFrame(frame, display: false)
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration * 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = peak
        }, completionHandler: { [weak self] in
            guard let self, gen == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration * 0.65
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                guard gen == self.generation else { return }
                overlay.orderOut(nil)
            })
        })
    }

    func hide() {
        generation &+= 1
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

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        created.contentView = effect

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
    /// 参与动画的窗口数在此以内用 60Hz，超过则降 30Hz 避免 AX 洪峰。
    var max60HzRecords: Int = 12

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
    var frameInterval: TimeInterval = 1.0 / 30.0
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
