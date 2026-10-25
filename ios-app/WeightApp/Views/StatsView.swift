import SwiftUI

/// 分析页：体重/卡路里/营养汇总 + 趋势图 + AI 建议
struct StatsView: View {
    @EnvironmentObject var state: AppState
    @State private var stats: APIClient.StatsResponse? = CacheStore.load(APIClient.StatsResponse.self, "stats")
    @State private var advice: String?
    @State private var loadingAdvice = false
    @State private var error: String?
    @State private var lastLoadAt: Date?
    @State private var showReport = false

    private let adviceKey = "stats.advice.text"
    private let adviceStampKey = "stats.advice.stamp"

    private var forecast: TrendAnalysis.Forecast? {
        TrendAnalysis.forecast(state.weights, targetKg: state.user?.target_kg)
    }

    var body: some View {
        NavigationView {
            Group {
                if let s = stats {
                    statsList(s)
                } else if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 40)).foregroundColor(.secondary)
                        Text(error).font(.footnote).foregroundColor(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    ProgressView("加载统计…").padding(.vertical, 60)
                }
            }
            .navigationTitle("分析")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Haptics.tap()
                        showReport = true
                    } label: {
                        Text("周报")
                    }
                    .disabled(stats == nil)
                }
            }
            .sheet(isPresented: $showReport) {
                if let s = stats {
                    WeeklyReportView(stats: s, weights: state.weights, user: state.user)
                }
            }
            .onAppear {
                // 每次切回分析页都刷新（5 秒内重复进入不重复请求）
                loadCachedAdvice()
                if let t = lastLoadAt, Date().timeIntervalSince(t) < 5 { return }
                Task { await load() }
            }
            .refreshable { await load() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 统计列表（List 固定导航栏 + 分组结构）

    private func statsList(_ s: APIClient.StatsResponse) -> some View {
        List {
            // 总览渐变卡（全宽）
            Section {
                overviewCard(s)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // 体重模块
            Section {
                if let f = forecast {
                    HStack(spacing: 0) {
                        let week = TrendAnalysis.weekDelta(state.weights)
                        statCell("本周变化", week.map { String(format: "%+.1f kg", $0) } ?? "—",
                                 color: trendColor(week))
                        statCell("周均速度", String(format: "%+.1f kg", f.weeklyChangeKg),
                                 color: trendColor(f.weeklyChangeKg))
                        statCell("预计达标", TrendAnalysis.targetText(f))
                    }
                }
                Text("已记录 \(s.weight.record_count) 条体重")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                sectionHeader("体重", icon: "scalemass.fill")
            }

            // 本周 vs 上周
            Section {
                let w = weekCompare(s)
                HStack(spacing: 0) {
                    statCell("本周体重", w.thisAvg.map { String(format: "%.1f", $0) } ?? "—")
                    statCell("较上周", weightDeltaText(w), color: weightDeltaColor(w))
                    statCell("日均摄入", w.thisKcal.map { "\(Int($0.rounded()))" } ?? "—")
                }
                Text(weekFootnote(w))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                sectionHeader("本周 vs 上周", icon: "calendar")
            }

            // 卡路里模块
            Section {
                HStack(spacing: 0) {
                    calorieStat("今日", s.calories.today_kcal)
                    calorieStat("近7天日均", s.calories.avg7_kcal)
                    calorieStat("近30天日均", s.calories.avg30_kcal)
                }
            } header: {
                sectionHeader("卡路里", icon: "flame.fill")
            }

            // 营养模块
            Section {
                HStack(spacing: 12) {
                    macroBar("蛋白质", s.nutrition.avg7_protein_g, Theme.brandBlue)
                    macroBar("脂肪", s.nutrition.avg7_fat_g, Theme.warning)
                    macroBar("碳水", s.nutrition.avg7_carbs_g, Theme.inkSecondary)
                }
            } header: {
                sectionHeader("营养 · 近7天日均", icon: "leaf.fill")
            }

            // 趋势：体重变化
            Section {
                if weightTrend(s).count > 1 {
                    TrendChartView(weights: weightTrend(s), height: 180, showDetail: false)
                        .padding(.vertical, 6)
                } else {
                    Text("至少 2 条体重记录才有趋势").font(.caption).foregroundColor(.secondary)
                }
            } header: {
                sectionHeader("趋势 · 体重变化", icon: "chart.line.uptrend.xyaxis")
            }

            // 趋势：每日卡路里
            Section {
                let pts = Array(s.daily.suffix(30))
                if pts.contains(where: { $0.kcal > 0 }) {
                    KcalBarChart(points: pts, height: 140)
                        .padding(.vertical, 6)
                } else {
                    Text("暂无饮食卡路里记录").font(.caption).foregroundColor(.secondary)
                }
            } header: {
                sectionHeader("趋势 · 每日卡路里", icon: "chart.bar.fill")
            }

            // AI 建议
            Section {
                adviceContent
            } header: {
                sectionHeader("AI 建议", icon: "sparkles")
            }
            .listRowBackground(Theme.adviceBackground)
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        do {
            let s = try await APIClient.shared.fetchStats()
            await MainActor.run {
                stats = s
                error = nil
                lastLoadAt = Date()
                CacheStore.save(s, "stats")
            }
        } catch let err {
            await MainActor.run { error = err.localizedDescription }
        }
    }

    // MARK: - 模块标题 + 总览

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Theme.inkTertiary)
            .textCase(nil)
    }

    private func overviewCard(_ s: APIClient.StatsResponse) -> some View {
        let w = s.weight
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("累计已减")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.inkTertiary)
                Spacer()
                if let bmi = w.bmi, !(w.bmi_category ?? "").isEmpty {
                    Text("BMI \(String(format: "%.1f", bmi)) · \(w.bmi_category ?? "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.inkSecondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%.1f", w.lost_kg ?? 0))
                    .font(.system(size: 44, weight: .medium))
                    .tracking(-0.8)
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()
                Text("kg")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.inkTertiary)
                Spacer()
            }
            .padding(.top, 6)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
                .padding(.vertical, 14)

            HStack(spacing: 0) {
                miniStat("起始", w.start_kg)
                miniStat("当前", w.current_kg)
                miniStat("目标", w.target_kg)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func miniStat(_ title: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Theme.inkTertiary)
            Text(v == nil ? "—" : String(format: "%.1f", v!))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.ink)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func calorieStat(_ title: String, _ v: Double) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(v.rounded()))")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Theme.ink)
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statCell(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 减重为绿色（向好），增重为橙色（提醒），持平为默认色
    private func trendColor(_ v: Double?) -> Color {
        guard let v = v, abs(v) >= 0.05 else { return .primary }
        return v < 0 ? Theme.success : Theme.warning
    }

    // MARK: - 本周 vs 上周

    private struct WeekCompare {
        let thisAvg: Double?
        let lastAvg: Double?
        let thisDays: Int
        let lastDays: Int
        let thisKcal: Double?
        let lastKcal: Double?
    }

    private func weekCompare(_ s: APIClient.StatsResponse) -> WeekCompare {
        let cal = Calendar.current
        let today = Date()
        func keys(_ from: Int, _ to: Int) -> Set<String> {
            var set = Set<String>()
            for i in from..<to {
                if let d = cal.date(byAdding: .day, value: -i, to: today) {
                    set.insert(WeightRecord.dateFormatter.string(from: d))
                }
            }
            return set
        }
        let thisKeys = keys(0, 7)
        let lastKeys = keys(7, 14)

        let thisW = state.weights.filter { thisKeys.contains($0.date) }
        let lastW = state.weights.filter { lastKeys.contains($0.date) }
        let thisK = s.daily.filter { thisKeys.contains($0.date) && $0.kcal > 0 }
        let lastK = s.daily.filter { lastKeys.contains($0.date) && $0.kcal > 0 }

        func avgKg(_ list: [WeightRecord]) -> Double? {
            list.isEmpty ? nil : list.reduce(0.0) { $0 + $1.kg } / Double(list.count)
        }
        func avgKcal(_ list: [APIClient.StatsResponse.DailyPoint]) -> Double? {
            list.isEmpty ? nil : list.reduce(0.0) { $0 + $1.kcal } / Double(list.count)
        }

        return WeekCompare(thisAvg: avgKg(thisW), lastAvg: avgKg(lastW),
                           thisDays: thisW.count, lastDays: lastW.count,
                           thisKcal: avgKcal(thisK), lastKcal: avgKcal(lastK))
    }

    private func weightDelta(_ w: WeekCompare) -> Double? {
        guard let a = w.thisAvg, let b = w.lastAvg else { return nil }
        return a - b
    }

    private func weightDeltaText(_ w: WeekCompare) -> String {
        guard let d = weightDelta(w) else { return "—" }
        return String(format: "%+.1f kg", d)
    }

    private func weightDeltaColor(_ w: WeekCompare) -> Color {
        guard let d = weightDelta(w) else { return .primary }
        if abs(d) < 0.05 { return .primary }
        return d < 0 ? Theme.success : Theme.warning
    }

    private func weekFootnote(_ w: WeekCompare) -> String {
        var text = "体重记录 本周 \(w.thisDays) 天 · 上周 \(w.lastDays) 天"
        if let k = w.thisKcal, let p = w.lastKcal, p > 0 {
            let delta = k - p
            text += String(format: "；日均摄入 %+.0f 千卡", delta)
        } else {
            text += "；日均摄入仅统计有饮食记录的天"
        }
        return text
    }

    private func macroBar(_ name: String, _ v: Double, _ color: Color) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(Int(v.rounded()))g")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()
            }
            Text(name).font(.system(size: 11)).foregroundColor(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func weightTrend(_ s: APIClient.StatsResponse) -> [WeightRecord] {
        s.daily.compactMap { p in
            p.kg.map { WeightRecord(id: 0, date: p.date, kg: $0, note: "") }
        }
    }

    // MARK: - AI 建议

    private var adviceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if loadingAdvice {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text(advice == nil ? "点击生成，基于你的体重和饮食数据给出个性化建议" : "")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: generateAdvice) {
                    Text(advice == nil ? "生成" : "刷新")
                        .font(.caption.bold())
                        .foregroundColor(Theme.brandBlue)
                }
                .disabled(loadingAdvice)
            }
            if let advice, !advice.isEmpty {
                Text(advice)
                    .font(.subheadline)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }

    private func generateAdvice() {
        loadingAdvice = true
        Task {
            do {
                let a = try await APIClient.shared.fetchAdvice()
                await MainActor.run {
                    advice = a
                    loadingAdvice = false
                    // 缓存 6 小时：避免每次进页面都烧一次 AI 调用
                    UserDefaults.standard.set(a, forKey: adviceKey)
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: adviceStampKey)
                }
            } catch let err {
                await MainActor.run {
                    advice = "生成失败：\(err.localizedDescription)"
                    loadingAdvice = false
                    Haptics.error()
                }
            }
        }
    }

    /// 6 小时内的建议直接复用，打开分析页即有内容
    private func loadCachedAdvice() {
        let stamp = UserDefaults.standard.double(forKey: adviceStampKey)
        guard stamp > 0, Date().timeIntervalSince1970 - stamp < 6 * 3600 else { return }
        if let cached = UserDefaults.standard.string(forKey: adviceKey), !cached.isEmpty {
            advice = cached
        }
    }
}

/// 每日卡路里柱状图（自绘，兼容 iOS 15）
struct KcalBarChart: View {
    let points: [APIClient.StatsResponse.DailyPoint]
    var height: CGFloat = 140

    var body: some View {
        let maxKcal = max(points.map { $0.kcal }.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: p.kcal > 0 ? [Theme.ink, Theme.ink] : [Theme.fill, Theme.fill]),
                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: p.kcal > 0 ? max(2, CGFloat(p.kcal / maxKcal) * (height - 16)) : 2)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}
