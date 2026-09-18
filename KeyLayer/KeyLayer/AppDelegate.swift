import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯菜单栏应用：不进入 Dock、不在切换器中显示。
        NSApp.setActivationPolicy(.accessory)

        // 需要在真正的 NSApplication 里跑的自检（界面快照 / 快捷键验证）：
        // 只渲染界面与窗口，**不启动事件引擎**（避免与用户正在使用的实例抢事件 tap），
        // 也不弹权限引导，跑完自行退出。
        if AppSelfTestMode.current != .none {
            let s = AppState()
            s.snapshotMode = true
            state = s
            switch AppSelfTestMode.current {
            case .uiSnapshot: UISnapshot.start(state: s) { exit(0) }
            case .shortcuts:  ShortcutSelfTest.run(state: s) { exit(0) }
            case .none:       break
            }
            return
        }

        state = AppState()
        state.refreshAccessibility()

        // 首次未授权时弹出系统授权引导，并打开设置界面，引导用户开启辅助功能权限。
        if !state.accessibilityGranted {
            Permissions.requestAccessibility()
            state.openSettings()
        }
    }

    /// 关键修复：从系统设置（辅助功能授权页）切回 app 时，自动重试拉起事件引擎。
    /// 首次运行若未授权，引擎不会启动；用户去系统设置授权后回到 app，必须在此
    /// 主动重新检查权限并 start，否则事件拦截永远不会生效（表现为「规则没触发」）。
    func applicationDidBecomeActive(_ notification: Notification) {
        state.refreshAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.engine.stop()
    }
}
