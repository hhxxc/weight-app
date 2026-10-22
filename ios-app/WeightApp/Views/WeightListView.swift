import SwiftUI

/// 体重列表 + 概览 + 预测 + 趋势（核心页面）
struct WeightListView: View {
    @EnvironmentObject var state: AppState
    @State private var showAdd = false
    @State private var showTrend = false
    @State private var pendingDelete: [WeightRecord] = []
    @State private var showDeleteConfirm = false
    @State private var visibleMonthCount = 3
    @State private var showQuickFrequent = false
    @State private var showQuickAdd = false

    private var latest: WeightRecord? { state.sortedDesc.first }

    /// 历史记录按月分组（月份倒序），便于回看阶段性变化
    private struct MonthGroup: Identifiable {
        let id: String
        let title: String
        let items: [WeightRecord]
        let average: Double
    }

    private var monthGroups: [MonthGroup] {
        let grouped = Dictionary(grouping: state.sortedDesc) { String($0.date.prefix(7)) }
        return grouped.keys.sorted(by: >).map { key in
            let items = grouped[key] ?? []
            let avg = items.isEmpty ? 0 : items.reduce(0.0) { $0 + $1.kg } / Double(items.count)
            let parts = key.split(separator: "-")
            var title = key
            if parts.count == 2, let m = Int(parts[1]) {
                title = "\(parts[0])年\(m)月"
            }
            return MonthGroup(id: key, title: title, items: items, average: avg)
        }
    }

    private var forecast: TrendAnalysis.Forecast? {
        TrendAnalysis.forecast(state.weights, targetKg: state.user?.target_kg)
    }

    var body: some View {
        NavigationView {
            Group {
                if state.isLoading && state.weights.isEmpty {
                    skeleton
                } else if state.weights.isEmpty {
                    if let err = state.errorMessage {
                        errorView(err)
                    } else {
                        emptyView
                    }
                } else {
                    list
                }
            }
            .navigationTitle("体重")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showTrend = true } label: { Image(systemName: "chart.line.uptrend.xyaxis") }
                        .disabled(state.weights.count < 2)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptics.tap()
                    showAdd = true
                } label: {
                    Label("记录体重", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Theme.brandGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .sheet(isPresented: $showAdd) {
                WeightEditView()
            }
            .sheet(isPresented: $showTrend) {
                TrendView()
            }
            .sheet(isPresented: $showQuickFrequent) {
                FrequentMealsView(dateStr: WeightRecord.dateFormatter.string(from: Date()))
            }
            .sheet(isPresented: $showQuickAdd) {
                MealEditView(dateStr: WeightRecord.dateFormatter.string(from: Date()))
            }
            .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) { pendingDelete = [] }
            } message: {
                Text("删除后不可恢复，需要时可重新记录。")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 加载骨架

    private var skeleton: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(height: 190)
                .overlay(
                    VStack(alignment: .leading, spacing: 10) {
                        Text("正在同步最新记录…")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                        Text("--")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.65))
                    }
                    .padding(22),
                    alignment: .leading
                )
            ForEach(0..<3) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .frame(height: 54)
            }
            Spacer()
        }
        .padding(16)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("连不上服务器")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") {
                Task { await state.bootstrap() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 96, height: 96)
                    .opacity(0.15)
                Image(systemName: "scalemass")
                    .font(.system(size: 42))
                    .foregroundColor(Theme.brandDeep)
            }
            Text("还没有体重记录")
                .font(.headline)
            Text("点下方「记录体重」记第一条，或到「我的」从 Excel 导入历史数据")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding()
    }

    // MARK: - 主列表

    private var list: some View {
        List {
            // 渐变大卡片（全宽，无分组边距）
            Section {
                OverviewCard(latest: latest, weights: state.weights, user: state.user)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // 今日饮食预算（一眼知道还能吃多少）
            Section {
                todayMealCard
            }

            // 进度预测（有目标体重且记录足够时才出现）
            if let f = forecast {
                Section {
                    forecastCard(f)
                }
            }

            // 趋势图（内嵌小图）
            if state.weights.count >= 2 {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("体重趋势").font(.headline)
                            Spacer()
                            Text("\(String(format: "%.1f", state.sortedAsc.first?.kg ?? 0)) → \(String(format: "%.1f", state.sortedAsc.last?.kg ?? 0))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        TrendChartView(weights: state.sortedAsc,
                                       height: 150,
                                       showDetail: false,
                                       targetKg: state.user?.target_kg,
                                       showAverage: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            // 历史记录：按月分组，每月一行摘要
            ForEach(Array(monthGroups.prefix(visibleMonthCount))) { g in
                Section {
                    ForEach(g.items) { w in
                        historyRow(w)
                    }
                    .onDelete { offsets in
                        requestDelete(offsets.map { g.items[$0] })
                    }
                } header: {
                    HStack {
                        Text(g.title)
                        Spacer()
                        Text(String(format: "%d 条 · 均 %.1f kg", g.items.count, g.average))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .textCase(nil)
                }
            }

            if monthGroups.count > visibleMonthCount {
                Section {
                    Button {
                        Haptics.tap()
                        withAnimation { visibleMonthCount += 6 }
                    } label: {
                        HStack {
                            Text("显示更早的 \(monthGroups.count - visibleMonthCount) 个月")
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .foregroundColor(Theme.brandDeep)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await state.refreshWeights() }
    }

    private func historyRow(_ w: WeightRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.chineseDate).font(.subheadline)
                if !w.note.isEmpty {
                    Text(w.note).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(String(format: "%.1f kg", w.kg)).font(.headline).monospacedDigit()
            if let bmi = w.bmi(heightCm: state.user?.height_cm) {
                Text(String(format: "BMI %.1f", bmi))
                    .font(.caption).foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 今日饮食

    private var todayMealCard: some View {
        let target = state.user?.kcalTarget(currentKg: state.sortedDesc.first?.kg)
        let kcal = state.todayKcal

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(.caption)
                    .foregroundColor(Theme.brandDeep)
                Text("今日饮食")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.brandDeep)
                if state.todayKcalLoaded {
                    Text("\(state.todayMealCount) 条")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        Haptics.tap()
                        showQuickFrequent = true
                    } label: {
                        Label("常吃食物", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        Haptics.tap()
                        showQuickAdd = true
                    } label: {
                        Label("手动记录", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("记一笔", systemImage: "plus.circle.fill")
                        .font(.caption.bold())
                        .foregroundColor(Theme.brandDeep)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.brandBlue.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if !state.todayKcalLoaded {
                Text("正在读取今日记录…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if let t = target, t > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(kcal.rounded()))")
                        .font(.title3.bold())
                        .monospacedDigit()
                    Text("/ \(Int(t)) 千卡")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(kcal > t ? "超出 \(Int((kcal - t).rounded()))" : "还剩 \(Int((t - kcal).rounded()))")
                        .font(.caption.bold())
                        .foregroundColor(kcal > t ? Theme.danger : Theme.success)
                }
                ProgressView(value: min(1, max(0, kcal / t)))
                    .tint(kcal > t ? Theme.danger : Theme.brandBlue)
            } else {
                Text("还没设置每日热量目标，去「我的 → 个人资料」填一个吧")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 预测卡片

    private func forecastCard(_ f: TrendAnalysis.Forecast) -> some View {
        let streakDays = TrendAnalysis.streak(state.weights)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("进度预测", systemImage: "chart.line.flatten")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.brandDeep)
                Spacer()
                Text(TrendAnalysis.confidenceText(f.confidence))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 0) {
                metric("周均变化", String(format: "%+.1f kg", f.weeklyChangeKg),
                       color: f.weeklyChangeKg < 0 ? Theme.success : (f.weeklyChangeKg > 0 ? Theme.danger : .primary))
                metric("预计达标", TrendAnalysis.targetText(f), color: .primary)
                metric("还差", f.remainingKg.map { String(format: "%.1f kg", max(0, $0)) } ?? "—", color: .primary)
            }

            if let p = TrendAnalysis.progress(state.weights, targetKg: state.user?.target_kg) {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: p)
                        .tint(Theme.brandDeep)
                    Text(p >= 1 ? "目标已达成，继续保持" : "已完成 \(Int((p * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // 连续记录天数
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .foregroundColor(streakDays >= 7 ? Theme.warning : .secondary)
                Text(streakDays > 0 ? "连续记录 \(streakDays) 天" : "今天还没记录，记一笔开始连续")
                    .foregroundColor(.secondary)
                if streakDays >= 7 {
                    Text("· 保持住")
                        .foregroundColor(Theme.warning)
                }
            }
            .font(.caption2)

            // 数据太旧时提醒：预测会随后续记录变化
            if let lastDate = latest?.dateObj,
               let days = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day,
               days > 7 {
                Label("上次称重已是 \(days) 天前，预测会随新记录更新", systemImage: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 删除

    private var deleteTitle: String {
        if pendingDelete.count == 1, let d = pendingDelete.first {
            return "删除 \(d.chineseDate) 的记录？"
        }
        return "删除这 \(pendingDelete.count) 条记录？"
    }

    private func requestDelete(_ items: [WeightRecord]) {
        guard !items.isEmpty else { return }
        pendingDelete = items
        showDeleteConfirm = true
    }

    private func performDelete() {
        let items = pendingDelete
        pendingDelete = []
        guard !items.isEmpty else { return }
        Haptics.tap()
        Task {
            // 本地先移除，界面即时响应；失败再回滚
            state.removeLocalWeights(dates: items.map { $0.date })
            var failed = 0
            for w in items {
                do {
                    try await APIClient.shared.deleteWeight(date: w.date)
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                await state.refreshWeights()
                state.showToast("有 \(failed) 条删除失败，已恢复")
                await MainActor.run { Haptics.error() }
            } else {
                await MainActor.run { Haptics.success() }
            }
        }
    }
}

/// 概览卡片：最新体重、BMI、目标进度（蓝青渐变品牌卡）
struct OverviewCard: View {
    let latest: WeightRecord?
    let weights: [WeightRecord]
    let user: UserProfile?

    private var currentBmi: Double? {
        guard let l = latest, let h = user?.height_cm else { return nil }
        return BMI.value(kg: l.kg, heightCm: h)
    }

    private var startRecord: WeightRecord? {
        weights.min(by: { $0.date < $1.date })
    }

    private var lostKg: Double {
        guard let first = startRecord, let l = latest else { return 0 }
        return first.kg - l.kg
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标签行
            HStack {
                Text(latest?.chineseDate ?? "当前体重")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if let bmi = currentBmi {
                    Theme.pill("BMI \(String(format: "%.1f", bmi)) · \(BMI.level(bmi).rawValue)")
                }
            }

            // 大号体重
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(latest.map { String(format: "%.1f", $0.kg) } ?? "--")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text("kg")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
            }
            .padding(.top, 4)

            // 已减标签
            if lostKg > 0.05 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                    Text("已减 \(String(format: "%.1f", lostKg)) kg")
                        .font(.subheadline.bold())
                }
                .foregroundColor(.white)
                .padding(.top, 8)
            }

            // 底部三格：起始 / 目标 / 已减
            HStack(spacing: 0) {
                miniStat("起始", startRecord?.kg)
                miniStat("目标", user?.target_kg)
                miniStat("已减", lostKg, signed: true)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func miniStat(_ title: String, _ v: Double?, signed: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(v == nil ? "—" : String(format: signed ? "%+.1f" : "%.1f", v!))
                .font(.title3.bold())
                .foregroundColor(.white)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }
}
