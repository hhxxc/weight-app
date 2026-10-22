import SwiftUI

/// 体重列表 + 概览 + 趋势（核心页面）
struct WeightListView: View {
    @EnvironmentObject var state: AppState
    @State private var showAdd = false
    @State private var showTrend = false

    private var sortedWeights: [WeightRecord] {
        state.weights.sorted { $0.date > $1.date }
    }

    private var latest: WeightRecord? { sortedWeights.first }

    var body: some View {
        NavigationView {
            Group {
                if state.isLoading && state.weights.isEmpty {
                    ProgressView("加载中…")
                } else if state.weights.isEmpty {
                    emptyView
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) {
                WeightEditView()
            }
            .sheet(isPresented: $showTrend) {
                TrendView()
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "scalemass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("还没有体重记录")
                .font(.headline)
            Text("点击右上角 + 记录第一条，或从 Excel 导入历史数据")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("记录体重") { showAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var list: some View {
        List {
            // 渐变大卡片（全宽，无分组边距）
            Section {
                OverviewCard(latest: latest, weights: state.weights, user: state.user)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // 趋势图（内嵌小图）
            if state.weights.count >= 2 {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("体重趋势").font(.headline)
                            Spacer()
                            Text("\(String(format: "%.1f", sortedWeights.last!.kg)) → \(String(format: "%.1f", sortedWeights.first!.kg))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        TrendChartView(weights: sortedWeights.reversed(), height: 150, showDetail: false)
                    }
                    .padding(.vertical, 4)
                }
            }

            // 历史记录
            Section("历史记录（\(state.weights.count) 条）") {
                ForEach(sortedWeights) { w in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.chineseDate).font(.subheadline)
                            if !w.note.isEmpty {
                                Text(w.note).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.1f kg", w.kg)).font(.headline)
                        if let bmi = w.bmi(heightCm: state.user?.height_cm) {
                            Text(String(format: "BMI %.1f", bmi))
                                .font(.caption).foregroundColor(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete(perform: deleteItems)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await state.refreshWeights() }
    }

    private func deleteWeight(_ w: WeightRecord) {
        Task {
            try? await APIClient.shared.deleteWeight(date: w.date)
            await state.refreshWeights()
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let items = offsets.map { sortedWeights[$0] }
        Task {
            for w in items {
                try? await APIClient.shared.deleteWeight(date: w.date)
            }
            await state.refreshWeights()
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

    private var lostKg: Double {
        guard let first = weights.min(by: { $0.date < $1.date }), let l = latest else { return 0 }
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
                miniStat("起始", weights.min(by: { $0.date < $1.date })?.kg)
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
