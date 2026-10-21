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
            // 概览卡片
            Section {
                OverviewCard(latest: latest, weights: state.weights, user: state.user)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // 趋势图（内嵌小图）
            if state.weights.count >= 2 {
                Section {
                    TrendChartView(weights: sortedWeights.reversed(), height: 160, showDetail: false)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }

            // 历史记录
            Section("历史记录（\(state.weights.count) 条）") {
                ForEach(sortedWeights) { w in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.date)
                                .font(.subheadline)
                            if !w.note.isEmpty {
                                Text(w.note)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.1f kg", w.kg))
                            .font(.headline)
                        if let bmi = w.bmi(heightCm: state.user?.height_cm) {
                            Text(String(format: "BMI %.1f", bmi))
                                .font(.caption)
                                .foregroundColor(.secondary)
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

/// 概览卡片：最新体重、BMI、目标进度
struct OverviewCard: View {
    let latest: WeightRecord?
    let weights: [WeightRecord]
    let user: UserProfile?

    private var currentBmi: Double? {
        guard let l = latest, let h = user?.height_cm else { return nil }
        return BMI.value(kg: l.kg, heightCm: h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("最新体重")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if let l = latest {
                    Text(l.date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(latest.map { String(format: "%.1f", $0.kg) } ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("kg")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }

            if let bmi = currentBmi {
                let level = BMI.level(bmi)
                HStack(spacing: 8) {
                    Text("BMI")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f", bmi))
                        .font(.title3.bold())
                    Text(level.rawValue)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: level.colorHex))
                        .cornerRadius(10)
                }
            } else if user?.height_cm == nil {
                Text("在「我的」里填身高后自动计算 BMI")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 目标进度
            if let target = user?.target_kg, let l = latest {
                let diff = l.kg - target
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("目标 \(String(format: "%.1f", target)) kg")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if abs(diff) < 0.05 {
                            Text("已达标 🎉").font(.caption.bold()).foregroundColor(.green)
                        } else if diff > 0 {
                            Text("还需减 \(String(format: "%.1f", diff)) kg").font(.caption).foregroundColor(.orange)
                        } else {
                            Text("已低于目标 \(String(format: "%.1f", -diff)) kg").font(.caption).foregroundColor(.blue)
                        }
                    }
                    if diff > 0 {
                        ProgressView(value: target, total: l.kg)
                            .tint(.orange)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.08))
        )
    }
}
