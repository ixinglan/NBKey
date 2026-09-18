import AppKit
import CoreGraphics

/// 全局事件拦截引擎。
///
/// 关键设计：使用 **CGEventTap（active tap）**，而不是 NSEvent 的全局监听。
/// 只有事件拦截能在命中自定义组合时「吃掉」原始事件，从而避免与系统默认行为冲突
/// （例如 Ctrl+左键在 macOS 里本就是右键菜单）。这正是「在系统快捷键之上再加一层、
/// 实现系统本身组合不了的效果」的核心机制。
///
/// 性能与稳定性：
/// - 热路径只做 O(1) 字典查表，命中失败时不分配任何对象；
/// - 回调跑在主线程 RunLoop，不另起线程、不在回调内做耗时操作；
/// - 拦截被系统超时禁用时自动重新启用；
/// - 合成事件带 `kCGEventSourceUserData` 标记，回调据此跳过自身事件，避免回灌造成死循环
///   （已验证标记会被保留并读到，见 `SpaceSelfTest.runInjectionGuardCheck`）；
/// - deinit 时移除 RunLoop source 与禁用 tap，避免资源泄漏。
final class EventTapEngine {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 仅缓存「启用中」的规则，供匹配零分配查表。
    private var keyboardRules: [UInt32: HotkeyAction] = [:]
    private var mouseRules: [UInt32: HotkeyAction] = [:]

    private var capturing = false
    private var captureCompletion: ((Trigger) -> Void)?
    private var suppressingFeedback = false   // 合成事件期间的临时标志（兜底）
    private var lastUnmatchedLog: TimeInterval = 0

    /// 本引擎合成事件的标记值（写入 kCGEventSourceUserData 字段）。
    /// 回调据此识别并跳过自己发出的事件 —— 这是防回灌的**主防线**：
    /// `CGEvent.post` 是异步的，布尔标志可能在事件到达前就已被复位，
    /// 因此仅靠 `suppressingFeedback` 挡不住（日志里的 `RECV sig=379/380` 即为证据）。
    /// 若不修：一旦用户配置了键盘类规则，合成事件会再次命中该规则 → 递归触发 → 卡死。
    private static let syntheticMarker: Int64 = 0x4E42_4B59   // "NBKY"

    /// 空间切换器：对「切换到上/下一个桌面」类动作，直接调用 WindowServer 私有 API 执行，
    /// 而不是合成 Ctrl+← / Ctrl+→ 按键（后者无法稳定驱动系统的 symbolic hotkey）。
    private let spaceSwitcher = SpaceSwitcher()

    var isRunning: Bool { tap != nil }

    // MARK: - 诊断日志（真实下游验证证据：确认引擎是否运行、事件是否被匹配）

    /// 日志专用串行队列。
    ///
    /// 为什么不能直接写在调用线程上：`diagLog` 会被 `handle()` 调用，而 `handle()` 跑在
    /// **CGEventTap 的回调线程**上。系统对 tap 回调有耗时限制，超时会直接把 tap 禁掉
    /// （然后才靠 `tapDisabledByTimeout` 恢复）—— 表现出来就是偶发卡顿、甚至漏掉用户输入。
    /// 而这里每次调用都要做 `createDirectory` + 新建 `ISO8601DateFormatter` + 开关文件句柄，
    /// 全是最不适合放在回调里的操作。因此统一挪到串行队列异步落盘。
    private static let logQueue = DispatchQueue(label: "com.nbkey.diag.log")

    /// 复用 formatter（每次新建 `ISO8601DateFormatter` 是已知的昂贵操作）。
    /// 只在 `logQueue` 上访问，靠队列的串行性保证线程安全（formatter 本身不是线程安全的）。
    private static let logFormatter = ISO8601DateFormatter()

    private func diagLog(_ message: String) {
        Self.logQueue.async {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NBKey")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("engine.log")
            let line = "[\(Self.logFormatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let fh = FileHandle(forWritingAtPath: url.path) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - 规则更新

    func updateRules(_ rules: [HotkeyRule]) {
        var kb: [UInt32: HotkeyAction] = [:]
        var mb: [UInt32: HotkeyAction] = [:]
        for rule in rules where rule.enabled {
            let sig = rule.trigger.numericSig()
            if rule.trigger.isMouse {
                mb[sig] = rule.action
            } else {
                kb[sig] = rule.action
            }
        }
        keyboardRules = kb
        mouseRules = mb

        // 任何规则变更都顺手重新启用 tap，作为超时后的兜底恢复手段。
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: - 启动 / 停止

    func start() {
        guard tap == nil else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        var mask: CGEventMask = 0
        for t in [CGEventType.keyDown,
                  CGEventType.leftMouseDown,
                  CGEventType.rightMouseDown,
                  CGEventType.otherMouseDown] {
            mask |= (CGEventMask(1) << CGEventMask(t.rawValue))
        }

        // 未授权辅助功能时 tapCreate 返回 nil，此时不创建，等待用户授权后重试。
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: Self.eventTapCallback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return
        }

        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.commonModes)
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        diagLog("ENGINE START 已启用规则: 键盘 \(keyboardRules.count) / 鼠标 \(mouseRules.count) / CGS \(spaceSwitcher.isAvailable ? "可用" : "不可用")")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.commonModes)
        }
        runLoopSource = nil
        tap = nil
        diagLog("ENGINE STOP")
    }

    deinit { stop() }

    // MARK: - 录制

    func beginCapture(completion: @escaping (Trigger) -> Void) {
        capturing = true
        captureCompletion = completion
    }

    func cancelCapture() {
        capturing = false
        captureCompletion = nil
    }

    // MARK: - C 回调（不捕获上下文，仅通过 userInfo 取回 self）

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passRetained(event)
        }
        let engine = Unmanaged<EventTapEngine>.fromOpaque(refcon).takeUnretainedValue()
        return engine.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 拦截被系统禁用时（超时 / 用户输入）重新启用；该控制事件不向下传递。
        // 注意：只处理 tapDisabledByTimeout 是不够的 —— tapDisabledByUserInput 同样会禁用 tap，
        // 若不恢复会导致引擎「静默失效」（表现为按了没反应）。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        // 本引擎自身合成的事件：带标记，直接放行、不参与匹配（防回灌主防线）。
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passRetained(event)
        }

        guard let candidate = Self.sigForEvent(type, event) else {
            return Unmanaged.passRetained(event)
        }

        // 录制模式：只记录触发组合，不拦截、不触发。
        if capturing {
            if let trigger = Self.triggerFromEvent(type, event) {
                capturing = false
                let cb = captureCompletion
                captureCompletion = nil
                cb?(trigger)
            }
            return Unmanaged.passRetained(event)
        }

        // 这里曾经有一个 suppressesFeedback 布尔标志，已删除。
        // 原因：它包住的是 execute() 的**同步**段，而本回调不会重入（tap 回调由主 RunLoop 串行驱动，
        // 合成事件也是异步投递、稍后才到达），所以它在被读取时恒为 false —— 是永远不会生效的死代码，
        // 留着只会让人误以为多了一层防护。真正的防回灌就是上面那个 userData 标记。
        // 标记确实有效，已由 selftest 的「防回灌标记验证」实测确认（阳性对照不带标记 → 切一格；
        // 带标记 → 空间完全不动）。
        let action: HotkeyAction? = candidate.isMouse ? mouseRules[candidate.sig] : keyboardRules[candidate.sig]
        if let action {
            execute(action)
            diagLog("HIT sig=\(candidate.sig) flags=\(event.flags.rawValue) 拦截原事件并执行动作")
            return nil // 拦截原始事件
        }

        // 引擎在跑但当前事件无匹配规则：节流记录，既能证明引擎在监听，又避免刷屏。
        let now = Date().timeIntervalSince1970
        if now - lastUnmatchedLog > 2 {
            lastUnmatchedLog = now
            diagLog("RECV sig=\(candidate.sig) flags=\(event.flags.rawValue) 无匹配规则")
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - 事件 → 签名/触发器

    private static func sigForEvent(_ type: CGEventType, _ event: CGEvent) -> (isMouse: Bool, sig: UInt32)? {
        let mods = Modifiers.from(event.flags).modifierBits()
        switch type {
        case .keyDown:
            let kc = UInt32(event.getIntegerValueField(.keyboardEventKeycode) & 0xFF)
            return (false, kc | (mods << 8))
        case .leftMouseDown:
            return (true, 0 | (mods << 8))
        case .rightMouseDown:
            return (true, 1 | (mods << 8))
        case .otherMouseDown:
            let b = UInt32(event.getIntegerValueField(.mouseEventButtonNumber) & 0xFF)
            return (true, b | (mods << 8))
        default:
            return nil
        }
    }

    /// 仅接受「安全」的触发组合：
    /// - 键盘：非单独修饰键的任意键；
    /// - 鼠标：中键/其它键可单独使用；左/右键必须配合至少一个修饰键（避免劫持所有点击）。
    private static func triggerFromEvent(_ type: CGEventType, _ event: CGEvent) -> Trigger? {
        let mods = Modifiers.from(event.flags)
        switch type {
        case .keyDown:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode) & 0xFF)
            if [55, 56, 58, 59, 63].contains(kc) { return nil } // 排除单独修饰键
            return .keyboard(modifiers: mods, keyCode: kc)
        case .leftMouseDown:
            guard mods.hasAny else { return nil }
            return .mouse(modifiers: mods, button: .left)
        case .rightMouseDown:
            guard mods.hasAny else { return nil }
            return .mouse(modifiers: mods, button: .right)
        case .otherMouseDown:
            let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let btn = MouseButton(rawValue: b) ?? .middle
            return .mouse(modifiers: mods, button: btn)
        default:
            return nil
        }
    }

    // MARK: - 触发系统动作

    /// 把「切换空间」类动作映射为方向。
    /// 判定条件本身放在 `HotkeyAction.isSpaceSwitch`，界面与引擎共用同一份定义。
    private static func spaceSwitchDirection(for action: HotkeyAction) -> SpaceSwitcher.Direction? {
        guard action.isSpaceSwitch else { return nil }
        return action.keyCode == 123 ? .left : .right
    }

    private func execute(_ action: HotkeyAction) {
        // 空间切换：不模拟按键，而是让系统走自己的 Dock 手势管线（带动画、台前调度正确）。
        // 详见 switchSpace 的说明。
        if let dir = Self.spaceSwitchDirection(for: action) {
            switchSpace(dir)
            return
        }

        // 通用路径：合成键盘快捷键。
        let source = CGEventSource(stateID: .combinedSessionState)
        let order: [(CGEventFlags, UInt16)] = [
            (.maskControl, 59),
            (.maskAlternate, 58),
            (.maskCommand, 55),
            (.maskShift, 56)
        ]
        let flags = action.modifiers.cgFlags()

        // 1) 依次按下目标修饰键
        for (flag, code) in order where flags.contains(flag) {
            post(keycode: code, keyDown: true, flags: flags, source: source)
        }
        // 2) 按下并松开目标键
        post(keycode: action.keyCode, keyDown: true, flags: flags, source: source)
        post(keycode: action.keyCode, keyDown: false, flags: flags, source: source)
        // 3) 逆序松开修饰键
        for (flag, code) in order.reversed() where flags.contains(flag) {
            post(keycode: code, keyDown: false, flags: flags, source: source)
        }
    }

    // MARK: - 空间切换（原生手势管线优先，CGS 兜底）

    /// 轮询校验的采样间隔。实测「按下 → 首个可见变化」约 700~780ms，60ms 的采样精度足够。
    private static let switchPollInterval: TimeInterval = 0.06
    /// 各步的最长等待。因为是**轮询**、一旦发现空间已变就立刻结束，正常路径的确认耗时
    /// 就等于真实切换耗时（约 0.8s），比原先「固定等 1.2s 再看一眼」又快又稳。
    private static let switchAnimatedTimeout: TimeInterval = 1.8
    private static let switchInstantTimeout: TimeInterval = 1.2
    /// 上一轮手势结束到下一轮开始之间的静默间隔，留给 Dock 的手势状态机复位。
    private static let switchSettleGap: TimeInterval = 0.12
    /// 排队队列上限。防止用户狂按之后出现「松手了还在自己切桌面」的排空现象。
    private static let pendingSwitchesLimit = 4

    /// 当前是否有一条切换链在途。
    /// 用于把「快速连按」从**并发叠加**收敛成**串行排队**。
    private var spaceSwitchInFlight = false
    /// 在途期间到来的切换请求队列（FIFO）。当前链结束后依次补做。
    /// 用队列而不是「只记最后一次」：连按三下就该切三格，丢掉请求等于吞掉用户输入。
    private var pendingSwitches: [SpaceSwitcher.Direction] = []

    /// 空间切换。三条路径按「保真度」从高到低依次尝试，每一步都用 WindowServer 报告的
    /// 真实当前空间 ID 复核 —— 不拿「我发了什么事件」当证据。
    ///
    /// 1. Dock 手势管线（带动画）：合成一次触控板三指横滑的 Dock 手势事件。
    ///    系统会走与用户手动滑动**完全相同**的路径 —— 带动画，且台前调度能正确重排。
    ///    这正是 CGS 直切做不到的地方。
    /// 2. Dock 手势管线（瞬时）：同样经过 Dock，只是用高速度让系统跳过动画。
    /// 3. CGS 私有 API 直切：必定生效，但不经过 Dock，台前调度可能不同步。
    ///
    /// 为什么不再合成 Ctrl+←/→（已实测排除）：
    /// macOS 26 的 WindowServer 会直接忽略合成事件去触发「移动空间」这一 symbolic hotkey。
    /// 自检矩阵在 AXIsProcessTrusted=true 的环境下测过 6 种变体（hidSystemState /
    /// combinedSessionState / privateState，带或不带 Ctrl 标志、带或不带 userData 标记），
    /// 全部未切换；而同时运行的实例确实收到了这些事件（engine.log 记录到 RECV sig=380，
    /// 即 keyCode 124 + Ctrl 位），说明事件已投递、只是系统不接受。
    /// 这是系统行为，不是本项目的实现 bug。
    ///
    /// 并发保护：整条链耗时约 0.8s，期间到来的新请求不会叠加，而是排队等这条链收尾。
    private func switchSpace(_ dir: SpaceSwitcher.Direction) {
        let side = (dir == .left) ? "left" : "right"

        // 防叠加（重要）：一条切换链要跑约 0.8s（手势分次投递 + 轮询校验）。
        // 若在途期间再发起一条，两个手势序列会在 Dock 侧交错叠加（Begin/Changed/End 互相插入），
        // 而且两个校验回调各自「自认为成功」—— 表现出来就是**一次按键跳好几格**。
        // 注意这里不是丢弃请求而是排队：连按 N 下仍然切 N 格，但保证每格都只切一格。
        guard !spaceSwitchInFlight else {
            if pendingSwitches.count < Self.pendingSwitchesLimit {
                pendingSwitches.append(dir)
                diagLog("SPACE \(side) 上一条切换链尚未结束，本次请求排队"
                        + "（队列 \(pendingSwitches.count)/\(Self.pendingSwitchesLimit)，不叠加）")
            } else {
                diagLog("SPACE \(side) 排队已满（\(Self.pendingSwitchesLimit)），忽略本次")
            }
            return
        }
        beginSwitchChain(dir)
    }

    /// 起一条切换链。`canMove` 在这里重新判断 —— 排队请求真正执行时，空间位置可能已经不是当初那个了。
    private func beginSwitchChain(_ dir: SpaceSwitcher.Direction) {
        let side = (dir == .left) ? "left" : "right"

        // 边界判断前置：到最左/最右不循环，与系统行为保持一致。
        guard spaceSwitcher.canMove(dir) else {
            diagLog("SPACE \(side) 已到边界，忽略（不循环）")
            endSwitchChain()
            return
        }
        spaceSwitchInFlight = true
        let before = spaceSwitcher.currentSpaceOnPointerDisplay()
        attemptSwitch(dir, side: side, before: before, step: 1)
    }

    /// 一条切换链收尾（成功 / 到边界 / 兜底完毕都走这里）：清在途标志，并补做排队的请求。
    private func endSwitchChain() {
        spaceSwitchInFlight = false
        guard !pendingSwitches.isEmpty else { return }
        let next = pendingSwitches.removeFirst()
        diagLog("执行排队的切换请求（剩余 \(pendingSwitches.count)）")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchSettleGap) { [weak self] in
            self?.beginSwitchChain(next)
        }
    }

    /// 逐级尝试切换。step: 1=带动画手势，2=瞬时手势（重试一次），3=CGS 兜底。
    ///
    /// 为什么 CGS 必须放在最后、且只在两次手势都失败后才用：
    /// 实测（selftest.log 的连续行走测试）发现，CGS 直切会让 Dock 的手势状态与真实空间脱节，
    /// **污染紧接着的下一次手势** —— 表现为下一次手势一次跳 2 格。行走测试里 8 步有 7 步精确
    /// ±1，唯一跳 2 格的那步正好紧跟在一次 CGS 复位之后。所以正常路径绝不能碰 CGS。
    private func attemptSwitch(_ dir: SpaceSwitcher.Direction, side: String,
                               before: UInt64?, step: Int) {
        if step >= 3 {
            switch spaceSwitcher.move(dir) {
            case .switched:
                diagLog("SPACE \(side) 手势管线未生效，已用 CGS 兜底 "
                        + "[\(spaceSwitcher.lastDisplayDesc) spaces=\(spaceSwitcher.lastSpacesDesc)]")
            case .atBoundary:
                diagLog("SPACE \(side) 已到边界，忽略（不循环）")
            case .unavailable:
                diagLog("SPACE \(side) 手势管线与 CGS 均不可用")
            }
            endSwitchChain()
            return
        }

        let style: SpaceSwipe.Style = (step == 1) ? .animated : .instant
        SpaceSwipe.post(dir, style: style)

        let started = Date()
        let timeout = (step == 1) ? Self.switchAnimatedTimeout : Self.switchInstantTimeout
        pollSwitchResult(dir: dir, side: side, before: before, step: step,
                         started: started, deadline: started.addingTimeInterval(timeout))
    }

    /// 轮询校验：只认 WindowServer 报告的**真实当前空间**是否变化，不认自己发了什么事件。
    ///
    /// 为什么不是「发完手势固定等 1.2s 再查一次」：
    /// 1.2s 相对实测的 700~780ms 切换延迟只留约 400ms 余量，任何一次动画偏慢都会被判成
    /// 「未生效」而补发第二次手势 —— 那正是随机出现「一次按键跳两格」的来源。
    /// 改成轮询后，一旦切成功就立刻收工（不白等），判据也宽容得多。
    private func pollSwitchResult(dir: SpaceSwitcher.Direction, side: String, before: UInt64?,
                                  step: Int, started: Date, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchPollInterval) { [weak self] in
            guard let self else { return }
            let now = self.spaceSwitcher.currentSpaceOnPointerDisplay()

            // 只有「起点读到过明确的值」且「现在确实与起点不同」才算成功。
            // ⚠️ `before == nil` 时**绝不能判成功** —— 那等于什么都没验证却报「切换成功」，
            // 典型的自己跟自己对账。读不到起点就继续降级，最终由 CGS 兜底真正把空间切过去。
            if let before, let now, now != before {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let how = (step == 1) ? "带动画" : "瞬时"
                self.diagLog("SPACE \(side) 原生手势管线切换成功（\(how)）耗时 \(ms)ms")
                self.endSwitchChain()
                return
            }

            if Date() < deadline {
                self.pollSwitchResult(dir: dir, side: side, before: before, step: step,
                                      started: started, deadline: deadline)
                return
            }

            let waited = Int(Date().timeIntervalSince(started) * 1000)
            if before == nil, now == nil {
                diagLog("SPACE \(side) 起点与当前空间均不可读，无法校验 —— 降级到下一策略（不臆断成功）")
            } else if before == nil {
                diagLog("SPACE \(side) 起点空间不可读，无法校验 —— 降级到下一策略（不臆断成功）")
            } else {
                diagLog("SPACE \(side) 等待 \(waited)ms 仍未变化，降级到下一策略")
            }
            self.attemptSwitch(dir, side: side, before: before, step: step + 1)
        }
    }

    private func post(keycode: UInt16, keyDown: Bool, flags: CGEventFlags, source: CGEventSource?) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: keyDown) else { return }
        e.flags = flags
        // 打上标记：回调据此识别并跳过本引擎合成的事件，杜绝回灌命中规则造成的递归。
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - 空间切换器（WindowServer 私有 API）

/// 通过 SkyLight 框架的私有 CGS 接口直接切换「活动空间」。
///
/// 为什么不用合成按键：用 CGEvent 合成 Ctrl+← / Ctrl+→ 去触发系统
/// 「在活动空间之间移动」这一 symbolic hotkey，在 macOS 上并不可靠——
/// 系统对合成事件的接受度不稳定，会出现「拦截命中、按键已发出、但桌面不切」的现象。
/// 直接调用 `CGSManagedDisplaySetCurrentSpace` 与系统行为一致且稳定。
///
/// 仅用于本地工具（App Store 不允许私有 API）。符号在 macOS 26 上已验证可用：
/// CGSMainConnectionID / CGSCopyManagedDisplaySpaces / CGSManagedDisplaySetCurrentSpace。
final class SpaceSwitcher {
    enum Direction { case left, right }

    private typealias CGSConnectionID = UInt32
    private typealias CGSSpaceID = UInt64
    private typealias MainConnFn   = @convention(c) () -> CGSConnectionID
    private typealias CopySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias SetSpaceFn   = @convention(c) (CGSConnectionID, CFString, CGSSpaceID) -> Void

    private var handle: UnsafeMutableRawPointer?
    private var mainConn: MainConnFn?
    private var copySpaces: CopySpacesFn?
    private var setSpace: SetSpaceFn?

    init() {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        ]
        for p in paths where handle == nil {
            handle = dlopen(p, RTLD_LAZY)
        }
        guard let h = handle else { return }
        mainConn = Self.symbol(h, "CGSMainConnectionID")
        copySpaces = Self.symbol(h, "CGSCopyManagedDisplaySpaces")
        setSpace = Self.symbol(h, "CGSManagedDisplaySetCurrentSpace")
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    var isAvailable: Bool { handle != nil && mainConn != nil && copySpaces != nil && setSpace != nil }

    /// 读取当前活动空间 ID（UInt64）。
    ///
    /// ⚠️ 已被 `currentSpaceOnPointerDisplay()` 取代，**当前无调用点**（自检与探针各自有独立实现）。
    /// 它只读 `displays.first`，多显示器时会拿到另一块屏的状态 —— 正是这个坑催生了
    /// `currentSpaceOnPointerDisplay()`。保留仅为兼容早期探针，新代码请勿使用。
    func currentSpaceID() -> UInt64? {
        guard let cid = mainConn?(),
              let arr = copySpaces?(cid)?.takeRetainedValue() else { return nil }
        let displays = (arr as NSArray) as? [[String: Any]] ?? []
        guard let d = displays.first,
              let cd = d["Current Space"] as? [String: Any],
              let cur = (cd["id64"] as? NSNumber)?.uint64Value else { return nil }
        return cur
    }

    /// 直接切换到指定空间 ID（自检复位等场景使用）。
    @discardableResult
    func goto(_ spaceID: UInt64) -> Bool {
        guard let cid = mainConn?(),
              let arr = copySpaces?(cid)?.takeRetainedValue() else { return false }
        let displays = (arr as NSArray) as? [[String: Any]] ?? []
        for d in displays {
            guard let display = d["Display Identifier"] as? String,
                  let sd = d["Spaces"] as? [[String: Any]] else { continue }
            let ids = sd.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            if ids.contains(spaceID) {
                setSpace?(cid, display as CFString, spaceID)
                return true
            }
        }
        return false
    }

    /// 鼠标当前所在显示器上的当前空间 ID。
    /// 注意与 `currentSpaceID()`（只读第一个显示器）的区别：多显示器时切换动作只作用于
    /// 鼠标所在那块屏，校验也必须读同一块屏，否则会拿 A 屏的状态去判断 B 屏的操作。
    func currentSpaceOnPointerDisplay() -> UInt64? {
        guard let cid = mainConn?(),
              let arr = copySpaces?(cid)?.takeRetainedValue() else { return nil }
        let displays = (arr as NSArray) as? [[String: Any]] ?? []
        let pointerUUID = displayUUIDUnderPointer()
        let target = displays.first { ($0["Display Identifier"] as? String) == pointerUUID } ?? displays.first
        guard let d = target, let cd = d["Current Space"] as? [String: Any] else { return nil }
        return (cd["id64"] as? NSNumber)?.uint64Value
    }

    /// 是否还能朝该方向移动（到最左/最右即为 false）。
    /// 用于把边界判断前置：手势类方案会「移动一格」，在边界处必须先拦掉，
    /// 否则系统行为不可预期（与系统「不循环」的语义不一致）。
    func canMove(_ direction: Direction) -> Bool {
        let ids = spaceIDsOnPointerDisplay()
        guard let cur = currentSpaceOnPointerDisplay(), let idx = ids.firstIndex(of: cur) else { return true }
        let target = direction == .left ? idx - 1 : idx + 1
        return target >= 0 && target < ids.count
    }

    /// 鼠标当前所在显示器的空间 ID 列表（按顺序）。取不到时退化为第一个显示器。
    /// 自检时用它把起点定位到最左/最右，避免一上来就撞边界而误判成「合成按键无效」。
    func spaceIDsOnPointerDisplay() -> [UInt64] {
        guard let cid = mainConn?(),
              let arr = copySpaces?(cid)?.takeRetainedValue() else { return [] }
        let displays = (arr as NSArray) as? [[String: Any]] ?? []
        let pointerUUID = displayUUIDUnderPointer()
        let target = displays.first { ($0["Display Identifier"] as? String) == pointerUUID } ?? displays.first
        guard let d = target, let sd = d["Spaces"] as? [[String: Any]] else { return [] }
        return sd.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
    }

    /// 鼠标所在显示器最左 / 最右的空间 ID。
    func edgeSpaceID(_ edge: Direction) -> UInt64? {
        let ids = spaceIDsOnPointerDisplay()
        return edge == .left ? ids.first : ids.last
    }

    /// 切换结果：成功 / 已到边界（不循环）/ 私有 API 不可用（需回退）。
    enum Result { case switched, atBoundary, unavailable }

    /// 记录最近一次切换所用的显示器信息与空间顺序（供诊断日志使用）。
    private(set) var lastDisplayDesc: String = "-"
    private(set) var lastSpacesDesc: String = "-"

    /// 在「鼠标当前所在显示器」上按方向移动到相邻空间。
    ///
    /// 多显示器场景：每个显示器有各自独立的空间列表，应只切换**鼠标所在那块屏**的空间；
    /// 取不到鼠标位置时退化为遍历全部显示器。边界行为与系统一致：到最左/最右不循环。
    @discardableResult
    func move(_ direction: Direction) -> Result {
        guard let cid = mainConn?(),
              let arr = copySpaces?(cid)?.takeRetainedValue() else { return .unavailable }
        let displays = (arr as NSArray) as? [[String: Any]] ?? []
        guard !displays.isEmpty else { return .unavailable }

        // 鼠标所在显示器优先，其余作为兜底。
        let pointerUUID = displayUUIDUnderPointer()
        let ordered: [[String: Any]]
        if let pointerUUID {
            ordered = displays.filter { ($0["Display Identifier"] as? String) == pointerUUID }
                    + displays.filter { ($0["Display Identifier"] as? String) != pointerUUID }
        } else {
            ordered = displays
        }
        lastDisplayDesc = "\(displays.count)屏 uuid=\(pointerUUID?.prefix(8) ?? "-")"

        // 区分「确实走到边界」与「压根读不到可用的显示器」：
        // 两者都不能切，但语义不同，日志里混在一起会掩盖真正的读取故障。
        var sawUsableDisplay = false

        for d in ordered {
            guard let display = d["Display Identifier"] as? String,
                  let curDict = d["Current Space"] as? [String: Any],
                  let current = (curDict["id64"] as? NSNumber)?.uint64Value,
                  let spaceDicts = d["Spaces"] as? [[String: Any]] else { continue }
            sawUsableDisplay = true

            let ids = spaceDicts.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard let idx = ids.firstIndex(of: current) else { continue }

            let target = direction == .left ? idx - 1 : idx + 1
            guard target >= 0, target < ids.count else { return .atBoundary }

            lastSpacesDesc = "\(ids) current=\(current) → \(ids[target])"
            setSpace?(cid, display as CFString, ids[target])
            return .switched
        }
        return sawUsableDisplay ? .atBoundary : .unavailable
    }

    /// 鼠标当前所在显示器的 UUID 字符串，格式与 CGSCopyManagedDisplaySpaces 的
    /// "Display Identifier" 一致（大写）。取不到时返回 nil，调用方退化为遍历全部显示器。
    private func displayUUIDUnderPointer() -> String? {
        guard let loc = CGEvent(source: nil)?.location else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        for did in ids where CGDisplayBounds(did).contains(loc) {
            guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(did) else { continue }
            let uuid = unmanaged.takeRetainedValue()
            return (CFUUIDCreateString(kCFAllocatorDefault, uuid) as String).uppercased()
        }
        return nil
    }
}

// MARK: - Dock 手势合成（让系统走自己的手势管线来切换空间）

/// 通过合成「触控板三指横滑」的 Dock 手势事件来切换空间。
///
/// 为什么是这条路（而不是合成快捷键、也不是 CGS 直切）：
/// - 合成 Ctrl+←/→ 已实测被 macOS 26 的 WindowServer 忽略（见 `switchSpace` 注释）；
/// - CGS 的 `CGSManagedDisplaySetCurrentSpace` 只更新 WindowServer 的记账、不经过 Dock，
///   于是开启台前调度时观感会变成「桌面没切、应用却换了」；
/// - Dock 手势事件是 WindowServer 自己手势管线的入口。走它，等于让系统像用户手动
///   三指滑动那样完成切换：带动画，台前调度也会跟着正确重排。
///
/// 私有字段编号来源：开源实现 andrewyur/iss 与 WebKit 私有头文件（多年保持稳定）。
/// 这些编号只是传给公开函数 `CGEventSet*ValueField` 的整数，无需关闭 SIP，
/// 也不需要任何代码注入。
enum SpaceSwipe {

    /// 手势风格：带动画更接近原生手感，瞬时更快。
    enum Style { case animated, instant }

    // MARK: 私有 CGEvent 字段编号
    //
    // 公开 SDK 里没有这些常量，Swift 的 CGEventField 枚举也不含它们，
    // 因此用 rawValue 构造；构造失败时退回 0（无意义字段），
    // 保证不会因为将来系统删掉某个编号而崩溃。
    private static func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw) ?? CGEventField(rawValue: 0)!
    }
    private enum F {
        static let eventType             = SpaceSwipe.field(55)   // 事件的「真实类型」
        static let gestureHIDType        = SpaceSwipe.field(110)
        static let gestureScrollY        = SpaceSwipe.field(119)
        static let gestureSwipeMotion    = SpaceSwipe.field(123)  // 水平 / 垂直
        static let gestureSwipeProgress  = SpaceSwipe.field(124)  // 累计滑动距离
        static let gestureSwipeVelocityX = SpaceSwipe.field(129)
        static let gestureSwipeVelocityY = SpaceSwipe.field(130)
        static let gesturePhase          = SpaceSwipe.field(132)
        static let scrollGestureFlagBits = SpaceSwipe.field(135)  // 方向提示位
        static let gestureZoomDeltaX     = SpaceSwipe.field(139)  // 参考实现标注「必需，原因不明」
    }

    private enum Const {
        static let eventGesture: Int64 = 29        // kCGSEventGesture
        static let eventDockControl: Int64 = 30    // kCGSEventDockControl
        static let hidDockSwipe: Int64 = 23        // kIOHIDEventTypeDockSwipe
        static let motionHorizontal: Int64 = 1     // kCGGestureMotionHorizontal
        static let phaseBegan: Int64 = 1
        static let phaseChanged: Int64 = 2
        static let phaseEnded: Int64 = 4
    }

    /// 构造一个 DockControl 事件（各相位共用字段）。
    private static func makeDockEvent(phase: Int64, right: Bool) -> CGEvent? {
        guard let e = CGEvent(source: nil) else { return nil }
        e.setIntegerValueField(F.eventType, value: Const.eventDockControl)
        e.setIntegerValueField(F.gestureHIDType, value: Const.hidDockSwipe)
        e.setIntegerValueField(F.gesturePhase, value: phase)
        e.setIntegerValueField(F.scrollGestureFlagBits, value: right ? 1 : 0)
        e.setIntegerValueField(F.gestureSwipeMotion, value: Const.motionHorizontal)
        e.setDoubleValueField(F.gestureScrollY, value: 0)
        e.setDoubleValueField(F.gestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))
        return e
    }

    /// 成对投递「Dock 事件 + 伴随手势事件」，让事件流与真实手势保持一致。
    ///
    /// 注意：CGEvent 的 userData 标记在 CGEventPost 之后**不保留**，
    /// 所以这里无法用标记防回灌；好在本引擎的 tap 只订阅键鼠按下事件，
    /// 不会收到这两类手势事件，不存在回灌风险。
    private static func postPair(_ dock: CGEvent) {
        guard let companion = CGEvent(source: nil) else { return }
        companion.setIntegerValueField(F.eventType, value: Const.eventGesture)
        dock.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }

    /// 手势投递用的串行队列。
    /// 必须离开主线程：完整手势要分几次投递、中间有等待，不能阻塞事件 tap 回调。
    private static let gestureQueue = DispatchQueue(label: "com.nbkey.space.gesture")

    /// 各相位之间的间隔。真实三指滑动的相位是**分散在几百毫秒内**推进的；
    /// 实测把 Begin/Changed/End 全部挤在同一微秒内投递时，同一组参数会出现
    /// 「有时切 1 格、有时切 2 格」的不稳定结果 —— Dock 的状态机需要时间推进相位。
    private static let phaseGap: useconds_t = 40_000   // 40ms

    /// 低层投递：一次 Begin(+可选 Changed)+End 手势。**异步执行**，按真实节奏分次投递。
    /// `progress` 是累计滑动距离（实测 0.3 左右正好切一格；2.0 会被判为「用力甩动」而跨 2 格），
    /// `velocity` 是收尾速度（实测非 0 会放大位移，因此保持 0）。
    static func postRaw(right: Bool, progress: Double, velocity: Double, withChanged: Bool = false) {
        gestureQueue.async {
            let sign: Double = right ? 1 : -1
            guard let begin = makeDockEvent(phase: Const.phaseBegan, right: right) else { return }
            postPair(begin)
            usleep(phaseGap)

            if withChanged, let c = makeDockEvent(phase: Const.phaseChanged, right: right) {
                c.setDoubleValueField(F.gestureSwipeProgress, value: sign * progress * 0.6)
                postPair(c)
                usleep(phaseGap)
            }
            if let end = makeDockEvent(phase: Const.phaseEnded, right: right) {
                end.setDoubleValueField(F.gestureSwipeProgress, value: sign * progress)
                end.setDoubleValueField(F.gestureSwipeVelocityX, value: sign * velocity)
                end.setDoubleValueField(F.gestureSwipeVelocityY, value: 0)
                postPair(end)
            }
        }
    }

    /// 投递一次「切一格」的手势（本版实现的实际入口）。**异步执行**。
    ///
    /// 参数经实测标定（见 selftest.log 的行走测试）：progress ≈ 0.30、velocity = 0
    /// 才是稳定的「正好一格」。速度非 0 会让 Dock 判定为甩动并跨多格。
    static func post(_ dir: SpaceSwitcher.Direction, style: Style) {
        let right = (dir == .right)
        let sign: Double = right ? 1 : -1

        gestureQueue.async {
            guard let begin = makeDockEvent(phase: Const.phaseBegan, right: right) else { return }
            postPair(begin)
            usleep(phaseGap)

            switch style {
            case .animated:
                // 真实三指滑动的样子：进度分几步推进，让 Dock 走完整的过渡动画。
                for frac in [0.08, 0.15, 0.23] {
                    guard let c = makeDockEvent(phase: Const.phaseChanged, right: right) else { return }
                    c.setDoubleValueField(F.gestureSwipeProgress, value: sign * frac)
                    postPair(c)
                    usleep(phaseGap)
                }

            case .instant:
                // 只推进一次，相位少、收尾更快。
                if let c = makeDockEvent(phase: Const.phaseChanged, right: right) {
                    c.setDoubleValueField(F.gestureSwipeProgress, value: sign * 0.15)
                    postPair(c)
                    usleep(phaseGap)
                }
            }

            guard let end = makeDockEvent(phase: Const.phaseEnded, right: right) else { return }
            end.setDoubleValueField(F.gestureSwipeProgress, value: sign * 0.30)
            end.setDoubleValueField(F.gestureSwipeVelocityX, value: 0)
            end.setDoubleValueField(F.gestureSwipeVelocityY, value: 0)
            postPair(end)
        }
    }
}

// MARK: - 自检（验证合成按键能否触发系统原生空间切换）

/// 以 NBKey.app **自身身份**运行的自检，用来回答一个关键问题：
/// 合成的 Ctrl+→ 到底能不能让系统执行「原生」空间切换？
///
/// 为什么这个问题必须先回答：CGS 私有 API 是「无动画瞬移」，在开启台前调度时
/// 观感会变成「桌面没切、应用却换了」。要让台前调度正常工作，
/// 最干净的办法是让系统自己走原生切换路径（合成 Ctrl+←/→）。
/// 而这条路能否走通，只能实测 —— 不能靠推断。
///
/// 判定依据（只认最下游的真实状态）：
///   WindowServer 在 CGSCopyManagedDisplaySpaces 里报告的当前空间 ID 是否变化。
///   → 变化 = 系统真的执行了切换；不变 = 合成事件没被系统接受。
/// 不拿「我发了什么事件」当证据（那是自己跟自己对账）。
///
/// 触发方式：在 ~/Library/Application Support/NBKey/ 放一个 selftest.request 文件后
/// 经 LaunchServices 启动应用（open -n …）。必须这样启动，才能继承辅助功能授权。
/// 结果追加写入同目录 selftest.log（逐行落盘，中途崩溃也能保住已有结论）。
enum SpaceSelfTest {

    // 与 EventTapEngine 保持一致的合成事件标记值（"NBKY"）。
    private static let marker: Int64 = 0x4E42_4B59

    private static var logURL: URL!

    /// 逐行追加落盘：避免自检中途异常导致整份结果丢失。
    private static func log(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let text = "[\(ts)] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logURL.path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? data.write(to: logURL)
        }
        print(text, terminator: "")
    }

    // MARK: 只读探针

    private static func prefInt(_ domain: String, _ key: String) -> Int {
        let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        return (v as? NSNumber)?.intValue ?? -1
    }

    /// 读 com.apple.symbolichotkeys，把「移动空间 / 调度中心」这一组快捷键的真实状态打出来。
    ///
    /// 注意一个容易误判的点：id 79/80/81/82 若 `enabled=true` 但 `value` 缺失，
    /// 表示用户**没有自定义**、走系统**内建默认**绑定（即 Ctrl+←/→），
    /// 并不代表绑定不存在。只看 `parameters` 会把这种情况误报成「没有绑定」。
    private static func symbolicHotkeyDump() -> [String] {
        var out: [String] = []
        guard let dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                   "com.apple.symbolichotkeys" as CFString) as? [String: Any] else {
            return ["  ⚠️ 读不到 com.apple.symbolichotkeys / AppleSymbolicHotKeys"]
        }
        for k in ["78", "79", "80", "81", "82", "83"] {
            guard let entry = dict[k] as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
            let params = ((entry["value"] as? [String: Any])?["parameters"] as? [Any])?
                .compactMap { ($0 as? NSNumber)?.intValue }
            let desc = params.map { "自定义参数=\($0)" } ?? "无自定义参数 → 走系统内建默认绑定"
            out.append("  id=\(k) enabled=\(enabled) \(desc)")
        }
        if out.isEmpty { out.append("  ⚠️ 未读到 78~83 这一组快捷键") }
        return out
    }

    // MARK: 合成事件

    private static func post(_ code: CGKeyCode, _ down: Bool,
                             source: CGEventSource?, withCtrlFlag: Bool,
                             markerFlag: Bool, tap: CGEventTapLocation) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if withCtrlFlag { e.flags = .maskControl }
        if markerFlag { e.setIntegerValueField(.eventSourceUserData, value: marker) }
        e.post(tap: tap)
    }

    /// 合成 Ctrl+→。fullSequence=true 表示同时发 Ctrl 键的按下/抬起（当前实现的做法）。
    private static func synthCtrlArrow(_ key: CGKeyCode, source: CGEventSource?,
                                       fullSequence: Bool, withCtrlFlag: Bool = true,
                                       markerFlag: Bool = false,
                                       tap: CGEventTapLocation = .cghidEventTap) {
        if fullSequence {
            let seq: [(CGKeyCode, Bool)] = [(59, true), (key, true), (key, false), (59, false)]
            for (code, down) in seq {
                post(code, down, source: source, withCtrlFlag: withCtrlFlag, markerFlag: markerFlag, tap: tap)
            }
        } else {
            post(key, true, source: source, withCtrlFlag: withCtrlFlag, markerFlag: markerFlag, tap: tap)
            post(key, false, source: source, withCtrlFlag: withCtrlFlag, markerFlag: markerFlag, tap: tap)
        }
    }

    /// 让 System Events（系统自带、有系统级合成权限的进程）代为按键。
    /// 带硬超时，避免等待「自动化」授权弹窗把自检卡死。
    private static func pressViaSystemEvents(right: Bool, timeout: TimeInterval = 6) {
        let code = right ? 124 : 123
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to key code \(code) using control down"]
        do { try p.run() } catch { log("   ⚠️ osascript 启动失败: \(error)"); return }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            log("   ⚠️ osascript 超时 \(Int(timeout))s —— 多半是在等「NBKey 想控制 System Events」的授权弹窗")
        }
    }

    // MARK: 单个用例：先归位到最左空间，再执行动作，用「索引位移」判定

    /// 判定标准不是「空间变了没有」，而是**在鼠标所在屏的空间序列里位移了几格**：
    /// - 位移 = 期望值 → 成功且方向正确；
    /// - 位移 = 0 → 未生效；
    /// - 其它 → 方向反了或一次切了多格（这就是「一次按键跳好几个桌面」类 bug 的证据）。
    ///
    /// 起点先归位到最左空间，确保「往右」一定有目标空间，避免一上来就撞边界被误判成失败。
    private static func measure(_ sw: SpaceSwitcher, _ label: String,
                                startEdge: SpaceSwitcher.Direction = .left,
                                expected: Int = 1, wait: TimeInterval = 1.3,
                                _ act: () -> Void) {
        guard let start = sw.edgeSpaceID(startEdge) else {
            log("\(label): ⚠️ 取不到空间列表，结果不可信")
            return
        }
        _ = sw.goto(start)
        Thread.sleep(forTimeInterval: 0.9)

        let ids = sw.spaceIDsOnPointerDisplay()
        guard let before = sw.currentSpaceOnPointerDisplay() else { log("\(label): 读取当前空间失败"); return }
        let bi = ids.firstIndex(of: before) ?? -1

        act()
        Thread.sleep(forTimeInterval: wait)

        guard let after = sw.currentSpaceOnPointerDisplay() else { log("\(label): 读取当前空间失败"); return }
        let ai = ids.firstIndex(of: after) ?? -1
        let delta = ai - bi

        let verdict: String
        if delta == expected      { verdict = "✅ 成功，方向与幅度都对（位移 \(delta)）" }
        else if delta == 0        { verdict = "❌ 未切换（位移 0）" }
        else                      { verdict = "⚠️ 切了但不符合预期（位移 \(delta)，期望 \(expected)）" }
        log("\(label): idx \(bi)→\(ai)  \(before)→\(after)   \(verdict)")
    }

    /// 阳性对照：用必定生效的方式直接跳到下一个空间。
    /// 存在的意义是证明这套测量装置**能识别成功** —— 否则「全部 ❌」可能只是装置失灵。
    private static func positiveControl(_ sw: SpaceSwitcher) {
        measure(sw, "P) 阳性对照: CGS 直接跳到下一个空间", wait: 0.6) {
            let ids = sw.spaceIDsOnPointerDisplay()
            if let cur = sw.currentSpaceOnPointerDisplay(),
               let i = ids.firstIndex(of: cur), i + 1 < ids.count {
                _ = sw.goto(ids[i + 1])
            }
        }
    }

    /// 连续行走测试：**中途不用 CGS 复位**，从中间一格出发连续做多次手势，看每一步落在哪。
    ///
    /// 为什么必须这么测：`measureSwipe` 每个用例前都用 CGS 直切复位，而 CGS 直切是绕过 Dock
    /// 的换空间方式，可能让 Dock 的手势/动画内部状态与真实空间不同步，从而污染紧接着的手势
    /// —— 也就是测量手段本身在干扰被测对象。连续行走避免了这个问题，同时还能顺带验证
    /// 「同一方向连续触发是否稳定」。
    private static func walkTest(_ sw: SpaceSwitcher, label: String,
                                 steps: [(name: String, dir: SpaceSwitcher.Direction, style: SpaceSwipe.Style)]) {
        let ids = sw.spaceIDsOnPointerDisplay()
        guard ids.count >= 3 else { log("\(label): 空间数不足（\(ids.count)），跳过"); return }

        _ = sw.goto(ids[1])                    // 从第 2 格出发，左右都有余量
        Thread.sleep(forTimeInterval: 1.5)
        var idx = 1
        log("\(label): 起点 idx=1 (\(ids[1]))   空间序列=\(ids)")

        for s in steps {
            SpaceSwipe.post(s.dir, style: s.style)

            let t0 = Date()
            var firstChange: Int?
            var cur = sw.currentSpaceOnPointerDisplay()
            while Date().timeIntervalSince(t0) < 1.3 {
                Thread.sleep(forTimeInterval: 0.04)
                let c = sw.currentSpaceOnPointerDisplay()
                if c != cur {
                    if firstChange == nil { firstChange = Int(Date().timeIntervalSince(t0) * 1000) }
                    cur = c
                }
            }

            let newIdx = sw.spaceIDsOnPointerDisplay().firstIndex(of: cur ?? 0) ?? -1
            let d = newIdx - idx
            let expect = (s.dir == .right) ? 1 : -1
            let mark = (d == expect) ? "✅" : (d == 0 ? "❌ 未动" : "⚠️")
            log("   \(s.name): idx \(idx)→\(newIdx)  首个变化 \(firstChange.map { "+\($0)ms" } ?? "窗口内无变化")"
                + "  \(mark) 位移 \(d)（期望 \(expect)）")
            if newIdx >= 0 { idx = newIdx }
        }
    }

    /// 手势用例的测量。比 `measure` 多两个观测维度：
    /// - **首个变化出现的延迟**：瞬移应接近 0ms，带过渡动画则会有明显延迟；
    /// - **采样到的空间序列**：位移到底是 1 格还是 3 格，直接数出来。
    ///
    /// 之所以不只看索引差：系统的「按最近使用自动重排空间」开着时（本机 mru-spaces=1），
    /// 空间顺序本身会变，索引差可能被重排污染，需要额外标注。
    private static func measureSwipe(_ sw: SpaceSwitcher, _ label: String,
                                     startEdge: SpaceSwitcher.Direction = .left,
                                     resetIndex: Int? = nil, settle: TimeInterval = 0.9,
                                     expected: Int = 1, wait: TimeInterval = 1.4,
                                     _ act: () -> Void) {
        let ids0 = sw.spaceIDsOnPointerDisplay()
        let start: UInt64? = resetIndex.flatMap { $0 < ids0.count ? ids0[$0] : nil }
            ?? sw.edgeSpaceID(startEdge)
        guard let start else {
            log("\(label): ⚠️ 取不到空间列表，结果不可信"); return
        }
        _ = sw.goto(start)
        Thread.sleep(forTimeInterval: settle)

        let before = sw.currentSpaceOnPointerDisplay()
        let idsBefore = sw.spaceIDsOnPointerDisplay()

        act()

        let t0 = Date()
        var firstChangeMs: Int?
        var visited: [UInt64] = before.map { [$0] } ?? []
        while Date().timeIntervalSince(t0) < wait {
            Thread.sleep(forTimeInterval: 0.04)
            if let cur = sw.currentSpaceOnPointerDisplay(), cur != visited.last {
                if firstChangeMs == nil { firstChangeMs = Int(Date().timeIntervalSince(t0) * 1000) }
                visited.append(cur)
            }
        }

        let idsAfter = sw.spaceIDsOnPointerDisplay()
        let after = sw.currentSpaceOnPointerDisplay()
        let bi = idsAfter.firstIndex(of: before ?? 0) ?? -1
        let ai = idsAfter.firstIndex(of: after ?? 0) ?? -1
        let delta = ai - bi
        let reordered = idsBefore != idsAfter

        var verdict: String
        if delta == expected   { verdict = "✅ 位移正好 \(delta) 格" }
        else if delta == 0     { verdict = "❌ 未切换" }
        else                   { verdict = "⚠️ 位移 \(delta) 格（期望 \(expected)）" }
        if reordered { verdict += " ｜空间顺序已重排，索引差仅供参考" }

        let timing = firstChangeMs.map { "首个变化 +\($0)ms" } ?? "窗口内无变化"
        log("\(label): idx \(bi)→\(ai)  \(timing)  采样到 \(visited.count) 个空间  \(verdict)")
    }

    // MARK: 端到端验证（合成 Ctrl+鼠标点击，交给正在运行的 NBKey 实例去处理）

    /// 合成一次「按住 Ctrl 点击鼠标」。
    ///
    /// - `withMarker: false`（默认）：**不设** userData 标记 —— 目的就是让它被正在运行的
    ///   NBKey 实例当作真实用户操作命中规则，用来验证「触发链路通不通」。
    /// - `withMarker: true`：**带上**与引擎一致的防回灌标记 —— 用来验证标记是否真的被 tap 读到。
    private static func clickMouseWithCtrl(button: Int64, withMarker: Bool = false) {
        guard let loc = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let down: CGEventType = (button == 0) ? .leftMouseDown : .rightMouseDown
        let up: CGEventType   = (button == 0) ? .leftMouseUp   : .rightMouseUp
        guard let btn = CGMouseButton(rawValue: UInt32(button)) else { return }
        for t in [down, up] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: t,
                                  mouseCursorPosition: loc,
                                  mouseButton: btn) else { continue }
            e.flags = .maskControl
            if withMarker { e.setIntegerValueField(.eventSourceUserData, value: marker) }
            e.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    /// 采样一段窗口，返回「窗口内空间是否变过」以及最终空间 ID。
    /// 与 `runE2E` 用的是同一套判据（只认 WindowServer 报告的真实当前空间）。
    private static func watchSpace(_ sw: SpaceSwitcher, from cur: UInt64,
                                   seconds: TimeInterval) -> (changed: Bool, last: UInt64) {
        let t0 = Date()
        var now = cur
        var changed = false
        while Date().timeIntervalSince(t0) < seconds {
            Thread.sleep(forTimeInterval: 0.05)
            if let c = sw.currentSpaceOnPointerDisplay(), c != now {
                changed = true
                now = c
            }
        }
        return (changed, now)
    }

    /// 验证「合成事件上的防回灌标记」是否真的能被事件 tap 在回调里读到。
    ///
    /// 为什么必须实测：`EventTapEngine.post()` 给合成键事件写了 `kCGEventSourceUserData` 标记，
    /// 并把它当作防回灌的**主防线**（注释里明确写了「`CGEvent.post` 是异步的，布尔标志挡不住」）；
    /// 但同一份代码在 `SpaceSwipe` 那一段又写着「CGEvent 的 userData 标记在 `CGEventPost` 之后
    /// **不保留**」。两处说法互相矛盾 —— 其中必有一处是错的。
    ///
    /// 这件事的后果不小：若标记真的会丢，那么用户一旦配置「键盘触发 → 键盘动作」这类规则，
    /// 引擎合成出来的按键会**再次命中同一条规则** → 递归触发 → 卡死。
    /// 当前用户的规则全是鼠标触发（合成的是手势事件、不进 tap 的订阅掩码），所以这个隐患没暴露。
    ///
    /// 判据（带阳性对照，两种结果可区分，跑一次即可定性）：
    ///   A) 合成**不带标记**的 Ctrl+鼠标点击 → 期望切一格（证明实例在跑、链路是通的）
    ///   B) 合成**带标记**的 Ctrl+鼠标点击   → 期望空间完全不动（证明标记被读到并被跳过）
    ///
    /// 只有 A 成功、B 不动，才算「标记生效」。若 A 也没反应，说明实例没在运行，本次结论无效。
    static func runInjectionGuardCheck() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("selftest.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { try? Data().write(to: logURL) }

        let sw = SpaceSwitcher()
        log("=========== 防回灌标记验证 \(ISO8601DateFormatter().string(from: Date())) ===========")
        log("AXIsProcessTrusted = \(AXIsProcessTrusted())   ← 必须为 true")

        // 选一个「一定有目标空间」的方向，避免撞边界被误判。
        let ids0 = sw.spaceIDsOnPointerDisplay()
        guard ids0.count >= 2,
              let cur0 = sw.currentSpaceOnPointerDisplay(),
              let idx0 = ids0.firstIndex(of: cur0) else {
            log("❌ 读取空间列表失败（\(ids0.count) 个空间），终止"); return
        }
        let useNext = (idx0 + 1 < ids0.count)
        let button: Int64 = useNext ? 1 : 0
        log("起点 idx=\(idx0)  空间序列=\(ids0)")

        // ---- 阳性对照 A：不带标记，应当真的切一格 ----
        log("--- A) 阳性对照：合成「不带标记」的 Ctrl+鼠标\(useNext ? "右" : "左")键 → 期望切一格 ---")
        clickMouseWithCtrl(button: button, withMarker: false)
        let a = watchSpace(sw, from: cur0, seconds: 2.5)
        let idsA = sw.spaceIDsOnPointerDisplay()
        let aIdx = idsA.firstIndex(of: a.last) ?? -1
        let aDelta = aIdx - idx0
        let controlOK = a.changed
        log("   结果: idx \(idx0)→\(aIdx)  位移 \(aDelta)  \(controlOK ? "✅ 实例在跑，链路通" : "❌ 实例没响应")")

        guard controlOK else {
            log("⚠️ 阳性对照失败 —— 说明没有正在运行的 NBKey 实例（或规则未启用），本次 B) 的结论不可信，已跳过")
            log("=========== END ===========")
            return
        }

        // 等切换链彻底收尾、Dock 手势状态复位，再做 B。
        Thread.sleep(forTimeInterval: 1.5)

        // ---- 用例 B：带标记，应当被实例跳过 ----
        let idsB = sw.spaceIDsOnPointerDisplay()
        guard let curB = sw.currentSpaceOnPointerDisplay(),
              let idxB = idsB.firstIndex(of: curB) else {
            log("❌ B) 读取当前空间失败，终止"); return
        }
        log("--- B) 用例：合成「带防回灌标记」的 Ctrl+鼠标点击 → 期望空间完全不动 ---")
        clickMouseWithCtrl(button: button, withMarker: true)
        let b = watchSpace(sw, from: curB, seconds: 2.5)
        let idsB2 = sw.spaceIDsOnPointerDisplay()
        let bIdx = idsB2.firstIndex(of: b.last) ?? -1
        log("   结果: idx \(idxB)→\(bIdx)  变化=\(b.changed)")
        if !b.changed {
            log("✅ 标记生效：带标记的合成事件被实例在 tap 里识别并跳过 —— 防回灌主防线成立")
        } else {
            log("❌ 标记丢失：带标记的合成事件仍被当成真实操作执行了")
            log("   → 结论：kCGEventSourceUserData 经 CGEventPost 后确实不保留，")
            log("     必须改用其它防回灌手段（例如「合成期间 + 短时间窗」抑制），否则配置键盘类规则会递归卡死")
        }

        // ---- C/D) 键盘路径的防回灌 ----
        // 为什么要单独测键盘：鼠标路径合成的是 Dock 手势事件（不在 tap 的订阅掩码里，天然无回灌风险），
        // 而**键盘路径合成的是真正的按键事件，会再次进入 tap** —— 这才是标记一旦失效就会递归卡死的那条路。
        //
        // 判据不依赖任何用户规则：本机没有配置键盘类规则，所以一个「不带标记」的 Ctrl+←
        // 必定走进「无匹配规则」分支、在 engine.log 留下 `RECV sig=379`；
        // 而「带标记」的同一个按键若被正确跳过，就**不会**新增 RECV 行。两种结果可直接区分。
        // 安全性：合成的 Ctrl+← 不会切换空间（这个组合的合成按键已被实测排除，见 switchSpace 注释），
        // 也会被引擎原样放行给系统 —— 与之前那轮 K1 金丝雀用例是同一件事。
        let engineLog = dir.appendingPathComponent("engine.log")
        func recvCount() -> Int {
            guard let text = try? String(contentsOf: engineLog, encoding: .utf8) else { return -1 }
            return text.components(separatedBy: "RECV sig=379").count - 1
        }

        log("--- C) 键盘路径对照：合成「不带标记」的 Ctrl+← → engine.log 应新增 RECV sig=379 ---")
        let c0 = recvCount()
        postCtrlArrowKey(marked: false)
        Thread.sleep(forTimeInterval: 2.6)   // 跨过 RECV 日志 2s 的节流窗口
        let c1 = recvCount()
        log("   RECV sig=379 计数 \(c0) → \(c1)   "
            + (c1 > c0 ? "✅ 未加标记的按键确实被引擎看见了" : "❌ 没看到，说明键盘事件根本没进 tap，D) 的结论无效"))

        guard c1 > c0 else {
            log("=========== END ===========")
            return
        }

        log("--- D) 键盘路径用例：合成「带标记」的 Ctrl+← → engine.log 不应新增 RECV sig=379 ---")
        postCtrlArrowKey(marked: true)
        Thread.sleep(forTimeInterval: 2.6)
        let c2 = recvCount()
        log("   RECV sig=379 计数 \(c1) → \(c2)   "
            + (c2 == c1 ? "✅ 被标记跳过 —— 键盘路径的防回灌同样成立，配置键盘类规则不会递归"
                        : "❌ 仍被当成真实按键处理 —— 配置键盘类规则会递归触发，必须修复"))
        log("=========== END ===========")
    }

    /// 合成一次 Ctrl+←（完整序列：Ctrl 按下 → ← 按下 → ← 抬起 → Ctrl 抬起）。
    /// 只在防回灌验证里用，用来制造一个「会进入 tap 的键盘事件」。
    private static func postCtrlArrowKey(marked: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let seq: [(CGKeyCode, Bool)] = [(59, true), (123, true), (123, false), (59, false)]
        for (code, down) in seq {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = .maskControl
            if marked { e.setIntegerValueField(.eventSourceUserData, value: marker) }
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// 端到端验证：不依赖用户手动操作，走完整条真实链路。
    ///
    /// 合成一次「Ctrl+鼠标右键（或左键）」投递到 HID 层 → 由**正在运行的 NBKey 实例**
    /// 命中规则并执行切换 → 读 WindowServer 的真实当前空间 ID 判断是否真的切了一格。
    ///
    /// 价值：用户真实操作是「按住 Ctrl 点鼠标」，这条链路只能由外部事件触发。
    /// 这里用合成事件替代用户的手，把「触发是否生效」也纳入自动验证，
    /// 从而把需要人工确认的范围压缩到「观感是否正常」这一件事上。
    ///
    /// 前置条件：NBKey 实例必须已经在运行（本模式不创建引擎）。
    /// 起点**不做 CGS 复位**（复位会毒化 Dock 状态），而是按当前位置自动选择方向。
    static func runE2E() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("selftest.log")
        // 追加而非清空：端到端验证会被反复执行，保留每次结果便于统计成功率。
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }

        let sw = SpaceSwitcher()
        log("=================== E2E SELFTEST \(ISO8601DateFormatter().string(from: Date())) ===================")
        log("AXIsProcessTrusted = \(AXIsProcessTrusted())")

        let ids = sw.spaceIDsOnPointerDisplay()
        guard let cur = sw.currentSpaceOnPointerDisplay(), let idx = ids.firstIndex(of: cur) else {
            log("❌ 读取当前空间失败，终止"); return
        }
        // 按当前位置选方向：优先测「下一个桌面」（Ctrl+鼠标右键）；已在最右则改测「上一个桌面」。
        let useNext = (idx + 1 < ids.count)
        let expect = useNext ? 1 : -1
        log("起点 idx=\(idx)   空间序列=\(ids)")
        log("本次触发：\(useNext ? "Ctrl+鼠标右键 → 下一个桌面" : "Ctrl+鼠标左键 → 上一个桌面")   期望位移 \(expect)")

        clickMouseWithCtrl(button: useNext ? 1 : 0)

        let t0 = Date()
        var firstChange: Int?
        var now = cur
        while Date().timeIntervalSince(t0) < 2.5 {
            Thread.sleep(forTimeInterval: 0.05)
            if let c = sw.currentSpaceOnPointerDisplay(), c != now {
                if firstChange == nil { firstChange = Int(Date().timeIntervalSince(t0) * 1000) }
                now = c
            }
        }

        let newIdx = sw.spaceIDsOnPointerDisplay().firstIndex(of: now) ?? -1
        let d = newIdx - idx
        let timing = firstChange.map { "首个变化 +\($0)ms" } ?? "窗口内无变化"
        log("结果: idx \(idx)→\(newIdx)  \(timing)  "
            + (d == expect ? "✅ 端到端链路正常：按一次 = 切一格"
                           : "❌ 不符合预期（位移 \(d)，期望 \(expect)）"))
        log("请对照 engine.log 末尾确认走的是哪条路径（应出现「原生手势管线切换成功」）")
        log("=================== END ===================")
    }

    // MARK: 快速连按压测（验证「防叠加」仲裁）

    /// 验证「快速连按」不会叠加成跳多格。
    ///
    /// 场景：合成 N 次 Ctrl+鼠标点击、间隔 120ms。一条切换链要跑约 0.8s（手势分次投递 + 轮询校验），
    /// 因此后面 N-1 次必然落在「上一条链还在途」的窗口里 —— 正好把防叠加仲裁压到极限。
    ///
    /// 期望位移**正好** = ±N（每按一下切一格，既不多也不少）：
    ///   - 位移 < N → 请求被吞掉（用户会感觉「按了没反应」）
    ///   - 位移 > N → 手势在 Dock 侧叠加了（即「一次按键跳好几格」的原始 bug 复现）
    ///
    /// 交叉验证：engine.log 里应出现「本次请求排队（不叠加）」与「执行排队的切换请求」，
    /// 这是仲裁确实介入的直接证据；若全程没有这两行，说明事件间隔其实没落进在途窗口，压测无效。
    static func runBurstCheck() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("selftest.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { try? Data().write(to: logURL) }

        let sw = SpaceSwitcher()
        log("=========== 快速连按压测 \(ISO8601DateFormatter().string(from: Date())) ===========")
        log("AXIsProcessTrusted = \(AXIsProcessTrusted())")

        let ids = sw.spaceIDsOnPointerDisplay()
        guard ids.count >= 2, let cur = sw.currentSpaceOnPointerDisplay(),
              let idx = ids.firstIndex(of: cur) else {
            log("❌ 读取空间列表失败（\(ids.count) 个空间），终止"); return
        }

        let roomRight = ids.count - 1 - idx
        let roomLeft = idx
        let goRight = roomRight >= roomLeft
        let room = max(roomRight, roomLeft)
        let n = min(3, room)
        guard n >= 2 else {
            log("⚠️ 可用空间不足（本侧仅剩 \(room) 格），无法压测，跳过"); return
        }

        let button: Int64 = goRight ? 1 : 0
        let expect = goRight ? n : -n
        log("起点 idx=\(idx)  空间序列=\(ids)")
        log("将合成 \(n) 次 Ctrl+鼠标\(goRight ? "右" : "左")键，间隔 120ms"
            + "（远小于单链 ~0.8s，必然落进在途窗口）")
        log("期望：位移正好 \(expect)（每按一下切一格，不丢不多）")

        for i in 0..<n {
            clickMouseWithCtrl(button: button, withMarker: false)
            if i < n - 1 { Thread.sleep(forTimeInterval: 0.12) }
        }

        let r = watchSpace(sw, from: cur, seconds: 6.0)
        let idsAfter = sw.spaceIDsOnPointerDisplay()
        let newIdx = idsAfter.firstIndex(of: r.last) ?? -1
        let d = newIdx - idx

        let verdict: String
        if d == expect {
            verdict = "✅ 符合预期：连按 \(n) 下 = 切 \(n) 格，既没叠加也没丢"
        } else if abs(d) < abs(expect) {
            verdict = "❌ 位移不足（\(d)，期望 \(expect)）：有请求被吞掉了"
        } else {
            verdict = "⚠️ 位移超出（\(d)，期望 \(expect)）：手势在 Dock 侧叠加了，防叠加仲裁没兜住"
        }
        log("结果: idx \(idx)→\(newIdx)  位移 \(d)   \(verdict)")
        if idsAfter != ids {
            log("   注意：空间序列已变化（\(ids) → \(idsAfter)），索引差可能被系统自动重排污染")
        }
        log("   交叉验证：engine.log 里应同时出现「排队（不叠加）」与「执行排队的切换请求」")
        log("=========== END ===========")
    }

    // MARK: 入口

    static func run(includePermissionPromptingCases: Bool) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("selftest.log")
        try? Data().write(to: logURL)   // 本次结果自成一档

        let sw = SpaceSwitcher()
        log("=================== SPACE SELFTEST \(ISO8601DateFormatter().string(from: Date())) ===================")
        log("bundle=\(Bundle.main.bundleIdentifier ?? "-")  pid=\(getpid())")
        log("AXIsProcessTrusted = \(AXIsProcessTrusted())   ← 必须为 true；若为 false，下面结论全是环境假阴性")
        log("CGS available      = \(sw.isAvailable)")
        log("StageManager GloballyEnabled = \(prefInt("com.apple.WindowManager", "GloballyEnabled"))   (1=开启)")
        log("dock mru-spaces              = \(prefInt("com.apple.dock", "mru-spaces"))   (1=按最近使用自动重排空间)")
        log("指针所在屏空间序列 = \(sw.spaceIDsOnPointerDisplay())  当前=\(sw.currentSpaceOnPointerDisplay().map(String.init) ?? "-")")
        log("--- 「移动空间 / 调度中心」快捷键真实状态 ---")
        symbolicHotkeyDump().forEach { log($0) }

        log("")
        log("--- [第 1 组] 测量装置的阳性对照（必须先看到 ✅，否则后面的 ❌ 无意义）---")
        positiveControl(sw)

        log("")
        log("--- [第 2 组] 合成 Ctrl+←/→ 金丝雀（预期 ❌；完整 6 变体已在 16:05 那轮全部 ❌）---")
        measure(sw, "  K1) hidSystemState + Ctrl 序列") {
            synthCtrlArrow(124, source: CGEventSource(stateID: .hidSystemState), fullSequence: true)
        }

        log("")
        log("--- [第 3 组] 连续行走测试（中途不复位，避免 CGS 复位干扰 Dock 状态）---")
        walkTest(sw, label: "W", steps: [
            ("W1 右·带动画 ", .right, .animated),
            ("W2 右·瞬时   ", .right, .instant),
            ("W3 左·带动画 ", .left,  .animated),
            ("W4 左·瞬时   ", .left,  .instant),
            ("W5 左·带动画 ", .left,  .animated),
            ("W6 右·瞬时   ", .right, .instant),
            ("W7 右·带动画 ", .right, .animated),
            ("W8 右·瞬时   ", .right, .instant),
        ])
        log("   期望 idx 走位: 1→2→3→2→1→0→1→2→3（全程不撞边界）")

        log("")
        log("--- [第 4 组] 从中间格出发的单次手势，对比 progress 是否影响位移 ---")
        measureSwipe(sw, "  M1) 起点 idx=1, progress 0.30, vel 0", resetIndex: 1, settle: 1.5) {
            SpaceSwipe.postRaw(right: true, progress: 0.30, velocity: 0)
        }
        measureSwipe(sw, "  M2) 起点 idx=1, progress 2.00, vel 400", resetIndex: 1, settle: 1.5) {
            SpaceSwipe.postRaw(right: true, progress: 2.00, velocity: 400)
        }

        if includePermissionPromptingCases {
            log("")
            log("--- [第 5 组] 附加用例（可能弹出「自动化」授权框）---")
            measure(sw, "  S1) System Events 代按 Ctrl+→", wait: 1.5) { pressViaSystemEvents(right: true) }
        } else {
            log("")
            log("（已跳过 System Events 用例；需要时把 selftest.request 内容写成 all）")
        }

        log("")
        log("AXIsProcessTrusted(结束复核) = \(AXIsProcessTrusted())")
        log("=================== END ===================")
    }
}
