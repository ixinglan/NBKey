// display_uuid_probe.swift
// 验证 P4 多显示器逻辑的核心：把「鼠标所在显示器」映射到 CGS 的 "Display Identifier" UUID。
// 单屏环境下也应精确匹配成功（多屏只是同一方法的自然扩展）。

import Foundation
import AppKit
import CoreGraphics

// 1) 鼠标位置 + 所在显示器 UUID（与 app 内 displayUUIDUnderPointer 相同的算法）
func pointerDisplayUUID() -> String? {
    guard let loc = CGEvent(source: nil)?.location else { return nil }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
    print("活跃显示器数 = \(count)")
    for did in ids {
        let b = CGDisplayBounds(did)
        let hit = b.contains(loc)
        print("  display \(did)  bounds=\(b)  含鼠标=\(hit)")
        if hit, let u = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
            return (CFUUIDCreateString(kCFAllocatorDefault, u) as String).uppercased()
        }
    }
    return nil
}

let mouse = CGEvent(source: nil)?.location ?? .zero
print("鼠标位置 = \(mouse)")
let pUUID = pointerDisplayUUID()
print("鼠标所在显示器 UUID = \(pUUID ?? "nil")")

// 2) CGS 报告的显示器 UUID 列表
typealias CGSConnectionID = UInt32
typealias MainConnFn   = @convention(c) () -> CGSConnectionID
typealias CopySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?

guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY) else {
    print("dlopen fail"); exit(1)
}
func sym<T>(_ n: String) -> T? { guard let p = dlsym(h, n) else { return nil }; return unsafeBitCast(p, to: T.self) }
guard let mainConn: MainConnFn = sym("CGSMainConnectionID"),
      let copySpaces: CopySpacesFn = sym("CGSCopyManagedDisplaySpaces") else { print("symbol missing"); exit(1) }
let cid = mainConn()
guard let arr = copySpaces(cid)?.takeRetainedValue() else { print("no spaces"); exit(2) }
let displays = (arr as NSArray) as? [[String: Any]] ?? []
let cgsUUIDs = displays.compactMap { $0["Display Identifier"] as? String }
print("CGS 报告显示器 UUID = \(cgsUUIDs)")

// 3) 判定
if let pUUID {
    print(cgsUUIDs.contains(pUUID)
          ? "✅ 匹配成功：鼠标所在显示器可正确定位（P4 多屏逻辑成立）"
          : "❌ 不匹配：UUID 映射有问题")
} else {
    print("⚠️ 未取到鼠标所在显示器 UUID（运行时会退化为遍历全部显示器，功能仍可用）")
}
