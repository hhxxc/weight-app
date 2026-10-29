import SwiftUI

/// 通用小组件：进度环 / 迷你柱状图（首页英雄卡用）

/// 减重进度环：细线环 + 圆心百分比
struct ProgressRing: View {
    /// 0...1
    let progress: Double
    var lineWidth: CGFloat = 7
    var size: CGFloat = 84

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.fill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(Theme.brandDeep, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: size * 0.19, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()
                Text("已减进度")
                    .font(.system(size: max(8, size * 0.105)))
                    .foregroundColor(Theme.inkTertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 迷你柱状图：最近 N 次记录，最后两根用主色，其余浅灰
struct MiniBars: View {
    let values: [Double]
    var height: CGFloat = 46

    private var maxValue: Double { max(values.max() ?? 1, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
                let isLast = idx >= values.count - 2
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isLast ? Theme.ink : Theme.fill)
                    .frame(height: max(4, CGFloat(v / maxValue) * height))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}
