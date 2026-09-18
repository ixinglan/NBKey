import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// 主菜单项需要的 Objective-C 目标桥。
///
/// 为什么需要它：`AppState` 是纯 Swift 类（`ObservableObject`），无法直接标注 `@objc`，
/// 而 `NSMenuItem` 的 `target/action` 必须走 Objective-C 运行时。用一个最小的 NSObject 中转即可。
private final class MenuActionTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler() }
}

/// 全局可观察状态：持有事件引擎、菜单栏、规则与设置窗口。
final class AppState: ObservableObject {
    @Published var rules: [HotkeyRule]
    @Published var accessibilityGranted: Bool
    @Published var engineRunning: Bool = false
    let engine: EventTapEngine
    // 隐式解包可选：默认 nil，使 init 中 self 在 menuBar 显式赋值前即视为完全初始化，
    // 从而 MenuBarController 的 onOpenSettings 闭包可以安全地 [weak self] 捕获 AppState，
    // 避免 “variable used before being initialized” 编译错误。AppState 生命周期内 menuBar 始终非 nil。
    var menuBar: MenuBarController!
    var window: NSWindow?

    /// 自检模式：只渲染界面，**不启动事件引擎** ——
    /// 避免与用户正在使用的实例同时挂两个事件 tap 互相抢事件。
    var snapshotMode = false

    // 下面两个信号**只服务于界面快照回归**，正常使用时永远是 false、不产生任何行为。
    // 存在的原因：编辑面板与「没生效？」区块都由视图内部的 `@State` 驱动，
    // 外部（快照流程）没法直接触发，偏偏它们又是设置界面的一部分，必须纳入回归。

    /// 置为 true 时主界面会打开「规则编辑」面板。
    @Published var snapshotOpenEditorSignal = false
    /// 置为 true 时主界面会展开底部的「没生效？」区块。
    @Published var snapshotExpandHelpSignal = false

    /// ⌘W / ⌘Q 的本地事件监听器。必须强引用，否则监听器会被立刻释放。
    private var shortcutMonitor: Any?
    /// 主菜单的 action 目标。同样必须强引用。
    private var menuTargets: [MenuActionTarget] = []

    init() {
        self.rules = RuleStore.load()
        self.engine = EventTapEngine()
        self.accessibilityGranted = Permissions.isAccessibilityTrusted()
        self.window = nil
        // self 此刻已完全初始化（menuBar 为隐式解包可选，默认 nil），
        // 闭包可安全捕获 self；menuBar 在 AppState 生命周期内保持非 nil。
        self.menuBar = MenuBarController(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onRetry: { [weak self] in self?.refreshAccessibility() },
            statusText: { [weak self] in
                guard let self else { return "状态未知" }
                if self.engine.isRunning { return "● 引擎运行中" }
                return self.accessibilityGranted ? "○ 已授权 · 重启引擎可生效" : "○ 未授权辅助功能"
            }
        )
        self.engine.updateRules(self.rules)
        installMainMenu()
        installShortcuts()
    }

    deinit {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    }

    // MARK: - 快捷键

    /// 安装应用级快捷键（⌘W 关闭窗口、⌘Q 退出）。
    ///
    /// 为什么必须自己装：本应用是 `LSUIElement`（无 Dock 图标、不显示菜单栏）的后台工具，
    /// 系统**不会**替它挂上 ⌘W / ⌘Q 这类标准快捷键 —— 没有菜单栏就没有「菜单项快捷键」可依赖。
    ///
    /// 用**本地**监听器（`addLocalMonitorForEvents`）而不是全局监听：本地监听只在本应用
    /// 处于激活状态时收到事件，因此不会去抢别的 App 的 ⌘Q —— 那是很严重的越界行为。
    private func installShortcuts() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // 先剔掉与快捷键语义无关的标志位：
            // 大写锁定开着、按了方向键（numericPad）、按住 fn（function）都会体现在
            // modifierFlags 里；不剔掉，下面的 `mods == .command` 就会时真时假，
            // 表现为「⌘W 有时管用有时不管用」这种极难排查的间歇故障。
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .help, .function])
            guard mods == .command else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w":
                self.closeSettings()
                return nil      // 吃掉事件，不再向下传递
            case "q":
                NSApp.terminate(nil)
                return nil
            default:
                return event
            }
        }
    }

    /// 建一份最小主菜单。
    ///
    /// 本应用不显示菜单栏（LSUIElement），菜单本身用户看不到；但 `NSApp.mainMenu`
    /// 依然参与快捷键分发，所以这里等于给 ⌘, / ⌘W / ⌘Q 多挂一层保险
    /// （主防线是上面那个本地监听器）。
    private func installMainMenu() {
        let main = NSMenu()

        // 应用菜单。系统会用 App 名覆盖第一项的标题，所以这里不需要写标题。
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: "关于 NBKey",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let settingsTarget = MenuActionTarget { [weak self] in self?.openSettings() }
        menuTargets.append(settingsTarget)
        let prefs = NSMenuItem(title: "设置…",
                               action: #selector(MenuActionTarget.fire(_:)),
                               keyEquivalent: ",")
        prefs.target = settingsTarget
        appMenu.addItem(prefs)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 NBKey",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 NBKey",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // 窗口菜单：target 留空 → 沿响应链找到当前的 key window 自己处理。
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - 权限与引擎

    func refreshAccessibility() {
        accessibilityGranted = Permissions.isAccessibilityTrusted()
        if accessibilityGranted, !engine.isRunning, !snapshotMode {
            engine.start()
        }
        engineRunning = engine.isRunning
    }

    // MARK: - 规则

    func save() {
        RuleStore.save(rules)
        engine.updateRules(rules)
    }

    func add(_ rule: HotkeyRule) { rules.append(rule); save() }

    func update(_ rule: HotkeyRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    func remove(_ rule: HotkeyRule) { rules.removeAll { $0.id == rule.id }; save() }

    func conflictingIDs() -> Set<UUID> { rules.conflictingIDs() }

    func beginCapture(completion: @escaping (Trigger) -> Void) { engine.beginCapture(completion: completion) }

    // MARK: - 设置窗口

    func openSettings() {
        if window == nil {
            let vc = NSHostingController(rootView: SettingsView().environmentObject(self))
            let w = NSWindow(contentViewController: vc)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = "NBKey 设置"
            // 隐藏标题栏文字：内容区顶部已经有一个更完整的「NBKey + 副标题」头部栏，
            // 两处都写标题属于重复信息。标题本身仍保留（Mission Control、窗口菜单要用）。
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 740, height: 540)
            w.setContentSize(NSSize(width: 800, height: 640))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭设置窗口（⌘W）。
    /// 走 `performClose` 而不是 `orderOut`：前者会经过窗口自身的关闭流程，
    /// 将来若加「有未保存修改」之类的拦截也能生效。
    func closeSettings() {
        window?.performClose(nil)
    }
}
