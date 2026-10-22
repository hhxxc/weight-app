import SwiftUI

/// 体重录入 / 编辑（按日期覆盖）
struct WeightEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var kgText = ""
    @State private var note = ""
    @State private var error: String?
    @State private var pendingKg: Double?
    @State private var showAnomalyAlert = false

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
            .alert("体重变化有点大", isPresented: $showAnomalyAlert) {
                Button("确认录入") {
                    if let kg = pendingKg { commit(kg) }
                    pendingKg = nil
                }
                Button("取消", role: .cancel) { pendingKg = nil }
            } message: {
                Text(anomalyMessage)
            }
        }
    }

    private func save() {
        guard let kg = validKg else {
            error = "请输入有效体重（10~500 kg）"
            Haptics.warning()
            return
        }
        let dateStr = WeightRecord.dateFormatter.string(from: date)

        // 与最近另一条记录相差 ≥3kg 时二次确认，防手误
        if let last = state.sortedDesc.first(where: { $0.date != dateStr }),
           abs(kg - last.kg) >= 3 {
            pendingKg = kg
            showAnomalyAlert = true
            Haptics.warning()
            return
        }
        commit(kg)
    }

    private var anomalyMessage: String {
        let dateStr = WeightRecord.dateFormatter.string(from: date)
        guard let last = state.sortedDesc.first(where: { $0.date != dateStr }),
              let kg = pendingKg else { return "确认这次录入的体重吗？" }
        return String(format: "上次记录是 %.1f kg（%@），这次 %.1f kg，相差 %.1f kg。确认没输错吗？",
                      last.kg, last.chineseDate, kg, abs(kg - last.kg))
    }

    private func commit(_ kg: Double) {
        error = nil
        let dateStr = WeightRecord.dateFormatter.string(from: date)
        let noteText = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldDate = editing?.date
        // 记完给个即时对比（和最近一条别的记录比）
        let previousKg = state.sortedDesc.first(where: { $0.date != dateStr })?.kg

        // 乐观更新：本地立即生效并关闭面板，网络在后台完成
        Task {
            state.applyLocalWeight(date: dateStr, kg: kg, note: noteText)
            await MainActor.run {
                Haptics.success()
                dismiss()
                if let prev = previousKg, abs(kg - prev) >= 0.1 {
                    state.showToast(String(format: "已记录 %.1f kg，较上次 %+.1f kg", kg, kg - prev))
                }
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
