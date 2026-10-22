import SwiftUI

/// 分析页：体重/卡路里/营养汇总 + 趋势图 + AI 建议
struct StatsView: View {
    @EnvironmentObject var state: AppState
    @State private var stats: APIClient.StatsResponse?
    @State private var advice: String?
    @State private var loadingAdvice = false
    @State private var error: String?
    @State private var lastLoadAt: Date?

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
                    macroBar("碳水", s.nutrition.avg7_carbs_g, Theme.brandCyan)
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
            .listRowBackground(Color(hex: "EEF2FF"))
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
            }
        } catch let err {
            await MainActor.run { error = err.localizedDescription }
        }
    }

    // MARK: - 模块标题 + 总览

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.brandDeep)
            .textCase(nil)
    }

    private func overviewCard(_ s: APIClient.StatsResponse) -> some View {
        let w = s.weight
        return VStack(alignment: .leading, spacing: 0) {
            Text("累计已减")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", w.lost_kg ?? 0))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("kg")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if let bmi = w.bmi, !(w.bmi_category ?? "").isEmpty {
                    Theme.pill("BMI \(String(format: "%.1f", bmi)) · \(w.bmi_category ?? "")")
                }
            }
            .padding(.top, 4)

            HStack(spacing: 0) {
                miniStat("起始", w.start_kg)
                miniStat("当前", w.current_kg)
                miniStat("目标", w.target_kg)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func miniStat(_ title: String, _ v: Double?) -> some View {
        VStack(spacing: 3) {
            Text(v == nil ? "—" : String(format: "%.1f", v!))
                .font(.title3.bold())
                .foregroundColor(.white)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    private func calorieStat(_ title: String, _ v: Double) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(v.rounded()))").font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundColor(.secondary)
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

    private func macroBar(_ name: String, _ v: Double, _ color: Color) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(Int(v.rounded()))g").font(.headline).monospacedDigit()
            }
            Text(name).font(.caption).foregroundColor(.secondary)
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
                        p.kcal > 0
                            ? LinearGradient(
                                gradient: Gradient(colors: [Theme.brandCyan, Theme.brandBlue]),
                                startPoint: .top, endPoint: .bottom)
                            : LinearGradient(
                                gradient: Gradient(colors: [Color.gray.opacity(0.15), Color.gray.opacity(0.15)]),
                                startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: p.kcal > 0 ? max(2, CGFloat(p.kcal / maxKcal) * (height - 16)) : 2)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}
