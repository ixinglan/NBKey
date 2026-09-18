import Foundation
import CoreGraphics

/// 修饰键集合。使用独立结构体而非 CGEventFlags，便于 Codable 与 Hashable。
struct Modifiers: Codable, Hashable {
    var control = false
    var option = false
    var command = false
    var shift = false
    var function = false

    var hasAny: Bool { control || option || command || shift || function }

    /// 压成 5 个比特（control/option/command/shift/function），用于生成数值签名。
    func modifierBits() -> UInt32 {
        var b: UInt32 = 0
        if control { b |= 1 << 0 }
        if option { b |= 1 << 1 }
        if command { b |= 1 << 2 }
        if shift { b |= 1 << 3 }
        if function { b |= 1 << 4 }
        return b
    }

    func cgFlags() -> CGEventFlags {
        var f: CGEventFlags = []
        if control { f.formUnion(.maskControl) }
        if option { f.formUnion(.maskAlternate) }
        if command { f.formUnion(.maskCommand) }
        if shift { f.formUnion(.maskShift) }
        if function { f.formUnion(.maskSecondaryFn) }
        return f
    }

    static func from(_ flags: CGEventFlags) -> Modifiers {
        Modifiers(control: flags.contains(.maskControl),
                  option: flags.contains(.maskAlternate),
                  command: flags.contains(.maskCommand),
                  shift: flags.contains(.maskShift),
                  function: flags.contains(.maskSecondaryFn))
    }
}

/// 鼠标按键。rawValue 与系统 buttonNumber 对齐（左=0 右=1 中=2 …）。
enum MouseButton: Int, Codable, Hashable, CaseIterable, Identifiable {
    case left = 0, right = 1, middle = 2, button3 = 3, button4 = 4, button5 = 5
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .left: return "左键"
        case .right: return "右键"
        case .middle: return "中键"
        case .button3: return "按键3"
        case .button4: return "按键4"
        case .button5: return "按键5"
        }
    }
}

/// 触发器：键盘组合 或 鼠标组合。
enum Trigger: Codable, Hashable {
    case keyboard(modifiers: Modifiers, keyCode: UInt16)
    case mouse(modifiers: Modifiers, button: MouseButton)

    var isMouse: Bool {
        switch self {
        case .mouse: return true
        case .keyboard: return false
        }
    }

    var modifiers: Modifiers {
        switch self {
        case let .keyboard(modifiers, _): return modifiers
        case let .mouse(modifiers, _): return modifiers
        }
    }

    /// 数值签名（低位：键码/按键号；高位：修饰键比特）。供热路径 O(1) 查表。
    func numericSig() -> UInt32 {
        switch self {
        case let .keyboard(modifiers, keyCode):
            return (UInt32(keyCode) & 0xFF) | (modifiers.modifierBits() << 8)
        case let .mouse(modifiers, button):
            return (UInt32(button.rawValue) & 0xFF) | (modifiers.modifierBits() << 8)
        }
    }

    var description: String {
        switch self {
        case let .keyboard(modifiers, keyCode):
            return modifiersString(modifiers) + keyName(keyCode)
        case let .mouse(modifiers, button):
            let m = modifiersString(modifiers)
            return (m.isEmpty ? "" : m + " + ") + "鼠标\(button.label)"
        }
    }
}

/// 动作：键盘模拟（目标修饰键 + 目标键）。
struct HotkeyAction: Codable, Hashable {
    var modifiers: Modifiers
    var keyCode: UInt16

    var description: String {
        modifiersString(modifiers) + keyName(keyCode)
    }

    /// 是否为「切换桌面」类动作 —— 即系统「在活动空间之间移动」的默认绑定 **⌃← / ⌃→**。
    ///
    /// 抽在这里而不是留在引擎或界面里各写一遍：引擎要靠它决定「走手势切换而不是模拟按键」，
    /// 界面要靠它给用户提示，两处判断一旦不一致就会出现「界面说有提示、行为却不是」的错位。
    var isSpaceSwitch: Bool {
        let m = modifiers
        guard m.control, !m.option, !m.command, !m.shift, !m.function else { return false }
        return keyCode == 123 || keyCode == 124
    }
}

struct HotkeyRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var enabled: Bool
    var trigger: Trigger
    var action: HotkeyAction
}

extension Array where Element == HotkeyRule {
    /// 返回所有处于「冲突」状态的规则 id（多个启用规则拥有相同触发签名即视为冲突）。
    func conflictingIDs() -> Set<UUID> {
        var seen: [UInt32: UUID] = [:]
        var conflicts: Set<UUID> = []
        for rule in self where rule.enabled {
            let base = rule.trigger.numericSig()
            let key = rule.trigger.isMouse ? (UInt32(0x80000000) | base) : base
            if let existing = seen[key] {
                conflicts.insert(existing)
                conflicts.insert(rule.id)
            } else {
                seen[key] = rule.id
            }
        }
        return conflicts
    }
}
