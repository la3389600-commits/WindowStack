import AppKit

final class SettingsWindowController: NSWindowController {
    var onHotKeyChange: ((HotKeyAction, HotKeySpec) -> Void)?
    var onConfigChange: ((PanConfig) -> Void)?
    var onResetDefaults: (() -> Void)?

    private var hotKeyButtons: [HotKeyAction: NSButton] = [:]
    private var modePopup: NSPopUpButton?
    private var sliderBindings: [SliderBinding] = []
    private var stepGroup: NSStackView?
    private var followGroup: NSStackView?
    private var currentConfig = PanConfig()
    private var currentHotKeys: [HotKeyAction: HotKeySpec] = [:]
    private var recordingAction: HotKeyAction?
    private var keyMonitor: Any?

    private struct SliderBinding {
        let slider: NSSlider
        let valueLabel: NSTextField
        let mode: InteractionMode
        let get: (PanConfig) -> Double
        let set: (inout PanConfig, Double) -> Void
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(config: PanConfig, hotKeys: [HotKeyAction: HotKeySpec]) {
        currentConfig = config
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
        stack.spacing = 14
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
        modeRow.spacing = 12
        stack.addArrangedSubview(modeRow)

        let step = sectionGroup("逐组切换模式参数")
        stepGroup = step
        addSliderRow(to: step, mode: .step, title: "滑动触发距离", range: 10...80, decimals: 0,
                     get: { $0.swipeThreshold }, set: { $0.swipeThreshold = $1 })
        addSliderRow(to: step, mode: .step, title: "连切最小间隔", range: 0.05...0.6, decimals: 2,
                     get: { $0.switchCooldown }, set: { $0.switchCooldown = $1 })
        addSliderRow(to: step, mode: .step, title: "停顿清零时长", range: 0.1...1.0, decimals: 2,
                     get: { $0.stepIdleReset }, set: { $0.stepIdleReset = $1 })
        addSliderRow(to: step, mode: .step, title: "峰值遮挡强度", range: 0.0...1.0, decimals: 2,
                     get: { $0.switchFadeIntensity }, set: { $0.switchFadeIntensity = $1 })
        addSliderRow(to: step, mode: .step, title: "毛玻璃时长", range: 0.15...2.0, decimals: 2,
                     get: { $0.switchFadeDuration }, set: { $0.switchFadeDuration = $1 })
        addSliderRow(to: step, mode: .step, title: "遮挡层亮度", range: 0.0...1.0, decimals: 2,
                     get: { $0.switchFadeBrightness }, set: { $0.switchFadeBrightness = $1 })
        stack.addArrangedSubview(step)

        let follow = sectionGroup("跟手模式参数")
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

        let resetButton = NSButton(title: "恢复默认设置", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)
        stack.setCustomSpacing(24, after: modeRow)
        stack.setCustomSpacing(26, after: step)
        stack.setCustomSpacing(26, after: follow)
        step.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        follow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])
        return view
    }

    /// 一个分组 = 标题 + 若干行，整组一起显示或隐藏，行间距比组间距小，层级才读得出来。
    private func sectionGroup(_ title: String) -> NSStackView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 12
        let header = sectionHeader(title)
        group.addArrangedSubview(header)
        group.setCustomSpacing(14, after: header)
        return group
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        // 分组标题和上一组之间留出呼吸空间，靠字距和上间距把层级拉开
        if let existing = label.cell as? NSTextFieldCell {
            existing.attributedStringValue = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .kern: 0.6
                ]
            )
        }
        return label
    }

    private func addSliderRow(
        to group: NSStackView,
        mode: InteractionMode,
        title: String,
        range: ClosedRange<Double>,
        decimals: Int,
        get: @escaping (PanConfig) -> Double,
        set: @escaping (inout PanConfig, Double) -> Void
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true

        let slider = NSSlider(value: get(currentConfig), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true

        let valueLabel = NSTextField(labelWithString: format(get(currentConfig), decimals: decimals))
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)

        sliderBindings.append(SliderBinding(slider: slider, valueLabel: valueLabel, mode: mode, get: get, set: set))
        group.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
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
        for binding in sliderBindings where binding.mode == mode {
            binding.slider.doubleValue = binding.get(currentConfig)
            binding.valueLabel.stringValue = format(binding.get(currentConfig), decimals: decimals(for: binding.slider))
        }
        for (action, spec) in currentHotKeys {
            hotKeyButtons[action]?.title = spec.display
        }
    }

    private func decimals(for slider: NSSlider) -> Int {
        slider.minValue >= 100 ? 0 : (slider.maxValue - slider.minValue < 1 ? 2 : 1)
    }

    // MARK: - 动作

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let binding = sliderBindings.first(where: { $0.slider === sender }) else { return }
        var config = currentConfig
        binding.set(&config, sender.doubleValue)
        currentConfig = config
        binding.valueLabel.stringValue = format(sender.doubleValue, decimals: decimals(for: sender))
        onConfigChange?(config)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        let all = InteractionMode.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < all.count else { return }
        var config = currentConfig
        config.interactionMode = all[sender.indexOfSelectedItem]
        currentConfig = config
        onConfigChange?(config)
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
            self.onHotKeyChange?(action, spec)
            return nil
        }
    }

    private func cancelRecording() {
        recordingAction = nil
        if let action = hotKeyButtons.first(where: { $0.value.title == "按下组合键…" })?.key {
            hotKeyButtons[action]?.title = currentHotKeys[action]?.display ?? ""
        }
    }
}
