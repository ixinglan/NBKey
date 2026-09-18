import SwiftUI
import AppKit

// MARK: - 设计令牌

/// 全应用统一的视觉常量。界面里出现的每一个色值 / 间距 / 圆角 / 字号都从这里取。
///
/// 两条硬规则：
/// 1. **颜色只用系统语义色**（`NSColor` 的动态色）。浅色 / 深色模式、以及用户更换系统强调色
///    都能自动跟随 —— 自己写死颜色就必须维护两套，且出现低对比时不易察觉。
/// 2. **间距只用刻度值**（4 的倍数）。避免 7 / 13 这类随手值让卡片之间对不齐。
enum DS {

    /// 间距刻度。
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 28
    }

    /// 圆角。
    enum Radius {
        static let chip: CGFloat = 6     // 键帽 / 胶囊
        static let card: CGFloat = 10    // 规则卡片
        static let block: CGFloat = 12   // 横幅 / 提示卡
    }

    /// 字号梯度。整体比 SwiftUI 默认略小 —— 这是工具窗口，信息密度比“大标题”重要。
    enum Text {
        static let pageTitle = Font.system(size: 17, weight: .semibold)
        static let cardTitle = Font.system(size: 13, weight: .semibold)
        static let section   = Font.system(size: 11, weight: .semibold)
        static let body      = Font.system(size: 12)
        static let caption   = Font.system(size: 11)
        static let micro     = Font.system(size: 10)
        static let keycap    = Font.system(size: 11.5, weight: .medium, design: .rounded)
    }

    /// 色板（全部来自系统语义色，深浅色自动跟随）。
    enum Palette {
        static let surface   = Color(nsColor: .controlBackgroundColor)   // 卡片 / 头部栏
        static let canvas    = Color(nsColor: .windowBackgroundColor)    // 窗口底色
        static let hairline  = Color(nsColor: .separatorColor)           // 描边 / 分隔
        static let primary   = Color(nsColor: .labelColor)
        static let secondary = Color(nsColor: .secondaryLabelColor)
        static let tertiary  = Color(nsColor: .tertiaryLabelColor)
        static let accent    = Color.accentColor
        static let ok        = Color(nsColor: .systemGreen)
        static let warn      = Color(nsColor: .systemOrange)
        static let danger    = Color(nsColor: .systemRed)

        /// 键帽底色：在卡片表面色之上再叠一层极淡的前景色，
        /// 保证浅色 / 深色两种模式下键帽都与卡片有区分度。
        static let keycapFill = Color.primary.opacity(0.07)
    }
}

// MARK: - 基础组件

/// 键帽：把 `⌃`、`←`、`鼠标左键` 这类元素显示成一个个独立圆角小块。
///
/// 这是本界面最重要的信息设计 —— 用户扫一眼就知道「按什么 → 得到什么」，
/// 不必去读 `Ctrl+鼠标左键 → Ctrl+←` 这样串成一行的纯文本。
struct KeyCap: View {
    let text: String
    var tint: Color = DS.Palette.secondary
    var emphasized: Bool = false

    var body: some View {
        Text(text)
            .font(DS.Text.keycap)
            .foregroundStyle(emphasized ? tint : DS.Palette.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DS.Space.s - 1)
            .padding(.vertical, DS.Space.xxs + 1)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(emphasized ? tint.opacity(0.12) : DS.Palette.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .strokeBorder(emphasized ? tint.opacity(0.32) : DS.Palette.hairline, lineWidth: 1)
            )
    }
}

/// 一组键帽：按 macOS 习惯，每个修饰键一个帽子，最后跟目标键 / 鼠标键。
/// 例：`⌃` `鼠标右键` 或 `⌃` `←`。
struct KeyComboCaps: View {
    let modifiers: Modifiers
    let keyLabel: String
    var tint: Color = DS.Palette.accent

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if modifiers.control  { KeyCap(text: "⌃") }
            if modifiers.option   { KeyCap(text: "⌥") }
            if modifiers.shift    { KeyCap(text: "⇧") }
            if modifiers.command  { KeyCap(text: "⌘") }
            if modifiers.function { KeyCap(text: "fn") }
            KeyCap(text: keyLabel, tint: tint, emphasized: true)
        }
    }
}

/// 状态胶囊：一个小图标 / 圆点 + 文案。
/// 引擎、权限、冲突三种状态共用同一套视觉语言，避免每个地方各写一种「彩色横条」。
struct StatusChip: View {
    let text: String
    var tint: Color
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: DS.Space.xs + 1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(text)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Palette.secondary)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs + 1)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

/// 区块小标题（左标题 + 右说明）。
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title).font(DS.Text.section).foregroundStyle(DS.Palette.secondary)
            Spacer(minLength: 0)
            if let trailing {
                // 用 secondary 而不是 tertiary：tertiaryLabelColor 在白底上的对比度只有 2:1 左右，
                // 达不到正文 4.5:1 的可读性门槛。这类「共 N 条」是有信息量的内容，不该被调那么淡。
                Text(trailing).font(DS.Text.micro).foregroundStyle(DS.Palette.secondary)
            }
        }
    }
}

/// 1px 分隔线。
/// 为什么不用 `Divider()`：它的粗细与颜色不可控，在不同容器里表现不一致。
struct Hairline: View {
    var body: some View {
        Rectangle().fill(DS.Palette.hairline).frame(height: 1)
    }
}

extension View {
    /// 统一的卡片外观：表面色底 + 1px 描边 + 极轻阴影。
    func dsCard(tint: Color = DS.Palette.hairline) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
    }

    /// 区块容器：更大圆角，用于「提示卡 / 警示卡」这类成块内容。
    /// `fill` 单独开放出来，是为了让警示卡能换底色而不是被迫用表面色。
    func dsBlock(fill: Color = DS.Palette.surface,
                 tint: Color = DS.Palette.hairline) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1)
            )
    }
}
