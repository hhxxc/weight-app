import SwiftUI

/// 体重趋势折线图（自绘，兼容 iOS 15，不依赖 Swift Charts）
/// 传入按日期升序排列的体重记录。
struct TrendChartView: View {
    let weights: [WeightRecord]   // 升序
    var height: CGFloat = 200
    var showDetail: Bool = true   // 是否显示坐标轴/标签

    private var minKg: Double { weights.map { $0.kg }.min() ?? 0 }
    private var maxKg: Double { weights.map { $0.kg }.max() ?? 1 }
    private var range: Double { max(maxKg - minKg, 0.5) }

    var body: some View {
        GeometryReader { geo in
            let pts = normalizedPoints(in: geo.size)
            ZStack {
                // 渐变填充面积
                if pts.count > 1 {
                    TrendFill(points: pts)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Theme.brandCyan.opacity(0.25),
                                    Theme.brandCyan.opacity(0.0),
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                // 背景网格
                if showDetail {
                    grid(in: geo.size)
                }
                // 折线
                TrendPath(points: pts, range: range, minKg: minKg)
                    .stroke(Theme.brandDeep, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                // 数据点
                ForEach(Array(pts.enumerated()), id: \.offset) { idx, p in
                    Circle()
                        .fill(Theme.brandDeep)
                        .frame(width: idx == pts.count - 1 ? 8 : 5, height: idx == pts.count - 1 ? 8 : 5)
                        .position(p)
                }
            }
        }
        .frame(height: height)
    }

    /// 把体重数据映射成画布坐标
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard weights.count > 1 else { return [] }
        let pad: CGFloat = 16
        let w = size.width - pad * 2
        let h = size.height - pad * 2
        let n = weights.count
        return weights.enumerated().map { idx, rec in
            let x = pad + (n == 1 ? 0 : CGFloat(idx) * w / CGFloat(n - 1))
            let y = pad + CGFloat(1 - (rec.kg - minKg) / range) * h
            return CGPoint(x: x, y: y)
        }
    }

    private func grid(in size: CGSize) -> some View {
        VStack {
            ForEach(0..<3) { _ in
                Divider()
                Spacer()
            }
        }
    }
}

/// 折线路径（把点连成折线）
struct TrendPath: Shape {
    let points: [CGPoint]
    let range: Double
    let minKg: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1, let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() {
            path.addLine(to: p)
        }
        return path
    }
}

/// 折线下方到图底的填充面积（渐变填充用）
struct TrendFill: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: rect.height))
        path.addLine(to: first)
        for p in points.dropFirst() {
            path.addLine(to: p)
        }
        guard let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// 趋势大图页（Sheet 全屏展示）
struct TrendView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var ascending: [WeightRecord] {
        state.weights.sorted { $0.date < $1.date }
    }

    private var stats: (min: Double, max: Double, avg: Double, change: Double) {
        let kgs = ascending.map { $0.kg }
        let min = kgs.min() ?? 0
        let max = kgs.max() ?? 0
        let avg = kgs.isEmpty ? 0 : kgs.reduce(0, +) / Double(kgs.count)
        let change = (kgs.last ?? 0) - (kgs.first ?? 0)
        return (min, max, avg, change)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 统计卡片
                    HStack(spacing: 0) {
                        statItem("区间", String(format: "%.1f–%.1f", stats.min, stats.max))
                        statItem("平均", String(format: "%.1f", stats.avg))
                        statItem("变化", String(format: "%+.1f", stats.change))
                    }
                    .padding(.vertical, 8)

                    // 大图
                    TrendChartView(weights: ascending, height: 260, showDetail: true)
                        .padding(.horizontal, 8)

                    Text("按日期升序，共 \(ascending.count) 条")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("体重趋势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
