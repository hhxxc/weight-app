import SwiftUI

/// 配料表/营养成分表 OCR：拍照 → 识别每100g营养 → 填克数算卡路里 → 记账
struct NutritionOCRView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String

    @State private var pickedImage: UIImage?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var recognizing = false
    @State private var saving = false
    @State private var result: APIClient.NutritionInfo?
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
            .navigationTitle("拍配料表")
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
        }
    }

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
                        if recognizing { ProgressView().scaleEffect(0.8) }
                        else { Label("识别", systemImage: "text.viewfinder") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recognizing)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("拍营养成分表，自动读出每 100g 的能量和营养")
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

    @ViewBuilder
    private var resultArea: some View {
        if let r = result {
            VStack(spacing: 14) {
                if !r.name.isEmpty {
                    Text(r.name).font(.title3.bold())
                }
                Text("每 100g")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    nutrientCard("能量", "\(Int(r.energy_kcal.rounded()))", "千卡/100g")
                    nutrientCard("蛋白质", "\(Int(r.protein_g.rounded()))", "g")
                }
                HStack(spacing: 12) {
                    nutrientCard("脂肪", "\(Int(r.fat_g.rounded()))", "g")
                    nutrientCard("碳水", "\(Int(r.carbs_g.rounded()))", "g")
                }

                HStack {
                    Text("吃了多少克")
                    Spacer()
                    TextField("克", text: $weightText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("g").foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // 按克数折算后的卡路里
                let kcal = scaledKcal
                Text("≈ \(Int(kcal.rounded())) 千卡")
                    .font(.title2.bold())
                    .foregroundColor(.accentColor)

                Picker("餐次", selection: $type) {
                    ForEach(types, id: \.0) { t in Text(t.1).tag(t.0) }
                }
                .pickerStyle(.segmented)

                Button(action: save) {
                    if saving { ProgressView().scaleEffect(0.8) }
                    else { Text("记入 \(chineseDateString(dateStr))").frame(maxWidth: .infinity) }
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
            Text("\(name) \(unit)").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.systemBackground)))
    }

    private var scaleFactor: Double {
        guard let w = Double(weightText), w > 0 else { return 0 }
        return w / 100.0
    }
    private var scaledKcal: Double { (result?.energy_kcal ?? 0) * scaleFactor }
    private var scaledProtein: Double { (result?.protein_g ?? 0) * scaleFactor }
    private var scaledFat: Double { (result?.fat_g ?? 0) * scaleFactor }
    private var scaledCarbs: Double { (result?.carbs_g ?? 0) * scaleFactor }

    private func recognize() {
        guard let img = pickedImage, let b64 = ImageUtil.jpegBase64(img) else { return }
        recognizing = true
        error = nil
        Task {
            defer { recognizing = false }
            do {
                var r = try await APIClient.shared.ocrNutrition(imageBase64: b64)
                // 若模型只给了 kJ 没给 kcal，换算：1 kcal = 4.184 kJ
                if r.energy_kcal <= 0 && r.energy_kj > 0 {
                    r = APIClient.NutritionInfo(name: r.name, energy_kj: r.energy_kj,
                                                energy_kcal: r.energy_kj / 4.184,
                                                protein_g: r.protein_g, fat_g: r.fat_g, carbs_g: r.carbs_g)
                }
                await MainActor.run {
                    result = r
                    weightText = "100"
                }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }

    private func save() {
        guard let r = result, scaledKcal > 0 else {
            error = "请填写食用克数"
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let clientId = UUID().uuidString
                var imageURL: String? = nil
                if let img = pickedImage, let b64 = ImageUtil.jpegBase64(img, maxDimension: 800, quality: 0.6) {
                    imageURL = try await APIClient.shared.uploadImage(imageBase64: b64, ext: "jpg")
                }
                let content = r.name.isEmpty ? "包装食品" : r.name
                _ = try await APIClient.shared.saveMeal(
                    date: dateStr, type: type, content: content,
                    kcal: scaledKcal, protein_g: scaledProtein, fat_g: scaledFat, carbs_g: scaledCarbs,
                    image_url: imageURL, clientId: clientId)
                await state.refreshMeals(date: dateStr)
                await MainActor.run { dismiss() }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }
}
