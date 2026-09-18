import AppKit

/// 菜单栏图标与菜单（无 Dock）。
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let onOpenSettings: () -> Void
    private let onRetry: () -> Void
    private let statusText: () -> String
    private weak var statusMenuItem: NSMenuItem?

    init(onOpenSettings: @escaping () -> Void,
         onRetry: @escaping () -> Void,
         statusText: @escaping () -> String) {
        self.onOpenSettings = onOpenSettings
        self.onRetry = onRetry
        self.statusText = statusText
        super.init()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = Self.makeIcon()
            icon.isTemplate = true // 模板图标随菜单栏明暗自动反色
            button.image = icon
            button.toolTip = "NBKey"
        }

        let menu = NSMenu()
        menu.delegate = self
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        let retry = NSMenuItem(title: "检查权限并重试引擎", action: #selector(retryEngine), keyEquivalent: "")
        retry.target = self
        let logItem = NSMenuItem(title: "打开诊断日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        let quit = NSMenuItem(title: "退出 NBKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(status)
        menu.addItem(retry)
        menu.addItem(logItem)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        statusMenuItem = status

        statusItem = item
    }

    @objc private func openSettings() { onOpenSettings() }

    @objc private func retryEngine() {
        onRetry()
        refreshStatus()
    }

    /// 菜单打开时刷新状态文案，使引擎 / 权限状态对用户可见（便于诊断「没触发」问题）。
    private func refreshStatus() {
        statusMenuItem?.title = statusText()
    }

    @objc private func openLog() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey").appendingPathComponent("engine.log")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            onRetry()
            refreshStatus()
        }
    }

    /// 现代科技模板图标：圆角矩形「键/层」外框 + NB 字母，简洁且适配明暗菜单栏。
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setStroke()
        let r = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 5.5, width: 15, height: 14), xRadius: 4, yRadius: 4)
        r.lineWidth = 1.6
        r.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let s = NSAttributedString(string: "NB", attributes: attrs)
        let tw = s.size().width
        s.draw(at: NSPoint(x: (size.width - tw) / 2, y: 7.5))
        image.unlockFocus()
        return image
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        onRetry()      // 每次打开菜单都确保：已授权则启动引擎
        refreshStatus()
    }
}
