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
                    Label("记录体重", systemImage: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Theme.brandGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .buttonStyle(PressableStyle())
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
                .fill(Theme.card)
                .frame(height: 190)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
                .overlay(
                    VStack(alignment: .leading, spacing: 10) {
                        Text("正在同步最新记录…")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.inkTertiary)
                        Text("--")
                            .font(.system(size: 46, weight: .medium))
                            .foregroundColor(Theme.ink.opacity(0.25))
                    }
                    .padding(20),
                    alignment: .leading
                )
            ForEach(0..<3) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.fill)
                    .frame(height: 54)
            }
            Spacer()
        }
        .padding(16)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.inkTertiary)
            Text("连不上服务器")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.inkSecondary)
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
        VStack(spacing: 14) {
            Image(systemName: "scalemass")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.inkTertiary)
            Text("还没有体重记录")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.ink)
            Text("记下第一笔，之后就能看到趋势、预测和每周小结；\n也可以在「我的」里从 Excel 导入历史数据")
                .font(.system(size: 13))
                .foregroundColor(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主列表

    private var list: some View {
        List {
            // 达成目标：放在最上面先庆祝一下
            if reachedTarget {
                Section { celebrationCard }
            }

            // 英雄卡：体重 + 进度环 + 迷你趋势（一屏抓重点）
            Section {
                OverviewCard(latest: latest, weights: state.weights, user: state.user, forecast: forecast)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            // 今日摄入 + 三项统计
            Section {
                todayMealCard
                statsRow
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

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
                    HStack(alignment: .firstTextBaseline) {
                        Text(g.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.inkSecondary)
                        Spacer()
                        Text(String(format: "%d 条 · 均 %.1f", g.items.count, g.average))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.inkTertiary)
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
        .listRowSeparatorTint(Theme.hairline)
        .background(Theme.canvas.ignoresSafeArea())
        .refreshable { await state.refreshWeights() }
    }

    private func historyRow(_ w: WeightRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.chineseDate)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.ink)
                if !w.note.isEmpty {
                    Text(w.note)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", w.kg))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()
                Text("kg")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkTertiary)
            }
            if let bmi = w.bmi(heightCm: state.user?.height_cm) {
                Text(String(format: "%.1f", bmi))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkTertiary)
                    .frame(width: 30, alignment: .trailing)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 空状态 / 目标达成

    private var reachedTarget: Bool {
        guard let t = state.user?.target_kg, t > 0, let cur = latest?.kg else { return false }
        return cur <= t
    }

    private var celebrationCard: some View {
        HStack(spacing: 12) {
            Text("🎉").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("目标达成")
                    .font(.subheadline.bold())
                    .foregroundColor(Theme.brandDeep)
                Text(String(format: "已经到 %.1f kg 了，接下来保持住就好", latest?.kg ?? 0))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.brandBlue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 今日饮食

    private var todayMealCard: some View {
        let target = state.user?.kcalTarget(currentKg: state.sortedDesc.first?.kg)
        let kcal = state.todayKcal

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("今日摄入")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.ink)
                if state.todayKcalLoaded {
                    Text("\(state.todayMealCount) 条")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkTertiary)
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
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("记一笔")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Theme.brandDeep)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Theme.fill)
                    .clipShape(Capsule())
                }
            }

            if !state.todayKcalLoaded {
                Text("正在读取今日记录…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.inkTertiary)
            } else if let t = target, t > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(kcal.rounded()))")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(Theme.ink)
                        .monospacedDigit()
                    Text("/ \(Int(t)) 千卡")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkTertiary)
                    Spacer()
                    Text(kcal > t ? "超出 \(Int((kcal - t).rounded()))" : "还剩 \(Int((t - kcal).rounded()))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(kcal > t ? Theme.warning : Theme.success)
                        .monospacedDigit()
                }
                ProgressView(value: min(1, max(0, kcal / t)))
                    .tint(kcal > t ? Theme.warning : Theme.brandDeep)
            } else {
                Text("还没设置每日热量目标，去「我的 → 个人资料」填一个吧")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.inkTertiary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card)
        )
        .cardShadow()
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    // MARK: - 三项统计

    private var statsRow: some View {
        let monthKg = monthChangeKg
        return HStack(spacing: 0) {
            statsItem("连续", "\(streakDays)", "天")
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 26)
            statsItem("本月已减", monthKg.map { String(format: "%.1f", $0) } ?? "—", "kg")
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 26)
            statsItem("本月记录", "\(monthRecordDays)", "天")
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card)
        )
        .cardShadow()
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func statsItem(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.inkTertiary)
            }
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 本月变化（本月均值 − 上月均值，均值不存在时用首尾差）
    private var monthChangeKg: Double? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        let thisKey = fmt.string(from: Date())
        let lastKey = {
            let d = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            return fmt.string(from: d)
        }()
        let thisVals = state.weights.filter { $0.date.hasPrefix(thisKey) }.map { $0.kg }
        let lastVals = state.weights.filter { $0.date.hasPrefix(lastKey) }.map { $0.kg }
        guard !thisVals.isEmpty, !lastVals.isEmpty else { return nil }
        return (thisVals.reduce(0, +) / Double(thisVals.count))
            - (lastVals.reduce(0, +) / Double(lastVals.count))
    }

    /// 本月记录天数
    private var monthRecordDays: Int {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        let key = fmt.string(from: Date())
        return state.weights.filter { $0.date.hasPrefix(key) }.count
    }

    /// 连续记录天数（从今天或昨天往回数）
    private var streakDays: Int {
        let fmt = WeightRecord.dateFormatter
        let dates = Set(state.weights.map { $0.date })
        guard !dates.isEmpty else { return 0 }
        var day = Calendar.current.startOfDay(for: Date())
        if !dates.contains(fmt.string(from: day)) {
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: day),
                  dates.contains(fmt.string(from: prev)) else { return 0 }
            day = prev
        }
        var count = 0
        while dates.contains(fmt.string(from: day)) {
            count += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
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

/// 英雄卡：大号体重 + 进度环 + 迷你趋势（暖色极简）
struct OverviewCard: View {
    let latest: WeightRecord?
    let weights: [WeightRecord]
    let user: UserProfile?
    var forecast: TrendAnalysis.Forecast? = nil

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

    /// 减重进度 0...1（已减 / 需减）
    private var progress: Double {
        guard let start = startRecord?.kg, let target = user?.target_kg, start > target else { return 0 }
        return max(0, min(1, lostKg / (start - target)))
    }

    private var remainingKg: Double? {
        guard let target = user?.target_kg, let cur = latest?.kg else { return nil }
        return cur - target
    }

    /// 最近几次体重（迷你柱状图用）
    private var last7: [Double] {
        Array(weights.suffix(7).map { $0.kg })
    }

    private var barsDateRange: (String, String)? {
        let recent = Array(weights.suffix(7))
        guard recent.count >= 2 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        func short(_ s: String) -> String {
            (WeightRecord.dateFormatter.date(from: s)).map { f.string(from: $0) } ?? s
        }
        return (short(recent.first!.date), short(recent.last!.date))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：日期 + BMI 胶囊
            HStack {
                Text(latest?.chineseDate ?? "还没有记录")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkTertiary)
                Spacer()
                if let bmi = currentBmi {
                    Text("BMI \(String(format: "%.1f", bmi))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.fill)
                        .clipShape(Capsule())
                }
            }

            // 大数字 + 进度环
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(latest.map { String(format: "%.1f", $0.kg) } ?? "--")
                            .font(.system(size: 52, weight: .medium))
                            .tracking(-1.2)
                            .foregroundColor(Theme.ink)
                            .monospacedDigit()
                        Text("kg")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.inkTertiary)
                    }
                    if let d = deltaFromLast {
                        HStack(spacing: 5) {
                            Image(systemName: d <= 0 ? "arrow.down.right" : "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                            Text(String(format: "%.1f kg", abs(d)))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(d <= 0 ? Theme.success : Theme.warning)
                    }
                    if let rem = remainingKg {
                        Text(rem > 0 ? String(format: "距目标 %.1f kg", rem) : "已达成目标")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.inkTertiary)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 8)
                ProgressRing(progress: progress)
            }
            .padding(.top, 12)

            // 迷你趋势（最近几次）
            if !last7.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .padding(.vertical, 14)

                MiniBars(values: last7)

                if let r = barsDateRange {
                    HStack {
                        Text(r.0)
                        Spacer()
                        Text("近 \(last7.count) 次")
                        Spacer()
                        Text(r.1)
                    }
                    .font(.system(size: 9))
                    .foregroundColor(Theme.inkTertiary)
                    .padding(.top, 6)
                }
            }

            // 预计达标（一行小字）
            if let f = forecast, let date = f.targetDate {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    Text("按当前速度，预计 \(dateString(date)) 达标")
                        .font(.system(size: 11))
                }
                .foregroundColor(Theme.brandDeep)
                .padding(.top, 12)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.card)
        )
        .cardShadow()
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 与上一条记录的差值（同一天覆盖后仍能反映最近两天变化）
    private var deltaFromLast: Double? {
        let sorted = weights.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return nil }
        return sorted[sorted.count - 1].kg - sorted[sorted.count - 2].kg
    }

    private func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}
