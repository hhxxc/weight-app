import SwiftUI

/// 体重录入 / 编辑（按日期覆盖）
struct WeightEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var kgText = ""
    @State private var note = ""
    @State private var error: String?

    /// 编辑已有记录时传入
    var editing: WeightRecord?

    private var validKg: Double? {
        guard let kg = Double(kgText), kg > 10, kg < 500 else { return nil }
        return kg
    }

    var body: some View {
        NavigationView {
            Form {
                Section("记录") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    HStack {
                        Text("体重")
                        TextField("kg", text: $kgText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("kg")
                    }
                    TextField("备注（可选）", text: $note)
                }

                if let h = state.user?.height_cm, let kg = validKg {
                    let bmi = BMI.value(kg: kg, heightCm: h)
                    Section("BMI 预览") {
                        HStack {
                            Text(String(format: "%.1f", bmi))
                                .font(.title2.bold())
                            Spacer()
                            Text(BMI.level(bmi).rawValue)
                                .foregroundColor(Color(hex: BMI.level(bmi).colorHex))
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle(editing == nil ? "记录体重" : "修改体重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(validKg == nil)
                }
            }
            .onAppear {
                if let e = editing {
                    if let d = WeightRecord.dateFormatter.date(from: e.date) { date = d }
                    kgText = String(format: "%.1f", e.kg)
                    note = e.note
                }
            }
        }
    }

    private func save() {
        guard let kg = validKg else {
            error = "请输入有效体重（10~500 kg）"
            Haptics.warning()
            return
        }
        error = nil
        let dateStr = WeightRecord.dateFormatter.string(from: date)
        let noteText = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldDate = editing?.date

        // 乐观更新：本地立即生效并关闭面板，网络在后台完成
        Task {
            state.applyLocalWeight(date: dateStr, kg: kg, note: noteText)
            await MainActor.run {
                Haptics.success()
                dismiss()
            }
            do {
                _ = try await APIClient.shared.saveWeight(date: dateStr, kg: kg, note: noteText)
                // 编辑时改了日期：把旧日期那条删掉，避免出现两条
                if let old = oldDate, old != dateStr {
                    try? await APIClient.shared.deleteWeight(date: old)
                    state.removeLocalWeights(dates: [old])
                }
                await state.refreshWeights()
            } catch {
                // 断网也不丢记录：进待同步队列，下次启动自动补传
                PendingSync.add(date: dateStr, kg: kg, note: noteText)
                state.showToast("已存本地，联网后自动同步")
            }
        }
    }
}
