// space_probe6.swift — 验证 CGS 切换空间时「屏幕上真实显示的窗口」是否跟着切换
// 之前的 probe2/3 只读回了 CGS 的 current 值（API 中间状态），可能存在假验证。
// 本探针量的是最下游的真实产物：CGWindowListCopyWindowInfo(.optionOnScreenOnly) 的在屏窗口列表。
// 并对比两种 display 参数（UUID vs "Main"）的行为差异。

import Foundation
import AppKit
import CoreGraphics

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
      let setSpace: SetSpaceFn = sym("CGSManagedDisplaySetCurrentSpace") else { print("symbol missing"); exit(1) }
let cid = mainConn()

func snapshot() -> (display: String, ids: [CGSSpaceID], current: CGSSpaceID)? {
    guard let arr = copySpaces(cid)?.takeRetainedValue() else { return nil }
    let displays = (arr as NSArray) as? [[String: Any]] ?? []
    guard let d = displays.first,
          let display = d["Display Identifier"] as? String,
          let curDict = d["Current Space"] as? [String: Any],
          let cur = (curDict["id64"] as? NSNumber)?.uint64Value,
          let sd = d["Spaces"] as? [[String: Any]] else { return nil }
    let ids = sd.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
    return (display, ids, cur)
}

/// 真实下游产物：屏幕上正在显示的应用窗口（layer==0，排除桌面/Dock/菜单栏）。
func onScreenApps() -> [String] {
    guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [String] = []
    for w in arr {
        let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let name  = w[kCGWindowName as String] as? String ?? ""
        if layer == 0, !owner.isEmpty {
            out.append(name.isEmpty ? owner : "\(owner)/\(name)")
        }
    }
    return out.sorted()
}

func describe(_ s: [String]) -> String { s.isEmpty ? "(无普通窗口)" : s.joined(separator: ", ") }

guard let s0 = snapshot() else { print("snapshot fail"); exit(2) }
guard let idx = s0.ids.firstIndex(of: s0.current), s0.ids.count > 1 else { print("无法定位或仅 1 个空间"); exit(3) }
let target = s0.ids[(idx + 1) % s0.ids.count]

let w0 = onScreenApps()
print("【基准】current=\(s0.current)  在屏窗口: \(describe(w0))")
print("----------------------------------------")

// A) 用 display UUID 切换
print("A) setSpace(display=UUID \"\(s0.display.prefix(8))…\", space=\(target))")
setSpace(cid, s0.display as CFString, target)
Thread.sleep(forTimeInterval: 1.2)
let sA = snapshot(); let wA = onScreenApps()
print("   → CGS current=\(sA?.current ?? 0)   在屏窗口: \(describe(wA))")
print("   窗口是否变化: \(wA != w0 ? "✅ 变了" : "❌ 完全没变")")
// 复位
setSpace(cid, s0.display as CFString, s0.current)
Thread.sleep(forTimeInterval: 1.0)
print("   复位后 current=\(snapshot()?.current ?? 0)")
print("----------------------------------------")

// B) 用 "Main" 切换
print("B) setSpace(display=\"Main\", space=\(target))")
setSpace(cid, "Main" as CFString, target)
Thread.sleep(forTimeInterval: 1.2)
let sB = snapshot(); let wB = onScreenApps()
print("   → CGS current=\(sB?.current ?? 0)   在屏窗口: \(describe(wB))")
print("   窗口是否变化: \(wB != w0 ? "✅ 变了" : "❌ 完全没变")")
// 复位
setSpace(cid, s0.display as CFString, s0.current)
Thread.sleep(forTimeInterval: 1.0)
print("   复位后 current=\(snapshot()?.current ?? 0)")
print("----------------------------------------")
print("结论提示：若 A/B 都能让 current 变化但窗口列表有时不变，则说明「桌面未真正切换、仅窗口层异常」。")
