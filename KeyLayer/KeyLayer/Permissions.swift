import AppKit

enum Permissions {
    /// 是否已被授予「辅助功能」权限（事件拦截的前提）。
    static func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    /// 弹出系统级授权引导对话框（用户点允许后会被引导到「辅助功能」设置页勾选本应用）。
    /// 这是修复「授权后规则不触发」体验的关键：让用户第一时间知道需要在此处开启。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统设置 → 隐私与安全性 → 辅助功能。
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
