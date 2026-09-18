import SwiftUI

/// 设置主界面。
///
/// 布局自上而下分四层，每一层的职责单一：
/// 1. **头部栏** —— 产品标识 + 全局主动作（新增规则）；
/// 2. **状态区** —— 权限横幅（仅在未授权时出现）+ 引擎/权限状态胶囊；
/// 3. **规则区** —— 规则卡片列表；无规则时显示空态引导，不留白板；
/// 4. **快捷键区** —— 本应用自身的快捷键（⌘, / ⌘N / ⌘W / ⌘Q）；
/// 5. **帮助区** —— 把「没生效怎么办」这类排障信息收进可折叠区块，不干扰主流程。
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var token: EditToken?
    @State private var showHelp = false

    private var conflicts: Set<UUID> { state.conflictingIDs() }

    /// 本应用自身的快捷键。写在这里而不是散在文档里 ——
    /// ⌘W / ⌘Q 是「装上去就忘了」的那类能力，用户在设置窗口里顺眼看到才会用。
    private let appShortcuts: [(key: String, title: String)] = [
        (",", "打开这个设置窗口"),
        ("N", "新增一条规则"),
        ("W", "关闭设置窗口（不退出应用）"),
        ("Q", "退出 NBKey")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if !state.accessibilityGranted { permissionBanner }
                    statusRow
                    rulesSection
                    shortcutsSection
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 帮助区钉在窗口底部而不是跟着滚动：它本来就是「随时可能要看一眼」的内容，
            // 钉住能让下方空间有个收尾，不至于让规则列表下面挂一大片空白。
            Hairline()
            helpSection
        }
        .frame(minWidth: 740, minHeight: 540)
        // 快照回归用的钩子：正常使用时这两个信号永远是 false，不会有任何行为。
        .onChange(of: state.snapshotOpenEditorSignal) { _, armed in
            if armed { addRule() }
        }
        .onChange(of: state.snapshotExpandHelpSignal) { _, armed in
            if armed { showHelp = true }
        }
        .sheet(item: $token) { tk in
            RuleEditorView(initial: tk.rule,
                           isNew: tk.isNew,
                           existing: state.rules,
                           onSave: { saved in
                               if tk.isNew { state.add(saved) } else { state.update(saved) }
                               token = nil
                           },
                           onCancel: { token = nil })
        }
    }

    // MARK: - 头部栏

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            appIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("NBKey").font(DS.Text.pageTitle)
                Text("在系统快捷键之上，再加一层自定义组合")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Palette.secondary)
            }
            Spacer(minLength: DS.Space.m)
            Button {
                addRule()
            } label: {
                Label("新增规则", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
            .help("新增一条规则（⌘N）")
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.m + 2)
        .background(DS.Palette.surface)
    }

    private var appIcon: some View {
        Group {
            if let img = Self.brandImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            } else {
                // 连 bundle 里的 icns 都读不到时的兜底：画一个品牌色方块，别留一块空白。
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Palette.accent.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "command").foregroundStyle(DS.Palette.accent))
            }
        }
    }

    /// 品牌图标。
    ///
    /// 为什么不直接用 `NSApp.applicationIconImage`：本应用是 `LSUIElement`（无 Dock 图标），
    /// 实测这条路径会退回**系统通用图标**（界面上就是一块空白方块），而且失败时不会有任何报错。
    /// 改成直接从 bundle 资源里读 `AppIcon.icns`，路径确定、结果可预期；
    /// 读不到才退回 `applicationIconImage`。
    private static let brandImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }()

    // MARK: - 状态区

    private var statusRow: some View {
        HStack(spacing: DS.Space.s) {
            if state.engineRunning {
                StatusChip(text: "引擎运行中", tint: DS.Palette.ok)
                StatusChip(text: "正在监听全局组合", tint: DS.Palette.ok)
            } else if state.accessibilityGranted {
                StatusChip(text: "引擎未启动", tint: DS.Palette.warn)
            } else {
                StatusChip(text: "辅助功能未授权", tint: DS.Palette.warn)
            }
            Spacer(minLength: DS.Space.s)
            Button {
                state.refreshAccessibility()
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(DS.Text.caption)
            .help("重新检查辅助功能权限并尝试启动引擎")
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(DS.Palette.warn)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("需要「辅助功能」权限").font(DS.Text.cardTitle)
                Text("授权后本应用才能监听并拦截全局按键 / 鼠标组合。授权完成后回到本窗口会自动重试。")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s) {
                    Button("去开启权限") { Permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("我已开启，重试") { state.refreshAccessibility() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, DS.Space.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
        .dsBlock(fill: DS.Palette.warn.opacity(0.08), tint: DS.Palette.warn.opacity(0.35))
    }

    // MARK: - 规则区

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "规则",
                          trailing: state.rules.isEmpty ? nil : "共 \(state.rules.count) 条")
            if state.rules.isEmpty {
                emptyState
            } else {
                VStack(spacing: DS.Space.s) {
                    ForEach($state.rules) { $rule in
                        RuleRow(rule: $rule,
                                isConflict: conflicts.contains(rule.id),
                                onEdit: { token = EditToken(rule: rule, isNew: false) },
                                onDelete: { state.remove(rule) })
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "keyboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DS.Palette.tertiary)
                .padding(.bottom, DS.Space.xxs)
            Text("还没有任何规则").font(DS.Text.cardTitle)
            Text("添加一条规则，把一个组合键映射到系统操作。")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Palette.secondary)
            Button("添加第一条规则") { addRule() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xxl)
        .dsCard()
    }

    // MARK: - 快捷键区

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "应用快捷键")
            VStack(spacing: 0) {
                ForEach(Array(appShortcuts.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Hairline().padding(.leading, DS.Space.m + 2)
                    }
                    HStack(spacing: DS.Space.m) {
                        // 键帽区固定宽度：否则 ", " / "N" 这些键帽宽窄不一，
                        // 右边的说明文字会参差不齐。
                        HStack(spacing: DS.Space.xs) {
                            KeyCap(text: "⌘")
                            KeyCap(text: item.key, tint: DS.Palette.accent, emphasized: true)
                        }
                        .frame(width: 60, alignment: .leading)
                        Text(item.title)
                            .font(DS.Text.body)
                            .foregroundStyle(DS.Palette.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.m + 2)
                    .padding(.vertical, DS.Space.s + 1)
                }
            }
            .dsCard()
        }
    }

    // MARK: - 帮助区

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showHelp.toggle() }
            } label: {
                HStack(spacing: DS.Space.xs + 1) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Palette.tertiary)
                        .rotationEffect(.degrees(showHelp ? 90 : 0))
                    Text("没生效？先检查这两处")
                        .font(DS.Text.section)
                        .foregroundStyle(DS.Palette.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.s + 2)

            if showHelp {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    helpItem(
                        title: "确认「在活动空间之间移动」仍是系统默认绑定",
                        detail: "系统设置 › 键盘 › 键盘快捷键 › 调度中心。默认规则依赖这个绑定。"
                    )
                    helpItem(
                        title: "确认辅助功能权限已开启",
                        detail: "系统设置 › 隐私与安全性 › 辅助功能。授权后回到本窗口会自动重试启动引擎。"
                    )
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsBlock()
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.l)
            }
        }
    }

    private func helpItem(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Circle().fill(DS.Palette.tertiary).frame(width: 4, height: 4).padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Text.caption).foregroundStyle(DS.Palette.primary)
                Text(detail)
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 动作

    private func addRule() {
        token = EditToken(rule: HotkeyRule(name: "",
                                           enabled: true,
                                           trigger: .keyboard(modifiers: Modifiers(control: true), keyCode: 49),
                                           action: HotkeyAction(modifiers: Modifiers(control: true), keyCode: 123)),
                          isNew: true)
    }
}

// MARK: - 列表行的编辑令牌

struct EditToken: Identifiable {
    let id = UUID()
    let rule: HotkeyRule
    let isNew: Bool
}

// MARK: - 规则卡片

/// 单条规则。信息层级从上到下：规则名 → 「触发 → 动作」的键帽对照 → 右侧开关与操作。
///
/// 为什么把触发/动作做成键帽而不是一行文字：这是用户最需要快速核对的信息，
/// 键帽能形成两个视觉块，扫一眼就能比对「我按的组合」和「实际执行的操作」是否一致。
struct RuleRow: View {
    @Binding var rule: HotkeyRule
    let isConflict: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                        .font(DS.Text.cardTitle)
                        .foregroundStyle(rule.enabled ? DS.Palette.primary : DS.Palette.tertiary)
                        .lineLimit(1)
                    if isConflict {
                        StatusChip(text: "触发组合重复", tint: DS.Palette.danger,
                                   systemImage: "exclamationmark.triangle.fill")
                    }
                    if !rule.enabled {
                        StatusChip(text: "已停用", tint: DS.Palette.secondary)
                    }
                }
                HStack(spacing: DS.Space.s) {
                    KeyComboCaps(modifiers: rule.trigger.modifiers,
                                 keyLabel: triggerKeyLabel(rule.trigger))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Palette.tertiary)
                        .padding(.horizontal, DS.Space.xxs)
                    KeyComboCaps(modifiers: rule.action.modifiers,
                                 keyLabel: keyGlyph(rule.action.keyCode),
                                 tint: DS.Palette.secondary)
                }
            }

            Spacer(minLength: DS.Space.m)

            Toggle("", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(rule.enabled ? "停用这条规则" : "启用这条规则")
                .onChange(of: rule.enabled) { _, _ in state.save() }

            HStack(spacing: DS.Space.s) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.Palette.secondary)
                .help("编辑这条规则")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(hovering ? DS.Palette.danger : DS.Palette.secondary)
                .help("删除这条规则")
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, DS.Space.m + 2)
        .padding(.vertical, DS.Space.m)
        .opacity(rule.enabled ? 1 : 0.66)
        .dsCard(tint: isConflict ? DS.Palette.danger.opacity(0.5)
                                 : (hovering ? DS.Palette.accent.opacity(0.45) : DS.Palette.hairline))
        .onHover { hovering = $0 }
    }

    private func triggerKeyLabel(_ trigger: Trigger) -> String {
        switch trigger {
        case let .keyboard(_, keyCode): return keyGlyph(keyCode)
        case let .mouse(_, button): return "鼠标\(button.label)"
        }
    }
}

// MARK: - 规则编辑器（sheet）

struct RuleEditorView: View {
    @EnvironmentObject var state: AppState
    @State private var draft: HotkeyRule
    @State private var capturing = false
    let isNew: Bool
    let existing: [HotkeyRule]
    let onSave: (HotkeyRule) -> Void
    let onCancel: () -> Void

    init(initial: HotkeyRule, isNew: Bool, existing: [HotkeyRule],
         onSave: @escaping (HotkeyRule) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.isNew = isNew
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var triggerIsMouse: Binding<Bool> {
        Binding(get: { draft.trigger.isMouse },
                set: { isMouse in
                    if isMouse {
                        draft.trigger = .mouse(modifiers: draft.trigger.modifiers, button: .left)
                    } else {
                        draft.trigger = .keyboard(modifiers: draft.trigger.modifiers, keyCode: 49)
                    }
                })
    }

    private var conflictWithExisting: Bool {
        let base = draft.trigger.numericSig()
        let key = draft.trigger.isMouse ? (UInt32(0x80000000) | base) : base
        return existing.contains { $0.id != draft.id && $0.enabled &&
            (($0.trigger.isMouse ? (UInt32(0x80000000) | $0.trigger.numericSig()) : $0.trigger.numericSig()) == key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader
            Hairline()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    basicsCard
                    triggerCard
                    actionCard
                    if conflictWithExisting { conflictNotice }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            editorFooter
        }
        .frame(width: 520, height: 620)
    }

    private var editorHeader: some View {
        HStack {
            Text(isNew ? "新增规则" : "编辑规则").font(DS.Text.pageTitle)
            Spacer()
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
        .background(DS.Palette.surface)
    }

    // MARK: 各区块

    private var basicsCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            fieldLabel("名称")
            TextField("给这条规则起个名字，例如「切换上一个桌面」", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Toggle("启用此规则", isOn: $draft.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(DS.Text.body)
        }
        .padding(DS.Space.l)
        .dsCard()
    }

    private var triggerCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                fieldLabel("触发组合")
                Spacer()
                comboPreview(modifiers: draft.trigger.modifiers,
                             keyLabel: triggerKeyLabel(draft.trigger))
            }

            Picker("", selection: triggerIsMouse) {
                Text("键盘快捷键").tag(false)
                Text("鼠标组合").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: DS.Space.s) {
                recordButton
                Text(capturing ? "正在监听，按下想用的组合即可" : "也可以直接在下方勾选修饰键")
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Palette.secondary)
            }

            if !state.accessibilityGranted {
                Text("需先授予辅助功能权限才能录制（见主窗口提示）。")
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Palette.warn)
            }

            ModifierPicker(modifiers: triggerModifiers)
        }
        .padding(DS.Space.l)
        .dsCard()
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                fieldLabel("执行动作")
                Spacer()
                comboPreview(modifiers: draft.action.modifiers,
                             keyLabel: keyGlyph(draft.action.keyCode))
            }
            Text("命中触发组合时，会模拟按下这个键盘快捷键。")
                .font(DS.Text.micro)
                .foregroundStyle(DS.Palette.secondary)

            Picker("目标键", selection: $draft.action.keyCode) {
                ForEach(commonKeys) { k in
                    Text(k.name).tag(k.keyCode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)

            ModifierPicker(modifiers: actionModifiers)

            if draft.action.isSpaceSwitch {
                HStack(spacing: DS.Space.xs + 1) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Palette.accent)
                    Text("⌃← / ⌃→ 会被识别为「切换桌面」，走系统原生的手势切换（带动画、支持台前调度），不会去模拟按键。")
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Space.l)
        .dsCard()
    }

    private var conflictNotice: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.Palette.danger)
            Text("该触发组合与已有启用规则重复，两者都会被触发。建议换一个组合或先停用其中一条。")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .dsBlock(fill: DS.Palette.danger.opacity(0.07), tint: DS.Palette.danger.opacity(0.35))
    }

    private var editorFooter: some View {
        HStack(spacing: DS.Space.s) {
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("保存") {
                if capturing { state.engine.cancelCapture() }
                onSave(draft)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.return)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
        .background(DS.Palette.surface)
    }

    // MARK: 辅助

    /// 录制按钮。绘制样式随录制状态变化，所以拆成两分支而不是写三元表达式 ——
    /// `buttonStyle(_:)` 的参数是泛型 `ButtonStyle`，三元表达式里两个不同的样式无法推断出同一类型。
    @ViewBuilder
    private var recordButton: some View {
        let label = Label(capturing ? "请按下组合键…" : "录制组合",
                          systemImage: capturing ? "record.circle.fill" : "record.circle")
        let action = {
            capturing = true
            state.beginCapture { trigger in
                draft.trigger = trigger
                capturing = false
            }
        }
        if capturing {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.accessibilityGranted)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(DS.Text.section).foregroundStyle(DS.Palette.secondary)
    }

    private func comboPreview(modifiers: Modifiers, keyLabel: String) -> some View {
        KeyComboCaps(modifiers: modifiers, keyLabel: keyLabel)
    }

    private func triggerKeyLabel(_ trigger: Trigger) -> String {
        switch trigger {
        case let .keyboard(_, keyCode): return keyGlyph(keyCode)
        case let .mouse(_, button): return "鼠标\(button.label)"
        }
    }

    private var triggerModifiers: Binding<Modifiers> {
        Binding(get: { draft.trigger.modifiers },
                set: { draft.trigger = setModifiers(on: draft.trigger, to: $0) })
    }

    private var actionModifiers: Binding<Modifiers> {
        Binding(get: { draft.action.modifiers }, set: { draft.action.modifiers = $0 })
    }
}

/// 修饰键选择器。
///
/// 为什么不用 `.toggleStyle(.button)`：系统那个样式在 macOS 上明显比周围的键帽高一大截，
/// 一排下来会打破「界面里所有小方块都长得一样」的视觉语言；而且选中/未选中的形态差异也不够清楚。
/// 这里自己画，尺寸与 `KeyCap` 对齐，选中态直接复用强调色。
struct ModifierPicker: View {
    @Binding var modifiers: Modifiers

    private struct Item {
        let symbol: String
        let name: String
        let isOn: WritableKeyPath<Modifiers, Bool>
    }

    private let items: [Item] = [
        Item(symbol: "⌃", name: "Control", isOn: \.control),
        Item(symbol: "⌥", name: "Option", isOn: \.option),
        Item(symbol: "⇧", name: "Shift", isOn: \.shift),
        Item(symbol: "⌘", name: "Command", isOn: \.command),
        Item(symbol: "fn", name: "Function", isOn: \.function)
    ]

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let on = modifiers[keyPath: item.isOn]
                Button {
                    modifiers[keyPath: item.isOn].toggle()
                } label: {
                    Text(item.symbol)
                        .font(DS.Text.keycap)
                        .foregroundStyle(on ? DS.Palette.accent : DS.Palette.primary)
                        .frame(minWidth: 22, minHeight: 16)
                        .padding(.horizontal, DS.Space.s - 1)
                        .padding(.vertical, DS.Space.xxs + 1)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                                .fill(on ? DS.Palette.accent.opacity(0.14) : DS.Palette.keycapFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                                .strokeBorder(on ? DS.Palette.accent.opacity(0.5)
                                                 : DS.Palette.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.name)
            }
        }
    }
}

private func setModifiers(on trigger: Trigger, to m: Modifiers) -> Trigger {
    switch trigger {
    case let .keyboard(_, keyCode): return .keyboard(modifiers: m, keyCode: keyCode)
    case let .mouse(_, button): return .mouse(modifiers: m, button: button)
    }
}
