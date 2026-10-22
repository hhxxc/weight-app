import SwiftUI

/// 饮食记录页（按日期分组，可切换日期、增删）
struct MealListView: View {
    @EnvironmentObject var state: AppState

    @State private var selectedDate = Date()
    @State private var showAdd = false
    @State private var showFoodRecognize = false
    @State private var showNutritionOCR = false
    @State private var showVoice = false
    @State private var showFrequent = false
    @State private var editingMeal: MealRecord?
    @State private var viewingImage: URL?
    @State private var showViewer = false

    private var dateStr: String { WeightRecord.dateFormatter.string(from: selectedDate) }
    private var dayMeals: [MealRecord] {
        // 当前日期已加载就直接用；否则先取该日缓存，切日期不闪空
        state.mealsDate == dateStr ? state.meals : state.cachedMeals(for: dateStr)
    }

    /// 当日营养合计
    private var dayTotal: (kcal: Double, protein: Double, fat: Double, carbs: Double) {
        var k = 0.0, p = 0.0, f = 0.0, c = 0.0
        for m in dayMeals {
            k += m.kcal ?? 0
            p += m.protein_g ?? 0
            f += m.fat_g ?? 0
            c += m.carbs_g ?? 0
        }
        return (k, p, f, c)
    }

    /// 每日热量目标：手动设置优先，否则按当前体重估算
    private var kcalTarget: Double? {
        state.user?.kcalTarget(currentKg: state.sortedDesc.first?.kg)
    }

    private var summaryBar: some View {
        VStack(spacing: 6) {
            if let target = kcalTarget, target > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(dayTotal.kcal.rounded()))")
                        .font(.title3.bold())
                        .monospacedDigit()
                    Text("/ \(Int(target)) 千卡\(state.user?.isKcalTargetCustom == true ? "" : " · 自动")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if dayTotal.kcal > target {
                        Text("超出 \(Int((dayTotal.kcal - target).rounded())) 千卡")
                            .font(.caption.bold())
                            .foregroundColor(Theme.danger)
                    } else {
                        Text("还剩 \(Int((target - dayTotal.kcal).rounded())) 千卡")
                            .font(.caption.bold())
                            .foregroundColor(Theme.success)
                    }
                }
                ProgressView(value: min(1, max(0, dayTotal.kcal / target)))
                    .tint(dayTotal.kcal > target ? Theme.danger : Theme.brandBlue)
            } else {
                HStack {
                    Label("\(Int(dayTotal.kcal.rounded())) 千卡", systemImage: "flame.fill")
                        .foregroundColor(Theme.warning)
                    Spacer()
                    Text("去「我的」设置热量目标")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !dayMeals.isEmpty {
                HStack(spacing: 12) {
                    Text("蛋白 \(Int(dayTotal.protein.rounded()))g")
                    Text("脂肪 \(Int(dayTotal.fat.rounded()))g")
                    Text("碳水 \(Int(dayTotal.carbs.rounded()))g")
                    Spacer()
                    Text("\(dayMeals.count) 条")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 日期切换器
                HStack {
                    Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                        .frame(width: 44, height: 44)
                    Spacer()
                    DatePicker("", selection: $selectedDate, displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                        .frame(width: 44, height: 44)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // 今日热量预算（没设目标时退回简单合计）
                summaryBar

                Divider()

                if dayMeals.isEmpty {
                    if state.isLoadingMeals && state.mealsDate != dateStr {
                        ProgressView("加载中…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "fork.knife")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                            Text("这一天还没有记录饮食")
                                .font(.headline)
                            Text("点下方「拍照记饮食」，拍一张自动识别卡路里")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List {
                        ForEach(dayMeals) { m in
                            HStack(alignment: .top, spacing: 12) {
                                Text(m.typeName)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(typeColor(m.type))
                                    .cornerRadius(8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.content)
                                        .font(.body)
                                    if !m.kcalText.isEmpty {
                                        Text(m.kcalText)
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                Spacer()
                                // 食物缩略图
                                if let url = APIClient.shared.imageURL(for: m.image_url) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().scaledToFill()
                                        case .failure:
                                            Image(systemName: "photo")
                                                .foregroundColor(.secondary)
                                        default:
                                            ProgressView().scaleEffect(0.7)
                                        }
                                    }
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewingImage = url
                                        showViewer = true
                                    }
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { editingMeal = m }
                        }
                        .onDelete(perform: deleteItems)
                    }
                    .listStyle(.plain)
                    .refreshable { await state.refreshMeals(date: dateStr) }
                }

                // 底部操作栏：拍照识图为主操作
                bottomBar
            }
            .navigationTitle("饮食")
            .sheet(isPresented: $showAdd) {
                MealEditView(dateStr: dateStr)
            }
            .sheet(item: $editingMeal) { m in
                MealEditView(dateStr: m.date, meal: m)
            }
            .sheet(isPresented: $showViewer) {
                if let url = viewingImage {
                    ImageViewer(url: url)
                }
            }
            .sheet(isPresented: $showFoodRecognize) {
                FoodRecognizeView(dateStr: dateStr)
            }
            .sheet(isPresented: $showNutritionOCR) {
                NutritionOCRView(dateStr: dateStr)
            }
            .sheet(isPresented: $showVoice) {
                VoiceRecordView(dateStr: dateStr)
            }
            .sheet(isPresented: $showFrequent) {
                FrequentMealsView(dateStr: dateStr)
            }
            .onChange(of: dateStr) { _ in
                Task { await state.refreshMeals(date: dateStr) }
            }
            .task {
                await state.refreshMeals(date: dateStr)
                // 预热昨天：往回翻一页也瞬间出内容
                if let prev = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) {
                    await state.prefetchMeals(date: WeightRecord.dateFormatter.string(from: prev))
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func typeColor(_ t: String) -> Color {
        switch t {
        case "breakfast": return .orange
        case "lunch": return .green
        case "dinner": return .purple
        default: return .gray
        }
    }

    /// 底部操作栏：拍照识图主按钮 + 两个次要入口
    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button { showFoodRecognize = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text("拍照记饮食")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .background(Theme.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                secondaryButton("常吃", icon: "clock.arrow.circlepath") { showFrequent = true }
                secondaryButton("语音", icon: "mic.fill") { showVoice = true }
                secondaryButton("手动", icon: "square.and.pencil") { showAdd = true }
                secondaryButton("配料表", icon: "text.viewfinder") { showNutritionOCR = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemBackground))
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(title).font(.caption2)
            }
            .foregroundColor(Theme.brandDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Theme.brandBlue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func shiftDay(_ d: Int) {
        if let nd = Calendar.current.date(byAdding: .day, value: d, to: selectedDate) {
            selectedDate = nd
            Haptics.tap()
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let items = offsets.map { dayMeals[$0] }
        Haptics.tap()
        Task {
            var failed = 0
            for m in items {
                do { try await APIClient.shared.deleteMeal(id: m.id) }
                catch { failed += 1 }
            }
            await state.refreshMeals(date: dateStr)
            await MainActor.run {
                if failed > 0 { Haptics.error() } else { Haptics.success() }
            }
        }
    }
}

/// 食物图片大图查看
struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationView {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("图片加载失败").font(.footnote).foregroundColor(.secondary)
                    }
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemBackground))
            .navigationTitle("食物照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 饮食录入 / 编辑（传入 meal 则为编辑模式）
struct MealEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let dateStr: String
    var meal: MealRecord? = nil   // 编辑模式：传入要编辑的记录

    @State private var type = MealRecord.autoType()
    @State private var content = ""
    @State private var kcalText = ""
    @State private var isBusy = false
    @State private var error: String?

    private let types = [("breakfast", "早餐"), ("lunch", "午餐"), ("dinner", "晚餐"), ("snack", "加餐")]
    private var isEditing: Bool { meal != nil }

    var body: some View {
        NavigationView {
            Form {
                Section("餐次") {
                    Picker("餐次", selection: $type) {
                        ForEach(types, id: \.0) { t in Text(t.1).tag(t.0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                }
                Section {
                    HStack {
                        Text("卡路里")
                        TextField("可留空", text: $kcalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("千卡")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("AI 估算不准时可以在这里手改；留空表示不计入卡路里统计。")
                }
                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle(isEditing ? "编辑饮食" : "记录饮食")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(isBusy || content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let m = meal {
                    type = m.type
                    content = m.content
                    if let k = m.kcal, k > 0 {
                        kcalText = String(format: "%.0f", k)
                    }
                }
            }
        }
    }

    private func save() {
        let trimmedKcal = kcalText.trimmingCharacters(in: .whitespaces)
        var kcalValue: Double?
        if !trimmedKcal.isEmpty {
            guard let k = Double(trimmedKcal), k >= 0, k <= 5000 else {
                error = "卡路里请输入 0~5000 之间的数字"
                Haptics.warning()
                return
            }
            kcalValue = k
        }

        isBusy = true
        error = nil
        Task {
            do {
                if let m = meal {
                    _ = try await APIClient.shared.updateMeal(id: m.id, date: m.date, type: type,
                                                              content: content, kcal: kcalValue,
                                                              protein_g: m.protein_g, fat_g: m.fat_g,
                                                              carbs_g: m.carbs_g, image_url: m.image_url)
                } else {
                    _ = try await APIClient.shared.saveMeal(date: dateStr, type: type,
                                                            content: content, kcal: kcalValue)
                }
                await state.refreshMeals(date: meal?.date ?? dateStr)
                await MainActor.run {
                    isBusy = false
                    Haptics.success()
                    dismiss()
                }
            } catch let err {
                await MainActor.run {
                    isBusy = false
                    Haptics.error()
                    error = err.localizedDescription
                }
            }
        }
    }
}
