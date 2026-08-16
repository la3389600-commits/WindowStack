import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var onHotKeyChange: ((HotKeyAction, HotKeySpec) -> Void)?
    var onConfigChange: ((PanConfig) -> Void)?
    /// 只把尺寸改动推给运行时看效果，不落盘
    var onPreviewLayout: ((PanConfig) -> Void)?
    /// 尺寸改动最终生效并保存
    var onApplyLayout: ((PanConfig) -> Void)?
    var onResetDefaults: (() -> Void)?

    private var hotKeyButtons: [HotKeyAction: NSButton] = [:]
    private var modePopup: NSPopUpButton?
    private var sliderBindings: [SliderBinding] = []
    private var stepGroup: CardView?
    private var followGroup: CardView?
    private var layoutHint: NSTextField?
    private var applyButton: NSButton?
    private var currentConfig = PanConfig()
    /// 尺寸参数不即时生效，先攒在这儿，等「预览」或「应用」
    private var layoutDraft = LayoutRatios()
    private var layoutDirty = false
    private var currentHotKeys: [HotKeyAction: HotKeySpec] = [:]
    private var recordingAction: HotKeyAction?
    private var keyMonitor: Any?

    private struct LayoutRatios {
        var tileWidth: CGFloat = 0.5
        var tileHeight: CGFloat = 0.5
        var cascadeWidth: CGFloat = 0.5
        var cascadeHeight: CGFloat = 0.5

        init() {}

        init(_ config: PanConfig) {
            tileWidth = config.tileWidthRatio
            tileHeight = config.tileHeightRatio
            cascadeWidth = config.cascadeWidthRatio
            cascadeHeight = config.cascadeHeightRatio
        }
    }

    /// currentConfig 叠上未应用的尺寸草稿
    private var draftConfig: PanConfig {
        var config = currentConfig
        config.tileWidthRatio = layoutDraft.tileWidth
        config.tileHeightRatio = layoutDraft.tileHeight
        config.cascadeWidthRatio = layoutDraft.cascadeWidth
        config.cascadeHeightRatio = layoutDraft.cascadeHeight
        return config
    }

    private struct SliderBinding {
        let slider: NSSlider
        let valueField: NSTextField
        let mode: InteractionMode?
        /// true = 改了不立刻生效，等「预览」/「应用」
        let deferred: Bool
        let range: ClosedRange<Double>
        let decimals: Int
        let get: (PanConfig) -> Double
        let set: (inout PanConfig, Double) -> Void
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(config: PanConfig, hotKeys: [HotKeyAction: HotKeySpec]) {
        currentConfig = config
        layoutDraft = LayoutRatios(config)
        layoutDirty = false
        currentHotKeys = hotKeys
        refreshUI()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateHotKey(_ action: HotKeyAction, _ spec: HotKeySpec) {
        currentHotKeys[action] = spec
        hotKeyButtons[action]?.title = spec.display
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    /// 快捷键当前是否真的在系统里注册成功了，注册失败通常是被别的 app 占了同一组合。
    func updateHotKeyStatus(_ registered: [HotKeyAction: Bool]) {
        for (action, ok) in registered {
            guard let button = hotKeyButtons[action], recordingAction != action else { continue }
            button.title = currentHotKeys[action]?.display ?? ""
            button.contentTintColor = ok ? nil : .systemRed
            button.toolTip = ok ? nil : "这个组合被其他 app 占用了，注册失败"
        }
    }

    // MARK: - UI 构建

    private func buildUI() {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let panTab = NSTabViewItem(identifier: "pan")
        panTab.label = "滑动"
        panTab.view = buildPanView()

        let hotKeyTab = NSTabViewItem(identifier: "hotkeys")
        hotKeyTab.label = "快捷键"
        hotKeyTab.view = buildHotKeyView()

        tabView.addTabViewItem(panTab)
        tabView.addTabViewItem(hotKeyTab)

        guard let contentView = window?.contentView else { return }
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    // MARK: 滑动页

    private func buildPanView() -> NSView {
        let view = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 滑动模式
        let modeLabel = NSTextField(labelWithString: "滑动模式")
        modeLabel.font = NSFont.systemFont(ofSize: 13)
        let popup = NSPopUpButton()
        popup.addItems(withTitles: InteractionMode.allCases.map { $0.displayName })
        popup.target = self
        popup.action = #selector(modeChanged(_:))
        modePopup = popup
        let modeRow = NSStackView(views: [modeLabel, popup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 14
        stack.addArrangedSubview(modeRow)

        let step = sectionGroup("逐组滑动")
        stepGroup = step
        addSliderRow(to: step, mode: .step, title: "滑动触发距离", range: 10...80, decimals: 0,
                     get: { $0.swipeThreshold }, set: { $0.swipeThreshold = $1 })
        addSliderRow(to: step, mode: .step, title: "连切最小间隔", range: 0.05...0.6, decimals: 2,
                     get: { $0.switchCooldown }, set: { $0.switchCooldown = $1 })
        addSliderRow(to: step, mode: .step, title: "停顿清零时长", range: 0.1...1.0, decimals: 2,
                     get: { $0.stepIdleReset }, set: { $0.stepIdleReset = $1 })
        addSliderRow(to: step, mode: .step, title: "峰值遮挡强度", range: 0.0...1.0, decimals: 2,
                     get: { $0.switchFadeIntensity }, set: { $0.switchFadeIntensity = $1 })
        addSliderRow(to: step, mode: .step, title: "遮挡过渡时长", range: 0.15...2.0, decimals: 2,
                     get: { $0.switchFadeDuration }, set: { $0.switchFadeDuration = $1 })
        addSliderRow(to: step, mode: .step, title: "黑色遮挡深度", range: 0.0...1.0, decimals: 2,
                     get: { $0.switchFadeBrightness }, set: { $0.switchFadeBrightness = $1 })
        stack.addArrangedSubview(step)

        let follow = sectionGroup("跟手滑动")
        followGroup = follow
        addSliderRow(to: follow, mode: .follow, title: "跟手灵敏度", range: 1.0...4.0, decimals: 1,
                     get: { $0.sensitivity }, set: { $0.sensitivity = $1 })
        addSliderRow(to: follow, mode: .follow, title: "惯性时长", range: 0.2...0.8, decimals: 2,
                     get: { $0.inertiaTau }, set: { $0.inertiaTau = $1 })
        addSliderRow(to: follow, mode: .follow, title: "吸附时长", range: 0.15...0.6, decimals: 2,
                     get: { $0.settleDuration }, set: { $0.settleDuration = $1 })
        addSliderRow(to: follow, mode: .follow, title: "吸附弹性", range: 1.0...1.8, decimals: 2,
                     get: { $0.settleOvershoot }, set: { $0.settleOvershoot = $1 })
        addSliderRow(to: follow, mode: .follow, title: "甩动翻页阈值", range: 500...2000, decimals: 0,
                     get: { $0.flingVelocity }, set: { $0.flingVelocity = $1 })
        addSliderRow(to: follow, mode: .follow, title: "惯性触发阈值", range: 100...500, decimals: 0,
                     get: { $0.minInertiaVelocity }, set: { $0.minInertiaVelocity = $1 })
        stack.addArrangedSubview(follow)

        let layout = sectionGroup("窗口尺寸")
        addSliderRow(to: layout, mode: nil, deferred: true, title: "平铺宽度（%）", range: 25...90, decimals: 0,
                     get: { $0.tileWidthRatio * 100 }, set: { $0.tileWidthRatio = $1 / 100 })
        addSliderRow(to: layout, mode: nil, deferred: true, title: "平铺高度（%）", range: 25...90, decimals: 0,
                     get: { $0.tileHeightRatio * 100 }, set: { $0.tileHeightRatio = $1 / 100 })
        addSliderRow(to: layout, mode: nil, deferred: true, title: "叠放宽度（%）", range: 25...90, decimals: 0,
                     get: { $0.cascadeWidthRatio * 100 }, set: { $0.cascadeWidthRatio = $1 / 100 })
        addSliderRow(to: layout, mode: nil, deferred: true, title: "叠放高度（%）", range: 25...90, decimals: 0,
                     get: { $0.cascadeHeightRatio * 100 }, set: { $0.cascadeHeightRatio = $1 / 100 })
        addLayoutActions(to: layout)
        stack.addArrangedSubview(layout)

        let resetButton = NSButton(title: "恢复默认设置", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)
        stack.setCustomSpacing(26, after: modeRow)
        stack.setCustomSpacing(28, after: step)
        stack.setCustomSpacing(28, after: follow)
        stack.setCustomSpacing(28, after: layout)
        step.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        follow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        layout.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 卡片一多就可能超出窗口高度，套个滚动视图，谁也不会被裁掉
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        return view
    }

    /// 尺寸参数改完不立刻生效：先「预览」看一眼，满意了再「应用」锁定。
    private func addLayoutActions(to card: CardView) {
        let hint = NSTextField(wrappingLabelWithString: "")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        layoutHint = hint

        let preview = NSButton(title: "预览", target: self, action: #selector(previewLayout))
        preview.bezelStyle = .rounded

        let apply = NSButton(title: "应用", target: self, action: #selector(applyLayout))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        applyButton = apply

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [hint, spacer, preview, apply])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY

        card.content.setCustomSpacing(20, after: card.content.arrangedSubviews.last ?? row)
        card.content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
    }

    /// 一个分组 = 一张浅灰卡片，标题 + 若干行，整张一起显示或隐藏。
    private func sectionGroup(_ title: String) -> CardView {
        CardView(title: title)
    }

    private func addSliderRow(
        to card: CardView,
        mode: InteractionMode?,
        deferred: Bool = false,
        title: String,
        range: ClosedRange<Double>,
        decimals: Int,
        get: @escaping (PanConfig) -> Double,
        set: @escaping (inout PanConfig, Double) -> Void
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 20
        row.alignment = .centerY

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.widthAnchor.constraint(equalToConstant: 148).isActive = true

        let source = deferred ? draftConfig : currentConfig
        let slider = NSSlider(value: get(source), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true

        let valueField = NSTextField(string: format(get(source), decimals: decimals))
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .labelColor
        valueField.alignment = .right
        valueField.isEditable = true
        valueField.isSelectable = true
        valueField.isBordered = true
        valueField.bezelStyle = .roundedBezel
        valueField.delegate = self
        valueField.target = self
        valueField.action = #selector(valueFieldChanged(_:))
        valueField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueField)

        sliderBindings.append(SliderBinding(
            slider: slider,
            valueField: valueField,
            mode: mode,
            deferred: deferred,
            range: range,
            decimals: decimals,
            get: get,
            set: set
        ))
        card.content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
    }

    // MARK: 快捷键页

    private func buildHotKeyView() -> NSView {
        let view = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: "点击右侧按钮，然后按下新的组合键即可修改，Esc 取消。")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(24, after: hint)

        for action in HotKeyAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 16

            let label = NSTextField(labelWithString: title(for: action))
            label.font = NSFont.systemFont(ofSize: 13)
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true

            let button = NSButton(title: "", target: self, action: #selector(hotKeyClicked(_:)))
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
            hotKeyButtons[action] = button

            row.addArrangedSubview(label)
            row.addArrangedSubview(button)
            stack.addArrangedSubview(row)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])
        return view
    }

    private func title(for action: HotKeyAction) -> String {
        switch action {
        case .tile: return "平铺窗口"
        case .cascade: return "叠放窗口"
        case .restore: return "恢复布局"
        }
    }

    private func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    // MARK: - 刷新

    private func refreshUI() {
        let mode = currentConfig.interactionMode
        if let index = InteractionMode.allCases.firstIndex(of: mode) {
            modePopup?.selectItem(at: index)
        }
        // 整组一起隐藏。之前只藏滑块不藏标题，另一模式的标题会孤零零留在那儿。
        let showStep = mode == .step
        stepGroup?.isHidden = !showStep
        followGroup?.isHidden = showStep
        let draft = draftConfig
        for binding in sliderBindings where binding.mode == nil || binding.mode == mode {
            let value = binding.get(binding.deferred ? draft : currentConfig)
            binding.slider.doubleValue = value
            binding.valueField.stringValue = format(value, decimals: binding.decimals)
        }
        for (action, spec) in currentHotKeys {
            hotKeyButtons[action]?.title = spec.display
        }
        updateLayoutStatus()
    }

    private func updateLayoutStatus() {
        applyButton?.isEnabled = layoutDirty
        layoutHint?.stringValue = layoutDirty
            ? "尺寸已改动，未生效。点「预览」看效果，「应用」后保存。"
            : "当前尺寸已生效。"
    }

    // MARK: - 动作

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let binding = sliderBindings.first(where: { $0.slider === sender }) else { return }
        binding.valueField.stringValue = format(sender.doubleValue, decimals: binding.decimals)
        commit(binding, value: sender.doubleValue)
    }

    @objc private func valueFieldChanged(_ sender: NSTextField) {
        commitValueField(sender)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commitValueField(field)
    }

    private func commitValueField(_ field: NSTextField) {
        guard let binding = sliderBindings.first(where: { $0.valueField === field }) else { return }
        let fallback = binding.get(binding.deferred ? draftConfig : currentConfig)
        let parsed = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) ?? fallback
        let value = min(max(parsed, binding.range.lowerBound), binding.range.upperBound)
        binding.slider.doubleValue = value
        field.stringValue = format(value, decimals: binding.decimals)
        commit(binding, value: value)
    }

    private func commit(_ binding: SliderBinding, value: Double) {
        if binding.deferred {
            var config = draftConfig
            binding.set(&config, value)
            layoutDraft = LayoutRatios(config)
            layoutDirty = true
            updateLayoutStatus()
        } else {
            var config = currentConfig
            binding.set(&config, value)
            currentConfig = config
            onConfigChange?(config)
        }
    }

    @objc private func previewLayout() {
        onPreviewLayout?(draftConfig)
    }

    @objc private func applyLayout() {
        currentConfig = draftConfig
        layoutDirty = false
        updateLayoutStatus()
        onApplyLayout?(currentConfig)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        let all = InteractionMode.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < all.count else { return }
        var config = currentConfig
        config.interactionMode = all[sender.indexOfSelectedItem]
        currentConfig = config
        onConfigChange?(config)
        refreshUI()
    }

    @objc private func hotKeyClicked(_ sender: NSButton) {
        guard let action = hotKeyButtons.first(where: { $0.value === sender })?.key else { return }
        recordingAction = action
        sender.title = "按下组合键…"
        startKeyMonitor()
    }

    @objc private func resetDefaults() {
        onResetDefaults?()
    }

    private func startKeyMonitor() {
        // 每次录制都换一个新监听器，旧的必须先摘掉：
        // 叠着几个监听器时，一次按键会被重复录进去。
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }
            if event.keyCode == 53 {   // Esc 取消
                self.cancelRecording()
                return nil
            }
            let keyCode = UInt32(event.keyCode)
            let modifiers = HotKeyManager.carbonModifiers(event.modifierFlags)
            guard modifiers != 0 else {
                NSSound.beep()
                return nil
            }
            let spec = HotKeySpec(keyCode: keyCode, modifiers: modifiers, display: HotKeyManager.displayString(for: event))
            self.currentHotKeys[action] = spec
            self.hotKeyButtons[action]?.title = spec.display
            self.recordingAction = nil
            self.stopKeyMonitor()
            self.onHotKeyChange?(action, spec)
            return nil
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// 录制中途跑掉（切窗口、关设置）也要退出录制状态，
    /// 否则监听器一直挂着，下一次随便按个带修饰键的组合就被录成新快捷键，
    /// 原来的快捷键就这么悄悄失效了。
    private func cancelRecording() {
        let action = recordingAction
            ?? hotKeyButtons.first(where: { $0.value.title == "按下组合键…" })?.key
        recordingAction = nil
        stopKeyMonitor()
        guard let action else { return }
        hotKeyButtons[action]?.title = currentHotKeys[action]?.display ?? ""
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelRecording()
    }

    func windowWillClose(_ notification: Notification) {
        cancelRecording()
    }
}

/// 文档视图从上往下排，滚动条才不会把内容倒着放。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 参数卡片：比页面底色浅一档的灰底，靠这一档色差和留白把分组读出来。
/// 底色写死成半透明黑/白而不是取系统色，是因为 controlBackgroundColor
/// 在深色模式下和窗口底色几乎一样，卡片就糊成一片了。
final class CardView: NSView {
    let content = NSStackView()

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])

        let header = NSTextField(labelWithString: title)
        header.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.8
            ]
        )
        content.addArrangedSubview(header)
        content.setCustomSpacing(20, after: header)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.045).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.08).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
