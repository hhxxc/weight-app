import SwiftUI

/// 全局主题：极简白（大字号 + 留白 + 细分割线 + 单一强调色）
enum Theme {
    // MARK: - 中性色板
    /// 主文字（近黑）
    static let ink = Color(hex: "111114")
    /// 次级文字
    static let inkSecondary = Color(hex: "6B6B73")
    /// 辅助说明
    static let inkTertiary = Color(hex: "9A9AA2")
    /// 细分割线
    static let hairline = Color(hex: "E8E8ED")
    /// 页面底色（分组的浅灰）
    static let canvas = Color(hex: "F6F6F8")
    /// 卡片底色
    static let card = Color.white

    /// 深色实心块（按钮/强调块），替代原来的蓝青渐变
    static let brandGradient = LinearGradient(
        gradient: Gradient(colors: [ink, ink]),
        startPoint: .top,
        endPoint: .bottom
    )

    // 唯一强调色：低饱和深青，只用在数值和链接上
    static let brandBlue = Color(hex: "0A7EA4")
    static let brandCyan = Color(hex: "0A7EA4")
    static let brandDeep = Color(hex: "0A7EA4")

    // 功能色
    static let success = Color(hex: "2E7D5B")
    static let warning = Color(hex: "C77700")
    static let danger = Color(hex: "C0392B")
    static let textMuted = Color(hex: "8E8E93")

    // 卡片背景
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)

    /// AI 建议卡背景：极浅中性底，不再用蓝色
    static let adviceBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
            : UIColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1.0)
    })

    /// 统一的卡片容器样式：圆角 18 + 白底 + 0.5 细边
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
    static func pill(_ text: String, bg: Color = Color(hex: "F1F1F4"), fg: Color = inkSecondary) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
    }
}

/// 卡片阴影修饰符（iOS 15 可用）——极简风不用阴影，保留空实现避免改动调用点
extension View {
    func cardShadow() -> some View {
        self
    }
}
