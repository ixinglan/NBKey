import Foundation

/// 常用系统键（用于「执行动作」目标键下拉）。
struct KeyDef: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let keyCode: UInt16
}

let commonKeys: [KeyDef] = [
    KeyDef(name: "← 左方向键", keyCode: 123),
    KeyDef(name: "→ 右方向键", keyCode: 124),
    KeyDef(name: "↑ 上方向键", keyCode: 126),
    KeyDef(name: "↓ 下方向键", keyCode: 125),
    KeyDef(name: "空格 Space", keyCode: 49),
    KeyDef(name: "回车 Return", keyCode: 36),
    KeyDef(name: "Tab", keyCode: 48),
    KeyDef(name: "Esc", keyCode: 53),
    KeyDef(name: "删除 Backspace", keyCode: 51),
    KeyDef(name: "向前删除", keyCode: 117),
    KeyDef(name: "Home", keyCode: 115),
    KeyDef(name: "End", keyCode: 119),
    KeyDef(name: "Page Up", keyCode: 116),
    KeyDef(name: "Page Down", keyCode: 121),
    KeyDef(name: "F1", keyCode: 122),
    KeyDef(name: "F2", keyCode: 120),
    KeyDef(name: "F3", keyCode: 99),
    KeyDef(name: "F4", keyCode: 118),
    KeyDef(name: "F5", keyCode: 96),
    KeyDef(name: "F6", keyCode: 97),
    KeyDef(name: "F7", keyCode: 98),
    KeyDef(name: "F8", keyCode: 100),
    KeyDef(name: "F9", keyCode: 101),
    KeyDef(name: "F10", keyCode: 109),
    KeyDef(name: "F11", keyCode: 103),
    KeyDef(name: "F12", keyCode: 111)
]

func modifiersString(_ m: Modifiers) -> String {
    var s = ""
    if m.control { s += "⌃" }
    if m.option { s += "⌥" }
    if m.command { s += "⌘" }
    if m.shift { s += "⇧" }
    if m.function { s += "fn" }
    return s
}

func keyName(_ code: UInt16) -> String {
    if let k = commonKeys.first(where: { $0.keyCode == code }) {
        return k.name
    }
    return "键\(code)"
}

/// 紧凑的键位符号，专供「键帽」这类小尺寸展示使用。
///
/// 为什么需要单独一个函数：`keyName` 里的名字是给下拉框用的（「← 左方向键」这样能自解释），
/// 塞进键帽里就太长、会把卡片撑开。这里换成正统的键位符号，一眼可辨且宽度可控。
func keyGlyph(_ code: UInt16) -> String {
    switch code {
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    case 49:  return "space"
    case 36:  return "↩"
    case 48:  return "⇥"
    case 53:  return "⎋"
    case 51:  return "⌫"
    case 117: return "⌦"
    case 115: return "↖"
    case 119: return "↘"
    case 116: return "⇞"
    case 121: return "⇟"
    default:
        if let k = commonKeys.first(where: { $0.keyCode == code }) { return k.name }
        return "键\(code)"
    }
}
