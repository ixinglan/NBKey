import AppKit

// ---------------------------------------------------------------------------
// 自检入口（必须在 NSApplication 启动之前判断）
//
// 为什么不用 `open -n -a NBKey.app --args --selftest-space`：
// 实测经 LaunchServices 启动时，参数不一定能透传到 CommandLine.arguments，
// 自检会静默不执行（selftest.log 不刷新），排查成本很高。
//
// 改用「请求文件」触发：只要在下方路径放一个 selftest.request 文件，
// 应用在下一次启动时就会执行对应自检，结果写入 selftest.log。
//
// 关键点：必须经 LaunchServices 启动（open -n …），让自检运行在
// **NBKey 自己的身份与辅助功能授权**之下。
// 从终端直接跑 build/Debug/NBKey.app/Contents/MacOS/NBKey，
// 责任进程是终端，AXIsProcessTrusted() 会是 false，合成按键必然全部失败
// —— 那是环境假阴性，不能据此判定方案不可行。
// ---------------------------------------------------------------------------

/// 需要在真正的 `NSApplication` 里跑的自检模式。
///
/// 与 `SpaceSelfTest` 那几项的区别：空间切换自检可以在 App 启动前就跑完并退出，
/// 而界面快照、快捷键验证都需要一个活着的窗口与 run loop，因此必须继续走正常启动流程。
enum AppSelfTestMode {
    case none
    case uiSnapshot      // 设置界面离屏快照
    case shortcuts       // ⌘W / ⌘Q 端到端验证
    static var current: AppSelfTestMode = .none
}

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NBKey")
let selftestRequest = supportDir.appendingPathComponent("selftest.request")

if CommandLine.arguments.contains("--selftest-space")
    || FileManager.default.fileExists(atPath: selftestRequest.path) {

    // 请求文件内容决定跑哪种自检：
    //   "e2e"    → 端到端验证（合成 Ctrl+鼠标点击，交给正在运行的 NBKey 实例处理）
    //   "guard"  → 防回灌标记验证（带阳性对照：不带标记应切一格、带标记应完全不动）
    //   "burst"  → 快速连按压测（连按 3 下，期望正好切 3 格，验证防叠加仲裁）
    //   "ui"     → 设置界面离屏快照（浅色/深色 + 空态 + 编辑面板），跑完自行退出
    //   "keys"   → ⌘W / ⌘Q 端到端验证（合成真实按键，观察窗口是否关闭、进程是否退出）
    //   "all"    → 完整矩阵，额外包含会弹系统授权框的用例
    //   其它/空  → 常规矩阵（手势 + 合成按键）
    //
    // 注意 "ui" / "keys" 与其它几项不同：它们**不能**在这里 exit(0)，
    // 因为界面与快捷键必须跑在真正的 NSApplication 里才有得验证。
    let mode = ((try? String(contentsOf: selftestRequest, encoding: .utf8)) ?? "").lowercased()
    try? FileManager.default.removeItem(at: selftestRequest)

    if mode.contains("ui") {
        AppSelfTestMode.current = .uiSnapshot
    } else if mode.contains("keys") {
        AppSelfTestMode.current = .shortcuts
    } else if mode.contains("guard") {
        SpaceSelfTest.runInjectionGuardCheck()
        exit(0)
    } else if mode.contains("burst") {
        SpaceSelfTest.runBurstCheck()
        exit(0)
    } else if mode.contains("e2e") {
        SpaceSelfTest.runE2E()
        exit(0)
    } else {
        SpaceSelfTest.run(includePermissionPromptingCases: mode.contains("all"))
        exit(0)
    }
}

// 入口：仅创建一个无主窗口的菜单栏应用（配合 Info.plist 的 LSUIElement=true，不显示 Dock 图标）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// ---------------------------------------------------------------------------
// 设置界面离屏快照
// ---------------------------------------------------------------------------

/// 把设置窗口的视图树渲染成 PNG，用于「界面到底长什么样」的自动化回归。
///
/// 为什么不用 `screencapture`：那需要「屏幕录制」权限（会弹窗、需人工授权、无头环境不可用）。
/// 而 `cacheDisplay(in:to:)` 渲染的是 App 自己的视图树，不读屏幕像素 —— **零权限**，
/// 因此可以放进自动化里反复跑。
///
/// ⚠️ 本流程**绝不修改磁盘上的规则**：中间会把 `state.rules` 临时置空以拍空态，
/// 拍完立即恢复，全程不调用 `save()`。`RuleStore.save` 是唯一写 rules.json 的地方。
enum UISnapshot {
    private static var outputDir: URL?

    static func start(state: AppState, completion: @escaping () -> Void) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBKey")
            .appendingPathComponent("ui-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outputDir = dir

        // 先清掉旧图：否则某一步失败时，目录里残留的上一次结果会被误当成这一次的产出。
        if let stale = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                   includingPropertiesForKeys: nil) {
            stale.filter { $0.pathExtension == "png" }.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        SelfLog.write("=========== UI SNAPSHOT \(ISO8601DateFormatter().string(from: Date())) ===========")
        SelfLog.write("输出目录: \(dir.path)")

        state.openSettings()
        guard let window = state.window else {
            SelfLog.write("❌ 设置窗口未创建，终止")
            completion()
            return
        }

        let backup = state.rules
        var steps: [(String, () -> Void)] = []
        steps.append(("01-settings-light", {}))
        steps.append(("02-settings-dark", {
            window.appearance = NSAppearance(named: .darkAqua)
        }))
        steps.append(("03-empty-state-light", {
            window.appearance = nil
            state.rules = []              // 仅内存，不落盘
        }))
        // 顺序上把「展开帮助区」排在编辑面板之前：sheet 一旦弹出，视图内部那个
        // `@State` 的令牌就不受外部控制了，再想去切换主窗口的其它状态容易打架。
        steps.append(("04-help-expanded-light", {
            window.appearance = nil
            state.rules = backup          // 恢复数据
            state.snapshotExpandHelpSignal = true
        }))
        steps.append(("05-editor-light", {
            state.snapshotOpenEditorSignal = true
        }))
        steps.append(("06-editor-dark", {
            window.appearance = NSAppearance(named: .darkAqua)
        }))

        var index = 0
        func runNext() {
            guard index < steps.count else {
                window.appearance = nil
                state.rules = backup      // 兜底恢复
                SelfLog.write("✅ 快照完成，共 \(index) 组")
                SelfLog.write("=========== END ===========")
                completion()
                return
            }
            let (name, action) = steps[index]
            index += 1
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                capture(window, name: name)
                runNext()
            }
        }
        runNext()
    }

    /// 截图：主窗口取「纯内容」与「整窗（含标题栏）」两张；若挂有 sheet 再单独取一张。
    private static func capture(_ window: NSWindow, name: String) {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let content = window.contentView else {
            SelfLog.write("⚠️ \(name): 取不到 contentView")
            return
        }
        write(content, name: name)
        if let frame = content.superview {   // NSThemeFrame：连标题栏一起
            write(frame, name: name + "-full")
        }

        // ⚠️ SwiftUI 的 `.sheet` 在 macOS 上是**附加窗口**（attached sheet），
        // 不在主窗口的视图树里。只截主窗口的话，画面里只有「主窗口被压暗」，
        // 面板内容一张都看不到 —— 必须单独取它的 contentView。
        if let sheet = window.attachedSheet, let sheetContent = sheet.contentView {
            sheetContent.layoutSubtreeIfNeeded()
            write(sheetContent, name: name + "-sheet")
        }
    }

    private static func write(_ view: NSView, name: String) {
        guard let dir = outputDir else { return }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            SelfLog.write("⚠️ \(name): 无法创建位图（bounds=\(Int(bounds.width))x\(Int(bounds.height))）")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)

        // ⚠️ 必须补窗口底色，否则产物里会留下大片 alpha=0 的透明像素。
        // `cacheDisplay` 只捕获**视图自己画的像素**，窗口底色是由 WindowServer 画的、
        // 不在视图的绘制内容里。后果非常隐蔽：看图器会把透明区按它自己的底色合成，
        // 深色快照看起来就像「文字消失了」/「背景是黑的」—— 我曾据此误判成深色模式有 bug。
        let opaque = flatten(rep, appearance: view.window?.effectiveAppearance)

        guard let data = opaque.representation(using: .png, properties: [:]) else {
            SelfLog.write("⚠️ \(name): PNG 编码失败")
            return
        }
        do {
            try data.write(to: dir.appendingPathComponent(name + ".png"))
            SelfLog.write("  \(name).png  \(opaque.pixelsWide)x\(opaque.pixelsHigh)px")
        } catch {
            SelfLog.write("⚠️ \(name): 写入失败 \(error)")
        }
    }

    /// 在视图内容下面铺一层窗口底色，得到「屏幕上真实看到的样子」。
    /// 用的是 `windowBackgroundColor` 在该外观下的实际值（深色快照铺深色底、浅色铺浅色底）。
    private static func flatten(_ rep: NSBitmapImageRep, appearance: NSAppearance?) -> NSBitmapImageRep {
        var background = NSColor.white
        let resolve = {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.white
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }

        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0,
              let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) else {
            SelfLog.write("    ⚠️ 补底：位图创建失败")
            return rep   // 补底失败就退回原图，别把快照整个搞丢
        }
        flat.size = rep.size

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: flat)
        if let ctx {
            NSGraphicsContext.current = ctx
            let rect = NSRect(origin: .zero, size: rep.size)
            background.setFill()
            rect.fill()

            // 必须用 `NSImage` + 显式 `.sourceOver` 合成，**不能**用 `rep.draw(in:)`：
            // 后者是「替换式」绘制，源图里的透明像素会把刚铺好的底色一起擦掉，
            // 表现就是「补底代码跑了、产物依然透明」。而这种情况极其容易误判成功 ——
            // 若只看某个角落像素，sheet 那张整幅都被内容盖住、采样值 255，看着就像补底生效了。
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        // 唯一的判据：全图还有没有 alpha<255 的像素。
        let transparent = transparentCount(of: flat)
        SelfLog.write("    补底: 底色=\(describe(background)) 上下文=\(ctx != nil) "
                      + "残留透明像素=\(transparent)/\(w * h)"
                      + (transparent == 0 ? " ✅" : "  ⚠️ 补底不完整"))
        return flat
    }

    /// 统计 alpha < 255 的像素数。
    private static func transparentCount(of rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return -1 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            let row = y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide where data[row + x * 4 + 3] < 255 {
                count += 1
            }
        }
        return count
    }

    private static func describe(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

// ---------------------------------------------------------------------------
// ⌘W / ⌘Q 端到端验证
// ---------------------------------------------------------------------------

/// 验证 ⌘W 真的能关窗口、⌘Q 真的能退出应用。
///
/// 做法是**合成真实的 ⌘ 组合键**投到 HID 层，然后观察下游真实结果
/// （窗口 `isVisible` 是否变 false、进程是否自行退出）——
/// 而不是去调用 `closeSettings()` 再自问自答「函数被执行了所以算通过」。
///
/// ⚠️ 安全阀：发送 ⌘W 之前必须确认本应用处于激活状态。
/// 否则这个 ⌘W 会落到**别的 App** 的窗口上，把人家的文档关掉。
enum ShortcutSelfTest {
    static func run(state: AppState, completion: @escaping () -> Void) {
        SelfLog.write("=========== SHORTCUT SELFTEST \(ISO8601DateFormatter().string(from: Date())) ===========")
        SelfLog.write("AXIsProcessTrusted = \(AXIsProcessTrusted())   ← 必须为 true，否则合成按键会被系统丢弃")

        state.openSettings()
        guard let window = state.window else {
            SelfLog.write("❌ 设置窗口未创建，终止")
            completion()
            return
        }

        // 激活是**异步**的：刚调用完 `NSApp.activate`，`isActive` 这一瞬间仍是 false。
        // 所以必须轮询等它真的变成前台，否则会误判成「不是前台」而把整个用例白白跳过
        // （第一次跑就是这么被跳掉的）。
        waitUntilActive(deadline: Date().addingTimeInterval(3.0)) { [weak state] active in
            guard let state, active else {
                SelfLog.write("⚠️ 等待 3s 后 NSApp.isActive 仍为 false，本应用没能成为前台应用。")
                SelfLog.write("   为避免误关其它 App 的窗口，本次不发 ⌘W / ⌘Q，已跳过。")
                completion()
                return
            }
            guard AXIsProcessTrusted() else {
                SelfLog.write("⚠️ 无辅助功能权限，合成按键会被系统丢弃 —— 本次结论无效，请改经 open -n 启动")
                completion()
                return
            }
            SelfLog.write("前置：isActive=true  isKeyWindow=\(window.isKeyWindow)  isVisible=\(window.isVisible)")

            // 每步带自己的等待时长：后面的步骤（关面板、退出）本身要花更久，
            // 用同一个固定间隔会误判成"没生效"。
            var steps: [(gap: TimeInterval, action: () -> Void)] = []
            steps.append((1.4, {
                SelfLog.write("① 发送 ⌘W 前：isVisible=\(window.isVisible)  \(window.isVisible ? "✅" : "❌")")
                postCommandKey(keyCode: 13)          // 13 = w
            }))
            steps.append((1.4, {
                SelfLog.write("② 发送 ⌘W 后：isVisible=\(window.isVisible)  "
                              + (window.isVisible ? "❌ 窗口没关" : "✅ 窗口已关闭"))
                SelfLog.write("   发送 ⌘, 测试「打开设置」…")
                postCommandKey(keyCode: 43)          // 43 = ,
            }))
            steps.append((1.4, {
                SelfLog.write("③ 发送 ⌘, 后：isVisible=\(window.isVisible)  "
                              + (window.isVisible ? "✅ 窗口已重新打开" : "❌ 没能打开"))
                if !window.isVisible { state.openSettings() }   // 兜底，保证后面还有窗口可用
                SelfLog.write("   发送 ⌘N 测试「新增规则」…")
                postCommandKey(keyCode: 45)          // 45 = n
            }))
            steps.append((1.8, {
                // 编辑面板是 SwiftUI 的 sheet，在 macOS 上是**附加窗口**，
                // 所以判据是「主窗口有没有 attach 上一个 sheet」，不是主窗口自己的状态。
                let sheetOpen = window.attachedSheet != nil
                SelfLog.write("④ 发送 ⌘N 后：attachedSheet=\(sheetOpen ? "已弹出" : "无")  "
                              + (sheetOpen ? "✅ 新建规则面板已打开" : "❌ 没打开"))
                SelfLog.write("   发送 Esc 测试「取消编辑」…")
                postKey(keyCode: 53)                 // 53 = esc
            }))
            steps.append((1.6, {
                let sheetGone = window.attachedSheet == nil
                SelfLog.write("⑤ 发送 Esc 后：attachedSheet=\(sheetGone ? "已关闭" : "仍在")  "
                              + (sheetGone ? "✅ 面板已取消" : "❌ 面板没关"))
                SelfLog.write("   前置状态：isActive=\(NSApp.isActive)  sheet=\(window.attachedSheet != nil)")
                SelfLog.write("⑥ 发送 ⌘Q —— 若生效，本进程会立刻退出，下面这行提示不会再出现：")
                SelfLog.write("   「❌ ⌘Q 未生效：进程仍然存活」")
                postCommandKey(keyCode: 12)          // 12 = q
            }))
            // ⌘Q 的观察窗口给足 3s：应用退出要经过终止流程（还会先关掉附属窗口），
            // 窗口太短会把"正在退出"误判成"没退出"。
            steps.append((3.0, {
                SelfLog.write("❌ ⌘Q 未生效：进程仍然存活")
                SelfLog.write("   诊断：isActive=\(NSApp.isActive)  sheet=\(window.attachedSheet != nil)"
                              + "  windows=\(NSApp.windows.count)")
                SelfLog.write("=========== END (FAILED) ===========")
                completion()
            }))

            runSteps(steps, completion: completion)
        }
    }

    /// 轮询等待本应用成为前台应用。每轮都重新 activate 一次 ——
    /// 单次调用可能被系统忽略（尤其刚启动、或前面有别的应用正在抢焦点）。
    private static func waitUntilActive(deadline: Date, tries: Int = 0,
                                        then: @escaping (Bool) -> Void) {
        if NSApp.isActive {
            then(true)
            return
        }
        if Date() >= deadline {
            then(false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            waitUntilActive(deadline: deadline, tries: tries + 1, then: then)
        }
    }

    /// 合成一次 ⌘+某键（按下再抬起），投到 HID 层。
    private static func postCommandKey(keyCode: CGKeyCode) {
        post(keyCode: keyCode, flags: .maskCommand)
    }

    /// 合成一次「不带修饰键」的普通按键（用于 Esc 这类单键）。
    private static func postKey(keyCode: CGKeyCode) {
        post(keyCode: keyCode, flags: [])
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// 逐步执行；**每一步用自己的等待时长**（元组第一个字段）。
    /// 退出这类动作要经过终止流程，需要的观察窗比"关窗口"长得多，
    /// 用统一间隔会把"正在退出"误判成"没退出"。
    private static func runSteps(_ steps: [(gap: TimeInterval, action: () -> Void)],
                                completion: @escaping () -> Void) {
        var index = 0
        func next() {
            guard index < steps.count else { completion(); return }
            let (gap, action) = steps[index]
            index += 1
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { next() }
        }
        next()
    }
}

// ---------------------------------------------------------------------------
// 自检日志
// ---------------------------------------------------------------------------

/// 自检结论统一写进 `selftest.log`。
///
/// 两个关键点：
/// 1. **必须落盘**而不是只 print —— GUI 进程的 stdout 常常无处可去；
/// 2. **必须同步写**。这里刻意用 `queue.sync` 而不是 `async`：
///    自检里有一条用例会主动让进程退出（验证 ⌘Q），异步队列里的最后几行
///    很可能还没刷盘进程就没了 —— 而"没退出"和"日志没写出来"在事后看起来一模一样。
///    自检不在热路径上，多等几毫秒完全值得。
enum SelfLog {
    private static let queue = DispatchQueue(label: "com.nbkey.selftest.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ line: String) {
        queue.sync {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NBKey")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("selftest.log")
            let text = "[\(formatter.string(from: Date()))] \(line)\n"
            guard let data = text.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: url.path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try? data.write(to: url)
            }
            print(text, terminator: "")
        }
    }
}
