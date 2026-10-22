import SwiftUI

/// 食物拍照识图：拍照/选图 → AI 识别食物 + 卡路里 → 确认记账
struct FoodRecognizeView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String

    @State private var pickedImage: UIImage?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var recognizing = false
    @State private var saving = false
    @State private var result: APIClient.FoodRecognition?
    @State private var weightText = ""
    @State private var type = MealRecord.autoType()
    @State private var error: String?

    private let types = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐")]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    imageArea
                    if result != nil { resultArea }
                    if let error { Text(error).font(.footnote).foregroundColor(.red) }
                }
                .padding(16)
            }
            .navigationTitle("拍照识图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .sheet(isPresented: $showCamera) {
                ImagePicker(sourceType: .camera) { img in pickedImage = img }
            }
            .sheet(isPresented: $showLibrary) {
                ImagePicker(sourceType: .photoLibrary) { img in pickedImage = img }
            }
            .onAppear {
                // 进入即呼出相机，无需再点「拍照」
                if pickedImage == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showCamera = true
                    }
                }
            }
        }
    }

    // MARK: - 图片选择区

    @ViewBuilder
    private var imageArea: some View {
        VStack(spacing: 12) {
            if let img = pickedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .cornerRadius(12)
                HStack(spacing: 12) {
                    Button { showCamera = true } label: { Label("重拍", systemImage: "camera") }
                    Button { showLibrary = true } label: { Label("换图", systemImage: "photo") }
                    Spacer()
                    Button(action: recognize) {
                        if recognizing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("识别食物", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recognizing)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("拍一张食物照片，自动识别并算卡路里")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack(spacing: 16) {
                        Button { showCamera = true } label: {
                            Label("拍照", systemImage: "camera").frame(minWidth: 100)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { showLibrary = true } label: {
                            Label("相册", systemImage: "photo").frame(minWidth: 100)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }

    // MARK: - 识别结果区

    @ViewBuilder
    private var resultArea: some View {
        if let r = result {
            VStack(spacing: 14) {
                Text(r.food.isEmpty ? "未识别出食物" : r.food)
                    .font(.title3.bold())

                HStack {
                    Text("克数")
                    Spacer()
                    TextField("克", text: $weightText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("g").foregroundColor(.secondary)
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    nutrientCard("卡路里", "\(Int(scaledKcal.rounded()))", "千卡")
                    nutrientCard("蛋白质", "\(Int(scaledProtein.rounded()))", "g")
                }
                HStack(spacing: 12) {
                    nutrientCard("脂肪", "\(Int(scaledFat.rounded()))", "g")
                    nutrientCard("碳水", "\(Int(scaledCarbs.rounded()))", "g")
                }

                Picker("餐次", selection: $type) {
                    ForEach(types, id: \.0) { t in Text(t.1).tag(t.0) }
                }
                .pickerStyle(.segmented)

                Button(action: save) {
                    if saving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("记入 \(dateStr)").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemGroupedBackground)))
        }
    }

    private func nutrientCard(_ name: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text("\(name) (\(unit))").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.systemBackground)))
    }

    // MARK: - 卡路里按克数缩放

    private var scaleFactor: Double {
        guard let r = result, r.weight_g > 0, let w = Double(weightText), w > 0 else { return 1 }
        return w / r.weight_g
    }
    private var scaledKcal: Double { (result?.kcal ?? 0) * scaleFactor }
    private var scaledProtein: Double { (result?.protein_g ?? 0) * scaleFactor }
    private var scaledFat: Double { (result?.fat_g ?? 0) * scaleFactor }
    private var scaledCarbs: Double { (result?.carbs_g ?? 0) * scaleFactor }

    // MARK: - 动作

    private func recognize() {
        guard let img = pickedImage, let b64 = ImageUtil.jpegBase64(img) else { return }
        recognizing = true
        error = nil
        Task {
            defer { recognizing = false }
            do {
                let r = try await APIClient.shared.recognizeFood(imageBase64: b64)
                await MainActor.run {
                    result = r
                    weightText = r.weight_g > 0 ? String(Int(r.weight_g.rounded())) : ""
                }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }

    private func save() {
        guard let r = result else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                var imageURL: String? = nil
                if let img = pickedImage, let b64 = ImageUtil.jpegBase64(img, maxDimension: 800, quality: 0.6) {
                    imageURL = try await APIClient.shared.uploadImage(imageBase64: b64, ext: "jpg")
                }
                let content = r.food.isEmpty ? "食物" : r.food
                _ = try await APIClient.shared.saveMeal(
                    date: dateStr, type: type, content: content,
                    kcal: scaledKcal, protein_g: scaledProtein, fat_g: scaledFat, carbs_g: scaledCarbs,
                    image_url: imageURL)
                await state.refreshMeals(date: dateStr)
                await MainActor.run { dismiss() }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }
}
