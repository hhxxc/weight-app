import SwiftUI

/// 常吃食物：把最近 90 天吃过的内容聚合出来，点一条按当前餐次直接记账
struct FrequentMealsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String

    @State private var items: [APIClient.FrequentMeal] = []
    @State private var loading = true
    @State private var savingContent: String?
    @State private var error: String?

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView("读取常吃食物…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("读取失败")
                            .font(.headline)
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("重试") {
                            loading = true
                            Task { await load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("还没有可复用的记录")
                            .font(.headline)
                        Text("先用拍照、语音或手动记几次，这里会自动出现你常吃的东西")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                row(item)
                            }
                        } footer: {
                            Text("按最近 90 天的出现次数排序；点一下即按当前时段自动归入餐次。")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("常吃食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func row(_ item: APIClient.FrequentMeal) -> some View {
        Button {
            record(item)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.content)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text("\(item.count) 次 · 上次 \(chineseDateString(item.last_date))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let k = item.kcal, k > 0 {
                    Text("\(Int(k.rounded())) 千卡")
                        .font(.caption)
                        .foregroundColor(Theme.brandDeep)
                        .monospacedDigit()
                }
                if savingContent == item.content {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Theme.brandBlue)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(savingContent != nil)
    }

    private func load() async {
        do {
            let r = try await APIClient.shared.fetchFrequentMeals()
            await MainActor.run {
                items = r
                loading = false
                error = nil
            }
        } catch let err {
            await MainActor.run {
                loading = false
                error = err.localizedDescription
            }
        }
    }

    private func record(_ item: APIClient.FrequentMeal) {
        savingContent = item.content
        Haptics.tap()
        Task {
            let outcome = await state.saveMealResilient(date: dateStr,
                                                       type: MealRecord.autoType(),
                                                       content: item.content,
                                                       kcal: item.kcal,
                                                       protein_g: item.protein_g,
                                                       fat_g: item.fat_g,
                                                       carbs_g: item.carbs_g,
                                                       image_url: nil)
            await MainActor.run {
                savingContent = nil
                switch outcome {
                case .synced:
                    Haptics.success()
                    state.showToast("已记录：\(item.content)")
                    dismiss()
                case .queued:
                    Haptics.success()
                    state.showToast("已存本地，联网后自动同步")
                    dismiss()
                case .failed(let msg):
                    Haptics.error()
                    state.showToast("记录失败：\(msg)")
                }
            }
        }
    }
}
