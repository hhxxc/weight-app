import SwiftUI

/// 全局主题：极简白（大字号 + 留白 + 细分割线 + 单一强调色）
/// 色值全部随深浅色模式自适应，避免深色下近黑文字看不见。
enum Theme {
    // MARK: - 中性色板（动态）

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// 主文字
    static let ink = dynamic(light: 0x111114, dark: 0xF2F2F7)
    /// 次级文字
    static let inkSecondary = dynamic(light: 0x6B6B73, dark: 0xA1A1AA)
    /// 辅助说明
    static let inkTertiary = dynamic(light: 0x9A9AA2, dark: 0x6E6E76)
    /// 细分割线
    static let hairline = dynamic(light: 0xE8E8ED, dark: 0x2C2C2E)
    /// 页面底色
    static let canvas = dynamic(light: 0xF6F6F8, dark: 0x000000)
    /// 卡片底色
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// 极浅填充（进度条底、今日高亮）
    static let fill = dynamic(light: 0xEFEFF2, dark: 0x2C2C2E)

    /// 实心块底色（黑按钮/头像底）：浅色近黑，深色改成 #3A3A3C，保证白字始终可读
    static let solid = dynamic(light: 0x111114, dark: 0x3A3A3C)

    /// 深色实心块（按钮/强调块），替代原来的蓝青渐变
    static var brandGradient: LinearGradient {
        LinearGradient(gradient: Gradient(colors: [solid, solid]),
                       startPoint: .top,
                       endPoint: .bottom)
    }

    // 唯一强调色：低饱和深青，只用在数值和链接上（深色下提亮）
    static let brandBlue = dynamic(light: 0x0A7EA4, dark: 0x5BC0DE)
    static let brandCyan = brandBlue
    static let brandDeep = brandBlue

    // 功能色
    static let success = dynamic(light: 0x2E7D5B, dark: 0x4FBF8B)
    static let warning = dynamic(light: 0xC77700, dark: 0xE0A64A)
    static let danger = dynamic(light: 0xC0392B, dark: 0xE06C5F)
    static let textMuted = dynamic(light: 0x8E8E93, dark: 0x8E8E93)

    // 卡片背景
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)

    /// AI 建议卡背景：极浅中性底
    static let adviceBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
            : UIColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1.0)
    })

    /// 统一的卡片容器样式：圆角 18 + 卡片底 + 0.5 细边
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hairline, lineWidth: 0.5)
            )
    }

    /// 胶囊标签（中性底 + 深色字）
    static func pill(_ text: String, bg: Color? = nil, fg: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(fg ?? inkSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(bg ?? fill)
            .clipShape(Capsule())
    }
}

/// 卡片阴影修饰符（iOS 15 可用）——极简风不用阴影，保留空实现避免改动调用点
extension View {
    func cardShadow() -> some View {
        self
    }
}

/// 轻微按压反馈：0.98 缩放 + 降透明度，用在主按钮上
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
