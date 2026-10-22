import SwiftUI

/// 语音记录饮食：说话 → 转文字 → 自动估卡路里 → 确认记账
struct VoiceRecordView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String

    @StateObject private var recognizer = SpeechRecognizer()
    @State private var text = ""
    @State private var type = MealRecord.autoType()
    @State private var estimation: APIClient.FoodEstimation?
    @State private var estimating = false
    @State private var saving = false
    @State private var error: String?
    @State private var permissionDenied = false

    private let types = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐")]

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // 语音输入区
                VStack(spacing: 12) {
                    if recognizer.isRecording {
                        // 录音中：波形提示
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 40))
                                .foregroundColor(Theme.brandBlue)
                            Text("正在聆听…请说「吃了什么」")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else if text.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "mic")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("点下方按钮，说出你吃了什么")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }

                // 识别文字（可编辑）
                if !text.isEmpty {
                    TextEditor(text: $text)
                        .frame(minHeight: 70)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color(UIColor.separator), lineWidth: 0.5)
                        )
                }

                // 麦克风按钮
                Button(action: toggleRecord) {
                    ZStack {
                        Circle()
                            .fill(recognizer.isRecording ? Theme.danger : Theme.brandGradient)
                            .frame(width: 72, height: 72)
                        Image(systemName: recognizer.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                }

                // 餐次
                Picker("餐次", selection: $type) {
                    ForEach(types, id: \.0) { t in Text(t.1).tag(t.0) }
                }
                .pickerStyle(.segmented)

                // 卡路里估算结果
                if let e = estimation {
                    HStack(spacing: 12) {
                        estimationCard("卡路里", "\(Int(e.kcal.rounded()))", "千卡")
                        estimationCard("蛋白质", "\(Int(e.protein_g.rounded()))", "g")
                    }
                    HStack(spacing: 12) {
                        estimationCard("脂肪", "\(Int(e.fat_g.rounded()))", "g")
                        estimationCard("碳水", "\(Int(e.carbs_g.rounded()))", "g")
                    }
                } else if !text.isEmpty {
                    Button(action: estimate) {
                        if estimating {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("估算卡路里", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(estimating || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let error {
                    Text(error).font(.footnote).foregroundColor(.red)
                }

                // 保存
                if estimation != nil || !text.isEmpty {
                    Button(action: save) {
                        if saving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("记入 \(chineseDateString(dateStr))")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Spacer()
            }
            .padding(16)
            .navigationTitle("语音记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .alert("需要语音权限", isPresented: $permissionDenied) {
                Button("去设置", role: .none) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在系统设置中允许「体重记录」使用麦克风和语音识别。")
            }
        }
    }

    private func estimationCard(_ name: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text("\(name) (\(unit))").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    private func toggleRecord() {
        if recognizer.isRecording {
            recognizer.stop()
            // 录音结束，把识别结果同步到可编辑文本框
            text = recognizer.transcript.trimmingCharacters(in: .whitespaces)
        } else {
            Task {
                let ok = await recognizer.requestPermission()
                if !ok {
                    permissionDenied = true
                    return
                }
                do {
                    try recognizer.start()
                } catch {
                    error = "无法启动录音：\(error.localizedDescription)"
                }
            }
        }
    }

    private func estimate() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        estimating = true
        error = nil
        Task {
            defer { estimating = false }
            do {
                let r = try await APIClient.shared.estimateFood(text: t)
                await MainActor.run { estimation = r }
            } catch let err {
                await MainActor.run { error = "卡路里估算失败：\(err.localizedDescription)" }
            }
        }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let e = estimation
                _ = try await APIClient.shared.saveMeal(
                    date: dateStr, type: type, content: e?.food.isEmpty == false ? e!.food : t,
                    kcal: e?.kcal, protein_g: e?.protein_g, fat_g: e?.fat_g, carbs_g: e?.carbs_g)
                await state.refreshMeals(date: dateStr)
                await MainActor.run { dismiss() }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }
}
