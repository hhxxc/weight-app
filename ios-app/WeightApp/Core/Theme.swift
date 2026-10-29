import SwiftUI
import UIKit

/// 全局主题：暖色极简（暖纸底 + 白卡 + 细线 + 深青绿强调）
/// 色值随深浅色模式自适应。
enum Theme {
    // MARK: - 中性色板（动态）

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// 主文字（暖调近黑）
    static let ink = dynamic(light: 0x23201C, dark: 0xF3EFE9)
    /// 次级文字
    static let inkSecondary = dynamic(light: 0x7A736B, dark: 0xB0A79C)
    /// 辅助说明
    static let inkTertiary = dynamic(light: 0xA39A90, dark: 0x7D746B)
    /// 细分割线
    static let hairline = dynamic(light: 0xEAE4DB, dark: 0x2E2A25)
    /// 页面底色（暖纸）
    static let canvas = dynamic(light: 0xF5F1EA, dark: 0x171512)
    /// 卡片底色
    static let card = dynamic(light: 0xFFFFFF, dark: 0x23201B)
    /// 极浅填充（进度条底、今日高亮）
    static let fill = dynamic(light: 0xF0EBE3, dark: 0x2E2A25)

    /// 实心块底色（按钮/头像底）：浅色暖近黑，深色灰棕，保证白字可读
    static let solid = dynamic(light: 0x23201C, dark: 0x4A443C)

    /// 深色实心块（按钮/强调块）
    static var brandGradient: LinearGradient {
        LinearGradient(gradient: Gradient(colors: [solid, solid]),
                       startPoint: .top,
                       endPoint: .bottom)
    }

    // 强调色：深青绿，数值/链接/进度用
    static let brandBlue = dynamic(light: 0x1F6F63, dark: 0x6FBFAE)
    static let brandCyan = brandBlue
    static let brandDeep = brandBlue

    // 功能色（暖调）
    static let success = dynamic(light: 0x2F7D6E, dark: 0x6FC2A8)
    static let warning = dynamic(light: 0xB8794A, dark: 0xD9A46B)
    static let danger = dynamic(light: 0xB5523F, dark: 0xE08573)
    static let textMuted = dynamic(light: 0x8E8E93, dark: 0x8E8E93)

    // 卡片背景
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)

    /// AI 建议卡背景：极浅暖灰
    static let adviceBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.13, blue: 0.11, alpha: 1.0)
            : UIColor(red: 0.965, green: 0.953, blue: 0.933, alpha: 1.0)
    })

    /// 统一的卡片容器：圆角 20 + 白底 + 轻阴影
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(card)
            )
            .cardShadow()
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

/// 卡片阴影：暖调浅阴影，制造一点层次
extension View {
    func cardShadow() -> some View {
        self.shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }
}

extension Theme {
    /// 全局表格外观：列表背景透明，让暖纸底色透出来；分隔线统一用主题细线
    static func applyAppearance() {
        UITableView.appearance().backgroundColor = .clear
        UITableView.appearance().separatorColor = UIColor(hex: 0xEAE4DB)
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
