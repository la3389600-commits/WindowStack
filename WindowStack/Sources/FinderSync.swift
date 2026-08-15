import AppKit
import FinderSync

@objc(WindowStackFinderSync)
final class WindowStackFinderSync: FIFinderSync {
    override init() {
        super.init()

        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override var toolbarItemName: String {
        "窗口叠放"
    }

    override var toolbarItemToolTip: String {
        "平铺、叠放或恢复窗口"
    }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "窗口叠放") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems else {
            return nil
        }

        let menu = NSMenu(title: "窗口叠放")

        let tileItem = NSMenuItem(title: "平铺窗口", action: #selector(tileWindows), keyEquivalent: "")
        tileItem.target = self
        menu.addItem(tileItem)

        let cascadeItem = NSMenuItem(title: "叠放窗口", action: #selector(cascadeWindows), keyEquivalent: "")
        cascadeItem.target = self
        menu.addItem(cascadeItem)

        let restoreItem = NSMenuItem(title: "恢复布局", action: #selector(restoreWindows), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        return menu
    }

    @objc private func tileWindows() {
        openApp(command: "tile")
    }

    @objc private func cascadeWindows() {
        openApp(command: "cascade")
    }

    @objc private func restoreWindows() {
        openApp(command: "restore")
    }

    private func openApp(command: String) {
        var components = URLComponents()
        components.scheme = "windowstack"
        components.host = command

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
