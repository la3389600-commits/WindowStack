import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var restoreButton: NSButton?
    private var statusLabel: NSTextField?
    private let arranger = WindowArranger()
    private var settingsController: SettingsWindowController?
    private var hotKeyIDs: [HotKeyAction: UInt32] = [:]
    private var hotKeys: [HotKeyAction: HotKeySpec] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadPreferences()
        registerAllHotKeys()
        setupStatusItem()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 停掉事件拦截与动画驱动，保证正常退出
        arranger.shutdown()
        HotKeyManager.shared.unregisterAll()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "tile":
                arrangeWindows(mode: .tile)
            case "cascade":
                arrangeWindows(mode: .cascade)
            case "restore":
                menuRestore()
            default:
                break
            }
        }
    }

    // MARK: - 偏好（UserDefaults）

    private let configKey = "pan.config"
    private func hotKeyKey(_ action: HotKeyAction) -> String { "hotkey.\(action.rawValue)" }

    private func loadPreferences() {
        if let data = UserDefaults.standard.data(forKey: configKey),
           var config = try? JSONDecoder().decode(PanConfig.self, from: data) {
            // 旧默认 0.26 太短；若用户还停在旧默认，抬到新默认
            if abs(config.switchFadeDuration - 0.26) < 0.001 {
                config.switchFadeDuration = 0.45
                saveConfig(config)
            }
            arranger.config = config
        }
        hotKeys = defaultHotKeys()
        for action in HotKeyAction.allCases {
            if let data = UserDefaults.standard.data(forKey: hotKeyKey(action)),
               let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
                hotKeys[action] = spec
            }
        }
    }

    private func defaultHotKeys() -> [HotKeyAction: HotKeySpec] {
        let mods = UInt32(cmdKey) | UInt32(shiftKey)
        return [
            .tile: HotKeySpec(keyCode: 17, modifiers: mods, display: "⇧⌘T"),
            .cascade: HotKeySpec(keyCode: 8, modifiers: mods, display: "⇧⌘C"),
            .restore: HotKeySpec(keyCode: 15, modifiers: mods, display: "⇧⌘R")
        ]
    }

    private func saveConfig(_ config: PanConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private func saveHotKey(_ action: HotKeyAction, _ spec: HotKeySpec) {
        hotKeys[action] = spec
        if let data = try? JSONEncoder().encode(spec) {
            UserDefaults.standard.set(data, forKey: hotKeyKey(action))
        }
        if let old = hotKeyIDs[action] {
            HotKeyManager.shared.unregister(old)
        }
        let id = HotKeyManager.shared.register(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            self?.performHotKeyAction(action)
        }
        hotKeyIDs[action] = id
    }

    private func registerAllHotKeys() {
        HotKeyManager.shared.unregisterAll()
        hotKeyIDs.removeAll()
        for action in HotKeyAction.allCases {
            guard let spec = hotKeys[action] else { continue }
            let id = HotKeyManager.shared.register(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
                self?.performHotKeyAction(action)
            }
            hotKeyIDs[action] = id
        }
    }

    private func performHotKeyAction(_ action: HotKeyAction) {
        switch action {
        case .tile:
            arrangeWindows(mode: .tile)
        case .cascade:
            arrangeWindows(mode: .cascade)
        case .restore:
            menuRestore()
        }
    }

    private func resetSettings() {
        arranger.config = PanConfig()
        saveConfig(arranger.config)
        hotKeys = defaultHotKeys()
        for action in HotKeyAction.allCases {
            saveHotKey(action, hotKeys[action]!)
        }
        settingsController?.show(config: arranger.config, hotKeys: hotKeys)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        guard let button = item.button else { return }
        let image = NSImage(
            systemSymbolName: "square.3.layers.3d",
            accessibilityDescription: "窗口叠放"
        ) ?? NSImage(named: NSImage.actionTemplateName)

        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "左键点击平铺窗口，右键打开菜单"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // 左键/右键点击都弹出菜单，包含排列、设置、退出
        showMenu(from: sender)
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu(title: "窗口叠放")

        let openPanelItem = NSMenuItem(title: "打开控制面板", action: #selector(showMainWindow), keyEquivalent: "o")
        openPanelItem.target = self
        menu.addItem(openPanelItem)

        menu.addItem(.separator())

        let tileItem = NSMenuItem(title: "平铺窗口", action: #selector(menuTile), keyEquivalent: "t")
        tileItem.target = self
        menu.addItem(tileItem)

        let cascadeItem = NSMenuItem(title: "叠放窗口", action: #selector(menuCascade), keyEquivalent: "c")
        cascadeItem.target = self
        menu.addItem(cascadeItem)

        let restoreItem = NSMenuItem(title: "恢复布局", action: #selector(menuRestore), keyEquivalent: "r")
        restoreItem.target = self
        restoreItem.isEnabled = arranger.canRestore
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let accessibilityItem = NSMenuItem(title: "辅助功能设置…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - 主窗口

    @objc private func showMainWindow() {
        if mainWindow == nil {
            buildMainWindow()
        }
        mainWindow?.center()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "窗口叠放"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WindowStackMainWindow")

        let contentView = NSView()
        window.contentView = contentView

        // 状态行
        let initialCount = WindowArranger.visibleWindowCount()
        let statusLabel = NSTextField(labelWithString: "当前屏幕有 \(initialCount) 个窗口")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        self.statusLabel = statusLabel

        // 三张操作卡片
        let tileCard = actionCard(
            icon: "rectangle.split.2x1",
            title: "平铺窗口",
            subtitle: "同尺寸整齐排开",
            keycap: hotKeys[.tile]?.display ?? "⇧⌘T",
            action: #selector(menuTile)
        )
        let cascadeCard = actionCard(
            icon: "square.3.layers.3d",
            title: "叠放窗口",
            subtitle: "对角层叠可翻页",
            keycap: hotKeys[.cascade]?.display ?? "⇧⌘C",
            action: #selector(menuCascade)
        )
        let restoreCard = actionCard(
            icon: "arrow.uturn.backward",
            title: "恢复布局",
            subtitle: "回到排列之前",
            keycap: hotKeys[.restore]?.display ?? "⇧⌘R",
            action: #selector(menuRestore)
        )
        if let button = restoreCard.subviews.compactMap({ $0 as? NSButton }).first {
            button.isEnabled = false
            restoreButton = button
        }

        let cardRow = NSStackView(views: [tileCard, cascadeCard, restoreCard])
        cardRow.orientation = .horizontal
        cardRow.spacing = 12

        // 分隔线
        let divider = NSBox()
        divider.boxType = .separator

        // 系统状态行
        let permissionText = WindowArranger.isTrusted ? "辅助功能 ✓" : "辅助功能 ✗"
        let permissionLabel = NSTextField(labelWithString: permissionText)
        permissionLabel.font = NSFont.systemFont(ofSize: 11)
        permissionLabel.textColor = WindowArranger.isTrusted ? .secondaryLabelColor : .systemOrange

        let versionLabel = NSTextField(labelWithString: "v1.1")
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor

        let settingsButton = NSButton(title: "偏好设置…", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .controlAccentColor

        let bottomRow = NSStackView(views: [permissionLabel, versionLabel, settingsButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .centerY

        let stack = NSStackView(views: [statusLabel, cardRow, divider, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            cardRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        mainWindow = window
    }

    /// 首页操作卡片：图示 + 名称 + 说明 + 快捷键。
    private func actionCard(icon: String, title: String, subtitle: String, keycap: String, action: Selector) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.fillColor = NSColor(calibratedWhite: 0.5, alpha: 0.09)
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)

        let button = NSButton()
        button.isBordered = false
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        image?.size = NSSize(width: 40, height: 40)
        button.image = image
        button.imagePosition = .imageAbove
        button.contentTintColor = .controlAccentColor

        let centerPara = NSMutableParagraphStyle()
        centerPara.alignment = .center
        centerPara.lineBreakMode = .byWordWrapping

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centerPara
        ]))
        attributed.append(NSAttributedString(string: subtitle + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centerPara
        ]))
        attributed.append(NSAttributedString(string: keycap, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centerPara
        ]))
        button.attributedTitle = attributed
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            button.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            button.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            button.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            box.widthAnchor.constraint(equalToConstant: 110),
            box.heightAnchor.constraint(equalToConstant: 150)
        ])
        return box
    }

    // MARK: - 动作

    @objc private func menuTile() {
        arrangeWindows(mode: .tile)
    }

    @objc private func menuCascade() {
        arrangeWindows(mode: .cascade)
    }

    @objc private func menuRestore() {
        if !arranger.restoreWindows() {
            presentInfo(title: "没有可恢复的布局", message: "当前还没有记录上一次叠放前的窗口位置。")
        } else {
            restoreButton?.isEnabled = false
        }
    }

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onHotKeyChange = { [weak self] action, spec in
                self?.saveHotKey(action, spec)
            }
            controller.onConfigChange = { [weak self] config in
                guard let self else { return }
                self.arranger.config = config
                self.saveConfig(config)
            }
            controller.onResetDefaults = { [weak self] in
                self?.resetSettings()
            }
            settingsController = controller
        }
        settingsController?.show(config: arranger.config, hotKeys: hotKeys)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func arrangeWindows(mode: ArrangementMode) {
        guard WindowArranger.isTrusted else {
            presentAccessibilityPermission()
            return
        }

        let result = arranger.arrangeWindows(mode: mode)
        if result.moved == 0 {
            let title = mode == .tile ? "没有窗口被平铺" : "没有窗口被叠放"
            presentInfo(title: title, message: result.message)
        } else {
            restoreButton?.isEnabled = true
            let action = mode == .tile ? "平铺" : "叠放"
            statusLabel?.stringValue = "已\(action) \(result.moved) 个窗口 · \(result.skipped) 个待翻页"
        }
    }

    private func presentAccessibilityPermission() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "请在“系统设置 > 隐私与安全性 > 辅助功能”中勾选 WindowStack，然后再次点击排列。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "好")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func presentInfo(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
