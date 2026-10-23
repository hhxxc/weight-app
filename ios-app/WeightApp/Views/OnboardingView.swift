import SwiftUI

/// 首次使用引导：补齐身高 / 目标体重 / 每日热量目标
/// 没有这两项，BMI、进度预测、热量预算都没法算，所以第一次登录时问一次。
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var heightText = ""
    @State private var targetText = ""
    @State private var kcalText = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("身高")
                        TextField("178", text: $heightText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("cm").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("目标体重")
                        TextField("75", text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("kg").foregroundColor(.secondary)
                    }
                } header: {
                    Text("基本资料")
                } footer: {
                    Text("身高用来算 BMI；目标体重用来算进度预测和完成度。之后都能在「我的 → 个人资料」里改。")
                }

                Section {
                    HStack {
                        Text("每日热量目标")
                        TextField("留空自动估算", text: $kcalText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("千卡").foregroundColor(.secondary)
                    }
                } footer: {
                    Text("不确定填多少就留空，App 会按当前体重和每周减 0.5kg 的速度自动估算。")
                }

                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle("开始之前")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") {
                        state.markOnboardingSeen()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "保存中…" : "保存", action: save)
                        .disabled(busy || !isValid)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var isValid: Bool {
        guard let h = Double(heightText), h >= 100, h <= 250 else { return false }
        guard let t = Double(targetText), t >= 30, t <= 200 else { return false }
        return true
    }

    private func prefill() {
        if let h = state.user?.height_cm, h > 0 { heightText = String(Int(h)) }
        if let t = state.user?.target_kg, t > 0 { targetText = String(format: "%.1f", t) }
        if let k = state.user?.daily_kcal_target, k > 0 { kcalText = String(Int(k)) }
    }

    private func save() {
        guard let h = Double(heightText), let t = Double(targetText) else { return }
        let kcal = Double(kcalText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        busy = true
        error = nil
        Task {
            do {
                let u = try await APIClient.shared.updateMe(nickname: state.user?.nickname ?? "",
                                                            heightCm: h,
                                                            targetKg: t,
                                                            dailyKcalTarget: kcal)
                await MainActor.run {
                    busy = false
                    state.updateUser(u)
                    state.markOnboardingSeen()
                    Haptics.success()
                    dismiss()
                }
            } catch let err {
                await MainActor.run {
                    busy = false
                    error = err.localizedDescription
                }
            }
        }
    }
}
