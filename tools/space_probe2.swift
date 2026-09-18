// space_probe2.swift — 受控端到端验证
// 读当前空间 → 切到相邻空间 → 读回确认变化 → 切回原空间。
// 全程约 2 秒，结束恢复原状。用于证明 CGSManagedDisplaySetCurrentSpace 真的生效。

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

guard let s0 = snapshot() else { print("snapshot fail"); exit(2) }
print("初始: spaces=\(s0.ids) current=\(s0.current)")
guard let idx = s0.ids.firstIndex(of: s0.current), s0.ids.count > 1 else {
    print("无法定位当前空间或仅 1 个空间"); exit(3)
}
let nextID = s0.ids[(idx + 1) % s0.ids.count]
print("→ 切到 next id=\(nextID) ...")
setSpace(cid, s0.display as CFString, nextID)
Thread.sleep(forTimeInterval: 0.9)
guard let s1 = snapshot() else { print("snapshot2 fail"); exit(4) }
print("切换后: current=\(s1.current) (期望 \(nextID)) => \(s1.current == nextID ? "✅ 切换成功" : "❌ 未生效")")

print("← 切回原空间 id=\(s0.current) ...")
setSpace(cid, s0.display as CFString, s0.current)
Thread.sleep(forTimeInterval: 0.9)
guard let s2 = snapshot() else { print("snapshot3 fail"); exit(5) }
print("恢复后: current=\(s2.current) (期望 \(s0.current)) => \(s2.current == s0.current ? "✅ 已恢复" : "❌ 未恢复")")
