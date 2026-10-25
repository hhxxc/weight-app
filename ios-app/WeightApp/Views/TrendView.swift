import SwiftUI

/// 体重趋势折线图（自绘，兼容 iOS 15，不依赖 Swift Charts）
/// 传入按日期升序排列的体重记录。
struct TrendChartView: View {
    let weights: [WeightRecord]   // 升序
    var height: CGFloat = 200
    var showDetail: Bool = true   // 是否显示坐标轴/标签
    var targetKg: Double? = nil   // 目标线（距离过远时自动忽略）
    var showAverage: Bool = false // 叠加 7 日移动平均虚线
    var interactive: Bool = false // 长按/拖动查看某天数值

    @State private var touchX: CGFloat?

    private var rawMin: Double { weights.map { $0.kg }.min() ?? 0 }
    private var rawMax: Double { weights.map { $0.kg }.max() ?? 1 }

    /// 目标线离当前区间过远时不画，否则会把折线压成一条直线
    private var targetInRange: Double? {
        guard let t = targetKg else { return nil }
        return (rawMin - t <= 12 && t <= rawMax + 2) ? t : nil
    }

    private var minKg: Double { min(rawMin, targetInRange ?? rawMin) }
    private var maxKg: Double { max(rawMax, targetInRange ?? rawMax) }
    private var range: Double { max(maxKg - minKg, 0.5) }

    var body: some View {
        GeometryReader { geo in
            let pts = normalizedPoints(weights, in: geo.size)
            let avgPts = showAverage
                ? normalizedPoints(TrendAnalysis.movingAverage(weights), in: geo.size)
                : []
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
                // 目标线
                if let target = targetInRange {
                    let y = yPosition(for: target, in: geo.size)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Theme.warning.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Text("目标 \(String(format: "%.1f", target))")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.warning)
                        .position(x: 38, y: max(8, y - 9))
                }
                // 7 日移动平均（平滑日常称重噪声）
                if avgPts.count > 1 {
                    TrendPath(points: avgPts, range: range, minKg: minKg)
                        .stroke(Theme.brandBlue.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                }
                // 实际折线
                TrendPath(points: pts, range: range, minKg: minKg)
                    .stroke(Theme.brandDeep, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                // 数据点
                ForEach(Array(pts.enumerated()), id: \.offset) { idx, p in
                    Circle()
                        .fill(Theme.brandDeep)
                        .frame(width: idx == pts.count - 1 ? 8 : 5, height: idx == pts.count - 1 ? 8 : 5)
                        .position(p)
                }
                // 交互：横向滑动查看某天数值
                if interactive, let tx = touchX, let idx = nearestIndex(tx, in: pts), idx < weights.count {
                    let p = pts[idx]
                    let rec = weights[idx]
                    Path { path in
                        path.move(to: CGPoint(x: p.x, y: 0))
                        path.addLine(to: CGPoint(x: p.x, y: geo.size.height))
                    }
                    .stroke(Theme.brandDeep.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Theme.brandDeep, lineWidth: 3))
                        .position(p)

                    VStack(spacing: 1) {
                        Text(String(format: "%.1f kg", rec.kg))
                            .font(.caption2.bold())
                            .foregroundColor(.primary)
                        Text(chineseDateString(rec.date))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                            .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                    )
                    .position(x: min(max(p.x, 56), geo.size.width - 56), y: 22)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard interactive else { return }
                        // 只在横向滑动时激活，避免抢走页面的上下滚动
                        if touchX == nil {
                            let dx = abs(value.translation.width)
                            let dy = abs(value.translation.height)
                            guard dx > dy + 2 else { return }
                        }
                        touchX = value.location.x
                    }
                    .onEnded { _ in touchX = nil }
            )
        }
        .frame(height: height)
    }

    /// 找离手指最近的数据点
    private func nearestIndex(_ x: CGFloat, in pts: [CGPoint]) -> Int? {
        guard !pts.isEmpty else { return nil }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, p) in pts.enumerated() {
            let d = abs(p.x - x)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /// 把体重数据映射成画布坐标（x 按真实日期比例，缺记录的日子留空而不是压缩）
    private func normalizedPoints(_ series: [WeightRecord], in size: CGSize) -> [CGPoint] {
        guard series.count > 1 else { return [] }
        let pad: CGFloat = 16
        let w = size.width - pad * 2
        let h = size.height - pad * 2

        let days = series.compactMap { $0.dateObj }
        guard let firstDay = days.min(), let lastDay = days.max() else { return [] }
        let total = lastDay.timeIntervalSince(firstDay)

        return series.enumerated().map { idx, rec in
            let x: CGFloat
            if total > 0 {
                let ratio = (rec.dateObj ?? firstDay).timeIntervalSince(firstDay) / total
                x = pad + CGFloat(ratio) * w
            } else {
                // 都是同一天：退化为等距
                x = pad + CGFloat(idx) * w / CGFloat(max(1, series.count - 1))
            }
            let y = pad + CGFloat(1 - (rec.kg - minKg) / range) * h
            return CGPoint(x: x, y: y)
        }
    }

    private func yPosition(for kg: Double, in size: CGSize) -> CGFloat {
        let pad: CGFloat = 16
        let h = size.height - pad * 2
        return pad + CGFloat(1 - (kg - minKg) / range) * h
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

    /// 图表时间跨度
    private enum Span: String, CaseIterable, Identifiable {
        case week = "7 天"
        case month = "30 天"
        case quarter = "90 天"
        case all = "全部"

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .all: return nil
            }
        }
    }

    @State private var span: Span = .all

    private var ascending: [WeightRecord] { state.sortedAsc }

    /// 区间内记录（严格按日期过滤）
    private var ranged: [WeightRecord] {
        guard let days = span.days else { return ascending }
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        let key = WeightRecord.dateFormatter.string(from: cutoff)
        return ascending.filter { $0.date >= key }
    }

    /// 区间内一条记录都没有时（比如停了几天），退回全部，别给空图
    private var displayWeights: [WeightRecord] {
        ranged.isEmpty ? ascending : ranged
    }

    private var showingFallback: Bool {
        span.days != nil && ranged.isEmpty && !ascending.isEmpty
    }

    private var stats: (min: Double, max: Double, avg: Double, change: Double) {
        let kgs = displayWeights.map { $0.kg }
        let minV = kgs.min() ?? 0
        let maxV = kgs.max() ?? 0
        let avg = kgs.isEmpty ? 0 : kgs.reduce(0, +) / Double(kgs.count)
        let change = (kgs.last ?? 0) - (kgs.first ?? 0)
        return (minV, maxV, avg, change)
    }

    private var forecast: TrendAnalysis.Forecast? {
        TrendAnalysis.forecast(ascending, targetKg: state.user?.target_kg)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 统计卡片
                    HStack(spacing: 0) {
                        statItem("区间", String(format: "%.1f–%.1f", stats.min, stats.max))
                        statItem("平均", String(format: "%.1f", stats.avg))
                        statItem("变化", String(format: "%+.1f", stats.change),
                                 color: stats.change < 0 ? Theme.success : (stats.change > 0 ? Theme.danger : .primary))
                    }
                    .padding(.vertical, 8)

                    // 时间跨度
                    HStack(spacing: 8) {
                        ForEach(Span.allCases) { s in
                            Button {
                                Haptics.tap()
                                span = s
                            } label: {
                                Text(s.rawValue)
                                    .font(.caption.bold())
                                    .foregroundColor(span == s ? .white : Theme.inkSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(span == s ? Theme.solid : Theme.fill)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)

                    if showingFallback {
                        Text("\(span.rawValue)内还没有记录，下面显示全部数据")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                    }

                    // 大图
                    TrendChartView(weights: displayWeights,
                                   height: 260,
                                   showDetail: true,
                                   targetKg: state.user?.target_kg,
                                   showAverage: true,
                                   interactive: true)
                        .padding(.horizontal, 8)

                    Text("在图表上左右滑动可查看某天的具体数值 · 横轴按真实日期间距排列")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)

                    // 图例
                    HStack(spacing: 14) {
                        legendItem("实际", color: Theme.brandDeep, dashed: false)
                        legendItem("7 日均线", color: Theme.brandBlue.opacity(0.7), dashed: true)
                        if state.user?.target_kg != nil {
                            legendItem("目标", color: Theme.warning, dashed: true)
                        }
                    }
                    .padding(.horizontal, 8)

                    // 预测
                    if let f = forecast {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(forecastText(f))
                                .font(.subheadline)
                            Text("按最近 3 周趋势估算（\(TrendAnalysis.confidenceText(f.confidence))），仅供参考")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 8)
                    }

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

    private func forecastText(_ f: TrendAnalysis.Forecast) -> String {
        guard let d = f.daysToTarget else {
            return String(format: "最近趋势为每周 %+.1f kg，暂时看不出达标时间", f.weeklyChangeKg)
        }
        if d == 0 { return "已经达到目标体重" }
        guard let date = f.targetDate else { return "预计 \(d) 天后达到目标" }
        return String(format: "按最近趋势（每周 %+.1f kg），预计 %@ 达到目标", f.weeklyChangeKg, TrendAnalysis.shortDate(date))
    }

    private func legendItem(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 14, height: dashed ? 1.5 : 2.5)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
    }

    private func statItem(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(color)
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
