// space_probe.swift — 只读探针
// 目的：验证私有 WindowServer 框架（SkyLight / CoreGraphics）在当前 macOS 上
//       是否仍导出空间管理相关符号，并读取当前 display 的空间列表与当前空间。
// 安全性：仅读取，不调用任何 Set 类接口，不产生副作用。

import Foundation
import CoreGraphics

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

let candidates = [
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
]

var handle: UnsafeMutableRawPointer? = nil
for p in candidates {
    if let hh = dlopen(p, RTLD_LAZY) {
        handle = hh
        print("dlopen OK  : \(p)")
        break
    } else {
        print("dlopen FAIL: \(p) -> \(String(cString: dlerror()!))")
    }
}
guard let h = handle else { print("!! 所有候选框架均无法加载"); exit(2) }

// 1) 探测符号存在性
let symbols = [
    "CGSMainConnectionID",
    "CGSCopyManagedDisplaySpaces",
    "CGSManagedDisplaySetCurrentSpace",
    "CGSGetActiveSpace",
    "CGSSetWorkspace",
    "CGSGetDisplayForUUID",
]
for s in symbols {
    print(dlsym(h, s) != nil ? "SYM  OK   : \(s)" : "SYM  MISS : \(s)")
}

// 2) 读取当前连接与空间结构
typealias MainConnFn = @convention(c) () -> CGSConnectionID
typealias CopySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?

guard let sMain = dlsym(h, "CGSMainConnectionID") else { print("!! 无 CGSMainConnectionID"); exit(3) }
let mainConn = unsafeBitCast(sMain, to: MainConnFn.self)
let cid = mainConn()
print("CGSMainConnectionID = \(cid)")

guard let sCopy = dlsym(h, "CGSCopyManagedDisplaySpaces") else { print("!! 无 CGSCopyManagedDisplaySpaces"); exit(4) }
let copySpaces = unsafeBitCast(sCopy, to: CopySpacesFn.self)

if let arr = copySpaces(cid)?.takeRetainedValue() {
    print("display count = \(CFArrayGetCount(arr))")
    print("---- raw dump ----")
    print(arr as NSArray)
} else {
    print("CGSCopyManagedDisplaySpaces 返回 nil（可能不在主 GUI 会话）")
}
