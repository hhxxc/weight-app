import SwiftUI

/// 分析页：体重/卡路里/营养汇总 + 趋势图 + AI 建议
struct StatsView: View {
    @State private var stats: APIClient.StatsResponse?
    @State private var advice: String?
    @State private var loadingAdvice = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    if let s = stats {
                        // 总览（渐变卡）
                        overviewCard(s)

                        // 体重模块
                        sectionHeader("体重", icon: "scalemass.fill")
                        weightCard(s)

                        // 卡路里模块
                        sectionHeader("卡路里", icon: "flame.fill")
                        calorieCard(s)

                        // 营养模块
                        sectionHeader("营养 · 近7天日均", icon: "leaf.fill")
                        nutritionCard(s)

                        // 趋势模块
                        sectionHeader("趋势", icon: "chart.line.uptrend.xyaxis")
                        weightTrendCard(s)
                        calorieTrendCard(s)

                        // AI 建议模块
                        sectionHeader("AI 建议", icon: "sparkles")
                        adviceCard
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
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("分析")
            .task { await load() }
            .refreshable { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        do {
            let s = try await APIClient.shared.fetchStats()
            await MainActor.run { stats = s; error = nil }
        } catch let err {
            await MainActor.run { error = err.localizedDescription }
        }
    }

    // MARK: - 模块标题 + 总览

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(Theme.brandBlue)
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.top, 4)
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

    // MARK: - 体重汇总卡片

    private func weightCard(_ s: APIClient.StatsResponse) -> some View {
        let w = s.weight
        return VStack(alignment: .leading, spacing: 10) {
            if w.record_count < 3 {
                Text("记录还很少（\(w.record_count) 条），坚持每天称重才能看到趋势")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("已记录 \(w.record_count) 条体重")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(cardBg)
        .cardShadow()
    }

    // MARK: - 卡路里卡片

    private func calorieCard(_ s: APIClient.StatsResponse) -> some View {
        let c = s.calories
        return HStack(spacing: 0) {
            calorieStat("今日", c.today_kcal)
            calorieStat("近7天日均", c.avg7_kcal)
            calorieStat("近30天日均", c.avg30_kcal)
        }
        .padding(16)
        .background(cardBg)
        .cardShadow()
    }

    private func calorieStat(_ title: String, _ v: Double) -> some View {
        VStack(spacing: 4) {
            Text("\(Int(v.rounded()))").font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 营养卡片

    private func nutritionCard(_ s: APIClient.StatsResponse) -> some View {
        let n = s.nutrition
        return HStack(spacing: 12) {
            macroBar("蛋白质", n.avg7_protein_g, Theme.brandBlue)
            macroBar("脂肪", n.avg7_fat_g, Theme.warning)
            macroBar("碳水", n.avg7_carbs_g, Theme.brandCyan)
        }
        .padding(16)
        .background(cardBg)
        .cardShadow()
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

    // MARK: - 体重趋势

    private func weightTrendCard(_ s: APIClient.StatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("体重变化").font(.subheadline.bold()).foregroundColor(.secondary)
            if weightTrend(s).count > 1 {
                TrendChartView(weights: weightTrend(s), height: 180, showDetail: false)
            } else {
                Text("至少 2 条体重记录才有趋势").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding(16)
        .background(cardBg)
        .cardShadow()
    }

    private func weightTrend(_ s: APIClient.StatsResponse) -> [WeightRecord] {
        s.daily.compactMap { p in
            p.kg.map { WeightRecord(id: 0, date: p.date, kg: $0, note: "") }
        }
    }

    // MARK: - 卡路里趋势（柱状）

    private func calorieTrendCard(_ s: APIClient.StatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日卡路里").font(.subheadline.bold()).foregroundColor(.secondary)
            let pts = Array(s.daily.suffix(30))
            if pts.contains(where: { $0.kcal > 0 }) {
                KcalBarChart(points: pts, height: 140)
            } else {
                Text("暂无饮食卡路里记录").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding(16)
        .background(cardBg)
        .cardShadow()
    }

    // MARK: - AI 建议

    @ViewBuilder
    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 建议", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundColor(Theme.brandDeep)
                Spacer()
                Button(action: generateAdvice) {
                    if loadingAdvice {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text(advice == nil ? "生成" : "刷新")
                            .font(.caption.bold())
                            .foregroundColor(Theme.brandBlue)
                    }
                }
                .disabled(loadingAdvice)
            }
            if let advice, !advice.isEmpty {
                Text(advice)
                    .font(.subheadline)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("点右上角「生成」，基于你的体重和饮食数据给出个性化建议")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color(hex: "EEF2FF"), Color(hex: "E0F7FA")]),
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(hex: "DBEAFE"), lineWidth: 1)
        )
    }

    private func generateAdvice() {
        loadingAdvice = true
        Task {
            defer { loadingAdvice = false }
            do {
                let a = try await APIClient.shared.fetchAdvice()
                await MainActor.run { advice = a }
            } catch let err {
                await MainActor.run { advice = "生成失败：\(err.localizedDescription)" }
            }
        }
    }

    private var cardBg: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(UIColor.systemBackground))
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
