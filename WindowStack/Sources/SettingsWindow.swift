import AppKit

final class SettingsWindowController: NSWindowController {
    var onHotKeyChange: ((HotKeyAction, HotKeySpec) -> Void)?
    var onConfigChange: ((PanConfig) -> Void)?
    var onResetDefaults: (() -> Void)?

    private var hotKeyButtons: [HotKeyAction: NSButton] = [:]
    private var modePopup: NSPopUpButton?
    private var sliderBindings: [SliderBinding] = []
    private var stepHeader: NSTextField?
    private var followHeader: NSTextField?
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
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
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // 滑动模式
        let modeLabel = NSTextField(labelWithString: "滑动模式：")
        let popup = NSPopUpButton()
        popup.addItems(withTitles: InteractionMode.allCases.map { $0.displayName })
        popup.target = self
        popup.action = #selector(modeChanged(_:))
        modePopup = popup
        let modeRow = NSStackView(views: [modeLabel, popup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        stack.addArrangedSubview(modeRow)

        let stepHeaderLabel = sectionHeader("逐组切换模式参数")
        stepHeader = stepHeaderLabel
        stack.addArrangedSubview(stepHeaderLabel)

        addSliderRow(to: stack, mode: .step, title: "滑动触发距离", range: 10...80, decimals: 0,
                     get: { $0.swipeThreshold }, set: { $0.swipeThreshold = $1 })
        addSliderRow(to: stack, mode: .step, title: "连切最小间隔", range: 0.05...0.6, decimals: 2,
                     get: { $0.switchCooldown }, set: { $0.switchCooldown = $1 })
        addSliderRow(to: stack, mode: .step, title: "停顿清零时长", range: 0.1...1.0, decimals: 2,
                     get: { $0.stepIdleReset }, set: { $0.stepIdleReset = $1 })
        addSliderRow(to: stack, mode: .step, title: "切换毛玻璃浓度", range: 0.0...0.8, decimals: 2,
                     get: { $0.switchFadeIntensity }, set: { $0.switchFadeIntensity = $1 })
        addSliderRow(to: stack, mode: .step, title: "毛玻璃时长", range: 0.15...0.8, decimals: 2,
                     get: { $0.switchFadeDuration }, set: { $0.switchFadeDuration = $1 })

        let followHeaderLabel = sectionHeader("跟手模式参数")
        followHeader = followHeaderLabel
        stack.addArrangedSubview(followHeaderLabel)

        addSliderRow(to: stack, mode: .follow, title: "跟手灵敏度", range: 1.0...4.0, decimals: 1,
                     get: { $0.sensitivity }, set: { $0.sensitivity = $1 })
        addSliderRow(to: stack, mode: .follow, title: "惯性时长", range: 0.2...0.8, decimals: 2,
                     get: { $0.inertiaTau }, set: { $0.inertiaTau = $1 })
        addSliderRow(to: stack, mode: .follow, title: "吸附时长", range: 0.15...0.6, decimals: 2,
                     get: { $0.settleDuration }, set: { $0.settleDuration = $1 })
        addSliderRow(to: stack, mode: .follow, title: "吸附弹性", range: 1.0...1.8, decimals: 2,
                     get: { $0.settleOvershoot }, set: { $0.settleOvershoot = $1 })
        addSliderRow(to: stack, mode: .follow, title: "甩动翻页阈值", range: 500...2000, decimals: 0,
                     get: { $0.flingVelocity }, set: { $0.flingVelocity = $1 })
        addSliderRow(to: stack, mode: .follow, title: "惯性触发阈值", range: 100...500, decimals: 0,
                     get: { $0.minInertiaVelocity }, set: { $0.minInertiaVelocity = $1 })

        let resetButton = NSButton(title: "恢复默认设置", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8)
        ])
        return view
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func addSliderRow(
        to stack: NSStackView,
        mode: InteractionMode,
        title: String,
        range: ClosedRange<Double>,
        decimals: Int,
        get: @escaping (PanConfig) -> Double,
        set: @escaping (inout PanConfig, Double) -> Void
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let slider = NSSlider(value: get(currentConfig), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true

        let valueLabel = NSTextField(labelWithString: format(get(currentConfig), decimals: decimals))
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)

        sliderBindings.append(SliderBinding(slider: slider, valueLabel: valueLabel, mode: mode, get: get, set: set))
        stack.addArrangedSubview(row)
    }

    // MARK: 快捷键页

    private func buildHotKeyView() -> NSView {
        let view = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: "点击快捷键按钮，然后按下新的组合键即可修改。Esc 取消。")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)
        stack.addArrangedSubview(hint)

        for action in HotKeyAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12

            let label = NSTextField(labelWithString: title(for: action))
            label.font = NSFont.systemFont(ofSize: 13)
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true

            let button = NSButton(title: "", target: self, action: #selector(hotKeyClicked(_:)))
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 160).isActive = true
            hotKeyButtons[action] = button

            row.addArrangedSubview(label)
            row.addArrangedSubview(button)
            stack.addArrangedSubview(row)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8)
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
        // 只显示当前模式对应的滑块，避免调了不生效
        let showStep = mode == .step
        stepHeader?.isHidden = !showStep
        followHeader?.isHidden = showStep
        for binding in sliderBindings {
            let visible = binding.mode == mode
            binding.slider.isHidden = !visible
            binding.valueLabel.isHidden = !visible
            if visible {
                binding.slider.doubleValue = binding.get(currentConfig)
                binding.valueLabel.stringValue = format(binding.get(currentConfig), decimals: decimals(for: binding.slider))
            }
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
