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
    /// 多样食物：每行的克数输入 / 是否记入
    @State private var multiGrams: [String] = []
    @State private var multiOn: [Bool] = []

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
            if let items = r.items, items.count > 1 {
                multiResult(items, converted: r.converted_from_kj == true)
            } else {
                singleResult(r)
            }
        }
    }

    // MARK: - 单样食物

    private func singleResult(_ r: APIClient.FoodRecognition) -> some View {
        VStack(spacing: 14) {
            Text(r.food.isEmpty ? "未识别出食物" : r.food)
                .font(.title3.bold())

            if r.converted_from_kj == true {
                kjHint
            }

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

            typePicker

            Button(action: save) {
                if saving {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text("记入 \(chineseDateString(dateStr))").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    // MARK: - 多样食物

    private func multiResult(_ items: [APIClient.FoodItem], converted: Bool) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("识别到 \(items.count) 样食物")
                    .font(.headline)
                Spacer()
                Text("共 \(Int(multiTotal(items).rounded())) 千卡")
                    .font(.caption)
                    .foregroundColor(Theme.brandDeep)
                    .monospacedDigit()
            }

            if converted { kjHint }

            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Button {
                        if i < multiOn.count {
                            multiOn[i].toggle()
                            Haptics.tap()
                        }
                    } label: {
                        Image(systemName: (i < multiOn.count && multiOn[i]) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor((i < multiOn.count && multiOn[i]) ? Theme.brandDeep : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[i].food)
                            .font(.subheadline)
                        Text("\(Int(multiKcal(items, i).rounded())) 千卡")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Spacer()

                    TextField("克", text: bindingForGram(i))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("g")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
                .opacity((i < multiOn.count && multiOn[i]) ? 1 : 0.45)
            }

            Divider()

            typePicker

            Button(action: { saveMulti(items) }) {
                if saving {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text("记入 \(max(1, multiOn.filter { $0 }.count)) 样 · \(chineseDateString(dateStr))")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving || multiOn.filter { $0 }.isEmpty)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    private var kjHint: some View {
        Text("营养成分表单位是千焦(kJ)，已自动 ÷4.184 换算为千卡")
            .font(.caption2)
            .foregroundColor(Theme.warning)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    private var typePicker: some View {
        Picker("餐次", selection: $type) {
            ForEach(types, id: \.0) { t in Text(t.1).tag(t.0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 多样食物的克数 / 卡路里

    private func bindingForGram(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < multiGrams.count ? multiGrams[i] : "" },
            set: { v in
                if i < multiGrams.count { multiGrams[i] = v }
            }
        )
    }

    private func multiGramsOf(_ items: [APIClient.FoodItem], _ i: Int) -> Double {
        if i < multiGrams.count, let g = Double(multiGrams[i]), g > 0 { return g }
        return max(0, items[i].weight_g)
    }

    private func multiKcal(_ items: [APIClient.FoodItem], _ i: Int) -> Double {
        let base = items[i]
        guard base.weight_g > 0 else { return base.kcal }
        return base.kcal * multiGramsOf(items, i) / base.weight_g
    }

    private func multiTotal(_ items: [APIClient.FoodItem]) -> Double {
        items.indices.filter { $0 < multiOn.count && multiOn[$0] }
            .reduce(0.0) { $0 + multiKcal(items, $1) }
    }

    private func saveMulti(_ items: [APIClient.FoodItem]) {
        let chosen = items.indices.filter { $0 < multiOn.count && multiOn[$0] }
        guard !chosen.isEmpty else {
            error = "至少勾选一样食物"
            return
        }
        saving = true
        error = nil
        Task {
            var imageURL: String? = nil
            if let img = pickedImage, let b64 = ImageUtil.jpegBase64(img, maxDimension: 800, quality: 0.6) {
                imageURL = try? await APIClient.shared.uploadImage(imageBase64: b64, ext: "jpg")
            }

            var okCount = 0
            for i in chosen {
                let base = items[i]
                let grams = multiGramsOf(items, i)
                let ratio = base.weight_g > 0 ? grams / base.weight_g : 1
                let clientId = UUID().uuidString
                do {
                    _ = try await APIClient.shared.saveMeal(
                        date: dateStr, type: type, content: base.food,
                        kcal: multiKcal(items, i),
                        protein_g: base.protein_g * ratio,
                        fat_g: base.fat_g * ratio,
                        carbs_g: base.carbs_g * ratio,
                        image_url: imageURL,
                        clientId: clientId)
                    okCount += 1
                } catch {
                    // 单条失败不影响其他条目
                }
            }

            await state.refreshMeals(date: dateStr)
            await MainActor.run {
                saving = false
                if okCount > 0 {
                    Haptics.success()
                    dismiss()
                } else {
                    Haptics.error()
                    error = "保存失败，请检查网络后重试"
                }
            }
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
                    let items = r.items ?? []
                    multiGrams = items.map { $0.weight_g > 0 ? String(Int($0.weight_g.rounded())) : "" }
                    multiOn = items.map { _ in true }
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
                let clientId = UUID().uuidString
                var imageURL: String? = nil
                if let img = pickedImage, let b64 = ImageUtil.jpegBase64(img, maxDimension: 800, quality: 0.6) {
                    imageURL = try await APIClient.shared.uploadImage(imageBase64: b64, ext: "jpg")
                }
                let content = r.food.isEmpty ? "食物" : r.food
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
