import SwiftUI

/// 体重录入 / 编辑（按日期覆盖）
struct WeightEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var kgText = ""
    @State private var note = ""
    @State private var isBusy = false
    @State private var error: String?

    /// 编辑已有记录时传入
    var editing: WeightRecord?

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

                if let h = state.user?.height_cm, let kg = Double(kgText), kg > 0 {
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
                    Button("保存", action: save).disabled(isBusy)
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
        guard let kg = Double(kgText), kg > 10, kg < 500 else {
            error = "请输入有效体重（10~500 kg）"
            return
        }
        isBusy = true
        error = nil
        let dateStr = WeightRecord.dateFormatter.string(from: date)
        Task {
            defer { isBusy = false }
            do {
                _ = try await APIClient.shared.saveWeight(date: dateStr, kg: kg, note: note)
                await state.refreshWeights()
                await MainActor.run { dismiss() }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }
}
