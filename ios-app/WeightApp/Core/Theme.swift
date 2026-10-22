import SwiftUI

/// 全局主题：统一蓝青渐变 + 卡片样式 + 配色
/// 与 App 图标（logo.svg）保持一致的品牌视觉。
enum Theme {
    // MARK: - 品牌渐变（蓝 → 青，呼应图标）
    static let brandGradient = LinearGradient(
        gradient: Gradient(colors: [Color(hex: "3B82F6"), Color(hex: "22D3EE")]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // 主色 / 强调色
    static let brandBlue = Color(hex: "3B82F6")
    static let brandCyan = Color(hex: "22D3EE")
    static let brandDeep = Color(hex: "0A7EA4")   // 深青，用于文字/强调

    // 功能色（中国习惯：涨红跌绿不适用，这里是通用语义）
    static let success = Color(hex: "34C759")
    static let warning = Color(hex: "FF9500")
    static let danger = Color(hex: "FF3B30")
    static let textMuted = Color(hex: "8E8E93")

    // 卡片背景（浅灰白，带轻阴影）
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)

    /// 统一的卡片容器样式：圆角 16 + 白底 + 轻阴影
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 胶囊标签（用于 BMI 等级、状态等）
    static func pill(_ text: String, bg: Color = Color.white.opacity(0.22), fg: Color = Color.white) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
    }
}

/// 卡片阴影修饰符（iOS 15 可用）
extension View {
    func cardShadow() -> some View {
        self.shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}
