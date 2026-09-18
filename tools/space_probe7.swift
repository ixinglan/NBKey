// space_probe7.swift — 验证「合成 Ctrl+→」能否触发系统的原生空间切换
// 关键变量：CGEventSource 的 stateID。NBKey 之前用 .combinedSessionState（系统不响应），
// 本探针依次测试 combinedSessionState / nil / hidSystemState，看哪种能让系统执行切换。

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64
typealias MainConnFn   = @convention(c) () -> CGSConnectionID
typealias CopySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
typealias SetSpaceFn   = @convention(c) (CGSConnectionID, CFString, CGSSpaceID) -> Void

guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY) else {
    print("dlopen fail"); exit(1)
}
func sym<T>(_ n: String) -> T? { guard let p = dlsym(h, n) else { return nil }; return unsafeBitCast(p, to: T.self) }
guard let mainConn: MainConnFn = sym("CGSMainConnectionID"),
      let copySpaces: CopySpacesFn = sym("CGSCopyManagedDisplaySpaces"),
      let setSpace: SetSpaceFn = sym("CGSManagedDisplaySetCurrentSpace") else { print("sym missing"); exit(1) }
let cid = mainConn()

func snapshot() -> (display: String, current: CGSSpaceID)? {
    guard let arr = copySpaces(cid)?.takeRetainedValue() else { return nil }
    let displays = (arr as NSArray) as? [[String: Any]] ?? []
    guard let d = displays.first,
          let disp = d["Display Identifier"] as? String,
          let cd = d["Current Space"] as? [String: Any],
          let cur = (cd["id64"] as? NSNumber)?.uint64Value else { return nil }
    return (disp, cur)
}

let MARKER: Int64 = 0x4E42_4B59

func post(key: CGKeyCode, down: Bool, source: CGEventSource?) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    e.flags = .maskControl
    e.setIntegerValueField(.eventSourceUserData, value: MARKER)
    e.post(tap: .cghidEventTap)
}

func synthCtrlArrow(_ key: CGKeyCode, source: CGEventSource?) {
    post(key: 59, down: true,  source: source)   // Ctrl down
    post(key: key, down: true,  source: source)  // → down
    post(key: key, down: false, source: source)  // → up
    post(key: 59, down: false, source: source)   // Ctrl up
}

guard let s0 = snapshot() else { print("snapshot fail"); exit(2) }
print("AXIsProcessTrusted() = \(AXIsProcessTrusted())")
print("display = \(s0.display.prefix(8))…  current=\(s0.current)")
print("----------------------------------------")

func test(_ label: String, source: CGEventSource?) {
    guard let before = snapshot()?.current else { print("\(label): 读取失败"); return }
    synthCtrlArrow(124, source: source)          // Ctrl + →
    Thread.sleep(forTimeInterval: 1.2)
    guard let after = snapshot()?.current else { print("\(label): 读取失败"); return }
    print("\(label): \(before) → \(after)   \(after != before ? "✅ 系统已执行切换" : "❌ 未切换")")
    if after != before {                          // 复位
        setSpace(cid, s0.display as CFString, before)
        Thread.sleep(forTimeInterval: 1.0)
        print("   （已复位 → \(snapshot()?.current ?? 0)）")
    }
}

test("① combinedSessionState（NBKey 当前用法）", source: CGEventSource(stateID: .combinedSessionState))
test("② nil（Rectangle 等工具的做法）",            source: nil)
test("③ hidSystemState（最接近真实硬件）",          source: CGEventSource(stateID: .hidSystemState))
print("----------------------------------------")
print("说明：若三者全部「未切换」且 AXIsProcessTrusted()=false，则说明本探针无辅助功能权限、")
print("      无法代表 NBKey（NBKey 已获授权）；此时需在 NBKey 内部改事件源后由你实测。")
