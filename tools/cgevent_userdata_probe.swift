// cgevent_userdata_probe.swift
// 验证 CGEvent 的 kCGEventSourceUserData 字段可写可读 —— 这是本引擎「合成事件标记」
// 防回灌机制的基础。若读写一致，则 EventTapEngine.syntheticMarker 方案成立。
//
// ⚠️ 注意这个探针的结论强度有限（2026-09-18 补充）：
// 它只证明了「同一个事件对象在 post **之前** set/get 一致」，属于自己跟自己对账——
// 真正要回答的问题是「标记能否穿过 CGEvent.post 被**另一个进程**的 tap 在回调里读到」。
// 后者已由 SpaceSelfTest 的「防回灌标记验证」端到端实测（带阳性对照）：
//   A) 不带标记的 Ctrl+鼠标点击 → 切一格（证明实例在跑）
//   B) 带标记的同一个点击       → 空间完全不动（证明标记被读到并跳过）
//   C) 不带标记的 Ctrl+←        → engine.log 新增 RECV sig=379（键盘事件确实进入 tap）
//   D) 带标记的同一个 Ctrl+←    → engine.log 不新增（键盘路径同样被跳过）
// 结论：标记确实保留且有效。以此为准则，勿再仅凭本探针下结论。

import Foundation
import CoreGraphics

let marker: Int64 = 0x4E42_4B59   // "NBKY"

guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
    print("❌ 无法创建 CGEvent"); exit(1)
}
e.setIntegerValueField(.eventSourceUserData, value: marker)
let read = e.getIntegerValueField(.eventSourceUserData)
print("set=\(marker)  read=\(read)  => \(read == marker ? "✅ userData 可读写，marker 机制成立" : "❌ 读写不一致")")

// 对照：未设置标记的事件应为 0（真实用户事件的默认值）
if let e2 = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
    let read2 = e2.getIntegerValueField(.eventSourceUserData)
    print("未设置标记的事件 userData=\(read2) => \(read2 == 0 ? "✅ 默认为 0（不误伤真实事件）" : "⚠️ 默认非 0")")
}
