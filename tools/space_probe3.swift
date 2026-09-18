// space_probe3.swift — 边界行为验证（不循环）
// 步骤：读当前 → 切到最右空间 → 再次尝试「向右」（应越界不切换）→ 读回确认未变 → 切回原空间。
// 与 app 内 SpaceSwitcher.move 使用相同的索引逻辑（target = idx ± 1，越界即 atBoundary）。

import Foundation
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
      let setSpace: SetSpaceFn = sym("CGSManagedDisplaySetCurrentSpace") else {
    print("symbol missing"); exit(1)
}
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

/// 与 app 内逻辑一致：向右移动，越界不切换。
func moveRight() -> String {
    guard let s = snapshot(), let idx = s.ids.firstIndex(of: s.current) else { return "err" }
    let target = idx + 1
    guard target < s.ids.count else { return "atBoundary" }
    setSpace(cid, s.display as CFString, s.ids[target])
    return "switched->\(s.ids[target])"
}

guard let s0 = snapshot() else { print("snapshot fail"); exit(2) }
print("初始: spaces=\(s0.ids) current=\(s0.current) (index \(s0.ids.firstIndex(of: s0.current) ?? -1)/\(s0.ids.count - 1))")

// 1) 先到最右空间
let rightmost = s0.ids.last!
if s0.current != rightmost {
    print("→ 先切到最右 id=\(rightmost) ...")
    setSpace(cid, s0.display as CFString, rightmost)
    Thread.sleep(forTimeInterval: 0.9)
    print("  现在 current=\(snapshot()?.current ?? 0)")
} else {
    print("已在最右 id=\(rightmost)")
}

// 2) 在最右再尝试向右 → 应 atBoundary
let r = moveRight()
print("在最右空间执行「向右」 => \(r) \(r == "atBoundary" ? "✅ 正确（不循环）" : "❌ 意外切换")")
Thread.sleep(forTimeInterval: 0.4)

// 3) 读回确认没有变化
let s2 = snapshot()
print("读回 current=\(s2?.current ?? 0) (期望仍为 \(rightmost)) => \(s2?.current == rightmost ? "✅ 未越界" : "❌ 发生了越界切换")")

// 4) 恢复原空间
if s0.current != s2?.current {
    print("← 恢复原空间 id=\(s0.current) ...")
    setSpace(cid, s0.display as CFString, s0.current)
    Thread.sleep(forTimeInterval: 0.9)
    print("恢复后 current=\(snapshot()?.current ?? 0) (期望 \(s0.current)) => \((snapshot()?.current == s0.current) ? "✅ 已恢复" : "❌ 未恢复")")
} else {
    print("无需恢复（位置未变）")
}
