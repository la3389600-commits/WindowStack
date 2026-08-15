import AppKit
import ApplicationServices
import CoreGraphics

private let logQueue = DispatchQueue(label: "com.local.WindowStack.log", qos: .utility)

/// 调试追踪：后台写一行到 /tmp/windowstack.log（不阻塞主线程）。
/// 走串行队列，否则多线程并发写会把日志行截断交错。
func logTrace(_ message: String) {
    let line = "[\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(message)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: "/tmp/windowstack.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/windowstack.log"))
        }
    }
}

struct WindowRecord {
    let app: NSRunningApplication
    let element: AXUIElement
    let title: String
    let originalPosition: CGPoint
    let originalSize: CGSize
}

/// 一次待写入的窗口位置；index 指向 allRecords，用来查上次写过的尺寸。
struct FrameWrite {
    let record: WindowRecord
    let index: Int
    let frame: CGRect
}

enum ArrangementMode {
    case tile
    case cascade
}

struct ArrangeResult {
    let moved: Int
    let skipped: Int
    let message: String
}

/// 滑动交互模式。
enum InteractionMode: String, Codable, CaseIterable {
    case follow   // 跟手 + 惯性 + 吸附
    case step     // 滑一次切换一组/一张（更稳不卡）

    var displayName: String {
        switch self {
        case .follow: return "跟手滑动"
        case .step: return "逐组切换"
        }
    }
}

/// 滑动交互参数，可在设置面板调节并持久化。
/// 解码逐字段 decodeIfPresent，新增字段不会让旧配置整份失效退回默认值。
struct PanConfig: Codable {
    var interactionMode: InteractionMode = .step

    // 逐组切换模式（直接切换）
    var swipeThreshold: CGFloat = 24            // 手势滑动超过此距离触发一次切换 (px)
    var switchCooldown: TimeInterval = 0.1      // 两次切换的最小间隔（手势锁之外的兜底防抖）
    var stepIdleReset: TimeInterval = 0.25      // 滑动停顿超过此时长，已攒的位移清零
    var switchFadeIntensity: CGFloat = 0.35     // 切换时毛玻璃的最浓程度，0 = 关闭特效
    var switchFadeDuration: TimeInterval = 0.42 // 毛玻璃淡入淡出总时长
    var switchFadeBrightness: CGFloat = 0.55    // 毛玻璃提亮程度，0 = 纯虚化，1 = 最白

    /// 过渡观感这组参数每调一次版就 +1；存档里比它小就把这几项重置回新默认，
    /// 免得用户一直停在旧手感上，也省掉一堆一次性的迁移判断。
    static let currentFadeStyleRevision = 1
    var fadeStyleRevision = PanConfig.currentFadeStyleRevision

    // 跟手模式
    var sensitivity: CGFloat = 2.5
    var minInertiaVelocity: CGFloat = 220
    var inertiaTau: TimeInterval = 0.5
    var inertiaStopVelocity: CGFloat = 30
    var velocityProjectionTime: TimeInterval = 0.18
    var flingVelocity: CGFloat = 1100
    var settleDuration: TimeInterval = 0.32
    var settleOvershoot: CGFloat = 1.2
    var epsilon: CGFloat = 0.3
    var farEpsilon: CGFloat = 0.5
    var legacyIdleTimeout: TimeInterval = 0.18
    var bandMarginPages: Int = 1
    var parkFarPagesOnSettle: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PanConfig()
        interactionMode = try c.decodeIfPresent(InteractionMode.self, forKey: .interactionMode) ?? d.interactionMode
        swipeThreshold = try c.decodeIfPresent(CGFloat.self, forKey: .swipeThreshold) ?? d.swipeThreshold
        switchCooldown = try c.decodeIfPresent(TimeInterval.self, forKey: .switchCooldown) ?? d.switchCooldown
        stepIdleReset = try c.decodeIfPresent(TimeInterval.self, forKey: .stepIdleReset) ?? d.stepIdleReset
        switchFadeIntensity = try c.decodeIfPresent(CGFloat.self, forKey: .switchFadeIntensity) ?? d.switchFadeIntensity
        switchFadeDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .switchFadeDuration) ?? d.switchFadeDuration
        switchFadeBrightness = try c.decodeIfPresent(CGFloat.self, forKey: .switchFadeBrightness) ?? d.switchFadeBrightness
        // 缺字段说明是改版之前存的，按 0 处理才能触发重置
        fadeStyleRevision = try c.decodeIfPresent(Int.self, forKey: .fadeStyleRevision) ?? 0
        sensitivity = try c.decodeIfPresent(CGFloat.self, forKey: .sensitivity) ?? d.sensitivity
        minInertiaVelocity = try c.decodeIfPresent(CGFloat.self, forKey: .minInertiaVelocity) ?? d.minInertiaVelocity
        inertiaTau = try c.decodeIfPresent(TimeInterval.self, forKey: .inertiaTau) ?? d.inertiaTau
        inertiaStopVelocity = try c.decodeIfPresent(CGFloat.self, forKey: .inertiaStopVelocity) ?? d.inertiaStopVelocity
        velocityProjectionTime = try c.decodeIfPresent(TimeInterval.self, forKey: .velocityProjectionTime) ?? d.velocityProjectionTime
        flingVelocity = try c.decodeIfPresent(CGFloat.self, forKey: .flingVelocity) ?? d.flingVelocity
        settleDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .settleDuration) ?? d.settleDuration
        settleOvershoot = try c.decodeIfPresent(CGFloat.self, forKey: .settleOvershoot) ?? d.settleOvershoot
        epsilon = try c.decodeIfPresent(CGFloat.self, forKey: .epsilon) ?? d.epsilon
        farEpsilon = try c.decodeIfPresent(CGFloat.self, forKey: .farEpsilon) ?? d.farEpsilon
        legacyIdleTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .legacyIdleTimeout) ?? d.legacyIdleTimeout
        bandMarginPages = try c.decodeIfPresent(Int.self, forKey: .bandMarginPages) ?? d.bandMarginPages
        parkFarPagesOnSettle = try c.decodeIfPresent(Bool.self, forKey: .parkFarPagesOnSettle) ?? d.parkFarPagesOnSettle
    }
}

private enum PanPhase {
    case idle
    case dragging
    case inertia
    case settling
}

final class WindowArranger {
    private var currentLayout: [WindowRecord] = []
    private var allRecords: [WindowRecord] = []
    private var pageSizes: [CGSize] = []
    private var pageSize: Int = 1
    private var pageCount: Int = 1
    private var currentMode: ArrangementMode?

    // 平铺内容坐标系
    private var contentBaseFrames: [CGRect] = []
    private var lastSetFrames: [CGRect] = []
    private var bandFrame: CGRect = .zero
    private var contentPageWidth: CGFloat = 0
    private var contentOffset: CGFloat = 0

    // 叠放：窗口固定在阶梯槽位；横滑最小化最上层，露出下层
    private var cascadeBaseFrames: [CGRect] = []
    /// 我们最小化过的窗口下标（栈：末尾 = 最近一次）。反滑按此顺序还原。
    private var cascadeMinimizedIndices: [Int] = []

    // 跟手模式状态
    private var panPhase: PanPhase = .idle
    private var pendingInputDelta: CGFloat = 0
    private var gestureVelocity: CGFloat = 0
    private var panVelocity: CGFloat = 0
    private var lastScrollTime: TimeInterval = 0
    private var lastScrollOffset: CGFloat = 0
    private var settleState: (startOffset: CGFloat, startTime: TimeInterval, target: CGFloat, duration: TimeInterval)?

    // 逐组切换模式状态
    private var gestureAccumulator: CGFloat = 0
    /// 逐组模式的横向位移累积量。跨事件相位累计，攒够一个 threshold 切一次。
    private var stepAccumulator: CGFloat = 0
    private var stepLastEventTime: TimeInterval = 0
    private var lastSwitchTime: TimeInterval = 0
    /// 本次手势已经切过一次，抬手前不再触发第二次。
    private var stepLocked = false
    private var stepIdleWorkItem: DispatchWorkItem?

    private var legacyIdleTimer: Timer?
    private var scrollEventPort: CFMachPort?
    private var scrollRunLoopSource: CFRunLoopSource?
    private var tapWatchdog: Timer?
    private let animator = WindowAnimator()
    private let motionDriver = WindowMotionDriver()
    private let transitionOverlay = TransitionOverlay()
    /// z 序调整串行队列：raise 的先后顺序决定最终叠放次序，不能并发。
    private let zOrderQueue = DispatchQueue(label: "com.local.WindowStack.z", qos: .userInteractive)
    /// 每个 app 一条 AX 写入队列：某个 app 的 AX 慢（终端类可达 ~300ms）只拖它自己，别的窗口照常跟手。
    private var appQueues: [pid_t: DispatchQueue] = [:]
    private var pendingByPID: [pid_t: [FrameWrite]] = [:]
    private var drainingPIDs = Set<pid_t>()
    /// 上次写入的窗口尺寸；尺寸没变就只写 position，省掉一半 AX 调用。
    private var lastWrittenSizes: [CGSize] = []
    private let axLock = NSLock()
    /// 手感参数，可在设置面板调节（外部可读写）。
    var config = PanConfig()

    deinit {
        stopPanSession()
        animator.cancel()
    }

    /// 应用退出前清理：停掉事件拦截与动画驱动，保证正常退出。
    func shutdown() {
        stopPanSession()
        animator.cancel()
        transitionOverlay.hide()
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    var canRestore: Bool {
        !currentLayout.isEmpty
    }

    /// 当前已排列的窗口数（首页状态显示用）。
    var arrangedWindowCount: Int {
        allRecords.count
    }

    /// 统计当前屏幕上可见的普通应用窗口数（轻量，首页状态显示用）。
    static func visibleWindowCount() -> Int {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windowInfo.reduce(into: 0) { count, info in
            guard let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.int32Value != ownPID else { return }
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { return }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return }
            count += 1
        }
    }

    // MARK: - 排列

    func arrangeWindows(mode: ArrangementMode = .tile) -> ArrangeResult {
        let screen = activeScreen()
        let visibleAXFrame = axRect(from: screen.visibleFrame, screen: screen)
        let records = collectWindows(on: visibleAXFrame)
        guard !records.isEmpty else {
            return ArrangeResult(moved: 0, skipped: 0, message: "没有找到可排列的窗口")
        }

        stopPanSession()
        allRecords = records
        currentMode = mode

        if mode == .tile {
            let metrics = tileMetrics(visibleAXFrame: visibleAXFrame)
            let targetSize = CGSize(width: metrics.windowWidth, height: metrics.windowHeight)
            pageSizes = measureTileSizes(for: records, targetSize: targetSize)
            pageSize = measuredFitCount(
                for: pageSizes,
                visibleAXFrame: visibleAXFrame,
                gap: metrics.gap,
                margin: metrics.margin
            )
            pageCount = max(1, Int(ceil(Double(records.count) / Double(pageSize))))

            bandFrame = visibleAXFrame
            contentPageWidth = visibleAXFrame.width
            contentOffset = 0

            // 逐页构造内容坐标系基帧：页 p 的窗口整体右移 p 个屏宽
            var bases: [CGRect] = []
            var firstPageRecords: [WindowRecord] = []
            var offscreenRecords: [WindowRecord] = []
            for p in 0..<pageCount {
                let pageRecords = Array(records.dropFirst(p * pageSize).prefix(pageSize))
                let pageFrames = tileFrames(for: pageRecords, visibleAXFrame: visibleAXFrame)
                for (i, record) in pageRecords.enumerated() {
                    bases.append(pageFrames[i].offsetBy(dx: CGFloat(p) * contentPageWidth, dy: 0))
                    if p == 0 {
                        firstPageRecords.append(record)
                    } else {
                        offscreenRecords.append(record)
                    }
                }
            }
            contentBaseFrames = bases
            lastSetFrames = bases
            lastWrittenSizes = bases.map { $0.size }
            currentLayout = firstPageRecords

            // 屏幕外页窗口瞬移到位（省动画 AX 调用）
            for record in offscreenRecords {
                guard let index = allRecords.firstIndex(where: { isSameWindow($0, record) }) else { continue }
                setAXFrame(record, contentBaseFrames[index])
            }

            // 首屏窗口进场动画
            let startFrames = firstPageRecords.map { CGRect(origin: $0.originalPosition, size: $0.originalSize) }
            let targetFrames = Array(contentBaseFrames.prefix(firstPageRecords.count))
            animator.animate(
                records: firstPageRecords,
                startFrames: startFrames,
                targetFrames: targetFrames,
                duration: 0.42,
                setFrame: { [weak self] record, frame in
                    self?.setAXFrame(record, frame)
                },
                completion: { [weak self] in
                    self?.startPanSession()
                }
            )
            bringWindowsForward(firstPageRecords)

            let offscreenCount = records.count - firstPageRecords.count
            let suffix = offscreenCount > 0 ? "，另有 \(offscreenCount) 个窗口可横向滚动" : ""
            return ArrangeResult(
                moved: firstPageRecords.count,
                skipped: offscreenCount,
                message: "已平铺 \(firstPageRecords.count) 个窗口\(suffix)"
            )
        }

        // 叠放
        let frames = cascadeFrames(count: records.count, visibleAXFrame: visibleAXFrame)
        cascadeBaseFrames = frames
        lastWrittenSizes = frames.map { $0.size }
        bandFrame = visibleAXFrame
        cascadeMinimizedIndices.removeAll()
        currentLayout = records

        let startFrames = records.map { CGRect(origin: $0.originalPosition, size: $0.originalSize) }
        animator.animate(
            records: records,
            startFrames: startFrames,
            targetFrames: frames,
            duration: 0.38,
            setFrame: { [weak self] record, frame in
                self?.setAXFrame(record, frame)
            },
            completion: { [weak self] in
                self?.startPanSession()
            }
        )
        bringWindowsForward(records)

        return ArrangeResult(moved: records.count, skipped: 0, message: "已叠放 \(records.count) 个窗口")
    }

    // MARK: - 恢复

    @discardableResult
    func restoreWindows() -> Bool {
        let recordsToRestore = allRecords.isEmpty ? currentLayout : allRecords
        let visibleRecords = currentLayout
        guard !recordsToRestore.isEmpty else { return false }

        stopPanSession()
        transitionOverlay.hide()

        // 叠放时可能最小化过窗口：先全部还原，再飞回原位
        for index in cascadeMinimizedIndices where index < recordsToRestore.count {
            setAXMinimized(recordsToRestore[index], false)
        }
        cascadeMinimizedIndices.removeAll()

        for record in recordsToRestore where !visibleRecords.contains(where: { isSameWindow($0, record) }) {
            setAXFrame(record, originalFrame(record))
        }

        // 起点用排列时的已知目标位置（不依赖 AX 读，避免读取失败导致"恢复不动"）
        let animateRecords = visibleRecords.isEmpty ? recordsToRestore : visibleRecords
        let startFrames = animateRecords.map { currentArrangedFrame($0) }
        let targetFrames = animateRecords.map { originalFrame($0) }

        animator.animate(
            records: animateRecords,
            startFrames: startFrames,
            targetFrames: targetFrames,
            duration: 0.42,
            setFrame: { [weak self] record, frame in
                self?.setAXFrame(record, frame)
            },
            completion: { [weak self] in
                guard let self else { return }
                self.currentLayout.removeAll()
                self.allRecords.removeAll()
                self.pageSizes.removeAll()
                self.contentBaseFrames.removeAll()
                self.lastSetFrames.removeAll()
                self.cascadeBaseFrames.removeAll()
                self.cascadeMinimizedIndices.removeAll()
                self.lastWrittenSizes.removeAll()
                self.currentMode = nil
                self.contentOffset = 0
            }
        )

        return true
    }

    // MARK: - 横向滚动会话

    private func startPanSession() {
        motionDriver.tick = { [weak self] dt in
            self?.applyPanFrame(dt: dt)
        }
        motionDriver.stop()
        motionDriver.frameInterval = allRecords.count <= 16 ? 1.0 / 60.0 : 1.0 / 30.0
        contentOffset = 0
        pendingInputDelta = 0
        panVelocity = 0
        gestureVelocity = 0
        gestureAccumulator = 0
        endStepGesture()
        panPhase = .idle
        settleState = nil
        legacyIdleTimer?.invalidate()
        legacyIdleTimer = nil

        let needsPanning: Bool
        switch currentMode {
        case .tile: needsPanning = pageCount > 1
        case .cascade: needsPanning = allRecords.count > 1
        case nil: needsPanning = false
        }
        guard needsPanning else { return }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.scrollCallback,
            userInfo: selfPointer
        ) else {
            logTrace("tapCreate failed")
            return
        }

        scrollEventPort = port
        CGEvent.tapEnable(tap: port, enable: true)

        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) {
            scrollRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        // 回调一旦超时，系统会静默关掉 tap，之后所有滑动都收不到 —— 定期兜底重开。
        let watchdog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let port = self.scrollEventPort else { return }
            guard !CGEvent.tapIsEnabled(tap: port) else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            logTrace("watchdog re-enabled tap")
        }
        tapWatchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
        logTrace("pan session started mode=\(currentMode.map { "\($0)" } ?? "nil") windows=\(allRecords.count)")
    }

    private func stopPanSession() {
        motionDriver.stop()
        panPhase = .idle
        settleState = nil
        pendingInputDelta = 0
        gestureAccumulator = 0
        legacyIdleTimer?.invalidate()
        legacyIdleTimer = nil
        tapWatchdog?.invalidate()
        tapWatchdog = nil
        endStepGesture()

        if let source = scrollRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            scrollRunLoopSource = nil
        }
        if let port = scrollEventPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            scrollEventPort = nil
        }
    }

    // MARK: - 事件处理

    private static let scrollCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let arranger = Unmanaged<WindowArranger>.fromOpaque(refcon).takeUnretainedValue()

        // 回调超时会被系统关掉 tap 并投递这个类型；不重开就再也收不到任何滑动。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            arranger.reenableTap(reason: type == .tapDisabledByTimeout ? "timeout" : "userInput")
            return nil
        }

        if arranger.handleScrollEvent(event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func reenableTap(reason: String) {
        guard let port = scrollEventPort else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        logTrace("tap disabled by \(reason), re-enabled")
    }

    /// 返回 true 表示吞掉该事件。回调本身就在主线程。
    private func handleScrollEvent(_ event: CGEvent) -> Bool {
        // 惯性事件（含 end）一律放行，否则一次甩动会被当成连续多次滑动
        guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return false }

        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let dx: CGFloat
        let dy: CGFloat
        if continuous != 0 {
            dx = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            dy = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        } else {
            dx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
            dy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
        }

        // 叠放永远走逐组切换。跟手模式需要连续插值 z 序，而 macOS 根本不允许跨 app 改
        // z 序，硬做只会变成每帧 raise + 移窗的抖动，所以这里直接不给它走跟手路径。
        if config.interactionMode == .step || currentMode == .cascade {
            return handleStepScroll(event: event, phase: phase, dx: dx, dy: dy)
        }
        return handleFollowScroll(event: event, phase: phase, dx: dx, dy: dy)
    }

    // MARK: - 逐组切换：跨相位累积

    /// 一次手势只切一次：切过之后上锁，直到手指抬起（ended）或事件停顿超时才解锁。
    ///
    /// 不靠 began 开启会话 —— 触控板的 began 经常 delta=0，之前就是因为依赖它才整串丢事件。
    /// began 只当作额外的解锁点，真正的边界是 ended 和空闲计时，两者少一个都还能兜住。
    private func handleStepScroll(event: CGEvent, phase: Int64, dx: CGFloat, dy: CGFloat) -> Bool {
        switch phase {
        case Int64(CGScrollPhase.began.rawValue):
            endStepGesture()
            return false
        case Int64(CGScrollPhase.ended.rawValue), Int64(CGScrollPhase.cancelled.rawValue):
            endStepGesture()
            return false
        case Int64(CGScrollPhase.mayBegin.rawValue):
            return false
        default:
            break
        }

        // 纵向主导的滚动放行，避免劫持其他 app 的正常滚动
        guard abs(dx) > abs(dy), abs(dx) >= 0.5, isOverBand(event) else { return false }

        // 鼠标滚轮没有 ended 相位，靠停顿补一个手势边界
        scheduleStepIdleReset()

        let now = ProcessInfo.processInfo.systemUptime
        if stepLocked { return true }
        if now - stepLastEventTime > config.stepIdleReset { stepAccumulator = 0 }
        if stepAccumulator != 0, (stepAccumulator > 0) != (dx > 0) { stepAccumulator = 0 }
        stepLastEventTime = now
        stepAccumulator += dx

        guard abs(stepAccumulator) >= config.swipeThreshold else { return true }
        guard now - lastSwitchTime >= config.switchCooldown else { return true }

        lastSwitchTime = now
        let direction = stepAccumulator > 0 ? -1 : 1
        stepAccumulator = 0
        stepLocked = true
        performSwitch(direction: direction)
        return true
    }

    /// 结束当前滑动手势：解锁并清空累积，让下一次滑动可以再切一次。
    private func endStepGesture() {
        stepIdleWorkItem?.cancel()
        stepIdleWorkItem = nil
        stepAccumulator = 0
        stepLocked = false
    }

    private func scheduleStepIdleReset() {
        stepIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endStepGesture() }
        stepIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.stepIdleReset, execute: work)
    }

    // MARK: - 跟手模式

    private func handleFollowScroll(event: CGEvent, phase: Int64, dx: CGFloat, dy: CGFloat) -> Bool {
        switch phase {
        case Int64(CGScrollPhase.began.rawValue):
            guard isOverBand(event) else { return false }
            beginGesture()
            if dx != 0 { accumulateGesture(dx) }
            return true
        case Int64(CGScrollPhase.changed.rawValue):
            guard panPhase != .idle else { return false }
            accumulateGesture(dx)
            return true
        case Int64(CGScrollPhase.ended.rawValue), Int64(CGScrollPhase.cancelled.rawValue):
            guard panPhase != .idle else { return false }
            if dx != 0 { accumulateGesture(dx) }
            endGesture()
            return true
        case Int64(CGScrollPhase.mayBegin.rawValue):
            return false
        default:
            break
        }

        // legacy 滚轮（无相位）：光标在排列区域内且横向主导才响应
        guard abs(dx) >= 0.5, abs(dx) > abs(dy), isOverBand(event) else { return false }
        handleLegacyWheel(rawDx: dx)
        return true
    }

    /// 光标是否位于排列区域内，避免劫持其他 app 的横向滚动。
    private func isOverBand(_ event: CGEvent) -> Bool {
        let location = event.location
        let margin: CGFloat = 24
        return location.x >= bandFrame.minX - margin &&
            location.x <= bandFrame.maxX + margin &&
            location.y >= bandFrame.minY - margin &&
            location.y <= bandFrame.maxY + margin
    }

    private func beginGesture() {
        gestureAccumulator = 0
        panPhase = .dragging
        pendingInputDelta = 0
        gestureVelocity = 0
        lastScrollTime = 0
        if currentMode == .tile, !contentBaseFrames.isEmpty {
            for i in allRecords.indices {
                let frame = contentBaseFrames[i].offsetBy(dx: contentOffset, dy: 0)
                if deltaExceeds(lastSetFrames[i], frame, config.epsilon) {
                    lastSetFrames[i] = frame
                    setAXFrame(allRecords[i], frame)
                }
            }
            raiseWindowsAXOnly(currentLayout)
        }
        motionDriver.start()
    }

    private func accumulateGesture(_ rawDx: CGFloat) {
        gestureAccumulator += rawDx
        guard panPhase == .dragging else { return }

        let value = rawDx * config.sensitivity
        pendingInputDelta += value
        let now = ProcessInfo.processInfo.systemUptime
        if lastScrollTime > 0 {
            let dt = max(now - lastScrollTime, 0.001)
            let instant = (contentOffset + pendingInputDelta - lastScrollOffset) / dt
            gestureVelocity = gestureVelocity * 0.5 + instant * 0.5
        }
        lastScrollTime = now
        lastScrollOffset = contentOffset + pendingInputDelta
    }

    private func endGesture() {
        legacyIdleTimer?.invalidate()
        legacyIdleTimer = nil

        guard panPhase == .dragging else { return }
        mergePendingInput()
        panVelocity = gestureVelocity
        if abs(panVelocity) >= config.minInertiaVelocity {
            panPhase = .inertia
            motionDriver.start()
        } else {
            startSettle()
        }
    }

    /// 跟手模式下的 legacy 滚轮（鼠标滚轮无相位）：靠空闲计时补一个"松手"。
    private func handleLegacyWheel(rawDx: CGFloat) {
        if panPhase == .idle {
            beginGesture()
        }
        accumulateGesture(rawDx)
        legacyIdleTimer?.invalidate()
        let timer = Timer(timeInterval: config.legacyIdleTimeout, repeats: false) { [weak self] _ in
            self?.endGesture()
        }
        legacyIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - 切换分发

    /// direction：+1 = 平铺下一页 / 叠放最小化最上层；-1 = 上一页 / 还原刚最小化的窗口。
    private var switchTimes: [TimeInterval] = []

    private func performSwitch(direction: Int) {
        // 限流：0.5s 内最多 8 次切换，防 AX 后台队列过载堆积
        let now = ProcessInfo.processInfo.systemUptime
        switchTimes.removeAll { now - $0 > 0.5 }
        if switchTimes.count >= 8 {
            logTrace("switch throttled")
            return
        }
        switchTimes.append(now)
        logTrace("switch dir=\(direction)")
        switch currentMode {
        case .tile:
            performPageChange(direction: direction)
        case .cascade:
            performCascadeRoll(direction: direction)
        case nil:
            break
        }
    }

    // MARK: - 逐组切换动画

    private func performPageChange(direction: Int) {
        guard currentMode == .tile, pageCount > 1, !allRecords.isEmpty else { return }
        let oldPage = currentPageIndex
        let newPage = clamp(oldPage + direction, 0, pageCount - 1)
        guard newPage != oldPage else { return }

        // 逻辑状态立刻更新，真正的窗口位移推迟到毛玻璃最浓时
        contentOffset = -CGFloat(newPage) * contentPageWidth
        currentLayout = pageRecords(for: newPage)

        transitionOverlay.flash(
            frame: appKitRect(from: bandFrame),
            peak: config.switchFadeIntensity,
            duration: config.switchFadeDuration,
            brightness: config.switchFadeBrightness,
            direction: newPage > oldPage ? 1 : -1
        ) { [weak self] done in
            self?.applyTilePageFrames(completion: done)
        }
    }

    /// 按当前 contentOffset 把窗口写到位。故意不捕获调用时的页码：
    /// 连续切换时后到的回调直接落到最新状态，不会先闪回旧页。
    private func applyTilePageFrames(completion: @escaping () -> Void) {
        guard currentMode == .tile, contentBaseFrames.count == allRecords.count else {
            completion()
            return
        }
        var writes: [FrameWrite] = []
        for i in allRecords.indices {
            writes.append(FrameWrite(record: allRecords[i], index: i, frame: contentBaseFrames[i].offsetBy(dx: contentOffset, dy: 0)))
        }
        setFramesAsync(writes, completion: completion)
        raiseWindowsAXOnly(currentLayout)
    }

    /// 叠放切换：正滑最小化最上层（露出下层），反滑还原刚最小化的那扇。
    ///
    /// 最小化是公开 API，跨 app 可靠；比改 z 序稳得多，也不会抖。
    /// 留最后一扇不最小化，避免桌面空着。
    private func performCascadeRoll(direction: Int) {
        guard currentMode == .cascade, allRecords.count > 1 else { return }
        if direction > 0 {
            minimizeCascadeFront()
        } else {
            restoreLastCascadeMinimized()
        }
    }

    private func cascadeVisibleIndices() -> [Int] {
        allRecords.indices.filter { !cascadeMinimizedIndices.contains($0) }
    }

    private func minimizeCascadeFront() {
        let visible = cascadeVisibleIndices()
        guard visible.count > 1, let front = visible.last else {
            logTrace("cascade minimize skipped remaining=\(visible.count)")
            return
        }
        let record = allRecords[front]
        setAXMinimized(record, true)
        cascadeMinimizedIndices.append(front)
        let remaining = Array(visible.dropLast())
        currentLayout = remaining.map { allRecords[$0] }
        if let next = remaining.last {
            allRecords[next].app.activate(options: [.activateIgnoringOtherApps])
            AXUIElementPerformAction(allRecords[next].element, "AXRaise" as CFString)
        }
        logTrace("cascade minimize idx=\(front) title=\(record.title) remaining=\(remaining.count)")
    }

    private func restoreLastCascadeMinimized() {
        guard let front = cascadeMinimizedIndices.popLast(), front < allRecords.count else {
            logTrace("cascade restore skipped empty")
            return
        }
        let record = allRecords[front]
        setAXMinimized(record, false)
        if front < cascadeBaseFrames.count {
            setAXFrame(record, cascadeBaseFrames[front])
        }
        record.app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(record.element, "AXRaise" as CFString)
        currentLayout = cascadeVisibleIndices().map { allRecords[$0] }
        logTrace("cascade restore idx=\(front) title=\(record.title)")
    }

    // MARK: - 跟手渲染驱动（30/60Hz）

    private func applyPanFrame(dt: TimeInterval) {
        switch panPhase {
        case .dragging:
            mergePendingInput()
        case .inertia:
            panVelocity *= exp(-dt / config.inertiaTau)
            contentOffset += panVelocity * CGFloat(dt)
            clampContentOffset()
            applyContentOffset()
            if abs(panVelocity) < config.inertiaStopVelocity {
                panPhase = .settling
                let target = settleTargetOffset()
                settleState = (activeOffset, ProcessInfo.processInfo.systemUptime, target, config.settleDuration)
            }
        case .settling:
            guard let settle = settleState else {
                panPhase = .idle
                motionDriver.stop()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - settle.startTime
            let progress = min(max(elapsed / settle.duration, 0), 1)
            let eased = easeOutBack(progress, overshoot: config.settleOvershoot)
            contentOffset = settle.startOffset + (settle.target - settle.startOffset) * eased
            applyContentOffset()
            if progress >= 1 {
                contentOffset = settle.target
                finalizeSettle()
            }
        case .idle:
            motionDriver.stop()
        }
    }

    private func mergePendingInput() {
        guard pendingInputDelta != 0 else { return }
        contentOffset += pendingInputDelta
        clampContentOffset()
        applyContentOffset()
        pendingInputDelta = 0
    }

    private var activeOffset: CGFloat { contentOffset }

    private func startSettle() {
        panPhase = .settling
        let target = settleTargetOffset()
        settleState = (activeOffset, ProcessInfo.processInfo.systemUptime, target, config.settleDuration)
        motionDriver.start()
    }

    private func settleTargetOffset() -> CGFloat {
        if currentMode == .cascade {
            return 0
        }
        let pitch = contentPageWidth
        guard pitch > 0 else { return contentOffset }
        if abs(panVelocity) >= config.flingVelocity {
            let dir: Int = panVelocity > 0 ? 1 : -1
            let page = clamp(currentPageIndex - dir, 0, pageCount - 1)
            return -CGFloat(page) * pitch
        }
        let predicted = contentOffset + panVelocity * CGFloat(config.velocityProjectionTime)
        let slot = (predicted / pitch).rounded() * pitch
        return clamp(slot, -(CGFloat(pageCount) - 1) * pitch, 0)
    }

    private func finalizeSettle() {
        switch currentMode {
        case .tile:
            for i in allRecords.indices {
                let base = contentBaseFrames[i]
                let frame = base.offsetBy(dx: contentOffset, dy: 0)
                if frame.intersects(bandFrame) {
                    if deltaExceeds(lastSetFrames[i], frame, config.epsilon) {
                        lastSetFrames[i] = frame
                        setAXFrame(allRecords[i], frame)
                    }
                } else if config.parkFarPagesOnSettle {
                    var park = frame
                    if park.minX >= bandFrame.maxX {
                        park.origin.x = bandFrame.maxX + 24
                    } else if park.maxX <= bandFrame.minX {
                        park.origin.x = bandFrame.minX - park.width - 24
                    }
                    if deltaExceeds(lastSetFrames[i], park, config.epsilon) {
                        lastSetFrames[i] = park
                        setAXFrame(allRecords[i], park)
                    }
                }
            }
            currentLayout = currentPageRecords()
            raiseWindowsAXOnly(currentLayout)
        case .cascade:
            break   // 叠放不走跟手驱动
        case nil:
            break
        }
        panPhase = .idle
        settleState = nil
        motionDriver.stop()
    }

    private func clampContentOffset() {
        let minOffset = -(CGFloat(pageCount) - 1) * contentPageWidth
        contentOffset = min(max(contentOffset, minOffset), 0)
    }

    private func applyContentOffset() {
        guard !allRecords.isEmpty,
              contentBaseFrames.count == allRecords.count,
              lastSetFrames.count == allRecords.count else { return }

        let bandMinX = bandFrame.minX - contentPageWidth * CGFloat(config.bandMarginPages)
        let bandMaxX = bandFrame.maxX + contentPageWidth * CGFloat(config.bandMarginPages)
        let bandY0 = bandFrame.minY - 400
        let bandY1 = bandFrame.maxY + 400

        for i in allRecords.indices {
            let frame = contentBaseFrames[i].offsetBy(dx: contentOffset, dy: 0)
            let inBand = frame.maxX >= bandMinX && frame.minX <= bandMaxX &&
                frame.maxY >= bandY0 && frame.minY <= bandY1
            let eps = inBand ? config.epsilon : config.farEpsilon
            guard deltaExceeds(lastSetFrames[i], frame, eps) else { continue }
            lastSetFrames[i] = frame
            setAXPositionOnly(allRecords[i], frame.origin)
        }
    }

    // MARK: - 页面索引

    private var currentPageIndex: Int {
        guard contentPageWidth > 0 else { return 0 }
        return clamp(Int((-(contentOffset) / contentPageWidth).rounded()), 0, pageCount - 1)
    }

    private func currentPageRecords() -> [WindowRecord] {
        pageRecords(for: currentPageIndex)
    }

    private func pageRecords(for page: Int) -> [WindowRecord] {
        guard pageSize > 0 else { return [] }
        let start = min(page * pageSize, allRecords.count)
        let end = min(start + pageSize, allRecords.count)
        guard start < end else { return [] }
        return Array(allRecords[start..<end])
    }

    // MARK: - 窗口操作

    private func raiseWindowsAXOnly(_ records: [WindowRecord]) {
        let snapshot = records
        zOrderQueue.async {
            for record in snapshot {
                AXUIElementPerformAction(record.element, "AXRaise" as CFString)
            }
        }
    }

    private func isSameWindow(_ lhs: WindowRecord, _ rhs: WindowRecord) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    private func originalFrame(_ record: WindowRecord) -> CGRect {
        CGRect(origin: record.originalPosition, size: record.originalSize)
    }

    /// 批量移动窗口。按 app 分流到各自的串行队列：某个 app 的 AX 写慢只拖它自己，
    /// 其余窗口照常瞬时到位。每条队列内部只保留最新目标，连续划动不会堆积。
    private func setFramesAsync(_ writes: [FrameWrite], completion: (() -> Void)? = nil) {
        var grouped: [pid_t: [FrameWrite]] = [:]
        for write in writes {
            grouped[write.record.app.processIdentifier, default: []].append(write)
        }

        var toStart: [pid_t] = []
        axLock.lock()
        for (pid, list) in grouped {
            pendingByPID[pid] = list        // 覆盖为最新目标，丢弃中间态
            if !drainingPIDs.contains(pid) {
                drainingPIDs.insert(pid)
                toStart.append(pid)
            }
        }
        axLock.unlock()

        for pid in toStart {
            queue(for: pid).async { [weak self] in self?.drainFrames(pid: pid) }
        }

        guard let completion else { return }
        // 每个 pid 的队列是串行的：此刻排进去的空块必然排在处理本批写入的 drain 之后，
        // 全部回来就说明窗口已经真的落位了。
        let group = DispatchGroup()
        for pid in grouped.keys {
            group.enter()
            queue(for: pid).async { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        axLock.lock()
        defer { axLock.unlock() }
        if let existing = appQueues[pid] { return existing }
        let created = DispatchQueue(label: "com.local.WindowStack.ax.\(pid)", qos: .userInteractive)
        appQueues[pid] = created
        return created
    }

    private func drainFrames(pid: pid_t) {
        while true {
            axLock.lock()
            guard let batch = pendingByPID[pid], !batch.isEmpty else {
                pendingByPID[pid] = nil
                drainingPIDs.remove(pid)
                axLock.unlock()
                return
            }
            pendingByPID[pid] = nil
            axLock.unlock()

            for write in batch {
                let start = ProcessInfo.processInfo.systemUptime
                var position = write.frame.origin
                if let positionValue = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(write.record.element, kAXPositionAttribute as CFString, positionValue)
                }
                // 尺寸在排列后就不再变，只在真的变了时才写，省掉一半 AX 往返
                if sizeNeedsWrite(index: write.index, size: write.frame.size) {
                    var size = write.frame.size
                    if let sizeValue = AXValueCreate(.cgSize, &size) {
                        AXUIElementSetAttributeValue(write.record.element, kAXSizeAttribute as CFString, sizeValue)
                    }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if elapsed > 0.12 {
                    logTrace("slow AX write pid=\(pid) \(Int(elapsed * 1000))ms")
                }
            }
        }
    }

    private func sizeNeedsWrite(index: Int, size: CGSize) -> Bool {
        axLock.lock()
        defer { axLock.unlock() }
        guard index >= 0, index < lastWrittenSizes.count else { return true }
        let previous = lastWrittenSizes[index]
        guard abs(previous.width - size.width) < 1, abs(previous.height - size.height) < 1 else {
            lastWrittenSizes[index] = size
            return true
        }
        return false
    }

    /// 窗口当前在排列布局中的位置（不依赖 AX 读，用排列时计算的目标帧）。
    private func currentArrangedFrame(_ record: WindowRecord) -> CGRect {
        guard let index = allRecords.firstIndex(where: { isSameWindow($0, record) }) else {
            return originalFrame(record)
        }
        if currentMode == .tile, index < contentBaseFrames.count {
            return contentBaseFrames[index].offsetBy(dx: contentOffset, dy: 0)
        }
        // 叠放的窗口固定在自己的槽位，下标即槽位
        if currentMode == .cascade, index < cascadeBaseFrames.count {
            return cascadeBaseFrames[index]
        }
        return originalFrame(record)
    }

    private func deltaExceeds(_ lhs: CGRect, _ rhs: CGRect, _ eps: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) >= eps ||
        abs(lhs.minY - rhs.minY) >= eps ||
        abs(lhs.width - rhs.width) >= eps ||
        abs(lhs.height - rhs.height) >= eps
    }

    private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private func clamp(_ value: Int, _ minValue: Int, _ maxValue: Int) -> Int {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private func easeOutBack(_ progress: CGFloat, overshoot: CGFloat) -> CGFloat {
        let c3 = overshoot + 1
        let p = progress - 1
        return 1 + c3 * p * p * p + overshoot * p * p
    }

    // MARK: - 窗口收集

    private func collectWindows(on visibleAXFrame: CGRect) -> [WindowRecord] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var windowsByPID: [pid_t: [CGRect]] = [:]

        for info in windowInfo {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            guard pid != ownPID else { continue }

            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = windowBounds(from: boundsDict),
                  bounds.width >= 100,
                  bounds.height >= 60,
                  bounds.intersects(visibleAXFrame) else { continue }

            windowsByPID[pid, default: []].append(bounds)
        }

        guard !windowsByPID.isEmpty else { return [] }

        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            !app.isHidden &&
            windowsByPID[app.processIdentifier] != nil
        }

        var records: [WindowRecord] = []

        for app in apps {
            guard var matchingCGWindows = windowsByPID[app.processIdentifier] else { continue }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 1.5)

            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else {
                continue
            }

            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.5)

                let role = stringAttribute(window, kAXRoleAttribute as CFString)
                guard role == kAXWindowRole as String else { continue }

                let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
                guard subrole == kAXStandardWindowSubrole as String else { continue }
                guard !boolAttribute(window, kAXMinimizedAttribute as CFString) else { continue }
                guard !boolAttribute(window, "AXFullScreen" as CFString) else { continue }

                guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
                      let size = sizeAttribute(window, kAXSizeAttribute as CFString) else {
                    continue
                }

                let axFrame = CGRect(origin: position, size: size)
                guard let matchIndex = matchingCGWindows.firstIndex(where: { framesAreClose($0, axFrame) }) else {
                    continue
                }

                matchingCGWindows.remove(at: matchIndex)
                records.append(
                    WindowRecord(
                        app: app,
                        element: window,
                        title: stringAttribute(window, kAXTitleAttribute as CFString),
                        originalPosition: position,
                        originalSize: size
                    )
                )
            }
        }

        return records
    }

    // MARK: - 布局计算

    private func tileMetrics(visibleAXFrame: CGRect) -> (windowWidth: CGFloat, windowHeight: CGFloat, gap: CGFloat, margin: CGFloat) {
        let gap: CGFloat = 12
        let margin: CGFloat = 16
        let windowHeight = visibleAXFrame.height * 0.5
        let windowWidth = min(
            max(windowHeight * 1.6, 420),
            visibleAXFrame.width * 0.62
        )

        return (
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            gap: gap,
            margin: margin
        )
    }

    private func tileFrames(for records: [WindowRecord], visibleAXFrame: CGRect) -> [CGRect] {
        let metrics = tileMetrics(visibleAXFrame: visibleAXFrame)
        let gap = metrics.gap
        let margin = metrics.margin
        let sizes = records.map { effectiveTileSize(for: $0) }
        let totalWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width } + gap * CGFloat(max(records.count - 1, 0))
        let fitsOnScreen = totalWidth <= visibleAXFrame.width - margin * 2
        var x = fitsOnScreen
            ? visibleAXFrame.minX + (visibleAXFrame.width - totalWidth) / 2
            : visibleAXFrame.minX + margin

        return sizes.map { size in
            let y = visibleAXFrame.minY + (visibleAXFrame.height - size.height) / 2
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + gap
            return frame
        }
    }

    private func measureTileSizes(for records: [WindowRecord], targetSize: CGSize) -> [CGSize] {
        records.map { record in
            let originalSize = record.originalSize
            var size = targetSize

            guard let sizeValue = AXValueCreate(.cgSize, &size),
                  AXUIElementSetAttributeValue(record.element, kAXSizeAttribute as CFString, sizeValue) == .success else {
                return originalSize
            }

            let actualSize = sizeAttribute(record.element, kAXSizeAttribute as CFString) ?? targetSize
            var resetSize = originalSize
            if let resetValue = AXValueCreate(.cgSize, &resetSize) {
                AXUIElementSetAttributeValue(record.element, kAXSizeAttribute as CFString, resetValue)
            }

            let widthMatches = abs(actualSize.width - targetSize.width) < 2
            let heightMatches = abs(actualSize.height - targetSize.height) < 2
            return widthMatches && heightMatches ? targetSize : actualSize
        }
    }

    private func measuredFitCount(
        for sizes: [CGSize],
        visibleAXFrame: CGRect,
        gap: CGFloat,
        margin: CGFloat
    ) -> Int {
        guard let firstWidth = sizes.first?.width else { return 1 }

        let usableWidth = visibleAXFrame.width - margin * 2
        var count = 1
        var usedWidth = firstWidth

        for size in sizes.dropFirst() {
            guard usedWidth + gap + size.width <= usableWidth else { break }
            count += 1
            usedWidth += gap + size.width
        }

        return max(1, count)
    }

    private func effectiveTileSize(for record: WindowRecord) -> CGSize {
        guard let index = allRecords.firstIndex(where: { isSameWindow($0, record) }),
              index < pageSizes.count else {
            return record.originalSize
        }
        return pageSizes[index]
    }

    private func cascadeFrames(count: Int, visibleAXFrame: CGRect) -> [CGRect] {
        let metrics = tileMetrics(visibleAXFrame: visibleAXFrame)
        let size = CGSize(width: metrics.windowWidth, height: metrics.windowHeight)

        let margin: CGFloat = 24
        let baseX = visibleAXFrame.minX + margin
        let baseY = visibleAXFrame.minY + margin
        let maxStepX = max(0, visibleAXFrame.width - size.width - margin * 2)
        let maxStepY = max(0, visibleAXFrame.height - size.height - margin * 2)
        let denominator = max(CGFloat(count - 1), 1)

        let stepX = min(38, maxStepX / denominator)
        let stepY = min(30, maxStepY / denominator)

        return (0..<count).map { index in
            CGRect(
                x: baseX + CGFloat(index) * stepX,
                y: baseY + CGFloat(index) * stepY,
                width: size.width,
                height: size.height
            )
        }
    }

    private func bringWindowsForward(_ records: [WindowRecord]) {
        var raisedApps = Set<pid_t>()

        for record in records.reversed() {
            if raisedApps.contains(record.app.processIdentifier) { continue }
            raisedApps.insert(record.app.processIdentifier)
            record.app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        for record in records {
            AXUIElementPerformAction(record.element, "AXRaise" as CFString)
        }
    }

    // MARK: - 坐标转换

    private func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private var primaryScreen: NSScreen {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func axRect(from appKitRect: NSRect, screen: NSScreen) -> CGRect {
        let primary = primaryScreen
        return CGRect(
            x: appKitRect.minX - primary.frame.minX,
            y: primary.frame.maxY - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    /// axRect 的逆变换：AX 坐标（左上原点、y 向下）回到 AppKit 屏幕坐标。
    private func appKitRect(from axRect: CGRect) -> NSRect {
        let primary = primaryScreen
        return NSRect(
            x: axRect.minX + primary.frame.minX,
            y: primary.frame.maxY - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
    }

    private func windowBounds(from dictionary: [String: CGFloat]) -> CGRect? {
        guard let x = dictionary["X"],
              let y = dictionary["Y"],
              let width = dictionary["Width"],
              let height = dictionary["Height"] else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func framesAreClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 &&
        abs(lhs.minY - rhs.minY) < 2 &&
        abs(lhs.width - rhs.width) < 2 &&
        abs(lhs.height - rhs.height) < 2
    }

    // MARK: - AX 读写

    private func setAXFrame(_ record: WindowRecord, _ frame: CGRect) {
        let start = ProcessInfo.processInfo.systemUptime
        var position = frame.origin
        var size = frame.size

        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(record.element, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(record.element, kAXSizeAttribute as CFString, sizeValue)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if elapsed > 0.15 {
            logTrace("setAXFrame slow pid=\(record.app.processIdentifier) \(Int(elapsed * 1000))ms")
        }
    }

    private func setAXMinimized(_ record: WindowRecord, _ minimized: Bool) {
        AXUIElementSetAttributeValue(
            record.element,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    private func setAXPositionOnly(_ record: WindowRecord, _ point: CGPoint) {
        var position = point
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(record.element, kAXPositionAttribute as CFString, positionValue)
        }
    }

    private func currentAXFrame(_ record: WindowRecord) -> CGRect? {
        guard let position = pointAttribute(record.element, kAXPositionAttribute as CFString),
              let size = sizeAttribute(record.element, kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
        copyAttribute(element, attribute) as? String ?? ""
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        (copyAttribute(element, attribute) as? NSNumber)?.boolValue ?? false
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}
