import SwiftUI

/// 搜历史饮食：找到上次那道菜，一键再记一次（记到当前查看的日期）
struct MealSearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let targetDate: String

    @State private var query = ""
    @State private var hits: [APIClient.MealSearchHit] = []
    @State private var loading = false
    @State private var reloggingId: Int?
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜菜名，比如「牛肉面」", text: $query)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if loading {
                    ProgressView().padding(.top, 20)
                    Spacer()
                } else if trimmedQuery.isEmpty {
                    hint("输入菜名搜历史记录\n找到后点「再记」直接记到 \(chineseDateString(targetDate))")
                } else if hits.isEmpty {
                    hint("没搜到「\(trimmedQuery)」相关的记录")
                } else {
                    List {
                        ForEach(hits) { h in
                            row(h)
                        }
                    }
                    .listStyle(.plain)
                    .background(Theme.canvas)
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("搜历史饮食")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task(id: query) {
                await search(trimmedQuery)
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ h: APIClient.MealSearchHit) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(h.content)
                    .font(.subheadline)
                Text(subtitle(h))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                relog(h)
            } label: {
                Text(reloggingId == h.id ? "记录中…" : "再记")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.fill)
                    .foregroundColor(Theme.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(reloggingId != nil)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ h: APIClient.MealSearchHit) -> String {
        var parts = [chineseDateString(h.date), typeLabel(h.type)]
        if let k = h.kcal, k > 0 { parts.append("\(Int(k.rounded())) 千卡") }
        return parts.joined(separator: " · ")
    }

    private func typeLabel(_ t: String) -> String {
        switch t {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        default: return "加餐"
        }
    }

    private func search(_ q: String) async {
        guard !q.isEmpty else {
            await MainActor.run {
                hits = []
                loading = false
            }
            return
        }
        await MainActor.run { loading = true }
        // 输入防抖，避免每敲一个字都请求
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        do {
            let r = try await APIClient.shared.searchMeals(query: q)
            if Task.isCancelled { return }
            await MainActor.run {
                hits = r
                loading = false
            }
        } catch {
            await MainActor.run { loading = false }
        }
    }

    private func relog(_ h: APIClient.MealSearchHit) {
        reloggingId = h.id
        error = nil
        Task {
            let outcome = await state.saveMealResilient(date: targetDate, type: h.type,
                                                        content: h.content, kcal: h.kcal,
                                                        protein_g: h.protein_g, fat_g: h.fat_g,
                                                        carbs_g: h.carbs_g, image_url: h.image_url)
            await MainActor.run {
                reloggingId = nil
                switch outcome {
                case .synced:
                    Haptics.success()
                    state.showToast("已记入：\(h.content)")
                    dismiss()
                case .queued:
                    Haptics.success()
                    state.showToast("已存本地，联网后自动同步")
                    dismiss()
                case .failed(let msg):
                    Haptics.error()
                    error = msg
                }
            }
        }
    }
}
