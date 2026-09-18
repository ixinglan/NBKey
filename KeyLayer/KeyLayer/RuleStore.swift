import Foundation

/// 规则持久化（JSON 存入 Application Support）与默认规则。
enum RuleStore {
    static var url: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rules.json")
    }

    static func load() -> [HotkeyRule] {
        // 仅在「文件不存在 / 解析失败」时回退默认规则；
        // 用户主动删光规则（保存空数组）时应予以尊重，否则重启后规则会「复活」。
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([HotkeyRule].self, from: data) else {
            return defaultRules()
        }
        return rules
    }

    static func save(_ rules: [HotkeyRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 开箱即用的示例：直接对应你举的例子（Ctrl+鼠标左键 → 切换上一个桌面）。
    static func defaultRules() -> [HotkeyRule] {
        [
            HotkeyRule(name: "Ctrl+鼠标左键 → 切换上一个桌面",
                       enabled: true,
                       trigger: .mouse(modifiers: Modifiers(control: true), button: .left),
                       action: HotkeyAction(modifiers: Modifiers(control: true), keyCode: 123)),
            HotkeyRule(name: "Ctrl+鼠标右键 → 切换下一个桌面",
                       enabled: true,
                       trigger: .mouse(modifiers: Modifiers(control: true), button: .right),
                       action: HotkeyAction(modifiers: Modifiers(control: true), keyCode: 124))
        ]
    }
}
